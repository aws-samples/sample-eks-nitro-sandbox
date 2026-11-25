"""Contract tests for the EKS Auto Mode StorageClass setup."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import textwrap
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "deploy" / "storage-class.yaml"
SCRIPT = ROOT / "scripts" / "setup-storage-class.sh"
NAME = "openclaw-enterprise-gp3"
CONTEXT = "openclaw-test"
OWNER = "openclaw-enterprise-blueprint"
STORAGE_CLASS_UID = "uid-storage-class-123"
CLUSTER_ENDPOINT = "https://cluster.example.test"


def _storage_class(*, live: bool = False) -> dict[str, Any]:
    storage_class = {
        "apiVersion": "storage.k8s.io/v1",
        "kind": "StorageClass",
        "metadata": {
            "name": NAME,
            "labels": {
                "app.kubernetes.io/name": NAME,
                "app.kubernetes.io/component": "storage",
                "app.kubernetes.io/managed-by": OWNER,
                "app.kubernetes.io/part-of": OWNER,
            },
            "annotations": {
                "storageclass.kubernetes.io/is-default-class": "false",
            },
        },
        "provisioner": "ebs.csi.eks.amazonaws.com",
        "parameters": {
            "type": "gp3",
            "encrypted": "true",
        },
        "reclaimPolicy": "Delete",
        "volumeBindingMode": "WaitForFirstConsumer",
        "allowVolumeExpansion": True,
    }
    if live:
        storage_class["metadata"]["uid"] = STORAGE_CLASS_UID
    return storage_class


def _write_executable(path: Path, source: str) -> None:
    path.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def _install_fake_kubectl(bin_dir: Path) -> None:
    _write_executable(
        bin_dir / "kubectl",
        """
        #!/usr/bin/env python3
        import json
        import os
        from pathlib import Path
        import sys

        args = sys.argv[1:]
        state_path = Path(os.environ["FAKE_KUBE_STATE"])
        log_path = Path(os.environ["FAKE_KUBE_LOG"])
        state = json.loads(state_path.read_text(encoding="utf-8"))
        with log_path.open("a", encoding="utf-8") as log:
            log.write(json.dumps(args) + "\\n")

        offset = 0
        snapshot_path = None
        if args[:1] == ["--kubeconfig"]:
            snapshot_path = Path(args[1])
            if not snapshot_path.is_file():
                print("missing kubeconfig snapshot", file=sys.stderr)
                raise SystemExit(30)
            snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
            state.setdefault("kubeconfig_observations", []).append(
                {
                    "path": str(snapshot_path),
                    "mode": snapshot_path.stat().st_mode & 0o777,
                    "endpoint": snapshot["clusters"][0]["cluster"]["server"],
                }
            )
            state_path.write_text(json.dumps(state), encoding="utf-8")
            offset = 2

        has_global_context = False
        if args[offset : offset + 1] == ["--context"]:
            has_global_context = True
            if args[offset + 1] != state["context"]:
                print("missing or incorrect explicit context", file=sys.stderr)
                raise SystemExit(30)
            offset += 2

        command = args[offset:]
        if command[:2] == ["config", "get-contexts"]:
            if command[2] == state["context"]:
                print(state["context"])
            raise SystemExit(0)

        if command[:2] == ["config", "view"]:
            selected_context = (
                state["context"]
                if has_global_context
                else command[command.index("--context") + 1]
                if "--context" in command
                else None
            )
            if selected_context != state["context"]:
                print("missing or incorrect explicit context", file=sys.stderr)
                raise SystemExit(30)
            if "--flatten" in command:
                print(
                    json.dumps(
                        {
                            "apiVersion": "v1",
                            "kind": "Config",
                            "current-context": state["context"],
                            "contexts": [
                                {
                                    "name": state["context"],
                                    "context": {
                                        "cluster": "test-cluster",
                                        "user": "test-user",
                                    },
                                }
                            ],
                            "clusters": [
                                {
                                    "name": "test-cluster",
                                    "cluster": {"server": state["endpoint"]},
                                }
                            ],
                            "users": [{"name": "test-user", "user": {}}],
                        }
                    )
                )
                if state.get("replace_endpoint_after_snapshot"):
                    state["endpoint"] = "https://changed.example.test"
                    state_path.write_text(json.dumps(state), encoding="utf-8")
                raise SystemExit(0)
            if snapshot_path is not None:
                print(snapshot["clusters"][0]["cluster"]["server"])
                raise SystemExit(0)
            print("missing or incorrect explicit context", file=sys.stderr)
            raise SystemExit(30)

        if snapshot_path is None or not has_global_context:
            print("missing or incorrect explicit context", file=sys.stderr)
            raise SystemExit(30)

        if command == ["get", "--raw=/readyz"]:
            print("ok")
            raise SystemExit(0)

        if command[:2] == ["get", "storageclass"]:
            if state.get("read_error"):
                print("simulated read failure", file=sys.stderr)
                raise SystemExit(31)
            storage_class = state.get("storage_class")
            if storage_class is None:
                if "--ignore-not-found" in command:
                    raise SystemExit(0)
                print("NotFound", file=sys.stderr)
                raise SystemExit(1)
            print(json.dumps(storage_class))
            raise SystemExit(0)

        if command[:2] == ["create", "--filename"]:
            if state.get("storage_class") is not None:
                print("AlreadyExists", file=sys.stderr)
                raise SystemExit(1)
            state["storage_class"] = state["create_result"]
            state_path.write_text(json.dumps(state), encoding="utf-8")
            print(json.dumps(state["storage_class"]))
            raise SystemExit(0)

        if command[:1] == ["delete"] and any(
            value.startswith("--raw=") for value in command
        ):
            delete_options = json.load(sys.stdin)
            current = state.get("storage_class")
            if state.get("replace_before_uid_delete") and current:
                current["metadata"]["uid"] = (
                    f"replacement-{current['metadata']['uid']}"
                )
                state_path.write_text(json.dumps(state), encoding="utf-8")
            expected_uid = delete_options["preconditions"]["uid"]
            if current and current["metadata"].get("uid") == expected_uid:
                state["storage_class"] = None
                state_path.write_text(json.dumps(state), encoding="utf-8")
                print(json.dumps({"status": "Success"}))
            elif current:
                print("UID precondition failed", file=sys.stderr)
                raise SystemExit(1)
            raise SystemExit(0)

        print(f"unsupported kubectl call: {args}", file=sys.stderr)
        raise SystemExit(32)
        """,
    )


def _install_fake_python3(bin_dir: Path) -> None:
    _write_executable(
        bin_dir / "python3",
        f"""
        #!{sys.executable}
        import os
        import sys

        args = sys.argv[1:]
        failure = os.environ.get("FAKE_RECEIPT_PYTHON_FAILURE")
        if "-c" in args:
            source = args[args.index("-c") + 1]
            markers = {{
                "temp-fsync": "os.fsync(temporary.fileno())",
                "link": "os.link(source, destination",
                "unlink": "os.unlink(sys.argv[1])",
                "directory-fsync": "os.fsync(directory)",
            }}
            if failure in markers and markers[failure] in source:
                print(f"simulated {{failure}} failure", file=sys.stderr)
                raise SystemExit(70)

        os.execv({sys.executable!r}, [{sys.executable!r}, *args])
        """,
    )


def _run_script(
    tmp_path: Path,
    storage_class: dict[str, Any] | None,
    *,
    create_result: dict[str, Any] | None = None,
    read_error: bool = False,
    replace_before_uid_delete: bool = False,
    replace_endpoint_after_snapshot: bool = False,
    receipt_python_failure: str | None = None,
    args: tuple[str, ...] = ("--kube-context", CONTEXT),
) -> tuple[subprocess.CompletedProcess[str], list[list[str]], dict[str, Any]]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _install_fake_kubectl(bin_dir)
    if receipt_python_failure is not None:
        _install_fake_python3(bin_dir)

    state_path = tmp_path / "state.json"
    log_path = tmp_path / "kubectl.log"
    state = {
        "context": CONTEXT,
        "endpoint": CLUSTER_ENDPOINT,
        "storage_class": storage_class,
        "expected_storage_class": _storage_class(live=True),
        "create_result": create_result or _storage_class(live=True),
        "read_error": read_error,
        "replace_before_uid_delete": replace_before_uid_delete,
        "replace_endpoint_after_snapshot": replace_endpoint_after_snapshot,
    }
    state_path.write_text(json.dumps(state), encoding="utf-8")
    env = os.environ.copy()
    env.update(
        {
            "FAKE_KUBE_STATE": str(state_path),
            "FAKE_KUBE_LOG": str(log_path),
            "FAKE_RECEIPT_PYTHON_FAILURE": receipt_python_failure or "",
            "PATH": f"{bin_dir}{os.pathsep}{env['PATH']}",
        }
    )

    result = subprocess.run(
        ["bash", str(SCRIPT), *args],
        text=True,
        capture_output=True,
        env=env,
        check=False,
        timeout=10,
    )
    calls = (
        [
            json.loads(line)
            for line in log_path.read_text(encoding="utf-8").splitlines()
        ]
        if log_path.exists()
        else []
    )
    final_state = json.loads(state_path.read_text(encoding="utf-8"))
    return result, calls, final_state


def _kubectl_command(call: list[str]) -> list[str]:
    offset = 0
    if call[offset : offset + 1] == ["--kubeconfig"]:
        offset += 2
    if call[offset : offset + 1] == ["--context"]:
        offset += 2
    return call[offset:]


def _create_calls(calls: list[list[str]]) -> list[list[str]]:
    return [
        call
        for call in calls
        if _kubectl_command(call)[:2] == ["create", "--filename"]
    ]


def _delete_calls(calls: list[list[str]]) -> list[list[str]]:
    return [
        call for call in calls if _kubectl_command(call)[:1] == ["delete"]
    ]


def test_manifest_is_sample_owned_encrypted_gp3_and_non_default() -> None:
    manifest = yaml.safe_load(MANIFEST.read_text(encoding="utf-8"))

    assert manifest == _storage_class()


def test_script_requires_an_explicit_kube_context(tmp_path: Path) -> None:
    result, calls, _ = _run_script(tmp_path, None, args=())

    assert result.returncode == 2
    assert "--kube-context is required" in result.stderr
    assert calls == []


def test_absent_storage_class_is_created_once_and_selected(tmp_path: Path) -> None:
    result, calls, final_state = _run_script(tmp_path, None)

    assert result.returncode == 0, result.stderr
    assert result.stdout == f"{NAME}\n"
    assert len(_create_calls(calls)) == 1
    assert final_state["storage_class"] == _storage_class(live=True)
    resource_calls = [
        call
        for call in calls
        if _kubectl_command(call)[:1] in (["get"], ["create"], ["delete"])
    ]
    assert all(
        call[:1] == ["--kubeconfig"]
        and call[2:4] == ["--context", CONTEXT]
        for call in resource_calls
    )
    storage_reads = [
        call
        for call in calls
        if _kubectl_command(call)[:2] == ["get", "storageclass"]
    ]
    assert len(storage_reads) == 1


def test_invalid_create_response_is_rolled_back_by_exact_uid(
    tmp_path: Path,
) -> None:
    invalid = _storage_class(live=True)
    invalid["parameters"]["encrypted"] = "false"

    result, calls, final_state = _run_script(
        tmp_path,
        None,
        create_result=invalid,
    )

    assert result.returncode != 0
    assert "parameters.encrypted must be true" in result.stderr
    assert final_state["storage_class"] is None
    assert any(
        _kubectl_command(call)[:1] == ["delete"]
        and any(value.startswith("--raw=") for value in call)
        for call in calls
    )


def test_rollback_preserves_a_concurrently_recreated_storage_class(
    tmp_path: Path,
) -> None:
    invalid = _storage_class(live=True)
    invalid["parameters"]["encrypted"] = "false"

    result, _, final_state = _run_script(
        tmp_path,
        None,
        create_result=invalid,
        replace_before_uid_delete=True,
    )

    assert result.returncode != 0
    assert final_state["storage_class"] is not None
    assert final_state["storage_class"]["metadata"]["uid"].startswith("replacement-")
    assert "rollback could not delete StorageClass" in result.stderr


def test_matching_storage_class_is_validated_without_mutation(tmp_path: Path) -> None:
    result, calls, final_state = _run_script(tmp_path, _storage_class(live=True))

    assert result.returncode == 0, result.stderr
    assert result.stdout == f"{NAME}\n"
    assert _create_calls(calls) == []
    assert final_state["storage_class"] == _storage_class(live=True)


@pytest.mark.parametrize(
    ("existing", "created"),
    [(None, True), (_storage_class(live=True), False)],
    ids=["created", "reused"],
)
def test_receipt_records_exact_storage_class_identity_and_provenance(
    tmp_path: Path,
    existing: dict[str, Any] | None,
    created: bool,
) -> None:
    receipt = tmp_path / "storage-class-receipt.json"

    result, calls, _ = _run_script(
        tmp_path,
        existing,
        args=(
            "--kube-context",
            CONTEXT,
            "--receipt",
            str(receipt),
        ),
    )

    assert result.returncode == 0, result.stderr
    assert json.loads(receipt.read_text(encoding="utf-8")) == {
        "version": 1,
        "operation": "setup-storage-class",
        "kubeContext": CONTEXT,
        "clusterEndpoint": CLUSTER_ENDPOINT,
        "resource": {
            "apiVersion": "storage.k8s.io/v1",
            "kind": "StorageClass",
            "name": NAME,
            "uid": STORAGE_CLASS_UID,
            "created": created,
        },
    }
    assert stat.S_IMODE(receipt.stat().st_mode) == 0o600
    assert not Path(f"{receipt}.lock").exists()
    assert list(tmp_path.glob(f".{receipt.name}.tmp.*")) == []
    assert all(
        call[:1] == ["--kubeconfig"]
        or _kubectl_command(call)[:2]
        in (["config", "get-contexts"], ["config", "view"])
        for call in calls
    )


def test_kubectl_uses_a_private_stable_kubeconfig_snapshot(
    tmp_path: Path,
) -> None:
    receipt = tmp_path / "storage-class-receipt.json"

    result, calls, final_state = _run_script(
        tmp_path,
        None,
        replace_endpoint_after_snapshot=True,
        args=(
            "--kube-context",
            CONTEXT,
            "--receipt",
            str(receipt),
        ),
    )

    assert result.returncode == 0, result.stderr
    assert final_state["endpoint"] == "https://changed.example.test"
    assert json.loads(receipt.read_text(encoding="utf-8"))["clusterEndpoint"] == (
        CLUSTER_ENDPOINT
    )
    observations = final_state["kubeconfig_observations"]
    snapshot_paths = {item["path"] for item in observations}
    assert len(snapshot_paths) == 1
    assert {item["mode"] for item in observations} == {0o600}
    assert {item["endpoint"] for item in observations} == {CLUSTER_ENDPOINT}
    assert all(not Path(path).exists() for path in snapshot_paths)
    assert [
        _kubectl_command(call)[:2]
        for call in calls
        if "--kubeconfig" not in call
    ] == [
        ["config", "get-contexts"],
        ["config", "view"],
    ]


def test_kubeconfig_snapshot_lives_in_the_receipt_directory(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    receipt_dir = tmp_path / "receipts"
    receipt_dir.mkdir(mode=0o700)
    receipt = receipt_dir / "storage-class-receipt.json"
    empty_tmpdir = tmp_path / "read-only-tmp"
    empty_tmpdir.mkdir()
    empty_tmpdir.chmod(0o500)
    monkeypatch.setenv("TMPDIR", str(empty_tmpdir))

    result, _, final_state = _run_script(
        tmp_path,
        None,
        args=("--kube-context", CONTEXT, "--receipt", str(receipt)),
    )

    assert result.returncode == 0, result.stderr
    snapshot_paths = {item["path"] for item in final_state["kubeconfig_observations"]}
    assert len(snapshot_paths) == 1
    snapshot = Path(snapshot_paths.pop())
    assert snapshot.parent.parent == receipt_dir
    assert snapshot.parent.name.startswith(".setup-storage-class-kubeconfig.")
    assert not snapshot.parent.exists()
    assert list(empty_tmpdir.iterdir()) == []


def test_existing_receipt_lock_is_preserved(tmp_path: Path) -> None:
    receipt = tmp_path / "storage-class-receipt.json"
    lock = Path(f"{receipt}.lock")
    lock.mkdir(mode=0o700)
    owner = lock / "owner"
    owner.write_text("another-invocation\n", encoding="utf-8")
    owner.chmod(0o600)

    result, calls, final_state = _run_script(
        tmp_path,
        None,
        args=(
            "--kube-context",
            CONTEXT,
            "--receipt",
            str(receipt),
        ),
    )

    assert result.returncode != 0
    assert "already in use or has a stale lock" in result.stderr
    assert owner.read_text(encoding="utf-8") == "another-invocation\n"
    assert final_state["storage_class"] is None
    assert _create_calls(calls) == []


def test_group_or_world_writable_receipt_parent_is_rejected(
    tmp_path: Path,
) -> None:
    receipt_parent = tmp_path / "shared"
    receipt_parent.mkdir(mode=0o700)
    receipt_parent.chmod(0o777)
    receipt = receipt_parent / "storage-class-receipt.json"

    result, calls, final_state = _run_script(
        tmp_path,
        None,
        args=(
            "--kube-context",
            CONTEXT,
            "--receipt",
            str(receipt),
        ),
    )

    assert result.returncode != 0
    assert "must not be writable by group or other users" in result.stderr
    assert not Path(f"{receipt}.lock").exists()
    assert final_state["storage_class"] is None
    assert _create_calls(calls) == []


@pytest.mark.parametrize(
    "failure",
    ["temp-fsync", "link"],
    ids=["temporary-file-fsync", "publish-link"],
)
def test_prepublication_receipt_failure_rolls_back_created_storage_class(
    tmp_path: Path,
    failure: str,
) -> None:
    receipt = tmp_path / "storage-class-receipt.json"

    result, calls, final_state = _run_script(
        tmp_path,
        None,
        receipt_python_failure=failure,
        args=(
            "--kube-context",
            CONTEXT,
            "--receipt",
            str(receipt),
        ),
    )

    assert result.returncode != 0
    assert "could not atomically write lifecycle receipt" in result.stderr
    assert not receipt.exists()
    assert final_state["storage_class"] is None
    assert len(_delete_calls(calls)) == 1
    assert list(tmp_path.glob(f".{receipt.name}.tmp.*")) == []


@pytest.mark.parametrize(
    ("failure", "expected_error"),
    [
        ("unlink", "temporary-state cleanup failed"),
        ("directory-fsync", "parent directory could not be synced"),
    ],
    ids=["temporary-unlink", "directory-fsync"],
)
def test_postpublication_receipt_failure_keeps_resource_and_visible_receipt(
    tmp_path: Path,
    failure: str,
    expected_error: str,
) -> None:
    receipt = tmp_path / "storage-class-receipt.json"

    result, calls, final_state = _run_script(
        tmp_path,
        None,
        receipt_python_failure=failure,
        args=(
            "--kube-context",
            CONTEXT,
            "--receipt",
            str(receipt),
        ),
    )

    assert result.returncode != 0
    assert expected_error in result.stderr
    assert "StorageClass remains committed" in result.stderr
    assert json.loads(receipt.read_text(encoding="utf-8"))["resource"]["uid"] == (
        STORAGE_CLASS_UID
    )
    assert stat.S_IMODE(receipt.stat().st_mode) == 0o600
    assert final_state["storage_class"] == _storage_class(live=True)
    assert _delete_calls(calls) == []
    assert list(tmp_path.glob(f".{receipt.name}.tmp.*")) == []


def test_failed_validation_leaves_no_receipt_or_partial_file(
    tmp_path: Path,
) -> None:
    storage_class = _storage_class(live=True)
    storage_class["parameters"]["encrypted"] = "false"
    receipt = tmp_path / "storage-class-receipt.json"

    result, _, _ = _run_script(
        tmp_path,
        storage_class,
        args=(
            "--kube-context",
            CONTEXT,
            "--receipt",
            str(receipt),
        ),
    )

    assert result.returncode != 0
    assert not receipt.exists()
    assert list(tmp_path.glob(f".{receipt.name}.tmp.*")) == []


Mutation = Callable[[dict[str, Any]], None]


@pytest.mark.parametrize(
    ("mutate", "expected_error"),
    [
        (
            lambda item: item.update(provisioner="ebs.csi.aws.com"),
            "provisioner must be ebs.csi.eks.amazonaws.com",
        ),
        (
            lambda item: item["parameters"].update(type="gp2"),
            "parameters.type must be gp3",
        ),
        (
            lambda item: item["parameters"].update(encrypted="false"),
            "parameters.encrypted must be true",
        ),
        (
            lambda item: item.update(reclaimPolicy="Retain"),
            "reclaimPolicy must be Delete",
        ),
        (
            lambda item: item.update(volumeBindingMode="Immediate"),
            "volumeBindingMode must be WaitForFirstConsumer",
        ),
        (
            lambda item: item.update(allowVolumeExpansion=False),
            "allowVolumeExpansion must be true",
        ),
        (
            lambda item: item["metadata"]["annotations"].update(
                {"storageclass.kubernetes.io/is-default-class": "true"}
            ),
            "GA default-class annotation must be explicitly false",
        ),
        (
            lambda item: item["metadata"]["annotations"].update(
                {"storageclass.beta.kubernetes.io/is-default-class": "true"}
            ),
            "beta default-class annotation must be absent or false",
        ),
        (
            lambda item: item["metadata"]["labels"].update(
                {"app.kubernetes.io/managed-by": "someone-else"}
            ),
            "app.kubernetes.io/managed-by ownership label does not match",
        ),
    ],
    ids=[
        "wrong-provisioner",
        "wrong-volume-type",
        "unencrypted",
        "wrong-reclaim-policy",
        "wrong-binding-mode",
        "no-expansion",
        "ga-default",
        "beta-default",
        "foreign-owner",
    ],
)
def test_existing_contract_drift_fails_without_mutation(
    tmp_path: Path,
    mutate: Mutation,
    expected_error: str,
) -> None:
    storage_class = _storage_class()
    mutate(storage_class)
    original = json.loads(json.dumps(storage_class))

    result, calls, final_state = _run_script(tmp_path, storage_class)

    assert result.returncode != 0
    assert expected_error in result.stderr
    assert "refusing to patch or adopt it" in result.stderr
    assert _create_calls(calls) == []
    assert final_state["storage_class"] == original


def test_read_failure_does_not_attempt_creation(tmp_path: Path) -> None:
    result, calls, final_state = _run_script(
        tmp_path,
        None,
        read_error=True,
    )

    assert result.returncode != 0
    assert "could not read StorageClass" in result.stderr
    assert _create_calls(calls) == []
    assert final_state["storage_class"] is None
