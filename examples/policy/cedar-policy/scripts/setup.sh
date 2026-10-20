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
RENDERED_NS="$TMP_DIR/rendered-namespace.json"
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

# kubectl is needed in both modes: --policy-only renders the pod with a client-side
# dry-run, which still invokes kubectl.
require_commands base64 gzip jq kubectl "$GENPOLICY"
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

echo "== 3/4 render the pod and namespace with the chosen NAMESPACE =="
# Render locally (--dry-run=client contacts no cluster), so --policy-only stops
# after this step. Keeping the rendered objects on disk shows exactly what was applied.
#
# Both objects are rendered with $NAMESPACE so an override never touches the default
# name: the committed manifests hard-code the default (so they read cleanly on the
# page), and these renders put the chosen namespace into each. The namespace's
# managed-by label stays "cedar-policy-sample" (the ownership mark names the SAMPLE, not
# the namespace), so clean.sh still recognises an overridden namespace as owned.
policy_b64="$(tr -d '\r\n' < "$POLICY_B64")"
render() {  # render <manifest> <jq-filter> <out>
  # --validate=false keeps this offline: client-side validation would otherwise fetch
  # the cluster's OpenAPI schema, which --policy-only must not need.
  kubectl create --dry-run=client --validate=false -o json -f "$1" | jq "$2" > "$3"
}
render "$MANIFEST" \
  "$(printf '.metadata.namespace = %s | .metadata.name = %s | .metadata.annotations["sandbox.amazonaws.com/policy"] = %s' \
     "$(jq -n --arg v "$NAMESPACE" '$v')" "$(jq -n --arg v "$POD_NAME" '$v')" "$(jq -n --arg v "$policy_b64" '$v')")" \
  "$RENDERED"
render "$SAMPLE_DIR/deploy/namespace.yaml" \
  "$(printf '.metadata.name = %s' "$(jq -n --arg v "$NAMESPACE" '$v')")" \
  "$RENDERED_NS"
echo "  rendered pod:       $RENDERED"
echo "  rendered namespace: $RENDERED_NS"

if [[ "$policy_only" == true ]]; then
  echo
  echo "policy generated and pod rendered; the cluster was not touched."
  exit 0
fi

echo "== 4/4 apply the pod and wait for the guest to admit it =="
# Create the namespace only if it does not exist; reuse it only when it already carries
# this sample's managed-by label; never adopt a same-named namespace another demo owns.
# Why: the label is the ownership mark, and applying over a foreign namespace would add
# the mark and then let the pod delete below act in a namespace this sample does not own.
# Capture inside `if` so `set -e` does not abort on a failed lookup before the die
# below can explain it: a lookup that cannot run is "could not determine", a failure,
# and we must stop with the reason rather than exit on a bare error.
if ns_label="$(kc get namespace "$NAMESPACE" --ignore-not-found \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"; then
  ns_lookup_rc=0
else
  ns_lookup_rc=$?
fi
if ns_exists="$(kc get namespace "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)"; then
  ns_exists_rc=0
else
  ns_exists_rc=$?
fi
[[ "$ns_lookup_rc" == 0 && "$ns_exists_rc" == 0 ]] \
  || die "could not determine whether namespace $NAMESPACE already exists (kubectl lookup failed; check the context and permissions); created nothing"
if [[ -z "$ns_exists" ]]; then
  kc apply -f "$RENDERED_NS"
elif [[ "$ns_label" != "cedar-policy-sample" ]]; then
  die "namespace $NAMESPACE already exists and is not this sample's (managed-by='$ns_label'); created nothing. Delete it, or re-run with NAMESPACE set to a name no other workload uses."
else
  echo "  reusing namespace $NAMESPACE (carries this sample's managed-by label)"
fi
# This workload boots network-isolated, so it has no network and needs no network
# policy: there is no cluster-wide enforcement prerequisite to check and nothing to
# apply before the pod.
# Replace instead of apply-over: a pod's policy annotation is immutable, so a pod
# left from an earlier run would keep enforcing the earlier policy.
kc delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
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
