#!/usr/bin/env python3
"""Create the agent. Run once, on your machine, with your application key.

An agent is a model, a system prompt and a tool set. For a self-hosted sandbox
the executor provides the Bash and apply-patch tools, so the agent is created
without hosted tools. The self-hosted environment is created per session by
submit.py (environment.type: self_hosted), not here: a self-hosted environment
is the live connection to one running executor, so it is created when a session
starts and torn down when the session is deleted.

  set -a; . ./.env; set +a
  python scripts/setup_agent.py

Prints an AGENT_ID to add to .env. Safe to run again: if AGENT_ID is already set
it looks that agent up and keeps it only if the lookup returns that agent. On a
404 it stops and lists what to check (the id, the key's project and
organization, OPENAI_BASE_URL), and says to blank AGENT_ID in .env, load .env
again and run it again only once the agent is confirmed gone; a blank AGENT_ID,
like an unset one, means "create". It never creates a replacement on its own. A
lookup that fails for any other reason (network, auth, 5xx) also stops, naming
the error by its SDK exception class and, when it has one, its HTTP status,
rather than being read as "agent gone". A lookup that succeeds but returns no
id, or a different agent's id, stops too, saying which.

Creating an agent is reported the same way: a create that raises an SDK APIError
stops, naming the error by its exception class and, when it has one, its HTTP
status, and nothing the server sent.

Every value this step interpolates into what it prints is checked before it is
printed. The line it prints is pasted into .env and loaded with
`set -a; . ./.env; set +a`, which parses the file as shell code, so an expansion
or a command in a value may run rather than being assigned. Quoting hides this: a
value can sit inertly in .env and still run once printed back unquoted, or add a
line to this step's own output.

- An agent id, from either source, must be one this step is willing to emit (see
  SAFE_AGENT_ID, which is an emission allowlist and not a claim about what the
  API issues; not every value it refuses would have run). A create that returns
  no id, a non-string one, or one outside the allowlist is refused without
  printing it, and says to check the dashboard before running the step again,
  because the agent may exist. An AGENT_ID you supply is checked where it is
  read, before the lookup, since the 404 and could-not-confirm messages repeat it
  too.
- AGENT_MODEL is echoed on one line, the one reporting a new agent, and must be a
  short token with no whitespace (see DISPLAYABLE_MODEL). A refusal that mentioned
  the model would be a second place it was echoed, so none of them does.

A refusal never repeats the offending value, since that would put the same string
on your terminal.

Two things that reach your terminal are not interpolated values and are handled
their own way: a failure inside a dependency, whose traceback could carry text
from .env or from whatever OPENAI_BASE_URL points at, so main() is wrapped below
and shows only an exception class name; and the SDK's own debug logging, which
scripts/_client.py turns off before importing it, because at debug level it
writes response headers out verbatim.

Choosing the model
------------------
Set AGENT_MODEL in .env to the model id you want. The default below is a
PLACEHOLDER, not a guaranteed-current production id: confirm a model id your
OpenAI project can use against the official model list before you rely on it,
  https://platform.openai.com/docs/models
and the Agents API quickstart, which shows the id in an agents.create call,
  https://platform.openai.com/docs/guides/agents/quickstart
Model ids change; re-check before each release. (The id must be a public OpenAI
Agents API model, not any internal/runtime identifier.)
"""

from __future__ import annotations

import os
import re
import sys

from openai import APIError, NotFoundError

from _client import make_client

# PLACEHOLDER model id. Override with AGENT_MODEL in .env. This value is taken
# from the OpenAI Agents API quickstart example as read on 2026-10-15
# (https://platform.openai.com/docs/guides/agents/quickstart); treat it as a
# placeholder and confirm a current id for your project before you rely on it.
# It is NOT a verified-stable production id and NOT an internal/runtime id.
DEFAULT_MODEL = "gpt-6-astra"
AGENT_NAME = "EKS Nitro sandbox coding assistant"
INSTRUCTIONS = (
    "You are a coding assistant. Your Bash and file-editing tools run in a codex "
    "executor inside a Nitro sandbox on Amazon EKS. Your working directory is "
    "/workspace; write any files you produce there. Inspect files directly and "
    "cite concrete details."
)


def _describe(exc: APIError) -> str:
    """Name an API error by its SDK exception class and, when it has one, its HTTP status.

    No free-form text the server sent is printed: str(exc) carries the response
    body and the request id comes from a response header, a proxy behind
    OPENAI_BASE_URL controls both, and either could carry a key.
    """
    status = getattr(exc, "status_code", None)
    name = type(exc).__name__
    return name if status is None else f"{name}, HTTP {status}"


NOT_FOUND_MESSAGE = """\
The lookup of agent {agent_id} from AGENT_ID returned HTTP 404, so it was not kept.
A 404 does not show that the agent was deleted. The same answer comes from a mistyped
AGENT_ID, from OPENAI_API_KEY, OPENAI_PROJECT_ID or OPENAI_ORG_ID selecting a different
project or organization from the one the agent was created in, or from OPENAI_BASE_URL
pointing somewhere else. Check those first.
Only once you have confirmed the agent is gone, for example in the OpenAI dashboard of the
project it was created in, change the line in .env to a blank AGENT_ID=, load the file
again with `set -a; . ./.env; set +a`, and run this step again to create a new agent."""


# A conservative allowlist for what this program is willing to EMIT as an agent
# id, not a description of what the Agents API issues: the pinned SDK types that
# field as a plain `str` and documents no prefix, alphabet or length, so nothing
# here can be a claim about the service. It is drawn tightly because the line this
# program prints is a shell assignment the reader pastes into .env and loads with
# `set -a; . ./.env; set +a`, which runs what it finds; the endpoint OPENAI_BASE_URL
# selects is what controls a returned id, and a .env can carry a quoted value that
# is inert until printed back unquoted. A refusal never echoes the value, because
# that would put the same string on the terminal, escape sequences and all.
#
# So a value this rejects is not necessarily dangerous -- an over-length id is
# perfectly shell-safe -- only outside what this program will emit unquoted. A
# legitimate id it rejects stops the step rather than being printed, which is the
# safe direction to fail in.
SAFE_AGENT_ID = re.compile(r"\A[A-Za-z0-9._-]{1,128}\Z")

# '.' and '..' match that grammar and are shell-safe, but they are URI dot-segments:
# the pinned SDK raises ValueError while building the request path, before any
# request is sent. ValueError is not an APIError, so it would escape the handlers
# below and reach the reader as a traceback.
_DOT_SEGMENTS = frozenset({".", ".."})


def is_emittable_agent_id(value: object) -> bool:
    """Whether this program may use and print `value` as an agent id."""
    return (
        isinstance(value, str)
        and SAFE_AGENT_ID.match(value) is not None
        and value not in _DOT_SEGMENTS
    )


# AGENT_MODEL comes from .env and is echoed on the success line, so it reaches the
# terminal. Quoting makes a newline or an escape sequence inert in .env while
# leaving it live in this program's output, so a value that loads without
# complaint can still add lines of its own.
#
# A byte-level check is not enough on its own. Round 11 of the second review
# forged a line with no control character at all, using a value of ordinary
# letters and spaces long enough that the terminal's own wrapping put
# "  AGENT_ID=forged" at the start of a row. So whitespace is excluded too: that
# is what the indented forgery needed, and no model id has any. The length cap is
# a local display policy, not something the API documents -- the SDK types this
# field as a plain str.
#
# Stated plainly rather than claimed as closed: this reduces display forgery, it
# does not eliminate it. On a narrow enough terminal a wrapped row can still begin
# with text from this value, unindented. Closing it completely means not echoing
# the model at all, which changes the success line the page's output block was
# recorded from; see the pull request.
DISPLAYABLE_MODEL = re.compile(r"\A[A-Za-z0-9._:/-]{1,64}\Z")

UNEXPECTED_FAILURE_MESSAGE = """\
This step stopped on an unexpected {kind}, and the details are not shown: a
failure deep in a dependency can carry text from .env or from whatever
OPENAI_BASE_URL points at, and this step will not put either on your terminal.
Check OPENAI_BASE_URL, OPENAI_API_KEY and the rest of .env, then run it again."""

NO_CREATED_ID_MESSAGE = """\
The create call succeeded but returned no usable agent id, so there is nothing
to add to .env. An agent named "{name}"
may have been created: check the OpenAI dashboard of the project this key selects
before running this step again, so that you do not leave a second agent behind."""

UNSAFE_ENV_AGENT_ID_MESSAGE = """\
The AGENT_ID that is set is not one this step will print, so it was not used and
is not repeated here. The line this step prints is pasted into .env and loaded
with `set -a; . ./.env; set +a`, which runs what it finds, so only a plain token
of letters, digits, dot, underscore and hyphen, up to 128 of them and not "." or
"..", is emitted. Check the AGENT_ID line in .env, and the environment if you set
it there, then load the file again and rerun this step."""

UNSAFE_MODEL_MESSAGE = """\
The AGENT_MODEL that is set is not one this step will print, so no agent was
created and the value is not repeated here. It is shown back to you on the line
reporting the new agent, so this step prints only a model of letters, digits,
dot, underscore, hyphen, colon or slash, up to 64 of them: no whitespace and
nothing longer. That is a limit on what this step will display, not on what the
API accepts. Quoting is why it matters -- a value can sit in .env without the
shell doing anything with it and still add a line to this step's output once
printed. Check the AGENT_MODEL line in .env, then load the file again and rerun
this step."""

UNSAFE_CREATED_ID_MESSAGE = """\
The create call returned an agent id this step will not print, so it was not
printed: the line this step prints is pasted into .env and loaded
with `set -a; . ./.env; set +a`, which runs what it finds. Check OPENAI_BASE_URL
first, since the endpoint it selects is what sent this. An agent named "{name}"
may have been created: check the OpenAI dashboard of the project this key selects
before running this step again, so that you do not leave a second agent behind."""


def confirm_agent_exists(client, agent_id: str) -> None:
    """Return if the lookup returns this agent; otherwise exit with a message.

    A 404 is not read as "gone": the SDK raises NotFoundError for any 404,
    including one caused by a mistyped id, a different project or organization,
    or a different endpoint, so the message lists those to check and says to
    blank AGENT_ID in .env and load the file again only after confirming the
    agent is gone. Any other failure (a network error, a 401 or 403, a 429, a
    5xx) means "could not tell", and so does a successful response that does not
    carry this agent's id: either way the agent is not kept, and clearing
    AGENT_ID is not suggested.
    """
    try:
        agent = client.beta.agents.retrieve(agent_id)
    except NotFoundError:
        sys.exit(NOT_FOUND_MESSAGE.format(agent_id=agent_id))
    except APIError as exc:
        sys.exit(f"Could not confirm that agent {agent_id} exists, so it was not kept ({_describe(exc)}).")
    returned_id = getattr(agent, "id", None)
    if returned_id != agent_id:
        sys.exit(
            f"Could not confirm that agent {agent_id} exists, so it was not kept: the lookup "
            f"succeeded but returned {'no agent id' if returned_id is None else 'a different agent id'}."
        )


def main() -> None:
    client = make_client()

    # `set -a; . ./.env` exports the template's blank AGENT_MODEL= as "", which
    # must mean "not set", not a model id of "".
    model = os.environ.get("AGENT_MODEL") or DEFAULT_MODEL
    agent_id = os.environ.get("AGENT_ID")
    if agent_id:
        # Checked here rather than beside the print, so that every id this program
        # goes on to handle is one it may emit: the line printed at the end, the
        # 404 message and the could-not-confirm messages all repeat this value,
        # and the printed one is pasted into .env and loaded by a command that
        # runs what it finds. A reader's own value can carry shell syntax too, by
        # being copied from somewhere or exported by another tool.
        if not is_emittable_agent_id(agent_id):
            sys.exit(UNSAFE_ENV_AGENT_ID_MESSAGE)
        confirm_agent_exists(client, agent_id)
        print(f"AGENT_ID is set and the agent exists; keeping agent {agent_id}")
    else:
        # Only this branch echoes the model, on the success line below, so the
        # check belongs here: a model this step would not print must not stop a
        # run that keeps an existing agent and never shows it.
        if not DISPLAYABLE_MODEL.match(model):
            sys.exit(UNSAFE_MODEL_MESSAGE)
        if not os.environ.get("AGENT_MODEL"):
            print(f"[note] Using the PLACEHOLDER model id '{model}'. Set AGENT_MODEL in .env to a")
            print("       model id your project can use; confirm it against https://platform.openai.com/docs/models")
        try:
            agent = client.beta.agents.create(
                name=AGENT_NAME,
                model=model,
                instructions=INSTRUCTIONS,
            )
        except APIError as exc:
            # Named by class and status only, for the reason _describe gives: a
            # creation failure's body and request-id header are server-controlled
            # too, and an unhandled exception would print the body in a traceback.
            sys.exit(f"Could not create an agent ({_describe(exc)}).")
        agent_id = getattr(agent, "id", None)
        # Both refusals come before any print of the id, including the line below:
        # the call succeeded, so an agent may well exist, and saying so beats
        # inviting a second create or printing something a reader would paste.
        if not isinstance(agent_id, str) or not agent_id:
            sys.exit(NO_CREATED_ID_MESSAGE.format(name=AGENT_NAME))
        if not is_emittable_agent_id(agent_id):
            sys.exit(UNSAFE_CREATED_ID_MESSAGE.format(name=AGENT_NAME))
        print(f"Created agent {agent_id} ({model})")

    print()
    print("Add this to .env:")
    print(f"  AGENT_ID={agent_id}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 -- deliberate; see below
        # A traceback is an output channel like any other, and not one this
        # program controls: a dependency's exception message can carry text from
        # .env or from the endpoint OPENAI_BASE_URL selects. Round 11 of the
        # second review reached three that way -- httpx2.InvalidURL carrying a
        # port from a hostile OPENAI_BASE_URL, UnicodeEncodeError carrying a
        # non-ASCII key or header value, and JSONDecodeError on a malformed 2xx.
        # So nothing the exception carries is printed, only the class's own name,
        # which comes from installed code rather than from either of those.
        # SystemExit and KeyboardInterrupt are not Exception, so a refusal above
        # and a reader's Ctrl-C both still behave as they did.
        sys.exit(UNEXPECTED_FAILURE_MESSAGE.format(kind=type(exc).__name__))
