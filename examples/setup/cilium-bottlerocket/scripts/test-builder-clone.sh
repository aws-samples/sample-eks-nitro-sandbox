#!/usr/bin/env bash
# test-builder-clone.sh: proves the checks of the builder stages fetch-verify
# (scripts/builder/20-fetch-verify.sh) and overlay (scripts/builder/30-overlay.sh) both ways, in
# the REAL files, on a fixture builder tree (SYSROOT, scripts/testlib/fixture_builder_sysroot.py)
# with stub commands first on PATH. No builder, no root, no network and no AWS call: the
# Bottlerocket clone is a stand-in git repository cloned over file://, the inputs are the
# file:// stand-ins of scripts/testlib/fixture_inputs.py, checked by the real runtime_verify.py
# with the real curl and openssl, and the overlay is the real register-variant.py.
#
# Safety: the suite refuses to run as root, and before each case it checks that every command
# that can write a disk or change the host (DISK_WRITERS) and every command this suite answers
# (STUBBED) resolves to this suite's stub folder on the exact PATH the stage runs with, with
# $SYSROOT/work/tools/cargo/bin first as lib.sh puts it; if one does not, the suite stops (exit 2).
# Each stub answers only the calls the stage makes; STUB_FAIL makes it fail one call:
#   mountpoint  answers `mountpoint -q $SYSROOT/work`; STUB_FAIL=mountpoint: not mounted
#   git         the real git, never for a network URL; STUB_FAIL=git-clone: the clone fails
#   ln          the real ln; STUB_FAIL=ln-disk: the link of the guest disk image fails
#   cargo       answers `cargo update --workspace --offline --quiet` by adding the two path
#               crates to Cargo.lock; STUB_FAIL=cargo-update: it fails; cargo-none: it adds
#               nothing; cargo-bump: it also changes a registry crate; cargo-other: it also
#               changes Makefile.toml
#
#   1  20-fetch-verify.sh  E_WORK_VOLUME E_CLONE E_CLONE_COMMIT E_CLONE_TAG E_TWOLITER E_INPUTS,
#                          and lib.sh tool_lock E_TOOLS_LOCK
#   2  30-overlay.sh       E_INPUT_SANDBOX_SLOTS E_CLONE E_INPUTS E_OVERLAY E_CARGO_LOCK
#
#   examples/setup/cilium-bottlerocket/scripts/test-builder-clone.sh
source "$(dirname "$0")/testlib/harness.sh"
STAGES="$SAMPLE_DIR_REAL/scripts/builder"
need_file "$STAGES/20-fetch-verify.sh" "every fetch-verify case" || finish
need_file "$STAGES/30-overlay.sh" "every overlay case" || finish
if [[ "$(id -u)" == 0 ]]; then
  echo "ERROR: $SUITE refuses to run as root: a builder stage run by root could write a real disk" >&2
  exit 2
fi
export PYTHONDONTWRITEBYTECODE=1 GIT_CEILING_DIRECTORIES="$WORK" CB_SYSBIN="$WORK/sysbin"

# ---- stubs -----------------------------------------------------------------------------------
BSTUB="$WORK/bstub"; mkdir -p "$BSTUB"
export BSTUB_LOG="$WORK/bstub.log"; : > "$BSTUB_LOG"
DISK_WRITERS=(dd sgdisk sfdisk parted partprobe mkfs mkfs.xfs mkfs.ext4 mkfs.erofs mount umount losetup
  blockdev wipefs blkdiscard udevadm modprobe systemctl dnf docker)
STUBBED=(mountpoint git ln cargo)
# Each disk writer is a stub that records its call and refuses it (exit 97).
for c in "${DISK_WRITERS[@]}"; do
  printf '#!/bin/sh\necho "%s $*" >> "$BSTUB_LOG"\necho "STUB %s: call not modelled by this case: $*" >&2\nexit 97\n' "$c" "$c" > "$BSTUB/$c"
  chmod 0755 "$BSTUB/$c"
done
# stub <name> <sh body>: a stub that records its call, then runs the body ("$@" are its arguments).
stub() {
  printf '#!/bin/sh\necho "%s $*" >> "$BSTUB_LOG"\n%s\n' "$1" "$2" > "$BSTUB/$1"
  chmod 0755 "$BSTUB/$1"
}
stub mountpoint '[ "$*" = "-q $SYSROOT/work" ] || { echo "STUB mountpoint: call not modelled: $*" >&2; exit 97; }
[ "${STUB_FAIL:-}" = mountpoint ] && exit 1
exit 0'
stub git 'case " $* " in *" https://"*|*" http://"*|*" ssh://"*|*" git://"*|*" git@"*)
  echo "STUB git: a network URL is refused: $*" >&2; exit 97 ;;
esac
if [ "${STUB_FAIL:-}" = git-clone ]; then
  case " $* " in *" clone "*) echo "fatal: STUB git: the clone failed" >&2; exit 128 ;; esac
fi
exec "$CB_SYSBIN/git" "$@"'
stub ln 'if [ "${STUB_FAIL:-}" = ln-disk ] && [ "$#" -eq 2 ] && [ "${2##*/}" = nitro-sandbox-guest-disk.img ]; then
  echo "ln: STUB: failed to create hard link $2" >&2; exit 1
fi
exec "$CB_SYSBIN/ln" "$@"'
stub cargo '[ "$*" = "update --workspace --offline --quiet" ] && [ -f Cargo.toml ] && [ -f Cargo.lock ] \
  || { echo "STUB cargo: call not modelled: $*" >&2; exit 97; }
case "${STUB_FAIL:-}" in
  cargo-update) echo "error: STUB cargo: update failed" >&2; exit 101 ;;
  cargo-none) exit 0 ;;
esac
printf "\n[[package]]\nname = \"aws-k8s-1_36-nitro-sandbox\"\nversion = \"0.1.0\"\ndependencies = [\n \"nitro-sandbox\",\n]\n\n[[package]]\nname = \"nitro-sandbox\"\nversion = \"0.1.0\"\n" >> Cargo.lock
case "${STUB_FAIL:-}" in
  cargo-bump) sed -i "s/^version = \"1.0.228\"\$/version = \"1.0.229\"/" Cargo.lock ;;
  cargo-other) printf "# changed by the build\n" >> Makefile.toml ;;
esac
exit 0'
BPATH="$BSTUB:$PATH"
# assert_stubs <PATH>: every disk writer and every answered command on that PATH is this suite's
# stub, else stop the suite.
assert_stubs() {
  local c p
  for c in "${DISK_WRITERS[@]}" "${STUBBED[@]}"; do
    p="$(PATH="$1" command -v "$c" 2>/dev/null || true)"
    if [[ "$p" != "$BSTUB/$c" ]]; then
      echo "ERROR: $SUITE: $c resolves to '${p:-nothing}', not $BSTUB/$c; stopping before any stage runs" >&2
      exit 2
    fi
  done
}
# stage <log> <sysroot> <stage file> [VAR=value ...]: run the REAL stage on that tree as the
# builder runs it (CB_SANDBOX_SLOTS=58 unless a VAR overrides it); sets RC. <log>.calls holds the
# calls the stubs saw.
stage() {
  local log="$1" sys="$2" st="$3"; shift 3
  assert_stubs "$sys/work/tools/cargo/bin:$BPATH"
  : > "$log.calls"
  run_real "$log" env PATH="$BPATH" SYSROOT="$sys" CB_SANDBOX_SLOTS=58 BSTUB_LOG="$log.calls" STUB_FAIL= "$@" \
    bash "$STAGES/$st"
}

# BLOCK_NODE: no case needs a block device, but a test user that can read or write one could
# reach a real disk through a stage; the suite stops before any case if it can.
BLOCK_NODE=""
for __n in /dev/*; do
  if [[ -b "$__n" && ! -L "$__n" ]]; then BLOCK_NODE="$__n"; break; fi
done
unset __n
if [[ -n "$BLOCK_NODE" && ( -r "$BLOCK_NODE" || -w "$BLOCK_NODE" ) ]]; then
  echo "ERROR: $SUITE: the test user can read or write the block node $BLOCK_NODE; refusing to run" >&2
  exit 2
fi

# ---- the fixture tree ------------------------------------------------------------------------
FX="$WORK/fx"; FXREPO="$FX/bottlerocket"; TPL="$WORK/tpl"
mkdir -p "$FX" "$WORK/case"
if ! python3 -B "$TESTLIB/fixture_builder_sysroot.py" "$SAMPLE_DIR_REAL" "$TPL" "$FX/files" "$FXREPO" > "$WORK/fixture.log" 2>&1; then
  sed 's/^/        | /' "$WORK/fixture.log" | tail -n 8
  not_run "every stage case" "scripts/testlib/fixture_builder_sysroot.py could not make the tree"
  finish
fi
PIN_COMMIT="$(sed -n 's/^commit=//p' "$WORK/fixture.log")"; PIN_TAG="$(sed -n 's/^tag_object=//p' "$WORK/fixture.log")"
TWV="$(sed -n 's/^TWOLITER_VERSION=//p' "$SAMPLE_DIR_REAL/packer/tools.lock")"
LOCKREL=opt/cilium-bottlerocket/overlay/packages/sources.lock
# mk_tree <name> [<template>]: a fresh SYSROOT for one case, a copy of the template (default: the
# tree before fetch-verify); sets SYS and L (its sources.lock).
mk_tree() { SYS="$WORK/case/$1"; rm -rf "$SYS"; cp -a "${2:-$TPL}" "$SYS"; L="$SYS/$LOCKREL"; }
# gitx <git arguments>: git in the case repository $R, with an identity for its commits.
gitx() { git -C "$R" -c user.name=offline-test -c user.email=offline-test@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
# repo_copy <name>: a copy of the fixture repository that the case lock clones; sets R.
repo_copy() {
  R="$FX/repo-$1"; rm -rf "$R"; cp -a "$FXREPO" "$R"
  sed -i "s#^source=file://$FXREPO\$#source=file://$R#" "$L"
  grep -qxF "source=file://$R" "$L" || { echo "ERROR: $SUITE: could not point the $1 lock at its repository" >&2; exit 2; }
}
# retag: commit the changes of $R and move the annotated tag v1.70.0 to that commit.
retag() { gitx commit -qam "$1" && gitx tag -f -a v1.70.0 -m "$1" > /dev/null 2>&1; }
# pin_repo: the case lock pins the commit and the tag object of $R.
pin_repo() {
  local c t; c="$(gitx rev-parse HEAD)"; t="$(gitx rev-parse refs/tags/v1.70.0)"
  sed -i "s/^commit=[0-9a-f]\{40\}\$/commit=$c/; s/^tag_object=[0-9a-f]\{40\}\$/tag_object=$t/" "$L"
}
# clean_clone <sysroot>: the clone has no change (the overlay did not run).
clean_clone() { [[ -z "$(git -C "$1/work/bottlerocket" status --porcelain 2>&1)" ]]; }

echo "== 0/2 the harness refuses a command that is not the stub ============================"
mk_tree harness
mkdir -p "$SYS/work/tools/cargo/bin"; ln -s "$WORK/sysbin/cat" "$SYS/work/tools/cargo/bin/cargo"   # any real program named cargo
( assert_stubs "$SYS/work/tools/cargo/bin:$BPATH" ) > "$WORK/assert.log" 2>&1
check "REJECT (harness) a cargo in \$SYSROOT/work/tools/cargo/bin, first on the stage PATH: the suite would stop" 2 $? "$WORK/assert.log" "cargo resolves to '$SYS/work/tools/cargo/bin/cargo'"
( assert_stubs "$TPL/work/tools/cargo/bin:$BPATH" ) > "$WORK/assert-ok.log" 2>&1
check "ACCEPT (harness) the stage PATH of the fixture tree: every disk writer and answered command is the stub" 0 $? "$WORK/assert-ok.log"

echo "== 1/2 20-fetch-verify.sh ============================================================="
entry scripts/builder/20-fetch-verify.sh
mk_tree fv-ok; FETCHED="$SYS"
stage "$WORK/fv-ok.log" "$SYS" 20-fetch-verify.sh
check "ACCEPT fetch-verify: work volume mounted, clone at the pinned commit and tag, the pinned Twoliter in Makefile.toml, every input verified" 0 "$RC" "$WORK/fv-ok.log" '^builder: fetch-verify ok$'
cover accept E_WORK_VOLUME E_CLONE E_CLONE_COMMIT E_CLONE_TAG E_TWOLITER E_INPUTS E_TOOLS_LOCK
grep -qxF "builder: bottlerocket v1.70.0 commit=$PIN_COMMIT tag_object=$PIN_TAG" "$WORK/fv-ok.log" \
  && grep -qx 'runtime-verify all inputs verified' "$WORK/fv-ok.log"
check "  ... it logs the pinned commit and tag object, and runtime_verify.py verified every input" 0 $? "$WORK/fv-ok.log"
grep -qxF "mountpoint -q $SYS/work" "$WORK/fv-ok.log.calls" \
  && grep -qxF "git -c advice.detachedHead=false clone --quiet --depth 1 --branch v1.70.0 file://$FXREPO $SYS/work/bottlerocket" "$WORK/fv-ok.log.calls" \
  && [[ -s "$SYS/work/inputs/members/runtime-shim" && -f "$SYS/work/inputs/nitro-sandbox-guest-disk.img" ]]
check "  ... it asked mountpoint about the work volume, cloned the file:// stand-in once, and left the inputs in work/inputs" 0 $? "$WORK/fv-ok.log.calls"

mk_tree fv-nomount
stage "$WORK/fv-nomount.log" "$SYS" 20-fetch-verify.sh STUB_FAIL=mountpoint
check "REJECT fetch-verify when the work volume is not mounted" 1 "$RC" "$WORK/fv-nomount.log" '^ERROR: E_WORK_VOLUME: .*/work is not mounted; host-setup did not pass$'
[[ ! -e "$SYS/work/bottlerocket" && ! -e "$SYS/work/inputs" ]] && ! grep -q '^git ' "$WORK/fv-nomount.log.calls"
check "  ... and nothing is cloned or downloaded" 0 $? "$WORK/fv-nomount.log"

mk_tree fv-exists; mkdir -p "$SYS/work/bottlerocket"
stage "$WORK/fv-exists.log" "$SYS" 20-fetch-verify.sh
check "REJECT fetch-verify when the clone folder already exists" 1 "$RC" "$WORK/fv-exists.log" '^ERROR: E_CLONE: .*/work/bottlerocket already exists$'
! grep -q '^git ' "$WORK/fv-exists.log.calls"
check "  ... and git is not run" 0 $? "$WORK/fv-exists.log.calls"

mk_tree fv-clonefail
stage "$WORK/fv-clonefail.log" "$SYS" 20-fetch-verify.sh STUB_FAIL=git-clone
check "REJECT fetch-verify when git clone fails" 1 "$RC" "$WORK/fv-clonefail.log" '^ERROR: E_CLONE: git clone of v1\.70\.0 failed$'

mk_tree fv-commit; repo_copy commit
printf 'later\n' >> "$R/README.md"; retag "a later commit"
stage "$WORK/fv-commit.log" "$SYS" 20-fetch-verify.sh
check "REJECT fetch-verify when the tag now names another commit than the pin" 1 "$RC" "$WORK/fv-commit.log" "^ERROR: E_CLONE_COMMIT: v1\\.70\\.0 is not at the pinned commit $PIN_COMMIT\$"

mk_tree fv-tag; repo_copy tag
gitx tag -f -a v1.70.0 -m "the same commit, another tag object" > /dev/null 2>&1
stage "$WORK/fv-tag.log" "$SYS" 20-fetch-verify.sh
check "REJECT fetch-verify when the tag is another tag object on the pinned commit" 1 "$RC" "$WORK/fv-tag.log" '^ERROR: E_CLONE_TAG: tag v1\.70\.0 is not the pinned tag object$'

mk_tree fv-twv; repo_copy twv
sed -i "s/^TWOLITER_VERSION = \".*\"\$/TWOLITER_VERSION = \"$TWV-other\"/" "$R/Makefile.toml"; retag "another Twoliter"; pin_repo
stage "$WORK/fv-twv.log" "$SYS" 20-fetch-verify.sh
check "REJECT fetch-verify when Makefile.toml sets another Twoliter version" 1 "$RC" "$WORK/fv-twv.log" "^ERROR: E_TWOLITER: Makefile.toml does not set TWOLITER_VERSION = $TWV\$"
[[ ! -e "$SYS/work/inputs" ]]
check "  ... and no input is downloaded" 0 $? "$WORK/fv-twv.log"

mk_tree fv-twsha; repo_copy twsha
sed -i '/^TWOLITER_SHA256_X86_64 = /d' "$R/Makefile.toml"; retag "no x86_64 digest"; pin_repo
stage "$WORK/fv-twsha.log" "$SYS" 20-fetch-verify.sh
check "REJECT fetch-verify when Makefile.toml has no line with the pinned Twoliter x86_64 digest" 1 "$RC" "$WORK/fv-twsha.log" '^ERROR: E_TWOLITER: Makefile.toml does not set TWOLITER_SHA256_X86_64 = [0-9a-f]{64}$'

# The pin is matched as a fixed whole line, so a look-alike whose dots are other
# characters (v0.27.0 -> v0x27y0), which a regex match took for the pin, is refused.
TWV_LIKE="$(printf '%s' "$TWV" | sed 's/\./x/; s/\./y/')"
mk_tree fv-twlike; repo_copy twlike
sed -i "s/^TWOLITER_VERSION = \".*\"\$/TWOLITER_VERSION = \"$TWV_LIKE\"/" "$R/Makefile.toml"; retag "a look-alike Twoliter version"; pin_repo
stage "$WORK/fv-twlike.log" "$SYS" 20-fetch-verify.sh
check "REJECT fetch-verify when Makefile.toml sets the look-alike $TWV_LIKE for the pin $TWV" 1 "$RC" "$WORK/fv-twlike.log" "^ERROR: E_TWOLITER: Makefile.toml does not set TWOLITER_VERSION = ${TWV//./\\.}\$"
[[ "$TWV_LIKE" != "$TWV" && "$(grep -c "^TWOLITER_VERSION = \"$TWV\"\$" "$R/Makefile.toml")" == 1 ]]
check "  ... and the look-alike is one a regex match of the pin accepts (the case tests the fix)" 0 $? "$WORK/fv-twlike.log"

for c in signature-changed download-fails; do
  SYS="$WORK/case/fv-$c"; rm -rf "$SYS"
  python3 -B "$TESTLIB/fixture_builder_sysroot.py" "$SAMPLE_DIR_REAL" "$SYS" "$FX/files-$c" "$FXREPO" "$c" > "$WORK/fixture-$c.log" 2>&1
  stage "$WORK/fv-$c.log" "$SYS" 20-fetch-verify.sh
  check "REJECT fetch-verify when runtime_verify.py fetch refuses ($c)" 1 "$RC" "$WORK/fv-$c.log" '^ERROR: E_INPUTS: an input did not verify \(see the line above\)$'
done
grep -q '^ERROR: E_SIGNATURE: runtime-release: ' "$WORK/fv-signature-changed.log" && grep -q '^ERROR: E_DOWNLOAD: ' "$WORK/fv-download-fails.log"
check "  ... the line above is the verifier's E_SIGNATURE and E_DOWNLOAD refusal" 0 $? "$WORK/fv-signature-changed.log"

entry scripts/builder/lib.sh:tool_lock
mk_tree fv-toolslock; printf 'TWOLITER_VERSION=%s\n' "$TWV" >> "$SYS/opt/cilium-bottlerocket/overlay/packer/tools.lock"
stage "$WORK/fv-toolslock.log" "$SYS" 20-fetch-verify.sh
check "REJECT fetch-verify when tools.lock sets TWOLITER_VERSION twice" 1 "$RC" "$WORK/fv-toolslock.log" '^ERROR: E_TOOLS_LOCK: TWOLITER_VERSION must appear exactly once in tools\.lock$'

echo "== 2/2 30-overlay.sh =================================================================="
entry scripts/builder/30-overlay.sh
PKGREL=work/bottlerocket/packages/nitro-sandbox
LINKED=(nitro-sandboxes-runtime.tar.gz firecracker-vfx-x86_64.tgz nitro-sandbox-guest.eif nitro-sandbox-guest-disk.img)
# linked <sysroot> <file>...: each file of the package is a hard link of the verified input.
linked() { local s="$1" f; shift; for f in "$@"; do [[ "$s/$PKGREL/$f" -ef "$s/work/inputs/$f" ]] || return 1; done; }
if [[ ! -d "$FETCHED/work/bottlerocket/.git" ]]; then
  not_run "every overlay case after fetch-verify" "the fetch-verify accept case left no clone"
  finish
fi
mk_tree ov-ok "$FETCHED"
stage "$WORK/ov-ok.log" "$SYS" 30-overlay.sh
check "ACCEPT overlay: slots 58, a clone, unchanged inputs, register-variant.py, four linked inputs, Cargo.lock with the two new crates, no other path" 0 "$RC" "$WORK/ov-ok.log" '^builder: overlay ok$'
cover accept E_INPUT_SANDBOX_SLOTS E_CLONE E_INPUTS E_OVERLAY E_CARGO_LOCK
grep -qx 'builder: nitro-sandbox.toml pcie_slots      = 58' "$WORK/ov-ok.log" \
  && grep -q '^register-variant variant=aws-k8s-1.36-nitro-sandbox slots=58 .* registrations=5 ok$' "$WORK/ov-ok.log" \
  && grep -qx 'register-variant cargo-lock added=aws-k8s-1_36-nitro-sandbox,nitro-sandbox ok' "$WORK/ov-ok.log"
check "  ... it prints pcie_slots = 58 and the register-variant.py apply and check-lock ok lines" 0 $? "$WORK/ov-ok.log"
linked "$SYS" "${LINKED[@]}" && [[ "$(grep -c '^cargo ' "$WORK/ov-ok.log.calls")" == 1 ]]
check "  ... the four inputs are hard links of the verified files, and cargo ran once" 0 $? "$WORK/ov-ok.log.calls"
for s in 1 250; do
  mk_tree "ov-slots$s" "$FETCHED"
  stage "$WORK/ov-slots$s.log" "$SYS" 30-overlay.sh CB_SANDBOX_SLOTS="$s"
  check "ACCEPT overlay with CB_SANDBOX_SLOTS=$s (an end of 1 to 250)" 0 "$RC" "$WORK/ov-slots$s.log" "^builder: nitro-sandbox.toml pcie_slots += $s\$"
done

mk_tree ov-slots "$FETCHED"
for s in 0 251 058 abc ""; do
  stage "$WORK/ov-slots.log" "$SYS" 30-overlay.sh CB_SANDBOX_SLOTS="$s"
  check "REJECT overlay with CB_SANDBOX_SLOTS='$s'" 1 "$RC" "$WORK/ov-slots.log" '^ERROR: E_INPUT_SANDBOX_SLOTS: CB_SANDBOX_SLOTS must be an integer from 1 to 250$'
done
clean_clone "$SYS"
check "  ... and the clone is unchanged" 0 $? "$WORK/ov-slots.log"

mk_tree ov-noclone
stage "$WORK/ov-noclone.log" "$SYS" 30-overlay.sh
check "REJECT overlay when there is no clone (fetch-verify did not pass)" 1 "$RC" "$WORK/ov-noclone.log" '^ERROR: E_CLONE: no clone; fetch-verify did not pass$'

# A clone with no root Cargo.lock stops with a tag (the accept side is ov-ok,
# whose clone has one).
mk_tree ov-nolock "$FETCHED"; rm "$SYS/work/bottlerocket/Cargo.lock"
stage "$WORK/ov-nolock.log" "$SYS" 30-overlay.sh
check "REJECT overlay of a clone with no root Cargo.lock" 1 "$RC" "$WORK/ov-nolock.log" '^ERROR: E_CARGO_LOCK: could not copy .*/work/bottlerocket/Cargo\.lock$'
! grep -q '^register-variant ' "$WORK/ov-nolock.log" && ! grep -q '^cargo ' "$WORK/ov-nolock.log.calls"
check "  ... before register-variant.py or cargo runs" 0 $? "$WORK/ov-nolock.log"

mk_tree ov-inputs "$FETCHED"; printf 'changed after fetch-verify\n' >> "$SYS/work/inputs/nitro-sandbox-guest-disk.img"
stage "$WORK/ov-inputs.log" "$SYS" 30-overlay.sh
check "REJECT overlay when a verified input changed after fetch-verify" 1 "$RC" "$WORK/ov-inputs.log" '^ERROR: E_INPUTS: the inputs changed after fetch-verify$'
grep -q '^ERROR: E_FILE_SHA256: guest-image-disk: ' "$WORK/ov-inputs.log" && clean_clone "$SYS"
check "  ... the verifier names the guest disk image, and the clone is unchanged" 0 $? "$WORK/ov-inputs.log"

mk_tree ov-dirty "$FETCHED"; printf 'x\n' > "$SYS/work/bottlerocket/stray.txt"
stage "$WORK/ov-dirty.log" "$SYS" 30-overlay.sh
check "REJECT overlay when register-variant.py refuses (a clone with changes)" 1 "$RC" "$WORK/ov-dirty.log" '^ERROR: E_OVERLAY: register-variant\.py refused \(see the line above\)$'
grep -qx 'ERROR: E_CLONE_DIRTY: the clone has changes before the overlay' "$WORK/ov-dirty.log"
check "  ... the line above is register-variant.py's E_CLONE_DIRTY" 0 $? "$WORK/ov-dirty.log"

mk_tree ov-ln "$FETCHED"
stage "$WORK/ov-ln.log" "$SYS" 30-overlay.sh STUB_FAIL=ln-disk
check "REJECT overlay when an input cannot be linked into the package" 1 "$RC" "$WORK/ov-ln.log" '^ERROR: E_OVERLAY: could not link nitro-sandbox-guest-disk\.img into the package$'
linked "$SYS" "${LINKED[@]:0:3}" && ! grep -q '^cargo ' "$WORK/ov-ln.log.calls"
check "  ... the three inputs before it are linked, and cargo does not run" 0 $? "$WORK/ov-ln.log.calls"

mk_tree ov-cargo "$FETCHED"
stage "$WORK/ov-cargo.log" "$SYS" 30-overlay.sh STUB_FAIL=cargo-update
check "REJECT overlay when cargo update fails" 1 "$RC" "$WORK/ov-cargo.log" '^ERROR: E_CARGO_LOCK: cargo update --workspace failed$'

while IFS='|' read -r mode why; do
  [[ -n "$mode" ]] || continue
  mk_tree "ov-$mode" "$FETCHED"
  stage "$WORK/ov-$mode.log" "$SYS" 30-overlay.sh STUB_FAIL="$mode"
  check "$why" 1 "$RC" "$WORK/ov-$mode.log" '^ERROR: E_CARGO_LOCK: Cargo\.lock changed more than the two new crates$'
done <<'CASES'
cargo-bump|REJECT overlay when cargo update also changes a registry crate in Cargo.lock
cargo-none|REJECT overlay when cargo update does not add the two new crates
CASES
grep -qx 'ERROR: E_LOCK_CHANGED: Cargo.lock changed the package serde' "$WORK/ov-cargo-bump.log"
check "  ... check-lock names the changed crate" 0 $? "$WORK/ov-cargo-bump.log"

mk_tree ov-other "$FETCHED"
stage "$WORK/ov-other.log" "$SYS" 30-overlay.sh STUB_FAIL=cargo-other
check "REJECT overlay when the clone changed in another path (Makefile.toml)" 1 "$RC" "$WORK/ov-other.log" '^ERROR: E_OVERLAY: the clone changed in other paths: Cargo\.lock Cargo\.toml Makefile\.toml README\.md '
finish
