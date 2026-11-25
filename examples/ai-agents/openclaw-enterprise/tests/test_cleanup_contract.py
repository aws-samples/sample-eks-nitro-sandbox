"""Focused lifecycle contracts for cleanup.sh."""

from __future__ import annotations

import ast
import hashlib
import importlib.util
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

def admission_defaults(document):
    if document["kind"] == "ValidatingAdmissionPolicy":
        constraints = document["spec"]["matchConstraints"]
        constraints.setdefault("matchPolicy", "Equivalent")
        constraints.setdefault("namespaceSelector", {})
        constraints.setdefault("objectSelector", {})
    elif document["kind"] == "ValidatingAdmissionPolicyBinding":
        match_resources = document["spec"].get("matchResources")
        if match_resources is not None:
            match_resources.setdefault("matchPolicy", "Equivalent")
            match_resources.setdefault("objectSelector", {})

def namespace_frozen(name):
    labels = state["resources"][f"namespace/{name}"]["metadata"].get("labels", {})
    for key, binding in state["resources"].items():
        if "cleanup-freeze-" not in key or binding["kind"] != "ValidatingAdmissionPolicyBinding":
            continue
        policy_name = binding["spec"]["policyName"]
        policy = state["resources"].get(
            "validatingadmissionpolicies.admissionregistration.k8s.io/" + policy_name
        )
        if not policy:
            continue
        selector = binding["spec"].get("matchResources", {}).get(
            "namespaceSelector", {}
        ).get("matchLabels")
        if selector and all(labels.get(k) == v for k, v in selector.items()):
            return True
        if not selector and any(
            json.dumps(name) in condition["expression"]
            for condition in policy["spec"].get("matchConditions", [])
        ):
            return True
    return False

def finalize_namespace(namespace):
    state["resources"].pop(f"namespace/{namespace}", None)
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
            if pv.get("spec", {}).get("claimRef", {}).get("namespace") != namespace
        ]

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
        if item and resource.startswith("namespace/") and state.get("delayedNamespaceDeletion"):
            name = resource.split("/", 1)[1]
            pending = state.get("pendingNamespaceDeletes", {})
            if name in pending:
                if namespace_frozen(name):
                    pending[name] += 1
                    state["namespaceLifecycleEvents"].append(["blocked", name])
                    save()
                    if pending[name] > 1:
                        raise SystemExit("namespace finalization blocked by cleanup freeze")
                elif (
                    item["metadata"].get("deletionTimestamp")
                    and item.get("status", {}).get("phase") == "Terminating"
                ):
                    state["namespaceLifecycleEvents"].append(["finalized", name])
                    finalize_namespace(name)
                    del pending[name]
                    save()
                    return
        if item:
            print(json.dumps(item))
        return
    if command[:2] == ["create", "--dry-run=server"]:
        document = json.loads(stdin)
        admission_defaults(document)
        if document["kind"] in (
            "ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding"
        ):
            print(json.dumps(document))
            return
        namespace = document["metadata"]["namespace"]
        namespace_item = state["resources"].get(f"namespace/{namespace}", {})
        if namespace_item.get("status", {}).get("phase") == "Terminating":
            print(
                f'Forbidden: unable to create new content in namespace "{namespace}" '
                "because it is being terminated",
                file=sys.stderr,
            )
            raise SystemExit(1)
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
        admission_defaults(document)
        name = document["metadata"]["name"]
        if document["kind"] == "ValidatingAdmissionPolicy":
            for index, rule in enumerate(
                document["spec"].get("matchConstraints", {}).get("resourceRules", [])
            ):
                resources = rule.get("resources", [])
                if "*/*" in resources and len(resources) != 1:
                    print(
                        f"spec.matchConstraints.resourceRules[{index}].resources: "
                        "Invalid value: '*/*' cannot be combined with other resources",
                        file=sys.stderr,
                    )
                    raise SystemExit(1)
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
            if key.startswith("namespace/"):
                namespace = key.split("/", 1)[1]
                if state.get("delayedNamespaceDeletion"):
                    item["metadata"]["deletionTimestamp"] = "2026-11-26T00:00:00Z"
                    item["status"] = {"phase": "Terminating"}
                    state.setdefault("pendingNamespaceDeletes", {})[namespace] = 0
                    state.setdefault("namespaceLifecycleEvents", []).append(
                        ["delete-requested", namespace]
                    )
                    tamper = state.get("namespaceDeleteTamper", {})
                    if tamper.get("name") == namespace:
                        if "uid" in tamper:
                            item["metadata"]["uid"] = tamper["uid"]
                        if "phase" in tamper:
                            item["status"]["phase"] = tamper["phase"]
                        if "deletionTimestamp" in tamper:
                            item["metadata"]["deletionTimestamp"] = tamper["deletionTimestamp"]
                else:
                    finalize_namespace(namespace)
            else:
                if "cleanup-freeze-" in key and item["kind"] == "ValidatingAdmissionPolicyBinding":
                    state.setdefault("namespaceLifecycleEvents", []).append(
                        ["binding-deleted", item["metadata"]["name"]]
                    )
                del state["resources"][key]
            state["mutations"] += 1
            save()
        log(bool(item))
        print(json.dumps({"status": "Success"}))
        return
    raise SystemExit(f"unsupported kubectl command: {command}")

def helm():
    if args == ["version", "--short"]:
        print(state.get("helmVersion", "v3.22.1+gd6c1a0e"))
        return
    if args[:2] != ["--kubeconfig", state["kubeconfig"]]:
        raise SystemExit("missing explicit kubeconfig")
    if args[2:4] != ["--kube-context", state["context"]]:
        raise SystemExit("wrong context")
    command = args[4:]
    if command[0] == "list":
        print(json.dumps([{"name": "oce"}] if state["helm"] else []))
        return
    if command[:2] == ["get", "values"]:
        layout = state.get("helmValuesLayout", "current")
        if layout == "current":
            values = {"installation": {"attemptId": state["attempt"]}}
        elif layout == "legacy":
            values = {"installationAttempt": state["attempt"]}
        elif layout == "dual":
            values = {
                "installation": {"attemptId": state["attempt"]},
                "installationAttempt": state["attempt"],
            }
        elif layout == "conflict":
            values = {
                "installation": {"attemptId": state["attempt"]},
                "installationAttempt": "other",
            }
        elif layout == "missing":
            values = {}
        else:
            raise SystemExit("unsupported Helm values layout")
        print(json.dumps(values))
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
        "helmValuesLayout": "current",
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


def test_cleanup_rejects_helm_4_before_mutation(tmp_path: Path) -> None:
    _, command, env = _prepare(tmp_path)
    state = _state(env)
    state["helmVersion"] = "v4.3.0+gbec5b06"
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run(command, env)

    assert result.returncode == 1
    assert "requires Helm 3; found v4.3.0+gbec5b06" in result.stderr
    assert _state(env)["mutations"] == 0


def _add_tenant(
    env: dict[str, str],
    name: str,
    *,
    uid: str | None = None,
    workloads: list[dict[str, Any]] | None = None,
) -> None:
    state = _state(env)
    state["resources"][f"namespace/{name}"] = _object(
        "Namespace",
        name,
        uid or f"uid-{name}",
        owner=OCE_OWNER,
    )
    if workloads:
        state["tenantWorkloads"][name] = workloads
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))


def _tenant_identity_args(*names: str) -> list[str]:
    return [
        argument
        for name in names
        for argument in (
            "--tenant-namespace",
            name,
            "--tenant-namespace-uid",
            f"{name}=uid-{name}",
        )
    ]


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


def _add_validation_database_storage(env: dict[str, str]) -> None:
    state = _state(env)
    state["pvcs"].append({
        "apiVersion": "v1",
        "kind": "PersistentVolumeClaim",
        "metadata": {
            "name": "oce-validation-only-postgres",
            "namespace": SYSTEM_NAMESPACE,
            "uid": "uid-pvc-validation-postgres",
        },
        "spec": {
            "storageClassName": STORAGE_CLASS,
            "volumeName": "pv-validation-postgres",
        },
    })
    state["pvs"].append({
        "apiVersion": "v1",
        "kind": "PersistentVolume",
        "metadata": {
            "name": "pv-validation-postgres",
            "uid": "uid-pv-validation-postgres",
        },
        "spec": {
            "storageClassName": STORAGE_CLASS,
            "claimRef": {
                "name": "oce-validation-only-postgres",
                "namespace": SYSTEM_NAMESPACE,
                "uid": "uid-pvc-validation-postgres",
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


@pytest.mark.parametrize("delete_tenant", [False, True], ids=["system", "tenant"])
def test_cleanup_freeze_policies_use_api_valid_resource_wildcard(
    tmp_path: Path,
    delete_tenant: bool,
) -> None:
    _, command, env = _prepare(tmp_path)
    if delete_tenant:
        tenant = "openclaw-tenant-a"
        _add_tenant(env, tenant)
        command += [*_tenant_identity_args(tenant), "--delete-tenant-data"]

    result = _run(command, env)

    assert result.returncode == 0, result.stderr
    after = _state(env)
    assert after["resources"] == {}
    assert after["helm"] is False
    policies = [
        json.loads(entry["stdin"])
        for line in Path(env["FAKE_LOG"]).read_text().splitlines()
        if (entry := json.loads(line))["tool"] == "kubectl"
        and "create" in entry["args"]
        and "-f" in entry["args"]
        and json.loads(entry["stdin"])["kind"] == "ValidatingAdmissionPolicy"
    ]
    assert len(policies) == (2 if delete_tenant else 1)
    assert any(
        "cleanup-freeze-tenants-" in policy["metadata"]["name"]
        for policy in policies
    ) == delete_tenant
    for policy in policies:
        rules = policy["spec"]["matchConstraints"]["resourceRules"]
        assert len(rules) == 1
        assert rules[0]["resources"] == ["*/*"]
        assert rules[0]["operations"] == ["CREATE", "UPDATE"]
        assert rules[0]["scope"] == "Namespaced"
        assert policy["spec"]["failurePolicy"] == "Fail"

        # Replay the real builder's document with the formerly invalid overlap.
        # The fake API must reject it before assigning a UID or storing anything.
        rules[0]["resources"] = ["*", "*/*"]
        rejected = subprocess.run(
            [
                str(tmp_path / "bin" / "kubectl"),
                "--kubeconfig", str(tmp_path / "kubeconfig"),
                "--context", CONTEXT,
                "--request-timeout=20s",
                "create", "-f", "-",
            ],
            input=json.dumps(policy),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        assert rejected.returncode == 1
        assert rejected.stderr == (
            "spec.matchConstraints.resourceRules[0].resources: "
            "Invalid value: '*/*' cannot be combined with other resources\n"
        )
        assert _state(env) == after


def test_cleanup_removes_local_admin_and_tenant_credentials(tmp_path: Path) -> None:
    _, command, env = _prepare(tmp_path)
    state_dir = tmp_path / "state"
    admin_key = state_dir / "initial-admin-service-key.json"
    _write_json(admin_key, {"key": "admin-key"})
    admin_password = state_dir / "initial-admin-password"
    admin_password.write_text("admin-password")
    admin_password.chmod(0o600)

    namespace = "openclaw-tenant-a"
    _add_tenant(env, namespace)
    validator_dir = tmp_path / "tenant-a"
    validator_dir.mkdir(mode=0o700)
    validator_key = validator_dir / "validator-service-key.json"
    _write_json(validator_key, {"key": "test-validator-key"})
    command += [
        *_tenant_identity_args(namespace),
        "--tenant-validator-key-file",
        str(validator_key),
        "--delete-tenant-data",
    ]

    result = _run(command, env)

    assert result.returncode == 0, result.stderr
    for path in (admin_key, admin_password, validator_key):
        assert not path.exists()
        assert f"Removed local credential: {path}" in result.stdout


def test_hard_linked_validator_key_is_reported_and_preserved_before_mutation(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path)
    namespace = "openclaw-tenant-a"
    _add_tenant(env, namespace)
    validator_dir = tmp_path / "tenant-a"
    validator_dir.mkdir(mode=0o700)
    validator_key = validator_dir / "validator-service-key.json"
    _write_json(validator_key, {"key": "test-validator-key"})
    validator_link = validator_dir / "validator-key-backup.json"
    validator_link.hardlink_to(validator_key)
    command += [
        *_tenant_identity_args(namespace),
        "--tenant-validator-key-file",
        str(validator_key),
        "--delete-tenant-data",
    ]

    result = _run(command, env)

    assert result.returncode == 1
    assert f"local credential remains at {validator_key}" in result.stderr
    assert "every backup or snapshot that contains it" in result.stderr
    assert validator_key.exists()
    assert validator_link.exists()
    assert _state(env)["mutations"] == 0


def test_cleanup_removes_validation_database_storage_with_system_namespace(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    _add_validation_database_storage(env)

    result = _run(command, env)

    assert result.returncode == 0, result.stderr
    current = _state(env)
    assert current["pvcs"] == []
    assert current["pvs"] == []
    assert (
        f"storageclass.storage.k8s.io/{STORAGE_CLASS}"
        not in current["resources"]
    )


@pytest.mark.parametrize("layout", ["legacy", "dual"])
def test_cleanup_accepts_supported_helm_attempt_layouts(
    tmp_path: Path,
    layout: str,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    state = _state(env)
    state["helmValuesLayout"] = layout
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run(command, env)

    assert result.returncode == 0, result.stderr
    current = _state(env)
    assert current["helm"] is False
    assert current["resources"] == {}


def test_cleanup_rejects_conflicting_helm_attempt_layouts_before_mutation(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    state = _state(env)
    state["helmValuesLayout"] = "conflict"
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run(command, env)

    assert result.returncode == 1
    assert result.stderr == (
        "cleanup: live Helm release does not match the OCC receipt attempt.\n"
    )
    assert _state(env)["mutations"] == 0


def test_cleanup_accepts_minimal_helm_clusterrolebinding_labels(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path)
    key = (
        "clusterrolebinding.rbac.authorization.k8s.io/"
        "oce-openclaw-worker-namespaces"
    )
    state = _state(env)
    metadata = state["resources"][key]["metadata"]
    # The upstream chart emits this exact shape; its receipt records the UID.
    metadata["labels"] = {"app.kubernetes.io/managed-by": "Helm"}
    metadata["annotations"] = {
        "meta.helm.sh/release-name": "oce",
        "meta.helm.sh/release-namespace": SYSTEM_NAMESPACE,
    }
    receipt = json.loads(
        (tmp_path / "state" / "receipt" / "resources.json").read_text()
    )
    assert receipt["resources"][key] == metadata["uid"]
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run(command, env)

    assert result.returncode == 0, result.stderr
    current = _state(env)
    assert current["helm"] is False
    assert key not in current["resources"]
    assert current["mutations"] > 0


@pytest.mark.parametrize(
    ("section", "field", "value", "diagnostic"),
    [
        (
            "annotations", "meta.helm.sh/release-name", "foreign-release",
            "does not carry an exact cleanup ownership label.",
        ),
        (
            "annotations", "meta.helm.sh/release-name", None,
            "does not carry an exact cleanup ownership label.",
        ),
        (
            "annotations", "meta.helm.sh/release-namespace", "foreign-namespace",
            "does not carry an exact cleanup ownership label.",
        ),
        (
            "annotations", "meta.helm.sh/release-namespace", None,
            "does not carry an exact cleanup ownership label.",
        ),
        (
            "metadata", "uid", "replacement-uid",
            "does not match the UID recorded in the installation receipt.",
        ),
        (
            "metadata", "uid", None,
            "does not match the UID recorded in the installation receipt.",
        ),
        (
            "receipt", "uid", None,
            "is live but has no UID in the installation receipt.",
        ),
        (
            "labels", "app.kubernetes.io/instance", "foreign-release",
            "does not carry an exact cleanup ownership label.",
        ),
        (
            "labels", "app.kubernetes.io/instance", None,
            "does not carry an exact cleanup ownership label.",
        ),
        (
            "labels", "app.kubernetes.io/managed-by", "another-installer",
            "does not carry an exact cleanup ownership label.",
        ),
        (
            "labels", "app.kubernetes.io/managed-by", None,
            "does not carry an exact cleanup ownership label.",
        ),
    ],
    ids=[
        "foreign-release", "missing-release", "foreign-namespace",
        "missing-namespace", "replacement-uid", "missing-uid",
        "missing-receipt-uid", "wrong-instance", "null-instance",
        "foreign-owner", "missing-owner",
    ],
)
def test_minimal_helm_clusterrolebinding_identity_mismatch_stops_mutations(
    tmp_path: Path,
    section: str,
    field: str,
    value: str | None,
    diagnostic: str,
) -> None:
    _, command, env = _prepare(tmp_path)
    key = (
        "clusterrolebinding.rbac.authorization.k8s.io/"
        "oce-openclaw-worker-namespaces"
    )
    state = _state(env)
    metadata = state["resources"][key]["metadata"]
    metadata["labels"] = {"app.kubernetes.io/managed-by": "Helm"}
    if section == "receipt":
        receipt_path = tmp_path / "state" / "receipt" / "resources.json"
        receipt = json.loads(receipt_path.read_text())
        del receipt["resources"][key]
        _write_json(receipt_path, receipt)
    else:
        target = metadata if section == "metadata" else metadata[section]
        if value is None and field != "app.kubernetes.io/instance":
            target.pop(field)
        else:
            # A present JSON null is distinct from an absent instance label.
            target[field] = value
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run(command, env)

    assert result.returncode == 1
    assert result.stderr == f"cleanup: {key} {diagnostic}\n"
    assert _state(env) == state
    assert state["mutations"] == 0


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


def test_tenant_delete_requires_a_captured_uid_for_every_namespace(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    tenant_namespace = "openclaw-tenant-a"
    _add_tenant(env, tenant_namespace)
    before = _state(env)

    result = _run([
        *command,
        "--tenant-namespace",
        tenant_namespace,
        "--delete-tenant-data",
    ], env)

    assert result.returncode == 1
    assert result.stderr == (
        "cleanup: --delete-tenant-data requires one "
        "--tenant-namespace-uid NAME=UID for every supplied tenant namespace "
        "on the first cleanup attempt.\n"
    )
    after = _state(env)
    after["tenantDiscoveryCount"] = before["tenantDiscoveryCount"]
    after["aws"]["policyGetCount"] = before["aws"]["policyGetCount"]
    assert after == before


def test_replacement_same_name_namespace_fails_before_any_mutation(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, created=_all_created())
    tenant_namespace = "openclaw-tenant-a"
    _add_tenant(env, tenant_namespace, uid="replacement-tenant-uid")
    before = _state(env)

    result = _run([
        *command,
        *_tenant_identity_args(tenant_namespace),
        "--delete-tenant-data",
    ], env)

    assert result.returncode == 1
    assert result.stderr == (
        "cleanup: managed tenant namespaces changed during cleanup; "
        "refusing to continue.\n"
    )
    after = _state(env)
    assert after["tenantDiscoveryCount"] == 2
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
        *_tenant_identity_args(tenant_namespace),
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


def test_tenant_uid_replacement_is_rejected_before_control_plane_removal(
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
        *_tenant_identity_args(tenant_namespace),
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
    assert (
        current["resources"][f"namespace/{tenant_namespace}"]["metadata"]["uid"]
        == "replacement-tenant-uid"
    )
    deletion_state = json.loads(
        (tmp_path / "state" / "cleanup-tenant-deletion.json").read_text()
    )
    assert deletion_state["namespaces"] == [
        {"name": tenant_namespace, "uid": f"uid-{tenant_namespace}"}
    ]
    assert deletion_state["complete"] is False
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
        *_tenant_identity_args(tenant_namespace),
        "--delete-tenant-data",
    ], env)

    assert result.returncode == 0, result.stderr
    assert "No tenant validator key files were supplied" in result.stdout
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
        *_tenant_identity_args(*tenants),
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
        *_tenant_identity_args(*tenants),
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

    retry_command = [
        *command,
        *[
            argument
            for tenant in tenants
            for argument in ("--tenant-namespace", tenant)
        ],
        "--delete-tenant-data",
    ]
    recovered = _run(retry_command, env)

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
            "0123456789abcdef0123456789abcdef"  # pragma: allowlist secret -- test identity
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
        "value": "0123456789abcdef0123456789abcdef",  # pragma: allowlist secret -- test placeholder
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
        "value": "fedcba9876543210fedcba9876543210",  # pragma: allowlist secret -- test identity
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
@pytest.mark.parametrize("delete_tenant", [False, True], ids=["system", "tenant"])
def test_sigkill_after_freeze_creation_is_recovered_on_rerun(
    tmp_path: Path,
    boundary: str,
    delete_tenant: bool,
) -> None:
    _, command, env = _prepare(tmp_path, kill_after=boundary)
    if delete_tenant:
        tenant = "openclaw-tenant-a"
        _add_tenant(env, tenant)
        command += [*_tenant_identity_args(tenant), "--delete-tenant-data"]
    killed = _run(command, env)
    assert killed.returncode == -9
    freeze_state = tmp_path / "state" / (
        "cleanup-tenant-freeze.json" if delete_tenant else "cleanup-freeze.json"
    )
    assert freeze_state.exists()
    assert stat.S_IMODE(freeze_state.stat().st_mode) == 0o600
    live = _state(env)["resources"]
    assert any("cleanup-freeze-" in key for key in live)
    policy = next(
        item for key, item in live.items()
        if "cleanup-freeze-" in key and item["kind"] == "ValidatingAdmissionPolicy"
    )
    constraints = policy["spec"]["matchConstraints"]
    assert constraints["matchPolicy"] == "Equivalent"
    assert constraints["namespaceSelector"] == {}
    assert constraints["objectSelector"] == {}
    if boundary == "binding":
        binding = next(
            item for key, item in live.items()
            if "cleanup-freeze-" in key
            and item["kind"] == "ValidatingAdmissionPolicyBinding"
        )
        if delete_tenant:
            assert binding["spec"]["matchResources"] == {
                "matchPolicy": "Equivalent",
                "namespaceSelector": {
                    "matchLabels": {"app.kubernetes.io/managed-by": OCE_OWNER},
                },
                "objectSelector": {},
            }
        else:
            assert "matchResources" not in binding["spec"]

    recovered = _run(command, env)
    assert recovered.returncode == 0, recovered.stderr
    assert not freeze_state.exists()
    assert not any("cleanup-freeze-" in key for key in _state(env)["resources"])
    assert _state(env)["resources"] == {}


@pytest.mark.parametrize(
    ("delete_tenant", "kind", "tamper"),
    [
        (False, "policy", "match-policy"),
        (True, "policy", "namespace-selector"),
        (True, "binding", "object-selector"),
        (False, "policy", "validation"),
    ],
    ids=[
        "system-match-policy", "tenant-namespace-selector",
        "tenant-binding-object-selector", "system-validation",
    ],
)
def test_server_defaulted_freeze_spec_drift_refuses_recovery(
    tmp_path: Path,
    delete_tenant: bool,
    kind: str,
    tamper: str,
) -> None:
    _, command, env = _prepare(tmp_path, kill_after=kind)
    if delete_tenant:
        tenant = "openclaw-tenant-a"
        _add_tenant(env, tenant)
        command += [*_tenant_identity_args(tenant), "--delete-tenant-data"]
    assert _run(command, env).returncode == -9
    state = _state(env)
    target_kind = (
        "ValidatingAdmissionPolicyBinding"
        if kind == "binding" else "ValidatingAdmissionPolicy"
    )
    item = next(
        item for key, item in state["resources"].items()
        if "cleanup-freeze-" in key and item["kind"] == target_kind
    )
    if tamper == "match-policy":
        item["spec"]["matchConstraints"]["matchPolicy"] = "Exact"
    elif tamper == "namespace-selector":
        item["spec"]["matchConstraints"]["namespaceSelector"] = {
            "matchLabels": {"app.kubernetes.io/managed-by": "foreign-owner"},
        }
    elif tamper == "object-selector":
        item["spec"]["matchResources"]["objectSelector"] = {
            "matchLabels": {"app": "foreign-workload"},
        }
    else:
        item["spec"]["validations"][0]["expression"] = "true"
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run(command, env)

    assert result.returncode == 1
    prefix = "tenant " if delete_tenant else ""
    diagnostic = (
        f"{prefix}admission-freeze {kind} identity/UID does not match "
        "private state; refusing deletion."
    )
    expected_stderr = f"cleanup: {diagnostic}\n"
    if delete_tenant:
        expected_stderr += (
            f"cleanup: failed to remove admission freeze: {diagnostic}\n"
        )
    assert result.stderr == expected_stderr
    current = _state(env)
    assert current["resources"] == state["resources"]
    assert current["mutations"] == state["mutations"]
    assert current["helm"] == state["helm"]


@pytest.mark.parametrize("kind", ["policy", "binding"])
def test_recorded_tenant_freeze_uid_missing_refuses_replacement(
    tmp_path: Path,
    kind: str,
) -> None:
    _, command, env = _prepare(tmp_path, kill_after="binding")
    tenant = "openclaw-tenant-a"
    _add_tenant(env, tenant)
    command += [*_tenant_identity_args(tenant), "--delete-tenant-data"]
    assert _run(command, env).returncode == -9
    state = _state(env)
    target_kind = (
        "ValidatingAdmissionPolicyBinding"
        if kind == "binding" else "ValidatingAdmissionPolicy"
    )
    resource = next(
        key for key, item in state["resources"].items()
        if "cleanup-freeze-tenants-" in key and item["kind"] == target_kind
    )
    journal_path = tmp_path / "state" / "cleanup-tenant-freeze.json"
    journal = json.loads(journal_path.read_text())
    # Model a successfully recorded UID before the object disappears.
    journal[f"{kind}Uid"] = state["resources"][resource]["metadata"]["uid"]
    _write_json(journal_path, journal)
    del state["resources"][resource]
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))
    prior_log = Path(env["FAKE_LOG"]).read_text().splitlines()

    result = _run(command, env)

    assert result.returncode == 1
    assert result.stderr == (
        f"cleanup: recorded tenant admission-freeze {kind} is absent; "
        "refusing replacement.\n"
    )
    current = _state(env)
    assert resource not in current["resources"]
    assert current["helm"] is True
    assert f"namespace/{tenant}" in current["resources"]
    recovery_log = Path(env["FAKE_LOG"]).read_text().splitlines()[len(prior_log):]
    assert not any(
        (entry := json.loads(line))["tool"] == "kubectl"
        and "create" in entry["args"]
        for line in recovery_log
    )


@pytest.mark.parametrize("delete_tenant", [False, True], ids=["system", "tenant"])
def test_namespace_controllers_finalize_only_after_defrost(
    tmp_path: Path,
    delete_tenant: bool,
) -> None:
    _, command, env = _prepare(tmp_path)
    names = ["openclaw-tenant-a", "openclaw-tenant-b"] if delete_tenant else [
        SYSTEM_NAMESPACE
    ]
    if delete_tenant:
        for name in names:
            _add_tenant(env, name)
            _add_tenant_storage(env, name)
        command += [*_tenant_identity_args(*names), "--delete-tenant-data"]
    state = _state(env)
    state["delayedNamespaceDeletion"] = True
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run(command, env)

    assert result.returncode == 0, result.stderr
    current = _state(env)
    assert current["resources"] == {}
    assert current["pvcs"] == []
    assert current["pvs"] == []
    assert current["pendingNamespaceDeletes"] == {}
    events = current["namespaceLifecycleEvents"]
    binding_removed = next(
        index for index, event in enumerate(events)
        if event[0] == "binding-deleted"
    )
    for name in names:
        assert events.index(["delete-requested", name]) < binding_removed
        assert events.index(["blocked", name]) < binding_removed
        assert events.index(["finalized", name]) > binding_removed
    assert not (tmp_path / "state" / "cleanup-freeze.json").exists()
    assert not (tmp_path / "state" / "cleanup-tenant-freeze.json").exists()


@pytest.mark.parametrize("delete_tenant", [False, True], ids=["system", "tenant"])
@pytest.mark.parametrize("tamper", ["uid", "phase", "deletionTimestamp"])
def test_namespace_deletion_transition_rejects_identity_or_lifecycle_drift(
    tmp_path: Path,
    delete_tenant: bool,
    tamper: str,
) -> None:
    _, command, env = _prepare(tmp_path)
    name = "openclaw-tenant-a" if delete_tenant else SYSTEM_NAMESPACE
    if delete_tenant:
        _add_tenant(env, name)
        command += [*_tenant_identity_args(name), "--delete-tenant-data"]
    state = _state(env)
    state["delayedNamespaceDeletion"] = True
    value = {
        "uid": "replacement-uid",
        "phase": "Active",
        "deletionTimestamp": None,
    }[tamper]
    state["namespaceDeleteTamper"] = {"name": name, tamper: value}
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run(command, env)

    assert result.returncode == 1
    diagnostic = (
        "was replaced while deletion was starting."
        if tamper == "uid" else
        "has not entered deletion; refusing to release the admission freeze."
    )
    assert result.stderr.splitlines()[0] == f"cleanup: namespace/{name} {diagnostic}"
    current = _state(env)
    assert f"namespace/{name}" in current["resources"]
    assert ["finalized", name] not in current["namespaceLifecycleEvents"]


def test_namespace_lifecycle_denies_create_without_cleanup_binding(
    tmp_path: Path,
) -> None:
    _, _, env = _prepare(tmp_path)
    state = _state(env)
    namespace = state["resources"][f"namespace/{SYSTEM_NAMESPACE}"]
    namespace["metadata"]["deletionTimestamp"] = "2026-11-26T00:00:00Z"
    namespace["status"] = {"phase": "Terminating"}
    assert not any(
        "cleanup-freeze-" in key for key in state["resources"]
    )
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))
    result = subprocess.run(
        [
            str(tmp_path / "bin" / "kubectl"),
            "--kubeconfig", str(tmp_path / "kubeconfig"),
            "--context", CONTEXT, "--request-timeout=20s",
            "create", "--dry-run=server", "-f", "-",
        ],
        input=json.dumps(_object(
            "ConfigMap", "probe", "probe-uid", namespace=SYSTEM_NAMESPACE,
        )),
        env=env, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 1
    assert "because it is being terminated" in result.stderr
    assert _state(env) == state


@pytest.mark.parametrize(
    ("uid", "phase", "timestamp", "probe_code", "probe_error", "diagnostic"),
    [
        ("target-uid", "Terminating", "2026-11-26T00:00:00Z", 1, "native denial", None),
        ("replacement-uid", "Terminating", "2026-11-26T00:00:00Z", 1, "", "changed while verifying"),
        ("target-uid", "Terminating", None, 1, "", "has not entered deletion"),
        ("target-uid", "Active", "2026-11-26T00:00:00Z", 1, "", "has not entered deletion"),
        ("target-uid", "Terminating", "", 1, "", "has not entered deletion"),
        ("target-uid", "Active", None, 1, "UID-bound freeze denial", None),
        ("target-uid", "Active", None, 1, "because it is being terminated", "could not be verified"),
        ("target-uid", "Active", None, 0, "UID-bound freeze denial", "could not be verified"),
    ],
    ids=[
        "terminating-native-barrier", "replaced-namespace", "phase-only",
        "timestamp-only", "empty-timestamp", "active-freeze-denial",
        "active-native-denial", "active-create-allowed",
    ],
)
def test_tenant_freeze_verification_requires_exact_namespace_barrier(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    uid: str,
    phase: str,
    timestamp: str | None,
    probe_code: int,
    probe_error: str,
    diagnostic: str | None,
) -> None:
    # Execute the production methods, including their shared termination guard.
    source = CLEANUP.read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
    tree = ast.parse(source)
    cleanup_class = next(
        node for node in tree.body
        if isinstance(node, ast.ClassDef) and node.name == "Cleanup"
    )
    cleanup_class.body = [
        node for node in cleanup_class.body
        if isinstance(node, ast.FunctionDef)
        and node.name in {"verify_tenant_freeze", "require_namespace_deletion_started"}
    ]
    definitions = [
        node for node in tree.body
        if isinstance(node, (ast.ClassDef, ast.FunctionDef))
        and node.name in {"CleanupError", "fail"}
    ]
    module_path = tmp_path / "cleanup_namespace_barrier.py"
    module_path.write_text(
        "import json\nimport subprocess\n"
        + ast.unparse(ast.Module(body=[*definitions, cleanup_class], type_ignores=[]))
    )
    spec = importlib.util.spec_from_file_location("cleanup_namespace_barrier", module_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    namespace = vars(module)
    cleanup = namespace["Cleanup"]()
    cleanup.k = ["fake-kubectl"]
    target = {"name": "openclaw-tenant-a", "uid": "target-uid"}
    live = {
        "metadata": {"uid": uid, "deletionTimestamp": timestamp},
        "status": {"phase": phase},
    }
    reads: list[str] = []
    probes: list[dict[str, Any]] = []

    def get(key: str) -> dict[str, Any]:
        reads.append(key)
        assert key == f"namespace/{target['name']}"
        return live

    def run(args: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        assert args == ["fake-kubectl", "create", "--dry-run=server", "-f", "-"]
        probes.append(json.loads(kwargs["input"]))
        return subprocess.CompletedProcess(args, probe_code, "", probe_error)

    cleanup.get = get
    monkeypatch.setattr(subprocess, "run", run)
    state = {"denialMessage": "UID-bound freeze denial"}
    if diagnostic:
        with pytest.raises(namespace["CleanupError"], match=diagnostic):
            cleanup.verify_tenant_freeze(state, [target])
    else:
        cleanup.verify_tenant_freeze(state, [target])
    expected_probes = int(phase == "Active" and timestamp is None)
    assert len(probes) == expected_probes
    if probes:
        assert probes[0]["kind"] == "ConfigMap"
        assert probes[0]["metadata"]["namespace"] == target["name"]
    assert len(reads) == (
        2 if uid == target["uid"] and (phase == "Terminating" or timestamp) else 1
    )


def test_terminating_tenant_retry_recovers_owned_freeze_and_finishes(
    tmp_path: Path,
) -> None:
    _, command, env = _prepare(tmp_path, kill_after="binding")
    tenant = "openclaw-tenant-a"
    _add_tenant(env, tenant)
    _add_tenant_storage(env, tenant)
    command += [*_tenant_identity_args(tenant), "--delete-tenant-data"]
    assert _run(command, env).returncode == -9
    state = _state(env)
    live = state["resources"][f"namespace/{tenant}"]
    live["metadata"]["deletionTimestamp"] = "2026-11-26T00:00:00Z"
    live["status"] = {"phase": "Terminating"}
    state["delayedNamespaceDeletion"] = True
    Path(env["FAKE_STATE"]).write_text(json.dumps(state))

    result = _run(command, env)

    assert result.returncode == 0, result.stderr
    current = _state(env)
    assert current["resources"] == {}
    assert current["pvcs"] == []
    assert current["pvs"] == []
    events = current["namespaceLifecycleEvents"]
    binding_removed = next(
        index for index, event in enumerate(events)
        if event[0] == "binding-deleted"
    )
    assert events.index(["finalized", tenant]) > binding_removed
    assert not (tmp_path / "state" / "cleanup-tenant-freeze.json").exists()


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
