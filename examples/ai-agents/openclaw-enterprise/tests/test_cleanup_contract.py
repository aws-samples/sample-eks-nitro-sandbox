"""Destructive-boundary contracts for the OpenClaw Enterprise cleanup."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import textwrap
from pathlib import Path
from typing import Any

import pytest

SAMPLE = Path(__file__).resolve().parent.parent
CLEANUP = SAMPLE / "scripts" / "cleanup.sh"
OWNER = "openclaw-enterprise-blueprint"
OCE_OWNER = "openclaw-enterprise"
SOURCE_PIN = "86c8c12310f691bb21651118ffffd6bfd460e9ff"
CONTEXT = "shared-cluster"
ACCOUNT = "111122223333"
REGION = "us-west-2"
CLUSTER_ARN = f"arn:aws:eks:{REGION}:{ACCOUNT}:cluster/{CONTEXT}"
SYSTEM_NAMESPACE = "openclaw-system"
RELEASE = "oce"
ATTEMPT = "attempt-123"
STORAGE_CLASS = "openclaw-enterprise-gp3"
ASSOCIATION_ID = "a-abcdefghijklmnopq"
ROLE_NAME = "openclaw-enterprise-agentgateway"
POLICY_NAME = "openclaw-enterprise-bedrock-invoke"
ROLE_ARN = f"arn:aws:iam::{ACCOUNT}:role/{ROLE_NAME}"
ASSOCIATION_ARN = f"arn:aws:eks:{REGION}:{ACCOUNT}:podidentityassociation/{CONTEXT}/{ASSOCIATION_ID}"
FREEZE_PREFIX = "openclaw-enterprise-cleanup-freeze-"
CLUSTER = {"certificate-authority-data": "dGVzdA==", "server": "https://cluster.example.test"}
TENANT_ROLE_BINDINGS = (
    "openclaw-enterprise-worker",
    "openclaw-enterprise-api-secrets",
    "openclaw-enterprise-api-configuration",
)
CLUSTER_RESOURCES = (
    (
        "validatingadmissionpolicies.admissionregistration.k8s.io/"
        "protect-openclaw-enterprise-namespace-label"
    ),
    (
        "validatingadmissionpolicybindings.admissionregistration.k8s.io/"
        "protect-openclaw-enterprise-namespace-label"
    ),
    (
        "mutatingwebhookconfigurations.admissionregistration.k8s.io/"
        "openclaw-enterprise-nitro-adapter"
    ),
    (
        "validatingwebhookconfigurations.admissionregistration.k8s.io/"
        "openclaw-enterprise-nitro-policy"
    ),
)
RELEASE_RESOURCES = (
    *(f"clusterrole.rbac.authorization.k8s.io/{RELEASE}-{name}" for name in (
        "openclaw-namespace-observer",
        "openclaw-namespace-worker",
        "openclaw-tenant-worker",
        "openclaw-tenant-api",
        "openclaw-tenant-configuration",
        "openclaw-gateway-observer",
    )),
    *(f"clusterrolebinding.rbac.authorization.k8s.io/{RELEASE}-{name}" for name in (
        "openclaw-worker-namespaces",
        "openclaw-api-namespaces",
    )),
)
RECEIPT_BOUND_RESOURCES = {
    f"namespace/{SYSTEM_NAMESPACE}",
    "namespace/openclaw-enterprise-adapter",
    "namespace/openclaw-enterprise-agw",
    *CLUSTER_RESOURCES,
    *RELEASE_RESOURCES,
    f"storageclass.storage.k8s.io/{STORAGE_CLASS}",
}

FAKE_CLI = r"""
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
state_path = Path(os.environ["FAKE_STATE"])
state = json.loads(state_path.read_text())
stdin = (
    sys.stdin.read()
    if tool == "kubectl" and ({"create", "delete"} & set(args))
    else ""
)
with Path(os.environ["FAKE_LOG"]).open("a") as log:
    log.write(json.dumps({"tool": tool, "args": args, "stdin": stdin}) + "\n")

def save():
    state_path.write_text(json.dumps(state))

def kube_command():
    if args[:2] != ["--kubeconfig", os.environ["FAKE_KUBECONFIG"]]:
        raise SystemExit("missing explicit kubeconfig")
    index = 2
    if args[index:index + 1] == ["--context"]:
        if args[index + 1] != state["context"]:
            raise SystemExit("wrong context")
        index += 2
    if args[index:index + 1] == ["--request-timeout=20s"]:
        index += 1
    return args[index:]

def resource_key(resource, namespace=""):
    return f"{namespace}|{resource}"

def api_resource_name(resource):
    return {
        "certificate.cert-manager.io": "certificates.cert-manager.io",
        "configmap": "configmaps",
        "deployment.apps": "deployments.apps",
        "endpoint": "endpoints",
        "event": "events",
        "lease.coordination.k8s.io": "leases.coordination.k8s.io",
        "networkpolicy.networking.k8s.io":
            "networkpolicies.networking.k8s.io",
        "pod": "pods",
        "replicaset.apps": "replicasets.apps",
        "rolebinding.rbac.authorization.k8s.io":
            "rolebindings.rbac.authorization.k8s.io",
        "secret": "secrets",
        "service": "services",
        "serviceaccount": "serviceaccounts",
    }.get(resource, resource)

def object_from_record(record, namespace=""):
    labels = record.get("labels")
    if labels is None:
        labels = {
            "app.kubernetes.io/managed-by": record["owner"],
            "app.kubernetes.io/instance": record["instance"],
        }
    metadata = {
        "name": record["name"],
        "labels": labels,
        "annotations": record.get("annotations", {}),
        "ownerReferences": record.get("ownerReferences", []),
        "uid": record["uid"],
        "resourceVersion": record["version"],
    }
    if namespace:
        metadata["namespace"] = namespace
    item = {"metadata": metadata}
    item.update(record.get("objectFields", {}))
    return item

def freeze_denial(namespace):
    if state.get("ignoreFreeze"):
        return None
    for key, binding in state["resources"].items():
        if binding["resource"] != (
            "validatingadmissionpolicybindings.admissionregistration.k8s.io"
        ):
            continue
        binding_spec = binding.get("objectFields", {}).get("spec", {})
        if binding_spec.get("validationActions") != ["Deny"]:
            continue
        policy_name = binding_spec.get("policyName")
        policy = state["resources"].get(
            resource_key(
                "validatingadmissionpolicies.admissionregistration.k8s.io/"
                f"{policy_name}"
            )
        )
        if not policy:
            continue
        policy_spec = policy.get("objectFields", {}).get("spec", {})
        conditions = policy_spec.get("matchConditions", [])
        rules = policy_spec.get("matchConstraints", {}).get(
            "resourceRules", []
        )
        validations = policy_spec.get("validations", [])
        if (
            policy_spec.get("failurePolicy") == "Fail"
            and conditions == [{
                "name": "target-namespace",
                "expression": (
                    f"request.namespace == {json.dumps(namespace)}"
                ),
            }]
            and any(
                "CREATE" in rule.get("operations", [])
                and rule.get("scope") == "Namespaced"
                for rule in rules
            )
            and validations
            and validations[0].get("expression") == "false"
        ):
            return validations[0].get("message")
    return None

if tool == "kubectl":
    command = kube_command()
    if command[:2] == ["config", "get-contexts"]:
        if command[2] == state["context"]:
            print(state["context"])
    elif command[:2] == ["config", "view"]:
        print(json.dumps({"clusters": [{"cluster": state["cluster"]}]}))
    elif command == ["get", "--raw=/readyz"]:
        print("ok")
    elif command[:2] == ["get", "persistentvolumeclaims"]:
        print(json.dumps({"items": state["pvcs"]}))
    elif command[:1] == ["api-resources"]:
        if state.get("discoveryError"):
            print("discovery failed", file=sys.stderr)
            raise SystemExit(1)
        print("\n".join(state["namespacedTypes"]))
    elif command[:1] == ["get"]:
        resource = command[1]
        namespace = (
            command[command.index("--namespace") + 1]
            if "--namespace" in command else ""
        )
        if "--output=json" in command:
            if "/" in resource:
                record = state["resources"].get(
                    resource_key(resource, namespace)
                )
                if record:
                    print(json.dumps(object_from_record(record, namespace)))
                raise SystemExit(0)
            if resource in state.get("inventoryErrors", []):
                print(f"cannot list {resource}", file=sys.stderr)
                raise SystemExit(1)
            items = []
            for key, record in state["resources"].items():
                record_namespace, _, _ = key.partition("|")
                if (
                    record_namespace == namespace
                    and api_resource_name(record["resource"]) == resource
                ):
                    items.append(object_from_record(record, namespace))
            print(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}))
        else:
            record = state["resources"].get(resource_key(resource, namespace))
            if record:
                print("|".join([
                    record["name"], record["owner"], record["instance"],
                    record["uid"], record["version"],
                ]))
    elif command[:1] == ["create"]:
        document = json.loads(stdin)
        kind = document["kind"]
        metadata = document["metadata"]
        namespace = metadata.get("namespace", "")
        if kind == "ConfigMap" and "--dry-run=server" in command:
            denial = freeze_denial(namespace)
            if denial:
                state.setdefault("freezeDenials", []).append(namespace)
                save()
                print(f"admission webhook denied the request: {denial}", file=sys.stderr)
                raise SystemExit(1)
            state.setdefault("acceptedFreezeProbes", []).append(namespace)
            save()
            print(f"configmap/{metadata['name']}")
            raise SystemExit(0)
        resource_kind = {
            "ValidatingAdmissionPolicy":
                "validatingadmissionpolicies.admissionregistration.k8s.io",
            "ValidatingAdmissionPolicyBinding":
                "validatingadmissionpolicybindings.admissionregistration.k8s.io",
        }.get(kind)
        if resource_kind is None:
            raise SystemExit(f"unsupported create kind: {kind}")
        if (
            kind == "ValidatingAdmissionPolicyBinding"
            and state.get("failFreezeBindingCreate")
        ):
            print("injected binding creation failure", file=sys.stderr)
            raise SystemExit(1)
        resource = f"{resource_kind}/{metadata['name']}"
        key = resource_key(resource)
        if key in state["resources"]:
            print("AlreadyExists", file=sys.stderr)
            raise SystemExit(1)
        serial = state.setdefault("createdResourceSerial", 0) + 1
        state["createdResourceSerial"] = serial
        labels = metadata.get("labels", {})
        record = {
            "resource": resource_kind,
            "name": metadata["name"],
            "owner": labels.get("app.kubernetes.io/managed-by", ""),
            "instance": labels.get("app.kubernetes.io/instance", ""),
            "annotations": metadata.get("annotations", {}),
            "labels": labels,
            "objectFields": {
                "apiVersion": document["apiVersion"],
                "kind": kind,
                "spec": document["spec"],
            },
            "ownerReferences": [],
            "uid": f"uid-created-{serial}",
            "version": str(10000 + serial),
            "path": (
                "/apis/admissionregistration.k8s.io/v1/"
                f"{resource_kind.split('.', 1)[0]}/{metadata['name']}"
            ),
            "helm": False,
        }
        state["resources"][key] = record
        save()
        print(json.dumps(object_from_record(record)))
    elif command[:1] == ["delete"] and command[1].startswith("--raw="):
        path = command[1].split("=", 1)[1]
        match = next(
            ((key, value) for key, value in state["resources"].items()
             if value["path"] == path),
            None,
        )
        if match:
            key, record = match
            if state.get("race") == key:
                record["version"] = str(int(record["version"]) + 1)
                state["race"] = None
                save()
            if (
                state.get("freezeDeleteRace")
                and record["resource"].startswith(
                    "validatingadmissionpolicybindings."
                )
            ):
                record["version"] = str(int(record["version"]) + 1)
                state["freezeDeleteRace"] = False
                save()
            preconditions = json.loads(stdin)["preconditions"]
            if preconditions != {
                "uid": record["uid"], "resourceVersion": record["version"]
            }:
                raise SystemExit("Kubernetes precondition failed")
            if state.get("sticky") != key:
                del state["resources"][key]
                if record["resource"] == "namespace":
                    prefix = f"{record['name']}|"
                    state["resources"] = {
                        item_key: value
                        for item_key, value in state["resources"].items()
                        if not item_key.startswith(prefix)
                    }
                save()
    else:
        raise SystemExit(f"unsupported kubectl call: {command}")
elif tool == "helm":
    expected = [
        "--kubeconfig", os.environ["FAKE_KUBECONFIG"],
        "--kube-context", state["context"],
    ]
    if args[:4] != expected:
        raise SystemExit("missing explicit Helm target")
    command = args[4:]
    if command[:1] == ["list"]:
        if state["release"]:
            print(os.environ["FAKE_RELEASE"])
    elif command[:2] == ["get", "values"]:
        print(json.dumps({"installation": {"attemptId": state["attempt"]}}))
    elif command[:1] == ["uninstall"]:
        state["release"] = False
        state["resources"] = {
            key: value for key, value in state["resources"].items()
            if not value.get("helm")
        }
        injected = state.pop("injectAfterHelm", None)
        if injected:
            state["resources"][injected["key"]] = injected["record"]
        save()
    else:
        raise SystemExit(f"unsupported helm call: {command}")
elif tool == "aws":
    if args[:3] != ["--no-cli-pager", "--region", os.environ["FAKE_REGION"]]:
        raise SystemExit("wrong AWS region")
    command = tuple(args[3:5])
    query = args[args.index("--query") + 1] if "--query" in args else ""
    aws = state["aws"]
    if command == ("sts", "get-caller-identity"):
        print(aws["account"])
    elif command == ("eks", "describe-cluster"):
        print(aws["clusterArn"])
    elif command == ("iam", "get-role"):
        if query == "Role.[RoleName,Arn]":
            print(f"{aws['roleName']}\t{aws['roleArn']}")
        else:
            print(aws["roleOwner"])
    elif command == ("iam", "list-role-policies"):
        print("\t".join(aws["policies"]))
    elif command == ("iam", "list-attached-role-policies"):
        print(aws["managedPolicies"])
    elif command == ("iam", "list-instance-profiles-for-role"):
        print(aws["instanceProfiles"])
    elif command == ("eks", "describe-pod-identity-association"):
        if aws["associationDeleted"]:
            print("ResourceNotFoundException", file=sys.stderr)
            raise SystemExit(254)
        print("\t".join([
            aws["clusterName"], aws["associationId"], aws["associationArn"],
            aws["namespace"], aws["serviceAccount"], aws["roleArn"],
            aws["associationOwner"], "None",
        ]))
    elif command == ("eks", "delete-pod-identity-association"):
        aws["associationDeleted"] = True
        save()
    elif command == ("iam", "delete-role-policy"):
        aws["policyDeleted"] = True
        save()
    elif command == ("iam", "delete-role"):
        aws["roleDeleted"] = True
        save()
    else:
        raise SystemExit(f"unsupported aws call: {args}")
else:
    raise SystemExit(f"unexpected fake tool: {tool}")
"""

def _api_path(resource: str, namespace: str = "") -> str:
    kind, name = resource.split("/", 1)
    if kind == "namespace":
        return f"/api/v1/namespaces/{name}"
    core = {
        "secret": "secrets",
        "configmap": "configmaps",
        "endpoint": "endpoints",
        "event": "events",
        "pod": "pods",
        "service": "services",
        "serviceaccount": "serviceaccounts",
    }
    if kind in core:
        return f"/api/v1/namespaces/{namespace}/{core[kind]}/{name}"
    namespaced = {
        "certificate.cert-manager.io": ("cert-manager.io", "certificates"),
        "deployment.apps": ("apps", "deployments"),
        "job.batch": ("batch", "jobs"),
        "lease.coordination.k8s.io": ("coordination.k8s.io", "leases"),
        "networkpolicy.networking.k8s.io": (
            "networking.k8s.io", "networkpolicies"
        ),
        "persistentvolumeclaim": ("", "persistentvolumeclaims"),
        "replicaset.apps": ("apps", "replicasets"),
        "rolebinding.rbac.authorization.k8s.io": (
            "rbac.authorization.k8s.io", "rolebindings"
        ),
    }
    if kind in namespaced:
        group, plural = namespaced[kind]
        if not group:
            return f"/api/v1/namespaces/{namespace}/{plural}/{name}"
        return f"/apis/{group}/v1/namespaces/{namespace}/{plural}/{name}"
    cluster = {
        "mutatingwebhookconfigurations.admissionregistration.k8s.io":
            ("admissionregistration.k8s.io", "mutatingwebhookconfigurations"),
        "validatingadmissionpolicies.admissionregistration.k8s.io":
            ("admissionregistration.k8s.io", "validatingadmissionpolicies"),
        "validatingadmissionpolicybindings.admissionregistration.k8s.io":
            ("admissionregistration.k8s.io", "validatingadmissionpolicybindings"),
        "validatingwebhookconfigurations.admissionregistration.k8s.io":
            ("admissionregistration.k8s.io", "validatingwebhookconfigurations"),
        "storageclass.storage.k8s.io":
            ("storage.k8s.io", "storageclasses"),
        "clusterrole.rbac.authorization.k8s.io":
            ("rbac.authorization.k8s.io", "clusterroles"),
        "clusterrolebinding.rbac.authorization.k8s.io":
            ("rbac.authorization.k8s.io", "clusterrolebindings"),
    }
    group, plural = cluster[kind]
    return f"/apis/{group}/v1/{plural}/{name}"


def _add_resource(
    resources: dict[str, dict[str, Any]],
    resource: str,
    namespace: str = "",
    owner: str = OWNER,
    *,
    annotations: dict[str, str] | None = None,
    labels: dict[str, str] | None = None,
    object_fields: dict[str, Any] | None = None,
    owner_references: list[dict[str, Any]] | None = None,
    helm: bool = False,
) -> None:
    serial = len(resources) + 1
    kind, name = resource.split("/", 1)
    resources[f"{namespace}|{resource}"] = {
        "resource": kind,
        "name": name,
        "owner": owner,
        "instance": RELEASE,
        "annotations": annotations or {},
        "labels": labels,
        "objectFields": object_fields or {},
        "ownerReferences": owner_references or [],
        "uid": f"uid-{serial}",
        "version": str(serial),
        "path": _api_path(resource, namespace),
        "helm": helm,
    }


def _base_state(*, include_sample: bool = True) -> dict[str, Any]:
    resources: dict[str, dict[str, Any]] = {}

    if include_sample:
        _add_resource(resources, f"namespace/{SYSTEM_NAMESPACE}")
        _add_resource(resources, "secret/oce-sample-auth", SYSTEM_NAMESPACE)
        _add_resource(resources, "namespace/openclaw-enterprise-adapter")
        _add_resource(resources, "namespace/openclaw-enterprise-agw")
        _add_resource(
            resources,
            "mutatingwebhookconfigurations.admissionregistration.k8s.io/"
            "openclaw-enterprise-nitro-adapter",
        )
    _add_resource(resources, "namespace/tenant-a", owner=OCE_OWNER)
    _add_resource(resources, "configmap/agentgateway-ca", "tenant-a")
    for name in TENANT_ROLE_BINDINGS:
        if name == "openclaw-enterprise-worker":
            role_name = f"{RELEASE}-openclaw-tenant-worker"
            service_account = "openclaw-enterprise-worker"
        elif name == "openclaw-enterprise-api-secrets":
            role_name = f"{RELEASE}-openclaw-tenant-api"
            service_account = "openclaw-enterprise-api"
        else:
            role_name = f"{RELEASE}-openclaw-tenant-configuration"
            service_account = "openclaw-enterprise-api"
        _add_resource(
            resources,
            f"rolebinding.rbac.authorization.k8s.io/{name}",
            "tenant-a",
            owner="customer",
            labels={},
            object_fields={
                "roleRef": {
                    "apiGroup": "rbac.authorization.k8s.io",
                    "kind": "ClusterRole",
                    "name": role_name,
                },
                "subjects": [{
                    "kind": "ServiceAccount",
                    "name": service_account,
                    "namespace": SYSTEM_NAMESPACE,
                }],
            },
        )
    for name in ("default-deny", "allow-dns", "allow-gateway-ingress"):
        _add_resource(
            resources,
            f"networkpolicy.networking.k8s.io/{name}",
            "tenant-a",
            owner=OCE_OWNER,
        )
    _add_resource(resources, "secret/oce-tenant-state", "tenant-a", owner=OCE_OWNER)
    _add_resource(
        resources,
        f"clusterrole.rbac.authorization.k8s.io/"
        f"{RELEASE}-openclaw-namespace-observer",
        owner="Helm",
        helm=True,
    )
    _add_resource(resources, f"storageclass.storage.k8s.io/{STORAGE_CLASS}")
    return {
        "context": CONTEXT,
        "cluster": CLUSTER,
        "resources": resources,
        "namespacedTypes": [
            "configmaps",
            "events",
            "networkpolicies.networking.k8s.io",
            "rolebindings.rbac.authorization.k8s.io",
            "secrets",
        ],
        "discoveryError": False,
        "inventoryErrors": [],
        "release": True,
        "attempt": ATTEMPT,
        "race": None,
        "sticky": None,
        "freezeDenials": [],
        "acceptedFreezeProbes": [],
        "externalDatabase": "customer-managed-rds",
        "pvcs": [],
        "aws": {
            "account": ACCOUNT,
            "clusterArn": CLUSTER_ARN,
            "clusterName": CONTEXT,
            "roleName": ROLE_NAME,
            "roleArn": ROLE_ARN,
            "roleOwner": OWNER,
            "policies": [POLICY_NAME],
            "managedPolicies": "0",
            "instanceProfiles": "0",
            "associationId": ASSOCIATION_ID,
            "associationArn": ASSOCIATION_ARN,
            "namespace": "openclaw-enterprise-agw",
            "serviceAccount": "agentgateway",
            "associationOwner": OWNER,
            "associationDeleted": False,
            "policyDeleted": False,
            "roleDeleted": False,
        },
    }

def _write_executable(path: Path, source: str) -> None:
    path.write_text(textwrap.dedent(source).lstrip())
    path.chmod(path.stat().st_mode | stat.S_IXUSR)

def _write_evidence(
    tmp_path: Path,
    state: dict[str, Any],
    outcome: str,
    *,
    receipt_uid_overrides: dict[str, str] | None = None,
    omit_receipt_resources: set[str] | None = None,
) -> tuple[Path, Path, Path]:
    kubeconfig = tmp_path / "kubeconfig"
    kubeconfig.write_text("test")
    kubeconfig.chmod(0o600)
    state_dir = tmp_path / "state"
    receipt = state_dir / "receipt"
    receipt.mkdir(parents=True)
    state_dir.chmod(0o700)
    receipt.chmod(0o700)
    marker = state_dir / "install.complete"
    marker.write_text(
        f"source={SOURCE_PIN}\ncluster_arn={CLUSTER_ARN}\n"
        f"context={CONTEXT}\nnamespace={SYSTEM_NAMESPACE}\nrelease={RELEASE}\n"
    )
    intent = {
        "version": 1,
        "operation": "helm-install",
        "attempt": ATTEMPT,
        "createdAt": "2026-11-18T00:00:00Z",
        "clusterSha256": hashlib.sha256(
            json.dumps(CLUSTER, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest(),
        "namespace": SYSTEM_NAMESPACE,
        "release": RELEASE,
        "chartSha256": "a" * 64,
        "valuesSha256": "b" * 64,
    }
    files = {
        "intent.json": intent,
        "dispatch.json": {"outcome": "unknown"},
        "helm-result.json": {"outcome": outcome},
        "resources.json": {
            "version": 1,
            "attempt": ATTEMPT,
            "resources": {
                resource: (receipt_uid_overrides or {}).get(
                    resource, record["uid"]
                )
                for record in state["resources"].values()
                if (resource := f"{record['resource']}/{record['name']}")
                in RECEIPT_BOUND_RESOURCES
                and resource not in (omit_receipt_resources or set())
            },
        },
    }
    for name, value in files.items():
        path = receipt / name
        path.write_text(json.dumps(value))
        path.chmod(0o600)
    marker.chmod(0o600)
    return kubeconfig, state_dir, receipt

def _run(
    tmp_path: Path,
    state: dict[str, Any],
    *,
    outcome: str = "succeeded",
    aws: bool = False,
    receipt_uid_overrides: dict[str, str] | None = None,
    omit_receipt_resources: set[str] | None = None,
) -> tuple[subprocess.CompletedProcess[str], dict[str, Any], list[dict[str, Any]]]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    dispatcher = bin_dir / "fake-cli"
    _write_executable(dispatcher, FAKE_CLI)
    for tool in ("kubectl", "helm", "aws"):
        (bin_dir / tool).symlink_to(dispatcher)
    _write_executable(bin_dir / "sleep", "#!/bin/sh\nexit 0\n")
    kubeconfig, state_dir, receipt = _write_evidence(
        tmp_path,
        state,
        outcome,
        receipt_uid_overrides=receipt_uid_overrides,
        omit_receipt_resources=omit_receipt_resources,
    )
    state_path = tmp_path / "state.json"
    state_path.write_text(json.dumps(state))
    log_path = tmp_path / "calls.jsonl"
    log_path.write_text("")
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("HELM_KUBE") and key != "HELM_DRIVER"
    }
    env.update({
        "PATH": f"{bin_dir}{os.pathsep}{env['PATH']}",
        "FAKE_STATE": str(state_path),
        "FAKE_LOG": str(log_path),
        "FAKE_KUBECONFIG": str(kubeconfig),
        "FAKE_RELEASE": RELEASE,
        "FAKE_REGION": REGION,
    })
    command = [
        "bash", str(CLEANUP),
        "--kubeconfig", str(kubeconfig),
        "--kube-context", CONTEXT,
        "--state-dir", str(state_dir),
        "--receipt", str(receipt),
        "--tenant-namespace", "tenant-a",
    ]
    if aws:
        command += [
            "--aws-region", REGION,
            "--aws-account-id", ACCOUNT,
            "--eks-cluster-name", CONTEXT,
            "--pod-identity-association-id", ASSOCIATION_ID,
            "--iam-role-name", ROLE_NAME,
            "--iam-inline-policy-name", POLICY_NAME,
        ]
    result = subprocess.run(
        command,
        capture_output=True,
        check=False,
        text=True,
        env=env,
        timeout=60,
    )
    final = json.loads(state_path.read_text())
    calls = [json.loads(line) for line in log_path.read_text().splitlines()]
    return result, final, calls

def _mutations(calls: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        call for call in calls
        if "delete" in call["args"]
        or "create" in call["args"]
        or "patch" in call["args"]
        or "uninstall" in call["args"]
    ]


def _freeze_resources(state: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        record for record in state["resources"].values()
        if record["name"].startswith(FREEZE_PREFIX)
    ]


def test_requires_explicit_receipt_bound_target_arguments() -> None:
    result = subprocess.run(
        ["bash", str(CLEANUP)], capture_output=True, check=False, text=True
    )
    assert result.returncode != 0
    assert "--kubeconfig is required" in result.stderr

def test_complete_cleanup_removes_tenant_and_preserves_external_state(
    tmp_path: Path,
) -> None:
    state = _base_state()
    result, final, calls = _run(tmp_path, state)
    assert result.returncode == 0, result.stderr
    assert final["externalDatabase"] == "customer-managed-rds"
    assert "|namespace/tenant-a" not in final["resources"]
    assert not any(key.startswith("tenant-a|") for key in final["resources"])
    assert "tenant-a|configmap/agentgateway-ca" not in final["resources"]
    for name in TENANT_ROLE_BINDINGS:
        assert (
            f"tenant-a|rolebinding.rbac.authorization.k8s.io/{name}"
            not in final["resources"]
        )
    assert f"|storageclass.storage.k8s.io/{STORAGE_CLASS}" not in final["resources"]
    assert final["release"] is False
    assert _freeze_resources(final) == []
    assert set(final["freezeDenials"]) == {
        "tenant-a",
        "openclaw-enterprise-adapter",
        "openclaw-enterprise-agw",
        SYSTEM_NAMESPACE,
    }
    assert final["acceptedFreezeProbes"] == []

    freeze_creates = [
        (index, json.loads(call["stdin"]))
        for index, call in enumerate(calls)
        if call["tool"] == "kubectl"
        and "create" in call["args"]
        and call["stdin"]
    ]
    policies = [
        (index, document)
        for index, document in freeze_creates
        if document["kind"] == "ValidatingAdmissionPolicy"
    ]
    bindings = [
        document for _, document in freeze_creates
        if document["kind"] == "ValidatingAdmissionPolicyBinding"
    ]
    probes = [
        (index, document)
        for index, document in freeze_creates
        if document["kind"] == "ConfigMap"
    ]
    assert len(policies) == len(bindings) == len(probes) == 4
    policy_annotations = {
        policy["metadata"]["name"]: policy["metadata"]["annotations"]
        for _, policy in policies
    }
    for _, policy in policies:
        token = policy["metadata"]["annotations"][
            "openclaw-enterprise.aws/cleanup-token"
        ]
        assert len(token) == 32
        assert set(token) <= set("0123456789abcdef")
        namespace = policy["metadata"]["annotations"][
            "openclaw-enterprise.aws/target-namespace"
        ]
        assert policy["metadata"]["labels"] == {
            "app.kubernetes.io/managed-by": OWNER,
            "app.kubernetes.io/instance": RELEASE,
        }
        assert policy["spec"]["failurePolicy"] == "Fail"
        assert policy["spec"]["matchConditions"] == [{
            "name": "target-namespace",
            "expression": f"request.namespace == {json.dumps(namespace)}",
        }]
        assert policy["spec"]["matchConstraints"] == {
            "matchPolicy": "Equivalent",
            "resourceRules": [{
                "apiGroups": ["*"],
                "apiVersions": ["*"],
                "operations": ["CREATE", "UPDATE"],
                "resources": ["*/*"],
                "scope": "Namespaced",
            }],
        }
        assert "DELETE" not in policy["spec"]["matchConstraints"][
            "resourceRules"
        ][0]["operations"]
    for binding in bindings:
        assert binding["metadata"]["annotations"] == policy_annotations[
            binding["metadata"]["name"]
        ]
        assert binding["spec"] == {
            "policyName": binding["metadata"]["name"],
            "validationActions": ["Deny"],
        }

    probe_by_namespace = {
        document["metadata"]["namespace"]: index
        for index, document in probes
    }
    for namespace, probe_index in probe_by_namespace.items():
        namespace_delete = next(
            index for index, call in enumerate(calls)
            if call["tool"] == "kubectl"
            and f"--raw={_api_path(f'namespace/{namespace}')}" in call["args"]
        )
        assert probe_index < namespace_delete

    raw_deletes = [
        call for call in calls
        if call["tool"] == "kubectl"
        and "delete" in call["args"]
        and call["stdin"]
    ]
    assert raw_deletes
    for call in raw_deletes:
        options = json.loads(call["stdin"])
        assert set(options["preconditions"]) == {"uid", "resourceVersion"}
        assert all(options["preconditions"].values())
        assert not {"--all", "--selector", "-l"} & set(call["args"])

    helm_lists = [
        call for call in calls
        if call["tool"] == "helm" and call["args"][4:5] == ["list"]
    ]
    assert helm_lists
    for call in helm_lists:
        args = set(call["args"])
        assert "--all" not in args
        assert {
            "--deployed",
            "--failed",
            "--pending",
            "--uninstalled",
            "--superseded",
            "--uninstalling",
        } <= args


def test_unowned_tenant_descendant_blocks_cleanup_before_mutation(
    tmp_path: Path,
) -> None:
    state = _base_state()
    _add_resource(
        state["resources"],
        "secret/customer-managed",
        "tenant-a",
        owner="customer",
    )

    result, final, calls = _run(tmp_path, state)

    assert result.returncode != 0
    assert "descendants without exact sample ownership metadata" in result.stderr
    assert "secrets/customer-managed" in result.stderr
    assert "tenant-a|secret/customer-managed" in final["resources"]
    assert "|namespace/tenant-a" in final["resources"]
    assert _mutations(calls) == []


def test_new_unowned_descendant_after_helm_blocks_namespace_deletion(
    tmp_path: Path,
) -> None:
    state = _base_state()
    injected_resources: dict[str, dict[str, Any]] = {}
    _add_resource(
        injected_resources,
        "secret/customer-created-during-cleanup",
        "tenant-a",
        owner="customer",
    )
    key, record = next(iter(injected_resources.items()))
    state["injectAfterHelm"] = {"key": key, "record": record}

    result, final, calls = _run(tmp_path, state)

    assert result.returncode != 0
    assert "descendants without exact sample ownership metadata" in result.stderr
    assert "secrets/customer-created-during-cleanup" in result.stderr
    assert final["release"] is False
    assert key in final["resources"]
    assert "|namespace/tenant-a" in final["resources"]
    assert final["freezeDenials"] == ["tenant-a"]
    assert final["acceptedFreezeProbes"] == []
    assert _freeze_resources(final) == []
    assert not any(
        call["tool"] == "kubectl"
        and f"--raw={_api_path('namespace/tenant-a')}" in call["args"]
        for call in calls
    )
    assert sum(
        call["tool"] == "kubectl" and "api-resources" in call["args"]
        for call in calls
    ) >= 2


def test_freeze_verification_failure_is_closed_and_cleaned(
    tmp_path: Path,
) -> None:
    state = _base_state()
    state["ignoreFreeze"] = True

    result, final, calls = _run(tmp_path, state)

    assert result.returncode != 0
    assert "repeatedly accepted object creation" in result.stderr
    assert final["acceptedFreezeProbes"] == ["tenant-a"] * 10
    assert "|namespace/tenant-a" in final["resources"]
    assert _freeze_resources(final) == []
    assert not any(
        call["tool"] == "kubectl"
        and f"--raw={_api_path('namespace/tenant-a')}" in call["args"]
        for call in calls
    )


def test_partial_freeze_setup_removes_created_policy(
    tmp_path: Path,
) -> None:
    state = _base_state()
    state["failFreezeBindingCreate"] = True

    result, final, calls = _run(tmp_path, state)

    assert result.returncode != 0
    assert "could not create the namespace admission freeze binding" in (
        result.stderr
    )
    assert "|namespace/tenant-a" in final["resources"]
    assert _freeze_resources(final) == []
    policy_delete = next(
        call for call in calls
        if call["tool"] == "kubectl"
        and "delete" in call["args"]
        and "validatingadmissionpolicies" in " ".join(call["args"])
    )
    assert set(json.loads(policy_delete["stdin"])["preconditions"]) == {
        "uid",
        "resourceVersion",
    }


def test_freeze_cleanup_retries_with_fresh_resource_version_and_fails_closed(
    tmp_path: Path,
) -> None:
    state = _base_state()
    state["freezeDeleteRace"] = True

    result, final, calls = _run(tmp_path, state)

    assert result.returncode != 0
    assert "could not remove the namespace admission freeze" in result.stderr
    assert _freeze_resources(final) == []
    binding_deletes = [
        call for call in calls
        if call["tool"] == "kubectl"
        and "delete" in call["args"]
        and "validatingadmissionpolicybindings" in " ".join(call["args"])
    ]
    assert len(binding_deletes) == 2
    versions = [
        json.loads(call["stdin"])["preconditions"]["resourceVersion"]
        for call in binding_deletes
    ]
    assert int(versions[1]) == int(versions[0]) + 1


@pytest.mark.parametrize(
    "resource",
    [
        f"namespace/{SYSTEM_NAMESPACE}",
        (
            "mutatingwebhookconfigurations.admissionregistration.k8s.io/"
            "openclaw-enterprise-nitro-adapter"
        ),
        (
            f"clusterrole.rbac.authorization.k8s.io/"
            f"{RELEASE}-openclaw-namespace-observer"
        ),
        f"storageclass.storage.k8s.io/{STORAGE_CLASS}",
    ],
)
def test_receipt_uid_mismatch_rejects_replacement_before_mutation(
    tmp_path: Path,
    resource: str,
) -> None:
    state = _base_state()
    result, final, calls = _run(
        tmp_path,
        state,
        receipt_uid_overrides={resource: "uid-from-installation"},
    )
    assert result.returncode != 0
    assert "does not match the UID recorded in the installation receipt" in result.stderr
    assert any(
        f"{record['resource']}/{record['name']}" == resource
        for record in final["resources"].values()
    )
    assert _mutations(calls) == []


def test_live_receipt_bound_resource_requires_receipt_entry(
    tmp_path: Path,
) -> None:
    state = _base_state()
    resource = (
        "mutatingwebhookconfigurations.admissionregistration.k8s.io/"
        "openclaw-enterprise-nitro-adapter"
    )
    result, _, calls = _run(
        tmp_path,
        state,
        omit_receipt_resources={resource},
    )
    assert result.returncode != 0
    assert "is live but has no UID in the installation receipt" in result.stderr
    assert _mutations(calls) == []


def test_receipt_uid_does_not_replace_cluster_resource_label_check(
    tmp_path: Path,
) -> None:
    state = _base_state()
    key = (
        "|mutatingwebhookconfigurations.admissionregistration.k8s.io/"
        "openclaw-enterprise-nitro-adapter"
    )
    state["resources"][key]["owner"] = "customer"
    result, _, calls = _run(tmp_path, state)
    assert result.returncode != 0
    assert "does not carry the exact" in result.stderr
    assert _mutations(calls) == []


def test_tenant_role_binding_identity_mismatch_blocks_cleanup(
    tmp_path: Path,
) -> None:
    state = _base_state()
    resource = (
        "rolebinding.rbac.authorization.k8s.io/"
        "openclaw-enterprise-api-secrets"
    )
    state["resources"][f"tenant-a|{resource}"]["objectFields"]["roleRef"][
        "name"
    ] = "customer-cluster-role"
    result, final, calls = _run(tmp_path, state)
    assert result.returncode != 0
    assert "contains descendants without exact sample ownership metadata" in (
        result.stderr
    )
    assert f"tenant-a|{resource}" in final["resources"]
    assert "|namespace/tenant-a" in final["resources"]
    assert _mutations(calls) == []


def test_tenant_role_binding_resource_version_guard_rejects_race(
    tmp_path: Path,
) -> None:
    state = _base_state()
    resource = (
        "rolebinding.rbac.authorization.k8s.io/"
        "openclaw-enterprise-worker"
    )
    key = f"tenant-a|{resource}"
    state["race"] = key
    result, final, calls = _run(tmp_path, state)
    assert result.returncode != 0
    assert "guarded deletion failed" in result.stderr
    assert key in final["resources"]
    assert "|namespace/tenant-a" in final["resources"]
    delete = next(
        call for call in calls
        if call["tool"] == "kubectl"
        and f"--raw={_api_path(resource, 'tenant-a')}" in call["args"]
    )
    preconditions = json.loads(delete["stdin"])["preconditions"]
    assert set(preconditions) == {"uid", "resourceVersion"}


@pytest.mark.parametrize(
    ("outcome", "live_attempt", "message"),
    [
        ("failed", ATTEMPT, "does not prove a successful install"),
        ("succeeded", "another-attempt", "does not match the OCC receipt attempt"),
    ],
)
def test_receipt_and_live_release_must_match_before_mutation(
    tmp_path: Path,
    outcome: str,
    live_attempt: str,
    message: str,
) -> None:
    state = _base_state()
    state["attempt"] = live_attempt
    result, _, calls = _run(tmp_path, state, outcome=outcome)
    assert result.returncode != 0
    assert message in result.stderr
    assert _mutations(calls) == []

def test_ownership_mismatch_blocks_all_mutation(tmp_path: Path) -> None:
    state = _base_state()
    state["resources"][f"{SYSTEM_NAMESPACE}|secret/oce-sample-auth"]["owner"] = (
        "customer"
    )
    result, _, calls = _run(tmp_path, state)
    assert result.returncode != 0
    assert "descendants without exact sample ownership metadata" in result.stderr
    assert _mutations(calls) == []


def test_namespace_inventory_blocks_unowned_descendant_before_mutation(
    tmp_path: Path,
) -> None:
    state = _base_state()
    key = f"{SYSTEM_NAMESPACE}|configmap/customer-settings"
    _add_resource(
        state["resources"],
        "configmap/customer-settings",
        SYSTEM_NAMESPACE,
        owner="customer",
    )
    result, final, calls = _run(tmp_path, state)
    assert result.returncode != 0
    assert "descendants without exact sample ownership metadata" in result.stderr
    assert "configmaps/customer-settings" in result.stderr
    assert key in final["resources"]
    assert _mutations(calls) == []


def test_namespace_inventory_accepts_sample_and_matching_helm_ownership(
    tmp_path: Path,
) -> None:
    state = _base_state()
    _add_resource(
        state["resources"],
        "configmap/adapter-settings",
        "openclaw-enterprise-adapter",
    )
    _add_resource(
        state["resources"],
        "secret/helm-owned",
        SYSTEM_NAMESPACE,
        owner="Helm",
        annotations={
            "meta.helm.sh/release-name": RELEASE,
            "meta.helm.sh/release-namespace": SYSTEM_NAMESPACE,
        },
        helm=True,
    )
    _add_resource(
        state["resources"],
        "event/controller-noise",
        "openclaw-enterprise-agw",
        owner="kube-controller-manager",
    )
    result, final, calls = _run(tmp_path, state)
    assert result.returncode == 0, result.stderr
    assert (
        "openclaw-enterprise-adapter|configmap/adapter-settings"
        not in final["resources"]
    )
    assert f"{SYSTEM_NAMESPACE}|secret/helm-owned" not in final["resources"]
    assert any(
        call["tool"] == "kubectl" and "api-resources" in call["args"]
        for call in calls
    )
    assert not any(
        call["tool"] == "kubectl"
        and "get" in call["args"]
        and "events" in call["args"]
        for call in calls
    )


@pytest.mark.parametrize(
    "generated_kind",
    [
        "default-service-account",
        "root-ca-configmap",
        "controller-owner-reference",
        "legacy-service-endpoint",
        "cert-manager-secret",
        "controller-lease",
    ],
)
def test_namespace_inventory_accepts_only_narrow_generated_descendants(
    tmp_path: Path,
    generated_kind: str,
) -> None:
    state = _base_state()
    resources = state["resources"]

    def discover(resource_type: str) -> None:
        if resource_type not in state["namespacedTypes"]:
            state["namespacedTypes"].append(resource_type)

    if generated_kind == "default-service-account":
        discover("serviceaccounts")
        resource = "serviceaccount/default"
        _add_resource(resources, resource, SYSTEM_NAMESPACE, owner="", labels={})
    elif generated_kind == "root-ca-configmap":
        resource = "configmap/kube-root-ca.crt"
        _add_resource(
            resources,
            resource,
            SYSTEM_NAMESPACE,
            owner="",
            labels={},
            annotations={
                "kubernetes.io/description":
                    "Contains a CA bundle for kube-apiserver verification."
            },
            object_fields={"data": {"ca.crt": "test-ca"}},
        )
    elif generated_kind == "controller-owner-reference":
        discover("deployments.apps")
        discover("replicasets.apps")
        parent = "deployment.apps/sample-controller"
        _add_resource(resources, parent, SYSTEM_NAMESPACE)
        parent_uid = resources[f"{SYSTEM_NAMESPACE}|{parent}"]["uid"]
        resource = "replicaset.apps/sample-controller-abc123"
        _add_resource(
            resources,
            resource,
            SYSTEM_NAMESPACE,
            owner="",
            labels={},
            owner_references=[{
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "name": "sample-controller",
                "uid": parent_uid,
                "controller": True,
            }],
        )
    elif generated_kind == "legacy-service-endpoint":
        discover("services")
        discover("endpoints")
        parent = "service/sample-api"
        _add_resource(resources, parent, SYSTEM_NAMESPACE)
        resource = "endpoint/sample-api"
        _add_resource(
            resources,
            resource,
            SYSTEM_NAMESPACE,
            owner="",
            labels={"endpoints.kubernetes.io/managed-by": "endpoint-controller"},
            annotations={
                "endpoints.kubernetes.io/last-change-trigger-time":
                    "2026-11-20T00:00:00Z"
            },
        )
    elif generated_kind == "cert-manager-secret":
        discover("certificates.cert-manager.io")
        parent = "certificate.cert-manager.io/sample-ingress"
        _add_resource(resources, parent, SYSTEM_NAMESPACE)
        resource = "secret/sample-ingress-tls"
        _add_resource(
            resources,
            resource,
            SYSTEM_NAMESPACE,
            owner="",
            labels={"controller.cert-manager.io/fao": "true"},
            annotations={
                "cert-manager.io/certificate-name": "sample-ingress",
                "cert-manager.io/issuer-name": "sample-ca",
            },
            object_fields={
                "type": "kubernetes.io/tls",
                "data": {"tls.crt": "cert", "tls.key": "key"},
            },
        )
    else:
        discover("pods")
        discover("leases.coordination.k8s.io")
        parent = "pod/sample-controller-abc123"
        _add_resource(resources, parent, SYSTEM_NAMESPACE)
        resource = "lease.coordination.k8s.io/sample-controller-leader"
        _add_resource(
            resources,
            resource,
            SYSTEM_NAMESPACE,
            owner="",
            labels={},
            object_fields={
                "spec": {"holderIdentity": "sample-controller-abc123_unique"}
            },
        )

    result, final, _ = _run(tmp_path, state)
    assert result.returncode == 0, result.stderr
    assert f"{SYSTEM_NAMESPACE}|{resource}" not in final["resources"]


@pytest.mark.parametrize(
    "generated_kind",
    ["default-service-account", "root-ca-configmap", "controller-lease"],
)
def test_namespace_inventory_rejects_generated_lookalikes_with_user_state(
    tmp_path: Path,
    generated_kind: str,
) -> None:
    state = _base_state()
    resources = state["resources"]
    if generated_kind == "default-service-account":
        state["namespacedTypes"].append("serviceaccounts")
        resource = "serviceaccount/default"
        expected_type = "serviceaccounts"
        _add_resource(
            resources,
            resource,
            SYSTEM_NAMESPACE,
            owner="",
            labels={"team": "customer"},
        )
    elif generated_kind == "root-ca-configmap":
        resource = "configmap/kube-root-ca.crt"
        expected_type = "configmaps"
        _add_resource(
            resources,
            resource,
            SYSTEM_NAMESPACE,
            owner="",
            labels={},
            annotations={
                "kubernetes.io/description":
                    "Contains a CA bundle for kube-apiserver verification."
            },
            object_fields={
                "data": {"ca.crt": "test-ca", "customer-settings": "keep"}
            },
        )
    else:
        state["namespacedTypes"].append("leases.coordination.k8s.io")
        resource = "lease.coordination.k8s.io/customer-controller"
        expected_type = "leases.coordination.k8s.io"
        _add_resource(
            resources,
            resource,
            SYSTEM_NAMESPACE,
            owner="",
            labels={},
            object_fields={"spec": {"holderIdentity": "unrelated-pod"}},
        )

    result, final, calls = _run(tmp_path, state)
    assert result.returncode != 0
    assert expected_type in result.stderr
    assert f"{SYSTEM_NAMESPACE}|{resource}" in final["resources"]
    assert _mutations(calls) == []


@pytest.mark.parametrize(
    ("state_field", "value", "message"),
    [
        ("discoveryError", True, "could not discover namespaced resource types"),
        ("inventoryErrors", ["configmaps"], "could not inventory configmaps"),
    ],
)
def test_namespace_inventory_errors_fail_before_mutation(
    tmp_path: Path,
    state_field: str,
    value: Any,
    message: str,
) -> None:
    state = _base_state()
    state[state_field] = value
    result, _, calls = _run(tmp_path, state)
    assert result.returncode != 0
    assert message in result.stderr
    assert _mutations(calls) == []


def test_uid_resource_version_race_preserves_replacement(tmp_path: Path) -> None:
    state = _base_state()
    key = f"{SYSTEM_NAMESPACE}|secret/oce-sample-auth"
    state["race"] = key
    result, final, _ = _run(tmp_path, state)
    assert result.returncode != 0
    assert "guarded deletion failed" in result.stderr
    assert key in final["resources"]

def test_incomplete_deletion_fails_loudly(tmp_path: Path) -> None:
    state = _base_state()
    key = f"|namespace/{SYSTEM_NAMESPACE}"
    state["sticky"] = key
    result, final, _ = _run(tmp_path, state)
    assert result.returncode != 0
    assert "still exists after deletion" in result.stderr
    assert key in final["resources"]

@pytest.mark.parametrize(
    ("owner", "references", "success"),
    [("customer", [], True), (OWNER, ["tenant-a/data"], False)],
)
def test_storage_class_requires_ownership_and_no_remaining_pvc_references(
    tmp_path: Path,
    owner: str,
    references: list[str],
    success: bool,
) -> None:
    state = _base_state()
    key = f"|storageclass.storage.k8s.io/{STORAGE_CLASS}"
    state["resources"][key]["owner"] = owner
    state["pvcs"] = [
        {
            "metadata": {"namespace": item.split("/")[0], "name": item.split("/")[1]},
            "spec": {"storageClassName": STORAGE_CLASS},
        }
        for item in references
    ]
    result, final, _ = _run(tmp_path, state)
    assert (result.returncode == 0) is success
    assert key in final["resources"]
    if references:
        assert "remaining PVC references" in result.stderr

def test_missing_release_does_not_authorize_stale_helm_rbac(tmp_path: Path) -> None:
    state = _base_state(include_sample=False)
    state["release"] = False
    result, final, calls = _run(tmp_path, state)
    key = f"|clusterrole.rbac.authorization.k8s.io/{RELEASE}-openclaw-namespace-observer"
    path = _api_path(key.removeprefix("|"))
    assert result.returncode != 0
    assert "ownership could not be proved" in result.stderr
    assert key in final["resources"]
    assert not [
        call for call in calls
        if call["tool"] == "kubectl" and f"--raw={path}" in call["args"]
    ]

def test_aws_cleanup_uses_exact_verified_identifiers(tmp_path: Path) -> None:
    state = _base_state(include_sample=False)
    state["resources"].pop(
        f"|clusterrole.rbac.authorization.k8s.io/"
        f"{RELEASE}-openclaw-namespace-observer"
    )
    result, final, calls = _run(tmp_path, state, aws=True)
    assert result.returncode == 0, result.stderr
    assert final["aws"]["associationDeleted"]
    assert final["aws"]["policyDeleted"]
    assert final["aws"]["roleDeleted"]
    deletes = [
        call["args"] for call in calls
        if call["tool"] == "aws" and any("delete-" in arg for arg in call["args"])
    ]
    assert ASSOCIATION_ID in deletes[0]
    assert ROLE_NAME in deletes[1]
    assert POLICY_NAME in deletes[1]
    assert ROLE_NAME in deletes[2]

@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        ("account", "999900001111", "wrong account"),
        ("roleOwner", "customer", "not tagged"),
        ("managedPolicies", "1", "extra attachments"),
        ("associationOwner", "customer", "association does not match"),
    ],
)
def test_aws_identity_ownership_and_attachments_are_fail_closed(
    tmp_path: Path,
    field: str,
    value: str,
    message: str,
) -> None:
    state = _base_state(include_sample=False)
    state["resources"].pop(
        f"|clusterrole.rbac.authorization.k8s.io/"
        f"{RELEASE}-openclaw-namespace-observer"
    )
    state["aws"][field] = value
    result, final, calls = _run(tmp_path, state, aws=True)
    assert result.returncode != 0
    assert message in result.stderr
    assert not final["aws"]["associationDeleted"]
    assert not final["aws"]["roleDeleted"]
    assert not [
        call for call in calls
        if call["tool"] == "aws" and any("delete-" in arg for arg in call["args"])
    ]
