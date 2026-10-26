#!/usr/bin/env bash
# run.sh -- run one procurement case in the sandboxed analyst pod and copy its
# recommendation and evidence out.
#
# Usage:
#   ./scripts/run.sh
#
# Each run gets a fresh run id and its own directories inside the pod, so one run cannot
# read or resume another's. It leaves both pods running; ./scripts/clean.sh removes them.
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/nono"
STATE_FILE="$TMP_DIR/state.env"

for arg in "$@"; do
  case "$arg" in
    --help|-h) sed -n '2,11p' "$0"; exit 0 ;;
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

# The pod has to be the one setup created, with the image setup pushed: a pod left from an
# earlier image would run yesterday's code and the page would show the wrong thing.
live_image="$(kc get pod analyst -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)" ||
  die "could not read the analyst pod in $NAMESPACE; run ./scripts/setup.sh"
[[ "$live_image" == "$ANALYST_IMAGE" ]] ||
  die "the running analyst pod uses $live_image, not the $ANALYST_IMAGE setup pushed; run ./scripts/setup.sh again"
[[ "$(kc get pod analyst -n "$NAMESPACE" -o jsonpath='{.spec.runtimeClassName}')" == "isolated-sandbox" ]] ||
  die "the analyst pod is not using the isolated-sandbox runtime class"

mkdir -p "$TMP_DIR"
printf '\n==> running one procurement case in the sandbox\n'
set +e
kc exec analyst -n "$NAMESPACE" -- python3 /opt/nono/controller.py 2>&1 |
  tee "$TMP_DIR/controller.log"
status="${PIPESTATUS[0]}"
set -e
[[ "$status" == 0 ]] ||
  die "the run failed; the last check it printed above is the one that did not hold. The full output is in $TMP_DIR/controller.log"

run_id="$(grep -oE '^ANALYST_COMPLETE=[0-9a-f]{32}$' "$TMP_DIR/controller.log" | tail -1 | cut -d= -f2)"
[[ -n "$run_id" ]] || die "the run printed no completion marker, so it did not finish"

out="$TMP_DIR/runs/$run_id"
mkdir -p "$out"
for f in recommendation.md evidence.json checks.json calls.json; do
  kc exec analyst -n "$NAMESPACE" -- cat "/var/lib/analyst/$run_id/$f" > "$out/$f" ||
    die "could not copy $f out of the pod"
done

# The supplier API's own log, read from its pod rather than from the analyst's evidence,
# so an allowed request can be shown to have arrived exactly once and a refused one never
# to have arrived at all.
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
