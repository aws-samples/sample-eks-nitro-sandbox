#!/usr/bin/env bash
# Stand up the sample: its namespace, its SandboxTemplate at rev-1, its
# SandboxWarmPool, and the ordinary pod the sandbox readings are compared with.
#
#   ./scripts/setup.sh
#
# It checks the shared installs it needs and creates nothing when one is missing,
# so a missing prerequisite stops the run clean with no leftovers. It never
# installs, upgrades or reconfigures any of them: the runtime class and the
# agent-sandbox controller belong to the cluster, and another workload may depend
# on the version that is there.
#
# Argo Rollouts is NOT checked here. The page shows the drain as a plain script
# first, which needs no controller; ./scripts/run-rollout.sh is what requires
# Argo Rollouts and the registered step plugin.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

# grep and sort are used by the pool readings in common.sh, which step 4/4 calls,
# not by this file directly. They belong here all the same: without grep the
# hash filter produces an empty string, which would be read as "no distinct
# hashes" and leave wait_pool_warm waiting on a pool that was already warm.
require_commands kubectl sed grep sort
show_context

# --- the shared installs, checked before anything is created ----------------
require_agent_sandbox

# --- the sample's own objects ------------------------------------------------

step "1/4 namespace $NAMESPACE"
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

step "2/4 apply the SandboxTemplate at rev-1 and the SandboxWarmPool"
# Render the manifest with this run's namespace, so an overridden NAMESPACE
# reaches every object. Never apply the file with its placeholder in place.
sed -e "s/__NAMESPACE__/$NAMESPACE/g" "$SAMPLE_DIR/deploy/warm-pool.yaml" | kc apply -f -

step "3/4 apply the ordinary pod the sandbox readings are compared with"
sed -e "s/__NAMESPACE__/$NAMESPACE/g" "$SAMPLE_DIR/deploy/ordinary-pod.yaml" | kc apply -f -

step "4/4 wait for the pool to be warm at one template revision"
# The first sandboxed pod on a cold cluster waits for EKS Auto Mode to launch a
# sandbox-capable node, so the first run can take minutes.
wait_pool_warm 900 \
  || die "the pool never became warm at a single template hash. Check 'kubectl -n $NAMESPACE describe sandboxwarmpool $POOL' and 'kubectl -n $NAMESPACE get pods'"

kc get sandboxwarmpool "$POOL"
echo
rev="$(template_revision)" || rev="?"
echo "the SandboxTemplate says $REVISION_ENV=$rev"
echo "the pool's sandboxes carry $LABEL_TEMPLATE_HASH:"
pool_template_hashes | sed 's/^/  /'
echo
echo "Open the stale-adoption window:  ./scripts/patch-template.sh rev-2"
echo "Claim a pod and read its marker: ./scripts/claim.sh stale"
echo "Close the window:                ./scripts/drain-pool.sh"
echo "Drive the same drain from a Rollout: ./scripts/run-rollout.sh rev-3"
echo "Tear it down:                    ./scripts/cleanup.sh"
