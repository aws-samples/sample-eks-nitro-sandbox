#!/usr/bin/env bash
# test-packer-stage.sh: proves the guards of scripts/packer-stage.sh both ways, the REAL stage
# driver, run the way Packer's shell-local runs it (CB_STAGE, CB_BUILDER_ID, CB_PACKER_RUN_UUID,
# RUN_STATE_DIR in the environment), against a builder in the fake world:
#   the template's run folder, the stage name, build.ID, the Packer run UUID, SANDBOX_SLOTS
#   the stage order, a stage that ran twice, another builder or Packer run than the bound one
#   bind: the builder read-back (no key pair, no public IP ...), SSM Online, a failed read
#   upload: the measured overlay, the base64 chunks
#   every Run Command stage: the parameter file, a failed send, a failed or successful status
#
#   examples/setup/cilium-bottlerocket/scripts/test-packer-stage.sh
source "$(dirname "$0")/testlib/harness.sh"
STAGE="$SAMPLE_DIR_REAL/scripts/packer-stage.sh"
need_file "$STAGE" "every packer-stage.sh case" || finish
UUID=00000000-0000-4000-8000-000000000042
RD="$CB_RUN_DIR/runs/r1"
PK="$RD/packer"

# prep [<python change on the world>]: run r1 with its Packer folder and overlay, the builder SG
# and profile recorded, and one builder instance with its four volumes in the fake world.
prep() {
  world_reset
  world_py 's["ec2"]["vpcs"].append({"VpcId": "vpc-0fa00000000000001", "Tags": []})
s["ec2"]["subnets"].append({"SubnetId": "subnet-0fa00000000000001", "VpcId": "vpc-0fa00000000000001", "MapPublicIpOnLaunch": False, "Tags": []})
s["ec2"]["security_groups"].append({"GroupId": "sg-0fc00000000000001", "GroupName": "cb-offline-test-r1-builder", "VpcId": "vpc-0fa00000000000001", "IpPermissions": [], "IpPermissionsEgress": [], "Tags": [{"Key": "ManagedBy", "Value": "cilium-bottlerocket-sample"}, {"Key": "RunId", "Value": "r1"}]})
s["ssm"]["results"] = [{"match": "", "Status": "Success", "stdout": "stage ok\n"}]'
  [[ -z "${1:-}" ]] || world_py "$1"
  BID="$(python3 -c 'import os, sys
sys.path.insert(0, os.environ["FAKE_TESTLIB"])
import fake_packer as fp
b = fp.Builder({"run_id": "r1", "region": "us-west-2", "subnet_id": "subnet-0fa00000000000001", "security_group_id": "sg-0fc00000000000001",
                "instance_profile": "cb-offline-test-r1-builder", "build_name": "cb-offline-test-r1-builder", "managed_by": "cilium-bottlerocket-sample"},
               __import__("json").load(open(os.environ["FAKE_STATE"])).get("packer") or {})
print(b.launch())')"
  rm -rf "$CB_RUN_DIR/runs" "$CB_RUN_DIR/current-run"
  mkdir -p -m 700 "$RD" "$PK" "$PK/private" "$PK/upload" "$RD/evidence"
  write_state "$RD/state.env" RUN_ID=r1 CLUSTER_NAME=cb-offline-test AWS_REGION=us-west-2 INTERFACE_VERSION=cluster-v3 \
    VPC_ID=vpc-0fa00000000000001 BUILD_SUBNET_ID=subnet-0fa00000000000001 BUILDER_SG_ID=sg-0fc00000000000001 \
    BUILDER_ROLE_NAME=cb-offline-test-r1-builder BUILDER_PROFILE_NAME=cb-offline-test-r1-builder
  printf 'r1\n' > "$CB_RUN_DIR/current-run"
  printf 'overlay archive stand-in\n' > "$PK/overlay.tgz"
  sha256sum "$PK/overlay.tgz" | cut -d' ' -f1 > "$PK/overlay.sha256"
  base64 -w0 "$PK/overlay.tgz" > "$PK/upload/chunk-000"
  export RUN_ID=r1
}
# stage <log> <stage> [VAR=value ...]: run the real stage driver as shell-local would; sets RC.
stage() {
  local log="$1" s="$2"; shift 2
  run_real "$log" env CB_STAGE="$s" CB_BUILDER_ID="$BID" CB_PACKER_RUN_UUID="$UUID" RUN_STATE_DIR="$RD" "$@" bash "$STAGE"
}
done_upto() { # done_upto <stage>: mark every stage before <stage> as done, as a bound run would
  local s
  for s in bind upload host-setup fetch-verify overlay build write-images verify-root release; do
    [[ "$s" == "$1" ]] && break
    printf 'stage=%s\n' "$s" > "$PK/stage-$s.done"
  done
}
st() { sed -n "s/^$1=//p" "$RD/state.env" | tail -n1; }

echo "== 1/4 bind ========================================================================"
entry scripts/packer-stage.sh
prep
stage "$WORK/bind.log" bind
check "ACCEPT stage bind: the builder reads back as the run's (no key, no public IP, one SG, IMDSv2, four volumes) and SSM Online" 0 "$RC" \
  "$WORK/bind.log" '^packer-stage bind builder=bound ssm=Online$'
cover accept E_RUN_STATE_DIR E_STAGE_UNKNOWN E_BUILDER_ID E_PACKER_RUN_UUID E_INPUT_SANDBOX_SLOTS E_PACKER_DIR E_STAGE_ORDER \
  E_STAGE_REPEAT E_BIND_REPEAT E_READ E_SSM_ONLINE
[[ "$(st BUILDER_INSTANCE_ID)" == "$BID" && "$(st BUILDER_VOLUME_IDS)" =~ ^vol-[0-9a-f]{17}(,vol-[0-9a-f]{17}){3}$ \
   && -n "$(st OS_VOLUME_ID)" && -n "$(st DATA_VOLUME_ID)" && -f "$PK/stage-bind.done" && "$(cat "$PK/packer-run-uuid")" == "$UUID" ]]
check "  ... it records the builder, its four volumes (comma), the OS and data volumes, the run UUID and the stage marker" 0 $? "$RD/state.env"
[[ "$(count_calls aws 'ssm send-command')" == 0 ]]
check "  ... and sends no command to the builder" 0 $? "$WORK/bind.log"
stage "$WORK/bind-again.log" bind
check "REJECT stage bind a second time (its marker exists)" 1 "$RC" "$WORK/bind-again.log" '^ERROR: E_STAGE_REPEAT: stage bind already ran'
rm -f "$PK/stage-bind.done"
stage "$WORK/bind-bound.log" bind
check "REJECT stage bind when a builder is already bound in the state file" 1 "$RC" "$WORK/bind-bound.log" '^ERROR: E_BIND_REPEAT: '
prep 's["packer"] = {"builder_overrides": {"KeyName": "a-key"}}'
stage "$WORK/bind-key.log" bind
check "REJECT stage bind for a builder with a key pair" 1 "$RC" "$WORK/bind-key.log" '^ERROR: E_BUILDER_KEY: '
[[ ! -f "$PK/stage-bind.done" ]]; check "  ... and leaves no stage marker" 0 $? "$WORK/bind-key.log"
prep 's["ec2"]["security_groups"][0]["IpPermissions"] = [{"IpProtocol": "tcp", "FromPort": 22, "ToPort": 22}]'
stage "$WORK/bind-inbound.log" bind
check "REJECT stage bind when the builder security group has an inbound rule" 1 "$RC" "$WORK/bind-inbound.log" '^ERROR: E_BUILDER_INBOUND: '
prep; FAKE_FAIL='aws|ec2 describe-instances||RequestLimitExceeded' stage "$WORK/bind-read.log" bind
check "REJECT stage bind when the builder cannot be read, as could not determine (exit 2)" 2 "$RC" "$WORK/bind-read.log" '^ERROR: E_READ: describe-instances of the builder failed'
prep 's["ssm"]["online"] = False'
stage "$WORK/bind-offline.log" bind CB_WAIT_TRIES=2
check "REJECT stage bind when the builder never reports Online" 1 "$RC" "$WORK/bind-offline.log" '^ERROR: E_SSM_ONLINE: builder .* did not report Online'
prep; FAKE_FAIL='aws|ssm describe-instance-information||ThrottlingException' stage "$WORK/bind-ssmread.log" bind CB_WAIT_TRIES=2
check "REJECT stage bind when the SSM status cannot be read, as could not determine (exit 2)" 2 "$RC" "$WORK/bind-ssmread.log" '^ERROR: E_SSM_ONLINE: could not read the SSM status'

echo "== 2/4 the stage environment and the order ========================================="
prep
stage "$WORK/env-dir.log" bind RUN_STATE_DIR="$CB_RUN_DIR/runs/r2"
check "REJECT a template run folder that is not this run's" 1 "$RC" "$WORK/env-dir.log" '^ERROR: E_RUN_STATE_DIR: '
stage "$WORK/env-stage.log" make-coffee
check "REJECT an unknown stage name" 1 "$RC" "$WORK/env-stage.log" "^ERROR: E_STAGE_UNKNOWN: unknown stage 'make-coffee'"
stage "$WORK/env-id.log" bind CB_BUILDER_ID=i-NOTANID
check "REJECT a build.ID that is not an instance ID" 1 "$RC" "$WORK/env-id.log" '^ERROR: E_BUILDER_ID: '
stage "$WORK/env-uuid.log" bind CB_PACKER_RUN_UUID=not-a-uuid
check "REJECT a build.PackerRunUUID that is not a UUID" 1 "$RC" "$WORK/env-uuid.log" '^ERROR: E_PACKER_RUN_UUID: '
config_set 'SANDBOX_SLOTS="0"'
stage "$WORK/env-slots.log" bind
check "REJECT SANDBOX_SLOTS 0 in the stage driver" 1 "$RC" "$WORK/env-slots.log" '^ERROR: E_INPUT_SANDBOX_SLOTS: '
config_set 'SANDBOX_SLOTS="58"'
rm -rf "$PK/private"
stage "$WORK/env-pk.log" bind
check "REJECT a run with no Packer private folder (10-build-ami-packer.sh did not prepare it)" 1 "$RC" "$WORK/env-pk.log" '^ERROR: E_PACKER_DIR: '
prep; stage "$WORK/o-bind.log" bind
stage "$WORK/order.log" overlay
check "REJECT stage overlay before stages upload, host-setup and fetch-verify" 1 "$RC" "$WORK/order.log" '^ERROR: E_STAGE_ORDER: stage overlay before stage fetch-verify'
done_upto host-setup
stage "$WORK/other-id.log" host-setup CB_BUILDER_ID=i-0fb99999999999999
check "REJECT a stage whose build.ID is not the bound builder" 1 "$RC" "$WORK/other-id.log" '^ERROR: E_STAGE_BUILDER: '
stage "$WORK/other-uuid.log" host-setup CB_PACKER_RUN_UUID=00000000-0000-4000-8000-000000000099
check "REJECT a stage of another Packer run" 1 "$RC" "$WORK/other-uuid.log" '^ERROR: E_STAGE_UUID: '
stage "$WORK/hs.log" host-setup
check "ACCEPT stage host-setup: one Run Command, its command ID and Success" 0 "$RC" "$WORK/hs.log" \
  '^packer-stage host-setup command_id=[0-9a-f-]{36} status=Success$'
cover accept E_STAGE_BUILDER E_STAGE_UUID E_SSM_PARAMS E_SSM_SEND E_STAGE_UNBOUND
[[ "$(st SSM_COMMAND_HOST_SETUP)" =~ ^[0-9a-f-]{36}\ Success$ ]] && calls aws 'ssm send-command' | grep -q 'AWS-RunShellScript'
check "  ... the state file records SSM_COMMAND_HOST_SETUP, and the document is AWS-RunShellScript" 0 $? "$RD/state.env"

echo "== 3/4 upload ======================================================================="
prep; stage "$WORK/u-bind.log" bind
stage "$WORK/upload.log" upload
check "ACCEPT stage upload: the measured overlay in base64 chunks, unpacked and checked on the builder" 0 "$RC" "$WORK/upload.log" \
  '^packer-stage upload-unpack command_id=[0-9a-f-]{36} status=Success$'
cover accept E_UPLOAD
grep -q "sha256sum -c --strict" "$PK/private/ssm-upload-unpack.json"
check "  ... the unpack command checks the overlay SHA-256 on the builder" 0 $? "$PK/private/ssm-upload-unpack.json"
while IFS='|' read -r change rx why; do
  [[ -n "$change" ]] || continue
  prep; stage "$WORK/u-bind2.log" bind
  eval "$change"
  stage "$WORK/upload-bad.log" upload
  check "$why" 1 "$RC" "$WORK/upload-bad.log" "$rx"
done <<'CASES'
printf 'changed\n' >> "$PK/overlay.tgz"|^ERROR: E_UPLOAD: overlay.tgz changed after it was measured|REJECT an overlay that changed after it was measured
printf 'not base64!\n' > "$PK/upload/chunk-000"|^ERROR: E_UPLOAD: chunk-000 is not base64|REJECT an upload chunk that is not base64
rm -f "$PK/upload/chunk-000"|^ERROR: E_UPLOAD: no upload chunks|REJECT an upload with no chunks
printf 'x\n' > "$PK/overlay.sha256"|^ERROR: E_UPLOAD: no overlay digest|REJECT an overlay with no digest
CASES

echo "== 4/4 the Run Command stages ======================================================"
prep; stage "$WORK/r-bind.log" bind; done_upto host-setup
FAKE_FAIL='aws|ssm send-command||AccessDeniedException' stage "$WORK/send.log" host-setup
check "REJECT a stage whose send-command fails, as could not determine (exit 2)" 2 "$RC" "$WORK/send.log" '^ERROR: E_SSM_SEND: send-command failed for host-setup'
prep; stage "$WORK/r-bind2.log" bind; done_upto host-setup
: > "$PK/private/ssm-host-setup.json"
stage "$WORK/params.log" host-setup
check "REJECT a stage whose parameter file already exists (a stage never reuses one)" 1 "$RC" "$WORK/params.log" '^ERROR: E_SSM_PARAMS: '
prep 's["ssm"]["results"] = [{"match": "20-fetch-verify.sh", "Status": "Failed", "stdout": "", "stderr": "ERROR: E_SIGNATURE: runtime-release"}, {"match": "", "Status": "Success", "stdout": "ok"}]'
stage "$WORK/r-bind3.log" bind; done_upto fetch-verify
stage "$WORK/failed.log" fetch-verify
check "REJECT a stage whose Run Command ends Failed (exit 1), with the builder's error line shown" 1 "$RC" "$WORK/failed.log" \
  '^packer-stage fetch-verify command_id=[0-9a-f-]{36} status=Failed$'
grep -q '\[builder:stderr\] ERROR: E_SIGNATURE: runtime-release' "$WORK/failed.log" && [[ ! -f "$PK/stage-fetch-verify.done" ]]
check "  ... the builder's refusal reaches the operator log, and the stage leaves no marker" 0 $? "$WORK/failed.log"

# The build stage copies the partition-use and root-fit lines of 40-build.sh
# to the evidence file without the "builder: " prefix; after a Success, both ROOT-A lines must
# be there (E_PARTITION_USE); after a failure, it copies what is there and keeps the exit code.
PU='builder: partition-use ROOT-A bytes_used=1342177280 bytes_total=2147483648 percent=62.5'
PB='builder: partition-use BOTTLEROCKET-DATA bytes_used=1 bytes_total=2 percent=50'
RF='builder: root-fit ROOT-A used=1342177280 total=2147483648 ok'
# build_stage <log> <status> <stdout>: stage build after a bound run, with that Run Command result.
build_stage() {
  prep "s[\"ssm\"][\"results\"] = [{\"match\": \"40-build.sh\", \"Status\": \"$2\", \"stdout\": $(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$3"), \"stderr\": \"\"}, {\"match\": \"\", \"Status\": \"Success\", \"stdout\": \"ok\"}]"
  stage "$WORK/bind-$1" bind; done_upto build
  stage "$WORK/$1" build
}
entry scripts/packer-stage.sh
build_stage pu-ok.log Success "builder: cargo make finished
$PU
$PB
$RF
builder: build ok"
check "ACCEPT the build stage: the ROOT-A partition use and root-fit lines are there after a Success" 0 "$RC" "$WORK/pu-ok.log"
cover accept E_PARTITION_USE
[[ "$(grep -c '^partition-use \|^root-fit ' "$RD/evidence/ami-build.txt")" == 3 ]] \
  && grep -qx "${PU#builder: }" "$RD/evidence/ami-build.txt" && grep -qx "${RF#builder: }" "$RD/evidence/ami-build.txt" \
  && ! grep -q '^builder: ' "$RD/evidence/ami-build.txt" && [[ -f "$PK/stage-build.done" ]]
check "  ... the evidence file holds the three lines without the builder: prefix, and the stage is marked done" 0 $? "$RD/evidence/ami-build.txt"
build_stage pu-nofit.log Success "$PU
builder: build ok"
check "REJECT a build stage that ends Success with no root-fit line" 1 "$RC" "$WORK/pu-nofit.log" '^ERROR: E_PARTITION_USE: the build stage printed no ROOT-A partition use and root-fit line$'
[[ ! -f "$PK/stage-build.done" ]] && grep -qx "${PU#builder: }" "$RD/evidence/ami-build.txt"
check "  ... the line that is there is kept, and the stage leaves no marker" 0 $? "$WORK/pu-nofit.log"
build_stage pu-nouse.log Success "$PB
$RF"
check "REJECT a build stage that ends Success with no ROOT-A partition-use line" 1 "$RC" "$WORK/pu-nouse.log" '^ERROR: E_PARTITION_USE: '
build_stage pu-failed.log Failed "$PU
builder: E_ROOT_FIT stand-in"
check "REJECT a failed build stage: its own exit code (1), not E_PARTITION_USE" 1 "$RC" "$WORK/pu-failed.log" '^packer-stage build command_id=[0-9a-f-]{36} status=Failed$'
! grep -q 'E_PARTITION_USE' "$WORK/pu-failed.log" && grep -qx "${PU#builder: }" "$RD/evidence/ami-build.txt" && [[ ! -f "$PK/stage-build.done" ]]
check "  ... the partition-use line of the failed stage is still copied to the evidence file" 0 $? "$WORK/pu-failed.log"
prep; stage "$WORK/r-bind4.log" bind; done_upto write-images
sed -i '/^OS_VOLUME_ID=/d' "$RD/state.env"
stage "$WORK/unbound.log" write-images
check "REJECT stage write-images when the OS volume is not in the state file" 1 "$RC" "$WORK/unbound.log" '^ERROR: E_STAGE_UNBOUND: '
prep; stage "$WORK/r-bind5.log" bind; done_upto write-images
stage "$WORK/wi.log" write-images
check "ACCEPT stage write-images: the command names the OS and data volumes by ID" 0 "$RC" "$WORK/wi.log" '^packer-stage write-images command_id=[0-9a-f-]{36} status=Success$'
grep -q "CB_OS_VOLUME_ID=$(st OS_VOLUME_ID) CB_DATA_VOLUME_ID=$(st DATA_VOLUME_ID)" "$PK/private/ssm-write-images.json"
check "  ... with CB_OS_VOLUME_ID and CB_DATA_VOLUME_ID from the bound builder" 0 $? "$PK/private/ssm-write-images.json"
prep; stage "$WORK/r-bind6.log" bind; done_upto overlay
stage "$WORK/ov.log" overlay
grep -q "CB_SANDBOX_SLOTS=58 bash /opt/cilium-bottlerocket/overlay/scripts/builder/30-overlay.sh" "$PK/private/ssm-overlay.json"
check "ACCEPT stage overlay: the command passes CB_SANDBOX_SLOTS=58, the one density value" 0 $? "$PK/private/ssm-overlay.json"
finish
