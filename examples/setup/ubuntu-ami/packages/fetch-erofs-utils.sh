#!/usr/bin/env bash
# fetch-erofs-utils.sh: download the pinned erofs-utils cgit snapshot and verify it against
# packages/sources.lock before anything builds it.
#
#   packages/fetch-erofs-utils.sh [destination-dir]  # default: $RUNTIME_ARTIFACTS_DIR
#
# The snapshot is a cgit-generated archive of a tag, not a release tarball with its own
# upstream-published checksum, so the pinned SHA-256 is owned by this sample (see
# packages/SOURCES.txt). A mismatch here can mean cgit's archive generation changed; it aborts
# the same way a corrupt download would, with no override flag.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/lib/common.sh"

DEST="${1:-$RUNTIME_ARTIFACTS_DIR}"
mkdir -p "$DEST"

ref="$(lock_field erofs-utils-source ref)"           || die "packages/sources.lock has no ref= for erofs-utils-source"
source_url="$(lock_field erofs-utils-source source)" || die "packages/sources.lock has no source= for erofs-utils-source"
expected_sha="$(lock_field erofs-utils-source sha256)" || die "packages/sources.lock has no sha256= for erofs-utils-source"

file="erofs-utils-${ref}.tar.gz"
dest_file="$DEST/$file"

if [[ -s "$dest_file" ]] && echo "$expected_sha  $dest_file" | sha256sum -c --status 2>/dev/null; then
  log "cached and verified: $file"
else
  log "fetching $source_url"
  curl -fsSL --retry 5 --retry-delay 3 -o "$dest_file" "$source_url"
  verify_sha256 "$dest_file" "$expected_sha"
fi

log "erofs-utils source ready: $dest_file (sha256 $expected_sha)"
printf '%s\n' "$dest_file"
