#!/usr/bin/env bash
# Show what the debug mode adds and what it cannot reach.
#
#   ./scripts/debug.sh           # build, gate, run and check the debug pod
#   ./scripts/debug.sh --delete  # delete the debug pod (the key is left for clean.sh)
#
# Builds the debug image (the production image plus busybox), generates its Cedar policy
# with deploy/debug-profile.yaml (exec allowed, logs allowed), and gates a separate debug
# KMS key on the debug pod's own PCR17. Then shows that the operator can read the pod's
# logs and run a shell in it, that it decrypts a throwaway secret with the debug key, and
# that the production ciphertext is refused: KMS evaluates the production key's policy,
# which names only the production PCR17.
#
# Needs ./scripts/setup.sh to have run: it reads the state file setup.sh wrote.
set -euo pipefail

DEBUG_POD_NAME="reproducible-build-debug"
LOCAL_PORT=18082

main() {
  if [[ $# -gt 1 || (-n "${1:-}" && "$1" != "--delete") ]]; then
    echo "unknown argument: $*" >&2
    exit 2
  fi

  local SCRIPT_DIR sample_dir shared_dir repo_root TMP_DIR debug_dir state_file profile
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  sample_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"
  shared_dir="$(cd "${sample_dir}/../_shared" && pwd)"
  repo_root="$(cd "${sample_dir}/../../.." && pwd)"
  state_file="${repo_root}/tmp/reproducible-build/run/state.env"
  debug_dir="${repo_root}/tmp/reproducible-build/debug"
  TMP_DIR="${debug_dir}" # ensure_gated_key writes the rendered key policy here
  profile="${sample_dir}/deploy/debug-profile.yaml"
  KEY_POLICY_TEMPLATE="${shared_dir}/kms-key-policy.json"

  if [[ -f "${sample_dir}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    . "${sample_dir}/.env"
    set +a
  fi
  local genpolicy container_runtime debug_alias
  genpolicy="${GENPOLICY:-eks-nitro-sandbox-genpolicy}"
  container_runtime="${CONTAINER_RUNTIME:-docker}"
  debug_alias="${DEBUG_KMS_ALIAS:-alias/reproducible-build-debug}"
  KUBE_CONTEXT="${KUBE_CONTEXT:-}"

  [[ -f "${state_file}" ]] || {
    echo "ERROR: no ${state_file}; run ./scripts/setup.sh first" >&2
    exit 1
  }
  set -a
  # shellcheck source=/dev/null
  . "${state_file}"
  set +a
  # shellcheck source=examples/confidential/reproducible-build/scripts/lib.sh
  . "${SCRIPT_DIR}/lib.sh"
  export AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"

  local ns_rc=0
  # shellcheck disable=SC2310  # capture pattern; set -e disabled in || is intentional
  check_ns "${NAMESPACE:-}" || ns_rc=$?
  if [[ "${1:-}" == "--delete" ]]; then
    case "${ns_rc}" in
      0) ;;
      1) echo "Namespace ${NAMESPACE:-} is not there; nothing to delete." && exit 0 ;;
      2) exit 2 ;;
      *) die "namespace ${NAMESPACE:-} is not this sample's; changed nothing in it" ;;
    esac
    kc delete pod "${DEBUG_POD_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=true --timeout=5m
    exit 0
  fi
  case "${ns_rc}" in
    0) ;;
    1) die "namespace ${NAMESPACE:-} is not there; run ./scripts/setup.sh first" ;;
    2) exit 2 ;;
    *) die "namespace ${NAMESPACE:-} is not this sample's; changed nothing in it" ;;
  esac

  local c v
  for c in aws jq kubectl openssl curl base64 shasum "${container_runtime}"; do
    command -v "${c}" >/dev/null 2>&1 || die "${c} is required"
  done
  command -v "${genpolicy}" >/dev/null 2>&1 || die "${genpolicy} is not on PATH"
  for v in IMAGE_DIGEST PREDICTED_PCR17 KMS_KEY_ARN KMS_KEY_ID KMS_ALIAS IAM_ROLE_ARN IAM_ROLE_ID IMAGE_REPO; do
    [[ -n "${!v:-}" ]] || die "${v} not found in ${state_file}; run ./scripts/setup.sh first"
  done
  # ensure_gated_key overwrites KMS_KEY_ID/KMS_KEY_ARN, so keep the production key's.
  local prod_key_id="${KMS_KEY_ID}" prod_key_arn="${KMS_KEY_ARN}"
  [[ "${debug_alias}" =~ ^alias/[A-Za-z0-9/_-]+$ ]] || die "DEBUG_KMS_ALIAS '${debug_alias}' is not a KMS alias name"
  # shellcheck disable=SC2154  # KMS_ALIAS sourced from state.env via set -a above
  [[ "${debug_alias}" != "${KMS_ALIAS}" ]] \
    || die "DEBUG_KMS_ALIAS equals KMS_ALIAS; the debug key must be a separate key"

  local account_id registry
  account_id="$(aws sts get-caller-identity --query Account --output text)" \
    || die "could not read the AWS account; check your credentials"
  registry="${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  rm -rf "${debug_dir}"
  mkdir -p "${debug_dir}"

  # --- 1/6 build and push the debug image ---
  echo "== 1/6 build and push the debug image (the production image plus busybox) =="
  local auth_file ecr_token debug_digest
  auth_file="${debug_dir}/auth.json"
  ecr_token="$(aws ecr get-login-password)" || die "could not get an ECR authorization token"
  [[ -n "${ecr_token}" ]] || die "the ECR authorization token came back empty"
  (
    umask 077
    printf 'AWS:%s' "${ecr_token}" | base64 | tr -d '\r\n' \
      | jq -Rn --arg r "${registry}" '{auths:{($r):{auth:input}}}' >"${auth_file}"
  )
  unset ecr_token
  # shellcheck disable=SC2154  # IMAGE_REPO, IMAGE_DIGEST sourced from state.env via set -a above
  IMAGE_ATTR=image-debug "${SCRIPT_DIR}/build.sh" "${sample_dir}" "${debug_dir}/out" \
    --push "${IMAGE_REPO}:v1-debug-@DIGEST12@" "${auth_file}" --tag-from-digest
  debug_digest="$(cat "${debug_dir}/out/digest")"
  [[ "${debug_digest}" == sha256:* ]] || die "build.sh did not write a digest to ${debug_dir}/out/digest"
  # shellcheck disable=SC2154  # IMAGE_DIGEST sourced from state.env via set -a above
  [[ "${debug_digest}" != "${IMAGE_DIGEST}" ]] \
    || die "the debug image has the production digest, so the debug layer is missing"
  echo "  production digest: ${IMAGE_DIGEST}"
  echo "  debug      digest: ${debug_digest}"

  # --- 2/6 generate the debug policy and read its PCR17 ---
  echo "== 2/6 generate the debug policy and confirm its PCR17 differs =="
  local debug_alias_arn pod_filter
  debug_alias_arn="arn:aws:kms:${AWS_REGION}:${account_id}:${debug_alias}"
  # shellcheck disable=SC2312  # json_string wraps jq; a failure is caught by set -e
  pod_filter="$(printf '
    .metadata.namespace = %s
    | .metadata.name = %s
    | .metadata.labels["app.kubernetes.io/name"] = %s
    | .spec.containers[0].image = %s
    | (.spec.containers[0].env[] | select(.name == "AWS_REGION").value) = %s
    | (.spec.containers[0].env[] | select(.name == "AWS_DEFAULT_REGION").value) = %s
    | (.spec.containers[0].env[] | select(.name == "KMS_KEY_ARN").value) = %s
  ' "$(json_string "${NAMESPACE}")" "$(json_string "${DEBUG_POD_NAME}")" \
    "$(json_string "${DEBUG_POD_NAME}")" "$(json_string "${IMAGE_REPO}@${debug_digest}")" \
    "$(json_string "${AWS_REGION}")" "$(json_string "${AWS_REGION}")" \
    "$(json_string "${debug_alias_arn}")")"
  render "${sample_dir}/deploy/pod.yaml" "${pod_filter}" "${debug_dir}/debug-pod-input.json"

  local genpolicy_home ecr_token2 debug_pcr17
  genpolicy_home="${debug_dir}/genpolicy-home"
  mkdir -p "${genpolicy_home}/.docker"
  ecr_token2="$(aws ecr get-login-password)" || die "could not get an ECR authorization token for the policy generator"
  [[ -n "${ecr_token2}" ]] || die "the ECR authorization token came back empty"
  (
    umask 077
    printf 'AWS:%s' "${ecr_token2}" | base64 | tr -d '\r\n' \
      | jq -Rn --arg r "${registry}" '{auths:{($r):{auth:input}}}' >"${genpolicy_home}/.docker/config.json"
  )
  unset ecr_token2
  HOME="${genpolicy_home}" "${genpolicy}" --profile "${profile}" --with-pod-identity \
    --output-file-b64 "${debug_dir}/debug-policy.b64" \
    "${debug_dir}/debug-pod-input.json" | tee "${debug_dir}/debug-genpolicy.log"
  debug_pcr17="$(read_predicted_pcr17 "${debug_dir}/debug-genpolicy.log")"
  [[ "${debug_pcr17}" =~ ^[0123456789abcdef]{96}$ ]] \
    || die "could not read a predicted PCR17 for the debug pod (${debug_dir}/debug-genpolicy.log)"
  [[ "${debug_pcr17}" =~ [123456789abcdef] ]] || die "the debug PCR17 is all zeros; refusing to gate a key on it"
  # shellcheck disable=SC2154  # PREDICTED_PCR17 sourced from state.env via set -a above
  [[ "${debug_pcr17}" != "${PREDICTED_PCR17}" ]] \
    || die "the debug PCR17 equals the production PCR17, so the production key would be released to the debug pod"
  echo "  production PCR17: ${PREDICTED_PCR17}"
  echo "  debug      PCR17: ${debug_pcr17}"

  # --- 3/6 gate the debug key on the debug PCR17 ---
  echo "== 3/6 gate a separate debug key on the debug PCR17 =="
  ensure_gated_key "${debug_alias}" "${debug_pcr17}" \
    "Debug key for the EKS Nitro sandbox reproducible-build sample; gated on the debug pod"
  [[ "${KMS_KEY_ID}" != "${prod_key_id}" ]] \
    || die "${debug_alias} resolves to the production key; the debug key must be a separate key"
  local debug_key_arn="${KMS_KEY_ARN}"
  sleep "${KMS_POLICY_PROPAGATION_WAIT_SECONDS:-15}"
  echo "  the production key is still gated on the production PCR17:"
  mkdir -p "${debug_dir}/production"
  TMP_DIR="${debug_dir}/production" KMS_KEY_ARN="${prod_key_arn}" verify_key_policy "${PREDICTED_PCR17}"
  echo "  ok: ${KMS_ALIAS} still gated on ${PREDICTED_PCR17}"

  # --- 4/6 run the debug pod ---
  echo "== 4/6 run the debug pod =="
  local policy_b64 existing
  policy_b64="$(tr -d '\r\n' <"${debug_dir}/debug-policy.b64")"
  jq --arg policy "${policy_b64}" '.metadata.annotations["sandbox.amazonaws.com/policy"] = $policy' \
    "${debug_dir}/debug-pod-input.json" >"${debug_dir}/rendered-debug-pod.json"
  # shellcheck disable=SC2310  # capture pattern; set -e disabled in || is intentional
  existing="$(kc get pod "${DEBUG_POD_NAME}" -n "${NAMESPACE}" --ignore-not-found -o name)" \
    || die "could not check whether ${DEBUG_POD_NAME} already exists in ${NAMESPACE}"
  if [[ -n "${existing}" ]]; then
    echo "  removing leftover ${DEBUG_POD_NAME} before this run"
    kc delete pod "${DEBUG_POD_NAME}" -n "${NAMESPACE}" --wait=true --timeout=5m >/dev/null
  fi
  kc apply -f "${debug_dir}/rendered-debug-pod.json"
  # shellcheck disable=SC2310  # ! condition; set -e disabled is intentional
  if ! kc wait pod "${DEBUG_POD_NAME}" -n "${NAMESPACE}" --for=condition=Ready --timeout=10m; then
    kc get pod "${DEBUG_POD_NAME}" -n "${NAMESPACE}" -o wide || true
    die "${DEBUG_POD_NAME} did not become Ready within 10 minutes"
  fi
  # --- 5/6 the operator can read logs and run a shell; the debug key works ---
  echo "== 5/6 debug works: logs, a shell, and a decrypt with the debug key =="
  local logs shell_out attempt
  logs=""
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    # shellcheck disable=SC2310  # capture pattern; set -e disabled in && is intentional
    logs="$(kc logs "${DEBUG_POD_NAME}" -n "${NAMESPACE}" -c main)" && break
    [[ "${attempt}" -ge 12 ]] && die "kubectl logs on the debug pod failed after 60 seconds"
    sleep 5
  done
  grep -q '^reading kernel=' <<<"${logs}" || die "the debug pod's log has no 'reading kernel=' line"
  grep '^reading ' <<<"${logs}" | sed 's/^/  log: /'
  # shellcheck disable=SC2310  # capture pattern; set -e disabled in || is intentional
  shell_out="$(kc exec "${DEBUG_POD_NAME}" -n "${NAMESPACE}" -c main -- sh -c 'id; ls /')" \
    || die "kubectl exec into the debug pod failed"
  grep -q 'uid=65534' <<<"${shell_out}" || die "the debug shell does not run as uid 65534"
  # shellcheck disable=SC2001  # sed is cleaner than bash substitution for multi-line prefixing
  sed 's/^/  sh: /' <<<"${shell_out}"

  (
    umask 077
    # shellcheck disable=SC2312  # openssl rand is standalone; failure exits the subshell
    printf 'debug-%s' "$(openssl rand -hex 8)" >"${debug_dir}/plaintext.txt"
    aws kms encrypt --key-id "${debug_key_arn}" --plaintext "fileb://${debug_dir}/plaintext.txt" \
      --query CiphertextBlob --output text | base64 -d >"${debug_dir}/debug-ciphertext.bin"
    aws kms encrypt --key-id "${prod_key_arn}" \
      --plaintext "fileb://${debug_dir}/plaintext.txt" \
      --query CiphertextBlob --output text | base64 -d >"${debug_dir}/production-ciphertext.bin"
  )

  start_port_forward "pod/${DEBUG_POD_NAME}" "${LOCAL_PORT}" "${debug_dir}/port-forward.log" 60
  local status expected
  status="$(curl -sS -X PUT --data-binary "@${debug_dir}/debug-ciphertext.bin" \
    -H 'Content-Type: application/octet-stream' -o "${debug_dir}/debug-response.json" \
    -w '%{http_code}' "http://127.0.0.1:${LOCAL_PORT}/decrypt")" \
    || {
      echo "ERROR: curl to the debug pod failed; nothing was determined" >&2
      exit 2
    }
  [[ "${status}" == 200 ]] || die "debug decrypt returned HTTP ${status}; see ${debug_dir}/debug-response.json"
  expected="$(shasum -a 256 "${debug_dir}/plaintext.txt" | awk '{print $1}')"
  # shellcheck disable=SC2312  # jq failure exits non-zero; caught by the [[ comparison failing
  [[ "$(jq -r '.sha256' "${debug_dir}/debug-response.json")" == "${expected}" ]] \
    || die "the debug decrypt's sha256 does not match the plaintext"
  echo "  debug ciphertext -> HTTP 200, sha256=${expected}"

  # --- 6/6 the production secret stays out of reach ---
  echo "== 6/6 the production ciphertext is refused to the debug pod =="
  status="$(curl -sS -X PUT --data-binary "@${debug_dir}/production-ciphertext.bin" \
    -H 'Content-Type: application/octet-stream' -o "${debug_dir}/production-response.json" \
    -w '%{http_code}' "http://127.0.0.1:${LOCAL_PORT}/decrypt")" \
    || {
      echo "ERROR: curl to the debug pod failed; nothing was determined" >&2
      exit 2
    }
  stop_port_forward
  case "${status}" in
    403) assert_decrypt_denial "${debug_dir}/production-response.json" ;;
    200) die "KMS released the production key to the debug pod" ;;
    *) die "unexpected HTTP ${status}; see ${debug_dir}/production-response.json" ;;
  esac
  echo "  production ciphertext -> HTTP 403, kms-denied"

  echo
  echo "== summary =="
  echo "  production: ${IMAGE_DIGEST}  PCR17 ${PREDICTED_PCR17}  key ${KMS_ALIAS}"
  echo "  debug:      ${debug_digest}  PCR17 ${debug_pcr17}  key ${debug_alias}"
  echo "Delete the debug pod before you finish:  ./scripts/debug.sh --delete"
}

main "$@"
