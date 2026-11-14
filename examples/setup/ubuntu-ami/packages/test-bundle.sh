#!/usr/bin/env bash
# test-bundle.sh: proves make-bundle.sh both ways, with no network reached and without
# downloading the real multi-hundred-MB kernel/erofs-utils sources.
#
#   packages/test-bundle.sh
#
# What it proves, against a small local fixture and a test-local lock file (never
# packages/sources.lock itself, so this never re-pins the real inputs):
#   1/4  build:    fetch (from a local file:// URL) + verify + archive + manifest succeeds
#        for a good fixture, and a second independent build produces a byte-identical
#        archive (same SHA-256): the determinism proof.
#   2/4  consume:  the good bundle verifies and extracts offline (fail-closed path NOT
#        triggered): accept control.
#   3/4  consume:  a TAMPERED archive (one byte flipped) is REJECTED, non-zero exit,
#        clear message: reject control for archive tampering.
#   4/4  consume:  a MISSING bundle (no archive file at all) is REJECTED, non-zero exit:
#        reject control for a missing bundle.
#   6/6  consume:  extraction is staged beside the destination: a good bundle lands with no
#        temporary folder left; a final-hash failure leaves no destination and no temporary
#        folder; a non-empty destination is refused with its contents untouched; an existing
#        empty destination keeps its mode and owner (0700 stays 0700), and a missing one is
#        created 0777 & ~umask.
#
# The fixtures mirror the real lock file's shapes: two source tarballs, a public .patch input
# (like host-kernel-patch), a signed release archive (like runtime-release, kind signed-archive)
# that build must skip without listing it, a pending input and a not-available archive that build
# must skip and list as external slots, and an ssm-ami block.
#
# The real sources.lock inputs (kernel 6.18.56, the host-kernel patch, erofs-utils 1.8.10) follow this identical
# code path (bundle_fetch_file -> bundle_verify_sha256 -> bundle_create_archive ->
# bundle_write_manifest, and bundle_verify_archive on consume); this test exercises that
# same path end to end with inputs small enough to run with no network and in under a
# second, not a different code path kept only for tests.
set -euo pipefail
# A reader's own config.env (in the sample folder or ~/ubuntu-ami/) must not change what this suite
# tests: scripts/lib/common.sh skips it while this test hook is set.
export UBUNTU_AMI_TESTS_IGNORE_CONFIG_ENV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bundle-common.sh
. "$HERE/lib/bundle-common.sh"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass=0
fail=0
assert_rc() { # assert_rc <description> <expected-rc> <actual-rc>
  if [[ "$3" -eq "$2" ]]; then
    printf '  PASS  %s (rc=%s)\n' "$1" "$3"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s (expected rc=%s, got rc=%s)\n' "$1" "$2" "$3"
    fail=$((fail + 1))
  fi
}
assert_true() { # assert_true <description> <bool-expr-already-evaluated-as-0-or-1>
  if [[ "$2" -eq 0 ]]; then
    printf '  PASS  %s\n' "$1"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s\n' "$1"
    fail=$((fail + 1))
  fi
}

# --- Fixture: a tiny "source tarball" with a known SHA-256, served over file:// so the
# fetch path (curl) runs for real with no internet reached. A second, unrelated fixture
# proves the component loop handles more than one input, as the real lock file does.
FIXTURE_DIR="$WORK/fixtures"
mkdir -p "$FIXTURE_DIR"
printf 'fixture-source-content-for-make-bundle-test\n' > "$FIXTURE_DIR/fixture-a-1.0.0.tar.gz"
printf 'second-fixture-source-content\n' > "$FIXTURE_DIR/fixture-b-2.0.0.tar.gz"
printf 'From 0123456789abcdef0123456789abcdef01234567 Mon Sep 17 00:00:00 2001\nSubject: [PATCH] fixture\n' > "$FIXTURE_DIR/0123abcd.patch"
FIXTURE_A_SHA="$(bundle_sha256_of "$FIXTURE_DIR/fixture-a-1.0.0.tar.gz")"
FIXTURE_B_SHA="$(bundle_sha256_of "$FIXTURE_DIR/fixture-b-2.0.0.tar.gz")"
FIXTURE_P_SHA="$(bundle_sha256_of "$FIXTURE_DIR/0123abcd.patch")"
printf 'fixture signed release archive\n' > "$FIXTURE_DIR/fixture-release.tar.gz"
FIXTURE_R_SHA="$(bundle_sha256_of "$FIXTURE_DIR/fixture-release.tar.gz")"

TEST_LOCK="$WORK/test-sources.lock"
cat > "$TEST_LOCK" <<LOCK
# Test-local lock file for packages/test-bundle.sh. NOT packages/sources.lock: this never
# re-pins a real input. Exercises the identical bundle_fetch_file/verify/archive code path
# with small fixtures instead of the real multi-hundred-MB kernel and erofs-utils sources.

id=fixture-a
kind=file
ref=1.0.0
source=file://$FIXTURE_DIR/fixture-a-1.0.0.tar.gz
sha256=$FIXTURE_A_SHA
verify=test fixture, pinned by this test run
status=available

id=fixture-b
kind=file
ref=2.0.0
source=file://$FIXTURE_DIR/fixture-b-2.0.0.tar.gz
sha256=$FIXTURE_B_SHA
verify=test fixture, pinned by this test run
status=available

id=fixture-patch
kind=file
ref=0123456789abcdef0123456789abcdef01234567
source=file://$FIXTURE_DIR/0123abcd.patch
sha256=$FIXTURE_P_SHA
verify=mirrors the real host-kernel-patch block: a public .patch input, bundled
status=available

id=fixture-runtime
kind=file
ref=fixture-runtime-1
file=fixture-runtime.zip
source=not-available: an archive with no public download
sha256=0000000000000000000000000000000000000000000000000000000000000000
verify=a file input that is not available; must be skipped by build, never fetched, listed as an external slot
status=not-available

id=fixture-release
kind=signed-archive
ref=fixture-release-1
file=fixture-release.tar.gz
source=file://$FIXTURE_DIR/fixture-release.tar.gz
sha256=$FIXTURE_R_SHA
verify=mirrors the real runtime-release block: fetchable and available, but not a kind=file input, so build skips it
status=available

id=fixture-pending
kind=file
ref=TODO-pin-exact-public-release-version
source=TODO-public-release-not-yet-published
sha256=TODO-sha256-once-released
verify=a not-yet-available input; must be skipped by build, never fetched, listed as an external slot
status=pending-public-release

id=fixture-ami
kind=ssm-ami
ref=k8s-1.36
source=/aws/service/example/ami-id
sha256=n/a
verify=mirrors the real ssm-ami block; must be skipped by build, it is not a file to archive
status=available
LOCK

echo "== 1/4 build: good fixtures verify, archive, and are deterministic across two builds =="
OUT1="$WORK/bundle-run-1"
OUT2="$WORK/bundle-run-2"
rc=0
LOCK_FILE="$TEST_LOCK" bash "$HERE/make-bundle.sh" build "$OUT1" > "$WORK/build1.log" 2>&1 || rc=$?
assert_rc "first build of good fixtures succeeds" 0 "$rc"
rc=0
LOCK_FILE="$TEST_LOCK" bash "$HERE/make-bundle.sh" build "$OUT2" > "$WORK/build2.log" 2>&1 || rc=$?
assert_rc "second, independent build of the same fixtures succeeds" 0 "$rc"

sha1=""
sha2=""
[[ -s "$OUT1/dependency-bundle.tar" ]] && sha1="$(bundle_sha256_of "$OUT1/dependency-bundle.tar")"
[[ -s "$OUT2/dependency-bundle.tar" ]] && sha2="$(bundle_sha256_of "$OUT2/dependency-bundle.tar")"
echo "  build 1 archive sha256: ${sha1:-<missing>}"
echo "  build 2 archive sha256: ${sha2:-<missing>}"
assert_true "both builds produced the archive" $([[ -n "$sha1" && -n "$sha2" ]]; echo $?)
assert_true "DETERMINISM: two independent builds produce a byte-identical archive (same sha256)" \
  $([[ -n "$sha1" && "$sha1" == "$sha2" ]]; echo $?)

python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OUT1/dependency-bundle.manifest.json" \
  && manifest_parses=0 || manifest_parses=1
assert_true "the emitted manifest is valid, parseable JSON" "$manifest_parses"

components_count="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["components"]))' "$OUT1/dependency-bundle.manifest.json" 2>/dev/null || echo 0)"
echo "  manifest lists $components_count component(s) (expect 3: fixture-a, fixture-b, fixture-patch)"
assert_true "manifest lists exactly the three bundleable fixtures (not the pending, not-available, signed-archive or ssm-ami ones)" \
  $([[ "$components_count" -eq 3 ]]; echo $?)
assert_true "the public .patch input is in the archive under its .patch name" \
  $(tar -tf "$OUT1/dependency-bundle.tar" | grep -qx 'fixture-patch-0123456789abcdef0123456789abcdef01234567.patch'; echo $?)

slots="$(python3 -c 'import json,sys; print(" ".join(sorted(s["id"] for s in json.load(open(sys.argv[1]))["external_unbundled_slots"])))' "$OUT1/dependency-bundle.manifest.json" 2>/dev/null || echo "")"
echo "  external slots: ${slots:-<none>} (expect: fixture-pending fixture-runtime)"
assert_true "manifest lists exactly the non-available file inputs as external slots, read from the lock file" \
  $([[ "$slots" == "fixture-pending fixture-runtime" ]]; echo $?)
assert_true "the not-available fixture was never fetched into the archive" \
  $(! tar -tf "$OUT1/dependency-bundle.tar" | grep -q 'fixture-runtime'; echo $?)
assert_true "the signed-archive fixture (like the runtime release) is neither bundled nor listed as a slot, though it is fetchable" \
  $(! tar -tf "$OUT1/dependency-bundle.tar" | grep -q 'fixture-release' && [[ "$slots" != *fixture-release* ]] && grep -q 'skip fixture-release: kind=signed-archive' "$WORK/build1.log"; echo $?)

echo
echo "== 2/4 consume (ACCEPT control): a good bundle verifies and extracts offline =========="
EXTRACT_GOOD="$WORK/extract-good"
rc=0
LOCK_FILE="$TEST_LOCK" bash "$HERE/make-bundle.sh" consume "$OUT1" "$EXTRACT_GOOD" > "$WORK/consume-good.log" 2>&1 || rc=$?
assert_rc "a good, untampered bundle is accepted" 0 "$rc"
assert_true "the fixture-a payload was extracted with its original content" \
  $(cmp -s "$EXTRACT_GOOD/fixture-a-1.0.0.tar.gz" "$FIXTURE_DIR/fixture-a-1.0.0.tar.gz"; echo $?)

echo
echo "== 3/4 consume (REJECT control): a tampered archive is rejected, fail-closed =========="
TAMPERED_DIR="$WORK/bundle-tampered"
mkdir -p "$TAMPERED_DIR"
cp "$OUT1/dependency-bundle.tar" "$TAMPERED_DIR/dependency-bundle.tar"
cp "$OUT1/dependency-bundle.manifest.json" "$TAMPERED_DIR/dependency-bundle.manifest.json"
# Flip one byte in the archive without changing its length, so it is still a plausible tar
# but no longer matches the manifest's recorded SHA-256.
python3 - "$TAMPERED_DIR/dependency-bundle.tar" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r+b") as f:
    data = bytearray(f.read())
    data[200] ^= 0xFF
    f.seek(0)
    f.write(data)
PY
rc=0
LOCK_FILE="$TEST_LOCK" bash "$HERE/make-bundle.sh" consume "$TAMPERED_DIR" "$WORK/extract-tampered" > "$WORK/consume-tampered.log" 2>&1 || rc=$?
assert_rc "a tampered archive is rejected with a non-zero exit" 1 "$rc"
assert_true "the rejection names a SHA-256 mismatch, not a generic error" \
  $(grep -q "SHA-256" "$WORK/consume-tampered.log"; echo $?)

echo
echo "== 4/4 consume (REJECT control): a missing bundle is rejected, fail-closed ============="
EMPTY_DIR="$WORK/bundle-missing"
mkdir -p "$EMPTY_DIR"
rc=0
LOCK_FILE="$TEST_LOCK" bash "$HERE/make-bundle.sh" consume "$EMPTY_DIR" "$WORK/extract-missing" > "$WORK/consume-missing.log" 2>&1 || rc=$?
assert_rc "a missing bundle (no archive present) is rejected with a non-zero exit" 1 "$rc"
assert_true "the rejection names a missing archive, not a generic error" \
  $(grep -q "missing or empty archive" "$WORK/consume-missing.log"; echo $?)

echo
echo "== 5/5 consume (REJECT controls): sources.lock is the trust root, members checked first ==="
# craft <dir> <case>: an archive + manifest that agree with EACH OTHER (the manifest records the
# crafted archive's real SHA-256), built from the good bundle, then changed one way per case.
craft() {
  local d="$1" case="$2"
  mkdir -p "$d"
  python3 - "$OUT1" "$d" "$case" <<'PY'
import hashlib, io, json, sys, tarfile
src, d, case = sys.argv[1:4]
man = json.load(open(f"{src}/dependency-bundle.manifest.json"))
with tarfile.open(f"{src}/dependency-bundle.tar") as t:
    files = {m.name: t.extractfile(m).read() for m in t.getmembers()}
extra = []
if case == "lock-mismatch":     # the reviewer's probe: a changed component, consistent manifest
    name = next(n for n in files if n.startswith("fixture-a-"))
    files[name] = b"replaced content that sources.lock never pinned\n"
    for c in man["components"]:
        if c["id"] == "fixture-a":
            c["sha256"] = hashlib.sha256(files[name]).hexdigest()
elif case == "hash-mismatch":     # manifest and member set still match the lock; one payload does not
    name = next(n for n in files if n.startswith("fixture-a-"))
    files[name] = b"payload whose SHA-256 is not the lock pin\n"
elif case == "extra-member":
    files["unlisted-extra.sh"] = b"#!/bin/sh\necho not in the lock\n"
elif case == "missing-component":
    man["components"] = [c for c in man["components"] if c["id"] != "fixture-b"]
def add(t, name, data=b"", kind=tarfile.REGTYPE, link=""):
    ti = tarfile.TarInfo(name); ti.type = kind; ti.linkname = link; ti.size = len(data) if kind == tarfile.REGTYPE else 0
    t.addfile(ti, io.BytesIO(data) if kind == tarfile.REGTYPE else None)
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    for n in sorted(files):
        add(t, n, files[n])
    if case == "symlink-member":
        add(t, "fixture-link", kind=tarfile.SYMTYPE, link="/etc/passwd")
    if case == "traversal-member":
        add(t, "../escaped-by-bundle", b"outside\n")
    if case == "duplicate-member":
        n = next(n for n in files if n.startswith("fixture-b-"))
        add(t, n, b"second copy\n")
data = buf.getvalue()
open(f"{d}/dependency-bundle.tar", "wb").write(data)
man["archive"]["sha256"] = hashlib.sha256(data).hexdigest()
json.dump(man, open(f"{d}/dependency-bundle.manifest.json", "w"), indent=2)
PY
}
while IFS='|' read -r case rx why; do
  [ -n "$case" ] || continue
  craft "$WORK/craft-$case" "$case"
  rc=0
  LOCK_FILE="$TEST_LOCK" bash "$HERE/make-bundle.sh" consume "$WORK/craft-$case" "$WORK/craft-$case/x" > "$WORK/craft-$case.log" 2>&1 || rc=$?
  assert_rc "$why" 1 "$rc"
  assert_true "  ... and the refusal says why ($rx)" $(grep -qE -- "$rx" "$WORK/craft-$case.log"; echo $?)
done <<'CASES'
lock-mismatch|disagrees with sources.lock|REJECT a self-consistent archive + manifest whose component disagrees with sources.lock
extra-member|not the lock file.s|REJECT an archive with an unlisted extra member, before extraction
symlink-member|not regular files with flat names|REJECT an archive with a symbolic-link member
traversal-member|not regular files with flat names: \['\.\./escaped-by-bundle'\]|REJECT an archive member that escapes the extract folder (..)
duplicate-member|more than one member named|REJECT an archive with a duplicate member
missing-component|are not the lock file.s bundleable inputs|REJECT a manifest that leaves out a component the lock file pins
CASES
assert_true "no rejected bundle wrote anything: no extract folder has a file, nothing escaped" \
  $([[ -z "$(find "$WORK"/craft-*/x -type f 2>/dev/null)" && ! -e "$WORK/escaped-by-bundle" && ! -e "$WORK/craft-traversal-member/escaped-by-bundle" ]]; echo $?)

echo
echo "== 6/6 consume: extraction is staged beside the destination and renamed only on success ==="
# Each case gets its own parent folder, so "ls -A <parent>" shows any temporary folder left behind.
ATOMIC="$WORK/atomic"
mkdir -p "$ATOMIC/good" "$ATOMIC/bad" "$ATOMIC/full/dest"
rc=0
LOCK_FILE="$TEST_LOCK" bash "$HERE/make-bundle.sh" consume "$OUT1" "$ATOMIC/good/dest" > "$WORK/atomic-good.log" 2>&1 || rc=$?
assert_rc "ACCEPT a good bundle into a fresh destination" 0 "$rc"
assert_true "  ... the payload is in the destination and no temporary folder is left beside it" \
  $([[ "$(ls -A "$ATOMIC/good")" == dest ]] && cmp -s "$ATOMIC/good/dest/fixture-a-1.0.0.tar.gz" "$FIXTURE_DIR/fixture-a-1.0.0.tar.gz"; echo $?)

craft "$WORK/craft-hash-mismatch" hash-mismatch
rc=0
LOCK_FILE="$TEST_LOCK" bash "$HERE/make-bundle.sh" consume "$WORK/craft-hash-mismatch" "$ATOMIC/bad/dest" > "$WORK/atomic-bad.log" 2>&1 || rc=$?
assert_rc "REJECT a bundle whose member set passes but whose final component hash fails" 1 "$rc"
assert_true "  ... the refusal is the final hash check (sources.lock pins for fixture-a)" \
  $(grep -q 'sources.lock pins for fixture-a' "$WORK/atomic-bad.log"; echo $?)
assert_true "  ... the destination does not exist and no temporary folder is left beside it" \
  $([[ ! -e "$ATOMIC/bad/dest" && -z "$(ls -A "$ATOMIC/bad")" ]]; echo $?)

printf 'existing content\n' > "$ATOMIC/full/dest/keep.txt"
rc=0
LOCK_FILE="$TEST_LOCK" bash "$HERE/make-bundle.sh" consume "$OUT1" "$ATOMIC/full/dest" > "$WORK/atomic-full.log" 2>&1 || rc=$?
assert_rc "REJECT consuming a good bundle into a non-empty destination" 1 "$rc"
assert_true "  ... the refusal names the non-empty destination" \
  $(grep -q 'is not an empty folder' "$WORK/atomic-full.log"; echo $?)
assert_true "  ... the existing contents are untouched and no temporary folder is left beside it" \
  $([[ "$(ls -A "$ATOMIC/full/dest")" == keep.txt && "$(cat "$ATOMIC/full/dest/keep.txt")" == "existing content" && "$(ls -A "$ATOMIC/full")" == dest ]]; echo $?)

# The destination's mode, under an explicit umask 022: an existing empty folder keeps its own
# mode and owner; a missing one is created 0777 & ~umask.
mkdir -p "$ATOMIC/keep/dest" "$ATOMIC/new"
chmod 0700 "$ATOMIC/keep/dest"
keep_owner="$(stat -c %u:%g "$ATOMIC/keep/dest")"
rc=0
( umask 022; LOCK_FILE="$TEST_LOCK" bash "$HERE/make-bundle.sh" consume "$OUT1" "$ATOMIC/keep/dest" ) > "$WORK/atomic-keep.log" 2>&1 || rc=$?
assert_rc "ACCEPT a good bundle into an existing empty destination of mode 0700 (umask 022)" 0 "$rc"
assert_true "  ... all three components are extracted and verified, and no temporary folder is left beside it" \
  $([[ "$(ls -A "$ATOMIC/keep")" == dest && "$(grep -c '^verified sha256 for ' "$WORK/atomic-keep.log")" -eq 3 ]] \
    && cmp -s "$ATOMIC/keep/dest/fixture-a-1.0.0.tar.gz" "$FIXTURE_DIR/fixture-a-1.0.0.tar.gz" \
    && cmp -s "$ATOMIC/keep/dest/fixture-b-2.0.0.tar.gz" "$FIXTURE_DIR/fixture-b-2.0.0.tar.gz" \
    && cmp -s "$ATOMIC/keep/dest/fixture-patch-0123456789abcdef0123456789abcdef01234567.patch" "$FIXTURE_DIR/0123abcd.patch"; echo $?)
assert_true "  ... the destination is still mode 0700 with its owner unchanged, not widened to 0755" \
  $([[ "$(stat -c %a "$ATOMIC/keep/dest")" == 700 && "$(stat -c %u:%g "$ATOMIC/keep/dest")" == "$keep_owner" ]]; echo $?)
rc=0
( umask 022; LOCK_FILE="$TEST_LOCK" bash "$HERE/make-bundle.sh" consume "$OUT1" "$ATOMIC/new/dest" ) > "$WORK/atomic-new.log" 2>&1 || rc=$?
assert_rc "ACCEPT a good bundle into a missing destination (umask 022)" 0 "$rc"
assert_true "  ... the new destination is created 0777 & ~umask (0755), with the payload in it" \
  $([[ "$(stat -c %a "$ATOMIC/new/dest")" == 755 ]] && cmp -s "$ATOMIC/new/dest/fixture-a-1.0.0.tar.gz" "$FIXTURE_DIR/fixture-a-1.0.0.tar.gz"; echo $?)

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "make-bundle.sh proven both ways: good bundle accepted; tampered, missing, lock-disagreeing and unsafe bundles rejected fail-closed; two builds deterministic."
