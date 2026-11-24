#!/usr/bin/env bash
# packer-stage.sh: the stage driver of packer/bottlerocket.pkr.hcl. Packer's shell-local runs
# it once per stage. It reaches the builder only through AWS Systems Manager Run Command
# (AWS-RunShellScript): one command per stage after bind (bind reads EC2 and waits for Systems
# Manager; upload sends one per chunk and one to unpack). For each command it prints the
# command ID and the final status, and it exits 0 only for Success.
#
# From the template: CB_STAGE, CB_BUILDER_ID (build.ID), CB_PACKER_RUN_UUID
# (build.PackerRunUUID), RUN_STATE_DIR (must be this run's). From 10-build-ami-packer.sh:
# RUN_ID, SANDBOX_SLOTS, AWS_REGION and the credentials of the operator shell.
# Exit 0 done; 1 refused or the command did not succeed; 2 the status could not be read.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR="$(cd "$HERE/.." && pwd)"
export SAMPLE_DIR
template_dir="${RUN_STATE_DIR:-}"
# shellcheck source=/dev/null
. "$SAMPLE_DIR/scripts/common.sh"
require_run_id
[ -n "$template_dir" ] && [ "$template_dir" = "$RUN_STATE_DIR" ] \
  || die E_RUN_STATE_DIR "the template's run folder '$template_dir' is not this run's $RUN_STATE_DIR"
umask 077

STAGES="bind upload host-setup fetch-verify overlay build write-images verify-root release"
stage="${CB_STAGE:-}"
case " $STAGES " in *" $stage "*) ;; *) die E_STAGE_UNKNOWN "unknown stage '$stage'" ;; esac
id="${CB_BUILDER_ID:-}"
[[ "$id" =~ ^i-[0-9a-f]{8,17}$ ]] || die E_BUILDER_ID "build.ID '$id' is not an instance ID"
[[ "${CB_PACKER_RUN_UUID:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || die E_PACKER_RUN_UUID "build.PackerRunUUID is not a UUID"
[[ "${SANDBOX_SLOTS:-}" =~ ^[1-9][0-9]{0,2}$ ]] && [ "$SANDBOX_SLOTS" -le 250 ] \
  || die E_INPUT_SANDBOX_SLOTS "SANDBOX_SLOTS must be an integer from 1 to 250"
PK="$RUN_STATE_DIR/packer"
PRIV="$PK/private"
EV="$EVIDENCE_DIR/ami-build.txt"
[ -d "$PRIV" ] && [ ! -L "$PK" ] || die E_PACKER_DIR "no $PRIV; run scripts/10-build-ami-packer.sh build"
PM=(python3 -I "$SAMPLE_DIR/scripts/lib/packer_manifest.py")
SLEEP="${CB_SLEEP_SECONDS:-15}"
[[ "$SLEEP" =~ ^[0-9]+$ ]] && [ "$SLEEP" -le 15 ] || SLEEP=15
TRIES="${CB_WAIT_TRIES:-60}"
[[ "$TRIES" =~ ^[0-9]+$ ]] && [ "$TRIES" -ge 1 ] && [ "$TRIES" -le 60 ] || TRIES=60
REMOTE=/opt/cilium-bottlerocket
OVL="$REMOTE/overlay/scripts/builder"

record() { printf '%s\n' "$*" | tee -a "$EV"; }
# The previous stage must be done, and this stage must not have run.
prev=""
for s in $STAGES; do [ "$s" = "$stage" ] && break; prev="$s"; done
[ -z "$prev" ] || [ -f "$PK/stage-$prev.done" ] || die E_STAGE_ORDER "stage $stage before stage $prev"
[ ! -e "$PK/stage-$stage.done" ] || die E_STAGE_REPEAT "stage $stage already ran"
if [ "$stage" != bind ]; then
  [ "$(state_get BUILDER_INSTANCE_ID)" = "$id" ] || die E_STAGE_BUILDER "build.ID $id is not the bound builder"
  [ "$(cat "$PK/packer-run-uuid")" = "$CB_PACKER_RUN_UUID" ] || die E_STAGE_UUID "another Packer run"
fi

# ssm_run <name> <execution-timeout-seconds> <shell command>: one Run Command; prints its
# command ID and final status. Returns 0 Success, 1 another final status, 2 not readable.
ssm_run() {
  local name="$1" t="$2" cmd="$3" p cid out rc=0 status="" deadline
  p="$PRIV/ssm-$name.json"
  python3 -I -c 'import json, sys
json.dump({"commands": [sys.argv[2]], "executionTimeout": [sys.argv[3]]}, open(sys.argv[1], "x"))' "$p" "$cmd" "$t" \
    || die E_SSM_PARAMS "could not write $p"
  cid=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$id" --document-name AWS-RunShellScript \
        --comment "cilium-bottlerocket $RUN_ID $name" --timeout-seconds 600 --parameters "file://$p" \
        --query Command.CommandId --output text 2>"$PRIV/ssm-$name.err") \
    || { echo "ERROR: E_SSM_SEND: send-command failed for $name: $(tail -n 1 "$PRIV/ssm-$name.err")" >&2; return 2; }
  [[ "$cid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || { echo "ERROR: E_SSM_SEND: send-command returned no command ID for $name" >&2; return 2; }
  record "packer-stage $name command_id=$cid"
  deadline=$(( $(date +%s) + t + 120 ))
  while [ "$(date +%s)" -le "$deadline" ]; do
    sleep "$SLEEP"
    if aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cid" --instance-id "$id" \
         --output json >"$PRIV/inv-$name.json" 2>"$PRIV/inv-$name.err"; then
      status=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("Status", ""))' "$PRIV/inv-$name.json") || status=""
    elif grep -q 'InvocationDoesNotExist' "$PRIV/inv-$name.err"; then
      status=Pending
    else
      status=""
    fi
    case "$status" in
      Pending|InProgress|Delayed|Cancelling) continue ;;
      "") continue ;;
      *) break ;;
    esac
  done
  [ -f "$PRIV/inv-$name.json" ] && python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
for k, tag in (("StandardOutputContent", "  [builder] "), ("StandardErrorContent", "  [builder:stderr] ")):
    for line in (d.get(k) or "").splitlines()[-40:]:
        print(tag + line)' "$PRIV/inv-$name.json" || true
  case "$status" in
    Success) rc=0 ;;
    Failed|Cancelled|TimedOut|DeliveryTimedOut|ExecutionTimedOut|Undeliverable|Terminated|InvalidPlatform|AccessDenied) rc=1 ;;
    *) status="unknown"; rc=2 ;;
  esac
  record "packer-stage $name command_id=$cid status=$status"
  state_set "SSM_COMMAND_$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')" "$cid $status"
  return "$rc"
}

# record_partition_use <stage rc>: the partition-use and root-fit lines of the build stage
# (the os-image-size-gib measurement) go to the evidence file. After a Success, a missing
# ROOT-A line stops the build.
record_partition_use() {
  local lines
  lines=$(python3 -I -c 'import json, sys
out = json.load(open(sys.argv[1])).get("StandardOutputContent") or ""
for line in out.splitlines():
    if line.startswith(("builder: partition-use ", "builder: root-fit ")):
        print(line[len("builder: "):])' "$PRIV/inv-build.json" 2>/dev/null) || lines=""
  [ -z "$lines" ] || printf '%s\n' "$lines" | tee -a "$EV"
  [ "$1" != 0 ] || { grep -q '^partition-use ROOT-A ' <<<"$lines" && grep -q '^root-fit ROOT-A .* ok$' <<<"$lines"; } \
    || die E_PARTITION_USE "the build stage printed no ROOT-A partition use and root-fit line"
}

stage_bind() {
  local sg prof subnet out vols enis v rc=0 ping=""
  [ -z "$(state_get BUILDER_INSTANCE_ID)" ] || die E_BIND_REPEAT "a builder is already bound"
  state_set BUILDER_INSTANCE_ID "$id"
  printf '%s\n' "$CB_PACKER_RUN_UUID" > "$PK/packer-run-uuid"
  sg=$(state_need BUILDER_SG_ID); prof=$(state_need BUILDER_PROFILE_NAME); subnet=$(state_need BUILD_SUBNET_ID)
  aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$id" --output json >"$PRIV/bind-instances.json" 2>"$PRIV/bind.err" \
    || { echo "ERROR: E_READ: describe-instances of the builder failed" >&2; exit 2; }
  aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$sg" --output json >"$PRIV/bind-sg.json" 2>"$PRIV/bind.err" \
    || { echo "ERROR: E_READ: describe-security-groups failed" >&2; exit 2; }
  out=$("${PM[@]}" builder "$PRIV/bind-instances.json" "$PRIV/bind-sg.json" --builder "$id" --sg "$sg" --profile "$prof" \
        --subnet "$subnet" --run-id "$RUN_ID" --managed-by "$OWNER_TAG_VALUE") || exit $?
  vols=$(printf '%s\n' "$out" | sed -n 's/^BUILDER_VOLUME_IDS=//p')
  enis=$(printf '%s\n' "$out" | sed -n 's/^BUILDER_ENI_IDS=//p')
  state_set BUILDER_VOLUME_IDS "$vols"
  state_set BUILDER_ENI_IDS "$enis"
  state_set OS_VOLUME_ID "$(printf '%s\n' "$out" | sed -n 's/^OS_VOLUME_ID=//p')"
  state_set DATA_VOLUME_ID "$(printf '%s\n' "$out" | sed -n 's/^DATA_VOLUME_ID=//p')"
  # shellcheck disable=SC2086
  aws ec2 describe-volumes --region "$AWS_REGION" --volume-ids ${vols//,/ } --output json >"$PRIV/bind-volumes.json" 2>"$PRIV/bind.err" \
    || { echo "ERROR: E_READ: describe-volumes failed" >&2; exit 2; }
  "${PM[@]}" volumes "$PRIV/bind-volumes.json" --ids "$vols" --builder "$id" --run-id "$RUN_ID" --managed-by "$OWNER_TAG_VALUE" | tee -a "$EV" || exit "${PIPESTATUS[0]}"
  # The builder's network interfaces: Packer's run_tags tag them at launch. Each one attached to
  # the builder must be one the instance lists and carry ManagedBy and this run's RunId, so that
  # an interface left after the builder ends is found by its tags or by BUILDER_ENI_IDS.
  aws ec2 describe-network-interfaces --region "$AWS_REGION" --filters "Name=attachment.instance-id,Values=$id" \
    --output json >"$PRIV/bind-enis.json" 2>"$PRIV/bind.err" \
    || { echo "ERROR: E_READ: describe-network-interfaces of the builder failed" >&2; exit 2; }
  "${PM[@]}" enis "$PRIV/bind-enis.json" --ids "$enis" --builder "$id" --run-id "$RUN_ID" --managed-by "$OWNER_TAG_VALUE" | tee -a "$EV" || exit "${PIPESTATUS[0]}"
  printf '%s\n' "$out" | grep '^builder ' | tee -a "$EV"
  for _ in $(seq 1 "$TRIES"); do
    if ping=$(aws ssm describe-instance-information --region "$AWS_REGION" --filters "Key=InstanceIds,Values=$id" \
              --query 'InstanceInformationList[0].PingStatus' --output text 2>"$PRIV/bind.err"); then
      [ "$ping" = Online ] && break
    else
      rc=2
    fi
    sleep "${CB_SLEEP_SECONDS:-10}"
  done
  [ "$ping" = Online ] || { [ "$rc" = 2 ] && { echo "ERROR: E_SSM_ONLINE: could not read the SSM status of $id" >&2; exit 2; }
                           die E_SSM_ONLINE "builder $id did not report Online to Systems Manager"; }
  record "packer-stage bind builder=bound ssm=Online"
}

stage_upload() {
  local sha n i files=() rc=0
  sha=$(cat "$PK/overlay.sha256")
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die E_UPLOAD "no overlay digest"
  [ "$(sha256sum "$PK/overlay.tgz" | awk '{print $1}')" = "$sha" ] || die E_UPLOAD "overlay.tgz changed after it was measured"
  while IFS= read -r f; do files+=("$f"); done < <(find "$PK/upload" -maxdepth 1 -name 'chunk-*' | sort)
  n=${#files[@]}
  [ "$n" -ge 1 ] || die E_UPLOAD "no upload chunks"
  for i in $(seq 1 "$n"); do
    local f="${files[$((i - 1))]}" b64 pre=""
    b64=$(cat "$f")
    [[ "$b64" =~ ^[A-Za-z0-9+/=]+$ ]] || die E_UPLOAD "$(basename "$f") is not base64"
    [ "$i" != 1 ] || pre="rm -rf $REMOTE && install -d -m 0700 $REMOTE/upload && "
    ssm_run "upload-$i" 120 "set -e; ${pre}printf '%s' '$b64' > $REMOTE/upload/$(basename "$f")" || exit $?
  done
  ssm_run upload-unpack 120 "set -e; cd $REMOTE; cat upload/chunk-* | base64 -d > overlay.tgz; printf '%s  overlay.tgz\n' $sha | sha256sum -c --strict -; install -d -m 0700 overlay; tar -xzf overlay.tgz -C overlay --no-same-owner; echo overlay-unpacked chunks=$n sha256=$sha" || rc=$?
  return "$rc"
}

vols=$(state_get BUILDER_VOLUME_IDS)
os_vol=$(state_get OS_VOLUME_ID); data_vol=$(state_get DATA_VOLUME_ID)
work_vol=$(printf '%s' "$vols" | cut -d, -f3)
case "$stage" in
  bind|upload|fetch-verify|overlay|build) ;;
  *) for v in "$work_vol" "$os_vol" "$data_vol"; do
       [[ "$v" =~ ^vol-[0-9a-f]{8,17}$ ]] || die E_STAGE_UNBOUND "the builder volumes are not in the state file; bind did not pass"
     done ;;
esac
case "$stage" in
  bind) stage_bind ;;
  upload) stage_upload || exit $? ;;
  host-setup) ssm_run host-setup 1600 "CB_WORK_VOLUME_ID=$work_vol bash $OVL/10-host-setup.sh" || exit $? ;;
  fetch-verify) ssm_run fetch-verify 1600 "bash $OVL/20-fetch-verify.sh" || exit $? ;;
  overlay) ssm_run overlay 700 "CB_SANDBOX_SLOTS=$SANDBOX_SLOTS bash $OVL/30-overlay.sh" || exit $? ;;
  build) rc=0; ssm_run build 8700 "bash $OVL/40-build.sh" || rc=$?; record_partition_use "$rc"; [ "$rc" = 0 ] || exit "$rc" ;;
  write-images) ssm_run write-images 1000 "CB_OS_VOLUME_ID=$os_vol CB_DATA_VOLUME_ID=$data_vol bash $OVL/50-write-images.sh" || exit $? ;;
  verify-root) ssm_run verify-root 700 "CB_OS_VOLUME_ID=$os_vol CB_SANDBOX_SLOTS=$SANDBOX_SLOTS bash $OVL/60-verify-root.sh" || exit $? ;;
  release) ssm_run release 180 "CB_OS_VOLUME_ID=$os_vol CB_DATA_VOLUME_ID=$data_vol bash $OVL/70-release.sh" || exit $? ;;
esac
( set -o noclobber; printf 'stage=%s builder=%s utc=%s\n' "$stage" "$id" "$(date -u +%FT%TZ)" > "$PK/stage-$stage.done" ) \
  || die E_STAGE_REPEAT "stage $stage already ran"
