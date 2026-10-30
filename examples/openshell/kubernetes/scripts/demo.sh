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

# Scoped to the CLI's own invocations only, never exported. Exporting HOME for the whole
# script would also move where kubectl's own EKS exec-credential plugin looks for AWS
# profile files, which would break every kc call for a reader whose AWS credentials come
# from a named profile rather than already-exported environment variables. XDG_CONFIG_HOME
# is set the same way and for the same reason: if a reader already has it exported, the
# CLI would otherwise read and write their real configuration (its mTLS bundle, its
# registered gateways) instead of this run's own scratch copy under $CLI_HOME.
mkdir -p "$CLI_HOME"
os() { HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_HOME/.config" "$CLI" "$@"; }

curl -sk --max-time 3 "https://127.0.0.1:$GATEWAY_PORT/" >/dev/null 2>&1 || true
# A plain reachability probe above is best-effort; the real check is the CLI's own
# "status" below.

say "the mTLS client bundle and the CLI"

MTLS_DIR="$CLI_HOME/.config/openshell/gateways/k8s/mtls"
mkdir -p "$MTLS_DIR"
kc -n "$GATEWAY_NAMESPACE" get secret "$GATEWAY_RELEASE-client-tls" -o jsonpath='{.data.ca\.crt}'  | base64 -d > "$MTLS_DIR/ca.crt"
kc -n "$GATEWAY_NAMESPACE" get secret "$GATEWAY_RELEASE-client-tls" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$MTLS_DIR/tls.crt"
kc -n "$GATEWAY_NAMESPACE" get secret "$GATEWAY_RELEASE-client-tls" -o jsonpath='{.data.tls\.key}' | base64 -d > "$MTLS_DIR/tls.key"

os gateway remove k8s >/dev/null 2>&1 || true
os gateway add "https://127.0.0.1:$GATEWAY_PORT" --local --name k8s
os status || die "the CLI could not reach the gateway at https://127.0.0.1:$GATEWAY_PORT -- is 'kubectl port-forward' running?"

say "the demo provider: a credential stored as a Kubernetes Secret, never seen by the agent"

# Captured into a variable before grepping it, not grepped straight off the pipe: under
# "set -o pipefail", "os ... | grep -q ..." can report exit 141 once grep is satisfied and
# closes its end of the pipe early, which would read here as "not found" and attempt to
# create something that already exists.
profile_listing="$(os profile list 2>/dev/null)" || profile_listing=""
if ! grep -q '^demo-echo ' <<<"$profile_listing"; then
  os profile import -f "$SAMPLE_DIR/policy/demo-profile.json"
fi
provider_listing="$(os provider list 2>/dev/null)" || provider_listing=""
if grep -q '^demo ' <<<"$provider_listing" && [[ -z "${DEMO_API_KEY_SHA256:-}" ]]; then
  # The provider exists, but this run has no recorded digest for it -- most likely
  # because an earlier ./scripts/setup.sh re-run truncated this sample's state file
  # (setup.sh starts a fresh record every time it runs) while the provider itself
  # persisted in the gateway's own storage. Comparing against no digest, or a stale one
  # left over from an unrelated value, would not prove anything, so this starts over.
  os provider delete demo >/dev/null 2>&1 || true
  provider_listing=""
fi
if ! grep -q '^demo ' <<<"$provider_listing"; then
  # Generated fresh, never written to a file or put on a command line: --credential
  # DEMO_API_KEY (no "=value") has the CLI read it from this process's own DEMO_API_KEY
  # environment variable instead. The digest (never the value) is recorded only after
  # the provider is actually created, so a failed create cannot leave a digest on record
  # for a provider that does not exist; a later run of this script, which skips
  # re-creating a provider that already exists and so never sees the value again
  # either, reads the recorded digest back to confirm the backend received the real
  # credential, by comparing digests rather than printing it.
  demo_key="$(openssl rand -hex 32)"
  demo_key_sha256="$(printf '%s' "$demo_key" | sha256sum | cut -d' ' -f1)"
  DEMO_API_KEY="$demo_key" os provider create --name demo --type demo-echo --credential DEMO_API_KEY
  echo "DEMO_API_KEY_SHA256=$demo_key_sha256" >> "$STATE_FILE"
  DEMO_API_KEY_SHA256="$demo_key_sha256"
  unset demo_key demo_key_sha256
fi
[[ -n "${DEMO_API_KEY_SHA256:-}" ]] ||
  die "no DEMO_API_KEY_SHA256 is recorded for the existing provider 'demo'; this should not happen after the check above"
echo "  the credential Secret, by name only -- never its value:"
kc get secret -n "$CREDENTIAL_NAMESPACE" -o custom-columns=NAME:.metadata.name,TYPE:.type --no-headers

say "a fresh sandbox"

# STATE_FILE was sourced at the top of this script, so a LAST_SANDBOX appended by an
# earlier run is already the shell variable ${LAST_SANDBOX:-}, holding whichever
# assignment came last in the file -- there is no need to re-parse the file by hand, and
# doing so by grepping every "LAST_SANDBOX=" line and taking the last field used to break
# from the third run on, once the file held more than one such line.
if [[ -n "${LAST_SANDBOX:-}" ]]; then
  os sandbox delete --name "$LAST_SANDBOX" >/dev/null 2>&1 || true
fi

SANDBOX="demo-$(date +%s)"
sed "s|<SANDBOX_NAMESPACE>|$SANDBOX_NAMESPACE|g" "$SAMPLE_DIR/policy/sandbox-policy.json" \
  > "$TMP_DIR/sandbox-policy.rendered.json"

os sandbox create --name "$SANDBOX" --policy "$TMP_DIR/sandbox-policy.rendered.json" \
  --provider demo --no-auto-providers --detach -- sleep 3600
echo "LAST_SANDBOX=$SANDBOX" >> "$STATE_FILE"

workload_pod="default--$SANDBOX"
kc wait pod/"$workload_pod" -n "$SANDBOX_NAMESPACE" --for=condition=Ready --timeout=5m ||
  die "the workload pod $workload_pod did not reach Ready; 'kubectl describe pod/$workload_pod -n $SANDBOX_NAMESPACE' says why"

say "the two pods of this one sandbox"

sandbox_uid="$(kc get sandboxes.agents.x-k8s.io "$workload_pod" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.metadata.uid}')"
supervisor_pod="$(kc get pods -n "$SANDBOX_NAMESPACE" -l openshell.ai/boundary-role=supervisor -o json |
  python3 -I -c "
import json, sys
uid = '$sandbox_uid'
for pod in json.load(sys.stdin)['items']:
    for ref in pod['metadata'].get('ownerReferences', []):
        if ref.get('uid') == uid:
            print(pod['metadata']['name'])
" )"
[[ -n "$supervisor_pod" ]] || die "could not find the supervisor pod owned by sandbox $workload_pod"
kc wait pod/"$supervisor_pod" -n "$SANDBOX_NAMESPACE" --for=condition=Ready --timeout=5m ||
  die "the supervisor pod $supervisor_pod did not reach Ready; 'kubectl describe pod/$supervisor_pod -n $SANDBOX_NAMESPACE' says why"

echo "  workload pod:   $workload_pod"
kc get pod "$workload_pod" -n "$SANDBOX_NAMESPACE" -o jsonpath='    runtimeClassName: {.spec.runtimeClassName}{"\n"}'
echo "  supervisor pod: $supervisor_pod"
kc get pod "$supervisor_pod" -n "$SANDBOX_NAMESPACE" -o jsonpath='    runtimeClassName: {.spec.runtimeClassName}{"\n"}'
echo "    (empty means no RuntimeClass: an ordinary pod)"

kc get pvc "workspace-$workload_pod" -n "$SANDBOX_NAMESPACE" \
  -o jsonpath='  workspace PVC: {.status.phase} on {.spec.storageClassName}{"\n"}'

say "the workload pod's own kernel, boot and virtio disks"

echo "  guest /proc/version:"
os sandbox exec -n "$SANDBOX" --no-login-shell -- cat /proc/version
echo "  guest /sys/class/dmi/id/product_name and disks:"
os sandbox exec -n "$SANDBOX" --no-login-shell -- sh -c \
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
os sandbox exec -n "$SANDBOX" --no-login-shell -- bash -c 'echo "DEMO_API_KEY=$DEMO_API_KEY"'

echo "  the digest of the value the backend received (substituted by the supervisor, outside the sandbox), computed INSIDE the sandbox so the real value is never printed anywhere, including by this script:"
# grep -m1 is load-bearing, not cosmetic: go-httpbin sends "Connection: close" but leaves
# the socket open past that point, so a grep with no match limit (or anything relying on
# the stream's own EOF, such as "tail -n1") blocks forever waiting for more input that
# never comes. -m1 makes grep exit the moment it has the one line this needs, which ends
# the pipeline on its own; "timeout" stays only as a last-resort backstop.
response_digest="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_HOME/.config" timeout 10 "$CLI" sandbox exec -n "$SANDBOX" --no-login-shell -- bash -c '
exec 3<>/dev/tcp/echo-api.'"$SANDBOX_NAMESPACE"'.svc.cluster.local/80
printf "GET /headers HTTP/1.1\r\nHost: echo-api.'"$SANDBOX_NAMESPACE"'.svc.cluster.local\r\nX-Demo-Api-Key: $DEMO_API_KEY\r\nConnection: close\r\n\r\n" >&3
value=$(grep -m1 -A1 "X-Demo-Api-Key" <&3 | sed -n 2p | sed -E "s/^[[:space:]]*\"([^\"]*)\".*/\1/")
printf "%s" "$value" | sha256sum | cut -d" " -f1
' 2>/dev/null)" || response_digest=""
echo "  resolved credential digest: ${response_digest:-<no response>}"
# e3b0c4...  is the SHA-256 of an empty string: the digest of "nothing came back", never
# treated as a coincidental match, and a mismatch stops the run rather than printing
# "false" and continuing as if the claim had merely failed to be shown.
empty_sha256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
if [[ -z "$response_digest" || "$response_digest" == "$empty_sha256" ]]; then
  die "the echo API returned no X-Demo-Api-Key header to extract a digest from; 'kubectl logs' on the echo-api pod and the supervisor say why"
fi
[[ "$response_digest" == "$DEMO_API_KEY_SHA256" ]] ||
  die "the digest the backend received ($response_digest) does not match the digest this run stored in the Secret ($DEMO_API_KEY_SHA256); the credential substitution this page claims did not happen"
echo "  matches the digest of the credential this run stored in the Secret: true"

say "layer 1: OpenShell's policy refuses a file outside it and a destination outside it"

echo "  a file the policy does not list (world-readable, so this is the policy and not a Unix permission):"
os sandbox exec -n "$SANDBOX" --no-login-shell -- sh -c \
  'stat -c "%a %n" /var/lib/dpkg/status; cat /var/lib/dpkg/status >/dev/null; echo "cat exit=$?"' 2>&1 || true
echo "  control -- a file the policy does list:"
os sandbox exec -n "$SANDBOX" --no-login-shell -- cat /etc/hostname
echo "  a destination the policy does not list:"
HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_HOME/.config" timeout 10 "$CLI" sandbox exec -n "$SANDBOX" --no-login-shell -- bash -c \
  'exec 3<>/dev/tcp/kubernetes.default.svc.cluster.local/443' 2>&1 || true

say "layer 2: the Nitro boundary -- the node is invisible, and the credential is absent"

echo "  processes visible in the guest (its own, only):"
os sandbox exec -n "$SANDBOX" --no-login-shell -- ps aux
echo "  the guest's environment, checked rather than eyeballed:"
guest_env="$(os sandbox exec -n "$SANDBOX" --no-login-shell -- env)"
echo "$guest_env" | grep -E '^DEMO_API_KEY='
# Asserted, not just printed: a DEMO_API_KEY that is not in the placeholder form would
# mean the substitution this page claims did not happen, and a check that merely printed
# the line would not catch that.
echo "$guest_env" | grep -qE '^DEMO_API_KEY=openshell:resolve:env:[A-Za-z0-9_]+$' ||
  die "DEMO_API_KEY in the guest's environment is not in OpenShell's placeholder form; the credential substitution this page claims did not happen"
# Broader than just the placeholder's own name: any AWS-style _ID/_KEY pair, PAT, auth or
# pass fields, and a second occurrence of OpenShell's own placeholder prefix under a
# different variable name, so a real secret under an unexpected name is still caught.
if echo "$guest_env" | grep -vE '^DEMO_API_KEY=' | \
    grep -qiE '(secret|token|password|passwd|credential|_key=|_key_id=|pat=|auth|openshell:resolve:)'; then
  echo "  found an unexpected credential-shaped variable besides the placeholder:"
  echo "$guest_env" | grep -vE '^DEMO_API_KEY=' | \
    grep -iE '(secret|token|password|passwd|credential|_key=|_key_id=|pat=|auth|openshell:resolve:)'
else
  echo "  no other credential-shaped variable"
fi
echo "  no Secret for the real credential is mounted in the workload pod:"
kc get pod "$workload_pod" -n "$SANDBOX_NAMESPACE" -o jsonpath='{range .spec.volumes[*]}{.secret.secretName}{"\n"}{end}' | grep -v '^$' || echo "  (none)"

say "layer 3: the Kubernetes NetworkPolicy drops a direct, workload-initiated connection"

echo "  every NetworkPolicy in the sandbox namespace, and which select the workload pod's labels:"
kc get networkpolicy -n "$SANDBOX_NAMESPACE" -o wide
workload_labels="$(kc get pod "$workload_pod" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.metadata.labels}')"
echo "  workload pod labels: $workload_labels"

# Two of the policies above select the workload pod's labels, not one: the generic
# "openshell-sandbox-workloads" (by boundary-role=workload, shared by every sandbox) and
# a per-sandbox "os-control-<boundary-pair>" (by boundary-pair, unique to this one).
# Together, not either alone, is what actually governs the workload pod's egress: the
# first carries no egress rule at all under its Egress policyType, which denies all of
# it; the second adds back exactly one egress rule, to the supervisor on port 5500. Both
# are shown, because showing only the first -- as an earlier draft of this script did --
# makes the workload pod look like it can never egress anywhere, when the truth is it can
# reach one destination, the supervisor, on one port.
boundary_pair="$(kc get pod "$workload_pod" -n "$SANDBOX_NAMESPACE" \
  -o jsonpath='{.metadata.labels.openshell\.ai/boundary-pair}')"
echo "  the two NetworkPolicies selecting the workload pod (boundary-pair=$boundary_pair):"
# Strips run-to-run noise (timestamps, resource versions, the cluster's own finalizer,
# owner references) by parsing the YAML and removing those metadata keys, rather than by
# a line-matching pattern: a pattern anchored on one field's own "key:" syntax does not
# also match a different field whose value happens to share a word with it (an earlier
# version of this filter excluded lines ending in a literal ":", which silently kept
# "kind: Sandbox" and "name: default--..." because neither line ends that way).
strip_metadata_noise() {
  python3 -c '
import sys
import yaml

obj = yaml.safe_load(sys.stdin)
meta = obj.get("metadata", {})
for key in ("creationTimestamp", "finalizers", "generation", "resourceVersion", "uid", "ownerReferences"):
    meta.pop(key, None)
yaml.safe_dump(obj, sys.stdout, default_flow_style=False)
'
}
kc get networkpolicy openshell-sandbox-workloads -n "$SANDBOX_NAMESPACE" -o yaml | strip_metadata_noise
kc get networkpolicy "os-control-$boundary_pair" -n "$SANDBOX_NAMESPACE" -o yaml | strip_metadata_noise

echo "  a connection from the workload pod's own network namespace, outside OpenShell's control (an ephemeral debug container sharing it), to the policy-approved backend by IP -- bypassing OpenShell entirely does not bypass the NetworkPolicy:"
ECHO_IP="$(kc get service echo-api -n "$SANDBOX_NAMESPACE" -o jsonpath='{.spec.clusterIP}')"
# kubectl debug's own wait only covers container creation, not the command finishing, so
# this polls the ephemeral container's own terminated state before reading its logs, and
# reports plainly rather than reading silently on if it never terminates.
wait_for_ephemeral_exit() { # <pod> <container>
  local pod="$1" container="$2" i state
  for i in $(seq 1 30); do
    state="$(kc get pod "$pod" -n "$SANDBOX_NAMESPACE" \
      -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name==\"$container\")].state.terminated.reason}" 2>/dev/null)"
    [[ -n "$state" ]] && return 0
    sleep 2
  done
  echo "  WARNING: ephemeral container $container in $pod did not terminate within 60s; its logs below may be partial"
  return 1
}

kc debug "$workload_pod" -n "$SANDBOX_NAMESPACE" --image=public.ecr.aws/docker/library/busybox:1.36 \
  --target=agent -- sh -c "wget -T 5 -O- http://$ECHO_IP/headers; echo EXIT=\$?" 2>&1 | grep -v '^Defaulting\|^--profile\|^Targeting' || true
debugger="$(kc get pod "$workload_pod" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.spec.ephemeralContainers[-1:].name}')"
wait_for_ephemeral_exit "$workload_pod" "$debugger" || true
kc logs "$workload_pod" -n "$SANDBOX_NAMESPACE" -c "$debugger"

echo "  control -- the same technique against the supervisor pod, which carries no such restriction:"
kc debug "$supervisor_pod" -n "$SANDBOX_NAMESPACE" --image=public.ecr.aws/docker/library/busybox:1.36 \
  -- sh -c "wget -T 5 -O- http://$ECHO_IP/headers; echo EXIT=\$?" 2>&1 | grep -v '^Defaulting\|^--profile\|^Targeting' || true
debugger2="$(kc get pod "$supervisor_pod" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.spec.ephemeralContainers[-1:].name}')"
wait_for_ephemeral_exit "$supervisor_pod" "$debugger2" || true
kc logs "$supervisor_pod" -n "$SANDBOX_NAMESPACE" -c "$debugger2"

kc delete pod node-probe -n "$SANDBOX_NAMESPACE" --wait=false >/dev/null 2>&1 || true

say "done"
echo "  sandbox: $SANDBOX (workload pod $workload_pod, supervisor pod $supervisor_pod)"
echo "  run ./scripts/clean.sh to remove everything this sample created."
