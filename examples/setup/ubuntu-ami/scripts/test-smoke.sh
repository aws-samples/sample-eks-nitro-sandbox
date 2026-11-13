#!/usr/bin/env bash
# test-smoke.sh: runs the REAL scripts/40-smoke.sh (the Firecracker smoke stage) both ways,
# offline, against a fixture system tree (SYSROOT) in which /usr/bin/firecracker is
# scripts/testlib/fake_firecracker.py, with stub commands first on PATH. No build host, no AWS,
# no network, no root.
#
#   scripts/test-smoke.sh
#
#   1  the fake refuses what Firecracker v1.18.0's API refuses in the request shapes 40-smoke.sh
#      sends (unknown or missing top-level fields, wrong top-level types, unknown endpoints; it does
#      not check inside list or object values), and looks only inside its fixture folders
#      (FAKE_FC_ROOTS), whatever path a request names
#   2  ACCEPT: the exact PUT sequence, the /enclave and /boot-source bodies, the vsock handshake,
#      the manifest line and the stage's own cleanup; again with SHIM_DEBUG=true
#   3  REJECT: a non-2xx API answer, an early Firecracker exit, a garbled, silent or unreachable
#      agent, a missing EIF, SHIM_DEBUG=maybe, and a failed overlay disk or tap (the stage's
#      private folder is removed all the same)
#   4  BOTH WAYS: the preview-era pcie_mode /enclave field is refused, while the real body passes
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE="$(cd "$HERE/.." && pwd)"
REPO_ROOT_REAL="$(cd "$SAMPLE/../../.." && pwd)"
FAKE="$HERE/testlib/fake_firecracker.py"
mkdir -p "$REPO_ROOT_REAL/tmp"
WORK="$(mktemp -d "$REPO_ROOT_REAL/tmp/test-smoke.XXXXXX")"
SHORT=""
cleanup() { # stop any fake a broken run left behind (only processes that are the fake), then remove both folders
  local f p
  for f in "$WORK"/*/stub/fc-started.jsonl "$WORK"/self-started.jsonl; do
    [ -f "$f" ] || continue
    for p in $(sed -n 's/^{"pid": \([0-9][0-9]*\),.*/\1/p' "$f"); do
      grep -qa firecracker "/proc/$p/cmdline" 2>/dev/null && kill -9 "$p" 2>/dev/null
    done
  done
  rm -rf "$WORK" ${SHORT:+"$SHORT"}
}
trap cleanup EXIT
# 40-smoke.sh puts its API and vsock sockets in the private folder it makes as
# $TMPDIR/smoke-XXXXXX. A Unix socket path is limited to 107 bytes and the repository path is long,
# so each case's TMPDIR is a folder under this short private one in /tmp, not under WORK.
SHORT="$(mktemp -d /tmp/uas-smoke.XXXXXX)" || { echo "could not create a private folder in /tmp"; exit 1; }
unset SYSROOT SAMPLE_DIR REPO_ROOT LOG_DIR OUT_DIR RUNTIME_ARTIFACTS_DIR RUN_STATE_FILE LOCK_FILE \
  NITRO_SANDBOX_IMAGE_DIR IMAGE_MANIFEST SHIM_DEBUG \
  FAKE_FC_LOG FAKE_FC_STARTED FAKE_FC_FAIL_PATH FAKE_FC_EXIT_AFTER_START FAKE_FC_HANDSHAKE FAKE_FC_MAX_SECS

pass=0; fail=0
check() { # check <description> <expected-rc> <actual-rc> <log> [<regex the log must match>]
  local ok=0
  [[ "$3" -eq "$2" ]] || ok=1
  if [[ $ok -eq 0 && -n "${5:-}" ]]; then grep -qE -- "$5" "$4" || ok=1; fi
  if [[ $ok -eq 0 ]]; then printf '  PASS  %s (rc=%s)\n' "$1" "$3"; pass=$((pass+1))
  else printf '  FAIL  %s (expected rc=%s%s, got rc=%s)\n' "$1" "$2" "${5:+ and /$5/}" "$3"; sed 's/^/        | /' "$4" | tail -n 12; fail=$((fail+1)); fi
}
ok() { if [[ "$2" -eq 0 ]]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }

# --- stub commands ----------------------------------------------------------------------------
# curl and python3 are the real ones. STUB_LOG is the case's own log folder.
STUB="$WORK/bin"; mkdir -p "$STUB"
REAL_ID="$(command -v id)"
{ printf '#!/bin/bash\n# -u prints 0, so 40-smoke.sh does not take its sudo re-exec; anything else is the real id.\n'
  printf '[ "$#" = 1 ] && [ "$1" = -u ] && { echo 0; exit 0; }\nexec %q "$@"\n' "$REAL_ID"; } > "$STUB/id"
cat > "$STUB/sudo" <<'SH'
#!/bin/bash
# drops -E, then runs the command as this user
[ "${1:-}" = -E ] && shift
exec "$@"
SH
cat > "$STUB/ip" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${STUB_LOG:?}/ip.log"
# STUB_IP_FAIL=tuntap: `ip tuntap add` fails, as it does when the host cannot make a tap
[ "${STUB_IP_FAIL:-}" = tuntap ] && [ "${1:-}" = tuntap ] && { echo "ioctl(TUNSETIFF): Operation not permitted" >&2; exit 1; }
exit 0
SH
cat > "$STUB/sfdisk" <<'SH'
#!/bin/bash
{ printf 'args: %s\n' "$*"; printf 'target size: %s\n' "$(stat -c %s -- "${@: -1}" 2>/dev/null)"; cat; } >> "${STUB_LOG:?}/sfdisk.log"
# STUB_SFDISK_FAIL=1: writing the partition table fails
[ -n "${STUB_SFDISK_FAIL:-}" ] && { echo "sfdisk: failed to write disklabel" >&2; exit 1; }
exit 0
SH
cat > "$STUB/sleep" <<'SH'
#!/bin/bash
# Every sleep is 0.05 s whatever its argument, so the stage's 150-second agent wait (50 tries of
# sleep 3), its 0.1 s socket poll and its 2 s kill grace take seconds, not minutes.
exec /bin/sleep 0.05
SH
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"

python3 "$FAKE" --schema > "$WORK/schema.json" || { echo "  FAIL  the fake prints its schemas"; exit 1; }
BOOT_ARGS_EXPECTED="console=ttyS0 reboot=k panic=1 root=/dev/vda ro init=/sbin/nitro-sandbox-agent setup-ephemeral-storage --exec-init overlay_root=vdb rootwait net.ifnames=0 quiet"
IP_EXPECTED='link del tap-smoke
tuntap add dev tap-smoke mode tap
link set tap-smoke up
link del tap-smoke'
STAGE=usr/local/share/ubuntu-ami-sample

mkroot() { # mkroot <name>: a fresh fixture root $WORK/<name> holding a copy of the sample laid out as on the host
  local r="$WORK/$1"
  mkdir -p "$r/dev" "$r/var/lib/nitro-sandbox-images" "$r/usr/bin" "$r/etc" "$r/root" "$r/stub" "$r/$STAGE"
  mkdir -m 0700 "$SHORT/$1"
  ln -s /dev/null "$r/dev/nitro_enclaves"
  printf 'fixture enclave image file\n' > "$r/var/lib/nitro-sandbox-images/latest.eif"
  printf 'fixture guest disk\n' > "$r/var/lib/nitro-sandbox-images/latest-disk.img"
  ln -s latest-disk.img "$r/var/lib/nitro-sandbox-images/rootfs.ext4"
  cp "$FAKE" "$r/usr/bin/firecracker"; chmod 0755 "$r/usr/bin/firecracker"
  cp -a "$SAMPLE/." "$r/$STAGE/"
  rm -f "$r/$STAGE/config.env"
}
smoke() { # smoke <name> <script under the sample> [VAR=value...]: run it in root <name>; sets rc, log $WORK/<name>.log
  local n="$1" s="$2" r="$WORK/$1"; shift 2
  rc=0
  timeout 120 env SYSROOT="$r" HOME="$r/root" ISSUE10_RUN_DIR="$r/hostrun" TMPDIR="$SHORT/$n" STUB_LOG="$r/stub" \
    FAKE_FC_ROOTS="$r:$SHORT/$n" FAKE_FC_LOG="$r/stub/fc-requests.jsonl" FAKE_FC_STARTED="$r/stub/fc-started.jsonl" SHIM_DEBUG=false "$@" \
    bash "$r/$STAGE/$s" > "$WORK/$n.log" 2>&1 || rc=$?
}
fcq() { # fcq <name> <python expression> [args...]: 0 when the expression holds over the fake's request log.
        # L: every request in order; R: path -> its request; A: the extra args; S: the fake's embedded schemas
  python3 - "$WORK/$1/stub/fc-requests.jsonl" "$WORK/schema.json" "$2" "${@:3}" <<'PY'
import json, sys
L = [json.loads(line) for line in open(sys.argv[1])]
R = {d["path"]: d for d in L}
S = json.load(open(sys.argv[2]))["definitions"]
A = sys.argv[4:]
sys.exit(0 if eval(sys.argv[3]) else 1)
PY
}
manifest_is() { # manifest_is <name> <PASS|FAIL> <true|false>: the manifest holds exactly that one smoke line
  local m="$WORK/$1/etc/ubuntu-ami-sample-manifest"
  [ "$(wc -l < "$m")" = 1 ] && grep -qE "^smoke [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z: $2; debug_mode=$3\$" "$m"
}
cleaned() { # cleaned <name>: the stage's own cleanup ran
  local n="$1" pid
  pid=$(sed -n 's/^{"pid": \([0-9][0-9]*\),.*/\1/p' "$WORK/$n/stub/fc-started.jsonl" 2>/dev/null)
  [ -n "$pid" ] && [ "$(printf '%s\n' "$pid" | wc -l)" = 1 ] && ! kill -0 "$pid" 2>/dev/null
  ok "  ... cleanup: the fake Firecracker process (pid ${pid:-none}) started once and is gone" $?
  python3 - "$WORK/$n/stub/fc-started.jsonl" "$SHORT/$n" <<'PY'
import json, os, re, sys
argv = json.loads(open(sys.argv[1]).readline())["argv"]
sock = argv[argv.index("--api-sock") + 1]
d = os.path.dirname(sock)
sys.exit(0 if os.path.dirname(d) == sys.argv[2] and re.fullmatch(r"smoke-[A-Za-z0-9]{6}", os.path.basename(d)) and not os.path.exists(d) else 1)
PY
  ok "  ... cleanup: the API socket sat in the stage's own folder \$TMPDIR/smoke-XXXXXX (the name 50-bake-prep.sh removes), and that folder is gone" $?
  [ -z "$(ls -A "$SHORT/$n")" ]; ok "  ... cleanup: nothing is left in TMPDIR" $?
  [ "$(cat "$WORK/$n/stub/ip.log" 2>/dev/null)" = "$IP_EXPECTED" ]; ok "  ... cleanup: the tap was created, then deleted (ip log)" $?
}
untouched() { # untouched <name>: the stage stopped before it made or started anything
  local n="$1" s="$WORK/$1/stub"
  [ ! -e "$s/fc-started.jsonl" ] && [ ! -e "$s/fc-requests.jsonl" ]; ok "  ... the fake Firecracker never started" $?
  [ -z "$(ls -A "$SHORT/$n")" ] && [ ! -e "$s/ip.log" ] && [ ! -e "$s/sfdisk.log" ]; ok "  ... no temp folder, no overlay disk, no tap" $?
  [ ! -e "$WORK/$n/etc/ubuntu-ami-sample-manifest" ]; ok "  ... no manifest line" $?
}
ALL_PUTS=("PUT /machine-config" "PUT /boot-source" "PUT /drives/rootfs" "PUT /drives/overlay" "PUT /vsock"
          "PUT /network-interfaces/eth0" "PUT /enclave" "PUT /actions")
puts_are() { # puts_are <name> <status...>: the recorded requests are exactly ALL_PUTS, in order, answered with these statuses
  local n="$1" i want=(); shift
  for i in "${!ALL_PUTS[@]}"; do want+=("${ALL_PUTS[$i]} $1"); [ $# -gt 1 ] && shift; done
  diff <(python3 -c 'import json, sys
for line in open(sys.argv[1]):
    d = json.loads(line); print(d["method"], d["path"], d["status"])' "$WORK/$n/stub/fc-requests.jsonl") \
       <(printf '%s\n' "${want[@]}") > "$WORK/$n.puts.diff"
}

echo "== 1/4 the fake itself: Firecracker v1.18.0's API, in the shapes 40-smoke.sh sends ========"
FS="$SHORT/self"; mkdir -m 0700 "$FS"
FAKE_FC_ROOTS="$FS" FAKE_FC_LOG="$WORK/self.jsonl" FAKE_FC_STARTED="$WORK/self-started.jsonl" python3 "$FAKE" --api-sock "$FS/api.sock" --level Debug > "$WORK/self.out" 2>&1 &
fpid=$!
for _ in $(seq 1 100); do [ -S "$FS/api.sock" ] && break; /bin/sleep 0.05; done
api() { curl -s -o "$WORK/self.body" -w '%{http_code}' --unix-socket "$FS/api.sock" -X PUT "http://localhost$1" -H 'Content-Type: application/json' -d "$2"; }
answers() { # answers <description> <code> <fault regex|""> <path> <body>
  local code; code=$(api "$4" "$5")
  [ "$code" = "$2" ] && { [ -z "$3" ] || grep -qE -- "$3" "$WORK/self.body"; }
  ok "fake: $1 -> $2" $?
}
answers "an unknown /enclave field (the preview-era pcie_mode)" 400 'unknown field `pcie_mode`' /enclave '{"debug_mode":false,"pcie_mode":true}'
answers "a missing required field (/boot-source with no kernel_image_path)" 400 'missing field `kernel_image_path`' /boot-source '{"boot_args":"quiet"}'
answers "a body that is not JSON" 400 'deserializing the json body' /machine-config 'vcpu_count=2'
answers "a field of the wrong type" 400 'invalid type for `vcpu_count`' /machine-config '{"vcpu_count":"2","mem_size_mib":1024}'
answers "an unknown endpoint (/entropy, which the shim never adds)" 400 'Invalid request method and/or path: PUT /entropy' /entropy '{}'
answers "a kernel_image_path that is not a file" 400 'cannot be opened' /boot-source "{\"kernel_image_path\":\"$FS/nonexistent/latest.eif\"}"
answers "a drive whose path_on_host does not exist" 400 'backing file' /drives/rootfs "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$FS/nonexistent/rootfs.ext4\",\"is_root_device\":false,\"is_read_only\":true}"
# A path in a request is the client's choice, so the fake looks only inside FAKE_FC_ROOTS.
answers "a kernel_image_path outside its fixture folders (an absolute system path)" 400 'outside the folders this fake may look at' /boot-source '{"kernel_image_path":"/etc/hostname"}'
answers "a drive path_on_host that climbs out of its fixture folder with .." 400 'path_on_host .* is outside the folders' /drives/rootfs "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$FS/../escape.img\",\"is_root_device\":false,\"is_read_only\":true}"
answers "a vsock uds_path outside its fixture folders" 400 'uds_path .* is outside the folders' /vsock '{"guest_cid":3,"uds_path":"/tmp/fake-firecracker-escape.vsock"}'
answers "a drive whose drive_id is not the one in the path" 400 'id from the path does not match' /drives/rootfs "{\"drive_id\":\"other\",\"path_on_host\":\"$FAKE\",\"is_root_device\":false,\"is_read_only\":true}"
answers "InstanceStart before any boot source" 400 'without kernel configuration' /actions '{"action_type":"InstanceStart"}'
answers "a valid /machine-config" 204 "" /machine-config '{"vcpu_count":2,"mem_size_mib":1024}'
[ "$(wc -l < "$WORK/self.jsonl")" = 13 ] && grep -q '"path": "/entropy".*"status": 400' "$WORK/self.jsonl" && [ ! -e /tmp/fake-firecracker-escape.vsock ]
ok "fake: every request is recorded with the status it answered, and nothing was bound outside its folders" $?
kill -TERM "$fpid"; frc=0; wait "$fpid" || frc=$?
[ "$frc" = 0 ]; ok "fake: SIGTERM ends it cleanly (status $frc)" $?

echo
echo "== 2/4 ACCEPT: the real stage boots the fake and passes on the vsock handshake ============"
n=accept; mkroot "$n"; R="$WORK/$n"; IMG="$R/var/lib/nitro-sandbox-images"
smoke "$n" scripts/40-smoke.sh
check "ACCEPT: the stage passes" 0 "$rc" "$WORK/$n.log" '^smoke [0-9T:Z-]+: PASS; debug_mode=false$'
grep -qF "vsock handshake reply: 'OK 1073741824'" "$WORK/$n.log"; ok "  ... on the agent's handshake reply 'OK 1073741824'" $?
manifest_is "$n" PASS false; ok "  ... the manifest gained exactly one PASS line, debug_mode=false" $?
puts_are "$n" 204; ok "  ... the requests are exactly the eight PUTs, in the shim's order, each answered 204" $?
fcq "$n" 'R["/enclave"]["body"] == {"debug_mode": False, "direct_mode": False, "hotplug_mode": True, "cpu_overcommit": True, "cpu_accounting": False}'
ok "  ... the /enclave body is exactly the v1.18.0 one" $?
fcq "$n" 'set(R["/enclave"]["body"]) <= set(S["EnclaveConfig"]["fields"]) and "pcie_mode" not in S["EnclaveConfig"]["fields"]'
ok "  ... its keys are all fields of the embedded v1.18.0 EnclaveConfig, which has no pcie_mode" $?
fcq "$n" 'R["/boot-source"]["body"] == {"kernel_image_path": A[0], "boot_args": A[1]}' "$IMG/latest.eif" "$BOOT_ARGS_EXPECTED"
ok "  ... /boot-source boots the EIF (\$SYSROOT/var/lib/nitro-sandbox-images/latest.eif) with the shim's boot args" $?
fcq "$n" 'R["/drives/rootfs"]["body"] == {"drive_id": "rootfs", "path_on_host": A[0], "is_root_device": False, "is_read_only": True, "cache_type": "Unsafe"}' "$IMG/rootfs.ext4"
ok "  ... the rootfs drive is read-only on rootfs.ext4" $?
fcq "$n" 'R["/drives/overlay"]["body"]["is_read_only"] is False and R["/drives/overlay"]["body"]["path_on_host"].startswith(A[0] + "/smoke-") and R["/vsock"]["body"]["guest_cid"] == 3 and R["/vsock"]["body"]["uds_path"].startswith(A[0] + "/smoke-") and R["/network-interfaces/eth0"]["body"]["host_dev_name"] == "tap-smoke"' "$SHORT/$n"
ok "  ... the overlay disk is writable and, with the vsock socket, in the stage's private \$TMPDIR/smoke-XXXXXX folder; vsock guest_cid 3; eth0 on tap-smoke" $?
grep -qx 'label: gpt' "$R/stub/sfdisk.log" && grep -qF 'name="BOTTLEROCKET-DATA"' "$R/stub/sfdisk.log"
ok "  ... the overlay disk got its GPT with the BOTTLEROCKET-DATA partition (sfdisk input)" $?
cleaned "$n"

n=debug; mkroot "$n"
smoke "$n" scripts/40-smoke.sh SHIM_DEBUG=true
check "ACCEPT with SHIM_DEBUG=true" 0 "$rc" "$WORK/$n.log" '^smoke [0-9T:Z-]+: PASS; debug_mode=true$'
fcq "$n" 'R["/enclave"]["body"] == {"debug_mode": True, "direct_mode": False, "hotplug_mode": True, "cpu_overcommit": True, "cpu_accounting": False}'
ok "  ... /enclave asks for debug_mode true" $?
manifest_is "$n" PASS true; ok "  ... the manifest line says debug_mode=true" $?
cleaned "$n"

echo
echo "== 3/4 REJECT ================================================================================"
n=apifail; mkroot "$n"
smoke "$n" scripts/40-smoke.sh FAKE_FC_FAIL_PATH=/enclave
check "REJECT a non-2xx API answer (400 to PUT /enclave)" 1 "$rc" "$WORK/$n.log" '^PUT /enclave -> 400 .*fault_message'
puts_are "$n" 204 204 204 204 204 204 400 204
ok "  ... the stage still sends PUT /actions after the failed PUT (the fake answers it 204)" $?
! grep -q 'vsock handshake' "$WORK/$n.log" && grep -qx -- '--- process alive: yes; agent reachable: 0 after 0s' "$WORK/$n.log"
ok "  ... but tries no handshake: a failed PUT alone fails the stage" $?
manifest_is "$n" FAIL false; ok "  ... the manifest line says FAIL" $?
cleaned "$n"

n=early; mkroot "$n"
smoke "$n" scripts/40-smoke.sh FAKE_FC_EXIT_AFTER_START=1
check "REJECT Firecracker exiting right after InstanceStart" 1 "$rc" "$WORK/$n.log" '^firecracker exited early$'
grep -q -- '^--- process alive: NO; agent reachable: 0' "$WORK/$n.log"; ok "  ... the stage reports the process gone and the agent unreached" $?
manifest_is "$n" FAIL false; ok "  ... the manifest line says FAIL" $?
cleaned "$n"

for hs in garbled silent none; do
  case "$hs" in
    garbled) what="a garbled handshake reply"; says="vsock handshake reply: 'garbled'" ;;
    silent)  what="an agent that accepts and closes without a reply"; says="vsock handshake reply: ''" ;;
    none)    what="an unreachable agent (no vsock socket)"; says="vsock handshake: [Errno 2] No such file or directory" ;;
  esac
  n="hs-$hs"; mkroot "$n"
  smoke "$n" scripts/40-smoke.sh FAKE_FC_HANDSHAKE="$hs"
  check "REJECT $what" 1 "$rc" "$WORK/$n.log" '^--- process alive: yes; agent reachable: 0 after 150s$'
  grep -qF -- "$says" "$WORK/$n.log"; ok "  ... the last try says: $says" $?
  puts_are "$n" 204; ok "  ... every PUT was answered 204 (the handshake alone fails it)" $?
  manifest_is "$n" FAIL false; ok "  ... the manifest line says FAIL" $?
  cleaned "$n"
done

n=noeif; mkroot "$n"; rm "$WORK/$n/var/lib/nitro-sandbox-images/latest.eif"
smoke "$n" scripts/40-smoke.sh
check "REJECT a missing EIF (precondition)" 2 "$rc" "$WORK/$n.log" '^SMOKE PRECONDITION FAIL$'
untouched "$n"

n=badflag; mkroot "$n"
smoke "$n" scripts/40-smoke.sh SHIM_DEBUG=maybe
check "REJECT SHIM_DEBUG=maybe (precondition)" 2 "$rc" "$WORK/$n.log" 'SMOKE PRECONDITION FAIL: SHIM_DEBUG must be true or false'
untouched "$n"

# Review R2c MUST-FIX 2: a failure after the stage made its private folder (the overlay disk's
# partition table, or the tap) must still remove that folder and the 2 GiB sparse overlay in it.
early() { # early <name>: the stage stopped after making its folder, before Firecracker started, and left nothing
  local n="$1" s="$WORK/$1/stub"
  [ ! -e "$s/fc-started.jsonl" ] && [ ! -e "$s/fc-requests.jsonl" ]; ok "  ... the fake Firecracker never started" $?
  grep -qE "^args: -q $SHORT/$n/smoke-[A-Za-z0-9]{6}/smoke.overlay.img\$" "$s/sfdisk.log" && grep -qx 'target size: 2147483648' "$s/sfdisk.log"
  ok "  ... the stage had made its 2 GiB sparse overlay disk in \$TMPDIR/smoke-XXXXXX (sfdisk saw it)" $?
  [ -z "$(find "$SHORT/$n" -mindepth 1 -maxdepth 1 -name 'smoke-*' -print)" ] && [ -z "$(ls -A "$SHORT/$n")" ]
  ok "  ... no smoke-* folder and nothing else is left in TMPDIR" $?
  [ ! -e "$WORK/$n/etc/ubuntu-ami-sample-manifest" ]; ok "  ... no manifest line" $?
}
n=overlayfail; mkroot "$n"
smoke "$n" scripts/40-smoke.sh STUB_SFDISK_FAIL=1
check "REJECT a failed overlay disk (sfdisk cannot write its partition table)" 1 "$rc" "$WORK/$n.log" '^overlay disk creation failed$'
early "$n"
[ ! -e "$WORK/$n/stub/ip.log" ]; ok "  ... and no tap was tried, so none is deleted" $?
n=tapfail; mkroot "$n"
smoke "$n" scripts/40-smoke.sh STUB_IP_FAIL=tuntap
check "REJECT a failed tap (ip tuntap add fails)" 1 "$rc" "$WORK/$n.log" '^tap creation failed$'
early "$n"
[ "$(cat "$WORK/$n/stub/ip.log" 2>/dev/null)" = "$(printf 'link del tap-smoke\ntuntap add dev tap-smoke mode tap\nlink del tap-smoke')" ]
ok "  ... and the clean up deleted the tap name it tried to make (ip log)" $?

echo
echo "== 4/4 BOTH WAYS: the fake would have caught the R1 pcie_mode regression ===================="
n=pcie; mkroot "$n"
sed '/^ENCLAVE_CFG=/s/,\\"direct_mode\\":false/,\\"pcie_mode\\":true,\\"direct_mode\\":false/' \
  "$WORK/$n/$STAGE/scripts/40-smoke.sh" > "$WORK/$n/$STAGE/scripts/40-smoke-pcie.sh"
grep -qF 'ENCLAVE_CFG="{\"debug_mode\":${SHIM_DEBUG},\"pcie_mode\":true,\"direct_mode\":false,' "$WORK/$n/$STAGE/scripts/40-smoke-pcie.sh" \
  && [ "$(diff "$WORK/$n/$STAGE/scripts/40-smoke.sh" "$WORK/$n/$STAGE/scripts/40-smoke-pcie.sh" | grep -c '^[<>]')" = 2 ]
ok "a scratch copy of the stage differs only in its /enclave body, which has pcie_mode back" $?
smoke "$n" scripts/40-smoke-pcie.sh
check "REJECT that copy: the fake answers PUT /enclave 400 and the stage fails" 1 "$rc" "$WORK/$n.log" '^PUT /enclave -> 400 .*unknown field `pcie_mode`'
fcq "$n" 'R["/enclave"]["status"] == 400 and R["/enclave"]["body"].get("pcie_mode") is True'; ok "  ... the fake recorded the refused pcie_mode body" $?
manifest_is "$n" FAIL false; ok "  ... the manifest line says FAIL" $?
cleaned "$n"
n=pcie-real; mkroot "$n"
smoke "$n" scripts/40-smoke.sh
check "ACCEPT the real stage in the same setup" 0 "$rc" "$WORK/$n.log" '^PUT /enclave -> 204 $'
fcq "$n" 'R["/enclave"]["status"] == 204'; ok "  ... the fake answered its /enclave 204" $?

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "scripts/40-smoke.sh proven both ways against the fake Firecracker v1.18.0 API."
