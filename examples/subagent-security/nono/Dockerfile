# The analyst and nono in one image.
#
# Build it with examples/subagent-security/ as the context, so the shared analyst files
# and this sample's own src/ are both in reach:
#   docker build -f nono/Dockerfile -t <repo>:<tag> .
#
# nono is pinned by release tag and by the SHA-256 of the release archive, so a rebuild
# gets the same binary or fails. Take both from the release's SHA256SUMS.txt when you
# move the pin.
FROM public.ecr.aws/docker/library/python:3.13-slim

ARG NONO_VERSION=0.80.0
ARG NONO_SHA256=cae6755f1188b561ea02f62995feb8ad87d457f6d5255956ec54f41bbefca31e

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/nono.tar.gz \
      "https://github.com/nolabs-ai/nono/releases/download/v${NONO_VERSION}/nono-v${NONO_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
    && echo "${NONO_SHA256}  /tmp/nono.tar.gz" | sha256sum -c - \
    && tar xzf /tmp/nono.tar.gz -C /usr/local/bin nono \
    && rm /tmp/nono.tar.gz \
    && nono --version

# --require-hashes, so the locked requirements.txt is the only thing that can be
# installed: a dependency resolved to another version fails the build.
COPY analyst/requirements.txt /opt/analyst/requirements.txt
RUN pip install --no-cache-dir --require-hashes -r /opt/analyst/requirements.txt

# The shared analyst: the same files every Subagent security sample runs.
COPY analyst/src/ /opt/analyst/
COPY analyst/fixtures/ /opt/analyst/fixtures/
# This sample's own part: the controller, the profile generator and the profiles the page
# shows.
COPY nono/src/ /opt/nono/
COPY nono/policies/ /opt/nono/policies/

# The controller runs as an ordinary user, not root. nono's filesystem and network
# controls come from Landlock and seccomp, which need no privilege.
RUN useradd --create-home --uid 1000 analyst \
    && mkdir -p /var/lib/analyst \
    && chown analyst:analyst /var/lib/analyst

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PYTHONPATH=/opt/analyst \
    NONO_NO_SAVE_PROMPT=1 NONO_NO_MIGRATE=1
USER 1000:1000
WORKDIR /var/lib/analyst
CMD ["sleep", "infinity"]
