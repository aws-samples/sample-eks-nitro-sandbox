"""Tests for scripts/_client.py: the SDK must not copy response data to output.

Below WARNING, the SDK and its transport write parts of the response into their
own logs, and the endpoint OPENAI_BASE_URL selects chooses what is in those. The
three routes in the pinned packages, all exercised by the cases here:

    openai._base_client   DEBUG   the response's x-request-id, verbatim
    httpx2                INFO    the response's reason phrase, verbatim
    httpcore2.http11      DEBUG   whole response-header tuples

So an endpoint can put terminal control sequences in front of a reader, and one
that puts the reader's own application key in a response header -- by echoing the
request it received -- gets that written into their scrollback. The endpoint is not
*learning* the key; it was sent the key. What this closes is the local copy.

How the cases are built, and why:

- **Through make_client().** The client comes from the real factory, with the
  transport injected by replacing _client.OpenAI. An earlier version built
  openai.OpenAI directly, which tested only the import-time call: a make_client()
  mutated to put every logger back to DEBUG passed all thirteen cases while a
  real request leaked.
- **Over a real httpx2.HTTPTransport, with httpcore2.MockBackend behind it.** Not
  httpx2.MockTransport, which never reaches httpcore2 at all, so no case using it
  could exercise the transport routes that log the most.
- **Both ways, every request case.** Each runs with the protection and without it,
  so each shows the leak when it is absent as well as its absence when it is
  there. A case that only ran the protected path could not tell a working fix from
  an endpoint that sent nothing interesting.
- **Four ways the logging gets turned on**, including one configured *after*
  _client is imported. That last is a regression test: an earlier version only
  raised a level when the current one was already too low, which in the ordinary
  case set nothing, so a later basicConfig(level=DEBUG) re-enabled everything.

What these do not cover: logging configured after make_client() returns, which can
lower these levels again, and openai.lib.parsing, which logs response-supplied
values at WARNING -- above the floor. These scripts do not use that path.

Run with: python -m pytest tests/test_client.py
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import sys
from pathlib import Path

import pytest

pytest.importorskip("openai")
pytest.importorskip("httpx2")
pytest.importorskip("httpcore2")

TESTS = Path(__file__).resolve().parent
SAMPLE = TESTS.parent
SCRIPTS = SAMPLE / "scripts"

# Owned by this file. KEY_SENTINEL stands for the reader's application key coming
# back in a response header; ESC_SENTINEL is a control sequence in the same place.
# AGENT_ID is what a successful call returns, so a case cannot pass by never
# having made one.
KEY_SENTINEL = "sentinel-application-key-value"  # pragma: allowlist secret
ESC_SENTINEL = "\x1b]0;forged-title\x07"
AGENT_ID = "agent_ok"

DRIVER = '''\
import json
import logging
import os
import sys

SCRIPTS = {scripts!r}
KEY = {key!r}
AGENT_ID = {agent_id!r}
ESC = "\\x1b]0;forged-title\\x07"

if os.environ["LOGGING_ON"] == "root-debug-before":
    logging.basicConfig(level=logging.DEBUG)

import httpcore2
import httpx2


def transport():
    """A real httpx2 transport over a canned response, so httpcore2 runs for real."""
    body = json.dumps({{"id": AGENT_ID}}).encode()
    raw = (
        b"HTTP/1.1 200 " + ESC.encode() + b" OK\\r\\n"
        b"Content-Type: application/json\\r\\n"
        b"x-request-id: " + KEY.encode() + b" " + ESC.encode() + b"\\r\\n"
        b"Content-Length: " + str(len(body)).encode() + b"\\r\\n\\r\\n" + body
    )
    sender = httpx2.HTTPTransport()
    sender._pool._network_backend = httpcore2.MockBackend([raw])
    return sender


if os.environ["WITH_THE_SHARED_CLIENT"] == "1":
    if os.environ["IMPORT_ORDER"] == "openai-first":
        import openai  # as scripts/submit.py does
    sys.path.insert(0, SCRIPTS)
    import _client

    if os.environ["LOGGING_ON"] == "root-debug-after-import":
        logging.basicConfig(level=logging.DEBUG)
    elif os.environ["LOGGING_ON"] == "child-debug-after-import":
        logging.basicConfig()
        logging.getLogger("openai._base_client").setLevel(logging.DEBUG)
        logging.getLogger("httpcore2.http11").setLevel(logging.DEBUG)

    built = _client.OpenAI

    def factory(*args, **kwargs):
        kwargs["http_client"] = httpx2.Client(transport=transport())
        kwargs.setdefault("base_url", "http://api.openai.example/v1")
        return built(*args, **kwargs)

    _client.OpenAI = factory
    client = _client.make_client()
else:
    # No protection at all: what the routes do when nothing holds them back.
    import openai

    if os.environ["LOGGING_ON"] == "root-debug-after-import":
        logging.basicConfig(level=logging.DEBUG)
    elif os.environ["LOGGING_ON"] == "child-debug-after-import":
        logging.basicConfig()
        logging.getLogger("openai._base_client").setLevel(logging.DEBUG)
        logging.getLogger("httpcore2.http11").setLevel(logging.DEBUG)
    client = openai.OpenAI(
        api_key=KEY,
        base_url="http://api.openai.example/v1",
        http_client=httpx2.Client(transport=transport()),
    )

agent = client.beta.agents.retrieve(AGENT_ID)
print("RETURNED", agent.id)
'''


def _run(tmp_path, *, import_order, with_the_shared_client, logging_on):
    driver = tmp_path / "driver.py"
    driver.write_text(
        DRIVER.format(scripts=str(SCRIPTS), key=KEY_SENTINEL, agent_id=AGENT_ID)
    )
    environment = {
        name: value
        for name, value in os.environ.items()
        if not name.startswith(("OPENAI_", "PYTEST_"))
    }
    environment["OPENAI_API_KEY"] = KEY_SENTINEL
    environment["IMPORT_ORDER"] = import_order
    environment["WITH_THE_SHARED_CLIENT"] = "1" if with_the_shared_client else "0"
    environment["LOGGING_ON"] = logging_on
    if logging_on == "openai-log":
        environment["OPENAI_LOG"] = "debug"

    return subprocess.run(
        [sys.executable, str(driver)], cwd=tmp_path, env=environment,
        capture_output=True, text=True, timeout=120,
    )


IMPORT_ORDERS = pytest.mark.parametrize(
    "import_order", ["openai-first", "client-first"], ids=["as-submit", "as-setup-agent"]
)
LOGGING_ROUTES = pytest.mark.parametrize(
    "logging_on",
    ["openai-log", "root-debug-before", "root-debug-after-import",
     # A logger given its own level is checked instead of its parent's, so a fix
     # that pinned only the parents would leave this one open.
     "child-debug-after-import"],
)


@IMPORT_ORDERS
@LOGGING_ROUTES
def test_the_shared_client_keeps_the_response_out_of_the_output(
    tmp_path, import_order, logging_on
):
    result = _run(
        tmp_path, import_order=import_order, with_the_shared_client=True,
        logging_on=logging_on,
    )
    written = result.stdout + result.stderr

    assert result.returncode == 0, written[-2000:]
    # The call happened and returned, so this is about what was logged.
    assert f"RETURNED {AGENT_ID}" in result.stdout
    assert KEY_SENTINEL not in result.stderr
    assert ESC_SENTINEL not in written


@IMPORT_ORDERS
@LOGGING_ROUTES
def test_without_the_shared_client_the_response_reaches_the_output(
    tmp_path, import_order, logging_on
):
    # The other half of each case above. If this stops leaking, those stop being
    # evidence, and this says so.
    result = _run(
        tmp_path, import_order=import_order, with_the_shared_client=False,
        logging_on=logging_on,
    )
    written = result.stdout + result.stderr

    assert result.returncode == 0, written[-2000:]
    assert f"RETURNED {AGENT_ID}" in result.stdout
    assert KEY_SENTINEL in result.stderr
    assert ESC_SENTINEL in result.stderr


LEVEL_PROBE = '''\
import logging
import sys

logging.basicConfig(level=logging.DEBUG)
sys.path.insert(0, {scripts!r})
import _client

logging.basicConfig(level=logging.DEBUG)   # again, after the import
_client.silence_sdk_logging()

for name in _client.PROTECTED_LOGGERS:
    # The logger's OWN level, not the effective one: an effective level can come
    # from an ancestor that something else raised, which would make this pass
    # while these loggers were never pinned at all.
    print(name, logging.getLogger(name).level)
'''


def test_every_protected_logger_has_its_own_level_at_or_above_warning(tmp_path):
    """The mechanism, asserted on each logger's own level.

    Kept as a mechanism check beside the request cases above, not as a substitute
    for them: an earlier version of this file had only this, comparing effective
    levels, and a version of the fix that never pinned httpx2 or httpcore2 passed
    it because they inherited a root level something else had raised.
    """
    probe = tmp_path / "probe.py"
    probe.write_text(LEVEL_PROBE.format(scripts=str(SCRIPTS)))

    result = subprocess.run(
        [sys.executable, str(probe)], cwd=tmp_path, capture_output=True, text=True, timeout=120,
    )

    assert result.returncode == 0, result.stderr[-2000:]
    levels = {
        name: int(level)
        for name, level in (line.split() for line in result.stdout.strip().splitlines())
    }
    assert levels, result.stdout
    for name, level in levels.items():
        assert level >= logging.WARNING, f"{name} has its own level at {level}"
    # And the set is the one the module says it protects, including the children
    # that do the logging rather than only their parents.
    assert {"openai._base_client", "httpx2", "httpcore2.http11"} <= set(levels)


NOTE_DRIVER = '''\
import sys
sys.path.insert(0, {scripts!r})
import _client
_client.make_client()
'''


@pytest.mark.parametrize(
    "openai_log,expect_note",
    [(None, False), ("debug", True), ("info", True), ("warning", False),
     ("error", False), ("", False), ("nonsense", False)],
)
def test_the_note_appears_exactly_for_the_values_it_changes_something_for(
    tmp_path, openai_log, expect_note
):
    """Told, not silently overridden -- and only where there is something to tell.

    The SDK recognises debug, info, warning, error and critical. Only the first
    two ask for something below the floor these scripts hold, so only those two
    get a note; an empty or unrecognised value turns nothing on, and warning and
    stricter are already at or above it.
    """
    driver = tmp_path / "note.py"
    driver.write_text(NOTE_DRIVER.format(scripts=str(SCRIPTS)))
    environment = {
        name: value
        for name, value in os.environ.items()
        if not name.startswith(("OPENAI_", "PYTEST_"))
    }
    environment["OPENAI_API_KEY"] = KEY_SENTINEL
    if openai_log is not None:
        environment["OPENAI_LOG"] = openai_log

    result = subprocess.run(
        [sys.executable, str(driver)], cwd=tmp_path, env=environment,
        capture_output=True, text=True, timeout=120,
    )

    assert result.returncode == 0, result.stderr[-2000:]
    assert result.stdout == ""
    if expect_note:
        assert "these scripts hold the SDK's own" in result.stderr
        assert f"OPENAI_LOG={openai_log}" in result.stderr
        assert KEY_SENTINEL not in result.stderr
    else:
        assert result.stderr == ""
