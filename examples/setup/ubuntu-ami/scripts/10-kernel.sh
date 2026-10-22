#!/usr/bin/env bash
# 10-kernel.sh: build the host kernel from the pinned public kernel.org 6.18.39 tree plus
# the released EKS Pod Isolation host-kernel patch series, and make it the default GRUB
# boot entry. Stops short of the reboot so the GRUB state can be read first.
#
# This is the customer build path described in packages/SOURCES.txt: the kernel SOURCE is
# public and pinned (packages/sources.lock); only the patch series is a released artifact,
# already verified present by 00-preflight.sh (packages/fetch-runtime-artifacts.sh) before
# this script runs. There is no RPM here and no internal source tree: the kernel is
# compiled on this host from a tree this script fetches and verifies itself.
#
# Three Ubuntu-specific behaviors are load-bearing, each with an assertion below:
#   * GRUB_FORCE_PARTUUID must be emptied. Canonical's cloud image boots WITHOUT an
#     initramfs on the first try; a kernel with CONFIG_EXT4_FS=m cannot mount / that way.
#   * GRUB_DEFAULT must be pinned by entry id, because a newer stock kernel would otherwise
#     sort ahead of this one and boot silently instead.
#   * The Nitro Enclaves boot arguments are added by hand (no grubby here).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
: "${KERNEL_EXTRA_CMDLINE:=}"
GRUBD=/etc/default/grub.d/99-nip-nitro-sandbox.cfg
CFG=/boot/grub/grub.cfg
NE_ARGS="nitro_enclaves.mempool=95%-1G nitro_enclaves.ne_cpus=dynamic"

# --- 0. Secure Boot gate (also checked by 00-preflight.sh; re-checked here, it is load-bearing) ---
sbv=$(od -An -tu1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | tr -d ' ')
[ "${sbv:-0}" = 0 ] || die "Secure Boot is ON (efivar=$sbv); refusing to install an unsigned kernel"

# --- 1. Fetch + verify the public kernel source against packages/sources.lock -------------
KSRC_TARBALL="$(bash "$HERE/../packages/fetch-kernel.sh" "$RUNTIME_ARTIFACTS_DIR")"
# --- 2. Confirm the host-kernel patch series is present and verified (00-preflight.sh gates
# the overall build on this; re-check here since this is the step that consumes it) --------
bash "$HERE/../packages/fetch-runtime-artifacts.sh"
PATCH_ARCHIVE="$RUNTIME_ARTIFACTS_DIR/$PATCH_SERIES_FILE"

# --- 3. Unpack kernel source, apply the patch series ---------------------------------------
BUILD_DIR="$HOME/build-kernel"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
tar -C "$BUILD_DIR" --strip-components=1 -xJf "$KSRC_TARBALL"
cd "$BUILD_DIR"

PATCH_DIR="$HOME/host-kernel-patches"
rm -rf "$PATCH_DIR"; mkdir -p "$PATCH_DIR"
tar -C "$PATCH_DIR" -xf "$PATCH_ARCHIVE"
patch_count=$(find "$PATCH_DIR" -name '*.patch' | wc -l)
[ "$patch_count" -gt 0 ] || die "no .patch files found in $PATCH_ARCHIVE"
for p in "$PATCH_DIR"/*.patch; do
  patch -p1 < "$p"
done
log "applied $patch_count patch(es) from the released host-kernel patch series"

# --- 4. Configure: start from the running Canonical config, add the sandbox symbols,
# then assert after olddefconfig rather than assuming a requested symbol survived --------
cp "/boot/config-$(uname -r)" .config 2>/dev/null || make olddefconfig
REQUIRED_SYMBOLS=(
  CONFIG_NITRO_ENCLAVES
  CONFIG_EXT4_FS
  CONFIG_EROFS_FS
  CONFIG_SQUASHFS
  CONFIG_BLK_DEV_LOOP
  CONFIG_OVERLAY_FS
  CONFIG_BLK_DEV_NVME
  CONFIG_VHOST_VSOCK
  CONFIG_DEBUG_INFO_BTF
  CONFIG_RD_ZSTD
)
for sym in "${REQUIRED_SYMBOLS[@]}"; do
  ./scripts/config --enable "$sym" 2>/dev/null || echo "$sym=y" >> .config
done
make olddefconfig
# Assert in the RESULT, because olddefconfig silently drops a symbol whose gating menu is
# off; checking what was requested, not what survived, is exactly the bug this guards.
for sym in "${REQUIRED_SYMBOLS[@]}"; do
  grep -qE "^${sym}=(y|m)$" .config || die "$sym did not survive olddefconfig; its gating menu may be off. Check .config and the dependent symbols it needs."
done
log "all required kernel config symbols survived olddefconfig"

# --- 5. Build and install ------------------------------------------------------------------
make -j"$(nproc)" 2>&1 | tee "$LOG_DIR/kernel-build.log" | tail -40
KREL=$(make -s kernelrelease)
sudo make modules_install
sudo make install   # installs vmlinuz/System.map/config and runs update-initramfs via the Debian kernel hooks
test -s "/boot/vmlinuz-$KREL"
test -s "/boot/initrd.img-$KREL"
sudo lsinitramfs "/boot/initrd.img-$KREL" > "$LOG_DIR/initrd-$KREL.list"
grep -qE '/ext4\.ko' "$LOG_DIR/initrd-$KREL.list" || die "initramfs lacks ext4.ko: cannot mount /"

# --- 6. GRUB defaults drop-in (sourced after 40-force-partuuid.cfg, so it wins) -------------
sudo tee "$GRUBD" >/dev/null <<GRUBCFG
# Written by scripts/10-kernel.sh. Sourced after 40-force-partuuid.cfg; each line below is
# load-bearing (see the comment at the top of this script).
GRUB_FORCE_PARTUUID=
GRUB_CMDLINE_LINUX="\$GRUB_CMDLINE_LINUX $NE_ARGS $KERNEL_EXTRA_CMDLINE"
GRUBCFG
sudo update-grub 2>&1 | tee "$LOG_DIR/update-grub-1.log"

SUB=$(sudo grep -oE "menuentry_id_option 'gnulinux-advanced-[^']+'" "$CFG" | head -1 | cut -d"'" -f2)
ENT=$(sudo grep -oE "menuentry_id_option 'gnulinux-${KREL}-advanced-[^']+'" "$CFG" | head -1 | cut -d"'" -f2)
test -n "$SUB"; test -n "$ENT"
echo "# Boot the built host kernel by id: a newer stock kernel can otherwise sort ahead of it." | sudo tee -a "$GRUBD"
echo "GRUB_DEFAULT=\"${SUB}>${ENT}\"" | sudo tee -a "$GRUBD"
sudo update-grub 2>&1 | tee "$LOG_DIR/update-grub-2.log"

# --- 7. Assert on the generated grub.cfg, not on intentions ---------------------------------
sudo grep -qF "set default=\"${SUB}>${ENT}\"" "$CFG" || die "grub.cfg 'set default' is not our entry"
E="$LOG_DIR/grub-entry.txt"
sudo sed -n "/menuentry_id_option 'gnulinux-${KREL}-advanced-/,/^\t}/p" "$CFG" | tee "$E" >/dev/null
grep -q "vmlinuz-${KREL}"    "$E" || die "our entry does not load /boot/vmlinuz-$KREL"
grep -q "initrd.img-${KREL}" "$E" || die "our entry has no initrd line"
grep -q 'root=UUID='         "$E" || die "our entry does not use root=UUID= (GRUB_FORCE_PARTUUID still set?)"
grep -q 'nitro_enclaves.mempool=95%-1G' "$E" || die "our entry lacks the Nitro Enclaves boot arguments"

printf 'loop\nsquashfs\noverlay\n' | sudo tee /etc/modules-load.d/nip-nitro-sandbox.conf >/dev/null

kernel_sha="$(sha256sum "/boot/vmlinuz-$KREL" | cut -c1-16)"
echo "host kernel $KREL built from kernel.org linux-${KERNEL_VERSION}.tar.xz + $patch_count released patch(es); grub-default=\"${SUB}>${ENT}\"; vmlinuz sha256(16)=$kernel_sha; $(date -u +%FT%TZ)" \
  | sudo tee -a /etc/nip-custom-ami-manifest
echo "10-kernel.sh done. Reboot now:  sudo systemctl reboot"
echo "Then run: bash scripts/00-preflight.sh"
