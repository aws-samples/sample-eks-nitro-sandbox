#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 MANIFEST ADAPTER_IMAGE OWNERSHIP_INIT_IMAGE" >&2
  exit 64
fi

manifest="$1"
adapter_image="$2"
ownership_init_image="$3"
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
[[ "$adapter_image" != "$ownership_init_image" ]] || {
  echo "adapter and ownership helper images must differ" >&2
  exit 65
}

export ADAPTER_IMAGE="$adapter_image"
export OWNERSHIP_INIT_IMAGE="$ownership_init_image"

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
    }]
' "$manifest"
