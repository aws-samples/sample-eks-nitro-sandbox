#!/usr/bin/env bash
# Build a reproducible image, gate a KMS key on its PCR17 measurement, and run the
# confidential-sandbox pod that decrypts with that key.
#
#   ./scripts/setup.sh              # the whole flow, ending with both pods Ready
#   ./scripts/setup.sh --no-pods    # everything except starting the pods
#
# Reads .env (copy from .env.example). Writes run files, including the generated Cedar
# policy, rendered manifests and the live key policy, to the repository's
# tmp/reproducible-build/run/. Nothing it writes goes anywhere else, and clean.sh removes
# that one directory.
#
# Every AWS resource is tagged ManagedBy=reproducible-build, and an existing one is reused
# only when that tag is on it. The namespace carries a matching
# app.kubernetes.io/managed-by label, which clean.sh checks before it deletes anything
# inside.
#
# It applies no network policy. Restricting egress is the subject of its own sample,
# examples/isolation/network-policy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAMPLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SHARED_DIR="$(cd "${SAMPLE_DIR}/../_shared" && pwd)"
REPO_ROOT="$(cd "${SAMPLE_DIR}/../../.." && pwd)"
TMP_DIR="${REPO_ROOT}/tmp/reproducible-build/run"
STATE_FILE="${TMP_DIR}/state.env"

MANAGED_BY="reproducible-build"

# ---------------------------------------------------------------------------- settings
if [[ -f "${SAMPLE_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null  # local, gitignored settings file
  . "${SAMPLE_DIR}/.env"
  set +a
fi

CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
NAMESPACE="${NAMESPACE:-reproducible-build}"
REPO_NAME="${REPO_NAME:-reproducible-build}"
ROLE_NAME="${ROLE_NAME:-reproducible-build-pod}"
KMS_ALIAS="${KMS_ALIAS:-alias/reproducible-build-sample}"

SERVICE_ACCOUNT="reproducible-build-pod"
POD_NAME="reproducible-build-demo"
PLAIN_POD_NAME="reproducible-build-plain"

GENPOLICY="${GENPOLICY:-eks-nitro-sandbox-genpolicy}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"

PROFILE="${SAMPLE_DIR}/deploy/production-profile.yaml"
KEY_POLICY_TEMPLATE="${SHARED_DIR}/kms-key-policy.json"
TRUST_POLICY_TEMPLATE="${SHARED_DIR}/pod-identity/role-trust-policy.json"

no_pods=false
for arg in "$@"; do
  case "${arg}" in
    --no-pods) no_pods=true ;;
    --help | -h)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: ${arg}" >&2
      exit 2
      ;;
  esac
done

# shellcheck source=examples/confidential/reproducible-build/scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"
state_put() { printf '%s=%s\n' "$1" "$2" >>"${STATE_FILE}"; }

# ------------------------------------------------------------------ 1/8 preflight
echo "== 1/8 check the tools, the cluster and the Region =="
[[ -n "${CLUSTER_NAME}" ]] || die "CLUSTER_NAME is not set; copy .env.example to .env and fill it in"
[[ -n "${AWS_REGION}" ]] || die "AWS_REGION is not set; copy .env.example to .env and fill it in"
export AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"

for c in aws jq kubectl "${CONTAINER_RUNTIME}" "${GENPOLICY}"; do
  command -v "${c}" >/dev/null 2>&1 || die "${c} is required"
done

mkdir -p "${TMP_DIR}"

account_id="$(aws sts get-caller-identity --query Account --output text)" \
  || die "could not read the AWS account; check your credentials"
registry="${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"

if [[ -n "${KUBE_CONTEXT:-}" ]]; then
  # shellcheck disable=SC2310  # the || fallback handles a failed lookup
  current_ctx="$(kc config current-context 2>/dev/null)" || current_ctx="(unknown)"
  [[ "${current_ctx}" == "${KUBE_CONTEXT}" ]] \
    || die "kubectl current-context is '${current_ctx}', expected '${KUBE_CONTEXT}'; set KUBE_CONTEXT in .env to the cluster you mean"
  echo "  context:  ${current_ctx}"
else
  # shellcheck disable=SC2310,SC2312  # the || fallback handles a failed lookup
  echo "  context:  $(kc config current-context 2>/dev/null || echo '(unknown)')"
fi
# shellcheck disable=SC2310  # the || die is the check
kc get runtimeclass confidential-sandbox -o name >/dev/null 2>&1 \
  || die "the confidential-sandbox runtime class is not on this cluster; run the Getting started samples first"

: >"${STATE_FILE}"
chmod 600 "${STATE_FILE}"
state_put NAMESPACE "${NAMESPACE}"
state_put AWS_REGION "${AWS_REGION}"
state_put CLUSTER_NAME "${CLUSTER_NAME}"

# --------------------------------------------------------------------- 2/8 ECR repo
echo "== 2/8 create the ECR repository =="

repo_json=""
repo_rc=0
# shellcheck disable=SC2310  # the exit code is captured in repo_rc and checked next
repo_json="$(lookup RepositoryNotFoundException ecr describe-repositories \
  --repository-names "${REPO_NAME}" --query 'repositories[0]' --output json)" || repo_rc=$?
stop_if_undetermined "${repo_rc}" "the ECR repository ${REPO_NAME}"
if [[ "${repo_rc}" == 0 ]]; then
  repo_arn="$(jq -r '.repositoryArn' <<<"${repo_json}")"
  # shellcheck disable=SC2312  # a failed lookup yields an empty tag, which require_managed_by rejects
  repo_tag="$(tag_or_empty "$(aws ecr list-tags-for-resource --resource-arn "${repo_arn}" \
    --query "tags[?Key=='ManagedBy'].Value | [0]" --output text)")"
  require_managed_by "the ECR repository ${REPO_NAME}" "${repo_tag}"
  repo_uri="$(jq -r '.repositoryUri' <<<"${repo_json}")"
  echo "  reusing ECR repository ${REPO_NAME} (${repo_uri})"
  state_put ECR_CREATED false
else
  repo_json="$(aws ecr create-repository --repository-name "${REPO_NAME}" \
    --image-tag-mutability IMMUTABLE \
    --image-scanning-configuration scanOnPush=false \
    --encryption-configuration encryptionType=AES256 \
    --tags "Key=ManagedBy,Value=${MANAGED_BY}" \
    --output json)"
  repo_uri="$(jq -r '.repository.repositoryUri' <<<"${repo_json}")"
  repo_arn="$(jq -r '.repository.repositoryArn' <<<"${repo_json}")"
  echo "  created ECR repository ${REPO_NAME} (${repo_uri})"
  state_put ECR_CREATED true
fi
state_put REPO_NAME "${REPO_NAME}"
state_put ECR_REPOSITORY_ARN "${repo_arn}"
state_put REPO_URI "${repo_uri}"

# -------------------------------------------------------------- 3/8 build and push
echo "== 3/8 build the application image and push it to ECR =="

# Write the registry auth file, then build and push in one container. The auth file must
# exist before build.sh is called; it is mounted read-only inside the build container.
# A failed ecr get-login-password would otherwise produce an empty auth file and the push
# would fail with an opaque registry error.
(
  umask 077
  mkdir -p "${TMP_DIR}"
)
auth_file="${TMP_DIR}/auth.json"
ecr_token="$(aws ecr get-login-password)" \
  || die "could not get an ECR authorization token"
[[ -n "${ecr_token}" ]] || die "the ECR authorization token came back empty"
(
  umask 077
  printf 'AWS:%s' "${ecr_token}" | base64 | tr -d '\r\n' \
    | jq -Rn --arg r "${registry}" '{auths:{($r):{auth:input}}}' \
      >"${auth_file}"
)
unset ecr_token
# Sanity-check: auth must carry a token longer than the prefix "AWS:" encodes to.
jq -e --arg r "${registry}" --arg prefix "QVdTOg" '
  .auths[$r].auth | type == "string" and length > 0
  and . != "QVdTOg==" and (length > ($prefix | length) + 2)
' "${auth_file}" >/dev/null \
  || die "could not write the ECR credentials needed by the build"

# build.sh --push with --tag-from-digest: the literal @DIGEST12@ in the tag is replaced
# with the first 12 hex chars of the built digest before push — one build, one push.
# build.sh writes <out_dir>/digest (sha256:...) and <out_dir>/pushed-ref (the full URI).
image_tag="v1-@DIGEST12@"
rm -rf "${TMP_DIR}/build" # build.sh wants an empty out_dir; a failed run leaves one behind
"${SCRIPT_DIR}/build.sh" "${SAMPLE_DIR}" "${TMP_DIR}/build" \
  --push "${repo_uri}:${image_tag}" "${auth_file}" --tag-from-digest

image_digest="$(cat "${TMP_DIR}/build/digest")"
[[ "${image_digest}" == sha256:* ]] || die "build.sh did not write a valid digest to ${TMP_DIR}/build/digest"
pushed_ref="$(cat "${TMP_DIR}/build/pushed-ref")"
[[ -n "${pushed_ref}" ]] || die "build.sh did not write pushed-ref; cannot determine the pushed tag"
# Extract the tag from the pushed reference (repo_uri:tag).
image_tag_actual="${pushed_ref##*:}"
IMAGE_REPO="${repo_uri}"
IMAGE_DIGEST="${image_digest}"
APP_IMAGE_URI="${repo_uri}@${image_digest}"
state_put IMAGE_DIGEST "${IMAGE_DIGEST}"
state_put IMAGE_REPO "${IMAGE_REPO}"
state_put APP_IMAGE_URI "${APP_IMAGE_URI}"

# Confirm ECR has the image at the expected digest.
ecr_digest="$(aws ecr describe-images --repository-name "${REPO_NAME}" \
  --image-ids "imageTag=${image_tag_actual}" \
  --query 'imageDetails[0].imageDigest' --output text 2>/dev/null)" \
  || die "could not read the digest of the published image from ECR"
[[ "${ecr_digest}" == "${IMAGE_DIGEST}" ]] \
  || die "ECR reports digest ${ecr_digest} but the build wrote ${IMAGE_DIGEST}; the push may not have landed"
echo "  published ${APP_IMAGE_URI} (tag ${image_tag_actual})"

# ---------------------------------------------------------- 4/8 generate the policy
echo "== 4/8 generate the Cedar policy =="

# The KMS alias ARN is predictable from account, region and alias name, so the pod can be
# rendered with it before the key is created. The Cedar policy pins this ARN into PCR17,
# and the key is then created under exactly this alias, so the measurement matches at
# runtime.
kms_alias_arn="arn:aws:kms:${AWS_REGION}:${account_id}:${KMS_ALIAS}"

# shellcheck disable=SC2312  # json_string only quotes a set value with jq
pod_filter="$(printf '
  .metadata.namespace = %s
  | .spec.containers[0].image = %s
  | (.spec.containers[0].env[] | select(.name == "AWS_REGION").value) = %s
  | (.spec.containers[0].env[] | select(.name == "AWS_DEFAULT_REGION").value) = %s
  | (.spec.containers[0].env[] | select(.name == "KMS_KEY_ARN").value) = %s
' "$(json_string "${NAMESPACE}")" \
  "$(json_string "${APP_IMAGE_URI}")" \
  "$(json_string "${AWS_REGION}")" \
  "$(json_string "${AWS_REGION}")" \
  "$(json_string "${kms_alias_arn}")")"
render "${SAMPLE_DIR}/deploy/pod.yaml" "${pod_filter}" "${TMP_DIR}/pod-input-nonce.json"

# The generator resolves the image, so it needs to authenticate to ECR. The token goes
# into a throwaway HOME, never onto a command line.
genpolicy_home="${TMP_DIR}/genpolicy-home"
rm -rf "${genpolicy_home}"
mkdir -p "${genpolicy_home}/.docker"
ecr_token2="$(aws ecr get-login-password)" \
  || die "could not get an ECR authorization token for the policy generator"
[[ -n "${ecr_token2}" ]] || die "the ECR authorization token came back empty"
(
  umask 077
  printf 'AWS:%s' "${ecr_token2}" | base64 | tr -d '\r\n' \
    | jq -Rn --arg registry "${registry}" '{auths: {($registry): {auth: input}}}' \
      >"${genpolicy_home}/.docker/config.json"
)
unset ecr_token2
jq -e --arg registry "${registry}" --arg prefix "QVdTOg" '
  .auths[$registry].auth
  | type == "string" and length > 0
    and . != "QVdTOg==" and (length > ($prefix | length) + 2)
' "${genpolicy_home}/.docker/config.json" >/dev/null \
  || die "could not write the registry credentials the policy generator needs"

HOME="${genpolicy_home}" "${GENPOLICY}" \
  --profile "${PROFILE}" --with-pod-identity \
  --output-file-b64 "${TMP_DIR}/policy.b64" \
  "${TMP_DIR}/pod-input-nonce.json" | tee "${TMP_DIR}/genpolicy.log"

predicted_pcr17="$(read_predicted_pcr17 "${TMP_DIR}/genpolicy.log")"
[[ "${predicted_pcr17}" =~ ^[0123456789abcdef]{96}$ ]] \
  || die "could not read a predicted PCR17 from the generator's output (${TMP_DIR}/genpolicy.log)"

zero_pcr17="$(printf '0%.0s' {1..96})"
[[ "${predicted_pcr17}" != "${zero_pcr17}" ]] \
  || die "the predicted PCR17 is all zeros, which is the value that means 'no sandbox can match'"
state_put PREDICTED_PCR17 "${predicted_pcr17}"
echo "  predicted PCR17: ${predicted_pcr17}"

# Decode the envelope so the policy can be read.
base64 --decode <"${TMP_DIR}/policy.b64" >"${TMP_DIR}/policy.raw"
if gzip -t "${TMP_DIR}/policy.raw" >/dev/null 2>&1; then
  gzip -dc "${TMP_DIR}/policy.raw" >"${TMP_DIR}/policy.json"
else
  cp "${TMP_DIR}/policy.raw" "${TMP_DIR}/policy.json"
fi
jq -e '(.version | type) == "number" and (.admission_policy | type) == "string"
       and (.runtime_policy | type) == "string"' "${TMP_DIR}/policy.json" >/dev/null \
  || die "the generated policy envelope has an unexpected schema"

# The image pin must sit under the CreateContainer permit, not just mentioned in a comment.
# shellcheck disable=SC2312  # a failed jq leaves create_pin empty, which the check below rejects
create_pin="$(awk '
  /^[[:space:]]*permit\(/ { rule = "permit"; which = ""; next }
  /^[[:space:]]*forbid\(/ { rule = "forbid"; which = ""; next }
  /^[[:space:]]*action == Agent::Action::"CreateContainer"/ { which = "create"; next }
  /^[[:space:]]*context\.image_ref == "/ {
    if (rule == "permit" && which == "create" && !seen) {
      line = $0
      sub(/^[^"]*"/, "", line); sub(/".*$/, "", line)
      print line; seen = 1
    }
  }' <<<"$(jq -r '.admission_policy' "${TMP_DIR}/policy.json")")"
[[ "${create_pin}" == "${APP_IMAGE_URI}" ]] \
  || die "the generated policy pins '${create_pin}' under its CreateContainer permit, not ${APP_IMAGE_URI}; read ${TMP_DIR}/policy.json"
echo "  image digest pinned under CreateContainer permit: ${create_pin}"

# -------------------------------------------------------------------- 5/8 IAM role
echo "== 5/8 create the pod's IAM role =="

jq --arg c "${CLUSTER_NAME}" --arg n "${NAMESPACE}" --arg s "${SERVICE_ACCOUNT}" '
  del(._comment)
  | .Statement[0].Condition.StringEquals["aws:RequestTag/eks-cluster-name"] = $c
  | .Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-namespace"] = $n
  | .Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-service-account"] = $s
' "${TRUST_POLICY_TEMPLATE}" >"${TMP_DIR}/role-trust-policy.json"

role_json=""
role_rc=0
# shellcheck disable=SC2310  # the exit code is captured in role_rc and checked next
role_json="$(lookup NoSuchEntity iam get-role --role-name "${ROLE_NAME}" \
  --query 'Role' --output json)" || role_rc=$?
stop_if_undetermined "${role_rc}" "the IAM role ${ROLE_NAME}"
if [[ "${role_rc}" == 0 ]]; then
  # shellcheck disable=SC2312  # a failed lookup yields an empty tag, which require_managed_by rejects
  role_tag="$(tag_or_empty "$(aws iam list-role-tags --role-name "${ROLE_NAME}" \
    --query "Tags[?Key=='ManagedBy'].Value | [0]" --output text)")"
  require_managed_by "the IAM role ${ROLE_NAME}" "${role_tag}"
  IAM_ROLE_ARN="$(jq -r '.Arn' <<<"${role_json}")"
  aws iam update-assume-role-policy --role-name "${ROLE_NAME}" \
    --policy-document "file://${TMP_DIR}/role-trust-policy.json"
  echo "  reusing IAM role ${ROLE_NAME}"
  state_put IAM_CREATED false
else
  IAM_ROLE_ARN="$(aws iam create-role --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "file://${TMP_DIR}/role-trust-policy.json" \
    --description "EKS Pod Identity role for the reproducible-build sample; no identity policies by design" \
    --tags "Key=ManagedBy,Value=${MANAGED_BY}" \
    --query 'Role.Arn' --output text)"
  echo "  created IAM role ${IAM_ROLE_ARN}"
  state_put IAM_CREATED true
fi
IAM_ROLE_ID="$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.RoleId' --output text)"
[[ -n "${IAM_ROLE_ID}" && "${IAM_ROLE_ID}" != "None" ]] \
  || die "could not read the unique id of the role ${ROLE_NAME}"
state_put ROLE_NAME "${ROLE_NAME}"
state_put IAM_ROLE_ARN "${IAM_ROLE_ARN}"
state_put IAM_ROLE_ID "${IAM_ROLE_ID}"

inline_count="$(aws iam list-role-policies --role-name "${ROLE_NAME}" \
  --query 'length(PolicyNames)' --output text)"
attached_count="$(aws iam list-attached-role-policies --role-name "${ROLE_NAME}" \
  --query 'length(AttachedPolicies)' --output text)"
[[ "${inline_count}" == "0" && "${attached_count}" == "0" ]] \
  || die "the role ${ROLE_NAME} carries identity policies (${inline_count} inline, ${attached_count} attached). The KMS key policy is meant to be its only grant, so an identity policy could allow kms:Decrypt with no attestation condition. Remove them, or set a new ROLE_NAME in .env."
echo "  the role has no identity policies (0 inline, 0 attached)"

# ---------------------------------------------------------------------- 6/8 KMS key
echo "== 6/8 create the KMS key =="

ensure_gated_key "${KMS_ALIAS}" "${predicted_pcr17}" \
  "Wraps the layer key for the EKS Nitro sandbox reproducible-build sample"
state_put KMS_CREATED "${KMS_CREATED}"
state_put KMS_ALIAS "${KMS_ALIAS}"
state_put KMS_KEY_ID "${KMS_KEY_ID}"
state_put KMS_KEY_ARN "${KMS_KEY_ARN}"
state_put KEY_ARN "${KMS_KEY_ARN}"
echo "  the gate releases the key only to this measurement"
sleep "${KMS_POLICY_PROPAGATION_WAIT_SECONDS:-15}"

# -------------------------------------------- 7/8 namespace, service account, assoc
echo "== 7/8 create the namespace, the service account and the association =="

# shellcheck disable=SC2312  # json_string only quotes a set value with jq
render "${SAMPLE_DIR}/deploy/namespace.yaml" \
  ".metadata.name = $(json_string "${NAMESPACE}")" "${TMP_DIR}/rendered-namespace.json"
# shellcheck disable=SC2312  # json_string only quotes a set value with jq
render "${SAMPLE_DIR}/deploy/service-account.yaml" \
  ".metadata.namespace = $(json_string "${NAMESPACE}")" "${TMP_DIR}/rendered-service-account.json"
# shellcheck disable=SC2312  # json_string only quotes a set value with jq
render "${SAMPLE_DIR}/deploy/service.yaml" \
  ".metadata.namespace = $(json_string "${NAMESPACE}")" "${TMP_DIR}/rendered-service.json"

ns_exists=""
ns_label=""
# shellcheck disable=SC2310  # a failed lookup takes the else branch and stops
if ns_exists="$(kc get namespace "${NAMESPACE}" --ignore-not-found -o name 2>/dev/null)" \
  && ns_label="$(kc get namespace "${NAMESPACE}" --ignore-not-found \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"; then
  :
else
  die "could not determine whether namespace ${NAMESPACE} exists (kubectl lookup failed); created nothing in the cluster"
fi
if [[ -z "${ns_exists}" ]]; then
  kc apply -f "${TMP_DIR}/rendered-namespace.json"
  state_put NAMESPACE_CREATED true
elif [[ "${ns_label}" != "${MANAGED_BY}" ]]; then
  die "namespace ${NAMESPACE} already exists and is not this sample's (managed-by='${ns_label}'); created nothing in it. Delete it, or set a new NAMESPACE in .env."
else
  echo "  reusing namespace ${NAMESPACE} (carries this sample's managed-by label)"
  state_put NAMESPACE_CREATED false
fi
kc apply -f "${TMP_DIR}/rendered-service-account.json"

assoc_id="$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" \
  --namespace "${NAMESPACE}" --service-account "${SERVICE_ACCOUNT}" \
  --query 'associations[0].associationId' --output text)"
if [[ "${assoc_id}" == "None" || -z "${assoc_id}" ]]; then
  assoc_id="$(aws eks create-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
    --namespace "${NAMESPACE}" --service-account "${SERVICE_ACCOUNT}" --role-arn "${IAM_ROLE_ARN}" \
    --tags "ManagedBy=${MANAGED_BY}" \
    --query 'association.associationId' --output text)"
  echo "  created Pod Identity association ${assoc_id}"
  state_put ASSOCIATION_CREATED true
else
  assoc_json="$(aws eks describe-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
    --association-id "${assoc_id}" --query 'association' --output json)"
  # shellcheck disable=SC2312  # a failed lookup yields an empty tag, which require_managed_by rejects
  require_managed_by "the Pod Identity association for ${NAMESPACE}/${SERVICE_ACCOUNT}" \
    "$(jq -r '.tags.ManagedBy // ""' <<<"${assoc_json}")"
  assoc_role="$(jq -r '.roleArn' <<<"${assoc_json}")"
  [[ "${assoc_role}" == "${IAM_ROLE_ARN}" ]] \
    || die "a Pod Identity association for ${NAMESPACE}/${SERVICE_ACCOUNT} already points at ${assoc_role}, not ${IAM_ROLE_ARN}; changed nothing"
  echo "  reusing Pod Identity association ${assoc_id}"
  state_put ASSOCIATION_CREATED false
fi
state_put SERVICE_ACCOUNT "${SERVICE_ACCOUNT}"
state_put ASSOCIATION_ID "${assoc_id}"

# ----------------------------------------------------------------------- 8/8 pods
if [[ "${no_pods}" == true ]]; then
  echo
  echo "Set up, no pods started. The policy is in ${TMP_DIR}/policy.json."
  exit 0
fi

echo "== 8/8 run the pods and the Service =="

# Render the pod for apply. KMS_KEY_ARN uses the same alias ARN that genpolicy measured.
render "${SAMPLE_DIR}/deploy/pod.yaml" "${pod_filter}" "${TMP_DIR}/pod-input.json"

policy_b64="$(tr -d '\r\n' <"${TMP_DIR}/policy.b64")"
jq --arg name "${POD_NAME}" --arg policy "${policy_b64}" '
  .metadata.name = $name
  | .metadata.annotations["sandbox.amazonaws.com/policy"] = $policy
' "${TMP_DIR}/pod-input.json" >"${TMP_DIR}/rendered-pod.json"

# Replace rather than apply: a pod's policy annotation is immutable.
kc delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=true --timeout=5m >/dev/null
kc apply -f "${TMP_DIR}/rendered-pod.json"
kc apply -f "${TMP_DIR}/rendered-service.json"

# Wait for a node assignment, then start the plain pod pinned to that node.
node_name=""
for _ in $(seq 180); do
  # shellcheck disable=SC2310  # not scheduled yet is retried by the loop
  node_name="$(kc get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  if [[ -n "${node_name}" ]]; then break; fi
  sleep 5
done
[[ -n "${node_name}" ]] || die "the approved pod was not scheduled to a node within 15 minutes"
state_put NODE_NAME "${node_name}"
echo "  the approved pod is on ${node_name}"

# shellcheck disable=SC2312  # json_string only quotes a set value with jq
render "${SAMPLE_DIR}/deploy/plain-pod.yaml" "$(printf '
  .metadata.namespace = %s
  | .spec.nodeName = %s
  | .spec.containers[0].image = %s
' "$(json_string "${NAMESPACE}")" "$(json_string "${node_name}")" "$(json_string "${APP_IMAGE_URI}")")" \
  "${TMP_DIR}/rendered-plain-pod.json"
kc delete pod "${PLAIN_POD_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=true --timeout=5m >/dev/null
kc apply -f "${TMP_DIR}/rendered-plain-pod.json"

# Wait for the confidential pod to become Ready (the service starts serving once it is).
echo "  waiting for the approved pod to become Ready..."
# shellcheck disable=SC2310  # the if handles a failed wait
if ! kc wait pod "${POD_NAME}" -n "${NAMESPACE}" --for=condition=Ready --timeout=10m 2>/dev/null; then
  kc get pod "${POD_NAME}" -n "${NAMESPACE}" -o wide 2>/dev/null || true
  kc logs "${POD_NAME}" -n "${NAMESPACE}" -c main 2>/dev/null | redact || true
  die "the approved pod did not become Ready within 10 minutes"
fi
echo "  the approved pod is Ready"

# Wait for the plain pod to be Running.
echo "  waiting for the plain pod to be Running..."
# shellcheck disable=SC2310  # the if handles a failed wait
if ! kc wait pod "${PLAIN_POD_NAME}" -n "${NAMESPACE}" --for=condition=Ready --timeout=5m 2>/dev/null; then
  kc get pod "${PLAIN_POD_NAME}" -n "${NAMESPACE}" -o wide 2>/dev/null || true
  die "the plain pod did not become Running within 5 minutes"
fi
echo "  the plain pod is Running"

# The sandbox pod's readings come from GET /readings: production denies its logs.
start_port_forward "pod/${POD_NAME}" 18079 "${TMP_DIR}/readings-pf.log" 60
curl -sS --fail "http://127.0.0.1:18079/readings" -o "${TMP_DIR}/readings.json" \
  || die "GET /readings failed; could not read the sandbox pod's readings"
stop_port_forward
# shellcheck disable=SC2310,SC2312  # a missing plain-pod reading prints (no readings)
paste \
  <(jq -r 'to_entries[] | "reading \(.key)=\(.value)"' "${TMP_DIR}/readings.json") \
  <(kc logs "${PLAIN_POD_NAME}" -n "${NAMESPACE}" -c main 2>/dev/null | grep '^reading ' || echo '(no readings)') \
  | tee "${TMP_DIR}/readings.log"

# Zero operator access: logs and exec on the sandbox pod are refused by its policy.
echo "== the operator cannot read logs or run commands in the approved pod =="
assert_operator_refused "${POD_NAME}" "${NAMESPACE}"

echo
echo "Both pods are running. Next:"
echo "  ./scripts/decrypt.sh   # PUT /decrypt through a port-forward to the Service"
echo "  the generated policy:  less ${TMP_DIR}/policy.json"
echo "  the live key policy:   less ${TMP_DIR}/kms-key-policy.live.json"
echo "  tear down:             ./scripts/clean.sh"
