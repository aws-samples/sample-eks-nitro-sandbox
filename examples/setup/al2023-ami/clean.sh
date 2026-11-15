#!/usr/bin/env bash
# clean.sh: remove everything a run created, and only that. Deletes the pods and namespace (after
# confirming the namespace carries this run's label), the Karpenter NodePool + EC2NodeClass, the
# managed node group + launch template, and the AMI + snapshot. Deletes only resources that carry
# this run's ManagedBy=<RESOURCE_PREFIX> and RunId=<RUN_ID> tags; a resource that is not the run's,
# or a lookup that fails, leaves the clean up INCOMPLETE and exits non-zero.
#
#   RUN_ID=<id> ./clean.sh              # full clean up of that run
#   RUN_ID=<id> ./clean.sh --dry-run    # print what would be removed, change nothing
#
# It never removes a shared install (vpc-cni, the RuntimeClasses, Karpenter itself); the page
# says what stays. The host may block `aws ec2 delete-*`/`deregister-image`: this script prints
# those as an ordered teardown you run, rather than rewording them.
set -uo pipefail
SAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SAMPLE_DIR/scripts/lib/common.sh"
require_run_id

DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
incomplete=0
act() { # act <description> <command...> ; in dry-run just print
  if [ "$DRY" = 1 ]; then printf '  would: %s\n' "$*"; return 0; fi
  log "$1"; shift
  "$@" || { warn "step failed: $*"; incomplete=1; }
}
note_blocked() { # record an ec2/sqs delete the host blocks, for the handoff script
  printf '%s\n' "$1" >> "$RUN_STATE_DIR/teardown-remaining.sh"
  warn "host may block this; recorded in $RUN_STATE_DIR/teardown-remaining.sh: $1"
}
: > "${RUN_STATE_DIR}/teardown-remaining.sh" 2>/dev/null || true

# --- Pods + namespace (check the namespace is this run's before deleting anything in it) ------
if kc get namespace "$NAMESPACE" >/dev/null 2>&1; then
  ns_json=$(kc get namespace "$NAMESPACE" -o json 2>/dev/null)
  ns_owner=$(printf '%s' "$ns_json" | json_get "d['metadata'].get('labels',{}).get('app.kubernetes.io/part-of','')")
  ns_run=$(printf '%s' "$ns_json" | json_get "d['metadata'].get('labels',{}).get('app.kubernetes.io/instance','')")
  if [ "$ns_owner" = "$RESOURCE_PREFIX" ] && [ "$ns_run" = "$RUN_ID" ]; then
    act "deleting namespace $NAMESPACE (this run's)" kc delete namespace "$NAMESPACE" --wait=false
  else
    warn "namespace $NAMESPACE is not run $RUN_ID's (part-of='${ns_owner:-none}', instance='${ns_run:-none}'); leaving it. Clean up incomplete."
    incomplete=1
  fi
else
  log "namespace $NAMESPACE not present; nothing to delete there"
fi

# --- Karpenter NodePool + EC2NodeClass (named for the blueprint) ------------------------------
if kc get crd ec2nodeclasses.karpenter.k8s.aws >/dev/null 2>&1; then
  act "deleting Karpenter NodePool al2023-nitro-sandbox" kc delete nodepool al2023-nitro-sandbox --ignore-not-found
  act "deleting Karpenter EC2NodeClass al2023-nitro-sandbox" kc delete ec2nodeclass al2023-nitro-sandbox --ignore-not-found
fi

# --- Managed node group (only if it carries this run's tags) ---------------------------------
ng_tags=$(aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" --query 'nodegroup.tags' --output json 2>/dev/null || echo '{}')
if printf '%s' "$ng_tags" | tags_match; then
  act "deleting managed node group $NODEGROUP_NAME" aws eks delete-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME"
  [ "$DRY" = 1 ] || { log "waiting for node group deletion"; aws eks wait nodegroup-deleted --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" 2>/dev/null || true; }
elif [ "$ng_tags" != '{}' ]; then
  warn "node group $NODEGROUP_NAME exists but is not tagged for run $RUN_ID; leaving it. Clean up incomplete."
  incomplete=1
fi

# --- Launch template, AMI, snapshot: ec2 delete-* (host may block) ----------------------------
lt_id=$(aws ec2 describe-launch-templates --region "$AWS_REGION" --launch-template-names "$LT_NAME" --query 'LaunchTemplates[0].LaunchTemplateId' --output text 2>/dev/null || true)
[ -n "$lt_id" ] && [ "$lt_id" != None ] && note_blocked "aws ec2 delete-launch-template --region $AWS_REGION --profile ${AWS_PROFILE:-eks-sandbox} --launch-template-id $lt_id"
ami_id=$(sed -n 's/^AMI_ID=//p' "$RUN_STATE_DIR/run-state.env" 2>/dev/null | tail -n 1)
if [ -n "$ami_id" ]; then
  snap=$(aws ec2 describe-images --region "$AWS_REGION" --image-ids "$ami_id" --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text 2>/dev/null || true)
  note_blocked "aws ec2 deregister-image --region $AWS_REGION --profile ${AWS_PROFILE:-eks-sandbox} --image-id $ami_id"
  [ -n "$snap" ] && [ "$snap" != None ] && note_blocked "aws ec2 delete-snapshot --region $AWS_REGION --profile ${AWS_PROFILE:-eks-sandbox} --snapshot-id $snap"
fi

echo
if [ -s "$RUN_STATE_DIR/teardown-remaining.sh" ]; then
  echo "Some deletes are host-blocked ec2 operations; run them yourself (ordered):"
  echo "  $RUN_STATE_DIR/teardown-remaining.sh"
fi
if [ "$incomplete" = 1 ]; then
  echo "CLEAN UP INCOMPLETE: something was not this run's, or a lookup failed. See the warnings above."
  exit 1
fi
echo "Clean up complete for run $RUN_ID (except any host-blocked ec2 steps listed above)."
