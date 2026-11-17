#!/usr/bin/env bash
# deadline.sh -- the run's clean-up deadline. setup.sh starts it in the background; it is
# not meant to be run by hand.
#
# Usage: deadline.sh <run record> <clean-up time, seconds since the epoch>
#
# It waits until that time by the wall clock, checking every 30 seconds, so a machine that
# sleeps through the deadline acts as soon as it wakes. Then, if the run record is still
# there and still names that same deadline, it runs ./scripts/clean.sh --delete-aws
# --delete-node; if you removed the run first, or a later run has replaced the record, it
# does nothing. Its output goes to tmp/bubblewrap-deadline.log.
set -uo pipefail

[[ "$#" == 2 && "$2" =~ ^[0-9]+$ ]] || { echo "usage: deadline.sh <run record> <epoch>" >&2; exit 2; }
state="$1" at="$2"

while (( $(date -u +%s) < at )); do sleep 30; done

if [[ ! -f "$state" ]] || ! grep -qx "CLEANUP_AT_EPOCH=$at" "$state"; then
  echo "$(date -u +%FT%TZ) the run with clean-up deadline $at is already gone; nothing to do"
  exit 0
fi
echo "$(date -u +%FT%TZ) the run reached its clean-up deadline; running clean.sh --delete-aws --delete-node"
exec "$(cd "$(dirname "$0")" && pwd)/clean.sh" --delete-aws --delete-node
