"""Contract tests for the EKS Auto Mode StorageClass setup."""

from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import subprocess
import textwrap
from typing import Any, Callable

import pytest
import yaml


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "deploy" / "storage-class.yaml"
SCRIPT = ROOT / "scripts" / "setup-storage-class.sh"
NAME = "openclaw-enterprise-gp3"
CONTEXT = "openclaw-test"
OWNER = "openclaw-enterprise-blueprint"


def _storage_class() -> dict[str, Any]:
    return {
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

        if args[:2] != ["--context", state["context"]]:
            print("missing or incorrect explicit context", file=sys.stderr)
            raise SystemExit(30)

        command = args[2:]
        if command[:2] == ["config", "get-contexts"]:
            if command[2] == state["context"]:
                print(state["context"])
            raise SystemExit(0)

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
            state["storage_class"] = state["expected_storage_class"]
            state_path.write_text(json.dumps(state), encoding="utf-8")
            print(f"storageclass.storage.k8s.io/{state['storage_class']['metadata']['name']} created")
            raise SystemExit(0)

        print(f"unsupported kubectl call: {args}", file=sys.stderr)
        raise SystemExit(32)
        """,
    )


def _run_script(
    tmp_path: Path,
    storage_class: dict[str, Any] | None,
    *,
    read_error: bool = False,
    args: tuple[str, ...] = ("--kube-context", CONTEXT),
) -> tuple[subprocess.CompletedProcess[str], list[list[str]], dict[str, Any]]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _install_fake_kubectl(bin_dir)

    state_path = tmp_path / "state.json"
    log_path = tmp_path / "kubectl.log"
    state = {
        "context": CONTEXT,
        "storage_class": storage_class,
        "expected_storage_class": _storage_class(),
        "read_error": read_error,
    }
    state_path.write_text(json.dumps(state), encoding="utf-8")
    env = os.environ.copy()
    env.update(
        {
            "FAKE_KUBE_STATE": str(state_path),
            "FAKE_KUBE_LOG": str(log_path),
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


def _create_calls(calls: list[list[str]]) -> list[list[str]]:
    return [call for call in calls if call[2:4] == ["create", "--filename"]]


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
    assert final_state["storage_class"] == _storage_class()
    assert all(call[:2] == ["--context", CONTEXT] for call in calls)


def test_matching_storage_class_is_validated_without_mutation(tmp_path: Path) -> None:
    result, calls, final_state = _run_script(tmp_path, _storage_class())

    assert result.returncode == 0, result.stderr
    assert result.stdout == f"{NAME}\n"
    assert _create_calls(calls) == []
    assert final_state["storage_class"] == _storage_class()


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
