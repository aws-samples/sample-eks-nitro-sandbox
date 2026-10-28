#!/usr/bin/env bash
# fetch-runtime-artifacts.sh: check for the Nitro sandbox runtime archive (the binaries and
# the guest image, one flat zip) at the path config.env names, verify it against
# packages/sources.lock, unpack it, and verify every payload.
#
#   packages/fetch-runtime-artifacts.sh
#
# The archive is an operator-supplied preview archive, checksum-pinned, with no public download, so this script never
# downloads it. The operator obtains nitro-sandbox-binaries-2026-10-28.zip from their AWS account team
# and places it at RUNTIME_ARTIFACTS_DIR/RUNTIME_ARTIFACT_FILE. When it is absent this script
# prints the documented prerequisite and exits 3, which setup.sh and 00-preflight.sh treat as
# the documented stop, not a build failure.
#
# When it is present, every check below fails closed (exit 1, no override flag):
#   1. the archive's SHA-256 is the runtime-archive pin;
#   2. every zip member is a plain regular file with a flat, safe name (no folder, no '..',
#      no link), and no name appears twice;
#   3. after unpacking into a fresh RUNTIME_ARTIFACTS_DIR/unpacked: SHA256SUMS is present,
#      every line is '<sha256>  <file name>', no file is listed twice, it lists exactly the
#      unpacked files (nothing unlisted, nothing missing), and `sha256sum -c --strict` passes;
#   4. the listed files are exactly the runtime-payload blocks in sources.lock, and every
#      payload's SHA-256 is its pin there, so an archive whose SHA256SUMS was edited to match a
#      changed payload is still refused.
# On success it prints the verified unpacked directory.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/lib/common.sh"

if [[ -z "${RUNTIME_ARTIFACT_FILE:-}" ]]; then
  RUNTIME_ARTIFACT_FILE="$(lock_field runtime-archive file)" || die "packages/sources.lock has no file= for runtime-archive"
fi
ARCHIVE="$RUNTIME_ARTIFACTS_DIR/$RUNTIME_ARTIFACT_FILE"
UNPACKED="$RUNTIME_ARTIFACTS_DIR/unpacked"

prerequisite_message() {
  cat <<MSG
PREREQUISITE NOT MET: the Nitro sandbox runtime archive is required and was not found at
  $ARCHIVE
The archive (the containerd shim and CRI proxy, Firecracker and its jailer, the guest boot
image and root disk, the policy generator, the key provider and the guest agent) is an
operator-supplied preview archive, checksum-pinned, with no public download. This sample never downloads it and never substitutes an
internal source tree or a private URL for it.

To proceed:
  1. Obtain $(lock_field runtime-archive file 2>/dev/null || echo 'the runtime archive') from your AWS account team.
  2. Place it at RUNTIME_ARTIFACTS_DIR (now: $RUNTIME_ARTIFACTS_DIR). The default is the
     repository's gitignored tmp/issue10/run/runtime; never put it in the sample folder.
  3. Re-run this script, then ./setup.sh. It checks the archive against packages/sources.lock.
MSG
}

if [[ ! -s "$ARCHIVE" ]]; then
  prerequisite_message
  exit 3
fi

# --- 1. The archive itself ---------------------------------------------------------------------
archive_sha="$(lock_field runtime-archive sha256)" || die "packages/sources.lock has no sha256= for runtime-archive"
[[ "$archive_sha" =~ ^[0-9a-f]{64}$ ]] || die "packages/sources.lock runtime-archive sha256 is not a SHA-256: $archive_sha"
verify_sha256 "$ARCHIVE" "$archive_sha"

# The payloads sources.lock pins: "<file name> <sha256>" per runtime-payload block.
pins=""
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  pf="$(lock_field "$id" file)"   || die "packages/sources.lock block $id has no file="
  ps="$(lock_field "$id" sha256)" || die "packages/sources.lock block $id has no sha256="
  [[ "$pf" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "packages/sources.lock block $id file= is not a plain file name: $pf"
  [[ "$ps" =~ ^[0-9a-f]{64}$ ]] || die "packages/sources.lock block $id sha256 is not a SHA-256: $ps"
  pins+="$pf $ps"$'\n'
done < <(lock_ids_where kind runtime-payload)
[[ -n "$pins" ]] || die "packages/sources.lock has no runtime-payload blocks to check the archive against"

# --- 2. Zip members, before anything is written ------------------------------------------------
# python3's zipfile, not unzip: Canonical's EKS AMI ships python3 but not unzip, and this lets
# the member checks run on the listing before a single byte is extracted.
command -v python3 >/dev/null 2>&1 || die "python3 is required to read the runtime archive"
rm -rf "$UNPACKED"
mkdir -p "$UNPACKED"
python3 - "$ARCHIVE" "$UNPACKED" <<'PY' || die "the runtime archive's members are not a flat set of plain files; refusing to unpack it (see the message above)"
import re, stat, sys, zipfile
archive, dest = sys.argv[1], sys.argv[2]
safe = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
with zipfile.ZipFile(archive) as z:
    infos = z.infolist()
    names = [i.filename for i in infos]
    bad = []
    for i in infos:
        # Unix type bits, when the zip writer recorded them (many record permissions only, type 0):
        # anything other than a regular file (a link, a device, a folder) is refused.
        fmt = stat.S_IFMT(i.external_attr >> 16)
        if i.is_dir() or not safe.match(i.filename) or (fmt and fmt != stat.S_IFREG):
            bad.append(i.filename)
    dups = sorted({n for n in names if names.count(n) > 1})
    if bad:
        print("the runtime archive has members that are not plain, flat file names: " + ", ".join(map(repr, bad)), file=sys.stderr)
        sys.exit(1)
    if dups:
        print("the runtime archive has more than one member named: " + ", ".join(dups), file=sys.stderr)
        sys.exit(1)
    for i in infos:
        z.extract(i, dest)
PY

# --- 3. SHA256SUMS covers exactly what was unpacked, and every hash matches -------------------
cd "$UNPACKED"
[[ -s SHA256SUMS ]] || die "the runtime archive has no SHA256SUMS"
if bad_lines="$(grep -vE '^[0-9a-f]{64}  [A-Za-z0-9][A-Za-z0-9._-]*$' SHA256SUMS)"; then
  die "SHA256SUMS has lines that are not '<sha256>  <file name>':
$bad_lines"
fi
listed="$(sed -E 's/^[0-9a-f]{64}  //' SHA256SUMS | LC_ALL=C sort)"
dups="$(printf '%s\n' "$listed" | uniq -d)"
[[ -z "$dups" ]] || die "SHA256SUMS lists a file more than once: $dups"
unpacked_names="$(find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | LC_ALL=C sort)"
[[ "$listed" == "$unpacked_names" ]] || die "SHA256SUMS does not cover exactly the unpacked files (< listed, > unpacked):
$(diff <(printf '%s\n' "$listed") <(printf '%s\n' "$unpacked_names") || true)"
sha256sum -c --strict --quiet SHA256SUMS || die "a payload in the runtime archive does not match its SHA256SUMS line (see the FAILED line above)"

# --- 4. The same set, and the same hashes, as sources.lock pins --------------------------------
pinned_names="$(printf '%s' "$pins" | awk '{print $1}' | LC_ALL=C sort)"
[[ "$listed" == "$pinned_names" ]] || die "the runtime archive's payloads are not the set packages/sources.lock pins (< archive, > sources.lock):
$(diff <(printf '%s\n' "$listed") <(printf '%s\n' "$pinned_names") || true)"
while read -r pf ps; do
  [[ -n "$pf" ]] || continue
  got="$(sha256sum "$pf" | awk '{print $1}')"
  [[ "$got" == "$ps" ]] || die "payload $pf has SHA-256 $got, not the $ps packages/sources.lock pins (the archive's own SHA256SUMS agreed with the file, so the archive was re-packed)"
done <<< "$pins"

log "runtime archive $RUNTIME_ARTIFACT_FILE verified: $(printf '%s\n' "$listed" | wc -l) payloads match SHA256SUMS and packages/sources.lock; unpacked in $UNPACKED"
printf '%s\n' "$UNPACKED"
