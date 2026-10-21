# Kiro CLI on the shared base. Kiro CLI uses the developer's own Kiro sign-in, done once
# in the terminal and kept in the session's folder (under $HOME inside /workspace), not
# Amazon Bedrock. The version is pinned to the latest release at build time; record it in
# the README from the build.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER root
# Kiro CLI ships a Linux installer from kiro.dev. Install to a shared location on PATH.
# The installed version is captured in the README from the build (`kiro --version`).
RUN set -eu; \
    curl -fsSL https://kiro.dev/install/cli.sh -o /tmp/kiro-install.sh; \
    sh /tmp/kiro-install.sh --to /usr/local/bin; \
    rm -f /tmp/kiro-install.sh; \
    kiro --version

# The sign-in is interactive the first time and is kept in the session's folder, so a
# restored session resumes without signing in again.
ENV CLI_CMD="kiro"
