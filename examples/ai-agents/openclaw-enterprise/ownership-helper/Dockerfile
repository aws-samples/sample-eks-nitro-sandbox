ARG OWNERSHIP_HELPER_BASE_IMAGE=docker.io/library/busybox:1.37.0-musl@sha256:f6a95d611e0a8780fabdb2aec43e31275b2720dfefa3e41b16835bfc42454478
FROM ${OWNERSHIP_HELPER_BASE_IMAGE} AS source

FROM scratch
COPY --from=source /bin/busybox /bin/sh
COPY --from=source /bin/busybox /bin/chown
COPY --from=source /bin/busybox /bin/chmod
