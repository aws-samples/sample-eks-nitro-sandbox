#!/usr/bin/env python3
"""Create the agent and the self-hosted environment. Run once, on your machine.

Uses your organization API key (ANTHROPIC_API_KEY). Creates whichever of the
two is not in your environment yet, so it is safe to run again:

  * an agent: a model, a system prompt and the built-in agent_toolset_20260401
    tools (bash, read, write, edit, glob, grep);
  * a self-hosted environment: the work queue your cluster serves.

Then generate an environment key for the environment in the Claude Console;
there is no API that creates one.

  set -a; . ./.env; set +a
  python scripts/setup_agent.py
"""

from __future__ import annotations

import os
import sys

from anthropic import Anthropic

MODEL = "claude-sonnet-5-5"
AGENT_NAME = "EKS sandbox coding assistant"
SYSTEM_PROMPT = (
    "You are a coding assistant. Your tools run in a sandbox on Amazon EKS. "
    "Your working directory is /workspace; write any files you produce there."
)
ENVIRONMENT_NAME = "eks-nitro-sandbox"


def main() -> None:
    if not os.environ.get("ANTHROPIC_API_KEY"):
        sys.exit("Set ANTHROPIC_API_KEY to your organization API key (on this machine only).")
    client = Anthropic()

    agent_id = os.environ.get("AGENT_ID")
    if agent_id:
        print(f"AGENT_ID is set; keeping agent {agent_id}")
    else:
        agent = client.beta.agents.create(
            name=AGENT_NAME,
            model=MODEL,
            system=SYSTEM_PROMPT,
            tools=[{"type": "agent_toolset_20260401"}],
        )
        agent_id = agent.id
        print(f"Created agent {agent.id} ({MODEL})")

    environment_id = os.environ.get("ANTHROPIC_ENVIRONMENT_ID")
    if environment_id:
        print(f"ANTHROPIC_ENVIRONMENT_ID is set; keeping environment {environment_id}")
    else:
        environment = client.beta.environments.create(
            name=ENVIRONMENT_NAME,
            config={"type": "self_hosted"},
        )
        environment_id = environment.id
        print(f"Created self-hosted environment {environment.id}")

    print()
    print("Add these to .env:")
    print(f"  AGENT_ID={agent_id}")
    print(f"  ANTHROPIC_ENVIRONMENT_ID={environment_id}")
    if not os.environ.get("ANTHROPIC_ENVIRONMENT_KEY"):
        print("Then, in the Claude Console, open Workspace > Environments > your")
        print("environment > Generate environment key, and add it as")
        print("  ANTHROPIC_ENVIRONMENT_KEY=...")


if __name__ == "__main__":
    main()
