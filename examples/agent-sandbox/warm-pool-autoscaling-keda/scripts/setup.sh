#!/usr/bin/env bash
# Stand up the sample: its namespace, its SandboxTemplate and SandboxWarmPool,
# the claim-demand exporter, and the ScaledObject that hands the pool's
# spec.replicas to KEDA.
#
#   ./scripts/setup.sh
#
# It checks the three shared installs it needs and creates nothing when one is
# missing, so a missing prerequisite stops the run clean with no leftovers. It
# never installs, upgrades or reconfigures any of them: the runtime class, the
# agent-sandbox controller and KEDA all belong to the cluster, and another
# workload may depend on the version that is there.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

require_commands kubectl sed
show_context

# --- the shared installs, checked before anything is created ----------------

# The runtime class. On EKS Auto Mode it is always present; on standard EKS the
# nodes need a sandbox-enabled AMI (see Hello sandbox).
kc_cluster get runtimeclass isolated-sandbox >/dev/null 2>&1 \
  || die "runtimeclass isolated-sandbox not found; run the Hello sandbox sample first"

# The agent-sandbox controller and its extensions (Getting started > Warm pool
# step 1). All three extension CRDs, because this sample uses all three.
for crd in sandboxtemplates.extensions.agents.x-k8s.io \
           sandboxwarmpools.extensions.agents.x-k8s.io \
           sandboxclaims.extensions.agents.x-k8s.io; do
  kc_cluster get crd "$crd" >/dev/null 2>&1 \
    || die "the agent-sandbox CRD $crd is not installed; run the Warm pool sample's install step first"
done

# KEDA, reused as it is or the run stops with the install command.
require_keda

# --- the sample's own objects ------------------------------------------------

step "1/5 namespace $NAMESPACE"
# Create the namespace only when it is absent, and label it so the other scripts
# can tell it is the sample's. Applying over an existing namespace counts as
# reusing it, which would put our label on a namespace another demo owns, so
# check first. A read that fails is never read as "absent".
ns_rc=0
namespace_is_ours || ns_rc=$?
case $ns_rc in
  0) echo "namespace $NAMESPACE already exists and is the sample's; reusing it" ;;
  1) die "namespace $NAMESPACE exists but is not labelled $NS_LABEL_KEY=$NS_LABEL_VAL; it belongs to something else. Set NAMESPACE to a free name in .env and re-run." ;;
  2) die "could not read the labels on namespace $NAMESPACE; stopping rather than guess" ;;
  3) kc_cluster create namespace "$NAMESPACE"
     # The label is the only thing that marks the namespace as the sample's, so
     # a namespace created without it is one every script here will refuse from
     # then on, including the clean up. If the label does not take, remove the
     # namespace this command just made rather than leaving that behind.
     if ! kc_cluster label namespace "$NAMESPACE" "$NS_LABEL_KEY=$NS_LABEL_VAL"; then
       echo "could not label namespace $NAMESPACE; deleting the namespace this run just created" >&2
       kc_cluster delete namespace "$NAMESPACE" --wait=true --timeout=120s >&2 \
         || echo "could not delete namespace $NAMESPACE either; remove it by hand: kubectl delete namespace $NAMESPACE" >&2
       die "namespace $NAMESPACE could not be labelled $NS_LABEL_KEY=$NS_LABEL_VAL, so nothing was created"
     fi
     echo "created namespace $NAMESPACE, labelled $NS_LABEL_KEY=$NS_LABEL_VAL" ;;
esac

step "2/5 apply the SandboxTemplate and the SandboxWarmPool"
# Render the manifest with this run's namespace, so an overridden NAMESPACE
# reaches every object. Never apply the file with its placeholder in place.
sed -e "s/__NAMESPACE__/$NAMESPACE/g" "$SAMPLE_DIR/deploy/warm-pool.yaml" | kc apply -f -

step "3/5 apply the claim-demand exporter"
# The exporter's code lives in src/exporter.py, so the file on disk is the file
# that runs. Render it into the ConfigMap the Deployment mounts.
kc create configmap "$EXPORTER_SRC_CM" \
  --from-file="exporter.py=$SAMPLE_DIR/src/exporter.py" \
  --dry-run=client -o yaml | kc apply -f -
sed -e "s/__NAMESPACE__/$NAMESPACE/g" -e "s|__CLAIM_SELECTOR__|$CLAIM_SELECTOR|g" \
  "$SAMPLE_DIR/deploy/exporter.yaml" | kc apply -f -
kc rollout status "deploy/$EXPORTER" --timeout=3m \
  || die "the exporter never became ready; check 'kubectl -n $NAMESPACE logs deploy/$EXPORTER'"
echo "  exporter is serving: $(exporter_metric)"

step "4/5 apply the ScaledObject and wait for the HPA KEDA creates"
sed -e "s/__NAMESPACE__/$NAMESPACE/g" "$SAMPLE_DIR/deploy/scaledobject.yaml" | kc apply -f -
hpa=""
for _ in $(seq 1 36); do   # 36 * 5s = 3m
  hpa="$(hpa_for_pool)"
  [[ -n "$hpa" ]] && break
  sleep 5
done
[[ -n "$hpa" ]] || die "KEDA never created an HPA for $POOL. Check 'kubectl -n $NAMESPACE describe scaledobject $SCALEDOBJECT' and 'kubectl -n $KEDA_NAMESPACE logs deploy/keda-operator'"
echo "  hpa/$hpa targets $(kc get hpa "$hpa" -o jsonpath='{.spec.scaleTargetRef.kind}/{.spec.scaleTargetRef.name}')"

step "5/5 wait for the pool to settle warm at the floor"
# At rest, with no claims, KEDA holds spec.replicas at minReplicaCount. Wait for
# the pool to be genuinely warm there: readyReplicas meets spec.replicas and
# nothing is terminating. The first sandboxed pod on a cold cluster waits for
# Auto Mode to launch a sandbox-capable node, so the first run can take minutes.
wait_pool_warm 900 \
  || die "the pool never reached its warm floor. Check 'kubectl -n $NAMESPACE describe sandboxwarmpool $POOL' and 'kubectl -n $NAMESPACE get pods'"

kc get sandboxwarmpool "$POOL"
kc get scaledobject "$SCALEDOBJECT"
echo
echo "the pool is warm at the floor and KEDA owns its spec.replicas."
echo "Drive demand up and back down:   ./scripts/demand.sh"
echo "Run the no-autoscaler control:   ./scripts/control-no-autoscaler.sh"
echo "Tear it down:                    ./scripts/cleanup.sh"
