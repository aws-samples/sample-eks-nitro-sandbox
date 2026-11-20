#!/usr/bin/env bash
# 40-build.sh (stage build, on the builder): the Twoliter build of the variant
# (cargo make), as the Amazon EKS User Guide page "Build a custom Bottlerocket AMI variant for
# Amazon EKS" shows. Twoliter is the verified binary from host-setup; no other install path
# is allowed. Prints the image sizes and the root partition use (the os-image-size-gib
# measurement).
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
[ -f "$CLONE/variants/$VARIANT/Cargo.toml" ] || die "E_BUILD: no variant; overlay did not pass"

install -D -m 0755 "$TOOLS/twoliter-x86_64-unknown-linux-musl/twoliter" "$CLONE/tools/twoliter/twoliter"
# Twoliter sets CARGO_HOME to the clone's .cargo, so cargo-make must be there too.
install -d "$CLONE/.cargo/bin"
ln -sf "$CARGO_HOME/bin/cargo-make" "$CLONE/.cargo/bin/cargo-make"

log "cargo make of $VARIANT started $(date -u +%FT%TZ), log $WORK/build.log"
set +e
( cd "$CLONE" && cargo make \
    -e BUILDSYS_VARIANT="$VARIANT" \
    -e BUILDSYS_ARCH=x86_64 \
    -e BUILDSYS_JOBS="$(nproc)" \
    -e TWOLITER_REUSE_EXISTING_INSTALL=true \
    -e TWOLITER_ALLOW_BINARY_INSTALL=false \
    -e TWOLITER_ALLOW_SOURCE_INSTALL=false ) >"$WORK/build.log" 2>&1
rc=$?
set -e
if [ "$rc" != 0 ]; then
  tail -n 60 "$WORK/build.log" >&2
  die "E_BUILD: cargo make exited $rc"
fi
log "cargo make finished $(date -u +%FT%TZ)"

find_images
for img in "$OS_IMG" "$DATA_IMG"; do
  bytes=$(lz4 -dc "$img" | wc -c)
  log "image $(basename "$img") compressed=$(stat -c %s "$img") raw=$bytes"
done
# rpm2img prints the use of each partition as JSON; ROOT-A is the measurement.
grep -o '{"ROOT-A":[^}]*}' "$WORK/build.log" | tail -n 1 | sed 's/^/builder: partition-use /' || true
log "build ok"
