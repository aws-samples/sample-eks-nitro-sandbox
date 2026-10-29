#!/usr/bin/env bash
# test-setup-flow.sh: proves the bounded waits and the two-stage setup both ways, in the REAL
# code, with a fake `aws` (scripts/testlib/fake_aws.py) and a stub `kubectl` first on PATH. No
# AWS account and no cluster are reached.
#
#   scripts/test-setup-flow.sh
#
#   1  scripts/lib/aws-wait.sh ssm_run (C-1): an SSM command InProgress for several reads, then
#      Success, is accepted without the 100 s command-executed waiter (which the fake caps the
#      way the real one is capped: exit 255 after 20 attempts); Failed, TimedOut, still
#      InProgress past the deadline, and repeated read errors are refused.
#   2  wait_image_available (C-2): pending, then available; failed, error, the deadline, and
#      repeated read errors are refused with the AMI id named. wait_status_ok: the 600 s waiter
#      retried, then refused after STATUS_OK_ROUNDS.
#   3  wait_rebooted (C-3): a new boot id with the wanted kernel is accepted; the same boot id
#      until the deadline and a new boot on the wrong kernel are refused.
#   4  setup.sh --ami-only (C-4), the whole AMI half for real: completes on a cluster with no
#      vpc-cni, with no KUBE_CONTEXT, and never calls EKS or kubectl; a failed kernel stage stops
#      it before any AMI exists.
#   5  RUN_ID=<id> setup.sh --join (C-4): refuses, before any change, an AMI without
#      BtfValidated=true, an AMI of another run, a cluster without vpc-cni, a run with no AMI
#      recorded, and no RUN_ID; accepts the run's own verified AMI; the default path still
#      stops on the missing vpc-cni before any AWS change.
#
# The fake keeps a JSON state file per case and logs every call. Poll intervals are 0 here.
# The account id is the AWS documentation's example id.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE="$(cd "$HERE/.." && pwd)"
REPO_ROOT_REAL="$(cd "$SAMPLE/../../.." && pwd)"
mkdir -p "$REPO_ROOT_REAL/tmp"
WORK="$(mktemp -d "$REPO_ROOT_REAL/tmp/test-setup-flow.XXXXXX")"
trap '[ -n "${KEEP_WORK:-}" ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT
export ISSUE10_RUN_DIR="$WORK/run" AWS_REGION=us-west-2 CLUSTER_NAME=example-cluster RESOURCE_PREFIX=ubuntu-ami-sample \
       NAMESPACE=ubuntu-ami-sample SSM_POLL_SECONDS=0 AMI_POLL_SECONDS=0 REBOOT_POLL_SECONDS=0 AWS_READ_RETRIES=3
unset RUN_ID KUBECTL NODEGROUP_NAME KUBE_CONTEXT

pass=0; fail=0
check() { # check <description> <expected-rc> <actual-rc> <log> [<regex the log must match>]
  local ok=0
  [[ "$3" -eq "$2" ]] || ok=1
  if [[ $ok -eq 0 && -n "${5:-}" ]]; then grep -qE -- "$5" "$4" || ok=1; fi
  if [[ $ok -eq 0 ]]; then printf '  PASS  %s (rc=%s)\n' "$1" "$3"; pass=$((pass+1))
  else printf '  FAIL  %s (expected rc=%s%s, got rc=%s)\n' "$1" "$2" "${5:+ and /$5/}" "$3"; sed 's/^/        | /' "$4" | tail -n 12; fail=$((fail+1)); fi
}
ok() { # ok <description> <rc-of-an-assertion> [<file to show on failure>]
  if [[ "$2" -eq 0 ]]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$1"; [ -n "${3:-}" ] && sed 's/^/        | /' "$3" | tail -n 12; fail=$((fail+1)); fi
}

STUB="$WORK/bin"; mkdir -p "$STUB"
printf '#!/bin/bash\nexec python3 "%s" "$@"\n' "$HERE/testlib/fake_aws.py" > "$STUB/aws"
# Stub kubectl: logs every call; must name the test's context; answers what 00c, the waits,
# ensure-namespace.sh and the apply make.
cat > "$STUB/kubectl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_KUBECTL_LOG"
[ "${1:-}" = --context ] && [ "${2:-}" = example-context ] || { echo "STUB kubectl: call without --context example-context: $*" >&2; exit 97; }
shift 2
case "$*" in
  "config view --minify -o jsonpath={.clusters[0].cluster.server}") printf '%s' 'https://EXAMPLE0123.gr7.us-west-2.eks.amazonaws.com' ;;
  "get runtimeclass isolated-sandbox -o json") echo '{"handler":"isolated-sandbox","scheduling":{"nodeSelector":{"eks.amazonaws.com/nitro-sandbox":"true"}}}' ;;
  "get pods -n kube-system -l k8s-app=kube-dns -o json") echo '{"items": [{"metadata": {"name": "coredns-a"}}]}' ;;
  "get nodes -l eks.amazonaws.com/nodegroup="*" -o jsonpath={.items[0].metadata.name}") printf 'node-a' ;;
  "get node node-a -o jsonpath={.status.conditions[?(@.type==\"Ready\")].status}") printf 'True' ;;
  "get node node-a -o jsonpath={.status.allocatable.eks\\.amazonaws\\.com/nitro-sandbox}") printf '20' ;;
  "get namespace "*" -o json") echo 'Error from server (NotFound): namespaces "x" not found' >&2; exit 1 ;;
  "create -f "*) echo "namespace/created" ;;
  "apply -n "*) echo "applied" ;;
  *) echo "STUB kubectl: unexpected call: $*" >&2; exit 97 ;;
esac
SH
chmod +x "$STUB/aws" "$STUB/kubectl"
export PATH="$STUB:$PATH" STUB_KUBECTL_LOG="$WORK/kubectl.log"

# st <case> [<python statements over s, the state>]: this case's state and call log
st() {
  export FAKE_AWS_STATE="$WORK/$1.state.json" FAKE_AWS_LOG="$WORK/$1.calls.jsonl"
  : > "$FAKE_AWS_LOG"; : > "$STUB_KUBECTL_LOG"; unset FAKE_AWS_FAIL
  python3 - "$FAKE_AWS_STATE" "${2:-}" <<'PY'
import json, sys
s = {"account": "111122223333",
     "ec2": {"instances": [{"InstanceId": "i-0build", "State": {"Name": "running"}, "Tags": [],
                            "BootId": "00000000-0000-4000-8000-b00000000001", "Kernel": "stock-kernel"}],
             "images": [{"ImageId": "ami-0ba5e", "Name": "ubuntu-eks/k8s_1.36/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-20261027",
                         "CreationDate": "2026-10-27T00:00:00.000Z", "OwnerId": "444455556666", "State": "available", "Tags": []}],
             "subnets": [{"SubnetId": "subnet-0example1", "VpcId": "vpc-0example"}]},
     "eks": {"clusters": {"example-cluster": {"endpoint": "https://EXAMPLE0123.gr7.us-west-2.eks.amazonaws.com",
                                              "certificateAuthority": {"data": "Q0EtREFUQS1GSVhUVVJF"},
                                              "kubernetesNetworkConfig": {"serviceIpv4Cidr": "10.100.0.0/16"}}}},
     "ssm": {"results": [{"match": "slow", "Status": "Success", "stdout": "done", "progress": 25},
                         {"match": "fails", "Status": "Failed", "stdout": "", "stderr": "boom"},
                         {"match": "times-out", "Status": "TimedOut"},
                         {"match": "never-ends", "Status": "Success", "progress": 100000},
                         {"match": "random/boot_id", "Status": "Success", "stdout": "@bootinfo"}]}}
exec(sys.argv[2], {"s": s})
json.dump(s, open(sys.argv[1], "w"))
PY
}
calls() { python3 -c 'import json,re,sys; print(sum(1 for l in open(sys.argv[1]) if re.search(sys.argv[2], json.loads(l)["call"])))' "$WORK/$1.calls.jsonl" "$2"; }
MUTATING='create-|attach-|put-|tag-|add-|delete-|detach-|remove-|terminate-|deregister-|run-instances|reboot-|send-command'
# lib <case> <bash code>: run <code> with the real common.sh and aws-wait.sh sourced
lib() { bash -c '. "$1/lib/common.sh" && . "$1/lib/aws-wait.sh" && eval "$2"' _ "$HERE" "$2" > "$WORK/$1.log" 2>&1 < /dev/null; }

echo "== 1/5 SSM command results: scripts/lib/aws-wait.sh ssm_run (C-1) ========================"
P='$(ssm_shell_params "WHAT" 60)'
st s-slow
rc=0; lib s-slow "ssm_run i-0build 60 AWS-RunShellScript \"${P/WHAT/slow}\"; r=\$?; echo \"rc=\$r status=\$SSM_STATUS out=\$SSM_STDOUT\"; exit \$r" || rc=$?
check "ACCEPT a command InProgress for 25 reads (longer than the waiter's 20 attempts), then Success" 0 "$rc" "$WORK/s-slow.log" 'status=Success out=done'
[ "$(calls s-slow '^ssm get-command-invocation$')" = 26 ] && [ "$(calls s-slow '^ssm wait')" = 0 ]
ok "  ... after 26 invocation reads, and without the command-executed waiter" $?
cid=$(python3 -c 'import json,sys; print(list(json.load(open(sys.argv[1]))["ssm"]["commands"])[0])' "$FAKE_AWS_STATE")
st s-waiter; python3 - "$WORK/s-slow.state.json" "$FAKE_AWS_STATE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
for c in s["ssm"]["commands"].values():
    c["reads"] = 0                       # the same slow command, seen afresh
json.dump(s, open(sys.argv[2], "w"))
PY
rc=0; aws ssm wait command-executed --command-id "$cid" --instance-id i-0build > "$WORK/s-waiter.log" 2>&1 || rc=$?
check "REJECT (the R1-F2 form) the same command through 'aws ssm wait command-executed': the waiter's cap, exit 255" 255 "$rc" "$WORK/s-waiter.log" 'Max attempts exceeded'
while IFS='@' read -r name what env want rx why; do
  [ -n "$name" ] || continue
  st "$name"
  rc=0; lib "$name" "$env ssm_run i-0build 1 AWS-RunShellScript \"${P/WHAT/$what}\" 1; r=\$?; echo \"rc=\$r status=\$SSM_STATUS\"; exit \$r" || rc=$?
  check "$why" "$want" "$rc" "$WORK/$name.log" "$rx"
done <<'CASES'
s-failed@fails@@1@status=Failed@REJECT a command that ends Failed (rc 1)
s-timedout@times-out@@1@status=TimedOut@REJECT a command that ends TimedOut (rc 1)
s-stuck@never-ends@@2@could not determine SSM command .*still InProgress after 2 s@REJECT a command still InProgress past its deadline (timeout 1 s + margin 1 s): could not determine (rc 2)
CASES
st s-readerr; export FAKE_AWS_FAIL='ssm get-command-invocation||ThrottlingException'
rc=0; lib s-readerr "ssm_run i-0build 60 AWS-RunShellScript \"${P/WHAT/slow}\"; r=\$?; echo \"rc=\$r\"; exit \$r" || rc=$?
check "REJECT reads that keep failing: could not determine after AWS_READ_RETRIES=3 retries (rc 2)" 2 "$rc" "$WORK/s-readerr.log" '4 reads in a row failed .*ThrottlingException'
st s-transient; export FAKE_AWS_FAIL='ssm get-command-invocation||ThrottlingException|2'
rc=0; lib s-transient "ssm_run i-0build 60 AWS-RunShellScript \"${P/WHAT/slow}\"; r=\$?; echo \"rc=\$r status=\$SSM_STATUS\"; exit \$r" || rc=$?
check "ACCEPT two failed reads in a row, then the command's reads (a transient error is retried)" 0 "$rc" "$WORK/s-transient.log" 'status=Success'
st s-send; export FAKE_AWS_FAIL='ssm send-command||InvalidInstanceId'
rc=0; lib s-send "ssm_run i-0build 60 AWS-RunShellScript \"${P/WHAT/slow}\"; r=\$?; echo \"rc=\$r status=\$SSM_STATUS\"; exit \$r" || rc=$?
check "REJECT a send-command that fails: could not determine (rc 2)" 2 "$rc" "$WORK/s-send.log" 'status=send-command failed'
unset FAKE_AWS_FAIL

echo
echo "== 2/5 the AMI and instance status: wait_image_available, wait_status_ok (C-2) ============"
img() { # img <pending-reads> <final>: one image create-image would have made
  printf 's["ec2"]["images"].append({"ImageId": "ami-0new", "State": "pending", "Reads": 0, "PendingReads": %s, "Final": "%s", "Tags": []})' "$1" "$2"
}
st i-ok "$(img 3 available)"
rc=0; lib i-ok 'wait_image_available ami-0new' || rc=$?
check "ACCEPT an AMI pending for 3 reads, then available" 0 "$rc" "$WORK/i-ok.log"
[ "$(calls i-ok '^ec2 describe-images$')" = 4 ] && [ "$(calls i-ok '^ec2 wait')" = 0 ]; ok "  ... after 4 reads, and without the image-available waiter" $?
while IFS='@' read -r name pending final env want rx why; do
  [ -n "$name" ] || continue
  st "$name" "$(img "$pending" "$final")"
  rc=0; lib "$name" "$env wait_image_available ami-0new" || rc=$?
  check "$why" "$want" "$rc" "$WORK/$name.log" "$rx"
done <<'CASES'
i-failed@1@failed@@1@AMI ami-0new is failed@REJECT an AMI that ends failed, naming it
i-error@0@error@@1@AMI ami-0new is error@REJECT an AMI that ends error, naming it
i-deadline@100000@available@AMI_WAIT_SECONDS=1@2@could not determine AMI ami-0new becoming available: still pending after 1 s@REJECT an AMI still pending at AMI_WAIT_SECONDS, naming it
CASES
st i-readerr "$(img 0 available)"; export FAKE_AWS_FAIL='ec2 describe-images||RequestLimitExceeded'
rc=0; lib i-readerr 'wait_image_available ami-0new' || rc=$?
check "REJECT AMI reads that keep failing: could not determine" 2 "$rc" "$WORK/i-readerr.log" 'could not determine AMI ami-0new becoming available: 4 reads in a row failed'
st w-ok; export FAKE_AWS_FAIL='ec2 wait instance-status-ok||WaiterMaxAttempts|2'
rc=0; lib w-ok 'STATUS_OK_ROUNDS=3 wait_status_ok i-0build' || rc=$?
check "ACCEPT instance-status-ok on the third waiter round (two rounds hit the 600 s cap)" 0 "$rc" "$WORK/w-ok.log" 'waiter round 2 of 3'
st w-never; export FAKE_AWS_FAIL='ec2 wait instance-status-ok||WaiterMaxAttempts'
rc=0; lib w-never 'STATUS_OK_ROUNDS=3 wait_status_ok i-0build' || rc=$?
check "REJECT an instance never status-ok in STATUS_OK_ROUNDS=3 rounds" 1 "$rc" "$WORK/w-never.log" 'did not reach status-ok in 3 waiter rounds'
[ "$(calls w-never '^ec2 wait instance-status-ok$')" = 3 ]; ok "  ... after exactly 3 waiter runs" $?
unset FAKE_AWS_FAIL

echo
echo "== 3/5 the reboot onto the new kernel: read_boot_info, wait_rebooted (C-3) =================="
rb() { # rb <case> <state python>: read the boot id, reboot, wait for the new kernel
  st "$1" "$2"
  lib "$1" 'read_boot_info i-0build 60 || exit 9; b=$BOOT_ID; echo "before=$b"
    aws ec2 reboot-instances --region us-west-2 --instance-ids i-0build >/dev/null || exit 8
    wait_rebooted i-0build "$b" 6.18.56-nitro-ga; r=$?; echo "rc=$r after=$BOOT_ID kernel=$BOOT_KERNEL"; exit $r'
}
rc=0; rb r-ok '' || rc=$?
check "ACCEPT a new boot id and kernel 6.18.56-nitro-ga after the reboot" 0 "$rc" "$WORK/r-ok.log" 'after=00000000-0000-4000-9000-c00000000001 kernel=6.18.56-nitro-ga'
grep -q 'before=00000000-0000-4000-8000-b00000000001' "$WORK/r-ok.log"; ok "  ... and the boot id read before the reboot was the old one" $?
rc=0; st r-same 's["boot"] = {"no_reboot": True}'
lib r-same 'REBOOT_WAIT_SECONDS=1; read_boot_info i-0build 60 || exit 9; b=$BOOT_ID
  aws ec2 reboot-instances --region us-west-2 --instance-ids i-0build >/dev/null || exit 8
  wait_rebooted i-0build "$b" 6.18.56-nitro-ga' || rc=$?
check "REJECT the same boot id until the deadline (a stale answer from before the reboot)" 2 "$rc" "$WORK/r-same.log" 'still boot 00000000-0000-4000-8000-b00000000001 \(not rebooted yet\) after 1 s'
rc=0; rb r-wrong 's["boot"] = {"after_reboot": "6.8.0-1021-aws"}' || rc=$?
check "REJECT a new boot on the wrong kernel (GRUB booted the stock one)" 1 "$rc" "$WORK/r-wrong.log" 'onto kernel 6.8.0-1021-aws, not 6.18.56-nitro-ga'

echo
echo "== 4/5 the AMI half alone: setup.sh --ami-only (C-4, and C-1 to C-3 in the real caller) ===="
FX="$ISSUE10_RUN_DIR/runtime"; mkdir -p "$FX"
python3 "$HERE/testlib/fixture_inputs.py" "$FX" "$WORK/fixture.lock"
BUILD_RESULTS='s["ssm"]["results"] = [
  {"match": "staged-and-verified", "Status": "Success", "stdout": "staged-and-verified"},
  {"match": "sha256sum", "Status": "Success", "stdout": "downloaded"},
  {"match": "install -d -m 0700", "Status": "Success"},
  {"match": "random/boot_id", "Status": "Success", "stdout": "@bootinfo"},
  {"match": "00-preflight.sh", "Status": "Success", "stdout": "CONTAINERD_VERDICT=containerd 2.2.1 is supported by the GA shim\nPREFLIGHT OK"},
  {"match": "10-kernel.sh", "Status": "@KERNEL@", "stdout": "10-kernel.sh done", "progress": 5},
  {"match": "20-erofs-utils.sh", "Status": "Success"}, {"match": "30-runtime-install.sh", "Status": "Success"},
  {"match": "31-wire-containerd.sh", "Status": "Success"}, {"match": "35-apparmor.sh", "Status": "Success"},
  {"match": "36-hold-packages.sh", "Status": "Success"},
  {"match": "40-smoke.sh", "Status": "Success", "stdout": "smoke ok"},
  {"match": "verify-image.py", "Status": "Success", "stdout": "image_configuration: PASS\ncontainerd 2.2.1 supported by the GA shim", "progress": 2},
  {"match": "50-bake-prep.sh", "Status": "Success"}]
s["ssm"]["parameters"] = {"/aws/service/canonical/ubuntu/eks/24.04/1.36/stable/current/amd64/hvm/ebs-gp3/ami-id": "ami-0ba5e"}
s["ec2"]["instances"] = []
s["image"] = {"pending_reads": 3}'
su() { # su <case> [args]: the real setup.sh with the fixture inputs, plus SU_ENV
  local c="$1"; shift
  env LOCK_FILE="$WORK/fixture.lock" RUNTIME_ARTIFACT_FILE=fixture.zip BUILD_SUBNET_ID=subnet-0example1 \
    NODE_SUBNET_IDS=subnet-0example2 SSM_ONLINE_TRIES=2 "${SU_ENV[@]}" bash "$SAMPLE/setup.sh" "$@" > "$WORK/$c.log" 2>&1 < /dev/null
}
SU_ENV=()
st ami "${BUILD_RESULTS/@KERNEL@/Success}"
rc=0; su ami --ami-only || rc=$?
check "ACCEPT --ami-only on a cluster with no vpc-cni and no KUBE_CONTEXT: steps 1 to 9 complete" 0 "$rc" "$WORK/ami.log" '--ami-only: done\. AMI ami-0fa002 is verified and tagged BtfValidated=true'
RUNID=$(sed -n 's/.*current run is now \([a-z0-9]*\) .*/\1/p' "$WORK/ami.log" | head -n 1)
RS="$ISSUE10_RUN_DIR/out/runs/$RUNID"
[ "$(calls ami '^eks ')" = 0 ] && [ ! -s "$STUB_KUBECTL_LOG" ]
ok "  ... it never called EKS (no create-nodegroup, no describe-addon) or kubectl (no apply)" $?
grep -qx 'AMI_ID=ami-0fa002' "$RS/run-state.env"; ok "  ... and recorded AMI_ID in the run's run-state.env" $?
python3 - "$FAKE_AWS_STATE" <<'PY'; ok "  ... the AMI carries ManagedBy, RunId and BtfValidated=true; both instances are terminated" $?
import json, sys
s = json.load(open(sys.argv[1]))
img = [i for i in s["ec2"]["images"] if i["ImageId"] == "ami-0fa002"][0]
t = {x["Key"]: x["Value"] for x in img["Tags"]}
assert t["ManagedBy"] == "ubuntu-ami-sample" and t["RunId"] and t["BtfValidated"] == "true", t
assert all(i["State"]["Name"] == "terminated" for i in s["ec2"]["instances"]), s["ec2"]["instances"]
PY
python3 - "$WORK/ami.calls.jsonl" <<'PY'; ok "  ... (C-1) the kernel stage was read 6 times (5 InProgress, then Success), and no SSM command used the waiter" $?
import json, sys
c = [json.loads(l) for l in open(sys.argv[1])]
assert not any(x["call"].startswith("ssm wait") for x in c), "waiter used"
sends = [" ".join(x["argv"]) for x in c if x["call"] == "ssm send-command"]
k = [i for i, a in enumerate(sends, 1) if "10-kernel.sh" in a]
assert len(k) == 1, k
cid = f"cmd-{k[0]:03d}"          # the fake numbers commands in send order
reads = [x for x in c if x["call"] == "ssm get-command-invocation" and cid in x["argv"]]
assert len(reads) == 6, (cid, len(reads))
PY
[ "$(calls ami '^ec2 wait image-available$')" = 0 ] && [ "$(calls ami '^ec2 describe-images$')" -ge 4 ]
ok "  ... (C-2) the AMI was polled through its pending reads, without the image-available waiter" $?
EV="$RS/evidence/run-evidence.env"
grep -q '^BUILD_HOST_BOOT_ID_BEFORE=00000000-0000-4000-8000-b00000000001$' "$EV" && grep -q '^BUILD_HOST_BOOT_ID_AFTER=00000000-0000-4000-9000-c00000000001$' "$EV" \
  && grep -q '^BUILD_HOST_KERNEL_AFTER_REBOOT=6.18.56-nitro-ga$' "$EV"
ok "  ... (C-3) the evidence records both boot ids and the new kernel" $?
python3 - "$WORK/ami.calls.jsonl" <<'PY'; ok "  ... (C-3) the boot id was read before reboot-instances, and the next stage ran only after a new one" $?
import json, sys
c = [json.loads(l) for l in open(sys.argv[1])]
sends = [(i, " ".join(x["argv"])) for i, x in enumerate(c) if x["call"] == "ssm send-command"]
reboot = next(i for i, x in enumerate(c) if x["call"] == "ec2 reboot-instances")
boot = [i for i, a in sends if "random/boot_id" in a]
pre2 = [i for i, a in sends if "00-preflight.sh" in a][1]
assert boot[0] < reboot < boot[1] < pre2, (boot, reboot, pre2)
PY
python3 - "$WORK/ami.calls.jsonl" <<'PY'; ok "  ... only the second 00-preflight.sh, after the reboot, is sent with --after-reboot (the enclave checks)" $?
import json, sys
c = [json.loads(l) for l in open(sys.argv[1])]
pre = [" ".join(x["argv"]) for x in c if x["call"] == "ssm send-command" and "00-preflight.sh" in " ".join(x["argv"])]
assert len(pre) == 2, len(pre)
assert "--after-reboot" not in pre[0] and "00-preflight.sh --after-reboot" in pre[1], pre
PY
cp "$FAKE_AWS_STATE" "$WORK/after-ami.json"; cp -a "$ISSUE10_RUN_DIR/out" "$WORK/after-ami-out"
st ami-kfail "${BUILD_RESULTS/@KERNEL@/Failed}"
rc=0; su ami-kfail --ami-only || rc=$?
check "REJECT --ami-only when the kernel stage ends Failed after polling: it stops" 1 "$rc" "$WORK/ami-kfail.log" 'SSM AWS-RunShellScript failed on i-fakerun001 \(status Failed\)'
[ "$(calls ami-kfail '^ec2 (reboot-instances|create-image)$')" = 0 ]; ok "  ... before any reboot or AMI" $?

echo
echo "== 5/5 the node-group half alone: RUN_ID=<id> setup.sh --join (C-4) ===================="
# join_state <case> <python over s>: the state --ami-only left, changed as the case says, with
# vpc-cni installed (network policy on) unless the case removes it.
join_state() {
  export FAKE_AWS_STATE="$WORK/$1.state.json" FAKE_AWS_LOG="$WORK/$1.calls.jsonl"
  : > "$FAKE_AWS_LOG"; : > "$STUB_KUBECTL_LOG"; unset FAKE_AWS_FAIL
  rm -rf "$ISSUE10_RUN_DIR/out"; cp -a "$WORK/after-ami-out" "$ISSUE10_RUN_DIR/out"
  python3 - "$WORK/after-ami.json" "$FAKE_AWS_STATE" "${2:-}" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["eks"]["addons"] = {"example-cluster/vpc-cni": {"status": "ACTIVE", "addonVersion": "v1.0.0-eksbuild.1",
                                                  "configurationValues": "{\"enableNetworkPolicy\":\"true\"}"}}
img = [i for i in s["ec2"]["images"] if i["ImageId"] == "ami-0fa002"][0]
exec(sys.argv[3], {"s": s, "img": img})
json.dump(s, open(sys.argv[2], "w"))
PY
}
nothing_changed() { [ "$(calls "$1" "$MUTATING")" = 0 ] && ! grep -q '^--context example-context \(apply\|create\)' "$STUB_KUBECTL_LOG"; }
# join_reject <case> <description> <log regex>: --join (with SU_ENV) must stop, before any change
join_reject() {
  local rc=0; su "$1" --join || rc=$?
  check "$2" 1 "$rc" "$WORK/$1.log" "$3"
  nothing_changed "$1"; ok "  ... before any change (no AWS mutation, no kubectl create or apply)" $?
}
SU_ENV=(KUBE_CONTEXT=example-context "RUN_ID=$RUNID")
join_state j-nobtf 'img["Tags"] = [t for t in img["Tags"] if t["Key"] != "BtfValidated"]'
join_reject j-nobtf "REJECT --join with an AMI that has no BtfValidated=true" 'does not carry BtfValidated=true'
join_state j-btffalse '[t.update(Value="false") for t in img["Tags"] if t["Key"] == "BtfValidated"]'
join_reject j-btffalse "REJECT --join with an AMI tagged BtfValidated=false" 'does not carry BtfValidated=true'
join_state j-foreign '[t.update(Value="otherrun1") for t in img["Tags"] if t["Key"] == "RunId"]'
join_reject j-foreign "REJECT --join with an AMI tagged for another run" "does not carry ManagedBy=ubuntu-ami-sample and RunId=$RUNID"
join_state j-nocni 'del s["eks"]["addons"]'
join_reject j-nocni "REJECT --join on a cluster with no vpc-cni" 'PREREQUISITE NOT MET: cluster example-cluster has no managed vpc-cni add-on'
join_state j-noami
sed -i '/^AMI_ID=/d' "$ISSUE10_RUN_DIR/out/runs/$RUNID/run-state.env"
join_reject j-noami "REJECT --join for a run with no AMI recorded" 'has no AMI_ID'
join_state j-readerr; export FAKE_AWS_FAIL='ec2 describe-images||AccessDenied'
join_reject j-readerr "REJECT --join when the AMI cannot be read: could not determine" "could not determine whether AMI ami-0fa002 is this run's verified AMI"
unset FAKE_AWS_FAIL
join_state j-norun; SU_ENV=(KUBE_CONTEXT=example-context)
join_reject j-norun "REJECT --join with no RUN_ID" '--join needs RUN_ID'
join_state j-ok; SU_ENV=(KUBE_CONTEXT=example-context "RUN_ID=$RUNID")
rc=0; su j-ok --join || rc=$?
check "ACCEPT --join with the run's own verified AMI: step 10 runs" 0 "$rc" "$WORK/j-ok.log" 'setup.sh complete\. AMI=ami-0fa002'
python3 - "$WORK/j-ok.calls.jsonl" <<'PY'; ok "  ... one launch template from that AMI and one node group, and nothing was rebuilt" $?
import json, sys
c = [json.loads(l) for l in open(sys.argv[1])]
lt = [x for x in c if x["call"] == "ec2 create-launch-template"]
assert len(lt) == 1 and lt[0]["launch_template_data"]["ImageId"] == "ami-0fa002", lt
assert sum(1 for x in c if x["call"] == "eks create-nodegroup") == 1
assert not any(x["call"] in ("ec2 run-instances", "ec2 create-image", "ssm send-command") for x in c)
PY
[ "$(grep -c '^--context example-context apply -n ubuntu-ami-sample -f ' "$STUB_KUBECTL_LOG")" = 3 ]; ok "  ... and applied the three validation manifests" $?
st def-nocni "${BUILD_RESULTS/@KERNEL@/Success}"; SU_ENV=(KUBE_CONTEXT=example-context)
rc=0; su def-nocni || rc=$?
check "REJECT the default path (no flag) on the same cluster with no vpc-cni" 1 "$rc" "$WORK/def-nocni.log" 'PREREQUISITE NOT MET: cluster example-cluster has no managed vpc-cni add-on'
nothing_changed def-nocni; ok "  ... before any AWS change (RR-014 order kept)" $?

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "bounded SSM, AMI, status and reboot waits and the two-stage setup proven both ways in the real code."
