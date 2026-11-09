#!/usr/bin/env python3
"""Start a self-hosted session and run the agent, or send a follow-up turn.

Run on your machine with your application key. The flow (issue #9's default,
application-managed provisioning):

  1. Create the session with environment.type: self_hosted. OpenAI returns the
     session's environment id and its remote URL.
  2. Open the session's event stream, then hand the environment id and remote
     URL to the launcher in the cluster, which claims a Nitro sandbox and starts
     codex exec-server in it pointing at that remote URL.
     The launcher is reached over a ClusterIP Service you port-forward:
       kubectl port-forward svc/openai-launcher 8080:8080
     Every request to the launcher carries LAUNCHER_AUTH_TOKEN from your .env.
  3. Wait on the open stream for agent.session.environment.connected for this
     session and this environment (up to --connect-timeout seconds, default
     300; an event for another session or environment does not count). Only
     then send the prompt, and
     keep streaming the turn, printing the agent's output. On the timeout, or on
     agent.session.environment.failed, exit non-zero and send no prompt.

A follow-up turn in the SAME session runs in the SAME claimed pod, so files the
first turn wrote are still there. Its environment is usually still connected:
the API's environment status says so, and the prompt goes at once:

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
import queue
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from openai import APIStatusError, BadRequestError

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

# How long to wait for agent.session.environment.connected before giving up
# without sending the prompt. OpenAI's self-hosted guide has the application open
# the session's event stream, wait for that event, and only then send input.
DEFAULT_CONNECT_TIMEOUT = 300


def _handoff_timeout() -> int:
    hint = int(os.environ.get("LAUNCHER_READY_TIMEOUT_HINT", DEFAULT_READY_TIMEOUT_HINT))
    return hint + HANDOFF_TIMEOUT_HEADROOM


def _launcher_token() -> str:
    token = os.environ.get("LAUNCHER_AUTH_TOKEN")
    if not token:
        sys.exit(
            "Set LAUNCHER_AUTH_TOKEN in .env (the same value stored in the "
            "launcher-auth Secret). The launcher checks it on every claim and release request."
        )
    return token


def _post(url: str, payload: dict, token: str, timeout: int) -> dict:
    # urlopen also opens file:// and other schemes; the launcher is an HTTP intake.
    if urllib.parse.urlsplit(url).scheme not in ("http", "https"):
        sys.exit(f"the launcher URL must start with http:// or https://: {url}")
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - http(s) only, checked above
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


class _EventPump:
    """Read a session's event stream on a background thread, so a wait on it can time out.

    The stream comes from client.beta.agents.sessions.events.stream(session_id),
    which subscribes without sending input. Events are deduplicated by event_id,
    as the SDK's own sessions.stream helper does.
    """

    END = object()

    def __init__(self, stream):
        self._stream = stream
        self._queue: queue.Queue = queue.Queue()
        self._seen: set[str] = set()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        try:
            for event in self._stream:
                self._queue.put(event)
        except Exception as exc:  # handed to the reader of the queue
            self._queue.put(exc)
        self._queue.put(self.END)

    def next(self, timeout: float | None):
        """The next new event, or END. Raises the stream's error, or queue.Empty once
        `timeout` seconds have passed. The deadline is set once, so a stream that keeps
        replaying an event it already sent cannot hold the wait open past it."""
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            remaining = None
            if deadline is not None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise queue.Empty
            item = self._queue.get(timeout=remaining)
            if isinstance(item, BaseException):
                raise item
            event_id = getattr(item, "event_id", None)
            if item is self.END or event_id is None or event_id not in self._seen:
                if event_id is not None:
                    self._seen.add(event_id)
                return item

    def close(self) -> None:
        self._stream.close()


_ENVIRONMENT_EVENTS = ("agent.session.environment.connected", "agent.session.environment.failed")


def _is_this_environment(event, session_id: str, environment_id: str) -> bool:
    """True if an environment event names this session and this environment."""
    environment = getattr(event, "environment", None)
    return (getattr(event, "session_id", None) == session_id
            and getattr(environment, "id", None) == environment_id)


def wait_for_environment(client, events: _EventPump, session_id: str, environment_id: str,
                         timeout: float) -> None:
    """Return once the environment is connected; otherwise exit non-zero. Sends nothing.

    An environment that is already connected (a follow-up turn) may emit no new
    connection event, so its status is read first:
    client.beta.agents.environments.retrieve(environment_id).status, trusted only
    when the API returned that same environment id. On the stream, a connected or
    failed event counts only when its session_id is this session's and its
    environment.id is this environment's; any other environment event is ignored.
    """
    status = None
    try:
        info = client.beta.agents.environments.retrieve(environment_id)
    except APIStatusError as exc:
        print(f"[note] could not read the environment's status (HTTP {exc.status_code}); "
              "waiting for its connection event")
    else:
        if getattr(info, "id", None) == environment_id:
            status = info.status
        else:
            print("[note] the API returned the status of another environment; "
                  "waiting for this environment's connection event")
    if status == "connected":
        print("[environment already connected]")
        return
    if status == "failed":
        sys.exit("the environment's status is failed; no prompt was sent.")

    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            sys.exit(f"the environment did not connect within {timeout:g}s; no prompt was sent. "
                     "Check the claimed sandbox's log (kubectl logs <SANDBOX>).")
        try:
            event = events.next(remaining)
        except queue.Empty:
            continue
        if event is _EventPump.END:
            sys.exit("the session's event stream ended before the environment connected; "
                     "no prompt was sent.")
        if event.type in _ENVIRONMENT_EVENTS and not _is_this_environment(event, session_id, environment_id):
            continue  # another session's or another environment's event
        if event.type == "agent.session.environment.connected":
            print("[environment connected]")
            return
        if event.type == "agent.session.environment.failed":
            sys.exit(f"[environment failed] {event.environment.error}; no prompt was sent.")
        if event.type in ("agent.session.failed", "error"):
            sys.exit(f"[session error] {event.type} before the environment connected; "
                     "no prompt was sent.")


def send_input(client, session_id: str, prompt: str) -> None:
    """Submit the prompt as one user message (the shape the SDK's sessions.stream sends)."""
    client.beta.agents.sessions.events.create(
        session_id,
        events=[{"type": "agent.session.input.message",
                 "input": [{"role": "user", "content": [{"type": "input_text", "text": prompt}]}]}],
        idempotency_key=str(uuid.uuid4()),
    )


def stream_turn(events: _EventPump) -> int:
    """Stream one turn's events and print the agent's output. Return error count.

    The turn ends as the SDK's sessions.stream helper ends it: on
    agent.session.failed, or on agent.session.idle after the main agent's turn
    (the first turn.created with no subagent_id) completed, failed or was cancelled.
    """
    errors = 0
    saw_text = False
    turn_id = None
    turn_ended = False
    while True:
        event = events.next(None)
        if event is _EventPump.END:
            errors += 1
            print("\n[stream ended] the event stream closed before the turn finished")
            break
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
        if kind == "agent.session.turn.created" and event.turn.subagent_id is None and turn_id is None:
            turn_id = event.turn_id
        if kind in ("agent.session.turn.completed", "agent.session.turn.failed",
                    "agent.session.turn.cancelled") and turn_id is not None and event.turn_id == turn_id:
            turn_ended = True
        if kind == "agent.session.failed" or (kind == "agent.session.idle" and turn_ended):
            break
    print()
    return errors


def run_turn(client, session_id: str, environment_id: str, prompt: str, connect_timeout: float,
             start_executor=None) -> int:
    """Open the event stream, wait for the environment to connect, then send the prompt.

    start_executor, if given, runs after the stream is open and before the wait:
    the first turn hands the session to the launcher there.
    """
    events = _EventPump(client.beta.agents.sessions.events.stream(session_id))
    try:
        if start_executor is not None:
            start_executor()
        wait_for_environment(client, events, session_id, environment_id, connect_timeout)
        send_input(client, session_id, prompt)
        print("\nagent output:\n")
        return stream_turn(events)
    finally:
        events.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("task", nargs="?", default=DEFAULT_TASK, help="the task for the agent")
    parser.add_argument("--session-id", help="send a follow-up turn to an existing session")
    parser.add_argument("--launcher-url", default=DEFAULT_LAUNCHER_URL,
                        help=f"the launcher intake URL (default {DEFAULT_LAUNCHER_URL})")
    parser.add_argument("--budget-cents", default="100",
                        help="spend ceiling in US cents (default 100 = $1.00); 0 for none")
    parser.add_argument("--connect-timeout", type=float, default=DEFAULT_CONNECT_TIMEOUT,
                        help="seconds to wait for the environment to connect before giving up "
                             f"without sending the prompt (default {DEFAULT_CONNECT_TIMEOUT})")
    args = parser.parse_args()

    client = make_client()

    # Follow-up turn: the session (and its claimed pod) already exist. The pod is
    # the one the launcher claimed for this session; the follow-up turn runs there
    # because the executor is still connected to the same environment.
    if args.session_id:
        print(f"follow-up turn in session {args.session_id} (same claimed pod)")
        environment_id = client.beta.agents.sessions.retrieve(args.session_id).environment.id
        errors = run_turn(client, args.session_id, environment_id, args.task, args.connect_timeout)
        sys.exit(1 if errors else 0)

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

    # Open the event stream first, then start the executor, then wait for it to
    # connect: only a connected environment gets the prompt.
    errors = run_turn(
        client, session.id, env.id, args.task, args.connect_timeout,
        start_executor=lambda: hand_off_to_launcher(args.launcher_url, token, session.id, env.id, env.remote_url),
    )

    final = client.beta.agents.sessions.retrieve(session.id)
    print(f"\nfinal status: {final.status}")
    print(f"\nTo send a follow-up turn to the same pod:\n  python scripts/submit.py --session-id {session.id} \"...\"")
    print(f"To clean up:\n  python scripts/cleanup.py {session.id}")
    sys.exit(1 if errors or final.status == "failed" else 0)


if __name__ == "__main__":
    main()
