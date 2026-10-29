# pi coding agent on the shared base. Reaches Amazon Bedrock through EKS Pod Identity.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG PI_VERSION=1.3.0
ARG NODE_MAJOR=22
# ripgrep (rg) and fd are pre-installed so pi does not try to download them at startup. pi
# looks for rg and fd on PATH and, when they are missing, fetches prebuilt binaries from
# GitHub Pages -- which the sandbox's egress policy deliberately blocks, so the download
# times out and prints a warning on every start. Amazon Linux 2023 does not package either
# tool, so install the official static (musl) release binaries at BUILD time (the build has
# network; the running pod does not need any). Pinned; recorded in the README.
ARG RIPGREP_VERSION=14.1.1
ARG FD_VERSION=10.2.0

USER root
RUN set -eu; \
    curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash -; \
    dnf install -y nodejs; \
    dnf clean all; \
    arch="x86_64-unknown-linux-musl"; \
    curl -fsSL "https://github.com/BurntSushi/ripgrep/releases/download/${RIPGREP_VERSION}/ripgrep-${RIPGREP_VERSION}-${arch}.tar.gz" \
      | tar -xz -C /tmp; \
    install -m 0755 "/tmp/ripgrep-${RIPGREP_VERSION}-${arch}/rg" /usr/local/bin/rg; \
    curl -fsSL "https://github.com/sharkdp/fd/releases/download/v${FD_VERSION}/fd-v${FD_VERSION}-${arch}.tar.gz" \
      | tar -xz -C /tmp; \
    install -m 0755 "/tmp/fd-v${FD_VERSION}-${arch}/fd" /usr/local/bin/fd; \
    rm -rf "/tmp/ripgrep-${RIPGREP_VERSION}-${arch}" "/tmp/fd-v${FD_VERSION}-${arch}"; \
    rg --version | head -1; fd --version; \
    npm install -g "@earendil-works/pi-coding-agent@${PI_VERSION}"; \
    npm cache clean --force; \
    pi --version

# pi reads AWS credentials ambiently from the pod's Pod Identity (the standard
# AWS_CONTAINER_CREDENTIALS_* variables) and takes the provider and model on the command
# line, so no config file is needed. AWS_REGION is passed by the session entrypoint.
ENV CLI_CMD="pi --provider amazon-bedrock --model us.anthropic.claude-sonnet-5-5" \
    CLI_RESUME_CMD="pi --provider amazon-bedrock --model us.anthropic.claude-sonnet-5-5 --continue"
