#!/usr/bin/env bash
# Delete everything the sample created, and only that.
#
#   ./scripts/cleanup.sh
#
# ORDER MATTERS:
#   1. the claims        -- they hold warm pods; deleting them releases them.
#   2. the ScaledObject  -- so KEDA stops writing spec.replicas and removes its
#                           HPA before the pool goes.
#   3. the exporter      -- the endpoint KEDA polled.
#   4. the warm pool     -- a pool boots replacements, so removing it stops the
#                           loop; then wait for its pods to actually go.
#   5. the template      -- the pool references it, so it goes after the pool.
#   6. the namespace     -- last.
#
# KEDA IS NOT REMOVED. It is a shared install: another workload on the cluster
# may rely on it, and taking out a cluster prerequisite is not part of tearing
# down one sample. The page says what stays and how to remove it, with the
# check to run first.
#
# The namespace label is the mark: setup.sh created and labelled the namespace,
# so everything inside it is the sample's and the namespace check covers its
# contents. This sample creates no AWS resources, so there is nothing to clean up
# outside the cluster.
#
# Lookups are failure-aware: a read that fails means "could not determine",
# which is a failure, never "gone". The script exits non-zero when it skipped
# something or could not confirm a delete, so an incomplete clean up is never
# reported as done. Safe to run at any time, including when nothing was set up.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

# One failed delete must not stop the ones after it; track failures and own the
# exit code at the end.
set +e

require_commands kubectl
show_context

failures=0
note_fail() { echo "  INCOMPLETE: $*" >&2; failures=$((failures + 1)); }

# del <kind> <name...> : delete objects in the sample's namespace, by exact name,
# reporting a failed read as a failure rather than as "gone". Only called after
# the namespace has been confirmed the sample's.
del() {
  local kind=$1; shift
  local name rc
  for name in "$@"; do
    rc=0; resource_exists kc "$kind/$name" || rc=$?
    case $rc in
      0) kc delete "$kind" "$name" --wait=true --timeout=180s \
           || note_fail "$kind/$name did not delete cleanly" ;;
      1) echo "  $kind/$name not present" ;;
      2) note_fail "could not read $kind/$name; not reporting it gone" ;;
    esac
  done
}

# The namespace must be the sample's before anything inside it is deleted. A read
# that fails is a failure, never "gone".
ns_absent=0
namespace_is_ours
ns_rc=$?
case $ns_rc in
  0) : ;;
  1) die "namespace $NAMESPACE exists but is not the sample's ($NS_LABEL_KEY=$NS_LABEL_VAL); refusing to touch it" ;;
  2) die "could not read namespace $NAMESPACE; refusing to delete anything (a failed read is not 'gone')" ;;
  3) ns_absent=1; echo "namespace $NAMESPACE does not exist; nothing of this sample's is left to delete." ;;
esac

if [[ $ns_absent -eq 0 ]]; then
  step "1/6 delete the demand claims"
  # By exact name, never by label selector, so this can only remove the claims
  # this sample makes.
  claim_names=()
  for ((i = 1; i <= MAX_CLAIMS; i++)); do claim_names+=("${CLAIM_PREFIX}-${i}"); done
  del sandboxclaim "${claim_names[@]}"

  step "2/6 delete the ScaledObject so KEDA stops scaling and removes its HPA"
  del scaledobject "$SCALEDOBJECT"
  # Confirm the HPA went with it, so nothing is left writing to a pool that is
  # about to be deleted.
  left_hpa=""
  for _ in $(seq 1 24); do
    left_hpa="$(hpa_for_pool)"
    [[ -z "$left_hpa" ]] && break
    sleep 5
  done
  if [[ -n "$left_hpa" ]]; then
    note_fail "hpa/$left_hpa still targets $POOL after the ScaledObject was deleted"
  else
    echo "  no HPA targets $POOL any more"
  fi

  step "3/6 delete the claim-demand exporter"
  del service "$EXPORTER"
  del deployment "$EXPORTER"
  del configmap "$EXPORTER_SRC_CM"
  del rolebinding "$EXPORTER"
  del role "$EXPORTER"
  del serviceaccount "$EXPORTER"

  step "4/6 delete the warm pool so it stops booting replacements"
  del sandboxwarmpool "$POOL"
  # The pool's own pods: wait for them to go, so a still-running sandbox is never
  # reported as cleaned up. Matched by the pool's name prefix within the sample's
  # own namespace, which the label check above has already established is the
  # sample's.
  echo "  waiting for the pool's sandboxes to terminate"
  leftover=""
  for _ in $(seq 1 60); do   # 60 * 5s = 5m
    leftover="$(kc get sandboxes -o name 2>/dev/null | sed 's|.*/||' | grep -E "^${POOL}-" | tr '\n' ' ')"
    [[ -z "$leftover" ]] && break
    echo "    still terminating: $leftover"
    sleep 5
  done
  if [[ -n "$leftover" ]]; then
    note_fail "these sandboxes of the pool are still present after 5m: $leftover"
  else
    echo "    the pool's sandboxes are gone"
  fi

  step "5/6 delete the SandboxTemplate"
  del sandboxtemplate "$TEMPLATE"
fi

step "6/6 delete namespace $NAMESPACE"
# Only when everything above succeeded. If a delete failed or a read could not be
# confirmed, something may still be in the namespace, and deleting it would hide
# an incomplete clean up.
if [[ $ns_absent -eq 1 ]]; then
  echo "  namespace $NAMESPACE not present"
elif [[ $failures -ne 0 ]]; then
  echo "  SKIPPED: not deleting namespace $NAMESPACE while $failures item(s) above are unconfirmed; resolve them first." >&2
elif kc_cluster delete namespace "$NAMESPACE" --wait=true --timeout=300s; then
  echo "  namespace $NAMESPACE deleted"
else
  note_fail "namespace $NAMESPACE did not delete cleanly"
fi

echo
echo "KEDA in namespace $KEDA_NAMESPACE is left installed: it is a shared install and"
echo "another workload may rely on it. The page says how to remove it, and what to check"
echo "first."

echo
if [[ $failures -ne 0 ]]; then
  echo "clean up INCOMPLETE: $failures item(s) could not be removed or confirmed (see above)." >&2
  echo "Check with: kubectl get sandboxwarmpool,sandboxclaim,sandbox,scaledobject,deploy -n $NAMESPACE" >&2
  echo "        and kubectl get ns $NAMESPACE" >&2
  exit 1
fi
if [[ $ns_absent -eq 1 ]]; then
  echo "clean up complete: nothing of this sample's was on the cluster."
else
  echo "clean up complete: the claims, the ScaledObject and its HPA, the exporter, the warm pool, the template and the namespace are gone."
fi
