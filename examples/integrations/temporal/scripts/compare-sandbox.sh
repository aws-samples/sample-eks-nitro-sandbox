#!/usr/bin/env bash
# Read the same four signals from an ordinary pod on the same node, so the
# workflow's readings from inside the sandbox have something to be compared
# against.
#
#   ./scripts/compare-sandbox.sh --node <node the run reported>
#
# The sandbox the workflow drives exists only while a run is in flight, and the
# run reads its signals itself and returns them in its result. This script
# supplies the other column: one ordinary pod, same image, same command, same
# node, with the single line `runtimeClassName: isolated-sandbox` left out.
#
# It creates one pod, reads it and deletes it by its exact name. Never by a
# label selector: a selector meant for one helper pod has deleted another demo's
# pod on a shared cluster before.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

ORDINARY_POD=ordinary-pod
NODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) NODE="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1 (usage: $0 --node <node name>)" ;;
  esac
done
[[ -n "$NODE" ]] || die "pass --node <node>, the node the run reported its sandbox ran on"
[[ "$NODE" =~ ^[a-zA-Z0-9]([-a-zA-Z0-9._]{0,251}[a-zA-Z0-9])?$ ]] \
  || die "--node must be a Kubernetes node name; got '$NODE'"

require_commands kubectl sed
show_context
require_our_namespace

node_rc=0; resource_exists kc_cluster "node/$NODE" || node_rc=$?
case $node_rc in
  0) : ;;
  1) die "node/$NODE is not on this cluster. Pass the node the run reported, from its result's timeline." ;;
  2) die "could not read node/$NODE, so whether it is on this cluster could not be determined; stopping rather than pin a pod to a node I cannot verify" ;;
esac

step "create pod/$ORDINARY_POD on node $NODE"
# kc create, not apply: a pod left behind by an interrupted earlier run must
# fail this rather than be silently adopted and read as if it were fresh.
sed -e "s/__NAMESPACE__/$NAMESPACE/g" -e "s/__NODE_NAME__/$NODE/g" \
  "$SAMPLE_DIR/deploy/ordinary-pod.yaml" | kc create -f - \
  || die "could not create pod/$ORDINARY_POD. If one is left over from an earlier run, delete it by name first: kubectl -n $NAMESPACE delete pod $ORDINARY_POD"
# Delete it by its exact name whatever happens next, including a failed wait.
trap 'kc delete pod "$ORDINARY_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

kc wait --for=condition=Ready "pod/$ORDINARY_POD" --timeout=3m \
  || die "pod/$ORDINARY_POD did not become Ready; check 'kubectl -n $NAMESPACE describe pod $ORDINARY_POD'"

step "the same four readings, from an ordinary pod on node $NODE"
kc exec "$ORDINARY_POD" -- sh -c \
  'echo "read at $(date -u +%Y-%m-%dT%H:%M:%SZ)"; uname -rv; cat /proc/uptime; ls /sys/block; cat /sys/class/dmi/id/product_name' \
  || die "could not read the signals from pod/$ORDINARY_POD"
kc get pod "$ORDINARY_POD" \
  -o custom-columns='NAME:.metadata.name,RUNTIMECLASS:.spec.runtimeClassName,NODE:.spec.nodeName,START:.status.startTime'

step "delete pod/$ORDINARY_POD by name"
kc delete pod "$ORDINARY_POD" --timeout=2m || die "could not delete pod/$ORDINARY_POD"
trap - EXIT
echo
echo "pod/$ORDINARY_POD is gone. Compare these readings with the signals the run returned."
