"""Entry point: ``python -m launcher <launch|serve>``.

One image, two roles, selected by the container's ``args``:

  * ``launch`` -- the launcher Deployment: takes a session the operator submits
    and claims a warm sandbox for it.
  * ``serve``  -- the SandboxTemplate container: waits for one dispatch, runs
    that session's ``codex exec-server``, then exits.
"""

from __future__ import annotations

import sys


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    command = argv[0] if argv else None

    if command == "launch":
        from . import launch

        launch.main()
        return 0

    if command == "serve":
        from . import serve

        serve.main()
        return 0

    print(
        "usage: python -m launcher <command>\n\n"
        "commands:\n"
        "  launch  take a submitted session and claim a warm sandbox for it\n"
        "  serve   wait for one dispatch, run that session's codex exec-server, then exit\n",
        file=sys.stderr,
    )
    return 0 if command in (None, "-h", "--help", "help") else 2


if __name__ == "__main__":
    raise SystemExit(main())
