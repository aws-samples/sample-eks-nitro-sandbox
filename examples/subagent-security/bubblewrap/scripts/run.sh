#!/usr/bin/env bash
# run.sh -- run one procurement case in the sandboxed analyst pod and copy its
# recommendation and evidence out.
#
# Usage:
#   ./scripts/run.sh
#
# Each run gets a fresh run id and its own directories inside the pod, so one run cannot
# read or resume another's. When it succeeds it leaves both pods running for the page's
# last step; ./scripts/clean.sh removes them, and so does the run's own deadline. When it
# fails, it runs ./scripts/clean.sh --delete-aws --delete-node itself, keeping what the run
# printed in tmp/bubblewrap-run-failure/.
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/bubblewrap"
STATE_FILE="$TMP_DIR/state.env"

for arg in "$@"; do
  case "$arg" in
    --help|-h) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[[ -f "$STATE_FILE" ]] || { echo "ERROR: no run record at $STATE_FILE; run ./scripts/setup.sh first" >&2; exit 1; }
set -a; . "$STATE_FILE"; set +a

kc() {
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"
  else kubectl "$@"; fi
}
die() { echo "ERROR: $*" >&2; exit 1; }

# A run that fails for any reason removes what setup created, so nothing it started keeps
# running or billing. What it printed is kept first, outside the run directory.
on_run_exit() {
  local status=$?
  [[ "$status" != 0 ]] || return 0
  trap - EXIT
  echo "the run stopped (exit $status); removing what setup created so nothing it started keeps billing" >&2
  rm -rf "$REPO_ROOT/tmp/bubblewrap-run-failure"
  mkdir -p "$REPO_ROOT/tmp/bubblewrap-run-failure"
  cp -R "$TMP_DIR/controller.log" "$TMP_DIR/runs" "$REPO_ROOT/tmp/bubblewrap-run-failure/" 2>/dev/null || true
  "$SAMPLE_DIR/scripts/clean.sh" --delete-aws --delete-node ||
    echo "the clean up after the failed run is incomplete (see above); run ./scripts/clean.sh --delete-aws --delete-node again" >&2
  exit "$status"
}
trap on_run_exit EXIT

# The pod has to be the one setup created, with the image setup pushed: a pod left from an
# earlier image would run yesterday's code and the page would show the wrong thing.
live_image="$(kc get pod analyst -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)" ||
  die "could not read the analyst pod in $NAMESPACE"
[[ "$live_image" == "$ANALYST_IMAGE" ]] ||
  die "the running analyst pod uses $live_image, not the $ANALYST_IMAGE setup pushed"
[[ "$(kc get pod analyst -n "$NAMESPACE" -o jsonpath='{.spec.runtimeClassName}')" == "isolated-sandbox" ]] ||
  die "the analyst pod is not using the isolated-sandbox runtime class"

# The same cost bound setup checked, again before the model turn: the very collection setup
# read, rebuilt from its raw reads, with the image sizes setup measured, and only inside the
# run window that starts when setup did. Silent when it passes.
[[ -n "${COST_SNAPSHOT:-}" && -d "$COST_SNAPSHOT" ]] ||
  die "the run record names no cost snapshot, or its folder is gone"
SECTION_DIR="$SAMPLE_DIR/.."
terms="$(python3 "$SAMPLE_DIR/scripts/cost_gate.py" --snapshot "$COST_SNAPSHOT" \
  --manifest "$SAMPLE_DIR/deploy/analyst-pod.yaml" \
  --envelope "$SAMPLE_DIR/src/run_envelope.json" --region "$AWS_REGION" \
  --account "${ACCOUNT_ID:-}" --cluster-name "${CLUSTER_NAME:-}" --kube-context "${KUBE_CONTEXT:-}" \
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

mkdir -p "$TMP_DIR"
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
api_pod="$(kc get pods -n "$NAMESPACE" -l app=supplier-api \
  -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$api_pod" ]] || die "no supplier API pod is running in $NAMESPACE"
kc exec "$api_pod" -n "$NAMESPACE" -- cat /var/lib/supplier/requests.jsonl \
  > "$out/supplier-api-requests.jsonl" ||
  die "could not read the supplier API request log"

python3 "$SAMPLE_DIR/scripts/correlate.py" "$out/evidence.json" \
  "$out/supplier-api-requests.jsonl"

printf '\n==> done\n'
echo "  run id:         $run_id"
echo "  recommendation: $out/recommendation.md"
echo "  evidence:       $out/evidence.json"
echo "  S3 report:      s3://$BUCKET/reports/rfp-001/$run_id/"
