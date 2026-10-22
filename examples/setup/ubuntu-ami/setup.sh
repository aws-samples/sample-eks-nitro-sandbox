#!/usr/bin/env bash
# setup.sh: IAM -> build host -> kernel build -> runtime install -> runtime wiring ->
# AppArmor profile -> smoke -> bake-prep -> AMI register -> fresh-image verify -> dedicated
# tainted node-group join -> apply the validation workloads.
#
#   ./setup.sh --prepare     # preflight only: validate inputs, resolve pins, check the
#                            #   documented runtime prerequisite; create nothing
#   ./setup.sh --dry-run     # alias of --prepare (kept for older docs)
#   ./setup.sh               # run the whole build and join
#
# This script does not SSH anywhere directly: the build host is reached through AWS Systems
# Manager Session Manager / Run Command, and the build security group carries no inbound
# rule. The preflight stage (scripts/00-preflight.sh, via
# packages/fetch-runtime-artifacts.sh) STOPS cleanly with a documented prerequisite if the
# EKS Pod Isolation runtime release artifacts are not yet present; it never substitutes an
# internal source tree or a private URL.
set -euo pipefail
SAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SAMPLE_DIR/scripts/lib/common.sh"

PREPARE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --prepare|--dry-run) PREPARE_ONLY=1 ;;
    *) die "unknown argument: $arg (supported: --prepare, --dry-run)" ;;
  esac
done

command -v aws >/dev/null 2>&1 || die "aws CLI v2 is required"
command -v session-manager-plugin >/dev/null 2>&1 || warn "session-manager-plugin not found; required to reach the build host interactively"

# --- Step 1: local preflight (no cloud calls) ---------------------------------------------
log "Step 1/8: local preflight (lock file sanity, pinned public inputs, documented prerequisite)"
[[ -f "$LOCK_FILE" ]] || die "missing $LOCK_FILE"
bash "$SAMPLE_DIR/packages/fetch-runtime-artifacts.sh" || {
  rc=$?
  if [[ "$rc" == 3 ]]; then
    log "setup.sh STOPS here: the documented EKS Pod Isolation runtime prerequisite is not met."
    exit 3
  fi
  die "fetch-runtime-artifacts.sh failed unexpectedly (exit $rc)"
}
bash "$SAMPLE_DIR/packages/fetch-kernel.sh" "$RUNTIME_ARTIFACTS_DIR" >/dev/null
bash "$SAMPLE_DIR/packages/fetch-erofs-utils.sh" "$RUNTIME_ARTIFACTS_DIR" >/dev/null
log "all pinned public inputs verified; runtime release artifacts present and verified."

if [[ "$PREPARE_ONLY" == 1 ]]; then
  log "--prepare: inputs validated, pins resolved, runtime prerequisite satisfied. No AWS resources created."
  log "Re-run without --prepare to build, bake, verify and join."
  exit 0
fi

# ---- From here on, real AWS mutation. Everything created is tagged ManagedBy=$RESOURCE_PREFIX
# ---- so clean.sh can find and remove it even if this run is interrupted.
: "${BUILD_SUBNET_ID:?set BUILD_SUBNET_ID in config.env to a private build subnet}"
: "${NODE_SUBNET_IDS:?set NODE_SUBNET_IDS in config.env (space-separated private subnets)}"

# --- Step 2: scoped IAM roles + build-host instance profile --------------------------------
log "Step 2/8: create scoped IAM roles and the build-host instance profile (scripts/00a-iam.sh)"
bash "$SAMPLE_DIR/scripts/00a-iam.sh"
# 00a-iam.sh records INSTANCE_PROFILE / NODE_ROLE_ARN here for the later stages to consume.
IAM_ENV="$OUT_DIR/iam.env"
[[ -f "$IAM_ENV" ]] || die "00a-iam.sh did not write $IAM_ENV"
# shellcheck source=/dev/null
. "$IAM_ENV"
log "using INSTANCE_PROFILE=$INSTANCE_PROFILE, NODE_ROLE_ARN=$NODE_ROLE_ARN"

# --- Step 3: resolve the Canonical EKS base AMI --------------------------------------------
log "Step 3/8: resolve the Ubuntu 24.04 EKS base AMI for Kubernetes ${BASE_AMI_K8S_VERSION:-1.36} in $AWS_REGION"
BASE_AMI_ID=$(aws ssm get-parameter --region "$AWS_REGION" \
  --name "/aws/service/canonical/ubuntu/eks/24.04/${BASE_AMI_K8S_VERSION:-1.36}/stable/current/amd64/hvm/ebs-gp3/ami-id" \
  --query 'Parameter.Value' --output text)
log "resolved base AMI: $BASE_AMI_ID"

# --- Step 4: build security group (no inbound rule) and the build host, reached via SSM ----
log "Step 4/8: build security group (no inbound rule) + launch the build host over SSM"
SG_NAME="${RESOURCE_PREFIX}-build-sg"
VPC_ID=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$BUILD_SUBNET_ID" \
  --query 'Subnets[0].VpcId' --output text)
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [[ -z "$SECURITY_GROUP_ID" || "$SECURITY_GROUP_ID" == "None" ]]; then
  SECURITY_GROUP_ID=$(aws ec2 create-security-group --region "$AWS_REGION" \
    --group-name "$SG_NAME" --vpc-id "$VPC_ID" \
    --description "ubuntu-ami sample build host; NO inbound rule by design (SSM only)" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{$(ownership_tag_cli)}]" \
    --query 'GroupId' --output text)
  log "created build security group $SECURITY_GROUP_ID with no inbound rule (SSM-only access)"
else
  log "reusing owned build security group $SECURITY_GROUP_ID"
fi

BUILD_NAME="${RESOURCE_PREFIX}-build-$(date -u +%Y%m%dT%H%M%SZ)"
log "launching build host $BUILD_NAME from $BASE_AMI_ID (type ${BUILD_INSTANCE_TYPE:-m8i.xlarge}, ${BUILD_ROOT_VOLUME_GB:-120} GiB root)"
build_id=$(aws ec2 run-instances --region "$AWS_REGION" \
  --image-id "$BASE_AMI_ID" \
  --instance-type "${BUILD_INSTANCE_TYPE:-m8i.xlarge}" \
  --iam-instance-profile "Name=$INSTANCE_PROFILE" \
  --security-group-ids "$SECURITY_GROUP_ID" \
  --subnet-id "$BUILD_SUBNET_ID" \
  --enclave-options Enabled=true \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${BUILD_ROOT_VOLUME_GB:-120},\"VolumeType\":\"gp3\"}}]" \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=$BUILD_NAME},{$(ownership_tag_cli)}]" \
    "ResourceType=volume,Tags=[{Key=Name,Value=$BUILD_NAME},{$(ownership_tag_cli)}]" \
  --query 'Instances[0].InstanceId' --output text)
log "build host: $build_id; waiting for status-ok and SSM Online"
aws ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$build_id"
ssm_online() {
  local id="$1" state
  for _ in $(seq 1 30); do
    state=$(aws ssm describe-instance-information --region "$AWS_REGION" \
      --filters "Key=InstanceIds,Values=$id" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)
    [[ "$state" == "Online" ]] && return 0
    sleep 10
  done
  return 1
}
ssm_online "$build_id" || die "build host $build_id never reported Online to SSM"

# Copy this sample's scripts + packages + manifests onto the build host so the numbered
# stages run there. tar over SSM via base64 (no inbound rule, no SSH, no S3 bucket needed).
REMOTE_DIR=/usr/local/share/ubuntu-ami-sample
log "staging sample scripts to $build_id:$REMOTE_DIR over SSM"
bundle_b64=$(cd "$SAMPLE_DIR" && tar -cz scripts packages manifests config.env.example | base64 -w0)
run_ssm() { # run_ssm <instance-id> <timeout-seconds> <shell-command>
  local id="$1" timeout="$2" cmd="$3" cmd_id status
  cmd_id=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$id" \
    --document-name AWS-RunShellScript --timeout-seconds "$timeout" \
    --parameters "{\"commands\":[$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')],\"executionTimeout\":[\"$timeout\"]}" \
    --query 'Command.CommandId' --output text)
  aws ssm wait command-executed --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$id" 2>/dev/null || true
  status=$(aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$id" \
    --query 'Status' --output text)
  aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$id" \
    --query 'StandardOutputContent' --output text | sed 's/^/  [build] /'
  if [[ "$status" != "Success" ]]; then
    aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$id" \
      --query 'StandardErrorContent' --output text | sed 's/^/  [build:stderr] /' >&2
    die "SSM command failed on $id (status $status)"
  fi
}
run_ssm "$build_id" 300 "sudo mkdir -p $REMOTE_DIR && echo '$bundle_b64' | base64 -d | sudo tar -xz -C $REMOTE_DIR && sudo cp $REMOTE_DIR/scripts/verify-image.py $REMOTE_DIR/ && sudo cp $REMOTE_DIR/scripts/40-smoke.sh $REMOTE_DIR/ && echo staged"

# --- Step 5: run the numbered build stages on the build host, in order ---------------------
log "Step 5/8: run the build stages on $build_id in order (00 -> 10 -> 20 -> 30 -> 31 -> 35 -> 40)"
STAGE_ENV="sudo RUNTIME_ARTIFACTS_DIR=$REMOTE_DIR/artifacts SHIM_DEBUG=${SHIM_DEBUG:-true} bash $REMOTE_DIR/scripts"
run_ssm "$build_id" 1800 "$STAGE_ENV/00-preflight.sh"
run_ssm "$build_id" 7200 "$STAGE_ENV/10-kernel.sh"
log "rebooting build host onto the new kernel"
aws ec2 reboot-instances --region "$AWS_REGION" --instance-ids "$build_id"
sleep 30; ssm_online "$build_id" || die "build host did not return to SSM after reboot"
run_ssm "$build_id" 1800 "$STAGE_ENV/00-preflight.sh"   # re-run: enclave checks are meaningful now
run_ssm "$build_id" 1800 "$STAGE_ENV/20-erofs-utils.sh"
run_ssm "$build_id" 1800 "$STAGE_ENV/30-runtime-install.sh"
run_ssm "$build_id" 600  "$STAGE_ENV/31-wire-containerd.sh"
run_ssm "$build_id" 600  "$STAGE_ENV/35-apparmor.sh"
run_ssm "$build_id" 900  "$STAGE_ENV/40-smoke.sh"
run_ssm "$build_id" 600  "sudo python3 $REMOTE_DIR/scripts/verify-image.py"

# --- Step 6: bake-prep, then register an AMI from the build host ---------------------------
log "Step 6/8: sanitize (scripts/50-bake-prep.sh) and register an AMI from $build_id"
run_ssm "$build_id" 1200 "$STAGE_ENV/50-bake-prep.sh"
AMI_NAME="${RESOURCE_PREFIX}-$(date -u +%Y%m%dT%H%M%SZ)"
AMI_ID=$(aws ec2 create-image --region "$AWS_REGION" --instance-id "$build_id" \
  --name "$AMI_NAME" --no-reboot \
  --tag-specifications \
    "ResourceType=image,Tags=[{Key=Name,Value=$AMI_NAME},{$(ownership_tag_cli)}]" \
    "ResourceType=snapshot,Tags=[{Key=Name,Value=$AMI_NAME},{$(ownership_tag_cli)}]" \
  --query 'ImageId' --output text)
log "AMI $AMI_ID registering; waiting until available"
aws ec2 wait image-available --region "$AWS_REGION" --image-ids "$AMI_ID"
log "AMI available: $AMI_ID"
log "terminating the build host $build_id (the AMI carries the image now)"
aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$build_id" >/dev/null
aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids "$build_id"

# --- Step 7: verify a SECOND fresh instance launched from the AMI --------------------------
log "Step 7/8: fresh-instance verification on a SECOND instance (scripts/verify-fresh-instance.sh)"
AMI_ID="$AMI_ID" INSTANCE_PROFILE="$INSTANCE_PROFILE" SECURITY_GROUP_ID="$SECURITY_GROUP_ID" \
  SUBNET_ID="$BUILD_SUBNET_ID" bash "$SAMPLE_DIR/scripts/verify-fresh-instance.sh"

# --- Step 8: join the dedicated tainted node group, then apply the validation workloads ----
log "Step 8/8: join the dedicated tainted managed node group (scripts/join-nodegroup.sh)"
AMI_ID="$AMI_ID" NODE_ROLE_ARN="$NODE_ROLE_ARN" bash "$SAMPLE_DIR/scripts/join-nodegroup.sh"

NODEGROUP_NAME="${NODEGROUP_NAME:-${RESOURCE_PREFIX}-ng}"
log "applying the validation workloads from deploy/ (rendering @NODEGROUP@ = $NODEGROUP_NAME)"
APPLY_TMP="$OUT_DIR/rendered"
mkdir -p "$APPLY_TMP"
for f in pod-ordinary.yaml pod-isolated-sandbox.yaml network-policy.yaml; do
  sed "s/@NODEGROUP@/$NODEGROUP_NAME/g" "$SAMPLE_DIR/deploy/$f" > "$APPLY_TMP/$f"
done
# Create the sample's namespace only if absent, and label it so clean.sh will own it.
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  kubectl create namespace "$NAMESPACE"
fi
kubectl label namespace "$NAMESPACE" "app.kubernetes.io/part-of=$RESOURCE_PREFIX" --overwrite >/dev/null
kubectl apply -n "$NAMESPACE" -f "$APPLY_TMP/network-policy.yaml"
kubectl apply -n "$NAMESPACE" -f "$APPLY_TMP/pod-ordinary.yaml"
kubectl apply -n "$NAMESPACE" -f "$APPLY_TMP/pod-isolated-sandbox.yaml"

log "setup.sh complete. AMI=$AMI_ID, node group=$NODEGROUP_NAME. Run ./test.sh to read live evidence."
printf 'AMI_ID=%s\n' "$AMI_ID" > "$OUT_DIR/last-build.env"
