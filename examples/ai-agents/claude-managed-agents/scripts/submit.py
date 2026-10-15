#!/usr/bin/env python3
"""Start a session on the self-hosted environment and print what the agent did.

Run on your machine with your organization API key (on Claude Platform on AWS,
your AWS credentials). The session waits in the
environment's queue until the poller in your cluster claims it and hands it to a
warm sandbox. This script then follows the session until it settles and prints
each tool call, its result and the agent's replies.

  set -a; . ./.env; set +a
  python scripts/submit.py "your task"
  python scripts/submit.py --session-id sesn_...    # print an existing session
"""

from __future__ import annotations

import argparse
import os
import sys
import time

from anthropic import Anthropic

from _client import make_client

DEFAULT_TASK = (
    "Write a Python script that prints the first 20 Fibonacci numbers, save it as "
    "fib.py, run it, and show me the output."
)
# Settled: idle for one of these reasons, with no new events for two polls.
FINAL_STOP_REASONS = {"end_turn", "budget_reached", "refusal", "retries_exhausted"}


def text_of(content) -> str:
    return "".join(getattr(b, "text", "") for b in content or [] if getattr(b, "type", None) == "text")


def events_of(client: Anthropic, session_id: str) -> list:
    return list(client.beta.sessions.events.list(session_id, limit=1000, order="asc"))


def wait_until_settled(client: Anthropic, session_id: str, timeout: float) -> None:
    """Poll until the session is idle for a final reason and its events stop growing."""
    deadline = time.monotonic() + timeout
    last_count, stable, shown = -1, 0, 0
    while time.monotonic() < deadline:
        events = events_of(client, session_id)
        for event in events[shown:]:
            if event.type == "agent.tool_use":
                print(f"  -> {event.name}", flush=True)
        shown = len(events)
        idle = [e for e in events if e.type == "session.status_idle"]
        final = bool(idle) and idle[-1].stop_reason.type in FINAL_STOP_REASONS
        status = client.beta.sessions.retrieve(session_id).status
        if final and status == "idle" and len(events) == last_count:
            stable += 1
            if stable >= 2:
                return
        else:
            stable = 0
        last_count = len(events)
        time.sleep(3)
    print(f"timed out after {timeout:.0f}s waiting for the session to settle", file=sys.stderr)


def print_session(client: Anthropic, session_id: str) -> int:
    """Print the conversation and every tool call with its result. Return the error count."""
    session = client.beta.sessions.retrieve(session_id)
    events = events_of(client, session_id)
    print(f"\nSession {session_id} (status: {session.status})")
    errors = 0
    for event in events:
        if event.type == "user.message":
            print(f"\n[user] {text_of(event.content).strip()}")
        elif event.type == "agent.message":
            text = text_of(event.content).strip()
            if text:
                print(f"\n[agent] {text}")
        elif event.type == "agent.tool_use":
            detail = event.input.get("command") or event.input.get("file_path") or event.input.get("path") or ""
            print(f"\n[tool] {event.name}: {str(detail)[:200]}")
        elif event.type in ("user.tool_result", "agent.tool_result"):
            # The worker in the sandbox posts each result back to the session.
            mark = "error" if event.is_error else "ok"
            errors += bool(event.is_error)
            out = text_of(event.content).strip().replace("\n", "\n         ")
            print(f"[result:{mark}] {out[:800]}")
        elif event.type == "session.error":
            errors += 1
            print(f"\n[session error] {event}")
        elif event.type == "session.status_idle":
            print(f"\n[idle] {event.stop_reason.type}")
    usage = [e for e in events if e.type == "session.usage"]
    cost = ""
    if usage:
        list_cost = usage[-1].usage.list_cost
        cost = f", list cost {int(list_cost.amount) / 100:.2f} {list_cost.currency}"
    print(f"\n{sum(e.type == 'agent.tool_use' for e in events)} tool calls, {errors} errors{cost}")
    return errors


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("task", nargs="?", default=DEFAULT_TASK, help="the task for the agent")
    parser.add_argument("--session-id", help="print an existing session instead of starting one")
    parser.add_argument("--budget-cents", default="100",
                        help="spend ceiling for the session in US cents (default 100, i.e. $1.00); 0 for none")
    parser.add_argument("--timeout", type=float, default=600, help="seconds to wait for the session")
    args = parser.parse_args()

    client = make_client()

    if args.session_id:
        sys.exit(1 if print_session(client, args.session_id) else 0)

    agent_id = os.environ.get("AGENT_ID")
    environment_id = os.environ.get("ANTHROPIC_ENVIRONMENT_ID")
    if not agent_id or not environment_id:
        sys.exit("Set AGENT_ID and ANTHROPIC_ENVIRONMENT_ID (see scripts/setup_agent.py).")

    extra = {}
    if args.budget_cents != "0":
        extra["budget"] = {"type": "limit", "max_list_cost": {"amount": args.budget_cents, "currency": "USD"}}
    session = client.beta.sessions.create(
        agent=agent_id,
        environment_id=environment_id,
        title="EKS Nitro sandbox session",
        initial_events=[{"type": "user.message", "content": [{"type": "text", "text": args.task}]}],
        **extra,
    )
    print(f"Session {session.id} created; waiting for the cluster to pick it up...")
    wait_until_settled(client, session.id, args.timeout)
    sys.exit(1 if print_session(client, session.id) else 0)


if __name__ == "__main__":
    main()
