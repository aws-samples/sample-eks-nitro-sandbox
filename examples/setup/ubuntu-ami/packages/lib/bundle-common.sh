# bundle-common.sh: sourced by make-bundle.sh and test-bundle.sh. Holds the helpers for
# building and consuming the deterministic dependency bundle: fetch-and-verify against a
# lock file, deterministic archive creation, SBOM/provenance manifest emission, and
# offline bundle verification. Sourced, never executed; callers set `set -euo pipefail`
# and keep LOCK_FILE / BUNDLE_LOCK_FILE pointed at the lock file this run uses.
#
# This file deliberately duplicates nothing from scripts/lib/common.sh's AWS/EKS-specific
# defaults: the bundle command has no cluster, no namespace and no AWS call anywhere in it,
# by design (see docs: this input is pure file-fetch-and-archive). It re-implements only
# the two primitives it shares with that file (log/die and lock_field-style parsing) so it
# has no path dependency on scripts/lib/common.sh and can run standalone, from CI or from a
# restricted-network host that has only this bundle to consume.

BUNDLE_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bundle_log()  { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
bundle_die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
bundle_warn() { printf 'WARN: %s\n' "$*" >&2; }

# bundle_lock_field <lock-file> <id> <field> : same block-parsing convention as
# scripts/lib/common.sh's lock_field, kept local here so this helper has no path
# dependency on that file. Multi-line fields (verify=) return only the first line.
bundle_lock_field() { # bundle_lock_field <lock-file> <id> <field>
  local lock_file="$1" id="$2" field="$3" in_block=0 val=""
  while IFS='=' read -r k v; do
    case "$k" in
      id) if [[ "$v" == "$id" ]]; then in_block=1; else in_block=0; fi ;;
      "") in_block=0 ;;
      "$field") [[ "$in_block" == 1 ]] && { val="$v"; } ;;
    esac
  done < "$lock_file"
  [[ -n "$val" ]] || return 1
  printf '%s\n' "$val"
}

# bundle_lock_ids <lock-file> : print one id= value per block, in file order. Used to
# iterate "every input in this lock file" without hard-coding the id list in the command.
bundle_lock_ids() { # bundle_lock_ids <lock-file>
  awk -F= '/^id=/{print $2}' "$1"
}

# bundle_verify_sha256 <file> <expected-sha256> <label> : fail closed on any mismatch, no
# override flag. Mirrors scripts/lib/common.sh's verify_sha256 but names the bundle step
# in its error so a failure here reads distinctly from a build-time verify failure.
bundle_verify_sha256() {
  local file="$1" expected="$2" label="${3:-$1}" actual
  [[ -s "$file" ]] || bundle_die "bundle: missing or empty file for $label: $file"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    bundle_die "bundle: SHA-256 mismatch for $label ($file)
  expected: $expected
  actual:   $actual
This input does not match the lock file pin. Do not use it: either the fetch is corrupt
(re-fetch) or the upstream artifact changed (re-pin deliberately, see sources.lock). There
is no override flag."
  fi
  bundle_log "verified sha256 for $label: $actual"
}

# bundle_fetch_file <lock-file> <id> <dest-dir> : fetch a kind=file input named in the lock
# file to <dest-dir>/<id>-<ref>.<ext-inferred-from-source-url>, verify it against the
# pinned sha256, and print the resulting path. Caches: a destination file that already
# verifies is reused rather than re-fetched. Fails closed on a missing ref/source/sha256,
# a TODO-* or n/a placeholder sha256, or a mismatch.
bundle_fetch_file() { # bundle_fetch_file <lock-file> <id> <dest-dir>
  local lock_file="$1" id="$2" dest_dir="$3"
  local ref source_url expected_sha ext file dest_file
  ref="$(bundle_lock_field "$lock_file" "$id" ref)" || bundle_die "sources.lock has no ref= for $id"
  source_url="$(bundle_lock_field "$lock_file" "$id" source)" || bundle_die "sources.lock has no source= for $id"
  expected_sha="$(bundle_lock_field "$lock_file" "$id" sha256)" || bundle_die "sources.lock has no sha256= for $id"
  case "$expected_sha" in
    TODO-*|n/a)
      bundle_die "sources.lock has no concrete sha256 pin for $id (value: $expected_sha); this input is not a bundleable public file yet" ;;
  esac
  case "$source_url" in
    *.tar.gz) ext=tar.gz ;;
    *.tar.xz) ext=tar.xz ;;
    *.tar.bz2) ext=tar.bz2 ;;
    *.tgz) ext=tgz ;;
    *) ext="${source_url##*.}" ;;
  esac
  file="${id}-${ref}.${ext}"
  dest_file="$dest_dir/$file"
  mkdir -p "$dest_dir"
  if [[ -s "$dest_file" ]] && echo "$expected_sha  $dest_file" | sha256sum -c --status 2>/dev/null; then
    bundle_log "cached and verified: $file"
  else
    bundle_log "fetching $id from $source_url"
    curl -fsSL --retry 5 --retry-delay 3 -o "$dest_file" "$source_url"
    bundle_verify_sha256 "$dest_file" "$expected_sha" "$id"
  fi
  printf '%s\n' "$dest_file"
}

# bundle_sha256_of <file> : print just the hex digest.
bundle_sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# bundle_create_archive <output-tar> <staging-dir> : create a deterministic tar from every
# regular file directly inside <staging-dir> (one level, no subdirectories expected: the
# bundle stages each fetched artifact as a flat file named by bundle_fetch_file, plus the
# manifest/SBOM files bundle_write_manifest adds alongside). Deterministic means: stable
# member order (sorted by name), fixed mtime/owner/group/numeric-ids, and no
# host-dependent metadata (user/group names, ACLs, extended attributes), so a second run
# over the same inputs produces a byte-identical archive and therefore the same SHA-256.
# GNU tar is required for --sort=name and --mtime; this is noted in the command's own
# --help and in evidence-bundle.md, not silently assumed.
bundle_create_archive() { # bundle_create_archive <output-tar> <staging-dir>
  local out="$1" staging="$2"
  command -v tar >/dev/null 2>&1 || bundle_die "tar is required"
  tar --version 2>/dev/null | grep -q GNU || bundle_warn "non-GNU tar detected; --sort=name/--mtime may be unsupported, which breaks determinism"

  local -a members=()
  while IFS= read -r -d '' member; do
    members+=("$member")
  done < <(cd "$staging" && find . -maxdepth 1 -type f -printf '%P\0' | LC_ALL=C sort -z)
  [[ "${#members[@]}" -gt 0 ]] || bundle_die "bundle: nothing to archive in $staging"

  tar \
    --sort=name \
    --mtime='2024-01-01 00:00:00Z' \
    --owner=0 --group=0 --numeric-owner \
    --pax-option='exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime' \
    -C "$staging" \
    -cf "$out" \
    -- "${members[@]}"
  bundle_log "created deterministic archive: $out (sha256 $(bundle_sha256_of "$out"))"
}

# bundle_write_manifest <manifest-json> <lock-file> <staging-dir> <archive-file>
#   <components-csv>
# Emit the machine-checkable SBOM + license summary + provenance record as one JSON
# document. <components-csv> is a semicolon-separated list of "id" tokens that were
# actually bundled (so the manifest lists exactly what is in the archive, not every block
# in the lock file, which also carries the operator-supplied runtime archive this command
# never bundles).
bundle_write_manifest() { # bundle_write_manifest <manifest-json> <lock-file> <staging-dir> <archive-file> <components-csv> <command-version>
  local manifest="$1" lock_file="$2" staging="$3" archive="$4" components_csv="$5" cmd_version="$6"
  local tmp
  tmp="$(mktemp)"
  {
    printf '{\n'
    printf '  "bundle_format_version": "1.0",\n'
    printf '  "generated_at": "%s",\n' "$(date -u +%FT%TZ)"
    printf '  "generated_by": "packages/make-bundle.sh %s",\n' "$cmd_version"
    printf '  "lock_file": "%s",\n' "$(basename "$lock_file")"
    printf '  "archive": {\n'
    printf '    "path": "%s",\n' "$(basename "$archive")"
    printf '    "sha256": "%s"\n' "$(bundle_sha256_of "$archive")"
    printf '  },\n'
    printf '  "components": [\n'
    local first=1 id ref source sha license
    IFS=';' read -ra ids <<< "$components_csv"
    for id in "${ids[@]}"; do
      [[ -n "$id" ]] || continue
      ref="$(bundle_lock_field "$lock_file" "$id" ref)" || ref="unknown"
      source="$(bundle_lock_field "$lock_file" "$id" source)" || source="unknown"
      sha="$(bundle_lock_field "$lock_file" "$id" sha256)" || sha="unknown"
      license="$(bundle_lock_field "$lock_file" "$id" license)" || license="see-upstream-source"
      [[ "$first" == 1 ]] && first=0 || printf ',\n'
      printf '    {\n'
      printf '      "id": "%s",\n' "$id"
      printf '      "version": "%s",\n' "$ref"
      printf '      "source_url": "%s",\n' "$source"
      printf '      "sha256": "%s",\n' "$sha"
      printf '      "license": "%s"\n' "$license"
      printf '    }'
    done
    printf '\n  ],\n'
    # Every kind=file input that is not a public, fetchable one (status other than available,
    # e.g. the operator-supplied runtime archive) is listed as an external slot this bundle
    # never fetches, embeds or commits, read from the lock file rather than hard-coded.
    printf '  "external_unbundled_slots": [\n'
    local sfirst=1 sid skind sstatus sfile ssha
    while IFS= read -r sid; do
      [[ -n "$sid" ]] || continue
      skind="$(bundle_lock_field "$lock_file" "$sid" kind)" || continue
      sstatus="$(bundle_lock_field "$lock_file" "$sid" status)" || continue
      [[ "$skind" == file && "$sstatus" != available ]] || continue
      sfile="$(bundle_lock_field "$lock_file" "$sid" file)" || sfile="unknown"
      ssha="$(bundle_lock_field "$lock_file" "$sid" sha256)" || ssha="unknown"
      [[ "$sfirst" == 1 ]] && sfirst=0 || printf ',\n'
      printf '    {\n'
      printf '      "id": "%s",\n' "$sid"
      printf '      "status": "%s",\n' "$sstatus"
      printf '      "file": "%s",\n' "$sfile"
      printf '      "sha256": "%s",\n' "$ssha"
      printf '      "note": "Not a public download. This bundle command never fetches, embeds or commits it; the operator places it at RUNTIME_ARTIFACTS_DIR and the build verifies it against sources.lock."\n'
      printf '    }'
    done < <(bundle_lock_ids "$lock_file")
    printf '\n  ],\n'
    printf '  "license_summary": "Each component license is recorded per-component above (license=upstream SPDX-style identifier or note from sources.lock; distro packages are not included in this file-bundle). This bundle redistributes upstream source archives unmodified; see each component source_url for its own license text.",\n'
    printf '  "provenance": {\n'
    printf '    "fetched_by": "packages/make-bundle.sh",\n'
    printf '    "fetched_from": "public URLs recorded per-component above, no internal or private source",\n'
    printf '    "verification": "each component SHA-256-verified against sources.lock before being added to the archive; fails closed on any mismatch, no override flag"\n'
    printf '  }\n'
    printf '}\n'
  } > "$tmp"
  mv "$tmp" "$manifest"
  bundle_log "wrote manifest: $manifest"
}

# bundle_member_name <lock-file> <id> : the archive member name bundle_fetch_file gives an
# input, <id>-<ref>.<ext>, derived from the lock file alone.
bundle_member_name() {
  local lock_file="$1" id="$2" ref source_url ext
  ref="$(bundle_lock_field "$lock_file" "$id" ref)" || return 1
  source_url="$(bundle_lock_field "$lock_file" "$id" source)" || return 1
  case "$source_url" in
    *.tar.gz) ext=tar.gz ;;
    *.tar.xz) ext=tar.xz ;;
    *.tar.bz2) ext=tar.bz2 ;;
    *.tgz) ext=tgz ;;
    *) ext="${source_url##*.}" ;;
  esac
  printf '%s-%s.%s\n' "$id" "$ref" "$ext"
}

# bundle_expected <lock-file> : one "<id> <ref> <sha256> <member-name>" line per input the
# lock file says belongs in a bundle (kind=file, status=available, a concrete SHA-256): the same
# rule `make-bundle.sh build` applies.
bundle_expected() {
  local lock_file="$1" id kind status sha ref
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    kind="$(bundle_lock_field "$lock_file" "$id" kind)" || continue
    status="$(bundle_lock_field "$lock_file" "$id" status)" || continue
    sha="$(bundle_lock_field "$lock_file" "$id" sha256)" || continue
    [[ "$kind" == file && "$status" == available && "$sha" =~ ^[0-9a-f]{64}$ ]] || continue
    ref="$(bundle_lock_field "$lock_file" "$id" ref)" || bundle_die "sources.lock has no ref= for $id"
    printf '%s %s %s %s\n' "$id" "$ref" "$sha" "$(bundle_member_name "$lock_file" "$id")"
  done < <(bundle_lock_ids "$lock_file")
}

# bundle_verify_archive <archive-file> <manifest-json> <lock-file> <extract-dir> : offline-consume
# path. sources.lock is the TRUST ROOT; the manifest and the archive are only accepted where they
# agree with it. Fails closed (non-zero exit, clear message, nothing extracted) unless:
#   1. the archive and the manifest exist and parse;
#   2. the manifest's components are EXACTLY the inputs the lock file says belong in a bundle,
#      each with the lock's version and SHA-256 (a self-consistent archive plus manifest that
#      disagree with the lock are refused);
#   3. the archive's SHA-256 is the one its manifest records;
#   4. BEFORE anything is extracted, the archive's members are exactly the member names derived
#      from the lock, each once, each a regular file with a flat name (no folder, no '..', no
#      link, no device);
#   5. after extraction, every file's SHA-256 is its lock pin.
# Never falls back to fetching: a restricted-network consumer gets a hard failure, not a retry
# that silently reaches the internet.
bundle_verify_archive() { # bundle_verify_archive <archive-file> <manifest-json> <lock-file> <extract-dir>
  local archive="$1" manifest="$2" lock_file="$3" extract_dir="$4"
  [[ -s "$archive" ]] || bundle_die "bundle-verify: missing or empty archive: $archive"
  [[ -s "$manifest" ]] || bundle_die "bundle-verify: missing or empty manifest: $manifest"
  [[ -s "$lock_file" ]] || bundle_die "bundle-verify: missing or empty lock file: $lock_file"
  command -v python3 >/dev/null 2>&1 || bundle_die "bundle-verify: python3 is required to parse the manifest"

  local expected
  expected="$(bundle_expected "$lock_file")"
  [[ -n "$expected" ]] || bundle_die "bundle-verify: $lock_file names no bundleable input; refusing to accept a bundle"

  mkdir -p "$extract_dir"
  printf '%s\n' "$expected" | python3 "$BUNDLE_LIB_HERE/bundle_verify.py" "$archive" "$manifest" "$extract_dir" \
    || bundle_die "bundle-verify: rejected (see the message above); nothing from $archive is accepted"
  bundle_log "bundle verified offline against $(basename "$lock_file"): $(printf '%s\n' "$expected" | wc -l) component(s), extracted to $extract_dir"
}
