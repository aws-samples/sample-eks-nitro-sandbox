#!/usr/bin/env bash
# shellcheck source=../../../../scripts/lib/require-bash.sh
. "$(dirname "$0")/../../../../scripts/lib/require-bash.sh"
set +x
set -Eeuo pipefail

umask 077

AGW_NAMESPACE="openclaw-enterprise-agw"
AGW_DEPLOYMENT="agentgateway"
AGW_MODEL_ID="nova-lite"
BEDROCK_MODEL_ID="amazon.nova-lite-v1:0"
NATIVE_MODEL_ID="openclaw/default"
OCE_FORBIDDEN_CODE="FORBIDDEN"
EXPECTED_OCE_SOURCE_REVISION="86c8c12310f691bb21651118ffffd6bfd460e9ff" # pragma: allowlist secret -- public source revision
CONTROLLER_DENIAL="admission caller is not an allowed controller identity for this resource"
EPHEMERAL_DENIAL="ephemeral containers are not permitted in OpenClaw Enterprise managed namespaces"
PERSISTENT_MARKER="/home/node/.openclaw/.live-validation-marker"
EPHEMERAL_MARKER="/home/node/.live-validation-marker"
PERSISTENT_HOME="/home/node/.openclaw"
RUNTIME_HOME="/home/node"
RUNTIME_CODEX_HOME="$RUNTIME_HOME/.openclaw/agents/main/agent/codex-home"
RUNTIME_CODEX_HOME_SUBPATH="gateway-codex-home"
PERSISTENT_STATE_ROOT="/gateway-state"
RUNTIME_STATE_VOLUME="runtime-state"
PREP_INIT_CONTAINER="prepare-private-state"
OWNER_INIT_CONTAINER="nitro-prepare-runtime-ownership"
LINK_INIT_CONTAINER="nitro-link-gateway-state"
OCE_CONFIGURATION_VOLUME="openclaw-configuration"
OCE_CONFIGURATION_MOUNT="/etc/openclaw"
OCE_SERVICE_PRINCIPAL_VOLUME="openclaw-service-principal"
OCE_SERVICE_PRINCIPAL_MOUNT="/var/run/secrets/openclaw/service-principal"
AGENTGATEWAY_CA_VOLUME="agentgateway-ca"
AGENTGATEWAY_CA_MOUNT="/etc/agentgateway-ca"

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
OCE_API_URL=""
OCE_SYSTEM_NAMESPACE=""
OCE_SOURCE_REVISION=""
IMAGE_SOURCE_REVISION=""
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
EVIDENCE_LOCK_DIR=""
EVIDENCE_OWNED="false"
EVIDENCE_OUTPUT_DIR=""
EVIDENCE_DIRECTORY_IDENTITY=""
CURRENT_CHECK="argument-validation"
MARKERS_CREATED="false"
REPLACEMENT_POD=""
REPLACEMENT_POD_CANDIDATE=""
ORDINARY_CONTROL_POD=""
ORDINARY_CONTROL_POD_UID=""
KMS_CANONICAL_KEY_ID=""
KMS_KEY_ID_HASH=""
OCE_PORT_FORWARD_PID=""
OCE_PORT_FORWARD_LOG=""
OCE_PORT_FORWARD_CLEANED="false"
OCE_API_TUNNEL_SCRIPT="${OCE_API_TUNNEL_SCRIPT:-}"
OCE_API_TUNNEL_STARTUP_TIMEOUT_SECONDS="${OCE_API_TUNNEL_STARTUP_TIMEOUT_SECONDS:-120}"
OCE_API_TUNNEL_CLEANUP_TIMEOUT_SECONDS="${OCE_API_TUNNEL_CLEANUP_TIMEOUT_SECONDS:-30}"
OCE_API_TUNNEL_CLEANUP_GRACE_SECONDS=15
OCE_API_TUNNEL_READY_FILE=""
OCE_API_TUNNEL_STATE_FILE=""
FINAL_EVIDENCE_CANDIDATE=""
FINAL_MANIFEST_CANDIDATE=""
FINAL_SIGNATURE_CANDIDATE=""
EVIDENCE_PREPASS_BACKUP=""
NATIVE_HISTORY_EVALUATOR_PATH=""
NATIVE_HISTORY_EVALUATOR_B64=""
NATIVE_HISTORY_EVALUATOR_SHA256=""
NATIVE_TIMELINE_READER_B64=""
AGENTGATEWAY_TELEMETRY_EVALUATOR_B64=""
TENANT_A_POD_UID=""
TENANT_B_POD_UID=""
REPLACEMENT_POD_UID=""
FINAL_EVIDENCE_IDENTITY=""
FINAL_MANIFEST_IDENTITY=""
FINAL_SIGNATURE_IDENTITY=""
FINAL_EVIDENCE_FD=""

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
    '  --image-source-revision COMMIT  Image build revision; compiled inputs must match HEAD' \
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

portable_file_identity() {
  local path="$1"
  local metadata
  if metadata="$(stat -Lc '%d %i %u %h %a %s' "$path" 2>/dev/null)" &&
    [[ "$metadata" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+\ [0-7]{3,4}\ [0-9]+$ ]]; then
    :
  elif metadata="$(stat -f '%d %i %u %l %Lp %z' "$path" 2>/dev/null)" &&
    [[ "$metadata" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+\ [0-7]{3,4}\ [0-9]+$ ]]; then
    :
  else
    die "could not inspect a validation evidence file"
  fi
  printf '%s' "$metadata"
}

private_regular_file_identity() {
  local path="$1"
  local metadata device inode owner links mode size
  [[ -f "$path" && ! -L "$path" ]] ||
    die "validation evidence path must be a regular, non-symlink file"
  metadata="$(portable_file_identity "$path")"
  read -r device inode owner links mode size <<<"$metadata"
  [[ "$owner" == "$(id -u)" && "$links" == "1" && "$mode" == "600" ]] ||
    die "validation evidence files must be user-owned mode 0600 with one hard link"
  printf '%s:%s:%s:%s:%s:%s' "$device" "$inode" "$owner" "$links" "$mode" "$size"
}

private_directory_identity() {
  local path="$1"
  local metadata device inode owner links mode size
  [[ -d "$path" && ! -L "$path" ]] ||
    die "validation evidence directory must be a non-symlink directory"
  metadata="$(portable_file_identity "$path")"
  read -r device inode owner links mode size <<<"$metadata"
  [[ "$owner" == "$(id -u)" && "$mode" == "700" ]] ||
    die "validation evidence directory must be user-owned mode 0700"
  printf '%s:%s:%s:%s' "$device" "$inode" "$owner" "$mode"
}

assert_private_file_identity() {
  local path="$1"
  local expected_identity="$2"
  local actual_identity
  actual_identity="$(private_regular_file_identity "$path")"
  [[ "$actual_identity" == "$expected_identity" ]] ||
    die "validation evidence file identity changed during signing"
}

assert_open_file_matches_path() {
  local fd="$1"
  local path="$2"
  node - "$fd" "$path" <<'NODE'
const fs = require("node:fs");
const fd = Number(process.argv[2]);
const path = process.argv[3];
const opened = fs.fstatSync(fd);
const named = fs.lstatSync(path);
const fields = ["dev", "ino", "uid", "nlink", "size"];
if (!named.isFile() || named.isSymbolicLink() ||
    fields.some(field => opened[field] !== named[field])) {
  process.exit(1);
}
NODE
}

assert_evidence_directory_identity() {
  local actual_identity
  actual_identity="$(private_directory_identity "$EVIDENCE_OUTPUT_DIR")"
  [[ "$actual_identity" == "$EVIDENCE_DIRECTORY_IDENTITY" ]] ||
    die "validation evidence directory identity changed during the run"
}

opened_file_path() {
  local fd="$1"
  if [[ -e "/proc/self/fd/$fd" ]]; then
    printf '/proc/self/fd/%s' "$fd"
  else
    printf '/dev/fd/%s' "$fd"
  fi
}

validate_evidence_parent() {
  local requested_parent="$1"
  node - "$requested_parent" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const effectiveUid = process.geteuid();
let current = fs.realpathSync(process.argv[2]);
const resolvedParent = current;
for (;;) {
  const stat = fs.lstatSync(current);
  const mode = stat.mode & 0o7777;
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new Error(`evidence parent component is not a directory: ${current}`);
  }
  if (stat.uid !== 0 && stat.uid !== effectiveUid) {
    throw new Error(`evidence parent component has an untrusted owner: ${current}`);
  }
  if ((mode & 0o022) !== 0 && !(stat.uid === 0 && (mode & 0o1000) !== 0)) {
    throw new Error(`evidence parent component is group/other writable: ${current}`);
  }
  const parent = path.dirname(current);
  if (parent === current) break;
  current = parent;
}
process.stdout.write(resolvedParent);
NODE
}

sha256_text() {
  local digest_output digest
  digest_output="$(printf '%s' "$1" | openssl dgst -sha256 -r)" ||
    die "could not hash value"
  digest="${digest_output%% *}"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "hash command returned an invalid SHA-256 digest"
  printf '%s' "$digest"
}

sha256_base64() {
  local digest_output digest
  digest_output="$(
    printf '%s' "$1" |
      openssl base64 -A -d |
      openssl dgst -sha256 -r
  )" || die "could not hash base64 value"
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

oce_api_tunnel_resources_absent() {
  [[ -n "$OCE_API_TUNNEL_STATE_FILE" &&
    -f "$OCE_API_TUNNEL_STATE_FILE" &&
    ! -L "$OCE_API_TUNNEL_STATE_FILE" ]] || return 1
  private_regular_file_identity "$OCE_API_TUNNEL_STATE_FILE" >/dev/null || return 1

  local namespace relay_pod egress_policy api_ingress_policy cleanup_status
  namespace="$(jq -er '.namespace' "$OCE_API_TUNNEL_STATE_FILE")" || return 1
  relay_pod="$(jq -er '.relayPod' "$OCE_API_TUNNEL_STATE_FILE")" || return 1
  egress_policy="$(jq -er '.egressPolicy' "$OCE_API_TUNNEL_STATE_FILE")" || return 1
  api_ingress_policy="$(
    jq -er '.apiIngressPolicy' "$OCE_API_TUNNEL_STATE_FILE"
  )" || return 1
  cleanup_status="$(jq -er '.cleanupStatus' "$OCE_API_TUNNEL_STATE_FILE")" || return 1

  [[ "$namespace" == "$OCE_SYSTEM_NAMESPACE" &&
    "$relay_pod" =~ ^oce-api-loopback-relay-[0-9a-f]{16}$ &&
    "$egress_policy" == "${relay_pod}-egress" &&
    "$api_ingress_policy" == "${relay_pod}-api-ingress" &&
    "$cleanup_status" == "complete" ]] || return 1

  local resource_name
  resource_name="$(
    kube -n "$namespace" \
      --request-timeout="${OCE_API_TUNNEL_CLEANUP_TIMEOUT_SECONDS}s" get \
      "pod/$relay_pod" \
      "networkpolicy/$egress_policy" \
      "networkpolicy/$api_ingress_policy" \
      --ignore-not-found=true -o name
  )" || return 1
  [[ -z "$resource_name" ]]
}

start_oce_api_port_forward() {
  [[ -z "$OCE_PORT_FORWARD_PID" ]] || die "OCE API tunnel is already running"
  if oce_api_port_is_ready; then
    die "OCE API local port is already accepting connections"
  fi

  OCE_PORT_FORWARD_LOG="$WORK_DIR/oce-api-port-forward.log"
  OCE_API_TUNNEL_READY_FILE="$WORK_DIR/oce-api-tunnel.ready"
  OCE_API_TUNNEL_STATE_FILE="$WORK_DIR/oce-api-tunnel-state.json"
  : >"$OCE_PORT_FORWARD_LOG"
  chmod 600 "$OCE_PORT_FORWARD_LOG"
  "$OCE_API_TUNNEL_SCRIPT" \
    --kube-context "$KUBE_CONTEXT" \
    --namespace "$OCE_SYSTEM_NAMESPACE" \
    --local-port "$OCE_API_LOCAL_PORT" \
    --startup-timeout-seconds "$OCE_API_TUNNEL_STARTUP_TIMEOUT_SECONDS" \
    --cleanup-timeout-seconds "$OCE_API_TUNNEL_CLEANUP_TIMEOUT_SECONDS" \
    --ready-file "$OCE_API_TUNNEL_READY_FILE" \
    --state-file "$OCE_API_TUNNEL_STATE_FILE" \
    >"$OCE_PORT_FORWARD_LOG" 2>&1 &
  OCE_PORT_FORWARD_PID=$!
  OCE_PORT_FORWARD_CLEANED="false"

  local attempt wait_status
  for ((
    attempt = 0;
    attempt <
      (OCE_API_TUNNEL_STARTUP_TIMEOUT_SECONDS +
        OCE_API_TUNNEL_CLEANUP_TIMEOUT_SECONDS * 2 +
        OCE_API_TUNNEL_CLEANUP_GRACE_SECONDS) * 10;
    attempt += 1
  )); do
    if ! kill -0 "$OCE_PORT_FORWARD_PID" 2>/dev/null; then
      if wait "$OCE_PORT_FORWARD_PID" 2>/dev/null; then
        wait_status=0
      else
        wait_status=$?
      fi
      OCE_PORT_FORWARD_PID=""
      OCE_API_URL=""
      if oce_api_tunnel_resources_absent; then
        OCE_PORT_FORWARD_CLEANED="true"
      fi
      die "OCE API tunnel exited with status ${wait_status} before becoming ready"
    fi
    if [[ -f "$OCE_API_TUNNEL_READY_FILE" &&
      ! -L "$OCE_API_TUNNEL_READY_FILE" ]] &&
      private_regular_file_identity "$OCE_API_TUNNEL_READY_FILE" >/dev/null &&
      grep -Fqx \
        "Forwarding from 127.0.0.1:${OCE_API_LOCAL_PORT} -> 18080" \
        "$OCE_API_TUNNEL_READY_FILE" &&
      kill -0 "$OCE_PORT_FORWARD_PID" 2>/dev/null; then
      OCE_API_URL="http://127.0.0.1:${OCE_API_LOCAL_PORT}"
      return 0
    fi
    sleep 0.1
  done
  die "OCE API tunnel did not become ready on the explicit loopback port"
}

stop_oce_api_port_forward() {
  local pid="${OCE_PORT_FORWARD_PID:-}"
  [[ -n "$pid" ]] || return 0

  if kill -0 "$pid" 2>/dev/null; then
    if ! kill "$pid" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
  fi
  local wait_status watchdog_pid
  (
    sleep "$((OCE_API_TUNNEL_CLEANUP_TIMEOUT_SECONDS * 2 + 15))"
    kill -KILL "$pid" 2>/dev/null || true
  ) </dev/null >/dev/null 2>&1 &
  watchdog_pid=$!
  if wait "$pid" 2>/dev/null; then
    wait_status=0
  else
    wait_status=$?
  fi
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  ((wait_status == 143)) || return 1
  kill -0 "$pid" 2>/dev/null && return 1
  oce_api_tunnel_resources_absent || return 1
  OCE_PORT_FORWARD_PID=""
  OCE_API_URL=""
  OCE_PORT_FORWARD_CLEANED="true"
}

cleanup_markers() {
  [[ "$MARKERS_CREATED" == "true" ]] || return 0
  local pod pod_uid
  while IFS=$'\t' read -r pod pod_uid; do
    [[ -n "$pod" && -n "$pod_uid" ]] || continue
    exec_in_exact_pod \
      "$TENANT_A_NAMESPACE" "$pod" "$TENANT_A_CONTAINER" "$pod_uid" \
      rm -f -- "$PERSISTENT_MARKER" "$EPHEMERAL_MARKER" >/dev/null 2>&1 || true
  done < <(
    printf '%s\t%s\n%s\t%s\n' \
      "$TENANT_A_POD" "$TENANT_A_POD_UID" \
      "$REPLACEMENT_POD" "$REPLACEMENT_POD_UID"
  )
}

assert_pod_uid() {
  local namespace="$1"
  local pod="$2"
  local expected_uid="$3"
  local actual_uid
  [[ "$expected_uid" =~ ^[A-Za-z0-9._:-]+$ ]] || die "expected pod UID is invalid"
  actual_uid="$(
    kube -n "$namespace" get pod "$pod" -o json |
      jq -er '.metadata.uid | select(type == "string" and length > 0)'
  )" || die "could not re-read pod identity before exec"
  [[ "$actual_uid" == "$expected_uid" ]] ||
    die "pod identity changed before exec; refusing a name-reused workload"
}

exec_in_exact_pod() {
  local namespace="$1"
  local pod="$2"
  local container="$3"
  local expected_uid="$4"
  shift 4
  (($# > 0)) || die "exact-pod exec requires a command"

  assert_pod_uid "$namespace" "$pod" "$expected_uid"
  # OPENCLAW_POD_UID comes from the Downward API. Checking it inside the
  # container closes the remaining name-reuse race between the GET and exec.
  # shellcheck disable=SC2016 # The variables and positional arguments expand in the guest.
  kube -n "$namespace" exec "$pod" -c "$container" -- \
    env "OCE_EXPECTED_POD_UID=$expected_uid" \
    sh -eu -c '
      [ "${OPENCLAW_POD_UID:-}" = "$OCE_EXPECTED_POD_UID" ] || exit 91
      shift
      exec "$@"
    ' sh "__OCE_EXACT_POD_COMMAND__" "$@"
}

exec_runtime_command() {
  local namespace="$1"
  local pod="$2"
  local container="$3"
  local expected_uid="$4"
  shift 4
  if [[ -n "$expected_uid" ]]; then
    exec_in_exact_pod "$namespace" "$pod" "$container" "$expected_uid" "$@"
  else
    kube -n "$namespace" exec "$pod" -c "$container" -- "$@"
  fi
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

cleanup_ordinary_control_pod() {
  [[ -n "$ORDINARY_CONTROL_POD" ]] || return 0
  if [[ -z "$ORDINARY_CONTROL_POD_UID" ]]; then
    local recovered_probe="$WORK_DIR/ordinary-control-pod-recovered.json"
    kube -n "$AGW_NAMESPACE" get pod "$ORDINARY_CONTROL_POD" -o json \
      >"$recovered_probe" || return 1
    jq -e \
      --arg namespace "$AGW_NAMESPACE" \
      --arg name "$ORDINARY_CONTROL_POD" \
      --arg image "$RUNTIME_IMAGE" '
      .metadata.namespace == $namespace
      and .metadata.name == $name
      and .metadata.labels["app.kubernetes.io/managed-by"] ==
        "openclaw-enterprise-blueprint"
      and .metadata.labels["openclaw.dev/validation"] == "ordinary-pod-control"
      and (.metadata.uid | type == "string" and length > 0)
      and (.spec.runtimeClassName == null)
      and (.spec.volumes // [] | length == 0)
      and .spec.automountServiceAccountToken == false
      and .spec.enableServiceLinks == false
      and .spec.restartPolicy == "Never"
      and .spec.serviceAccountName == "default"
      and (.spec.containers | length == 1)
      and .spec.containers[0].name == "ordinary-control"
      and .spec.containers[0].image == $image
      and .spec.containers[0].command == ["sh", "-c", "sleep 3600"]
    ' "$recovered_probe" >/dev/null || return 1
    ORDINARY_CONTROL_POD_UID="$(jq -er '.metadata.uid' "$recovered_probe")" || return 1
  fi
  delete_pod_with_uid \
    "$AGW_NAMESPACE" \
    "$ORDINARY_CONTROL_POD" \
    "$ORDINARY_CONTROL_POD_UID" \
    "$WORK_DIR/ordinary-control-delete-options.json"
  kube -n "$AGW_NAMESPACE" wait \
    --for=delete "pod/$ORDINARY_CONTROL_POD" --timeout=60s >/dev/null
  ORDINARY_CONTROL_POD=""
  ORDINARY_CONTROL_POD_UID=""
}

on_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  stop_oce_api_port_forward >/dev/null 2>&1
  cleanup_markers
  cleanup_ordinary_control_pod >/dev/null 2>&1
  if [[ -n "$FINAL_EVIDENCE_FD" ]]; then
    exec {FINAL_EVIDENCE_FD}<&- 2>/dev/null || true
  fi
  if [[ -n "$FINAL_EVIDENCE_CANDIDATE" ]]; then
    rm -f -- "$FINAL_EVIDENCE_CANDIDATE"
  fi
  if [[ -n "$FINAL_MANIFEST_CANDIDATE" ]]; then
    rm -f -- "$FINAL_MANIFEST_CANDIDATE"
  fi
  if [[ -n "$FINAL_SIGNATURE_CANDIDATE" ]]; then
    rm -f -- "$FINAL_SIGNATURE_CANDIDATE"
  fi
  if [[ $status -ne 0 && "$EVIDENCE_OWNED" == "true" &&
    -n "$EVIDENCE_FILE" && -f "$EVIDENCE_FILE" ]]; then
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
  if [[ -n "$EVIDENCE_LOCK_DIR" && -d "$EVIDENCE_LOCK_DIR" ]]; then
    rmdir -- "$EVIDENCE_LOCK_DIR"
  fi
  exit "$status"
}

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
    --image-source-revision) IMAGE_SOURCE_REVISION="${2:-}"; shift 2 ;;
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
[[ "$OCE_API_TUNNEL_STARTUP_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
  die "OCE API tunnel startup timeout must be a positive integer"
((OCE_API_TUNNEL_STARTUP_TIMEOUT_SECONDS <= 600)) ||
  die "OCE API tunnel startup timeout must not exceed 600 seconds"
[[ "$OCE_API_TUNNEL_CLEANUP_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
  die "OCE API tunnel cleanup timeout must be a positive integer"
((OCE_API_TUNNEL_CLEANUP_TIMEOUT_SECONDS <= 120)) ||
  die "OCE API tunnel cleanup timeout must not exceed 120 seconds"
[[ "$OCE_SYSTEM_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ &&
  ${#OCE_SYSTEM_NAMESPACE} -le 63 ]] ||
  die "OCE system namespace must be a Kubernetes DNS label"
[[ "$OCE_SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] ||
  die "OCE source revision must be a full lowercase Git commit SHA"
[[ "$OCE_SOURCE_REVISION" == "$EXPECTED_OCE_SOURCE_REVISION" ]] ||
  die "OCE source revision must match this sample's reviewed pin"
[[ -z "$IMAGE_SOURCE_REVISION" || "$IMAGE_SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] ||
  die "image source revision must be a full lowercase Git commit SHA"
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
  awk aws basename cat chmod cp curl date dirname git grep id jq kubectl mkdir mktemp node openssl rm \
  python3 sed sleep stat uname; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is unavailable: $command_name"
done

read_credential() {
  local file="$1"
  local credential_blob metadata value
  local file_owner file_links mode file_size
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] ||
    die "credential file must be a readable regular, non-symlink file"
  exec 3<"$file" || die "could not open credential file"
  if metadata="$(stat -Lc '%u %h %a %s' /proc/self/fd/3 2>/dev/null)" &&
    [[ "$metadata" =~ ^[0-9]+\ [0-9]+\ [0-7]{3,4}\ [0-9]+$ ]]; then
    :
  elif metadata="$(stat -f '%u %l %Lp %z' /dev/fd/3 2>/dev/null)" &&
    [[ "$metadata" =~ ^[0-9]+\ [0-9]+\ [0-7]{3,4}\ [0-9]+$ ]]; then
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

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
REPO_ROOT="$(git -C "$(dirname "$SCRIPT_PATH")" rev-parse --show-toplevel)" ||
  die "validator must run from a Git checkout"
GIT_REVISION="$(git -C "$REPO_ROOT" rev-parse --verify 'HEAD^{commit}')" ||
  die "could not resolve an exact Git revision"
[[ "$GIT_REVISION" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve an exact Git revision"
[[ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" ]] ||
  die "Git worktree must be clean before live validation"
GIT_WORKTREE_STATE="clean"
IMAGE_SOURCE_REVISION="${IMAGE_SOURCE_REVISION:-$GIT_REVISION}"
python3 "$(dirname "$SCRIPT_PATH")/lib/check-image-source-revision.py" \
  "$REPO_ROOT" "$IMAGE_SOURCE_REVISION" "$GIT_REVISION" >/dev/null ||
  die "image build source does not match the candidate compiled inputs"
VALIDATOR_SHA256="$(sha256_file "$SCRIPT_PATH")"
EVIDENCE_REQUESTED_DIR="$(
  node -e 'process.stdout.write(require("node:path").resolve(process.argv[1]))' "$EVIDENCE_DIR"
)"
EVIDENCE_REQUESTED_PARENT="$(dirname -- "$EVIDENCE_REQUESTED_DIR")"
EVIDENCE_BASENAME="$(basename -- "$EVIDENCE_REQUESTED_DIR")"
[[ "$EVIDENCE_BASENAME" != "." && "$EVIDENCE_BASENAME" != ".." ]] ||
  die "evidence directory name is invalid"
EVIDENCE_PARENT="$(
  validate_evidence_parent "$EVIDENCE_REQUESTED_PARENT"
)" || die "evidence parent directory is not private"
EVIDENCE_OUTPUT_DIR="$EVIDENCE_PARENT/$EVIDENCE_BASENAME"
[[ ! -e "$EVIDENCE_OUTPUT_DIR" && ! -L "$EVIDENCE_OUTPUT_DIR" ]] ||
  die "evidence directory already exists; choose a fresh directory"
mkdir -m 700 -- "$EVIDENCE_OUTPUT_DIR"
EVIDENCE_OWNED="true"
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cd -- "$EVIDENCE_OUTPUT_DIR"
EVIDENCE_DIRECTORY_IDENTITY="$(private_directory_identity ".")"
assert_evidence_directory_identity
EVIDENCE_FILE="./live-validation-evidence.txt"
MANIFEST_FILE="./live-validation-manifest.sha256"
SIGNATURE_FILE="./live-validation-evidence.sig.b64"
EVIDENCE_LOCK_DIR="./.live-validation.lock"
if ! mkdir -m 700 -- "$EVIDENCE_LOCK_DIR" 2>/dev/null; then
  EVIDENCE_LOCK_DIR=""
  die "evidence directory is already in use by another validation run"
fi
if ! (set -o noclobber; : >"$EVIDENCE_FILE") 2>/dev/null; then
  die "evidence file already exists; choose a fresh directory"
fi
chmod 600 "$EVIDENCE_FILE"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oce-live-validation.XXXXXX")"
NATIVE_HISTORY_EVALUATOR_PATH="$(dirname "$SCRIPT_PATH")/lib/evaluate-native-tool-history.mjs"
if [[ -z "$OCE_API_TUNNEL_SCRIPT" ]]; then
  OCE_API_TUNNEL_SCRIPT="$(dirname "$SCRIPT_PATH")/oce-api-tunnel.sh"
fi
[[ -f "$OCE_API_TUNNEL_SCRIPT" &&
  ! -L "$OCE_API_TUNNEL_SCRIPT" &&
  -x "$OCE_API_TUNNEL_SCRIPT" ]] ||
  die "OCE API tunnel helper must be an executable regular, non-symlink file"
[[ -f "$NATIVE_HISTORY_EVALUATOR_PATH" &&
  ! -L "$NATIVE_HISTORY_EVALUATOR_PATH" &&
  -r "$NATIVE_HISTORY_EVALUATOR_PATH" ]] ||
  die "native tool-history evaluator must be a readable regular, non-symlink file"
NATIVE_HISTORY_EVALUATOR_B64="$(
  openssl base64 -A -in "$NATIVE_HISTORY_EVALUATOR_PATH"
)" || die "could not encode the native tool-history evaluator"
[[ -n "$NATIVE_HISTORY_EVALUATOR_B64" ]] ||
  die "native tool-history evaluator encoding is empty"
NATIVE_HISTORY_EVALUATOR_SHA256="$(sha256_base64 "$NATIVE_HISTORY_EVALUATOR_B64")"
for helper in read-native-timeline.cjs evaluate-agentgateway-telemetry.mjs; do
  helper_path="$(dirname "$SCRIPT_PATH")/lib/$helper"
  [[ -f "$helper_path" && ! -L "$helper_path" && -r "$helper_path" ]] ||
    die "native trace helper must be a readable regular, non-symlink file"
done
NATIVE_TIMELINE_READER_B64="$(openssl base64 -A -in "$(dirname "$SCRIPT_PATH")/lib/read-native-timeline.cjs")"
AGENTGATEWAY_TELEMETRY_EVALUATOR_B64="$(openssl base64 -A -in "$(dirname "$SCRIPT_PATH")/lib/evaluate-agentgateway-telemetry.mjs")"
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
  printf 'EVIDENCE\timage-build-revision\t%s\n' "$IMAGE_SOURCE_REVISION"
  printf 'EVIDENCE\tgit-worktree-state\t%s\n' "$GIT_WORKTREE_STATE"
  printf 'EVIDENCE\tvalidator-sha256\t%s\n' "$VALIDATOR_SHA256"
  printf 'EVIDENCE\tnative-history-evaluator-sha256\t%s\n' \
    "$NATIVE_HISTORY_EVALUATOR_SHA256"
  printf 'EVIDENCE\tnative-timeline-reader-sha256\t%s\n' \
    "$(sha256_base64 "$NATIVE_TIMELINE_READER_B64")"
  printf 'EVIDENCE\tagentgateway-telemetry-evaluator-sha256\t%s\n' \
    "$(sha256_base64 "$AGENTGATEWAY_TELEMETRY_EVALUATOR_B64")"
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

verify_ecr_image_revision() {
  local evidence_alias="$1"
  local image="$2"
  local digest="$3"
  local registry repository_ref repository expected_digest
  local manifest_file config_file config_digest config_url

  [[ "$image" == *".dkr.ecr."* ]] || return 0
  registry="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/"
  [[ "$image" == "$registry"* ]] ||
    die "$evidence_alias image belongs to an unexpected ECR registry"
  repository_ref="${image#"$registry"}"
  [[ "$repository_ref" == *@sha256:* ]] ||
    die "$evidence_alias ECR image is not pinned by digest"
  repository="${repository_ref%@*}"
  expected_digest="${repository_ref##*@}"
  [[ "$repository" =~ ^[A-Za-z0-9._/-]+$ ]] ||
    die "$evidence_alias ECR repository name is invalid"
  [[ "$expected_digest" == "$digest" ]] ||
    die "$evidence_alias running image digest does not match the deployed ECR reference"

  manifest_file="$WORK_DIR/ecr-manifest-${evidence_alias}.json"
  config_file="$WORK_DIR/ecr-config-${evidence_alias}.json"
  aws ecr batch-get-image \
    --region "$AWS_REGION" \
    --registry-id "$AWS_ACCOUNT_ID" \
    --repository-name "$repository" \
    --image-ids "imageDigest=$digest" \
    --accepted-media-types \
    application/vnd.oci.image.manifest.v1+json \
    application/vnd.docker.distribution.manifest.v2+json \
    --output json >"$manifest_file"
  jq -e \
    --arg registry "$AWS_ACCOUNT_ID" \
    --arg repository "$repository" \
    --arg digest "$digest" '
      (.failures | length) == 0
      and (.images | length) == 1
      and .images[0].registryId == $registry
      and .images[0].repositoryName == $repository
      and .images[0].imageId.imageDigest == $digest
    ' "$manifest_file" >/dev/null ||
    die "$evidence_alias ECR manifest lookup did not bind the requested digest"
  config_digest="$(
    jq -er '.images[0].imageManifest | fromjson | .config.digest' "$manifest_file"
  )" || die "$evidence_alias ECR manifest did not contain an image config digest"
  [[ "$config_digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "$evidence_alias ECR image config digest is invalid"
  config_url="$(
    aws ecr get-download-url-for-layer \
      --region "$AWS_REGION" \
      --registry-id "$AWS_ACCOUNT_ID" \
      --repository-name "$repository" \
      --layer-digest "$config_digest" \
      --query downloadUrl \
      --output text
  )" || die "$evidence_alias ECR image config URL lookup failed"
  [[ "$config_url" == https://* ]] ||
    die "$evidence_alias ECR image config URL was not HTTPS"
  curl --fail --silent --show-error \
    --proto '=https' --tlsv1.2 --max-time 30 --max-filesize 1048576 \
    --output "$config_file" "$config_url" ||
    die "$evidence_alias ECR image config download failed"
  jq -e --arg revision "$IMAGE_SOURCE_REVISION" '
    .config.Labels["org.opencontainers.image.revision"] == $revision
  ' "$config_file" >/dev/null ||
    die "$evidence_alias ECR image revision label does not match the verified image build revision"
  printf 'EVIDENCE\timage-source-revision-%s\t%s@%s revision=%s\n' \
    "$evidence_alias" "$repository" "$digest" "$IMAGE_SOURCE_REVISION" >>"$EVIDENCE_FILE"
}

verify_pod_ecr_image_revisions() {
  local evidence_alias="$1"
  local pod_file="$2"
  local index container image digest records_file

  records_file="$WORK_DIR/ecr-images-${evidence_alias}.tsv"
  jq -er '
    def records($spec; $status):
      ($spec // [])[] as $container
      | (
          [($status // [])[] | select(.name == $container.name)]
          | if length == 1
            then .[0]
            else error("container image status is missing or ambiguous")
            end
        ) as $state
      | [
          $container.name,
          $container.image,
          (
            $state.imageID
            | capture("(?<digest>sha256:[0-9a-f]{64})$").digest
          )
        ]
      | @tsv;
    records(.spec.containers; .status.containerStatuses),
    records(.spec.initContainers; .status.initContainerStatuses),
    records(.spec.ephemeralContainers; .status.ephemeralContainerStatuses)
  ' "$pod_file" >"$records_file" ||
    die "$evidence_alias pod lacks complete immutable image status"
  index=0
  while IFS=$'\t' read -r container image digest; do
    index=$((index + 1))
    verify_ecr_image_revision "${evidence_alias}-${index}" "$image" "$digest"
  done <"$records_file"
}

assert_no_aws_credential_paths() {
  local tenant_alias="$1"
  local pod_file="$2"
  local runtime_container="$3"
  local finding

  if ! finding="$(
    jq -r \
      --arg runtime_container "$runtime_container" \
      --arg runtime_home "$RUNTIME_HOME" \
      --arg runtime_codex_home "$RUNTIME_CODEX_HOME" \
      --arg runtime_codex_home_subpath "$RUNTIME_CODEX_HOME_SUBPATH" \
      --arg persistent_home "$PERSISTENT_HOME" \
      --arg persistent_state_root "$PERSISTENT_STATE_ROOT" \
      --arg runtime_state_volume "$RUNTIME_STATE_VOLUME" \
      --arg prep_init_container "$PREP_INIT_CONTAINER" \
      --arg owner_init_container "$OWNER_INIT_CONTAINER" \
      --arg link_init_container "$LINK_INIT_CONTAINER" \
      --arg oce_configuration_volume "$OCE_CONFIGURATION_VOLUME" \
      --arg oce_configuration_mount "$OCE_CONFIGURATION_MOUNT" \
      --arg oce_service_principal_volume "$OCE_SERVICE_PRINCIPAL_VOLUME" \
      --arg oce_service_principal_mount "$OCE_SERVICE_PRINCIPAL_MOUNT" \
      --arg agentgateway_ca_volume "$AGENTGATEWAY_CA_VOLUME" \
      --arg agentgateway_ca_mount "$AGENTGATEWAY_CA_MOUNT" '
      def container_groups:
        [
          {field: "containers", items: (.spec.containers // [])},
          {field: "initContainers", items: (.spec.initContainers // [])},
          {field: "ephemeralContainers", items: (.spec.ephemeralContainers // [])}
        ];

      def container_location($group; $entry):
        "spec.\($group.field)[\($entry.key)] (\($entry.value.name | tojson))";

      def forbidden_aws_environment($name):
        [
          "AWS_ACCESS_KEY_ID",
          "AWS_SECRET_ACCESS_KEY",
          "AWS_SESSION_TOKEN",
          "AWS_SECURITY_TOKEN",
          "AWS_WEB_IDENTITY_TOKEN_FILE",
          "AWS_ROLE_ARN",
          "AWS_CONTAINER_CREDENTIALS_FULL_URI",
          "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
          "AWS_CONTAINER_AUTHORIZATION_TOKEN",
          "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
          "AWS_SHARED_CREDENTIALS_FILE",
          "AWS_CONFIG_FILE",
          "AWS_EC2_METADATA_SERVICE_ENDPOINT"
        ] | index($name) != null;

      def normalized_path($path):
        if $path == "/" then "/" else ($path | sub("/+$"; "")) end;

      def paths_overlap($left; $right):
        (normalized_path($left)) as $left_path
        | (normalized_path($right)) as $right_path
        | $left_path == "/"
          or $right_path == "/"
          or $left_path == $right_path
          or ($left_path | startswith($right_path + "/"))
          or ($right_path | startswith($left_path + "/"));

      def credential_like_path($path):
        if ($path | type) != "string" then false
        else
          paths_overlap($path; "/home/node/.aws")
          or paths_overlap($path; "/root/.aws")
          or paths_overlap(
              $path;
              "/var/run/secrets/eks.amazonaws.com/serviceaccount"
            )
          or paths_overlap(
              $path;
              "/var/run/secrets/kubernetes.io/serviceaccount"
            )
          or (
              $path
              | test(
                  "(^|/)([.]aws|aws[-_]?credentials?|credentials?|secrets?)(/|$)";
                  "i"
                )
            )
        end;

      def has_exact_keys($object; $keys):
        ($object | type) == "object"
        and (($object | keys | sort) == ($keys | sort));

      def is_empty_dir_volume($volume):
        has_exact_keys($volume; ["name", "emptyDir"])
        and (($volume.emptyDir | type) == "object");

      def is_oce_configuration_volume($volume):
        has_exact_keys($volume; ["name", "configMap"])
        and $volume.name == $oce_configuration_volume
        and (($volume.configMap // null) | type) == "object"
        and (($volume.configMap.name // null) | type) == "string"
        and ($volume.configMap.name | length) > 0
        and $volume.configMap.items == [
          {key: "openclaw.json", path: "openclaw.json"}
        ]
        and (($volume.configMap.defaultMode // 420) == 420)
        and (($volume.configMap.optional // false) == false);

      def is_agentgateway_ca_volume($volume):
        has_exact_keys($volume; ["name", "configMap"])
        and $volume.name == $agentgateway_ca_volume
        and (($volume.configMap // null) | type) == "object"
        and $volume.configMap.name == $agentgateway_ca_volume
        and $volume.configMap.items == [
          {key: "ca.crt", path: "ca.crt"}
        ]
        and (($volume.configMap.defaultMode // 420) == 420)
        and (($volume.configMap.optional // false) == false);

      def is_gateway_state_volume($volume; $persistent_volume):
        has_exact_keys($volume; ["name", "persistentVolumeClaim"])
        and $persistent_volume != null
        and $volume.name == $persistent_volume
        and has_exact_keys(
          $volume.persistentVolumeClaim;
          ["claimName"]
        )
        and (($volume.persistentVolumeClaim.claimName // null) | type)
          == "string"
        and ($volume.persistentVolumeClaim.claimName | length) > 0;

      def is_oce_service_principal_volume($volume):
        has_exact_keys($volume; ["name", "projected"])
        and $volume.name == $oce_service_principal_volume
        and (($volume.projected // null) | type) == "object"
        and (($volume.projected.defaultMode // 420) == 420)
        and $volume.projected.sources == [
          {
            serviceAccountToken: {
              audience: "openclaw-enterprise",
              expirationSeconds: 900,
              path: "token"
            }
          }
        ];

      def volume_source($volume):
        if ($volume | type) != "object" then "malformed"
        elif ($volume | has("secret")) then "Secret"
        elif ($volume | has("csi")) then "CSI"
        elif ($volume | has("persistentVolumeClaim")) then "PersistentVolumeClaim"
        elif ($volume | has("hostPath")) then "hostPath"
        elif ($volume | has("nfs")) then "NFS"
        elif ($volume | has("ephemeral")) then "ephemeral volume claim"
        elif is_oce_service_principal_volume($volume) then
          "OCE service-account token"
        elif (
          [
            $volume.projected.sources[]?
            | select((.secret // null) != null)
          ] | length
        ) > 0 then "projected Secret"
        elif (
          [
            $volume.projected.sources[]?
            | select((.serviceAccountToken // null) != null)
          ] | length
        ) > 0 then "service-account token"
        elif ($volume | has("projected")) then "projected"
        elif ($volume | has("configMap")) then "ConfigMap"
        elif ($volume | has("emptyDir")) then "emptyDir"
        else "unsupported"
        end;

      def approved_volume($volume; $persistent_volume):
        is_empty_dir_volume($volume)
        or is_oce_configuration_volume($volume)
        or is_agentgateway_ca_volume($volume)
        or is_gateway_state_volume($volume; $persistent_volume)
        or is_oce_service_principal_volume($volume);

      def is_runtime_container($group_field; $container_name):
        $group_field == "containers"
        and $container_name == $runtime_container;

      def is_init_container($group_field; $container_name; $expected_name):
        $group_field == "initContainers"
        and $container_name == $expected_name;

      def approved_runtime_state_mount(
        $mount;
        $group_field;
        $container_name
      ):
        (
          (
            (
              is_runtime_container($group_field; $container_name)
              and $mount.mountPath == $runtime_home
            )
            or (
              is_init_container(
                $group_field;
                $container_name;
                $owner_init_container
              )
              and $mount.mountPath == $runtime_home
            )
            or (
              (
                is_init_container(
                  $group_field;
                  $container_name;
                  $prep_init_container
                )
                or is_init_container(
                  $group_field;
                  $container_name;
                  $link_init_container
                )
              )
              and $mount.mountPath == "/runtime-state"
            )
          )
          and ($mount.subPath // null) == null
          and ($mount.subPathExpr // null) == null
          and ($mount.readOnly // false) == false
        )
        or (
          is_runtime_container($group_field; $container_name)
          and $mount.mountPath == $runtime_codex_home
          and $mount.subPath == $runtime_codex_home_subpath
          and ($mount.subPathExpr // null) == null
          and ($mount.readOnly // false) == false
        );

      def approved_gateway_state_mount(
        $mount;
        $group_field;
        $container_name
      ):
        (
          (
            is_runtime_container($group_field; $container_name)
            and $mount.mountPath == $persistent_home
          )
          or (
            is_init_container(
              $group_field;
              $container_name;
              $owner_init_container
            )
            and $mount.mountPath == $persistent_home
          )
          or (
            (
              is_init_container(
                $group_field;
                $container_name;
                $prep_init_container
              )
              or is_init_container(
                $group_field;
                $container_name;
                $link_init_container
              )
            )
            and $mount.mountPath == $persistent_state_root
          )
        )
        and ($mount.subPath // null) == null
        and ($mount.subPathExpr // null) == null
        and ($mount.readOnly // false) == false;

      def approved_mount(
        $volume;
        $mount;
        $persistent_volume;
        $group_field;
        $container_name
      ):
        if is_empty_dir_volume($volume) then
          if $volume.name == $runtime_state_volume then
            approved_runtime_state_mount(
              $mount;
              $group_field;
              $container_name
            )
          else true
          end
        elif is_gateway_state_volume($volume; $persistent_volume) then
          approved_gateway_state_mount(
            $mount;
            $group_field;
            $container_name
          )
        elif is_oce_configuration_volume($volume) then
          is_runtime_container($group_field; $container_name)
          and $mount.mountPath == $oce_configuration_mount
          and $mount.readOnly == true
        elif is_agentgateway_ca_volume($volume) then
          is_runtime_container($group_field; $container_name)
          and $mount.mountPath == $agentgateway_ca_mount
          and $mount.readOnly == true
        elif is_oce_service_principal_volume($volume) then
          is_runtime_container($group_field; $container_name)
          and $mount.mountPath == $oce_service_principal_mount
          and $mount.readOnly == true
          and ($mount.subPath // null) == null
          and ($mount.subPathExpr // null) == null
        else
          false
        end;

      def approved_credential_like_mount(
        $volume;
        $mount;
        $group_field;
        $container_name
      ):
        (
          is_empty_dir_volume($volume)
          and $volume.name == $runtime_state_volume
          and approved_runtime_state_mount(
            $mount;
            $group_field;
            $container_name
          )
        )
        or (
          is_oce_service_principal_volume($volume)
          and is_runtime_container($group_field; $container_name)
          and $mount.mountPath == $oce_service_principal_mount
          and $mount.readOnly == true
          and ($mount.subPath // null) == null
          and ($mount.subPathExpr // null) == null
        );

      . as $pod
      | [
          ($pod.spec.containers // [])[]?
          | select(.name == $runtime_container)
          | (.volumeMounts // [])[]?
          | select(.mountPath == $persistent_home)
          | .name
        ] as $persistent_volume_candidates
      | (
          if ($persistent_volume_candidates | length) == 1
          then $persistent_volume_candidates[0]
          else null
          end
        ) as $persistent_volume
      | (
          [
            if (
              ($pod.metadata.annotations // {})["eks.amazonaws.com/role-arn"]
              != null
            ) then
              "metadata.annotations contains eks.amazonaws.com/role-arn"
            else empty end
          ]
          +
          [
            container_groups[] as $group
            | ($group.items | to_entries[]) as $entry
            | ($entry.value.env // [])[]?
            | select(forbidden_aws_environment(.name))
            | "\(container_location($group; $entry)) defines prohibited AWS credential environment \(.name | tojson)"
          ]
          +
          [
            container_groups[] as $group
            | ($group.items | to_entries[]) as $entry
            | select((($entry.value.envFrom // []) | length) > 0)
            | "\(container_location($group; $entry)) uses envFrom, which can inject AWS credential variables"
          ]
          +
          [
            container_groups[] as $group
            | ($group.items | to_entries[]) as $entry
            | (($entry.value.volumeMounts // []) | to_entries[]) as $mount_entry
            | $mount_entry.value as $mount
            | (
                first(
                  ($pod.spec.volumes // [])[]?
                  | select(.name == $mount.name)
                ) // null
              ) as $volume
            | if $volume == null then
                "\(container_location($group; $entry)).volumeMounts[\($mount_entry.key)] references unknown volume \($mount.name | tojson)"
              elif (
                credential_like_path($mount.mountPath)
                and (
                  approved_credential_like_mount(
                    $volume;
                    $mount;
                    $group.field;
                    $entry.value.name
                  ) | not
                )
              ) then
                "\(container_location($group; $entry)).volumeMounts[\($mount_entry.key)] mounts \(volume_source($volume)) volume \($mount.name | tojson) at credential-like path \($mount.mountPath | tojson)"
              elif (
                approved_mount(
                  $volume;
                  $mount;
                  $persistent_volume;
                  $group.field;
                  $entry.value.name
                ) | not
              ) then
                "\(container_location($group; $entry)).volumeMounts[\($mount_entry.key)] uses unapproved \(volume_source($volume)) volume \($mount.name | tojson) at \($mount.mountPath | tojson)"
              else empty end
          ]
          +
          [
            ($pod.spec.volumes // [] | to_entries[]) as $volume_entry
            | select(
                approved_volume($volume_entry.value; $persistent_volume) | not
              )
            | "spec.volumes[\($volume_entry.key)] (\($volume_entry.value.name | tojson)) uses unapproved \(volume_source($volume_entry.value)) source"
          ]
        )
      | first // ""
    ' "$pod_file"
  )"; then
    die "$tenant_alias AWS credential inspection could not evaluate the pod"
  fi

  [[ -z "$finding" ]] ||
    die "$tenant_alias pod violates the runtime volume or AWS credential contract: $finding"
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
      and (($runtime.env // []) | any(
        .name == "OPENCLAW_POD_UID"
        and .valueFrom.fieldRef.apiVersion == "v1"
        and .valueFrom.fieldRef.fieldPath == "metadata.uid"
      ))
  ' "$output_file" >/dev/null || die "$tenant_alias security context check failed"

  assert_no_aws_credential_paths "$tenant_alias" "$output_file" "$container"
  verify_pod_ecr_image_revisions "$tenant_alias" "$output_file"
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

CURRENT_CHECK="tenant-storage-boundary"
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
record_pass "tenant-storage-boundary" \
  "runtime mounts bind to distinct namespace-local PVC/PV UIDs and CSI volume handles"
record_pass "pvc-name-resolution-is-namespaced" \
  "tenant B's claim name is not resolvable in tenant A; no cross-namespace mount was attempted"

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

# Without an AWS credential in the pod, the node's instance metadata service is the remaining way for a
# runtime to obtain the node role. Each runtime must fail to open a TCP connection to the IPv4 IMDS address.
probe_tenant_imds() {
  local tenant_alias="$1"
  local namespace="$2"
  local pod="$3"
  local container="$4"
  local expected_uid="$5"
  local output_file="$6"
  exec_in_exact_pod "$namespace" "$pod" "$container" "$expected_uid" node -e '
    const net = require("node:net");
    const marker = "LIVE_IMDS_PROBE";
    let done = false;
    const finish = (result) => {
      if (done) return;
      done = true;
      process.stdout.write(JSON.stringify({ marker, ...result }) + "\n");
      process.exit(0);
    };
    const socket = net.connect({ host: "169.254.169.254", port: 80, timeout: 5000 });
    socket.on("connect", () => {
      socket.destroy();
      finish({ result: "open" });
    });
    socket.on("timeout", () => {
      socket.destroy();
      finish({ result: "timeout" });
    });
    socket.on("error", error => finish({ result: "error", code: String(error.code || "unknown") }));
    setTimeout(() => finish({ result: "timeout" }), 8000).unref();
  ' >"$output_file" || die "instance metadata probe for $tenant_alias did not run"
  jq -e '
    .marker == "LIVE_IMDS_PROBE"
    and (.result == "timeout" or .result == "error")
  ' "$output_file" >/dev/null ||
    die "$tenant_alias runtime opened a TCP connection to the instance metadata service"
}

guest_evidence() {
  local namespace="$1"
  local pod="$2"
  local container="$3"
  local output_file="$4"
  local expected_kind="$5"
  local expected_uid="${6:-}"
  local evidence_line block_name partition_name
  local saw_block="false"
  local saw_partition="false"
  local saw_virtio_block="false"
  local saw_virtio_partition="false"
  local saw_nvme_block="false"
  local saw_nvme_partition="false"
  # shellcheck disable=SC2016 # This program expands inside the guest, not locally.
  exec_runtime_command "$namespace" "$pod" "$container" "$expected_uid" sh -eu -c '
    printf "LIVE_GUEST_EVIDENCE\n"
    cat /proc/sys/kernel/random/boot_id
    uname -r
    uname -m
    awk "\$2 == \"/\" { print \$1 \" \" \$3; exit }" /proc/mounts
    for block_path in /sys/block/*; do
      [ -e "$block_path" ] || continue
      printf "BLOCK:%s\n" "${block_path##*/}"
    done
    awk "NR > 2 && \$4 != \"\" { print \"PARTITION:\" \$1 \":\" \$2 \":\" \$3 \":\" \$4 }" /proc/partitions
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
  while IFS= read -r evidence_line; do
    case "$evidence_line" in
      BLOCK:*)
        [[ "$evidence_line" =~ ^BLOCK:([A-Za-z0-9._+-]+)$ ]] ||
          die "guest block-device evidence is malformed"
        block_name="${BASH_REMATCH[1]}"
        saw_block="true"
        [[ "$block_name" =~ ^vd[a-z]+$ ]] && saw_virtio_block="true"
        [[ "$block_name" =~ ^nvme[0-9]+n[0-9]+$ ]] && saw_nvme_block="true"
        ;;
      PARTITION:*)
        [[ "$evidence_line" =~ ^PARTITION:[0-9]+:[0-9]+:[0-9]+:([A-Za-z0-9._+-]+)$ ]] ||
          die "guest partition evidence is malformed"
        partition_name="${BASH_REMATCH[1]}"
        saw_partition="true"
        [[ "$partition_name" =~ ^vd[a-z]+[0-9]+$ ]] && saw_virtio_partition="true"
        [[ "$partition_name" =~ ^nvme[0-9]+n[0-9]+p[0-9]+$ ]] &&
          saw_nvme_partition="true"
        ;;
      *)
        die "guest disk evidence contains an unexpected row"
        ;;
    esac
  done < <(sed -n '6,$p' "$output_file")
  [[ "$saw_block" == "true" ]] || die "guest block-device evidence is incomplete"
  [[ "$saw_partition" == "true" ]] || die "guest partition evidence is incomplete"
  case "$expected_kind" in
    sandbox)
      [[ "$saw_virtio_block" == "true" && "$saw_virtio_partition" == "true" ]] ||
        die "sandbox guest did not expose a virtio block device and partition"
      ;;
    ordinary)
      [[ "$saw_virtio_block" == "false" && "$saw_virtio_partition" == "false" ]] ||
        die "ordinary control pod unexpectedly exposed sandbox virtio disks"
      [[ "$saw_nvme_block" == "true" && "$saw_nvme_partition" == "true" ]] ||
        die "ordinary control pod did not expose the expected NVMe disk contrast"
      ;;
    *)
      die "guest evidence kind is invalid"
      ;;
  esac
}

CURRENT_CHECK="guest-vm-evidence"
ORDINARY_CONTROL_POD="oce-live-ordinary-$$"
jq -n \
  --arg name "$ORDINARY_CONTROL_POD" \
  --arg namespace "$AGW_NAMESPACE" \
  --arg image "$RUNTIME_IMAGE" '
  {
    apiVersion: "v1",
    kind: "Pod",
    metadata: {
      name: $name,
      namespace: $namespace,
      labels: {
        "app.kubernetes.io/managed-by": "openclaw-enterprise-blueprint",
        "openclaw.dev/validation": "ordinary-pod-control"
      }
    },
    spec: {
      automountServiceAccountToken: false,
      enableServiceLinks: false,
      restartPolicy: "Never",
      serviceAccountName: "default",
      containers: [{
        name: "ordinary-control",
        image: $image,
        command: ["sh", "-c", "sleep 3600"],
        env: [{
          name: "OPENCLAW_POD_UID",
          valueFrom: {fieldRef: {apiVersion: "v1", fieldPath: "metadata.uid"}}
        }],
        securityContext: {
          allowPrivilegeEscalation: false,
          privileged: false,
          readOnlyRootFilesystem: true,
          runAsNonRoot: true,
          runAsUser: 1000,
          runAsGroup: 1000,
          seccompProfile: {type: "RuntimeDefault"},
          capabilities: {drop: ["ALL"]}
        }
      }]
    }
  }' >"$WORK_DIR/ordinary-control-manifest.json"
kube -n "$AGW_NAMESPACE" create -f "$WORK_DIR/ordinary-control-manifest.json" -o json \
  >"$WORK_DIR/ordinary-control-created.json"
ORDINARY_CONTROL_POD_UID="$(
  jq -er \
    --arg namespace "$AGW_NAMESPACE" \
    --arg name "$ORDINARY_CONTROL_POD" '
    select(
      .metadata.namespace == $namespace
      and .metadata.name == $name
      and (.metadata.uid | type == "string" and length > 0)
    )
    | .metadata.uid
  ' "$WORK_DIR/ordinary-control-created.json"
)" || die "ordinary control pod creation did not return its UID"
[[ "$ORDINARY_CONTROL_POD_UID" =~ ^[A-Za-z0-9._:-]+$ ]] ||
  die "ordinary control pod UID is invalid"
kube -n "$AGW_NAMESPACE" wait \
  --for=condition=Ready "pod/$ORDINARY_CONTROL_POD" "--timeout=${TIMEOUT_SECONDS}s" >/dev/null
kube -n "$AGW_NAMESPACE" get pod "$ORDINARY_CONTROL_POD" -o json \
  >"$WORK_DIR/ordinary-control-pod.json"
jq -e \
  --arg namespace "$AGW_NAMESPACE" \
  --arg name "$ORDINARY_CONTROL_POD" \
  --arg uid "$ORDINARY_CONTROL_POD_UID" \
  --arg image "$RUNTIME_IMAGE" '
  .metadata.namespace == $namespace
  and .metadata.name == $name
  and .metadata.uid == $uid
  and .metadata.labels["app.kubernetes.io/managed-by"] ==
    "openclaw-enterprise-blueprint"
  and .metadata.labels["openclaw.dev/validation"] == "ordinary-pod-control"
  and (.spec.runtimeClassName == null)
  and (.spec.volumes // [] | length == 0)
  and .spec.automountServiceAccountToken == false
  and .spec.enableServiceLinks == false
  and .spec.restartPolicy == "Never"
  and .spec.serviceAccountName == "default"
  and (.spec.containers | length == 1)
  and .spec.containers[0].name == "ordinary-control"
  and .spec.containers[0].image == $image
  and .spec.containers[0].command == ["sh", "-c", "sleep 3600"]
  and .spec.containers[0].env == [{
    name: "OPENCLAW_POD_UID",
    valueFrom: {fieldRef: {apiVersion: "v1", fieldPath: "metadata.uid"}}
  }]
  and .status.phase == "Running"
  and ((.status.containerStatuses // []) | any(
    .name == "ordinary-control"
    and .ready == true
    and .state.running != null
  ))
' "$WORK_DIR/ordinary-control-pod.json" >/dev/null ||
  die "ordinary control pod did not preserve its non-sandboxed contract"
guest_evidence "$TENANT_A_NAMESPACE" "$TENANT_A_POD" "$TENANT_A_CONTAINER" \
  "$WORK_DIR/tenant-a-guest.txt" "sandbox" "$TENANT_A_POD_UID"
guest_evidence "$TENANT_B_NAMESPACE" "$TENANT_B_POD" "$TENANT_B_CONTAINER" \
  "$WORK_DIR/tenant-b-guest.txt" "sandbox" "$TENANT_B_POD_UID"
guest_evidence "$AGW_NAMESPACE" "$ORDINARY_CONTROL_POD" "ordinary-control" \
  "$WORK_DIR/ordinary-control-guest.txt" "ordinary"
GUEST_BOOT_IDS=(
  "$(sed -n '2p' "$WORK_DIR/tenant-a-guest.txt")"
  "$(sed -n '2p' "$WORK_DIR/tenant-b-guest.txt")"
  "$(sed -n '2p' "$WORK_DIR/ordinary-control-guest.txt")"
)
[[ ${#GUEST_BOOT_IDS[@]} -eq 3 ]] ||
  die "guest comparison did not return three boot IDs"
[[ "$(printf '%s\n' "${GUEST_BOOT_IDS[@]}" | sort -u | wc -l | tr -d ' ')" == "3" ]] ||
  die "sandboxed tenants and the ordinary pod did not report three distinct boot IDs"
{
  printf 'EVIDENCE\tguest-a-kernel\t%s %s\n' \
    "$(sed -n '3p' "$WORK_DIR/tenant-a-guest.txt")" \
    "$(sed -n '4p' "$WORK_DIR/tenant-a-guest.txt")"
  printf 'EVIDENCE\tguest-a-root\t%s\n' "$(sed -n '5p' "$WORK_DIR/tenant-a-guest.txt")"
  printf 'EVIDENCE\tguest-a-block-devices\t%s\n' \
    "$(sed -n 's/^BLOCK://p' "$WORK_DIR/tenant-a-guest.txt" | tr '\n' ',' | sed 's/,$//')"
  printf 'EVIDENCE\tguest-b-kernel\t%s %s\n' \
    "$(sed -n '3p' "$WORK_DIR/tenant-b-guest.txt")" \
    "$(sed -n '4p' "$WORK_DIR/tenant-b-guest.txt")"
  printf 'EVIDENCE\tguest-b-root\t%s\n' "$(sed -n '5p' "$WORK_DIR/tenant-b-guest.txt")"
  printf 'EVIDENCE\tguest-b-block-devices\t%s\n' \
    "$(sed -n 's/^BLOCK://p' "$WORK_DIR/tenant-b-guest.txt" | tr '\n' ',' | sed 's/,$//')"
  printf 'EVIDENCE\tordinary-control-kernel\t%s %s\n' \
    "$(sed -n '3p' "$WORK_DIR/ordinary-control-guest.txt")" \
    "$(sed -n '4p' "$WORK_DIR/ordinary-control-guest.txt")"
  printf 'EVIDENCE\tordinary-control-root\t%s\n' \
    "$(sed -n '5p' "$WORK_DIR/ordinary-control-guest.txt")"
  printf 'EVIDENCE\tordinary-control-block-devices\t%s\n' \
    "$(sed -n 's/^BLOCK://p' "$WORK_DIR/ordinary-control-guest.txt" | tr '\n' ',' | sed 's/,$//')"
} >>"$EVIDENCE_FILE"
record_pass "guest-vm-boundary" \
  "sandbox guests exposed virtio disks, the ordinary pod exposed NVMe, and all three boot IDs differed"

CURRENT_CHECK="tenant-imds-unreachable"
probe_tenant_imds "tenant-a" "$TENANT_A_NAMESPACE" "$TENANT_A_POD" "$TENANT_A_CONTAINER" \
  "$TENANT_A_POD_UID" "$WORK_DIR/imds-tenant-a.json"
probe_tenant_imds "tenant-b" "$TENANT_B_NAMESPACE" "$TENANT_B_POD" "$TENANT_B_CONTAINER" \
  "$TENANT_B_POD_UID" "$WORK_DIR/imds-tenant-b.json"
record_pass "tenant-imds-unreachable" \
  "neither tenant runtime could open a TCP connection to 169.254.169.254:80"

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
  local index pod_index uid container digest pod_file
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
  pod_index=0
  while IFS= read -r pod_json; do
    pod_index=$((pod_index + 1))
    pod_file="$WORK_DIR/${evidence_alias}-pod-${pod_index}.json"
    printf '%s\n' "$pod_json" >"$pod_file"
    verify_pod_ecr_image_revisions "${evidence_alias}-${pod_index}" "$pod_file"
  done < <(jq -c '.items[]' "$pod_list_file")
}

capture_pod_list_evidence "agentgateway" "$WORK_DIR/agentgateway-pods.json"
kube -n "$OCE_SYSTEM_NAMESPACE" get pods -o json >"$WORK_DIR/oce-system-pods.json"
capture_pod_list_evidence "oce-system" "$WORK_DIR/oce-system-pods.json"
record_pass "agentgateway-health" "deployment readiness probe and pod readiness passed"
record_pass "control-plane-evidence" "AgentGateway and OCE workload UIDs and image digests captured"

verify_agentgateway_key_contract() {
  local namespace="$1"
  local pod="$2"
  local container="$3"
  local expected_uid="$4"
  local output_file="$5"
  # shellcheck disable=SC2016 # This JavaScript reads credentials only inside the guest.
  exec_in_exact_pod "$namespace" "$pod" "$container" "$expected_uid" node -e '
    const crypto = require("node:crypto");
    const fs = require("node:fs");
    const https = require("node:https");
    const key = process.env.OPENAI_API_KEY || "";
    if (!key) process.exit(70);
    const ca = fs.readFileSync("/etc/agentgateway-ca/ca.crt");

    function request(token, prompt) {
      const body = JSON.stringify({
        model: "nova-lite",
        input: prompt
      });
      const headers = {
        "content-type": "application/json",
        "content-length": Buffer.byteLength(body)
      };
      if (token !== null) headers.authorization = `Bearer ${token}`;
      return new Promise((resolve, reject) => {
        const operation = https.request({
          hostname: "agentgateway.openclaw-enterprise-agw.svc.cluster.local",
          port: 443,
          path: "/v1/responses",
          method: "POST",
          ca,
          rejectUnauthorized: true,
          headers
        }, response => {
          let responseBody = "";
          response.setEncoding("utf8");
          response.on("data", chunk => {
            responseBody += chunk;
            if (responseBody.length > 1048576) {
              operation.destroy(new Error("response too large"));
            }
          });
          response.on("end", () => resolve({
            status: response.statusCode,
            body: responseBody
          }));
        });
        operation.setTimeout(180000, () => operation.destroy(new Error("timeout")));
        operation.on("error", reject);
        operation.end(body);
      });
    }

    const outputText = response => {
      if (typeof response?.output_text === "string") return response.output_text;
      if (!Array.isArray(response?.output)) return "";
      return response.output.flatMap(item =>
        Array.isArray(item?.content) ? item.content : []
      ).filter(item =>
        item?.type === "output_text" && typeof item.text === "string"
      ).map(item => item.text).join("");
    };
    const normalize = value => value.normalize("NFKC").trim();

    (async () => {
      const challenge = () => {
        const nonce = crypto.randomBytes(12).toString("hex");
        const left = crypto.randomInt(100, 500);
        const right = crypto.randomInt(100, 500);
        return {
          expected: `${nonce}:${left + right}`,
          prompt: `The verification nonce is ${nonce}. Calculate ${left} + ${right}. Reply in exactly this form: ${nonce}:<answer>. Do not add explanation or formatting.`
        };
      };
      const initial = challenge();
      const prompt = initial.prompt;
      const noKey = await request(null, prompt);
      const wrongKey = await request(
        `wrong-${crypto.randomBytes(24).toString("hex")}`,
        prompt
      );
      if (![401, 403].includes(noKey.status)) process.exit(71);
      if (![401, 403].includes(wrongKey.status)) process.exit(72);
      let accepted;
      for (let attempt = 1; attempt <= 3; attempt++) {
        const probe = attempt === 1 ? initial : challenge();
        accepted = await request(key, probe.prompt);
        if (accepted.status !== 200) {
          process.stderr.write(`Responses request with tenant key returned HTTP ${accepted.status}\n`);
          process.exit(74);
        }
        let parsed;
        try { parsed = JSON.parse(accepted.body); } catch { process.exit(73); }
        if (normalize(outputText(parsed)) === probe.expected) break;
        if (attempt === 3) {
          process.stderr.write("Responses model challenge mismatched after 3 attempts\n");
          process.exit(74);
        }
        process.stderr.write(`Responses model challenge retry ${attempt + 1}/3\n`);
      }
      process.stdout.write(JSON.stringify({
        marker: "LIVE_AGENTGATEWAY_KEY_CONTRACT",
        noKeyStatus: noKey.status,
        wrongKeyStatus: wrongKey.status,
        acceptedStatus: accepted.status,
        challengeMatch: true
      }));
    })().catch(() => process.exit(75));
  ' >"$output_file"
  jq -e '
    .marker == "LIVE_AGENTGATEWAY_KEY_CONTRACT"
    and (.noKeyStatus == 401 or .noKeyStatus == 403)
    and (.wrongKeyStatus == 401 or .wrongKeyStatus == 403)
    and .acceptedStatus == 200
    and .challengeMatch == true
  ' "$output_file" >/dev/null ||
    die "AgentGateway key authorization did not deny both invalid cases and accept the tenant key"
}

CURRENT_CHECK="agentgateway-key-authorization"
verify_agentgateway_key_contract \
  "$TENANT_A_NAMESPACE" "$TENANT_A_POD" "$TENANT_A_CONTAINER" "$TENANT_A_POD_UID" \
  "$WORK_DIR/agentgateway-key-tenant-a.json"
verify_agentgateway_key_contract \
  "$TENANT_B_NAMESPACE" "$TENANT_B_POD" "$TENANT_B_CONTAINER" "$TENANT_B_POD_UID" \
  "$WORK_DIR/agentgateway-key-tenant-b.json"
record_pass "agentgateway-key-authorization" \
  "missing and incorrect keys were denied; each tenant key completed one Responses API turn"

gateway_http_port() {
  local namespace="$1" pod="$2" container="$3" expected_uid="$4" pod_file
  if [[ "$namespace" == "$TENANT_A_NAMESPACE" && "$pod" == "$TENANT_A_POD" ]]; then
    pod_file="$WORK_DIR/tenant-a-pod.json"
  elif [[ "$namespace" == "$TENANT_B_NAMESPACE" && "$pod" == "$TENANT_B_POD" ]]; then
    pod_file="$WORK_DIR/tenant-b-pod.json"
  elif [[ "$namespace" == "$TENANT_A_NAMESPACE" \
    && -n "${REPLACEMENT_POD:-}" && "$pod" == "$REPLACEMENT_POD" ]]; then
    pod_file="$WORK_DIR/replacement-pod.json"
  else
    die "gateway port lookup is outside the verified tenant runtimes"
  fi
  jq -er --arg namespace "$namespace" --arg pod "$pod" \
    --arg container "$container" --arg uid "$expected_uid" '
    if .metadata.namespace == $namespace and .metadata.name == $pod
      and .metadata.uid == $uid then
      [.spec.containers[] | select(.name == $container)
        | .ports[]? | select(.name == "http") | .containerPort]
      | if length == 1 and (.[0] | type == "number") then
          .[0] | if . >= 1 and . <= 65535 and floor == . then .
            else error("invalid gateway port") end
        else error("expected one gateway HTTP port") end
    else error("gateway pod identity differs") end
  ' "$pod_file" || die "could not resolve the verified runtime HTTP port"
}

call_native_openclaw_model() {
  local namespace="$1"
  local pod="$2"
  local container="$3"
  local expected_uid="$4"
  local output_file="$5"
  local gateway_port
  gateway_port="$(gateway_http_port "$namespace" "$pod" "$container" "$expected_uid")"
  # shellcheck disable=SC2016 # This JavaScript reads the guest environment.
  exec_in_exact_pod "$namespace" "$pod" "$container" "$expected_uid" \
    env "OCE_TEST_GATEWAY_PORT=$gateway_port" \
      "OCE_NATIVE_TIMELINE_READER_B64=$NATIVE_TIMELINE_READER_B64" node -e '
    const crypto = require("node:crypto");
    const http = require("node:http");
    const { spawnSync } = require("node:child_process");
    const password = process.env.OPENCLAW_GATEWAY_PASSWORD || "";
    if (!password) process.exit(49);
    const rawPort = process.env.OCE_TEST_GATEWAY_PORT || "";
    const port = Number(rawPort);
    if (!/^[1-9][0-9]{0,4}$/.test(rawPort) || port > 65535) process.exit(48);
    const reader = Buffer.from(process.env.OCE_NATIVE_TIMELINE_READER_B64 || "", "base64").toString("utf8");
    if (!reader) process.exit(54);
    const timeline = (mode, cursor = "", runId = "") => {
      const result = spawnSync(process.execPath, ["-e", reader, mode, cursor, runId], {
        encoding: "utf8", timeout: 10000, maxBuffer: 1048576
      });
      if (result.error) process.exit(54);
      if (result.status !== 0) return { status: result.status };
      try { return { status: 0, value: JSON.parse(result.stdout) }; }
      catch { process.exit(54); }
    };

    function request(payload, authenticated) {
      const body = JSON.stringify(payload);
      const headers = {
        "content-type": "application/json",
        "content-length": Buffer.byteLength(body)
      };
      if (authenticated) headers.authorization = `Bearer ${password}`;
      return new Promise((resolve, reject) => {
        const operation = http.request({
          hostname: "127.0.0.1",
          port,
          path: "/v1/chat/completions",
          method: "POST",
          headers
        }, response => {
          let responseBody = "";
          response.setEncoding("utf8");
          response.on("data", chunk => {
            responseBody += chunk;
            if (responseBody.length > 1048576) {
              operation.destroy(new Error("response too large"));
            }
          });
          response.on("end", () => resolve({
            status: response.statusCode,
            body: responseBody
          }));
        });
        operation.setTimeout(180000, () => operation.destroy(new Error("timeout")));
        operation.on("error", reject);
        operation.end(body);
      });
    }

    (async () => {
      const checkpoint = timeline("mark");
      if (checkpoint.status !== 0) process.exit(54);
      const denied = await request({
        model: "openclaw/default",
        messages: []
      }, false);
      if (![401, 403].includes(denied.status)) process.exit(50);

      let parsed;
      let challengeMatch = false;
      for (let attempt = 0; attempt < 3; attempt++) {
        const nonce = crypto.randomBytes(12).toString("hex");
        const left = crypto.randomInt(100, 500);
        const right = crypto.randomInt(100, 500);
        const expected = `${nonce}:${left + right}`;
        const response = await request({
          model: "openclaw/default",
          stream: false,
          messages: [{
            role: "user",
            content: `The verification nonce is ${nonce}. Calculate ${left} + ${right}. Reply in exactly this form: ${nonce}:<answer>.`
          }]
        }, true);
        if (response.status !== 200) process.exit(52);
        try { parsed = JSON.parse(response.body); } catch { process.exit(51); }
        const text = parsed?.choices?.[0]?.message?.content;
        if (typeof text !== "string") process.exit(52);
        if (text.normalize("NFKC").trim() === expected) {
          challengeMatch = true;
          break;
        }
      }
      if (!challengeMatch) process.exit(52);
      let mapping;
      for (let attempt = 0; attempt < 50; attempt++) {
        mapping = timeline("read", JSON.stringify(checkpoint.value), parsed.id);
        if (mapping.status === 0) break;
        if (mapping.status !== 2) process.exit(54);
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      if (mapping.status !== 0) process.exit(54);
      const traceId = mapping.value.traceId;
      process.stdout.write(JSON.stringify({
        status: 200,
        unauthenticatedStatus: denied.status,
        model: parsed.model,
        requestId: parsed.id,
        traceId,
        challengeMatch: true
      }));
    })().catch(() => process.exit(53));
  ' >"$output_file"
  jq -e --arg model "$NATIVE_MODEL_ID" '
    .status == 200
    and (.unauthenticatedStatus == 401 or .unauthenticatedStatus == 403)
    and .model == $model
    and (.requestId | type == "string" and test("^chatcmpl_[A-Za-z0-9_-]{8,}$"))
    and (.traceId | type == "string" and test("^[0-9a-f]{32}$"))
    and .challengeMatch == true
  ' "$output_file" >/dev/null ||
    die "native OpenClaw gateway authentication or model response did not match the contract"
}

# This topology has no private gateway routing, so the OCE API Pod has no route to an Agent gateway (README
# Step 8, "How the native tool turn runs without gateway routing"). The tool turn runs inside the exact tenant A
# runtime Pod, with the same UID checks as the model turn, against that Pod's own gateway on loopback. It runs
# the image's own native OpenClaw CLI, `openclaw gateway call`, with --expect-url bound to 127.0.0.1 and the
# HTTP port that the exact Pod declares; there is no download and no other client. The CLI reads the configured
# gateway authentication inside the guest, so no credential reaches argv or output.
verify_native_tool_execution() {
  local output_file="$1"
  local gateway_port
  gateway_port="$(gateway_http_port "$TENANT_A_NAMESPACE" "$TENANT_A_POD" \
    "$TENANT_A_CONTAINER" "$TENANT_A_POD_UID")"
  # shellcheck disable=SC2016 # Native CLI reads authentication inside the guest.
  exec_in_exact_pod "$TENANT_A_NAMESPACE" "$TENANT_A_POD" \
    "$TENANT_A_CONTAINER" "$TENANT_A_POD_UID" \
    env \
      "OCE_TEST_GATEWAY_PORT=$gateway_port" \
      "OCE_NATIVE_HISTORY_EVALUATOR_B64=$NATIVE_HISTORY_EVALUATOR_B64" \
    node --input-type=module -e '
      import { spawnSync } from "node:child_process";
      import { randomBytes, randomUUID, createHash } from "node:crypto";

      const { evaluateNativeToolHistory } = await import(
        `data:text/javascript;base64,${
          process.env.OCE_NATIVE_HISTORY_EVALUATOR_B64 || ""
        }`
      );
      const rawPort = process.env.OCE_TEST_GATEWAY_PORT || "";
      const port = Number(rawPort);
      if (!/^[1-9][0-9]{0,4}$/.test(rawPort) || port > 65535) process.exit(80);
      const call = async (method, params) => {
        const result = spawnSync("openclaw", [
          "gateway", "call", method, "--json",
          "--expect-url", `ws://127.0.0.1:${port}`,
          "--timeout", "30000", "--params", JSON.stringify(params)
        ], { encoding: "utf8", timeout: 45000, maxBuffer: 1048576 });
        if (result.error || result.status !== 0) {
          throw new Error("native gateway CLI request failed");
        }
        return JSON.parse(result.stdout);
      };

      const nonce = randomBytes(12).toString("hex");
      const toolMarker = `TOOL_${nonce}`;
      const finalMarker = `DONE_${nonce}`;
      const exactCommand = `printf ${toolMarker}`;
      const prompt = [
        "Use the exec tool exactly once.",
        `Run exactly this command: ${exactCommand}`,
        `After it succeeds, reply with exactly ${finalMarker} and no other text.`
      ].join(" ");
      const sessionKey = `agent:main:api-tool-check-${randomUUID()}`;
      {
        const sent = await call("chat.send", {
          sessionKey,
          idempotencyKey: randomUUID(),
          message: prompt
        });
        if (typeof sent?.runId !== "string" || sent.runId.length === 0) {
          process.exit(82);
        }
        const waitDeadline = Date.now() + 600000;
        let outcome;
        while (true) {
          outcome = await call("agent.wait", {
            runId: sent.runId,
            timeoutMs: 3000
          });
          if (outcome?.runId !== sent.runId) process.exit(83);
          if (outcome.status === "ok") break;
          if (
            outcome.status === "error"
            || outcome.endedAt != null
            || outcome.stopReason != null
            || !["pending", "timeout"].includes(outcome.status)
            || Date.now() >= waitDeadline
          ) {
            process.exit(84);
          }
        }

        const historyDeadline = Date.now() + 30000;
        let evidence;
        while (!evidence && Date.now() < historyDeadline) {
          evidence = evaluateNativeToolHistory({
            history: await call("chat.history", { sessionKey, limit: 200 }),
            nonce,
            runId: sent.runId,
            exactCommand,
            toolMarker,
            finalMarker
          });
          if (!evidence) {
            await new Promise(resolve => setTimeout(resolve, 1000));
          }
        }
        if (!evidence) process.exit(85);
        process.stdout.write(JSON.stringify({
          marker: "LIVE_NATIVE_TOOL_EXECUTION",
          outcome: "ok",
          toolCallCount: evidence.toolCallCount,
          execResultCount: evidence.execResultCount,
          finalReplyCount: evidence.finalReplyCount,
          exactCommand: true,
          resultMarker: true,
          finalReply: true,
          runIdHash: createHash("sha256")
            .update(String(sent.runId))
            .digest("hex")
        }));
      }
    ' >"$output_file"
  jq -e '
    .marker == "LIVE_NATIVE_TOOL_EXECUTION"
    and .outcome == "ok"
    and .toolCallCount == 1
    and .execResultCount >= 1
    and .finalReplyCount == 1
    and .exactCommand == true
    and .resultMarker == true
    and .finalReply == true
    and (.runIdHash | type == "string" and test("^[0-9a-f]{64}$"))
  ' "$output_file" >/dev/null ||
    die "native OCE session did not prove successful exec tool evidence and an exact final reply"
  printf 'EVIDENCE\tnative-tool-run-id-sha256\t%s\n' \
    "$(jq -er '.runIdHash' "$output_file")" >>"$EVIDENCE_FILE"
}

capture_agentgateway_model_evidence() {
  local native_output="$1"
  local evidence_alias="$2"
  local started_at="$3"
  local trace_id native_request_id pod_name
  local -a pod_names=()
  local log_file="$WORK_DIR/agentgateway-${evidence_alias}.log"
  local telemetry_file="$WORK_DIR/agentgateway-${evidence_alias}.json"

  [[ "$evidence_alias" =~ ^[a-z0-9-]+$ ]] ||
    die "AgentGateway telemetry evidence alias is invalid"
  trace_id="$(jq -er '.traceId' "$native_output")"
  native_request_id="$(jq -er '.requestId' "$native_output")"
  mapfile -t pod_names < <(
    jq -er '.items[].metadata.name' "$WORK_DIR/agentgateway-pods.json"
  )
  ((${#pod_names[@]} > 0)) || die "no AgentGateway pods were available for telemetry"
  : >"$log_file"
  for pod_name in "${pod_names[@]}"; do
    [[ "$pod_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
      die "AgentGateway pod name is invalid"
    kube -n "$AGW_NAMESPACE" logs "$pod_name" -c agentgateway \
      --since-time="$started_at" >>"$log_file" 2>/dev/null ||
      die "could not read AgentGateway telemetry"
  done

  # shellcheck disable=SC2016 # This JavaScript contains regex metacharacters.
  if ! env "OCE_TELEMETRY_EVALUATOR_B64=$AGENTGATEWAY_TELEMETRY_EVALUATOR_B64" \
    node --input-type=module -e '
    import fs from "node:fs";
    const { evaluateAgentGatewayTelemetry } = await import(
      `data:text/javascript;base64,${process.env.OCE_TELEMETRY_EVALUATOR_B64}`
    );
    const [logFile, traceId, gatewayModel, bedrockModel] = process.argv.slice(1);
    process.stdout.write(JSON.stringify(evaluateAgentGatewayTelemetry({
      lines: fs.readFileSync(logFile, "utf8"), traceId, gatewayModel, bedrockModel
    })));
  ' "$log_file" "$trace_id" "$AGW_MODEL_ID" "$BEDROCK_MODEL_ID" >"$telemetry_file"; then
    die "native OpenClaw run trace did not match successful AgentGateway Bedrock spans"
  fi

  jq -e \
    --arg trace_id "$trace_id" \
    --arg gateway_model "$AGW_MODEL_ID" \
    --arg bedrock_model "$BEDROCK_MODEL_ID" '
      .traceId == $trace_id
    and .provider == "aws.bedrock"
    and (.spanIds | type == "array" and length > 0)
    and all(.spanIds[]; type == "string" and test("^[0-9a-f]{16}$"))
    and .invocationCount == (.spanIds | length)
      and .gatewayModel == $gateway_model
      and .bedrockModel == $bedrock_model
    ' "$telemetry_file" >/dev/null ||
    die "AgentGateway telemetry fields did not match the Bedrock model contract"

  printf \
    'EVIDENCE\tnative-model-correlation-%s\ttrace-id-sha256=%s native-request-id-sha256=%s gateway-span-ids-sha256=%s native-model=%s gateway-model=%s bedrock-model=%s\n' \
    "$evidence_alias" \
    "$(sha256_text "$trace_id")" \
    "$(sha256_text "$native_request_id")" \
    "$(sha256_text "$(jq -cer '.spanIds' "$telemetry_file")")" \
    "$NATIVE_MODEL_ID" "$AGW_MODEL_ID" "$BEDROCK_MODEL_ID" >>"$EVIDENCE_FILE"
}

CURRENT_CHECK="native-openclaw-model-turn"
MODEL_STARTED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
call_native_openclaw_model "$TENANT_A_NAMESPACE" "$TENANT_A_POD" "$TENANT_A_CONTAINER" \
  "$TENANT_A_POD_UID" "$WORK_DIR/model-response-a.json"
CURRENT_CHECK="agentgateway-model-telemetry"
capture_agentgateway_model_evidence \
  "$WORK_DIR/model-response-a.json" "tenant-a" "$MODEL_STARTED_AT"
CURRENT_CHECK="native-openclaw-model-turn"
MODEL_STARTED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
call_native_openclaw_model "$TENANT_B_NAMESPACE" "$TENANT_B_POD" "$TENANT_B_CONTAINER" \
  "$TENANT_B_POD_UID" "$WORK_DIR/model-response-b.json"
CURRENT_CHECK="agentgateway-model-telemetry"
capture_agentgateway_model_evidence \
  "$WORK_DIR/model-response-b.json" "tenant-b" "$MODEL_STARTED_AT"
record_pass "native-openclaw-model-turn" \
  "both native OpenClaw gateways rejected anonymous access and answered their random arithmetic challenge"
record_pass "agentgateway-model-telemetry" \
  "both native run IDs joined through their diagnostic timeline to successful AgentGateway Bedrock spans"
CURRENT_CHECK="native-openclaw-tool-execution"
verify_native_tool_execution "$WORK_DIR/native-tool-execution.json"
record_pass "native-openclaw-tool-execution" \
  "one native OCE session recorded one successful exec tool call and its exact result"

# OCE trusts every pod address as a gateway proxy source, so only its tenant NetworkPolicies, which admit no
# gateway client in this topology, keep other pods from presenting the trusted identity header. The ordinary
# control pod is such a peer; it must not get a gateway answer other than 401 or 403.
probe_forged_gateway_identity() {
  local tenant_alias="$1"
  local pod_json="$2"
  local output_file="$3"
  local gateway_ip
  gateway_ip="$(
    jq -er '
      .status.podIP
      | select(type == "string" and test("^[0-9]{1,3}([.][0-9]{1,3}){3}$"))
    ' "$pod_json"
  )" || die "$tenant_alias gateway pod has no IPv4 pod address"
  # Port 8080 is the gateway port install-oce.sh renders for OCE (gatewayPort). The exact-pod exec
  # refuses a same-name replacement of the ordinary control pod, before the exec and inside it.
  # shellcheck disable=SC2016 # This JavaScript runs in the ordinary control pod.
  exec_runtime_command "$AGW_NAMESPACE" "$ORDINARY_CONTROL_POD" "ordinary-control" \
    "$ORDINARY_CONTROL_POD_UID" \
    node -e '
      const http = require("node:http");
      const [host, port] = process.argv.slice(1);
      if (!/^[0-9]{1,3}([.][0-9]{1,3}){3}$/.test(host || "") || port !== "8080") {
        process.exit(64);
      }
      const marker = "LIVE_PEER_FORGED_IDENTITY";
      let done = false;
      const finish = (result) => {
        if (done) return;
        done = true;
        process.stdout.write(JSON.stringify({ marker, ...result }) + "\n");
        process.exit(0);
      };
      const request = http.request({
        host,
        port: Number(port),
        path: "/v1/models",
        method: "GET",
        headers: {
          "x-occ-identity": "occ-workspace-files",
          "x-forwarded-for": "203.0.113.7"
        }
      }, response => {
        response.resume();
        finish({ result: "status", status: response.statusCode });
      });
      request.setTimeout(5000, () => {
        request.destroy();
        finish({ result: "timeout" });
      });
      request.on("error", error => finish({ result: "error", code: String(error.code || "unknown") }));
      request.end();
      setTimeout(() => finish({ result: "timeout" }), 8000).unref();
    ' "$gateway_ip" 8080 >"$output_file" ||
    die "forged identity probe for $tenant_alias did not run"
  jq -e '
    .marker == "LIVE_PEER_FORGED_IDENTITY"
    and (
      .result == "timeout"
      or .result == "error"
      or (.result == "status" and (.status == 401 or .status == 403))
    )
  ' "$output_file" >/dev/null ||
    die "a non-proxy peer Pod reached the $tenant_alias gateway with a forged x-occ-identity header"
}

CURRENT_CHECK="tenant-gateway-peer-forged-identity"
probe_forged_gateway_identity "tenant-a" "$WORK_DIR/tenant-a-pod.json" \
  "$WORK_DIR/forged-identity-tenant-a.json"
probe_forged_gateway_identity "tenant-b" "$WORK_DIR/tenant-b-pod.json" \
  "$WORK_DIR/forged-identity-tenant-b.json"
record_pass "tenant-gateway-peer-forged-identity" \
  "a pod outside the gateway client selector could not use a forged x-occ-identity header on either tenant gateway"

CURRENT_CHECK="oce-api-loopback-tunnel"
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
stop_oce_api_port_forward || die "OCE API tunnel child could not be terminated and reaped"
[[ "$OCE_PORT_FORWARD_CLEANED" == "true" ]] ||
  die "OCE API tunnel child was not reaped"
record_pass "oce-api-loopback-tunnel" \
  "OCE API used a temporary, network-restricted relay and a local-only port-forward; both were removed"
record_pass "oce-same-tenant-api" "both tenants received HTTP 200 for their own agent"
record_pass "oce-cross-tenant-api" "both reciprocal requests returned HTTP 403 FORBIDDEN"

CURRENT_CHECK="shared-database-boundary"
SHARED_POSTGRESQL_BOUNDARY="$(
  kube -n "$OCE_SYSTEM_NAMESPACE" exec \
    deployment/oce-validation-only-postgres -- \
    psql -U oce_validation -d openclaw -v ON_ERROR_STOP=1 -Atc "
SELECT json_build_object(
  'appRoleRestricted',
  COALESCE((
    SELECT NOT rolsuper
      AND NOT rolcreatedb
      AND NOT rolcreaterole
      AND NOT rolbypassrls
      AND NOT has_database_privilege('occ_app', current_database(), 'CREATE')
      AND NOT has_schema_privilege('occ_app', 'public', 'CREATE')
    FROM pg_roles
    WHERE rolname = 'occ_app'
  ), false),
  'applicationTableCount',
  (
    SELECT count(*)
    FROM pg_class AS relation
    JOIN pg_namespace AS namespace
      ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname IN ('occ', 'drizzle')
      AND relation.relkind IN ('r', 'p')
  ),
  'rlsEnabledTableCount',
  (
    SELECT count(*)
    FROM pg_class AS relation
    JOIN pg_namespace AS namespace
      ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname IN ('occ', 'drizzle')
      AND relation.relkind IN ('r', 'p')
      AND relation.relrowsecurity
  )
)::text;"
)" || die "could not inspect shared PostgreSQL isolation controls"
jq -e '
  type == "object"
  and .appRoleRestricted == true
  and (.applicationTableCount | type == "number" and . > 0)
  and (.rlsEnabledTableCount | type == "number" and . >= 0)
' <<<"$SHARED_POSTGRESQL_BOUNDARY" >/dev/null ||
  die "shared PostgreSQL isolation evidence did not match the expected schema"
[[ "$(jq -r '.rlsEnabledTableCount' <<<"$SHARED_POSTGRESQL_BOUNDARY")" == "0" ]] ||
  die "shared PostgreSQL row-level security contract changed; reassess the tenant-boundary claim"
{
  printf 'EVIDENCE\tshared-postgresql-boundary\tapp-role-restricted=true application-table-count=%s rls-enabled-table-count=0\n' \
    "$(jq -r '.applicationTableCount' <<<"$SHARED_POSTGRESQL_BOUNDARY")"
  printf 'LIMITATION\tdatabase-isolation-not-proven\tOCE application schemas occ and drizzle have no row-level security; reciprocal HTTP 403 responses prove application-layer authorization, not a database-enforced tenant boundary\n'
} >>"$EVIDENCE_FILE"
record_pass "shared-database-application-boundary" \
  "shared PostgreSQL uses a restricted application role; reciprocal tenant API denials were also verified"

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
kube -n "$TENANT_A_NAMESPACE" get pod "$TENANT_A_POD" -o json \
  >"$WORK_DIR/ephemeral-debug-current-pod.json"
jq -e --arg uid "$TENANT_A_POD_UID" '
  .metadata.uid == $uid
  and .metadata.deletionTimestamp == null
  and all(.spec.ephemeralContainers[]?; .name != "live-validation-debug")
' "$WORK_DIR/ephemeral-debug-current-pod.json" >/dev/null ||
  die "ephemeral debug target identity changed or test container already exists"
jq --arg image "$RUNTIME_IMAGE" --arg target "$TENANT_A_CONTAINER" '
  del(.status, .metadata.managedFields)
  | .spec.ephemeralContainers = ((.spec.ephemeralContainers // []) + [{
      name: "live-validation-debug",
      image: $image,
      imagePullPolicy: "IfNotPresent",
      targetContainerName: $target,
      command: ["sh", "-c", "true"],
      securityContext: {
        runAsNonRoot: true,
        runAsUser: 1000,
        runAsGroup: 1000,
        allowPrivilegeEscalation: false,
        readOnlyRootFilesystem: true,
        capabilities: {drop: ["ALL"]},
        seccompProfile: {type: "RuntimeDefault"}
      }
    }])
' "$WORK_DIR/ephemeral-debug-current-pod.json" >"$WORK_DIR/ephemeral-debug-update.json"
# kubectl debug has no server dry-run flag. Exercise the real subresource
# admission path without persisting an ephemeral container.
expect_server_denial "ephemeral-debug" "$EPHEMERAL_DENIAL" \
  kube replace --raw \
  "/api/v1/namespaces/$TENANT_A_NAMESPACE/pods/$TENANT_A_POD/ephemeralcontainers?dryRun=All" \
  -f "$WORK_DIR/ephemeral-debug-update.json"

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

exec_in_exact_pod \
  "$TENANT_A_NAMESPACE" "$TENANT_A_POD" "$TENANT_A_CONTAINER" "$TENANT_A_POD_UID" \
  sh -eu -c \
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
  REPLACEMENT_POD_CANDIDATE="$(
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
  [[ -n "$REPLACEMENT_POD_CANDIDATE" ]] && break
  sleep 2
done
[[ -n "$REPLACEMENT_POD_CANDIDATE" ]] ||
  die "controller did not create a ready replacement pod before timeout"
kube -n "$TENANT_A_NAMESPACE" rollout status "deployment/$ORIGINAL_DEPLOYMENT" \
  "--timeout=${TIMEOUT_SECONDS}s" >/dev/null

verify_runtime_pod "tenant-a-replacement" "$TENANT_A_NAMESPACE" "$REPLACEMENT_POD_CANDIDATE" \
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
REPLACEMENT_POD="$REPLACEMENT_POD_CANDIDATE"
[[ "$(exec_in_exact_pod \
  "$TENANT_A_NAMESPACE" "$REPLACEMENT_POD" "$TENANT_A_CONTAINER" "$REPLACEMENT_POD_UID" \
  cat "$PERSISTENT_MARKER")" == "persistent-ok" ]] ||
  die "persistent marker did not survive controller-driven replacement"
if exec_in_exact_pod \
  "$TENANT_A_NAMESPACE" "$REPLACEMENT_POD" "$TENANT_A_CONTAINER" "$REPLACEMENT_POD_UID" \
  test -e "$EPHEMERAL_MARKER"; then
  die "ephemeral home marker unexpectedly survived replacement"
fi
MODEL_STARTED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
call_native_openclaw_model \
  "$TENANT_A_NAMESPACE" "$REPLACEMENT_POD" "$TENANT_A_CONTAINER" "$REPLACEMENT_POD_UID" \
  "$WORK_DIR/replacement-model-response.json"
CURRENT_CHECK="agentgateway-model-telemetry"
capture_agentgateway_model_evidence \
  "$WORK_DIR/replacement-model-response.json" "tenant-a-replacement" "$MODEL_STARTED_AT"
CURRENT_CHECK="controller-driven-persistence"
{
  printf 'EVIDENCE\toce-revision-tenant-a-replacement\t%s\n' "$REPLACEMENT_OCE_REVISION"
  printf 'EVIDENCE\tworkload-image-tenant-a-replacement\tuid=%s container=%s digest=%s\n' \
    "$REPLACEMENT_POD_UID" "$TENANT_A_CONTAINER" "$REPLACEMENT_IMAGE_DIGEST"
} >>"$EVIDENCE_FILE"
record_pass "controller-driven-persistence" \
  "persistent state survived replacement; ephemeral state did not; native model turn still passed"

CURRENT_CHECK="temporary-artifact-cleanup"
exec_in_exact_pod \
  "$TENANT_A_NAMESPACE" "$REPLACEMENT_POD" "$TENANT_A_CONTAINER" "$REPLACEMENT_POD_UID" \
  rm -f -- "$PERSISTENT_MARKER" "$EPHEMERAL_MARKER"
if ! exec_in_exact_pod \
  "$TENANT_A_NAMESPACE" "$REPLACEMENT_POD" "$TENANT_A_CONTAINER" "$REPLACEMENT_POD_UID" \
  test ! -e "$PERSISTENT_MARKER" -a ! -e "$EPHEMERAL_MARKER"; then
  die "validation markers could not be removed"
fi
MARKERS_CREATED="false"
cleanup_ordinary_control_pod
[[ "$OCE_PORT_FORWARD_CLEANED" == "true" ]] ||
  die "OCE API tunnel cleanup was not completed"
record_pass "temporary-artifact-cleanup" \
  "API relay, local port-forward, markers, and the ordinary control pod were removed"
printf 'CLEANUP\tPASS\tAPI relay and local port-forward were removed; temporary cluster artifacts were deleted and awaited\n' \
  >>"$EVIDENCE_FILE"

CURRENT_CHECK="evidence-signing"
VALIDATION_ENDED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
EVIDENCE_PREPASS_BACKUP="$WORK_DIR/live-validation-evidence-prepass.txt"
cp -- "$EVIDENCE_FILE" "$EVIDENCE_PREPASS_BACKUP"
assert_evidence_directory_identity
FINAL_EVIDENCE_CANDIDATE="$(mktemp "./.live-validation-evidence.XXXXXX")"
FINAL_MANIFEST_CANDIDATE="$(mktemp "./.live-validation-manifest.XXXXXX")"
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
FINAL_EVIDENCE_IDENTITY="$(private_regular_file_identity "$FINAL_EVIDENCE_CANDIDATE")"
exec {FINAL_EVIDENCE_FD}<"$FINAL_EVIDENCE_CANDIDATE"
FINAL_EVIDENCE_FD_PATH="$(opened_file_path "$FINAL_EVIDENCE_FD")"
assert_open_file_matches_path "$FINAL_EVIDENCE_FD" "$FINAL_EVIDENCE_CANDIDATE" ||
  die "opened evidence does not match the final evidence candidate"
FINAL_EVIDENCE_SHA256="$(sha256_file "$FINAL_EVIDENCE_FD_PATH")"

if [[ -n "$KMS_SIGNING_KEY_ID" ]]; then
  openssl dgst -sha256 -binary "$FINAL_EVIDENCE_FD_PATH" \
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
  [[ "$(sha256_file "$FINAL_EVIDENCE_FD_PATH")" == "$FINAL_EVIDENCE_SHA256" ]] ||
    die "validation evidence content changed during signing"
  assert_private_file_identity "$FINAL_EVIDENCE_CANDIDATE" "$FINAL_EVIDENCE_IDENTITY"
  FINAL_SIGNATURE_CANDIDATE="$(
    mktemp "./.live-validation-signature.XXXXXX"
  )"
  jq -er '.Signature' "$WORK_DIR/kms-signature.json" >"$FINAL_SIGNATURE_CANDIDATE"
  chmod 600 "$FINAL_SIGNATURE_CANDIDATE"
  FINAL_SIGNATURE_IDENTITY="$(private_regular_file_identity "$FINAL_SIGNATURE_CANDIDATE")"
fi

assert_evidence_directory_identity
assert_private_file_identity "$FINAL_EVIDENCE_CANDIDATE" "$FINAL_EVIDENCE_IDENTITY"
write_manifest_to \
  "$FINAL_MANIFEST_CANDIDATE" \
  "$FINAL_EVIDENCE_CANDIDATE" \
  "$FINAL_SIGNATURE_CANDIDATE"
FINAL_MANIFEST_IDENTITY="$(private_regular_file_identity "$FINAL_MANIFEST_CANDIDATE")"
assert_private_file_identity "$FINAL_EVIDENCE_CANDIDATE" "$FINAL_EVIDENCE_IDENTITY"
if [[ -n "$FINAL_SIGNATURE_CANDIDATE" ]]; then
  assert_private_file_identity "$FINAL_SIGNATURE_CANDIDATE" "$FINAL_SIGNATURE_IDENTITY"
fi
assert_evidence_directory_identity
if [[ -n "$FINAL_SIGNATURE_CANDIDATE" ]]; then
  mv -- "$FINAL_SIGNATURE_CANDIDATE" "$SIGNATURE_FILE"
  FINAL_SIGNATURE_CANDIDATE=""
  assert_private_file_identity "$SIGNATURE_FILE" "$FINAL_SIGNATURE_IDENTITY"
fi
mv -- "$FINAL_EVIDENCE_CANDIDATE" "$EVIDENCE_FILE"
FINAL_EVIDENCE_CANDIDATE=""
assert_private_file_identity "$EVIDENCE_FILE" "$FINAL_EVIDENCE_IDENTITY"
exec {FINAL_EVIDENCE_FD}<&-
FINAL_EVIDENCE_FD=""
mv -- "$FINAL_MANIFEST_CANDIDATE" "$MANIFEST_FILE"
FINAL_MANIFEST_CANDIDATE=""
assert_private_file_identity "$MANIFEST_FILE" "$FINAL_MANIFEST_IDENTITY"
assert_evidence_directory_identity

printf 'Validation passed. Sanitized evidence: %s\n' \
  "$EVIDENCE_OUTPUT_DIR/$(basename "$EVIDENCE_FILE")"
printf 'SHA-256 manifest: %s\n' "$EVIDENCE_OUTPUT_DIR/$(basename "$MANIFEST_FILE")"
if [[ -f "$SIGNATURE_FILE" ]]; then
  printf 'KMS signature: %s\n' "$EVIDENCE_OUTPUT_DIR/$(basename "$SIGNATURE_FILE")"
fi
