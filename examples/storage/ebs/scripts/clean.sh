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
# The sample's own StorageClass. The clean up deletes it ONLY when it exists AND carries the
# mark below, so a class the sample created is removed and the cluster default (or any class
# another workload owns) is never touched.
SAMPLE_CLASS=nitro-sandbox-ebs
SAMPLE_LABEL_KEY="app.kubernetes.io/part-of"
SAMPLE_LABEL_VALUE="nitro-sandbox-ebs"
# The same key with its dots backslash-escaped, for use inside a jsonpath expression: an
# unescaped dot is a field separator there, so {.metadata.labels.app.kubernetes.io/part-of}
# would look for nested fields and return empty, reading a marked object as unmarked.
SAMPLE_LABEL_JSONPATH='app\.kubernetes\.io/part-of'
# Select the StatefulSet's pods and per-replica claims on BOTH the app label AND this
# sample's part-of label, so an unrelated object that merely carries app=ebs-sandbox-set is
# never recorded or deleted. The StatefulSet stamps both labels on its pod template and its
# volumeClaimTemplates.
SET_SELECTOR="app=$SET,$SAMPLE_LABEL_KEY=$SAMPLE_LABEL_VALUE"

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

# Never delete anything inside a namespace this sample did not create. Three outcomes, kept
# apart so a failed read is never mistaken for "absent" (fail open) or "ours" (unsafe):
# the namespace exists, it does not exist, or the read itself failed. `get -o name` prints
# the object when it exists and nothing when it does not; `--ignore-not-found` turns the
# NotFound case into a clean exit 0 with empty output, so a non-zero status or non-empty
# stderr is a real read failure. Fail closed on that: refuse rather than guess.
ns_exist_err="$(mktemp)"
ns_name="$($KUBECTL get namespace "$NAMESPACE" --ignore-not-found -o name 2>"$ns_exist_err")"
ns_exist_rc=$?
ns_exist_msg="$(sed 's/^/  /' "$ns_exist_err")"; rm -f "$ns_exist_err"
if [[ $ns_exist_rc -ne 0 ]]; then
  printf 'error: could not determine whether namespace %s exists (the read failed, not a
report that it is absent). Refusing to clean up on an unknown state. kubectl said:\n%s\n' \
    "$NAMESPACE" "$ns_exist_msg" >&2
  exit 2
fi
if [[ -z "$ns_name" ]]; then
  echo "Namespace '$NAMESPACE' does not exist; nothing to clean up."
  exit 0
fi
# Read the exact label value, not the whole labels map: the map's jsonpath serialization
# varies by kubectl version (a Go map[...] string on some, JSON on others), and a substring
# match against either is fragile and can be fooled by a prefix. The dotted key is escaped
# with backslashes. A failed read is kept distinct from an absent label.
ns_label_err="$(mktemp)"
ns_label="$($KUBECTL get namespace "$NAMESPACE" \
  -o "jsonpath={.metadata.labels.app\.kubernetes\.io/part-of}" 2>"$ns_label_err")"
ns_label_rc=$?
ns_label_msg="$(sed 's/^/  /' "$ns_label_err")"; rm -f "$ns_label_err"
if [[ $ns_label_rc -ne 0 ]]; then
  printf 'error: could not read the %s label of namespace %s (the read failed, not a report
that it is unlabelled). Refusing to delete anything inside it. kubectl said:\n%s\n' \
    "$SAMPLE_LABEL_KEY" "$NAMESPACE" "$ns_label_msg" >&2
  exit 2
fi
if [[ "$ns_label" != "$SAMPLE_LABEL_VALUE" ]]; then
  printf 'error: namespace %s is not labelled %s=%s (found %s=%s), so this sample did not
create it. Refusing to delete objects inside a namespace another demo may own. If you ran
the sample in a namespace you own, set NAMESPACE to it and ensure it carries that label.\n' \
    "$NAMESPACE" "$SAMPLE_LABEL_KEY" "$SAMPLE_LABEL_VALUE" "$SAMPLE_LABEL_KEY" "${ns_label:-<unset>}" >&2
  exit 2
fi
echo "Namespace '$NAMESPACE' is this sample's (labelled $SAMPLE_LABEL_KEY=$SAMPLE_LABEL_VALUE)."

# Collect every volume ID this sample's claims hold, BEFORE deleting anything, so the
# confirmation at the end can look each one up in EC2. Record the claim name too, for the
# messages. A read that FAILS here (as opposed to a claim that is simply absent or not yet
# bound) must not be mistaken for "no volume": a claim could then be deleted and its EBS
# volume never confirmed, with the clean up still reporting success. So warn on a failed
# read and mark the clean up incomplete.
declare -a vol_ids=() vol_claims=()
record_volume() { # record_volume <pvc-name>
  local pvc="$1" pv vid e1 e2
  e1="$(mktemp)"
  pv="$($KUBECTL get pvc "$pvc" -n "$NAMESPACE" --ignore-not-found -o jsonpath='{.spec.volumeName}' 2>"$e1")"
  if [[ $? -ne 0 ]]; then
    warn "could not read pvc/$pvc to record its volume before deleting it: $(sed 's/^/    /' "$e1")"
    rm -f "$e1"; return 0
  fi
  rm -f "$e1"
  # Absent claim, or bound-but-not-yet-provisioned: nothing to record, not a failure.
  [[ -z "$pv" ]] && return 0
  # No --ignore-not-found here: an absent PVC is legitimate (handled above by the empty
  # pv), but a bound PVC that names a PV which is MISSING is an unsuccessful lookup, not
  # "no volume". Let NotFound exit non-zero so it reaches the warn path and marks the clean
  # up incomplete, rather than silently recording nothing and deleting the claim anyway.
  e2="$(mktemp)"
  vid="$($KUBECTL get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}' 2>"$e2")"
  if [[ $? -ne 0 ]]; then
    warn "could not read pv/$pv (claim $pvc) to record its volume id: $(sed 's/^/    /' "$e2")"
    rm -f "$e2"; return 0
  fi
  rm -f "$e2"
  [[ -n "$vid" ]] && { vol_ids+=("$vid"); vol_claims+=("$pvc"); }
}
record_volume "$PVC"
set_claim_err="$(mktemp)"
set_claims="$($KUBECTL get pvc -n "$NAMESPACE" -l "$SET_SELECTOR" -o jsonpath='{.items[*].metadata.name}' 2>"$set_claim_err")"
if [[ $? -ne 0 ]]; then
  warn "could not list the StatefulSet's per-replica claims to record their volumes: $(sed 's/^/    /' "$set_claim_err")"
fi
rm -f "$set_claim_err"
for c in $set_claims; do
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
  echo "Left any StorageClass in place too (a class is not data; re-run setup to land back on the kept volumes)."
  # The workload deletes above still had to succeed. If one of them could not be confirmed,
  # say so and exit non-zero rather than reporting a clean "data kept".
  if [[ "$incomplete" -ne 0 ]]; then
    printf '\nClean up INCOMPLETE: a workload delete above could not be confirmed. See the warnings.\n' >&2
    exit 1
  fi
  echo "Done (data kept)."
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

# Delete the sample's OWN StorageClass, and only that. The rule is strict: delete
# nitro-sandbox-ebs only when it exists AND carries this sample's mark. A class that does
# not exist is nothing to do; a class that exists without the mark is not ours (setup would
# have refused to use it), so we must not delete it; and the cluster default is never named
# here, so it is never touched. A read that fails is "could not determine", which marks the
# clean up incomplete rather than guessing.
sc_mark_err="$(mktemp)"
if sc_mark="$($KUBECTL get storageclass "$SAMPLE_CLASS" --ignore-not-found \
      -o "jsonpath={.metadata.labels.$SAMPLE_LABEL_JSONPATH}" 2>"$sc_mark_err")"; then
  sc_mark_rc=0
else
  sc_mark_rc=$?
fi
sc_mark_msg="$(sed 's/^/    /' "$sc_mark_err")"; rm -f "$sc_mark_err"
# Does the class exist at all? --ignore-not-found makes an absent class an empty-but-success
# read of the label too, so distinguish "exists" with a separate name read.
sc_exist_err="$(mktemp)"
if sc_exist="$($KUBECTL get storageclass "$SAMPLE_CLASS" --ignore-not-found -o name 2>"$sc_exist_err")"; then
  sc_exist_rc=0
else
  sc_exist_rc=$?
fi
sc_exist_msg="$(sed 's/^/    /' "$sc_exist_err")"; rm -f "$sc_exist_err"
if [[ $sc_exist_rc -ne 0 || $sc_mark_rc -ne 0 ]]; then
  warn "could not determine whether the sample's StorageClass '$SAMPLE_CLASS' exists or is marked; leaving it untouched:
${sc_exist_msg:-}${sc_mark_msg:-}"
elif [[ -z "$sc_exist" ]]; then
  echo "The sample's StorageClass '$SAMPLE_CLASS' is not present (setup used the cluster default, or it was never created). Nothing to delete; the cluster default is untouched."
elif [[ "$sc_mark" == "$SAMPLE_LABEL_VALUE" ]]; then
  echo "Deleting the sample's own StorageClass '$SAMPLE_CLASS' (it carries the sample's mark)..."
  $KUBECTL delete storageclass "$SAMPLE_CLASS" --ignore-not-found \
    || warn "could not confirm the sample's StorageClass '$SAMPLE_CLASS' was deleted"
else
  warn "a StorageClass named '$SAMPLE_CLASS' exists but is not marked $SAMPLE_LABEL_KEY=$SAMPLE_LABEL_VALUE, so this sample did not create it; leaving it untouched."
fi
echo "The cluster's default StorageClass was never touched."

if [[ "$incomplete" -ne 0 ]]; then
  printf '\nClean up INCOMPLETE: something above could not be deleted or confirmed. See the warnings.\n' >&2
  exit 1
fi
echo
echo "Clean up complete: every pod, the StatefulSet, the Service and every PVC this sample created are gone, their EBS volumes are confirmed deleted, and the sample's own StorageClass (if it created one) is removed."
