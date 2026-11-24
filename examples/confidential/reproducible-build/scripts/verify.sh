#!/usr/bin/env bash
# Rebuild the image, compare with ECR, predict PCR17, compare with the live KMS key
# policy. An outside verifier: reads IMAGE_REPO, KEY_ARN and AWS_REGION from .env or the
# environment; does not read state.env. Without IMAGE_REPO it looks up the ECR repository
# REPO_NAME, and without KEY_ARN the key behind KMS_ALIAS (the names setup.sh uses).
#
# Read-only AWS calls this script makes:
#   ecr:DescribeRepositories  -- the repository URI, when IMAGE_REPO is not set
#   kms:DescribeKey  -- resolve KEY_ARN (or KMS_ALIAS) to the key, and check it is enabled
#   ecr:GetAuthorizationToken  -- auth for the policy generator's ECR pull
#   ecr:DescribeImages  -- confirm the rebuilt digest and its v1-<digest12> tag are in ECR
#   ecr:BatchGetImage  -- fetch manifests when tag digest differs from rebuilt
#   kms:ListAliases  -- find the alias ARN for the KMS key
#   kms:GetKeyPolicy  -- read the live gate on the KMS key
#
# Exit codes:
#   0  verified
#   1  a comparison failed (see the message)
#   2  a lookup or read failed; nothing was determined
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAMPLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SAMPLE_DIR}/../../.." && pwd)"
TMP_DIR="${REPO_ROOT}/tmp/reproducible-build/verify"

# --- settings ---
if [[ -f "${SAMPLE_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null  # path is dynamic via SAMPLE_DIR
  . "${SAMPLE_DIR}/.env"
  set +a
fi

IMAGE_REPO="${IMAGE_REPO:-}"
KEY_ARN="${KEY_ARN:-}"
REPO_NAME="${REPO_NAME:-reproducible-build}"
KMS_ALIAS="${KMS_ALIAS:-alias/reproducible-build-sample}"
AWS_REGION="${AWS_REGION:-}"
NAMESPACE="${NAMESPACE:-reproducible-build}"
GENPOLICY="${GENPOLICY:-eks-nitro-sandbox-genpolicy}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"

# shellcheck source=examples/confidential/reproducible-build/scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

# --- helpers ---

json_string() { jq -n --arg v "$1" '$v'; }

render() { # render <manifest> <jq-filter> <out>
  kubectl create --dry-run=client --validate=false -o json -f "$1" | jq "$2" >"$3"
}

# Saves manifests for two digests to tmp/mismatch/ and exits 1.
#   save_manifests_and_fail <rebuilt_digest> <ecr_digest> <repo_name>
save_manifests_and_fail() {
  local rebuilt="${1}" ecr_digest="${2}" repo_name="${3}"
  mkdir -p "${TMP_DIR}/mismatch"
  printf '%s\n' "${rebuilt}" >"${TMP_DIR}/mismatch/rebuilt-digest.txt"
  printf '%s\n' "${ecr_digest}" >"${TMP_DIR}/mismatch/ecr-tag-digest.txt"
  local rm_text tt_text rm_compact tt_compact first_diff
  rm_text="$(aws ecr batch-get-image --repository-name "${repo_name}" \
    --image-ids "imageDigest=${rebuilt}" \
    --query 'images[0].imageManifest' --output text 2>/dev/null || echo '{}')"
  tt_text="$(aws ecr batch-get-image --repository-name "${repo_name}" \
    --image-ids "imageDigest=${ecr_digest}" \
    --query 'images[0].imageManifest' --output text 2>/dev/null || echo '{}')"
  printf '%s\n' "${rm_text}" >"${TMP_DIR}/mismatch/rebuilt-manifest.json"
  printf '%s\n' "${tt_text}" >"${TMP_DIR}/mismatch/tag-manifest.json"
  # Extract compact JSON separately to avoid masking return values inside --argjson.
  rm_compact="$(jq -c . <<<"${rm_text}" 2>/dev/null || echo 'null')"
  tt_compact="$(jq -c . <<<"${tt_text}" 2>/dev/null || echo 'null')"
  first_diff="$(jq -rn \
    --argjson rm "${rm_compact}" \
    --argjson tt "${tt_compact}" \
    '($rm.layers // []) as $rl
     | ($tt.layers // [])
     | to_entries[]
     | select(.value.digest != ($rl[.key].digest // ""))
     | .value.digest' \
    2>/dev/null | head -1 || echo "(could not compare layers)")"
  echo "ERROR: rebuilt digest ${rebuilt} differs from ECR tag digest ${ecr_digest}" >&2
  echo "  first differing layer: ${first_diff}" >&2
  echo "  manifests: ${TMP_DIR}/mismatch/" >&2
  exit 1
}

# --- preflight ---
[[ -n "${AWS_REGION}" ]] \
  || die "AWS_REGION is not set; add AWS_REGION=<region> to .env"
export AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"

for c in aws jq kubectl "${CONTAINER_RUNTIME}" "${GENPOLICY}"; do
  command -v "${c}" >/dev/null 2>&1 || die "${c} is required but not found"
done

if [[ -z "${IMAGE_REPO}" ]]; then
  IMAGE_REPO="$(aws ecr describe-repositories --repository-names "${REPO_NAME}" \
    --query 'repositories[0].repositoryUri' --output text)" || {
    echo "ERROR: IMAGE_REPO is not set and ECR repository ${REPO_NAME} could not be read" >&2
    exit 2
  }
fi

# KMS takes a key ID, key ARN, alias name or alias ARN here, but GetKeyPolicy and
# ListAliases take only a key ID or ARN, so resolve once. A key an earlier clean up
# scheduled for deletion still resolves, and is not the gate the running pod uses.
key_json="$(aws kms describe-key --key-id "${KEY_ARN:-${KMS_ALIAS}}" \
  --query 'KeyMetadata.[Arn,KeyState]' --output text)" || {
  echo "ERROR: could not read the KMS key ${KEY_ARN:-${KMS_ALIAS}}" >&2
  exit 2
}
read -r key_arn key_state <<<"${key_json}"
[[ "${key_state}" == Enabled ]] \
  || die "the KMS key ${key_arn} is ${key_state}, not Enabled; set KEY_ARN to the key setup.sh gated, or unset it to use ${KMS_ALIAS}"

mkdir -p "${TMP_DIR}/build" "${TMP_DIR}/mismatch" "${TMP_DIR}/genpolicy"
BUILD_DIR="${TMP_DIR}/build"

# ---------------------------------------------------------------- 1/4 rebuild
echo "== step 1/4 rebuild the image =="

# Remove a stale OCI layout from a previous run so build.sh does not refuse the directory.
rm -rf "${BUILD_DIR}/oci" "${BUILD_DIR}/digest" "${BUILD_DIR}/manifest.json" "${BUILD_DIR}/config.json"

"${SCRIPT_DIR}/build.sh" "${SAMPLE_DIR}" "${BUILD_DIR}"
rebuilt="$(cat "${BUILD_DIR}/digest")"
[[ "${rebuilt}" == sha256:* ]] \
  || die "build.sh did not write a valid sha256 digest to ${BUILD_DIR}/digest"
echo "  rebuilt: ${rebuilt}"

# -------------------------------------------------------------- 2/4 compare ECR
echo "== step 2/4 compare with ECR =="

# IMAGE_REPO is the full ECR repository URI; the name is everything after the registry host,
# so a slash-delimited name such as team/reproducible-build stays whole.
repo_name="${IMAGE_REPO#*/}"

# Confirm the rebuilt digest is in ECR.
ecr_rc=0
# shellcheck disable=SC2310  # lookup handles its own errors explicitly; set -e suppression inside is intentional
lookup ImageNotFoundException ecr describe-images \
  --repository-name "${repo_name}" \
  --image-ids "imageDigest=${rebuilt}" \
  --output json >/dev/null || ecr_rc=$?
if [[ "${ecr_rc}" == 1 ]]; then
  echo "ERROR: rebuilt digest ${rebuilt} is not in ECR repository ${repo_name}" >&2
  exit 1
fi
[[ "${ecr_rc}" == 0 ]] || exit 2

# Check the v1-<digest12> tag, which embeds the first 12 hex digits of the pushed digest, so
# it is predictable from the rebuilt digest. A missing tag fails verification.
digest12="${rebuilt:7:12}"
expected_tag="v1-${digest12}"
tag_rc=0
# shellcheck disable=SC2310  # lookup handles its own errors explicitly; set -e suppression inside is intentional
tag_json="$(lookup ImageNotFoundException ecr describe-images \
  --repository-name "${repo_name}" \
  --image-ids "imageTag=${expected_tag}" \
  --output json)" || tag_rc=$?
if [[ "${tag_rc}" == 2 ]]; then
  exit 2
elif [[ "${tag_rc}" == 1 ]]; then
  echo "ERROR: the expected tag ${expected_tag} is not in ECR repository ${repo_name}" >&2
  exit 1
else
  tagged_digest="$(jq -r '.imageDetails[0].imageDigest' <<<"${tag_json}")"
  if [[ "${tagged_digest}" != "${rebuilt}" ]]; then
    save_manifests_and_fail "${rebuilt}" "${tagged_digest}" "${repo_name}"
  fi
  echo "  ECR tag ${expected_tag} digest matches rebuilt: ${tagged_digest}"
fi

# ----------------------------------------------------------- 3/4 predict PCR17
echo "== step 3/4 predict PCR17 =="

# The pod manifest carries the KMS alias ARN so the Cedar policy measures the alias,
# matching exactly what setup.sh passed to genpolicy. If KEY_ARN is an alias ARN already,
# use it directly; otherwise look up the alias.
if [[ "${KEY_ARN}" == *":alias/"* ]]; then
  kms_alias_arn="${KEY_ARN}"
else
  kms_alias_arn="$(aws kms list-aliases --key-id "${key_arn}" --output json 2>/dev/null \
    | jq -r '[.Aliases[] | select(.AliasName | startswith("alias/aws/") | not)
              | .AliasArn] | .[0] // empty')" \
    || {
      echo "ERROR: could not list aliases for ${key_arn}" >&2
      exit 2
    }
  [[ -n "${kms_alias_arn}" && "${kms_alias_arn}" != "None" ]] \
    || die "no customer-managed alias found for ${key_arn}; the pod env must carry the alias ARN"
fi

PROFILE="${SAMPLE_DIR}/deploy/production-profile.yaml"
genpolicy_dir="${TMP_DIR}/genpolicy"
genpolicy_home="${genpolicy_dir}/home"
mkdir -p "${genpolicy_home}/.docker"

# Auth for the policy generator's ECR pull.
registry="${IMAGE_REPO%%/*}"
ecr_token="$(aws ecr get-login-password)" \
  || {
    echo "ERROR: could not get an ECR authorization token" >&2
    exit 2
  }
[[ -n "${ecr_token}" ]] \
  || {
    echo "ERROR: the ECR authorization token came back empty" >&2
    exit 2
  }
(
  umask 077
  printf 'AWS:%s' "${ecr_token}" | base64 | tr -d '\r\n' \
    | jq -Rn --arg r "${registry}" '{auths:{($r):{auth:input}}}' \
      >"${genpolicy_home}/.docker/config.json"
)
unset ecr_token

# Build the jq filter that renders pod.yaml. Extract json_string calls into separate
# variables so each return value is individually tracked rather than nested inside printf.
ns_json="$(json_string "${NAMESPACE}")"
img_json="$(json_string "${IMAGE_REPO}@${rebuilt}")"
region_json="$(json_string "${AWS_REGION}")"
alias_json="$(json_string "${kms_alias_arn}")"
pod_filter="$(printf '
  .metadata.namespace = %s
  | .spec.containers[0].image = %s
  | (.spec.containers[0].env[] | select(.name == "AWS_REGION").value) = %s
  | (.spec.containers[0].env[] | select(.name == "AWS_DEFAULT_REGION").value) = %s
  | (.spec.containers[0].env[] | select(.name == "KMS_KEY_ARN").value) = %s
' "${ns_json}" "${img_json}" "${region_json}" "${region_json}" "${alias_json}")"

render "${SAMPLE_DIR}/deploy/pod.yaml" "${pod_filter}" "${genpolicy_dir}/pod-input.json"

HOME="${genpolicy_home}" "${GENPOLICY}" \
  --profile "${PROFILE}" --with-pod-identity \
  --output-file-b64 "${genpolicy_dir}/policy.b64" \
  "${genpolicy_dir}/pod-input.json" | tee "${genpolicy_dir}/genpolicy.log"

predicted_pcr17="$(read_predicted_pcr17 "${genpolicy_dir}/genpolicy.log")"
[[ -n "${predicted_pcr17}" ]] \
  || {
    echo "ERROR: could not read PCR17 from ${genpolicy_dir}/genpolicy.log" >&2
    exit 2
  }
require_hex96 "${predicted_pcr17}" "predicted PCR17"
echo "  predicted PCR17: ${predicted_pcr17}"

# ------------------------------------------------------- 4/4 compare key policy
echo "== step 4/4 compare PCR17 with the live KMS key policy =="

live_policy="$(aws kms get-key-policy --key-id "${key_arn}" --policy-name default \
  --query Policy --output text)" \
  || {
    echo "ERROR: could not read the key policy of ${key_arn}" >&2
    exit 2
  }
printf '%s\n' "${live_policy}" | jq . >"${TMP_DIR}/kms-key-policy.live.json"

policy_pcr17="$(jq -r '
  .Statement[] | select(.Sid == "AttestedDecryptOnly")
  | .Condition.StringEqualsIgnoreCase["kms:RecipientAttestation:PCR17"] // empty
' "${TMP_DIR}/kms-key-policy.live.json")"
[[ -n "${policy_pcr17}" ]] \
  || {
    echo "ERROR: no PCR17 found in AttestedDecryptOnly of ${key_arn} policy" >&2
    exit 2
  }
require_hex96 "${policy_pcr17}" "key-policy PCR17"

# Extract the principal the gate carries. An outside verifier has no state.env, so it
# takes the ARN (or unique ID) stored in the live policy and passes it as both $role and
# $roleid: whichever form KMS stored, one will match. The goal is to check the measurement
# and the gate shape, not who the principal is.
gate_principal="$(jq -r '
  .Statement[] | select(.Sid == "AttestedDecryptOnly")
  | (.Principal.AWS | if type == "array" then .[0] else . end)
' "${TMP_DIR}/kms-key-policy.live.json")"
[[ -n "${gate_principal}" ]] \
  || {
    echo "ERROR: could not read the principal from AttestedDecryptOnly" >&2
    exit 2
  }

# shellcheck disable=SC2016  # jq --arg values, not shell expansions
if ! jq -e \
  --arg role "${gate_principal}" \
  --arg roleid "${gate_principal}" \
  --arg pcr17 "${predicted_pcr17}" \
  --from-file "${SCRIPT_DIR}/gate.jq" \
  "${TMP_DIR}/kms-key-policy.live.json" >/dev/null; then
  echo "ERROR: gate check failed" >&2
  echo "  predicted PCR17:  ${predicted_pcr17}" >&2
  echo "  key-policy PCR17: ${policy_pcr17}" >&2
  echo "  live policy:      ${TMP_DIR}/kms-key-policy.live.json" >&2
  exit 1
fi

# -------------------------------------------------------------------- summary
echo
echo "rebuilt digest:    ${rebuilt}"
echo "found in ECR:      ${rebuilt}"
echo "predicted PCR17:   ${predicted_pcr17}"
echo "key-policy PCR17:  ${policy_pcr17}"
echo "verified"
