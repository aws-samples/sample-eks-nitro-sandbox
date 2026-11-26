"""Execute the production timeline reader against private synthetic JSONL."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

READER = Path(__file__).resolve().parents[1] / "scripts/lib/read-native-timeline.cjs"
NODE = shutil.which("node")
# Public, synthetic correlation fixtures; no production identifiers or credentials.
RUN_ID = "chatcmpl_00000000-0000-0000-0000-000000000000"
OTHER_RUN_ID = "chatcmpl_00000000-0000-0000-0000-000000000001"
TRACE_ID = "1" * 32
MAX_DELTA = 2 * 1024 * 1024


def _event(name="provider.request.started", *, call_id="synthetic-call", **changes):
    event = {
        "schemaVersion": "openclaw.diagnostics.v1",
        "runId": RUN_ID,
        "name": name,
        "spanId": call_id,
        "provider": "synthetic-provider",
        "attributes": {
            "traceId": TRACE_ID,
            "model": "synthetic-model",
            "captureId": "synthetic-capture",
            "sequence": 1,
        },
    }
    if name == "provider.request":
        event.update(ok=True, status=200)
    event.update(changes)
    return event


def _pair(*, call_id="synthetic-call"):
    return [
        _event(call_id=call_id),
        _event("provider.request", call_id=call_id),
    ]


def _jsonl(events):
    return "".join(json.dumps(event) + "\n" for event in events).encode()


@pytest.fixture
def timeline(tmp_path):
    tmp_path.chmod(0o700)
    path = tmp_path / "synthetic-timeline.jsonl"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(descriptor)
    return path


def _run(path, mode="mark", cursor=None, run_id=RUN_ID, *, wrong_uid=False):
    assert NODE is not None, "Node is required for production timeline contracts"
    source = READER.read_text(encoding="utf-8")
    if wrong_uid:
        # Exercise the ownership guard without chown or privileged execution.
        source = "process.getuid = () => " + str(os.getuid() + 1) + ";\n" + source
    args = [NODE, "-e", source, mode]
    if mode == "read":
        args.extend([json.dumps(cursor), run_id])
    return subprocess.run(
        args,
        check=False,
        env={"OPENCLAW_DIAGNOSTICS_TIMELINE_PATH": str(path)},
        capture_output=True,
        text=True,
        timeout=5,
    )


def _mark(path):
    result = _run(path)
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    return json.loads(result.stdout)


def _assert_rejected(result, message=None):
    assert result.returncode != 0
    assert result.stdout == ""
    assert result.stderr.strip()
    if message:
        assert message in result.stderr


def test_mark_absent_file_returns_zero_cursor_without_creating_file(tmp_path):
    path = tmp_path / "absent.jsonl"

    assert _mark(path) == {"exists": False, "offset": 0}
    assert not path.exists()


def test_mark_private_file_records_identity_and_exact_byte_offset(timeline):
    # Earlier complete lines are outside the new correlation window.
    prefix = "synthetic previous log: \u2603\n".encode()
    timeline.write_bytes(prefix)

    cursor = _mark(timeline)

    stat = timeline.stat()
    assert cursor == {
        "exists": True,
        "dev": str(stat.st_dev),
        "ino": str(stat.st_ino),
        "offset": len(prefix),
    }
    assert stat.st_mode & 0o777 == 0o600


def test_read_accepts_file_created_after_absent_checkpoint(tmp_path):
    path = tmp_path / "created-after-mark.jsonl"
    cursor = _mark(path)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(_jsonl(_pair()))

    result = _run(path, "read", cursor)

    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["traceId"] == TRACE_ID


def test_read_maps_only_appended_exact_run_events_and_matching_call_ids(timeline):
    timeline.write_bytes(b"previous unrelated non-JSON line\n")
    cursor = _mark(timeline)
    other_run = [_event(runId=OTHER_RUN_ID)]
    ignored = [_event("synthetic.ignored", attributes={"traceId": "invalid"})]
    expected_calls = _pair(call_id="synthetic-first") + _pair(
        call_id="synthetic-second"
    )
    expected_calls[-1]["ok"] = False  # One success suffices; both calls settle.
    with timeline.open("ab") as output:
        output.write(_jsonl(other_run + ignored + expected_calls))

    result = _run(timeline, "read", cursor)

    assert result.returncode == 0, result.stderr
    evidence = json.loads(result.stdout)
    assert evidence["runId"] == RUN_ID
    assert evidence["traceId"] == TRACE_ID
    assert [call["callId"] for call in evidence["calls"]] == [
        "synthetic-first",
        "synthetic-second",
    ]
    assert [call["ok"] for call in evidence["calls"]] == [True, False]
    assert evidence["cursor"] == {**cursor, "offset": timeline.stat().st_size}
    assert all(call["traceId"] == TRACE_ID for call in evidence["calls"])


@pytest.mark.parametrize("mode", ["mark", "read"])
@pytest.mark.parametrize(
    "unsafe", ["symlink", "hardlink", "world_readable", "group_readable", "wrong_uid"]
)
def test_private_ownership_guards_reject_unsafe_timeline(timeline, mode, unsafe):
    cursor = _mark(timeline)
    timeline.write_bytes(_jsonl(_pair()))
    path = timeline
    if unsafe == "symlink":
        path = timeline.with_name("synthetic-link")
        path.symlink_to(timeline)
    elif unsafe == "hardlink":
        os.link(timeline, timeline.with_name("synthetic-hardlink"))
    elif unsafe == "world_readable":
        timeline.chmod(0o604)
    elif unsafe == "group_readable":
        timeline.chmod(0o640)

    result = _run(path, mode, cursor, wrong_uid=unsafe == "wrong_uid")

    _assert_rejected(result)


def test_reader_rejects_directory_instead_of_regular_file(tmp_path):
    _assert_rejected(_run(tmp_path), "private owned regular file")


@pytest.mark.parametrize("mutation", ["replaced", "truncated"])
def test_reader_rejects_file_replacement_or_truncation_after_mark(timeline, mutation):
    timeline.write_bytes(_jsonl(_pair()))
    cursor = _mark(timeline)
    if mutation == "replaced":
        replacement = timeline.with_name("synthetic-replacement")
        replacement.write_bytes(_jsonl(_pair()))
        replacement.chmod(0o600)
        replacement.replace(timeline)
    else:
        timeline.write_bytes(b"")

    result = _run(timeline, "read", cursor)

    _assert_rejected(result, "replaced" if mutation == "replaced" else "truncated")


def test_mark_rejects_checkpoint_inside_incomplete_line(timeline):
    timeline.write_bytes(json.dumps(_event()).encode())

    _assert_rejected(_run(timeline), "incomplete")


@pytest.mark.parametrize("delta", [b"{broken JSON}\n", b'{"unfinished":true}'])
def test_reader_rejects_malformed_or_incomplete_appended_json(timeline, delta):
    cursor = _mark(timeline)
    timeline.write_bytes(_jsonl(_pair()) + delta)

    _assert_rejected(_run(timeline, "read", cursor))


@pytest.mark.parametrize("extra_byte", [False, True])
def test_reader_accepts_two_mib_boundary_and_rejects_larger_delta(timeline, extra_byte):
    cursor = _mark(timeline)
    records = _jsonl(_pair())
    padding = _jsonl([{"name": "synthetic.padding", "padding": ""}])
    padding = padding.replace(
        b'"padding": ""',
        b'"padding": "' + b"x" * (MAX_DELTA - len(records) - len(padding)) + b'"',
    )
    timeline.write_bytes(records + padding + (b"\n" if extra_byte else b""))

    result = _run(timeline, "read", cursor)

    if extra_byte:
        _assert_rejected(result, "2 MiB")
    else:
        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout)["cursor"]["offset"] == MAX_DELTA


@pytest.mark.parametrize("scenario", ["wrong_run", "no_root", "multiple_roots"])
def test_reader_rejects_unrelated_runs_missing_roots_and_multiple_roots(
    timeline, scenario
):
    cursor = _mark(timeline)
    events = _pair()
    if scenario == "wrong_run":
        for event in events:
            event["runId"] = OTHER_RUN_ID
    elif scenario == "no_root":
        for event in events:
            event["name"] = "synthetic.ignored"
    else:
        events[1]["attributes"]["traceId"] = "2" * 32
    timeline.write_bytes(_jsonl(events))

    _assert_rejected(_run(timeline, "read", cursor))


@pytest.mark.parametrize("trace_id", [None, "", "0" * 32, "1" * 31, "g" * 32, "A" * 32])
def test_reader_requires_nonzero_32_lowercase_hex_trace_metadata(timeline, trace_id):
    cursor = _mark(timeline)
    events = _pair()
    events[0]["attributes"]["traceId"] = trace_id
    timeline.write_bytes(_jsonl(events))

    _assert_rejected(_run(timeline, "read", cursor), "trace metadata")


def test_reader_requires_expected_diagnostic_schema(timeline):
    cursor = _mark(timeline)
    events = _pair()
    events[0]["schemaVersion"] = "synthetic.unsupported.v0"
    timeline.write_bytes(_jsonl(events))

    _assert_rejected(_run(timeline, "read", cursor), "trace metadata")


@pytest.mark.parametrize("scenario", ["unsettled", "wrong_call", "all_failed"])
def test_reader_requires_each_started_call_to_settle_and_one_success(
    timeline, scenario
):
    cursor = _mark(timeline)
    events = _pair()
    if scenario == "unsettled":
        events.append(_event(call_id="synthetic-unsettled"))
    elif scenario == "wrong_call":
        events[1]["spanId"] = "synthetic-other-call"
    else:
        events[1]["ok"] = False
    timeline.write_bytes(_jsonl(events))

    _assert_rejected(_run(timeline, "read", cursor))


@pytest.mark.parametrize("matching_run", [False, True])
def test_reader_rejects_failed_writes_even_for_unrelated_run(timeline, matching_run):
    cursor = _mark(timeline)
    failed = _event(
        "synthetic.writer.health",
        runId=RUN_ID if matching_run else OTHER_RUN_ID,
        attributes={"failedWrites": 1},
    )
    timeline.write_bytes(_jsonl(_pair() + [failed]))

    _assert_rejected(_run(timeline, "read", cursor), "failed writes")


@pytest.mark.parametrize("offset", [-1, 0.5, "0", 2**53])
def test_reader_rejects_invalid_cursor_offsets(timeline, offset):
    timeline.write_bytes(_jsonl(_pair()))

    _assert_rejected(
        _run(timeline, "read", {"exists": False, "offset": offset}), "offset"
    )


def test_reader_rejects_nonzero_offset_for_absent_checkpoint(timeline):
    timeline.write_bytes(_jsonl(_pair()))

    _assert_rejected(_run(timeline, "read", {"exists": False, "offset": 1}), "offset")
