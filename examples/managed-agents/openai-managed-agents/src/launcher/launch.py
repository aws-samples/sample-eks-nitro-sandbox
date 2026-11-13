"""``launcher launch`` -- the ordinary pod that claims a sandbox per session.

The default hand-off in issue #9 is application-managed provisioning: the
operator's ``scripts/submit.py`` creates the session with the application key,
then hands the launcher the session's environment id and remote URL. The
launcher reaches no public endpoint and the sample creates no Ingress; the
operator connects to this intake port with ``kubectl port-forward`` to a
ClusterIP Service.

Two layers protect the intake, because a NetworkPolicy is reachability and not
authentication:

  * a deny-by-default ingress ``ApplicationNetworkPolicy`` (see
    ``deploy/launcher-ingress.yaml``) so no in-cluster pod may reach the
    launcher Service; and
  * a pre-shared bearer token on every POST, the requests that claim or release
    a sandbox. The launcher reads it from a mounted Secret file and refuses to
    start without it; the intake rejects any POST whose ``Authorization: Bearer``
    token does not match, in constant time. ``submit.py`` sends it from the
    operator's ``.env``. This is a shared secret the operator already holds to
    deploy the launcher, so an ordinary in-cluster caller that reached the
    Service still cannot drive it. ``GET /`` answers without the token, for the
    readiness and liveness probes, and returns only ``{"status": "ok"}``.

Why this and not a poller like the Claude sample: the OpenAI self-hosted
executor dials OUT to the environment's remote URL and there is no work queue to
poll. The session must be created first, then compute started for it. The pinned
SDK (3.31.0) exposes session create/retrieve/stream and event streaming, but no
"list sessions awaiting an environment connection" call, so this sample uses the
issue's default, operator-driven provisioning. The README records this choice.

For each submitted session the launcher claims a sandbox and gives it the
session (and the environment key the launcher holds) through the claim's env
(see ``sandbox.py``). The launcher runs no tool calls itself, so it is an
ordinary pod.
"""

from __future__ import annotations

import hmac
import json
import logging
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from kubernetes.config import incluster_config

from . import config, guard, sandbox

log = logging.getLogger(__name__)

ID_RE = re.compile(r"^[A-Za-z0-9_\-]{1,128}$")
URL_RE = re.compile(r"^https://[A-Za-z0-9._\-]+(:\d+)?(/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%\-]*)?$")
MAX_BODY = 64 * 1024
_BEARER_RE = re.compile(r"^Bearer (?P<token>[A-Za-z0-9._\-]{1,4096})$")


class _Handler(BaseHTTPRequestHandler):
    """Claim or release a sandbox for a session. Every POST must authenticate; GET / is the probe."""

    def _authenticated(self) -> bool:
        """Constant-time check of the request's bearer token against the launcher's."""
        header = self.headers.get("Authorization", "")
        match = _BEARER_RE.match(header)
        if not match:
            return False
        presented = match.group("token")
        # hmac.compare_digest is constant time, so a wrong token leaks no timing.
        return hmac.compare_digest(presented, self.server.auth_token)  # type: ignore[attr-defined]

    def do_POST(self):  # noqa: N802 - stdlib naming
        if not self._authenticated():
            self._json(401, {"error": "unauthorized"})
            return
        if self.path.rstrip("/") == "/sessions":
            self._dispatch()
        elif self.path.rstrip("/") == "/sessions/claim-delete":
            self._delete_claim()
        else:
            self._json(404, {"error": "not found"})

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= MAX_BODY:
            raise ValueError("bad length")
        return json.loads(self.rfile.read(length))

    def _dispatch(self) -> None:
        try:
            body = self._body()
            session_id = body["session_id"]
            environment_id = body["environment_id"]
            remote_url = body["remote_url"]
            if not (ID_RE.match(session_id) and ID_RE.match(environment_id) and URL_RE.match(remote_url)):
                raise ValueError("invalid field")
        except Exception:
            self._json(400, {"error": "bad request"})
            return
        try:
            result = self.server.dispatcher.dispatch(  # type: ignore[attr-defined]
                session_id=session_id, environment_id=environment_id, remote_url=remote_url
            )
        except Exception as exc:  # noqa: BLE001 - report the failure to the operator
            log.exception("dispatch failed for session %s", session_id)
            self._json(502, {"error": "dispatch failed", "detail": type(exc).__name__})
            return
        self._json(202, {"session_id": session_id, **result})

    def _delete_claim(self) -> None:
        """Session-aware claim cleanup. The operator has already rechecked the
        session's state through the Agents API (it holds the application key the
        launcher must not); the launcher only deletes the claim, which it alone
        has the RBAC to do. The session is deleted separately, operator-side."""
        try:
            body = self._body()
            session_id = body["session_id"]
            if not ID_RE.match(session_id):
                raise ValueError("invalid field")
        except Exception:
            self._json(400, {"error": "bad request"})
            return
        try:
            deleted = self.server.dispatcher.delete_claim_for_session(session_id)  # type: ignore[attr-defined]
        except Exception as exc:  # noqa: BLE001
            log.exception("claim delete failed for session %s", session_id)
            self._json(502, {"error": "claim delete failed", "detail": type(exc).__name__})
            return
        self._json(200, {"session_id": session_id, "claims_deleted": deleted})

    def do_GET(self):  # noqa: N802 - a liveness/readiness probe target; no auth, no data
        self._json(200, {"status": "ok"})

    def _json(self, code: int, payload: dict) -> None:
        data = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        """No per-request access log."""


def _require_service_account_token() -> None:
    """Fail closed when the pod has no ServiceAccount token to call the API with.

    The launcher creates and watches SandboxClaims, so it needs the token that
    deploy/launcher.yaml mounts by hand (automountServiceAccountToken is false).
    Without this check the agent-sandbox client would fall back to looking for a
    kubeconfig (k8s_agent_sandbox/k8s_helper.py) and fail with an error about
    that file instead of the token. The paths are the Kubernetes client's own,
    so this checks what it will read. Each file is read only to test that it
    holds something other than whitespace; its content is never logged.
    """
    for path in (incluster_config.SERVICE_TOKEN_FILENAME, incluster_config.SERVICE_CERT_FILENAME):
        if not _has_content(path):
            raise RuntimeError(
                f"{path} is missing, empty or only whitespace, so the launcher cannot "
                "reach the Kubernetes API to claim sandboxes; refusing to start. "
                "deploy/launcher.yaml mounts it with the kube-api-access volume."
            )


def _has_content(path: str) -> bool:
    """True if ``path`` is a readable file holding more than whitespace."""
    try:
        with open(path, encoding="utf-8") as handle:
            return bool(handle.read().strip())
    except (OSError, UnicodeDecodeError):
        return False


def main() -> None:
    config.setup_logging()
    guard.assert_safe(guard.ROLE_LAUNCH)
    # Both credentials are files mounted from their Secrets, not env variables.
    executor_key = config.read_launcher_credential(config.ENV_EXECUTOR_API_KEY)
    # Fail closed: the launcher will not start without its intake auth token, so
    # the claim and release routes are never served without it.
    auth_token = config.read_launcher_credential(config.ENV_LAUNCHER_AUTH_TOKEN)
    _require_service_account_token()
    dispatcher = sandbox.Dispatcher(executor_key)
    port = config.optional_int(config.ENV_LAUNCHER_PORT, config.DEFAULT_LAUNCHER_PORT)
    # Binds 0.0.0.0 so the ClusterIP Service can reach the launcher pod. The
    # launcher publishes no host port; its Service is ClusterIP, a deny-by-default
    # ingress NetworkPolicy admits no in-cluster pod, every POST (claim or release)
    # must carry the bearer token, and GET / answers without it with no data.
    # The dispatch body carries no credential (the environment key stays in the
    # launcher and goes to the sandbox through the claim env).
    # The all-interface pod bind is intentional: the Service and the kubelet's
    # probes reach the pod IP, and narrowing it to loopback would cut both off.
    httpd = ThreadingHTTPServer(("0.0.0.0", port), _Handler)
    httpd.dispatcher = dispatcher  # type: ignore[attr-defined]
    httpd.auth_token = auth_token  # type: ignore[attr-defined]
    log.info("launcher intake on :%d; claiming from warm pool %s/%s",
             port, dispatcher.namespace, dispatcher.warmpool)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log.info("launcher shutting down")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
