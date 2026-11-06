#!/usr/bin/env bash
# Create this sample's resources on an existing cluster; DEPLOYMENT_MODE is nitro or eks.
# Usage: ./scripts/setup.sh
# Required: AWS_REGION and CLUSTER_NAME. Copy .env.example to .env first.
# Defaults: mode nitro; namespace subagent-security-strands-box; model Sonnet 4.5 global.
# Bucket and role default to sample-specific names; KUBE_CONTEXT defaults to the current context.
set -euo pipefail
umask 077
source "$(dirname "$0")/common.sh"
for arg in "$@"; do
  case "$arg" in
    --help|-h) sed -n '2,6p' "$0"; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done
if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; source "$SAMPLE_DIR/.env"; set +a; fi
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-}"
NAMESPACE="${NAMESPACE:-subagent-security-strands-box}"
BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-global.anthropic.claude-sonnet-4-5-20250929-v1:0}"
box_mode
box_require_tools
KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
[[ -n "$KUBE_CONTEXT" ]] || die "KUBE_CONTEXT is empty"
box_preflight
KUBE_SERVER="$(kc config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
cluster="$(aws eks describe-cluster --name "$CLUSTER_NAME" --output json)" ||
  die "could not read CLUSTER_NAME in the selected AWS account and Region"
cluster_server="$(jq -er '.cluster.endpoint' <<<"$cluster")" || die "the cluster response has no endpoint"
[[ -n "$KUBE_SERVER" && "$KUBE_SERVER" == "$cluster_server" ]] ||
  die "KUBE_CONTEXT does not point to CLUSTER_NAME in the selected AWS account and Region"
box_cluster_prerequisites "$cluster"
SAMPLE="$(box_resource_owner)" || die "could not derive this deployment owner"
BUCKET="${BUCKET:-subagent-analyst-$SAMPLE-$ACCOUNT_ID}"
ROLE_NAME="${ROLE_NAME:-subagent-analyst-$SAMPLE}"
SUPPLIER_API_REPOSITORY="pod-isolation/subagent-analyst-$SAMPLE-supplier-api"
ANALYST_REPOSITORY="pod-isolation/subagent-analyst-$SAMPLE"
# Preserve a previous deployment's record when the selected target changes.
expected_target="$(printf '%s\n' "$SAMPLE" "$NAMESPACE" "$CLUSTER_NAME" "$AWS_REGION" \
  "$KUBE_CONTEXT" "$KUBE_SERVER" "$ACCOUNT_ID" "$BUCKET" "$ROLE_NAME" "$DEPLOYMENT_MODE" \
  "$ANALYST_REPOSITORY" "$SUPPLIER_API_REPOSITORY")"
if [[ -f "$STATE_FILE" ]]; then
  saved_target="$(
    unset SAMPLE NAMESPACE CLUSTER_NAME AWS_REGION KUBE_CONTEXT KUBE_SERVER ACCOUNT_ID BUCKET ROLE_NAME DEPLOYMENT_MODE ANALYST_REPOSITORY SUPPLIER_API_REPOSITORY
    source "$STATE_FILE"
    printf '%s\n' "$SAMPLE" "$NAMESPACE" "$CLUSTER_NAME" "$AWS_REGION" \
      "$KUBE_CONTEXT" "${KUBE_SERVER:-}" "${ACCOUNT_ID:-}" "$BUCKET" "$ROLE_NAME" "${DEPLOYMENT_MODE:-nitro}" \
      "${ANALYST_REPOSITORY:-}" "${SUPPLIER_API_REPOSITORY:-}"
  )"
  [[ "$saved_target" == "$expected_target" ]] ||
    die "the existing setup record names another target; clean that deployment before changing .env"
fi
box_namespace_state >/dev/null
# The shared helper checks the association's role. Check ownership before reusing it.
associations="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" --service-account analyst --output json)"
association_count="$(jq -er '.associations | if type=="array" then length else error("invalid response") end' <<<"$associations")"
if [[ "$association_count" == 1 ]]; then
  association_id="$(jq -er '.associations[0].associationId' <<<"$associations")"
  association="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --association-id "$association_id" --output json)"
  require_managed_by "Pod Identity association $association_id" \
    "$(jq -r '.association.tags.ManagedBy // ""' <<<"$association")"
elif [[ "$association_count" != 0 ]]; then
  die "multiple Pod Identity associations match this namespace and service account; changed nothing"
fi
mkdir -p "$TMP_DIR/lookups"
export TMPDIR="$TMP_DIR/lookups"
for name in SAMPLE NAMESPACE CLUSTER_NAME AWS_REGION KUBE_CONTEXT KUBE_SERVER ACCOUNT_ID \
  BUCKET ROLE_NAME BEDROCK_MODEL_ID SUPPLIER_API_REPOSITORY ANALYST_REPOSITORY DEPLOYMENT_MODE; do
  state_put "$name" "${!name}"
done
state_put SETUP_COMPLETE false
analyst_namespace
source "$SAMPLE_DIR/scripts/image.sh"
box_supplier_api
box_bucket
analyst_role
box_image "$ANALYST_REPOSITORY"
state_put ANALYST_IMAGE "$ANALYST_IMAGE"
manifest="$SAMPLE_DIR/deploy/analyst-pod.yaml"
if [[ "$DEPLOYMENT_MODE" == eks ]]; then manifest="$SAMPLE_DIR/deploy/eks-analyst-pod.yaml"; fi
analyst_render "$manifest" "$TMP_DIR/analyst-pod.yaml" \
  "s|<ANALYST_IMAGE>|$ANALYST_IMAGE|g" "s|<AWS_REGION>|$AWS_REGION|g" \
  "s|<BUCKET>|$BUCKET|g" "s|<ROLE_NAME>|$ROLE_NAME|g" "s|<BEDROCK_MODEL_ID>|$BEDROCK_MODEL_ID|g"
[[ "$(box_namespace_state)" == owned ]] || die "the sample namespace disappeared during setup"
kc delete pod analyst -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=3m
kc apply -n "$NAMESPACE" -f "$TMP_DIR/analyst-pod.yaml"
kc wait pod/analyst -n "$NAMESPACE" --for=condition=Ready --timeout=10m
state_put SETUP_COMPLETE true
say "ready: run ./scripts/run.sh"
echo "  setup record: $STATE_FILE"
