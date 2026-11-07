"""Tests for scripts/submit.py session creation, with the OpenAI client mocked.

These assert the behaviour a reader running the documented defaults depends on,
without a live call:

  * the default budget asks for spend_control, but a project that does not
    accept a session budget still gets a session: submit.py drops spend_control
    and retries once, so `python scripts/submit.py` works unchanged rather than
    forcing the reader to pass --budget-cents 0. Two refusals count: a 400
    'Session budget configuration is not enabled' (param spend_control), and a
    400 whose error code is unknown_parameter and whose param is spend_control
    ("Unknown parameter: 'spend_control'.", what a new project returned);
  * --budget-cents 0 asks for no spend_control at all;
  * any OTHER error is NOT swallowed -- it propagates, so a real bad request is
    not hidden by the fallback: an unrelated 400, an unknown_parameter on another
    param, another spend_control 400, a 400 that only names those words in its
    message, and an error that is not a 400.

Both inputs of each accept/reject pair are exercised, per AGENTS.md.

Run with: python -m pytest
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys

import pytest

import httpx2 as httpx  # the HTTP library openai 3.31.0 ships with
from openai import BadRequestError, UnprocessableEntityError


def _load_submit():
    scripts_dir = pathlib.Path(__file__).resolve().parent.parent / "scripts"
    sys.path.insert(0, str(scripts_dir))  # so submit.py's `from _client import ...` resolves
    try:
        spec = importlib.util.spec_from_file_location("submit_under_test", scripts_dir / "submit.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.path.remove(str(scripts_dir))


submit = _load_submit()


def _api_error(cls, status: int, message: str, param: str | None, code: str | None = None):
    """Build a real SDK status error the way the SDK would, so .body/.code/.param are set.

    The SDK passes the inner `error` object as `body` (see openai/_client.py,
    _make_status_error), and its `message` is the whole "Error code: ..." string.
    """
    request = httpx.Request("POST", "https://api.openai.com/v1/agents/sessions")
    body = {"error": {"message": message, "param": param, "type": "invalid_request_error"}}
    if code is not None:
        body["error"]["code"] = code
    response = httpx.Response(status, request=request, json=body)
    return cls(f"Error code: {status} - {body}", response=response, body=body["error"])


def _bad_request(message: str, param: str | None, code: str | None = None) -> BadRequestError:
    return _api_error(BadRequestError, 400, message, param, code)


# The refusal a new project returned for a session created with spend_control.
UNKNOWN_SPEND_CONTROL = dict(message="Unknown parameter: 'spend_control'.",
                             param="spend_control", code="unknown_parameter")


class _SessionsRecorder:
    """Records each sessions.create call and can fail the first with a chosen error."""

    def __init__(self, first_error: Exception | None = None):
        self._first_error = first_error
        self.calls: list[dict] = []

    def create(self, **kwargs):
        self.calls.append(kwargs)
        if self._first_error is not None and len(self.calls) == 1:
            raise self._first_error
        return object()  # a stand-in session; the fallback path does not read it


class _Client:
    def __init__(self, sessions):
        self.beta = type("B", (), {"agents": type("A", (), {"sessions": sessions})()})()


# --- the predicate: accepted -------------------------------------------------
def test_predicate_matches_spend_control_not_enabled_by_param():
    exc = _bad_request("Session budget configuration is not enabled", param="spend_control")
    assert submit._is_spend_control_unsupported(exc) is True


def test_predicate_does_not_match_not_enabled_words_without_the_param():
    # Words in a message are not the refusal: the body must name param spend_control.
    exc = _bad_request("spend_control is not enabled for this project", param=None)
    assert submit._is_spend_control_unsupported(exc) is False


def test_predicate_does_not_match_another_not_enabled_message_on_spend_control():
    exc = _bad_request("The audit feature is not enabled; the request also mentioned spend_control.",
                       param="spend_control")
    assert submit._is_spend_control_unsupported(exc) is False


def test_predicate_matches_unknown_parameter_spend_control():
    exc = _bad_request(**UNKNOWN_SPEND_CONTROL)
    assert submit._is_spend_control_unsupported(exc) is True


# --- the predicate: rejected -------------------------------------------------
def test_predicate_does_not_match_an_unrelated_400():
    exc = _bad_request("model is required", param="model")
    assert submit._is_spend_control_unsupported(exc) is False


def test_predicate_does_not_match_unknown_parameter_on_another_param():
    exc = _bad_request("Unknown parameter: 'budget'.", param="budget", code="unknown_parameter")
    assert submit._is_spend_control_unsupported(exc) is False


def test_predicate_does_not_match_another_spend_control_400():
    exc = _bad_request("spend_control.limit must be a positive integer.",
                       param="spend_control", code="invalid_value")
    assert submit._is_spend_control_unsupported(exc) is False


def test_predicate_reads_code_and_param_from_the_body_not_the_message():
    # The words are in the message, but the structured fields say otherwise.
    exc = _bad_request("unknown_parameter spend_control appears only in this text",
                       param="input", code="invalid_value")
    assert submit._is_spend_control_unsupported(exc) is False


def test_predicate_does_not_match_an_error_that_is_not_a_400():
    exc = _api_error(UnprocessableEntityError, 422, **UNKNOWN_SPEND_CONTROL)
    assert submit._is_spend_control_unsupported(exc) is False


# --- create_session fallback: accepted ---------------------------------------
@pytest.mark.parametrize("error", [
    _bad_request("Session budget configuration is not enabled", param="spend_control"),
    _bad_request(**UNKNOWN_SPEND_CONTROL),
], ids=["not-enabled", "unknown-parameter"])
def test_spend_control_400_is_tolerated_and_retried_without_it(capsys, error):
    sessions = _SessionsRecorder(first_error=error)
    client = _Client(sessions)

    submit.create_session(client, "agent_1", {"limit": 100})

    assert len(sessions.calls) == 2, "should retry exactly once"
    assert "spend_control" in sessions.calls[0], "first attempt asks for the budget"
    assert "spend_control" not in sessions.calls[1], "retry drops the budget"
    first_without_budget = {k: v for k, v in sessions.calls[0].items() if k != "spend_control"}
    assert sessions.calls[1] == first_without_budget, "the retry changes nothing else"
    out = capsys.readouterr().out  # the reader is told why, and what it means
    assert "does not accept a session budget" in out
    assert "no budget ceiling" in out


# --- create_session fallback: rejected ---------------------------------------
@pytest.mark.parametrize("error", [
    _bad_request("model is required", param="model"),
    _bad_request("Unknown parameter: 'budget'.", param="budget", code="unknown_parameter"),
    _bad_request("spend_control.limit must be a positive integer.",
                 param="spend_control", code="invalid_value"),
    _api_error(UnprocessableEntityError, 422, **UNKNOWN_SPEND_CONTROL),
], ids=["unrelated-400", "unknown-parameter-other-param", "other-spend-control-400", "not-a-400"])
def test_other_errors_are_not_swallowed(error):
    sessions = _SessionsRecorder(first_error=error)
    client = _Client(sessions)

    with pytest.raises(type(error)) as raised:
        submit.create_session(client, "agent_1", {"limit": 100})
    assert raised.value is error, "the original error propagates unchanged"
    assert len(sessions.calls) == 1, "an error that is not the budget refusal is not retried"


# --- the same, through the real SDK client and its own error parsing ----------
def _sdk_client(refusal: dict, calls: list):
    """A real OpenAI client whose transport refuses any create that asks for spend_control."""
    import json

    from openai import OpenAI

    def handler(request):
        body = json.loads(request.content)
        calls.append(sorted(body))
        if "spend_control" in body:
            return httpx.Response(400, json={"error": refusal})
        return httpx.Response(200, json={"id": "sesn_test", "object": "agent.session"})

    # The transport is mocked, so no request leaves the process and the key is a placeholder.
    return OpenAI(api_key="not-used",  # pragma: allowlist secret
                  base_url="https://api.openai.test/v1", max_retries=0,
                  http_client=httpx.Client(transport=httpx.MockTransport(handler)))


def test_the_live_refusal_through_the_sdk_is_retried_without_a_budget():
    calls: list = []
    refusal = {"type": "invalid_request_error", "code": "unknown_parameter",
               "message": "Unknown parameter: 'spend_control'.", "param": "spend_control"}

    session = submit.create_session(_sdk_client(refusal, calls), "agent_1", {"limit": 100})

    assert session.id == "sesn_test"
    assert len(calls) == 2 and "spend_control" in calls[0] and "spend_control" not in calls[1]


def test_unknown_parameter_on_another_param_through_the_sdk_is_raised():
    calls: list = []
    refusal = {"type": "invalid_request_error", "code": "unknown_parameter",
               "message": "Unknown parameter: 'metadata'.", "param": "metadata"}

    with pytest.raises(BadRequestError):
        submit.create_session(_sdk_client(refusal, calls), "agent_1", {"limit": 100})
    assert len(calls) == 1


def test_budget_cents_zero_sends_no_spend_control():
    sessions = _SessionsRecorder()
    client = _Client(sessions)

    submit.create_session(client, "agent_1", None)

    assert len(sessions.calls) == 1
    assert "spend_control" not in sessions.calls[0]


def test_a_budget_is_passed_through_when_the_project_supports_it():
    sessions = _SessionsRecorder()
    client = _Client(sessions)

    submit.create_session(client, "agent_1", {"limit": 100})

    assert len(sessions.calls) == 1
    assert sessions.calls[0]["spend_control"] == {"limit": 100}
