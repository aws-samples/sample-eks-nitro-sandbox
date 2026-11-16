#!/usr/bin/env bash
# For app-standard and app-sandboxed, check where each of the five log sources
# ends up, and print one table:
#
#   stdout, stderr  kubectl logs (the kubelet's copy, which node agents read)
#   file            the pod's emptyDir folder on the node, under
#                   /var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~empty-dir/
#   syslog          the node's journal since the pod started, for "syslog <pod> seq="
#   kernel          the same journal, for the kernel's "<pod>[pid]: segfault at 0"
#
# The node checks run in a node debug pod (kubectl debug node/... --profile=sysadmin)
# on each pod's node. The script deletes each debug pod it made, by name.
#
# Usage: scripts/compare.sh        # takes no arguments
# Env:   NAMESPACE (default sandbox-logging)
set -euo pipefail

NAMESPACE=${NAMESPACE:-sandbox-logging}
DEBUG_IMAGE=public.ecr.aws/amazonlinux/amazonlinux:2023
made=()
cleanup() {
  for d in "${made[@]}"; do
    kubectl -n "$NAMESPACE" delete pod "$d" --ignore-not-found --wait=false >/dev/null
  done
}
trap cleanup EXIT

label=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.sample}')
if [ "$label" != logging ]; then
  echo "namespace $NAMESPACE is not this blueprint's (label sample=$label); stopping" >&2
  exit 1
fi

yesno() { [ "$1" -gt 0 ] && echo "yes ($1)" || echo "no"; }
rows=()
for pod in app-standard app-sandboxed; do
  node=$(kubectl -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.spec.nodeName}')
  uid=$(kubectl -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.metadata.uid}')
  rc=$(kubectl -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.spec.runtimeClassName}')
  started=$(kubectl -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.status.startTime}')
  logs=$(kubectl -n "$NAMESPACE" logs "$pod" -c app)
  out=$(grep -c "^stdout $pod seq=" <<<"$logs" || true)
  err=$(grep -c "^stderr $pod seq=" <<<"$logs" || true)

  dbg=$(kubectl -n "$NAMESPACE" debug "node/$node" --profile=sysadmin --image="$DEBUG_IMAGE" \
          -- sleep 600 2>&1 | sed -n 's/^Creating debugging pod \([^ ]*\) .*/\1/p')
  [ -n "$dbg" ] || { echo "could not start a debug pod on $node" >&2; exit 1; }
  made+=("$dbg")
  kubectl -n "$NAMESPACE" wait "pod/$dbg" --for=condition=Ready --timeout=120s >/dev/null

  # The values are passed as arguments, never pasted into the remote script.
  read -r file sys kern < <(kubectl -n "$NAMESPACE" exec "$dbg" -- sh -c '
    pod=$1 uid=$2 since=$(echo "$3" | sed "s/T/ /; s/Z$/ UTC/")
    dir=/host/var/lib/kubelet/pods/$uid/volumes/kubernetes.io~empty-dir/app-logs
    f=$(cat "$dir"/*.log 2>/dev/null | grep -c "^file $pod seq=")
    j=$(chroot /host journalctl --since="$since" --no-pager -o cat)
    s=$(printf "%s\n" "$j" | grep -c "^syslog $pod seq=")
    k=$(printf "%s\n" "$j" | grep -c "^$(printf %.15s "$pod")\[[0-9]*\]: segfault at 0")
    echo "$f $s $k"' sh "$pod" "$uid" "$started")

  rows+=("$(printf '%-14s %-17s %-8s %-8s %-8s %-8s %-8s' "$pod" "${rc:-(none)}" \
    "$(yesno "$out")" "$(yesno "$err")" "$(yesno "$file")" "$(yesno "$sys")" "$(yesno "$kern")")")
done

echo
echo "Reached the node since each pod started (lines counted):"
printf '%-14s %-17s %-8s %-8s %-8s %-8s %-8s\n' pod runtimeClass stdout stderr file syslog kernel
printf '%s\n' "${rows[@]}"
