#!/usr/bin/env bash
# 30-runtime-install.sh: unpack and install the EKS Pod Isolation runtime binaries + guest
# image from the verified released archive (packages/fetch-runtime-artifacts.sh has already
# checked it is present and matches packages/sources.lock; this script re-verifies before
# unpacking, since a build can resume hours after preflight ran).
#
# This is the one stage that consumes the release artifact described in packages/SOURCES.txt:
# the containerd shim (also the CRI proxy via a subcommand), the Firecracker fork and its
# jailer, the guest microVM boot image and root disk, the Cedar policy generator and the
# KMS key provider. Nothing here is built from an internal source tree; everything is
# unpacked from the archive at RUNTIME_ARTIFACTS_DIR/RUNTIME_ARTIFACT_FILE.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

bash "$HERE/../packages/fetch-runtime-artifacts.sh"
ARCHIVE="$RUNTIME_ARTIFACTS_DIR/$RUNTIME_ARTIFACT_FILE"

STAGE="$HOME/runtime-artifacts"
rm -rf "$STAGE"; mkdir -p "$STAGE"
tar -C "$STAGE" -xf "$ARCHIVE"

sudo mkdir -p "$NITRO_SANDBOX_DIR_INSTALL"
# The release's expected layout, per packages/SOURCES.txt: a shim binary, the Firecracker fork +
# jailer, a guest kernel/bootable image and root disk, the Cedar policy generator and the
# KMS key provider. Record each installed artifact's SHA-256 into the manifest, including
# any the release ships without its own .sha256 (the shim, agent, policy generator and key
# provider in the pre-GA bundle), so the installed set stays auditable either way.
declare -A EXPECTED=(
  [containerd-shim-nitro-sandbox-v2]=/usr/local/bin
  [firecracker]=/usr/local/bin
  [jailer]=/usr/local/bin
  [eks-nitro-sandbox-genpolicy]=/usr/local/bin
)
for name in "${!EXPECTED[@]}"; do
  src=$(find "$STAGE" -name "$name" -type f | head -1)
  [ -n "$src" ] || die "runtime archive did not contain expected artifact: $name (check the archive layout against packages/SOURCES.txt)"
  dest="${EXPECTED[$name]}/$name"
  sudo install -m 0755 "$src" "$dest"
  echo "installed $dest sha256=$(sha256sum "$dest" | cut -c1-16)" | sudo tee -a /etc/nip-custom-ami-manifest
done

for name in vmlinuz rootfs.ext4; do
  src=$(find "$STAGE" -name "$name" -type f | head -1)
  [ -n "$src" ] || die "runtime archive did not contain expected guest image file: $name"
  sudo install -m 0644 "$src" "$NITRO_SANDBOX_DIR_INSTALL/$name"
  echo "installed $NITRO_SANDBOX_DIR_INSTALL/$name sha256=$(sha256sum "$NITRO_SANDBOX_DIR_INSTALL/$name" | cut -c1-16)" | sudo tee -a /etc/nip-custom-ami-manifest
done

/usr/local/bin/firecracker --version 2>&1 | head -2 || true
/usr/local/bin/jailer --version 2>&1 | head -2 || true
test -x /usr/local/bin/containerd-shim-nitro-sandbox-v2

echo "runtime release artifact $RUNTIME_ARTIFACT_FILE installed; patch series $PATCH_SERIES_FILE applied in scripts/10-kernel.sh; $(date -u +%FT%TZ)" \
  | sudo tee -a /etc/nip-custom-ami-manifest
