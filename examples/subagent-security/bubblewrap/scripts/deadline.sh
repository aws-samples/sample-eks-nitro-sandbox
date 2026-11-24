#!/usr/bin/env bash
# deadline.sh -- the run's clean-up deadline on this machine. setup.sh starts it in the
# background and waits for its answer; it is not meant to be run by hand.
#
# Usage: deadline.sh <run record> <clean-up time, seconds since the epoch>
#
# It writes its process id and that time to deadline.ack in the run directory, so setup.sh
# knows it is running, then sleeps until that time by the wall clock, never more than 30
# seconds at once, so a machine that sleeps through the deadline acts as soon as it wakes
# and one that does not acts within a second of it. Then it takes the run lock (waiting up to
# five minutes for a setup or run.sh still holding it) and, if the run record is still there
# and still names that same deadline, runs ./scripts/clean.sh --delete-aws --delete-node; if
# you removed the run first, or a later run has replaced the record, it does nothing.
# The clean up it starts is killed after CLEAN_HARD_S, whatever it is doing, which is the
# bound the cost check reads. Its output goes to tmp/bubblewrap-deadline.log.
#
# It is the second of two ways a run ends. The first needs nothing on this machine: both
# pods stop themselves at the same time, and EKS Auto Mode removes the empty node.
set -uo pipefail
# Never setup's lock: this process waits for it like any other script.
unset BUBBLEWRAP_LOCK_TOKEN
# clean.sh's own budget (CLEAN_BUDGET_S) and one last call (CALL_TIMEOUT_S) fit inside this.
CLEAN_HARD_S=2700

[[ "$#" == 2 && "$2" =~ ^[0-9]+$ ]] || { echo "usage: deadline.sh <run record> <epoch>" >&2; exit 2; }
state="$1" at="$2"
REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SAMPLE="bubblewrap"
die() { echo "$(date -u +%FT%TZ) ERROR: $*" >&2; exit 1; }
# shellcheck source=run-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/run-lib.sh"
TIMEOUT="$(command -v timeout || command -v gtimeout)" ||
  die "timeout (GNU coreutils; gtimeout on macOS) is required; the clean up will not run"

ack="$(mktemp "$TMP_DIR/deadline.ack.XXXXXX")" || die "could not answer setup.sh"
{ printf '%s %s\n' "$$" "$at" > "$ack" && mv -f "$ack" "$TMP_DIR/deadline.ack"; } ||
  die "could not answer setup.sh"

while now="$(date -u +%s)" && (( now < at )); do
  sleep $(( at - now < 30 ? at - now : 30 ))
done

lock_take 300 || die "a setup, run or clean up still held $LOCK_DIR after five minutes; the clean up did not run"
# Checked under the lock, so a run.sh that cleaned up after itself while this waited is seen.
if [[ ! -f "$state" ]] || ! jq -e --arg at "$at" '.CLEANUP_AT_EPOCH == $at' "$state" >/dev/null 2>&1; then
  echo "$(date -u +%FT%TZ) the run with clean-up deadline $at is already gone; nothing to do"
  lock_release
  exit 0
fi
echo "$(date -u +%FT%TZ) the run reached its clean-up deadline; running clean.sh --delete-aws --delete-node"
"$TIMEOUT" -k 30 "$CLEAN_HARD_S" "$(cd "$(dirname "$0")" && pwd)/clean.sh" --delete-aws --delete-node
status=$?
lock_release
exit "$status"
