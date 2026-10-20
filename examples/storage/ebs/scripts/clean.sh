#!/usr/bin/env bash
# Remove everything this sample created: the pods, the StatefulSet and its headless
# Service, and every PVC this sample creates (and so the EBS volume each one holds).
#
#   NAMESPACE=<ns> ./scripts/clean.sh              # delete the pods and every PVC/volume
#   NAMESPACE=<ns> ./scripts/clean.sh --keep-data  # delete the pods, keep every PVC/volume
#
# Deleting a PVC deletes the dynamically provisioned EBS volume with it (reclaimPolicy
# Delete), so the data is gone. This never deletes the StorageClass: it is cluster-wide
# and shared. To remove it, see the page's clean up.
#
# The CSI driver owns the EBS volumes, so this does not tag or delete any volume through
# the EC2 API. It records each claim's volume ID before deleting the claim, then confirms
# with aws ec2 describe-volumes that the volume is gone. A lookup that fails means "could
# not determine", never "gone", and the script exits non-zero.
#
# Overridable: NAMESPACE, KUBECTL, AWS (the aws CLI).
set -uo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NAMESPACE="${NAMESPACE:-nitro-ebs-sample}"
KUBECTL="${KUBECTL:-kubectl}"
AWS="${AWS:-aws}"

POD=ebs-sandbox
SECOND_POD=ebs-sandbox-second
PVC=ebs-sandbox-data
SET=ebs-sandbox-set
SET_SELECTOR="app=$SET"
SAMPLE_LABEL_KEY="app.kubernetes.io/part-of"
SAMPLE_LABEL_VALUE="nitro-sandbox-ebs"

keep_data=false
for arg in "$@"; do
  case "$arg" in
    --keep-data) keep_data=true ;;
    *) printf 'error: unknown argument: %s (supported: --keep-data)\n' "$arg" >&2; exit 2 ;;
  esac
done

incomplete=0
warn() { printf 'warning: %s\n' "$*" >&2; incomplete=1; }
command -v "${KUBECTL%% *}" >/dev/null 2>&1 || { printf 'error: %s not on PATH\n' "$KUBECTL" >&2; exit 2; }

# Never delete anything inside a namespace this sample did not create. Read the label we
# stamp in setup.sh; a namespace that lacks it (or an unreadable read) means we do not own
# it, so touch nothing and exit non-zero rather than deleting another demo's objects.
if ! $KUBECTL get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "Namespace '$NAMESPACE' does not exist; nothing to clean up."
  exit 0
fi
# Read the whole labels map rather than a single dotted-key jsonpath, which is fiddly to
# escape; match the key/value pair in it below.
ns_label_err="$(mktemp)"
ns_labels="$($KUBECTL get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels}' 2>"$ns_label_err")"
ns_read_rc=$?
ns_msg="$(sed 's/^/  /' "$ns_label_err")"; rm -f "$ns_label_err"
if [[ $ns_read_rc -ne 0 ]]; then
  printf 'error: could not read the labels of namespace %s (the read failed, not a report
that it is unlabelled). Refusing to delete anything inside it. kubectl said:\n%s\n' \
    "$NAMESPACE" "$ns_msg" >&2
  exit 2
fi
if [[ "$ns_labels" != *"\"$SAMPLE_LABEL_KEY\":\"$SAMPLE_LABEL_VALUE\""* ]]; then
  printf 'error: namespace %s is not labelled %s=%s, so this sample did not create it.
Refusing to delete objects inside a namespace another demo may own. If you ran the sample
in a namespace you own, set NAMESPACE to it and ensure it carries that label.\n' \
    "$NAMESPACE" "$SAMPLE_LABEL_KEY" "$SAMPLE_LABEL_VALUE" >&2
  exit 2
fi
echo "Namespace '$NAMESPACE' is this sample's (labelled $SAMPLE_LABEL_KEY=$SAMPLE_LABEL_VALUE)."

# Collect every volume ID this sample's claims hold, BEFORE deleting anything, so the
# confirmation at the end can look each one up in EC2. Record the claim name too, for the
# messages.
declare -a vol_ids=() vol_claims=()
record_volume() { # record_volume <pvc-name>
  local pvc="$1" pv vid
  pv="$($KUBECTL get pvc "$pvc" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}' 2>/dev/null)"
  [[ -z "$pv" ]] && return 0
  vid="$($KUBECTL get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)"
  [[ -n "$vid" ]] && { vol_ids+=("$vid"); vol_claims+=("$pvc"); }
}
record_volume "$PVC"
for c in $($KUBECTL get pvc -n "$NAMESPACE" -l "$SET_SELECTOR" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  record_volume "$c"
done

echo "Deleting pods..."
$KUBECTL delete pod "$POD" "$SECOND_POD" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m \
  || warn "could not confirm the pods were deleted"

echo "Deleting the StatefulSet and its headless Service (a no-op unless applied)..."
# statefulset-ebs.yaml holds exactly a headless Service and the StatefulSet, no standalone
# PVC, and sets no persistentVolumeClaimRetentionPolicy (so its per-replica claims are
# Retained and swept separately below). Deleting these two destroys no data, so it runs
# even under --keep-data.
$KUBECTL delete statefulset "$SET" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m \
  || warn "could not confirm the StatefulSet was deleted"
$KUBECTL delete service "$SET" -n "$NAMESPACE" --ignore-not-found \
  || warn "could not confirm the Service was deleted"
# The StatefulSet's pods cascade-delete in the background; block on them by label before
# deleting their claims, so the volumes can detach before the CSI driver deletes them.
$KUBECTL delete pod -l "$SET_SELECTOR" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m \
  || warn "could not confirm the StatefulSet pods were deleted"

if [[ "$keep_data" == true ]]; then
  echo "Kept every PVC and its EBS volume (--keep-data):"
  echo "  pvc/$PVC and any data-$SET-* per-replica claims."
  echo "Done (data kept). The StorageClass was left in place."
  exit 0
fi

echo "Deleting the single-pod claim (this deletes its EBS volume)..."
$KUBECTL delete pvc "$PVC" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m \
  || warn "could not confirm pvc/$PVC was deleted"
echo "Deleting any data-$SET-* per-replica claims (one EBS volume each)..."
$KUBECTL delete pvc -l "$SET_SELECTOR" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m \
  || warn "could not confirm the per-replica claims were deleted"

# Confirm each volume we recorded is actually gone in EC2. A lookup that fails is "could
# not determine", not "gone": report it and mark the clean up incomplete. The CSI driver
# deletes the volume asynchronously after the pod detaches and the claim is removed, so a
# volume that is still 'in-use' or 'deleting' the instant the claim delete returns is on
# its way out, not stuck. Poll each one up to EBS_CONFIRM_TIMEOUT seconds (default 180)
# before deciding, so a correct teardown is not reported as incomplete; only a volume
# still present after the budget, or a read that fails, marks the clean up incomplete.
EBS_CONFIRM_TIMEOUT="${EBS_CONFIRM_TIMEOUT:-180}"
if ((${#vol_ids[@]} > 0)); then
  if command -v "${AWS%% *}" >/dev/null 2>&1; then
    echo "Confirming the EBS volumes are gone (waiting up to ${EBS_CONFIRM_TIMEOUT}s for the CSI driver to delete them)..."
    region="${AWS_REGION:-}"
    for i in "${!vol_ids[@]}"; do
      vid="${vol_ids[$i]}"; claim="${vol_claims[$i]}"
      deadline=$(( $(date +%s) + EBS_CONFIRM_TIMEOUT ))
      while true; do
        q_err="$(mktemp)"
        state="$($AWS ec2 describe-volumes --volume-ids "$vid" ${region:+--region "$region"} \
          --query 'Volumes[0].State' --output text 2>"$q_err")"
        rc=$?
        if grep -qi 'InvalidVolume.NotFound' "$q_err"; then
          echo "  $claim: volume $vid is gone."
          rm -f "$q_err"; break
        elif [[ $rc -ne 0 ]]; then
          # A real read failure (throttle, RBAC, network): could not determine, so fail
          # closed. Do not keep polling a call that is erroring.
          warn "could not determine whether volume $vid (from $claim) is gone; the describe-volumes call failed: $(sed 's/^/    /' "$q_err")"
          rm -f "$q_err"; break
        fi
        rm -f "$q_err"
        if [[ "$(date +%s)" -ge "$deadline" ]]; then
          warn "volume $vid (from $claim) is still '${state:-unknown}' after ${EBS_CONFIRM_TIMEOUT}s; it may still be billing. Check: aws ec2 describe-volumes --volume-ids $vid"
          break
        fi
        sleep 5
      done
    done
  else
    warn "aws CLI not on PATH; cannot confirm the EBS volumes are gone (recorded: ${vol_ids[*]})"
  fi
else
  echo "No sample PVCs were present, so there were no EBS volumes to confirm."
fi

echo "Left the StorageClass in place (cluster-wide and shared). To remove it, see the page's clean up."

if [[ "$incomplete" -ne 0 ]]; then
  printf '\nClean up INCOMPLETE: something above could not be deleted or confirmed. See the warnings.\n' >&2
  exit 1
fi
echo
echo "Clean up complete: every pod, the StatefulSet, the Service and every PVC this sample created are gone, and their EBS volumes are confirmed deleted."
