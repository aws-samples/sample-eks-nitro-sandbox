#!/usr/bin/env bash
# The control: the same demand, with no autoscaler. The pool must stay flat.
#
#   ./scripts/control-no-autoscaler.sh
#
# ./scripts/demand.sh asserts that the pool's spec.replicas moves up and back
# down with claim demand. On its own, a reading that moved could still be
# something else moving it. This run removes the ScaledObject, confirms the HPA
# went with it so nothing is autoscaling the pool, applies the SAME number of
# claims for at least as long as the scale-up in demand.sh was given, and asserts
# that spec.replicas does not move. Side by side, the two runs show the movement
# demand.sh asserts is KEDA's and nothing else's.
#
# It puts the sample back as setup.sh left it: the ScaledObject re-applied and no
# claims.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

# Leave the sample in a usable state even when an assertion fails, and let
# assert_summary own the exit code.
set +e

require_commands kubectl sed
show_context
require_our_namespace

resource_exists kc "sandboxwarmpool/$POOL" >/dev/null \
  || die "sandboxwarmpool/$POOL is not in namespace $NAMESPACE; run ./scripts/setup.sh first"

# Put the ScaledObject back whatever happens, including on an interrupt, so this
# run cannot leave the sample without its autoscaler. Returns kubectl's status,
# so step 4/4 can assert the restore worked rather than just announcing it.
restore_scaledobject() {
  sed -e "s/__NAMESPACE__/$NAMESPACE/g" "$SAMPLE_DIR/deploy/scaledobject.yaml" \
    | kc apply -f - >/dev/null 2>&1
}
# INT and TERM as well as EXIT: an interrupt must not leave the pool unmanaged.
trap 'echo; echo "restoring scaledobject/$SCALEDOBJECT"; delete_claims || true; restore_scaledobject || echo "WARNING: could not restore scaledobject/$SCALEDOBJECT; re-run ./scripts/setup.sh" >&2' EXIT INT TERM

so_min="$(kc get scaledobject "$SCALEDOBJECT" -o jsonpath='{.spec.minReplicaCount}' 2>/dev/null)"
[[ "$so_min" =~ ^[0-9]+$ ]] \
  || die "could not read minReplicaCount from scaledobject/$SCALEDOBJECT; stopping rather than compare against a floor I do not know"

step "1/4 settle at the floor, then remove the ScaledObject"
delete_claims || true
wait_claims_gone 180 || true
wait_spec_replicas "\$v -le $so_min" 300
baseline="$(pool_spec_replicas)" || baseline="?"
print_stage "baseline"
# The baseline is what "flat" is measured against. If it could not be read, there
# is no control to run: comparing two unread values would make "it stayed flat"
# true by construction, which is exactly the vacuous pass this script exists to
# rule out for demand.sh.
[[ "$baseline" =~ ^[0-9]+$ ]] \
  || die "the baseline spec.replicas could not be read, so 'the pool stayed flat' could not be established; stopping"

kc delete scaledobject "$SCALEDOBJECT" --ignore-not-found --wait=true --timeout=120s
# KEDA deletes the HPA it created when the ScaledObject goes. Confirm it, so the
# control is genuinely "no autoscaler" rather than "the ScaledObject object is
# gone but its HPA is still writing spec.replicas". A read that FAILS is not
# "no HPA": hpa_for_pool returns non-zero for that, and it keeps the loop going
# rather than concluding the pool is unmanaged.
gone=""
left=""
read_failed=""
for _ in $(seq 1 24); do   # 24 * 5s = 2m
  if left="$(hpa_for_pool)"; then
    read_failed=""
    [[ -z "$left" ]] && { gone=1; break; }
  else
    left=""
    read_failed=1
  fi
  sleep 5
done
if [[ -n "$read_failed" ]]; then
  echo "  HPA whose scaleTargetRef names $POOL: <could not read>"
else
  echo "  HPA whose scaleTargetRef names $POOL: ${left:-<none>}"
fi
[[ -n "$gone" ]]
assert $? "the ScaledObject and the HPA it owned are both gone: nothing is autoscaling the pool now"

step "2/4 apply the same demand: $MAX_CLAIMS claims"
make_claims "$MAX_CLAIMS"
control_claims="$(claim_count)" || control_claims="?"
echo "  claims now: $control_claims"
[[ "$control_claims" == "$MAX_CLAIMS" ]]
assert $? "the same demand is present for the control: $MAX_CLAIMS claims, as in demand.sh"
# Wait for the exporter to report the new demand before reading it, so the line
# below shows the signal that IS there and that nothing is acting on, rather than
# the exporter's previous answer. The signal having arrived is asserted: "nothing
# read it" means nothing, if it was never served.
metric_rc=0
wait_exporter_metric "$MAX_CLAIMS" 120 || metric_rc=$?
echo "  exporter is serving: $(exporter_metric)"
[[ $metric_rc -eq 0 ]]
assert $? "the exporter served active_claims=$MAX_CLAIMS, so the demand signal KEDA would have read was there"
echo "  (the demand signal is there; with no ScaledObject, nothing reads it)"

step "3/4 watch for the same window demand.sh gives the scale-up (300s)"
# demand.sh waits up to 300s for the scale-up, so give the control at least as
# long: a slow move must not be missed by stopping early.
deadline=$((SECONDS + 300))
moved=""
while ((SECONDS < deadline)); do
  v="$(pool_spec_replicas)" || v=""
  if [[ -n "$v" && "$v" -gt "$baseline" ]]; then moved="$v"; break; fi
  sleep 10
done
after="$(pool_spec_replicas)" || after="?"
print_stage "under load"
# Both sides must be real numbers AND equal. "?" == "?" would otherwise report a
# flat pool from two failed reads.
[[ -z "$moved" && "$after" =~ ^[0-9]+$ && "$after" == "$baseline" ]]
assert $? "with no autoscaler, spec.replicas stayed flat at $baseline under the same $MAX_CLAIMS claims"
[[ -n "$moved" ]] && echo "  spec.replicas moved to $moved with no ScaledObject present; that is unexpected, investigate before trusting demand.sh"

step "4/4 put the sample back: claims deleted, ScaledObject re-applied"
# The trap does this too, so an interrupted run is covered; doing it here means
# the output says it happened AND the result is asserted. A control that left the
# sample without its autoscaler while reporting all checks passed would be worse
# than one that failed.
delete_claims || true
restore_rc=0
restore_scaledobject || restore_rc=$?
[[ $restore_rc -eq 0 ]]
assert $? "scaledobject/$SCALEDOBJECT was re-applied, so the sample is not left without its autoscaler"
echo "  waiting for KEDA to take the pool back"
back=""
for _ in $(seq 1 36); do   # 36 * 5s = 3m
  if back="$(hpa_for_pool)" && [[ -n "$back" ]]; then break; fi
  back=""
  sleep 5
done
echo "  HPA whose scaleTargetRef names $POOL: ${back:-<none>}"
[[ -n "$back" ]]
assert $? "KEDA created its HPA for $POOL again, so the pool is back under autoscaling"

echo
echo "control result: no ScaledObject, no movement. The up and down movement"
echo "./scripts/demand.sh asserts is therefore KEDA's, not spare capacity and not"
echo "the pool replenishing itself."

assert_summary "the pool stays flat under the same demand when KEDA's ScaledObject is absent"
