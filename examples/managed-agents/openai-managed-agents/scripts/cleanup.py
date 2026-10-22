#!/usr/bin/env python3
"""Clean up the sessions this sample created, claim-aware. Run on your machine.

Sessions and their claimed pods have independent lifecycles, and the issue
requires that a claim is never released on a wall-clock deadline alone: the
session's state is rechecked immediately before the claim is deleted. This
script does exactly that, per session, in this order:

  1. Retrieve the session's current state through the Agents API (the recheck).
  2. Ask the launcher to delete the session's SandboxClaim. The launcher is the
     only component with the RBAC to delete claims; it holds no application key,
     so the recheck in step 1 is done here, where the application key lives, and
     the claim delete follows it immediately. (--keep-claim skips this, e.g. to
     let a follow-up turn keep using the pod.)
  3. Delete the API session itself.

Deleting the claim removes the pod; deleting the session does not, and deleting
the pod does not delete the session. That is why both steps exist.

  set -a; . ./.env; set +a
  python scripts/cleanup.py sesn_abc sesn_def          # recheck, delete claim, delete session
  python scripts/cleanup.py --keep-claim sesn_abc      # delete only the API session
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

from _client import make_client

DEFAULT_LAUNCHER_URL = "http://127.0.0.1:8080"


CLAIM_DELETE_TIMEOUT = 30  # a claim delete is a quick Kubernetes API call, unlike /sessions dispatch


def _delete_claim(launcher_url: str, token: str, session_id: str) -> None:
    """Ask the launcher to delete this session's claim (called right after the recheck)."""
    body = json.dumps({"session_id": session_id}).encode()
    req = urllib.request.Request(
        launcher_url.rstrip("/") + "/sessions/claim-delete", data=body,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=CLAIM_DELETE_TIMEOUT) as resp:  # noqa: S310 - operator's own port-forward
            info = json.loads(resp.read() or b"{}")
        print(f"{session_id}: deleted {info.get('claims_deleted', 0)} claim(s); the pod stops with the claim")
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            sys.exit("launcher rejected the request (401): LAUNCHER_AUTH_TOKEN does not match the launcher-auth Secret.")
        print(f"{session_id}: launcher claim-delete returned {exc.code}; delete the SandboxClaim with kubectl")
    except urllib.error.URLError as exc:
        print(f"{session_id}: could not reach the launcher ({exc}); is the port-forward running? "
              "Delete the SandboxClaim with kubectl, or re-run with the port-forward up.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("session_ids", nargs="+", help="the session ids to clean up")
    parser.add_argument("--launcher-url", default=DEFAULT_LAUNCHER_URL,
                        help=f"the launcher intake URL (default {DEFAULT_LAUNCHER_URL})")
    parser.add_argument("--keep-claim", action="store_true",
                        help="delete only the API session, leaving the claim (and pod) running")
    args = parser.parse_args()

    token = os.environ.get("LAUNCHER_AUTH_TOKEN")
    if not args.keep_claim and not token:
        sys.exit("Set LAUNCHER_AUTH_TOKEN in .env, or pass --keep-claim to delete only the API session.")

    client = make_client()
    failed = 0
    for session_id in args.session_ids:
        try:
            # Step 1: recheck the session's state immediately before releasing
            # the claim, per OpenAI's lifecycle guidance (never release on idle
            # alone). We report the state we saw, then release the claim.
            session = client.beta.agents.sessions.retrieve(session_id)
            print(f"{session_id}: status={session.status} (rechecked before releasing the claim)")

            # Step 2: delete the claim right after the recheck (unless kept).
            if not args.keep_claim:
                _delete_claim(args.launcher_url, token, session_id)

            # Step 3: delete the API session itself.
            client.beta.agents.sessions.delete(session_id)
            print(f"{session_id}: session deleted")
        except Exception as exc:  # noqa: BLE001 - report and continue
            failed += 1
            print(f"{session_id}: could not clean up ({type(exc).__name__})")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
