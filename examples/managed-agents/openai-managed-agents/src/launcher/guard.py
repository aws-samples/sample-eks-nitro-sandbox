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

import os
import re

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

# The files the launcher's credentials directory holds (deploy/launcher.yaml),
# and the only ones it may hold. Each was an environment variable before; the
# launcher now refuses to start if either is still set in its environment.
_LAUNCHER_CREDENTIAL_FILES = (
    config.ENV_EXECUTOR_API_KEY,
    config.ENV_LAUNCHER_AUTH_TOKEN,
)


def assert_safe(role: str) -> None:
    """Raise unless this role's process holds exactly the credentials it should."""
    if role not in (ROLE_LAUNCH, ROLE_SERVE):
        raise ValueError(f"unknown role {role!r}")

    # No pod ever holds the application key, in any role, as a variable or as a
    # file in the credentials directory.
    if os.environ.get(config.ENV_API_KEY):
        raise RuntimeError(
            f"{config.ENV_API_KEY} is set in this pod; refusing to start. The "
            "application key creates and reads sessions and stays on the "
            "operator's machine; the cluster never holds it."
        )
    files = _credential_files()
    if config.ENV_API_KEY in files:
        raise RuntimeError(
            f"{config.launcher_credential_path(config.ENV_API_KEY)} is mounted in "
            "this pod; refusing to start. The application key creates and reads "
            "sessions and stays on the operator's machine; the cluster never "
            "holds it."
        )
    _refuse_foreign_credentials(role)

    if role == ROLE_LAUNCH:
        _assert_launch_safe(files)
    else:
        _assert_serve_safe(files)


def dispatched() -> bool:
    """True on a claimed sandbox (the controller injected its session), False on a warm one.

    Call it only after ``assert_safe(ROLE_SERVE)`` has accepted the pod, so a
    partial or inconsistent env has already been refused.
    """
    return any(os.environ.get(name) for name in _SESSION_TUPLE)


def _credential_files() -> list[str]:
    """The names in config.LAUNCHER_CREDENTIALS_DIR, or none if it is absent.

    The kubelet's atomic writer keeps its own entries beside a projected
    volume's files: the ``..data`` symlink (``..data_tmp`` while it swaps it)
    and a ``..<UTC timestamp>.<digits>`` directory. Exactly those are skipped,
    and only in those forms (a symlink, a directory). Every other name is
    returned, including one that starts with ``..``, so the callers refuse it.
    """
    directory = config.LAUNCHER_CREDENTIALS_DIR
    try:
        names = os.listdir(directory)
    except FileNotFoundError:
        return []
    return sorted(name for name in names if not _kubelet_entry(directory, name))


# The atomic writer's directory: "..2006_01_02_15_04_05." plus os.MkdirTemp digits.
_KUBELET_TS_DIR = re.compile(r"^\.\.\d{4}_\d{2}_\d{2}_\d{2}_\d{2}_\d{2}\.\d+$")


def _kubelet_entry(directory: str, name: str) -> bool:
    """True only for the kubelet atomic writer's own entries, in their own forms."""
    path = os.path.join(directory, name)
    if name in ("..data", "..data_tmp"):
        return os.path.islink(path)
    if _KUBELET_TS_DIR.match(name):
        return os.path.isdir(path) and not os.path.islink(path)
    return False


def _assert_launch_safe(files: list[str]) -> None:
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
    unexpected = [name for name in files if name not in _LAUNCHER_CREDENTIAL_FILES]
    if unexpected:
        raise RuntimeError(
            f"unexpected files in {config.LAUNCHER_CREDENTIALS_DIR}: "
            f"{', '.join(unexpected)}; refusing to start. The launcher holds only "
            f"{' and '.join(_LAUNCHER_CREDENTIAL_FILES)} there."
        )
    if config.ENV_EXECUTOR_API_KEY not in files:
        raise RuntimeError(
            f"{config.launcher_credential_path(config.ENV_EXECUTOR_API_KEY)} is "
            "missing, so the launcher has no environment key to give to the "
            "sandboxes it claims. Store it in the openai-env-key Secret, which "
            "deploy/launcher.yaml mounts there."
        )


def _assert_serve_safe(files: list[str]) -> None:
    """A warm pod holds neither key and no session; a claimed pod holds the whole tuple + key."""
    # A sandbox never holds a credential file: its key arrives in the claim env.
    if files:
        raise RuntimeError(
            f"credential files in {config.LAUNCHER_CREDENTIALS_DIR} on a sandbox: "
            f"{', '.join(files)}; refusing to start. A sandbox gets its key only "
            "from its SandboxClaim env."
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
