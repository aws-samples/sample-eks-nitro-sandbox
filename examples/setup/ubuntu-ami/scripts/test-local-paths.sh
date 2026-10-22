#!/usr/bin/env bash
# test-local-paths.sh: proves scripts/lib/common.sh keeps ALL local runtime state under the
# repository's gitignored tmp/issue10/run, and that its containment guard refuses any override
# pointing inside the sample tree. Needs no cluster and no AWS.
#
#   scripts/test-local-paths.sh
#
# AGENTS.md: "Keep local files in the repository's tmp/ ... Never put them in a sample folder
# or its .gitignore. Why: anything in a sample folder is one `git add` from being published."
# This test is the both-ways proof of that rule for the three local-state directories
# (LOG_DIR, OUT_DIR, RUNTIME_ARTIFACTS_DIR) the sample's scripts use.
#
# It sources the REAL common.sh (not a copy) in clean subshells, each with its own env, so the
# defaults and the guard under test are exactly the ones every other script loads:
#   1  ACCEPT (defaults): with no overrides, LOG_DIR, OUT_DIR and RUNTIME_ARTIFACTS_DIR all
#      resolve UNDER repo-root tmp/issue10/run, and NONE resolves under examples/.
#   2  ACCEPT (external override): an override pointing OUTSIDE examples/ (a mktemp dir) is
#      honored.
#   3  REJECT (override inside examples/): an override pointing INSIDE the sample folder is
#      REFUSED with a non-zero exit and a message naming the containment rule.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"            # .../examples/setup/ubuntu-ami/scripts
SAMPLE_DIR_REAL="$(cd "$HERE/.." && pwd)"                        # .../examples/setup/ubuntu-ami
REPO_ROOT_REAL="$(cd "$SAMPLE_DIR_REAL/../../.." && pwd)"        # repo root
EXAMPLES_ROOT="$(cd "$SAMPLE_DIR_REAL/../.." && pwd)"           # .../examples
RUN_BASE="$REPO_ROOT_REAL/tmp/issue10/run"
COMMON="$HERE/lib/common.sh"

# Keep every byte this test writes under the repository's tmp/, never the sample folder.
WORK="$(mktemp -d "$REPO_ROOT_REAL/tmp/test-local-paths.XXXXXX" 2>/dev/null || mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass=0
fail=0
assert_true() { # assert_true <description> <rc-already-0-or-1>
  if [[ "$2" -eq 0 ]]; then
    printf '  PASS  %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  FAIL  %s\n' "$1"; fail=$((fail + 1))
  fi
}

# under_dir <child> <ancestor> : 0 when resolved <child> is at or under resolved <ancestor>.
# Resolves both physically so a symlink or .. cannot fool the prefix match.
under_dir() {
  local child="$1" ancestor="$2" rc rp
  rc="$(cd "$child" 2>/dev/null && pwd)" || return 2
  rp="$(cd "$ancestor" 2>/dev/null && pwd)" || return 2
  [ "$rc" = "$rp" ] && return 0
  case "$rc/" in "$rp"/*) return 0 ;; *) return 1 ;; esac
}

echo "== 1/3 ACCEPT defaults: all three dirs resolve under tmp/issue10/run, none under examples/ =="
# A clean subshell with no LOG_DIR/OUT_DIR/RUNTIME_ARTIFACTS_DIR/ISSUE10_RUN_DIR overrides.
eval "$(
  env -u LOG_DIR -u OUT_DIR -u RUNTIME_ARTIFACTS_DIR -u ISSUE10_RUN_DIR \
    bash -c '
      SAMPLE_DIR="'"$SAMPLE_DIR_REAL"'"
      . "'"$COMMON"'" >/dev/null 2>&1
      printf "D_LOG=%q\n" "$LOG_DIR"
      printf "D_OUT=%q\n" "$OUT_DIR"
      printf "D_RUN=%q\n" "$RUNTIME_ARTIFACTS_DIR"
      printf "D_BASE=%q\n" "$ISSUE10_RUN_DIR"
    '
)"
echo "  LOG_DIR=$D_LOG"
echo "  OUT_DIR=$D_OUT"
echo "  RUNTIME_ARTIFACTS_DIR=$D_RUN"
echo "  ISSUE10_RUN_DIR=$D_BASE"
assert_true "ISSUE10_RUN_DIR defaults to repo-root tmp/issue10/run" \
  $([[ "$D_BASE" == "$RUN_BASE" ]]; echo $?)
assert_true "LOG_DIR resolves under tmp/issue10/run" $(under_dir "$D_LOG" "$RUN_BASE"; echo $?)
assert_true "OUT_DIR resolves under tmp/issue10/run" $(under_dir "$D_OUT" "$RUN_BASE"; echo $?)
assert_true "RUNTIME_ARTIFACTS_DIR resolves under tmp/issue10/run" $(under_dir "$D_RUN" "$RUN_BASE"; echo $?)
assert_true "LOG_DIR is NOT under examples/" \
  $(under_dir "$D_LOG" "$EXAMPLES_ROOT" && echo 1 || echo 0)
assert_true "OUT_DIR is NOT under examples/" \
  $(under_dir "$D_OUT" "$EXAMPLES_ROOT" && echo 1 || echo 0)
assert_true "RUNTIME_ARTIFACTS_DIR is NOT under examples/" \
  $(under_dir "$D_RUN" "$EXAMPLES_ROOT" && echo 1 || echo 0)

echo
echo "== 2/3 ACCEPT external override: a path OUTSIDE examples/ is honored ================"
EXT="$(mktemp -d "$WORK/ext.XXXXXX")"
ext_rc=0
ext_out="$(
  SAMPLE_DIR="$SAMPLE_DIR_REAL" RUNTIME_ARTIFACTS_DIR="$EXT" \
    bash -c '. "'"$COMMON"'" >/dev/null 2>&1 || exit 7; printf "%s" "$RUNTIME_ARTIFACTS_DIR"'
)" || ext_rc=$?
echo "  override RUNTIME_ARTIFACTS_DIR=$EXT -> rc=$ext_rc, value=${ext_out:-<none>}"
assert_true "an override outside examples/ is honored (common.sh returns 0)" "$ext_rc"
assert_true "the honored override keeps the operator's path" \
  $([[ "$ext_out" == "$EXT" ]]; echo $?)
assert_true "the honored external directory was created" $([[ -d "$EXT" ]]; echo $?)

echo
echo "== 3/3 REJECT override inside examples/: refused with non-zero exit =================="
# A unique, not-yet-existing path inside the sample folder, so we can also prove the guard
# never created it (reusing a name a prior run left behind could not show that).
INSIDE="$SAMPLE_DIR_REAL/artifacts-reject-probe.$$"   # inside the sample folder: forbidden case
rej_rc=0
rej_out="$(
  SAMPLE_DIR="$SAMPLE_DIR_REAL" RUNTIME_ARTIFACTS_DIR="$INSIDE" \
    bash -c '. "'"$COMMON"'"' 2>&1
)" || rej_rc=$?
echo "  override RUNTIME_ARTIFACTS_DIR=$INSIDE -> rc=$rej_rc"
printf '%s\n' "$rej_out" | sed 's/^/    /'
assert_true "an override inside examples/ is refused with a non-zero exit" \
  $([[ "$rej_rc" -ne 0 ]]; echo $?)
assert_true "the refusal names the containment rule (AGENTS.md / inside the sample tree)" \
  $(printf '%s' "$rej_out" | grep -qiE 'sample (tree|folder)|AGENTS.md'; echo $?)
assert_true "the refusal did NOT create the forbidden directory inside the sample folder" \
  $([[ ! -d "$INSIDE" ]]; echo $?)

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "local paths proven: defaults land under tmp/issue10/run, an outside override is honored, an inside-examples override is refused."
