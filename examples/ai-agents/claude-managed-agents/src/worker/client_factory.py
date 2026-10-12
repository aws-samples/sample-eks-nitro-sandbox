"""Build the Anthropic client every role uses: authenticated with the environment key."""

from __future__ import annotations

from anthropic import Anthropic, AsyncAnthropic

from . import config


def _kwargs() -> dict[str, object]:
    kwargs: dict[str, object] = {"auth_token": config.require(config.ENV_ENVIRONMENT_KEY)}
    base_url = config.optional(config.ENV_BASE_URL)
    if base_url:
        kwargs["base_url"] = base_url
    return kwargs


def make_async_client() -> AsyncAnthropic:
    """The async client for the poller and the sandbox worker (caller closes it)."""
    return AsyncAnthropic(**_kwargs())


def make_sync_client() -> Anthropic:
    """The sync client for the autoscaler's ``work.stats`` reads."""
    return Anthropic(**_kwargs())
