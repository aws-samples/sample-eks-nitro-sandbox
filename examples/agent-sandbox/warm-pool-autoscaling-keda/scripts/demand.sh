#!/usr/bin/env bash
# Drive claim demand from 0 up to MAX_CLAIMS and back to 0, and read the pool's
# scaling decision at each stage.
#
#   ./scripts/demand.sh
#
# WHAT IS ASSERTED, AND WHY IT IS NOT VACUOUS.
# Every assertion is on SandboxWarmPool .spec.replicas, the field the
# KEDA-created HPA writes through the pool's /scale subresource. Asserting on
# that field, rather than on how fast a claim was served or on how much capacity
# happened to be ready, tells "KEDA scaled the pool from demand" apart from:
#
#   * a pool that was simply big enough -- its spec.replicas never changes;
#     this one moves up and back down.
#   * the pool replenishing itself -- refilling a pod a claim consumed brings
#     status.readyReplicas back up to spec.replicas WITHOUT changing
#     spec.replicas, and needs no autoscaler at all.
#   * a capacity artifact, a pod pending or evicted -- that shows in
#     status.readyReplicas, the outcome, never in spec.replicas, the decision.
#   * the cluster adding nodes -- a different axis entirely; nothing that
#     provisions nodes writes SandboxWarmPool.spec.replicas.
#
# status.readyReplicas is printed at every stage beside spec.replicas, so the
# decision and the outcome can be read separately and never confused.
#
# ./scripts/control-no-autoscaler.sh is the other half: the same demand with the
# ScaledObject removed, where spec.replicas stays flat. Together they show the
# movement asserted here cannot be explained without KEDA.
#
# It leaves the sample up with no claims, ready to run again.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

# One failed assertion must not stop the stages after it: the trajectory is only
# readable in full. assert_summary owns the exit code.
set +e

require_commands kubectl python3 sed grep tr
show_context
require_our_namespace

resource_exists kc "sandboxwarmpool/$POOL" >/dev/null \
  || die "sandboxwarmpool/$POOL is not in namespace $NAMESPACE; run ./scripts/setup.sh first"

step "1/5 precondition: the HPA KEDA created targets the SandboxWarmPool"
# Tell "there is no such HPA" apart from "the list could not be read", so the
# line below never says the first when it means the second.
hpa_rc=0
hpa="$(hpa_for_pool)" || hpa_rc=$?
if [[ $hpa_rc -ne 0 ]]; then
  hpa=""
  echo "  HPA whose scaleTargetRef names $POOL: <could not read>"
else
  echo "  HPA whose scaleTargetRef names $POOL: ${hpa:-<none>}"
fi
# One name, not several: hpa_for_pool separates multiple matches with a newline,
# and "two HPAs target the pool" must not satisfy "an HPA targets the pool".
[[ -n "$hpa" && "$hpa" != *$'\n'* ]]
assert $? "an HPA targets sandboxwarmpool/$POOL, so its replica count is driven rather than fixed"

target_kind="$(kc get hpa "$hpa" -o jsonpath='{.spec.scaleTargetRef.kind}' 2>/dev/null)"
owner="$(kc get hpa "$hpa" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="ScaledObject")].name}' 2>/dev/null)"
echo "  scaleTargetRef.kind=$target_kind   ownerReferences[kind=ScaledObject].name=${owner:-<none>}"
[[ "$target_kind" == "SandboxWarmPool" ]]
assert $? "the HPA's scaleTargetRef.kind is SandboxWarmPool: it scales the pool itself, not a Deployment"
[[ "$owner" == "$SCALEDOBJECT" ]]
assert $? "the HPA is owned by scaledobject/$SCALEDOBJECT, so KEDA created it and KEDA owns the scaling"

so_min="$(kc get scaledobject "$SCALEDOBJECT" -o jsonpath='{.spec.minReplicaCount}' 2>/dev/null)"
so_max="$(kc get scaledobject "$SCALEDOBJECT" -o jsonpath='{.spec.maxReplicaCount}' 2>/dev/null)"
echo "  ScaledObject bounds: minReplicaCount=$so_min maxReplicaCount=$so_max   (load generator cap: $MAX_CLAIMS claims)"
# Both bounds must be numbers before anything is measured against them. An empty
# one goes into the expression wait_spec_replicas evals as a missing operand,
# which is a syntax error on every poll, so the run would sit through 300s and
# then 420s of waiting before failing for a reason the output would not name.
[[ "$so_min" =~ ^[0-9]+$ && "$so_max" =~ ^[0-9]+$ ]] \
  || die "could not read minReplicaCount/maxReplicaCount from scaledobject/$SCALEDOBJECT (got '$so_min'/'$so_max'); stopping rather than measure against bounds I do not know"

# The /scale subresource is what lets an HPA drive the pool at all. Read it, so
# the page shows the field the HPA writes rather than asserting it exists.
echo "  the pool's /scale subresource:"
kc_cluster get --raw \
  "/apis/extensions.agents.x-k8s.io/v1beta1/namespaces/$NAMESPACE/sandboxwarmpools/$POOL/scale" \
  2>/dev/null | sed 's/^/    /'
echo

step "2/5 baseline: no demand, the pool holds the warm floor"
# Start from a clean demand floor so the baseline is a real reading, not whatever
# an interrupted run left behind. The claims must be GONE, not merely accepted
# for deletion: step 3/5 creates one with `create` and reads its timestamps, and
# a claim still terminating would make that creation fail or, worse, make the
# readings describe the old claim.
delete_claims || true
claims_gone=0
wait_claims_gone 180 || claims_gone=$?
[[ $claims_gone -eq 0 ]]
assert $? "no demand claim of this sample's is left on the cluster, so stage 3/5 reads a claim this run created"
wait_spec_replicas "\$v -le $so_min" 300
wait_pool_warm 900 >/dev/null
baseline="$(pool_spec_replicas)" || baseline="?"
baseline_claims="$(claim_count)" || baseline_claims="?"
print_stage "baseline"
# The baseline must be a real number: every comparison in stages 4/5 and 5/5 is
# measured against it.
#
# What an unreadable baseline actually does, since this is easy to state wrongly
# and two earlier versions of this comment did. "?" carried into -gt or -lt is
# NOT read as 0: inside [[ ]] those operands go through arithmetic evaluation,
# and "?" is not a valid name, so bash prints
# `[[: ?: syntax error: operand expected` and the test is FALSE. The comparison
# fails closed rather than passing on nothing. (Nor would an unset NAME be 0
# here: these scripts run under set -u, where `[[ foo -gt 0 ]]` on an unset foo
# aborts with "foo: unbound variable".)
#
# So the guard is not what keeps a bad baseline from passing a check. What it is
# for: it stops with a message that names the problem, instead of letting the run
# carry on and emit a raw bash syntax error from the middle of a stage; and it
# keeps "?" out of the expression wait_spec_replicas builds and evals in stages
# 4/5 and 5/5, where it would be a syntax error on every poll, so the wait could
# never be satisfied and would burn its full 300s and 420s before failing.
[[ "$baseline" =~ ^[0-9]+$ && "$baseline" == "$so_min" && "$baseline_claims" == "0" ]]
assert $? "baseline: 0 claims and spec.replicas=$baseline, the floor (minReplicaCount=$so_min)"
[[ "$baseline" =~ ^[0-9]+$ ]] \
  || die "the baseline spec.replicas could not be read, so nothing after this could be measured against it; stopping rather than report movement I did not measure"

step "3/5 one claim adopts a pre-booted pod, and it is a sandbox"
# The point of a warm pool: the claim is handed a pod that is ALREADY RUNNING, so
# it is usable at once instead of paying a cold start.
#
# How this is measured, and one way it must NOT be. The claim's own Ready
# condition looks like the obvious source, but its lastTransitionTime is
# inherited from the Sandbox the claim adopted, and that Sandbox became Ready
# when the pool booted it, which is BEFORE the claim existed. On this sample's
# runs that puts the condition's timestamp tens of seconds earlier than the
# claim's creationTimestamp, so any "Ready minus created" arithmetic on it comes
# out negative and would satisfy an "under a second" test without measuring
# anything. So the adoption is measured two other ways instead:
#
#   * by value from the API: the pod's creationTimestamp against the claim's. A
#     pod that was created before the claim existed cannot have been created for
#     it, which is what adoption means and what a cold start can never show.
#   * client side: how long `kubectl wait --for=condition=Ready` takes once the
#     claim object exists. That is one kubectl round trip, so it is an upper
#     bound on the wait, not a lower one.
# `create`, not `apply`: a claim of this name left by an earlier run would be
# quietly updated by an apply, and every reading below would then describe that
# old claim. Stage 2/5 has already asserted none is left.
t_apply_start="$(python3 -c 'import time; print(time.time())')"
create_rc=0
create_claim_fresh 1 || create_rc=$?
t_apply_done="$(python3 -c 'import time; print(time.time())')"
[[ $create_rc -eq 0 ]]
assert $? "claim ${CLAIM_PREFIX}-1 was created by this run (kubectl create, so an existing claim of that name would have failed here)"
# Keep kubectl wait's own status: without it, a wait that fails fast, because the
# claim does not exist or the API refused it, leaves a sub-second measurement that
# would satisfy the "under a second" check having waited for nothing.
wait_rc=0
kc wait "sandboxclaim/${CLAIM_PREFIX}-1" --for=condition=Ready --timeout=120s || wait_rc=$?
t_ready="$(python3 -c 'import time; print(time.time())')"
wait_secs="$(python3 -c "print('%.3f' % (${t_ready} - ${t_apply_done}))")"
wall_secs="$(python3 -c "print('%.3f' % (${t_ready} - ${t_apply_start}))")"

pod="$(kc get "sandboxclaim/${CLAIM_PREFIX}-1" -o jsonpath='{.status.sandbox.name}' 2>/dev/null)"
launch_type="$(kc get "sandbox/$pod" -o jsonpath='{.metadata.labels.agents\.x-k8s\.io/launch-type}' 2>/dev/null)"
claim_created="$(kc get "sandboxclaim/${CLAIM_PREFIX}-1" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"
pod_created="$(kc get "pod/$pod" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"
# How many seconds the pod had already been running when the claim was created.
# Positive means the pod predates the claim: it was adopted, not created for it.
preboot="$(python3 -c "
import datetime, sys
def parse(s):
    return datetime.datetime.strptime(s, '%Y-%m-%dT%H:%M:%SZ')
try:
    print('%d' % (parse('$claim_created') - parse('$pod_created')).total_seconds())
except Exception:
    print('?')
")"
echo "  claim ${CLAIM_PREFIX}-1 -> sandbox/$pod   launch-type=${launch_type:-<none>}"
echo "  pod created   $pod_created"
echo "  claim created $claim_created"
echo "  so the pod had already been booted and Ready for ${preboot}s when the claim was created"
echo "  kubectl wait for the claim to report Ready, once the claim existed: ${wait_secs}s (kubectl wait exit ${wait_rc})"
echo "  (create and wait together, including both kubectl round trips: ${wall_secs}s)"
[[ "$launch_type" == "warm" ]]
assert $? "the claim adopted a pre-booted pod from the pool (sandbox label launch-type=warm), not a cold-created one"
[[ "$preboot" =~ ^[0-9]+$ && "$preboot" -gt 0 ]]
assert $? "the pod was created ${preboot}s before the claim existed, so it was adopted, not created for the claim"
# Under a second, measured client side with one kubectl round trip in it. A cold
# start is about 5 to 6 seconds on a warm node, so this also separates the two.
# The wait must have SUCCEEDED, and the measurement must be positive: a wait that
# failed fast, or a clock that stepped backwards, must not read as "sub-second".
if [[ $wait_rc -eq 0 ]]; then
  python3 -c "import sys; sys.exit(0 if 0.0 < $wait_secs < 1.0 else 1)"
else
  false
fi
assert $? "the claim reported Ready ${wait_secs}s after it existed: under a second, where a cold start is about 5 to 6"

# The three signals that show the adopted pod ran in a sandbox of its own, each
# read again from the exporter pod, which is an ordinary pod on this cluster.
exporter_pod="$(kc get pods -l app.kubernetes.io/name=claim-exporter \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
echo
echo "  the claimed pod ($pod), in a sandbox:"
echo "    uname -rv                        -> $(kc exec "$pod" -- uname -rv 2>/dev/null)"
echo "    cat /proc/uptime                 -> $(kc exec "$pod" -- cat /proc/uptime 2>/dev/null)"
echo "    ls /sys/block                    -> $(kc exec "$pod" -- ls /sys/block 2>/dev/null | tr '\n' ' ')"
echo "    cat /sys/class/dmi/id/product_name -> $(kc exec "$pod" -- cat /sys/class/dmi/id/product_name 2>/dev/null)"
echo "  the exporter pod ($exporter_pod), an ordinary pod:"
echo "    uname -rv                        -> $(kc exec "$exporter_pod" -- uname -rv 2>/dev/null)"
echo "    cat /proc/uptime                 -> $(kc exec "$exporter_pod" -- cat /proc/uptime 2>/dev/null)"
echo "    ls /sys/block                    -> $(kc exec "$exporter_pod" -- ls /sys/block 2>/dev/null | tr '\n' ' ')"
echo "    cat /sys/class/dmi/id/product_name -> $(kc exec "$exporter_pod" -- cat /sys/class/dmi/id/product_name 2>/dev/null)"

echo
echo "  the claimed pod is network-isolated, so there is no network to restrict:"
# exec itself must work before a failed request can mean anything. Without this,
# any reason exec could not run, an empty pod name included, would read as "the
# pod has no network", which is the opposite of a measurement.
exec_rc=0
kc exec "$pod" -- true >/dev/null 2>&1 || exec_rc=$?
[[ $exec_rc -eq 0 ]]
assert $? "kubectl exec into the claimed pod works, so the readings below are the pod's answers"

# The two readings that settle it, asserted rather than just printed. A failed
# request is NOT evidence on its own: busybox wget prints "bad address" for any
# failed name lookup, which a pod that HAS a network also does when its DNS is
# blocked, so a check that accepted that message would accept a networked pod.
# What cannot be faked is the interface list and the routing table.
#
# BOTH address families, deliberately. `ip -4` and a v4-only route check would
# say nothing about IPv6, so a guest reachable only over v6 would satisfy them
# while the assertion below claimed it had no network at all. `ip -o addr show`
# lists every family, and the route reading asks for the v4 and the v6 default
# separately.
echo "  \$ kubectl exec $pod -- ip -o addr show"
addr_out="$(kc exec "$pod" -- ip -o addr show 2>&1)"
addr_rc=$?
printf '%s\n' "$addr_out" | sed 's/^/    /'
# Every address line must be on lo, in any family. A guest with a network has an
# eth0 line here. The here-string rather than a pipe into grep: under pipefail a
# `grep -q` that exits on its first match can leave the pipeline reporting the
# SIGPIPE it sent the writer, and `!` would turn that into a pass.
if [[ $addr_rc -eq 0 && -n "$addr_out" ]] \
   && ! grep -qvE '^[0-9]+:[[:space:]]+lo[[:space:]]' <<<"$addr_out"; then
  true
else
  false
fi
assert $? "the only interface with an address in the claimed pod is loopback, in either address family: there is no network interface to carry traffic"

# One echo per command, each above its own answer, so the transcript cannot read
# as though the second `ip` ran on this machine rather than in the pod. Each
# answer is printed only when there is one, and with a newline, so the failing
# case does not run its route onto the next line.
echo "  \$ kubectl exec $pod -- ip route show default         # prints nothing: no IPv4 default route"
route_out="$(kc exec "$pod" -- ip route show default 2>&1)"
route_rc=$?
[[ -n "$route_out" ]] && printf '%s\n' "$route_out" | sed 's/^/    /'
echo "  \$ kubectl exec $pod -- ip -6 route show default      # prints nothing: no IPv6 default route"
route6_out="$(kc exec "$pod" -- ip -6 route show default 2>&1)"
route6_rc=$?
[[ -n "$route6_out" ]] && printf '%s\n' "$route6_out" | sed 's/^/    /'
[[ $route_rc -eq 0 && -z "$route_out" && $route6_rc -eq 0 && -z "$route6_out" ]]
assert $? "the claimed pod has no default route for IPv4 and none for IPv6, so nothing would know where to send a packet"

echo "  \$ kubectl exec $pod -- wget -T 5 -O /dev/null https://aws.amazon.com"
wget_out="$(kc exec "$pod" -- wget -T 5 -O /dev/null https://aws.amazon.com 2>&1)"
wget_rc=$?
printf '%s\n' "$wget_out" | sed 's/^/    /'
# Corroboration, not the proof: the request must at least fail, and fail in a way
# consistent with having no network rather than with having reached something.
[[ $exec_rc -eq 0 && $wget_rc -ne 0 && "$wget_out" =~ (bad[[:space:]]address|Network[[:space:]]is[[:space:]]unreachable|Host[[:space:]]is[[:space:]]unreachable) ]]
assert $? "a request out of the claimed pod fails the way a pod with no network fails, rather than reaching anything"

step "4/5 drive demand UP to $MAX_CLAIMS claims"
# demand-1 is already there from stage 3/5, so this creates the rest.
make_rc=0
make_claims "$MAX_CLAIMS" || make_rc=$?
up_claims="$(claim_count)" || up_claims="?"
echo "  claims now: $up_claims"
[[ $make_rc -eq 0 && "$up_claims" == "$MAX_CLAIMS" ]]
assert $? "the demand is $MAX_CLAIMS claims, so the metric KEDA reads should ask for $MAX_CLAIMS warm pods"
wait_exporter_metric "$MAX_CLAIMS" 120
# Wait for the DECISION to move, then print the OUTCOME beside it.
wait_spec_replicas "\$v -gt $baseline" 300
loaded="$(pool_spec_replicas)"; loaded="${loaded:-?}"
echo "  exporter is serving: $(exporter_metric)"
print_stage "under load"
[[ "$loaded" != "?" && "$loaded" -gt "$baseline" ]]
assert $? "under load KEDA raised spec.replicas from $baseline to $loaded: the scale-up decision"
[[ "$loaded" == "$so_max" ]]
assert $? "spec.replicas reached maxReplicaCount=$so_max, matching $MAX_CLAIMS claims at targetValue 1"
echo "  hpa/$hpa: $(kc get hpa "$hpa" --no-headers 2>/dev/null)"

step "5/5 drive demand DOWN to 0 claims"
delete_claims
wait_exporter_metric 0 60
wait_spec_replicas "\$v -le $baseline" 420
drained="$(pool_spec_replicas)"; drained="${drained:-?}"
echo "  exporter is serving: $(exporter_metric)"
print_stage "drained"
[[ "$drained" != "?" && "$drained" -lt "$loaded" ]]
assert $? "with the demand gone KEDA lowered spec.replicas from $loaded to $drained: the scale-down decision"
[[ "$drained" == "$so_min" ]]
assert $? "spec.replicas came all the way back to the floor minReplicaCount=$so_min: no idle warm capacity held"

echo
echo "spec.replicas: baseline=$baseline -> under load=$loaded -> drained=$drained"
echo "claim demand:  0 -> $MAX_CLAIMS -> 0"
echo
echo "Now run the control, which applies the same demand with no autoscaler:"
echo "  ./scripts/control-no-autoscaler.sh"

assert_summary "KEDA moves the pool's spec.replicas up and back down with SandboxClaim demand"
