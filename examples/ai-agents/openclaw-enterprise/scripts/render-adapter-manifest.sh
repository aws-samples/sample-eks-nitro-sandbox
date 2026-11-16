#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 MANIFEST ADAPTER_IMAGE OWNERSHIP_INIT_IMAGE RUNTIME_IMAGE" >&2
  exit 64
fi

manifest="$1"
adapter_image="$2"
ownership_init_image="$3"
runtime_image="$4"
digest_pattern='^.+@sha256:[0-9a-f]{64}$'

[[ -f "$manifest" ]] || {
  echo "manifest not found: $manifest" >&2
  exit 66
}
[[ "$adapter_image" =~ $digest_pattern ]] || {
  echo "adapter image must use an exact sha256 digest" >&2
  exit 65
}
[[ "$ownership_init_image" =~ $digest_pattern ]] || {
  echo "ownership helper image must use an exact sha256 digest" >&2
  exit 65
}
[[ "$runtime_image" =~ $digest_pattern ]] || {
  echo "runtime image must use an exact sha256 digest" >&2
  exit 65
}
[[ "$adapter_image" != "$ownership_init_image" ]] || {
  echo "adapter and ownership helper images must differ" >&2
  exit 65
}
[[ "$runtime_image" != "$ownership_init_image" ]] || {
  echo "runtime and ownership helper images must differ" >&2
  exit 65
}

export ADAPTER_IMAGE="$adapter_image"
export OWNERSHIP_INIT_IMAGE="$ownership_init_image"
export RUNTIME_IMAGE="$runtime_image"

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

yq eval '
  (select(.kind == "Deployment" and
    .metadata.name == "openclaw-enterprise-nitro-adapter") |
    .spec.template.spec.containers[] | select(.name == "webhook") |
    .image) = strenv(ADAPTER_IMAGE) |
  (select(.kind == "Deployment" and
    .metadata.name == "openclaw-enterprise-nitro-adapter") |
    .spec.template.spec.containers[] | select(.name == "webhook") |
    .env) += [{
      "name": "OCE_OWNERSHIP_INIT_IMAGE",
      "value": strenv(OWNERSHIP_INIT_IMAGE)
    }, {
      "name": "OCE_RUNTIME_IMAGES",
      "value": strenv(RUNTIME_IMAGE)
    }]
' "$manifest" >"$rendered"

# shellcheck disable=SC2016 # yq reads the exported values through strenv().
yq eval-all -e '
  [.] | map(select(
    .kind == "Deployment" and
    .metadata.name == "openclaw-enterprise-nitro-adapter"
  )) as $deployments |
  [
    ($deployments | length) == 1,
    ($deployments[0].spec.template.spec.containers |
      map(select(.name == "webhook")) | length) == 1,
    ($deployments[0].spec.template.spec.containers[] |
      select(.name == "webhook") | .image) == strenv(ADAPTER_IMAGE),
    ($deployments[0].spec.template.spec.containers[] |
      select(.name == "webhook") |
      [.env[] | select(
        .name == "OCE_OWNERSHIP_INIT_IMAGE" and
        .value == strenv(OWNERSHIP_INIT_IMAGE)
      )] | length) == 1
    ,
    ($deployments[0].spec.template.spec.containers[] |
      select(.name == "webhook") |
      [.env[] | select(
        .name == "OCE_RUNTIME_IMAGES" and
        .value == strenv(RUNTIME_IMAGE)
      )] | length) == 1
  ] | all
' "$rendered" >/dev/null

cat "$rendered"
