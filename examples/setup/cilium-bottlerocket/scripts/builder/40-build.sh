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
  # The useful lines of the log, without the Go stack traces of BuildKit, to stdout (SSM keeps
  # up to 24,000 characters of stdout and 8,000 of stderr).
  grep -v -E '^[[:space:]]+(github\.com|google\.golang\.org|golang\.org|/builddir|/usr/lib/golang|runtime\.|sync\.|[0-9]+ +/)' "$WORK/build.log" \
    | grep -v -E '^[[:space:]]*$' | tail -n 250 | tail -c 20000
  die "E_BUILD: cargo make exited $rc"
fi
log "cargo make finished $(date -u +%FT%TZ)"

find_images
for img in "$OS_IMG" "$DATA_IMG"; do
  bytes=$(lz4 -dc "$img" | wc -c)
  log "image $(basename "$img") compressed=$(stat -c %s "$img") raw=$bytes"
done
# rpm2img records the use of each partition in artifact-metadata.json; ROOT-A is the
# measurement for os-image-size-gib.
python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))["disk_usage"]
for k in sorted(d):
    v = d[k]
    print("builder: partition-use %s bytes_used=%s bytes_total=%s percent=%s" % (k, v["bytes_used"], v["bytes_total"], v["percentage_bytes"]))' \
  "$IMG_DIR/artifact-metadata.json" || die "E_BUILD: no partition use in $IMG_DIR/artifact-metadata.json"
# ROOT-A holds the guest image pair. rpm2img copies the root image into its partition with no
# size check, so the build stops here when ROOT-A uses more than its partition.
fit=$(python3 -I -c 'import json, sys
r = json.load(open(sys.argv[1]))["disk_usage"]["ROOT-A"]
u, t = int(r["bytes_used"]), int(r["bytes_total"])
print("used=%d total=%d %s" % (u, t, "ok" if u <= t else "no"))' "$IMG_DIR/artifact-metadata.json") \
  || die "E_ROOT_FIT: artifact-metadata.json has no ROOT-A bytes_used and bytes_total"
[ "${fit##* }" = ok ] || die "E_ROOT_FIT: ROOT-A ${fit% *} bytes; the root file system with the guest image pair does not fit os-image-size-gib"
log "root-fit ROOT-A ${fit% *} ok"
log "build ok"
