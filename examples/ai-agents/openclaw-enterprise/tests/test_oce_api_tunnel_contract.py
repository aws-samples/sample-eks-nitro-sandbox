from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "oce-api-tunnel.sh"
DIGEST = "a" * 64

FAKE_KUBECTL = """#!/usr/bin/env python3
import json
import os
import signal
import sys
import time
from pathlib import Path

state = Path(os.environ["FAKE_STATE_DIR"])
args = sys.argv[1:]

def append(name, value):
    with (state / name).open("a") as stream:
        stream.write(value + "\\n")

def raise_exit(code):
    raise SystemExit(code)

if "config" in args and "get-contexts" in args:
    time.sleep(float(os.environ.get("FAKE_CONFIG_DELAY", "0")))
    print("fake-context")
    raise SystemExit(0)

if "get" in args and "pods" in args:
    print(os.environ["FAKE_PODS_JSON"])
    raise SystemExit(0)

if "create" in args and "-f" in args:
    (state / "manifest.json").write_text(sys.stdin.read())
    append("commands.log", "create " + " ".join(args))
    if os.environ.get("FAKE_CREATE_FAIL") == "true":
        raise SystemExit(9)
    raise SystemExit(0)

if "wait" in args:
    append("commands.log", "wait " + " ".join(args))
    raise SystemExit(0)

if "port-forward" in args:
    append("commands.log", "port-forward " + " ".join(args))
    time.sleep(float(os.environ.get("FAKE_PORT_FORWARD_DELAY", "0")))
    local_port, relay_port = args[-1].split(":", 1)
    print(
        f"Forwarding from 127.0.0.1:{local_port} -> {relay_port}",
        file=sys.stderr,
        flush=True,
    )
    signal.signal(signal.SIGTERM, lambda *_: raise_exit(143))
    signal.signal(signal.SIGINT, lambda *_: raise_exit(130))
    signal.pause()

if "delete" in args:
    append("commands.log", "delete " + " ".join(args))
    if os.environ.get("FAKE_DELETE_FAIL") == "true":
        raise SystemExit(9)
    raise SystemExit(0)

if "get" in args and any(
    item.startswith(("pod/", "networkpolicy/")) for item in args
):
    if os.environ.get("FAKE_DELETE_FAIL") == "true":
        print(next(item for item in args if item.startswith("pod/")))
    raise SystemExit(0)

raise SystemExit(97)
"""


def _pods_json(image: str) -> str:
    return json.dumps(
        {
            "items": [
                {
                    "metadata": {
                        "name": "openclaw-enterprise-api-abc",
                        "uid": "11111111-2222-3333-4444-555555555555",
                        "deletionTimestamp": None,
                    },
                    "spec": {
                        "containers": [
                            {
                                "name": "api",
                                "image": image,
                            }
                        ]
                    },
                    "status": {
                        "phase": "Running",
                        "podIP": "192.0.2.42",
                        "conditions": [{"type": "Ready", "status": "True"}],
                    },
                }
            ]
        }
    )


def _environment(tmp_path: Path, image: str) -> dict[str, str]:
    if shutil.which("jq") is None or shutil.which("openssl") is None:
        pytest.skip("jq and openssl are required for this contract test")
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    kubectl = fake_bin / "kubectl"
    kubectl.write_text(FAKE_KUBECTL)
    kubectl.chmod(0o755)
    state = tmp_path / "state"
    state.mkdir()
    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    env["FAKE_STATE_DIR"] = str(state)
    env["FAKE_PODS_JSON"] = _pods_json(image)
    return env


def _wait_for(
    path: Path,
    text: str,
    *,
    process: subprocess.Popen[str] | None = None,
) -> None:
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if path.exists() and text in path.read_text():
            return
        if process is not None and process.poll() is not None:
            stdout, stderr = process.communicate(timeout=1)
            pytest.fail(
                f"process exited with {process.returncode} while waiting for "
                f"{text!r} in {path}\nstdout:\n{stdout}\nstderr:\n{stderr}"
            )
        time.sleep(0.05)
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate(timeout=5)
    pytest.fail(f"timed out waiting for {text!r} in {path}")


def test_tunnel_uses_digest_pinned_relay_and_cleans_up(tmp_path: Path) -> None:
    env = _environment(tmp_path, f"example.invalid/oce-api@sha256:{DIGEST}")
    env["FAKE_PORT_FORWARD_DELAY"] = "0.5"
    control_dir = tmp_path / "control"
    control_dir.mkdir(mode=0o700)
    ready_file = control_dir / "ready"
    state_file = control_dir / "state.json"
    process = subprocess.Popen(
        [
            "bash",
            str(SCRIPT),
            "--kube-context",
            "fake-context",
            "--local-port",
            "18081",
            "--ready-file",
            str(ready_file),
            "--state-file",
            str(state_file),
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    log = tmp_path / "state" / "commands.log"
    _wait_for(log, "port-forward", process=process)
    time.sleep(0.1)
    assert not ready_file.exists()
    _wait_for(
        ready_file,
        "Forwarding from 127.0.0.1:18081 -> 18080",
        process=process,
    )
    assert process.poll() is None
    process.send_signal(signal.SIGTERM)
    _, stderr = process.communicate(timeout=10)

    assert process.returncode == 143
    assert "http://127.0.0.1:18081" in stderr
    state = json.loads(state_file.read_text())
    assert state["cleanupStatus"] == "complete"
    assert state["relayPod"].startswith("oce-api-loopback-relay-")

    manifest = json.loads((tmp_path / "state" / "manifest.json").read_text())
    relay, relay_policy, api_policy = manifest["items"]
    container = relay["spec"]["containers"][0]
    assert container["image"] == f"example.invalid/oce-api@sha256:{DIGEST}"
    assert relay["spec"]["automountServiceAccountToken"] is False
    assert relay["spec"]["enableServiceLinks"] is False
    assert relay["spec"]["securityContext"]["runAsNonRoot"] is True
    assert container["securityContext"]["readOnlyRootFilesystem"] is True
    assert container["securityContext"]["capabilities"]["drop"] == ["ALL"]
    assert "readinessProbe" not in container
    assert 'listen(l,"127.0.0.1")' in container["args"][1]
    assert relay_policy["spec"]["ingress"] == []
    assert relay_policy["spec"]["egress"][0]["to"] == [
        {"ipBlock": {"cidr": "192.0.2.42/32"}}
    ]
    relay_id = relay["metadata"]["labels"]["openclaw.dev/api-relay-id"]
    assert (
        api_policy["spec"]["ingress"][0]["from"][0]["podSelector"]["matchLabels"][
            "openclaw.dev/api-relay-id"
        ]
        == relay_id
    )

    commands = log.read_text()
    assert "--address=127.0.0.1 pod/oce-api-loopback-relay-" in commands
    assert "service/openclaw-enterprise-api" not in commands
    assert len([line for line in commands.splitlines() if line.startswith("delete ")]) == 1
    assert " delete pod/oce-api-loopback-relay-" in commands
    assert " networkpolicy/oce-api-loopback-relay-" in commands


def test_tunnel_rejects_mutable_api_image_before_creating_resources(
    tmp_path: Path,
) -> None:
    env = _environment(tmp_path, "example.invalid/oce-api:latest")
    result = subprocess.run(
        ["bash", str(SCRIPT), "--kube-context", "fake-context"],
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )

    assert result.returncode != 0
    assert "must be pinned by SHA-256 digest" in result.stderr
    assert not (tmp_path / "state" / "manifest.json").exists()


def test_tunnel_cleans_partial_create_failure(tmp_path: Path) -> None:
    env = _environment(tmp_path, f"example.invalid/oce-api@sha256:{DIGEST}")
    env["FAKE_CREATE_FAIL"] = "true"
    result = subprocess.run(
        ["bash", str(SCRIPT), "--kube-context", "fake-context"],
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )

    assert result.returncode != 0
    assert "could not create the temporary API relay" in result.stderr
    commands = (tmp_path / "state" / "commands.log").read_text()
    assert len([line for line in commands.splitlines() if line.startswith("delete ")]) == 1


def test_tunnel_reports_unverified_cleanup_as_failure(tmp_path: Path) -> None:
    env = _environment(tmp_path, f"example.invalid/oce-api@sha256:{DIGEST}")
    env["FAKE_DELETE_FAIL"] = "true"
    control_dir = tmp_path / "control"
    control_dir.mkdir(mode=0o700)
    ready_file = control_dir / "ready"
    state_file = control_dir / "state.json"
    process = subprocess.Popen(
        [
            "bash",
            str(SCRIPT),
            "--kube-context",
            "fake-context",
            "--local-port",
            "18082",
            "--ready-file",
            str(ready_file),
            "--state-file",
            str(state_file),
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    _wait_for(
        ready_file,
        "Forwarding from 127.0.0.1:18082 -> 18080",
        process=process,
    )
    process.send_signal(signal.SIGTERM)
    _, stderr = process.communicate(timeout=10)

    assert process.returncode == 70
    assert "cleanup could not be verified" in stderr
    assert json.loads(state_file.read_text())["cleanupStatus"] == "failed"


def test_tunnel_applies_one_deadline_to_preflight_and_relay_startup(
    tmp_path: Path,
) -> None:
    env = _environment(tmp_path, f"example.invalid/oce-api@sha256:{DIGEST}")
    env["FAKE_CONFIG_DELAY"] = "2"
    result = subprocess.run(
        [
            "bash",
            str(SCRIPT),
            "--kube-context",
            "fake-context",
            "--startup-timeout-seconds",
            "1",
        ],
        text=True,
        capture_output=True,
        env=env,
        check=False,
        timeout=5,
    )

    assert result.returncode != 0
    assert "startup timeout elapsed" in result.stderr
    assert not (tmp_path / "state" / "manifest.json").exists()
