"""Build the Anthropic clients the three roles use."""

from __future__ import annotations

from anthropic import Anthropic, AsyncAnthropic

from . import config


def _base_url() -> dict[str, object]:
    base_url = config.optional(config.ENV_BASE_URL)
    return {"base_url": base_url} if base_url else {}


def make_async_client() -> AsyncAnthropic:
    """The poller's client, authenticated with the environment key (caller closes it)."""
    return AsyncAnthropic(auth_token=config.require(config.ENV_ENVIRONMENT_KEY), **_base_url())


def make_sync_client() -> Anthropic:
    """The autoscaler's client for ``work.stats``, authenticated with the environment key."""
    return Anthropic(auth_token=config.require(config.ENV_ENVIRONMENT_KEY), **_base_url())


def make_session_client() -> AsyncAnthropic:
    """The sandbox's client: no credential of its own (caller closes it).

    EnvironmentWorker never sends a request with this client directly. For the
    session it builds Bearer-only copies carrying the session's token from the
    work secret, and clears any credential the parent has. guard.assert_safe has
    already refused the organization key and the environment key in this pod.
    """
    return AsyncAnthropic(**_base_url())
