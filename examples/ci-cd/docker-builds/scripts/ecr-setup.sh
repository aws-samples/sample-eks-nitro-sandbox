#!/usr/bin/env bash
# Optional: set up the Amazon ECR push for the build Job, with no stored credential.
#
#   ./scripts/ecr-setup.sh
#
# It creates (or adopts, when they already carry this sample's ManagedBy tag):
#   - an ECR repository for the image the build pushes;
#   - an IAM role whose permission policy names that one repository ARN and allows only the
#     actions a push needs;
#   - an EKS Pod Identity association binding the role to the sample's ServiceAccount;
# and then adds the two egress rules the push needs to the sample's network policy.
#
# It reads .env (copy .env.example) for CLUSTER_NAME and AWS_REGION, and records what it
# created in .docker-builds.state so scripts/clean.sh removes only that.
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SAMPLE_DIR"

# The namespace comes from the environment, as on the page, and .env never overrides it: it is
# the one value the other scripts also take from the environment, so a copy in .env would make
# this script and setup.sh disagree about which namespace the run is in.
NAMESPACE="${NAMESPACE:-docker-builds-sample}"

[[ -f .env ]] || { echo "error: .env not found. Copy .env.example to .env and fill it in." >&2; exit 2; }
# shellcheck disable=SC1091
. ./.env
: "${CLUSTER_NAME:?set CLUSTER_NAME in .env}"
: "${AWS_REGION:?set AWS_REGION in .env}"
MANAGED_BY="docker-builds"
SAMPLE_LABEL_JSONPATH='app\.kubernetes\.io/part-of'
SERVICE_ACCOUNT="docker-builds-builder"
ECR_REPO_NAME="${ECR_REPO_NAME:-nitro-sample-docker-builds}"
ROLE_NAME="${ROLE_NAME:-nitro-sample-docker-builds-push}"
POLICY_NAME="docker-builds-ecr-push"
STATE_FILE="$SAMPLE_DIR/.docker-builds.state"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

KUBE_CONTEXT="${KUBE_CONTEXT:-}"
kc() { if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi; }
for c in aws kubectl jq; do command -v "$c" >/dev/null 2>&1 || die "$c is required"; done

mark="$(kc get namespace "$NAMESPACE" -o "jsonpath={.metadata.labels.$SAMPLE_LABEL_JSONPATH}" 2>/dev/null || true)"
[[ "$mark" == "docker-builds" ]] || die "namespace '$NAMESPACE' is not this sample's; run ./scripts/setup.sh first"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
REPO_ARN="arn:aws:ecr:${AWS_REGION}:${ACCOUNT_ID}:repository/${ECR_REPO_NAME}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo "Account $ACCOUNT_ID, Region $AWS_REGION, cluster $CLUSTER_NAME."

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

echo "Step 1/4: the ECR repository $ECR_REPO_NAME"
if aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  owner="$(aws ecr list-tags-for-resource --resource-arn "$REPO_ARN" --region "$AWS_REGION" \
    | jq -r --arg m "$MANAGED_BY" 'any(.tags[]?; .Key=="ManagedBy" and .Value==$m)')"
  [[ "$owner" == "true" ]] || die "ECR repository $ECR_REPO_NAME exists but is not tagged ManagedBy=$MANAGED_BY;
refusing to use a repository this sample did not create. Set ECR_REPO_NAME to a name of your own."
  echo "  reusing $ECR_REPO_NAME (tagged ManagedBy=$MANAGED_BY)."
else
  aws ecr create-repository --repository-name "$ECR_REPO_NAME" --region "$AWS_REGION" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    --tags Key=ManagedBy,Value="$MANAGED_BY" Key=auto-delete,Value=no >/dev/null
  echo "  created $ECR_REPO_NAME."
fi

echo "Step 2/4: the push role $ROLE_NAME, scoped to that one repository"
sed -e "s|<CLUSTER_NAME>|$CLUSTER_NAME|g" -e "s|<NAMESPACE>|$NAMESPACE|g" \
  iam/pod-identity-trust.json > "$tmp_dir/trust.json"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  owner="$(aws iam list-role-tags --role-name "$ROLE_NAME" \
    | jq -r --arg m "$MANAGED_BY" 'any(.Tags[]?; .Key=="ManagedBy" and .Value==$m)')"
  [[ "$owner" == "true" ]] || die "IAM role $ROLE_NAME exists but is not tagged ManagedBy=$MANAGED_BY;
refusing to use a role this sample did not create. Set ROLE_NAME to a name of your own."
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "file://$tmp_dir/trust.json"
  echo "  reusing $ROLE_NAME (tagged ManagedBy=$MANAGED_BY), trust policy refreshed."
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$tmp_dir/trust.json" \
    --tags Key=ManagedBy,Value="$MANAGED_BY" Key=auto-delete,Value=no >/dev/null
  echo "  created $ROLE_NAME."
fi
sed -e "s|<AWS_REGION>|$AWS_REGION|g" -e "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" -e "s|<ECR_REPO>|$ECR_REPO_NAME|g" \
  iam/ecr-push-policy.json > "$tmp_dir/push.json"
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY_NAME" \
  --policy-document "file://$tmp_dir/push.json"
# Keep the role least privilege even when it was adopted: exactly this one inline policy and
# no attached managed policies, so "scoped to one repository" stays true of the live role.
attached="$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'length(AttachedPolicies)' --output text)"
[[ "$attached" == "0" ]] || die "$ROLE_NAME must have no attached managed policies (found $attached)"
inline="$(aws iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames' --output json | jq -r 'join(",")')"
[[ "$inline" == "$POLICY_NAME" ]] || die "$ROLE_NAME must carry exactly one inline policy ($POLICY_NAME); found: [$inline]"
echo "  the role's one policy:"
aws iam get-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY_NAME" \
  --query 'PolicyDocument' --output json | sed 's/^/    /'

echo "Step 3/4: the EKS Pod Identity association for $NAMESPACE/$SERVICE_ACCOUNT"
assoc="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" \
  --query 'associations[0].associationId' --output text 2>/dev/null || true)"
if [[ -z "$assoc" || "$assoc" == "None" ]]; then
  assoc="$(aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" --role-arn "$ROLE_ARN" \
    --query 'association.associationId' --output text)"
  echo "  created association $assoc."
else
  bound="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --association-id "$assoc" --query 'association.roleArn' --output text)"
  [[ "$bound" == "$ROLE_ARN" ]] || die "an association for $NAMESPACE/$SERVICE_ACCOUNT already exists ($assoc)
bound to $bound, not this sample's role $ROLE_ARN; refusing to adopt it"
  echo "  reusing association $assoc (bound to this sample's role)."
fi

{
  printf 'ECR_PUSH_READY=true\n'
  printf 'ECR_ACCOUNT_ID=%q\n' "$ACCOUNT_ID"
  printf 'ECR_AWS_REGION=%q\n' "$AWS_REGION"
  printf 'ECR_REPO_NAME=%q\n' "$ECR_REPO_NAME"
  printf 'ECR_ROLE_NAME=%q\n' "$ROLE_NAME"
  printf 'ECR_POLICY_NAME=%q\n' "$POLICY_NAME"
  printf 'ECR_CLUSTER_NAME=%q\n' "$CLUSTER_NAME"
  printf 'ECR_ASSOCIATION_ID=%q\n' "$assoc"
  printf 'ECR_NAMESPACE=%q\n' "$NAMESPACE"
} > "$STATE_FILE"

echo "Step 4/4: add the push rules to the egress policy"
coredns="$(kc get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}')"
[[ -n "$coredns" ]] || die "could not read the CoreDNS Service address (kube-system/kube-dns)"
push_rules="$(sed -e "s|<AWS_REGION>|$AWS_REGION|g" -e "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" deploy/egress-push-rules.yaml)"
sed -e "s|<NAMESPACE>|$NAMESPACE|g" deploy/egress-policy.yaml \
  | awk -v rules="$push_rules" '{ if ($0 == "<ECR_PUSH_RULES>") print rules; else print }' \
  | sed -e "s|<COREDNS_IP>|$coredns|g" \
  | kc apply -f -

echo
echo "The push is ready: $REGISTRY/$ECR_REPO_NAME"
echo "Run the build with the push: NAMESPACE=$NAMESPACE ./scripts/run-build-job.sh --push"
