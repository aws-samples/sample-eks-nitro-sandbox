#!/usr/bin/env bash
# Show that a one-line source change produces a different image digest and measurement,
# and that the unchanged KMS key refuses the changed pod.
#
#   ./scripts/changed-source.sh           # run it, wait for the denial, print it
#   ./scripts/changed-source.sh --delete  # delete the changed pod
#
# Copies flake.nix, flake.lock and src/ to tmp/reproducible-build/changed/, applies a
# one-line sed change (BANNER v1 -> v2), builds and pushes the changed image, generates
# the Cedar policy, verifies the measurement differs from the approved pod's, and runs
# the changed pod. The pod reaches KMS and is refused: the gate expects the approved
# measurement, and the changed pod carries a different one.
#
# Needs ./scripts/setup.sh to have run: it reads the state file setup.sh wrote.
set -euo pipefail

CHANGED_POD_NAME="reproducible-build-changed"
LOCAL_PORT=18081

# --- main ---

main() {
  # No argument, or --delete, and nothing else.
  if [[ $# -gt 1 || (-n "${1:-}" && "$1" != "--delete") ]]; then
    echo "unknown argument: $*" >&2
    exit 2
  fi

  local SCRIPT_DIR sample_dir repo_root TMP_DIR changed_dir state_file profile
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  sample_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"
  repo_root="$(cd "${sample_dir}/../../.." && pwd)"
  TMP_DIR="${repo_root}/tmp/reproducible-build/run"
  changed_dir="${repo_root}/tmp/reproducible-build/changed"
  state_file="${TMP_DIR}/state.env"
  profile="${sample_dir}/deploy/production-profile.yaml"

  if [[ -f "${sample_dir}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    . "${sample_dir}/.env"
    set +a
  fi

  # After .env, so GENPOLICY and CONTAINER_RUNTIME set there are used.
  local genpolicy container_runtime
  genpolicy="${GENPOLICY:-eks-nitro-sandbox-genpolicy}"
  container_runtime="${CONTAINER_RUNTIME:-docker}"

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

  # Namespace check: runs for both --delete and normal path.
  # check_ns returns 0=ok, 1=absent, 2=lookup-failed, 3=wrong-label.
  local ns_rc=0
  # shellcheck disable=SC2310  # capture pattern; set -e disabled in || is intentional
  check_ns "${NAMESPACE:-}" || ns_rc=$?

  if [[ "${1:-}" == "--delete" ]]; then
    case "${ns_rc}" in
      0) ;; # namespace is ours, proceed to delete
      1)
        echo "Namespace ${NAMESPACE:-} is not there; nothing to delete."
        exit 0
        ;;
      2) exit 2 ;;
      3) die "namespace ${NAMESPACE:-} is not this sample's; changed nothing in it" ;;
      *) die "unexpected check_ns return code ${ns_rc}" ;;
    esac
    kc delete pod "${CHANGED_POD_NAME}" -n "${NAMESPACE}" \
      --ignore-not-found --wait=true --timeout=5m
    exit 0
  fi

  case "${ns_rc}" in
    0) ;;
    1) die "namespace ${NAMESPACE:-} is not there; run ./scripts/setup.sh first" ;;
    2) exit 2 ;;
    3) die "namespace ${NAMESPACE:-} is not this sample's; changed nothing in it" ;;
    *) die "unexpected check_ns return code ${ns_rc}" ;;
  esac

  # --- preflight ---

  local c
  for c in aws jq kubectl openssl curl base64 "${container_runtime}"; do
    command -v "${c}" >/dev/null 2>&1 || die "${c} is required"
  done
  command -v "${genpolicy}" >/dev/null 2>&1 || die "${genpolicy} is not on PATH"

  [[ -n "${IMAGE_DIGEST:-}" ]] \
    || die "IMAGE_DIGEST not found in ${state_file}; run ./scripts/setup.sh first"
  [[ -n "${PREDICTED_PCR17:-}" ]] \
    || die "PREDICTED_PCR17 not found in ${state_file}; run ./scripts/setup.sh first"
  [[ -n "${KMS_KEY_ARN:-}" ]] \
    || die "KMS_KEY_ARN not found in ${state_file}; run ./scripts/setup.sh first"
  [[ -n "${IAM_ROLE_ARN:-}" ]] \
    || die "IAM_ROLE_ARN not found in ${state_file}; run ./scripts/setup.sh first"
  [[ -n "${IAM_ROLE_ID:-}" ]] \
    || die "IAM_ROLE_ID not found in ${state_file}; run ./scripts/setup.sh first"
  [[ -n "${IMAGE_REPO:-}" ]] \
    || die "IMAGE_REPO not found in ${state_file}; run ./scripts/setup.sh first"

  local account_id registry
  account_id="$(aws sts get-caller-identity --query Account --output text)" \
    || die "could not read the AWS account; check your credentials"
  registry="${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"

  # --- 1/5 copy source and apply the one-line change ---

  echo "== 1/5 copy the source and change BANNER v1 to v2 =="

  rm -rf "${changed_dir}"
  mkdir -p "${changed_dir}"

  cp "${sample_dir}/flake.nix" "${changed_dir}/flake.nix"
  cp "${sample_dir}/flake.lock" "${changed_dir}/flake.lock"
  cp -r "${sample_dir}/src" "${changed_dir}/src"

  # sed -i differs between GNU and BSD; write to a tmp file and mv to avoid the difference.
  local main_rs tmp_rs diff_count
  main_rs="${changed_dir}/src/src/main.rs"
  tmp_rs="$(mktemp "${TMPDIR:-/tmp}/rb-main.XXXXXX")"
  sed 's/const BANNER: &str = "reproducible-build decrypt v1";/const BANNER: \&str = "reproducible-build decrypt v2";/' \
    "${main_rs}" >"${tmp_rs}"
  mv "${tmp_rs}" "${main_rs}"

  # Require exactly one line changed against the original src/.
  diff_count="$(diff -r "${sample_dir}/src/src/main.rs" "${main_rs}" | grep -c '^[<>]' || true)"
  [[ "${diff_count}" -eq 2 ]] \
    || die "expected exactly 2 diff lines (one old, one new) from the BANNER change; got ${diff_count}. Check ${main_rs}"
  echo "  changed BANNER v1 -> v2 in ${main_rs} (diff lines: ${diff_count})"

  # --- 2/5 build and push the changed image ---

  echo "== 2/5 build and push the changed image =="

  local changed_auth_file ecr_token
  changed_auth_file="${changed_dir}/auth.json"
  ecr_token="$(aws ecr get-login-password)" \
    || die "could not get an ECR authorization token"
  [[ -n "${ecr_token}" ]] || die "the ECR authorization token came back empty"
  (
    umask 077
    printf 'AWS:%s' "${ecr_token}" | base64 | tr -d '\r\n' \
      | jq -Rn --arg r "${registry}" '{auths:{($r):{auth:input}}}' \
        >"${changed_auth_file}"
  )
  unset ecr_token

  jq -e --arg r "${registry}" --arg prefix "QVdTOg" '
    .auths[$r].auth | type == "string" and length > 0
    and . != "QVdTOg==" and (length > ($prefix | length) + 2)
  ' "${changed_auth_file}" >/dev/null \
    || die "could not write the ECR credentials needed by the build"

  local changed_tag changed_digest
  changed_tag="v2-@DIGEST12@"
  "${SCRIPT_DIR}/build.sh" "${changed_dir}" "${changed_dir}/out" \
    --push "${IMAGE_REPO}:${changed_tag}" "${changed_auth_file}" --tag-from-digest

  changed_digest="$(cat "${changed_dir}/out/digest")"
  [[ "${changed_digest}" == sha256:* ]] \
    || die "build.sh did not write a valid digest to ${changed_dir}/out/digest"

  [[ "${changed_digest}" != "${IMAGE_DIGEST}" ]] \
    || die "the changed image has the same digest as the approved image, so the BANNER change did not affect the build"
  echo "  approved digest: ${IMAGE_DIGEST}"
  echo "  changed  digest: ${changed_digest}"

  # --- 3/5 generate policy, check PCR17, verify gate ---

  echo "== 3/5 generate policy for the changed image and confirm PCR17 differs =="

  # The KMS alias ARN is predictable from account, region and alias name: same as setup.sh.
  local kms_alias_arn changed_image_uri pod_filter
  kms_alias_arn="arn:aws:kms:${AWS_REGION}:${account_id}:${KMS_ALIAS:-alias/reproducible-build-sample}"
  changed_image_uri="${IMAGE_REPO}@${changed_digest}"

  # shellcheck disable=SC2312  # json_string wraps a jq call; failure of jq is caught by set -euo
  pod_filter="$(printf '
    .metadata.namespace = %s
    | .metadata.name = %s
    | .metadata.labels["app.kubernetes.io/name"] = %s
    | .spec.containers[0].image = %s
    | (.spec.containers[0].env[] | select(.name == "AWS_REGION").value) = %s
    | (.spec.containers[0].env[] | select(.name == "AWS_DEFAULT_REGION").value) = %s
    | (.spec.containers[0].env[] | select(.name == "KMS_KEY_ARN").value) = %s
  ' "$(json_string "${NAMESPACE}")" \
    "$(json_string "${CHANGED_POD_NAME}")" \
    "$(json_string "reproducible-build-changed")" \
    "$(json_string "${changed_image_uri}")" \
    "$(json_string "${AWS_REGION}")" \
    "$(json_string "${AWS_REGION}")" \
    "$(json_string "${kms_alias_arn}")")"

  render "${sample_dir}/deploy/pod.yaml" "${pod_filter}" "${changed_dir}/changed-pod-input.json"

  # Registry credentials for the policy generator.
  local genpolicy_home ecr_token2
  genpolicy_home="${changed_dir}/genpolicy-home"
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

  HOME="${genpolicy_home}" "${genpolicy}" \
    --profile "${profile}" --with-pod-identity \
    --output-file-b64 "${changed_dir}/changed-policy.b64" \
    "${changed_dir}/changed-pod-input.json" | tee "${changed_dir}/changed-genpolicy.log"

  local changed_pcr17
  changed_pcr17="$(read_predicted_pcr17 "${changed_dir}/changed-genpolicy.log")"
  [[ "${changed_pcr17}" =~ ^[0123456789abcdef]{96}$ ]] \
    || die "could not read a predicted PCR17 for the changed pod (${changed_dir}/changed-genpolicy.log)"

  [[ "${changed_pcr17}" != "${PREDICTED_PCR17}" ]] \
    || die "the changed pod's measurement equals the approved pod's, so the gate would release the key and this would show nothing"
  echo "  approved PCR17: ${PREDICTED_PCR17}"
  echo "  changed  PCR17: ${changed_pcr17}"

  # Confirm the live gate still carries the approved measurement.
  echo "== 3b verify the gate still expects the approved measurement =="
  verify_key_policy "${PREDICTED_PCR17}"
  echo "  the gate is bound to the approved measurement, unchanged"

  # --- 4/5 run the changed pod and expect a denial ---

  echo "== 4/5 run the changed pod and wait for the kms:Decrypt denial =="

  local changed_b64 existing
  changed_b64="$(tr -d '\r\n' <"${changed_dir}/changed-policy.b64")"
  jq --arg name "${CHANGED_POD_NAME}" --arg policy "${changed_b64}" '
    .metadata.name = $name
    | .metadata.annotations["sandbox.amazonaws.com/policy"] = $policy
  ' "${changed_dir}/changed-pod-input.json" >"${changed_dir}/rendered-changed-pod.json"

  # Apply only if absent; if a leftover from a previous run is there, delete it first.
  existing=""
  # shellcheck disable=SC2310  # capture pattern; set -e disabled in || is intentional
  existing="$(kc get pod "${CHANGED_POD_NAME}" -n "${NAMESPACE}" --ignore-not-found -o name 2>/dev/null)" \
    || die "could not check whether ${CHANGED_POD_NAME} already exists in ${NAMESPACE}"
  if [[ -n "${existing}" ]]; then
    echo "  removing leftover ${CHANGED_POD_NAME} before this run"
    kc delete pod "${CHANGED_POD_NAME}" -n "${NAMESPACE}" --wait=true --timeout=5m >/dev/null
  fi
  kc apply -f "${changed_dir}/rendered-changed-pod.json"

  # Wait for Ready.
  echo "  waiting for ${CHANGED_POD_NAME} to become Ready..."
  # shellcheck disable=SC2310  # ! condition; set -e disabled is intentional
  if ! kc wait pod "${CHANGED_POD_NAME}" -n "${NAMESPACE}" \
    --for=condition=Ready --timeout=10m 2>/dev/null; then
    # shellcheck disable=SC2310  # || true; partial failure output is best-effort
    kc get pod "${CHANGED_POD_NAME}" -n "${NAMESPACE}" -o wide 2>/dev/null || true
    # shellcheck disable=SC2310  # || true; partial failure output is best-effort
    kc logs "${CHANGED_POD_NAME}" -n "${NAMESPACE}" -c main 2>/dev/null | redact || true
    die "${CHANGED_POD_NAME} did not become Ready within 10 minutes"
  fi
  echo "  ${CHANGED_POD_NAME} is Ready"

  # --- 4b encrypt a fresh ciphertext and send PUT /decrypt to the changed pod ---

  (
    umask 077
    local rand_hex
    rand_hex="$(openssl rand -hex 8)"
    printf 'demo-%s' "${rand_hex}" >"${changed_dir}/plaintext.txt"
  )

  (
    umask 077
    aws kms encrypt \
      --key-id "${KMS_KEY_ARN}" \
      --plaintext "fileb://${changed_dir}/plaintext.txt" \
      --query CiphertextBlob --output text \
      | base64 -d >"${changed_dir}/ciphertext.bin"
  )
  echo "  ciphertext: ${changed_dir}/ciphertext.bin"

  start_port_forward "pod/${CHANGED_POD_NAME}" "${LOCAL_PORT}" "${changed_dir}/port-forward.log" 60

  local http_status
  # shellcheck disable=SC2310  # capture pattern; set -e disabled in || is intentional
  http_status="$(curl -sS -X PUT \
    --data-binary "@${changed_dir}/ciphertext.bin" \
    -H 'Content-Type: application/octet-stream' \
    -o "${changed_dir}/decrypt-response.json" \
    -w '%{http_code}' \
    "http://127.0.0.1:${LOCAL_PORT}/decrypt")" || {
    echo "ERROR: curl failed to reach port-forward on ${LOCAL_PORT}; could not determine whether KMS denied" >&2
    exit 2
  }

  stop_port_forward

  # 403 → KMS denied (expected); 200 → KMS released key to wrong measurement (gate failed).
  case "${http_status}" in
    403)
      assert_decrypt_denial "${changed_dir}/decrypt-response.json"
      echo "  the changed pod was refused by KMS (kms:Decrypt denied)"
      ;;
    200)
      die "KMS released the key to the changed measurement ${changed_pcr17}: the gate is not enforcing the expected measurement"
      ;;
    *)
      die "unexpected HTTP ${http_status} from /decrypt; see ${changed_dir}/decrypt-response.json"
      ;;
  esac

  # --- 5/5 print the summary ---

  echo
  echo "== 5/5 summary =="
  echo "  approved digest: ${IMAGE_DIGEST}"
  echo "  changed  digest: ${changed_digest}"
  echo "  approved PCR17:  ${PREDICTED_PCR17}"
  echo "  changed  PCR17:  ${changed_pcr17}"
  echo
  echo "The changed pod was refused the key by KMS: its measurement differs from the gate."
  echo "Delete it before you finish:  ./scripts/changed-source.sh --delete"
}

main "$@"
