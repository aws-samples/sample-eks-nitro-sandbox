"""Serve the shared synthetic supplier data over unauthenticated HTTP.

This fixture has no supplier credential or purchasing integration. It reuses the
shared request handler; the Box example tests its own role restrictions instead.
"""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import sys
from http.server import ThreadingHTTPServer


def serve(*, bind="0.0.0.0", port=8080, analyst_source=Path("/opt/analyst"),
          supplier_source=Path("/opt/supplier-api/supplier_api.py"),
          fixtures=Path("/opt/analyst/fixtures"), state=Path("/var/lib/supplier")):
    """Run in the supplier process, separate from the controller and its environment."""
    # The shared handler accepts an absent or empty header against this empty key.
    # No secret file is created, and the shared source remains unchanged.
    os.environ["SUPPLIER_KEY_FILE"] = "/dev/null"
    os.environ["SUPPLIER_STATE_DIR"] = str(state)
    sys.path.insert(0, str(analyst_source))
    spec = importlib.util.spec_from_file_location("shared_supplier_api", supplier_source)
    supplier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supplier)
    supplier.AVAILABILITY_FIXTURE = Path(fixtures) / "availability.json"
    server = ThreadingHTTPServer((bind, port), supplier.Handler)
    server.daemon_threads = True
    print(json.dumps({"origin": f"http://{bind}:{server.server_port}"}), flush=True)
    try:
        server.serve_forever(poll_interval=0.05)
    finally:
        server.server_close()


if __name__ == "__main__":
    serve()
