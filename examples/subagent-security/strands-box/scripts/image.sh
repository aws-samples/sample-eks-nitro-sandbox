#!/usr/bin/env bash
# Build the analyst and synthetic supplier for the same ARM64 node capacity.
box_image_tag() {
  python3 - "$SECTION_DIR" "$@" <<'HASH'
import hashlib
import sys
from pathlib import Path
root = Path(sys.argv[1])
platform = sys.argv[2]
if platform not in ("linux/arm64", "linux/amd64"):
    sys.exit("Unsupported image platform")
paths = [root / ".dockerignore"]
for name in sys.argv[3:]:
    path = root / name
    if path.is_dir():
        paths.extend(p for p in path.rglob("*") if p.is_file()
                     and "__pycache__" not in p.parts and p.suffix != ".pyc")
    elif path.is_file():
        paths.append(path)
    else:
        sys.exit(f"Missing image input: {name}")
if not paths:
    sys.exit("No image inputs")
digest = hashlib.sha256(platform.encode() + b'\0')
for path in sorted(set(paths)):
    digest.update(str(path.relative_to(root)).encode() + b'\0')
    digest.update(path.read_bytes() + b'\0')
print(platform.split("/")[1] + "-" + digest.hexdigest()[:20])
HASH
}

box_build_image() {
  local repository="$1" platform="$2" dockerfile="$3" tag="$4"
  local registry existing rc arn tags docker_config image_digest
  case "$platform" in
    linux/arm64|linux/amd64) ;;
    *) die "unsupported image platform: $platform" ;;
  esac
  registry="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
  ANALYST_IMAGE="$registry/$repository:$tag"
  rc=0
  existing="$(lookup RepositoryNotFoundException ecr describe-repositories \
    --repository-names "$repository" --output json)" || rc=$?
  stop_if_undetermined "$rc" "the ECR repository $repository"
  if [[ "$rc" == 0 ]]; then
    arn="$(jq -er '.repositories[0].repositoryArn' <<<"$existing")" || die "invalid ECR repository response"
    tags="$(aws ecr list-tags-for-resource --resource-arn "$arn" --output json)" ||
      die "could not read ownership of ECR repository $repository"
    require_managed_by "ECR repository $repository" \
      "$(jq -r '.tags[]? | select(.Key=="ManagedBy") | .Value' <<<"$tags")"
  else
    aws ecr create-repository --repository-name "$repository" \
      --image-scanning-configuration scanOnPush=true \
      --tags "Key=ManagedBy,Value=$SAMPLE" >/dev/null
  fi
  rc=0
  lookup ImageNotFoundException ecr describe-images --repository-name "$repository" \
    --image-ids "imageTag=$tag" >/dev/null || rc=$?
  stop_if_undetermined "$rc" "the image $ANALYST_IMAGE"
  if [[ "$rc" == 0 ]]; then
    echo "  reusing $ANALYST_IMAGE"
  else
    docker_config="$(mktemp -d "$TMP_DIR/docker.XXXXXX")"
    (
    # Keep the scratch directory, but remove the registry credential on every exit.
    trap 'printf "{}\n" > "$docker_config/config.json"' EXIT
    aws ecr get-login-password --region "$AWS_REGION" |
      docker --config "$docker_config" login --username AWS --password-stdin "$registry" >/dev/null || exit 1
    # Always BuildKit, the builder box_require_arm64_builder inspected, even if the
    # shell has DOCKER_BUILDKIT=0 for Docker's legacy builder.
    DOCKER_BUILDKIT=1 docker --config "$docker_config" build --platform "$platform" \
      -f "$dockerfile" -t "$ANALYST_IMAGE" "$SECTION_DIR" || exit 1
    docker --config "$docker_config" push "$ANALYST_IMAGE" >/dev/null || exit 1
    ) || die "the image build or push failed"
    echo "  built and pushed $ANALYST_IMAGE"
  fi
  image_digest="$(aws ecr describe-images --repository-name "$repository" \
    --image-ids "imageTag=$tag" --query 'imageDetails[0].imageDigest' --output text)" ||
    die "could not resolve the pushed image digest for $ANALYST_IMAGE"
  [[ "$image_digest" =~ ^sha256:[a-f0-9]{64}$ ]] || die "ECR returned an invalid image digest"
  ANALYST_IMAGE="$registry/$repository@$image_digest"
  echo "  selected $ANALYST_IMAGE"
}

box_image() {
  local tag
  tag="$(box_image_tag linux/arm64 strands-box/Dockerfile strands-box/versions.json \
    analyst/requirements.txt strands-box/src strands-box/policies analyst/src analyst/fixtures)" ||
    die "could not hash the Box image inputs"
  box_build_image "$1" linux/arm64 "$SAMPLE_DIR/Dockerfile" "$tag"
}

box_supplier_image() {
  local repository="$1" dockerfile="$2" platform tag; shift 2
  case "$DEPLOYMENT_MODE" in
    eks|nitro) platform=linux/arm64 ;;
    *) die "DEPLOYMENT_MODE must be eks or nitro" ;;
  esac
  tag="$(box_image_tag "$platform" "$dockerfile" "$@")" || die "could not hash the supplier image inputs"
  box_build_image "$repository" "$platform" "$SECTION_DIR/$dockerfile" "$tag"
}

# Keep the shared synthetic business behavior; render the HTTP deployment.
box_render_supplier() {
  python3 "$SAMPLE_DIR/scripts/render_supplier.py" --mode "$DEPLOYMENT_MODE" \
    --image "$ANALYST_IMAGE" --namespace "$NAMESPACE" --managed-by "$SAMPLE" --output "$1"
}

box_supplier_api() {
  say "4/7 the synthetic supplier API"
  box_supplier_image "$SUPPLIER_API_REPOSITORY" strands-box/supplier/Dockerfile \
    strands-box/supplier/http_supplier.py analyst/supplier-api/supplier_api.py \
    analyst/src/business.py analyst/fixtures
  box_render_supplier "$TMP_DIR/supplier-api.yaml"
  kc apply -n "$NAMESPACE" -f "$TMP_DIR/supplier-api.yaml"
  kc rollout status deployment/supplier-api -n "$NAMESPACE" --timeout=5m ||
    die "the supplier API did not become ready"
}
