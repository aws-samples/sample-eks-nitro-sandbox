# OpenAI Codex CLI on the shared base. Reaches Amazon Bedrock through EKS Pod Identity.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG CODEX_VERSION=0.163.0
ARG NODE_MAJOR=22

USER root
RUN set -eu; \
    curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash -; \
    dnf install -y nodejs; \
    dnf clean all; \
    npm install -g "@openai/codex@${CODEX_VERSION}"; \
    npm cache clean --force; \
    codex --version

# cli-setup.sh writes Codex's config.toml (the amazon-bedrock provider) into the dev user's
# home at session start (the home is the mounted workspace, so it cannot be baked into the
# image). Codex then signs Bedrock requests with the pod's Pod Identity credentials.
COPY --chmod=0755 cli-setup.sh /usr/local/bin/cli-setup.sh

ENV CLI_CMD="codex"
