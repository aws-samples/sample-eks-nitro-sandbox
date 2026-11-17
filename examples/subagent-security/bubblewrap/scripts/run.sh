#!/usr/bin/env bash
# run.sh -- run the procurement case in the sandboxed analyst pod, once, and copy its
# recommendation and evidence out.
#
# Usage:
#   ./scripts/run.sh
#
# One setup gets one model turn: a second run.sh against the same run record refuses before
# it reaches the pod, and so does the controller inside the pod. When it succeeds it leaves
# both pods running for the page's last step; ./scripts/clean.sh removes them, and so does
# the run's own deadline. When it fails, it runs ./scripts/clean.sh --delete-aws
# --delete-node itself, keeping what the run printed in tmp/bubblewrap-run-failure/.
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
SAMPLE="bubblewrap"

for arg in "$@"; do
  case "$arg" in
    --help|-h) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
# shellcheck source=run-lib.sh
. "$SAMPLE_DIR/scripts/run-lib.sh"
kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }

# A run that fails once it has started removes what setup created, so nothing it started
# keeps running or billing. What it printed is kept first, outside the run directory. A
# refusal before that point (no record, a second run, another script holding the lock)
# leaves the first run exactly as it was.
clean_on_failure=false
on_run_exit() {
  local status=$?
  trap - EXIT
  if [[ "$status" != 0 && "$clean_on_failure" == true ]]; then
    echo "the run stopped (exit $status); removing what setup created so nothing it started keeps billing" >&2
    rm -rf "$REPO_ROOT/tmp/bubblewrap-run-failure"
    mkdir -p "$REPO_ROOT/tmp/bubblewrap-run-failure"
    cp -R "$TMP_DIR/controller.log" "$TMP_DIR/runs" "$REPO_ROOT/tmp/bubblewrap-run-failure/" 2>/dev/null || true
    "$SAMPLE_DIR/scripts/clean.sh" --delete-aws --delete-node ||
      echo "the clean up after the failed run is incomplete (see above); run ./scripts/clean.sh --delete-aws --delete-node again" >&2
  fi
  lock_release
  exit "$status"
}
trap on_run_exit EXIT

lock_take 0 ||
  die "another setup, run or clean up of this sample holds $LOCK_DIR; ran nothing"
state_load ||
  die "no readable run record at $STATE_FILE; run ./scripts/setup.sh first"
[[ -n "${KUBE_CONTEXT:-}" ]] || die "the run record names no kube context; ran nothing"
[[ ! -e "$TMP_DIR/model-turn" ]] ||
  die "this run's model turn has already run once, and one setup pays for one. Clean up with ./scripts/clean.sh --delete-aws --delete-node and set up again for another."
clean_on_failure=true

# The deadline process setup started must still be there: it is the clean up that runs at
# the deadline, and the model turn is the one paid step of the run.
ps -o args= -p "${DEADLINE_PID:-0}" 2>/dev/null | grep -q "deadline\\.sh .*${CLEANUP_AT_EPOCH:-none}" ||
  die "the clean-up deadline process setup started (pid ${DEADLINE_PID:-none}) is no longer running; nothing was run"

# The pod has to be the one setup created, with the image setup pushed, by digest.
live_image="$(kc get pod analyst -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)" ||
  die "could not read the analyst pod in $NAMESPACE"
[[ "$live_image" == "$ANALYST_IMAGE" ]] ||
  die "the running analyst pod uses $live_image, not the $ANALYST_IMAGE setup pushed"
[[ "$(kc get pod analyst -n "$NAMESPACE" -o jsonpath='{.spec.runtimeClassName}')" == "isolated-sandbox" ]] ||
  die "the analyst pod is not using the isolated-sandbox runtime class"

# The same cost bound setup checked, again before the model turn: the reads setup collected,
# rebuilt, with the image sizes setup measured, and only inside the run window that starts
# when setup did. Silent when it passes.
[[ -n "${COST_SNAPSHOT:-}" && -d "$COST_SNAPSHOT" ]] ||
  die "the run record names no cost snapshot, or its folder is gone"
SECTION_DIR="$SAMPLE_DIR/.."
terms="$(python3 "$SAMPLE_DIR/scripts/cost_gate.py" --snapshot "$COST_SNAPSHOT" \
  --manifest "$SAMPLE_DIR/deploy/analyst-pod.yaml" \
  --envelope "$SAMPLE_DIR/src/run_envelope.json" --region "$AWS_REGION" \
  --account "${ACCOUNT_ID:-}" --cluster-name "${CLUSTER_NAME:-}" --kube-context "$KUBE_CONTEXT" \
  --extra-s3 "${COST_EXTRA_S3_REQUESTS:-}" \
  --model-id "${BEDROCK_MODEL_ID:-}" --image "supplier-api=${SUPPLIER_API_IMAGE_BYTES:-}" \
  --image "analyst=${ANALYST_IMAGE_BYTES:-}" --started-at "${RUN_STARTED_AT:-}" \
  --seed-object "$SECTION_DIR/analyst/fixtures/case.json" \
  --seed-object "$SECTION_DIR/analyst/fixtures/proposals/northstar.json" \
  --seed-object "$SECTION_DIR/analyst/fixtures/proposals/harbor.json" \
  --seed-object "$SECTION_DIR/analyst/fixtures/proposals/cedar.json")" ||
  die "the cost check refused this run, for the reason above; nothing was run"
[[ "$(jq -r '.snapshot_sha256' <<<"$terms")" == "${COST_SNAPSHOT_SHA256:-}" ]] ||
  die "the cost snapshot $COST_SNAPSHOT changed after setup checked it; nothing was run"

# Once only: mkdir is the claim, in one syscall, before the controller starts.
mkdir "$TMP_DIR/model-turn" || die "this run's model turn has already started once; nothing was run"
state_put MODEL_TURN_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '\n==> running one procurement case in the sandbox\n'
set +e
kc exec analyst -n "$NAMESPACE" -- python3 /opt/bubblewrap/controller.py 2>&1 |
  tee "$TMP_DIR/controller.log"
status="${PIPESTATUS[0]}"
set -e
[[ "$status" == 0 ]] ||
  die "the run failed; the last check it printed above is the one that did not hold. The full output is kept in $REPO_ROOT/tmp/bubblewrap-run-failure/controller.log"

run_id="$(grep -oE '^ANALYST_COMPLETE=[0-9a-f]{32}$' "$TMP_DIR/controller.log" | tail -1 | cut -d= -f2)"
[[ -n "$run_id" ]] || die "the run printed no completion marker, so it did not finish"

out="$TMP_DIR/runs/$run_id"
mkdir -p "$out"
for f in recommendation.md evidence.json checks.json calls.json; do
  kc exec analyst -n "$NAMESPACE" -- cat "/var/lib/analyst/$run_id/$f" > "$out/$f" ||
    die "could not copy $f out of the pod"
done

# The supplier API's own log, read from its pod rather than from the analyst's evidence,
# so the requests that arrived upstream can be compared with what the controller says it
# sent. In this sample no tool process has a network, so the point of the comparison is
# that the only requests the server saw are the trusted controller's own.
kc exec supplier-api -n "$NAMESPACE" -- cat /var/lib/supplier/requests.jsonl \
  > "$out/supplier-api-requests.jsonl" ||
  die "could not read the supplier API request log"

python3 "$SAMPLE_DIR/scripts/correlate.py" "$out/evidence.json" \
  "$out/supplier-api-requests.jsonl"

printf '\n==> done\n'
echo "  run id:         $run_id"
echo "  recommendation: $out/recommendation.md"
echo "  evidence:       $out/evidence.json"
echo "  S3 report:      s3://$BUCKET/reports/rfp-001/$run_id/"
