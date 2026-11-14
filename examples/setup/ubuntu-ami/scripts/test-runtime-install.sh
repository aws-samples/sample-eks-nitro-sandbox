#!/usr/bin/env bash
# test-runtime-install.sh: runs the REAL scripts/30-runtime-install.sh, the full install, against a
# fixture system tree (SYSROOT) with stub commands first on PATH, and proves it both ways. No build
# host, no AWS, no network, no root.
#
#   scripts/test-runtime-install.sh     # needs Python 3.11+ for the TOML checks; it uses $PYTHON,
#                                       #   else python3.12, python3.11 or python3
#
# The inputs are scripts/testlib/fixture_inputs.py's small stand-ins (a runtime release signed with
# a P-384 test key, a guest image pair with sidecars, a Firecracker tarball), served through file://
# URLs, so the stage's own call to packages/fetch-runtime-artifacts.sh downloads and verifies them
# for real. The stubs: sudo (runs the command), containerd (--version only), systemctl and modprobe
# (record their arguments), losetup and mkfs.erofs (the stage's gates), and install (the real one,
# which can corrupt one named file after copying it, for the post-install hash case).
#
#   1  the install: the five files at their sources.lock paths, modes and hashes, the relative
#      rootfs.ext4 link, the kept signed manifest, the shim config, cri-proxy.service, the tun
#      module file, the systemctl and modprobe calls, the provenance lines; SHIM_DEBUG=true; a re-run
#   2  refusals before anything is installed: the guest image and data folders nested either way
#      or the same (review MUST-FIX 2), a relative folder, an install= line that is relative, holds
#      a . or .. component, has a mode that is not octal or names no verified file, a runtime input
#      that does not verify, no /dev/nitro_enclaves, a containerd out of range, an unknown argument
#   3  refusals after the install began: a file whose installed copy is not its pin, a failed
#      `systemctl enable cri-proxy.service`, no /dev/net/tun after modprobe
set -uo pipefail
# A reader's own config.env (in the sample folder or ~/ubuntu-ami/) must not change what this suite
# tests: scripts/lib/common.sh skips it while this test hook is set.
export UBUNTU_AMI_TESTS_IGNORE_CONFIG_ENV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE="$(cd "$HERE/.." && pwd)"
REPO_ROOT_REAL="$(cd "$SAMPLE/../../.." && pwd)"
mkdir -p "$REPO_ROOT_REAL/tmp"
WORK="$(mktemp -d "$REPO_ROOT_REAL/tmp/test-runtime-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
unset SYSROOT NITRO_SANDBOX_IMAGE_DIR NITRO_SANDBOX_DATA_DIR SHIM_DEBUG LOCK_FILE RUNTIME_ARTIFACTS_DIR

pass=0; fail=0
check() { # check <description> <expected-rc> <actual-rc> <log> [<regex the log must match>]
  local ok=0
  [[ "$3" -eq "$2" ]] || ok=1
  if [[ $ok -eq 0 && -n "${5:-}" ]]; then grep -qE -- "$5" "$4" || ok=1; fi
  if [[ $ok -eq 0 ]]; then printf '  PASS  %s (rc=%s)\n' "$1" "$3"; pass=$((pass+1))
  else printf '  FAIL  %s (expected rc=%s%s, got rc=%s)\n' "$1" "$2" "${5:+ and /$5/}" "$3"; sed 's/^/        | /' "$4" | tail -n 12; fail=$((fail+1)); fi
}
ok() { if [[ "$2" -eq 0 ]]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }

PY="${PYTHON:-}"
if [ -z "$PY" ]; then
  for c in python3.12 python3.11 python3; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import tomllib' 2>/dev/null; then PY=$(command -v "$c"); break; fi
  done
fi
if [ -z "$PY" ] || ! "$PY" -c 'import tomllib' 2>/dev/null; then
  echo "  SKIP  every case: no Python 3.11+ with tomllib found (set PYTHON)"; echo "passed 0, failed 0, skipped 1"; exit 1
fi
echo "using $PY ($("$PY" --version 2>&1))"

# --- stub commands ----------------------------------------------------------------------------
STUB="$WORK/bin"; mkdir -p "$STUB"
REAL_INSTALL="$(command -v install)"; export REAL_INSTALL
cat > "$STUB/sudo" <<'SH'
#!/bin/bash
[ "${1:-}" = -E ] && shift
exec "$@"
SH
cat > "$STUB/containerd" <<'SH'
#!/bin/bash
[ "${1:-}" = --version ] || { echo "stub containerd: unexpected call: $*" >&2; exit 97; }
printf '%s\n' "${STUB_CONTAINERD_LINE:-containerd github.com/containerd/containerd/v2 2.2.1 }"
SH
cat > "$STUB/systemctl" <<'SH'
#!/bin/bash
echo "$*" >> "$STUB_LOG/systemctl.calls"
case "$*" in
  daemon-reload) exit 0 ;;
  "enable cri-proxy.service") exit "${STUB_ENABLE_RC:-0}" ;;
  *) echo "stub systemctl: unexpected call: $*" >&2; exit 97 ;;
esac
SH
cat > "$STUB/modprobe" <<'SH'
#!/bin/bash
echo "$*" >> "$STUB_LOG/modprobe.calls"
SH
cat > "$STUB/install" <<'SH'
#!/bin/bash
# The real install; then, when STUB_INSTALL_CORRUPT names the destination's file name, one byte
# appended to the installed copy (a copy that is not what was verified).
"$REAL_INSTALL" "$@" || exit $?
last="${*: -1}"
if [ -n "${STUB_INSTALL_CORRUPT:-}" ] && [ "$(basename "$last")" = "$STUB_INSTALL_CORRUPT" ]; then printf 'x' >> "$last"; fi
SH
printf '#!/bin/bash\nexit 0\n' > "$STUB/losetup"
printf '#!/bin/bash\nexit 0\n' > "$STUB/mkfs.erofs"
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"

# --- inputs: the good fixture set, and variants of its lock -----------------------------------
mkdir -p "$WORK/lock"
python3 "$HERE/testlib/fixture_inputs.py" "$WORK/fx" "$WORK/lock/sources.lock"
ok "the fixture inputs and their lock are made (scripts/testlib/fixture_inputs.py)" $?
GOOD_LOCK="$WORK/lock/sources.lock"
lockvar() { # lockvar <name> <install= value>: the good lock plus one kind=file block that installs <value>
  mkdir -p "$WORK/locks/$1"; cp -- "$GOOD_LOCK" "$WORK/lock/fixture-runtime-v1.pub" "$WORK/locks/$1/"
  printf '\nid=extra-file\nkind=file\nref=fixture\nsource=file://%s/absent\nsha256=%s\ninstall=%s\nstatus=available\n' \
    "$WORK" "$(printf 'extra\n' | sha256sum | awk '{print $1}')" "$2" >> "$WORK/locks/$1/sources.lock"
}
lockvar relative "usr/bin/extra 0755"
lockvar dotdot "/usr/bin/../sbin/extra 0755"
lockvar badmode "/usr/bin/extra 755"
lockvar nofile "/usr/bin/extra 0755"
mkdir -p "$WORK/locks/badsig"
python3 "$HERE/testlib/fixture_inputs.py" "$WORK/fx-badsig" "$WORK/locks/badsig/sources.lock" bad-sig

# inst <case> [VAR=value...]: run the REAL stage into the case's fixture root $WORK/<case>/root
# (made on first use: /dev/nitro_enclaves and /dev/net/tun as links to /dev/null, the system
# folders the base image has). The lock is $LOCK when set, else the good one.
inst() {
  local c="$1"; shift
  local r="$WORK/$c/root"
  if [ ! -d "$r" ]; then
    mkdir -p "$r/dev/net" "$r/etc/systemd/system" "$r/etc/modules-load.d"
    ln -s /dev/null "$r/dev/nitro_enclaves"; ln -s /dev/null "$r/dev/net/tun"
  fi
  env SYSROOT="$r" LOCK_FILE="${LOCK:-$GOOD_LOCK}" ISSUE10_RUN_DIR="$WORK/$c/run" STUB_LOG="$WORK/$c" "$@" \
    bash "$HERE/30-runtime-install.sh" >> "$WORK/$c.log" 2>&1
}
# untouched <case>: the stage wrote nothing into the fixture root (only the fixture's own dev links)
untouched() { [ -z "$(cd "$WORK/$1/root" && find . -path ./dev -prune -o \( -type f -o -type l \) -print)" ]; }
pin() { sed -n "/^id=$2\$/,/^\$/s/^sha256=//p" "$1"; }

echo "== 1/3 the install: scripts/30-runtime-install.sh against a fixture root (review MUST-FIX 3) =="
rc=0; inst good || rc=$?
check "ACCEPT the full install from verified inputs" 0 "$rc" "$WORK/good.log" \
  'runtime release fixture \(x86_64\), guest image fixture/amd64, Firecracker vfixture installed from their public sources; containerd 2\.2\.1'
G="$WORK/good/root"
"$PY" - "$GOOD_LOCK" "$G" <<'PY'; check "  ... the five files at their sources.lock paths, with their modes and pinned SHA-256s" 0 $? "$WORK/good.log"
import hashlib, os, re, stat, sys
lock, root = sys.argv[1], sys.argv[2]
blocks = [dict(l.split("=", 1) for l in b.splitlines() if "=" in l) for b in open(lock).read().split("\n\n")]
inst = [b for b in blocks if b.get("install", "none") != "none"]
assert len(inst) == 5, inst
for b in inst:
    dest, mode = b["install"].split()
    st = os.lstat(root + dest)
    if not stat.S_ISREG(st.st_mode) or stat.S_IMODE(st.st_mode) != int(mode, 8):
        sys.exit(f"{dest}: not a regular file with mode {mode}")
    if hashlib.sha256(open(root + dest, "rb").read()).hexdigest() != b["sha256"]:
        sys.exit(f"{dest}: not its pin")
PY
[ -L "$G/var/lib/nitro-sandbox-images/rootfs.ext4" ] && [ "$(readlink "$G/var/lib/nitro-sandbox-images/rootfs.ext4")" = latest-disk.img ]
ok "  ... rootfs.ext4 is a relative link to latest-disk.img" $?
SD="$G/usr/local/share/ubuntu-ami-sample/runtime"
cmp -s "$SD/runtime-release.SHA256SUM" "$WORK/fx/SHA256SUM" && cmp -s "$SD/runtime-release.SHA256SUM.sig" "$WORK/fx/SHA256SUM.sig" \
  && [ "$(stat -c %a "$SD/runtime-release.SHA256SUM")" = 644 ] && [ "$(stat -c %a "$SD/runtime-release.SHA256SUM.sig")" = 644 ]
ok "  ... the signed manifest and its signature are kept, byte for byte, mode 0644" $?
rc=0; "$PY" "$HERE/lib/image_checks.py" shim "$G/etc/containerd/nitro-sandbox.toml" > "$WORK/good-shim.log" 2>&1 || rc=$?
check "  ... the shim config passes the shim check verify-image.py runs" 0 "$rc" "$WORK/good-shim.log" '^ok: shim config'
grep -qx 'kernel_path     = "/var/lib/nitro-sandbox-images/latest.eif"' "$G/etc/containerd/nitro-sandbox.toml" \
  && grep -qx 'debug           = false' "$G/etc/containerd/nitro-sandbox.toml" \
  && ! grep -rqF -- "$G" "$G/etc" && [ "$(stat -c %a "$G/etc/containerd/nitro-sandbox.toml")" = 644 ]
ok "  ... it names the real paths (not the fixture root), debug = false, mode 0644" $?
rc=0; "$PY" "$HERE/lib/image_checks.py" cri-unit "$G/etc/systemd/system/cri-proxy.service" > "$WORK/good-unit.log" 2>&1 || rc=$?
check "  ... cri-proxy.service passes the unit check, ExecStart the shim's cri-proxy" 0 "$rc" "$WORK/good-unit.log" '^ok: cri-proxy.service'
cmp -s "$G/etc/modules-load.d/nitro-sandbox-tun.conf" <(printf 'tun\n') \
  && [ "$(cat "$WORK/good/systemctl.calls")" = "$(printf 'daemon-reload\nenable cri-proxy.service')" ] \
  && [ "$(cat "$WORK/good/modprobe.calls")" = tun ]
ok "  ... the tun module file is written, systemctl daemon-reload then enable cri-proxy.service, modprobe tun" $?
[ "$(grep -c '^installed /' "$G/etc/ubuntu-ami-sample-manifest")" = 5 ] && grep -q 'containerd-shim-nitro-sandbox-v2 fixture stand-in' "$WORK/good.log" \
  && grep -q "^installed /usr/sbin/containerd-shim-nitro-sandbox-v2 mode 0755 sha256=$(pin "$GOOD_LOCK" runtime-shim) (runtime-shim fixture)$" "$G/etc/ubuntu-ami-sample-manifest"
ok "  ... the provenance manifest has one line per installed file, and the installed shim ran (--version)" $?
rc=0; inst good || rc=$?
check "ACCEPT a re-run on the same tree (the stage is idempotent)" 0 "$rc" "$WORK/good.log" 'installed from their public sources'
rc=0; inst debug SHIM_DEBUG=true || rc=$?
check "ACCEPT SHIM_DEBUG=true" 0 "$rc" "$WORK/debug.log" 'shim config debug=true'
grep -qx 'debug           = true' "$WORK/debug/root/etc/containerd/nitro-sandbox.toml" \
  && SHIM_DEBUG=true "$PY" "$HERE/lib/image_checks.py" shim "$WORK/debug/root/etc/containerd/nitro-sandbox.toml" > "$WORK/debug-shim.log" 2>&1
ok "  ... and its shim config says debug = true and passes the shim check with SHIM_DEBUG=true" $?

echo
echo "== 2/3 refusals before anything is installed ================================================"
# case|VAR=value (one, or none)|lock (good when empty)|regex the log must match|description
while IFS='|' read -r c envv lk rx why; do
  [ -n "$c" ] || continue
  envs=(); [ -z "$envv" ] || envs=("$envv")
  rc=0; LOCK="${lk:+$WORK/locks/$lk/sources.lock}" inst "$c" "${envs[@]}" || rc=$?
  check "$why" 1 "$rc" "$WORK/$c.log" "$rx"
  untouched "$c"; ok "  ... and nothing was installed ($c)" $?
done <<'CASES'
image-in-data|NITRO_SANDBOX_IMAGE_DIR=/var/lib/nitro-sandbox/images||NITRO_SANDBOX_IMAGE_DIR \(/var/lib/nitro-sandbox/images\) is inside NITRO_SANDBOX_DATA_DIR \(/var/lib/nitro-sandbox\)|REJECT the review's probe: the guest image folder inside the shim's data folder (MUST-FIX 2)
data-in-image|NITRO_SANDBOX_DATA_DIR=/var/lib/nitro-sandbox-images/data||NITRO_SANDBOX_DATA_DIR \(/var/lib/nitro-sandbox-images/data\) is inside NITRO_SANDBOX_IMAGE_DIR|REJECT the shim's data folder inside the guest image folder (MUST-FIX 2)
same|NITRO_SANDBOX_DATA_DIR=/var/lib/nitro-sandbox-images||are the same folder \(/var/lib/nitro-sandbox-images\)|REJECT one folder for both (MUST-FIX 2)
dotdot-dir|NITRO_SANDBOX_IMAGE_DIR=/var/lib/nitro-sandbox/x/../images||NITRO_SANDBOX_IMAGE_DIR \(/var/lib/nitro-sandbox/images\) is inside NITRO_SANDBOX_DATA_DIR|REJECT the guest image folder inside the data folder when it is spelled with .. (compared canonical)
relative-dir|NITRO_SANDBOX_IMAGE_DIR=var/lib/nitro-sandbox-images||NITRO_SANDBOX_IMAGE_DIR must be an absolute path|REJECT a relative guest image folder
relative||relative|sources.lock block extra-file install path is not absolute: usr/bin/extra|REJECT an install= path that is not absolute, after the five good blocks
dotdot||dotdot|sources.lock block extra-file install path has a . or .. component: /usr/bin/../sbin/extra|REJECT an install= path with a .. component
badmode||badmode|sources.lock block extra-file install mode is not octal: 755|REJECT an install= mode that is not octal
nofile||nofile|no verified file for sources.lock block extra-file in .*/node-files|REJECT an install= block with no verified file in node-files
badsig||badsig|signature over .* does not verify with fixture-runtime-v1.pub|REJECT a runtime release whose signed manifest does not verify (the stage's own fetch)
containerd-new|STUB_CONTAINERD_LINE=containerd github.com/containerd/containerd/v2 2.4.0 x||containerd 2\.4\.0 \(2\.4\.0\) is newer than this sample is validated on|REJECT a containerd newer than 2.3.x
CASES
mkdir -p "$WORK/nodev/root/etc/systemd/system" "$WORK/nodev/root/etc/modules-load.d" "$WORK/nodev/root/dev/net"
ln -s /dev/null "$WORK/nodev/root/dev/net/tun"
rc=0; inst nodev || rc=$?
check "REJECT a host with no /dev/nitro_enclaves" 1 "$rc" "$WORK/nodev.log" '/dev/nitro_enclaves missing: boot the host kernel from 10-kernel.sh'
untouched nodev; ok "  ... and nothing was installed (nodev)" $?
rc=0; env SYSROOT="$WORK/good/root" LOCK_FILE="$GOOD_LOCK" ISSUE10_RUN_DIR="$WORK/arg/run" bash "$HERE/30-runtime-install.sh" --install > "$WORK/arg.log" 2>&1 || rc=$?
check "REJECT an unknown argument" 1 "$rc" "$WORK/arg.log" 'unknown argument: --install'

echo
echo "== 3/3 refusals after the install began =========================================================="
rc=0; inst corrupt STUB_INSTALL_CORRUPT=latest.eif || rc=$?
check "REJECT an installed file that is not its pin (latest.eif changed after the copy)" 1 "$rc" "$WORK/corrupt.log" \
  "installed /var/lib/nitro-sandbox-images/latest.eif has SHA-256 [0-9a-f]{64}, not $(pin "$GOOD_LOCK" guest-image-eif)"
[ ! -e "$WORK/corrupt/root/etc/containerd/nitro-sandbox.toml" ] && [ ! -e "$WORK/corrupt/root/etc/systemd/system/cri-proxy.service" ]
ok "  ... and it stopped there: no shim config and no cri-proxy.service were written" $?
rc=0; inst enable STUB_ENABLE_RC=1 || rc=$?
check "REJECT a failed systemctl enable cri-proxy.service" 1 "$rc" "$WORK/enable.log" 'could not enable cri-proxy.service'
! grep -q 'installed from their public sources' "$WORK/enable/root/etc/ubuntu-ami-sample-manifest" && [ ! -e "$WORK/enable/root/etc/modules-load.d/nitro-sandbox-tun.conf" ]
ok "  ... and no completion line was written to the provenance manifest, and no tun module file" $?
mkdir -p "$WORK/notun/root/etc/systemd/system" "$WORK/notun/root/etc/modules-load.d" "$WORK/notun/root/dev"
ln -s /dev/null "$WORK/notun/root/dev/nitro_enclaves"
rc=0; inst notun || rc=$?
check "REJECT a host where /dev/net/tun is still missing after modprobe tun" 1 "$rc" "$WORK/notun.log" '/dev/net/tun missing after modprobe tun'

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "scripts/30-runtime-install.sh proven both ways: the full install, and every refusal, in the real script."
