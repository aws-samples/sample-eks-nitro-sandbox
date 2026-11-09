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

import pathlib
import re

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
    config.ENV_LAUNCHER_AUTH_TOKEN,
    config.ENV_BASE_URL,
    config.ENV_SESSION_ID,
    config.ENV_ENVIRONMENT_ID,
    config.ENV_REMOTE_URL,
    "OPENAI_ORG_ID",
    "OPENAI_ORGANIZATION",
]

_REMOTE = "https://codex-cloud-environments.chatgpt.com/e/env_1"
_LAUNCHER_FILES = (config.ENV_EXECUTOR_API_KEY, config.ENV_LAUNCHER_AUTH_TOKEN)


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch, tmp_path):
    for name in _VARS:
        monkeypatch.delenv(name, raising=False)
    # The credentials directory starts absent, as on a sandbox pod.
    monkeypatch.setattr(config, "LAUNCHER_CREDENTIALS_DIR", str(tmp_path / "credentials"))


def _mount(*names, value="mounted-value"):
    """Create files in the credentials directory, as the projected volume does."""
    directory = pathlib.Path(config.LAUNCHER_CREDENTIALS_DIR)
    directory.mkdir(exist_ok=True)
    for name in names:
        (directory / name).write_text(value)
    return directory


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
        _mount(*_LAUNCHER_FILES)
    with pytest.raises(RuntimeError, match=config.ENV_API_KEY):
        guard.assert_safe(role)


@pytest.mark.parametrize("role", [guard.ROLE_LAUNCH, guard.ROLE_SERVE])
def test_application_key_file_refused_in_every_pod(role):
    # The same rule for a file in the credentials directory: a Secret holding the
    # application key mounted there is refused, by its file name.
    if role == guard.ROLE_LAUNCH:
        _mount(*_LAUNCHER_FILES)
    _mount(config.ENV_API_KEY)
    with pytest.raises(RuntimeError, match=f"{config.ENV_API_KEY} is mounted"):
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
def test_launch_ok_with_environment_key_and_token_files():
    _mount(*_LAUNCHER_FILES)
    guard.assert_safe(guard.ROLE_LAUNCH)


def test_launch_requires_environment_key():
    with pytest.raises(RuntimeError, match=config.ENV_EXECUTOR_API_KEY):
        guard.assert_safe(guard.ROLE_LAUNCH)


def test_launch_requires_environment_key_file_not_only_the_token():
    _mount(config.ENV_LAUNCHER_AUTH_TOKEN)
    with pytest.raises(RuntimeError, match=f"{config.ENV_EXECUTOR_API_KEY} is missing"):
        guard.assert_safe(guard.ROLE_LAUNCH)


@pytest.mark.parametrize("name", _LAUNCHER_FILES)
def test_launch_refuses_its_credentials_in_the_environment(name, monkeypatch):
    # Both are files now; an env entry left in the manifest would put a value
    # back in the launcher's environment, so the launcher refuses to start.
    _mount(*_LAUNCHER_FILES)
    monkeypatch.setenv(name, "x")
    with pytest.raises(RuntimeError, match=f"{name} set in the launcher's environment"):
        guard.assert_safe(guard.ROLE_LAUNCH)


@pytest.mark.parametrize("name", ["OPENAI_ORG_ID", config.ENV_CODEX_API_KEY, "other"])
def test_launch_refuses_any_other_file_in_the_credentials_directory(name):
    _mount(*_LAUNCHER_FILES, name)
    with pytest.raises(RuntimeError, match=f"unexpected files in .*: {name};"):
        guard.assert_safe(guard.ROLE_LAUNCH)


def test_launch_skips_the_kubelet_atomic_writer_entries():
    # A projected volume holds ..data and a timestamped .. directory beside the
    # key files; they are not credentials and must not stop the launcher.
    directory = _mount(*_LAUNCHER_FILES)
    (directory / "..2026_11_09_21_00_00.000000000").mkdir()
    (directory / "..data").symlink_to("..2026_11_09_21_00_00.000000000")
    (directory / "..data_tmp").symlink_to("..2026_11_09_21_00_00.000000000")
    guard.assert_safe(guard.ROLE_LAUNCH)


@pytest.mark.parametrize("make", [
    "file:..creds",                              # any other ..name
    "file:..data",                               # the writer's name, but a plain file
    "file:..2026_11_09_21_00_00.123",            # a timestamp name, but a file
    "symlink:..2026_11_09_21_00_00.123",         # a timestamp name, but a symlink
    "dir:..2026_11_09_21_00_00",                 # no digits after the seconds
])
def test_launch_refuses_a_dotdot_entry_the_kubelet_does_not_write(make):
    kind, name = make.split(":", 1)
    directory = _mount(*_LAUNCHER_FILES)
    path = directory / name
    if kind == "file":
        path.write_text("x")
    elif kind == "symlink":
        path.symlink_to(config.ENV_EXECUTOR_API_KEY)
    else:
        path.mkdir()
    with pytest.raises(RuntimeError, match=re.escape(f": {name};")):
        guard.assert_safe(guard.ROLE_LAUNCH)


def test_serve_refuses_a_dotdot_file_on_a_sandbox():
    _mount("..creds")
    with pytest.raises(RuntimeError, match="credential files in .* on a sandbox: \\.\\.creds;"):
        guard.assert_safe(guard.ROLE_SERVE)


def test_launch_refuses_codex_api_key(monkeypatch):
    # The launcher never runs codex itself, so CODEX_API_KEY in its own env is wrong.
    _mount(*_LAUNCHER_FILES)
    monkeypatch.setenv(config.ENV_CODEX_API_KEY, "x")
    with pytest.raises(RuntimeError, match=config.ENV_CODEX_API_KEY):
        guard.assert_safe(guard.ROLE_LAUNCH)


def test_base_url_is_allowed_not_a_credential(monkeypatch):
    _mount(*_LAUNCHER_FILES)
    monkeypatch.setenv(config.ENV_BASE_URL, "https://api.openai.com/v1")
    guard.assert_safe(guard.ROLE_LAUNCH)


# --- a sandbox never holds a credential file ---------------------------------
@pytest.mark.parametrize("claimed", [False, True])
def test_serve_refuses_any_credential_file(claimed, monkeypatch):
    if claimed:
        _claim_env(monkeypatch)
    _mount(config.ENV_EXECUTOR_API_KEY)
    with pytest.raises(RuntimeError, match="credential files in .* on a sandbox"):
        guard.assert_safe(guard.ROLE_SERVE)


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


def test_guard_never_reports_a_mounted_file_value():
    planted = "sk-mounted-value-should-never-appear"
    _mount(config.ENV_API_KEY, value=planted)
    with pytest.raises(RuntimeError) as exc:
        guard.assert_safe(guard.ROLE_SERVE)
    assert planted not in str(exc.value)


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
