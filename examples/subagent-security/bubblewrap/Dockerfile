# The analyst and bubblewrap in one image.
#
# Build it with examples/subagent-security/ as the context, so the shared analyst files
# and this sample's own src/ are both in reach:
#   docker build -f bubblewrap/Dockerfile -t <repo>:<tag> .
#
# bubblewrap is built from upstream source at a pinned commit, with no patches. The
# commit is checked after the checkout and the release tag is checked to point at it, so
# a tag moved upstream cannot change what goes in the image. The pin is written into the
# image and the run reads it back, which is how the page's version claim is checked
# rather than asserted.
FROM public.ecr.aws/docker/library/python:3.13-slim AS bubblewrap

ARG BWRAP_VERSION=0.13.1
ARG BWRAP_COMMIT=362936aea0d5c6e70f7af75d2d44b5a914cb4ba2

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates git gcc libc6-dev pkg-config meson ninja-build libcap-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/containers/bubblewrap.git /src \
    && cd /src \
    && git checkout --detach "$BWRAP_COMMIT" \
    && test "$(git rev-parse HEAD)" = "$BWRAP_COMMIT" \
    && test "$(git rev-parse "v${BWRAP_VERSION}^{commit}")" = "$BWRAP_COMMIT" \
    && meson setup _build --prefix=/usr/local \
         -Dman=disabled -Dtests=false -Dselinux=disabled \
         -Dbash_completion=disabled -Dzsh_completion=disabled \
    && meson compile -C _build \
    && meson install -C _build \
    && printf '%s %s\n' "$BWRAP_VERSION" "$BWRAP_COMMIT" \
       > /usr/local/share/bubblewrap-pin

FROM public.ecr.aws/docker/library/python:3.13-slim

# libcap2 is what bwrap links against. libseccomp2 is what the controller loads through
# ctypes to compile a BPF filter; bubblewrap itself does not depend on it, because
# --add-seccomp-fd takes a compiled filter and the caller is the one that compiles it.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates libcap2 libseccomp2 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=bubblewrap /usr/local/bin/bwrap /usr/local/bin/bwrap
COPY --from=bubblewrap /usr/local/share/bubblewrap-pin /usr/local/share/bubblewrap-pin
RUN bwrap --version && cat /usr/local/share/bubblewrap-pin

# --require-hashes, so the locked requirements.txt is the only thing that can be
# installed: a dependency resolved to another version fails the build.
COPY analyst/requirements.txt /opt/analyst/requirements.txt
RUN pip install --no-cache-dir --require-hashes -r /opt/analyst/requirements.txt

# The shared analyst: the same files every Subagent security sample runs.
COPY analyst/src/ /opt/analyst/
COPY analyst/fixtures/ /opt/analyst/fixtures/
# This sample's own part: the controller, the bwrap launcher, the seccomp filter compiler
# and the tool entry point.
COPY bubblewrap/src/ /opt/bubblewrap/

# The controller runs as an ordinary user, not root, and so does every tool process it
# launches. /home/analyst exists in the image only so that the page's claim about the
# child's HOME has somewhere real to point; bwrap gives the child its own empty one.
RUN useradd --create-home --uid 1000 analyst \
    && mkdir -p /var/lib/analyst \
    && chown analyst:analyst /var/lib/analyst

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    PYTHONPATH=/opt/analyst:/opt/bubblewrap
USER 1000:1000
WORKDIR /var/lib/analyst
CMD ["sleep", "infinity"]
