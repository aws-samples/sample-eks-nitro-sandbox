FROM cgr.dev/chainguard/python:latest@sha256:b969ffa5d847b5acd28bd18b12d5b6631cb69c8289f03b309e19b68608724dc6

WORKDIR /app
COPY --chown=65532:65532 adapter.py server.py /app/

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
USER 65532:65532
EXPOSE 8443
ENTRYPOINT ["python", "/app/server.py"]
