#!/usr/bin/env bash
# test-run-scope.sh: proves the run-scope and ownership rules both ways, in the REAL scripts,
# with a fake `aws` (scripts/testlib/fake_aws.py) and a stub `kubectl` first on PATH. No AWS
# account and no cluster are reached.
#
#   scripts/test-run-scope.sh
#
#   1  scripts/00a-iam.sh            per-run role and profile names, both tags at creation, and a
#                                    reuse that refuses anything not exactly this run's (H1)
#   2  clean.sh                      only resources with ManagedBy AND this RunId are listed or
#                                    deleted, tags re-read before each delete, --keep-ami, failed
#                                    lookups, the expected bucket owner on every S3 call (H2, L1);
#                                    IAM roles and the profile by per-run name through IAM (H5);
#                                    each dependency lookup and the namespace read failed alone
#                                    (H7); the kube context checked before the first delete (H6);
#                                    --list-runs for a lost run id, read only (H2)
#   3  scripts/00b-stage-bucket.sh   revoke confirms the objects and the policy are gone, or fails (M5)
#   4  scripts/lib/common.sh         derived names checked against the API name limits (H2)
#
# The fake keeps a JSON state file per case and logs every call; a case fails only the call
# under test (FAKE_AWS_FAIL) and asserts both the exit code and what was, or was not, changed.
# The account ids are the AWS documentation's example ids.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE="$(cd "$HERE/.." && pwd)"
REPO_ROOT_REAL="$(cd "$SAMPLE/../../.." && pwd)"
mkdir -p "$REPO_ROOT_REAL/tmp"
WORK="$(mktemp -d "$REPO_ROOT_REAL/tmp/test-run-scope.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export ISSUE10_RUN_DIR="$WORK/run" AWS_REGION=us-west-2 CLUSTER_NAME=example-cluster RESOURCE_PREFIX=ubuntu-ami-sample NAMESPACE=ubuntu-ami-sample
unset RUN_ID KUBECTL NODEGROUP_NAME
ACCT=111122223333
OTHER_ACCT=444455556666

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
# Stub kubectl: answers the namespace read and delete clean.sh makes, from STUB_NS_JSON.
cat > "$STUB/kubectl" <<'SH'
#!/bin/bash
[ "${1:-}" = --context ] && [ "${2:-}" = "$STUB_CTX" ] || { echo "STUB kubectl: call without --context $STUB_CTX: $*" >&2; exit 97; }
shift 2
case "$*" in
  "config view --minify -o jsonpath={.clusters[0].cluster.server}")
    printf '%s' "${STUB_SERVER:-https://EXAMPLE0123.gr7.us-west-2.eks.amazonaws.com}" ;;
  "get namespace "*" -o json")
    if [ "${STUB_NS_ERR:-}" = denied ]; then echo 'Error from server (Forbidden): namespaces "x" is forbidden: User "test" cannot get resource' >&2; exit 1; fi
    if [ -n "${STUB_NS_JSON:-}" ]; then printf '%s\n' "$STUB_NS_JSON"; else echo 'Error from server (NotFound): namespaces "x" not found' >&2; exit 1; fi ;;
  "delete namespace "*) echo "namespace deleted" ;;
  *) echo "STUB kubectl: unexpected call: $*" >&2; exit 97 ;;
esac
SH
chmod +x "$STUB/aws" "$STUB/kubectl"
export PATH="$STUB:$PATH" KUBE_CONTEXT=example-context STUB_CTX=example-context

# st <case> : point the fake at this case's state and log files
st() { export FAKE_AWS_STATE="$WORK/$1.state.json" FAKE_AWS_LOG="$WORK/$1.calls.jsonl"; : > "$FAKE_AWS_LOG"; unset FAKE_AWS_FAIL; }
# calls <case> <regex>: number of logged calls whose "service op" matches
calls() { python3 -c 'import json,re,sys; print(sum(1 for l in open(sys.argv[1]) if re.search(sys.argv[2], json.loads(l)["call"])))' "$WORK/$1.calls.jsonl" "$2"; }
MUTATING='create-|attach-|put-|tag-|add-|delete-|detach-|remove-|terminate-|deregister-'
TRUST='{"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]}'

# iam_state <file> <role-tags-json> <profile-roles-json> <extra-attached-json> <inline-json> <trust-json>
iam_state() {
  python3 - "$@" <<'PY'
import json, sys
path, rtags, proles, extra, inline, trust = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3]), json.loads(sys.argv[4]), json.loads(sys.argv[5]), json.loads(sys.argv[6])
p = "ubuntu-ami-sample-testrun1"
ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
node = ["arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy", "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
        "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy", ssm]
tags = [{"Key": k, "Value": v} for k, v in rtags.items()]
state = {"account": "111122223333", "iam": {
    "roles": {p + "-build": {"Trust": trust, "Tags": tags, "Attached": [ssm] + extra, "Inline": inline},
              p + "-node": {"Trust": trust, "Tags": tags, "Attached": list(node), "Inline": {}}},
    "profiles": {p + "-build": {"Tags": tags, "Roles": proles}}}}
json.dump(state, open(path, "w"))
PY
}
OWN='{"ManagedBy": "ubuntu-ami-sample", "RunId": "testrun1"}'
iam() { RUN_ID=testrun1 bash "$HERE/00a-iam.sh" > "$WORK/$1.log" 2>&1; }

echo "== 1/4 IAM roles and the instance profile: scripts/00a-iam.sh (H1) ===================="
st fresh; echo '{"account": "111122223333"}' > "$FAKE_AWS_STATE"
rc=0; iam fresh || rc=$?
check "ACCEPT a fresh run: creates its per-run roles and profile" 0 "$rc" "$WORK/fresh.log" 'IAM: PASS \(run testrun1'
python3 - "$FAKE_AWS_STATE" <<'PY'; ok "both roles and the profile carry ManagedBy and RunId, the profile holds the build role" $?
import json, sys
s = json.load(open(sys.argv[1]))["iam"]
want = {"ManagedBy": "ubuntu-ami-sample", "RunId": "testrun1"}
t = lambda x: {i["Key"]: i["Value"] for i in x["Tags"]}
r, p = s["roles"], s["profiles"]
assert set(r) == {"ubuntu-ami-sample-testrun1-build", "ubuntu-ami-sample-testrun1-node"}, r.keys()
assert all(t(v) == want for v in r.values()) and t(p["ubuntu-ami-sample-testrun1-build"]) == want
assert p["ubuntu-ami-sample-testrun1-build"]["Roles"] == ["ubuntu-ami-sample-testrun1-build"]
assert r["ubuntu-ami-sample-testrun1-build"]["Attached"] == ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"]
PY
grep -q 'NODE_ROLE_ARN=arn:aws:iam::111122223333:role/ubuntu-ami-sample-testrun1-node' "$ISSUE10_RUN_DIR/out/runs/testrun1/iam.env"
ok "the node role ARN is recorded in the run state" $?
cp "$FAKE_AWS_STATE" "$WORK/resume.state.json"; st resume
rc=0; iam resume || rc=$?
check "ACCEPT a resumed run: reuses roles and profile that carry both tags and exact policies" 0 "$rc" "$WORK/resume.log" 'carries both run tags'
ok "the resumed run created and tagged nothing" "$( [ "$(calls resume 'create-|tag-|add-role')" = 0 ]; echo $?)"

refuse_iam() { # refuse_iam <case> <regex> <description> : rc 1, message, and no mutating call
  local rc=0; iam "$1" || rc=$?
  check "$3" 1 "$rc" "$WORK/$1.log" "$2"
  ok "  ... and changed nothing (no create, attach, put, tag or add call)" "$( [ "$(calls "$1" 'create-|attach-|put-|tag-|add-')" = 0 ]; echo $?)"
}
st owner; iam_state "$FAKE_AWS_STATE" '{"ManagedBy": "someone-else", "RunId": "testrun1"}' '["ubuntu-ami-sample-testrun1-build"]' '[]' '{}' "$TRUST"
refuse_iam owner 'refusing to reuse IAM role .* does not carry ManagedBy=ubuntu-ami-sample and RunId=testrun1' "REJECT a same-named role with another ManagedBy"
st otherrun; iam_state "$FAKE_AWS_STATE" '{"ManagedBy": "ubuntu-ami-sample", "RunId": "testrun2"}' '["ubuntu-ami-sample-testrun1-build"]' '[]' '{}' "$TRUST"
refuse_iam otherrun 'does not carry ManagedBy=ubuntu-ami-sample and RunId=testrun1' "REJECT a same-named role from another run (RunId mismatch)"
st untagged; iam_state "$FAKE_AWS_STATE" '{}' '["ubuntu-ami-sample-testrun1-build"]' '[]' '{}' "$TRUST"
refuse_iam untagged 'does not carry' "REJECT a same-named role with no tags"
st tagsdenied; iam_state "$FAKE_AWS_STATE" "$OWN" '["ubuntu-ami-sample-testrun1-build"]' '[]' '{}' "$TRUST"; export FAKE_AWS_FAIL='iam list-role-tags||AccessDenied'
refuse_iam tagsdenied 'could not determine the tags of IAM role' "REJECT (could not determine) when the role's tags cannot be read"
st getdenied; echo '{"account": "111122223333"}' > "$FAKE_AWS_STATE"; export FAKE_AWS_FAIL='iam get-role||AccessDenied'
refuse_iam getdenied 'could not determine IAM role' "REJECT (could not determine) when get-role fails for a reason other than NoSuchEntity"
st extra; iam_state "$FAKE_AWS_STATE" "$OWN" '["ubuntu-ami-sample-testrun1-build"]' '["arn:aws:iam::aws:policy/AdministratorAccess"]' '{}' "$TRUST"
rc=0; iam extra || rc=$?
check "REJECT a reused role with an extra attached managed policy" 1 "$rc" "$WORK/extra.log" 'AdministratorAccess'
st inline; iam_state "$FAKE_AWS_STATE" "$OWN" '["ubuntu-ami-sample-testrun1-build"]' '[]' '{"unexpected": {"Version": "2012-10-17"}}' "$TRUST"
rc=0; iam inline || rc=$?
check "REJECT a reused role with an unexpected inline policy" 1 "$rc" "$WORK/inline.log" 'unexpected inline policies: unexpected'
st trust; iam_state "$FAKE_AWS_STATE" "$OWN" '["ubuntu-ami-sample-testrun1-build"]' '[]' '{}' '{"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Principal": {"AWS": "*"}, "Action": "sts:AssumeRole"}]}'
refuse_iam trust 'trust policy is not deploy/iam-node-trust-policy.json' "REJECT a reused role with a different trust policy"
st profrole; iam_state "$FAKE_AWS_STATE" "$OWN" '["some-other-role"]' '[]' '{}' "$TRUST"
rc=0; iam profrole || rc=$?
check "REJECT a reused instance profile that holds another role" 1 "$rc" "$WORK/profrole.log" "holds role\(s\) 'some-other-role'"
st proftags; iam_state "$FAKE_AWS_STATE" "$OWN" '["ubuntu-ami-sample-testrun1-build"]' '[]' '{}' "$TRUST"
python3 - "$FAKE_AWS_STATE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["iam"]["profiles"]["ubuntu-ami-sample-testrun1-build"]["Tags"] = [{"Key": "ManagedBy", "Value": "someone-else"}]
json.dump(s, open(sys.argv[1], "w"))
PY
rc=0; iam proftags || rc=$?
check "REJECT a reused instance profile without this run's tags" 1 "$rc" "$WORK/proftags.log" 'refusing to reuse instance profile'
st addfail; echo '{"account": "111122223333"}' > "$FAKE_AWS_STATE"; export FAKE_AWS_FAIL='iam add-role-to-instance-profile||LimitExceeded'
rc=0; iam addfail || rc=$?
check "REJECT (not swallowed: the CLI's exit 254 stops the script) an add-role-to-instance-profile failure" 254 "$rc" "$WORK/addfail.log" 'LimitExceeded'
! grep -q 'IAM: PASS' "$WORK/addfail.log"; ok "  ... and no PASS line was printed" $?
st tagfail; echo '{"account": "111122223333"}' > "$FAKE_AWS_STATE"; export FAKE_AWS_FAIL='iam create-role||InvalidInput'
rc=0; iam tagfail || rc=$?
check "REJECT (not swallowed) a create-role-with-tags failure" 254 "$rc" "$WORK/tagfail.log" 'InvalidInput'

echo
echo "== 2/4 run-scoped clean up: clean.sh (H2, L1) ========================================"
# two_runs <file>: resources of run testrun1 and run testrun2, plus one with another ManagedBy
two_runs() {
  python3 - "$1" "$ACCT" "$OTHER_ACCT" "${2:-}" <<'PY'
import json, sys
path, acct, other, variant = sys.argv[1:5]
def tags(run, mb="ubuntu-ami-sample", name=None):
    t = [{"Key": "ManagedBy", "Value": mb}, {"Key": "RunId", "Value": run}]
    return t + ([{"Key": "Name", "Value": name}] if name else [])
s = {"account": acct, "ec2": {"instances": [], "images": [], "snapshots": [], "security_groups": [], "launch_templates": []},
     "eks": {"nodegroups": {}, "clusters": {"example-cluster": {"endpoint": "https://EXAMPLE0123.gr7.us-west-2.eks.amazonaws.com"}}},
     "iam": {"roles": {}, "profiles": {}}, "s3": {"buckets": {}}}
e = s["ec2"]
for run in ("testrun1", "testrun2"):
    p = f"ubuntu-ami-sample-{run}"
    e["instances"].append({"InstanceId": f"i-{run}-build", "State": {"Name": "running"}, "Tags": tags(run, name=p + "-build")})
    e["images"].append({"ImageId": f"ami-{run}", "Name": p, "Tags": tags(run), "BlockDeviceMappings": [{"Ebs": {"SnapshotId": f"snap-{run}-ami"}}]})
    e["snapshots"] += [{"SnapshotId": f"snap-{run}-ami", "VolumeSize": 120, "Tags": tags(run)},
                       {"SnapshotId": f"snap-{run}-orphan", "VolumeSize": 120, "Tags": tags(run)}]
    e["security_groups"].append({"GroupId": f"sg-{run}", "GroupName": p + "-build-sg", "Tags": tags(run)})
    e["launch_templates"].append({"LaunchTemplateId": f"lt-{run}", "LaunchTemplateName": p + "-lt", "Tags": tags(run)})
    s["eks"]["nodegroups"][f"example-cluster/{p}-ng"] = {"status": "ACTIVE", "tags": {"ManagedBy": "ubuntu-ami-sample", "RunId": run}}
    s["iam"]["roles"][p + "-build"] = {"Trust": {}, "Tags": tags(run), "Attached": ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"], "Inline": {p + "-stage-read": {}}}
    s["iam"]["roles"][p + "-node"] = {"Trust": {}, "Tags": tags(run), "Attached": ["arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"], "Inline": {}}
    s["iam"]["profiles"][p + "-build"] = {"Tags": tags(run), "Roles": [p + "-build"]}
    s["s3"]["buckets"][f"ubuntu-ami-sample-stage-{run}-abcdef"] = {"owner": acct, "Tags": tags(run), "objects": [f"{run}/a.zip", f"{run}/b.tgz"]}
e["instances"].append({"InstanceId": "i-someone-else", "State": {"Name": "running"}, "Tags": tags("testrun1", mb="other-sample")})
if variant == "drift":       # the by-id re-check sees another run's tags on run 1's instance
    e["instances"][0]["RecheckTags"] = tags("testrun2")
if variant == "foreign-bucket":
    s["s3"]["buckets"]["ubuntu-ami-sample-stage-testrun1-abcdef"]["owner"] = other
if variant == "no-iam":       # run 1's roles and profile never created (or already removed)
    for n in ("ubuntu-ami-sample-testrun1-build", "ubuntu-ami-sample-testrun1-node"):
        del s["iam"]["roles"][n]
    del s["iam"]["profiles"]["ubuntu-ami-sample-testrun1-build"]
if variant == "foreign-role":  # a same-named node role someone else owns
    s["iam"]["roles"]["ubuntu-ami-sample-testrun1-node"]["Tags"] = tags("testrun1", mb="someone-else")
if variant == "bare-profile":  # setup stopped after create-instance-profile, before add-role
    s["iam"]["profiles"]["ubuntu-ami-sample-testrun1-build"]["Roles"] = []
json.dump(s, open(path, "w"), indent=1)
PY
}
cl() { local c="$1"; shift; bash "$SAMPLE/clean.sh" "$@" > "$WORK/$c.log" 2>&1; }
remaining() { python3 -c '
import json, sys
s = json.load(open(sys.argv[1])); e = s["ec2"]
ids = [i["InstanceId"] for i in e["instances"] if i["State"]["Name"] != "terminated"] + [x["ImageId"] for x in e["images"]] \
    + [x["SnapshotId"] for x in e["snapshots"]] + [x["GroupId"] for x in e["security_groups"]] + [x["LaunchTemplateId"] for x in e["launch_templates"]] \
    + list(s["eks"]["nodegroups"]) + list(s["iam"]["roles"]) + ["profile:" + p for p in s["iam"]["profiles"]] + list(s["s3"]["buckets"])
print(" ".join(sorted(ids)))' "$FAKE_AWS_STATE"; }

st norun; two_runs "$FAKE_AWS_STATE"
rc=0; cl norun --dry-run || rc=$?
check "REJECT a clean up with no RUN_ID (no run state, no --run-id): nothing listed" 1 "$rc" "$WORK/norun.log" 'no RUN_ID'
ok "  ... and no AWS call was made" "$( [ "$(calls norun '.')" = 0 ]; echo $?)"

st dry; two_runs "$FAKE_AWS_STATE"
rc=0; cl dry --dry-run --run-id testrun1 || rc=$?
check "ACCEPT --dry-run for run testrun1" 0 "$rc" "$WORK/dry.log" 'nothing was deleted'
grep -q 'i-testrun1-build' "$WORK/dry.log" && grep -q 'ubuntu-ami-sample-stage-testrun1-abcdef' "$WORK/dry.log" && grep -q 'ubuntu-ami-sample-testrun1-node' "$WORK/dry.log"
ok "  ... lists run testrun1's instance, bucket and roles" $?
! grep -qE 'testrun2|i-someone-else' "$WORK/dry.log"
ok "  ... lists nothing of run testrun2 or of another ManagedBy" $?
ok "  ... changed nothing" "$( [ "$(calls dry "$MUTATING")" = 0 ]; echo $?)"
python3 - "$FAKE_AWS_LOG" <<'PY'; ok "  ... every EC2 list call filters on BOTH ManagedBy and RunId" $?
import json, sys
calls = [json.loads(l)["argv"] for l in open(sys.argv[1])]
lists = [a for a in calls if a[0] == "ec2" and a[1].startswith("describe-") and "--filters" in a]
assert lists, "no filtered describe calls"
for a in lists:
    j = " ".join(a)
    assert "Name=tag:ManagedBy,Values=ubuntu-ami-sample" in j and "Name=tag:RunId,Values=testrun1" in j, j
tag = [a for a in calls if a[0] == "resourcegroupstaggingapi"]
assert tag and all("Key=RunId,Values=testrun1" in " ".join(a) for a in tag)
PY
grep -q 'Left in place (shared, not the sample.s): the vpc-cni add-on' "$WORK/dry.log"
ok "  ... and says the shared vpc-cni add-on is left in place" $?

st full; two_runs "$FAKE_AWS_STATE"
mkdir -p "$ISSUE10_RUN_DIR/out"; printf 'RUN_ID=testrun1\n' > "$ISSUE10_RUN_DIR/out/run-state.env"
rc=0; STUB_NS_JSON='{"metadata": {"labels": {"app.kubernetes.io/part-of": "ubuntu-ami-sample", "app.kubernetes.io/instance": "testrun1"}}}' cl full --delete-aws-resources || rc=$?
check "ACCEPT a full clean up of the run in the run state (testrun1)" 0 "$rc" "$WORK/full.log" 'Clean up of run testrun1 complete'
left=$(remaining)
[[ "$left" != *testrun1* ]]; ok "  ... every testrun1 resource is gone (left: $left)" $?
for want in i-testrun2-build ami-testrun2 snap-testrun2-ami snap-testrun2-orphan sg-testrun2 lt-testrun2 ubuntu-ami-sample-testrun2-node profile:ubuntu-ami-sample-testrun2-build ubuntu-ami-sample-stage-testrun2-abcdef i-someone-else; do
  [[ " $left " == *" $want "* ]] || { echo "    missing: $want"; false; }
done; ok "  ... and every testrun2 resource, and the other sample's instance, is untouched" $?
python3 - "$FAKE_AWS_LOG" <<'PY'; ok "  ... every S3 call names the expected bucket owner (L1)" $?
import json, sys
s3 = [json.loads(l)["argv"] for l in open(sys.argv[1]) if json.loads(l)["argv"][0] == "s3api"]
assert s3, "no s3 calls"
for a in s3:
    assert "--expected-bucket-owner" in a and a[a.index("--expected-bucket-owner") + 1] == "111122223333", a
PY
rm -f "$ISSUE10_RUN_DIR/out/run-state.env"

st drift; two_runs "$FAKE_AWS_STATE" drift
rc=0; cl drift --delete-aws-resources --run-id testrun1 || rc=$?
check "REJECT deleting an instance whose tags changed between the listing and the delete (re-check)" 1 "$rc" "$WORK/drift.log" 'instance i-testrun1-build no longer carries'
[[ " $(remaining) " == *" i-testrun1-build "* ]]; ok "  ... the instance was not terminated" $?

st keep; two_runs "$FAKE_AWS_STATE"
rc=0; cl keepdry --dry-run --keep-ami --run-id testrun1 || rc=$?
check "ACCEPT --dry-run --keep-ami: the AMI and its snapshot are listed as kept" 0 "$rc" "$WORK/keepdry.log" 'ami-testrun1.*left in place \(kept on request\)'
grep -qE 'snap-testrun1-ami .*left in place \(kept on request\)' "$WORK/keepdry.log"; ok "  ... including the AMI's backing snapshot" $?
rc=0; cl keep --delete-aws-resources --keep-ami --run-id testrun1 || rc=$?
check "ACCEPT --delete-aws-resources --keep-ami" 0 "$rc" "$WORK/keep.log" 'Left in place \(kept on request\): AMI\(s\) ami-testrun1'
left=$(remaining)
[[ " $left " == *" ami-testrun1 "* && " $left " == *" snap-testrun1-ami "* ]]; ok "  ... the AMI and its backing snapshot remain" $?
[[ " $left " != *" snap-testrun1-orphan "* && " $left " != *" i-testrun1-build "* && " $left " != *" ubuntu-ami-sample-testrun1-build "* ]]
ok "  ... and the run's other resources (orphan snapshot, instance, roles) are gone" $?

st lookupfail; two_runs "$FAKE_AWS_STATE"; export FAKE_AWS_FAIL='ec2 describe-instances||UnauthorizedOperation'
rc=0; cl lookupfail --dry-run --run-id testrun1 || rc=$?
check "REJECT (could not determine) a --dry-run whose instance lookup fails" 1 "$rc" "$WORK/lookupfail.log" 'could not determine this run.s EC2 instances'

st foreign; two_runs "$FAKE_AWS_STATE" foreign-bucket
rc=0; cl foreign --delete-aws-resources --run-id testrun1 || rc=$?
check "REJECT emptying a same-named staging bucket owned by another account (expected owner)" 1 "$rc" "$WORK/foreign.log" 'could not determine the state of bucket ubuntu-ami-sample-stage-testrun1-abcdef'
python3 -c 'import json,sys; b=json.load(open(sys.argv[1]))["s3"]["buckets"]["ubuntu-ami-sample-stage-testrun1-abcdef"]; sys.exit(0 if len(b["objects"])==2 else 1)' "$FAKE_AWS_STATE"
ok "  ... and its objects were not deleted" $?

st nsother; two_runs "$FAKE_AWS_STATE"
rc=0; STUB_NS_JSON='{"metadata": {"labels": {"app.kubernetes.io/part-of": "ubuntu-ami-sample", "app.kubernetes.io/instance": "testrun2"}}}' cl nsother --run-id testrun1 || rc=$?
check "REJECT deleting the namespace when it carries another run's instance label" 1 "$rc" "$WORK/nsother.log" 'refusing to delete a namespace this run may not own'
OWN_NS='{"metadata": {"labels": {"app.kubernetes.io/part-of": "ubuntu-ami-sample", "app.kubernetes.io/instance": "testrun1"}}}'

echo
echo "== 2b/4 IAM by per-run name, every lookup checked, the kube context: clean.sh (H5, H7, H6) =="
st iamdry; two_runs "$FAKE_AWS_STATE"
rc=0; cl iamdry --dry-run --run-id testrun1 || rc=$?
check "ACCEPT (H5) the run's roles and profile are found by name through IAM" 0 "$rc" "$WORK/iamdry.log" 'role ubuntu-ami-sample-testrun1-node: owned'
grep -q 'instance profile ubuntu-ami-sample-testrun1-build: owned' "$WORK/iamdry.log"; ok "  ... and the instance profile too" $?
python3 -c 'import json,sys; sys.exit(1 if any("iam:role" in " ".join(json.loads(l)["argv"]) for l in open(sys.argv[1])) else 0)' "$FAKE_AWS_LOG"
ok "  ... and no Resource Groups Tagging API call asks for iam:role (GetResources does not support IAM roles)" $?
st noiam; two_runs "$FAKE_AWS_STATE" no-iam
rc=0; STUB_NS_JSON="$OWN_NS" cl noiam --delete-aws-resources --run-id testrun1 || rc=$?
check "ACCEPT (H5) NoSuchEntity as absent: roles and profile never created, the clean up completes" 0 "$rc" "$WORK/noiam.log" 'Clean up of run testrun1 complete'
grep -q 'role ubuntu-ami-sample-testrun1-build does not exist' "$WORK/noiam.log"; ok "  ... reporting each as absent" $?
st iamdenied; two_runs "$FAKE_AWS_STATE"; export FAKE_AWS_FAIL='iam list-role-tags|ubuntu-ami-sample-testrun1-node|AccessDenied'
rc=0; cl iamdenied --dry-run --run-id testrun1 || rc=$?
check "REJECT (H5) AccessDenied on one role's tags is 'could not determine', never absent" 1 "$rc" "$WORK/iamdenied.log" 'could not determine IAM role ubuntu-ami-sample-testrun1-node'
st foreignrole; two_runs "$FAKE_AWS_STATE" foreign-role
rc=0; STUB_NS_JSON="$OWN_NS" cl foreignrole --delete-aws-resources --run-id testrun1 || rc=$?
check "REJECT (H5) a same-named role another owner tagged: refused, the clean up incomplete" 1 "$rc" "$WORK/foreignrole.log" 'role ubuntu-ami-sample-testrun1-node does not carry ManagedBy=ubuntu-ami-sample and RunId=testrun1; refusing'
[[ " $(remaining) " == *" ubuntu-ami-sample-testrun1-node "* ]]; ok "  ... and that role is still there" $?
st bareprof; two_runs "$FAKE_AWS_STATE" bare-profile
rc=0; STUB_NS_JSON="$OWN_NS" cl bareprof --delete-aws-resources --run-id testrun1 || rc=$?
check "ACCEPT (H5) an instance profile that holds no role (setup stopped before add-role) is still found and deleted" 0 "$rc" "$WORK/bareprof.log" 'Clean up of run testrun1 complete'
[[ " $(remaining) " != *" profile:ubuntu-ami-sample-testrun1-build "* ]]; ok "  ... and it is gone" $?
# H7: each IAM dependency lookup, failed alone, leaves its resource in place and the clean up
# incomplete (exit 1); none is read as "nothing there".
while IFS='@' read -r name rule left rx why; do
  [ -n "$name" ] || continue
  st "$name"; two_runs "$FAKE_AWS_STATE"; export FAKE_AWS_FAIL="$rule"
  rc=0; STUB_NS_JSON="$OWN_NS" cl "$name" --delete-aws-resources --run-id testrun1 || rc=$?
  check "$why" 1 "$rc" "$WORK/$name.log" "$rx"
  lft=$(remaining)
  [[ " $lft " == *" $left "* ]]; ok "  ... $left is left in place" $?
  ! grep -q 'Clean up of run testrun1 complete' "$WORK/$name.log"; ok "  ... and no completion line was printed" $?
done <<'CASES'
h7-profroles@iam get-instance-profile||AccessDenied@profile:ubuntu-ami-sample-testrun1-build@could not determine the roles in instance profile@REJECT (H7) the instance profile's role lookup fails
h7-forrole@iam list-instance-profiles-for-role|ubuntu-ami-sample-testrun1-node|ServiceFailure@ubuntu-ami-sample-testrun1-node@could not determine the instance profiles that hold ubuntu-ami-sample-testrun1-node@REJECT (H7) list-instance-profiles-for-role fails
h7-attached@iam list-attached-role-policies|ubuntu-ami-sample-testrun1-build|AccessDenied@ubuntu-ami-sample-testrun1-build@could not determine the attached policies of ubuntu-ami-sample-testrun1-build@REJECT (H7) list-attached-role-policies fails
h7-inline@iam list-role-policies|ubuntu-ami-sample-testrun1-build|Throttling@ubuntu-ami-sample-testrun1-build@could not determine the inline policies of ubuntu-ami-sample-testrun1-build@REJECT (H7) list-role-policies fails
CASES
st h7-ns; two_runs "$FAKE_AWS_STATE"
rc=0; STUB_NS_ERR=denied cl h7-ns --run-id testrun1 || rc=$?
check "REJECT (H7) a namespace read that fails (Forbidden) is 'could not read', never 'does not exist'" 1 "$rc" "$WORK/h7-ns.log" 'could not read namespace ubuntu-ami-sample \(the read failed, not a report it is absent\)'
! grep -q 'does not exist' "$WORK/h7-ns.log"; ok "  ... and it is not reported absent" $?
st h6-ctx; two_runs "$FAKE_AWS_STATE"
rc=0; STUB_SERVER=https://EXAMPLE9999.yl4.us-west-2.eks.amazonaws.com STUB_NS_JSON="$OWN_NS" cl h6-ctx --delete-aws-resources --run-id testrun1 || rc=$?
check "REJECT (H6) a kube context that is another cluster: clean.sh stops before its first delete" 1 "$rc" "$WORK/h6-ctx.log" "refusing to act on a different cluster"
ok "  ... and nothing was changed" "$( [ "$(calls h6-ctx "$MUTATING")" = 0 ]; echo $?)"
st h6-unset; two_runs "$FAKE_AWS_STATE"
rc=0; KUBE_CONTEXT= STUB_NS_JSON="$OWN_NS" cl h6-unset --run-id testrun1 || rc=$?
check "REJECT (H6) no KUBE_CONTEXT: no fallback to the current context" 1 "$rc" "$WORK/h6-unset.log" 'KUBE_CONTEXT is not set'

echo
echo "== 2c/4 a lost run id: clean.sh --list-runs (H2) ======================================"
st lr; two_runs "$FAKE_AWS_STATE"
rc=0; cl lr --list-runs || rc=$?
check "ACCEPT --list-runs with no run id: every marked resource, grouped by RunId" 0 "$rc" "$WORK/lr.log" 'nothing was deleted'
python3 - "$WORK/lr.log" <<'PY'; ok "  ... both runs, each with its instance, AMI, snapshots, SG, LT, bucket, both roles and node group" $?
import re, sys
text = open(sys.argv[1]).read()
for run in ("testrun1", "testrun2"):
    block = re.search(rf"^run {run}:\n((?:  .*\n)+)", text, re.M).group(1)
    for want in (f"EC2 instance i-{run}-build", f"AMI ami-{run}", f"EBS snapshot snap-{run}-orphan", f"security group sg-{run}",
                 f"launch template lt-{run}", f"S3 bucket ubuntu-ami-sample-stage-{run}-abcdef", f"IAM role ubuntu-ami-sample-{run}-node",
                 f"IAM role ubuntu-ami-sample-{run}-build", f"EKS node group ubuntu-ami-sample-{run}-ng"):
        assert want in block, (run, want, block)
assert "i-someone-else" not in text
PY
ok "  ... and changed nothing" "$( [ "$(calls lr "$MUTATING")" = 0 ]; echo $?)"
st lrfail; two_runs "$FAKE_AWS_STATE"; export FAKE_AWS_FAIL='iam list-roles||AccessDenied'
rc=0; cl lrfail --list-runs || rc=$?
check "REJECT (could not determine) --list-runs whose role listing fails: the list is incomplete" 1 "$rc" "$WORK/lrfail.log" 'could not determine the marked IAM roles'
rc=0; cl lrmix --list-runs --delete-aws-resources || rc=$?
check "REJECT --list-runs with a delete option (it never deletes)" 1 "$rc" "$WORK/lrmix.log" 'takes no other option'
unset FAKE_AWS_FAIL

echo
echo "== 3/4 staging revocation: scripts/00b-stage-bucket.sh revoke (M5) ======================"
stage_state() {
  python3 - "$1" <<'PY'
import json, sys
s = {"account": "111122223333",
     "iam": {"roles": {"ubuntu-ami-sample-testrun1-build": {"Trust": {}, "Tags": [], "Attached": [], "Inline": {"ubuntu-ami-sample-testrun1-stage-read": {}}}}, "profiles": {}},
     "s3": {"buckets": {"ubuntu-ami-sample-stage-testrun1-abcdef": {"owner": "111122223333", "Tags": [], "objects": ["testrun1/a.zip", "testrun1/b.tgz"]}}}}
json.dump(s, open(sys.argv[1], "w"))
PY
}
rv() { local c="$1"; shift; RUN_ID=testrun1 bash "$HERE/00b-stage-bucket.sh" revoke "$@" > "$WORK/$c.log" 2>&1; }
st revok; stage_state "$FAKE_AWS_STATE"
rc=0; rv revok ubuntu-ami-sample-stage-testrun1-abcdef a.zip b.tgz || rc=$?
check "ACCEPT a revocation: objects and the per-run policy deleted and confirmed gone" 0 "$rc" "$WORK/revok.log" 'confirmed: the staged objects are gone'
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if not s["s3"]["buckets"]["ubuntu-ami-sample-stage-testrun1-abcdef"]["objects"] and not s["iam"]["roles"]["ubuntu-ami-sample-testrun1-build"]["Inline"] else 1)' "$FAKE_AWS_STATE"
ok "  ... the state shows no staged object and no staging policy" $?
st revobj; stage_state "$FAKE_AWS_STATE"; export FAKE_AWS_FAIL='s3api delete-object|a.zip|AccessDenied'
rc=0; rv revobj ubuntu-ami-sample-stage-testrun1-abcdef a.zip b.tgz || rc=$?
check "REJECT a revocation whose object delete fails (exit 1, residue recorded)" 1 "$rc" "$WORK/revobj.log" 'staging revocation incomplete'
grep -q 'testrun1/a.zip' "$ISSUE10_RUN_DIR/out/runs/testrun1/stage-residue.txt"; ok "  ... the residue file names the object left behind" $?
! grep -q 'confirmed:' "$WORK/revobj.log"; ok "  ... and no success line was printed" $?
st revpol; stage_state "$FAKE_AWS_STATE"; export FAKE_AWS_FAIL='iam delete-role-policy||AccessDenied'
rc=0; rv revpol ubuntu-ami-sample-stage-testrun1-abcdef a.zip b.tgz || rc=$?
check "REJECT a revocation whose role-policy delete fails" 1 "$rc" "$WORK/revpol.log" 'inline policy ubuntu-ami-sample-testrun1-stage-read on ubuntu-ami-sample-testrun1-build: (delete failed|still present)'
st revconf; stage_state "$FAKE_AWS_STATE"; export FAKE_AWS_FAIL='iam get-role-policy||AccessDenied'
rc=0; rv revconf ubuntu-ami-sample-stage-testrun1-abcdef a.zip b.tgz || rc=$?
check "REJECT a revocation whose policy removal cannot be confirmed" 1 "$rc" "$WORK/revconf.log" 'could not confirm it is gone'
st revother; stage_state "$FAKE_AWS_STATE"
rc=0; rv revother ubuntu-ami-sample-stage-testrun2-abcdef a.zip || rc=$?
check "REJECT revoking with another run's bucket" 1 "$rc" "$WORK/revother.log" "is not this run's staging bucket"
# The guard setup.sh arms right after staging (common.sh arm_staging_revoke): a step that fails
# before the normal revocation still revokes, and the failure's exit status is kept.
guard() { # guard <case> <body run after arming>
  RUN_ID=testrun1 bash -c 'set -euo pipefail; . "$1/lib/common.sh"; derive_run_names
    arm_staging_revoke ubuntu-ami-sample-stage-testrun1-abcdef a.zip b.tgz; eval "$2"' _ "$HERE" "$2" > "$WORK/$1.log" 2>&1
}
st gfail; stage_state "$FAKE_AWS_STATE"
rc=0; guard gfail 'false  # a build step that fails' || rc=$?
check "ACCEPT the guard: a step failing after staging revokes before exiting" 1 "$rc" "$WORK/gfail.log" 'confirmed: the staged objects are gone'
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if not s["s3"]["buckets"]["ubuntu-ami-sample-stage-testrun1-abcdef"]["objects"] and not s["iam"]["roles"]["ubuntu-ami-sample-testrun1-build"]["Inline"] else 1)' "$FAKE_AWS_STATE"
ok "  ... the staged objects and the build role's read are gone, and the failure's exit status (1) is kept" $?
st gdie; stage_state "$FAKE_AWS_STATE"
rc=0; guard gdie 'die "the kernel build failed"' || rc=$?
check "ACCEPT the guard on die as well" 1 "$rc" "$WORK/gdie.log" 'confirmed: the staged objects are gone'
st goff; stage_state "$FAKE_AWS_STATE"
rc=0; guard goff 'disarm_staging_revoke; exit 3' || rc=$?
check "REJECT (nothing to do) once disarmed for the normal revocation: no second revoke" 3 "$rc" "$WORK/goff.log"
[ "$(calls goff 'delete-')" = 0 ]; ok "  ... no delete call was made" $?
st grevfail; stage_state "$FAKE_AWS_STATE"; export FAKE_AWS_FAIL='iam delete-role-policy||AccessDenied'
rc=0; guard grevfail 'false' || rc=$?
check "REJECT a guard revocation that fails: warned, residue recorded, the run still fails" 1 "$rc" "$WORK/grevfail.log" 'staging revocation did not complete'
unset FAKE_AWS_FAIL
python3 - "$SAMPLE/setup.sh" <<'PY'; ok "setup.sh arms the guard on the line after it reads stage.env, and disarms it on the line before the normal revoke" $?
import re, sys
L = [l.strip() for l in open(sys.argv[1]) if l.strip() and not l.strip().startswith("#")]
i = next(n for n, l in enumerate(L) if l == '. "$RUN_STATE_DIR/stage.env"')
assert L[i + 1].startswith("arm_staging_revoke \"$STAGE_BUCKET\""), L[i + 1]
j = next(n for n, l in enumerate(L) if l.startswith('bash "$SAMPLE_DIR/scripts/00b-stage-bucket.sh" revoke'))
assert L[j - 1] == "disarm_staging_revoke", L[j - 1]
assert i < j
PY

echo
echo "== 4/4 derived per-run names: scripts/lib/common.sh derive_run_names =================="
names() { bash -c '. "$1/lib/common.sh" >/dev/null && RUN_ID="$2" && derive_run_names && printf "%s\n" "$BUILD_ROLE_NAME" "$NODE_ROLE_NAME" "$INSTANCE_PROFILE" "$SG_NAME" "$LT_NAME" "$NODEGROUP_NAME" "$STAGE_POLICY_NAME"' _ "$HERE" "$1"; }
rc=0; out=$(names 20261028t221500z 2>&1) || rc=$?
printf '%s\n' "$out" > "$WORK/names.log"
check "ACCEPT the default prefix with a timestamp run id" 0 "$rc" "$WORK/names.log" '^ubuntu-ami-sample-20261028t221500z-ng$'
[ "$(printf '%s\n' "$out" | grep -c 20261028t221500z)" = 7 ]; ok "  ... every derived name carries the run id" $?
rc=0; RESOURCE_PREFIX=a-very-long-resource-prefix-for-this-sample-x names 20261028t221500z > "$WORK/names-long.log" 2>&1 || rc=$?
check "REJECT a prefix that makes a name exceed an API limit" 1 "$rc" "$WORK/names-long.log" 'characters; the limit is (64|63)'
rc=0; RESOURCE_PREFIX=Ubuntu_Sample names 20261028t221500z > "$WORK/names-case.log" 2>&1 || rc=$?
check "REJECT a prefix with characters a bucket name cannot carry" 1 "$rc" "$WORK/names-case.log" 'must be lowercase'
rc=0; names 'Bad-Run' > "$WORK/names-run.log" 2>&1 || rc=$?
check "REJECT a malformed run id" 1 "$rc" "$WORK/names-run.log" 'no valid RUN_ID'

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "run scope proven both ways: per-run names, both tags, exact reuse, run-scoped clean up, confirmed revocation."
