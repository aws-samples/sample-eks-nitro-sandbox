"""Regression test: a dispatched serving pod keeps its readiness port open while codex runs.

The SandboxTemplate gives every sandbox pod a ``readinessProbe: tcpSocket`` on
the readiness port (8080). A warm pod opens that port in ``_hold_readiness_port``
and is claimable. The regression this guards (Round 3c, "Finding C"): a CLAIMED
pod took the serving branch -- read its dispatch, run ``codex exec-server`` --
and, before the fix, never opened the readiness port, so the pod stayed
``ready=false``, its SandboxClaim stayed ``DependenciesNotReady``, and the
launcher's ``wait_for_claim_ready`` timed out even though the executor had
connected. A static manifest test cannot catch this: it only diverges at runtime
on a serving pod.

This test drives ``serve.main()`` on a claimed pod with ``codex exec-server``
replaced by a controllable blocker, and proves BOTH directions:

  * WHILE the executor is running, the readiness port ACCEPTS a TCP connection
    (so the claim can reach Ready);
  * AFTER the executor exits, the readiness listener is torn down.

Run with: python -m pytest
"""

from __future__ import annotations

import socket
import threading
import time

import pytest

from launcher import config, serve

_REMOTE = "https://codex-cloud-environments.chatgpt.com/e/env_1"


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _claimed_pod_env(monkeypatch, port: int) -> None:
    """Set a complete claimed-pod dispatch so serve.main() takes the serving path."""
    monkeypatch.setenv(config.ENV_SESSION_ID, "sesn_abc123")
    monkeypatch.setenv(config.ENV_ENVIRONMENT_ID, "env_abc123")
    monkeypatch.setenv(config.ENV_REMOTE_URL, _REMOTE)
    monkeypatch.setenv(config.ENV_CODEX_API_KEY, "env-key-value-not-read-here")
    monkeypatch.setenv(config.ENV_DISPATCH_PORT, str(port))


def _readiness_accepts(port: int, timeout: float = 2.0) -> bool:
    """True if something is accepting TCP connects on the readiness port."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.05)
    return False


def test_serving_pod_holds_readiness_port_while_codex_runs(monkeypatch, tmp_path):
    port = _free_port()
    _claimed_pod_env(monkeypatch, port)

    # Replace codex exec-server with a blocker we release, so we can observe the
    # readiness port WHILE the "executor" is running. _run_executor returns this
    # value as the executor's exit code once we let it finish.
    executor_running = threading.Event()
    release_executor = threading.Event()

    def _fake_run_executor(dispatch):
        assert dispatch["session_id"] == "sesn_abc123"  # the serving branch ran
        executor_running.set()
        release_executor.wait(timeout=10)
        return 0

    monkeypatch.setattr(serve, "_run_executor", _fake_run_executor)
    # serve.main() calls sys.exit at the end; run it on a thread and catch that.
    monkeypatch.setattr(serve.guard, "assert_safe", lambda *_a, **_k: None)
    # serve.main() makes WORKDIR; point it at a writable tmp path, not /workspace.
    monkeypatch.setattr(serve.config, "WORKDIR", str(tmp_path))

    exit_code: dict = {}

    def _run_main():
        try:
            serve.main()
        except SystemExit as exc:  # serve.main() ends with sys.exit
            exit_code["code"] = exc.code

    main_thread = threading.Thread(target=_run_main, daemon=True)
    main_thread.start()

    # The executor must have started on the serving branch...
    assert executor_running.wait(timeout=5), "serve never reached the executor"
    # ...and WHILE it runs, the readiness port must accept connections.
    assert _readiness_accepts(port), (
        "a serving pod did not open its readiness port while codex ran; the "
        "SandboxClaim would never reach Ready (Round 3c Finding C regression)"
    )

    # Let the executor finish; the readiness listener should then be torn down
    # and serve.main() should exit cleanly.
    release_executor.set()
    main_thread.join(timeout=5)
    assert not main_thread.is_alive(), "serve.main did not exit after the executor returned"
    assert exit_code.get("code") in (0, None)

    # After the executor exits the readiness port is no longer served.
    with pytest.raises(OSError):
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            pass


def test_readiness_listener_accepts_and_a_stopped_accept_loop_tears_it_down():
    """The shared readiness primitives both the warm and serving paths use:

    the listener opens an accepting port, and the accept loop closes it once its
    stop event is set. The serving path (tested above) and the warm path
    (``_hold_readiness_port``) are the two callers; this exercises the primitive
    both ways -- a connection it must accept while running, and that it stops
    accepting once ``stop`` is set.
    """
    port = _free_port()
    stop = threading.Event()
    srv = serve._readiness_listener(port, stop)
    accept_thread = threading.Thread(
        target=serve._accept_readiness, args=(srv, stop), daemon=True
    )
    accept_thread.start()
    try:
        # One it must accept: while the loop runs, the port is open.
        assert _readiness_accepts(port), "readiness listener did not accept while running"
    finally:
        # One it must reject: after stop is set, the loop closes the socket.
        stop.set()
        accept_thread.join(timeout=5)
    assert not accept_thread.is_alive(), "accept loop did not stop on its stop event"
    with pytest.raises(OSError):
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            pass
