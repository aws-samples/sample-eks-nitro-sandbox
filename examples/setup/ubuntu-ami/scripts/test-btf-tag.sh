#!/usr/bin/env bash
# test-btf-tag.sh: proves the BtfValidated=true decision both ways, in the REAL code, with a fake
# `aws` (scripts/testlib/fake_aws.py) first on PATH. No AWS account and no cluster are reached.
#
#   scripts/test-btf-tag.sh
#
#   1  scripts/lib/btf-tag.sh btf_tag_ami_if_verified, sourced (not copied): tags only an AMI that
#      carries BOTH run tags (ManagedBy and this RunId) and only on the literal status "pass";
#      a failed tag read or a failed create-tags is never reported as tagged.
#   2  scripts/verify-fresh-instance.sh, the real caller (M11), against the fake's EC2 and SSM:
#      both remote checks pass -> create-tags, after both invocations reported Success; the image
#      check fails, the smoke check fails, or SSM never comes Online -> no create-tags. The
#      verification instance is terminated in every case; a termination that is not confirmed
#      (terminate or its waiter fails) also means no create-tags, and the exit trap retries it
#      (RR-015). The fake's SSM answers only the instance a command was sent to (RR-018).
#
# The fake keeps a JSON state file per case and logs every call, so the test asserts what was
# called, in what order, and what the AMI's tags became. The account id is the AWS
# documentation's example id.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE="$(cd "$HERE/.." && pwd)"
REPO_ROOT_REAL="$(cd "$SAMPLE/../../.." && pwd)"
mkdir -p "$REPO_ROOT_REAL/tmp"
WORK="$(mktemp -d "$REPO_ROOT_REAL/tmp/test-btf-tag.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export ISSUE10_RUN_DIR="$WORK/run" AWS_REGION=us-west-2 CLUSTER_NAME=example-cluster RESOURCE_PREFIX=ubuntu-ami-sample \
       NAMESPACE=ubuntu-ami-sample RUN_ID=testrun1
unset KUBECTL NODEGROUP_NAME
AMI=ami-0example

pass=0; fail=0
check() { # check <description> <expected-rc> <actual-rc> <log> [<regex the log must match>]
  local ok=0
  [[ "$3" -eq "$2" ]] || ok=1
  if [[ $ok -eq 0 && -n "${5:-}" ]]; then grep -qE -- "$5" "$4" || ok=1; fi
  if [[ $ok -eq 0 ]]; then printf '  PASS  %s (rc=%s)\n' "$1" "$3"; pass=$((pass+1))
  else printf '  FAIL  %s (expected rc=%s%s, got rc=%s)\n' "$1" "$2" "${5:+ and /$5/}" "$3"; sed 's/^/        | /' "$4" | tail -n 10; fail=$((fail+1)); fi
}
ok() { # ok <description> <rc-of-an-assertion>
  if [[ "$2" -eq 0 ]]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}

STUB="$WORK/bin"; mkdir -p "$STUB"
printf '#!/bin/bash\nexec python3 "%s" "$@"\n' "$HERE/testlib/fake_aws.py" > "$STUB/aws"
chmod +x "$STUB/aws"
export PATH="$STUB:$PATH"

# st <case> <ami-tags-json> [<ssm-json>]: this case's state (one AMI with the given tags) and log
st() {
  export FAKE_AWS_STATE="$WORK/$1.state.json" FAKE_AWS_LOG="$WORK/$1.calls.jsonl"
  : > "$FAKE_AWS_LOG"; unset FAKE_AWS_FAIL
  local ssmjs="${3:-}"; [ -n "$ssmjs" ] || ssmjs='{}'
  python3 - "$FAKE_AWS_STATE" "$2" "$ssmjs" <<'PY'
import json, sys
tags = [{"Key": k, "Value": v} for k, v in json.loads(sys.argv[2]).items()]
s = {"account": "111122223333", "ec2": {"images": [{"ImageId": "ami-0example", "Tags": tags}], "instances": []},
     "ssm": json.loads(sys.argv[3])}
json.dump(s, open(sys.argv[1], "w"))
PY
}
calls() { python3 -c 'import json,re,sys; print(sum(1 for l in open(sys.argv[1]) if re.search(sys.argv[2], json.loads(l)["call"])))' "$WORK/$1.calls.jsonl" "$2"; }
ami_tag() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print({t["Key"]: t["Value"] for t in s["ec2"]["images"][0]["Tags"]}.get(sys.argv[2], ""))' "$FAKE_AWS_STATE" "$1"; }
OWN='{"ManagedBy": "ubuntu-ami-sample", "RunId": "testrun1"}'

echo "== 1/2 the decision: scripts/lib/btf-tag.sh btf_tag_ami_if_verified =================="
tagfn() { # tagfn <case> <status>: run the real function, sourced with the real common.sh
  bash -c '. "$1/lib/common.sh" && . "$1/lib/btf-tag.sh" && btf_tag_ami_if_verified "$2" "$3" "Key=KernelVersion,Value=6.18.56"' \
    _ "$HERE" "$AMI" "$2" > "$WORK/$1.log" 2>&1
}
st t-pass "$OWN"
rc=0; tagfn t-pass pass || rc=$?
check "ACCEPT an AMI with both run tags and status pass: tagged" 0 "$rc" "$WORK/t-pass.log" "tagged $AMI BtfValidated=true"
[[ "$(ami_tag BtfValidated)" == true && "$(ami_tag ManagedBy)" == ubuntu-ami-sample && "$(ami_tag RunId)" == testrun1 && "$(ami_tag KernelVersion)" == 6.18.56 ]]
ok "  ... the AMI now carries BtfValidated=true and the metadata tag, ManagedBy and RunId unchanged" $?
while IFS='|' read -r name tags status want rx why; do
  [ -n "$name" ] || continue
  st "$name" "$tags"
  rc=0; tagfn "$name" "$status" || rc=$?
  check "$why" "$want" "$rc" "$WORK/$name.log" "$rx"
  [ "$(calls "$name" '^ec2 create-tags$')" = 0 ] && [ -z "$(ami_tag BtfValidated)" ]
  ok "  ... and create-tags was never called" $?
done <<'CASES'
t-fail|{"ManagedBy": "ubuntu-ami-sample", "RunId": "testrun1"}|fail|2|verification did not pass \(status=fail\)|REJECT status fail on this run's AMI
t-notliteral|{"ManagedBy": "ubuntu-ami-sample", "RunId": "testrun1"}|PASS|2|status=PASS|REJECT any status but the literal "pass"
t-owner|{"ManagedBy": "someone-else", "RunId": "testrun1"}|pass|1|does not carry ManagedBy=ubuntu-ami-sample and RunId=testrun1|REJECT an AMI another owner tagged, even on pass
t-otherrun|{"ManagedBy": "ubuntu-ami-sample", "RunId": "testrun2"}|pass|1|does not carry ManagedBy=ubuntu-ami-sample and RunId=testrun1|REJECT an AMI from another run of this sample, even on pass
t-untagged|{}|pass|1|does not carry|REJECT an AMI with no tags, even on pass
CASES
st t-readfail "$OWN"; export FAKE_AWS_FAIL='ec2 describe-images||UnauthorizedOperation'
rc=0; tagfn t-readfail pass || rc=$?
check "REJECT (fail closed) when the AMI's tags cannot be read" 1 "$rc" "$WORK/t-readfail.log" 'tags could not be read'
[ "$(calls t-readfail '^ec2 create-tags$')" = 0 ]; ok "  ... and create-tags was never called" $?
st t-tagfail "$OWN"; export FAKE_AWS_FAIL='ec2 create-tags||UnauthorizedOperation'
rc=0; tagfn t-tagfail pass || rc=$?
check "REJECT a create-tags failure: never reported as tagged" 1 "$rc" "$WORK/t-tagfail.log" 'BtfValidated=true was NOT confirmed applied'
! grep -q "tagged $AMI BtfValidated=true" "$WORK/t-tagfail.log"; ok "  ... and no success line was printed" $?
unset FAKE_AWS_FAIL

echo
echo "== 2/2 the real caller: scripts/verify-fresh-instance.sh (M11) =========================="
ssm() { # ssm <verify-image status> <smoke status> [online]
  printf '{"online": %s, "results": [{"match": "verify-image.py", "Status": "%s", "stdout": "image_configuration: %s\\ncontainerd 2.2.1 supported by the GA shim"}, {"match": "40-smoke.sh", "Status": "%s", "stdout": "smoke %s"}]}' \
    "${3:-true}" "$1" "$1" "$2" "$2"
}
vf() { env AMI_ID="$AMI" SECURITY_GROUP_ID=sg-0example SUBNET_ID=subnet-0example1 SSM_ONLINE_TRIES=2 SSM_POLL_SECONDS=0 \
       bash "$HERE/verify-fresh-instance.sh" > "$WORK/$1.log" 2>&1; }
order() { python3 - "$WORK/$1.calls.jsonl" <<'PY'
import json, sys
c = [json.loads(l) for l in open(sys.argv[1])]
names = [x["call"] for x in c]
inv = [i for i, n in enumerate(names) if n == "ssm get-command-invocation"]
tag = [i for i, n in enumerate(names) if n == "ec2 create-tags"]
term = [i for i, n in enumerate(names) if n == "ec2 terminate-instances"]
print(f"invocations={inv} create-tags={tag} terminate={term}")
assert len(inv) == 2 and len(tag) == 1 and tag[0] > max(inv), "create-tags must follow both invocations"
assert term and term[0] < tag[0], "the instance is terminated before the AMI is marked"
PY
}
st c-pass "$OWN" "$(ssm Success Success)"
rc=0; vf c-pass || rc=$?
check "ACCEPT both remote checks Success: the AMI is tagged BtfValidated=true" 0 "$rc" "$WORK/c-pass.log" "tagged $AMI BtfValidated=true"
rc=0; order c-pass > "$WORK/c-pass.order" 2>&1 || rc=$?
check "  ... and create-tags came after both get-command-invocation calls, the instance already terminated" 0 "$rc" "$WORK/c-pass.order"
[[ "$(ami_tag BtfValidated)" == true ]]; ok "  ... and the AMI's state shows it" $?
head -n 1 "$WORK/run/out/runs/testrun1/evidence/fresh-instance-verify-image.txt" | grep -qx Success
ok "  ... and the evidence file starts with the invocation's Status (no log line ahead of it)" $?
while IFS='|' read -r name img smoke online want rx sends why; do
  [ -n "$name" ] || continue
  st "$name" "$OWN" "$(ssm "$img" "$smoke" "$online")"
  rc=0; vf "$name" || rc=$?
  check "$why" "$want" "$rc" "$WORK/$name.log" "$rx"
  [ "$(calls "$name" '^ec2 create-tags$')" = 0 ] && [ -z "$(ami_tag BtfValidated)" ]; ok "  ... no create-tags, and the AMI is not marked" $?
  [ "$(calls "$name" '^ssm send-command$')" = "$sends" ]; ok "  ... after $sends remote command(s)" $?
  [ "$(calls "$name" '^ec2 terminate-instances$')" = 1 ]; ok "  ... and the verification instance was terminated" $?
done <<'CASES'
c-imgfail|Failed|Success|true|1|verify-image.py failed on the fresh instance|1|REJECT the image check Failed: smoke is not run, nothing is tagged
c-smokefail|Success|Failed|true|1|40-smoke.sh failed on the fresh instance|2|REJECT the smoke check Failed after the image check passed: nothing is tagged
c-offline|Success|Success|false|1|never reported Online to SSM|0|REJECT an instance SSM never sees Online: nothing runs, nothing is tagged
CASES
# RR-015: both checks pass, but the instance's termination is not confirmed: the AMI is not
# marked, the script fails, and the exit trap (instance_id kept) tries the termination again.
while IFS='@' read -r name rule why; do
  [ -n "$name" ] || continue
  st "$name" "$OWN" "$(ssm Success Success)"; export FAKE_AWS_FAIL="$rule"
  rc=0; vf "$name" || rc=$?
  check "$why" 1 "$rc" "$WORK/$name.log" 'was not confirmed terminated; BtfValidated=true was not applied'
  [ "$(calls "$name" '^ec2 create-tags$')" = 0 ] && [ -z "$(ami_tag BtfValidated)" ] && ! grep -q 'fresh-instance verification PASS' "$WORK/$name.log"
  ok "  ... no create-tags, the AMI is not marked, and no PASS line" $?
  [ "$(calls "$name" '^ec2 terminate-instances$')" = 2 ]; ok "  ... and the exit trap tried the termination again (2 terminate calls)" $?
  unset FAKE_AWS_FAIL
done <<'CASES'
c-termfail@ec2 terminate-instances||UnauthorizedOperation@REJECT (RR-015) a refused terminate-instances after both checks passed
c-waitfail@ec2 wait instance-terminated||WaiterFailed@REJECT (RR-015) a terminate whose instance-terminated waiter fails
CASES
# RR-018: the fake binds SSM to EC2, so a wrong-instance call cannot pass. Proven on the fake
# itself, with the state c-pass left (its instance i-fakerun001 terminated, command cmd-001).
fa() { FAKE_AWS_STATE="$WORK/c-pass.state.json" FAKE_AWS_LOG="$WORK/fa.calls.jsonl" aws "$@" --region us-west-2 --output json > "$WORK/fa.log" 2>&1; }
rc=0; fa ssm get-command-invocation --command-id cmd-001 --instance-id i-fakerun001 || rc=$?
check "ACCEPT (RR-018) the fake answers an invocation read that names the command's own instance" 0 "$rc" "$WORK/fa.log" '"Status": "Success"'
rc=0; fa ssm get-command-invocation --command-id cmd-001 --instance-id i-0other || rc=$?
check "REJECT (RR-018) the same read naming another instance" 254 "$rc" "$WORK/fa.log" 'InvocationDoesNotExist'
rc=0; fa ssm wait command-executed --command-id cmd-001 --instance-id i-0other || rc=$?
check "REJECT (RR-018) a wait naming another instance" 254 "$rc" "$WORK/fa.log" 'InvocationDoesNotExist'
rc=0; fa ssm send-command --instance-ids i-fakerun001 --document-name AWS-RunShellScript --parameters 'commands=["verify-image.py"]' || rc=$?
check "REJECT (RR-018) a command to an instance that is no longer running" 254 "$rc" "$WORK/fa.log" 'is not registered with SSM'
rc=0; fa ssm describe-instance-information --filters Key=InstanceIds,Values=i-fakerun001 || rc=$?
check "REJECT (RR-018) SSM registration of a terminated instance: no Online entry" 0 "$rc" "$WORK/fa.log" '"InstanceInformationList": \[\]'
st c-otherrun '{"ManagedBy": "ubuntu-ami-sample", "RunId": "testrun2"}' "$(ssm Success Success)"
rc=0; vf c-otherrun || rc=$?
check "REJECT both checks Success on an AMI from another run: refused, not tagged" 1 "$rc" "$WORK/c-otherrun.log" 'BtfValidated=true was not applied'
[ -z "$(ami_tag BtfValidated)" ]; ok "  ... and the AMI is not marked" $?

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "BtfValidated=true proven both ways in btf-tag.sh and in its real caller, verify-fresh-instance.sh."
