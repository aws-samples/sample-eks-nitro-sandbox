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
# Releases before 3.0 dropped three binaries there (`kiro-cli`, `kiro-cli-chat`, which
# `kiro-cli chat` execs by name, and `kiro-cli-term`); 3.0 is the single `kiro-cli`. Copy
# every kiro-cli* binary the installer made, then check that `kiro-cli chat` itself starts,
# which holds for both layouts.
RUN set -eu; \
    curl -fsSL https://cli.kiro.dev/install | bash; \
    for b in /root/.local/bin/kiro-cli*; do \
      cp -a "$b" "/usr/local/bin/$(basename "$b")"; \
      chmod 0755 "/usr/local/bin/$(basename "$b")"; \
    done; \
    /usr/local/bin/kiro-cli --version; \
    /usr/local/bin/kiro-cli chat --help >/dev/null

# cli-setup.sh prepares Kiro CLI's home for V3 (session locks on tmpfs). See the script.
COPY --chmod=0755 cli-setup.sh /usr/local/bin/cli-setup.sh
# kiro-session.sh signs in with the device flow when needed, then starts the chat. See it.
COPY --chmod=0755 kiro-session.sh /usr/local/bin/kiro-session.sh

# The sign-in is kept in the session's folder (under $HOME inside /workspace), so a restored
# session resumes without signing in again. The first sign-in is interactive; inside a
# sandbox pod that means the OAuth device flow.
#
# `kiro-cli chat --v3` pins the V3 agent engine (workflows, cloud sessions, specs). The V3
# flags live on the `chat` subcommand, not on the bare `kiro-cli` entrypoint (bare
# `kiro-cli --agent-engine v3` errors "unexpected argument"), so name `chat` explicitly.
# Kiro CLI still defaults to V2 and otherwise nags to upgrade on every launch; pinning V3
# skips the nag and gives every session the current engine.
ENV CLI_CMD="/usr/local/bin/kiro-session.sh" \
    CLI_RESUME_CMD="/usr/local/bin/kiro-session.sh --resume"
