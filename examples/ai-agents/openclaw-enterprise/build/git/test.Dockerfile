# Standalone package/ABI/transport verification; never publishes an image.
# Build with the sample directory as context, using the same Debian 13 family
# as production. These immutable bases match the reviewed runtime repair.
FROM node:24.22.1-trixie@sha256:f1e034976f948cf212ef1f659c12e5dd58ac7eab947831813e81a62401ca38be AS build-base
RUN apt-get update --error-on=any \
    && apt-get install -y --no-install-recommends \
        build-essential dpkg-dev pkg-config libcurl4-openssl-dev zlib1g-dev \
        ca-certificates curl xz-utils

FROM build-base AS git-packages
COPY build/git /tmp/git
RUN sh /tmp/git/build.sh

FROM build-base AS expat-packages
COPY build/expat /tmp/expat
RUN sh /tmp/expat/build.sh

FROM node:24.22.1-trixie-slim@sha256:89c5244bc22a9bc3287d89ebc7e49b9cb5bb84cd40e6175ac3421d5a9f68b95a AS verify
COPY build/git/verify.sh /tmp/git-verify.sh
COPY build/expat/verify.sh /tmp/expat-verify.sh
# Start with actual distro packages, so this proves normal dpkg replacement.
RUN apt-get update --error-on=any \
    && apt-get install -y --no-install-recommends git python3 libexpat1-dev
RUN --mount=type=bind,from=git-packages,source=/out,target=/tmp/git-packages \
    --mount=type=bind,from=expat-packages,source=/out,target=/tmp/expat-packages \
    sh /tmp/git-verify.sh --packages /tmp/git-packages \
    && sh /tmp/expat-verify.sh --packages /tmp/expat-packages \
    && apt-get install -y --no-install-recommends /tmp/git-packages/*.deb /tmp/expat-packages/*.deb \
    && sh /tmp/git-verify.sh --runtime \
    && sh /tmp/expat-verify.sh --runtime \
    && dpkg-query -W git git-man libexpat1 libexpat1-dev \
    && rm -rf /var/lib/apt/lists/*
