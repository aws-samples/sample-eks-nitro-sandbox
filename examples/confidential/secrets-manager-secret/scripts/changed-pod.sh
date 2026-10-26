#!/usr/bin/env bash
# Run a second pod, the same application with one pinned value changed, and show AWS KMS
# refuse it the secret.
#
#   ./scripts/changed-pod.sh            # run it, wait for the denial, print it
#   ./scripts/changed-pod.sh --delete   # delete it again
#
# The change is one environment variable's value. The confidential profile pins the
# container's environment, so the generated policy differs, its measurement differs, and the
# gate setup.sh installed no longer matches. Nothing about the KMS key policy is touched
# here: the gate stays bound to the approved pod's measurement for the whole run, so this
# pod can never succeed.
#
# Needs scripts/setup.sh to have run: it reads the resource record setup.sh wrote.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHARED_DIR="$(cd "$SAMPLE_DIR/../_shared" && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/secrets-manager-secret/run"
STATE_FILE="$TMP_DIR/state.env"

MANAGED_BY="secrets-manager-secret"

if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; . "$SAMPLE_DIR/.env"; set +a; fi
[[ -f "$STATE_FILE" ]] || { echo "ERROR: no $STATE_FILE; run ./scripts/setup.sh first" >&2; exit 1; }
set -a; . "$STATE_FILE"; set +a

KUBE_CONTEXT="${KUBE_CONTEXT:-}"
GENPOLICY="${GENPOLICY:-eks-nitro-sandbox-genpolicy}"
PROFILE="$SHARED_DIR/confidential-profile.yaml"
CHANGED_POD_NAME="secrets-manager-secret-changed"
# The one pinned value that differs from the approved pod.
CHANGED_ENV_NAME="DEMO_VARIANT"
CHANGED_ENV_VALUE="changed"

. "$SCRIPT_DIR/lib.sh"

export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

if [[ "${1:-}" == "--delete" ]]; then
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
  | (.spec.containers[0].env[] | select(.name == $n).value) = $v
' "$TMP_DIR/pod-input.json" > "$TMP_DIR/changed-pod-input.json"
# Everything the policy pins, other than that one variable, is identical. The hostname is
# pinned too, so it stays as it is; only metadata.name and one label differ besides, and
# neither is a pinned value.
diff_fields="$(jq -n --slurpfile a "$TMP_DIR/pod-input.json" --slurpfile b "$TMP_DIR/changed-pod-input.json" '
  ($a[0].spec | del(.containers[0].env)) as $x
  | ($b[0].spec | del(.containers[0].env)) as $y
  | ($a[0].spec.containers[0].env | map(.name)) as $xn
  | ($b[0].spec.containers[0].env | map(.name)) as $yn
  | if $x == $y and $xn == $yn then "ok" else "differs" end')"
[[ "$diff_fields" == '"ok"' ]] ||
  die "the changed pod differs from the approved pod in more than one environment variable's value; the demonstration would not isolate one pinned value"
echo "  set env $CHANGED_ENV_NAME=$CHANGED_ENV_VALUE; the rest of the spec is unchanged"

echo "== 2/4 generate the policy for the changed pod =="
genpolicy_home="$TMP_DIR/genpolicy-home"
[[ -f "$genpolicy_home/.docker/config.json" ]] ||
  die "no registry credentials in $genpolicy_home; re-run ./scripts/setup.sh"
HOME="$genpolicy_home" "$GENPOLICY" \
  --profile "$PROFILE" --with-pod-identity \
  --output-file-b64 "$TMP_DIR/changed-policy.b64" \
  "$TMP_DIR/changed-pod-input.json" | tee "$TMP_DIR/changed-genpolicy.log"

changed_pcr17="$(read_predicted_pcr17 "$TMP_DIR/changed-genpolicy.log")"
# Written-out hex class, not [0-9a-f]: a bracket range is matched against the locale's
# collating order, and this value is what the gate is compared against below.
[[ "$changed_pcr17" =~ ^[0123456789abcdef]{96}$ ]] ||
  die "could not read a predicted PCR17 for the changed pod ($TMP_DIR/changed-genpolicy.log)"
[[ "$changed_pcr17" != "$PREDICTED_PCR17" ]] ||
  die "the changed pod's measurement is the same as the approved pod's, so the gate would release the secret and this would show nothing"
echo "  approved PCR17: $PREDICTED_PCR17"
echo "  changed  PCR17: $changed_pcr17"

echo "== 3/4 confirm the gate still expects the approved measurement =="
# A denial only means "the measurement was refused" if the gate that produced it is the
# approved one. Read the live policy rather than trusting that nothing moved it, with the
# same gate.jq setup.sh used, from the same file.
verify_key_policy "$PREDICTED_PCR17"
echo "  the gate is bound to the approved measurement, unchanged"

echo "== 4/4 run the changed pod and wait for the refusal =="
changed_b64="$(tr -d '\r\n' < "$TMP_DIR/changed-policy.b64")"
jq --arg policy "$changed_b64" \
  '.metadata.annotations["sandbox.amazonaws.com/policy"] = $policy' \
  "$TMP_DIR/changed-pod-input.json" > "$TMP_DIR/rendered-changed-pod.json"
kc delete pod "$CHANGED_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
kc apply -f "$TMP_DIR/rendered-changed-pod.json"

# The application reaches its decrypt about a minute in, after its readings and its network
# probes, so this waits for the pod to finish rather than polling for a message.
phase=""
for _ in $(seq 180); do
  phase="$(kc get pod "$CHANGED_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$phase" == Succeeded || "$phase" == Failed ]]; then break; fi
  sleep 5
done
[[ "$phase" == Succeeded || "$phase" == Failed ]] ||
  die "the changed pod did not finish within 15 minutes; it is still $phase. Read: kubectl -n $NAMESPACE describe pod $CHANGED_POD_NAME"

# The application redacts the account ID and the role session itself before it prints an
# error, and this passes the logs through the same redaction again: a container message from
# the guest, which is not the application's own output, would otherwise carry both.
{ kc logs "$CHANGED_POD_NAME" -n "$NAMESPACE" -c main 2>/dev/null || true
  kc get pod "$CHANGED_POD_NAME" -n "$NAMESPACE" \
    -o jsonpath='{range .status.containerStatuses[*]}{.state.terminated.message}{.state.waiting.message}{end}' 2>/dev/null || true
} | redact > "$TMP_DIR/changed-pod.log"

kc get pod "$CHANGED_POD_NAME" -n "$NAMESPACE"
echo
cat "$TMP_DIR/changed-pod.log"
echo

[[ "$phase" == Failed ]] ||
  die "the changed pod ended $phase, so the gate released the secret to a measurement it was not set to expect"
# "attested-secret-error" on its own is only the application saying something went wrong:
# throttling, a network error and an expired credential all wear it. The authorization
# wording is what the attestation condition, and only it, produces here.
grep -Eiq 'AccessDenied|not authorized|explicit deny' "$TMP_DIR/changed-pod.log" ||
  die "the changed pod failed, but not with an authorization denial, so this run does not show the gate refusing the measurement. Output above; full pod in: kubectl -n $NAMESPACE describe pod $CHANGED_POD_NAME"
echo "The changed pod was refused the secret by KMS and ended Failed."
echo "Delete it before you finish with the sample:  ./scripts/changed-pod.sh --delete"
