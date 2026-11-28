#!/usr/bin/env bash
# Build the sample's image from the flake, inside a pinned Nix container, and print its
# digest. Anyone who runs this on the same commit gets the same digest.
#
#   ./scripts/build.sh <flake_dir> <out_dir>                         # build, write an OCI layout
#   ./scripts/build.sh <flake_dir> <out_dir> --push <repo_uri>:<tag> <authfile>
#   ./scripts/build.sh <flake_dir> <out_dir> --push <repo_uri>:<tag> <authfile> --tag-from-digest
#   ./scripts/build.sh <flake_dir> <out_dir> --lock                  # write <out_dir>/flake.lock only
#   ./scripts/build.sh <flake_dir> <out_dir> --check                 # nix flake check, and --rebuild of server and image
#
# A build writes <out_dir>/oci (the image as an OCI layout), <out_dir>/digest,
# <out_dir>/manifest.json and <out_dir>/config.json, and prints digest=sha256:...
# --push also copies the image to the registry, authenticating with <authfile>, a
# containers-auth.json file that is mounted read-only and never put on a command line.
# --tag-from-digest (only with --push) replaces the literal string @DIGEST12@ in <tag>
# with the first 12 hex characters of the built digest before pushing, so the caller can
# write a tag such as "v1-@DIGEST12@" and get "v1-abc123def456" without a second build.
#
# Each run is a new container with an empty /nix store, so the sample's own derivations are
# built from source every time. nixpkgs' toolchain, rustc included, still comes from
# cache.nixos.org: building it under emulation would take many hours.
#
# Environment:
#   CONTAINER_RUNTIME  docker (default) or podman
#   BUILD_PRELUDE      optional, and not needed on an ordinary network. A shell script run
#                      inside the container before the build, for a network that blocks
#                      something the build fetches. Its folder is mounted read-only at
#                      /prelude, so it can bring files with it.
#   IMAGE_ATTR         image (default) or image-debug. image-debug adds busybox for kubectl exec.
set -euo pipefail

# nixos/nix:2.36.0, the linux/amd64 image, pinned by digest.
NIX_IMAGE="nixos/nix@sha256:9b6a776642088021e9251e7cdb47988747008178ca2f7398cb3e1b365bde3372"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
BUILD_PRELUDE="${BUILD_PRELUDE:-}"
# Which flake output to build: image (production) or image-debug.
IMAGE_ATTR="${IMAGE_ATTR:-image}"

# Runs inside the container as sh. $1 is the mode, $2 the push reference.
# shellcheck disable=SC2016  # expanded by the container's shell, not this one
INNER='set -eu
# Hand /out back to whoever owns the mount point. Under rootful Docker on Linux that is the
# host user, who could not otherwise remove the root-owned OCI layout; under rootless
# runtimes and Docker Desktop it is root inside, which already maps to the host user.
trap "chown -R \"\$(stat -c %u:%g /out)\" /out" EXIT
mode="$1"
ref="${2:-}"
cp -r /src /work
cd /work
if [ -n "${PRELUDE_NAME:-}" ]; then sh "/prelude/${PRELUDE_NAME}"; fi
case "${mode}" in
  lock)
    nix flake lock
    cp flake.lock /out/flake.lock
    ;;
  check)
    nix build -L ".#${IMAGE_ATTR}"
    nix flake check -L
    nix build -L .#server --rebuild
    nix build -L ".#${IMAGE_ATTR}" --rebuild
    ;;
  push-tag-from-digest)
    # Build once, write OCI layout, derive the tag from the digest, then push — all in
    # one container so the nix store is populated only once.
    nix build -L ".#${IMAGE_ATTR}"
    nix run ".#${IMAGE_ATTR}.copyTo" -- oci:/out/oci:v1
    # Read the digest from the OCI index. nixos/nix has grep, head and cut but no sed or
    # awk, so the rest is shell parameter expansion.
    digest=$(grep -o "sha256:[0-9a-f]*" /out/oci/index.json | head -1)
    digest="${digest#sha256:}"
    [ "${#digest}" -eq 64 ] || { echo "no manifest digest in /out/oci/index.json" >&2; exit 1; }
    digest12=$(printf "%s" "${digest}" | cut -c1-12)
    resolved="${ref//@DIGEST12@/${digest12}}"
    nix run ".#${IMAGE_ATTR}.copyTo" -- --dest-authfile /auth/auth.json "docker://${resolved}"
    # Write the resolved tag back to /out for the caller to read.
    printf "sha256:%s\n" "${digest}" >/out/digest
    printf "%s\n" "${resolved}" >/out/pushed-ref
    ;;
  *)
    nix build -L ".#${IMAGE_ATTR}"
    nix run ".#${IMAGE_ATTR}.copyTo" -- oci:/out/oci:v1
    if [ "${mode}" = push ]; then
      nix run ".#${IMAGE_ATTR}.copyTo" -- --dest-authfile /auth/auth.json "docker://${ref}"
    fi
    ;;
esac'

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "${IMAGE_ATTR}" =~ ^image(-debug)?$ ]] || die "IMAGE_ATTR must be image or image-debug, not ${IMAGE_ATTR}"

usage() {
  die "usage: $0 <flake_dir> <out_dir> [--lock | --check | --push <repo_uri>:<tag> <authfile> [--tag-from-digest]]"
}

nix_config() {
  local arch
  arch="$(uname -m)"
  printf '%s\n' "experimental-features = nix-command flakes" "substituters = https://cache.nixos.org"

  # An empty store downloads several GiB, so retry a dropped download for longer than the
  # defaults do. These change how Nix fetches, never what it builds.
  printf '%s\n' "download-attempts = 10" "connect-timeout = 60" "stalled-download-timeout = 600"

  # The image ships with sandbox = false on every host, because a Nix sandbox needs a
  # privileged container, so reproducibility must not depend on the sandbox: the flake fixes
  # what the missing sandbox would leave to chance, such as the build directory's name.
  # Not on x86_64, the amd64 image runs under QEMU emulation, which cannot load the seccomp
  # BPF filter Nix installs, so every derivation fails to start; filter-syscalls = false
  # turns that filter off. It does not touch content addressing, so every output path and
  # the image digest are still fixed by flake.lock.
  if [[ "${arch}" != x86_64 ]]; then
    printf '%s\n' "filter-syscalls = false"
  fi
}

write_outputs() { # write_outputs <out_dir>
  local blobs="$1/oci/blobs/sha256" digest config
  digest="$(jq -er '.manifests[0].digest' "$1/oci/index.json")" \
    || die "no manifest digest in $1/oci/index.json"
  cp "${blobs}/${digest#sha256:}" "$1/manifest.json"
  config="$(jq -er '.config.digest' "$1/manifest.json")" \
    || die "no config digest in $1/manifest.json"
  cp "${blobs}/${config#sha256:}" "$1/config.json"
  printf '%s\n' "${digest}" >"$1/digest"
  echo "digest=${digest}"
}

main() {
  [[ $# -ge 2 ]] || usage
  local flake_dir out_dir mode=build ref="" authfile="" tag_from_digest=false
  flake_dir="$(cd "$1" && pwd)" || die "no flake directory $1"
  [[ -f "${flake_dir}/flake.nix" ]] || die "no flake.nix in ${flake_dir}"
  mkdir -p "$2"
  out_dir="$(cd "$2" && pwd)"
  shift 2
  case "${1:-}" in
    "") ;;
    --lock) mode=lock ;;
    --check) mode=check ;;
    --push)
      [[ $# -ge 3 ]] || usage
      mode=push ref="$2"
      [[ -f "$3" ]] || die "no authfile $3"
      authfile="$(realpath "$3")"
      shift 3
      if [[ "${1:-}" == "--tag-from-digest" ]]; then
        tag_from_digest=true
        shift
      fi
      [[ $# -eq 0 ]] || usage
      ;;
    *) usage ;;
  esac
  if [[ "${mode}" == build || "${mode}" == push ]]; then
    [[ ! -e "${out_dir}/oci" ]] || die "${out_dir}/oci already exists; give an empty out_dir"
  fi

  # GOPROXY: the Go module fetch for nix2container's tools tries the module proxy first and
  # falls back to each module's source. With direct alone, every module is a git fetch, and
  # under Rosetta one of those hangs for good. buildGoModule passes GOPROXY through as an
  # impure variable of a fixed-output derivation, so it cannot change the output hash.
  local args=(run --rm --platform linux/amd64
    -e "NIX_CONFIG=$(nix_config)" -e "GOPROXY=${GOPROXY_BUILD:-https://proxy.golang.org,direct}"
    -e "IMAGE_ATTR=${IMAGE_ATTR}"
    -v "${flake_dir}:/src:ro" -v "${out_dir}:/out")
  if [[ -n "${authfile}" ]]; then args+=(-v "${authfile}:/auth/auth.json:ro"); fi
  if [[ -n "${BUILD_PRELUDE}" ]]; then
    [[ -f "${BUILD_PRELUDE}" ]] || die "no BUILD_PRELUDE file ${BUILD_PRELUDE}"
    local prelude_dir
    prelude_dir="$(cd "$(dirname "${BUILD_PRELUDE}")" && pwd)"
    args+=(-v "${prelude_dir}:/prelude:ro" -e "PRELUDE_NAME=$(basename "${BUILD_PRELUDE}")")
  fi

  local inner_mode="${mode}"
  if [[ "${mode}" == push && "${tag_from_digest}" == true ]]; then
    inner_mode=push-tag-from-digest
  fi

  "${CONTAINER_RUNTIME}" "${args[@]}" "${NIX_IMAGE}" sh -c "${INNER}" sh "${inner_mode}" "${ref}"

  case "${mode}" in
    lock)
      cp "${out_dir}/flake.lock" "${flake_dir}/flake.lock"
      echo "wrote ${flake_dir}/flake.lock"
      ;;
    check) echo "check passed" ;;
    push)
      if [[ "${tag_from_digest}" == true ]]; then
        # Digest was written by push-tag-from-digest; write the companion files.
        write_outputs "${out_dir}"
        [[ -f "${out_dir}/pushed-ref" ]] \
          || die "build container did not write pushed-ref; push may have failed"
        local pushed_ref
        pushed_ref="$(cat "${out_dir}/pushed-ref")"
        echo "pushed ${pushed_ref}"
      else
        write_outputs "${out_dir}"
      fi
      ;;
    *) write_outputs "${out_dir}" ;;
  esac
}

main "$@"
