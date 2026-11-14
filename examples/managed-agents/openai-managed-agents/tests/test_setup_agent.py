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
exactly the expected calls, in every situation step 2 can produce from the
template, piped and on a terminal.

What this does not cover beyond that: the real scripts/_client.py, which is
replaced (it prints nothing, and exits with a message when OPENAI_API_KEY is
unset or blank); an interactive shell's own behaviour, since the commands run
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

Every other way a lookup can fail stops the run and names the error by its SDK
exception class and, when it has one, its HTTP status. "Every other way" is a
claim about a known set, not about the handful of classes that came to mind:
_fake_outcomes.py raises one of every openai.APIError subclass the installed SDK
defines, and test_every_sdk_error_class_is_covered fails if the SDK gains one
that no scenario raises.

Creating an agent is covered the same way, because it reports failures the same
way: a create that raises any of those classes stops with the error named and
nothing the server sent, and a create that succeeds while returning no usable id
(no attribute, None, blank, or not a string) stops and says the agent may exist,
rather than printing an id a reader would paste into .env.

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
        outcome = lookup(SCENARIO)
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
WITH_AGENT_ID = {
    "kept": (
        0,
        "AGENT_ID is set and the agent exists; keeping agent agent_kept\n"
        "\n"
        "Add this to .env:\n"
        "  AGENT_ID=agent_kept\n",
        "",
    ),
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


def _create_failed(why: str, model: str = SET_MODEL) -> str:
    return f"Could not create an agent with model {model} ({why}).\n"


def _no_created_id(model: str = SET_MODEL) -> str:
    return (
        f"The create call for model {model} succeeded but returned no agent id, so there is\n"
        f'nothing to add to .env. An agent named "{AGENT_NAME}" may have\n'
        "been created: check the OpenAI dashboard of the project this key selects before\n"
        "running this step again, so that you do not leave a second agent behind.\n"
    )


# create scenario -> (exit status, entire stdout, entire stderr), with AGENT_ID
# absent and AGENT_MODEL set, so no placeholder note and no lookup is involved.
# A failure must name the class and status and nothing the server sent, and a
# success that carries no usable id must not print one.
WITHOUT_AGENT_ID = {
    "created": _created(SET_MODEL)[0],
    "create-network": (1, "", _create_failed("APIConnectionError")),
    "create-401": (1, "", _create_failed("AuthenticationError, HTTP 401")),
    "create-planted-401": (1, "", _create_failed("AuthenticationError, HTTP 401")),
    "create-429": (1, "", _create_failed("RateLimitError, HTTP 429")),
    "create-500": (1, "", _create_failed("InternalServerError, HTTP 500")),
    "create-planted-500": (1, "", _create_failed("InternalServerError, HTTP 500")),
    "create-no-id-attribute": (1, "", _no_created_id()),
    "create-id-none": (1, "", _no_created_id()),
    "create-id-blank": (1, "", _no_created_id()),
    "create-id-not-a-string": (1, "", _no_created_id()),
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


@pytest.mark.parametrize("scenario", ["create-planted-401", "create-planted-500"])
def test_the_planted_create_errors_carry_both_values(scenario):
    # The same premise on the create path, which an unhandled exception would
    # have printed in a traceback.
    error = outcomes.create(scenario)
    assert outcomes.IN_BODY in str(error)
    assert error.request_id == outcomes.IN_HEADER


def test_every_create_scenario_is_tested():
    assert sorted(WITHOUT_AGENT_ID) == outcomes.CREATE_SCENARIOS


def test_every_sdk_error_class_is_covered():
    # The scenarios raise one of every openai.APIError subclass the installed SDK
    # defines, so "every other way it can fail" is a claim about a known set. An
    # SDK that gains a class fails here instead of leaving it silently untested.
    assert outcomes.sdk_error_classes() - outcomes.error_classes_covered() == set()


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
    expected = (1, PLACEHOLDER_NOTE, _create_failed("RateLimitError, HTTP 429", PLACEHOLDER_MODEL))

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
