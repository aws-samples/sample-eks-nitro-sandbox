# The software provider's application image.
#
# The sample builds it twice, once per release: scripts/setup.sh builds the release in
# RELEASE_ONE and scripts/new-version.sh builds the one in RELEASE_TWO (both are in
# .env). The two releases differ in content, so they differ in digest, and that is the
# point: the second one runs under the policy generated for the first.
#
# Everything the generated Cedar policy pins is deliberately the same in both, because a
# signer-based policy drops only the image digest and keeps the rest. The working
# directory, the image USER, and the image's own environment all stay as the base image
# leaves them, and the process arguments come from the pod spec rather than from here.
# A release that changed any of those would be refused by the policy even though it is
# signed, which the page says plainly.
#
# The base tag is not pinned by digest, so an unrelated rebuild of the base would change
# this image's digest too. Pin FROM by digest if you need byte-for-byte reproducibility.
FROM public.ecr.aws/amazonlinux/amazonlinux:minimal

# The release this build is. scripts/setup.sh and scripts/new-version.sh pass it; the
# default is only here to document the shape.
ARG RELEASE=0.0.0

# The whole application: a file naming the release, and a file of release notes so the
# two builds differ by more than one byte. Both world-readable, because the pod runs as
# uid 65534 with a read-only root filesystem.
RUN mkdir -p /app \
 && printf '%s\n' "$RELEASE" > /app/release \
 && printf 'Release %s from the software provider.\n' "$RELEASE" > /app/notes.txt \
 && chmod 0444 /app/release /app/notes.txt
