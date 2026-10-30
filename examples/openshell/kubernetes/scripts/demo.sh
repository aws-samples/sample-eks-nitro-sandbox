#!/usr/bin/env bash
# demo.sh -- register the CLI with the port-forwarded gateway, create one OpenShell
# sandbox whose workload pod runs in a Nitro sandbox, and show every claim this sample's
# page makes with real output.
#
# Usage:
#   ./scripts/setup.sh
#   kubectl -n <gateway namespace> port-forward svc/openshell 8080:8080   # separate terminal
#   ./scripts/demo.sh
#
# Each run deletes the previous run's sandbox (if this run created it) and creates a
# fresh one, so a run never resumes another run's workspace. It leaves the gateway, the
# workspace prerequisites and the demo echo API running; ./scripts/clean.sh removes
# everything.
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
SAMPLE="openshell-kubernetes"
TMP_DIR="$REPO_ROOT/tmp/$SAMPLE"
STATE_FILE="$TMP_DIR/state.env"
LOCAL_DIR="$TMP_DIR/local"
CLI_HOME="$TMP_DIR/home"

[[ -f "$STATE_FILE" ]] || { echo "ERROR: no run record at $STATE_FILE; run ./scripts/setup.sh first" >&2; exit 1; }
set -a; . "$STATE_FILE"; set +a

GATEWAY_PORT="${GATEWAY_PORT:-8080}"

say() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
kc() { if [[ -n "${KUBE_CONTEXT:-}" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi; }

# kubectl reads ~/.kube/config by default, so KUBECONFIG has to be pinned before HOME
# changes below to scope the OpenShell CLI's own config directory -- otherwise kubectl
# would look for a kubeconfig under the CLI's scratch HOME and find none.
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export HOME="$CLI_HOME"
mkdir -p "$HOME"

curl -sk --max-time 3 "https://127.0.0.1:$GATEWAY_PORT/" >/dev/null 2>&1 || true
# A plain reachability probe above is best-effort; the real check is the CLI's own
# "status" below.

say "the mTLS client bundle and the CLI"

MTLS_DIR="$HOME/.config/openshell/gateways/k8s/mtls"
mkdir -p "$MTLS_DIR"
kc -n "$GATEWAY_NAMESPACE" get secret "$GATEWAY_RELEASE-client-tls" -o jsonpath='{.data.ca\.crt}'  | base64 -d > "$MTLS_DIR/ca.crt"
kc -n "$GATEWAY_NAMESPACE" get secret "$GATEWAY_RELEASE-client-tls" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$MTLS_DIR/tls.crt"
kc -n "$GATEWAY_NAMESPACE" get secret "$GATEWAY_RELEASE-client-tls" -o jsonpath='{.data.tls\.key}' | base64 -d > "$MTLS_DIR/tls.key"

"$CLI" gateway remove k8s >/dev/null 2>&1 || true
"$CLI" gateway add "https://127.0.0.1:$GATEWAY_PORT" --local --name k8s
"$CLI" status || die "the CLI could not reach the gateway at https://127.0.0.1:$GATEWAY_PORT -- is 'kubectl port-forward' running?"

say "the demo provider: a credential stored as a Kubernetes Secret, never seen by the agent"

if ! "$CLI" profile list 2>/dev/null | grep -q '^demo-echo '; then
  "$CLI" profile import -f "$SAMPLE_DIR/policy/demo-profile.json"
fi
if ! "$CLI" provider list 2>/dev/null | grep -q '^demo '; then
  # Generated fresh each run, never written to a file and never put on a command line:
  # --credential DEMO_API_KEY (no "=value") has the CLI read it from this process's own
  # DEMO_API_KEY environment variable instead.
  DEMO_API_KEY="$(openssl rand -hex 32)" "$CLI" provider create --name demo --type demo-echo \
    --credential DEMO_API_KEY
fi
echo "  the credential Secret, by name only -- never its value:"
kc get secret -n "$CREDENTIAL_NAMESPACE" -l '!openshell.ai/managed-by' -o name 2>/dev/null || true
kc get secret -n "$CREDENTIAL_NAMESPACE" -o custom-columns=NAME:.metadata.name,TYPE:.type --no-headers

say "a fresh sandbox"

PREVIOUS_SANDBOX="$(grep -o '^LAST_SANDBOX=.*' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)"
if [[ -n "$PREVIOUS_SANDBOX" ]]; then
  "$CLI" sandbox delete --name "$PREVIOUS_SANDBOX" >/dev/null 2>&1 || true
fi

SANDBOX="demo-$(date +%s)"
sed "s|<SANDBOX_NAMESPACE>|$SANDBOX_NAMESPACE|g" "$SAMPLE_DIR/policy/sandbox-policy.json" \
  > "$TMP_DIR/sandbox-policy.rendered.json"

"$CLI" sandbox create --name "$SANDBOX" --policy "$TMP_DIR/sandbox-policy.rendered.json" \
  --provider demo --no-auto-providers --detach -- sleep 3600
echo "LAST_SANDBOX=$SANDBOX" >> "$STATE_FILE"

say "the two pods of this one sandbox"

workload_pod="default--$SANDBOX"
sandbox_uid="$(kc get sandboxes.agents.x-k8s.io "$workload_pod" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.metadata.uid}')"
supervisor_pod="$(kc get pods -n "$SANDBOX_NAMESPACE" -l openshell.ai/boundary-role=supervisor -o json |
  python3 -c "
import json, sys
uid = '$sandbox_uid'
for pod in json.load(sys.stdin)['items']:
    for ref in pod['metadata'].get('ownerReferences', []):
        if ref.get('uid') == uid:
            print(pod['metadata']['name'])
" )"
[[ -n "$supervisor_pod" ]] || die "could not find the supervisor pod owned by sandbox $workload_pod"

echo "  workload pod:   $workload_pod"
kc get pod "$workload_pod" -n "$SANDBOX_NAMESPACE" -o jsonpath='    runtimeClassName: {.spec.runtimeClassName}{"\n"}'
echo "  supervisor pod: $supervisor_pod"
kc get pod "$supervisor_pod" -n "$SANDBOX_NAMESPACE" -o jsonpath='    runtimeClassName: {.spec.runtimeClassName}{"\n"}'
echo "    (empty means no RuntimeClass: an ordinary pod)"

kc get pvc "workspace-$workload_pod" -n "$SANDBOX_NAMESPACE" \
  -o jsonpath='  workspace PVC: {.status.phase} on {.spec.storageClassName}{"\n"}'

say "the workload pod's own kernel, boot and virtio disks"

echo "  guest /proc/version:"
"$CLI" sandbox exec -n "$SANDBOX" --no-login-shell -- cat /proc/version
echo "  guest /sys/class/dmi/id/product_name and disks:"
"$CLI" sandbox exec -n "$SANDBOX" --no-login-shell -- sh -c \
  'echo "product_name: $(cat /sys/class/dmi/id/product_name)"; echo "disks: $(ls /sys/block | tr "\n" " ")"'

node="$(kc get pod "$workload_pod" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.spec.nodeName}')"
if kc get pod node-probe -n "$SANDBOX_NAMESPACE" >/dev/null 2>&1; then
  kc delete pod node-probe -n "$SANDBOX_NAMESPACE" --wait=true >/dev/null 2>&1 || true
fi
kc run node-probe --image=public.ecr.aws/docker/library/busybox:1.36 -n "$SANDBOX_NAMESPACE" \
  --labels="app.kubernetes.io/managed-by=$SAMPLE" --overrides="{\"spec\":{\"nodeName\":\"$node\"}}" \
  --restart=Never -- sleep 300 >/dev/null
kc wait pod/node-probe -n "$SANDBOX_NAMESPACE" --for=condition=Ready --timeout=60s >/dev/null
echo "  the same node's own view, from an ordinary pod on $node:"
kc exec node-probe -n "$SANDBOX_NAMESPACE" -- sh -c \
  'echo "product_name: $(cat /sys/class/dmi/id/product_name)"; echo "disks: $(ls /sys/block | tr "\n" " ")"; cat /proc/version'

say "the agent's credential: a placeholder, never the real value"

echo "  the agent's own environment:"
"$CLI" sandbox exec -n "$SANDBOX" --no-login-shell -- bash -c 'echo "DEMO_API_KEY=$DEMO_API_KEY"'
echo "  the request as the backend received it (the real value, substituted by the supervisor, outside the sandbox):"
# "timeout" is belt-and-suspenders here, not an expected failure: go-httpbin sends
# "Connection: close" but this sample's run has seen the local exec stream outlive the
# server's own FIN past that point, so the command's exit status (0 on a clean close,
# 124 if "timeout" had to step in after the full response was already printed) is not
# itself part of what this step checks -- the printed response body is.
timeout 10 "$CLI" sandbox exec -n "$SANDBOX" --no-login-shell -- bash -c '
exec 3<>/dev/tcp/echo-api.'"$SANDBOX_NAMESPACE"'.svc.cluster.local/80
printf "GET /headers HTTP/1.1\r\nHost: echo-api.'"$SANDBOX_NAMESPACE"'.svc.cluster.local\r\nX-Demo-Api-Key: $DEMO_API_KEY\r\nConnection: close\r\n\r\n" >&3
cat <&3
' | tail -n +6 || true

say "layer 1: OpenShell's policy refuses a file outside it and a destination outside it"

echo "  a file the policy does not list:"
"$CLI" sandbox exec -n "$SANDBOX" --no-login-shell -- cat /root/.bashrc 2>&1 || true
echo "  control -- a file the policy does list:"
"$CLI" sandbox exec -n "$SANDBOX" --no-login-shell -- cat /etc/hostname
echo "  a destination the policy does not list:"
timeout 10 "$CLI" sandbox exec -n "$SANDBOX" --no-login-shell -- bash -c \
  'exec 3<>/dev/tcp/kubernetes.default.svc.cluster.local/443' 2>&1 || true

say "layer 2: the Nitro boundary -- the node is invisible, and the credential is absent"

echo "  processes visible in the guest (its own, only):"
"$CLI" sandbox exec -n "$SANDBOX" --no-login-shell -- ps aux
echo "  no credential anywhere in the guest's environment:"
"$CLI" sandbox exec -n "$SANDBOX" --no-login-shell -- env | grep -iE 'demo|secret|cred' || echo "  (DEMO_API_KEY is the placeholder above; no other credential-shaped variable)"
echo "  no Secret for the real credential is mounted in the workload pod:"
kc get pod "$workload_pod" -n "$SANDBOX_NAMESPACE" -o jsonpath='{range .spec.volumes[*]}{.secret.secretName}{"\n"}{end}' | grep -v '^$' || echo "  (none)"

say "layer 3: the Kubernetes NetworkPolicy drops a direct, workload-initiated connection"

echo "  the NetworkPolicy selecting the workload pod:"
kc get networkpolicy openshell-sandbox-workloads -n "$SANDBOX_NAMESPACE" -o yaml | \
  grep -v -E '^\s*(creationTimestamp|finalizers|-\snetworking|generation|resourceVersion|uid):'

echo "  a connection from the workload pod's own network namespace, outside OpenShell's control (an ephemeral debug container sharing it), to the policy-approved backend by IP -- bypassing OpenShell entirely does not bypass the NetworkPolicy:"
ECHO_IP="$(kc get service echo-api -n "$SANDBOX_NAMESPACE" -o jsonpath='{.spec.clusterIP}')"
# kubectl debug's own wait only covers container creation, not the command finishing, so
# this polls the ephemeral container's own terminated state before reading its logs.
wait_for_ephemeral_exit() { # <pod> <container> -- prints nothing, just waits
  local pod="$1" container="$2" i
  for i in $(seq 1 30); do
    state="$(kc get pod "$pod" -n "$SANDBOX_NAMESPACE" \
      -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name==\"$container\")].state.terminated.reason}" 2>/dev/null)"
    [[ -n "$state" ]] && return 0
    sleep 2
  done
}

kc debug "$workload_pod" -n "$SANDBOX_NAMESPACE" --image=public.ecr.aws/docker/library/busybox:1.36 \
  --target=agent -- sh -c "wget -T 5 -O- http://$ECHO_IP/headers; echo EXIT=\$?" 2>&1 | grep -v '^Defaulting\|^--profile\|^Targeting' || true
debugger="$(kc get pod "$workload_pod" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.spec.ephemeralContainers[-1:].name}')"
wait_for_ephemeral_exit "$workload_pod" "$debugger"
kc logs "$workload_pod" -n "$SANDBOX_NAMESPACE" -c "$debugger"

echo "  control -- the same technique against the supervisor pod, which carries no such restriction:"
kc debug "$supervisor_pod" -n "$SANDBOX_NAMESPACE" --image=public.ecr.aws/docker/library/busybox:1.36 \
  -- sh -c "wget -T 5 -O- http://$ECHO_IP/headers; echo EXIT=\$?" 2>&1 | grep -v '^Defaulting\|^--profile\|^Targeting' || true
debugger2="$(kc get pod "$supervisor_pod" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.spec.ephemeralContainers[-1:].name}')"
wait_for_ephemeral_exit "$supervisor_pod" "$debugger2"
kc logs "$supervisor_pod" -n "$SANDBOX_NAMESPACE" -c "$debugger2"

kc delete pod node-probe -n "$SANDBOX_NAMESPACE" --wait=false >/dev/null 2>&1 || true

say "done"
echo "  sandbox: $SANDBOX (workload pod $workload_pod, supervisor pod $supervisor_pod)"
echo "  run ./scripts/clean.sh to remove everything this sample created."
