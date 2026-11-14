"""Tests for scripts/setup_agent.py keeping an AGENT_ID, with the OpenAI client faked.

A kept AGENT_ID is looked up before it is kept. Both ways, per AGENTS.md: an
agent the lookup returns is kept and nothing is created; a 404 stops with a
message that lists what to check before removing AGENT_ID, without claiming the
agent is gone; a lookup that fails for any other reason (network, auth, 5xx),
or succeeds without this agent's id, stops and is not read as "agent gone"; and
a failure is named by its SDK exception class and, when it has one, its HTTP
status, printing neither the response body nor the request-id header, either of which a proxy can fill with a secret.
In every stopping case no agent is created.

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


def test_a_404_lists_what_to_check_before_saying_to_remove_agent_id(run):
    client = _client(_status_error(openai.NotFoundError, 404))

    with pytest.raises(SystemExit) as stopped:
        run(client)

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


def _everything_printed(stopped, capsys) -> str:
    """The exit message plus all of stdout and stderr, so a leak anywhere is seen."""
    captured = capsys.readouterr()
    return "\n".join([str(stopped.value.code), captured.out, captured.err])


def test_a_failed_lookup_never_prints_the_response_body(run, capsys):
    secret = "sk-proj-SECRET-ECHOED-BY-A-PROXY"
    failure = openai.AuthenticationError(
        f"Error code: 401 - {{'error': 'bad key {secret}'}}",
        response=httpx.Response(401, request=_REQUEST),
        body={"error": f"bad key {secret}"},
    )
    assert secret in str(failure)  # the SDK's own message carries the body

    client = _client(failure)
    with pytest.raises(SystemExit) as stopped:
        run(client)

    assert secret not in _everything_printed(stopped, capsys)
    assert str(stopped.value.code).endswith("(AuthenticationError, HTTP 401).")


def test_a_failed_lookup_never_prints_the_request_id_header(run, capsys):
    # The SDK takes request_id straight from the x-request-id response header,
    # which a proxy behind OPENAI_BASE_URL controls.
    secret = "sk-proj-SECRET-IN-A-HEADER"
    failure = openai.InternalServerError(
        "error",
        response=httpx.Response(500, request=_REQUEST, headers={"x-request-id": secret}),
        body=None,
    )
    assert failure.request_id == secret

    client = _client(failure)
    with pytest.raises(SystemExit) as stopped:
        run(client)

    assert secret not in _everything_printed(stopped, capsys)
    message = str(stopped.value.code)
    assert message.endswith("(InternalServerError, HTTP 500).")


def test_without_agent_id_an_agent_is_created_and_nothing_is_looked_up(monkeypatch, capsys):
    client = _client(AssertionError("retrieve must not be called"))
    monkeypatch.delenv("AGENT_ID", raising=False)
    monkeypatch.setattr(setup_agent, "make_client", lambda: client)

    setup_agent.main()

    client.beta.agents.retrieve.assert_not_called()
    client.beta.agents.create.assert_called_once()
    assert "AGENT_ID=agent_new" in capsys.readouterr().out
