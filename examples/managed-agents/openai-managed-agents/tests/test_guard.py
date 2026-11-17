"""Tests for the credential boundary (guard.py) and the dispatch validators.

These assert the role rules by variable NAME, and the sandbox's path rule by one
lstat, never by value:

  * the launcher refuses OPENAI_API_KEY, OPENAI_EXECUTOR_API_KEY,
    LAUNCHER_AUTH_TOKEN and CODEX_API_KEY in its environment, whatever the value,
    an empty or blank one included;
  * every sandbox, warm or claimed, refuses OPENAI_API_KEY,
    OPENAI_EXECUTOR_API_KEY and LAUNCHER_AUTH_TOKEN the same way, and refuses
    anything at the launcher's credentials path;
  * of the 256 states of the four claim names (each absent, empty, blank or
    valid), only all absent (a warm pod) and all valid (a claimed pod) start.

The launcher reads its two credentials from their files in config.py;
tests/test_launcher.py covers that read. The projected volume's shape is the
manifest's, and tests/test_manifests.py covers it.

Run with: python -m pytest  (from this sample's folder, with the package
installed: pip install .)
"""

from __future__ import annotations

import errno
import itertools
import os
import pathlib
from types import SimpleNamespace

import pytest

from launcher import config, guard
from launcher.sandbox import label_safe
from launcher.serve import ID_RE, URL_RE

_REMOTE = "https://codex-cloud-environments.chatgpt.com/e/env_1"

_LAUNCH_FORBIDDEN = (
    config.ENV_API_KEY,
    config.ENV_EXECUTOR_API_KEY,
    config.ENV_LAUNCHER_AUTH_TOKEN,
    config.ENV_CODEX_API_KEY,
)
_SERVE_FORBIDDEN = (config.ENV_API_KEY, config.ENV_EXECUTOR_API_KEY, config.ENV_LAUNCHER_AUTH_TOKEN)

# The claim names, in guard order, with a value of the right form for each.
_CLAIM_VALUES = {
    config.ENV_CODEX_API_KEY: "env-key-value",
    config.ENV_SESSION_ID: "sesn_abc123",
    config.ENV_ENVIRONMENT_ID: "env_abc123",
    config.ENV_REMOTE_URL: _REMOTE,
}
_CLAIM = tuple(_CLAIM_VALUES)

# Present values that are not usable: present all the same.
_PRESENT = {"empty": "", "blank": " \t\n", "set": "a-value"}

# Every name the guard reasons about, and the ones it deliberately does not.
# Clearing them before each test keeps a stray value in the real environment out.
_VARS = [*_LAUNCH_FORBIDDEN, *_CLAIM, config.ENV_BASE_URL, "OPENAI_ORG_ID", "OPENAI_ORGANIZATION"]


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch, tmp_path):
    for name in _VARS:
        monkeypatch.delenv(name, raising=False)
    # The credentials path starts absent, as on a sandbox pod.
    monkeypatch.setattr(config, "LAUNCHER_CREDENTIALS_DIR", str(tmp_path / "credentials"))


def _claim_env(monkeypatch):
    for name, value in _CLAIM_VALUES.items():
        monkeypatch.setenv(name, value)


def _refusal(role: str) -> str:
    with pytest.raises(RuntimeError) as exc:
        guard.assert_safe(role)
    return str(exc.value)


def _forbidden_message(names, role: str) -> str:
    return f"{', '.join(names)} set in this {role} pod's environment; refusing to start."


# --- the launcher: nothing credential-shaped in its environment ---------------
@pytest.mark.parametrize("value", list(_PRESENT))
@pytest.mark.parametrize("role", ["launch", "serve-warm", "serve-claimed"])
def test_application_key_refused_in_every_pod(role, value, monkeypatch):
    if role == "serve-claimed":
        _claim_env(monkeypatch)
    monkeypatch.setenv(config.ENV_API_KEY, _PRESENT[value])
    role = guard.ROLE_LAUNCH if role == "launch" else guard.ROLE_SERVE
    assert _refusal(role).startswith(_forbidden_message([config.ENV_API_KEY], role))


def test_launch_starts_with_none_of_its_forbidden_names():
    guard.assert_safe(guard.ROLE_LAUNCH)


@pytest.mark.parametrize("value", list(_PRESENT))
@pytest.mark.parametrize("name", _LAUNCH_FORBIDDEN)
def test_launch_refuses_each_forbidden_name_whatever_its_value(name, value, monkeypatch):
    # Presence, not truthiness: an empty or blank value is refused too.
    monkeypatch.setenv(name, _PRESENT[value])
    assert _refusal(guard.ROLE_LAUNCH).startswith(_forbidden_message([name], guard.ROLE_LAUNCH))


def test_launch_names_every_forbidden_name_it_finds(monkeypatch):
    for name in _LAUNCH_FORBIDDEN:
        monkeypatch.setenv(name, "")
    assert _refusal(guard.ROLE_LAUNCH).startswith(_forbidden_message(_LAUNCH_FORBIDDEN, guard.ROLE_LAUNCH))


def test_launch_does_not_inspect_the_credentials_path(monkeypatch):
    # The launcher's guard is names only; the path is the two fixed reads' to open.
    monkeypatch.setattr(guard, "os", SimpleNamespace(environ=os.environ))
    guard.assert_safe(guard.ROLE_LAUNCH)


# --- every sandbox: never the application key or the launcher's credentials ---
@pytest.mark.parametrize("claimed", [False, True], ids=["warm", "claimed"])
@pytest.mark.parametrize("value", list(_PRESENT))
@pytest.mark.parametrize("name", _SERVE_FORBIDDEN)
def test_serve_refuses_each_forbidden_name_whatever_its_value(name, value, claimed, monkeypatch):
    if claimed:
        _claim_env(monkeypatch)
    monkeypatch.setenv(name, _PRESENT[value])
    assert _refusal(guard.ROLE_SERVE).startswith(_forbidden_message([name], guard.ROLE_SERVE))


def test_serve_refuses_a_forbidden_name_before_inspecting_the_path(monkeypatch):
    # Both are wrong; the name is reported, so the path check has not run yet.
    monkeypatch.setenv(config.ENV_API_KEY, "")
    pathlib.Path(config.LAUNCHER_CREDENTIALS_DIR).mkdir()
    assert _refusal(guard.ROLE_SERVE).startswith(_forbidden_message([config.ENV_API_KEY], guard.ROLE_SERVE))


# --- names that are not credentials are left alone, in both roles -------------
@pytest.mark.parametrize("role", ["launch", "serve-warm", "serve-claimed"])
def test_base_url_is_allowed_not_a_credential(role, monkeypatch):
    if role == "serve-claimed":
        _claim_env(monkeypatch)
    monkeypatch.setenv(config.ENV_BASE_URL, "https://api.openai.com/v1")
    guard.assert_safe(guard.ROLE_LAUNCH if role == "launch" else guard.ROLE_SERVE)


@pytest.mark.parametrize("name", ["OPENAI_ORG_ID", "OPENAI_ORGANIZATION"])
@pytest.mark.parametrize("role", ["launch", "serve-warm", "serve-claimed"])
def test_organization_ids_are_not_credentials(role, name, monkeypatch):
    # They select an organization in a request header; they authenticate nothing.
    if role == "serve-claimed":
        _claim_env(monkeypatch)
    monkeypatch.setenv(name, "org-x")
    guard.assert_safe(guard.ROLE_LAUNCH if role == "launch" else guard.ROLE_SERVE)


# --- a sandbox has nothing at the credentials path ----------------------------
def test_serve_warm_pod_ok_with_nothing_set():
    guard.assert_safe(guard.ROLE_SERVE)  # a warm pod: nothing set
    assert guard.dispatched() is False


@pytest.mark.parametrize("claimed", [False, True], ids=["warm", "claimed"])
def test_serve_accepts_an_absent_credentials_path(claimed, monkeypatch):
    if claimed:
        _claim_env(monkeypatch)
    guard.assert_safe(guard.ROLE_SERVE)
    assert guard.dispatched() is claimed


def _make(shape: str, path: pathlib.Path, scratch: pathlib.Path) -> None:
    if shape == "empty-directory":
        path.mkdir()
    elif shape == "directory":
        path.mkdir()
        (path / config.ENV_EXECUTOR_API_KEY).write_text("mounted-value")
    elif shape == "file":
        path.write_text("mounted-value")
    elif shape == "link-to-directory":
        (scratch / "target").mkdir()
        path.symlink_to(scratch / "target")
    elif shape == "dangling-link":
        path.symlink_to(scratch / "missing")
    else:
        assert shape == "fifo"
        os.mkfifo(path)


@pytest.mark.parametrize("claimed", [False, True], ids=["warm", "claimed"])
@pytest.mark.parametrize(
    "shape", ["empty-directory", "directory", "file", "link-to-directory", "dangling-link", "fifo"]
)
def test_serve_refuses_anything_at_the_credentials_path(shape, claimed, monkeypatch, tmp_path):
    # Only "absent" passes. A dangling link is refused too, so the check does not
    # follow it, and an empty directory is refused, so it does not list it.
    if claimed:
        _claim_env(monkeypatch)
    path = pathlib.Path(config.LAUNCHER_CREDENTIALS_DIR)
    _make(shape, path, tmp_path)
    assert _refusal(guard.ROLE_SERVE).startswith(f"{path} exists on this sandbox; refusing to start.")


def test_serve_refuses_a_credentials_path_under_a_file(monkeypatch, tmp_path):
    parent = tmp_path / "not-a-directory"
    parent.write_text("x")
    path = parent / "credentials"
    monkeypatch.setattr(config, "LAUNCHER_CREDENTIALS_DIR", str(path))
    assert _refusal(guard.ROLE_SERVE) == f"could not inspect {path} (NotADirectoryError); refusing to start."


@pytest.mark.skipif(os.geteuid() == 0, reason="root can lstat through a mode-000 directory")
def test_serve_refuses_a_credentials_path_it_cannot_inspect(monkeypatch, tmp_path):
    locked = tmp_path / "locked"
    locked.mkdir()
    path = locked / "credentials"
    monkeypatch.setattr(config, "LAUNCHER_CREDENTIALS_DIR", str(path))
    locked.chmod(0)
    try:
        message = _refusal(guard.ROLE_SERVE)
    finally:
        locked.chmod(0o700)
    assert message == f"could not inspect {path} (PermissionError); refusing to start."


def test_serve_refuses_any_other_inspection_error_by_class_only(monkeypatch):
    marker = "inspection-error-text-must-not-appear"

    def lstat(path):
        raise OSError(errno.EIO, marker, path)

    monkeypatch.setattr(guard, "os", SimpleNamespace(environ=os.environ, lstat=lstat))
    message = _refusal(guard.ROLE_SERVE)
    assert message == f"could not inspect {config.LAUNCHER_CREDENTIALS_DIR} (OSError); refusing to start."
    assert marker not in message


def test_serve_makes_one_lstat_and_nothing_else(monkeypatch):
    # The guard's os offers only environ and lstat, so a listdir, stat, open or
    # readlink would fail the test; the one lstat is of the fixed path.
    calls = []

    def lstat(path):
        calls.append(path)
        raise FileNotFoundError(errno.ENOENT, "absent", path)

    monkeypatch.setattr(guard, "os", SimpleNamespace(environ=os.environ, lstat=lstat))
    guard.assert_safe(guard.ROLE_SERVE)
    assert calls == [config.LAUNCHER_CREDENTIALS_DIR]


def test_serve_refuses_the_path_before_judging_the_claim(monkeypatch):
    # A partial claim and a present path: the path is reported.
    monkeypatch.setenv(config.ENV_SESSION_ID, "sesn_abc123")
    path = pathlib.Path(config.LAUNCHER_CREDENTIALS_DIR)
    path.mkdir()
    assert _refusal(guard.ROLE_SERVE).startswith(f"{path} exists on this sandbox")


# --- warm or claimed: the whole matrix of the four claim names ----------------
_STATES = ("absent", "empty", "blank", "valid")


@pytest.mark.parametrize("states", list(itertools.product(_STATES, repeat=4)), ids="-".join)
def test_only_an_all_absent_or_all_valid_claim_env_starts(states, monkeypatch):
    for (name, value), state in zip(_CLAIM_VALUES.items(), states):
        if state != "absent":
            monkeypatch.setenv(name, {"empty": "", "blank": " \t", "valid": value}[state])
    if set(states) == {"absent"}:
        guard.assert_safe(guard.ROLE_SERVE)
        assert guard.dispatched() is False
    elif set(states) == {"valid"}:
        guard.assert_safe(guard.ROLE_SERVE)
        assert guard.dispatched() is True
    else:
        unusable = [name for name, state in zip(_CLAIM, states) if state != "valid"]
        assert _refusal(guard.ROLE_SERVE) == (
            "this sandbox was claimed but its claim env is incomplete: "
            f"{', '.join(unusable)} missing or blank. Refusing to start on a partial dispatch."
        )


def test_unknown_role_rejected():
    with pytest.raises(ValueError, match="unknown role"):
        guard.assert_safe("nope")


# --- the guard reports names, never values ------------------------------------
@pytest.mark.parametrize("role", [guard.ROLE_LAUNCH, guard.ROLE_SERVE])
def test_guard_never_reports_a_value(role, monkeypatch):
    marker = "synthetic-value-must-not-appear"
    for name in _LAUNCH_FORBIDDEN:
        monkeypatch.setenv(name, marker)
    assert marker not in _refusal(role)


def test_guard_partial_dispatch_never_reports_key_value(monkeypatch):
    marker = "synthetic-key-must-not-appear"
    monkeypatch.setenv(config.ENV_CODEX_API_KEY, marker)
    monkeypatch.setenv(config.ENV_SESSION_ID, "sesn_abc123")
    message = _refusal(guard.ROLE_SERVE)
    assert message.startswith("this sandbox was claimed but its claim env is incomplete")
    assert marker not in message


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
