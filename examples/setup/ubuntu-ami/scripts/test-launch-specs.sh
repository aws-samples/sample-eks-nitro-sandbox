#!/usr/bin/env bash
# test-launch-specs.sh: proves the launch rules (M1) both ways, in the REAL scripts, with a fake
# `aws` (scripts/testlib/fake_aws.py) first on PATH. No AWS account and no cluster are reached.
#
#   scripts/test-launch-specs.sh
#
#   1  scripts/lib/launch_spec.py       accepts the specs it renders; refuses IMDSv1, a hop limit
#                                       other than 1, IMDS off, enclaves off, and a missing or
#                                       wrong ManagedBy or RunId on the instance or its volume
#   2  scripts/join-nodegroup.sh        the node launch template EC2 receives requires IMDSv2 with
#                                       hop limit 1, has enclaves on and tags nodes and volumes
#                                       with both tags; the template and node group carry both
#                                       tags; a failed call stops everything after it
#   3  scripts/verify-fresh-instance.sh the verification instance EC2 receives meets the same
#                                       rules, and a failure after launch terminates it
#   4  setup.sh                         the build host is launched from the spec it checked
#
# The fake keeps a JSON state file per case and logs every call; a case fails only the call
# under test (FAKE_AWS_FAIL) and asserts what was, or was not, sent to EC2 and EKS.
# The account id is the AWS documentation's example id.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE="$(cd "$HERE/.." && pwd)"
REPO_ROOT_REAL="$(cd "$SAMPLE/../../.." && pwd)"
mkdir -p "$REPO_ROOT_REAL/tmp"
WORK="$(mktemp -d "$REPO_ROOT_REAL/tmp/test-launch-specs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export ISSUE10_RUN_DIR="$WORK/run" AWS_REGION=us-west-2 CLUSTER_NAME=example-cluster RESOURCE_PREFIX=ubuntu-ami-sample \
       NAMESPACE=ubuntu-ami-sample RUN_ID=testrun1
unset KUBECTL NODEGROUP_NAME
RS="$WORK/run/out/runs/testrun1"

pass=0; fail=0
check() { # check <description> <expected-rc> <actual-rc> <log> [<regex the log must match>]
  local ok=0
  [[ "$3" -eq "$2" ]] || ok=1
  if [[ $ok -eq 0 && -n "${5:-}" ]]; then grep -qE -- "$5" "$4" || ok=1; fi
  if [[ $ok -eq 0 ]]; then printf '  PASS  %s (rc=%s)\n' "$1" "$3"; pass=$((pass+1))
  else printf '  FAIL  %s (expected rc=%s%s, got rc=%s)\n' "$1" "$2" "${5:+ and /$5/}" "$3"; sed 's/^/        | /' "$4" | tail -n 10; fail=$((fail+1)); fi
}
ok() { # ok <description> <rc-of-an-assertion> [<file to show on failure>]
  if [[ "$2" -eq 0 ]]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$1"; [ -n "${3:-}" ] && sed 's/^/        | /' "$3" | tail -n 10; fail=$((fail+1)); fi
}

STUB="$WORK/bin"; mkdir -p "$STUB"
printf '#!/bin/bash\nexec python3 "%s" "$@"\n' "$HERE/testlib/fake_aws.py" > "$STUB/aws"
chmod +x "$STUB/aws"
export PATH="$STUB:$PATH"

# st <case>: point the fake at this case's state and log files, with the example cluster in it
st() {
  export FAKE_AWS_STATE="$WORK/$1.state.json" FAKE_AWS_LOG="$WORK/$1.calls.jsonl"
  : > "$FAKE_AWS_LOG"; unset FAKE_AWS_FAIL
  printf '%s\n' '{"account": "111122223333", "eks": {"clusters": {"example-cluster": {"endpoint": "https://EXAMPLE0123.gr7.us-west-2.eks.amazonaws.com", "certificateAuthority": {"data": "Q0EtREFUQS1GSVhUVVJF"}, "kubernetesNetworkConfig": {"serviceIpv4Cidr": "10.100.0.0/16"}}}}}' > "$FAKE_AWS_STATE"
}
# calls <case> <regex>: number of logged calls whose "service op" matches
calls() { python3 -c 'import json,re,sys; print(sum(1 for l in open(sys.argv[1]) if re.search(sys.argv[2], json.loads(l)["call"])))' "$WORK/$1.calls.jsonl" "$2"; }
# sent <case> <call> <field>: the JSON body the first such call sent (cli_input_json or launch_template_data)
sent() { python3 -c '
import json, sys
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e["call"] == sys.argv[2]:
        print(json.dumps(e.get(sys.argv[3]))); break
' "$WORK/$1.calls.jsonl" "$2" "$3"; }
# rules <json-file> <name>: assert the M1 rules on a spec, independently of launch_spec.py
rules() { python3 - "$1" "$2" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
md, bad = s.get("MetadataOptions") or {}, []
if md.get("HttpTokens") != "required": bad.append("HttpTokens")
if md.get("HttpPutResponseHopLimit") != 1: bad.append("hop limit")
if (s.get("EnclaveOptions") or {}).get("Enabled") is not True: bad.append("enclaves")
ts = {t["ResourceType"]: {x["Key"]: x["Value"] for x in t["Tags"]} for t in s.get("TagSpecifications") or []}
for rt in ("instance", "volume"):
    t = ts.get(rt, {})
    if t.get("ManagedBy") != "ubuntu-ami-sample" or t.get("RunId") != "testrun1": bad.append(rt + " tags")
    if t.get("Name") != sys.argv[2]: bad.append(rt + " Name")
print("rules broken: " + ", ".join(bad) if bad else "rules met")
sys.exit(1 if bad else 0)
PY
}
LS() { python3 "$HERE/lib/launch_spec.py" "$@" --owner-key ManagedBy --owner-value ubuntu-ami-sample --run-key RunId --run-id testrun1; }

echo "== 1/4 the launch rules: scripts/lib/launch_spec.py (M1) ==============================="
printf '#!/bin/bash\nexit 0\n' > "$WORK/ud.sh"
LS render-instance --name ubuntu-ami-sample-testrun1-verify --image-id ami-0example --instance-type m8i.xlarge --profile p \
  --security-group sg-0example --subnet subnet-0example > "$WORK/inst.json"
LS render-instance --name ubuntu-ami-sample-testrun1-build --image-id ami-0example --instance-type m8i.4xlarge --profile p \
  --security-group sg-0example --subnet subnet-0example --root-gb 120 > "$WORK/build.json"
LS render-lt --name ubuntu-ami-sample-testrun1-ng --image-id ami-0example --instance-type m8i.xlarge --user-data-file "$WORK/ud.sh" > "$WORK/lt.json"
rc=0; LS check-instance "$WORK/inst.json" > "$WORK/c-inst.log" 2>&1 || rc=$?
check "ACCEPT the verification instance spec it renders" 0 "$rc" "$WORK/c-inst.log" 'LAUNCH SPEC OK'
rc=0; LS check-instance "$WORK/build.json" > "$WORK/c-build.log" 2>&1 || rc=$?
check "ACCEPT the build host spec it renders (120 GiB gp3 root)" 0 "$rc" "$WORK/c-build.log" 'LAUNCH SPEC OK'
rc=0; LS check-lt "$WORK/lt.json" > "$WORK/c-lt.log" 2>&1 || rc=$?
check "ACCEPT the node launch template data it renders" 0 "$rc" "$WORK/c-lt.log" 'LAUNCH SPEC OK'
rc=0; rules "$WORK/lt.json" ubuntu-ami-sample-testrun1-ng > "$WORK/r-lt.log" 2>&1 || rc=$?
check "  ... and the rendered template meets the rules read independently of launch_spec.py" 0 "$rc" "$WORK/r-lt.log" 'rules met'
# mutate <in> <out> <python statement over s>
mutate() { python3 -c "import json,sys; s=json.load(open(sys.argv[1])); $3; json.dump(s, open(sys.argv[2], 'w'))" "$1" "$2"; }
while IFS='|' read -r name base code rx why; do
  [ -n "$name" ] || continue
  mutate "$WORK/$base.json" "$WORK/m-$name.json" "$code"
  cmp -s "$WORK/$base.json" "$WORK/m-$name.json" && { echo "  FAIL  the $name mutation did not change the spec"; fail=$((fail+1)); continue; }
  rc=0; LS "check-$([ "$base" = lt ] && echo lt || echo instance)" "$WORK/m-$name.json" > "$WORK/m-$name.log" 2>&1 || rc=$?
  check "$why" 1 "$rc" "$WORK/m-$name.log" "$rx"
done <<'CASES'
inst-imdsv1|inst|s["MetadataOptions"]["HttpTokens"] = "optional"|HttpTokens is 'optional', must be 'required'|REJECT a verification instance with IMDSv1 allowed (HttpTokens optional)
lt-imdsv1|lt|s["MetadataOptions"]["HttpTokens"] = "optional"|HttpTokens is 'optional'|REJECT a node launch template with IMDSv1 allowed
lt-hop2|lt|s["MetadataOptions"]["HttpPutResponseHopLimit"] = 2|HopLimit is 2, must be 1|REJECT a node launch template with hop limit 2 (a pod could reach the node's credentials)
build-hop2|build|s["MetadataOptions"]["HttpPutResponseHopLimit"] = 2|HopLimit is 2, must be 1|REJECT a build host with hop limit 2
lt-no-md|lt|s.pop("MetadataOptions")|HttpTokens is None|REJECT a node launch template with no MetadataOptions (the account default applies)
inst-imds-off|inst|s["MetadataOptions"]["HttpEndpoint"] = "disabled"|HttpEndpoint is disabled|REJECT IMDS turned off (SSM and the bootstrap need it)
lt-enclaves-off|lt|s["EnclaveOptions"]["Enabled"] = False|EnclaveOptions.Enabled is not true|REJECT enclaves off
inst-no-enclaves|inst|s.pop("EnclaveOptions")|EnclaveOptions.Enabled is not true|REJECT no EnclaveOptions
lt-vol-no-runid|lt|[t for t in s["TagSpecifications"] if t["ResourceType"] == "volume"][0]["Tags"].pop(2)|volume tag RunId is None|REJECT a node volume without RunId (the reviewer's case)
inst-other-run|inst|[t for t in s["TagSpecifications"] if t["ResourceType"] == "instance"][0]["Tags"][2]["Value"] = "testrun2"|instance tag RunId is 'testrun2', must be 'testrun1'|REJECT an instance tagged for another run
inst-no-owner|inst|[t for t in s["TagSpecifications"] if t["ResourceType"] == "instance"][0]["Tags"].pop(1)|instance tag ManagedBy is None|REJECT an instance without ManagedBy
lt-no-volume-tags|lt|s["TagSpecifications"] = [t for t in s["TagSpecifications"] if t["ResourceType"] != "volume"]|no TagSpecifications for ResourceType volume|REJECT a node launch template that does not tag volumes
CASES
rc=0; LS check-lt "$WORK/does-not-exist.json" > "$WORK/c-missing.log" 2>&1 || rc=$?
check "REJECT a spec file that cannot be read" 1 "$rc" "$WORK/c-missing.log" 'cannot read launch spec'

echo
echo "== 2/4 the node launch template: scripts/join-nodegroup.sh (M1, H2) ====================="
jn() { env AMI_ID=ami-0example NODE_ROLE_ARN=arn:aws:iam::111122223333:role/ubuntu-ami-sample-testrun1-node \
       NODE_SUBNET_IDS="subnet-0example1 subnet-0example2" bash "$HERE/join-nodegroup.sh" "$@" > "$WORK/$CASE.log" 2>&1; }
CASE=jn-ok; st "$CASE"
rc=0; jn || rc=$?
check "ACCEPT a run: the launch template and the node group are created" 0 "$rc" "$WORK/$CASE.log" 'node group ubuntu-ami-sample-testrun1-ng is ACTIVE'
sent jn-ok "ec2 create-launch-template" launch_template_data > "$WORK/jn-ok.sent.json"
rc=0; rules "$WORK/jn-ok.sent.json" ubuntu-ami-sample-testrun1-ng > "$WORK/jn-ok.rules.log" 2>&1 || rc=$?
check "  ... and the template data EC2 received: IMDSv2 required, hop limit 1, enclaves on, ManagedBy+RunId+Name on instance and volume" 0 "$rc" "$WORK/jn-ok.rules.log" 'rules met'
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)' "$WORK/jn-ok.sent.json" "$RS/nodegroup-launch-template.json"
ok "  ... and it is byte for byte the data file the script checked (file://, not re-rendered)" $?
python3 - "$WORK/jn-ok.sent.json" "$WORK/jn-ok.ud.sh" <<'PY'; ok "  ... and its user data is the rendered bootstrap script" $?
import base64, json, sys
open(sys.argv[2], "wb").write(base64.b64decode(json.load(open(sys.argv[1]))["UserData"]))
PY
rc=0; bash "$HERE/join-nodegroup.sh" --check-user-data "$WORK/jn-ok.ud.sh" > "$WORK/jn-ok.ud.log" 2>&1 || rc=$?
check "  ... which passes the user data check" 0 "$rc" "$WORK/jn-ok.ud.log" 'USER DATA OK'
python3 - "$FAKE_AWS_STATE" <<'PY'; ok "  ... and the launch template (ubuntu-ami-sample-testrun1-lt) and node group (ubuntu-ami-sample-testrun1-ng) carry ManagedBy and RunId" $?
import json, sys
s = json.load(open(sys.argv[1]))
lt = s["ec2"]["launch_templates"]
assert len(lt) == 1 and lt[0]["LaunchTemplateName"] == "ubuntu-ami-sample-testrun1-lt", lt
assert {t["Key"]: t["Value"] for t in lt[0]["Tags"]} == {"ManagedBy": "ubuntu-ami-sample", "RunId": "testrun1"}, lt
ng = s["eks"]["nodegroups"]
assert list(ng) == ["example-cluster/ubuntu-ami-sample-testrun1-ng"], ng
assert ng["example-cluster/ubuntu-ami-sample-testrun1-ng"]["tags"] == {"ManagedBy": "ubuntu-ami-sample", "RunId": "testrun1"}, ng
PY
python3 - "$WORK/jn-ok.calls.jsonl" <<'PY'; ok "  ... and create-nodegroup names that template, the NoSchedule taint and the node role" $?
import json, sys
e = [json.loads(l) for l in open(sys.argv[1]) if json.loads(l)["call"] == "eks create-nodegroup"][0]["argv"]
j = " ".join(e)
assert "--launch-template id=lt-fakerun001" in j and "key=sandbox.preview/ubuntu-ami,value=true,effect=NO_SCHEDULE" in j, j
assert "--node-role arn:aws:iam::111122223333:role/ubuntu-ami-sample-testrun1-node" in j, j
PY
# --check-launch-template on the checked file and on mutations of it
rc=0; bash "$HERE/join-nodegroup.sh" --check-launch-template "$RS/nodegroup-launch-template.json" > "$WORK/jn-clt.log" 2>&1 || rc=$?
check "ACCEPT --check-launch-template on the data the run sent" 0 "$rc" "$WORK/jn-clt.log" 'LAUNCH SPEC OK'
mutate "$RS/nodegroup-launch-template.json" "$WORK/jn-hop2.json" 's["MetadataOptions"]["HttpPutResponseHopLimit"] = 2'
rc=0; bash "$HERE/join-nodegroup.sh" --check-launch-template "$WORK/jn-hop2.json" > "$WORK/jn-hop2.log" 2>&1 || rc=$?
check "REJECT --check-launch-template on the same data with hop limit 2" 1 "$rc" "$WORK/jn-hop2.log" 'HopLimit is 2'
mutate "$RS/nodegroup-launch-template.json" "$WORK/jn-v1.json" 's["MetadataOptions"]["HttpTokens"] = "optional"'
rc=0; bash "$HERE/join-nodegroup.sh" --check-launch-template "$WORK/jn-v1.json" > "$WORK/jn-v1.log" 2>&1 || rc=$?
check "REJECT --check-launch-template on the same data with IMDSv1 allowed" 1 "$rc" "$WORK/jn-v1.log" "HttpTokens is 'optional'"
# a failed call stops what follows it
CASE=jn-lt-denied; st "$CASE"; export FAKE_AWS_FAIL='ec2 create-launch-template||UnauthorizedOperation'
rc=0; jn || rc=$?
[ "$rc" -ne 0 ]; ok "REJECT a refused create-launch-template: the script fails (rc=$rc)" $? "$WORK/$CASE.log"
[ "$(calls jn-lt-denied '^eks create-nodegroup$')" = 0 ]; ok "  ... and no node group is created" $?
CASE=jn-ng-denied; st "$CASE"; export FAKE_AWS_FAIL='eks create-nodegroup||AccessDeniedException'
rc=0; jn || rc=$?
[ "$rc" -ne 0 ]; ok "REJECT a refused create-nodegroup: the script fails (rc=$rc), never reporting ACTIVE" $? "$WORK/$CASE.log"
! grep -q 'is ACTIVE' "$WORK/$CASE.log"; ok "  ... and it does not wait for or report a node group it did not create" $?
CASE=jn-cl-denied; st "$CASE"; export FAKE_AWS_FAIL='eks describe-cluster||AccessDeniedException'
rc=0; jn || rc=$?
check "REJECT an unreadable cluster: nothing is rendered or created" 1 "$rc" "$WORK/$CASE.log" 'could not read cluster example-cluster'
[ "$(calls jn-cl-denied '^ec2 |^eks create')" = 0 ]; ok "  ... and no EC2 or EKS create call is made" $?
unset FAKE_AWS_FAIL

echo
echo "== 3/4 the verification instance: scripts/verify-fresh-instance.sh (M1, H2) =============="
vf() { env AMI_ID=ami-0example SECURITY_GROUP_ID=sg-0example SUBNET_ID=subnet-0example1 bash "$HERE/verify-fresh-instance.sh" > "$WORK/$CASE.log" 2>&1; }
CASE=vf-wait; st "$CASE"; export FAKE_AWS_FAIL='ec2 wait instance-status-ok||RequestLimitExceeded'
rc=0; vf || rc=$?
[ "$rc" -ne 0 ]; ok "REJECT an instance that never reaches status-ok: the script fails (rc=$rc)" $? "$WORK/$CASE.log"
sent vf-wait "ec2 run-instances" cli_input_json > "$WORK/vf-wait.sent.json"
rc=0; rules "$WORK/vf-wait.sent.json" ubuntu-ami-sample-testrun1-verify > "$WORK/vf-wait.rules.log" 2>&1 || rc=$?
check "  ... the spec EC2 received: IMDSv2 required, hop limit 1, enclaves on, ManagedBy+RunId+Name on instance and volume" 0 "$rc" "$WORK/vf-wait.rules.log" 'rules met'
python3 - "$WORK/vf-wait.sent.json" "$RS/verify-instance-launch.json" <<'PY'; ok "  ... from the AMI under test with this run's profile, and byte for byte the file the script checked" $?
import json, sys
s, f = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
assert s == f
assert s["ImageId"] == "ami-0example" and s["IamInstanceProfile"] == {"Name": "ubuntu-ami-sample-testrun1-build"}, s
assert s["SecurityGroupIds"] == ["sg-0example"] and s["SubnetId"] == "subnet-0example1", s
PY
python3 - "$WORK/vf-wait.calls.jsonl" "$FAKE_AWS_STATE" <<'PY'; ok "  ... and the exit trap terminated the instance after the failure and waited for it" $?
import json, sys
c = [json.loads(l) for l in open(sys.argv[1])]
names = [x["call"] for x in c]
i = names.index("ec2 wait instance-status-ok")
t = names.index("ec2 terminate-instances")
assert t > i and "i-fakerun001" in c[t]["argv"], names
assert "ec2 wait instance-terminated" in names[t:], names
s = json.load(open(sys.argv[2]))
assert s["ec2"]["instances"][0]["State"]["Name"] == "terminated"
PY
[ "$(calls vf-wait '^ssm |^ec2 create-tags')" = 0 ]; ok "  ... and nothing ran on it over SSM and no BtfValidated tag was written" $?
CASE=vf-run-denied; st "$CASE"; export FAKE_AWS_FAIL='ec2 run-instances||UnauthorizedOperation'
rc=0; vf || rc=$?
[ "$rc" -ne 0 ]; ok "REJECT a refused run-instances: the script fails (rc=$rc)" $? "$WORK/$CASE.log"
[ "$(calls vf-run-denied '^ec2 terminate-instances$')" = 0 ]; ok "  ... and the trap has no instance to terminate (no id was returned)" $?
unset FAKE_AWS_FAIL

echo
echo "== 4/4 the build host launch: setup.sh (M1) ==========================================="
# launch_from_checked_spec <file>: every `aws ec2 run-instances` in <file> (comments stripped)
# sends --cli-input-json file://$X, and `launch_spec check-instance "$X" || die` comes before it.
launch_from_checked_spec() { python3 - "$1" <<'PY'
import re, sys
lines = [l.split("#", 1)[0] if not l.lstrip().startswith("#") else "" for l in open(sys.argv[1])]
runs = [i for i, l in enumerate(lines) if re.search(r"\baws ec2 run-instances\b", l)]
bad = [] if runs else ["no aws ec2 run-instances call"]
for i in runs:
    m = re.search(r'--cli-input-json "file://\$([A-Z_]+)"', lines[i])
    if not m:
        bad.append(f"line {i + 1}: run-instances does not send a --cli-input-json spec file")
        continue
    v = m.group(1)
    if not any(re.match(rf'\s*launch_spec check-instance "\${v}" \|\| die\b', l) for l in lines[:i]):
        bad.append(f"line {i + 1}: ${v} is not checked with launch_spec check-instance before the launch")
for b in bad:
    print("FAIL: " + b)
print("LAUNCHES FROM CHECKED SPEC" if not bad else "REFUSED")
sys.exit(1 if bad else 0)
PY
}
rc=0; launch_from_checked_spec "$SAMPLE/setup.sh" > "$WORK/st-ok.log" 2>&1 || rc=$?
check "ACCEPT setup.sh: the build host is launched from the spec file it checked" 0 "$rc" "$WORK/st-ok.log" 'LAUNCHES FROM CHECKED SPEC'
rc=0; launch_from_checked_spec "$HERE/verify-fresh-instance.sh" > "$WORK/st-vf.log" 2>&1 || rc=$?
check "ACCEPT verify-fresh-instance.sh by the same rule (cross-check of section 3)" 0 "$rc" "$WORK/st-vf.log" 'LAUNCHES FROM CHECKED SPEC'
sed 's#^launch_spec check-instance "\$BUILD_SPEC" || die#: launch_spec check-instance "$BUILD_SPEC" || die#' "$SAMPLE/setup.sh" > "$WORK/setup-nocheck.sh"
rc=0; launch_from_checked_spec "$WORK/setup-nocheck.sh" > "$WORK/st-nocheck.log" 2>&1 || rc=$?
check "REJECT a setup.sh whose check of the build spec was dropped" 1 "$rc" "$WORK/st-nocheck.log" 'is not checked with launch_spec check-instance'
sed 's#--cli-input-json "file://\$BUILD_SPEC"#--image-id "$BASE_AMI_ID" --metadata-options HttpTokens=optional#' "$SAMPLE/setup.sh" > "$WORK/setup-inline.sh"
rc=0; launch_from_checked_spec "$WORK/setup-inline.sh" > "$WORK/st-inline.log" 2>&1 || rc=$?
check "REJECT a setup.sh that launches with inline options instead of the checked file" 1 "$rc" "$WORK/st-inline.log" 'does not send a --cli-input-json spec file'

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "IMDSv2 hop limit 1, enclaves and both run tags proven both ways on the node launch template, the verification instance and the build host."
