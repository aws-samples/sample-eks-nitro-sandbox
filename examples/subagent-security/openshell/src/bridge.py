"""The model bridge: a small OpenAI-compatible completion endpoint over Amazon Bedrock.

It runs in an ordinary pod outside the Nitro sandbox and is the only component in this
sample that holds AWS credentials, through EKS Pod Identity. The analyst, confined by
OpenShell inside the sandbox, calls this endpoint with a placeholder credential that
OpenShell's supervisor replaces with the real one; the analyst has no AWS role.

Why an OpenAI-compatible endpoint rather than OpenShell's own inference route: that route
(`openshell inference`, `inference.local`) was removed upstream in 0.1.0. The supported
way for a confined workload to reach a model now is to attach a provider and call the
model host's native API with the placeholder key, which is what this does.

This is application code, not an upstream OpenShell Bedrock integration, and it is
deliberately small: one text-only completion, on one configured model. It is not a
general OpenAI-compatible proxy, and the page does not present it as one.
"""
import hmac
import json
import os
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

import boto3

KEY_FILE = Path(os.environ.get("SUPPLIER_KEY_FILE", "/opt/supplier-key/api-key"))
TLS_DIR = Path(os.environ.get("BRIDGE_TLS_DIR", "/opt/bridge-tls"))
PORT = int(os.environ.get("BRIDGE_PORT", "8443"))
MODEL = os.environ["BEDROCK_MODEL_ID"]
REGION = os.environ["AWS_REGION"]

# The same key the shared supplier API checks. The bridge is a second destination behind
# one brokered credential, so the analyst holds a single placeholder for both.
KEY = KEY_FILE.read_text().strip()

MAX_BODY = 65536
MAX_TOKENS = 2000


def converse(payload: dict) -> dict:
    """One Bedrock Converse turn, on the configured model only.

    The model id is not taken from the request. A caller that asks for another model is
    refused: the bridge's IAM role is scoped to one inference profile, so honouring an
    arbitrary model id would either fail at AWS or, if the role were ever widened, let a
    confined caller choose what it spends. Checking here keeps that decision outside the
    sandbox.
    """
    requested = payload.get("model")
    if requested != MODEL:
        raise PermissionError(
            f"this bridge serves only its configured model, not {requested!r}")

    messages, system = [], []
    for message in payload.get("messages") or []:
        if message.get("role") == "system":
            system.append({"text": message["content"]})
        else:
            messages.append({"role": message["role"],
                             "content": [{"text": message["content"]}]})
    if not messages:
        raise ValueError("the request carries no messages")

    session = boto3.Session(region_name=REGION)
    credentials = session.get_credentials()
    if credentials is None:
        raise RuntimeError("the bridge has no AWS credentials")
    # EKS Pod Identity reaches boto3 as the container-role provider. The run reports this
    # value so the page can show which credential path the Bedrock call actually used,
    # rather than asserting it from the manifest.
    method = credentials.method

    answer = session.client("bedrock-runtime").converse(
        modelId=MODEL, messages=messages, system=system,
        inferenceConfig={"maxTokens": MAX_TOKENS, "temperature": 0})
    text = "".join(block.get("text", "")
                   for block in answer["output"]["message"]["content"])
    usage = answer.get("usage", {})
    return {
        "id": "analyst-" + answer["ResponseMetadata"]["RequestId"],
        "object": "chat.completion",
        "model": MODEL,
        "choices": [{"index": 0, "finish_reason": answer.get("stopReason", "stop"),
                     "message": {"role": "assistant", "content": text}}],
        # Named for what it is: not an OpenAI field, but how the page shows a real
        # Bedrock turn happened and which identity made it.
        "usage": {"prompt_tokens": usage.get("inputTokens", 0),
                  "completion_tokens": usage.get("outputTokens", 0),
                  "total_tokens": usage.get("totalTokens", 0)},
        "bridge_credential_provider": method,
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        """Drop the default access log, which would print request URLs, and a URL can
        carry a credential a caller put in a query string."""

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
        presented = self.headers.get("X-Api-Key", "")
        accepted = hmac.compare_digest(presented, KEY)
        request_id = self.headers.get("X-Analyst-Request-ID", "")
        if (not request_id or len(request_id) > 100
                or not all(c.isalnum() or c == "-" for c in request_id)):
            self.reply(400, {"error": "invalid request id"})
            return
        # One line per authenticated attempt, with no headers, credentials or bodies, so a
        # run can show that an allowed request arrived and a refused one never did.
        print(json.dumps({"request_id": request_id, "method": self.command,
                          "path": path, "authenticated": accepted}), flush=True)
        if not accepted:
            self.reply(401, {"error": "invalid API key"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length > MAX_BODY:
                self.reply(413, {"error": "request too large"})
                return
            payload = json.loads(self.rfile.read(length)) if length else {}
            if path == "/v1/chat/completions" and self.command == "POST":
                self.reply(200, converse(payload))
                return
            if path == "/v1/models" and self.command == "GET":
                self.reply(200, {"object": "list", "data": [{"id": MODEL}]})
                return
            self.reply(404, {"error": "unknown endpoint"})
        except PermissionError as error:
            self.reply(403, {"error": "model_not_permitted", "detail": str(error)})
        except Exception as error:
            # The type only, never the message: a model or SDK error can quote request
            # content. The page reads this log, so it must be safe to publish.
            print(json.dumps({"request_id": request_id,
                              "error_type": type(error).__name__}), flush=True)
            self.reply(502, {"error": "bridge_failed"})

    do_GET = handle_request
    do_POST = handle_request


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    # PROTOCOL_TLS_SERVER alone still permits TLS 1.0 and 1.1 on some builds, and a
    # sample is copied as-is, so the floor is set explicitly.
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(TLS_DIR / "tls.crt", TLS_DIR / "tls.key")
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f"model bridge listening on {PORT} for {MODEL}", flush=True)
    server.serve_forever()
