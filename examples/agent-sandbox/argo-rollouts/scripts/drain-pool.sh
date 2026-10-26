#!/usr/bin/env bash
# The drain action, as a plain script. This is the mechanism the Argo Rollouts
# step plugin performs from a canary timeline; running it here shows what the
# plugin does, without a controller.
#
#   ./scripts/drain-pool.sh
#
# Patching a SandboxTemplate does NOT reboot the pool. Pods already warm keep the
# revision they booted with, and a SandboxClaim made after the patch can adopt
# one of them. This closes that window: it replaces the warm pods with pods
# booted from the template as it now stands.
#
# What it does, in order:
#   1. If every pool sandbox already booted with the revision the template holds,
#      stop: the pool is current and draining it would destroy warm capacity for
#      nothing. This is what makes a second run a safe no-op.
#   2. Read the pool's spec.replicas, so there is a number to restore.
#   3. Patch spec.replicas to 0.
#   4. Wait until no sandbox matches the pool's selector. A Terminating sandbox
#      counts as still present, because a claim could otherwise race onto a pod
#      that is going away.
#   5. Patch spec.replicas back.
#   6. Wait until readyReplicas meets it with ONE distinct template hash across
#      the pool. Waiting on readyReplicas alone would pass while a replacement
#      was still coming up, and a claim in that window could still adopt a pod
#      from the old revision.
#
# If any step fails after the pool has been scaled to zero, the pool is scaled
# back before the script exits, so a failed drain never leaves warm capacity
# stranded at zero. That is the same guarantee the plugin's Abort and Terminate
# give a rollout.
#
# Exit codes:
#   0  the pool is at the template's current revision, drained or already there
#   1  the drain did not converge in time (the pool has been scaled back)
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

# Each phase gets its OWN budget, so a slow drain cannot eat the budget the
# re-warm needs. On a cluster that has to launch a node for the replacements,
# the re-warm is the slow half.
DRAIN_TIMEOUT_SECS="${DRAIN_TIMEOUT_SECS:-300}"
REWARM_TIMEOUT_SECS="${REWARM_TIMEOUT_SECS:-600}"

require_commands kubectl grep sort
show_context
require_our_namespace

# RESTORE_TO holds the replica count to put back while the pool is scaled down.
# It is set after the scale to zero and cleared once the pool is scaled back, so
# the trap only acts in the window where capacity would otherwise be stranded.
RESTORE_TO=""
restore_if_needed() {
  local rc=$?
  if [[ -n "$RESTORE_TO" ]]; then
    echo "[drain] exiting with the pool still scaled to 0; restoring spec.replicas=$RESTORE_TO" >&2
    if kc patch sandboxwarmpool "$POOL" --type=merge \
         -p "{\"spec\":{\"replicas\":$RESTORE_TO}}" >/dev/null 2>&1; then
      echo "[drain] restored spec.replicas=$RESTORE_TO" >&2
    else
      echo "[drain] COULD NOT restore spec.replicas=$RESTORE_TO on $POOL; the pool is still at 0. Put it back with: kubectl -n $NAMESPACE patch sandboxwarmpool $POOL --type=merge -p '{\"spec\":{\"replicas\":$RESTORE_TO}}'" >&2
    fi
  fi
  return $rc
}
trap restore_if_needed EXIT
# INT and TERM are trapped separately so an interrupted drain unwinds too: the
# EXIT trap alone does not run on a signal that kills the shell outright.
trap 'exit 130' INT
trap 'exit 143' TERM

want_rev="$(template_revision)" \
  || die "could not read $REVISION_ENV on sandboxtemplate/$TEMPLATE; stopping rather than drain a pool without knowing what to drain it to"
echo "[drain] the SandboxTemplate says $REVISION_ENV=$want_rev"

sel="$(pool_selector)" \
  || die "could not read a usable status.selector on sandboxwarmpool/$POOL; stopping rather than treat an unreadable selector as an empty pool"
echo "[drain] the pool selects sandboxes with $sel"

# --- 1) already current? ----------------------------------------------------
cur_rc=0
pool_is_current || cur_rc=$?
case $cur_rc in
  0) echo "[drain] every pool sandbox already booted at $REVISION_ENV=$want_rev; nothing to drain"
     pool_template_hashes | sed 's/^/  template hash: /'
     exit 0 ;;
  2) die "could not determine which revision the pool's sandboxes booted with; stopping rather than drain on a guess" ;;
esac
have_revs="$(pool_sandbox_revisions | join_lines)" || have_revs=""
echo "[drain] the pool's sandboxes booted at: ${have_revs:-<none>} (want $want_rev), so a drain is needed"

old_hashes="$(pool_template_hashes | join_lines)" || old_hashes=""
echo "[drain] pre-drain template hashes: ${old_hashes:-<none>}"

want="$(pool_spec_replicas)" \
  || die "could not read spec.replicas on sandboxwarmpool/$POOL; stopping rather than scale a pool whose size is unknown"
if [[ "$want" == "0" ]]; then
  echo "[drain] spec.replicas is already 0; there is no warm capacity to drain"
  exit 0
fi
echo "[drain] spec.replicas=$want (will scale to 0, then back to $want)"

# --- 2) scale to zero -------------------------------------------------------
# RESTORE_TO is armed BEFORE the patch, not after it. Between the patch and the
# assignment there is a window in which an INT or a TERM would leave the trap
# with no restore target and the pool at zero. Arming it first closes that
# window: if the patch never lands, the trap's restore is a patch back to the
# value the pool already has, which is a harmless no-op.
RESTORE_TO="$want"
kc patch sandboxwarmpool "$POOL" --type=merge -p '{"spec":{"replicas":0}}' >/dev/null
echo "[drain] patched spec.replicas=0; waiting for the pool to empty (timeout ${DRAIN_TIMEOUT_SECS}s)"

deadline=$((SECONDS + DRAIN_TIMEOUT_SECS))
drained=""
while ((SECONDS < deadline)); do
  # A read that failed leaves the loop waiting: counting it as 0 would call the
  # pool drained on no evidence, and the re-warm would then start while old pods
  # were still there.
  left="$(pool_sandbox_count)" || left="?"
  if [[ "$left" == "0" ]]; then
    drained=1
    echo "[drain] the pool is empty: 0 sandboxes match the pool selector"
    break
  fi
  printf '  %s pool sandbox(es) still present (Terminating counts)\n' "$left"
  sleep 3
done
[[ -n "$drained" ]] || {
  echo "[drain] timeout: the pool still had sandboxes after ${DRAIN_TIMEOUT_SECS}s" >&2
  exit 1
}

# --- 3) scale back and wait for the new revision ----------------------------
kc patch sandboxwarmpool "$POOL" --type=merge -p "{\"spec\":{\"replicas\":$want}}" >/dev/null
RESTORE_TO=""
echo "[drain] patched spec.replicas=$want; waiting for the pool to re-warm at $want_rev (timeout ${REWARM_TIMEOUT_SECS}s)"

# The condition is readyReplicas == want AND one distinct template hash AND every
# sandbox booted at the revision the template holds. The hash alone would be
# satisfied by a pool that is consistently on the OLD template, which is exactly
# the state the drain exists to leave behind.
deadline=$((SECONDS + REWARM_TIMEOUT_SECS))
while ((SECONDS < deadline)); do
  ready="$(pool_ready_replicas)" || ready=""
  hashes="$(pool_template_hashes)" || hashes=""
  count="$(printf '%s' "$hashes" | grep -c . || true)"
  revs="$(pool_sandbox_revisions)" || revs=""
  if [[ "$ready" == "$want" && "$count" == "1" && "$revs" == "$want_rev" ]]; then
    echo "[drain] the pool has re-warmed: readyReplicas=$ready, all sandboxes at $REVISION_ENV=$revs"
    echo "[drain] template hash: ${old_hashes:-<none>} -> $(printf '%s' "$hashes" | join_lines)"
    exit 0
  fi
  printf '  readyReplicas=%s/%s  distinct hashes=%s  revisions=%s\n' \
    "${ready:-?}" "$want" "${count:-0}" "$(printf '%s' "${revs:-<none>}" | join_lines)"
  sleep 5
done

echo "[drain] timeout: the pool did not re-warm at $want_rev within ${REWARM_TIMEOUT_SECS}s" >&2
echo "[drain] last reading: readyReplicas=${ready:-?}/$want, revisions=${revs:-<none>}, hashes=${hashes:-<none>}" >&2
exit 1
