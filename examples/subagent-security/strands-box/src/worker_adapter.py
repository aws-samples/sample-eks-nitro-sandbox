"""Add explicit filesystem probes without changing the shared analyst worker."""
import errno
import json
import os
from pathlib import Path

import sys
import time
import urllib.error
import urllib.request
import strict_json

ACCESS_ERRORS = (errno.EACCES, errno.EPERM, errno.ENOENT, errno.EROFS)
NATIVE_ERRORS = (errno.EACCES, errno.EPERM, errno.ENETUNREACH, errno.EHOSTUNREACH, errno.ECONNREFUSED)


def errno_result(result, field, allowed):
    """A refusal has one integer errno and no simultaneous success result."""
    return (isinstance(result, dict) and set(result) == {field}
            and type(result[field]) is int and result[field] in allowed)


def access_refused(result):
    return errno_result(result, "access_error_errno", ACCESS_ERRORS)


def native_refused(result):
    return (errno_result(result, "native_connect_error_errno", NATIVE_ERRORS)
            or errno_result(result, "denied_errno", (errno.EACCES, errno.EPERM)))


def supplier_reply(body, request_id, method, path):
    """Validate successful fields returned by the unchanged supplier protocol."""
    if not isinstance(body, dict) or "error" in body:
        raise AssertionError("Supplier response must be a successful JSON object")
    if method == "GET":
        if body.get("case_id") != path.split("/")[2]:
            raise AssertionError("Supplier response belongs to a different procurement case")
        # Both runtime images and host verification use the unchanged shared
        # schema and fixture. This check is specific to the synthetic sample.
        from importlib.util import module_from_spec, spec_from_file_location
        from strict_json import loads
        shared = Path(__file__).resolve().parents[2] / "analyst"
        source = shared / "src" / "business.py"
        if not source.is_file():
            source = shared / "business.py"
        spec = spec_from_file_location("_box_supplier_business", source)
        business = module_from_spec(spec)
        spec.loader.exec_module(business)
        try:
            availability = business.availability_from_reply(body)
        except ValueError:
            raise AssertionError("Supplier response has malformed availability data") from None
        expected = loads((shared / "fixtures" / "availability.json").read_text())
        if availability != expected:
            raise AssertionError("Supplier availability differs from the shared synthetic fixture")
    if (method != "GET" or "request_id" in body) and body.get("request_id") != request_id:
        raise AssertionError("Supplier response does not identify the submitted request")
    if "case_id" in body and path.startswith("/cases/") and body["case_id"] != path.split("/")[2]:
        raise AssertionError("Supplier response belongs to a different procurement case")
    if method == "POST" and path.endswith("/recommendations"):
        if body.get("saved") is not True:
            raise AssertionError("Supplier response did not confirm the saved draft")
    elif method == "PATCH" or (method == "POST" and path == "/purchase-orders"):
        if body.get("synthetic_mutation_accepted") is not True:
            raise AssertionError("Supplier response did not confirm the synthetic mutation")


def http_result(result, expected, request_id, method, path):
    """Keep HTTP responses separate from native-operation results and errors."""
    if not isinstance(result, dict) or type(result.get("status")) is not int or result["status"] != expected:
        raise AssertionError("The worker result differs from the expected response: " + request_id)
    if expected == 403:
        body_denial = set(result) == {"status", "body"} and isinstance(result["body"], str)
        tunnel_denial = set(result) == {"status", "proxy_connect_denied"} and result["proxy_connect_denied"] is True
        if not (body_denial or tunnel_denial):
            raise AssertionError("The HTTP denial result is missing or contradictory: " + request_id)
    else:
        if set(result) != {"status", "body"}:
            raise AssertionError("The successful HTTP result is missing or contradictory: " + request_id)
        supplier_reply(result["body"], request_id, method, path)


def api(args):
    # The local fixture uses loopback outside the worker network namespace.
    # Route HTTP through Box even when a client would otherwise bypass its proxy.
    saved = {name: os.environ.pop(name) for name in ("NO_PROXY", "no_proxy")
             if name in os.environ}
    try:
        # Preserve the shared supplier protocol, but reject ambiguous response
        # objects before serializing them into the worker's result receipt.
        url, method, request_id = args[:3]
        option = args[3] if len(args) > 3 else None
        body = None
        if method != "GET":
            body = (strict_json.loads(Path(option).read_text())
                    if option and option != "bypass-proxy" else {"draft": True})
        headers = {"X-Api-Key": os.environ.get("SUPPLIER_API_KEY", ""),
                   "X-Analyst-Request-ID": request_id}
        data = json.dumps(body).encode() if body is not None else None
        if data:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        opener = (urllib.request.build_opener(urllib.request.ProxyHandler({}))
                  if option == "bypass-proxy" else urllib.request.build_opener())
        try:
            with opener.open(request, timeout=10) as response:
                return {"status": response.status, "body": strict_json.load(response)}
        except urllib.error.HTTPError as error:
            return {"status": error.code, "body": error.read().decode()[:2048]}
        except urllib.error.URLError as error:
            if isinstance(error.reason, PermissionError):
                return worker.denied(error.reason)
            if worker.proxy_host_denial(error.reason, url):
                return {"status": 403, "proxy_connect_denied": True}
            raise
    finally:
        os.environ.update(saved)


def readable(args):
    with Path(args[0]).open("rb") as stream:
        stream.read(1)
    return {"readable": True}


def credential_names(args):
    return {"aws_credential_names": sorted(name for name in worker.AWS_CREDENTIAL_VARS
                                           if name in os.environ),
            "model_key_names": sorted(name for name in os.environ if name.endswith("_API_KEY") or name == "AWS_BEARER_TOKEN_BEDROCK"),
            "supplier_key_present": bool(os.environ.get("SUPPLIER_API_KEY"))}


def probes(args):
    actions = strict_json.loads(Path(args[0]).read_text())
    results = []
    for action in actions:
        started = time.time_ns()
        try:
            result = worker.run(action["action"], action["args"],
                                extra={"api": api, "credential-names": credential_names, "readable": readable})
        except OSError as error:
            if action["action"] == "connect" and error.errno in (errno.EACCES, errno.EPERM, errno.ENETUNREACH, errno.EHOSTUNREACH, errno.ECONNREFUSED):
                result = {"native_connect_error_errno": error.errno}
            elif error.errno in ACCESS_ERRORS:
                # The controller proves these paths exist outside confinement.
                result = {"access_error_errno": error.errno}
            else:
                raise
        results.append({"name": action["name"], "result": result,
                        "started_ns": started, "ended_ns": time.time_ns()})
    return results


if __name__ == "__main__":
    sys.path.insert(0, sys.argv.pop(1))
    import worker
    worker.main(extra={"box-probes": probes})
