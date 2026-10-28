#!/usr/bin/env bash
# setup.sh: preflight -> IAM -> base AMI -> S3 staging -> build host -> kernel build ->
# runtime install -> runtime wiring -> AppArmor profile -> smoke -> bake-prep -> AMI register ->
# fresh-image verify -> tag BtfValidated=true -> dedicated tainted node-group join -> apply the
# validation workloads.
#
# BtfValidated=true (the tag issue #11, Cilium on Ubuntu, requires before it will use an
# AMI) is applied to the AMI ONLY after scripts/verify-fresh-instance.sh PASSES (step 9
# below), never at create-image time (step 8) and never when verification fails. See
# scripts/verify-fresh-instance.sh and scripts/lib/btf-tag.sh for exactly where and how.
#
#   ./setup.sh --prepare     # preflight only: verify every pinned input and the runtime
#                            #   archive locally; create nothing
#   ./setup.sh --dry-run     # alias of --prepare (kept for older docs)
#   ./setup.sh               # run the whole build and join
#
# This script does not SSH anywhere: the build host is reached through AWS Systems Manager Run
# Command, and the build security group carries no inbound rule. Files reach the build host
# through a per-run S3 staging bucket (scripts/00b-stage-bucket.sh), never through an SSM shell.
# The local preflight STOPS (exit 3) with the documented prerequisite when the operator-supplied
# runtime archive is not present; it never substitutes an internal source tree or a private URL.
#
# Private run evidence (the resolved base AMI and its serial, the observed containerd version,
# each stage's output) is written under $OUT_DIR/evidence/<run-id>, the repository's gitignored
# tmp/issue10/run/out/evidence by default, never in the sample folder.
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
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v session-manager-plugin >/dev/null 2>&1 || warn "session-manager-plugin not found; required to reach the build host interactively"

KUBECTL="${KUBECTL:-kubectl}"   # e.g. KUBECTL="kubectl --context <your-context>"; never use-context on a shared machine
RUN_ID="$(date -u +%Y%m%dt%H%M%Sz)"
EVIDENCE="$OUT_DIR/evidence/$RUN_ID"
export EVIDENCE_DIR="$EVIDENCE"
mkdir -p "$EVIDENCE"
EVIDENCE_ENV="$EVIDENCE/run-evidence.env"
SUMMARY="$EVIDENCE/summary.txt"
record() { printf '%s=%q\n' "$1" "$2" >> "$EVIDENCE_ENV"; printf '%s: %s\n' "$1" "$2" >> "$SUMMARY"; }
: > "$EVIDENCE_ENV"; : > "$SUMMARY"
record RUN_ID "$RUN_ID"

# --- Step 1: local preflight (no cloud calls) ---------------------------------------------
log "Step 1/10: local preflight (lock file, pinned public inputs, the operator-supplied runtime archive)"
[[ -f "$LOCK_FILE" ]] || die "missing $LOCK_FILE"
rc=0
bash "$SAMPLE_DIR/packages/fetch-runtime-artifacts.sh" || rc=$?
if [[ "$rc" == 3 ]]; then
  log "setup.sh STOPS here: the documented runtime-archive prerequisite is not met."
  exit 3
fi
[[ "$rc" == 0 ]] || die "the runtime archive did not verify (exit $rc); see the FATAL line above"
bash "$SAMPLE_DIR/packages/fetch-kernel.sh" "$RUNTIME_ARTIFACTS_DIR" >/dev/null
bash "$SAMPLE_DIR/packages/fetch-kernel-patch.sh" "$RUNTIME_ARTIFACTS_DIR" >/dev/null
bash "$SAMPLE_DIR/packages/fetch-erofs-utils.sh" "$RUNTIME_ARTIFACTS_DIR" >/dev/null
RUNTIME_ZIP="$RUNTIME_ARTIFACTS_DIR/${RUNTIME_ARTIFACT_FILE:-$(lock_field runtime-archive file)}"
log "all pinned public inputs verified; runtime archive and its eight payloads verified."

if [[ "$PREPARE_ONLY" == 1 ]]; then
  log "--prepare: inputs verified, pins resolved, runtime prerequisite satisfied. No AWS resources created."
  log "Re-run without --prepare to build, bake, verify and join."
  exit 0
fi

: "${BUILD_SUBNET_ID:?set BUILD_SUBNET_ID in config.env to a private build subnet}"
: "${NODE_SUBNET_IDS:?set NODE_SUBNET_IDS in config.env (space-separated private subnets)}"

# --- Cluster-wide prerequisites, read only, before anything is created ---------------------
# The managed vpc-cni add-on with network policy on, and the shared isolated-sandbox
# RuntimeClass. Both are the reader's; this run checks them and stops with the command to run.
log "checking the cluster-wide prerequisites (scripts/00c-check-cluster.sh, read only)"
KUBECTL="$KUBECTL" bash "$SAMPLE_DIR/scripts/00c-check-cluster.sh"

# ---- From here on, real AWS mutation. Everything created is tagged ManagedBy=$RESOURCE_PREFIX
# ---- so clean.sh can find and remove it even if this run is interrupted.

# --- Step 2: scoped IAM roles + build-host instance profile --------------------------------
log "Step 2/10: create scoped IAM roles and the build-host instance profile (scripts/00a-iam.sh)"
bash "$SAMPLE_DIR/scripts/00a-iam.sh"
IAM_ENV="$OUT_DIR/iam.env"
[[ -f "$IAM_ENV" ]] || die "00a-iam.sh did not write $IAM_ENV"
# shellcheck source=/dev/null
. "$IAM_ENV"
log "using INSTANCE_PROFILE=$INSTANCE_PROFILE, NODE_ROLE_ARN=$NODE_ROLE_ARN"

# --- Step 3: resolve the Canonical EKS base AMI at run time --------------------------------
# Never hard-coded: Canonical republishes "current" under new serials (the image name ends in
# the serial), so the run records which one it got, and the build host checks that serial's
# containerd before building anything (scripts/00-preflight.sh).
BASE_AMI_PARAM="/aws/service/canonical/ubuntu/eks/24.04/${BASE_AMI_K8S_VERSION:-1.36}/stable/current/amd64/hvm/ebs-gp3/ami-id"
log "Step 3/10: resolve the Ubuntu 24.04 EKS base AMI for Kubernetes ${BASE_AMI_K8S_VERSION:-1.36} in $AWS_REGION"
BASE_AMI_ID=$(aws ssm get-parameter --region "$AWS_REGION" --name "$BASE_AMI_PARAM" --query 'Parameter.Value' --output text)
[[ "$BASE_AMI_ID" =~ ^ami-[0-9a-f]+$ ]] || die "SSM parameter $BASE_AMI_PARAM did not resolve to an AMI id"
read -r BASE_AMI_NAME BASE_AMI_CREATED BASE_AMI_OWNER < <(aws ec2 describe-images --region "$AWS_REGION" --image-ids "$BASE_AMI_ID" \
  --query 'Images[0].[Name,CreationDate,OwnerId]' --output text)
BASE_AMI_SERIAL=$(printf '%s' "$BASE_AMI_NAME" | sed -nE 's/.*-([0-9]{8}(\.[0-9]+)?)$/\1/p')
log "resolved base AMI: $BASE_AMI_ID ($BASE_AMI_NAME, serial ${BASE_AMI_SERIAL:-<unknown>})"
record BASE_AMI_PARAM "$BASE_AMI_PARAM"
record BASE_AMI_ID "$BASE_AMI_ID"
record BASE_AMI_NAME "$BASE_AMI_NAME"
record BASE_AMI_SERIAL "${BASE_AMI_SERIAL:-unknown}"
record BASE_AMI_CREATION_DATE "$BASE_AMI_CREATED"
record BASE_AMI_OWNER "$BASE_AMI_OWNER"

# --- Step 4: the per-run S3 staging bucket ---------------------------------------------------
log "Step 4/10: per-run S3 staging bucket for the sample's scripts and the runtime archive (scripts/00b-stage-bucket.sh)"
STAGE_TARBALL="$OUT_DIR/ubuntu-ami-sample-${RUN_ID}.tar.gz"
(cd "$SAMPLE_DIR" && tar -czf "$STAGE_TARBALL" scripts packages manifests deploy config.env.example)
TARBALL_SHA=$(sha256sum "$STAGE_TARBALL" | awk '{print $1}')
ZIP_SHA=$(lock_field runtime-archive sha256)
bash "$SAMPLE_DIR/scripts/00b-stage-bucket.sh" create "$RUN_ID" "$BUILD_ROLE_NAME" "$STAGE_TARBALL" "$RUNTIME_ZIP"
# shellcheck source=/dev/null
. "$OUT_DIR/stage.env"
record STAGE_BUCKET "$STAGE_BUCKET"

# --- Step 5: build security group (no inbound rule) and the build host, reached via SSM ----
log "Step 5/10: build security group (no inbound rule) + launch the build host over SSM"
SG_NAME="${RESOURCE_PREFIX}-build-sg"
VPC_ID=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$BUILD_SUBNET_ID" \
  --query 'Subnets[0].VpcId' --output text)
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" "Name=tag:${TAGS_OWNER_KEY},Values=${TAGS_OWNER_VALUE}" \
  --query 'SecurityGroups[0].GroupId' --output text)
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
inbound=$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$SECURITY_GROUP_ID" \
  --query 'length(SecurityGroups[0].IpPermissions)' --output text)
[[ "$inbound" == 0 ]] || die "build security group $SECURITY_GROUP_ID has $inbound inbound rule(s); this sample needs none"

BUILD_NAME="${RESOURCE_PREFIX}-build-${RUN_ID}"
log "launching build host $BUILD_NAME from $BASE_AMI_ID (type ${BUILD_INSTANCE_TYPE:-m8i.4xlarge}, ${BUILD_ROOT_VOLUME_GB:-120} GiB root)"
build_id=$(aws ec2 run-instances --region "$AWS_REGION" \
  --image-id "$BASE_AMI_ID" \
  --instance-type "${BUILD_INSTANCE_TYPE:-m8i.4xlarge}" \
  --iam-instance-profile "Name=$INSTANCE_PROFILE" \
  --security-group-ids "$SECURITY_GROUP_ID" \
  --subnet-id "$BUILD_SUBNET_ID" \
  --enclave-options Enabled=true \
  --metadata-options HttpTokens=required \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${BUILD_ROOT_VOLUME_GB:-120},\"VolumeType\":\"gp3\"}}]" \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=$BUILD_NAME},{$(ownership_tag_cli)},{Key=RunId,Value=$RUN_ID}]" \
    "ResourceType=volume,Tags=[{Key=Name,Value=$BUILD_NAME},{$(ownership_tag_cli)},{Key=RunId,Value=$RUN_ID}]" \
  --query 'Instances[0].InstanceId' --output text)
record BUILD_INSTANCE_ID "$build_id"
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

# send_and_wait <instance-id> <timeout-seconds> <document> <parameters-json> : run an SSM
# document, print its output, and fail unless it reports Success.
send_and_wait() {
  local id="$1" timeout="$2" doc="$3" params="$4" cmd_id status
  cmd_id=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$id" \
    --document-name "$doc" --timeout-seconds "$timeout" --parameters "$params" \
    --query 'Command.CommandId' --output text)
  aws ssm wait command-executed --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$id" 2>/dev/null || true
  status=$(aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$id" \
    --query 'Status' --output text)
  aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$id" \
    --query 'StandardOutputContent' --output text | sed 's/^/  [build] /'
  if [[ "$status" != "Success" ]]; then
    aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$id" \
      --query 'StandardErrorContent' --output text | sed 's/^/  [build:stderr] /' >&2
    die "SSM $doc failed on $id (status $status)"
  fi
}
json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
run_ssm() { # run_ssm <instance-id> <timeout-seconds> <shell-command>
  send_and_wait "$1" "$2" AWS-RunShellScript "{\"commands\":[$(json_str "$3")],\"executionTimeout\":[\"$2\"]}"
}

# --- Step 6: stage this run's files onto the build host from S3, and verify them there ------
# AWS-RunRemoteScript downloads with the build host's instance profile (the per-run read
# 00b-stage-bucket.sh granted); the hashes it is checked against come from THIS workstation
# over the SSM command channel, not from the bucket.
HOST_BASE=/var/lib/ubuntu-ami-sample
HOST_STAGE="$HOST_BASE/stage"
REMOTE_DIR=/usr/local/share/ubuntu-ami-sample
log "Step 6/10: download the staged files on $build_id from s3://$STAGE_BUCKET/$RUN_ID/ and verify their SHA-256 there"
run_ssm "$build_id" 120 "install -d -m 0700 $HOST_BASE $HOST_STAGE"
for f in "$STAGE_TARBALL" "$RUNTIME_ZIP"; do
  url="https://s3.${AWS_REGION}.amazonaws.com/${STAGE_BUCKET}/${RUN_ID}/$(basename "$f")"
  send_and_wait "$build_id" 1800 AWS-RunRemoteScript \
    "{\"sourceType\":[\"S3\"],\"sourceInfo\":[$(json_str "{\"path\":\"$url\"}")],\"commandLine\":[$(json_str "sha256sum $(basename "$f")")],\"workingDirectory\":[\"$HOST_STAGE\"],\"executionTimeout\":[\"1800\"]}"
done
run_ssm "$build_id" 900 "set -e
cd $HOST_STAGE
printf '%s  %s\n' $TARBALL_SHA $(basename "$STAGE_TARBALL") $ZIP_SHA $(basename "$RUNTIME_ZIP") | sha256sum -c --strict -
mkdir -p $REMOTE_DIR $HOST_BASE/run/runtime
tar -xzf $(basename "$STAGE_TARBALL") -C $REMOTE_DIR
mv -f $(basename "$RUNTIME_ZIP") $HOST_BASE/run/runtime/
echo staged-and-verified"
bash "$SAMPLE_DIR/scripts/00b-stage-bucket.sh" revoke "$STAGE_BUCKET" "$RUN_ID" "$BUILD_ROLE_NAME" \
  "$(basename "$STAGE_TARBALL")" "$(basename "$RUNTIME_ZIP")"

# --- Step 7: run the numbered build stages on the build host, in order ---------------------
log "Step 7/10: run the build stages on $build_id in order (00 -> 10 -> reboot -> 00 -> 20 -> 30 -> 31 -> 35 -> 40 -> verify-image)"
STAGE_ENV="sudo ISSUE10_RUN_DIR=$HOST_BASE/run RUNTIME_ARTIFACTS_DIR=$HOST_BASE/run/runtime SHIM_DEBUG=${SHIM_DEBUG} STAGE_DIR=$HOST_STAGE bash $REMOTE_DIR/scripts"
run_ssm "$build_id" 1800 "$STAGE_ENV/00-preflight.sh" | tee "$EVIDENCE/build-host-preflight-1.txt"
build_containerd=$(sed -n 's/^  \[build\] CONTAINERD_VERDICT=//p' "$EVIDENCE/build-host-preflight-1.txt" | head -n 1)
record BUILD_HOST_CONTAINERD "${build_containerd:-<not read>}"
run_ssm "$build_id" 7200 "$STAGE_ENV/10-kernel.sh" | tee "$EVIDENCE/build-host-kernel.txt"
log "rebooting build host onto the new kernel"
aws ec2 reboot-instances --region "$AWS_REGION" --instance-ids "$build_id"
sleep 30; ssm_online "$build_id" || die "build host did not return to SSM after reboot"
run_ssm "$build_id" 1800 "$STAGE_ENV/00-preflight.sh" | tee "$EVIDENCE/build-host-preflight-2.txt"   # enclave checks are meaningful now
run_ssm "$build_id" 1800 "$STAGE_ENV/20-erofs-utils.sh"
run_ssm "$build_id" 1800 "$STAGE_ENV/30-runtime-install.sh"
run_ssm "$build_id" 600  "$STAGE_ENV/31-wire-containerd.sh"
run_ssm "$build_id" 600  "$STAGE_ENV/35-apparmor.sh"
run_ssm "$build_id" 900  "$STAGE_ENV/40-smoke.sh" | tee "$EVIDENCE/build-host-smoke.txt"
run_ssm "$build_id" 600  "sudo SHIM_DEBUG=${SHIM_DEBUG} python3 $REMOTE_DIR/scripts/verify-image.py" | tee "$EVIDENCE/build-host-verify-image.txt"

# --- Step 8: bake-prep, then register an AMI from the build host ---------------------------
log "Step 8/10: sanitize (scripts/50-bake-prep.sh) and register an AMI from $build_id"
run_ssm "$build_id" 1200 "$STAGE_ENV/50-bake-prep.sh"
AMI_NAME="${RESOURCE_PREFIX}-${RUN_ID}"
AMI_ID=$(aws ec2 create-image --region "$AWS_REGION" --instance-id "$build_id" \
  --name "$AMI_NAME" --no-reboot \
  --tag-specifications \
    "ResourceType=image,Tags=[{Key=Name,Value=$AMI_NAME},{$(ownership_tag_cli)},{Key=RunId,Value=$RUN_ID},{Key=BaseAmiSerial,Value=${BASE_AMI_SERIAL:-unknown}}]" \
    "ResourceType=snapshot,Tags=[{Key=Name,Value=$AMI_NAME},{$(ownership_tag_cli)},{Key=RunId,Value=$RUN_ID}]" \
  --query 'ImageId' --output text)
record AMI_ID "$AMI_ID"
log "AMI $AMI_ID registering; waiting until available"
aws ec2 wait image-available --region "$AWS_REGION" --image-ids "$AMI_ID"
log "AMI available: $AMI_ID"
log "terminating the build host $build_id (the AMI carries the image now)"
aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$build_id" >/dev/null
aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids "$build_id"

# --- Step 9: verify a SECOND fresh instance launched from the AMI, then tag it -------------
log "Step 9/10: fresh-instance verification on a SECOND instance, then tag BtfValidated=true on success (scripts/verify-fresh-instance.sh)"
AMI_ID="$AMI_ID" INSTANCE_PROFILE="$INSTANCE_PROFILE" SECURITY_GROUP_ID="$SECURITY_GROUP_ID" \
  SUBNET_ID="$BUILD_SUBNET_ID" bash "$SAMPLE_DIR/scripts/verify-fresh-instance.sh"

# --- Step 10: join the dedicated tainted node group, then apply the validation workloads ---
log "Step 10/10: join the dedicated tainted managed node group (scripts/join-nodegroup.sh)"
AMI_ID="$AMI_ID" NODE_ROLE_ARN="$NODE_ROLE_ARN" bash "$SAMPLE_DIR/scripts/join-nodegroup.sh"

NODEGROUP_NAME="${NODEGROUP_NAME:-${RESOURCE_PREFIX}-ng}"
# No sandbox pod before the node is Ready and advertises the extended resource the RuntimeClass
# overhead requests (eks.amazonaws.com/nitro-sandbox > 0).
KUBECTL="$KUBECTL" NODEGROUP_NAME="$NODEGROUP_NAME" bash "$SAMPLE_DIR/scripts/wait-node-ready.sh"
log "applying the validation workloads from deploy/ (rendering @NODEGROUP@ = $NODEGROUP_NAME, namespace $NAMESPACE)"
APPLY_TMP="$OUT_DIR/rendered"
mkdir -p "$APPLY_TMP"
for f in pod-ordinary.yaml pod-isolated-sandbox.yaml network-policy.yaml; do
  sed -e "s/@NODEGROUP@/$NODEGROUP_NAME/g" -e "s/^  namespace: ubuntu-ami-sample$/  namespace: $NAMESPACE/" \
    "$SAMPLE_DIR/deploy/$f" > "$APPLY_TMP/$f"
done
# Create the sample's namespace only if absent, and label it so clean.sh will own it. An
# existing namespace is used only when it already carries this sample's label.
if ! $KUBECTL get namespace "$NAMESPACE" >/dev/null 2>&1; then
  $KUBECTL create namespace "$NAMESPACE"
  $KUBECTL label namespace "$NAMESPACE" "app.kubernetes.io/part-of=$RESOURCE_PREFIX" >/dev/null
else
  ns_owner=$($KUBECTL get namespace "$NAMESPACE" -o "jsonpath={.metadata.labels.app\.kubernetes\.io/part-of}")
  [[ "$ns_owner" == "$RESOURCE_PREFIX" ]] || die "namespace $NAMESPACE exists and is not labelled app.kubernetes.io/part-of=$RESOURCE_PREFIX; set NAMESPACE to a new name"
fi
$KUBECTL apply -n "$NAMESPACE" -f "$APPLY_TMP/network-policy.yaml"
$KUBECTL apply -n "$NAMESPACE" -f "$APPLY_TMP/pod-ordinary.yaml"
$KUBECTL apply -n "$NAMESPACE" -f "$APPLY_TMP/pod-isolated-sandbox.yaml"

log "setup.sh complete. AMI=$AMI_ID, node group=$NODEGROUP_NAME. Run ./test.sh to read live evidence."
log "private run evidence: $EVIDENCE_ENV and $SUMMARY"
printf 'AMI_ID=%s\n' "$AMI_ID" > "$OUT_DIR/last-build.env"
