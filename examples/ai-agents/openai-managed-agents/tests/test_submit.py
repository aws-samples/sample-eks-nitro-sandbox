"""Tests for scripts/submit.py session creation, with the OpenAI client mocked.

These assert the behaviour a reader running the documented defaults depends on,
without a live call:

  * the default budget asks for spend_control, but a project that has per-session
    budgets turned OFF (OpenAI answers 400 'Session budget configuration is not
    enabled', param spend_control) still gets a session: submit.py drops
    spend_control and retries once, so `python scripts/submit.py` works unchanged
    rather than forcing the reader to pass --budget-cents 0;
  * --budget-cents 0 asks for no spend_control at all;
  * an UNRELATED 400 is NOT swallowed -- it propagates, so a real bad request is
    not hidden by the fallback.

Both inputs of the accept/reject pair are exercised (a spend_control 400 that
must be tolerated, and a different 400 that must not be), per AGENTS.md.

Run with: python -m pytest
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys

import pytest

import httpx2 as httpx  # the HTTP library openai 3.31.0 ships with
from openai import BadRequestError


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


def _bad_request(message: str, param: str | None) -> BadRequestError:
    """Build a real BadRequestError the way the SDK would, so .message/.param are set."""
    request = httpx.Request("POST", "https://api.openai.com/v1/agents/sessions")
    body = {"error": {"message": message, "param": param, "type": "invalid_request_error"}}
    response = httpx.Response(400, request=request, json=body)
    return BadRequestError(message, response=response, body=body["error"])


class _SessionsRecorder:
    """Records each sessions.create call and can fail the first with a chosen 400."""

    def __init__(self, first_error: BadRequestError | None = None):
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


# --- the predicate, both ways ------------------------------------------------
def test_predicate_matches_spend_control_not_enabled_by_param():
    exc = _bad_request("Session budget configuration is not enabled", param="spend_control")
    assert submit._is_spend_control_unsupported(exc) is True


def test_predicate_matches_spend_control_not_enabled_by_message_text():
    exc = _bad_request("spend_control is not enabled for this project", param=None)
    assert submit._is_spend_control_unsupported(exc) is True


def test_predicate_does_not_match_an_unrelated_400():
    exc = _bad_request("model is required", param="model")
    assert submit._is_spend_control_unsupported(exc) is False


# --- create_session fallback, both ways --------------------------------------
def test_spend_control_400_is_tolerated_and_retried_without_it(capsys):
    err = _bad_request("Session budget configuration is not enabled", param="spend_control")
    sessions = _SessionsRecorder(first_error=err)
    client = _Client(sessions)

    submit.create_session(client, "agent_1", {"limit": 100})

    assert len(sessions.calls) == 2, "should retry exactly once"
    assert "spend_control" in sessions.calls[0], "first attempt asks for the budget"
    assert "spend_control" not in sessions.calls[1], "retry drops the budget"
    assert "spend_control" in capsys.readouterr().out  # the reader is told why


def test_unrelated_400_is_not_swallowed():
    err = _bad_request("model is required", param="model")
    sessions = _SessionsRecorder(first_error=err)
    client = _Client(sessions)

    with pytest.raises(BadRequestError, match="model is required"):
        submit.create_session(client, "agent_1", {"limit": 100})
    assert len(sessions.calls) == 1, "an unrelated 400 is not retried"


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
