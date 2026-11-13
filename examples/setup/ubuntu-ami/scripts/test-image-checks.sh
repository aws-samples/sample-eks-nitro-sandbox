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
# -c FILE config dump: the file as is (STUB_DUMP_BREAK=1 breaks the confidential-sandbox handler's
# runtime_type; STUB_DUMP_BREAK=priv sets privileged_without_host_devices = false on both handlers).
if [ "${1:-}" = --version ]; then printf '%s\n' "${STUB_CONTAINERD_LINE:-containerd github.com/containerd/containerd/v2 2.2.1 }"; exit 0; fi
[ "${1:-}" = -c ] || { echo "stub containerd: unexpected call: $*" >&2; exit 97; }
f="$2"; shift 2
case "$*" in
  "config migrate") sed -e 's/^version = 2$/version = 3/' -e 's/"io\.containerd\.grpc\.v1\.cri"\.containerd/"io.containerd.cri.v1.runtime".containerd/g' "$f" ;;
  "config dump")
    case "${STUB_DUMP_BREAK:-}" in
      1) awk '/runtimes\.confidential-sandbox\]/{b=1} b && /^runtime_type/{print "runtime_type = \"io.containerd.runc.v2\""; b=0; next} {print}' "$f" ;;
      priv) sed 's/^privileged_without_host_devices = true$/privileged_without_host_devices = false/' "$f" ;;
      *) cat "$f" ;;
    esac ;;
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
# STUB_DPKGQ_FAIL=1: the query itself fails. STUB_DPKGQ_NOKERNEL=1: it succeeds but lists no
# installed kernel meta-package (only versioned kernels, firmware, and meta-packages not installed).
[ -n "${STUB_DPKGQ_FAIL:-}" ] && { echo "dpkg-query: error: parsing file '/var/lib/dpkg/status' near line 7: missing 'Package' field" >&2; exit 2; }
if [ -n "${STUB_DPKGQ_NOKERNEL:-}" ]; then
  printf '%s\n' "containerd-app installed" "linux-image-7.0.0-1001-aws installed" "linux-modules-7.0.0-1001-aws installed" \
    "linux-firmware installed" "linux-base installed" "linux-aws not-installed" "linux-generic config-files" "bash installed"
  exit 0
fi
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
# RR-012: the reviewer's inline-comment probe. The active `snap set` sets a wrong endpoint; the
# stage's own sed turns the inline comment's value into the cri-proxy socket.
R6="$WORK/r6"; base_root "$R6"
sed -i 's#^snap set kubelet-eks container-runtime-endpoint=unix:///run/containerd/containerd.sock$#snap set kubelet-eks container-runtime-endpoint=unix:///run/containerd/other.sock \# container-runtime-endpoint=unix:///run/containerd/containerd.sock#' "$R6/usr/local/share/eks/bootstrap.sh"
rc=0; stage 31-wire-containerd.sh "$R6" "$WORK/w-inline.log" || rc=$?
check "REJECT the stage when the active snap set endpoint is wrong and the cri-proxy one follows # on the same line" 1 "$rc" "$WORK/w-inline.log" "sets container-runtime-endpoint to 'unix:///run/containerd/other.sock'"
grep -qxF 'snap set kubelet-eks container-runtime-endpoint=unix:///run/containerd/other.sock # container-runtime-endpoint=unix:///run/nitro-sandbox/cri-proxy.sock' "$R6/usr/local/share/eks/bootstrap.sh"
ok "  ... the checked bootstrap.sh line is the reviewer's probe" $?
# RR-012: a migrated dump whose handlers both say privileged_without_host_devices = false (the
# template itself is correct, so only the dump check can refuse it).
R7="$WORK/r7"; base_root "$R7"
rc=0; stage 31-wire-containerd.sh "$R7" "$WORK/w-priv.log" STUB_DUMP_BREAK=priv || rc=$?
check "REJECT the stage when containerd's migrated dump has privileged_without_host_devices = false on both handlers" 1 "$rc" "$WORK/w-priv.log" 'dumped handler isolated-sandbox privileged_without_host_devices is False, must be true'
[ "$(STUB_DUMP_BREAK=priv containerd -c "$R1/usr/local/share/eks/containerd-config.toml" config dump | grep -c '^privileged_without_host_devices = false$')" = 2 ] \
  && ! STUB_DUMP_BREAK=priv containerd -c "$R1/usr/local/share/eks/containerd-config.toml" config dump | grep -q '^privileged_without_host_devices = true$'
ok "  ... the probe dump sets it false on both handlers and true on none" $?

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
RH4="$WORK/holds4"; base_root "$RH4"
rc=0; stage 36-hold-packages.sh "$RH4" "$WORK/h-dpkgq.log" STUB_DPKGQ_FAIL=1 || rc=$?
check "REJECT when the dpkg-query listing itself fails" 1 "$rc" "$WORK/h-dpkgq.log" 'dpkg-query failed \(exit 2\)'
RH5="$WORK/holds5"; base_root "$RH5"
rc=0; stage 36-hold-packages.sh "$RH5" "$WORK/h-nokernel.log" STUB_DPKGQ_NOKERNEL=1 || rc=$?
check "REJECT when dpkg-query succeeds but lists no installed kernel meta-package" 1 "$rc" "$WORK/h-nokernel.log" 'lists no installed Ubuntu kernel meta-package'
[ ! -e "$RH4/.held" ] && [ ! -e "$RH5/.held" ]; ok "  ... and neither holds anything (refused before apt-mark hold)" $?

echo
echo "== 4/5 bake prep: scripts/50-bake-prep.sh (M6, H9) ======================================"
bake_root() { # bake_root <dir>: a build host's leftovers, in a copy of the sample laid out as on the host
  local r="$1"; base_root "$r"
  mkdir -p "$r/root/linux-6.18.56" "$r/root/build-erofs" "$r/var/lib/ubuntu-ami-sample/stage" "$r/etc/ssh" "$r/var/lib/dbus" "$r/tmp" "$r/opt"
  : > "$r/root/linux-6.18.56/Makefile"; : > "$r/var/lib/ubuntu-ami-sample/stage/x.zip"
  : > "$r/etc/ssh/ssh_host_ed25519_key"; : > "$r/etc/ssh/ssh_host_ed25519_key.pub"; echo 0123abcd > "$r/etc/machine-id"
  cp -a "$SAMPLE/." "$r/usr/local/share/ubuntu-ami-sample/"
  mkdir -p "$r/hostrun/runtime/downloads" "$r/hostrun/runtime/node-files"; : > "$r/hostrun/runtime/linux-6.18.56.tar.xz"
  : > "$r/hostrun/runtime/downloads/nitro-sandboxes-runtime.tar.gz"; : > "$r/hostrun/runtime/node-files/guest-image-disk"
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
B4="$WORK/bake4"; bake_root "$B4"; : > "$B4/opt/nitro-sandbox-guest-disk.img"; : > "$B4/opt/firecracker-v1.18.0-x86_64.tgz.part"
rc=0; bake "$B4" "$WORK/b-left4.log" || rc=$?
check "REJECT when a runtime download (the guest disk under its download name, a partial Firecracker tarball) survives" 1 "$rc" "$WORK/b-left4.log" 'STILL PRESENT: .*nitro-sandbox-guest-disk.img'
grep -q 'STILL PRESENT: .*firecracker-v1.18.0-x86_64.tgz.part' "$WORK/b-left4.log"; ok "  ... both are named" $?
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
printf 'kernel_path     = "/var/lib/nitro-sandbox-images/latest.eif"\nkubeconfig_path = "/var/lib/kubelet/kubeconfig"\nformat_overlay  = true\ncpu_overcommit  = true\npcie_slots      = 110\ndata_base_dir   = "/var/lib/nitro-sandbox"\ndebug           = false\n' > "$G/etc/containerd/nitro-sandbox.toml"
cat > "$G/usr/local/bin/mkfs.erofs" <<'SH'
#!/bin/bash
case "$1" in --version|-V) echo "mkfs.erofs ${STUB_EROFS_VERSION:-1.8.10}" ;; -zzstd,1) : > "$2" ;; *) exit 2 ;; esac
SH
chmod +x "$G/usr/local/bin/mkfs.erofs"
# Every file sources.lock installs, at its path and mode, with a test lock pinned to these bytes: the
# real lock's blocks, each install= block's sha256 replaced, and the signed-archive block pointed at a
# P-384 test key beside the test lock, whose signed manifest (listing the archive and the shim) is
# kept on the image where 30-runtime-install.sh keeps the real one. A second key signs the bad case.
openssl ecparam -name secp384r1 -genkey -noout -out "$WORK/sign.key" 2>/dev/null \
  && openssl ec -in "$WORK/sign.key" -pubout -out "$WORK/fixture-runtime-v1.pub" 2>/dev/null \
  && openssl ecparam -name secp384r1 -genkey -noout -out "$WORK/other.key" 2>/dev/null
ok "a P-384 test key pair is made with openssl" $?
"$PY" - "$SAMPLE/packages/sources.lock" "$G" "$WORK/test.lock" "$WORK" <<'PY'
import hashlib, os, re, struct, subprocess, sys
lock, root, out, work = sys.argv[1:5]
sha = lambda b: hashlib.sha256(b).hexdigest()

def eif(release):
    """A small Enclave Image File: a kernel section whose bzImage setup header names <release>."""
    k = bytearray(0x400)
    k[0x202:0x206] = b"HdrS"
    struct.pack_into("<H", k, 0x20E, 0x100)
    s = f"{release} (builder@fixture) #1 SMP".encode() + b"\0"
    k[0x300:0x300 + len(s)] = s
    secs = [(1, bytes(k)), (2, b"console=ttyS0\0")]
    offs, body, pos = [], b"", 548
    for t, d in secs:
        offs.append(pos)
        chunk = struct.pack(">HHQ", t, 0, len(d)) + d
        body += chunk
        pos += len(chunk)
    sizes = [len(d) for _, d in secs]
    head = struct.pack(">4sHHQQHH", b".eif", 4, 0, 1 << 29, 2, 0, len(secs))
    head += struct.pack(">32Q", *(offs + [0] * (32 - len(offs)))) + struct.pack(">32Q", *(sizes + [0] * (32 - len(sizes))))
    return head + struct.pack(">II", 0, 0) + body
open(f"{work}/eif-host.eif", "wb").write(eif("6.18.56-nitro-ga"))
blocks = open(lock).read().split("\n\n")
field = lambda b, k: (re.search(rf"^{k}=(.*)$", b, re.M) or [None, None])[1]
pins, signed = {}, None
for i, b in enumerate(blocks):
    bid, inst = field(b, "id"), field(b, "install")
    if field(b, "kind") == "signed-archive":
        signed = i
    if not inst or inst == "none":
        continue
    data = eif(field(b, "guest_kernel")) if field(b, "guest_kernel") else f"fixture node file {bid}\n".encode()
    pins[bid] = sha(data)
    blocks[i] = re.sub(r"^sha256=.*$", f"sha256={pins[bid]}", b, flags=re.M)
    dest, mode = inst.split()
    p = root + dest
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "wb").write(data)
    os.chmod(p, int(mode, 8))
assert signed is not None and len(pins) == 5, (signed, pins)
b = blocks[signed]
sid, archive = field(b, "id"), field(b, "file")
archive_sha = sha(b"fixture archive\n")
shim = [x for x in blocks if field(x, "kind") == "archive-member" and field(x, "archive") == sid]
man = f"{archive_sha}  {archive}\n" + "".join(f"{pins[field(x, 'id')]}  {field(x, 'member')}\n" for x in shim)
d = root + "/usr/local/share/ubuntu-ami-sample/runtime"
os.makedirs(d, exist_ok=True)
open(f"{d}/{sid}.SHA256SUM", "w").write(man)
subprocess.run(["openssl", "dgst", "-sha384", "-sign", f"{work}/sign.key", "-out", f"{d}/{sid}.SHA256SUM.sig", f"{d}/{sid}.SHA256SUM"], check=True)
pub = open(f"{work}/fixture-runtime-v1.pub", "rb").read()
for k, v in (("sha256", archive_sha), ("manifest_sha256", sha(man.encode())), ("public_key", "fixture-runtime-v1.pub"),
             ("public_key_sha256", sha(pub))):
    b = re.sub(rf"^{k}=.*$", f"{k}={v}", b, flags=re.M)
blocks[signed] = b
open(out, "w").write("\n\n".join(blocks))
PY
ok "  ... and the five node files, the signed manifest and the test lock are written" $?
ln -sfn latest-disk.img "$G/var/lib/nitro-sandbox-images/rootfs.ext4"
vi() { local r="$1" log="$2"; shift 2; env SYSROOT="$r" LOCK_FILE="$WORK/test.lock" "$@" "$PY" "$HERE/verify-image.py" > "$log" 2>&1; }
for mode in plain optimized; do
  if [ "$mode" = optimized ]; then OPT=(PYTHONOPTIMIZE=1); else OPT=(); fi
  rc=0; vi "$G" "$WORK/v-good-$mode.log" "${OPT[@]}" || rc=$?
  check "[$mode] ACCEPT the good image: every check passes" 0 "$rc" "$WORK/v-good-$mode.log" '"image_configuration": "PASS"'
  grep -q '"detail": "latest.eif boots guest kernel 6.18.56, the pinned guest_kernel"' "$WORK/v-good-$mode.log" \
    && grep -qx 'image_configuration: PASS (16 checks)' "$WORK/v-good-$mode.log"
  ok "  ... [$mode] including the guest kernel 6.18.56 read out of latest.eif, 16 checks in all" $?
  # one broken image per check: copy, break one thing, expect that check (and only a FAIL) to answer
  # name|failed check[|text the failed check's detail must contain]
  while IFS='|' read -r name failed_check detail; do
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
      bootinline) sed -i 's#^snap set kubelet-eks container-runtime-endpoint=unix:///run/nitro-sandbox/cri-proxy.sock$#snap set kubelet-eks container-runtime-endpoint=unix:///run/containerd/other.sock \# container-runtime-endpoint=unix:///run/nitro-sandbox/cri-proxy.sock#' "$b/usr/local/share/eks/bootstrap.sh" ;;
      dumppriv)   env=(STUB_DUMP_BREAK=priv) ;;
      pcie)       sed -i 's/^pcie_slots      = 110$/pcie_slots      = 1/' "$b/etc/containerd/nitro-sandbox.toml" ;;
      datadir)    sed -i 's#^data_base_dir   = "/var/lib/nitro-sandbox"$#data_base_dir   = "/wrong/data/path"#' "$b/etc/containerd/nitro-sandbox.toml" ;;
      kubeconfig) sed -i 's#^kubeconfig_path = "/var/lib/kubelet/kubeconfig"$#kubeconfig_path = "/wrong/kubeconfig"#' "$b/etc/containerd/nitro-sandbox.toml" ;;
      overlay)    sed -i 's/^format_overlay  = true$/format_overlay  = false/' "$b/etc/containerd/nitro-sandbox.toml" ;;
      stalekey)   printf 'rootfs_path     = "/var/lib/nitro-sandbox-images/rootfs.ext4"\n' >> "$b/etc/containerd/nitro-sandbox.toml" ;;
      jailermode) chmod 0644 "$b/usr/bin/jailer" ;;
      tamper)     echo tampered >> "$b/usr/sbin/containerd-shim-nitro-sandbox-v2" ;;
      eiftamper)  echo tampered >> "$b/var/lib/nitro-sandbox-images/latest.eif" ;;
      eifhost)    cp "$WORK/eif-host.eif" "$b/var/lib/nitro-sandbox-images/latest.eif" ;;
      eifnot)     printf 'not an enclave image\n' > "$b/var/lib/nitro-sandbox-images/latest.eif" ;;
      nodisk)     rm "$b/var/lib/nitro-sandbox-images/latest-disk.img" ;;
      sigbad)     openssl dgst -sha384 -sign "$WORK/other.key" -out "$b/usr/local/share/ubuntu-ami-sample/runtime/runtime-release.SHA256SUM.sig" \
                    "$b/usr/local/share/ubuntu-ami-sample/runtime/runtime-release.SHA256SUM" ;;
      mantamper)  echo "$(printf '%064d' 0)  extra" >> "$b/usr/local/share/ubuntu-ami-sample/runtime/runtime-release.SHA256SUM" ;;
      noman)      rm "$b/usr/local/share/ubuntu-ami-sample/runtime/runtime-release.SHA256SUM" ;;
      hold)       grep -vx containerd-app "$b/.held" > "$b/.held.new"; mv "$b/.held.new" "$b/.held" ;;
      containerd) env=(STUB_CONTAINERD_LINE="containerd github.com/containerd/containerd/v2 2.4.0 ") ;;
      erofs)      env=(STUB_EROFS_VERSION=1.7.1) ;;
      btf)        : > "$b/sys/kernel/btf/vmlinux" ;;
    esac
    rc=0; vi "$b" "$WORK/v-$name-$mode.log" "${OPT[@]}" "${env[@]}" || rc=$?
    check "[$mode] REJECT a broken image ($name): $failed_check fails" 1 "$rc" "$WORK/v-$name-$mode.log" "^image_configuration: FAIL \(failed: ([a-z_]+, )*$failed_check(, [a-z_]+)*\)$"
    if [ -n "$detail" ]; then grep -qF -- "$detail" "$WORK/v-$name-$mode.log"; ok "  ... [$mode] $failed_check says: $detail" $?; fi
  done <<'CASES'
kernel|host_kernel
nedev|nitro_enclaves_device
complain|apparmor
discard|runtime_wiring
dump|runtime_wiring
dropin|runtime_wiring
debug|runtime_wiring
bootinline|runtime_wiring|bootstrap.sh sets container-runtime-endpoint to 'unix:///run/containerd/other.sock'
dumppriv|runtime_wiring|dumped handler isolated-sandbox privileged_without_host_devices is False, must be true
pcie|runtime_wiring|pcie_slots is 1, must be 110
datadir|runtime_wiring|data_base_dir is '/wrong/data/path', must be '/var/lib/nitro-sandbox'
kubeconfig|runtime_wiring|kubeconfig_path is '/wrong/kubeconfig', must be '/var/lib/kubelet/kubeconfig'
overlay|runtime_wiring|format_overlay is False, must be true
stalekey|runtime_wiring|the shim config sets ['rootfs_path'], which the shim does not read
jailermode|runtime_files|/usr/bin/jailer has mode 0o644, expected 0755
tamper|runtime_files|/usr/sbin/containerd-shim-nitro-sandbox-v2 has SHA-256
eiftamper|runtime_files|/var/lib/nitro-sandbox-images/latest.eif has SHA-256
eifhost|guest_kernel|latest.eif boots guest kernel '6.18.56-nitro-ga', not the '6.18.56' sources.lock pins
eifnot|guest_kernel|latest.eif is not an Enclave Image File
nodisk|runtime_files|/var/lib/nitro-sandbox-images/latest-disk.img is not a regular file
sigbad|runtime_signature|the signature over runtime-release.SHA256SUM does not verify
mantamper|runtime_signature|runtime-release.SHA256SUM is not the manifest sources.lock pins
noman|runtime_signature|runtime-release.SHA256SUM or its .sig is missing
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
