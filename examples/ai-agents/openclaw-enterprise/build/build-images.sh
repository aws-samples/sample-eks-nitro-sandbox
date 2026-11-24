#!/usr/bin/env bash
# Build all sample images inside AWS CodeBuild and export digest-qualified ECR refs.
# shellcheck source=../../../../scripts/lib/require-bash.sh
. "$(dirname "$0")/../../../../scripts/lib/require-bash.sh"

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

require_digest() {
  local name="$1"
  local value="${!name:-}"
  [[ "$value" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "$name must be sha256 followed by exactly 64 lowercase hex characters"
}

reclaim_build_disk() {
  # Every image is already in ECR at this point. Remove its local BuildKit
  # cache and VFS layer copies before the next build consumes the ephemeral
  # CodeBuild disk.
  docker buildx prune --all --force
  docker system prune --all --force --volumes
}

read_oce_dockerfile_arg() {
  local name="$1"
  local dockerfile="$2"
  node - "$name" "$dockerfile" <<'NODE'
const fs = require("node:fs");
const [name, dockerfile] = process.argv.slice(2);
const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const pattern = new RegExp(`^ARG[ \t]+${escaped}=([^ \t\r\n]+)$`, "gm");
const matches = [...fs.readFileSync(dockerfile, "utf8").matchAll(pattern)];
if (matches.length !== 1 || !/@sha256:[0-9a-f]{64}$/.test(matches[0][1])) {
  process.exit(1);
}
process.stdout.write(matches[0][1]);
NODE
}

require_matching_oce_node_bases() {
  local build_image="$1"
  local runtime_image="$2"
  local build_version
  local runtime_version

  if [[ "$build_image" =~ ^docker\.io/library/node:([0-9]+\.[0-9]+\.[0-9]+)-trixie@sha256:[0-9a-f]{64}$ ]]; then
    build_version="${BASH_REMATCH[1]}"
  else
    die "OCE NODE_BASE_IMAGE must be a digest-pinned Node.js Trixie image"
  fi
  if [[ "$runtime_image" =~ ^docker\.io/library/node:([0-9]+\.[0-9]+\.[0-9]+)-trixie-slim@sha256:[0-9a-f]{64}$ ]]; then
    runtime_version="${BASH_REMATCH[1]}"
  else
    die "OCE NODE_RUNTIME_BASE_IMAGE must be a digest-pinned Node.js Trixie slim image"
  fi
  [[ "$build_version" == "$runtime_version" ]] ||
    die "OCE Node build and runtime base versions must match"
}

readonly OCE_REPOSITORY_URL="https://github.com/openclaw/openclaw-enterprise.git"
readonly CONTROLLER_RUNTIME_BASE_IMAGE_REPOSITORY="gcr.io/distroless/nodejs24-debian13"
readonly CONTROLLER_RUNTIME_BASE_IMAGE_TAG="nonroot"
readonly CONTROLLER_RUNTIME_BASE_IMAGE_ALLOWLIST_DIGEST="sha256:6abfcb367ebc291572c774c1592a986be2ab26a2486f73093401327495a5962a"
readonly INSPECTOR_SCAN_POLL_SECONDS=5
readonly INSPECTOR_SCAN_STABLE_OBSERVATIONS=13

require_value CODEBUILD_BUILD_ARN
require_value CODEBUILD_SRC_DIR
require_value AWS_ACCOUNT_ID
require_value AWS_DEFAULT_REGION
require_value SAMPLE_SOURCE_DIR
require_value ADAPTER_REPOSITORY
require_value CONTROLLER_REPOSITORY
require_value OWNERSHIP_HELPER_REPOSITORY
require_value RUNTIME_REPOSITORY
require_value BUILD_OUTPUT_ENV
require_sha SAMPLE_GIT_REVISION
require_sha OCE_GIT_REVISION
require_digest CONTROLLER_RUNTIME_BASE_IMAGE_DIGEST
[[ "$CONTROLLER_RUNTIME_BASE_IMAGE_DIGEST" == "$CONTROLLER_RUNTIME_BASE_IMAGE_ALLOWLIST_DIGEST" ]] ||
  die "CONTROLLER_RUNTIME_BASE_IMAGE_DIGEST is not the reviewed distroless Node runtime"

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

metadata_dir="$CODEBUILD_SRC_DIR/image-metadata"
mkdir -p "$metadata_dir"
inspector_account_status="$metadata_dir/inspector-account-status.json"
registry_scanning_config="$metadata_dir/ecr-registry-scanning-config.json"
if ! aws inspector2 batch-get-account-status \
  --region "$AWS_DEFAULT_REGION" \
  --account-ids "$AWS_ACCOUNT_ID" \
  --output json >"$inspector_account_status"; then
  die "could not verify Amazon Inspector account status"
fi
if ! aws ecr get-registry-scanning-configuration \
  --region "$AWS_DEFAULT_REGION" \
  --output json >"$registry_scanning_config"; then
  die "could not verify the ECR registry scanning configuration"
fi
python3 -I \
  "$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/build/check-enhanced-scanning.py" \
  "$inspector_account_status" \
  "$registry_scanning_config" \
  "$AWS_ACCOUNT_ID" \
  "$ADAPTER_REPOSITORY" \
  "$CONTROLLER_REPOSITORY" \
  "$OWNERSHIP_HELPER_REPOSITORY" \
  "$RUNTIME_REPOSITORY"

OCE_SOURCE_DIR="$CODEBUILD_SRC_DIR/oce-source"
git init "$OCE_SOURCE_DIR"
git -C "$OCE_SOURCE_DIR" remote add origin "$OCE_REPOSITORY_URL"
[[ "$(git -C "$OCE_SOURCE_DIR" remote get-url origin)" == "$OCE_REPOSITORY_URL" ]] ||
  die "OCE origin does not match the canonical repository"
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

OPENSSL_BACKPORT_PATCH="$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/build/patches/openssl-cve-2026-95692.patch"
OPENSSL_BACKPORT_CVE="CVE-2026-95692"
OPENSSL_BACKPORT_PATCH_SHA256="ab26acb8f611cd6d07e9d9e30af45ed58e316b6011cb08847bb99fa5ff67f94c" # pragma: allowlist secret -- public patch checksum
OPENSSL_BACKPORT_UPSTREAM_COMMIT="257a3427aa0ef8d9dd2ef5b3e2d1c021a221b116" # pragma: allowlist secret -- public source revision
OPENSSL_88823_BACKPORT_PATCH="$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/build/patches/openssl-cve-2026-88823.patch"
OPENSSL_88823_TEST_PATCH="$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/build/patches/openssl-cve-2026-88823-test.patch"
OPENSSL_88823_SOURCE_ASSETS="$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/build/openssl"
OPENSSL_88823_BACKPORT_CVE="CVE-2026-88823"
OPENSSL_88823_BACKPORT_PATCH_SHA256="a945077c0a978dbfe5af5e4f7174a2151466547f8fb94562f395baa7b6b7c147" # pragma: allowlist secret -- public patch checksum
OPENSSL_88823_TEST_PATCH_SHA256="c7885d44f2659d97c0fc71fcdc8a6ef04cbe2ccdd36a72c28e7dfd1452033f2d" # pragma: allowlist secret -- public patch checksum
OPENSSL_88823_BACKPORT_UPSTREAM_COMMIT="159e1de0c448d7b9f09ad768c8e141def4aa1eb4" # pragma: allowlist secret -- public source revision
OPENSSL_88823_TEST_UPSTREAM_COMMIT="9d0d29bcf98ae5c1fb91653ba635e993260176d8" # pragma: allowlist secret -- public source revision
OPENSSL_DEBIAN_VERSION="3.5.9-1~deb13u1"
OPENSSL_PACKAGE_VERSION="${OPENSSL_DEBIAN_VERSION}+oce1"
OPENCLAW_DEPENDENCY_PATCH="$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/build/patches/openclaw-security-overrides.patch"
OPENCLAW_DEPENDENCY_PATCH_SHA256="2b1fb478649494c0b74879bbed20c55155658575555ebe37a88050d372aef451" # pragma: allowlist secret -- reviewed patch checksum
CURL_BACKPORT_PATCH="$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/build/patches/curl-cve-2026-86414-trixie.patch"
CURL_BACKPORT_CVE="CVE-2026-86414"
CURL_BACKPORT_PATCH_SHA256="cdd2c3db9c85552d0a2633e873fdab4f96f7ea996a4f6c87d3348a1b34bae824" # pragma: allowlist secret -- reviewed patch checksum
CURL_BACKPORT_UPSTREAM_COMMIT="2956af6c7451029fb12c12f8166dff211f930d52" # pragma: allowlist secret -- public source revision
NPM_RUNTIME_VERSION="11.21.3"
NPM_RUNTIME_ARCHIVE_SHA256="ee5fc68e724c4bdba38db9d96d9c661d4e736e4be7001ae44d2fbbaa52159514" # pragma: allowlist secret -- public archive checksum
python3 -I \
  "$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/build/apply-oce-security-patches.py" \
  "$OCE_SOURCE_DIR" \
  "$OCE_SOURCE_REVISION" \
  "$OPENSSL_BACKPORT_PATCH" \
  "$OPENCLAW_DEPENDENCY_PATCH" \
  "$CURL_BACKPORT_PATCH" \
  "$OPENSSL_88823_SOURCE_ASSETS" \
  "$OPENSSL_88823_BACKPORT_PATCH" \
  "$OPENSSL_88823_TEST_PATCH"
readonly OPENSSL_BACKPORT_PATCH OPENSSL_BACKPORT_CVE
readonly OPENSSL_BACKPORT_PATCH_SHA256 OPENSSL_BACKPORT_UPSTREAM_COMMIT
readonly OPENSSL_88823_BACKPORT_PATCH OPENSSL_88823_TEST_PATCH
readonly OPENSSL_88823_SOURCE_ASSETS OPENSSL_88823_BACKPORT_CVE
readonly OPENSSL_88823_BACKPORT_PATCH_SHA256 OPENSSL_88823_TEST_PATCH_SHA256
readonly OPENSSL_88823_BACKPORT_UPSTREAM_COMMIT OPENSSL_88823_TEST_UPSTREAM_COMMIT
readonly OPENSSL_DEBIAN_VERSION OPENSSL_PACKAGE_VERSION
readonly OPENCLAW_DEPENDENCY_PATCH OPENCLAW_DEPENDENCY_PATCH_SHA256
readonly CURL_BACKPORT_PATCH CURL_BACKPORT_CVE
readonly CURL_BACKPORT_PATCH_SHA256 CURL_BACKPORT_UPSTREAM_COMMIT
readonly NPM_RUNTIME_VERSION NPM_RUNTIME_ARCHIVE_SHA256

# Consume the digest-pinned Debian 13 bases prepared by the fail-closed OCE
# source patcher. Inspector gates the final pushed images below.
OCE_RUNTIME_DOCKERFILE="$OCE_SOURCE_DIR/deploy/runtime/Dockerfile"
OCE_NODE_BUILD_BASE_IMAGE="$(
  read_oce_dockerfile_arg NODE_BASE_IMAGE "$OCE_RUNTIME_DOCKERFILE"
)" || die "could not resolve OCE's digest-pinned NODE_BASE_IMAGE"
OCE_NODE_RUNTIME_BASE_IMAGE="$(
  read_oce_dockerfile_arg NODE_RUNTIME_BASE_IMAGE "$OCE_RUNTIME_DOCKERFILE"
)" || die "could not resolve OCE's digest-pinned NODE_RUNTIME_BASE_IMAGE"
readonly OCE_NODE_BUILD_BASE_IMAGE OCE_NODE_RUNTIME_BASE_IMAGE
require_matching_oce_node_bases \
  "$OCE_NODE_BUILD_BASE_IMAGE" \
  "$OCE_NODE_RUNTIME_BASE_IMAGE"

REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"
aws ecr get-login-password --region "$AWS_DEFAULT_REGION" |
  docker login --username AWS --password-stdin "$REGISTRY"
trap 'docker logout "$REGISTRY" >/dev/null 2>&1 || true' EXIT

build_identity="$(printf '%s' "$CODEBUILD_BUILD_ARN" | sha256sum | cut -c1-16)"
sample_tag="${SAMPLE_SOURCE_REVISION}-${build_identity}"
oce_tag="${OCE_SOURCE_REVISION}-${build_identity}"

adapter_tagged="${REGISTRY}/${ADAPTER_REPOSITORY}:${sample_tag}"
controller_tagged="${REGISTRY}/${CONTROLLER_REPOSITORY}:${oce_tag}"
ownership_helper_tagged="${REGISTRY}/${OWNERSHIP_HELPER_REPOSITORY}:${sample_tag}"
runtime_tagged="${REGISTRY}/${RUNTIME_REPOSITORY}:${oce_tag}"
OWNERSHIP_HELPER_BUILDER_IMAGE="public.ecr.aws/docker/library/golang:1.26.9-alpine3.23@sha256:6750308561953d451210ed1a8086d36c8c8bdcbf672d38d9d0d424b8a7a0216c"

docker buildx build \
  --pull \
  --push \
  --provenance=false \
  --platform "${TARGET_PLATFORM:-linux/amd64}" \
  --metadata-file "$metadata_dir/adapter.json" \
  --label "org.opencontainers.image.revision=$SAMPLE_SOURCE_REVISION" \
  --tag "$adapter_tagged" \
  "$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/adapter"
reclaim_build_disk

docker buildx build \
  --pull \
  --push \
  --provenance=false \
  --platform "${TARGET_PLATFORM:-linux/amd64}" \
  --metadata-file "$metadata_dir/ownership-helper.json" \
  --build-arg "OWNERSHIP_HELPER_BUILDER_IMAGE=$OWNERSHIP_HELPER_BUILDER_IMAGE" \
  --label "org.opencontainers.image.revision=$SAMPLE_SOURCE_REVISION" \
  --tag "$ownership_helper_tagged" \
  "$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/ownership-helper"
reclaim_build_disk

readonly CONTROLLER_RUNTIME_BASE_IMAGE="${CONTROLLER_RUNTIME_BASE_IMAGE_REPOSITORY}:${CONTROLLER_RUNTIME_BASE_IMAGE_TAG}@${CONTROLLER_RUNTIME_BASE_IMAGE_DIGEST}"

docker buildx build \
  --pull \
  --push \
  --provenance=false \
  --platform "${TARGET_PLATFORM:-linux/amd64}" \
  --target runtime \
  --metadata-file "$metadata_dir/controller.json" \
  --build-arg "NODE_BUILD_BASE_IMAGE=$OCE_NODE_BUILD_BASE_IMAGE" \
  --build-arg "NODE_RUNTIME_BASE_IMAGE=$CONTROLLER_RUNTIME_BASE_IMAGE" \
  --build-arg "OCC_BUILD_REVISION=$OCE_SOURCE_REVISION" \
  --label "org.opencontainers.image.revision=$SAMPLE_SOURCE_REVISION" \
  --label "org.openclaw.enterprise.source-revision=$OCE_SOURCE_REVISION" \
  --file "$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/build/controller-runtime.Dockerfile" \
  --tag "$controller_tagged" \
  "$OCE_SOURCE_DIR"
reclaim_build_disk

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
  --provenance=false \
  --platform "${TARGET_PLATFORM:-linux/amd64}" \
  --metadata-file "$metadata_dir/runtime.json" \
  "${runtime_build_args[@]}" \
  --build-arg "NODE_BASE_IMAGE=$OCE_NODE_BUILD_BASE_IMAGE" \
  --build-arg "NODE_RUNTIME_BASE_IMAGE=$OCE_NODE_RUNTIME_BASE_IMAGE" \
  --build-arg "OCC_BUILD_REVISION=$OCE_SOURCE_REVISION" \
  --label "org.opencontainers.image.revision=$SAMPLE_SOURCE_REVISION" \
  --label "org.openclaw.enterprise.source-revision=$OCE_SOURCE_REVISION" \
  --file "$OCE_RUNTIME_DOCKERFILE" \
  --tag "$runtime_tagged" \
  "$OCE_SOURCE_DIR"

read_digest() {
  python3 -c '
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    digest = json.load(handle).get("containerimage.digest", "")
if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
    raise SystemExit(f"invalid image digest in {sys.argv[1]}: {digest!r}")
print(digest)
' "$1"
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
  shift 2
  local -a backport_patches=("$@")
  local coverage_response="$metadata_dir/coverage-${repository//\//-}.json"
  local findings_response="$metadata_dir/findings-${repository//\//-}.json"
  local filter_dir="$metadata_dir/filters-${repository//\//-}"
  local partition
  local resource_id
  local scan_result
  local -a scan_command
  local backport_patch
  local clean_observations=0
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
      --output json >"$findings_response"; then
      die "Inspector findings lookup failed for $repository@$digest"
    fi

    scan_command=(
      python3 -I
      "$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/build/check-inspector-scan.py"
      "$coverage_response"
      "$findings_response"
      "$resource_id"
      "$AWS_ACCOUNT_ID"
      "$repository"
      "$digest"
    )
    for backport_patch in "${backport_patches[@]}"; do
      scan_command+=(--backport-patch "$backport_patch")
    done
    # Inspector can mark coverage successful before all findings are queryable.
    # Observations at five-second intervals span a full minute from first to last.
    if "${scan_command[@]}"; then
      ((clean_observations += 1))
      if (( clean_observations >= INSPECTOR_SCAN_STABLE_OBSERVATIONS )); then
        return 0
      fi
    else
      scan_result=$?
      [[ "$scan_result" -eq 10 ]] ||
        die "Inspector scan gate rejected $repository@$digest"
      clean_observations=0
    fi
    sleep "$INSPECTOR_SCAN_POLL_SECONDS"
  done
  die "Inspector PACKAGE scan for $repository@$digest did not complete; confirm Amazon Inspector enhanced ECR scanning is enabled"
}

verify_scan "$ADAPTER_REPOSITORY" "$adapter_digest"
verify_scan "$CONTROLLER_REPOSITORY" "$controller_digest"
verify_scan "$OWNERSHIP_HELPER_REPOSITORY" "$ownership_helper_digest"
verify_scan \
  "$RUNTIME_REPOSITORY" \
  "$runtime_digest" \
  "$OPENSSL_BACKPORT_PATCH" \
  "$OPENSSL_88823_BACKPORT_PATCH"

ADAPTER_IMAGE="${REGISTRY}/${ADAPTER_REPOSITORY}@${adapter_digest}"
CONTROLLER_IMAGE="${REGISTRY}/${CONTROLLER_REPOSITORY}@${controller_digest}"
OWNERSHIP_INIT_IMAGE="${REGISTRY}/${OWNERSHIP_HELPER_REPOSITORY}@${ownership_helper_digest}"
RUNTIME_IMAGE="${REGISTRY}/${RUNTIME_REPOSITORY}@${runtime_digest}"
export ADAPTER_IMAGE CONTROLLER_IMAGE OWNERSHIP_INIT_IMAGE RUNTIME_IMAGE
export OWNERSHIP_HELPER_BUILDER_IMAGE
export SAMPLE_SOURCE_REVISION OCE_SOURCE_REVISION
export OCE_NODE_BUILD_BASE_IMAGE OCE_NODE_RUNTIME_BASE_IMAGE
export OPENSSL_BACKPORT_CVE OPENSSL_BACKPORT_PATCH_SHA256
export OPENSSL_BACKPORT_UPSTREAM_COMMIT
export OPENSSL_88823_BACKPORT_CVE OPENSSL_88823_BACKPORT_PATCH_SHA256
export OPENSSL_88823_TEST_PATCH_SHA256 OPENSSL_88823_BACKPORT_UPSTREAM_COMMIT
export OPENSSL_88823_TEST_UPSTREAM_COMMIT
export OPENSSL_DEBIAN_VERSION OPENSSL_PACKAGE_VERSION
export OPENCLAW_DEPENDENCY_PATCH_SHA256
export CURL_BACKPORT_CVE CURL_BACKPORT_PATCH_SHA256
export CURL_BACKPORT_UPSTREAM_COMMIT
export NPM_RUNTIME_VERSION NPM_RUNTIME_ARCHIVE_SHA256

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
        "oceSourceRevision": os.environ["OCE_SOURCE_REVISION"],
        "sourceRevision": os.environ["SAMPLE_SOURCE_REVISION"],
    },
    "ownershipHelper": {
        "builderImage": os.environ["OWNERSHIP_HELPER_BUILDER_IMAGE"],
        "image": os.environ["OWNERSHIP_INIT_IMAGE"],
        "sourceRevision": os.environ["SAMPLE_SOURCE_REVISION"],
    },
    "runtime": {
        "baseImage": os.environ["OCE_NODE_RUNTIME_BASE_IMAGE"],
        "buildBaseImage": os.environ["OCE_NODE_BUILD_BASE_IMAGE"],
        "image": os.environ["RUNTIME_IMAGE"],
        "oceSourceRevision": os.environ["OCE_SOURCE_REVISION"],
        "sourceRevision": os.environ["SAMPLE_SOURCE_REVISION"],
        "dependencyPatches": [
            {
                "component": "OpenClaw transitive dependencies",
                "patchSha256": os.environ["OPENCLAW_DEPENDENCY_PATCH_SHA256"],
            }
        ],
        "runtimePackages": [
            {
                "archiveSha256": os.environ["NPM_RUNTIME_ARCHIVE_SHA256"],
                "name": "npm",
                "version": os.environ["NPM_RUNTIME_VERSION"],
            }
        ],
        "securityBackports": [
            {
                "cve": os.environ["OPENSSL_BACKPORT_CVE"],
                "component": "Node.js embedded OpenSSL",
                "patchSha256": os.environ["OPENSSL_BACKPORT_PATCH_SHA256"],
                "upstreamCommit": os.environ["OPENSSL_BACKPORT_UPSTREAM_COMMIT"],
                "upstreamUrl": (
                    "https://github.com/openssl/openssl/commit/"
                    + os.environ["OPENSSL_BACKPORT_UPSTREAM_COMMIT"]
                ),
            },
            {
                "cve": os.environ["OPENSSL_88823_BACKPORT_CVE"],
                "component": "Node.js embedded and Debian OpenSSL",
                "debianSourceVersion": os.environ["OPENSSL_DEBIAN_VERSION"],
                "packageVersion": os.environ["OPENSSL_PACKAGE_VERSION"],
                "patchSha256": os.environ[
                    "OPENSSL_88823_BACKPORT_PATCH_SHA256"
                ],
                "testPatchSha256": os.environ[
                    "OPENSSL_88823_TEST_PATCH_SHA256"
                ],
                "upstreamCommit": os.environ[
                    "OPENSSL_88823_BACKPORT_UPSTREAM_COMMIT"
                ],
                "upstreamTestCommit": os.environ[
                    "OPENSSL_88823_TEST_UPSTREAM_COMMIT"
                ],
                "upstreamUrl": (
                    "https://github.com/openssl/openssl/commit/"
                    + os.environ["OPENSSL_88823_BACKPORT_UPSTREAM_COMMIT"]
                ),
            },
            {
                "cve": os.environ["CURL_BACKPORT_CVE"],
                "patchSha256": os.environ["CURL_BACKPORT_PATCH_SHA256"],
                "upstreamCommit": os.environ["CURL_BACKPORT_UPSTREAM_COMMIT"],
                "upstreamUrl": (
                    "https://github.com/curl/curl/commit/"
                    + os.environ["CURL_BACKPORT_UPSTREAM_COMMIT"]
                ),
            }
        ],
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(result, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
