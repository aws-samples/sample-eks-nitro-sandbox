# The claim-demand exporter: the HTTP endpoint KEDA's metrics-api trigger polls.
#
# It counts SandboxClaim objects in its OWN namespace that carry the sample's
# label, and serves that count as JSON at /metrics:
#
#   {"active_claims": 2, "namespace": "...", "selector": "...", "ts": "..."}
#
# KEDA ships no scaler that counts an arbitrary custom resource, which is why
# this exists: it turns "how many SandboxClaims are there" into a number the
# metrics-api scaler can read.
#
# WHAT IT CAN REACH. The ServiceAccount this runs as is bound to a namespaced
# Role whose only rule is get and list on sandboxclaims in this namespace, and
# that Role is everything the sample grants it. It cannot read a claim in another
# namespace, cannot list anything else, and cannot create, patch or delete
# anything at all. The one API call below is a list of SandboxClaims in
# POD_NAMESPACE, and it is the only call the code makes.
#
# WHO CAN REACH IT. It listens on all interfaces inside its own container and is
# published only through a ClusterIP Service, so it is reachable from inside the
# cluster and from nowhere else: the sample creates no Ingress, LoadBalancer or
# NodePort. The response is a count of the sample's own claims and holds no
# secret, no credential and no claim contents, so the endpoint is unauthenticated
# like any other in-cluster /metrics endpoint. The page says how a reader whose
# cluster enforces network policies can narrow it further.
#
# It runs as an ORDINARY pod (no runtimeClassName), not a sandbox: it is
# first-party code the cluster operator deployed, and keeping it out of a sandbox
# means it consumes no sandbox capacity that the pool it measures would want.
import json
import os
import ssl
import sys
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NAMESPACE = os.environ["POD_NAMESPACE"]
SELECTOR = os.environ["CLAIM_SELECTOR"]
API_HOST = os.environ["KUBERNETES_SERVICE_HOST"]
API_PORT = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
TOKEN_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CA_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
LISTEN_PORT = 8080

CLAIMS_URL = (
    "https://%s:%s/apis/extensions.agents.x-k8s.io/v1beta1"
    "/namespaces/%s/sandboxclaims?labelSelector=%s"
    % (API_HOST, API_PORT, NAMESPACE, urllib.parse.quote(SELECTOR))
)

# The last count the API actually answered with. On an API error the handler
# serves this instead of failing: a transient blip must not look like demand
# falling away, which would make KEDA scale the pool down for no reason.
#
# It starts at 0, so this protects a running exporter, not a restarting one: an
# exporter that restarts while the API is unreachable has no last good count and
# serves 0 until its first successful read. The pool's minReplicaCount is the
# floor that case falls to.
_last_good = 0


def count_claims():
    """List this namespace's SandboxClaims carrying SELECTOR and return how many."""
    global _last_good
    with open(TOKEN_FILE) as f:
        token = f.read().strip()
    context = ssl.create_default_context(cafile=CA_FILE)
    request = urllib.request.Request(
        CLAIMS_URL, headers={"Authorization": "Bearer " + token}
    )
    with urllib.request.urlopen(request, context=context, timeout=10) as response:
        payload = json.load(response)
    _last_good = len(payload.get("items", []))
    return _last_good


class Handler(BaseHTTPRequestHandler):
    # Drop a connection that goes quiet rather than holding the handler open. The
    # endpoint is reachable from anywhere in the cluster, and without a timeout a
    # single idle connection would stall KEDA's poll and the readiness probe.
    timeout = 5

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except TimeoutError:
            self.close_connection = True

    def do_GET(self):
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        try:
            count = count_claims()
            error = ""
        except Exception as exc:  # serve the last good count, never fail the poll
            count = _last_good
            error = repr(exc)
        body = json.dumps(
            {
                "active_claims": count,
                "namespace": NAMESPACE,
                "selector": SELECTOR,
                "ts": stamp,
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        # One line per poll, so the pod's log is a record of the demand signal
        # KEDA saw and when it saw it.
        sys.stdout.write(
            "%s active_claims=%d selector=%s%s\n"
            % (stamp, count, SELECTOR, (" error=" + error) if error else "")
        )
        sys.stdout.flush()

    def log_message(self, *args):
        pass  # the line above is the log; drop the default access log


if __name__ == "__main__":
    # Binds every interface in the container. The boundary is the ClusterIP
    # Service in deploy/exporter.yaml, which publishes this port inside the
    # cluster only; the sample creates no Ingress, LoadBalancer or NodePort.
    #
    # Threading, not the single-threaded HTTPServer: KEDA's poll and the
    # readiness probe must not queue behind each other, or behind a connection
    # that is waiting on the API call this handler makes.
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
