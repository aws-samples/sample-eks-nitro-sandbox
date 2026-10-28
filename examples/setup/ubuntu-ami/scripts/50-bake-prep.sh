#!/usr/bin/env bash
# 50-bake-prep.sh: idempotent sanitization run over SSM before an AMI is created from the
# build host. Removes the build toolchain, the kernel tree, the downloaded kernel tarball and
# kernel patch, the runtime archive and its unpacked copy, the S3-staged downloads, SSH host
# keys and machine identity. Keeps the installed runtime, the guest image, the verification
# scripts (/usr/local/share/ubuntu-ami-sample), the AppArmor profile and the on-image manifest.
# Refuses to report PASS while anything it was meant to remove is still present.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
export DEBIAN_FRONTEND=noninteractive
: "${STAGE_DIR:=/var/lib/ubuntu-ami-sample/stage}"
# This deletes the build host's state; it must never run against a workstation checkout.
[ "$IN_CHECKOUT" = 0 ] || die "50-bake-prep.sh runs on the build host only (this copy is in a repository checkout)"

sudo systemctl stop snap.kubelet-eks.daemon.service cri-proxy.service 2>/dev/null || true

sudo apt-mark manual containerd runc 2>/dev/null || true
sudo apt-get -o DPkg::Lock::Timeout=600 purge -y \
  build-essential gcc g++ make flex bison libelf-dev libdw-dev libssl-dev \
  autoconf automake libtool pkg-config 2>&1 | tail -n 5

# Everything a build left behind that must not reach the AMI.
REMOVE=(
  "$HOME/linux-${KERNEL_VERSION}"        # kernel tree (10-kernel.sh)
  "$HOME/build-erofs"                    # erofs-utils tree (20-erofs-utils.sh)
  "$RUNTIME_ARTIFACTS_DIR"               # kernel tarball, kernel patch, erofs tarball, runtime zip + unpacked copy
  "$STAGE_DIR"                           # the S3-staged downloads (setup.sh)
)
for p in "${REMOVE[@]}"; do sudo rm -rf -- "$p"; done
sudo rm -rf /tmp/smoke-* /tmp/erofs-*

printf 'APT::Periodic::Update-Package-Lists "0";\nAPT::Periodic::Unattended-Upgrade "0";\n' \
  | sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb

# Machine identity and host keys: every instance from the AMI must generate its own.
printf 'localhost\n' | sudo tee /etc/hostname >/dev/null
rm -f "$HOME/.bash_history" "$HOME/.ssh/known_hosts" "$HOME/.ssh/authorized_keys"
sudo rm -f /root/.bash_history
sudo cloud-init clean --logs --machine-id 2>/dev/null || true
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id
sudo rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
sudo journalctl --rotate 2>/dev/null || true
sudo journalctl --vacuum-time=1s 2>/dev/null || true
sudo rm -rf /var/log/journal/*/ /var/lib/cloud/instances/* "$LOG_DIR"

# --- Refuse to bake if anything above survived ------------------------------------------------
left=0
for p in "${REMOVE[@]}"; do
  [ ! -e "$p" ] || { echo "STILL PRESENT: $p" >&2; left=1; }
done
leftovers=$(sudo find / -xdev \( -name "linux-${KERNEL_VERSION}.tar.xz*" -o -name "$(lock_field host-kernel-patch file)*" \
  -o -name "$(lock_field runtime-archive file)*" -o -name 'erofs-utils-*.tar.gz*' \) -print 2>/dev/null || true)
[ -z "$leftovers" ] || { printf 'STILL PRESENT: %s\n' $leftovers >&2; left=1; }
if compgen -G '/etc/ssh/ssh_host_*_key*' >/dev/null; then echo "STILL PRESENT: SSH host keys" >&2; left=1; fi
[ ! -s /etc/machine-id ] || { echo "STILL PRESENT: /etc/machine-id is not empty" >&2; left=1; }
[ "$left" = 0 ] || die "bake-prep did not remove everything above; do not bake this host"

echo "BAKE-PREP: PASS (kernel tree, tarball, patch, archives, staged downloads, toolchain, SSH host keys and machine-id removed)"
