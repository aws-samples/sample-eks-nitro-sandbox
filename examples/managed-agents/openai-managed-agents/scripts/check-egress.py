#!/usr/bin/env python3
"""Egress check (the two allowed hosts and two refused), run against a sandbox pod from your machine.

Confirms the network policy allows exactly the two OpenAI hosts (and DNS to
resolve them) and refuses everything else. Prints one line per host.

The sample image does NOT ship this file (the Dockerfile copies only the
launcher package). Run it from your machine by piping it into the pod's python,
so there is nothing to install in the image:

  POD=$(kubectl get pods -l app=openai-sandbox-executor \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -i $POD -- python - < scripts/check-egress.py

The README's "Check the egress policy" step runs the same probes inline; this
file is the same check kept as a script you can pipe in.
"""

from __future__ import annotations

import socket

ALLOWED = ("api.openai.com", "codex-cloud-environments.chatgpt.com")
REFUSED = ("example.com", "sts.us-west-2.amazonaws.com")


def probe(host: str) -> str:
    try:
        socket.create_connection((host, 443), timeout=5).close()
        return "connected"
    except OSError as exc:
        return f"{type(exc).__name__} {exc}"


def main() -> int:
    ok = True
    for host in ALLOWED:
        result = probe(host)
        print(f"{host} {result}")
        ok = ok and result == "connected"
    for host in REFUSED:
        result = probe(host)
        print(f"{host} {result}")
        ok = ok and result != "connected"
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
