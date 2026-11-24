#!/usr/bin/env bash
# test-packer-build.sh: proves scripts/10-build-ami-packer.sh both ways, the REAL script, with the
# stub commands first on PATH and a fixture HashiCorp release (scripts/testlib/fixture_packer_release.py):
#   check-tools  Packer 1.16.2 and the Amazon plugin 1.8.4 against the signed SHA256SUMS: a good
#                signature by the pinned fingerprint passes; another signer, a changed file, a bad
#                signature, a changed zip, another version each stop with exit 1; no AWS call; the
#                operator's own ~/.gnupg is untouched
#   build        the inputs before any AWS call (SANDBOX_SLOTS 1 to 250, PACKER_LOG); a retry only
#                when each part of the last attempt reads back absent (E_RESUME);
#                the SSM upload size gate one byte under and one byte over; the private
#                subnet; one `packer build` with no forbidden flag; the builder parts gone after the
#                build (#281); the manifest with exactly one AMI; the image and its two snapshots;
#                an interrupted build leaves the builder security group, profile and role recorded
#                for clean.sh
# The real scripts/packer-stage.sh runs each stage through the fake SSM Run Command.
#
#   examples/setup/cilium-bottlerocket/scripts/test-packer-build.sh
source "$(dirname "$0")/testlib/harness.sh"
BUILD="$SAMPLE_DIR_REAL/scripts/10-build-ami-packer.sh"
need_file "$BUILD" "every 10-build-ami-packer.sh case" || finish
need_file "$SAMPLE_DIR_REAL/scripts/packer-stage.sh" "the build flow cases" || finish
# Packer's plugin sockets need a short TMPDIR (the script allows at most 80 bytes).
export TMPDIR="$REPO_ROOT_REAL/tmp"
[[ ${#TMPDIR} -le 80 ]] || { not_run "every build case" "the repository path makes TMPDIR longer than 80 bytes"; finish; }

# release <case>: a fixture release; exports CB_PACKER_TOOLS_LOCK.
release() {
  [[ -s "$WORK/rel/$1.lock" ]] || python3 "$TESTLIB/fixture_packer_release.py" "$WORK/rel/$1" "$WORK/rel/$1.lock" "$1" > "$WORK/rel-$1.log" 2>&1
  export CB_PACKER_TOOLS_LOCK="$WORK/rel/$1.lock"
}
mkdir -p "$WORK/rel"
# A marker in the operator's (the suite's) ~/.gnupg, to show the check never touches it.
mkdir -m 700 "$HOME/.gnupg"; printf 'operator keyring marker\n' > "$HOME/.gnupg/pubring.kbx"
gnupg_print() { find "$HOME/.gnupg" -printf '%p %m %s %T@\n' | sort; sha256sum "$HOME/.gnupg/pubring.kbx"; }
gnupg_print > "$WORK/gnupg-before.txt"

echo "== 1/4 check-tools ================================================================"
world_reset
entry scripts/10-build-ami-packer.sh:check-tools
release good
run_real "$WORK/ct-good.log" bash "$BUILD" check-tools
check "ACCEPT check-tools: VALIDSIG by the pinned fingerprint, both zips equal the signed and pinned digests, Packer v1.16.2, plugin 1.8.4" 0 "$RC" \
  "$WORK/ct-good.log" '^packer-tools packer=v1\.16\.2 plugin=1\.8\.4 platform=linux_amd64 signer=[0-9A-F]{40}$'
cover accept E_ARGS E_TOOLS_LOCK E_TOOLS_DOWNLOAD E_TOOLS_SIGNATURE E_TOOLS_SIGNER E_TOOLS_DIGEST E_TOOLS_PLATFORM \
  E_TOOLS_PREREQ E_TOOLS_KEY E_TOOLS_UNZIP E_TOOLS_VERSION E_TOOLS_PLUGIN
[[ "$(count_calls aws)" == 0 ]]
check "  ... and check-tools made no AWS call" 0 $? "$WORK/ct-good.log"
[[ -x "$CB_RUN_DIR/tools/packer/bin/packer" && -z "$(find "$CB_RUN_DIR/tools" -maxdepth 1 -name 'gnupg.*')" ]]
check "  ... installed Packer under CB_RUN_DIR/tools and removed its own GNUPGHOME" 0 $? "$WORK/ct-good.log"
gnupg_print > "$WORK/gnupg-after.txt"; cmp -s "$WORK/gnupg-before.txt" "$WORK/gnupg-after.txt"
check "  ... and left the operator's ~/.gnupg byte for byte as it was" 0 $? "$WORK/gnupg-after.txt"
while IFS='|' read -r c want tag why; do
  [[ -n "$c" ]] || continue
  release "$c"
  rm -rf "$CB_RUN_DIR/tools"
  run_real "$WORK/ct-$c.log" bash "$BUILD" check-tools
  check "$why" "$want" "$RC" "$WORK/ct-$c.log" "^ERROR: $tag: "
done <<'CASES'
bad-sig|1|E_TOOLS_SIGNATURE|REJECT a bad signature: SHA256SUMS signed by a key that is not the pinned one
wrong-fingerprint|1|E_TOOLS_SIGNER|REJECT a wrong fingerprint: a good signature, but not by the pinned HASHICORP_KEY_FPR
zip-swapped|1|E_TOOLS_DIGEST|REJECT a changed file: the Packer zip served is not the one the signed SHA256SUMS lists
lock-digest|1|E_TOOLS_DIGEST|REJECT a Packer zip whose signed digest is not the one tools.lock pins
plugin-digest|1|E_TOOLS_DIGEST|REJECT a plugin zip whose signed digest is not the one tools.lock pins
wrong-version|1|E_TOOLS_VERSION|REJECT a verified packer that does not report v1.16.2
no-plugin-binary|1|E_TOOLS_PLUGIN|REJECT a plugin zip without the plugin binary
no-packer-binary|1|E_TOOLS_UNZIP|REJECT a Packer zip without the packer binary
CASES
release good; rm -rf "$CB_RUN_DIR/tools"
printf '%s  packer_1.16.2_linux_amd64.zip\n' "$(printf '0%.0s' $(seq 64))" >> "$WORK/rel/good/releases/packer/1.16.2/packer_1.16.2_SHA256SUMS"
run_real "$WORK/ct-sums-changed.log" bash "$BUILD" check-tools
check "REJECT a changed file: SHA256SUMS changed after it was signed" 1 "$RC" "$WORK/ct-sums-changed.log" '^ERROR: E_TOOLS_SIGNATURE: '
rm -rf "$WORK/rel/good" "$WORK/rel/good.lock"; release good
cp "$CB_PACKER_TOOLS_LOCK" "$WORK/rel/missing.lock"; sed -i "s#^HASHICORP_RELEASES_URL=.*#HASHICORP_RELEASES_URL=file://$WORK/rel/nowhere#" "$WORK/rel/missing.lock"
CB_PACKER_TOOLS_LOCK="$WORK/rel/missing.lock" run_real "$WORK/ct-dl.log" bash "$BUILD" check-tools
check "REJECT a release that cannot be downloaded, as could not check (exit 2)" 2 "$RC" "$WORK/ct-dl.log" '^ERROR: E_TOOLS_DOWNLOAD: '
cp "$CB_PACKER_TOOLS_LOCK" "$WORK/rel/notakey.lock"; printf 'not a key\n' > "$WORK/rel/notakey.asc"
sed -i "s#^HASHICORP_KEY_URL=.*#HASHICORP_KEY_URL=file://$WORK/rel/notakey.asc#" "$WORK/rel/notakey.lock"
CB_PACKER_TOOLS_LOCK="$WORK/rel/notakey.lock" run_real "$WORK/ct-key.log" bash "$BUILD" check-tools
check "REJECT a HashiCorp key file that is not a key" 1 "$RC" "$WORK/ct-key.log" '^ERROR: E_TOOLS_KEY: '
{ cat "$CB_PACKER_TOOLS_LOCK"; grep '^PACKER_VERSION=' "$CB_PACKER_TOOLS_LOCK"; } > "$WORK/rel/twice.lock"
CB_PACKER_TOOLS_LOCK="$WORK/rel/twice.lock" run_real "$WORK/ct-twice.log" bash "$BUILD" check-tools
check "REJECT a tools lock with a key twice" 1 "$RC" "$WORK/ct-twice.log" '^ERROR: E_TOOLS_LOCK: PACKER_VERSION must appear exactly once'
cp "$CB_PACKER_TOOLS_LOCK" "$WORK/rel/fpr.lock"; sed -i 's/^HASHICORP_KEY_FPR=.*/HASHICORP_KEY_FPR=not-a-fingerprint/' "$WORK/rel/fpr.lock"
CB_PACKER_TOOLS_LOCK="$WORK/rel/fpr.lock" run_real "$WORK/ct-fpr.log" bash "$BUILD" check-tools
check "REJECT a tools lock whose fingerprint is not 40 hex digits" 1 "$RC" "$WORK/ct-fpr.log" '^ERROR: E_TOOLS_LOCK: a value in .* has the wrong form'
mv "$WORK/sysbin/unzip" "$WORK/sysbin/unzip.off"
run_real "$WORK/ct-unzip.log" bash "$BUILD" check-tools
check "REJECT a machine without unzip" 1 "$RC" "$WORK/ct-unzip.log" '^ERROR: E_TOOLS_PREREQ: unzip is not installed'
mv "$WORK/sysbin/unzip.off" "$WORK/sysbin/unzip"
printf '#!/bin/sh\ncase "$1" in -s) echo SunOS ;; *) echo x86_64 ;; esac\n' > "$WORK/bin/uname"; chmod 0755 "$WORK/bin/uname"
run_real "$WORK/ct-os.log" bash "$BUILD" check-tools
check "REJECT an operating system other than Linux or macOS" 1 "$RC" "$WORK/ct-os.log" '^ERROR: E_TOOLS_PLATFORM: SunOS is not supported'
rm -f "$WORK/bin/uname"
run_real "$WORK/ct-noarg.log" bash "$BUILD"
check "REJECT no subcommand" 1 "$RC" "$WORK/ct-noarg.log" '^ERROR: E_ARGS: usage'
run_real "$WORK/ct-badarg.log" bash "$BUILD" check-tool
check "REJECT an unknown subcommand" 1 "$RC" "$WORK/ct-badarg.log" '^ERROR: E_ARGS: usage'
gnupg_print > "$WORK/gnupg-after2.txt"; cmp -s "$WORK/gnupg-before.txt" "$WORK/gnupg-after2.txt"
check "  ... and no refused case touched the operator's ~/.gnupg" 0 $? "$WORK/gnupg-after2.txt"

# ---- a run ready for the build: the cluster's VPC and private subnet in the fake world -------
# prep [<python change on the world>]: a fresh world, run r1 recorded, SSM answers Success.
prep() {
  world_reset
  release good
  world_py 's["ec2"]["vpcs"].append({"VpcId": "vpc-0fa00000000000001", "Tags": []})
s["ec2"]["subnets"].append({"SubnetId": "subnet-0fa00000000000001", "VpcId": "vpc-0fa00000000000001", "MapPublicIpOnLaunch": False, "Tags": []})
s["ssm"]["results"] = [{"match": "40-build.sh", "Status": "Success", "stdout": "builder: cargo make finished\nbuilder: partition-use ROOT-A bytes_used=1342177280 bytes_total=2147483648 percent=62.5\nbuilder: root-fit ROOT-A used=1342177280 total=2147483648 ok\nbuilder: build ok\n"},
                       {"match": "", "Status": "Success", "stdout": "stage ok\n"}]'
  [[ -z "${1:-}" ]] || world_py "$1"
  rm -rf "$CB_RUN_DIR/runs" "$CB_RUN_DIR/current-run"
  mkdir -p -m 700 "$CB_RUN_DIR/runs/r1"
  write_state "$CB_RUN_DIR/runs/r1/state.env" RUN_ID=r1 CLUSTER_NAME=cb-offline-test AWS_REGION=us-west-2 \
    INTERFACE_VERSION=cluster-v3 VPC_ID=vpc-0fa00000000000001 BUILD_SUBNET_ID=subnet-0fa00000000000001
  printf 'r1\n' > "$CB_RUN_DIR/current-run"
  export RUN_ID=r1
}
st() { sed -n "s/^$1=//p" "$CB_RUN_DIR/runs/r1/state.env" | tail -n1; }
ev() { cat "$CB_RUN_DIR/runs/r1/evidence/ami-build.txt" 2>/dev/null; }

echo "== 2/4 build: the good flow ======================================================="
entry scripts/10-build-ami-packer.sh:build
prep
run_real "$WORK/b-good.log" bash "$BUILD" build
check "ACCEPT a full build: SG, role and profile made, nine stages through SSM, builder gone, one AMI with two snapshots checked" 0 "$RC" "$WORK/b-good.log"
cover accept E_INPUT_SANDBOX_SLOTS E_INPUT E_PACKER_LOG E_RESUME E_UPLOAD E_UPLOAD_TOO_LARGE E_PACKER_TMPDIR E_READ E_SUBNET \
  E_CREATE E_PACKER_VALIDATE E_LEFTOVER E_PACKER_BUILD E_MANIFEST_UUID E_RUN_RECORD E_RUN_LOCK
[[ "$(tail -n1 "$CB_RUN_DIR/runs/r1/state.env")" == AMI_BUILD_RESULT=ok && "$(st SANDBOX_AMI_ID)" =~ ^ami-[0-9a-f]{17}$ \
   && "$(st SANDBOX_AMI_SNAPSHOT_IDS)" =~ ^snap-[0-9a-f]{17},snap-[0-9a-f]{17}$ ]]
check "  ... the state file ends with AMI_BUILD_RESULT=ok and names the AMI and its two snapshots (root,data)" 0 $? "$CB_RUN_DIR/runs/r1/state.env"
for k in BUILDER_AMI_ID BUILDER_SG_ID BUILDER_ROLE_NAME BUILDER_PROFILE_NAME BUILDER_INSTANCE_ID BUILDER_VOLUME_IDS BUILDER_ENI_IDS OS_VOLUME_ID DATA_VOLUME_ID PACKER_MANIFEST PACKER_RUN_UUID; do
  [[ -n "$(st "$k")" ]] || { echo "missing $k" >> "$WORK/b-keys.log"; }
done
[[ ! -s "$WORK/b-keys.log" ]]
check "  ... and records every builder key (BUILDER_*, OS/DATA_VOLUME_ID, PACKER_*)" 0 $? "$WORK/b-keys.log"
# On the good flow: no refusal, so no undo; the build stage's ROOT-A lines
# are in the evidence file without the builder: prefix.
! ev | grep -q '^undo ' && ev | grep -qx 'partition-use ROOT-A bytes_used=1342177280 bytes_total=2147483648 percent=62.5' \
  && ev | grep -qx 'root-fit ROOT-A used=1342177280 total=2147483648 ok'
check "  ... no undo ran, and the evidence holds the ROOT-A partition-use and root-fit lines" 0 $? "$WORK/b-good.log"
# Stage bind reads the builder's network interface back with both run tags (Packer's run_tags
# put them on it at launch) and records its ID; the interface goes with the builder.
[[ "$(st BUILDER_ENI_IDS)" =~ ^eni-[0-9a-f]{17}$ ]] && ev | grep -qx 'builder-enis count=1 attached=builder tags=ok' \
  && [[ "$(world_get 'len(s["ec2"].get("network_interfaces", []))')" == 0 && "$(count_calls aws 'ec2 create-tags')" == 0 ]]
check "  ... stage bind records BUILDER_ENI_IDS and reads ManagedBy and RunId on the builder's interface; it ends with the builder" 0 $? "$WORK/b-good.log"
cover accept E_UNDONE E_PARTITION_USE
[[ "$(world_get 'len([g for g in s["ec2"]["security_groups"] if g.get("GroupName","").endswith("builder") or "builder" in g.get("GroupName","")])')" == 0 \
   && "$(world_get 'len(s["iam"]["roles"]) + len(s["iam"]["profiles"])')" == 0 \
   && "$(world_get 'len([i for i in s["ec2"]["instances"] if i["State"]["Name"] != "terminated"])')" == 0 \
   && "$(world_get 'len(s["ec2"]["volumes"])')" == 0 ]]
check "  ... the builder instance is terminated and its volumes, SG, profile and role do not exist" 0 $? "$WORK/b-good.log"
calls packer build > "$WORK/b-argv.txt"
pargv="$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e["tool"] == "packer" and e["call"] == "build":
        print(" ".join(a if not a.startswith("-var-file=") else "-var-file=V" for a in e["argv"][:-1]))' "$FAKE_LOG")"
[[ "$pargv" == "build -on-error=cleanup -var-file=V" ]]
check "  ... one packer build with exactly -on-error=cleanup and -var-file (no -debug, -force, -var, -only, -except)" 0 $? "$WORK/b-argv.txt"
python3 -c 'import json,sys
bad = [e for e in map(json.loads, open(sys.argv[1])) if e["tool"] == "packer" and e["call"] == "build" and any(n in ("PACKER_LOG", "PACKER_LOG_PATH") for n in e.get("env_names", []))]
sys.exit(1 if bad else 0)' "$FAKE_LOG"
check "  ... and Packer ran with no PACKER_LOG or PACKER_LOG_PATH in its environment" 0 $? "$WORK/b-good.log"
[[ "$(count_calls aws 'ssm send-command')" -ge 9 ]] && ev | grep -q '^builder key_name=none public_ip=none inbound_rules=0 http_tokens=required hop_limit=1$' \
  && ev | grep -q '^builder-gone instance=terminated volumes=absent sg=absent profile=absent role=absent$' \
  && [[ "$(ev | grep -cE '^packer-stage [a-z0-9-]+ command_id=[0-9a-f-]{36} status=Success$')" -ge 8 ]]
check "  ... the evidence shows the builder's three values, each stage's command ID and status, and builder-gone" 0 $? "$WORK/b-good.log"
B64="$(ev | sed -n 's/^overlay archive=[0-9]* base64=\([0-9]*\) .*/\1/p')"

echo "== 3/4 build: inputs, before any AWS call =========================================="
for s in "" abc 0 251 058; do
  prep; config_set "SANDBOX_SLOTS=\"$s\""
  run_real "$WORK/b-slots.log" bash "$BUILD" build
  check "REJECT SANDBOX_SLOTS='$s' before any AWS call" 1 "$RC" "$WORK/b-slots.log" '^ERROR: E_INPUT_SANDBOX_SLOTS: '
  [[ "$(count_calls aws)" == 0 ]]; check "  ... and no AWS call was made (SANDBOX_SLOTS='$s')" 0 $? "$WORK/b-slots.log"
done
prep; config_set 'BUILD_INSTANCE_TYPE="m8i 4xlarge"'
run_real "$WORK/b-type.log" bash "$BUILD" build
check "REJECT a BUILD_INSTANCE_TYPE that is not an instance type, before any AWS call" 1 "$RC" "$WORK/b-type.log" '^ERROR: E_INPUT: BUILD_INSTANCE_TYPE'
prep; PACKER_LOG=1 run_real "$WORK/b-plog.log" bash "$BUILD" build
check "REJECT PACKER_LOG set (a debug log could hold build output)" 1 "$RC" "$WORK/b-plog.log" '^ERROR: E_PACKER_LOG: '
# A retry after a failed build: one read of each part of
# the last attempt; all absent, the build runs again; one present or one read failed, E_RESUME.
R1="$CB_RUN_DIR/runs/r1"
# prep_attempt [<python change on the world>]: a run whose last attempt failed and left nothing.
prep_attempt() {
  prep "${1:-}"
  mkdir -p -m 700 "$R1/packer/private" "$R1/evidence"
  printf 'attempt 1 marker\n' > "$R1/packer/private/marker"; printf 'attempt 1 evidence\n' > "$R1/evidence/ami-build.txt"
  printf '%s\n' BUILDER_AMI_ID=ami-0fc00000000000001 BUILDER_SG_ID=sg-0fc00000000000009 \
    BUILDER_ROLE_NAME=cb-offline-test-r1-builder BUILDER_PROFILE_NAME=cb-offline-test-r1-builder \
    BUILDER_INSTANCE_ID=i-0fc00000000000009 BUILDER_VOLUME_IDS=vol-0fc00000000000001,vol-0fc00000000000002 \
    OS_VOLUME_ID=vol-0fc00000000000001 DATA_VOLUME_ID=vol-0fc00000000000002 "SSM_COMMAND_BUILD=x Failed" >> "$R1/state.env"
}
prep_attempt
run_real "$WORK/b-retry.log" bash "$BUILD" build
check "ACCEPT a retry: every part of the last attempt reads back absent, so the run builds again" 0 "$RC" "$WORK/b-retry.log"
cover accept E_RESUME
[[ -f "$R1/packer.attempt1/private/marker" && "$(cat "$R1/packer.attempt1/ami-build.txt")" == "attempt 1 evidence" \
   && "$(grep -c . "$R1/packer.attempt1/private/resume.txt")" == 13 \
   && "$(grep -cEv '=(absent|terminated)$' "$R1/packer.attempt1/private/resume.txt")" == 0 \
   && "$(cut -d= -f1 "$R1/packer.attempt1/state-cleared.env" | tr '\n' ' ')" == "BUILDER_AMI_ID BUILDER_SG_ID BUILDER_ROLE_NAME BUILDER_PROFILE_NAME BUILDER_INSTANCE_ID BUILDER_VOLUME_IDS OS_VOLUME_ID DATA_VOLUME_ID SSM_COMMAND_BUILD " \
   && "$(st BUILDER_SG_ID)" != sg-0fc00000000000009 && "$(st SSM_COMMAND_BUILD)" != "x Failed" && "$(st AMI_BUILD_RESULT)" == ok ]] \
  && ev | grep -q '^resume previous=packer.attempt1 reads=13 all=absent cleared=BUILDER_AMI_ID,BUILDER_SG_ID,'
check "  ... packer/ and the evidence moved to packer.attempt1 with 13 absent reads, the old keys moved to state-cleared.env, and the new build recorded its own" 0 $? "$WORK/b-retry.log"
prep_attempt; mkdir -p "$R1/packer.attempt1"
sed -i '/^\(BUILDER_\|OS_VOLUME_ID\|DATA_VOLUME_ID\|SSM_COMMAND_\)/d' "$R1/state.env"
run_real "$WORK/b-retry2.log" bash "$BUILD" build
[[ "$RC" == 0 && -f "$R1/packer.attempt2/private/marker" && -d "$R1/packer.attempt1" && ! -s "$R1/packer.attempt2/state-cleared.env" ]]
check "ACCEPT a retry with only packer/ left (no builder keys): it becomes packer.attempt2 beside packer.attempt1" 0 $? "$WORK/b-retry2.log"
while IFS='~' read -r code fail why; do
  [[ -n "$why" ]] || continue
  prep_attempt "$code"
  sha_before="$(sha256sum "$R1/state.env")"
  FAKE_FAIL="$fail" run_real "$WORK/b-retry-no.log" bash "$BUILD" build
  check "$why" 1 "$RC" "$WORK/b-retry-no.log" '^ERROR: E_RESUME: '
  [[ -d "$R1/packer" && ! -e "$R1/packer.attempt1" && "$(sha256sum "$R1/state.env")" == "$sha_before" \
     && "$(count_calls aws 'ec2 create-security-group')" == 0 && "$(count_calls aws 'iam create-role')" == 0 && "$(count_calls packer)" == 0 ]]
  check "  ... nothing renamed, the state file byte for byte as before, nothing created, no Packer run" 0 $? "$WORK/b-retry-no.log"
done <<'CASES'
s["ec2"]["security_groups"].append({"GroupId": "sg-0fc00000000000009", "GroupName": "cb-offline-test-r1-builder", "VpcId": "vpc-0fa00000000000001", "Tags": [], "IpPermissions": [], "IpPermissionsEgress": []})~~REJECT a retry while the last attempt's security group exists
s["ec2"]["instances"].append({"InstanceId": "i-0fc00000000000009", "State": {"Name": "shutting-down"}, "Tags": []})~~REJECT a retry while the last builder instance is still shutting down
s["ec2"]["volumes"].append({"VolumeId": "vol-0fc00000000000002", "State": "available", "Tags": [], "Attachments": []})~~REJECT a retry while a builder volume of the last attempt exists
s.setdefault("iam", {}).setdefault("roles", {})["cb-offline-test-r1-builder"] = {"Tags": []}~~REJECT a retry while the builder role exists
s["ec2"]["images"].append({"ImageId": "ami-0fc00000000000007", "Name": "other", "State": "available", "Tags": [{"Key": "ManagedBy", "Value": "cilium-bottlerocket-sample"}, {"Key": "RunId", "Value": "r1"}]})~~REJECT a retry while an AMI with the run tags exists
s["ec2"]["images"].append({"ImageId": "ami-0fc00000000000008", "Name": "cb-offline-test-r1-aws-k8s-1.36-nitro-sandbox", "State": "available", "Tags": []})~~REJECT a retry while an AMI with the run's AMI name exists (no tags)
s["ec2"]["snapshots"].append({"SnapshotId": "snap-0fc00000000000007", "State": "completed", "Tags": [{"Key": "Name", "Value": "cb-offline-test-r1-aws-k8s-1.36-nitro-sandbox"}]})~~REJECT a retry while a snapshot with the AMI's Name tag exists
~aws|iam get-role|cb-offline-test-r1-builder|ServiceUnavailable~REJECT a retry when one absence read fails (iam get-role)
CASES
prep_attempt; printf 'AMI_BUILD_RESULT=ok\n' >> "$R1/state.env"
run_real "$WORK/b-retry-done.log" bash "$BUILD" build
check "REJECT a retry of a run that already built its AMI" 1 "$RC" "$WORK/b-retry-done.log" '^ERROR: E_RESUME: this run already built its AMI'
prep_attempt; sed -i 's/^BUILDER_ROLE_NAME=.*/BUILDER_ROLE_NAME=cb-offline-test-r0-builder/' "$R1/state.env"
run_real "$WORK/b-retry-name.log" bash "$BUILD" build
check "REJECT a retry whose state names another builder role than derive_names" 1 "$RC" "$WORK/b-retry-name.log" '^ERROR: E_RESUME: the state has BUILDER_ROLE_NAME=cb-offline-test-r0-builder, not cb-offline-test-r1-builder$'
[[ "$(count_calls aws)" == 0 && -d "$R1/packer" && ! -e "$R1/packer.attempt1" ]]
check "  ... before any AWS read, and nothing renamed" 0 $? "$WORK/b-retry-name.log"
# The rename itself fails: every part reads back absent, but the run folder cannot be written.
prep_attempt; : > "$R1/run.lock"; mkdir -p -m 700 "$R1/logs"; chmod 500 "$R1"
run_real "$WORK/b-retry-mv.log" bash "$BUILD" build
chmod 700 "$R1"
check "REJECT a retry whose packer/ cannot be renamed" 1 "$RC" "$WORK/b-retry-mv.log" "^ERROR: E_RESUME: could not rename $R1/packer to $R1/packer.attempt1\$"
[[ -d "$R1/packer" && ! -e "$R1/packer.attempt1" && "$(count_calls packer)" == 0 && "$(grep -c '^BUILDER_SG_ID=sg-0fc00000000000009$' "$R1/state.env")" == 1 ]]
check "  ... packer/ stays, the state keeps the attempt's keys, and Packer did not run" 0 $? "$WORK/b-retry-mv.log"
prep; sed -i 's/^CLUSTER_NAME=.*/CLUSTER_NAME=another-cluster/' "$CB_RUN_DIR/runs/r1/state.env"
run_real "$WORK/b-record.log" bash "$BUILD" build
check "REJECT a run record of another cluster" 1 "$RC" "$WORK/b-record.log" '^ERROR: E_RUN_RECORD: '
if [[ "$B64" =~ ^[0-9]+$ ]]; then
  for d in 1 0; do
    prep; CB_UPLOAD_MAX_BYTES=$((B64 + d)) run_real "$WORK/b-up-$d.log" bash "$BUILD" build
    check "ACCEPT the overlay at the upload gate: base64 $B64 bytes, limit $((B64 + d)) ($d byte(s) under or at the limit)" 0 "$RC" "$WORK/b-up-$d.log"
  done
  prep; CB_UPLOAD_MAX_BYTES=$((B64 - 1)) run_real "$WORK/b-up-over.log" bash "$BUILD" build
  check "REJECT the overlay one byte over the upload gate (limit $((B64 - 1)))" 1 "$RC" "$WORK/b-up-over.log" '^ERROR: E_UPLOAD_TOO_LARGE: '
  [[ "$(count_calls aws)" == 0 ]]; check "  ... before the builder or any other AWS resource exists" 0 $? "$WORK/b-up-over.log"
else
  not_run "the upload size gate cases" "the good build printed no overlay base64 size"
fi
prep; TMPDIR="$REPO_ROOT_REAL/tmp/$(printf 'x%.0s' $(seq 1 60))" run_real "$WORK/b-tmp.log" bash "$BUILD" build
check "REJECT a TMPDIR longer than 80 bytes (Packer's plugin socket path)" 1 "$RC" "$WORK/b-tmp.log" '^ERROR: E_PACKER_TMPDIR: '
prep 's["ec2"]["subnets"][0]["MapPublicIpOnLaunch"] = True'
run_real "$WORK/b-public.log" bash "$BUILD" build
check "REJECT a build subnet that maps public IP addresses" 1 "$RC" "$WORK/b-public.log" '^ERROR: E_SUBNET: '
prep 's["ec2"]["subnets"][0]["VpcId"] = "vpc-0fa00000000000009"'
run_real "$WORK/b-othervpc.log" bash "$BUILD" build
check "REJECT a build subnet in another VPC" 1 "$RC" "$WORK/b-othervpc.log" '^ERROR: E_SUBNET: '
prep; FAKE_FAIL='aws|ssm get-parameter||ThrottlingException' run_real "$WORK/b-param.log" bash "$BUILD" build
check "REJECT a builder AMI parameter that cannot be read, as could not determine (exit 2)" 2 "$RC" "$WORK/b-param.log" '^ERROR: E_READ: '
prep; FAKE_FAIL='aws|ec2 create-security-group||UnauthorizedOperation' run_real "$WORK/b-sg.log" bash "$BUILD" build
check "REJECT a security group that cannot be created" 1 "$RC" "$WORK/b-sg.log" '^ERROR: E_CREATE: '
prep 's["packer"]["validate_rc"] = 1'
run_real "$WORK/b-validate.log" bash "$BUILD" build
check "REJECT a template that packer validate refuses" 1 "$RC" "$WORK/b-validate.log" '^ERROR: E_PACKER_VALIDATE: '

# A refusal between the first create and packer build deletes exactly what this
# invocation created (recorded IDs and names), reads each back, and stops with E_UNDONE (the
# first refusal's exit code) or E_UNDO_LEFTOVER (1 when a part remains, 2 when a read fails).
sgid="$(st BUILDER_SG_ID)"
check "  ... and undoes its creates: E_UNDONE with the refusal's exit code 1" 1 "$RC" "$WORK/b-validate.log" \
  "^ERROR: E_UNDONE: stopped before packer build; deleted what this attempt created \\(sg=$sgid role=cb-offline-test-r1-builder profile=cb-offline-test-r1-builder\\) and read each back absent"
# undo_scope <log> <sg id or ''> <role deletes> <profile deletes>: the deletes name only the
# recorded parts, each once, and nothing else is deleted or terminated.
undo_scope() {
  python3 - "$FAKE_LOG" "$2" "$3" "$4" > "$WORK/undo-scope.txt" <<'PY'
import json, sys
log, sg, nrole, nprof = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
calls = [json.loads(l) for l in open(log)]
dels = [c for c in calls if c["tool"] == "aws" and any(w in c["call"] for w in ("delete", "terminate", "deregister", "remove", "detach", "release"))]
for c in dels:
    print(c["call"], " ".join(c["argv"]))
want = {"ec2 delete-security-group": 1 if sg else 0, "iam delete-role": nrole, "iam delete-instance-profile": nprof}
ok = all(sum(1 for c in dels if c["call"] == k) == n for k, n in want.items())
ok = ok and all(sg in c["argv"] for c in dels if c["call"] == "ec2 delete-security-group")
ok = ok and all("cb-offline-test-r1-builder" in c["argv"] for c in dels if c["call"].startswith("iam "))
ok = ok and not [c for c in dels if c["call"] not in want and c["call"] not in ("iam remove-role-from-instance-profile", "iam detach-role-policy")]
sys.exit(0 if ok else 1)
PY
}
undo_scope "$WORK/b-validate.log" "$sgid" 1 1 && ev | grep -qx "undo sg=$sgid role=cb-offline-test-r1-builder profile=cb-offline-test-r1-builder result=absent" \
  && [[ "$(world_get 'len(s["iam"]["roles"]) + len(s["iam"]["profiles"]) + len([g for g in s["ec2"]["security_groups"] if g["GroupId"] == "'"$sgid"'"])')" == 0 \
        && "$(count_calls packer build)" == 0 && "$(st BUILDER_SG_ID)" == "$sgid" ]]
check "  ... the deletes name only the recorded SG, role and profile, each once; all read back absent; no packer build; the state keys stay" 0 $? "$WORK/undo-scope.txt"
cover accept E_UNDO_LEFTOVER   # every part read back absent: no leftover
prep; FAKE_FAIL='aws|iam get-instance-profile||ServiceFailure|1' run_real "$WORK/b-undo2.log" bash "$BUILD" build
check "REJECT an instance-profile read that fails after the creates: E_READ, then E_UNDONE with its exit code 2" 2 "$RC" "$WORK/b-undo2.log" \
  '^ERROR: E_UNDONE: stopped before packer build; deleted what this attempt created \(sg=sg-[0-9a-f]+ role=cb-offline-test-r1-builder profile=cb-offline-test-r1-builder\)'
grep -q '^ERROR: E_READ: get-instance-profile failed' "$WORK/b-undo2.log"
check "  ... and the first refusal (E_READ) is printed first" 0 $? "$WORK/b-undo2.log"
prep 's["iam"]["roles"]["cb-offline-test-r1-builder"] = {"Tags": [{"Key": "team", "Value": "someone-else"}], "Attached": [], "Inline": {}}'
run_real "$WORK/b-undo-role.log" bash "$BUILD" build
check "REJECT a builder role name that someone else's role holds: create-role fails, only the SG is undone" 1 "$RC" "$WORK/b-undo-role.log" \
  '^ERROR: E_UNDONE: stopped before packer build; deleted what this attempt created \(sg=sg-[0-9a-f]+\) and read each back absent'
undo_scope "$WORK/b-undo-role.log" "$(st BUILDER_SG_ID)" 0 0 && [[ "$(world_get '"cb-offline-test-r1-builder" in s["iam"]["roles"]')" == true ]]
check "  ... the other owner's role is not deleted (no delete-role, no delete-instance-profile)" 0 $? "$WORK/undo-scope.txt"
prep; FAKE_FAIL='aws|ec2 create-security-group||UnauthorizedOperation' run_real "$WORK/b-sg2.log" bash "$BUILD" build
undo_scope "$WORK/b-sg2.log" "" 0 0 && ! ev | grep -q '^undo ' && ! grep -q 'E_UNDO' "$WORK/b-sg2.log"
check "  ... and when the first create fails (the SG), nothing is deleted and no undo runs" 0 $? "$WORK/undo-scope.txt"
prep 's["packer"]["validate_rc"] = 1'
FAKE_FAIL='aws|ec2 delete-security-group||DependencyViolation' CB_WAIT_TRIES=2 run_real "$WORK/b-undo-left.log" bash "$BUILD" build
check "REJECT an undo whose security group delete fails: E_UNDO_LEFTOVER, exit 1" 1 "$RC" "$WORK/b-undo-left.log" '^ERROR: E_UNDO_LEFTOVER: a part this attempt created remains \(see above\); run \./clean\.sh --dry-run$'
ev | grep -qE '^undo sg=sg-[0-9a-f]+ role=cb-offline-test-r1-builder profile=cb-offline-test-r1-builder result=leftover$'
check "  ... the evidence says result=leftover" 0 $? "$WORK/b-undo-left.log"
prep 's["packer"]["validate_rc"] = 1'
FAKE_FAIL='aws|iam get-role||ServiceFailure' CB_WAIT_TRIES=2 run_real "$WORK/b-undo-read.log" bash "$BUILD" build
check "REJECT an undo whose role read back fails: E_UNDO_LEFTOVER, exit 2" 2 "$RC" "$WORK/b-undo-read.log" '^ERROR: E_UNDO_LEFTOVER: a part this attempt created could not be read back \(see above\); run \./clean\.sh --dry-run$'
# Each undo step reads its part back first and needs ManagedBy and this run's RunId. tag_change
# <sg|role|profile>: for one case, the aws stub gives that part another RunId once `packer
# validate` ran (the fake's "RecheckTags" with "ChangeAfterCall"), so the creates read it back as
# the run's and the undo does not. undo_calls <log>: the IAM and EC2 delete-side calls of the case.
cat > "$WORK/tag-change.py" <<'PY'
import os, sys
sys.path.insert(0, os.environ["FAKE_TESTLIB"])
import fakelib
kind, argv = sys.argv[1], sys.argv[2:]
op = {"sg": "create-security-group", "role": "create-role", "profile": "create-instance-profile"}[kind]
if op in argv:
    key = {"sg": "--group-name", "role": "--role-name", "profile": "--instance-profile-name"}[kind]
    name = argv[argv.index(key) + 1]
    other = [{"Key": "ManagedBy", "Value": "cilium-bottlerocket-sample"}, {"Key": "RunId", "Value": "r2"}]
    with fakelib.world() as (state, _):
        if kind == "sg":
            obj = next(g for g in state["ec2"]["security_groups"] if g.get("GroupName") == name)
        else:
            obj = state["iam"]["roles" if kind == "role" else "profiles"][name]
        obj["RecheckTags"], obj["ChangeAfterCall"] = other, "packer validate"
PY
tag_change() {
  printf '#!/bin/sh\n"%s" "%s" "$@"; rc=$?\n[ "$rc" != 0 ] || "%s" "%s" %s "$@"\nexit "$rc"\n' \
    "$REAL_PYTHON" "$TESTLIB/fake_aws.py" "$REAL_PYTHON" "$WORK/tag-change.py" "$1" > "$WORK/bin/aws"
  chmod 0755 "$WORK/bin/aws"
}
undo_calls() {
  python3 -c 'import json, sys
for l in open(sys.argv[1]):
    c = json.loads(l)
    if c["tool"] == "aws" and any(w in c["call"] for w in ("delete", "remove", "detach")):
        print(c["call"])' "$FAKE_LOG" > "$WORK/undo-calls.txt"
}
while IFS='~' read -r kind kept done_calls why; do
  [[ -n "$why" ]] || continue
  prep 's["packer"]["validate_rc"] = 1'; tag_change "$kind"
  CB_WAIT_TRIES=2 run_real "$WORK/b-undo-tag.log" bash "$BUILD" build
  stub_install aws fake_aws.py
  check "$why" 1 "$RC" "$WORK/b-undo-tag.log" '^ERROR: E_UNDO_LEFTOVER: a part this attempt created remains \(see above\); run \./clean\.sh --dry-run$'
  undo_calls
  [[ "$(sort "$WORK/undo-calls.txt" | tr '\n' ' ')" == "$done_calls" ]] && grep -q "^undo: the $kind is not this run's before " "$WORK/b-undo-tag.log" \
    && [[ "$(world_get "$kept")" == true ]]
  check "  ... the $kind is left for clean.sh, and only the other steps run (${done_calls% })" 0 $? "$WORK/undo-calls.txt"
done <<'CASES'
sg~len([g for g in s["ec2"]["security_groups"] if g.get("GroupName") == "cb-offline-test-r1-builder"]) == 1~iam delete-instance-profile iam delete-role iam detach-role-policy iam remove-role-from-instance-profile ~REJECT an undo whose security group has another RunId when read back before its delete
role~"cb-offline-test-r1-builder" in s["iam"]["roles"] and "cb-offline-test-r1-builder" in s["iam"]["profiles"]~ec2 delete-security-group ~REJECT an undo whose role has another RunId when read back: the profile keeps the role, both left
profile~"cb-offline-test-r1-builder" in s["iam"]["profiles"] and "cb-offline-test-r1-builder" in s["iam"]["roles"]~ec2 delete-security-group ~REJECT an undo whose instance profile has another RunId when read back: the profile and role left
CASES
# A part that cannot be read back just before its step is left too (exit 2). The sixth FAKE_FAIL
# field lets the reads of the creates pass first.
while IFS='~' read -r fail done_calls why; do
  [[ -n "$why" ]] || continue
  prep 's["packer"]["validate_rc"] = 1'
  FAKE_FAIL="$fail" CB_WAIT_TRIES=2 run_real "$WORK/b-undo-noread.log" bash "$BUILD" build
  check "$why" 2 "$RC" "$WORK/b-undo-noread.log" '^ERROR: E_UNDO_LEFTOVER: a part this attempt created could not be read back \(see above\); run \./clean\.sh --dry-run$'
  undo_calls
  [[ "$(sort "$WORK/undo-calls.txt" | tr '\n' ' ')" == "$done_calls" ]] && grep -q '^undo: the .* could not be read back before ' "$WORK/b-undo-noread.log"
  check "  ... the unreadable part gets no delete (${done_calls% })" 0 $? "$WORK/undo-calls.txt"
done <<'CASES'
aws|ec2 describe-security-groups||RequestLimitExceeded||1~iam delete-instance-profile iam delete-role iam detach-role-policy iam remove-role-from-instance-profile ~REJECT an undo whose security group cannot be read back before its delete
aws|iam get-instance-profile||ServiceFailure||1~ec2 delete-security-group ~REJECT an undo whose instance profile cannot be read back before the role is removed from it
CASES

echo "== 4/4 build: during and after Packer ==============================================="
prep 's["packer"]["builder_overrides"] = {"KeyName": "a-key"}'
run_real "$WORK/b-key.log" bash "$BUILD" build
check "REJECT a builder with a key pair at stage bind" 1 "$RC" "$WORK/b-key.log" '^ERROR: E_BUILDER_KEY: '
grep -q '^ERROR: E_PACKER_BUILD: ' "$WORK/b-key.log" && [[ -z "$(st SANDBOX_AMI_ID)" ]] && ! ev | grep -q 'status='
check "  ... the build stops (E_PACKER_BUILD), no stage command is sent and no AMI is recorded" 0 $? "$WORK/b-key.log"
prep 's["packer"]["builder_overrides"] = {"PublicIpAddress": "198.51.100.7"}'
run_real "$WORK/b-pip.log" bash "$BUILD" build
check "REJECT a builder with a public IP address at stage bind" 1 "$RC" "$WORK/b-pip.log" '^ERROR: E_BUILDER_PUBLIC_IP: '
prep 's["packer"]["eni_tags_override"] = {"RunId": "r2"}'
run_real "$WORK/b-eni.log" bash "$BUILD" build
check "REJECT a builder whose network interface is tagged for another run, at stage bind" 1 "$RC" "$WORK/b-eni.log" '^ERROR: E_BUILDER_ENI_TAGS: '
grep -q '^ERROR: E_PACKER_BUILD: ' "$WORK/b-eni.log" && [[ "$(st BUILDER_ENI_IDS)" =~ ^eni-[0-9a-f]{17}$ && -z "$(st SANDBOX_AMI_ID)" ]] && ! ev | grep -q 'status='
check "  ... the build stops (E_PACKER_BUILD) before any stage command, with BUILDER_ENI_IDS recorded for clean.sh" 0 $? "$WORK/b-eni.log"
prep 's["packer"]["eni_tags_override"] = {"ManagedBy": None}'
run_real "$WORK/b-eni2.log" bash "$BUILD" build
check "REJECT a builder whose network interface has no ManagedBy tag, at stage bind" 1 "$RC" "$WORK/b-eni2.log" '^ERROR: E_BUILDER_ENI_TAGS: ManagedBy=None'
prep 's["ssm"]["results"] = [{"match": "40-build.sh", "Status": "Failed", "stdout": "", "stderr": "cargo make failed"}, {"match": "", "Status": "Success", "stdout": "ok"}]'
run_real "$WORK/b-stagefail.log" bash "$BUILD" build
check "REJECT a stage whose Run Command fails: the build stops" 1 "$RC" "$WORK/b-stagefail.log" '^ERROR: E_PACKER_BUILD: packer build exited'
ev | grep -qE '^packer-stage build command_id=[0-9a-f-]{36} status=Failed$' && ev | grep -q '^builder-gone '
check "  ... the evidence shows the failed stage, and the builder parts are gone anyway" 0 $? "$WORK/b-stagefail.log"
prep 's["ssm"]["online"] = False'
CB_WAIT_TRIES=2 run_real "$WORK/b-online.log" bash "$BUILD" build
check "REJECT a builder that never reports Online to Systems Manager" 1 "$RC" "$WORK/b-online.log" '^ERROR: E_SSM_ONLINE: '
prep 's["packer"]["leftovers"] = ["volume"]'
CB_WAIT_TRIES=2 run_real "$WORK/b-left.log" bash "$BUILD" build
check "REJECT a builder volume that remains after the build" 1 "$RC" "$WORK/b-left.log" '^ERROR: E_LEFTOVER: a builder resource remains'
# The system node has the run tags but not the builder's Name tag, so the by-tag reads after the
# build (run tags and the builder's Name) do not count it.
RUNTAGS='{"Key": "ManagedBy", "Value": "cilium-bottlerocket-sample"}, {"Key": "RunId", "Value": "r1"}'
SYSNODE='s["ec2"]["instances"].append({"InstanceId": "i-0fd00000000000001", "State": {"Name": "running"}, "Tags": ['"$RUNTAGS"', {"Key": "eks:nodegroup-name", "Value": "system"}]})
s["ec2"]["volumes"].append({"VolumeId": "vol-0fd00000000000001", "State": "in-use", "Tags": ['"$RUNTAGS"'], "Attachments": [{"InstanceId": "i-0fd00000000000001", "State": "attached"}]})'
prep "$SYSNODE"
CB_WAIT_TRIES=2 run_real "$WORK/b-sysnode.log" bash "$BUILD" build
check "ACCEPT a build beside a running system node that has the run tags and no builder Name tag" 0 "$RC" "$WORK/b-sysnode.log"
cover accept E_LEFTOVER
ev | grep -q '^builder-gone instance=terminated volumes=absent sg=absent profile=absent role=absent$' \
  && [[ "$(world_get '[i["State"]["Name"] for i in s["ec2"]["instances"] if i["InstanceId"] == "i-0fd00000000000001"] + [v["VolumeId"] for v in s["ec2"]["volumes"]]')" == '["running", "vol-0fd00000000000001"]' ]]
check "  ... builder-gone is recorded, and the system node and its volume are untouched" 0 $? "$WORK/b-sysnode.log"
while IFS='~' read -r code why; do
  [[ -n "$why" ]] || continue
  prep "$SYSNODE
$code"
  CB_WAIT_TRIES=2 run_real "$WORK/b-named.log" bash "$BUILD" build
  check "$why" 1 "$RC" "$WORK/b-named.log" '^ERROR: E_LEFTOVER: a builder resource remains'
done <<CASES
s["ec2"]["instances"].append({"InstanceId": "i-0fd00000000000002", "State": {"Name": "running"}, "Tags": [$RUNTAGS, {"Key": "Name", "Value": "cb-offline-test-r1-builder"}]})~REJECT a running instance with the run tags and the builder's Name tag after the build (beside the system node)
s["ec2"]["volumes"].append({"VolumeId": "vol-0fd00000000000002", "State": "available", "Tags": [$RUNTAGS, {"Key": "Name", "Value": "cb-offline-test-r1-builder"}], "Attachments": []})~REJECT a volume with the run tags and the builder's Name tag after the build (beside the system node)
CASES
prep; FAKE_FAIL='aws|iam get-role|cb-offline-test-r1-builder|ServiceUnavailable' CB_WAIT_TRIES=1 run_real "$WORK/b-leftread.log" bash "$BUILD" build
check "REJECT a builder role read that fails after the build, as could not determine (exit 2)" 2 "$RC" "$WORK/b-leftread.log" '^ERROR: E_LEFTOVER: a builder resource could not be read'
while IFS='|' read -r code tag why; do
  [[ -n "$code" ]] || continue
  prep "$code"
  run_real "$WORK/b-art.log" bash "$BUILD" build
  check "$why" 1 "$RC" "$WORK/b-art.log" "^ERROR: $tag: "
  [[ "$(st AMI_BUILD_RESULT)" != ok ]]; check "  ... and AMI_BUILD_RESULT is not ok" 0 $? "$WORK/b-art.log"
done <<'CASES'
s["packer"]["manifest"] = "two-amis"|E_MANIFEST_COUNT|REJECT a Packer manifest with two AMIs
s["packer"]["manifest"] = "zero"|E_MANIFEST_COUNT|REJECT a Packer manifest with no AMI
s["packer"]["manifest"] = "wrong-run-id"|E_MANIFEST_RUN_ID|REJECT a Packer manifest of another run
s["packer"]["snapshots"] = 3|E_IMAGE_MAPPINGS|REJECT an AMI with a third snapshot (a builder volume not omitted)
s["packer"]["image_tags_override"] = {"SandboxSlots": "57"}|E_IMAGE_SLOTS|REJECT an AMI whose SandboxSlots tag is not SANDBOX_SLOTS
s["packer"]["registration"] = {"UefiData": "QUJD"}|E_IMAGE_UEFI_DATA|REJECT an AMI with UEFI variable data
s["packer"]["registration"] = {"BootMode": "legacy-bios"}|E_IMAGE_BOOT_MODE|REJECT an AMI registered legacy-bios
s["packer"]["untagged_snapshot"] = True|E_SNAP_TAGS|REJECT an AMI with an untagged data snapshot
CASES
# An interrupted build (Ctrl-C, SIGINT to the process group): Packer terminates its builder, the
# script still deletes the builder SG, profile and role and reads each one back, then stops.
prep 's["packer"]["hang"] = "stage:3"'
cloud_guard "$PATH"
setsid bash "$BUILD" build > "$WORK/b-int.log" 2>&1 < /dev/null &
bpid=$!
for _ in $(seq 1 300); do grep -q '"waiting for SIGINT"' "$FAKE_LOG" 2>/dev/null && break; sleep 0.1; done
kill -INT -- "-$bpid" 2>/dev/null
rc=0; wait "$bpid" || rc=$?
echo "exit=$rc" >> "$WORK/b-int.log"
check "REJECT an interrupted build (SIGINT): the script exits 1 and records no AMI" 1 "$rc" "$WORK/b-int.log" '^ERROR: E_PACKER_BUILD: '
grep -q '^builder-gone instance=terminated volumes=absent sg=absent profile=absent role=absent$' "$WORK/b-int.log" \
  && [[ "$(world_get 'len([g for g in s["ec2"]["security_groups"] if g.get("GroupName") == "cb-offline-test-r1-builder"]) + len(s["iam"]["roles"]) + len(s["iam"]["profiles"])')" == 0 ]]
check "  ... after the interrupt the builder, its SG, profile and role are gone and read back as gone" 0 $? "$WORK/b-int.log"
# A build that is killed outright (SIGKILL, a closed terminal): nothing can clean up. The builder,
# its volumes, its SG, profile and role survive, and the state file names each one, so clean.sh
# finds them (scripts/test-clean.sh proves the delete order from this state).
prep 's["packer"]["hang"] = "stage:3"'
cloud_guard "$PATH"
setsid bash "$BUILD" build > "$WORK/b-kill.log" 2>&1 < /dev/null &
bpid=$!
for _ in $(seq 1 300); do grep -q '"waiting for SIGINT"' "$FAKE_LOG" 2>/dev/null && break; sleep 0.1; done
kill -KILL -- "-$bpid" 2>/dev/null; wait "$bpid" 2>/dev/null
[[ -n "$(st BUILDER_SG_ID)" && -n "$(st BUILDER_ROLE_NAME)" && -n "$(st BUILDER_PROFILE_NAME)" && -n "$(st BUILDER_INSTANCE_ID)" \
   && -n "$(st BUILDER_VOLUME_IDS)" && "$(st AMI_BUILD_RESULT)" != ok ]]
check "ACCEPT a killed build's state file: it names the builder, its volumes, SG, role and profile, and no AMI result" 0 $? "$CB_RUN_DIR/runs/r1/state.env"
sgid="$(st BUILDER_SG_ID)"
[[ "$(world_get "len([g for g in s['ec2']['security_groups'] if g['GroupId'] == '$sgid'])")" == 1 \
   && "$(world_get 'len([i for i in s["ec2"]["instances"] if i["State"]["Name"] == "running"])')" == 1 ]]
check "  ... and the builder security group survives the killed build beside the running builder" 0 $? "$WORK/b-kill.log"
finish
