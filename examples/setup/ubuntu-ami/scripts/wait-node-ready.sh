#!/usr/bin/env bash
# wait-node-ready.sh: after the node group is ACTIVE and before any sandbox pod is applied, wait
# until the sample's node is Ready AND advertises allocatable eks.amazonaws.com/nitro-sandbox > 0,
# the extended resource the shared isolated-sandbox RuntimeClass's overhead requests. A node that
# advertises none keeps every sandbox pod Pending with "Insufficient eks.amazonaws.com/nitro-sandbox".
#
#   KUBECTL="kubectl --context <ctx>" scripts/wait-node-ready.sh
#
# Overridable: NODEGROUP_NAME, KUBECTL, NODE_READY_TIMEOUT (seconds, default 900),
# NODE_POLL_SECONDS (default 10). Fails with a message naming what was missing at the timeout.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
KUBECTL="${KUBECTL:-kubectl}"
NODEGROUP_NAME="${NODEGROUP_NAME:-${RESOURCE_PREFIX}-ng}"
: "${NODE_READY_TIMEOUT:=900}"
: "${NODE_POLL_SECONDS:=10}"

deadline=$((SECONDS + NODE_READY_TIMEOUT))
node=""; ready=""; capacity=""
while :; do
  node=$($KUBECTL get nodes -l "eks.amazonaws.com/nodegroup=${NODEGROUP_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -n "$node" ]]; then
    ready=$($KUBECTL get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    capacity=$($KUBECTL get node "$node" -o jsonpath='{.status.allocatable.eks\.amazonaws\.com/nitro-sandbox}' 2>/dev/null)
    if [[ "$ready" == True && "$capacity" =~ ^[0-9]+$ && "$capacity" -gt 0 ]]; then
      log "node $node is Ready and advertises allocatable eks.amazonaws.com/nitro-sandbox=$capacity"
      [ -n "${EVIDENCE_DIR:-}" ] && printf 'NODE_NITRO_SANDBOX_ALLOCATABLE=%q\n' "$node=$capacity" >> "$EVIDENCE_DIR/run-evidence.env"
      exit 0
    fi
  fi
  if (( SECONDS >= deadline )); then
    if [[ -z "$node" ]]; then
      die "no node labelled eks.amazonaws.com/nodegroup=${NODEGROUP_NAME} registered within ${NODE_READY_TIMEOUT}s (check the launch template user data and the node's kubelet log over SSM)"
    elif [[ "$ready" != True ]]; then
      die "node $node is not Ready after ${NODE_READY_TIMEOUT}s (Ready=${ready:-<unknown>}); check the vpc-cni add-on (scripts/00c-check-cluster.sh) and kubelet on the node"
    fi
    die "node $node is Ready but advertises allocatable eks.amazonaws.com/nitro-sandbox='${capacity:-<none>}' after ${NODE_READY_TIMEOUT}s; no sandbox pod could schedule. Check cri-proxy.service and /dev/nitro_enclaves on the node; no sandbox pod was applied"
  fi
  sleep "$NODE_POLL_SECONDS"
done
