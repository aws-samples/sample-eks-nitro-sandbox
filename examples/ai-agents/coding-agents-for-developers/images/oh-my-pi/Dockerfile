# oh-my-pi on the shared base. Needs Bun (not Node). Reaches Amazon Bedrock through
# EKS Pod Identity.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG OH_MY_PI_VERSION=18.12.5

USER root
# Bun, installed to a shared location and symlinked onto PATH.
RUN set -eu; \
    export BUN_INSTALL=/usr/local; \
    curl -fsSL https://bun.sh/install | bash; \
    /usr/local/bin/bun --version; \
    bun add -g "@oh-my-pi/pi-coding-agent@${OH_MY_PI_VERSION}"; \
    ln -sf /usr/local/bin/oh-my-pi /usr/local/bin/oh-my-pi || true

# oh-my-pi installs its binary into Bun's global bin; make sure it is on PATH.
ENV PATH="/usr/local/bin:/root/.bun/bin:${PATH}" \
    CLI_CMD="oh-my-pi"
