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
#   ./setup.sh --ami-only    # steps 1 to 9 only: build, verify and tag the AMI; no cluster read,
#                            #   no node group (issue #11 needs only the AMI). Records AMI_ID in
#                            #   the run's run-state.env.
#   RUN_ID=<id> ./setup.sh --join
#                            # step 10 only, for a run whose AMI is built: checks the AMI carries
#                            #   both run tags and BtfValidated=true, the kube context and the
#                            #   cluster prerequisites, then joins. It never rebuilds.
#
# Waits are bounded polls (scripts/lib/aws-wait.sh), not the AWS CLI waiters, whose caps
# (about 100 s for an SSM command, 600 s for an AMI) are shorter than the kernel build and the
# AMI snapshot. After the reboot onto the new kernel, the build host must answer with a new boot
# id and the new kernel release before the next stage runs.
#
# This script does not SSH anywhere: the build host is reached through AWS Systems Manager Run
# Command, and the build security group carries no inbound rule. Files reach the build host
# through a per-run S3 staging bucket (scripts/00b-stage-bucket.sh), never through an SSM shell.
# The local preflight STOPS (exit 3) with the documented prerequisite when the operator-supplied
# runtime archive is not present; it never substitutes an internal source tree or a private URL.
#
# Private run evidence (the resolved base AMI and its serial, the observed containerd version,
# each stage's output) is written under $OUT_DIR/runs/<run-id>/evidence, the repository's
# gitignored tmp/issue10/run/out/runs/<run-id>/evidence by default, never in the sample folder.
# The run id is recorded in $OUT_DIR/run-state.env for test.sh and clean.sh.
set -euo pipefail
SAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SAMPLE_DIR/scripts/lib/common.sh"
# shellcheck source=scripts/lib/aws-wait.sh
. "$SAMPLE_DIR/scripts/lib/aws-wait.sh"

PREPARE_ONLY=0
MODE=full
for arg in "$@"; do
  case "$arg" in
    --prepare|--dry-run) PREPARE_ONLY=1 ;;
    --ami-only) [ "$MODE" = full ] || die "--ami-only and --join go alone"; MODE=ami ;;
    --join) [ "$MODE" = full ] || die "--ami-only and --join go alone"; MODE=join ;;
    *) die "unknown argument: $arg (supported: --prepare, --dry-run, --ami-only, --join)" ;;
  esac
done
[[ "$PREPARE_ONLY" == 0 || "$MODE" == full ]] || die "--prepare goes alone"

command -v aws >/dev/null 2>&1 || die "aws CLI v2 is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v session-manager-plugin >/dev/null 2>&1 || warn "session-manager-plugin not found; required to reach the build host interactively"

# One run id names and tags everything this run creates (scripts/lib/common.sh derive_run_names).
# A new run gets a fresh one; RUN_ID=<id> ./setup.sh resumes that run, and every reuse then checks
# both tags first. A new id is a UTC timestamp plus random hex (new_run_id), and its run folder is
# reserved with a plain mkdir, so two starts in the same second cannot share one. The id becomes
# the current run in $RUN_STATE_FILE (what clean.sh and test.sh act on) only just before the
# first AWS change, so a run that stops on a read-only check never replaces the previous one.
if [ -n "${RUN_ID:-}" ]; then RESUME=1; else RUN_ID=$(new_run_id); RESUME=0; fi
[[ "$MODE" != join || "$RESUME" == 1 ]] || die "--join needs RUN_ID=<id>, the run whose AMI ./setup.sh --ami-only built (it prints the id)"
export RUN_ID
derive_run_names

# Private run evidence, under the run's folder in the repository's tmp/.
open_evidence() { # open_evidence <new|append>
  EVIDENCE="$EVIDENCE_DIR"
  export EVIDENCE_DIR
  mkdir -p "$EVIDENCE"
  EVIDENCE_ENV="$EVIDENCE/run-evidence.env"
  SUMMARY="$EVIDENCE/summary.txt"
  [ "$1" = append ] || { : > "$EVIDENCE_ENV"; : > "$SUMMARY"; }
}
record() { printf '%s=%q\n' "$1" "$2" >> "$EVIDENCE_ENV"; printf '%s: %s\n' "$1" "$2" >> "$SUMMARY"; }

# --- Step 10, shared by the full run and --join: the dedicated tainted node group, then the
# --- validation workloads. Needs AMI_ID and NODE_ROLE_ARN.
join_and_apply() {
  log "Step 10/10: join the dedicated tainted managed node group (scripts/join-nodegroup.sh)"
  AMI_ID="$AMI_ID" NODE_ROLE_ARN="$NODE_ROLE_ARN" bash "$SAMPLE_DIR/scripts/join-nodegroup.sh"
  # No sandbox pod before the node is Ready and advertises the extended resource the RuntimeClass
  # overhead requests (eks.amazonaws.com/nitro-sandbox > 0).
  bash "$SAMPLE_DIR/scripts/wait-node-ready.sh"
  log "applying the validation workloads from deploy/ (rendering @NODEGROUP@ = $NODEGROUP_NAME, namespace $NAMESPACE)"
  local f apply_tmp="$RUN_STATE_DIR/rendered"
  mkdir -p "$apply_tmp"
  for f in pod-ordinary.yaml pod-isolated-sandbox.yaml network-policy.yaml; do
    sed -e "s/@NODEGROUP@/$NODEGROUP_NAME/g" -e "s/^  namespace: ubuntu-ami-sample$/  namespace: $NAMESPACE/" \
      "$SAMPLE_DIR/deploy/$f" > "$apply_tmp/$f"
  done
  # The sample's namespace: created (with both labels) only when absent, reused only when it
  # carries app.kubernetes.io/part-of=$RESOURCE_PREFIX and app.kubernetes.io/instance=$RUN_ID; a
  # failed lookup stops the run (scripts/ensure-namespace.sh).
  bash "$SAMPLE_DIR/scripts/ensure-namespace.sh"
  kc apply -n "$NAMESPACE" -f "$apply_tmp/network-policy.yaml"
  kc apply -n "$NAMESPACE" -f "$apply_tmp/pod-ordinary.yaml"
  kc apply -n "$NAMESPACE" -f "$apply_tmp/pod-isolated-sandbox.yaml"
  log "setup.sh complete. AMI=$AMI_ID, node group=$NODEGROUP_NAME. Run ./test.sh to read live evidence."
  log "private run evidence: $EVIDENCE_ENV and $SUMMARY"
  log "run $RUN_ID recorded in $RUN_STATE_FILE; ./test.sh and ./clean.sh act on it"
}

# --- --join: step 10 only, for a run whose AMI is already built and verified ----------------
# It reads the AMI the run recorded and changes nothing until that AMI carries both run tags
# and BtfValidated=true, the kube context is CLUSTER_NAME, and the cluster prerequisites hold.
if [ "$MODE" = join ]; then
  : "${NODE_SUBNET_IDS:?set NODE_SUBNET_IDS in config.env (space-separated private subnets)}"
  [ -f "$RUN_STATE_DIR/run-state.env" ] || die "run $RUN_ID has no run state at $RUN_STATE_DIR/run-state.env; build its AMI first with ./setup.sh --ami-only"
  AMI_ID=$(sed -n 's/^AMI_ID=//p' "$RUN_STATE_DIR/run-state.env" | tail -n 1 || true)
  [[ "$AMI_ID" =~ ^ami-[0-9a-f]+$ ]] || die "run $RUN_ID has no AMI_ID in $RUN_STATE_DIR/run-state.env; --join never builds one (./setup.sh --ami-only does)"
  [ -f "$RUN_STATE_DIR/iam.env" ] || die "run $RUN_ID has no $RUN_STATE_DIR/iam.env (its node role); build its AMI first with ./setup.sh --ami-only"
  # shellcheck source=/dev/null
  . "$RUN_STATE_DIR/iam.env"
  [[ "${NODE_ROLE_ARN:-}" == arn:aws*:iam::*:role/"$NODE_ROLE_NAME" ]] || die "run $RUN_ID's iam.env names no node role $NODE_ROLE_NAME"
  log "--join: run $RUN_ID, AMI $AMI_ID"
  ami_json=$(aws ec2 describe-images --region "$AWS_REGION" --image-ids "$AMI_ID" --output json) \
    || die "could not determine whether AMI $AMI_ID is this run's verified AMI (describe-images failed); nothing was changed"
  printf '%s' "$ami_json" | json_pick 'd["Images"][0].get("Tags", []) if d.get("Images") else []' | tags_match \
    || die "AMI $AMI_ID does not carry ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} and ${TAGS_RUN_KEY}=${RUN_ID}; --join refuses an AMI this run did not build. Nothing was changed."
  btf=$(printf '%s' "$ami_json" | json_get 'next((t["Value"] for t in (d["Images"][0].get("Tags", []) if d.get("Images") else []) if t["Key"] == "BtfValidated"), "")')
  [ "$btf" = true ] || die "AMI $AMI_ID does not carry BtfValidated=true: no fresh instance from it has passed verification, so --join will not join it. Nothing was changed."
  require_kube_context
  open_evidence append
  log "checking the cluster-wide prerequisites (scripts/00c-check-cluster.sh, read only)"
  bash "$SAMPLE_DIR/scripts/00c-check-cluster.sh"
  printf 'RUN_ID=%s\n' "$RUN_ID" > "$RUN_STATE_FILE"
  log "current run is now $RUN_ID (recorded in $RUN_STATE_FILE)"
  join_and_apply
  exit 0
fi

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
[ "$MODE" = ami ] || : "${NODE_SUBNET_IDS:?set NODE_SUBNET_IDS in config.env (space-separated private subnets)}"

# --- The cluster kubectl will talk to: KUBE_CONTEXT, checked against CLUSTER_NAME ----------
# Every kubectl call below passes --context "$KUBE_CONTEXT"; this stops unless that context's
# server is CLUSTER_NAME's API endpoint, before anything is created anywhere. --ami-only skips
# it: steps 1 to 9 never read or change the cluster (no kubectl call, no EKS call).
[ "$MODE" = ami ] || require_kube_context

if [ "$RESUME" = 1 ]; then mkdir -p "$RUN_STATE_DIR"; else reserve_run_dir; fi
printf 'RUN_ID=%s\nRESOURCE_PREFIX=%s\nNODEGROUP_NAME=%s\nNAMESPACE=%s\n' "$RUN_ID" "$RESOURCE_PREFIX" "$NODEGROUP_NAME" "$NAMESPACE" > "$RUN_STATE_DIR/run-state.env"
open_evidence new
record RUN_ID "$RUN_ID"

# --- Cluster-wide prerequisites, read only, before anything is created ---------------------
# The managed vpc-cni add-on with network policy on, and the shared isolated-sandbox
# RuntimeClass. Both are the reader's; this run checks them and stops with the command to run.
# --ami-only skips them: only the node group (step 10, ./setup.sh --join) needs them.
if [ "$MODE" = full ]; then
  log "checking the cluster-wide prerequisites (scripts/00c-check-cluster.sh, read only)"
  bash "$SAMPLE_DIR/scripts/00c-check-cluster.sh"
fi

# ---- From here on, real AWS mutation. Everything created is tagged ManagedBy=$RESOURCE_PREFIX
# ---- and RunId=$RUN_ID, so clean.sh can find and remove this run's resources, and only them,
# ---- even if this run is interrupted.

# Every read-only check passed: this run becomes the current one, just before its first change.
printf 'RUN_ID=%s\n' "$RUN_ID" > "$RUN_STATE_FILE"
log "current run is now $RUN_ID (recorded in $RUN_STATE_FILE)"

# --- Step 2: scoped IAM roles + build-host instance profile --------------------------------
log "Step 2/10: create this run's scoped IAM roles and the build-host instance profile (scripts/00a-iam.sh)"
bash "$SAMPLE_DIR/scripts/00a-iam.sh"
IAM_ENV="$RUN_STATE_DIR/iam.env"
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
STAGE_TARBALL="$RUN_STATE_DIR/ubuntu-ami-sample-${RUN_ID}.tar.gz"
(cd "$SAMPLE_DIR" && tar -czf "$STAGE_TARBALL" scripts packages manifests deploy config.env.example)
TARBALL_SHA=$(sha256sum "$STAGE_TARBALL" | awk '{print $1}')
ZIP_SHA=$(lock_field runtime-archive sha256)
bash "$SAMPLE_DIR/scripts/00b-stage-bucket.sh" create "$STAGE_TARBALL" "$RUNTIME_ZIP"
# shellcheck source=/dev/null
. "$RUN_STATE_DIR/stage.env"
# Until the revocation in step 6, any exit revokes the staged objects and the build role's read.
arm_staging_revoke "$STAGE_BUCKET" "$(basename "$STAGE_TARBALL")" "$(basename "$RUNTIME_ZIP")"
record STAGE_BUCKET "$STAGE_BUCKET"

# --- Step 5: build security group (no inbound rule) and the build host, reached via SSM ----
log "Step 5/10: this run's build security group $SG_NAME (no inbound rule) + launch the build host over SSM"
VPC_ID=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$BUILD_SUBNET_ID" \
  --query 'Subnets[0].VpcId' --output text)
# Look the group up by its per-run name; reuse it only when it carries both run tags.
sg_json=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" --output json) \
  || die "could not determine whether security group $SG_NAME exists (lookup failed)"
SECURITY_GROUP_ID=$(printf '%s' "$sg_json" | json_get '[g["GroupId"] for g in d["SecurityGroups"]]' | head -n 1)
if [[ -z "$SECURITY_GROUP_ID" ]]; then
  SECURITY_GROUP_ID=$(aws ec2 create-security-group --region "$AWS_REGION" \
    --group-name "$SG_NAME" --vpc-id "$VPC_ID" \
    --description "ubuntu-ami sample build host; NO inbound rule by design (SSM only)" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},$(run_tags_cli)]" \
    --query 'GroupId' --output text)
  log "created build security group $SECURITY_GROUP_ID with no inbound rule (SSM-only access)"
else
  printf '%s' "$sg_json" | json_pick 'd["SecurityGroups"][0].get("Tags", [])' | tags_match \
    || die "security group $SG_NAME ($SECURITY_GROUP_ID) exists but does not carry ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} and ${TAGS_RUN_KEY}=${RUN_ID}; refusing to reuse it"
  log "reusing this run's build security group $SECURITY_GROUP_ID"
fi
inbound=$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$SECURITY_GROUP_ID" \
  --query 'length(SecurityGroups[0].IpPermissions)' --output text)
[[ "$inbound" == 0 ]] || die "build security group $SECURITY_GROUP_ID has $inbound inbound rule(s); this sample needs none"

log "launching build host $BUILD_NAME from $BASE_AMI_ID (type ${BUILD_INSTANCE_TYPE:-m8i.4xlarge}, ${BUILD_ROOT_VOLUME_GB:-120} GiB root)"
BUILD_SPEC="$RUN_STATE_DIR/build-host-launch.json"
launch_spec render-instance --name "$BUILD_NAME" --image-id "$BASE_AMI_ID" --instance-type "${BUILD_INSTANCE_TYPE:-m8i.4xlarge}" \
  --profile "$INSTANCE_PROFILE" --security-group "$SECURITY_GROUP_ID" --subnet "$BUILD_SUBNET_ID" \
  --root-gb "${BUILD_ROOT_VOLUME_GB:-120}" > "$BUILD_SPEC"
launch_spec check-instance "$BUILD_SPEC" || die "the build host launch spec $BUILD_SPEC failed its check"
build_id=$(aws ec2 run-instances --region "$AWS_REGION" --cli-input-json "file://$BUILD_SPEC" \
  --query 'Instances[0].InstanceId' --output text)
record BUILD_INSTANCE_ID "$build_id"
log "build host: $build_id; waiting for status-ok and SSM Online"
wait_status_ok "$build_id" || die "build host $build_id never reached status-ok"
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
# document, print its output, and fail unless it reports Success. The result is polled until it
# is final or <timeout> + SSM_WAIT_MARGIN has passed (scripts/lib/aws-wait.sh ssm_run).
send_and_wait() {
  local id="$1" timeout="$2" doc="$3" params="$4" rc=0
  ssm_run "$id" "$timeout" "$doc" "$params" || rc=$?
  [ -z "$SSM_STDOUT" ] || printf '%s\n' "$SSM_STDOUT" | sed 's/^/  [build] /'
  if [ "$rc" -ne 0 ]; then
    [ -z "$SSM_STDERR" ] || printf '%s\n' "$SSM_STDERR" | sed 's/^/  [build:stderr] /' >&2
    [ "$rc" = 1 ] && die "SSM $doc failed on $id (status $SSM_STATUS)"
    die "SSM $doc on $id: its result could not be determined ($SSM_STATUS); see the warning above"
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
# Fails (and so stops this run) unless the staged objects and the build role's read are
# confirmed gone; any residue is recorded in $RUN_STATE_DIR/stage-residue.txt.
disarm_staging_revoke
bash "$SAMPLE_DIR/scripts/00b-stage-bucket.sh" revoke "$STAGE_BUCKET" \
  "$(basename "$STAGE_TARBALL")" "$(basename "$RUNTIME_ZIP")"

# --- Step 7: run the numbered build stages on the build host, in order ---------------------
log "Step 7/10: run the build stages on $build_id in order (00 -> 10 -> reboot -> 00 -> 20 -> 30 -> 31 -> 35 -> 36 -> 40 -> verify-image)"
STAGE_ENV="sudo ISSUE10_RUN_DIR=$HOST_BASE/run RUNTIME_ARTIFACTS_DIR=$HOST_BASE/run/runtime SHIM_DEBUG=${SHIM_DEBUG} STAGE_DIR=$HOST_STAGE bash $REMOTE_DIR/scripts"
run_ssm "$build_id" 1800 "$STAGE_ENV/00-preflight.sh" | tee "$EVIDENCE/build-host-preflight-1.txt"
build_containerd=$(sed -n 's/^  \[build\] CONTAINERD_VERDICT=//p' "$EVIDENCE/build-host-preflight-1.txt" | head -n 1)
record BUILD_HOST_CONTAINERD "${build_containerd:-<not read>}"
run_ssm "$build_id" 7200 "$STAGE_ENV/10-kernel.sh" | tee "$EVIDENCE/build-host-kernel.txt"
# The reboot is confirmed by the host itself, not by SSM's Online ping (which can still be the one
# from before the reboot): a fresh command must answer with a new boot id and the new kernel.
KREL="${KERNEL_VERSION}${KERNEL_LOCALVERSION}"
read_boot_info "$build_id" 120 || die "could not read the build host's boot id before the reboot ($SSM_STATUS)"
record BUILD_HOST_BOOT_ID_BEFORE "$BOOT_ID"
log "rebooting build host onto the new kernel $KREL (boot id before: $BOOT_ID)"
aws ec2 reboot-instances --region "$AWS_REGION" --instance-ids "$build_id"
wait_rebooted "$build_id" "$BOOT_ID" "$KREL" || die "build host $build_id did not come back on kernel $KREL within ${REBOOT_WAIT_SECONDS} s (see the warning above)"
record BUILD_HOST_BOOT_ID_AFTER "$BOOT_ID"
record BUILD_HOST_KERNEL_AFTER_REBOOT "$BOOT_KERNEL"
log "build host rebooted: boot id $BOOT_ID, kernel $BOOT_KERNEL"
run_ssm "$build_id" 1800 "$STAGE_ENV/00-preflight.sh --after-reboot" | tee "$EVIDENCE/build-host-preflight-2.txt"   # the enclave checks are enforced now
run_ssm "$build_id" 1800 "$STAGE_ENV/20-erofs-utils.sh"
run_ssm "$build_id" 1800 "$STAGE_ENV/30-runtime-install.sh"
run_ssm "$build_id" 600  "$STAGE_ENV/31-wire-containerd.sh"
run_ssm "$build_id" 600  "$STAGE_ENV/35-apparmor.sh"
run_ssm "$build_id" 600  "$STAGE_ENV/36-hold-packages.sh"
run_ssm "$build_id" 900  "$STAGE_ENV/40-smoke.sh" | tee "$EVIDENCE/build-host-smoke.txt"
run_ssm "$build_id" 600  "sudo SHIM_DEBUG=${SHIM_DEBUG} python3 $REMOTE_DIR/scripts/verify-image.py" | tee "$EVIDENCE/build-host-verify-image.txt"

# --- Step 8: bake-prep, then register an AMI from the build host ---------------------------
log "Step 8/10: sanitize (scripts/50-bake-prep.sh) and register an AMI from $build_id"
run_ssm "$build_id" 1200 "$STAGE_ENV/50-bake-prep.sh"
AMI_ID=$(aws ec2 create-image --region "$AWS_REGION" --instance-id "$build_id" \
  --name "$AMI_NAME" --no-reboot \
  --tag-specifications \
    "ResourceType=image,Tags=[{Key=Name,Value=$AMI_NAME},$(run_tags_cli),{Key=BaseAmiSerial,Value=${BASE_AMI_SERIAL:-unknown}}]" \
    "ResourceType=snapshot,Tags=[{Key=Name,Value=$AMI_NAME},$(run_tags_cli)]" \
  --query 'ImageId' --output text)
record AMI_ID "$AMI_ID"
log "AMI $AMI_ID registering; waiting until available (up to AMI_WAIT_SECONDS=${AMI_WAIT_SECONDS})"
wait_image_available "$AMI_ID" || die "AMI $AMI_ID did not become available (see the warning above); the build host $build_id is still running: ./clean.sh --dry-run lists both"
log "AMI available: $AMI_ID"
log "terminating the build host $build_id (the AMI carries the image now)"
aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$build_id" >/dev/null
aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids "$build_id"

# --- Step 9: verify a SECOND fresh instance launched from the AMI, then tag it -------------
log "Step 9/10: fresh-instance verification on a SECOND instance, then tag BtfValidated=true on success (scripts/verify-fresh-instance.sh)"
AMI_ID="$AMI_ID" INSTANCE_PROFILE="$INSTANCE_PROFILE" SECURITY_GROUP_ID="$SECURITY_GROUP_ID" \
  SUBNET_ID="$BUILD_SUBNET_ID" bash "$SAMPLE_DIR/scripts/verify-fresh-instance.sh"
# The verified AMI, for --join and for clean.sh --keep-ami.
printf 'AMI_ID=%s\n' "$AMI_ID" >> "$RUN_STATE_DIR/run-state.env"

if [ "$MODE" = ami ]; then
  log "--ami-only: done. AMI $AMI_ID is verified and tagged BtfValidated=true; no node group was created."
  log "private run evidence: $EVIDENCE_ENV and $SUMMARY"
  log "join it later with: RUN_ID=$RUN_ID ./setup.sh --join   (keep the AMI on clean up: ./clean.sh --run-id $RUN_ID --delete-aws-resources --keep-ami)"
  exit 0
fi

# --- Step 10: join the dedicated tainted node group, then apply the validation workloads ---
join_and_apply
