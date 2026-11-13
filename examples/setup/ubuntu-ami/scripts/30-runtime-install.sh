#!/usr/bin/env bash
# 30-runtime-install.sh: check containerd, then download and verify the Nitro Sandbox runtime
# release, the guest image pair and Firecracker from their public locations, install what the
# Amazon EKS User Guide ("Create and update a Nitro Sandbox AMI") puts on a node, write the shim
# config, and install (not start) cri-proxy.service.
#
#   sudo scripts/30-runtime-install.sh            # the install (on the build host, after the
#                                                 #   host kernel from 10-kernel.sh is booted)
#   scripts/30-runtime-install.sh --check-containerd
#                                                 # only check this host's containerd version
#   SHIM_DEBUG=true scripts/30-runtime-install.sh # debug-mode enclaves; troubleshooting only
#
# containerd is a GATE, not an install: this sample is validated on containerd 2.1.x, 2.2.x and
# 2.3.x (the User Guide asks for 2.0 or later). 2.4 and later are untested and refused, and so is
# anything older than 2.1, before anything is installed. Canonical republishes its EKS AMI under
# new serials, and a new serial can ship a newer containerd, so the check reads the booted host
# every time; the sample never upgrades or downgrades the base AMI's containerd.
#
# Install layout (packages/sources.lock install= lines), the files the User Guide puts on a node:
#   /usr/sbin/containerd-shim-nitro-sandbox-v2      0755  (also the CRI proxy), from the signed
#                                                         runtime release
#   /usr/bin/firecracker, /usr/bin/jailer           0755  from the Firecracker release
#   /var/lib/nitro-sandbox-images/latest.eif, latest-disk.img 0644, rootfs.ext4 -> latest-disk.img
#                                                         the guest image pair
# Nothing else from the runtime release is installed: the guest agent runs inside the guest image,
# and eks-nitro-sandbox-genpolicy runs on a workstation or in a build pipeline, not on the node.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

# containerd_verdict: read `containerd --version` on stdin and print one line saying the
# version and whether it is in the range this sample is validated on. Returns 0 only for 2.1.x,
# 2.2.x or 2.3.x. The version is the third field of the first line, which must start with
# `containerd`: upstream builds print `v2.1.5`, distro builds print `2.2.1` or `2.3.7+unknown`.
# Exactly three numeric parts, no leading zeros, an optional `+build` suffix and no pre-release
# suffix; anything else is refused as unreadable.
containerd_verdict() {
  local line prog _repo ver major minor patch
  IFS= read -r line || true
  read -r prog _repo ver _ <<<"$line" || true
  if [ "${prog:-}" != containerd ] || \
     ! [[ ${ver:-} =~ ^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\+[0-9A-Za-z.-]+)?$ ]]; then
    echo "containerd version unreadable: '$line' (expected 'containerd <repo> <version> ...')"
    return 1
  fi
  major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
  if [ "$major" = 2 ] && { [ "$minor" = 1 ] || [ "$minor" = 2 ] || [ "$minor" = 3 ]; }; then
    echo "containerd $major.$minor.$patch ($ver): in the range this sample is validated on (2.1.x to 2.3.x)"
    return 0
  fi
  if [ "${#major}" -gt 3 ] || [ "$major" -gt 2 ] || \
     { [ "$major" = 2 ] && { [ "${#minor}" -gt 3 ] || [ "$minor" -ge 4 ]; }; }; then
    echo "containerd $major.$minor.$patch ($ver) is newer than this sample is validated on (2.1.x to 2.3.x): build from a base AMI serial whose containerd is 2.3.x or earlier"
    return 1
  fi
  echo "containerd $major.$minor.$patch ($ver) is older than this sample is validated on (2.1.x to 2.3.x)"
  return 1
}

# check_containerd: the verdict for the containerd on this host's PATH. A binary whose
# `--version` fails is refused even when it prints a version line.
check_containerd() {
  local bin out rc=0
  bin=$(command -v containerd) || { echo "containerd not found on the PATH"; return 1; }
  out=$("$bin" --version 2>&1) || rc=$?
  if [ "$rc" != 0 ]; then
    echo "'$bin --version' failed (exit $rc): $(printf '%s\n' "$out" | head -n 1)"
    return 1
  fi
  printf '%s\n' "$out" | containerd_verdict
}

if [ "${1:-}" = --check-containerd ]; then
  verdict=$(check_containerd) && rc=0 || rc=$?
  printf '%s\n' "$verdict"
  exit "$rc"
fi
[ $# -eq 0 ] || die "unknown argument: $1 (supported: --check-containerd)"

case $SHIM_DEBUG in true|false) ;; *) die "SHIM_DEBUG must be true or false, got '$SHIM_DEBUG'" ;; esac
CRI_SOCK=/run/nitro-sandbox/cri-proxy.sock
SHIM=/usr/sbin/containerd-shim-nitro-sandbox-v2
KUBECONFIG_PATH=/var/lib/kubelet/kubeconfig
SIGNED_DIR=/usr/local/share/ubuntu-ami-sample/runtime
case "$NITRO_SANDBOX_DATA_DIR/" in "$NITRO_SANDBOX_IMAGE_DIR/"*) die "NITRO_SANDBOX_DATA_DIR is inside NITRO_SANDBOX_IMAGE_DIR; the shim needs them apart" ;; esac

# --- 0. Gates, before anything is installed ---------------------------------------------------
verdict=$(check_containerd) || die "$verdict"
echo "$verdict"
[ -c /dev/nitro_enclaves ] || die "/dev/nitro_enclaves missing: boot the host kernel from 10-kernel.sh (uname -r should be ${KERNEL_VERSION}${KERNEL_LOCALVERSION}) on an instance with Nitro Enclaves enabled"
command -v losetup >/dev/null 2>&1 || die "losetup (util-linux) missing"
command -v mkfs.erofs >/dev/null 2>&1 || die "mkfs.erofs missing: run 20-erofs-utils.sh first"
d=$(mktemp -d); echo x > "$d/f"
mkfs.erofs -zzstd,1 "$d/t.img" "$d" >/dev/null 2>&1 || { rm -rf "$d"; die "mkfs.erofs has no zstd support: run 20-erofs-utils.sh (erofs-utils ${EROFS_UTILS_VERSION} --with-libzstd)"; }
rm -rf "$d"

# --- 1. Download and verify every runtime input here, on the build host -----------------------
# The signed manifest and its signature, the archive, the guest pair with their sidecars, the
# Firecracker release with its sidecar, and each member read out of an archive, all against
# packages/sources.lock (packages/fetch-runtime-artifacts.sh).
NODE_FILES="$(bash "$HERE/../packages/fetch-runtime-artifacts.sh" "$RUNTIME_ARTIFACTS_DIR" | tail -n 1)"
[ -d "$NODE_FILES" ] || die "fetch-runtime-artifacts.sh did not report its node-files folder"

# --- 2. Install every file at its sources.lock path and mode ------------------------------------
sudo install -d -m 0755 "$NITRO_SANDBOX_IMAGE_DIR"
installed=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  spec="$(lock_field "$id" install)" || continue
  [ "$spec" != none ] || continue
  read -r dest mode <<<"$spec"
  case "$dest" in /*) ;; *) die "sources.lock block $id install path is not absolute: $dest" ;; esac
  [[ "$mode" =~ ^0[0-7]{3}$ ]] || die "sources.lock block $id install mode is not octal: $mode"
  [ -f "$NODE_FILES/$id" ] || die "no verified file for sources.lock block $id in $NODE_FILES"
  sudo install -D -m "$mode" "$NODE_FILES/$id" "$dest"
  got="$(sha256sum "$dest" | awk '{print $1}')"
  want="$(lock_field "$id" sha256)"
  [ "$got" = "$want" ] || die "installed $dest has SHA-256 $got, not $want"
  echo "installed $dest mode $mode sha256=$got ($id $(lock_field "$id" ref))" | sudo tee -a "$IMAGE_MANIFEST"
  installed=$((installed + 1))
done < <(awk -F= '/^id=/{print substr($0, 4)}' "$LOCK_FILE")
[ "$installed" -gt 0 ] || die "sources.lock names no file to install on the node"
# The signed manifest and its signature stay on the image, so verify-image.py can verify the
# signature and the shim's line again on a fresh instance, after the downloads are gone.
for id in $(lock_ids_where kind signed-archive); do
  sudo install -D -m 0644 "$RUNTIME_ARTIFACTS_DIR/signed-manifest/$id.SHA256SUM" "$SIGNED_DIR/$id.SHA256SUM"
  sudo install -D -m 0644 "$RUNTIME_ARTIFACTS_DIR/signed-manifest/$id.SHA256SUM.sig" "$SIGNED_DIR/$id.SHA256SUM.sig"
done
"$SHIM" --version 2>&1 | head -n 1

# --- 3. Guest image: the shim attaches the disk as rootfs.ext4, beside the EIF -----------------
sudo ln -sfn latest-disk.img "$NITRO_SANDBOX_IMAGE_DIR/rootfs.ext4"
[ "$(readlink "$NITRO_SANDBOX_IMAGE_DIR/rootfs.ext4")" = latest-disk.img ] || die "rootfs.ext4 symlink wrong"

# --- 4. Shim config, as the User Guide gives it. debug = false unless SHIM_DEBUG=true ----------
sudo install -d -m 0755 /etc/containerd
sudo tee /etc/containerd/nitro-sandbox.toml >/dev/null <<TOML
# Nitro Sandbox shim config, written by scripts/30-runtime-install.sh.
# kernel_path is the guest image EIF; the disk image is beside it, and both are outside data_base_dir.
kernel_path     = "${NITRO_SANDBOX_IMAGE_DIR}/latest.eif"
kubeconfig_path = "${KUBECONFIG_PATH}"
format_overlay  = true
cpu_overcommit  = true         # host-schedule enclave vCPUs so a small node fits many sandboxes
pcie_slots      = 110          # concurrent sandbox slot target (kubelet max-pods default 110)
data_base_dir   = "${NITRO_SANDBOX_DATA_DIR}"
# debug = true makes DEBUG-MODE enclaves (attestation PCRs read zero). Keep OFF in production.
debug           = ${SHIM_DEBUG}
TOML
sudo chmod 0644 /etc/containerd/nitro-sandbox.toml

# --- 5. cri-proxy.service: the shim binary IS the CRI proxy. Installed and enabled, not started:
#        it needs kubelet's kubeconfig, which exists only after the node joins. -----------------
sudo tee /etc/systemd/system/cri-proxy.service >/dev/null <<UNIT
[Unit]
Description=CRI Proxy for nitro-sandbox
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=${SHIM} cri-proxy --listen ${CRI_SOCK} --containerd /run/containerd/containerd.sock
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
sudo chmod 0644 /etc/systemd/system/cri-proxy.service
sudo systemctl daemon-reload
sudo systemctl enable cri-proxy.service

# --- 6. tun at boot (the shim makes one TAP per VM) ---------------------------------------------
printf 'tun\n' | sudo tee /etc/modules-load.d/nitro-sandbox-tun.conf >/dev/null
sudo modprobe tun
[ -c /dev/net/tun ] || die "/dev/net/tun missing after modprobe tun"

echo "runtime release $(lock_field runtime-release ref) ($(lock_field runtime-release arch)), guest image $(lock_field guest-image-eif ref), Firecracker $(lock_field firecracker-release ref) installed from their public sources; ${verdict}; shim config debug=${SHIM_DEBUG}; cri-proxy.service enabled, not started; $(date -u +%FT%TZ)" \
  | sudo tee -a "$IMAGE_MANIFEST"
