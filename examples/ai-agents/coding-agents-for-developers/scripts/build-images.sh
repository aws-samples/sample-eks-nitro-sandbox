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
# IMAGE_TAG in .env (v3, v4, ...) and run setup.sh again so the pods pick it up.
IMAGE_TAG="${IMAGE_TAG:-v2}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

die() { echo "ERROR: $*" >&2; exit 1; }

# Push only to a repository that is the sample's. Absent: create it, tagged
# ManagedBy=$SAMPLE. Present: reuse it only if it carries that tag. Anything else, including
# a lookup that fails, stops the script. Every repository is checked before anything is
# logged in to, built or pushed, so a refusal stops before any Docker login, build or push.
# A repository it created before the refusal carries the tag, so clean.sh removes it.
ensure_repo() {
  local repo="$1" arn owner
  if arn="$(aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" \
      --query 'repositories[0].repositoryArn' --output text 2>&1)"; then
    owner="$(aws ecr list-tags-for-resource --resource-arn "$arn" --region "$AWS_REGION" \
      --query "tags[?Key=='ManagedBy'].Value | [0]" --output text 2>&1)" \
      || die "ECR repository $repo: could not read its tags ($(printf '%s' "$owner" | grep -m1 .))"
    [[ "$owner" == "$SAMPLE" ]] \
      || die "ECR repository $repo exists but is not tagged ManagedBy=$SAMPLE (found: ${owner:-none}); refusing to push to it"
  else
    case "$arn" in
      *RepositoryNotFoundException*)
        aws ecr create-repository --repository-name "$repo" --region "$AWS_REGION" \
          --tags Key=ManagedBy,Value=$SAMPLE Key=auto-delete,Value=no >/dev/null ;;
      *) die "ECR repository $repo: lookup failed ($(printf '%s' "$arn" | grep -m1 .))" ;;
    esac
  fi
}

IFS=',' read -ra clis <<< "$AGENT_CLIS"
for name in base "${clis[@]}" app; do ensure_repo "$SAMPLE-$name"; done

aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null

# From here on Docker holds an ECR token for $REGISTRY. Log out on every exit, so a failed
# build or push does not leave the token in Docker's credential store. A failed logout is
# reported, and fails a run that otherwise succeeded; an earlier failure keeps its own status.
logout_on_exit() {
  local rc=$?
  if ! docker logout "$REGISTRY" >/dev/null 2>&1; then
    echo "ERROR: docker logout $REGISTRY failed; remove the registry entry from your Docker credential store" >&2
    [ "$rc" -ne 0 ] || rc=1
  fi
  exit "$rc"
}
trap logout_on_exit EXIT

echo "==> base"
BASE="$REGISTRY/$SAMPLE-base:$IMAGE_TAG"
docker build --platform linux/amd64 -t "$BASE" "$ROOT/images/base"
docker push "$BASE"

for cli in "${clis[@]}"; do
  echo "==> $cli"
  docker build --platform linux/amd64 --build-arg BASE_IMAGE="$BASE" \
    -t "$REGISTRY/$SAMPLE-$cli:$IMAGE_TAG" "$ROOT/images/$cli"
  docker push "$REGISTRY/$SAMPLE-$cli:$IMAGE_TAG"
done

echo "==> app"
docker build --platform linux/amd64 -t "$REGISTRY/$SAMPLE-app:$IMAGE_TAG" "$ROOT/app"
docker push "$REGISTRY/$SAMPLE-app:$IMAGE_TAG"

echo "==> images pushed to $REGISTRY"
