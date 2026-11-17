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
#   3  REJECT (override anywhere else): outside the repository (a path that does not exist,
#      which R1-A accepted), inside the sample folder (absolute and relative), elsewhere in the
#      repository, a `..` that climbs out of tmp/, a symlink under tmp/ that points into the
#      sample, and a sibling whose name only starts with "tmp"; and RUN_STATE_FILE inside the
#      sample or outside the repository (RR-007). Each is refused with a non-zero exit, and the
#      refused path is never created.
#   4  The unpacked copy on a build host (not a checkout): the default stays
#      /var/lib/ubuntu-ami-sample/run, an override outside the copy is honored, one inside the
#      copy is refused.
#   5  EVIDENCE_DIR is guarded the same way, and in a checkout every mktemp lands in a private
#      tmp/ folder under ISSUE10_RUN_DIR whatever TMPDIR the caller set (RR-007).
#   6  that private folder (RR2-002): the base ISSUE10_RUN_DIR/tmp is a real 0700 directory, each
#      process gets its own 0700 folder in it, and a child reuses its parent's; a symlink or a
#      non-0700 base is refused with nothing written, and an inherited TMPDIR that is a symlink,
#      outside the base, the base itself or not 0700 is not used.
#   7  the cluster and Region a run uses: the shell's CLUSTER_NAME and AWS_REGION survive
#      sourcing a config.env copied from config.env.example, unset ones get the home page's
#      defaults (sandbox-demo, us-west-2), and NAMESPACE is the sample's own whatever the shell has.
# The test itself creates nothing outside the repository's tmp/.
set -uo pipefail
# A reader's own config.env (in the sample folder or ~/ubuntu-ami/) must not change what this suite
# tests: scripts/lib/common.sh skips it while this test hook is set.
export UBUNTU_AMI_TESTS_IGNORE_CONFIG_ENV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"            # .../examples/setup/ubuntu-ami/scripts
SAMPLE_DIR_REAL="$(cd "$HERE/.." && pwd)"                        # .../examples/setup/ubuntu-ami
REPO_ROOT_REAL="$(cd "$SAMPLE_DIR_REAL/../../.." && pwd)"        # repo root
RUN_BASE="$REPO_ROOT_REAL/tmp/issue10/run"
COMMON="$HERE/lib/common.sh"
VARS=(ISSUE10_RUN_DIR LOG_DIR OUT_DIR RUNTIME_ARTIFACTS_DIR)

# Every byte this test writes stays under the repository's tmp/. The outside-the-repository
# reject cases point at OUTSIDE, a path beside the repository that does not exist and that this
# test never creates (it checks at the end that nothing made it either).
mkdir -p "$REPO_ROOT_REAL/tmp"
WORK="$(mktemp -d "$REPO_ROOT_REAL/tmp/test-local-paths.XXXXXX")"
OUTSIDE="$(dirname "$REPO_ROOT_REAL")/ubuntu-ami-paths-probe-$$-$RANDOM"
[ ! -e "$OUTSIDE" ] || { echo "FATAL: $OUTSIDE exists; re-run the test" >&2; exit 2; }
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

echo "== 1/7 ACCEPT defaults: all four dirs resolve under tmp/issue10/run ======================"
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
echo "== 2/7 ACCEPT overrides under the repository's tmp/ ======================================="
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
echo "== 3/7 REJECT overrides that do not resolve under the repository's tmp/ ==================="
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
RUNTIME_ARTIFACTS_DIR|@OUTSIDE@/@P@|@OUTSIDE@/@P@|REJECT an override outside the repository (R1-A accepted this)
RUN_STATE_FILE|@SAMPLE@/@P@.env|@SAMPLE@/@P@.env|REJECT (RR-007) a run-state file inside the sample folder
RUN_STATE_FILE|@P@.env|@SAMPLE@/@P@.env|REJECT (RR-007) a relative run-state file, which resolves inside the sample folder
RUN_STATE_FILE|@OUTSIDE@/@P@.env|@OUTSIDE@/@P@.env|REJECT (RR-007) a run-state file outside the repository
RUNTIME_ARTIFACTS_DIR|@SAMPLE@/@P@|@SAMPLE@/@P@|REJECT an absolute override inside the sample folder
LOG_DIR|@P@|@SAMPLE@/@P@|REJECT a relative override, which resolves inside the sample folder
OUT_DIR|scripts/@P@|@SAMPLE@/scripts/@P@|REJECT a relative override into a subfolder of the sample
ISSUE10_RUN_DIR|@REPO@/docs/@P@|@REPO@/docs/@P@|REJECT an override elsewhere in the repository (tracked, not tmp/)
OUT_DIR|@REPO@/tmp/../examples/@P@|@REPO@/examples/@P@|REJECT a .. that climbs out of tmp/ into examples/
LOG_DIR|@WORK@/link-to-sample/@P@|@SAMPLE@/@P@|REJECT a symlink under tmp/ that points into the sample folder
RUNTIME_ARTIFACTS_DIR|@REPO@/tmpx-@P@|@REPO@/tmpx-@P@|REJECT a sibling whose name only starts with tmp (whole path components)
CASES

echo
echo "== 4/7 the unpacked copy on a build host (not a checkout) ==============================="
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
echo "== 5/7 the run's evidence folder and temporary files (RR-007) ==========================="
# ev <EVIDENCE_DIR or empty>: source common.sh with ISSUE10_RUN_DIR under WORK, derive the run's
# names, and print EVIDENCE_DIR and where a plain mktemp lands. TMPDIR is set to OUTSIDE (which
# does not exist): in a checkout common.sh must replace it.
ev() {
  EV_RC=0
  EV_OUT="$(env -u LOG_DIR -u OUT_DIR -u RUNTIME_ARTIFACTS_DIR -u RUN_STATE_FILE -u REPO_ROOT ${1:+EVIDENCE_DIR="$1"} \
    SAMPLE_DIR="$SAMPLE_DIR_REAL" ISSUE10_RUN_DIR="$WORK/ev-run" TMPDIR="$OUTSIDE" RUN_ID=evrun1 \
    bash -c '. "$1" 2>&1 && derive_run_names 2>&1 && printf "EVIDENCE=%s\nTMPFILE=%s\nTMPDIR=%s\n" "$EVIDENCE_DIR" "$(mktemp)" "$TMPDIR"' _ "$COMMON" 2>&1)" || EV_RC=$?
}
ev ""
evd=$(printf '%s\n' "$EV_OUT" | sed -n 's/^EVIDENCE=//p'); tf=$(printf '%s\n' "$EV_OUT" | sed -n 's/^TMPFILE=//p')
[[ "$EV_RC" -eq 0 && "$evd" == "$WORK/ev-run/out/runs/evrun1/evidence" ]]; assert_true "ACCEPT the default EVIDENCE_DIR, under the run's folder in tmp/ ($evd)" $?
evt=$(printf '%s\n' "$EV_OUT" | sed -n 's/^TMPDIR=//p')
[[ "$tf" == "$evt/"* && -f "$tf" ]]; assert_true "ACCEPT: a plain mktemp lands in the private TMPDIR common.sh set ($tf)" $?
[[ "$(dirname "$evt")" == "$WORK/ev-run/tmp" ]]
assert_true "REJECT the caller's TMPDIR outside the repository: common.sh replaced it with a folder in tmp/ under ISSUE10_RUN_DIR ($evt)" $?
ev "$SAMPLE_DIR_REAL/evidence-probe.$$"
[[ "$EV_RC" -ne 0 ]] && printf '%s' "$EV_OUT" | grep -q "FATAL: EVIDENCE_DIR resolves to .* which is not under the repository's tmp/"
assert_true "REJECT (RR-007) an EVIDENCE_DIR inside the sample folder" $?
[[ ! -e "$SAMPLE_DIR_REAL/evidence-probe.$$" ]]; assert_true "  ... and it was not created" $?

echo
echo "== 6/7 the private temporary folder: a real 0700 base, one folder per process (RR2-002) ==="
# tp <case> <ISSUE10_RUN_DIR> [<inherited TMPDIR>]: source the real common.sh in a clean shell
# (TMPDIR only when given), make one plain mktemp, and source common.sh again in a child. Sets
# TP_RC, TP_DIR (the TMPDIR common.sh set), TP_FILE (the mktemp) and TP_CHILD (the child's TMPDIR).
cat > "$WORK/tp-driver.sh" <<'SH'
. "$1" || exit 1
f=$(mktemp) || exit 1
printf 'TMPDIR=%s\nTMPFILE=%s\n' "$TMPDIR" "$f"
printf 'CHILD=%s\n' "$(bash -c '. "$1" >/dev/null 2>&1 && printf %s "$TMPDIR"' _ "$1")"
SH
tp() {
  TP_RC=0
  TP_OUT="$(env -u LOG_DIR -u OUT_DIR -u RUNTIME_ARTIFACTS_DIR -u RUN_STATE_FILE -u REPO_ROOT -u TMPDIR \
    SAMPLE_DIR="$SAMPLE_DIR_REAL" ISSUE10_RUN_DIR="$2" ${3:+TMPDIR="$3"} bash "$WORK/tp-driver.sh" "$COMMON" 2>&1)" || TP_RC=$?
  printf '%s\n' "$TP_OUT" > "$WORK/tp-$1.log"
  TP_DIR=$(printf '%s\n' "$TP_OUT" | sed -n 's/^TMPDIR=//p')
  TP_FILE=$(printf '%s\n' "$TP_OUT" | sed -n 's/^TMPFILE=//p')
  TP_CHILD=$(printf '%s\n' "$TP_OUT" | sed -n 's/^CHILD=//p')
  echo "  $1: rc=$TP_RC TMPDIR=${TP_DIR:-<none>}"
  printf '%s\n' "$TP_OUT" | grep -m1 FATAL | sed 's/^/    /'
}
mode() { stat -c %a "$1" 2>/dev/null; }
# own_dir <dir> <base>: <dir> is a direct child of <base>, a real directory (not a symlink), mode 700
own_dir() { [[ -n "$1" && "$(dirname "$1")" == "$2" && -d "$1" && ! -L "$1" && "$(mode "$1")" == 700 ]]; }
empty_dir() { [[ -d "$1" && -z "$(ls -A "$1")" ]]; }

R1="$WORK/tp-run1"; B1="$R1/tmp"
tp new "$R1"
[[ "$TP_RC" -eq 0 ]] && own_dir "$TP_DIR" "$B1" && [[ "$(basename "$TP_DIR")" =~ ^p\.[A-Za-z0-9]{10}$ ]]
assert_true "ACCEPT: the base ISSUE10_RUN_DIR/tmp is created, and this process gets its own 0700 folder in it with a random name" $?
[[ -d "$B1" && ! -L "$B1" && "$(mode "$B1")" == 700 ]]; assert_true "  ... the base itself is a real directory, mode 700" $?
[[ "$(dirname "$TP_FILE")" == "$TP_DIR" && -f "$TP_FILE" ]]; assert_true "  ... and a plain mktemp lands in that folder" $?
[[ "$TP_CHILD" == "$TP_DIR" ]]; assert_true "ACCEPT: a child that sources common.sh again reuses its parent's folder" $?
FIRST="$TP_DIR"
tp second "$R1"
[[ "$TP_RC" -eq 0 && "$TP_DIR" != "$FIRST" ]] && own_dir "$TP_DIR" "$B1"
assert_true "ACCEPT: a second process gets a different folder in the same base" $?
tp inherit "$R1" "$FIRST"
[[ "$TP_RC" -eq 0 && "$TP_DIR" == "$FIRST" && "$(dirname "$TP_FILE")" == "$FIRST" ]]
assert_true "ACCEPT: an inherited TMPDIR that is such a folder (a direct 0700 child of the base) is kept" $?
first_count=$(ls -A "$FIRST" | wc -l)

# A symlink at the base, to a folder outside ISSUE10_RUN_DIR (under this test's tmp/ folder) and,
# dangling, to the outside-the-repository probe path: refused, and nothing is written where it points.
R2="$WORK/tp-run2"; mkdir -p "$R2" "$WORK/tp-elsewhere"; ln -s "$WORK/tp-elsewhere" "$R2/tmp"
tp symlink-base "$R2"
[[ "$TP_RC" -ne 0 ]] && grep -q "FATAL: $R2/tmp is a symlink" "$WORK/tp-symlink-base.log"
assert_true "REJECT a base that is a symlink to a folder outside ISSUE10_RUN_DIR" $?
empty_dir "$WORK/tp-elsewhere"; assert_true "  ... and nothing was written in the folder it points to" $?
R3="$WORK/tp-run3"; mkdir -p "$R3"; ln -s "$OUTSIDE" "$R3/tmp"
tp dangling-base "$R3"
[[ "$TP_RC" -ne 0 ]] && grep -q "FATAL: $R3/tmp is a symlink" "$WORK/tp-dangling-base.log" && [[ ! -e "$OUTSIDE" ]]
assert_true "REJECT a base that is a symlink to a path outside the repository, and do not create it" $?
R4="$WORK/tp-run4"; mkdir -p "$R4"; mkdir -m 0755 "$R4/tmp"
tp open-base "$R4"
[[ "$TP_RC" -ne 0 ]] && grep -q "FATAL: $R4/tmp must be a directory owned by you with mode 0700" "$WORK/tp-open-base.log" && empty_dir "$R4/tmp"
assert_true "REJECT a base with mode 755, with nothing written in it" $?

# An inherited TMPDIR that is not one of the base's own 0700 folders is not used: common.sh makes
# a new folder in the base, and nothing lands in the inherited one.
mkdir -m 0700 "$WORK/tp-elsewhere-0700" "$B1/p.open"; chmod 0755 "$B1/p.open"
ln -s "$FIRST" "$B1/p.link"
while IFS='|' read -r name inherited why; do
  [ -n "$name" ] || continue
  inherited="${inherited//@B1@/$B1}"; inherited="${inherited//@WORK@/$WORK}"
  tp "$name" "$R1" "$inherited"
  [[ "$TP_RC" -eq 0 && "$TP_DIR" != "$inherited" && "$TP_DIR" != "$FIRST" ]] && own_dir "$TP_DIR" "$B1" && [[ "$(dirname "$TP_FILE")" == "$TP_DIR" ]]
  assert_true "$why" $?
done <<'CASES'
link|@B1@/p.link|REJECT an inherited TMPDIR that is a symlink in the base (to a valid sibling folder): not used, a new folder is made
outside|@WORK@/tp-elsewhere-0700|REJECT an inherited TMPDIR outside the base (a real 0700 folder elsewhere in tmp/): not used
base|@B1@|REJECT an inherited TMPDIR that is the base itself: not used
open|@B1@/p.open|REJECT an inherited TMPDIR in the base with mode 755: not used
CASES
[[ "$(ls -A "$FIRST" | wc -l)" == "$first_count" ]] && empty_dir "$WORK/tp-elsewhere-0700" && empty_dir "$B1/p.open"
assert_true "  ... and nothing was written in any of the inherited folders (or through the symlink)" $?
[[ ! -e "$OUTSIDE" ]]; assert_true "nothing was created at the outside-the-repository probe path, by this test or by the code under test" $?

echo "== 7/7 the cluster, Region and namespace a run uses: config.env.example and common.sh ====="
# The README's Build block says the reader's own CLUSTER_NAME and AWS_REGION stay in effect after
# `cp config.env.example config.env`, and that the sample uses its own namespace. The real
# common.sh's own config.env search runs here (the suite's test hook is unset for these cases),
# from a copy of the sample laid out as in a checkout, which holds no config.env, so a reader's own
# config.env is never read. It finds the copied example where a build host's copy would be
# ($HOME/ubuntu-ami/config.env), so nothing is written into the sample folder.
mkdir -p "$WORK/hdir/ubuntu-ami" "$WORK/hdir-none" "$WORK/cfgrepo/examples/setup"
cp "$SAMPLE_DIR_REAL/config.env.example" "$WORK/hdir/ubuntu-ami/config.env"
cp -- "$REPO_ROOT_REAL/AGENTS.md" "$WORK/cfgrepo/"; cp -a "$SAMPLE_DIR_REAL" "$WORK/cfgrepo/examples/setup/"
rm -f "$WORK/cfgrepo/examples/setup/$(basename "$SAMPLE_DIR_REAL")/config.env"
CFG_SAMPLE="$WORK/cfgrepo/examples/setup/$(basename "$SAMPLE_DIR_REAL")"
names() { # names <home> [VAR=value...]: CLUSTER_NAME|AWS_REGION|NAMESPACE after common.sh
  local h="$1"; shift
  env -u CLUSTER_NAME -u AWS_REGION -u NAMESPACE -u LOG_DIR -u OUT_DIR -u RUNTIME_ARTIFACTS_DIR -u ISSUE10_RUN_DIR -u REPO_ROOT \
    -u UBUNTU_AMI_TESTS_IGNORE_CONFIG_ENV HOME="$h" SAMPLE_DIR="$CFG_SAMPLE" "$@" \
    bash -c '. "$1" >/dev/null 2>&1; printf "%s|%s|%s" "$CLUSTER_NAME" "$AWS_REGION" "$NAMESPACE"' _ "$CFG_SAMPLE/scripts/lib/common.sh"
}
# sources_clean <file>: source it under the entrypoints' discipline (set -euo pipefail) in an
# empty environment; 0 only when the source exits 0 AND writes nothing to stderr. SRC_RC and
# SRC_ERR say what it did.
sources_clean() {
  SRC_RC=0
  SRC_ERR=$(env -i PATH="$PATH" bash -c 'set -euo pipefail; . "$1"' _ "$1" 2>&1 >/dev/null) || SRC_RC=$?
  [ "$SRC_RC" = 0 ] && [ -z "$SRC_ERR" ]
}
src_note() { printf 'source status %s%s' "$SRC_RC" "${SRC_ERR:+, stderr: $(printf '%s' "$SRC_ERR" | head -n 1 | sed 's#.*/config.env[^:]*: #config.env: #')}"; }
sources_clean "$WORK/hdir/ubuntu-ami/config.env"; r=$?   # read before the description's command substitution resets $?
assert_true "ACCEPT config.env as copied from the example, before any edit: it sources with status 0 and nothing on stderr ($(src_note))" "$r"
# The check itself, both ways: a command that fails silently (status 1, no stderr) and the
# pre-F1 unquoted placeholder (a syntax error on stderr) are each refused.
cp "$WORK/hdir/ubuntu-ami/config.env" "$WORK/config.env.silent"; printf 'false\n' >> "$WORK/config.env.silent"
sources_clean "$WORK/config.env.silent"; r=$?
[ "$r" != 0 ] && [ "$SRC_RC" != 0 ] && [ -z "$SRC_ERR" ]; r=$?
assert_true "REJECT a config.env with a command that fails silently: status nonzero, empty stderr ($(src_note))" "$r"
sed 's/^export KUBE_CONTEXT=.*/export KUBE_CONTEXT=<your-context>/' "$WORK/hdir/ubuntu-ami/config.env" > "$WORK/config.env.syntax"
sources_clean "$WORK/config.env.syntax"; r=$?
[ "$r" != 0 ] && [ -n "$SRC_ERR" ]; r=$?
assert_true "REJECT a config.env with the unquoted KUBE_CONTEXT placeholder: a syntax error on stderr ($(src_note))" "$r"
got=$(names "$WORK/hdir" CLUSTER_NAME=my-cluster AWS_REGION=eu-west-1)
[ "$got" = "my-cluster|eu-west-1|ubuntu-ami-sample" ]
assert_true "ACCEPT the shell's own CLUSTER_NAME and AWS_REGION: they survive sourcing config.env ($got)" $?
got=$(names "$WORK/hdir")
[ "$got" = "sandbox-demo|us-west-2|ubuntu-ami-sample" ]
assert_true "ACCEPT the home page's defaults when the shell has neither: sandbox-demo and us-west-2 ($got)" $?
got=$(names "$WORK/hdir-none")
[ "$got" = "sandbox-demo|us-west-2|ubuntu-ami-sample" ]
assert_true "ACCEPT the same defaults from common.sh alone, with no config.env ($got)" $?
got=$(names "$WORK/hdir" NAMESPACE=nitro-sandboxes-demo)
[ "$got" = "sandbox-demo|us-west-2|ubuntu-ami-sample" ]
assert_true "REJECT the home page's shared NAMESPACE: config.env sets the sample's own ubuntu-ami-sample ($got)" $?
# The suites' test hook, both ways: a config.env in the sample folder and one in ~/ubuntu-ami/ are
# each read by a normal run, and neither is read while UBUNTU_AMI_TESTS_IGNORE_CONFIG_ENV=1.
mkdir -p "$WORK/hdir-reader/ubuntu-ami"
printf 'export NAMESPACE=reader-home-namespace\n' > "$WORK/hdir-reader/ubuntu-ami/config.env"
got=$(names "$WORK/hdir-reader"); [ "$got" = "sandbox-demo|us-west-2|reader-home-namespace" ]
assert_true "ACCEPT a normal run reading ~/ubuntu-ami/config.env ($got)" $?
got=$(names "$WORK/hdir-reader" UBUNTU_AMI_TESTS_IGNORE_CONFIG_ENV=1); [ "$got" = "sandbox-demo|us-west-2|ubuntu-ami-sample" ]
assert_true "REJECT ~/ubuntu-ami/config.env while the suites' test hook is set: not read ($got)" $?
printf 'export NAMESPACE=reader-sample-namespace\n' > "$CFG_SAMPLE/config.env"
got=$(names "$WORK/hdir-none"); [ "$got" = "sandbox-demo|us-west-2|reader-sample-namespace" ]
assert_true "ACCEPT a normal run reading the sample folder's config.env ($got)" $?
got=$(names "$WORK/hdir-none" UBUNTU_AMI_TESTS_IGNORE_CONFIG_ENV=1); [ "$got" = "sandbox-demo|us-west-2|ubuntu-ami-sample" ]
assert_true "REJECT the sample folder's config.env while the suites' test hook is set: not read ($got)" $?
rm -f "$CFG_SAMPLE/config.env"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "local paths proven: every default and accepted override resolves under the repository's tmp/; every other location is refused and never created."
