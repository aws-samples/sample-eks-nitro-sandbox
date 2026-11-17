#!/usr/bin/env bash
# wait-node-ready.sh: after the node group is ACTIVE and before any sandbox pod is applied, wait
# until this run's node is Ready AND advertises allocatable eks.amazonaws.com/nitro-sandbox > 0,
# the extended resource the shared isolated-sandbox RuntimeClass's overhead requests. A node that
# advertises none keeps every sandbox pod Pending with "Insufficient eks.amazonaws.com/nitro-sandbox".
#
#   RUN_ID=<id> KUBE_CONTEXT=<ctx> scripts/wait-node-ready.sh
#
# Overridable: NODE_READY_TIMEOUT (seconds, default 900), NODE_POLL_SECONDS (default 10).
# Every read is checked: an empty node list is "not registered yet" and a NotFound node is "gone,
# keep waiting", but any other failed read (wrong context, no permission, API or transport error)
# stops at once with "could not determine", never a misleading readiness diagnosis. At the
# timeout it fails with a message naming what was missing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
require_run_id
[ -n "${KUBE_CONTEXT:-}" ] || die "KUBE_CONTEXT is not set; set it to the kubectl context of cluster $CLUSTER_NAME (never the current context)"
: "${NODE_READY_TIMEOUT:=900}"
: "${NODE_POLL_SECONDS:=10}"
ERR=$(mktemp); trap 'rm -f "$ERR"' EXIT

# kread <var> <what> <kubectl args...>: the output in <var>; 1 (and <var> empty) on NotFound;
# any other failure dies with "could not determine".
kread() {
  local __v="$1" what="$2" out; shift 2
  if out=$(kc "$@" 2>"$ERR"); then
    printf -v "$__v" '%s' "$out"; return 0
  fi
  printf -v "$__v" '%s' ""
  grep -q 'NotFound' "$ERR" && return 1
  die "could not determine $what (kubectl failed, not a report that it is absent or not ready): $(head -n 2 "$ERR")"
}

deadline=$((SECONDS + NODE_READY_TIMEOUT))
node=""; ready=""; capacity=""
while :; do
  kread node "the nodes of node group $NODEGROUP_NAME" get nodes -l "eks.amazonaws.com/nodegroup=${NODEGROUP_NAME}" -o jsonpath='{.items[0].metadata.name}' || node=""
  ready=""; capacity=""
  if [[ -n "$node" ]]; then
    if kread ready "the Ready condition of node $node" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
       && kread capacity "the nitro-sandbox capacity of node $node" get node "$node" -o jsonpath='{.status.allocatable.eks\.amazonaws\.com/nitro-sandbox}'; then
      if [[ "$ready" == True && "$capacity" =~ ^[0-9]+$ && "$capacity" -gt 0 ]]; then
        log "node $node is Ready and advertises allocatable eks.amazonaws.com/nitro-sandbox=$capacity"
        [ -n "${EVIDENCE_DIR:-}" ] && mkdir -p "$EVIDENCE_DIR" && printf 'NODE_NITRO_SANDBOX_ALLOCATABLE=%q\n' "$node=$capacity" >> "$EVIDENCE_DIR/run-evidence.env"
        exit 0
      fi
    else
      node=""   # the node went away between the list and the read: keep waiting
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
