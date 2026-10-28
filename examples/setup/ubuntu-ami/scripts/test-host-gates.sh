#!/usr/bin/env bash
# test-host-gates.sh: proves two build-host gates both ways, in the REAL scripts, with no
# build host, no cluster and no AWS:
#   scripts/30-runtime-install.sh --check-containerd   containerd 2.1.x to 2.3.x only (the GA
#        shim's range), read from `containerd --version` (a stub first on PATH prints the case)
#   scripts/10-kernel.sh --assert-config FILE          the required .config symbols, asserted on
#        the file as olddefconfig left it (fixture .config files)
#
#   scripts/test-host-gates.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR_REAL="$(cd "$HERE/.." && pwd)"
REPO_ROOT_REAL="$(cd "$SAMPLE_DIR_REAL/../../.." && pwd)"
mkdir -p "$REPO_ROOT_REAL/tmp"
WORK="$(mktemp -d "$REPO_ROOT_REAL/tmp/test-host-gates.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export ISSUE10_RUN_DIR="$WORK/run"

pass=0; fail=0
check() { # check <description> <expected-rc> <actual-rc> <log> [<regex the log must match>]
  local ok=0
  [[ "$3" -eq "$2" ]] || ok=1
  if [[ $ok -eq 0 && -n "${5:-}" ]]; then grep -qE -- "$5" "$4" || ok=1; fi
  if [[ $ok -eq 0 ]]; then printf '  PASS  %s (rc=%s)\n' "$1" "$3"; pass=$((pass+1))
  else printf '  FAIL  %s (expected rc=%s%s, got rc=%s)\n' "$1" "$2" "${5:+ and /$5/}" "$3"; sed 's/^/        | /' "$4" | tail -n 6; fail=$((fail+1)); fi
}

echo "== 1/2 containerd gate: scripts/30-runtime-install.sh --check-containerd ================"
STUB="$WORK/bin"; mkdir -p "$STUB"
# Stub containerd: answers only `--version`, with the line and exit code the case sets.
cat > "$STUB/containerd" <<'SH'
#!/bin/bash
[ "${1:-}" = --version ] || { echo "stub containerd: unexpected call: $*" >&2; exit 97; }
printf '%s\n' "$STUB_CONTAINERD_LINE"
exit "${STUB_CONTAINERD_RC:-0}"
SH
chmod +x "$STUB/containerd"
gate() { # gate <name> <version line> [rc] : run the REAL gate with the stub first on PATH
  env PATH="$STUB:$PATH" STUB_CONTAINERD_LINE="$2" STUB_CONTAINERD_RC="${3:-0}" \
    bash "$HERE/30-runtime-install.sh" --check-containerd > "$WORK/cd-$1.log" 2>&1
}
while IFS='|' read -r name line want why; do
  [ -n "$name" ] || continue
  rc=0; gate "$name" "$line" || rc=$?
  check "$why: '$line'" "$want" "$rc" "$WORK/cd-$name.log"
done <<'CASES'
u2.2.1|containerd github.com/containerd/containerd/v2 2.2.1 |0|ACCEPT 2.2.1 (Ubuntu EKS 1.36 AMI)
u2.2.7|containerd github.com/containerd/containerd/v2 2.2.7 abc123|0|ACCEPT a later 2.2.x
v2.1.5|containerd github.com/containerd/containerd/v2 v2.1.5 fcd43222|0|ACCEPT upstream v2.1.5
a2.3.0|containerd github.com/containerd/containerd/v2 2.3.0 |0|ACCEPT 2.3.0
a2.3.7|containerd github.com/containerd/containerd/v2 2.3.7+unknown |0|ACCEPT 2.3.7+unknown (AL2023 build string)
r2.4.0|containerd github.com/containerd/containerd/v2 2.4.0 |1|REJECT 2.4.0 (newer than the GA shim is tested on)
r2.10.1|containerd github.com/containerd/containerd/v2 2.10.1 |1|REJECT 2.10.1 (newer, not read as 2.1)
r2.0.5|containerd github.com/containerd/containerd/v2 v2.0.5 |1|REJECT 2.0.5 (older than 2.1)
r1.7.28|containerd github.com/containerd/containerd 1.7.28 |1|REJECT 1.7.28
r3.0.0|containerd github.com/containerd/containerd/v3 3.0.0 |1|REJECT 3.0.0
rrc|containerd github.com/containerd/containerd/v2 2.2.1-rc.1 |1|REJECT a pre-release (unreadable)
rjunk|runc version 1.2.3|1|REJECT output that is not containerd's
CASES
rc=0; gate fails "containerd github.com/containerd/containerd/v2 2.2.1 " 1 || rc=$?
check "REJECT a containerd whose --version exits non-zero, even with a good version line" 1 "$rc" "$WORK/cd-fails.log" 'failed \(exit 1\)'
grep -q 'supported by the GA shim' "$WORK/cd-u2.2.1.log"; check "the ACCEPT verdict says why (supported by the GA shim)" 0 $? "$WORK/cd-u2.2.1.log"
grep -q 'newer than the GA shim is tested on' "$WORK/cd-r2.4.0.log"; check "the 2.4 REJECT verdict says why (newer than tested)" 0 $? "$WORK/cd-r2.4.0.log"
grep -q 'older than the GA shim supports' "$WORK/cd-r2.0.5.log"; check "the 2.0 REJECT verdict says why (older than supported)" 0 $? "$WORK/cd-r2.0.5.log"

echo
echo "== 2/2 kernel config assertion: scripts/10-kernel.sh --assert-config =================="
GOOD="$WORK/config-good"
cat > "$GOOD" <<'CFG'
CONFIG_LOCALVERSION="-nitro-ga"
CONFIG_NITRO_ENCLAVES=y
CONFIG_CMA=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_BTF_MODULES=y
CONFIG_VHOST_VSOCK=m
CONFIG_EROFS_FS=m
CONFIG_TUN=y
CONFIG_VIRT_DRIVERS=y
CONFIG_VSOCKETS=m
CONFIG_VHOST_MENU=y
CONFIG_EXT4_FS=m
CONFIG_SQUASHFS=y
CONFIG_BLK_DEV_LOOP=y
CONFIG_OVERLAY_FS=m
CONFIG_BLK_DEV_NVME=y
CFG
variant() { # variant <name> <sed expression> : a copy of the good config with one change
  sed -e "$2" "$GOOD" > "$WORK/config-$1"
}
assert_cfg() { bash "$HERE/10-kernel.sh" --assert-config "$WORK/config-$1" > "$WORK/kc-$1.log" 2>&1; }
rc=0; assert_cfg good || rc=$?
check "ACCEPT a .config with every required symbol (VHOST_VSOCK, EROFS_FS as modules)" 0 "$rc" "$WORK/kc-good.log" 'KERNEL CONFIG OK'
variant ne-module   's/^CONFIG_NITRO_ENCLAVES=y$/CONFIG_NITRO_ENCLAVES=m/'
variant btf-off     's/^CONFIG_DEBUG_INFO_BTF=y$/# CONFIG_DEBUG_INFO_BTF is not set/'
variant btf-gone    '/^CONFIG_DEBUG_INFO_BTF=y$/d'
variant btfmod-off  's/^CONFIG_DEBUG_INFO_BTF_MODULES=y$/# CONFIG_DEBUG_INFO_BTF_MODULES is not set/'
variant cma-off     's/^CONFIG_CMA=y$/# CONFIG_CMA is not set/'
variant vsock-gone  '/^CONFIG_VHOST_VSOCK=/d'
variant gate-off    's/^CONFIG_VIRT_DRIVERS=y$/# CONFIG_VIRT_DRIVERS is not set/'
variant tun-gone    '/^CONFIG_TUN=/d'
while IFS='|' read -r name rx why; do
  [ -n "$name" ] || continue
  rc=0; assert_cfg "$name" || rc=$?
  check "$why" 1 "$rc" "$WORK/kc-$name.log" "$rx"
done <<'CASES'
ne-module|FAIL: CONFIG_NITRO_ENCLAVES is 'CONFIG_NITRO_ENCLAVES=m', must be y|REJECT CONFIG_NITRO_ENCLAVES=m (a module: mempool= would do nothing)
btf-off|FAIL: CONFIG_DEBUG_INFO_BTF is '<unset>'|REJECT BTF switched off (# CONFIG_DEBUG_INFO_BTF is not set)
btf-gone|FAIL: CONFIG_DEBUG_INFO_BTF is '<unset>'|REJECT BTF missing from the config
btfmod-off|FAIL: CONFIG_DEBUG_INFO_BTF_MODULES is '<unset>'|REJECT module BTF off
cma-off|FAIL: CONFIG_CMA is '<unset>'|REJECT CMA off
vsock-gone|FAIL: CONFIG_VHOST_VSOCK is '<unset>'|REJECT VHOST_VSOCK dropped by olddefconfig
gate-off|FAIL: CONFIG_VIRT_DRIVERS is '<unset>'|REJECT the VIRT_DRIVERS menu gate off
tun-gone|FAIL: CONFIG_TUN is '<unset>'|REJECT TUN missing
CASES
rc=0; bash "$HERE/10-kernel.sh" --assert-config "$WORK/does-not-exist" > "$WORK/kc-missing.log" 2>&1 || rc=$?
check "REJECT a missing .config file" 1 "$rc" "$WORK/kc-missing.log" 'missing or empty'

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "containerd gate and kernel config assertion proven both ways in the real scripts."
