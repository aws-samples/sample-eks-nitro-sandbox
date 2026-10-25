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

# The namespace comes from the environment, as on the page, and .env must not override it: it
# is the one value the other scripts also take from the environment, so a copy of it in .env
# would make this script and setup.sh disagree about which namespace the run is in, and the
# mismatch would be baked into the state file where the other guards cannot see it. Sourcing
# assigns unconditionally whatever the order, so the caller's value is kept aside and put back.
namespace_from_caller="${NAMESPACE:-}"

[[ -f .env ]] || { echo "error: .env not found. Copy .env.example to .env and fill it in." >&2; exit 2; }
# shellcheck disable=SC1091
. ./.env
: "${CLUSTER_NAME:?set CLUSTER_NAME in .env}"
: "${AWS_REGION:?set AWS_REGION in .env}"

if [[ -n "$namespace_from_caller" && -n "${NAMESPACE:-}" && "$NAMESPACE" != "$namespace_from_caller" ]]; then
  echo "note: .env sets NAMESPACE=$NAMESPACE; using NAMESPACE=$namespace_from_caller from the environment, as the page's steps do." >&2
fi
NAMESPACE="${namespace_from_caller:-${NAMESPACE:-docker-builds-sample}}"
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

# The state file records each resource as soon as it exists, not at the end: this script can
# stop part way (a refused adoption, a denied call), and whatever it already created must still
# be something scripts/clean.sh can find and remove. ECR_PUSH_READY stays false until the whole
# push is set up, so the build Job will not try to use a half-made credential path.
STATE_REPO="" STATE_ROLE="" STATE_ASSOC="" STATE_READY=false
write_state() {
  {
    printf 'ECR_PUSH_READY=%s\n' "$STATE_READY"
    printf 'ECR_ACCOUNT_ID=%q\n' "$ACCOUNT_ID"
    printf 'ECR_AWS_REGION=%q\n' "$AWS_REGION"
    printf 'ECR_CLUSTER_NAME=%q\n' "$CLUSTER_NAME"
    printf 'ECR_NAMESPACE=%q\n' "$NAMESPACE"
    printf 'ECR_REPO_NAME=%q\n' "$STATE_REPO"
    printf 'ECR_ROLE_NAME=%q\n' "$STATE_ROLE"
    printf 'ECR_POLICY_NAME=%q\n' "$POLICY_NAME"
    printf 'ECR_ASSOCIATION_ID=%q\n' "$STATE_ASSOC"
  } > "$STATE_FILE"
}

# aws_read <description> <command...> : run a read-only AWS call and tell a failure apart from
# an absent resource. Returns 0 when the resource is there, with the call's output in
# AWS_READ_OUT; returns 1 when AWS says it does not exist; and stops the script on any other
# error, because a failed read is "could not determine" and never "absent".
#
# The output comes back in a variable rather than on stdout on purpose. In
# `x="$(aws_read ...)"` the function would run in a subshell, where its `die` exits only that
# subshell: the caller would see an empty value and a non-zero status, which is exactly what
# "does not exist" looks like, and would carry on. Every call below therefore runs aws_read as
# a plain command and reads AWS_READ_OUT.
AWS_READ_OUT=""
aws_read() {
  local what="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  AWS_READ_OUT="$out"
  if [[ $rc -eq 0 ]]; then return 0; fi
  case "$out" in
    *NotFoundException*|*NoSuchEntity*)
      # Covers RepositoryNotFoundException and ResourceNotFoundException too: AWS says "this
      # does not exist", which is the one failure that is not a failure to determine.
      AWS_READ_OUT=""; return 1 ;;
  esac
  die "could not read $what (the call failed, which is not a report that it is missing):
$out
Re-run once AWS answers cleanly."
}

# The cluster, once, so a wrong CLUSTER_NAME is a clear error here rather than a confusing
# "no association" later: eks list-pod-identity-associations answers NotFoundException for a
# cluster that does not exist, which otherwise reads like an empty list.
aws_read "EKS cluster $CLUSTER_NAME" \
  aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.name' \
  || die "the EKS cluster '$CLUSTER_NAME' does not exist in $AWS_REGION. Set CLUSTER_NAME in
.env to the cluster this sample is running on."

echo "Step 1/4: the ECR repository $ECR_REPO_NAME"
if aws_read "ECR repository $ECR_REPO_NAME" \
     aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION"; then
  aws_read "the tags of ECR repository $ECR_REPO_NAME" \
    aws ecr list-tags-for-resource --resource-arn "$REPO_ARN" --region "$AWS_REGION" \
    || die "ECR repository $ECR_REPO_NAME exists but its tags could not be read"
  owner="$(printf '%s' "$AWS_READ_OUT" | jq -r --arg m "$MANAGED_BY" 'any(.tags[]?; .Key=="ManagedBy" and .Value==$m)')"
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
STATE_REPO="$ECR_REPO_NAME"
write_state

echo "Step 2/4: the push role $ROLE_NAME, scoped to that one repository"
sed -e "s|<CLUSTER_NAME>|$CLUSTER_NAME|g" -e "s|<NAMESPACE>|$NAMESPACE|g" \
  -e "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" iam/pod-identity-trust.json > "$tmp_dir/trust.json"
if aws_read "IAM role $ROLE_NAME" aws iam get-role --role-name "$ROLE_NAME"; then
  aws_read "the tags of IAM role $ROLE_NAME" aws iam list-role-tags --role-name "$ROLE_NAME" \
    || die "IAM role $ROLE_NAME exists but its tags could not be read"
  owner="$(printf '%s' "$AWS_READ_OUT" | jq -r --arg m "$MANAGED_BY" 'any(.Tags[]?; .Key=="ManagedBy" and .Value==$m)')"
  [[ "$owner" == "true" ]] || die "IAM role $ROLE_NAME exists but is not tagged ManagedBy=$MANAGED_BY;
refusing to use a role this sample did not create. Set ROLE_NAME to a name of your own."
  STATE_ROLE="$ROLE_NAME"; write_state
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "file://$tmp_dir/trust.json"
  echo "  reusing $ROLE_NAME (tagged ManagedBy=$MANAGED_BY), trust policy refreshed."
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$tmp_dir/trust.json" \
    --tags Key=ManagedBy,Value="$MANAGED_BY" Key=auto-delete,Value=no >/dev/null
  STATE_ROLE="$ROLE_NAME"; write_state
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
# A failed list is not an empty list: creating an association on top of a read that failed
# would be acting on a guess, so the read stops the script instead.
if aws_read "the Pod Identity associations of $NAMESPACE/$SERVICE_ACCOUNT" \
  aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" \
  --query 'associations[0].associationId' --output text; then
  assoc="$AWS_READ_OUT"
else
  assoc=""
fi
if [[ -z "$assoc" || "$assoc" == "None" ]]; then
  assoc="$(aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" --role-arn "$ROLE_ARN" \
    --query 'association.associationId' --output text)"
  STATE_ASSOC="$assoc"; write_state
  echo "  created association $assoc."
else
  aws_read "Pod Identity association $assoc" \
    aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --association-id "$assoc" --query 'association.roleArn' --output text \
    || die "association $assoc was listed and then could not be read"
  bound="$AWS_READ_OUT"
  [[ "$bound" == "$ROLE_ARN" ]] || die "an association for $NAMESPACE/$SERVICE_ACCOUNT already exists ($assoc)
bound to $bound, not this sample's role $ROLE_ARN; refusing to adopt it"
  STATE_ASSOC="$assoc"; write_state
  echo "  reusing association $assoc (bound to this sample's role)."
fi

STATE_READY=true
write_state

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
