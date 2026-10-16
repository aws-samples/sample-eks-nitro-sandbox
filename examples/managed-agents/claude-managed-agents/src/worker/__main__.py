"""Entry point: ``python -m worker <poll|serve|stats>``.

One image with three roles, selected by the container's ``args``:

  * ``poll``  -- the poller Deployment: claims sessions from the work queue and
    hands each one to a warm sandbox.
  * ``serve`` -- the SandboxTemplate container: waits for one dispatch, runs that
    session's tool calls, then exits.
  * ``stats`` -- the optional autoscaler: sizes the warm pool from queue depth.
"""

from __future__ import annotations

import sys


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    command = argv[0] if argv else None

    if command == "poll":
        from . import poller

        poller.main()
        return 0

    if command == "serve":
        from . import serve

        serve.main()
        return 0

    if command == "stats":
        from . import stats_adapter

        stats_adapter.main()
        return 0

    print(
        "usage: python -m worker <command>\n\n"
        "commands:\n"
        "  poll    claim sessions and dispatch each one to a warm sandbox\n"
        "  serve   wait for one dispatch, run that session's tool calls, then exit\n"
        "  stats   size the warm pool from work-queue depth\n",
        file=sys.stderr,
    )
    return 0 if command in (None, "-h", "--help", "help") else 2


if __name__ == "__main__":
    raise SystemExit(main())
