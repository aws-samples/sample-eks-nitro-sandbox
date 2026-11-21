#!/usr/bin/env bash
# 60-verify-root.sh (stage verify-root, on the builder): before Packer registers the AMI,
# check the written OS volume. The GPT is valid and every partition is inside the volume;
# ROOT-A mounts read-only; each file that sources.lock installs (shim, Firecracker, jailer,
# both guest image files) has its pinned SHA-256 there; the shim config carries the slot count;
# the containerd drop-in carries the handler and discard_unpacked_layers = false.
# Inputs: CB_OS_VOLUME_ID, CB_SANDBOX_SLOTS.
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
need_volume_id CB_OS_VOLUME_ID
[[ "${CB_SANDBOX_SLOTS:-}" =~ ^[1-9][0-9]{0,2}$ ]] || die "E_INPUT_SANDBOX_SLOTS: CB_SANDBOX_SLOTS is not an integer"
dev=$(volume_device "$CB_OS_VOLUME_ID")
not_in_use "$dev"

blockdev --rereadpt "$dev" || die "E_GPT: could not read the partition table of $dev"
udevadm settle
modprobe erofs 2>/dev/null || true
sgdisk -v "$dev" | grep -q '^No problems found' || die "E_GPT: sgdisk -v reports a problem on $dev"
sectors=$(( $(blockdev --getsize64 "$dev") / 512 ))
while read -r start end name; do
  [ "$end" -lt "$sectors" ] && [ "$start" -le "$end" ] || die "E_BOUNDS: partition $name ($start-$end) is outside the volume"
done < <(sgdisk -p "$dev" | awk '/^ +[0-9]+ /{print $2, $3, $NF}')

part=$(lsblk -nrpo NAME,PARTLABEL "$dev" | awk '$2=="BOTTLEROCKET-ROOT-A"{print $1}')
[ "$(printf '%s\n' "$part" | grep -c .)" = 1 ] || die "E_ROOT_A: not exactly one BOTTLEROCKET-ROOT-A partition on $dev"
mnt=$SYSROOT/mnt/cilium-bottlerocket-root
install -d -m 0700 "$mnt"
mount -t erofs -o ro "$part" "$mnt" || die "E_ROOT_A: could not mount $part read-only as erofs"
trap 'umount "$mnt" 2>/dev/null || true' EXIT

python3 -I "$OVERLAY/packages/lib/runtime_verify.py" installed "$LOCK" "$mnt" \
  || die "E_ROOT_FILES: a file on the root volume does not match sources.lock"
[ "$(readlink "$mnt/usr/share/nitro-sandbox/rootfs.ext4")" = latest-disk.img ] || die "E_ROOT_FILES: rootfs.ext4 is not a link to latest-disk.img"
toml="$mnt/usr/share/factory/etc/containerd/nitro-sandbox.toml"
grep -Eq "^pcie_slots += $CB_SANDBOX_SLOTS\$" "$toml" || die "E_ROOT_SLOTS: nitro-sandbox.toml does not set pcie_slots = $CB_SANDBOX_SLOTS"
dropin="$mnt/usr/share/factory/etc/containerd/config.d/50-nitro-sandbox.toml"
if ! grep -q '^\[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.isolated-sandbox\]$' "$dropin" \
   || ! grep -q '^discard_unpacked_layers = false$' "$dropin"; then
  die "E_ROOT_FILES: the containerd drop-in is not the package one"
fi
log "root volume $CB_OS_VOLUME_ID: ROOT-A verified, pcie_slots=$CB_SANDBOX_SLOTS"
umount "$mnt"
trap - EXIT
log "verify-root ok"
