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
#
# The real sources.lock inputs (kernel 6.18.39, erofs-utils 1.8.10) follow this identical
# code path (bundle_fetch_file -> bundle_verify_sha256 -> bundle_create_archive ->
# bundle_write_manifest, and bundle_verify_archive on consume); this test exercises that
# same path end to end with inputs small enough to run with no network and in under a
# second, not a different code path kept only for tests.
set -euo pipefail
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
FIXTURE_A_SHA="$(bundle_sha256_of "$FIXTURE_DIR/fixture-a-1.0.0.tar.gz")"
FIXTURE_B_SHA="$(bundle_sha256_of "$FIXTURE_DIR/fixture-b-2.0.0.tar.gz")"

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

id=fixture-pending
kind=file
ref=TODO-pin-exact-public-release-version
source=TODO-public-release-not-yet-published
sha256=TODO-sha256-once-released
verify=mirrors the real pending-public-release blocks; must be skipped by build, never fetched
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
echo "  manifest lists $components_count component(s) (expect 2: fixture-a, fixture-b)"
assert_true "manifest lists exactly the two bundleable fixtures (not the pending or ssm-ami ones)" \
  $([[ "$components_count" -eq 2 ]]; echo $?)

slots_count="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["external_unbundled_slots"]))' "$OUT1/dependency-bundle.manifest.json" 2>/dev/null || echo 0)"
assert_true "manifest documents both external unbundled runtime slots" $([[ "$slots_count" -eq 2 ]]; echo $?)

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
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "make-bundle.sh proven both ways: good bundle accepted, tampered/missing bundle rejected fail-closed, two builds deterministic."
