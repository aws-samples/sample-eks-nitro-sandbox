#!/usr/bin/env bash
# Build one image, push it to two ECR repositories, sign ONLY one copy with AWS
# Signer, create the in-guest verifier's Pod Identity role, turn on network policy
# enforcement, apply the egress policy, and launch the three pods this sample
# compares. Run it from this sample's folder.
#
#   ./scripts/setup.sh    create everything and wait until the pods are Ready
#
# Tear down with ./scripts/clean.sh (add --delete-aws-resources to remove the ECR
# repositories, the IAM role and the AWS Signer signing profile).
#
# Idempotent: resources this sample owns (tagged ManagedBy) are adopted, not
# recreated. State (resource IDs and which ones this run created) is recorded in
# .image-signing.state so clean.sh removes only what setup.sh made.
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SAMPLE_DIR"

# --- configuration ---------------------------------------------------------
[[ -f .env ]] || { echo "ERROR: .env not found. Copy .env.example to .env and fill it in." >&2; exit 2; }
# shellcheck disable=SC1091
. ./.env
: "${CLUSTER_NAME:?set CLUSTER_NAME in .env}"
: "${AWS_REGION:?set AWS_REGION in .env}"

MANAGED_BY="eks-nitro-sandbox-image-signing-sample"
NAMESPACE="image-signing-sample"
SERVICE_ACCOUNT="image-signing-verifier"
# AWS Signer keeps a CANCELED signing profile until its signatures expire (about
# 141 months by default; see the AWS Signer developer guide, "Data retention") and
# refuses put-signing-profile on a name that still exists in any state. So the
# profile name comes from .env: if you run clean.sh --delete-aws-resources (which
# cancels the profile) and then setup.sh again, pick a NEW SIGNING_PROFILE in .env,
# because the canceled name cannot be reused.
SIGNING_PROFILE="${SIGNING_PROFILE:-nitro_sample_image_signing}"
SIGNING_PLATFORM_ID="Notation-OCI-SHA384-ECDSA"
SIGNER_PLUGIN_ID="com.amazonaws.signer.notation.plugin"
ECR_REPO_SIGNED="nitro-sample-image-signing-signed"
ECR_REPO_UNSIGNED="nitro-sample-image-signing-unsigned"
ROLE_NAME="nitro-sample-image-signing-verify"
ECR_POLICY_NAME="image-signing-ecr-read"
STATE_FILE="$SAMPLE_DIR/.image-signing.state"
PODS=(verify-signed verify-unsigned verify-signed-denied)

case "$(uname -m)" in
  x86_64|amd64) SIGNER_ARCH=amd64 ;;
  aarch64|arm64) SIGNER_ARCH=arm64 ;;
  *) echo "ERROR: unsupported host architecture $(uname -m)" >&2; exit 2 ;;
esac
SIGNER_PLUGIN_URL="https://d2hvyiie56hcat.cloudfront.net/linux/${SIGNER_ARCH}/plugin/latest/notation-aws-signer-plugin.zip"
ECR_CRED_HELPER_VERSION="${ECR_CRED_HELPER_VERSION:-0.12.0}"

for c in aws docker notation kubectl jq curl; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 2; }
done
kubectl get runtimeclass isolated-sandbox >/dev/null 2>&1 \
  || { echo "ERROR: runtimeclass isolated-sandbox not found on this cluster" >&2; exit 2; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
SIGNING_PROFILE_ARN="arn:aws:signer:${AWS_REGION}:${ACCOUNT_ID}:/signing-profiles/${SIGNING_PROFILE}"
echo "Identity: account ${ACCOUNT_ID}, region ${AWS_REGION}, cluster ${CLUSTER_NAME}"

# --- state -----------------------------------------------------------------
CREATED_ECR_SIGNED=false CREATED_ECR_UNSIGNED=false
CREATED_IAM_ROLE=false CREATED_SIGNING_PROFILE=false
SIGNED_IMAGE_URI="" UNSIGNED_IMAGE_URI="" SIGNER_PLUGIN_VERSION=""
# shellcheck disable=SC1090
[[ -f "$STATE_FILE" ]] && . "$STATE_FILE"
write_state() {
  {
    printf 'ACCOUNT_ID=%q\n' "$ACCOUNT_ID"
    printf 'SIGNED_IMAGE_URI=%q\n' "$SIGNED_IMAGE_URI"
    printf 'UNSIGNED_IMAGE_URI=%q\n' "$UNSIGNED_IMAGE_URI"
    printf 'SIGNER_PLUGIN_VERSION=%q\n' "$SIGNER_PLUGIN_VERSION"
    printf 'CREATED_ECR_SIGNED=%q\n' "$CREATED_ECR_SIGNED"
    printf 'CREATED_ECR_UNSIGNED=%q\n' "$CREATED_ECR_UNSIGNED"
    printf 'CREATED_IAM_ROLE=%q\n' "$CREATED_IAM_ROLE"
    printf 'CREATED_SIGNING_PROFILE=%q\n' "$CREATED_SIGNING_PROFILE"
  } > "$STATE_FILE"
}

step() { printf '\n=== %s ===\n' "$*"; }

# --- 1/8 signing profile ---------------------------------------------------
step "1/8 ensure the AWS Signer signing profile"
profile_status="$(aws signer get-signing-profile --profile-name "$SIGNING_PROFILE" \
  --region "$AWS_REGION" --query 'status' --output text 2>/dev/null || true)"
if [[ "$profile_status" == "Active" ]]; then
  managed="$(aws signer list-tags-for-resource --resource-arn "$SIGNING_PROFILE_ARN" \
    --region "$AWS_REGION" 2>/dev/null | jq -r --arg m "$MANAGED_BY" '.tags.ManagedBy == $m')"
  [[ "$managed" == "true" ]] || { echo "ERROR: signing profile $SIGNING_PROFILE exists but is not tagged ManagedBy=$MANAGED_BY" >&2; exit 1; }
  CREATED_SIGNING_PROFILE=true
  echo "signing profile $SIGNING_PROFILE already active (owned by this sample)."
elif [[ -n "$profile_status" && "$profile_status" != "None" ]]; then
  # The name exists in a non-Active state (e.g. Canceled). AWS Signer keeps a
  # canceled profile until its signatures expire and refuses put-signing-profile
  # on a name that still exists, so this name cannot be reused.
  echo "ERROR: signing profile $SIGNING_PROFILE already exists with status '$profile_status' and cannot be reused." >&2
  echo "       AWS Signer keeps a canceled profile until its signatures expire. Set a new" >&2
  echo "       SIGNING_PROFILE in .env (a name not used before) and run setup.sh again." >&2
  exit 1
else
  aws signer put-signing-profile --profile-name "$SIGNING_PROFILE" \
    --platform-id "$SIGNING_PLATFORM_ID" \
    --tags "ManagedBy=$MANAGED_BY,auto-delete=no" --region "$AWS_REGION" >/dev/null
  CREATED_SIGNING_PROFILE=true
  echo "created signing profile $SIGNING_PROFILE ($SIGNING_PLATFORM_ID)."
fi

# --- 2/8 ECR repositories --------------------------------------------------
ensure_repo() {  # ensure_repo <name> <created-var-name>
  local name="$1" flagvar="$2"
  if aws ecr describe-repositories --repository-names "$name" --region "$AWS_REGION" >/dev/null 2>&1; then
    local managed
    managed="$(aws ecr list-tags-for-resource \
      --resource-arn "arn:aws:ecr:${AWS_REGION}:${ACCOUNT_ID}:repository/${name}" --region "$AWS_REGION" \
      | jq -r --arg m "$MANAGED_BY" 'any(.tags[]?; .Key=="ManagedBy" and .Value==$m)')"
    [[ "$managed" == "true" ]] || { echo "ERROR: ECR repository $name exists but is not tagged ManagedBy=$MANAGED_BY" >&2; exit 1; }
    printf -v "$flagvar" true
  else
    aws ecr create-repository --repository-name "$name" \
      --image-tag-mutability IMMUTABLE \
      --image-scanning-configuration scanOnPush=true \
      --encryption-configuration encryptionType=AES256 \
      --tags Key=ManagedBy,Value="$MANAGED_BY" Key=auto-delete,Value=no --region "$AWS_REGION" >/dev/null
    printf -v "$flagvar" true
  fi
}
step "2/8 ensure the ECR repositories"
ensure_repo "$ECR_REPO_SIGNED" CREATED_ECR_SIGNED
ensure_repo "$ECR_REPO_UNSIGNED" CREATED_ECR_UNSIGNED
write_state

# --- 3/8 build and push ----------------------------------------------------
step "3/8 build the image and push to both repositories"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/docker" "$tmp_dir/bin"
if ! command -v docker-credential-ecr-login >/dev/null 2>&1; then
  curl -fsSL -o "$tmp_dir/bin/docker-credential-ecr-login" \
    "https://amazon-ecr-credential-helper-releases.s3.us-east-2.amazonaws.com/${ECR_CRED_HELPER_VERSION}/linux-${SIGNER_ARCH}/docker-credential-ecr-login"
  chmod +x "$tmp_dir/bin/docker-credential-ecr-login"
  export PATH="$tmp_dir/bin:$PATH"
fi
printf '{"credHelpers":{"%s":"ecr-login"}}\n' "$REGISTRY" > "$tmp_dir/docker/config.json"
export DOCKER_CONFIG="$tmp_dir/docker"

tag_exists() { aws ecr describe-images --repository-name "$1" --image-ids imageTag=v1 --region "$AWS_REGION" >/dev/null 2>&1; }
signed_has=false; tag_exists "$ECR_REPO_SIGNED"   && signed_has=true
unsigned_has=false; tag_exists "$ECR_REPO_UNSIGNED" && unsigned_has=true
build_tag="$REGISTRY/${ECR_REPO_SIGNED}:v1"
unsigned_tag="$REGISTRY/${ECR_REPO_UNSIGNED}:v1"
if [[ "$signed_has" == "true" && "$unsigned_has" == "true" ]]; then
  echo "image :v1 already present in both repositories; adopting it (no rebuild)."
else
  DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}" docker build --platform linux/amd64 \
    --build-arg "SIGNING_PROFILE_ARN=$SIGNING_PROFILE_ARN" \
    --build-arg "REGISTRY=$REGISTRY" \
    --tag "$build_tag" "$SAMPLE_DIR"
  [[ "$signed_has" == "true" ]] || docker --config "$tmp_dir/docker" push "$build_tag"
  if [[ "$unsigned_has" != "true" ]]; then
    docker tag "$build_tag" "$unsigned_tag"
    docker --config "$tmp_dir/docker" push "$unsigned_tag"
  fi
fi

resolve_digest() { aws ecr describe-images --repository-name "$1" --image-ids imageTag=v1 --region "$AWS_REGION" --query 'imageDetails[0].imageDigest' --output text; }
signed_digest="$(resolve_digest "$ECR_REPO_SIGNED")"
unsigned_digest="$(resolve_digest "$ECR_REPO_UNSIGNED")"
SIGNED_IMAGE_URI="$REGISTRY/${ECR_REPO_SIGNED}@${signed_digest}"
UNSIGNED_IMAGE_URI="$REGISTRY/${ECR_REPO_UNSIGNED}@${unsigned_digest}"

# --- 4/8 sign ONLY the signed copy -----------------------------------------
step "4/8 sign the image in $ECR_REPO_SIGNED with AWS Signer"
if ! notation plugin ls 2>/dev/null | grep -q "$SIGNER_PLUGIN_ID"; then
  echo "installing the AWS Signer notation plugin on the host ($SIGNER_ARCH)..."
  curl -fsSL -o "$tmp_dir/signer-plugin.zip" "$SIGNER_PLUGIN_URL"
  notation plugin install --file "$tmp_dir/signer-plugin.zip" --force
fi
# The plugin version is column 3 (after NAME and the two-word DESCRIPTION the CLI
# pads to a fixed width); the trailing CAPABILITIES column contains spaces, so take
# the first dotted-version token on the plugin's row rather than a column offset.
SIGNER_PLUGIN_VERSION="$(notation plugin ls 2>/dev/null | awk -v id="$SIGNER_PLUGIN_ID" '$1==id {for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}')"
echo "AWS Signer plugin version: ${SIGNER_PLUGIN_VERSION:-unknown}"
sig_listing=""
if sig_listing="$(notation ls "$SIGNED_IMAGE_URI" 2>/dev/null)" \
   && printf '%s' "$sig_listing" | grep -q 'application/vnd.cncf.notary.signature'; then
  echo "$SIGNED_IMAGE_URI already has a Notary signature referrer; skipping notation sign."
else
  notation sign "$SIGNED_IMAGE_URI" \
    --plugin "$SIGNER_PLUGIN_ID" \
    --id "$SIGNING_PROFILE_ARN" \
    --plugin-config "aws-region=$AWS_REGION"
  echo "signed $SIGNED_IMAGE_URI (the $ECR_REPO_UNSIGNED copy is deliberately left unsigned)."
  sig_listing="$(notation ls "$SIGNED_IMAGE_URI" 2>/dev/null || true)"
  printf '%s' "$sig_listing" | grep -q 'application/vnd.cncf.notary.signature' \
    || { echo "ERROR: notation sign reported success but no signature referrer is present" >&2; exit 1; }
fi
write_state

# --- 5/8 in-guest verifier IAM role + Pod Identity association -------------
step "5/8 ensure the in-guest verifier Pod Identity role"
sed -e "s|<CLUSTER_NAME>|$CLUSTER_NAME|g" -e "s|<NAMESPACE>|$NAMESPACE|g" \
  iam/pod-identity-trust.json > "$tmp_dir/trust.json"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  managed="$(aws iam list-role-tags --role-name "$ROLE_NAME" \
    | jq -r --arg m "$MANAGED_BY" 'any(.Tags[]?; .Key=="ManagedBy" and .Value==$m)')"
  [[ "$managed" == "true" ]] || { echo "ERROR: IAM role $ROLE_NAME exists but is not tagged ManagedBy=$MANAGED_BY" >&2; exit 1; }
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "file://$tmp_dir/trust.json"
  CREATED_IAM_ROLE=true
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$tmp_dir/trust.json" \
    --tags Key=ManagedBy,Value="$MANAGED_BY" Key=auto-delete,Value=no >/dev/null
  CREATED_IAM_ROLE=true
fi
sed -e "s|<AWS_REGION>|$AWS_REGION|g" -e "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" \
  iam/ecr-read-policy.json > "$tmp_dir/ecr-read.json"
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "$ECR_POLICY_NAME" --policy-document "file://$tmp_dir/ecr-read.json" >/dev/null
# Keep least privilege even when the role was adopted: it must carry EXACTLY our one
# inline policy and NO attached managed policies. An adopted role could otherwise keep
# a pre-existing inline policy (for example signer:*), which would silently break the
# "the role holds no AWS Signer permissions" claim. Fail closed if anything else is there.
attached="$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'length(AttachedPolicies)' --output text)"
[[ "$attached" == "0" ]] || { echo "ERROR: $ROLE_NAME must have no attached managed policies (found $attached)" >&2; exit 1; }
inline="$(aws iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames' --output json | jq -r 'join(",")')"
[[ "$inline" == "$ECR_POLICY_NAME" ]] \
  || { echo "ERROR: $ROLE_NAME must carry exactly one inline policy ($ECR_POLICY_NAME); found: [$inline]" >&2; exit 1; }
write_state

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
kubectl apply -f deploy/namespace.yaml
kubectl apply -f deploy/service-account.yaml
existing_assoc="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" --region "$AWS_REGION" \
  --query 'associations[0].associationId' --output text 2>/dev/null)"
if [[ -z "$existing_assoc" || "$existing_assoc" == "None" ]]; then
  aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" \
    --role-arn "$ROLE_ARN" --region "$AWS_REGION" >/dev/null
  echo "created Pod Identity association for $SERVICE_ACCOUNT."
else
  # Adopt only an association that points at OUR role, so clean.sh never deletes
  # one some other owner created for this namespace and service account.
  bound_arn="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --association-id "$existing_assoc" --region "$AWS_REGION" \
    --query 'association.roleArn' --output text 2>/dev/null)"
  [[ "$bound_arn" == "$ROLE_ARN" ]] \
    || { echo "ERROR: a Pod Identity association for $NAMESPACE/$SERVICE_ACCOUNT already exists ($existing_assoc) bound to $bound_arn, not this sample's role $ROLE_ARN; refusing to adopt it" >&2; exit 1; }
  echo "Pod Identity association already present for $SERVICE_ACCOUNT (bound to this sample's role)."
fi

# --- 6/8 network policy enforcement + egress policy ------------------------
step "6/8 turn on network policy enforcement and apply the egress policy"
kubectl apply -f deploy/enable-network-policy.yaml
COREDNS_IP="$(kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}')"
# ECR serves image layers and the Notation signature blob from Amazon S3 through a
# presigned URL whose host rotates across the whole S3 regional range, which a
# domainNames rule cannot pin. Allow S3 by its AWS-managed prefix list CIDRs.
s3_pl_id="$(aws ec2 describe-managed-prefix-lists --region "$AWS_REGION" \
  --filters "Name=prefix-list-name,Values=com.amazonaws.${AWS_REGION}.s3" \
  --query 'PrefixLists[0].PrefixListId' --output text)"
[[ -n "$s3_pl_id" && "$s3_pl_id" != "None" ]] || { echo "ERROR: could not find the S3 managed prefix list for $AWS_REGION" >&2; exit 1; }
s3_cidrs="$(aws ec2 get-managed-prefix-list-entries --region "$AWS_REGION" \
  --prefix-list-id "$s3_pl_id" --query 'Entries[].Cidr' --output text \
  | tr '\t' '\n' | sed 's/^/        - ipBlock: { cidr: /; s/$/ }/')"
# Write the rendered policy to the state tmp dir, then apply it (keeps secrets out
# of the command line and lets the reader see what was applied).
awk -v cidrs="$s3_cidrs" '{ if ($0=="<S3_CIDRS>") print cidrs; else print }' deploy/egress-policy.yaml \
  | sed -e "s|<COREDNS_IP>|$COREDNS_IP|" -e "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" \
  | kubectl apply -f -
echo "waiting for the egress PolicyEndpoint..."
until kubectl -n "$NAMESPACE" get policyendpoints -o name 2>/dev/null | grep -q 'image-signing-egress'; do sleep 2; done
kubectl -n "$NAMESPACE" get applicationnetworkpolicies,policyendpoints

# --- 7/8 render and apply the workloads ------------------------------------
step "7/8 apply the three pods"
rendered="$tmp_dir/workloads.rendered.yaml"
sed -e "s|POSITIVE_IMAGE_URI|$SIGNED_IMAGE_URI|g" \
    -e "s|NEGATIVE_IMAGE_URI|$UNSIGNED_IMAGE_URI|g" \
    -e "s|DEMO_AWS_REGION|$AWS_REGION|g" \
    deploy/workloads.yaml > "$rendered"
kubectl apply -f "$rendered"

# --- 8/8 wait --------------------------------------------------------------
step "8/8 wait for all three guest VMs to boot"
for p in "${PODS[@]}"; do
  kubectl -n "$NAMESPACE" wait "pod/$p" --for=condition=Ready --timeout=300s \
    || { echo "ERROR: pod/$p never became Ready; check 'kubectl -n $NAMESPACE describe pod $p'" >&2; exit 1; }
done

printf '\nimage-signing sample is up in namespace %s.\n' "$NAMESPACE"
echo "Run the verification steps on the page, then tear down with ./scripts/clean.sh"
