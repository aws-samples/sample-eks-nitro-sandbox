#!/usr/bin/env bash
# Build all sample images inside AWS CodeBuild and export digest-qualified ECR refs.
set -euo pipefail

die() {
  printf 'image build: %s\n' "$*" >&2
  exit 1
}

require_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "$name is required"
}

require_sha() {
  local name="$1"
  local value="${!name:-}"
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] ||
    die "$name must be a full 40-character lowercase Git commit SHA"
}

require_value CODEBUILD_BUILD_ARN
require_value CODEBUILD_SRC_DIR
require_value AWS_ACCOUNT_ID
require_value AWS_DEFAULT_REGION
require_value SAMPLE_SOURCE_DIR
require_value OCE_REPOSITORY_URL
require_value ADAPTER_REPOSITORY
require_value CONTROLLER_REPOSITORY
require_value OWNERSHIP_HELPER_REPOSITORY
require_value RUNTIME_REPOSITORY
require_value BUILD_OUTPUT_ENV
require_sha SAMPLE_GIT_REVISION
require_sha OCE_GIT_REVISION

require_digest_image() {
  local name="$1"
  local value="${!name:-}"
  [[ "$value" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] ||
    die "$name must be an immutable image reference ending in @sha256:<64 lowercase hex characters>"
}

[[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die "AWS_ACCOUNT_ID must be 12 digits"
[[ "${TARGET_PLATFORM:-linux/amd64}" =~ ^linux/(amd64|arm64)$ ]] ||
  die "TARGET_PLATFORM must be linux/amd64 or linux/arm64"
[[ -d "$SAMPLE_SOURCE_DIR/.git" ]] || die "SAMPLE_SOURCE_DIR is not a Git checkout"

for command in aws docker git node python3 sha256sum; do
  command -v "$command" >/dev/null || die "$command is required"
done
docker buildx version >/dev/null || die "Docker Buildx is required"

SAMPLE_SOURCE_REVISION="$(git -C "$SAMPLE_SOURCE_DIR" rev-parse HEAD)"
[[ "$SAMPLE_SOURCE_REVISION" == "$SAMPLE_GIT_REVISION" ]] ||
  die "sample checkout resolved to $SAMPLE_SOURCE_REVISION, expected $SAMPLE_GIT_REVISION"

OCE_SOURCE_DIR="$CODEBUILD_SRC_DIR/oce-source"
git init "$OCE_SOURCE_DIR"
git -C "$OCE_SOURCE_DIR" remote add origin "$OCE_REPOSITORY_URL"
git -C "$OCE_SOURCE_DIR" fetch --depth 1 origin "$OCE_GIT_REVISION"
OCE_SOURCE_REVISION="$(git -C "$OCE_SOURCE_DIR" rev-parse FETCH_HEAD)"
[[ "$OCE_SOURCE_REVISION" == "$OCE_GIT_REVISION" ]] ||
  die "OCE checkout resolved to $OCE_SOURCE_REVISION, expected $OCE_GIT_REVISION"
git -C "$OCE_SOURCE_DIR" checkout --detach "$OCE_GIT_REVISION"

OCE_MSAL_NODE_VERSION="7.2.0"
python3 -I \
  "$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/build/check-oce-lock.py" \
  "$OCE_SOURCE_DIR/pnpm-lock.yaml" \
  "$OCE_MSAL_NODE_VERSION"

REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"
aws ecr get-login-password --region "$AWS_DEFAULT_REGION" |
  docker login --username AWS --password-stdin "$REGISTRY"
trap 'docker logout "$REGISTRY" >/dev/null 2>&1 || true' EXIT

build_identity="$(printf '%s' "$CODEBUILD_BUILD_ARN" | sha256sum | cut -c1-16)"
sample_tag="${SAMPLE_SOURCE_REVISION}-${build_identity}"
oce_tag="${OCE_SOURCE_REVISION}-${build_identity}"
metadata_dir="$CODEBUILD_SRC_DIR/image-metadata"
mkdir -p "$metadata_dir"

adapter_tagged="${REGISTRY}/${ADAPTER_REPOSITORY}:${sample_tag}"
controller_tagged="${REGISTRY}/${CONTROLLER_REPOSITORY}:${oce_tag}"
ownership_helper_tagged="${REGISTRY}/${OWNERSHIP_HELPER_REPOSITORY}:${sample_tag}"
runtime_tagged="${REGISTRY}/${RUNTIME_REPOSITORY}:${oce_tag}"
OWNERSHIP_HELPER_BUILDER_IMAGE="public.ecr.aws/docker/library/golang:1.26.9-alpine3.23@sha256:6750308561953d451210ed1a8086d36c8c8bdcbf672d38d9d0d424b8a7a0216c"

docker buildx build \
  --pull \
  --push \
  --platform "${TARGET_PLATFORM:-linux/amd64}" \
  --metadata-file "$metadata_dir/adapter.json" \
  --label "org.opencontainers.image.revision=$SAMPLE_SOURCE_REVISION" \
  --tag "$adapter_tagged" \
  "$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/adapter"

docker buildx build \
  --pull \
  --push \
  --platform "${TARGET_PLATFORM:-linux/amd64}" \
  --metadata-file "$metadata_dir/ownership-helper.json" \
  --build-arg "OWNERSHIP_HELPER_BUILDER_IMAGE=$OWNERSHIP_HELPER_BUILDER_IMAGE" \
  --label "org.opencontainers.image.revision=$SAMPLE_SOURCE_REVISION" \
  --tag "$ownership_helper_tagged" \
  "$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/ownership-helper"

node_base_image="$(
  node -e '
    const fs = require("node:fs");
    const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const value = data?.prepare?.defaultEnv?.NODE_BASE_IMAGE;
    if (typeof value !== "string" || !/@sha256:[0-9a-f]{64}$/.test(value)) {
      process.exit(1);
    }
    process.stdout.write(value);
  ' "$OCE_SOURCE_DIR/scripts/ci/test-suites/images-packaging.json"
)" || die "could not resolve OCE's pinned NODE_BASE_IMAGE"
CONTROLLER_RUNTIME_BASE_IMAGE="${CONTROLLER_RUNTIME_BASE_IMAGE:-docker.io/library/node:24.22.1-bookworm-slim@sha256:55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205}"
require_digest_image CONTROLLER_RUNTIME_BASE_IMAGE

docker buildx build \
  --pull \
  --push \
  --platform "${TARGET_PLATFORM:-linux/amd64}" \
  --target runtime \
  --metadata-file "$metadata_dir/controller.json" \
  --build-arg "NODE_BUILD_BASE_IMAGE=$node_base_image" \
  --build-arg "NODE_RUNTIME_BASE_IMAGE=$CONTROLLER_RUNTIME_BASE_IMAGE" \
  --build-arg "OCC_BUILD_REVISION=$OCE_SOURCE_REVISION" \
  --label "org.opencontainers.image.revision=$OCE_SOURCE_REVISION" \
  --file "$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/build/controller-runtime.Dockerfile" \
  --tag "$controller_tagged" \
  "$OCE_SOURCE_DIR"

mapfile -t openclaw_source_args < <(
  cd "$OCE_SOURCE_DIR"
  node scripts/lib/openclaw-source.mjs build-args
)
[[ "${#openclaw_source_args[@]}" -gt 0 ]] ||
  die "OCE returned no pinned OpenClaw source arguments"

runtime_build_args=()
for argument in "${openclaw_source_args[@]}"; do
  [[ "$argument" == *=* ]] || die "invalid OCE runtime build argument"
  runtime_build_args+=(--build-arg "$argument")
done

docker buildx build \
  --pull \
  --push \
  --platform "${TARGET_PLATFORM:-linux/amd64}" \
  --metadata-file "$metadata_dir/runtime.json" \
  "${runtime_build_args[@]}" \
  --build-arg "NODE_BASE_IMAGE=$node_base_image" \
  --build-arg "OCC_BUILD_REVISION=$OCE_SOURCE_REVISION" \
  --label "org.opencontainers.image.revision=$OCE_SOURCE_REVISION" \
  --file "$OCE_SOURCE_DIR/deploy/runtime/Dockerfile" \
  --tag "$runtime_tagged" \
  "$OCE_SOURCE_DIR"

read_digest() {
  python3 - "$1" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    digest = json.load(handle).get("containerimage.digest", "")
if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
    raise SystemExit(f"invalid image digest in {sys.argv[1]}: {digest!r}")
print(digest)
PY
}

adapter_digest="$(read_digest "$metadata_dir/adapter.json")"
controller_digest="$(read_digest "$metadata_dir/controller.json")"
ownership_helper_digest="$(read_digest "$metadata_dir/ownership-helper.json")"
runtime_digest="$(read_digest "$metadata_dir/runtime.json")"

verify_digest() {
  local repository="$1"
  local digest="$2"
  local _
  for _ in {1..10}; do
    if aws ecr describe-images \
      --region "$AWS_DEFAULT_REGION" \
      --repository-name "$repository" \
      --image-ids "imageDigest=$digest" \
      --query 'imageDetails[0].imageDigest' \
      --output text 2>/dev/null | grep -Fxq "$digest"; then
      return 0
    fi
    sleep 2
  done
  die "ECR did not return $repository@$digest after push"
}

verify_digest "$ADAPTER_REPOSITORY" "$adapter_digest"
verify_digest "$CONTROLLER_REPOSITORY" "$controller_digest"
verify_digest "$OWNERSHIP_HELPER_REPOSITORY" "$ownership_helper_digest"
verify_digest "$RUNTIME_REPOSITORY" "$runtime_digest"

verify_scan() {
  local repository="$1"
  local digest="$2"
  local response="$metadata_dir/scan-${repository//\//-}.json"
  local error_response="$metadata_dir/scan-${repository//\//-}.stderr"
  local coverage_response="$metadata_dir/coverage-${repository//\//-}.json"
  local findings_response="$metadata_dir/findings-${repository//\//-}.json"
  local filter_dir="$metadata_dir/filters-${repository//\//-}"
  local partition
  local resource_id
  local scan_result
  local _
  partition="$(cut -d: -f2 <<<"$CODEBUILD_BUILD_ARN")"
  [[ -n "$partition" ]] || die "could not derive AWS partition"
  resource_id="arn:${partition}:ecr:${AWS_DEFAULT_REGION}:${AWS_ACCOUNT_ID}:repository/${repository}/${digest}"

  mkdir -p "$filter_dir"
  python3 - "$filter_dir" "$AWS_ACCOUNT_ID" "$repository" "$digest" "$resource_id" <<'PY'
import json
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
account_id, repository, digest, resource_id = sys.argv[2:]
equals = lambda value: [{"comparison": "EQUALS", "value": value}]
coverage = {
    "accountId": equals(account_id),
    "resourceId": equals(resource_id),
    "resourceType": equals("AWS_ECR_CONTAINER_IMAGE"),
    "scanType": equals("PACKAGE"),
    "ecrRepositoryName": equals(repository),
}
findings = {
    "awsAccountId": equals(account_id),
    "resourceType": equals("AWS_ECR_CONTAINER_IMAGE"),
    "resourceId": equals(resource_id),
    "ecrImageRegistry": equals(account_id),
    "ecrImageRepositoryName": equals(repository),
    "ecrImageHash": equals(digest),
    "findingStatus": equals("ACTIVE"),
    "severity": [
        {"comparison": "EQUALS", "value": "CRITICAL"},
        {"comparison": "EQUALS", "value": "HIGH"},
    ],
}
(directory / "coverage.json").write_text(json.dumps(coverage), encoding="utf-8")
(directory / "findings.json").write_text(json.dumps(findings), encoding="utf-8")
PY

  for _ in {1..120}; do
    if aws ecr describe-image-scan-findings \
        --region "$AWS_DEFAULT_REGION" \
        --repository-name "$repository" \
        --image-id "imageDigest=$digest" \
        --output json >"$response" 2>"$error_response"; then
      if python3 -I \
        "$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/build/check-image-scan.py" \
        <"$response"; then
        return 0
      else
        scan_result=$?
      fi
      [[ "$scan_result" -eq 10 ]] ||
        die "ECR scan gate rejected $repository@$digest"
      sleep 5
      continue
    fi

    if ! grep -Fq "ScanNotFoundException" "$error_response"; then
      cat "$error_response" >&2
      die "ECR scan lookup failed for $repository@$digest"
    fi

    if ! aws inspector2 list-coverage \
      --region "$AWS_DEFAULT_REGION" \
      --filter-criteria "file://$filter_dir/coverage.json" \
      --max-results 2 \
      --no-paginate \
      --output json >"$coverage_response"; then
      die "Inspector coverage lookup failed for $repository@$digest"
    fi
    if ! aws inspector2 list-findings \
      --region "$AWS_DEFAULT_REGION" \
      --filter-criteria "file://$filter_dir/findings.json" \
      --max-results 1 \
      --no-paginate \
      --output json >"$findings_response"; then
      die "Inspector findings lookup failed for $repository@$digest"
    fi

    if python3 -I \
      "$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/build/check-inspector-scan.py" \
      "$coverage_response" \
      "$findings_response" \
      "$resource_id" \
      "$AWS_ACCOUNT_ID" \
      "$repository" \
      "$digest"; then
      return 0
    else
      scan_result=$?
    fi
    [[ "$scan_result" -eq 10 ]] ||
      die "Inspector scan gate rejected $repository@$digest"
    sleep 5
  done
  die "image scan for $repository@$digest did not produce completed findings"
}

verify_scan "$ADAPTER_REPOSITORY" "$adapter_digest"
verify_scan "$CONTROLLER_REPOSITORY" "$controller_digest"
verify_scan "$OWNERSHIP_HELPER_REPOSITORY" "$ownership_helper_digest"
verify_scan "$RUNTIME_REPOSITORY" "$runtime_digest"

ADAPTER_IMAGE="${REGISTRY}/${ADAPTER_REPOSITORY}@${adapter_digest}"
CONTROLLER_IMAGE="${REGISTRY}/${CONTROLLER_REPOSITORY}@${controller_digest}"
OWNERSHIP_INIT_IMAGE="${REGISTRY}/${OWNERSHIP_HELPER_REPOSITORY}@${ownership_helper_digest}"
RUNTIME_IMAGE="${REGISTRY}/${RUNTIME_REPOSITORY}@${runtime_digest}"
export ADAPTER_IMAGE CONTROLLER_IMAGE OWNERSHIP_INIT_IMAGE RUNTIME_IMAGE
export OWNERSHIP_HELPER_BUILDER_IMAGE
export SAMPLE_SOURCE_REVISION OCE_SOURCE_REVISION

{
  printf 'export ADAPTER_IMAGE=%q\n' "$ADAPTER_IMAGE"
  printf 'export CONTROLLER_IMAGE=%q\n' "$CONTROLLER_IMAGE"
  printf 'export OWNERSHIP_INIT_IMAGE=%q\n' "$OWNERSHIP_INIT_IMAGE"
  printf 'export RUNTIME_IMAGE=%q\n' "$RUNTIME_IMAGE"
  printf 'export SAMPLE_SOURCE_REVISION=%q\n' "$SAMPLE_SOURCE_REVISION"
  printf 'export OCE_SOURCE_REVISION=%q\n' "$OCE_SOURCE_REVISION"
} >"$BUILD_OUTPUT_ENV"

python3 - "$CODEBUILD_SRC_DIR/image-digests.json" <<'PY'
import json
import os
import sys

result = {
    "adapter": {
        "image": os.environ["ADAPTER_IMAGE"],
        "sourceRevision": os.environ["SAMPLE_SOURCE_REVISION"],
    },
    "controller": {
        "image": os.environ["CONTROLLER_IMAGE"],
        "sourceRevision": os.environ["OCE_SOURCE_REVISION"],
    },
    "ownershipHelper": {
        "builderImage": os.environ["OWNERSHIP_HELPER_BUILDER_IMAGE"],
        "image": os.environ["OWNERSHIP_INIT_IMAGE"],
        "sourceRevision": os.environ["SAMPLE_SOURCE_REVISION"],
    },
    "runtime": {
        "image": os.environ["RUNTIME_IMAGE"],
        "sourceRevision": os.environ["OCE_SOURCE_REVISION"],
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(result, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
