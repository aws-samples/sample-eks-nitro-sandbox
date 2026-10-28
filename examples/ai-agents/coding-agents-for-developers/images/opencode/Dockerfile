# OpenCode on the shared base. Reaches Amazon Bedrock through EKS Pod Identity.
# OpenCode 2.x ships as the @opencode/cli package (the older opencode-ai line stops at
# 1.x); the command is still `opencode`.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG OPENCODE_VERSION=2.1.2
ARG NODE_MAJOR=22

USER root
RUN set -eu; \
    curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash -; \
    dnf install -y nodejs; \
    dnf clean all; \
    npm install -g "@opencode/cli@${OPENCODE_VERSION}"; \
    npm cache clean --force; \
    opencode --version

# cli-setup.sh writes the Bedrock provider/model config into the dev user's home at
# session start (the home is the mounted workspace, so it cannot be baked into the image).
COPY --chmod=0755 cli-setup.sh /usr/local/bin/cli-setup.sh

# opencode reads the config cli-setup.sh writes and AWS credentials ambiently from Pod
# Identity via the AI SDK's amazon-bedrock provider.
ENV CLI_CMD="opencode" \
    CLI_RESUME_CMD="opencode --continue"
