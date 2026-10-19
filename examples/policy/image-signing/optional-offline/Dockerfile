# Optional variant: verify with no network at all.
#
# This image bakes the signed image AND its AWS Signer signature into an on-disk
# OCI image layout, next to the same trust material the main verifier image
# carries. `notation verify --oci-layout` then reads the signature from disk, so a
# pod running this image verifies the signature under
# sandbox.amazonaws.com/network-isolated: "true", with no registry pull and no
# egress of any kind.
#
# The trade-off is real: with no network, revocation cannot be checked, so the
# trust policy sets revocation: skip. A revoked signing profile or certificate
# would not be detected here. If revocation must be enforced, the guest needs
# egress to the AWS Signer regional endpoint and cannot run network-isolated.
#
# scripts/build-offline.sh stages the OCI layout into ./layout with `oras cp`
# before this build, and passes the signing-profile ARN and the layout's scope.
FROM public.ecr.aws/docker/library/debian:bookworm-slim

ARG NOTATION_VERSION=1.3.2
ARG SIGNING_PROFILE_ARN=arn:aws:signer:us-west-2:111122223333:/signing-profiles/nitro_sample_image_signing
# The OCI layout's artifact path, used as the trust-policy scope. setup/build pass
# the real value; the default documents shape.
ARG LAYOUT_SCOPE=111122223333.dkr.ecr.us-west-2.amazonaws.com/nitro-sample-image-signing-signed

ENV XDG_CONFIG_HOME=/etc/notation-config
ENV NOTATION_HOME=/etc/notation-config/notation
# Experimental --oci-layout flag; set here so the pod's verify command is plain.
ENV NOTATION_EXPERIMENTAL=1

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in amd64) nartifact=amd64 ;; arm64) nartifact=arm64 ;; *) echo "unsupported arch $arch" >&2; exit 1 ;; esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl tar unzip; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL -o /tmp/notation.tgz \
      "https://github.com/notaryproject/notation/releases/download/v${NOTATION_VERSION}/notation_${NOTATION_VERSION}_linux_${nartifact}.tar.gz"; \
    tar -xzf /tmp/notation.tgz -C /usr/local/bin notation; \
    rm /tmp/notation.tgz; \
    curl -fsSL -o /tmp/signer-plugin.zip \
      "https://d2hvyiie56hcat.cloudfront.net/linux/${nartifact}/plugin/latest/notation-aws-signer-plugin.zip"; \
    notation plugin install --file /tmp/signer-plugin.zip; \
    rm /tmp/signer-plugin.zip; \
    ts_dir="${NOTATION_HOME}/truststore/x509/signingAuthority/aws-signer-ts"; \
    mkdir -p "$ts_dir"; \
    curl -fsSL -o "${ts_dir}/aws-signer-notation-root.cert" \
      "https://d2hvyiie56hcat.cloudfront.net/aws-signer-notation-root.cert"; \
    chmod -R a+rX "$XDG_CONFIG_HOME"

# The pre-staged OCI layout: the signed image and its signature, copied from ECR
# on a networked host by scripts/build-offline.sh. This is the only thing the pod
# reads at verify time.
COPY layout /var/lib/image-signing/layout

# Trust policy pinned to this sample's signing profile, with revocation skipped so
# verification needs no network. The scope matches the layout's artifact path.
RUN printf '%s\n' \
  '{' \
  '  "version": "1.0",' \
  '  "trustPolicies": [{' \
  '    "name": "aws-signer-image-signing-offline",' \
  "    \"registryScopes\": [\"${LAYOUT_SCOPE}\"]," \
  '    "signatureVerification": { "level": "strict", "override": { "revocation": "skip" } },' \
  '    "trustStores": ["signingAuthority:aws-signer-ts"],' \
  "    \"trustedIdentities\": [\"${SIGNING_PROFILE_ARN}\"]" \
  '  }]' \
  '}' > "${NOTATION_HOME}/trustpolicy.json"; \
  chmod -R a+rX "$XDG_CONFIG_HOME"

USER 65534:65534
ENTRYPOINT ["/bin/sh", "-c", "echo image-signing-offline-ready; exec sleep 3600"]
