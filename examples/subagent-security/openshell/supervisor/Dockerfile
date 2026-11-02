# The upstream OpenShell supervisor image, with this sample's certificate authority added
# to its trust bundle. Nothing else changes.
#
# Why this image exists at all: the supervisor is what relays the analyst's approved
# requests, and it verifies TLS against the certificates in its own image. The shared
# synthetic supplier API serves TLS from a sample certificate authority this run creates,
# which no public bundle knows, so without this the supervisor would refuse every request
# with a TLS error. A TLS error is not a policy refusal, and a page that showed one as
# though it were would be wrong about the thing it is teaching. The alternative, turning
# TLS verification off, would remove a control the sample should keep.
#
# SUPERVISOR_IMAGE is the pinned upstream digest from versions.json, and BASE_IMAGE is
# only somewhere to run `cat`: the upstream image is built FROM scratch and has no shell.
ARG SUPERVISOR_IMAGE
ARG BASE_IMAGE
FROM ${SUPERVISOR_IMAGE} AS upstream

FROM ${BASE_IMAGE} AS bundle
COPY --from=upstream /etc/ssl/certs/ca-certificates.crt /bundle/ca-certificates.crt
COPY ca.crt /bundle/sample-ca.crt
# Append only a certificate. The two tests are what keep a mistake in the setup script
# from baking a private key into an image: the file has to look like a certificate, and
# it has to not look like a key.
RUN grep -q 'BEGIN CERTIFICATE' /bundle/sample-ca.crt \
 && ! grep -q 'PRIVATE KEY' /bundle/sample-ca.crt \
 && cat /bundle/sample-ca.crt >> /bundle/ca-certificates.crt

FROM ${SUPERVISOR_IMAGE}
COPY --from=bundle /bundle/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
