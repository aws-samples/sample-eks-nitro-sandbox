"""Crash-recovery contracts for AgentGateway key rotation."""

from __future__ import annotations

import shlex
import shutil
import signal
from pathlib import Path

import pytest

from test_setup_agentgateway import (
    NAMESPACE,
    STATE_FILES,
    _assert_no_setup_journal,
    _clear_stale_setup_lock,
    _run,
    _without_resource_versions,
    _write_executable,
)


def _journal_keysets(journal: Path) -> list[dict[str, bytes]]:
    return [
        {name: (candidate / name).read_bytes() for name in STATE_FILES}
        for candidate in journal.iterdir()
        if candidate.is_dir()
        and all((candidate / name).is_file() for name in STATE_FILES)
    ]


@pytest.mark.parametrize(
    ("state_updates", "local_keys_rotated"),
    [
        (
            {
                "kill_get_once_after_replace": {
                    "after": (
                        f"{NAMESPACE}|configmap|agentgateway-config"
                    ),
                    "target": f"{NAMESPACE}|secret|agw-client-key",
                }
            },
            False,
        ),
        (
            {
                "kill_get_once_after_successful_rollout_for": [
                    f"{NAMESPACE}|deployment.apps|agentgateway"
                ]
            },
            True,
        ),
    ],
)
def test_active_rotation_journal_restores_original_state_after_sigkill(
    tmp_path: Path,
    state_updates: dict[str, object],
    local_keys_rotated: bool,
) -> None:
    initial, initial_state, _, state_dir = _run(tmp_path)
    assert initial.returncode == 0, initial.stderr
    original_files = {name: (state_dir / name).read_bytes() for name in STATE_FILES}
    interrupted, interrupted_state, _, _ = _run(
        tmp_path,
        state_dir=state_dir,
        rotate=True,
        state_updates=state_updates,
    )

    assert interrupted.returncode == -signal.SIGKILL
    journal = state_dir / ".setup-agentgateway.journal"
    assert (journal / "journal-mode").read_text().strip() == "rotation"
    assert (journal / "journal-phase").read_text().strip() == "active"
    assert _without_resource_versions(interrupted_state["objects"]) != (
        _without_resource_versions(initial_state["objects"])
    )
    interrupted_files = {
        name: (state_dir / name).read_bytes() for name in STATE_FILES
    }
    assert (interrupted_files != original_files) is local_keys_rotated

    replace_count = len(interrupted_state.get("replace_order", []))
    _clear_stale_setup_lock(state_dir)
    restarted, final_state, _, _ = _run(
        tmp_path,
        state_dir=state_dir,
        state_updates={"kill_get_on_counts": {}},
    )

    assert restarted.returncode == 0, restarted.stderr
    assert _without_resource_versions(final_state["objects"]) == (
        _without_resource_versions(initial_state["objects"])
    )
    assert {name: (state_dir / name).read_bytes() for name in STATE_FILES} == (
        original_files
    )
    if local_keys_rotated:
        assert final_state["replace_order"][replace_count:] == [
            f"{NAMESPACE}|configmap|agentgateway-config",
            f"{NAMESPACE}|secret|agw-client-key",
            f"{NAMESPACE}|secret|agw-session-key",
            f"{NAMESPACE}|deployment.apps|agentgateway",
        ]
    _assert_no_setup_journal(state_dir)


def test_failed_recovery_preserves_journal_for_next_run(tmp_path: Path) -> None:
    initial, initial_state, _, state_dir = _run(tmp_path)
    assert initial.returncode == 0, initial.stderr
    original_files = {name: (state_dir / name).read_bytes() for name in STATE_FILES}

    interrupted, interrupted_state, _, _ = _run(
        tmp_path,
        state_dir=state_dir,
        rotate=True,
        state_updates={
            "kill_get_once_after_replace": {
                "after": f"{NAMESPACE}|configmap|agentgateway-config",
                "target": f"{NAMESPACE}|secret|agw-client-key",
            }
        },
    )
    assert interrupted.returncode == -signal.SIGKILL
    journal = state_dir / ".setup-agentgateway.journal"
    assert (journal / "state-backup").is_dir()
    journal_keysets = _journal_keysets(journal)
    assert original_files in journal_keysets
    assert any(keyset != original_files for keyset in journal_keysets)

    configmap_key = f"{NAMESPACE}|configmap|agentgateway-config"
    failed_count = interrupted_state["get_counts"][configmap_key] + 1
    _clear_stale_setup_lock(state_dir)
    failed, _, _, _ = _run(
        tmp_path,
        state_dir=state_dir,
        state_updates={
            "fail_get_on_counts": {configmap_key: failed_count},
        },
    )

    assert failed.returncode != 0
    assert "preserved recovery material" in failed.stderr
    assert _journal_keysets(journal) == journal_keysets
    assert (journal / "journal-mode").read_text().strip() == "rotation"
    assert (journal / "journal-phase").read_text().strip() == "active"

    restarted, final_state, _, _ = _run(
        tmp_path,
        state_dir=state_dir,
        state_updates={"fail_get_on_counts": {}},
    )

    assert restarted.returncode == 0, restarted.stderr
    assert _without_resource_versions(final_state["objects"]) == (
        _without_resource_versions(initial_state["objects"])
    )
    assert {name: (state_dir / name).read_bytes() for name in STATE_FILES} == (
        original_files
    )
    _assert_no_setup_journal(state_dir)


@pytest.mark.parametrize("partial_marker", ["journal-mode", "journal-phase"])
def test_incomplete_journal_header_restarts_safely(
    tmp_path: Path,
    partial_marker: str,
) -> None:
    state_dir = tmp_path / "private-state"
    journal = state_dir / ".setup-agentgateway.journal"
    journal.mkdir(parents=True, mode=0o700)
    marker_value = "setup" if partial_marker == "journal-mode" else "active"
    marker = journal / partial_marker
    marker.write_text(f"{marker_value}\n")
    marker.chmod(0o600)
    (journal / ".kubeconfig.interrupted").write_text("partial")

    result, state, _, _ = _run(tmp_path, state_dir=state_dir)

    assert result.returncode == 0, result.stderr
    assert len(state["objects"]) == 12
    _assert_no_setup_journal(state_dir)


def test_empty_existing_journal_directory_restarts_safely(tmp_path: Path) -> None:
    state_dir = tmp_path / "private-state"
    journal = state_dir / ".setup-agentgateway.journal"
    journal.mkdir(parents=True, mode=0o700)

    result, state, _, _ = _run(tmp_path, state_dir=state_dir)

    assert result.returncode == 0, result.stderr
    assert len(state["objects"]) == 12
    _assert_no_setup_journal(state_dir)


def test_committed_rotation_journal_keeps_rotated_state_after_sigkill(
    tmp_path: Path,
) -> None:
    initial, _, _, state_dir = _run(tmp_path)
    assert initial.returncode == 0, initial.stderr
    original_files = {name: (state_dir / name).read_bytes() for name in STATE_FILES}
    real_mv = shutil.which("mv")
    assert real_mv is not None
    mv_wrapper = tmp_path / "bin" / "mv"
    _write_executable(
        mv_wrapper,
        f"""
        #!/usr/bin/env bash
        set -euo pipefail
        {shlex.quote(real_mv)} "$@"
        destination="${{!#}}"
        if [[ "${{destination}}" == */.setup-agentgateway.journal/journal-phase ]] &&
          grep -qx committed "${{destination}}"; then
          kill -KILL "${{PPID}}"
        fi
        """,
    )

    interrupted, interrupted_state, _, _ = _run(
        tmp_path,
        state_dir=state_dir,
        rotate=True,
    )

    assert interrupted.returncode == -signal.SIGKILL
    journal = state_dir / ".setup-agentgateway.journal"
    assert (journal / "journal-mode").read_text().strip() == "rotation"
    assert (journal / "journal-phase").read_text().strip() == "committed"
    rotated_files = {name: (state_dir / name).read_bytes() for name in STATE_FILES}
    assert all(rotated_files[name] != original_files[name] for name in STATE_FILES)
    mv_wrapper.unlink()

    _clear_stale_setup_lock(state_dir)
    restarted, final_state, _, _ = _run(
        tmp_path,
        state_dir=state_dir,
        rotate=True,
    )

    assert restarted.returncode == 0, restarted.stderr
    assert "completed rotation recovered" in restarted.stdout
    assert final_state["objects"] == interrupted_state["objects"]
    assert {name: (state_dir / name).read_bytes() for name in STATE_FILES} == (
        rotated_files
    )
    _assert_no_setup_journal(state_dir)
