#!/usr/bin/env python3
"""Read the environment's work-queue stats. Run on your machine.

workers_polling should be 1 or more once the poller is running.

  set -a; . ./.env; set +a
  python scripts/stats.py
"""

from __future__ import annotations

import os
import sys

from anthropic import Anthropic


def main() -> None:
    environment_id = os.environ.get("ANTHROPIC_ENVIRONMENT_ID")
    if not environment_id or not os.environ.get("ANTHROPIC_API_KEY"):
        sys.exit("Set ANTHROPIC_API_KEY and ANTHROPIC_ENVIRONMENT_ID (see .env.example).")
    stats = Anthropic().beta.environments.work.stats(environment_id)
    print(f"workers_polling: {stats.workers_polling}")
    print(f"depth:           {stats.depth}  (waiting to be picked up)")
    print(f"pending:         {stats.pending}  (polled, not yet acknowledged)")
    if not stats.workers_polling:
        print("\nNo worker is polling. Check the poller: kubectl logs deploy/claude-poller")


if __name__ == "__main__":
    main()
