# shellcheck shell=bash
# Helpers the sample's scripts share. Sourced, never run on its own.
#
# It is one file rather than a copy in each script for the same reason gate.jq is: a check
# that exists twice stops matching itself at the next edit, and the copy keeps passing.
#
# Expects the caller to have set TMP_DIR and SCRIPT_DIR (KUBE_CONTEXT is optional), and, for
# verify_key_policy, KMS_KEY_ARN, IAM_ROLE_ARN and IAM_ROLE_ID. They are left unset here
# on purpose, so a caller that forgets one fails under set -u.

MANAGED_BY="${MANAGED_BY:-reproducible-build}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# kubectl, always against the context the run names. On a shared machine "whatever is
# current" is not always this sample's cluster, and another session can move it mid-run.
kc() {
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then kubectl --context "${KUBE_CONTEXT}" "$@"; else kubectl "$@"; fi
}

# A lookup that cannot run is "could not determine", which is a failure, never "absent".
# So absence is proved by the service's own not-found exception and nothing else; any other
# error has to stop the script before it can create a duplicate of something already there.
#   lookup <not-found-exception> <aws args...>
#     prints stdout and returns 0 when the resource is there
#     returns 1 only when the named exception came back
#     returns 2 when it could not be determined, having printed the AWS error
#
# It returns 2 rather than exiting, because every caller runs it inside a command
# substitution: an exit there would leave the subshell only, and the caller would read the
# non-zero status as "absent" and go on to create the resource.
lookup() {
  local notfound="$1"
  shift
  local out err rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/rb-out.XXXXXX")" || return 2
  err="$(mktemp "${TMPDIR:-/tmp}/rb-err.XXXXXX")" || return 2
  aws "$@" >"${out}" 2>"${err}" || rc=$?
  if [[ "${rc}" == 0 ]]; then
    cat "${out}"
    rm -f "${out}" "${err}"
    return 0
  fi
  if grep -Fq "${notfound}" "${err}"; then
    rm -f "${out}" "${err}"
    return 1
  fi
  echo "ERROR: 'aws $*' failed (exit ${rc}) and not with ${notfound}, so it is unknown whether the resource exists:" >&2
  sed 's/^/  /' "${err}" >&2
  rm -f "${out}" "${err}"
  return 2
}

# The other half of that contract, at the call site. A lookup that could not run must never
# reach the create path.
stop_if_undetermined() { # stop_if_undetermined <lookup-rc> <description>
  [[ "$1" != 2 ]] \
    || die "could not determine whether $2 exists (the AWS error is above), so this run created and changed nothing. Re-run once the call succeeds."
}

# Confirms a resource this script is about to reuse carries the sample's ownership tag. A
# resource with the tag counts as the sample's whichever run created it; one without it
# belongs to something else and is never touched.
require_managed_by() { # require_managed_by <description> <actual-tag-value>
  [[ "$2" == "${MANAGED_BY}" ]] \
    || die "$1 already exists and is not this sample's (ManagedBy='$2', expected '${MANAGED_BY}'); created and changed nothing. Delete it, or set a new name in .env."
}

# "None" is what the AWS CLI prints for a missing value with --output text. Treating it as
# a tag value would make require_managed_by compare against the literal string.
tag_or_empty() { # tag_or_empty <aws-cli-text-output>
  if [[ "$1" == "None" ]]; then printf ''; else printf '%s' "$1"; fi
}

# Checks that <value> is a 96-character lowercase hexadecimal string. The hex class is
# written out rather than given as ranges; a bracket range is matched against the locale's
# collating order and can accept characters outside ASCII hex.
#   require_hex96 <value> <what>
require_hex96() {
  [[ "$1" =~ ^[0123456789abcdef]{96}$ ]] \
    || die "$2 must be a 96-character lowercase hex string; got '${1:0:20}...'"
}

# Confirms the namespace exists and carries this sample's label.
# Returns 0 when the label matches MANAGED_BY, 1 when it differs or the namespace is absent,
# and 2 when the lookup itself failed (never "absent").
#   require_ns_label <ns>
require_ns_label() {
  local ns ns_exists ns_label
  ns="$1"
  ns_exists="$(kc get namespace "${ns}" --ignore-not-found -o name)" || {
    echo "ERROR: could not determine whether namespace ${ns} exists (kubectl lookup failed)" >&2
    return 2
  }
  if [[ -z "${ns_exists}" ]]; then
    echo "ERROR: namespace ${ns} is not there; run ./scripts/setup.sh first" >&2
    return 1
  fi
  ns_label="$(kc get namespace "${ns}" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')" || {
    echo "ERROR: could not determine whether namespace ${ns} is this sample's (kubectl lookup failed)" >&2
    return 2
  }
  if [[ "${ns_label}" != "${MANAGED_BY}" ]]; then
    echo "ERROR: namespace ${ns} is not this sample's (managed-by='${ns_label}', expected '${MANAGED_BY}')" >&2
    return 1
  fi
}

# Reads the live key policy back and checks it against gate.jq. Takes the measurement the
# gate should carry; the role ARN and unique id come from the caller's variables.
#   verify_key_policy <expected-pcr17>
# shellcheck disable=SC2154  # the caller sets these before sourcing, see the header
verify_key_policy() {
  local live
  live="$(aws kms get-key-policy --key-id "${KMS_KEY_ARN}" --policy-name default \
    --query Policy --output text)" \
    || die "could not read the key policy back off ${KMS_KEY_ARN}, so it is unknown what the gate on it is"
  printf '%s\n' "${live}" | jq . >"${TMP_DIR}/kms-key-policy.live.json"
  jq -e --arg role "${IAM_ROLE_ARN}" --arg roleid "${IAM_ROLE_ID}" --arg pcr17 "$1" \
    --from-file "${SCRIPT_DIR}/gate.jq" \
    "${TMP_DIR}/kms-key-policy.live.json" >/dev/null \
    || die "the live KMS key policy is not the gate this sample installs (read back into ${TMP_DIR}/kms-key-policy.live.json). A denial only means the measurement was refused if the gate that produced it is the gate we believe is there."
}

# Was this pod's response a kms:Decrypt authorization denial?
#
# The service returns HTTP 403 with JSON {"ok":false,"error":"kms-denied","code":"<KMS error
# code>"} when KMS refuses the decryption request. Two conditions earn their place:
#
#   * error == "kms-denied": the service reached KMS and was refused, not some other failure
#     such as a network error, a missing attestation device, or a bad ciphertext.
#   * code == "AccessDeniedException": the specific KMS error an attestation gate produces.
#     A throttle or an invalid-ciphertext error both produce a non-200 response, and neither
#     of them shows the gate refusing the measurement.
#
#   assert_decrypt_denial <response-body-file>
assert_decrypt_denial() {
  jq -e '.error == "kms-denied"' "$1" >/dev/null \
    || die "the pod failed, but not with a kms-denied response body, so the refusal cannot be attributed to the attestation condition. Read $1 for what the service returned."
  # shellcheck disable=SC2312  # jq failure yields empty string; still a useful error message
  jq -e '.code == "AccessDeniedException"' "$1" >/dev/null \
    || die "the response carries error kms-denied but the KMS error code is not AccessDeniedException (got: $(jq -r '.code // "(absent)"' "$1" || true)), so the specific denial differs from what the attestation gate produces."
}

# The generator prints the measurement it predicts for a policy, under a header line, and a
# ready-to-paste KMS condition after it. Take the first 96-hex-character line after the
# header: a SHA-384, which is what the agent extends into PCR17 (Amazon EKS User Guide,
# "Cedar policies").
#
# The hex class is written out rather than given as ranges. A bracket RANGE is matched
# against the locale's collating order, so [0-9a-f] under a UTF-8 locale can also accept
# characters that are not ASCII hex digits, and the measurement this returns is what the KMS
# key gets gated on.
#   read_predicted_pcr17 <generator-log>
read_predicted_pcr17() {
  awk '
    /--- Predicted PCR17 ---/ { found = 1; next }
    found {
      value = tolower($0); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^[0123456789abcdef]{96}$/) { print value; exit }
    }' "$1"
}

# An AWS error names the full role session, and an EKS Pod Identity session name is built
# from the cluster name and the pod name, so an unredacted message would put this account
# and this cluster into a file the page is copied from.
#
# The account id is matched only where one actually appears -- between two colons of an ARN,
# or in front of an ECR registry host -- and not as any run of twelve digits. A SHA-256 hex
# digest contains twelve consecutive decimal digits surprisingly often, and the blunt pattern
# rewrote part of an image digest into <ACCOUNT_ID>, which silently corrupted the evidence
# this output is read for.
redact() {
  sed -e 's/:[0-9]\{12\}:/:<ACCOUNT_ID>:/g' \
    -e 's/[0-9]\{12\}\(\.dkr\.ecr\.\)/<ACCOUNT_ID>\1/g' \
    -e 's|\(assumed-role/[^/]*/\)[^ "]*|\1<session>|g'
}

# Check whether a namespace exists and carries this sample's managed-by label.
# Returns:
#   0  namespace exists with the correct label
#   1  namespace does not exist
#   2  a kubectl lookup failed (could not determine)
#   3  namespace exists but carries a different label
check_ns() { # check_ns <ns>
  local ns="$1" ns_exists ns_label
  # shellcheck disable=SC2310  # capture pattern; set -e disabled in || is intentional
  ns_exists="$(kc get namespace "${ns}" --ignore-not-found -o name)" || {
    echo "ERROR: could not determine whether namespace ${ns} exists (kubectl lookup failed)" >&2
    return 2
  }
  if [[ -z "${ns_exists}" ]]; then
    return 1
  fi
  # shellcheck disable=SC2310  # capture pattern; set -e disabled in || is intentional
  ns_label="$(kc get namespace "${ns}" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')" || {
    echo "ERROR: could not determine whether namespace ${ns} is this sample's (kubectl lookup failed)" >&2
    return 2
  }
  if [[ "${ns_label}" != "${MANAGED_BY}" ]]; then
    echo "ERROR: namespace ${ns} is not this sample's (managed-by='${ns_label}', expected '${MANAGED_BY}')" >&2
    return 3
  fi
}

json_string() { jq -n --arg v "$1" '$v'; }

# shellcheck disable=SC2312  # pipeline is intentional; kc error handled by set -e
render() { # render <manifest> <jq-filter> <out>
  kc create --dry-run=client --validate=false -o json -f "$1" | jq "$2" >"$3"
}

# shellcheck disable=SC2154  # account_id, IAM_ROLE_ARN, KEY_POLICY_TEMPLATE, TMP_DIR set by caller
render_key_policy() { # render_key_policy <pcr17>
  jq --arg account "${account_id}" --arg role "${IAM_ROLE_ARN}" --arg pcr17 "$1" '
    del(._comment)
    | (.Statement[] | select(.Sid == "KeyAdministration").Principal.AWS) = "arn:aws:iam::\($account):root"
    | (.Statement[] | select(.Sid == "BuildTimeEncrypt").Principal.AWS) = "arn:aws:iam::\($account):root"
    | (.Statement[] | select(.Sid == "AttestedDecryptOnly").Principal.AWS) = $role
    | (.Statement[] | select(.Sid == "AttestedDecryptOnly").Condition.StringEqualsIgnoreCase["kms:RecipientAttestation:PCR17"]) = $pcr17
    | (.Statement[] | select(.Sid == "DenyUnlessThePolicyMeasurementMatches").Condition.StringNotEqualsIgnoreCase["kms:RecipientAttestation:PCR17"]) = $pcr17
  ' "${KEY_POLICY_TEMPLATE}" >"${TMP_DIR}/kms-key-policy.json"
}

# shellcheck disable=SC2154  # KMS_KEY_ARN, TMP_DIR set by caller or ensure_gated_key
put_key_policy() { # put_key_policy <expected-pcr17>
  render_key_policy "$1"
  local attempt err rc
  err="$(mktemp "${TMPDIR:-/tmp}/rb-kp.XXXXXX")" || die "mktemp failed"
  for attempt in $(seq 12); do
    rc=0
    aws kms put-key-policy --key-id "${KMS_KEY_ARN}" --policy-name default \
      --policy "file://${TMP_DIR}/kms-key-policy.json" 2>"${err}" || rc=$?
    if [[ "${rc}" == 0 ]]; then
      rm -f "${err}"
      return 0
    fi
    if ! grep -Fq "invalid principals" "${err}"; then
      echo "ERROR: kms:PutKeyPolicy failed (exit ${rc}):" >&2
      sed 's/^/  /' "${err}" >&2
      rm -f "${err}"
      exit 1
    fi
    if [[ "${attempt}" == 1 ]]; then echo "  waiting for the new IAM role to be visible to KMS..."; fi
    sleep 5
  done
  echo "ERROR: kms:PutKeyPolicy kept refusing the role after 12 tries:" >&2
  sed 's/^/  /' "${err}" >&2
  rm -f "${err}"
  exit 1
}

# shellcheck disable=SC2154  # KMS_KEY_ARN, IAM_ROLE_ARN, TMP_DIR set by caller or ensure_gated_key
settle_key_policy_principal() {
  local attempt stored
  for attempt in $(seq 6); do
    # shellcheck disable=SC2312  # pipeline is intentional; aws error handled by set -e
    stored="$(aws kms get-key-policy --key-id "${KMS_KEY_ARN}" --policy-name default \
      --query Policy --output text \
      | jq -r '[.Statement[] | select(.Sid == "AttestedDecryptOnly")
                | (.Principal.AWS | if type == "array" then .[] else . end)] | join(",")')"
    [[ "${stored}" != "${IAM_ROLE_ARN}" ]] || return 0
    [[ -n "${stored}" ]] || return 0
    sleep 5
    aws kms put-key-policy --key-id "${KMS_KEY_ARN}" --policy-name default \
      --policy "file://${TMP_DIR}/kms-key-policy.json" >/dev/null 2>&1 || true
  done
  return 0
}

# Forward <local-port> to <target> (pod/x or svc/x) in NAMESPACE and wait until it accepts TCP.
# kubectl itself is backgrounded, not kc, so PF_PID is kubectl and not a subshell.
# shellcheck disable=SC2154  # NAMESPACE set by the caller (via .env or state.env)
start_port_forward() { # start_port_forward <target> <local-port> <log-file> <timeout-s>
  local target="$1" port="$2" log="$3" timeout="$4" deadline
  kubectl ${KUBE_CONTEXT:+--context "${KUBE_CONTEXT}"} port-forward "${target}" "${port}:8080" \
    -n "${NAMESPACE}" >"${log}" 2>&1 &
  PF_PID=$!
  # shellcheck disable=SC2064  # expand PF_PID now, not at trap time
  trap "kill ${PF_PID} 2>/dev/null || true" EXIT
  deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)) && kill -0 "${PF_PID}" 2>/dev/null; do
    if (echo >"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then return 0; fi
    sleep 1
  done
  sed 's/^/  kubectl: /' "${log}" >&2 || true
  die "port-forward to ${target} on ${port} stopped or was not ready within ${timeout} s (kubectl output above)"
}

stop_port_forward() {
  kill "${PF_PID:-}" 2>/dev/null || true
  trap - EXIT
}

# Create the KMS key behind <alias>, gated on <pcr17>, or reuse it when it carries this
# sample's ManagedBy tag; then put, settle and verify the gate.
# shellcheck disable=SC2154  # account_id, IAM_ROLE_ARN, KEY_POLICY_TEMPLATE, MANAGED_BY, TMP_DIR set by caller
ensure_gated_key() { # ensure_gated_key <alias> <pcr17> <description>
  local alias="$1" pcr17="$2" description="$3" key_json="" key_rc=0 key_tag
  key_json="$(lookup NotFoundException kms describe-key --key-id "${alias}" \
    --query 'KeyMetadata' --output json)" || key_rc=$?
  stop_if_undetermined "${key_rc}" "the KMS key behind ${alias}"
  if [[ "${key_rc}" == 0 ]]; then
    KMS_KEY_ID="$(jq -r '.KeyId' <<<"${key_json}")"
    KMS_KEY_ARN="$(jq -r '.Arn' <<<"${key_json}")"
    # shellcheck disable=SC2312  # nested substitution is intentional; outer handles empty
    key_tag="$(tag_or_empty "$(aws kms list-resource-tags --key-id "${KMS_KEY_ID}" \
      --query "Tags[?TagKey=='ManagedBy'].TagValue | [0]" --output text)")"
    require_managed_by "the KMS key behind ${alias}" "${key_tag}"
    echo "  reusing KMS key ${alias}"
    # shellcheck disable=SC2034  # caller reads KMS_CREATED after the call
    KMS_CREATED=false
  else
    # Created with the full gate, so the key never exists without it.
    render_key_policy "${pcr17}"
    key_json="$(aws kms create-key --description "${description}" \
      --key-usage ENCRYPT_DECRYPT --key-spec SYMMETRIC_DEFAULT \
      --policy "file://${TMP_DIR}/kms-key-policy.json" \
      --tags "TagKey=ManagedBy,TagValue=${MANAGED_BY}" \
      --query 'KeyMetadata' --output json)"
    KMS_KEY_ID="$(jq -r '.KeyId' <<<"${key_json}")"
    KMS_KEY_ARN="$(jq -r '.Arn' <<<"${key_json}")"
    aws kms create-alias --alias-name "${alias}" --target-key-id "${KMS_KEY_ID}"
    echo "  created KMS key ${KMS_KEY_ARN}"
    # shellcheck disable=SC2034  # caller reads KMS_CREATED after the call
    KMS_CREATED=true
  fi
  put_key_policy "${pcr17}"
  settle_key_policy_principal
  verify_key_policy "${pcr17}"
}

# The guest policy's refusal text, captured from a live production pod (not documented).
REFUSAL_LOGS_TEXT='Container logs are disabled by policy.'
REFUSAL_EXEC_TEXT='policy denied Agent::Action::"Exec"'

# Show that an operator with cluster access can neither read the pod's logs nor run a
# command in it. Matching the refusal text keeps a wrong context or a pod that is not
# Ready from passing as a refusal.
assert_operator_refused() { # assert_operator_refused <pod> <ns>
  local pod="$1" ns="$2" out rc
  rc=0
  out="$(kc logs "${pod}" -n "${ns}" -c main 2>&1)" || rc=$?
  # kubectl logs exits 0 with the denial in stdout; check for the text before rc.
  if grep -Fq -- "${REFUSAL_LOGS_TEXT}" <<<"${out}"; then
    # shellcheck disable=SC2312  # head failure means empty output, which is acceptable
    echo "  kubectl logs refused: $(head -1 <<<"${out}")"
  elif ((rc == 0)); then
    die "kubectl logs ${pod} succeeded: the operator can read its logs"
  else
    echo "ERROR: kubectl logs ${pod} failed, but not with the policy refusal:" >&2
    # shellcheck disable=SC2001  # sed is cleaner than bash substitution for multi-line prefixing
    sed 's/^/  /' <<<"${out}" >&2
    return 2
  fi
  rc=0
  out="$(kc exec "${pod}" -n "${ns}" -c main -- /bin/sh -c true 2>&1)" || rc=$?
  ((rc != 0)) || die "kubectl exec into ${pod} succeeded: the operator can run commands in it"
  grep -Fq -- "${REFUSAL_EXEC_TEXT}" <<<"${out}" || {
    echo "ERROR: kubectl exec into ${pod} failed, but not with the policy refusal:" >&2
    # shellcheck disable=SC2001  # sed is cleaner than bash substitution for multi-line prefixing
    sed 's/^/  /' <<<"${out}" >&2
    return 2
  }
  # shellcheck disable=SC2312  # head failure means empty output, which is acceptable
  echo "  kubectl exec refused: $(head -1 <<<"${out}")"
}
