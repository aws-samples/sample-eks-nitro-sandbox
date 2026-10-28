#!/usr/bin/env bash
# test-inputs.sh: proves the two GA input checks both ways, in the REAL scripts, with no AWS and
# no network reached:
#   packages/fetch-runtime-artifacts.sh  (the operator-supplied runtime zip and its payloads)
#   packages/fetch-kernel-patch.sh       (AWS's public host-kernel commit as a .patch)
#
#   packages/test-inputs.sh
#   REAL_RUNTIME_ARCHIVE=/path/to/nitro-sandbox-binaries-2026-10-28.zip packages/test-inputs.sh
#       also runs the real archive against the real packages/sources.lock (unpacks ~2.3 GB)
#
# Fixtures are small files with the eight real payload names, zipped per case, with a test-local
# lock file pinned to each case's own archive (so the archive check passes and the check the
# case is about is the one that answers). curl is a stub first on PATH that copies a local file
# to curl's -o target, so fetch-kernel-patch.sh runs unchanged. The real pinned patch, when it is
# cached under the repository's tmp/ (setup.sh --prepare or fetch-kernel-patch.sh leaves it
# there), is also run against the REAL packages/sources.lock, accepted, and refused tampered.
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

# --- Runtime archive fixtures -------------------------------------------------------------------
NAMES=(containerd-shim-nitro-sandbox-v2 eks-nitro-sandbox-genpolicy firecracker jailer latest-disk.img latest.eif nitro-sandbox-agent nitro-sandbox-keyprovider)
SRC="$WORK/payloads"; mkdir -p "$SRC"
for n in "${NAMES[@]}"; do printf 'fixture payload %s\n' "$n" > "$SRC/$n"; done

# make_case <case> : build $WORK/<case>/runtime/fixture.zip for the named shape (python3 zipfile).
make_case() {
  mkdir -p "$WORK/$1/runtime"
  python3 - "$1" "$SRC" "$WORK/$1/runtime/fixture.zip" "${NAMES[@]}" <<'PY'
import hashlib, sys, warnings, zipfile
case, src, out, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
files = {n: open(f"{src}/{n}", "rb").read() for n in names}
sums = {n: hashlib.sha256(b).hexdigest() for n, b in files.items()}
lines = [f"{sums[n]}  {n}" for n in sorted(files)]
extra = []
if case == "tampered":          # payload changed after SHA256SUMS was written
    files["jailer"] = b"tampered jailer\n"
elif case == "missing-line":    # a payload SHA256SUMS does not list
    lines = [l for l in lines if not l.endswith("  firecracker")]
elif case == "extra-file":      # an unpacked file SHA256SUMS does not list
    extra = [("extra-tool", b"not listed\n")]
elif case == "dup-line":        # SHA256SUMS lists a file twice
    lines.append(f"{sums['latest.eif']}  latest.eif")
elif case == "repacked":        # payload AND its SHA256SUMS line changed together
    files["firecracker"] = b"repacked firecracker\n"
    lines = [f"{hashlib.sha256(files[n]).hexdigest()}  {n}" for n in sorted(files)]
elif case == "unpinned":        # a ninth payload, listed in SHA256SUMS, that sources.lock does not pin
    bonus = b"unpinned\n"
    extra = [("bonus-binary", bonus)]
    lines.append(hashlib.sha256(bonus).hexdigest() + "  bonus-binary")
    lines.sort(key=lambda l: l.split("  ", 1)[1])
with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    with zipfile.ZipFile(out, "w") as z:
        z.writestr("SHA256SUMS", "\n".join(lines) + "\n")
        for n, b in files.items():
            z.writestr(n, b)
        for n, b in extra:
            z.writestr(n, b)
        if case == "dup-member":    # two members with the same name
            z.writestr("jailer", b"second jailer\n")
        if case == "dir-member":    # a member inside a folder
            z.writestr("sub/evil", b"x\n")
        if case == "symlink-member":  # a member recorded as a symbolic link
            zi = zipfile.ZipInfo("jailer-link")
            zi.external_attr = (0o120777) << 16
            z.writestr(zi, "/usr/bin/jailer")
PY
}
# write_lock <case> <archive-sha256> : a test lock in the real file's shape, payloads pinned to the fixtures.
write_lock() {
  {
    printf 'id=runtime-archive\nkind=file\nref=fixture\nfile=fixture.zip\nsource=operator-supplied fixture\nsha256=%s\nstatus=operator-supplied\n\n' "$2"
    for n in "${NAMES[@]}"; do
      printf 'id=runtime-payload-%s\nkind=runtime-payload\narchive=runtime-archive\nref=fixture\nfile=%s\nsource=member of runtime-archive\nsha256=%s\ninstall=none\nstatus=operator-supplied\n\n' \
        "$(printf '%s' "$n" | tr . -)" "$n" "$(sha "$SRC/$n")"
    done
  } > "$WORK/$1/sources.lock"
}
run_archive() { # run_archive <case> : run the REAL fetch-runtime-artifacts.sh on the case
  LOCK_FILE="$WORK/$1/sources.lock" RUNTIME_ARTIFACTS_DIR="$WORK/$1/runtime" RUNTIME_ARTIFACT_FILE=fixture.zip \
    bash "$HERE/fetch-runtime-artifacts.sh" > "$WORK/$1.log" 2>&1
}

echo "== 1/2 runtime archive: packages/fetch-runtime-artifacts.sh ========================="
for c in good wrong-hash tampered missing-line extra-file dup-line repacked unpinned dup-member dir-member symlink-member; do
  make_case "$c"
  if [[ "$c" == wrong-hash ]]; then write_lock "$c" "$(printf '0%.0s' {1..64})"; else write_lock "$c" "$(sha "$WORK/$c/runtime/fixture.zip")"; fi
  rc=0; run_archive "$c" || rc=$?
  case "$c" in
    good)         check "ACCEPT a good zip: archive pin, SHA256SUMS coverage, payload hashes and pins all match" 0 "$rc" "$WORK/$c.log" 'runtime archive fixture.zip verified: 8 payloads'
                  [[ -f "$WORK/$c/runtime/unpacked/latest-disk.img" ]]; check "ACCEPT unpacks every payload into RUNTIME_ARTIFACTS_DIR/unpacked" 0 $? "$WORK/$c.log" ;;
    wrong-hash)   check "REJECT an archive whose SHA-256 is not the runtime-archive pin" 1 "$rc" "$WORK/$c.log" 'SHA-256 mismatch' ;;
    tampered)     check "REJECT a payload that no longer matches its SHA256SUMS line" 1 "$rc" "$WORK/$c.log" 'jailer: FAILED' ;;
    missing-line) check "REJECT a payload missing from SHA256SUMS" 1 "$rc" "$WORK/$c.log" 'does not cover exactly the unpacked files' ;;
    extra-file)   check "REJECT an extra unpacked file SHA256SUMS does not list" 1 "$rc" "$WORK/$c.log" 'does not cover exactly the unpacked files' ;;
    dup-line)     check "REJECT a SHA256SUMS that lists a file twice" 1 "$rc" "$WORK/$c.log" 'lists a file more than once: latest.eif' ;;
    repacked)     check "REJECT a re-packed payload whose SHA256SUMS line was edited to match (sources.lock pin)" 1 "$rc" "$WORK/$c.log" 'payload firecracker has SHA-256 .* not the' ;;
    unpinned)     check "REJECT a listed payload sources.lock does not pin" 1 "$rc" "$WORK/$c.log" 'not the set packages/sources.lock pins' ;;
    dup-member)   check "REJECT a zip with two members of the same name" 1 "$rc" "$WORK/$c.log" 'more than one member named: jailer' ;;
    dir-member)   check "REJECT a zip member inside a folder" 1 "$rc" "$WORK/$c.log" "not plain, flat file names: 'sub/evil'" ;;
    symlink-member) check "REJECT a zip member recorded as a symbolic link" 1 "$rc" "$WORK/$c.log" "not plain, flat file names: 'jailer-link'" ;;
  esac
done
mkdir -p "$WORK/absent/runtime"; write_lock absent "$(printf '0%.0s' {1..64})"
rc=0; run_archive absent || rc=$?
check "STOP (exit 3, the documented prerequisite) when the operator has not placed the archive" 3 "$rc" "$WORK/absent.log" 'PREREQUISITE NOT MET'

if [[ -n "${REAL_RUNTIME_ARCHIVE:-}" ]]; then
  mkdir -p "$WORK/real/runtime"; cp -- "$REAL_RUNTIME_ARCHIVE" "$WORK/real/runtime/"
  rc=0
  RUNTIME_ARTIFACTS_DIR="$WORK/real/runtime" RUNTIME_ARTIFACT_FILE="$(basename "$REAL_RUNTIME_ARCHIVE")" \
    bash "$HERE/fetch-runtime-artifacts.sh" > "$WORK/real.log" 2>&1 || rc=$?
  check "ACCEPT the real runtime archive against the REAL packages/sources.lock" 0 "$rc" "$WORK/real.log" 'verified: 8 payloads match SHA256SUMS and packages/sources.lock'
else
  echo "  SKIP  the real runtime archive (set REAL_RUNTIME_ARCHIVE to run it)"; skip=$((skip+1))
fi

echo
echo "== 2/2 host-kernel patch: packages/fetch-kernel-patch.sh =============================="
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
check "REJECT a tampered patch (SHA-256 mismatch)" 1 "$rc" "$WORK/p-tampered.log" 'SHA-256 mismatch for the host-kernel patch'
[[ ! -e "$WORK/p-tampered/$COMMIT.patch" && ! -e "$WORK/p-tampered/$COMMIT.patch.part" ]]
check "REJECT leaves no patch under the final name and no .part file" 0 $? "$WORK/p-tampered.log"
plock "$WORK/patch-other.lock" "$(sha "$WORK/othercommit.patch")"
rc=0; run_patch other "$WORK/patch-other.lock" "$WORK/othercommit.patch" || rc=$?
check "REJECT a patch on its pinned SHA-256 whose From line names a different commit" 1 "$rc" "$WORK/p-other.log" "does not start with git's 'From $COMMIT' header"
rc=0; run_patch nofetch "$WORK/patch.lock" "" || rc=$?
check "REJECT when the download fails (no file is left to apply)" 1 "$rc" "$WORK/p-nofetch.log" 'could not download'

REAL_PATCH="${REAL_KERNEL_PATCH:-$REPO_ROOT_REAL/tmp/issue10/run/runtime/$(sed -n 's/^file=//p' "$HERE/sources.lock" | grep '\.patch$' | head -n 1)}"
if [[ -s "$REAL_PATCH" ]]; then
  cp -- "$REAL_PATCH" "$WORK/real.patch"
  python3 -c 'import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); b[-2]^=1; open(sys.argv[2],"wb").write(b)' "$WORK/real.patch" "$WORK/real-tampered.patch"
  rc=0; run_patch real "$HERE/sources.lock" "$WORK/real.patch" || rc=$?
  check "ACCEPT the real cached patch against the REAL packages/sources.lock pin" 0 "$rc" "$WORK/p-real.log" 'verified sha256 .*1e66c960b982c94bda76ebd0129eaecf0a68b46e'
  rc=0; run_patch real-tampered "$HERE/sources.lock" "$WORK/real-tampered.patch" || rc=$?
  check "REJECT the real patch with one byte changed against the REAL pin" 1 "$rc" "$WORK/p-real-tampered.log" 'SHA-256 mismatch for the host-kernel patch'
else
  echo "  SKIP  the real pinned patch (not cached at $REAL_PATCH; run packages/fetch-kernel-patch.sh first)"; skip=$((skip+1))
fi

echo
printf 'passed %d, failed %d, skipped %d\n' "$pass" "$fail" "$skip"
[[ "$fail" -eq 0 ]] || exit 1
echo "runtime archive and host-kernel patch checks proven both ways in the real scripts."
