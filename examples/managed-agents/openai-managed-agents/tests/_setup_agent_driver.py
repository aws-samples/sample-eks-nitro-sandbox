"""Run scripts/setup_agent.py as a program against one faked agents API outcome.

  python tests/_setup_agent_driver.py <scenario>

tests/test_setup_agent.py starts this in a child process and compares the child's
entire stdout, stderr and exit status with what a reader must see. The driver
itself prints nothing: it replaces the _client module with one whose client
answers retrieve() and create() as the scenario says, then runs setup_agent.py
with runpy as __main__, the way `python scripts/setup_agent.py` does.

A call the scenario does not expect (a lookup when no AGENT_ID is set, a lookup
of another id, or a create while a kept agent is being checked) raises, and the
traceback that reaches stderr fails the test.
"""

from __future__ import annotations

import runpy
import sys
import types
from pathlib import Path
from types import SimpleNamespace

import httpx2 as httpx
import openai

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
KEPT_ID = "agent_kept"
NEW_ID = "agent_new"

# Planted where a proxy behind OPENAI_BASE_URL could put a key: the response body
# and the x-request-id header, which the SDK exposes as exc.request_id.
IN_BODY = "planted-value-in-the-response-body"
IN_HEADER = "planted-value-in-the-request-id-header"

_REQUEST = httpx.Request("GET", f"https://api.openai.example/v1/agents/{KEPT_ID}")


def status_error(cls, status: int):
    return cls("error", response=httpx.Response(status, request=_REQUEST), body=None)


def planted_error(cls, status: int):
    return cls(
        f"Error code: {status} - {{'error': '{IN_BODY}'}}",
        response=httpx.Response(status, request=_REQUEST, headers={"x-request-id": IN_HEADER}),
        body={"error": IN_BODY},
    )


# What retrieve(KEPT_ID) does in each scenario: return this object, or raise it.
LOOKUPS = {
    "kept": SimpleNamespace(id=KEPT_ID),
    "404": status_error(openai.NotFoundError, 404),
    "network": openai.APIConnectionError(request=_REQUEST),
    "401": status_error(openai.AuthenticationError, 401),
    "403": status_error(openai.PermissionDeniedError, 403),
    "500": status_error(openai.InternalServerError, 500),
    "planted-404": planted_error(openai.NotFoundError, 404),
    "planted-401": planted_error(openai.AuthenticationError, 401),
    "planted-500": planted_error(openai.InternalServerError, 500),
    "no-id-attribute": SimpleNamespace(),
    "id-none": SimpleNamespace(id=None),
    "different-id": SimpleNamespace(id="agent_other"),
}
SCENARIOS = sorted([*LOOKUPS, "create"])


class _Agents:
    def __init__(self, scenario: str):
        self._scenario = scenario

    def retrieve(self, agent_id):
        if self._scenario == "create":
            raise AssertionError("retrieve() was called although AGENT_ID is not set")
        if agent_id != KEPT_ID:
            raise AssertionError(f"retrieve() was called with {agent_id!r}, not AGENT_ID")
        outcome = LOOKUPS[self._scenario]
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome

    def create(self, **_kwargs):
        if self._scenario != "create":
            raise AssertionError("create() was called although AGENT_ID is set")
        return SimpleNamespace(id=NEW_ID)


def main() -> None:
    scenario = sys.argv[1]
    if scenario not in SCENARIOS:
        raise SystemExit(f"unknown scenario {scenario!r}")
    client = SimpleNamespace(beta=SimpleNamespace(agents=_Agents(scenario)))
    fake = types.ModuleType("_client")
    fake.make_client = lambda: client
    sys.modules["_client"] = fake

    script = SCRIPTS / "setup_agent.py"
    sys.path.insert(0, str(SCRIPTS))
    sys.argv = [str(script)]
    runpy.run_path(str(script), run_name="__main__")


if __name__ == "__main__":
    main()
