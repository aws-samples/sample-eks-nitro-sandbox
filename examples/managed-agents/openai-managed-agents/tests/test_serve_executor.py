"""``serve._run_executor`` runs the executor and the forwarder, with a fake codex.

A claimed pod runs Codex's forward mode as two processes on the pod's loopback:

    codex exec-server --listen ws://127.0.0.1:<port>                      (executor)
    codex exec-server forward --remote <url> --environment-id <id> \\
        --connect ws://127.0.0.1:<port>                                   (forwarder)

These tests point ``CODEX_PATH`` at a small fake codex, so both children are real
processes. The fake records its argv and whether it holds ``CODEX_API_KEY``; as
the executor it listens where ``--listen`` says, as the forwarder it checks that
``--connect`` is accepting when it starts, and on SIGTERM it records the signal.
Each behaviour is checked both ways: what must happen, and what must not.

Run with: python -m pytest
"""

from __future__ import annotations

import json
import os
import signal
import socket
import sys
import threading
import time
from types import SimpleNamespace
from urllib.parse import urlsplit

import pytest

from launcher import config, serve

REMOTE = "https://codex-cloud-environments.chatgpt.com/e/env_1"
DISPATCH = {"session_id": "sesn_abc123", "environment_id": "env_abc123", "remote_url": REMOTE}

FAKE_CODEX = r'''#!@PYTHON@
import json, os, signal, socket, sys, time
from pathlib import Path

out = Path(os.environ["FAKE_CODEX_DIR"])
args = sys.argv[1:]
role = "forwarder" if args[:2] == ["exec-server", "forward"] else "executor"
rec = {"argv": args, "pid": os.getpid(), "has_key": bool(os.environ.get("CODEX_API_KEY")),
       "started": time.time()}

def save():
    tmp = out / f"{role}.json.tmp"
    tmp.write_text(json.dumps(rec))
    os.replace(tmp, out / f"{role}.json")

def on_term(signum, _frame):
    (out / f"{role}.signal").write_text(str(signum))
    os._exit(128 + signum)

signal.signal(signal.SIGTERM, on_term)
save()

def host_port(flag):
    url = args[args.index(flag) + 1]
    host, port = url[len("ws://"):].rsplit(":", 1)
    return host, int(port)

srv = None
mode = os.environ.get("FAKE_EXECUTOR_MODE", "listen")
if role == "executor":
    if mode == "exit-before-listen":
        sys.exit(int(os.environ.get("FAKE_EXECUTOR_EXIT_CODE", "2")))
    if mode == "listen":
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(host_port("--listen"))
        srv.listen(16)
        srv.settimeout(0.05)
        rec["bound"] = list(srv.getsockname())
        rec["listening_at"] = time.time()
        save()
else:
    try:
        socket.create_connection(host_port("--connect"), timeout=2).close()
        rec["executor_listening_at_start"] = True
    except OSError:
        rec["executor_listening_at_start"] = False
    save()

exit_after = os.environ.get(f"FAKE_{role.upper()}_EXIT_AFTER")
code = int(os.environ.get(f"FAKE_{role.upper()}_EXIT_CODE", "0"))
start = time.time()
while True:
    if exit_after and time.time() - start >= float(exit_after):
        sys.exit(code)
    if srv is not None:
        try:
            srv.accept()[0].close()
        except socket.timeout:
            pass
    else:
        time.sleep(0.05)
'''


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _accepts(port: int) -> bool:
    try:
        socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
        return True
    except OSError:
        return False


def _wait_for(predicate, timeout: float = 10.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


@pytest.fixture
def fake(tmp_path, monkeypatch):
    rec = tmp_path / "rec"
    rec.mkdir()
    codex = tmp_path / "codex"
    codex.write_text(FAKE_CODEX.replace("@PYTHON@", sys.executable))
    codex.chmod(0o755)
    port = _free_port()
    monkeypatch.setenv(config.ENV_CODEX_PATH, str(codex))
    monkeypatch.setenv("FAKE_CODEX_DIR", str(rec))
    monkeypatch.setenv(config.ENV_CODEX_API_KEY, "env-key-value-not-read-here")
    monkeypatch.delenv("CODEX_HOME", raising=False)
    monkeypatch.setattr(config, "WORKDIR", str(tmp_path / "workspace"))
    monkeypatch.setattr(config, "EXECUTOR_LOOPBACK_PORT", port)
    monkeypatch.setattr(config, "EXECUTOR_LISTEN_TIMEOUT", 10)
    # Capture the handlers serve installs instead of replacing pytest's own.
    handlers: dict = {}
    monkeypatch.setattr(serve.signal, "signal", lambda signum, handler: handlers.__setitem__(signum, handler))
    state = SimpleNamespace(rec=rec, port=port, handlers=handlers, ready=[])
    yield state
    for f in rec.glob("*.json"):  # never leave a fake child behind
        try:
            os.kill(json.loads(f.read_text())["pid"], signal.SIGKILL)
        except (OSError, ValueError, KeyError):
            pass


def _record(fake, role: str) -> dict | None:
    f = fake.rec / f"{role}.json"
    return json.loads(f.read_text()) if f.exists() else None


def _start(fake) -> tuple[threading.Thread, dict]:
    """Run _run_executor on a thread; on_ready records whether the executor listened."""
    result: dict = {}

    def on_ready():
        fake.ready.append({"executor_listening": _accepts(fake.port)})

    def run():
        result["code"] = serve._run_executor(dict(DISPATCH), on_ready)

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread, result


def _finish(thread: threading.Thread, result: dict) -> int:
    thread.join(timeout=30)
    assert not thread.is_alive(), "_run_executor did not return"
    return result["code"]


def _both_running(fake) -> bool:
    executor, forwarder = _record(fake, "executor"), _record(fake, "forwarder")
    return bool(executor and "listening_at" in executor and forwarder
                and "executor_listening_at_start" in forwarder)


def _sigterm(fake) -> None:
    fake.handlers[signal.SIGTERM](signal.SIGTERM, None)


def test_spawns_the_executor_then_the_forwarder_with_the_exact_arguments(fake):
    thread, result = _start(fake)
    assert _wait_for(lambda: _both_running(fake)), "both children did not start"
    _sigterm(fake)
    assert _finish(thread, result) == 0

    local = f"ws://127.0.0.1:{fake.port}"
    executor, forwarder = _record(fake, "executor"), _record(fake, "forwarder")
    assert executor["argv"] == ["exec-server", "--listen", local]
    # `forward` first, then --remote and --environment-id, then --connect.
    assert forwarder["argv"] == [
        "exec-server", "forward",
        "--remote", REMOTE,
        "--environment-id", "env_abc123",
        "--connect", local,
    ]
    # The forwarder starts only after the executor is listening, and finds it there.
    assert forwarder["started"] >= executor["listening_at"]
    assert forwarder["executor_listening_at_start"] is True
    # Both inherit CODEX_API_KEY from serve's own environment.
    assert executor["has_key"] is True and forwarder["has_key"] is True
    # Ready is reported once, when the executor was already listening.
    assert fake.ready == [{"executor_listening": True}]


def test_the_executor_and_the_forwarder_use_loopback_only(fake):
    thread, result = _start(fake)
    assert _wait_for(lambda: _both_running(fake))
    executor, forwarder = _record(fake, "executor"), _record(fake, "forwarder")

    # Not reachable on any of this host's other addresses (none found: nothing to try).
    try:
        infos = socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)
    except socket.gaierror:
        infos = []
    others = {ai[4][0] for ai in infos if not ai[4][0].startswith("127.")}
    reachable = []
    for addr in others:
        try:
            socket.create_connection((addr, fake.port), timeout=0.5).close()
            reachable.append(addr)
        except OSError:
            pass
    _sigterm(fake)
    _finish(thread, result)

    for url in (executor["argv"][executor["argv"].index("--listen") + 1],
                forwarder["argv"][forwarder["argv"].index("--connect") + 1]):
        parts = urlsplit(url)
        assert (parts.scheme, parts.hostname, parts.port) == ("ws", "127.0.0.1", fake.port)
    assert executor["bound"] == ["127.0.0.1", fake.port]
    assert reachable == [], f"the executor port answered on {reachable}"


@pytest.mark.parametrize("exit_code, expected", [(0, 1), (3, 3)])
def test_a_forwarder_that_exits_stops_the_executor_and_fails(fake, monkeypatch, exit_code, expected):
    monkeypatch.setenv("FAKE_FORWARDER_EXIT_AFTER", "0.5")
    monkeypatch.setenv("FAKE_FORWARDER_EXIT_CODE", str(exit_code))
    thread, result = _start(fake)
    # Even a forwarder that exits 0 is a failure: the executor alone serves nothing.
    assert _finish(thread, result) == expected
    assert (fake.rec / "executor.signal").read_text() == str(int(signal.SIGTERM))
    assert not (fake.rec / "forwarder.signal").exists()  # it exited on its own
    with pytest.raises(ProcessLookupError):
        os.kill(_record(fake, "executor")["pid"], 0)


def test_an_executor_that_exits_stops_the_forwarder_and_fails(fake, monkeypatch):
    monkeypatch.setenv("FAKE_EXECUTOR_EXIT_AFTER", "1.5")
    thread, result = _start(fake)
    assert _finish(thread, result) == 1
    assert _record(fake, "forwarder") is not None, "the forwarder never started"
    assert (fake.rec / "forwarder.signal").read_text() == str(int(signal.SIGTERM))
    assert not (fake.rec / "executor.signal").exists()  # it exited on its own
    with pytest.raises(ProcessLookupError):
        os.kill(_record(fake, "forwarder")["pid"], 0)


def test_sigterm_reaches_both_children(fake):
    thread, result = _start(fake)
    assert _wait_for(lambda: _both_running(fake))
    assert set(fake.handlers) >= {signal.SIGTERM, signal.SIGINT}
    # Before the signal, neither child has been asked to stop.
    assert not list(fake.rec.glob("*.signal"))
    _sigterm(fake)
    assert _finish(thread, result) == 0  # a forwarded SIGTERM is a clean stop
    assert (fake.rec / "executor.signal").read_text() == str(int(signal.SIGTERM))
    assert (fake.rec / "forwarder.signal").read_text() == str(int(signal.SIGTERM))


def test_an_executor_that_exits_before_listening_gets_no_forwarder_and_no_ready(fake, monkeypatch):
    monkeypatch.setenv("FAKE_EXECUTOR_MODE", "exit-before-listen")
    monkeypatch.setenv("FAKE_EXECUTOR_EXIT_CODE", "2")
    thread, result = _start(fake)
    assert _finish(thread, result) == 2
    assert _record(fake, "executor") is not None
    assert _record(fake, "forwarder") is None
    assert fake.ready == []


def test_an_executor_that_never_listens_is_stopped_with_no_forwarder_and_no_ready(fake, monkeypatch):
    monkeypatch.setenv("FAKE_EXECUTOR_MODE", "never-listen")
    monkeypatch.setattr(config, "EXECUTOR_LISTEN_TIMEOUT", 1)
    thread, result = _start(fake)
    assert _finish(thread, result) == 1
    assert _record(fake, "forwarder") is None
    assert fake.ready == []
    assert (fake.rec / "executor.signal").read_text() == str(int(signal.SIGTERM))


def test_serve_main_exits_non_zero_when_the_forwarder_exits(fake, monkeypatch, tmp_path):
    ready_port = _free_port()
    monkeypatch.setenv(config.ENV_SESSION_ID, DISPATCH["session_id"])
    monkeypatch.setenv(config.ENV_ENVIRONMENT_ID, DISPATCH["environment_id"])
    monkeypatch.setenv(config.ENV_REMOTE_URL, REMOTE)
    monkeypatch.setenv(config.ENV_DISPATCH_PORT, str(ready_port))
    monkeypatch.setenv("FAKE_FORWARDER_EXIT_AFTER", "0.5")
    monkeypatch.setattr(serve.guard, "assert_safe", lambda *_a, **_k: None)

    result: dict = {}

    def run_main():
        try:
            serve.main()
        except SystemExit as exc:
            result["code"] = exc.code

    thread = threading.Thread(target=run_main, daemon=True)
    thread.start()
    thread.join(timeout=30)
    assert not thread.is_alive(), "serve.main did not exit after the forwarder exited"
    assert result["code"] == 1
    assert (fake.rec / "executor.signal").read_text() == str(int(signal.SIGTERM))
    assert not _accepts(ready_port), "the readiness port stayed open after serve exited"


def test_executor_commands_are_built_from_the_dispatch():
    executor, forwarder = serve._executor_commands("/x/codex", DISPATCH, 4242)
    assert executor == ["/x/codex", "exec-server", "--listen", "ws://127.0.0.1:4242"]
    assert forwarder == [
        "/x/codex", "exec-server", "forward", "--remote", REMOTE,
        "--environment-id", "env_abc123", "--connect", "ws://127.0.0.1:4242",
    ]
