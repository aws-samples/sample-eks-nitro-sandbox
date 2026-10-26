# Helpers the sample's three scripts share. Sourced, never run on its own.
#
# It is one file rather than a copy in each script for the same reason gate.jq is: a check
# that exists twice stops matching itself at the next edit, and the copy keeps passing.
#
# Expects the caller to have set TMP_DIR, SCRIPT_DIR, MANAGED_BY and KUBE_CONTEXT.

MANAGED_BY="${MANAGED_BY:-secrets-manager-secret}"

die() { echo "ERROR: $*" >&2; exit 1; }

# kubectl, always against the context the run names. On a shared machine "whatever is
# current" is not always this sample's cluster, and another session can move it mid-run.
kc() {
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi
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
  local notfound="$1"; shift
  local out err rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/sms-out.XXXXXX")" || return 2
  err="$(mktemp "${TMPDIR:-/tmp}/sms-err.XXXXXX")" || return 2
  aws "$@" >"$out" 2>"$err" || rc=$?
  if [[ "$rc" == 0 ]]; then
    cat "$out"; rm -f "$out" "$err"; return 0
  fi
  if grep -Fq "$notfound" "$err"; then
    rm -f "$out" "$err"; return 1
  fi
  echo "ERROR: 'aws $*' failed (exit $rc) and not with $notfound, so it is unknown whether the resource exists:" >&2
  sed 's/^/  /' "$err" >&2
  rm -f "$out" "$err"
  return 2
}

# The other half of that contract, at the call site. A lookup that could not run must never
# reach the create path.
stop_if_undetermined() {  # stop_if_undetermined <lookup-rc> <description>
  [[ "$1" != 2 ]] ||
    die "could not determine whether $2 exists (the AWS error is above), so this run created and changed nothing. Re-run once the call succeeds."
}

# Confirms a resource this script is about to reuse carries the sample's ownership tag. A
# resource with the tag counts as the sample's whichever run created it; one without it
# belongs to something else and is never touched.
require_managed_by() {  # require_managed_by <description> <actual-tag-value>
  [[ "$2" == "$MANAGED_BY" ]] ||
    die "$1 already exists and is not this sample's (ManagedBy='$2', expected '$MANAGED_BY'); created and changed nothing. Delete it, or set a new name in .env."
}

# "None" is what the AWS CLI prints for a missing value with --output text. Treating it as
# a tag value would make require_managed_by compare against the literal string.
tag_or_empty() {  # tag_or_empty <aws-cli-text-output>
  if [[ "$1" == "None" ]]; then printf ''; else printf '%s' "$1"; fi
}

# Reads the live key policy back and checks it against gate.jq. Takes the measurement the
# gate should carry; the role ARN and unique id come from the caller's variables.
#   verify_key_policy <expected-pcr17>
verify_key_policy() {
  local live
  live="$(aws kms get-key-policy --key-id "$KMS_KEY_ARN" --policy-name default \
    --query Policy --output text)" ||
    die "could not read the key policy back off $KMS_KEY_ARN, so it is unknown what the gate on it is"
  printf '%s\n' "$live" | jq . > "$TMP_DIR/kms-key-policy.live.json"
  jq -e --arg role "$IAM_ROLE_ARN" --arg roleid "$IAM_ROLE_ID" --arg pcr17 "$1" \
    --from-file "$SCRIPT_DIR/gate.jq" \
    "$TMP_DIR/kms-key-policy.live.json" >/dev/null ||
    die "the live KMS key policy is not the gate this sample installs (read back into $TMP_DIR/kms-key-policy.live.json). A denial only means the measurement was refused if the gate that produced it is the gate we believe is there."
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
redact() {
  sed -e 's/[0-9]\{12\}/<ACCOUNT_ID>/g' -e 's|\(assumed-role/[^/]*/\)[^ "]*|\1<session>|g'
}
