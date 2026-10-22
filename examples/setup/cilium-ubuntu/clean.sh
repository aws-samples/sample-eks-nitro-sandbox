#!/usr/bin/env bash
# Delete what this sample created, and nothing else:
#   the two node groups, the ENIs Cilium created that their instances left behind, the cluster
#   with everything in its eksctl stacks (VPC, subnets, gateways, security groups, IAM roles),
#   and the two node launch templates.
#
#   ./clean.sh --dry-run    list only run-owned resources it would delete; changes nothing
#   ./clean.sh              delete them, after you type the cluster name to confirm
#
# It refuses a cluster that is not tagged Demo=setup-cilium-ubuntu, and deletes ENIs and launch
# templates only when they carry that tag too. A lookup that fails means "could not determine",
# which is recorded as a failure and never read as "gone"; the script exits non-zero if
# anything it was asked to delete is still there afterwards.
#
# A full run bills EKS control-plane, EC2, EBS, NAT gateway and public IPv4 charges for as long
# as the cluster exists, so run this right after ./test.sh.
set -euo pipefail
SAMPLE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SAMPLE_DIR/scripts/common.sh"

dry_run=0
case "${1:-}" in
  --dry-run) dry_run=1 ;;
  "") ;;
  *) die "usage: ./clean.sh [--dry-run]" ;;
esac

require_commands aws eksctl python3
require_caller_account
lt_names="$CLUSTER_NAME-system,$CLUSTER_NAME-sandbox"

# leftover_enis <vpc>: ENIs this sample's Cilium created that are no longer attached.
leftover_enis() {
  aws ec2 describe-network-interfaces --region "$AWS_REGION" --filters \
    "Name=vpc-id,Values=$1" "Name=status,Values=available" "Name=tag:$DEMO_TAG_KEY,Values=$DEMO_TAG_VAL" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
}

# demo_launch_templates: the ids of the two node launch templates that exist AND are the
# sample's.
demo_launch_templates() {
  aws ec2 describe-launch-templates --region "$AWS_REGION" \
    --filters "Name=launch-template-name,Values=$lt_names" "Name=tag:$DEMO_TAG_KEY,Values=$DEMO_TAG_VAL" \
    --query 'LaunchTemplates[].LaunchTemplateId' --output text
}

state="$(cluster_state)"
vpc=""
if [[ "$state" != NONE ]]; then
  require_demo_cluster
  vpc="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" \
    --query cluster.resourcesVpcConfig.vpcId --output text)"
fi
lts="$(demo_launch_templates)"

if ((dry_run)); then
  step "dry run: what ./clean.sh would delete"
  if [[ "$state" == NONE ]]; then
    echo "Cluster $CLUSTER_NAME: already gone."
  else
    echo "Cluster $CLUSTER_NAME ($state) and every resource it owns:"
    python3 "$PY" owned | sed 's/^/  /'
    enis="$(leftover_enis "$vpc")" || enis="(could not be read; ./clean.sh would report it)"
    echo "Unattached Cilium ENIs in $vpc: ${enis:-none}" | tr '\t' ' '
    echo
  fi
  echo "Node launch templates ($lt_names): ${lts:-already gone}" | tr '\t' ' '
  echo
  echo "Nothing was changed. Run ./clean.sh without --dry-run to delete these."
  exit 0
fi

if [[ "${CLEAN_CONFIRM:-}" != "$CLUSTER_NAME" ]]; then
  read -r -p "This deletes cluster $CLUSTER_NAME and its VPC. Type the cluster name to confirm: " answer
  [[ "$answer" == "$CLUSTER_NAME" ]] || die "not confirmed; nothing was deleted"
fi

if [[ "$state" != NONE ]]; then
  step "1/4 node groups"
  for group in sandbox system; do
    if aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
      --nodegroup-name "$group" >/dev/null 2>&1; then
      eksctl delete nodegroup --region "$AWS_REGION" --cluster "$CLUSTER_NAME" --name "$group" \
        --disable-eviction --wait || clean_failed "eksctl delete nodegroup $group" ""
    fi
  done

  step "2/4 ENIs Cilium created (instances do not always take them along)"
  # A failed read is recorded, never taken as "none left": an ENI still in the VPC would make
  # the VPC deletion in step 3 fail.
  enis="$(leftover_enis "$vpc")" || { clean_failed "could not list leftover Cilium ENIs in $vpc" ""; enis=""; }
  for eni in $enis; do
    aws ec2 delete-network-interface --region "$AWS_REGION" --network-interface-id "$eni" \
      && echo "deleted $eni" || clean_failed "delete ENI $eni" ""
  done

  step "3/4 cluster, VPC and IAM roles (eksctl stacks)"
  eksctl delete cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --disable-nodegroup-eviction --wait \
    || clean_failed "eksctl delete cluster $CLUSTER_NAME" ""
fi

step "4/4 node launch templates"
for lt in $lts; do
  aws ec2 delete-launch-template --region "$AWS_REGION" --launch-template-id "$lt" >/dev/null \
    && echo "deleted $lt" || clean_failed "delete launch template $lt" ""
done

# Postconditions, read back rather than assumed.
[[ "$(cluster_state)" == NONE ]] || clean_failed "cluster $CLUSTER_NAME still exists" ""
left="$(demo_launch_templates)"
[[ -z "$left" ]] || clean_failed "launch templates remain: $left" ""
stacks="$(aws cloudformation list-stacks --region "$AWS_REGION" \
  --query "StackSummaries[?starts_with(StackName, 'eksctl-$CLUSTER_NAME-') && StackStatus!='DELETE_COMPLETE'].StackName" \
  --output text)"
[[ -z "$stacks" ]] || clean_failed "eksctl stacks remain: $stacks" ""
clean_summary "the Cilium-on-Ubuntu sample ($CLUSTER_NAME)"
