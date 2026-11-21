#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly STORAGE_CLASS_NAME="openclaw-enterprise-gp3"
readonly OWNER_LABEL_VALUE="openclaw-enterprise-blueprint"

usage() {
  cat >&2 <<'EOF'
Usage:
  setup-storage-class.sh --kube-context CONTEXT [--receipt FILE]

Creates or verifies the sample-owned, non-default encrypted gp3 StorageClass
for EKS Auto Mode. An existing same-name StorageClass must match the complete
storage and ownership contract; this script never patches or adopts it. When
--receipt is supplied, FILE records whether this lifecycle created or reused
the exact StorageClass UID on the selected kube context.
EOF
}

die() {
  echo "setup-storage-class: $*" >&2
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "${value}" && "${value}" != --* ]] ||
    die "${option} requires an explicit value."
}

KUBE_CONTEXT=""
RECEIPT_PATH=""

while (( $# > 0 )); do
  case "$1" in
    --kube-context)
      require_value "$1" "${2:-}"
      KUBE_CONTEXT="$2"
      shift 2
      ;;
    --receipt)
      require_value "$1" "${2:-}"
      RECEIPT_PATH="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

if [[ -z "${KUBE_CONTEXT}" ]]; then
  echo "setup-storage-class: --kube-context is required." >&2
  usage
  exit 2
fi

for command in kubectl jq mktemp; do
  command -v "${command}" >/dev/null 2>&1 ||
    die "${command} is required."
done
if [[ -n "${RECEIPT_PATH}" ]]; then
  for command in python3 stat; do
    command -v "${command}" >/dev/null 2>&1 ||
      die "${command} is required when --receipt is supplied."
  done
  [[ "${RECEIPT_PATH}" = /* ]] ||
    die "--receipt must be an absolute path."
fi

readonly -a BOOTSTRAP_KUBECTL=(kubectl)

receipt_parent=""
receipt_existing=false
receipt_created=false
receipt_uid=""
receipt_endpoint=""
receipt_temp=""
receipt_committed=false
receipt_lock=""
receipt_lock_acquired=false
receipt_lock_owner_token=""
kubeconfig_snapshot_dir=""
kubeconfig_snapshot=""
create_error=""

release_receipt_lock() {
  [[ "${receipt_lock_acquired}" == true && -n "${receipt_lock}" ]] || return 0

  local owner_file="${receipt_lock}/owner"
  if [[ -f "${owner_file}" && ! -L "${owner_file}" ]]; then
    local current_owner
    current_owner="$(<"${owner_file}")"
    if [[ "${current_owner}" != "${receipt_lock_owner_token}" ]]; then
      echo "setup-storage-class: receipt lock ownership changed; preserving ${receipt_lock}." >&2
      return 0
    fi
    rm -f -- "${owner_file}"
  elif [[ -e "${owner_file}" || -L "${owner_file}" ]]; then
    echo "setup-storage-class: receipt lock owner is invalid; preserving ${receipt_lock}." >&2
    return 0
  fi
  rmdir -- "${receipt_lock}" 2>/dev/null || true
  receipt_lock_acquired=false
}

cleanup_local_state() {
  [[ -z "${receipt_temp}" ]] || rm -f -- "${receipt_temp}"
  [[ -z "${create_error}" ]] || rm -f -- "${create_error}"
  [[ -z "${kubeconfig_snapshot}" ]] || rm -f -- "${kubeconfig_snapshot}"
  [[ -z "${kubeconfig_snapshot_dir}" ]] ||
    rmdir -- "${kubeconfig_snapshot_dir}" 2>/dev/null
  release_receipt_lock
}

cleanup_preflight() {
  local exit_code="$?"
  set +e
  cleanup_local_state
  trap - EXIT
  exit "${exit_code}"
}
trap cleanup_preflight EXIT

context_name="$(
  "${BOOTSTRAP_KUBECTL[@]}" config get-contexts \
    "${KUBE_CONTEXT}" \
    --no-headers \
    --output=name
)" || die "could not read kube context ${KUBE_CONTEXT}."
[[ "${context_name}" == "${KUBE_CONTEXT}" ]] ||
  die "kube context ${KUBE_CONTEXT} does not exist exactly."

kubeconfig_snapshot_dir="$(
  mktemp -d "${TMPDIR:-/tmp}/.setup-storage-class-kubeconfig.XXXXXX"
)" || die "could not create a private kubeconfig snapshot directory."
chmod 700 "${kubeconfig_snapshot_dir}" ||
  die "could not secure the kubeconfig snapshot directory."
kubeconfig_snapshot="${kubeconfig_snapshot_dir}/config"
if ! "${BOOTSTRAP_KUBECTL[@]}" config view \
  --raw \
  --minify \
  --flatten \
  --context "${KUBE_CONTEXT}" >"${kubeconfig_snapshot}"; then
  die "could not snapshot kube context ${KUBE_CONTEXT}."
fi
chmod 600 "${kubeconfig_snapshot}" ||
  die "could not secure the kubeconfig snapshot."
[[ -s "${kubeconfig_snapshot}" ]] ||
  die "kube context ${KUBE_CONTEXT} produced an empty kubeconfig snapshot."

readonly -a KUBECTL=(
  kubectl
  --kubeconfig "${kubeconfig_snapshot}"
  --context "${KUBE_CONTEXT}"
)

"${KUBECTL[@]}" get --raw=/readyz >/dev/null ||
  die "could not reach kube context ${KUBE_CONTEXT}."

file_mode() {
  local mode
  if mode="$(stat -c '%a' "$1" 2>/dev/null)" &&
    [[ "${mode}" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "${mode}"
  elif mode="$(stat -f '%Lp' "$1" 2>/dev/null)" &&
    [[ "${mode}" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "${mode}"
  else
    die "could not inspect permissions for $1."
  fi
}

prepare_receipt() {
  [[ -n "${RECEIPT_PATH}" ]] || return 0

  receipt_parent="$(dirname -- "${RECEIPT_PATH}")"
  local canonical_parent
  canonical_parent="$(cd -- "${receipt_parent}" 2>/dev/null && pwd -P)" ||
    die "receipt parent directory does not exist: ${receipt_parent}."
  [[ "${canonical_parent}" == "${receipt_parent}" &&
    -d "${receipt_parent}" && ! -L "${receipt_parent}" &&
    -O "${receipt_parent}" ]] ||
    die "receipt parent must be an owned canonical directory, not a symbolic link."
  local parent_mode
  parent_mode="$(file_mode "${receipt_parent}")"
  (( (8#${parent_mode} & 8#022) == 0 )) ||
    die "receipt parent must not be writable by group or other users."

  receipt_lock="${RECEIPT_PATH}.lock"
  [[ ! -L "${receipt_lock}" ]] ||
    die "receipt lock must not be a symbolic link."
  receipt_lock_owner_token="$(
    python3 -I -c 'import secrets; print(secrets.token_hex(32))'
  )" || die "could not generate receipt lock ownership token."
  if ! mkdir -- "${receipt_lock}" 2>/dev/null; then
    die "receipt is already in use or has a stale lock: ${receipt_lock}."
  fi
  receipt_lock_acquired=true
  chmod 700 "${receipt_lock}" ||
    die "could not secure receipt lock ${receipt_lock}."
  printf '%s\n' "${receipt_lock_owner_token}" >"${receipt_lock}/owner" ||
    die "could not record receipt lock ownership for ${receipt_lock}."
  chmod 600 "${receipt_lock}/owner" ||
    die "could not secure receipt lock ownership for ${receipt_lock}."

  if [[ -L "${RECEIPT_PATH}" ]]; then
    die "--receipt must not be a symbolic link."
  fi
  if [[ -e "${RECEIPT_PATH}" ]]; then
    [[ -f "${RECEIPT_PATH}" && -O "${RECEIPT_PATH}" &&
      -r "${RECEIPT_PATH}" ]] ||
      die "--receipt must be an owned readable regular file."
    case "$(file_mode "${RECEIPT_PATH}")" in
      400|600) ;;
      *) die "--receipt must have mode 0400 or 0600." ;;
    esac

    local parsed
    parsed="$(
      jq -er \
        --arg context "${KUBE_CONTEXT}" \
        --arg name "${STORAGE_CLASS_NAME}" \
        '
          if (
            type == "object"
            and keys == [
              "clusterEndpoint",
              "kubeContext",
              "operation",
              "resource",
              "version"
            ]
            and .version == 1
            and .operation == "setup-storage-class"
            and .kubeContext == $context
            and (.clusterEndpoint | type == "string" and length > 0)
            and (
              .resource | type == "object"
              and keys == ["apiVersion", "created", "kind", "name", "uid"]
              and .apiVersion == "storage.k8s.io/v1"
              and .kind == "StorageClass"
              and .name == $name
              and (.uid | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"))
              and (.created | type == "boolean")
            )
          )
          then [
            .clusterEndpoint,
            .resource.uid,
            (.resource.created | tostring)
          ] | @tsv
          else error("unexpected lifecycle receipt schema or target")
          end
        ' "${RECEIPT_PATH}"
    )" || die "--receipt is invalid or belongs to another target."
    local extra
    IFS=$'\t' read -r receipt_endpoint receipt_uid receipt_created extra \
      <<<"${parsed}"
    : "${receipt_created}"
    [[ -z "${extra:-}" ]] ||
      die "--receipt contains a malformed target identity."
    receipt_existing=true
  fi
}

write_receipt() {
  local endpoint="$1"
  local uid="$2"
  local created="$3"

  [[ -n "${RECEIPT_PATH}" ]] || return 0
  if [[ "${receipt_existing}" == true ]]; then
    receipt_committed=true
    return 0
  fi

  local receipt_basename
  receipt_basename="$(basename -- "${RECEIPT_PATH}")"
  receipt_temp="$(mktemp "${receipt_parent}/.${receipt_basename}.tmp.XXXXXX")" ||
    return 1
  chmod 600 "${receipt_temp}" || return 1
  jq -n \
    --arg context "${KUBE_CONTEXT}" \
    --arg endpoint "${endpoint}" \
    --arg name "${STORAGE_CLASS_NAME}" \
    --arg uid "${uid}" \
    --argjson created "${created}" \
    '{
      version: 1,
      operation: "setup-storage-class",
      kubeContext: $context,
      clusterEndpoint: $endpoint,
      resource: {
        apiVersion: "storage.k8s.io/v1",
        kind: "StorageClass",
        name: $name,
        uid: $uid,
        created: $created
      }
    }' >"${receipt_temp}" || return 1

  python3 -I -c '
import os
import sys

with open(sys.argv[1], "rb") as temporary:
    os.fsync(temporary.fileno())
' "${receipt_temp}" || return 1

  # Link a fully written private inode into place. link(2) fails if any path,
  # including a symlink, appeared at the destination after preflight.
  python3 -I -c '
import os
import sys

source, destination = sys.argv[1:]
os.link(source, destination, follow_symlinks=False)
' "${receipt_temp}" "${RECEIPT_PATH}" || return 1

  # The receipt is externally visible now, so the resource lifecycle is
  # committed even if local cleanup or the durability sync reports an error.
  receipt_committed=true

  python3 -I -c '
import os
import sys

os.unlink(sys.argv[1])
' "${receipt_temp}" ||
    die "lifecycle receipt ${RECEIPT_PATH} is published, but temporary-state cleanup failed; the StorageClass remains committed."
  receipt_temp=""

  python3 -I -c '
import os
import sys

directory = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
' "${receipt_parent}" ||
    die "lifecycle receipt ${RECEIPT_PATH} is published, but its parent directory could not be synced; the StorageClass remains committed."
}
prepare_receipt

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly manifest_path="${script_dir}/../deploy/storage-class.yaml"
[[ -f "${manifest_path}" && ! -L "${manifest_path}" ]] ||
  die "StorageClass manifest is missing or is a symbolic link: ${manifest_path}."

read_storage_class() {
  local ignore_not_found="${1:-false}"
  local -a command=(
    "${KUBECTL[@]}"
    get
    storageclass
    "${STORAGE_CLASS_NAME}"
  )
  if [[ "${ignore_not_found}" == true ]]; then
    command+=(--ignore-not-found)
  fi
  command+=(--output=json)

  local resource
  if ! resource="$("${command[@]}")"; then
    die "could not read StorageClass ${STORAGE_CLASS_NAME}."
  fi
  printf '%s' "${resource}"
}

validate_storage_class() {
  local resource="$1"
  local violations
  if ! violations="$(
    printf '%s\n' "${resource}" |
      jq -r \
      --arg name "${STORAGE_CLASS_NAME}" \
      --arg owner "${OWNER_LABEL_VALUE}" \
      '
        [
          if .apiVersion != "storage.k8s.io/v1"
            then "apiVersion must be storage.k8s.io/v1" else empty end,
          if .kind != "StorageClass"
            then "kind must be StorageClass" else empty end,
          if .metadata.name != $name
            then "metadata.name must be \($name)" else empty end,
          if .metadata.labels["app.kubernetes.io/name"] != $name
            then "app.kubernetes.io/name ownership label does not match" else empty end,
          if .metadata.labels["app.kubernetes.io/component"] != "storage"
            then "app.kubernetes.io/component ownership label must be storage" else empty end,
          if .metadata.labels["app.kubernetes.io/managed-by"] != $owner
            then "app.kubernetes.io/managed-by ownership label does not match" else empty end,
          if .metadata.labels["app.kubernetes.io/part-of"] != $owner
            then "app.kubernetes.io/part-of ownership label does not match" else empty end,
          if .metadata.annotations["storageclass.kubernetes.io/is-default-class"] != "false"
            then "the GA default-class annotation must be explicitly false" else empty end,
          if (.metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] // "false") != "false"
            then "the beta default-class annotation must be absent or false" else empty end,
          if .provisioner != "ebs.csi.eks.amazonaws.com"
            then "provisioner must be ebs.csi.eks.amazonaws.com" else empty end,
          if .parameters.type != "gp3"
            then "parameters.type must be gp3" else empty end,
          if .parameters.encrypted != "true"
            then "parameters.encrypted must be true" else empty end,
          if .reclaimPolicy != "Delete"
            then "reclaimPolicy must be Delete" else empty end,
          if .volumeBindingMode != "WaitForFirstConsumer"
            then "volumeBindingMode must be WaitForFirstConsumer" else empty end,
          if .allowVolumeExpansion != true
            then "allowVolumeExpansion must be true" else empty end
        ]
        | .[]
      '
  )"; then
    die "StorageClass ${STORAGE_CLASS_NAME} is not valid JSON."
  fi

  if [[ -n "${violations}" ]]; then
    while IFS= read -r violation; do
      echo "setup-storage-class: contract violation: ${violation}" >&2
    done <<<"${violations}"
    die "StorageClass ${STORAGE_CLASS_NAME} exists but does not match the required contract; refusing to patch or adopt it."
  fi
}

created_storage_class=false
created_storage_class_uid=""
rollback() {
  local exit_code="$?"
  set +e
  if ((exit_code != 0)) &&
    [[ "${created_storage_class}" == true &&
      "${receipt_committed}" != true &&
      -n "${created_storage_class_uid}" ]]; then
    local delete_options
    delete_options="$(
      jq -n --arg uid "${created_storage_class_uid}" '{
        apiVersion: "v1",
        kind: "DeleteOptions",
        propagationPolicy: "Foreground",
        preconditions: {uid: $uid}
      }'
    )"
    printf '%s' "${delete_options}" |
      "${KUBECTL[@]}" delete \
        --raw="/apis/storage.k8s.io/v1/storageclasses/${STORAGE_CLASS_NAME}" \
        -f - >/dev/null 2>&1 ||
      echo "setup-storage-class: rollback could not delete StorageClass ${STORAGE_CLASS_NAME}." >&2
  fi
  cleanup_local_state
  trap - EXIT
  exit "${exit_code}"
}
trap rollback EXIT

existing_resource="$(read_storage_class true)"
if [[ "${receipt_existing}" == true && -z "${existing_resource}" ]]; then
  die "StorageClass ${STORAGE_CLASS_NAME} recorded in --receipt is absent; refusing to replace its identity."
fi
if [[ -z "${existing_resource}" ]]; then
  echo "Creating StorageClass ${STORAGE_CLASS_NAME} in context ${KUBE_CONTEXT}." >&2
  create_error="$(mktemp "${receipt_parent:-${TMPDIR:-/tmp}}/.setup-storage-class-error.XXXXXX")" ||
    die "could not create a temporary error file."
  if ! create_output="$(
    "${KUBECTL[@]}" create --filename "${manifest_path}" --output=json \
      2>"${create_error}"
  )"; then
    concurrent_resource="$(read_storage_class true)"
    if [[ -z "${concurrent_resource}" ]]; then
      create_message="$(<"${create_error}")"
      rm -f -- "${create_error}"
      create_error=""
      die "could not create StorageClass ${STORAGE_CLASS_NAME}: ${create_message}"
    fi
    echo "StorageClass ${STORAGE_CLASS_NAME} appeared concurrently; validating it without modification." >&2
    existing_resource="${concurrent_resource}"
  else
    existing_resource="${create_output}"
    created_storage_class=true
    created_storage_class_uid="$(
      jq -er \
        --arg name "${STORAGE_CLASS_NAME}" \
        '
          select(
            .apiVersion == "storage.k8s.io/v1"
            and .kind == "StorageClass"
            and .metadata.name == $name
          )
          | .metadata.uid
          | strings
          | select(test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"))
        ' <<<"${existing_resource}"
    )" || die "create returned no stable identity for StorageClass ${STORAGE_CLASS_NAME}."
    echo "StorageClass ${STORAGE_CLASS_NAME} created." >&2
  fi
  rm -f -- "${create_error}"
  create_error=""
else
  echo "StorageClass ${STORAGE_CLASS_NAME} already exists; validating it without modification." >&2
fi

validate_storage_class "${existing_resource}"
storage_class_uid="$(
  jq -er '.metadata.uid | strings | select(test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"))' \
    <<<"${existing_resource}"
)" || {
  if [[ -n "${RECEIPT_PATH}" ]]; then
    die "StorageClass ${STORAGE_CLASS_NAME} has no valid UID for the lifecycle receipt."
  fi
  storage_class_uid=""
}
if [[ "${created_storage_class}" == true ]]; then
  [[ "${created_storage_class_uid}" == "${storage_class_uid}" ]] ||
    die "created StorageClass ${STORAGE_CLASS_NAME} changed identity before receipt commit."
fi

if [[ -n "${RECEIPT_PATH}" ]]; then
  context_endpoint="$(
    "${KUBECTL[@]}" config view \
      --minify \
      --output=jsonpath='{.clusters[0].cluster.server}'
  )" || die "could not resolve the API endpoint for kube context ${KUBE_CONTEXT}."
  [[ -n "${context_endpoint}" ]] ||
    die "kube context ${KUBE_CONTEXT} has no API endpoint."
  if [[ "${receipt_existing}" == true ]]; then
    [[ "${receipt_endpoint}" == "${context_endpoint}" ]] ||
      die "--receipt is bound to a different Kubernetes API endpoint."
    [[ "${receipt_uid}" == "${storage_class_uid}" ]] ||
      die "StorageClass ${STORAGE_CLASS_NAME} does not match the UID in --receipt."
  elif ! write_receipt \
    "${context_endpoint}" "${storage_class_uid}" "${created_storage_class}"; then
    die "could not atomically write lifecycle receipt ${RECEIPT_PATH}."
  fi
fi
printf '%s\n' "${STORAGE_CLASS_NAME}"
