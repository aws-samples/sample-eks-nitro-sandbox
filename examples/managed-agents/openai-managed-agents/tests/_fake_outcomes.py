"""What the faked agents API answers to retrieve(), per scenario.

tests/test_setup_agent.py copies this file beside a copy of setup_agent.py, where
the fake _client module imports it, and imports it itself to check the planted
values' premise. It prints nothing.
"""

from __future__ import annotations

from types import SimpleNamespace

import httpx2 as httpx
import openai

KEPT_ID = "agent_kept"
NEW_ID = "agent_new"

# Planted where a proxy behind OPENAI_BASE_URL could put a key: the response body
# and the x-request-id header, which the SDK exposes as exc.request_id.
IN_BODY = "planted-value-in-the-response-body"
IN_HEADER = "planted-value-in-the-request-id-header"

_REQUEST = httpx.Request("GET", f"https://api.openai.example/v1/agents/{KEPT_ID}")


def _status_error(cls, status: int):
    return cls("error", response=httpx.Response(status, request=_REQUEST), body=None)


def _planted_error(cls, status: int):
    return cls(
        f"Error code: {status} - {{'error': '{IN_BODY}'}}",
        response=httpx.Response(status, request=_REQUEST, headers={"x-request-id": IN_HEADER}),
        body={"error": IN_BODY},
    )


_LOOKUPS = {
    "kept": lambda: SimpleNamespace(id=KEPT_ID),
    "404": lambda: _status_error(openai.NotFoundError, 404),
    "network": lambda: openai.APIConnectionError(request=_REQUEST),
    "401": lambda: _status_error(openai.AuthenticationError, 401),
    "403": lambda: _status_error(openai.PermissionDeniedError, 403),
    "500": lambda: _status_error(openai.InternalServerError, 500),
    "planted-404": lambda: _planted_error(openai.NotFoundError, 404),
    "planted-401": lambda: _planted_error(openai.AuthenticationError, 401),
    "planted-500": lambda: _planted_error(openai.InternalServerError, 500),
    "no-id-attribute": lambda: SimpleNamespace(),
    "id-none": lambda: SimpleNamespace(id=None),
    "different-id": lambda: SimpleNamespace(id="agent_other"),
}
LOOKUP_SCENARIOS = sorted(_LOOKUPS)


def lookup(scenario: str):
    """The object retrieve() returns, or the exception it raises, in this scenario."""
    return _LOOKUPS[scenario]()
