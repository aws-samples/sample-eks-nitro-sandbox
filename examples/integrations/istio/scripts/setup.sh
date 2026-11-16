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
rtc="$(kc_read get runtimeclass isolated-sandbox --ignore-not-found -o name)" \
  || die "could not read RuntimeClass isolated-sandbox, so it is not known whether Nitro sandboxes are set up"
[[ -n "$rtc" ]] \
  || die "RuntimeClass isolated-sandbox not found. Finish Getting started first (see the home page prerequisites)."
[[ "$rtc" == "runtimeclass.node.k8s.io/isolated-sandbox" ]] \
  || die "unexpected answer for RuntimeClass isolated-sandbox: $rtc"

# Istio itself: istiod must be running. The Istio CNI node agent and ambient mesh
# would change how pods are injected for every workload on the cluster, and neither
# works on Nitro sandboxes, so a cluster that has them is stopped on, not changed.
istiod="$(kc_read -n "$ISTIO_NAMESPACE" get deployment istiod --ignore-not-found \
  -o 'jsonpath={.metadata.name}{"|"}{.status.readyReplicas}')" \
  || die "could not read istiod in $ISTIO_NAMESPACE, so it is not known whether Istio is installed"
if [[ -z "$istiod" ]]; then
  die "Istio is not installed (no istiod in $ISTIO_NAMESPACE). Install it as the page's step 1 says:
  helm repo add istio https://istio-release.storage.googleapis.com/charts && helm repo update istio
  helm install istio-base istio/base -n $ISTIO_NAMESPACE --create-namespace --version 1.30.8 --wait
  helm install istiod istio/istiod -n $ISTIO_NAMESPACE --version 1.30.8 --wait"
fi
[[ "$istiod" == "istiod|"* ]] || die "unexpected answer for deployment istiod: $istiod"
ready="${istiod#istiod|}"
[[ "$ready" =~ ^[1-9][0-9]*$ ]] \
  || die "istiod is installed in $ISTIO_NAMESPACE but has no ready replicas (readyReplicas='$ready'). Fix the existing install; this blueprint does not change it."

# The Istio CNI node agent and ztunnel, in any namespace, found by the labels their
# Helm charts set (cni: k8s-app=istio-cni-node, ztunnel: app.kubernetes.io/name=ztunnel).
found=""
for sel in k8s-app=istio-cni-node app.kubernetes.io/name=ztunnel; do
  ds="$(kc_read get daemonset -A -l "$sel" \
    -o 'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name} {end}')" \
    || die "could not list DaemonSets with label $sel, so it is not known whether Istio CNI or ztunnel is installed"
  found+="$ds"
done
[[ -z "$found" ]] \
  || die "found DaemonSet ${found}on this cluster. The Istio CNI plugin and ambient mesh do not work on Nitro sandboxes, and this blueprint uses the istio-init sidecar. Run it on a cluster whose Istio has neither; it will not change this one."
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
