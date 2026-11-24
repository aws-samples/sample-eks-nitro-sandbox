#!/usr/bin/env bash
# test-prereqs.sh: proves the guards of scripts/common.sh both ways, in the REAL file, sourced
# with the stub commands first on PATH (no AWS account, no cluster). Each reject case matches the
# stable refusal line ^ERROR: E_<TAG>: of its tag:
#   require_tool_versions   E_TOOL_MISSING E_TOOL_AWS E_TOOL_EKSCTL E_TOOL_HELM E_TOOL_KUBECTL E_TOOL_PYYAML
#   require_region          E_REGION (us-west-2 only)
#   require_caller_account  E_ACCOUNT (the STS account equals AWS_ACCOUNT_ID; a failed read stops)
#   read_cilium_version     E_CILIUM_LOCK (the one CILIUM_VERSION line of cilium.lock)
#   on load                 E_SAMPLE_DIR, E_LOCAL_CONFIG, E_RUN_DIR (local state and config only under tmp/)
#   derive_names, load_run  E_NAME, E_RUN_ID
#   state_set, state_get, state_need   E_STATE (absent is empty and 0, unreadable is 2)
#   check_run_record, lock_run         E_RUN_RECORD, E_RUN_LOCK
#   cluster_state, require_sample_cluster, require_kube_context   E_CLUSTER_READ E_CLUSTER_OWNER E_KUBE_CONTEXT
#   tags_match, namespace_is_ours, wait_until   (exit codes 0, 1, 2, 3)
#
#   examples/setup/cilium-bottlerocket/scripts/test-prereqs.sh
source "$(dirname "$0")/testlib/harness.sh"
COMMON="$SAMPLE_DIR_REAL/scripts/common.sh"
need_file "$COMMON" "every scripts/common.sh case" || finish

# t2 <log> '<bash code>': source the REAL common.sh, then run the code; sets RC.
t2() {
  local log="$1" code="$2"
  run_real "$log" bash -c 'SAMPLE_DIR="$1"; source "$SAMPLE_DIR/scripts/common.sh" || exit 1; eval "$2"' t2 "$SAMPLE_DIR_REAL" "$code"
}

echo "== 1/6 tools and versions ======================================================="
world_reset
entry scripts/common.sh:require_tool_versions
t2 "$WORK/tools-ok.log" require_tool_versions
check "ACCEPT the pinned tools: aws 2.x, eksctl 0.232.0, helm v3.19.0, kubectl v1.36.2, python3 with PyYAML" 0 "$RC" "$WORK/tools-ok.log"
cover accept E_TOOL_MISSING E_TOOL_AWS E_TOOL_EKSCTL E_TOOL_HELM E_TOOL_KUBECTL E_TOOL_PYYAML
while IFS='|' read -r var val rx why; do
  [[ -n "$var" ]] || continue
  cloud_guard "$PATH"
  env "$var=$val" bash -c 'SAMPLE_DIR="$1"; source "$SAMPLE_DIR/scripts/common.sh" && require_tool_versions' t2 "$SAMPLE_DIR_REAL" \
    > "$WORK/tools-$var-$val.log" 2>&1 < /dev/null; rc=$?
  check "$why" 1 "$rc" "$WORK/tools-$var-$val.log" "$rx"
done <<'CASES'
FAKE_AWS_VERSION|1.29.0|^ERROR: E_TOOL_AWS: aws CLI v2 is required|REJECT the AWS CLI v1
FAKE_EKSCTL_VERSION|0.229.9|^ERROR: E_TOOL_EKSCTL: eksctl 0\.229\.9 is too old|REJECT eksctl 0.229.9, older than 0.230.0
FAKE_EKSCTL_VERSION|unknown|^ERROR: E_TOOL_EKSCTL: could not read the eksctl version|REJECT an eksctl version that cannot be read
FAKE_HELM_VERSION|v4.3.2+gabcdef0|^ERROR: E_TOOL_HELM: helm v4\.3\.2.* is not v3\.19\.0|REJECT Helm v4.3.2 (the sample pins v3.19.0)
FAKE_HELM_VERSION|v3.19.1+gabcdef0|^ERROR: E_TOOL_HELM: helm v3\.19\.1.* is not v3\.19\.0|REJECT Helm v3.19.1, a different patch release
FAKE_KUBECTL_VERSION|v1.34.4|^ERROR: E_TOOL_KUBECTL: kubectl 1\.34 is outside 1\.35 to 1\.37|REJECT kubectl 1.34, outside the 1.36 skew
FAKE_KUBECTL_VERSION|v1.38.0|^ERROR: E_TOOL_KUBECTL: kubectl 1\.38 is outside 1\.35 to 1\.37|REJECT kubectl 1.38, outside the 1.36 skew
CASES
FAKE_KUBECTL_VERSION=v1.35.0 t2 "$WORK/tools-k135.log" require_tool_versions
check "ACCEPT kubectl 1.35, the lower end of the skew" 0 "$RC" "$WORK/tools-k135.log"
FAKE_KUBECTL_VERSION=v1.37.1 t2 "$WORK/tools-k137.log" require_tool_versions
check "ACCEPT kubectl 1.37, the upper end of the skew" 0 "$RC" "$WORK/tools-k137.log"
for tool in aws eksctl helm kubectl; do
  mv "$WORK/bin/$tool" "$WORK/bin/$tool.off"
  t2 "$WORK/tools-no-$tool.log" require_tool_versions
  check "REJECT a missing $tool" 1 "$RC" "$WORK/tools-no-$tool.log" "^ERROR: E_TOOL_MISSING: $tool is required but was not found on PATH"
  mv "$WORK/bin/$tool.off" "$WORK/bin/$tool"
done
mkdir -p "$WORK/noyaml"; printf 'raise ImportError("PyYAML is not installed in this test")\n' > "$WORK/noyaml/yaml.py"
printf '#!/bin/sh\nPYTHONPATH="%s" exec "%s" "$@"\n' "$WORK/noyaml" "$REAL_PYTHON" > "$WORK/bin/python3"; chmod 0755 "$WORK/bin/python3"
t2 "$WORK/tools-noyaml.log" require_tool_versions
check "REJECT a python3 without PyYAML" 1 "$RC" "$WORK/tools-noyaml.log" '^ERROR: E_TOOL_PYYAML: python3 needs PyYAML'
rm -f "$WORK/bin/python3"

echo "== 2/6 Region and account ======================================================="
entry scripts/common.sh:require_region
t2 "$WORK/region-ok.log" require_region
check "ACCEPT AWS_REGION=us-west-2" 0 "$RC" "$WORK/region-ok.log"
cover accept E_REGION
config_set 'AWS_REGION="us-east-1"'
t2 "$WORK/region-bad.log" require_region
check "REJECT AWS_REGION=us-east-1" 1 "$RC" "$WORK/region-bad.log" '^ERROR: E_REGION: AWS_REGION=us-east-1 is not us-west-2'
world_reset
entry scripts/common.sh:require_caller_account
t2 "$WORK/acct-ok.log" require_caller_account
check "ACCEPT a caller in AWS_ACCOUNT_ID" 0 "$RC" "$WORK/acct-ok.log" '^Caller: arn:aws:sts::'
cover accept E_ACCOUNT
world_py 's["account"] = "2" * 12'
t2 "$WORK/acct-other.log" require_caller_account
check "REJECT a caller in another account" 1 "$RC" "$WORK/acct-other.log" '^ERROR: E_ACCOUNT: the caller is in account [0-9]{12}, not AWS_ACCOUNT_ID='
world_reset
config_set 'AWS_ACCOUNT_ID=""'
t2 "$WORK/acct-empty.log" require_caller_account
check "REJECT the empty AWS_ACCOUNT_ID placeholder" 1 "$RC" "$WORK/acct-empty.log" '^ERROR: E_ACCOUNT: AWS_ACCOUNT_ID is not set'
config_set 'AWS_ACCOUNT_ID="12345"'
t2 "$WORK/acct-short.log" require_caller_account
check "REJECT an AWS_ACCOUNT_ID that is not 12 digits" 1 "$RC" "$WORK/acct-short.log" '^ERROR: E_ACCOUNT: AWS_ACCOUNT_ID is not set'
world_reset
FAKE_FAIL='aws|sts get-caller-identity||ExpiredToken' t2 "$WORK/acct-sts.log" require_caller_account
check "REJECT when STS cannot be read (no credentials, an expired token)" 1 "$RC" "$WORK/acct-sts.log" '^ERROR: E_ACCOUNT: no AWS credentials'

echo "== 3/6 the Cilium lock file =========================================================="
entry scripts/common.sh:read_cilium_version
t2 "$WORK/cv-real.log" 'read_cilium_version "$SAMPLE_DIR/cilium.lock"; read_cilium_chart "$SAMPLE_DIR/cilium.lock"'
check "ACCEPT the tracked cilium.lock: 1.20.5 and the OCI chart" 0 "$RC" "$WORK/cv-real.log" '^1\.20\.5$'
cover accept E_CILIUM_LOCK
mkdir -p "$WORK/locks"
printf '# comment\nCILIUM_VERSION=1.20.5\nCILIUM_CHART=oci://quay.io/cilium/charts/cilium\n' > "$WORK/locks/ok.lock"
printf 'CILIUM_CHART=oci://quay.io/cilium/charts/cilium\n# CILIUM_VERSION=1.20.5\n' > "$WORK/locks/none.lock"
printf 'CILIUM_VERSION=1.20.5\nCILIUM_VERSION=1.20.2\n' > "$WORK/locks/two.lock"
printf 'CILIUM_VERSION=1.20\n' > "$WORK/locks/short.lock"
printf 'CILIUM_VERSION=v1.20.5\n' > "$WORK/locks/vprefix.lock"
printf 'CILIUM_VERSION=1.20.5 # latest\n' > "$WORK/locks/trailing.lock"
printf 'CILIUM_VERSION=1.20.5\n' > "$WORK/locks/nochart.lock"
printf 'CILIUM_VERSION=1.20.5\nCILIUM_CHART=https://helm.cilium.io/\n' > "$WORK/locks/badchart.lock"
t2 "$WORK/cv-ok.log" "read_cilium_version '$WORK/locks/ok.lock'"
check "ACCEPT a lock with a comment and one version line" 0 "$RC" "$WORK/cv-ok.log" '^1\.20\.5$'
while IFS='|' read -r f fn rx why; do
  [[ -n "$f" ]] || continue
  t2 "$WORK/cv-$f.log" "$fn '$WORK/locks/$f.lock'"
  check "$why" 1 "$RC" "$WORK/cv-$f.log" "^ERROR: E_CILIUM_LOCK: .*$rx"
done <<'CASES'
absent|read_cilium_version|the Cilium lock file is missing or unreadable|REJECT a missing lock file
none|read_cilium_version|has no CILIUM_VERSION line|REJECT a lock whose version line is only a comment
two|read_cilium_version|has more than one CILIUM_VERSION line|REJECT a lock with two versions
short|read_cilium_version|has a malformed version line|REJECT a version with no patch number
vprefix|read_cilium_version|has a malformed version line|REJECT a version with a v prefix
trailing|read_cilium_version|has a malformed version line|REJECT a version line with trailing text
nochart|read_cilium_chart|has no CILIUM_CHART line|REJECT a lock with no chart line
badchart|read_cilium_chart|malformed or repeated CILIUM_CHART line|REJECT a chart that is not an oci:// reference
CASES

echo "== 4/6 local paths, names and run IDs ==============================================="
entry scripts/common.sh
t2 "$WORK/rundir-ok.log" 'printf "%s\n" "$CB_RUN_DIR"'
check "ACCEPT SAMPLE_DIR, CB_LOCAL_CONFIG and CB_RUN_DIR under the repository's tmp/" 0 "$RC" "$WORK/rundir-ok.log" "^$CB_RUN_DIR\$"
cover accept E_SAMPLE_DIR E_REPO_ROOT E_LOCAL_CONFIG E_RUN_DIR
run_real "$WORK/nosample.log" bash -c 'unset SAMPLE_DIR; source "$1/scripts/common.sh"' t2 "$SAMPLE_DIR_REAL"
check "REJECT sourcing common.sh without SAMPLE_DIR" 1 "$RC" "$WORK/nosample.log" '^ERROR: E_SAMPLE_DIR: '
[[ "$(grep -c . "$WORK/nosample.log")" == 1 ]]
check "  ... and it stops at that guard: the refusal is the only line" 0 $? "$WORK/nosample.log"
cover reject E_SAMPLE_DIR   # a mutant that prints the refusal but goes on fails this case
# E_REPO_ROOT: git answers no work tree (a stub that fails only rev-parse --show-toplevel), and
# SAMPLE_DIR is /proc/self/cwd, the fixture folder under tmp/ seen from a path with no AGENTS.md
# above it, so the AGENTS.md walk reads /proc/self, /proc and / and finds no root. Nothing is
# written outside the repository.
if [[ -d /proc/self/cwd/ ]]; then
  mkdir -p "$WORK/noroot/sample" "$WORK/noroot/bin"
  cp "$SAMPLE_DIR_REAL/config.env.example" "$WORK/noroot/sample/"
  printf '#!/bin/sh\ncase "$*" in *"rev-parse --show-toplevel"*) echo "fatal: not a git repository" >&2; exit 128 ;; esac\nexec "%s" "$@"\n' \
    "$WORK/sysbin/git" > "$WORK/noroot/bin/git"
  chmod 0755 "$WORK/noroot/bin/git"
  (cd "$WORK/noroot/sample" && PATH="$WORK/noroot/bin:$PATH" run_real "$WORK/noroot.log" \
    bash -c 'SAMPLE_DIR=/proc/self/cwd; source "$1/scripts/common.sh"' t2 "$SAMPLE_DIR_REAL"; exit "$RC")
  check "REJECT a sample folder with no git work tree and no AGENTS.md above it" 1 $? "$WORK/noroot.log" '^ERROR: E_REPO_ROOT: could not find the repository root above /proc/self/cwd$'
else
  not_run "REJECT a sample folder with no git work tree and no AGENTS.md above it" "this host has no /proc/self"
fi
CB_RUN_DIR="$SAMPLE_DIR_REAL/run-state" t2 "$WORK/rundir-sample.log" true
check "REJECT CB_RUN_DIR inside the sample folder" 1 "$RC" "$WORK/rundir-sample.log" '^ERROR: E_RUN_DIR: CB_RUN_DIR=.* is not under '
[[ ! -e "$SAMPLE_DIR_REAL/run-state" ]]
check "  ... and the refused folder is not created" 0 $? "$WORK/rundir-sample.log"
CB_RUN_DIR="$REPO_ROOT_REAL/tmp" t2 "$WORK/rundir-root.log" true
check "REJECT CB_RUN_DIR equal to tmp/ itself" 1 "$RC" "$WORK/rundir-root.log" '^ERROR: E_RUN_DIR: CB_RUN_DIR='
CB_RUN_DIR="$REPO_ROOT_REAL/tmp/../examples/cb-run" t2 "$WORK/rundir-dotdot.log" true
check "REJECT CB_RUN_DIR that climbs out of tmp/ with .." 1 "$RC" "$WORK/rundir-dotdot.log" '^ERROR: E_RUN_DIR: CB_RUN_DIR='
CB_LOCAL_CONFIG="$SAMPLE_DIR_REAL/other.local.env" t2 "$WORK/cfg-outside.log" true
check "REJECT CB_LOCAL_CONFIG in the sample folder under another name than config.local.env" 1 "$RC" "$WORK/cfg-outside.log" '^ERROR: E_LOCAL_CONFIG: '
CB_LOCAL_CONFIG="$REPO_ROOT_REAL/tmp/../cb-outside.env" t2 "$WORK/cfg-dotdot.log" true
check "REJECT CB_LOCAL_CONFIG that climbs out of tmp/ with .." 1 "$RC" "$WORK/cfg-dotdot.log" '^ERROR: E_LOCAL_CONFIG: '
t2 "$WORK/cfg-ok.log" 'printf "%s\n" "$CLUSTER_NAME"'
check "ACCEPT CB_LOCAL_CONFIG under tmp/: its values win over config.env.example" 0 "$RC" "$WORK/cfg-ok.log" '^cb-offline-test$'
entry scripts/common.sh:derive_names
for name in cb-offline-test abc nitro-cilium-bottlerocket; do
  config_set "CLUSTER_NAME=\"$name\""
  RUN_ID=abc123 t2 "$WORK/name-$name.log" derive_names
  check "ACCEPT CLUSTER_NAME=$name" 0 "$RC" "$WORK/name-$name.log"
  cover accept E_NAME E_RUN_ID
done
for name in ab Bad-Name 1starts-with-digit has_underscore a-name-that-is-thirty-three-chars; do
  config_set "CLUSTER_NAME=\"$name\""
  RUN_ID=abc123 t2 "$WORK/name-$name.log" derive_names
  check "REJECT CLUSTER_NAME=$name" 1 "$RC" "$WORK/name-$name.log" '^ERROR: E_NAME: CLUSTER_NAME '
done
entry scripts/common.sh:require_name
n64="$(printf 'r%.0s' $(seq 1 64))"; n65="${n64}r"
t2 "$WORK/nl-64.log" "require_name 'IAM role' '$n64' 64 '^[A-Za-z0-9+=,.@_-]+\$'"
check "ACCEPT an IAM role name of 64 characters, at the IAM limit" 0 "$RC" "$WORK/nl-64.log"
cover accept E_NAME_LIMIT
t2 "$WORK/nl-65.log" "require_name 'IAM role' '$n65' 64 '^[A-Za-z0-9+=,.@_-]+\$'"
check "REJECT an IAM role name of 65 characters, one over the IAM limit" 1 "$RC" "$WORK/nl-65.log" '^ERROR: E_NAME_LIMIT: IAM role name .* is 65 characters; the limit is 64'
t2 "$WORK/nl-chars.log" "require_name 'IAM role' 'role with space' 64 '^[A-Za-z0-9+=,.@_-]+\$'"
check "REJECT an IAM role name with a character IAM refuses" 1 "$RC" "$WORK/nl-chars.log" '^ERROR: E_NAME_LIMIT: IAM role name .* has characters'
config_set "CLUSTER_NAME=\"a$(printf 'b%.0s' $(seq 1 31))\""
RUN_ID="$(printf '9%.0s' $(seq 1 20))" t2 "$WORK/nl-derived.log" 'derive_names; printf "%s %s\n" "${#BUILDER_ROLE_NAME}" "$AMI_NAME"'
check "ACCEPT the longest derived names (32-character cluster, 20-character run ID): the builder role is 61 characters" 0 "$RC" \
  "$WORK/nl-derived.log" '^61 a[b]{31}-9{20}-aws-k8s-1\.36-nitro-sandbox$'
config_set 'CLUSTER_NAME="cb-offline-test"'
world_reset
RUN_ID='' t2 "$WORK/derive-norun.log" 'unset RUN_ID; derive_names'
check "REJECT derive_names with no RUN_ID" 1 "$RC" "$WORK/derive-norun.log" '^ERROR: E_RUN_ID: derive_names: no valid RUN_ID'
entry scripts/common.sh:load_run
for id in abc123 20261120t223000z1a2b; do
  RUN_ID="$id" t2 "$WORK/runid-$id.log" 'load_run && printf "%s\n" "$RUN_STATE_DIR"'
  check "ACCEPT RUN_ID=$id" 0 "$RC" "$WORK/runid-$id.log" "/runs/$id\$"
done
for id in ABC123 run-1 20261120t223000z1a2b3 'a b'; do
  RUN_ID="$id" t2 "$WORK/runid-bad.log" load_run
  check "REJECT RUN_ID='$id'" 1 "$RC" "$WORK/runid-bad.log" "^ERROR: E_RUN_ID: RUN_ID '.*' is not 1 to 20 lowercase letters and digits"
done
printf 'NOT-A-RUN\n' > "$CB_RUN_DIR/current-run"
t2 "$WORK/current-bad.log" 'unset RUN_ID; load_run'
check "REJECT a current-run file that holds no valid run ID" 1 "$RC" "$WORK/current-bad.log" '^ERROR: E_RUN_ID: .*current-run holds no valid run ID'
rm -f "$CB_RUN_DIR/current-run"
t2 "$WORK/norun.log" 'unset RUN_ID; require_run_id'
check "REJECT require_run_id with no RUN_ID and no current run" 1 "$RC" "$WORK/norun.log" '^ERROR: E_RUN_ID: no RUN_ID'

echo "== 5/6 the state file and the run record =============================================="
entry scripts/common.sh:reserve_run
t2 "$WORK/reserve.log" 'reserve_run; state_get RUN_ID; state_get NO_SUCH_KEY; echo "absent-rc=$?"; state_set SANDBOX_AMI_ID ami-0fa1; state_set SANDBOX_AMI_ID ami-0fa2; state_get SANDBOX_AMI_ID; grep -c "^SANDBOX_AMI_ID=" "$RUN_STATE_FILE"; stat -c %a "$RUN_STATE_FILE" "$RUN_STATE_DIR"'
check "ACCEPT reserve_run, then state_get of an absent key: empty and exit 0" 0 "$RC" "$WORK/reserve.log" '^absent-rc=0$'
cover accept E_STATE E_RUN_DIR
grep -qx 'ami-0fa2' "$WORK/reserve.log" && grep -qx '1' "$WORK/reserve.log" && grep -qx '600' "$WORK/reserve.log" && grep -qx '700' "$WORK/reserve.log"
check "  ... state_set keeps one line per key (the last value), the file 600 and the folder 700" 0 $? "$WORK/reserve.log"
rid="$(head -n1 "$CB_RUN_DIR/current-run")"
entry scripts/common.sh:state_set
RUN_ID="$rid" t2 "$WORK/badkey.log" 'set_run_paths; state_set "bad-key" x'
check "REJECT state_set of a key that is not upper case" 1 "$RC" "$WORK/badkey.log" "^ERROR: E_STATE: state_set: bad key 'bad-key'"
RUN_ID="$rid" t2 "$WORK/newline.log" 'set_run_paths; state_set GOOD_KEY "$(printf "a\nb")"'
check "REJECT state_set of a value with a line break" 1 "$RC" "$WORK/newline.log" '^ERROR: E_STATE: state_set: the value of GOOD_KEY has a line break'
t2 "$WORK/noload.log" 'unset RUN_STATE_FILE; state_set GOOD_KEY x'
check "REJECT state_set with no run loaded" 1 "$RC" "$WORK/noload.log" '^ERROR: E_STATE: state_set: no run is loaded'
entry scripts/common.sh:state_get
RUN_ID="$rid" t2 "$WORK/getbad.log" 'set_run_paths; state_get "lower"'
check "REJECT state_get of a key that is not upper case" 1 "$RC" "$WORK/getbad.log" "^ERROR: E_STATE: state_get: bad key 'lower'"
chmod 000 "$CB_RUN_DIR/runs/$rid/state.env"
RUN_ID="$rid" t2 "$WORK/unreadable.log" 'set_run_paths; state_get RUN_ID; echo "rc=$?"'
check "ACCEPT an unreadable state file as exit 2 from state_get (could not determine)" 0 "$RC" "$WORK/unreadable.log" '^rc=2$'
chmod 600 "$CB_RUN_DIR/runs/$rid/state.env"
entry scripts/common.sh:state_need
RUN_ID="$rid" t2 "$WORK/need-absent.log" 'set_run_paths; state_need VPC_ID'
check "REJECT state_need of an absent key" 1 "$RC" "$WORK/need-absent.log" '^ERROR: E_STATE: run .* has no VPC_ID'
entry scripts/common.sh:check_run_record
RUN_ID="$rid" t2 "$WORK/record-ok.log" 'require_run_id; check_run_record'
check "ACCEPT a run record that matches this config" 0 "$RC" "$WORK/record-ok.log"
cover accept E_RUN_RECORD E_RUN_ID
config_set 'CLUSTER_NAME="another-cluster"'
RUN_ID="$rid" t2 "$WORK/record-bad.log" 'require_run_id; check_run_record'
check "REJECT a run record made for another cluster name" 1 "$RC" "$WORK/record-bad.log" "^ERROR: E_RUN_RECORD: run $rid's record has CLUSTER_NAME=cb-offline-test, but this run has CLUSTER_NAME=another-cluster"
world_reset
RUN_ID=nosuchrun t2 "$WORK/nofolder.log" require_run_id
check "REJECT a RUN_ID with no run folder" 1 "$RC" "$WORK/nofolder.log" '^ERROR: E_RUN_ID: run nosuchrun has no folder'
entry scripts/common.sh:lock_run
cloud_guard "$PATH"
RUN_ID="$rid" bash -c 'SAMPLE_DIR="$1"; source "$SAMPLE_DIR/scripts/common.sh"; require_run_id; lock_run; echo locked; sleep 5' t2 "$SAMPLE_DIR_REAL" > "$WORK/lock-holder.log" 2>&1 &
holder=$!
for _ in $(seq 1 50); do grep -q locked "$WORK/lock-holder.log" && break; sleep 0.1; done
RUN_ID="$rid" t2 "$WORK/lock-second.log" 'require_run_id; lock_run'
check "REJECT a second process on a run that another process holds" 1 "$RC" "$WORK/lock-second.log" "^ERROR: E_RUN_LOCK: run $rid is in use"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
RUN_ID="$rid" t2 "$WORK/lock-free.log" 'require_run_id; lock_run'
check "ACCEPT the lock once the other process has ended" 0 "$RC" "$WORK/lock-free.log"
cover accept E_RUN_LOCK

echo "== 6/6 ownership: tags, cluster, namespace, kube context, waits ========================"
entry scripts/common.sh:tags_match
RUN_ID=r1 t2 "$WORK/tm-ok.log" "tags_match <<<'[{\"Key\":\"ManagedBy\",\"Value\":\"cilium-bottlerocket-sample\"},{\"Key\":\"RunId\",\"Value\":\"r1\"}]'"
check "ACCEPT tags ManagedBy=cilium-bottlerocket-sample RunId=r1 for run r1" 0 "$RC" "$WORK/tm-ok.log"
RUN_ID=r1 t2 "$WORK/tm-map.log" "tags_match <<<'{\"ManagedBy\":\"cilium-bottlerocket-sample\",\"RunId\":\"r1\",\"Name\":\"x\"}'"
check "ACCEPT the same tags as a map (the EKS shape)" 0 "$RC" "$WORK/tm-map.log"
RUN_ID=r1 t2 "$WORK/tm-run.log" "tags_match <<<'{\"ManagedBy\":\"cilium-bottlerocket-sample\",\"RunId\":\"r2\"}'"
check "REJECT the sample's tags of another run (exit 1)" 1 "$RC" "$WORK/tm-run.log"
RUN_ID=r1 t2 "$WORK/tm-owner.log" "tags_match <<<'{\"ManagedBy\":\"someone-else\",\"RunId\":\"r1\"}'"
check "REJECT another owner's tag (exit 1)" 1 "$RC" "$WORK/tm-owner.log"
RUN_ID=r1 t2 "$WORK/tm-junk.log" "tags_match <<<'An error occurred (AccessDenied)'"
check "REJECT an answer that is not tags, as unreadable (exit 2)" 2 "$RC" "$WORK/tm-junk.log"
world_reset
entry scripts/common.sh:cluster_state
t2 "$WORK/cs-none.log" cluster_state
check "ACCEPT cluster_state NONE for a cluster that does not exist" 0 "$RC" "$WORK/cs-none.log" '^NONE$'
cover accept E_CLUSTER_READ
FAKE_FAIL='aws|eks describe-cluster||AccessDeniedException' t2 "$WORK/cs-denied.log" cluster_state
check "REJECT a cluster read that fails: it stops, never NONE" 1 "$RC" "$WORK/cs-denied.log" '^ERROR: E_CLUSTER_READ: could not read cluster cb-offline-test'
entry scripts/common.sh:require_sample_cluster
world_py 's["eks"]["clusters"]["cb-offline-test"] = {"status": "ACTIVE", "endpoint": "https://FAKE1.gr7.us-west-2.eks.amazonaws.com", "tags": {"ManagedBy": "cilium-bottlerocket-sample", "RunId": "r1"}}'
RUN_ID=r1 t2 "$WORK/rsc-ok.log" require_sample_cluster
check "ACCEPT require_sample_cluster for this run's cluster" 0 "$RC" "$WORK/rsc-ok.log"
cover accept E_CLUSTER_OWNER E_CLUSTER_READ
RUN_ID=r2 t2 "$WORK/rsc-run.log" require_sample_cluster
check "REJECT require_sample_cluster for a cluster of another run" 1 "$RC" "$WORK/rsc-run.log" '^ERROR: E_CLUSTER_OWNER: cluster cb-offline-test exists but is not tagged'
world_py 's["eks"]["clusters"]["cb-offline-test"]["tags"] = {"team": "other"}'
RUN_ID=r1 t2 "$WORK/rsc-foreign.log" require_sample_cluster
check "REJECT require_sample_cluster for a same-name cluster without the sample's tags" 1 "$RC" "$WORK/rsc-foreign.log" '^ERROR: E_CLUSTER_OWNER: cluster cb-offline-test exists but is not tagged'
FAKE_FAIL='aws|eks describe-cluster||ThrottlingException' RUN_ID=r1 t2 "$WORK/rsc-read.log" require_sample_cluster
check "REJECT require_sample_cluster when the tag read fails" 1 "$RC" "$WORK/rsc-read.log" '^ERROR: E_CLUSTER_READ: could not read the tags of cluster'
# The kube context and the namespace, through the sample's own kubeconfig.
world_reset
world_py 's["eks"]["clusters"]["cb-offline-test"] = {"status": "ACTIVE", "endpoint": "https://FAKE1.gr7.us-west-2.eks.amazonaws.com", "tags": {"ManagedBy": "cilium-bottlerocket-sample", "RunId": "r1"}}'
mkdir -p -m 700 "$CB_RUN_DIR/runs/r1"
write_state "$CB_RUN_DIR/runs/r1/state.env" RUN_ID=r1 CLUSTER_NAME=cb-offline-test AWS_REGION=us-west-2 \
  CLUSTER_ENDPOINT=https://FAKE1.gr7.us-west-2.eks.amazonaws.com
entry scripts/common.sh:require_kube_context
RUN_ID=r1 t2 "$WORK/rkc-none.log" 'require_run_id; require_kube_context'
check "REJECT require_kube_context before the kubeconfig exists" 1 "$RC" "$WORK/rkc-none.log" '^ERROR: E_KUBE_CONTEXT: the kubeconfig .* does not exist'
cloud_guard "$PATH"; aws eks update-kubeconfig --name cb-offline-test --alias cb-r1 --kubeconfig "$CB_RUN_DIR/runs/r1/kubeconfig" > "$WORK/ukc.log" 2>&1
RUN_ID=r1 t2 "$WORK/rkc-ok.log" 'require_run_id; require_kube_context'
check "ACCEPT require_kube_context: context cb-r1 points at the recorded endpoint" 0 "$RC" "$WORK/rkc-ok.log"
cover accept E_KUBE_CONTEXT
printf 'CLUSTER_ENDPOINT=https://OTHER.gr7.us-west-2.eks.amazonaws.com\n' >> "$CB_RUN_DIR/runs/r1/state.env"
RUN_ID=r1 t2 "$WORK/rkc-other.log" 'require_run_id; require_kube_context'
check "REJECT require_kube_context when the context points at another endpoint" 1 "$RC" "$WORK/rkc-other.log" "^ERROR: E_KUBE_CONTEXT: the kubeconfig .* does not hold context cb-r1 for https://OTHER"
sed -i '$d' "$CB_RUN_DIR/runs/r1/state.env"
entry scripts/common.sh:namespace_is_ours
RUN_ID=r1 t2 "$WORK/ns-absent.log" 'require_run_id; namespace_is_ours; echo "rc=$?"'
check "ACCEPT namespace_is_ours exit 3 for an absent namespace" 0 "$RC" "$WORK/ns-absent.log" '^rc=3$'
world_py 's["k8s"]["objects"]["namespaces/-/cilium-bottlerocket-demo"] = {"kind": "Namespace", "metadata": {"name": "cilium-bottlerocket-demo", "labels": {"app.kubernetes.io/part-of": "cilium-bottlerocket-sample"}}}'
RUN_ID=r1 t2 "$WORK/ns-ours.log" 'require_run_id; namespace_is_ours; echo "rc=$?"'
check "ACCEPT namespace_is_ours exit 0 for the labelled namespace" 0 "$RC" "$WORK/ns-ours.log" '^rc=0$'
world_py 's["k8s"]["objects"]["namespaces/-/cilium-bottlerocket-demo"]["metadata"]["labels"] = {"team": "other"}'
RUN_ID=r1 t2 "$WORK/ns-foreign.log" 'require_run_id; namespace_is_ours; echo "rc=$?"'
check "REJECT namespace_is_ours (exit 1) for a same-name namespace without the label" 0 "$RC" "$WORK/ns-foreign.log" '^rc=1$'
FAKE_FAIL='kubectl|get namespace||Forbidden' RUN_ID=r1 t2 "$WORK/ns-fail.log" 'require_run_id; namespace_is_ours; echo "rc=$?"'
check "REJECT namespace_is_ours (exit 2) when the read fails, never absent" 0 "$RC" "$WORK/ns-fail.log" '^rc=2$'
entry scripts/common.sh:wait_until
t2 "$WORK/wait-ok.log" 'n=0; f() { n=$((n+1)); ((n >= 3)); }; wait_until 5 "the third try" f; echo "rc=$?"'
check "ACCEPT wait_until when the condition holds on the third of five tries" 0 "$RC" "$WORK/wait-ok.log" '^rc=0$'
t2 "$WORK/wait-never.log" 'wait_until 3 "a condition that never holds" false; echo "rc=$?"'
check "REJECT wait_until (exit 2, gave up) when the condition never holds" 0 "$RC" "$WORK/wait-never.log" '^rc=2$'
finish
