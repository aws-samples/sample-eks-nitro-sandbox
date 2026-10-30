#!/usr/bin/env bash
# setup.sh -- install OpenShell on this cluster: the gateway chart and the workspace
# chart, both pinned to v0.1.6, with every workload pod they create opting into a Nitro
# sandbox.
#
# Usage:
#   cp .env.example .env && $EDITOR .env   # optional; the defaults match the page
#   ./scripts/setup.sh
#
# What it does, in order:
#   1. checks the tools, the kube context, the agent-sandbox controller, network policy
#      enforcement and the MutatingAdmissionPolicy API;
#   2. creates the gateway and sandbox namespaces when absent, and labels them;
#   3. labels the isolated-sandbox RuntimeClass for OpenShell's resource admission, when
#      the label is not already there;
#   4. applies the namespace-scoped admission adapter that fits OpenShell's generated
#      workload pod to a Nitro sandbox guest (deploy/nitro-adapter.yaml);
#   5. applies the namespace-scoped RBAC this sample's own run found missing from the
#      split-release, shared-workspace-mode combination the setup guide describes
#      (deploy/gateway-sandbox-rbac.yaml -- see that file for the exact gap);
#   6. downloads and verifies the pinned OpenShell CLI, the gateway chart and the
#      workspace chart against versions.json;
#   7. installs the gateway chart, with workspaceResources.enabled=false so the
#      namespace-scoped sandbox prerequisites come from the workspace chart instead;
#   8. installs the workspace chart in the sandbox namespace;
#   9. copies the gateway's client-tls Secret into the sandbox namespace, which this
#      sample's own run found the supervisor pod needs and the split pattern does not
#      create there on its own;
#  10. starts the demo echo API this sample's policy and provider point at.
#
# It never changes a cluster-wide setting (network policy enforcement is checked, not
# turned on here -- see the page), never upgrades or reconfigures a shared install such
# as agent-sandbox, and never reuses a resource that is not this sample's: it stops
# instead, and says what it found.
#
# Overridable in .env (the defaults match the page):
#   KUBE_CONTEXT GATEWAY_NAMESPACE SANDBOX_NAMESPACE CREDENTIAL_NAMESPACE
#   GATEWAY_RELEASE WORKSPACE_STORAGE_CLASS
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
SAMPLE="openshell-kubernetes"
TMP_DIR="$REPO_ROOT/tmp/$SAMPLE"
LOCAL_DIR="$TMP_DIR/local"
STATE_FILE="$TMP_DIR/state.env"

for arg in "$@"; do
  case "$arg" in
    --help|-h) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$TMP_DIR" "$LOCAL_DIR"
if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; . "$SAMPLE_DIR/.env"; set +a; fi

KUBE_CONTEXT="${KUBE_CONTEXT:-}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-openshell-kubernetes}"
SANDBOX_NAMESPACE="${SANDBOX_NAMESPACE:-openshell-kubernetes-sandbox}"
CREDENTIAL_NAMESPACE="${CREDENTIAL_NAMESPACE:-openshell-kubernetes-credentials}"
GATEWAY_RELEASE="${GATEWAY_RELEASE:-openshell}"
WORKSPACE_RELEASE="${GATEWAY_RELEASE}-workspace"
WORKSPACE_STORAGE_CLASS="${WORKSPACE_STORAGE_CLASS:-auto-ebs-sc}"
RUNTIME_CLASS="isolated-sandbox"
APPROVAL_LABEL="openshell.ai/sandbox-attachable"
ADAPTER="${SAMPLE}-nitro-adapter"
RBAC_GAP="openshell-sandbox-rbac-gap"
ECHO_IMAGE="docker.io/mccutchen/go-httpbin:v2.15.0"

say() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
kc() { if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi; }
state_put() { printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"; }

: > "$STATE_FILE"
state_put SAMPLE "$SAMPLE"
state_put GATEWAY_NAMESPACE "$GATEWAY_NAMESPACE"
state_put SANDBOX_NAMESPACE "$SANDBOX_NAMESPACE"
state_put CREDENTIAL_NAMESPACE "$CREDENTIAL_NAMESPACE"
state_put GATEWAY_RELEASE "$GATEWAY_RELEASE"
state_put WORKSPACE_RELEASE "$WORKSPACE_RELEASE"
state_put KUBE_CONTEXT "$KUBE_CONTEXT"

jqr() { jq -r "$1" "$SAMPLE_DIR/versions.json"; }
GATEWAY_CHART_REF="$(jqr '.gateway_chart.ref')"
GATEWAY_CHART_VERSION="$(jqr '.gateway_chart.version')"
GATEWAY_CHART_SHA256="$(jqr '.gateway_chart.sha256')"
WORKSPACE_CHART_REF="$(jqr '.workspace_chart.ref')"
WORKSPACE_CHART_VERSION="$(jqr '.workspace_chart.version')"
WORKSPACE_CHART_SHA256="$(jqr '.workspace_chart.sha256')"
UPSTREAM_REF="$(jqr '.upstream_ref')"
CLI_ASSET="$(jqr '.cli_asset')"
CLI_SHA256="$(jqr '.cli_sha256')"
CLI="$LOCAL_DIR/openshell-$UPSTREAM_REF"
state_put CLI "$CLI"
state_put LOCAL_DIR "$LOCAL_DIR"

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------

say "checking tools and the cluster (1/10)"

for tool in kubectl helm jq curl openssl python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

kc cluster-info >/dev/null 2>&1 || die "no reachable cluster for context '${KUBE_CONTEXT:-current}'"

kc get crd sandboxes.agents.x-k8s.io -o name >/dev/null 2>&1 ||
  die "the agent-sandbox controller is not on this cluster. Install it as Getting started > Warm pool does, then re-run this script:
  kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.6/sandbox-with-extensions.yaml"
echo "  agent-sandbox: reusing the install already on this cluster"

kc api-resources --api-group=admissionregistration.k8s.io -o name 2>/dev/null |
  grep -q '^mutatingadmissionpolicies\.' ||
  die "this cluster does not serve MutatingAdmissionPolicy, which this sample needs to adapt OpenShell's workload pod. It is stable and enabled by default from Kubernetes 1.36. 'kubectl version' shows what this cluster runs."

enforcement="$(kc get configmap -n kube-system amazon-vpc-cni \
  -o jsonpath='{.data.enable-network-policy-controller}' 2>/dev/null)" ||
  die "could not read the amazon-vpc-cni ConfigMap in kube-system"
[[ "$enforcement" == "true" ]] ||
  die "network policy enforcement is off on this cluster (enable-network-policy-controller=$enforcement). OpenShell requires it -- see Getting started > Coding agent for the one-time command, then re-run this script."
echo "  network policy enforcement: on"

# ---------------------------------------------------------------------------
# 2. Namespaces
# ---------------------------------------------------------------------------

say "the gateway and sandbox namespaces (2/10)"

for ns in "$GATEWAY_NAMESPACE" "$SANDBOX_NAMESPACE"; do
  if kc get ns "$ns" >/dev/null 2>&1; then
    owner="$(kc get ns "$ns" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')"
    [[ "$owner" == "$SAMPLE" ]] ||
      die "the namespace $ns already exists and is not this sample's (managed-by='$owner'); created nothing. Delete it, or set a new name in .env."
    echo "  reusing the namespace $ns (this sample's)"
  else
    kc create namespace "$ns"
    kc label namespace "$ns" "app.kubernetes.io/managed-by=$SAMPLE"
    echo "  created the namespace $ns"
  fi
done

# ---------------------------------------------------------------------------
# 3. The RuntimeClass approval label
# ---------------------------------------------------------------------------

say "the isolated-sandbox RuntimeClass's OpenShell approval label (3/10)"

runtime_label="$(kc get runtimeclass "$RUNTIME_CLASS" \
  -o jsonpath="{.metadata.labels['openshell\.ai/sandbox-attachable']}" 2>/dev/null)" ||
  die "could not read the $RUNTIME_CLASS RuntimeClass"
if [[ "$runtime_label" == "true" ]]; then
  echo "  runtime class: $RUNTIME_CLASS already carries $APPROVAL_LABEL=true"
else
  kc label runtimeclass "$RUNTIME_CLASS" "$APPROVAL_LABEL=true"
  echo "  runtime class: added $APPROVAL_LABEL=true to $RUNTIME_CLASS"
fi

# ---------------------------------------------------------------------------
# 4. The admission adapter
# ---------------------------------------------------------------------------

say "the admission adapter that fits OpenShell's workload pod to a Nitro sandbox (4/10)"

for kind in mutatingadmissionpolicy mutatingadmissionpolicybinding; do
  owner="$(kc get "$kind" "$ADAPTER" --ignore-not-found \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)" ||
    die "could not determine whether the $kind $ADAPTER exists; created nothing"
  if [[ -n "$owner" && "$owner" != "$SAMPLE" ]]; then
    die "the $kind $ADAPTER already exists and is not this sample's (managed-by='$owner'); created nothing."
  fi
done

sed -e "s|<ADAPTER_NAME>|$ADAPTER|g" -e "s|<MANAGED_BY>|$SAMPLE|g" \
  "$SAMPLE_DIR/deploy/nitro-adapter.yaml" > "$TMP_DIR/nitro-adapter.yaml"
kc apply -f "$TMP_DIR/nitro-adapter.yaml"
echo "  applied $ADAPTER, scoped to namespaces labelled managed-by=$SAMPLE"

# ---------------------------------------------------------------------------
# 5. The RBAC gap
# ---------------------------------------------------------------------------

say "the namespace-scoped RBAC this sample's own run found missing (5/10)"

for kind in role rolebinding; do
  owner="$(kc get "$kind" "$RBAC_GAP" -n "$SANDBOX_NAMESPACE" --ignore-not-found \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)" ||
    die "could not determine whether the $kind $RBAC_GAP exists; created nothing"
  if [[ -n "$owner" && "$owner" != "$SAMPLE" ]]; then
    die "the $kind $RBAC_GAP already exists in $SANDBOX_NAMESPACE and is not this sample's (managed-by='$owner'); created nothing."
  fi
done

sed -e "s|<SANDBOX_NAMESPACE>|$SANDBOX_NAMESPACE|g" \
    -e "s|<GATEWAY_NAMESPACE>|$GATEWAY_NAMESPACE|g" \
    -e "s|<GATEWAY_SA_NAME>|$GATEWAY_RELEASE|g" \
    -e "s|<MANAGED_BY>|$SAMPLE|g" \
    "$SAMPLE_DIR/deploy/gateway-sandbox-rbac.yaml" > "$TMP_DIR/gateway-sandbox-rbac.yaml"
kc apply -f "$TMP_DIR/gateway-sandbox-rbac.yaml"
echo "  applied $RBAC_GAP in $SANDBOX_NAMESPACE, scoped to the gateway's own ServiceAccount"

# ---------------------------------------------------------------------------
# 6. The pinned CLI and charts
# ---------------------------------------------------------------------------

say "the pinned OpenShell CLI, gateway chart and workspace chart ($UPSTREAM_REF) (6/10)"

if [[ -x "$CLI" ]]; then
  echo "  reusing the verified CLI at $CLI"
else
  curl -fsSL -o "$LOCAL_DIR/$CLI_ASSET" \
    "https://github.com/NVIDIA/OpenShell/releases/download/$UPSTREAM_REF/$CLI_ASSET" ||
    die "could not download the OpenShell CLI $CLI_ASSET for $UPSTREAM_REF"
  echo "$CLI_SHA256  $LOCAL_DIR/$CLI_ASSET" | sha256sum -c - >/dev/null ||
    die "the OpenShell CLI archive does not match the SHA-256 in versions.json; refusing to use it."
  tar xzf "$LOCAL_DIR/$CLI_ASSET" -C "$LOCAL_DIR" openshell
  mv "$LOCAL_DIR/openshell" "$CLI"
  chmod 755 "$CLI"
  rm -f "$LOCAL_DIR/$CLI_ASSET"
  echo "  downloaded and verified the CLI: $("$CLI" --version)"
fi

GATEWAY_CHART="$LOCAL_DIR/helm-chart-$GATEWAY_CHART_VERSION.tgz"
if [[ ! -f "$GATEWAY_CHART" ]]; then
  helm pull "$GATEWAY_CHART_REF" --version "$GATEWAY_CHART_VERSION" --destination "$LOCAL_DIR" >/dev/null ||
    die "could not pull the OpenShell gateway chart $GATEWAY_CHART_VERSION"
fi
echo "$GATEWAY_CHART_SHA256  $GATEWAY_CHART" | sha256sum -c - >/dev/null || {
  rm -f "$GATEWAY_CHART"; die "the gateway chart does not match the SHA-256 in versions.json; refusing to install it."
}

WORKSPACE_CHART="$LOCAL_DIR/openshell-workspace-$WORKSPACE_CHART_VERSION.tgz"
if [[ ! -f "$WORKSPACE_CHART" ]]; then
  helm pull "$WORKSPACE_CHART_REF" --version "$WORKSPACE_CHART_VERSION" --destination "$LOCAL_DIR" >/dev/null ||
    die "could not pull the OpenShell workspace chart $WORKSPACE_CHART_VERSION"
fi
echo "$WORKSPACE_CHART_SHA256  $WORKSPACE_CHART" | sha256sum -c - >/dev/null || {
  rm -f "$WORKSPACE_CHART"; die "the workspace chart does not match the SHA-256 in versions.json; refusing to install it."
}
echo "  verified the gateway chart and the workspace chart against their pinned checksums"
state_put GATEWAY_CHART "$GATEWAY_CHART"
state_put WORKSPACE_CHART "$WORKSPACE_CHART"

# ---------------------------------------------------------------------------
# 7. The gateway chart
# ---------------------------------------------------------------------------

say "the OpenShell gateway (7/10)"

sed -e "s|<RELEASE>|$GATEWAY_RELEASE|g" \
    -e "s|<NAMESPACE>|$GATEWAY_NAMESPACE|g" \
    -e "s|<SANDBOX_NAMESPACE>|$SANDBOX_NAMESPACE|g" \
    -e "s|<CREDENTIAL_NAMESPACE>|$CREDENTIAL_NAMESPACE|g" \
    -e "s|<WORKSPACE_STORAGE_CLASS>|$WORKSPACE_STORAGE_CLASS|g" \
    "$SAMPLE_DIR/deploy/gateway-values.yaml" > "$TMP_DIR/gateway-values.yaml"

helm template "$GATEWAY_RELEASE" "$GATEWAY_CHART" -n "$GATEWAY_NAMESPACE" \
  -f "$TMP_DIR/gateway-values.yaml" --set agentSandbox.preflight.enabled=false \
  > "$TMP_DIR/gateway-rendered.yaml" ||
  die "could not render the gateway chart with this sample's values"
python3 - "$TMP_DIR/gateway-rendered.yaml" <<'PY'
import sys
import yaml

public = {"Ingress", "Gateway", "GRPCRoute", "HTTPRoute", "Route"}
findings = []
for obj in yaml.safe_load_all(open(sys.argv[1])):
    if not obj:
        continue
    kind = obj.get("kind")
    if kind in public:
        findings.append(f"the chart rendered a {kind}, which would be reachable from outside the cluster")
    if kind == "Service" and obj.get("spec", {}).get("type", "ClusterIP") != "ClusterIP":
        findings.append(f"the chart rendered a {obj['spec']['type']} Service, {obj['metadata']['name']}")
if findings:
    for f in findings:
        print("ERROR: " + f, file=sys.stderr)
    sys.exit(1)
print("  rendered chart: all Services are ClusterIP, and no Ingress, Gateway or Route")
PY

# Installed without --wait: until the workspace chart below grants the gateway's
# ServiceAccount access to Sandboxes in the sandbox namespace, the gateway pod cannot
# reach Ready, and a --wait here would do nothing but time out. The rollout status
# check at the end of step 8 is where this script actually waits for it.
helm upgrade --install "$GATEWAY_RELEASE" "$GATEWAY_CHART" \
  ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"} \
  -n "$GATEWAY_NAMESPACE" -f "$TMP_DIR/gateway-values.yaml" --timeout 10m ||
  die "the OpenShell gateway chart did not install; 'helm status $GATEWAY_RELEASE -n $GATEWAY_NAMESPACE' says why"

# ---------------------------------------------------------------------------
# 8. The workspace chart
# ---------------------------------------------------------------------------

say "the sandbox namespace's own prerequisites (8/10)"

sed -e "s|<GATEWAY_RELEASE>|$GATEWAY_RELEASE|g" -e "s|<GATEWAY_NAMESPACE>|$GATEWAY_NAMESPACE|g" \
  "$SAMPLE_DIR/deploy/workspace-values.yaml" > "$TMP_DIR/workspace-values.yaml"

helm upgrade --install "$WORKSPACE_RELEASE" "$WORKSPACE_CHART" \
  ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"} \
  -n "$SANDBOX_NAMESPACE" -f "$TMP_DIR/workspace-values.yaml" --wait --timeout 3m ||
  die "the workspace chart did not install; 'helm status $WORKSPACE_RELEASE -n $SANDBOX_NAMESPACE' says why"

kc rollout status statefulset/"$GATEWAY_RELEASE" -n "$GATEWAY_NAMESPACE" --timeout=5m ||
  die "the gateway did not reach Ready after the workspace chart installed; 'kubectl get pods -n $GATEWAY_NAMESPACE' says why"

# This sample's own run found that the gateway's client-tls Secret -- which the
# supervisor pod mounts -- exists only in the gateway's release namespace. The split
# pattern schedules the supervisor pod in the sandbox namespace instead, and nothing in
# either chart copies the Secret there. Until the chart does, this script copies it
# (never moves or regenerates it) each time setup.sh runs, so an operator-rotated
# certificate reaches the sandbox namespace too.
kc get secret "$GATEWAY_RELEASE-client-tls" -n "$GATEWAY_NAMESPACE" -o json |
  python3 -c "
import json, sys
d = json.load(sys.stdin)
print(json.dumps({
    'apiVersion': 'v1', 'kind': 'Secret', 'type': d['type'],
    'metadata': {'name': d['metadata']['name'], 'namespace': '$SANDBOX_NAMESPACE',
                 'labels': {'app.kubernetes.io/managed-by': '$SAMPLE'}},
    'data': d['data'],
}))" | kc apply -f -
echo "  copied the gateway's client-tls Secret into $SANDBOX_NAMESPACE for the supervisor pod"

credential_ns_owner="$(kc get ns "$CREDENTIAL_NAMESPACE" \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
if [[ -n "$credential_ns_owner" ]]; then
  kc label namespace "$CREDENTIAL_NAMESPACE" "app.kubernetes.io/managed-by=$SAMPLE" --overwrite >/dev/null
fi

# ---------------------------------------------------------------------------
# 9. The demo echo API
# ---------------------------------------------------------------------------

say "the demo echo API this sample's policy and provider point at (9/10)"

if kc get pod echo-api -n "$SANDBOX_NAMESPACE" >/dev/null 2>&1; then
  echo "  reusing the echo-api pod already in $SANDBOX_NAMESPACE"
else
  kc run echo-api --image="$ECHO_IMAGE" --port=8080 -n "$SANDBOX_NAMESPACE" \
    --labels="app.kubernetes.io/managed-by=$SAMPLE" --restart=Always
  kc wait pod/echo-api -n "$SANDBOX_NAMESPACE" --for=condition=Ready --timeout=120s
fi
kc get service echo-api -n "$SANDBOX_NAMESPACE" >/dev/null 2>&1 ||
  kc expose pod echo-api -n "$SANDBOX_NAMESPACE" --port=80 --target-port=8080 --name=echo-api
echo "  echo-api Ready, reachable in-cluster at echo-api.$SANDBOX_NAMESPACE.svc.cluster.local:80"

# ---------------------------------------------------------------------------
# 10. Done
# ---------------------------------------------------------------------------

say "ready (10/10)"
cat <<EOF
  gateway namespace:    $GATEWAY_NAMESPACE
  sandbox namespace:    $SANDBOX_NAMESPACE
  credential namespace: $CREDENTIAL_NAMESPACE
  gateway release:      $GATEWAY_RELEASE (OpenShell $UPSTREAM_REF)
  workspace release:    $WORKSPACE_RELEASE
  run record:           $STATE_FILE

Next: reach the gateway and create a sandbox.
  kubectl -n $GATEWAY_NAMESPACE port-forward svc/$GATEWAY_RELEASE 8080:8080
  ./scripts/demo.sh
EOF
