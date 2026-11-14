#!/usr/bin/env bash
# 00-preflight.sh: prove the build CAN proceed before spending build-host time on it.
#
# Runs on the build host, in this order:
#   1. The base image: Canonical's EKS AMI (bootstrap.sh, the containerd template, the
#      kubelet-eks snap), Secure Boot off, disk space.
#   2. containerd, read from the BOOTED base: this sample is validated on 2.1.x, 2.2.x and 2.3.x
#      only (scripts/30-runtime-install.sh --check-containerd). Canonical republishes the base AMI
#      under new serials, and a new serial can ship a newer containerd, so this is checked on
#      every build, before the kernel compile, and fails closed outside that range.
#   3. Enclave hardware, enforced only after the reboot onto the host kernel (--after-reboot).
#   4. The public runtime inputs: packages/fetch-runtime-artifacts.sh --check verifies the runtime
#      release's signed manifest and the guest image and Firecracker sidecars against
#      packages/sources.lock, so a moved pin stops the build before the kernel compile.
#
# The build toolchain is not checked here: 10-kernel.sh and 20-erofs-utils.sh install their
# own packages from Ubuntu's signed apt repositories and assert the tools they need.
#
# Run it twice: `00-preflight.sh` before 10-kernel.sh, and `00-preflight.sh --after-reboot` once
# the host has rebooted onto the kernel 10-kernel.sh built. Only the second run enforces the
# enclave-hardware checks: the base image's own kernel can already have a Nitro Enclaves driver
# (Canonical's builds it as a module and /dev/nitro_enclaves exists), but not the attributes the
# driver from AWS's kernel commit adds, so on that kernel the first run reports them and fails on
# none of them.
#
#   SYSROOT (scripts/lib/common.sh) prefixes the enclave device and sysfs paths, for the
#   clusterless tests only.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
rc=0
fail() { printf 'FAIL: %s\n' "$*" >&2; rc=1; }
AFTER_REBOOT=0
for a in "$@"; do
  case "$a" in
    --after-reboot) AFTER_REBOOT=1 ;;
    *) die "unknown argument: $a (supported: --after-reboot)" ;;
  esac
done

. /etc/os-release 2>/dev/null || true
log "preflight on $(uname -r), ${PRETTY_NAME:-unknown-os}"

# --- 1. This must be Canonical's EKS AMI, not plain Ubuntu --------------------------------
[ -x /etc/eks/bootstrap.sh ] || fail "/etc/eks/bootstrap.sh missing: not the EKS-optimized Ubuntu AMI"
[ -f /usr/local/share/eks/containerd-config.toml ] || fail "/usr/local/share/eks/containerd-config.toml missing: nothing for the runtime-handler stage to patch"
grep -q '^version = 2$' /usr/local/share/eks/containerd-config.toml 2>/dev/null \
  || fail "containerd template is not 'version = 2'"
snap list kubelet-eks >/dev/null 2>&1 || fail "kubelet-eks snap missing"

# --- 2. Instance identity (informational; recorded in the run evidence by setup.sh) -------
# The IMDSv2 session token is a credential: it reaches curl as a config read from standard input
# (`-K -`, written by the printf builtin), never as an argument any other process could read.
TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)
imds() {
  [ -n "$TOKEN" ] || return 0
  printf 'header = "X-aws-ec2-metadata-token: %s"\n' "$TOKEN" | curl -sf -K - "http://169.254.169.254/latest/$1" || true
}
log "instance=$(imds meta-data/instance-id) type=$(imds meta-data/instance-type) ami=$(imds meta-data/ami-id) az=$(imds meta-data/placement/availability-zone)"

# --- 3. Secure Boot: this sample's kernel build is unsigned --------------------------------
SB=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
if [ -e "$SB" ]; then
  sbv=$(od -An -tu1 -j4 -N1 "$SB" | tr -d ' ')
  [ "$sbv" = 0 ] && echo "ok: UEFI Secure Boot disabled" || fail "Secure Boot is ON (efivar=$sbv): an unsigned kernel will not boot"
else
  warn "no SecureBoot efivar: not UEFI? the Canonical AMI is expected to boot UEFI"
fi

# --- 4. containerd on the booted base: 2.1.x to 2.3.x, or stop before anything is built ----
if verdict=$(bash "$HERE/30-runtime-install.sh" --check-containerd); then
  echo "ok: $verdict"
else
  fail "$verdict"
fi
echo "CONTAINERD_VERDICT=$verdict"

# --- 5. Disk ---------------------------------------------------------------------------------
avail=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
log "root filesystem free: ${avail:-?} GiB"
[ "${avail:-0}" -ge 40 ] || fail "less than 40 GiB free on /"
bavail=$(df -BM --output=avail /boot 2>/dev/null | tail -1 | tr -dc '0-9')
log "/boot free: ${bavail:-?} MiB"
[ "${bavail:-0}" -ge 200 ] || fail "less than 200 MiB free on /boot"

# --- 6. Enclave hardware: enforced only by the --after-reboot run ----------------------------
# Before the reboot the host runs the base image's own kernel. Canonical's (7.0.0-1014-aws on
# serial 20261027) has CONFIG_NITRO_ENCLAVES=m: the module is loaded and /dev/nitro_enclaves
# exists on an instance with enclaves on, but pcie_slots_total and the "BAR4 notify mapped" line
# come only from the driver in the Amazon Linux sandbox patch (amazonlinux/linux 4ae89f6e). So
# the first run reports what it sees and fails on none of it; the --after-reboot run requires the
# host kernel 10-kernel.sh built, the device, pcie_slots_total and the BAR4 line.
KREL="${KERNEL_VERSION}${KERNEL_LOCALVERSION}"
NE_DEV="$SYSROOT/dev/nitro_enclaves"
NE_SLOTS="$SYSROOT/sys/class/misc/nitro_enclaves/pcie_slots_total"
running_kernel=$(uname -r)
slots=$(cat "$NE_SLOTS" 2>/dev/null || echo "")
if [ -c "$NE_DEV" ]; then ne_dev=present; else ne_dev=absent; fi
log "enclave hardware on kernel $running_kernel: /dev/nitro_enclaves $ne_dev, pcie_slots_total=${slots:-<absent>}"
if [ "$AFTER_REBOOT" = 1 ]; then
  if [ "$running_kernel" = "$KREL" ]; then echo "ok: running the host kernel $KREL"
  else fail "running kernel $running_kernel, not $KREL: the enclave checks need the host kernel 10-kernel.sh built"; fi
  if [ "$ne_dev" = present ]; then echo "ok: /dev/nitro_enclaves present"
  else fail "/dev/nitro_enclaves absent: Nitro Enclaves is off on this instance, or the driver did not load"; fi
  if [ -n "$slots" ]; then echo "ok: pcie_slots_total=$slots"
  else fail "no pcie_slots_total: this is NOT sandbox-capable hardware/placement"; fi
  # The driver logs "BAR4 notify mapped at ..." when the doorbell BAR is mapped, and
  # "No notify BAR4, virtqueue kicks unavailable" when it is not; only the first passes.
  if [ "$(sudo dmesg 2>/dev/null | grep -cE 'BAR4 notify mapped')" -ge 1 ]; then
    echo "ok: dmesg reports BAR4 notify mapped"
  else
    fail "dmesg has no 'BAR4 notify mapped' line"
  fi
else
  log "enclave checks not enforced on this run: 00-preflight.sh --after-reboot enforces them on $KREL, after 10-kernel.sh and the reboot"
fi

# --- 7. The public runtime inputs, checked before the kernel build --------------------------
# The small published files only (the signed manifest and its signature, the guest image and
# Firecracker sidecars), against packages/sources.lock; 30-runtime-install.sh downloads and
# verifies the files themselves.
if bash "$HERE/../packages/fetch-runtime-artifacts.sh" --check; then
  echo "ok: the runtime release's signed manifest and the guest image and Firecracker sidecars match packages/sources.lock"
else
  fail "the published runtime inputs did not verify against packages/sources.lock (see the FATAL line above)"
fi

[ "$rc" = 0 ] && log "PREFLIGHT OK" || log "PREFLIGHT FAILED: fix the FAIL lines above before building"
exit "$rc"
