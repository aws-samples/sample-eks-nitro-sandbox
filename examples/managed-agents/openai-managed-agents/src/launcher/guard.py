"""The credential boundary, checked before any process in the cluster starts work.

OpenAI runs the agent harness, the model and the session. Only the executor's
tool calls run in the cluster. Two OpenAI keys, kept apart:

  * The application key (OPENAI_API_KEY) can create sessions and read every
    session the project can see. It stays on the operator's machine; no pod may
    hold it. scripts/ use it, never the cluster.
  * The environment key (OPENAI_EXECUTOR_API_KEY) lets an executor connect its
    environment. codex exec-server reads it as CODEX_API_KEY. The launcher holds
    it and gives it to each claimed sandbox through the SandboxClaim env, so a
    warm pod holds no key.

So the roles differ in what they may hold:

  * launcher -- the environment key, and never the application key. It holds
    the environment key and its intake token as files in
    config.LAUNCHER_CREDENTIALS_DIR, mounted from their Secrets, and neither in
    its environment.
  * serve, before a claim (a warm pod) -- neither key and no session. The
    SandboxWarmPool booted it ahead of any session.
  * serve, on a claimed pod -- the whole session tuple (session id, environment
    id, remote URL) and the environment key as CODEX_API_KEY, all injected by
    the controller into the pod it cold-started for that claim. This pod never
    existed as a warm pod: setting the claim's env forces a cold start, so the
    key is only present on a pod created for a specific session.

The guard checks the application key by name, never by content: a variable
named OPENAI_API_KEY, or an entry of that name in
config.LAUNCHER_CREDENTIALS_DIR (in the launcher, also inside the kubelet's
timestamp directories there). Where the launcher's two credential-name links
point is not checked.

Unlike the Claude sample there is no per-session token: OpenAI documents no
credential narrower than the environment key for a self-hosted session, and
OpenAI notes the agent-generated code the executor runs can read it
(https://developers.openai.com/api/docs/guides/agents-api/environments/security).
A compromised session therefore holds the environment key; the network policy
and a dedicated OpenAI project per trust boundary are what bound that, not a
narrower credential. The README's "What the environment key can reach" explains
this.
"""

from __future__ import annotations

import errno
import os
import re
import stat
import time
from typing import NamedTuple

from . import config

ROLE_LAUNCH = "launch"
ROLE_SERVE = "serve"

# The session tuple the launcher injects into a claimed sandbox. All three are
# present together on a claimed pod and all absent on a warm one.
_SESSION_TUPLE = (
    config.ENV_SESSION_ID,
    config.ENV_ENVIRONMENT_ID,
    config.ENV_REMOTE_URL,
)

# OpenAI/Codex variable names the SDK or codex would read as a credential, other
# than the environment key the launcher legitimately holds and injects.
_FOREIGN_CREDENTIALS = (
    "OPENAI_API_KEY",
    "OPENAI_ORG_ID",
    "OPENAI_ORGANIZATION",
)

# The files the launcher's credentials directory holds (deploy/launcher.yaml).
# Besides the kubelet atomic writer's own entries (_launcher_attempt), they
# are the only names it may hold. Each was an environment variable before; the
# launcher now refuses to start if either is still set in its environment.
_LAUNCHER_CREDENTIAL_FILES = (
    config.ENV_EXECUTOR_API_KEY,
    config.ENV_LAUNCHER_AUTH_TOKEN,
)


def assert_safe(role: str) -> None:
    """Raise unless this role's process holds exactly the credentials it should."""
    if role not in (ROLE_LAUNCH, ROLE_SERVE):
        raise ValueError(f"unknown role {role!r}")

    # The application key is refused in every role by NAME: a variable named
    # OPENAI_API_KEY, or an entry of that name in the credentials directory.
    # The entry is refused at the top level in both roles; deeper in the
    # directory, a sandbox refuses every entry (_assert_serve_safe) and the
    # launcher lists the kubelet's timestamp directories too
    # (_launcher_attempt). No content is read, and where the launcher's two
    # credential-name links point is not checked, so a file one of them links
    # to is read as that credential whatever it holds.
    if os.environ.get(config.ENV_API_KEY):
        raise RuntimeError(
            f"{config.ENV_API_KEY} is set in this pod; refusing to start. The "
            "application key creates and reads sessions and stays on the "
            "operator's machine; the cluster never holds it."
        )
    if role == ROLE_LAUNCH:
        names, unexpected = _settled_launcher_listing()
    else:
        names, unexpected = _credential_dir_names(), []
        if config.ENV_API_KEY in names:
            raise _application_key_mounted(config.launcher_credential_path(config.ENV_API_KEY))
    _refuse_foreign_credentials(role)

    if role == ROLE_LAUNCH:
        _assert_launch_safe(names, unexpected)
    else:
        _assert_serve_safe(names)


def dispatched() -> bool:
    """True on a claimed sandbox (the controller injected its session), False on a warm one.

    Call it only after ``assert_safe(ROLE_SERVE)`` has accepted the pod, so a
    partial or inconsistent env has already been refused.
    """
    return any(os.environ.get(name) for name in _SESSION_TUPLE)


def _application_key_mounted(path: str) -> RuntimeError:
    return RuntimeError(
        f"{path} is mounted in this pod; refusing to start. The application key "
        "creates and reads sessions and stays on the operator's machine; the "
        "cluster never holds it."
    )


def _could_not_inspect(path: str, exc: OSError) -> RuntimeError:
    return RuntimeError(
        f"could not inspect {exc.filename or path} ({type(exc).__name__}); "
        "refusing to start."
    )


def _credential_dir_names() -> list[str]:
    """Every name in config.LAUNCHER_CREDENTIALS_DIR, sorted, or none if it is absent.

    The sandbox's one listing; it refuses any name in it. Nothing is skipped.
    Any other error listing the directory is a refusal, never an OSError.
    """
    directory = config.LAUNCHER_CREDENTIALS_DIR
    try:
        return sorted(os.listdir(directory))
    except FileNotFoundError:
        return []
    except OSError as exc:
        raise _could_not_inspect(directory, exc) from None


# The kubelet's atomic writer, which fills the projected volume in
# deploy/launcher.yaml, keeps its own entries beside the names it publishes: a
# timestamp directory holding the files themselves, ..data linking to it by its
# bare name, ..data_tmp linking to the next one while the writer swaps it in,
# and each published name a symlink through ..data.
_KUBELET_DATA_LINKS = ("..data", "..data_tmp")
# The atomic writer's directory: "..2006_01_02_15_04_05." plus os.MkdirTemp digits.
# Always matched against the whole name (fullmatch): "$" would also accept a name
# with a trailing newline. The digits are spelled [0-9], because \d also matches
# non-ASCII digits, which the writer never uses.
_KUBELET_TS_DIR = re.compile(r"\.\.[0-9]{4}_[0-9]{2}_[0-9]{2}_[0-9]{2}_[0-9]{2}_[0-9]{2}\.[0-9]+")


# The kubelet's atomic writer renames ..data_tmp over ..data and removes the
# old timestamp directory while the launcher may be checking the directory, so
# a launcher check is retried when the directory changes under it: at most
# _SETTLE_ATTEMPTS attempts, _SETTLE_WAIT_SECONDS apart (at most 0.4 s of
# waiting in all). _sleep is a module attribute so the tests can replace it.
_SETTLE_ATTEMPTS = 3
_SETTLE_WAIT_SECONDS = 0.2
_sleep = time.sleep


class _Entry(NamedTuple):
    """One entry as one listing saw it: lstat file type, and readlink target if a symlink."""

    name: str
    kind: int
    target: str | None


class _Listing(NamedTuple):
    """One snapshot of the credentials directory, as an attempt opens or closes with it.

    ``top`` is every top-level entry. ``nested`` holds, for each top-level
    entry that is a timestamp directory (a real directory whose name matches
    _KUBELET_TS_DIR as a whole), that directory's name and its entries. Two
    snapshots are equal only when both levels are.
    """

    top: tuple[_Entry, ...]
    nested: tuple[tuple[str, tuple[_Entry, ...]], ...]


class _Unsettled(Exception):
    """The credentials directory changed during one launcher attempt."""


def _settled_launcher_listing() -> tuple[list[str], list[str]]:
    """The launcher's check of its credentials directory, from one attempt that was stable.

    Returns the attempt's top-level names and the entries it must not hold
    (see _launcher_attempt). An attempt is unstable when an entry it listed,
    at the top level or inside a timestamp directory, vanishes or changes
    type while it runs (FileNotFoundError or NotADirectoryError from an lstat,
    readlink or listdir of it, or readlink finding it is no longer a symlink),
    or when the snapshot taken at its end differs from the one at its start
    (see _snapshot for what a snapshot holds). An unstable attempt is retried
    with a fresh snapshot, at most _SETTLE_ATTEMPTS (3) attempts, waiting
    _SETTLE_WAIT_SECONDS (0.2 s) before each retry, so at most 0.4 s of
    waiting. If every attempt is unstable the launcher refuses to start,
    naming the directory.

    Not retried: a stable attempt's unexpected entries (refused by the caller
    at once), an entry named OPENAI_API_KEY in any listing of any attempt,
    opening or closing, top level or timestamp directory, stable or not
    (refused at once), and any other OSError (refused at once, naming the
    path and the error class). No OSError leaves the guard.
    """
    directory = config.LAUNCHER_CREDENTIALS_DIR
    for attempt in range(_SETTLE_ATTEMPTS):
        if attempt:
            _sleep(_SETTLE_WAIT_SECONDS)
        try:
            return _launcher_attempt(directory)
        except (_Unsettled, FileNotFoundError, NotADirectoryError):
            continue
        except OSError as exc:
            raise _could_not_inspect(directory, exc) from None
    raise RuntimeError(
        f"the credentials directory {directory} did not settle: it changed "
        f"during each of {_SETTLE_ATTEMPTS} checks, {_SETTLE_WAIT_SECONDS} s "
        "apart; refusing to start."
    )


def _snapshot(directory: str) -> _Listing:
    """One snapshot of the credentials directory: both levels, sorted, with each entry's type.

    What it holds, and so what the closing comparison covers: every top-level
    name with its lstat file type and, for a symlink, its readlink target;
    and for each top-level timestamp directory, its names with the same lstat
    type and readlink target. Not covered: file contents, sizes, modes and
    times, anything below a timestamp directory, and where a symlink's target
    leads beyond what the two levels list.

    An absent directory is an empty snapshot. Any other error listing the
    directory itself is a refusal: a mount that is not a directory does not
    settle by waiting. An entry named OPENAI_API_KEY, at either level, is
    refused as mounted as soon as that level's names are read, before any of
    them is examined. An entry or timestamp directory that vanishes raises
    FileNotFoundError, and a symlink that stops being one raises _Unsettled.
    """
    try:
        names = sorted(os.listdir(directory))
    except FileNotFoundError:
        return _Listing((), ())
    except OSError as exc:
        raise _could_not_inspect(directory, exc) from None
    top = _entries(directory, names)
    nested = []
    for entry in top:
        if _KUBELET_TS_DIR.fullmatch(entry.name) and entry.kind == stat.S_IFDIR:
            path = os.path.join(directory, entry.name)
            nested.append((entry.name, _entries(path, sorted(os.listdir(path)))))
    return _Listing(top, tuple(nested))


def _entries(path: str, names: list[str]) -> tuple[_Entry, ...]:
    """The entries of one directory listing, refusing an OPENAI_API_KEY name before any lstat."""
    if config.ENV_API_KEY in names:
        raise _application_key_mounted(os.path.join(path, config.ENV_API_KEY))
    entries = []
    for name in names:
        entry_path = os.path.join(path, name)
        mode = os.lstat(entry_path).st_mode
        target = None
        if stat.S_ISLNK(mode):
            try:
                target = os.readlink(entry_path)
            except OSError as exc:
                if exc.errno == errno.EINVAL:
                    raise _Unsettled from None
                raise
        entries.append(_Entry(name, stat.S_IFMT(mode), target))
    return tuple(entries)


def _credential_name_unexpected(path: str, listed: str) -> list[str]:
    """A launcher credential name is accepted only when it is not a directory or a symlink to one.

    The type is the one os.stat finds, following a symlink. A name whose
    target is missing (FileNotFoundError or NotADirectoryError from that
    stat) is returned as ``<name> (a dangling link)``, so a stable attempt
    refuses it at once. When the writer is the cause, it has also changed
    something the snapshot lists (it renamed ..data, or removed or emptied a
    timestamp directory), so the attempt is unstable and is retried instead.
    Any other error from that stat, PermissionError included, is a refusal at
    once naming the path and the error class.
    """
    try:
        mode = os.stat(path).st_mode
    except (FileNotFoundError, NotADirectoryError):
        return [f"{listed} (a dangling link)"]
    except OSError as exc:
        raise _could_not_inspect(path, exc) from None
    return [f"{listed} (a directory)"] if stat.S_ISDIR(mode) else []


def _launcher_attempt(directory: str) -> tuple[list[str], list[str]]:
    """One attempt: one snapshot, every check made against it, and a closing snapshot.

    Accepted at the top level of the snapshot:

      * the names in _LAUNCHER_CREDENTIAL_FILES, only when os.stat finds they
        are not a directory or a symlink to one (such a name is returned as
        ``<name> (a directory)``, and one whose target is missing as
        ``<name> (a dangling link)``; see _credential_name_unexpected). Where
        a symlink among them points is not otherwise checked;
      * ``..data`` and ``..data_tmp``, each only as a symlink whose target, as
        os.readlink returned it in this listing, is one path component (no
        "/", not absolute) that matches _KUBELET_TS_DIR as a whole and is the
        name of a real directory (not a symlink) in this same listing, which
        the next rule then lists. So every directory a link resolves to is
        listed in this attempt;
      * a name that matches _KUBELET_TS_DIR as a whole, only as a real
        directory (not a symlink). Every such directory is listed in the
        snapshot, whether or not a link names it, and checked from that
        listing. Inside it, an entry named OPENAI_API_KEY is refused as
        mounted (_snapshot), and the only names accepted are those in
        _LAUNCHER_CREDENTIAL_FILES, by the same rule as at the top level (such
        a name that is a directory or a symlink to one is returned as
        ``<timestamp directory>/<name> (a directory)``, and one whose target
        is missing as ``<timestamp directory>/<name> (a dangling link)``). Any
        other name there, including a directory of any other name and the
        writer's own names, is returned as ``<timestamp directory>/<name>``.
        Nothing below that level is listed.

    Every other top-level name is returned, including one that starts with
    ``..``. A top-level entry named OPENAI_API_KEY is refused as mounted at
    once (_snapshot). The attempt raises _Unsettled when the closing snapshot
    differs from the opening one at either level; the closing snapshot also
    refuses an OPENAI_API_KEY name at either level at once.
    """
    first = _snapshot(directory)
    names = [entry.name for entry in first.top]
    listed = {entry.name: entry for entry in first.top}
    timestamp_dirs = dict(first.nested)
    unexpected = []
    for entry in first.top:
        path = os.path.join(directory, entry.name)
        if entry.name in _LAUNCHER_CREDENTIAL_FILES:
            unexpected.extend(_credential_name_unexpected(path, entry.name))
        elif entry.name in _KUBELET_DATA_LINKS:
            if not _kubelet_data_link(entry, listed):
                unexpected.append(entry.name)
        elif entry.name in timestamp_dirs:
            inside = timestamp_dirs[entry.name]
            unexpected.extend(_timestamp_dir_unexpected(directory, entry.name, inside))
        else:
            unexpected.append(entry.name)
    if _snapshot(directory) != first:
        raise _Unsettled
    return names, unexpected


def _kubelet_data_link(entry: _Entry, listed: dict[str, _Entry]) -> bool:
    """True for a ..data or ..data_tmp link in the form the atomic writer makes it, in this listing."""
    target = entry.target  # None unless the entry was a symlink in this listing
    if target is None:
        return False
    if "/" in target or os.path.isabs(target) or not _KUBELET_TS_DIR.fullmatch(target):
        return False
    resolved = listed.get(target)
    return resolved is not None and resolved.kind == stat.S_IFDIR


def _timestamp_dir_unexpected(
    directory: str, ts_dir: str, entries: tuple[_Entry, ...]
) -> list[str]:
    """The names inside one timestamp directory that the launcher must not hold.

    ``entries`` is the directory as the attempt's snapshot listed it. An
    OPENAI_API_KEY name was already refused when the snapshot listed them.
    """
    unexpected = []
    for entry in entries:
        path = os.path.join(directory, ts_dir, entry.name)
        if entry.name in _LAUNCHER_CREDENTIAL_FILES:
            unexpected.extend(_credential_name_unexpected(path, f"{ts_dir}/{entry.name}"))
            continue
        unexpected.append(f"{ts_dir}/{entry.name}")
    return unexpected


def _assert_launch_safe(names: list[str], unexpected: list[str]) -> None:
    # The launcher never runs codex itself, so CODEX_API_KEY in its own env is
    # unexpected; it holds only the environment key it hands on.
    if os.environ.get(config.ENV_CODEX_API_KEY):
        raise RuntimeError(
            f"{config.ENV_CODEX_API_KEY} is set in the launcher; refusing to "
            "start. The launcher holds the environment key as "
            f"{config.ENV_EXECUTOR_API_KEY} and never runs codex itself."
        )
    in_env = [name for name in _LAUNCHER_CREDENTIAL_FILES if os.environ.get(name)]
    if in_env:
        raise RuntimeError(
            f"{', '.join(in_env)} set in the launcher's environment; refusing to "
            "start. The launcher reads its credentials from files in "
            f"{config.LAUNCHER_CREDENTIALS_DIR}, which deploy/launcher.yaml mounts "
            "from their Secrets, so no credential belongs in its environment."
        )
    if unexpected:
        raise RuntimeError(
            f"unexpected files in {config.LAUNCHER_CREDENTIALS_DIR}: "
            f"{', '.join(unexpected)}; refusing to start. The launcher holds only "
            f"{' and '.join(_LAUNCHER_CREDENTIAL_FILES)} there, neither of them a "
            "directory, beside the kubelet atomic writer's own entries."
        )
    if config.ENV_EXECUTOR_API_KEY not in names:
        raise RuntimeError(
            f"{config.launcher_credential_path(config.ENV_EXECUTOR_API_KEY)} is "
            "missing, so the launcher has no environment key to give to the "
            "sandboxes it claims. Store it in the openai-env-key Secret, which "
            "deploy/launcher.yaml mounts there."
        )


def _assert_serve_safe(names: list[str]) -> None:
    """A warm pod holds neither key and no session; a claimed pod holds the whole tuple + key."""
    # A sandbox never holds a credential file: its key arrives in the claim env.
    # deploy/sandbox-template.yaml mounts nothing at this path, so every entry
    # there is refused, the kubelet atomic writer's own included. An absent or
    # empty directory passes.
    if names:
        raise RuntimeError(
            f"credential files in {config.LAUNCHER_CREDENTIALS_DIR} on a sandbox: "
            f"{', '.join(names)}; refusing to start. A sandbox gets its key only "
            "from its SandboxClaim env, and deploy/sandbox-template.yaml mounts "
            "nothing there."
        )
    tuple_present = [name for name in _SESSION_TUPLE if os.environ.get(name)]
    has_key = bool(os.environ.get(config.ENV_CODEX_API_KEY))

    if not tuple_present and not has_key:
        # A warm pod: the SandboxWarmPool booted it before any session. It must
        # hold no OpenAI/Codex credential of its own, which the application-key
        # and foreign-credential checks above have already enforced.
        return

    # A claimed pod: the controller injected the whole session tuple AND the
    # key. Anything partial is refused, so a pod that got only some of the
    # dispatch (a misconfigured claim) never runs the executor with half a
    # session or an unkeyed executor.
    if len(tuple_present) != len(_SESSION_TUPLE):
        missing = [name for name in _SESSION_TUPLE if not os.environ.get(name)]
        raise RuntimeError(
            "this sandbox was claimed but its session env is incomplete; "
            f"missing {', '.join(missing)}. Refusing to start on a partial "
            "dispatch."
        )
    if not has_key:
        raise RuntimeError(
            f"this sandbox was claimed but {config.ENV_CODEX_API_KEY} is not "
            "set, so the executor would have no environment key. Refusing to "
            "start on a partial dispatch."
        )


def _refuse_foreign_credentials(role: str) -> None:
    """Refuse any OpenAI/Codex credential this role must never hold."""
    present = [k for k in _FOREIGN_CREDENTIALS if os.environ.get(k)]
    if present:
        raise RuntimeError(
            f"foreign OpenAI/Codex credential variables in this {role} pod: "
            f"{', '.join(present)}; refusing to start. Only the environment key "
            "(as the OPENAI_EXECUTOR_API_KEY file in the launcher, CODEX_API_KEY "
            "in a claimed sandbox) is expected."
        )
