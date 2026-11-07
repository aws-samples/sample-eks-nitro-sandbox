#!/usr/bin/env python3
"""Start a self-hosted session and run the agent, or send a follow-up turn.

Run on your machine with your application key. The flow (issue #9's default,
application-managed provisioning):

  1. Create the session with environment.type: self_hosted. OpenAI returns the
     session's environment id and its remote URL.
  2. Hand those to the launcher in the cluster, which claims a warm Nitro
     sandbox and starts codex exec-server in it pointing at that remote URL.
     The launcher is reached over a ClusterIP Service you port-forward:
       kubectl port-forward svc/openai-launcher 8080:8080
     Every request to the launcher carries LAUNCHER_AUTH_TOKEN from your .env.
  3. Stream the session until it settles, printing the agent's output.

A follow-up turn in the SAME session runs in the SAME claimed pod, so files the
first turn wrote are still there:

  set -a; . ./.env; set +a
  python scripts/submit.py "write hello.txt with the kernel build, then stop"
  python scripts/submit.py --session-id sesn_... "read hello.txt back to me"

The launcher URL defaults to http://127.0.0.1:8080 (your port-forward); override
with --launcher-url. A session uses OpenAI API credit for model tokens; the
tools run on your cluster's nodes.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

from openai import BadRequestError

from _client import make_client

WORKSPACE = "/workspace"
DEFAULT_TASK = (
    "Run `uname -rv` and `ls /sys/block` with your Bash tool, write their combined "
    "output to report.txt in your working directory, then read report.txt back to me."
)
DEFAULT_LAUNCHER_URL = "http://127.0.0.1:8080"

# The launcher's /sessions handler claims a sandbox and waits synchronously
# for the SandboxClaim to report Ready (up to SANDBOX_READY_TIMEOUT, which
# defaults to 300s -- see launcher/config.py) before it answers this request.
# A fixed 30s client timeout used to fire while the launcher was still waiting
# on a cold start, well before any error: the deployment had in fact succeeded,
# just not finished yet. The client timeout must comfortably exceed the
# launcher's own wait, not race it, so it is derived from the same number
# (plus headroom for the HTTP round trip itself) rather than hard-coded
# separately. Override LAUNCHER_READY_TIMEOUT_HINT if your cluster's
# SANDBOX_READY_TIMEOUT differs from the default.
DEFAULT_READY_TIMEOUT_HINT = 300
HANDOFF_TIMEOUT_HEADROOM = 30


def _handoff_timeout() -> int:
    hint = int(os.environ.get("LAUNCHER_READY_TIMEOUT_HINT", DEFAULT_READY_TIMEOUT_HINT))
    return hint + HANDOFF_TIMEOUT_HEADROOM


def _launcher_token() -> str:
    token = os.environ.get("LAUNCHER_AUTH_TOKEN")
    if not token:
        sys.exit(
            "Set LAUNCHER_AUTH_TOKEN in .env (the same value stored in the "
            "launcher-auth Secret). The launcher authenticates every request with it."
        )
    return token


def _post(url: str, payload: dict, token: str, timeout: int) -> dict:
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - operator's own port-forward
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            sys.exit("launcher rejected the request (401): LAUNCHER_AUTH_TOKEN does not match the launcher-auth Secret.")
        sys.exit(f"launcher returned {exc.code}: {exc.read().decode(errors='replace')}")
    except urllib.error.URLError as exc:
        sys.exit(
            f"could not reach the launcher at {url}: {exc}. Is "
            "`kubectl port-forward svc/openai-launcher 8080:8080` running?"
        )


def hand_off_to_launcher(launcher_url: str, token: str, session_id: str, environment_id: str, remote_url: str) -> None:
    """POST the session's environment id and remote URL to the in-cluster launcher.

    This call blocks until the launcher's claim reaches Ready (or its own
    SANDBOX_READY_TIMEOUT elapses), so the client timeout must be longer than
    that wait, not a fixed, shorter guess.
    """
    info = _post(
        launcher_url.rstrip("/") + "/sessions",
        {"session_id": session_id, "environment_id": environment_id, "remote_url": remote_url},
        token,
        timeout=_handoff_timeout(),
    )
    reused = " (reused the existing pod)" if info.get("reused") else ""
    print(f"launcher claimed sandbox {info.get('sandbox', '?')} for {session_id}{reused}")


def _is_spend_control_unsupported(exc: BadRequestError) -> bool:
    """True if a 400 is OpenAI refusing spend_control because the project lacks it.

    A project that does not accept a per-session budget refuses the
    `spend_control` parameter in one of two ways:

      * `400 'Session budget configuration is not enabled'` (param
        `spend_control`): the project has per-session budgets turned off;
      * `400` with error code `unknown_parameter` and param `spend_control`
        ("Unknown parameter: 'spend_control'."): the project does not know the
        parameter at all. A new project answered this way.

    Either is a property of the project, not of this request, so the only honest
    fallback is to drop `spend_control` and create the session without it -- not
    to retry the same body. The second shape is read from the structured error
    body (its `code` and `param` fields), never from the message text. Anything
    else, including an `unknown_parameter` on another param, another
    `spend_control` error, or an error that is not a 400, is not swallowed.
    """
    if getattr(exc, "status_code", None) != 400:
        return False

    # Both shapes are read from the structured error body the SDK delivers, so a
    # message that merely mentions the words never removes a budget the user asked for.
    body = getattr(exc, "body", None)
    if not isinstance(body, dict) or body.get("param") != "spend_control":
        return False
    if body.get("code") == "unknown_parameter":
        return True
    return str(body.get("message") or "").strip() == "Session budget configuration is not enabled"


def create_session(client, agent_id: str, spend_control: dict | None) -> object:
    """Create the self-hosted session, tolerating a project without spend_control.

    By default submit.py asks for a per-session spend ceiling, but not every
    project accepts one. If OpenAI refuses `spend_control` for that reason (see
    _is_spend_control_unsupported), we retry once without it and say so, so a
    reader running the documented defaults gets a session rather than a 400 they
    must decode. That session has no budget ceiling. Any other 400 is re-raised
    unchanged.
    """
    environment = {"type": "self_hosted", "workspace_directory": WORKSPACE}
    metadata = {"sample": "openai-managed-agents-eks"}
    try:
        return client.beta.agents.sessions.create(
            agent_id=agent_id, environment=environment, metadata=metadata,
            **({"spend_control": spend_control} if spend_control else {}),
        )
    except BadRequestError as exc:
        if spend_control and _is_spend_control_unsupported(exc):
            print("[note] this project does not accept a session budget (spend_control), so "
                  "this session has no budget ceiling. Pass --budget-cents 0 to skip asking "
                  "for one.")
            return client.beta.agents.sessions.create(
                agent_id=agent_id, environment=environment, metadata=metadata,
            )
        raise


def stream_turn(client, session_id: str, prompt: str) -> int:
    """Stream one turn's events and print the agent's output. Return error count."""
    errors = 0
    saw_text = False
    with client.beta.agents.sessions.stream(session_id, input=prompt) as events:
        for event in events:
            kind = event.type
            if kind == "agent.session.environment.connected":
                print("[environment connected]")
            elif kind == "agent.session.turn.output_text.delta":
                print(event.delta, end="", flush=True)
                saw_text = True
            elif kind == "agent.session.turn.output_text.done" and not saw_text:
                print(event.text)
            elif kind == "agent.session.turn.failed":
                errors += 1
                msg = event.turn.error.message if event.turn.error else "unknown"
                print(f"\n[turn failed] {msg}")
            elif kind == "agent.session.environment.failed":
                errors += 1
                print(f"\n[environment failed] {event.environment.error}")
            elif kind in ("agent.session.failed", "error"):
                errors += 1
                print(f"\n[session error] {kind}")
    print()
    return errors


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("task", nargs="?", default=DEFAULT_TASK, help="the task for the agent")
    parser.add_argument("--session-id", help="send a follow-up turn to an existing session")
    parser.add_argument("--launcher-url", default=DEFAULT_LAUNCHER_URL,
                        help=f"the launcher intake URL (default {DEFAULT_LAUNCHER_URL})")
    parser.add_argument("--budget-cents", default="100",
                        help="spend ceiling in US cents (default 100 = $1.00); 0 for none")
    args = parser.parse_args()

    client = make_client()

    # Follow-up turn: the session (and its claimed pod) already exist. The pod is
    # the one the launcher claimed for this session; the follow-up turn's stream
    # runs there because the executor is still connected to the same environment.
    if args.session_id:
        print(f"follow-up turn in session {args.session_id} (same claimed pod)")
        sys.exit(1 if stream_turn(client, args.session_id, args.task) else 0)

    agent_id = os.environ.get("AGENT_ID")
    if not agent_id:
        sys.exit("Set AGENT_ID (see scripts/setup_agent.py).")

    token = _launcher_token()

    # SpendControl is {"limit": <USD cents>}; 0 (or a project that does not
    # accept a session budget) means no ceiling. create_session tolerates a
    # project that refuses spend_control, so the documented default works
    # unchanged.
    spend_control = {"limit": int(args.budget_cents)} if args.budget_cents != "0" else None

    # Create the session WITHOUT running a turn yet: the executor must connect
    # first. The pinned SDK creates and returns the self-hosted environment.
    session = create_session(client, agent_id, spend_control)
    env = session.environment
    if env.type != "self_hosted":
        sys.exit(f"expected a self-hosted environment, got {env.type}")
    print(f"created session {session.id}")
    print(f"environment {env.id}")

    hand_off_to_launcher(args.launcher_url, token, session.id, env.id, env.remote_url)

    print("\nagent output:\n")
    errors = stream_turn(client, session.id, args.task)

    final = client.beta.agents.sessions.retrieve(session.id)
    print(f"\nfinal status: {final.status}")
    print(f"\nTo send a follow-up turn to the same pod:\n  python scripts/submit.py --session-id {session.id} \"...\"")
    print(f"To clean up:\n  python scripts/cleanup.py {session.id}")
    sys.exit(1 if errors or final.status == "failed" else 0)


if __name__ == "__main__":
    main()
