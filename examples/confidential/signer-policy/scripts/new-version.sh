#!/usr/bin/env bash
# The provider ships its next release, and the operator runs it with no policy change.
#
#   ./scripts/new-version.sh
#
# It builds a different image, pushes it under a new tag, signs it with the same AWS
# Signer profile, and restarts the pod on that tag carrying the SAME policy annotation
# setup.sh generated. Nothing is regenerated: the annotation is compared against the hash
# setup.sh recorded, and the run stops if it differs, because then the pod starting would
# show nothing.
#
# Needs ./scripts/setup.sh to have run.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ "${1:-}" == "" ]] || { echo "unknown argument: $1" >&2; exit 2; }

load_env
load_state
require_commands aws docker notation kubectl jq base64 sha256sum

step "1/4 the provider builds, pushes and signs release $RELEASE_TWO"
write_registry_credentials "$REGISTRY"
digest_two="$(build_push_sign "$RELEASE_TWO" "$REGISTRY" "$SIGNING_PROFILE_ARN")"
[[ "$digest_two" != "$DIGEST_ONE" ]] ||
  die "release $RELEASE_TWO came out at the same digest as release $RELEASE_ONE ($digest_two), so there is no new image here and the run would prove nothing. Change something in the Dockerfile."
echo "  release $RELEASE_ONE was $DIGEST_ONE"
echo "  release $RELEASE_TWO is  $digest_two"
state_put RELEASE_TWO "$RELEASE_TWO"
state_put DIGEST_TWO "$digest_two"

step "2/4 point the pod at the new tag, with the policy untouched"
image_uri="$REGISTRY/$ECR_REPOSITORY:$RELEASE_TWO"
signer_b64="$(tr -d '\r\n' < "$TMP_DIR/policy.signer.b64")"
# The annotation this pod will carry has to be the very string setup.sh generated. If the
# policy had been regenerated for the new image, the pod starting would show only that a
# fresh policy admits the image it was made for, which is not the claim.
now_sha="$(printf '%s' "$signer_b64" | sha256sum | cut -d' ' -f1)"
[[ "$now_sha" == "$POLICY_SIGNER_SHA256" ]] ||
  die "the policy in $TMP_DIR/policy.signer.b64 is not the one setup.sh generated (sha256 $now_sha, recorded $POLICY_SIGNER_SHA256). Run ./scripts/clean.sh and start again, so this run shows the original policy admitting the new release."
echo "  policy annotation sha256: $now_sha (unchanged since setup.sh)"
jq --arg img "$image_uri" --arg policy "$signer_b64" '
  .spec.containers[0].image = $img
  | .metadata.annotations["sandbox.amazonaws.com/policy"] = $policy
' "$TMP_DIR/pod-input.json" > "$TMP_DIR/rendered-pod-two.json"
# Everything the policy pins must be identical to the approved pod apart from the image,
# or a pod that starts would not be evidence about the image. The image is the only field
# allowed to differ.
differs="$(jq -n --slurpfile a "$TMP_DIR/rendered-pod.json" --slurpfile b "$TMP_DIR/rendered-pod-two.json" '
  ($a[0].spec | .containers[0].image = "X") as $x
  | ($b[0].spec | .containers[0].image = "X") as $y
  | if $x == $y then "no" else "yes" end')"
[[ "$differs" == '"no"' ]] ||
  die "the new pod differs from the approved pod in more than its image, so it would not isolate the image as the thing that changed"
echo "  the spec differs from the approved pod in the image tag and nothing else"

step "3/4 restart the pod on the new release"
# The policy annotation is immutable on a running pod, so the pod is replaced rather than
# patched. It is replaced with the same annotation it had.
kc delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
kc apply -f "$TMP_DIR/rendered-pod-two.json"
if ! wait_for_pod "$POD_NAME" 900; then
  printf '%s\n' "$POD_MESSAGE" | redact
  die "the pod did not start on release $RELEASE_TWO. Its message is above; the full pod is in: kubectl -n $NAMESPACE describe pod $POD_NAME"
fi

step "4/4 read back what is running"
kc get pod "$POD_NAME" -n "$NAMESPACE" -o \
  "custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,IMAGE:.spec.containers[0].image,IMAGEID:.status.containerStatuses[0].imageID" \
  | redact
# The digest the guest actually prepared, read from the pod rather than from the registry.
running_id="$(kc get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.containerStatuses[0].imageID}')"
grep -q "$digest_two" <<<"$running_id" ||
  die "the pod is running, but its imageID ($running_id) does not carry release $RELEASE_TWO's digest, so this is not the new image"

printf '\n%s is Ready on release %s, under the policy generated for release %s.\n' \
  "$POD_NAME" "$RELEASE_TWO" "$RELEASE_ONE"
echo "Nothing was regenerated: the annotation is the same string, sha256 $now_sha."
echo "Now show what the digest pin would have done:  ./scripts/pinned-arm.sh"
