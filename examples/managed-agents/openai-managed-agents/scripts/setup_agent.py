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

Every agent id is checked against a plain-token grammar before this program does
anything with it, because the line it prints is a shell assignment you paste into
.env and load with `set -a; . ./.env; set +a`: an id that is not a plain token is
not a cosmetic problem, since loading the file would run it rather than assign
it. That applies to both sources. The endpoint OPENAI_BASE_URL selects controls
what a create returns, so a create that returns no id, a non-string one, or one
that is not a plain token stops without printing it, and says to check the
dashboard before running the step again, because the agent may exist. An AGENT_ID
you supply is checked where it is read, before the lookup, because quoting makes
a value inert in .env while the line printed here is unquoted -- so printing one
back would hand you a line that does run when you paste it.

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


# The printed line is a shell assignment the reader pastes into .env and loads with
# `set -a; . ./.env; set +a`, so an id carrying shell syntax, a space or a newline
# would be run rather than assigned, and the endpoint OPENAI_BASE_URL selects is
# what controls it. Accept only a plain token, and refuse without printing the
# value: a refusal that echoed it back would put the same string on the terminal,
# escape sequences and all. Checked against the ids the Agents API is documented to
# issue ("agent_" and a token); a legitimate id this rejects stops the step with the
# message below rather than being printed, which is the safe direction to fail in.
SAFE_AGENT_ID = re.compile(r"\A[A-Za-z0-9._-]{1,128}\Z")

NO_CREATED_ID_MESSAGE = """\
The create call for model {model} succeeded but returned no usable agent id, so
there is nothing to add to .env. An agent named "{name}"
may have been created: check the OpenAI dashboard of the project this key selects
before running this step again, so that you do not leave a second agent behind."""

UNSAFE_ENV_AGENT_ID_MESSAGE = """\
The AGENT_ID that is set is not a plain token, so it was not used and is not
repeated here: this step prints an AGENT_ID= line to paste into .env, and .env is
loaded with `set -a; . ./.env; set +a`, which would run shell syntax, a space or
a newline in it rather than assign it. Check the AGENT_ID line in .env, and the
environment if you set it there, then load the file again."""

UNSAFE_CREATED_ID_MESSAGE = """\
The create call for model {model} returned an agent id that is not a plain token,
so it was not printed: this step's output is pasted into .env and loaded with
`set -a; . ./.env; set +a`, and an id carrying shell syntax, a space or a newline
would be run by that rather than assigned. Check OPENAI_BASE_URL first, since the
endpoint it selects is what sent this. An agent named "{name}"
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
        # goes on to handle is a plain token: the line printed at the end, the 404
        # message and the could-not-confirm messages all repeat this value, and
        # the printed one is pasted into .env and loaded by a command that runs
        # what it finds. A reader's own value can carry shell syntax too, by being
        # copied from somewhere or exported by another tool.
        if not SAFE_AGENT_ID.match(agent_id):
            sys.exit(UNSAFE_ENV_AGENT_ID_MESSAGE)
        confirm_agent_exists(client, agent_id)
        print(f"AGENT_ID is set and the agent exists; keeping agent {agent_id}")
    else:
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
            sys.exit(f"Could not create an agent with model {model} ({_describe(exc)}).")
        agent_id = getattr(agent, "id", None)
        # Both refusals come before any print of the id, including the line below:
        # the call succeeded, so an agent may well exist, and saying so beats
        # inviting a second create or printing something a reader would paste.
        if not isinstance(agent_id, str) or not agent_id:
            sys.exit(NO_CREATED_ID_MESSAGE.format(model=model, name=AGENT_NAME))
        if not SAFE_AGENT_ID.match(agent_id):
            sys.exit(UNSAFE_CREATED_ID_MESSAGE.format(model=model, name=AGENT_NAME))
        print(f"Created agent {agent_id} ({model})")

    print()
    print("Add this to .env:")
    print(f"  AGENT_ID={agent_id}")


if __name__ == "__main__":
    main()
