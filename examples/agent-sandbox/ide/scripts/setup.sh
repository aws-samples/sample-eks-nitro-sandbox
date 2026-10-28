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

# base64 is used to compare the Secret's value with the local hash file without
# putting either on a command line.
require_commands kubectl sed base64
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
  || die "could not read the CoreDNS Service address ($(kubectl_cmd) get svc -n kube-system kube-dns)"
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
  3) kc_cluster create namespace "$NAMESPACE" \
       || die "could not create namespace $NAMESPACE.$(
            [[ $CREATED_SAMPLE_STORAGE_CLASS -eq 1 ]] \
              && printf ' The step before this one created storageclass/%s, which is cluster-scoped; ./scripts/cleanup.sh removes it.' "$SAMPLE_STORAGE_CLASS"
            true
          )"
     # The label is the mark everything else depends on: without it, this script
     # and the clean up both refuse the namespace, so say exactly that rather
     # than exiting on set -e with no explanation.
     kc_cluster label namespace "$NAMESPACE" "$NS_LABEL_KEY=$NS_LABEL_VAL" \
       || die "created namespace $NAMESPACE but could not label it $NS_LABEL_KEY=$NS_LABEL_VAL. Nothing was created in it.$(
            [[ $CREATED_SAMPLE_STORAGE_CLASS -eq 1 ]] \
              && printf ' The step before this one created storageclass/%s, which is cluster-scoped and is still there.' "$SAMPLE_STORAGE_CLASS"
            true
          ) Label the namespace yourself with
         $(kubectl_cmd) label namespace $NAMESPACE $NS_LABEL_KEY=$NS_LABEL_VAL
       and re-run; without the label this script and the clean up both refuse it. To undo
       instead, label it as above and then run ./scripts/cleanup.sh, which removes the
       namespace and the sample's own StorageClass."
     echo "created namespace $NAMESPACE, labelled $NS_LABEL_KEY=$NS_LABEL_VAL" ;;
esac

step "2/5 secret/$SECRET from $(rel "$HASH_FILE")"
# The hash is read from the FILE, so neither the password nor its hash is ever on
# a command line. Created only when absent: the namespace is the sample's, so an
# existing Secret here is this sample's, and applying over it is not needed.
#
# An existing Secret is kept, but only after checking it holds the hash this
# machine has. Otherwise a reader who ran ./scripts/new-password.sh again would
# be told to type a password the running editor does not accept, and nothing
# would say why.
sec_rc=0; resource_exists kc "secret/$SECRET" || sec_rc=$?
case $sec_rc in
  0) live_hash_rc=0
     live_hash="$(kc get secret "$SECRET" -o jsonpath='{.data.hashed-password}' 2>/dev/null)" || live_hash_rc=$?
     [[ $live_hash_rc -ne 0 ]] && die "could not read secret/$SECRET; stopping rather than guess"
     # Compare base64 to base64, so the hash itself is never built into an
     # argument or printed.
     # -w0 on GNU coreutils, the pipe through tr for the BSD base64 that has no
     # -w. If BOTH fail the substitution fails, which under set -e would end the
     # run with no message at all, in the middle of a credential check, so say so.
     want_hash="$(base64 -w0 < "$HASH_FILE" 2>/dev/null || base64 < "$HASH_FILE" | tr -d '\n')" \
       || die "could not base64-encode $(rel "$HASH_FILE") to compare it with the Secret; stopping rather than guess whether they match"
     if [[ "$live_hash" != "$want_hash" ]]; then
       die "secret/$SECRET already exists and holds a different hash from $(rel "$HASH_FILE").
       The editor would keep accepting the older password, not the one in $(rel "$PASSWORD_FILE").
       Delete the Secret to set the new password, keeping the workspace:
         $(kubectl_cmd) -n $NAMESPACE delete secret $SECRET && ./scripts/setup.sh
       The pod picks the new value up when it restarts:
         $(kubectl_cmd) -n $NAMESPACE delete pod $SANDBOX"
     fi
     echo "  secret/$SECRET already exists and holds the hash in $(rel "$HASH_FILE"); keeping it" ;;
  1) kc create secret generic "$SECRET" --from-file="hashed-password=$HASH_FILE" \
       || die "could not create secret/$SECRET"
     echo "  created secret/$SECRET from the hash file; the plaintext stayed on this machine" ;;
  2) die "could not read secret/$SECRET; stopping rather than guess" ;;
esac

step "3/5 egress policy $POLICY (all ingress denied)"
sed -e "s/__NAMESPACE__/$NAMESPACE/g" -e "s|<COREDNS_IP>|$coredns_ip|g" \
  "$SAMPLE_DIR/deploy/egress-policy.yaml" | kc apply -f -
# The PolicyEndpoint shows the controller picked the policy up and handed it to
# the nodes. Wait for it before creating the editor, so the policy is on the
# nodes before the pod that it governs exists.
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
# Read all three fields the claim template pins, not just the access mode: the
# class this run chose can differ from the one an existing Sandbox was created
# with (a fitting default class appeared since, or STORAGE_CLASS changed), and so
# can the size. Any of the three makes the apply fail with a CEL message that
# does not mention the workspace it is about to cost.
#
# --ignore-not-found, not `|| true`: an absent Sandbox is an empty result with
# status 0, so a read that actually failed is still a failure and stops the run
# rather than looking like "there is no Sandbox".
tmpl_rc=0
live_tmpl="$(kc get sandbox "$SANDBOX" --ignore-not-found \
  -o jsonpath='{.spec.volumeClaimTemplates[0].spec.accessModes[0]}|{.spec.volumeClaimTemplates[0].spec.storageClassName}|{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}' 2>/dev/null)" || tmpl_rc=$?
[[ $tmpl_rc -ne 0 ]] && die "could not read sandbox/$SANDBOX; stopping rather than guess whether it exists"
# An absent Sandbox prints nothing; a Sandbox with no claim template prints the
# two separators and no values. Neither is a mismatch.
if [[ -n "$live_tmpl" && "$live_tmpl" != "||" ]]; then
  live_access="${live_tmpl%%|*}"
  _rest="${live_tmpl#*|}"
  live_class="${_rest%%|*}"
  live_size="${_rest##*|}"
  mismatch=""
  # keep_hint is added only for the class, and only when the class is what
  # differs: it is the one field a reader can point back at the existing claim.
  # For the access mode or the size there is nothing to set, and saying "unset
  # STORAGE_CLASS" would be wrong advice, which is worse than none. It is also
  # wrong when STORAGE_CLASS is already unset and the cluster grew a default
  # class that fits, so the hint names the value to SET rather than to unset.
  keep_hint=""
  if [[ "$live_access" != "$want_access" ]]; then
    mismatch="$mismatch
         accessModes: [$live_access], and this manifest asks for [$want_access]"
  fi
  if [[ "$live_class" != "$CHOSEN_STORAGE_CLASS" ]]; then
    mismatch="$mismatch
         storageClassName: $live_class, and this run chose $CHOSEN_STORAGE_CLASS"
    # Only offer the hint when there is a class to name. A claim template with no
    # storageClassName cannot come from this sample's manifest, which always names
    # one, and "set STORAGE_CLASS=" would be the same as leaving it unset.
    if [[ -n "$live_class" ]]; then
      keep_hint="
       To keep the existing workspace instead, point this run back at the class the claim
       already uses: set STORAGE_CLASS=$live_class in .env, and re-run. A value already in
       the environment wins over .env, so unset it there first if you exported one."
    fi
  fi
  if [[ "$live_size" != "$WORKSPACE_SIZE" ]]; then
    mismatch="$mismatch
         storage: $live_size, and this manifest asks for $WORKSPACE_SIZE"
  fi
  if [[ -n "$mismatch" ]]; then
    die "sandbox/$SANDBOX already exists with a different workspace claim template:$mismatch
       volumeClaimTemplates is immutable on the Sandbox CRD, so the Sandbox has to be recreated:
         ./scripts/cleanup.sh && ./scripts/setup.sh
       That DELETES the workspace and its EBS volume.$keep_hint$(
         [[ $CREATED_SAMPLE_STORAGE_CLASS -eq 1 ]] \
           && printf '\n       This run also created storageclass/%s, which is cluster-scoped; ./scripts/cleanup.sh removes it.' "$SAMPLE_STORAGE_CLASS"
         true
       )"
  fi
fi
sed -e "s/__NAMESPACE__/$NAMESPACE/g" \
    -e "s/__STORAGE_CLASS__/$CHOSEN_STORAGE_CLASS/g" \
    -e "s/__STORAGE_SIZE__/$WORKSPACE_SIZE/g" \
    -e "s|__IMAGE__|$IMAGE|g" \
  "$SAMPLE_DIR/deploy/sandbox.yaml" | kc apply -f -

step "5/5 wait for the guest to boot, mount the workspace and serve the IDE"
# Ready on a Sandbox means its pod is Ready, and the pod's readinessProbe is
# code-server's own /healthz, so this waits for a serving editor and not just a
# started container. The first sandboxed pod on a cold cluster waits for Auto Mode
# to launch a node, so the first run can take minutes.
kc wait --for=condition=Ready "sandbox/$SANDBOX" --timeout=15m \
  || die "sandbox/$SANDBOX never became Ready; check '$(kubectl_cmd) -n $NAMESPACE describe sandbox $SANDBOX', '$(kubectl_cmd) -n $NAMESPACE describe pod $SANDBOX' (a stuck EBS attach shows up as FailedAttachVolume) and '$(kubectl_cmd) -n $NAMESPACE logs $SANDBOX'"
kc get pvc "$PVC"
kc get service "$SANDBOX" -o wide

echo
echo "sandbox/$SANDBOX is Ready: code-server is serving on :$IDE_PORT inside the guest,"
echo "with its workspace on EBS at $WORKSPACE."
echo "Open it:          ./scripts/port-forward.sh     # then http://localhost:$IDE_PORT"
echo "Your password:    cat $(rel "$PASSWORD_FILE")"
# Plain kubectl, not kubectl_cmd, in these two hints and nowhere else: this block
# is the output the page reproduces, and kubectl_cmd would print the context the
# run was pinned to, which on a shared cluster is a cluster name that must not
# reach a published page. The error paths above, which the page never shows, name
# the context so a reader's follow-up command hits the cluster the script used.
echo "Shell in:         kubectl -n $NAMESPACE exec -it $SANDBOX -- bash"
echo "Tear it down:     ./scripts/cleanup.sh          (deletes the PVC and its EBS volume)"
