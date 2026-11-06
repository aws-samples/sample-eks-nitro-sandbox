# The brain image: the agent, and the agent-sandbox MCP server it runs commands
# through.
#
# Nothing in this image is sandboxed. The brain is an ordinary pod; the
# isolation boundary is the other pod, which this one reaches only through
# sandboxd in that pod, on the two ports its network policy admits.
FROM public.ecr.aws/docker/library/node:22-bookworm-slim

# The agent. Pinned so a rebuild gets the version this sample was checked
# against, and so the permission behaviour the page relies on is the documented
# behaviour of a known version.
ARG CLAUDE_CODE_VERSION=2.1.310
# The agent-sandbox tag the MCP server comes from. The server is not published
# to PyPI or as an image, so it is installed from this tag's source archive of
# kubernetes-sigs/agent-sandbox. Keep it equal to the sandboxd image in
# deploy/warm-pool.yaml.
ARG AGENT_SANDBOX_VERSION=v1.0.10

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates python3 python3-pip \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

# The MCP server and, through its dependencies, the agent-sandbox Python SDK with
# its async and gRPC extras (k8s-agent-sandbox[async,grpc]), which is what dials
# sandboxd. --break-system-packages because this is a single-purpose container,
# not a shared Python environment.
RUN pip3 install --no-cache-dir --break-system-packages \
      "k8s-agent-sandbox-mcp-server @ https://github.com/kubernetes-sigs/agent-sandbox/archive/refs/tags/${AGENT_SANDBOX_VERSION}.tar.gz#subdirectory=clients/integrations/mcp-server" \
  && python3 -c "import k8s_agent_sandbox_mcp_server, k8s_agent_sandbox"

RUN useradd --create-home --uid 10001 agent \
  && mkdir -p /workspace/.claude /opt/brain \
  && chown -R agent:agent /workspace /opt/brain

# The launcher that serves the MCP server over stdio with the pool and the
# namespace fixed.
COPY brain/hands_mcp.py /opt/brain/hands_mcp.py

# The agent's configuration, baked in rather than mounted, so the image is what
# decides which tools the agent has.
#   settings.json  denies every tool that runs a command, and allows the
#                  hands MCP server's tools
#   .mcp.json      registers the hands MCP server
COPY brain/settings.json /workspace/.claude/settings.json
COPY brain/.mcp.json /workspace/.mcp.json
# Project instructions Claude Code reads from /workspace: how paths in the
# hands work. The MCP server's file tools are rooted at /workspace in the
# sandbox, so without this an absolute path the model picks lands somewhere
# its commands do not look.
COPY brain/CLAUDE.md /workspace/CLAUDE.md
# Agent state outside the project: /workspace is already trusted and the
# project's MCP server already enabled, so a non-interactive `claude -p` run
# does not stop at the trust prompt. Stopping there would leave settings.json
# unread and the hands MCP server never loaded.
COPY brain/claude.json /home/agent/.claude.json
RUN chown -R agent:agent /workspace/.claude /workspace/.mcp.json /workspace/CLAUDE.md /home/agent/.claude.json

USER agent
WORKDIR /workspace
ENV HOME=/home/agent
CMD ["sleep", "infinity"]
