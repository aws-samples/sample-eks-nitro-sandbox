#!/usr/bin/env bash
# Suspend the sandbox: terminate the pod, keep the Sandbox and its EBS volume.
#
#   ./scripts/suspend.sh
#
# operatingMode: Suspended tells the controller to delete the pod. The PVC is
# owned by the Sandbox and is left alone, so the workspace survives. No sync is
# needed first: the platform flushes and releases the CSI mount before killing
# the guest.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

require_commands kubectl
show_context

# Only act when this sample owns the namespace, so a same-named Sandbox in a
# namespace that belongs to something else is never patched.
require_our_namespace

rc=0; resource_exists kc "sandbox/$SANDBOX" || rc=$?
case $rc in
  0) : ;;
  1) die "sandbox/$SANDBOX not found in namespace $NAMESPACE; run ./scripts/setup.sh first" ;;
  2) die "could not read sandbox/$SANDBOX in namespace $NAMESPACE; stopping rather than patch something I cannot verify" ;;
esac

step "suspend sandbox/$SANDBOX"
kc patch "sandbox/$SANDBOX" --type=merge -p '{"spec":{"operatingMode":"Suspended"}}'
# The Suspended condition goes True only once the pod is fully gone, not merely
# terminating.
kc wait --for=condition=Suspended "sandbox/$SANDBOX" --timeout=5m \
  || die "sandbox never reported Suspended; check 'kubectl -n $NAMESPACE describe sandbox $SANDBOX'"

echo
echo "The pod is gone (you stop paying for the guest); the EBS volume is kept:"
# A failure-aware check: the pod should be genuinely gone, not merely unreadable.
pod_rc=0; resource_exists kc "pod/$SANDBOX" || pod_rc=$?
case $pod_rc in
  0) die "pod/$SANDBOX is still present after the Suspended condition; something is wrong, check 'kubectl -n $NAMESPACE get pod $SANDBOX'" ;;
  1) echo "  pod/$SANDBOX: NotFound (deleted)" ;;
  2) die "could not read pod/$SANDBOX to confirm it is gone; not reporting a suspend I cannot verify" ;;
esac
kc get pvc "$PVC" 2>&1 | sed 's/^/  /'
echo
echo "Resume it with: ./scripts/resume.sh"
