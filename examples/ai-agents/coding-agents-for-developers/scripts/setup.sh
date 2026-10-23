#!/usr/bin/env bash
# Create everything the coding-agents-for-developers sample needs, end to end, and apply
# it to your cluster. Idempotent: a re-run adopts what it already made (marked
# ManagedBy=coding-agents-for-developers) instead of making a second copy.
#
#   cp ../.env.example ../.env   # fill in CLUSTER_NAME, AWS_REGION
#   ./setup.sh
#
# What it does, in order:
#   1. Check the shared installs this sample needs (agent-sandbox, the EFS CSI driver,
#      network-policy enforcement). If one is absent it STOPS with the command to add it,
#      never installing a cluster-wide thing for you.
#   2. Create the sample's own AWS resources: a versioned bucket, an S3 Files file system
#      and its mount targets, and three IAM roles (Bedrock, App, Mount) with their Pod
#      Identity associations.
#   3. Build and push the base image, the six CLI images and the app image.
#   4. Render and apply the per-CLI SandboxTemplate, SandboxWarmPool and egress policy,
#      and the app Deployment, Service and RBAC.
#   5. Print the kubectl port-forward command to open the app.
set -euo pipefail

SAMPLE=coding-agents-for-developers
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ENV_FILE="$ROOT/.env"

[[ -f "$ENV_FILE" ]] || { echo "Copy .env.example to .env and fill it in first." >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

: "${CLUSTER_NAME:?set CLUSTER_NAME in .env}"
: "${AWS_REGION:?set AWS_REGION in .env}"
NAMESPACE="${NAMESPACE:-coding-agents-for-developers}"
S3_PREFIX="${S3_PREFIX:-coding-agents}"
POOL_REPLICAS="${POOL_REPLICAS:-1}"
AGENT_CLIS="${AGENT_CLIS:-claude-code,codex,kiro-cli,opencode,pi,oh-my-pi}"
KCTL=(kubectl --context "$CLUSTER_NAME")

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
S3_BUCKET_NAME="${S3_BUCKET_NAME:-$SAMPLE-$ACCOUNT_ID-$AWS_REGION}"
APP_ROLE="$SAMPLE-app"
MOUNT_ROLE="$SAMPLE-mount"
BEDROCK_ROLE="$SAMPLE-bedrock"
SYNC_ROLE="$SAMPLE-s3files-sync"
SG_NAME="$SAMPLE-nfs"

say() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# --- 1. Shared installs: check, never change. Stop with the command if absent. ---
say "Checking shared installs (reused as they are, never changed)"
"${KCTL[@]}" get crd sandboxtemplates.extensions.agents.x-k8s.io >/dev/null 2>&1 \
  || die "agent-sandbox is not installed. Install it (as the warm-pool sample does):
  kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.6/sandbox-with-extensions.yaml"
aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-efs-csi-driver \
  --region "$AWS_REGION" --query 'addon.status' --output text >/dev/null 2>&1 \
  || die "the EFS CSI driver add-on (>= 3.0.0, for S3 Files) is not installed. See the
  storage/ebs sample's prerequisites, or:
  aws eks create-addon --cluster-name $CLUSTER_NAME --addon-name aws-efs-csi-driver --region $AWS_REGION"
npol="$("${KCTL[@]}" get configmap -n kube-system amazon-vpc-cni \
  -o jsonpath='{.data.enable-network-policy-controller}' 2>/dev/null || true)"
[[ "$npol" == "true" ]] \
  || die "network policy enforcement is off. Turn it on once per cluster:
  kubectl apply -f ../../getting-started/coding-agent/enable-network-policy.yaml"

# The EFS CSI node role needs ClientMount on this file system AND the ability to let the
# app's per-session credential mount: on this cluster the mount uses the credential the
# pod supplies (see the README). We do not touch the shared CSI role here.

# --- 2. AWS resources the sample owns ---
# Reuse only what this sample created. For a resource that already exists, confirm it
# carries ManagedBy=$SAMPLE before adopting it, and stop otherwise, so a re-run never
# retags or reconfigures something another demo owns that happens to share the name.
say "Bucket $S3_BUCKET_NAME"
if aws s3api head-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  owner="$(aws s3api get-bucket-tagging --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" \
    --query "TagSet[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null || true)"
  [[ "$owner" == "$SAMPLE" ]] || die "bucket $S3_BUCKET_NAME exists but is not tagged ManagedBy=$SAMPLE (found: ${owner:-none}); refusing to adopt it"
else
  aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
fi
aws s3api put-bucket-tagging --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" \
  --tagging "TagSet=[{Key=ManagedBy,Value=$SAMPLE},{Key=auto-delete,Value=no}]"
aws s3api put-bucket-versioning --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

say "IAM roles (Bedrock, App, Mount) and the S3 Files sync role"
mk_role() { # name  trust-json-file
  if aws iam get-role --role-name "$1" >/dev/null 2>&1; then
    # Exists already: adopt only if it is the sample's. A same-named role from another
    # owner must not be reused (its trust policy and permissions would be rewritten below).
    owner="$(aws iam list-role-tags --role-name "$1" \
      --query "Tags[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null || true)"
    [[ "$owner" == "$SAMPLE" ]] || die "IAM role $1 exists but is not tagged ManagedBy=$SAMPLE (found: ${owner:-none}); refusing to adopt it"
  else
    aws iam create-role --role-name "$1" --assume-role-policy-document "file://$2" \
      --tags Key=ManagedBy,Value=$SAMPLE Key=auto-delete,Value=no >/dev/null
  fi
}
render() { sed -e "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" -e "s|<AWS_REGION>|$AWS_REGION|g" \
  -e "s|<S3_FILES_FS_ID>|${S3_FILES_FS_ID:-PENDING}|g" -e "s|<S3_BUCKET_NAME>|$S3_BUCKET_NAME|g" \
  -e "s|<S3_PREFIX>|$S3_PREFIX|g" -e "s|<APP_ROLE_NAME>|$APP_ROLE|g" \
  -e "s|<MOUNT_ROLE_NAME>|$MOUNT_ROLE|g" "$1"; }

# Sync role (assumed by the S3 Files service to move data to/from the bucket).
cat > /tmp/$SAMPLE-sync-trust.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"elasticfilesystem.amazonaws.com"},"Action":"sts:AssumeRole","Condition":{"StringEquals":{"aws:SourceAccount":"$ACCOUNT_ID"},"ArnLike":{"aws:SourceArn":"arn:aws:s3files:$AWS_REGION:$ACCOUNT_ID:file-system/*"}}}]}
EOF
mk_role "$SYNC_ROLE" /tmp/$SAMPLE-sync-trust.json
cat > /tmp/$SAMPLE-sync-perm.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:ListBucket","s3:ListBucketVersions"],"Resource":"arn:aws:s3:::$S3_BUCKET_NAME","Condition":{"StringEquals":{"aws:ResourceAccount":"$ACCOUNT_ID"}}},
 {"Effect":"Allow","Action":["s3:AbortMultipartUpload","s3:DeleteObject*","s3:GetObject*","s3:List*","s3:PutObject*"],"Resource":"arn:aws:s3:::$S3_BUCKET_NAME/*","Condition":{"StringEquals":{"aws:ResourceAccount":"$ACCOUNT_ID"}}},
 {"Effect":"Allow","Action":["events:DeleteRule","events:DisableRule","events:EnableRule","events:PutRule","events:PutTargets","events:RemoveTargets"],"Condition":{"StringEquals":{"events:ManagedBy":"elasticfilesystem.amazonaws.com"}},"Resource":["arn:aws:events:*:*:rule/DO-NOT-DELETE-S3-Files*"]},
 {"Effect":"Allow","Action":["events:DescribeRule","events:ListRuleNamesByTarget","events:ListRules","events:ListTargetsByRule"],"Resource":["arn:aws:events:*:*:rule/*"]}
]}
EOF
aws iam put-role-policy --role-name "$SYNC_ROLE" --policy-name sync --policy-document file:///tmp/$SAMPLE-sync-perm.json
SYNC_ROLE_ARN="$(aws iam get-role --role-name "$SYNC_ROLE" --query Role.Arn --output text)"

# Bedrock and App roles trust EKS Pod Identity. The Bedrock policy is rendered (it scopes
# model invocation to this account's inference profiles and foundation models), so pass it
# through render() like the others rather than attaching the raw file.
mk_role "$BEDROCK_ROLE" "$ROOT/iam/pod-identity-trust.json"
render "$ROOT/iam/bedrock-invoke-policy.json" > /tmp/$SAMPLE-bedrock-perm.json
aws iam put-role-policy --role-name "$BEDROCK_ROLE" --policy-name bedrock \
  --policy-document file:///tmp/$SAMPLE-bedrock-perm.json
mk_role "$APP_ROLE" "$ROOT/iam/pod-identity-trust.json"

# --- S3 Files file system, mount targets, security group ---
say "Security group (NFS 2049 from the cluster security group)"
VPC="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query cluster.resourcesVpcConfig.vpcId --output text)"
CLUSTER_SG="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)"
# Find only THIS sample's security group: filter on the ManagedBy tag as well as the name,
# so a same-named group another demo owns in this VPC is not adopted. If one exists by name
# without our tag, the create below fails on the duplicate name, which is the right outcome.
SG_ID="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=$SG_NAME" "Name=tag:ManagedBy,Values=$SAMPLE" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  SG_ID="$(aws ec2 create-security-group --group-name "$SG_NAME" \
    --description "NFS 2049 from cluster SG for $SAMPLE" --vpc-id "$VPC" --region "$AWS_REGION" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=ManagedBy,Value=$SAMPLE},{Key=auto-delete,Value=no}]" \
    --query GroupId --output text)" \
    || die "could not create security group $SG_NAME (a group with this name may already exist in $VPC under another owner)"
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 2049 \
    --source-group "$CLUSTER_SG" --region "$AWS_REGION" >/dev/null
fi

say "S3 Files file system"
S3_FILES_FS_ID="$(aws s3files list-file-systems --region "$AWS_REGION" \
  --query "fileSystems[?name=='$SAMPLE'].fileSystemId | [0]" --output text 2>/dev/null || true)"
if [[ "$S3_FILES_FS_ID" != "None" && -n "$S3_FILES_FS_ID" ]]; then
  # Found a file system with the sample's name: adopt it only if it carries our tag.
  fs_owner="$(aws s3files list-tags-for-resource --resource-id "$S3_FILES_FS_ID" --region "$AWS_REGION" \
    --query "tags[?key=='ManagedBy'].value | [0]" --output text 2>/dev/null || true)"
  [[ "$fs_owner" == "$SAMPLE" ]] || die "file system $S3_FILES_FS_ID is named $SAMPLE but not tagged ManagedBy=$SAMPLE (found: ${fs_owner:-none}); refusing to adopt it"
fi
if [[ "$S3_FILES_FS_ID" == "None" || -z "$S3_FILES_FS_ID" ]]; then
  S3_FILES_FS_ID="$(aws s3files create-file-system --region "$AWS_REGION" \
    --bucket "arn:aws:s3:::$S3_BUCKET_NAME" --prefix "$S3_PREFIX/" --role-arn "$SYNC_ROLE_ARN" \
    --accept-bucket-warning \
    --tags key=Name,value=$SAMPLE key=ManagedBy,value=$SAMPLE key=auto-delete,value=no \
    --query fileSystemId --output text)"
fi
fs_status=""
for i in $(seq 1 90); do
  fs_status="$(aws s3files get-file-system --file-system-id "$S3_FILES_FS_ID" --region "$AWS_REGION" --query status --output text)"
  [[ "${fs_status^^}" == "AVAILABLE" ]] && break; [[ "${fs_status^^}" == "ERROR" ]] && die "file system ERROR"; sleep 5
done
# Do not proceed on a file system that never became available: the mount targets and every
# later step depend on it.
[[ "${fs_status^^}" == "AVAILABLE" ]] || die "file system $S3_FILES_FS_ID did not become AVAILABLE (last status: ${fs_status:-unknown})"

say "Mount targets, one per cluster subnet"
for subnet in $(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.subnetIds' --output text); do
  have="$(aws s3files list-mount-targets --file-system-id "$S3_FILES_FS_ID" --region "$AWS_REGION" \
    --query "mountTargets[?subnetId=='$subnet'].mountTargetId | [0]" --output text 2>/dev/null || true)"
  [[ "$have" == "None" || -z "$have" ]] && aws s3files create-mount-target \
    --file-system-id "$S3_FILES_FS_ID" --subnet-id "$subnet" --security-groups "$SG_ID" --region "$AWS_REGION" >/dev/null
done
pending=1
for i in $(seq 1 90); do
  pending="$(aws s3files list-mount-targets --file-system-id "$S3_FILES_FS_ID" --region "$AWS_REGION" \
    --query "length(mountTargets[?status!='available'])" --output text 2>/dev/null || echo 1)"
  [[ "$pending" == "0" ]] && break; sleep 10
done
# Do not proceed until every mount target is available: the egress policy's
# <MOUNT_TARGET_CIDRS> and every session's mount depend on them. A lookup failure above
# leaves pending=1, which this also catches.
[[ "$pending" == "0" ]] || die "mount targets for $S3_FILES_FS_ID did not all become available ($pending not available / lookup failed)"

# Now that the file system id is known, attach the App and Mount policies and the Mount
# trust (which names the App role).
say "App and Mount policies"
render "$ROOT/iam/app-policy.json" > /tmp/$SAMPLE-app-perm.json
aws iam put-role-policy --role-name "$APP_ROLE" --policy-name app --policy-document file:///tmp/$SAMPLE-app-perm.json
render "$ROOT/iam/mount-trust.json" > /tmp/$SAMPLE-mount-trust.json
mk_role "$MOUNT_ROLE" /tmp/$SAMPLE-mount-trust.json
aws iam update-assume-role-policy --role-name "$MOUNT_ROLE" --policy-document file:///tmp/$SAMPLE-mount-trust.json
render "$ROOT/iam/mount-policy.json" > /tmp/$SAMPLE-mount-perm.json
aws iam put-role-policy --role-name "$MOUNT_ROLE" --policy-name mount --policy-document file:///tmp/$SAMPLE-mount-perm.json
MOUNT_ROLE_ARN="$(aws iam get-role --role-name "$MOUNT_ROLE" --query Role.Arn --output text)"

# --- Namespace, service accounts, Pod Identity associations ---
say "Namespace $NAMESPACE"
# Create the namespace only when absent; applying over an existing one counts as adopting
# it. If it already exists, it must either be unlabelled (a fresh namespace we are about to
# claim) or already carry our part-of label -- never another demo's label, which we would
# otherwise overwrite and then delete on clean up.
if "${KCTL[@]}" get namespace "$NAMESPACE" >/dev/null 2>&1; then
  # The namespace already exists: adopt it ONLY if it already carries our part-of label.
  # An existing namespace -- even an unlabelled one -- is not one we are "about to create",
  # so we do not claim it: it may belong to another demo that simply did not label it, and
  # the clean up deletes whatever carries our label. Create-only-when-absent (AGENTS.md).
  ns_owner="$("${KCTL[@]}" get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null || true)"
  [[ "$ns_owner" == "$SAMPLE" ]] \
    || die "namespace $NAMESPACE already exists and is not labelled app.kubernetes.io/part-of=$SAMPLE (found: ${ns_owner:-none}); refusing to adopt it"
else
  "${KCTL[@]}" create namespace "$NAMESPACE"
fi
"${KCTL[@]}" label namespace "$NAMESPACE" app.kubernetes.io/part-of=$SAMPLE --overwrite >/dev/null
sed "s|<NAMESPACE>|$NAMESPACE|g" "$ROOT/deploy/rbac.yaml" | "${KCTL[@]}" apply -n "$NAMESPACE" -f -

assoc() { # service-account  role-arn
  aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --namespace "$NAMESPACE" \
    --service-account "$1" --region "$AWS_REGION" --query 'associations[0].associationId' --output text 2>/dev/null \
    | grep -q '^a-' || aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" --service-account "$1" --role-arn "$2" --region "$AWS_REGION" >/dev/null
}
say "Pod Identity associations"
assoc agent-app "$(aws iam get-role --role-name "$APP_ROLE" --query Role.Arn --output text)"
assoc agent-session "$(aws iam get-role --role-name "$BEDROCK_ROLE" --query Role.Arn --output text)"

# --- 3. Images ---
say "Build and push images"
"$HERE/build-images.sh"

# --- 4. Apply per-CLI templates/pools/policies and the app ---
say "Apply SandboxTemplates, warm pools, egress policies"

# Resolve this file system's mount-target IPs and render them as one /32 ipBlock each, so
# the NFS (2049) egress rule is scoped to the sample's own mount targets rather than to the
# whole VPC. Stop if none resolve: an empty block would leave the pods unable to mount.
mt_ips="$(aws s3files list-mount-targets --file-system-id "$S3_FILES_FS_ID" --region "$AWS_REGION" \
  --query 'mountTargets[].ipv4Address' --output text 2>/dev/null || true)"
[ -n "$mt_ips" ] || die "could not resolve mount-target IPs for $S3_FILES_FS_ID"
mount_target_cidrs=""
for ip in $mt_ips; do
  mount_target_cidrs="${mount_target_cidrs}        - ipBlock: { cidr: ${ip}/32 }
"
done

# kiro-cli alone reaches its Kiro / Amazon Q Developer sign-in and the CodeWhisperer
# streaming service instead of Amazon Bedrock. Those endpoints live in the developer's Kiro
# Region (independent of this cluster's Region), so allow *.amazonaws.com on 443 for the
# kiro-cli pods only -- wide within AWS, still AWS-only. Other CLIs get an empty block.
kiro_cli_egress() {
  cat <<'EGRESS'
    - to:
        - domainNames:
            - "*.amazonaws.com"
            - "*.kiro.dev"
      ports:
        - { protocol: TCP, port: 443 }
EGRESS
}
IFS=',' read -ra clis <<< "$AGENT_CLIS"
for cli in "${clis[@]}"; do
  sed -e "s|<CLI>|$cli|g" -e "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" -e "s|<AWS_REGION>|$AWS_REGION|g" \
      -e "s|<POOL_REPLICAS>|$POOL_REPLICAS|g" "$ROOT/deploy/sandbox-template.yaml" \
    | "${KCTL[@]}" apply -n "$NAMESPACE" -f -
  # Fill the <KIRO_CLI_EGRESS> and <MOUNT_TARGET_CIDRS> placeholder lines. awk keeps each
  # multi-line block's indentation, which a sed substitution would mangle. Match each
  # placeholder only as a whole line (^<...>$) so a comment that mentions the name by text
  # is left untouched. <MOUNT_TARGET_CIDRS> must always be non-empty (checked above).
  if [ "$cli" = "kiro-cli" ]; then extra="$(kiro_cli_egress)"; else extra=""; fi
  awk -v repl="$extra" -v mtc="$mount_target_cidrs" '
      /^<KIRO_CLI_EGRESS>$/   { if (repl != "") printf "%s", repl ORS; next }
      /^<MOUNT_TARGET_CIDRS>$/ { printf "%s", mtc; next }
      { print }' \
      "$ROOT/deploy/egress-policy.yaml" \
    | sed -e "s|<CLI>|$cli|g" -e "s|<AWS_REGION>|$AWS_REGION|g" \
    | "${KCTL[@]}" apply -n "$NAMESPACE" -f -
done

say "Apply the app"
sed -e "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" -e "s|<AWS_REGION>|$AWS_REGION|g" -e "s|<NAMESPACE>|$NAMESPACE|g" \
    -e "s|<S3_FILES_FS_ID>|$S3_FILES_FS_ID|g" -e "s|<S3_BUCKET_NAME>|$S3_BUCKET_NAME|g" \
    -e "s|<S3_PREFIX>|$S3_PREFIX|g" -e "s|<MOUNT_ROLE_ARN>|$MOUNT_ROLE_ARN|g" \
    -e "s|<AGENT_CLIS>|$AGENT_CLIS|g" "$ROOT/deploy/app.yaml" | "${KCTL[@]}" apply -n "$NAMESPACE" -f -

# Record the resource ids back into .env for clean.sh and re-runs.
{ echo "ACCOUNT_ID=$ACCOUNT_ID"; echo "S3_FILES_FS_ID=$S3_FILES_FS_ID"; echo "S3_BUCKET_NAME=$S3_BUCKET_NAME"; } >> "$ENV_FILE"

say "Wait for the warm pools, then open the app"
for cli in "${clis[@]}"; do
  "${KCTL[@]}" -n "$NAMESPACE" wait sandboxwarmpool/agent-$cli \
    --for=jsonpath='{.status.readyReplicas}'=$POOL_REPLICAS --timeout=600s || true
done
"${KCTL[@]}" -n "$NAMESPACE" rollout status deploy/agent-app
cat <<EOF

Done. Open the app on your machine:

  kubectl --context $CLUSTER_NAME -n $NAMESPACE port-forward svc/agent-app 8080:8080

Then browse to http://127.0.0.1:8080
EOF
