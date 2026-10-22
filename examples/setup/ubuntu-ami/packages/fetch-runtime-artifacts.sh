#!/usr/bin/env bash
# fetch-runtime-artifacts.sh: check for the EKS Pod Isolation runtime binaries + guest image
# and the host-kernel patch series at the paths config.env names, and verify them against
# packages/sources.lock.
#
#   packages/fetch-runtime-artifacts.sh
#
# These two inputs have NO public AWS release channel yet (see docs/SOURCES.md). This
# script never downloads them and never falls back to an internal source tree or a private
# URL: it only checks for archives the operator has already placed at
# RUNTIME_ARTIFACTS_DIR, named by the RUNTIME_ARTIFACT_FILE / PATCH_SERIES_FILE variables in
# config.env. When they are absent, it stops with the documented prerequisite and the public
# download location (cited by page title until a public page exists), exactly as setup.sh's
# preflight does, because this helper is what preflight calls.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/lib/common.sh"

: "${RUNTIME_ARTIFACT_FILE:=}"   # e.g. eks-pod-isolation-runtime-<version>.tar.gz, set in config.env
: "${PATCH_SERIES_FILE:=}"       # e.g. eks-pod-isolation-kernel-patches-<version>.tar.gz

prerequisite_message() {
  cat <<'MSG'
PREREQUISITE NOT MET: the EKS Pod Isolation runtime release artifacts are required and are
not yet obtainable from a public AWS release channel (see docs/SOURCES.md, "The release
artifacts, and the prerequisite the sample stops on"). This is a property of the feature's
pre-GA release stage, not a bug in this sample: it is designed to consume the runtime as
verified downloads from a public release the moment one exists, and to stop here until then.

To proceed once a public release exists:
  1. Obtain the runtime binaries + guest image archive, and the host-kernel patch series
     archive, from the Amazon EKS User Guide's download location for EKS Pod Isolation
     (cited here by page title until that page is published; see docs/SOURCES.md).
  2. Record their exact version and per-artifact SHA-256 in packages/sources.lock (the
     eks-pod-isolation-runtime and host-kernel-patch-series blocks) and in docs/SOURCES.md.
  3. Set RUNTIME_ARTIFACT_FILE and PATCH_SERIES_FILE in config.env to the archive filenames,
     and place both archives under RUNTIME_ARTIFACTS_DIR.
  4. Re-run this script, then ./setup.sh.

This sample never substitutes an internal source tree or a private URL for these artifacts.
MSG
}

missing=0
[[ -n "$RUNTIME_ARTIFACT_FILE" && -s "$RUNTIME_ARTIFACTS_DIR/$RUNTIME_ARTIFACT_FILE" ]] || missing=1
[[ -n "$PATCH_SERIES_FILE" && -s "$RUNTIME_ARTIFACTS_DIR/$PATCH_SERIES_FILE" ]] || missing=1

if [[ "$missing" == 1 ]]; then
  prerequisite_message
  exit 3
fi

runtime_sha="$(lock_field eks-pod-isolation-runtime sha256)" || die "packages/sources.lock has no sha256= for eks-pod-isolation-runtime"
patch_sha="$(lock_field host-kernel-patch-series sha256)"    || die "packages/sources.lock has no sha256= for host-kernel-patch-series"

case "$runtime_sha" in
  TODO-*) prerequisite_message; die "packages/sources.lock still carries a TODO placeholder for eks-pod-isolation-runtime; pin the real SHA-256 for the archive you placed before continuing." ;;
esac
case "$patch_sha" in
  TODO-*) prerequisite_message; die "packages/sources.lock still carries a TODO placeholder for host-kernel-patch-series; pin the real SHA-256 for the archive you placed before continuing." ;;
esac

verify_sha256 "$RUNTIME_ARTIFACTS_DIR/$RUNTIME_ARTIFACT_FILE" "$runtime_sha"
verify_sha256 "$RUNTIME_ARTIFACTS_DIR/$PATCH_SERIES_FILE" "$patch_sha"
log "runtime release artifacts present and verified."
