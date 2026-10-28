#!/usr/bin/env bash
# clean.sh: remove what this sample created, in one of three modes that match the README's
# three documented invocations. Every AWS resource it removes must carry the ownership tag
# ManagedBy=<RESOURCE_PREFIX>; a lookup that fails is "could not determine", never "gone", and
# leaves the clean up incomplete (exit 1).
#
#   ./clean.sh --dry-run               # list only run-owned resources; change nothing
#   ./clean.sh                         # remove the Kubernetes validation workload only
#   ./clean.sh --delete-aws-resources  # also remove the owned AWS infrastructure and AMI
#
# The bare run removes only the Kubernetes workload (the namespace, after confirming its
# ownership label), so a reader can tear down the pods and the network policy without deleting
# the node group and AMI a longer investigation still needs. --delete-aws-resources does the full
# teardown: workload, node group, instances, AMIs and snapshots, launch templates, the build
# security group, the staging buckets, the instance profile and roles, then re-lists every
# category to confirm absence.
#
# Never removed, because they are not the sample's: the vpc-cni add-on and the isolated-sandbox
# RuntimeClass (shared installs the reader set up; the README says how to remove them).
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
TAG_FILTER="Name=tag:${TAGS_OWNER_KEY},Values=${TAGS_OWNER_VALUE}"

# owned <var> <description> <command...>: run a lookup; on failure record "could not determine"
# (never an empty "none") and mark the clean up incomplete.
owned() {
  local __var="$1" what="$2" out rc errf; shift 2
  errf=$(mktemp)
  out=$("$@" 2>"$errf"); rc=$?
  if [[ $rc -ne 0 ]]; then
    warn_inc "could not determine $what (lookup failed, not a report that none exist): $(head -n 2 "$errf")"
    out="<could not determine>"
  fi
  rm -f "$errf"
  [[ "$out" == None ]] && out=""
  printf -v "$__var" '%s' "$out"
}
list_instances()  { aws ec2 describe-instances --region "$AWS_REGION" --filters "$TAG_FILTER" \
  --query 'Reservations[].Instances[?State.Name!=`terminated`].[InstanceId,State.Name,Tags[?Key==`Name`]|[0].Value]' --output text; }
list_images()     { aws ec2 describe-images --region "$AWS_REGION" --owners self --filters "$TAG_FILTER" \
  --query 'Images[].[ImageId,Name]' --output text; }
list_snapshots()  { aws ec2 describe-snapshots --region "$AWS_REGION" --owner-ids self --filters "$TAG_FILTER" \
  --query 'Snapshots[].[SnapshotId,VolumeSize]' --output text; }
list_sgs()        { aws ec2 describe-security-groups --region "$AWS_REGION" --filters "$TAG_FILTER" \
  --query 'SecurityGroups[].[GroupId,GroupName]' --output text; }
list_lts()        { aws ec2 describe-launch-templates --region "$AWS_REGION" --filters "$TAG_FILTER" \
  --query 'LaunchTemplates[].[LaunchTemplateId,LaunchTemplateName]' --output text; }
# Tag-based, like the rest: scripts/00a-iam.sh tags the roles it creates, and
# scripts/00b-stage-bucket.sh tags each staging bucket. The tagging API can still list a
# resource for a while after it is deleted, so each one is re-checked before it is touched.
list_roles()      { aws resourcegroupstaggingapi get-resources --region "$AWS_REGION" --resource-type-filters iam:role \
  --tag-filters "Key=${TAGS_OWNER_KEY},Values=${TAGS_OWNER_VALUE}" --query 'ResourceTagMappingList[].ResourceARN' --output text \
  | tr '\t' '\n' | sed -n 's#^arn:[^:]*:iam::[0-9]*:role/\(.*\)$#\1#p' | sed 's#.*/##'; }
list_buckets()    { aws resourcegroupstaggingapi get-resources --region "$AWS_REGION" --resource-type-filters s3 \
  --tag-filters "Key=${TAGS_OWNER_KEY},Values=${TAGS_OWNER_VALUE}" --query 'ResourceTagMappingList[].ResourceARN' --output text \
  | tr '\t' '\n' | sed -n 's#^arn:[^:]*:s3:::\(.*\)$#\1#p'; }
# nodegroup_state: the node group's status, "absent" only on ResourceNotFoundException.
nodegroup_state() {
  local out
  if out=$(aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
      --nodegroup-name "$NODEGROUP_NAME" --query 'nodegroup.[status,tags.'"$TAGS_OWNER_KEY"']' --output text 2>&1); then
    printf '%s\n' "$out"
  elif [[ "$out" == *ResourceNotFoundException* ]]; then
    echo absent
  else
    printf '%s\n' "$out" >&2; return 1
  fi
}
# bucket_state <bucket>: "absent" only when S3 answers 404; "owned" when it carries the tag.
bucket_state() {
  local b="$1" out tag
  if ! out=$(aws s3api head-bucket --bucket "$b" --region "$AWS_REGION" 2>&1); then
    [[ "$out" == *"Not Found"* || "$out" == *"404"* ]] && { echo absent; return 0; }
    printf '%s\n' "$out" >&2; return 1
  fi
  tag=$(aws s3api get-bucket-tagging --bucket "$b" --region "$AWS_REGION" \
    --query "TagSet[?Key=='${TAGS_OWNER_KEY}'].Value | [0]" --output text 2>&1) || { printf '%s\n' "$tag" >&2; return 1; }
  [[ "$tag" == "$TAGS_OWNER_VALUE" ]] && echo owned || echo not-owned
}

echo "== resources tagged ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} in $AWS_REGION =="
owned instances "owned EC2 instances" list_instances
owned images "owned AMIs" list_images
owned snapshots "owned EBS snapshots" list_snapshots
owned sgs "owned security groups" list_sgs
owned lts "owned launch templates" list_lts
owned roles "owned IAM roles" list_roles
owned buckets "owned S3 staging buckets" list_buckets
owned ng_state "the managed node group $NODEGROUP_NAME" nodegroup_state

echo "EC2 instances:"; printf '%s\n' "${instances:-  (none)}"
echo "AMIs:"; printf '%s\n' "${images:-  (none)}"
echo "EBS snapshots:"; printf '%s\n' "${snapshots:-  (none)}"
echo "Security groups:"; printf '%s\n' "${sgs:-  (none)}"
echo "Launch templates:"; printf '%s\n' "${lts:-  (none)}"
echo "S3 staging buckets:"; printf '%s\n' "${buckets:-  (none)}"
echo "IAM roles (and their instance profiles):"; printf '%s\n' "${roles:-  (none)}"
echo "EKS managed node group $NODEGROUP_NAME: ${ng_state:-<unknown>}"
echo "Left in place (shared, not the sample's): the vpc-cni add-on and the isolated-sandbox RuntimeClass on cluster $CLUSTER_NAME"

if [[ "$DRY_RUN" == 1 ]]; then
  echo
  echo "--dry-run: nothing was deleted."
  [[ "$incomplete" -eq 0 ]] || { echo "Some lookups failed; the list above is incomplete." >&2; exit 1; }
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
  if $KUBECTL get namespace "$NAMESPACE" >/dev/null 2>&1; then
    warn_inc "namespace $NAMESPACE exists but carries no app.kubernetes.io/part-of label; refusing to delete a namespace this sample may not own."
  else
    echo "namespace $NAMESPACE does not exist; nothing namespaced to delete."
  fi
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
  echo "template, security group, staging bucket, instance profile and roles) is left in place."
  echo "Re-run with --delete-aws-resources to remove it, or ./clean.sh --dry-run to see what remains."
  exit 0
fi

echo "== deleting the managed node group =="
case "$ng_state" in
  absent) echo "no node group named $NODEGROUP_NAME; nothing to delete." ;;
  "<could not determine>") warn_inc "skipping the node group: its state could not be determined" ;;
  *)
    ng_owner=$(printf '%s' "$ng_state" | awk '{print $2}')
    if [[ "$ng_owner" != "$TAGS_OWNER_VALUE" ]]; then
      warn_inc "node group $NODEGROUP_NAME does not carry ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE}; refusing to delete it"
    else
      aws eks delete-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" >/dev/null \
        || warn_inc "could not issue delete-nodegroup for $NODEGROUP_NAME"
      aws eks wait nodegroup-deleted --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" \
        || warn_inc "could not confirm node group $NODEGROUP_NAME was deleted"
    fi ;;
esac

echo "== terminating owned EC2 instances (build + verification hosts) =="
if [[ "$instances" == "<could not determine>" ]]; then :
elif [[ -n "$instances" ]]; then
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

echo "== deregistering owned AMIs, then deleting owned snapshots =="
if [[ "$images" == "<could not determine>" ]]; then :
elif [[ -n "$images" ]]; then
  while read -r image_id _name; do
    [[ -z "$image_id" ]] && continue
    aws ec2 deregister-image --region "$AWS_REGION" --image-id "$image_id" \
      || warn_inc "could not deregister AMI $image_id"
  done <<< "$images"
else
  echo "no owned AMIs found; nothing to deregister."
fi
# Snapshots are tagged at create-image time, so this also catches a snapshot whose AMI never
# finished registering.
owned snapshots "owned EBS snapshots" list_snapshots
if [[ "$snapshots" == "<could not determine>" ]]; then :
elif [[ -n "$snapshots" ]]; then
  while read -r snap _size; do
    [[ -z "$snap" ]] && continue
    aws ec2 delete-snapshot --region "$AWS_REGION" --snapshot-id "$snap" \
      || warn_inc "could not delete snapshot $snap"
  done <<< "$snapshots"
else
  echo "no owned snapshots found; nothing to delete."
fi

echo "== deleting owned launch templates =="
if [[ "$lts" == "<could not determine>" ]]; then :
elif [[ -n "$lts" ]]; then
  while read -r lt_id _name; do
    [[ -z "$lt_id" ]] && continue
    aws ec2 delete-launch-template --region "$AWS_REGION" --launch-template-id "$lt_id" >/dev/null \
      || warn_inc "could not delete launch template $lt_id"
  done <<< "$lts"
else
  echo "no owned launch templates found; nothing to delete."
fi

echo "== deleting the owned build security group =="
if [[ "$sgs" == "<could not determine>" ]]; then :
elif [[ -n "$sgs" ]]; then
  while read -r sg_id _name; do
    [[ -z "$sg_id" ]] && continue
    aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$sg_id" \
      || warn_inc "could not delete security group $sg_id (it may still be referenced; retry once dependent resources are gone)"
  done <<< "$sgs"
else
  echo "no owned security groups found; nothing to delete."
fi

echo "== emptying and deleting owned S3 staging buckets =="
if [[ "$buckets" == "<could not determine>" ]]; then :
elif [[ -n "$buckets" ]]; then
  for b in $buckets; do
    if ! st=$(bucket_state "$b"); then warn_inc "could not determine the state of bucket $b"; continue; fi
    case "$st" in
      absent) echo "bucket $b is already gone." ;;
      not-owned) warn_inc "bucket $b does not carry ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE}; refusing to delete it" ;;
      owned)
        aws s3 rm "s3://$b" --recursive --region "$AWS_REGION" >/dev/null \
          || warn_inc "could not empty bucket $b"
        aws s3api delete-bucket --bucket "$b" --region "$AWS_REGION" \
          || warn_inc "could not delete bucket $b" ;;
    esac
  done
else
  echo "no owned staging buckets found; nothing to delete."
fi

echo "== deleting owned IAM instance profiles and roles =="
if [[ "$roles" == "<could not determine>" ]]; then :
elif [[ -n "$roles" ]]; then
  for role in $roles; do
    role_owner=$(aws iam list-role-tags --role-name "$role" --query "Tags[?Key=='${TAGS_OWNER_KEY}'].Value | [0]" --output text 2>&1)
    if [[ "$role_owner" == *NoSuchEntity* ]]; then echo "role $role is already gone."; continue; fi
    [[ "$role_owner" == "$TAGS_OWNER_VALUE" ]] || { warn_inc "role $role does not carry ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} (read: $role_owner); refusing to delete it"; continue; }
    profiles=$(aws iam list-instance-profiles-for-role --role-name "$role" --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null)
    for profile in $profiles; do
      aws iam remove-role-from-instance-profile --instance-profile-name "$profile" --role-name "$role" 2>/dev/null || true
      aws iam delete-instance-profile --instance-profile-name "$profile" \
        || warn_inc "could not delete instance profile $profile"
    done
    policies=$(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null)
    for policy_arn in $policies; do
      aws iam detach-role-policy --role-name "$role" --policy-arn "$policy_arn" || warn_inc "could not detach $policy_arn from $role"
    done
    # Inline policies (the per-run staging read) block delete-role until removed.
    inline_policies=$(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null)
    for policy_name in $inline_policies; do
      aws iam delete-role-policy --role-name "$role" --policy-name "$policy_name" || warn_inc "could not delete inline policy $policy_name from $role"
    done
    aws iam delete-role --role-name "$role" \
      || warn_inc "could not delete IAM role $role"
  done
else
  echo "no owned IAM roles found; nothing to delete."
fi

echo "== verifying absence =="
owned r_instances "owned EC2 instances" list_instances
owned r_images "owned AMIs" list_images
owned r_snapshots "owned EBS snapshots" list_snapshots
owned r_sgs "owned security groups" list_sgs
owned r_lts "owned launch templates" list_lts
owned r_ng "the managed node group $NODEGROUP_NAME" nodegroup_state
[[ -z "$r_instances" ]] || warn_inc "owned instances still present after cleanup: $r_instances"
[[ -z "$r_images" ]]    || warn_inc "owned AMIs still present after cleanup: $r_images"
[[ -z "$r_snapshots" ]] || warn_inc "owned snapshots still present after cleanup: $r_snapshots"
[[ -z "$r_sgs" ]]       || warn_inc "owned security groups still present after cleanup: $r_sgs"
[[ -z "$r_lts" ]]       || warn_inc "owned launch templates still present after cleanup: $r_lts"
[[ "$r_ng" == absent ]] || warn_inc "node group $NODEGROUP_NAME still present after cleanup: $r_ng"
# Roles and buckets are confirmed directly (the tagging API lags deletions).
for role in $( [[ "$roles" == "<could not determine>" ]] || printf '%s\n' "$roles" ); do
  out=$(aws iam get-role --role-name "$role" 2>&1) && warn_inc "IAM role $role still present after cleanup" \
    || [[ "$out" == *NoSuchEntity* ]] || warn_inc "could not confirm IAM role $role is gone: $out"
done
for b in $( [[ "$buckets" == "<could not determine>" ]] || printf '%s\n' "$buckets" ); do
  st=$(bucket_state "$b") || { warn_inc "could not confirm bucket $b is gone"; continue; }
  [[ "$st" == absent ]] || warn_inc "bucket $b still present after cleanup ($st)"
done
echo "Left in place (shared, not the sample's): the vpc-cni add-on and the isolated-sandbox RuntimeClass on cluster $CLUSTER_NAME; see the README's Clean up section for how to remove the add-on."

if [[ "$incomplete" -ne 0 ]]; then
  printf '\nClean up INCOMPLETE: see the warnings above.\n' >&2
  exit 1
fi
echo
echo "Clean up complete: validation workload, node group, instances, AMIs and snapshots, launch template, security group, staging bucket, instance profile and roles are gone."
