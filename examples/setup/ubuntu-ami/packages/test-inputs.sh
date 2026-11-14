#!/usr/bin/env bash
# test-inputs.sh: proves the input checks both ways, in the REAL scripts, with no AWS and no
# network reached:
#   packages/fetch-runtime-artifacts.sh  (the signed runtime release, the guest image pair and
#                                         Firecracker, in --check mode and in full, and the
#                                         destination folder it may use)
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
# A reader's own config.env (in the sample folder or ~/ubuntu-ami/) must not change what this suite
# tests: scripts/lib/common.sh skips it while this test hook is set.
export UBUNTU_AMI_TESTS_IGNORE_CONFIG_ENV=1
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

echo "== 1/4 runtime inputs: packages/fetch-runtime-artifacts.sh ============================="
rc=0; rt good check || rc=$?
check "ACCEPT --check on a good set: key pin, manifest pin, signature, manifest lines and the three sidecars" 0 "$rc" "$WORK/good-check.log" \
  'runtime inputs checked against sources.lock with no large download: 4 published inputs'
rc=0; rt good fetch || rc=$?
check "ACCEPT the full fetch of a good set: every download and every member matches its pin" 0 "$rc" "$WORK/good-fetch.log" \
  'runtime inputs verified against sources.lock: 5 node files in '
[ "$(ls "$WORK/good/out/node-files" | tr '\n' ' ')" = "firecracker guest-image-disk guest-image-eif jailer runtime-shim " ] \
  && [ "$(sha "$WORK/good/out/node-files/runtime-shim")" = "$(sed -n '/^id=runtime-shim$/,/^$/s/^sha256=//p' "$WORK/good/fixture.lock")" ] \
  && cmp -s "$WORK/good/out/node-files/jailer" <(printf 'fixture jailer\n') \
  && cmp -s "$WORK/good/out/signed-manifest/runtime-release.SHA256SUM" "$WORK/good/fx/SHA256SUM" \
  && [ "$(tail -n 1 "$WORK/good-fetch.log")" = "$WORK/good/out/node-files" ]
check "  ... node-files holds exactly the five installable files, named by block id, the signed manifest is kept, and the last line names node-files" 0 $? "$WORK/good-fetch.log"
rc=0; rt check-only check || rc=$?
check "ACCEPT --check when none of the large files can be downloaded (it downloads none of them)" 0 "$rc" "$WORK/check-only-check.log" 'with no large download'
rc=0; rt sidecar-hash-only check || rc=$?
check "ACCEPT a sidecar that holds only the SHA-256, on one line" 0 "$rc" "$WORK/sidecar-hash-only-check.log" 'guest-image-eif fixture/amd64: its published sidecar matches the pin'
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
sidecar-garbled|check|sidecar .*guest.eif.sha256 is not one line holding a SHA-256 and at most a file name|REJECT a sidecar that is not a SHA-256 (an error page)
sidecar-extra-line|check|sidecar .*guest.eif.sha256 is not one line holding a SHA-256 and at most a file name: '[0-9a-f]{64} guest.eif\\nnot a|REJECT a sidecar whose first line is the right SHA-256 but which has a second, malformed line (review LOW 1)
sidecar-other-name|check|sidecar .*guest.eif.sha256 names 'other.eif', not 'guest.eif'|REJECT a sidecar with the right SHA-256 that names another file
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
echo "== 2/4 the destination folder: fetch-runtime-artifacts.sh <dest> (review MUST-FIX 1) ========"
# A positional destination is not RUNTIME_ARTIFACTS_DIR, so scripts/lib/common.sh's path guard never
# sees it. The script must refuse a link, and a folder that is not empty and that it did not make,
# before it creates or removes anything; it may replace only the folders it made itself, for this
# destination; and once it has checked the folder it must never act through the folder's path again.
# Every case uses the good fixture set. tree_sum lists every path under a folder with its type, link
# target and content hash, so a refusal is shown to have changed nothing.
D="$WORK/dest"; mkdir -p "$D"
tree_sum() { (cd "$1" && find . -printf '%y %p %l\n' | sort && find . -type f -exec sha256sum {} + | sort); }
pd() { # pd <log> <dest> [VAR=value...]: the REAL full fetch of the good set into <dest>
  local log="$1" dest="$2"; shift 2
  env LOCK_FILE="$WORK/good/fixture.lock" RUNTIME_ARTIFACTS_DIR="$WORK/good/out" "$@" \
    bash "$HERE/fetch-runtime-artifacts.sh" "$dest" > "$log" 2>&1
}
made() { local d; [ -f "$1/.fetch-runtime-artifacts" ] || return 1
  for d in downloads node-files signed-manifest; do [ -f "$1/$d/.made-by-fetch-runtime-artifacts" ] || return 1; done; }
# The review's probe, as it ran it: a folder outside the run folder that already holds
# downloads/, node-files/ and signed-manifest/ with a sentinel file each, and a curl that fails.
P="$D/probe"; mkdir -p "$P/downloads" "$P/node-files" "$P/signed-manifest"
for d in downloads node-files signed-manifest; do printf 'sentinel %s\n' "$d" > "$P/$d/keep.txt"; done
before="$(tree_sum "$P")"
NC="$WORK/bin-nocurl"; mkdir -p "$NC"
printf '#!/bin/bash\necho called >> "%s/curl-calls"\necho "stub curl refusal" >&2\nexit 77\n' "$NC" > "$NC/curl"; chmod +x "$NC/curl"
rc=0; pd "$WORK/d-probe.log" "$P" PATH="$NC:$PATH" || rc=$?
check "REJECT the review's probe: a destination outside the run folder holding downloads/, node-files/ and signed-manifest/keep.txt, with a failing curl" 1 "$rc" "$WORK/d-probe.log" \
  "the destination $P is not empty and has no .fetch-runtime-artifacts marker, so this helper did not make it"
[ "$(tree_sum "$P")" = "$before" ] && [ ! -e "$NC/curl-calls" ]
check "  ... every sentinel byte-unchanged, nothing added or removed, and curl never called" 0 $? "$WORK/d-probe.log"
rc=0; pd "$WORK/d-probe2.log" "$P" || rc=$?
check "REJECT that same folder when every download would succeed (refused for what it is, before any download)" 1 "$rc" "$WORK/d-probe2.log" 'is not empty and has no .fetch-runtime-artifacts marker'
[ "$(tree_sum "$P")" = "$before" ]; check "  ... and it is still byte-unchanged" 0 $? "$WORK/d-probe2.log"
N="$D/new/sub"; rc=0; pd "$WORK/d-new.log" "$N" || rc=$?
check "ACCEPT a destination that does not exist yet: made, with its marker and one marker in each folder it made" 0 "$rc" "$WORK/d-new.log" \
  "runtime inputs verified against sources.lock: 5 node files in $N/node-files"
made "$N" && [ "$(tail -n 1 "$WORK/d-new.log")" = "$N/node-files" ]; check "  ... the markers are there and the last line names node-files" 0 $? "$WORK/d-new.log"
printf 'mine\n' > "$N/notes.txt"; rc=0; pd "$WORK/d-rerun.log" "$N" || rc=$?
check "ACCEPT a re-run into the folder it made: its own folders are replaced" 0 "$rc" "$WORK/d-rerun.log" 'runtime inputs verified against sources.lock: 5 node files'
cmp -s "$N/notes.txt" <(printf 'mine\n') && made "$N"; check "  ... and a file beside them that it did not make is left as it was" 0 $? "$WORK/d-rerun.log"
E="$D/empty"; mkdir -p "$E"; rc=0; pd "$WORK/d-empty.log" "$E" || rc=$?
check "ACCEPT an existing empty folder" 0 "$rc" "$WORK/d-empty.log" 'runtime inputs verified against sources.lock: 5 node files'
T="$D/target"; mkdir -p "$T"; ln -s "$T" "$D/link"
rc=0; pd "$WORK/d-link.log" "$D/link" || rc=$?
check "REJECT a destination that is a symbolic link (to an empty folder)" 1 "$rc" "$WORK/d-link.log" "the destination $D/link is a symbolic link; give the real folder"
rc=0; pd "$WORK/d-link2.log" "$D/link/" || rc=$?
check "REJECT the same link written with a trailing slash" 1 "$rc" "$WORK/d-link2.log" "the destination $D/link is a symbolic link"
[ -z "$(ls -A "$T")" ]; check "  ... and nothing was written where the link points" 0 $? "$WORK/d-link2.log"
M="$D/marked"; pd "$WORK/d-m0.log" "$M"; rm -rf "$M/downloads"; mkdir "$M/downloads"; printf 'sentinel\n' > "$M/downloads/keep.txt"
before="$(tree_sum "$M")"; rc=0; pd "$WORK/d-m1.log" "$M" || rc=$?
check "REJECT a folder it made whose downloads/ it did not make (no marker inside)" 1 "$rc" "$WORK/d-m1.log" "$M/downloads exists and this helper did not make it"
[ "$(tree_sum "$M")" = "$before" ]; check "  ... the sentinel and the rest of the folder are byte-unchanged" 0 $? "$WORK/d-m1.log"
M2="$D/marked2"; pd "$WORK/d-m2a.log" "$M2"; O="$D/outside"; mkdir -p "$O"; printf 'sentinel\n' > "$O/keep.txt"
cp -- "$M2/node-files/.made-by-fetch-runtime-artifacts" "$O/"; rm -rf "$M2/node-files"; ln -s "$O" "$M2/node-files"
before="$(tree_sum "$O")$(tree_sum "$M2")"; rc=0; pd "$WORK/d-m2.log" "$M2" || rc=$?
check "REJECT a folder it made whose node-files is a link to an outside folder (even one carrying a copied marker)" 1 "$rc" "$WORK/d-m2.log" "$M2/node-files exists and this helper did not make it"
[ "$(tree_sum "$O")$(tree_sum "$M2")" = "$before" ]; check "  ... the outside folder and the link are left as they were" 0 $? "$WORK/d-m2.log"
F="$D/forged"; mkdir -p "$F/downloads"; printf 'sentinel\n' > "$F/downloads/keep.txt"; printf 'not the marker\n' > "$F/.fetch-runtime-artifacts"
before="$(tree_sum "$F")"; rc=0; pd "$WORK/d-forged.log" "$F" || rc=$?
check "REJECT a folder whose marker file is not this script's" 1 "$rc" "$WORK/d-forged.log" "$F/.fetch-runtime-artifacts is not this helper's marker file"
[ "$(tree_sum "$F")" = "$before" ]; check "  ... byte-unchanged" 0 $? "$WORK/d-forged.log"
# Review R2c MUST-FIX 1: each marker carries the destination's random token, and the helper works
# inside the folder it checked (opened once, without following a link), never through its path again.
tok() { sed -n 's/^token=\([0-9a-f]\{32\}\)$/\1/p' "$1"; }
A="$D/tokA"; B="$D/tokB"; pd "$WORK/d-ta.log" "$A"; pd "$WORK/d-tb.log" "$B"
ta="$(tok "$A/.fetch-runtime-artifacts")"; tb="$(tok "$B/.fetch-runtime-artifacts")"
okt=0; { [ -n "$ta" ] && [ -n "$tb" ] && [ "$ta" != "$tb" ]; } || okt=1
for d in downloads node-files signed-manifest; do [ "$(tok "$A/$d/.made-by-fetch-runtime-artifacts")" = "$ta" ] || okt=1; done
check "ACCEPT: each destination gets its own random token, and every folder it made there carries that token" 0 $okt "$WORK/d-ta.log"
rm -rf "$A/downloads"; mkdir "$A/downloads"; cp -- "$B/downloads/.made-by-fetch-runtime-artifacts" "$A/downloads/"
printf 'sentinel\n' > "$A/downloads/keep.txt"; before="$(tree_sum "$A")"; rc=0; pd "$WORK/d-tok.log" "$A" || rc=$?
check "REJECT a downloads/ whose marker was copied from another destination (another token)" 1 "$rc" "$WORK/d-tok.log" "$A/downloads exists and this helper did not make it"
[ "$(tree_sum "$A")" = "$before" ]; check "  ... the sentinel and the rest of the folder are byte-unchanged" 0 $? "$WORK/d-tok.log"
M3="$D/marked3"; pd "$WORK/d-m3a.log" "$M3"; mkdir "$M3/node-files/sub"; printf 'sentinel\n' > "$M3/node-files/sub/keep.txt"
before="$(tree_sum "$M3")"; rc=0; pd "$WORK/d-m3.log" "$M3" || rc=$?
check "REJECT a folder it made that now holds a folder (it never makes one there)" 1 "$rc" "$WORK/d-m3.log" "$M3/node-files exists and this helper did not make it"
[ "$(tree_sum "$M3")" = "$before" ]; check "  ... byte-unchanged" 0 $? "$WORK/d-m3.log"
L="$D/legacy"; mkdir -p "$L/downloads"; printf 'sentinel\n' > "$L/downloads/keep.txt"
printf 'packages/fetch-runtime-artifacts.sh keeps its metadata, downloads, node-files and signed-manifest\nfolders here, and removes only those folders, each when it carries its own marker.\n' > "$L/.fetch-runtime-artifacts"
printf 'made by packages/fetch-runtime-artifacts.sh, which replaces this folder on its next run\n' > "$L/downloads/.made-by-fetch-runtime-artifacts"
before="$(tree_sum "$L")"; rc=0; pd "$WORK/d-legacy.log" "$L" || rc=$?
check "REJECT markers with no token (a plain marker anyone can copy)" 1 "$rc" "$WORK/d-legacy.log" "$L/.fetch-runtime-artifacts is not this helper's marker file"
[ "$(tree_sum "$L")" = "$before" ]; check "  ... byte-unchanged" 0 $? "$WORK/d-legacy.log"
# The review's race: another process with write access to the destination's parent replaces the
# checked destination with a link to another folder X while the helper runs. X holds downloads/,
# node-files/ and signed-manifest/, each with a copy of the destination's own markers (its token
# too) and a sentinel. The swap happens at the helper's first download, after the checks; a curl
# wrapper first on PATH makes it, once, then runs the real curl.
R="$D/race"; X="$D/other"; pd "$WORK/d-race0.log" "$R"; mkdir -p "$X"; cp -- "$R/.fetch-runtime-artifacts" "$X/"
for d in downloads node-files signed-manifest; do
  mkdir -p "$X/$d"; cp -- "$R/$d/.made-by-fetch-runtime-artifacts" "$X/$d/"; printf 'sentinel %s\n' "$d" > "$X/$d/keep.txt"; done
SW="$WORK/bin-swap"; mkdir -p "$SW"; : > "$SW/armed"
printf '#!/bin/bash\nif [ -e %q ]; then rm -f %q; mv -- %q %q && ln -s %q %q; fi\nexec %q "$@"\n' \
  "$SW/armed" "$SW/armed" "$R" "$R.checked" "$X" "$R" "$(command -v curl)" > "$SW/curl"; chmod +x "$SW/curl"
before="$(tree_sum "$X")"; rc=0; pd "$WORK/d-race.log" "$R" PATH="$SW:$PATH" || rc=$?
check "REJECT a destination replaced by a link to another folder while the helper runs (fails closed)" 1 "$rc" "$WORK/d-race.log" \
  "the destination $R was replaced while this helper ran"
[ -L "$R" ] && [ ! -e "$SW/armed" ] && [ "$(tree_sum "$X")" = "$before" ]
check "  ... the swap happened, and every sentinel in the other folder is byte-unchanged, nothing added or removed" 0 $? "$WORK/d-race.log"
# The run folder itself (RUNTIME_ARTIFACTS_DIR, checked by common.sh) is shared with the kernel,
# patch and erofs-utils fetchers, so it may hold their files without a marker; the script's own
# folders inside it still need theirs.
RF="$WORK/runfolder"; mkdir -p "$RF"; printf 'kernel tarball stand-in\n' > "$RF/linux-fixture.tar.xz"
rf() { local log="$1" dir="$2"; shift 2; LOCK_FILE="$WORK/good/fixture.lock" RUNTIME_ARTIFACTS_DIR="$dir" bash "$HERE/fetch-runtime-artifacts.sh" "$@" > "$log" 2>&1; }
rc=0; rf "$WORK/d-rf-check.log" "$RF" --check || rc=$?
check "ACCEPT --check in the run folder while it holds another fetcher's file and no marker yet" 0 "$rc" "$WORK/d-rf-check.log" 'with no large download'
rc=0; rf "$WORK/d-rf-fetch.log" "$RF" || rc=$?
check "ACCEPT the full fetch into the run folder (no destination given)" 0 "$rc" "$WORK/d-rf-fetch.log" "5 node files in $RF/node-files"
rc=0; rf "$WORK/d-rf-pos.log" "$RF" "$RF" || rc=$?
check "ACCEPT the run folder given as the destination, as 30-runtime-install.sh gives it" 0 "$rc" "$WORK/d-rf-pos.log" "5 node files in $RF/node-files"
cmp -s "$RF/linux-fixture.tar.xz" <(printf 'kernel tarball stand-in\n') && made "$RF" && [ -f "$RF/metadata/.made-by-fetch-runtime-artifacts" ]
check "  ... the other fetcher's file is left as it was" 0 $? "$WORK/d-rf-pos.log"
RS="$WORK/runstale"; mkdir -p "$RS/metadata"; printf 'sentinel\n' > "$RS/metadata/keep.txt"; before="$(tree_sum "$RS")"
rc=0; rf "$WORK/d-rs.log" "$RS" --check || rc=$?
check "REJECT --check when the run folder holds a metadata/ this script did not make" 1 "$rc" "$WORK/d-rs.log" "$RS/metadata exists and this helper did not make it"
[ "$(tree_sum "$RS")" = "$before" ]; check "  ... byte-unchanged" 0 $? "$WORK/d-rs.log"
# An upgrade: the run folder as an earlier version of this script left it, with markers that hold
# no token (plain), or with no markers at all (none). Each is refused, changing nothing, by a
# message that names the folder and what to remove there; removing exactly that is enough.
up_old() { # up_old <dir> <plain|none>
  local d; mkdir -p "$1"; printf 'kernel tarball stand-in\n' > "$1/linux-fixture.tar.xz"
  [ "$2" = plain ] && printf 'packages/fetch-runtime-artifacts.sh keeps its metadata, downloads, node-files and signed-manifest\nfolders here, and removes only those folders, each when it carries its own marker.\n' > "$1/.fetch-runtime-artifacts"
  for d in metadata downloads node-files signed-manifest; do mkdir -p "$1/$d"; printf 'earlier %s\n' "$d" > "$1/$d/keep.txt"
    [ "$2" = plain ] && printf 'made by packages/fetch-runtime-artifacts.sh, which replaces this folder on its next run\n' > "$1/$d/.made-by-fetch-runtime-artifacts"
  done; return 0; }
for kind in plain none; do
  UP="$WORK/upgrade-$kind"; up_old "$UP" "$kind"; before="$(tree_sum "$UP")"
  if [ "$kind" = plain ]; then what="$UP/.fetch-runtime-artifacts is not this helper's marker file"; how="markers with no token"
  else what="$UP/metadata exists and this helper did not make it"; how="no markers"; fi
  rc=0; rf "$WORK/d-up-$kind.log" "$UP" --check || rc=$?
  check "REJECT --check on a run folder an earlier version left ($how), saying what to remove there" 1 "$rc" "$WORK/d-up-$kind.log" \
    "$what.*If an earlier version of this helper wrote what is in $UP .*remove any of \.fetch-runtime-artifacts, metadata, downloads, node-files and signed-manifest there, then run it again"
  [ "$(tree_sum "$UP")" = "$before" ]; check "  ... byte-unchanged" 0 $? "$WORK/d-up-$kind.log"
  for d in .fetch-runtime-artifacts metadata downloads node-files signed-manifest; do rm -rf -- "${UP:?}/$d"; done
  rc=0; rf "$WORK/d-up-$kind-2.log" "$UP" --check && rf "$WORK/d-up-$kind-2.log" "$UP" || rc=$?
  check "  ... ACCEPT --check and the full fetch once exactly those are removed" 0 "$rc" "$WORK/d-up-$kind-2.log" "5 node files in $UP/node-files"
  cmp -s "$UP/linux-fixture.tar.xz" <(printf 'kernel tarball stand-in\n'); check "  ... and the other fetcher's file is left as it was" 0 $? "$WORK/d-up-$kind-2.log"
done

echo
echo "== 3/4 the real pins: packages/sources.lock against real copies of the runtime inputs ======"
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
echo "== 4/4 host-kernel patch: packages/fetch-kernel-patch.sh =============================="
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
