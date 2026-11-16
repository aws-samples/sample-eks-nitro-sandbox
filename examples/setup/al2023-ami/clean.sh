#!/usr/bin/env bash
# clean.sh: remove everything a run created, and only that. Deletes the namespace, the Karpenter
# NodePool + EC2NodeClass, the managed node group, the launch template, and the AMI + snapshot.
# A resource is touched only if it carries this run's ownership mark (labels for Kubernetes
# objects, ManagedBy=<RESOURCE_PREFIX> and RunId=<RUN_ID> tags for AWS). A resource that is not
# the run's, a lookup that fails, or a delete the host blocks leaves the clean up INCOMPLETE and
# exits non-zero. "Not found" is accepted as gone only when the API says so.
#
#   RUN_ID=<id> KUBE_CONTEXT=<ctx> ./clean.sh              # full clean up of that run
#   RUN_ID=<id> KUBE_CONTEXT=<ctx> ./clean.sh --dry-run    # print what would be removed
#
# It never removes a shared install (vpc-cni, the RuntimeClasses, Karpenter itself); the page
# says what stays. The host may block `aws ec2 delete-*`/`deregister-image`: this script writes
# those to a file as an ordered teardown for you to run, rather than rewording them.
set -uo pipefail
SAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SAMPLE_DIR/scripts/lib/common.sh"
require_run_id
# --- Identity: clean up only the run that setup recorded -------------------------------------
rec() { sed -n "s/^$1=//p" "$RUN_STATE_DIR/run-state.env" 2>/dev/null | head -n 1; }
for v in RESOURCE_PREFIX CLUSTER_NAME AWS_REGION NAMESPACE; do
  r=$(rec "$v"); c=${!v}
  [ -n "$r" ] || die "run state has no $v, so run $RUN_ID's target cannot be confirmed; refusing to delete anything"
  [ "$r" = "$c" ] || die "$v is '$c' but run $RUN_ID recorded '$r'; set it to the recorded value. Refusing to delete anything"
done

require_kube_context

DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
incomplete=0
REMAINING="$RUN_STATE_DIR/teardown-remaining.sh"
: > "$REMAINING" 2>/dev/null || { warn "cannot write $REMAINING"; incomplete=1; }

act() { # act <description> <command...>; in dry-run only print
  if [ "$DRY" = 1 ]; then printf '  would: %s\n' "$2 ${*:3}"; return 0; fi
  log "$1"; shift
  "$@" || { warn "step failed: $*"; incomplete=1; }
}
note_blocked() { # an ec2 delete the host may block: record it for the ordered hand-off script
  printf '%s\n' "$1" >> "$REMAINING"
  incomplete=1
  warn "not deleted here; recorded in $REMAINING: $1"
}
# probe <not-found-regex> <command...>: 0 = found (output in PROBE_OUT), 1 = the API said not
# found, 2 = could not determine (any other failure). Only 1 may be treated as "gone".
probe() {
  local nf="$1" err; shift
  err=$(mktemp)
  if PROBE_OUT=$("$@" 2>"$err"); then rm -f "$err"; return 0; fi
  if grep -Eq "$nf" "$err"; then rm -f "$err"; return 1; fi
  warn "could not determine state ($*): $(head -n 2 "$err")"; rm -f "$err"; return 2
}
jfield() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1], {"d": d})))' "$1"; }

# --- Account: the one the run was created in ----------------------------------------------------
recorded=$(sed -n 's/^ACCOUNT_ID=//p' "$RUN_STATE_DIR/run-state.env" 2>/dev/null | tail -n 1)
[ -n "$recorded" ] || die "run state has no ACCOUNT_ID, so the account cannot be confirmed; refusing to delete anything"
current=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || die "could not read the current AWS account (sts get-caller-identity failed); refusing to delete anything"
[ "$current" = "$recorded" ] || die "credentials are for a different account than run $RUN_ID was created in; refusing to delete anything"

# --- Kubernetes objects: delete only one that carries this run's labels --------------------------
owned_by_run() { # reads an object's JSON on stdin
  python3 -c '
import json, sys
l = json.load(sys.stdin).get("metadata", {}).get("labels", {}) or {}
sys.exit(0 if l.get("app.kubernetes.io/part-of") == sys.argv[1] and l.get("app.kubernetes.io/instance") == sys.argv[2] else 1)
' "$RESOURCE_PREFIX" "$RUN_ID"
}
delete_if_owned() { # delete_if_owned <kind> <name> [extra delete args]
  local kind="$1" name="$2"; shift 2
  probe 'NotFound|not found' kc get "$kind" "$name" -o json; local rc=$?
  case $rc in
    0) if printf '%s' "$PROBE_OUT" | owned_by_run; then
         act "deleting $kind $name (this run's)" kc delete "$kind" "$name" "$@"
       else
         warn "$kind $name is not run $RUN_ID's; leaving it. Clean up incomplete."; incomplete=1
       fi ;;
    1) log "$kind $name not present" ;;
    *) incomplete=1 ;;
  esac
}
delete_if_owned namespace "$NAMESPACE" --wait=false
probe 'NotFound|not found' kc get crd ec2nodeclasses.karpenter.k8s.aws; rc=$?
case $rc in
  0) delete_if_owned nodepool al2023-nitro-sandbox
     delete_if_owned ec2nodeclass al2023-nitro-sandbox ;;
  1) log "Karpenter CRDs not present; no NodePool or EC2NodeClass to delete" ;;
  *) incomplete=1 ;;
esac

# --- Managed node group (only if it carries this run's tags) ------------------------------------
probe 'ResourceNotFoundException' aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODEGROUP_NAME" --query 'nodegroup.tags' --output json; rc=$?
case $rc in
  0) if printf '%s' "$PROBE_OUT" | tags_match; then
       act "deleting managed node group $NODEGROUP_NAME" aws eks delete-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME"
       [ "$DRY" = 1 ] || act "waiting for node group deletion" aws eks wait nodegroup-deleted --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME"
     else
       warn "node group $NODEGROUP_NAME is not tagged for run $RUN_ID; leaving it. Clean up incomplete."; incomplete=1
     fi ;;
  1) log "node group $NODEGROUP_NAME not present" ;;
  *) incomplete=1 ;;
esac

# --- Launch template, AMI, snapshot: ec2 deletes the host may block ------------------------------
probe 'NotFoundException|NotFound' aws ec2 describe-launch-templates --region "$AWS_REGION" --launch-template-names "$LT_NAME" --query 'LaunchTemplates[0]' --output json; rc=$?
case $rc in
  0) if printf '%s' "$PROBE_OUT" | jfield 'd.get("Tags") or []' | tags_match; then
       lt_id=$(printf '%s' "$PROBE_OUT" | json_get 'd["LaunchTemplateId"]')
       note_blocked "aws ec2 delete-launch-template --region $AWS_REGION --launch-template-id $lt_id"
     else
       warn "launch template $LT_NAME is not tagged for run $RUN_ID; leaving it. Clean up incomplete."; incomplete=1
     fi ;;
  1) log "launch template $LT_NAME not present" ;;
  *) incomplete=1 ;;
esac

ami_id=$(sed -n 's/^AMI_ID=//p' "$RUN_STATE_DIR/run-state.env" 2>/dev/null | tail -n 1)
if [ -n "$ami_id" ]; then
  probe 'InvalidAMIID' aws ec2 describe-images --region "$AWS_REGION" --image-ids "$ami_id" --query 'Images[0]' --output json; rc=$?
  case $rc in
    0) if printf '%s' "$PROBE_OUT" | jfield 'd.get("Tags") or []' | tags_match; then
         snaps=$(printf '%s' "$PROBE_OUT" | json_get '[b["Ebs"]["SnapshotId"] for b in d.get("BlockDeviceMappings", []) if b.get("Ebs", {}).get("SnapshotId")]')
         note_blocked "aws ec2 deregister-image --region $AWS_REGION --image-id $ami_id"
         # A snapshot is deleted only if it carries this run's own tags, checked one by one.
         for s in $snaps; do
           probe 'InvalidSnapshot' aws ec2 describe-snapshots --region "$AWS_REGION" --snapshot-ids "$s" --query 'Snapshots[0]' --output json; src=$?
           case $src in
             0) if printf '%s' "$PROBE_OUT" | jfield 'd.get("Tags") or []' | tags_match; then
                  note_blocked "aws ec2 delete-snapshot --region $AWS_REGION --snapshot-id $s"
                else
                  warn "snapshot $s is not tagged for run $RUN_ID; leaving it. Clean up incomplete."; incomplete=1
                fi ;;
             1) log "snapshot $s not present" ;;
             *) incomplete=1 ;;
           esac
         done
       else
         warn "AMI $ami_id is not tagged for run $RUN_ID; leaving it. Clean up incomplete."; incomplete=1
       fi ;;
    1) log "AMI $ami_id not present" ;;
    *) incomplete=1 ;;
  esac
fi

echo
[ -s "$REMAINING" ] && { echo "Deletes the host may block are listed in order; run them yourself:"; echo "  $REMAINING"; }
if [ "$incomplete" = 1 ]; then
  echo "CLEAN UP INCOMPLETE: something was not this run's, a lookup failed, or a delete is left for you. See the warnings above."
  exit 1
fi
echo "Clean up complete for run $RUN_ID."
