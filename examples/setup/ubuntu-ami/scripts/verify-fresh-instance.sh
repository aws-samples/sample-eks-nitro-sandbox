#!/usr/bin/env bash
# verify-fresh-instance.sh: run on a SECOND, fresh EC2 instance launched from the AMI that
# scripts/50-bake-prep.sh sanitized, reached over SSM (no inbound security-group rule).
# This is the "a second fresh instance passes the same host-readiness checks" acceptance
# criterion: it must not reuse the build host's own verification run.
#
#   AMI_ID=<ami-id> INSTANCE_PROFILE=<name> SECURITY_GROUP_ID=<sg-id> SUBNET_ID=<subnet-id> \
#     scripts/verify-fresh-instance.sh
#
# The checks' output is saved under $OUT_DIR/evidence (the repository's gitignored
# tmp/issue10/run/out/evidence by default), never in the sample folder.
#
# Launches the instance, waits for SSM to report it Online, runs scripts/verify-image.py and
# scripts/40-smoke.sh on it over SSM Run Command, then terminates it and waits for
# termination. The instance is tagged ManagedBy=<RESOURCE_PREFIX> like every other resource
# this sample creates, so clean.sh can find and remove it if this script is interrupted.
#
# BtfValidated=true contract (issue #11, Cilium on Ubuntu, reads this tag before trusting an
# AMI): this script is the ONE place that decides whether $AMI_ID earns that tag. It is
# applied, via scripts/lib/btf-tag.sh, ONLY after verify-image.py and 40-smoke.sh both PASS
# on this second, fresh instance below, never at create-image time, and never when either
# check fails. See scripts/lib/btf-tag.sh for the ownership check and the fail-closed
# decision logic, and scripts/test-btf-tag.sh for the clusterless proof of all three paths.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
. "$HERE/lib/btf-tag.sh"

: "${AMI_ID:?set AMI_ID to the sanitized AMI to verify}"
: "${INSTANCE_PROFILE:?set INSTANCE_PROFILE to the build instance profile name}"
: "${SECURITY_GROUP_ID:?set SECURITY_GROUP_ID to the build security group (no inbound rules)}"
: "${SUBNET_ID:?set SUBNET_ID to a private build subnet}"

NAME="${RESOURCE_PREFIX}-verify-$(date -u +%Y%m%dT%H%M%SZ)"
log "launching fresh verification instance $NAME from $AMI_ID"

instance_id=$(aws ec2 run-instances \
  --region "$AWS_REGION" \
  --image-id "$AMI_ID" \
  --instance-type "${VERIFY_INSTANCE_TYPE:-m8i.xlarge}" \
  --iam-instance-profile "Name=$INSTANCE_PROFILE" \
  --security-group-ids "$SECURITY_GROUP_ID" \
  --subnet-id "$SUBNET_ID" \
  --enclave-options Enabled=true \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{$(ownership_tag_cli)}]" \
    "ResourceType=volume,Tags=[{Key=Name,Value=$NAME},{$(ownership_tag_cli)}]" \
  --query 'Instances[0].InstanceId' --output text)
log "instance: $instance_id"
# Terminate the verification instance however this script exits (a failed check included), so
# a failure never leaves it running; clean.sh would still find it by its ManagedBy tag.
terminate_verify_instance() {
  [[ -n "${instance_id:-}" ]] || return 0
  log "terminating verification instance $instance_id"
  aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$instance_id" >/dev/null \
    && aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids "$instance_id" \
    || warn "could not confirm termination of $instance_id; run ./clean.sh --dry-run"
  instance_id=""
}
trap terminate_verify_instance EXIT

aws ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$instance_id"
for _ in $(seq 1 30); do
  state=$(aws ssm describe-instance-information --region "$AWS_REGION" \
    --filters "Key=InstanceIds,Values=$instance_id" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)
  [[ "$state" == "Online" ]] && break
  sleep 10
done
[[ "$state" == "Online" ]] || die "instance $instance_id never reported Online to SSM"

run_remote() { # run_remote <description> <command>
  local desc="$1" cmd="$2" cmd_id
  log "running: $desc"
  cmd_id=$(aws ssm send-command --region "$AWS_REGION" \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"$cmd\"]" \
    --query 'Command.CommandId' --output text)
  aws ssm wait command-executed --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$instance_id" || true
  aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$instance_id" \
    --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
}

# VERIFY_STATUS is the explicit, testable signal scripts/lib/btf-tag.sh keys the tagging
# decision on: "pass" only once both remote checks below actually reported success, "fail"
# the moment either one does not. It is never inferred from "the script reached the end
# without dying": a change here that removed a `die` would otherwise silently start tagging
# on unverified output.
VERIFY_STATUS=fail

EVIDENCE="${EVIDENCE_DIR:-$OUT_DIR/evidence}"
mkdir -p "$EVIDENCE"
run_remote "verify-image.py" "sudo python3 /usr/local/share/ubuntu-ami-sample/scripts/verify-image.py" \
  > "$EVIDENCE/fresh-instance-verify-image.txt"
cat "$EVIDENCE/fresh-instance-verify-image.txt"
status_line=$(head -n 1 "$EVIDENCE/fresh-instance-verify-image.txt")
[[ "$status_line" == Success* ]] || die "verify-image.py failed on the fresh instance"
# The containerd version the fresh instance booted with, for the run's private evidence.
fresh_containerd=$(grep -o 'containerd [0-9][^"]*supported by the GA shim[^"]*' "$EVIDENCE/fresh-instance-verify-image.txt" | head -n 1 || true)
printf 'FRESH_INSTANCE_CONTAINERD=%q\n' "${fresh_containerd:-<not read>}" >> "$EVIDENCE/run-evidence.env"

run_remote "40-smoke.sh" "sudo bash /usr/local/share/ubuntu-ami-sample/scripts/40-smoke.sh" \
  > "$EVIDENCE/fresh-instance-smoke.txt"
cat "$EVIDENCE/fresh-instance-smoke.txt"
smoke_line=$(head -n 1 "$EVIDENCE/fresh-instance-smoke.txt")
[[ "$smoke_line" == Success* ]] || die "40-smoke.sh failed on the fresh instance"

VERIFY_STATUS=pass

terminate_verify_instance
log "fresh-instance verification PASS"

# --- BtfValidated=true: applied here, and only here, now that VERIFY_STATUS=pass ----------
# btf_tag_ami_if_verified refuses (non-zero) on an AMI that does not carry this run's
# ManagedBy ownership tag, whatever VERIFY_STATUS says, and never tags when VERIFY_STATUS is
# not the literal string "pass". Safe immutable build metadata recorded alongside the tag:
# the kernel and erofs-utils versions this run pinned (from config.env / common.sh
# defaults, never invented), and a build-id timestamp matching this verification run's own
# instance name, so a reader can tell which verification run earned the tag.
btf_tag_ami_if_verified "$AMI_ID" "$VERIFY_STATUS" \
  "Key=KernelVersion,Value=${KERNEL_VERSION}" \
  "Key=ErofsUtilsVersion,Value=${EROFS_UTILS_VERSION}" \
  "Key=BtfValidatedBuildId,Value=${NAME}" \
  || die "BtfValidated=true was not applied to $AMI_ID; see the warning above"
