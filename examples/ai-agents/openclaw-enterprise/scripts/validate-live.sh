#!/usr/bin/env bash
set +x
set -Eeuo pipefail

umask 077

AGW_NAMESPACE="openclaw-enterprise-agw"
AGW_DEPLOYMENT="agentgateway"
MODEL_ALIAS="nova-lite"
EXPECTED_MODEL_TEXT="OK"
OCE_FORBIDDEN_CODE="FORBIDDEN"
EXPECTED_OCE_SOURCE_REVISION="86c8c12310f691bb21651118ffffd6bfd460e9ff"
CONTROLLER_DENIAL="admission caller is not an allowed controller identity for this resource"
EPHEMERAL_DENIAL="ephemeral containers are not permitted in OpenClaw Enterprise managed namespaces"
PERSISTENT_MARKER="/home/node/.openclaw/.live-validation-marker"
EPHEMERAL_MARKER="/home/node/.live-validation-marker"
PERSISTENT_HOME="/home/node/.openclaw"

AWS_ACCOUNT_ID=""
AWS_REGION=""
EKS_CLUSTER=""
KUBE_CONTEXT=""
TENANT_A_NAMESPACE=""
TENANT_A_POD=""
TENANT_A_CONTAINER=""
TENANT_B_NAMESPACE=""
TENANT_B_POD=""
TENANT_B_CONTAINER=""
RUNTIME_IMAGE=""
OCE_API_LOCAL_PORT=""
OCE_API_SERVICE_PORT="8080"
OCE_API_URL=""
OCE_SYSTEM_NAMESPACE=""
OCE_SOURCE_REVISION=""
TENANT_A_OCE_NAMESPACE=""
TENANT_A_AGENT_ID=""
TENANT_A_CREDENTIAL_FILE=""
TENANT_B_OCE_NAMESPACE=""
TENANT_B_AGENT_ID=""
TENANT_B_CREDENTIAL_FILE=""
EVIDENCE_DIR=""
KMS_SIGNING_KEY_ID=""
CONFIRM_POD_REPLACEMENT="false"
TIMEOUT_SECONDS=600

WORK_DIR=""
EVIDENCE_FILE=""
MANIFEST_FILE=""
SIGNATURE_FILE=""
CURRENT_CHECK="argument-validation"
MARKERS_CREATED="false"
REPLACEMENT_POD=""
NETWORK_VALIDATION_NAMESPACE=""
NETWORK_VALIDATION_CREATED="false"
NETWORK_POLICY_NAME=""
CROSS_TENANT_PVC_POD=""
CROSS_TENANT_PVC_POD_UID=""
KMS_CANONICAL_KEY_ID=""
KMS_KEY_ID_HASH=""
OCE_PORT_FORWARD_PID=""
OCE_PORT_FORWARD_LOG=""
OCE_PORT_FORWARD_CLEANED="false"
FINAL_EVIDENCE_CANDIDATE=""
FINAL_MANIFEST_CANDIDATE=""
FINAL_SIGNATURE_CANDIDATE=""
EVIDENCE_PREPASS_BACKUP=""

usage() {
  printf '%s\n' \
    'Usage: validate-live.sh [required options]' \
    '' \
    'Required:' \
    '  --account-id ID' \
    '  --region us-west-2' \
    '  --cluster NAME' \
    '  --kube-context NAME' \
    '  --tenant-a-namespace NAME' \
    '  --tenant-a-pod NAME' \
    '  --tenant-a-container NAME' \
    '  --tenant-b-namespace NAME' \
    '  --tenant-b-pod NAME' \
    '  --tenant-b-container NAME' \
    '  --runtime-image REPOSITORY@sha256:DIGEST' \
    '  --oce-api-local-port PORT' \
    '  --oce-system-namespace NAME' \
    '  --oce-source-revision COMMIT' \
    '  --tenant-a-oce-namespace ns_ID' \
    '  --tenant-a-agent-id agt_ID' \
    '  --tenant-a-credential-file PATH' \
    '  --tenant-b-oce-namespace ns_ID' \
    '  --tenant-b-agent-id agt_ID' \
    '  --tenant-b-credential-file PATH' \
    '  --evidence-dir PATH' \
    '  --confirm-pod-replacement' \
    '' \
    'Optional:' \
    '  --timeout-seconds SECONDS  Replacement timeout (default: 600)' \
    '  --kms-signing-key-id KEY   KMS signing key ID or ARN; evidence is unsigned when omitted'
}

die() {
  printf 'ERROR [%s]: %s\n' "$CURRENT_CHECK" "$1" >&2
  exit 1
}

record_pass() {
  printf 'PASS\t%s\t%s\n' "$1" "$2" >>"$EVIDENCE_FILE"
}

sha256_file() {
  local digest_output digest
  digest_output="$(openssl dgst -sha256 -r "$1")" ||
    die "could not hash file"
  digest="${digest_output%% *}"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "hash command returned an invalid SHA-256 digest"
  printf '%s' "$digest"
}

sha256_text() {
  local digest_output digest
  digest_output="$(printf '%s' "$1" | openssl dgst -sha256 -r)" ||
    die "could not hash value"
  digest="${digest_output%% *}"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "hash command returned an invalid SHA-256 digest"
  printf '%s' "$digest"
}

write_manifest() {
  [[ -n "$EVIDENCE_FILE" && -f "$EVIDENCE_FILE" && -n "$MANIFEST_FILE" ]] || return 0
  write_manifest_to "$MANIFEST_FILE" "$EVIDENCE_FILE" "$SIGNATURE_FILE"
}

write_manifest_to() {
  local output_file="$1"
  local evidence_input="$2"
  local signature_input="${3:-}"
  local evidence_digest
  evidence_digest="$(sha256_file "$evidence_input")"
  printf '%s  %s\n' "$evidence_digest" "$(basename "$EVIDENCE_FILE")" >"$output_file"
  if [[ -n "$signature_input" && -f "$signature_input" ]]; then
    printf '%s  %s\n' "$(sha256_file "$signature_input")" "$(basename "$SIGNATURE_FILE")" \
      >>"$output_file"
  fi
  chmod 600 "$output_file"
}

kube() {
  kubectl --context "$KUBE_CONTEXT" "$@"
}

oce_api_port_is_ready() {
  node -e '
    const net = require("node:net");
    const port = Number(process.argv[1]);
    const socket = net.createConnection({host: "127.0.0.1", port}, () => {
      socket.destroy();
      process.exit(0);
    });
    socket.setTimeout(500, () => {
      socket.destroy();
      process.exit(1);
    });
    socket.on("error", () => process.exit(1));
  ' "$OCE_API_LOCAL_PORT" >/dev/null 2>&1
}

start_oce_api_port_forward() {
  [[ -z "$OCE_PORT_FORWARD_PID" ]] || die "OCE API port-forward is already running"
  if oce_api_port_is_ready; then
    die "OCE API local port is already accepting connections"
  fi

  OCE_PORT_FORWARD_LOG="$WORK_DIR/oce-api-port-forward.log"
  : >"$OCE_PORT_FORWARD_LOG"
  chmod 600 "$OCE_PORT_FORWARD_LOG"
  kubectl --context "$KUBE_CONTEXT" -n "$OCE_SYSTEM_NAMESPACE" port-forward \
    --address=127.0.0.1 \
    service/openclaw-enterprise-api \
    "${OCE_API_LOCAL_PORT}:${OCE_API_SERVICE_PORT}" \
    >"$OCE_PORT_FORWARD_LOG" 2>&1 &
  OCE_PORT_FORWARD_PID=$!
  OCE_PORT_FORWARD_CLEANED="false"

  local attempt
  for ((attempt = 0; attempt < 50; attempt += 1)); do
    if ! kill -0 "$OCE_PORT_FORWARD_PID" 2>/dev/null; then
      wait "$OCE_PORT_FORWARD_PID" 2>/dev/null || true
      OCE_PORT_FORWARD_PID=""
      OCE_API_URL=""
      OCE_PORT_FORWARD_CLEANED="true"
      die "OCE API port-forward exited before becoming ready"
    fi
    if grep -Fq \
      "Forwarding from 127.0.0.1:${OCE_API_LOCAL_PORT} -> ${OCE_API_SERVICE_PORT}" \
      "$OCE_PORT_FORWARD_LOG" &&
      oce_api_port_is_ready &&
      kill -0 "$OCE_PORT_FORWARD_PID" 2>/dev/null; then
      OCE_API_URL="http://127.0.0.1:${OCE_API_LOCAL_PORT}"
      return 0
    fi
    sleep 0.2
  done
  die "OCE API port-forward did not become ready on the explicit loopback port"
}

stop_oce_api_port_forward() {
  local pid="${OCE_PORT_FORWARD_PID:-}"
  [[ -n "$pid" ]] || return 0

  if kill -0 "$pid" 2>/dev/null; then
    if ! kill "$pid" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    local attempt
    for ((attempt = 0; attempt < 50; attempt += 1)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      if ! kill -KILL "$pid" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
        return 1
      fi
    fi
  fi
  local wait_status
  if wait "$pid" 2>/dev/null; then
    wait_status=0
  else
    wait_status=$?
  fi
  ((wait_status != 127)) || return 1
  kill -0 "$pid" 2>/dev/null && return 1
  OCE_PORT_FORWARD_PID=""
  OCE_API_URL=""
  OCE_PORT_FORWARD_CLEANED="true"
}

cleanup_markers() {
  [[ "$MARKERS_CREATED" == "true" ]] || return 0
  local pod
  for pod in "$TENANT_A_POD" "$REPLACEMENT_POD"; do
    [[ -n "$pod" ]] || continue
    kube -n "$TENANT_A_NAMESPACE" exec "$pod" -c "$TENANT_A_CONTAINER" -- \
      rm -f -- "$PERSISTENT_MARKER" "$EPHEMERAL_MARKER" >/dev/null 2>&1 || true
  done
}

delete_pod_with_uid() {
  local namespace="$1"
  local pod="$2"
  local uid="$3"
  local delete_options="$4"
  [[ "$uid" =~ ^[A-Za-z0-9._:-]+$ ]] || die "pod UID is invalid"
  printf '{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":"%s"}}\n' \
    "$uid" >"$delete_options"
  kube delete \
    --raw="/api/v1/namespaces/${namespace}/pods/${pod}" \
    -f "$delete_options" >/dev/null
}

cleanup_cross_tenant_pvc_probe() {
  [[ -n "$CROSS_TENANT_PVC_POD" ]] || return 0
  if [[ -z "$CROSS_TENANT_PVC_POD_UID" ]]; then
    local recovered_probe="$WORK_DIR/cross-tenant-pvc-pod-recovered.json"
    kube -n "$TENANT_A_NAMESPACE" get pod "$CROSS_TENANT_PVC_POD" -o json \
      >"$recovered_probe" || return 1
    jq -e \
      --arg namespace "$TENANT_A_NAMESPACE" \
      --arg name "$CROSS_TENANT_PVC_POD" \
      --arg image "$RUNTIME_IMAGE" \
      --arg pvc "$TENANT_B_PVC" '
      .metadata.namespace == $namespace
      and .metadata.name == $name
      and .metadata.labels["openclaw.dev/validation"] == "cross-tenant-pvc"
      and (.metadata.uid | type == "string" and length > 0)
      and (.spec.containers | length == 1)
      and .spec.containers[0].name == "cross-tenant-pvc"
      and .spec.containers[0].image == $image
      and .spec.containers[0].command == ["sh", "-c", "sleep 3600"]
      and .spec.containers[0].volumeMounts == [{
        "name": "cross-tenant-pvc",
        "mountPath": "/cross-tenant"
      }]
      and (.spec.volumes | length == 1)
      and .spec.volumes[0].name == "cross-tenant-pvc"
      and .spec.volumes[0].persistentVolumeClaim.claimName == $pvc
      and .spec.automountServiceAccountToken == false
      and .spec.enableServiceLinks == false
      and .spec.restartPolicy == "Never"
    ' "$recovered_probe" >/dev/null || return 1
    CROSS_TENANT_PVC_POD_UID="$(jq -er '.metadata.uid' "$recovered_probe")" || return 1
  fi
  delete_pod_with_uid \
    "$TENANT_A_NAMESPACE" \
    "$CROSS_TENANT_PVC_POD" \
    "$CROSS_TENANT_PVC_POD_UID" \
    "$WORK_DIR/cross-tenant-pvc-delete-options.json"
  kube -n "$TENANT_A_NAMESPACE" wait \
    --for=delete "pod/$CROSS_TENANT_PVC_POD" --timeout=60s >/dev/null
  CROSS_TENANT_PVC_POD=""
  CROSS_TENANT_PVC_POD_UID=""
}

cleanup_network_validation() {
  [[ -n "$NETWORK_VALIDATION_NAMESPACE" ]] || return 0
  if [[ -n "$NETWORK_POLICY_NAME" ]]; then
    kube -n "$TENANT_A_NAMESPACE" delete networkpolicy "$NETWORK_POLICY_NAME" \
      --ignore-not-found --wait=true >/dev/null
    kube -n "$TENANT_B_NAMESPACE" delete networkpolicy "$NETWORK_POLICY_NAME" \
      --ignore-not-found --wait=true >/dev/null
  fi
  if [[ "$NETWORK_VALIDATION_CREATED" == "true" ]]; then
    kube delete namespace "$NETWORK_VALIDATION_NAMESPACE" \
      --ignore-not-found --wait=true >/dev/null
  fi
  NETWORK_VALIDATION_NAMESPACE=""
  NETWORK_VALIDATION_CREATED="false"
  NETWORK_POLICY_NAME=""
}

on_exit() {
  local status=$?
  trap - EXIT
  set +e
  stop_oce_api_port_forward >/dev/null 2>&1
  cleanup_markers
  cleanup_cross_tenant_pvc_probe >/dev/null 2>&1
  cleanup_network_validation >/dev/null 2>&1
  if [[ -n "$FINAL_EVIDENCE_CANDIDATE" ]]; then
    rm -f -- "$FINAL_EVIDENCE_CANDIDATE"
  fi
  if [[ -n "$FINAL_MANIFEST_CANDIDATE" ]]; then
    rm -f -- "$FINAL_MANIFEST_CANDIDATE"
  fi
  if [[ -n "$FINAL_SIGNATURE_CANDIDATE" ]]; then
    rm -f -- "$FINAL_SIGNATURE_CANDIDATE"
  fi
  if [[ $status -ne 0 && -n "$EVIDENCE_FILE" && -f "$EVIDENCE_FILE" ]]; then
    rm -f -- "$SIGNATURE_FILE" "$MANIFEST_FILE"
    if [[ -n "$EVIDENCE_PREPASS_BACKUP" && -f "$EVIDENCE_PREPASS_BACKUP" ]]; then
      cp -- "$EVIDENCE_PREPASS_BACKUP" "$EVIDENCE_FILE"
    fi
    printf 'CLEANUP\tFAILURE-PATH\tbest-effort cleanup attempted\n' >>"$EVIDENCE_FILE"
    printf 'FAIL\t%s\tvalidation stopped; inspect stderr\n' "$CURRENT_CHECK" >>"$EVIDENCE_FILE"
    write_manifest
  fi
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
  exit "$status"
}
trap on_exit EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm-pod-replacement|--help|-h) ;;
    --*) [[ $# -ge 2 ]] || die "option requires a value: $1" ;;
  esac
  case "$1" in
    --account-id) AWS_ACCOUNT_ID="${2:-}"; shift 2 ;;
    --region) AWS_REGION="${2:-}"; shift 2 ;;
    --cluster) EKS_CLUSTER="${2:-}"; shift 2 ;;
    --kube-context) KUBE_CONTEXT="${2:-}"; shift 2 ;;
    --tenant-a-namespace) TENANT_A_NAMESPACE="${2:-}"; shift 2 ;;
    --tenant-a-pod) TENANT_A_POD="${2:-}"; shift 2 ;;
    --tenant-a-container) TENANT_A_CONTAINER="${2:-}"; shift 2 ;;
    --tenant-b-namespace) TENANT_B_NAMESPACE="${2:-}"; shift 2 ;;
    --tenant-b-pod) TENANT_B_POD="${2:-}"; shift 2 ;;
    --tenant-b-container) TENANT_B_CONTAINER="${2:-}"; shift 2 ;;
    --runtime-image) RUNTIME_IMAGE="${2:-}"; shift 2 ;;
    --oce-api-local-port) OCE_API_LOCAL_PORT="${2:-}"; shift 2 ;;
    --oce-system-namespace) OCE_SYSTEM_NAMESPACE="${2:-}"; shift 2 ;;
    --oce-source-revision) OCE_SOURCE_REVISION="${2:-}"; shift 2 ;;
    --tenant-a-oce-namespace) TENANT_A_OCE_NAMESPACE="${2:-}"; shift 2 ;;
    --tenant-a-agent-id) TENANT_A_AGENT_ID="${2:-}"; shift 2 ;;
    --tenant-a-credential-file) TENANT_A_CREDENTIAL_FILE="${2:-}"; shift 2 ;;
    --tenant-b-oce-namespace) TENANT_B_OCE_NAMESPACE="${2:-}"; shift 2 ;;
    --tenant-b-agent-id) TENANT_B_AGENT_ID="${2:-}"; shift 2 ;;
    --tenant-b-credential-file) TENANT_B_CREDENTIAL_FILE="${2:-}"; shift 2 ;;
    --evidence-dir) EVIDENCE_DIR="${2:-}"; shift 2 ;;
    --kms-signing-key-id) KMS_SIGNING_KEY_ID="${2:-}"; shift 2 ;;
    --confirm-pod-replacement) CONFIRM_POD_REPLACEMENT="true"; shift ;;
    --timeout-seconds) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "unknown argument" ;;
  esac
done

required_values=(
  AWS_ACCOUNT_ID AWS_REGION EKS_CLUSTER KUBE_CONTEXT
  TENANT_A_NAMESPACE TENANT_A_POD TENANT_A_CONTAINER
  TENANT_B_NAMESPACE TENANT_B_POD TENANT_B_CONTAINER
  RUNTIME_IMAGE OCE_API_LOCAL_PORT OCE_SYSTEM_NAMESPACE
  OCE_SOURCE_REVISION
  TENANT_A_OCE_NAMESPACE TENANT_A_AGENT_ID TENANT_A_CREDENTIAL_FILE
  TENANT_B_OCE_NAMESPACE TENANT_B_AGENT_ID TENANT_B_CREDENTIAL_FILE
  EVIDENCE_DIR
)
for required_name in "${required_values[@]}"; do
  [[ -n "${!required_name:-}" ]] || die "missing required option; use --help"
done
[[ "$CONFIRM_POD_REPLACEMENT" == "true" ]] ||
  die "--confirm-pod-replacement is required because this test deletes one managed pod"

[[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die "AWS account ID must contain exactly 12 digits"
[[ "$AWS_REGION" == "us-west-2" ]] || die "region must be exactly us-west-2"
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "timeout must be a positive integer"
((TIMEOUT_SECONDS <= 3600)) || die "timeout must not exceed 3600 seconds"
[[ "$RUNTIME_IMAGE" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] ||
  die "runtime image must be pinned as repository@sha256:<64 lowercase hex characters>"
[[ "$OCE_API_LOCAL_PORT" =~ ^[0-9]+$ ]] ||
  die "OCE API local port must be an integer"
((OCE_API_LOCAL_PORT >= 1024 && OCE_API_LOCAL_PORT <= 65535)) ||
  die "OCE API local port must be between 1024 and 65535"
[[ "$OCE_SYSTEM_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ &&
  ${#OCE_SYSTEM_NAMESPACE} -le 63 ]] ||
  die "OCE system namespace must be a Kubernetes DNS label"
[[ "$OCE_SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] ||
  die "OCE source revision must be a full lowercase Git commit SHA"
[[ "$OCE_SOURCE_REVISION" == "$EXPECTED_OCE_SOURCE_REVISION" ]] ||
  die "OCE source revision must match this sample's reviewed pin"
[[ "$TENANT_A_OCE_NAMESPACE" =~ ^ns_[A-Za-z0-9-]+$ ]] ||
  die "tenant A OCE namespace ID is invalid"
[[ "$TENANT_B_OCE_NAMESPACE" =~ ^ns_[A-Za-z0-9-]+$ ]] ||
  die "tenant B OCE namespace ID is invalid"
[[ "$TENANT_A_AGENT_ID" =~ ^agt_[A-Za-z0-9-]+$ ]] || die "tenant A agent ID is invalid"
[[ "$TENANT_B_AGENT_ID" =~ ^agt_[A-Za-z0-9-]+$ ]] || die "tenant B agent ID is invalid"
[[ "$TENANT_A_NAMESPACE" != "$TENANT_B_NAMESPACE" ]] ||
  die "tenant Kubernetes namespaces must be distinct"
[[ "$TENANT_A_OCE_NAMESPACE" != "$TENANT_B_OCE_NAMESPACE" ]] ||
  die "tenant OCE namespace IDs must be distinct"
[[ "$TENANT_A_AGENT_ID" != "$TENANT_B_AGENT_ID" ]] ||
  die "tenant agent IDs must be distinct"
for dns_label in \
  "$TENANT_A_NAMESPACE" "$TENANT_B_NAMESPACE" "$OCE_SYSTEM_NAMESPACE" \
  "$TENANT_A_CONTAINER" "$TENANT_B_CONTAINER"; do
  [[ ${#dns_label} -le 63 &&
    "$dns_label" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    die "namespace and container values must be Kubernetes DNS labels"
done
for pod_name in "$TENANT_A_POD" "$TENANT_B_POD"; do
  [[ ${#pod_name} -le 253 &&
    "$pod_name" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] ||
    die "pod values must be Kubernetes DNS subdomains"
done

for command_name in \
  awk aws basename cat chmod cp date git grep id jq kubectl mkdir mktemp node openssl rm sed sleep \
  stat uname; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is unavailable: $command_name"
done

read_credential() {
  local file="$1"
  local credential_blob metadata value
  local file_owner file_links mode file_size
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] ||
    die "credential file must be a readable regular, non-symlink file"
  exec 3<"$file" || die "could not open credential file"
  if metadata="$(stat -f '%u %l %Lp %z' /dev/fd/3 2>/dev/null)"; then
    :
  elif metadata="$(stat -Lc '%u %h %a %s' /proc/self/fd/3 2>/dev/null)"; then
    :
  else
    exec 3<&-
    die "could not inspect the opened credential file"
  fi
  read -r file_owner file_links mode file_size <<<"$metadata"
  [[ "$file_owner" == "$(id -u)" ]] || {
    exec 3<&-
    die "credential file must be owned by the effective user"
  }
  [[ "$file_links" == "1" ]] || {
    exec 3<&-
    die "credential file must have exactly one hard link"
  }
  [[ "$mode" == "400" || "$mode" == "600" ]] ||
    {
      exec 3<&-
      die "credential file permissions must be 0400 or 0600"
    }
  [[ "$file_size" =~ ^[0-9]+$ && "$file_size" -gt 0 && "$file_size" -le 8192 ]] ||
    {
      exec 3<&-
      die "credential file must contain between 1 and 8192 bytes"
    }
  if IFS= read -r -d '' credential_blob <&3; then
    exec 3<&-
    die "credential file must not contain NUL bytes"
  fi
  exec 3<&-
  if value="$(printf '%s' "$credential_blob" | jq -er '
      if (.data.key | type == "string" and length > 0)
      then .data.key
      else error("missing service key")
      end
    ' 2>/dev/null)"; then
    :
  else
    [[ "$credential_blob" != *$'\n'* && "$credential_blob" != *$'\r'* ]] ||
      die "credential file must be an OCE service-key response or one raw-key line"
    value="$credential_blob"
  fi
  unset credential_blob
  [[ -n "$value" && ${#value} -le 4096 ]] || die "credential must contain one non-empty value"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] ||
    die "credential must contain exactly one line"
  [[ "$value" =~ ^[A-Za-z0-9._~+/=-]+$ ]] ||
    die "credential contains characters unsafe for non-interactive validation"
  printf '%s' "$value"
}

TENANT_A_CREDENTIAL="$(read_credential "$TENANT_A_CREDENTIAL_FILE")"
TENANT_B_CREDENTIAL="$(read_credential "$TENANT_B_CREDENTIAL_FILE")"
[[ "$TENANT_A_CREDENTIAL" != "$TENANT_B_CREDENTIAL" ]] ||
  die "tenant credentials must be distinct"

if [[ -e "$EVIDENCE_DIR" && -L "$EVIDENCE_DIR" ]]; then
  die "evidence directory must not be a symlink"
fi
mkdir -p -- "$EVIDENCE_DIR"
[[ -d "$EVIDENCE_DIR" ]] || die "evidence path is not a directory"
EVIDENCE_FILE="$EVIDENCE_DIR/live-validation-evidence.txt"
MANIFEST_FILE="$EVIDENCE_DIR/live-validation-manifest.sha256"
SIGNATURE_FILE="$EVIDENCE_DIR/live-validation-evidence.sig.b64"
[[ ! -e "$EVIDENCE_FILE" ]] || die "evidence file already exists; choose a fresh directory"
[[ ! -e "$MANIFEST_FILE" && ! -e "$SIGNATURE_FILE" ]] ||
  die "evidence manifest or signature already exists; choose a fresh directory"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oce-live-validation.XXXXXX")"
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
REPO_ROOT="$(git -C "$(dirname "$SCRIPT_PATH")" rev-parse --show-toplevel)"
GIT_REVISION="$(git -C "$REPO_ROOT" rev-parse --verify 'HEAD^{commit}')"
[[ "$GIT_REVISION" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve an exact Git revision"
VALIDATOR_SHA256="$(sha256_file "$SCRIPT_PATH")"
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" ]]; then
  GIT_WORKTREE_STATE="dirty"
else
  GIT_WORKTREE_STATE="clean"
fi
VALIDATION_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
AWS_VERSION="$(aws --version 2>&1)"
KUBECTL_VERSION="$(kube version --client -o json | jq -er '
  .clientVersion.gitVersion + " " + .clientVersion.platform
')"
JQ_VERSION="$(jq --version)"
GIT_VERSION="$(git --version)"
OPENSSL_VERSION="$(openssl version)"
NODE_VERSION="$(node --version)"
for version_value in \
  "$AWS_VERSION" "$KUBECTL_VERSION" "$JQ_VERSION" "$GIT_VERSION" "$OPENSSL_VERSION" \
  "$NODE_VERSION"; do
  [[ "$version_value" =~ ^[[:print:]]+$ ]] || die "tool version contained unsafe characters"
done
{
  printf 'OpenClaw Enterprise live validation\n'
  printf 'EVIDENCE\tvalidation-start\t%s\n' "$VALIDATION_STARTED_AT"
  printf 'EVIDENCE\tgit-revision\t%s\n' "$GIT_REVISION"
  printf 'EVIDENCE\tgit-worktree-state\t%s\n' "$GIT_WORKTREE_STATE"
  printf 'EVIDENCE\tvalidator-sha256\t%s\n' "$VALIDATOR_SHA256"
  printf 'EVIDENCE\toce-source-revision\t%s\n' "$OCE_SOURCE_REVISION"
  printf 'EVIDENCE\ttool-version-aws\t%s\n' "$AWS_VERSION"
  printf 'EVIDENCE\ttool-version-kubectl\t%s\n' "$KUBECTL_VERSION"
  printf 'EVIDENCE\ttool-version-jq\t%s\n' "$JQ_VERSION"
  printf 'EVIDENCE\ttool-version-git\t%s\n' "$GIT_VERSION"
  printf 'EVIDENCE\ttool-version-openssl\t%s\n' "$OPENSSL_VERSION"
  printf 'EVIDENCE\ttool-version-node\t%s\n' "$NODE_VERSION"
  printf 'Region\tus-west-2\n'
} >"$EVIDENCE_FILE"

CURRENT_CHECK="aws-identity"
aws sts get-caller-identity --output json >"$WORK_DIR/aws-identity.json"
jq -e --arg account "$AWS_ACCOUNT_ID" '.Account == $account' \
  "$WORK_DIR/aws-identity.json" >/dev/null || die "authenticated AWS account does not match"
record_pass "aws-identity" "explicit account matched"

CURRENT_CHECK="eks-cluster"
aws eks describe-cluster --region "$AWS_REGION" --name "$EKS_CLUSTER" --output json \
  >"$WORK_DIR/eks-cluster.json"
jq -e --arg account "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" --arg name "$EKS_CLUSTER" '
  .cluster.status == "ACTIVE"
  and .cluster.name == $name
  and .cluster.arn == ("arn:aws:eks:" + $region + ":" + $account + ":cluster/" + $name)
  and (.cluster.endpoint | type == "string" and startswith("https://"))
' "$WORK_DIR/eks-cluster.json" >/dev/null || die "EKS cluster identity or status did not match"
EKS_ENDPOINT="$(jq -r '.cluster.endpoint' "$WORK_DIR/eks-cluster.json")"
EKS_CLUSTER_ARN="$(jq -er '.cluster.arn' "$WORK_DIR/eks-cluster.json")"
printf 'EVIDENCE\tcluster-arn-sha256\t%s\n' "$(sha256_text "$EKS_CLUSTER_ARN")" \
  >>"$EVIDENCE_FILE"
unset EKS_CLUSTER_ARN

CURRENT_CHECK="kube-context"
[[ "$(kube config get-contexts "$KUBE_CONTEXT" --no-headers -o name)" == "$KUBE_CONTEXT" ]] ||
  die "requested kube context does not exist"
kube config view --minify -o json >"$WORK_DIR/kube-context.json"
jq -e --arg endpoint "$EKS_ENDPOINT" \
  '.clusters | length == 1 and .[0].cluster.server == $endpoint' \
  "$WORK_DIR/kube-context.json" >/dev/null || die "kube context endpoint does not match the EKS cluster"
[[ "$(kube get --raw=/readyz)" == "ok" ]] || die "Kubernetes API readyz check failed"
record_pass "cluster-binding" "account, EKS cluster, context, and API readiness matched"

pod_container_digest() {
  local pod_file="$1"
  local container="$2"
  local digest
  digest="$(jq -er --arg container "$container" '
    first(
      .status.containerStatuses[]
      | select(.name == $container)
      | .imageID
      | capture("(?<digest>sha256:[0-9a-f]{64})$").digest
    )
  ' "$pod_file")" || die "workload image ID did not contain an immutable digest"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "workload image ID contained an invalid digest"
  printf '%s' "$digest"
}

verify_runtime_pod() {
  local tenant_alias="$1"
  local namespace="$2"
  local pod="$3"
  local container="$4"
  local oce_namespace="$5"
  local agent_id="$6"
  local output_file="$7"
  local digest="${RUNTIME_IMAGE##*@}"

  kube -n "$namespace" get pod "$pod" -o json >"$output_file"
  jq -e \
    --arg namespace "$namespace" \
    --arg container "$container" \
    --arg image "$RUNTIME_IMAGE" \
    --arg digest "$digest" \
    --arg oce_namespace "$oce_namespace" \
    --arg agent_id "$agent_id" '
    .metadata.namespace == $namespace
    and .metadata.labels["app.kubernetes.io/managed-by"] == "openclaw-enterprise"
    and .metadata.labels["openclaw.dev/workload-role"] == "gateway"
    and .metadata.labels["openclaw.dev/namespace"] == $oce_namespace
    and .metadata.labels["openclaw.dev/agent"] == $agent_id
    and (.metadata.labels["openclaw.dev/revision"] | test("^rev_[A-Za-z0-9-]+$"))
    and (.metadata.uid | type == "string" and length > 0)
    and .spec.runtimeClassName == "isolated-sandbox"
    and .spec.automountServiceAccountToken == false
    and (.spec.containers | any(.name == $container and .image == $image))
    and (.status.phase == "Running")
    and (.status.containerStatuses | any(
      .name == $container and .ready == true and .state.running != null
      and (
        (.imageID | endswith("@" + $digest))
        or (.imageID | endswith("://" + $digest))
      )
    ))
  ' "$output_file" >/dev/null || die "$tenant_alias runtime identity, image, or readiness check failed"

  jq -e --arg container "$container" '
    (.spec.containers[] | select(.name == $container)) as $runtime
    | $runtime.securityContext.allowPrivilegeEscalation == false
      and $runtime.securityContext.privileged == false
      and $runtime.securityContext.readOnlyRootFilesystem == true
      and $runtime.securityContext.runAsNonRoot == true
      and $runtime.securityContext.runAsUser == 1000
      and $runtime.securityContext.runAsGroup == 1000
      and $runtime.securityContext.seccompProfile.type == "RuntimeDefault"
      and ($runtime.securityContext.capabilities.drop | index("ALL") != null)
  ' "$output_file" >/dev/null || die "$tenant_alias security context check failed"

  jq -e --arg container "$container" '
    (.spec.containers[] | select(.name == $container)) as $runtime
    | (($runtime.env // []) | map(.name) | [
        .[] | select(
          . == "AWS_ACCESS_KEY_ID"
          or . == "AWS_SECRET_ACCESS_KEY"
          or . == "AWS_SESSION_TOKEN"
          or . == "AWS_WEB_IDENTITY_TOKEN_FILE"
          or . == "AWS_ROLE_ARN"
          or . == "AWS_CONTAINER_CREDENTIALS_FULL_URI"
          or . == "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"
        )
      ] | length == 0)
      and (($runtime.envFrom // []) | length == 0)
      and ((.metadata.annotations // {})["eks.amazonaws.com/role-arn"] == null)
      and ([
        .spec.volumes[]?.projected.sources[]?.serviceAccountToken?
        | select(.audience == "sts.amazonaws.com")
      ] | length == 0)
  ' "$output_file" >/dev/null || die "$tenant_alias pod exposes an AWS credential path"
}

CURRENT_CHECK="tenant-runtime-contract"
verify_runtime_pod "tenant-a" "$TENANT_A_NAMESPACE" "$TENANT_A_POD" "$TENANT_A_CONTAINER" \
  "$TENANT_A_OCE_NAMESPACE" "$TENANT_A_AGENT_ID" "$WORK_DIR/tenant-a-pod.json"
verify_runtime_pod "tenant-b" "$TENANT_B_NAMESPACE" "$TENANT_B_POD" "$TENANT_B_CONTAINER" \
  "$TENANT_B_OCE_NAMESPACE" "$TENANT_B_AGENT_ID" "$WORK_DIR/tenant-b-pod.json"
TENANT_A_OCE_REVISION="$(jq -er '.metadata.labels["openclaw.dev/revision"]' \
  "$WORK_DIR/tenant-a-pod.json")"
TENANT_B_OCE_REVISION="$(jq -er '.metadata.labels["openclaw.dev/revision"]' \
  "$WORK_DIR/tenant-b-pod.json")"
TENANT_A_POD_UID="$(jq -er '.metadata.uid' "$WORK_DIR/tenant-a-pod.json")"
TENANT_B_POD_UID="$(jq -er '.metadata.uid' "$WORK_DIR/tenant-b-pod.json")"
for pod_uid in "$TENANT_A_POD_UID" "$TENANT_B_POD_UID"; do
  [[ "$pod_uid" =~ ^[A-Za-z0-9._:-]+$ ]] || die "runtime workload UID is invalid"
done
TENANT_A_IMAGE_DIGEST="$(pod_container_digest "$WORK_DIR/tenant-a-pod.json" \
  "$TENANT_A_CONTAINER")"
TENANT_B_IMAGE_DIGEST="$(pod_container_digest "$WORK_DIR/tenant-b-pod.json" \
  "$TENANT_B_CONTAINER")"
{
  printf 'EVIDENCE\toce-revision-tenant-a\t%s\n' "$TENANT_A_OCE_REVISION"
  printf 'EVIDENCE\toce-revision-tenant-b\t%s\n' "$TENANT_B_OCE_REVISION"
  printf 'EVIDENCE\tworkload-image-tenant-a\tuid=%s container=%s digest=%s\n' \
    "$TENANT_A_POD_UID" "$TENANT_A_CONTAINER" "$TENANT_A_IMAGE_DIGEST"
  printf 'EVIDENCE\tworkload-image-tenant-b\tuid=%s container=%s digest=%s\n' \
    "$TENANT_B_POD_UID" "$TENANT_B_CONTAINER" "$TENANT_B_IMAGE_DIGEST"
} >>"$EVIDENCE_FILE"
record_pass "runtime-isolation" "both pods use isolated-sandbox and the pinned digest"
record_pass "security-context" "both runtime containers meet the restricted security contract"

runtime_pvc_name() {
  local pod_file="$1"
  local container="$2"
  jq -er --arg container "$container" --arg mount_path "$PERSISTENT_HOME" '
    (.spec.containers[] | select(.name == $container)) as $runtime
    | [
        ($runtime.volumeMounts // [])[]
        | select(.mountPath == $mount_path)
        | .name
      ] as $mounts
    | (if ($mounts | length) != 1
       then error("persistent home must have exactly one mount")
       else $mounts[0]
       end) as $volume_name
    | [
        .spec.volumes[]
        | select(.name == $volume_name)
        | .persistentVolumeClaim.claimName
      ] as $claims
    | (if ($claims | length) != 1
          or ($claims[0] | type) != "string"
          or ($claims[0] | length) == 0
       then error("persistent home must use exactly one PVC")
       else $claims[0]
       end)
  ' "$pod_file" || die "runtime persistent home is not backed by exactly one PVC"
}

inspect_runtime_storage() {
  local tenant_alias="$1"
  local namespace="$2"
  local pod_file="$3"
  local container="$4"
  local output_prefix="$5"
  local pvc_name pv_name

  pvc_name="$(runtime_pvc_name "$pod_file" "$container")"
  [[ ${#pvc_name} -le 253 &&
    "$pvc_name" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] ||
    die "$tenant_alias PVC name is not a Kubernetes DNS subdomain"
  kube -n "$namespace" get persistentvolumeclaim "$pvc_name" -o json \
    >"${output_prefix}-pvc.json"
  jq -e --arg namespace "$namespace" --arg name "$pvc_name" '
    .metadata.namespace == $namespace
    and .metadata.name == $name
    and (.metadata.uid | type == "string" and length > 0)
    and (.spec.storageClassName | type == "string" and length > 0)
    and (.spec.volumeName | type == "string" and length > 0)
    and .status.phase == "Bound"
  ' "${output_prefix}-pvc.json" >/dev/null ||
    die "$tenant_alias persistent home PVC is not bound as expected"
  pv_name="$(jq -er '.spec.volumeName' "${output_prefix}-pvc.json")"
  kube get persistentvolume "$pv_name" -o json >"${output_prefix}-pv.json"
  jq -e \
    --arg namespace "$namespace" \
    --arg pv_name "$pv_name" \
    --arg pvc_name "$pvc_name" \
    --arg pvc_uid "$(jq -er '.metadata.uid' "${output_prefix}-pvc.json")" \
    --arg storage_class "$(jq -er '.spec.storageClassName' "${output_prefix}-pvc.json")" '
    .metadata.name == $pv_name
    and (.metadata.uid | type == "string" and length > 0)
    and .spec.claimRef.namespace == $namespace
    and .spec.claimRef.name == $pvc_name
    and .spec.claimRef.uid == $pvc_uid
    and .spec.storageClassName == $storage_class
    and (.spec.csi.driver | type == "string" and length > 0)
    and (.spec.csi.volumeHandle | type == "string" and length > 0)
  ' "${output_prefix}-pv.json" >/dev/null ||
    die "$tenant_alias PV does not bind exactly to its PVC and CSI volume"
  printf '%s' "$pvc_name"
}

CURRENT_CHECK="tenant-storage-isolation"
TENANT_A_PVC="$(inspect_runtime_storage \
  "tenant-a" "$TENANT_A_NAMESPACE" "$WORK_DIR/tenant-a-pod.json" "$TENANT_A_CONTAINER" \
  "$WORK_DIR/tenant-a")"
TENANT_B_PVC="$(inspect_runtime_storage \
  "tenant-b" "$TENANT_B_NAMESPACE" "$WORK_DIR/tenant-b-pod.json" "$TENANT_B_CONTAINER" \
  "$WORK_DIR/tenant-b")"
TENANT_A_PV="$(jq -er '.spec.volumeName' "$WORK_DIR/tenant-a-pvc.json")"
TENANT_B_PV="$(jq -er '.spec.volumeName' "$WORK_DIR/tenant-b-pvc.json")"
TENANT_A_STORAGE_CLASS="$(jq -er '.spec.storageClassName' "$WORK_DIR/tenant-a-pvc.json")"
TENANT_B_STORAGE_CLASS="$(jq -er '.spec.storageClassName' "$WORK_DIR/tenant-b-pvc.json")"
TENANT_A_VOLUME_HANDLE="$(jq -er '.spec.csi.volumeHandle' "$WORK_DIR/tenant-a-pv.json")"
TENANT_B_VOLUME_HANDLE="$(jq -er '.spec.csi.volumeHandle' "$WORK_DIR/tenant-b-pv.json")"
[[ "$TENANT_A_PVC" != "$TENANT_B_PVC" ]] ||
  die "tenant PVC names must differ for the cross-namespace negative test"
[[ "$TENANT_A_PV" != "$TENANT_B_PV" ]] || die "tenant PVCs unexpectedly share one PV"
[[ "$(jq -er '.metadata.uid' "$WORK_DIR/tenant-a-pvc.json")" != \
  "$(jq -er '.metadata.uid' "$WORK_DIR/tenant-b-pvc.json")" ]] ||
  die "tenant PVCs unexpectedly share one UID"
[[ "$(jq -er '.metadata.uid' "$WORK_DIR/tenant-a-pv.json")" != \
  "$(jq -er '.metadata.uid' "$WORK_DIR/tenant-b-pv.json")" ]] ||
  die "tenant PVs unexpectedly share one UID"
[[ "$TENANT_A_VOLUME_HANDLE" != "$TENANT_B_VOLUME_HANDLE" ]] ||
  die "tenant PVs unexpectedly share one CSI volume handle"
for storage_class in "$TENANT_A_STORAGE_CLASS" "$TENANT_B_STORAGE_CLASS"; do
  [[ ${#storage_class} -le 253 &&
    "$storage_class" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] ||
    die "storage class name is invalid"
done
for storage_uid in \
  "$(jq -er '.metadata.uid' "$WORK_DIR/tenant-a-pvc.json")" \
  "$(jq -er '.metadata.uid' "$WORK_DIR/tenant-b-pvc.json")" \
  "$(jq -er '.metadata.uid' "$WORK_DIR/tenant-a-pv.json")" \
  "$(jq -er '.metadata.uid' "$WORK_DIR/tenant-b-pv.json")"; do
  [[ "$storage_uid" =~ ^[A-Za-z0-9._:-]+$ ]] || die "storage workload UID is invalid"
done
{
  printf 'EVIDENCE\tstorage-class-tenant-a\t%s\n' "$TENANT_A_STORAGE_CLASS"
  printf 'EVIDENCE\tstorage-class-tenant-b\t%s\n' "$TENANT_B_STORAGE_CLASS"
  printf 'EVIDENCE\tpvc-uid-tenant-a\t%s\n' \
    "$(jq -er '.metadata.uid' "$WORK_DIR/tenant-a-pvc.json")"
  printf 'EVIDENCE\tpvc-uid-tenant-b\t%s\n' \
    "$(jq -er '.metadata.uid' "$WORK_DIR/tenant-b-pvc.json")"
  printf 'EVIDENCE\tpv-uid-tenant-a\t%s\n' \
    "$(jq -er '.metadata.uid' "$WORK_DIR/tenant-a-pv.json")"
  printf 'EVIDENCE\tpv-uid-tenant-b\t%s\n' \
    "$(jq -er '.metadata.uid' "$WORK_DIR/tenant-b-pv.json")"
  printf 'EVIDENCE\tvolume-handle-sha256-tenant-a\t%s\n' \
    "$(sha256_text "$TENANT_A_VOLUME_HANDLE")"
  printf 'EVIDENCE\tvolume-handle-sha256-tenant-b\t%s\n' \
    "$(sha256_text "$TENANT_B_VOLUME_HANDLE")"
} >>"$EVIDENCE_FILE"
unset TENANT_A_STORAGE_CLASS TENANT_B_STORAGE_CLASS TENANT_A_VOLUME_HANDLE TENANT_B_VOLUME_HANDLE

set +e
CROSS_TENANT_PVC_LOOKUP="$(
  kube -n "$TENANT_A_NAMESPACE" get persistentvolumeclaim "$TENANT_B_PVC" -o name 2>&1
)"
CROSS_TENANT_PVC_LOOKUP_STATUS=$?
set -e
[[ $CROSS_TENANT_PVC_LOOKUP_STATUS -ne 0 &&
  "$CROSS_TENANT_PVC_LOOKUP" =~ (NotFound|not[[:space:]]found) ]] ||
  die "tenant B PVC name unexpectedly resolves in tenant A or lookup did not fail as NotFound"
CROSS_TENANT_PVC_POD="oce-live-cross-pvc-$$"
kube -n "$TENANT_A_NAMESPACE" create -f - -o json \
  >"$WORK_DIR/cross-tenant-pvc-pod.json" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $CROSS_TENANT_PVC_POD
  labels:
    app.kubernetes.io/managed-by: openclaw-enterprise-blueprint
    openclaw.dev/validation: cross-tenant-pvc
spec:
  automountServiceAccountToken: false
  enableServiceLinks: false
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: cross-tenant-pvc
      image: $RUNTIME_IMAGE
      command: [sh, -c, "sleep 3600"]
      volumeMounts:
        - name: cross-tenant-pvc
          mountPath: /cross-tenant
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
  volumes:
    - name: cross-tenant-pvc
      persistentVolumeClaim:
        claimName: $TENANT_B_PVC
EOF
CROSS_TENANT_PVC_POD_UID_CANDIDATE="$(jq -er '.metadata.uid' \
  "$WORK_DIR/cross-tenant-pvc-pod.json")" ||
  die "cross-tenant PVC probe has no workload UID"
CROSS_TENANT_PVC_POD_UID="$CROSS_TENANT_PVC_POD_UID_CANDIDATE"
unset CROSS_TENANT_PVC_POD_UID_CANDIDATE
[[ "$CROSS_TENANT_PVC_POD_UID" =~ ^[A-Za-z0-9._:-]+$ ]] ||
  die "cross-tenant PVC probe workload UID is invalid"
jq -e '
  select(.status.phase == "Pending")
  | select([.status.containerStatuses[]? | select(.state.running != null)] | length == 0)
' "$WORK_DIR/cross-tenant-pvc-pod.json" >/dev/null ||
  die "cross-tenant PVC probe was not pending before mount"
PVC_DENIAL_OBSERVED="false"
for ((attempt = 0; attempt < 15; attempt += 1)); do
  kube -n "$TENANT_A_NAMESPACE" get events \
    --field-selector "involvedObject.kind=Pod,involvedObject.uid=${CROSS_TENANT_PVC_POD_UID}" \
    -o json >"$WORK_DIR/cross-tenant-pvc-events.json"
  if jq -e --arg pvc "$TENANT_B_PVC" '
      any(.items[];
        (.reason == "FailedScheduling" or .reason == "FailedMount")
        and (.message | contains($pvc))
        and (.message | test("not found"; "i"))
      )
    ' "$WORK_DIR/cross-tenant-pvc-events.json" >/dev/null; then
    PVC_DENIAL_OBSERVED="true"
    break
  fi
  sleep 2
done
[[ "$PVC_DENIAL_OBSERVED" == "true" ]] ||
  die "cross-tenant PVC mount did not produce the expected NotFound scheduling or mount event"
printf 'EVIDENCE\tworkload-uid-cross-tenant-pvc-negative\t%s\n' \
  "$CROSS_TENANT_PVC_POD_UID" >>"$EVIDENCE_FILE"
record_pass "tenant-storage-isolation" \
  "PVC/PV identities and hashed CSI handles differ between tenants"
record_pass "cross-tenant-pvc-mount-denied" \
  "a live tenant A pod could not resolve or mount tenant B's PVC"

verify_service_account() {
  local tenant_alias="$1"
  local namespace="$2"
  local pod_file="$3"
  local sa_file="$4"
  local associations_file="$5"
  local service_account

  service_account="$(jq -r '.spec.serviceAccountName' "$pod_file")"
  [[ -n "$service_account" && "$service_account" != "null" ]] ||
    die "$tenant_alias pod has no explicit service account"
  kube -n "$namespace" get serviceaccount "$service_account" -o json >"$sa_file"
  jq -e '
    .automountServiceAccountToken == false
    and ((.metadata.annotations // {})["eks.amazonaws.com/role-arn"] == null)
  ' "$sa_file" >/dev/null || die "$tenant_alias service account exposes AWS credentials"
  aws eks list-pod-identity-associations \
    --cluster-name "$EKS_CLUSTER" \
    --region "$AWS_REGION" \
    --namespace "$namespace" \
    --service-account "$service_account" \
    --output json >"$associations_file"
  jq -e '(.associations // []) | length == 0' "$associations_file" >/dev/null ||
    die "$tenant_alias has an EKS Pod Identity association"
}

CURRENT_CHECK="tenant-aws-credentials"
verify_service_account "tenant-a" "$TENANT_A_NAMESPACE" "$WORK_DIR/tenant-a-pod.json" \
  "$WORK_DIR/tenant-a-sa.json" "$WORK_DIR/tenant-a-associations.json"
verify_service_account "tenant-b" "$TENANT_B_NAMESPACE" "$WORK_DIR/tenant-b-pod.json" \
  "$WORK_DIR/tenant-b-sa.json" "$WORK_DIR/tenant-b-associations.json"
record_pass "aws-credential-absence" "pod, service-account, token, and Pod Identity checks passed"

guest_evidence() {
  local namespace="$1"
  local pod="$2"
  local container="$3"
  local output_file="$4"
  # shellcheck disable=SC2016 # This program expands inside the guest, not locally.
  kube -n "$namespace" exec "$pod" -c "$container" -- sh -eu -c '
    printf "LIVE_GUEST_EVIDENCE\n"
    cat /proc/sys/kernel/random/boot_id
    uname -r
    uname -m
    awk "\$2 == \"/\" { print \$1 \" \" \$3; exit }" /proc/mounts
    awk "NR > 2 && \$4 != \"\" { print \$1 \":\" \$2 \":\" \$3 \":\" \$4 }" /proc/partitions
  ' >"$output_file"
  [[ "$(sed -n '1p' "$output_file")" == "LIVE_GUEST_EVIDENCE" ]] ||
    die "guest evidence marker is missing"
  [[ "$(sed -n '2p' "$output_file")" =~ ^[0-9a-f-]{36}$ ]] ||
    die "guest boot ID is invalid"
  [[ -n "$(sed -n '3p' "$output_file")" && -n "$(sed -n '4p' "$output_file")" ]] ||
    die "guest kernel evidence is incomplete"
  [[ "$(sed -n '3p' "$output_file")" =~ ^[A-Za-z0-9._+-]+$ ]] ||
    die "guest kernel release contains unsafe evidence characters"
  [[ "$(sed -n '4p' "$output_file")" =~ ^[A-Za-z0-9._+-]+$ ]] ||
    die "guest architecture contains unsafe evidence characters"
  [[ "$(sed -n '5p' "$output_file")" =~ ^[A-Za-z0-9._/+:-]+\ [A-Za-z0-9._+-]+$ ]] ||
    die "guest root disk evidence is incomplete"
  [[ -n "$(sed -n '6,$p' "$output_file")" ]] || die "guest partition evidence is incomplete"
}

CURRENT_CHECK="guest-vm-evidence"
guest_evidence "$TENANT_A_NAMESPACE" "$TENANT_A_POD" "$TENANT_A_CONTAINER" \
  "$WORK_DIR/tenant-a-guest.txt"
guest_evidence "$TENANT_B_NAMESPACE" "$TENANT_B_POD" "$TENANT_B_CONTAINER" \
  "$WORK_DIR/tenant-b-guest.txt"
[[ "$(sed -n '2p' "$WORK_DIR/tenant-a-guest.txt")" != \
  "$(sed -n '2p' "$WORK_DIR/tenant-b-guest.txt")" ]] ||
  die "tenant pods reported the same guest boot ID"
{
  printf 'EVIDENCE\tguest-a-kernel\t%s %s\n' \
    "$(sed -n '3p' "$WORK_DIR/tenant-a-guest.txt")" \
    "$(sed -n '4p' "$WORK_DIR/tenant-a-guest.txt")"
  printf 'EVIDENCE\tguest-a-root\t%s\n' "$(sed -n '5p' "$WORK_DIR/tenant-a-guest.txt")"
  printf 'EVIDENCE\tguest-b-kernel\t%s %s\n' \
    "$(sed -n '3p' "$WORK_DIR/tenant-b-guest.txt")" \
    "$(sed -n '4p' "$WORK_DIR/tenant-b-guest.txt")"
  printf 'EVIDENCE\tguest-b-root\t%s\n' "$(sed -n '5p' "$WORK_DIR/tenant-b-guest.txt")"
} >>"$EVIDENCE_FILE"
record_pass "guest-vm-boundary" "kernel and disk evidence captured; boot IDs are distinct"

CURRENT_CHECK="auto-mode-network-policy-configuration"
kube -n kube-system get configmap amazon-vpc-cni -o json >"$WORK_DIR/vpc-cni.json"
jq -e '
  ((.data["enable-network-policy-controller"] // "") | ascii_downcase) == "true"
' "$WORK_DIR/vpc-cni.json" >/dev/null || die "VPC CNI network policy is not enabled"
kube get nodeclass default -o json >"$WORK_DIR/default-nodeclass.json"
jq -e '
  .spec.networkPolicy == "DefaultAllow" or .spec.networkPolicy == "DefaultDeny"
' "$WORK_DIR/default-nodeclass.json" >/dev/null ||
  die "default EKS Auto Mode NodeClass has no valid networkPolicy setting"
record_pass "auto-mode-network-policy-configuration" \
  "controller configuration and NodeClass policy mode passed"

NETWORK_VALIDATION_NAMESPACE="oce-live-network-$$"
NETWORK_POLICY_NAME="oce-live-allow-canary-$$"
if kube get namespace "$NETWORK_VALIDATION_NAMESPACE" >/dev/null 2>&1; then
  die "temporary network validation namespace already exists"
fi
for tenant_namespace in "$TENANT_A_NAMESPACE" "$TENANT_B_NAMESPACE"; do
  if kube -n "$tenant_namespace" get networkpolicy "$NETWORK_POLICY_NAME" >/dev/null 2>&1; then
    die "temporary network validation policy already exists"
  fi
done
kube create namespace "$NETWORK_VALIDATION_NAMESPACE" >/dev/null
NETWORK_VALIDATION_CREATED="true"
kube label namespace "$NETWORK_VALIDATION_NAMESPACE" \
  app.kubernetes.io/managed-by=openclaw-enterprise-blueprint \
  openclaw.dev/validation=network-policy --overwrite >/dev/null

kube -n "$NETWORK_VALIDATION_NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: canary
  labels:
    app.kubernetes.io/managed-by: openclaw-enterprise-blueprint
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: oce-network-canary
  template:
    metadata:
      labels:
        app.kubernetes.io/name: oce-network-canary
        app.kubernetes.io/managed-by: openclaw-enterprise-blueprint
    spec:
      automountServiceAccountToken: false
      enableServiceLinks: false
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: canary
          image: $RUNTIME_IMAGE
          command: [node]
          args:
            - -e
            - |
              require("node:http")
                .createServer((request, response) => {
                  response.end("OCE_NETPOL_CANARY");
                })
                .listen(8080, "0.0.0.0");
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /
              port: http
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
---
apiVersion: v1
kind: Service
metadata:
  name: canary
  labels:
    app.kubernetes.io/managed-by: openclaw-enterprise-blueprint
spec:
  selector:
    app.kubernetes.io/name: oce-network-canary
  ports:
    - name: http
      port: 8080
      targetPort: http
EOF
kube -n "$NETWORK_VALIDATION_NAMESPACE" rollout status deployment/canary \
  --timeout=180s >/dev/null
NETWORK_CANARY_POD="$(kube -n "$NETWORK_VALIDATION_NAMESPACE" get pods \
  -l app.kubernetes.io/name=oce-network-canary \
  -o 'jsonpath={.items[0].metadata.name}')"
[[ -n "$NETWORK_CANARY_POD" ]] || die "temporary network canary pod was not created"
NETWORK_CANARY_HOST="canary.${NETWORK_VALIDATION_NAMESPACE}.svc.cluster.local"

network_probe_allowed() {
  local namespace="$1"
  local pod="$2"
  local container="$3"
  kube -n "$namespace" exec "$pod" -c "$container" -- node -e '
    const http = require("node:http");
    const host = process.argv[1];
    const request = http.get({host, port: 8080, path: "/", timeout: 5000}, response => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", chunk => { body += chunk; });
      response.on("end", () => {
        if (response.statusCode !== 200 || body !== "OCE_NETPOL_CANARY") process.exit(42);
        process.stdout.write("NETPOL_ALLOWED");
      });
    });
    request.on("timeout", () => request.destroy(new Error("timeout")));
    request.on("error", () => process.exit(43));
  ' "$NETWORK_CANARY_HOST"
}

network_probe_denied() {
  local namespace="$1"
  local pod="$2"
  local container="$3"
  local attempt result status
  for attempt in 1 2 3; do
    set +e
    result="$(kube -n "$namespace" exec "$pod" -c "$container" -- node -e '
      const net = require("node:net");
      const host = process.argv[1];
      const socket = net.createConnection({host, port: 8080});
      let finished = false;
      const done = blocked => {
        if (finished) return;
        finished = true;
        socket.destroy();
        if (blocked) process.stdout.write("NETPOL_BLOCKED");
        process.exit(blocked ? 0 : 42);
      };
      socket.setTimeout(3000, () => done(true));
      socket.once("error", () => done(true));
      socket.once("connect", () => done(false));
    ' "$NETWORK_CANARY_HOST" 2>/dev/null)"
    status=$?
    set -e
    [[ $status -eq 0 && "$result" == "NETPOL_BLOCKED" ]] ||
      die "temporary canary was reachable while the allow policy was absent"
  done
}

apply_canary_allow_policy() {
  local namespace="$1"
  kube -n "$namespace" create -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: $NETWORK_POLICY_NAME
  labels:
    app.kubernetes.io/managed-by: openclaw-enterprise-blueprint
spec:
  podSelector:
    matchLabels:
      openclaw.dev/workload-role: gateway
      openclaw.dev/network-profile: nitro-central-gateway-v1
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: $NETWORK_VALIDATION_NAMESPACE
          podSelector:
            matchLabels:
              app.kubernetes.io/name: oce-network-canary
      ports:
        - protocol: TCP
          port: 8080
EOF
}

CURRENT_CHECK="auto-mode-network-policy-enforcement"
[[ "$(network_probe_allowed "$NETWORK_VALIDATION_NAMESPACE" "$NETWORK_CANARY_POD" canary)" == \
  "NETPOL_ALLOWED" ]] || die "temporary network canary control request failed"
for tenant in a b; do
  if [[ "$tenant" == "a" ]]; then
    tenant_namespace="$TENANT_A_NAMESPACE"
    tenant_pod="$TENANT_A_POD"
    tenant_container="$TENANT_A_CONTAINER"
  else
    tenant_namespace="$TENANT_B_NAMESPACE"
    tenant_pod="$TENANT_B_POD"
    tenant_container="$TENANT_B_CONTAINER"
  fi
  network_probe_denied "$tenant_namespace" "$tenant_pod" "$tenant_container"
  apply_canary_allow_policy "$tenant_namespace"
  [[ "$(network_probe_allowed "$tenant_namespace" "$tenant_pod" "$tenant_container")" == \
    "NETPOL_ALLOWED" ]] || die "temporary canary remained blocked after applying the allow policy"
  kube -n "$tenant_namespace" delete networkpolicy "$NETWORK_POLICY_NAME" \
    --wait=true >/dev/null
  network_probe_denied "$tenant_namespace" "$tenant_pod" "$tenant_container"
done
record_pass "auto-mode-network-policy-enforcement" \
  "both tenant paths were blocked, allowed, and blocked again against one live endpoint"

deny_egress() {
  local tenant_alias="$1"
  local namespace="$2"
  local pod="$3"
  local container="$4"
  local host="$5"
  local port="$6"
  local destination_alias="$7"
  local result
  local status
  set +e
  result="$(kube -n "$namespace" exec "$pod" -c "$container" -- node -e '
    const net = require("node:net");
    const [host, port] = process.argv.slice(1);
    const socket = net.createConnection({host, port: Number(port)});
    let finished = false;
    const done = (blocked) => {
      if (finished) return;
      finished = true;
      socket.destroy();
      if (blocked) process.stdout.write("EGRESS_BLOCKED");
      process.exit(blocked ? 0 : 42);
    };
    socket.setTimeout(3000, () => done(true));
    socket.once("error", () => done(true));
    socket.once("connect", () => done(false));
  ' "$host" "$port" 2>/dev/null)"
  status=$?
  set -e
  if [[ $status -eq 0 && "$result" == "EGRESS_BLOCKED" ]]; then
    record_pass "egress-${tenant_alias}-${destination_alias}" "connection was denied"
  else
    die "$tenant_alias reached a prohibited egress destination"
  fi
}

CURRENT_CHECK="tenant-egress-deny"
for tenant in a b; do
  if [[ "$tenant" == "a" ]]; then
    tenant_namespace="$TENANT_A_NAMESPACE"
    tenant_pod="$TENANT_A_POD"
    tenant_container="$TENANT_A_CONTAINER"
  else
    tenant_namespace="$TENANT_B_NAMESPACE"
    tenant_pod="$TENANT_B_POD"
    tenant_container="$TENANT_B_CONTAINER"
  fi
  deny_egress "tenant-$tenant" "$tenant_namespace" "$tenant_pod" "$tenant_container" \
    "1.1.1.1" "443" "public-ip"
  deny_egress "tenant-$tenant" "$tenant_namespace" "$tenant_pod" "$tenant_container" \
    "169.254.170.23" "80" "identity-endpoint"
  deny_egress "tenant-$tenant" "$tenant_namespace" "$tenant_pod" "$tenant_container" \
    "169.254.169.254" "80" "imds"
done

CURRENT_CHECK="agentgateway-health"
kube -n "$AGW_NAMESPACE" get deployment "$AGW_DEPLOYMENT" -o json \
  >"$WORK_DIR/agentgateway-deployment.json"
jq -e '
  .status.observedGeneration >= .metadata.generation
  and .status.replicas > 0
  and .status.updatedReplicas == .status.replicas
  and .status.readyReplicas == .status.replicas
  and .status.availableReplicas == .status.replicas
  and (.spec.template.spec.containers | any(
    .name == "agentgateway"
    and .readinessProbe.httpGet.path == "/healthz/ready"
    and .readinessProbe.httpGet.port == "health"
  ))
' "$WORK_DIR/agentgateway-deployment.json" >/dev/null ||
  die "central AgentGateway deployment is not healthy"
kube -n "$AGW_NAMESPACE" get pods -l app=agentgateway -o json >"$WORK_DIR/agentgateway-pods.json"
jq -e '
  .items | length > 0
  and all(.[];
    .status.phase == "Running"
    and ((.status.containerStatuses // []) | any(
      .name == "agentgateway" and .ready == true and .state.running != null
    ))
  )
' "$WORK_DIR/agentgateway-pods.json" >/dev/null ||
  die "central AgentGateway pods are not healthy"

capture_pod_list_evidence() {
  local evidence_alias="$1"
  local pod_list_file="$2"
  local index uid container digest
  jq -e '
    (.items | length) > 0
    and all(.items[];
      (.metadata.uid | type == "string" and length > 0)
      and (.spec.containers | length > 0)
      and (. as $pod | all($pod.spec.containers[];
        .name as $container_name
        | ($pod.status.containerStatuses // []) | any(
          .name == $container_name
          and (.imageID | test("sha256:[0-9a-f]{64}$"))
        )
      ))
    )
  ' "$pod_list_file" >/dev/null ||
    die "$evidence_alias workloads lack complete UID or immutable image evidence"
  index=0
  while IFS=$'\t' read -r uid container digest; do
    index=$((index + 1))
    [[ "$uid" =~ ^[A-Za-z0-9._:-]+$ ]] || die "$evidence_alias workload UID is invalid"
    [[ "$container" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
      die "$evidence_alias container name is invalid"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
      die "$evidence_alias image digest is invalid"
    printf 'EVIDENCE\tworkload-image-%s-%d\tuid=%s container=%s digest=%s\n' \
      "$evidence_alias" "$index" "$uid" "$container" "$digest" >>"$EVIDENCE_FILE"
  done < <(jq -er '
    [
      .items[] as $pod
      | $pod.spec.containers[] as $container
      | first(
          $pod.status.containerStatuses[]
          | select(.name == $container.name)
        ) as $status
      | {
          uid: $pod.metadata.uid,
          container: $container.name,
          digest: (
            $status.imageID
            | capture("(?<digest>sha256:[0-9a-f]{64})$").digest
          )
        }
    ]
    | sort_by(.uid, .container)
    | .[]
    | [.uid, .container, .digest]
    | @tsv
  ' "$pod_list_file")
}

capture_pod_list_evidence "agentgateway" "$WORK_DIR/agentgateway-pods.json"
kube -n "$OCE_SYSTEM_NAMESPACE" get pods -o json >"$WORK_DIR/oce-system-pods.json"
capture_pod_list_evidence "oce-system" "$WORK_DIR/oce-system-pods.json"
record_pass "agentgateway-health" "deployment readiness probe and pod readiness passed"
record_pass "control-plane-evidence" "AgentGateway and OCE workload UIDs and image digests captured"

call_model() {
  local namespace="$1"
  local pod="$2"
  local container="$3"
  local output_file="$4"
  # shellcheck disable=SC2016 # This JavaScript reads the guest environment.
  kube -n "$namespace" exec "$pod" -c "$container" -- node -e '
    const fs = require("node:fs");
    const https = require("node:https");
    const caPath = process.env.NODE_EXTRA_CA_CERTS;
    if (caPath !== "/etc/agentgateway-ca/ca.crt") process.exit(49);
    let ca;
    try { ca = fs.readFileSync(caPath); } catch { process.exit(49); }
    const payload = JSON.stringify({
      model: "nova-lite",
      input: "Reply with exactly OK.",
      max_output_tokens: 16
    });
    const request = https.request({
      hostname: "agentgateway.openclaw-enterprise-agw.svc.cluster.local",
      port: 443,
      path: "/v1/responses",
      method: "POST",
      ca,
      rejectUnauthorized: true,
      headers: {
        authorization: `Bearer ${process.env.OPENAI_API_KEY || ""}`,
        "content-type": "application/json",
        "content-length": Buffer.byteLength(payload)
      }
    }, response => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", chunk => { body += chunk; });
      response.on("end", () => {
        let parsed;
        try { parsed = JSON.parse(body); } catch { process.exit(50); }
        const text = (parsed.output || [])
          .flatMap(item => item.content || [])
          .filter(item => item.type === "output_text")
          .map(item => item.text || "")
          .join("")
          .trim();
        if (response.statusCode !== 200 || !parsed.id || text !== "OK") process.exit(51);
        process.stdout.write(JSON.stringify({status: 200, model: "nova-lite", text: "OK"}));
      });
    });
    request.setTimeout(30000, () => request.destroy(new Error("timeout")));
    request.on("error", () => process.exit(52));
    request.end(payload);
  ' >"$output_file"
  jq -e --arg model "$MODEL_ALIAS" --arg text "$EXPECTED_MODEL_TEXT" '
    .status == 200 and .model == $model and .text == $text
  ' "$output_file" >/dev/null || die "AgentGateway response did not match the exact contract"
}

CURRENT_CHECK="agentgateway-responses-api"
call_model "$TENANT_A_NAMESPACE" "$TENANT_A_POD" "$TENANT_A_CONTAINER" \
  "$WORK_DIR/model-response-a.json"
call_model "$TENANT_B_NAMESPACE" "$TENANT_B_POD" "$TENANT_B_CONTAINER" \
  "$WORK_DIR/model-response-b.json"
record_pass "agentgateway-responses-api" "both tenants received the exact expected response"

CURRENT_CHECK="oce-api-port-forward"
start_oce_api_port_forward

assert_live_oce_source_revision() {
  local request_url="${OCE_API_URL}/console/"
  local deployed_revision
  deployed_revision="$(
    printf '%s\0%s' "$request_url" "$OCE_SOURCE_REVISION" |
      node -e '
        const http = require("node:http");
        let input = "";
        process.stdin.setEncoding("utf8");
        process.stdin.on("data", chunk => {
          input += chunk;
          if (input.length > 8192) process.exit(60);
        });
        process.stdin.on("end", () => {
          const separator = input.indexOf("\0");
          if (separator < 1 || input.indexOf("\0", separator + 1) !== -1) process.exit(61);
          const requestUrl = input.slice(0, separator);
          const expectedRevision = input.slice(separator + 1);
          if (!/^[0-9a-f]{40}$/.test(expectedRevision)) process.exit(61);
          let target;
          try {
            target = new URL(requestUrl);
          } catch {
            process.exit(61);
          }
          if (target.protocol !== "http:" ||
              target.hostname !== "127.0.0.1" ||
              target.port !== String(Number(target.port)) ||
              target.pathname !== "/console/" ||
              target.username || target.password || target.search || target.hash) {
            process.exit(62);
          }
          const request = http.request(target, {
            method: "GET",
            headers: {accept: "text/html"}
          }, response => {
            let body = "";
            response.setEncoding("utf8");
            response.on("data", chunk => {
              body += chunk;
              if (body.length > 1048576) request.destroy(new Error("response too large"));
            });
            response.on("end", () => {
              if (response.statusCode !== 200 ||
                  !String(response.headers["content-type"] || "").startsWith("text/html")) {
                process.exit(63);
              }
              const matches = [...body.matchAll(
                /<meta name="occ-build-revision" content="([0-9a-f]{40})" \/>/g
              )];
              if (matches.length !== 1 || matches[0][1] !== expectedRevision) process.exit(64);
              process.stdout.write(matches[0][1]);
            });
          });
          request.setTimeout(30000, () => request.destroy(new Error("timeout")));
          request.on("error", () => process.exit(65));
          request.end();
        });
      '
  )" || die "deployed OCE source revision did not match the reviewed pin"
  [[ "$deployed_revision" == "$OCE_SOURCE_REVISION" ]] ||
    die "deployed OCE source revision did not match the reviewed pin"
  printf 'EVIDENCE\toce-deployed-source-revision\t%s\n' "$deployed_revision" \
    >>"$EVIDENCE_FILE"
  record_pass "oce-deployed-source-revision" \
    "the live console build marker matched the exact reviewed OCE commit"
}

CURRENT_CHECK="oce-deployed-source-revision"
assert_live_oce_source_revision

oce_get() {
  local credential="$1"
  local oce_namespace="$2"
  local agent_id="$3"
  local output_file="$4"
  local request_url="${OCE_API_URL}/namespaces/${oce_namespace}/agents/${agent_id}"
  local response_file="${output_file}.response"
  printf '%s\0%s' "$request_url" "$credential" |
    node -e '
        const http = require("node:http");
        let input = "";
        process.stdin.setEncoding("utf8");
        process.stdin.on("data", chunk => {
          input += chunk;
          if (input.length > 8192) process.exit(60);
        });
        process.stdin.on("end", () => {
          const separator = input.indexOf("\0");
          if (separator < 1 || input.indexOf("\0", separator + 1) !== -1) process.exit(61);
          const requestUrl = input.slice(0, separator);
          const credential = input.slice(separator + 1);
          if (!credential) process.exit(61);
          let target;
          try {
            target = new URL(requestUrl);
          } catch {
            process.exit(61);
          }
          if (target.protocol !== "http:" ||
              target.hostname !== "127.0.0.1" ||
              target.port !== String(Number(target.port)) ||
              target.username || target.password || target.search || target.hash) {
            process.exit(62);
          }
          const request = http.request(target, {
            method: "GET",
            headers: {
              accept: "application/json",
              "x-api-key": credential
            }
          }, response => {
            let body = "";
            response.setEncoding("utf8");
            response.on("data", chunk => {
              body += chunk;
              if (body.length > 1048576) request.destroy(new Error("response too large"));
            });
            response.on("end", () => {
              let parsed;
              try { parsed = JSON.parse(body); } catch { process.exit(63); }
              process.stdout.write(JSON.stringify({status: response.statusCode, body: parsed}));
            });
          });
          request.setTimeout(30000, () => request.destroy(new Error("timeout")));
          request.on("error", () => process.exit(64));
          request.end();
        });
      ' >"$response_file"
  jq -e '.status | type == "number"' "$response_file" >/dev/null ||
    die "OCE API client returned an invalid response envelope"
  jq '.body' "$response_file" >"$output_file"
  jq -r '.status' "$response_file"
}

assert_same_tenant() {
  local tenant_alias="$1"
  local credential="$2"
  local oce_namespace="$3"
  local agent_id="$4"
  local output_file="$5"
  local status
  status="$(oce_get "$credential" "$oce_namespace" "$agent_id" "$output_file")"
  [[ "$status" == "200" ]] || die "$tenant_alias same-tenant OCE request did not return HTTP 200"
  jq -e --arg namespace "$oce_namespace" --arg agent "$agent_id" '
    .data.id == $agent and .data.namespaceId == $namespace
  ' "$output_file" >/dev/null || die "$tenant_alias same-tenant OCE response identity did not match"
}

assert_cross_tenant_denied() {
  local direction="$1"
  local credential="$2"
  local oce_namespace="$3"
  local agent_id="$4"
  local output_file="$5"
  local status
  status="$(oce_get "$credential" "$oce_namespace" "$agent_id" "$output_file")"
  [[ "$status" == "403" ]] || die "$direction cross-tenant OCE request did not return HTTP 403"
  jq -e --arg code "$OCE_FORBIDDEN_CODE" '.error.code == $code' "$output_file" >/dev/null ||
    die "$direction cross-tenant OCE error code did not match"
}

CURRENT_CHECK="oce-tenant-api-isolation"
assert_same_tenant "tenant-a" "$TENANT_A_CREDENTIAL" "$TENANT_A_OCE_NAMESPACE" \
  "$TENANT_A_AGENT_ID" "$WORK_DIR/oce-a-own.json"
assert_same_tenant "tenant-b" "$TENANT_B_CREDENTIAL" "$TENANT_B_OCE_NAMESPACE" \
  "$TENANT_B_AGENT_ID" "$WORK_DIR/oce-b-own.json"
assert_cross_tenant_denied "tenant-a-to-b" "$TENANT_A_CREDENTIAL" "$TENANT_B_OCE_NAMESPACE" \
  "$TENANT_B_AGENT_ID" "$WORK_DIR/oce-a-to-b.json"
assert_cross_tenant_denied "tenant-b-to-a" "$TENANT_B_CREDENTIAL" "$TENANT_A_OCE_NAMESPACE" \
  "$TENANT_A_AGENT_ID" "$WORK_DIR/oce-b-to-a.json"
stop_oce_api_port_forward || die "OCE API port-forward child could not be terminated and reaped"
[[ "$OCE_PORT_FORWARD_CLEANED" == "true" ]] ||
  die "OCE API port-forward child was not reaped"
record_pass "oce-api-loopback-port-forward" \
  "OCE API used a 127.0.0.1-only port-forward whose child process was terminated and reaped"
record_pass "oce-same-tenant-api" "both tenants received HTTP 200 for their own agent"
record_pass "oce-cross-tenant-api" "both reciprocal requests returned HTTP 403 FORBIDDEN"

expect_server_denial() {
  local check_name="$1"
  local expected_text="$2"
  shift 2
  local output
  local status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || die "$check_name unexpectedly succeeded"
  [[ "$output" == *"$expected_text"* ]] || die "$check_name failed without the expected denial"
  record_pass "$check_name" "server-side admission denied the request"
}

CURRENT_CHECK="reserved-resource-admission"
reserved_configmap="gateway-ffffffffffff-rev-eeeeeeeeeeee"
if kube -n "$TENANT_A_NAMESPACE" get configmap "$reserved_configmap" >/dev/null 2>&1; then
  die "reserved ConfigMap test name already exists"
fi
expect_server_denial "reserved-configmap-spoof" "$CONTROLLER_DENIAL" \
  kube -n "$TENANT_A_NAMESPACE" create configmap "$reserved_configmap" \
  --from-literal=openclaw.json='{}' --dry-run=server -o yaml

jq '
  del(
    .metadata.creationTimestamp,
    .metadata.generateName,
    .metadata.managedFields,
    .metadata.resourceVersion,
    .metadata.uid,
    .status
  )
  | .metadata.name = "oce-live-validation-spoof"
' "$WORK_DIR/tenant-a-pod.json" >"$WORK_DIR/spoof-pod.json"
if kube -n "$TENANT_A_NAMESPACE" get pod oce-live-validation-spoof >/dev/null 2>&1; then
  die "spoof pod test name already exists"
fi
expect_server_denial "managed-pod-spoof" "$CONTROLLER_DENIAL" \
  kube -n "$TENANT_A_NAMESPACE" create --dry-run=server -f "$WORK_DIR/spoof-pod.json"

CURRENT_CHECK="ephemeral-debug-admission"
expect_server_denial "ephemeral-debug" "$EPHEMERAL_DENIAL" \
  kube -n "$TENANT_A_NAMESPACE" debug "$TENANT_A_POD" \
  --container=live-validation-debug \
  --image="$RUNTIME_IMAGE" \
  --target="$TENANT_A_CONTAINER" \
  --attach=false \
  --dry-run=server \
  -- sh -c true

controller_for_pod() {
  local namespace="$1"
  local pod_file="$2"
  local result_file="$3"
  local replica_set
  replica_set="$(jq -r '
    first(.metadata.ownerReferences[]? | select(.controller == true and .kind == "ReplicaSet") | .name) // empty
  ' "$pod_file")"
  [[ -n "$replica_set" ]] || die "runtime pod is not controller-owned by a ReplicaSet"
  kube -n "$namespace" get replicaset "$replica_set" -o json >"$result_file"
  jq -r '
    first(.metadata.ownerReferences[]? | select(.controller == true and .kind == "Deployment") | .name) // empty
  ' "$result_file"
}

CURRENT_CHECK="controller-driven-persistence"
ORIGINAL_POD_UID="$(jq -r '.metadata.uid' "$WORK_DIR/tenant-a-pod.json")"
POD_SELECTOR_VALUE="$(jq -r '.metadata.labels["app.kubernetes.io/name"]' "$WORK_DIR/tenant-a-pod.json")"
ORIGINAL_DEPLOYMENT="$(controller_for_pod "$TENANT_A_NAMESPACE" "$WORK_DIR/tenant-a-pod.json" \
  "$WORK_DIR/original-replicaset.json")"
[[ -n "$ORIGINAL_DEPLOYMENT" ]] || die "runtime pod ReplicaSet is not controller-owned by a Deployment"

kube -n "$TENANT_A_NAMESPACE" exec "$TENANT_A_POD" -c "$TENANT_A_CONTAINER" -- sh -eu -c \
  "printf '%s' 'persistent-ok' > '$PERSISTENT_MARKER'; printf '%s' 'ephemeral-old' > '$EPHEMERAL_MARKER'"
MARKERS_CREATED="true"
delete_pod_with_uid \
  "$TENANT_A_NAMESPACE" \
  "$TENANT_A_POD" \
  "$ORIGINAL_POD_UID" \
  "$WORK_DIR/tenant-a-delete-options.json"

attempts=$((TIMEOUT_SECONDS / 2))
((attempts > 0)) || attempts=1
for ((attempt = 0; attempt < attempts; attempt += 1)); do
  kube -n "$TENANT_A_NAMESPACE" get pods \
    -l "app.kubernetes.io/name=${POD_SELECTOR_VALUE}" -o json >"$WORK_DIR/replacement-candidates.json"
  REPLACEMENT_POD="$(
    jq -r --arg uid "$ORIGINAL_POD_UID" --arg container "$TENANT_A_CONTAINER" '
      first(
        .items[]
        | select(.metadata.uid != $uid and .metadata.deletionTimestamp == null)
        | select(.status.phase == "Running")
        | select(
            (.status.containerStatuses // []) | any(
              .name == $container and .ready == true and .state.running != null
            )
          )
        | .metadata.name
      ) // empty
    ' "$WORK_DIR/replacement-candidates.json"
  )"
  [[ -n "$REPLACEMENT_POD" ]] && break
  sleep 2
done
[[ -n "$REPLACEMENT_POD" ]] || die "controller did not create a ready replacement pod before timeout"
kube -n "$TENANT_A_NAMESPACE" rollout status "deployment/$ORIGINAL_DEPLOYMENT" \
  "--timeout=${TIMEOUT_SECONDS}s" >/dev/null

verify_runtime_pod "tenant-a-replacement" "$TENANT_A_NAMESPACE" "$REPLACEMENT_POD" \
  "$TENANT_A_CONTAINER" "$TENANT_A_OCE_NAMESPACE" "$TENANT_A_AGENT_ID" \
  "$WORK_DIR/replacement-pod.json"
REPLACEMENT_POD_UID="$(jq -er '.metadata.uid' "$WORK_DIR/replacement-pod.json")"
[[ "$REPLACEMENT_POD_UID" =~ ^[A-Za-z0-9._:-]+$ ]] ||
  die "replacement workload UID is invalid"
REPLACEMENT_OCE_REVISION="$(jq -er '.metadata.labels["openclaw.dev/revision"]' \
  "$WORK_DIR/replacement-pod.json")"
REPLACEMENT_IMAGE_DIGEST="$(pod_container_digest "$WORK_DIR/replacement-pod.json" \
  "$TENANT_A_CONTAINER")"
[[ "$REPLACEMENT_POD_UID" != "$ORIGINAL_POD_UID" ]] ||
  die "replacement pod reused the deleted workload UID"
[[ "$REPLACEMENT_OCE_REVISION" == "$TENANT_A_OCE_REVISION" ]] ||
  die "replacement pod did not preserve the exact OCE revision"
[[ "$REPLACEMENT_IMAGE_DIGEST" == "$TENANT_A_IMAGE_DIGEST" ]] ||
  die "replacement pod did not preserve the exact runtime image digest"
REPLACEMENT_DEPLOYMENT="$(controller_for_pod "$TENANT_A_NAMESPACE" "$WORK_DIR/replacement-pod.json" \
  "$WORK_DIR/replacement-replicaset.json")"
[[ "$REPLACEMENT_DEPLOYMENT" == "$ORIGINAL_DEPLOYMENT" ]] ||
  die "replacement pod was not created by the original Deployment"
[[ "$(kube -n "$TENANT_A_NAMESPACE" exec "$REPLACEMENT_POD" -c "$TENANT_A_CONTAINER" -- \
  cat "$PERSISTENT_MARKER")" == "persistent-ok" ]] ||
  die "persistent marker did not survive controller-driven replacement"
if kube -n "$TENANT_A_NAMESPACE" exec "$REPLACEMENT_POD" -c "$TENANT_A_CONTAINER" -- \
  test -e "$EPHEMERAL_MARKER"; then
  die "ephemeral home marker unexpectedly survived replacement"
fi
call_model "$TENANT_A_NAMESPACE" "$REPLACEMENT_POD" "$TENANT_A_CONTAINER" \
  "$WORK_DIR/replacement-model-response.json"
{
  printf 'EVIDENCE\toce-revision-tenant-a-replacement\t%s\n' "$REPLACEMENT_OCE_REVISION"
  printf 'EVIDENCE\tworkload-image-tenant-a-replacement\tuid=%s container=%s digest=%s\n' \
    "$REPLACEMENT_POD_UID" "$TENANT_A_CONTAINER" "$REPLACEMENT_IMAGE_DIGEST"
} >>"$EVIDENCE_FILE"
record_pass "controller-driven-persistence" \
  "persistent state survived replacement; ephemeral state did not; model access still passed"

CURRENT_CHECK="temporary-artifact-cleanup"
kube -n "$TENANT_A_NAMESPACE" exec "$REPLACEMENT_POD" -c "$TENANT_A_CONTAINER" -- \
  rm -f -- "$PERSISTENT_MARKER" "$EPHEMERAL_MARKER"
if ! kube -n "$TENANT_A_NAMESPACE" exec "$REPLACEMENT_POD" -c "$TENANT_A_CONTAINER" -- \
  test ! -e "$PERSISTENT_MARKER" -a ! -e "$EPHEMERAL_MARKER"; then
  die "validation markers could not be removed"
fi
MARKERS_CREATED="false"
cleanup_cross_tenant_pvc_probe
cleanup_network_validation
[[ "$OCE_PORT_FORWARD_CLEANED" == "true" ]] ||
  die "OCE API port-forward cleanup was not completed"
record_pass "temporary-artifact-cleanup" \
  "port-forward, markers, negative PVC pod, network policies, and canary namespace were removed"
printf 'CLEANUP\tPASS\tlocal port-forward was reaped; temporary cluster artifacts were deleted and awaited\n' \
  >>"$EVIDENCE_FILE"

CURRENT_CHECK="evidence-signing"
VALIDATION_ENDED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
EVIDENCE_PREPASS_BACKUP="$WORK_DIR/live-validation-evidence-prepass.txt"
cp -- "$EVIDENCE_FILE" "$EVIDENCE_PREPASS_BACKUP"
FINAL_EVIDENCE_CANDIDATE="$(mktemp "$EVIDENCE_DIR/.live-validation-evidence.XXXXXX")"
FINAL_MANIFEST_CANDIDATE="$(mktemp "$EVIDENCE_DIR/.live-validation-manifest.XXXXXX")"
chmod 600 "$FINAL_EVIDENCE_CANDIDATE" "$FINAL_MANIFEST_CANDIDATE"
cp -- "$EVIDENCE_FILE" "$FINAL_EVIDENCE_CANDIDATE"
if [[ -n "$KMS_SIGNING_KEY_ID" ]]; then
  aws kms get-public-key \
    --region "$AWS_REGION" \
    --key-id "$KMS_SIGNING_KEY_ID" \
    --output json >"$WORK_DIR/kms-public-key.json"
  KMS_SIGNING_ALGORITHM="$(jq -er '
    select(.KeyUsage == "SIGN_VERIFY")
    | if (.SigningAlgorithms | index("RSASSA_PSS_SHA_256")) != null
      then "RSASSA_PSS_SHA_256"
      elif (.SigningAlgorithms | index("ECDSA_SHA_256")) != null
      then "ECDSA_SHA_256"
      else error("no supported SHA-256 signing algorithm")
      end
  ' "$WORK_DIR/kms-public-key.json")" ||
    die "KMS key cannot sign a SHA-256 digest"
  KMS_CANONICAL_KEY_ID="$(jq -er '.KeyId' "$WORK_DIR/kms-public-key.json")"
  KMS_KEY_ID_HASH="$(sha256_text "$KMS_CANONICAL_KEY_ID")"
  {
    printf 'EVIDENCE\tsignature-status\tsigned-with-kms algorithm=%s key-id-sha256=%s\n' \
      "$KMS_SIGNING_ALGORITHM" "$KMS_KEY_ID_HASH"
    printf 'EVIDENCE\tvalidation-end\t%s\n' "$VALIDATION_ENDED_AT"
    printf 'RESULT\tPASS\tall live validation checks passed\n'
  } >>"$FINAL_EVIDENCE_CANDIDATE"
else
  {
    printf 'EVIDENCE\tsignature-status\tunsigned; no KMS key explicitly supplied\n'
    printf 'EVIDENCE\tvalidation-end\t%s\n' "$VALIDATION_ENDED_AT"
    printf 'RESULT\tPASS\tall live validation checks passed\n'
  } >>"$FINAL_EVIDENCE_CANDIDATE"
fi

if [[ -n "$KMS_SIGNING_KEY_ID" ]]; then
  openssl dgst -sha256 -binary "$FINAL_EVIDENCE_CANDIDATE" \
    >"$WORK_DIR/evidence-digest.bin"
  aws kms sign \
    --region "$AWS_REGION" \
    --key-id "$KMS_SIGNING_KEY_ID" \
    --message-type DIGEST \
    --signing-algorithm "$KMS_SIGNING_ALGORITHM" \
    --message "fileb://$WORK_DIR/evidence-digest.bin" \
    --output json >"$WORK_DIR/kms-signature.json"
  jq -e --arg key_id "$KMS_CANONICAL_KEY_ID" '
    .KeyId == $key_id
    and (.Signature | type == "string" and length > 0)
  ' "$WORK_DIR/kms-signature.json" >/dev/null ||
    die "KMS returned an invalid signature envelope"
  jq -er '.Signature' "$WORK_DIR/kms-signature.json" |
    openssl base64 -d -A >"$WORK_DIR/evidence-signature.bin"
  aws kms verify \
    --region "$AWS_REGION" \
    --key-id "$KMS_SIGNING_KEY_ID" \
    --message-type DIGEST \
    --signing-algorithm "$KMS_SIGNING_ALGORITHM" \
    --message "fileb://$WORK_DIR/evidence-digest.bin" \
    --signature "fileb://$WORK_DIR/evidence-signature.bin" \
    --output json >"$WORK_DIR/kms-verification.json"
  jq -e --arg key_id "$KMS_CANONICAL_KEY_ID" '
    .KeyId == $key_id and .SignatureValid == true
  ' "$WORK_DIR/kms-verification.json" >/dev/null ||
    die "KMS did not verify the evidence signature"
  FINAL_SIGNATURE_CANDIDATE="$(
    mktemp "$EVIDENCE_DIR/.live-validation-signature.XXXXXX"
  )"
  jq -er '.Signature' "$WORK_DIR/kms-signature.json" >"$FINAL_SIGNATURE_CANDIDATE"
  chmod 600 "$FINAL_SIGNATURE_CANDIDATE"
fi

write_manifest_to \
  "$FINAL_MANIFEST_CANDIDATE" \
  "$FINAL_EVIDENCE_CANDIDATE" \
  "$FINAL_SIGNATURE_CANDIDATE"
if [[ -n "$FINAL_SIGNATURE_CANDIDATE" ]]; then
  mv -- "$FINAL_SIGNATURE_CANDIDATE" "$SIGNATURE_FILE"
  FINAL_SIGNATURE_CANDIDATE=""
fi
mv -- "$FINAL_EVIDENCE_CANDIDATE" "$EVIDENCE_FILE"
FINAL_EVIDENCE_CANDIDATE=""
mv -- "$FINAL_MANIFEST_CANDIDATE" "$MANIFEST_FILE"
FINAL_MANIFEST_CANDIDATE=""

printf 'Validation passed. Sanitized evidence: %s\n' "$EVIDENCE_FILE"
printf 'SHA-256 manifest: %s\n' "$MANIFEST_FILE"
if [[ -f "$SIGNATURE_FILE" ]]; then
  printf 'KMS signature: %s\n' "$SIGNATURE_FILE"
fi
