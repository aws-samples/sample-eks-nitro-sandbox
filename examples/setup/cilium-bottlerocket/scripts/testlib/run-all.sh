#!/usr/bin/env bash
# run-all.sh: runs every offline test suite of this sample (scripts/test-*.sh), then the
# closed-world gate, and with --mutants the mutant runs.
# No AWS account, no cluster and no network are used.
#
#   examples/setup/cilium-bottlerocket/scripts/testlib/run-all.sh [--mutants] [--jobs N]
#
# It exits non-zero when a suite fails or has a case that could not run, when a tag of the
# generated inventory lacks a passing accept case or a passing reject case, when a refusal has no
# tag, when a case names an entry point that no longer exists, and (with --mutants) when a mutant
# with a guard removed survives its reject cases. Output and reports go to CB_TESTS_LOG_DIR
# (default tmp/cb-tests-logs under the repository).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
SAMPLE="$(cd "$SCRIPTS/.." && pwd)"
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || (cd "$SAMPLE/../../.." && pwd))"
LOG_DIR="${CB_TESTS_LOG_DIR:-$REPO_ROOT/tmp/cb-tests-logs}"
mutants=0; jobs=6
while (($#)); do
  case "$1" in
    --mutants) mutants=1 ;;
    --jobs) jobs="$2"; shift ;;
    *) echo "usage: run-all.sh [--mutants] [--jobs N]" >&2; exit 2 ;;
  esac
  shift
done
case "$(realpath -m "$LOG_DIR")/" in
  "$(realpath -m "$REPO_ROOT/tmp")"/*) ;;
  *) echo "ERROR: CB_TESTS_LOG_DIR must be under the repository's tmp/" >&2; exit 2 ;;
esac
mkdir -p "$LOG_DIR"
export CB_TESTS_COVERAGE="$LOG_DIR/coverage.jsonl"
: > "$CB_TESTS_COVERAGE"
unset CB_TESTS_SAMPLE_DIR
total_p=0; total_f=0; total_n=0; bad=0
for suite in "$SCRIPTS"/test-*.sh; do
  [[ -f "$suite" ]] || continue
  name="$(basename "$suite" .sh)"
  rc=0
  bash "$suite" > "$LOG_DIR/$name.log" 2>&1 < /dev/null || rc=$?
  line="$(grep -E '^RESULT: ' "$LOG_DIR/$name.log" | tail -n1)"
  if [[ "$line" =~ ([0-9]+)\ passed,\ ([0-9]+)\ failed,\ ([0-9]+)\ not\ run ]]; then
    total_p=$((total_p + BASH_REMATCH[1])); total_f=$((total_f + BASH_REMATCH[2])); total_n=$((total_n + BASH_REMATCH[3]))
  else
    line="RESULT: $name: no RESULT line (exit $rc), see $LOG_DIR/$name.log"
    total_f=$((total_f + 1))
  fi
  ((rc == 0)) || bad=1
  printf '%s (exit %d)\n' "$line" "$rc"
done
printf '\nTOTAL: %d passed, %d failed, %d not run; logs in %s\n' "$total_p" "$total_f" "$total_n" "$LOG_DIR"
gate=0
python3 "$HERE/closed_world.py" gate "$SAMPLE" "$CB_TESTS_COVERAGE" "$LOG_DIR/closed-world.md" || gate=1
echo "closed-world report: $LOG_DIR/closed-world.md"
mut=0
if ((mutants)); then
  python3 "$HERE/closed_world.py" mutants "$SAMPLE" "$CB_TESTS_COVERAGE" "$LOG_DIR/mutants.md" "$jobs" || mut=1
  echo "mutant report: $LOG_DIR/mutants.md"
fi
((bad == 0 && total_f == 0 && total_n == 0 && gate == 0 && mut == 0))
