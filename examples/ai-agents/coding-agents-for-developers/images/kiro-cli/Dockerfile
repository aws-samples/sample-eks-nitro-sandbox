# Kiro CLI on the shared base. Kiro CLI uses the developer's own Kiro sign-in, done once
# in the terminal and kept in the session's folder (under $HOME inside /workspace), not
# Amazon Bedrock. The installer pulls the latest release; record the version in the README
# from the build (`kiro-cli --version`).
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER root
# Official Kiro CLI installer (from kiro.dev/downloads). It installs the `kiro-cli`
# binary into the invoking user's ~/.local/bin; move it onto a system path so the
# unprivileged dev user runs the same binary.
RUN set -eu; \
    curl -fsSL https://cli.kiro.dev/install | bash; \
    cp -a /root/.local/bin/kiro-cli /usr/local/bin/kiro-cli; \
    chmod 0755 /usr/local/bin/kiro-cli; \
    /usr/local/bin/kiro-cli --version

# The sign-in is interactive the first time and is kept in the session's folder, so a
# restored session resumes without signing in again.
ENV CLI_CMD="kiro-cli"
