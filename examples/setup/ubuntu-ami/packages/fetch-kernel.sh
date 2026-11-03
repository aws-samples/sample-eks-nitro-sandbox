#!/usr/bin/env bash
# fetch-kernel.sh: download the pinned Linux kernel source tarball from kernel.org and
# verify it against packages/sources.lock before anything unpacks it.
#
#   packages/fetch-kernel.sh [destination-dir]      # default: $RUNTIME_ARTIFACTS_DIR
#
# Fails closed: a SHA-256 mismatch aborts with a non-zero exit and no override flag, because
# an artifact that does not match the lock file is not the kernel source this sample was
# built and reviewed against.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/lib/common.sh"

DEST="${1:-$RUNTIME_ARTIFACTS_DIR}"
mkdir -p "$DEST"

ref="$(lock_field linux-kernel-source ref)"       || die "packages/sources.lock has no ref= for linux-kernel-source"
source_url="$(lock_field linux-kernel-source source)" || die "packages/sources.lock has no source= for linux-kernel-source"
expected_sha="$(lock_field linux-kernel-source sha256)" || die "packages/sources.lock has no sha256= for linux-kernel-source"

file="linux-${ref}.tar.xz"
dest_file="$DEST/$file"

if [[ -s "$dest_file" ]] && echo "$expected_sha  $dest_file" | sha256sum -c --status 2>/dev/null; then
  log "cached and verified: $file"
else
  log "fetching $source_url"
  curl -fsSL --retry 5 --retry-delay 3 -o "$dest_file" "$source_url"
  verify_sha256 "$dest_file" "$expected_sha"
fi

log "kernel source ready: $dest_file (sha256 $expected_sha)"
printf '%s\n' "$dest_file"
