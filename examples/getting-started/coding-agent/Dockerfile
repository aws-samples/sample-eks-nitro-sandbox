# coding-agent: Claude Code, git, the GitHub CLI and a Python test runner on a
# stock Node base. Everything the agent needs is installed at build time, so the
# pod needs no package-registry egress at run time.
FROM public.ecr.aws/docker/library/node:22-bookworm-slim

ARG CLAUDE_CODE_VERSION=2.1.291
ARG GH_VERSION=2.102.0
ARG GH_SHA256_AMD64=bb766f710eef8ede859c18578c72c327597cd4c8a85b06001b1f3843c6019386
ARG GH_SHA256_ARM64=7862c86c72f43df3a2d93ddde6f473285b4e2af61b494849846827e513ef6484
ARG TARGETARCH

RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git python3 python3-pytest; \
    rm -rf /var/lib/apt/lists/*

# GitHub CLI, pinned and checksum-verified, for reading the issue and opening the PR.
RUN set -eu; \
    arch="${TARGETARCH:-amd64}"; \
    case "$arch" in \
      amd64) sum="$GH_SHA256_AMD64" ;; \
      arm64) sum="$GH_SHA256_ARM64" ;; \
      *) echo "unsupported arch $arch" >&2; exit 1 ;; \
    esac; \
    tgz="gh_${GH_VERSION}_linux_${arch}.tar.gz"; \
    curl -fsSL -o "/tmp/$tgz" "https://github.com/cli/cli/releases/download/v${GH_VERSION}/$tgz"; \
    echo "$sum  /tmp/$tgz" | sha256sum -c -; \
    tar -xzf "/tmp/$tgz" -C /tmp; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" /usr/local/bin/gh; \
    rm -rf /tmp/gh_*; \
    gh --version

RUN set -eu; \
    npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
    npm cache clean --force; \
    claude --version

# Claude Code only needs the model endpoint; skip telemetry, error reporting and
# auto-update calls that the pod's egress policy would refuse anyway.
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_AUTOUPDATER=1

COPY --chmod=0755 entrypoint.sh /entrypoint.sh
RUN mkdir -p /workspace && chown node:node /workspace

USER node
WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
