#!/usr/bin/env bash
# Send the same stdout burst from the ordinary pod and the sandboxed pod: time how
# long the app's writes take, and how long kubectl logs takes to show every line.
# The sandbox streams container logs out at the rate its
# sandbox.amazonaws.com/log-bandwidth annotation allows (2M, 2 Mbit/s, by default:
# Amazon EKS User Guide, "Resource isolation and throttling").
#
# Read-only apart from the log lines it writes.
#
# Usage: scripts/run-log-burst.sh [pod ...]   # default: app-standard app-sandboxed
# Env:   NAMESPACE (default sandbox-logging)
#        BURST_MB  (default 4: the kubelet rotates a container log at 10 MiB, and
#                   kubectl logs reads only the current file)
set -euo pipefail
cd "$(dirname "$0")/.."

NAMESPACE=${NAMESPACE:-sandbox-logging}
BURST_MB=${BURST_MB:-4}
pods=("$@")
[ ${#pods[@]} -gt 0 ] || pods=(app-standard app-sandboxed)
want=$(python3 -c "print(int($BURST_MB * 1000))")

for pod in "${pods[@]}"; do
  id="burst-$(date +%s)-$pod"
  echo "== $pod: $BURST_MB MB to stdout"
  start=$(date +%s)
  kubectl -n "$NAMESPACE" exec -i "$pod" -c app -- env BURST_MB="$BURST_MB" BURST_ID="$id" \
    python3 - < scripts/log-burst.py
  while :; do
    got=$(kubectl -n "$NAMESPACE" logs "$pod" -c app --since=5m | grep -c "^$id " || true)
    secs=$(( $(date +%s) - start ))
    [ "$got" -ge "$want" ] || [ "$secs" -ge 120 ] && break
    sleep 1
  done
  echo "kubectl logs shows $got of $want lines ${secs}s after the burst started"
done
