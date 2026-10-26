# The brain image: the agent, a kubectl client, and the one tool that runs
# commands in a claimed sandbox.
#
# Nothing in this image is sandboxed. The brain is an ordinary pod; the
# isolation boundary is the other pod, which this one reaches only over the
# Kubernetes API.
FROM public.ecr.aws/docker/library/node:22-bookworm-slim

# Within one minor of the cluster this was built against (Kubernetes 1.37).
ARG KUBECTL_VERSION=v1.37.1
# The agent. Pinned so a rebuild gets the version this sample was checked
# against, and so the permission behaviour the page relies on is the documented
# behaviour of a known version.
ARG CLAUDE_CODE_VERSION=2.1.310
ARG TARGETARCH=amd64

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates curl python3 python3-pip \
  && rm -rf /var/lib/apt/lists/*

# kubectl: the only thing the sandbox tool shells out to.
RUN curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
  && chmod 0755 /usr/local/bin/kubectl \
  && kubectl version --client=true

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

# The MCP SDK the sandbox tool is built on. Pinned to 1.x: the tool uses the
# FastMCP API, which 2.x renamed. --break-system-packages because this is a
# single-purpose container, not a shared Python environment.
RUN pip3 install --no-cache-dir --break-system-packages "mcp>=1.6,<2"

RUN useradd --create-home --uid 10001 agent \
  && mkdir -p /workspace/.claude /opt/brain \
  && chown -R agent:agent /workspace /opt/brain

# The sandbox tool and the in-cluster kubeconfig its kubectl uses.
COPY brain/sandbox_tool.py /opt/brain/sandbox_tool.py
COPY brain/kubeconfig.yaml /opt/brain/kubeconfig.yaml

# The agent's configuration, baked in rather than mounted, so the image is what
# decides which tools the agent has.
#   settings.json  denies every tool that runs a command, and allows the
#                  sandbox tool
#   .mcp.json      registers the sandbox tool as an MCP server
COPY brain/settings.json /workspace/.claude/settings.json
COPY brain/.mcp.json /workspace/.mcp.json
# Agent state outside the project: /workspace is already trusted and the
# project's MCP server already enabled, so a non-interactive `claude -p` run
# does not stop at the trust prompt. Stopping there would leave settings.json
# unread and the sandbox tool never loaded.
COPY brain/claude.json /home/agent/.claude.json
RUN chown -R agent:agent /workspace/.claude /workspace/.mcp.json /home/agent/.claude.json

USER agent
WORKDIR /workspace
ENV HOME=/home/agent \
    KUBECONFIG=/opt/brain/kubeconfig.yaml
CMD ["sleep", "infinity"]
