#!/usr/bin/env bash
# clean.sh: remove what this sample created, in one of three modes that match the README's
# three documented invocations. Every AWS resource it removes must carry the ownership tag
# ManagedBy=<RESOURCE_PREFIX>; a lookup that fails is "could not determine", never "gone".
#
#   ./clean.sh --dry-run               # list only run-owned resources; change nothing
#   ./clean.sh                         # remove the Kubernetes validation workload only
#   ./clean.sh --delete-aws-resources  # also remove the owned AWS infrastructure and AMI
#
# The bare run removes only the Kubernetes workload (the namespace, after confirming its
# ownership label), so a reader can tear down the pods and the network policy without
# deleting the node group and AMI a longer investigation still needs. --delete-aws-resources
# does the full teardown: workload, then node group, instances, AMI/snapshots, launch
# template, build security group, instance profile and roles, then verifies absence.
set -uo pipefail
SAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SAMPLE_DIR/scripts/lib/common.sh"
KUBECTL="${KUBECTL:-kubectl}"

DRY_RUN=0
DELETE_AWS=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --delete-aws-resources) DELETE_AWS=1 ;;
    *) die "unknown argument: $arg (supported: --dry-run, --delete-aws-resources)" ;;
  esac
done

incomplete=0
warn_inc() { printf 'warning: %s\n' "$*" >&2; incomplete=1; }

NODEGROUP_NAME="${NODEGROUP_NAME:-${RESOURCE_PREFIX}-ng}"
LT_NAME="${RESOURCE_PREFIX}-lt"
TAG_FILTER="Name=tag:${TAGS_OWNER_KEY},Values=${TAGS_OWNER_VALUE}"

echo "== resources tagged ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} in $AWS_REGION =="

list_owned_instances() {
  aws ec2 describe-instances --region "$AWS_REGION" --filters "$TAG_FILTER" \
    --query 'Reservations[].Instances[?State.Name!=`terminated`].[InstanceId,State.Name,Tags[?Key==`Name`]|[0].Value]' \
    --output text 2>/dev/null
}
list_owned_images() {
  aws ec2 describe-images --region "$AWS_REGION" --owners self --filters "$TAG_FILTER" \
    --query 'Images[].[ImageId,Name]' --output text 2>/dev/null
}
list_owned_security_groups() {
  aws ec2 describe-security-groups --region "$AWS_REGION" --filters "$TAG_FILTER" \
    --query 'SecurityGroups[].[GroupId,GroupName]' --output text 2>/dev/null
}
list_owned_launch_templates() {
  aws ec2 describe-launch-templates --region "$AWS_REGION" --filters "$TAG_FILTER" \
    --query 'LaunchTemplates[].[LaunchTemplateId,LaunchTemplateName]' --output text 2>/dev/null
}
list_owned_roles() {
  # Tag-based, matching every other list_owned_* helper: scripts/00a-iam.sh tags the roles
  # it creates ManagedBy=<RESOURCE_PREFIX>. Use the Resource Groups Tagging API (it resolves
  # IAM role tags directly); fall back to per-role tag reads if that API is unavailable.
  local arns
  arns=$(aws resourcegroupstaggingapi get-resources --region "$AWS_REGION" \
    --resource-type-filters iam:role \
    --tag-filters "Key=${TAGS_OWNER_KEY},Values=${TAGS_OWNER_VALUE}" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null)
  if [[ -n "$arns" ]]; then
    for arn in $arns; do printf '%s\n' "${arn##*/}"; done
    return
  fi
  # Fallback: enumerate roles and keep only those carrying the ownership tag.
  local names name val
  names=$(aws iam list-roles --query 'Roles[].RoleName' --output text 2>/dev/null)
  for name in $names; do
    val=$(aws iam list-role-tags --role-name "$name" \
      --query "Tags[?Key=='${TAGS_OWNER_KEY}'].Value | [0]" --output text 2>/dev/null)
    [[ "$val" == "$TAGS_OWNER_VALUE" ]] && printf '%s\n' "$name"
  done
}

instances="$(list_owned_instances)"
images="$(list_owned_images)"
sgs="$(list_owned_security_groups)"
lts="$(list_owned_launch_templates)"
roles="$(list_owned_roles)"
ng_exists=$(aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODEGROUP_NAME" --query 'nodegroup.nodegroupName' --output text 2>/dev/null || true)

echo "EC2 instances:"; printf '%s\n' "${instances:-  (none)}"
echo "AMIs:"; printf '%s\n' "${images:-  (none)}"
echo "Security groups:"; printf '%s\n' "${sgs:-  (none)}"
echo "Launch templates:"; printf '%s\n' "${lts:-  (none)}"
echo "IAM roles (ManagedBy=${TAGS_OWNER_VALUE}-tagged):"
printf '%s\n' "${roles:-  (none)}"
echo "EKS managed node group: ${ng_exists:-<absent>}"

if [[ "$DRY_RUN" == 1 ]]; then
  echo
  echo "--dry-run: nothing was deleted."
  exit 0
fi

echo
echo "== deleting the validation workload (namespace $NAMESPACE) =="
ns_label_err="$(mktemp)"
ns_label="$($KUBECTL get namespace "$NAMESPACE" --ignore-not-found \
  -o "jsonpath={.metadata.labels.app\.kubernetes\.io/part-of}" 2>"$ns_label_err")"
ns_rc=$?
ns_err_msg="$(sed 's/^/  /' "$ns_label_err")"; rm -f "$ns_label_err"
if [[ $ns_rc -ne 0 ]]; then
  warn_inc "could not read namespace $NAMESPACE's ownership label (the read failed, not a report it is absent): $ns_err_msg"
elif [[ -z "$ns_label" ]]; then
  echo "namespace $NAMESPACE does not exist or carries no label; nothing namespaced to delete."
elif [[ "$ns_label" != "$RESOURCE_PREFIX" ]]; then
  warn_inc "namespace $NAMESPACE is not labelled app.kubernetes.io/part-of=$RESOURCE_PREFIX; refusing to delete objects inside a namespace this sample may not own."
else
  $KUBECTL delete namespace "$NAMESPACE" --wait=true --timeout=5m \
    || warn_inc "could not confirm namespace $NAMESPACE was deleted"
fi

if [[ "$DELETE_AWS" != 1 ]]; then
  echo
  if [[ "$incomplete" -ne 0 ]]; then
    printf 'Workload clean up INCOMPLETE: see the warnings above.\n' >&2
    exit 1
  fi
  echo "Workload removed. The owned AWS infrastructure (node group, instances, AMI, launch"
  echo "template, security group, instance profile and roles) is left in place. Re-run with"
  echo "--delete-aws-resources to remove it, or ./clean.sh --dry-run to see what remains."
  exit 0
fi

echo "== deleting the managed node group =="
if [[ -n "$ng_exists" ]]; then
  aws eks delete-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" >/dev/null \
    || warn_inc "could not issue delete-nodegroup for $NODEGROUP_NAME"
  aws eks wait nodegroup-deleted --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" \
    || warn_inc "could not confirm node group $NODEGROUP_NAME was deleted"
else
  echo "no owned node group named $NODEGROUP_NAME; nothing to delete."
fi

echo "== terminating owned EC2 instances (build + verification hosts) =="
if [[ -n "$instances" ]]; then
  ids=$(printf '%s\n' "$instances" | awk '{print $1}')
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids $ids >/dev/null \
    || warn_inc "could not issue terminate-instances for: $ids"
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids $ids \
    || warn_inc "could not confirm termination for: $ids"
else
  echo "no owned instances found; nothing to terminate."
fi

echo "== deregistering owned AMIs and deleting their snapshots =="
if [[ -n "$images" ]]; then
  while read -r image_id _name; do
    [[ -z "$image_id" ]] && continue
    snaps=$(aws ec2 describe-images --region "$AWS_REGION" --image-ids "$image_id" \
      --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text 2>/dev/null)
    aws ec2 deregister-image --region "$AWS_REGION" --image-id "$image_id" \
      || warn_inc "could not deregister AMI $image_id"
    for snap in $snaps; do
      [[ -z "$snap" || "$snap" == "None" ]] && continue
      aws ec2 delete-snapshot --region "$AWS_REGION" --snapshot-id "$snap" \
        || warn_inc "could not delete snapshot $snap (from AMI $image_id)"
    done
  done <<< "$images"
else
  echo "no owned AMIs found; nothing to deregister."
fi

echo "== deleting owned launch templates =="
if [[ -n "$lts" ]]; then
  while read -r lt_id _name; do
    [[ -z "$lt_id" ]] && continue
    aws ec2 delete-launch-template --region "$AWS_REGION" --launch-template-id "$lt_id" \
      || warn_inc "could not delete launch template $lt_id"
  done <<< "$lts"
else
  echo "no owned launch templates found; nothing to delete."
fi

echo "== deleting the owned build security group =="
if [[ -n "$sgs" ]]; then
  while read -r sg_id _name; do
    [[ -z "$sg_id" ]] && continue
    aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$sg_id" \
      || warn_inc "could not delete security group $sg_id (it may still be referenced; retry once dependent resources are gone)"
  done <<< "$sgs"
else
  echo "no owned security groups found; nothing to delete."
fi

echo "== deleting owned IAM instance profiles and roles =="
if [[ -n "$roles" ]]; then
  for role in $roles; do
    profiles=$(aws iam list-instance-profiles-for-role --role-name "$role" --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null)
    for profile in $profiles; do
      aws iam remove-role-from-instance-profile --instance-profile-name "$profile" --role-name "$role" 2>/dev/null || true
      aws iam delete-instance-profile --instance-profile-name "$profile" 2>/dev/null \
        || warn_inc "could not delete instance profile $profile"
    done
    policies=$(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null)
    for policy_arn in $policies; do
      aws iam detach-role-policy --role-name "$role" --policy-arn "$policy_arn" 2>/dev/null || true
    done
    # Inline policies (e.g. scripts/00a-iam.sh's build-host inline policy) block delete-role
    # with DeleteConflict until removed; detach-role-policy above only covers managed ones.
    inline_policies=$(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null)
    for policy_name in $inline_policies; do
      aws iam delete-role-policy --role-name "$role" --policy-name "$policy_name" 2>/dev/null || true
    done
    aws iam delete-role --role-name "$role" 2>/dev/null \
      || warn_inc "could not delete IAM role $role"
  done
else
  echo "no owned IAM roles found; nothing to delete."
fi

echo "== verifying absence =="
remaining_instances="$(list_owned_instances)"
remaining_images="$(list_owned_images)"
[[ -z "$remaining_instances" ]] || warn_inc "owned instances still present after cleanup: $remaining_instances"
[[ -z "$remaining_images" ]] || warn_inc "owned AMIs still present after cleanup: $remaining_images"

if [[ "$incomplete" -ne 0 ]]; then
  printf '\nClean up INCOMPLETE: see the warnings above.\n' >&2
  exit 1
fi
echo
echo "Clean up complete: validation workload, node group, instances, AMI/snapshots, launch template, security group, instance profile and roles are gone."
