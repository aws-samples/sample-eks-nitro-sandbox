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
#                                    volumes listed, deleted when unattached and confirmed gone
#                                    (RR-003); --list-runs shows only resources whose tags were read
#                                    and match (RR-005); a role re-tagged before its first change is
#                                    left alone (RR-009); both role tags re-read right before every
#                                    policy detach, inline-policy delete and role delete, so a role
#                                    re-tagged after its first change keeps the rest (RR2-001)
#   3  scripts/00b-stage-bucket.sh   revoke confirms the objects and the policy are gone, or fails
#                                    (M5), and touches nothing unless the bucket, the role and the
#                                    policy are this run's (RR-002), re-read right before each
#                                    object delete and the policy delete; create rolls back on any
#                                    failed step after the bucket exists (RR-004)
#   4  scripts/lib/common.sh         derived names checked against the API name limits (H2); new
#                                    run ids carry entropy and their folder is reserved (RR-006),
#                                    proven with injected entropy, a forced collision included
#                                    (RR2-005)
#   5  setup.sh                      the current-run pointer survives a read-only stop (RR-014)
# Section 1 also proves RR-001: an existing role is validated whole, staging-policy document
# included, before anything is attached.
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
  "get runtimeclass isolated-sandbox -o json")
    echo '{"handler":"isolated-sandbox","scheduling":{"nodeSelector":{"eks.amazonaws.com/nitro-sandbox":"true"}}}' ;;
  "get pods -n kube-system -l k8s-app=kube-dns -o json")
    echo '{"items": [{"metadata": {"name": "coredns-a"}}]}' ;;
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
# after_read <case> <read call> <option> <name> <n>: the "service op" of every call whose <option>
# is <name>, after the n-th <read call> with that <option> <name> (exit 3: fewer than n such reads)
after_read() { python3 -c '
import json, sys
log, read, opt, name, n = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
calls = [json.loads(l) for l in open(log)]
names = lambda a: any(a[i] == opt and a[i + 1] == name for i in range(len(a) - 1))
idx = [i for i, c in enumerate(calls) if c["call"] == read and names(c["argv"])]
if len(idx) < n:
    sys.exit(3)
for c in calls[idx[n - 1] + 1:]:
    if names(c["argv"]):
        print(c["call"])' "$WORK/$1.calls.jsonl" "$2" "$3" "$4" "$5"; }
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

echo "== 1/5 IAM roles and the instance profile: scripts/00a-iam.sh (H1) ===================="
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
refuse_iam extra 'attached managed policies outside the allowlist: arn:aws:iam::aws:policy/AdministratorAccess' "REJECT a reused role with an extra attached managed policy, before any attach (RR-001)"
st inline; iam_state "$FAKE_AWS_STATE" "$OWN" '["ubuntu-ami-sample-testrun1-build"]' '[]' '{"unexpected": {"Version": "2012-10-17"}}' "$TRUST"
refuse_iam inline 'unexpected inline policy: unexpected' "REJECT a reused role with an unexpected inline policy"
# RR-001: the allowed staging-policy NAME is not enough; its document must be this run's read,
# rendered for the bucket this run recorded in stage.env.
STAGE_ENV="$ISSUE10_RUN_DIR/out/runs/testrun1/stage.env"
read_doc() { python3 -c '
import json, sys
t = open(sys.argv[1]).read().replace("@STAGE_BUCKET@", sys.argv[2]).replace("@RUN_ID@", "testrun1")
d = json.loads(t); d.pop("Comment", None); print(json.dumps(d))' "$SAMPLE/deploy/iam-build-host-policy.json" "$1"; }
BROAD='{"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "s3:*", "Resource": "*"}]}'
mkdir -p "$(dirname "$STAGE_ENV")"; printf 'export STAGE_BUCKET=ubuntu-ami-sample-stage-testrun1-abcdef\n' > "$STAGE_ENV"
st broad; iam_state "$FAKE_AWS_STATE" "$OWN" '["ubuntu-ami-sample-testrun1-build"]' '[]' "{\"ubuntu-ami-sample-testrun1-stage-read\": $BROAD}" "$TRUST"
refuse_iam broad 'inline policy ubuntu-ami-sample-testrun1-stage-read is not exactly this run.s staging read' "REJECT (RR-001) s3:* on every resource under the allowed staging-policy name"
st otherbucket; iam_state "$FAKE_AWS_STATE" "$OWN" '["ubuntu-ami-sample-testrun1-build"]' '[]' "{\"ubuntu-ami-sample-testrun1-stage-read\": $(read_doc ubuntu-ami-sample-stage-testrun2-abcdef)}" "$TRUST"
refuse_iam otherbucket 'is not exactly this run.s staging read' "REJECT (RR-001) the staging read rendered for another run's bucket"
st exactdoc; iam_state "$FAKE_AWS_STATE" "$OWN" '["ubuntu-ami-sample-testrun1-build"]' '[]' "{\"ubuntu-ami-sample-testrun1-stage-read\": $(read_doc ubuntu-ami-sample-stage-testrun1-abcdef)}" "$TRUST"
rc=0; iam exactdoc || rc=$?
check "ACCEPT (RR-001) a resumed run whose staging policy is exactly this run's read for its recorded bucket" 0 "$rc" "$WORK/exactdoc.log" 'IAM: PASS'
ok "  ... and it changed nothing" "$( [ "$(calls exactdoc "$MUTATING")" = 0 ]; echo $?)"
rm -f "$STAGE_ENV"
st nostage; iam_state "$FAKE_AWS_STATE" "$OWN" '["ubuntu-ami-sample-testrun1-build"]' '[]' "{\"ubuntu-ami-sample-testrun1-stage-read\": $(read_doc ubuntu-ami-sample-stage-testrun1-abcdef)}" "$TRUST"
refuse_iam nostage 'this run recorded no staging bucket to check its document against' "REJECT (RR-001) a staging policy when this run recorded no bucket to check it against"
st partial; iam_state "$FAKE_AWS_STATE" "$OWN" '["ubuntu-ami-sample-testrun1-build"]' '[]' '{}' "$TRUST"
python3 - "$FAKE_AWS_STATE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["iam"]["roles"]["ubuntu-ami-sample-testrun1-node"]["Attached"].pop()
json.dump(s, open(sys.argv[1], "w"))
PY
rc=0; iam partial || rc=$?
check "ACCEPT a resumed run whose node role lacks one allowed policy: only that one is attached" 0 "$rc" "$WORK/partial.log" 'IAM: PASS'
[ "$(calls partial '^iam attach-role-policy$')" = 1 ]; ok "  ... exactly one attach call" $?
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
echo "== 2/5 run-scoped clean up: clean.sh (H2, L1) ========================================"
# two_runs <file>: resources of run testrun1 and run testrun2, plus one with another ManagedBy
two_runs() {
  python3 - "$1" "$ACCT" "$OTHER_ACCT" "${2:-}" <<'PY'
import json, sys
path, acct, other, variant = sys.argv[1:5]
def tags(run, mb="ubuntu-ami-sample", name=None):
    t = [{"Key": "ManagedBy", "Value": mb}, {"Key": "RunId", "Value": run}]
    return t + ([{"Key": "Name", "Value": name}] if name else [])
s = {"account": acct, "ec2": {"instances": [], "images": [], "snapshots": [], "security_groups": [], "launch_templates": [], "volumes": []},
     "eks": {"nodegroups": {}, "clusters": {"example-cluster": {"endpoint": "https://EXAMPLE0123.gr7.us-west-2.eks.amazonaws.com"}}},
     "iam": {"roles": {}, "profiles": {}}, "s3": {"buckets": {}}}
e = s["ec2"]
for run in ("testrun1", "testrun2"):
    p = f"ubuntu-ami-sample-{run}"
    e["instances"].append({"InstanceId": f"i-{run}-build", "State": {"Name": "running"}, "Tags": tags(run, name=p + "-build")})
    e["volumes"] += [{"VolumeId": f"vol-{run}-root", "State": "in-use", "AttachedTo": f"i-{run}-build", "DeleteOnTermination": True, "Tags": tags(run)},
                     {"VolumeId": f"vol-{run}-data", "State": "in-use", "AttachedTo": f"i-{run}-build", "DeleteOnTermination": False, "Tags": tags(run)},
                     {"VolumeId": f"vol-{run}-left", "State": "available", "Tags": tags(run)}]
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
e["volumes"].append({"VolumeId": "vol-someone-else", "State": "available", "Tags": tags("testrun1", mb="other-sample")})
# same-pattern IAM and EKS names another owner tagged (--list-runs must not show them)
s["iam"]["roles"]["ubuntu-ami-sample-otherx-build"] = {"Trust": {}, "Tags": tags("otherx", mb="someone-else"), "Attached": [], "Inline": {}}
s["iam"]["profiles"]["ubuntu-ami-sample-otherx-build"] = {"Tags": tags("otherx", mb="someone-else"), "Roles": []}
s["eks"]["nodegroups"]["example-cluster/ubuntu-ami-sample-otherx-ng"] = {"status": "ACTIVE", "tags": {"ManagedBy": "someone-else", "RunId": "otherx"}}
if variant == "role-drift":  # run 1's node role is re-tagged for another run after the first tag read
    s["iam"]["roles"]["ubuntu-ami-sample-testrun1-node"]["TagsAfterFirstRead"] = tags("testrun2")
if variant == "late-retag":  # run 1's build role is re-tagged for another run after two tag reads
    s["iam"]["roles"]["ubuntu-ami-sample-testrun1-build"]["TagsAfterReads"] = {"after": 2, "tags": tags("testrun2")}
if variant.startswith("gone-after-"):  # someone else deletes run 1's build role after n tag reads
    s["iam"]["roles"]["ubuntu-ami-sample-testrun1-build"]["GoneAfterReads"] = int(variant.rsplit("-", 1)[1])
if variant == "vol-in-use":  # a volume of run 1 still attached to an instance clean.sh does not terminate
    e["volumes"].append({"VolumeId": "vol-testrun1-stuck", "State": "in-use", "AttachedTo": "i-someone-else", "Tags": tags("testrun1")})
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
    + [x["VolumeId"] for x in e.get("volumes", [])] \
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
grep -qE '^  vol-testrun1-root\s+in-use$' "$WORK/dry.log" && grep -qE '^  vol-testrun1-left\s+available$' "$WORK/dry.log"
ok "  ... and its EBS volumes with their state (RR-003)" $?
! grep -qE 'testrun2|someone-else' "$WORK/dry.log"
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
for want in i-testrun2-build ami-testrun2 snap-testrun2-ami snap-testrun2-orphan sg-testrun2 lt-testrun2 ubuntu-ami-sample-testrun2-node profile:ubuntu-ami-sample-testrun2-build ubuntu-ami-sample-stage-testrun2-abcdef i-someone-else \
            vol-testrun2-root vol-testrun2-left vol-someone-else; do
  [[ " $left " == *" $want "* ]] || { echo "    missing: $want"; false; }
done; ok "  ... and every testrun2 resource, and the other sample's instance, is untouched" $?
python3 - "$FAKE_AWS_LOG" <<'PY'; ok "  ... every S3 call names the expected bucket owner (L1)" $?
import json, sys
s3 = [json.loads(l)["argv"] for l in open(sys.argv[1]) if json.loads(l)["argv"][0] == "s3api"]
assert s3, "no s3 calls"
for a in s3:
    assert "--expected-bucket-owner" in a and a[a.index("--expected-bucket-owner") + 1] == "111122223333", a
PY
python3 - "$FAKE_AWS_LOG" <<'PY'; ok "  ... (RR2-001) each detach, inline-policy delete and role delete comes right after a read of that role's tags, each profile change right after a read of the profile's" $?
import json, sys
calls = [json.loads(l)["argv"] for l in open(sys.argv[1])]
val = lambda a, o: a[a.index(o) + 1] if o in a else None
n = 0
for i, a in enumerate(calls):
    for ops, read, opt in ((("detach-role-policy", "delete-role-policy", "delete-role"), "list-role-tags", "--role-name"),
                           (("remove-role-from-instance-profile", "delete-instance-profile"), "list-instance-profile-tags", "--instance-profile-name")):
        if a[0] == "iam" and a[1] in ops:
            p = calls[i - 1]
            assert p[:2] == ["iam", read] and val(p, opt) == val(a, opt), (a, p)
            n += 1
# build role: one detach, one inline delete, the delete; node role: one detach, the delete;
# the profile: remove the build role, the delete
assert n == 7, n
PY
rm -f "$ISSUE10_RUN_DIR/out/run-state.env"

python3 -c 'import json,sys; c=[json.loads(l)["argv"] for l in open(sys.argv[1])]; d=[a for a in c if a[:2]==["ec2","delete-volume"]]; sys.exit(0 if sorted(a[a.index("--volume-id")+1] for a in d)==["vol-testrun1-data","vol-testrun1-left"] else 1)' "$FAKE_AWS_LOG"
ok "  ... (RR-003) it deleted exactly run testrun1's two available volumes, after its instance was gone (the root volume went with it)" $?
st volstuck; two_runs "$FAKE_AWS_STATE" vol-in-use
rc=0; STUB_NS_JSON='{"metadata": {"labels": {"app.kubernetes.io/part-of": "ubuntu-ami-sample", "app.kubernetes.io/instance": "testrun1"}}}' cl volstuck --delete-aws-resources --run-id testrun1 || rc=$?
check "REJECT (RR-003) a run volume still attached: left in place, the clean up incomplete" 1 "$rc" "$WORK/volstuck.log" 'volume vol-testrun1-stuck is in-use \(still attached\); left in place'
grep -q 'EBS volumes still present after cleanup: vol-testrun1-stuck' "$WORK/volstuck.log"; ok "  ... and the final absence check names it" $?
st voldrift; two_runs "$FAKE_AWS_STATE"
python3 - "$FAKE_AWS_STATE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
v = [x for x in s["ec2"]["volumes"] if x["VolumeId"] == "vol-testrun1-left"][0]
v["RecheckTags"] = [{"Key": "ManagedBy", "Value": "ubuntu-ami-sample"}, {"Key": "RunId", "Value": "testrun2"}]
json.dump(s, open(sys.argv[1], "w"))
PY
rc=0; STUB_NS_JSON='{"metadata": {"labels": {"app.kubernetes.io/part-of": "ubuntu-ami-sample", "app.kubernetes.io/instance": "testrun1"}}}' cl voldrift --delete-aws-resources --run-id testrun1 || rc=$?
check "REJECT (RR-003) deleting a volume whose tags changed since the listing (both re-read first)" 1 "$rc" "$WORK/voldrift.log" 'volume vol-testrun1-left no longer carries'
[[ " $(remaining) " == *" vol-testrun1-left "* ]]; ok "  ... the volume was not deleted" $?

st drift; two_runs "$FAKE_AWS_STATE" drift
rc=0; cl drift --delete-aws-resources --run-id testrun1 || rc=$?
check "REJECT deleting an instance whose tags changed between the listing and the delete (re-check)" 1 "$rc" "$WORK/drift.log" 'instance i-testrun1-build no longer carries'
[[ " $(remaining) " == *" i-testrun1-build "* ]]; ok "  ... the instance was not terminated" $?
st roledrift; two_runs "$FAKE_AWS_STATE" role-drift
rc=0; STUB_NS_JSON='{"metadata": {"labels": {"app.kubernetes.io/part-of": "ubuntu-ami-sample", "app.kubernetes.io/instance": "testrun1"}}}' cl roledrift --delete-aws-resources --run-id testrun1 || rc=$?
check "REJECT (RR-009) a role re-tagged between the listing and its first change: left in place, no policy detached" 1 "$rc" "$WORK/roledrift.log" 'role ubuntu-ami-sample-testrun1-node no longer carries .* no policy detached'
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); r=s["iam"]["roles"]["ubuntu-ami-sample-testrun1-node"]; sys.exit(0 if r["Attached"] else 1)' "$FAKE_AWS_STATE" \
  && [ "$(python3 -c 'import json,sys; print(sum(1 for l in open(sys.argv[1]) if json.loads(l)["argv"][:2]==["iam","detach-role-policy"] and "ubuntu-ami-sample-testrun1-node" in json.loads(l)["argv"]))' "$FAKE_AWS_LOG")" = 0 ]
ok "  ... its managed policy is still attached and no detach call named it" $?
[[ " $(remaining) " != *" ubuntu-ami-sample-testrun1-build "* ]]; ok "  ... while the unchanged build role was removed" $?
# RR2-001: the reviewer's late re-tag. Read 1 of the build role's tags is the listing (iam_state),
# read 2 the re-check right before its first change (the detach of its one managed policy). The
# other owner re-tags it after that read, while the detach is in flight, so every read from read 3
# on returns the new tags (TagsAfterReads after=2): read 3 is the re-check right before the delete
# of its inline staging policy. Nothing may change the role after that.
st latetag; two_runs "$FAKE_AWS_STATE" late-retag
rc=0; STUB_NS_JSON='{"metadata": {"labels": {"app.kubernetes.io/part-of": "ubuntu-ami-sample", "app.kubernetes.io/instance": "testrun1"}}}' cl latetag --delete-aws-resources --run-id testrun1 || rc=$?
check "REJECT (RR2-001) a role re-tagged after its first change: the clean up stops there and is incomplete" 1 "$rc" "$WORK/latetag.log" 'role ubuntu-ami-sample-testrun1-build no longer carries ManagedBy=ubuntu-ami-sample and RunId=testrun1 before deleting inline policy ubuntu-ami-sample-testrun1-stage-read'
out=$(after_read latetag "iam list-role-tags" --role-name ubuntu-ami-sample-testrun1-build 3) && ! printf '%s\n' "$out" | grep -qE "$MUTATING"
ok "  ... no mutating IAM call names the role after read 3, the first that returned the new tags" $?
python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))["iam"]["roles"]["ubuntu-ami-sample-testrun1-build"]
c = [json.loads(l)["argv"] for l in open(sys.argv[2])]
m = [a[1] for a in c if a[0] == "iam" and a[1] in ("detach-role-policy", "delete-role-policy", "delete-role") and "ubuntu-ami-sample-testrun1-build" in a]
sys.exit(0 if m == ["detach-role-policy"] and list(s["Inline"]) == ["ubuntu-ami-sample-testrun1-stage-read"] else 1)' "$FAKE_AWS_STATE" "$FAKE_AWS_LOG"
ok "  ... only the detach made before the re-tag named it: its inline staging policy is still on it and no delete call named it" $?
# RR2-001: a role that disappears after it was listed. Gone from read 2 (before its first change)
# and from read 4 (before delete-role): either way the clean up says so and is incomplete, and no
# change names the role after the read that found it gone.
for g in 1 3; do
  st "rgone$g"; two_runs "$FAKE_AWS_STATE" "gone-after-$g"
  rc=0; STUB_NS_JSON='{"metadata": {"labels": {"app.kubernetes.io/part-of": "ubuntu-ami-sample", "app.kubernetes.io/instance": "testrun1"}}}' cl "rgone$g" --delete-aws-resources --run-id testrun1 || rc=$?
  check "REJECT (RR2-001) a role that disappears after it was listed, at tag read $((g + 1)): the clean up stops and is incomplete" 1 "$rc" "$WORK/rgone$g.log" \
    'role ubuntu-ami-sample-testrun1-build disappeared after it was listed'
  out=$(after_read "rgone$g" "iam list-role-tags" --role-name ubuntu-ami-sample-testrun1-build "$((g + 1))") && ! printf '%s\n' "$out" | grep -qE "$MUTATING"
  ok "  ... no mutating IAM call names the role after the read that found it gone" $?
done

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
echo "== 2b/5 IAM by per-run name, every lookup checked, the kube context: clean.sh (H5, H7, H6) =="
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
echo "== 2c/5 a lost run id: clean.sh --list-runs (H2) ======================================"
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
                 f"IAM role ubuntu-ami-sample-{run}-build", f"EKS node group ubuntu-ami-sample-{run}-ng",
                 f"EBS volume vol-{run}-left", f"IAM instance profile ubuntu-ami-sample-{run}-build"):
        assert want in block, (run, want, block)
# RR-005: same-pattern names another owner tagged, and another sample's resources, are not listed
for bad in ("someone-else", "otherx"):
    assert bad not in text, (bad, text)
PY
ok "  ... and changed nothing" "$( [ "$(calls lr "$MUTATING")" = 0 ]; echo $?)"
st lrfail; two_runs "$FAKE_AWS_STATE"; export FAKE_AWS_FAIL='iam list-roles||AccessDenied'
rc=0; cl lrfail --list-runs || rc=$?
check "REJECT (could not determine) --list-runs whose role listing fails: the list is incomplete" 1 "$rc" "$WORK/lrfail.log" 'could not determine the marked IAM roles'
rc=0; cl lrmix --list-runs --delete-aws-resources || rc=$?
check "REJECT --list-runs with a delete option (it never deletes)" 1 "$rc" "$WORK/lrmix.log" 'takes no other option'
st lrtag; two_runs "$FAKE_AWS_STATE"; export FAKE_AWS_FAIL='iam list-instance-profile-tags|ubuntu-ami-sample-testrun1-build|AccessDenied'
rc=0; cl lrtag --list-runs || rc=$?
check "REJECT (RR-005) --list-runs when one candidate's tags cannot be read: incomplete, and that candidate not listed" 1 "$rc" "$WORK/lrtag.log" 'could not determine the marked IAM instance profile'
! grep -q 'IAM instance profile ubuntu-ami-sample-testrun1-build' "$WORK/lrtag.log"; ok "  ... the unread profile is not shown as run testrun1's" $?
unset FAKE_AWS_FAIL
unset FAKE_AWS_FAIL

echo
echo "== 3/5 staging: scripts/00b-stage-bucket.sh revoke and create (M5, RR-002, RR-004) ======="
# stage_state <file> [variant]: run testrun1's tagged bucket with two staged objects, and its
# tagged build role holding exactly this run's staging read for that bucket.
stage_state() {
  python3 - "$1" "${2:-}" "$(read_doc ubuntu-ami-sample-stage-testrun1-abcdef)" "$(read_doc ubuntu-ami-sample-stage-testrun2-abcdef)" <<'PY'
import json, sys
path, variant, doc, other_doc = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), json.loads(sys.argv[4])
own = [{"Key": "ManagedBy", "Value": "ubuntu-ami-sample"}, {"Key": "RunId", "Value": "testrun1"}]
role = {"Trust": {}, "Tags": list(own), "Attached": [], "Inline": {"ubuntu-ami-sample-testrun1-stage-read": doc}}
bucket = {"owner": "111122223333", "Tags": list(own), "objects": ["testrun1/a.zip", "testrun1/b.tgz"]}
if variant == "bucket-untagged": bucket["Tags"] = []
if variant == "bucket-other-run": bucket["Tags"] = [own[0], {"Key": "RunId", "Value": "testrun2"}]
if variant == "role-untagged": role["Tags"] = []
if variant == "doc-other-bucket": role["Inline"]["ubuntu-ami-sample-testrun1-stage-read"] = other_doc
if variant == "doc-broad": role["Inline"]["ubuntu-ami-sample-testrun1-stage-read"] = {"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "s3:*", "Resource": "*"}]}
if variant == "no-bucket": bucket = None
# another run's tags, set between two reads: from read n + 1 on (bucket) or the second (role)
if variant in ("bucket-late-1", "bucket-late-2"): bucket["TagsAfterReads"] = {"after": int(variant[-1]), "tags": [own[0], {"Key": "RunId", "Value": "testrun2"}]}
if variant == "role-late": role["TagsAfterFirstRead"] = [own[0], {"Key": "RunId", "Value": "testrun2"}]
s = {"account": "111122223333", "iam": {"roles": {"ubuntu-ami-sample-testrun1-build": role}, "profiles": {}},
     "s3": {"buckets": {"ubuntu-ami-sample-stage-testrun1-abcdef": bucket} if bucket else {}}}
json.dump(s, open(path, "w"))
PY
}
unchanged() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); b=s["s3"]["buckets"]["ubuntu-ami-sample-stage-testrun1-abcdef"]; sys.exit(0 if len(b["objects"])==2 and s["iam"]["roles"]["ubuntu-ami-sample-testrun1-build"]["Inline"] else 1)' "$FAKE_AWS_STATE"; }
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
st revconf; stage_state "$FAKE_AWS_STATE"; export FAKE_AWS_FAIL='iam list-role-policies||AccessDenied'
rc=0; rv revconf ubuntu-ami-sample-stage-testrun1-abcdef a.zip b.tgz || rc=$?
check "REJECT a revocation whose policy removal cannot be confirmed" 1 "$rc" "$WORK/revconf.log" 'could not confirm it is gone'
st revother; stage_state "$FAKE_AWS_STATE"
rc=0; rv revother ubuntu-ami-sample-stage-testrun2-abcdef a.zip || rc=$?
check "REJECT revoking with another run's bucket" 1 "$rc" "$WORK/revother.log" "is not this run's staging bucket"
# RR-002: ownership of the bucket and the role, and the policy's content, before any delete. Each
# refusal changes nothing (both objects and the policy are still there). R1-F expected the
# untagged case to succeed; it is now a refusal.
while IFS='@' read -r name variant rule rx why; do
  [ -n "$name" ] || continue
  st "$name"; stage_state "$FAKE_AWS_STATE" "$variant"; [ -z "$rule" ] || export FAKE_AWS_FAIL="$rule"
  rc=0; rv "$name" ubuntu-ami-sample-stage-testrun1-abcdef a.zip b.tgz || rc=$?
  check "$why" 1 "$rc" "$WORK/$name.log" "$rx"
  unchanged && [ "$(calls "$name" 'delete-')" = 0 ]; ok "  ... and nothing was deleted" $?
  unset FAKE_AWS_FAIL
done <<'CASES'
rv-buntag@bucket-untagged@@revoke: could not read the tags of bucket@REJECT (RR-002) an untagged bucket of the run's name (R1-F accepted this)
rv-bother@bucket-other-run@@bucket ubuntu-ami-sample-stage-testrun1-abcdef does not carry ManagedBy=ubuntu-ami-sample and RunId=testrun1@REJECT (RR-002) a bucket tagged for another run
rv-btagerr@@s3api get-bucket-tagging||AccessDenied@could not read the tags of bucket@REJECT (RR-002) when the bucket's tags cannot be read
rv-runtag@role-untagged@@role ubuntu-ami-sample-testrun1-build does not carry@REJECT (RR-002) an untagged build role
rv-rtagerr@@iam list-role-tags||AccessDenied@could not read the tags of role@REJECT (RR-002) when the role's tags cannot be read
rv-docother@doc-other-bucket@@is not this run.s read for s3://ubuntu-ami-sample-stage-testrun1-abcdef/testrun1/@REJECT (RR-002) a staging policy for another run's bucket and prefix
rv-docbroad@doc-broad@@is not this run.s read@REJECT (RR-002) a broad document under the staging-policy name
rv-docerr@@iam get-role-policy||AccessDenied@could not read inline policy@REJECT (RR-002) when the policy document cannot be read
CASES
# RR2-001 pattern in revoke: the bucket's two tags are read again right before each object delete,
# and the role's two tags and the policy document right before the policy delete. Bucket read 1 is
# the ownership check, read 2 the re-check before a.zip, read 3 the one before b.tgz; role read 1
# is the ownership check, read 2 the re-check before the policy delete.
RES="$ISSUE10_RUN_DIR/out/runs/testrun1/stage-residue.txt"
objs() { python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["s3"]["buckets"]["ubuntu-ami-sample-stage-testrun1-abcdef"]["objects"])))' "$FAKE_AWS_STATE"; }
st rv-blate1; stage_state "$FAKE_AWS_STATE" bucket-late-1; rm -f "$RES"
rc=0; rv rv-blate1 ubuntu-ami-sample-stage-testrun1-abcdef a.zip b.tgz || rc=$?
check "REJECT (RR2-001) a bucket re-tagged after its ownership check: no object deleted, residue recorded" 1 "$rc" "$WORK/rv-blate1.log" 'object s3://ubuntu-ami-sample-stage-testrun1-abcdef/testrun1/a.zip: not deleted: bucket ubuntu-ami-sample-stage-testrun1-abcdef does not carry ManagedBy=ubuntu-ami-sample and RunId=testrun1'
out=$(after_read rv-blate1 "s3api get-bucket-tagging" --bucket ubuntu-ami-sample-stage-testrun1-abcdef 2) && [ "$(calls rv-blate1 '^s3api delete-object$')" = 0 ] \
  && [ "$(calls rv-blate1 '^iam delete-role-policy$')" = 0 ] && [ "$(objs)" = "testrun1/a.zip testrun1/b.tgz" ] \
  && grep -q 'testrun1/b.tgz: not deleted' "$RES" && grep -q 'inline policy ubuntu-ami-sample-testrun1-stage-read on ubuntu-ami-sample-testrun1-build: not deleted' "$RES"
ok "  ... no delete-object after the re-tag (none at all), both objects and the policy kept and named in the residue" $?
st rv-blate2; stage_state "$FAKE_AWS_STATE" bucket-late-2; rm -f "$RES"
rc=0; rv rv-blate2 ubuntu-ami-sample-stage-testrun1-abcdef a.zip b.tgz || rc=$?
check "REJECT (RR2-001) a bucket re-tagged after the first object delete: the second is not deleted" 1 "$rc" "$WORK/rv-blate2.log" 'object s3://ubuntu-ami-sample-stage-testrun1-abcdef/testrun1/b.tgz: not deleted: bucket .* does not carry'
out=$(after_read rv-blate2 "s3api get-bucket-tagging" --bucket ubuntu-ami-sample-stage-testrun1-abcdef 3) && ! printf '%s\n' "$out" | grep -qE "$MUTATING" \
  && [ "$(calls rv-blate2 '^s3api delete-object$')" = 1 ] && [ "$(objs)" = "testrun1/b.tgz" ] && grep -q 'testrun1/b.tgz: not deleted' "$RES"
ok "  ... only a.zip, deleted before the re-tag, is gone; no mutating call names the bucket after read 3, the first with the new tags" $?
st rv-rlate; stage_state "$FAKE_AWS_STATE" role-late; rm -f "$RES"
rc=0; rv rv-rlate ubuntu-ami-sample-stage-testrun1-abcdef a.zip b.tgz || rc=$?
check "REJECT (RR2-001) a build role re-tagged after its ownership check: its policy is not deleted, residue recorded" 1 "$rc" "$WORK/rv-rlate.log" 'inline policy ubuntu-ami-sample-testrun1-stage-read on ubuntu-ami-sample-testrun1-build: not deleted: role ubuntu-ami-sample-testrun1-build does not carry'
out=$(after_read rv-rlate "iam list-role-tags" --role-name ubuntu-ami-sample-testrun1-build 2) && ! printf '%s\n' "$out" | grep -qE "$MUTATING" \
  && [ "$(calls rv-rlate '^iam delete-role-policy$')" = 0 ] && grep -q 'stage-read on ubuntu-ami-sample-testrun1-build: not deleted' "$RES" \
  && python3 -c 'import json,sys; sys.exit(0 if list(json.load(open(sys.argv[1]))["iam"]["roles"]["ubuntu-ami-sample-testrun1-build"]["Inline"]) == ["ubuntu-ami-sample-testrun1-stage-read"] else 1)' "$FAKE_AWS_STATE"
ok "  ... no delete-role-policy after the re-tag; the policy is still on the role and named in the residue" $?
rm -f "$RES"

# RR-004: create, and the rollback that runs when any step after the bucket exists fails.
printf 'scripts\n' > "$WORK/stage-a.tgz"; printf 'runtime\n' > "$WORK/stage-b.zip"
cr() { local c="$1"; shift; RUN_ID=testrun1 bash "$HERE/00b-stage-bucket.sh" create "$WORK/stage-a.tgz" "$WORK/stage-b.zip" > "$WORK/$c.log" 2>&1; }
SENV="$ISSUE10_RUN_DIR/out/runs/testrun1/stage.env"
st cr-ok; stage_state "$FAKE_AWS_STATE" no-bucket
python3 - "$FAKE_AWS_STATE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["iam"]["roles"]["ubuntu-ami-sample-testrun1-build"]["Inline"] = {}
json.dump(s, open(sys.argv[1], "w"))
PY
cp "$FAKE_AWS_STATE" "$WORK/cr-base.json"
rc=0; cr cr-ok || rc=$?
check "ACCEPT a create: the bucket is tagged and hardened, both files uploaded, the read granted" 0 "$rc" "$WORK/cr-ok.log" '^STAGE_BUCKET=ubuntu-ami-sample-stage-testrun1-[0-9a-f]{6}$'
python3 - "$FAKE_AWS_STATE" <<'PY'; ok "  ... the state shows exactly that, and the rollback did not run" $?
import json, sys
s = json.load(open(sys.argv[1]))
(name, b), = s["s3"]["buckets"].items()
t = {x["Key"]: x["Value"] for x in b["Tags"]}
assert t["ManagedBy"] == "ubuntu-ami-sample" and t["RunId"] == "testrun1", t
assert sorted(b["objects"]) == ["testrun1/stage-a.tgz", "testrun1/stage-b.zip"], b
assert set(b["config"]) == {"put-public-access-block", "put-bucket-encryption", "put-bucket-policy"}, b
assert list(s["iam"]["roles"]["ubuntu-ami-sample-testrun1-build"]["Inline"]) == ["ubuntu-ami-sample-testrun1-stage-read"]
PY
! grep -q 'staging create failed' "$WORK/cr-ok.log" && [ -s "$SENV" ]; ok "  ... and stage.env records the bucket" $?
while IFS='@' read -r name rule why; do
  [ -n "$name" ] || continue
  st "$name"; cp "$WORK/cr-base.json" "$FAKE_AWS_STATE"; rm -f "$SENV"; export FAKE_AWS_FAIL="$rule"
  rc=0; cr "$name" || rc=$?
  [ "$rc" -ne 0 ]; ok "$why: create fails (rc=$rc)" $?
  python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if not s["s3"]["buckets"] and not s["iam"]["roles"]["ubuntu-ami-sample-testrun1-build"]["Inline"] else 1)' "$FAKE_AWS_STATE" \
    && [ ! -e "$SENV" ] && grep -q 'rollback: removed bucket ubuntu-ami-sample-stage-testrun1-' "$WORK/$name.log"
  ok "  ... and the rollback removed the bucket, every uploaded object, the policy and stage.env" $?
  unset FAKE_AWS_FAIL
done <<'CASES'
cr-tag@s3api put-bucket-tagging||InternalError@REJECT (RR-004) a failed put-bucket-tagging
cr-pab@s3api put-public-access-block||AccessDenied@REJECT (RR-004) a failed put-public-access-block
cr-enc@s3api put-bucket-encryption||AccessDenied@REJECT (RR-004) a failed put-bucket-encryption
cr-pol@s3api put-bucket-policy||MalformedPolicy@REJECT (RR-004) a failed put-bucket-policy
cr-obj1@s3api put-object|stage-a.tgz|InternalError@REJECT (RR-004) a failed first upload
cr-obj2@s3api put-object|stage-b.zip|InternalError@REJECT (RR-004) a failed second upload, after the first one landed
cr-role@iam put-role-policy||AccessDenied@REJECT (RR-004) a failed put-role-policy, after both uploads (the reviewer's probe)
CASES
st cr-rbfail; cp "$WORK/cr-base.json" "$FAKE_AWS_STATE"; rm -f "$SENV"; export FAKE_AWS_FAIL='iam put-role-policy||AccessDenied;s3api delete-object|stage-b.zip|AccessDenied'
rc=0; cr cr-rbfail || rc=$?
[ "$rc" -ne 0 ] && grep -q 'the rollback left: object s3://ubuntu-ami-sample-stage-testrun1-[0-9a-f]*/testrun1/stage-b.zip' "$WORK/cr-rbfail.log" \
  && [ -s "$SENV" ] && grep -q 'stage-b.zip' "$ISSUE10_RUN_DIR/out/runs/testrun1/stage-residue.txt"
ok "REJECT a rollback that cannot delete an object: it says so, keeps the bucket and stage.env for clean.sh, records the residue" $?
unset FAKE_AWS_FAIL; rm -f "$SENV" "$ISSUE10_RUN_DIR/out/runs/testrun1/stage-residue.txt"
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
echo "== 4/5 run ids and derived names: scripts/lib/common.sh (H2, RR-006) ===================="
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
# RR-006, RR2-005: the entropy new_run_id reads is injected, so these cases are deterministic.
# Stubs first on PATH: `od` answers new_run_id's 2-byte read of /dev/urandom with a counter
# (STUB_OD=count) or with the same two bytes every time (STUB_OD='be ef'), and `date` answers its
# timestamp format with one fixed second (any other date call goes to the real date).
ENT="$WORK/entropy"; mkdir -p "$ENT"
printf '%s\n' '#!/bin/bash' \
  '[ "$*" = "-An -N2 -tx1 /dev/urandom" ] || { echo "STUB od: unexpected call: $*" >&2; exit 97; }' \
  'if [ "$STUB_OD" = count ]; then' \
  '  n=$(( $(cat "$STUB_OD_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_OD_COUNT"' \
  '  printf " %02x %02x\n" $((n / 256)) $((n % 256))' \
  'else printf " %s\n" "$STUB_OD"; fi' > "$ENT/od"
printf '%s\n' '#!/bin/bash' \
  '[ "$*" = "-u +%Y%m%dt%H%M%Sz" ] && { echo 20261028t221500z; exit 0; }' \
  "exec $(command -v date) \"\$@\"" > "$ENT/date"
chmod +x "$ENT/od" "$ENT/date"
newids() { # newids <STUB_OD> <n>: n new_run_id calls in one shell, the stubs first on PATH
  PATH="$ENT:$PATH" STUB_OD="$1" STUB_OD_COUNT="$WORK/od.count" bash -c '. "$1/lib/common.sh" >/dev/null; for i in $(seq 1 "$2"); do new_run_id; done' _ "$HERE" "$2"
}
rm -f "$WORK/od.count"; ids=$(newids count 20 2>&1)
printf '%s\n' "$ids" > "$WORK/ids.log"
[ "$(cat "$WORK/od.count")" = 20 ] && [ "$(printf '%s\n' "$ids" | sort -u | wc -l)" = 20 ] && ! printf '%s\n' "$ids" | grep -qvE '^20261028t221500z[0-9a-f]{4}$'
ok "ACCEPT (RR-006, RR2-005) 20 new run ids in one second, each from its own injected 2 bytes, are all different and well formed (20 characters)" $?
real=$(bash -c '. "$1/lib/common.sh" >/dev/null; new_run_id' _ "$HERE" 2>&1)
rc=0; out=$(names "$real" 2>&1) || rc=$?
printf '%s\n%s\n' "$real" "$out" > "$WORK/names-new.log"
[[ "$real" =~ ^[0-9]{8}t[0-9]{6}z[0-9a-f]{4}$ ]] || rc=1
check "  ... and a new id from the real od and date is well formed and keeps every derived name within the IAM, node group and S3 limits" 0 "$rc" "$WORK/names-new.log" '-ng$'
# The collision path, forced: both stubs give the same second and the same 2 bytes, so two starts
# get the same id from new_run_id. The plain-mkdir reservation gives the folder to the first start
# and refuses the second.
reserve() { # reserve <case>: one start, as setup.sh makes it: a new id, its names, its folder
  PATH="$ENT:$PATH" STUB_OD='be ef' bash -c '. "$1/lib/common.sh" >/dev/null && RUN_ID=$(new_run_id) && echo "id $RUN_ID" && derive_run_names && reserve_run_dir && echo reserved' _ "$HERE" > "$WORK/$1.log" 2>&1
}
rc=0; reserve res1 || rc=$?
check "ACCEPT (RR-006, RR2-005) the first start reserves the folder of its new id" 0 "$rc" "$WORK/res1.log" '^reserved$'
rc=0; reserve res2 || rc=$?
check "REJECT (RR-006, RR2-005) a second start that new_run_id gave the same id (same second, same 2 bytes): its reservation is refused" 1 "$rc" "$WORK/res2.log" 'already exists: another run has id 20261028t221500zbeef'
grep -qx 'id 20261028t221500zbeef' "$WORK/res1.log" && grep -qx 'id 20261028t221500zbeef' "$WORK/res2.log" && ! grep -q '^reserved$' "$WORK/res2.log"
ok "  ... both starts got the same id from new_run_id, and only the first reserved it" $?

echo
echo "== 5/5 the current-run pointer: setup.sh (RR-014) ======================================="
# setup.sh run for real, against a fixture lock whose small inputs it verifies like the real
# ones, the fake aws and the stub kubectl. The previous run's pointer must survive any stop
# before the first AWS change, and be replaced right before it.
FX="$ISSUE10_RUN_DIR/runtime"; mkdir -p "$FX"
python3 - "$FX" "$WORK/fixture.lock" <<'PY'
import hashlib, sys, warnings, zipfile
fx, lock = sys.argv[1], sys.argv[2]
sha = lambda b: hashlib.sha256(b).hexdigest()
pay = {"fx-shim": b"fixture shim\n", "fx-image": b"fixture image\n"}
with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    with zipfile.ZipFile(f"{fx}/fixture.zip", "w") as z:
        z.writestr("SHA256SUMS", "".join(f"{sha(b)}  {n}\n" for n, b in sorted(pay.items())))
        for n, b in pay.items():
            z.writestr(n, b)
commit = "0123456789abcdef0123456789abcdef01234567"
files = {"linux-fixture.tar.xz": b"kernel fixture\n", "erofs-utils-fixture.tar.gz": b"erofs fixture\n",
         f"{commit}.patch": f"From {commit} Mon Sep 17 00:00:00 2001\nSubject: [PATCH] fixture\n".encode()}
for n, b in files.items():
    open(f"{fx}/{n}", "wb").write(b)
blocks = [
    dict(id="runtime-archive", kind="file", ref="fixture", file="fixture.zip", source="operator-supplied fixture",
         sha256=sha(open(f"{fx}/fixture.zip", "rb").read()), status="operator-supplied"),
    *[dict(id=f"runtime-payload-{n}", kind="runtime-payload", archive="runtime-archive", ref="fixture", file=n,
           source="member of runtime-archive", sha256=sha(b), install="none", status="operator-supplied") for n, b in pay.items()],
    dict(id="linux-kernel-source", kind="file", ref="fixture", source="https://example.invalid/linux-fixture.tar.xz",
         sha256=sha(files["linux-fixture.tar.xz"]), status="available"),
    dict(id="host-kernel-patch", kind="file", ref=commit, file=f"{commit}.patch", source=f"https://example.invalid/{commit}.patch",
         sha256=sha(files[f"{commit}.patch"]), subject="fixture", status="available"),
    dict(id="erofs-utils-source", kind="file", ref="fixture", source="https://example.invalid/erofs-utils-fixture.tar.gz",
         sha256=sha(files["erofs-utils-fixture.tar.gz"]), status="available"),
]
open(lock, "w").write("\n".join("".join(f"{k}={v}\n" for k, v in b.items()) for b in blocks))
PY
POINTER="$ISSUE10_RUN_DIR/out/run-state.env"
su() { # su <case>: run the real setup.sh with a previous run recorded as the current one
  mkdir -p "$(dirname "$POINTER")"; printf 'RUN_ID=oldrun1\n' > "$POINTER"
  env -u RUN_ID LOCK_FILE="$WORK/fixture.lock" RUNTIME_ARTIFACT_FILE=fixture.zip BUILD_SUBNET_ID=subnet-0example1 \
    NODE_SUBNET_IDS=subnet-0example2 bash "$SAMPLE/setup.sh" > "$WORK/$1.log" 2>&1
}
su_state() { # su_state <with-vpc-cni: yes|no>
  python3 - "$FAKE_AWS_STATE" "$1" <<'PY'
import json, sys
s = {"account": "111122223333", "eks": {"clusters": {"example-cluster": {"endpoint": "https://EXAMPLE0123.gr7.us-west-2.eks.amazonaws.com"}}}}
if sys.argv[2] == "yes":
    s["eks"]["addons"] = {"example-cluster/vpc-cni": {"status": "ACTIVE", "addonVersion": "v1.0.0-eksbuild.1", "configurationValues": "{\"enableNetworkPolicy\":\"true\"}"}}
json.dump(s, open(sys.argv[1], "w"))
PY
}
st su-cni; su_state no
rc=0; su su-cni || rc=$?
check "REJECT setup.sh on a cluster without the vpc-cni add-on (the known missing prerequisite)" 1 "$rc" "$WORK/su-cni.log" 'PREREQUISITE NOT MET: cluster example-cluster has no managed vpc-cni add-on'
grep -q 'all pinned public inputs verified' "$WORK/su-cni.log"; ok "  ... after it verified the fixture inputs (the stop is the cluster check, not the inputs)" $?
[ "$(cat "$POINTER")" = "RUN_ID=oldrun1" ]; ok "  ... and the previous run's pointer survives (RR-014)" $?
ok "  ... and it made no AWS change" "$( [ "$(calls su-cni "$MUTATING")" = 0 ]; echo $?)"
st su-iam; su_state yes; export FAKE_AWS_FAIL='iam get-role||AccessDenied'
rc=0; su su-iam || rc=$?
new=$(sed -n 's/.*current run is now \([a-z0-9]*\) .*/\1/p' "$WORK/su-iam.log" | head -n 1)
check "ACCEPT: with every read-only check passed, the run becomes current just before its first AWS step (which then fails here)" 1 "$rc" "$WORK/su-iam.log" 'could not determine IAM role'
[[ "$new" =~ ^[0-9]{8}t[0-9]{6}z[0-9a-f]{4}$ ]] && [ "$(cat "$POINTER")" = "RUN_ID=$new" ] && [ -d "$ISSUE10_RUN_DIR/out/runs/$new" ]
ok "  ... the pointer now names the new run ($new), whose folder was reserved" $?
unset FAKE_AWS_FAIL

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "run scope proven both ways: per-run names, both tags, exact reuse, run-scoped clean up, confirmed revocation."
