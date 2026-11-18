"""Destructive-boundary contracts for the OpenClaw Enterprise cleanup."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import textwrap
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
VPC_KEY = "enable-network-policy-controller"
ASSOCIATION_ID = "a-abcdefghijklmnopq"
ROLE_NAME = "openclaw-enterprise-agentgateway"
POLICY_NAME = "openclaw-enterprise-bedrock-invoke"
ROLE_ARN = f"arn:aws:iam::{ACCOUNT}:role/{ROLE_NAME}"
ASSOCIATION_ARN = f"arn:aws:eks:{REGION}:{ACCOUNT}:podidentityassociation/{CONTEXT}/{ASSOCIATION_ID}"
CLUSTER = {"certificate-authority-data": "dGVzdA==", "server": "https://cluster.example.test"}

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
stdin = sys.stdin.read() if tool == "kubectl" and "delete" in args else ""
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
    elif command[:3] == ["get", "configmap", "amazon-vpc-cni"]:
        if state["vpc"] is not None:
            print(json.dumps(state["vpc"]))
    elif command[:1] == ["get"]:
        resource = command[1]
        namespace = (
            command[command.index("--namespace") + 1]
            if "--namespace" in command else ""
        )
        record = state["resources"].get(resource_key(resource, namespace))
        if record:
            print("|".join([
                record["name"], record["owner"], record["instance"],
                record["uid"], record["version"],
            ]))
    elif command[:2] == ["patch", "configmap"]:
        patch = json.loads(next(x.split("=", 1)[1] for x in command if x.startswith("--patch=")))
        resource = state["vpc"]
        expected = [
            resource["metadata"]["uid"],
            resource["metadata"]["resourceVersion"],
            resource["data"].get(os.environ["FAKE_VPC_KEY"]),
        ]
        if [item.get("value") for item in patch[:3]] != expected:
            raise SystemExit("VPC patch precondition failed")
        resource["data"].pop(os.environ["FAKE_VPC_KEY"])
        resource["metadata"]["resourceVersion"] = "45"
        save()
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
    }
    if kind in core:
        return f"/api/v1/namespaces/{namespace}/{core[kind]}/{name}"
    cluster = {
        "mutatingwebhookconfigurations.admissionregistration.k8s.io":
            ("admissionregistration.k8s.io", "mutatingwebhookconfigurations"),
        "storageclass.storage.k8s.io":
            ("storage.k8s.io", "storageclasses"),
        "clusterrole.rbac.authorization.k8s.io":
            ("rbac.authorization.k8s.io", "clusterroles"),
    }
    group, plural = cluster[kind]
    return f"/apis/{group}/v1/{plural}/{name}"

def _base_state(*, include_sample: bool = True) -> dict[str, Any]:
    resources: dict[str, dict[str, Any]] = {}

    def add(resource: str, namespace: str = "", owner: str = OWNER, *,
            helm: bool = False) -> None:
        serial = len(resources) + 1
        kind, name = resource.split("/", 1)
        resources[f"{namespace}|{resource}"] = {
            "resource": kind,
            "name": name,
            "owner": owner,
            "instance": RELEASE,
            "uid": f"uid-{serial}",
            "version": str(serial),
            "path": _api_path(resource, namespace),
            "helm": helm,
        }

    if include_sample:
        add(f"namespace/{SYSTEM_NAMESPACE}")
        add("secret/oce-sample-auth", SYSTEM_NAMESPACE)
        add("namespace/openclaw-enterprise-adapter")
        add("namespace/openclaw-enterprise-agw")
        add("mutatingwebhookconfigurations.admissionregistration.k8s.io/"
            "openclaw-enterprise-nitro-adapter")
    add("namespace/tenant-a", owner=OCE_OWNER)
    add("configmap/agentgateway-ca", "tenant-a")
    add("secret/customer-managed", "tenant-a", owner="customer")
    add(f"clusterrole.rbac.authorization.k8s.io/"
        f"{RELEASE}-openclaw-namespace-observer", helm=True)
    add(f"storageclass.storage.k8s.io/{STORAGE_CLASS}")
    return {
        "context": CONTEXT,
        "cluster": CLUSTER,
        "resources": resources,
        "release": True,
        "attempt": ATTEMPT,
        "race": None,
        "sticky": None,
        "externalDatabase": "customer-managed-rds",
        "pvcs": [],
        "vpc": {
            "metadata": {
                "uid": "vpc-uid",
                "resourceVersion": "44",
                "managedFields": [{
                    "manager": OWNER,
                    "fieldsV1": {"f:data": {f"f:{VPC_KEY}": {}}},
                }],
            },
            "data": {VPC_KEY: "true", "shared": "keep"},
        },
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

def _write_evidence(tmp_path: Path, outcome: str) -> tuple[Path, Path, Path]:
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
) -> tuple[subprocess.CompletedProcess[str], dict[str, Any], list[dict[str, Any]]]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    dispatcher = bin_dir / "fake-cli"
    _write_executable(dispatcher, FAKE_CLI)
    for tool in ("kubectl", "helm", "aws"):
        (bin_dir / tool).symlink_to(dispatcher)
    _write_executable(bin_dir / "sleep", "#!/bin/sh\nexit 0\n")
    kubeconfig, state_dir, receipt = _write_evidence(tmp_path, outcome)
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
        "FAKE_VPC_KEY": VPC_KEY,
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
        timeout=20,
    )
    final = json.loads(state_path.read_text())
    calls = [json.loads(line) for line in log_path.read_text().splitlines()]
    return result, final, calls

def _mutations(calls: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        call for call in calls
        if "delete" in call["args"]
        or "patch" in call["args"]
        or "uninstall" in call["args"]
    ]

def test_requires_explicit_receipt_bound_target_arguments() -> None:
    result = subprocess.run(
        ["bash", str(CLEANUP)], capture_output=True, check=False, text=True
    )
    assert result.returncode != 0
    assert "--kubeconfig is required" in result.stderr

def test_complete_cleanup_preserves_tenant_and_external_state(tmp_path: Path) -> None:
    state = _base_state()
    result, final, calls = _run(tmp_path, state)
    assert result.returncode == 0, result.stderr
    assert final["externalDatabase"] == "customer-managed-rds"
    assert "|namespace/tenant-a" in final["resources"]
    assert "tenant-a|secret/customer-managed" in final["resources"]
    assert "tenant-a|configmap/agentgateway-ca" not in final["resources"]
    assert f"|storageclass.storage.k8s.io/{STORAGE_CLASS}" not in final["resources"]
    assert final["vpc"]["data"] == {"shared": "keep"}
    assert final["release"] is False
    raw_deletes = [
        call for call in calls
        if call["tool"] == "kubectl" and call["stdin"]
    ]
    assert raw_deletes
    for call in raw_deletes:
        options = json.loads(call["stdin"])
        assert set(options["preconditions"]) == {"uid", "resourceVersion"}
        assert all(options["preconditions"].values())
        assert not {"--all", "--selector", "-l"} & set(call["args"])

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
    assert "does not carry the exact" in result.stderr
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
    ("manager", "value", "success"),
    [("eks", "true", True), (OWNER, "false", False)],
)
def test_shared_vpc_cni_field_is_only_removed_when_owned_and_unchanged(
    tmp_path: Path,
    manager: str,
    value: str,
    success: bool,
) -> None:
    state = _base_state()
    state["vpc"]["metadata"]["managedFields"][0]["manager"] = manager
    state["vpc"]["data"][VPC_KEY] = value
    result, final, calls = _run(tmp_path, state)
    assert (result.returncode == 0) is success
    assert final["vpc"]["data"][VPC_KEY] == value
    assert not any(call["tool"] == "kubectl" and "patch" in call["args"] for call in calls)

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
