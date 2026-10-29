"""Pinned-SDK contract tests: the calls the sample makes exist on the pinned SDKs.

These do NOT make a live call. They assert that the exact methods and keyword
surface the sample depends on are present on openai 3.31.0 and
k8s-agent-sandbox 1.0.6, and that a mocked client is driven the way the scripts
drive it. A pin bump that moved any of these would fail here instead of at the
operator's first live run.

Run with: python -m pytest
"""

from __future__ import annotations

import inspect
from unittest.mock import MagicMock

import pytest

openai = pytest.importorskip("openai")
k8s_mod = pytest.importorskip("k8s_agent_sandbox")


def test_openai_version_is_pinned():
    assert openai.__version__ == "3.31.0"


def test_empty_base_url_is_treated_as_unset(monkeypatch):
    """A sourced .env may export a blank optional URL; that must use the SDK default."""
    import importlib.util
    import pathlib

    client_path = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "_client.py"
    spec = importlib.util.spec_from_file_location("client_under_test", client_path)
    client_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(client_module)

    constructor = MagicMock(return_value=object())
    monkeypatch.setattr(client_module, "OpenAI", constructor)
    monkeypatch.setenv("OPENAI_API_KEY", "sk-not-used-in-this-test")
    monkeypatch.setenv("OPENAI_BASE_URL", "")

    client_module.make_client()

    constructor.assert_called_once_with()
    assert "OPENAI_BASE_URL" not in client_module.os.environ


def test_agents_sessions_surface_exists():
    # Build a client without a network call (dummy key), then walk the attribute
    # chain the sample uses. Accessing these resource namespaces does not call out.
    client = openai.OpenAI(api_key="sk-not-used-in-this-test")
    agents = client.beta.agents
    for name in ("create",):
        assert hasattr(agents, name), f"client.beta.agents.{name} missing"
    sessions = agents.sessions
    for name in ("create", "retrieve", "stream", "delete"):
        assert hasattr(sessions, name), f"client.beta.agents.sessions.{name} missing"


def test_create_sandbox_accepts_env_kwarg():
    # The off-the-wire key delivery depends on create_sandbox(env=...).
    sig = inspect.signature(k8s_mod.SandboxClient.create_sandbox)
    assert "env" in sig.parameters, "create_sandbox must accept env= for claim-env key delivery"
    assert "shutdown_after_seconds" in sig.parameters
    assert "labels" in sig.parameters


def test_sdk_version_pin_declared():
    # The pin is declared in pyproject; k8s-agent-sandbox exposes no __version__,
    # so assert the client class is importable from the pinned package.
    assert hasattr(k8s_mod, "SandboxClient")


def test_submit_stream_turn_consumes_pinned_events():
    """stream_turn drives client.beta.agents.sessions.stream and reads event.type."""
    import importlib.util
    import pathlib
    import sys

    scripts_dir = pathlib.Path(__file__).resolve().parent.parent / "scripts"
    submit_path = scripts_dir / "submit.py"
    sys.path.insert(0, str(scripts_dir))  # so submit.py's `from _client import ...` resolves
    try:
        spec = importlib.util.spec_from_file_location("submit_under_test", submit_path)
        submit = importlib.util.module_from_spec(spec)
        # scripts/_client.py imports openai; it is importable, so loading submit is safe.
        spec.loader.exec_module(submit)
    finally:
        sys.path.remove(str(scripts_dir))

    # A fake streaming context yielding one text-delta event and one failure event.
    delta = MagicMock(type="agent.session.turn.output_text.delta", delta="hello")
    err = MagicMock(type="agent.session.turn.failed")
    err.turn.error.message = "boom"

    class _Stream:
        def __enter__(self):
            return [delta, err]

        def __exit__(self, *a):
            return False

    client = MagicMock()
    client.beta.agents.sessions.stream.return_value = _Stream()

    errors = submit.stream_turn(client, "sesn_a", "do a thing")
    client.beta.agents.sessions.stream.assert_called_once_with("sesn_a", input="do a thing")
    assert errors == 1  # the one turn.failed event counted
