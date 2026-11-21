"""Focused lifecycle contracts for cleanup.sh."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
from pathlib import Path
from typing import Any

import pytest

SAMPLE = Path(__file__).resolve().parent.parent
CLEANUP = SAMPLE / "scripts" / "cleanup.sh"
OWNER = "openclaw-enterprise-blueprint"
OCE_OWNER = "openclaw-enterprise"
SOURCE_PIN = "86c8c12310f691bb21651118ffffd6bfd460e9ff"  # pragma: allowlist secret -- public source revision
CONTEXT = "shared-cluster"
ACCOUNT = "111122223333"
REGION = "us-west-2"
CLUSTER_ARN = f"arn:aws:eks:{REGION}:{ACCOUNT}:cluster/{CONTEXT}"
SYSTEM_NAMESPACE = "openclaw-system"
AGW_NAMESPACE = "openclaw-enterprise-agw"
AGW_SERVICE_ACCOUNT = "agentgateway"
ATTEMPT = "attempt-123"
STORAGE_CLASS = "openclaw-enterprise-gp3"
ASSOCIATION_ID = "a-abcdefghijklmnopq"
ROLE_NAME = "openclaw-enterprise-agentgateway"
ROLE_ID = "AROABCDEFGHIJKLMNOPQ"
POLICY_NAME = "openclaw-enterprise-bedrock-invoke"
ROLE_ARN = f"arn:aws:iam::{ACCOUNT}:role/{ROLE_NAME}"
ASSOCIATION_ARN = (
    f"arn:aws:eks:{REGION}:{ACCOUNT}:"
    f"podidentityassociation/{CONTEXT}/{ASSOCIATION_ID}"
)
INVOCATION_ID = "0123456789abcdef0123456789abcdef"
AGW_SETUP_ID = "abcdef0123456789abcdef0123456789"
SETUP_KEY = "openclaw-enterprise.aws.dev/setup-token"
POD_SETUP_KEY = "openclaw.enterprise/setup-invocation"
TENANT_WORKLOADS = (
    "pods,deployments.apps,statefulsets.apps,daemonsets.apps,"
    "jobs.batch,cronjobs.batch,replicasets.apps"
)
AGW_RESOURCE_SPECS = (
    ("namespace", "_", AGW_NAMESPACE, "Namespace"),
    ("serviceaccount", AGW_NAMESPACE, "agentgateway", "ServiceAccount"),
    ("issuer.cert-manager.io", AGW_NAMESPACE, "agentgateway-selfsigned", "Issuer"),
    (
        "certificate.cert-manager.io",
        AGW_NAMESPACE,
        "agentgateway-root",
        "Certificate",
    ),
    ("issuer.cert-manager.io", AGW_NAMESPACE, "agentgateway-ca", "Issuer"),
    (
        "certificate.cert-manager.io",
        AGW_NAMESPACE,
        "agentgateway-serving",
        "Certificate",
    ),
    ("secret", AGW_NAMESPACE, "agw-client-key", "Secret"),
    ("secret", AGW_NAMESPACE, "agw-session-key", "Secret"),
    ("configmap", AGW_NAMESPACE, "agentgateway-config", "ConfigMap"),
    ("deployment.apps", AGW_NAMESPACE, "agentgateway", "Deployment"),
    (
        "poddisruptionbudget.policy",
        AGW_NAMESPACE,
        "agentgateway",
        "PodDisruptionBudget",
    ),
    ("service", AGW_NAMESPACE, "agentgateway", "Service"),
)
RBAC_RESOURCE_SPECS = (
    (
        "clusterrole.rbac.authorization.k8s.io",
        "oce-openclaw-namespace-observer",
        "ClusterRole",
    ),
    (
        "clusterrole.rbac.authorization.k8s.io",
        "oce-openclaw-namespace-worker",
        "ClusterRole",
    ),
    (
        "clusterrole.rbac.authorization.k8s.io",
        "oce-openclaw-tenant-worker",
        "ClusterRole",
    ),
    (
        "clusterrole.rbac.authorization.k8s.io",
        "oce-openclaw-tenant-api",
        "ClusterRole",
    ),
    (
        "clusterrole.rbac.authorization.k8s.io",
        "oce-openclaw-tenant-configuration",
        "ClusterRole",
    ),
    (
        "clusterrole.rbac.authorization.k8s.io",
        "oce-openclaw-gateway-observer",
        "ClusterRole",
    ),
    (
        "clusterrolebinding.rbac.authorization.k8s.io",
        "oce-openclaw-worker-namespaces",
        "ClusterRoleBinding",
    ),
    (
        "clusterrolebinding.rbac.authorization.k8s.io",
        "oce-openclaw-api-namespaces",
        "ClusterRoleBinding",
    ),
)
CLUSTER = {
    "certificate-authority-data": "dGVzdA==",
    "server": "https://cluster.example.test",
}

FAKE_CLI = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import signal
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
state_path = Path(os.environ["FAKE_STATE"])
log_path = Path(os.environ["FAKE_LOG"])
state = json.loads(state_path.read_text())
stdin = sys.stdin.read()

def save():
    state_path.write_text(json.dumps(state))

def log(mutation=False):
    with log_path.open("a") as stream:
        stream.write(json.dumps({
            "tool": tool, "args": args, "stdin": stdin, "mutation": mutation
        }) + "\n")

def object_key(resource, namespace=None):
    return f"{namespace}|{resource}" if namespace else resource

def strip_kube():
    if args[:2] != ["--kubeconfig", state["kubeconfig"]]:
        raise SystemExit("missing explicit kubeconfig")
    if args[2:4] != ["--context", state["context"]]:
        raise SystemExit("wrong context")
    if args[4] != "--request-timeout=20s":
        raise SystemExit("missing request timeout")
    return args[5:]

def metadata(name, uid, namespace=None, owner=None):
    result = {"name": name, "uid": uid, "resourceVersion": "1"}
    if namespace:
        result["namespace"] = namespace
    if owner:
        result["labels"] = {"app.kubernetes.io/managed-by": owner}
    return result

def key_from_raw(path):
    name = path.rsplit("/", 1)[-1]
    if "/serviceaccounts/" in path:
        namespace = path.split("/namespaces/", 1)[1].split("/", 1)[0]
        return f"{namespace}|serviceaccount/{name}"
    if "/configmaps/" in path:
        namespace = path.split("/namespaces/", 1)[1].split("/", 1)[0]
        return f"{namespace}|configmap/{name}"
    if "/secrets/" in path:
        namespace = path.split("/namespaces/", 1)[1].split("/", 1)[0]
        return f"{namespace}|secret/{name}"
    if "/services/" in path:
        namespace = path.split("/namespaces/", 1)[1].split("/", 1)[0]
        return f"{namespace}|service/{name}"
    if "/issuers/" in path:
        namespace = path.split("/namespaces/", 1)[1].split("/", 1)[0]
        return f"{namespace}|issuer.cert-manager.io/{name}"
    if "/certificates/" in path:
        namespace = path.split("/namespaces/", 1)[1].split("/", 1)[0]
        return f"{namespace}|certificate.cert-manager.io/{name}"
    if "/deployments/" in path:
        namespace = path.split("/namespaces/", 1)[1].split("/", 1)[0]
        return f"{namespace}|deployment.apps/{name}"
    if "/poddisruptionbudgets/" in path:
        namespace = path.split("/namespaces/", 1)[1].split("/", 1)[0]
        return f"{namespace}|poddisruptionbudget.policy/{name}"
    if "/namespaces/" in path:
        return f"namespace/{name}"
    if "/storageclasses/" in path:
        return f"storageclass.storage.k8s.io/{name}"
    if "/clusterrolebindings/" in path:
        return f"clusterrolebinding.rbac.authorization.k8s.io/{name}"
    if "/clusterroles/" in path:
        return f"clusterrole.rbac.authorization.k8s.io/{name}"
    if "/mutatingwebhookconfigurations/" in path:
        return (
            "mutatingwebhookconfigurations.admissionregistration.k8s.io/"
            f"{name}"
        )
    if "/validatingwebhookconfigurations/" in path:
        return (
            "validatingwebhookconfigurations.admissionregistration.k8s.io/"
            f"{name}"
        )
    if "/validatingadmissionpolicybindings/" in path:
        return f"validatingadmissionpolicybindings.admissionregistration.k8s.io/{name}"
    if "/validatingadmissionpolicies/" in path:
        return f"validatingadmissionpolicies.admissionregistration.k8s.io/{name}"
    raise SystemExit(f"unknown raw path: {path}")

def kubectl():
    command = strip_kube()
    if command[:4] == ["config", "view", "--minify", "--flatten"]:
        print(json.dumps({
            "current-context": state["context"],
            "clusters": [{"name": state["context"], "cluster": state["cluster"]}],
        }))
        return
    if command[:2] == ["get", "--raw=/readyz"]:
        print("ok")
        return
    if command[:2] == ["get", "persistentvolumeclaims"]:
        print(json.dumps({"items": state.get("pvcs", [])}))
        return
    if command[:2] == ["get", "persistentvolumes"]:
        print(json.dumps({"items": state.get("pvs", [])}))
        return
    if command[:2] == ["get", "namespaces"] and "--selector" in command:
        state["tenantDiscoveryCount"] = state.get("tenantDiscoveryCount", 0) + 1
        mutation = state.get("tenantNamespaceMutation")
        if mutation and state["tenantDiscoveryCount"] == mutation["discovery"]:
            resource = f"namespace/{mutation['name']}"
            if mutation["action"] == "add":
                state["resources"][resource] = {
                    "apiVersion": "v1",
                    "kind": "Namespace",
                    "metadata": metadata(
                        mutation["name"],
                        mutation["uid"],
                        owner=mutation["owner"],
                    ),
                }
            elif mutation["action"] == "replace-uid":
                state["resources"][resource]["metadata"]["uid"] = mutation["uid"]
            else:
                raise SystemExit("unsupported tenant namespace mutation")
            state["tenantNamespaceMutation"] = None
        save()
        selector = command[command.index("--selector") + 1]
        key, value = selector.split("=", 1)
        items = [
            item for resource, item in state["resources"].items()
            if resource.startswith("namespace/")
            and item.get("metadata", {}).get("labels", {}).get(key) == value
        ]
        print(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}))
        return
    if command[:2] == [
        "get",
        (
            "pods,deployments.apps,statefulsets.apps,daemonsets.apps,"
            "jobs.batch,cronjobs.batch,replicasets.apps"
        ),
    ]:
        namespace = command[command.index("--namespace") + 1]
        print(json.dumps({
            "apiVersion": "v1",
            "kind": "List",
            "items": state.get("tenantWorkloads", {}).get(namespace, []),
        }))
        return
    if command[0] == "get":
        resource = command[1]
        namespace = None
        if "--namespace" in command:
            namespace = command[command.index("--namespace") + 1]
        item = state["resources"].get(object_key(resource, namespace))
        if item:
            print(json.dumps(item))
        return
    if command[:2] == ["create", "--dry-run=server"]:
        document = json.loads(stdin)
        namespace = document["metadata"]["namespace"]
        for key, binding in state["resources"].items():
            if not key.startswith(
                "validatingadmissionpolicybindings.admissionregistration.k8s.io/"
            ):
                continue
            policy_name = binding.get("spec", {}).get("policyName")
            if not policy_name:
                continue
            policy_key = (
                "validatingadmissionpolicies.admissionregistration.k8s.io/"
                + policy_name
            )
            policy = state["resources"].get(policy_key)
            if not policy:
                continue
            selector = (
                binding.get("spec", {})
                .get("matchResources", {})
                .get("namespaceSelector", {})
                .get("matchLabels")
            )
            if selector:
                namespace_item = state["resources"].get(f"namespace/{namespace}", {})
                labels = namespace_item.get("metadata", {}).get("labels", {})
                matches = all(labels.get(key) == value for key, value in selector.items())
            else:
                matches = (
                    json.dumps(namespace)
                    in policy["spec"]["matchConditions"][0]["expression"]
                )
            if matches:
                print(policy["spec"]["validations"][0]["message"], file=sys.stderr)
                raise SystemExit(1)
        print(json.dumps(document))
        return
    if command[:2] == ["create", "-f"]:
        document = json.loads(stdin)
        name = document["metadata"]["name"]
        if document["kind"] == "ValidatingAdmissionPolicy":
            prefix = "validatingadmissionpolicies.admissionregistration.k8s.io"
            kind = "policy"
        else:
            prefix = (
                "validatingadmissionpolicybindings."
                "admissionregistration.k8s.io"
            )
            kind = "binding"
        document["metadata"]["uid"] = f"uid-freeze-{kind}"
        document["metadata"]["resourceVersion"] = "1"
        state["resources"][f"{prefix}/{name}"] = document
        state["mutations"] += 1
        boundary = state.get("killAfterFreezeCreate")
        if boundary == kind:
            state["killAfterFreezeCreate"] = None
            save()
            log(True)
            os.kill(os.getppid(), signal.SIGKILL)
            raise SystemExit(0)
        save()
        log(True)
        print(json.dumps(document))
        return
    if command[:2] == ["delete", "--raw"]:
        key = key_from_raw(command[2])
        item = state["resources"].get(key)
        if (
            item
            and key.startswith("namespace/")
            and state.get("failNamespaceDeleteOnce") == key.split("/", 1)[1]
        ):
            state["failNamespaceDeleteOnce"] = None
            save()
            print("simulated namespace deletion failure", file=sys.stderr)
            raise SystemExit(1)
        options = json.loads(stdin)
        expected = options["preconditions"]
        if item and (
            item["metadata"]["uid"] != expected["uid"]
            or item["metadata"]["resourceVersion"] != expected["resourceVersion"]
        ):
            print("Conflict", file=sys.stderr)
            raise SystemExit(1)
        if item:
            del state["resources"][key]
            if key.startswith("namespace/"):
                namespace = key.split("/", 1)[1]
                for child in list(state["resources"]):
                    if child.startswith(f"{namespace}|"):
                        del state["resources"][child]
                state.get("tenantWorkloads", {}).pop(namespace, None)
                state["pvcs"] = [
                    pvc for pvc in state.get("pvcs", [])
                    if pvc.get("metadata", {}).get("namespace") != namespace
                ]
                if namespace not in state.get("retainTenantPvs", []):
                    state["pvs"] = [
                        pv for pv in state.get("pvs", [])
                        if pv.get("spec", {}).get("claimRef", {}).get("namespace")
                        != namespace
                    ]
            state["mutations"] += 1
            save()
        log(bool(item))
        print(json.dumps({"status": "Success"}))
        return
    raise SystemExit(f"unsupported kubectl command: {command}")

def helm():
    if args[:2] != ["--kubeconfig", state["kubeconfig"]]:
        raise SystemExit("missing explicit kubeconfig")
    if args[2:4] != ["--kube-context", state["context"]]:
        raise SystemExit("wrong context")
    command = args[4:]
    if command[0] == "list":
        print(json.dumps([{"name": "oce"}] if state["helm"] else []))
        return
    if command[:2] == ["get", "values"]:
        print(json.dumps({"installationAttempt": state["attempt"]}))
        return
    if command[:2] == ["uninstall", "oce"]:
        changed = state["helm"]
        state["helm"] = False
        if changed:
            state["mutations"] += 1
            save()
        log(changed)
        print("uninstalled")
        return
    raise SystemExit(f"unsupported helm command: {command}")

def aws():
    command = args[:]
    for option in ("--region", "--output"):
        if option in command:
            index = command.index(option)
            del command[index:index + 2]
    action = command[:2]
    data = state["aws"]
    if action == ["sts", "get-caller-identity"]:
        print(json.dumps({"Account": data["account"]}))
        return
    if action == ["eks", "describe-cluster"]:
        print(json.dumps({"cluster": {"arn": data["clusterArn"]}}))
        return
    if action == ["eks", "describe-pod-identity-association"]:
        if data["association"] is None:
            print("ResourceNotFoundException", file=sys.stderr)
            raise SystemExit(1)
        print(json.dumps({"association": data["association"]}))
        return
    if action == ["eks", "delete-pod-identity-association"]:
        if data.get("denyDeleteAssociation"):
            print(
                "AccessDenied: eks:DeletePodIdentityAssociation",
                file=sys.stderr,
            )
            raise SystemExit(1)
        changed = data["association"] is not None
        data["association"] = None
        mutation = state.get("mutateAfterAssociationDelete")
        if mutation:
            item = state["resources"][mutation["resource"]]
            metadata = item.setdefault("metadata", {})
            values = metadata.setdefault(mutation["section"], {})
            values[mutation["key"]] = mutation["value"]
            state["mutateAfterAssociationDelete"] = None
    elif action == ["iam", "get-role"]:
        if data["role"] is None:
            print("NoSuchEntity", file=sys.stderr)
            raise SystemExit(1)
        print(json.dumps({"Role": data["role"]}))
        return
    elif action == ["iam", "get-role-policy"]:
        if data["policyDocument"] is None:
            print("NoSuchEntity", file=sys.stderr)
            raise SystemExit(1)
        data["policyGetCount"] = data.get("policyGetCount", 0) + 1
        mutation = data.get("mutatePolicyOnGet")
        if mutation and data["policyGetCount"] == mutation["count"]:
            data["policyDocument"] = mutation["document"]
            data["mutatePolicyOnGet"] = None
        save()
        print(json.dumps({"PolicyDocument": data["policyDocument"]}))
        return
    elif action == ["iam", "delete-role-policy"]:
        changed = data["policyDocument"] is not None
        data["policyDocument"] = None
    elif action == ["iam", "list-role-policies"]:
        names = [state["policyName"]] if data["policyDocument"] is not None else []
        print(json.dumps({"PolicyNames": names}))
        return
    elif action == ["iam", "list-attached-role-policies"]:
        print(json.dumps({"AttachedPolicies": data.get("attached", [])}))
        return
    elif action == ["iam", "list-instance-profiles-for-role"]:
        print(json.dumps({"InstanceProfiles": data.get("profiles", [])}))
        return
    elif action == ["iam", "delete-role"]:
        if data.get("denyDeleteRole"):
            print("AccessDenied: iam:DeleteRole", file=sys.stderr)
            raise SystemExit(1)
        changed = data["role"] is not None
        data["role"] = None
    else:
        raise SystemExit(f"unsupported aws command: {command}")
    if changed:
        state["mutations"] += 1
        save()
    log(changed)
    print("{}")

if tool == "kubectl":
    kubectl()
elif tool == "helm":
    helm()
elif tool == "aws":
    aws()
else:
    raise SystemExit(f"unknown fake tool: {tool}")
"""


def _object(
    kind: str,
    name: str,
    uid: str,
    *,
    namespace: str | None = None,
    owner: str = OWNER,
    annotations: dict[str, str] | None = None,
    labels: dict[str, str] | None = None,
) -> dict[str, Any]:
    metadata: dict[str, Any] = {
        "name": name,
        "uid": uid,
        "resourceVersion": "1",
        "labels": {"app.kubernetes.io/managed-by": owner},
    }
    if namespace:
        metadata["namespace"] = namespace
    if labels:
        metadata["labels"].update(labels)
    if annotations:
        metadata["annotations"] = annotations
    return {"apiVersion": "v1", "kind": kind, "metadata": metadata}


def _helm_object(kind: str, name: str, uid: str) -> dict[str, Any]:
    item = _object(kind, name, uid, owner="Helm")
    item["metadata"]["labels"]["app.kubernetes.io/instance"] = "oce"
    item["metadata"]["annotations"] = {
        "meta.helm.sh/release-name": "oce",
        "meta.helm.sh/release-namespace": SYSTEM_NAMESPACE,
    }
    return item


def _base_state(kubeconfig: Path) -> dict[str, Any]:
    return {
        "context": CONTEXT,
        "cluster": CLUSTER,
        "kubeconfig": str(kubeconfig),
        "attempt": ATTEMPT,
        "helm": True,
        "mutations": 0,
        "killAfterFreezeCreate": None,
        "tenantDiscoveryCount": 0,
        "tenantNamespaceMutation": None,
        "mutateAfterAssociationDelete": None,
        "tenantWorkloads": {},
        "policyName": POLICY_NAME,
        "pvcs": [],
        "pvs": [],
        "failNamespaceDeleteOnce": None,
        "retainTenantPvs": [],
        "resources": {
            f"namespace/{SYSTEM_NAMESPACE}": _object(
                "Namespace", SYSTEM_NAMESPACE, "uid-system"
            ),
        },
        "aws": {
            "account": ACCOUNT,
            "clusterArn": CLUSTER_ARN,
            "role": None,
            "policyDocument": None,
            "association": None,
            "attached": [],
            "profiles": [],
            "denyDeleteAssociation": False,
            "denyDeleteRole": False,
            "policyGetCount": 0,
            "mutatePolicyOnGet": None,
        },
    }


def _write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value))
    path.chmod(0o600)


def _write_install_evidence(tmp_path: Path, state: dict[str, Any]) -> tuple[Path, Path]:
    state_dir = tmp_path / "state"
    receipt = state_dir / "receipt"
    receipt.mkdir(parents=True)
    state_dir.chmod(0o700)
    receipt.chmod(0o700)
    marker = state_dir / "install.complete"
    marker.write_text(
        f"source={SOURCE_PIN}\n"
        f"cluster_arn={CLUSTER_ARN}\n"
        f"context={CONTEXT}\n"
        f"namespace={SYSTEM_NAMESPACE}\n"
        "release=oce\n"
    )
    marker.chmod(0o600)
    cluster_hash = hashlib.sha256(
        json.dumps(CLUSTER, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    _write_json(receipt / "intent.json", {
        "version": 1,
        "operation": "helm-install",
        "attempt": ATTEMPT,
        "namespace": SYSTEM_NAMESPACE,
        "release": "oce",
        "clusterSha256": cluster_hash,
    })
    _write_json(receipt / "dispatch.json", {"outcome": "unknown"})
    _write_json(receipt / "helm-result.json", {"outcome": "succeeded"})
    admission_resources = {
        (
            "validatingadmissionpolicies.admissionregistration.k8s.io/"
            "protect-openclaw-enterprise-namespace-label"
        ): _object(
            "ValidatingAdmissionPolicy",
            "protect-openclaw-enterprise-namespace-label",
            "uid-namespace-policy",
        ),
        (
            "validatingadmissionpolicybindings.admissionregistration.k8s.io/"
            "protect-openclaw-enterprise-namespace-label"
        ): _object(
            "ValidatingAdmissionPolicyBinding",
            "protect-openclaw-enterprise-namespace-label",
            "uid-namespace-policy-binding",
        ),
        (
            "mutatingwebhookconfigurations.admissionregistration.k8s.io/"
            "openclaw-enterprise-nitro-adapter"
        ): _object(
            "MutatingWebhookConfiguration",
            "openclaw-enterprise-nitro-adapter",
            "uid-mutating-webhook",
        ),
        (
            "validatingwebhookconfigurations.admissionregistration.k8s.io/"
            "openclaw-enterprise-nitro-policy"
        ): _object(
            "ValidatingWebhookConfiguration",
            "openclaw-enterprise-nitro-policy",
            "uid-validating-webhook",
        ),
    }
    rbac_resources = {
        f"{resource}/{name}": _helm_object(kind, name, f"uid-rbac-{index}")
        for index, (resource, name, kind) in enumerate(RBAC_RESOURCE_SPECS)
    }
    state["resources"].update(rbac_resources)
    admission_resources.update(rbac_resources)
    state["resources"].update(admission_resources)
    _write_json(receipt / "resources.json", {
        "version": 1,
        "attempt": ATTEMPT,
        "resources": {
            f"namespace/{SYSTEM_NAMESPACE}": "uid-system",
            **{
                resource: item["metadata"]["uid"]
                for resource, item in admission_resources.items()
            },
        },
    })
    return state_dir, receipt


def _write_lifecycle_receipts(
    tmp_path: Path,
    state: dict[str, Any],
    created: dict[str, bool],
    gateway_reused: set[str] | None = None,
) -> tuple[Path, Path, Path]:
    lifecycle = tmp_path / "lifecycle"
    lifecycle.mkdir()
    lifecycle.chmod(0o700)
    storage = lifecycle / "storage.json"
    _write_json(storage, {
        "version": 1,
        "operation": "setup-storage-class",
        "kubeContext": CONTEXT,
        "clusterEndpoint": CLUSTER["server"],
        "resource": {
            "apiVersion": "storage.k8s.io/v1",
            "kind": "StorageClass",
            "name": STORAGE_CLASS,
            "uid": "uid-storage",
            "created": created["storage"],
        },
    })
    policy_document = {
        "Version": "2012-10-17",
        "Statement": [{"Effect": "Allow", "Action": "bedrock:InvokeModel", "Resource": "*"}],
    }
    role_created = created["role"]
    state["resources"][f"namespace/{AGW_NAMESPACE}"] = _object(
        "Namespace",
        AGW_NAMESPACE,
        "uid-agw",
        labels=(
            {POD_SETUP_KEY: INVOCATION_ID}
            if created["namespace"]
            else None
        ),
    )
    state["resources"][f"{AGW_NAMESPACE}|serviceaccount/agentgateway"] = _object(
        "ServiceAccount",
        "agentgateway",
        "uid-sa",
        namespace=AGW_NAMESPACE,
        labels=(
            {POD_SETUP_KEY: INVOCATION_ID}
            if created["serviceAccount"]
            else None
        ),
    )
    gateway_records = []
    gateway_reused = gateway_reused or set()
    for index, (resource, namespace, name, kind) in enumerate(AGW_RESOURCE_SPECS):
        created_by_gateway = (
            kind not in {"Namespace", "ServiceAccount"}
            and f"{resource}/{name}" not in gateway_reused
        )
        uid = (
            "uid-agw"
            if kind == "Namespace"
            else "uid-sa"
            if kind == "ServiceAccount"
            else f"uid-gateway-{index}"
        )
        gateway_records.append({
            "resource": resource,
            "namespace": namespace,
            "name": name,
            "uid": uid,
            "created": created_by_gateway,
        })
        if kind in {"Namespace", "ServiceAccount"}:
            continue
        state["resources"][f"{namespace}|{resource}/{name}"] = _object(
            kind,
            name,
            uid,
            namespace=namespace,
            annotations=(
                {"openclaw-enterprise.aws.dev/setup-token": AGW_SETUP_ID}
                if created_by_gateway
                else None
            ),
        )
    gateway = lifecycle / "agentgateway.json"
    _write_json(gateway, {
        "version": 1,
        "clusterEndpoint": CLUSTER["server"],
        "namespace": AGW_NAMESPACE,
        "setupId": AGW_SETUP_ID,
        "resources": gateway_records,
    })
    state["resources"][
        f"{AGW_NAMESPACE}|configmap/agentgateway-aws-region"
    ] = _object(
        "ConfigMap",
        "agentgateway-aws-region",
        "uid-region-config-map",
        namespace=AGW_NAMESPACE,
        labels=(
            {POD_SETUP_KEY: INVOCATION_ID}
            if created["regionConfigMap"]
            else None
        ),
    )
    state["resources"][f"storageclass.storage.k8s.io/{STORAGE_CLASS}"] = _object(
        "StorageClass", STORAGE_CLASS, "uid-storage"
    )
    state["aws"]["role"] = {
        "RoleName": ROLE_NAME,
        "Arn": ROLE_ARN,
        "RoleId": ROLE_ID,
        "Tags": (
            [{"Key": "OpenClawSetupInvocation", "Value": INVOCATION_ID}]
            if role_created else []
        ),
    }
    state["aws"]["policyDocument"] = policy_document
    state["aws"]["association"] = {
        "associationId": ASSOCIATION_ID,
        "associationArn": ASSOCIATION_ARN,
        "clusterName": CONTEXT,
        "namespace": AGW_NAMESPACE,
        "serviceAccount": "agentgateway",
        "roleArn": ROLE_ARN,
        "targetRoleArn": None,
        "externalId": None,
        "disableSessionTags": False,
        "policy": None,
    }
    pod = lifecycle / "pod-identity.json"
    _write_json(pod, {
        "version": 2,
        "operation": "setup-agentgateway-pod-identity",
        "target": {
            "kubeContext": CONTEXT,
            "clusterEndpoint": CLUSTER["server"],
            "awsRegion": REGION,
            "awsAccountId": ACCOUNT,
            "eksClusterName": CONTEXT,
            "eksClusterArn": CLUSTER_ARN,
        },
        "resources": {
            "namespace": {
                "apiVersion": "v1",
                "kind": "Namespace",
                "name": AGW_NAMESPACE,
                "uid": "uid-agw",
                "created": created["namespace"],
            },
            "serviceAccount": {
                "apiVersion": "v1",
                "kind": "ServiceAccount",
                "namespace": AGW_NAMESPACE,
                "name": "agentgateway",
                "uid": "uid-sa",
                "created": created["serviceAccount"],
            },
            "regionConfigMap": {
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "namespace": AGW_NAMESPACE,
                "name": "agentgateway-aws-region",
                "uid": "uid-region-config-map",
                "created": created["regionConfigMap"],
            },
            "iamRole": {
                "name": ROLE_NAME,
                "arn": ROLE_ARN,
                "roleId": ROLE_ID,
                "invocationId": INVOCATION_ID,
                "created": role_created,
            },
            "inlinePolicy": {
                "name": POLICY_NAME,
                "roleName": ROLE_NAME,
                "roleId": ROLE_ID,
                "documentSha256": hashlib.sha256(
                    json.dumps(
                        policy_document,
                        sort_keys=True,
                        separators=(",", ":"),
                    ).encode()
                ).hexdigest(),
                "created": created["policy"],
            },
            "podIdentityAssociation": {
                **state["aws"]["association"],
                "invocationId": INVOCATION_ID,
                "created": created["association"],
            },
        },
    })
    return storage, gateway, pod


def _prepare(
    tmp_path: Path,
    *,
    created: dict[str, bool] | None = None,
    gateway_reused: set[str] | None = None,
    kill_after: str | None = None,
) -> tuple[dict[str, Any], list[str], dict[str, str]]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    fake = bin_dir / "fake-cli"
    fake.write_text(FAKE_CLI)
    fake.chmod(0o755)
    for name in ("kubectl", "helm", "aws"):
        (bin_dir / name).symlink_to(fake)
    kubeconfig = tmp_path / "kubeconfig"
    kubeconfig.write_text("test")
    kubeconfig.chmod(0o600)
    state = _base_state(kubeconfig)
    state["killAfterFreezeCreate"] = kill_after
    state_dir, receipt = _write_install_evidence(tmp_path, state)
    command = [
        str(CLEANUP),
        "--kubeconfig", str(kubeconfig),
        "--kube-context", CONTEXT,
        "--state-dir", str(state_dir),
        "--receipt", str(receipt),
    ]
    if created:
        storage, gateway, pod = _write_lifecycle_receipts(
            tmp_path,
            state,
            created,
            gateway_reused,
        )
        command += [
            "--storage-class-receipt", str(storage),
            "--agentgateway-receipt", str(gateway),
            "--agentgateway-pod-identity-receipt", str(pod),
            "--aws-region", REGION,
            "--aws-account-id", ACCOUNT,
            "--eks-cluster-name", CONTEXT,
            "--pod-identity-association-id", ASSOCIATION_ID,
            "--iam-role-name", ROLE_NAME,
            "--iam-inline-policy-name", POLICY_NAME,
        ]
    state_path = tmp_path / "fake-state.json"
    log_path = tmp_path / "fake-log.jsonl"
    state["kubeconfig"] = str(kubeconfig)
    state_path.write_text(json.dumps(state))
    env = {
        **os.environ,
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "FAKE_STATE": str(state_path),
        "FAKE_LOG": str(log_path),
    }
    return state, command, env


def _run(command: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=False,
        env=env,
        text=True,
        capture_output=True,
    )


def _state(env: dict[str, str]) -> dict[str, Any]:
    return json.loads(Path(env["FAKE_STATE"]).read_text())


def _all_created() -> dict[str, bool]:
    return {
        "storage": True,
        "namespace": True,
        "serviceAccount": True,
        "regionConfigMap": True,
        "role": True,
        "policy": True,
        "association": True,
    }


def _add_tenant(
    env: dict[str, str],
    name: str,
    *,
    workloads: list[dict[str, Any]] | None = None,
) -> None:
    state = _state(env)
    state["resources"][f"namespace/{name}"] = _object(
        "Namespace",
        name,
        f"uid-{name}",
        owner=OCE_OWNER,
    )
    if workloads:
        state["tenantWorkloads"][name] = workloads
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))


def _add_tenant_storage(env: dict[str, str], namespace: str) -> None:
    state = _state(env)
    state["pvcs"].append({
        "apiVersion": "v1",
        "kind": "PersistentVolumeClaim",
        "metadata": {
            "name": "openclaw-workspace",
            "namespace": namespace,
            "uid": f"uid-pvc-{namespace}",
        },
        "spec": {
            "storageClassName": STORAGE_CLASS,
            "volumeName": f"pv-{namespace}",
        },
    })
    state["pvs"].append({
        "apiVersion": "v1",
        "kind": "PersistentVolume",
        "metadata": {
            "name": f"pv-{namespace}",
            "uid": f"uid-pv-{namespace}",
        },
        "spec": {
            "claimRef": {
                "name": "openclaw-workspace",
                "namespace": namespace,
                "uid": f"uid-pvc-{namespace}",
            },
        },
    })
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))


def _mutate_tenant_namespace_on_discovery(
    env: dict[str, str],
    *,
    discovery: int,
    action: str,
    name: str,
    uid: str,
) -> None:
    state = _state(env)
    state["tenantNamespaceMutation"] = {
        "discovery": discovery,
        "action": action,
        "name": name,
        "uid": uid,
        "owner": OCE_OWNER,
    }
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))


def test_all_created_resources_are_deleted_and_second_run_is_idempotent(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    first = _run(command, env)
    assert first.returncode == 0, first.stderr
    after_first = _state(env)
    assert after_first["resources"] == {}
    assert after_first["aws"]["association"] is None
    assert after_first["aws"]["policyDocument"] is None
    assert after_first["aws"]["role"] is None
    mutation_count = after_first["mutations"]

    second = _run(command, env)
    assert second.returncode == 0, second.stderr
    assert _state(env)["mutations"] == mutation_count


def test_helm_rbac_ownership_mismatch_fails_before_any_mutation(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    key = (
        "clusterrole.rbac.authorization.k8s.io/"
        "oce-openclaw-tenant-worker"
    )
    state = _state(env)
    state["resources"][key]["metadata"]["labels"][
        "app.kubernetes.io/managed-by"
    ] = "another-installer"
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run(command, env)

    assert result.returncode == 1
    assert (
        "cleanup: clusterrole.rbac.authorization.k8s.io/"
        "oce-openclaw-tenant-worker does not carry an exact cleanup ownership "
        "label.\n"
    ) == result.stderr
    assert _state(env)["mutations"] == 0


def test_iam_delete_denial_occurs_after_kubernetes_cleanup(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    state = _state(env)
    state["aws"]["denyDeleteRole"] = True
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run(command, env)

    assert result.returncode == 1
    assert "AccessDenied: iam:DeleteRole" in result.stderr
    current = _state(env)
    assert current["resources"] == {}
    assert current["aws"]["association"] is None
    assert current["aws"]["policyDocument"] is None
    assert current["aws"]["role"] is not None


def test_association_delete_denial_preserves_kubernetes_identity(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    state = _state(env)
    state["aws"]["denyDeleteAssociation"] = True
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run(command, env)

    assert result.returncode == 1
    assert "AccessDenied: eks:DeletePodIdentityAssociation" in result.stderr
    current = _state(env)
    assert current["aws"]["association"] is not None
    assert f"namespace/{AGW_NAMESPACE}" in current["resources"]
    assert (
        f"{AGW_NAMESPACE}|serviceaccount/{AGW_SERVICE_ACCOUNT}"
        in current["resources"]
    )
    assert current["helm"] is True


def test_tenant_data_requires_explicit_opt_in_before_any_mutation(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    tenant_namespace = "openclaw-tenant-a"
    _add_tenant(env, tenant_namespace)
    state = _state(env)
    state["resources"][f"{tenant_namespace}|secret/user-data"] = _object(
        "Secret",
        "user-data",
        "uid-user-data",
        namespace=tenant_namespace,
        owner="tenant-user",
    )
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run([*command, "--tenant-namespace", tenant_namespace], env)

    assert result.returncode == 1
    assert result.stderr == (
        "cleanup: tenant namespaces may contain user data; cleanup made no "
        "changes. Rerun with --delete-tenant-data to delete the exact listed "
        "tenant namespaces and their data.\n"
    )
    current = _state(env)
    resources = current["resources"]
    assert f"namespace/{tenant_namespace}" in resources
    assert f"{tenant_namespace}|secret/user-data" in resources
    assert current["mutations"] == 0
    assert current["helm"] is True
    assert not (tmp_path / "state" / "cleanup-tenant-deletion.json").exists()


def test_undisclosed_managed_tenant_fails_before_any_mutation(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    _add_tenant(env, "openclaw-tenant-a")
    before = _state(env)

    result = _run(command, env)

    assert result.returncode == 1
    assert result.stderr == (
        "cleanup: the supplied tenant namespace set does not exactly match "
        "the cleanup tenant namespace set (not supplied: openclaw-tenant-a).\n"
    )
    after = _state(env)
    assert after["tenantDiscoveryCount"] == 1
    after["tenantDiscoveryCount"] = before["tenantDiscoveryCount"]
    after["aws"]["policyGetCount"] = before["aws"]["policyGetCount"]
    assert after == before


def test_tenant_added_after_freeze_fails_before_application_teardown(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    tenant_namespace = "openclaw-tenant-a"
    _add_tenant(env, tenant_namespace)
    _mutate_tenant_namespace_on_discovery(
        env,
        discovery=2,
        action="add",
        name="openclaw-tenant-b",
        uid="uid-openclaw-tenant-b",
    )

    result = _run([
        *command,
        "--tenant-namespace",
        tenant_namespace,
        "--delete-tenant-data",
    ], env)

    assert result.returncode == 1
    assert result.stderr == (
        "cleanup: managed tenant namespaces changed during cleanup; "
        "refusing to continue.\n"
    )
    current = _state(env)
    assert current["helm"] is True
    assert current["aws"]["association"] is not None
    assert f"namespace/{SYSTEM_NAMESPACE}" in current["resources"]
    assert f"namespace/{AGW_NAMESPACE}" in current["resources"]
    assert "namespace/openclaw-tenant-a" in current["resources"]
    assert "namespace/openclaw-tenant-b" in current["resources"]
    assert not any(
        "cleanup-tenant-freeze-" in resource
        for resource in current["resources"]
    )


def test_tenant_uid_replaced_after_control_plane_removal_stops_teardown(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    tenant_namespace = "openclaw-tenant-a"
    _add_tenant(env, tenant_namespace)
    _mutate_tenant_namespace_on_discovery(
        env,
        discovery=3,
        action="replace-uid",
        name=tenant_namespace,
        uid="replacement-tenant-uid",
    )

    result = _run([
        *command,
        "--tenant-namespace",
        tenant_namespace,
        "--delete-tenant-data",
    ], env)

    assert result.returncode == 1
    assert result.stderr == (
        "cleanup: managed tenant namespaces changed during cleanup; "
        "refusing to continue.\n"
    )
    current = _state(env)
    assert current["helm"] is False
    assert current["aws"]["association"] is not None
    assert f"namespace/{SYSTEM_NAMESPACE}" in current["resources"]
    assert (
        current["resources"][f"namespace/{tenant_namespace}"]["metadata"]["uid"]
        == "replacement-tenant-uid"
    )
    assert any(
        resource.startswith("clusterrole.rbac.authorization.k8s.io/")
        for resource in current["resources"]
    )
    assert not any(
        "cleanup-tenant-freeze-" in resource
        for resource in current["resources"]
    )


def test_opt_in_deletes_live_tenant_workload_with_namespace(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    tenant_namespace = "openclaw-tenant-a"
    _add_tenant(
        env,
        tenant_namespace,
        workloads=[
            _object(
                "Deployment",
                "openclaw-agent",
                "uid-agent-deployment",
                namespace=tenant_namespace,
                owner=OCE_OWNER,
            )
        ],
    )
    result = _run([
        *command,
        "--tenant-namespace",
        tenant_namespace,
        "--delete-tenant-data",
    ], env)

    assert result.returncode == 0, result.stderr
    after = _state(env)
    assert f"namespace/{tenant_namespace}" not in after["resources"]
    assert not after["tenantWorkloads"].get(tenant_namespace)
    assert not (tmp_path / "state" / "cleanup-tenant-freeze.json").exists()
    assert not any("cleanup-freeze-tenants-" in key for key in after["resources"])


def test_opt_in_deletes_exact_tenant_namespaces_and_storage_idempotently(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    tenants = ["openclaw-tenant-a", "openclaw-tenant-b"]
    for tenant in tenants:
        _add_tenant(env, tenant)
        _add_tenant_storage(env, tenant)
    destructive_command = [
        *command,
        *[
            argument
            for tenant in tenants
            for argument in ("--tenant-namespace", tenant)
        ],
        "--delete-tenant-data",
    ]

    first = _run(destructive_command, env)

    assert first.returncode == 0, first.stderr
    after_first = _state(env)
    assert not any(
        f"namespace/{tenant}" in after_first["resources"]
        for tenant in tenants
    )
    assert after_first["pvcs"] == []
    assert after_first["pvs"] == []
    assert not any(
        "cleanup-freeze-tenants-" in resource
        for resource in after_first["resources"]
    )
    deletion_state_path = tmp_path / "state" / "cleanup-tenant-deletion.json"
    deletion_state = json.loads(deletion_state_path.read_text())
    assert deletion_state["complete"] is True
    assert deletion_state["namespaces"] == [
        {"name": tenant, "uid": f"uid-{tenant}"}
        for tenant in tenants
    ]
    assert deletion_state["persistentVolumes"] == [
        {"name": f"pv-{tenant}", "uid": f"uid-pv-{tenant}"}
        for tenant in tenants
    ]
    assert stat.S_IMODE(deletion_state_path.stat().st_mode) == 0o600
    mutation_count = after_first["mutations"]

    second = _run(destructive_command, env)

    assert second.returncode == 0, second.stderr
    assert _state(env)["mutations"] == mutation_count


def test_partial_tenant_delete_rerun_uses_recorded_uids_and_keeps_controls(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    tenants = ["openclaw-tenant-a", "openclaw-tenant-b"]
    for tenant in tenants:
        _add_tenant(env, tenant)
        _add_tenant_storage(env, tenant)
    state = _state(env)
    state["failNamespaceDeleteOnce"] = "openclaw-tenant-b"
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))
    destructive_command = [
        *command,
        *[
            argument
            for tenant in tenants
            for argument in ("--tenant-namespace", tenant)
        ],
        "--delete-tenant-data",
    ]

    failed = _run(destructive_command, env)

    assert failed.returncode == 1
    assert "simulated namespace deletion failure" in failed.stderr
    partial = _state(env)
    assert "namespace/openclaw-tenant-a" not in partial["resources"]
    assert "namespace/openclaw-tenant-b" in partial["resources"]
    assert partial["helm"] is False
    assert (
        "validatingwebhookconfigurations.admissionregistration.k8s.io/"
        "openclaw-enterprise-nitro-policy"
    ) in partial["resources"]
    assert not any(
        "cleanup-freeze-tenants-" in resource
        for resource in partial["resources"]
    )
    deletion_state = json.loads(
        (tmp_path / "state" / "cleanup-tenant-deletion.json").read_text()
    )
    assert deletion_state["complete"] is False

    recovered = _run(destructive_command, env)

    assert recovered.returncode == 0, recovered.stderr
    final = _state(env)
    assert "namespace/openclaw-tenant-b" not in final["resources"]
    assert final["pvcs"] == []
    assert final["pvs"] == []
    assert json.loads(
        (tmp_path / "state" / "cleanup-tenant-deletion.json").read_text()
    )["complete"] is True


@pytest.mark.parametrize(
    ("tamper", "diagnostic"),
    [
        (
            "uid",
            (
                "cleanup: Deployment/agentgateway does not match its "
                "AgentGateway lifecycle receipt.\n"
            ),
        ),
        (
            "setup-token",
            (
                "cleanup: Deployment/agentgateway does not match its "
                "AgentGateway lifecycle receipt.\n"
            ),
        ),
    ],
)
def test_agentgateway_identity_mismatch_fails_before_any_mutation(
    tmp_path: Path,
    tamper: str,
    diagnostic: str,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    key = f"{AGW_NAMESPACE}|deployment.apps/agentgateway"
    state = _state(env)
    if tamper == "uid":
        state["resources"][key]["metadata"]["uid"] = "replacement-uid"
    else:
        state["resources"][key]["metadata"]["annotations"][SETUP_KEY] = (
            "0123456789abcdef0123456789abcdef"
        )
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run(command, env)

    assert result.returncode == 1
    assert result.stderr == diagnostic
    assert _state(env)["mutations"] == 0


def test_agentgateway_setup_token_drift_stops_late_deletion(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    key = f"{AGW_NAMESPACE}|configmap/agentgateway-config"
    state = _state(env)
    state["mutateAfterAssociationDelete"] = {
        "resource": key,
        "section": "annotations",
        "key": SETUP_KEY,
        "value": "0123456789abcdef0123456789abcdef",
    }
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run(command, env)

    assert result.returncode == 1
    assert result.stderr == (
        "cleanup: ConfigMap/agentgateway-config changed after AgentGateway "
        "cleanup preflight.\n"
    )
    current = _state(env)
    assert key in current["resources"]
    assert current["aws"]["association"] is None
    assert current["aws"]["policyDocument"] is not None
    assert current["aws"]["role"] is not None


def test_pod_identity_namespace_marker_drift_stops_late_deletion(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    key = f"namespace/{AGW_NAMESPACE}"
    state = _state(env)
    state["mutateAfterAssociationDelete"] = {
        "resource": key,
        "section": "labels",
        "key": POD_SETUP_KEY,
        "value": "fedcba9876543210fedcba9876543210",
    }
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run(command, env)

    assert result.returncode == 1
    assert result.stderr == (
        "cleanup: namespace/openclaw-enterprise-agw identity changed before "
        "deletion.\n"
    )
    current = _state(env)
    assert key in current["resources"]
    assert current["aws"]["policyDocument"] is not None
    assert current["aws"]["role"] is not None


def test_inline_policy_drift_stops_late_deletion(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    state = _state(env)
    state["aws"]["mutatePolicyOnGet"] = {
        "count": 2,
        "document": {
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Action": "s3:*",
                "Resource": "*",
            }],
        },
    }
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run(command, env)

    assert result.returncode == 1
    assert result.stderr == (
        "cleanup: inline policy changed after cleanup preflight.\n"
    )
    current = _state(env)
    assert current["aws"]["policyDocument"] is not None
    assert current["aws"]["role"] is not None


def test_reused_agentgateway_dependency_and_identity_are_preserved(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(
        tmp_path,
        created=_all_created(),
        gateway_reused={"secret/agw-session-key"},
    )

    first = _run(command, env)

    assert first.returncode == 0, first.stderr
    after_first = _state(env)
    resources = after_first["resources"]
    assert f"{AGW_NAMESPACE}|secret/agw-session-key" in resources
    assert f"namespace/{AGW_NAMESPACE}" in resources
    assert f"{AGW_NAMESPACE}|serviceaccount/{AGW_SERVICE_ACCOUNT}" in resources
    assert f"{AGW_NAMESPACE}|deployment.apps/agentgateway" in resources
    assert f"{AGW_NAMESPACE}|configmap/agentgateway-aws-region" in resources
    assert after_first["aws"]["association"] is not None
    assert after_first["aws"]["policyDocument"] is not None
    assert after_first["aws"]["role"] is not None
    assert "Preserved the complete AgentGateway dependency closure" in first.stdout
    mutation_count = after_first["mutations"]

    second = _run(command, env)

    assert second.returncode == 0, second.stderr
    assert _state(env)["mutations"] == mutation_count


def test_mixed_provenance_preserves_dependencies_and_rerun_is_idempotent(
    tmp_path: Path,
) -> None:
    created = {
        "storage": False,
        "namespace": True,
        "serviceAccount": True,
        "regionConfigMap": True,
        "role": True,
        "policy": True,
        "association": False,
    }
    _, command, env = _prepare(tmp_path, created=created)
    first = _run(command, env)
    assert first.returncode == 0, first.stderr
    after_first = _state(env)
    assert f"namespace/{AGW_NAMESPACE}" in after_first["resources"]
    assert f"{AGW_NAMESPACE}|serviceaccount/agentgateway" in after_first["resources"]
    assert (
        f"{AGW_NAMESPACE}|configmap/agentgateway-aws-region"
        in after_first["resources"]
    )
    assert after_first["aws"]["association"] is not None
    assert after_first["aws"]["role"] is not None
    assert after_first["aws"]["policyDocument"] is not None
    assert f"storageclass.storage.k8s.io/{STORAGE_CLASS}" in after_first["resources"]
    mutation_count = after_first["mutations"]

    second = _run(command, env)
    assert second.returncode == 0, second.stderr
    assert _state(env)["mutations"] == mutation_count


def test_reused_region_config_map_and_its_namespace_are_preserved(
    tmp_path: Path,
) -> None:
    created = _all_created()
    created["regionConfigMap"] = False
    _, command, env = _prepare(tmp_path, created=created)

    result = _run(command, env)

    assert result.returncode == 0, result.stderr
    resources = _state(env)["resources"]
    assert f"{AGW_NAMESPACE}|configmap/agentgateway-aws-region" in resources
    assert f"namespace/{AGW_NAMESPACE}" in resources
    assert f"{AGW_NAMESPACE}|deployment.apps/agentgateway" in resources
    current = _state(env)
    assert current["aws"]["association"] is not None
    assert current["aws"]["policyDocument"] is not None
    assert current["aws"]["role"] is not None


def test_reused_inline_policy_preserves_complete_dependency_closure(
    tmp_path: Path,
) -> None:
    created = _all_created()
    created["policy"] = False
    _, command, env = _prepare(tmp_path, created=created)
    first = _run(command, env)
    assert first.returncode == 0, first.stderr
    after_first = _state(env)
    assert after_first["aws"]["association"] is not None
    assert after_first["aws"]["policyDocument"] is not None
    assert after_first["aws"]["role"] is not None
    assert f"namespace/{AGW_NAMESPACE}" in after_first["resources"]
    assert f"{AGW_NAMESPACE}|deployment.apps/agentgateway" in after_first["resources"]
    mutation_count = after_first["mutations"]

    second = _run(command, env)
    assert second.returncode == 0, second.stderr
    assert _state(env)["mutations"] == mutation_count


@pytest.mark.parametrize("boundary", ["policy", "binding"])
def test_sigkill_after_freeze_creation_is_recovered_on_rerun(
    tmp_path: Path,
    boundary: str,
) -> None:
    _, command, env = _prepare(tmp_path, kill_after=boundary)
    killed = _run(command, env)
    assert killed.returncode == -9
    freeze_state = tmp_path / "state" / "cleanup-freeze.json"
    assert freeze_state.exists()
    assert stat.S_IMODE(freeze_state.stat().st_mode) == 0o600
    live = _state(env)["resources"]
    assert any("cleanup-freeze-" in key for key in live)

    recovered = _run(command, env)
    assert recovered.returncode == 0, recovered.stderr
    assert not freeze_state.exists()
    assert not any("cleanup-freeze-" in key for key in _state(env)["resources"])


def test_private_freeze_state_mode_is_fail_closed_with_exact_diagnostic(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, kill_after="policy")
    assert _run(command, env).returncode == -9
    freeze_state = tmp_path / "state" / "cleanup-freeze.json"
    freeze_state.chmod(0o644)
    result = _run(command, env)
    assert result.returncode == 1
    assert result.stderr == (
        "cleanup: admission-freeze state must be an owned regular file "
        "with mode 0600.\n"
    )
    assert any("cleanup-freeze-" in key for key in _state(env)["resources"])


def test_recorded_freeze_uid_mismatch_is_fail_closed_with_exact_diagnostic(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, kill_after="binding")
    assert _run(command, env).returncode == -9
    state = _state(env)
    policy_key = next(
        key for key in state["resources"]
        if key.startswith(
            "validatingadmissionpolicies.admissionregistration.k8s.io/"
        )
    )
    state["resources"][policy_key]["metadata"]["uid"] = "replacement-uid"
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))
    result = _run(command, env)
    assert result.returncode == 1
    assert result.stderr == (
        "cleanup: admission-freeze policy identity/UID does not match "
        "private state; refusing deletion.\n"
    )
    assert policy_key in _state(env)["resources"]


def test_lifecycle_target_mismatch_fails_before_any_mutation(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    receipt = tmp_path / "lifecycle" / "pod-identity.json"
    content = json.loads(receipt.read_text())
    content["target"]["awsAccountId"] = "999900001111"
    _write_json(receipt, content)
    result = _run(command, env)
    assert result.returncode == 1
    assert result.stderr == (
        "cleanup: AgentGateway lifecycle receipt does not match "
        "this cleanup target.\n"
    )
    assert _state(env)["mutations"] == 0


def test_region_config_map_uid_mismatch_fails_before_any_mutation(
    tmp_path: Path,
) -> None:
    created = _all_created()
    created["association"] = False
    _, command, env = _prepare(tmp_path, created=created)
    key = f"{AGW_NAMESPACE}|configmap/agentgateway-aws-region"
    state = _state(env)
    state["resources"][key]["metadata"]["uid"] = "replacement-uid"
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run(command, env)

    assert result.returncode == 1
    assert result.stderr == (
        "cleanup: ConfigMap/agentgateway-aws-region does not match its "
        "lifecycle receipt.\n"
    )
    assert _state(env)["mutations"] == 0


def test_reused_storage_class_is_preserved(tmp_path: Path) -> None:
    created = _all_created()
    created["storage"] = False
    _, command, env = _prepare(tmp_path, created=created)
    result = _run(command, env)
    assert result.returncode == 0, result.stderr
    assert f"storageclass.storage.k8s.io/{STORAGE_CLASS}" in _state(env)["resources"]
