"""The OpenAI client the operator scripts use on your machine.

Uses your application key (OPENAI_API_KEY). This key creates agents and sessions
and reads them; it stays on this machine and never enters the cluster. The
cluster gets only the environment key (OPENAI_EXECUTOR_API_KEY), handed to each
sandbox at claim time by the launcher.
"""

from __future__ import annotations

import logging
import os
import sys

from openai import OpenAI

# The SDK and its transport write response data to their own loggers, at DEBUG.
# openai's own request_id line prints the response's x-request-id header verbatim,
# and httpcore2 logs whole response-header tuples. Both are chosen by whatever
# endpoint OPENAI_BASE_URL selects, so both can put control sequences on the
# terminal, and an endpoint that echoes the request's Authorization header back in
# a response header writes this machine's application key into the reader's
# scrollback. (It does not learn the key that way -- it was sent the key -- but
# this sample's page says the key stays on this machine, and terminal output from
# samples ends up in workshop transcripts and CI logs.)
#
# Note what the SDK does and does not protect: SensitiveHeadersFilter redacts
# api-key, authorization and x-amz-security-token in logged *request* headers, and
# nothing redacts a response header. Its own comment says transport loggers are
# left to the application, which is why httpcore2 is a separate route.
#
# Raising the level on these three parents is what stops it, rather than unsetting
# OPENAI_LOG: a logger's level is checked before a record is made, children with
# no level of their own inherit it, and -- the part that matters -- this works
# whichever order the importing script happens to use. Unsetting OPENAI_LOG only
# works if it runs before `import openai`, and two of this sample's three scripts
# import openai first. WARNING rather than CRITICAL, so a genuine warning still
# reaches the reader; propagate is left alone for the same reason.
SILENCED_SDK_LOGGERS = ("openai", "httpx2", "httpcore2")


def silence_sdk_logging() -> None:
    """Stop the SDK and its transport logging response data to the terminal."""
    for name in SILENCED_SDK_LOGGERS:
        logger = logging.getLogger(name)
        if logger.getEffectiveLevel() < logging.WARNING:
            logger.setLevel(logging.WARNING)


# At import, so that it has happened before any script here can make a request,
# and so a script that imports openai first is covered too.
silence_sdk_logging()


def make_client() -> OpenAI:
    """Return the client, or exit naming what is missing."""
    if os.environ.get("OPENAI_LOG") is not None:
        # Said rather than done silently: a reader who asked for debug logging
        # should know why they are not getting the SDK's. Only this variable is
        # mentioned, because it is the one a reader sets on purpose; logging
        # configured by a surrounding process is silenced the same way without a
        # note, since there is nobody to tell.
        print(
            "[note] OPENAI_LOG is set. These scripts hold the SDK's own logging at WARNING,"
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
