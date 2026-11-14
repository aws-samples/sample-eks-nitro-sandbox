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
#   6  an explicit RUN_ID (RR2-003): setup.sh acts on a run only when its record
#      (runs/<id>/run-state.env) names the same RUN_ID, RESOURCE_PREFIX, NODEGROUP_NAME and
#      NAMESPACE, and only while it holds the run's lock (runs/<id>/run.lock). No record, any
#      mismatch, a missing line and a second concurrent holder are refused before any AWS call.
#      With REAL_RUN_STATE=<path to a real run's run-state.env>, that real record is accepted too:
#      its values are read at run time (the fake gets an image with its AMI_ID), never stored here.
#   7  the build host's SSM registration (setup.sh ssm_online): repeated read errors stop the run
#      with "could not determine", an instance never Online keeps its own message, and two failed
#      reads followed by Online are accepted.
#
# The fake keeps a JSON state file per case and logs every call. Poll intervals are 0 here.
# The account id is the AWS documentation's example id.
set -uo pipefail
# A reader's own config.env (in the sample folder or ~/ubuntu-ami/) must not change what this suite
# tests: scripts/lib/common.sh skips it while this test hook is set.
export UBUNTU_AMI_TESTS_IGNORE_CONFIG_ENV=1
export PYTHONDONTWRITEBYTECODE=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE="$(cd "$HERE/.." && pwd)"
REPO_ROOT_REAL="$(cd "$SAMPLE/../../.." && pwd)"
mkdir -p "$REPO_ROOT_REAL/tmp"
WORK="$(mktemp -d "$REPO_ROOT_REAL/tmp/test-setup-flow.XXXXXX")"
HOLDER=""   # section 6's background lock holder, killed by its pid
trap '[ -z "$HOLDER" ] || kill "$HOLDER" 2>/dev/null; [ -n "${KEEP_WORK:-}" ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT
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

echo "== 1/7 SSM command results: scripts/lib/aws-wait.sh ssm_run (C-1) ========================"
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
echo "== 2/7 the AMI and instance status: wait_image_available, wait_status_ok (C-2) ============"
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
# The AMI deadline's default (R3): the live 120 GiB AMI took 54.7 min, so 3600 s left 5 min.
st w-default
rc=0; (unset AMI_WAIT_SECONDS; lib w-default 'echo "AMI_WAIT_SECONDS=$AMI_WAIT_SECONDS"') || rc=$?
check "ACCEPT AMI_WAIT_SECONDS defaults to 7200 when config.env does not set it" 0 "$rc" "$WORK/w-default.log" '^AMI_WAIT_SECONDS=7200$'
rc=0; AMI_WAIT_SECONDS=1800 lib w-set 'echo "AMI_WAIT_SECONDS=$AMI_WAIT_SECONDS"' || rc=$?
check "REJECT the default when config.env sets AMI_WAIT_SECONDS: its value (1800) is kept" 0 "$rc" "$WORK/w-set.log" '^AMI_WAIT_SECONDS=1800$'
grep -qx 'export AMI_WAIT_SECONDS=7200' "$SAMPLE/config.env.example"; ok "  ... and config.env.example sets 7200" $?

echo
echo "== 3/7 the reboot onto the new kernel: read_boot_info, wait_rebooted (C-3) =================="
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
echo "== 4/7 the AMI half alone: setup.sh --ami-only (C-4, and C-1 to C-3 in the real caller) ===="
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
  env LOCK_FILE="$WORK/fixture.lock" BUILD_SUBNET_ID=subnet-0example1 \
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
echo "== 5/7 the node-group half alone: RUN_ID=<id> setup.sh --join (C-4) ===================="
# join_state <case> <python over s>: the state --ami-only left, changed as the case says, with
# vpc-cni installed unless the case removes it (its network policy setting is the reader's own;
# 00c does not read it).
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
# The sample ships no network policy (AGENTS.md): setup.sh applies the two validation pods and
# nothing else, and the sandbox pod it applies is booted network-isolated.
applied=$(sed -n 's#^--context example-context apply -n ubuntu-ami-sample -f .*/##p' "$STUB_KUBECTL_LOG" | paste -sd' ')
[ "$applied" = "pod-ordinary.yaml pod-isolated-sandbox.yaml" ]
ok "  ... and applied the two validation pod manifests and nothing else, no network policy (applied: ${applied:-none})" $?
python3 - "$ISSUE10_RUN_DIR/out/runs/$RUNID/rendered/pod-isolated-sandbox.yaml" <<'PY'; ok "  ... and the sandbox pod it applied carries metadata.annotations sandbox.amazonaws.com/network-isolated: \"true\"" $?
import re, sys
text = open(sys.argv[1]).read()
meta = re.search(r"^metadata:\n((?:  .*\n|\s*\n)*)", text, re.M)
ann = meta and re.search(r"^  annotations:\n((?:    .*\n)*)", meta.group(1), re.M)
assert ann and re.search(r'^    sandbox\.amazonaws\.com/network-isolated: "true"(\s+#.*)?$', ann.group(1), re.M), "no network-isolated annotation"
PY
# The page shows that annotation line as the manifest has it, in its no-network section.
python3 - "$SAMPLE/README.md" "$SAMPLE/deploy/pod-isolated-sandbox.yaml" <<'PY'; ok "  ... and the README's no-network section shows the manifest's annotation line verbatim" $?
import re, sys
readme, pod = open(sys.argv[1]).read(), open(sys.argv[2]).read()
want = [l for l in pod.splitlines() if "sandbox.amazonaws.com/network-isolated" in l and not l.lstrip().startswith("#")]
sec = readme.split("### The validation sandbox has no network", 1)[1].split("\n### ", 1)[0]
block = re.search(r"```yaml\n(.*?)```", sec, re.S).group(1)
assert len(want) == 1 and want[0] in block.splitlines(), (want, block)
PY
st def-nocni "${BUILD_RESULTS/@KERNEL@/Success}"; SU_ENV=(KUBE_CONTEXT=example-context)
rc=0; su def-nocni || rc=$?
check "REJECT the default path (no flag) on the same cluster with no vpc-cni" 1 "$rc" "$WORK/def-nocni.log" 'PREREQUISITE NOT MET: cluster example-cluster has no managed vpc-cni add-on'
nothing_changed def-nocni; ok "  ... before any AWS change (RR-014 order kept)" $?

echo
echo "== 6/7 an explicit RUN_ID: the run's record and its lock (RR2-003) ======================"
# rec_reject <case> <description> <log regex> [<mode flag, default --join>]: setup.sh (with
# SU_ENV) must stop before any AWS or kubectl call, so nothing in AWS can have changed.
rec_reject() {
  local rc=0; su "$1" "${4:---join}" || rc=$?
  check "$2" 1 "$rc" "$WORK/$1.log" "$3"
  [ "$(calls "$1" .)" = 0 ] && [ ! -s "$STUB_KUBECTL_LOG" ]
  ok "  ... before any AWS or kubectl call (no AWS mutation)" $? "$WORK/$1.log"
}
REC="$ISSUE10_RUN_DIR/out/runs/$RUNID/run-state.env"
grep -q 'setup.sh complete\. AMI=ami-0fa002' "$WORK/j-ok.log"
ok "ACCEPT the synthetic run from 4/7: its record matches, so --join (j-ok in 5/7) took its lock and ran step 10" $? "$WORK/j-ok.log"
if [ -n "${REAL_RUN_STATE:-}" ]; then
  # The real run's record, copied into the fixture run folder for its own RUN_ID; the fake gets an
  # image with that record's AMI_ID and both run tags. Both values are read here, at run time.
  REAL_ID=$(sed -n 's/^RUN_ID=//p' "$REAL_RUN_STATE" 2>/dev/null | tail -n 1)
  REAL_AMI=$(sed -n 's/^AMI_ID=//p' "$REAL_RUN_STATE" 2>/dev/null | tail -n 1)
  if [[ "$REAL_ID" =~ ^[a-z0-9]{1,20}$ && "$REAL_AMI" =~ ^ami-[0-9a-f]+$ ]]; then
    export REAL_ID REAL_AMI
    join_state j-real 'e = __import__("os").environ
s["ec2"]["images"].append({"ImageId": e["REAL_AMI"], "Name": "real-run", "State": "available",
    "Tags": [{"Key": "ManagedBy", "Value": "ubuntu-ami-sample"}, {"Key": "RunId", "Value": e["REAL_ID"]}, {"Key": "BtfValidated", "Value": "true"}]})'
    RD="$ISSUE10_RUN_DIR/out/runs/$REAL_ID"; mkdir -p "$RD"
    cp "$REAL_RUN_STATE" "$RD/run-state.env"
    sed "s/$RUNID/$REAL_ID/g" "$ISSUE10_RUN_DIR/out/runs/$RUNID/iam.env" > "$RD/iam.env"   # synthetic: the fake's account
    SU_ENV=(KUBE_CONTEXT=example-context "RUN_ID=$REAL_ID")
    if grep -q '^CLUSTER_NAME=' "$RD/run-state.env"; then
      ok "  (the REAL record already names its cluster)" 0
    else
      # A record from before the cluster and Region were recorded is refused, before any call;
      # with the two lines added (for the fixture's cluster), the rest of the real record passes.
      rc=0; su j-real-old --join || rc=$?
      check "REJECT the REAL record as it was written before F1: it has no CLUSTER_NAME line" 1 "$rc" "$WORK/j-real-old.log" \
        'has no CLUSTER_NAME line, but this run has CLUSTER_NAME=example-cluster'
      printf 'CLUSTER_NAME=example-cluster\nAWS_REGION=us-west-2\n' >> "$RD/run-state.env"
    fi
    rc=0; su j-real --join || rc=$?
    grep -q -- "--join: run $REAL_ID, AMI " "$WORK/j-real.log" && grep -q 'Step 10/10: join' "$WORK/j-real.log"
    ok "ACCEPT the REAL recorded run ($REAL_RUN_STATE, with the fixture's cluster and Region): --join passes its record and lock checks and reaches step 10 (rc=$rc)" $? "$WORK/j-real.log"
  else
    ok "ACCEPT the REAL recorded run: REAL_RUN_STATE ($REAL_RUN_STATE) has a RUN_ID and an AMI_ID line" 1
  fi
else
  echo "  SKIP  ACCEPT the REAL recorded run (set REAL_RUN_STATE=<path to its run-state.env> to run it)"
fi
join_state j-norec; SU_ENV=(KUBE_CONTEXT=example-context RUN_ID=norecord1)
rec_reject j-norec "REJECT --join for a RUN_ID with no record" 'run norecord1 has no record at .*/runs/norecord1/run-state.env'
join_state a-norec; SU_ENV=(RUN_ID=norecord1)
rec_reject a-norec "REJECT an --ami-only resume for a RUN_ID with no record (every mode checks it)" 'run norecord1 has no record at ' --ami-only
! grep -q 'Step 1/10' "$WORK/a-norec.log"; ok "  ... before step 1" $?
join_state j-prefix; SU_ENV=(KUBE_CONTEXT=example-context "RUN_ID=$RUNID" RESOURCE_PREFIX=other-prefix)
rec_reject j-prefix "REJECT --join with RESOURCE_PREFIX changed since the run started" 'has RESOURCE_PREFIX=ubuntu-ami-sample, but this run has RESOURCE_PREFIX=other-prefix'
join_state j-ns; SU_ENV=(KUBE_CONTEXT=example-context "RUN_ID=$RUNID" NAMESPACE=other-ns)
rec_reject j-ns "REJECT --join with NAMESPACE changed since the run started" 'has NAMESPACE=ubuntu-ami-sample, but this run has NAMESPACE=other-ns'
SU_ENV=(KUBE_CONTEXT=example-context "RUN_ID=$RUNID")
join_state j-ng; sed -i 's/^NODEGROUP_NAME=.*/NODEGROUP_NAME=ubuntu-ami-sample-otherrun1-ng/' "$REC"
rec_reject j-ng "REJECT --join when the record names another node group" "has NODEGROUP_NAME=ubuntu-ami-sample-otherrun1-ng, but this run has NODEGROUP_NAME=ubuntu-ami-sample-$RUNID-ng"
join_state j-nons; sed -i '/^NAMESPACE=/d' "$REC"
rec_reject j-nons "REJECT --join when the record has no NAMESPACE line (a missing line is a mismatch)" 'has no NAMESPACE line, but this run has NAMESPACE=ubuntu-ami-sample'
join_state j-otherid; sed -i 's/^RUN_ID=.*/RUN_ID=otherrun1/' "$REC"
rec_reject j-otherid "REJECT --join when the record in the run's folder names another RUN_ID" "has RUN_ID=otherrun1, but this run has RUN_ID=$RUNID"
# The late R3 finding: the record names the run's cluster and Region. other-cluster here has the
# same API endpoint as the test's kube context and its own vpc-cni, so without the record check
# --join would pass every other check and create the node group in other-cluster.
join_state j-othercluster 's["eks"]["clusters"]["other-cluster"] = dict(s["eks"]["clusters"]["example-cluster"])
s["eks"]["addons"]["other-cluster/vpc-cni"] = dict(s["eks"]["addons"]["example-cluster/vpc-cni"])'
SU_ENV=(KUBE_CONTEXT=example-context "RUN_ID=$RUNID" CLUSTER_NAME=other-cluster)
rec_reject j-othercluster "REJECT --join with CLUSTER_NAME other-cluster, whose endpoint the kube context matches, for a run recorded on example-cluster" \
  'has CLUSTER_NAME=example-cluster, but this run has CLUSTER_NAME=other-cluster'
[ "$(calls j-othercluster '^eks create-nodegroup$')" = 0 ]; ok "  ... and no eks create-nodegroup in other-cluster" $?
join_state j-otherregion; SU_ENV=(KUBE_CONTEXT=example-context "RUN_ID=$RUNID" AWS_REGION=us-east-1)
rec_reject j-otherregion "REJECT --join with AWS_REGION other than the run's record" 'has AWS_REGION=us-west-2, but this run has AWS_REGION=us-east-1'
SU_ENV=(KUBE_CONTEXT=example-context "RUN_ID=$RUNID")
grep -qx 'CLUSTER_NAME=example-cluster' "$REC" && grep -qx 'AWS_REGION=us-west-2' "$REC"
ok "  ... the record setup.sh wrote names the run's cluster and Region" $? "$REC"
# A second holder: a background process takes the run's lock with the real lock_run and then
# sleeps; the test kills it by its own pid.
join_state j-locked; rm -f "$WORK/holder.ready"
RUN_ID="$RUNID" bash -c '. "$1/lib/common.sh" && derive_run_names && lock_run && echo held > "$2" && exec sleep 300' \
  _ "$HERE" "$WORK/holder.ready" > "$WORK/holder.log" 2>&1 < /dev/null &
HOLDER=$!
for _ in $(seq 1 100); do [ -s "$WORK/holder.ready" ] && break; sleep 0.1; done
[ -s "$WORK/holder.ready" ] && kill -0 "$HOLDER" 2>/dev/null
ok "a background process (pid $HOLDER) holds run $RUNID's lock, taken with the real lock_run" $? "$WORK/holder.log"
rec_reject j-locked "REJECT a second --join for the same run while another process holds its lock" "run $RUNID is in use: another process holds its lock .*/runs/$RUNID/run.lock"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""
# The same run folder and lock file (not a fresh copy): the lock is free once its holder is gone.
export FAKE_AWS_LOG="$WORK/j-unlocked.calls.jsonl"; : > "$FAKE_AWS_LOG"; : > "$STUB_KUBECTL_LOG"
rc=0; su j-unlocked --join || rc=$?
grep -q 'Step 10/10: join' "$WORK/j-unlocked.log" && ! grep -q 'is in use' "$WORK/j-unlocked.log"
ok "ACCEPT the same --join once the holder has been killed: the lock is free again and step 10 runs (rc=$rc)" $? "$WORK/j-unlocked.log"

echo
echo "== 7/7 the build host's SSM registration: setup.sh ssm_online ============================"
st o-err "${BUILD_RESULTS/@KERNEL@/Success}"; export FAKE_AWS_FAIL='ssm describe-instance-information||ThrottlingException'
SU_ENV=(SSM_ONLINE_TRIES=10 SSM_ONLINE_SLEEP=0)
rc=0; su o-err --ami-only || rc=$?
check "REJECT --ami-only when every describe-instance-information read fails: could not determine, after AWS_READ_RETRIES=3 retries" 1 "$rc" "$WORK/o-err.log" \
  'FATAL: could not determine whether build host i-fakerun001 is Online to SSM: 4 reads in a row failed \(last: An error occurred \(ThrottlingException\)'
[ "$(calls o-err '^ssm describe-instance-information$')" = 4 ] && [ "$(calls o-err '^(ssm send-command|ec2 create-image)$')" = 0 ]
ok "  ... after exactly 4 reads, and before any SSM command or AMI" $?
st o-never "${BUILD_RESULTS/@KERNEL@/Success}"$'\n''s["ssm"]["online"] = False'
SU_ENV=(SSM_ONLINE_TRIES=3 SSM_ONLINE_SLEEP=0)
rc=0; su o-never --ami-only || rc=$?
check "REJECT --ami-only when the build host is never Online in SSM_ONLINE_TRIES=3 reads (the message is today's)" 1 "$rc" "$WORK/o-never.log" \
  'FATAL: build host i-fakerun001 never reported Online to SSM'
[ "$(calls o-never '^ssm describe-instance-information$')" = 3 ] && ! grep -q 'could not determine whether' "$WORK/o-never.log"
ok "  ... after exactly 3 reads, and not reported as a read failure" $?
st o-lasterr "${BUILD_RESULTS/@KERNEL@/Success}"; export FAKE_AWS_FAIL='ssm describe-instance-information||ThrottlingException'
SU_ENV=(SSM_ONLINE_TRIES=2 SSM_ONLINE_SLEEP=0)
rc=0; su o-lasterr --ami-only || rc=$?
check "REJECT --ami-only when the tries run out while the reads still fail (2 tries, fewer than the retry bound): could not determine, not 'never Online'" 1 "$rc" "$WORK/o-lasterr.log" \
  'FATAL: could not determine whether build host i-fakerun001 is Online to SSM: 2 reads in a row failed'
! grep -q 'never reported Online' "$WORK/o-lasterr.log"; ok "  ... and it does not say the host was never Online" $?
st o-flaky "${BUILD_RESULTS/@KERNEL@/Success}"; export FAKE_AWS_FAIL='ssm describe-instance-information||ThrottlingException|2'
SU_ENV=(SSM_ONLINE_TRIES=5 SSM_ONLINE_SLEEP=0)
rc=0; su o-flaky --ami-only || rc=$?
check "ACCEPT two failed reads in a row, then Online: --ami-only completes" 0 "$rc" "$WORK/o-flaky.log" '--ami-only: done\.'
python3 - "$WORK/o-flaky.calls.jsonl" <<'PY'; ok "  ... after 3 reads of the build host (2 failed, then Online)" $?
import json, sys
c = [json.loads(l) for l in open(sys.argv[1])]
n = sum(1 for x in c if x["call"] == "ssm describe-instance-information" and "Key=InstanceIds,Values=i-fakerun001" in x["argv"])
assert n == 3, n
PY
unset FAKE_AWS_FAIL; SU_ENV=()

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "bounded SSM, AMI, status and reboot waits and the two-stage setup proven both ways in the real code."
