"""Tests for scripts/setup_agent.py keeping an AGENT_ID, with the OpenAI client faked.

A kept AGENT_ID is looked up before it is kept. Both ways, per AGENTS.md: an
agent the lookup returns is kept and nothing is created; a 404 stops with a
message that lists what to check before removing AGENT_ID, without claiming the
agent is gone; a lookup that fails for any other reason (network, auth, 5xx),
or succeeds without this agent's id, stops and is not read as "agent gone"; and
a failure is named by its SDK exception class and, when it has one, its HTTP
status, printing neither the response body nor the request-id header, either of
which a proxy can fill with a key. A stopping path emits nothing besides its
exit message: no stdout, stderr, file-descriptor write, log record or warning.
In every stopping case no agent is created.

Run with: python -m pytest
"""

from __future__ import annotations

import importlib.util
import logging
import pathlib
import sys
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

openai = pytest.importorskip("openai")
httpx = pytest.importorskip("httpx2")


def _load_setup_agent():
    scripts_dir = pathlib.Path(__file__).resolve().parent.parent / "scripts"
    sys.path.insert(0, str(scripts_dir))  # so setup_agent.py's `from _client import ...` resolves
    try:
        spec = importlib.util.spec_from_file_location("setup_agent_under_test", scripts_dir / "setup_agent.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.path.remove(str(scripts_dir))


setup_agent = _load_setup_agent()

_REQUEST = httpx.Request("GET", "https://api.openai.example/v1/agents/agent_kept")


def _status_error(cls, status):
    return cls("error", response=httpx.Response(status, request=_REQUEST), body=None)


def _client(retrieve):
    client = MagicMock()
    client.beta.agents.retrieve.side_effect = retrieve
    client.beta.agents.create.return_value = SimpleNamespace(id="agent_new")
    return client


@pytest.fixture
def run(monkeypatch):
    def _run(client):
        monkeypatch.setenv("AGENT_ID", "agent_kept")
        monkeypatch.delenv("AGENT_MODEL", raising=False)
        monkeypatch.setattr(setup_agent, "make_client", lambda: client)
        setup_agent.main()

    return _run


def test_an_existing_agent_is_kept(run, capsys):
    client = _client(lambda agent_id: SimpleNamespace(id=agent_id))

    run(client)

    client.beta.agents.retrieve.assert_called_once_with("agent_kept")
    client.beta.agents.create.assert_not_called()
    assert "AGENT_ID=agent_kept" in capsys.readouterr().out


@pytest.fixture
def side_output(capfd, caplog, recwarn):
    """Everything a stopping run emitted besides its exit message.

    capfd sees writes to file descriptors 1 and 2 as well as sys.stdout and
    sys.stderr; caplog and recwarn see logging and warnings, which pytest would
    otherwise capture separately. A stopping path emits nothing but its exit
    message, so each test asserts this is empty.
    """
    caplog.set_level(logging.DEBUG)

    def _collect() -> str:
        captured = capfd.readouterr()
        return "".join(
            [captured.out, captured.err]
            + [record.getMessage() for record in caplog.records]
            + [str(warning.message) for warning in recwarn]
        )

    return _collect


def test_a_404_lists_what_to_check_before_saying_to_remove_agent_id(run, side_output):
    client = _client(_status_error(openai.NotFoundError, 404))

    with pytest.raises(SystemExit) as stopped:
        run(client)

    assert side_output() == ""
    # The whole message, owned by the test, so an added or changed claim (such as
    # that the agent was deleted, which a 404 does not show) fails here.
    assert str(stopped.value.code) == (
        "The lookup of agent agent_kept from AGENT_ID returned HTTP 404, so it was not kept.\n"
        "A 404 does not show that the agent was deleted. The same answer comes from a mistyped\n"
        "AGENT_ID, from OPENAI_API_KEY, OPENAI_PROJECT_ID or OPENAI_ORG_ID selecting a different\n"
        "project or organization from the one the agent was created in, or from OPENAI_BASE_URL\n"
        "pointing somewhere else. Check those first.\n"
        "Only once you have confirmed the agent is gone, for example in the OpenAI dashboard of the\n"
        "project it was created in, remove AGENT_ID from .env (or unset it in this shell) and run\n"
        "this step again to create a new agent."
    )
    client.beta.agents.create.assert_not_called()


@pytest.mark.parametrize(
    ("failure", "described"),
    [
        (openai.APIConnectionError(request=_REQUEST), "APIConnectionError"),
        (_status_error(openai.AuthenticationError, 401), "AuthenticationError, HTTP 401"),
        (_status_error(openai.PermissionDeniedError, 403), "PermissionDeniedError, HTTP 403"),
        (_status_error(openai.InternalServerError, 500), "InternalServerError, HTTP 500"),
    ],
    ids=["network", "401", "403", "500"],
)
def test_a_failed_lookup_stops_and_is_not_read_as_gone(run, side_output, failure, described):
    client = _client(failure)

    with pytest.raises(SystemExit) as stopped:
        run(client)

    assert side_output() == ""
    # A network error has no HTTP status, so it is named by its class alone.
    assert str(stopped.value.code) == (
        f"Could not confirm that agent agent_kept exists, so it was not kept ({described})."
    )
    client.beta.agents.create.assert_not_called()


@pytest.mark.parametrize(
    "returned",
    [SimpleNamespace(), SimpleNamespace(id=None), SimpleNamespace(id="agent_other")],
    ids=["no-id-attribute", "id-none", "different-id"],
)
def test_a_successful_lookup_without_this_agents_id_is_not_kept(run, capsys, returned):
    client = _client(lambda agent_id: returned)

    with pytest.raises(SystemExit) as stopped:
        run(client)

    message = str(stopped.value.code)
    assert message.startswith("Could not confirm that agent agent_kept exists")
    assert "remove AGENT_ID" not in message
    assert "keeping agent" not in capsys.readouterr().out
    client.beta.agents.create.assert_not_called()


# Planted where a proxy behind OPENAI_BASE_URL could put a key: the response body
# and the x-request-id header, which the SDK exposes as exc.request_id.
_IN_BODY = "planted-value-in-the-response-body"
_IN_HEADER = "planted-value-in-the-request-id-header"


def _planted_error(cls, status):
    error = cls(
        f"Error code: {status} - {{'error': '{_IN_BODY}'}}",
        response=httpx.Response(status, request=_REQUEST, headers={"x-request-id": _IN_HEADER}),
        body={"error": _IN_BODY},
    )
    # The premise of these tests: the SDK's own error carries both values.
    assert _IN_BODY in str(error)
    assert error.request_id == _IN_HEADER
    return error


@pytest.mark.parametrize(
    ("cls", "status", "message_start"),
    [
        (openai.NotFoundError, 404, "The lookup of agent agent_kept from AGENT_ID returned HTTP 404"),
        (openai.AuthenticationError, 401, "Could not confirm that agent agent_kept exists"),
        (openai.InternalServerError, 500, "Could not confirm that agent agent_kept exists"),
    ],
    ids=["404", "401", "500"],
)
def test_a_failed_lookup_prints_neither_the_body_nor_the_request_id(
    run, side_output, cls, status, message_start
):
    client = _client(_planted_error(cls, status))

    with pytest.raises(SystemExit) as stopped:
        run(client)

    message = str(stopped.value.code)
    assert message.startswith(message_start)
    emitted = message + side_output()
    assert _IN_BODY not in emitted
    assert _IN_HEADER not in emitted


def test_without_agent_id_an_agent_is_created_and_nothing_is_looked_up(monkeypatch, capsys):
    client = _client(AssertionError("retrieve must not be called"))
    monkeypatch.delenv("AGENT_ID", raising=False)
    monkeypatch.setattr(setup_agent, "make_client", lambda: client)

    setup_agent.main()

    client.beta.agents.retrieve.assert_not_called()
    client.beta.agents.create.assert_called_once()
    assert "AGENT_ID=agent_new" in capsys.readouterr().out
