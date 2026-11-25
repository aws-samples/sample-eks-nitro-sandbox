#!/usr/bin/env bash
set -euo pipefail

readonly OWNER_LABEL_KEY="app.kubernetes.io/managed-by"
readonly OWNER_LABEL_VALUE="openclaw-enterprise-blueprint"
readonly OCE_OWNER_LABEL_VALUE="openclaw-enterprise"
readonly AGW_NAMESPACE="openclaw-enterprise-agw"

die() {
  echo "configure-tenant-model-gateway: $*" >&2
  exit 1
}

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <kube-context> <oce-tenant-namespace> <cluster-dns-ipv4/32> <receipt-file>" >&2
  exit 2
fi

readonly KUBE_CONTEXT="$1"
readonly TENANT_NAMESPACE="$2"
readonly CLUSTER_DNS_CIDR="$3"
# The receipt records the UIDs of the CA ConfigMap and the NetworkPolicy this script created, so a rerun
# changes only those objects and never a same-name replacement.
readonly RECEIPT_PATH="$4"

if [[ ! "${TENANT_NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
   (( ${#TENANT_NAMESPACE} > 63 )); then
  echo "The tenant namespace must be a valid Kubernetes DNS label." >&2
  exit 2
fi
[[ "${RECEIPT_PATH}" = /* ]] || die "the receipt must be an absolute path."

for command in kubectl jq base64 cmp mktemp python3 stat find; do
  command -v "${command}" >/dev/null 2>&1 ||
    die "${command} is required."
done

work_dir=""
receipt_temp=""
receipt_lock="${RECEIPT_PATH}.lock"
receipt_lock_acquired=false
receipt_lock_token=""
# Release only the lock this run created, while it is empty or holds only this run's owner token.
release_receipt_lock() {
  [[ "${receipt_lock_acquired}" == true ]] || return 0
  receipt_lock_acquired=false
  local owner_file="${receipt_lock}/owner"
  if [[ -d "${receipt_lock}" && ! -L "${receipt_lock}" ]]; then
    if [[ -f "${owner_file}" && ! -L "${owner_file}" &&
      "$(<"${owner_file}")" == "${receipt_lock_token}" &&
      -z "$(find "${receipt_lock}" -mindepth 1 -maxdepth 1 ! -name owner -print)" ]]; then
      rm -f -- "${owner_file}"
    fi
    rmdir -- "${receipt_lock}" 2>/dev/null && return 0
  fi
  echo "configure-tenant-model-gateway: receipt lock ownership changed; preserving ${receipt_lock}." >&2
}
cleanup_local_state() {
  [[ -z "${work_dir}" ]] || rm -rf -- "${work_dir}"
  [[ -z "${receipt_temp}" ]] || rm -f -- "${receipt_temp}"
  release_receipt_lock
}
trap cleanup_local_state EXIT

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

python3 -I -c '
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1], strict=True)
except ValueError:
    raise SystemExit(1)
if network.version != 4 or network.prefixlen != 32:
    raise SystemExit(1)
' "${CLUSTER_DNS_CIDR}" ||
  die "cluster DNS address must be an exact IPv4 /32."

context_name="$(
  kubectl config get-contexts "${KUBE_CONTEXT}" --no-headers --output=name
)" || die "could not read kube context ${KUBE_CONTEXT}."
[[ "${context_name}" == "${KUBE_CONTEXT}" ]] ||
  die "kube context ${KUBE_CONTEXT} does not exist exactly."
readonly -a KUBECTL=(kubectl --context "${KUBE_CONTEXT}")
"${KUBECTL[@]}" get --raw=/readyz >/dev/null ||
  die "could not reach kube context ${KUBE_CONTEXT}."

agentgateway_service_ip="$(
  "${KUBECTL[@]}" get service agentgateway \
    --namespace "${AGW_NAMESPACE}" --output=jsonpath='{.spec.clusterIP}'
)" || die "could not read the private AgentGateway Service address."
python3 -I -c '
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
if address.version != 4:
    raise SystemExit(1)
' "${agentgateway_service_ip}" ||
  die "AgentGateway Service address must be an IPv4 address."
readonly AGENTGATEWAY_SERVICE_CIDR="${agentgateway_service_ip}/32"

resource_record() {
  local resource="$1"
  local namespace="$2"
  local -a command=(
    "${KUBECTL[@]}"
    get
    "${resource}"
  )
  if [[ -n "${namespace}" ]]; then
    command+=(--namespace "${namespace}")
  fi
  command+=(
    --ignore-not-found
    --output=jsonpath='{.metadata.name}{"|"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"|"}{.metadata.uid}{"\n"}'
  )

  local record
  if ! record="$("${command[@]}")"; then
    die "could not determine ownership of ${resource}${namespace:+ in ${namespace}}."
  fi
  printf '%s' "${record}"
}

owned_resource_exists() {
  local resource="$1"
  local namespace="$2"
  local expected_owner="$3"
  local expected_name="${resource##*/}"
  local record name owner uid
  # resource_record's die exits only its command substitution, and callers test this function in if/||,
  # where errexit is off; stop here so a failed read never counts as absent.
  record="$(resource_record "${resource}" "${namespace}")" ||
    die "could not determine ownership of ${resource}${namespace:+ in ${namespace}}."
  owned_uid=""
  if [[ -z "${record}" ]]; then
    return 1
  fi
  IFS='|' read -r name owner uid <<<"${record}"
  [[ "${name}|${owner}" == "${expected_name}|${expected_owner}" ]] ||
    die "${resource}${namespace:+ in ${namespace}} does not carry the exact ${OWNER_LABEL_KEY}=${expected_owner} ownership label."
  [[ "${uid}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] ||
    die "${resource}${namespace:+ in ${namespace}} has no valid UID."
  owned_uid="${uid}"
}

# Take the receipt lock, then read any receipt from an earlier run.
receipt_parent="$(dirname -- "${RECEIPT_PATH}")"
canonical_parent="$(cd -- "${receipt_parent}" 2>/dev/null && pwd -P)" ||
  die "receipt parent directory does not exist: ${receipt_parent}."
[[ "${canonical_parent}" == "${receipt_parent}" &&
  -d "${receipt_parent}" && ! -L "${receipt_parent}" && -O "${receipt_parent}" ]] ||
  die "receipt parent must be an owned canonical directory, not a symbolic link."
receipt_parent_mode="$(file_mode "${receipt_parent}")"
(( (8#${receipt_parent_mode} & 8#022) == 0 )) ||
  die "receipt parent must not be writable by group or other users."
[[ ! -L "${receipt_lock}" ]] || die "receipt lock must not be a symbolic link."
receipt_lock_token="$(python3 -I -c 'import secrets; print(secrets.token_hex(32))')" ||
  die "could not generate the receipt lock token."
mkdir -- "${receipt_lock}" 2>/dev/null ||
  die "receipt is already in use or has a stale lock: ${receipt_lock}."
receipt_lock_acquired=true
chmod 700 "${receipt_lock}" || die "could not secure the receipt lock ${receipt_lock}."
printf '%s\n' "${receipt_lock_token}" >"${receipt_lock}/owner" ||
  die "could not record the receipt lock owner."
chmod 600 "${receipt_lock}/owner" || die "could not secure the receipt lock owner."

recorded_ca_uid=""
recorded_policy_uid=""
[[ ! -L "${RECEIPT_PATH}" ]] || die "the receipt must not be a symbolic link."
if [[ -e "${RECEIPT_PATH}" ]]; then
  [[ -f "${RECEIPT_PATH}" && -O "${RECEIPT_PATH}" && -r "${RECEIPT_PATH}" ]] ||
    die "the receipt must be an owned readable regular file."
  case "$(file_mode "${RECEIPT_PATH}")" in
    400|600) ;;
    *) die "the receipt must have mode 0400 or 0600." ;;
  esac
  recorded_uids="$(
    jq -er \
      --arg context "${KUBE_CONTEXT}" \
      --arg namespace "${TENANT_NAMESPACE}" '
      def object($api; $kind; $name):
        type == "object"
        and keys == ["apiVersion", "kind", "name", "uid"]
        and .apiVersion == $api
        and .kind == $kind
        and .name == $name
        and (.uid | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"));
      if (
        type == "object"
        and keys == ["kubeContext", "namespace", "operation", "resources", "version"]
        and .version == 1
        and .operation == "configure-tenant-model-gateway"
        and .kubeContext == $context
        and .namespace == $namespace
        and (.resources | type == "array" and length == 2)
        and (.resources[0] | object("v1"; "ConfigMap"; "agentgateway-ca"))
        and (.resources[1] | object("networking.k8s.io/v1"; "NetworkPolicy"; "oce-private-service-egress"))
      )
      then [.resources[0].uid, .resources[1].uid] | @tsv
      else error("unexpected tenant receipt schema or target")
      end
    ' "${RECEIPT_PATH}"
  )" || die "the receipt is invalid or belongs to another tenant or kube context."
  IFS=$'\t' read -r recorded_ca_uid recorded_policy_uid <<<"${recorded_uids}"
fi

owned_resource_exists \
  "namespace/${TENANT_NAMESPACE}" "" "${OCE_OWNER_LABEL_VALUE}" ||
  die "namespace ${TENANT_NAMESPACE} does not exist."

live_ca_uid=""
live_policy_uid=""
if owned_resource_exists \
  "configmap/agentgateway-ca" "${TENANT_NAMESPACE}" "${OWNER_LABEL_VALUE}"; then
  live_ca_uid="${owned_uid}"
fi
if owned_resource_exists \
  "networkpolicy.networking.k8s.io/oce-private-service-egress" \
  "${TENANT_NAMESPACE}" "${OWNER_LABEL_VALUE}"; then
  live_policy_uid="${owned_uid}"
fi
# Before any change: a rerun needs both recorded objects with their recorded UIDs, and a first run needs
# neither object to exist yet.
if [[ -e "${RECEIPT_PATH}" ]]; then
  [[ "${live_ca_uid}" == "${recorded_ca_uid}" ]] ||
    die "configmap/agentgateway-ca in ${TENANT_NAMESPACE} is missing or was replaced since ${RECEIPT_PATH} recorded it; refusing to change it."
  [[ "${live_policy_uid}" == "${recorded_policy_uid}" ]] ||
    die "networkpolicy/oce-private-service-egress in ${TENANT_NAMESPACE} is missing or was replaced since ${RECEIPT_PATH} recorded it; refusing to change it."
  ca_config_map_exists=true
else
  for live in "configmap/agentgateway-ca|${live_ca_uid}" \
    "networkpolicy/oce-private-service-egress|${live_policy_uid}"; do
    [[ -z "${live#*|}" ]] ||
      die "${live%%|*} in ${TENANT_NAMESPACE} exists, but ${RECEIPT_PATH} does not record it; refusing to adopt it. If the first run was interrupted, follow README Step 7."
  done
  ca_config_map_exists=false
fi

work_dir="$(mktemp -d)"
readonly ca_file="${work_dir}/ca.crt"

"${KUBECTL[@]}" wait \
  --namespace "${AGW_NAMESPACE}" \
  --for=condition=Ready \
  certificate/agentgateway-root \
  --timeout=120s

"${KUBECTL[@]}" get secret agentgateway-ca \
  --namespace "${AGW_NAMESPACE}" \
  --output jsonpath='{.data.tls\.crt}' |
  base64 --decode >"${ca_file}"

if [[ "${ca_config_map_exists}" == true ]]; then
  existing_ca="${work_dir}/existing-ca.crt"
  "${KUBECTL[@]}" get configmap agentgateway-ca \
    --namespace "${TENANT_NAMESPACE}" \
    --output jsonpath='{.data.ca\.crt}' >"${existing_ca}"
  if ! cmp --silent "${ca_file}" "${existing_ca}"; then
    die "the immutable AgentGateway CA changed; recreate the ConfigMap deliberately."
  fi
fi

"${KUBECTL[@]}" label "namespace/${TENANT_NAMESPACE}" \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted \
  --overwrite

# A first run creates each object exclusively and takes its UID from the create response. The follow-up read
# must return that UID and the content this run wrote, so an object that appeared after the preflight read, or
# a replacement made between the create and the read, is refused before the receipt is published. Server-side
# apply is used only on a receipt-backed rerun, after the live UIDs matched the receipt.
created_uid() {
  jq -er --arg kind "$1" --arg name "$2" --arg namespace "${TENANT_NAMESPACE}" '
    if .kind == $kind
      and .metadata.name == $name
      and .metadata.namespace == $namespace
      and (.metadata.uid | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"))
    then .metadata.uid
    else error("unexpected create response")
    end
  ' <<<"$3" 2>/dev/null
}

# verify_live_object RESOURCE UID FILTER [JQ_ARGS...]: read RESOURCE back and require FILTER, which sees $uid,
# $owner and $namespace, to hold for the live object.
verify_live_object() {
  local resource="$1"
  local uid="$2"
  local filter="$3"
  shift 3
  local live
  live="$("${KUBECTL[@]}" get "${resource}" --namespace "${TENANT_NAMESPACE}" --output=json)" ||
    die "could not read ${resource} in ${TENANT_NAMESPACE} back."
  jq -e \
    --arg uid "${uid}" \
    --arg owner "${OWNER_LABEL_VALUE}" \
    --arg namespace "${TENANT_NAMESPACE}" \
    "$@" "${filter}" <<<"${live}" >/dev/null ||
    die "${resource} in ${TENANT_NAMESPACE} is not the object this run created or recorded, or its content differs from what this run wrote; refusing to continue."
}

if [[ "${ca_config_map_exists}" == false ]]; then
  ca_created="$(
    "${KUBECTL[@]}" create configmap agentgateway-ca \
      --namespace "${TENANT_NAMESPACE}" \
      --from-file=ca.crt="${ca_file}" \
      --dry-run=client \
      --output json |
      jq \
        --arg owner "${OWNER_LABEL_VALUE}" \
        '.immutable = true
         | .metadata.labels = ((.metadata.labels // {})
           + {"app.kubernetes.io/managed-by": $owner})' |
      "${KUBECTL[@]}" create --filename - --output=json
  )" || die "could not create configmap/agentgateway-ca in ${TENANT_NAMESPACE} as a new object. If the first run was interrupted, follow README Step 7."
  recorded_ca_uid="$(created_uid ConfigMap agentgateway-ca "${ca_created}")" ||
    die "the create response for configmap/agentgateway-ca in ${TENANT_NAMESPACE} has no valid identity."
  verify_live_object configmap/agentgateway-ca "${recorded_ca_uid}" '
    .kind == "ConfigMap"
    and .metadata.name == "agentgateway-ca"
    and .metadata.namespace == $namespace
    and .metadata.uid == $uid
    and .metadata.labels["app.kubernetes.io/managed-by"] == $owner
    and .immutable == true
    and .data == {"ca.crt": $ca}
    and (has("binaryData") | not)
  ' --rawfile ca "${ca_file}"
fi

readonly policy_file="${work_dir}/networkpolicy.json"
jq -n \
  --arg namespace "${TENANT_NAMESPACE}" \
  --arg owner "${OWNER_LABEL_VALUE}" \
  --arg cluster_dns_cidr "${CLUSTER_DNS_CIDR}" \
  --arg agentgateway_service_cidr "${AGENTGATEWAY_SERVICE_CIDR}" \
  '{
    apiVersion: "networking.k8s.io/v1",
    kind: "NetworkPolicy",
    metadata: {
      name: "oce-private-service-egress",
      namespace: $namespace,
      labels: {
        "app.kubernetes.io/managed-by": $owner
      }
    },
    spec: {
      podSelector: {
        matchLabels: {
          "app.kubernetes.io/managed-by": "openclaw-enterprise",
          "openclaw.dev/workload-role": "gateway",
          "openclaw.dev/network-profile": "broad-egress-v1"
        }
      },
      policyTypes: ["Egress"],
      egress: [
        {
          to: [{ipBlock: {cidr: $cluster_dns_cidr}}],
          ports: [
            {protocol: "UDP", port: 53},
            {protocol: "TCP", port: 53}
          ]
        },
        {
          to: [{ipBlock: {cidr: $agentgateway_service_cidr}}],
          ports: [{protocol: "TCP", port: 443}]
        }
      ]
    }
  }' >"${policy_file}"
if [[ -e "${RECEIPT_PATH}" ]]; then
  "${KUBECTL[@]}" apply \
    --server-side \
    --field-manager="${OWNER_LABEL_VALUE}" \
    --filename - <"${policy_file}"
else
  policy_created="$(
    "${KUBECTL[@]}" create --filename - --output=json <"${policy_file}"
  )" || die "could not create networkpolicy/oce-private-service-egress in ${TENANT_NAMESPACE} as a new object. If the first run was interrupted, follow README Step 7."
  recorded_policy_uid="$(
    created_uid NetworkPolicy oce-private-service-egress "${policy_created}"
  )" ||
    die "the create response for networkpolicy/oce-private-service-egress in ${TENANT_NAMESPACE} has no valid identity."
fi
verify_live_object networkpolicy.networking.k8s.io/oce-private-service-egress "${recorded_policy_uid}" '
  .kind == "NetworkPolicy"
  and .metadata.name == "oce-private-service-egress"
  and .metadata.namespace == $namespace
  and .metadata.uid == $uid
  and .metadata.labels["app.kubernetes.io/managed-by"] == $owner
  and .spec == $policy[0].spec
' --slurpfile policy "${policy_file}"

if [[ ! -e "${RECEIPT_PATH}" ]]; then
  # Link a fully written private file into place; link(2) fails if anything appeared at the path meanwhile.
  receipt_temp="$(mktemp "${receipt_parent}/.$(basename -- "${RECEIPT_PATH}").tmp.XXXXXX")" ||
    die "could not create a temporary receipt."
  chmod 600 "${receipt_temp}" || die "could not secure the temporary receipt."
  jq -n \
    --arg context "${KUBE_CONTEXT}" \
    --arg namespace "${TENANT_NAMESPACE}" \
    --arg ca_uid "${recorded_ca_uid}" \
    --arg policy_uid "${recorded_policy_uid}" \
    '{
      version: 1,
      operation: "configure-tenant-model-gateway",
      kubeContext: $context,
      namespace: $namespace,
      resources: [
        {apiVersion: "v1", kind: "ConfigMap", name: "agentgateway-ca", uid: $ca_uid},
        {
          apiVersion: "networking.k8s.io/v1",
          kind: "NetworkPolicy",
          name: "oce-private-service-egress",
          uid: $policy_uid
        }
      ]
    }' >"${receipt_temp}" || die "could not write the receipt."
  python3 -I -c '
import os
import sys

source, destination, parent = sys.argv[1:]
with open(source, "rb") as temporary:
    os.fsync(temporary.fileno())
os.link(source, destination, follow_symlinks=False)
os.unlink(source)
directory = os.open(parent, os.O_RDONLY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
' "${receipt_temp}" "${RECEIPT_PATH}" "${receipt_parent}" ||
    die "could not publish the receipt ${RECEIPT_PATH}; the created objects are not recorded."
  receipt_temp=""
fi

echo "Configured the Nitro Pod Security profile, private AgentGateway trust, and exact private Service routes for ${TENANT_NAMESPACE}."
