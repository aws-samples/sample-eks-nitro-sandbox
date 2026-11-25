"""Contracts for the per-tenant private model-gateway path."""

from __future__ import annotations

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
SCRIPT = SAMPLE / "scripts" / "configure-tenant-model-gateway.sh"
OWNER = "openclaw-enterprise-blueprint"
CONTEXT = "shared-cluster"
TENANT = "tenant-a"
TENANT_RESOURCES = (
    "configmap/agentgateway-ca",
    "networkpolicy.networking.k8s.io/oce-private-service-egress",
)
CLUSTER_DNS_CIDR = "10.100.0.10/32"
AGENTGATEWAY_SERVICE_IP = "10.100.42.17"


def _write_executable(path: pathlib.Path, source: str) -> None:
    path.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
    path.chmod(0o755)


def _install_fake_kubectl(bin_dir: pathlib.Path) -> None:
    source = """
        #!/usr/bin/env python3
        import base64
        import json
        import os
        import pathlib
        import sys

        args = sys.argv[1:]
        state_path = pathlib.Path(os.environ["FAKE_KUBE_STATE"])
        state = json.loads(state_path.read_text())
        stdin = sys.stdin.read()
        with pathlib.Path(os.environ["FAKE_KUBE_LOG"]).open("a") as log:
            log.write(json.dumps({"args": args, "stdin": stdin}) + "\\n")

        if args[:2] == ["config", "get-contexts"]:
            if len(args) > 2 and args[2] == state["context"]:
                print(state["context"])
            raise SystemExit(0)

        if args[:2] != ["--context", state["context"]]:
            print("wrong context", file=sys.stderr)
            raise SystemExit(40)
        command = args[2:]

        if command == ["get", "--raw=/readyz"]:
            print("ok")
        elif command[:2] == ["get", f"namespace/{state['tenant']}"]:
            print(
                f"{state['tenant']}|"
                f"{state.get('namespace_owner', 'openclaw-enterprise')}|"
                "uid-namespace"
            )
        elif command[:2] == ["wait", "--namespace"]:
            pass
        elif command[:3] == ["get", "secret", "agentgateway-ca"]:
            print(base64.b64encode(b"test-ca").decode())
        elif (
            command[:3] == ["get", "configmap", "agentgateway-ca"]
            and command[-1] == "jsonpath={.data.ca\\\\.crt}"
        ):
            sys.stdout.write("test-ca")
        elif (
            command[:3] == ["get", "service", "agentgateway"]
            and command[-1] == "--output=jsonpath={.spec.clusterIP}"
        ):
            print(state.get("agentgateway_service_ip", "10.100.42.17"))
        elif command and command[0] == "get" and command[-1] == "--output=json":
            resource = command[1]
            if resource == "networkpolicy.networking.k8s.io/oce-private-service-egress":
                pass
            elif resource != "configmap/agentgateway-ca":
                print(f"unsupported kubectl call: {args}", file=sys.stderr)
                raise SystemExit(41)
            document = state.get("objects", {}).get(resource)
            if document is None or resource not in state.get("resources", {}):
                print(f"Error from server (NotFound): {resource}", file=sys.stderr)
                raise SystemExit(1)
            name = resource.rsplit("/", 1)[1]
            document["metadata"]["uid"] = state.get("uids", {}).get(resource, f"uid-{name}")
            print(json.dumps(document))
        elif command and command[0] == "get":
            resource = command[1]
            if resource == state.get("fail_get"):
                print("Unable to connect to the server", file=sys.stderr)
                raise SystemExit(1)
            owner = state.get("resources", {}).get(resource)
            if owner is not None:
                name = resource.rsplit("/", 1)[1]
                uid = state.get("uids", {}).get(resource, f"uid-{name}")
                print(f"{name}|{owner}|{uid}")
        elif command[:2] == ["label", f"namespace/{state['tenant']}"]:
            # An object that appears after the preflight read and before the first-run create.
            resource = state.pop("appear_on_label", None)
            if resource is not None:
                owner = "openclaw-enterprise-blueprint"
                state.setdefault("resources", {})[resource] = owner
                state.setdefault("uids", {})[resource] = "uid-intruder"
                state.setdefault("objects", {})[resource] = {
                    "apiVersion": "networking.k8s.io/v1",
                    "kind": "NetworkPolicy",
                    "metadata": {
                        "name": resource.rsplit("/", 1)[1],
                        "namespace": state["tenant"],
                        "labels": {"app.kubernetes.io/managed-by": owner},
                    },
                    "spec": {
                        "podSelector": {},
                        "policyTypes": ["Egress"],
                        "egress": [{"to": [{"ipBlock": {"cidr": "10.0.0.0/8"}}]}],
                    },
                }
                state_path.write_text(json.dumps(state))
        elif command[:3] == ["create", "configmap", "agentgateway-ca"]:
            print(
                json.dumps(
                    {
                        "apiVersion": "v1",
                        "kind": "ConfigMap",
                        "metadata": {
                            "name": "agentgateway-ca",
                            "namespace": state["tenant"],
                        },
                        "data": {"ca.crt": "test-ca"},
                    }
                )
            )
        elif command[:3] == ["create", "--filename", "-"] or (
            command[:1] == ["apply"] and command[-2:] == ["--filename", "-"]
        ):
            document = json.loads(stdin)
            name = document["metadata"]["name"]
            resource = (
                f"configmap/{name}"
                if document["kind"] == "ConfigMap"
                else f"networkpolicy.networking.k8s.io/{name}"
            )
            exists = resource in state.get("resources", {})
            if command[0] == "create" and exists:
                print(
                    f"Error from server (AlreadyExists): {resource} already exists",
                    file=sys.stderr,
                )
                raise SystemExit(1)
            state.setdefault("resources", {})[resource] = document["metadata"][
                "labels"
            ]["app.kubernetes.io/managed-by"]
            uid = state.get("uids", {}).get(resource, f"uid-{name}")
            document["metadata"]["uid"] = uid
            state.setdefault("objects", {})[resource] = document
            # A delete and same-name recreate between this mutation and the script's next read.
            if resource in state.get("replace_after_create", []):
                state["replace_after_create"].remove(resource)
                state.setdefault("uids", {})[resource] = "uid-replacement"
            state_path.write_text(json.dumps(state))
            if command[-1] == "--output=json":
                created = json.loads(json.dumps(document))
                created["metadata"]["uid"] = uid
                print(json.dumps(created))
        elif command[:1] == ["patch"] and "--type=json" in command:
            # A JSON Patch is applied atomically: a failed operation leaves the object unchanged.
            resource = command[1]
            patch_file = next(
                value.split("=", 1)[1]
                for value in command
                if value.startswith("--patch-file=")
            )
            patch = json.loads(pathlib.Path(patch_file).read_text())
            state.setdefault("patches", []).append(patch)
            state_path.write_text(json.dumps(state))
            document = state.get("objects", {}).get(resource)
            if document is None or resource not in state.get("resources", {}):
                print(f"Error from server (NotFound): {resource}", file=sys.stderr)
                raise SystemExit(1)
            name = resource.rsplit("/", 1)[1]
            working = json.loads(json.dumps(document))
            working["metadata"]["uid"] = state.get("uids", {}).get(resource, f"uid-{name}")
            for operation in patch:
                *parents, last = [
                    token.replace("~1", "/").replace("~0", "~")
                    for token in operation["path"].split("/")[1:]
                ]
                target = working
                for token in parents:
                    target = target[token]
                if operation["op"] == "test":
                    if target.get(last) != operation["value"]:
                        print(
                            "The request is invalid: the server rejected our request "
                            "due to an error in our request",
                            file=sys.stderr,
                        )
                        raise SystemExit(1)
                elif operation["op"] in ("add", "replace"):
                    target[last] = operation["value"]
                else:
                    print(f"unsupported patch operation: {operation}", file=sys.stderr)
                    raise SystemExit(41)
            state["objects"][resource] = working
            state["resources"][resource] = working["metadata"]["labels"][
                "app.kubernetes.io/managed-by"
            ]
            state_path.write_text(json.dumps(state))
            print(f"{resource} patched")
        else:
            print(f"unsupported kubectl call: {args}", file=sys.stderr)
            raise SystemExit(41)
        """
    _write_executable(
        bin_dir / "kubectl",
        source.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1),
    )


def _receipt(tmp_path: pathlib.Path) -> pathlib.Path:
    private_dir = tmp_path / "private"
    private_dir.mkdir(mode=0o700, exist_ok=True)
    return private_dir / f"{TENANT}-model-gateway-receipt.json"


def _run_configure(
    tmp_path: pathlib.Path,
    *,
    state: dict[str, Any] | None = None,
    context: str = CONTEXT,
    rerun: bool = False,
) -> tuple[subprocess.CompletedProcess[str], list[dict[str, Any]]]:
    """Run the script once; with rerun=True, run it again on the same cluster state and receipt."""
    bin_dir = tmp_path / "bin"
    state_path = tmp_path / "kube-state.json"
    if not rerun:
        bin_dir.mkdir()
        _install_fake_kubectl(bin_dir)
        state_path.write_text(
            json.dumps(
                state
                or {
                    "context": CONTEXT,
                    "tenant": TENANT,
                    "resources": {},
                }
            ),
            encoding="utf-8",
        )
    log_path = tmp_path / "kubectl.log"
    log_path.write_text("", encoding="utf-8")
    result = subprocess.run(
        ["bash", str(SCRIPT), context, TENANT, CLUSTER_DNS_CIDR, str(_receipt(tmp_path))],
        check=False,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "FAKE_KUBE_STATE": str(state_path),
            "FAKE_KUBE_LOG": str(log_path),
        },
    )
    calls = [
        json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()
    ]
    return result, calls


def _mutating_calls(calls: list[dict[str, Any]]) -> list[dict[str, Any]]:
    mutations = {"apply", "create", "label", "patch"}
    return [
        call
        for call in calls
        if any(argument in mutations for argument in call["args"])
    ]


def test_configure_script_copies_public_ca_and_allows_exact_private_services() -> None:
    script = SCRIPT.read_text(encoding="utf-8")

    assert "set -euo pipefail" in script
    assert 'readonly -a KUBECTL=(kubectl --context "${KUBE_CONTEXT}")' in script
    assert 'kubectl config get-contexts "${KUBE_CONTEXT}"' in script
    assert "app\\.kubernetes\\.io/managed-by" in script
    assert "pod-security.kubernetes.io/enforce=baseline" in script
    assert "pod-security.kubernetes.io/audit=restricted" in script
    assert "pod-security.kubernetes.io/warn=restricted" in script
    assert "tls\\.crt" in script
    assert "tls\\.key" not in script
    assert "--dry-run=client" in script
    assert ".immutable = true" in script
    assert "NetworkPolicy" in script
    assert "OCE_AGENTGATEWAY_SERVICE_CIDR" not in script


def test_configure_marks_the_created_tenant_resource(
    tmp_path: pathlib.Path,
) -> None:
    result, calls = _run_configure(tmp_path)

    assert result.returncode == 0, result.stderr
    # A first run creates both objects exclusively and reads each UID from the create response.
    created = [
        call
        for call in calls
        if call["args"][2:] == ["create", "--filename", "-", "--output=json"]
    ]
    assert [json.loads(call["stdin"])["kind"] for call in created] == [
        "ConfigMap",
        "NetworkPolicy",
    ]
    assert not any(call["args"][2:3] == ["apply"] for call in calls)
    config_map = json.loads(created[0]["stdin"])
    assert config_map["metadata"]["labels"] == {
        "app.kubernetes.io/managed-by": OWNER
    }
    assert config_map["immutable"] is True
    applied = created[1]
    policy = json.loads(applied["stdin"])
    assert policy["metadata"] == {
        "name": "oce-private-service-egress",
        "namespace": TENANT,
        "labels": {"app.kubernetes.io/managed-by": OWNER},
    }
    assert policy["spec"]["podSelector"]["matchLabels"] == {
        "app.kubernetes.io/managed-by": "openclaw-enterprise",
        "openclaw.dev/workload-role": "gateway",
        "openclaw.dev/network-profile": "broad-egress-v1",
    }
    assert policy["spec"]["policyTypes"] == ["Egress"]
    assert policy["spec"]["egress"] == [
        {
            "to": [{"ipBlock": {"cidr": CLUSTER_DNS_CIDR}}],
            "ports": [
                {"protocol": "UDP", "port": 53},
                {"protocol": "TCP", "port": 53},
            ],
        },
        {
            "to": [
                {
                    "ipBlock": {
                        "cidr": f"{AGENTGATEWAY_SERVICE_IP}/32"
                    }
                }
            ],
            "ports": [{"protocol": "TCP", "port": 443}],
        },
    ]
    assert "0.0.0.0/0" not in applied["stdin"]


@pytest.mark.parametrize("resource", TENANT_RESOURCES)
def test_configure_refuses_unowned_existing_tenant_resources_before_mutation(
    tmp_path: pathlib.Path,
    resource: str,
) -> None:
    result, calls = _run_configure(
        tmp_path,
        state={
            "context": CONTEXT,
            "tenant": TENANT,
            "resources": {resource: "another-sample"},
        },
    )

    assert result.returncode != 0
    assert "does not carry the exact" in result.stderr
    assert _mutating_calls(calls) == []


def test_configure_rejects_a_context_that_does_not_exist_exactly(
    tmp_path: pathlib.Path,
) -> None:
    result, calls = _run_configure(tmp_path, context="shared-cluster-typo")

    assert result.returncode != 0
    assert "does not exist exactly" in result.stderr
    assert _mutating_calls(calls) == []


@pytest.mark.parametrize(
    "cluster_dns_cidr",
    ["10.100.0.10/24", "fd00::a/128", "not-a-cidr"],
)
def test_configure_rejects_invalid_cluster_dns_cidr_before_mutation(
    tmp_path: pathlib.Path,
    cluster_dns_cidr: str,
) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _install_fake_kubectl(bin_dir)
    state_path = tmp_path / "kube-state.json"
    state_path.write_text(
        json.dumps(
            {"context": CONTEXT, "tenant": TENANT, "resources": {}}
        ),
        encoding="utf-8",
    )
    log_path = tmp_path / "kubectl.log"
    log_path.write_text("", encoding="utf-8")

    result = subprocess.run(
        ["bash", str(SCRIPT), CONTEXT, TENANT, cluster_dns_cidr, str(_receipt(tmp_path))],
        check=False,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "FAKE_KUBE_STATE": str(state_path),
            "FAKE_KUBE_LOG": str(log_path),
        },
    )

    assert result.returncode != 0
    assert "exact IPv4 /32" in result.stderr
    calls = [
        json.loads(line)
        for line in log_path.read_text(encoding="utf-8").splitlines()
    ]
    assert _mutating_calls(calls) == []


@pytest.mark.parametrize(
    "service_ip",
    ["None", "fd00::17", "not-an-address"],
)
def test_configure_rejects_invalid_agentgateway_service_ip_before_mutation(
    tmp_path: pathlib.Path,
    service_ip: str,
) -> None:
    result, calls = _run_configure(
        tmp_path,
        state={
            "context": CONTEXT,
            "tenant": TENANT,
            "agentgateway_service_ip": service_ip,
            "resources": {},
        },
    )

    assert result.returncode != 0
    assert "AgentGateway Service address must be an IPv4 address" in result.stderr
    assert _mutating_calls(calls) == []


def test_configure_stops_when_a_tenant_resource_lookup_fails(
    tmp_path: pathlib.Path,
) -> None:
    result, calls = _run_configure(
        tmp_path,
        state={
            "context": CONTEXT,
            "tenant": TENANT,
            "resources": {},
            "fail_get": "configmap/agentgateway-ca",
        },
    )

    assert result.returncode != 0
    assert (
        "configure-tenant-model-gateway: could not determine ownership of "
        "configmap/agentgateway-ca in tenant-a."
    ) in result.stderr
    assert any(
        call["args"][2:4] == ["get", "configmap/agentgateway-ca"] for call in calls
    )
    assert _mutating_calls(calls) == []


def test_configure_records_the_uids_of_the_objects_it_creates(
    tmp_path: pathlib.Path,
) -> None:
    result, _ = _run_configure(tmp_path)

    assert result.returncode == 0, result.stderr
    receipt = _receipt(tmp_path)
    assert receipt.stat().st_mode & 0o777 == 0o600
    assert json.loads(receipt.read_text(encoding="utf-8")) == {
        "version": 1,
        "operation": "configure-tenant-model-gateway",
        "kubeContext": CONTEXT,
        "namespace": TENANT,
        "resources": [
            {
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "name": "agentgateway-ca",
                "uid": "uid-agentgateway-ca",
            },
            {
                "apiVersion": "networking.k8s.io/v1",
                "kind": "NetworkPolicy",
                "name": "oce-private-service-egress",
                "uid": "uid-oce-private-service-egress",
            },
        ],
    }
    assert sorted(path.name for path in receipt.parent.iterdir()) == [receipt.name]


def test_configure_rerun_changes_only_the_recorded_objects(
    tmp_path: pathlib.Path,
) -> None:
    first, _ = _run_configure(tmp_path)
    assert first.returncode == 0, first.stderr

    result, calls = _run_configure(tmp_path, rerun=True)

    assert result.returncode == 0, result.stderr
    assert [call["args"][2] for call in _mutating_calls(calls)] == ["label", "patch"]
    # One JSON Patch from a private file: test the recorded UID, then set only the spec and owner label.
    patch_call = _mutating_calls(calls)[1]
    assert patch_call["args"][2:6] == [
        "patch",
        TENANT_RESOURCES[1],
        "--namespace",
        TENANT,
    ]
    assert "--type=json" in patch_call["args"]
    assert any(value.startswith("--patch-file=") for value in patch_call["args"])
    assert not any("/metadata/uid" in value for value in patch_call["args"])
    state = json.loads((tmp_path / "kube-state.json").read_text(encoding="utf-8"))
    policy = state["objects"][TENANT_RESOURCES[1]]
    assert state["patches"] == [
        [
            {"op": "test", "path": "/metadata/uid", "value": "uid-oce-private-service-egress"},
            {"op": "replace", "path": "/spec", "value": policy["spec"]},
            {
                "op": "add",
                "path": "/metadata/labels/app.kubernetes.io~1managed-by",
                "value": OWNER,
            },
        ]
    ]


def test_configure_rerun_writes_nothing_to_a_replacement_made_after_the_preflight(
    tmp_path: pathlib.Path,
) -> None:
    first, _ = _run_configure(tmp_path)
    assert first.returncode == 0, first.stderr
    receipt_before = _receipt(tmp_path).read_text(encoding="utf-8")
    policy = TENANT_RESOURCES[1]
    state_path = tmp_path / "kube-state.json"
    state = json.loads(state_path.read_text(encoding="utf-8"))
    # A same-name policy replaces the recorded one during the namespace label call: after the receipt UID
    # preflight and before the policy write.
    state["appear_on_label"] = policy
    state_path.write_text(json.dumps(state), encoding="utf-8")

    result, calls = _run_configure(tmp_path, rerun=True)

    # No write lands on the replacement: no name-based apply, and the replacement keeps its own spec.
    assert not any(call["args"][2:3] == ["apply"] for call in calls)
    after = json.loads(state_path.read_text(encoding="utf-8"))
    replacement = after["objects"][policy]
    assert after["uids"][policy] == "uid-intruder"
    assert replacement["spec"]["egress"] == [{"to": [{"ipBlock": {"cidr": "10.0.0.0/8"}}]}]
    # The run fails closed and the receipt is unchanged.
    assert result.returncode != 0
    assert (
        "configure-tenant-model-gateway: networkpolicy/oce-private-service-egress in "
        f"{TENANT} is not the object {_receipt(tmp_path)} records, or could not be written; "
        "refusing to change it."
    ) in result.stderr
    assert _receipt(tmp_path).read_text(encoding="utf-8") == receipt_before


@pytest.mark.parametrize("resource", TENANT_RESOURCES)
def test_configure_refuses_a_same_name_replacement_before_mutation(
    tmp_path: pathlib.Path,
    resource: str,
) -> None:
    first, _ = _run_configure(tmp_path)
    assert first.returncode == 0, first.stderr
    receipt_before = _receipt(tmp_path).read_text(encoding="utf-8")
    state_path = tmp_path / "kube-state.json"
    state = json.loads(state_path.read_text(encoding="utf-8"))
    # Another object with the same name and the sample's owner label, as after a delete and recreate.
    state.setdefault("uids", {})[resource] = "uid-replacement"
    state_path.write_text(json.dumps(state), encoding="utf-8")

    result, calls = _run_configure(tmp_path, rerun=True)

    assert result.returncode != 0
    assert "was replaced since" in result.stderr
    assert "refusing to change it." in result.stderr
    assert _mutating_calls(calls) == []
    assert _receipt(tmp_path).read_text(encoding="utf-8") == receipt_before


@pytest.mark.parametrize("resource", TENANT_RESOURCES)
def test_configure_refuses_to_adopt_an_unrecorded_object(
    tmp_path: pathlib.Path,
    resource: str,
) -> None:
    result, calls = _run_configure(
        tmp_path,
        state={
            "context": CONTEXT,
            "tenant": TENANT,
            "resources": {resource: OWNER},
        },
    )

    assert result.returncode != 0
    assert "does not record it; refusing to adopt it." in result.stderr
    assert _mutating_calls(calls) == []
    assert not _receipt(tmp_path).exists()


@pytest.mark.parametrize("resource", TENANT_RESOURCES)
def test_configure_first_run_refuses_an_object_replaced_after_its_create(
    tmp_path: pathlib.Path,
    resource: str,
) -> None:
    # The object is deleted and recreated under the same name between the create and the follow-up read.
    result, _ = _run_configure(
        tmp_path,
        state={
            "context": CONTEXT,
            "tenant": TENANT,
            "resources": {},
            "replace_after_create": [resource],
        },
    )

    assert result.returncode != 0
    assert (
        f"configure-tenant-model-gateway: {resource} in {TENANT} is not the object this run "
        "created or recorded, or its content differs from what this run wrote; refusing to "
        "continue."
    ) in result.stderr
    assert sorted(path.name for path in _receipt(tmp_path).parent.iterdir()) == []


def test_configure_first_run_refuses_a_policy_that_appears_before_its_create(
    tmp_path: pathlib.Path,
) -> None:
    policy = TENANT_RESOURCES[1]
    # A same-name policy with the sample's owner label appears after the preflight read.
    result, calls = _run_configure(
        tmp_path,
        state={
            "context": CONTEXT,
            "tenant": TENANT,
            "resources": {},
            "appear_on_label": policy,
        },
    )

    assert result.returncode != 0
    assert (
        "configure-tenant-model-gateway: could not create "
        f"networkpolicy/oce-private-service-egress in {TENANT} as a new object."
    ) in result.stderr
    assert not any(call["args"][2:3] == ["apply"] for call in calls)
    state = json.loads((tmp_path / "kube-state.json").read_text(encoding="utf-8"))
    assert state["objects"][policy]["spec"]["egress"] == [
        {"to": [{"ipBlock": {"cidr": "10.0.0.0/8"}}]}
    ]
    assert sorted(path.name for path in _receipt(tmp_path).parent.iterdir()) == []


def test_readme_step_7_recovers_an_interrupted_first_run() -> None:
    readme = (SAMPLE / "README.md").read_text(encoding="utf-8")
    step = readme.split("**Step 7:", 1)[1].split("**Step 8:", 1)[0]
    recovery = step.split("If the first run was interrupted before it wrote the receipt", 1)[1]
    recovery = recovery.split("\nOCE creates the tenant namespace", 1)[0]
    text = " ".join(recovery.split())

    steps = [
        "first confirm that no tenant Agent has started",
        (
            "--selector 'app.kubernetes.io/managed-by=openclaw-enterprise,"
            "openclaw.dev/workload-role=gateway'"
        ),
        "Then inspect only the two objects the script creates",
        "get configmap/agentgateway-ca networkpolicy/oce-private-service-egress",
        (
            "Delete, deliberately and by name, only the object that the refusal names as "
            "not recorded by the receipt."
        ),
        "delete configmap/agentgateway-ca",
        "Then rerun `configure-tenant-model-gateway.sh` with the same receipt path.",
        (
            "The script reports one unrecorded object per run, so when both objects exist you "
            "need two delete-and-rerun rounds. Repeat until the rerun reports no unrecorded object."
        ),
        "when the refusal says an object is missing or was replaced since the receipt recorded it.",
    ]
    positions = [text.index(" ".join(part.split())) for part in steps]
    assert positions == sorted(positions)
    # Only the two sample-owned objects are inspected or deleted, and nothing is deleted in bulk.
    commands = re.findall(r"```bash\n(.*?)```", recovery, re.DOTALL)
    assert len(commands) == 3
    assert all("--context \"$KUBE_CONTEXT\" --namespace \"$TENANT_NAMESPACE\"" in c for c in commands)
    deletes = [line for c in commands for line in c.splitlines() if " delete" in f" {line}"]
    assert [line.strip() for line in deletes] == ["delete configmap/agentgateway-ca"]
    assert "--all" not in recovery and "--selector" not in commands[2]
    # The refusal points the operator here, and it stops at the first unrecorded object, which is why
    # the page asks for one delete-and-rerun round per object.
    script = SCRIPT.read_text(encoding="utf-8")
    assert "If the first run was interrupted, follow README Step 7." in script
    refusal_loop = script.split('for live in "configmap/agentgateway-ca|', 1)[1].split("\n  done\n", 1)[0]
    assert "die " in refusal_loop and "refusing to adopt it." in refusal_loop
