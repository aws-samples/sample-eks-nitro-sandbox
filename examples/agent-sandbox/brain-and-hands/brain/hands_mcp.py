#!/usr/bin/env python3
"""The brain's one execution path: the upstream agent-sandbox MCP server, over stdio.

The agent in the brain pod has no shell tool of its own. Claude Code starts this
process as the `hands` MCP server (see brain/.mcp.json), and it is the agent's
only way to run anything. It is the MCP server from kubernetes-sigs/agent-sandbox
(clients/integrations/mcp-server), unchanged, with two differences in how it is
served:

1. It runs over stdio, as a child of the agent, instead of the upstream image's
   streamable HTTP on 0.0.0.0:8000. Upstream ships that listener with no
   authentication, so not opening one is the simplest way to keep anything else
   in the cluster from driving it.

2. The arguments that choose WHERE a sandbox comes from are hidden from the
   model and filled in from this pod's environment (deploy/brain.yaml):
   `namespace` on every tool, and `warmpool`, `labels`, `pod_labels` and
   `pod_annotations` on create_sandbox. So the model can claim from one pool, in
   one namespace, and cannot label or annotate the claim or the pod it is
   handed. The `sandboxes://{namespace}` resource template is removed for the
   same reason.

sandboxd in the hands requires a bearer token. Its value is mounted from a
Secret as a file (HANDS_TOKEN_FILE) and read here, so it is never in the pod
spec, an environment variable of the pod, or a command line.

The claim name stays a tool argument, as upstream has it. The server only acts
on claims this MCP session created (it labels each claim with the session ID and
checks the label on every call), which is an application-level control. The
hard limits are below it: the RBAC Role in deploy/rbac.yaml, which covers claims
and Sandboxes in one namespace and nothing else, and the network policy on the
hands' template, which admits only this pod on sandboxd's two ports.

How it reaches the hands is the server's own configuration, also from the pod's
environment: K8S_SANDBOX_CONNECTION__TYPE=sandboxd-in-cluster dials sandboxd in
the claimed pod directly, gRPC on 9090 for commands and REST on 8080 for files,
so neither goes through the Kubernetes API.
"""

import os
import sys

from fastmcp.server.transforms import ToolTransform
from fastmcp.tools.tool_transform import ArgTransformConfig, ToolTransformConfig
from k8s_agent_sandbox_mcp_server.server import create_mcp_server

NAMESPACE = os.environ["HANDS_NAMESPACE"]
WARMPOOL = os.environ["HANDS_WARMPOOL"]
TOKEN_FILE = os.environ.get("HANDS_TOKEN_FILE", "")

# The server's settings read the token from this variable (pydantic-settings,
# prefix K8S_SANDBOX_, nested with __). It is set in this process only, after
# the agent has started it, so it reaches the server and nothing the pod spec
# shows.
if TOKEN_FILE:
    with open(TOKEN_FILE, encoding="ascii") as handle:
        os.environ["K8S_SANDBOX_CONNECTION__AUTH_TOKEN"] = handle.read().strip()

# Every upstream tool that takes a namespace. create_sandbox also takes the pool
# and the pod's labels and annotations.
TOOLS_WITH_NAMESPACE = (
    "create_sandbox",
    "delete_sandbox",
    "execute_command",
    "upload_file",
    "download_file",
    "list_files",
    "file_exists",
    "get_sandbox_status",
)


def _hidden(value=None):
    # hide=True removes the argument from the schema the model sees. With a
    # default, the server passes that constant to the upstream tool; without
    # one, the upstream tool's own default (None) applies.
    if value is None:
        return ArgTransformConfig(hide=True)
    return ArgTransformConfig(hide=True, default=value)


def build():
    mcp = create_mcp_server()
    transforms = {}
    for name in TOOLS_WITH_NAMESPACE:
        args = {"namespace": _hidden(NAMESPACE)}
        if name == "create_sandbox":
            args["warmpool"] = _hidden(WARMPOOL)
            args["labels"] = _hidden()
            args["pod_labels"] = _hidden()
            args["pod_annotations"] = _hidden()
        transforms[name] = ToolTransformConfig(arguments=args)
    mcp.add_transform(ToolTransform(transforms))
    mcp.local_provider.remove_template("sandboxes://{namespace}")
    return mcp


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--print-tools":
        # Print the tool schemas the model is given, then exit. Used by the page
        # to show what the agent can and cannot set.
        import asyncio
        import json

        from fastmcp import Client

        async def _dump():
            async with Client(build()) as client:
                for tool in await client.list_tools():
                    print(json.dumps({"name": tool.name,
                                      "arguments": sorted(tool.inputSchema.get("properties", {}))}))

        asyncio.run(_dump())
    else:
        build().run()  # stdio
