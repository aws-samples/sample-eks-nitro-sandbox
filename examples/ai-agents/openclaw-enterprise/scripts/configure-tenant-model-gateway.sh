#!/usr/bin/env bash
set -euo pipefail

readonly OWNER_LABEL_KEY="app.kubernetes.io/managed-by"
readonly OWNER_LABEL_VALUE="openclaw-enterprise-blueprint"
readonly OCE_OWNER_LABEL_VALUE="openclaw-enterprise"
readonly AGW_NAMESPACE="openclaw-enterprise-agw"
readonly -a TENANT_RESOURCES=(
  "configmap/agentgateway-ca"
  "networkpolicy.networking.k8s.io/oce-private-service-egress"
)

die() {
  echo "configure-tenant-model-gateway: $*" >&2
  exit 1
}

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <kube-context> <oce-tenant-namespace> <cluster-dns-ipv4/32>" >&2
  exit 2
fi

readonly KUBE_CONTEXT="$1"
readonly TENANT_NAMESPACE="$2"
readonly CLUSTER_DNS_CIDR="$3"

if [[ ! "${TENANT_NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
   (( ${#TENANT_NAMESPACE} > 63 )); then
  echo "The tenant namespace must be a valid Kubernetes DNS label." >&2
  exit 2
fi

for command in kubectl jq base64 cmp mktemp python3; do
  command -v "${command}" >/dev/null 2>&1 ||
    die "${command} is required."
done

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
    --output=jsonpath='{.metadata.name}{"|"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\n"}'
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
  local record
  # resource_record's die exits only its command substitution, and callers test this function in if/||,
  # where errexit is off; stop here so a failed read never counts as absent.
  record="$(resource_record "${resource}" "${namespace}")" ||
    die "could not determine ownership of ${resource}${namespace:+ in ${namespace}}."
  if [[ -z "${record}" ]]; then
    return 1
  fi
  [[ "${record}" == "${expected_name}|${expected_owner}" ]] ||
    die "${resource}${namespace:+ in ${namespace}} does not carry the exact ${OWNER_LABEL_KEY}=${expected_owner} ownership label."
}

owned_resource_exists \
  "namespace/${TENANT_NAMESPACE}" "" "${OCE_OWNER_LABEL_VALUE}" ||
  die "namespace ${TENANT_NAMESPACE} does not exist."

ca_config_map_exists=false
for resource in "${TENANT_RESOURCES[@]}"; do
  if owned_resource_exists \
    "${resource}" "${TENANT_NAMESPACE}" "${OWNER_LABEL_VALUE}"; then
    if [[ "${resource}" == "configmap/agentgateway-ca" ]]; then
      ca_config_map_exists=true
    fi
  fi
done

work_dir="$(mktemp -d)"
trap 'rm -rf -- "${work_dir}"' EXIT
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

if [[ "${ca_config_map_exists}" == false ]]; then
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
    "${KUBECTL[@]}" create --filename -
  owned_resource_exists \
    "configmap/agentgateway-ca" \
    "${TENANT_NAMESPACE}" \
    "${OWNER_LABEL_VALUE}" ||
    die "created ConfigMap agentgateway-ca could not be verified."
fi

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
  }' |
  "${KUBECTL[@]}" apply \
    --server-side \
    --field-manager="${OWNER_LABEL_VALUE}" \
    --filename -
owned_resource_exists \
  "networkpolicy.networking.k8s.io/oce-private-service-egress" \
  "${TENANT_NAMESPACE}" \
  "${OWNER_LABEL_VALUE}" ||
  die "created NetworkPolicy oce-private-service-egress could not be verified."

echo "Configured the Nitro Pod Security profile, private AgentGateway trust, and exact private Service routes for ${TENANT_NAMESPACE}."
