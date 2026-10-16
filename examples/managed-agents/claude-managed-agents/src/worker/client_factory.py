"""Build the Anthropic clients the three roles use.

First-party Claude API (the default): the poller and the autoscaler authenticate
with the environment key, and the sandbox with its session's token.

Claude Platform on AWS (ANTHROPIC_PLATFORM=aws): every role uses the SDK's
AnthropicAWS client. It reads AWS_REGION and ANTHROPIC_AWS_WORKSPACE_ID, signs
each request with SigV4 from the default AWS credential chain (here, the pod's
EKS Pod Identity credentials), sends it to aws-external-anthropic.<region>.api.aws
and adds the anthropic-workspace-id header. There is no environment key on
this path, and guard.assert_safe has refused ANTHROPIC_AWS_API_KEY, which would
switch the client from SigV4 to an API key.
"""

from __future__ import annotations

from anthropic import Anthropic, AnthropicAWS, AsyncAnthropic, AsyncAnthropicAWS

from . import config


def _base_url() -> dict[str, object]:
    base_url = config.optional(config.ENV_BASE_URL)
    return {"base_url": base_url} if base_url else {}


def make_async_client() -> AsyncAnthropic:
    """The poller's client (caller closes it): the environment key, or SigV4 on AWS."""
    if config.on_aws():
        return AsyncAnthropicAWS()
    return AsyncAnthropic(auth_token=config.require(config.ENV_ENVIRONMENT_KEY), **_base_url())


def make_sync_client() -> Anthropic:
    """The autoscaler's client for ``work.stats``: the environment key, or SigV4 on AWS."""
    if config.on_aws():
        return AnthropicAWS()
    return Anthropic(auth_token=config.require(config.ENV_ENVIRONMENT_KEY), **_base_url())


def make_session_client() -> AsyncAnthropic:
    """The sandbox's client (caller closes it).

    First-party: no credential of its own. EnvironmentWorker never sends a
    request with this client directly. For the session it builds Bearer-only
    copies carrying the session's token from the work secret, and clears any
    credential the parent has. guard.assert_safe has already refused every
    ANTHROPIC_* variable the SDK could read a credential from in this pod.

    Claude Platform on AWS: the SigV4 client, signed with the pod's own AWS
    credentials. EnvironmentWorker's Bearer-only copies of it still sign with
    SigV4 (see serve.py).
    """
    if config.on_aws():
        return AsyncAnthropicAWS()
    return AsyncAnthropic(**_base_url())
