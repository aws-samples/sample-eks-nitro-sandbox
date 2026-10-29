#!/usr/bin/env bash
# 10-kernel.sh: build the Nitro Sandbox HOST kernel from kernel.org linux-6.18.56 plus AWS's
# public kernel commit (amazonlinux/linux 1e66c960), install it, and make it the default GRUB
# boot entry. Stops short of the reboot so the GRUB state can be read first. Mirrors the GA
# node-build bundle's build-kernel-ubuntu.sh.
#
#   sudo scripts/10-kernel.sh                   # the build (on the build host)
#   scripts/10-kernel.sh --assert-config FILE   # only run the .config assertions on FILE
#   scripts/10-kernel.sh --check-initramfs CONFIG LISTING
#                                               # only run the root-filesystem-at-boot check
#                                               #   on a .config and an lsinitramfs listing
#
# Both inputs are public and pinned in packages/sources.lock: the kernel tarball
# (packages/fetch-kernel.sh) and the patch (packages/fetch-kernel-patch.sh), each verified
# against its SHA-256 before it is used. There is no RPM and no internal source tree here.
#
# Load-bearing behaviors, each with an assertion below:
#   * The patch applies in a throwaway git repository as exactly ONE commit whose subject is
#     the one sources.lock pins.
#   * .config starts from the RUNNING node's config, and the required symbols are asserted on
#     the RESULT of olddefconfig (assert_kernel_config), because olddefconfig silently drops a
#     symbol whose menu gate is off. CONFIG_NITRO_ENCLAVES must be =y, never =m: the
#     nitro_enclaves.mempool= boot argument does nothing when the driver is a module.
#   * BTF needs pahole (dwarves) and DWARF debug info: DWARF 4 is selected, and
#     INSTALL_MOD_STRIP=1 strips the DWARF from the installed modules while their BTF stays.
#   * The root filesystem driver must be available at boot (check_initramfs_root_fs): the build
#     sets EXT4_FS built in (y), which needs no module; if olddefconfig leaves it a module (m),
#     ext4.ko must be in the initramfs.
#   * GRUB_FORCE_PARTUUID must be emptied (Canonical's cloud image first boots WITHOUT an
#     initramfs, and this kernel is meant to boot from its own), and GRUB_DEFAULT is pinned by
#     entry id, because the stock 7.0 kernel sorts ahead of 6.18.56 and would otherwise boot.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

# assert_kernel_config <config-file>: every symbol the sandbox host needs, asserted on the
# file as it is (the result of olddefconfig), never on what was requested. Prints one ok/FAIL
# line per check and returns non-zero if any check fails.
assert_kernel_config() { # assert_kernel_config <config-file>
  local cfg="$1" bad=0 line want sym
  [ -s "$cfg" ] || { echo "FAIL: kernel config $cfg is missing or empty" >&2; return 1; }
  # Each entry: <symbol> <regex its value must match> <why>
  while IFS=';' read -r sym want why; do
    [ -n "$sym" ] || continue
    line=$(grep -E "^${sym}=" "$cfg" | tail -n 1 || true)
    if [[ "${line#*=}" =~ ^(${want})$ ]] && [ -n "$line" ]; then
      echo "ok: $line"
    else
      echo "FAIL: ${sym} is '${line:-<unset>}', must be ${want}: ${why}" >&2
      bad=1
    fi
  done <<'CHECKS'
CONFIG_NITRO_ENCLAVES;y;built in, never =m: nitro_enclaves.mempool= does nothing when the driver is a module
CONFIG_CMA;y;the enclave memory pool is carved from CMA
CONFIG_DEBUG_INFO_BTF;y;kernel BTF for eBPF (Cilium); needs DWARF debug info and pahole >= 1.16 from dwarves
CONFIG_DEBUG_INFO_BTF_MODULES;y;module BTF; needs pahole >= 1.19
CONFIG_VHOST_VSOCK;y|m;the guest agent talks to the host over vsock
CONFIG_EROFS_FS;y|m;the shim builds each container's EROFS filesystem
CONFIG_TUN;y|m;the shim makes one TAP device per VM
CONFIG_VIRT_DRIVERS;y;menu gate: without it olddefconfig drops NITRO_ENCLAVES
CONFIG_VSOCKETS;y|m;menu gate: without it olddefconfig drops VHOST_VSOCK
CONFIG_VHOST_MENU;y;menu gate: without it olddefconfig drops VHOST_VSOCK
CONFIG_EXT4_FS;y|m;the root filesystem
CONFIG_SQUASHFS;y|m;guest image tooling
CONFIG_BLK_DEV_LOOP;y|m;loop devices for the guest disks
CONFIG_OVERLAY_FS;y|m;overlay filesystems for container layers
CONFIG_BLK_DEV_NVME;y|m;the instance's own EBS (NVMe) root volume
CHECKS
  return "$bad"
}

# check_initramfs_root_fs <config-file> <initramfs-listing>: the root filesystem driver is
# available at boot. Reads CONFIG_EXT4_FS as olddefconfig left it (`scripts/config --enable`
# sets it to y): built in (y) needs no module; a module (m) must be in the initramfs (ext4.ko,
# compressed or not); anything else is refused.
check_initramfs_root_fs() {
  local cfg="$1" list="$2" v
  [ -s "$cfg" ] || { echo "FAIL: kernel config $cfg is missing or empty" >&2; return 1; }
  [ -f "$list" ] || { echo "FAIL: initramfs listing $list is missing" >&2; return 1; }
  v=$(grep -E '^CONFIG_EXT4_FS=' "$cfg" | tail -n 1 | cut -d= -f2)
  case "$v" in
    y) echo "ok: CONFIG_EXT4_FS=y (built in): the root filesystem needs no module in the initramfs" ;;
    m) if grep -qE '/ext4\.ko(\.(zst|xz|gz))?$' "$list"; then
         echo "ok: CONFIG_EXT4_FS=m and the initramfs carries $(grep -E '/ext4\.ko(\.(zst|xz|gz))?$' "$list" | head -n 1)"
       else
         echo "FAIL: CONFIG_EXT4_FS=m but the initramfs has no ext4.ko: the kernel cannot mount /" >&2; return 1
       fi ;;
    *) echo "FAIL: CONFIG_EXT4_FS is '${v:-<unset>}', must be y or m: the root filesystem" >&2; return 1 ;;
  esac
}

if [ "${1:-}" = --check-initramfs ]; then
  [ -n "${2:-}" ] && [ -n "${3:-}" ] || die "usage: 10-kernel.sh --check-initramfs <config-file> <initramfs-listing>"
  if check_initramfs_root_fs "$2" "$3"; then echo "INITRAMFS OK: $3"; exit 0; else echo "INITRAMFS REFUSED: $3" >&2; exit 1; fi
fi
if [ "${1:-}" = --assert-config ]; then
  [ -n "${2:-}" ] || die "usage: 10-kernel.sh --assert-config <config-file>"
  if assert_kernel_config "$2"; then
    echo "KERNEL CONFIG OK: $2"; exit 0
  else
    echo "KERNEL CONFIG REFUSED: $2" >&2; exit 1
  fi
fi
[ $# -eq 0 ] || die "unknown argument: $1 (supported: --assert-config <config-file>, --check-initramfs <config-file> <initramfs-listing>)"

: "${KERNEL_EXTRA_CMDLINE:=}"
KREL="${KERNEL_VERSION}${KERNEL_LOCALVERSION}"
GRUBD=/etc/default/grub.d/99-nitro-sandbox.cfg
CFG=/boot/grub/grub.cfg
NE_ARGS="nitro_enclaves.mempool=95%-1G nitro_enclaves.ne_cpus=dynamic"
G=(git -c user.email=kbuild@localhost -c user.name=kbuild)

ref="$(lock_field linux-kernel-source ref)" || die "packages/sources.lock has no ref= for linux-kernel-source"
[ "$ref" = "$KERNEL_VERSION" ] || die "KERNEL_VERSION=$KERNEL_VERSION but packages/sources.lock pins linux-kernel-source $ref; change both together"
subject="$(lock_field host-kernel-patch subject)" || die "packages/sources.lock has no subject= for host-kernel-patch"

# --- 0. Secure Boot gate (also checked by 00-preflight.sh; re-checked here, it is load-bearing) ---
sbvar=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
if [ -e "$sbvar" ]; then
  sbv=$(od -An -tu1 -j4 -N1 "$sbvar" | tr -d ' ')
  [ "$sbv" = 0 ] || die "Secure Boot is ON (efivar=$sbv); refusing to install an unsigned kernel"
fi

# --- 1. Build packages. gawk: Ubuntu ships mawk, and a 6.18 build then fails at the final link.
#        dwarves gives pahole for BTF. libdw-dev gives dwarf.h for gendwarfksyms (Canonical's
#        config sets CONFIG_GENDWARFKSYMS=y). --------------------------------------------------
sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y \
  build-essential flex bison bc gawk libelf-dev libdw-dev libssl-dev dwarves git curl xz-utils
for b in gcc make flex bison bc gawk pahole git; do have "$b" || die "build tool missing after apt install: $b"; done
log "pahole $(pahole --version 2>/dev/null || echo unknown)"

# --- 2. Fetch + verify both public inputs against packages/sources.lock --------------------
KSRC_TARBALL="$(bash "$HERE/../packages/fetch-kernel.sh" "$RUNTIME_ARTIFACTS_DIR" | tail -n 1)"
PATCH="$(bash "$HERE/../packages/fetch-kernel-patch.sh" "$RUNTIME_ARTIFACTS_DIR" | tail -n 1)"

# --- 3. Clean tree, then apply the commit in a throwaway git repository ---------------------
SRC="$HOME/linux-${KERNEL_VERSION}"
rm -rf "$SRC"; mkdir -p "$SRC"
tar -C "$SRC" --strip-components=1 -xJf "$KSRC_TARBALL"
cd "$SRC"
"${G[@]}" init -q
"${G[@]}" add -A
"${G[@]}" commit -qm "linux ${KERNEL_VERSION} (kernel.org)"
"${G[@]}" am -q "$PATCH" || die "the host-kernel patch did not apply to linux-${KERNEL_VERSION}"
[ "$("${G[@]}" rev-list --count HEAD)" = 2 ] || die "the patch did not apply as exactly one commit"
applied="$("${G[@]}" log -1 --format=%s)"
[ "$applied" = "$subject" ] || die "the applied patch is '$applied', not '$subject'"
log "applied 1 commit: $applied"

# --- 4. .config: the running node's config + the Nitro Sandbox kernel symbols ---------------
cp "/boot/config-$(uname -r)" .config || die "no /boot/config-$(uname -r): this must run on the booted Canonical base"
./scripts/config --enable NITRO_ENCLAVES --enable CMA --module VHOST_VSOCK \
                 --module EROFS_FS --enable SQUASHFS --enable BLK_DEV_LOOP \
                 --enable OVERLAY_FS --enable EXT4_FS
# The menu gates, or olddefconfig silently drops NITRO_ENCLAVES and VHOST_VSOCK.
./scripts/config --enable VIRT_DRIVERS --enable VSOCKETS --enable VHOST_MENU
# A self-built kernel has none of the distro's signing keys.
./scripts/config --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS "" \
                 --disable MODULE_SIG_FORCE --set-str LOCALVERSION "$KERNEL_LOCALVERSION" \
                 --disable LOCALVERSION_AUTO
# BTF: DWARF 4 as the one debug-info choice (pahole >= 1.16), REDUCED/SPLIT off (either drops
# BTF silently), module BTF on.
./scripts/config --disable DEBUG_INFO_NONE --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
                 --enable DEBUG_INFO_DWARF4 --disable DEBUG_INFO_DWARF5 \
                 --disable DEBUG_INFO_REDUCED --disable DEBUG_INFO_SPLIT \
                 --enable DEBUG_INFO_BTF --enable DEBUG_INFO_BTF_MODULES
make olddefconfig
cp .config "$LOG_DIR/kernel-${KREL}.config"
assert_kernel_config .config || die "the kernel config after olddefconfig is missing a required symbol (FAIL lines above); pahole version: $(grep -x 'CONFIG_PAHOLE_VERSION=[0-9]*' .config || echo 'no CONFIG_PAHOLE_VERSION')"
log "every required kernel config symbol survived olddefconfig"

# --- 5. Build + install. LOCALVERSION= (set, even empty) stops kbuild appending '+' for a git
#        tree; pass it to every make (sudo drops the environment). -------------------------
make -j"$(nproc)" LOCALVERSION= 2>&1 | tee "$LOG_DIR/kernel-build.log" | tail -n 40
[ "$(make -s kernelrelease LOCALVERSION=)" = "$KREL" ] || die "kernelrelease $(make -s kernelrelease LOCALVERSION=) != $KREL"
sudo make INSTALL_MOD_STRIP=1 LOCALVERSION= modules_install
sudo make LOCALVERSION= install   # Ubuntu's installkernel runs initramfs-tools + update-grub
test -s "/boot/vmlinuz-$KREL"; test -s "/boot/initrd.img-$KREL"; test -s "/lib/modules/$KREL/modules.dep"
sudo install -m 0644 .config "/boot/config-$KREL"
sudo lsinitramfs "/boot/initrd.img-$KREL" > "$LOG_DIR/initrd-$KREL.list"
check_initramfs_root_fs .config "$LOG_DIR/initrd-$KREL.list" || die "the root filesystem driver is not available at boot (FAIL line above)"

# --- 6. GRUB: boot arguments, no initrd-less first boot, and this entry pinned by id ----------
sudo tee "$GRUBD" >/dev/null <<GRUBCFG
# Written by scripts/10-kernel.sh. GRUB_FORCE_PARTUUID='' disables Canonical's initrd-less first
# boot (this kernel is installed with, and boots from, its own initrd); every entry then boots
# root=UUID=.
GRUB_FORCE_PARTUUID=
GRUB_CMDLINE_LINUX="\$GRUB_CMDLINE_LINUX $NE_ARGS $KERNEL_EXTRA_CMDLINE"
GRUBCFG
sudo update-grub 2>&1 | tee "$LOG_DIR/update-grub-1.log"
SUB=$(sudo grep -oE "menuentry_id_option 'gnulinux-advanced-[^']+'" "$CFG" | head -1 | cut -d"'" -f2)
ENT=$(sudo grep -oE "menuentry_id_option 'gnulinux-${KREL}-advanced-[^']+'" "$CFG" | head -1 | cut -d"'" -f2)
[ -n "$SUB" ] && [ -n "$ENT" ] || die "could not find the new kernel's grub entry id"
echo "GRUB_DEFAULT=\"${SUB}>${ENT}\"" | sudo tee -a "$GRUBD" >/dev/null
sudo update-grub 2>&1 | tee "$LOG_DIR/update-grub-2.log"

# --- 7. Assert on the generated grub.cfg, not on intentions ---------------------------------
sudo grep -qF "set default=\"${SUB}>${ENT}\"" "$CFG" || die "grub.cfg 'set default' is not our entry"
E="$LOG_DIR/grub-entry.txt"
sudo sed -n "/menuentry_id_option 'gnulinux-${KREL}-advanced-/,/^\t}/p" "$CFG" | tee "$E" >/dev/null
grep -q "vmlinuz-${KREL}"    "$E" || die "our entry does not load /boot/vmlinuz-$KREL"
grep -q "initrd.img-${KREL}" "$E" || die "our entry has no initrd line"
grep -q 'root=UUID='         "$E" || die "our entry does not use root=UUID= (GRUB_FORCE_PARTUUID still set?)"
grep -q 'nitro_enclaves.mempool=95%-1G' "$E" || die "our entry lacks the Nitro Enclaves boot arguments"

# --- 8. Modules Ubuntu builds =m that the sandbox path needs at boot --------------------------
printf 'tun\nloop\nsquashfs\noverlay\n' | sudo tee /etc/modules-load.d/nitro-sandbox.conf >/dev/null

kernel_sha="$(sha256sum "/boot/vmlinuz-$KREL" | awk '{print $1}')"
echo "host kernel $KREL from kernel.org linux-${KERNEL_VERSION}.tar.xz sha256=$(lock_field linux-kernel-source sha256) + 1 commit $(lock_field host-kernel-patch ref) patch sha256=$(lock_field host-kernel-patch sha256); grub-default=\"${SUB}>${ENT}\"; vmlinuz sha256=$kernel_sha; $(date -u +%FT%TZ)" \
  | sudo tee -a "$IMAGE_MANIFEST"
echo "10-kernel.sh done. Reboot now:  sudo systemctl reboot"
echo "Then run: bash scripts/00-preflight.sh --after-reboot   (uname -r should report $KREL)"
