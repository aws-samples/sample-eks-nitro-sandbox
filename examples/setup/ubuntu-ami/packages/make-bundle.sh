#!/usr/bin/env bash
# make-bundle.sh: build (or consume) one deterministic archive of this sample's PUBLIC,
# fetchable dependencies, SHA-256 verified against packages/sources.lock before anything
# is added to it, with an SBOM, a license summary and a provenance record alongside.
#
#   packages/make-bundle.sh build   [output-dir]   # fetch + verify + archive + manifest
#   packages/make-bundle.sh consume <bundle-dir> [extract-dir]
#                                                   # offline: verify a pre-built bundle and
#                                                   #   extract it, no network reached
#   packages/make-bundle.sh --version
#
# What this bundles: the public, checksum-verified file inputs in sources.lock (the Linux
# kernel source, AWS's public host-kernel patch, erofs-utils source). It never bundles the
# Ubuntu base AMI (resolved per Region from a signed SSM parameter, not a file to archive) or
# distro apt packages (capability-asserted against a reader's own apt snapshot, not a moving
# target to pin here; see sources.lock block 8).
#
# What this never bundles: the Nitro Sandbox runtime release, the guest image pair and
# Firecracker (sources.lock blocks 5 to 7, kinds signed-archive, sidecar-file and archive-member):
# the build host downloads and verifies those itself (packages/fetch-runtime-artifacts.sh), and the
# guest disk alone is 2 GiB. `build` takes only kind=file inputs, and skips any whose status is not
# `available`, listing it in the emitted manifest as an external slot. This command never fetches,
# embeds or commits an input that is not available.
#
# Determinism: the archive this command produces is byte-identical across two runs over
# the same inputs (same member order, same mtime/owner/group, no host-dependent metadata),
# so a second `build` yields the same archive SHA-256. See packages/test-bundle.sh for the
# two-build proof. Requires GNU tar (for --sort=name / --mtime); see bundle-common.sh.
#
# Fail-closed: a SHA-256 mismatch on any fetched input, or on the archive/components during
# `consume`, aborts with a non-zero exit and no override flag. `build` never substitutes an
# internal source tree or a private URL for an input that cannot be verified.
set -euo pipefail

VERSION="1.0"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bundle-common.sh
. "$HERE/lib/bundle-common.sh"

: "${LOCK_FILE:=$HERE/sources.lock}"
# REPO_ROOT: this sample's own tmp/ lives three levels up from packages/ (packages/ ->
# ubuntu-ami/ -> setup/ -> examples/ -> repo root), so the default build output goes to
# the REPOSITORY's gitignored tmp/, never under examples/setup/ and never committed. Found
# by walking up to the directory that holds AGENTS.md rather than counting ".." segments,
# so moving this script would not silently miscompute the default.
REPO_ROOT="$HERE"
while [[ "$REPO_ROOT" != "/" && ! -f "$REPO_ROOT/AGENTS.md" ]]; do
  REPO_ROOT="$(dirname "$REPO_ROOT")"
done
[[ -f "$REPO_ROOT/AGENTS.md" ]] || REPO_ROOT="$HERE/../../../.."
DEFAULT_OUT_DIR="$REPO_ROOT/tmp/issue10/bundle"

usage() {
  cat <<USAGE
Usage:
  packages/make-bundle.sh build   [output-dir]              (default: $DEFAULT_OUT_DIR)
  packages/make-bundle.sh consume <bundle-dir> [extract-dir] (default extract-dir: <bundle-dir>/extracted)
  packages/make-bundle.sh --version

Environment:
  LOCK_FILE   path to sources.lock (default: packages/sources.lock next to this script)
USAGE
}

cmd_build() {
  local out_dir="${1:-$DEFAULT_OUT_DIR}"
  mkdir -p "$out_dir"
  local staging
  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' RETURN

  bundle_log "building dependency bundle from $LOCK_FILE into $out_dir"
  [[ -s "$LOCK_FILE" ]] || bundle_die "missing or empty lock file: $LOCK_FILE"

  local bundled_ids=()
  local id kind status
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    kind="$(bundle_lock_field "$LOCK_FILE" "$id" kind)" || continue
    status="$(bundle_lock_field "$LOCK_FILE" "$id" status)" || continue
    if [[ "$kind" != "file" ]]; then
      bundle_log "skip $id: kind=$kind is not a bundleable file input (e.g. an SSM-resolved AMI)"
      continue
    fi
    if [[ "$status" != "available" ]]; then
      bundle_log "skip $id: status=$status, not a public fetchable input yet (external, user-supplied slot)"
      continue
    fi
    local sha
    sha="$(bundle_lock_field "$LOCK_FILE" "$id" sha256)" || sha=""
    case "$sha" in
      ""|n/a)
        bundle_log "skip $id: no concrete sha256 to verify against (capability-asserted input, e.g. distro packages)"
        continue ;;
    esac
    bundle_fetch_file "$LOCK_FILE" "$id" "$staging" >/dev/null
    bundled_ids+=("$id")
  done < <(bundle_lock_ids "$LOCK_FILE")

  [[ "${#bundled_ids[@]}" -gt 0 ]] || bundle_die "no bundleable inputs found in $LOCK_FILE (nothing with kind=file, status=available and a concrete sha256)"

  local components_csv
  components_csv="$(IFS=';'; echo "${bundled_ids[*]}")"
  bundle_log "bundling ${#bundled_ids[@]} component(s): $components_csv"

  local archive="$out_dir/dependency-bundle.tar"
  local manifest="$out_dir/dependency-bundle.manifest.json"
  bundle_create_archive "$archive" "$staging"
  bundle_write_manifest "$manifest" "$LOCK_FILE" "$staging" "$archive" "$components_csv" "$VERSION"

  bundle_log "build complete."
  bundle_log "  archive:  $archive"
  bundle_log "  manifest: $manifest"
  printf '%s\n' "$archive"
}

cmd_consume() {
  local bundle_dir="${1:-}" extract_dir="${2:-}"
  [[ -n "$bundle_dir" ]] || { usage; bundle_die "consume requires <bundle-dir>"; }
  extract_dir="${extract_dir:-$bundle_dir/extracted}"
  local archive="$bundle_dir/dependency-bundle.tar"
  local manifest="$bundle_dir/dependency-bundle.manifest.json"
  bundle_log "consuming pre-built bundle from $bundle_dir (offline, no network reached)"
  bundle_verify_archive "$archive" "$manifest" "$LOCK_FILE" "$extract_dir"
  bundle_log "bundle accepted; extracted components are in $extract_dir"
  printf '%s\n' "$extract_dir"
}

case "${1:-}" in
  build)   shift; cmd_build "$@" ;;
  consume) shift; cmd_consume "$@" ;;
  --version) printf 'make-bundle.sh %s\n' "$VERSION" ;;
  -h|--help|"") usage; [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] ;;
  *) usage; bundle_die "unknown subcommand: $1" ;;
esac
