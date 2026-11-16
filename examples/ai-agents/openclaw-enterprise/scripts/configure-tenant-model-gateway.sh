#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
SAMPLE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly SAMPLE_DIR
readonly AGW_NAMESPACE="openclaw-enterprise-agw"
readonly TENANT_TEMPLATE="${SAMPLE_DIR}/deploy/tenant-model-gateway.yaml.tpl"

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <kube-context> <oce-tenant-namespace>" >&2
  exit 2
fi

readonly KUBE_CONTEXT="$1"
readonly TENANT_NAMESPACE="$2"
readonly -a KUBECTL=(kubectl --context "${KUBE_CONTEXT}")
kubectl config get-contexts "${KUBE_CONTEXT}" >/dev/null

if [[ ! "${TENANT_NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
   (( ${#TENANT_NAMESPACE} > 63 )); then
  echo "The tenant namespace must be a valid Kubernetes DNS label." >&2
  exit 2
fi

managed_by="$(
  "${KUBECTL[@]}" get namespace "${TENANT_NAMESPACE}" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}'
)"
if [[ "${managed_by}" != "openclaw-enterprise" ]]; then
  echo "Namespace ${TENANT_NAMESPACE} is not managed by OpenClaw Enterprise." >&2
  exit 1
fi

"${KUBECTL[@]}" label namespace "${TENANT_NAMESPACE}" \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted \
  --overwrite

agentgateway_ip="$(
  "${KUBECTL[@]}" get service agentgateway \
    --namespace "${AGW_NAMESPACE}" \
    --output jsonpath='{.spec.clusterIP}'
)"
if [[ ! "${agentgateway_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "AgentGateway must have an IPv4 ClusterIP." >&2
  exit 1
fi
readonly agentgateway_cidr="${agentgateway_ip}/32"

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

if "${KUBECTL[@]}" get configmap agentgateway-ca \
  --namespace "${TENANT_NAMESPACE}" >/dev/null 2>&1; then
  existing_ca="${work_dir}/existing-ca.crt"
  "${KUBECTL[@]}" get configmap agentgateway-ca \
    --namespace "${TENANT_NAMESPACE}" \
    --output jsonpath='{.data.ca\.crt}' >"${existing_ca}"
  if ! cmp --silent "${ca_file}" "${existing_ca}"; then
    echo "The immutable AgentGateway CA changed; recreate the ConfigMap deliberately." >&2
    exit 1
  fi
else
  "${KUBECTL[@]}" create configmap agentgateway-ca \
    --namespace "${TENANT_NAMESPACE}" \
    --from-file=ca.crt="${ca_file}" \
    --dry-run=client \
    --output json |
    jq '.immutable = true' |
    "${KUBECTL[@]}" create --filename -
fi

sed \
  -e "s/OCE_TENANT_NAMESPACE/${TENANT_NAMESPACE}/g" \
  -e "s#OCE_AGENTGATEWAY_SERVICE_CIDR#${agentgateway_cidr}#g" \
  "${TENANT_TEMPLATE}" |
  "${KUBECTL[@]}" apply --filename -

echo "Configured the Nitro Pod Security profile, private AgentGateway trust, and egress path for ${TENANT_NAMESPACE}."
