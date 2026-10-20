#!/usr/bin/env bash
# Delete everything the sample created: the Sandbox, its PVC and the EBS volume
# behind it, and the sample's namespace.
#
#   ./scripts/cleanup.sh
#
# This DELETES DATA. The PVC carries the Sandbox as its ownerReference, so
# deleting the Sandbox garbage-collects workspace-pause-resume and the 10Gi EBS
# volume. Suspending preserves a workspace; deleting never does.
#
# The script touches a resource only when it carries the sample's mark, checks
# the namespace label before deleting anything inside it, and exits non-zero when
# it skipped something or could not check, so an incomplete clean up is never
# reported as done. Safe to run at any time, including when nothing was set up.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

# Do not let one failed delete stop the ones after it; track failures and own the
# exit code at the end.
set +e

require_commands kubectl
show_context

failures=0
note_fail() { echo "  INCOMPLETE: $*" >&2; failures=$((failures + 1)); }

# The namespace must be the sample's before we delete anything inside it. A read
# that fails is a failure, never "gone".
namespace_is_ours
ns_rc=$?
case $ns_rc in
  0) : ;;  # ours: go on and clean up
  1) die "namespace $NAMESPACE exists but is not the sample's ($NS_LABEL_KEY=$NS_LABEL_VAL); refusing to touch it" ;;
  2) die "could not read namespace $NAMESPACE; refusing to delete anything (a failed read is not 'gone')" ;;
  3) echo "namespace $NAMESPACE does not exist; nothing to clean up."; exit 0 ;;
esac

# Record the bound PV BEFORE deleting the Sandbox. GC removes the PVC as soon as
# its owner goes, so a volumeName read after the delete comes back empty, which
# would skip the check that the EBS volume is really gone. A failed read here is
# recorded as a cleanup failure, not read as "no volume".
pv=""
pvc_rc=0; resource_exists kc "pvc/$PVC" || pvc_rc=$?
case $pvc_rc in
  0) pv="$(kc get pvc "$PVC" -o jsonpath='{.spec.volumeName}' 2>/dev/null)"
     [[ -z "$pv" ]] && note_fail "could not read the bound PV of pvc/$PVC; cannot confirm the EBS volume is deleted" ;;
  1) : ;;  # no PVC: nothing to record
  2) note_fail "could not read pvc/$PVC; cannot determine its EBS volume (a failed read is not 'gone')" ;;
esac

step "1/3 delete sandbox/$SANDBOX (and, by ownerReference, pvc/$PVC + its EBS volume)"
# Delete the Sandbox only when it carries the sample's mark. The namespace is
# already confirmed ours; this is the per-resource check, so a same-named object
# another tool put in the namespace is never deleted (and, below, the namespace
# is not deleted either while such a resource is present).
sb_rc=0; resource_is_ours kc "sandbox/$SANDBOX" || sb_rc=$?
case $sb_rc in
  0) kc delete sandbox "$SANDBOX" --wait=true --timeout=120s || note_fail "sandbox/$SANDBOX did not delete cleanly" ;;
  1) note_fail "sandbox/$SANDBOX does not carry ManagedBy=$SAMPLE; not deleting it (it is not the sample's)" ;;
  2) note_fail "could not read sandbox/$SANDBOX; not deleting something I cannot verify" ;;
  3) echo "  sandbox/$SANDBOX not present" ;;
esac

step "2/3 confirm the workspace PVC and its EBS volume are gone"
# Belt and braces: if the Sandbox was already gone while the PVC remained (for
# example deleted by hand mid-suspend), there is no owner to GC the claim, so it
# would sit there holding an EBS volume. Delete it only when it carries the mark.
pvc_rc=0; resource_is_ours kc "pvc/$PVC" || pvc_rc=$?
case $pvc_rc in
  0) kc delete pvc "$PVC" --wait=true --timeout=120s || note_fail "pvc/$PVC did not delete cleanly" ;;
  1) note_fail "pvc/$PVC does not carry ManagedBy=$SAMPLE; not deleting it (it is not the sample's)" ;;
  2) note_fail "could not read pvc/$PVC; not deleting something I cannot verify" ;;
  3) echo "  pvc/$PVC not present" ;;
esac
if [[ -n "$pv" ]]; then
  # The PV is cluster-scoped. Delete reclaims the EBS volume (auto-ebs-sc is
  # Delete reclaim policy). Wait for it to be gone so a still-billing volume is
  # never reported as cleaned up. A read that fails is a failure, never "gone".
  pv_rc=0; resource_exists kc_cluster "pv/$pv" || pv_rc=$?
  case $pv_rc in
    0) if kc_cluster wait --for=delete "pv/$pv" --timeout=120s; then
         echo "  pv $pv: gone"
       else
         note_fail "pv/$pv (the EBS volume) is still present; it may still be billing"
       fi ;;
    1) echo "  pv $pv: gone" ;;
    2) note_fail "could not read pv/$pv; cannot confirm the EBS volume is deleted (a failed read is not 'gone')" ;;
  esac
fi

step "3/3 delete namespace $NAMESPACE"
# Delete the namespace only when everything above succeeded. If an ownership or
# read check failed, something in the namespace is unverified or not the
# sample's, and deleting the namespace would destroy it through the back door,
# which is exactly what the per-resource checks above exist to prevent. Leave the
# namespace for the reader to resolve instead.
if [[ $failures -ne 0 ]]; then
  echo "  SKIPPED: not deleting namespace $NAMESPACE while $failures item(s) above are unverified or not the sample's; deleting it would remove them too." >&2
elif kc_cluster delete namespace "$NAMESPACE" --wait=true --timeout=120s; then
  echo "  namespace $NAMESPACE deleted"
else
  note_fail "namespace $NAMESPACE did not delete cleanly"
fi

echo
if [[ $failures -ne 0 ]]; then
  echo "clean up INCOMPLETE: $failures item(s) could not be removed or confirmed (see above)." >&2
  echo "Check with: kubectl get sandbox,pvc -n $NAMESPACE  and  kubectl get ns $NAMESPACE" >&2
  exit 1
fi
echo "clean up complete: the Sandbox, its PVC, the EBS volume and the namespace are gone."
