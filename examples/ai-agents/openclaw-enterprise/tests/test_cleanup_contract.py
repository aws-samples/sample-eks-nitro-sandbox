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
    if "/namespaces/" in path and "/serviceaccounts/" not in path:
        return f"namespace/{name}"
    if "/serviceaccounts/" in path:
        namespace = path.split("/namespaces/", 1)[1].split("/", 1)[0]
        return f"{namespace}|serviceaccount/{name}"
    if "/storageclasses/" in path:
        return f"storageclass.storage.k8s.io/{name}"
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
            policy_name = binding["spec"]["policyName"]
            policy_key = (
                "validatingadmissionpolicies.admissionregistration.k8s.io/"
                + policy_name
            )
            policy = state["resources"].get(policy_key)
            if policy and json.dumps(namespace) in policy["spec"]["matchConditions"][0]["expression"]:
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
        changed = data["association"] is not None
        data["association"] = None
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
) -> dict[str, Any]:
    metadata: dict[str, Any] = {
        "name": name,
        "uid": uid,
        "resourceVersion": "1",
        "labels": {"app.kubernetes.io/managed-by": owner},
    }
    if namespace:
        metadata["namespace"] = namespace
    return {"apiVersion": "v1", "kind": kind, "metadata": metadata}


def _base_state(kubeconfig: Path) -> dict[str, Any]:
    return {
        "context": CONTEXT,
        "cluster": CLUSTER,
        "kubeconfig": str(kubeconfig),
        "attempt": ATTEMPT,
        "helm": True,
        "mutations": 0,
        "killAfterFreezeCreate": None,
        "policyName": POLICY_NAME,
        "pvcs": [],
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
    _write_json(receipt / "resources.json", {
        "version": 1,
        "attempt": ATTEMPT,
        "resources": {f"namespace/{SYSTEM_NAMESPACE}": "uid-system"},
    })
    return state_dir, receipt


def _write_lifecycle_receipts(
    tmp_path: Path,
    state: dict[str, Any],
    created: dict[str, bool],
) -> tuple[Path, Path]:
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
        "Namespace", AGW_NAMESPACE, "uid-agw"
    )
    state["resources"][f"{AGW_NAMESPACE}|serviceaccount/agentgateway"] = _object(
        "ServiceAccount", "agentgateway", "uid-sa", namespace=AGW_NAMESPACE
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
    return storage, pod


def _prepare(
    tmp_path: Path,
    *,
    created: dict[str, bool] | None = None,
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
        storage, pod = _write_lifecycle_receipts(tmp_path, state, created)
        command += [
            "--storage-class-receipt", str(storage),
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
    return subprocess.run(command, env=env, text=True, capture_output=True)


def _state(env: dict[str, str]) -> dict[str, Any]:
    return json.loads(Path(env["FAKE_STATE"]).read_text())


def _all_created() -> dict[str, bool]:
    return {
        "storage": True,
        "namespace": True,
        "serviceAccount": True,
        "role": True,
        "policy": True,
        "association": True,
    }


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


def test_mixed_provenance_preserves_dependencies_and_rerun_is_idempotent(
    tmp_path: Path,
) -> None:
    created = {
        "storage": False,
        "namespace": True,
        "serviceAccount": True,
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
    assert after_first["aws"]["association"] is not None
    assert after_first["aws"]["role"] is not None
    assert after_first["aws"]["policyDocument"] is None
    assert f"storageclass.storage.k8s.io/{STORAGE_CLASS}" in after_first["resources"]
    mutation_count = after_first["mutations"]

    second = _run(command, env)
    assert second.returncode == 0, second.stderr
    assert _state(env)["mutations"] == mutation_count


def test_reused_inline_policy_preserves_role_while_created_resources_are_deleted(
    tmp_path: Path,
) -> None:
    created = _all_created()
    created["policy"] = False
    _, command, env = _prepare(tmp_path, created=created)
    first = _run(command, env)
    assert first.returncode == 0, first.stderr
    after_first = _state(env)
    assert after_first["aws"]["association"] is None
    assert after_first["aws"]["policyDocument"] is not None
    assert after_first["aws"]["role"] is not None
    assert f"namespace/{AGW_NAMESPACE}" not in after_first["resources"]
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


def test_reused_storage_class_is_preserved(tmp_path: Path) -> None:
    created = _all_created()
    created["storage"] = False
    _, command, env = _prepare(tmp_path, created=created)
    result = _run(command, env)
    assert result.returncode == 0, result.stderr
    assert f"storageclass.storage.k8s.io/{STORAGE_CLASS}" in _state(env)["resources"]
