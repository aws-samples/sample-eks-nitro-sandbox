"""The credential boundary, checked before any process in the cluster starts work.

Claude's reasoning runs on Anthropic's side; only tool execution runs in the
cluster. Three credentials, three places:

  * The organization API key can create agents, start sessions and read every
    session in the organization. It stays on the operator's machine; no pod may
    hold it.
  * The environment key can poll and claim the whole environment's work queue.
    Only the poller and the autoscaler hold it.
  * Each work item carries a secret with a token for that one session. The
    sandbox gets only that, in the dispatch POST, and refuses to start if it
    finds either key.
"""

from __future__ import annotations

import os

from . import config

ROLE_POLL = "poll"
ROLE_SERVE = "serve"
ROLE_STATS = "stats"

# The only ANTHROPIC_* variables each role may have. The SDK reads credentials
# from others too (ANTHROPIC_AUTH_TOKEN, ANTHROPIC_PROFILE, workload identity
# variables) and merges ANTHROPIC_CUSTOM_HEADERS into every request, so anything
# not listed here is refused rather than ignored.
_ALLOWED = {
    ROLE_SERVE: {config.ENV_ENVIRONMENT_ID, config.ENV_BASE_URL},
    ROLE_POLL: {config.ENV_ENVIRONMENT_ID, config.ENV_ENVIRONMENT_KEY, config.ENV_BASE_URL},
    ROLE_STATS: {config.ENV_ENVIRONMENT_ID, config.ENV_ENVIRONMENT_KEY, config.ENV_BASE_URL},
}


def assert_safe(role: str) -> None:
    """Raise unless this role's process holds exactly the credentials it should."""
    if role not in _ALLOWED:
        raise ValueError(f"unknown role {role!r}")
    if os.environ.get(config.ENV_API_KEY):
        raise RuntimeError(
            f"{config.ENV_API_KEY} is set in this pod; refusing to start. The "
            "organization API key stays on the operator's machine."
        )
    if role == ROLE_SERVE and os.environ.get(config.ENV_ENVIRONMENT_KEY):
        raise RuntimeError(
            f"{config.ENV_ENVIRONMENT_KEY} is set in this sandbox; refusing to start. "
            "A sandbox runs on its session's own token, from the dispatch, and must "
            "not hold the key that can claim every session in the environment."
        )
    extra = sorted(k for k in os.environ if k.startswith("ANTHROPIC_") and k not in _ALLOWED[role])
    if extra:
        raise RuntimeError(
            f"unexpected Anthropic variables in this pod: {', '.join(extra)}; refusing to "
            f"start. The {role} role may only have {', '.join(sorted(_ALLOWED[role]))}."
        )
    if role in (ROLE_POLL, ROLE_STATS) and not os.environ.get(config.ENV_ENVIRONMENT_KEY):
        raise RuntimeError(
            f"{config.ENV_ENVIRONMENT_KEY} is not set, so this pod cannot reach the "
            "work queue. Generate an environment key in the Claude Console "
            "(Workspace > Environments > your environment > Generate environment key) "
            "and store it in the anthropic-env-key Secret."
        )
