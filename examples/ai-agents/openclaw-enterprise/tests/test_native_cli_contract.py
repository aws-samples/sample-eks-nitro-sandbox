"""Execute the live validator's actual guest programs without a cluster."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "validate-live.sh"
EVALUATOR = ROOT / "scripts" / "lib" / "evaluate-native-tool-history.mjs"
NODE = shutil.which("node")


def _function(name: str) -> str:
    match = re.search(
        rf"^{re.escape(name)}\(\) \{{\n.*?^\}}",
        SCRIPT.read_text(),
        re.MULTILINE | re.DOTALL,
    )
    assert match is not None, f"missing shell function: {name}"
    return match[0]


def _guest_program(name: str) -> str:
    match = re.search(
        r"node(?: --input-type=module)? -e '(.*?)\n\s*' >",
        _function(name),
        re.DOTALL,
    )
    assert match is not None, f"missing embedded JavaScript: {name}"
    return match[1]


FAKE_CLI = textwrap.dedent(
    """\
    import json
    import os
    import re
    import sys
    from pathlib import Path

    root = Path(os.environ["CLI_STATE_DIR"])
    args = sys.argv[1:]
    scenario = os.environ.get("CLI_SCENARIO", "pass")
    with (root / "calls.jsonl").open("a") as log:
        log.write(json.dumps(args) + "\\n")
    if scenario == "cli_exit":
        print("private-auth-detail", file=sys.stderr)
        sys.exit(7)
    if scenario == "cli_malformed":
        print("this is not JSON")
        sys.exit(0)
    if scenario == "cli_oversized":
        print("x" * 2097152)
        sys.exit(0)

    assert args[:2] == ["gateway", "call"]
    assert args[3:] == [
        "--json", "--expect-url", "ws://127.0.0.1:" + os.environ["CLI_EXPECT_PORT"],
        "--timeout", "30000", "--params", args[-1],
    ], args
    params = json.loads(args[-1])
    method = args[2]
    run_id = "native-cli-run-123"
    if method == "chat.send":
        assert params["sessionKey"].startswith("agent:main:")
        assert params["idempotencyKey"]
        (root / "sent.json").write_text(json.dumps(params))
        output = {"runId": "" if scenario == "missing_run_id" else run_id}
    elif method == "agent.wait":
        assert params == {"runId": run_id, "timeoutMs": 3000}
        output = {"runId": run_id, "status": "ok"}
        if scenario == "wrong_wait_run":
            output["runId"] = "unrelated-run"
        elif scenario == "wait_error":
            output["status"] = "error"
        elif scenario == "wait_unknown":
            output["status"] = "unexpected"
        elif scenario == "wait_terminal_timeout":
            output.update(status="timeout", endedAt=1)
        elif scenario == "wait_stop_reason":
            output.update(status="pending", stopReason="aborted")
        elif scenario == "wait_pending_then_ok":
            marker = root / "waited"
            if not marker.exists():
                marker.touch()
                output["status"] = "pending"
    elif method == "chat.history":
        sent = json.loads((root / "sent.json").read_text())
        assert params == {"sessionKey": sent["sessionKey"], "limit": 200}
        prompt = sent["message"]
        command = re.search(r"Run exactly this command: (printf TOOL_[0-9a-f]+)", prompt)[1]
        tool_marker = command.removeprefix("printf ")
        final_marker = re.search(r"reply with exactly (DONE_[0-9a-f]+)", prompt)[1]
        attributed_run = {"runId": run_id}
        messages = [
            {"role": "user", "content": prompt, "__openclaw": attributed_run},
            {"role": "assistant", "content": [
                {"type": "toolCall", "id": "call-1", "name": "exec",
                 "arguments": {"command": command}}],
             "__openclaw": attributed_run},
            {"role": "toolResult", "toolCallId": "call-1", "toolName": "exec",
             "isError": False, "content": tool_marker, "__openclaw": attributed_run},
            {"role": "assistant", "content": final_marker, "__openclaw": attributed_run},
        ]
        if scenario == "wrong_command":
            messages[1]["content"][0]["arguments"]["command"] = "printf WRONG"
        elif scenario == "wrong_tool":
            messages[1]["content"][0]["name"] = "read"
        elif scenario == "uncorrelated_result":
            messages[2]["toolCallId"] = "unrelated-call"
        elif scenario == "failed_exec":
            messages[2]["isError"] = True
        elif scenario == "wrong_result":
            messages[2]["content"] = "prefix " + tool_marker
        elif scenario == "wrong_final":
            messages[3]["content"] = "wrong-final"
        elif scenario == "wrong_history_run":
            for message in messages:
                message["__openclaw"] = {"runId": "unrelated-run"}
        elif scenario == "missing_exec":
            messages.pop(2)
            messages.pop(1)
        elif scenario == "duplicate_final":
            messages.append(messages[-1])
        elif scenario == "harmless_retry":
            messages.insert(3, messages[2])
        elif scenario == "thinking_final":
            messages[3]["content"] = [
                {"type": "thinking", "thinking": "The tool succeeded."},
                {"type": "text", "text": final_marker},
            ]
        output = {"messages": messages}
    else:
        raise AssertionError(method)
    print(json.dumps(output))
    """
)


def _run_guest(
    tmp_path: Path, port: str = "8080", scenario: str = "pass"
) -> tuple[subprocess.CompletedProcess[str], list[list[str]]]:
    assert NODE is not None, "Node is required for native guest contract tests"
    tmp_path.chmod(0o700)
    binary_dir = tmp_path / "bin"
    binary_dir.mkdir(mode=0o700)
    executable = binary_dir / "openclaw"
    executable.write_text(f"#!{sys.executable}\n{FAKE_CLI}")
    executable.chmod(0o700)
    if scenario == "cli_missing":
        executable.unlink()
    env = os.environ.copy()
    env.update(
        PATH=str(binary_dir),
        HOME=str(tmp_path),
        CLI_STATE_DIR=str(tmp_path),
        CLI_SCENARIO=scenario,
        CLI_EXPECT_PORT=port,
        OCE_TEST_GATEWAY_PORT=port,
        OCE_NATIVE_HISTORY_EVALUATOR_B64=base64.b64encode(
            EVALUATOR.read_bytes()
        ).decode(),
        OPENCLAW_GATEWAY_PASSWORD="configured-auth-secret",
    )
    # Advance a virtual clock to test exhausted polling without a 30-second sleep.
    prelude = """
        let clock = 0;
        Date.now = () => (clock += 11000);
        globalThis.setTimeout = (callback) => { queueMicrotask(callback); return 0; };
    """
    result = subprocess.run(
        [
            NODE,
            "--input-type=module",
            "-e",
            prelude + _guest_program("verify_native_tool_execution"),
        ],
        env=env,
        text=True,
        capture_output=True,
        check=False,
        timeout=10,
    )
    log = tmp_path / "calls.jsonl"
    calls = (
        [json.loads(line) for line in log.read_text().splitlines()]
        if log.exists()
        else []
    )
    return result, calls


@pytest.mark.parametrize("port", ["1", "8080", "65535"])
def test_native_cli_uses_derived_loopback_port_and_configured_auth(
    tmp_path: Path, port: str
) -> None:
    result, calls = _run_guest(tmp_path, port)

    assert result.returncode == 0, result.stderr
    assert [call[2] for call in calls] == ["chat.send", "agent.wait", "chat.history"]
    output = json.loads(result.stdout)
    assert output == {
        "marker": "LIVE_NATIVE_TOOL_EXECUTION",
        "outcome": "ok",
        "toolCallCount": 1,
        "execResultCount": 1,
        "finalReplyCount": 1,
        "exactCommand": True,
        "resultMarker": True,
        "finalReply": True,
        "runIdHash": hashlib.sha256(b"native-cli-run-123").hexdigest(),
    }
    assert (
        "configured-auth-secret"
        not in json.dumps(calls) + result.stdout + result.stderr
    )
    for call in calls:
        assert not set(call) & {"--token", "--password", "--url"}


@pytest.mark.parametrize(
    "port",
    [
        "",
        "0",
        "-1",
        "65536",
        "8080.5",
        "NaN",
        "Infinity",
        " 8080 ",
        "0x1f90",
        "8.08e3",
        "8080;echo injected",
        "ws://other-host:8080",
    ],
)
def test_invalid_guest_port_is_rejected_before_cli_execution(
    tmp_path: Path, port: str
) -> None:
    result, calls = _run_guest(tmp_path, port)
    assert result.returncode != 0
    assert result.stdout == ""
    assert calls == []


@pytest.mark.parametrize(
    "scenario, expected_calls",
    [
        ("cli_missing", 0),
        ("cli_exit", 1),
        ("cli_malformed", 1),
        ("cli_oversized", 1),
        ("missing_run_id", 1),
        ("wrong_wait_run", 2),
        ("wait_error", 2),
        ("wait_unknown", 2),
        ("wait_terminal_timeout", 2),
        ("wait_stop_reason", 2),
        ("wrong_command", 3),
        ("wrong_tool", 3),
        ("uncorrelated_result", 3),
        ("failed_exec", 3),
        ("wrong_result", 3),
        ("duplicate_final", 3),
        ("wrong_final", None),
        ("wrong_history_run", None),
        ("missing_exec", None),
    ],
)
def test_native_cli_fails_closed_on_execution_or_evidence_failure(
    tmp_path: Path, scenario: str, expected_calls: int | None
) -> None:
    result, calls = _run_guest(tmp_path, scenario=scenario)
    assert result.returncode != 0, result.stdout
    assert result.stdout == ""
    assert "private-auth-detail" not in result.stderr
    if expected_calls is not None:
        assert len(calls) == expected_calls


@pytest.mark.parametrize(
    "scenario, result_count",
    [("harmless_retry", 2), ("wait_pending_then_ok", 1), ("thinking_final", 1)],
)
def test_native_cli_accepts_valid_retries(
    tmp_path: Path, scenario: str, result_count: int
) -> None:
    result, calls = _run_guest(tmp_path, scenario=scenario)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["execResultCount"] == result_count
    assert calls[-1][2] == "chat.history"


def _pod(namespace: str = "tenant-a", name: str = "pod-a", uid: str = "uid-a") -> dict:
    return {
        "metadata": {"namespace": namespace, "name": name, "uid": uid},
        "spec": {
            "containers": [
                {"name": "gateway", "ports": [{"name": "http", "containerPort": 8080}]},
                {"name": "sidecar", "ports": [{"name": "http", "containerPort": 9090}]},
            ]
        },
    }


def _lookup_port(
    tmp_path: Path,
    pod: dict,
    target: tuple[str, str, str, str] = ("tenant-a", "pod-a", "gateway", "uid-a"),
) -> subprocess.CompletedProcess[str]:
    (tmp_path / "tenant-a-pod.json").write_text(json.dumps(pod))
    (tmp_path / "tenant-b-pod.json").write_text(
        json.dumps(_pod("tenant-b", "pod-b", "uid-b"))
    )
    replacement = _pod("tenant-a", "replacement-a", "uid-replacement")
    replacement["spec"]["containers"][0]["ports"][0]["containerPort"] = 9090
    (tmp_path / "replacement-pod.json").write_text(json.dumps(replacement))
    env = os.environ.copy()
    env.update(
        WORK_DIR=str(tmp_path),
        TENANT_A_NAMESPACE="tenant-a",
        TENANT_A_POD="pod-a",
        TENANT_B_NAMESPACE="tenant-b",
        TENANT_B_POD="pod-b",
        REPLACEMENT_POD="replacement-a",
        REPLACEMENT_POD_UID="uid-replacement",
    )
    return subprocess.run(
        [
            "bash",
            "-c",
            "set -eu\n"
            'die() { printf "%s\\n" "$*" >&2; exit 70; }\n'
            + _function("gateway_http_port")
            + '\ngateway_http_port "$@"',
            "port-contract",
            *target,
        ],
        env=env,
        text=True,
        capture_output=True,
        check=False,
        timeout=5,
    )


@pytest.mark.parametrize(
    "target",
    [
        ("tenant-a", "pod-a", "gateway", "uid-a"),
        ("tenant-b", "pod-b", "gateway", "uid-b"),
    ],
)
def test_gateway_port_lookup_selects_verified_tenant_container(
    tmp_path: Path, target: tuple
) -> None:
    result = _lookup_port(tmp_path, _pod(), target)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "8080"


@pytest.mark.parametrize("uid", ["uid-replacement", "uid-a", "wrong-uid"])
def test_gateway_port_lookup_binds_replacement_port_to_replacement_uid(
    tmp_path: Path, uid: str
) -> None:
    result = _lookup_port(
        tmp_path, _pod(), ("tenant-a", "replacement-a", "gateway", uid)
    )
    if uid == "uid-replacement":
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "9090"
    else:
        assert result.returncode != 0
        assert result.stdout == ""


@pytest.mark.parametrize("port", [1, 8080, 65535])
def test_gateway_port_lookup_accepts_integer_port_range(
    tmp_path: Path, port: int
) -> None:
    pod = _pod()
    pod["spec"]["containers"][0]["ports"][0]["containerPort"] = port
    result = _lookup_port(tmp_path, pod)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == str(port)


@pytest.mark.parametrize(
    "port", [None, True, False, "8080", 0, -1, 65536, 8080.5, {}, []]
)
def test_gateway_port_lookup_rejects_invalid_container_port(
    tmp_path: Path, port: object
) -> None:
    pod = _pod()
    pod["spec"]["containers"][0]["ports"][0]["containerPort"] = port
    result = _lookup_port(tmp_path, pod)
    assert result.returncode != 0
    assert result.stdout == ""


@pytest.mark.parametrize(
    "shape",
    [
        "missing_ports",
        "missing_http",
        "multiple_http",
        "duplicate_container",
        "missing_container",
    ],
)
def test_gateway_port_lookup_rejects_missing_or_ambiguous_http_port(
    tmp_path: Path, shape: str
) -> None:
    pod = _pod()
    gateway = pod["spec"]["containers"][0]
    if shape == "missing_ports":
        del gateway["ports"]
    elif shape == "missing_http":
        gateway["ports"][0]["name"] = "metrics"
    elif shape == "multiple_http":
        gateway["ports"].append({"name": "http", "containerPort": 9090})
    elif shape == "duplicate_container":
        pod["spec"]["containers"].append(gateway)
    elif shape == "missing_container":
        gateway["name"] = "other"
    result = _lookup_port(tmp_path, pod)
    assert result.returncode != 0
    assert result.stdout == ""


@pytest.mark.parametrize(
    "target",
    [
        ("outside-tenant", "pod-a", "gateway", "uid-a"),
        ("tenant-a", "other-pod", "gateway", "uid-a"),
        ("tenant-a", "pod-a", "gateway", "replaced-uid"),
    ],
)
def test_gateway_port_lookup_rejects_unverified_target(
    tmp_path: Path, target: tuple
) -> None:
    result = _lookup_port(tmp_path, _pod(), target)
    assert result.returncode != 0
    assert result.stdout == ""


@pytest.mark.parametrize("field", ["namespace", "name", "uid"])
def test_gateway_port_lookup_rejects_changed_snapshot_identity(
    tmp_path: Path, field: str
) -> None:
    pod = _pod()
    pod["metadata"][field] = "changed"
    result = _lookup_port(tmp_path, pod)
    assert result.returncode != 0
    assert result.stdout == ""


def test_native_probes_do_not_depend_on_gateway_routing_or_cli_credentials() -> None:
    for name in ("verify_native_tool_execution", "call_native_openclaw_model"):
        source = _function(name)
        assert "gateway_http_port" in source
        assert "exec_in_exact_pod" in source
        assert "18789" not in source
        assert "gatewayRouting" not in source
        assert "OCC_GATEWAY_API_KEY_PATH" not in source
        assert "--password" not in source
        assert "--token" not in source


@pytest.mark.parametrize("port", ["1", "8080", "65535"])
def test_native_model_requests_use_derived_http_port_and_header_auth(
    tmp_path: Path, port: str
) -> None:
    assert NODE is not None
    env = os.environ.copy()
    env.update(
        OCE_TEST_GATEWAY_PORT=port,
        OPENCLAW_GATEWAY_PASSWORD="configured-auth-secret",
        HTTP_CALL_LOG=str(tmp_path / "http-calls.json"),
    )
    # Replace only transport. Run the production challenge/authentication logic.
    transport = """
        const { EventEmitter } = require("node:events");
        const calls = [];
        require("node:http").request = (options, callback) => {
          const operation = new EventEmitter();
          operation.setTimeout = () => {};
          operation.destroy = error => operation.emit("error", error);
          operation.end = body => {
            const payload = JSON.parse(body);
            calls.push({ ...options, payload });
            const response = new EventEmitter();
            response.setEncoding = () => {};
            response.statusCode = options.headers.authorization ? 200 : 401;
            queueMicrotask(() => {
              callback(response);
              let output = {};
              if (response.statusCode === 200) {
                const prompt = payload.messages[0].content;
                const nonce = prompt.match(/nonce is ([0-9a-f]+)/)[1];
                const arithmetic = prompt.match(/Calculate ([0-9]+) \\+ ([0-9]+)/);
                output = {
                  model: "openclaw/default", id: "chatcmpl_test1234",
                  choices: [{ message: {
                    content: `${nonce}:${Number(arithmetic[1]) + Number(arithmetic[2])}`
                  }}]
                };
              }
              response.emit("data", JSON.stringify(output));
              response.emit("end");
            });
          };
          return operation;
        };
        process.on("exit", () => require("node:fs").writeFileSync(
          process.env.HTTP_CALL_LOG, JSON.stringify(calls)
        ));
    """
    result = subprocess.run(
        [NODE, "-e", transport + _guest_program("call_native_openclaw_model")],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=5,
    )
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["challengeMatch"] is True
    calls = json.loads((tmp_path / "http-calls.json").read_text())
    assert len(calls) == 2
    for call in calls:
        assert call["hostname"] == "127.0.0.1"
        assert call["port"] == int(port)
        assert call["path"] == "/v1/chat/completions"
        assert call["method"] == "POST"
    assert "authorization" not in calls[0]["headers"]
    assert calls[1]["headers"]["authorization"] == "Bearer configured-auth-secret"
    assert re.fullmatch(
        r"00-[0-9a-f]{32}-[0-9a-f]{16}-01", calls[1]["headers"]["traceparent"]
    )
    assert "configured-auth-secret" not in result.stdout + result.stderr


@pytest.mark.parametrize(
    "port", ["", "0", "65536", "8080.5", "0x1f90", " 8080 ", "8.08e3"]
)
def test_native_model_rejects_invalid_port_before_http_request(port: str) -> None:
    assert NODE is not None
    env = os.environ.copy()
    env.update(OCE_TEST_GATEWAY_PORT=port, OPENCLAW_GATEWAY_PASSWORD="configured")
    transport = """
        require("node:http").request = () => {
          process.stdout.write("UNEXPECTED_HTTP_REQUEST");
          throw new Error("invalid port reached HTTP transport");
        };
    """
    result = subprocess.run(
        [NODE, "-e", transport + _guest_program("call_native_openclaw_model")],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=5,
    )
    assert result.returncode != 0
    assert result.stdout == ""
