"""Contracts for the AgentGateway Pod Identity lifecycle helper."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import textwrap
from typing import Any

import pytest

SAMPLE = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = SAMPLE / "scripts" / "setup-agentgateway-pod-identity.sh"
OWNER = "openclaw-enterprise-blueprint"
REGION = "us-west-2"
ACCOUNT = "111122223333"
CLUSTER = "shared-cluster"
CONTEXT = "shared-cluster-context"
NAMESPACE = "openclaw-enterprise-agw"
SERVICE_ACCOUNT = "agentgateway"
REGION_CONFIG_MAP = "agentgateway-aws-region"
ROLE_NAME = "openclaw-enterprise-agentgateway"
POLICY_NAME = "openclaw-enterprise-bedrock-invoke"
MODEL_ID = "amazon.nova-lite-v1:0"
ROLE_ARN = f"arn:aws:iam::{ACCOUNT}:role/{ROLE_NAME}"
CLUSTER_ARN = f"arn:aws:eks:{REGION}:{ACCOUNT}:cluster/{CLUSTER}"
ASSOCIATION_ID = "a-abcdefghijklmnopq"
ASSOCIATION_ARN = (
    f"arn:aws:eks:{REGION}:{ACCOUNT}:"
    f"podidentityassociation/{CLUSTER}/{ASSOCIATION_ID}"
)
ROLE_ID = "AROABCDEFGHIJKLMNOPQ"
EXISTING_INVOCATION_ID = "0123456789abcdef0123456789abcdef"
NAMESPACE_UID = "uid-agentgateway-namespace"
SERVICE_ACCOUNT_UID = "uid-agentgateway-service-account"
CONFIG_MAP_UID = "uid-agentgateway-region-config-map"
ARGS = (
    "--aws-region",
    REGION,
    "--aws-account-id",
    ACCOUNT,
    "--eks-cluster-name",
    CLUSTER,
    "--kube-context",
    CONTEXT,
)


def test_script_avoids_jq_16_reserved_label_variable() -> None:
    source = SCRIPT.read_text()
    assert "--arg label " not in source
    assert re.search(r"\$label\b", source) is None


def _trust_policy(region: str = REGION) -> dict[str, Any]:
    return {
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "AllowAgentGatewayPodIdentity",
            "Effect": "Allow",
            "Principal": {"Service": "pods.eks.amazonaws.com"},
            "Action": ["sts:AssumeRole", "sts:TagSession"],
            "Condition": {
                "StringEquals": {
                    "aws:SourceAccount": ACCOUNT,
                    "aws:RequestTag/kubernetes-namespace": NAMESPACE,
                    "aws:RequestTag/kubernetes-service-account": SERVICE_ACCOUNT,
                },
                "ArnEquals": {
                    "aws:SourceArn": (
                        f"arn:aws:eks:{region}:{ACCOUNT}:cluster/{CLUSTER}"
                    )
                },
            },
        }],
    }


def _bedrock_policy(region: str = REGION) -> dict[str, Any]:
    return {
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "InvokeCentralBedrockModel",
            "Effect": "Allow",
            "Action": [
                "bedrock:InvokeModel",
                "bedrock:InvokeModelWithResponseStream",
            ],
            "Resource": (
                f"arn:aws:bedrock:{region}::foundation-model/{MODEL_ID}"
            ),
            "Condition": {"StringEquals": {"aws:RequestedRegion": region}},
        }],
    }


def _namespace() -> dict[str, Any]:
    return {
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": {
            "name": NAMESPACE,
            "uid": NAMESPACE_UID,
            "labels": {
                "app.kubernetes.io/name": "agentgateway",
                "app.kubernetes.io/managed-by": OWNER,
                "pod-security.kubernetes.io/enforce": "restricted",
                "pod-security.kubernetes.io/audit": "restricted",
                "pod-security.kubernetes.io/warn": "restricted",
            },
        },
    }


def _service_account() -> dict[str, Any]:
    return {
        "apiVersion": "v1",
        "kind": "ServiceAccount",
        "metadata": {
            "namespace": NAMESPACE,
            "name": SERVICE_ACCOUNT,
            "uid": SERVICE_ACCOUNT_UID,
            "labels": {},
        },
        "automountServiceAccountToken": False,
    }


def _region_config_map(region: str = REGION) -> dict[str, Any]:
    return {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "namespace": NAMESPACE,
            "name": REGION_CONFIG_MAP,
            "uid": CONFIG_MAP_UID,
            "labels": {},
        },
        "immutable": True,
        "data": {"AWS_REGION": region},
    }


def _base_state(region: str = REGION) -> dict[str, Any]:
    return {
        "account": ACCOUNT,
        "cluster": {
            "name": CLUSTER,
            "arn": f"arn:aws:eks:{region}:{ACCOUNT}:cluster/{CLUSTER}",
            "endpoint": "https://cluster.example.test",
        },
        "context": {
            "name": CONTEXT,
            "endpoint": "https://cluster.example.test",
        },
        "namespace": _namespace(),
        "service_account": _service_account(),
        "region_config_map": _region_config_map(region),
        "role": None,
        "association": None,
    }


def _owned_state(region: str = REGION) -> dict[str, Any]:
    state = _base_state(region)
    state["role"] = {
        "name": ROLE_NAME,
        "arn": ROLE_ARN,
        "role_id": ROLE_ID,
        "owner": OWNER,
        "invocation_id": EXISTING_INVOCATION_ID,
        "trust": _trust_policy(region),
        "inline_policies": {POLICY_NAME: _bedrock_policy(region)},
        "attached_policies": [],
        "instance_profiles": [],
        "permissions_boundary": None,
    }
    state["association"] = {
        "cluster": CLUSTER,
        "id": ASSOCIATION_ID,
        "namespace": NAMESPACE,
        "service_account": SERVICE_ACCOUNT,
        "role_arn": ROLE_ARN,
        "arn": ASSOCIATION_ARN,
        "owner": OWNER,
        "invocation_id": EXISTING_INVOCATION_ID,
        "owner_arn": None,
        "target_role_arn": None,
        "external_id": None,
        "disable_session_tags": False,
        "policy": None,
    }
    return state


def _write_executable(path: pathlib.Path, source: str) -> None:
    path.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
    path.chmod(0o755)


def _install_fake_cli(bin_dir: pathlib.Path) -> None:
    fake = bin_dir / "fake-cli"
    _write_executable(
        fake,
        r"""
        #!/usr/bin/env python3
        import json
        import os
        import pathlib
        import signal
        import sys

        REGION = "us-west-2"
        CLUSTER = "shared-cluster"
        NAMESPACE = "openclaw-enterprise-agw"
        SERVICE_ACCOUNT = "agentgateway"
        REGION_CONFIG_MAP = "agentgateway-aws-region"
        ROLE_NAME = "openclaw-enterprise-agentgateway"
        POLICY_NAME = "openclaw-enterprise-bedrock-invoke"
        ROLE_ARN = "arn:aws:iam::111122223333:role/" + ROLE_NAME
        ASSOCIATION_ID = "a-abcdefghijklmnopq"
        ASSOCIATION_ARN = (
            "arn:aws:eks:us-west-2:111122223333:"
            "podidentityassociation/shared-cluster/" + ASSOCIATION_ID
        )
        ROLE_ID = "AROABCDEFGHIJKLMNOPQ"
        NAMESPACE_UID = "uid-agentgateway-namespace"
        SERVICE_ACCOUNT_UID = "uid-agentgateway-service-account"
        CONFIG_MAP_UID = "uid-agentgateway-region-config-map"

        tool = pathlib.Path(sys.argv[0]).name
        args = sys.argv[1:]
        state_path = pathlib.Path(os.environ["FAKE_STATE"])
        state = json.loads(state_path.read_text())
        log_path = pathlib.Path(
            os.environ["FAKE_AWS_LOG" if tool == "aws" else "FAKE_KUBE_LOG"]
        )
        with log_path.open("a") as log:
            log.write(json.dumps(args) + "\n")

        def save():
            state_path.write_text(json.dumps(state))

        def value(option):
            return args[args.index(option) + 1]

        def aws_response(operation, response):
            if state.get("malformed") == operation:
                print("{broken")
            elif state.get("partial") == operation:
                print("{}")
            else:
                print(json.dumps(response))

        def after_mutation(operation):
            save()
            if state.get("kill_after") == operation:
                state.pop("kill_after")
                save()
                os.killpg(os.getpgrp(), signal.SIGKILL)
            if state.get("fail_after") == operation:
                print("simulated lost response", file=sys.stderr)
                raise SystemExit(70)

        if tool == "kubectl":
            context = state["context"]
            if len(args) > 3 and args[2:4] == ["config", "view"]:
                source = pathlib.Path(args[1])
                assert source.stat().st_mode & 0o777 == 0o600
                assert json.loads(source.read_text()) == {"source": "kubeconfig"}
                print(json.dumps({
                    "apiVersion": "v1",
                    "kind": "Config",
                    "current-context": context["name"],
                    "clusters": [{
                        "name": "selected",
                        "cluster": {"server": context["endpoint"]},
                    }],
                    "contexts": [{
                        "name": context["name"],
                        "context": {"cluster": "selected", "user": "test"},
                    }],
                    "users": [{
                        "name": "test",
                        "user": {"token": "test-token"},
                    }],
                }))
                raise SystemExit
            if args[:4] != [
                "--kubeconfig", args[1], "--context", context["name"]
            ]:
                raise SystemExit("unpinned kubectl")
            command = args[4:]
            kubeconfig = pathlib.Path(args[1])
            assert kubeconfig.stat().st_mode & 0o777 == 0o600
            if command == ["get", "--raw=/readyz"]:
                print("ok")
                raise SystemExit
            mapping = {
                f"namespace/{NAMESPACE}": "namespace",
                f"serviceaccount/{SERVICE_ACCOUNT}": "service_account",
                f"configmap/{REGION_CONFIG_MAP}": "region_config_map",
            }
            if command and command[0] == "get" and command[1] in mapping:
                document = state.get(mapping[command[1]])
                if document is not None:
                    print(json.dumps(document))
                raise SystemExit
            if command[:2] == ["create", "--filename"]:
                document = json.loads(pathlib.Path(command[2]).read_text())
                field = {
                    "Namespace": "namespace",
                    "ServiceAccount": "service_account",
                    "ConfigMap": "region_config_map",
                }[document["kind"]]
                if state.get(field) is not None:
                    raise SystemExit("AlreadyExists")
                document["metadata"]["uid"] = {
                    "namespace": NAMESPACE_UID,
                    "service_account": SERVICE_ACCOUNT_UID,
                    "region_config_map": CONFIG_MAP_UID,
                }[field]
                state[field] = document
                after_mutation(f"kube:create:{field}")
                print(f"{field} created")
                raise SystemExit
            raise SystemExit(f"unsupported kubectl: {command}")

        assert args[:3] == ["--no-cli-pager", "--region", REGION]
        service, action = args[3:5]
        operation = f"{service}:{action}"
        if state.get("fail_before") == operation:
            raise SystemExit("simulated failure")

        if operation == "sts:get-caller-identity":
            aws_response(operation, {"Account": state["account"]})
        elif operation == "eks:describe-cluster":
            aws_response(operation, {"cluster": state["cluster"]})
        elif operation == "iam:get-role":
            role = state["role"]
            if role is None:
                raise SystemExit("NoSuchEntity")
            aws_response(operation, {"Role": {
                "RoleName": role["name"],
                "Arn": role["arn"],
                "RoleId": role["role_id"],
                "Tags": [
                    {"Key": "ManagedBy", "Value": role["owner"]},
                    {
                        "Key": "OpenClawSetupInvocation",
                        "Value": role["invocation_id"],
                    },
                ],
                "PermissionsBoundary": role["permissions_boundary"],
                "AssumeRolePolicyDocument": role["trust"],
            }})
        elif operation == "iam:list-role-policies":
            aws_response(operation, {
                "PolicyNames": list(state["role"]["inline_policies"])
            })
        elif operation == "iam:list-attached-role-policies":
            aws_response(operation, {
                "AttachedPolicies": state["role"]["attached_policies"]
            })
        elif operation == "iam:list-instance-profiles-for-role":
            aws_response(operation, {
                "InstanceProfiles": state["role"]["instance_profiles"]
            })
        elif operation == "iam:get-role-policy":
            policy = state["role"]["inline_policies"].get(POLICY_NAME)
            if policy is None:
                raise SystemExit("NoSuchEntity")
            aws_response(operation, {
                "RoleName": ROLE_NAME,
                "PolicyName": POLICY_NAME,
                "PolicyDocument": policy,
            })
        elif operation == "iam:create-role":
            trust = json.loads(
                pathlib.Path(
                    value("--assume-role-policy-document").removeprefix("file://")
                ).read_text()
            )
            tags = {}
            index = args.index("--tags") + 1
            while index < len(args) and not args[index].startswith("--"):
                tags.update(
                    part.split("=", 1)
                    for part in args[index].split(",")
                    if part.startswith(("Key=", "Value="))
                )
                index += 1
            tag_args = args[args.index("--tags") + 1:index]
            parsed = {
                pair.split("=", 1)[0]: pair.split("=", 1)[1]
                for item in tag_args
                for pair in [item.replace("Key=", "").replace(",Value=", "=")]
            }
            state["role"] = {
                "name": ROLE_NAME,
                "arn": ROLE_ARN,
                "role_id": ROLE_ID,
                "owner": parsed["ManagedBy"],
                "invocation_id": parsed["OpenClawSetupInvocation"],
                "trust": trust,
                "inline_policies": {},
                "attached_policies": [],
                "instance_profiles": [],
                "permissions_boundary": None,
            }
            after_mutation(operation)
            aws_response(operation, {
                "Role": {
                    "RoleName": ROLE_NAME,
                    "Arn": ROLE_ARN,
                    "RoleId": ROLE_ID,
                }
            })
        elif operation == "iam:put-role-policy":
            policy = json.loads(
                pathlib.Path(
                    value("--policy-document").removeprefix("file://")
                ).read_text()
            )
            state["role"]["inline_policies"][POLICY_NAME] = policy
            after_mutation(operation)
        elif operation == "eks:list-pod-identity-associations":
            association = state["association"]
            aws_response(operation, {
                "associations": (
                    [] if association is None
                    else [{"associationId": association["id"]}]
                )
            })
        elif operation == "eks:describe-pod-identity-association":
            association = state["association"]
            if association is None:
                raise SystemExit("ResourceNotFoundException")
            aws_response(operation, {"association": {
                "clusterName": association["cluster"],
                "associationId": association["id"],
                "namespace": association["namespace"],
                "serviceAccount": association["service_account"],
                "roleArn": association["role_arn"],
                "associationArn": association["arn"],
                "tags": {
                    "ManagedBy": association["owner"],
                    "OpenClawSetupInvocation": association["invocation_id"],
                },
                "ownerArn": association["owner_arn"],
                "targetRoleArn": association["target_role_arn"],
                "externalId": association["external_id"],
                "disableSessionTags": association["disable_session_tags"],
                "policy": association["policy"],
            }})
        elif operation == "eks:create-pod-identity-association":
            tags = dict(
                item.split("=", 1)
                for item in value("--tags").split(",")
            )
            state["association"] = {
                "cluster": CLUSTER,
                "id": ASSOCIATION_ID,
                "namespace": NAMESPACE,
                "service_account": SERVICE_ACCOUNT,
                "role_arn": ROLE_ARN,
                "arn": ASSOCIATION_ARN,
                "owner": tags["ManagedBy"],
                "invocation_id": tags["OpenClawSetupInvocation"],
                "owner_arn": None,
                "target_role_arn": None,
                "external_id": None,
                "disable_session_tags": False,
                "policy": None,
            }
            after_mutation(operation)
            aws_response(operation, {"association": {
                "associationId": ASSOCIATION_ID,
                "associationArn": ASSOCIATION_ARN,
            }})
        else:
            raise SystemExit(f"unsupported aws call: {operation}")
        """,
    )
    for name in ("aws", "kubectl"):
        link = bin_dir / name
        if not link.exists():
            link.symlink_to(fake)


def _run_setup(
    tmp_path: pathlib.Path,
    *,
    state: dict[str, Any] | None = None,
    args: tuple[str, ...] = ARGS,
    extra_env: dict[str, str] | None = None,
) -> tuple[
    subprocess.CompletedProcess[str],
    list[list[str]],
    list[list[str]],
    dict[str, Any],
]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    _install_fake_cli(bin_dir)
    state_path = tmp_path / "state.json"
    if state is not None or not state_path.exists():
        state_path.write_text(json.dumps(state or _base_state()), encoding="utf-8")
    aws_log = tmp_path / "aws.log"
    kube_log = tmp_path / "kube.log"
    aws_log.write_text("", encoding="utf-8")
    kube_log.write_text("", encoding="utf-8")
    kubeconfig = tmp_path / "kubeconfig"
    kubeconfig.write_text(json.dumps({"source": "kubeconfig"}), encoding="utf-8")
    kubeconfig.chmod(0o600)
    result = subprocess.run(
        ["bash", str(SCRIPT), *args],
        check=False,
        capture_output=True,
        text=True,
        start_new_session=True,
        env={
            **os.environ,
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "FAKE_STATE": str(state_path),
            "FAKE_AWS_LOG": str(aws_log),
            "FAKE_KUBE_LOG": str(kube_log),
            "KUBECONFIG": str(kubeconfig),
            **(extra_env or {}),
        },
    )
    calls = lambda path: [
        json.loads(line) for line in path.read_text().splitlines()
    ]
    return result, calls(aws_log), calls(kube_log), json.loads(
        state_path.read_text()
    )


def _mutating_aws_calls(calls: list[list[str]]) -> list[list[str]]:
    mutations = {
        "create-role",
        "put-role-policy",
        "create-pod-identity-association",
    }
    return [call for call in calls if mutations.intersection(call)]


def _receipt_args(path: pathlib.Path) -> tuple[str, ...]:
    return (*ARGS, "--receipt", str(path))


def _receipt(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def test_requires_explicit_target() -> None:
    result = subprocess.run(
        ["bash", str(SCRIPT)],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 2
    assert "--aws-region is required" in result.stderr


def test_creates_exact_resources_and_private_receipt(
    tmp_path: pathlib.Path,
) -> None:
    receipt = tmp_path / "receipt.json"
    state = _base_state()
    state["namespace"] = None
    state["service_account"] = None
    state["region_config_map"] = None
    result, aws_calls, _, final = _run_setup(
        tmp_path, state=state, args=_receipt_args(receipt)
    )
    assert result.returncode == 0, result.stderr
    assert receipt.stat().st_mode & 0o777 == 0o600
    assert not receipt.with_suffix(".json.journal").exists()
    assert [call[4] for call in _mutating_aws_calls(aws_calls)] == [
        "create-role",
        "put-role-policy",
        "create-pod-identity-association",
    ]
    data = _receipt(receipt)
    assert data["version"] == 2
    assert data["operation"] == "setup-agentgateway-pod-identity"
    assert data["target"] == {
        "kubeContext": CONTEXT,
        "clusterEndpoint": "https://cluster.example.test",
        "awsRegion": REGION,
        "awsAccountId": ACCOUNT,
        "eksClusterName": CLUSTER,
        "eksClusterArn": CLUSTER_ARN,
    }
    resources = data["resources"]
    assert set(resources) == {
        "namespace",
        "serviceAccount",
        "iamRole",
        "inlinePolicy",
        "podIdentityAssociation",
    }
    assert all(item["created"] for item in resources.values())
    assert resources["namespace"] == {
        "apiVersion": "v1",
        "kind": "Namespace",
        "name": NAMESPACE,
        "uid": NAMESPACE_UID,
        "created": True,
    }
    assert resources["serviceAccount"] == {
        "apiVersion": "v1",
        "kind": "ServiceAccount",
        "namespace": NAMESPACE,
        "name": SERVICE_ACCOUNT,
        "uid": SERVICE_ACCOUNT_UID,
        "created": True,
    }
    role = resources["iamRole"]
    assert role["name"] == ROLE_NAME
    assert role["arn"] == ROLE_ARN
    assert role["roleId"] == ROLE_ID
    assert re.fullmatch(r"[a-f0-9]{32}", role["invocationId"])
    assert resources["inlinePolicy"]["name"] == POLICY_NAME
    assert resources["inlinePolicy"]["roleName"] == ROLE_NAME
    assert resources["inlinePolicy"]["roleId"] == ROLE_ID
    assert resources["inlinePolicy"]["documentSha256"] == hashlib.sha256(
        json.dumps(
            _bedrock_policy(), sort_keys=True, separators=(",", ":")
        ).encode()
    ).hexdigest()
    association = resources["podIdentityAssociation"]
    assert association == {
        "clusterName": CLUSTER,
        "associationId": ASSOCIATION_ID,
        "associationArn": ASSOCIATION_ARN,
        "namespace": NAMESPACE,
        "serviceAccount": SERVICE_ACCOUNT,
        "roleArn": ROLE_ARN,
        "targetRoleArn": None,
        "externalId": None,
        "disableSessionTags": False,
        "policy": None,
        "invocationId": association["invocationId"],
        "created": True,
    }
    assert re.fullmatch(r"[a-f0-9]{32}", association["invocationId"])
    assert final["role"]["trust"] == _trust_policy()
    assert final["role"]["inline_policies"][POLICY_NAME] == _bedrock_policy()


def test_reuses_exact_resources_idempotently(tmp_path: pathlib.Path) -> None:
    receipt = tmp_path / "receipt.json"
    result, aws_calls, _, _ = _run_setup(
        tmp_path, state=_owned_state(), args=_receipt_args(receipt)
    )
    assert result.returncode == 0, result.stderr
    assert not _mutating_aws_calls(aws_calls)
    assert all(
        item["created"] is False
        for item in _receipt(receipt)["resources"].values()
    )
    before = receipt.read_bytes()
    result, aws_calls, _, _ = _run_setup(
        tmp_path, args=_receipt_args(receipt)
    )
    assert result.returncode == 0, result.stderr
    assert not _mutating_aws_calls(aws_calls)
    assert receipt.read_bytes() == before


@pytest.mark.parametrize(
    ("operation", "mode"),
    [
        ("sts:get-caller-identity", "partial"),
        ("eks:describe-cluster", "malformed"),
        ("iam:get-role", "partial"),
        ("eks:list-pod-identity-associations", "partial"),
    ],
)
def test_rejects_malformed_or_partial_aws_output(
    tmp_path: pathlib.Path,
    operation: str,
    mode: str,
) -> None:
    state = _owned_state()
    state[mode] = operation
    result, aws_calls, _, _ = _run_setup(tmp_path, state=state)
    assert result.returncode != 0
    if operation in {"sts:get-caller-identity", "eks:describe-cluster"}:
        assert not _mutating_aws_calls(aws_calls)


@pytest.mark.parametrize("resource", ["namespace", "role", "association"])
def test_refuses_foreign_or_mismatched_resources(
    tmp_path: pathlib.Path,
    resource: str,
) -> None:
    state = _owned_state()
    if resource == "namespace":
        state["namespace"]["metadata"]["labels"][
            "app.kubernetes.io/managed-by"
        ] = "someone-else"
    elif resource == "role":
        state["role"]["owner"] = "someone-else"
    else:
        state["association"]["role_arn"] = (
            f"arn:aws:iam::{ACCOUNT}:role/foreign"
        )
    result, aws_calls, _, _ = _run_setup(tmp_path, state=state)
    assert result.returncode != 0
    assert not _mutating_aws_calls(aws_calls)


@pytest.mark.parametrize("failure", ["account", "region", "context"])
def test_refuses_wrong_explicit_target(
    tmp_path: pathlib.Path,
    failure: str,
) -> None:
    state = _owned_state()
    if failure == "account":
        state["account"] = "999900001111"
    elif failure == "region":
        state["cluster"]["arn"] = (
            f"arn:aws:eks:us-east-1:{ACCOUNT}:cluster/{CLUSTER}"
        )
    else:
        state["context"]["endpoint"] = "https://other.example.test"
    result, aws_calls, _, _ = _run_setup(tmp_path, state=state)
    assert result.returncode != 0
    assert not _mutating_aws_calls(aws_calls)


def test_refuses_unsafe_receipt_paths(tmp_path: pathlib.Path) -> None:
    public = tmp_path / "public"
    public.mkdir(mode=0o755)
    result, aws_calls, _, _ = _run_setup(
        tmp_path, args=_receipt_args(public / "receipt.json")
    )
    assert result.returncode != 0
    assert not aws_calls

    receipt = tmp_path / "receipt.json"
    receipt.write_text("{}", encoding="utf-8")
    receipt.chmod(0o644)
    result, aws_calls, _, _ = _run_setup(
        tmp_path, args=_receipt_args(receipt)
    )
    assert result.returncode != 0
    assert not aws_calls


@pytest.mark.parametrize(
    "interruption",
    ["iam:create-role", "eks:create-pod-identity-association"],
)
def test_recovers_interrupted_creation_with_original_provenance(
    tmp_path: pathlib.Path,
    interruption: str,
) -> None:
    receipt = tmp_path / "receipt.json"
    state = _base_state()
    state["kill_after"] = interruption
    first, _, _, after_first = _run_setup(
        tmp_path, state=state, args=_receipt_args(receipt)
    )
    assert first.returncode < 0
    assert not receipt.exists()
    assert pathlib.Path(f"{receipt}.journal").exists()

    second, _, _, _ = _run_setup(
        tmp_path, state=after_first, args=_receipt_args(receipt)
    )
    assert second.returncode == 0, second.stderr
    resources = _receipt(receipt)["resources"]
    assert resources["iamRole"]["created"] is True
    if interruption.startswith("eks:"):
        assert resources["podIdentityAssociation"]["created"] is True


def test_partial_create_response_fails_then_recovers(
    tmp_path: pathlib.Path,
) -> None:
    receipt = tmp_path / "receipt.json"
    state = _base_state()
    state["partial"] = "iam:create-role"
    first, _, _, after_first = _run_setup(
        tmp_path, state=state, args=_receipt_args(receipt)
    )
    assert first.returncode != 0
    assert after_first["role"] is not None
    after_first.pop("partial")
    second, _, _, _ = _run_setup(
        tmp_path, state=after_first, args=_receipt_args(receipt)
    )
    assert second.returncode == 0, second.stderr
    assert _receipt(receipt)["resources"]["iamRole"]["created"] is True


def test_receipt_records_mixed_created_and_reused_provenance(
    tmp_path: pathlib.Path,
) -> None:
    receipt = tmp_path / "receipt.json"
    result, _, _, _ = _run_setup(
        tmp_path, state=_base_state(), args=_receipt_args(receipt)
    )
    assert result.returncode == 0, result.stderr
    resources = _receipt(receipt)["resources"]
    assert resources["namespace"]["created"] is False
    assert resources["serviceAccount"]["created"] is False
    assert resources["iamRole"]["created"] is True
    assert resources["inlinePolicy"]["created"] is True
    assert resources["podIdentityAssociation"]["created"] is True


def test_existing_receipt_rejects_replaced_live_identity(
    tmp_path: pathlib.Path,
) -> None:
    receipt = tmp_path / "receipt.json"
    first, _, _, state = _run_setup(
        tmp_path, state=_base_state(), args=_receipt_args(receipt)
    )
    assert first.returncode == 0, first.stderr
    state["role"]["role_id"] = "AROZZZZZZZZZZZZZZZZ"
    second, aws_calls, _, _ = _run_setup(
        tmp_path, state=state, args=_receipt_args(receipt)
    )
    assert second.returncode != 0
    assert not _mutating_aws_calls(aws_calls)
