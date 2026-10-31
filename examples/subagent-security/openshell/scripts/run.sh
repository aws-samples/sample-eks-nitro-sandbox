#!/usr/bin/env bash
# run.sh -- create one fresh OpenShell sandbox, run the procurement case in it, and
# check every claim this sample's page makes.
#
# Usage:
#   ./scripts/run.sh
#
# Each run creates a new sandbox from the template and gets its own run id, so one run
# cannot read or resume another's workspace. It leaves the gateway, the supplier API and
# the bridge running; ./scripts/clean.sh removes everything.
#
# The walkthrough prints PASS or FAIL for each check and stops at the first one that does
# not hold, so a failure is never reported as a pass. Its evidence, including the
# recommendation, the per-operation results, the supervisor log and the backend request
# logs, is written under the repository's tmp/.
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
STATE_FILE="$REPO_ROOT/tmp/subagent-security-openshell/state.env"

for arg in "$@"; do
  case "$arg" in
    --help|-h) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[[ -f "$STATE_FILE" ]] ||
  { echo "ERROR: no run record at $STATE_FILE; run ./scripts/setup.sh first" >&2; exit 1; }

exec python3 "$SAMPLE_DIR/scripts/walkthrough.py"
