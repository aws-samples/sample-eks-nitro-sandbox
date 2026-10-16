"""The Anthropic client the scripts use on your machine.

First-party Claude API (the default): Anthropic() with your organization API key
from ANTHROPIC_API_KEY.

Claude Platform on AWS (ANTHROPIC_PLATFORM=aws): AnthropicAWS() signs each
request with SigV4 using your own AWS credentials (the default credential chain,
so AWS_PROFILE works) and reads ANTHROPIC_AWS_WORKSPACE_ID and AWS_REGION.
"""

from __future__ import annotations

import os
import sys

from anthropic import Anthropic, AnthropicAWS


def on_aws() -> bool:
    return os.environ.get("ANTHROPIC_PLATFORM") == "aws"


def make_client() -> Anthropic:
    """Return the client for the configured platform, or exit naming what is missing."""
    if on_aws():
        if not os.environ.get("ANTHROPIC_AWS_WORKSPACE_ID"):
            sys.exit("Set ANTHROPIC_AWS_WORKSPACE_ID to your Claude Platform on AWS workspace id (wrkspc_...).")
        if not (os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")):
            sys.exit("Set AWS_REGION to your workspace's Region.")
        return AnthropicAWS()
    if not os.environ.get("ANTHROPIC_API_KEY"):
        sys.exit("Set ANTHROPIC_API_KEY to your organization API key (on this machine only).")
    return Anthropic()
