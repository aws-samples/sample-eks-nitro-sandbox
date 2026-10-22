"""Environment variables shared by the poller, the sandbox server and the autoscaler.

The ``ANTHROPIC_*`` names are the ones the Anthropic SDK and the ``ant`` CLI read.
"""

from __future__ import annotations

import logging
import os

# --- Anthropic ---------------------------------------------------------------
ENV_ENVIRONMENT_ID = "ANTHROPIC_ENVIRONMENT_ID"
# The environment key: polls and claims this environment's whole work queue.
# Only the poller and the autoscaler hold it; a sandbox runs on its session's
# own token from the work item's secret.
ENV_ENVIRONMENT_KEY = "ANTHROPIC_ENVIRONMENT_KEY"
ENV_BASE_URL = "ANTHROPIC_BASE_URL"  # optional endpoint override
# The organization API key. It creates agents, environments and sessions, so it
# stays on the operator's machine; guard.py refuses to run if a pod has it.
ENV_API_KEY = "ANTHROPIC_API_KEY"  # pragma: allowlist secret

# --- Claude Platform on AWS (optional) ---------------------------------------
# ANTHROPIC_PLATFORM=aws switches every role to the SDK's AnthropicAWS client,
# which signs each request with SigV4 using the pod's AWS credentials (EKS Pod
# Identity), sends it to aws-external-anthropic.<AWS_REGION>.api.aws and adds
# the anthropic-workspace-id header. That path has no environment key. Unset,
# the sample uses the first-party Claude API.
ENV_PLATFORM = "ANTHROPIC_PLATFORM"
PLATFORM_AWS = "aws"
ENV_AWS_WORKSPACE_ID = "ANTHROPIC_AWS_WORKSPACE_ID"  # read by AnthropicAWS itself
ENV_AWS_REGION = "AWS_REGION"  # the workspace's Region; read by AnthropicAWS itself

# --- This sample -------------------------------------------------------------
ENV_SANDBOX_NAMESPACE = "SANDBOX_NAMESPACE"  # where the warm pool and claims live
ENV_SANDBOX_WARMPOOL = "SANDBOX_WARMPOOL"  # the SandboxWarmPool to claim from
ENV_DISPATCH_PORT = "DISPATCH_PORT"  # the sandbox's dispatch port
ENV_SANDBOX_READY_TIMEOUT = "SANDBOX_READY_TIMEOUT"  # seconds to wait for a claim to be Ready
ENV_MAX_REDISPATCH = "MAX_REDISPATCH"  # give up on a session after this many dispatches
ENV_SHUTDOWN_AFTER_SECONDS = "SHUTDOWN_AFTER_SECONDS"  # claim lifetime, from creation

# Autoscaler
ENV_WARMPOOL_MIN = "WARMPOOL_MIN"
ENV_WARMPOOL_MAX = "WARMPOOL_MAX"
ENV_POLL_INTERVAL_SECONDS = "POLL_INTERVAL_SECONDS"

# The working directory for tool calls and skill downloads. On a self-hosted
# environment Claude is told to work in /workspace.
WORKDIR = "/workspace"

DEFAULT_NAMESPACE = "default"
DEFAULT_WARMPOOL = "claude-sandbox-worker"
DEFAULT_DISPATCH_PORT = 8080
# Bounds only the wait for a claim to become Ready (k8s-agent-sandbox's
# claim-ready watch). The reap of earlier claims, the claim create, the pod IP
# lookup and the dispatch POST run outside it, so it does not bound the whole
# hand-off. Nothing heartbeats the work item between the poller's ack and the
# sandbox's first heartbeat, and the SDK assumes a 90 s lease TTL until a
# heartbeat reply reports the real one (it is the SDK's assumption, not the
# server's lease). 75 s keeps the claim wait inside that assumed TTL.
DEFAULT_SANDBOX_READY_TIMEOUT = 75
DEFAULT_MAX_REDISPATCH = 3
# The controller deletes a claim, and its sandbox, at creation + this many
# seconds, whatever the pod is doing. So it is also the longest a session can
# run, and a finished pod stays visible until then.
DEFAULT_SHUTDOWN_AFTER_SECONDS = 1800
DEFAULT_POLL_INTERVAL_SECONDS = 15
DEFAULT_WARMPOOL_MIN = 1
DEFAULT_WARMPOOL_MAX = 10


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


def on_aws() -> bool:
    """True when ANTHROPIC_PLATFORM selects Claude Platform on AWS.

    guard.assert_safe refuses any other non-empty value before this is read.
    """
    return optional(ENV_PLATFORM) == PLATFORM_AWS


def setup_logging() -> None:
    # force=True: k8s_agent_sandbox calls logging.basicConfig at import time,
    # which would otherwise leave the root logger at its level and handler.
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        force=True,
    )
    # One line per HTTP request (a poll every few seconds) is noise at INFO.
    for name in ("httpx", "httpx2"):
        logging.getLogger(name).setLevel(logging.WARNING)
