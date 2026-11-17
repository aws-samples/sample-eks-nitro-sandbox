# The analyst and the model bridge in one image.
#
# Build it with examples/subagent-security/ as the context, so the shared analyst files
# and this sample's own src/ are both in reach:
#   docker build -f openshell/Dockerfile -t <repo>:<tag> .
#
# One image runs two different things, which is why it carries both halves:
#   * the analyst, started by OpenShell's runtime inside the Nitro sandbox. It has no AWS
#     role and reaches the network only through OpenShell's supervisor.
#   * the model bridge, an ordinary pod outside the sandbox, which is the only component
#     that holds AWS credentials.
# Running them from one image keeps the shared analyst code identical on both sides of
# the boundary, so a difference in behaviour cannot be a difference in build.
#
# OpenShell supplies its own in-pod runtime binary at sandbox start, so the image does
# not carry it.
FROM public.ecr.aws/docker/library/python:3.13-slim

# procps so the page can read the running analyst process, and ca-certificates so the
# bridge trusts the AWS endpoints it calls.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates procps \
    && rm -rf /var/lib/apt/lists/*

# --require-hashes, so the locked requirements.txt is the only thing that can be
# installed: a dependency resolved to another version fails the build.
COPY analyst/requirements.txt /opt/analyst/requirements.txt
RUN pip install --no-cache-dir --require-hashes -r /opt/analyst/requirements.txt

# The shared analyst: the same files every Subagent security sample runs.
COPY analyst/src/ /opt/analyst/
COPY analyst/fixtures/ /opt/analyst/fixtures/
# This sample's own part: the probes the analyst runs under OpenShell, the policy
# generator and the model bridge.
COPY openshell/src/ /opt/openshell/

# Two deliberate file modes, and the page's refusals depend on both.
#
# The case file is world-writable, so a process running as the same UID outside
# OpenShell's confinement can open it for writing. When the analyst is refused that open,
# the refusal is OpenShell's filesystem policy and not a Unix permission. The probe opens
# it for writing and closes it; it never changes a byte.
#
# The canary sits outside every path the policy grants and is world-readable, so the same
# control can read it while the analyst cannot.
RUN chmod 666 /opt/analyst/fixtures/case.json \
    && mkdir -p /protected \
    && printf 'synthetic-private-canary\n' > /protected/canary \
    && chmod 755 /protected && chmod 644 /protected/canary

# The analyst runs as an ordinary user. OpenShell sets the restricted process's identity
# itself, from process.run_as_user in the policy; this is the image's own default, which
# the bridge pod also runs under.
RUN useradd --create-home --uid 1000 --user-group analyst

# The interpreter path the policy's `binaries` rule names. Asserted here so a base-image
# bump cannot leave that rule pointing at a binary that is not there, which would be a
# policy that silently matches nothing.
RUN test -x /usr/local/bin/python3.13 || \
    (echo "the policy's binaries rule names /usr/local/bin/python3.13, which is missing" \
     && exit 1)

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    PYTHONPATH=/opt/analyst:/opt/openshell
USER 1000:1000
# Not /sandbox: the workspace volume is mounted there, so anything the image kept under
# it would be hidden. deploy/nitro-adapter.yaml explains why.
WORKDIR /opt/openshell
CMD ["sleep", "infinity"]
