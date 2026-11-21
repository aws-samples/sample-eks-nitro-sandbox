#!/usr/bin/env bash
# 60-verify-root.sh (stage verify-root, on the builder): before Packer registers the AMI,
# check the written OS volume. The GPT is valid and every partition is inside the volume;
# ROOT-A mounts read-only; each file that sources.lock installs (shim, Firecracker, jailer,
# both guest image files) has its pinned SHA-256 there; the shim config carries the slot count;
# the containerd drop-in carries the handler and discard_unpacked_layers = false; erofs-utils
# (/usr/bin/mkfs.erofs) and libzstd are there, and mkfs.erofs lists the zstd compressor.
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

# ROOT-A by its GPT name, read from the disk (sgdisk) and from the partition itself (blkid -p).
# lsblk takes PARTLABEL from the udev database, which can lag behind the re-read above.
n=$(sgdisk -p "$dev" | awk '/^ +[0-9]+ / && $NF=="BOTTLEROCKET-ROOT-A"{print $1}')
[ "$(printf '%s\n' "$n" | grep -c .)" = 1 ] || die "E_ROOT_A: not exactly one BOTTLEROCKET-ROOT-A partition on $dev"
case "$dev" in *[0-9]) part="${dev}p$n" ;; *) part="$dev$n" ;; esac
if [ "$(blkid -p -o value -s PART_ENTRY_NAME "$part" 2>/dev/null)" != BOTTLEROCKET-ROOT-A ]; then
  lsblk -nrpo NAME,PARTLABEL "$dev" >&2 || true   # what the kernel and udev show, for the log
  die "E_ROOT_A: $part is not the BOTTLEROCKET-ROOT-A partition of $dev"
fi
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
# erofs-utils: the shim builds each container's EROFS with mkfs.erofs and zstd, with no fallback.
mk="$mnt/usr/bin/mkfs.erofs"
{ [ -f "$mk" ] && [ ! -L "$mk" ] && [ -x "$mk" ]; } \
  || die "E_ROOT_EROFS: ROOT-A has no executable regular file /usr/bin/mkfs.erofs (erofs-utils)"
[ -n "$(find "$mnt/usr/lib" -maxdepth 1 -type f -name 'libzstd.so.*' -print -quit)" ] \
  || die "E_ROOT_EROFS: ROOT-A has no libzstd shared object in /usr/lib (libzstd)"
if [ "$(uname -m)" = x86_64 ]; then
  # The image's own mkfs.erofs and libraries, run from the read-only ROOT-A (x86_64 on x86_64).
  ver=$(timeout 60 chroot "$mnt" /usr/bin/mkfs.erofs -V 2>&1) \
    || die "E_ROOT_EROFS: mkfs.erofs -V did not run in ROOT-A: $(printf '%s\n' "$ver" | tail -n 1)"
  # erofs-utils 1.9.4 mkfs/main.c version(): "available compressors: " and the names joined by ", ".
  comp=$(printf '%s\n' "$ver" | sed -n 's/^available compressors: //p')
  log "root volume mkfs.erofs: ${ver%%$'\n'*}; available compressors: ${comp:-none}"
  case ", $comp, " in
    *", zstd, "*) ;;
    *) die "E_ROOT_EROFS: mkfs.erofs in ROOT-A has no zstd compressor (available compressors: ${comp:-none})" ;;
  esac
else
  log "root volume mkfs.erofs: -V not run (the builder is $(uname -m), not x86_64)"
fi
log "root volume $CB_OS_VOLUME_ID: ROOT-A verified, pcie_slots=$CB_SANDBOX_SLOTS"
umount "$mnt"
trap - EXIT
log "verify-root ok"
