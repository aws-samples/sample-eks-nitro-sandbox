#!/usr/bin/env bash
# Build and push the base image, the six CLI images (each FROM the base) and the app
# image to ECR. Reads .env for CLUSTER_NAME/AWS_REGION; AGENT_CLIS selects the CLIs.
set -euo pipefail

SAMPLE=coding-agents-for-developers
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1090
set -a; . "$ROOT/.env"; set +a

AWS_REGION="${AWS_REGION:?set AWS_REGION}"
AGENT_CLIS="${AGENT_CLIS:-claude-code,codex,kiro-cli,opencode,pi,oh-my-pi}"
# A fixed tag, not :latest. The pods use imagePullPolicy: IfNotPresent, so a node that has
# already pulled this tag keeps its cached copy: after changing an image, set a new
# IMAGE_TAG in .env (v2, v3, ...) and run setup.sh again so the pods pick it up.
IMAGE_TAG="${IMAGE_TAG:-v1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

ensure_repo() { aws ecr describe-repositories --repository-names "$1" --region "$AWS_REGION" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "$1" --region "$AWS_REGION" \
       --tags Key=ManagedBy,Value=$SAMPLE Key=auto-delete,Value=no >/dev/null; }

aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null

echo "==> base"
ensure_repo "$SAMPLE-base"
BASE="$REGISTRY/$SAMPLE-base:$IMAGE_TAG"
docker build --platform linux/amd64 -t "$BASE" "$ROOT/images/base"
docker push "$BASE"

IFS=',' read -ra clis <<< "$AGENT_CLIS"
for cli in "${clis[@]}"; do
  echo "==> $cli"
  ensure_repo "$SAMPLE-$cli"
  docker build --platform linux/amd64 --build-arg BASE_IMAGE="$BASE" \
    -t "$REGISTRY/$SAMPLE-$cli:$IMAGE_TAG" "$ROOT/images/$cli"
  docker push "$REGISTRY/$SAMPLE-$cli:$IMAGE_TAG"
done

echo "==> app"
ensure_repo "$SAMPLE-app"
docker build --platform linux/amd64 -t "$REGISTRY/$SAMPLE-app:$IMAGE_TAG" "$ROOT/app"
docker push "$REGISTRY/$SAMPLE-app:$IMAGE_TAG"

docker logout "$REGISTRY" >/dev/null 2>&1 || true
echo "==> images pushed to $REGISTRY"
