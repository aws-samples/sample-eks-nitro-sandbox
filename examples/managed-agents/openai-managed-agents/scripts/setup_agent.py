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
it keeps that agent.

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


def main() -> None:
    client = make_client()

    model = os.environ.get("AGENT_MODEL", DEFAULT_MODEL)
    agent_id = os.environ.get("AGENT_ID")
    if agent_id:
        print(f"AGENT_ID is set; keeping agent {agent_id}")
    else:
        if model == DEFAULT_MODEL and not os.environ.get("AGENT_MODEL"):
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
