#!/usr/bin/env bash
# 50-bake-prep.sh: idempotent sanitization run over SSM before an AMI is created from the
# build host. Removes the build toolchain, the kernel tree, the downloaded kernel tarball and
# kernel patch, the runtime release, guest image and Firecracker downloads, the S3-staged
# scripts, SSH host keys and machine identity. Keeps the installed runtime, the guest image, the
# signed runtime manifest, the verification scripts (/usr/local/share/ubuntu-ami-sample), the
# AppArmor profile, the package holds and the
# on-image manifest. It does NOT change the base AMI's apt update policy (package-list refresh
# and unattended security upgrades stay as Canonical set them; 36-hold-packages.sh holds only
# what the image pins).
#
# Refuses to report PASS while anything it was meant to remove is still present, and when the
# residue scan itself cannot complete ("could not determine" is a failure, never a clean result).
# SYSROOT (scripts/lib/common.sh) prefixes every system path, for the clusterless tests only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
export DEBIAN_FRONTEND=noninteractive
: "${STAGE_DIR:=/var/lib/ubuntu-ami-sample/stage}"
# This deletes the build host's state; it must never run against a workstation checkout.
[ "$IN_CHECKOUT" = 0 ] || die "50-bake-prep.sh runs on the build host only (this copy is in a repository checkout)"
R="$SYSROOT"

sudo systemctl stop snap.kubelet-eks.daemon.service cri-proxy.service 2>/dev/null || true

sudo apt-get -o DPkg::Lock::Timeout=600 purge -y \
  build-essential gcc g++ make flex bison libelf-dev libdw-dev libssl-dev \
  autoconf automake libtool pkg-config 2>&1 | tail -n 5

# Everything a build left behind that must not reach the AMI.
REMOVE=(
  "$HOME/linux-${KERNEL_VERSION}"        # kernel tree (10-kernel.sh)
  "$HOME/build-erofs"                    # erofs-utils tree (20-erofs-utils.sh)
  "$RUNTIME_ARTIFACTS_DIR"               # kernel tarball, kernel patch, erofs tarball, the runtime, guest image and Firecracker downloads
  "$STAGE_DIR"                           # the S3-staged downloads (setup.sh)
)
for p in "${REMOVE[@]}"; do sudo rm -rf -- "$p"; done
sudo rm -rf "$R"/tmp/smoke-* "$R"/tmp/erofs-*

sudo apt-get clean
sudo rm -rf "$R"/var/lib/apt/lists/* "$R"/var/cache/apt/archives/*.deb

# Machine identity and host keys: every instance from the AMI must generate its own.
printf 'localhost\n' | sudo tee "$R/etc/hostname" >/dev/null
rm -f "$HOME/.bash_history" "$HOME/.ssh/known_hosts" "$HOME/.ssh/authorized_keys"
sudo rm -f "$R/root/.bash_history"
sudo cloud-init clean --logs --machine-id 2>/dev/null || true
sudo truncate -s 0 "$R/etc/machine-id"
sudo rm -f "$R/var/lib/dbus/machine-id"
sudo ln -sf /etc/machine-id "$R/var/lib/dbus/machine-id"
sudo rm -f "$R"/etc/ssh/ssh_host_*_key "$R"/etc/ssh/ssh_host_*_key.pub
sudo journalctl --rotate 2>/dev/null || true
sudo journalctl --vacuum-time=1s 2>/dev/null || true
sudo rm -rf "$R"/var/log/journal/*/ "$R"/var/lib/cloud/instances/* "$LOG_DIR"

# --- Refuse to bake if anything above survived ------------------------------------------------
left=0
for p in "${REMOVE[@]}"; do
  [ ! -e "$p" ] || { echo "STILL PRESENT: $p" >&2; left=1; }
done
# The whole-filesystem residue scan must COMPLETE: a find that fails (an unreadable directory,
# an I/O error) leaves the result unknown, which stops the bake. It looks for every downloaded
# file by name: the kernel tarball and patch, the erofs-utils snapshot, and the runtime release,
# guest image and Firecracker downloads (installed under other names, so a copy under the
# download name is residue).
scan_out=$(mktemp); scan_err=$(mktemp)
names=(-name "linux-${KERNEL_VERSION}.tar.xz*" -o -name "$(lock_field host-kernel-patch file)*" -o -name 'erofs-utils-*.tar.gz*')
for id in $(lock_ids_where kind signed-archive) $(lock_ids_where kind sidecar-file); do
  names+=(-o -name "$(lock_field "$id" file)*")
done
if sudo find "${R:-/}" -xdev \( "${names[@]}" \) -print >"$scan_out" 2>"$scan_err"; then
  leftovers=$(cat "$scan_out")
else
  msg=$(head -n 3 "$scan_err"); rm -f "$scan_out" "$scan_err"
  die "could not determine whether build residue remains: the residue scan failed ($msg); do not bake this host"
fi
rm -f "$scan_out" "$scan_err"
[ -z "$leftovers" ] || { printf 'STILL PRESENT: %s\n' $leftovers >&2; left=1; }
if compgen -G "$R/etc/ssh/ssh_host_*_key*" >/dev/null; then echo "STILL PRESENT: SSH host keys" >&2; left=1; fi
[ ! -s "$R/etc/machine-id" ] || { echo "STILL PRESENT: /etc/machine-id is not empty" >&2; left=1; }
[ "$left" = 0 ] || die "bake-prep did not remove everything above; do not bake this host"

echo "BAKE-PREP: PASS (kernel tree, tarball, patch, archives, staged downloads, toolchain, SSH host keys and machine-id removed; apt update policy unchanged)"
