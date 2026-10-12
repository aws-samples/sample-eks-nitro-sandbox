"""``worker serve`` -- the sandbox's entrypoint: run one session's tool calls, then exit.

The SandboxWarmPool boots this container before any session exists, so it
cannot be told its session at start-up. It serves one HTTP POST on the dispatch
port instead. When the poller claims this sandbox it POSTs
``{session_id, work_id, work_secret}``, and the session goes to
``EnvironmentWorker.handle_item()``, which:

  * heartbeats the work item's lease in the background,
  * downloads the agent's skills into ``/workspace/skills/<name>/``,
  * runs the ``agent_toolset_20260401`` tools (bash, read, write, edit, glob,
    grep) in ``/workspace`` and posts each result back,
  * stops the work item when the session goes idle, and returns.

Every one of those calls uses the session's own token from ``work_secret``. The
sandbox holds no API key and no environment key, so a command the model runs
here cannot claim another session's work.

Then the process exits and the pod completes. The warm pool has already booted
a replacement.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import re
import signal
from http.server import BaseHTTPRequestHandler, HTTPServer

from anthropic.lib.environments import EnvironmentWorker

from . import client_factory, config, guard

log = logging.getLogger(__name__)

ID_RE = re.compile(r"^[A-Za-z0-9_\-]{1,128}$")
# The work secret is URL-safe base64 issued by Anthropic; it is opaque here.
SECRET_RE = re.compile(r"^[A-Za-z0-9_\-=]{1,16384}$")
MAX_BODY = 32 * 1024


class _Handler(BaseHTTPRequestHandler):
    """Accept exactly one well-formed dispatch POST."""

    def do_POST(self):  # noqa: N802 - stdlib naming
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_BODY:
                raise ValueError("bad length")
            body = json.loads(self.rfile.read(length))
            session_id, work_id = body["session_id"], body["work_id"]
            # Required: the session's token is the only credential this sandbox
            # gets. A dispatch without it is refused.
            work_secret = body["work_secret"]
            if not (ID_RE.match(session_id) and ID_RE.match(work_id)):
                raise ValueError("invalid id")
            if not (isinstance(work_secret, str) and SECRET_RE.match(work_secret)):
                raise ValueError("invalid secret")
        except Exception:
            self.send_response(400)
            self.end_headers()
            return
        self.send_response(202)
        self.end_headers()
        self.server.dispatch = {  # type: ignore[attr-defined]
            "session_id": session_id,
            "work_id": work_id,
            "work_secret": work_secret,
        }

    def log_message(self, *_):
        """No per-request access log."""


def _wait_for_dispatch(port: int) -> dict[str, str]:
    """Block until the poller POSTs a session, then return it."""
    httpd = HTTPServer(("0.0.0.0", port), _Handler)
    httpd.dispatch = None  # type: ignore[attr-defined]
    log.info("waiting for a dispatch on :%d", port)
    while httpd.dispatch is None:  # type: ignore[attr-defined]
        httpd.handle_request()
    httpd.server_close()
    return httpd.dispatch  # type: ignore[attr-defined]


async def _handle(dispatch: dict[str, str]) -> None:
    environment_id = config.require(config.ENV_ENVIRONMENT_ID)
    async with client_factory.make_session_client() as client:
        # No environment_key: handle_item then authenticates every call for
        # this item (heartbeat, stop, skills, tool events) with the sessions
        # token in work_secret, and fails the item if the secret has none.
        worker = EnvironmentWorker(client, workdir=config.WORKDIR)
        task = asyncio.create_task(
            worker.handle_item(
                work_id=dispatch["work_id"],
                environment_id=environment_id,
                session_id=dispatch["session_id"],
                work_secret=dispatch["work_secret"],
            )
        )
        # Cancelling (rather than killing) on SIGTERM lets the worker stop the
        # work item and upload changed memory files before the pod exits.
        loop = asyncio.get_running_loop()
        for signum in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(signum, task.cancel)
        with contextlib.suppress(asyncio.CancelledError):
            await task


def main() -> None:
    config.setup_logging()
    guard.assert_safe(guard.ROLE_SERVE)
    os.makedirs(config.WORKDIR, exist_ok=True)
    port = config.optional_int(config.ENV_DISPATCH_PORT, config.DEFAULT_DISPATCH_PORT)
    dispatch = _wait_for_dispatch(port)
    log.info("serving session %s in %s", dispatch["session_id"], config.WORKDIR)
    asyncio.run(_handle(dispatch))
    log.info("session %s finished", dispatch["session_id"])


if __name__ == "__main__":
    main()
