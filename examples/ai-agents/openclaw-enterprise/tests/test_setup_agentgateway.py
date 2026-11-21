"""Lifecycle contracts for idempotent AgentGateway Kubernetes setup."""

from __future__ import annotations

import base64
import json
import os
import shutil
import stat
import subprocess
import signal
import sys
import textwrap
from pathlib import Path
from typing import Any

import pytest

SAMPLE = Path(__file__).resolve().parent.parent
SCRIPT = SAMPLE / "scripts" / "setup-agentgateway.sh"
CONTEXT = "shared-cluster"
NAMESPACE = "openclaw-enterprise-agw"
OWNER_LABEL = "app.kubernetes.io/managed-by"
OWNER = "openclaw-enterprise-blueprint"
STATE_FILES = (
    "tenant-a-agentgateway.key",
    "tenant-b-agentgateway.key",
    "tenant-a-sha256",
    "tenant-b-sha256",
    "agentgateway-session.key",
)


def _clear_stale_setup_lock(state_dir: Path) -> None:
    lock_dir = state_dir / ".setup-agentgateway.lock.active"
    assert lock_dir.is_dir()
    shutil.rmtree(lock_dir)

FAKE_KUBECTL = r"""
#!/usr/bin/env python3
import base64
import json
import os
from pathlib import Path
import signal
import sys

args = sys.argv[1:]
state_path = Path(os.environ["FAKE_KUBE_STATE"])
log_path = Path(os.environ["FAKE_KUBE_LOG"])
state = json.loads(state_path.read_text())
with log_path.open("a") as log:
    log.write(json.dumps(args) + "\n")

def save():
    state_path.write_text(json.dumps(state))

if args[:1] != ["--kubeconfig"]:
    raise SystemExit("missing snapshotted kubeconfig")
kubeconfig_path = Path(args[1])
snapshot = json.loads(kubeconfig_path.read_text())
if snapshot["context"] != state["context"]:
    raise SystemExit("wrong context in snapshotted kubeconfig")
live_revision = state.setdefault("live_kubeconfig_revision", 1)
args = args[2:]
if snapshot.get("bootstrap"):
    if args == [
        "config",
        "get-contexts",
        state["context"],
        "--no-headers",
        "--output=name",
    ]:
        print(state["context"])
    elif args == [
        "config",
        "view",
        "--raw",
        "--flatten",
        "--minify",
        "--context",
        state["context"],
    ]:
        print(json.dumps({
            "context": state["context"],
            "revision": live_revision,
            "clusters": [{"cluster": {"server": "https://fake.example"}}],
        }))
        if state.get("drift_kubeconfig_after_snapshot"):
            state["live_kubeconfig_revision"] = live_revision + 1
            save()
    else:
        raise SystemExit(f"unsupported bootstrap kubectl call: {args}")
    raise SystemExit(0)
state.setdefault("snapshot_revisions_used", []).append(snapshot["revision"])
save()
if args[:2] != ["--context", state["context"]]:
    raise SystemExit("missing explicit context")
args = args[2:]
if args[:1] == ["--request-timeout=20s"]:
    args = args[1:]

namespace = "_"
if "--namespace" in args:
    index = args.index("--namespace")
    namespace = args[index + 1]
    args = args[:index] + args[index + 2:]

def key(kind, name):
    return f"{namespace}|{kind}|{name}"

def resource_name(kind):
    return {
        "Namespace": "namespace",
        "ServiceAccount": "serviceaccount",
        "Issuer": "issuer.cert-manager.io",
        "Certificate": "certificate.cert-manager.io",
        "Secret": "secret",  # pragma: allowlist secret -- Kubernetes resource kind
        "ConfigMap": "configmap",
        "Deployment": "deployment.apps",
        "PodDisruptionBudget": "poddisruptionbudget.policy",
        "Service": "service",
    }[kind]

def apply_server_defaults(document):
    if document.get("kind") != "Deployment":
        return
    template = document.setdefault("spec", {}).setdefault("template", {})
    template.setdefault("metadata", {}).setdefault("creationTimestamp", None)
    for volume in template.setdefault("spec", {}).get("volumes", []):
        if "configMap" in volume:
            volume["configMap"].setdefault("defaultMode", 420)

if args == ["config", "current-context"]:
    print(state["context"])
elif args[:2] == ["config", "get-contexts"]:
    print(state["context"])
elif args == [
    "config",
    "view",
    "--raw",
    "--minify",
    "--context",
    state["context"],
    "--output=json",
]:
    print(json.dumps({
        "clusters": [{"cluster": {"server": "https://fake.example"}}],
    }))
elif args == ["get", "--raw=/readyz"]:
    print("ok")
elif args[:1] == ["get"]:
    kind, name = args[1], args[2]
    object_key = key(kind, name)
    get_counts = state.setdefault("get_counts", {})
    get_counts[object_key] = get_counts.get(object_key, 0) + 1
    fail_counts = state.get("fail_get_on_counts", {}).get(object_key, [])
    if isinstance(fail_counts, int):
        fail_counts = [fail_counts]
    save()
    if get_counts[object_key] in fail_counts:
        print("simulated get failure", file=sys.stderr)
        raise SystemExit(1)
    armed_after_rollout = state.get(
        "fail_get_once_after_successful_rollout_armed", []
    )
    if object_key in armed_after_rollout:
        armed_after_rollout.remove(object_key)
        state["fail_get_once_after_successful_rollout_armed"] = (
            armed_after_rollout
        )
        save()
        print("simulated post-rollout get failure", file=sys.stderr)
        raise SystemExit(1)
    kill_armed = state.get("kill_get_once_armed", [])
    if object_key in kill_armed:
        kill_armed.remove(object_key)
        state["kill_get_once_armed"] = kill_armed
        save()
        os.kill(os.getppid(), signal.SIGKILL)
        raise SystemExit(1)
    kill_counts = state.get("kill_get_on_counts", {}).get(object_key, [])
    if isinstance(kill_counts, int):
        kill_counts = [kill_counts]
    if get_counts[object_key] in kill_counts:
        os.kill(os.getppid(), signal.SIGKILL)
        raise SystemExit(1)
    value = state["objects"].get(object_key)
    if value:
        print(json.dumps(value))
elif args[:3] == ["create", "secret", "generic"]:
    name = args[3]
    data = {}
    for value in args:
        if value.startswith("--from-file="):
            field, path = value.removeprefix("--from-file=").split("=", 1)
            data[field] = base64.b64encode(Path(path).read_bytes()).decode()
    print(json.dumps({
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": name, "namespace": namespace},
        "data": data,
        "type": "Opaque",
    }))
elif args[:2] == ["create", "--filename"]:
    document = json.loads(Path(args[2]).read_text())
    apply_server_defaults(document)
    metadata = document["metadata"]
    object_namespace = metadata.get("namespace", "_")
    object_key = (
        f"{object_namespace}|{resource_name(document['kind'])}|{metadata['name']}"
    )
    document["metadata"]["uid"] = f"uid-{len(state['objects']) + 1}"
    document["metadata"]["resourceVersion"] = str(len(state["objects"]) + 1)
    state["objects"][object_key] = document
    create_count = state.setdefault("create_count", 0) + 1
    state["create_count"] = create_count
    save()
    if create_count == state.get("kill_after_create_count"):
        os.kill(os.getppid(), signal.SIGKILL)
        raise SystemExit(1)
    if create_count in state.get("empty_create_output_counts", []):
        pass
    elif create_count in state.get("malformed_create_output_counts", []):
        print("{")
    else:
        print(json.dumps(document))
elif args[:1] == ["delete"] and any(
    value.startswith("--raw=") for value in args
):
    path = next(value.removeprefix("--raw=") for value in args if value.startswith("--raw="))
    path_parts = path.strip("/").split("/")
    if path_parts[:2] == ["api", "v1"]:
        if path_parts[2] == "namespaces" and len(path_parts) == 4:
            object_key = f"_|namespace|{path_parts[3]}"
        else:
            resource_map = {
                "serviceaccounts": "serviceaccount",
                "secrets": "secret",  # pragma: allowlist secret -- Kubernetes API resource
                "configmaps": "configmap",
                "services": "service",
            }
            object_key = (
                f"{path_parts[3]}|{resource_map[path_parts[4]]}|{path_parts[5]}"
            )
    else:
        resource_map = {
            ("cert-manager.io", "issuers"): "issuer.cert-manager.io",
            ("cert-manager.io", "certificates"): "certificate.cert-manager.io",
            ("apps", "deployments"): "deployment.apps",
            ("policy", "poddisruptionbudgets"): "poddisruptionbudget.policy",
        }
        object_key = (
            f"{path_parts[4]}|{resource_map[(path_parts[1], path_parts[5])]}|"
            f"{path_parts[6]}"
        )
    delete_options = json.load(sys.stdin)
    current = state["objects"].get(object_key)
    if object_key in state.get("replace_before_uid_delete", []):
        current["metadata"]["uid"] = f"replacement-{current['metadata']['uid']}"
        current["metadata"]["resourceVersion"] = (
            f"replacement-{current['metadata']['resourceVersion']}"
        )
        save()
    expected_uid = delete_options["preconditions"]["uid"]
    current = state["objects"].get(object_key)
    if current and current["metadata"]["uid"] == expected_uid:
        del state["objects"][object_key]
        save()
    elif current:
        print("UID precondition failed", file=sys.stderr)
        raise SystemExit(1)
elif args[:2] == ["delete", "--filename"]:
    document = json.loads(Path(args[2]).read_text())
    metadata = document["metadata"]
    state["objects"].pop(
        f"{metadata.get('namespace', '_')}|{resource_name(document['kind'])}|"
        f"{metadata['name']}",
        None,
    )
    save()
elif args[:2] == ["rollout", "status"]:
    rollout_count = state.setdefault("rollout_count", 0) + 1
    state["rollout_count"] = rollout_count
    mutation = state.get("mutate_before_failed_rollout")
    if mutation:
        current = state["objects"][mutation]
        current.setdefault("metadata", {}).setdefault("labels", {})[
            "test.concurrent-change"
        ] = "true"
        current["metadata"]["resourceVersion"] = str(
            int(current["metadata"]["resourceVersion"]) + 1
        )
    rollout_failed = state.get("fail_rollout") or rollout_count in state.get(
        "fail_rollout_on_counts", []
    )
    if not rollout_failed:
        state["fail_get_once_after_successful_rollout_armed"] = state.pop(
            "fail_get_once_after_successful_rollout_for", []
        )
        state["kill_get_once_armed"] = state.pop(
            "kill_get_once_after_successful_rollout_for", []
        )
    save()
    if rollout_failed:
        print("simulated rollout failure", file=sys.stderr)
        raise SystemExit(1)
elif args[:2] == ["replace", "--filename"]:
    document = json.loads(Path(args[2]).read_text())
    apply_server_defaults(document)
    metadata = document["metadata"]
    object_key = (
        f"{metadata.get('namespace', '_')}|{resource_name(document['kind'])}|"
        f"{metadata['name']}"
    )
    current = state["objects"][object_key]
    state.setdefault("replace_order", []).append(object_key)
    replace_counts = state.setdefault("replace_counts", {})
    replace_counts[object_key] = replace_counts.get(object_key, 0) + 1
    if (
        object_key in state.get("fail_restore_for", [])
        and replace_counts[object_key] > 1
    ):
        save()
        print("simulated restore failure", file=sys.stderr)
        raise SystemExit(1)
    if metadata.get("resourceVersion") != current["metadata"]["resourceVersion"]:
        print("resourceVersion conflict", file=sys.stderr)
        raise SystemExit(1)
    document["metadata"]["uid"] = current["metadata"]["uid"]
    document["metadata"]["resourceVersion"] = str(
        int(current["metadata"]["resourceVersion"]) + 1
    )
    state["objects"][object_key] = document
    kill_after_replace = state.get("kill_get_once_after_replace")
    if kill_after_replace and object_key == kill_after_replace["after"]:
        state.setdefault("kill_get_once_armed", []).append(
            kill_after_replace["target"]
        )
        state.pop("kill_get_once_after_replace")
    save()
    print(json.dumps(document))
else:
    raise SystemExit(f"unsupported kubectl call: {args}")
"""


def _write_executable(path: Path, source: str) -> None:
    path.write_text(textwrap.dedent(source).lstrip())
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def _run(
    tmp_path: Path,
    *,
    state_dir: Path | None = None,
    rotate: bool = False,
    state_updates: dict[str, Any] | None = None,
) -> tuple[subprocess.CompletedProcess[str], dict[str, Any], list[list[str]], Path]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    _write_executable(bin_dir / "kubectl", FAKE_KUBECTL)
    state_path = tmp_path / "kube-state.json"
    if not state_path.exists():
        state_path.write_text(json.dumps({"context": CONTEXT, "objects": {}}))
    if state_updates:
        state = json.loads(state_path.read_text())
        state.update(state_updates)
        state_path.write_text(json.dumps(state))
    log_path = tmp_path / "kubectl-calls.jsonl"
    if not log_path.exists():
        log_path.write_text("")
    state_dir = state_dir or (tmp_path / "private-state")
    if not state_dir.exists():
        state_dir.mkdir(mode=0o700)
    state_dir.chmod(0o700)
    kubeconfig_dir = tmp_path / "private-kubeconfig"
    kubeconfig_dir.mkdir(mode=0o700, exist_ok=True)
    kubeconfig_dir.chmod(0o700)
    kubeconfig = kubeconfig_dir / "config"
    kubeconfig.write_text(json.dumps({
        "context": CONTEXT,
        "revision": json.loads(state_path.read_text()).get(
            "live_kubeconfig_revision", 1
        ),
        "bootstrap": True,
    }))
    kubeconfig.chmod(0o600)
    receipt = state_dir / "agentgateway-lifecycle-receipt.json"
    env = dict(os.environ)
    env.update({
        "PATH": f"{bin_dir}{os.pathsep}{env['PATH']}",
        "FAKE_KUBE_STATE": str(state_path),
        "FAKE_KUBE_LOG": str(log_path),
    })
    command = [
        "bash",
        str(SCRIPT),
        "--kubeconfig",
        str(kubeconfig),
        "--kube-context",
        CONTEXT,
        "--state-dir",
        str(state_dir),
        "--receipt",
        str(receipt),
    ]
    if rotate:
        command.append("--rotate-keys")
    result = subprocess.run(
        command, capture_output=True, check=False, text=True, env=env, timeout=60
    )
    calls = [json.loads(line) for line in log_path.read_text().splitlines()]
    return result, json.loads(state_path.read_text()), calls, state_dir


def _mutations(calls: list[list[str]]) -> list[list[str]]:
    return [
        call
        for call in calls
        if any(operation in call for operation in ("create", "replace", "delete"))
        and "--dry-run=client" not in call
    ]


def _without_resource_versions(objects: dict[str, Any]) -> dict[str, Any]:
    normalized = json.loads(json.dumps(objects))
    for item in normalized.values():
        item.get("metadata", {}).pop("resourceVersion", None)
    return normalized


def _assert_no_setup_journal(state_dir: Path) -> None:
    assert not (state_dir / ".setup-agentgateway.journal").exists()
    lock = state_dir / ".setup-agentgateway.lock"
    assert lock.is_file()
    assert stat.S_IMODE(lock.stat().st_mode) == 0o600
    assert lock.read_bytes() == b""


@pytest.mark.parametrize(
    ("pid_value", "expected_error"),
    [
        (None, "setup lock is incomplete"),
        ("not-a-pid\n", "setup lock is malformed"),
        ("99999999\n", "setup lock is stale"),
    ],
)
def test_existing_setup_lock_fails_closed_until_operator_clears_it(
    tmp_path: Path,
    pid_value: str | None,
    expected_error: str,
) -> None:
    state_dir = tmp_path / "private-state"
    state_dir.mkdir(mode=0o700)
    lock_dir = state_dir / ".setup-agentgateway.lock.active"
    lock_dir.mkdir(mode=0o700)
    if pid_value is not None:
        pid_file = lock_dir / "pid"
        pid_file.write_text(pid_value)
        pid_file.chmod(0o600)

    result, state, calls, _ = _run(tmp_path, state_dir=state_dir)

    assert result.returncode != 0
    assert expected_error in result.stderr
    assert lock_dir.is_dir()
    assert state["objects"] == {}
    assert _mutations(calls) == []


def test_setup_lock_marker_symlink_is_rejected(tmp_path: Path) -> None:
    state_dir = tmp_path / "private-state"
    state_dir.mkdir(mode=0o700)
    target = tmp_path / "outside-lock"
    target.write_text("unchanged")
    (state_dir / ".setup-agentgateway.lock").symlink_to(target)

    result, state, calls, _ = _run(tmp_path, state_dir=state_dir)

    assert result.returncode != 0
    assert "setup lock must not be a symlink" in result.stderr
    assert target.read_text() == "unchanged"
    assert state["objects"] == {}
    assert _mutations(calls) == []


@pytest.mark.parametrize("target_exists", [False, True])
def test_checksum_symlink_is_rejected(
    tmp_path: Path, target_exists: bool
) -> None:
    state_dir = tmp_path / "private-state"
    state_dir.mkdir(mode=0o700)
    target = tmp_path / "outside-checksum"
    if target_exists:
        target.write_text("unchanged")
    (state_dir / "tenant-a-sha256").symlink_to(target)

    result, state, calls, _ = _run(tmp_path, state_dir=state_dir)

    assert result.returncode != 0
    assert "invalid state file: tenant-a-sha256" in result.stderr
    if target_exists:
        assert target.read_text() == "unchanged"
    else:
        assert not target.exists()
    assert state["objects"] == {}
    assert _mutations(calls) == []


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS ACL semantics")
def test_state_directory_with_acl_is_rejected(tmp_path: Path) -> None:
    state_dir = tmp_path / "private-state"
    state_dir.mkdir(mode=0o700)
    subprocess.run(
        ["chmod", "+a", "everyone allow read", str(state_dir)],
        check=True,
    )
    try:
        result, state, calls, _ = _run(tmp_path, state_dir=state_dir)
    finally:
        subprocess.run(["chmod", "-N", str(state_dir)], check=True)

    assert result.returncode != 0
    assert "must not have access-control entries" in result.stderr
    assert state["objects"] == {}
    assert _mutations(calls) == []


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS ACL semantics")
def test_rerun_rejects_acl_on_private_state_file(tmp_path: Path) -> None:
    first, initial_state, first_calls, state_dir = _run(tmp_path)
    assert first.returncode == 0, first.stderr
    seed = state_dir / "tenant-a-agentgateway.key"
    subprocess.run(
        ["chmod", "+a", "everyone allow read", str(seed)],
        check=True,
    )
    mutation_count = len(_mutations(first_calls))
    try:
        second, final_state, all_calls, _ = _run(
            tmp_path, state_dir=state_dir
        )
    finally:
        subprocess.run(["chmod", "-N", str(seed)], check=True)

    assert second.returncode != 0
    assert "invalid state file: tenant-a-agentgateway.key" in second.stderr
    assert final_state["objects"] == initial_state["objects"]
    assert len(_mutations(all_calls)) == mutation_count


def test_kubeconfig_snapshot_is_used_after_live_config_drifts(tmp_path: Path) -> None:
    result, state, calls, _ = _run(
        tmp_path,
        state_updates={"drift_kubeconfig_after_snapshot": True},
    )

    assert result.returncode == 0, result.stderr
    assert calls[0][2:] == [
        "config",
        "get-contexts",
        CONTEXT,
        "--no-headers",
        "--output=name",
    ]
    assert all(call[:1] == ["--kubeconfig"] for call in calls)
    assert state["live_kubeconfig_revision"] == 2
    assert set(state["snapshot_revisions_used"]) == {1}


def test_interrupted_setup_restarts_from_private_journal(tmp_path: Path) -> None:
    interrupted, partial_state, _, state_dir = _run(
        tmp_path,
        state_updates={"kill_after_create_count": 1},
    )

    assert interrupted.returncode == -signal.SIGKILL
    assert len(partial_state["objects"]) == 1
    journal = state_dir / ".setup-agentgateway.journal"
    lock = state_dir / ".setup-agentgateway.lock"
    assert journal.is_dir()
    assert stat.S_IMODE(journal.stat().st_mode) == 0o700
    assert (journal / "journal-mode").read_text().strip() == "setup"
    assert (journal / "journal-phase").read_text().strip() == "active"
    assert stat.S_IMODE((journal / "kubeconfig").stat().st_mode) == 0o600
    assert lock.is_file()
    assert lock.read_text()

    _clear_stale_setup_lock(state_dir)
    restarted, final_state, _, _ = _run(
        tmp_path,
        state_dir=state_dir,
        state_updates={"kill_after_create_count": 0},
    )

    assert restarted.returncode == 0, restarted.stderr
    assert len(final_state["objects"]) == 12
    assert final_state["create_count"] == 12
    _assert_no_setup_journal(state_dir)


@pytest.mark.parametrize(
    "output_fault",
    ["empty_create_output_counts", "malformed_create_output_counts"],
)
def test_create_readback_recovers_unusable_success_output(
    tmp_path: Path,
    output_fault: str,
) -> None:
    result, state, calls, state_dir = _run(
        tmp_path,
        state_updates={output_fault: [1]},
    )

    assert result.returncode == 0, result.stderr
    assert len(state["objects"]) == 12
    receipt = json.loads(
        (state_dir / "agentgateway-lifecycle-receipt.json").read_text()
    )
    assert all(resource["created"] for resource in receipt["resources"])
    assert {resource["uid"] for resource in receipt["resources"]} == {
        resource["metadata"]["uid"] for resource in state["objects"].values()
    }
    namespace_create_index = next(
        index
        for index, call in enumerate(calls)
        if "create" in call
        and call[call.index("create"):call.index("create") + 2]
        == ["create", "--filename"]
        and "create-Namespace-openclaw-enterprise-agw.json"
        in call[call.index("create") + 2]
    )
    readback = calls[namespace_create_index + 1]
    get_index = readback.index("get")
    assert readback[get_index:get_index + 3] == [
        "get",
        "namespace",
        NAMESPACE,
    ]
    _assert_no_setup_journal(state_dir)


def test_failed_create_readback_preserves_journal_and_recovers(
    tmp_path: Path,
) -> None:
    namespace_key = f"_|namespace|{NAMESPACE}"
    interrupted, partial_state, _, state_dir = _run(
        tmp_path,
        state_updates={
            "empty_create_output_counts": [1],
            "fail_get_on_counts": {namespace_key: 2},
        },
    )

    assert interrupted.returncode != 0
    assert namespace_key in partial_state["objects"]
    journal = state_dir / ".setup-agentgateway.journal"
    assert (journal / "journal-mode").read_text().strip() == "setup"
    assert (journal / "journal-phase").read_text().strip() == "active"
    assert (journal / "setup-outcomes").read_text().splitlines()[0].endswith(
        "|pending||false"
    )

    restarted, final_state, _, _ = _run(
        tmp_path,
        state_dir=state_dir,
        state_updates={"fail_get_on_counts": {}},
    )

    assert restarted.returncode == 0, restarted.stderr
    assert len(final_state["objects"]) == 12
    receipt = json.loads(
        (state_dir / "agentgateway-lifecycle-receipt.json").read_text()
    )
    assert all(resource["created"] for resource in receipt["resources"])
    _assert_no_setup_journal(state_dir)


def test_second_run_preserves_key_bytes_and_creates_no_resources(
    tmp_path: Path,
) -> None:
    first, _, first_calls, state_dir = _run(tmp_path)
    assert first.returncode == 0, first.stderr
    original = {name: (state_dir / name).read_bytes() for name in STATE_FILES}
    first_mutation_count = len(_mutations(first_calls))

    second, _, all_calls, _ = _run(tmp_path, state_dir=state_dir)

    assert second.returncode == 0, second.stderr
    assert {name: (state_dir / name).read_bytes() for name in STATE_FILES} == original
    assert len(_mutations(all_calls)) == first_mutation_count


def test_rerun_rejects_hard_linked_seed_without_mutating_resources(
    tmp_path: Path,
) -> None:
    first, initial_state, first_calls, state_dir = _run(tmp_path)
    assert first.returncode == 0, first.stderr
    os.link(
        state_dir / "tenant-a-agentgateway.key",
        tmp_path / "tenant-a-agentgateway-hard-link.key",
    )
    mutation_count = len(_mutations(first_calls))

    second, final_state, all_calls, _ = _run(tmp_path, state_dir=state_dir)

    assert second.returncode != 0
    assert "invalid state file: tenant-a-agentgateway.key" in second.stderr
    assert final_state["objects"] == initial_state["objects"]
    assert len(_mutations(all_calls)) == mutation_count


def test_rerun_accepts_kubernetes_deployment_defaults(tmp_path: Path) -> None:
    first, _, first_calls, state_dir = _run(tmp_path)
    assert first.returncode == 0, first.stderr

    second, state, all_calls, _ = _run(tmp_path, state_dir=state_dir)

    assert second.returncode == 0, second.stderr
    deployment = state["objects"][
        f"{NAMESPACE}|deployment.apps|agentgateway"
    ]
    assert deployment["spec"]["template"]["metadata"]["creationTimestamp"] is None
    assert any(
        volume.get("configMap", {}).get("defaultMode") == 420
        for volume in deployment["spec"]["template"]["spec"]["volumes"]
    )
    assert len(_mutations(all_calls)) == len(_mutations(first_calls))


def test_rerun_refuses_terminating_namespace(tmp_path: Path) -> None:
    first, state, calls, state_dir = _run(tmp_path)
    assert first.returncode == 0, first.stderr
    namespace_key = f"_|namespace|{NAMESPACE}"
    state["objects"][namespace_key]["metadata"]["deletionTimestamp"] = (
        "2026-11-21T00:00:00Z"
    )
    (tmp_path / "kube-state.json").write_text(json.dumps(state))
    mutation_count = len(_mutations(calls))

    result, final, all_calls, _ = _run(tmp_path, state_dir=state_dir)

    assert result.returncode != 0
    assert "different material configuration" in result.stderr
    assert final["objects"][namespace_key] == state["objects"][namespace_key]
    assert len(_mutations(all_calls)) == mutation_count


@pytest.mark.parametrize(
    ("resource_key", "mutate", "message"),
    [
        (
            f"{NAMESPACE}|secret|agw-session-key",
            lambda obj: obj["metadata"]["labels"].update({OWNER_LABEL: "customer"}),
            "without exact blueprint ownership",
        ),
        (
            f"{NAMESPACE}|configmap|agentgateway-config",
            lambda obj: obj.setdefault("data", {}).update({"config.yaml": "drifted"}),
            "different material configuration",
        ),
    ],
)
def test_rerun_refuses_unowned_or_drifted_resources_without_overwrite(
    tmp_path: Path,
    resource_key: str,
    mutate: Any,
    message: str,
) -> None:
    first, state, calls, state_dir = _run(tmp_path)
    assert first.returncode == 0, first.stderr
    mutate(state["objects"][resource_key])
    state_path = tmp_path / "kube-state.json"
    state_path.write_text(json.dumps(state))
    mutation_count = len(_mutations(calls))

    result, final, all_calls, _ = _run(tmp_path, state_dir=state_dir)

    assert result.returncode != 0
    assert message in result.stderr
    assert final["objects"][resource_key] == state["objects"][resource_key]
    assert len(_mutations(all_calls)) == mutation_count


def test_rotate_keys_is_explicit_and_changes_key_bytes(tmp_path: Path) -> None:
    first, _, _, state_dir = _run(tmp_path)
    assert first.returncode == 0, first.stderr
    original = {name: (state_dir / name).read_bytes() for name in STATE_FILES}

    rotated, _, _, _ = _run(tmp_path, state_dir=state_dir, rotate=True)

    assert rotated.returncode == 0, rotated.stderr
    assert any((state_dir / name).read_bytes() != value for name, value in original.items())


def test_failed_rotation_rollout_restores_resources_and_local_keys(
    tmp_path: Path,
) -> None:
    first, initial_state, _, state_dir = _run(tmp_path)
    assert first.returncode == 0, first.stderr
    original_files = {name: (state_dir / name).read_bytes() for name in STATE_FILES}

    rotated, final_state, _, _ = _run(
        tmp_path,
        state_dir=state_dir,
        rotate=True,
        state_updates={"fail_rollout_on_counts": [2]},
    )

    assert rotated.returncode != 0
    assert "AgentGateway rollout did not complete after key rotation" in rotated.stderr
    assert _without_resource_versions(final_state["objects"]) == (
        _without_resource_versions(initial_state["objects"])
    )
    assert {name: (state_dir / name).read_bytes() for name in STATE_FILES} == original_files
    _assert_no_setup_journal(state_dir)
    assert final_state["replace_order"][-4:] == [
        f"{NAMESPACE}|configmap|agentgateway-config",
        f"{NAMESPACE}|secret|agw-client-key",
        f"{NAMESPACE}|secret|agw-session-key",
        f"{NAMESPACE}|deployment.apps|agentgateway",
    ]


def test_failed_rotation_rollback_rollout_preserves_journal(
    tmp_path: Path,
) -> None:
    first, initial_state, _, state_dir = _run(tmp_path)
    assert first.returncode == 0, first.stderr

    rotated, final_state, _, _ = _run(
        tmp_path,
        state_dir=state_dir,
        rotate=True,
        state_updates={"fail_rollout_on_counts": [2, 3]},
    )

    assert rotated.returncode != 0
    assert "restored AgentGateway rollout did not complete" in rotated.stderr
    assert "preserved recovery material" in rotated.stderr
    assert _without_resource_versions(final_state["objects"]) == (
        _without_resource_versions(initial_state["objects"])
    )
    journal = state_dir / ".setup-agentgateway.journal"
    assert (journal / "journal-mode").read_text().strip() == "rotation"
    assert (journal / "journal-phase").read_text().strip() == "active"


def test_post_commit_failure_restores_cluster_then_local_keys(
    tmp_path: Path,
) -> None:
    first, initial_state, _, state_dir = _run(tmp_path)
    assert first.returncode == 0, first.stderr
    original_files = {name: (state_dir / name).read_bytes() for name in STATE_FILES}
    deployment_key = f"{NAMESPACE}|deployment.apps|agentgateway"

    rotated, final_state, _, _ = _run(
        tmp_path,
        state_dir=state_dir,
        rotate=True,
        state_updates={
            "fail_get_once_after_successful_rollout_for": [deployment_key],
        },
    )

    assert rotated.returncode != 0
    assert "could not verify deployment.apps/agentgateway after rollout" in rotated.stderr
    assert "rotation rollback was incomplete" not in rotated.stderr
    assert _without_resource_versions(final_state["objects"]) == (
        _without_resource_versions(initial_state["objects"])
    )
    assert {name: (state_dir / name).read_bytes() for name in STATE_FILES} == original_files
    _assert_no_setup_journal(state_dir)


def test_partial_kubernetes_rollback_preserves_keys_and_recovery_workdir(
    tmp_path: Path,
) -> None:
    first, initial_state, _, state_dir = _run(tmp_path)
    assert first.returncode == 0, first.stderr
    original_files = {name: (state_dir / name).read_bytes() for name in STATE_FILES}
    deployment_key = f"{NAMESPACE}|deployment.apps|agentgateway"
    failed_restore_key = f"{NAMESPACE}|secret|agw-session-key"

    rotated, final_state, _, _ = _run(
        tmp_path,
        state_dir=state_dir,
        rotate=True,
        state_updates={
            "fail_get_once_after_successful_rollout_for": [deployment_key],
            "fail_restore_for": [failed_restore_key],
        },
    )

    assert rotated.returncode != 0
    assert "restore failed for secret/agw-session-key" in rotated.stderr
    assert "rotation rollback was incomplete" in rotated.stderr
    assert "rollback could not prove consistency" in rotated.stderr

    rotated_files = {name: (state_dir / name).read_bytes() for name in STATE_FILES}
    assert all(rotated_files[name] != original_files[name] for name in STATE_FILES)
    assert final_state["objects"][failed_restore_key]["data"]["key"] == (
        base64.b64encode(rotated_files["agentgateway-session.key"]).decode()
    )
    assert final_state["objects"][failed_restore_key] != (
        initial_state["objects"][failed_restore_key]
    )

    recovery_dirs = [
        path
        for path in state_dir.glob(".setup-agentgateway.*")
        if path.name != ".setup-agentgateway.lock"
    ]
    assert len(recovery_dirs) == 1
    recovery_dir = recovery_dirs[0]
    preserved_keysets = [
        {
            name: (candidate / name).read_bytes()
            for name in STATE_FILES
        }
        for candidate in recovery_dir.iterdir()
        if candidate.is_dir()
        and all((candidate / name).is_file() for name in STATE_FILES)
    ]
    assert original_files in preserved_keysets
    assert (state_dir / ".setup-agentgateway.lock").read_bytes() == b""


def test_rotation_rollback_preserves_concurrently_changed_object(
    tmp_path: Path,
) -> None:
    first, initial_state, _, state_dir = _run(tmp_path)
    assert first.returncode == 0, first.stderr
    protected_key = f"{NAMESPACE}|secret|agw-session-key"

    rotated, final_state, _, _ = _run(
        tmp_path,
        state_dir=state_dir,
        rotate=True,
        state_updates={
            "fail_rollout": True,
            "mutate_before_failed_rollout": protected_key,
        },
    )

    assert rotated.returncode != 0
    assert "skipped restore after secret/agw-session-key changed" in rotated.stderr
    assert (
        final_state["objects"][protected_key]["metadata"]["labels"][
            "test.concurrent-change"
        ]
        == "true"
    )
    assert final_state["objects"][protected_key] != initial_state["objects"][protected_key]


def test_failed_rollout_removes_every_object_created_by_this_run(
    tmp_path: Path,
) -> None:
    result, state, calls, _ = _run(
        tmp_path,
        state_updates={"fail_rollout": True},
    )

    assert result.returncode != 0
    assert "AgentGateway rollout did not complete" in result.stderr
    assert state["objects"] == {}
    raw_deletes = [
        call for call in calls
        if "delete" in call and any(value.startswith("--raw=") for value in call)
    ]
    assert len(raw_deletes) == 12


def test_rollback_uid_precondition_preserves_concurrently_recreated_object(
    tmp_path: Path,
) -> None:
    protected_key = f"{NAMESPACE}|service|agentgateway"
    result, state, _, _ = _run(
        tmp_path,
        state_updates={
            "fail_rollout": True,
            "replace_before_uid_delete": [protected_key],
        },
    )

    assert result.returncode != 0
    assert protected_key in state["objects"]
    assert state["objects"][protected_key]["metadata"]["uid"].startswith("replacement-")
    assert "rollback failed for service/agentgateway" in result.stderr
