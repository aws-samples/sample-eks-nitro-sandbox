"""The credential boundary, checked before any process in the cluster starts work.

Claude's reasoning runs on Anthropic's side; only tool execution runs in the
cluster. The organization API key can create agents, start sessions and read
every session in the organization, so it must never reach a pod. Every role in
this image authenticates with the environment key instead, which can only claim
work and post tool results for one environment.
"""

from __future__ import annotations

import os

from . import config


def assert_safe() -> None:
    """Raise unless the organization key is absent and the environment key is present."""
    if os.environ.get(config.ENV_API_KEY):
        raise RuntimeError(
            f"{config.ENV_API_KEY} is set in this pod; refusing to start. The "
            "organization API key stays on the operator's machine. Pods authenticate "
            f"with {config.ENV_ENVIRONMENT_KEY} only."
        )
    if not os.environ.get(config.ENV_ENVIRONMENT_KEY):
        raise RuntimeError(
            f"{config.ENV_ENVIRONMENT_KEY} is not set, so this pod cannot reach the "
            "work queue. Generate an environment key in the Claude Console "
            "(Workspace > Environments > your environment > Generate environment key) "
            "and store it in the anthropic-env-key Secret."
        )
