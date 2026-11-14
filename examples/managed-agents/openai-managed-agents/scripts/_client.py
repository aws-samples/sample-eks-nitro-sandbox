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
# Raising these loggers' own level is what stops it, rather than unsetting
# OPENAI_LOG: a logger's level is checked before a record is made, and this holds
# whichever order the importing script happens to use. Unsetting OPENAI_LOG works
# only when it runs before `import openai`, and submit.py imports openai first.
#
# Each name is pinned, parents and the children that do the logging, and the level
# is always set rather than only when it is currently too low. Both matter, and an
# earlier version of this got both wrong:
#   - `if getEffectiveLevel() < WARNING: setLevel(WARNING)` sets nothing at all in
#     the ordinary case, because the inherited root level is already WARNING. The
#     logger keeps NOTSET, and a later logging.basicConfig(level=DEBUG) -- a
#     framework, a wrapper, a notebook -- makes it inherit DEBUG again.
#   - pinning only the parents leaves a child that is given an explicit level of
#     its own, which is checked instead of the parent's.
# `max(getEffectiveLevel(), WARNING)` keeps a stricter setting a reader chose.
#
# WARNING rather than CRITICAL, and propagate left alone, so a genuine warning
# still reaches the reader. The boundary that remains: logging configured *after*
# make_client() returns can lower these again, and openai.lib.parsing logs
# response-supplied values at WARNING, which this floor does not suppress. These
# scripts do not use that parsing path; the claim here is about their own routes,
# not about the SDK as a whole.
PROTECTED_LOGGERS = (
    "openai",
    "openai._base_client",          # DEBUG: the response's x-request-id, verbatim
    "httpx2",                       # INFO: the response's reason phrase, verbatim
    "httpcore2",
    "httpcore2.connection",
    "httpcore2.http11",             # DEBUG: whole response-header tuples
    "httpcore2.http2",
    "httpcore2.proxy",
    "httpcore2.socks",
)


def silence_sdk_logging() -> None:
    """Hold the SDK's and its transport's own loggers at WARNING or stricter."""
    for name in PROTECTED_LOGGERS:
        logger = logging.getLogger(name)
        logger.setLevel(max(logger.getEffectiveLevel(), logging.WARNING))


# At import, so it has happened before an importing script can make a request,
# and again in make_client() below, which is after any logging a surrounding
# framework sets up on its way to calling it.
silence_sdk_logging()


def make_client() -> OpenAI:
    """Return the client, or exit naming what is missing."""
    # Again here, not only at import: whatever calls this may have configured
    # logging in between, and the last word on these loggers should be ours.
    silence_sdk_logging()
    if os.environ.get("OPENAI_LOG") in ("debug", "info"):
        # Said rather than done silently: a reader who asked for debug or info
        # logging should know why they are not getting the SDK's. Only those two
        # values, because they are the only ones this changes anything for -- the
        # SDK recognises debug, info, warning, error and critical, and the last
        # three are at or stricter than the floor below. An empty or unrecognised
        # value turns nothing on, so there is nothing to explain. Logging that a
        # surrounding process configured is held the same way without a note,
        # since there is nobody to tell.
        print(
            f"[note] OPENAI_LOG={os.environ['OPENAI_LOG']}: these scripts hold the SDK's own"
            " logging, and its transport's, at WARNING, because below that they copy parts of"
            " the response -- which the endpoint chooses -- into their output.",
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
