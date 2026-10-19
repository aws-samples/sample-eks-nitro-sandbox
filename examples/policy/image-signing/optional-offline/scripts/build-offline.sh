#!/usr/bin/env bash
# Optional variant: build and push the offline verifier image, then launch a
# network-isolated pod that verifies the signature with no network at all.
#
# Run the main sample's ./scripts/setup.sh first (it signs the image and writes
# .image-signing.state). Then run this from the optional-offline folder:
#
#   ./scripts/build-offline.sh
#
# It uses `oras` to copy the signed image and its AWS Signer signature from ECR
# into a local OCI layout, bakes that layout into the offline verifier image,
# pushes the image to its own ECR repository, and starts the network-isolated pod.
set -euo pipefail

OPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SAMPLE_DIR="$(cd "$OPT_DIR/.." && pwd)"
cd "$OPT_DIR"

[[ -f "$SAMPLE_DIR/.env" ]] || { echo "ERROR: $SAMPLE_DIR/.env not found; set up the main sample first." >&2; exit 2; }
# shellcheck disable=SC1091
. "$SAMPLE_DIR/.env"
[[ -f "$SAMPLE_DIR/.image-signing.state" ]] || { echo "ERROR: run the main ./scripts/setup.sh first (no .image-signing.state)." >&2; exit 2; }
# shellcheck disable=SC1091
. "$SAMPLE_DIR/.image-signing.state"
: "${CLUSTER_NAME:?}" "${AWS_REGION:?}" "${SIGNED_IMAGE_URI:?}"

MANAGED_BY="eks-nitro-sandbox-image-signing-sample"
NAMESPACE="image-signing-sample"
ECR_REPO_OFFLINE="nitro-sample-image-signing-offline"
ORAS_VERSION="${ORAS_VERSION:-1.3.0}"
STATE_FILE="$OPT_DIR/.image-signing-offline.state"
# Must match the profile setup.sh signed with, which comes from .env. Pinning the
# wrong name here bakes a trust policy that rejects the signature, so read it the
# same way setup.sh does.
SIGNING_PROFILE="${SIGNING_PROFILE:-nitro_sample_image_signing}"

for c in aws docker kubectl; do command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 2; }; done
case "$(uname -m)" in x86_64|amd64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) echo "ERROR: unsupported arch" >&2; exit 2 ;; esac

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
SIGNING_PROFILE_ARN="arn:aws:signer:${AWS_REGION}:${ACCOUNT_ID}:/signing-profiles/${SIGNING_PROFILE}"
SCOPE="${REGISTRY}/nitro-sample-image-signing-signed"
DIGEST="${SIGNED_IMAGE_URI##*@}"

tmp_dir="$(mktemp -d)"; trap 'rm -rf "$tmp_dir"' EXIT

echo "=== fetch oras ==="
if ! command -v oras >/dev/null 2>&1; then
  curl -fsSL -o "$tmp_dir/oras.tgz" "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_${ARCH}.tar.gz"
  tar -xzf "$tmp_dir/oras.tgz" -C "$tmp_dir" oras
  ORAS="$tmp_dir/oras"
else
  ORAS="$(command -v oras)"
fi

echo "=== stage the signed image + signature into an on-disk OCI layout ==="
rm -rf layout
aws ecr get-login-password --region "$AWS_REGION" \
  | "$ORAS" login --username AWS --password-stdin "$REGISTRY"
# The layout's artifact path must equal the trust-policy scope, so notation's
# scope match works offline.
"$ORAS" cp --recursive "$SIGNED_IMAGE_URI" --to-oci-layout "layout/nitro-sample-image-signing-signed:v1"

echo "=== ensure the offline ECR repository ==="
if ! aws ecr describe-repositories --repository-names "$ECR_REPO_OFFLINE" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws ecr create-repository --repository-name "$ECR_REPO_OFFLINE" \
    --image-tag-mutability IMMUTABLE --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    --tags Key=ManagedBy,Value="$MANAGED_BY" Key=auto-delete,Value=no --region "$AWS_REGION" >/dev/null
fi
printf 'ECR_REPO_OFFLINE=%q\nCREATED_OFFLINE_REPO=true\n' "$ECR_REPO_OFFLINE" > "$STATE_FILE"

echo "=== build and push the offline verifier image ==="
mkdir -p "$tmp_dir/docker"
printf '{"credHelpers":{"%s":"ecr-login"}}\n' "$REGISTRY" > "$tmp_dir/docker/config.json"
# docker-credential-ecr-login may not be on PATH; the main build already fetched
# it to a tmp dir, but here fall back to a short-lived password login.
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null 2>&1
# Tag by the signed image's digest, not a fixed :v1. The repository is IMMUTABLE,
# so a fixed tag could never be rebuilt after a change (for example a new signing
# profile in the trust policy); a digest-derived tag is unique per signed image and
# lets a re-run push a fresh image that bakes the current trust policy.
off_tag_name="sig-${DIGEST#sha256:}"
off_tag_name="${off_tag_name:0:20}"
off_tag="$REGISTRY/${ECR_REPO_OFFLINE}:${off_tag_name}"
if ! aws ecr describe-images --repository-name "$ECR_REPO_OFFLINE" --image-ids "imageTag=$off_tag_name" --region "$AWS_REGION" >/dev/null 2>&1; then
  DOCKER_BUILDKIT=1 docker build --platform linux/amd64 \
    --build-arg "SIGNING_PROFILE_ARN=$SIGNING_PROFILE_ARN" \
    --build-arg "LAYOUT_SCOPE=$SCOPE" \
    --tag "$off_tag" "$OPT_DIR"
  docker push "$off_tag"
fi
docker logout "$REGISTRY" >/dev/null 2>&1 || true
off_digest="$(aws ecr describe-images --repository-name "$ECR_REPO_OFFLINE" --image-ids "imageTag=$off_tag_name" --region "$AWS_REGION" --query 'imageDetails[0].imageDigest' --output text)"
OFFLINE_IMAGE_URI="$REGISTRY/${ECR_REPO_OFFLINE}@${off_digest}"

echo "=== launch the network-isolated offline verifier pod ==="
sed -e "s|OFFLINE_IMAGE_URI|$OFFLINE_IMAGE_URI|g" \
  "$OPT_DIR/deploy/verify-offline.yaml" | kubectl apply -f -
kubectl -n "$NAMESPACE" wait pod/verify-offline --for=condition=Ready --timeout=300s

echo
echo "Offline verifier pod is Ready. Verify with no network:"
echo "  kubectl -n $NAMESPACE exec verify-offline -c main -- \\"
echo "    notation verify --oci-layout --scope $SCOPE \\"
echo "    $SCOPE@$DIGEST"
