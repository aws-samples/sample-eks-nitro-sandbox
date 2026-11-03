#!/usr/bin/env bash
# verify-fresh-instance.sh: run on a SECOND, fresh EC2 instance launched from the AMI that
# scripts/50-bake-prep.sh sanitized, reached over SSM (no inbound security-group rule).
# This is the "a second fresh instance passes the same host-readiness checks" acceptance
# criterion: it must not reuse the build host's own verification run.
#
#   RUN_ID=<run-id> AMI_ID=<ami-id> SECURITY_GROUP_ID=<sg-id> SUBNET_ID=<subnet-id> \
#     scripts/verify-fresh-instance.sh
#
# The checks' output is saved under $EVIDENCE_DIR (the run's evidence folder in the repository's
# gitignored tmp/), never in the sample folder.
#
# Launches the instance (IMDSv2 required, hop limit 1, enclaves on; tagged ManagedBy and RunId on
# the instance and its volume, from a spec scripts/lib/launch_spec.py renders and checks), waits
# for SSM to report it Online, runs scripts/verify-image.py and scripts/40-smoke.sh on it over SSM
# Run Command, then terminates it and waits for termination, on success and on failure alike.
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
. "$HERE/lib/aws-wait.sh"
# Each remote check's executionTimeout; its result is polled until final or this plus
# SSM_WAIT_MARGIN (scripts/lib/aws-wait.sh), never through the 100 s command-executed waiter.
: "${VERIFY_REMOTE_TIMEOUT:=1800}"

: "${AMI_ID:?set AMI_ID to the sanitized AMI to verify}"
: "${SECURITY_GROUP_ID:?set SECURITY_GROUP_ID to the build security group (no inbound rules)}"
: "${SUBNET_ID:?set SUBNET_ID to a private build subnet}"
require_run_id   # names (INSTANCE_PROFILE, VERIFY_NAME) and both run tags come from the run id

NAME="$VERIFY_NAME"
log "launching fresh verification instance $NAME from $AMI_ID"
# The launch spec is rendered to a file, checked (IMDSv2 required with hop limit 1, enclaves on,
# ManagedBy and RunId on the instance and its volume), and that same file is what EC2 receives.
mkdir -p "$RUN_STATE_DIR"
SPEC="$RUN_STATE_DIR/verify-instance-launch.json"
launch_spec render-instance --name "$NAME" --image-id "$AMI_ID" --instance-type "${VERIFY_INSTANCE_TYPE:-m8i.xlarge}" \
  --profile "$INSTANCE_PROFILE" --security-group "$SECURITY_GROUP_ID" --subnet "$SUBNET_ID" > "$SPEC"
launch_spec check-instance "$SPEC" || die "the verification instance launch spec $SPEC failed its check"
instance_id=$(aws ec2 run-instances --region "$AWS_REGION" --cli-input-json "file://$SPEC" --output json \
  | json_get 'd["Instances"][0]["InstanceId"]')
[[ -n "$instance_id" ]] || die "run-instances returned no instance id"
log "instance: $instance_id"
# Terminate the verification instance however this script exits (a failed check included), so
# a failure never leaves it running; clean.sh would still find it by its ManagedBy and RunId tags.
# Returns 0 only once termination is confirmed; otherwise it keeps instance_id, so the exit trap
# tries again, and returns 1.
terminate_verify_instance() {
  [[ -n "${instance_id:-}" ]] || return 0
  log "terminating verification instance $instance_id"
  if aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$instance_id" --output json >/dev/null \
     && aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids "$instance_id"; then
    instance_id=""
    return 0
  fi
  warn "could not confirm termination of $instance_id; run ./clean.sh --dry-run"
  return 1
}
trap 'terminate_verify_instance || true' EXIT

wait_status_ok "$instance_id" || die "verification instance $instance_id never reached status-ok"
state=""
for _ in $(seq 1 "${SSM_ONLINE_TRIES:-30}"); do
  state=$(aws ssm describe-instance-information --region "$AWS_REGION" \
    --filters "Key=InstanceIds,Values=$instance_id" --output json 2>/dev/null \
    | json_get 'd["InstanceInformationList"][0]["PingStatus"] if d["InstanceInformationList"] else ""' 2>/dev/null || true)
  [[ "$state" == "Online" ]] && break
  sleep "${SSM_POLL_SECONDS:-10}"
done
[[ "$state" == "Online" ]] || die "instance $instance_id never reported Online to SSM"

run_remote() { # run_remote <description> <command>: prints the invocation's final Status line, then its output
  local desc="$1" cmd="$2"
  log "running: $desc" >&2
  # ssm_run polls until the command is final; a status that never becomes final, or reads that
  # keep failing, end as "could not determine", which is not "Success".
  ssm_run "$instance_id" "$VERIFY_REMOTE_TIMEOUT" AWS-RunShellScript "$(ssm_shell_params "$cmd" "$VERIFY_REMOTE_TIMEOUT")" || true
  printf '%s\n%s\n%s\n' "${SSM_STATUS:-could not determine}" "$SSM_STDOUT" "$SSM_STDERR"
}

# VERIFY_STATUS is the explicit, testable signal scripts/lib/btf-tag.sh keys the tagging
# decision on: "pass" only once both remote checks below actually reported success, "fail"
# the moment either one does not. It is never inferred from "the script reached the end
# without dying": a change here that removed a `die` would otherwise silently start tagging
# on unverified output.
VERIFY_STATUS=fail

EVIDENCE="$EVIDENCE_DIR"
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

# The AMI is marked only once its verification instance is confirmed gone.
terminate_verify_instance || die "verification instance $instance_id was not confirmed terminated; BtfValidated=true was not applied"
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
