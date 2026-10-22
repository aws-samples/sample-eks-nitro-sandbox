# The image this sample signs AND the tool that verifies it, in one.
#
# The same image is pushed to two ECR repositories: one copy is signed by AWS
# Signer, the other is left unsigned. Each pod verifies its OWN image reference
# in-guest with `notation verify`, so a single build backs both the positive
# (signed) and negative (unsigned) case.
#
# It bakes everything `notation verify` needs so verification is self-contained:
#   * the Notation CLI,
#   * the AWS Signer Notation plugin (com.amazonaws.signer.notation.plugin),
#   * the AWS Signer root certificate in a signingAuthority trust store,
#   * a trust policy pinned to this sample's signing-profile ARN.
# The signature itself is NOT baked in: it lives in ECR and is pulled at verify
# time (see the README: this is why the network-isolated pod cannot verify).
#
# Tool versions are ARGs so scripts/setup.sh can override without editing this
# file. The base tag and apt packages are NOT pinned by digest, so a rebuild may
# differ; setup.sh does not rebuild when the :v1 tag already exists in the
# (IMMUTABLE) repositories, which keeps re-runs idempotent. Pin FROM by digest if
# you need byte-for-byte reproducibility.
FROM public.ecr.aws/docker/library/debian:bookworm-slim

ARG NOTATION_VERSION=1.3.2
ARG ECR_CRED_HELPER_VERSION=0.12.0
# Signing-profile ARN this image trusts, and the ECR registry host it pulls
# signatures from. setup.sh passes the real values; the defaults document shape.
ARG SIGNING_PROFILE_ARN=arn:aws:signer:us-west-2:111122223333:/signing-profiles/nitro_sample_image_signing
ARG REGISTRY=111122223333.dkr.ecr.us-west-2.amazonaws.com

# notation reads its config (trust store and trust policy) from $XDG_CONFIG_HOME
# and its registry credentials from $DOCKER_CONFIG. World-readable paths under /
# keep them usable by uid 65534 with a read-only root filesystem: nothing is
# written to them at verify time. The signature pull authenticates to ECR through
# docker-credential-ecr-login, which uses the pod's Pod Identity credentials.
ENV XDG_CONFIG_HOME=/etc/notation-config
ENV NOTATION_HOME=/etc/notation-config/notation
ENV DOCKER_CONFIG=/etc/notation-config/docker

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) nartifact=amd64 ;; \
      arm64) nartifact=arm64 ;; \
      *) echo "unsupported arch $arch" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl tar unzip; \
    rm -rf /var/lib/apt/lists/*; \
    # Notation CLI
    curl -fsSL -o /tmp/notation.tgz \
      "https://github.com/notaryproject/notation/releases/download/v${NOTATION_VERSION}/notation_${NOTATION_VERSION}_linux_${nartifact}.tar.gz"; \
    tar -xzf /tmp/notation.tgz -C /usr/local/bin notation; \
    rm /tmp/notation.tgz; \
    # AWS Signer Notation plugin. AWS publishes a .zip (no SHA256, it uses GPG
    # signatures), so install it via notation. With XDG_CONFIG_HOME set, it lands
    # in the baked config dir. setup.sh records the version it resolves to.
    curl -fsSL -o /tmp/signer-plugin.zip \
      "https://d2hvyiie56hcat.cloudfront.net/linux/${nartifact}/plugin/latest/notation-aws-signer-plugin.zip"; \
    notation plugin install --file /tmp/signer-plugin.zip; \
    rm /tmp/signer-plugin.zip; \
    # AWS Signer root certificate -> signingAuthority trust store "aws-signer-ts".
    # notation's directory is "truststore" (no hyphen); a hyphen makes notation
    # report the store as non-existent at verify time.
    ts_dir="${NOTATION_HOME}/truststore/x509/signingAuthority/aws-signer-ts"; \
    mkdir -p "$ts_dir"; \
    curl -fsSL -o "${ts_dir}/aws-signer-notation-root.cert" \
      "https://d2hvyiie56hcat.cloudfront.net/aws-signer-notation-root.cert"; \
    # amazon-ecr-credential-helper: lets notation pull the signature from ECR
    # using the pod's Pod Identity credentials, without a stored password.
    curl -fsSL -o /usr/local/bin/docker-credential-ecr-login \
      "https://amazon-ecr-credential-helper-releases.s3.us-east-2.amazonaws.com/${ECR_CRED_HELPER_VERSION}/linux-${nartifact}/docker-credential-ecr-login"; \
    chmod +x /usr/local/bin/docker-credential-ecr-login; \
    chmod -R a+rX "$XDG_CONFIG_HOME"

# Route ECR registry auth through the credential helper (no stored secret).
RUN mkdir -p "$DOCKER_CONFIG"; \
    printf '{"credHelpers":{"%s":"ecr-login"}}\n' "$REGISTRY" > "$DOCKER_CONFIG/config.json"; \
    chmod -R a+rX "$DOCKER_CONFIG"

# Trust policy: trust ONLY this sample's signing profile, and skip revocation so
# the ONLY verify-time egress is the ECR signature pull (documented in README).
RUN printf '%s\n' \
  '{' \
  '  "version": "1.0",' \
  '  "trustPolicies": [{' \
  '    "name": "aws-signer-image-signing",' \
  '    "registryScopes": ["*"],' \
  '    "signatureVerification": { "level": "strict", "override": { "revocation": "skip" } },' \
  '    "trustStores": ["signingAuthority:aws-signer-ts"],' \
  "    \"trustedIdentities\": [\"${SIGNING_PROFILE_ARN}\"]" \
  '  }]' \
  '}' > "${NOTATION_HOME}/trustpolicy.json"; \
  chmod a+r "${NOTATION_HOME}/trustpolicy.json"

USER 65534:65534

# The workload just idles; verification is driven from the page via `kubectl exec`,
# which reaches the guest over the sandbox's internal control channel.
ENTRYPOINT ["/bin/sh", "-c", "echo image-signing-ready; exec sleep 3600"]
