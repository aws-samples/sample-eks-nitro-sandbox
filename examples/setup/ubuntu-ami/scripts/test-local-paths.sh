#!/usr/bin/env bash
# test-local-paths.sh: proves scripts/lib/common.sh keeps ALL local runtime state under the
# repository's gitignored tmp/, and that its containment guard refuses every override that does
# not resolve there (M7). Needs no cluster and no AWS.
#
#   scripts/test-local-paths.sh
#
# AGENTS.md: "Keep local files in the repository's tmp/ ... Never put them in a sample folder
# or its .gitignore. Why: anything in a sample folder is one `git add` from being published."
# This test is the both-ways proof of that rule for the four local-state directories
# (ISSUE10_RUN_DIR, LOG_DIR, OUT_DIR, RUNTIME_ARTIFACTS_DIR) the sample's scripts use.
#
# It sources the REAL common.sh (not a copy) in clean subshells, each with its own env, so the
# defaults and the guard under test are exactly the ones every other script loads:
#   1  ACCEPT (defaults): with no overrides, all four resolve UNDER repo-root tmp/issue10/run.
#   2  ACCEPT (override under the repository's tmp/): absolute, relative to the sample folder, and
#      through a symlink that stays under tmp/; each is honored as its canonical absolute path.
#   3  REJECT (override anywhere else): outside the repository (a mktemp dir, which R1-A
#      accepted), inside the sample folder (absolute and relative), elsewhere in the repository,
#      a `..` that climbs out of tmp/, a symlink under tmp/ that points into the sample, and a
#      sibling whose name only starts with "tmp". Each is refused with a non-zero exit, and the
#      refused directory is never created.
#   4  The unpacked copy on a build host (not a checkout): the default stays
#      /var/lib/ubuntu-ami-sample/run, an override outside the copy is honored, one inside the
#      copy is refused.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"            # .../examples/setup/ubuntu-ami/scripts
SAMPLE_DIR_REAL="$(cd "$HERE/.." && pwd)"                        # .../examples/setup/ubuntu-ami
REPO_ROOT_REAL="$(cd "$SAMPLE_DIR_REAL/../../.." && pwd)"        # repo root
RUN_BASE="$REPO_ROOT_REAL/tmp/issue10/run"
COMMON="$HERE/lib/common.sh"
VARS=(ISSUE10_RUN_DIR LOG_DIR OUT_DIR RUNTIME_ARTIFACTS_DIR)

# Keep every byte this test writes under the repository's tmp/, except the one outside-the-
# repository directory section 3 needs, which is removed on exit too.
mkdir -p "$REPO_ROOT_REAL/tmp"
WORK="$(mktemp -d "$REPO_ROOT_REAL/tmp/test-local-paths.XXXXXX")"
OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/ubuntu-ami-paths.XXXXXX")"
cleanup() { rm -rf "$WORK" "$OUTSIDE"; }
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
under() { # under <path> <base> : 0 when <path> is <base> or below it, compared as whole components
  [ "$1" = "$2" ] || case "$1/" in "$2"/*) true ;; *) false ;; esac
}

# probe <sample-dir> <var> <value>: source common.sh with only <var> overridden; sets P_RC, P_VAL
# (the value common.sh left in <var>) and P_OUT (everything common.sh printed).
probe() {
  local sd="$1" var="$2" val="$3" out
  P_RC=0
  out="$(env -u ISSUE10_RUN_DIR -u LOG_DIR -u OUT_DIR -u RUNTIME_ARTIFACTS_DIR -u REPO_ROOT \
          SAMPLE_DIR="$sd" "$var=$val" PROBE_VAR="$var" \
          bash -c '. "$1" 2>&1 || exit 1; printf "\nVALUE=%s" "${!PROBE_VAR}"' _ "$sd/scripts/lib/common.sh" 2>&1)" || P_RC=$?
  P_VAL="$(printf '%s' "$out" | sed -n 's/^VALUE=//p')"
  P_OUT="$(printf '%s' "$out" | sed '/^VALUE=/d')"
}

echo "== 1/4 ACCEPT defaults: all four dirs resolve under tmp/issue10/run ======================"
eval "$(
  env -u LOG_DIR -u OUT_DIR -u RUNTIME_ARTIFACTS_DIR -u ISSUE10_RUN_DIR -u REPO_ROOT SAMPLE_DIR="$SAMPLE_DIR_REAL" \
    bash -c '. "$1" >/dev/null 2>&1; for v in ISSUE10_RUN_DIR LOG_DIR OUT_DIR RUNTIME_ARTIFACTS_DIR; do printf "D_%s=%q\n" "$v" "${!v}"; done' _ "$COMMON"
)"
for v in "${VARS[@]}"; do
  d="D_$v"; echo "  $v=${!d}"
  under "${!d}" "$RUN_BASE"; assert_true "$v defaults under repo-root tmp/issue10/run" $?
  ! under "${!d}" "$SAMPLE_DIR_REAL"; assert_true "  ... and not inside the sample folder" $?
done
[[ "$D_ISSUE10_RUN_DIR" == "$RUN_BASE" ]]; assert_true "ISSUE10_RUN_DIR defaults to exactly repo-root tmp/issue10/run" $?

echo
echo "== 2/4 ACCEPT overrides under the repository's tmp/ ======================================="
mkdir -p "$WORK/real-target"
ln -s "$WORK/real-target" "$WORK/link-in-tmp"
REL_TMP="../../../tmp/$(basename "$WORK")/rel-accept"         # relative to the sample folder
while IFS='|' read -r var val want why; do
  [ -n "$var" ] || continue
  val="${val//@WORK@/$WORK}"; want="${want//@WORK@/$WORK}"; val="${val//@REL_TMP@/$REL_TMP}"
  probe "$SAMPLE_DIR_REAL" "$var" "$val"
  echo "  $var=$val -> rc=$P_RC, value=${P_VAL:-<none>}"
  [[ "$P_RC" -eq 0 && "$P_VAL" == "$want" ]]; assert_true "$why" $?
  [[ -d "$want" ]]; assert_true "  ... and it was created there" $?
done <<'CASES'
RUNTIME_ARTIFACTS_DIR|@WORK@/abs-accept|@WORK@/abs-accept|ACCEPT an absolute RUNTIME_ARTIFACTS_DIR under tmp/
LOG_DIR|@REL_TMP@|@WORK@/rel-accept|ACCEPT a relative LOG_DIR that resolves under tmp/ (read from the sample folder, made absolute)
OUT_DIR|@WORK@/link-in-tmp/out|@WORK@/real-target/out|ACCEPT an OUT_DIR through a symlink that stays under tmp/ (stored as its real path)
ISSUE10_RUN_DIR|@WORK@/run-accept/./sub/..|@WORK@/run-accept|ACCEPT an ISSUE10_RUN_DIR under tmp/ written with . and .. (stored canonical)
CASES

echo
echo "== 3/4 REJECT overrides that do not resolve under the repository's tmp/ ==================="
ln -s "$SAMPLE_DIR_REAL" "$WORK/link-to-sample"
PROBE_NAME="paths-reject-probe.$$"
while IFS='|' read -r var val created why; do
  [ -n "$var" ] || continue
  for k in val created; do
    x="${!k}"; x="${x//@WORK@/$WORK}"; x="${x//@OUTSIDE@/$OUTSIDE}"; x="${x//@SAMPLE@/$SAMPLE_DIR_REAL}"
    x="${x//@REPO@/$REPO_ROOT_REAL}"; x="${x//@P@/$PROBE_NAME}"; printf -v "$k" '%s' "$x"
  done
  probe "$SAMPLE_DIR_REAL" "$var" "$val"
  echo "  $var=$val -> rc=$P_RC"
  printf '%s\n' "$P_OUT" | grep -m1 FATAL | sed 's/^/    /'
  [[ "$P_RC" -ne 0 ]]; assert_true "$why" $?
  printf '%s' "$P_OUT" | grep -q "FATAL: $var resolves to .* which is not under the repository's tmp/"
  assert_true "  ... naming the variable and the rule" $?
  cname="${created##*/}"
  [[ ! -e "$created" ]]; assert_true "  ... and $cname was not created" $?
done <<'CASES'
RUNTIME_ARTIFACTS_DIR|@OUTSIDE@/@P@|@OUTSIDE@/@P@|REJECT an override outside the repository (a mktemp dir; R1-A accepted this)
RUNTIME_ARTIFACTS_DIR|@SAMPLE@/@P@|@SAMPLE@/@P@|REJECT an absolute override inside the sample folder
LOG_DIR|@P@|@SAMPLE@/@P@|REJECT a relative override, which resolves inside the sample folder
OUT_DIR|scripts/@P@|@SAMPLE@/scripts/@P@|REJECT a relative override into a subfolder of the sample
ISSUE10_RUN_DIR|@REPO@/docs/@P@|@REPO@/docs/@P@|REJECT an override elsewhere in the repository (tracked, not tmp/)
OUT_DIR|@REPO@/tmp/../examples/@P@|@REPO@/examples/@P@|REJECT a .. that climbs out of tmp/ into examples/
LOG_DIR|@WORK@/link-to-sample/@P@|@SAMPLE@/@P@|REJECT a symlink under tmp/ that points into the sample folder
RUNTIME_ARTIFACTS_DIR|@REPO@/tmpx-@P@|@REPO@/tmpx-@P@|REJECT a sibling whose name only starts with tmp (whole path components)
CASES

echo
echo "== 4/4 the unpacked copy on a build host (not a checkout) ==============================="
HOSTCOPY="$WORK/host/usr/local/share/ubuntu-ami-sample"
mkdir -p "$HOSTCOPY"
cp -a "$SAMPLE_DIR_REAL/scripts" "$HOSTCOPY/"
out="$(env -u ISSUE10_RUN_DIR -u REPO_ROOT SAMPLE_DIR="$HOSTCOPY" LOG_DIR="$WORK/hs/logs" OUT_DIR="$WORK/hs/out" \
        RUNTIME_ARTIFACTS_DIR="$WORK/hs/runtime" bash -c '. "$1" >/dev/null 2>&1; printf "%s|%s" "$IN_CHECKOUT" "$ISSUE10_RUN_DIR"' _ "$HOSTCOPY/scripts/lib/common.sh")"
echo "  IN_CHECKOUT|ISSUE10_RUN_DIR = $out"
[[ "$out" == "0|/var/lib/ubuntu-ami-sample/run" ]]; assert_true "ACCEPT the build-host default: not a checkout, ISSUE10_RUN_DIR=/var/lib/ubuntu-ami-sample/run" $?
probe "$HOSTCOPY" OUT_DIR "$WORK/hs/out2"
[[ "$P_RC" -eq 0 && "$P_VAL" == "$WORK/hs/out2" ]]; assert_true "ACCEPT an override outside the unpacked copy" $?
probe "$HOSTCOPY" OUT_DIR "$HOSTCOPY/out"
[[ "$P_RC" -ne 0 ]] && printf '%s' "$P_OUT" | grep -q 'inside the sample copy'
assert_true "REJECT an override inside the unpacked copy" $?
[[ ! -e "$HOSTCOPY/out" ]]; assert_true "  ... and it was not created" $?
probe "$HOSTCOPY" LOG_DIR "logs"
[[ "$P_RC" -ne 0 && ! -e "$HOSTCOPY/logs" ]]; assert_true "REJECT a relative override, which resolves inside the unpacked copy, and do not create it" $?

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "local paths proven: every default and accepted override resolves under the repository's tmp/; every other location is refused and never created."
