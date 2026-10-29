# aws-wait.sh: bounded polls for the waits this sample's steps outlast. Sourced after common.sh
# by setup.sh and scripts/verify-fresh-instance.sh, on the operator's workstation.
#
# The AWS CLI waiters stop after a fixed number of attempts (AWS CLI 2.38.0, botocore
# data/ssm/2014-11-06/waiters-2.json and data/ec2/2016-11-15/waiters-2.json):
#   ssm wait command-executed   5 s x 20 attempts, about 100 s
#   ec2 wait image-available    15 s x 40 attempts, 600 s
#   ec2 wait instance-status-ok 15 s x 40 attempts, 600 s
# A kernel build runs for up to two hours and a 120 GiB snapshot can take longer than ten
# minutes, so these polls read the state themselves until it is final or a deadline passes.
# A read that fails is retried AWS_READ_RETRIES times in a row, then the poll gives up with
# "could not determine", which the callers treat as a failure.
: "${AWS_READ_RETRIES:=5}"       # consecutive failed reads before "could not determine"
: "${SSM_POLL_SECONDS:=15}"      # between reads of a command's invocation
: "${SSM_WAIT_MARGIN:=300}"      # seconds past a command's executionTimeout before giving up
: "${AMI_WAIT_SECONDS:=3600}"    # how long a new AMI may stay pending (config.env)
: "${AMI_POLL_SECONDS:=15}"
: "${REBOOT_WAIT_SECONDS:=1200}" # how long the build host may take to come back on the new kernel
: "${REBOOT_POLL_SECONDS:=20}"
: "${STATUS_OK_ROUNDS:=3}"       # instance-status-ok waiter runs (600 s each) before giving up

# poll_until <what> <deadline-seconds> <interval-seconds> <probe> [args...]
#   Runs <probe> until it answers 0 (done) or 1 (failed for good), at most until the deadline.
#   The probe returns 10 for "not yet" and anything else for a failed read; it may set POLL_STATE
#   for the messages. Returns 0, 1, or 2 for "could not determine" (the deadline passed, or more
#   than AWS_READ_RETRIES reads in a row failed).
poll_until() {
  local what="$1" limit="$2" every="$3" end errs=0 rc
  shift 3
  end=$((SECONDS + limit))
  POLL_STATE=""
  while :; do
    rc=0; "$@" || rc=$?
    case "$rc" in
      0) return 0 ;;
      1) warn "$what: ${POLL_STATE:-failed}"; return 1 ;;
      10) errs=0 ;;
      *) errs=$((errs + 1))
         if [ "$errs" -gt "$AWS_READ_RETRIES" ]; then
           warn "could not determine $what: $errs reads in a row failed (last: ${POLL_STATE:-no answer})"
           return 2
         fi ;;
    esac
    if [ "$SECONDS" -ge "$end" ]; then
      warn "could not determine $what: still ${POLL_STATE:-unknown} after ${limit} s"
      return 2
    fi
    sleep "$every"
  done
}

# --- SSM Run Command ---------------------------------------------------------------------------
# ssm_shell_params <command> <timeout-seconds>: AWS-RunShellScript parameters as JSON.
ssm_shell_params() {
  python3 -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]], "executionTimeout": [sys.argv[2]]}))' "$1" "$2"
}
# _aws_read <var> <aws args...>: the call's stdout in <var>; on failure POLL_STATE names the error.
_aws_read() {
  local __v="$1" e out; shift
  e=$(mktemp)
  if out=$(aws "$@" 2>"$e"); then rm -f "$e"; printf -v "$__v" '%s' "$out"; return 0; fi
  POLL_STATE="read failed: $(grep . "$e" | tail -n 1)"; rm -f "$e"; return 1
}
_ssm_probe() { # _ssm_probe <command-id> <instance-id>: one get-command-invocation read
  local js st
  _aws_read js ssm get-command-invocation --region "$AWS_REGION" --command-id "$1" --instance-id "$2" --output json || return 3
  st=$(printf '%s' "$js" | json_get 'd["Status"]' 2>/dev/null) || { POLL_STATE="unreadable invocation"; return 3; }
  POLL_STATE="$st"
  case "$st" in
    Success) SSM_INVOCATION="$js"; return 0 ;;
    Failed|Cancelled|TimedOut|Undeliverable|Terminated) SSM_INVOCATION="$js"; POLL_STATE="status $st"; return 1 ;;
    Pending|InProgress|Delayed|Cancelling) return 10 ;;
    *) POLL_STATE="unknown status '$st'"; return 3 ;;
  esac
}
# ssm_run <instance-id> <timeout-seconds> <document> <parameters-json> [margin-seconds]
#   Sends the command (delivery timeout <timeout>) and polls its invocation until it is final,
#   or until <timeout> + margin (default SSM_WAIT_MARGIN) has passed. Sets SSM_STATUS,
#   SSM_STDOUT and SSM_STDERR; returns 0 for Success, 1 for a failed final status, 2 when the
#   result could not be determined (send failed, deadline, or repeated read errors).
ssm_run() {
  local iid="$1" t="$2" doc="$3" params="$4" margin="${5:-$SSM_WAIT_MARGIN}" cid rc=0
  SSM_STATUS="" SSM_STDOUT="" SSM_STDERR="" SSM_INVOCATION=""
  cid=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$iid" --document-name "$doc" \
          --timeout-seconds "$t" --parameters "$params" --output json | json_get 'd["Command"]["CommandId"]') \
    && [ -n "$cid" ] || { SSM_STATUS="send-command failed"; return 2; }
  poll_until "SSM command $cid ($doc) on $iid" "$((t + margin))" "$SSM_POLL_SECONDS" _ssm_probe "$cid" "$iid" || rc=$?
  if [ -n "$SSM_INVOCATION" ]; then
    SSM_STATUS=$(printf '%s' "$SSM_INVOCATION" | json_get 'd["Status"]')
    SSM_STDOUT=$(printf '%s' "$SSM_INVOCATION" | json_get 'd.get("StandardOutputContent", "")')
    SSM_STDERR=$(printf '%s' "$SSM_INVOCATION" | json_get 'd.get("StandardErrorContent", "")')
  else
    SSM_STATUS="could not determine (${POLL_STATE:-no answer})"
  fi
  return "$rc"
}

# --- AMI ---------------------------------------------------------------------------------------
_image_probe() { # _image_probe <ami-id>
  local js st
  _aws_read js ec2 describe-images --region "$AWS_REGION" --image-ids "$1" --output json || return 3
  st=$(printf '%s' "$js" | json_get 'd["Images"][0]["State"]' 2>/dev/null) && [ -n "$st" ] \
    || { POLL_STATE="no state for $1"; return 3; }
  POLL_STATE="$st"
  case "$st" in
    available) return 0 ;;
    pending|transient) return 10 ;;
    *) POLL_STATE="AMI $1 is $st: $(printf '%s' "$js" | json_get 'd["Images"][0].get("StateReason", {}).get("Message", "no reason given")')"
       return 1 ;;
  esac
}
# wait_image_available <ami-id>: poll its State every AMI_POLL_SECONDS for up to AMI_WAIT_SECONDS.
wait_image_available() {
  poll_until "AMI $1 becoming available" "$AMI_WAIT_SECONDS" "$AMI_POLL_SECONDS" _image_probe "$1"
}

# --- instance status --------------------------------------------------------------------------
# wait_status_ok <instance-id>: the instance-status-ok waiter, run up to STATUS_OK_ROUNDS times
# (600 s each), so a slow first boot does not stop the run at the waiter's own cap.
wait_status_ok() {
  local n
  for n in $(seq 1 "$STATUS_OK_ROUNDS"); do
    aws ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$1" && return 0
    warn "instance $1 is not status-ok yet (waiter round $n of $STATUS_OK_ROUNDS)"
  done
  warn "instance $1 did not reach status-ok in $STATUS_OK_ROUNDS waiter rounds"
  return 1
}

# --- reboot onto the new kernel ----------------------------------------------------------------
# read_boot_info <instance-id> <timeout-seconds> [margin-seconds]: run one short command and set
# BOOT_ID (/proc/sys/kernel/random/boot_id, new on every boot) and BOOT_KERNEL (uname -r).
# Returns ssm_run's result, or 3 when the answer is not a boot id and a release.
read_boot_info() {
  local rc=0
  BOOT_ID="" BOOT_KERNEL=""
  ssm_run "$1" "$2" AWS-RunShellScript "$(ssm_shell_params 'cat /proc/sys/kernel/random/boot_id; uname -r' "$2")" "${3:-$SSM_WAIT_MARGIN}" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  BOOT_ID=$(printf '%s\n' "$SSM_STDOUT" | sed -n 1p)
  BOOT_KERNEL=$(printf '%s\n' "$SSM_STDOUT" | sed -n 2p)
  [[ "$BOOT_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ && -n "$BOOT_KERNEL" ]] || return 3
}
_reboot_probe() { # _reboot_probe <instance-id> <boot-id-before> <kernel-wanted>
  local rc=0
  read_boot_info "$1" 60 30 || rc=$?
  # Unreachable while it reboots: not yet. An answer with the old boot id: not rebooted yet.
  if [ "$rc" != 0 ]; then POLL_STATE="no answer yet ($SSM_STATUS)"; return 10; fi
  if [ "$BOOT_ID" = "$2" ]; then POLL_STATE="still boot $BOOT_ID (not rebooted yet)"; return 10; fi
  if [ "$BOOT_KERNEL" != "$3" ]; then POLL_STATE="rebooted (boot $BOOT_ID) onto kernel $BOOT_KERNEL, not $3"; return 1; fi
  POLL_STATE="rebooted (boot $BOOT_ID) onto $BOOT_KERNEL"
  return 0
}
# wait_rebooted <instance-id> <boot-id-before> <kernel-wanted>: poll until a fresh command answers
# with a different boot id AND the wanted kernel release. Sets BOOT_ID and BOOT_KERNEL.
wait_rebooted() {
  poll_until "build host $1 rebooting onto $3" "$REBOOT_WAIT_SECONDS" "$REBOOT_POLL_SECONDS" _reboot_probe "$1" "$2" "$3"
}
