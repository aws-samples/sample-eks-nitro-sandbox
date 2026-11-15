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

# Below WARNING, the SDK and its transport copy parts of the response into their
# own logs, and the endpoint OPENAI_BASE_URL selects chooses what is in those. The
# three routes in the pinned stack, which the comments on the names below repeat:
#
#   openai._base_client  DEBUG  the response's x-request-id, verbatim
#   httpx2               INFO   the response's reason phrase, verbatim
#   httpcore2.http11     DEBUG  whole response-header tuples, through repr()
#
# The first two put those bytes through unchanged, so a control sequence in them
# reaches the terminal as one. httpcore2's repr() escapes a control sequence, but
# leaves a credential readable. An endpoint that echoes the request's Authorization
# header back in a response header therefore gets this machine's application key
# into the reader's scrollback. (It does not learn the key that way -- it was sent
# the key -- but this sample's page says the key stays on this machine, and sample
# output ends up in workshop transcripts and CI logs.)
#
# Note what the SDK does and does not protect: SensitiveHeadersFilter redacts
# api-key, authorization and x-amz-security-token in logged *request* headers, and
# nothing redacts a response header. setup_logging()'s own comment says transport
# loggers are left to the application, which is why httpcore2 is a separate route
# that OPENAI_LOG never governed.
#
# Raising these loggers' own levels is what stops it, rather than unsetting
# OPENAI_LOG: a logger's level is checked before a record is made, and this holds
# whichever order the importing script uses. Unsetting OPENAI_LOG works only when
# it runs before `import openai`, and submit.py imports openai first.
#
# Three earlier attempts at this got it wrong in ways worth leaving written down:
#   - unsetting OPENAI_LOG: one of the four cases tests/test_client.py covers.
#   - `if getEffectiveLevel() < WARNING: setLevel(WARNING)`: sets nothing at all in
#     the ordinary case, because the inherited root level is already WARNING, so
#     the logger keeps NOTSET and a later basicConfig(level=DEBUG) re-enables it.
#   - pinning the parents only: a child given an explicit level of its own is
#     checked instead of its parent.
#
# What this is NOT: a floor. It is one threshold assignment at the moment
# make_client() runs. Anything that reconfigures these loggers afterwards -- a
# framework, a notebook cell, a dictConfig -- can lower them again, and nothing
# here watches for that. Three further boundaries, stated rather than implied:
# openai.lib.parsing logs response-supplied values at WARNING, above this
# threshold, and these scripts do not use that path; a stricter level that is
# already in force is kept, but an ancestor's stricter level does not filter a
# record these loggers emit, which is why the assignment reads the effective level
# at the time; and all of this assumes one unchanged standard-library logging
# registry, so reloading the logging module between the SDK's import and this call
# would leave the SDK holding logger objects this never sees.
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
    """Set the SDK's and its transport's own loggers to WARNING, or leave stricter."""
    for name in PROTECTED_LOGGERS:
        logger = logging.getLogger(name)
        logger.setLevel(max(logger.getEffectiveLevel(), logging.WARNING))


def make_client() -> OpenAI:
    """Return the client, or exit naming what is missing."""
    # Here and nowhere else. An earlier version also ran this when the module was
    # imported, which looked like belt and braces and was worse than useless: it
    # froze each logger at the default WARNING, so a framework that then asked for
    # ERROR got WARNING records anyway, because this reads the effective level and
    # by then the logger had one of its own. Doing it once, at the point a script
    # actually asks for a client, is both sufficient and the right boundary for an
    # imported module to mutate process-global state at.
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
