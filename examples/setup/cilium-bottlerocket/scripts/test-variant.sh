#!/usr/bin/env bash
# test-variant.sh: proves variant/register-variant.py both ways, the REAL file, on a stand-in
# Bottlerocket clone (scripts/testlib/fixture_br_clone.py) and copies of the overlay under the work
# folder (never the tracked files):
#   apply       --slots 1 to 250; the clone at the pinned commit and tag, and clean; the stock
#               variant plus the four edits equals the tracked variant; the external-files SHA-512
#               values of the package equal sources.lock (E_PACKAGE_FILES, with the exact
#               `  # pragma: allowlist secret` suffix only); every registration matches once
#   check-lock  Cargo.lock keeps every package and adds exactly the two path crates
# With CB_TESTS_BOTTLEROCKET_CLONE=<a clone of bottlerocket v1.70.0>, the accept case also runs on a
# copy of it.
#
#   examples/setup/cilium-bottlerocket/scripts/test-variant.sh
source "$(dirname "$0")/testlib/harness.sh"
RV="$SAMPLE_DIR_REAL/variant/register-variant.py"
need_file "$RV" "every register-variant.py case" || finish

# fresh <name>: a stand-in clone at $WORK/<name>/clone, its lock, and a copy of the overlay.
fresh() {
  local d="$WORK/$1"
  rm -rf "$d"; mkdir -p "$d"
  python3 "$TESTLIB/fixture_br_clone.py" "$SAMPLE_DIR_REAL" "$d/clone" "$d/sources.lock" > "$d/fixture.log" 2>&1 || cat "$d/fixture.log"
  cp -r "$SAMPLE_DIR_REAL/variant" "$d/overlay"
  C="$d/clone" L="$d/sources.lock" O="$d/overlay"
}
apply() { local log="$1"; shift; run_real "$log" python3 "$RV" apply --clone "$C" --overlay "$O" --lock "$L" "$@"; }
gitc() { git -C "$C" -c user.name=offline-test -c user.email=offline-test@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }

echo "== 1/4 apply: the good overlay ===================================================="
entry variant/register-variant.py:apply
fresh good
apply "$WORK/good.log" --slots 58
check "ACCEPT apply: pinned commit and tag, clean clone, the four variant edits, the package digests with the pragma suffix, five registrations" 0 "$RC" \
  "$WORK/good.log" '^register-variant variant=aws-k8s-1.36-nitro-sandbox slots=58 os_image_gib=[0-9]+ registrations=5 ok$'
cover accept E_INPUT_SANDBOX_SLOTS E_LOCK_FILE E_GIT E_CLONE_COMMIT E_CLONE_TAG E_CLONE_DIRTY E_VARIANT_DIFF E_EDIT E_PACKAGE_FILES E_READ
grep -qx 'pcie_slots      = 58' "$C/packages/nitro-sandbox/nitro-sandbox.toml" && ! grep -q '@' "$C/packages/nitro-sandbox/nitro-sandbox.toml" \
  && cmp -s "$C/variants/aws-k8s-1.36-nitro-sandbox/Cargo.toml" "$SAMPLE_DIR_REAL/variant/variants/aws-k8s-1.36-nitro-sandbox/Cargo.toml" \
  && [[ -L "$C/variants/aws-k8s-1.36-nitro-sandbox/amispec.toml" ]] && grep -q 'variant(aws-k8s-1.36-nitro-sandbox)' "$C/packages/settings-defaults/settings-defaults.spec"
check "  ... it writes pcie_slots = 58, the tracked variant, the amispec link and the registrations" 0 $? "$WORK/good.log"
grep -q '^+    "nitro_enclaves.mempool=95%-1G",$' "$WORK/good.log" && grep -q '^+os-image-size-gib = ' "$WORK/good.log"
check "  ... and prints the variant diff the page shows (mempool and os-image-size-gib lines)" 0 $? "$WORK/good.log"
for s in 1 250; do
  fresh "slots$s"; apply "$WORK/slots$s.log" --slots "$s"
  check "ACCEPT --slots $s (the ends of 1 to 250)" 0 "$RC" "$WORK/slots$s.log" "slots=$s "
done
if [[ -n "${CB_TESTS_BOTTLEROCKET_CLONE:-}" && -d "$CB_TESTS_BOTTLEROCKET_CLONE/.git" ]]; then
  fresh upstream; rm -rf "$C"; git clone -q "$CB_TESTS_BOTTLEROCKET_CLONE" "$C"; L="$SAMPLE_DIR_REAL/packages/sources.lock"
  gitc checkout -q v1.70.0 2>/dev/null
  apply "$WORK/upstream.log" --slots 58
  check "ACCEPT apply on a copy of the real bottlerocket v1.70.0 clone (CB_TESTS_BOTTLEROCKET_CLONE)" 0 "$RC" "$WORK/upstream.log" ' registrations=5 ok$'
fi

echo "== 2/4 apply: inputs, clone and variant =========================================="
for s in 0 251 abc 058; do
  fresh "badslots"; apply "$WORK/badslots.log" --slots "$s"
  check "REJECT --slots '$s'" 1 "$RC" "$WORK/badslots.log" '^ERROR: E_INPUT_SANDBOX_SLOTS: '
done
fresh nolock; sed -i '/^id=bottlerocket-source$/,/^$/d' "$L"; apply "$WORK/nolock.log" --slots 58
check "REJECT a lock with no bottlerocket-source block" 1 "$RC" "$WORK/nolock.log" '^ERROR: E_LOCK_FILE: no bottlerocket-source block'
fresh basevar; sed -i 's/^base_variant=aws-k8s-1.36$/base_variant=aws-k8s-1.35/' "$L"; apply "$WORK/basevar.log" --slots 58
check "REJECT a lock whose base variant is not aws-k8s-1.36" 1 "$RC" "$WORK/basevar.log" '^ERROR: E_LOCK_FILE: base_variant is aws-k8s-1.35'
fresh commit; printf 'later\n' >> "$C/README.md"; gitc commit -qam later; apply "$WORK/commit.log" --slots 58
check "REJECT a clone that is not at the pinned commit" 1 "$RC" "$WORK/commit.log" '^ERROR: E_CLONE_COMMIT: '
fresh tag; gitc tag -f -a v1.70.0 -m moved > /dev/null 2>&1; apply "$WORK/tag.log" --slots 58
check "REJECT a tag v1.70.0 that is not the pinned tag object (a moved tag)" 1 "$RC" "$WORK/tag.log" '^ERROR: E_CLONE_TAG: '
fresh dirty; printf 'x\n' > "$C/stray.txt"; apply "$WORK/dirty.log" --slots 58
check "REJECT a clone with changes before the overlay" 1 "$RC" "$WORK/dirty.log" '^ERROR: E_CLONE_DIRTY: the clone has changes'
# GIT_CEILING_DIRECTORIES keeps git from finding this checkout above the work folder.
fresh notgit; rm -rf "$C/.git"; GIT_CEILING_DIRECTORIES="$WORK/notgit" apply "$WORK/notgit.log" --slots 58
check "REJECT a clone that is not a git repository, as could not check (exit 2)" 2 "$RC" "$WORK/notgit.log" '^ERROR: E_GIT: '
fresh edit; sed -i '/^    "quiet",$/d' "$C/variants/aws-k8s-1.36/Cargo.toml"; gitc commit -qam edit
sed -i "s/^commit=[0-9a-f]\{40\}$/commit=$(gitc rev-parse HEAD)/" "$L"; gitc tag -f -a v1.70.0 -m t >/dev/null 2>&1
sed -i "s/^tag_object=[0-9a-f]\{40\}$/tag_object=$(gitc rev-parse refs/tags/v1.70.0)/" "$L"
apply "$WORK/edit.log" --slots 58
check "REJECT a stock variant where an edit does not match exactly once" 1 "$RC" "$WORK/edit.log" '^ERROR: E_EDIT: .*variants/aws-k8s-1.36/Cargo.toml'
fresh vdiff; printf '# one more line\n' >> "$O/variants/aws-k8s-1.36-nitro-sandbox/Cargo.toml"; apply "$WORK/vdiff.log" --slots 58
check "REJECT a tracked variant that differs from the stock one with the four edits" 1 "$RC" "$WORK/vdiff.log" '^ERROR: E_VARIANT_DIFF: '
fresh vsize; printf 'os-image-size-gib = 9\n' >> "$O/variants/aws-k8s-1.36-nitro-sandbox/Cargo.toml"; apply "$WORK/vsize.log" --slots 58
check "REJECT a tracked variant that sets os-image-size-gib twice" 1 "$RC" "$WORK/vsize.log" '^ERROR: E_VARIANT_DIFF: the tracked variant must set os-image-size-gib exactly once'
fresh readme; sed -i '/^\* `aws-k8s-1.36`$/d' "$C/README.md"; gitc commit -qam readme
sed -i "s/^commit=[0-9a-f]\{40\}$/commit=$(gitc rev-parse HEAD)/" "$L"; gitc tag -f -a v1.70.0 -m t >/dev/null 2>&1
sed -i "s/^tag_object=[0-9a-f]\{40\}$/tag_object=$(gitc rev-parse refs/tags/v1.70.0)/" "$L"
apply "$WORK/readme.log" --slots 58
check "REJECT a registration that does not match exactly once (README.md)" 1 "$RC" "$WORK/readme.log" '^ERROR: E_EDIT: README.md'
fresh noread; run_real "$WORK/noread.log" python3 "$RV" apply --clone "$C" --overlay "$WORK/noread/missing" --lock "$L" --slots 58
check "REJECT an overlay that cannot be read, as could not check (exit 2)" 2 "$RC" "$WORK/noread.log" '^ERROR: E_READ: '

echo "== 3/4 apply: the package digests (E_PACKAGE_FILES) ========================"
PC=packages/nitro-sandbox/Cargo.toml
while IFS='|' read -r sedexpr why; do
  [[ -n "$sedexpr" ]] || continue
  fresh pkg; sed -i -E "$sedexpr" "$O/$PC"
  apply "$WORK/pkg.log" --slots 58
  check "$why" 1 "$RC" "$WORK/pkg.log" '^ERROR: E_PACKAGE_FILES: '
done <<'CASES'
0,/^(sha512 = ")[0-9a-f]/s//\1f/|REJECT a wrong SHA-512 digest that keeps the pragma suffix
0,/  # pragma: allowlist secret$/s//  # another comment/|REJECT another trailing comment after the digest
0,/^sha512 = "[0-9a-f]{128}"/s//sha512 = ""/|REJECT an empty digest
0,/"  # pragma: allowlist secret$/s//" # pragma: allowlist secret/|REJECT one space, not two, before the pragma
CASES
grep -c '^sha512 = "[0-9a-f]\{128\}"  # pragma: allowlist secret$' "$SAMPLE_DIR_REAL/variant/$PC" > "$WORK/pragma.txt"
[[ "$(cat "$WORK/pragma.txt")" == 4 ]]
check "ACCEPT the tracked package: all four sha512 lines end with exactly '  # pragma: allowlist secret'" 0 $? "$WORK/pragma.txt"
fresh pkg-nopragma; sed -i -E 's/"  # pragma: allowlist secret$/"/' "$O/$PC"
apply "$WORK/pkg-nopragma.log" --slots 58
check "ACCEPT the digests with no pragma suffix at all (the regex suffix is optional)" 0 "$RC" "$WORK/pkg-nopragma.log" ' ok$'
fresh pkg-link; ln -s nitro-sandbox.spec "$O/packages/nitro-sandbox/a-link"; apply "$WORK/pkg-link.log" --slots 58
check "REJECT a package file that is a link" 1 "$RC" "$WORK/pkg-link.log" '^ERROR: E_PACKAGE_FILES: a-link is not a regular file'
fresh pkg-tmpl; printf 'x = "@OTHER@"\n' >> "$O/packages/nitro-sandbox/nitro-sandbox.toml"; apply "$WORK/pkg-tmpl.log" --slots 58
check "REJECT a nitro-sandbox.toml that keeps a template value" 1 "$RC" "$WORK/pkg-tmpl.log" '^ERROR: E_PACKAGE_FILES: nitro-sandbox.toml still has a template value'
fresh pkg-exists; mkdir -p "$C/packages/nitro-sandbox"; printf 'x\n' > "$C/packages/nitro-sandbox/.keep"; gitc add -A >/dev/null; gitc commit -qm pkg
sed -i "s/^commit=[0-9a-f]\{40\}$/commit=$(gitc rev-parse HEAD)/" "$L"; gitc tag -f -a v1.70.0 -m t >/dev/null 2>&1
sed -i "s/^tag_object=[0-9a-f]\{40\}$/tag_object=$(gitc rev-parse refs/tags/v1.70.0)/" "$L"
apply "$WORK/pkg-exists.log" --slots 58
check "REJECT a clone that already has the package folder" 1 "$RC" "$WORK/pkg-exists.log" '^ERROR: E_CLONE_DIRTY: the variant or the package exists'

echo "== 4/4 check-lock ===================================================================="
entry variant/register-variant.py:check-lock
mkdir -p "$WORK/lock"
printf '# header\nversion = 3\n\n[[package]]\nname = "alpha"\nversion = "1.0.0"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\n\n[[package]]\nname = "beta"\nversion = "0.1.0"\n' > "$WORK/lock/before"
{ cat "$WORK/lock/before"; printf '\n[[package]]\nname = "aws-k8s-1_36-nitro-sandbox"\nversion = "0.1.0"\n\n[[package]]\nname = "nitro-sandbox"\nversion = "0.1.0"\n'; } > "$WORK/lock/after"
run_real "$WORK/cl-ok.log" python3 "$RV" check-lock "$WORK/lock/before" "$WORK/lock/after"
check "ACCEPT a Cargo.lock that keeps every package and adds exactly the two path crates" 0 "$RC" "$WORK/cl-ok.log" '^register-variant cargo-lock added=aws-k8s-1_36-nitro-sandbox,nitro-sandbox ok$'
cover accept E_LOCK_CHANGED E_LOCK_FILE
while IFS='|' read -r sedexpr why; do
  [[ -n "$sedexpr" ]] || continue
  cp "$WORK/lock/after" "$WORK/lock/after-bad"; sed -i -E "$sedexpr" "$WORK/lock/after-bad"
  run_real "$WORK/cl-bad.log" python3 "$RV" check-lock "$WORK/lock/before" "$WORK/lock/after-bad"
  check "$why" 1 "$RC" "$WORK/cl-bad.log" '^ERROR: E_LOCK_CHANGED: '
done <<'CASES'
s/^version = "1.0.0"$/version = "1.0.1"/|REJECT a Cargo.lock that changed an existing package
s/^version = 3$/version = 4/|REJECT a Cargo.lock whose version line changed
$a\\n[[package]]\nname = "gamma"\nversion = "0.1.0"|REJECT a Cargo.lock that adds a third crate
/^name = "nitro-sandbox"$/a source = "registry+https://github.com/rust-lang/crates.io-index"|REJECT a new crate with a registry source
CASES
{ cat "$WORK/lock/after"; printf '\n[[package]]\nversion = "1"\n'; } > "$WORK/lock/noname"
run_real "$WORK/cl-noname.log" python3 "$RV" check-lock "$WORK/lock/before" "$WORK/lock/noname"
check "REJECT a Cargo.lock package block with no name, as could not check (exit 2)" 2 "$RC" "$WORK/cl-noname.log" '^ERROR: E_LOCK_FILE: '
finish
