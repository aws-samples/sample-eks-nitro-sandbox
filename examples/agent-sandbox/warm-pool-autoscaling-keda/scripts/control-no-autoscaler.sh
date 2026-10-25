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

require_commands kubectl sed seq grep
show_context
require_our_namespace

resource_exists kc "sandboxwarmpool/$POOL" >/dev/null \
  || die "sandboxwarmpool/$POOL is not in namespace $NAMESPACE; run ./scripts/setup.sh first"

# Put the ScaledObject back whatever happens, including on an interrupt, so this
# run cannot leave the sample without its autoscaler.
#
# It is not enough to apply and take kubectl's status. An apply over an object
# that is still being deleted SUCCEEDS and the object then goes away with the
# deletion, so the apply's exit code says nothing about whether the autoscaler is
# there afterwards. That case is not hypothetical: the likeliest moment for an
# interrupt is during the `kc delete scaledobject --wait=true` in step 1/4, where
# the delete request is already in and the object is terminating behind KEDA's
# finalizer. So this waits for any in-flight deletion to finish, applies, and
# then READS THE OBJECT BACK, returning non-zero unless it is present with no
# deletionTimestamp. Both callers, step 4/4 and the EXIT trap, get all three.
restore_scaledobject() {
  local del rc
  # Wait ONLY when there is a deletion in flight. `kubectl wait --for=delete` on an
  # object that nothing is deleting does not return early: it waits the whole
  # timeout and then fails. Called unconditionally, that put a flat two minutes on
  # every normal exit, where step 4/4 has just restored the object and the EXIT
  # trap restores it again, and on every `die` after the trap is set, where the
  # ScaledObject has not been deleted at all. The trap ignores INT and TERM while
  # it runs, so those two minutes were also uninterruptible and printed nothing.
  # A read that FAILED maps to "wait", not to "nothing in flight": if a deletion
  # really is in progress, skipping the wait means applying over a terminating
  # object, and the read-back below then reports a restore that could have worked.
  # --ignore-not-found keeps a genuinely absent object as the empty, no-wait case.
  del="$(kc get scaledobject "$SCALEDOBJECT" --ignore-not-found \
           --request-timeout=30s -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" || del="unknown"
  if [[ -n "$del" ]]; then
    echo "  scaledobject/$SCALEDOBJECT is still terminating; waiting for the deletion to finish"
    kc wait --for=delete "scaledobject/$SCALEDOBJECT" --timeout=120s >/dev/null 2>&1 || true
  fi
  # --request-timeout on both calls: with INT and TERM ignored in the trap, an API
  # call that hangs would otherwise need a SIGKILL to get out of.
  sed -e "s/__NAMESPACE__/$NAMESPACE/g" "$SAMPLE_DIR/deploy/scaledobject.yaml" \
    | kc apply --request-timeout=30s -f - >/dev/null 2>&1 || return 1
  del="$(kc get scaledobject "$SCALEDOBJECT" --request-timeout=30s \
           -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)"
  rc=$?
  [[ $rc -eq 0 && -z "$del" ]]
}
# Restore on the way out, however the script ends, so it cannot leave the pool
# unmanaged.
#
# The restore is on EXIT only, and INT and TERM just exit. A handler trapped on
# INT or TERM does NOT end the script: bash runs it and carries on with the next
# command. Putting the restore on INT would therefore re-apply the ScaledObject in
# the middle of the run and let the run continue, so the watch loop would measure
# a pool that KEDA had been handed back and report it flat: all checks passing
# after the operator had interrupted the run. Exiting instead makes the EXIT trap
# run once, with a signal exit status.
#
# The handler ignores INT, TERM and HUP while it runs: a second Ctrl-C, an
# impatient `kill`, or the dropped ssh session that sends HUP to the whole process
# group would otherwise cut the restore off part way and leave the pool with no
# autoscaler and no warning printed.
trap 'trap "" INT TERM HUP; echo; echo "restoring scaledobject/$SCALEDOBJECT"; delete_claims || true; restore_scaledobject || echo "WARNING: could not restore scaledobject/$SCALEDOBJECT; re-run ./scripts/setup.sh" >&2' EXIT
trap 'echo; echo "interrupted" >&2; exit 130' INT
trap 'echo; echo "terminated" >&2; exit 143' TERM

so_min="$(kc get scaledobject "$SCALEDOBJECT" -o jsonpath='{.spec.minReplicaCount}' 2>/dev/null)"
so_max="$(kc get scaledobject "$SCALEDOBJECT" -o jsonpath='{.spec.maxReplicaCount}' 2>/dev/null)"
[[ "$so_min" =~ ^[0-9]+$ ]] \
  || die "could not read minReplicaCount from scaledobject/$SCALEDOBJECT; stopping rather than compare against a floor I do not know"
# The pool must have somewhere to GO for "it stayed flat" to say anything. If the
# floor and the ceiling were the same number, the pool could not rise however much
# demand arrived, and this control would pass on a pool that was never free to
# move. That is the shape of vacuous pass this whole script exists to exclude.
[[ "$so_max" =~ ^[0-9]+$ ]] \
  || die "could not read maxReplicaCount from scaledobject/$SCALEDOBJECT; stopping rather than claim a pool stayed flat without knowing it could have risen"
(( so_max > so_min )) \
  || die "scaledobject/$SCALEDOBJECT has minReplicaCount=$so_min and maxReplicaCount=$so_max, so the pool has no room to rise and 'it stayed flat' would be true whatever happened; widen the bounds and re-run"
# And the demand this script applies must be enough to ASK for more than the
# floor. With targetValue 1 the trigger wants one warm pod per claim, so
# MAX_CLAIMS claims at or below minReplicaCount would leave KEDA wanting exactly
# the floor: the pool would sit still with the ScaledObject present too, and a
# flat reading here would say nothing about whether KEDA was reading the signal.
(( MAX_CLAIMS > so_min )) \
  || die "this script applies $MAX_CLAIMS claims and the floor is minReplicaCount=$so_min, so even with KEDA reading the signal the pool would not rise above the floor and 'it stayed flat' would prove nothing; raise MAX_CLAIMS above $so_min or lower the floor"

step "1/4 settle at the floor, then remove the ScaledObject"
delete_claims || true
# The claims must be GONE before the baseline is read. A claim that is still
# terminating counts as demand everywhere that matters: the exporter counts it,
# claim_count counts it, and KEDA keeps the pool raised for it. If that left the
# pool sitting at maxReplicaCount, then "the pool stayed flat" would be true
# because the pool could not go any higher, and this control would report a pass
# having measured nothing. That is the one failure this script exists to rule
# out, so it stops here rather than carrying on.
wait_claims_gone 180 \
  || die "claims from an earlier run are still present, so the pool may already be raised and 'it stayed flat' could not mean anything; wait for them to go and re-run"
wait_spec_replicas "\$v -le $so_min" 300
baseline="$(pool_spec_replicas)" || baseline="?"
print_stage "baseline"
# The baseline is what "flat" is measured against, and it must be the FLOOR, not
# just any number. A baseline already at maxReplicaCount could not rise, so a
# flat reading would prove nothing.
[[ "$baseline" =~ ^[0-9]+$ ]] \
  || die "the baseline spec.replicas could not be read, so 'the pool stayed flat' could not be established; stopping"
[[ "$baseline" == "$so_min" ]] \
  || die "the pool is at spec.replicas=$baseline, not the floor $so_min, so it has room to fall but not to rise and a flat reading would prove nothing; clear the demand and re-run"

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
# The assertion names the ScaledObject as well as the HPA, so read the
# ScaledObject too rather than inferring it from the delete having been issued.
# resource_exists returns 1 for absent and 2 for a read that failed, and only 1
# will do here: a ScaledObject we could not read is not a ScaledObject we know
# is gone.
so_rc=0
resource_exists kc "scaledobject/$SCALEDOBJECT" >/dev/null || so_rc=$?
case $so_rc in
  0) echo "  scaledobject/$SCALEDOBJECT: still present" ;;
  1) echo "  scaledobject/$SCALEDOBJECT: gone" ;;
  2) echo "  scaledobject/$SCALEDOBJECT: <could not read>" ;;
esac
[[ -n "$gone" && $so_rc -eq 1 ]]
assert $? "the ScaledObject and the HPA it owned are both gone: nothing is autoscaling the pool now"

step "2/4 apply the same demand: $MAX_CLAIMS claims"
make_rc=0
make_claims "$MAX_CLAIMS" || make_rc=$?
control_claims="$(claim_count)" || control_claims="?"
echo "  claims now: $control_claims"
[[ $make_rc -eq 0 && "$control_claims" == "$MAX_CLAIMS" ]]
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
# Count the reads that actually came back. "Nothing moved" is only a finding if
# the window was watched: if every read in it had failed, the pool could have
# risen and fallen again inside the window and the final read below would still
# say the floor. So the window must have produced readings of its own.
polls=0
while ((SECONDS < deadline)); do
  v="$(pool_spec_replicas)" || v=""
  if [[ -n "$v" ]]; then
    polls=$((polls + 1))
    # ANY reading that is not the baseline ends the window, not just a higher one.
    # "Flat" means every reading was the baseline, which is what the assertion
    # below says; breaking only on a higher value would let a reading BELOW the
    # baseline be counted and then reported as having been the baseline.
    [[ "$v" != "$baseline" ]] && { moved="$v"; break; }
  fi
  sleep 10
done
after="$(pool_spec_replicas)" || after="?"
print_stage "under load"
# "every one of them" is a claim about readings that were taken, so it needs
# BOTH that none of them moved and that there were some. With no successful read
# the line would otherwise say "read 0 time(s), every one of them 1", which is
# the sentence this guard exists to prevent.
if [[ -z "$moved" && $polls -gt 0 ]]; then
  echo "  spec.replicas read $polls time(s) during the window, every one of them $baseline"
elif [[ -z "$moved" ]]; then
  echo "  no reading of spec.replicas came back during the window, so nothing was observed"
fi
# Both sides must be real numbers AND equal, and the window must have been
# watched. "?" == "?" would otherwise report a flat pool from two failed reads.
[[ -z "$moved" && $polls -gt 0 && "$after" =~ ^[0-9]+$ && "$after" == "$baseline" ]]
assert $? "with no autoscaler, spec.replicas stayed flat at $baseline under the same $MAX_CLAIMS claims"
[[ -n "$moved" ]] && echo "  spec.replicas moved to $moved with no ScaledObject present; that is unexpected, investigate before trusting demand.sh"
# A flat window and a different reading after it is its own case, and without this
# the FAIL above would have nothing beside it saying what was seen.
[[ -z "$moved" && "$after" != "$baseline" ]] && echo "  spec.replicas read $after after the window, having been $baseline throughout it"

step "4/4 put the sample back: claims deleted, ScaledObject re-applied"
# The trap does this too, so an interrupted run is covered; doing it here means
# the output says it happened AND the result is asserted. A control that left the
# sample without its autoscaler while reporting all checks passed would be worse
# than one that failed.
delete_claims || true
# restore_scaledobject waits out any in-flight deletion, applies, and reads the
# object back, so its status already means "it is there and not terminating".
restore_rc=0
restore_scaledobject || restore_rc=$?
[[ $restore_rc -eq 0 ]]
assert $? "scaledobject/$SCALEDOBJECT is back and not terminating, so the sample is not left without its autoscaler"
echo "  waiting for KEDA to take the pool back"
back=""
seen=""          # the last answer the loop got, for the line below
seen_rc=0
for _ in $(seq 1 36); do   # 36 * 5s = 3m
  # One name, not several: two HPAs both targeting the pool would make this
  # "yes" while KEDA's own may never have been created.
  seen_rc=0
  seen="$(hpa_for_pool)" || seen_rc=$?
  if [[ $seen_rc -eq 0 && -n "$seen" && "$seen" != *$'\n'* ]]; then back="$seen"; break; fi
  back=""
  sleep 5
done
# Report what was actually seen. Printing "<none>" for a failed read, or for two
# names, would say the opposite of what happened.
if [[ $seen_rc -ne 0 ]]; then
  echo "  HPA whose scaleTargetRef names $POOL: <could not read>"
elif [[ -z "$seen" ]]; then
  echo "  HPA whose scaleTargetRef names $POOL: <none>"
else
  echo "  HPA whose scaleTargetRef names $POOL: ${seen//$'\n'/, }"
fi
[[ -n "$back" ]]
assert $? "KEDA created its HPA for $POOL again, so the pool is back under autoscaling"

echo
# The conclusion is a finding, so it is only printed when the checks that support
# it all passed. Printed unconditionally it would have appeared under a run whose
# flat-pool check had just FAILED, including the run that reports the pool moved
# with no ScaledObject present, which is the one reading that would call
# demand.sh into question.
if [[ $ASSERT_FAIL -eq 0 ]]; then
  echo "control result: no ScaledObject, no movement. The up and down movement"
  echo "./scripts/demand.sh asserts is therefore KEDA's, not spare capacity and not"
  echo "the pool replenishing itself."
else
  echo "control result: NOT established. A check above failed, so this run says"
  echo "nothing either way about the movement ./scripts/demand.sh asserts. Read the"
  echo "FAIL line and re-run before trusting either script."
fi

assert_summary "the pool stays flat under the same demand when KEDA's ScaledObject is absent"
