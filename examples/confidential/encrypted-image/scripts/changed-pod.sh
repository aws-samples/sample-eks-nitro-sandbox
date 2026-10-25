#!/usr/bin/env bash
# Start a second pod that runs the same encrypted image with one pinned value changed,
# and show AWS KMS refuse it the layer key.
#
#   ./scripts/changed-pod.sh            # start it, wait for the denial, print it
#   ./scripts/changed-pod.sh --delete   # delete it again
#
# The change is one added environment variable. The confidential profile pins the
# container's environment, so the generated policy differs, its measurement differs, and
# the gate setup.sh installed no longer matches. Nothing about the KMS key policy is
# touched here: the gate stays bound to the approved pod's measurement for the whole run,
# so this pod can never succeed, however long it retries.
#
# Needs scripts/setup.sh to have run: it reads the resource record setup.sh wrote.
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHARED_DIR="$(cd "$SAMPLE_DIR/../_shared" && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/encrypted-image"
STATE_FILE="$TMP_DIR/state.env"

if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; . "$SAMPLE_DIR/.env"; set +a; fi
[[ -f "$STATE_FILE" ]] || { echo "ERROR: no $STATE_FILE; run ./scripts/setup.sh first" >&2; exit 1; }
set -a; . "$STATE_FILE"; set +a

KUBE_CONTEXT="${KUBE_CONTEXT:-}"
GENPOLICY="${GENPOLICY:-eks-nitro-sandbox-genpolicy}"
PROFILE="$SHARED_DIR/confidential-profile.yaml"
CHANGED_POD_NAME="encrypted-image-changed"
# The one pinned value that differs from the approved pod.
CHANGED_ENV_NAME="DEMO_VARIANT"
CHANGED_ENV_VALUE="changed"

die() { echo "ERROR: $*" >&2; exit 1; }
kc() {
  if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi
}

export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

if [[ "${1:-}" == "--delete" ]]; then
  # Deleting it is part of the demonstration, not just tidying: a pod left behind would
  # go on retrying the pull for as long as it exists.
  kc delete pod "$CHANGED_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m
  exit 0
fi
[[ "${1:-}" == "" ]] || { echo "unknown argument: $1" >&2; exit 2; }

for c in aws jq kubectl base64 gzip; do command -v "$c" >/dev/null 2>&1 || die "$c is required"; done
command -v "$GENPOLICY" >/dev/null 2>&1 || die "$GENPOLICY is not on PATH"

echo "== 1/4 render the same pod with one pinned value changed =="
[[ -f "$TMP_DIR/pod-input.json" ]] || die "no $TMP_DIR/pod-input.json; run ./scripts/setup.sh first"
jq --arg name "$CHANGED_POD_NAME" --arg n "$CHANGED_ENV_NAME" --arg v "$CHANGED_ENV_VALUE" '
  .metadata.name = $name
  | .metadata.labels["app.kubernetes.io/name"] = $name
  | .spec.containers[0].env += [{name: $n, value: $v}]
' "$TMP_DIR/pod-input.json" > "$TMP_DIR/changed-pod-input.json"
# Everything the policy pins, other than that one variable, is identical. The hostname is
# pinned too, so it stays as it is; only metadata.name and the label differ besides, and
# neither is a pinned value.
diff_fields="$(jq -n --slurpfile a "$TMP_DIR/pod-input.json" --slurpfile b "$TMP_DIR/changed-pod-input.json" '
  ($a[0].spec | del(.containers[0].env)) as $x
  | ($b[0].spec | del(.containers[0].env)) as $y
  | if $x == $y then "spec identical apart from env" else "SPEC DIFFERS BEYOND env" end')"
[[ "$diff_fields" == '"spec identical apart from env"' ]] ||
  die "the changed pod differs from the approved pod in more than its environment; the demonstration would not isolate one pinned value"
echo "  added env $CHANGED_ENV_NAME=$CHANGED_ENV_VALUE; the rest of the spec is unchanged"

echo "== 2/4 generate the policy for the changed pod =="
genpolicy_home="$TMP_DIR/genpolicy-home"
[[ -f "$genpolicy_home/.docker/config.json" ]] ||
  die "no registry credentials in $genpolicy_home; re-run ./scripts/setup.sh"
HOME="$genpolicy_home" "$GENPOLICY" \
  --profile "$PROFILE" --with-pod-identity \
  --output-file-b64 "$TMP_DIR/changed-policy.b64" \
  "$TMP_DIR/changed-pod-input.json" | tee "$TMP_DIR/changed-genpolicy.log"

changed_pcr17="$(awk '
  /--- Predicted PCR17 ---/ { found = 1; next }
  found {
    value = tolower($0); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
    if (value ~ /^[0-9a-f]{96}$/) { print value; exit }
  }' "$TMP_DIR/changed-genpolicy.log")"
[[ "$changed_pcr17" =~ ^[0-9a-f]{96}$ ]] ||
  die "could not read a predicted PCR17 for the changed pod ($TMP_DIR/changed-genpolicy.log)"
[[ "$changed_pcr17" != "$PREDICTED_PCR17" ]] ||
  die "the changed pod's measurement is the same as the approved pod's, so the gate would release the key and this would show nothing"
echo "  approved PCR17: $PREDICTED_PCR17"
echo "  changed  PCR17: $changed_pcr17"

echo "== 3/4 confirm the gate still expects the approved measurement =="
# A denial only means "the measurement was refused" if the gate that produced it is the
# approved one. Read the live policy rather than trusting that nothing moved it.
aws kms get-key-policy --key-id "$KMS_KEY_ARN" --policy-name default \
  --query Policy --output text | jq . > "$TMP_DIR/kms-key-policy.live.json"
# The same predicate setup.sh's verify_key_policy applies, for the same reason: this
# pod's denial only means "the measurement was refused" if the gate is still the approved
# one, with no second allow that could reach a decrypt and with both denies still
# covering kms:Decrypt.
jq -e --arg pcr17 "$PREDICTED_PCR17" '
  def reaches_decrypt:
    ascii_downcase
    | . == "*" or . == "kms:*"
      or startswith("kms:decrypt") or startswith("kms:reencryptfrom");
  def actions: (.Action | if type == "array" then . else [.] end);
  ([.Statement[] | select(.Effect == "Allow") | actions[] | select(reaches_decrypt)]
    | length) as $allow_actions_reaching_decrypt
  | ([.Statement[] | select(.Sid == "AttestedDecryptOnly")
      | select(.Effect == "Allow")
      | select(.Condition.StringEqualsIgnoreCase["kms:RecipientAttestation:PCR17"] == $pcr17)
      | select(.Condition.StringEqualsIgnoreCase["kms:RecipientAttestation:PCR8:ServiceName"] == "eks.amazonaws.com")
    ] | length) as $allows
  | ([.Statement[] | select(.Sid == "DenyUnlessThePolicyMeasurementMatches")
      | select(.Effect == "Deny") | select(.Principal == "*")
      | select(actions | map(ascii_downcase) | index("kms:decrypt"))
      | select(.Condition.StringNotEqualsIgnoreCase["kms:RecipientAttestation:PCR17"] == $pcr17)
    ] | length) as $pcr17_denies
  | ([.Statement[] | select(.Sid == "DenyUnlessTheAttestationComesFromAnEKSSandbox")
      | select(.Effect == "Deny") | select(.Principal == "*")
      | select(actions | map(ascii_downcase) | index("kms:decrypt"))
      | select(.Condition.StringNotEqualsIgnoreCase["kms:RecipientAttestation:PCR8:ServiceName"] == "eks.amazonaws.com")
    ] | length) as $pcr8_denies
  | $allow_actions_reaching_decrypt == 1
    and $allows == 1 and $pcr17_denies == 1 and $pcr8_denies == 1
' "$TMP_DIR/kms-key-policy.live.json" >/dev/null ||
  die "the live KMS key policy is not the approved gate (read back into $TMP_DIR/kms-key-policy.live.json); not starting the changed pod, because its refusal would not show the measurement being refused"
echo "  the gate is bound to the approved measurement, unchanged"

echo "== 4/4 start the changed pod and wait for the refusal =="
changed_b64="$(tr -d '\r\n' < "$TMP_DIR/changed-policy.b64")"
jq --arg policy "$changed_b64" \
  '.metadata.annotations["sandbox.amazonaws.com/policy"] = $policy' \
  "$TMP_DIR/changed-pod-input.json" > "$TMP_DIR/rendered-changed-pod.json"
kc delete pod "$CHANGED_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
kc apply -f "$TMP_DIR/rendered-changed-pod.json"

became_ready=false
message=""
for _ in $(seq 60); do
  pod_json="$(kc get pod "$CHANGED_POD_NAME" -n "$NAMESPACE" -o json 2>/dev/null || true)"
  if [[ -n "$pod_json" ]]; then
    if [[ "$(jq -r '[.status.conditions[]? | select(.type == "Ready") | .status] | first // "False"' <<<"$pod_json")" == "True" ]]; then
      became_ready=true; break
    fi
    message="$(jq -r '
      [ .status.containerStatuses[]?
        | .state.waiting.message?, .state.terminated.message?,
          .lastState.waiting.message?, .lastState.terminated.message? ]
      | map(select(. != null)) | unique | join("\n")' <<<"$pod_json")"
    if grep -Eiq 'AccessDenied|not authorized|explicit deny' <<<"$message"; then break; fi
  fi
  sleep 5
done

# Redact before anything is printed or saved. KMS names the full role session in its
# error, and an EKS Pod Identity session name is built from the cluster and pod names, so
# the raw message carries both the account and the cluster.
printf '%s\n' "$message" \
  | sed -e 's/[0-9]\{12\}/<ACCOUNT_ID>/g' \
        -e 's|\(assumed-role/[^/]*/\)[^ "\\]*|\1<session>|g' \
  > "$TMP_DIR/changed-pod-message.txt"
kc get pod "$CHANGED_POD_NAME" -n "$NAMESPACE"
echo
cat "$TMP_DIR/changed-pod-message.txt"
echo

[[ "$became_ready" == false ]] ||
  die "the changed pod became Ready, so the gate released the layer key to a measurement it was not set to expect"
# "KMS Decrypt failed" on its own is only the agent's wrapper around any failed decrypt:
# throttling, a network error, an expired credential and a wrong key all wear it. The
# authorization wording is what the attestation condition, and only it, produces here.
grep -Eiq 'AccessDenied|not authorized|explicit deny' "$TMP_DIR/changed-pod-message.txt" ||
  die "the changed pod did not start, but its message is not an authorization denial, so this run does not show the gate refusing the measurement. Message above; full pod in: kubectl -n $NAMESPACE describe pod $CHANGED_POD_NAME"

echo "The changed pod was refused the layer key by KMS and cannot start."
echo "Delete it before you finish with the sample:  ./scripts/changed-pod.sh --delete"
