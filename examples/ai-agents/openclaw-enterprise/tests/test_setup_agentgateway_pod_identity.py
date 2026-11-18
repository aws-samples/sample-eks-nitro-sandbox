"""Fail-closed contracts for the shared AgentGateway Bedrock identity setup."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
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


def _write_executable(path: pathlib.Path, source: str) -> None:
    path.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
    path.chmod(0o755)


def _trust_policy() -> dict[str, Any]:
    return {
        "Version": "2012-10-17",
        "Statement": [
            {
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
                    "ArnEquals": {"aws:SourceArn": CLUSTER_ARN},
                },
            }
        ],
    }


def _bedrock_policy() -> dict[str, Any]:
    return {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "InvokeCentralBedrockModel",
                "Effect": "Allow",
                "Action": [
                    "bedrock:InvokeModel",
                    "bedrock:InvokeModelWithResponseStream",
                ],
                "Resource": (
                    f"arn:aws:bedrock:{REGION}::foundation-model/{MODEL_ID}"
                ),
                "Condition": {
                    "StringEquals": {"aws:RequestedRegion": REGION},
                },
            }
        ],
    }


def _base_state() -> dict[str, Any]:
    return {
        "account": ACCOUNT,
        "cluster": {
            "name": CLUSTER,
            "arn": CLUSTER_ARN,
            "endpoint": "https://cluster.example.test",
        },
        "context": {
            "name": CONTEXT,
            "endpoint": "https://cluster.example.test",
        },
        "kubernetes_owner": OWNER,
        "role": None,
        "association": None,
    }


def _owned_state() -> dict[str, Any]:
    state = _base_state()
    state["role"] = {
        "name": ROLE_NAME,
        "arn": ROLE_ARN,
        "owner": OWNER,
        "trust": _trust_policy(),
        "inline_policies": {POLICY_NAME: _bedrock_policy()},
        "attached_policy_count": 0,
        "instance_profile_count": 0,
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
        "owner_arn": None,
    }
    return state


def _install_fake_kubectl(bin_dir: pathlib.Path) -> None:
    _write_executable(
        bin_dir / "kubectl",
        """
        #!/usr/bin/env python3
        import json
        import os
        import pathlib
        import sys

        args = sys.argv[1:]
        state = json.loads(pathlib.Path(os.environ["FAKE_STATE"]).read_text())
        with pathlib.Path(os.environ["FAKE_KUBE_LOG"]).open("a") as log:
            log.write(json.dumps(args) + "\\n")

        context = state["context"]
        if args[:2] == ["config", "get-contexts"]:
            if len(args) > 2 and args[2] == context["name"]:
                print(context["name"])
            raise SystemExit(0)
        if args[:2] == ["config", "view"]:
            if "--context" in args and args[args.index("--context") + 1] == context["name"]:
                print(context["endpoint"])
                raise SystemExit(0)
            raise SystemExit(40)
        if args == ["--context", context["name"], "get", "--raw=/readyz"]:
            print("ok")
            raise SystemExit(0)
        if args[:4] == [
            "--context",
            context["name"],
            "get",
            "namespace/openclaw-enterprise-agw",
        ]:
            print(f"openclaw-enterprise-agw|{state['kubernetes_owner']}")
            raise SystemExit(0)
        if args[:4] == [
            "--context",
            context["name"],
            "get",
            "serviceaccount/agentgateway",
        ]:
            print(f"agentgateway|{state['kubernetes_owner']}")
            raise SystemExit(0)
        print(f"unsupported kubectl call: {args}", file=sys.stderr)
        raise SystemExit(41)
        """,
    )


def _install_fake_aws(bin_dir: pathlib.Path) -> None:
    _write_executable(
        bin_dir / "aws",
        """
        #!/usr/bin/env python3
        import json
        import os
        import pathlib
        import sys

        args = sys.argv[1:]
        state_path = pathlib.Path(os.environ["FAKE_STATE"])
        state = json.loads(state_path.read_text())
        with pathlib.Path(os.environ["FAKE_AWS_LOG"]).open("a") as log:
            log.write(json.dumps(args) + "\\n")

        if args[:3] != ["--no-cli-pager", "--region", "us-west-2"]:
            print("missing explicit region", file=sys.stderr)
            raise SystemExit(50)
        service, operation = args[3:5]
        query = args[args.index("--query") + 1] if "--query" in args else ""
        role = state["role"]
        association = state["association"]

        def value_after(option):
            return args[args.index(option) + 1]

        def save():
            state_path.write_text(json.dumps(state))

        if (service, operation) == ("sts", "get-caller-identity"):
            print(state["account"])
        elif (service, operation) == ("eks", "describe-cluster"):
            cluster = state["cluster"]
            print("\\t".join([cluster["name"], cluster["arn"], cluster["endpoint"]]))
        elif (service, operation) == ("iam", "get-role"):
            if role is None:
                print("NoSuchEntity", file=sys.stderr)
                raise SystemExit(254)
            if query == "Role.AssumeRolePolicyDocument":
                print(json.dumps(role["trust"]))
            else:
                print(
                    "\\t".join(
                        [
                            role["name"],
                            role["arn"],
                            role["owner"],
                            role["permissions_boundary"] or "None",
                        ]
                    )
                )
        elif (service, operation) == ("iam", "list-role-policies"):
            print("\\t".join(role["inline_policies"]))
        elif (service, operation) == ("iam", "list-attached-role-policies"):
            print(role["attached_policy_count"])
        elif (service, operation) == ("iam", "list-instance-profiles-for-role"):
            print(role["instance_profile_count"])
        elif (service, operation) == ("iam", "get-role-policy"):
            name = value_after("--policy-name")
            policy = role["inline_policies"].get(name)
            if policy is None:
                print("NoSuchEntity", file=sys.stderr)
                raise SystemExit(254)
            print(json.dumps(policy))
        elif (service, operation) == ("eks", "list-pod-identity-associations"):
            print(association["id"] if association else "None")
        elif (service, operation) == ("eks", "describe-pod-identity-association"):
            if association is None:
                print("ResourceNotFoundException", file=sys.stderr)
                raise SystemExit(254)
            if query == "association.[roleArn,tags.ManagedBy,ownerArn]":
                print(
                    "\\t".join(
                        [
                            association["role_arn"],
                            association["owner"],
                            association["owner_arn"] or "None",
                        ]
                    )
                )
            else:
                print(
                    "\\t".join(
                        [
                            association["cluster"],
                            association["id"],
                            association["namespace"],
                            association["service_account"],
                            association["role_arn"],
                            association["arn"],
                            association["owner"],
                            association["owner_arn"] or "None",
                        ]
                    )
                )
        elif (service, operation) == ("iam", "create-role"):
            trust_path = pathlib.Path(
                value_after("--assume-role-policy-document").removeprefix("file://")
            )
            state["role"] = {
                "name": value_after("--role-name"),
                "arn": "arn:aws:iam::111122223333:role/"
                + value_after("--role-name"),
                "owner": "openclaw-enterprise-blueprint",
                "trust": json.loads(trust_path.read_text()),
                "inline_policies": {},
                "attached_policy_count": 0,
                "instance_profile_count": 0,
                "permissions_boundary": None,
            }
            save()
            print(state["role"]["arn"])
        elif (service, operation) == ("iam", "put-role-policy"):
            policy_path = pathlib.Path(
                value_after("--policy-document").removeprefix("file://")
            )
            state["role"]["inline_policies"][value_after("--policy-name")] = json.loads(
                policy_path.read_text()
            )
            save()
            if state.get("fail_after_operation") == "iam:put-role-policy":
                print("simulated response failure", file=sys.stderr)
                raise SystemExit(70)
        elif (service, operation) == ("eks", "create-pod-identity-association"):
            state["association"] = {
                "cluster": value_after("--cluster-name"),
                "id": "a-abcdefghijklmnopq",
                "namespace": value_after("--namespace"),
                "service_account": value_after("--service-account"),
                "role_arn": value_after("--role-arn"),
                "arn": (
                    "arn:aws:eks:us-west-2:111122223333:"
                    "podidentityassociation/shared-cluster/a-abcdefghijklmnopq"
                ),
                "owner": "openclaw-enterprise-blueprint",
                "owner_arn": None,
            }
            save()
            print(state["association"]["id"])
            if state.get("fail_after_operation") == "eks:create-pod-identity-association":
                print("simulated response failure", file=sys.stderr)
                raise SystemExit(70)
        elif (service, operation) == ("eks", "delete-pod-identity-association"):
            if association is not None:
                state["association"] = None
                save()
        elif (service, operation) == ("iam", "delete-role-policy"):
            if state["role"] is not None:
                state["role"]["inline_policies"].pop(
                    value_after("--policy-name"), None
                )
                save()
        elif (service, operation) == ("iam", "delete-role"):
            state["role"] = None
            save()
        else:
            print(f"unsupported aws call: {args}", file=sys.stderr)
            raise SystemExit(51)
        """,
    )


def _run_setup(
    tmp_path: pathlib.Path,
    *,
    state: dict[str, Any] | None = None,
    args: tuple[str, ...] = ARGS,
) -> tuple[
    subprocess.CompletedProcess[str],
    list[list[str]],
    list[list[str]],
    dict[str, Any],
]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _install_fake_aws(bin_dir)
    _install_fake_kubectl(bin_dir)
    state_path = tmp_path / "state.json"
    state_path.write_text(json.dumps(state or _base_state()), encoding="utf-8")
    aws_log = tmp_path / "aws.log"
    kube_log = tmp_path / "kubectl.log"
    aws_log.write_text("", encoding="utf-8")
    kube_log.write_text("", encoding="utf-8")
    result = subprocess.run(
        ["bash", str(SCRIPT), *args],
        check=False,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "FAKE_STATE": str(state_path),
            "FAKE_AWS_LOG": str(aws_log),
            "FAKE_KUBE_LOG": str(kube_log),
        },
    )
    aws_calls = [
        json.loads(line) for line in aws_log.read_text(encoding="utf-8").splitlines()
    ]
    kube_calls = [
        json.loads(line) for line in kube_log.read_text(encoding="utf-8").splitlines()
    ]
    final_state = json.loads(state_path.read_text(encoding="utf-8"))
    return result, aws_calls, kube_calls, final_state


def _mutating_aws_calls(calls: list[list[str]]) -> list[list[str]]:
    operations = {
        "create-role",
        "put-role-policy",
        "create-pod-identity-association",
    }
    return [call for call in calls if operations.intersection(call)]


def test_setup_requires_every_target_identifier() -> None:
    result = subprocess.run(
        ["bash", str(SCRIPT)],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert "--aws-region is required" in result.stderr
    assert "--aws-account-id is required" in result.stderr
    assert "--eks-cluster-name is required" in result.stderr
    assert "--kube-context is required" in result.stderr


def test_setup_creates_exact_owned_identity_without_inference_profiles(
    tmp_path: pathlib.Path,
) -> None:
    result, aws_calls, _, state = _run_setup(tmp_path)

    assert result.returncode == 0, result.stderr
    assert [call[4] for call in _mutating_aws_calls(aws_calls)] == [
        "create-role",
        "put-role-policy",
        "create-pod-identity-association",
    ]
    assert state["role"]["owner"] == OWNER
    assert state["role"]["trust"] == _trust_policy()
    assert state["role"]["inline_policies"] == {POLICY_NAME: _bedrock_policy()}
    assert "inference-profile" not in json.dumps(state["role"])
    assert "InferenceProfileArn" not in json.dumps(state["role"])
    assert state["association"] == _owned_state()["association"]
    create_role = next(call for call in aws_calls if "create-role" in call)
    create_association = next(
        call for call in aws_calls if "create-pod-identity-association" in call
    )
    assert create_role[create_role.index("--tags") + 1] == (
        f"Key=ManagedBy,Value={OWNER}"
    )
    assert create_association[create_association.index("--tags") + 1] == (
        f"ManagedBy={OWNER}"
    )


def test_setup_is_idempotent_for_the_exact_owned_identity(
    tmp_path: pathlib.Path,
) -> None:
    result, aws_calls, _, _ = _run_setup(tmp_path, state=_owned_state())

    assert result.returncode == 0, result.stderr
    assert _mutating_aws_calls(aws_calls) == []
    assert ASSOCIATION_ID in result.stdout


@pytest.mark.parametrize(
    "failed_operation",
    [
        "iam:put-role-policy",
        "eks:create-pod-identity-association",
    ],
)
def test_setup_rolls_back_partial_creation(
    tmp_path: pathlib.Path,
    failed_operation: str,
) -> None:
    state = _base_state()
    state["fail_after_operation"] = failed_operation

    result, aws_calls, _, final_state = _run_setup(tmp_path, state=state)

    assert result.returncode != 0
    assert "rolling back resources created by this invocation" in result.stderr
    assert final_state["association"] is None
    assert final_state["role"] is None
    assert any("delete-role" in call for call in aws_calls)
    if failed_operation == "eks:create-pod-identity-association":
        assert any("delete-pod-identity-association" in call for call in aws_calls)


@pytest.mark.parametrize(
    ("change", "message"),
    [
        ({"account": "999900001111"}, "authenticated to account"),
        (
            {"context": {"name": CONTEXT, "endpoint": "https://wrong.example.test"}},
            "does not target the explicit EKS cluster",
        ),
    ],
)
def test_setup_refuses_account_or_context_mismatch_before_mutation(
    tmp_path: pathlib.Path,
    change: dict[str, Any],
    message: str,
) -> None:
    state = _base_state()
    state.update(change)
    result, aws_calls, _, _ = _run_setup(tmp_path, state=state)

    assert result.returncode != 0
    assert message in result.stderr
    assert _mutating_aws_calls(aws_calls) == []


def test_setup_refuses_unowned_kubernetes_target_before_aws_mutation(
    tmp_path: pathlib.Path,
) -> None:
    state = _base_state()
    state["kubernetes_owner"] = "another-sample"
    result, aws_calls, _, _ = _run_setup(tmp_path, state=state)

    assert result.returncode != 0
    assert "namespace is absent or not owned" in result.stderr
    assert aws_calls == []


@pytest.mark.parametrize(
    ("change", "message"),
    [
        ({"role": {**_owned_state()["role"], "owner": "another-sample"}}, "not tagged"),
        (
            {
                "association": {
                    **_owned_state()["association"],
                    "namespace": "another-namespace",
                }
            },
            "does not match the explicit cluster, namespace, service account, and role",
        ),
    ],
)
def test_setup_refuses_unowned_or_mismatched_existing_resources_before_mutation(
    tmp_path: pathlib.Path,
    change: dict[str, Any],
    message: str,
) -> None:
    state = _owned_state()
    state.update(change)
    result, aws_calls, _, _ = _run_setup(tmp_path, state=state)

    assert result.returncode != 0
    assert message in result.stderr
    assert _mutating_aws_calls(aws_calls) == []


@pytest.mark.parametrize(
    ("mutate_role", "message"),
    [
        (
            lambda role: role["trust"]["Statement"][0]["Condition"][
                "StringEquals"
            ].update({"aws:SourceAccount": "999900001111"}),
            "unexpected trust policy",
        ),
        (
            lambda role: role["inline_policies"][POLICY_NAME].update(
                {
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Action": "bedrock:InvokeModel",
                            "Resource": (
                                f"arn:aws:bedrock:{REGION}:{ACCOUNT}:"
                                "inference-profile/us.example"
                            ),
                        }
                    ]
                }
            ),
            "exact regional foundation-model access",
        ),
        (
            lambda role: role["inline_policies"].update(
                {"unexpected-policy": {"Version": "2012-10-17", "Statement": []}}
            ),
            "unexpected inline policy set",
        ),
    ],
)
def test_setup_refuses_existing_identity_policy_drift_before_mutation(
    tmp_path: pathlib.Path,
    mutate_role: Any,
    message: str,
) -> None:
    state = _owned_state()
    mutate_role(state["role"])
    result, aws_calls, _, _ = _run_setup(tmp_path, state=state)

    assert result.returncode != 0
    assert message in result.stderr
    assert _mutating_aws_calls(aws_calls) == []
