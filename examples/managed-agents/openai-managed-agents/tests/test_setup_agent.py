"""Tests for scripts/setup_agent.py, run the way step 2 of the page runs it.

Each case copies this sample folder (without any .env, .venv or caches) to a
temporary folder and does step 2 there, literally:

- writes `.env` from `.env.example`, filling in only the two keys step 2 tells
  the reader to fill (OPENAI_API_KEY and OPENAI_EXECUTOR_API_KEY, with sentinel
  values), and with the AGENT_ID= and AGENT_MODEL= lines blank, set or removed
  as the case says;
- replaces scripts/_client.py with a fake that records every call and answers as
  the case says (the one deliberate difference from a reader's run);
- puts a `.venv/bin/python` in the copy that runs this interpreter; and
- runs `set -a; . ./.env; set +a; .venv/bin/python scripts/setup_agent.py` with
  /bin/sh in that folder, in the caller's environment minus anything the .env
  sets and any OPENAI_*, AGENT_*, PYTHON* or PYTEST_* variable (and COLUMNS and
  LINES, which a shell does not export).

Every case runs twice: with stdout and stderr piped, so each stream can be
compared on its own, and on one pseudo-terminal of 24 rows by 80 columns, in its
default configuration, as the controlling terminal of a new session with the
program in the foreground, carrying stdin, stdout and stderr, as when a reader
runs it in a terminal.

It then compares, exactly, against text this file owns:

- everything the program shows (piped: the entire stdout and the entire
  stderr; terminal: every byte the terminal received) and its exit status, so
  anything a reader would see beyond the expected text fails, whatever channel
  it came by; and
- the ordered list of every call the program made on the fake client, with
  every argument, so a missing, extra, repeated or changed API call fails.

So the claim is about this copy of step 2 as described above, and its scope
ends where that description does. A program written to detect where it runs
can always tell this from a reader's machine, by anything that differs between
the two: the folder path, the user, the time, which terminal it is, or any
file or variable a reader has that the copy does not. Such a program can
change what it shows on that difference, and these tests cannot see it; no
test can, because a reader's machine is not available to it. What the tests
do show is that setup_agent.py shows exactly the expected text, and makes
exactly the expected calls, for the environment states and faked API outcomes
enumerated below, piped and on a terminal. Not "every situation step 2 can
produce": round 9 of the second review made that wording false by reaching, with
the real SDK and a mock transport, a returned agent id no scenario here had --
which is why the id's own grammar is now checked in the script rather than
assumed from the shapes listed here.

What this does not cover beyond that: the real scripts/_client.py, which is
replaced (so almost nothing here tests the real one; the exception is the
subprocess case below for the SDK logging route, which imports it); an interactive shell's own behaviour, since the commands run
under `sh -c`; and anything the program writes somewhere other than its stdout
and stderr, such as a file.

Both ways, per AGENTS.md, for every combination of AGENT_ID and AGENT_MODEL
being unset, blank and set: an agent the lookup returns is kept and nothing is
created; with AGENT_ID blank or unset an agent is created and nothing is looked
up, with the placeholder note exactly when no model is given, including when the
model given is the placeholder id itself; a 404 stops with a message that lists
what to check before saying how to clear AGENT_ID, without claiming the agent is
gone; a lookup that succeeds without this agent's id stops; and neither the
response body nor the request-id header is ever shown.

Every way a lookup can fail **with an SDK APIError** stops the run and names the
error by its exception class and, when it has one, its HTTP status. That is a
claim about a known set, not about the handful of classes that came to mind:
_fake_outcomes.py raises one of every openai.APIError subclass **loaded** in the
installed SDK, and the coverage tests compare class objects rather than class
names. Both limits are deliberate and were found by round 9: a subclass defined
in a module nobody has imported is invisible to __subclasses__(), and the earlier
name-based comparison missed a distinct subclass sharing a covered one's name.

A lookup can also fail with something that is not an APIError at all -- round 11
reached ValueError, UnicodeEncodeError and JSONDecodeError from inside the SDK and
httpx2 -- and those do not reach _describe. They stop the run through the handler
around main(), which prints an exception class name and nothing else; there is one
case for that below, and it is the only thing claimed about that path.

The create path carries the same full set, asserted **separately** from the
lookup path rather than pooled with it, so neither path's coverage can be
satisfied by the other's cases. A create that raises any of those classes stops
with the error named and nothing the server sent, and every create error that
carries a response is planted with both values a proxy controls, so each case
proves the absence of a leak as well as the message.

A create that succeeds without an id this step may print also stops, saying the
agent may exist: no attribute, None, blank, or not a string, and -- since the
printed line is a shell assignment the reader loads with
`set -a; . ./.env; set +a` -- any string outside the emission allowlist. Round 9
demonstrated that end to end: an id of `$(touch ...)` was printed, pasted and run.

Three things about that allowlist, so these tests are not read as claiming more
than they show. It is a limit on what this program will emit, not a description
of what the API issues: the pinned SDK types that field as a plain `str`, so
nothing here establishes a prefix, an alphabet or a length, and a case asserting
a rejection is not asserting that the value was dangerous. "." and ".." are
refused for a different reason from the rest, which is pinned by its own test
against the real SDK rather than the fake: they are shell-safe, but the SDK
raises ValueError on them while building the request path, and ValueError is not
an APIError, so they would surface as a traceback. And an over-length id is
refused while being perfectly shell-safe.

The same reasoning covers AGENT_MODEL, by a route round 10 found rather than one
anticipated here. The model used to be interpolated into every refusal message as
well as the success line, so a .env value could add lines to this step's own
output, including one reading exactly like the line the page tells the reader to
paste. Round 11 then forged such a line with no control character at all, using
ordinary letters and spaces long enough that the terminal's own wrapping began a
row with it -- so a byte-level check was not enough. The refusal messages no
longer carry the model at all, and the one line that still does holds it to a
short token with no whitespace. Stated as it is rather than as closed: that
defeats the indented forgery, and on a narrow enough terminal a wrapped row can
still begin with this value unindented. The cases below forge a line against the
script with that check cut out.

Run with: python -m pytest
"""

from __future__ import annotations

import fcntl
import json
import os
import pty
import select
import shutil
import struct
import subprocess
import sys
import termios
import time
from pathlib import Path

import pytest

pytest.importorskip("openai")
pytest.importorskip("httpx2")

TESTS = Path(__file__).resolve().parent
SAMPLE = TESTS.parent
SCRIPT = SAMPLE / "scripts" / "setup_agent.py"
OUTCOMES = TESTS / "_fake_outcomes.py"
PAGE_COMMANDS = "set -a; . ./.env; set +a; .venv/bin/python scripts/setup_agent.py"

sys.path.insert(0, str(TESTS))
try:
    import _fake_outcomes as outcomes
finally:
    sys.path.remove(str(TESTS))

FAKE_CLIENT = '''\
"""Fake _client for one test case: records every call, answers as the case says."""
import json

from _fake_outcomes import create, lookup

LEDGER = {ledger!r}
SCENARIO = {scenario!r}
CREATE_SCENARIO = {create_scenario!r}


def _record(method, args, kwargs):
    with open(LEDGER, "a") as ledger:
        ledger.write(json.dumps([method, list(args), kwargs]) + "\\n")


class _Agents:
    def retrieve(self, *args, **kwargs):
        _record("retrieve", args, kwargs)
        outcome = lookup(SCENARIO, args[0] if args else None)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome

    def create(self, *args, **kwargs):
        _record("create", args, kwargs)
        outcome = create(CREATE_SCENARIO)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome


class _Beta:
    agents = _Agents()


class _Client:
    beta = _Beta()


def make_client(*args, **kwargs):
    _record("make_client", args, kwargs)
    return _Client()
'''

# ---------------------------------------------------------------------------
# What a reader must see, owned by this file
# ---------------------------------------------------------------------------

NOT_FOUND = (
    "The lookup of agent agent_kept from AGENT_ID returned HTTP 404, so it was not kept.\n"
    "A 404 does not show that the agent was deleted. The same answer comes from a mistyped\n"
    "AGENT_ID, from OPENAI_API_KEY, OPENAI_PROJECT_ID or OPENAI_ORG_ID selecting a different\n"
    "project or organization from the one the agent was created in, or from OPENAI_BASE_URL\n"
    "pointing somewhere else. Check those first.\n"
    "Only once you have confirmed the agent is gone, for example in the OpenAI dashboard of the\n"
    "project it was created in, change the line in .env to a blank AGENT_ID=, load the file\n"
    "again with `set -a; . ./.env; set +a`, and run this step again to create a new agent.\n"
)


def _not_confirmed(why: str) -> str:
    return f"Could not confirm that agent agent_kept exists, so it was not kept{why}\n"


# lookup scenario -> (exit status, entire stdout, entire stderr), with AGENT_ID=agent_kept
_KEPT = (
    0,
    "AGENT_ID is set and the agent exists; keeping agent agent_kept\n"
    "\n"
    "Add this to .env:\n"
    "  AGENT_ID=agent_kept\n",
    "",
)

WITH_AGENT_ID = {
    "kept": _KEPT,
    # Asked for agent_kept and answered with agent_kept, so identical to "kept"
    # here; the scenario exists for a case that supplies an id of its own.
    "echoes-what-was-asked": _KEPT,
    "404": (1, "", NOT_FOUND),
    "planted-404": (1, "", NOT_FOUND),
    # The errors with no HTTP status of their own are named by their class alone.
    "api-error": (1, "", _not_confirmed(" (APIError).")),
    "network": (1, "", _not_confirmed(" (APIConnectionError).")),
    "timeout": (1, "", _not_confirmed(" (APITimeoutError).")),
    # The rest carry the status of the response they were built from.
    "api-status": (1, "", _not_confirmed(" (APIStatusError, HTTP 418).")),
    "response-invalid": (1, "", _not_confirmed(" (APIResponseValidationError, HTTP 200).")),
    "400": (1, "", _not_confirmed(" (BadRequestError, HTTP 400).")),
    "401": (1, "", _not_confirmed(" (AuthenticationError, HTTP 401).")),
    "planted-401": (1, "", _not_confirmed(" (AuthenticationError, HTTP 401).")),
    "403": (1, "", _not_confirmed(" (PermissionDeniedError, HTTP 403).")),
    "409": (1, "", _not_confirmed(" (ConflictError, HTTP 409).")),
    "422": (1, "", _not_confirmed(" (UnprocessableEntityError, HTTP 422).")),
    "429": (1, "", _not_confirmed(" (RateLimitError, HTTP 429).")),
    "500": (1, "", _not_confirmed(" (InternalServerError, HTTP 500).")),
    "planted-500": (1, "", _not_confirmed(" (InternalServerError, HTTP 500).")),
    "oauth": (1, "", _not_confirmed(" (OAuthError, HTTP 401).")),
    "no-id-attribute": (1, "", _not_confirmed(": the lookup succeeded but returned no agent id.")),
    "id-none": (1, "", _not_confirmed(": the lookup succeeded but returned no agent id.")),
    "different-id": (
        1, "", _not_confirmed(": the lookup succeeded but returned a different agent id."),
    ),
}
LOOKUP_CALLS = [["make_client", [], {}], ["retrieve", ["agent_kept"], {}]]

PLACEHOLDER_NOTE = (
    "[note] Using the PLACEHOLDER model id 'gpt-6-astra'. Set AGENT_MODEL in .env to a\n"
    "       model id your project can use; confirm it against https://platform.openai.com/docs/models\n"
)
AGENT_NAME = "EKS Nitro sandbox coding assistant"
INSTRUCTIONS = (
    "You are a coding assistant. Your Bash and file-editing tools run in a codex "
    "executor inside a Nitro sandbox on Amazon EKS. Your working directory is "
    "/workspace; write any files you produce there. Inspect files directly and "
    "cite concrete details."
)

UNSET = None  # the line is removed from .env
BLANK = ""  # the line is left as the template ships it
SET_MODEL = "gpt-test-model"
# The script's own default. Choosing it explicitly is a model the reader gave, so
# the note must not appear: that tells "no model given" apart from "this model
# given", which a check on the resolved model alone cannot do.
PLACEHOLDER_MODEL = "gpt-6-astra"
MODELS = {
    "model-unset": UNSET,
    "model-blank": BLANK,
    "model-set": SET_MODEL,
    "model-set-to-the-placeholder": PLACEHOLDER_MODEL,
}


def _created(model_setting) -> tuple[tuple[int, str, str], list]:
    model = model_setting or PLACEHOLDER_MODEL
    note = "" if model_setting else PLACEHOLDER_NOTE
    shown = (0, f"{note}Created agent agent_new ({model})\n\nAdd this to .env:\n  AGENT_ID=agent_new\n", "")
    calls = [
        ["make_client", [], {}],
        ["create", [], {"name": AGENT_NAME, "model": model, "instructions": INSTRUCTIONS}],
    ]
    return shown, calls


# None of these repeat the model any more. Round 11 forged a line through it with
# no control character at all, using ordinary letters and spaces long enough that
# the terminal's own wrapping started a row with "  AGENT_ID=forged"; a message
# that does not carry the value cannot be made to do that at any width.
def _create_failed(why: str) -> str:
    return f"Could not create an agent ({why}).\n"


def _no_created_id() -> str:
    return (
        "The create call succeeded but returned no usable agent id, so there is nothing\n"
        f'to add to .env. An agent named "{AGENT_NAME}"\n'
        "may have been created: check the OpenAI dashboard of the project this key selects\n"
        "before running this step again, so that you do not leave a second agent behind.\n"
    )


def _unsafe_created_id() -> str:
    return (
        "The create call returned an agent id this step will not print, so it was not\n"
        "printed: the line this step prints is pasted into .env and loaded\n"
        "with `set -a; . ./.env; set +a`, which runs what it finds. Check OPENAI_BASE_URL\n"
        f'first, since the endpoint it selects is what sent this. An agent named "{AGENT_NAME}"\n'
        "may have been created: check the OpenAI dashboard of the project this key selects\n"
        "before running this step again, so that you do not leave a second agent behind.\n"
    )


# create scenario -> (exit status, entire stdout, entire stderr), with AGENT_ID
# absent and AGENT_MODEL set, so no placeholder note and no lookup is involved.
# A failure must name the class and status and nothing the server sent; a success
# carrying no usable id must not print one; and a success carrying a string
# outside the emission allowlist must not print that either. Not every rejected
# value would have run: ".", ".." and an over-length id are all shell-safe, and
# are refused for the other reasons SAFE_AGENT_ID's comment gives.
WITHOUT_AGENT_ID = {
    "created": _created(SET_MODEL)[0],
    # Nothing to paste.
    "create-no-id-attribute": (1, "", _no_created_id()),
    "create-id-none": (1, "", _no_created_id()),
    "create-id-blank": (1, "", _no_created_id()),
    "create-id-not-a-string": (1, "", _no_created_id()),
    # A string, but not one that may be printed into a shell assignment.
    "create-id-command-substitution": (1, "", _unsafe_created_id()),
    "create-id-backtick": (1, "", _unsafe_created_id()),
    "create-id-newline": (1, "", _unsafe_created_id()),
    "create-id-space": (1, "", _unsafe_created_id()),
    "create-id-leading-space": (1, "", _unsafe_created_id()),
    "create-id-only-spaces": (1, "", _unsafe_created_id()),
    "create-id-quote": (1, "", _unsafe_created_id()),
    "create-id-semicolon": (1, "", _unsafe_created_id()),
    "create-id-too-long": (1, "", _unsafe_created_id()),
    "create-id-dot": (1, "", _unsafe_created_id()),
    "create-id-dot-dot": (1, "", _unsafe_created_id()),
    # One per error class the SDK loads, every one of them planted wherever there
    # is a response to plant in.
    "create-api-error": (1, "", _create_failed("APIError")),
    "create-network": (1, "", _create_failed("APIConnectionError")),
    "create-timeout": (1, "", _create_failed("APITimeoutError")),
    "create-api-status": (1, "", _create_failed("APIStatusError, HTTP 418")),
    "create-response-invalid": (1, "", _create_failed("APIResponseValidationError, HTTP 200")),
    "create-400": (1, "", _create_failed("BadRequestError, HTTP 400")),
    "create-401": (1, "", _create_failed("AuthenticationError, HTTP 401")),
    "create-403": (1, "", _create_failed("PermissionDeniedError, HTTP 403")),
    "create-404": (1, "", _create_failed("NotFoundError, HTTP 404")),
    "create-409": (1, "", _create_failed("ConflictError, HTTP 409")),
    "create-422": (1, "", _create_failed("UnprocessableEntityError, HTTP 422")),
    "create-429": (1, "", _create_failed("RateLimitError, HTTP 429")),
    "create-500": (1, "", _create_failed("InternalServerError, HTTP 500")),
    "create-oauth": (1, "", _create_failed("OAuthError, HTTP 401")),
}
CREATE_CALLS = [
    ["make_client", [], {}],
    ["create", [], {"name": AGENT_NAME, "model": SET_MODEL, "instructions": INSTRUCTIONS}],
]


# ---------------------------------------------------------------------------
# Doing step 2
# ---------------------------------------------------------------------------


def _write_env(sample: Path, agent_id, agent_model) -> None:
    lines = (SAMPLE / ".env.example").read_text().splitlines(keepends=True)
    values = {
        # The two keys step 2 tells the reader to fill in; a sentinel shows if one
        # leaks. The pragmas are for detect-secrets, which reads the key names and
        # not the values: these are fixed test sentinels, never real credentials.
        "OPENAI_API_KEY": "sentinel-application-value",  # pragma: allowlist secret
        "OPENAI_EXECUTOR_API_KEY": "sentinel-environment-value",  # pragma: allowlist secret
        "AGENT_ID": agent_id,
        "AGENT_MODEL": agent_model,
    }
    out = []
    for name, value in values.items():
        matches = [i for i, line in enumerate(lines) if line == f"{name}=\n"]
        assert len(matches) == 1, f".env.example has no single blank {name}= line"
    for line in lines:
        name = line.split("=", 1)[0] if line.endswith("=\n") else None
        if name in values:
            if values[name] is UNSET:
                continue
            line = f"{name}={values[name]}\n"
        out.append(line)
    (sample / ".env").write_text("".join(out))


def _environment() -> dict[str, str]:
    template = {line.split("=", 1)[0] for line in (SAMPLE / ".env.example").read_text().splitlines()
                if line and not line.startswith("#") and "=" in line}
    return {
        name: value
        for name, value in os.environ.items()
        if name not in template
        and not name.startswith(("OPENAI_", "AGENT_", "PYTHON", "PYTEST_"))
        # A shell does not export these, and they would override the terminal's own size.
        and name not in ("COLUMNS", "LINES")
    }


def _prepare(sample: Path, scenario: str, agent_id, agent_model, source, create_scenario: str) -> Path:
    shutil.copytree(
        SAMPLE, sample,
        ignore=shutil.ignore_patterns(".env", ".venv", "__pycache__", ".pytest_cache"),
    )
    if source is not None:
        (sample / "scripts" / "setup_agent.py").write_text(source)
    ledger = sample / "calls.jsonl"
    (sample / "scripts" / "_client.py").write_text(
        FAKE_CLIENT.format(ledger=str(ledger), scenario=scenario, create_scenario=create_scenario)
    )
    (sample / "scripts" / "_fake_outcomes.py").write_text(OUTCOMES.read_text())
    python = sample / ".venv" / "bin" / "python"
    python.parent.mkdir(parents=True)
    python.write_text(f'#!/bin/sh\nexec "{sys.executable}" "$@"\n')
    python.chmod(0o755)
    _write_env(sample, agent_id, agent_model)
    return ledger


def _in_a_terminal(command, cwd, env, timeout=60):
    """Run on one default-configured 24x80 PTY that is the controlling terminal."""
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))

    def _take_terminal():
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    proc = subprocess.Popen(
        command, cwd=cwd, env=env, stdin=slave, stdout=slave, stderr=slave,
        start_new_session=True, preexec_fn=_take_terminal,
    )
    os.close(slave)
    received = b""
    deadline = time.monotonic() + timeout
    try:
        while True:
            if time.monotonic() > deadline:
                proc.kill()
                raise AssertionError("the program did not finish")
            ready, _, _ = select.select([master], [], [], 0.5)
            if not ready:
                if proc.poll() is not None:
                    break
                continue
            try:
                data = os.read(master, 65536)
            except OSError:  # EIO once every holder of the terminal has exited
                break
            if not data:
                break
            received += data
    finally:
        os.close(master)
    proc.wait(timeout=timeout)
    return proc.returncode, received.decode()


def run_step_2(tmp_path, scenario, agent_id, agent_model, *, tty, source=None, create_scenario="created"):
    """Do step 2 in a fresh copy; return (status, shown) and the calls made.

    shown is (stdout, stderr) when piped, and every byte the terminal received
    when on a terminal.
    """
    sample = tmp_path / "sample"
    ledger = _prepare(sample, scenario, agent_id, agent_model, source, create_scenario)
    command = ["/bin/sh", "-c", PAGE_COMMANDS]
    env = _environment()
    if tty:
        status, shown = _in_a_terminal(command, sample, env)
    else:
        result = subprocess.run(command, cwd=sample, env=env, capture_output=True, text=True, timeout=60)
        status, shown = result.returncode, (result.stdout, result.stderr)
    calls = [json.loads(line) for line in ledger.read_text().splitlines()] if ledger.exists() else []
    return status, shown, calls


def _as_shown(expected: tuple[int, str, str], tty: bool):
    status, stdout, stderr = expected
    if tty:
        # One terminal carries both streams, and it shows each newline as CR LF.
        return status, (stdout + stderr).replace("\n", "\r\n")
    return status, (stdout, stderr)


MODES = pytest.mark.parametrize("tty", [False, True], ids=["piped", "terminal"])

# ---------------------------------------------------------------------------
# The cases
# ---------------------------------------------------------------------------


def _script_without_the_guard(exit_constant: str) -> str:
    """The real script with one two-line guard cut out, located by its refusal.

    Earlier versions of these cases matched the guard's exact text, which went
    stale twice in two rounds -- once when both id checks moved into a shared
    predicate, once when a message stopped taking the model. Both times the
    marker assertion failed loudly rather than silently stopping the mutation,
    which is the point of it; this locates the guard by the constant it exits
    with instead, and still asserts the shape of what it removes, so a rename or
    a reindent does not make the case stop testing anything.
    """
    lines = SCRIPT.read_text().splitlines(keepends=True)
    found = [i for i, line in enumerate(lines) if f"sys.exit({exit_constant}" in line]
    assert len(found) == 1, f"expected one sys.exit({exit_constant}...), found {len(found)}"
    at = found[0]
    condition = lines[at - 1].lstrip()
    assert condition.startswith("if not "), f"guard above {exit_constant} is {condition!r}"
    without = "".join(lines[: at - 1] + lines[at + 1 :])
    # Cutting text can leave something that dies on its first line, which would
    # make the case pass for a reason unrelated to the guard.
    compile(without, "setup_agent.py", "exec")
    return without


def test_every_lookup_scenario_is_tested():
    assert sorted(WITH_AGENT_ID) == outcomes.LOOKUP_SCENARIOS


@MODES
@pytest.mark.parametrize("model", sorted(MODELS))
@pytest.mark.parametrize("scenario", sorted(WITH_AGENT_ID))
def test_with_agent_id_set_the_reader_sees_exactly_this(tmp_path, scenario, model, tty):
    status, shown, calls = run_step_2(tmp_path, scenario, "agent_kept", MODELS[model], tty=tty)

    assert (status, shown) == _as_shown(WITH_AGENT_ID[scenario], tty)
    assert calls == LOOKUP_CALLS


@MODES
@pytest.mark.parametrize("model", sorted(MODELS))
@pytest.mark.parametrize("agent_id", ["id-unset", "id-blank"])
def test_without_agent_id_an_agent_is_created_and_nothing_is_looked_up(tmp_path, agent_id, model, tty):
    expected, expected_calls = _created(MODELS[model])

    status, shown, calls = run_step_2(
        tmp_path, "kept", UNSET if agent_id == "id-unset" else BLANK, MODELS[model], tty=tty
    )

    assert (status, shown) == _as_shown(expected, tty)
    assert calls == expected_calls


@pytest.mark.parametrize("scenario", ["planted-404", "planted-401", "planted-500"])
def test_the_planted_errors_carry_both_values(scenario):
    # The premise of the planted scenarios: the SDK's own error exposes both, so
    # their exact expected output above shows the program prints neither.
    error = outcomes.lookup(scenario)
    assert outcomes.IN_BODY in str(error)
    assert error.request_id == outcomes.IN_HEADER


# The premise behind every create-error expectation: the SDK's own exception hands
# out the values a proxy behind OPENAI_BASE_URL controls, so the exact expected
# output of each case is what shows the script prints none of them.
#
# Asserted as an exact set per class, which is the shape round 10 asked for. The
# previous shape derived three lists from the same table it was checking, so a
# wrong entry only moved a class between lists and everything still passed -- and
# one entry was wrong: OAuthError was declared request-id-only, while the SDK
# builds its message from body["error_description"]. Round 9 had already found the
# other half of this, a mutation printing these fields for RateLimitError alone
# surviving because the single 429 case was unplanted. Equality catches both: a
# class exposing more than declared fails, and so does one exposing less.
# What each class is expected to expose of the two planted values, owned by THIS
# file. That is the point: round 11 defeated the previous version by removing
# OAuthError's error_description planting and editing the module's declaration to
# match, and 17 tests still passed -- a comparison of the module against itself
# cannot see a coordinated change to both sides. These are the observed facts of
# openai 3.31.0, written down here so that a change in the SDK or in the fake has
# to be reconciled with an expectation it does not control.
#   body          the response body reaches str(exc), which a traceback prints
#   request_id    the x-request-id header reaches exc.request_id
#   response_text the body reaches exc.response.text
_ALL_CHANNELS = frozenset({"body", "request_id", "response_text"})
EXPECTED_CHANNELS = {
    # No response, so no header and no response text; the body is in the message.
    "create-api-error": frozenset({"body"}),
    # Transport-level: the SDK writes the whole message and there is no response.
    "create-network": frozenset(),
    "create-timeout": frozenset(),
    # Writes its own message and is an APIError, not an APIStatusError, so it has
    # no request_id attribute at all -- but it does carry the response.
    "create-response-invalid": frozenset({"response_text"}),
    # Writes its own message too, but from body["error_description"], so the body
    # does reach it. Round 10 had this one declared header-only.
    "create-oauth": _ALL_CHANNELS,
    "create-api-status": _ALL_CHANNELS,
    "create-400": _ALL_CHANNELS,
    "create-401": _ALL_CHANNELS,
    "create-403": _ALL_CHANNELS,
    "create-404": _ALL_CHANNELS,
    "create-409": _ALL_CHANNELS,
    "create-422": _ALL_CHANNELS,
    "create-429": _ALL_CHANNELS,
    "create-500": _ALL_CHANNELS,
}


def test_the_expected_channels_cover_every_error_scenario():
    assert sorted(EXPECTED_CHANNELS) == outcomes.ERROR_SCENARIOS


@pytest.mark.parametrize("scenario", sorted(EXPECTED_CHANNELS))
def test_each_error_class_exposes_exactly_what_this_file_expects(scenario):
    assert outcomes.observed_channels(scenario) == EXPECTED_CHANNELS[scenario]


@pytest.mark.parametrize("scenario", outcomes.ERROR_SCENARIOS)
def test_the_fakes_own_table_agrees_with_what_it_produces(scenario):
    # Weaker than the test above and kept for a different purpose: this one finds
    # a table edited without the fixture, which is the ordinary mistake, and says
    # so against the module rather than against this file's expectations.
    assert outcomes.observed_channels(scenario) == outcomes.declared_channels(scenario)


def test_every_create_scenario_is_tested():
    assert sorted(WITHOUT_AGENT_ID) == outcomes.CREATE_SCENARIOS


UNSAFE_ENV_AGENT_ID = (
    "The AGENT_ID that is set is not one this step will print, so it was not used and\n"
    "is not repeated here. The line this step prints is pasted into .env and loaded\n"
    "with `set -a; . ./.env; set +a`, which runs what it finds, so only a plain token\n"
    'of letters, digits, dot, underscore and hyphen, up to 128 of them and not "." or\n'
    '"..", is emitted. Check the AGENT_ID line in .env, and the environment if you set\n'
    "it there, then load the file again and rerun this step.\n"
)

UNSAFE_MODEL = (
    "The AGENT_MODEL that is set is not one this step will print, so no agent was\n"
    "created and the value is not repeated here. It is shown back to you on the line\n"
    "reporting the new agent, so this step prints only a model of letters, digits,\n"
    "dot, underscore, hyphen, colon or slash, up to 64 of them: no whitespace and\n"
    "nothing longer. That is a limit on what this step will display, not on what the\n"
    "API accepts. Quoting is why it matters -- a value can sit in .env without the\n"
    "shell doing anything with it and still add a line to this step's output once\n"
    "printed. Check the AGENT_MODEL line in .env, then load the file again and rerun\n"
    "this step.\n"
)

# Quoted in .env, so each of these loads without the shell doing anything with it,
# and is then handed to this step as the model to show back to the reader. Round 10
# found this route: the model reaches every refusal message and the success line.
FORGING_MODEL = "'gpt-x\nAdd this to .env:\n  AGENT_ID=forged'"
# The autowrap value is round 11's, and the important one: it holds no control
# character at all. At 80 columns the terminal's own wrapping put
# "  AGENT_ID=forged" at the start of a row, so a byte-level check passed it.
AUTOWRAP_FORGING_MODEL = "'" + "X" * 54 + "  AGENT_ID=forged" + " " * 63 + "'"
HOSTILE_MODELS = {
    "forged-line": FORGING_MODEL,
    "carriage-return": "'gpt-x\rAGENT_ID=forged'",
    "osc-escape": "'gpt-x\x1b]0;pwned\x07'",
    "tab": "'gpt-x\tmodel'",
    "autowrap": AUTOWRAP_FORGING_MODEL,
    "space": "'gpt x'",
    "too-long": "'" + "A" * 65 + "'",
}


@MODES
@pytest.mark.parametrize("hostile", sorted(HOSTILE_MODELS))
def test_an_env_model_that_is_not_printable_ascii_is_refused(tmp_path, hostile, tty):
    """AGENT_MODEL is shown back to the reader, so it is checked before it is.

    Refused before the AGENT_ID branch, so it holds whether the run would have
    looked an agent up or created one.
    """
    status, shown, calls = run_step_2(
        tmp_path, "kept", UNSET, HOSTILE_MODELS[hostile], tty=tty
    )

    assert (status, shown) == _as_shown((1, "", UNSAFE_MODEL), tty)
    assert calls == [["make_client", [], {}]]


@MODES
@pytest.mark.parametrize("hostile", sorted(HOSTILE_MODELS))
def test_a_model_this_step_will_not_print_does_not_block_keeping_an_agent(tmp_path, hostile, tty):
    """The check sits in the create branch, which is the only path that shows it.

    Round 11 found it ahead of the AGENT_ID branch, where it stopped a run that
    keeps an existing agent and never prints a model at all -- contradicting the
    page, which says keeping one uses no model.
    """
    status, shown, calls = run_step_2(
        tmp_path, "kept", "agent_kept", HOSTILE_MODELS[hostile], tty=tty
    )

    assert (status, shown) == _as_shown(WITH_AGENT_ID["kept"], tty)
    assert calls == LOOKUP_CALLS


@MODES
@pytest.mark.parametrize(
    "quoted_in_env",
    [
        "'$(touch pwned)'", "'`touch pwned`'", "'agent_ok;touch pwned'", "'agent ok'",
        "' agent_ok'",
        # Shell-safe, but URI dot-segments the SDK refuses with ValueError, which
        # is not an APIError. See the premise test below.
        "'.'", "'..'",
    ],
    ids=["substitution", "backtick", "semicolon", "space", "leading-space", "dot", "dot-dot"],
)
def test_an_env_agent_id_that_is_not_a_plain_token_is_refused(tmp_path, quoted_in_env, tty):
    """The same grammar on the id the reader supplies, which is a real escalation.

    Quoted in .env, these load as literal text and run nothing. But the line this
    step prints is *unquoted*, so printing one back would hand the reader a line
    that does run when they paste it and load .env again. So the check is at the
    point the id is read, which also covers the 404 and could-not-confirm
    messages, each of which repeats the value.
    """
    status, shown, calls = run_step_2(tmp_path, "kept", quoted_in_env, SET_MODEL, tty=tty)

    assert (status, shown) == _as_shown((1, "", UNSAFE_ENV_AGENT_ID), tty)
    # Refused before the lookup, so no retrieve was attempted with it.
    assert calls == [["make_client", [], {}]]


def test_an_env_agent_id_quoted_in_env_is_not_run_by_loading_it(tmp_path):
    # The premise of the test above: these values are safe *as .env ships them*,
    # so the danger is only in printing them back unquoted. If loading them were
    # already unsafe, the check could not be what protects the reader.
    work = tmp_path / "quoted"
    work.mkdir()
    marker = work / "EXECUTED"
    (work / ".env").write_text(f"AGENT_ID='$(touch \"{marker}\")'\n")

    loaded = subprocess.run(
        ["/bin/sh", "-c", 'set -a; . ./.env; set +a; printf %s "$AGENT_ID"'],
        cwd=work, capture_output=True, text=True, timeout=60, check=True,
    )

    assert loaded.stdout == f'$(touch "{marker}")'
    assert not marker.exists()


_LOG_LEAK_DRIVER = '''\
"""Make one call through a mock transport whose endpoint reflects the request
headers back in x-request-id, which the SDK logs verbatim at debug level."""
import os
import sys

SENTINEL = "sentinel-application-key-value"  # pragma: allowlist secret

if os.environ.get("IMPORT_THE_SHARED_CLIENT") == "1":
    sys.path.insert(0, {scripts!r})
    import _client  # noqa: F401  -- imported for the effect it has on OPENAI_LOG

import httpx2 as httpx
import openai


def handler(request):
    reflected = request.headers.get("authorization", "")
    return httpx.Response(
        200,
        json={{"id": "agent_ok"}},
        headers={{"x-request-id": reflected + " \\x1b]0;pwned\\x07"}},
    )


client = openai.OpenAI(
    api_key=SENTINEL,
    base_url="https://api.openai.example/v1",
    http_client=httpx.Client(transport=httpx.MockTransport(handler)),
)
client.beta.agents.retrieve("agent_ok")
'''


@pytest.mark.parametrize("import_the_shared_client", [False, True], ids=["without", "with"])
def test_the_shared_client_keeps_sdk_logging_from_printing_the_key(tmp_path, import_the_shared_client):
    """Both ways on the one route that reaches the terminal around every check.

    openai 3.31.0 reads OPENAI_LOG when it is imported and, at debug level, logs
    response headers verbatim. x-request-id is one of them, and an endpoint that
    reflects the request headers it received puts this machine's application key
    in it. Round 11 found this; scripts/_client.py now unsets OPENAI_LOG before
    importing the SDK, which is why this runs in a subprocess -- the ordering is
    the whole mechanism and cannot be shown in a process that already imported it.
    """
    driver = tmp_path / "driver.py"
    driver.write_text(_LOG_LEAK_DRIVER.format(scripts=str(SAMPLE / "scripts")))
    environment = dict(os.environ)
    environment["OPENAI_LOG"] = "debug"
    environment["IMPORT_THE_SHARED_CLIENT"] = "1" if import_the_shared_client else "0"

    result = subprocess.run(
        [sys.executable, str(driver)], cwd=tmp_path, env=environment,
        capture_output=True, text=True, timeout=120,
    )
    written = result.stdout + result.stderr

    if import_the_shared_client:
        assert "sentinel-application-key-value" not in written
        assert "\x1b" not in written
    else:
        # The defect, so the case above is known to be testing something.
        assert "sentinel-application-key-value" in written
        assert "\x1b" in written


def test_an_unexpected_dependency_failure_shows_no_detail(tmp_path):
    """A traceback is an output channel too, and not one this program controls.

    Round 11 reached httpx2.InvalidURL carrying a port from a hostile
    OPENAI_BASE_URL, so main() is wrapped and only the exception's class name --
    which comes from installed code -- is shown.
    """
    source = SCRIPT.read_text()
    marker = "def main() -> None:\n"
    assert source.count(marker) == 1
    # Raise from inside main(), past every check, with a message that must not appear.
    mutant = source.replace(
        marker, marker + '    raise RuntimeError("secret-from-a-dependency")\n'
    )
    compile(mutant, "setup_agent.py", "exec")

    status, shown, _ = run_step_2(
        tmp_path, "kept", "agent_kept", SET_MODEL, tty=False, source=mutant
    )
    stdout, stderr = shown

    assert status == 1
    assert "secret-from-a-dependency" not in stderr
    assert "Traceback" not in stderr
    assert "unexpected RuntimeError" in stderr
    assert stdout == ""


def test_the_premise_that_a_dot_segment_id_raises_before_any_request():
    """Why "." and ".." are refused even though a shell treats them literally.

    The pinned SDK rejects them while building the request path, with ValueError
    -- not an APIError -- so they would escape both handlers and reach the reader
    as a traceback. Asserted against the real client over a mock transport, so it
    is the SDK's behaviour being recorded and not the fake's: the fake never
    builds a URL, which is exactly why no scenario here could have caught this.
    """
    import httpx2 as real_httpx
    import openai as real_openai

    reached = []

    def handler(request):
        reached.append(request.url.path)
        return real_httpx.Response(200, json={"id": "agent_ok"})

    client = real_openai.OpenAI(
        api_key="unused-in-this-test",  # pragma: allowlist secret
        base_url="https://api.openai.example/v1",
        http_client=real_httpx.Client(transport=real_httpx.MockTransport(handler)),
    )

    for dot_segment in (".", ".."):
        with pytest.raises(ValueError):
            client.beta.agents.retrieve(dot_segment)
    assert reached == [], "no request should have been attempted"

    # And the discriminating half: an ordinary id does reach the transport, so the
    # two above are refused for being dot-segments and not for some other reason.
    client.beta.agents.retrieve("agent_ok")
    assert reached == ["/v1/agents/agent_ok"]


def test_the_premise_that_loading_env_runs_what_it_finds(tmp_path):
    # Why the script checks the id's own grammar before printing it. The page has
    # the reader paste this step's output into .env and load it with
    # `set -a; . ./.env; set +a`, and that runs what it finds rather than
    # assigning it. Asserted rather than assumed, like the planted errors above:
    # round 9 demonstrated it end to end against the previous commit, whose check
    # accepted any non-empty string.
    work = tmp_path / "premise"
    work.mkdir()
    marker = work / "EXECUTED"
    (work / ".env").write_text(f'AGENT_ID=$(touch "{marker}")\n')

    subprocess.run(
        ["/bin/sh", "-c", "set -a; . ./.env; set +a"],
        cwd=work, capture_output=True, text=True, timeout=60, check=True,
    )

    assert marker.exists(), "if this ever stops holding, SAFE_AGENT_ID guards nothing"


@pytest.mark.parametrize(
    "scenario,pasteable",
    [("created", "agent_new"), ("create-id-command-substitution", None)],
)
def test_the_suggested_line_is_safe_to_paste_and_load(tmp_path, scenario, pasteable):
    """Both ways, on the property that matters: one id it must print, one it must not.

    The accepted case is loaded the way the page tells the reader to, and must
    assign exactly the id and run nothing. The rejected case must print no
    AGENT_ID line at all, so there is nothing to paste in the first place.
    """
    status, shown, _ = run_step_2(
        tmp_path, "kept", UNSET, SET_MODEL, tty=False, create_scenario=scenario
    )
    stdout, _ = shown
    suggested = [line.strip() for line in stdout.splitlines() if line.strip().startswith("AGENT_ID=")]

    if pasteable is None:
        assert status == 1
        assert suggested == []
        return

    assert status == 0
    assert suggested == [f"AGENT_ID={pasteable}"]

    work = tmp_path / "load"
    work.mkdir()
    marker = work / "EXECUTED"
    (work / ".env").write_text(suggested[0] + "\n")

    loaded = subprocess.run(
        ["/bin/sh", "-c", 'set -a; . ./.env; set +a; printf %s "$AGENT_ID"'],
        cwd=work, capture_output=True, text=True, timeout=60, check=True,
    )

    assert loaded.stdout == pasteable
    assert not marker.exists()


# The two paths are asserted separately, and that is the point. Round 9 found the
# earlier single assertion pooling them: it compared the union against the SDK, so
# deleting the lookup's 429 still passed, because the create side supplied
# RateLimitError. Pooled coverage is coverage of neither path.
def test_every_sdk_error_class_is_covered_on_the_lookup_path():
    assert outcomes.sdk_error_classes() - outcomes.lookup_error_classes() == set()


def test_every_sdk_error_class_is_covered_on_the_create_path():
    assert outcomes.sdk_error_classes() - outcomes.create_error_classes() == set()


def test_the_two_paths_are_not_pooled():
    # The guard on the defect itself: each path must carry the whole set on its
    # own, so neither assertion above can be satisfied by the other path's cases.
    assert outcomes.lookup_error_classes() == outcomes.sdk_error_classes()
    assert outcomes.create_error_classes() == outcomes.sdk_error_classes()


@MODES
@pytest.mark.parametrize("scenario", sorted(WITHOUT_AGENT_ID))
def test_what_a_create_shows_is_exactly_this(tmp_path, scenario, tty):
    status, shown, calls = run_step_2(
        tmp_path, "kept", UNSET, SET_MODEL, tty=tty, create_scenario=scenario
    )

    assert (status, shown) == _as_shown(WITHOUT_AGENT_ID[scenario], tty)
    assert calls == CREATE_CALLS


@MODES
def test_a_failed_create_shows_the_placeholder_note_and_then_the_error(tmp_path, tty):
    # With no model given the note is printed before the call is made, so a reader
    # sees the note and then the failure; the error path must not swallow it.
    expected = (1, PLACEHOLDER_NOTE, _create_failed("RateLimitError, HTTP 429"))

    status, shown, calls = run_step_2(
        tmp_path, "kept", UNSET, UNSET, tty=tty, create_scenario="create-429"
    )

    assert (status, shown) == _as_shown(expected, tty)
    assert calls == [
        ["make_client", [], {}],
        [
            "create", [],
            {"name": AGENT_NAME, "model": PLACEHOLDER_MODEL, "instructions": INSTRUCTIONS},
        ],
    ]


def test_output_only_on_a_terminal_is_caught_by_the_terminal_run(tmp_path):
    # The harness itself, both ways: a copy that prints one extra line only when
    # stdout is a terminal of 80 columns matches piped, and fails on the terminal.
    source = SCRIPT.read_text()
    marker = 'if __name__ == "__main__":\n'
    assert source.count(marker) == 1
    mutant = source.replace(
        marker,
        "import shutil, sys\n"
        "if sys.stdout.isatty() and shutil.get_terminal_size().columns == 80:\n"
        "    print('extra')\n" + marker,
    )
    expected = WITH_AGENT_ID["kept"]

    piped = run_step_2(tmp_path / "a", "kept", "agent_kept", SET_MODEL, tty=False, source=mutant)
    terminal = run_step_2(tmp_path / "b", "kept", "agent_kept", SET_MODEL, tty=True, source=mutant)

    assert piped[:2] == _as_shown(expected, tty=False)
    assert terminal[:2] != _as_shown(expected, tty=True)
    assert terminal[1] == ("extra\n" + expected[1]).replace("\n", "\r\n")


def test_without_the_id_grammar_check_the_hostile_id_is_printed(tmp_path):
    """The other half of the grammar check: cut it out and the danger comes back.

    Run against the real script with the two refusal lines removed, so what is
    being shown is that *this* check is what stops it, rather than something else
    in the script happening to. Without that, the rejecting cases above could be
    passing for any reason at all.
    """
    without = _script_without_the_guard("UNSAFE_CREATED_ID_MESSAGE")

    status, shown, _ = run_step_2(
        tmp_path, "kept", UNSET, SET_MODEL, tty=False,
        source=without, create_scenario="create-id-command-substitution",
    )
    stdout, _ = shown

    assert status == 0
    assert "  AGENT_ID=$(touch pwned)\n" in stdout


def test_without_the_env_id_check_the_unquoted_line_is_printed_back(tmp_path):
    """The other half of the env-side check, in the real script.

    Cut the guard out and the program hands the reader back an unquoted AGENT_ID=
    line built from a value that was quoted, and therefore inert, in their .env.
    Pasting that line is what makes it live.
    """
    without = _script_without_the_guard("UNSAFE_ENV_AGENT_ID_MESSAGE")

    # "echoes-what-was-asked", not "kept": with a fixed agent_kept coming back the
    # run would stop at "a different agent id" and never reach the print, so the
    # case would pass without showing anything about the check it is named for.
    status, shown, _ = run_step_2(
        tmp_path, "echoes-what-was-asked", "'agent_ok;touch pwned'", SET_MODEL,
        tty=False, source=without,
    )
    stdout, _ = shown

    assert status == 0
    assert "  AGENT_ID=agent_ok;touch pwned\n" in stdout


def test_without_the_model_check_the_output_can_be_forged(tmp_path):
    """The other half of the model check: cut it out and a .env forges a line.

    Demonstrated on the success line, because that is now the only place the model
    is echoed -- the refusal messages stopped carrying it this round, which closed
    the route this case originally used. A .env value holding a newline puts text
    of its own choosing on its own line in this step's output, right where the
    page tells the reader to look for the line to paste.
    """
    without = _script_without_the_guard("UNSAFE_MODEL_MESSAGE")

    status, shown, _ = run_step_2(
        tmp_path, "kept", UNSET, FORGING_MODEL, tty=False, source=without
    )
    stdout, _ = shown

    assert status == 0
    assert "\n  AGENT_ID=forged" in stdout
    # The real line is still there too, which is what makes the forgery work: the
    # reader sees two of them and no reason to prefer the second.
    assert "\n  AGENT_ID=agent_new\n" in stdout


def test_a_repeated_api_call_is_caught_by_the_call_list(tmp_path):
    # The harness itself: a copy that looks the agent up twice shows exactly the
    # expected text, so only the call list can catch it, and it does.
    source = SCRIPT.read_text()
    marker = "        agent = client.beta.agents.retrieve(agent_id)\n"
    assert source.count(marker) == 1
    mutant = source.replace(marker, marker + "        client.beta.agents.retrieve(agent_id)\n")

    status, shown, calls = run_step_2(tmp_path, "kept", "agent_kept", SET_MODEL, tty=False, source=mutant)

    assert (status, shown) == _as_shown(WITH_AGENT_ID["kept"], tty=False)
    assert calls == LOOKUP_CALLS + [["retrieve", ["agent_kept"], {}]]
