#!/usr/bin/env bash
# Run the trusted controller and cross-check its receipts with the supplier log.
# Usage: ./scripts/run.sh
# Run uses the saved namespace, Region, bucket, role, model and image; it has no target defaults.
set -euo pipefail
umask 077
source "$(dirname "$0")/common.sh"
for arg in "$@"; do
  case "$arg" in
    --help|-h) sed -n '2,4p' "$0"; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done
box_load_env
box_load_state
[[ "${SETUP_COMPLETE:-false}" == true ]] || die "setup did not finish; run ./scripts/setup.sh again"
for name in BUCKET ROLE_NAME BEDROCK_MODEL_ID ANALYST_IMAGE; do
  [[ -n "${!name:-}" ]] || die "the setup record has no $name; run ./scripts/setup.sh again"
done
box_check_target
[[ "$(box_namespace_state)" == owned ]] || die "the sample namespace is absent"
pod="$(kc get pod analyst -n "$NAMESPACE" -o json)"
deployment="$(python3 "$SAMPLE_DIR/scripts/verify_pod.py" --mode "$DEPLOYMENT_MODE" \
  --image "$ANALYST_IMAGE" --namespace "$NAMESPACE" --region "$AWS_REGION" \
  --bucket "$BUCKET" --role "$ROLE_NAME" --model "$BEDROCK_MODEL_ID" <<<"$pod")"
node="$(jq -er '.worker_node' <<<"$deployment")"
worker="$(kc get node "$node" -o json)"
jq -e --arg node "$node" '.metadata.name==$node and .status.nodeInfo.architecture=="arm64"' \
  <<<"$worker" >/dev/null || die "could not confirm the analyst's ARM64 worker identity"
if ! kc exec analyst -n "$NAMESPACE" -c analyst -- python3 /opt/strands-box/src/controller.py \
    2>&1 | tee "$TMP_DIR/controller.log"; then
  die "the controller or log collection failed; see $TMP_DIR/controller.log"
fi
run_id="$(python3 - "$TMP_DIR/controller.log" <<'MARKER'
import re
import sys
from pathlib import Path
markers = re.findall(r'^ANALYST_COMPLETE=([0-9a-f]{32})$', Path(sys.argv[1]).read_text(), re.M)
if len(markers) != 1:
    sys.exit('Expected exactly one ANALYST_COMPLETE marker')
print(markers[0])
MARKER
)"
out="$TMP_DIR/runs/$run_id"
mkdir -p "$out"
printf '%s\n' "$pod" > "$out/analyst-pod.json"
printf '%s\n' "$worker" > "$out/worker-node.json"
printf '%s\n' "$deployment" > "$out/deployment.json"
for file in checks.json calls.json evidence.json recommendation.md; do
  kc exec analyst -n "$NAMESPACE" -c analyst -- cat "/var/lib/analyst/$run_id/$file" > "$out/$file"
done
kc exec analyst -n "$NAMESPACE" -c analyst -- cat "/var/lib/analyst/$run_id/filesystem-checks.json"   > "$out/filesystem-checks.json"
for role in reader evaluator writer fresh-writer; do
  mkdir -p "$out/broker/$role"
  kc exec analyst -n "$NAMESPACE" -c analyst -- cat "/var/lib/analyst/$run_id/broker/$role/box-records.jsonl" \
    > "$out/broker/$role/box-records.jsonl"
  kc exec analyst -n "$NAMESPACE" -c analyst -- cat "/var/lib/analyst/$run_id/broker/$role/box-identity.json" \
    > "$out/broker/$role/box-identity.json"
done
pods="$(kc get pods -n "$NAMESPACE" -l app=supplier-api -o json)"
api_pod="$(jq -er '[.items[] | select(.metadata.deletionTimestamp == null) |
  select(.status.phase=="Running") |
  select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))] |
  if length==1 then .[0].metadata.name else error("expected one ready supplier pod") end' <<<"$pods")"
kc exec "$api_pod" -n "$NAMESPACE" -- cat /var/lib/supplier/requests.jsonl > "$out/supplier-api-requests.jsonl"
python3 "$SAMPLE_DIR/scripts/correlate.py" --require-cloud "$out/evidence.json" \
  "$out/supplier-api-requests.jsonl"
kc exec analyst -i -n "$NAMESPACE" -- python3 - \
  < "$SAMPLE_DIR/scripts/observe_kernel.py" > "$out/analyst-kernel.json"
if [[ "$DEPLOYMENT_MODE" == nitro ]]; then
  # A same-node ordinary pod provides worker observations beside the Nitro guest.
  [[ "$(box_namespace_state)" == owned ]] || die "the namespace disappeared before the ordinary-pod observation"
  analyst_render "$SAMPLE_DIR/deploy/ordinary-pod.yaml" "$TMP_DIR/ordinary-pod.yaml" \
    "s|<NODE_NAME>|$node|g" "s|<ANALYST_IMAGE>|$ANALYST_IMAGE|g"
  kc delete pod ordinary-control -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=3m
  kc apply -n "$NAMESPACE" -f "$TMP_DIR/ordinary-pod.yaml"
  kc wait pod/ordinary-control -n "$NAMESPACE" --for=condition=Ready --timeout=5m
  [[ "$(kc get pod ordinary-control -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')" == "$node" ]] ||
    die "the ordinary control is not on the analyst's worker node"
  kc exec ordinary-control -i -n "$NAMESPACE" -- python3 - \
    < "$SAMPLE_DIR/scripts/observe_kernel.py" > "$out/ordinary-control-kernel.json"
fi
python3 "$SAMPLE_DIR/scripts/compare_kernels.py" "$out" "$node" "$DEPLOYMENT_MODE"
printf '\nRun: %s\nRecommendation: %s\nEvidence: %s\n' "$run_id" "$out/recommendation.md" "$out"
