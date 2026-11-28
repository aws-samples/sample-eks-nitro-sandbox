#!/usr/bin/env bash
# Run the Linux Cedar policy generator in a container, so the scripts work on macOS too.
#
#   GENPOLICY_BIN=/path/to/eks-nitro-sandbox-genpolicy \
#     GENPOLICY="$PWD/scripts/genpolicy-container.sh" ./scripts/setup.sh
#
# Takes the same arguments as the generator. GENPOLICY_BIN is the Linux binary for your
# machine's architecture. The repository is mounted at its own path, so the absolute paths
# the scripts pass work unchanged, and only $HOME/.docker (the registry credentials the
# scripts write for the generator) is mounted from HOME, read-only.
set -euo pipefail

: "${GENPOLICY_BIN:?set GENPOLICY_BIN to the Linux eks-nitro-sandbox-genpolicy binary}"
[[ -f "${GENPOLICY_BIN}" ]] || {
  echo "ERROR: ${GENPOLICY_BIN} is not a file" >&2
  exit 1
}

repo_root="$(cd "$(dirname "$0")/../../../.." && pwd)"
bin_dir="$(dirname "${GENPOLICY_BIN}")"
bin="$(cd "${bin_dir}" && pwd)/${GENPOLICY_BIN##*/}"
uid="$(id -u)"
gid="$(id -g)"
workdir="${repo_root}"
[[ "${PWD}/" == "${repo_root}/"* ]] && workdir="${PWD}"

mkdir -p "${HOME}/.docker"

# amazonlinux:2023, the multi-architecture index, pinned by digest: glibc, which the
# generator is linked against, and CA certificates, which it needs to reach the registry.
# HOME is a writable directory inside the container, for the generator's image cache.
# The platform must match GENPOLICY_BIN: linux/amd64 unless GENPOLICY_PLATFORM says otherwise.
exec "${CONTAINER_RUNTIME:-docker}" run --rm -i --platform "${GENPOLICY_PLATFORM:-linux/amd64}" \
  --user "${uid}:${gid}" -e HOME=/tmp/home --tmpfs /tmp/home:mode=1777 \
  -v "${repo_root}:${repo_root}" \
  -v "${HOME}/.docker:/tmp/home/.docker:ro" \
  -v "${bin}:/usr/local/bin/eks-nitro-sandbox-genpolicy:ro" \
  -w "${workdir}" \
  public.ecr.aws/amazonlinux/amazonlinux@sha256:5c38fd85b00ce8c094315d9b71f671f880052314a22bd25f1a027821bf61d9d7 \
  eks-nitro-sandbox-genpolicy "$@"
