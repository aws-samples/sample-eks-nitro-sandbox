#!/usr/bin/env bash
# wait-pods-ready.sh: bounded wait for the named pods in the sample's namespace to be Ready, so
# test.sh reads live evidence only from running workloads (setup.sh applies the pods and returns
# at once). Reports every pod's state at the end.
#
#   KUBE_CONTEXT=<ctx> scripts/wait-pods-ready.sh <pod>...
#
# Overridable: NAMESPACE, POD_READY_TIMEOUT (seconds, default 300), POD_POLL_SECONDS
# (default 5). Exit 0 when every pod is Ready; 1 at the timeout, naming each pod that is not and
# its phase and waiting reason; 1 at once, with "could not determine", when a read fails for a
# reason other than NotFound (a pod not created yet is waited for, not refused).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
[ -n "${KUBE_CONTEXT:-}" ] || die "KUBE_CONTEXT is not set; set it to the kubectl context of cluster $CLUSTER_NAME (never the current context)"
: "${POD_READY_TIMEOUT:=300}"
: "${POD_POLL_SECONDS:=5}"
[ $# -gt 0 ] || die "usage: wait-pods-ready.sh <pod>..."
ERR=$(mktemp); trap 'rm -f "$ERR"' EXIT

pod_state() { # pod_state <pod>: prints "<ready> <phase> <reason>"; 3 on NotFound; dies (1) on other errors
  local out
  if out=$(kc get pod "$1" -n "$NAMESPACE" -o json 2>"$ERR"); then
    printf '%s' "$out" | json_get '(lambda s: " ".join([next((c["status"] for c in s.get("conditions", []) if c["type"] == "Ready"), "False"), s.get("phase", "Unknown"), next((x.get("state", {}).get("waiting", {}).get("reason", "") for x in s.get("containerStatuses", []) if x.get("state", {}).get("waiting")), "") or "-"]))(d.get("status", {}))'
    return 0
  fi
  grep -q 'NotFound' "$ERR" && return 3
  die "could not determine the state of pod $1 in $NAMESPACE (kubectl failed): $(head -n 2 "$ERR")"
}

deadline=$((SECONDS + POD_READY_TIMEOUT))
while :; do
  not_ready=()
  for p in "$@"; do
    rc=0; st=$(pod_state "$p") || rc=$?
    if [ "$rc" = 0 ]; then
      read -r ready phase reason <<<"$st"
      [ "$ready" = True ] || not_ready+=("$p (phase $phase, waiting reason $reason)")
    elif [ "$rc" = 3 ]; then
      not_ready+=("$p (not created yet)")
    else
      exit 1
    fi
  done
  if [ "${#not_ready[@]}" -eq 0 ]; then
    log "pods Ready in $NAMESPACE: $*"
    exit 0
  fi
  if (( SECONDS >= deadline )); then
    printf 'FAIL: not Ready after %ss in %s:\n' "$POD_READY_TIMEOUT" "$NAMESPACE" >&2
    printf '  %s\n' "${not_ready[@]}" >&2
    exit 1
  fi
  sleep "$POD_POLL_SECONDS"
done
