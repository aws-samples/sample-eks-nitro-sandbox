#!/usr/bin/env bash
# 50-bake-prep.sh: idempotent sanitization run over SSM before an AMI is created from the
# build host. Removes build tools, source trees, downloaded archives, SSH host keys and
# machine identity; keeps runtime artifacts, verification scripts and the on-image manifest.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
export DEBIAN_FRONTEND=noninteractive

sudo systemctl stop snap.kubelet-eks.daemon.service cri-proxy.service 2>/dev/null || true

sudo apt-mark manual containerd runc 2>/dev/null || true
sudo apt-get -o DPkg::Lock::Timeout=600 purge -y \
  build-essential gcc g++ make flex bison libelf-dev libdw-dev libssl-dev \
  autoconf automake libtool pkg-config 2>&1 | tail -5

sudo rm -rf "$HOME/build-kernel" "$HOME/build-erofs" "$HOME/host-kernel-patches" \
  "$HOME/runtime-artifacts" "$RUNTIME_ARTIFACTS_DIR" /tmp/smoke-* /tmp/erofs-*

printf 'APT::Periodic::Update-Package-Lists "0";\nAPT::Periodic::Unattended-Upgrade "0";\n' \
  | sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb

for path in "$HOME/build-kernel" "$HOME/build-erofs" "$HOME/host-kernel-patches" "$HOME/runtime-artifacts"; do
  [[ ! -e "$path" ]] || { echo "STILL PRESENT: $path; do not bake"; exit 1; }
done

printf 'localhost\n' | sudo tee /etc/hostname >/dev/null
rm -f "$HOME/.bash_history" "$HOME/.ssh/known_hosts"
sudo rm -f /root/.bash_history
sudo cloud-init clean --logs --machine-id 2>/dev/null || true
sudo rm -f /var/lib/dbus/machine-id
sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id
sudo rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
sudo journalctl --rotate 2>/dev/null || true
sudo journalctl --vacuum-time=1s 2>/dev/null || true
sudo rm -rf /var/log/journal/*/ /var/lib/cloud/instances/* "$LOG_DIR"
sudo rm -f "$HOME/.ssh/authorized_keys"

echo "BAKE-PREP: PASS (build artifacts and source archives removed; machine identity cleared)"
