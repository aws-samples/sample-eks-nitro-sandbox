#!/usr/bin/env bash
# Remove everything the sample created, and only that. Deletes in reverse order of
# creation, touches only resources marked ManagedBy=coding-agents-for-developers, and
# never removes a shared install (agent-sandbox, the EFS CSI driver, network-policy
# enforcement). Exits non-zero if it skipped something or could not confirm a delete.
set -uo pipefail

SAMPLE=coding-agents-for-developers
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1090
set -a; . "$ROOT/.env"; set +a

CLUSTER_NAME="${CLUSTER_NAME:?set CLUSTER_NAME}"
AWS_REGION="${AWS_REGION:?set AWS_REGION}"
NAMESPACE="${NAMESPACE:-coding-agents-for-developers}"
KCTL=(kubectl --context "$CLUSTER_NAME")
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
APP_ROLE="$SAMPLE-app"; MOUNT_ROLE="$SAMPLE-mount"; BEDROCK_ROLE="$SAMPLE-bedrock"; SYNC_ROLE="$SAMPLE-s3files-sync"
SG_NAME="$SAMPLE-nfs"
FAIL=0
say() { printf '\n==> %s\n' "$*"; }
note_fail() { echo "INCOMPLETE: $*" >&2; FAIL=1; }

# Confirm the namespace is the sample's before deleting anything inside it.
if "${KCTL[@]}" get namespace "$NAMESPACE" >/dev/null 2>&1; then
  owned="$("${KCTL[@]}" get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null || true)"
  [[ "$owned" == "$SAMPLE" ]] || { echo "namespace $NAMESPACE is not labelled for $SAMPLE; refusing." >&2; exit 2; }

  say "Warm pools first (so they stop booting replacements), then claims, then the app"
  "${KCTL[@]}" -n "$NAMESPACE" delete sandboxwarmpool -l app.kubernetes.io/part-of=$SAMPLE --ignore-not-found
  "${KCTL[@]}" -n "$NAMESPACE" delete sandboxclaim -l app.kubernetes.io/part-of=$SAMPLE --ignore-not-found
  "${KCTL[@]}" -n "$NAMESPACE" delete sandboxtemplate -l app.kubernetes.io/part-of=$SAMPLE --ignore-not-found
  "${KCTL[@]}" -n "$NAMESPACE" delete applicationnetworkpolicy -l app.kubernetes.io/part-of=$SAMPLE --ignore-not-found
  "${KCTL[@]}" -n "$NAMESPACE" delete deploy,svc -l app.kubernetes.io/part-of=$SAMPLE --ignore-not-found
fi

# Pod Identity associations (only this sample's namespace/service accounts).
say "Pod Identity associations"
for sa in agent-app agent-session; do
  aid="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --namespace "$NAMESPACE" \
    --service-account "$sa" --region "$AWS_REGION" --query 'associations[0].associationId' --output text 2>/dev/null || true)"
  [[ "$aid" == a-* ]] && aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --association-id "$aid" --region "$AWS_REGION" >/dev/null 2>&1 || true
done

# S3 Files: access points, mount targets, file system.
say "S3 Files access points, mount targets, file system"
FS_ID="${S3_FILES_FS_ID:-$(aws s3files list-file-systems --region "$AWS_REGION" \
  --query "fileSystems[?name=='$SAMPLE'].fileSystemId | [0]" --output text 2>/dev/null)}"
if [[ -n "$FS_ID" && "$FS_ID" != "None" ]]; then
  for ap in $(aws s3files list-access-points --file-system-id "$FS_ID" --region "$AWS_REGION" \
    --query 'accessPoints[].accessPointId' --output text 2>/dev/null); do
    aws s3files delete-access-point --access-point-id "$ap" --region "$AWS_REGION" >/dev/null 2>&1 || note_fail "access point $ap"
  done
  for mt in $(aws s3files list-mount-targets --file-system-id "$FS_ID" --region "$AWS_REGION" \
    --query 'mountTargets[].mountTargetId' --output text 2>/dev/null); do
    aws s3files delete-mount-target --mount-target-id "$mt" --region "$AWS_REGION" >/dev/null 2>&1 || note_fail "mount target $mt"
  done
  for i in $(seq 1 60); do
    left="$(aws s3files list-mount-targets --file-system-id "$FS_ID" --region "$AWS_REGION" --query 'length(mountTargets)' --output text 2>/dev/null || echo 0)"
    [[ "$left" == "0" ]] && break; sleep 10
  done
  aws s3files delete-file-system --file-system-id "$FS_ID" --region "$AWS_REGION" >/dev/null 2>&1 || note_fail "file system $FS_ID"
fi

# Bucket (owned by this sample: tagged ManagedBy). Re-check the tag before deleting.
say "Bucket"
if [[ -n "${S3_BUCKET_NAME:-}" ]] && aws s3api head-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  owner="$(aws s3api get-bucket-tagging --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" \
    --query "TagSet[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null || true)"
  if [[ "$owner" == "$SAMPLE" ]]; then
    aws s3 rm "s3://$S3_BUCKET_NAME" --recursive --region "$AWS_REGION" >/dev/null 2>&1 || true
    # Remove non-current versions too, then the bucket.
    aws s3api list-object-versions --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" \
      --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null \
      | aws s3api delete-objects --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --delete file:///dev/stdin >/dev/null 2>&1 || true
    aws s3api delete-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || note_fail "bucket $S3_BUCKET_NAME"
  else
    note_fail "bucket $S3_BUCKET_NAME is not tagged ManagedBy=$SAMPLE; left untouched"
  fi
fi

# IAM roles (inline policies then the role).
say "IAM roles"
for role in "$APP_ROLE" "$MOUNT_ROLE" "$BEDROCK_ROLE" "$SYNC_ROLE"; do
  for p in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$role" --policy-name "$p" >/dev/null 2>&1 || true
  done
  aws iam delete-role --role-name "$role" >/dev/null 2>&1 || true
  aws iam get-role --role-name "$role" >/dev/null 2>&1 && note_fail "IAM role $role still present"
done

# Security group (after the mount targets' ENIs are gone).
say "Security group"
VPC="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query cluster.resourcesVpcConfig.vpcId --output text 2>/dev/null || true)"
SG_ID="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
  for i in $(seq 1 30); do aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" >/dev/null 2>&1 && break; sleep 10; done
  aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$AWS_REGION" >/dev/null 2>&1 && note_fail "security group $SG_ID still present"
fi

# ECR repositories.
say "ECR repositories"
for name in base claude-code codex kiro-cli opencode pi oh-my-pi app; do
  aws ecr delete-repository --repository-name "$SAMPLE-$name" --region "$AWS_REGION" --force >/dev/null 2>&1 || true
done

# The namespace last. (On this host `kubectl delete namespace` may be blocked; if so the
# empty namespace is left for you to remove, and this is reported.)
say "Namespace"
"${KCTL[@]}" delete namespace "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 \
  || note_fail "could not delete namespace $NAMESPACE; remove it by hand: kubectl --context $CLUSTER_NAME delete namespace $NAMESPACE"

echo
if [[ "$FAIL" == "0" ]]; then
  echo "Clean up complete. Shared installs (agent-sandbox, the EFS CSI driver, network"
  echo "policy enforcement) were left in place; remove them only if nothing else uses them."
else
  echo "Clean up INCOMPLETE: see the INCOMPLETE lines above." >&2
fi
exit "$FAIL"
