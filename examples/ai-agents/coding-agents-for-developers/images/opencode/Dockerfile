# OpenCode on the shared base. Reaches Amazon Bedrock through EKS Pod Identity.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG OPENCODE_VERSION=1.19.3
ARG NODE_MAJOR=22

USER root
RUN set -eu; \
    curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash -; \
    dnf install -y nodejs; \
    dnf clean all; \
    npm install -g "opencode-ai@${OPENCODE_VERSION}"; \
    npm cache clean --force; \
    opencode --version

ENV CLI_CMD="opencode"
