#!/usr/bin/env bash
# fetch-kernel-patch.sh: download AWS's public Nitro Sandbox host-kernel commit from GitHub as
# a git-format patch, and verify it against packages/sources.lock (id=host-kernel-patch)
# before it takes its final name.
#
#   packages/fetch-kernel-patch.sh [destination-dir]   # default: $RUNTIME_ARTIFACTS_DIR
#   KERNEL_PATCH_FILE=/path/to/copy.patch packages/fetch-kernel-patch.sh [destination-dir]
#                                                       # use a copy you downloaded yourself;
#                                                       #   the same checks apply
#
# Fails closed, with no override flag: the patch is downloaded (or copied) to a .part file and
# checked there, so a failed, truncated or altered download is never left under the final name
# for scripts/10-kernel.sh to apply. Two checks, both against sources.lock:
#   1. its SHA-256 is the pinned sha256;
#   2. its first line is git's "From <commit> " header naming the pinned commit (ref).
# On success it prints the verified patch path.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/lib/common.sh"

DEST="${1:-$RUNTIME_ARTIFACTS_DIR}"
mkdir -p "$DEST"

commit="$(lock_field host-kernel-patch ref)"          || die "packages/sources.lock has no ref= for host-kernel-patch"
source_url="$(lock_field host-kernel-patch source)"   || die "packages/sources.lock has no source= for host-kernel-patch"
expected_sha="$(lock_field host-kernel-patch sha256)" || die "packages/sources.lock has no sha256= for host-kernel-patch"
file="$(lock_field host-kernel-patch file)"           || file="${commit}.patch"
[[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || die "packages/sources.lock host-kernel-patch sha256 is not a SHA-256: $expected_sha"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]]       || die "packages/sources.lock host-kernel-patch ref is not a full commit id: $commit"

dest_file="$DEST/$file"
part="$dest_file.part"
rm -f "$part"

if [[ -s "$dest_file" ]] && echo "$expected_sha  $dest_file" | sha256sum -c --status 2>/dev/null; then
  log "cached and verified: $file"
  printf '%s\n' "$dest_file"
  exit 0
fi

if [[ -n "${KERNEL_PATCH_FILE:-}" ]]; then
  [[ -s "$KERNEL_PATCH_FILE" ]] || die "KERNEL_PATCH_FILE not found or empty: $KERNEL_PATCH_FILE"
  log "using operator copy $KERNEL_PATCH_FILE"
  cp -- "$KERNEL_PATCH_FILE" "$part"
else
  log "fetching $source_url"
  curl -fsSL --retry 5 --retry-delay 3 -o "$part" "$source_url" || { rm -f "$part"; die "could not download $source_url"; }
fi
# An earlier run's file under the final name is dropped before the checks, so a refusal never
# leaves a stale patch behind for 10-kernel.sh to pick up.
rm -f "$dest_file"

actual="$(sha256sum "$part" | awk '{print $1}')"
if [[ "$actual" != "$expected_sha" ]]; then
  rm -f "$part"
  die "SHA-256 mismatch for the host-kernel patch from ${KERNEL_PATCH_FILE:-$source_url}
  expected: $expected_sha
  actual:   $actual
This is not the patch packages/sources.lock pins. Do not apply it. There is no override flag."
fi
first_line="$(head -n 1 "$part")"
if [[ "$first_line" != "From $commit "* ]]; then
  rm -f "$part"
  die "the host-kernel patch does not start with git's 'From $commit' header (got: '$first_line')"
fi

mv -- "$part" "$dest_file"
log "verified sha256 $dest_file (commit $commit)"
printf '%s\n' "$dest_file"
