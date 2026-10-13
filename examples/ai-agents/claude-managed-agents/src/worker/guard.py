"""The credential boundary, checked before any process in the cluster starts work.

Claude's reasoning runs on Anthropic's side; only tool execution runs in the
cluster. On the first-party Claude API, three credentials, three places:

  * The organization API key can create agents, start sessions and read every
    session in the organization. It stays on the operator's machine; no pod may
    hold it.
  * The environment key can poll and claim the whole environment's work queue.
    Only the poller and the autoscaler hold it.
  * Each work item carries a secret with a token for that one session. The
    sandbox gets only that, in the dispatch POST, and refuses to start if it
    finds either key.

On Claude Platform on AWS (ANTHROPIC_PLATFORM=aws) there is no environment key:
every role signs its requests with the AWS credentials EKS Pod Identity gives
its ServiceAccount, and the sandbox gets no secret in the dispatch. No pod may
hold the organization API key, the environment key or an AWS API key there.
"""

from __future__ import annotations

import os

from . import config

ROLE_POLL = "poll"
ROLE_SERVE = "serve"
ROLE_STATS = "stats"

# The only ANTHROPIC_* variables each role may have. The SDK reads credentials
# from others too (ANTHROPIC_AUTH_TOKEN, ANTHROPIC_PROFILE, workload identity
# variables, ANTHROPIC_AWS_API_KEY) and merges ANTHROPIC_CUSTOM_HEADERS into
# every request, so anything not listed here is refused rather than ignored.
_ALLOWED = {
    ROLE_SERVE: {config.ENV_ENVIRONMENT_ID, config.ENV_BASE_URL, config.ENV_PLATFORM},
    ROLE_POLL: {config.ENV_ENVIRONMENT_ID, config.ENV_ENVIRONMENT_KEY, config.ENV_BASE_URL, config.ENV_PLATFORM},
    ROLE_STATS: {config.ENV_ENVIRONMENT_ID, config.ENV_ENVIRONMENT_KEY, config.ENV_BASE_URL, config.ENV_PLATFORM},
}
# On Claude Platform on AWS every role has the same three: no key of any kind.
_ALLOWED_AWS = {config.ENV_ENVIRONMENT_ID, config.ENV_PLATFORM, config.ENV_AWS_WORKSPACE_ID}


def assert_safe(role: str) -> None:
    """Raise unless this role's process holds exactly the credentials it should."""
    if role not in _ALLOWED:
        raise ValueError(f"unknown role {role!r}")
    if os.environ.get(config.ENV_API_KEY):
        raise RuntimeError(
            f"{config.ENV_API_KEY} is set in this pod; refusing to start. The "
            "organization API key stays on the operator's machine."
        )
    platform = os.environ.get(config.ENV_PLATFORM)
    if platform and platform != config.PLATFORM_AWS:
        raise RuntimeError(
            f"{config.ENV_PLATFORM}={platform!r} is not a platform this sample knows; "
            f"refusing to start. Leave it unset for the Claude API, or set it to "
            f"{config.PLATFORM_AWS!r} for Claude Platform on AWS."
        )
    if config.on_aws():
        _assert_safe_aws(role)
        return
    if role == ROLE_SERVE and os.environ.get(config.ENV_ENVIRONMENT_KEY):
        raise RuntimeError(
            f"{config.ENV_ENVIRONMENT_KEY} is set in this sandbox; refusing to start. "
            "A sandbox runs on its session's own token, from the dispatch, and must "
            "not hold the key that can claim every session in the environment."
        )
    _refuse_extra(role, _ALLOWED[role])
    if role in (ROLE_POLL, ROLE_STATS) and not os.environ.get(config.ENV_ENVIRONMENT_KEY):
        raise RuntimeError(
            f"{config.ENV_ENVIRONMENT_KEY} is not set, so this pod cannot reach the "
            "work queue. Generate an environment key in the Claude Console "
            "(Workspace > Environments > your environment > Generate environment key) "
            "and store it in the anthropic-env-key Secret."
        )


def _assert_safe_aws(role: str) -> None:
    if os.environ.get(config.ENV_ENVIRONMENT_KEY):
        raise RuntimeError(
            f"{config.ENV_ENVIRONMENT_KEY} is set in this pod; refusing to start. On "
            "Claude Platform on AWS every role authenticates with its Pod Identity role, "
            "and an environment key from the Claude Console does not work there."
        )
    _refuse_extra(role, _ALLOWED_AWS)
    if not os.environ.get(config.ENV_AWS_WORKSPACE_ID):
        raise RuntimeError(
            f"{config.ENV_AWS_WORKSPACE_ID} is not set; Claude Platform on AWS needs the "
            "workspace id (wrkspc_...) in the anthropic-env ConfigMap."
        )
    if not (os.environ.get(config.ENV_AWS_REGION) or os.environ.get("AWS_DEFAULT_REGION")):
        raise RuntimeError(
            f"{config.ENV_AWS_REGION} is not set; Claude Platform on AWS needs the "
            "workspace's Region in the anthropic-env ConfigMap."
        )


def _refuse_extra(role: str, allowed: set[str]) -> None:
    extra = sorted(k for k in os.environ if k.startswith("ANTHROPIC_") and k not in allowed)
    if extra:
        raise RuntimeError(
            f"unexpected Anthropic variables in this pod: {', '.join(extra)}; refusing to "
            f"start. The {role} role may only have {', '.join(sorted(allowed))}."
        )
