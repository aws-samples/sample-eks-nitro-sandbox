"""Tests for the Dispatcher (sandbox.py), with the agent-sandbox client mocked.

The Dispatcher never calls live Kubernetes: these replace SandboxClient with a
fake and assert the behaviour the issue requires:

  * the environment key is delivered through SandboxClaim.spec.env (never over
    the pod network), by checking create_sandbox was called with env carrying
    CODEX_API_KEY and the session tuple;
  * a same-session follow-up reuses the existing claim instead of claiming again;
  * a claim whose pod lookup fails is terminated (rollback);
  * session-aware cleanup deletes the claim for a session;
  * the key value never appears in a log record.

Run with: python -m pytest
"""

from __future__ import annotations

import logging

import pytest

from launcher import config, sandbox

SECRET_KEY = "sk-env-key-must-never-be-logged-123"
REMOTE = "https://codex-cloud-environments.chatgpt.com/e/env_1"


class _FakeSandbox:
    def __init__(self, name="openai-sandbox-executor-abcde", pod_ip="10.0.0.5", fail_pod=False):
        self._name = name
        self._pod_ip = pod_ip
        self._fail_pod = fail_pod
        self.terminated = False
        self.closed = False

    def get_pod_name(self):
        if self._fail_pod:
            raise RuntimeError("no pod")
        return self._name

    def get_pod_ip(self):
        return self._pod_ip

    def terminate(self):
        self.terminated = True

    def close_connection(self):
        self.closed = True


class _FakeK8s:
    def __init__(self):
        self.deleted: list[tuple[str, str]] = []

    def delete_sandbox_claim(self, name, namespace):
        self.deleted.append((name, namespace))


class _FakeClient:
    """Stands in for SandboxClient; records how create_sandbox was called."""

    def __init__(self, *, existing=None, fail_pod=False):
        self._existing = existing or []       # names claimed_sandbox_name returns
        self._fail_pod = fail_pod
        self.k8s_helper = _FakeK8s()
        self.created_env: dict | None = None
        self.created_labels: dict | None = None
        self.last_sandbox: _FakeSandbox | None = None

    def list_all_sandboxes(self, namespace, label_selector):
        return list(self._existing)

    def create_sandbox(self, *, warmpool, namespace, sandbox_ready_timeout, labels,
                        shutdown_after_seconds, env):
        self.created_env = env
        self.created_labels = labels
        self.last_sandbox = _FakeSandbox(fail_pod=self._fail_pod)
        return self.last_sandbox

    def list_active_sandboxes(self):
        pass


@pytest.fixture
def patch_client(monkeypatch):
    """Patch SandboxClient so Dispatcher.__init__ builds a fake we control."""
    holder = {}

    def _install(**kwargs):
        fake = _FakeClient(**kwargs)

        def _factory(*_a, **_k):
            return fake

        monkeypatch.setattr(sandbox, "SandboxClient", _factory)
        holder["client"] = fake
        return fake

    return _install


def _dispatcher():
    return sandbox.Dispatcher(SECRET_KEY)


def test_key_delivered_through_claim_env_not_the_network(patch_client):
    client = patch_client()
    result = _dispatcher().dispatch(session_id="sesn_a", environment_id="env_a", remote_url=REMOTE)
    assert result["reused"] is False
    # The key and the whole session tuple went into the claim env.
    assert client.created_env[config.ENV_CODEX_API_KEY] == SECRET_KEY
    assert client.created_env[config.ENV_SESSION_ID] == "sesn_a"
    assert client.created_env[config.ENV_ENVIRONMENT_ID] == "env_a"
    assert client.created_env[config.ENV_REMOTE_URL] == REMOTE
    # The claim is labelled with the session so a follow-up can find it.
    assert client.created_labels[sandbox.SESSION_ID_LABEL] == sandbox.label_safe("sesn_a")


def test_follow_up_reuses_the_existing_claim(patch_client):
    client = patch_client(existing=["openai-sandbox-executor-live"])
    result = _dispatcher().dispatch(session_id="sesn_a", environment_id="env_a", remote_url=REMOTE)
    assert result == {"sandbox": "openai-sandbox-executor-live", "reused": True}
    # No new claim was created for the follow-up.
    assert client.created_env is None


def test_failed_pod_lookup_rolls_back_the_claim(patch_client):
    client = patch_client(fail_pod=True)
    with pytest.raises(RuntimeError):
        _dispatcher().dispatch(session_id="sesn_a", environment_id="env_a", remote_url=REMOTE)
    assert client.last_sandbox.terminated is True
    assert client.last_sandbox.closed is True


def test_delete_claim_for_session(patch_client):
    client = patch_client(existing=["claim-1", "claim-2"])
    deleted = _dispatcher().delete_claim_for_session("sesn_a")
    assert deleted == 2
    assert client.k8s_helper.deleted == [("claim-1", "default"), ("claim-2", "default")]


def test_delete_claim_for_session_none(patch_client):
    patch_client(existing=[])
    assert _dispatcher().delete_claim_for_session("sesn_a") == 0


def test_key_value_never_logged(patch_client, caplog):
    patch_client()
    with caplog.at_level(logging.DEBUG, logger="launcher.sandbox"):
        _dispatcher().dispatch(session_id="sesn_a", environment_id="env_a", remote_url=REMOTE)
    assert SECRET_KEY not in caplog.text
