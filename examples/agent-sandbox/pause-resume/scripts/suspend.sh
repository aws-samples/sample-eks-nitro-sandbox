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

kc get sandbox "$SANDBOX" >/dev/null 2>&1 \
  || die "sandbox/$SANDBOX not found in namespace $NAMESPACE; run ./scripts/setup.sh first"

step "suspend sandbox/$SANDBOX"
kc patch "sandbox/$SANDBOX" --type=merge -p '{"spec":{"operatingMode":"Suspended"}}'
# The Suspended condition goes True only once the pod is fully gone, not merely
# terminating.
kc wait --for=condition=Suspended "sandbox/$SANDBOX" --timeout=5m \
  || die "sandbox never reported Suspended; check 'kubectl -n $NAMESPACE describe sandbox $SANDBOX'"

echo
echo "The pod is gone (you stop paying for the guest); the EBS volume is kept:"
kc get pod "$SANDBOX" 2>&1 | sed 's/^/  /' || true
kc get pvc "$PVC" 2>&1 | sed 's/^/  /'
echo
echo "Resume it with: ./scripts/resume.sh"
