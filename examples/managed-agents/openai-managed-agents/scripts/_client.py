"""The OpenAI client the operator scripts use on your machine.

Uses your application key (OPENAI_API_KEY). This key creates agents and sessions
and reads them; it stays on this machine and never enters the cluster. The
cluster gets only the environment key (OPENAI_EXECUTOR_API_KEY), handed to each
sandbox at claim time by the launcher.
"""

from __future__ import annotations

import os
import sys

from openai import OpenAI


def make_client() -> OpenAI:
    """Return the client, or exit naming what is missing."""
    if not os.environ.get("OPENAI_API_KEY"):
        sys.exit("Set OPENAI_API_KEY to your application key (on this machine only).")

    # `set -a; . ./.env` exports blank optional values too. OpenAI 3.31.0
    # treats OPENAI_BASE_URL="" as an explicit URL and fails before making a
    # request, so normalize a blank override to "not set". Pass a real
    # override explicitly instead of relying on SDK environment parsing.
    base_url = os.environ.get("OPENAI_BASE_URL")
    if base_url:
        return OpenAI(base_url=base_url)
    os.environ.pop("OPENAI_BASE_URL", None)
    return OpenAI()
