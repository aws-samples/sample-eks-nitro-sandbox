#!/usr/bin/env bash
# Generate a confidential Cedar policy for deploy/pod.yaml and start the pod under
# it.
#
#   ./scripts/setup.sh                 # generate the policy, apply the pod, wait for Ready
#   ./scripts/setup.sh --policy-only   # generate and decode the policy files only; touches no cluster
#
# What travels to the guest is the gzipped, base64-encoded JSON policy envelope in
# the sandbox.amazonaws.com/policy annotation, which is not readable by eye. So this
# script also leaves decoded copies under the repository's tmp/ for inspection, and
# commits a readable sample as policy/policy.generated.yaml (refresh it with
# --policy-only; see the README).
#
# This sample creates no AWS resources. It creates one namespace and one pod, each
# marked as the sample's own (the namespace carries a managed-by label, checked by
# clean.sh before it removes anything).
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/cedar-policy"

NAMESPACE="${NAMESPACE:-cedar-policy-sample}"
POD_NAME="${POD_NAME:-cedar-policy-demo}"
MANIFEST="$SAMPLE_DIR/deploy/pod.yaml"
PROFILE="$SAMPLE_DIR/policy/confidential-profile.yaml"
# The command the generator is invoked as. The Amazon EKS User Guide names it
# eks-nitro-sandbox-genpolicy; override GENPOLICY if your copy is named differently.
GENPOLICY="${GENPOLICY:-eks-nitro-sandbox-genpolicy}"

POLICY_B64="$TMP_DIR/policy.b64"
POLICY_RAW="$TMP_DIR/policy.raw"
POLICY_JSON="$TMP_DIR/policy.json"
POLICY_YAML="$TMP_DIR/policy.yaml"
RENDERED="$TMP_DIR/rendered-pod.json"
GENPOLICY_LOG="$TMP_DIR/genpolicy.log"

# The context is named on every kubectl call, never switched with use-context, so a
# run on a shared machine cannot be redirected by another session. Set KUBE_CONTEXT
# to your cluster's context (kubectl config get-contexts).
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
kc() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    kubectl --context "$KUBE_CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

die() { echo "ERROR: $*" >&2; exit 1; }
require_commands() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "$c is required"; done
}

policy_only=false
for arg in "$@"; do
  case "$arg" in
    --policy-only) policy_only=true ;;
    --help|-h)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

require_commands base64 gzip jq "$GENPOLICY"
[[ "$policy_only" == true ]] || require_commands kubectl
command -v "$GENPOLICY" >/dev/null 2>&1 \
  || die "$GENPOLICY is not on PATH. The Amazon EKS User Guide, \"Cedar policies\", names the generator; set GENPOLICY to your copy if it is named differently."

mkdir -p "$TMP_DIR"

echo "== 1/4 generate the confidential Cedar policy from deploy/pod.yaml =="
# The log carries the generator's own summary, including the predicted PCR17. This
# sample does not use PCR17 (it makes no KMS request); the log keeps the two paths
# comparable with the Confidential section's attested-decryption samples.
"$GENPOLICY" \
  --profile "$PROFILE" \
  --output-file-b64 "$POLICY_B64" \
  "$MANIFEST" | tee "$GENPOLICY_LOG"

echo "== 2/4 decode the policy envelope into readable form =="
base64 --decode "$POLICY_B64" > "$POLICY_RAW"
if gzip -t "$POLICY_RAW" >/dev/null 2>&1; then
  gzip -dc "$POLICY_RAW" > "$POLICY_JSON"
else
  cp "$POLICY_RAW" "$POLICY_JSON"
fi
jq -e '
  (.version | type) == "number"
  and (.admission_policy | type) == "string"
  and (.runtime_policy | type) == "string"
' "$POLICY_JSON" >/dev/null || die "the generated policy envelope has an unexpected schema"
# Render the Cedar strings as readable multiline YAML blocks.
jq -r '
  def yaml_block($key):
    .[$key] as $value
    | if ($value | endswith("\n")) then
        "\($key): |+\n" + ($value | rtrimstr("\n") | split("\n") | map("  " + .) | join("\n"))
      else
        "\($key): |-\n" + ($value | split("\n") | map("  " + .) | join("\n"))
      end;
  "version: \(.version)",
  yaml_block("admission_policy"),
  yaml_block("runtime_policy")
' "$POLICY_JSON" > "$POLICY_YAML"
echo "  machine-readable envelope: $POLICY_JSON"
echo "  readable Cedar document:   $POLICY_YAML"

echo "== 3/4 render the pod with its policy annotation =="
# Render locally (--dry-run=client contacts no cluster), so --policy-only stops
# after this step. Keeping the rendered pod on disk shows exactly what was applied.
policy_b64="$(tr -d '\r\n' < "$POLICY_B64")"
# --validate=false keeps this render offline: client-side validation would otherwise
# fetch the cluster's OpenAPI schema, which --policy-only must not need.
kubectl create --dry-run=client --validate=false -o json -f "$MANIFEST" |
  jq \
    --arg namespace "$NAMESPACE" \
    --arg name "$POD_NAME" \
    --arg policy "$policy_b64" \
    '.metadata.namespace = $namespace
     | .metadata.name = $name
     | .metadata.annotations["sandbox.amazonaws.com/policy"] = $policy' \
    > "$RENDERED"
echo "  rendered pod: $RENDERED"

if [[ "$policy_only" == true ]]; then
  echo
  echo "policy generated and pod rendered; the cluster was not touched."
  exit 0
fi

echo "== 4/4 apply the pod and wait for the guest to admit it =="
kc apply -f "$SAMPLE_DIR/deploy/namespace.yaml"
# Replace instead of apply-over: a pod's policy annotation is immutable, so a pod
# left from an earlier run would keep enforcing the earlier policy.
kc delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
# Turn on network policy enforcement once per cluster, then apply the deny-all
# egress policy before the pod, so the pod never has a window with open egress.
kc apply -f "$SAMPLE_DIR/deploy/enable-network-policy.yaml"
kc apply -f "$SAMPLE_DIR/deploy/egress-policy.yaml"
kc apply -f "$RENDERED"
if ! kc wait "pod/$POD_NAME" -n "$NAMESPACE" --for=condition=Ready --timeout=15m; then
  kc get pod "$POD_NAME" -n "$NAMESPACE" -o wide 2>/dev/null || true
  kc describe pod "$POD_NAME" -n "$NAMESPACE" 2>/dev/null | tail -40 || true
  die "the confidential policy demo pod did not become Ready"
fi

echo
echo "$POD_NAME is Ready and enforcing its generated Cedar policy."
echo "Read the policy:   less $POLICY_YAML"
echo "Tear down:         ./scripts/clean.sh"
