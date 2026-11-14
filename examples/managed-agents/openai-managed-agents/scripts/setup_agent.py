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
organization, OPENAI_BASE_URL), and says to unset AGENT_ID and run it again only
once the agent is confirmed gone; it never creates a replacement on its own. A
lookup that fails for any other reason (network, auth, 5xx) also stops, naming
the error by its SDK exception class and, when it has one, its HTTP status,
rather than being read as "agent gone". A lookup that succeeds but returns no
id, or a different agent's id, stops too, saying which.

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
project it was created in, remove AGENT_ID from .env (or unset it in this shell) and run
this step again to create a new agent."""


def confirm_agent_exists(client, agent_id: str) -> None:
    """Return if the lookup returns this agent; otherwise exit with a message.

    A 404 is not read as "gone": the SDK raises NotFoundError for any 404,
    including one caused by a mistyped id, a different project or organization,
    or a different endpoint, so the message lists those to check and says to
    remove AGENT_ID only after confirming the agent is gone. Any other failure (a
    network error, a 401 or 403, a 5xx) means "could not tell", and so does a
    successful response that does not carry this agent's id: either way the
    agent is not kept, and AGENT_ID is not suggested for removal.
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
        confirm_agent_exists(client, agent_id)
        print(f"AGENT_ID is set and the agent exists; keeping agent {agent_id}")
    else:
        if not os.environ.get("AGENT_MODEL"):
            print(f"[note] Using the PLACEHOLDER model id '{model}'. Set AGENT_MODEL in .env to a")
            print("       model id your project can use; confirm it against https://platform.openai.com/docs/models")
        agent = client.beta.agents.create(
            name=AGENT_NAME,
            model=model,
            instructions=INSTRUCTIONS,
        )
        agent_id = agent.id
        print(f"Created agent {agent.id} ({model})")

    print()
    print("Add this to .env:")
    print(f"  AGENT_ID={agent_id}")


if __name__ == "__main__":
    main()
