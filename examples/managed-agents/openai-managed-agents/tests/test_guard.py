"""Tests for the credential boundary (guard.py) and the dispatch validators.

These assert the issue #9 key-separation rules by variable or entry NAME, never
by value:

  * the application key (OPENAI_API_KEY) is refused in every pod, as a variable
    or as an entry of that name in the credentials directory;
  * a warm sandbox holds neither key and no session;
  * a claimed sandbox holds the whole session tuple AND CODEX_API_KEY (injected
    by the controller from the claim env), and a partial dispatch is refused;
  * the launcher needs the environment key and refuses the application key.

Run with: python -m pytest  (from this sample's folder, with the package
installed: pip install .)
"""

from __future__ import annotations

import dataclasses
import errno
import os
import pathlib
import re
import shutil
from collections.abc import Callable

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


@pytest.fixture(autouse=True)
def sleeps(monkeypatch):
    """The launcher's waits between attempts, recorded instead of slept.

    raising=False, so this file also runs against a guard that never retries.
    """
    recorded = []
    monkeypatch.setattr(guard, "_sleep", recorded.append, raising=False)
    return recorded


def _mount(*names, value="mounted-value"):
    """Create files in the credentials directory, as the projected volume does."""
    directory = pathlib.Path(config.LAUNCHER_CREDENTIALS_DIR)
    directory.mkdir(exist_ok=True)
    for name in names:
        (directory / name).write_text(value)
    return directory


# Timestamp directory names in the atomic writer's form.
_TS = "..2026_11_09_21_00_00.000000000"
_TS_NEXT = "..2026_11_09_22_00_00.111111111"


def _kubelet_volume(*names, ts=_TS):
    """Lay out the credentials directory as the kubelet's atomic writer does.

    The files are in a timestamp directory, ``..data`` links to it by its bare
    name, and each published name is a symlink through ``..data``.
    """
    directory = pathlib.Path(config.LAUNCHER_CREDENTIALS_DIR)
    directory.mkdir(exist_ok=True)
    (directory / ts).mkdir()
    for name in names:
        (directory / ts / name).write_text("mounted-value")
        (directory / name).symlink_to(f"..data/{name}")
    (directory / "..data").symlink_to(ts)
    return directory


def _swap_in(directory, *names, ts=_TS_NEXT):
    """The writer part-way through an update: the next directory, and ..data_tmp linking to it."""
    (directory / ts).mkdir()
    for name in names:
        (directory / ts / name).write_text("mounted-value")
    (directory / "..data_tmp").symlink_to(ts)


@dataclasses.dataclass
class _Step:
    """A change to the directory, made at one point in the guard's own filesystem calls."""

    when: str                     # "before" or "after" the call
    call: str                     # "listdir", "lstat", "readlink" or "stat"
    path: pathlib.Path
    action: Callable[[], None]
    skip: int = 0                 # matching calls to let through first
    times: int | None = 1         # matching calls that run the action; None for all
    ran: int = 0


class _RacingOs:
    """The guard's os, running each _Step at its point; hidden names are left out of a listdir."""

    def __init__(self, steps, hidden=None):
        self.steps = list(steps)
        self.hidden = {str(path): set(names) for path, names in (hidden or {}).items()}

    def __getattr__(self, name):
        return getattr(os, name)

    def _call(self, call, path, func):
        path = os.fspath(path)
        self._run("before", call, path)
        try:
            return func(path)
        finally:
            self._run("after", call, path)

    def _run(self, when, call, path):
        for step in self.steps:
            if (step.when, step.call, str(step.path)) != (when, call, path):
                continue
            if step.skip:
                step.skip -= 1
            elif step.times is None or step.ran < step.times:
                step.ran += 1
                step.action()

    def listdir(self, path):
        names = self._call("listdir", path, os.listdir)
        return [name for name in names if name not in self.hidden.get(os.fspath(path), ())]

    def lstat(self, path):
        return self._call("lstat", path, os.lstat)

    def readlink(self, path):
        return self._call("readlink", path, os.readlink)

    def stat(self, path):
        return self._call("stat", path, os.stat)


def _race(monkeypatch, *steps, hidden=None):
    racing = _RacingOs(steps, hidden)
    monkeypatch.setattr(guard, "os", racing)
    return racing


def _swapping():
    """The writer part-way through an update: ..data on _TS, ..data_tmp on _TS_NEXT."""
    directory = _kubelet_volume(*_LAUNCHER_FILES)
    _swap_in(directory, *_LAUNCHER_FILES)
    return directory


def _swapped():
    """Just after the rename: ..data on _TS_NEXT, the old _TS not yet removed."""
    directory = _swapping()
    (directory / "..data_tmp").replace(directory / "..data")
    return directory


def _refused(role):
    """Run the guard expecting a credentials-directory refusal; return the entries it lists."""
    with pytest.raises(RuntimeError) as exc:
        guard.assert_safe(role)
    message = str(exc.value)
    kind = "unexpected files in " if role == guard.ROLE_LAUNCH else "credential files in "
    assert message.startswith(kind), message
    listed = re.search(r": ([^;]*); refusing to start", message)
    assert listed, message
    return listed.group(1).split(", ")


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


# --- the atomic writer's entries, only in the form the kubelet makes them ----
@pytest.mark.parametrize("stage", ["settled", "swapping", "swapped"])
def test_launch_accepts_the_kubelet_projected_volume(stage, sleeps):
    # The real layout: the published names linked through ..data. While the
    # writer updates it, the next timestamp directory and ..data_tmp; just after,
    # ..data on the next directory, with the old one not yet removed. Each is
    # accepted in one attempt.
    directory = _kubelet_volume(*_LAUNCHER_FILES)
    if stage != "settled":
        _swap_in(directory, *_LAUNCHER_FILES)
    if stage == "swapped":
        (directory / "..data_tmp").replace(directory / "..data")
    guard.assert_safe(guard.ROLE_LAUNCH)
    assert sleeps == []


@pytest.mark.parametrize("names", [(), _LAUNCHER_FILES], ids=["writer-only", "launcher-volume"])
@pytest.mark.parametrize("claimed", [False, True])
def test_serve_refuses_a_kubelet_projected_volume(names, claimed, monkeypatch):
    # sandbox-template.yaml mounts nothing at this path, so a sandbox refuses even
    # the writer's own entries.
    if claimed:
        _claim_env(monkeypatch)
    _kubelet_volume(*names)
    assert _refused(guard.ROLE_SERVE) == sorted([_TS, "..data", *names])


@pytest.mark.parametrize("present", [False, True], ids=["absent", "empty"])
@pytest.mark.parametrize("claimed", [False, True])
def test_serve_accepts_an_absent_or_empty_credentials_directory(present, claimed, monkeypatch):
    if claimed:
        _claim_env(monkeypatch)
    if present:
        pathlib.Path(config.LAUNCHER_CREDENTIALS_DIR).mkdir()
    guard.assert_safe(guard.ROLE_SERVE)
    assert guard.dispatched() is claimed


def _bad_target(form, directory):
    """Make what a malformed ..data or ..data_tmp link points at; return the link's target."""
    outside = directory.parent / "outside"
    if form == "absolute":  # outside the directory, by absolute path
        target = outside / _TS_NEXT
        target.mkdir(parents=True)
        (target / config.ENV_API_KEY).write_text("mounted-value")
        return str(target)
    if form == "parent":  # outside the directory, through ../
        outside.mkdir()
        (outside / config.ENV_API_KEY).write_text("mounted-value")
        return "../outside"
    if form == "subdir":  # a timestamp name, one level down
        (directory / "sub" / _TS_NEXT).mkdir(parents=True)
        return f"sub/{_TS_NEXT}"
    if form == "dot-slash":  # the real timestamp directory, but through a path
        return f"./{_TS}"
    if form == "file":  # a timestamp name, but a regular file
        (directory / _TS_NEXT).write_text("x")
        return _TS_NEXT
    if form == "symlink":  # a timestamp name, but a symlink to a directory
        (directory / _TS_NEXT).symlink_to(_TS)
        return _TS_NEXT
    if form == "name":  # a real directory, without the timestamp form
        (directory / "payload").mkdir()
        return "payload"
    assert form == "dangling"  # a timestamp name that does not exist
    return _TS_NEXT


@pytest.mark.parametrize(
    "form", ["absolute", "parent", "subdir", "dot-slash", "file", "symlink", "name", "dangling"]
)
@pytest.mark.parametrize("link", ["..data", "..data_tmp"])
@pytest.mark.parametrize("role", [guard.ROLE_LAUNCH, guard.ROLE_SERVE])
def test_a_data_link_the_kubelet_does_not_make_is_refused(role, link, form):
    # The writer links ..data (and ..data_tmp) to a timestamp directory beside
    # it, by its bare name. Any other link under those names is refused itself,
    # whatever it points at.
    directory = _kubelet_volume(*(_LAUNCHER_FILES if role == guard.ROLE_LAUNCH else ()))
    if link == "..data":
        (directory / link).unlink()
    (directory / link).symlink_to(_bad_target(form, directory))
    assert link in _refused(role)


@pytest.mark.parametrize("where", ["current", "next", "orphan"])
def test_launch_refuses_the_application_key_inside_a_timestamp_directory(where):
    # Every timestamp directory is listed, so the key cannot sit behind ..data,
    # behind ..data_tmp, or in a directory no link names, with no top-level
    # name of its own.
    directory = _kubelet_volume(*_LAUNCHER_FILES)
    ts = _TS
    if where != "current":
        ts = _TS_NEXT
        (directory / ts).mkdir()
        if where == "next":
            (directory / "..data_tmp").symlink_to(ts)
    (directory / ts / config.ENV_API_KEY).write_text("mounted-value")
    with pytest.raises(RuntimeError, match=re.escape(f"{ts}/{config.ENV_API_KEY} is mounted")):
        guard.assert_safe(guard.ROLE_LAUNCH)


@pytest.mark.parametrize("claimed", [False, True])
def test_serve_refuses_the_application_key_inside_a_timestamp_directory(claimed, monkeypatch):
    if claimed:
        _claim_env(monkeypatch)
    directory = _kubelet_volume()
    (directory / _TS / config.ENV_API_KEY).write_text("mounted-value")
    assert _refused(guard.ROLE_SERVE) == [_TS, "..data"]


@pytest.mark.parametrize("make", [
    "file:other",       # a name the launcher does not hold
    "file:..creds",     # any ..name
    "symlink:..data",   # the writer's link name, but nested
    "dir:nested",       # a nested directory
    f"dir:{_TS_NEXT}",  # the writer's directory form, but nested
])
def test_launch_refuses_other_names_inside_a_timestamp_directory(make):
    kind, name = make.split(":", 1)
    directory = _kubelet_volume(*_LAUNCHER_FILES)
    path = directory / _TS / name
    if kind == "file":
        path.write_text("x")
    elif kind == "symlink":
        path.symlink_to(config.ENV_EXECUTOR_API_KEY)
    else:
        path.mkdir()
    assert _refused(guard.ROLE_LAUNCH) == [f"{_TS}/{name}"]


@pytest.mark.parametrize("kind", ["dir", "symlink-to-dir"])
def test_launch_refuses_a_credential_name_that_is_a_directory_inside_a_timestamp_directory(kind):
    directory = _kubelet_volume(config.ENV_EXECUTOR_API_KEY)
    name = config.ENV_LAUNCHER_AUTH_TOKEN
    if kind == "dir":
        (directory / _TS / name).mkdir()
    else:
        (directory / _TS / name).symlink_to(directory.parent)
    (directory / name).symlink_to(f"..data/{name}")
    # Both levels apply the rule: the name inside, and the top-level link to it,
    # which now resolves to a directory.
    assert _refused(guard.ROLE_LAUNCH) == [f"{_TS}/{name} (a directory)", f"{name} (a directory)"]


# --- the timestamp name is matched exactly ------------------------------------
_TS_FORMS = {
    "exact": _TS_NEXT,
    "trailing-newline": _TS_NEXT + "\n",
    # Arabic-Indic digits, which \d would also match: in the year, and after the dot.
    "non-ascii-year": "..\u0662\u0660\u0662\u0666" + _TS_NEXT[6:],
    "non-ascii-suffix": _TS_NEXT.rsplit(".", 1)[0] + ".\u0661\u0661",
}


@pytest.mark.parametrize("link", ["unlinked", "..data", "..data_tmp"])
@pytest.mark.parametrize("form", list(_TS_FORMS))
def test_launch_matches_a_timestamp_directory_name_exactly(form, link):
    # A second timestamp-form directory beside the real layout: accepted with the
    # writer's exact name, whether no link, ..data or ..data_tmp names it. With a
    # trailing newline, or non-ASCII digits, it is not a timestamp directory, so
    # it is refused as an unexpected entry, and so is a link to it.
    directory = _kubelet_volume(*_LAUNCHER_FILES)
    name = _TS_FORMS[form]
    (directory / name).mkdir()
    for file in _LAUNCHER_FILES:
        (directory / name / file).write_text("mounted-value")
    if link == "..data":
        (directory / link).unlink()
    if link != "unlinked":
        (directory / link).symlink_to(name)
    if form == "exact":
        guard.assert_safe(guard.ROLE_LAUNCH)
        return
    assert _refused(guard.ROLE_LAUNCH) == sorted([name] + ([link] if link != "unlinked" else []))


# --- a top-level credential name is never a directory --------------------------
@pytest.mark.parametrize("shape", [
    "file",                      # a plain file: accepted
    "kubelet-link",              # a symlink through ..data to a file: accepted
    "dir",                       # a directory
    "dir-holding-application-key",
    "link-to-outside-dir",       # a symlink to a directory outside, holding the key
    "link-to-data",              # a symlink to ..data, the timestamp directory
])
@pytest.mark.parametrize("name", _LAUNCHER_FILES)
def test_launch_refuses_a_top_level_credential_name_that_is_a_directory(name, shape):
    if shape == "file":
        _mount(*_LAUNCHER_FILES)
        guard.assert_safe(guard.ROLE_LAUNCH)
        return
    directory = _kubelet_volume(*_LAUNCHER_FILES)
    if shape == "kubelet-link":
        guard.assert_safe(guard.ROLE_LAUNCH)
        return
    path = directory / name
    path.unlink()
    if shape.startswith("dir"):
        path.mkdir()
        if shape == "dir-holding-application-key":
            (path / config.ENV_API_KEY).write_text("mounted-value")
    elif shape == "link-to-outside-dir":
        outside = directory.parent / "outside"
        outside.mkdir()
        (outside / config.ENV_API_KEY).write_text("mounted-value")
        path.symlink_to(outside)
    else:
        path.symlink_to("..data")
    assert _refused(guard.ROLE_LAUNCH) == [f"{name} (a directory)"]


# --- the writer changes the directory while the launcher checks it -------------
def _writer_step(transition, directory):
    """The layout and the writer step for one transition; the step runs at the given point."""
    data_tmp = directory / "..data_tmp"
    old = directory / _TS

    def rename():
        data_tmp.replace(directory / "..data")

    def remove_old():
        shutil.rmtree(old)

    return {
        # Round 4's four transitions, at the points it made them.
        "rename-after-listing": ("swapping", _Step("after", "listdir", directory, rename)),
        "remove-old-after-listing": ("swapped", _Step("after", "listdir", directory, remove_old)),
        "rename-before-readlink": ("swapping", _Step("before", "readlink", data_tmp, rename)),
        "remove-old-before-its-listdir": ("swapped", _Step("before", "listdir", old, remove_old)),
        # The same two steps after every check, just before the closing listing.
        "rename-before-closing-listing": (
            "swapping", _Step("before", "listdir", directory, rename, skip=1)),
        "remove-old-before-closing-listing": (
            "swapped", _Step("before", "listdir", directory, remove_old, skip=1)),
    }[transition]


@pytest.mark.parametrize("transition", [
    "rename-after-listing",
    "remove-old-after-listing",
    "rename-before-readlink",
    "remove-old-before-its-listdir",
    "rename-before-closing-listing",
    "remove-old-before-closing-listing",
])
def test_launch_accepts_a_valid_update_on_the_retry(transition, monkeypatch, sleeps):
    # The writer renames ..data_tmp over ..data, then removes the old timestamp
    # directory. Whichever of the guard's calls that lands between, the attempt
    # is unstable, and the retry's fresh listing sees a valid layout.
    directory = _swapping()
    layout, step = _writer_step(transition, directory)
    if layout == "swapped":
        (directory / "..data_tmp").replace(directory / "..data")
    _race(monkeypatch, step)
    guard.assert_safe(guard.ROLE_LAUNCH)
    assert step.ran == 1
    assert len(sleeps) == 1


def test_launch_lists_the_directory_a_new_data_link_points_to(monkeypatch, sleeps):
    # Form D: the listing is taken before the writer creates the next timestamp
    # directory, which holds an OPENAI_API_KEY entry, and points ..data at it.
    # The link's target is not in that listing, so the attempt does not accept
    # it; the closing snapshot lists the new directory and refuses the entry by
    # name at once, in the same attempt.
    directory = _kubelet_volume(*_LAUNCHER_FILES)

    def write_next():
        _swap_in(directory, *_LAUNCHER_FILES, config.ENV_API_KEY)
        (directory / "..data_tmp").replace(directory / "..data")

    step = _Step("after", "listdir", directory, write_next)
    _race(monkeypatch, step)
    with pytest.raises(RuntimeError, match=re.escape(f"{_TS_NEXT}/{config.ENV_API_KEY} is mounted")):
        guard.assert_safe(guard.ROLE_LAUNCH)
    assert step.ran == 1
    assert sleeps == []


def test_launch_refuses_a_data_link_to_a_directory_its_listing_does_not_name(monkeypatch, sleeps):
    # The same rule with no change on disk: a listing that does not name
    # ..data's target (here, leaving it out of both listings) never accepts the
    # link, even though the target is a real timestamp directory.
    directory = _swapped()
    (directory / _TS_NEXT / config.ENV_API_KEY).write_text("mounted-value")
    _race(monkeypatch, hidden={directory: {_TS_NEXT}})
    assert _refused(guard.ROLE_LAUNCH) == ["..data"]
    assert sleeps == []


def test_launch_lists_a_timestamp_directory_that_appears_after_the_listing(monkeypatch, sleeps):
    directory = _kubelet_volume(*_LAUNCHER_FILES)

    def add_unlinked():
        (directory / _TS_NEXT).mkdir()
        (directory / _TS_NEXT / "other").write_text("x")

    step = _Step("after", "listdir", directory, add_unlinked)
    _race(monkeypatch, step)
    assert _refused(guard.ROLE_LAUNCH) == [f"{_TS_NEXT}/other"]
    assert step.ran == 1
    assert len(sleeps) == 1


@pytest.mark.parametrize("change", ["link-stops-being-a-link", "link-becomes-a-directory", "link-repointed"])
def test_launch_retries_when_an_entry_changes_type_or_target(change, monkeypatch, sleeps):
    # ..data_tmp becomes a regular file between its lstat and readlink, becomes a
    # directory, or is pointed at the other timestamp directory just before the
    # closing listing. The retry checks what is there then.
    directory = _swapping()
    data_tmp = directory / "..data_tmp"

    def to_file():
        data_tmp.unlink()
        data_tmp.write_text("x")

    def to_dir():
        data_tmp.unlink()
        data_tmp.mkdir()

    def repoint():
        (directory / "repoint").symlink_to(_TS)
        (directory / "repoint").replace(data_tmp)

    step = {
        "link-stops-being-a-link": _Step("before", "readlink", data_tmp, to_file),
        "link-becomes-a-directory": _Step("before", "listdir", directory, to_dir, skip=1),
        "link-repointed": _Step("before", "listdir", directory, repoint, skip=1),
    }[change]
    _race(monkeypatch, step)
    if change == "link-repointed":
        guard.assert_safe(guard.ROLE_LAUNCH)
    else:
        assert _refused(guard.ROLE_LAUNCH) == ["..data_tmp"]
    assert step.ran == 1
    assert len(sleeps) == 1


def test_launch_refuses_a_directory_that_never_settles(monkeypatch, sleeps):
    # A new timestamp directory appears after every listing, so no attempt is
    # stable: 3 attempts, 0.2 s apart, then a refusal naming the directory.
    directory = _kubelet_volume(*_LAUNCHER_FILES)
    made = []

    def add_unlinked():
        made.append(f"..2026_11_09_23_00_00.{len(made) + 1}")
        (directory / made[-1]).mkdir()

    _race(monkeypatch, _Step("after", "listdir", directory, add_unlinked, times=None))
    with pytest.raises(RuntimeError) as exc:
        guard.assert_safe(guard.ROLE_LAUNCH)
    assert str(exc.value) == (
        f"the credentials directory {directory} did not settle: it changed during "
        "each of 3 checks, 0.2 s apart; refusing to start."
    )
    assert sleeps == [0.2, 0.2]
    assert len(made) == 6


@pytest.mark.parametrize("bad", ["other-file", "dangling-data-link", "credential-name-directory"])
def test_launch_refuses_a_stable_bad_layout_without_retrying(bad, sleeps):
    directory = _kubelet_volume(*_LAUNCHER_FILES)
    if bad == "other-file":
        (directory / "other").write_text("x")
        listed = ["other"]
    elif bad == "dangling-data-link":
        (directory / "..data_tmp").symlink_to(_TS_NEXT)
        listed = ["..data_tmp"]
    else:
        name = config.ENV_LAUNCHER_AUTH_TOKEN
        (directory / name).unlink()
        (directory / name).mkdir()
        listed = [f"{name} (a directory)"]
    assert _refused(guard.ROLE_LAUNCH) == listed
    assert sleeps == []


@pytest.mark.parametrize("where", ["top-level", "timestamp-directory"])
def test_launch_refuses_the_application_key_without_retrying(where, monkeypatch, sleeps):
    # The attempt is unstable (..data_tmp is renamed during it), and the entry
    # named OPENAI_API_KEY is still refused at once, before any retry.
    directory = _swapping()

    def rename():
        (directory / "..data_tmp").replace(directory / "..data")

    if where == "top-level":
        path = directory / config.ENV_API_KEY
        step = _Step("after", "listdir", directory, rename)
    else:
        path = directory / _TS_NEXT / config.ENV_API_KEY
        step = _Step("after", "listdir", directory / _TS, rename)
    path.write_text("mounted-value")
    _race(monkeypatch, step)
    with pytest.raises(RuntimeError, match=re.escape(f"{path} is mounted")):
        guard.assert_safe(guard.ROLE_LAUNCH)
    assert step.ran == 1
    assert sleeps == []


def test_launch_refuses_an_unreadable_entry_without_an_oserror(monkeypatch, sleeps):
    directory = _kubelet_volume(*_LAUNCHER_FILES)
    target = directory / _TS

    def deny():
        raise PermissionError(errno.EACCES, "Permission denied", str(target))

    _race(monkeypatch, _Step("before", "listdir", target, deny))
    with pytest.raises(RuntimeError, match=re.escape(f"could not inspect {target} (PermissionError)")):
        guard.assert_safe(guard.ROLE_LAUNCH)
    assert sleeps == []


@pytest.mark.parametrize("role", [guard.ROLE_LAUNCH, guard.ROLE_SERVE])
def test_a_credentials_path_that_is_not_a_directory_is_refused_without_an_oserror(role):
    path = pathlib.Path(config.LAUNCHER_CREDENTIALS_DIR)
    path.write_text("x")
    with pytest.raises(RuntimeError, match=re.escape(f"could not inspect {path} (NotADirectoryError)")):
        guard.assert_safe(role)


# --- a timestamp directory changes while the launcher checks it ---------------
def _second_timestamp_dir(directory, *names):
    """An unlinked next timestamp directory beside the real layout, as the writer starts one."""
    (directory / _TS_NEXT).mkdir()
    for name in names:
        (directory / _TS_NEXT / name).write_text("mounted-value")
    return directory / _TS_NEXT


@pytest.mark.parametrize("where", ["linked", "unlinked"])
def test_launch_refuses_the_application_key_added_to_a_listed_timestamp_directory(where, monkeypatch, sleeps):
    # The entry is created just after the opening snapshot lists the directory.
    # The closing snapshot lists it again and refuses the name at once, in the
    # same attempt.
    directory = _kubelet_volume(*_LAUNCHER_FILES)
    ts = directory / _TS if where == "linked" else _second_timestamp_dir(directory, *_LAUNCHER_FILES)
    planted = ts / config.ENV_API_KEY
    step = _Step("after", "listdir", ts, lambda: planted.write_text("mounted-value"))
    _race(monkeypatch, step)
    with pytest.raises(RuntimeError) as exc:
        guard.assert_safe(guard.ROLE_LAUNCH)
    assert str(exc.value).startswith(f"{planted} is mounted in this pod; refusing to start.")
    assert "mounted-value" not in str(exc.value)
    assert step.ran == 1
    assert sleeps == []


@pytest.mark.parametrize("call", ["listdir", "lstat"])
def test_launch_accepts_once_an_unexpected_nested_entry_is_removed(call, monkeypatch, sleeps):
    # The entry is in the opening snapshot and removed just after the directory
    # is listed, or just after the entry's own lstat. The attempt is unstable
    # (a vanished entry, or a closing snapshot that differs), and the retry
    # checks the valid final layout.
    directory = _kubelet_volume(*_LAUNCHER_FILES)
    bad = directory / _TS / "other"
    bad.write_text("x")
    step = _Step("after", call, directory / _TS if call == "listdir" else bad, bad.unlink)
    _race(monkeypatch, step)
    guard.assert_safe(guard.ROLE_LAUNCH)
    assert step.ran == 1
    assert sleeps == [0.2]


@pytest.mark.parametrize("already", [(), (config.ENV_EXECUTOR_API_KEY,)], ids=["first-file", "second-file"])
def test_launch_accepts_a_projected_name_written_into_a_new_timestamp_directory(already, monkeypatch, sleeps):
    # What the writer does mid-payload: it writes the next file into its new,
    # unlinked timestamp directory just after the opening snapshot listed it.
    # The closing snapshot differs, and the retry checks the directory again.
    directory = _kubelet_volume(*_LAUNCHER_FILES)
    ts = _second_timestamp_dir(directory, *already)
    name = config.ENV_LAUNCHER_AUTH_TOKEN if already else config.ENV_EXECUTOR_API_KEY
    step = _Step("after", "listdir", ts, lambda: (ts / name).write_text("mounted-value"))
    _race(monkeypatch, step)
    guard.assert_safe(guard.ROLE_LAUNCH)
    assert step.ran == 1
    assert sleeps == [0.2]


@pytest.mark.parametrize("change", ["file-becomes-link", "link-repointed", "file-becomes-directory"])
def test_launch_retries_when_a_nested_entry_changes_type_or_target(change, monkeypatch, sleeps):
    # The change lands after the opening snapshot's lstat or readlink of the
    # entry, so only the closing snapshot can see it. The retry checks what is
    # there then.
    directory = _kubelet_volume(*_LAUNCHER_FILES)
    token = directory / _TS / config.ENV_LAUNCHER_AUTH_TOKEN

    def to_link():
        token.unlink()
        token.symlink_to(config.ENV_EXECUTOR_API_KEY)

    def repoint():
        token.unlink()
        token.symlink_to(f"./{config.ENV_EXECUTOR_API_KEY}")

    def to_dir():
        token.unlink()
        token.mkdir()

    if change == "link-repointed":
        to_link()
        step = _Step("after", "readlink", token, repoint)
    else:
        step = _Step("after", "lstat", token, to_link if change == "file-becomes-link" else to_dir)
    _race(monkeypatch, step)
    if change == "file-becomes-directory":
        name = config.ENV_LAUNCHER_AUTH_TOKEN
        assert _refused(guard.ROLE_LAUNCH) == [f"{_TS}/{name} (a directory)", f"{name} (a directory)"]
    else:
        guard.assert_safe(guard.ROLE_LAUNCH)
    assert step.ran == 1
    assert sleeps == [0.2]


def test_launch_refuses_a_timestamp_directory_that_never_settles(monkeypatch, sleeps):
    # A new name appears in the linked timestamp directory after every listing
    # of it, so no attempt is stable.
    directory = _kubelet_volume(*_LAUNCHER_FILES)
    made = []

    def add_name():
        made.append(directory / _TS / f"other-{len(made) + 1}")
        made[-1].write_text("x")

    _race(monkeypatch, _Step("after", "listdir", directory / _TS, add_name, times=None))
    with pytest.raises(RuntimeError) as exc:
        guard.assert_safe(guard.ROLE_LAUNCH)
    assert str(exc.value) == (
        f"the credentials directory {directory} did not settle: it changed during "
        "each of 3 checks, 0.2 s apart; refusing to start."
    )
    assert sleeps == [0.2, 0.2]
    assert len(made) == 6


@pytest.mark.parametrize("phase", ["new-empty", "new-one-file", "new-complete", "old-removed"])
def test_launch_accepts_each_writer_phase_in_one_attempt(phase, sleeps):
    # The writer's other states, beside settled, swapping and swapped: a new
    # timestamp directory being filled before ..data_tmp exists, and the final
    # layout once the old directory is gone.
    if phase == "old-removed":
        directory = _swapped()
        shutil.rmtree(directory / _TS)
    else:
        directory = _kubelet_volume(*_LAUNCHER_FILES)
        count = {"new-empty": 0, "new-one-file": 1, "new-complete": 2}[phase]
        _second_timestamp_dir(directory, *_LAUNCHER_FILES[:count])
    guard.assert_safe(guard.ROLE_LAUNCH)
    assert sleeps == []


# --- a credential name the guard cannot follow ---------------------------------
@pytest.mark.parametrize("where", ["top-level", "timestamp-directory"])
def test_launch_refuses_a_credential_name_it_cannot_stat_without_an_oserror(where, monkeypatch, sleeps):
    # os.stat of the name raises PermissionError (a target under an unreadable
    # directory): refused at once, naming the path and the error class only.
    directory = _kubelet_volume(*_LAUNCHER_FILES)
    name = config.ENV_LAUNCHER_AUTH_TOKEN
    path = directory / name if where == "top-level" else directory / _TS / name

    def deny():
        raise PermissionError(errno.EACCES, "Permission denied", str(path))

    _race(monkeypatch, _Step("before", "stat", path, deny))
    with pytest.raises(RuntimeError) as exc:
        guard.assert_safe(guard.ROLE_LAUNCH)
    assert str(exc.value) == f"could not inspect {path} (PermissionError); refusing to start."
    assert sleeps == []


@pytest.mark.skipif(os.geteuid() == 0, reason="root can stat through a mode-000 directory")
def test_launch_refuses_a_credential_link_to_a_directory_under_an_unreadable_parent(sleeps):
    # Round 5's shape on a real filesystem: the link's target is a directory the
    # launcher cannot reach. os.path.isdir would call it "not a directory".
    directory = _kubelet_volume(*_LAUNCHER_FILES)
    locked = directory.parent / "locked"
    (locked / "directory").mkdir(parents=True)
    link = directory / config.ENV_LAUNCHER_AUTH_TOKEN
    link.unlink()
    link.symlink_to(locked / "directory")
    locked.chmod(0)
    try:
        with pytest.raises(RuntimeError) as exc:
            guard.assert_safe(guard.ROLE_LAUNCH)
    finally:
        locked.chmod(0o700)
    assert str(exc.value) == f"could not inspect {link} (PermissionError); refusing to start."
    assert sleeps == []


@pytest.mark.parametrize("where", ["top-level", "timestamp-directory"])
def test_launch_refuses_a_dangling_credential_link_in_a_stable_attempt(where, sleeps):
    # A credential name whose target is missing, with nothing changing: the
    # attempt is stable, so it is refused at once, with no retry.
    directory = _kubelet_volume(*_LAUNCHER_FILES)
    name = config.ENV_LAUNCHER_AUTH_TOKEN
    if where == "top-level":
        (directory / name).unlink()
        (directory / name).symlink_to("..data/missing")
        listed = [f"{name} (a dangling link)"]
    else:
        inner = directory / _TS / name
        inner.unlink()
        inner.symlink_to("missing")
        # The top-level link resolves through ..data to the same missing target.
        listed = [f"{_TS}/{name} (a dangling link)", f"{name} (a dangling link)"]
    assert _refused(guard.ROLE_LAUNCH) == listed
    assert sleeps == []


def test_launch_accepts_a_swap_that_leaves_a_name_unresolvable_during_the_check(monkeypatch, sleeps):
    # Just after the rename, the writer removes the old timestamp directory
    # while the launcher is about to stat a credential name inside it. That stat
    # finds nothing, but the closing snapshot no longer lists the directory, so
    # the attempt is retried instead of refused.
    directory = _swapped()
    old = directory / _TS
    step = _Step("before", "stat", old / config.ENV_EXECUTOR_API_KEY, lambda: shutil.rmtree(old))
    _race(monkeypatch, step)
    guard.assert_safe(guard.ROLE_LAUNCH)
    assert step.ran == 1
    assert sleeps == [0.2]


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
