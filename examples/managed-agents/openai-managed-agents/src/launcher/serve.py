"""``launcher serve`` -- the sandbox's entrypoint: run one session's executor, then exit.

Every sandbox pod runs ``serve``. There is no network intake and no HTTP server
that receives a credential:

  * A **claimed** pod is cold-started by the controller with the session already
    in its environment -- the session id, environment id, remote URL and the
    environment key as ``CODEX_API_KEY``, all set from ``SandboxClaim.spec.env``
    by the launcher's authenticated Kubernetes API call (see ``sandbox.py``).
    ``serve`` reads them from its own environment and runs

        codex exec-server --remote <remote_url> --environment-id <environment_id>

    with the key in that child process's environment only. The executor dials
    out to OpenAI, registers for the environment, and runs the agent's Bash and
    apply-patch tool calls in ``/workspace``. When the turn ends it exits; this
    process exits with it and the pod completes.

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


def _run_executor(dispatch: dict[str, str]) -> int:
    """Run codex exec-server for this session. The key is already in this pod's env."""
    codex = config.optional(config.ENV_CODEX_PATH, config.DEFAULT_CODEX_PATH)
    command = [
        codex,
        "exec-server",
        "--remote",
        dispatch["remote_url"],
        "--environment-id",
        dispatch["environment_id"],
    ]
    child_env = dict(os.environ)
    child_env.setdefault("CODEX_HOME", f"{config.WORKDIR}/.codex")
    os.makedirs(child_env["CODEX_HOME"], exist_ok=True)

    log.info("session %s: starting codex exec-server for environment %s",
             dispatch["session_id"], dispatch["environment_id"])
    proc = subprocess.Popen(command, env=child_env, cwd=config.WORKDIR)  # noqa: S603

    def _forward(signum, _frame):
        # On SIGTERM (for example at the claim's deadline) stop the executor
        # cleanly so it can finish its current turn's cleanup.
        proc.send_signal(signum)

    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, _forward)
    return proc.wait()


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
    # readinessProbe is the same bare TCP connect on the readiness port. Keep
    # that port open on a background daemon thread so the SandboxClaim reports
    # Ready once the executor is up; otherwise the claim never reaches Ready and
    # the launcher's wait_for_claim_ready times out even though codex connected.
    # The port still carries no dispatch and no credential: the whole session
    # and the key arrive in the pod's env from the claim, and the network policy
    # admits nothing to a sandbox.
    ready_stop = threading.Event()
    ready_srv = _readiness_listener(port, ready_stop)
    ready_thread = threading.Thread(
        target=_accept_readiness, args=(ready_srv, ready_stop), daemon=True
    )
    ready_thread.start()
    try:
        log.info("readiness port :%d open while serving session %s", port, dispatch["session_id"])
        code = _run_executor(dispatch)
    finally:
        ready_stop.set()
        # The listener's one-second accept timeout (set in _readiness_listener)
        # bounds this join, so the socket closes before this process reports exit.
        ready_thread.join()
    log.info("session %s finished (exit %d)", dispatch["session_id"], code)
    sys.exit(0 if code in (0, -signal.SIGTERM, 143) else code)


if __name__ == "__main__":
    main()
