#!/usr/bin/env bash
# The other half of the evidence: the digest-pinned policy refusing the same new release.
#
#   ./scripts/pinned-arm.sh            # start it, wait for the refusal, print it
#   ./scripts/pinned-arm.sh --delete   # delete it again
#
# It starts a second pod that runs release two's image under the DEFAULT policy setup.sh
# generated for release one, which pins that release's digest. Everything the policy pins
# is identical to the approved pod except the image, so the refusal is a refusal of the
# image and not of anything else. Without this arm a reader could not tell a signer-based
# policy from no policy at all.
#
# Needs ./scripts/setup.sh and ./scripts/new-version.sh to have run.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_env
load_state
require_commands aws kubectl jq base64

if [[ "${1:-}" == "--delete" ]]; then
  # Deleting it matters: a pod left behind goes on retrying for as long as it exists.
  kc delete pod "$PINNED_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m
  exit 0
fi
[[ "${1:-}" == "" ]] || { echo "unknown argument: $1" >&2; exit 2; }

# No apostrophe in this message: bash processes quotes inside ${VAR:?word} even within
# double quotes, so one would make the whole script a syntax error.
: "${DIGEST_TWO:?run ./scripts/new-version.sh first, because this arm needs the second release image}"

step "1/3 confirm the pinned policy pins release $RELEASE_ONE, not release $RELEASE_TWO"
[[ -f "$TMP_DIR/policy.pinned.yaml" ]] || die "no $TMP_DIR/policy.pinned.yaml; run ./scripts/setup.sh first"
grep -q "image_ref == \".*@$DIGEST_ONE\"" "$TMP_DIR/policy.pinned.yaml" ||
  die "the pinned policy does not pin release $RELEASE_ONE's digest ($DIGEST_ONE), so its refusal would not be a digest pin refusing a new image"
grep -q "$DIGEST_TWO" "$TMP_DIR/policy.pinned.yaml" &&
  die "the pinned policy mentions release $RELEASE_TWO's digest, so it would admit the new image and show nothing"
echo "  it pins $DIGEST_ONE and does not mention $DIGEST_TWO"

step "2/3 start the pinned pod on release $RELEASE_TWO's image"
pinned_b64="$(tr -d '\r\n' < "$TMP_DIR/policy.pinned.b64")"
image_uri="$REGISTRY/$ECR_REPOSITORY:$RELEASE_TWO"
# metadata.name and the name label are the only things changed besides the image and the
# policy: neither is a value the policy pins. The hostname in particular stays as the
# approved pod's, because the policy pins it, and a different hostname would give the
# guest a second reason to refuse.
jq --arg name "$PINNED_POD_NAME" --arg img "$image_uri" --arg policy "$pinned_b64" '
  .metadata.name = $name
  | .metadata.labels["app.kubernetes.io/name"] = $name
  | .spec.containers[0].image = $img
  | .metadata.annotations["sandbox.amazonaws.com/policy"] = $policy
' "$TMP_DIR/pod-input.json" > "$TMP_DIR/rendered-pod-pinned.json"
differs="$(jq -n --slurpfile a "$TMP_DIR/rendered-pod.json" --slurpfile b "$TMP_DIR/rendered-pod-pinned.json" '
  ($a[0].spec | .containers[0].image = "X") as $x
  | ($b[0].spec | .containers[0].image = "X") as $y
  | if $x == $y then "no" else "yes" end')"
[[ "$differs" == '"no"' ]] ||
  die "the pinned pod differs from the approved pod in more than its image, so its refusal would not isolate the image"
echo "  the spec differs from the approved pod in the image tag and the policy only"
kc delete pod "$PINNED_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
kc apply -f "$TMP_DIR/rendered-pod-pinned.json"

step "3/3 wait for the guest to refuse it"
became_ready=no
if wait_for_pod "$PINNED_POD_NAME" 600; then became_ready=yes; fi
printf '%s\n' "$POD_MESSAGE" | redact > "$TMP_DIR/pinned-pod-message.txt"
kc get pod "$PINNED_POD_NAME" -n "$NAMESPACE" | redact
echo
cat "$TMP_DIR/pinned-pod-message.txt"
echo

[[ "$became_ready" == no ]] ||
  die "the pinned pod became Ready, so the digest pin admitted an image it had never seen. The sample's claim about the pin is wrong; do not publish this run."
# A pod that simply failed to start is not evidence. The message has to name the policy
# refusing the operation, which is what a digest that does not match produces here: a
# pull failure, a throttle or an expired credential all look like "not Ready" too.
grep -Eiq 'denied|not permitted|policy' "$TMP_DIR/pinned-pod-message.txt" ||
  die "the pinned pod did not start, but its message is not a policy refusal, so this run does not show the digest pin refusing the image. Message above; full pod in: kubectl -n $NAMESPACE describe pod $PINNED_POD_NAME"

printf '\nThe digest-pinned policy refused release %s, which it had never seen.\n' "$RELEASE_TWO"
echo "Delete it before you finish:  ./scripts/pinned-arm.sh --delete"
