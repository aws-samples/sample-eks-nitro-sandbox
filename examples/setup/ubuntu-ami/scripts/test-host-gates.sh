#!/usr/bin/env bash
# test-host-gates.sh: proves the build-host gates both ways, in the REAL scripts, with no
# build host, no cluster and no AWS:
#   scripts/30-runtime-install.sh --check-containerd   containerd 2.1.x to 2.3.x only (the GA
#        shim's range), read from `containerd --version` (a stub first on PATH prints the case)
#   scripts/10-kernel.sh --assert-config FILE          the required .config symbols, asserted on
#        the file as olddefconfig left it (fixture .config files)
#   scripts/10-kernel.sh --check-initramfs              the root filesystem at boot
#   scripts/00-preflight.sh                             the IMDSv2 token never on a command line, and
#        the enclave-hardware checks enforced only by its --after-reboot run (SYSROOT fixtures)
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

echo "== 1/5 containerd gate: scripts/30-runtime-install.sh --check-containerd ================"
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
echo "== 2/5 kernel config assertion: scripts/10-kernel.sh --assert-config =================="
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
echo "== 3/5 root filesystem at boot: scripts/10-kernel.sh --check-initramfs (H4) ============"
# Listings in the shape `lsinitramfs` prints; the module directory is the kernel release's.
printf 'usr/lib/modules/6.18.56-nitro-ga/kernel/drivers/nvme/host/nvme.ko.zst\nusr/bin/busybox\n' > "$WORK/initrd-no-ext4.list"
{ cat "$WORK/initrd-no-ext4.list"; echo 'usr/lib/modules/6.18.56-nitro-ga/kernel/fs/ext4/ext4.ko.zst'; } > "$WORK/initrd-ext4-zst.list"
{ cat "$WORK/initrd-no-ext4.list"; echo 'usr/lib/modules/6.18.56-nitro-ga/kernel/fs/ext4/ext4.ko'; } > "$WORK/initrd-ext4.list"
{ cat "$WORK/initrd-no-ext4.list"; echo 'usr/lib/modules/6.18.56-nitro-ga/kernel/fs/ext4/ext4.ko.bak'; } > "$WORK/initrd-ext4-bak.list"
variant ext4-y 's/^CONFIG_EXT4_FS=m$/CONFIG_EXT4_FS=y/'
variant ext4-off 's/^CONFIG_EXT4_FS=m$/# CONFIG_EXT4_FS is not set/'
ci() { bash "$HERE/10-kernel.sh" --check-initramfs "$WORK/config-$2" "$WORK/initrd-$3.list" > "$WORK/ci-$1.log" 2>&1; }
while IFS='|' read -r name cfg list want rx why; do
  [ -n "$name" ] || continue
  rc=0; ci "$name" "$cfg" "$list" || rc=$?
  check "$why" "$want" "$rc" "$WORK/ci-$name.log" "$rx"
done <<'CASES'
y-none|ext4-y|no-ext4|0|CONFIG_EXT4_FS=y \(built in\)|ACCEPT EXT4 built in (y) with no ext4.ko in the initramfs (the R1-A build failed here)
y-mod|ext4-y|ext4-zst|0|INITRAMFS OK|ACCEPT EXT4 built in (y) whatever else the initramfs holds
m-zst|good|ext4-zst|0|initramfs carries .*ext4\.ko\.zst|ACCEPT EXT4 as a module (m) with ext4.ko.zst in the initramfs
m-plain|good|ext4|0|initramfs carries .*ext4\.ko$|ACCEPT EXT4 as a module (m) with an uncompressed ext4.ko
m-none|good|no-ext4|1|CONFIG_EXT4_FS=m but the initramfs has no ext4\.ko|REJECT EXT4 as a module (m) with no ext4.ko in the initramfs
m-bak|good|ext4-bak|1|has no ext4\.ko|REJECT a file that only starts with ext4.ko (ext4.ko.bak)
off|ext4-off|ext4-zst|1|CONFIG_EXT4_FS is '<unset>', must be y or m|REJECT EXT4 not set, whatever the initramfs holds
CASES
rc=0; bash "$HERE/10-kernel.sh" --check-initramfs "$WORK/config-good" "$WORK/initrd-missing.list" > "$WORK/ci-nolist.log" 2>&1 || rc=$?
check "REJECT a missing initramfs listing" 1 "$rc" "$WORK/ci-nolist.log" 'listing .* is missing'
# The value the build really gets: run the kernel's own scripts/config, with the same --enable the
# build uses, on a copy of a config that has EXT4_FS=m, then the check on the result.
KTAR="${KERNEL_TARBALL:-$REPO_ROOT_REAL/tmp/issue10/run/runtime/linux-6.18.56.tar.xz}"
if [ -s "$KTAR" ] && tar -xJf "$KTAR" -C "$WORK" linux-6.18.56/scripts/config 2>"$WORK/ktar.err"; then
  cp "$WORK/config-good" "$WORK/config-from-build"
  rc=0; bash "$WORK/linux-6.18.56/scripts/config" --file "$WORK/config-from-build" --enable EXT4_FS > "$WORK/kcfg.log" 2>&1 || rc=$?
  grep -qx 'CONFIG_EXT4_FS=y' "$WORK/config-from-build"
  check "the kernel's own scripts/config --enable EXT4_FS (as 10-kernel.sh runs it) turns m into y" 0 $? "$WORK/kcfg.log"
  rc=0; ci from-build from-build no-ext4 || rc=$?
  check "  ... and that config passes the boot check with no ext4.ko in the initramfs" 0 "$rc" "$WORK/ci-from-build.log" 'built in'
  grep -qE '^\./scripts/config .*--enable EXT4_FS' "$HERE/10-kernel.sh" || grep -qE '^ +--enable OVERLAY_FS --enable EXT4_FS$' "$HERE/10-kernel.sh"
  check "  ... and 10-kernel.sh still enables EXT4_FS that way" 0 $? "$HERE/10-kernel.sh"
else
  echo "  SKIP  the kernel's own scripts/config run (no cached $(basename "$KTAR"); set KERNEL_TARBALL)"
fi
grep -qE '^check_initramfs_root_fs \.config "\$LOG_DIR/initrd-\$KREL\.list" \|\| die' "$HERE/10-kernel.sh"
check "the build calls the same check on its own .config and initramfs listing" 0 $? "$HERE/10-kernel.sh"
[ "$(grep -c '/ext4' "$HERE/10-kernel.sh")" = "$(grep -c '/ext4\\\.ko(\\\.(zst|xz|gz))?\$' "$HERE/10-kernel.sh")" ]
check "  ... and every ext4.ko match in 10-kernel.sh is the one inside that check (no unconditional grep left)" 0 $? "$HERE/10-kernel.sh"

echo
echo "== 4/5 the IMDSv2 token never on a command line: scripts/00-preflight.sh (M12) ========="
# Stub curl: records every argv (one line per call) and, for `-K -`, the config it reads on
# standard input. PUT .../api/token prints a sentinel token; a metadata GET answers only when its
# stdin config carries that token as the header (as IMDSv2 would), else fails like a 401.
IM="$WORK/imds"; mkdir -p "$IM/bin" "$IM/rt"
cat > "$IM/bin/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$IMDS_ARGV_LOG"
url=""; for a in "$@"; do case "$a" in http://*) url="$a" ;; esac; done
case "$url" in
  */latest/api/token) printf '%s' "$IMDS_SENTINEL" ;;
  */latest/meta-data/*)
    cfg=""; for a in "$@"; do [ "$a" = "-" ] && cfg=$(cat); done
    printf '%s\n' "$cfg" >> "$IMDS_STDIN_LOG"
    printf '%s\n' "$cfg" | grep -qxF "header = \"X-aws-ec2-metadata-token: $IMDS_SENTINEL\"" || { echo "curl: (22) 401" >&2; exit 22; }
    case "$url" in */instance-id) printf 'i-0example' ;; */instance-type) printf 'm8i.4xlarge' ;; *) printf 'example' ;; esac ;;
  *) echo "stub curl: unexpected $*" >&2; exit 97 ;;
esac
SH
chmod +x "$IM/bin/curl"
SENT="imds-token-sentinel-$$-Zq7"
rc=0; env PATH="$IM/bin:$PATH" IMDS_SENTINEL="$SENT" IMDS_ARGV_LOG="$IM/argv.log" IMDS_STDIN_LOG="$IM/stdin.log" \
  RUNTIME_ARTIFACTS_DIR="$IM/rt" bash "$HERE/00-preflight.sh" > "$IM/preflight.log" 2>&1 || rc=$?
grep -q 'instance=i-0example type=m8i.4xlarge' "$IM/preflight.log"
check "the real 00-preflight.sh reads instance identity with the token (it then stops, as it should off a build host)" 0 $? "$IM/preflight.log"
# leak <argv-log>: 0 when the sentinel token is absent from every recorded argv
leak() { ! grep -qF -- "$SENT" "$1"; }
ncalls=$(grep -c . "$IM/argv.log")
[ "$(grep -c '/latest/meta-data/' "$IM/argv.log")" -ge 4 ] && leak "$IM/argv.log"
check "ACCEPT: none of its $ncalls curl argvs (the token PUT and 4 metadata reads) carries the token" 0 $? "$IM/argv.log"
[ "$(grep -cxF "header = \"X-aws-ec2-metadata-token: $SENT\"" "$IM/stdin.log")" -ge 4 ]
check "  ... it reached curl on standard input instead, on every metadata call" 0 $? "$IM/stdin.log"
: > "$IM/argv-leak.log"
env PATH="$IM/bin:$PATH" IMDS_SENTINEL="$SENT" IMDS_ARGV_LOG="$IM/argv-leak.log" IMDS_STDIN_LOG="$IM/stdin-leak.log" \
  curl -sf -H "X-aws-ec2-metadata-token: $SENT" http://169.254.169.254/latest/meta-data/instance-id > /dev/null 2>&1
leak "$IM/argv-leak.log"
check "REJECT: the same detector catches the R1-A form (the token in a -H argument)" 1 $? "$IM/argv-leak.log"

echo
echo "== 5/5 enclave hardware, enforced only after the reboot: scripts/00-preflight.sh --after-reboot"
# The real 00-preflight.sh with SYSROOT fixtures for /dev/nitro_enclaves (a symlink to /dev/null,
# which is a character device) and pcie_slots_total, and stubs for uname -r, dmesg, sudo and curl.
# Off a build host its other sections fail (no bootstrap.sh, no snap) and the runtime archive is
# absent (exit 3), so each case reads the enclave section's own lines: its FAIL lines, and its ok
# lines when every check holds. The base-kernel fixture is what a live build host on Canonical's
# serial 20261027 showed before the kernel build: kernel 7.0.0-1014-aws, CONFIG_NITRO_ENCLAVES=m
# loaded, the device present, no pcie_slots_total, no BAR4 line.
PF="$WORK/pf"; PFB="$PF/bin"; mkdir -p "$PFB" "$PF/rt"
cat > "$PFB/uname" <<'SH'
#!/bin/bash
[ "${1:-}" = -r ] && { printf '%s\n' "$STUB_UNAME"; exit 0; }
exec /usr/bin/uname "$@"
SH
cat > "$PFB/dmesg" <<'SH'
#!/bin/bash
cat "$STUB_DMESG_FILE"
SH
cat > "$PFB/sudo" <<'SH'
#!/bin/bash
exec "$@"
SH
cat > "$PFB/curl" <<'SH'
#!/bin/bash
exit 22
SH
chmod +x "$PFB/uname" "$PFB/dmesg" "$PFB/sudo" "$PFB/curl"
BAR4_OK="nitro_enclaves 0000:00:05.0: BAR4 notify mapped at 00000000a1b2c3d4 (resource [mem 0xfe000000-0xfe003fff], len 16384)"
printf '%s\n' "$BAR4_OK" > "$PF/dmesg-bar4"
printf 'nitro_enclaves: loading out-of-tree module taints kernel\n' > "$PF/dmesg-none"
pf_root() { # pf_root <name> <dev: chr|file|none> <slots value, or none>
  local r="$PF/root-$1"; mkdir -p "$r/dev" "$r/sys/class/misc/nitro_enclaves"
  case "$2" in chr) ln -s /dev/null "$r/dev/nitro_enclaves" ;; file) : > "$r/dev/nitro_enclaves" ;; esac
  [ "$3" = none ] || printf '%s\n' "$3" > "$r/sys/class/misc/nitro_enclaves/pcie_slots_total"
  printf '%s' "$r"
}
pf() { # pf <case> <root> <uname -r> <dmesg file> [args]: the real 00-preflight.sh
  local c="$1" r="$2" u="$3" d="$4"; shift 4
  env PATH="$PFB:$PATH" SYSROOT="$r" STUB_UNAME="$u" STUB_DMESG_FILE="$d" RUNTIME_ARTIFACTS_DIR="$PF/rt" \
    bash "$HERE/00-preflight.sh" "$@" > "$PF/$c.log" 2>&1
}
NE_FAIL="^FAIL: (running kernel |/dev/nitro_enclaves absent|no pcie_slots_total|dmesg has no 'BAR4 notify)"
ne_fails() { grep -cE "$NE_FAIL" "$1"; }
R_BASE=$(pf_root base chr none); R_GOOD=$(pf_root good chr 110)
R_NODEV=$(pf_root nodev none 110); R_FILE=$(pf_root file file 110)
pf base-before "$R_BASE" 7.0.0-1014-aws "$PF/dmesg-none"
[ "$(ne_fails "$PF/base-before.log")" = 0 ] && grep -qE '^\[.*\] enclave checks not enforced on this run' "$PF/base-before.log" \
  && grep -qE '/dev/nitro_enclaves present, pcie_slots_total=<absent>$' "$PF/base-before.log"
check "ACCEPT before the reboot, on the base kernel as the live host had it (device present, no pcie_slots_total, no BAR4): no enclave FAIL, reported only" 0 $? "$PF/base-before.log"
pf good-after "$R_GOOD" 6.18.56-nitro-ga "$PF/dmesg-bar4" --after-reboot
[ "$(ne_fails "$PF/good-after.log")" = 0 ] && grep -qx 'ok: running the host kernel 6.18.56-nitro-ga' "$PF/good-after.log" \
  && grep -qx 'ok: /dev/nitro_enclaves present' "$PF/good-after.log" && grep -qx 'ok: pcie_slots_total=110' "$PF/good-after.log" \
  && grep -qx 'ok: dmesg reports BAR4 notify mapped' "$PF/good-after.log"
check "ACCEPT --after-reboot on 6.18.56-nitro-ga with the device, pcie_slots_total=110 and the BAR4 line: all four ok, no enclave FAIL" 0 $? "$PF/good-after.log"
pf base-after "$R_BASE" 7.0.0-1014-aws "$PF/dmesg-none" --after-reboot
[ "$(ne_fails "$PF/base-after.log")" = 3 ]
check "REJECT --after-reboot on the live host's base-kernel state: the kernel, pcie_slots_total and BAR4 all FAIL" 0 $? "$PF/base-after.log"
pf stock-kernel "$R_GOOD" 7.0.0-1014-aws "$PF/dmesg-bar4" --after-reboot
[ "$(ne_fails "$PF/stock-kernel.log")" = 1 ]
check "REJECT --after-reboot on any kernel but 6.18.56-nitro-ga, even with every other check met" 0 $? "$PF/stock-kernel.log" '^FAIL: running kernel 7\.0\.0-1014-aws, not 6\.18\.56-nitro-ga'
pf nodev "$R_NODEV" 6.18.56-nitro-ga "$PF/dmesg-bar4" --after-reboot
[ "$(ne_fails "$PF/nodev.log")" = 1 ]
check "REJECT --after-reboot with no /dev/nitro_enclaves" 0 $? "$PF/nodev.log" '^FAIL: /dev/nitro_enclaves absent'
pf file "$R_FILE" 6.18.56-nitro-ga "$PF/dmesg-bar4" --after-reboot
[ "$(ne_fails "$PF/file.log")" = 1 ]
check "REJECT --after-reboot when /dev/nitro_enclaves is a regular file, not a character device" 0 $? "$PF/file.log" '^FAIL: /dev/nitro_enclaves absent'
pf noslots "$R_BASE" 6.18.56-nitro-ga "$PF/dmesg-bar4" --after-reboot
[ "$(ne_fails "$PF/noslots.log")" = 1 ]
check "REJECT --after-reboot with no pcie_slots_total" 0 $? "$PF/noslots.log" '^FAIL: no pcie_slots_total'
pf nobar4 "$R_GOOD" 6.18.56-nitro-ga "$PF/dmesg-none" --after-reboot
[ "$(ne_fails "$PF/nobar4.log")" = 1 ]
check "REJECT --after-reboot with no BAR4 line in dmesg" 0 $? "$PF/nobar4.log" "^FAIL: dmesg has no 'BAR4 notify mapped' line"
# The driver's own message when the BAR is NOT mapped also holds "notify BAR4".
printf 'nitro_enclaves 0000:00:05.0: No notify BAR4, virtqueue kicks unavailable\n' > "$PF/dmesg-nobar4map"
pf bar4-unmapped "$R_GOOD" 6.18.56-nitro-ga "$PF/dmesg-nobar4map" --after-reboot
[ "$(ne_fails "$PF/bar4-unmapped.log")" = 1 ]
check "REJECT --after-reboot when dmesg says 'No notify BAR4, virtqueue kicks unavailable' (the BAR is not mapped)" 0 $? "$PF/bar4-unmapped.log" "^FAIL: dmesg has no 'BAR4 notify mapped' line"
rc=0; pf badarg "$R_GOOD" 6.18.56-nitro-ga "$PF/dmesg-bar4" --after-rebot || rc=$?
check "REJECT an unknown argument before any check runs" 1 "$rc" "$PF/badarg.log" '^FATAL: unknown argument: --after-rebot'

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "containerd gate, kernel config assertion, root filesystem boot check, IMDS token handling and the post-reboot enclave checks proven both ways in the real scripts."
