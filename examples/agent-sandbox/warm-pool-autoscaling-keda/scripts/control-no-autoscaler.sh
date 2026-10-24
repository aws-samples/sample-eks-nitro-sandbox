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
# run cannot leave the sample without its autoscaler.
restore_scaledobject() {
  sed -e "s/__NAMESPACE__/$NAMESPACE/g" "$SAMPLE_DIR/deploy/scaledobject.yaml" \
    | kc apply -f - >/dev/null 2>&1
}
trap 'echo; echo "restoring scaledobject/$SCALEDOBJECT"; delete_claims; restore_scaledobject' EXIT

step "1/4 settle at the floor, then remove the ScaledObject"
delete_claims
wait_spec_replicas '$v -le 1' 300
baseline="$(pool_spec_replicas)"; baseline="${baseline:-?}"
print_stage "baseline"

kc delete scaledobject "$SCALEDOBJECT" --ignore-not-found --wait=true --timeout=120s
# KEDA deletes the HPA it created when the ScaledObject goes. Confirm it, so the
# control is genuinely "no autoscaler" rather than "the ScaledObject object is
# gone but its HPA is still writing spec.replicas".
gone=""
left=""
for _ in $(seq 1 24); do   # 24 * 5s = 2m
  left="$(hpa_for_pool)"
  [[ -z "$left" ]] && { gone=1; break; }
  sleep 5
done
echo "  HPA whose scaleTargetRef names $POOL: ${left:-<none>}"
[[ -n "$gone" ]]
assert $? "the ScaledObject and the HPA it owned are both gone: nothing is autoscaling the pool now"

step "2/4 apply the same demand: $MAX_CLAIMS claims"
make_claims "$MAX_CLAIMS"
echo "  claims now: $(claim_count)"
# Wait for the exporter to report the new demand before reading it, so the line
# below shows the signal that IS there and that nothing is acting on, rather than
# the exporter's previous answer.
wait_exporter_metric "$MAX_CLAIMS" 60
echo "  exporter is serving: $(exporter_metric)"
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
after="$(pool_spec_replicas)"; after="${after:-?}"
print_stage "under load"
[[ -z "$moved" && "$after" == "$baseline" ]]
assert $? "with no autoscaler, spec.replicas stayed flat at $baseline under the same $MAX_CLAIMS claims"
[[ -n "$moved" ]] && echo "  spec.replicas moved to $moved with no ScaledObject present; that is unexpected, investigate before trusting demand.sh"

step "4/4 put the sample back: claims deleted, ScaledObject re-applied"
# The trap does this too, so an interrupted run is covered; doing it here means
# the output says it happened.
delete_claims
restore_scaledobject
echo "  scaledobject/$SCALEDOBJECT re-applied, claims deleted"
echo "  waiting for KEDA to take the pool back"
for _ in $(seq 1 36); do
  [[ -n "$(hpa_for_pool)" ]] && break
  sleep 5
done
echo "  HPA whose scaleTargetRef names $POOL: $(hpa_for_pool)"

echo
echo "control result: no ScaledObject, no movement. The up and down movement"
echo "./scripts/demand.sh asserts is therefore KEDA's, not spare capacity and not"
echo "the pool replenishing itself."

assert_summary "the pool stays flat under the same demand when KEDA's ScaledObject is absent"
