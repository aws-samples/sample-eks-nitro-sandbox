#!/usr/bin/env bash
# Exercises the decrypt path of the reproducible-build sample.
#
# Encrypts a demo string with the sample's KMS key (BuildTimeEncrypt statement), forwards
# the ciphertext to the confidential-sandbox pod via a local port-forward, and verifies:
#   - the response carries {"ok":true}
#   - the response sha256 matches sha256 of the plaintext
#   - the response does not contain the plaintext
#   - kubectl logs and kubectl exec on the pod are refused (zero operator access)
#
# Reads KEY_ARN, NAMESPACE and AWS_REGION from tmp/reproducible-build/run/state.env
# (written by setup.sh). Working files go to that same run/ directory. The plaintext
# value is never echoed and never placed on a command line; it moves through files only.
#
# Exit codes:
#   0  all checks passed
#   1  a check failed (see the error message)
#   2  a lookup or call failed; nothing was determined
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAMPLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SAMPLE_DIR}/../../.." && pwd)"
TMP_DIR="${REPO_ROOT}/tmp/reproducible-build/run"
STATE_FILE="${TMP_DIR}/state.env"

# Optional settings from .env (picks up KUBE_CONTEXT if set there).
if [[ -f "${SAMPLE_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null  # path is determined at runtime via SAMPLE_DIR
  . "${SAMPLE_DIR}/.env"
  set +a
fi

KUBE_CONTEXT="${KUBE_CONTEXT:-}"

# shellcheck source=examples/confidential/reproducible-build/scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

# --- load state ---

[[ -f "${STATE_FILE}" ]] || die "state file ${STATE_FILE} not found; run ./scripts/setup.sh first"
set -a
# shellcheck source=/dev/null  # path is determined at runtime via TMP_DIR
. "${STATE_FILE}"
set +a

[[ -n "${KEY_ARN:-}" ]] || die "KEY_ARN not found in ${STATE_FILE}; run ./scripts/setup.sh first"
[[ -n "${NAMESPACE:-}" ]] || die "NAMESPACE not found in ${STATE_FILE}; run ./scripts/setup.sh first"
[[ -n "${AWS_REGION:-}" ]] || die "AWS_REGION not found in ${STATE_FILE}; run ./scripts/setup.sh first"
export AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"

# --- constants ---

POD_NAME="reproducible-build-demo"
SVC_NAME="reproducible-build"
LOCAL_PORT=18080

# --- main ---

main() {
  # 1. Confirm the namespace is this sample's.
  local ns_rc=0
  # shellcheck disable=SC2310  # capture pattern; set -e disabled in || is intentional
  require_ns_label "${NAMESPACE}" || ns_rc=$?
  if ((ns_rc == 2)); then exit 2; fi
  if ((ns_rc != 0)); then exit 1; fi

  mkdir -p "${TMP_DIR}"

  # 2. Generate the demo plaintext; keep it mode 600.
  (
    umask 077
    local rand_hex
    rand_hex="$(openssl rand -hex 8)"
    printf 'demo-%s' "${rand_hex}" >"${TMP_DIR}/plaintext.txt"
  )

  # 3. Encrypt with KMS; ciphertext stays mode 600.
  (
    umask 077
    aws kms encrypt \
      --key-id "${KEY_ARN}" \
      --plaintext "fileb://${TMP_DIR}/plaintext.txt" \
      --query CiphertextBlob --output text \
      | base64 -d >"${TMP_DIR}/ciphertext.bin"
  )
  echo "ciphertext: ${TMP_DIR}/ciphertext.bin"

  # 4. Port-forward in the background; killed by stop_port_forward after the curl.
  start_port_forward "svc/${SVC_NAME}" "${LOCAL_PORT}" "${TMP_DIR}/port-forward.log" 30

  # 5. Send the ciphertext; tee the response so it is both displayed and saved.
  # shellcheck disable=SC2310  # exit 2 in the || block is intentional
  curl -sS -X PUT \
    --data-binary "@${TMP_DIR}/ciphertext.bin" \
    -H 'Content-Type: application/octet-stream' \
    -o "${TMP_DIR}/decrypt-response.json" \
    "http://127.0.0.1:${LOCAL_PORT}/decrypt" || {
    echo "ERROR: curl failed to reach the port-forward on ${LOCAL_PORT}; nothing was determined" >&2
    exit 2
  }
  stop_port_forward
  cat "${TMP_DIR}/decrypt-response.json"
  echo

  # 6a. Check that the response says ok.
  local ok response_body
  # shellcheck disable=SC2312  # jq failure means unparseable JSON; die message is best-effort
  response_body="$(cat "${TMP_DIR}/decrypt-response.json")"
  ok="$(jq -r '.ok' "${TMP_DIR}/decrypt-response.json")" \
    || die "could not parse response as JSON; read ${TMP_DIR}/decrypt-response.json"
  [[ "${ok}" == "true" ]] \
    || die "decrypt not ok: ${response_body}"

  # 6b. Check that the plaintext did not appear in the response.
  if grep -qF -f "${TMP_DIR}/plaintext.txt" "${TMP_DIR}/decrypt-response.json"; then
    die "plaintext value leaked into the response"
  fi

  # 6c. Check that .sha256 matches the sha256 of the plaintext file.
  local expected_sha256 response_sha256
  expected_sha256="$(shasum -a 256 "${TMP_DIR}/plaintext.txt" | awk '{print $1}')"
  response_sha256="$(jq -r '.sha256' "${TMP_DIR}/decrypt-response.json")"
  [[ "${response_sha256}" == "${expected_sha256}" ]] \
    || die "sha256 mismatch: response=${response_sha256} expected=${expected_sha256}"
  echo "sha256 check passed: ${response_sha256}"

  # 7. The operator cannot read the pod's log or run a command in it.
  assert_operator_refused "${POD_NAME}" "${NAMESPACE}"
  echo "decrypt verified"
}

main "$@"
