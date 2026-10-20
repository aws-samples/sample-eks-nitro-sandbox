#!/usr/bin/env bash
# Resume the sandbox: bring up a new pod on the same EBS volume.
#
#   ./scripts/resume.sh
#
# operatingMode: Running tells the controller to schedule a new pod (a new pod
# UID) and re-mount the same workspace. The earlier boot lines are still on the
# volume, with a new one appended on this boot: disk state survived even though
# process memory did not.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

require_commands kubectl
show_context

# Only act when this sample owns the namespace.
require_our_namespace

rc=0; resource_exists kc "sandbox/$SANDBOX" || rc=$?
case $rc in
  0) : ;;
  1) die "sandbox/$SANDBOX not found in namespace $NAMESPACE; run ./scripts/setup.sh first" ;;
  2) die "could not read sandbox/$SANDBOX in namespace $NAMESPACE; stopping rather than patch something I cannot verify" ;;
esac

step "resume sandbox/$SANDBOX"
kc patch "sandbox/$SANDBOX" --type=merge -p '{"spec":{"operatingMode":"Running"}}'
kc wait --for=condition=Ready "sandbox/$SANDBOX" --timeout=10m \
  || die "sandbox never became Ready again after resume; check 'kubectl -n $NAMESPACE describe pod $SANDBOX' (a stuck EBS re-attach shows up as FailedAttachVolume)"

echo
echo "The workspace came back on a new pod, with its history intact:"
kc exec "$SANDBOX" -- cat /workspace/boots.log | sed 's/^/  /'
