#!/usr/bin/env bash
# Create the blueprint's namespace and its workloads.
#
#   ./scripts/setup.sh
#
# It installs nothing shared. Istio is read and reused as it stands; when it is
# missing, or is set up in a way this blueprint does not use, the script stops
# and says so. The install command is a step on the page.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

require_commands kubectl sed grep
show_context

step "1/3 prerequisites, reused as they are"
kc get runtimeclass isolated-sandbox >/dev/null 2>&1 \
  || die "RuntimeClass isolated-sandbox not found. Finish Getting started first (see the home page prerequisites)."

# Istio itself: istiod must be running. The Istio CNI node agent and ambient mesh
# would change how pods are injected for every workload on the cluster, and neither
# works on Nitro sandboxes, so a cluster that has them is stopped on, not changed.
istiod_ready="$(kc -n "$ISTIO_NAMESPACE" get deployment istiod -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
if [[ -z "$istiod_ready" || "$istiod_ready" == "0" ]]; then
  die "Istio is not installed (no ready istiod in $ISTIO_NAMESPACE). Install it as the page's step 1 says:
  helm repo add istio https://istio-release.storage.googleapis.com/charts && helm repo update istio
  helm install istio-base istio/base -n $ISTIO_NAMESPACE --create-namespace --version 1.30.8 --wait
  helm install istiod istio/istiod -n $ISTIO_NAMESPACE --version 1.30.8 --wait"
fi
daemonsets="$(kc -n "$ISTIO_NAMESPACE" get daemonset -o name 2>/dev/null | grep -E 'istio-cni|ztunnel' || true)"
[[ -z "$daemonsets" ]] \
  || die "found $(echo "$daemonsets" | tr '\n' ' ')in $ISTIO_NAMESPACE. The Istio CNI plugin and ambient mesh do not work on Nitro sandboxes, and this blueprint uses the istio-init sidecar. Run it on a cluster whose Istio has neither; it will not change this one."
echo "istiod ready, no Istio CNI or ztunnel DaemonSet"

step "2/3 namespace $NAMESPACE"
mark=""; rc=0
mark="$(namespace_mark)" || rc=$?
case "$rc" in
  0) [[ "$mark" == "$MARK_VALUE" ]] \
       || die "namespace $NAMESPACE exists and is not this blueprint's (no $MARK_KEY=$MARK_VALUE label). Set another NAMESPACE."
     echo "namespace exists and carries the blueprint's label; reusing it" ;;
  2) sed "s/<NAMESPACE>/$NAMESPACE/g" "$SAMPLE_DIR/deploy/namespace.yaml" | kc create -f - ;;
  *) die "could not read namespace $NAMESPACE, so it is not known whether it is this blueprint's" ;;
esac

step "3/3 workloads"
sed "s/<NAMESPACE>/$NAMESPACE/g" "$SAMPLE_DIR/deploy/workloads.yaml" | kc apply -f -
for d in echo client-a client-b; do
  kc -n "$NAMESPACE" rollout status "deployment/$d" --timeout=300s
done
kc -n "$NAMESPACE" wait --for=condition=Ready pod/client-plain --timeout=120s
echo
kc -n "$NAMESPACE" get pods
