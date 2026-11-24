#!/usr/bin/env bash
# test-runtime-verify.sh: proves packages/lib/runtime_verify.py both ways, the REAL file, against
# fixture inputs served through file:// URLs (scripts/testlib/fixture_inputs.py). No network and
# no AWS: curl and openssl are real, the inputs are small stand-ins signed with a P-384 test key.
#
# #281: "Before the build uses a downloaded file, it compares the SHA-256 of that file with the
# source lock. For the runtime archive, it also checks the ECDSA signature of the downloaded
# SHA256SUM with nitro-sandboxes-runtime-v1.pub." and "A changed checksum stops the build, and a
# changed signature stops the build. The offline tests show both refusals."
#
#   examples/setup/cilium-bottlerocket/scripts/test-runtime-verify.sh
source "$(dirname "$0")/testlib/harness.sh"
RV="$SAMPLE_DIR_REAL/packages/lib/runtime_verify.py"
need_file "$RV" "every runtime_verify.py case" || finish

# rv <case> <fetch|check> [<lock>]: make the case's fixtures once, then run the real verifier.
rv() {
  local c="$1" mode="$2" lock="${3:-$WORK/$1/sources.lock}"
  if [[ ! -s "$WORK/$c/sources.lock" ]]; then
    mkdir -p "$WORK/$c"
    python3 "$TESTLIB/fixture_inputs.py" "$WORK/$c/files" "$WORK/$c/sources.lock" "$c" > "$WORK/$c/fixture.log" 2>&1 \
      || { RC=99; cp "$WORK/$c/fixture.log" "$WORK/$c-$mode.log"; return; }
  fi
  run_real "$WORK/$c-$mode.log" python3 "$RV" "$mode" "$lock" "$WORK/$c/dl"
}
# no_part <case>: no .part file is left in the download folder.
no_part() { [[ -z "$(find "$WORK/$1/dl" -name '*.part' 2>/dev/null)" ]]; }

echo "== 1/4 the full fetch, one changed input at a time ================================="
entry packages/lib/runtime_verify.py:fetch
rv good fetch
check "ACCEPT a good set: key pin, signature, manifest pin, archive, members, guest pair and Firecracker" 0 "$RC" \
  "$WORK/good-fetch.log" '^runtime-verify all inputs verified$'
# The good fetch runs every guard of the file except the `field` and argument checks.
# shellcheck disable=SC2046
cover accept $(file_tags packages/lib/runtime_verify.py E_LOCK_FIELD E_ARGS E_INSTALLED E_INSTALLED_SHA256)
[[ -s "$WORK/good/dl/members/runtime-shim" ]] && cmp -s "$WORK/good/dl/members/runtime-shim" <(tar -xzOf "$WORK/good/files/nitro-sandboxes-runtime.tar.gz" containerd-shim-nitro-sandbox-v2)
check "  ... and the shim it reads out is the archive's member" 0 $? "$WORK/good-fetch.log"
while IFS='|' read -r c want tag why; do
  [[ -n "$c" ]] || continue
  rv "$c" fetch
  check "$why" "$want" "$RC" "$WORK/$c-fetch.log" "^ERROR: $tag: "
done <<'CASES'
checksum-changed|1|E_FILE_SHA256|REJECT a changed checksum: the runtime archive served is not the one the signed SHA256SUM lists
lock-pin-changed|1|E_ARCHIVE_SHA256|REJECT a changed checksum: the lock pins another archive SHA-256 than the signed SHA256SUM lists
signature-changed|1|E_SIGNATURE|REJECT a changed signature: one byte of SHA256SUM.sig changed
bad-sig|1|E_SIGNATURE|REJECT a changed signature: SHA256SUM signed with another key
manifest-changed|1|E_SIGNATURE|REJECT a SHA256SUM changed after it was signed, even with its pin changed to match
manifest-pin|1|E_MANIFEST_SHA256|REJECT a signed SHA256SUM that is not the one the lock pins
wrong-key|1|E_KEY_SHA256|REJECT a public key that is not the pinned nitro-sandboxes-runtime-v1.pub
shim-tampered|1|E_MEMBER_SHA256|REJECT a shim member that is not its pin, in an archive whose own hash the manifest lists
file-mismatch|1|E_FILE_SHA256|REJECT a guest image file that is not its pin, while its sidecar agrees with the pin
sidecar-mismatch|1|E_SIDECAR|REJECT a guest image sidecar that names another SHA-256
download-fails|2|E_DOWNLOAD|REJECT a download that fails, as could not check (exit 2), never as verified
manifest-bad-line|1|E_MANIFEST_FORMAT|REJECT a signed SHA256SUM with a line that is not a checksum line
member-missing|1|E_MEMBER|REJECT a runtime archive without a member that the signed SHA256SUM and the lock list
CASES
no_part download-fails
check "  ... and a failed download leaves no .part file behind" 0 $? "$WORK/download-fails-fetch.log"

echo "== 2/4 check mode: a file that changes after the fetch, before the build uses it ======"
entry packages/lib/runtime_verify.py:check
rv good check
check "ACCEPT check mode on the files the good fetch left" 0 "$RC" "$WORK/good-check.log" '^runtime-verify all inputs verified$'
cp -r "$WORK/good" "$WORK/later"
printf 'changed after the fetch\n' >> "$WORK/later/dl/nitro-sandbox-guest-disk.img"
run_real "$WORK/later-check.log" python3 "$RV" check "$WORK/later/sources.lock" "$WORK/later/dl"
check "REJECT check mode on a guest disk image changed after the fetch" 1 "$RC" "$WORK/later-check.log" '^ERROR: E_FILE_SHA256: guest-image-disk: '
cp -r "$WORK/good" "$WORK/later-sig"
# One byte inside the DER signature changes (the last byte of s). An appended byte would not do:
# openssl dgst reads at most the key's maximum signature size, so a byte appended to a signature
# of that size is never read, and that case verified about one run in four.
python3 -c 'import sys; p = sys.argv[1]; b = bytearray(open(p, "rb").read()); b[-1] ^= 0x01; open(p, "wb").write(bytes(b))' \
  "$WORK/later-sig/dl/runtime-release.SHA256SUM.sig"
run_real "$WORK/later-sig-check.log" python3 "$RV" check "$WORK/later-sig/sources.lock" "$WORK/later-sig/dl"
check "REJECT check mode on a signature file changed after the fetch" 1 "$RC" "$WORK/later-sig-check.log" '^ERROR: E_SIGNATURE: '
cp -r "$WORK/good" "$WORK/sha512"
python3 - "$WORK/sha512/sources.lock" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p).read()
t = re.sub(r"(id=guest-image-eif\n(?:.*\n)*?sha512=)([0-9a-f])", lambda m: m.group(1) + ("1" if m.group(2) != "1" else "2"), t, count=1)
open(p, "w").write(t)
PY
run_real "$WORK/sha512-check.log" python3 "$RV" check "$WORK/sha512/sources.lock" "$WORK/sha512/dl"
check "REJECT a file whose SHA-256 matches but whose SHA-512 is not the lock's" 1 "$RC" "$WORK/sha512-check.log" '^ERROR: E_FILE_SHA512: guest-image-eif'
cp -r "$WORK/good" "$WORK/gone"
rm -f "$WORK/gone/dl/nitro-sandbox-guest.eif"
run_real "$WORK/gone-check.log" python3 "$RV" check "$WORK/gone/sources.lock" "$WORK/gone/dl"
check "REJECT check mode when a downloaded file is missing, as could not check (exit 2)" 2 "$RC" "$WORK/gone-check.log" '^ERROR: E_READ: guest-image-eif: '

echo "== 2b/4 installed: the guest pair and binaries on the written root volume ============"
entry packages/lib/runtime_verify.py:installed
# mkroot <dir>: a root holding each install= file of the good lock, from the good fetch, with its mode.
mkroot() {
  python3 - "$WORK/good/sources.lock" "$WORK/good/dl" "$1" <<'PY'
import os, re, shutil, sys
lock, dl, root = sys.argv[1:4]
for block in open(lock).read().split("\n\n"):
    kv = dict(l.split("=", 1) for l in block.splitlines() if re.match(r"^[a-z_0-9]+=", l))
    m = re.fullmatch(r"(/usr/\S+) (0[0-7]{3})", kv.get("install", "none"))
    if not m:
        continue
    src = os.path.join(dl, "members", kv["id"]) if kv["kind"] == "archive-member" else os.path.join(dl, kv["file"])
    dst = root + m.group(1)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    os.chmod(dst, int(m.group(2), 8))
PY
}
mkroot "$WORK/root-good"
run_real "$WORK/inst-good.log" python3 "$RV" installed "$WORK/good/sources.lock" "$WORK/root-good"
check "ACCEPT the written root: every install= file at its path, with its mode and its pinned SHA-256" 0 "$RC" "$WORK/inst-good.log" '^runtime-verify installed /usr/share/nitro-sandbox/latest-disk\.img mode=0644 sha256=[0-9a-f]{64} ok$'
cover accept E_INSTALLED E_INSTALLED_SHA256
cp -r "$WORK/root-good" "$WORK/root-missing"; rm -f "$WORK/root-missing/usr/share/nitro-sandbox/latest.eif"
run_real "$WORK/inst-missing.log" python3 "$RV" installed "$WORK/good/sources.lock" "$WORK/root-missing"
check "REJECT a root without the guest EIF" 1 "$RC" "$WORK/inst-missing.log" '^ERROR: E_INSTALLED: guest-image-eif: /usr/share/nitro-sandbox/latest.eif is not on the image'
cp -r "$WORK/root-good" "$WORK/root-mode"; chmod 0644 "$WORK/root-mode/usr/bin/containerd-shim-nitro-sandbox-v2"
run_real "$WORK/inst-mode.log" python3 "$RV" installed "$WORK/good/sources.lock" "$WORK/root-mode"
check "REJECT a shim that is not mode 0755" 1 "$RC" "$WORK/inst-mode.log" '^ERROR: E_INSTALLED: runtime-shim: .* has mode 0644, not 0755'
cp -r "$WORK/root-good" "$WORK/root-sha"; printf 'x' >> "$WORK/root-sha/usr/share/nitro-sandbox/latest-disk.img"
run_real "$WORK/inst-sha.log" python3 "$RV" installed "$WORK/good/sources.lock" "$WORK/root-sha"
check "REJECT a guest disk image on the root whose SHA-256 is not the pin" 1 "$RC" "$WORK/inst-sha.log" '^ERROR: E_INSTALLED_SHA256: guest-image-disk: '
cp -r "$WORK/root-good" "$WORK/root-link"; rm -f "$WORK/root-link/usr/bin/jailer"; ln -s firecracker "$WORK/root-link/usr/bin/jailer"
run_real "$WORK/inst-link.log" python3 "$RV" installed "$WORK/good/sources.lock" "$WORK/root-link"
check "REJECT an installed file that is a link" 1 "$RC" "$WORK/inst-link.log" '^ERROR: E_INSTALLED: jailer: '

echo "== 3/4 the lock itself ================================================================"
mkdir -p "$WORK/lock"
cp "$WORK/good/sources.lock" "$WORK/lock/dup-key.lock"; cp "$WORK/good/fixture-runtime-v1.pub" "$WORK/lock/" 2>/dev/null
sed -i '0,/^ref=fixture$/s//ref=fixture\nref=again/' "$WORK/lock/dup-key.lock"
run_real "$WORK/dup-key.log" python3 "$RV" check "$WORK/lock/dup-key.lock" "$WORK/good/dl"
check "REJECT a lock block with a key twice" 1 "$RC" "$WORK/dup-key.log" '^ERROR: E_LOCK_DUPLICATE_KEY: '
cp "$WORK/good/sources.lock" "$WORK/lock/kind.lock"
sed -i 's/^kind=sidecar-file$/kind=unchecked-file/' "$WORK/lock/kind.lock"
run_real "$WORK/kind.log" python3 "$RV" check "$WORK/lock/kind.lock" "$WORK/good/dl"
check "REJECT a lock block of an unknown kind (no kind skips a check)" 1 "$RC" "$WORK/kind.log" '^ERROR: E_LOCK_KIND: '
cp "$WORK/good/sources.lock" "$WORK/lock/nosha.lock"
sed -i '/^id=firecracker-release$/,/^$/{/^sha256=/d}' "$WORK/lock/nosha.lock"
run_real "$WORK/nosha.log" python3 "$RV" check "$WORK/lock/nosha.lock" "$WORK/good/dl"
check "REJECT a file block with no sha256= (a pin cannot be left out)" 1 "$RC" "$WORK/nosha.log" '^ERROR: E_LOCK_FORMAT: firecracker-release: sha256 is missing'
cp "$WORK/good/sources.lock" "$WORK/lock/dup-id.lock"
printf '\nid=jailer\nkind=archive-member\narchive=firecracker-release\nref=again\nmember=release-vfx-x86_64/jailer-vfx-x86_64\nsource=member of firecracker-release\nsha256=%064d\nstatus=available\n' 0 >> "$WORK/lock/dup-id.lock"
run_real "$WORK/dup-id.log" python3 "$RV" check "$WORK/lock/dup-id.lock" "$WORK/good/dl"
check "REJECT a lock with two blocks of the same id" 1 "$RC" "$WORK/dup-id.log" '^ERROR: E_LOCK_DUPLICATE_ID: jailer'
run_real "$WORK/args.log" python3 "$RV" check "$WORK/good/sources.lock" "$WORK/good/dl" extra-argument
check "REJECT check with an extra argument" 1 "$RC" "$WORK/args.log" '^ERROR: E_ARGS: '
run_real "$WORK/nolock.log" python3 "$RV" check "$WORK/lock/absent.lock" "$WORK/good/dl"
check "REJECT a lock that cannot be read, as could not check (exit 2)" 2 "$RC" "$WORK/nolock.log" '^ERROR: E_LOCK_READ: '
CB_SOURCES_LOCK="$WORK/good/sources.lock" run_real "$WORK/dash.log" python3 "$RV" check - "$WORK/good/dl"
check "ACCEPT '-' as the lock named by CB_SOURCES_LOCK" 0 "$RC" "$WORK/dash.log" '^runtime-verify all inputs verified$'
CB_SOURCES_LOCK="$WORK/bad-sig/sources.lock" run_real "$WORK/dash-bad.log" python3 "$RV" check - "$WORK/bad-sig/dl"
check "REJECT '-' when CB_SOURCES_LOCK names a set with a bad signature" 1 "$RC" "$WORK/dash-bad.log" '^ERROR: E_SIGNATURE: '

echo "== 4/4 the real packages/sources.lock ================================================"
entry packages/lib/runtime_verify.py:field
run_real "$WORK/real-field.log" python3 "$RV" field "$SAMPLE_DIR_REAL/packages/sources.lock" runtime-release public_key
check "ACCEPT the tracked sources.lock: it parses and names the runtime key file" 0 "$RC" "$WORK/real-field.log" '^nitro-sandboxes-runtime-v1\.pub$'
cover accept E_LOCK_FIELD E_ARGS
key_pin="$(python3 "$RV" field "$SAMPLE_DIR_REAL/packages/sources.lock" runtime-release public_key_sha256 2>/dev/null)"
[[ -n "$key_pin" && "$(sha256sum "$SAMPLE_DIR_REAL/packages/nitro-sandboxes-runtime-v1.pub" | cut -d' ' -f1)" == "$key_pin" ]]
check "ACCEPT the tracked runtime public key: its SHA-256 is the one the tracked lock pins" 0 $? "$WORK/real-field.log"
run_real "$WORK/real-field-bad.log" python3 "$RV" field "$SAMPLE_DIR_REAL/packages/sources.lock" runtime-release no_such_key
check "REJECT a field the tracked lock does not have" 1 "$RC" "$WORK/real-field-bad.log" '^ERROR: E_LOCK_FIELD: '
finish
