# Build with examples/subagent-security as the context and --platform linux/arm64.
FROM public.ecr.aws/docker/library/python:3.13-slim-bookworm@sha256:281d39ff02e3b389401586134ff9e6572954687822a58055ec07a60ded4e0b7f AS box-download
ARG TARGETARCH
ARG BOX_VERSION=0.2.1
ARG BOX_ARCHIVE_SHA256=9060a4ccca1d6d5153da31e9214d3fd64c9bab0aa7762b6556d2790a8a0f06c0
RUN test "$TARGETARCH" = arm64 \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && apt-get clean
WORKDIR /download
RUN curl --fail --location --proto '=https' --tlsv1.2 \
      "https://github.com/strands-agents/box/releases/download/v${BOX_VERSION}/box-v${BOX_VERSION}-linux-arm64.tar.gz" -o box.tar.gz \
    && echo "${BOX_ARCHIVE_SHA256}  box.tar.gz" | sha256sum --check - \
    && tar --extract --gzip --file box.tar.gz

FROM public.ecr.aws/docker/library/python:3.13-slim-bookworm@sha256:281d39ff02e3b389401586134ff9e6572954687822a58055ec07a60ded4e0b7f
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && apt-get clean
COPY --from=box-download /download/box /usr/local/bin/strands-box
COPY --from=box-download /download/strands-box-sock-alias /usr/local/bin/
COPY --from=box-download /download/strands-box-contain-trampoline /usr/local/bin/
COPY analyst/requirements.txt /opt/analyst/requirements.txt
RUN pip install --no-cache-dir --require-hashes -r /opt/analyst/requirements.txt
COPY analyst/src/ /opt/analyst/
COPY analyst/fixtures/ /opt/analyst/fixtures/
COPY strands-box/src/ /opt/strands-box/src/
COPY strands-box/policies/ /opt/strands-box/policies/
COPY strands-box/versions.json /opt/strands-box/versions.json
RUN useradd --create-home --uid 1000 analyst \
    && mkdir -p /var/lib/analyst \
    && chown analyst:analyst /var/lib/analyst
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/opt/analyst:/opt/strands-box/src EXPERIMENTAL_LINUX_SUPPORT=TRUE
USER 1000:1000
WORKDIR /var/lib/analyst
CMD ["sleep", "infinity"]
