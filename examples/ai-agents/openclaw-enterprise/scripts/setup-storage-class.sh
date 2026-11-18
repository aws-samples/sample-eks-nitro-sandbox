#!/usr/bin/env bash
set -euo pipefail

readonly STORAGE_CLASS_NAME="openclaw-enterprise-gp3"
readonly OWNER_LABEL_VALUE="openclaw-enterprise-blueprint"

usage() {
  cat >&2 <<'EOF'
Usage:
  setup-storage-class.sh --kube-context CONTEXT

Creates or verifies the sample-owned, non-default encrypted gp3 StorageClass
for EKS Auto Mode. An existing same-name StorageClass must match the complete
storage and ownership contract; this script never patches or adopts it.
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

while (( $# > 0 )); do
  case "$1" in
    --kube-context)
      require_value "$1" "${2:-}"
      KUBE_CONTEXT="$2"
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

for command in kubectl jq; do
  command -v "${command}" >/dev/null 2>&1 ||
    die "${command} is required."
done

readonly -a KUBECTL=(kubectl --context "${KUBE_CONTEXT}")

context_name="$(
  "${KUBECTL[@]}" config get-contexts \
    "${KUBE_CONTEXT}" \
    --no-headers \
    --output=name
)" || die "could not read kube context ${KUBE_CONTEXT}."
[[ "${context_name}" == "${KUBE_CONTEXT}" ]] ||
  die "kube context ${KUBE_CONTEXT} does not exist exactly."

"${KUBECTL[@]}" get --raw=/readyz >/dev/null ||
  die "could not reach kube context ${KUBE_CONTEXT}."

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

existing_resource="$(read_storage_class true)"
if [[ -z "${existing_resource}" ]]; then
  echo "Creating StorageClass ${STORAGE_CLASS_NAME} in context ${KUBE_CONTEXT}." >&2
  if ! create_output="$(
    "${KUBECTL[@]}" create --filename "${manifest_path}" 2>&1
  )"; then
    concurrent_resource="$(read_storage_class true)"
    if [[ -z "${concurrent_resource}" ]]; then
      die "could not create StorageClass ${STORAGE_CLASS_NAME}: ${create_output}"
    fi
    echo "StorageClass ${STORAGE_CLASS_NAME} appeared concurrently; validating it without modification." >&2
    existing_resource="${concurrent_resource}"
  else
    printf '%s\n' "${create_output}" >&2
    existing_resource="$(read_storage_class false)"
  fi
else
  echo "StorageClass ${STORAGE_CLASS_NAME} already exists; validating it without modification." >&2
fi

validate_storage_class "${existing_resource}"
printf '%s\n' "${STORAGE_CLASS_NAME}"
