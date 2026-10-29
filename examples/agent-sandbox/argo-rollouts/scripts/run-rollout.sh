#!/usr/bin/env bash
# Drive the same template bump and pool drain from an Argo Rollouts canary
# timeline instead of a shell.
#
#   ./scripts/run-rollout.sh rev-3                        # let it run to completion
#   ./scripts/run-rollout.sh rev-4 --abort-during-drain   # abort mid-drain on purpose
#
# The Rollout's canary steps are what act: a plugin step patches the
# SandboxTemplate, a pause holds, a second plugin step drains and re-warms the
# pool, and setWeight finishes. The plugin steps run inside the controller with
# the ClusterRole the registration granted.
#
# With --abort-during-drain the script waits until the drain has scaled the pool
# to zero and then aborts the rollout, to show that the plugin's Abort restores
# the replica count rather than leaving warm capacity stranded at zero. That is
# the failure the drain must never cause: a pool left at zero serves no claims at
# all, which is worse than serving stale ones.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

REVISION="${1:-}"
MODE="${2:-}"
[[ -n "$REVISION" ]] || die "usage: $0 <revision> [--abort-during-drain]   (for example: $0 rev-3)"
[[ "$REVISION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] \
  || die "revision must start alphanumeric and hold only letters, digits, dots, dashes or underscores; got '$REVISION'"
[[ -z "$MODE" || "$MODE" == "--abort-during-drain" ]] || die "unknown option '$MODE'; the only option is --abort-during-drain"

# The revision is substituted into the manifest with sed, where `/` would end the
# expression and `&` would expand to the matched text. The pattern above already
# excludes both, so this is belt and braces rather than the only guard.
require_commands kubectl sed grep sort
show_context
require_our_namespace

# --- the shared installs the rollout needs ----------------------------------
require_argo_rollouts
require_step_plugin

# --- where the pool stands before the rollout -------------------------------
before_rev="$(template_revision)" || die "could not read $REVISION_ENV on sandboxtemplate/$TEMPLATE"
want_replicas="$(pool_spec_replicas)" \
  || die "could not read spec.replicas on sandboxwarmpool/$POOL; stopping rather than start a rollout without knowing the pool's size"
echo
echo "before the rollout: the template says $REVISION_ENV=$before_rev, the pool wants $want_replicas replicas"
[[ "$before_rev" == "$REVISION" ]] && echo "note: the template already says $REVISION, so the drain step will find the pool current and do nothing"

# rollout_step : the index of the canary step the controller is on, and the
# rollout's phase. Prints "<index>|<phase>"; returns non-zero when the read
# failed, so a blip is never read as "step 0".
rollout_step() {
  local out rc=0
  out="$(kc get rollout "$ROLLOUT" \
    -o jsonpath='{.status.currentStepIndex}|{.status.phase}' 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && return 1
  printf '%s' "$out"
}

# rollout_marker : the revision the Rollout's own marker container carries. It is
# what the canary steps progress; a Rollout already at the target revision has
# nothing to progress to.
rollout_marker() {
  local v rc=0
  v="$(kc get rollout "$ROLLOUT" \
    -o "jsonpath={.spec.template.spec.containers[0].env[?(@.name=='$REVISION_ENV')].value}" 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 || -z "$v" ]] && return 1
  printf '%s' "$v"
}

apply_rollout_at() {   # apply_rollout_at <revision>
  sed -e "s/__NAMESPACE__/$NAMESPACE/g" -e "s/__REVISION__/$1/g" \
    "$SAMPLE_DIR/deploy/rollout.yaml" | kc apply -f -
}

wait_rollout_healthy() {   # wait_rollout_healthy <timeout-s>
  local timeout=${1:-300} si
  local deadline=$((SECONDS + timeout))
  while :; do
    si="$(rollout_step)" || si=""
    [[ "${si##*|}" == "Healthy" ]] && return 0
    ((SECONDS >= deadline)) && return 1
    sleep 3
  done
}

# Argo Rollouts SKIPS the canary steps the first time a Rollout is created: a
# brand new Rollout goes straight to its final step, because there is no previous
# revision to progress away from. So a Rollout that does not exist yet is seeded
# at the revision the template ALREADY holds, which makes that skip a no-op, and
# only then is it bumped. Without the seed the plugin steps would never run and
# the template would never be patched.
seeded=""
exists_rc=0
resource_exists kc "rollout/$ROLLOUT" || exists_rc=$?
case $exists_rc in
  2) die "could not read rollout/$ROLLOUT; stopping rather than apply over something I cannot see" ;;
  1) step "seed the Rollout at $before_rev, the revision the template already holds"
     echo "Argo Rollouts skips the canary steps on a Rollout's first creation, so the first"
     echo "apply is made at the current revision: the skip then changes nothing, and the bump"
     echo "below is a real update whose steps do run."
     apply_rollout_at "$before_rev"
     wait_rollout_healthy 300 \
       || die "the seeded rollout/$ROLLOUT never became Healthy. Check 'kubectl -n $NAMESPACE describe rollout $ROLLOUT'"
     seeded=1
     echo "  seeded and Healthy at $before_rev" ;;
  0) cur_marker="$(rollout_marker)" || cur_marker=""
     echo "rollout/$ROLLOUT already exists, with its marker at ${cur_marker:-<unreadable>}"
     [[ "$cur_marker" == "$REVISION" ]] && die "rollout/$ROLLOUT is already at $REVISION, so applying it again changes nothing and no canary step would run. Pick a revision it is not already on."
     ;;
esac

step "apply the Rollout at $REVISION"
apply_rollout_at "$REVISION"

if [[ "$MODE" == "--abort-during-drain" ]]; then
  step "wait for the drain step to scale the pool to 0, then abort"
  # The window being caught is between the drain's scale-to-0 and its scale-back.
  # Polling spec.replicas is what identifies it: the drain is the only thing that
  # sets this pool to 0.
  deadline=$((SECONDS + 300))
  caught=""
  while ((SECONDS < deadline)); do
    cur="$(pool_spec_replicas)" || cur=""
    si="$(rollout_step)" || si="?|?"
    if [[ "$cur" == "0" ]]; then
      caught=1
      echo "  the drain has scaled the pool to spec.replicas=0 (rollout step ${si%%|*}); aborting now"
      break
    fi
    printf '  pool spec.replicas=%s, rollout step=%s\n' "${cur:-?}" "${si%%|*}"
    sleep 2
  done
  [[ -n "$caught" ]] || die "the pool was never observed at spec.replicas=0, so there was no mid-drain moment to abort. The drain may have finished faster than this script polled; re-run with a new revision."

  # Abort the rollout. The CLI sets status.abort; with plain kubectl that is a
  # patch to the status subresource.
  kc patch rollout "$ROLLOUT" --subresource=status --type=merge -p '{"status":{"abort":true}}' >/dev/null \
    || die "could not abort rollout/$ROLLOUT"
  echo "  aborted rollout/$ROLLOUT"

  step "the pool's replica count after the abort"
  # The plugin's Abort is what has to put this back. Waiting rather than reading
  # once, because the controller calls Abort asynchronously.
  deadline=$((SECONDS + 180))
  restored=""
  while ((SECONDS < deadline)); do
    cur="$(pool_spec_replicas)" || cur=""
    if [[ -n "$cur" && "$cur" != "0" ]]; then
      restored="$cur"
      break
    fi
    printf '  pool spec.replicas=%s\n' "${cur:-?}"
    sleep 3
  done
  echo
  assert "$([[ "$restored" == "$want_replicas" ]] && echo 0 || echo 1)" \
    "the plugin's Abort restored the pool to spec.replicas=$want_replicas (read: ${restored:-still 0 or unreadable})"
  phase="$(rollout_step)" || phase="?|?"
  echo "  rollout phase: ${phase##*|}"
  echo
  echo "warm capacity was not left stranded at zero. The pool re-warms at whichever"
  echo "revision the template holds; read it with: ./scripts/claim.sh after-abort"
  assert_summary "abort mid-drain restores the pool's replica count"
  exit $?
fi

step "watch the canary steps"
# The steps are: patch the template, pause, drain and re-warm, setWeight. The
# drain is the long one, because it waits for the pool to come back on the new
# revision.
deadline=$((SECONDS + 1200))
last=""
while ((SECONDS < deadline)); do
  si="$(rollout_step)" || si=""
  if [[ -n "$si" ]]; then
    idx="${si%%|*}"; phase="${si##*|}"
    line="  step=${idx:-<none>} phase=$phase  template=$(template_revision || echo '?')  poolReplicas=$(pool_spec_replicas || echo '?')  revisions=$(pool_sandbox_revisions | tr '\n' ',' || echo '?')"
    [[ "$line" != "$last" ]] && { echo "$line"; last="$line"; }
    [[ "$phase" == "Healthy" ]] && break
    [[ "$phase" == "Degraded" ]] && die "rollout/$ROLLOUT went Degraded. Check 'kubectl -n $NAMESPACE describe rollout $ROLLOUT' and 'kubectl -n $ARGO_NAMESPACE logs deploy/argo-rollouts'"
  fi
  sleep 5
done

echo
step "what the rollout left behind"
after_rev="$(template_revision)" || after_rev=""
echo "  the template says $REVISION_ENV=${after_rev:-<unreadable>}"
echo "  the pool's sandboxes booted at: $(pool_sandbox_revisions | tr '\n' ' ' || echo '<unreadable>')"
echo "  template hashes: $(pool_template_hashes | tr '\n' ' ' || echo '<unreadable>')"
ready="$(pool_ready_replicas)" || ready=""
echo "  readyReplicas=${ready:-?}/$want_replicas"
echo

assert "$([[ "$after_rev" == "$REVISION" ]] && echo 0 || echo 1)" \
  "the patch step put $REVISION_ENV=$REVISION on the SandboxTemplate (read: ${after_rev:-<unreadable>})"
pool_revs="$(pool_sandbox_revisions)" || pool_revs=""
assert "$([[ "$pool_revs" == "$REVISION" ]] && echo 0 || echo 1)" \
  "the drain step left every pool sandbox booted at $REVISION (read: ${pool_revs:-<unreadable>})"
assert "$([[ -n "$ready" && "$ready" == "$want_replicas" ]] && echo 0 || echo 1)" \
  "the pool is warm again at $want_replicas replicas (read: ${ready:-<unreadable>})"

echo
echo "Claim a pod and read its revision by value:  ./scripts/claim.sh after-rollout"
assert_summary "the Rollout drove the template patch and the pool drain"
