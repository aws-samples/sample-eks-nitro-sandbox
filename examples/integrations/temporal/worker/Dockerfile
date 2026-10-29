# The Temporal Worker image: the workflow, its activities, and the Nitro sandbox
# provider that maps each lifecycle verb onto one Kubernetes operation.
#
# Nothing in this image is sandboxed. The Worker is an ordinary pod, because it
# is the trusted orchestrator that calls the Kubernetes API. The isolation
# boundary is the other pod, the Sandbox this one creates.
#
# Built and pushed by scripts/setup.sh. Every file it copies in is under
# worker/, which is the set the image tag is derived from, so a change to any of
# them produces a new tag.
FROM public.ecr.aws/docker/library/python:3.13-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /opt/harness

COPY worker/requirements.txt /opt/harness/requirements.txt
RUN pip install --no-cache-dir -r /opt/harness/requirements.txt \
  && pip show temporalio kubernetes | grep -E '^(Name|Version):'

# The harness, and the Sandbox manifest the provider renders and creates. The
# manifest is in the image rather than in a ConfigMap so that the image is what
# decides what the provider can create.
COPY worker/harness /opt/harness/harness
COPY worker/sandbox.yaml /opt/harness/sandbox.yaml

RUN useradd --create-home --uid 10001 worker \
  && chown -R worker:worker /opt/harness
# By UID, not by name: with runAsNonRoot set on the pod and a non-numeric USER
# here, the kubelet cannot verify the user is not root and refuses to start the
# container with a CreateContainerConfigError.
USER 10001
ENV HOME=/home/worker \
    PYTHONPATH=/opt/harness \
    SANDBOX_MANIFEST=/opt/harness/sandbox.yaml

CMD ["python", "-m", "harness.worker"]
