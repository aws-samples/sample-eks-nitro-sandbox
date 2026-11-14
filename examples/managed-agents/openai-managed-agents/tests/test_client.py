"""Tests for scripts/_client.py: the SDK must not log response data.

The SDK and its transport log at DEBUG, and what they log is chosen by whatever
endpoint OPENAI_BASE_URL selects:

- openai's own `request_id:` line prints the response's x-request-id verbatim; and
- httpcore2 logs whole response-header tuples.

So an endpoint can put terminal control sequences on the reader's terminal, and
one that echoes the request's Authorization header back in a response header
writes the application key into their scrollback. The endpoint is not *learning*
the key -- it was sent it -- but this sample's page says that key stays on the
reader's machine, and sample output ends up in workshop transcripts and CI logs.

Each case runs in a subprocess, because the thing under test is logger and import
state: a test in this process would be measuring whatever has already imported
openai. The cases cover the import orders the three real entrypoints use --
setup_agent.py and submit.py import openai *before* _client, cleanup.py imports
_client first -- because an earlier version of this fix only worked in the second
order and the first is the one two scripts actually use.

Both ways throughout: every case runs with and without _client imported, so each
shows the leak when the fix is absent as well as its absence when the fix is
there. A case that only ran the fixed path could not tell a working fix from an
endpoint that never reflected anything.

Run with: python -m pytest tests/test_client.py
"""

from __future__ import annotations

import logging
import os
import subprocess
import sys
from pathlib import Path

import pytest

pytest.importorskip("openai")
pytest.importorskip("httpx2")

TESTS = Path(__file__).resolve().parent
SAMPLE = TESTS.parent
SCRIPTS = SAMPLE / "scripts"

# Owned by this file. The key sentinel is what a reflecting endpoint sends back;
# REACHED is printed by the fake endpoint itself, so a case cannot pass by the
# driver exiting before it ever made a request.
KEY_SENTINEL = "sentinel-application-key-value"  # pragma: allowlist secret
REACHED = "THE-REQUEST-REACHED-THE-ENDPOINT"
ESCAPE = "\x1b"

DRIVER = '''\
import logging
import os
import sys

SCRIPTS = {scripts!r}
KEY = {key!r}
REACHED = {reached!r}

if os.environ["ROOT_DEBUG"] == "1":
    # An embedding process, a wrapper or a sitecustomize can do this, and it
    # enables the SDK's and the transport's loggers without OPENAI_LOG.
    logging.basicConfig(level=logging.DEBUG)


def import_the_shared_client():
    if os.environ["WITH_THE_SHARED_CLIENT"] == "1":
        sys.path.insert(0, SCRIPTS)
        import _client  # noqa: F401


# The orders the real entrypoints use.
if os.environ["IMPORT_ORDER"] == "openai-first":
    import openai  # as scripts/setup_agent.py and scripts/submit.py do
    import_the_shared_client()
else:
    import_the_shared_client()  # as scripts/cleanup.py does
    import openai

import httpx2 as httpx


def handler(request):
    # Printed by the endpoint, so its absence means no request was made.
    print(REACHED)
    reflected = request.headers.get("authorization", "")
    return httpx.Response(
        200,
        json={{"id": "agent_ok"}},
        headers={{"x-request-id": reflected + " \\x1b]0;forged-title\\x07"}},
    )


client = openai.OpenAI(
    api_key=KEY,
    base_url="https://api.openai.example/v1",
    http_client=httpx.Client(transport=httpx.MockTransport(handler)),
)
client.beta.agents.retrieve("agent_ok")
'''


def _run(tmp_path, *, import_order, with_the_shared_client, how_logging_is_on):
    driver = tmp_path / "driver.py"
    driver.write_text(
        DRIVER.format(scripts=str(SCRIPTS), key=KEY_SENTINEL, reached=REACHED)
    )
    environment = {
        name: value
        for name, value in os.environ.items()
        if not name.startswith(("OPENAI_", "PYTEST_"))
    }
    environment["IMPORT_ORDER"] = import_order
    environment["WITH_THE_SHARED_CLIENT"] = "1" if with_the_shared_client else "0"
    environment["ROOT_DEBUG"] = "1" if how_logging_is_on == "root-debug" else "0"
    if how_logging_is_on == "openai-log":
        environment["OPENAI_LOG"] = "debug"

    result = subprocess.run(
        [sys.executable, str(driver)], cwd=tmp_path, env=environment,
        capture_output=True, text=True, timeout=120,
    )
    return result


IMPORT_ORDERS = pytest.mark.parametrize(
    "import_order",
    ["openai-first", "client-first"],
    ids=["as-setup-agent-and-submit", "as-cleanup"],
)
LOGGING_ROUTES = pytest.mark.parametrize(
    "how_logging_is_on", ["openai-log", "root-debug"]
)


@IMPORT_ORDERS
@LOGGING_ROUTES
def test_the_shared_client_stops_the_leak(tmp_path, import_order, how_logging_is_on):
    result = _run(
        tmp_path, import_order=import_order, with_the_shared_client=True,
        how_logging_is_on=how_logging_is_on,
    )
    written = result.stdout + result.stderr

    assert result.returncode == 0, written[-2000:]
    # The request was made, so this case is about what was logged and not about a
    # driver that stopped early.
    assert REACHED in result.stdout
    assert KEY_SENTINEL not in result.stderr
    assert ESCAPE not in written


@IMPORT_ORDERS
@LOGGING_ROUTES
def test_without_the_shared_client_the_leak_is_there(tmp_path, import_order, how_logging_is_on):
    # The other half: the same endpoint, the same logging, no shared client. If
    # this ever stops leaking, the cases above are no longer evidence of anything
    # and this fails to say so.
    result = _run(
        tmp_path, import_order=import_order, with_the_shared_client=False,
        how_logging_is_on=how_logging_is_on,
    )

    assert result.returncode == 0, (result.stdout + result.stderr)[-2000:]
    assert REACHED in result.stdout
    assert KEY_SENTINEL in result.stderr
    assert ESCAPE in result.stderr


NOTE_DRIVER = '''\
import sys
sys.path.insert(0, {scripts!r})
import _client
_client.make_client()
'''


@pytest.mark.parametrize("openai_log", [None, "debug", "", "nonsense"])
def test_the_note_appears_exactly_when_openai_log_is_set(tmp_path, openai_log):
    """Told, not silently overridden -- and only for the variable a reader sets.

    Including the values the SDK itself ignores: an empty or unrecognised
    OPENAI_LOG enables no logging, but a reader who set it still asked for
    something they are not getting, so the note is about their having set it
    rather than about what the SDK would have done with it.
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
    if openai_log is None:
        assert result.stderr == ""
    else:
        assert "OPENAI_LOG is set" in result.stderr
        # Never the value, and never the key the client was built with.
        assert KEY_SENTINEL not in result.stderr
    assert result.stdout == ""


LEVEL_PROBE = '''\
import logging
import sys

logging.basicConfig(level=logging.DEBUG)
sys.path.insert(0, {scripts!r})
import _client

for name in _client.SILENCED_SDK_LOGGERS:
    print(name, logging.getLogger(name).getEffectiveLevel())
# A child with no level of its own must inherit the raised one.
print("openai._base_client", logging.getLogger("openai._base_client").getEffectiveLevel())
print("httpcore2.http11", logging.getLogger("httpcore2.http11").getEffectiveLevel())
'''


def test_the_silenced_loggers_end_up_above_debug_even_under_root_debug(tmp_path):
    """The mechanism itself, including the transport route a mock cannot exercise.

    httpx2's MockTransport never goes through httpcore2, so no end-to-end case
    here can show that route; what it rests on is the logger level, so that is
    asserted directly rather than claimed.
    """
    probe = tmp_path / "probe.py"
    probe.write_text(LEVEL_PROBE.format(scripts=str(SCRIPTS)))

    result = subprocess.run(
        [sys.executable, str(probe)], cwd=tmp_path, capture_output=True, text=True, timeout=120,
    )

    assert result.returncode == 0, result.stderr[-2000:]
    levels = dict(
        (name, int(level)) for name, level in
        (line.split() for line in result.stdout.strip().splitlines())
    )
    assert set(levels) >= {"openai", "httpx2", "httpcore2", "openai._base_client", "httpcore2.http11"}
    for name, level in levels.items():
        assert level >= logging.WARNING, f"{name} is at {level}, below WARNING"
