"""Tests for scripts/setup_agent.py keeping an AGENT_ID, with the OpenAI client faked.

A kept AGENT_ID is looked up before it is kept. Both ways, per AGENTS.md: an
agent the lookup returns is kept and nothing is created; a 404 stops with the
message to check the project and OPENAI_BASE_URL before removing AGENT_ID; a
lookup that fails for any other reason (network, auth, 5xx), or succeeds without
this agent's id, stops and is not read as "agent gone"; and a failure is named
by type, status and request id without printing the response body, which can
carry a secret. In every stopping case no agent is created.

Run with: python -m pytest
"""

from __future__ import annotations

import importlib.util
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


def test_a_missing_agent_stops_with_the_unset_message(run):
    client = _client(_status_error(openai.NotFoundError, 404))

    with pytest.raises(SystemExit) as stopped:
        run(client)

    message = str(stopped.value.code)
    assert "agent_kept" in message
    assert "not found (HTTP 404)" in message
    assert "OPENAI_BASE_URL" in message
    assert "remove AGENT_ID" in message
    client.beta.agents.create.assert_not_called()


@pytest.mark.parametrize(
    "failure",
    [
        openai.APIConnectionError(request=_REQUEST),
        _status_error(openai.AuthenticationError, 401),
        _status_error(openai.PermissionDeniedError, 403),
        _status_error(openai.InternalServerError, 500),
    ],
    ids=["network", "401", "403", "500"],
)
def test_a_failed_lookup_stops_and_is_not_read_as_gone(run, failure):
    client = _client(failure)

    with pytest.raises(SystemExit) as stopped:
        run(client)

    message = str(stopped.value.code)
    assert message.startswith("Could not confirm that agent agent_kept exists")
    assert "remove AGENT_ID" not in message
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


def test_a_failed_lookup_names_the_error_but_never_prints_its_body(run):
    secret = "sk-proj-SECRET-ECHOED-BY-A-PROXY"
    failure = openai.AuthenticationError(
        f"Error code: 401 - {{'error': 'bad key {secret}'}}",
        response=httpx.Response(401, request=_REQUEST, headers={"x-request-id": "req_123"}),
        body={"error": f"bad key {secret}"},
    )
    assert secret in str(failure)  # the SDK's own message carries the body

    client = _client(failure)
    with pytest.raises(SystemExit) as stopped:
        run(client)

    message = str(stopped.value.code)
    assert secret not in message
    assert "AuthenticationError, HTTP 401, request id req_123" in message


def test_without_agent_id_an_agent_is_created_and_nothing_is_looked_up(monkeypatch, capsys):
    client = _client(AssertionError("retrieve must not be called"))
    monkeypatch.delenv("AGENT_ID", raising=False)
    monkeypatch.setattr(setup_agent, "make_client", lambda: client)

    setup_agent.main()

    client.beta.agents.retrieve.assert_not_called()
    client.beta.agents.create.assert_called_once()
    assert "AGENT_ID=agent_new" in capsys.readouterr().out
