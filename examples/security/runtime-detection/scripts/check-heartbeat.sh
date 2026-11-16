#!/usr/bin/env bash
# Check that a pod's in-guest detector is alive: find its latest heartbeat in CloudWatch Logs
# and fail when there is none in the last MAX_AGE seconds. A detector that was killed or
# blinded stops writing heartbeats, so silence is itself the alert.
#
#   scripts/check-heartbeat.sh <pod>   # e.g. app-sandboxed-detector
#
# Needs the Amazon CloudWatch Observability add-on, which ships container logs to
# /aws/containerinsights/<cluster>/application. Read-only.
#
# Overridable: CLUSTER_NAME (default sandbox-demo), AWS_REGION (default us-west-2),
# NAMESPACE (default runtime-detection), MAX_AGE (default 180, three heartbeats).
set -euo pipefail

POD="${1:?usage: scripts/check-heartbeat.sh <pod>}"
CLUSTER_NAME="${CLUSTER_NAME:-sandbox-demo}"
REGION="${AWS_REGION:-us-west-2}"
NAMESPACE="${NAMESPACE:-runtime-detection}"
MAX_AGE="${MAX_AGE:-180}"
GROUP="/aws/containerinsights/$CLUSTER_NAME/application"

now="$(date +%s)"
pattern="{ (\$.kubernetes.namespace_name = \"$NAMESPACE\") && (\$.kubernetes.pod_name = \"$POD\") && (\$.log = \"*heartbeat*\") }"
# The CLI pages through the results, so take the latest timestamp across every page.
stamps="$(aws logs filter-log-events --region "$REGION" --log-group-name "$GROUP" \
  --start-time "$(( (now - MAX_AGE) * 1000 ))" --filter-pattern "$pattern" \
  --query 'events[].timestamp' --output text)" \
  || { echo "could not read $GROUP; the check cannot tell whether the detector is alive" >&2; exit 2; }
last_ms="$(printf '%s\n' $stamps | grep -E '^[0-9]+$' | sort -n | tail -1 || true)"

if [[ -z "$last_ms" ]]; then
  echo "ALERT: no heartbeat from $NAMESPACE/$POD in the last ${MAX_AGE}s"
  exit 1
fi
echo "OK: last heartbeat from $NAMESPACE/$POD was $(( now - last_ms / 1000 ))s ago (limit ${MAX_AGE}s)"
