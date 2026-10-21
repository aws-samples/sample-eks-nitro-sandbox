# pi coding agent on the shared base. Reaches Amazon Bedrock through EKS Pod Identity.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG PI_VERSION=1.3.0
ARG NODE_MAJOR=22

USER root
RUN set -eu; \
    curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash -; \
    dnf install -y nodejs; \
    dnf clean all; \
    npm install -g "@earendil-works/pi-coding-agent@${PI_VERSION}"; \
    npm cache clean --force; \
    pi --version

ENV CLI_CMD="pi"
