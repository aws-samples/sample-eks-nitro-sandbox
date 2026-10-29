"""Claim a warm sandbox for one session and give the session to it.

A ``SandboxWarmPool`` keeps sandboxes booted ahead of time. This sample does not
POST the session to a warm pod over the cluster network. Instead the launcher
puts the whole dispatch -- the session id, environment id, remote URL and the
environment key as ``CODEX_API_KEY`` -- into ``SandboxClaim.spec.env`` through
the agent-sandbox client's ``create_sandbox(env=...)``. The controller injects
those into the pod it starts for that claim, so:

  * the environment key reaches the sandbox over the launcher's authenticated
    Kubernetes API connection and the controller, never over the pod network;
  * because setting the claim env forces a cold start from the warm-pool
    template, the key is only ever on a pod created for a specific session, and
    a warm pod holds none. The warm pool still removes the VM-boot and
    image-pull latency; only the final container start is cold.

There is no dispatch HTTP server on the sandbox. ``serve.py`` reads its session
from its own environment and runs the executor; it opens a readiness TCP port so
the claim reports Ready, and that port carries nothing.

The Kubernetes side (create the SandboxClaim with env, wait until Ready, read
the pod name, list and delete claims) goes through the agent-sandbox Python
client, ``k8s-agent-sandbox``.
"""

from __future__ import annotations

import hashlib
import logging
import re

from k8s_agent_sandbox import SandboxClient
from k8s_agent_sandbox.models import SandboxInClusterConnectionConfig

from . import config

log = logging.getLogger(__name__)

SESSION_ID_LABEL = "openai.com/session-id"


def label_safe(value: str) -> str:
    """Reduce an id to a valid label value (<= 63 chars of [a-z0-9-])."""
    safe = re.sub(r"[^a-z0-9-]", "-", value.lower()).strip("-")[:63].rstrip("-")
    return safe or hashlib.sha256(value.encode()).hexdigest()[:12]


class Dispatcher:
    """Claims warm sandboxes and gives each a session through the claim's env."""

    def __init__(self, executor_key: str) -> None:
        self._executor_key = executor_key
        self.namespace = config.optional(config.ENV_SANDBOX_NAMESPACE, config.DEFAULT_NAMESPACE)
        self.warmpool = config.optional(config.ENV_SANDBOX_WARMPOOL, config.DEFAULT_WARMPOOL)
        self.dispatch_port = config.optional_int(config.ENV_DISPATCH_PORT, config.DEFAULT_DISPATCH_PORT)
        self.ready_timeout = config.optional_int(
            config.ENV_SANDBOX_READY_TIMEOUT, config.DEFAULT_SANDBOX_READY_TIMEOUT
        )
        self.shutdown_after_seconds = config.optional_int(
            config.ENV_SHUTDOWN_AFTER_SECONDS, config.DEFAULT_SHUTDOWN_AFTER_SECONDS
        )
        # The launcher drives only the Kubernetes side of the client (create a
        # claim, wait, read the pod, delete claims); it never opens the sandbox's
        # own command/file connection. The connection config is set so the client
        # never falls back to a kubectl port-forward tunnel. The client loads the
        # launcher pod's ServiceAccount token for the Kubernetes API itself.
        self.client = SandboxClient(
            connection_config=SandboxInClusterConnectionConfig(server_port=self.dispatch_port)
        )

    def claimed_sandbox_name(self, session_id: str) -> str | None:
        """Return the sandbox already claimed for this session, or None.

        A same-session follow-up turn should run in the pod the first turn
        claimed. The launcher labels each claim with the session id, so this
        finds an existing live claim for the session.
        """
        names = self.client.list_all_sandboxes(
            namespace=self.namespace,
            label_selector=f"{SESSION_ID_LABEL}={label_safe(session_id)}",
        )
        return names[0] if names else None

    def dispatch(self, *, session_id: str, environment_id: str, remote_url: str) -> dict:
        """Claim a warm sandbox for this session and return {sandbox, reused}.

        If a live claim for this session already exists (a same-session follow-up
        turn), reuse it: the same pod still holds the session's /workspace and
        its running executor, so the follow-up turn runs where the first did.
        Otherwise claim a fresh sandbox and inject the whole dispatch into its
        env. Raises if the claim fails. Blocking: run it in a thread.
        """
        existing = self.claimed_sandbox_name(session_id)
        if existing:
            log.info("session=%s already claimed sandbox=%s; reusing it", session_id, existing)
            return {"sandbox": existing, "reused": True}

        # create_sandbox writes env into SandboxClaim.spec.env (a cold start) and
        # waits until the claim reports Ready. shutdown_after_seconds sets the
        # claim's deadline (shutdownPolicy Delete). The key never leaves the
        # control plane: the controller sets it on the pod it starts.
        sandbox = self.client.create_sandbox(
            warmpool=self.warmpool,
            namespace=self.namespace,
            sandbox_ready_timeout=self.ready_timeout,
            labels={SESSION_ID_LABEL: label_safe(session_id)},
            shutdown_after_seconds=self.shutdown_after_seconds,
            env={
                config.ENV_CODEX_API_KEY: self._executor_key,
                config.ENV_SESSION_ID: session_id,
                config.ENV_ENVIRONMENT_ID: environment_id,
                config.ENV_REMOTE_URL: remote_url,
            },
        )
        try:
            name = sandbox.get_pod_name()
            log.info("session=%s -> sandbox=%s (key delivered via claim env)", session_id, name)
            return {"sandbox": name, "reused": False}
        except Exception:
            sandbox.terminate()
            raise
        finally:
            sandbox.close_connection()
            self.client.list_active_sandboxes()

    def delete_claim_for_session(self, session_id: str) -> int:
        """Delete the SandboxClaim(s) for this session. Return how many were deleted.

        Session-aware cleanup deletes the claim only after the caller has
        rechecked the session's state (see launch.py), never on a wall-clock
        deadline alone. Deleting the claim removes the pod; the session itself is
        deleted separately through the Agents API (scripts/cleanup.py).
        """
        k8s = self.client.k8s_helper
        names = self.client.list_all_sandboxes(
            namespace=self.namespace,
            label_selector=f"{SESSION_ID_LABEL}={label_safe(session_id)}",
        )
        for name in names:
            log.info("session=%s deleting claim=%s", session_id, name)
            k8s.delete_sandbox_claim(name, self.namespace)
        return len(names)
