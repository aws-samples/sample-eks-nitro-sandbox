# The one image this sample builds. All three of its pods run it: the sandboxed workload,
# the ordinary comparison pod and the ordinary no-attestation control, each picking a
# different file. One image is deliberate: the control's refusal says something about the
# attestation only if everything else about it is the same.
#
# The build context is the Confidential section folder, examples/confidential, not this
# sample's folder, because the image needs the attested-recipient helper the Confidential
# samples share. scripts/setup.sh builds it as:
#
#   docker build -f secrets-manager-secret/Dockerfile -t <uri> examples/confidential
# Pinned by digest as well as by tag: the tag moves, and the digest is what the Cedar
# policy ends up pinning by way of this image's own digest. Python 3.12.15.
FROM python:3.12-slim-bookworm@sha256:6a0e06f5ba0b373d051aabd3fffb9b873f27f9a2a3a14bcbe37dee6f0e3bbc70

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY secrets-manager-secret/src/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --requirement /app/requirements.txt

# The shared helper, then this sample's three files. main.py is the workload; the other
# two are the entry points the ordinary pods override the command with.
COPY _shared/attested_recipient.py /app/attested_recipient.py
COPY secrets-manager-secret/src/readings.py /app/readings.py
COPY secrets-manager-secret/src/no_attestation.py /app/no_attestation.py
COPY secrets-manager-secret/src/app.py /app/app.py

# Numeric, and the same ID the pod spec sets. The generator pins the identity from the pod
# spec, and a numeric USER here keeps the image and the policy agreed.
USER 65534:65534

ENTRYPOINT ["python", "/app/app.py"]
