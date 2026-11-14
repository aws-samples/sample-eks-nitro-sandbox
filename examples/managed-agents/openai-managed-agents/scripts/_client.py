"""The OpenAI client the operator scripts use on your machine.

Uses your application key (OPENAI_API_KEY). This key creates agents and sessions
and reads them; it stays on this machine and never enters the cluster. The
cluster gets only the environment key (OPENAI_EXECUTOR_API_KEY), handed to each
sandbox at claim time by the launcher.
"""

from __future__ import annotations

import os
import sys

# Unset before the SDK is imported, because openai 3.31.0 reads OPENAI_LOG at
# import time and cannot be told to stop afterwards. At debug level it logs
# response headers verbatim, including x-request-id. Two things follow, and the
# second is the serious one:
#   - the endpoint OPENAI_BASE_URL selects controls that header, so it could put
#     terminal control sequences straight onto your terminal; and
#   - an endpoint that reflects the request headers it received back in that
#     header puts this machine's OPENAI_API_KEY, OPENAI_ORG_ID, OPENAI_PROJECT_ID
#     and OPENAI_CUSTOM_HEADERS on your terminal with it.
# This key is meant to stay on this machine, so the scripts run with SDK logging
# off and say so when they turn it off, rather than leaving that to the reader.
_SDK_LOG_SETTING = os.environ.pop("OPENAI_LOG", None)

from openai import OpenAI  # noqa: E402  -- must follow the line above


def make_client() -> OpenAI:
    """Return the client, or exit naming what is missing."""
    if _SDK_LOG_SETTING is not None:
        print(
            "[note] OPENAI_LOG was set; these scripts run with the SDK's own logging off,"
            " because at debug level it writes response headers out verbatim.",
            file=sys.stderr,
        )
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
