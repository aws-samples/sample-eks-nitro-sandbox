#!/usr/bin/env bash
# test-cleanup-guards.sh: proves two ownership and clean-up guards both ways, with the REAL
# scripts against the fake world of a finished run (scripts/testlib/world_full.py) and the stub
# commands first on PATH:
#   tag-sweep   a sweep member with ManagedBy of the sample but RunId of another run stops the
#               sweep before its first write (E_TAG_SWEEP)
#   test.sh     a helper object that test.sh cannot remove at its end (a drop-in case folder, a
#               filler pod, the probe pod) is a failed check, and test.sh exits non-zero
#
#   examples/setup/cilium-bottlerocket/scripts/test-cleanup-guards.sh
source "$(dirname "$0")/testlib/harness.sh"
HELPER="$SAMPLE_DIR_REAL/scripts/cilium_bottlerocket.py"
TEST="$SAMPLE_DIR_REAL/test.sh"
need_file "$HELPER" "every tag-sweep case" || finish
need_file "$TEST" "every test.sh case" || finish
export CB_WAIT_TRIES=2
RD="$CB_RUN_DIR/runs/r1"
SYS_NODE=ip-10-0-1-10.us-west-2.compute.internal
SBX_NODE=ip-10-0-2-20.us-west-2.compute.internal
full() { # full: the world and the state file of a finished run
  world_reset; rm -rf "$CB_RUN_DIR/runs"; mkdir -p "$RD"; chmod 700 "$RD"
  python3 "$TESTLIB/world_full.py" "$FAKE_STATE" "$RD/state.env"; chmod 600 "$RD/state.env"
  printf 'r1\n' > "$CB_RUN_DIR/current-run"; export RUN_ID=r1
}
# h <log> <subcommand> <args...>: the real helper after common.sh and require_run_id; sets RC.
h() {
  local log="$1"; shift
  run_real "$log" bash -c 'SAMPLE_DIR="$1"; shift; source "$SAMPLE_DIR/scripts/common.sh" || exit 1; require_run_id; python3 "$PY" "$@"' h "$SAMPLE_DIR_REAL" "$@"
}

echo "== 1/2 tag-sweep: a resource of another run is never moved to this run ================"
entry "scripts/cilium_bottlerocket.py:tag-sweep"
# The main route table is a sweep class member. With no tag it is tagged; with this run's tags it
# is left; with ManagedBy of the sample and RunId r2 the sweep stops before any write.
full; world_py 's["ec2"]["route_tables"][0]["Tags"] = []'
h "$WORK/sweep-ok.log" tag-sweep
check "ACCEPT tag-sweep of an untagged sweep member: it is tagged with ManagedBy and RunId of the run" 0 "$RC" "$WORK/sweep-ok.log" \
  '^tagged main-route-table rtb-0fa00000000000001$'
cover accept E_TAG_SWEEP
full; world_py 's["ec2"]["route_tables"][0]["Tags"] = [{"Key": "ManagedBy", "Value": "cilium-bottlerocket-sample"}, {"Key": "RunId", "Value": "r2"}]
s["ec2"]["network_acls"][0]["Tags"] = []'
: > "$FAKE_LOG"
h "$WORK/sweep-r2.log" tag-sweep
check "REJECT tag-sweep when a sweep member has ManagedBy of the sample and RunId r2" 1 "$RC" "$WORK/sweep-r2.log" \
  '^ERROR: E_TAG_SWEEP: main-route-table rtb-0fa00000000000001 carries RunId=r2, not r1; nothing tagged'
[[ "$(count_calls aws 'ec2 create-tags')" == 0 && "$(count_calls aws 'autoscaling create-or-update-tags')" == 0 \
   && "$(count_calls aws 'iam tag-instance-profile')" == 0 ]] \
  && [[ "$(world_get 's["ec2"]["route_tables"][0]["Tags"][1]["Value"]')" == r2 && "$(world_get 'len(s["ec2"]["network_acls"][0]["Tags"])')" == 0 ]]
check "  ... before the first write: no tagging call, RunId r2 is kept, and the untagged network ACL is not tagged either" 0 $? "$WORK/sweep-r2.log"

echo "== 2/2 test.sh: a helper object that it cannot remove is a failure =================="
entry test.sh
# A finished run for test.sh: the world of world_full.py, the two nodes, the state keys of the
# stages after the AMI, and the kubeconfig that setup.sh writes.
tworld() {
  full
  local n g img
  for n in "system:$SYS_NODE:Bottlerocket OS 1.70.0 (aws-k8s-1.36)" "sandbox:$SBX_NODE:Bottlerocket OS 1.70.0 (aws-k8s-1.36-nitro-sandbox)"; do
    IFS=: read -r g n img <<<"$n"
    world_py "s['k8s']['objects']['nodes/-/$n'] = {'apiVersion': 'v1', 'kind': 'Node', 'metadata': {'name': '$n', 'labels': {'eks.amazonaws.com/nodegroup': '$g'}}, 'status': {'conditions': [{'type': 'Ready', 'status': 'True'}], 'nodeInfo': {'osImage': '$img', 'kernelVersion': '6.18.62'}, 'capacity': {'pods': '110'}, 'allocatable': {'pods': '110'}}}"
  done
  # The probe pod answers every command with exit 0 and no output (the node captures are then
  # empty, which test.sh counts as checks that could not run; only the removals matter here).
  world_py "s['k8s']['exec'] = [{'target': 'cb-probe-sandbox-r1', 'match': '', 'stdout': ''}]"
  printf '%s\n' STAGE_DONE=workloads "SYSTEM_NODE=$SYS_NODE" "SANDBOX_NODE=$SBX_NODE" SANDBOX_SLOTS=20 >> "$RD/state.env"
  run_real "$WORK/kubeconfig.log" aws eks update-kubeconfig --name cb-offline-test --kubeconfig "$RD/kubeconfig" --alias cb-r1
  : > "$FAKE_LOG"
}
# t <log> [FAKE_FAIL rule]: the real test.sh; sets RC.
t() { local log="$1"; FAKE_FAIL="${2:-}" run_real "$log" bash "$TEST"; }
# result <log>: "<failed> <total>" of the RESULT line, or "none".
result() {
  sed -nE 's/^RESULT: ([0-9]+) of ([0-9]+) assertion\(s\) FAILED.*/\1 \2/p; s/^RESULT: .*: ([0-9]+)\/\1 assertions passed\.$/0 \1/p' "$1" | tail -n1 | grep . || echo none
}
tworld; t "$WORK/t-ok.log"
read -r base_fail base_total <<<"$(result "$WORK/t-ok.log")"
grep -q '^  \[PASS\] each filler pod is deleted by its exact name, and none is left$' "$WORK/t-ok.log" \
  && grep -q '^  \[PASS\] the probe pod cb-probe-sandbox-r1 is deleted by its exact name, and it is gone$' "$WORK/t-ok.log" \
  && grep -q '^  \[PASS\] the drop-in case folders are removed from /run/cb-probe on the sandbox node$' "$WORK/t-ok.log" \
  && [[ -n "$base_total" && "$base_total" != none ]]
check "ACCEPT test.sh with every helper removal working: the three removals are passing checks (RESULT $base_fail failed of $base_total)" 0 $? "$WORK/t-ok.log"
echo "$base_fail $base_total" > "$WORK/t-base.txt"
# Each case: one removal fails; test.sh counts one more failed check of the same total, and exits non-zero.
i=0
while IFS='#' read -r what rule pat; do
  [[ -n "$what" ]] || continue
  i=$((i + 1)); tworld; t "$WORK/t-case$i.log" "$rule"
  read -r f n <<<"$(result "$WORK/t-case$i.log")"
  printf 'base %s of %s, now %s of %s, exit %s\n' "$base_fail" "$base_total" "$f" "$n" "$RC" > "$WORK/t-case$i.txt"
  [[ "$RC" != 0 && "$f" == "$((base_fail + 1))" && "$n" == "$base_total" ]] && grep -Fqx "  [FAIL] $pat" "$WORK/t-case$i.log"
  check "REJECT test.sh when $what fails: one more failed check of the same total, and a non-zero exit" 0 $? "$WORK/t-case$i.txt"
done <<'CASES'
the delete of a filler pod#kubectl|delete pod|cb-filler-|Timeout#each filler pod is deleted by its exact name, and none is left
the delete of the probe pod#kubectl|delete pod|cb-probe-sandbox-|Timeout#the probe pod cb-probe-sandbox-r1 is deleted by its exact name, and it is gone
the removal of the node scratch folders#kubectl|exec cb-probe-sandbox-r1|rm -rf /host-run-probe/valid|Timeout#the drop-in case folders are removed from /run/cb-probe on the sandbox node
CASES
# The exit trap on its own (the fake world fails other checks, so a whole test.sh run always ends
# non-zero): test.sh's own test_cleanup function, after a run that would end with exit 0, with
# filler pods left that the retry cannot delete, and with filler pods that it deletes.
sed -n '/^test_cleanup() {$/,/^}$/p' "$TEST" > "$WORK/trap.sh"
cat > "$WORK/trap-case.sh" <<'EOF'
kc() { [[ "$KC_RC" == 0 ]]; }
probe_cleanup() { return 0; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
dropin_started=no probe=p RUN_ID=r1 NAMESPACE=ns SANDBOX_NODE=n fillers=(cb-filler-1-r1 cb-filler-2-r1)
source "$1"
trap test_cleanup EXIT
true
EOF
grep -q '^test_cleanup() {$' "$WORK/trap.sh"; check "test.sh has its test_cleanup function" 0 $? "$WORK/trap.sh"
KC_RC=1 run_real "$WORK/trap-left.log" bash "$WORK/trap-case.sh" "$WORK/trap.sh"
check "REJECT an exit 0 whose exit trap cannot delete a filler pod that is left: the exit code becomes 1" 1 "$RC" "$WORK/trap-left.log" \
  '^WARN: could not delete the filler pod cb-filler-1-r1'
KC_RC=0 run_real "$WORK/trap-ok.log" bash "$WORK/trap-case.sh" "$WORK/trap.sh"
check "ACCEPT an exit 0 whose exit trap deletes the filler pods that are left: the exit code stays 0" 0 "$RC" "$WORK/trap-ok.log"
finish
