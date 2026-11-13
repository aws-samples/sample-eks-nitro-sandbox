#!/usr/bin/env bash
# test-inputs.sh: proves the input checks both ways, in the REAL scripts, with no AWS and no
# network reached:
#   packages/fetch-runtime-artifacts.sh  (the signed runtime release, the guest image pair and
#                                         Firecracker, in --check mode and in full)
#   packages/fetch-kernel-patch.sh       (the Amazon Linux sandbox patch as a .patch)
#
#   packages/test-inputs.sh
#   REAL_RUNTIME_DL=<folder> packages/test-inputs.sh
#       also runs the REAL packages/sources.lock against real copies of the runtime inputs: a
#       folder holding each file under the name at the end of its URL (nitro-sandboxes-runtime.tar.gz,
#       SHA256SUM, SHA256SUM.sig, nitro-sandbox-guest.eif and .sha256, nitro-sandbox-guest-disk.img
#       and .sha256, firecracker-v1.18.0-x86_64.tgz and .sha256.txt), served through file:// URLs
#
# The fixtures are scripts/testlib/fixture_inputs.py: small files in the real shapes, a runtime
# release signed with a P-384 test key made per case, and a test lock in the real file's shape, so
# the check a case is about is the one that answers. curl is real (file:// URLs). For the patch,
# curl is a stub first on PATH that copies a local file to curl's -o target, so
# fetch-kernel-patch.sh runs unchanged. The real pinned patch, when it is cached under the
# repository's tmp/ (setup.sh --prepare or fetch-kernel-patch.sh leaves it there), is also run
# against the REAL packages/sources.lock, accepted, and refused tampered.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR_REAL="$(cd "$HERE/.." && pwd)"
REPO_ROOT_REAL="$(cd "$SAMPLE_DIR_REAL/../../.." && pwd)"
mkdir -p "$REPO_ROOT_REAL/tmp"
WORK="$(mktemp -d "$REPO_ROOT_REAL/tmp/test-inputs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export ISSUE10_RUN_DIR="$WORK/run"

pass=0; fail=0; skip=0
check() { # check <description> <expected-rc> <actual-rc> <log> [<regex the log must match>]
  local ok=0
  [[ "$3" -eq "$2" ]] || ok=1
  if [[ $ok -eq 0 && -n "${5:-}" ]]; then grep -qE -- "$5" "$4" || ok=1; fi
  if [[ $ok -eq 0 ]]; then printf '  PASS  %s (rc=%s)\n' "$1" "$3"; pass=$((pass+1))
  else printf '  FAIL  %s (expected rc=%s%s, got rc=%s)\n' "$1" "$2" "${5:+ and /$5/}" "$3"; sed 's/^/        | /' "$4" | tail -n 8; fail=$((fail+1)); fi
}
sha() { sha256sum "$1" | awk '{print $1}'; }

# rt <case> <check|fetch> : make the case's fixtures, then run the REAL fetch-runtime-artifacts.sh
# on them; its log is $WORK/<case>-<mode>.log and its output folder $WORK/<case>/out.
rt() {
  local c="$1" mode="$2"
  mkdir -p "$WORK/$c/fx" "$ISSUE10_RUN_DIR"
  [ -s "$WORK/$c/fixture.lock" ] || python3 "$SAMPLE_DIR_REAL/scripts/testlib/fixture_inputs.py" "$WORK/$c/fx" "$WORK/$c/fixture.lock" "$c" \
    || { echo "fixture_inputs.py failed for $c" > "$WORK/$c-$mode.log"; return 99; }
  if [ "$mode" = check ]; then
    LOCK_FILE="$WORK/$c/fixture.lock" RUNTIME_ARTIFACTS_DIR="$WORK/$c/out" bash "$HERE/fetch-runtime-artifacts.sh" --check > "$WORK/$c-$mode.log" 2>&1
  else
    LOCK_FILE="$WORK/$c/fixture.lock" RUNTIME_ARTIFACTS_DIR="$WORK/$c/out" bash "$HERE/fetch-runtime-artifacts.sh" > "$WORK/$c-$mode.log" 2>&1
  fi
}
# no_partial <case>: nothing but whole, verified files in node-files (no .part file left behind)
no_partial() { [ -z "$(find "$WORK/$1/out" -name '*.part' 2>/dev/null)" ]; }

echo "== 1/3 runtime inputs: packages/fetch-runtime-artifacts.sh ============================="
rc=0; rt good check || rc=$?
check "ACCEPT --check on a good set: key pin, manifest pin, signature, manifest lines and the three sidecars" 0 "$rc" "$WORK/good-check.log" \
  'runtime inputs checked against sources.lock with no large download: 4 published inputs'
rc=0; rt good fetch || rc=$?
check "ACCEPT the full fetch of a good set: every download and every member matches its pin" 0 "$rc" "$WORK/good-fetch.log" \
  'runtime inputs verified against sources.lock: 5 node files in '
[ "$(ls "$WORK/good/out/node-files" | tr '\n' ' ')" = "firecracker guest-image-disk guest-image-eif jailer runtime-shim " ] \
  && cmp -s "$WORK/good/out/node-files/runtime-shim" <(printf 'fixture shim\n') \
  && cmp -s "$WORK/good/out/node-files/jailer" <(printf 'fixture jailer\n') \
  && cmp -s "$WORK/good/out/signed-manifest/runtime-release.SHA256SUM" "$WORK/good/fx/SHA256SUM" \
  && [ "$(tail -n 1 "$WORK/good-fetch.log")" = "$WORK/good/out/node-files" ]
check "  ... node-files holds exactly the five installable files, named by block id, the signed manifest is kept, and the last line names node-files" 0 $? "$WORK/good-fetch.log"
rc=0; rt check-only check || rc=$?
check "ACCEPT --check when none of the large files can be downloaded (it downloads none of them)" 0 "$rc" "$WORK/check-only-check.log" 'with no large download'
rc=0; rt check-only fetch || rc=$?
check "REJECT the full fetch of that same set: the archive cannot be downloaded" 1 "$rc" "$WORK/check-only-fetch.log" 'could not download file://.*absent-runtime.tar.gz'
while IFS='|' read -r c mode rx why; do
  [ -n "$c" ] || continue
  rc=0; rt "$c" "$mode" || rc=$?
  check "$why" 1 "$rc" "$WORK/$c-$mode.log" "$rx"
  if [ "$mode" = fetch ]; then no_partial "$c"; check "  ... and no .part file is left behind ($c)" 0 $? "$WORK/$c-$mode.log"; fi
done <<'CASES'
wrong-key|check|the public key fixture-runtime-v1.pub has SHA-256 [0-9a-f]{64}, not the|REJECT a public key that is not the one sources.lock pins
bad-sig|check|signature over .* does not verify with fixture-runtime-v1.pub|REJECT a manifest signed with another key (a bad signature)
manifest-changed|check|signature over .* does not verify|REJECT a manifest changed after it was signed, even with its pin changed to match
manifest-pin|check|the manifest file://.* has SHA-256 [0-9a-f]{64}, not the|REJECT a signed manifest that is not the one sources.lock pins
manifest-no-shim|check|the signed manifest lists fx-shim as <absent>|REJECT a signed manifest that does not list the shim
manifest-bad-line|check|has a line that is not '<sha256>  <file name>': 'not a manifest line'|REJECT a signed manifest with a malformed line
sidecar-mismatch|check|sidecar .*guest.eif.sha256 says [0-9a-f]{64}, not the|REJECT a guest image sidecar that disagrees with the pin
sidecar-garbled|check|sidecar .*guest.eif.sha256 does not start with a SHA-256|REJECT a sidecar that is not a SHA-256 (an error page)
archive-swapped|fetch|runtime.tar.gz from file://.* has SHA-256 [0-9a-f]{64}, not the|REJECT a runtime archive that is not the one the signed manifest lists (wrong hash)
not-a-tar|fetch|runtime.tar.gz is not a readable gzip tar|REJECT a runtime archive that is not a gzip tar
member-path|fetch|runtime.tar.gz has members that are not regular files with flat names: \['sub/evil'\]|REJECT a runtime archive member with a path, before anything is read out
member-dup|fetch|runtime.tar.gz has more than one member named: \['fx-agent'\]|REJECT a runtime archive with two members of the same name
member-link|fetch|runtime.tar.gz has members that are not regular files with flat names: \['fx-link'\]|REJECT a runtime archive member that is a symbolic link
shim-tampered|fetch|fx-shim in runtime.tar.gz has SHA-256 [0-9a-f]{64}, not the [0-9a-f]{64} sources.lock pins for runtime-shim|REJECT a shim that is not its pin, in an archive the signed manifest lists
file-mismatch|fetch|guest.eif from file://.* has SHA-256 [0-9a-f]{64}, not the|REJECT a guest image file that disagrees with its pin (its sidecar agrees)
fc-traversal|fetch|firecracker-fx.tgz has members that are not regular files or folders inside it: \['release-fx/../../escaped'\]|REJECT a Firecracker tarball member that climbs out with ..
fc-absolute|fetch|firecracker-fx.tgz has members that are not regular files or folders inside it: \['/etc/escaped'\]|REJECT a Firecracker tarball member with an absolute path
fc-link|fetch|firecracker-fx.tgz has members that are not regular files or folders inside it: \['release-fx/link'\]|REJECT a Firecracker tarball member that is a hard link
fc-missing-member|fetch|firecracker-fx.tgz has no regular file release-fx/jailer-fx \(sources.lock block jailer\)|REJECT a Firecracker tarball without the jailer
fc-jailer-tampered|fetch|release-fx/jailer-fx in firecracker-fx.tgz has SHA-256 [0-9a-f]{64}, not the [0-9a-f]{64} sources.lock pins for jailer|REJECT a jailer that is not its pin
download-fails|fetch|could not download file://.*missing.tar.gz|REJECT when a download fails
CASES
[ ! -e "$WORK/escaped" ] && [ ! -e "$WORK/fc-traversal/escaped" ] && [ ! -e "$WORK/fc-traversal/out/escaped" ]
check "  ... no refused member was written anywhere" 0 $? "$WORK/fc-traversal-fetch.log"
[ ! -e "$WORK/shim-tampered/out/node-files/runtime-shim" ] && [ ! -e "$WORK/fc-jailer-tampered/out/node-files/jailer" ]
check "  ... and a member that fails its pin never reaches node-files" 0 $? "$WORK/shim-tampered-fetch.log"
rc=0; LOCK_FILE="$WORK/good/fixture.lock" RUNTIME_ARTIFACTS_DIR="$WORK/good/out" bash "$HERE/fetch-runtime-artifacts.sh" --checkk > "$WORK/badarg.log" 2>&1 || rc=$?
check "REJECT an unknown option" 1 "$rc" "$WORK/badarg.log" 'unknown argument: --checkk'

echo
echo "== 2/3 the real pins: packages/sources.lock against real copies of the runtime inputs ======"
if [[ -n "${REAL_RUNTIME_DL:-}" ]]; then
  # The real lock with every URL served from REAL_RUNTIME_DL, and the real public key beside it.
  mkdir -p "$WORK/real" && cp -- "$HERE/nitro-sandboxes-runtime-v1.pub" "$WORK/real/"
  python3 - "$HERE/sources.lock" "$REAL_RUNTIME_DL" "$WORK/real/sources.lock" <<'PY'
import os, re, sys
lock, dl, out = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3]
text = open(lock).read()
text = re.sub(r"^(source|manifest|signature|sidecar)=https://\S+/([^/\s]+)$",
              lambda m: f"{m.group(1)}=file://{dl}/{m.group(2)}", text, flags=re.M)
open(out, "w").write(text)
PY
  real() { LOCK_FILE="$WORK/real/sources.lock" RUNTIME_ARTIFACTS_DIR="$WORK/real/out" bash "$HERE/fetch-runtime-artifacts.sh" "$@"; }
  rc=0; real > "$WORK/real.log" 2>&1 || rc=$?
  check "ACCEPT the real runtime release, guest image pair and Firecracker against the REAL packages/sources.lock pins and key" 0 "$rc" "$WORK/real.log" \
    'runtime-release 0\.1\.4274\.0: signature Verified OK with nitro-sandboxes-runtime-v1\.pub.*'
  grep -q 'runtime inputs verified against sources.lock: 5 node files' "$WORK/real.log"
  check "  ... and it read out the five node files" 0 $? "$WORK/real.log"
  # The guest kernel release inside the real EIF, read the way verify-image.py reads the staged copy.
  want_gk="$(sed -n '/^id=guest-image-eif$/,/^$/s/^guest_kernel=//p' "$HERE/sources.lock")"
  python3 "$SAMPLE_DIR_REAL/scripts/lib/image_checks.py" eif-kernel "$WORK/real/out/node-files/guest-image-eif" > "$WORK/real-eif.log" 2>&1
  rc=$?; [ "$rc" = 0 ] && [ -n "$want_gk" ] && [ "$(cat "$WORK/real-eif.log")" = "$want_gk" ]
  check "ACCEPT the real guest EIF: the release its bzImage header names is the pinned guest_kernel ($want_gk)" 0 $? "$WORK/real-eif.log"
  # One byte changed in a copy of the real runtime archive: the full fetch refuses it.
  mkdir -p "$WORK/real-t/dl"; cp -- "$HERE/nitro-sandboxes-runtime-v1.pub" "$WORK/real-t/"
  DL_ABS="$(cd "$REAL_RUNTIME_DL" && pwd)"
  for f in "$DL_ABS"/*; do [ "$(basename "$f")" = nitro-sandboxes-runtime.tar.gz ] || ln -s "$f" "$WORK/real-t/dl/$(basename "$f")"; done
  python3 -c 'import sys; b=bytearray(open(sys.argv[1],"rb").read()); b[len(b)//2]^=1; open(sys.argv[2],"wb").write(b)' \
    "$DL_ABS/nitro-sandboxes-runtime.tar.gz" "$WORK/real-t/dl/nitro-sandboxes-runtime.tar.gz"
  sed "s#file://$DL_ABS/#file://$WORK/real-t/dl/#" "$WORK/real/sources.lock" > "$WORK/real-t/sources.lock"
  rc=0; LOCK_FILE="$WORK/real-t/sources.lock" RUNTIME_ARTIFACTS_DIR="$WORK/real-t/out" bash "$HERE/fetch-runtime-artifacts.sh" > "$WORK/real-t.log" 2>&1 || rc=$?
  check "REJECT the real runtime archive with one byte changed, against the REAL pins" 1 "$rc" "$WORK/real-t.log" \
    'nitro-sandboxes-runtime.tar.gz from file://.* has SHA-256 [0-9a-f]{64}, not the abc1d003'
else
  echo "  SKIP  the real runtime inputs (set REAL_RUNTIME_DL to a folder of real copies to run them)"; skip=$((skip+1))
fi

echo
echo "== 3/3 host-kernel patch: packages/fetch-kernel-patch.sh =============================="
STUB="$WORK/bin"; mkdir -p "$STUB"
# Stub curl: copy $STUB_CURL_FROM to the -o target; fail like curl -f when it is unset.
cat > "$STUB/curl" <<'SH'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "${STUB_CURL_FROM:-}" ] && [ -n "$out" ] || { echo "stub curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cp -- "$STUB_CURL_FROM" "$out"
SH
chmod +x "$STUB/curl"
COMMIT=0123456789abcdef0123456789abcdef01234567
printf 'From %s Mon Sep 17 00:00:00 2001\nSubject: [PATCH] fixture\n\nbody\n' "$COMMIT" > "$WORK/good.patch"
printf 'From %s Mon Sep 17 00:00:00 2001\nSubject: [PATCH] fixture\n\nbody!\n' "$COMMIT" > "$WORK/tampered.patch"
printf 'From %s Mon Sep 17 00:00:00 2001\nSubject: [PATCH] fixture\n\nbody\n' "fedcba9876543210fedcba9876543210fedcba98" > "$WORK/othercommit.patch"
plock() { # plock <file> <sha256> : a test lock with one host-kernel-patch block
  printf 'id=host-kernel-patch\nkind=file\nref=%s\nfile=%s.patch\nsource=https://example.invalid/%s.patch\nsha256=%s\nsubject=fixture\nstatus=available\n' \
    "$COMMIT" "$COMMIT" "$COMMIT" "$2" > "$1"
}
run_patch() { # run_patch <case> <lock> <serve-file> [extra env]
  mkdir -p "$WORK/p-$1"
  env PATH="$STUB:$PATH" LOCK_FILE="$2" STUB_CURL_FROM="$3" RUNTIME_ARTIFACTS_DIR="$WORK/p-$1" \
    bash "$HERE/fetch-kernel-patch.sh" "$WORK/p-$1" > "$WORK/p-$1.log" 2>&1
}
plock "$WORK/patch.lock" "$(sha "$WORK/good.patch")"
rc=0; run_patch good "$WORK/patch.lock" "$WORK/good.patch" || rc=$?
check "ACCEPT a patch on its pinned SHA-256 whose From line names the pinned commit" 0 "$rc" "$WORK/p-good.log" "verified sha256 .*$COMMIT.patch"
rc=0; run_patch tampered "$WORK/patch.lock" "$WORK/tampered.patch" || rc=$?
check "REJECT a tampered patch (SHA-256 mismatch)" 1 "$rc" "$WORK/p-tampered.log" 'failed its checks: SHA-256 mismatch'
[[ ! -e "$WORK/p-tampered/$COMMIT.patch" && ! -e "$WORK/p-tampered/$COMMIT.patch.part" ]]
check "REJECT leaves no patch under the final name and no .part file" 0 $? "$WORK/p-tampered.log"
plock "$WORK/patch-other.lock" "$(sha "$WORK/othercommit.patch")"
rc=0; run_patch other "$WORK/patch-other.lock" "$WORK/othercommit.patch" || rc=$?
check "REJECT a patch on its pinned SHA-256 whose From line names a different commit" 1 "$rc" "$WORK/p-other.log" "does not start with git's 'From $COMMIT' header"
rc=0; run_patch nofetch "$WORK/patch.lock" "" || rc=$?
check "REJECT when the download fails (no file is left to apply)" 1 "$rc" "$WORK/p-nofetch.log" 'could not download'
# A copy already under the final name goes through the same two checks (M10). curl serves nothing
# in these cases unless a case says so, so a cache hit cannot be confused with a download.
cached() { mkdir -p "$WORK/p-$1"; cp -- "$2" "$WORK/p-$1/$COMMIT.patch"; }
cached cache-good "$WORK/good.patch"
rc=0; run_patch cache-good "$WORK/patch.lock" "" || rc=$?
check "ACCEPT a cached patch on its pinned SHA-256 whose From line names the pinned commit" 0 "$rc" "$WORK/p-cache-good.log" "cached and verified \(SHA-256 and From $COMMIT\)"
cached cache-other "$WORK/othercommit.patch"
rc=0; run_patch cache-other "$WORK/patch-other.lock" "" || rc=$?
check "REJECT a cached patch on its pinned SHA-256 whose From line names a different commit (the reviewer's probe)" 1 "$rc" "$WORK/p-cache-other.log" "cached $COMMIT.patch failed its checks and was removed: the patch does not start with git's 'From $COMMIT' header"
[[ ! -e "$WORK/p-cache-other/$COMMIT.patch" ]]
check "  ... and it is no longer under the final name for 10-kernel.sh" 0 $? "$WORK/p-cache-other.log"
cached cache-tampered "$WORK/tampered.patch"
rc=0; run_patch cache-tampered "$WORK/patch.lock" "$WORK/good.patch" || rc=$?
check "ACCEPT a re-download when the cached copy fails its SHA-256 (the cached copy is replaced)" 0 "$rc" "$WORK/p-cache-tampered.log" 'failed its checks and was removed: SHA-256 mismatch'
cmp -s "$WORK/p-cache-tampered/$COMMIT.patch" "$WORK/good.patch"
check "  ... and the file under the final name is now the verified download" 0 $? "$WORK/p-cache-tampered.log"

REAL_PATCH="${REAL_KERNEL_PATCH:-$REPO_ROOT_REAL/tmp/issue10/run/runtime/$(sed -n 's/^file=//p' "$HERE/sources.lock" | grep '\.patch$' | head -n 1)}"
REAL_COMMIT="$(sed -n '/^id=host-kernel-patch$/,/^$/s/^ref=//p' "$HERE/sources.lock")"
if [[ -s "$REAL_PATCH" ]]; then
  cp -- "$REAL_PATCH" "$WORK/real.patch"
  python3 -c 'import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); b[-2]^=1; open(sys.argv[2],"wb").write(b)' "$WORK/real.patch" "$WORK/real-tampered.patch"
  rc=0; run_patch real "$HERE/sources.lock" "$WORK/real.patch" || rc=$?
  check "ACCEPT the real cached patch against the REAL packages/sources.lock pin" 0 "$rc" "$WORK/p-real.log" "verified sha256 .*$REAL_COMMIT"
  rc=0; run_patch real-tampered "$HERE/sources.lock" "$WORK/real-tampered.patch" || rc=$?
  check "REJECT the real patch with one byte changed against the REAL pin" 1 "$rc" "$WORK/p-real-tampered.log" 'failed its checks: SHA-256 mismatch'
else
  echo "  SKIP  the real pinned patch (not cached at $REAL_PATCH; run packages/fetch-kernel-patch.sh first)"; skip=$((skip+1))
fi

echo
printf 'passed %d, failed %d, skipped %d\n' "$pass" "$fail" "$skip"
[[ "$fail" -eq 0 ]] || exit 1
echo "runtime input and host-kernel patch checks proven both ways in the real scripts."
