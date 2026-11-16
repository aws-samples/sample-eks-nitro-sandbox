#!/usr/bin/env bash
# Deploy app-sandboxed-detector (the sandboxed app pod with the in-guest detector), run the
# four test events in it and in the two pods from run-comparison.sh, and print the
# detector's alerts. It alerts on its own pod only: the other two pods' events never reach
# its guest kernel.
#
#   scripts/run-detector.sh      # run scripts/run-comparison.sh first
#
# Overridable: NAMESPACE (default runtime-detection), KUBE_CONTEXT (default: current).
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NAMESPACE="${NAMESPACE:-runtime-detection}"
KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
export NAMESPACE KUBE_CONTEXT

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
kc() { kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" "$@"; }

mark="$(kubectl --context "$KUBE_CONTEXT" get namespace "$NAMESPACE" --ignore-not-found \
  -o 'jsonpath={.metadata.labels.sample}')" || die "could not read namespace '$NAMESPACE'"
[[ "$mark" == "runtime-detection" ]] \
  || die "namespace '$NAMESPACE' is missing or not this blueprint's; run scripts/run-comparison.sh first"

kc create configmap guest-detector --from-file="$SAMPLE_DIR/deploy/guest-detector.py" \
  --dry-run=client -o yaml | kc apply -f -
# The manifest names the namespace runtime-detection; render it with $NAMESPACE instead.
sed "s|^  namespace: runtime-detection |  namespace: $NAMESPACE |" \
  "$SAMPLE_DIR/deploy/app-sandboxed-detector.yaml" | kc apply -f -
kc wait pod/app-sandboxed-detector --for=condition=Ready --timeout=600s

start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for pod in app-sandboxed-detector app-sandboxed app-standard; do
  "$SAMPLE_DIR/scripts/trigger-events.sh" "$pod"
done
sleep 5
echo
echo "=== app-sandboxed-detector: the detector's output since the events started ==="
kc logs app-sandboxed-detector -c detector --since-time="$start"
log="$(kc logs app-sandboxed-detector -c detector --since-time="$start")"
alerts="$(printf '%s\n' "$log" | grep -c '"rule"' || true)"
rules="$(printf '%s\n' "$log" | grep -oE '"rule": "[^"]*"' | sort -u | wc -l | tr -d ' ')"
echo
echo "=== Verdict ==="
if [[ "$alerts" -eq 4 && "$rules" -eq 4 ]]; then
  echo "RESULT: the in-guest detector raised 4 alerts, one for each test event in its own pod,"
  echo "and none for the same events in app-sandboxed or app-standard."
else
  echo "UNEXPECTED: the detector raised $alerts alerts ($rules distinct rules) for 12 test events"
  echo "in 3 pods; 4 were expected, one for each test event in its own pod."
  exit 1
fi
