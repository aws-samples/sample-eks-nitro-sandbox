"""The credential boundary, checked by name before any process in the cluster starts work.

OpenAI runs the agent harness, the model and the session. Only the executor's
tool calls run in the cluster. Two OpenAI keys, kept apart:

  * The application key (OPENAI_API_KEY) can create sessions and read every
    session the project can see. It stays on the operator's machine; no pod may
    hold it. scripts/ use it, never the cluster.
  * The environment key (OPENAI_EXECUTOR_API_KEY) lets an executor connect its
    environment. codex exec-server reads it as CODEX_API_KEY. The launcher holds
    it and gives it to each claimed sandbox through the SandboxClaim env, so a
    warm pod holds no key.

What each role may have in its environment, checked by variable NAME (a name
that is present with an empty or blank value counts as present), never by
value:

  * launcher -- none of OPENAI_API_KEY, OPENAI_EXECUTOR_API_KEY,
    LAUNCHER_AUTH_TOKEN or CODEX_API_KEY. Its environment key and intake token
    come only from the two files deploy/launcher.yaml projects into
    config.LAUNCHER_CREDENTIALS_DIR, which config.read_launcher_credential
    reads; the manifest, not this module, owns what that volume holds.
  * serve, before a claim (a warm pod) -- none of OPENAI_API_KEY,
    OPENAI_EXECUTOR_API_KEY or LAUNCHER_AUTH_TOKEN, and none of CODEX_API_KEY,
    OPENAI_SESSION_ID, OPENAI_ENVIRONMENT_ID or OPENAI_REMOTE_URL.
  * serve, on a claimed pod -- still none of the first three, and all four of
    CODEX_API_KEY and the session tuple, each with a non-blank value, injected
    by the controller from the SandboxClaim env into the pod it cold-started
    for that claim.

A sandbox also has nothing at config.LAUNCHER_CREDENTIALS_DIR: one lstat of
that path, which follows no link and lists nothing, must find it absent.

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

from . import config

ROLE_LAUNCH = "launch"
ROLE_SERVE = "serve"

# The four names a SandboxClaim's env gives a claimed sandbox (sandbox.py). All
# four are absent on a warm pod and all four are set on a claimed one.
_CLAIM_ENV = (
    config.ENV_CODEX_API_KEY,
    config.ENV_SESSION_ID,
    config.ENV_ENVIRONMENT_ID,
    config.ENV_REMOTE_URL,
)

# The launcher: the application key is operator-only, its own two credentials
# are files only, and it never runs codex, so CODEX_API_KEY has no use there.
_LAUNCH_FORBIDDEN = (
    config.ENV_API_KEY,
    config.ENV_EXECUTOR_API_KEY,
    config.ENV_LAUNCHER_AUTH_TOKEN,
    config.ENV_CODEX_API_KEY,
)

# Every sandbox, warm or claimed: the application key, and the launcher's two
# credentials, which a hand-written SandboxClaim could add because the template
# allows claim env (envVarsInjectionPolicy: Allowed), and which serve's two
# children would otherwise inherit.
_SERVE_FORBIDDEN = (
    config.ENV_API_KEY,
    config.ENV_EXECUTOR_API_KEY,
    config.ENV_LAUNCHER_AUTH_TOKEN,
)


def assert_safe(role: str) -> None:
    """Raise unless this role's process holds exactly the credentials it should."""
    if role == ROLE_LAUNCH:
        _refuse_present(role, _LAUNCH_FORBIDDEN)
    elif role == ROLE_SERVE:
        _refuse_present(role, _SERVE_FORBIDDEN)
        _refuse_credentials_path()
        _refuse_partial_claim()
    else:
        raise ValueError(f"unknown role {role!r}")


def dispatched() -> bool:
    """True on a claimed sandbox, False on a warm one.

    Call it only after ``assert_safe(ROLE_SERVE)`` has accepted the pod, so the
    four claim names are either all present or all absent.
    """
    return any(name in os.environ for name in _CLAIM_ENV)


def _refuse_present(role: str, names: tuple[str, ...]) -> None:
    # Presence, not truthiness: an empty or blank value is still a variable this
    # role must not have, and its children would inherit it.
    present = [name for name in names if name in os.environ]
    if present:
        raise RuntimeError(
            f"{', '.join(present)} set in this {role} pod's environment; refusing "
            "to start. The application key stays on the operator's machine, the "
            "launcher reads its two credentials only from their files, and a "
            "sandbox gets its key only as CODEX_API_KEY in its SandboxClaim env."
        )


def _refuse_credentials_path() -> None:
    # deploy/sandbox-template.yaml mounts nothing there and the image creates
    # nothing there, so only "absent" passes: an empty directory, a file or a
    # link, dangling or not, means something put it there.
    path = config.LAUNCHER_CREDENTIALS_DIR
    try:
        os.lstat(path)
    except FileNotFoundError:
        return
    except OSError as exc:
        raise RuntimeError(
            f"could not inspect {path} ({type(exc).__name__}); refusing to start."
        ) from None
    raise RuntimeError(
        f"{path} exists on this sandbox; refusing to start. A sandbox gets its "
        "key only from its SandboxClaim env, and deploy/sandbox-template.yaml "
        "mounts nothing there."
    )


def _refuse_partial_claim() -> None:
    # Exactly two states start: warm (none of the four claim names) and claimed
    # (all four, none blank). A partial claim would run an unkeyed executor or
    # one with half a session.
    if not any(name in os.environ for name in _CLAIM_ENV):
        return
    unusable = [name for name in _CLAIM_ENV if not os.environ.get(name, "").strip()]
    if unusable:
        raise RuntimeError(
            "this sandbox was claimed but its claim env is incomplete: "
            f"{', '.join(unusable)} missing or blank. Refusing to start on a "
            "partial dispatch."
        )
