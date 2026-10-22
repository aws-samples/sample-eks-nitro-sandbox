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
    # The package installs its command as `omp` in Bun's global bin (a symlink to the
    # package's dist/cli.js). Confirm it resolves and runs.
    test -x "$(readlink -f /usr/local/bin/omp)"; \
    /usr/local/bin/omp --version

# oh-my-pi's command is `omp`, installed into Bun's global bin (/usr/local/bin).
ENV PATH="/usr/local/bin:${PATH}" \
    CLI_CMD="omp"
