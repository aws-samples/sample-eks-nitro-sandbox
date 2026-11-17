# Build with examples/subagent-security as the context.
FROM public.ecr.aws/docker/library/python:3.13-slim-bookworm@sha256:281d39ff02e3b389401586134ff9e6572954687822a58055ec07a60ded4e0b7f
COPY analyst/src/business.py /opt/analyst/business.py
COPY analyst/fixtures/ /opt/analyst/fixtures/
COPY analyst/supplier-api/supplier_api.py /opt/supplier-api/supplier_api.py
COPY strands-box/supplier/http_supplier.py /opt/supplier-api/http_supplier.py
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 65534:65534
EXPOSE 8080
CMD ["python3", "/opt/supplier-api/http_supplier.py"]
