#!/usr/bin/env bash
# Run the same four test events in app-standard and app-sandboxed, on the same node, and
# print what the node's Falco and Tetragon saw from each pod.
#
#   scripts/run-comparison.sh            # deploy (when absent), trigger, report
#   scripts/run-comparison.sh --cleanup  # delete this blueprint's namespace
#
# Cluster-wide, it creates only its namespace. Falco and Tetragon are installs the reader makes
# as steps on the page; this script checks for them and stops with the command when one is
# missing.
#
# Overridable (the defaults match the page):
#   NAMESPACE           this blueprint's namespace         (default runtime-detection)
#   FALCO_NAMESPACE     where the Falco DaemonSet runs     (default falco)
#   TETRAGON_NAMESPACE  where the Tetragon DaemonSet runs  (default tetragon)
#   KUBE_CONTEXT        the kube context to pin this run to (default: the current context)
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NAMESPACE="${NAMESPACE:-runtime-detection}"
FALCO_NAMESPACE="${FALCO_NAMESPACE:-falco}"
TETRAGON_NAMESPACE="${TETRAGON_NAMESPACE:-tetragon}"
KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
export NAMESPACE KUBE_CONTEXT

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }

# Read the sample label of the namespace: empty when the namespace is absent; a failed read
# stops the script.
ns_mark() {
  kc get namespace "$NAMESPACE" --ignore-not-found -o 'jsonpath={.metadata.labels.sample}' \
    || die "could not read namespace '$NAMESPACE'; re-run once the cluster reads cleanly"
}

if [[ "${1:-}" == "--cleanup" ]]; then
  exists="$(kc get namespace "$NAMESPACE" --ignore-not-found -o name)" \
    || die "could not read namespace '$NAMESPACE'; nothing was deleted"
  [[ -n "$exists" ]] || { echo "namespace '$NAMESPACE' is already gone"; exit 0; }
  [[ "$(ns_mark)" == "runtime-detection" ]] \
    || die "namespace '$NAMESPACE' is not labelled sample=runtime-detection; deleting nothing"
  kc delete namespace "$NAMESPACE" --wait=true
  exit 0
fi

echo "kube context: $KUBE_CONTEXT"
kc get runtimeclass isolated-sandbox > /dev/null 2>&1 \
  || die "the isolated-sandbox runtime class is not on this cluster; run Getting started first"
kc -n "$FALCO_NAMESPACE" get daemonset -l app.kubernetes.io/name=falco -o name | grep -q . \
  || die "no Falco DaemonSet in namespace '$FALCO_NAMESPACE'. Install it as the page's step 1 says:
  helm install falco falcosecurity/falco --version 9.2.2 --namespace falco --create-namespace -f deploy/falco-values.yaml"
kc -n "$TETRAGON_NAMESPACE" get daemonset -l app.kubernetes.io/name=tetragon -o name | grep -q . \
  || die "no Tetragon DaemonSet in namespace '$TETRAGON_NAMESPACE'. Install it as the page's step 1 says:
  helm install tetragon cilium/tetragon --version 1.8.0 --namespace tetragon --create-namespace -f deploy/tetragon-values.yaml"

mark="$(ns_mark)"
if [[ -z "$mark" ]]; then
  sed "s|<NAMESPACE>|$NAMESPACE|" "$SAMPLE_DIR/deploy/namespace.yaml" | kc create -f -
elif [[ "$mark" != "runtime-detection" ]]; then
  die "namespace '$NAMESPACE' exists and is not labelled sample=runtime-detection, so this
blueprint did not create it. Set NAMESPACE to a name of your own and run this again."
fi
kc -n "$NAMESPACE" apply -f "$SAMPLE_DIR/deploy/tetragon-policy.yaml"
# The sandboxed pod goes first: the ordinary pod's affinity places it on the same node.
for pod in app-sandboxed app-standard; do
  kc -n "$NAMESPACE" apply -f "$SAMPLE_DIR/deploy/$pod.yaml"
  kc -n "$NAMESPACE" wait "pod/$pod" --for=condition=Ready --timeout=600s
done
node="$(kc -n "$NAMESPACE" get pod app-sandboxed -o 'jsonpath={.spec.nodeName}')"
[[ "$(kc -n "$NAMESPACE" get pod app-standard -o 'jsonpath={.spec.nodeName}')" == "$node" ]] \
  || die "app-standard and app-sandboxed are on different nodes, so one tool pod does not watch both"
falco_pod="$(kc -n "$FALCO_NAMESPACE" get pods -l app.kubernetes.io/name=falco \
  --field-selector "spec.nodeName=$node" -o name)"
tetragon_pod="$(kc -n "$TETRAGON_NAMESPACE" get pods -l app.kubernetes.io/name=tetragon \
  --field-selector "spec.nodeName=$node" -o name)"
[[ -n "$falco_pod" && -n "$tetragon_pod" ]] || die "no Falco or Tetragon pod on node $node yet"
echo "both pods are on node $node, watched by $falco_pod and $tetragon_pod"

start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for pod in app-standard app-sandboxed; do
  "$SAMPLE_DIR/scripts/trigger-events.sh" "$pod"
done
sleep 10   # let both tools flush their output

falco_log="$(kc -n "$FALCO_NAMESPACE" logs "$falco_pod" -c falco --since-time="$start")"
tetragon_log="$(kc -n "$TETRAGON_NAMESPACE" logs "$tetragon_pod" -c export-stdout --since-time="$start")"
FALCO_LOG="$falco_log" TETRAGON_LOG="$tetragon_log" python3 - <<'EOF'
import json, os
ns = os.environ["NAMESPACE"]
def lines(name):
    for line in os.environ[name].splitlines():
        if line.startswith("{"):
            yield json.loads(line)
seen = {"app-standard": [], "app-sandboxed": []}
for alert in lines("FALCO_LOG"):
    f = alert.get("output_fields", {})
    if f.get("k8s.ns.name") == ns and f.get("k8s.pod.name") in seen:
        seen[f["k8s.pod.name"]].append(("falco", alert["rule"]))
for event in lines("TETRAGON_LOG"):
    kind, body = next(iter(event.items()))
    pod = body.get("process", {}).get("pod", {})
    if pod.get("namespace") == ns and pod.get("name") in seen:
        what = body.get("function_name") or os.path.basename(body["process"].get("binary", ""))
        seen[pod["name"]].append(("tetragon", f"{kind} {what}"))
for pod, hits in seen.items():
    print(f"\n=== {pod}: {len([h for h in hits if h[0] == 'falco'])} Falco alerts, "
          f"{len([h for h in hits if h[0] == 'tetragon'])} Tetragon events ===")
    for tool, what in hits:
        print(f"  {tool:9} {what}")
# What each tool must report for the four test events in the ordinary pod.
expected = {("falco", r) for r in ("Terminal shell in container", "Read sensitive file untrusted",
                                  "Drop and execute new binary in container",
                                  "Contact K8S API Server From Container")}
expected |= {("tetragon", "process_exec sh"), ("tetragon", "process_kprobe security_file_permission"),
             ("tetragon", "process_exec runtime-detection-test"), ("tetragon", "process_kprobe tcp_connect")}
missing = sorted(expected - set(seen["app-standard"]))
print("\n=== Verdict ===")
if not missing and not seen["app-sandboxed"]:
    print("RESULT: the node's Falco and Tetragon each saw the ordinary pod's test events and\n"
          "none of the sandboxed pod's, which ran the same events on the same node.")
else:
    print(f"NO RESULT: missing from the ordinary pod: {missing or 'nothing'}; "
          f"seen from the sandboxed pod: {len(seen['app-sandboxed'])} events.")
    raise SystemExit(1)
EOF
