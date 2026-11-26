from __future__ import annotations

import base64
import copy
import io
import json
import os
import unittest
from unittest import mock

from server import (
    AdmissionHandler,
    admit,
    validate,
)
from test_adapter import RUNTIME_IMAGE, apply_patch, target_pod

OWNERSHIP_INIT_IMAGE = f"example.invalid/ownership-helper@sha256:{'b' * 64}"
ADMISSION_USER = "system:serviceaccount:kube-system:replicaset-controller"
DEPLOYMENT_USER = "system:serviceaccount:openclaw-system:openclaw-enterprise-worker"
REPLICASET_USER = "system:kube-controller-manager"
GARBAGE_COLLECTOR_USER = (
    "system:serviceaccount:kube-system:generic-garbage-collector"
)


def review(
    pod: dict,
    *,
    operation: str = "CREATE",
    old_pod: dict | None = None,
    subresource: str | None = None,
    resource: dict | None = None,
    username: str = ADMISSION_USER,
) -> dict:
    request = {
        "uid": "test-uid",
        "operation": operation,
        "namespace": "oce-tenant-test",
        "resource": resource or {"group": "", "version": "v1", "resource": "pods"},
        "userInfo": {"username": username},
        "object": pod,
    }
    if old_pod is not None:
        request["oldObject"] = old_pod
    if subresource is not None:
        request["subResource"] = subresource
    return {
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "request": request,
    }


@mock.patch.dict(
    os.environ,
    {
        "OCE_OWNERSHIP_INIT_IMAGE": OWNERSHIP_INIT_IMAGE,
        "OCE_RUNTIME_IMAGES": RUNTIME_IMAGE,
        "OCE_ALLOWED_ADMISSION_USERS": ADMISSION_USER,
        "OCE_ALLOWED_DEPLOYMENT_USERS": DEPLOYMENT_USER,
        "OCE_ALLOWED_REPLICASET_USERS": REPLICASET_USER,
    },
)
class AdmitTests(unittest.TestCase):
    def test_validation_accepts_only_the_trusted_gateway_controller_chain(self) -> None:
        pod = target_pod()
        labels = pod["metadata"]["labels"]
        deployment = {
            "metadata": {
                "name": labels["app.kubernetes.io/name"],
                "labels": {
                    "app.kubernetes.io/managed-by": labels[
                        "app.kubernetes.io/managed-by"
                    ],
                    "openclaw.dev/agent": labels["openclaw.dev/agent"],
                    "openclaw.dev/namespace": labels["openclaw.dev/namespace"],
                },
            },
            "spec": {
                "selector": {
                    "matchLabels": {
                        "app.kubernetes.io/name": labels["app.kubernetes.io/name"]
                    }
                },
                "template": {"metadata": {"labels": labels}, "spec": {}},
            },
        }
        deployment_review = review(
            deployment,
            resource={"group": "apps", "version": "v1", "resource": "deployments"},
            username=DEPLOYMENT_USER,
        )
        self.assertTrue(validate(deployment_review)["response"]["allowed"])

        replicaset = {
            "metadata": {
                "name": f"{labels['app.kubernetes.io/name']}-abc123def",
                "labels": labels,
                "ownerReferences": [
                    {
                        "apiVersion": "apps/v1",
                        "kind": "Deployment",
                        "name": labels["app.kubernetes.io/name"],
                        "uid": "11111111-2222-3333-4444-555555555555",
                        "controller": True,
                    }
                ],
            },
            "spec": {"template": {"metadata": {"labels": labels}}},
        }
        replicaset_review = review(
            replicaset,
            resource={"group": "apps", "version": "v1", "resource": "replicasets"},
            username=REPLICASET_USER,
        )
        self.assertTrue(validate(replicaset_review)["response"]["allowed"])

        for request in (deployment_review, replicaset_review):
            forged = copy.deepcopy(request)
            forged["request"]["userInfo"]["username"] = "tenant-user"
            response = validate(forged)["response"]
            self.assertFalse(response["allowed"])
            self.assertIn("controller identity", response["status"]["message"])

    def test_validation_rejects_deployment_host_sharing(self) -> None:
        pod = target_pod()
        labels = pod["metadata"]["labels"]
        deployment = {
            "metadata": {
                "name": labels["app.kubernetes.io/name"],
                "labels": {
                    "app.kubernetes.io/managed-by": labels[
                        "app.kubernetes.io/managed-by"
                    ],
                    "openclaw.dev/agent": labels["openclaw.dev/agent"],
                    "openclaw.dev/namespace": labels["openclaw.dev/namespace"],
                },
            },
            "spec": {
                "selector": {
                    "matchLabels": {
                        "app.kubernetes.io/name": labels["app.kubernetes.io/name"]
                    }
                },
                "template": {
                    "metadata": {"labels": labels},
                    "spec": {},
                },
            },
        }
        resource = {"group": "apps", "version": "v1", "resource": "deployments"}

        for field in (
            "hostIPC",
            "hostNetwork",
            "hostPID",
            "shareProcessNamespace",
        ):
            with self.subTest(field=field):
                unsafe = copy.deepcopy(deployment)
                unsafe["spec"]["template"]["spec"][field] = True
                response = validate(
                    review(
                        unsafe,
                        resource=resource,
                        username=DEPLOYMENT_USER,
                    )
                )["response"]
                self.assertFalse(response["allowed"])
                self.assertIn(field, response["status"]["message"])

    def test_validation_protects_gateway_revision_configmaps(self) -> None:
        configmap = {
            "metadata": {
                "name": "gateway-b59473701485-rev-deadbeefcafe",
                "labels": {
                    "app.kubernetes.io/managed-by": "openclaw-enterprise",
                    "openclaw.dev/agent": "agt_test",
                    "openclaw.dev/namespace": "ns_test",
                },
            },
            "immutable": True,
            "data": {"openclaw.json": "{}"},
        }
        resource = {"group": "", "version": "v1", "resource": "configmaps"}
        accepted = review(
            configmap,
            resource=resource,
            username=DEPLOYMENT_USER,
        )
        self.assertTrue(validate(accepted)["response"]["allowed"])

        forged = copy.deepcopy(accepted)
        forged["request"]["userInfo"]["username"] = "tenant-user"
        response = validate(forged)["response"]
        self.assertFalse(response["allowed"])
        self.assertIn("controller identity", response["status"]["message"])

        mutable = copy.deepcopy(accepted)
        mutable["request"]["object"]["immutable"] = False
        response = validate(mutable)["response"]
        self.assertFalse(response["allowed"])
        self.assertIn("must be immutable", response["status"]["message"])

        unexpected_key = copy.deepcopy(accepted)
        unexpected_key["request"]["object"]["data"]["extra"] = "unsafe"
        response = validate(unexpected_key)["response"]
        self.assertFalse(response["allowed"])
        self.assertIn("only openclaw.json", response["status"]["message"])

        deletion = copy.deepcopy(accepted)
        deletion["request"]["operation"] = "DELETE"
        deletion["request"]["oldObject"] = deletion["request"].pop("object")
        self.assertTrue(validate(deletion)["response"]["allowed"])

    def test_validation_allows_ordinary_configmaps(self) -> None:
        configmap = {
            "metadata": {"name": "agentgateway-ca"},
            "immutable": True,
            "data": {"ca.crt": "certificate"},
        }
        resource = {"group": "", "version": "v1", "resource": "configmaps"}
        for operation in ("CREATE", "UPDATE", "DELETE"):
            request = review(
                copy.deepcopy(configmap),
                operation=operation,
                resource=resource,
                username="tenant-user",
            )
            if operation == "DELETE":
                request["request"]["oldObject"] = request["request"].pop("object")
            with self.subTest(operation=operation):
                self.assertTrue(validate(request)["response"]["allowed"])

    def test_trusted_worker_can_delete_malformed_revision_configmap(self) -> None:
        configmap = {
            "metadata": {
                "name": "gateway-b59473701485-rev-deadbeefcafe",
                "labels": {},
            },
            "immutable": False,
            "data": {"unexpected": "unsafe"},
        }
        deletion = review(
            configmap,
            operation="DELETE",
            resource={"group": "", "version": "v1", "resource": "configmaps"},
            username=DEPLOYMENT_USER,
        )
        deletion["request"]["oldObject"] = deletion["request"].pop("object")
        self.assertTrue(validate(deletion)["response"]["allowed"])

        untrusted = copy.deepcopy(deletion)
        untrusted["request"]["userInfo"]["username"] = "tenant-user"
        self.assertFalse(validate(untrusted)["response"]["allowed"])

    def test_returns_an_encoded_json_patch(self) -> None:
        response = admit(review(target_pod()))["response"]
        self.assertTrue(response["allowed"])
        self.assertEqual(response["uid"], "test-uid")
        self.assertEqual(response["patchType"], "JSONPatch")
        patch = json.loads(base64.b64decode(response["patch"]))
        self.assertTrue(
            any(operation["path"] == "/spec/runtimeClassName" for operation in patch)
        )

    def test_denies_an_unmatched_workload(self) -> None:
        pod = target_pod()
        pod["metadata"]["labels"]["openclaw.dev/workload-role"] = "controller"
        response = admit(review(pod))["response"]
        self.assertFalse(response["allowed"])
        self.assertEqual(response["status"]["code"], 400)
        self.assertIn("embedded gateway workload", response["status"]["message"])

    def test_denies_an_unsafe_target_pod(self) -> None:
        pod = target_pod()
        pod["spec"]["containers"][-1]["volumeMounts"][-1]["subPathExpr"] = "$x"
        response = admit(review(pod))["response"]
        self.assertFalse(response["allowed"])
        self.assertEqual(response["status"]["code"], 400)
        self.assertIn("subPathExpr", response["status"]["message"])

    def test_validation_denies_ephemeral_container_updates(self) -> None:
        response = validate(
            review(
                target_pod(),
                operation="UPDATE",
                subresource="ephemeralcontainers",
            )
        )["response"]

        self.assertEqual(response["uid"], "test-uid")
        self.assertFalse(response["allowed"])
        self.assertEqual(response["status"]["code"], 403)
        self.assertEqual(response["status"]["reason"], "Forbidden")
        self.assertIn("ephemeral containers", response["status"]["message"])
        self.assertNotIn("patch", response)

    def test_validation_accepts_only_the_final_mutated_contract(self) -> None:
        pod = target_pod()
        final_pod = apply_patch(
            pod, json.loads(base64.b64decode(admit(review(pod))["response"]["patch"]))
        )
        response = validate(review(final_pod))["response"]
        self.assertTrue(response["allowed"])

        final_pod["spec"]["containers"].append(
            {
                "name": "sidecar",
                "image": RUNTIME_IMAGE,
                "securityContext": {},
            }
        )
        response = validate(review(final_pod))["response"]
        self.assertFalse(response["allowed"])

    def test_validation_allows_only_unchanged_regular_pod_updates(self) -> None:
        pod = target_pod()
        final_pod = apply_patch(
            pod, json.loads(base64.b64decode(admit(review(pod))["response"]["patch"]))
        )

        bookkeeping_update = copy.deepcopy(final_pod)
        bookkeeping_update["metadata"].update(
            {
                "creationTimestamp": "2026-11-22T00:00:00Z",
                "generation": 2,
                "managedFields": [{"manager": "kubelet", "operation": "Update"}],
                "resourceVersion": "42",
            }
        )
        response = validate(
            review(
                bookkeeping_update,
                operation="UPDATE",
                old_pod=final_pod,
            )
        )["response"]
        self.assertTrue(response["allowed"])

        changed = copy.deepcopy(final_pod)
        changed["metadata"].setdefault("annotations", {})["attacker.example/test"] = "x"
        response = validate(
            review(changed, operation="UPDATE", old_pod=final_pod)
        )["response"]
        self.assertFalse(response["allowed"])
        self.assertIn("security metadata are immutable", response["status"]["message"])

        changed = copy.deepcopy(final_pod)
        changed["spec"]["activeDeadlineSeconds"] = 60
        response = validate(
            review(changed, operation="UPDATE", old_pod=final_pod)
        )["response"]
        self.assertFalse(response["allowed"])
        self.assertIn("Pod spec is immutable", response["status"]["message"])

    def test_validation_allows_lifecycle_metadata_removal_only(self) -> None:
        pod = target_pod()
        final_pod = apply_patch(
            pod, json.loads(base64.b64decode(admit(review(pod))["response"]["patch"]))
        )

        deleting = copy.deepcopy(final_pod)
        deleting["metadata"]["finalizers"] = ["openclaw.dev/cleanup"]
        removed_finalizer = copy.deepcopy(deleting)
        removed_finalizer["metadata"]["deletionTimestamp"] = "2026-11-22T00:00:00Z"
        removed_finalizer["metadata"]["finalizers"] = []
        response = validate(
            review(
                removed_finalizer,
                operation="UPDATE",
                old_pod=deleting,
            )
        )["response"]
        self.assertTrue(response["allowed"])

        orphaned = copy.deepcopy(final_pod)
        orphaned["metadata"]["ownerReferences"] = []
        response = validate(
            review(
                orphaned,
                operation="UPDATE",
                old_pod=final_pod,
                username=GARBAGE_COLLECTOR_USER,
            )
        )["response"]
        self.assertTrue(response["allowed"])

        controller_orphaned = copy.deepcopy(final_pod)
        controller_orphaned["metadata"]["ownerReferences"] = []
        response = validate(
            review(
                controller_orphaned,
                operation="UPDATE",
                old_pod=final_pod,
                username="system:kube-controller-manager",
            )
        )["response"]
        self.assertTrue(response["allowed"])

    def test_validation_rejects_lifecycle_metadata_addition_or_untrusted_removal(
        self,
    ) -> None:
        pod = target_pod()
        final_pod = apply_patch(
            pod, json.loads(base64.b64decode(admit(review(pod))["response"]["patch"]))
        )

        added_finalizer = copy.deepcopy(final_pod)
        added_finalizer["metadata"]["finalizers"] = ["attacker.example/hold"]
        response = validate(
            review(
                added_finalizer,
                operation="UPDATE",
                old_pod=final_pod,
            )
        )["response"]
        self.assertFalse(response["allowed"])
        self.assertIn("finalizers permit removal only", response["status"]["message"])

        final_pod["metadata"]["finalizers"] = ["openclaw.dev/cleanup"]
        removed_before_deletion = copy.deepcopy(final_pod)
        removed_before_deletion["metadata"]["finalizers"] = []
        response = validate(
            review(
                removed_before_deletion,
                operation="UPDATE",
                old_pod=final_pod,
            )
        )["response"]
        self.assertFalse(response["allowed"])
        self.assertIn(
            "finalizers may be removed only during deletion",
            response["status"]["message"],
        )

        removed_owner = copy.deepcopy(final_pod)
        removed_owner["metadata"]["ownerReferences"] = []
        response = validate(
            review(
                removed_owner,
                operation="UPDATE",
                old_pod=final_pod,
            )
        )["response"]
        self.assertFalse(response["allowed"])
        self.assertIn("owner-reference controllers", response["status"]["message"])

        changed_owner = copy.deepcopy(final_pod)
        changed_owner["metadata"]["ownerReferences"][0]["uid"] = (
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        response = validate(
            review(
                changed_owner,
                operation="UPDATE",
                old_pod=final_pod,
                username=GARBAGE_COLLECTOR_USER,
            )
        )["response"]
        self.assertFalse(response["allowed"])
        self.assertIn(
            "owner references permit removal only",
            response["status"]["message"],
        )

    def test_validation_denies_regular_pod_update_without_old_object(self) -> None:
        pod = target_pod()
        final_pod = apply_patch(
            pod, json.loads(base64.b64decode(admit(review(pod))["response"]["patch"]))
        )
        response = validate(review(final_pod, operation="UPDATE"))["response"]

        self.assertFalse(response["allowed"])
        self.assertIn("old Pod must be an object", response["status"]["message"])

    def test_validation_rejects_post_mutation_contract_changes(self) -> None:
        pod = target_pod()
        final_pod = apply_patch(
            pod,
            json.loads(base64.b64decode(admit(review(pod))["response"]["patch"])),
        )
        cases = []

        changed = copy.deepcopy(final_pod)
        changed["spec"]["initContainers"][1]["args"].append("--dir")
        cases.append(changed)

        changed = copy.deepcopy(final_pod)
        changed["spec"]["initContainers"][2]["command"] = ["/bin/sh"]
        cases.append(changed)

        changed = copy.deepcopy(final_pod)
        changed["spec"]["initContainers"][0]["args"][0] += "\nprocess.exit(0);"
        cases.append(changed)

        changed = copy.deepcopy(final_pod)
        ca_volume = next(
            volume
            for volume in changed["spec"]["volumes"]
            if volume["name"] == "agentgateway-ca"
        )
        ca_volume["configMap"]["name"] = "attacker-ca"
        cases.append(changed)

        for changed in cases:
            with self.subTest(pod=changed):
                response = validate(review(changed))["response"]
                self.assertFalse(response["allowed"])

    def test_rejects_spoofed_admission_identity(self) -> None:
        request = review(target_pod())
        request["request"]["userInfo"]["username"] = (
            "system:serviceaccount:tenant:attacker"
        )
        response = admit(request)["response"]
        self.assertFalse(response["allowed"])
        self.assertIn("controller identity", response["status"]["message"])


class AdmissionHandlerTests(unittest.TestCase):
    def test_validate_path_uses_the_ephemeral_container_denial(self) -> None:
        body = json.dumps(
            review(
                target_pod(),
                operation="UPDATE",
                subresource="ephemeralcontainers",
            )
        ).encode("utf-8")
        handler = AdmissionHandler.__new__(AdmissionHandler)
        handler.path = "/validate"
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = io.BytesIO(body)
        handler._write_json = mock.Mock()
        handler.send_error = mock.Mock()

        handler.do_POST()

        handler.send_error.assert_not_called()
        status, admission_review = handler._write_json.call_args.args
        self.assertEqual(status, 200)
        self.assertFalse(admission_review["response"]["allowed"])
        self.assertEqual(admission_review["response"]["status"]["code"], 403)


if __name__ == "__main__":
    unittest.main()
