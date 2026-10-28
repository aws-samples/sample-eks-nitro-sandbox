#!/usr/bin/env bash
# Run a second pod, with the same application image and one pinned value changed, and show
# AWS KMS refuse to release the file's data key to it.
#
#   ./scripts/changed-pod.sh            # start it, wait for the denial, print it
#   ./scripts/changed-pod.sh --delete   # delete it again
#
# The change is one environment variable's value. The confidential profile pins the
# container's environment, so the generated policy differs, its measurement differs, and the
# gate setup.sh installed no longer matches. Nothing about the KMS key policy is touched
# here: the gate stays bound to the approved pod's measurement for the whole run, so this
# pod can never read the file, however long it retries.
#
# Needs scripts/setup.sh to have run: it reads the resource record setup.sh wrote.
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHARED_DIR="$(cd "$SAMPLE_DIR/../_shared" && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/s3-encrypted-file"
STATE_FILE="$TMP_DIR/state.env"

if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; . "$SAMPLE_DIR/.env"; set +a; fi
[[ -f "$STATE_FILE" ]] || { echo "ERROR: no $STATE_FILE; run ./scripts/setup.sh first" >&2; exit 1; }
set -a; . "$STATE_FILE"; set +a

KUBE_CONTEXT="${KUBE_CONTEXT:-}"
GENPOLICY="${GENPOLICY:-eks-nitro-sandbox-genpolicy}"
PROFILE="$SHARED_DIR/confidential-profile.yaml"
GATE_CHECK="$SAMPLE_DIR/scripts/kms-gate-check.jq"
CHANGED_POD_NAME="s3-encrypted-file-changed"
# The one pinned value that differs from the approved pod.
CHANGED_ENV_NAME="SAMPLE_VARIANT"
CHANGED_ENV_VALUE="changed"

die() { echo "ERROR: $*" >&2; exit 1; }
kc() {
  if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi
}

export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

if [[ "${1:-}" == "--delete" ]]; then
  kc delete pod "$CHANGED_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m
  exit 0
fi
[[ "${1:-}" == "" ]] || { echo "unknown argument: $1" >&2; exit 2; }

for c in aws jq kubectl base64 gzip; do command -v "$c" >/dev/null 2>&1 || die "$c is required"; done
command -v "$GENPOLICY" >/dev/null 2>&1 || die "$GENPOLICY is not on PATH"
[[ -f "$GATE_CHECK" ]] || die "the key policy check $GATE_CHECK is missing"

echo "== 1/4 render the same pod with one pinned value changed =="
[[ -f "$TMP_DIR/pod-input.json" ]] || die "no $TMP_DIR/pod-input.json; run ./scripts/setup.sh first"
jq --arg name "$CHANGED_POD_NAME" --arg n "$CHANGED_ENV_NAME" --arg v "$CHANGED_ENV_VALUE" '
  .metadata.name = $name
  | .metadata.labels["app.kubernetes.io/name"] = $name
  | (.spec.containers[0].env[] | select(.name == $n).value) = $v
' "$TMP_DIR/pod-input.json" > "$TMP_DIR/changed-pod-input.json"
# Everything the policy pins, other than that one value, is identical. The hostname is
# pinned too, so it stays as it is; only metadata.name and the label differ besides, and
# neither is a pinned value.
same_spec="$(jq -n --slurpfile a "$TMP_DIR/pod-input.json" --slurpfile b "$TMP_DIR/changed-pod-input.json" '
  ($a[0].spec | del(.containers[0].env)) as $x
  | ($b[0].spec | del(.containers[0].env)) as $y
  | ($a[0].spec.containers[0].env | map(select(.name != "SAMPLE_VARIANT"))) as $ex
  | ($b[0].spec.containers[0].env | map(select(.name != "SAMPLE_VARIANT"))) as $ey
  | ($x == $y) and ($ex == $ey)')"
[[ "$same_spec" == "true" ]] ||
  die "the changed pod differs from the approved pod in more than SAMPLE_VARIANT; the demonstration would not isolate one pinned value"
changed_value="$(jq -r '.spec.containers[0].env[] | select(.name == "SAMPLE_VARIANT").value' "$TMP_DIR/changed-pod-input.json")"
[[ "$changed_value" == "$CHANGED_ENV_VALUE" ]] ||
  die "the changed pod's $CHANGED_ENV_NAME is '$changed_value', not '$CHANGED_ENV_VALUE'"
echo "  $CHANGED_ENV_NAME=$CHANGED_ENV_VALUE; the rest of the spec is unchanged"

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
    if (value ~ /^[0123456789abcdef]{96}$/) { print value; exit }
  }' "$TMP_DIR/changed-genpolicy.log")"
[[ "$changed_pcr17" =~ ^[0123456789abcdef]{96}$ ]] ||
  die "could not read a predicted PCR17 for the changed pod ($TMP_DIR/changed-genpolicy.log)"
[[ "$changed_pcr17" != "$PREDICTED_PCR17" ]] ||
  die "the changed pod's measurement is the same as the approved pod's, so the gate would release the data key and this would show nothing"
echo "  approved PCR17: $PREDICTED_PCR17"
echo "  changed  PCR17: $changed_pcr17"

echo "== 3/4 confirm the gate still expects the approved measurement =="
# A denial only means "the measurement was refused" if the gate that produced it is the
# approved one. Read the live policy rather than trusting that nothing moved it, through the
# same file setup.sh checks it with.
aws kms get-key-policy --key-id "$KMS_KEY_ARN" --policy-name default \
  --query Policy --output text | jq . > "$TMP_DIR/kms-key-policy.live.json"
jq -e --arg mode gate --arg role "$IAM_ROLE_ARN" --arg roleid "$IAM_ROLE_ID" \
  --arg pcr17 "$PREDICTED_PCR17" -f "$GATE_CHECK" "$TMP_DIR/kms-key-policy.live.json" >/dev/null ||
  die "the live KMS key policy is not the approved gate (read back into $TMP_DIR/kms-key-policy.live.json); not starting the changed pod, because its refusal would not show the measurement being refused"
echo "  the gate is bound to the approved measurement, unchanged"

echo "== 4/4 start the changed pod and wait for the refusal =="
changed_b64="$(tr -d '\r\n' < "$TMP_DIR/changed-policy.b64")"
jq --arg policy "$changed_b64" \
  '.metadata.annotations["sandbox.amazonaws.com/policy"] = $policy' \
  "$TMP_DIR/changed-pod-input.json" > "$TMP_DIR/rendered-changed-pod.json"
kc delete pod "$CHANGED_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
kc apply -f "$TMP_DIR/rendered-changed-pod.json"

phase=""
for _ in $(seq 120); do
  phase="$(kc get pod "$CHANGED_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]]; then break; fi
  sleep 5
done
changed_log="$(kc logs "$CHANGED_POD_NAME" -n "$NAMESPACE" -c main 2>/dev/null || true)"
printf '%s\n' "$changed_log" > "$TMP_DIR/changed-pod.log"
kc get pod "$CHANGED_POD_NAME" -n "$NAMESPACE"
echo
printf '%s\n' "$changed_log"
echo

[[ "$phase" == "Failed" ]] ||
  die "the changed pod ended '$phase', not Failed. If it ended Succeeded, the gate released the data key to a measurement it was not set to expect."
if grep -Fq "attested-s3-ok" <<<"$changed_log"; then
  die "the changed pod printed the validation marker, so it read the file; the gate did not refuse its measurement"
fi
# "attested-s3-error" on its own is only the application's wrapper around any failure:
# throttling, a network error and an expired credential all wear it. The authorization
# wording is what the attestation condition, and only it, produces here.
grep -Eiq 'AccessDenied|not authorized|explicit deny' <<<"$changed_log" ||
  die "the changed pod failed, but its output is not an authorization denial, so this run does not show the gate refusing the measurement. Read $TMP_DIR/changed-pod.log"
echo "The changed pod was refused the data key by KMS and could not read the file."
echo "Delete it before you finish with the sample:  ./scripts/changed-pod.sh --delete"
