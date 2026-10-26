"""The synthetic supplier system, shared by every Subagent security sample.

A small HTTPS server with a handful of endpoints and one API key. It stands in for a
supplier's ordering system so a sample can show which operations a confined tool role is
allowed to perform. It holds synthetic data only: the proposals are made up and there is
no purchasing integration behind any of these paths.

It deliberately accepts an authenticated mutation. A purchase order or a supplier-record
change succeeds here when the request carries the real key, which is what makes a refusal
meaningful: the confinement layer refused it, not the server. Each sample's controller
proves that with a trusted request on the same path, using the same key, from outside the
restricted tool boundary.

Every authenticated request is appended to a log, without headers, credentials or bodies,
so a run can show that an allowed request arrived exactly once and a refused one never
arrived at all.
"""
import hmac
import json
import os
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

sys.path.insert(0, "/opt/analyst")
from business import AVAILABILITY_FIXTURE, CASE, load_json  # noqa: E402

KEY_FILE = Path(os.environ.get("SUPPLIER_KEY_FILE", "/opt/supplier-key/api-key"))
TLS_DIR = Path(os.environ.get("SUPPLIER_TLS_DIR", "/opt/supplier-tls"))
STATE = Path(os.environ.get("SUPPLIER_STATE_DIR", "/var/lib/supplier"))
PORT = int(os.environ.get("SUPPLIER_PORT", "8443"))

KEY = KEY_FILE.read_text().strip()
STATE.mkdir(parents=True, exist_ok=True)
LOCK = threading.Lock()

# The two case ids the server knows about. rfp-other exists so a sample can show a role
# being refused another case's data while the path itself is real and readable.
OTHER_CASE = "rfp-other"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        """Drop the default access log: it would print request URLs, and a URL can carry
        a credential a caller put in a query string."""

    def reply(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_request(self):
        path = urlsplit(self.path).path
        if path == "/healthz" and self.command == "GET":
            self.reply(200, {"healthy": True})
            return
        # compare_digest, so a wrong key cannot be found one character at a time.
        if not hmac.compare_digest(self.headers.get("X-Api-Key", ""), KEY):
            self.reply(401, {"error": "invalid API key"})
            return
        request_id = self.headers.get("X-Analyst-Request-ID", "")
        # Only a short, non-secret identifier goes in the log, and it names a file below.
        if (not request_id or len(request_id) > 100
                or not all(c.isalnum() or c == "-" for c in request_id)):
            self.reply(400, {"error": "invalid request id"})
            return
        with LOCK:
            with (STATE / "requests.jsonl").open("a") as stream:
                stream.write(json.dumps({"request_id": request_id, "method": self.command,
                                         "path": path}) + "\n")

        if self.command == "GET" and path in (f"/cases/{CASE}/suppliers",
                                              f"/cases/{OTHER_CASE}/suppliers"):
            self.reply(200, {"case_id": path.split("/")[2],
                             "availability": load_json(AVAILABILITY_FIXTURE)})
        elif self.command == "POST" and path == f"/cases/{CASE}/recommendations":
            length = int(self.headers.get("Content-Length", "0"))
            if length > 65536:
                self.reply(413, {"error": "draft too large"})
                return
            draft = json.loads(self.rfile.read(length))
            with LOCK:
                (STATE / f"{request_id}.json").write_text(json.dumps(draft))
            self.reply(201, {"saved": True, "request_id": request_id})
        elif ((self.command == "PATCH" and path.startswith("/suppliers/"))
              or (self.command == "POST" and path == "/purchase-orders")):
            # Accepted on purpose, and synthetic: nothing is ordered and no record changes.
            self.reply(200, {"synthetic_mutation_accepted": True, "request_id": request_id})
        else:
            self.reply(404, {"error": "unknown endpoint"})

    do_GET = handle_request
    do_POST = handle_request
    do_PATCH = handle_request


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(TLS_DIR / "tls.crt", TLS_DIR / "tls.key")
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f"supplier API listening on {PORT}", flush=True)
    server.serve_forever()
