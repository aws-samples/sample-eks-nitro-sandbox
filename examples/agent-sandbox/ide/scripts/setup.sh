#!/usr/bin/env bash
# Bring up VS Code in the browser (code-server) in a Nitro sandbox, on a
# persistent EBS workspace.
#
#   ./scripts/new-password.sh && ./scripts/setup.sh
#
# Creates, in this order: the sample's namespace (only when absent, and labelled
# as the sample's), the Secret holding the editor's argon2 password hash, the
# egress network policy, and the Sandbox. Then it waits for the Sandbox to be
# Ready, which its readinessProbe ties to code-server answering on /healthz, so
# "Ready" means "serving".
#
# It changes nothing cluster-wide: network policy enforcement is a reader step,
# checked here and never patched, and a StorageClass is chosen, never changed.
# Idempotent: every object is created only when it is absent, or applied by the
# sample into the sample's own namespace.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

require_commands kubectl sed
show_context

# Check every prerequisite BEFORE creating anything, so a missing one stops the
# run clean with no leftovers.

# The runtime class must be present. On EKS Auto Mode it always is; on standard
# EKS the nodes need a sandbox-enabled AMI (see Hello sandbox).
kc_cluster get runtimeclass isolated-sandbox >/dev/null 2>&1 \
  || die "runtimeclass isolated-sandbox not found; run the Hello sandbox sample first"

# The agent-sandbox controller must be installed (Getting started > Warm pool).
kc_cluster get crd sandboxes.agents.x-k8s.io >/dev/null 2>&1 \
  || die "the agent-sandbox Sandbox CRD is not installed; run the Warm pool sample's install step first"

# ApplicationNetworkPolicy is the EKS Auto Mode policy kind the egress rules use.
kc_cluster get crd applicationnetworkpolicies.networking.k8s.aws >/dev/null 2>&1 \
  || die "the ApplicationNetworkPolicy CRD is not present; this sample's egress policy needs EKS Auto Mode networking"

# Enforcement is a cluster-wide setting: checked, never changed.
require_network_policy_enforcement

# The password hash must already exist on this machine.
require_hash_file

# The CoreDNS address the egress policy allows, read from the cluster.
coredns_ip="$(kc_cluster -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null)" \
  || die "could not read the CoreDNS Service address (kubectl get svc -n kube-system kube-dns)"
[[ -n "$coredns_ip" ]] || die "the CoreDNS Service has no cluster IP; cannot render the egress policy"
echo "CoreDNS at $coredns_ip (the egress policy allows DNS to it)"

# Choose the StorageClass the workspace claim will name, before anything is
# created. The sample's own class is the one thing this may create here, and the
# clean up removes it.
choose_storage_class

step "1/5 namespace $NAMESPACE"
# Create the namespace only when it is absent, and label it so the clean up can
# tell it is the sample's. Applying over an existing namespace counts as reusing
# it, which would put our label on a namespace another demo owns, so check first.
# A read that fails is never read as "absent".
ns_rc=0
namespace_is_ours || ns_rc=$?
case $ns_rc in
  0) echo "namespace $NAMESPACE already exists and is the sample's; reusing it" ;;
  1) die "namespace $NAMESPACE exists but is not labelled $NS_LABEL_KEY=$NS_LABEL_VAL; it belongs to something else. Set NAMESPACE to a free name in .env and re-run." ;;
  2) die "could not read the labels on namespace $NAMESPACE; stopping rather than guess" ;;
  3) kc_cluster create namespace "$NAMESPACE"
     kc_cluster label namespace "$NAMESPACE" "$NS_LABEL_KEY=$NS_LABEL_VAL"
     echo "created namespace $NAMESPACE, labelled $NS_LABEL_KEY=$NS_LABEL_VAL" ;;
esac

step "2/5 secret/$SECRET from $(rel "$HASH_FILE")"
# The hash is read from the FILE, so neither the password nor its hash is ever on
# a command line. Created only when absent: the namespace is the sample's, so an
# existing Secret here is this sample's, and reusing it keeps the password that
# matches it. Delete the Secret (or run the clean up) to change the password.
sec_rc=0; resource_exists kc "secret/$SECRET" || sec_rc=$?
case $sec_rc in
  0) echo "  secret/$SECRET already exists; keeping it (delete it to set a new password)" ;;
  1) kc create secret generic "$SECRET" --from-file="hashed-password=$HASH_FILE" \
       || die "could not create secret/$SECRET"
     echo "  created secret/$SECRET from the hash file; the plaintext stayed on this machine" ;;
  2) die "could not read secret/$SECRET; stopping rather than guess" ;;
esac

step "3/5 egress policy $POLICY (all ingress denied)"
sed -e "s/__NAMESPACE__/$NAMESPACE/g" -e "s|<COREDNS_IP>|$coredns_ip|g" \
  "$SAMPLE_DIR/deploy/egress-policy.yaml" | kc apply -f -
# The PolicyEndpoint shows the controller picked the policy up and handed it to
# the nodes. Start the editor only after it appears, so the first thing it can do
# is already under the policy.
echo "  waiting for the PolicyEndpoint named after $POLICY"
for _ in $(seq 1 60); do
  if kc get policyendpoints -o name 2>/dev/null | grep -q "^policyendpoint.networking.k8s.aws/${POLICY}-"; then
    break
  fi
  sleep 2
done
kc get policyendpoints -o name 2>/dev/null | grep -q "^policyendpoint.networking.k8s.aws/${POLICY}-" \
  || die "no PolicyEndpoint for $POLICY after 2 minutes; the network policy controller has not picked the policy up, so the editor would run unrestricted"
kc get applicationnetworkpolicies,policyendpoints

step "4/5 apply sandbox/$SANDBOX"
# volumeClaimTemplates is immutable on the Sandbox CRD, so a Sandbox created from
# an older copy of this manifest cannot be patched into this one. Detect the
# mismatch and say what it costs, rather than letting the apply fail with a CEL
# message that does not mention the workspace.
want_access=ReadWriteOncePod
live_access="$(kc get sandbox "$SANDBOX" \
  -o jsonpath='{.spec.volumeClaimTemplates[0].spec.accessModes[0]}' 2>/dev/null || true)"
if [[ -n "$live_access" && "$live_access" != "$want_access" ]]; then
  die "sandbox/$SANDBOX already exists with accessModes: [$live_access], and this manifest asks for $want_access.
       volumeClaimTemplates is immutable on the Sandbox CRD, so the Sandbox has to be recreated:
         ./scripts/cleanup.sh && ./scripts/setup.sh
       That DELETES the workspace and its EBS volume."
fi
sed -e "s/__NAMESPACE__/$NAMESPACE/g" \
    -e "s/__STORAGE_CLASS__/$CHOSEN_STORAGE_CLASS/g" \
    -e "s|__IMAGE__|$IMAGE|g" \
  "$SAMPLE_DIR/deploy/sandbox.yaml" | kc apply -f -

step "5/5 wait for the guest to boot, mount the workspace and serve the IDE"
# Ready on a Sandbox means its pod is Ready, and the pod's readinessProbe is
# code-server's own /healthz, so this waits for a serving editor and not just a
# started container. The first sandboxed pod on a cold cluster waits for Auto Mode
# to launch a node, so the first run can take minutes.
kc wait --for=condition=Ready "sandbox/$SANDBOX" --timeout=15m \
  || die "sandbox/$SANDBOX never became Ready; check 'kubectl -n $NAMESPACE describe sandbox $SANDBOX', 'kubectl -n $NAMESPACE describe pod $SANDBOX' (a stuck EBS attach shows up as FailedAttachVolume) and 'kubectl -n $NAMESPACE logs $SANDBOX'"
kc get pvc "$PVC"
kc get service "$SANDBOX" -o wide

echo
echo "sandbox/$SANDBOX is Ready: code-server is serving on :$IDE_PORT inside the guest,"
echo "with its workspace on EBS at $WORKSPACE."
echo "Open it:          ./scripts/port-forward.sh     # then http://localhost:$IDE_PORT"
echo "Your password:    cat $(rel "$PASSWORD_FILE")"
echo "Shell in:         kubectl -n $NAMESPACE exec -it $SANDBOX -- bash"
echo "Tear it down:     ./scripts/cleanup.sh          (deletes the PVC and its EBS volume)"
