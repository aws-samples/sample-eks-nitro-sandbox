"""What the faked agents API answers to retrieve() and create(), per scenario.

tests/test_setup_agent.py copies this file beside a copy of setup_agent.py, where
the fake _client module imports it, and imports it itself to check the planted
values' premise and that every error class is covered. It prints nothing.

Both the lookup scenarios and the create scenarios are generated from one table
of exception classes, _ERROR_BUILDERS, so neither path can quietly cover a class
the other misses. Round 9 of the second review found the earlier version pooling
the two: coverage was asserted on the union, so deleting the lookup's 429 still
reported complete coverage because the create side happened to supply
RateLimitError.

Every create error that carries a response is planted with both values a proxy
behind OPENAI_BASE_URL controls, rather than only three of them: round 9 showed a
mutation that printed those fields only for RateLimitError surviving the whole
create suite, because the one 429 case had nothing planted in it.
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


def _response(status: int, planted: bool) -> httpx.Response:
    headers = {"x-request-id": IN_HEADER} if planted else {}
    return httpx.Response(status, request=_REQUEST, headers=headers)


def _message(status: int | None, planted: bool) -> str:
    if not planted:
        return "error"
    return f"Error code: {status} - {{'error': '{IN_BODY}'}}"


def _body(planted: bool):
    return {"error": IN_BODY} if planted else None


def _status_error(cls, status: int):
    """An APIStatusError subclass with the ordinary (message, response, body) shape."""
    return lambda planted: cls(
        _message(status, planted), response=_response(status, planted), body=_body(planted)
    )


# What each class actually exposes of the two values a proxy controls, as the
# pinned SDK is written. Not "does it have a response": round 9's fix asserted the
# premise for every class at once, and the SDK answered that two of them expose
# less than that would imply.
#   BODY       the response body reaches str(exc), which a traceback prints
#   REQUEST_ID the x-request-id header reaches exc.request_id
# A class exposing neither has nothing to leak through either channel, which is a
# fact about the SDK and is pinned by its own test rather than left implied.
BODY = "body"
REQUEST_ID = "request_id"
_BOTH = frozenset({BODY, REQUEST_ID})
_NEITHER = frozenset()


# One builder per openai.APIError subclass the SDK loads, keyed by the scenario
# name used in both _LOOKUPS and _CREATES.
#   scenario name -> (class, builder(planted), what the class exposes)
_ERROR_BUILDERS = {
    # Takes a message and a body but has no response, so no request_id property.
    "api-error": (
        openai.APIError,
        lambda planted: openai.APIError(_message(None, planted), _REQUEST, body=_body(planted)),
        frozenset({BODY}),
    ),
    # Transport-level: the SDK writes the whole message and there is no response,
    # so a proxy has nowhere to put anything in either of them.
    "network": (
        openai.APIConnectionError,
        lambda planted: openai.APIConnectionError(request=_REQUEST),
        _NEITHER,
    ),
    "timeout": (
        openai.APITimeoutError,
        lambda planted: openai.APITimeoutError(_REQUEST),
        _NEITHER,
    ),
    # Carries a response and a body, but writes its own fixed message ("Data
    # returned by API invalid for expected schema.") and is an APIError rather
    # than an APIStatusError, so it has no request_id attribute at all.
    "response-invalid": (
        openai.APIResponseValidationError,
        lambda planted: openai.APIResponseValidationError(_response(200, planted), _body(planted)),
        _NEITHER,
    ),
    # Fixed message ("OAuth authentication error.") so the body never reaches
    # str(exc), but it is an APIStatusError, so the header does reach request_id.
    "oauth": (
        openai.OAuthError,
        lambda planted: openai.OAuthError(response=_response(401, planted), body=_body(planted)),
        frozenset({REQUEST_ID}),
    ),
    # The ordinary APIStatusError subclasses expose both.
    "api-status": (openai.APIStatusError, _status_error(openai.APIStatusError, 418), _BOTH),
    "400": (openai.BadRequestError, _status_error(openai.BadRequestError, 400), _BOTH),
    "401": (openai.AuthenticationError, _status_error(openai.AuthenticationError, 401), _BOTH),
    "403": (openai.PermissionDeniedError, _status_error(openai.PermissionDeniedError, 403), _BOTH),
    "404": (openai.NotFoundError, _status_error(openai.NotFoundError, 404), _BOTH),
    "409": (openai.ConflictError, _status_error(openai.ConflictError, 409), _BOTH),
    "422": (
        openai.UnprocessableEntityError,
        _status_error(openai.UnprocessableEntityError, 422),
        _BOTH,
    ),
    "429": (openai.RateLimitError, _status_error(openai.RateLimitError, 429), _BOTH),
    "500": (openai.InternalServerError, _status_error(openai.InternalServerError, 500), _BOTH),
}

# The lookup keeps the shape the earlier rounds cleared: a plain error per class,
# plus the three planted ones whose expected output proves nothing leaks.
_LOOKUPS = {
    "kept": lambda: SimpleNamespace(id=KEPT_ID),
    # The same, but echoing whatever id was asked for rather than a fixed one, so
    # a case can use an id of its own and still reach the keeping path. With the
    # usual agent_kept this is indistinguishable from "kept"; see lookup() below.
    "echoes-what-was-asked": lambda: SimpleNamespace(id=KEPT_ID),
    # Succeeded, but not with this agent's id. Three of them, not four.
    "no-id-attribute": lambda: SimpleNamespace(),
    "id-none": lambda: SimpleNamespace(id=None),
    "different-id": lambda: SimpleNamespace(id="agent_other"),
}
for _name, (_cls, _build, _exposes) in _ERROR_BUILDERS.items():
    _LOOKUPS[_name] = (lambda b=_build: b(False))
for _name in ("404", "401", "500"):
    _LOOKUPS[f"planted-{_name}"] = (lambda b=_ERROR_BUILDERS[_name][1]: b(True))
LOOKUP_SCENARIOS = sorted(_LOOKUPS)

# Every create error is planted wherever there is somewhere to plant, so each
# create case proves the absence of a leak as well as the message.
_CREATES = {
    "created": lambda: SimpleNamespace(id=NEW_ID),
    # Succeeded with nothing a reader could paste into .env.
    "create-no-id-attribute": lambda: SimpleNamespace(),
    "create-id-none": lambda: SimpleNamespace(id=None),
    "create-id-blank": lambda: SimpleNamespace(id=""),
    "create-id-not-a-string": lambda: SimpleNamespace(id=1234),
    # Succeeded with a string that must not be printed: the step's output is
    # pasted into .env and loaded with `set -a; . ./.env; set +a`, so these would
    # be run rather than assigned. The command substitution is the one round 9
    # demonstrated end to end.
    "create-id-command-substitution": lambda: SimpleNamespace(id='$(touch pwned)'),
    "create-id-backtick": lambda: SimpleNamespace(id="`touch pwned`"),
    "create-id-newline": lambda: SimpleNamespace(id="agent_ok\nexport EVIL=1"),
    "create-id-space": lambda: SimpleNamespace(id="agent ok"),
    "create-id-leading-space": lambda: SimpleNamespace(id=" agent_ok"),
    "create-id-only-spaces": lambda: SimpleNamespace(id="   "),
    "create-id-quote": lambda: SimpleNamespace(id="agent_'ok"),
    "create-id-semicolon": lambda: SimpleNamespace(id="agent_ok;touch pwned"),
    "create-id-too-long": lambda: SimpleNamespace(id="a" * 129),
}
# Every create error is planted: the builder puts both values wherever its own
# constructor accepts them, so each create case proves the absence of a leak as
# well as the message.
for _name, (_cls, _build, _exposes) in _ERROR_BUILDERS.items():
    _CREATES[f"create-{_name}"] = (lambda b=_build: b(True))
CREATE_SCENARIOS = sorted(_CREATES)


def _create_scenarios_exposing(channel: str) -> list[str]:
    return sorted(
        f"create-{name}"
        for name, (_c, _b, exposes) in _ERROR_BUILDERS.items()
        if channel in exposes
    )


# Which premise each create error supports, taken from the table above rather than
# from "does it carry a response". Round 9's fix asserted both channels for every
# class at once; the SDK then showed that OAuthError writes its own message (so the
# body never reaches str(exc)) and that APIResponseValidationError does that *and*
# is an APIError rather than an APIStatusError, so it has no request_id attribute
# at all. Those are facts about the SDK, not gaps in the planting, and the test for
# the third list pins them so that an SDK which starts exposing either one fails
# here instead of passing quietly.
PLANTED_CREATE_BODY_SCENARIOS = _create_scenarios_exposing(BODY)
PLANTED_CREATE_HEADER_SCENARIOS = _create_scenarios_exposing(REQUEST_ID)
EXPOSING_NEITHER_CREATE_SCENARIOS = sorted(
    f"create-{name}"
    for name, (_c, _b, exposes) in _ERROR_BUILDERS.items()
    if not exposes
)


def lookup(scenario: str, requested: str | None = None):
    """The object retrieve() returns, or the exception it raises, in this scenario.

    `requested` is the id retrieve() was called with. Only one scenario uses it,
    to answer with that same id: a case that needs the keeping path reached with
    an id of its own cannot use "kept", because the fixed agent_kept would come
    back as "a different agent id" and stop the run before the path it is testing.
    """
    if scenario == "echoes-what-was-asked" and requested is not None:
        return SimpleNamespace(id=requested)
    return _LOOKUPS[scenario]()


def create(scenario: str):
    """The object create() returns, or the exception it raises, in this scenario."""
    return _CREATES[scenario]()


def _classes_raised(scenarios: dict) -> set[type]:
    outcomes = [factory() for factory in scenarios.values()]
    return {type(outcome) for outcome in outcomes if isinstance(outcome, BaseException)}


def lookup_error_classes() -> set[type]:
    """The class of every exception the lookup scenarios raise."""
    return _classes_raised(_LOOKUPS)


def create_error_classes() -> set[type]:
    """The class of every exception the create scenarios raise."""
    return _classes_raised(_CREATES)


def sdk_error_classes() -> set[type]:
    """Every openai.APIError subclass loaded in the installed SDK, as classes.

    Classes, not names: round 9 showed the name-based version missing a distinct
    subclass that happened to share a name with a covered one. Still bounded by
    what is loaded -- a subclass in a module nobody has imported is invisible to
    __subclasses__(), which is why the tests' claim says "loaded".
    """
    found: set[type] = {openai.APIError}

    def walk(cls: type) -> None:
        for subclass in cls.__subclasses__():
            found.add(subclass)
            walk(subclass)

    walk(openai.APIError)
    return found
