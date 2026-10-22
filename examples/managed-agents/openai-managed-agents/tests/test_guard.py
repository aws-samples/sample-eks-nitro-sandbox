"""Tests for the credential boundary (guard.py) and the dispatch validators.

These assert the issue #9 key-separation rules by variable NAME, never by value:

  * the application key (OPENAI_API_KEY) is refused in every pod;
  * a warm sandbox holds neither key and no session;
  * a claimed sandbox holds the whole session tuple AND CODEX_API_KEY (injected
    by the controller from the claim env), and a partial dispatch is refused;
  * the launcher needs the environment key and refuses the application key.

Run with: python -m pytest  (from this sample's folder, with the package
installed: pip install .)
"""

from __future__ import annotations

import pytest

from launcher import config, guard
from launcher.sandbox import label_safe
from launcher.serve import ID_RE, URL_RE

# Every OpenAI/Codex and session variable the guard reasons about. Clearing them
# before each test keeps a stray value in the real environment from leaking in.
_VARS = [
    config.ENV_API_KEY,
    config.ENV_EXECUTOR_API_KEY,
    config.ENV_CODEX_API_KEY,
    config.ENV_BASE_URL,
    config.ENV_SESSION_ID,
    config.ENV_ENVIRONMENT_ID,
    config.ENV_REMOTE_URL,
    "OPENAI_ORG_ID",
    "OPENAI_ORGANIZATION",
]

_REMOTE = "https://codex-cloud-environments.chatgpt.com/e/env_1"


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for name in _VARS:
        monkeypatch.delenv(name, raising=False)


def _claim_env(monkeypatch, *, key=True, session=True, env=True, remote=True):
    """Set a claimed-pod environment, optionally dropping fields to test partials."""
    if key:
        monkeypatch.setenv(config.ENV_CODEX_API_KEY, "env-key-value")
    if session:
        monkeypatch.setenv(config.ENV_SESSION_ID, "sesn_abc123")
    if env:
        monkeypatch.setenv(config.ENV_ENVIRONMENT_ID, "env_abc123")
    if remote:
        monkeypatch.setenv(config.ENV_REMOTE_URL, _REMOTE)


# --- the application key is refused everywhere -------------------------------
@pytest.mark.parametrize("role", [guard.ROLE_LAUNCH, guard.ROLE_SERVE])
def test_application_key_refused_in_every_pod(role, monkeypatch):
    monkeypatch.setenv(config.ENV_API_KEY, "x")
    if role == guard.ROLE_LAUNCH:
        monkeypatch.setenv(config.ENV_EXECUTOR_API_KEY, "y")
        monkeypatch.setenv(config.ENV_LAUNCHER_AUTH_TOKEN, "t")
    with pytest.raises(RuntimeError, match=config.ENV_API_KEY):
        guard.assert_safe(role)


# --- the warm sandbox holds neither key nor a session ------------------------
def test_serve_warm_pod_ok_with_nothing_set():
    guard.assert_safe(guard.ROLE_SERVE)  # a warm pod: nothing set
    assert guard.dispatched() is False


@pytest.mark.parametrize("var", ["OPENAI_ORG_ID", "OPENAI_ORGANIZATION", config.ENV_API_KEY])
def test_serve_warm_pod_refuses_foreign_credentials(var, monkeypatch):
    monkeypatch.setenv(var, "x")
    with pytest.raises(RuntimeError, match=var):
        guard.assert_safe(guard.ROLE_SERVE)


# --- the claimed sandbox holds the whole tuple + key -------------------------
def test_serve_claimed_pod_ok_with_full_dispatch(monkeypatch):
    _claim_env(monkeypatch)
    guard.assert_safe(guard.ROLE_SERVE)
    assert guard.dispatched() is True


def test_serve_claimed_pod_refuses_missing_key(monkeypatch):
    _claim_env(monkeypatch, key=False)
    with pytest.raises(RuntimeError, match=config.ENV_CODEX_API_KEY):
        guard.assert_safe(guard.ROLE_SERVE)


@pytest.mark.parametrize("drop", ["session", "env", "remote"])
def test_serve_claimed_pod_refuses_partial_tuple(drop, monkeypatch):
    _claim_env(monkeypatch, **{drop: False})
    with pytest.raises(RuntimeError, match="partial dispatch"):
        guard.assert_safe(guard.ROLE_SERVE)


def test_serve_claimed_pod_still_refuses_application_key(monkeypatch):
    _claim_env(monkeypatch)
    monkeypatch.setenv(config.ENV_API_KEY, "x")
    with pytest.raises(RuntimeError, match=config.ENV_API_KEY):
        guard.assert_safe(guard.ROLE_SERVE)


# --- the launcher holds the environment key, never the application key -------
def test_launch_ok_with_environment_key_and_token(monkeypatch):
    monkeypatch.setenv(config.ENV_EXECUTOR_API_KEY, "env-key")
    guard.assert_safe(guard.ROLE_LAUNCH)


def test_launch_requires_environment_key():
    with pytest.raises(RuntimeError, match=config.ENV_EXECUTOR_API_KEY):
        guard.assert_safe(guard.ROLE_LAUNCH)


def test_launch_refuses_codex_api_key(monkeypatch):
    # The launcher never runs codex itself, so CODEX_API_KEY in its own env is wrong.
    monkeypatch.setenv(config.ENV_EXECUTOR_API_KEY, "env-key")
    monkeypatch.setenv(config.ENV_CODEX_API_KEY, "x")
    with pytest.raises(RuntimeError, match=config.ENV_CODEX_API_KEY):
        guard.assert_safe(guard.ROLE_LAUNCH)


def test_base_url_is_allowed_not_a_credential(monkeypatch):
    monkeypatch.setenv(config.ENV_EXECUTOR_API_KEY, "env-key")
    monkeypatch.setenv(config.ENV_BASE_URL, "https://api.openai.com/v1")
    guard.assert_safe(guard.ROLE_LAUNCH)


def test_unknown_role_rejected():
    with pytest.raises(ValueError, match="unknown role"):
        guard.assert_safe("nope")


# --- the guard reads names, never values -------------------------------------
def test_guard_never_reports_a_value(monkeypatch):
    secret = "sk-super-secret-value-should-never-appear"
    monkeypatch.setenv(config.ENV_API_KEY, secret)
    with pytest.raises(RuntimeError) as exc:
        guard.assert_safe(guard.ROLE_SERVE)
    assert secret not in str(exc.value)


def test_guard_partial_dispatch_never_reports_key_value(monkeypatch):
    secret = "sk-env-key-should-never-appear"
    _claim_env(monkeypatch, session=False)
    monkeypatch.setenv(config.ENV_CODEX_API_KEY, secret)
    with pytest.raises(RuntimeError) as exc:
        guard.assert_safe(guard.ROLE_SERVE)
    assert secret not in str(exc.value)


# --- dispatch field validators ------------------------------------------------
def test_id_re_accepts_openai_ids():
    assert ID_RE.match("sesn_abc123")
    assert ID_RE.match("env_XYZ-789")
    assert not ID_RE.match("bad id with spaces")
    assert not ID_RE.match("")


def test_url_re_requires_https():
    assert URL_RE.match("https://codex-cloud-environments.chatgpt.com/e/env_1")
    assert not URL_RE.match("http://insecure.example.com")
    assert not URL_RE.match("ftp://example.com")


def test_label_safe_is_a_valid_k8s_label():
    out = label_safe("sesn_AbC-123")
    assert out == "sesn-abc-123"
    assert len(out) <= 63
    # a value with no usable characters falls back to a stable hash
    assert label_safe("@@@")
