#!/usr/bin/env bash
# fetch-runtime-artifacts.sh: download the Nitro Sandbox runtime release, the guest image pair and
# Firecracker from their public locations and verify them against packages/sources.lock, the way
# the Amazon EKS User Guide pages "Download and verify the runtime binaries" and "Create and update
# a Nitro Sandbox AMI" describe.
#
#   packages/fetch-runtime-artifacts.sh --check        # the small published files only
#   packages/fetch-runtime-artifacts.sh [dest-dir]     # everything; default: $RUNTIME_ARTIFACTS_DIR
#
# --check (./setup.sh --prepare on the workstation, and 00-preflight.sh on the build host before the
# kernel build) downloads no large file. It checks the committed public key against its pin,
# downloads the runtime release's SHA256SUM and SHA256SUM.sig, checks the manifest's SHA-256 against
# its pin, verifies its signature with `openssl dgst -sha384 -verify`, and checks that it lists the
# archive and the shim with their pinned SHA-256; it downloads the guest image's two .sha256
# sidecars and Firecracker's .sha256.txt and checks each value against its pin.
#
# The full run (scripts/30-runtime-install.sh, on the build host) does all of that, then downloads
# the runtime archive (about 40 MB), the guest EIF and disk (2 GiB) and the Firecracker tarball,
# checks each one's SHA-256, checks every member of each archive before anything is read out of it
# (the runtime archive must be flat, regular files only; nothing in either archive may be absolute,
# hold '..', or be a link or a device; no name twice), and reads out the shim, firecracker and
# jailer, each checked against its pin. Every file the node gets ends up in <dest-dir>/node-files,
# named by its sources.lock id; the signed manifest and its signature are kept in
# <dest-dir>/signed-manifest. It prints the node-files folder as its last line.
#
# Every check fails closed (exit 1, the reason on a FATAL line, no override flag). The work is in
# packages/lib/runtime_verify.py.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/lib/common.sh"

for tool in python3 curl openssl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required to download and verify the runtime inputs"
done
[[ -s "$LOCK_FILE" ]] || die "missing or empty $LOCK_FILE"

if [[ "${1:-}" == --check ]]; then
  [[ $# -eq 1 ]] || die "--check takes no other argument"
  python3 "$HERE/lib/runtime_verify.py" check "$LOCK_FILE" "$RUNTIME_ARTIFACTS_DIR" \
    || die "the runtime inputs did not verify against packages/sources.lock (see the FATAL line above)"
  exit 0
fi
case "${1:-}" in -*) die "unknown argument: $1 (supported: --check, or a destination folder)" ;; esac
[[ $# -le 1 ]] || die "too many arguments"
DEST="${1:-$RUNTIME_ARTIFACTS_DIR}"
mkdir -p "$DEST"
python3 "$HERE/lib/runtime_verify.py" fetch "$LOCK_FILE" "$DEST" \
  || die "the runtime inputs did not verify against packages/sources.lock (see the FATAL line above)"
