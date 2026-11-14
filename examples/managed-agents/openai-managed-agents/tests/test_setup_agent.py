"""Tests for scripts/setup_agent.py, run the way step 2 of the page runs it.

Each case copies setup_agent.py, unchanged, into a temporary sample folder beside
a fake `_client.py`, and runs the page's own command there,
`<python> scripts/setup_agent.py`, from that folder, with only the variables a
sourced `.env.example` exports (every template variable present; the blank ones
the reader is told to fill set to sentinel values; AGENT_ID and AGENT_MODEL
blank, set or unset as the case says) plus PATH and HOME. It runs every case
twice: with stdout and stderr piped, and with stdin, stdout and stderr on
pseudo-terminals, as when a reader runs it in a terminal.

It then compares, exactly, against text this file owns:

- the program's ENTIRE stdout, its ENTIRE stderr and its exit status, so
  anything a reader would see beyond the expected text fails, whatever channel
  it came by (a print, a visible log record or warning, a write to a file
  descriptor, a traceback, output at import time or from the __main__ block,
  output only on a terminal); and
- the ordered list of every call the program made on the fake client, with
  every argument, so a missing, extra, repeated or changed API call fails.

What the program is given in place of the real thing, and so what this does not
cover: the fake `_client` module, in place of scripts/_client.py (which prints
nothing and exits only when OPENAI_API_KEY is unset); and anything the program
writes somewhere other than its stdout and stderr, such as a file.

Both ways, per AGENTS.md: an agent the lookup returns is kept and nothing is
created; with AGENT_ID blank or unset an agent is created and nothing is looked
up; a 404 stops with a message that lists what to check before removing
AGENT_ID, without claiming the agent is gone; any other lookup failure stops and
names the error by its SDK exception class and, when it has one, its HTTP
status; a lookup that succeeds without this agent's id stops; and neither the
response body nor the request-id header is ever shown.

Run with: python -m pytest
"""

from __future__ import annotations

import json
import os
import pty
import select
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

sys.path.insert(0, str(TESTS))
try:
    import _fake_outcomes as outcomes
finally:
    sys.path.remove(str(TESTS))

FAKE_CLIENT = '''\
"""Fake _client for one test case: records every call, answers as the case says."""
import json

from _fake_outcomes import NEW_ID, lookup

LEDGER = {ledger!r}
SCENARIO = {scenario!r}


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
        from types import SimpleNamespace
        return SimpleNamespace(id=NEW_ID)


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
    "project it was created in, remove AGENT_ID from .env (or unset it in this shell) and run\n"
    "this step again to create a new agent.\n"
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
    # A network error has no HTTP status, so it is named by its class alone.
    "network": (1, "", _not_confirmed(" (APIConnectionError).")),
    "401": (1, "", _not_confirmed(" (AuthenticationError, HTTP 401).")),
    "planted-401": (1, "", _not_confirmed(" (AuthenticationError, HTTP 401).")),
    "403": (1, "", _not_confirmed(" (PermissionDeniedError, HTTP 403).")),
    "500": (1, "", _not_confirmed(" (InternalServerError, HTTP 500).")),
    "planted-500": (1, "", _not_confirmed(" (InternalServerError, HTTP 500).")),
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


def _created(model: str, note: str = "") -> tuple[int, str, str]:
    return (
        0,
        f"{note}Created agent agent_new ({model})\n\nAdd this to .env:\n  AGENT_ID=agent_new\n",
        "",
    )


def _create_calls(model: str) -> list:
    return [
        ["make_client", [], {}],
        ["create", [], {"name": AGENT_NAME, "model": model, "instructions": INSTRUCTIONS}],
    ]


UNSET = object()

# (AGENT_ID, AGENT_MODEL) -> expected (status, stdout, stderr) and calls, with no lookup
WITHOUT_AGENT_ID = {
    "id-blank-model-blank": ("", "", _created("gpt-6-astra", PLACEHOLDER_NOTE), _create_calls("gpt-6-astra")),
    "id-unset-model-unset": (UNSET, UNSET, _created("gpt-6-astra", PLACEHOLDER_NOTE), _create_calls("gpt-6-astra")),
    "id-blank-model-set": ("", "gpt-test-model", _created("gpt-test-model"), _create_calls("gpt-test-model")),
    "id-unset-model-set": (UNSET, "gpt-test-model", _created("gpt-test-model"), _create_calls("gpt-test-model")),
}

# ---------------------------------------------------------------------------
# Running the page's command
# ---------------------------------------------------------------------------


def _template_names() -> list[str]:
    """The variables `set -a; . ./.env` exports from an unedited .env.example."""
    names = []
    for line in (SAMPLE / ".env.example").read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            names.append(line.split("=", 1)[0])
    return names


def _environment(agent_id, agent_model) -> dict[str, str]:
    env = {name: os.environ[name] for name in ("PATH", "HOME") if name in os.environ}
    for name in _template_names():
        if name in ("AGENT_ID", "AGENT_MODEL"):
            continue
        # Step 2 has the reader fill these in; a sentinel shows if one leaks.
        env[name] = f"sentinel-for-{name.lower()}"
    for name, value in (("AGENT_ID", agent_id), ("AGENT_MODEL", agent_model)):
        if value is not UNSET:
            env[name] = value
    return env


def _read_ttys(proc, masters, timeout=60):
    chunks = {fd: b"" for fd in masters}
    open_fds = set(masters)
    deadline = time.monotonic() + timeout
    while open_fds:
        if time.monotonic() > deadline:
            proc.kill()
            raise AssertionError("the program did not finish")
        ready, _, _ = select.select(list(open_fds), [], [], 0.5)
        for fd in ready:
            try:
                data = os.read(fd, 65536)
            except OSError:  # EIO once the slave side is closed
                data = b""
            if data:
                chunks[fd] += data
            else:
                open_fds.discard(fd)
    proc.wait(timeout=timeout)
    return [chunks[fd].decode() for fd in masters]


def run_page_command(tmp_path, scenario, agent_id, agent_model, *, tty, source=None):
    """Run `<python> scripts/setup_agent.py` in a fresh copy; return status, out, err, calls."""
    sample = tmp_path / ("tty" if tty else "pipe")
    scripts = sample / "scripts"
    scripts.mkdir(parents=True)
    (scripts / "setup_agent.py").write_text(SCRIPT.read_text() if source is None else source)
    (scripts / "_fake_outcomes.py").write_text(OUTCOMES.read_text())
    ledger = sample / "calls.jsonl"
    (scripts / "_client.py").write_text(FAKE_CLIENT.format(ledger=str(ledger), scenario=scenario))
    command = [sys.executable, "scripts/setup_agent.py"]
    env = _environment(agent_id, agent_model)

    if not tty:
        result = subprocess.run(command, cwd=sample, env=env, capture_output=True, text=True, timeout=60)
        status, out, err = result.returncode, result.stdout, result.stderr
    else:
        out_master, out_slave = pty.openpty()
        err_master, err_slave = pty.openpty()
        for fd in (out_slave, err_slave):
            # No output translation (\n stays \n), so the comparison stays exact.
            attrs = termios.tcgetattr(fd)
            attrs[1] &= ~termios.OPOST
            termios.tcsetattr(fd, termios.TCSANOW, attrs)
        proc = subprocess.Popen(
            command, cwd=sample, env=env, stdin=out_slave, stdout=out_slave, stderr=err_slave
        )
        os.close(out_slave)
        os.close(err_slave)
        try:
            out, err = _read_ttys(proc, [out_master, err_master])
        finally:
            os.close(out_master)
            os.close(err_master)
        status = proc.returncode

    calls = [json.loads(line) for line in ledger.read_text().splitlines()] if ledger.exists() else []
    return status, out, err, calls


MODES = pytest.mark.parametrize("tty", [False, True], ids=["piped", "terminal"])

# ---------------------------------------------------------------------------
# The cases
# ---------------------------------------------------------------------------


def test_every_lookup_scenario_is_tested():
    assert sorted(WITH_AGENT_ID) == outcomes.LOOKUP_SCENARIOS


@MODES
@pytest.mark.parametrize("scenario", sorted(WITH_AGENT_ID))
def test_with_agent_id_set_the_reader_sees_exactly_this(tmp_path, scenario, tty):
    status, out, err, calls = run_page_command(tmp_path, scenario, "agent_kept", "gpt-test-model", tty=tty)

    assert (status, out, err) == WITH_AGENT_ID[scenario]
    assert calls == LOOKUP_CALLS


@MODES
@pytest.mark.parametrize("case", sorted(WITHOUT_AGENT_ID))
def test_without_agent_id_an_agent_is_created_and_nothing_is_looked_up(tmp_path, case, tty):
    agent_id, agent_model, expected, expected_calls = WITHOUT_AGENT_ID[case]

    status, out, err, calls = run_page_command(tmp_path, "kept", agent_id, agent_model, tty=tty)

    assert (status, out, err) == expected
    assert calls == expected_calls


@pytest.mark.parametrize("scenario", ["planted-404", "planted-401", "planted-500"])
def test_the_planted_errors_carry_both_values(scenario):
    # The premise of the planted scenarios: the SDK's own error exposes both, so
    # their exact expected output above shows the program prints neither.
    error = outcomes.lookup(scenario)
    assert outcomes.IN_BODY in str(error)
    assert error.request_id == outcomes.IN_HEADER


def test_output_only_on_a_terminal_is_caught_by_the_terminal_run(tmp_path):
    # The harness itself, both ways: a copy of the program that prints one extra
    # line only when stdout is a terminal matches when piped, and fails on a terminal.
    source = SCRIPT.read_text()
    marker = 'if __name__ == "__main__":\n'
    assert source.count(marker) == 1
    mutant = source.replace(marker, "import sys\nif sys.stdout.isatty():\n    print('extra')\n" + marker)
    expected = WITH_AGENT_ID["kept"]

    piped = run_page_command(tmp_path / "a", "kept", "agent_kept", "gpt-test-model", tty=False, source=mutant)
    terminal = run_page_command(tmp_path / "b", "kept", "agent_kept", "gpt-test-model", tty=True, source=mutant)

    assert piped[:3] == expected
    assert terminal[:3] != expected
    assert terminal[1] == "extra\n" + expected[1]


def test_a_repeated_api_call_is_caught_by_the_call_list(tmp_path):
    # The harness itself: a copy that looks the agent up twice prints exactly the
    # expected text, so only the call list can catch it, and it does.
    source = SCRIPT.read_text()
    marker = "        agent = client.beta.agents.retrieve(agent_id)\n"
    assert source.count(marker) == 1
    mutant = source.replace(marker, marker + "        client.beta.agents.retrieve(agent_id)\n")

    status, out, err, calls = run_page_command(
        tmp_path, "kept", "agent_kept", "gpt-test-model", tty=False, source=mutant
    )

    assert (status, out, err) == WITH_AGENT_ID["kept"]
    assert calls != LOOKUP_CALLS
    assert calls == LOOKUP_CALLS + [["retrieve", ["agent_kept"], {}]]
