# claude-sandbox-worker: one image, three roles, chosen by the container's args:
#   python -m worker poll    the poller Deployment
#   python -m worker serve   the sandbox, one session per pod (SandboxTemplate)
#   python -m worker stats   the optional warm-pool autoscaler
#
# The agent's bash tool runs /bin/bash at that exact path, which the Python base
# image provides. The Python SDK unpacks skills with its standard library, so no
# unzip, tar or Node is needed.
FROM public.ecr.aws/docker/library/python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app
COPY pyproject.toml ./
COPY src ./src
RUN pip install .

# Run as a non-root user. /workspace is the agent's working directory; the pod
# mounts an emptyDir over it, so it is fresh for every session.
RUN useradd --uid 1000 --create-home --home-dir /workspace agent
USER 1000
WORKDIR /workspace
# Library caches land in the writable workspace, not on the read-only root
# filesystem the pod runs with.
ENV HOME=/workspace

ENTRYPOINT ["python", "-m", "worker"]
