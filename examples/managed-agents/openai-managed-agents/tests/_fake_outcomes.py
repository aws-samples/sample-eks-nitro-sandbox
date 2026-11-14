"""What the faked agents API answers to retrieve() and create(), per scenario.

tests/test_setup_agent.py copies this file beside a copy of setup_agent.py, where
the fake _client module imports it, and imports it itself to check the planted
values' premise and that every error class is covered. It prints nothing.

The lookup scenarios cover every openai.APIError subclass the pinned SDK defines,
so "any other failure" is a claim about a known set rather than about the five
classes that happened to come to mind; test_setup_agent.py asserts that set is
still complete against the installed SDK.
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


# One scenario per openai.APIError subclass, plus the three planted ones and the
# four responses that carry no usable id. The classes whose constructor differs
# from the APIStatusError shape are built directly.
_LOOKUPS = {
    "kept": lambda: SimpleNamespace(id=KEPT_ID),
    # Every error class in the pinned SDK, by the status it answers with.
    "api-error": lambda: openai.APIError("error", _REQUEST, body=None),
    "api-status": lambda: _status_error(openai.APIStatusError, 418),
    "network": lambda: openai.APIConnectionError(request=_REQUEST),
    "timeout": lambda: openai.APITimeoutError(_REQUEST),
    "response-invalid": lambda: openai.APIResponseValidationError(
        httpx.Response(200, request=_REQUEST), None
    ),
    "400": lambda: _status_error(openai.BadRequestError, 400),
    "401": lambda: _status_error(openai.AuthenticationError, 401),
    "403": lambda: _status_error(openai.PermissionDeniedError, 403),
    "404": lambda: _status_error(openai.NotFoundError, 404),
    "409": lambda: _status_error(openai.ConflictError, 409),
    "422": lambda: _status_error(openai.UnprocessableEntityError, 422),
    "429": lambda: _status_error(openai.RateLimitError, 429),
    "500": lambda: _status_error(openai.InternalServerError, 500),
    "oauth": lambda: openai.OAuthError(
        response=httpx.Response(401, request=_REQUEST), body=None
    ),
    # The same answers, carrying a value in both places a proxy controls.
    "planted-404": lambda: _planted_error(openai.NotFoundError, 404),
    "planted-401": lambda: _planted_error(openai.AuthenticationError, 401),
    "planted-500": lambda: _planted_error(openai.InternalServerError, 500),
    # Succeeded, but not with this agent's id.
    "no-id-attribute": lambda: SimpleNamespace(),
    "id-none": lambda: SimpleNamespace(id=None),
    "different-id": lambda: SimpleNamespace(id="agent_other"),
}
LOOKUP_SCENARIOS = sorted(_LOOKUPS)

# What create() answers. The failures are the same shapes as a lookup's, because
# the create path must report them the same way; the last four are a call that
# succeeded without an id a reader could paste into .env.
_CREATES = {
    "created": lambda: SimpleNamespace(id=NEW_ID),
    "create-401": lambda: _status_error(openai.AuthenticationError, 401),
    "create-429": lambda: _status_error(openai.RateLimitError, 429),
    "create-500": lambda: _status_error(openai.InternalServerError, 500),
    "create-network": lambda: openai.APIConnectionError(request=_REQUEST),
    "create-planted-401": lambda: _planted_error(openai.AuthenticationError, 401),
    "create-planted-500": lambda: _planted_error(openai.InternalServerError, 500),
    "create-no-id-attribute": lambda: SimpleNamespace(),
    "create-id-none": lambda: SimpleNamespace(id=None),
    "create-id-blank": lambda: SimpleNamespace(id=""),
    "create-id-not-a-string": lambda: SimpleNamespace(id=1234),
}
CREATE_SCENARIOS = sorted(_CREATES)


def lookup(scenario: str):
    """The object retrieve() returns, or the exception it raises, in this scenario."""
    return _LOOKUPS[scenario]()


def create(scenario: str):
    """The object create() returns, or the exception it raises, in this scenario."""
    return _CREATES[scenario]()


def error_classes_covered() -> set[str]:
    """The name of every exception class the scenarios above raise."""
    outcomes = [factory() for factory in (*_LOOKUPS.values(), *_CREATES.values())]
    return {type(outcome).__name__ for outcome in outcomes if isinstance(outcome, BaseException)}


def sdk_error_classes() -> set[str]:
    """The name of every openai.APIError subclass the installed SDK defines."""
    found: set[str] = set()

    def walk(cls) -> None:
        for subclass in cls.__subclasses__():
            found.add(subclass.__name__)
            walk(subclass)

    walk(openai.APIError)
    return found | {openai.APIError.__name__}
