#!/usr/bin/env bash
# 00-preflight.sh: prove the build CAN proceed before spending build-host time on it.
#
# Two kinds of check, run in this order:
#   1. Public inputs: base image, toolchain, disk space, enclave hardware (after reboot).
#      These never require anything beyond what docs/SOURCES.md lists.
#   2. The one prerequisite this sample documents rather than works around: the EKS Pod
#      Isolation runtime release artifacts. packages/fetch-runtime-artifacts.sh checks for
#      them at the paths config.env names and verifies them against packages/sources.lock.
#      When they are absent, THIS SCRIPT STOPS with that prerequisite and the public
#      download location, and does not continue to the stages that need them. It never
#      falls back to an internal source tree or a private URL.
#
# Run it twice: once before 10-kernel.sh (base image, Secure Boot, toolchain), and again
# after the reboot, when the enclave-device checks become meaningful. Before the reboot the
# NE device is expected to be absent and this script says so rather than failing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
rc=0
fail() { printf 'FAIL: %s\n' "$*" >&2; rc=1; }

. /etc/os-release 2>/dev/null || true
log "preflight on $(uname -r), ${PRETTY_NAME:-unknown-os}"

# --- 1. This must be Canonical's EKS AMI, not plain Ubuntu --------------------------------
[ -x /etc/eks/bootstrap.sh ] || fail "/etc/eks/bootstrap.sh missing: not the EKS-optimized Ubuntu AMI"
[ -f /usr/local/share/eks/containerd-config.toml ] || fail "/usr/local/share/eks/containerd-config.toml missing: nothing for the runtime-handler stage to patch"
grep -q '^version = 2$' /usr/local/share/eks/containerd-config.toml 2>/dev/null \
  || fail "containerd template is not 'version = 2'"
snap list kubelet-eks >/dev/null 2>&1 || fail "kubelet-eks snap missing"

# --- 2. Instance identity (informational) --------------------------------------------------
TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)
imds() { [ -n "$TOKEN" ] && curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/$1" || true; }
log "instance=$(imds meta-data/instance-id) type=$(imds meta-data/instance-type) ami=$(imds meta-data/ami-id) az=$(imds meta-data/placement/availability-zone)"

# --- 3. Secure Boot: this sample's kernel build is unsigned --------------------------------
SB=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
if [ -e "$SB" ]; then
  sbv=$(od -An -tu1 -j4 -N1 "$SB" | tr -d ' ')
  [ "$sbv" = 0 ] && echo "ok: UEFI Secure Boot disabled" || fail "Secure Boot is ON (efivar=$sbv): an unsigned kernel will not boot"
else
  warn "no SecureBoot efivar: not UEFI? the Canonical AMI is expected to boot UEFI"
fi

# --- 4. Build toolchain (public apt packages only; see packages/sources.lock) --------------
for b in curl tar git make gcc flex bison bc perl file jq python3 xz zstd autoreconf libtoolize pkg-config update-initramfs update-grub depmod; do
  have "$b" || fail "missing build dependency: $b"
done
for p in libzstd-dev liblz4-dev uuid-dev libelf-dev libdw-dev libssl-dev dwarves; do
  dpkg -s "$p" >/dev/null 2>&1 || fail "missing -dev package: $p"
done

# --- 5. erofs zstd (informational before 20-erofs-utils.sh runs; FAIL after) ---------------
d=$(mktemp -d); : > "$d/f"
if have mkfs.erofs && mkfs.erofs -zzstd,1 "$d/t.img" "$d" >/dev/null 2>&1; then
  echo "ok: mkfs.erofs supports zstd ($(command -v mkfs.erofs))"
elif [ -x /usr/local/bin/mkfs.erofs ]; then
  fail "/usr/local/bin/mkfs.erofs exists but -zzstd,1 fails: the 20-erofs-utils.sh build is broken"
else
  warn "stock erofs-utils has no zstd; 20-erofs-utils.sh builds ${EROFS_UTILS_VERSION} from source and 31-install-shim.sh gates on it"
fi
rm -rf "$d"

# --- 6. Disk ---------------------------------------------------------------------------------
avail=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
log "root filesystem free: ${avail:-?} GiB"
[ "${avail:-0}" -ge 40 ] || fail "less than 40 GiB free on /"
bavail=$(df -BM --output=avail /boot 2>/dev/null | tail -1 | tr -dc '0-9')
log "/boot free: ${bavail:-?} MiB"
[ "${bavail:-0}" -ge 200 ] || fail "less than 200 MiB free on /boot"

# --- 7. Enclave hardware (meaningful only after the host kernel is running) ----------------
if [ -c /dev/nitro_enclaves ]; then
  slots=$(cat /sys/class/misc/nitro_enclaves/pcie_slots_total 2>/dev/null || echo "")
  log "pcie_slots_total=${slots:-<absent>}"
  [ -n "$slots" ] || fail "no pcie_slots_total: this is NOT sandbox-capable hardware/placement"
  if [ "$(sudo dmesg 2>/dev/null | grep -ciE 'BAR4 notify|notify BAR4')" -ge 1 ]; then
    echo "ok: dmesg reports BAR4 notify mapped"
  else
    fail "dmesg has no 'BAR4 notify' line"
  fi
else
  log "/dev/nitro_enclaves absent: expected before the host kernel from 10-kernel.sh is running. Run 10-kernel.sh, reboot, then run this script again."
fi

# --- 8. THE documented prerequisite: EKS Pod Isolation release artifacts -------------------
# This is the one check in this sample allowed to STOP the whole build rather than just
# fail a line: everything above is a public input (base AMI, toolchain, kernel source,
# erofs-utils); this is the runtime that currently has no public release channel. See
# docs/SOURCES.md and packages/fetch-runtime-artifacts.sh's own prerequisite message.
if ! bash "$HERE/../packages/fetch-runtime-artifacts.sh"; then
  log "PREFLIGHT STOPPED: the EKS Pod Isolation runtime release artifacts prerequisite is not met."
  log "This is the documented stop condition, not a build failure. See the message above and docs/SOURCES.md."
  exit 3
fi

[ "$rc" = 0 ] && log "PREFLIGHT OK" || log "PREFLIGHT FAILED: fix the FAIL lines above before building"
exit "$rc"
