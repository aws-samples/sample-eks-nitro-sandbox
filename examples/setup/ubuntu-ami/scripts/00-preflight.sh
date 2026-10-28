#!/usr/bin/env bash
# 00-preflight.sh: prove the build CAN proceed before spending build-host time on it.
#
# Runs on the build host, in this order:
#   1. The base image: Canonical's EKS AMI (bootstrap.sh, the containerd template, the
#      kubelet-eks snap), Secure Boot off, disk space.
#   2. containerd, read from the BOOTED base: the GA shim runs on 2.1.x, 2.2.x and 2.3.x only
#      (scripts/30-runtime-install.sh --check-containerd). Canonical republishes the base AMI
#      under new serials, and a new serial can ship a newer containerd, so this is checked on
#      every build, before the kernel compile, and fails closed outside that range.
#   3. Enclave hardware (meaningful only after the reboot onto the host kernel).
#   4. The one prerequisite this sample documents rather than works around: the operator-
#      supplied runtime archive. packages/fetch-runtime-artifacts.sh verifies it against
#      packages/sources.lock; when it is absent THIS SCRIPT STOPS (exit 3).
#
# The build toolchain is not checked here: 10-kernel.sh and 20-erofs-utils.sh install their
# own packages from Ubuntu's signed apt repositories and assert the tools they need.
#
# Run it twice: once before 10-kernel.sh, and again after the reboot, when the enclave-device
# checks become meaningful. Before the reboot the NE device is expected to be absent and this
# script says so rather than failing.
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

# --- 6. Enclave hardware (meaningful only after the host kernel is running) ----------------
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

# --- 7. THE documented prerequisite: the operator-supplied runtime archive -----------------
# The one check allowed to STOP the whole build (exit 3) rather than fail a line.
bash "$HERE/../packages/fetch-runtime-artifacts.sh"
fra_rc=$?
if [ "$fra_rc" = 3 ]; then
  log "PREFLIGHT STOPPED: the runtime archive prerequisite is not met (documented stop, not a build failure)."
  exit 3
elif [ "$fra_rc" != 0 ]; then
  fail "the runtime archive did not verify against packages/sources.lock (see the FATAL line above)"
else
  echo "ok: runtime archive verified against packages/sources.lock"
fi

[ "$rc" = 0 ] && log "PREFLIGHT OK" || log "PREFLIGHT FAILED: fix the FAIL lines above before building"
exit "$rc"
