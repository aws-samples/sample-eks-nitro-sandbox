"""Tests for scripts/_client.py: the SDK's own logs must not carry the response.

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
        b"HTTP/1.1 200 " + KEY.encode() + b" " + ESC.encode() + b" OK\\r\\n"
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
    elif os.environ["LOGGING_ON"] == "root-info-after-import":
        logging.basicConfig(level=logging.INFO)
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
    elif os.environ["LOGGING_ON"] == "root-info-after-import":
        logging.basicConfig(level=logging.INFO)
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
     # INFO, not DEBUG: httpx2 logs the response's reason phrase at INFO, so a
     # version of this fix that only looked for DEBUG left httpx2 at NOTSET and
     # leaked through it while passing every other case here.
     "root-info-after-import",
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


# The nine names, owned by this file. The probe below used to loop over
# _client.PROTECTED_LOGGERS itself, so deleting four of them from the module
# passed every case.
EXPECTED_PROTECTED_LOGGERS = (
    "openai",
    "openai._base_client",
    "httpx2",
    "httpcore2",
    "httpcore2.connection",
    "httpcore2.http11",
    "httpcore2.http2",
    "httpcore2.proxy",
    "httpcore2.socks",
)

# The versions the nine names were audited against. The sample pins only openai,
# so the transport and parser float; if one of them moves, the audit has to be
# redone rather than assumed, and this says so by failing.
EXPECTED_STACK = {"openai": "3.31.0", "httpx2": "2.16.0", "httpcore2": "2.16.0", "h11": "0.16.0"}

LEVEL_PROBE = '''\
import importlib.metadata as metadata
import json
import logging
import sys

logging.basicConfig(level={start_level})
sys.path.insert(0, {scripts!r})
import _client
_client.make_client()

print(json.dumps({{
    "names": list(_client.PROTECTED_LOGGERS),
    "levels": {{n: logging.getLogger(n).level for n in _client.PROTECTED_LOGGERS}},
    "versions": {{p: metadata.version(p) for p in ("openai", "httpx2", "httpcore2", "h11")}},
}}))
'''


def _probe(tmp_path, start_level):
    import json

    probe = tmp_path / "probe.py"
    probe.write_text(LEVEL_PROBE.format(scripts=str(SCRIPTS), start_level=start_level))
    environment = {
        name: value for name, value in os.environ.items()
        if not name.startswith(("OPENAI_", "PYTEST_"))
    }
    environment["OPENAI_API_KEY"] = KEY_SENTINEL
    result = subprocess.run(
        [sys.executable, str(probe)], cwd=tmp_path, env=environment,
        capture_output=True, text=True, timeout=120,
    )
    assert result.returncode == 0, result.stderr[-2000:]
    return json.loads(result.stdout)


def test_the_module_protects_exactly_the_audited_logger_names(tmp_path):
    assert tuple(_probe(tmp_path, "logging.DEBUG")["names"]) == EXPECTED_PROTECTED_LOGGERS


def test_the_audited_stack_is_the_installed_one(tmp_path):
    """If the transport or the parser moves, the logger audit is out of date.

    The sample pins openai and not its transport, so this is the thing that says
    "redo the audit" rather than letting a new version's logging go unexamined.
    """
    assert _probe(tmp_path, "logging.DEBUG")["versions"] == EXPECTED_STACK


def test_each_protected_logger_is_set_to_warning_from_a_lower_level(tmp_path):
    """Exactly WARNING, not merely at or above it.

    An earlier assertion of ">= WARNING" would have accepted a fix that set
    everything to CRITICAL, which would hide warnings a reader should see.
    """
    levels = _probe(tmp_path, "logging.DEBUG")["levels"]
    assert set(levels) == set(EXPECTED_PROTECTED_LOGGERS)
    assert all(level == logging.WARNING for level in levels.values()), levels


def test_a_stricter_level_already_in_force_is_kept(tmp_path):
    """The other direction, and a regression test.

    An earlier version ran the same call when the module was imported, which froze
    every logger at the default WARNING. A framework that then configured ERROR got
    WARNING records anyway, because the assignment reads the effective level and by
    then each logger had one of its own. With the call made only from
    make_client(), a stricter setting in force by then survives.
    """
    levels = _probe(tmp_path, "logging.ERROR")["levels"]
    assert all(level == logging.ERROR for level in levels.values()), levels


NOTE_DRIVER = '''\
import sys
sys.path.insert(0, {scripts!r})
import _client
_client.make_client()
'''


@pytest.mark.parametrize(
    "openai_log,expect_note",
    [(None, False), ("debug", True), ("info", True), ("warning", False),
     ("error", False), ("critical", False), ("", False), ("nonsense", False)],
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
