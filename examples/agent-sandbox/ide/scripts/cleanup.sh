#!/usr/bin/env bash
# Delete everything the sample created: the ordinary comparison pod, the Sandbox,
# its PVC and the EBS volume behind it, the password Secret, the egress policy,
# the sample's namespace, and the sample's own StorageClass when it made one.
#
#   ./scripts/cleanup.sh
#
# This DELETES DATA. The PVC carries the Sandbox as its ownerReference, so
# deleting the Sandbox garbage-collects workspace-ide and the 10Gi EBS volume with
# everything in the workspace.
#
# The script checks the namespace label before deleting anything inside it: the
# namespace was created and labelled by setup.sh, so everything in it is the
# sample's, and the namespace check covers its contents. It uses failure-aware
# lookups, so a read that fails is never mistaken for "gone", and it exits
# non-zero when it skipped something or could not confirm a delete, so an
# incomplete clean up is never reported as done. Safe to run at any time,
# including when nothing was set up.
#
# It never removes a shared install: the agent-sandbox controller stays, and so
# does the cluster-wide network policy enforcement setting and the cluster's
# default StorageClass. It removes only the sample's own class (ide-gp3), and only
# when that class carries the sample's mark.
#
# The password and its hash stay in the repository's tmp/ (git ignores it); delete
# them yourself when you are done.
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
# that fails is a failure, never "gone". When it is absent we skip the
# namespace-scoped steps but STILL check the StorageClass: setup creates the
# sample's class before the namespace, so a run that failed early can leave the
# class with no namespace, and exiting here would strand it.
ns_absent=0
namespace_is_ours
ns_rc=$?
case $ns_rc in
  0) : ;;  # ours: go on and clean up
  1) die "namespace $NAMESPACE exists but is not the sample's ($NS_LABEL_KEY=$NS_LABEL_VAL); refusing to touch it" ;;
  2) die "could not read namespace $NAMESPACE; refusing to delete anything (a failed read is not 'gone')" ;;
  3) ns_absent=1; echo "namespace $NAMESPACE does not exist; skipping the namespace-scoped steps, still checking the sample's StorageClass." ;;
esac

if [[ $ns_absent -eq 0 ]]; then
  # Record the bound PV BEFORE deleting the Sandbox. Garbage collection removes
  # the PVC as soon as its owner goes, so a volumeName read after the delete comes
  # back empty, which would skip the check that the EBS volume is really gone. A
  # failed read here is recorded as a failure, not read as "no volume".
  pv=""
  pvc_rc=0; resource_exists kc "pvc/$PVC" || pvc_rc=$?
  case $pvc_rc in
    0) pv_read_rc=0
       pv="$(kc get pvc "$PVC" -o jsonpath='{.spec.volumeName}' 2>/dev/null)" || pv_read_rc=$?
       if [[ $pv_read_rc -ne 0 ]]; then
         pv=""
         note_fail "could not read the bound PV of pvc/$PVC; cannot confirm the EBS volume is deleted (a failed read is not 'gone')"
       elif [[ -z "$pv" ]]; then
         note_fail "pvc/$PVC has no bound PV; cannot confirm the EBS volume is deleted"
       fi ;;
    1) : ;;  # no PVC: nothing to record
    2) note_fail "could not read pvc/$PVC; cannot determine its EBS volume (a failed read is not 'gone')" ;;
  esac

  step "1/6 delete the ordinary comparison pod, if Step 6 left one"
  # Deleted by its exact name, never with a label selector: a selector meant for
  # one helper pod can match another demo's pod.
  op_rc=0; resource_exists kc "pod/$ORDINARY_POD" || op_rc=$?
  case $op_rc in
    0) kc delete pod "$ORDINARY_POD" --ignore-not-found --wait=true --timeout=120s || note_fail "pod/$ORDINARY_POD did not delete cleanly" ;;
    1) echo "  pod/$ORDINARY_POD not present" ;;
    2) note_fail "could not read pod/$ORDINARY_POD; not reporting it gone" ;;
  esac

  step "2/6 delete sandbox/$SANDBOX (and, by ownerReference, pvc/$PVC + its EBS volume, and its Service)"
  sb_rc=0; resource_exists kc "sandbox/$SANDBOX" || sb_rc=$?
  case $sb_rc in
    0) kc delete sandbox "$SANDBOX" --ignore-not-found --wait=true --timeout=180s || note_fail "sandbox/$SANDBOX did not delete cleanly" ;;
    1) echo "  sandbox/$SANDBOX not present" ;;
    2) note_fail "could not read sandbox/$SANDBOX; not reporting it gone" ;;
  esac

  step "3/6 confirm the workspace PVC and its EBS volume are gone"
  # Belt and braces: if the Sandbox was already gone while the PVC remained, there
  # is no owner to garbage-collect the claim, so it would sit there holding an EBS
  # volume.
  #
  # Every delete in this script passes --ignore-not-found, so an object that
  # disappeared between the read above and the delete is not a failure. That
  # happens here routinely: deleting the Sandbox in step 2 garbage-collects this
  # claim, and a run where the collection landed in between used to report the
  # clean up INCOMPLETE and skip the namespace. A delete that fails for any other
  # reason still fails.
  pvc_rc=0; resource_exists kc "pvc/$PVC" || pvc_rc=$?
  case $pvc_rc in
    0) kc delete pvc "$PVC" --ignore-not-found --wait=true --timeout=120s || note_fail "pvc/$PVC did not delete cleanly" ;;
    1) echo "  pvc/$PVC not present" ;;
    2) note_fail "could not read pvc/$PVC; not reporting it gone" ;;
  esac
  if [[ -n "$pv" ]]; then
    # The PV is cluster-scoped. Deleting it reclaims the EBS volume, because
    # setup only ever uses a class with reclaimPolicy Delete (choose_storage_class
    # refuses any other, which is what makes this step's message true rather than
    # merely likely). Wait until the PV is gone, so a still-billing volume is
    # never reported as cleaned up; with a Retain class the PV would stay
    # Released, the wait would time out and this would be recorded as a failure.
    pv_rc=0; resource_exists kc_cluster "pv/$pv" || pv_rc=$?
    case $pv_rc in
      0) if kc_cluster wait --for=delete "pv/$pv" --timeout=180s; then
           echo "  pv $pv: gone"
         else
           note_fail "pv/$pv (the EBS volume) is still present; it may still be billing. Check it with: $(kubectl_cmd) get pv $pv"
         fi ;;
      1) echo "  pv $pv: gone" ;;
      2) note_fail "could not read pv/$pv; cannot confirm the EBS volume is deleted (a failed read is not 'gone')" ;;
    esac
  fi

  step "4/6 delete secret/$SECRET and the egress policy $POLICY"
  sec_rc=0; resource_exists kc "secret/$SECRET" || sec_rc=$?
  case $sec_rc in
    0) kc delete secret "$SECRET" --ignore-not-found --wait=true --timeout=60s || note_fail "secret/$SECRET did not delete cleanly" ;;
    1) echo "  secret/$SECRET not present" ;;
    2) note_fail "could not read secret/$SECRET; not reporting it gone" ;;
  esac
  pol_rc=0; resource_exists kc "applicationnetworkpolicy/$POLICY" || pol_rc=$?
  case $pol_rc in
    0) kc delete applicationnetworkpolicy "$POLICY" --ignore-not-found --wait=true --timeout=60s || note_fail "applicationnetworkpolicy/$POLICY did not delete cleanly" ;;
    1) echo "  applicationnetworkpolicy/$POLICY not present" ;;
    2) note_fail "could not read applicationnetworkpolicy/$POLICY; not reporting it gone" ;;
  esac
fi

step "5/6 delete namespace $NAMESPACE"
# Delete the namespace only when everything above succeeded. If a delete failed or
# a read could not be confirmed, something may still be in the namespace, so
# deleting it would hide an incomplete clean up.
if [[ $ns_absent -eq 1 ]]; then
  echo "  namespace $NAMESPACE not present"
elif [[ $failures -ne 0 ]]; then
  echo "  SKIPPED: not deleting namespace $NAMESPACE while $failures item(s) above are unconfirmed; resolve them first." >&2
elif kc_cluster delete namespace "$NAMESPACE" --ignore-not-found --wait=true --timeout=180s; then
  echo "  namespace $NAMESPACE deleted"
else
  note_fail "namespace $NAMESPACE did not delete cleanly"
fi

step "6/6 delete the sample's own StorageClass, if the sample made it"
# Delete ide-gp3 only when it exists AND carries the sample's mark. Never touch the
# cluster default (setup used it without creating anything), and never touch a
# class with this name that something else owns.
#
# Skipped while anything above is unconfirmed, for the same reason the namespace
# is: a claim of the sample's may still be bound to this class, and deleting a
# class a pending claim names would leave that claim stuck.
if [[ $failures -ne 0 ]]; then
  skip_sc=1
  echo "  SKIPPED: not deleting storageclass/$SAMPLE_STORAGE_CLASS while $failures item(s) above are unconfirmed; resolve them and re-run." >&2
else
  skip_sc=0
  sc_prov="$(sc_field "$SAMPLE_STORAGE_CLASS" '{.provisioner}')" ; sc_rc=$?
fi
if [[ $skip_sc -eq 1 ]]; then
  :
elif [[ $sc_rc -ne 0 ]]; then
  note_fail "could not read storageclass/$SAMPLE_STORAGE_CLASS; not reporting it gone"
elif [[ -z "$sc_prov" ]]; then
  echo "  storageclass/$SAMPLE_STORAGE_CLASS not present (setup used the cluster default, or it was already removed)"
else
  sc_mark="$(sc_field "$SAMPLE_STORAGE_CLASS" '{.metadata.labels.app\.kubernetes\.io/managed-by}')" ; scm_rc=$?
  if [[ $scm_rc -ne 0 ]]; then
    note_fail "could not read the labels on storageclass/$SAMPLE_STORAGE_CLASS; not deleting something I cannot verify"
  elif [[ "$sc_mark" != "$SAMPLE" ]]; then
    note_fail "storageclass/$SAMPLE_STORAGE_CLASS exists without the sample's mark; leaving it (it is not the sample's)"
  else
    if kc_cluster delete storageclass "$SAMPLE_STORAGE_CLASS" --ignore-not-found --wait=true --timeout=60s; then
      echo "  storageclass/$SAMPLE_STORAGE_CLASS deleted"
    else
      note_fail "storageclass/$SAMPLE_STORAGE_CLASS did not delete cleanly"
    fi
  fi
fi

echo
if [[ $failures -ne 0 ]]; then
  echo "clean up INCOMPLETE: $failures item(s) could not be removed or confirmed (see above)." >&2
  echo "Check with: $(kubectl_cmd) get sandbox,pod,pvc,secret,applicationnetworkpolicy -n $NAMESPACE  and  $(kubectl_cmd) get ns $NAMESPACE" >&2
  exit 1
fi
if [[ $ns_absent -eq 1 ]]; then
  echo "clean up complete: the namespace was already gone; the sample's own StorageClass is removed if it made one, and the cluster default is untouched."
else
  echo "clean up complete: the Sandbox, its PVC, the EBS volume, the Secret, the egress policy and the namespace are gone; the sample's own StorageClass is removed if it made one, and the cluster default is untouched."
fi
echo "The password and its hash are still in $(rel "$LOCAL_DIR"); delete them yourself when you are done."
