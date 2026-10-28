#!/usr/bin/env bash
# test-image-checks.sh: proves the build-host stages and the fresh-image check both ways, in the
# REAL scripts, against a fixture system tree (SYSROOT) with stub commands first on PATH. No
# build host, no AWS, no root.
#
#   scripts/test-image-checks.sh          # needs Python 3.11+ for the TOML checks; it uses
#                                         #   $PYTHON, else python3.12, python3.11 or python3
#
#   1  scripts/31-wire-containerd.sh   --check-template and the full stage (M9)
#   2  scripts/35-apparmor.sh          enforce mode required, service enablement checked (M8)
#   3  scripts/36-hold-packages.sh     containerd and kernel meta-packages held; policy kept (M6)
#   4  scripts/50-bake-prep.sh         residue removed, a failed scan refused, apt policy kept (M6, H9)
#   5  scripts/verify-image.py         the full flow on a good image and on one broken image per
#                                      check, under plain Python AND PYTHONOPTIMIZE=1 (H8, M9, M8)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE="$(cd "$HERE/.." && pwd)"
REPO_ROOT_REAL="$(cd "$SAMPLE/../../.." && pwd)"
mkdir -p "$REPO_ROOT_REAL/tmp"
WORK="$(mktemp -d "$REPO_ROOT_REAL/tmp/test-image-checks.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export ISSUE10_RUN_DIR="$WORK/run"
unset SYSROOT

pass=0; fail=0; skip=0
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
export PYTHON="$PY"
echo "using $PY ($("$PY" --version 2>&1))"

# --- stub commands ----------------------------------------------------------------------------
STUB="$WORK/bin"; mkdir -p "$STUB"
cat > "$STUB/sudo" <<'SH'
#!/bin/bash
exec "$@"
SH
cat > "$STUB/containerd" <<'SH'
#!/bin/bash
# --version: STUB_CONTAINERD_LINE. -c FILE config migrate: the v2 file as v3 (cri plugin renamed).
# -c FILE config dump: the file as is (STUB_DUMP_BREAK=1 breaks the confidential-sandbox handler).
if [ "${1:-}" = --version ]; then printf '%s\n' "${STUB_CONTAINERD_LINE:-containerd github.com/containerd/containerd/v2 2.2.1 }"; exit 0; fi
[ "${1:-}" = -c ] || { echo "stub containerd: unexpected call: $*" >&2; exit 97; }
f="$2"; shift 2
case "$*" in
  "config migrate") sed -e 's/^version = 2$/version = 3/' -e 's/"io\.containerd\.grpc\.v1\.cri"\.containerd/"io.containerd.cri.v1.runtime".containerd/g' "$f" ;;
  "config dump")
    if [ "${STUB_DUMP_BREAK:-}" = 1 ]; then
      awk '/runtimes\.confidential-sandbox\]/{b=1} b && /^runtime_type/{print "runtime_type = \"io.containerd.runc.v2\""; b=0; next} {print}' "$f"
    else cat "$f"; fi ;;
  *) echo "stub containerd: unexpected call: -c $f $*" >&2; exit 97 ;;
esac
SH
cat > "$STUB/systemctl" <<'SH'
#!/bin/bash
case "$1" in
  daemon-reload|stop|start) exit 0 ;;
  enable) exit "${STUB_ENABLE_RC:-0}" ;;
  is-enabled) echo "${STUB_IS_ENABLED:-enabled}"; [ "${STUB_IS_ENABLED:-enabled}" = enabled ] ;;
  *) echo "stub systemctl: unexpected call: $*" >&2; exit 97 ;;
esac
SH
cat > "$STUB/apparmor_parser" <<'SH'
#!/bin/bash
[ "$1" = -r ] || { echo "stub apparmor_parser: unexpected call: $*" >&2; exit 97; }
[ "${STUB_AA_MODE:-enforce}" = none ] && exit 0
echo "$(basename "$2") (${STUB_AA_MODE:-enforce})" >> "$SYSROOT/sys/kernel/security/apparmor/profiles"
SH
cat > "$STUB/dpkg" <<'SH'
#!/bin/bash
case "$1" in
  -S) [ -n "${STUB_DPKG_S_FAIL:-}" ] && { echo "dpkg-query: no path found matching pattern $2" >&2; exit 1; }
      echo "containerd-app: $2" ;;
  -s) [ "${STUB_EROFS_PKG:-}" = installed ] && { echo "Status: install ok installed"; exit 0; }
      echo "dpkg-query: package '$2' is not installed" >&2; exit 1 ;;
  *) echo "stub dpkg: unexpected call: $*" >&2; exit 97 ;;
esac
SH
cat > "$STUB/dpkg-query" <<'SH'
#!/bin/bash
printf '%s\n' "containerd-app installed" "linux-aws installed" "linux-image-aws installed" "linux-headers-aws installed" \
  "linux-image-7.0.0-1001-aws installed" "linux-modules-7.0.0-1001-aws installed" "linux-firmware installed" \
  "linux-base installed" "linux-generic not-installed" "bash installed"
SH
cat > "$STUB/apt-mark" <<'SH'
#!/bin/bash
f="$SYSROOT/.held"
case "$1" in
  hold) shift; [ -n "${STUB_APTMARK_FAIL:-}" ] && { echo "E: Can't select installed nor candidate version from package" >&2; exit 100; }
        printf '%s\n' "$@" >> "$f"; printf '%s set on hold.\n' "$@" ;;
  showhold) [ -f "$f" ] && sort -u "$f" ;;
  *) echo "stub apt-mark: unexpected call: $*" >&2; exit 97 ;;
esac
SH
cat > "$STUB/uname" <<'SH'
#!/bin/bash
[ "$1" = -r ] && { echo "${STUB_UNAME:-6.18.56-nitro-ga}"; exit 0; }
exec /bin/uname "$@"
SH
cat > "$STUB/systemd-run" <<'SH'
#!/bin/bash
while [ $# -gt 0 ] && [ "${1#--}" != "$1" ]; do shift; done
PATH="$SYSROOT/usr/local/bin:$PATH" exec "$@"
SH
for c in modprobe apt-get cloud-init journalctl; do printf '#!/bin/bash\nexit 0\n' > "$STUB/$c"; done
cat > "$STUB/find" <<'SH'
#!/bin/bash
for a in "$@"; do [ "$a" = -xdev ] && [ -n "${STUB_FIND_FAIL:-}" ] && { echo "find: '$1/opt/broken': Input/output error" >&2; exit 1; }; done
exec /usr/bin/find "$@"
SH
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"

TEMPLATE_BASE='version = 2
root = "/var/lib/containerd"
state = "/run/containerd"

[grpc]
address = "/run/containerd/containerd.sock"

[plugins."io.containerd.grpc.v1.cri"]
sandbox_image = "SANDBOX_IMAGE"

[plugins."io.containerd.grpc.v1.cri".containerd]
default_runtime_name = "runc"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
runtime_type = "io.containerd.runc.v2"
'
CRI_UNIT='[Unit]
Description=CRI Proxy for nitro-sandbox
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/sbin/containerd-shim-nitro-sandbox-v2 cri-proxy --listen /run/nitro-sandbox/cri-proxy.sock --containerd /run/containerd/containerd.sock
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
'
# base_root <dir>: a fresh Canonical-like tree before the sample's stages ran
base_root() {
  local r="$1"
  mkdir -p "$r/usr/local/share/eks" "$r/etc/eks" "$r/etc/systemd/system" "$r/etc/apparmor.d" "$r/etc/apt/apt.conf.d" \
           "$r/sys/kernel/security/apparmor" "$r/usr/local/share/ubuntu-ami-sample" "$r/etc/containerd"
  printf '%s' "$TEMPLATE_BASE" > "$r/usr/local/share/eks/containerd-config.toml"
  printf '#!/bin/bash\n# Canonical bootstrap (fixture)\nsnap set kubelet-eks container-runtime-endpoint=unix:///run/containerd/containerd.sock\n' > "$r/usr/local/share/eks/bootstrap.sh"
  printf '#!/bin/bash\nexec /usr/local/share/eks/bootstrap.sh "$@"\n' > "$r/etc/eks/bootstrap.sh"; chmod +x "$r/etc/eks/bootstrap.sh"
  printf '%s' "$CRI_UNIT" > "$r/etc/systemd/system/cri-proxy.service"
  : > "$r/sys/kernel/security/apparmor/profiles"
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > "$r/etc/apt/apt.conf.d/20auto-upgrades"
}
stage() { local s="$1" r="$2" log="$3"; shift 3; env SYSROOT="$r" "$@" bash "$HERE/$s" > "$log" 2>&1; }

echo "== 1/5 runtime wiring: scripts/31-wire-containerd.sh (M9) ==========================="
R1="$WORK/r1"; base_root "$R1"
rc=0; stage 31-wire-containerd.sh "$R1" "$WORK/w-good.log" || rc=$?
check "ACCEPT the stage on a fresh template: handlers, discard_unpacked_layers, endpoint, drop-in" 0 "$rc" "$WORK/w-good.log" 'checked in the template and in containerd.s migrated dump'
rc=0; bash "$HERE/31-wire-containerd.sh" --check-template "$R1/usr/local/share/eks/containerd-config.toml" > "$WORK/t-good.log" 2>&1 || rc=$?
check "ACCEPT --check-template on the template the stage wrote" 0 "$rc" "$WORK/t-good.log" 'discard_unpacked_layers = false in the cri containerd table'
"$PY" - "$R1/usr/local/share/eks/containerd-config.toml" <<'PY'; ok "the stage put discard_unpacked_layers=false INSIDE the cri containerd table (parsed)" $?
import sys, tomllib
c = tomllib.loads(open(sys.argv[1]).read())["plugins"]["io.containerd.grpc.v1.cri"]["containerd"]
sys.exit(0 if c.get("discard_unpacked_layers") is False and c["default_runtime_name"] == "runc" else 1)
PY
rc=0; stage 31-wire-containerd.sh "$R1" "$WORK/w-rerun.log" || rc=$?
check "ACCEPT a re-run of the stage (idempotent)" 0 "$rc" "$WORK/w-rerun.log"
T="$WORK/templates"; mkdir -p "$T"
good="$R1/usr/local/share/eks/containerd-config.toml"
sed 's/^discard_unpacked_layers = false$/discard_unpacked_layers = true/' "$good" > "$T/discard-true.toml"
# false, but in the PARENT cri table and only commented in the containerd table: wrong place
sed -e '/^discard_unpacked_layers = false$/d' -e 's/^sandbox_image = "SANDBOX_IMAGE"$/sandbox_image = "SANDBOX_IMAGE"\ndiscard_unpacked_layers = false/' \
    -e 's/^default_runtime_name = "runc"$/default_runtime_name = "runc"\n# discard_unpacked_layers = false/' "$good" > "$T/discard-wrong-table.toml"
awk '/runtimes\.confidential-sandbox\]/{b=1} b && /^runtime_type/{print "runtime_type = \"io.containerd.runc.v2\""; b=0; next} {print}' "$good" > "$T/handler-type.toml"
sed 's/^\[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.isolated-sandbox\]$/# &/' "$good" | sed '/^# \[plugins.*isolated-sandbox\]$/,/^$/s/^\([a-z]\)/# \1/' > "$T/handler-commented.toml"
sed 's/^version = 2$/version = 3/' "$good" > "$T/v3.toml"
while IFS='|' read -r name rx why; do
  [ -n "$name" ] || continue
  cmp -s "$good" "$T/$name.toml" && { echo "  FAIL  fixture $name did not change the template"; fail=$((fail+1)); continue; }
  rc=0; bash "$HERE/31-wire-containerd.sh" --check-template "$T/$name.toml" > "$WORK/t-$name.log" 2>&1 || rc=$?
  check "$why" 1 "$rc" "$WORK/t-$name.log" "$rx"
done <<'CASES'
discard-true|discard_unpacked_layers is True in the cri containerd table|REJECT discard_unpacked_layers = true in the cri containerd table
discard-wrong-table|discard_unpacked_layers is not set in|REJECT discard_unpacked_layers=false only in another table and in a comment
handler-type|handler confidential-sandbox runtime_type is|REJECT a handler with the wrong runtime_type
handler-commented|runtime handler isolated-sandbox is missing|REJECT a handler that exists only in comments
v3|version 3, must be 2|REJECT a template that is not config version 2
CASES
R2="$WORK/r2"; base_root "$R2"
rc=0; stage 31-wire-containerd.sh "$R2" "$WORK/w-dump.log" STUB_DUMP_BREAK=1 || rc=$?
check "REJECT the stage when containerd's own migrated dump carries a wrong handler" 1 "$rc" "$WORK/w-dump.log" "dumped handler confidential-sandbox runtime_type"
R3="$WORK/r3"; base_root "$R3"; sed -i 's/^default_runtime_name = "runc"$/default_runtime_name = "runc"\ndiscard_unpacked_layers = true/' "$R3/usr/local/share/eks/containerd-config.toml"
rc=0; stage 31-wire-containerd.sh "$R3" "$WORK/w-true.log" || rc=$?
check "REJECT the stage on a template whose cri containerd table already says discard_unpacked_layers = true" 1 "$rc" "$WORK/w-true.log" 'other than false in the cri containerd table'
R4="$WORK/r4"; base_root "$R4"; printf '# container-runtime-endpoint=unix:///run/nitro-sandbox/cri-proxy.sock\n' >> "$R4/usr/local/share/eks/bootstrap.sh"
sed -i 's#^snap set kubelet-eks container-runtime-endpoint=unix:///run/containerd/containerd.sock$#snap set kubelet-eks container-runtime-endpoint=unix:///run/containerd/other.sock#' "$R4/usr/local/share/eks/bootstrap.sh"
rc=0; stage 31-wire-containerd.sh "$R4" "$WORK/w-boot.log" || rc=$?
check "REJECT the stage when the only cri-proxy endpoint in bootstrap.sh is a comment" 1 "$rc" "$WORK/w-boot.log" 'does not set the cri-proxy endpoint'
R5="$WORK/r5"; base_root "$R5"; sed -i 's#^ExecStart=.*#ExecStart=/usr/bin/sleep infinity\n\# ExecStart=/usr/sbin/containerd-shim-nitro-sandbox-v2 cri-proxy --listen /run/nitro-sandbox/cri-proxy.sock --containerd /run/containerd/containerd.sock#' "$R5/etc/systemd/system/cri-proxy.service"
rc=0; stage 31-wire-containerd.sh "$R5" "$WORK/w-unit.log" || rc=$?
check "REJECT the stage when cri-proxy.service runs something else (the right ExecStart only in a comment)" 1 "$rc" "$WORK/w-unit.log" 'cri-proxy.service ExecStart is'

echo
echo "== 2/5 AppArmor: scripts/35-apparmor.sh (M8) ==========================================="
aa() { local n="$1"; shift; local r="$WORK/aa-$n"; base_root "$r"; rc=0; stage 35-apparmor.sh "$r" "$WORK/aa-$n.log" "$@" || rc=$?; }
aa enforce;   check "ACCEPT a profile the kernel lists in enforce mode, service enabled" 0 "$rc" "$WORK/aa-enforce.log" 'loaded in enforce mode'
aa complain STUB_AA_MODE=complain; check "REJECT a profile loaded in complain mode" 1 "$rc" "$WORK/aa-complain.log" "is 'complain', not 'enforce'"
aa none STUB_AA_MODE=none;         check "REJECT a profile the kernel does not list" 1 "$rc" "$WORK/aa-none.log" "is 'not loaded', not 'enforce'"
aa enable STUB_ENABLE_RC=1;        check "REJECT when systemctl enable apparmor.service fails" 1 "$rc" "$WORK/aa-enable.log" 'could not enable apparmor.service'
aa isen STUB_IS_ENABLED=disabled;  check "REJECT when apparmor.service is not enabled after enable" 1 "$rc" "$WORK/aa-isen.log" "is 'disabled' after enable"

echo
echo "== 3/5 package holds: scripts/36-hold-packages.sh (M6) ================================="
RH="$WORK/holds"; base_root "$RH"
rc=0; stage 36-hold-packages.sh "$RH" "$WORK/h-good.log" || rc=$?
check "ACCEPT: holds the containerd owner and the installed kernel meta-packages" 0 "$rc" "$WORK/h-good.log" 'HOLDS: PASS \(4 package\(s\) held: containerd-app linux-aws linux-image-aws linux-headers-aws\)'
! grep -qE 'linux-image-7|linux-modules-7|linux-firmware|linux-base' "$RH/.held"; ok "  ... and no versioned kernel, firmware or linux-base package" $?
grep -qF '"^containerd-app$";' "$RH/etc/apt/apt.conf.d/51ubuntu-ami-sample-holds" && grep -qF '"^linux-image-aws$";' "$RH/etc/apt/apt.conf.d/51ubuntu-ami-sample-holds"
ok "  ... and lists each, anchored, in Unattended-Upgrade::Package-Blacklist" $?
grep -qx 'APT::Periodic::Unattended-Upgrade "1";' "$RH/etc/apt/apt.conf.d/20auto-upgrades"; ok "  ... and leaves the base AMI's unattended-upgrade policy as it was" $?
RH2="$WORK/holds2"; base_root "$RH2"
rc=0; stage 36-hold-packages.sh "$RH2" "$WORK/h-fail.log" STUB_APTMARK_FAIL=1 || rc=$?
check "REJECT when apt-mark hold fails" 1 "$rc" "$WORK/h-fail.log" 'apt-mark hold failed'
RH3="$WORK/holds3"; base_root "$RH3"
rc=0; stage 36-hold-packages.sh "$RH3" "$WORK/h-noown.log" STUB_DPKG_S_FAIL=1 || rc=$?
check "REJECT when no package owns containerd (it could not be held)" 1 "$rc" "$WORK/h-noown.log" 'no Debian package owns'

echo
echo "== 4/5 bake prep: scripts/50-bake-prep.sh (M6, H9) ======================================"
bake_root() { # bake_root <dir>: a build host's leftovers, in a copy of the sample laid out as on the host
  local r="$1"; base_root "$r"
  mkdir -p "$r/root/linux-6.18.56" "$r/root/build-erofs" "$r/var/lib/ubuntu-ami-sample/stage" "$r/etc/ssh" "$r/var/lib/dbus" "$r/tmp" "$r/opt"
  : > "$r/root/linux-6.18.56/Makefile"; : > "$r/var/lib/ubuntu-ami-sample/stage/x.zip"
  : > "$r/etc/ssh/ssh_host_ed25519_key"; : > "$r/etc/ssh/ssh_host_ed25519_key.pub"; echo 0123abcd > "$r/etc/machine-id"
  cp -a "$SAMPLE/." "$r/usr/local/share/ubuntu-ami-sample/"
  mkdir -p "$r/hostrun/runtime"; : > "$r/hostrun/runtime/linux-6.18.56.tar.xz"
}
bake() { local r="$1" log="$2"; shift 2
  env SYSROOT="$r" HOME="$r/root" ISSUE10_RUN_DIR="$r/hostrun" STAGE_DIR="$r/var/lib/ubuntu-ami-sample/stage" "$@" \
    bash "$r/usr/local/share/ubuntu-ami-sample/scripts/50-bake-prep.sh" > "$log" 2>&1; }
B1="$WORK/bake1"; bake_root "$B1"
rc=0; bake "$B1" "$WORK/b-good.log" || rc=$?
check "ACCEPT: the kernel tree, staged files, archives, host keys and machine-id are removed" 0 "$rc" "$WORK/b-good.log" 'BAKE-PREP: PASS'
[ ! -e "$B1/root/linux-6.18.56" ] && [ ! -e "$B1/hostrun/runtime" ] && [ ! -e "$B1/etc/ssh/ssh_host_ed25519_key" ] && [ ! -s "$B1/etc/machine-id" ]
ok "  ... the fixture shows them gone" $?
grep -qx 'APT::Periodic::Update-Package-Lists "1";' "$B1/etc/apt/apt.conf.d/20auto-upgrades" && grep -qx 'APT::Periodic::Unattended-Upgrade "1";' "$B1/etc/apt/apt.conf.d/20auto-upgrades"
ok "  ... and the base AMI's package-list refresh and unattended upgrades are left on (M6)" $?
B2="$WORK/bake2"; bake_root "$B2"
rc=0; bake "$B2" "$WORK/b-find.log" STUB_FIND_FAIL=1 || rc=$?
check "REJECT (could not determine) when the residue scan itself fails (H9)" 1 "$rc" "$WORK/b-find.log" 'could not determine whether build residue remains'
B3="$WORK/bake3"; bake_root "$B3"; : > "$B3/opt/erofs-utils-1.8.10.tar.gz"
rc=0; bake "$B3" "$WORK/b-left.log" || rc=$?
check "REJECT when a build archive survives somewhere the removal list does not cover" 1 "$rc" "$WORK/b-left.log" 'STILL PRESENT: .*erofs-utils-1.8.10.tar.gz'
rc=0; env SYSROOT="$B3" bash "$HERE/50-bake-prep.sh" > "$WORK/b-checkout.log" 2>&1 || rc=$?
check "REJECT running bake prep from a repository checkout" 1 "$rc" "$WORK/b-checkout.log" 'runs on the build host only'

echo
echo "== 5/5 fresh-image check: scripts/verify-image.py, plain and PYTHONOPTIMIZE=1 (H8, M9, M8) =="
# A good image: the stages above run for real against one tree, then the rest of the image.
G="$WORK/good"; base_root "$G"
stage 31-wire-containerd.sh "$G" "$WORK/g-31.log" && stage 35-apparmor.sh "$G" "$WORK/g-35.log" && stage 36-hold-packages.sh "$G" "$WORK/g-36.log"
ok "the good image is built by running 31, 35 and 36 on it" $?
mkdir -p "$G/dev/net" "$G/sys/kernel/btf" "$G/proc" "$G/sys/module/apparmor/parameters" "$G/var/lib/nitro-sandbox-images" "$G/usr/local/bin"
ln -s /dev/null "$G/dev/nitro_enclaves"; ln -s /dev/null "$G/dev/vhost-vsock"; ln -s /dev/null "$G/dev/net/tun"
echo btf > "$G/sys/kernel/btf/vmlinux"; printf 'MemTotal: 16000000 kB\nCmaTotal: 1048576 kB\n' > "$G/proc/meminfo"
printf 'nodev\tproc\n\text4\n\terofs\n' > "$G/proc/filesystems"; echo Y > "$G/sys/module/apparmor/parameters/enabled"
printf 'kernel_path     = "/var/lib/nitro-sandbox-images/latest.eif"\nrootfs_path     = "/var/lib/nitro-sandbox-images/rootfs.ext4"\npcie_slots      = 110\nnitro_sandbox   = true\ncpu_overcommit  = true\ndata_base_dir   = "/var/lib/nitro-sandbox"\nkubeconfig_path = "/var/lib/kubelet/kubeconfig"\nformat_overlay  = true\ndebug           = false\n' > "$G/etc/containerd/nitro-sandbox.toml"
cat > "$G/usr/local/bin/mkfs.erofs" <<'SH'
#!/bin/bash
case "$1" in --version|-V) echo "mkfs.erofs ${STUB_EROFS_VERSION:-1.8.10}" ;; -zzstd,1) : > "$2" ;; *) exit 2 ;; esac
SH
chmod +x "$G/usr/local/bin/mkfs.erofs"
# Runtime payloads at their sources.lock paths and modes, with a test lock pinned to these bytes.
"$PY" - "$SAMPLE/packages/sources.lock" "$G" "$WORK/test.lock" <<'PY'
import hashlib, os, re, sys
lock, root, out = sys.argv[1:4]
text = open(lock).read()
blocks = text.split("\n\n")
sums = []
for i, b in enumerate(blocks):
    if "\nkind=runtime-payload\n" not in "\n" + b + "\n":
        continue
    f = re.search(r"^file=(.*)$", b, re.M).group(1)
    inst = re.search(r"^install=(.*)$", b, re.M).group(1)
    data = f"fixture payload {f}\n".encode()
    h = hashlib.sha256(data).hexdigest()
    sums.append(f"{h}  {f}")
    blocks[i] = re.sub(r"^sha256=.*$", f"sha256={h}", b, flags=re.M)
    if inst != "none":
        dest, mode = inst.split()
        p = root + dest
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "wb").write(data)
        os.chmod(p, int(mode, 8))
open(out, "w").write("\n\n".join(blocks))
open(root + "/usr/local/share/ubuntu-ami-sample/runtime-SHA256SUMS", "w").write("\n".join(sorted(sums, key=lambda l: l.split("  ")[1])) + "\n")
PY
ln -sfn latest-disk.img "$G/var/lib/nitro-sandbox-images/rootfs.ext4"
vi() { local r="$1" log="$2"; shift 2; env SYSROOT="$r" LOCK_FILE="$WORK/test.lock" "$@" "$PY" "$HERE/verify-image.py" > "$log" 2>&1; }
for mode in plain optimized; do
  if [ "$mode" = optimized ]; then OPT=(PYTHONOPTIMIZE=1); else OPT=(); fi
  rc=0; vi "$G" "$WORK/v-good-$mode.log" "${OPT[@]}" || rc=$?
  check "[$mode] ACCEPT the good image: every check passes" 0 "$rc" "$WORK/v-good-$mode.log" '"image_configuration": "PASS"'
  # one broken image per check: copy, break one thing, expect that check (and only a FAIL) to answer
  while IFS='|' read -r name failed_check; do
    [ -n "$name" ] || continue
    b="$WORK/bad-$name-$mode"; cp -a "$G" "$b"; env=()
    case "$name" in
      kernel)     env=(STUB_UNAME=7.0.0-1001-aws) ;;
      nedev)      rm "$b/dev/nitro_enclaves"; : > "$b/dev/nitro_enclaves" ;;
      complain)   sed -i 's/(enforce)$/(complain)/' "$b/sys/kernel/security/apparmor/profiles" ;;
      discard)    sed -i 's/^discard_unpacked_layers = false$/discard_unpacked_layers = true/' "$b/usr/local/share/eks/containerd-config.toml" ;;
      dump)       env=(STUB_DUMP_BREAK=1) ;;
      dropin)     sed -i 's/^After=cri-proxy.service$/#After=cri-proxy.service/' "$b/etc/systemd/system/snap.kubelet-eks.daemon.service.d/50-cri-proxy.conf" ;;
      debug)      sed -i 's/^debug           = false$/debug           = true/' "$b/etc/containerd/nitro-sandbox.toml" ;;
      jailermode) chmod 0644 "$b/usr/bin/jailer" ;;
      tamper)     echo tampered >> "$b/usr/sbin/containerd-shim-nitro-sandbox-v2" ;;
      hold)       grep -vx containerd-app "$b/.held" > "$b/.held.new"; mv "$b/.held.new" "$b/.held" ;;
      containerd) env=(STUB_CONTAINERD_LINE="containerd github.com/containerd/containerd/v2 2.4.0 ") ;;
      erofs)      env=(STUB_EROFS_VERSION=1.7.1) ;;
      btf)        : > "$b/sys/kernel/btf/vmlinux" ;;
    esac
    rc=0; vi "$b" "$WORK/v-$name-$mode.log" "${OPT[@]}" "${env[@]}" || rc=$?
    check "[$mode] REJECT a broken image ($name): $failed_check fails" 1 "$rc" "$WORK/v-$name-$mode.log" "^image_configuration: FAIL \(failed: ([a-z_]+, )*$failed_check(, [a-z_]+)*\)$"
  done <<'CASES'
kernel|host_kernel
nedev|nitro_enclaves_device
complain|apparmor
discard|runtime_wiring
dump|runtime_wiring
dropin|runtime_wiring
debug|runtime_wiring
jailermode|runtime_payloads
tamper|runtime_payloads
hold|package_holds
containerd|containerd_version
erofs|mkfs_erofs
btf|btf
CASES
done
grep -q '"failed": \[\]' "$WORK/v-good-optimized.log" && ! grep -q '"image_configuration": "PASS"' "$WORK/v-discard-optimized.log"
ok "under PYTHONOPTIMIZE=1 a broken image still fails (the checks are not asserts)" $?

echo
printf 'passed %d, failed %d, skipped %d\n' "$pass" "$fail" "$skip"
[[ "$fail" -eq 0 ]] || exit 1
echo "build-host stages and the fresh-image check proven both ways in the real scripts."
