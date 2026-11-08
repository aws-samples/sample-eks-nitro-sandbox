"""``launcher serve`` -- the sandbox's entrypoint: run one session's executor, then exit.

Every sandbox pod runs ``serve``. There is no network intake and no HTTP server
that receives a credential:

  * A **claimed** pod is cold-started by the controller with the session already
    in its environment -- the session id, environment id, remote URL and the
    environment key as ``CODEX_API_KEY``, all set from ``SandboxClaim.spec.env``
    by the launcher's authenticated Kubernetes API call (see ``sandbox.py``).
    ``serve`` reads them from its own environment and runs the executor in
    Codex's forward mode, as two child processes:

        codex exec-server --listen ws://127.0.0.1:<port>                  (the executor)
        codex exec-server forward --remote <remote_url> \\
            --environment-id <environment_id> --connect ws://127.0.0.1:<port>   (the forwarder)

    The executor listens on the pod's loopback only and runs the agent's Bash
    and apply-patch tool calls in ``/workspace``. The forwarder dials out to
    OpenAI, registers for the environment, and passes the session's messages
    to the executor unchanged. The key (``CODEX_API_KEY``) stays in the claimed
    pod, but not in one process: ``serve`` has it in its own environment, both
    children inherit that environment, and the tool commands the executor runs
    can read it, as the page says. The pod reports Ready only once the
    executor is listening. If either process exits, the
    other is stopped and ``serve`` exits non-zero; SIGTERM (the claim being
    deleted, or its deadline) goes to both.

  * A **warm** pod is booted by the ``SandboxWarmPool`` from the template, with
    no session env. It is never dispatched to (claiming a session cold-starts a
    fresh pod), so it just opens a readiness TCP port and waits. The controller
    recycles it. It holds no key.

The key never crosses the pod network and never touches a warm pod: the guard
refuses to start a warm pod that holds any credential, and a claimed pod gets
its key through the control plane.
"""

from __future__ import annotations

import logging
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
from typing import Callable

from . import config, guard

log = logging.getLogger(__name__)

ID_RE = re.compile(r"^[A-Za-z0-9_\-]{1,128}$")
URL_RE = re.compile(r"^https://[A-Za-z0-9._\-]+(:\d+)?(/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%\-]*)?$")


def _read_dispatch() -> dict[str, str]:
    """Read and validate this claimed pod's session from its own environment."""
    dispatch = {
        "session_id": config.require(config.ENV_SESSION_ID),
        "environment_id": config.require(config.ENV_ENVIRONMENT_ID),
        "remote_url": config.require(config.ENV_REMOTE_URL),
    }
    if not (ID_RE.match(dispatch["session_id"]) and ID_RE.match(dispatch["environment_id"])):
        raise RuntimeError("the injected session id or environment id is malformed")
    if not URL_RE.match(dispatch["remote_url"]):
        raise RuntimeError("the injected remote URL is malformed or not https")
    # The key is read by the child process from its own CODEX_API_KEY; this
    # process only confirms its presence by name, never its value.
    if not os.environ.get(config.ENV_CODEX_API_KEY):
        raise RuntimeError(f"{config.ENV_CODEX_API_KEY} is not set on this claimed sandbox")
    return dispatch


def _readiness_listener(port: int, stop: threading.Event) -> socket.socket:
    """Open the readiness TCP port and return the bound, listening socket.

    The readiness probe is a bare TCP connect (``tcpSocket`` in the template), so
    accepting and immediately closing a connection is all it needs. The listener
    binds the pod network (there is no host port; the SandboxTemplate publishes
    none and the network policy admits nothing to a sandbox), and it reads no
    request body. ``stop`` lets a caller end the accept loop.
    """
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # The all-interface pod bind is intentional: kubelet probes the pod IP, no
    # host port or Service publishes this port, and deny-all ingress governs it.
    # Narrowing it to loopback would break the Kubernetes readiness probe.
    srv.bind(("0.0.0.0", port))  # lgtm[py/bind-socket-all-network-interfaces]
    srv.listen(16)
    srv.settimeout(1.0)
    return srv


def _accept_readiness(srv: socket.socket, stop: threading.Event) -> None:
    """Accept-and-close readiness probes until ``stop`` is set."""
    while not stop.is_set():
        try:
            conn, _ = srv.accept()
            conn.close()  # readiness probe only; nothing is read
        except socket.timeout:
            continue
        except OSError:
            break
    srv.close()


def _hold_readiness_port(port: int) -> None:
    """A warm pod: listen so the claim can report Ready, accept nothing meaningful.

    The pod is never dispatched to over the network. It stays up until the
    controller recycles it or sends SIGTERM.
    """
    stop = threading.Event()
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda *_: stop.set())
    srv = _readiness_listener(port, stop)
    log.info("warm sandbox: readiness port :%d open, waiting to be claimed", port)
    _accept_readiness(srv, stop)
    log.info("warm sandbox: shutting down")


LOOPBACK = "127.0.0.1"
# Exit codes of a child that stopped because serve forwarded SIGTERM to it.
_CLEAN_STOP = (0, -signal.SIGTERM, 128 + signal.SIGTERM)
# How long both children get to stop after SIGTERM before they are killed. The
# template's terminationGracePeriodSeconds (90) is longer.
_STOP_GRACE = 60.0


def _executor_commands(codex: str, dispatch: dict[str, str], port: int) -> tuple[list[str], list[str]]:
    """The executor and forwarder command lines, both on the pod's loopback.

    Why two processes: the single-process ``codex exec-server --remote ...
    --environment-id ...`` failed on the pinned Codex build (0.163.0-alpha.11)
    in this blueprint's test runs 2, 6 and 7: the agent had no usable tool and
    the executor logged nothing. The same build in Codex's documented forward
    mode (``exec-server/README.md``, "Remote connections"), an executor on
    loopback and a forwarder that registers with OpenAI, ran the agent's tools
    in run 4. That is observed behaviour on this build, not a documented cause.
    """
    local = f"ws://{LOOPBACK}:{port}"
    executor = [codex, "exec-server", "--listen", local]
    # `forward` must come before --remote and --environment-id: the pinned
    # build's argument parser rejects those two in front of it.
    forwarder = [
        codex,
        "exec-server",
        "forward",
        "--remote",
        dispatch["remote_url"],
        "--environment-id",
        dispatch["environment_id"],
        "--connect",
        local,
    ]
    return executor, forwarder


def _wait_listening(port: int, proc: subprocess.Popen, timeout: float) -> bool:
    """True once something accepts a TCP connect on the loopback port; False if
    ``proc`` exits first or ``timeout`` seconds pass."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return False
        try:
            socket.create_connection((LOOPBACK, port), timeout=1).close()
            return True
        except OSError:
            time.sleep(0.2)
    return False


def _stop(proc: subprocess.Popen | None, grace: float = 10.0) -> None:
    """SIGTERM a child that is still running, then SIGKILL it after ``grace`` seconds."""
    if proc is None or proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


def _failure_code(code: int) -> int:
    """A non-zero exit status for this process from a child's return code."""
    return code if code > 0 else 1


def _run_executor(dispatch: dict[str, str], on_ready: Callable[[], None]) -> int:
    """Run this session's executor and forwarder; return this process's exit status.

    The key is already in this pod's env, and both children inherit it.
    ``on_ready`` is called once, after the executor is listening and the
    forwarder has started; ``main`` opens the readiness port there.
    """
    codex = config.optional(config.ENV_CODEX_PATH, config.DEFAULT_CODEX_PATH)
    port = config.EXECUTOR_LOOPBACK_PORT
    executor_cmd, forwarder_cmd = _executor_commands(codex, dispatch, port)
    child_env = dict(os.environ)
    child_env.setdefault("CODEX_HOME", f"{config.WORKDIR}/.codex")
    os.makedirs(child_env["CODEX_HOME"], exist_ok=True)

    procs: dict[str, subprocess.Popen] = {}
    stopping = threading.Event()

    def _forward(signum, _frame):
        # On SIGTERM (the claim deleted, or its deadline) stop both children
        # cleanly so the executor can finish its current turn's cleanup.
        stopping.set()
        for proc in list(procs.values()):
            if proc.poll() is None:
                proc.send_signal(signum)

    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, _forward)

    try:
        log.info("session %s: starting the executor, codex exec-server --listen ws://%s:%d",
                 dispatch["session_id"], LOOPBACK, port)
        procs["executor"] = subprocess.Popen(executor_cmd, env=child_env, cwd=config.WORKDIR)  # noqa: S603
        if not _wait_listening(port, procs["executor"], config.EXECUTOR_LISTEN_TIMEOUT):
            if stopping.is_set():
                return 0
            code = procs["executor"].poll()
            log.error("session %s: the executor %s before it listened on %s:%d",
                      dispatch["session_id"],
                      f"exited {code}" if code is not None else
                      f"did not listen within {config.EXECUTOR_LISTEN_TIMEOUT}s", LOOPBACK, port)
            return _failure_code(code) if code is not None else 1
        if stopping.is_set():
            return 0

        log.info("session %s: executor listening; starting the forwarder for environment %s",
                 dispatch["session_id"], dispatch["environment_id"])
        procs["forwarder"] = subprocess.Popen(forwarder_cmd, env=child_env, cwd=config.WORKDIR)  # noqa: S603
        if stopping.is_set():  # SIGTERM came while the forwarder was starting
            procs["forwarder"].terminate()
        on_ready()

        # Supervise: the two only work together, so the first child to exit on
        # its own ends the session, and the finally below stops the other.
        while not stopping.is_set():
            for name, proc in procs.items():
                code = proc.poll()
                if code is not None:
                    log.error("session %s: the %s exited %d; stopping the other",
                              dispatch["session_id"], name, code)
                    return _failure_code(code)
            time.sleep(0.2)

        # SIGTERM was forwarded to both: wait for them, within the pod's grace.
        deadline = time.monotonic() + _STOP_GRACE
        codes = []
        for proc in procs.values():
            try:
                codes.append(proc.wait(timeout=max(0.1, deadline - time.monotonic())))
            except subprocess.TimeoutExpired:
                proc.kill()
                codes.append(proc.wait())
        bad = [c for c in codes if c not in _CLEAN_STOP]
        return _failure_code(bad[0]) if bad else 0
    finally:
        for proc in procs.values():
            _stop(proc)


def main() -> None:
    config.setup_logging()
    guard.assert_safe(guard.ROLE_SERVE)
    os.makedirs(config.WORKDIR, exist_ok=True)
    port = config.optional_int(config.ENV_DISPATCH_PORT, config.DEFAULT_DISPATCH_PORT)

    if not guard.dispatched():
        # A warm pod: no session yet. Hold the readiness port and wait.
        _hold_readiness_port(port)
        sys.exit(0)

    dispatch = _read_dispatch()
    log.info("serving session %s in %s", dispatch["session_id"], config.WORKDIR)
    # A claimed pod runs the executor instead of waiting on the network, but its
    # readinessProbe is the same bare TCP connect on the readiness port. Open
    # that port on a background daemon thread, and only once the executor is
    # listening (``_run_executor`` calls ``_report_ready`` then), so the
    # SandboxClaim reports Ready when there is an executor to serve the session;
    # without the port the claim never reaches Ready and the launcher's
    # wait_for_claim_ready times out. The port still carries no dispatch and no
    # credential: the whole session and the key arrive in the pod's env from the
    # claim, and the network policy admits nothing to a sandbox.
    ready_stop = threading.Event()
    ready_threads: list[threading.Thread] = []

    def _report_ready() -> None:
        srv = _readiness_listener(port, ready_stop)
        thread = threading.Thread(target=_accept_readiness, args=(srv, ready_stop), daemon=True)
        thread.start()
        ready_threads.append(thread)
        log.info("readiness port :%d open while serving session %s", port, dispatch["session_id"])

    try:
        code = _run_executor(dispatch, _report_ready)
    finally:
        ready_stop.set()
        # The listener's one-second accept timeout (set in _readiness_listener)
        # bounds this join, so the socket closes before this process reports exit.
        for thread in ready_threads:
            thread.join()
    log.info("session %s finished (exit %d)", dispatch["session_id"], code)
    sys.exit(code)


if __name__ == "__main__":
    main()
