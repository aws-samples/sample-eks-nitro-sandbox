#!/usr/bin/env bash
# verify-fresh-instance.sh: run on a SECOND, fresh EC2 instance launched from the AMI that
# scripts/50-bake-prep.sh sanitized, reached over SSM (no inbound security-group rule).
# This is the "a second fresh instance passes the same host-readiness checks" acceptance
# criterion: it must not reuse the build host's own verification run.
#
#   AMI_ID=<ami-id> INSTANCE_PROFILE=<name> SECURITY_GROUP_ID=<sg-id> SUBNET_ID=<subnet-id> \
#     scripts/verify-fresh-instance.sh
#
# Launches the instance, waits for SSM to report it Online, runs scripts/verify-image.py and
# scripts/40-smoke.sh on it over SSM Run Command, then terminates it and waits for
# termination. The instance is tagged ManagedBy=<RESOURCE_PREFIX> like every other resource
# this sample creates, so clean.sh can find and remove it if this script is interrupted.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

: "${AMI_ID:?set AMI_ID to the sanitized AMI to verify}"
: "${INSTANCE_PROFILE:?set INSTANCE_PROFILE to the build instance profile name}"
: "${SECURITY_GROUP_ID:?set SECURITY_GROUP_ID to the build security group (no inbound rules)}"
: "${SUBNET_ID:?set SUBNET_ID to a private build subnet}"

NAME="${RESOURCE_PREFIX}-verify-$(date -u +%Y%m%dT%H%M%SZ)"
log "launching fresh verification instance $NAME from $AMI_ID"

instance_id=$(aws ec2 run-instances \
  --region "$AWS_REGION" \
  --image-id "$AMI_ID" \
  --instance-type "${BUILD_INSTANCE_TYPE:-m8i.xlarge}" \
  --iam-instance-profile "Name=$INSTANCE_PROFILE" \
  --security-group-ids "$SECURITY_GROUP_ID" \
  --subnet-id "$SUBNET_ID" \
  --enclave-options Enabled=true \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{$(ownership_tag_cli)}]" \
    "ResourceType=volume,Tags=[{Key=Name,Value=$NAME},{$(ownership_tag_cli)}]" \
  --query 'Instances[0].InstanceId' --output text)
log "instance: $instance_id"

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

status_line=$(run_remote "verify-image.py" "sudo python3 /usr/local/share/ubuntu-ami-sample/verify-image.py" | head -1)
echo "$status_line"
[[ "$status_line" == Success* ]] || die "verify-image.py failed on the fresh instance"

smoke_line=$(run_remote "40-smoke.sh" "sudo bash /usr/local/share/ubuntu-ami-sample/40-smoke.sh" | head -1)
echo "$smoke_line"
[[ "$smoke_line" == Success* ]] || die "40-smoke.sh failed on the fresh instance"

log "terminating verification instance $instance_id"
aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$instance_id" >/dev/null
aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids "$instance_id"
log "fresh-instance verification PASS; instance $instance_id terminated"
