# openai-sandbox-executor: one image, two roles, chosen by the container's args:
#   python -m launcher launch   the launcher Deployment (ordinary pod)
#   python -m launcher serve    the sandbox, one session per pod (SandboxTemplate)
#
# The image carries the launcher/dispatch Python and the codex exec-server the
# sandbox runs. codex exec-server is the OpenAI executor: it dials out to the
# session's environment and runs the agent's built-in Bash and apply-patch tools.
#
# Codex CLI is pinned to an exact alpha build. As of 2026-10-15 the npm `alpha`
# dist-tag is 0.163.0-alpha.11 and `latest` is 0.162.1, so exec-server has not
# reached the stable `latest` channel; pin the exact alpha the issue names rather
# than the moving `alpha` tag. Re-check the channel before each release.
FROM public.ecr.aws/docker/library/python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false

ARG CODEX_VERSION=0.163.0-alpha.11

# codex needs Node, and its built-in tools shell out to /bin/bash, git, ripgrep
# and apply-patch helpers. Install Node from the distro, pin codex to the exact
# version, then drop apt lists.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates curl git nodejs npm ripgrep \
    && npm install --global "@openai/codex@${CODEX_VERSION}" \
    && ln -sf "$(npm root -g)/@openai/codex/bin/codex.js" /usr/local/bin/codex 2>/dev/null || true \
    && (command -v codex >/dev/null || ln -sf "$(npm bin -g)/codex" /usr/local/bin/codex) \
    && codex --version \
    && npm cache clean --force \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY pyproject.toml ./
COPY src ./src
RUN pip install .

# Run as a non-root user. /workspace is the executor's working directory; the
# pod mounts an emptyDir over it, so it is fresh for every claimed session.
RUN useradd --uid 1000 --create-home --home-dir /workspace agent
USER 1000
WORKDIR /workspace
# Library and codex caches land in the writable workspace, not on the read-only
# root filesystem the pod runs with.
ENV HOME=/workspace \
    CODEX_HOME=/workspace/.codex \
    CODEX_PATH=/usr/local/bin/codex

ENTRYPOINT ["python", "-m", "launcher"]
