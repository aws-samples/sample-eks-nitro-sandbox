"""The analyst's tool-role worker, shared by every Subagent security sample.

One small process, started by the trusted controller for one action and one role. Every
Subagent security sample launches this same program under its own confinement layer, so
the work the reader, evaluator and writer do is identical across the three samples and
only the layer around them differs.

Two rules make the results readable as evidence rather than as noise:

  * A refusal is reported as structured data, never as a crash. A denied open or socket
    comes back as {"denied_errno": ...}; the controller decides whether that errno counts
    as the refusal it asked for.
  * Everything else is an error. A timeout, a missing interpreter, a DNS failure or an
    unexpected exception leaves a non-zero exit and no result line, and the controller
    fails the run. A startup failure must never read as a successful denial.

A sample that needs extra probes for its own layer passes them to main() rather than
editing this file:

    import worker
    worker.main(extra={"unshare": my_unshare_probe})

Each probe takes the remaining argument list and returns a JSON-serialisable object.
"""
import errno
import hashlib
import json
import os
import socket
import sys
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

from business import compare, load_json

# One marker for all three samples, so a controller's parser is shared too.
MARKER = "ANALYST_RESULT="

# Errnos that mean "the confinement layer refused this", as opposed to "it failed".
DENIED_ERRNOS = (errno.EACCES, errno.EPERM)


def denied(error) -> dict:
    return {"denied_errno": error.errno}


def proxy_host_denial(reason, url) -> bool:
    """Recognise a credential proxy refusing a host that is not on its allowlist.

    urllib reports a rejected CONNECT as URLError wrapping a plain OSError, not as
    HTTPError, so there is no status code to read and the message is all there is. Three
    things have to be in it: the proxy's own refusal of the tunnel, a 403, and the exact
    host that was asked for. A DNS failure, a TLS failure and a timeout carry none of
    those, so they still raise and the controller fails the run rather than recording a
    denial. The controller additionally requires the layer's own audit record naming the
    same host, so this message is never the only evidence for the refusal.
    """
    if not isinstance(reason, OSError):
        return False
    message = str(reason)
    return ("Tunnel connection failed" in message
            and "403" in message
            and urlsplit(url).netloc in message)


def request(url, method, request_id, body=None, bypass_proxy=False) -> dict:
    """Call the supplier API with whatever credential this role was given.

    The role sends the value of SUPPLIER_API_KEY in the ordinary API header. Under nono
    that value is a proxy placeholder and the proxy substitutes the real key; under a
    layer with no proxy the controller does the call itself. Either way the tool's own
    code is the same, and it never reads a key file.
    """
    headers = {"X-Api-Key": os.environ.get("SUPPLIER_API_KEY", ""),
               "X-Analyst-Request-ID": request_id}
    data = json.dumps(body).encode() if body is not None else None
    if data:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    # ProxyHandler({}) empties the proxy list, so the request leaves the process directly
    # instead of going through the layer's proxy: the "can it reach the API on its own"
    # probe.
    opener = (urllib.request.build_opener(urllib.request.ProxyHandler({}))
              if bypass_proxy else urllib.request.build_opener())
    try:
        with opener.open(req, timeout=10) as response:
            return {"status": response.status, "body": json.load(response)}
    except urllib.error.HTTPError as error:
        return {"status": error.code, "body": error.read().decode()[:2048]}
    except urllib.error.URLError as error:
        if isinstance(error.reason, PermissionError):
            return denied(error.reason)
        if proxy_host_denial(error.reason, url):
            return {"status": 403, "proxy_connect_denied": True}
        raise


def act_read(args):
    """Read an assigned document. A refused open raises PermissionError, caught in main."""
    return load_json(args[0])


def act_write(args):
    """Copy a document to a path. Writing a read-only input raises PermissionError."""
    target = Path(args[0])
    target.write_text(json.dumps(load_json(args[1]), indent=2))
    return {"written": str(target)}


def act_evaluate(args):
    """Run the deterministic comparison from a staged facts file, with no network."""
    facts = load_json(args[0])
    return compare(facts["case"], facts["availability"])


def act_api(args):
    url, method, request_id = args[:3]
    option = args[3] if len(args) > 3 else None
    body = None
    if method != "GET":
        body = load_json(option) if option and option != "bypass-proxy" else {"draft": True}
    return request(url, method, request_id, body, bypass_proxy=(option == "bypass-proxy"))


# The AWS variables that would give a role a way to authenticate: static keys, and every
# variable a credential provider reads to find a role. A confinement layer may legitimately
# set other AWS_* variables for its own reasons, so the check names these rather than
# anything starting with AWS_.
AWS_CREDENTIAL_VARS = (
    "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
    "AWS_SECURITY_TOKEN", "AWS_PROFILE", "AWS_ROLE_ARN", "AWS_WEB_IDENTITY_TOKEN_FILE",
    "AWS_CONTAINER_CREDENTIALS_FULL_URI", "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
    "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
)


def act_credential_env(args):
    """Report which credentials this role holds, by name and digest, never by value.

    The digest is what lets the controller show the role's placeholder differs from the
    real key without either value appearing anywhere. aws_names is reported in full
    alongside aws_credential_names, so a page can say which AWS variables the layer set
    and why, instead of claiming there are none.
    """
    value = os.environ.get("SUPPLIER_API_KEY", "")
    return {
        "aws_names": sorted(k for k in os.environ if k.startswith("AWS_")),
        "aws_credential_names": sorted(k for k in AWS_CREDENTIAL_VARS if k in os.environ),
        "model_key_names": sorted(k for k in os.environ
                                  if k.endswith("_API_KEY") and k != "SUPPLIER_API_KEY"),
        "api_key_present": bool(value),
        "api_key_length": len(value),
        "api_key_sha256": hashlib.sha256(value.encode()).hexdigest(),
    }


def act_socket(args):
    """Create an Internet socket without connecting it, the smallest network probe."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM):
            return {"socket_created": True}
    except PermissionError as error:
        return denied(error)


def act_connect(args):
    try:
        with socket.create_connection((args[0], int(args[1])), timeout=5):
            return {"connected": True}
    except PermissionError as error:
        return denied(error)


ACTIONS = {
    "read": act_read,
    "write": act_write,
    "evaluate": act_evaluate,
    "api": act_api,
    "credential-env": act_credential_env,
    "socket": act_socket,
    "connect": act_connect,
}


def run(action, args, extra=None):
    table = {**ACTIONS, **(extra or {})}
    if action not in table:
        raise ValueError(f"unknown action: {action}")
    return table[action](args)


def main(extra=None):
    try:
        result = run(sys.argv[1], sys.argv[2:], extra)
    except PermissionError as error:
        # The only exception that is evidence rather than a failure.
        result = denied(error)
    print(MARKER + json.dumps(result, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
