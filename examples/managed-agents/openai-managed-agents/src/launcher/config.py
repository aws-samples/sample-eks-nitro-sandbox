"""Environment variables shared by the launcher and the sandbox executor.

Two OpenAI credentials, kept apart (see guard.py):

  * The application key (OPENAI_API_KEY) creates sessions and reads them. It
    stays on the operator's machine, used only by scripts/. No pod holds it.
  * The environment key (OPENAI_EXECUTOR_API_KEY, read by codex exec-server as
    CODEX_API_KEY) lets the executor connect its environment. The launcher
    holds it and gives it to each claimed sandbox through the SandboxClaim the
    controller cold-starts for that session, so the key reaches the pod over the
    launcher's authenticated Kubernetes API connection, never over the pod
    network, and a warm pod never holds it.

How the key reaches the sandbox: the launcher calls
``SandboxClient.create_sandbox(..., env={...})``. agent-sandbox writes those
variables into ``SandboxClaim.spec.env``, and the controller injects them into
the pod it starts for that claim. Setting ``spec.env`` forces a cold start from
the warm-pool template rather than adopting a pre-warmed pod, so the key is only
ever present on a pod created for a specific session, never on a warm one.
"""

from __future__ import annotations

import logging
import os

# --- OpenAI credentials ------------------------------------------------------
# The application key: creates agents and sessions and reads every session.
# scripts/ use it on the operator's machine; guard.py refuses to run a pod that
# holds it.
ENV_API_KEY = "OPENAI_API_KEY"
# The environment key: the executor's only credential, held by the launcher.
# codex exec-server reads it as CODEX_API_KEY inside the sandbox. The launcher
# puts it in the claim's env, so the controller sets it on the claimed pod; a
# warm pod has none.
ENV_EXECUTOR_API_KEY = "OPENAI_EXECUTOR_API_KEY"
# The name codex exec-server reads inside the sandbox. The launcher injects it
# into the claimed pod through the SandboxClaim env.
ENV_CODEX_API_KEY = "CODEX_API_KEY"
ENV_BASE_URL = "OPENAI_BASE_URL"  # optional endpoint override, used by scripts/

# --- The session tuple the launcher injects into a claimed sandbox -----------
# These are not secrets: an OpenAI session id, its self-hosted environment id,
# and the remote URL the executor dials out to. The launcher sets them in the
# claim's env alongside CODEX_API_KEY, so the sandbox reads its whole dispatch
# from its own environment and runs no network intake of its own.
ENV_SESSION_ID = "OPENAI_SESSION_ID"
ENV_ENVIRONMENT_ID = "OPENAI_ENVIRONMENT_ID"
ENV_REMOTE_URL = "OPENAI_REMOTE_URL"

# --- The launcher intake's authentication token ------------------------------
# The operator reaches the launcher's intake over a kubectl port-forward to its
# ClusterIP Service. The intake authenticates every request with this
# pre-shared bearer token: the launcher loads it from a mounted Secret, and
# submit.py sends it from the operator's .env. The launcher refuses to start
# without it (fail closed), and the intake rejects any request whose bearer
# token does not match, so a NetworkPolicy is reachability and this token is
# authentication. It is a shared secret the operator already holds to deploy the
# launcher, not minted auth: no pod but the launcher reads it, and the operator
# rotates it by replacing the Secret.
ENV_LAUNCHER_AUTH_TOKEN = "LAUNCHER_AUTH_TOKEN"

# --- This sample -------------------------------------------------------------
ENV_SANDBOX_NAMESPACE = "SANDBOX_NAMESPACE"  # where the warm pool and claims live
ENV_SANDBOX_WARMPOOL = "SANDBOX_WARMPOOL"  # the SandboxWarmPool to claim from
ENV_DISPATCH_PORT = "DISPATCH_PORT"  # the sandbox's readiness port (no intake)
ENV_LAUNCHER_PORT = "LAUNCHER_PORT"  # the launcher's own intake port (ClusterIP Service)
ENV_SANDBOX_READY_TIMEOUT = "SANDBOX_READY_TIMEOUT"  # seconds to wait for a claim to be Ready
ENV_SHUTDOWN_AFTER_SECONDS = "SHUTDOWN_AFTER_SECONDS"  # claim lifetime, from creation
ENV_CODEX_PATH = "CODEX_PATH"  # path to the codex binary in the image

# The working directory for the executor's tool calls. The session is created
# with environment.workspace_directory set to this path.
WORKDIR = "/workspace"

DEFAULT_NAMESPACE = "default"
DEFAULT_WARMPOOL = "openai-sandbox-executor"
# The sandbox's readiness port. serve.py opens a TCP listener here so the claim
# reports Ready; it carries no dispatch and no credential (the whole dispatch
# arrives in the pod's env). The launcher reads nothing from it.
DEFAULT_DISPATCH_PORT = 8080
DEFAULT_LAUNCHER_PORT = 8080
# Bounds the wait for a claim to become Ready. The claim create and the
# session-state recheck run outside it.
#
# Why 300, not 120: the live Round 3c acceptance run timed out at the old
# default of 120s on a real cold-started injection pod (image pull already
# warm, but the pod still needed to come up, open its readiness port, and let
# codex exec-server connect its environment before the claim reported Ready);
# raising it to 300s via `kubectl set env` on the launcher Deployment is what
# let that run finish. 300s is the proven number, not a guess at a bigger one,
# so it is now the shipped default rather than a manual override a reader would
# have to discover. The retry/backoff alternative (claim, time out fast, retry)
# was rejected: a timed-out claim's cold start is not wasted work to retry from
# scratch, and agent-sandbox already reports a specific terminal reason (see the
# Round 3b EnvVarsInjectionRejected finding) rather than an ambiguous failure a
# blind retry would need to distinguish from a transient one.
DEFAULT_SANDBOX_READY_TIMEOUT = 300
# The controller deletes a claim, and its sandbox, at creation + this many
# seconds, whatever the pod is doing. It is the longest a single claimed pod
# lives, so a session's turn (and any same-session follow-up that reuses the
# pod) must finish within it; raise it for longer tasks.
DEFAULT_SHUTDOWN_AFTER_SECONDS = 1800
DEFAULT_CODEX_PATH = "/usr/local/bin/codex"


def require(name: str) -> str:
    """Return a required environment variable, or raise naming it."""
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"{name} is required but not set")
    return value


def optional(name: str, default: str | None = None) -> str | None:
    value = os.environ.get(name)
    return value if value else default


def optional_int(name: str, default: int) -> int:
    return int(optional(name, str(default)))


def setup_logging() -> None:
    # force=True: k8s_agent_sandbox calls logging.basicConfig at import time,
    # which would otherwise leave the root logger at its level and handler.
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        force=True,
    )
    for name in ("httpx", "httpcore", "openai"):
        logging.getLogger(name).setLevel(logging.WARNING)
