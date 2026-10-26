# The synthetic supplier API, shared by every Subagent security sample.
#
# Build it with examples/subagent-security/ as the context, so the shared analyst files are
# in reach:
#   docker build -f analyst/supplier-api/Dockerfile -t <repo>:<tag> .
#
# It needs no Python packages: the server is standard library only, which keeps the pod a
# reader has to trust as small as the sample can make it.
FROM public.ecr.aws/docker/library/python:3.13-slim

COPY analyst/src/business.py /opt/analyst/business.py
COPY analyst/fixtures/ /opt/analyst/fixtures/
COPY analyst/supplier-api/supplier_api.py /opt/supplier-api/supplier_api.py

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 65534:65534
EXPOSE 8443
CMD ["python3", "/opt/supplier-api/supplier_api.py"]
