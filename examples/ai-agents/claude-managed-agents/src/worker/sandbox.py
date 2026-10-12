"""Claim a warm sandbox for one session and hand the session to it.

A ``SandboxWarmPool`` keeps sandboxes booted ahead of time, so a claim adopts a
running guest instead of waiting for a VM to boot and an image to pull.

A warm sandbox exists before its session does, so it cannot be given the session
id at start-up. Instead it runs a small HTTP server on its dispatch port (see
``serve.py``). The poller claims a sandbox, reads its pod IP and POSTs
``{session_id, work_id, work_secret}`` to it.

The Kubernetes side (create the SandboxClaim, wait until it is Ready, read the
pod IP, list and delete claims) goes through the agent-sandbox Python client,
``k8s-agent-sandbox``.
"""

from __future__ import annotations

import hashlib
import json
import logging
import re
import time
import urllib.request

from k8s_agent_sandbox import SandboxClient
from k8s_agent_sandbox.models import SandboxInClusterConnectionConfig

from . import config

log = logging.getLogger(__name__)

SESSION_ID_LABEL = "anthropic.com/session-id"
DISPATCH_COUNT_LABEL = "anthropic.com/dispatch-count"


def label_safe(value: str) -> str:
    """Reduce an id to a valid label value (<= 63 chars of [a-z0-9-])."""
    safe = re.sub(r"[^a-z0-9-]", "-", value.lower()).strip("-")[:63].rstrip("-")
    return safe or hashlib.sha1(value.encode()).hexdigest()[:12]


def post_with_retry(url: str, body: bytes, *, attempts: int = 5, timeout: int = 5) -> None:
    """POST ``body`` to ``url``, retrying with backoff; raise the last error."""
    last_err: Exception | None = None
    for i in range(attempts):
        try:
            req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=timeout):
                return
        except OSError as exc:
            last_err = exc
            time.sleep(0.5 * (2**i))
    assert last_err is not None
    raise last_err


class Dispatcher:
    """Claims warm sandboxes and dispatches sessions to them."""

    def __init__(self) -> None:
        self.namespace = config.optional(config.ENV_SANDBOX_NAMESPACE, config.DEFAULT_NAMESPACE)
        self.warmpool = config.optional(config.ENV_SANDBOX_WARMPOOL, config.DEFAULT_WARMPOOL)
        self.dispatch_port = config.optional_int(config.ENV_DISPATCH_PORT, config.DEFAULT_DISPATCH_PORT)
        self.ready_timeout = config.optional_int(
            config.ENV_SANDBOX_READY_TIMEOUT, config.DEFAULT_SANDBOX_READY_TIMEOUT
        )
        self.max_redispatch = config.optional_int(config.ENV_MAX_REDISPATCH, config.DEFAULT_MAX_REDISPATCH)
        self.shutdown_after_seconds = config.optional_int(
            config.ENV_SHUTDOWN_AFTER_SECONDS, config.DEFAULT_SHUTDOWN_AFTER_SECONDS
        )
        # In-cluster: the poller reaches the sandbox at its pod IP directly.
        # The client loads the pod's ServiceAccount credentials itself.
        self.client = SandboxClient(
            connection_config=SandboxInClusterConnectionConfig(server_port=self.dispatch_port)
        )

    def reap_stale_claims(self, session_id: str) -> int:
        """Delete earlier claims for this session and return the highest dispatch count seen.

        A session can be offered again after its sandbox died. The new dispatch gets
        a fresh sandbox, so the old claim is removed rather than left running.
        """
        k8s = self.client.k8s_helper
        names = self.client.list_all_sandboxes(
            namespace=self.namespace,
            label_selector=f"{SESSION_ID_LABEL}={label_safe(session_id)}",
        )
        prev = 0
        for name in names:
            claim = k8s.get_sandbox_claim(name, self.namespace) or {}
            labels = (claim.get("metadata") or {}).get("labels") or {}
            prev = max(prev, int(labels.get(DISPATCH_COUNT_LABEL, "0")))
            log.info("session=%s deleting earlier claim=%s (dispatch #%d)", session_id, name, prev)
            k8s.delete_sandbox_claim(name, self.namespace)
        return prev

    def dispatch(self, *, session_id: str, work_id: str, work_secret: str) -> bool:
        """Claim a warm sandbox and POST the session to it.

        Returns False when the session has been dispatched too many times and the
        caller should stop its work item instead. Blocking: run it in a thread.
        """
        attempt = self.reap_stale_claims(session_id) + 1
        if attempt > self.max_redispatch:
            log.warning("session=%s reached max-redispatch=%d", session_id, self.max_redispatch)
            return False

        # create_sandbox creates the SandboxClaim against the warm pool, waits
        # until the claim reports Ready, and deletes the claim if that fails.
        # shutdown_after_seconds sets the claim's deadline (shutdownPolicy Delete).
        sandbox = self.client.create_sandbox(
            warmpool=self.warmpool,
            namespace=self.namespace,
            sandbox_ready_timeout=self.ready_timeout,
            labels={SESSION_ID_LABEL: label_safe(session_id), DISPATCH_COUNT_LABEL: str(attempt)},
            shutdown_after_seconds=self.shutdown_after_seconds,
        )
        try:
            host = sandbox.get_pod_ip()
            if not host:
                raise RuntimeError(f"claimed sandbox {sandbox.sandbox_id} reports no pod IP")
            log.info("session=%s work=%s -> sandbox=%s", session_id, work_id, sandbox.sandbox_id)
            # The per-session secret goes only to the sandbox serving this
            # session, and is its only credential. Never logged.
            body = {"session_id": session_id, "work_id": work_id, "work_secret": work_secret}
            post_with_retry(f"http://{host}:{self.dispatch_port}/", json.dumps(body).encode())
        except Exception:
            sandbox.terminate()
            raise
        # The sandbox now owns the session. Drop the client-side handle; the
        # claim's deadline removes the claim and its pod.
        sandbox.close_connection()
        self.client.list_active_sandboxes()  # prunes closed handles
        return True
