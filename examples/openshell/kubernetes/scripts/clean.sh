#!/usr/bin/env bash
# clean.sh -- remove everything this sample created: the demo sandbox, the echo API,
# both Helm releases and their namespaces (including the credential namespace and its
# generated Secrets), the admission adapter, and the namespace-scoped RBAC this sample
# added. It leaves the shared isolated-sandbox RuntimeClass and its approval label in
# place, and prints the command that removes the label.
#
# Usage:
#   ./scripts/clean.sh
set -uo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
SAMPLE="openshell-kubernetes"
TMP_DIR="$REPO_ROOT/tmp/$SAMPLE"
STATE_FILE="$TMP_DIR/state.env"

if [[ -f "$STATE_FILE" ]]; then set -a; . "$STATE_FILE"; set +a; fi

GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-openshell-kubernetes}"
SANDBOX_NAMESPACE="${SANDBOX_NAMESPACE:-openshell-kubernetes-sandbox}"
CREDENTIAL_NAMESPACE="${CREDENTIAL_NAMESPACE:-openshell-kubernetes-credentials}"
GATEWAY_RELEASE="${GATEWAY_RELEASE:-openshell}"
WORKSPACE_RELEASE="${WORKSPACE_RELEASE:-${GATEWAY_RELEASE}-workspace}"
ADAPTER="${SAMPLE}-nitro-adapter"
RBAC_GAP="openshell-sandbox-rbac-gap"
incomplete=0

kc() { if [[ -n "${KUBE_CONTEXT:-}" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi; }
say() { printf '\n==> %s\n' "$*"; }

# Prints one of: absent (nothing to do, not a failure), owned (this sample's),
# foreign (exists, labelled as someone else's or not labelled at all), unknown (the
# lookup itself failed, which is never read as "gone").
ns_state() { # <namespace>
  local out rc=0
  out="$(kc get ns "$1" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>&1)" || rc=$?
  if [[ "$rc" == 0 ]]; then
    if [[ "$out" == "$SAMPLE" ]]; then echo owned; else echo foreign; fi
  elif echo "$out" | grep -q "NotFound"; then
    echo absent
  else
    echo unknown
  fi
}
sandbox_ns_state="$(ns_state "$SANDBOX_NAMESPACE")"
gateway_ns_state="$(ns_state "$GATEWAY_NAMESPACE")"

say "the sandbox(es) this run created"
case "$sandbox_ns_state" in
  owned)
    for s in $(kc get sandboxes.agents.x-k8s.io -n "$SANDBOX_NAMESPACE" -o name 2>/dev/null); do
      kc delete "$s" -n "$SANDBOX_NAMESPACE" --wait=false
    done
    kc delete pod node-probe -n "$SANDBOX_NAMESPACE" --ignore-not-found --wait=false
    kc delete pod echo-api -n "$SANDBOX_NAMESPACE" --ignore-not-found --wait=false
    kc delete service echo-api -n "$SANDBOX_NAMESPACE" --ignore-not-found
    ;;
  absent) echo "  $SANDBOX_NAMESPACE is already gone; nothing to do" ;;
  foreign) echo "  $SANDBOX_NAMESPACE exists and is not this sample's; left it alone"; incomplete=1 ;;
  unknown) echo "  could not determine whether $SANDBOX_NAMESPACE exists; left it alone"; incomplete=1 ;;
esac

say "the Helm releases"
case "$gateway_ns_state" in
  owned) helm uninstall "$GATEWAY_RELEASE" -n "$GATEWAY_NAMESPACE" 2>&1 | sed 's/^/  /' || incomplete=1 ;;
  absent) echo "  $GATEWAY_NAMESPACE is already gone; nothing to do" ;;
  foreign) echo "  $GATEWAY_NAMESPACE exists and is not this sample's; left its release alone"; incomplete=1 ;;
  unknown) echo "  could not determine whether $GATEWAY_NAMESPACE exists; left its release alone"; incomplete=1 ;;
esac
if [[ "$sandbox_ns_state" == owned ]]; then
  helm uninstall "$WORKSPACE_RELEASE" -n "$SANDBOX_NAMESPACE" 2>&1 | sed 's/^/  /' || incomplete=1
fi

say "the namespace-scoped admission adapter and RBAC"
for kind in mutatingadmissionpolicybinding mutatingadmissionpolicy; do
  owner="$(kc get "$kind" "$ADAPTER" --ignore-not-found -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"
  if [[ "$owner" == "$SAMPLE" ]]; then
    kc delete "$kind" "$ADAPTER"
  elif [[ -n "$owner" ]]; then
    echo "  $kind $ADAPTER is not this sample's (managed-by='$owner'); left it alone"
    incomplete=1
  fi
done
if [[ "$sandbox_ns_state" == owned ]]; then
  kc delete role "$RBAC_GAP" -n "$SANDBOX_NAMESPACE" --ignore-not-found
  kc delete rolebinding "$RBAC_GAP" -n "$SANDBOX_NAMESPACE" --ignore-not-found
fi

say "the namespaces"
for ns in "$CREDENTIAL_NAMESPACE" "$SANDBOX_NAMESPACE" "$GATEWAY_NAMESPACE"; do
  case "$(ns_state "$ns")" in
    owned) kc delete namespace "$ns" --wait=false; echo "  deleting $ns" ;;
    absent) echo "  $ns is already gone" ;;
    foreign) echo "  $ns exists and is not this sample's; left it alone"; incomplete=1 ;;
    unknown) echo "  could not determine whether $ns exists; left it alone"; incomplete=1 ;;
  esac
done

say "left in place on purpose"
cat <<EOF
  The isolated-sandbox RuntimeClass and its openshell.ai/sandbox-attachable=true label:
  other OpenShell gateways and other samples on this cluster share it. To remove the
  label (only do this if nothing else on the cluster needs it):

    kubectl label runtimeclass isolated-sandbox openshell.ai/sandbox-attachable-
EOF

if [[ "$incomplete" != 0 ]]; then
  echo
  echo "ERROR: clean up could not remove everything; see above." >&2
  exit 1
fi
rm -f "$STATE_FILE"
