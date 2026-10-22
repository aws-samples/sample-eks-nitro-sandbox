# Claude Code on the shared base. Reaches Amazon Bedrock through EKS Pod Identity;
# no model API key in the pod.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG CLAUDE_CODE_VERSION=2.1.306
ARG NODE_MAJOR=22

USER root
RUN set -eu; \
    curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash -; \
    dnf install -y nodejs; \
    dnf clean all; \
    npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
    npm cache clean --force; \
    claude --version

# Claude Code on Bedrock: the Pod Identity role is resolved from the pod's credential
# endpoint. Skip telemetry and auto-update the egress policy would refuse anyway.
# ANTHROPIC_MODEL pins the Bedrock inference profile (set on the base as MODEL_ID); without
# it Claude Code picks its own default, which may not be enabled in the account.
ENV CLAUDE_CODE_USE_BEDROCK=1 \
    ANTHROPIC_MODEL="us.anthropic.claude-sonnet-5-5" \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_AUTOUPDATER=1 \
    CLI_CMD="claude"
