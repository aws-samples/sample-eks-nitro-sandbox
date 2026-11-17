"""TLS admission webhook for adapting OCE gateway-state mounts to Nitro."""

from __future__ import annotations

import base64
import json
import logging
import os
import re
import signal
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlsplit

from adapter import AdmissionError, build_patch, validate_pod

MAX_BODY_BYTES = 1_048_576
MAX_CONCURRENT_REQUESTS = 32
SOCKET_TIMEOUT_SECONDS = 5.0
LOG = logging.getLogger("oce-nitro-adapter")
POD_RESOURCE = {"group": "", "version": "v1", "resource": "pods"}
CONFIGMAP_RESOURCE = {"group": "", "version": "v1", "resource": "configmaps"}
DEPLOYMENT_RESOURCE = {
    "group": "apps",
    "version": "v1",
    "resource": "deployments",
}
REPLICASET_RESOURCE = {
    "group": "apps",
    "version": "v1",
    "resource": "replicasets",
}
ALLOWED_ADMISSION_USERS_ENV = "OCE_ALLOWED_ADMISSION_USERS"
ALLOWED_DEPLOYMENT_USERS_ENV = "OCE_ALLOWED_DEPLOYMENT_USERS"
ALLOWED_REPLICASET_USERS_ENV = "OCE_ALLOWED_REPLICASET_USERS"
GATEWAY_NAME_PATTERN = re.compile(r"^gateway-[0-9a-f]{12}$")
REVISION_CONFIGMAP_NAME_PATTERN = re.compile(
    r"^gateway-[0-9a-f]{12}-rev-[0-9a-f]{12}$"
)
REPLICASET_NAME_PATTERN = re.compile(r"^(gateway-[0-9a-f]{12})-[a-z0-9]{8,10}$")
OCE_LABELS = (
    "app.kubernetes.io/managed-by",
    "app.kubernetes.io/name",
    "openclaw.dev/agent",
    "openclaw.dev/namespace",
    "openclaw.dev/revision",
    "openclaw.dev/service-principal",
    "openclaw.dev/workload-role",
)


def _validate_admission_user(
    request: dict[str, Any],
    environment_name: str = ALLOWED_ADMISSION_USERS_ENV,
) -> None:
    configured = os.environ.get(environment_name, "")
    allowed = {value.strip() for value in configured.split(",") if value.strip()}
    username = request.get("userInfo", {}).get("username")
    if not allowed:
        raise AdmissionError(f"{environment_name} must not be empty")
    if username not in allowed:
        raise AdmissionError(
            "admission caller is not an allowed controller identity for this resource"
        )


def _metadata(value: Any, location: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise AdmissionError(f"{location} must be an object")
    return value


def _labels(
    value: Any,
    location: str,
    *,
    require_workload: bool = True,
) -> dict[str, str]:
    labels = _metadata(value, location)
    if labels.get("app.kubernetes.io/managed-by") != "openclaw-enterprise":
        raise AdmissionError(f"{location} is not managed by OpenClaw Enterprise")
    if require_workload and labels.get("openclaw.dev/workload-role") != "gateway":
        raise AdmissionError(f"{location} is not an embedded gateway workload")
    if require_workload:
        application_name = labels.get("app.kubernetes.io/name")
        if (
            not isinstance(application_name, str)
            or GATEWAY_NAME_PATTERN.fullmatch(application_name) is None
        ):
            raise AdmissionError(f"{location} has an invalid gateway name")
    return labels


def _validate_template_labels(
    metadata_labels: dict[str, str],
    template: Any,
    location: str,
) -> None:
    template_metadata = _metadata(
        _metadata(template, location).get("metadata"),
        f"{location}.metadata",
    )
    template_labels = _labels(
        template_metadata.get("labels"),
        f"{location}.metadata.labels",
    )
    for label in OCE_LABELS:
        if template_labels.get(label) != metadata_labels.get(label):
            raise AdmissionError(f"{location} has inconsistent {label}")


def _validate_deployment(deployment: Any) -> None:
    deployment = _metadata(deployment, "Deployment")
    metadata = _metadata(deployment.get("metadata"), "Deployment.metadata")
    labels = _labels(
        metadata.get("labels"),
        "Deployment.metadata.labels",
        require_workload=False,
    )
    name = metadata.get("name")
    if not isinstance(name, str) or GATEWAY_NAME_PATTERN.fullmatch(name) is None:
        raise AdmissionError("Deployment has an invalid gateway name")
    spec = _metadata(deployment.get("spec"), "Deployment.spec")
    selector = _metadata(spec.get("selector"), "Deployment.spec.selector")
    match_labels = _metadata(
        selector.get("matchLabels"),
        "Deployment.spec.selector.matchLabels",
    )
    if match_labels != {"app.kubernetes.io/name": name}:
        raise AdmissionError("Deployment selector does not identify its OCE gateway")
    template = _metadata(spec.get("template"), "Deployment.spec.template")
    template_labels = _labels(
        _metadata(template.get("metadata"), "Deployment.spec.template.metadata").get(
            "labels"
        ),
        "Deployment.spec.template.metadata.labels",
    )
    if template_labels["app.kubernetes.io/name"] != name:
        raise AdmissionError("Deployment template does not match its gateway name")
    for label in (
        "app.kubernetes.io/managed-by",
        "openclaw.dev/agent",
        "openclaw.dev/namespace",
    ):
        if template_labels.get(label) != labels.get(label):
            raise AdmissionError(f"Deployment template has inconsistent {label}")


def _validate_revision_configmap(configmap: Any) -> None:
    configmap = _metadata(configmap, "ConfigMap")
    metadata = _metadata(configmap.get("metadata"), "ConfigMap.metadata")
    name = metadata.get("name")
    if (
        not isinstance(name, str)
        or REVISION_CONFIGMAP_NAME_PATTERN.fullmatch(name) is None
    ):
        raise AdmissionError("ConfigMap is not an OCE gateway revision")
    labels = _metadata(metadata.get("labels"), "ConfigMap.metadata.labels")
    if labels.get("app.kubernetes.io/managed-by") != "openclaw-enterprise":
        raise AdmissionError("ConfigMap is not managed by OpenClaw Enterprise")
    for label in ("openclaw.dev/agent", "openclaw.dev/namespace"):
        if not isinstance(labels.get(label), str) or not labels[label]:
            raise AdmissionError(f"ConfigMap is missing {label}")
    if configmap.get("immutable") is not True:
        raise AdmissionError("OCE gateway revision ConfigMap must be immutable")
    data = _metadata(configmap.get("data"), "ConfigMap.data")
    if set(data) != {"openclaw.json"} or not isinstance(data["openclaw.json"], str):
        raise AdmissionError(
            "OCE gateway revision ConfigMap must contain only openclaw.json"
        )
    if configmap.get("binaryData") not in (None, {}):
        raise AdmissionError("OCE gateway revision ConfigMap must not use binaryData")


def _validate_replicaset(replicaset: Any) -> None:
    replicaset = _metadata(replicaset, "ReplicaSet")
    metadata = _metadata(replicaset.get("metadata"), "ReplicaSet.metadata")
    labels = _labels(metadata.get("labels"), "ReplicaSet.metadata.labels")
    name = metadata.get("name")
    match = REPLICASET_NAME_PATTERN.fullmatch(name) if isinstance(name, str) else None
    if match is None or match.group(1) != labels["app.kubernetes.io/name"]:
        raise AdmissionError("ReplicaSet name does not match its gateway label")
    controllers = [
        owner
        for owner in metadata.get("ownerReferences", [])
        if isinstance(owner, dict) and owner.get("controller") is True
    ]
    if (
        len(controllers) != 1
        or controllers[0].get("apiVersion") != "apps/v1"
        or controllers[0].get("kind") != "Deployment"
        or controllers[0].get("name") != labels["app.kubernetes.io/name"]
        or not isinstance(controllers[0].get("uid"), str)
        or not controllers[0]["uid"]
    ):
        raise AdmissionError("ReplicaSet must be owned by its gateway Deployment")
    spec = _metadata(replicaset.get("spec"), "ReplicaSet.spec")
    _validate_template_labels(labels, spec.get("template"), "ReplicaSet.spec.template")


def admit(review: Any) -> dict[str, Any]:
    """Build an AdmissionReview response without any HTTP dependencies."""
    uid = ""
    try:
        if not isinstance(review, dict):
            raise AdmissionError("AdmissionReview must be an object")
        if review.get("apiVersion") != "admission.k8s.io/v1":
            raise AdmissionError("only admission.k8s.io/v1 is supported")
        request = review.get("request")
        if not isinstance(request, dict):
            raise AdmissionError("AdmissionReview.request must be an object")
        uid = request.get("uid", "")
        if not isinstance(uid, str) or not uid:
            raise AdmissionError("AdmissionRequest.uid must be a non-empty string")
        if request.get("operation") != "CREATE":
            raise AdmissionError("only Pod CREATE admission is supported")
        resource = request.get("resource")
        if resource != POD_RESOURCE:
            raise AdmissionError("only core/v1 Pods are supported")
        if not isinstance(request.get("namespace"), str) or not request["namespace"]:
            raise AdmissionError("Pod admission request must name a namespace")
        _validate_admission_user(request)
        pod = request.get("object")
        patch = build_patch(pod)
        response: dict[str, Any] = {"uid": uid, "allowed": True}
        if patch:
            encoded = json.dumps(patch, separators=(",", ":"), sort_keys=True).encode(
                "utf-8"
            )
            response.update(
                {
                    "patchType": "JSONPatch",
                    "patch": base64.b64encode(encoded).decode("ascii"),
                }
            )
    except AdmissionError as error:
        response = {
            "uid": uid,
            "allowed": False,
            "status": {"code": 400, "message": str(error)},
        }
    except Exception:
        LOG.exception("unexpected admission failure")
        response = {
            "uid": uid,
            "allowed": False,
            "status": {"code": 500, "message": "internal admission error"},
        }
    return {
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "response": response,
    }


def validate(review: Any) -> dict[str, Any]:
    """Validate the trusted controller chain and final Pod contract."""
    uid = ""
    try:
        if not isinstance(review, dict):
            raise AdmissionError("AdmissionReview must be an object")
        if review.get("apiVersion") != "admission.k8s.io/v1":
            raise AdmissionError("only admission.k8s.io/v1 is supported")
        request = review.get("request")
        if not isinstance(request, dict):
            raise AdmissionError("AdmissionReview.request must be an object")
        uid = request.get("uid", "")
        if not isinstance(uid, str) or not uid:
            raise AdmissionError("AdmissionRequest.uid must be a non-empty string")
        if not isinstance(request.get("namespace"), str) or not request["namespace"]:
            raise AdmissionError("admission request must name a namespace")
        operation = request.get("operation")
        subresource = request.get("subResource")
        resource = request.get("resource")
        if resource == POD_RESOURCE and operation == "CREATE" and not subresource:
            _validate_admission_user(request)
            validate_pod(request.get("object"))
            response = {"uid": uid, "allowed": True}
        elif (
            resource == POD_RESOURCE
            and operation == "UPDATE"
            and subresource == "ephemeralcontainers"
        ):
            response = {
                "uid": uid,
                "allowed": False,
                "status": {
                    "code": 403,
                    "reason": "Forbidden",
                    "message": (
                        "ephemeral containers are not permitted in "
                        "OpenClaw Enterprise managed namespaces"
                    ),
                },
            }
        elif (
            resource == CONFIGMAP_RESOURCE
            and operation in {"CREATE", "UPDATE", "DELETE"}
            and not subresource
        ):
            _validate_admission_user(request, ALLOWED_DEPLOYMENT_USERS_ENV)
            configmap = (
                request.get("oldObject")
                if operation == "DELETE"
                else request.get("object")
            )
            _validate_revision_configmap(configmap)
            response = {"uid": uid, "allowed": True}
        elif (
            resource == DEPLOYMENT_RESOURCE
            and operation in {"CREATE", "UPDATE"}
            and not subresource
        ):
            _validate_admission_user(request, ALLOWED_DEPLOYMENT_USERS_ENV)
            _validate_deployment(request.get("object"))
            response = {"uid": uid, "allowed": True}
        elif (
            resource == REPLICASET_RESOURCE
            and operation in {"CREATE", "UPDATE"}
            and not subresource
        ):
            _validate_admission_user(request, ALLOWED_REPLICASET_USERS_ENV)
            _validate_replicaset(request.get("object"))
            response = {"uid": uid, "allowed": True}
        else:
            raise AdmissionError("unsupported admission resource or operation")
    except AdmissionError as error:
        response = {
            "uid": uid,
            "allowed": False,
            "status": {"code": 400, "message": str(error)},
        }
    except Exception:
        LOG.exception("unexpected admission failure")
        response = {
            "uid": uid,
            "allowed": False,
            "status": {"code": 500, "message": "internal admission error"},
        }
    return {
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "response": response,
    }


class AdmissionHandler(BaseHTTPRequestHandler):
    server_version = "oce-nitro-adapter"
    sys_version = ""

    def do_GET(self) -> None:
        if urlsplit(self.path).path not in {"/healthz", "/readyz"}:
            self.send_error(404)
            return
        self._write_json(200, {"status": "ok"})

    def do_POST(self) -> None:
        path = urlsplit(self.path).path
        if path not in {"/mutate", "/validate"}:
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
            if length <= 0 or length > MAX_BODY_BYTES:
                raise ValueError
            body = self.rfile.read(length)
            if len(body) != length:
                raise ValueError
            review = json.loads(body)
        except (ValueError, json.JSONDecodeError):
            self._write_json(
                400,
                {
                    "apiVersion": "admission.k8s.io/v1",
                    "kind": "AdmissionReview",
                    "response": {
                        "uid": "",
                        "allowed": False,
                        "status": {
                            "code": 400,
                            "message": "invalid AdmissionReview request body",
                        },
                    },
                },
            )
            return
        admission = admit if path == "/mutate" else validate
        self._write_json(200, admission(review))

    def log_message(self, format: str, *args: Any) -> None:
        LOG.info("%s - %s", self.client_address[0], format % args)

    def _write_json(self, status: int, value: dict[str, Any]) -> None:
        body = json.dumps(value, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)


class BoundedThreadingHTTPServer(ThreadingHTTPServer):
    """Threaded server with bounded admission concurrency and read timeouts."""

    daemon_threads = True
    request_queue_size = 64

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self._request_slots = threading.BoundedSemaphore(MAX_CONCURRENT_REQUESTS)

    def get_request(self) -> tuple[Any, Any]:
        request, client_address = super().get_request()
        request.settimeout(SOCKET_TIMEOUT_SECONDS)
        return request, client_address

    def process_request(self, request: Any, client_address: Any) -> None:
        self._request_slots.acquire()
        try:
            super().process_request(request, client_address)
        except Exception:
            self._request_slots.release()
            raise

    def process_request_thread(self, request: Any, client_address: Any) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._request_slots.release()


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    address = os.environ.get("LISTEN_ADDRESS", "0.0.0.0")
    port = int(os.environ.get("PORT", "8443"))
    cert_file = os.environ.get("TLS_CERT_FILE", "/tls/tls.crt")
    key_file = os.environ.get("TLS_KEY_FILE", "/tls/tls.key")

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert_file, key_file)

    server = BoundedThreadingHTTPServer((address, port), AdmissionHandler)
    server.socket = context.wrap_socket(server.socket, server_side=True)

    def stop_server(*_: Any) -> None:
        # BaseServer.shutdown must run outside the serve_forever thread.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop_server)
    signal.signal(signal.SIGINT, stop_server)
    LOG.info("listening on %s:%d", address, port)
    server.serve_forever()


if __name__ == "__main__":
    main()
