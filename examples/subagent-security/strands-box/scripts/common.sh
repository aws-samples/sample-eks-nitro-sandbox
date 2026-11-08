#!/usr/bin/env bash
# Shared analyst lifecycle functions, with this sample's saved target checks.
SAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION_DIR="$(cd "$SAMPLE_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SECTION_DIR/../.." && pwd)"
SAMPLE=strands-box
TMP_DIR="$REPO_ROOT/tmp/$SAMPLE"
STATE_FILE="$TMP_DIR/state.env"
source "$SECTION_DIR/analyst/scripts/analyst-lib.sh"

# Override the shared substring classifier for this sample's AWS existence reads.
# An exact service exception with empty stdout confirms absence; all other failures stop.
lookup() {
  local notfound="$1" operation directory rc=0; shift
  case "$1 $2:$notfound" in
    "s3api get-bucket-tagging:NoSuchBucket") operation=GetBucketTagging ;;
    "iam get-role:NoSuchEntity") operation=GetRole ;;
    "ecr describe-repositories:RepositoryNotFoundException") operation=DescribeRepositories ;;
    "ecr describe-images:ImageNotFoundException") operation=DescribeImages ;;
    *) echo "ERROR: unsupported sample existence lookup" >&2; return 2 ;;
  esac
  directory="$(mktemp -d "$TMP_DIR/lookups/setup.XXXXXX")" || return 2
  aws "$@" >"$directory/stdout" 2>"$directory/stderr" || rc=$?
  if [[ "$rc" == 0 ]]; then cat "$directory/stdout"; return; fi
  if [[ -f "$directory/stdout" && ! -s "$directory/stdout" ]] &&
      python3 - "$directory/stderr" "$notfound" "$operation" <<'EXCEPTION'
from pathlib import Path
import re
import sys
message = Path(sys.argv[1]).read_text(errors="replace").strip()
match = re.fullmatch(r"(?:aws: \[ERROR\]: )?An error occurred \(([^()\r\n]+)\) when calling the ([A-Za-z0-9]+) operation: [^\r\n]*", message)
sys.exit(0 if match and match.groups() == tuple(sys.argv[2:]) else 1)
EXCEPTION
  then
    return 1
  fi
  echo "ERROR: AWS existence read failed; absence is unconfirmed. Diagnostics: $directory" >&2
  sed 's/^/  /' "$directory/stderr" >&2
  return 2
}

stop_if_undetermined() {
  [[ "$1" != 2 ]] || die "could not determine whether $2 exists; stopped before changing that resource"
}

# Quote values because the run record is read by Bash.
state_put() { printf '%s=%q\n' "$1" "$2" >> "$STATE_FILE"; }

box_mode() {
  DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-nitro}"
  case "$DEPLOYMENT_MODE" in
    eks|nitro) ;;
    *) die "DEPLOYMENT_MODE must be eks or nitro" ;;
  esac
}

# One stable owner per verified account, Region, cluster endpoint, and namespace.
# Keep SAMPLE_DIR, TMP_DIR, and STATE_FILE on the fixed sample paths above.
box_resource_owner() {
  python3 - "${ACCOUNT_ID:-}" "${AWS_REGION:-}" "${KUBE_SERVER:-}" "${NAMESPACE:-}" <<'OWNER'
import hashlib
import json
import re
import sys
account, region, server, namespace = sys.argv[1:]
if not re.fullmatch(r"[0-9]{12}", account) or not all((region, server, namespace)):
    sys.exit("A verified account, Region, Kubernetes server, and namespace are required")
encoded = json.dumps([account, region, server, namespace], separators=(",", ":")).encode()
print("strands-box-" + hashlib.sha256(encoded).hexdigest()[:20])
OWNER
}

# Never apply a saved generic owner or repository belonging to another target.
box_check_saved_ownership() {
  local expected
  expected="$(box_resource_owner)" || die "could not derive the saved deployment owner"
  [[ "${SAMPLE:-}" == "$expected" ]] ||
    die "the saved resource owner does not match this deployment target; refused to act"
  [[ "${ANALYST_REPOSITORY:-}" == "pod-isolation/subagent-analyst-$expected" &&
     "${SUPPLIER_API_REPOSITORY:-}" == "pod-isolation/subagent-analyst-$expected-supplier-api" ]] ||
    die "the saved ECR repositories do not match this deployment target; refused to act"
}

# Keep bucket creation local: S3 omits LocationConstraint only in us-east-1.
# Record creation before tagging so a tagging failure leaves an actionable receipt.
box_bucket() {
  say "5/7 the S3 bucket and the proposals"
  local rc=0
  local create_args=(--bucket "$BUCKET")
  lookup NoSuchBucket s3api get-bucket-tagging --bucket "$BUCKET" --output json \
    >"$TMP_DIR/bucket-tags.json" 2>/dev/null || rc=$?
  stop_if_undetermined "$rc" "the bucket $BUCKET"
  if [[ "$rc" == 0 ]]; then
    require_managed_by "the bucket $BUCKET" \
      "$(jq -r '.TagSet[]? | select(.Key=="ManagedBy") | .Value' "$TMP_DIR/bucket-tags.json")"
    echo "  reusing the bucket $BUCKET"
  else
    if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
      die "the bucket $BUCKET already exists without confirmed ownership; left it unchanged"
    fi
    if [[ "$AWS_REGION" != us-east-1 ]]; then
      create_args+=(--create-bucket-configuration "LocationConstraint=$AWS_REGION")
    fi
    aws s3api create-bucket "${create_args[@]}" >/dev/null || die "could not create the bucket $BUCKET"
    state_put BUCKET_CREATED true
    state_put BUCKET_TAGGED false
    state_put BUCKET_ROLLBACK_STATUS not-attempted
    if ! aws s3api put-bucket-tagging --bucket "$BUCKET" \
        --tagging "TagSet=[{Key=ManagedBy,Value=$SAMPLE}]"; then
      # Delete only the just-created empty bucket. Never empty an untagged bucket.
      if aws s3api delete-bucket --bucket "$BUCKET" >/dev/null; then
        state_put BUCKET_ROLLBACK_STATUS deleted
        die "tagging the new bucket $BUCKET failed; rolled back the empty bucket; creation receipt: $STATE_FILE"
      else
        state_put BUCKET_ROLLBACK_STATUS failed
        die "tagging the new bucket $BUCKET failed and rollback failed; kept the creation receipt at $STATE_FILE; verify ownership before recovery"
      fi
    fi
    state_put BUCKET_TAGGED true
    echo "  created the bucket $BUCKET"
  fi
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

  local f
  aws s3api put-object --bucket "$BUCKET" --key "proposals/$ANALYST_CASE/case.json" \
    --body "$SECTION_DIR/analyst/fixtures/case.json" >/dev/null
  for f in "${ANALYST_PROPOSALS[@]}"; do
    aws s3api put-object --bucket "$BUCKET" --key "proposals/$ANALYST_CASE/$f.json" \
      --body "$SECTION_DIR/analyst/fixtures/proposals/$f.json" >/dev/null
  done
  # Another case's object, so the page's denied read names a real object that is readable
  # with other credentials. Without it, AccessDenied could just be a missing key.
  printf '{"case_id":"rfp-other","note":"another case, outside the analyst role grant"}\n' \
    > "$TMP_DIR/rfp-other-case.json"
  aws s3api put-object --bucket "$BUCKET" --key "proposals/rfp-other/case.json" \
    --body "$TMP_DIR/rfp-other-case.json" >/dev/null
  echo "  seeded the case, ${#ANALYST_PROPOSALS[@]} proposals and one other case's object"
}

# The live Bedrock endpoint also authorizes the account's default project resource.
# Keep the inference-profile/model resources and the shared policy's existing actions.
box_add_default_project() {
  MODEL_RESOURCES="$(python3 - "$MODEL_RESOURCES" "$AWS_REGION" "$ACCOUNT_ID" <<'PROJECT'
import json
import re
import sys
resources = json.loads(sys.argv[1])
region, account = sys.argv[2:]
if not isinstance(resources, list) or not resources or not all(isinstance(item, str) for item in resources):
    sys.exit("Invalid Bedrock resource list")
profile = resources[0].split(":", 5)
if (len(profile) != 6 or profile[0] != "arn" or profile[1] not in ("aws", "aws-cn", "aws-us-gov")
        or profile[2] != "bedrock" or not profile[5]):
    sys.exit("Could not derive the AWS partition from the inference-profile ARN")
if not re.fullmatch(r"[a-z0-9-]+", region) or not re.fullmatch(r"[0-9]{12}", account):
    sys.exit("The verified Region and account are required for the default project")
project = f"arn:{profile[1]}:bedrock:{region}:{account}:project/default"
if project not in resources:
    resources.append(project)
print(json.dumps(resources))
PROJECT
)" || die "could not include the exact Bedrock default project resource"
}

# Check operator tools before setup invokes kubectl or creates resources.
box_require_tools() {
  local command
  for command in aws jq kubectl docker python3; do
    command -v "$command" >/dev/null 2>&1 || die "$command is required"
  done
  docker buildx version >/dev/null 2>&1 || die "Docker Buildx is required; install it before setup"
  docker info --format '{{.ServerVersion}}' >/dev/null 2>&1 ||
    die "Docker is not ready; start the Docker daemon before setup"
  box_require_arm64_builder
}

# Box publishes only a Linux ARM64 build, so both images are linux/arm64. Ask the builder
# image.sh uses (Docker with a fresh configuration) whether it can build that platform,
# before setup creates anything, rather than failing partway with "exec format error".
box_require_arm64_builder() {
  local config platforms
  mkdir -p "$TMP_DIR" || die "could not create $TMP_DIR"
  config="$(mktemp -d "$TMP_DIR/docker.XXXXXX")" || die "could not create a scratch Docker configuration"
  platforms="$(docker --config "$config" buildx inspect --bootstrap 2>/dev/null |
    sed -n 's/^Platforms:[[:space:]]*//p')" || platforms=""
  rm -rf -- "$config"
  tr ',' '\n' <<<"$platforms" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' |
    grep -xE 'linux/arm64(/v8)?' >/dev/null ||
    die "the Docker builder cannot build linux/arm64 images (it reports: ${platforms:-no platforms}). Run setup on an ARM64 host, or enable arm64 emulation for Docker Buildx: https://docs.docker.com/build/building/multi-platform/"
}

# The settings .env may hold. Read them as data, never source the file: a sourced line
# could set the scripts' own variables (the setup record path, the --delete-aws choice).
BOX_ENV_KEYS=(DEPLOYMENT_MODE CLUSTER_NAME AWS_REGION KUBE_CONTEXT NAMESPACE
  BEDROCK_MODEL_ID BUCKET ROLE_NAME AWS_PROFILE)

# Export the documented settings from the blueprint's .env, so a setting chosen there
# (such as AWS_PROFILE) applies to setup, run, and cleanup alike. Run and cleanup still
# take the deployment target from the setup record, which box_load_state loads over these.
box_load_env() {
  local file="$SAMPLE_DIR/.env" line key value known name
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] ||
      die "$file has a line that is not NAME=value: $line"
    key="${BASH_REMATCH[2]}" value="${BASH_REMATCH[3]}"
    known=false
    for name in "${BOX_ENV_KEYS[@]}"; do [[ "$key" == "$name" ]] && known=true; done
    [[ "$known" == true ]] ||
      die "$file sets $key, which this blueprint does not read from .env; remove it (allowed: ${BOX_ENV_KEYS[*]})"
    # One pair of surrounding quotes is removed; nothing in the value is expanded.
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then value="${BASH_REMATCH[1]}"; fi
    printf -v "$key" '%s' "$value"
    export "$key"
  done < "$file"
}

# EKS Auto Mode includes Pod Identity. Other nodes need its installed agent.
# Reuse either provider; never install or reconfigure a cluster-wide component.
box_cluster_prerequisites() {
  local cluster="$1" agent
  if jq -e '.cluster.computeConfig.enabled == true' <<<"$cluster" >/dev/null; then
    return
  fi
  agent="$(kc get daemonset eks-pod-identity-agent -n kube-system --ignore-not-found -o json)" ||
    die "could not inspect the Pod Identity agent; check cluster access before setup"
  [[ -n "$agent" ]] ||
    die "EKS Pod Identity is unavailable: enable Auto Mode or install the Pod Identity agent using the Getting started guide"
  jq -e '.status.desiredNumberScheduled > 0 and
    .status.numberReady == .status.desiredNumberScheduled' <<<"$agent" >/dev/null ||
    die "the installed EKS Pod Identity agent is not ready on all scheduled nodes; fix it before setup"
}

# Keep the shared preflight behavior without its unused TLS tool requirement.
box_preflight() {
  box_mode
  say "1/6 tools, selected EKS cluster and model access"
  local c info
  for c in aws jq kubectl docker python3; do
    command -v "$c" >/dev/null 2>&1 || die "$c is required"
  done
  [[ -n "$AWS_REGION" ]] || die "AWS_REGION is not set; copy .env.example to .env and fill it in"
  export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
  [[ -n "$CLUSTER_NAME" ]] || die "CLUSTER_NAME is not set; copy .env.example to .env and fill it in"
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" ||
    die "could not read the AWS account; check your credentials"
  echo "  account:  $ACCOUNT_ID"
  echo "  region:   $AWS_REGION"
  echo "  context:  $(kc config current-context)"
  if [[ "$DEPLOYMENT_MODE" == nitro ]]; then
    kc get runtimeclass isolated-sandbox -o name >/dev/null 2>&1 ||
      die "isolated-sandbox is unavailable; complete the Getting started samples before setup"
  fi
  info="$(aws bedrock get-inference-profile --inference-profile-identifier "$BEDROCK_MODEL_ID" \
    --output json 2>/dev/null)" ||
    die "could not read the Bedrock inference profile '$BEDROCK_MODEL_ID' in $AWS_REGION. Check BEDROCK_MODEL_ID in .env and that the account has access to it."
  MODEL_RESOURCES="$(jq -c '[.inferenceProfileArn] + [.models[].modelArn]' <<<"$info")"
  box_add_default_project
  echo "  model:    $BEDROCK_MODEL_ID"
}

box_load_state() {
  local requested_mode="${DEPLOYMENT_MODE:-}"
  [[ -f "$STATE_FILE" ]] || die "no setup record at $STATE_FILE; run ./scripts/setup.sh first"
  unset SAMPLE NAMESPACE CLUSTER_NAME AWS_REGION KUBE_CONTEXT KUBE_SERVER ACCOUNT_ID DEPLOYMENT_MODE \
    BUCKET ROLE_NAME BEDROCK_MODEL_ID ANALYST_IMAGE SETUP_COMPLETE ANALYST_REPOSITORY SUPPLIER_API_REPOSITORY
  set -a
  source "$STATE_FILE"
  set +a
  box_mode
  [[ -z "$requested_mode" || "$requested_mode" == "$DEPLOYMENT_MODE" ]] ||
    die "DEPLOYMENT_MODE differs from the saved setup record; clean that deployment before changing modes"
  local name
  for name in NAMESPACE CLUSTER_NAME AWS_REGION KUBE_CONTEXT KUBE_SERVER ACCOUNT_ID; do
    [[ -n "${!name:-}" ]] || die "the setup record has no $name; run setup again"
  done
  box_check_saved_ownership
  export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
  mkdir -p "$TMP_DIR/lookups"
  export TMPDIR="$TMP_DIR/lookups"
}

box_check_target() {
  local server account
  server="$(kc config view --minify -o jsonpath='{.clusters[0].cluster.server}')" ||
    die "could not read the saved Kubernetes context $KUBE_CONTEXT"
  [[ -n "$server" && "$server" == "$KUBE_SERVER" ]] ||
    die "context $KUBE_CONTEXT no longer points to the cluster recorded by setup"
  account="$(aws sts get-caller-identity --query Account --output text)" ||
    die "could not confirm the AWS account"
  [[ "$account" == "$ACCOUNT_ID" ]] || die "the active AWS account differs from the setup record"
}

# Print absent or owned; a foreign namespace or an uncertain lookup is a failure.
box_namespace_state() {
  local document label
  document="$(kc get namespace "$NAMESPACE" --ignore-not-found -o json)" || {
    echo "ERROR: could not determine whether namespace $NAMESPACE exists" >&2
    return 1
  }
  if [[ -z "$document" ]]; then printf 'absent\n'; return; fi
  label="$(jq -er '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<<"$document")" || {
    echo "ERROR: could not read ownership of namespace $NAMESPACE" >&2
    return 1
  }
  [[ "$label" == "$SAMPLE" ]] || {
    echo "ERROR: namespace $NAMESPACE is not owned by $SAMPLE; left it alone" >&2
    return 1
  }
  printf 'owned\n'
}
