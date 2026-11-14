"""Tests for scripts/setup_agent.py keeping an AGENT_ID, run as a program.

Each case starts tests/_setup_agent_driver.py in a child process, which runs
setup_agent.py as __main__ against one faked agents API outcome, and compares
the child's ENTIRE stdout and stderr, and its exit status, with exact text this
file owns. So the tests do not list the ways output can escape: anything a
reader running the script would see beyond the expected text fails, whether it
is a print, a log record, a warning, a write to a file descriptor, a traceback,
output at import time or from the __main__ block. And an unexpected API call
(a lookup without AGENT_ID, a lookup of another id, a create while a kept agent
is checked) raises in the child and fails the same way.

Both ways, per AGENTS.md: an agent the lookup returns is kept and nothing is
created; with no AGENT_ID an agent is created and nothing is looked up; a 404
stops with a message that lists what to check before removing AGENT_ID, without
claiming the agent is gone; a lookup that fails for any other reason (network,
auth, 5xx) stops and names the error by its SDK exception class and, when it has
one, its HTTP status; a lookup that succeeds without this agent's id stops; and
neither the response body nor the request-id header, either of which a proxy
behind OPENAI_BASE_URL can fill with a key, is ever shown.

What this does not cover: anything the script writes somewhere other than its
own stdout and stderr, such as a file or the network.

Run with: python -m pytest
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

openai = pytest.importorskip("openai")
pytest.importorskip("httpx2")

TESTS = Path(__file__).resolve().parent
DRIVER = TESTS / "_setup_agent_driver.py"

sys.path.insert(0, str(TESTS))
try:
    import _setup_agent_driver as driver
finally:
    sys.path.remove(str(TESTS))

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


def _run(scenario: str, agent_id: str | None) -> subprocess.CompletedProcess:
    # A clean environment, so neither the caller's OpenAI settings nor Python
    # options such as PYTHONWARNINGS change what the child shows.
    env = {
        name: value
        for name, value in os.environ.items()
        if not name.startswith(("OPENAI_", "PYTHON", "AGENT_"))
    }
    env.update(PYTHONDONTWRITEBYTECODE="1", PYTHONIOENCODING="utf-8", AGENT_MODEL="test-model")
    if agent_id is not None:
        env["AGENT_ID"] = agent_id
    return subprocess.run(
        [sys.executable, str(DRIVER), scenario],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )


# scenario -> (exit status, entire stdout, entire stderr)
EXPECTED = {
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
    "no-id-attribute": (
        1, "", _not_confirmed(": the lookup succeeded but returned no agent id."),
    ),
    "id-none": (1, "", _not_confirmed(": the lookup succeeded but returned no agent id.")),
    "different-id": (
        1, "", _not_confirmed(": the lookup succeeded but returned a different agent id."),
    ),
}


def test_every_driver_scenario_is_tested():
    assert sorted([*EXPECTED, "create"]) == driver.SCENARIOS


@pytest.mark.parametrize("scenario", sorted(EXPECTED))
def test_with_agent_id_set_the_program_shows_exactly_this(scenario):
    status, stdout, stderr = EXPECTED[scenario]

    result = _run(scenario, agent_id="agent_kept")

    assert (result.returncode, result.stdout, result.stderr) == (status, stdout, stderr)


def test_without_agent_id_an_agent_is_created_and_nothing_is_looked_up():
    result = _run("create", agent_id=None)

    assert (result.returncode, result.stdout, result.stderr) == (
        0,
        "Created agent agent_new (test-model)\n"
        "\n"
        "Add this to .env:\n"
        "  AGENT_ID=agent_new\n",
        "",
    )


@pytest.mark.parametrize("scenario", ["planted-404", "planted-401", "planted-500"])
def test_the_planted_errors_carry_both_values(scenario):
    # The premise of the planted scenarios: the SDK's own error exposes both, so
    # their exact expected output above proves the script shows neither.
    error = driver.LOOKUPS[scenario]
    assert driver.IN_BODY in str(error)
    assert error.request_id == driver.IN_HEADER


def test_the_driver_fails_a_case_whose_script_emits_anything_extra(tmp_path):
    # The harness itself, both ways: the real script matches its expected output
    # (above), and a copy of it that logs one extra line does not.
    scripts = tmp_path / "scripts"
    tests = tmp_path / "tests"
    scripts.mkdir()
    tests.mkdir()
    source = (TESTS.parent / "scripts" / "setup_agent.py").read_text()
    marker = "    except NotFoundError:\n"
    assert source.count(marker) == 1
    (scripts / "setup_agent.py").write_text(
        source.replace(marker, marker + "        import logging; logging.warning('extra')\n")
    )
    (tests / DRIVER.name).write_text(DRIVER.read_text())

    env = {n: v for n, v in os.environ.items() if not n.startswith(("OPENAI_", "PYTHON", "AGENT_"))}
    env.update(PYTHONDONTWRITEBYTECODE="1", AGENT_ID="agent_kept")
    result = subprocess.run(
        [sys.executable, str(tests / DRIVER.name), "404"],
        env=env, capture_output=True, text=True, timeout=60,
    )

    assert result.returncode == 1
    assert result.stderr != NOT_FOUND
    assert "extra" in result.stderr
