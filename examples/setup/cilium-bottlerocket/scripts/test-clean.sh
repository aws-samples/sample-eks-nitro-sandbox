#!/usr/bin/env bash
# test-clean.sh: proves clean.sh both ways, the REAL script, against a fake world of one finished
# run (scripts/testlib/world_full.py) with the stub commands first on PATH:
#   --dry-run              lists only the run's tagged resources and changes nothing        (#281)
#   confirmation           no typed cluster name: nothing is deleted
#   the delete order       workloads, node groups, Cilium ENIs; builders, their volumes, the
#                          builder SG, profile and role; launch templates; the AMI and its
#                          snapshots; the Pod Identity association and the cluster stacks  (#281)
#   changed owner          a resource whose tags change between discovery and its delete is
#                          skipped, on every delete path, and the run exits non-zero      (#281)
#   a killed build         a killed build's builder SG is deleted before eksctl delete cluster; a
#                          builder SG that cannot be deleted keeps the cluster
#   --keep-ami             the AMI and its snapshots stay, everything else goes
#   read-back              a resource that remains, or a lookup that fails, is a non-zero exit
#   interrupted runs       a run with no cluster, a short state file
# Resources of another run (RunId r2), an untagged volume and another owner's VPC and security
# group sit in the same world and must survive every case.
#
#   examples/setup/cilium-bottlerocket/scripts/test-clean.sh
source "$(dirname "$0")/testlib/harness.sh"
CLEAN="$SAMPLE_DIR_REAL/clean.sh"
need_file "$CLEAN" "every clean.sh case" || finish
RD="$CB_RUN_DIR/runs/r1"

# full [<world case> ...]: the finished-run world and state file; then $1.. may be changed by world_py.
full() {
  world_reset
  rm -rf "$CB_RUN_DIR/runs" "$CB_RUN_DIR/current-run"
  mkdir -p -m 700 "$RD"
  python3 "$TESTLIB/world_full.py" "$FAKE_STATE" "$RD/state.env" "$@"
  chmod 600 "$RD/state.env"
  printf 'r1\n' > "$CB_RUN_DIR/current-run"
  export RUN_ID=r1
}
# clean <log> [args...]: run the real clean.sh with the typed confirmation given; sets RC.
clean() { local log="$1"; shift; CLEAN_CONFIRM=cb-offline-test run_real "$log" bash "$CLEAN" "$@"; }
# mutations: the number of calls that change something (written, with the calls, to $WORK/mutations.txt).
mutations() {
  python3 - "$FAKE_LOG" > "$WORK/mutations.txt" <<'PY'
import json, re, sys
pat = re.compile(r"^(aws ec2 (terminate-instances|delete-|deregister-image|release-address|revoke-|create-|authorize-)"
                 r"|aws iam (delete-|remove-|detach-|create-|put-|attach-|tag-)|aws eks (delete-|create-|update-kubeconfig)"
                 r"|aws cloudformation delete-stack|aws autoscaling (create|delete|update)"
                 r"|eksctl (delete|create)|kubectl (delete|apply|create)|helm (uninstall|upgrade|install))")
hits = [f"{e['seq']} {e['tool']} {e['call']}" for e in map(json.loads, open(sys.argv[1]))
        if pat.match(f"{e['tool']} {e['call']}")]
print("\n".join(hits))
PY
  grep -c . "$WORK/mutations.txt" || true
}
# alive <python expression on s>: 0 when it is true of the world.
alive() { [[ "$(world_get "$1")" == true ]]; }
FOREIGN='any(i["ImageId"] == "ami-0fa00000000000202" for i in s["ec2"]["images"]) and any(x["SnapshotId"] == "snap-0fa00000000000202" for x in s["ec2"]["snapshots"]) and any(x["LaunchTemplateId"] == "lt-0fa00000000000202" for x in s["ec2"]["launch_templates"]) and any(v["VolumeId"] == "vol-0fa00000000000999" for v in s["ec2"]["volumes"]) and any(g["GroupId"] == "sg-0fd00000000000999" for g in s["ec2"]["security_groups"]) and any(v["VpcId"] == "vpc-0fa00000000000999" for v in s["ec2"]["vpcs"])'
# The run's resources, counted from the world: 0 when the run left nothing.
RUN_LEFT='len([1 for k, v in s["ec2"].items() if isinstance(v, list) for x in v if {t["Key"]: t["Value"] for t in (x.get("TagSet") or x.get("Tags") or [])}.get("RunId") == "r1" and x.get("State") not in ({"Name": "terminated"}, "deleted")]) + len(s["eks"]["clusters"]) + len(s["eks"]["nodegroups"]) + len(s["eks"]["pod_identity"]) + len(s["iam"]["roles"]) + len(s["iam"]["profiles"]) + len(s["autoscaling"]["groups"]) + len([1 for st in s["cloudformation"]["stacks"].values() if st["StackStatus"] != "DELETE_COMPLETE"]) + len(s["k8s"]["objects"])'

echo "== 1/6 --dry-run and the confirmation ==============================================="
entry clean.sh
full
clean "$WORK/dry.log" --dry-run
check "ACCEPT --dry-run: it lists the run's resources and exits 0 (the no-change line)" 0 "$RC" "$WORK/dry.log" \
  '^No AWS resource or Kubernetes object was changed\. Run \./clean\.sh without --dry-run to delete these\.$'
cover accept E_USAGE E_REGION E_ACCOUNT E_RUN_ID E_RUN_RECORD E_CLUSTER_READ E_CLUSTER_OWNER E_VPC_READ E_CLEAN_INVENTORY E_NOT_CONFIRMED
[[ "$(mutations)" == 0 ]]; check "  ... and makes no delete, terminate, deregister, release or create call" 0 $? "$WORK/mutations.txt"
grep -Eq '^  ami +ami-0fa00000000000101$' "$WORK/dry.log" && grep -Eq '^  ami-snapshot +snap-0fa00000000000001$' "$WORK/dry.log" \
  && grep -Eq '^  cilium-eni +eni-0fa00000000000302$' "$WORK/dry.log" && grep -Eq '^  launch-template +lt-0fa00000000000001$' "$WORK/dry.log" \
  && grep -Eq '^  eks-cluster +cb-offline-test$' "$WORK/dry.log"
check "  ... the list names the AMI, a snapshot, a Cilium ENI, a launch template and the cluster" 0 $? "$WORK/dry.log"
! grep -Eq 'ami-0fa00000000000202|snap-0fa00000000000202|lt-0fa00000000000202|vol-0fa00000000000999|sg-0fd00000000000999|vpc-0fa00000000000999' "$WORK/dry.log"
check "  ... and lists only tagged resources of run r1 (not run r2's AMI, snapshot and template, an untagged volume or another owner's VPC)" 0 $? "$WORK/dry.log"
full; run_real "$WORK/noconfirm.log" bash "$CLEAN"
check "REJECT a clean up with no typed confirmation: nothing is deleted" 1 "$RC" "$WORK/noconfirm.log" '^ERROR: E_NOT_CONFIRMED: not confirmed; nothing was deleted'
[[ "$(mutations)" == 0 ]]; check "  ... and no delete call was made" 0 $? "$WORK/mutations.txt"
full; CLEAN_CONFIRM=another-cluster run_real "$WORK/wrongconfirm.log" bash "$CLEAN"
check "REJECT a typed confirmation that is not the cluster name" 1 "$RC" "$WORK/wrongconfirm.log" '^ERROR: E_NOT_CONFIRMED: '
full; clean "$WORK/usage.log" --everything
check "REJECT an unknown option" 1 "$RC" "$WORK/usage.log" '^ERROR: E_USAGE: '
# --run-id needs a value; with none, the run is never taken from current-run.
# The accept case points current-run at another run, so the listed run is the one --run-id names.
full; printf 'r9\n' > "$CB_RUN_DIR/current-run"; unset RUN_ID
clean "$WORK/rid-ok.log" --dry-run --run-id r1
check "ACCEPT --dry-run --run-id r1 while current-run names r9: it lists run r1" 0 "$RC" "$WORK/rid-ok.log" '^  launch-template +lt-0fa00000000000001$'
while IFS='|' read -r label args; do
  [[ -n "$label" ]] || continue
  full; unset RUN_ID
  # shellcheck disable=SC2086 # args is a fixed word list from the table ('' is an empty argument)
  eval "clean \"\$WORK/rid-bad.log\" $args"
  check "REJECT --run-id with $label" 1 "$RC" "$WORK/rid-bad.log" '^ERROR: E_USAGE: --run-id needs a run ID$'
  [[ "$(count_calls aws)" == 0 && "$(count_calls kubectl)" == 0 ]]
  check "  ... before any AWS or kubectl call ($label)" 0 $? "$WORK/rid-bad.log"
done <<'CASES'
no value (the last argument)|--dry-run --run-id
an empty value|--dry-run --run-id ''
an option-shaped value (--keep-ami)|--run-id --keep-ami
an option-shaped value (--dry-run)|--run-id --dry-run
CASES
export RUN_ID=r1
full; world_py 's["account"] = "2" * 12'; clean "$WORK/acct.log" --dry-run
check "REJECT a caller in another account, before any read of the run" 1 "$RC" "$WORK/acct.log" '^ERROR: E_ACCOUNT: '
full; sed -i 's/^CLUSTER_NAME=.*/CLUSTER_NAME=another-cluster/' "$RD/state.env"; clean "$WORK/record.log" --dry-run
check "REJECT a run record of another cluster" 1 "$RC" "$WORK/record.log" '^ERROR: E_RUN_RECORD: '
full; world_py 's["eks"]["clusters"]["cb-offline-test"]["tags"]["RunId"] = "r2"'; clean "$WORK/cl-owner.log"
check "REJECT a same-name cluster of another run: nothing is deleted" 1 "$RC" "$WORK/cl-owner.log" '^ERROR: E_CLUSTER_OWNER: '
[[ "$(mutations)" == 0 ]]; check "  ... and no delete call was made" 0 $? "$WORK/mutations.txt"
full; FAKE_FAIL='aws|eks describe-cluster||AccessDeniedException' clean "$WORK/cl-read.log" --dry-run
check "REJECT a cluster read that fails, never read as gone" 1 "$RC" "$WORK/cl-read.log" '^ERROR: E_CLUSTER_READ: '
full no-cluster; FAKE_FAIL='aws|ec2 describe-vpcs||RequestLimitExceeded' clean "$WORK/vpc-read.log" --dry-run
check "REJECT a run with no cluster whose VPC lookup by tags fails" 1 "$RC" "$WORK/vpc-read.log" '^ERROR: E_VPC_READ: could not look up the VPC'
full no-cluster; world_py 's["ec2"]["vpcs"].append(dict(s["ec2"]["vpcs"][0], VpcId="vpc-0fa00000000000002"))'; clean "$WORK/vpc-two.log" --dry-run
check "REJECT a run with two VPCs tagged for it" 1 "$RC" "$WORK/vpc-two.log" '^ERROR: E_VPC_READ: run r1 has more than one VPC'
full; FAKE_FAIL='aws|ec2 describe-launch-templates||RequestLimitExceeded' clean "$WORK/inv-read.log" --dry-run
check "REJECT --dry-run when the inventory read fails, as could not determine (exit 2)" 2 "$RC" "$WORK/inv-read.log" '^ERROR: E_CLEAN_INVENTORY: '

echo "== 2/6 the full clean up and its order ============================================"
full
clean "$WORK/full.log"
check "ACCEPT a full clean up of a finished run: every resource of the run is gone and read back as gone" 0 "$RC" "$WORK/full.log" '^CLEAN: run r1 .*nothing left behind\.$'
[[ "$(world_get "$RUN_LEFT")" == 0 ]]; check "  ... the world holds no resource of run r1" 0 $? "$WORK/full.log"
alive "$FOREIGN"; check "  ... and run r2's AMI, snapshot and template, the untagged volume and the other owner's VPC and SG remain" 0 $? "$WORK/full.log"
# order: each phase's last call comes before the next phase's first call (one log for all tools)
python3 - "$FAKE_LOG" > "$WORK/order.txt" <<'PY'
import json, re, sys
phases = [
    ("1 workloads, node groups, Cilium ENIs", [r"^kubectl delete objects", r"^eksctl delete nodegroup", r"^aws ec2 delete-network-interface"]),
    ("3 launch templates", [r"^aws ec2 delete-launch-template"]),
    ("4 AMI", [r"^aws ec2 deregister-image"]),
    ("4 snapshots", [r"^aws ec2 delete-snapshot"]),
    ("5 Pod Identity", [r"^aws eks delete-pod-identity-association"]),
    ("5 cluster", [r"^eksctl delete cluster"]),
]
seqs = {}
for line in open(sys.argv[1]):
    e = json.loads(line)
    c = f"{e['tool']} {e['call']}"
    for name, pats in phases:
        if any(re.search(p, c) for p in pats):
            seqs.setdefault(name, []).append(e["seq"])
bad = 0
for (a, _), (b, _) in zip(phases, phases[1:]):
    if a not in seqs or b not in seqs:
        print(f"missing phase: {a if a not in seqs else b}"); bad = 1; continue
    ok = max(seqs[a]) < min(seqs[b])
    print(f"{'ok ' if ok else 'BAD'} {a} (last {max(seqs[a])}) before {b} (first {min(seqs[b])})")
    bad |= not ok
sys.exit(bad)
PY
check "  ... in the #281 order: workloads and node groups and Cilium ENIs, launch templates, the AMI, its snapshots, Pod Identity, the cluster" 0 $? "$WORK/order.txt"
python3 - "$FAKE_LOG" > "$WORK/reread.txt" <<'PY'
# Before each EC2 or IAM delete, the same resource was read by its ID (the tag re-read).
import json, sys
log = [json.loads(l) for l in open(sys.argv[1])]
idopt = {"delete-network-interface": "--network-interface-id", "terminate-instances": "--instance-ids",
         "delete-volume": "--volume-id", "delete-security-group": "--group-id", "delete-launch-template": "--launch-template-id",
         "deregister-image": "--image-id", "delete-snapshot": "--snapshot-id"}
bad = 0
for i, e in enumerate(log):
    if e["tool"] != "aws" or not e["call"].startswith("ec2 "):
        continue
    op = e["call"].split()[1]
    if op not in idopt:
        continue
    ident = e["argv"][e["argv"].index(idopt[op]) + 1]
    prior = [p for p in log[:i] if p["tool"] == "aws" and p["call"].startswith("ec2 describe-") and ident in p["argv"]]
    print(("ok " if prior else "BAD") + f" {op} {ident}: {len(prior)} read(s) by ID before it")
    bad |= not prior
sys.exit(bad)
PY
check "  ... and every EC2 delete was preceded by a read of that resource by its ID" 0 $? "$WORK/reread.txt"

echo "== 3/6 a changed owner on every delete path ======================================="
# Each case changes one resource's tags after discovery (by-ID reads, or after a named call);
# clean.sh must skip it, leave it in the world, and exit non-zero.
while IFS='|' read -r code still why; do
  [[ -n "$code" ]] || continue
  full killed-build; world_py "$code"
  clean "$WORK/owner.log"
  check "REJECT a changed owner on the $why delete path: skipped, and the clean up exits non-zero" 1 "$RC" "$WORK/owner.log" \
    '(not tagged for run r1; skipped|is not this sample.s; skipped|not tagged for run r1, or could not be read; skipped|ERROR: E_CLUSTER_OWNER: )'
  alive "$still"; check "  ... the $why is still there" 0 $? "$WORK/owner.log"
done <<'CASES'
[x for x in s["ec2"]["network_interfaces"] if x["NetworkInterfaceId"] == "eni-0fa00000000000302"][0]["RecheckTags"] = [{"Key": "ManagedBy", "Value": "cilium-bottlerocket-sample"}, {"Key": "RunId", "Value": "r2"}]|any(x["NetworkInterfaceId"] == "eni-0fa00000000000302" for x in s["ec2"]["network_interfaces"])|Cilium ENI
[x for x in s["ec2"]["instances"] if x["InstanceId"] == "i-0fb00000000000001"][0]["RecheckTags"] = [{"Key": "team", "Value": "someone-else"}]|any(x["InstanceId"] == "i-0fb00000000000001" and x["State"]["Name"] == "running" for x in s["ec2"]["instances"])|builder instance
[x for x in s["ec2"]["security_groups"] if x["GroupId"] == "sg-0fc00000000000001"][0]["RecheckTags"] = [{"Key": "team", "Value": "someone-else"}]|any(x["GroupId"] == "sg-0fc00000000000001" for x in s["ec2"]["security_groups"])|builder security group
s["iam"]["profiles"]["cb-offline-test-r1-builder"]["RecheckTags"] = [{"Key": "team", "Value": "someone-else"}]|"cb-offline-test-r1-builder" in s["iam"]["profiles"]|builder instance profile
s["iam"]["roles"]["cb-offline-test-r1-builder"]["RecheckTags"] = [{"Key": "team", "Value": "someone-else"}]|"cb-offline-test-r1-builder" in s["iam"]["roles"]|builder role
[x for x in s["ec2"]["launch_templates"] if x["LaunchTemplateId"] == "lt-0fa00000000000001"][0]["RecheckTags"] = [{"Key": "RunId", "Value": "r2"}]|any(x["LaunchTemplateId"] == "lt-0fa00000000000001" for x in s["ec2"]["launch_templates"])|launch template
[x for x in s["ec2"]["images"] if x["ImageId"] == "ami-0fa00000000000101"][0]["RecheckTags"] = [{"Key": "RunId", "Value": "r2"}]|any(x["ImageId"] == "ami-0fa00000000000101" for x in s["ec2"]["images"])|AMI
s["eks"]["nodegroups"]["cb-offline-test/sandbox"]["RecheckTags"] = {"team": "someone-else"}; s["eks"]["nodegroups"]["cb-offline-test/sandbox"]["ChangeAfterCall"] = "aws ec2 describe-images"|"cb-offline-test/sandbox" in s["eks"]["nodegroups"]|sandbox node group
s["eks"]["pod_identity"]["a-fake000000000001"]["RecheckTags"] = {"team": "someone-else"}; s["eks"]["pod_identity"]["a-fake000000000001"]["ChangeAfterCall"] = "aws ec2 delete-launch-template"|"a-fake000000000001" in s["eks"]["pod_identity"]|Pod Identity association
s["eks"]["clusters"]["cb-offline-test"]["RecheckTags"] = {"team": "someone-else"}; s["eks"]["clusters"]["cb-offline-test"]["ChangeAfterCall"] = "aws ec2 delete-launch-template"|"cb-offline-test" in s["eks"]["clusters"]|cluster
s["k8s"]["objects"]["namespaces/-/cilium-bottlerocket-demo"]["metadata"]["labels"] = {"team": "someone-else"}|"namespaces/-/cilium-bottlerocket-demo" in s["k8s"]["objects"]|namespace
CASES
full killed-build
world_py '[x for x in s["ec2"]["snapshots"] if x["SnapshotId"] == "snap-0fa00000000000001"][0]["RecheckTags"] = [{"Key": "RunId", "Value": "r2"}]'
world_py 's["ec2"]["images"][0]["BlockDeviceMappings"] = []'
clean "$WORK/owner-snap.log"
check "REJECT a changed owner on the AMI snapshot delete path: skipped, and the clean up exits non-zero" 1 "$RC" "$WORK/owner-snap.log" 'snapshot snap-0fa00000000000001 is not tagged for run r1; skipped'
alive 'any(x["SnapshotId"] == "snap-0fa00000000000001" for x in s["ec2"]["snapshots"])'; check "  ... the snapshot is still there" 0 $? "$WORK/owner-snap.log"
# The cluster stack of a run that stopped before the cluster (clean.sh step 5, the no-cluster branch).
full no-cluster
world_py 's["cloudformation"]["stacks"]["eksctl-cb-offline-test-cluster"]["RecheckTags"] = [{"Key": "team", "Value": "someone-else"}]'
clean "$WORK/owner-stack.log"
check "REJECT a changed owner on the cluster stack delete path (no cluster): skipped, and the clean up exits non-zero" 1 "$RC" "$WORK/owner-stack.log" 'stack eksctl-cb-offline-test-cluster is not tagged for run r1; skipped'
alive 's["cloudformation"]["stacks"]["eksctl-cb-offline-test-cluster"]["StackStatus"] != "DELETE_COMPLETE" and len(s["ec2"]["vpcs"]) == 2'
check "  ... the cluster stack and its VPC are still there" 0 $? "$WORK/owner-stack.log"
# The Cilium operator role when it outlives eksctl delete cluster (clean.sh step 5, the role read).
full killed-build; world_py 's["iam"]["roles"]["cb-offline-test-cilium-operator"].pop("Stack")'
clean "$WORK/oprole.log"
check "ACCEPT an operator role that outlives eksctl delete cluster: read again, then deleted" 0 "$RC" "$WORK/oprole.log" '^deleted iam-role cb-offline-test-cilium-operator$'
full killed-build; world_py 's["iam"]["roles"]["cb-offline-test-cilium-operator"].pop("Stack"); s["iam"]["roles"]["cb-offline-test-cilium-operator"]["RecheckTags"] = [{"Key": "team", "Value": "someone-else"}]'
clean "$WORK/owner-oprole.log"
check "REJECT a changed owner on the operator role delete path: skipped, and the clean up exits non-zero" 1 "$RC" "$WORK/owner-oprole.log" 'iam-role cb-offline-test-cilium-operator is not tagged for run r1; skipped'
alive '"cb-offline-test-cilium-operator" in s["iam"]["roles"]'; check "  ... the operator role is still there" 0 $? "$WORK/owner-oprole.log"

echo "== 4/6 the builder security group of a killed build ==============================="
full killed-build
clean "$WORK/killed.log"
check "ACCEPT the clean up of a killed build: builder, volumes, SG, profile and role, then the rest" 0 "$RC" "$WORK/killed.log" '^CLEAN: run r1 .*nothing left behind\.$'
python3 - "$FAKE_LOG" > "$WORK/mf5.txt" <<'PY'
import json, sys
log = [json.loads(l) for l in open(sys.argv[1])]
def first(pred):
    return next((e["seq"] for e in log if pred(e)), None)
term = first(lambda e: e["call"] == "ec2 terminate-instances" and "i-0fb00000000000001" in e["argv"])
sg = first(lambda e: e["call"] == "ec2 delete-security-group" and "sg-0fc00000000000001" in e["argv"])
cl = first(lambda e: e["tool"] == "eksctl" and e["call"] == "delete cluster")
print(f"terminate builder={term} delete builder SG={sg} eksctl delete cluster={cl}")
sys.exit(0 if term and sg and cl and term < sg < cl else 1)
PY
check "  ... in this order: the builder terminates, then its SG is deleted, then eksctl deletes the cluster" 0 $? "$WORK/mf5.txt"
full killed-build
world_py '[x for x in s["ec2"]["security_groups"] if x["GroupId"] == "sg-0fc00000000000001"][0]["DeleteFails"] = "DependencyViolation"'
clean "$WORK/sgleft.log"
check "REJECT a builder SG that cannot be deleted: the cluster and its VPC are kept" 1 "$RC" "$WORK/sgleft.log" 'the cluster and its VPC are kept, because a builder security group remains'
[[ "$(count_calls eksctl 'delete cluster')" == 0 ]] && alive '"cb-offline-test" in s["eks"]["clusters"]'
check "  ... and eksctl delete cluster was never called" 0 $? "$WORK/sgleft.log"
full killed-build
FAKE_FAIL='aws|ec2 describe-security-groups|sg-0fc00000000000001|RequestLimitExceeded|50' clean "$WORK/sgread.log"
check "REJECT a builder SG that cannot be read again: the cluster is kept" 1 "$RC" "$WORK/sgread.log" 'builder security group sg-0fc00000000000001 is still there \(or could not be read\); the cluster is kept'
[[ "$(count_calls eksctl 'delete cluster')" == 0 ]]; check "  ... and eksctl delete cluster was never called" 0 $? "$WORK/sgread.log"

echo "== 5/6 --keep-ami, and the read-back ================================================"
full
clean "$WORK/keep.log" --keep-ami
check "ACCEPT --keep-ami: everything but the AMI and its snapshots is gone" 0 "$RC" "$WORK/keep.log" '^--keep-ami: the AMI and its snapshots stay'
[[ "$(count_calls aws 'ec2 deregister-image')" == 0 && "$(count_calls aws 'ec2 delete-snapshot')" == 0 ]] \
  && alive 'any(i["ImageId"] == "ami-0fa00000000000101" for i in s["ec2"]["images"]) and len([x for x in s["ec2"]["snapshots"] if x["SnapshotId"].startswith("snap-0fa0000000000000")]) == 2' \
  && alive 'len(s["eks"]["clusters"]) == 0 and not any(x["LaunchTemplateId"] == "lt-0fa00000000000001" for x in s["ec2"]["launch_templates"])'
check "  ... no deregister or snapshot delete was made; the AMI and both snapshots remain; the cluster and templates are gone" 0 $? "$WORK/keep.log"
grep -q '^kept: ' "$WORK/keep.log"; check "  ... and the read-back lists the AMI and snapshots as kept" 0 $? "$WORK/keep.log"
full; world_py '[x for x in s["ec2"]["launch_templates"] if x["LaunchTemplateId"] == "lt-0fa00000000000002"][0]["StaysAfterDelete"] = True'
clean "$WORK/stays.log"
check "REJECT a delete that answers success and leaves the resource: the read-back finds it" 1 "$RC" "$WORK/stays.log" '^CLEAN FAILED: still there: .*lt-0fa00000000000002'
full; FAKE_FAIL='aws|ec2 describe-launch-templates|--launch-template-ids lt-0fa00000000000001|RequestLimitExceeded' clean "$WORK/recheckfail.log"
check "REJECT a tag re-read that fails before a delete: could not read, the template stays" 1 "$RC" "$WORK/recheckfail.log" 'could not read launch-template lt-0fa00000000000001 before the delete'
alive 'any(x["LaunchTemplateId"] == "lt-0fa00000000000001" for x in s["ec2"]["launch_templates"])'; check "  ... and the template was not deleted" 0 $? "$WORK/recheckfail.log"

echo "== 6/6 interrupted runs =============================================================="
full no-cluster
clean "$WORK/nocluster.log"
check "ACCEPT the clean up of a run that stopped before the cluster: the VPC is found by its tags and the rest goes" 0 "$RC" "$WORK/nocluster.log"
full short-state
clean "$WORK/short.log"
check "ACCEPT the clean up of a run whose state file has only the run record: resources are found by their tags" 0 "$RC" "$WORK/short.log" '^CLEAN: run r1 .*nothing left behind\.$'
[[ "$(world_get "$RUN_LEFT")" == 0 ]]; check "  ... and the world holds no resource of run r1" 0 $? "$WORK/short.log"

echo "== 7/7 lock, verdict, inventory stops, stacks, state-named IDs, tools ======"
V="$RD/evidence/clean"
# The verdict and failures files.
full; clean "$WORK/g10-ok.log"
grep -Eqx 'run=r1 time=[0-9TZ:-]+ keep_ami=0 keep_cluster=0 failures=0 verdict=clean' "$V/verdict.txt" && [[ -f "$V/failures.txt" && ! -s "$V/failures.txt" ]]
check "ACCEPT a full clean up: verdict.txt says failures=0 verdict=clean, failures.txt is empty" 0 $? "$V/verdict.txt"
full; world_py '[x for x in s["ec2"]["launch_templates"] if x["LaunchTemplateId"] == "lt-0fa00000000000001"][0]["RecheckTags"] = [{"Key": "RunId", "Value": "r2"}]'
clean "$WORK/g10-bad.log"
grep -Eq ' failures=[1-9][0-9]* verdict=incomplete$' "$V/verdict.txt" && grep -qx 'launch-template lt-0fa00000000000001 is not tagged for run r1; skipped' "$V/failures.txt" \
  && [[ -f "$V/recheck-launch-template-lt-0fa00000000000001.err" ]]
check "REJECT a clean up with a skipped resource: verdict=incomplete, the skip in failures.txt, the recheck error in its own file" 0 $? "$V/failures.txt"
[[ "$RC" == 1 ]]; check "  ... and it exits 1" 0 $? "$WORK/g10-bad.log"
# The run lock of setup.sh; clean.sh never runs beside setup.sh or test.sh of the same run.
full; rm -f "$WORK/held"
python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").write("held"); time.sleep(60)' "$RD/run.lock" "$WORK/held" &
holder=$!
for _ in $(seq 1 100); do [[ -f "$WORK/held" ]] && break; sleep 0.1; done
: > "$FAKE_LOG"; clean "$WORK/g9.log"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check "REJECT a clean up while another process holds the run lock" 1 "$RC" "$WORK/g9.log" '^ERROR: E_RUN_LOCK: run r1 is in use: another process holds .*/run\.lock$'
[[ "$(mutations)" == 0 ]]; check "  ... and nothing is deleted" 0 $? "$WORK/mutations.txt"
cover accept E_RUN_LOCK   # every other clean up in this suite takes the lock
# The inventory read after the confirm, and the stops after step 1 and after the builders.
full; FAKE_FAIL='aws|ec2 describe-vpcs||RequestLimitExceeded||1' clean "$WORK/g11-confirm.log"
check "REJECT a clean up whose inventory after the confirm fails: nothing is deleted" 2 "$RC" "$WORK/g11-confirm.log" \
  '^ERROR: E_CLEAN_INVENTORY: could not list the resources of run r1 after the confirm; nothing was deleted$'
[[ "$(mutations)" == 0 ]]; check "  ... and no delete call was made" 0 $? "$WORK/mutations.txt"
full; FAKE_FAIL='aws|ec2 describe-vpcs||RequestLimitExceeded|1|2' clean "$WORK/g11-step1.log"
grep -q '^CLEAN FAILED: could not list the resources after step 1; no further delete' "$WORK/g11-step1.log" \
  && [[ "$(count_calls aws 'ec2 terminate-instances')" == 0 && "$(count_calls aws 'ec2 delete-launch-template')" == 0 \
        && "$(count_calls aws 'ec2 deregister-image')" == 0 && "$(count_calls eksctl 'delete cluster')" == 0 ]] \
  && grep -Eq ' verdict=incomplete$' "$V/verdict.txt"
check "REJECT an inventory that fails after step 1: no further delete, the read-back runs, verdict incomplete" 0 $? "$WORK/g11-step1.log"
[[ "$RC" == 1 ]]; check "  ... and it exits 1" 0 $? "$WORK/g11-step1.log"
full; FAKE_FAIL='eksctl|delete nodegroup|sandbox|Timeout' clean "$WORK/g11-ng.log"
grep -q 'eksctl delete nodegroup sandbox did not finish, so the cluster is kept' "$WORK/g11-ng.log" && [[ "$(count_calls eksctl 'delete cluster')" == 0 ]] \
  && alive '"cb-offline-test" in s["eks"]["clusters"]'
check "REJECT a node group delete that does not finish: the cluster is kept, no eksctl delete cluster" 0 $? "$WORK/g11-ng.log"
[[ "$RC" == 1 ]] && alive '"cb-offline-test-cilium-operator" in s["iam"]["roles"]'
check "  ... it exits 1, and the operator role stays with the kept cluster" 0 $? "$WORK/g11-ng.log"
# With no cluster, every eksctl stack of the run goes, the cluster stack last.
full no-cluster
world_py 's["cloudformation"]["stacks"]["eksctl-cb-offline-test-nodegroup-system"] = {"StackStatus": "CREATE_COMPLETE", "Tags": [{"Key": "ManagedBy", "Value": "cilium-bottlerocket-sample"}, {"Key": "RunId", "Value": "r1"}, {"Key": "alpha.eksctl.io/cluster-name", "Value": "cb-offline-test"}]}'
clean "$WORK/g12.log"
check "ACCEPT the clean up of a run with no cluster and two eksctl stacks" 0 "$RC" "$WORK/g12.log"
ng="$(first_seq aws 'cloudformation delete-stack' 'eksctl-cb-offline-test-nodegroup-system')"
cl="$(first_seq aws 'cloudformation delete-stack' 'eksctl-cb-offline-test-cluster')"
[[ -n "$ng" && -n "$cl" && "$ng" -lt "$cl" ]] && alive 'all(st["StackStatus"] == "DELETE_COMPLETE" for st in s["cloudformation"]["stacks"].values())'
check "  ... the node group stack is deleted before the cluster stack, and both are gone" 0 $? "$WORK/g12.log"
full no-cluster
world_py 's["cloudformation"]["stacks"]["eksctl-cb-offline-test-nodegroup-system"] = {"StackStatus": "CREATE_COMPLETE", "Tags": [{"Key": "team", "Value": "someone-else"}, {"Key": "alpha.eksctl.io/cluster-name", "Value": "cb-offline-test"}]}'
clean "$WORK/g12-foreign.log"
alive 's["cloudformation"]["stacks"]["eksctl-cb-offline-test-nodegroup-system"]["StackStatus"] == "CREATE_COMPLETE"' \
  && [[ -z "$(first_seq aws 'cloudformation delete-stack' 'eksctl-cb-offline-test-nodegroup-system')" ]]
check "ACCEPT and keep a same-cluster stack that is not the run's: it is not deleted" 0 $? "$WORK/g12-foreign.log"
# The IDs the state file names are deleted (after their tags are read again) even when the
# tag-filtered discovery misses them; a state-named ID left without the run's tags is reported.
full; world_py 't = [x for x in s["ec2"]["launch_templates"] if x["LaunchTemplateId"] == "lt-0fa00000000000002"][0]
t["RecheckTags"] = t["Tags"]; t["Tags"] = []'
clean "$WORK/g13-ok.log"
check "ACCEPT a state-named launch template that the tag discovery misses: read again by ID, then deleted" 0 "$RC" "$WORK/g13-ok.log" '^deleted launch-template lt-0fa00000000000002$'
# (detached and available, so the termination of the builder does not take it with it)
full killed-build; world_py 'v = [x for x in s["ec2"]["volumes"] if x["VolumeId"] == "vol-0fb00000000000002"][0]
v["Tags"] = []; v["State"] = "available"; v.pop("Attachment", None); v["Attachments"] = []'
clean "$WORK/g13-bad.log"
check "REJECT a state-named builder volume with no tags: skipped, and reported left over without the run's tags" 1 "$RC" "$WORK/g13-bad.log" \
  '^CLEAN FAILED: left over without the tags of run r1 \(BUILDER_VOLUME_IDS\): volume vol-0fb00000000000002'
alive 'any(v["VolumeId"] == "vol-0fb00000000000002" for v in s["ec2"]["volumes"])'
check "  ... and the untagged volume is not deleted" 0 $? "$WORK/g13-bad.log"
# The tool versions of setup.sh, before any AWS call.
full; : > "$FAKE_LOG"; FAKE_EKSCTL_VERSION=0.229.9 clean "$WORK/g24.log" --dry-run
check "REJECT clean.sh with eksctl 0.229.9 (older than setup.sh needs), before any AWS call" 1 "$RC" "$WORK/g24.log" '^ERROR: E_TOOL_EKSCTL: eksctl 0\.229\.9 is too old'
[[ "$(count_calls aws)" == 0 ]]; check "  ... and no AWS call was made" 0 $? "$WORK/g24.log"

echo "== a builder instance that EC2 no longer lists ========================================"
# After a finished build the state names the builder, which EC2 stops listing some time after it
# terminated: a read by its ID answers {"Reservations": []}. Its other parts are gone.
B=i-0fb00000000000001
AGED='b = [x for x in s["ec2"]["instances"] if x["InstanceId"] == "i-0fb00000000000001"][0]; b["State"] = {"Name": "terminated"}; b["AgedOut"] = True
s["ec2"]["volumes"] = [v for v in s["ec2"]["volumes"] if not v["VolumeId"].startswith("vol-0fb")]
s["ec2"]["network_interfaces"] = [x for x in s["ec2"]["network_interfaces"] if (x.get("Attachment") or {}).get("InstanceId") != "i-0fb00000000000001"]
s["ec2"]["security_groups"] = [g for g in s["ec2"]["security_groups"] if g["GroupId"] != "sg-0fc00000000000001"]
s["iam"]["profiles"].pop("cb-offline-test-r1-builder", None); s["iam"]["roles"].pop("cb-offline-test-r1-builder", None)'
full killed-build; world_py "$AGED"
clean "$WORK/s4-aged.log"
check "ACCEPT a builder instance that EC2 no longer lists: it reads as gone, and the cluster goes" 0 "$RC" "$WORK/s4-aged.log" '^CLEAN: run r1 .*nothing left behind\.$'
grep -qx "instance $B: already gone" "$WORK/s4-aged.log" && [[ "$(count_calls aws 'ec2 wait instance-terminated' "$B")" == 0 ]] \
  && [[ "$(count_calls eksctl 'delete cluster')" == 1 ]] && ! alive '"cb-offline-test" in s["eks"]["clusters"]' \
  && grep -q ' keep_cluster=0 failures=0 verdict=clean$' "$V/verdict.txt"
check "  ... already gone, no wait for it, eksctl delete cluster ran, verdict keep_cluster=0 clean" 0 $? "$WORK/s4-aged.log"
full killed-build; world_py "$AGED"
FAKE_FAIL="aws|ec2 describe-instances|$B|RequestLimitExceeded" clean "$WORK/s4-unread.log"
check "REJECT a builder instance that cannot be read: the cluster and its VPC are kept" 1 "$RC" "$WORK/s4-unread.log" 'the cluster and its VPC are kept, because a builder part remains'
[[ "$(count_calls eksctl 'delete cluster')" == 0 ]] && alive '"cb-offline-test" in s["eks"]["clusters"]' \
  && grep -q ' keep_cluster=1 failures=[1-9][0-9]* verdict=incomplete$' "$V/verdict.txt"
check "  ... no eksctl delete cluster, verdict keep_cluster=1 incomplete" 0 $? "$WORK/s4-unread.log"
full killed-build
clean "$WORK/s4-running.log"
check "ACCEPT a running builder: terminated, then waited for, then the cluster goes" 0 "$RC" "$WORK/s4-running.log" "^deleted instance $B\$"
[[ "$(count_calls aws 'ec2 wait instance-terminated' "$B")" == 1 ]]; check "  ... the waiter waits for the instance that this run terminated" 0 $? "$WORK/s4-running.log"

echo "== the operator role read after eksctl delete cluster ================================="
ROLE=cb-offline-test-cilium-operator
full
clean "$WORK/s4b-gone.log"
check "ACCEPT an operator role that went with its stack: NoSuchEntity is no failure" 0 "$RC" "$WORK/s4b-gone.log" '^CLEAN: run r1 .*nothing left behind\.$'
grep -q ' failures=0 verdict=clean$' "$V/verdict.txt" && [[ ! -e "$V/oprole-read.err" ]]
check "  ... verdict failures=0 clean, and no oprole-read.err" 0 $? "$V/verdict.txt"
# The get-role calls of the operator role before eksctl delete cluster pass; the next one fails.
k="$(calls aws 'iam get-role' "$ROLE" | awk -v s="$(first_seq eksctl 'delete cluster')" '$1 < s' | wc -l | tr -d ' ')"
full
FAKE_FAIL="aws|iam get-role|$ROLE|ServiceUnavailable|1|$k" clean "$WORK/s4b-unread.log"
check "REJECT an operator role read that fails with another error than NoSuchEntity" 1 "$RC" "$WORK/s4b-unread.log" "could not read role $ROLE"
grep -q 'ServiceUnavailable' "$V/oprole-read.err" && grep -q "could not read role $ROLE" "$V/failures.txt" \
  && grep -q ' failures=1 verdict=incomplete$' "$V/verdict.txt"
check "  ... oprole-read.err keeps the error text, failures.txt names the role, verdict failures=1 incomplete" 0 $? "$V/oprole-read.err"
full; world_py "s['iam']['roles']['$ROLE'].pop('Stack')"
clean "$WORK/s4b-found.log"
check "ACCEPT an operator role of the run that outlives its stack: read again, then deleted" 0 "$RC" "$WORK/s4b-found.log" "^deleted iam-role $ROLE\$"
grep -q ' failures=0 verdict=clean$' "$V/verdict.txt"; check "  ... verdict failures=0 clean" 0 $? "$V/verdict.txt"

echo "== the cluster delete that EKS refuses with 409 \"update in progress\" ==================="
# After the last node group and the Pod Identity association went, EKS can refuse DeleteCluster
# with 409 "currently has an update in progress" for minutes (#281, live). clean.sh runs eksctl
# delete cluster again only on that ControlPlane reason, at most 4 tries (no wait here:
# CB_SLEEP_SECONDS=0). Any other reason keeps the cluster at once.
CL='s["eks"]["clusters"]["cb-offline-test"]'
RETRY='^CLEAN RETRY E_CLUSTER_DELETE_BUSY: eksctl delete cluster, try '
full; world_py "$CL[\"DeleteRefusals\"] = 1"
clean "$WORK/busy-once.log"
check "ACCEPT a cluster delete that EKS refuses once with 409 update in progress: tried again, nothing left" 0 "$RC" "$WORK/busy-once.log" '^CLEAN: run r1 .*nothing left behind\.$'
cover accept E_CLUSTER_DELETE_BUSY
[[ "$(count_calls eksctl 'delete cluster')" == 2 && "$(grep -c "$RETRY" "$WORK/busy-once.log")" == 1 ]] \
  && grep -q "${RETRY}2 of 4 in 0 s; EKS answered: Cannot delete because cluster cb-offline-test currently has an update in progress (Service: Eks, Status Code: 409" "$WORK/busy-once.log" \
  && ! alive '"cb-offline-test" in s["eks"]["clusters"]' && grep -q ' failures=0 verdict=clean$' "$V/verdict.txt" \
  && grep -q '"ControlPlane"' "$V/cluster-stack-events-1.json"
check "  ... one CLEAN RETRY line (try 2 of 4) with the reason, two eksctl delete cluster calls, the stack events kept, verdict failures=0 clean" 0 $? "$WORK/busy-once.log"
full; world_py "$CL[\"DeleteRefusals\"] = 99"
clean "$WORK/busy-always.log"
check "REJECT a cluster delete that EKS refuses on every try: the named error after 4 tries" 1 "$RC" "$WORK/busy-always.log" \
  '^ERROR: E_CLUSTER_DELETE_BUSY: EKS still refused DeleteCluster with 409 "update in progress" after 4 tries in [0-9]+ s; run \./clean\.sh again later$'
[[ "$(count_calls eksctl 'delete cluster')" == 4 && "$(grep -c "$RETRY" "$WORK/busy-always.log")" == 3 ]] \
  && grep -qx 'CLEAN FAILED: eksctl delete cluster cb-offline-test' "$WORK/busy-always.log" && alive '"cb-offline-test" in s["eks"]["clusters"]' \
  && grep -q ' keep_cluster=0 failures=[1-9][0-9]* verdict=incomplete$' "$V/verdict.txt" && grep -qx 'eksctl delete cluster cb-offline-test' "$V/failures.txt"
check "  ... 4 eksctl delete cluster calls, 3 CLEAN RETRY lines, then the failure line of today; the cluster stays; verdict incomplete" 0 $? "$WORK/busy-always.log"
full; world_py "$CL[\"DeleteFailReason\"] = \"Resource handler returned message: User is not authorized to perform: eks:DeleteCluster (Service: Eks, Status Code: 403)\""
clean "$WORK/busy-other.log"
check "REJECT a cluster delete that fails for another ControlPlane reason: no retry, the cluster stays" 1 "$RC" "$WORK/busy-other.log" '^CLEAN FAILED: eksctl delete cluster cb-offline-test$'
[[ "$(count_calls eksctl 'delete cluster')" == 1 ]] && ! grep -q '^CLEAN RETRY' "$WORK/busy-other.log" \
  && grep -q 'not authorized to perform: eks:DeleteCluster (Service: Eks, Status Code: 403)' "$WORK/busy-other.log" \
  && alive '"cb-offline-test" in s["eks"]["clusters"]' && grep -q ' verdict=incomplete$' "$V/verdict.txt"
check "  ... one eksctl delete cluster call, no CLEAN RETRY line, the reason under the failure line, verdict incomplete" 0 $? "$WORK/busy-other.log"
full; world_py 'v = s["eks"]["clusters"]["cb-offline-test"]["resourcesVpcConfig"]["vpcId"]
s["ec2"]["network_interfaces"].append({"NetworkInterfaceId": "eni-0fd00000000000777", "VpcId": v, "Status": "in-use", "TagSet": []})'
clean "$WORK/busy-vpc.log"
check "REJECT a cluster stack delete that fails on the VPC (DELETE_FAILED, not the 409): no retry" 1 "$RC" "$WORK/busy-vpc.log" '^CLEAN FAILED: eksctl delete cluster cb-offline-test$'
[[ "$(count_calls eksctl 'delete cluster')" == 1 ]] && ! grep -q '^CLEAN RETRY' "$WORK/busy-vpc.log" && alive '"cb-offline-test" in s["eks"]["clusters"]'
check "  ... one eksctl delete cluster call, no CLEAN RETRY line, the cluster stays" 0 $? "$WORK/busy-vpc.log"
full; world_py "$CL[\"DeleteRefusals\"] = 1"
FAKE_FAIL='aws|cloudformation describe-stack-events||Throttling' clean "$WORK/busy-unread.log"
check "REJECT a refused cluster delete whose stack events cannot be read: no retry" 1 "$RC" "$WORK/busy-unread.log" '^CLEAN FAILED: eksctl delete cluster cb-offline-test$'
[[ "$(count_calls eksctl 'delete cluster')" == 1 ]] && ! grep -q '^CLEAN RETRY' "$WORK/busy-unread.log" \
  && grep -q 'could not read the events of stack eksctl-cb-offline-test-cluster: .*Throttling' "$WORK/busy-unread.log"
check "  ... one eksctl delete cluster call, no CLEAN RETRY line, the read error under the failure line" 0 $? "$WORK/busy-unread.log"
full; world_py "$CL[\"DeleteRefusals\"] = 1"
FAKE_FAIL='eksctl|delete cluster||Timeout||1' clean "$WORK/busy-stale.log"
check "REJECT a retry that fails before a new stack delete (no new ControlPlane event): no further retry" 1 "$RC" "$WORK/busy-stale.log" '^CLEAN FAILED: eksctl delete cluster cb-offline-test$'
[[ "$(count_calls eksctl 'delete cluster')" == 2 && "$(grep -c "$RETRY" "$WORK/busy-stale.log")" == 1 ]] && alive '"cb-offline-test" in s["eks"]["clusters"]'
check "  ... two eksctl delete cluster calls and one CLEAN RETRY line: the old refusal is not retried again" 0 $? "$WORK/busy-stale.log"
finish
