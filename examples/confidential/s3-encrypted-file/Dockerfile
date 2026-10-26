# The application the sandbox runs, and the encrypt helper the setup machine runs.
#
# The build context is examples/confidential/, not this folder, because the attested
# recipient is shared with the other Confidential samples:
#   docker build -f s3-encrypted-file/Dockerfile -t <tag> .
#
# Nothing in here is confidential. The image is the same for the approved pod and for the
# pod with one pinned value changed: what differs between them is the pod spec, and so the
# Cedar policy measurement KMS checks.
FROM python:3.12.11-slim-bookworm

# The pod has no business asking the instance metadata service for credentials: they come
# from EKS Pod Identity. Turning the metadata provider off keeps the SDK from falling back
# to the node's own role if the Pod Identity endpoint is slow to answer.
ENV AWS_EC2_METADATA_DISABLED=true \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY s3-encrypted-file/src/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --requirement /app/requirements.txt

COPY _shared/attested_recipient.py /app/attested_recipient.py
COPY s3-encrypted-file/src/encrypt_file.py /app/encrypt_file.py
COPY s3-encrypted-file/src/app.py /app/main.py

# A numeric user, not a name: the generated Cedar policy pins the identity, and the pod
# spec sets the same ids.
USER 65534:65534

ENTRYPOINT ["python", "/app/main.py"]
