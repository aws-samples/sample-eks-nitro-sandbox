#!/usr/bin/env bash
# ib-prereqs.sh: create (up) or remove (down) AWS prerequisites for Image Builder builds.
# Creates security group, IAM roles, log bucket, launch template, and ASG with capacity 1.
# All named al2023-ami-ib-<arch>-<RUN_ID>, tagged ManagedBy=al2023-ami, RunId=<RUN_ID>, auto-delete=no.
#
# Usage:  RUN_ID=<id> NODE_ARCH=<amd64|arm64> BUILD_SUBNET_ID=<subnet> BUILD_VPC_ID=<vpc> ./scripts/ib-prereqs.sh up
#         RUN_ID=<id> NODE_ARCH=<amd64|arm64> ./scripts/ib-prereqs.sh down
# Up needs BUILD_SUBNET_ID (private with NAT), BUILD_VPC_ID, KUBERNETES_VERSION (e.g. 1.37).
# Down removes only this run's tags. Failed lookup = exit 1. Host-blocked deletes -> tmp/ script.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

MODE="${1:-}"; [ "$MODE" = up ] || [ "$MODE" = down ] || die "usage: $0 <up|down>"
require_run_id; derive_run_names; : "${AWS_REGION:?}"

IB_PREFIX="al2023-ami-ib-${NODE_ARCH}-${RUN_ID}"
SG_NAME="${IB_PREFIX}-sg"; INSTANCE_ROLE_NAME="${IB_PREFIX}-role"; INSTANCE_PROFILE_NAME="${IB_PREFIX}-profile"
EXECUTION_ROLE_NAME="${IB_PREFIX}-exec-role"; BUCKET_NAME=""; LT_IB_NAME="${IB_PREFIX}-lt"; ASG_NAME="${IB_PREFIX}-asg"
REMAINING="$RUN_STATE_DIR/ib-teardown-remaining.sh"; incomplete=0

act() { log "$1"; shift; "$@" || { warn "step failed: $*"; incomplete=1; return 1; }; }
note_blocked() { printf '%s\n' "$1" >> "$REMAINING"; incomplete=1; warn "not deleted; in $REMAINING: $1"; }
probe() { local nf="$1" err; shift; err=$(mktemp); if PROBE_OUT=$("$@" 2>"$err"); then
  case "$PROBE_OUT" in null|""|"[]") rm -f "$err"; return 1 ;; esac; rm -f "$err"; return 0; fi
  if grep -Eq "$nf" "$err"; then rm -f "$err"; return 1; fi
  warn "could not determine ($*): $(head -n 2 "$err")"; rm -f "$err"; incomplete=1; return 2; }
jfield() { python3 -c 'import json,sys; d=json.load(sys.stdin); r=eval(sys.argv[1], {"d": d}); print(json.dumps(r) if r is not None else "")' "$1"; }

case "$NODE_ARCH" in amd64) SSM_ARCH=x86_64; BUILD_INSTANCE_TYPE=m8i.4xlarge ;;
  arm64) SSM_ARCH=arm64; BUILD_INSTANCE_TYPE=m8g.4xlarge ;; *) die "NODE_ARCH=$NODE_ARCH invalid" ;; esac

# =============================================================================
# UP: create prerequisites
# =============================================================================
if [ "$MODE" = up ]; then
  : "${BUILD_SUBNET_ID:?set BUILD_SUBNET_ID to a private subnet with NAT}"
  : "${BUILD_VPC_ID:?set BUILD_VPC_ID to the VPC containing BUILD_SUBNET_ID}"
  : "${KUBERNETES_VERSION:?set KUBERNETES_VERSION (e.g. 1.37)}"

  [[ "$KUBERNETES_VERSION" =~ ^1\.[0-9]{2}$ ]] || die "KUBERNETES_VERSION must look like 1.36, got '$KUBERNETES_VERSION'"

  # Get current account ID for bucket name
  ACCOUNT_ID=$(aws --profile eks-sandbox --region "$AWS_REGION" sts get-caller-identity --query Account --output text) \
    || die "could not read account ID"
  BUCKET_NAME="al2023-ami-ib-logs-${ACCOUNT_ID}"

  log "Creating Image Builder prerequisites for ${NODE_ARCH} (run $RUN_ID)"
  log "  Region: $AWS_REGION"
  log "  VPC: $BUILD_VPC_ID"
  log "  Subnet: $BUILD_SUBNET_ID (must be private with NAT)"
  log "  Instance type: $BUILD_INSTANCE_TYPE"

  # Resolve EKS-optimized AL2023 base AMI
  log "Resolving EKS-optimized AL2023 $SSM_ARCH base AMI for Kubernetes $KUBERNETES_VERSION"
  SSM_PARAM="/aws/service/eks/optimized-ami/${KUBERNETES_VERSION}/amazon-linux-2023/${SSM_ARCH}/standard/recommended/image_id"
  BASE_AMI=$(aws --profile eks-sandbox --region "$AWS_REGION" ssm get-parameter \
    --name "$SSM_PARAM" --query Parameter.Value --output text) \
    || die "could not resolve base AMI from SSM parameter $SSM_PARAM"
  [[ "$BASE_AMI" =~ ^ami-[0-9a-f]+$ ]] || die "SSM parameter returned '$BASE_AMI', not an AMI ID"
  log "  Base AMI: $BASE_AMI"

  # --- Security Group ---
  log "Creating security group $SG_NAME"
  probe 'InvalidGroup.NotFound' aws --profile eks-sandbox --region "$AWS_REGION" ec2 describe-security-groups \
    --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$BUILD_VPC_ID" \
    --query 'SecurityGroups[0]' --output json
  case $? in
    0) if printf '%s' "$PROBE_OUT" | jfield 'd.get("Tags") or []' | tags_match; then
         SG_ID=$(printf '%s' "$PROBE_OUT" | json_get 'd["GroupId"]')
         log "  Security group $SG_NAME already exists: $SG_ID (this run's)"
       else
         die "security group $SG_NAME exists but is not tagged for run $RUN_ID; refusing to reuse"
       fi ;;
    1) SG_ID=$(aws --profile eks-sandbox --region "$AWS_REGION" ec2 create-security-group \
         --group-name "$SG_NAME" \
         --description "Security group for Image Builder build instance (${NODE_ARCH}, run $RUN_ID)" \
         --vpc-id "$BUILD_VPC_ID" \
         --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=$TAGS_OWNER_KEY,Value=$TAGS_OWNER_VALUE},{Key=$TAGS_RUN_KEY,Value=$RUN_ID},{Key=auto-delete,Value=no}]" \
         --query 'GroupId' --output text) || die "could not create security group"
       log "  Created security group: $SG_ID"
       # Egress: HTTPS only (for SSM, S3, yum repos). SSM via VPC endpoints needs port 443 too.
       aws --profile eks-sandbox --region "$AWS_REGION" ec2 authorize-security-group-egress \
         --group-id "$SG_ID" \
         --ip-permissions IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges='[{CidrIp=0.0.0.0/0,Description="HTTPS"}]' \
         || warn "could not add egress rule (may already have default)"
       ;;
    *) die "could not check for existing security group" ;;
  esac

  # --- Instance IAM Role + Profile ---
  log "Creating IAM role $INSTANCE_ROLE_NAME"
  probe 'NoSuchEntity' aws --profile eks-sandbox iam get-role --role-name "$INSTANCE_ROLE_NAME" --query 'Role.Tags' --output json
  case $? in
    0) if printf '%s' "$PROBE_OUT" | tags_match; then
         log "  IAM role $INSTANCE_ROLE_NAME already exists (this run's)"
       else
         die "IAM role $INSTANCE_ROLE_NAME exists but is not tagged for run $RUN_ID; refusing to reuse"
       fi ;;
    1) TRUST_POLICY=$(mktemp)
       cat > "$TRUST_POLICY" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
       aws --profile eks-sandbox iam create-role \
         --role-name "$INSTANCE_ROLE_NAME" \
         --assume-role-policy-document "file://$TRUST_POLICY" \
         --description "Instance role for Image Builder build ($NODE_ARCH, run $RUN_ID)" \
         --tags "Key=$TAGS_OWNER_KEY,Value=$TAGS_OWNER_VALUE" "Key=$TAGS_RUN_KEY,Value=$RUN_ID" "Key=auto-delete,Value=no" \
         || die "could not create IAM role"
       rm -f "$TRUST_POLICY"
       log "  Created IAM role: $INSTANCE_ROLE_NAME"

       # Attach managed policies
       aws --profile eks-sandbox iam attach-role-policy \
         --role-name "$INSTANCE_ROLE_NAME" \
         --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
         || die "could not attach SSM policy"
       aws --profile eks-sandbox iam attach-role-policy \
         --role-name "$INSTANCE_ROLE_NAME" \
         --policy-arn arn:aws:iam::aws:policy/EC2InstanceProfileForImageBuilder \
         || die "could not attach ImageBuilder policy"

       # Inline policy for S3 read on amazon-eks bundle
       S3_POLICY=$(mktemp)
       cat > "$S3_POLICY" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:ListBucket"],
    "Resource": ["arn:aws:s3:::amazon-eks", "arn:aws:s3:::amazon-eks/*"]
  }]
}
EOF
       aws --profile eks-sandbox iam put-role-policy \
         --role-name "$INSTANCE_ROLE_NAME" \
         --policy-name S3ReadAmazonEKS \
         --policy-document "file://$S3_POLICY" \
         || die "could not add S3 policy"
       rm -f "$S3_POLICY"
       ;;
    *) die "could not check for existing IAM role" ;;
  esac

  log "Creating instance profile $INSTANCE_PROFILE_NAME"
  probe 'NoSuchEntity' aws --profile eks-sandbox iam get-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" --query 'InstanceProfile.Tags' --output json
  case $? in
    0) if printf '%s' "$PROBE_OUT" | tags_match; then
         log "  Instance profile $INSTANCE_PROFILE_NAME already exists (this run's)"
       else
         die "instance profile $INSTANCE_PROFILE_NAME exists but is not tagged for run $RUN_ID; refusing to reuse"
       fi ;;
    1) aws --profile eks-sandbox iam create-instance-profile \
         --instance-profile-name "$INSTANCE_PROFILE_NAME" \
         --tags "Key=$TAGS_OWNER_KEY,Value=$TAGS_OWNER_VALUE" "Key=$TAGS_RUN_KEY,Value=$RUN_ID" "Key=auto-delete,Value=no" \
         || die "could not create instance profile"
       log "  Created instance profile: $INSTANCE_PROFILE_NAME"
       aws --profile eks-sandbox iam add-role-to-instance-profile \
         --instance-profile-name "$INSTANCE_PROFILE_NAME" \
         --role-name "$INSTANCE_ROLE_NAME" \
         || die "could not add role to instance profile"
       # Wait for instance profile propagation
       sleep 10
       ;;
    *) die "could not check for existing instance profile" ;;
  esac

  # --- S3 Bucket for Logs ---
  log "Creating S3 bucket $BUCKET_NAME"
  probe 'NoSuchBucket' aws --profile eks-sandbox --region "$AWS_REGION" s3api head-bucket --bucket "$BUCKET_NAME"
  case $? in
    0) log "  S3 bucket $BUCKET_NAME already exists" ;;
    1) if [ "$AWS_REGION" = us-east-1 ]; then
         aws --profile eks-sandbox --region "$AWS_REGION" s3api create-bucket \
           --bucket "$BUCKET_NAME" \
           || die "could not create S3 bucket"
       else
         aws --profile eks-sandbox --region "$AWS_REGION" s3api create-bucket \
           --bucket "$BUCKET_NAME" \
           --create-bucket-configuration LocationConstraint="$AWS_REGION" \
           || die "could not create S3 bucket"
       fi
       log "  Created S3 bucket: $BUCKET_NAME"
       aws --profile eks-sandbox --region "$AWS_REGION" s3api put-bucket-tagging \
         --bucket "$BUCKET_NAME" \
         --tagging "TagSet=[{Key=$TAGS_OWNER_KEY,Value=$TAGS_OWNER_VALUE},{Key=$TAGS_RUN_KEY,Value=$RUN_ID},{Key=auto-delete,Value=no}]" \
         || warn "could not tag S3 bucket"
       aws --profile eks-sandbox --region "$AWS_REGION" s3api put-public-access-block \
         --bucket "$BUCKET_NAME" \
         --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
         || warn "could not set public access block"
       ;;
    *) die "could not check for existing S3 bucket" ;;
  esac

  # --- Execution Role (for Image Builder to manage ASG) ---
  log "Creating execution role $EXECUTION_ROLE_NAME"
  probe 'NoSuchEntity' aws --profile eks-sandbox iam get-role --role-name "$EXECUTION_ROLE_NAME" --query 'Role.Tags' --output json
  case $? in
    0) if printf '%s' "$PROBE_OUT" | tags_match; then
         log "  Execution role $EXECUTION_ROLE_NAME already exists (this run's)"
       else
         die "execution role $EXECUTION_ROLE_NAME exists but is not tagged for run $RUN_ID; refusing to reuse"
       fi ;;
    1) EXEC_TRUST=$(mktemp)
       cat > "$EXEC_TRUST" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "imagebuilder.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
       aws --profile eks-sandbox iam create-role \
         --role-name "$EXECUTION_ROLE_NAME" \
         --assume-role-policy-document "file://$EXEC_TRUST" \
         --description "Execution role for Image Builder ASG management ($NODE_ARCH, run $RUN_ID)" \
         --tags "Key=$TAGS_OWNER_KEY,Value=$TAGS_OWNER_VALUE" "Key=$TAGS_RUN_KEY,Value=$RUN_ID" "Key=auto-delete,Value=no" \
         || die "could not create execution role"
       rm -f "$EXEC_TRUST"
       log "  Created execution role: $EXECUTION_ROLE_NAME"

       # Attach EC2ImageBuilderExecutionPolicy
       aws --profile eks-sandbox iam attach-role-policy \
         --role-name "$EXECUTION_ROLE_NAME" \
         --policy-arn arn:aws:iam::aws:policy/service-role/EC2ImageBuilderExecutionPolicy \
         || die "could not attach EC2ImageBuilderExecutionPolicy"

       # Inline policy for ASG management (scoped to this ASG only)
       ASG_POLICY=$(mktemp)
       cat > "$ASG_POLICY" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TagInstanceInASG",
      "Effect": "Allow",
      "Action": ["ec2:CreateTags", "ec2:DeleteTags"],
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "StringEquals": {
          "ec2:ResourceTag/aws:autoscaling:groupName": "$ASG_NAME"
        }
      }
    },
    {
      "Sid": "DescribeASG",
      "Effect": "Allow",
      "Action": "autoscaling:DescribeAutoScalingGroups",
      "Resource": "*"
    },
    {
      "Sid": "DetachFromASG",
      "Effect": "Allow",
      "Action": "autoscaling:DetachInstances",
      "Resource": "arn:aws:autoscaling:*:*:autoScalingGroup:*:autoScalingGroupName/$ASG_NAME"
    }
  ]
}
EOF
       aws --profile eks-sandbox iam put-role-policy \
         --role-name "$EXECUTION_ROLE_NAME" \
         --policy-name ASGManagement \
         --policy-document "file://$ASG_POLICY" \
         || die "could not add ASG management policy"
       rm -f "$ASG_POLICY"
       ;;
    *) die "could not check for existing execution role" ;;
  esac

  # --- Launch Template ---
  log "Creating launch template $LT_IB_NAME"
  probe 'InvalidLaunchTemplateName.NotFoundException' aws --profile eks-sandbox --region "$AWS_REGION" ec2 describe-launch-templates \
    --launch-template-names "$LT_IB_NAME" --query 'LaunchTemplates[0]' --output json
  case $? in
    0) if printf '%s' "$PROBE_OUT" | jfield 'd.get("Tags") or []' | tags_match; then
         log "  Launch template $LT_IB_NAME already exists (this run's)"
       else
         die "launch template $LT_IB_NAME exists but is not tagged for run $RUN_ID; refusing to reuse"
       fi ;;
    1) LT_DATA=$(mktemp)
       cat > "$LT_DATA" <<EOF
{
  "ImageId": "$BASE_AMI",
  "InstanceType": "$BUILD_INSTANCE_TYPE",
  "IamInstanceProfile": {
    "Name": "$INSTANCE_PROFILE_NAME"
  },
  "NetworkInterfaces": [{
    "DeviceIndex": 0,
    "AssociatePublicIpAddress": false,
    "Groups": ["$SG_ID"],
    "SubnetId": "$BUILD_SUBNET_ID"
  }],
  "MetadataOptions": {
    "HttpTokens": "required",
    "HttpPutResponseHopLimit": 1
  },
  "EnclaveOptions": {
    "Enabled": true
  },
  "TagSpecifications": [{
    "ResourceType": "instance",
    "Tags": [
      {"Key": "Name", "Value": "al2023-ami-ib-$NODE_ARCH-build"},
      {"Key": "$TAGS_OWNER_KEY", "Value": "$TAGS_OWNER_VALUE"},
      {"Key": "$TAGS_RUN_KEY", "Value": "$RUN_ID"},
      {"Key": "auto-delete", "Value": "no"}
    ]
  }]
}
EOF
       aws --profile eks-sandbox --region "$AWS_REGION" ec2 create-launch-template \
         --launch-template-name "$LT_IB_NAME" \
         --launch-template-data "file://$LT_DATA" \
         --tag-specifications "ResourceType=launch-template,Tags=[{Key=$TAGS_OWNER_KEY,Value=$TAGS_OWNER_VALUE},{Key=$TAGS_RUN_KEY,Value=$RUN_ID},{Key=auto-delete,Value=no}]" \
         > /dev/null || die "could not create launch template"
       rm -f "$LT_DATA"
       log "  Created launch template: $LT_IB_NAME"
       ;;
    *) die "could not check for existing launch template" ;;
  esac

  # --- Auto Scaling Group at capacity 1 ---
  log "Creating Auto Scaling Group $ASG_NAME at desired capacity 1"
  probe 'ValidationError.*does not exist' aws --profile eks-sandbox --region "$AWS_REGION" autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" --query 'AutoScalingGroups[0].Tags' --output json
  case $? in
    0) if printf '%s' "$PROBE_OUT" | python3 -c '
import json,sys
tags=json.load(sys.stdin) or []
d={t["Key"]:t["Value"] for t in tags}
sys.exit(0 if d.get("'$TAGS_OWNER_KEY'")=="'$TAGS_OWNER_VALUE'" and d.get("'$TAGS_RUN_KEY'")=="'$RUN_ID'" else 1)
'; then
         log "  Auto Scaling Group $ASG_NAME already exists (this run's)"
       else
         die "ASG $ASG_NAME exists but is not tagged for run $RUN_ID; refusing to reuse"
       fi ;;
    1) aws --profile eks-sandbox --region "$AWS_REGION" autoscaling create-auto-scaling-group \
         --auto-scaling-group-name "$ASG_NAME" \
         --launch-template "LaunchTemplateName=$LT_IB_NAME" \
         --min-size 1 \
         --max-size 2 \
         --desired-capacity 1 \
         --vpc-zone-identifier "$BUILD_SUBNET_ID" \
         --tags "Key=$TAGS_OWNER_KEY,Value=$TAGS_OWNER_VALUE,PropagateAtLaunch=true" \
                "Key=$TAGS_RUN_KEY,Value=$RUN_ID,PropagateAtLaunch=true" \
                "Key=auto-delete,Value=no,PropagateAtLaunch=true" \
         || die "could not create Auto Scaling Group"
       log "  Created ASG: $ASG_NAME (min 1, max 2, desired 1)"
       ;;
    *) die "could not check for existing ASG" ;;
  esac

  # --- Wait for instance to be InService and online in SSM ---
  log "Waiting for ASG instance to be InService..."
  WAIT_TIMEOUT=900 # 15 minutes
  WAIT_START=$(date +%s)
  INSTANCE_ID=""
  while true; do
    ELAPSED=$(($(date +%s) - WAIT_START))
    [ "$ELAPSED" -lt "$WAIT_TIMEOUT" ] || die "timeout waiting for ASG instance to become InService (${WAIT_TIMEOUT}s)"

    INSTANCE_ID=$(aws --profile eks-sandbox --region "$AWS_REGION" autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId | [0]' \
      --output text 2>/dev/null || echo "")

    if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
      log "  Instance $INSTANCE_ID is InService"
      break
    fi
    sleep 10
  done

  log "Waiting for SSM agent to come online..."
  WAIT_START=$(date +%s)
  while true; do
    ELAPSED=$(($(date +%s) - WAIT_START))
    [ "$ELAPSED" -lt "$WAIT_TIMEOUT" ] || die "timeout waiting for SSM agent to come online (${WAIT_TIMEOUT}s)"

    SSM_STATUS=$(aws --profile eks-sandbox --region "$AWS_REGION" ssm describe-instance-information \
      --filters Key=InstanceIds,Values="$INSTANCE_ID" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null || echo "")

    if [ "$SSM_STATUS" = "Online" ]; then
      log "  SSM agent is Online"
      break
    fi
    sleep 15
  done

  # Print BUILD_* values for driver script
  EXECUTION_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EXECUTION_ROLE_NAME}"
  log ""
  log "Image Builder prerequisites ready for ${NODE_ARCH} (run $RUN_ID)"
  log "Set these variables for the driver script:"
  echo "BUILD_SUBNET_ID=$BUILD_SUBNET_ID"
  echo "BUILD_INSTANCE_PROFILE=$INSTANCE_PROFILE_NAME"
  echo "BUILD_SECURITY_GROUP_ID=$SG_ID"
  echo "BUILD_S3_BUCKET=$BUCKET_NAME"
  echo "BUILD_ASG_NAME=$ASG_NAME"
  echo "BUILD_INSTANCE_TYPE=$BUILD_INSTANCE_TYPE"
  echo "BUILD_EXECUTION_ROLE=$EXECUTION_ROLE_ARN"

  exit 0
fi

# =============================================================================
# DOWN: remove prerequisites
# =============================================================================
if [ "$MODE" = down ]; then
  log "Removing Image Builder prerequisites for ${NODE_ARCH} (run $RUN_ID)"
  : > "$REMAINING" 2>/dev/null || { warn "cannot write $REMAINING"; incomplete=1; }

  # Get account ID for bucket name
  ACCOUNT_ID=$(aws --profile eks-sandbox --region "$AWS_REGION" sts get-caller-identity --query Account --output text) \
    || { warn "could not read account ID"; incomplete=1; ACCOUNT_ID=""; }
  [ -n "$ACCOUNT_ID" ] && BUCKET_NAME="al2023-ami-ib-logs-${ACCOUNT_ID}"

  # --- Auto Scaling Group ---
  probe 'ValidationError.*does not exist' aws --profile eks-sandbox --region "$AWS_REGION" autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" --query 'AutoScalingGroups[0].Tags' --output json
  case $? in
    0) if printf '%s' "$PROBE_OUT" | python3 -c '
import json,sys
tags=json.load(sys.stdin) or []
d={t["Key"]:t["Value"] for t in tags}
sys.exit(0 if d.get("'$TAGS_OWNER_KEY'")=="'$TAGS_OWNER_VALUE'" and d.get("'$TAGS_RUN_KEY'")=="'$RUN_ID'" else 1)
'; then
         act "setting ASG $ASG_NAME desired capacity to 0" aws --profile eks-sandbox --region "$AWS_REGION" autoscaling update-auto-scaling-group \
           --auto-scaling-group-name "$ASG_NAME" --min-size 0 --max-size 0 --desired-capacity 0
         log "waiting for ASG instances to terminate..."
         sleep 30
         act "deleting ASG $ASG_NAME" aws --profile eks-sandbox --region "$AWS_REGION" autoscaling delete-auto-scaling-group \
           --auto-scaling-group-name "$ASG_NAME" --force-delete
       else
         warn "ASG $ASG_NAME is not tagged for run $RUN_ID; leaving it"
       fi ;;
    1) log "ASG $ASG_NAME not present" ;;
    *) ;; # incomplete already set
  esac

  # --- Launch Template ---
  probe 'InvalidLaunchTemplateName.NotFoundException' aws --profile eks-sandbox --region "$AWS_REGION" ec2 describe-launch-templates \
    --launch-template-names "$LT_IB_NAME" --query 'LaunchTemplates[0]' --output json
  case $? in
    0) if printf '%s' "$PROBE_OUT" | jfield 'd.get("Tags") or []' | tags_match; then
         LT_ID=$(printf '%s' "$PROBE_OUT" | json_get 'd["LaunchTemplateId"]')
         note_blocked "aws ec2 delete-launch-template --region $AWS_REGION --launch-template-id $LT_ID"
       else
         warn "launch template $LT_IB_NAME is not tagged for run $RUN_ID; leaving it"
       fi ;;
    1) log "launch template $LT_IB_NAME not present" ;;
    *) ;; # incomplete already set
  esac

  # --- Execution Role ---
  probe 'NoSuchEntity' aws --profile eks-sandbox iam get-role --role-name "$EXECUTION_ROLE_NAME" --query 'Role.Tags' --output json
  case $? in
    0) if printf '%s' "$PROBE_OUT" | tags_match; then
         # Detach managed policy
         aws --profile eks-sandbox iam detach-role-policy \
           --role-name "$EXECUTION_ROLE_NAME" \
           --policy-arn arn:aws:iam::aws:policy/service-role/EC2ImageBuilderExecutionPolicy 2>/dev/null || true
         # Delete inline policies
         for pol in $(aws --profile eks-sandbox iam list-role-policies --role-name "$EXECUTION_ROLE_NAME" --query 'PolicyNames' --output text 2>/dev/null || echo ""); do
           act "deleting inline policy $pol from $EXECUTION_ROLE_NAME" aws --profile eks-sandbox iam delete-role-policy \
             --role-name "$EXECUTION_ROLE_NAME" --policy-name "$pol"
         done
         act "deleting execution role $EXECUTION_ROLE_NAME" aws --profile eks-sandbox iam delete-role --role-name "$EXECUTION_ROLE_NAME"
       else
         warn "execution role $EXECUTION_ROLE_NAME is not tagged for run $RUN_ID; leaving it"
       fi ;;
    1) log "execution role $EXECUTION_ROLE_NAME not present" ;;
    *) ;; # incomplete already set
  esac

  # --- S3 Bucket (empty it first) ---
  if [ -n "$BUCKET_NAME" ]; then
    probe 'NoSuchBucket' aws --profile eks-sandbox --region "$AWS_REGION" s3api head-bucket --bucket "$BUCKET_NAME"
    case $? in
      0) log "emptying and deleting S3 bucket $BUCKET_NAME"
         aws --profile eks-sandbox --region "$AWS_REGION" s3 rm "s3://$BUCKET_NAME" --recursive 2>/dev/null || true
         act "deleting bucket $BUCKET_NAME" aws --profile eks-sandbox --region "$AWS_REGION" s3api delete-bucket --bucket "$BUCKET_NAME"
         ;;
      1) log "S3 bucket $BUCKET_NAME not present" ;;
      *) ;; # incomplete already set
    esac
  fi

  # --- Instance Profile ---
  probe 'NoSuchEntity' aws --profile eks-sandbox iam get-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" --query 'InstanceProfile.Tags' --output json
  case $? in
    0) if printf '%s' "$PROBE_OUT" | tags_match; then
         act "removing role from instance profile $INSTANCE_PROFILE_NAME" aws --profile eks-sandbox iam remove-role-from-instance-profile \
           --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$INSTANCE_ROLE_NAME" 2>/dev/null || true
         act "deleting instance profile $INSTANCE_PROFILE_NAME" aws --profile eks-sandbox iam delete-instance-profile \
           --instance-profile-name "$INSTANCE_PROFILE_NAME"
       else
         warn "instance profile $INSTANCE_PROFILE_NAME is not tagged for run $RUN_ID; leaving it"
       fi ;;
    1) log "instance profile $INSTANCE_PROFILE_NAME not present" ;;
    *) ;; # incomplete already set
  esac

  # --- Instance Role ---
  probe 'NoSuchEntity' aws --profile eks-sandbox iam get-role --role-name "$INSTANCE_ROLE_NAME" --query 'Role.Tags' --output json
  case $? in
    0) if printf '%s' "$PROBE_OUT" | tags_match; then
         # Detach managed policies
         for pol_arn in $(aws --profile eks-sandbox iam list-attached-role-policies --role-name "$INSTANCE_ROLE_NAME" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo ""); do
           act "detaching policy $pol_arn" aws --profile eks-sandbox iam detach-role-policy --role-name "$INSTANCE_ROLE_NAME" --policy-arn "$pol_arn"
         done
         # Delete inline policies
         for pol in $(aws --profile eks-sandbox iam list-role-policies --role-name "$INSTANCE_ROLE_NAME" --query 'PolicyNames' --output text 2>/dev/null || echo ""); do
           act "deleting inline policy $pol" aws --profile eks-sandbox iam delete-role-policy --role-name "$INSTANCE_ROLE_NAME" --policy-name "$pol"
         done
         act "deleting IAM role $INSTANCE_ROLE_NAME" aws --profile eks-sandbox iam delete-role --role-name "$INSTANCE_ROLE_NAME"
       else
         warn "IAM role $INSTANCE_ROLE_NAME is not tagged for run $RUN_ID; leaving it"
       fi ;;
    1) log "IAM role $INSTANCE_ROLE_NAME not present" ;;
    *) ;; # incomplete already set
  esac

  # --- Security Group ---
  probe 'InvalidGroup.NotFound' aws --profile eks-sandbox --region "$AWS_REGION" ec2 describe-security-groups \
    --filters Name=group-name,Values="$SG_NAME" --query 'SecurityGroups[0]' --output json
  case $? in
    0) if printf '%s' "$PROBE_OUT" | jfield 'd.get("Tags") or []' | tags_match; then
         SG_ID=$(printf '%s' "$PROBE_OUT" | json_get 'd["GroupId"]')
         note_blocked "aws ec2 delete-security-group --region $AWS_REGION --group-id $SG_ID"
       else
         warn "security group $SG_NAME is not tagged for run $RUN_ID; leaving it"
       fi ;;
    1) log "security group $SG_NAME not present" ;;
    *) ;; # incomplete already set
  esac

  echo
  [ -s "$REMAINING" ] && { echo "Host-blocked deletes are listed in order; run them yourself:"; echo "  $REMAINING"; }
  if [ "$incomplete" = 1 ]; then
    echo "TEARDOWN INCOMPLETE: something was not this run's, a lookup failed, or a delete is left for you."
    exit 1
  fi
  echo "Teardown complete for ${NODE_ARCH} run $RUN_ID."
  exit 0
fi
