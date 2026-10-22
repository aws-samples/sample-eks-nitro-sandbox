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

# pi reads AWS credentials ambiently from the pod's Pod Identity (the standard
# AWS_CONTAINER_CREDENTIALS_* variables) and takes the provider and model on the command
# line, so no config file is needed. AWS_REGION is passed by the session entrypoint.
ENV CLI_CMD="pi --provider amazon-bedrock --model us.anthropic.claude-sonnet-5-5"
