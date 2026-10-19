#!/usr/bin/env bash
# Delete everything setup.sh created for the cedar-policy sample.
#
#   ./scripts/clean.sh                   # delete the pod, egress policy and namespace, and the tmp files
#   ./scripts/clean.sh --keep-namespace  # delete the pod and egress policy, keep the namespace
#
# This sample creates no AWS resources, so there is nothing to delete in the
# account. clean.sh deletes the namespace only after confirming it carries this
# sample's managed-by label, so it never removes a namespace another demo created.
# Each deletion is verified; the script exits non-zero if anything it was asked to
# remove is still there or could not be checked.
set -uo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/cedar-policy"

NAMESPACE="${NAMESPACE:-cedar-policy-sample}"
POD_NAME="${POD_NAME:-cedar-policy-demo}"
MANAGED_BY_LABEL="app.kubernetes.io/managed-by=cedar-policy-sample"

KUBE_CONTEXT="${KUBE_CONTEXT:-}"
kc() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    kubectl --context "$KUBE_CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

keep_namespace=false
for arg in "$@"; do
  case "$arg" in
    --keep-namespace) keep_namespace=true ;;
    --help|-h) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl is required" >&2; exit 1; }

failed=0
note_fail() { echo "INCOMPLETE: $*" >&2; failed=1; }

# Check who owns the namespace BEFORE deleting anything inside it. A lookup that cannot
# run is "could not determine", a failure, never "gone": we must not delete objects in a
# namespace we did not create. ns_state is one of: absent, owned, foreign, unknown.
ns_label="$(kc get namespace "$NAMESPACE" --ignore-not-found \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"
ns_lookup_rc=$?
ns_exists="$(kc get namespace "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)"
ns_exists_rc=$?
if [[ "$ns_lookup_rc" != 0 || "$ns_exists_rc" != 0 ]]; then
  ns_state=unknown
elif [[ -z "$ns_exists" ]]; then
  ns_state=absent
elif [[ "$ns_label" == "cedar-policy-sample" ]]; then
  ns_state=owned
else
  ns_state=foreign
fi

case "$ns_state" in
  unknown)
    note_fail "could not determine whether namespace $NAMESPACE is this sample's (kubectl lookup failed); deleted nothing"
    ;;
  absent)
    echo "Namespace $NAMESPACE is already gone; nothing to delete."
    ;;
  foreign)
    note_fail "namespace $NAMESPACE is not this sample's (managed-by='$ns_label'); deleted nothing in it"
    ;;
  owned)
    echo "Deleting pod $NAMESPACE/$POD_NAME..."
    kc delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m \
      || note_fail "could not delete pod $POD_NAME"
    kc delete networkpolicy cedar-policy-deny-egress -n "$NAMESPACE" --ignore-not-found \
      || note_fail "could not delete the egress network policy"
    if [[ "$keep_namespace" == true ]]; then
      echo "Kept the $NAMESPACE namespace."
    else
      echo "Deleting namespace $NAMESPACE (carries $MANAGED_BY_LABEL)..."
      kc delete namespace "$NAMESPACE" --wait=true --timeout=5m \
        || note_fail "could not delete namespace $NAMESPACE"
      # Confirm it is gone. --ignore-not-found -o name prints nothing when absent and
      # fails only on a real lookup error, which is "could not confirm", not "gone".
      still="$(kc get namespace "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)"
      still_rc=$?
      if [[ "$still_rc" != 0 ]]; then
        note_fail "could not confirm namespace $NAMESPACE was deleted"
      elif [[ -n "$still" ]]; then
        note_fail "namespace $NAMESPACE still present after delete"
      fi
    fi
    ;;
esac

echo "Deleting the generated policy files under $TMP_DIR..."
rm -f \
  "$TMP_DIR/policy.b64" "$TMP_DIR/policy.raw" "$TMP_DIR/policy.json" \
  "$TMP_DIR/policy.yaml" "$TMP_DIR/rendered-pod.json" "$TMP_DIR/genpolicy.log"

if [[ "$failed" == 0 ]]; then
  echo "Clean up complete."
else
  echo "Clean up finished with items left behind (see INCOMPLETE lines above)." >&2
fi
exit "$failed"
