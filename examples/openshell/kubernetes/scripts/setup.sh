#!/usr/bin/env bash
# setup.sh -- install OpenShell on this cluster as one release of its gateway chart,
# pinned to v0.1.6, with every workload pod it creates opting into a Nitro sandbox.
#
# Usage:
#   cp .env.example .env && $EDITOR .env   # optional; the defaults match the page
#   ./scripts/setup.sh
#
# What it does, in order:
#   1. checks the tools, the kube context, the agent-sandbox controller, network policy
#      enforcement and the MutatingAdmissionPolicy API;
#   2. creates the namespace when absent, and labels it -- the gateway and its sandboxes
#      both run there, the chart's default;
#   3. labels the isolated-sandbox RuntimeClass for OpenShell's resource admission, when
#      the label is not already there;
#   4. applies the admission adapter that fits OpenShell's generated workload pod to a
#      Nitro sandbox guest (deploy/nitro-adapter.yaml) -- a cluster-scoped object, limited
#      by its own namespaceSelector to namespaces labelled managed-by=<sample>;
#   5. downloads and verifies the pinned OpenShell CLI and gateway chart against
#      versions.json;
#   6. pins the gateway, supervisor and sandbox-runtime images by digest in the rendered
#      values, then installs the gateway chart and waits for the gateway;
#   7. checks that neither the sandbox ServiceAccount nor the namespace's default one can
#      read Secrets there, since the gateway's own client certificate lives there too;
#   8. starts the demo echo API this sample's policy and provider point at.
#
# It never changes a cluster-wide setting (network policy enforcement is checked, not
# turned on here -- see the page), never upgrades or reconfigures a shared install such
# as agent-sandbox, and never reuses a resource that is not this sample's: it stops
# instead, and says what it found.
#
# Overridable in .env (the defaults match the page):
#   KUBE_CONTEXT GATEWAY_NAMESPACE CREDENTIAL_NAMESPACE GATEWAY_RELEASE
#   WORKSPACE_STORAGE_CLASS
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
# The chart's default: one release creates its sandboxes in its own namespace.
SANDBOX_NAMESPACE="$GATEWAY_NAMESPACE"
CREDENTIAL_NAMESPACE="${CREDENTIAL_NAMESPACE:-openshell-kubernetes-credentials}"
GATEWAY_RELEASE="${GATEWAY_RELEASE:-openshell}"
# WORKSPACE_STORAGE_CLASS, when set, names a specific class for the workspace claim and
# overrides the choice; setup then checks that class's provisioner and that it
# reclaims its volumes on delete. When it is unset (the default), setup CHOOSES the
# class: the cluster's default class if exactly one fits (EBS CSI, gp3, encrypted,
# reclaimed on delete), otherwise the sample's own class.
WORKSPACE_STORAGE_CLASS="${WORKSPACE_STORAGE_CLASS:-}"
CHOSEN_STORAGE_CLASS=""
SAMPLE_STORAGE_CLASS="openshell-kubernetes-gp3"
# Set to 1 only when this run actually created the sample's own class.
CREATED_SAMPLE_STORAGE_CLASS=0
EBS_PROVISIONER="ebs.csi.eks.amazonaws.com"
# The reclaim policy the sample needs: the clean up deletes the claim and waits
# for its PV to be deleted, which only releases the EBS volume when the class
# reclaims it rather than retaining it.
EBS_RECLAIM_POLICY="Delete"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"
RUNTIME_CLASS="isolated-sandbox"
APPROVAL_LABEL="openshell.ai/sandbox-attachable"
ADAPTER="${SAMPLE}-nitro-adapter"
ECHO_IMAGE="docker.io/mccutchen/go-httpbin:v2.15.0"

say() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
kc() { if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi; }
# %q, not %s: the state file is sourced back by demo.sh and clean.sh, so a value holding
# a space or a shell metacharacter (such as a path under a home directory with a space in
# it) has to come back as the same string, not as a word the shell re-splits or runs.
state_put() { printf '%s=%q\n' "$1" "$2" >> "$STATE_FILE"; }

# sc_field <class> <jsonpath> : read one field of a StorageClass. Prints the value
# (empty when the field or the class is absent) and returns non-zero only when the
# read itself fails, so a caller can tell "absent" from "could not read".
sc_field() {
  local class=$1 path=$2 out rc=0
  out="$(kc get storageclass "$class" --ignore-not-found -o "jsonpath=$path" 2>/dev/null)" || rc=$?
  printf '%s' "$out"
  return $rc
}

# sc_fits <class> : does this class fit the sample? EBS CSI provisioner, type gp3
# (or unset, which is gp3), encrypted "true", and reclaimPolicy Delete so the
# clean up's PV delete really releases the EBS volume. A class with Retain would
# leave a volume billing after a clean up that reported success.
#   0 it fits   1 it does not   2 a read failed
sc_fits() {
  local class=$1 prov type enc reclaim rc=0
  prov="$(sc_field "$class" '{.provisioner}')" || rc=$?
  type="$(sc_field "$class" '{.parameters.type}')" || rc=$?
  enc="$(sc_field "$class" '{.parameters.encrypted}')" || rc=$?
  reclaim="$(sc_field "$class" '{.reclaimPolicy}')" || rc=$?
  [[ $rc -ne 0 ]] && return 2
  [[ "$prov" == "$EBS_PROVISIONER" ]] || return 1
  [[ -z "$type" || "$type" == "gp3" ]] || return 1
  [[ "$enc" == "true" ]] || return 1
  [[ "$reclaim" == "$EBS_RECLAIM_POLICY" ]] || return 1
  return 0
}

# sc_reclaims_on_delete <class> : the one check the clean up depends on, applied
# to a class the reader named in WORKSPACE_STORAGE_CLASS as well as to a default class.
#   0 it reclaims on delete   1 it does not   2 a read failed
sc_reclaims_on_delete() {
  local class=$1 reclaim rc=0
  reclaim="$(sc_field "$class" '{.reclaimPolicy}')" || rc=$?
  [[ $rc -ne 0 ]] && return 2
  [[ "$reclaim" == "$EBS_RECLAIM_POLICY" ]]
}

# choose_storage_class : decide which StorageClass the workspace claim names, and
# create the sample's own class only if needed. Sets CHOSEN_STORAGE_CLASS. A
# StorageClass is chosen, never changed: this never patches a class and never
# `kubectl apply`s one.
#
#   WORKSPACE_STORAGE_CLASS set   -> use it, after checking its provisioner is EBS CSI and
#                          that it reclaims its volumes on delete.
#   WORKSPACE_STORAGE_CLASS unset -> use the one default class that fits, if exactly one
#                          does; otherwise the sample's own class.
choose_storage_class() {
  if [[ -n "$WORKSPACE_STORAGE_CLASS" ]]; then
    if [[ "$WORKSPACE_STORAGE_CLASS" == "$SAMPLE_STORAGE_CLASS" ]]; then
      echo "WORKSPACE_STORAGE_CLASS names the sample's own class $SAMPLE_STORAGE_CLASS"
      ensure_sample_storage_class
      CHOSEN_STORAGE_CLASS="$SAMPLE_STORAGE_CLASS"
      return 0
    fi
    local prov rc=0
    prov="$(sc_field "$WORKSPACE_STORAGE_CLASS" '{.provisioner}')" || rc=$?
    [[ $rc -ne 0 ]] && die "could not read storageclass/$WORKSPACE_STORAGE_CLASS; stopping rather than guess (a failed read is not 'absent')"
    [[ -z "$prov" ]] && die "storageclass/$WORKSPACE_STORAGE_CLASS (from WORKSPACE_STORAGE_CLASS) not found. Set WORKSPACE_STORAGE_CLASS to a class that uses $EBS_PROVISIONER, or unset it to let setup choose."
    [[ "$prov" != "$EBS_PROVISIONER" ]] && die "storageclass/$WORKSPACE_STORAGE_CLASS (from WORKSPACE_STORAGE_CLASS) uses provisioner '$prov', not '$EBS_PROVISIONER'; its volumes are not EBS CSI volumes."
    # The clean up deletes the claim, waits for its PV to be deleted, and calls that
    # "the EBS volume is deleted". That is only true for a class that reclaims
    # its volumes on delete, so refuse a class where it would not be.
    local rrc=0; sc_reclaims_on_delete "$WORKSPACE_STORAGE_CLASS" || rrc=$?
    [[ $rrc -eq 2 ]] && die "could not read the reclaimPolicy of storageclass/$WORKSPACE_STORAGE_CLASS; stopping rather than guess"
    [[ $rrc -eq 1 ]] && die "storageclass/$WORKSPACE_STORAGE_CLASS (from WORKSPACE_STORAGE_CLASS) does not have reclaimPolicy $EBS_RECLAIM_POLICY, so deleting the claim would leave its EBS volume behind and the clean up could not report it gone. Set WORKSPACE_STORAGE_CLASS to a class with reclaimPolicy $EBS_RECLAIM_POLICY, or unset it to let setup choose."
    CHOSEN_STORAGE_CLASS="$WORKSPACE_STORAGE_CLASS"
    echo "using storageclass $CHOSEN_STORAGE_CLASS (from WORKSPACE_STORAGE_CLASS), provisioner $prov, reclaimPolicy $EBS_RECLAIM_POLICY"
    return 0
  fi

  local defaults rc=0
  defaults="$(kc get storageclass \
    -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && die "could not list StorageClasses; stopping rather than guess"

  local fitting=() name f
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    f=0; sc_fits "$name" || f=$?
    case $f in
      0) fitting+=("$name") ;;
      2) die "could not read the default storageclass/$name; stopping rather than guess" ;;
    esac
  done <<< "$defaults"

  if [[ ${#fitting[@]} -eq 1 ]]; then
    CHOSEN_STORAGE_CLASS="${fitting[0]}"
    echo "using the cluster default storageclass ${CHOSEN_STORAGE_CLASS} (it fits: $EBS_PROVISIONER, gp3, encrypted, reclaimPolicy $EBS_RECLAIM_POLICY); creating no class"
    return 0
  fi

  if [[ ${#fitting[@]} -gt 1 ]]; then
    echo "note: ${#fitting[@]} default StorageClasses fit; not guessing which. Using the sample's own class ${SAMPLE_STORAGE_CLASS}."
  else
    echo "note: no default StorageClass fits ($EBS_PROVISIONER, gp3, encrypted, reclaimPolicy $EBS_RECLAIM_POLICY). Using the sample's own class ${SAMPLE_STORAGE_CLASS}."
  fi
  ensure_sample_storage_class
  CHOSEN_STORAGE_CLASS="$SAMPLE_STORAGE_CLASS"
}

# ensure_sample_storage_class : make SAMPLE_STORAGE_CLASS available. Create it from
# the manifest with `kubectl create` only when absent; reuse an existing one only
# when it carries the sample's mark AND the right provisioner AND reclaims its
# volumes on delete; stop otherwise.
ensure_sample_storage_class() {
  local prov rc=0
  prov="$(sc_field "$SAMPLE_STORAGE_CLASS" '{.provisioner}')" || rc=$?
  [[ $rc -ne 0 ]] && die "could not read storageclass/$SAMPLE_STORAGE_CLASS; stopping rather than guess"
  if [[ -z "$prov" ]]; then
    echo "creating storageclass/$SAMPLE_STORAGE_CLASS from deploy/storage-class.yaml"
    kc create -f "$SAMPLE_DIR/deploy/storage-class.yaml" \
      || die "could not create storageclass/$SAMPLE_STORAGE_CLASS"
    CREATED_SAMPLE_STORAGE_CLASS=1
    return 0
  fi
  local mark mrc=0
  mark="$(sc_field "$SAMPLE_STORAGE_CLASS" '{.metadata.labels.app\.kubernetes\.io/managed-by}')" || mrc=$?
  [[ $mrc -ne 0 ]] && die "could not read the labels on storageclass/$SAMPLE_STORAGE_CLASS; stopping rather than guess"
  [[ "$mark" != "$SAMPLE" ]] && die "storageclass/$SAMPLE_STORAGE_CLASS already exists without the sample's mark (app.kubernetes.io/managed-by=$SAMPLE); it belongs to something else. Remove it or set WORKSPACE_STORAGE_CLASS to a class that uses $EBS_PROVISIONER."
  [[ "$prov" != "$EBS_PROVISIONER" ]] && die "storageclass/$SAMPLE_STORAGE_CLASS exists with provisioner '$prov', not '$EBS_PROVISIONER'; not reusing it."
  local rrc=0; sc_reclaims_on_delete "$SAMPLE_STORAGE_CLASS" || rrc=$?
  [[ $rrc -eq 2 ]] && die "could not read the reclaimPolicy of storageclass/$SAMPLE_STORAGE_CLASS; stopping rather than guess"
  [[ $rrc -eq 1 ]] && die "storageclass/$SAMPLE_STORAGE_CLASS exists without reclaimPolicy $EBS_RECLAIM_POLICY, so the clean up could not report its EBS volume gone; not reusing it. Remove it, or set WORKSPACE_STORAGE_CLASS to a class with reclaimPolicy $EBS_RECLAIM_POLICY."
  echo "reusing storageclass/$SAMPLE_STORAGE_CLASS (carries the sample's mark, provisioner $prov, reclaimPolicy $EBS_RECLAIM_POLICY)"
}

[[ "$CREDENTIAL_NAMESPACE" != "$GATEWAY_NAMESPACE" ]] ||
  die "CREDENTIAL_NAMESPACE and GATEWAY_NAMESPACE are both '$GATEWAY_NAMESPACE'; the credential must live in a namespace of its own. Set a different CREDENTIAL_NAMESPACE in .env."

: > "$STATE_FILE"
state_put SAMPLE "$SAMPLE"
state_put GATEWAY_NAMESPACE "$GATEWAY_NAMESPACE"
state_put SANDBOX_NAMESPACE "$SANDBOX_NAMESPACE"
state_put CREDENTIAL_NAMESPACE "$CREDENTIAL_NAMESPACE"
state_put GATEWAY_RELEASE "$GATEWAY_RELEASE"
state_put KUBE_CONTEXT "$KUBE_CONTEXT"
state_put GATEWAY_PORT "$GATEWAY_PORT"

jqr() { jq -r "$1" "$SAMPLE_DIR/versions.json"; }
GATEWAY_CHART_REF="$(jqr '.gateway_chart.ref')"
GATEWAY_CHART_VERSION="$(jqr '.gateway_chart.version')"
GATEWAY_CHART_SHA256="$(jqr '.gateway_chart.sha256')"
UPSTREAM_REF="$(jqr '.upstream_ref')"
CLI_ASSET="$(jqr '.cli_asset')"
CLI_SHA256="$(jqr '.cli_sha256')"
CLI="$LOCAL_DIR/openshell-$UPSTREAM_REF"
state_put CLI "$CLI"
state_put LOCAL_DIR "$LOCAL_DIR"

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------

say "checking tools and the cluster (1/8)"

for tool in kubectl helm jq curl openssl python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
python3 -c 'import yaml' 2>/dev/null ||
  die "python3's yaml module (PyYAML) is required. Install it, e.g. 'python3 -m pip install --user pyyaml', then re-run this script."

kc cluster-info >/dev/null 2>&1 || die "no reachable cluster for context '${KUBE_CONTEXT:-current}'"

kc get crd sandboxes.agents.x-k8s.io -o name >/dev/null 2>&1 ||
  die "the agent-sandbox controller is not on this cluster. Install it as Getting started > Warm pool does, then re-run this script:
  kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.10/sandbox-with-extensions.yaml"
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
# 2. The namespace
# ---------------------------------------------------------------------------

say "the namespace the gateway and its sandboxes run in (2/8)"

for ns in "$GATEWAY_NAMESPACE"; do
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
# 3. Choose the StorageClass
# ---------------------------------------------------------------------------

say "choosing the StorageClass for workspace PVCs (3/9)"

# Choose the StorageClass the workspace claim will name, before the gateway is
# installed. The sample's own class is the one thing this may create here, and the
# clean up removes it.
choose_storage_class

# ---------------------------------------------------------------------------
# 4. The RuntimeClass approval label
# ---------------------------------------------------------------------------

say "the isolated-sandbox RuntimeClass's OpenShell approval label (4/9)"

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
# 5. The admission adapter
# ---------------------------------------------------------------------------

say "the admission adapter that fits OpenShell's workload pod to a Nitro sandbox (5/9)"

# Two steps, not one: an object that exists but carries no managed-by label at all would
# print an empty label value, exactly what an absent object also prints. Checking
# existence first, then the label only when something is actually there, is what tells
# the two apart.
for kind in mutatingadmissionpolicy mutatingadmissionpolicybinding; do
  existing="$(kc get "$kind" "$ADAPTER" --ignore-not-found -o name 2>/dev/null)" ||
    die "could not determine whether the $kind $ADAPTER exists; created nothing"
  if [[ -n "$existing" ]]; then
    owner="$(kc get "$kind" "$ADAPTER" \
      -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)" ||
      die "could not read the managed-by label on the existing $kind $ADAPTER; created nothing"
    [[ "$owner" == "$SAMPLE" ]] ||
      die "the $kind $ADAPTER already exists and is not this sample's (managed-by='$owner'); created nothing."
  fi
done

sed -e "s|<ADAPTER_NAME>|$ADAPTER|g" -e "s|<MANAGED_BY>|$SAMPLE|g" \
  "$SAMPLE_DIR/deploy/nitro-adapter.yaml" > "$TMP_DIR/nitro-adapter.yaml"
kc apply -f "$TMP_DIR/nitro-adapter.yaml"
echo "  applied $ADAPTER, scoped to namespaces labelled managed-by=$SAMPLE"

# ---------------------------------------------------------------------------
# 6. The pinned CLI and chart
# ---------------------------------------------------------------------------

say "the pinned OpenShell CLI and gateway chart ($UPSTREAM_REF) (6/9)"

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

echo "  verified the gateway chart against its pinned checksum"
state_put GATEWAY_CHART "$GATEWAY_CHART"

# ---------------------------------------------------------------------------
# 7. The gateway chart
# ---------------------------------------------------------------------------

say "the OpenShell gateway (7/9)"

# The gateway chart's own credential-secrets-namespace.yaml creates the credential
# namespace as part of this install (server.credentialDrivers.kubernetesSecrets.
# createNamespace=true), and writes a Role into it granting the gateway's own
# ServiceAccount get/create on every Secret there, whether or not the namespace already
# existed with a different owner -- the chart's own template skips only re-creating the
# Namespace object itself, not the RBAC. So this has to be checked before the install
# runs, not after: by the time a check after the install found a foreign namespace, that
# Role would already be written into it.
if kc get ns "$CREDENTIAL_NAMESPACE" -o name >/dev/null 2>&1; then
  pre_owner="$(kc get ns "$CREDENTIAL_NAMESPACE" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}{"\n"}{.metadata.annotations.meta\.helm\.sh/release-name}{"\n"}{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null)" ||
    die "could not read the existing credential namespace $CREDENTIAL_NAMESPACE before installing the gateway; installed nothing"
  pre_label="$(sed -n 1p <<<"$pre_owner")"
  # The sample's mark, or -- after a run that stopped before relabelling it -- Helm's own
  # record that this release, in the namespace step 2 confirmed is the sample's, made it.
  [[ "$pre_label" == "$SAMPLE" ||
     ( "$pre_label" == "Helm" && "$(sed -n 2p <<<"$pre_owner")" == "$GATEWAY_RELEASE" &&
       "$(sed -n 3p <<<"$pre_owner")" == "$GATEWAY_NAMESPACE" ) ]] ||
    die "the credential namespace $CREDENTIAL_NAMESPACE already exists and is neither labelled as this sample's nor owned by its Helm release (managed-by='$pre_label'); refusing to install the gateway chart, which would write RBAC into it. Delete it, or set a new CREDENTIAL_NAMESPACE in .env."
fi

sed -e "s|<RELEASE>|$GATEWAY_RELEASE|g" \
    -e "s|<NAMESPACE>|$GATEWAY_NAMESPACE|g" \
    -e "s|<CREDENTIAL_NAMESPACE>|$CREDENTIAL_NAMESPACE|g" \
    -e "s|<WORKSPACE_STORAGE_CLASS>|$CHOSEN_STORAGE_CLASS|g" \
    -e "s|<DATA_STORAGE_CLASS>|$CHOSEN_STORAGE_CLASS|g" \
    "$SAMPLE_DIR/deploy/gateway-values.yaml" > "$TMP_DIR/gateway-values.yaml"

# The pinned digests go in here rather than in the committed values file, so the
# committed file carries no registry paths and versions.json stays the one place every
# pin lives. This is what actually makes "pinned by digest" in versions.json true of what
# gets installed, rather than merely true of what versions.json records.
GATEWAY_IMAGE="$(jqr '.images.gateway')"
SUPERVISOR_IMAGE="$(jqr '.images.supervisor')"
SANDBOX_RUNTIME_IMAGE="$(jqr '.images.sandbox_runtime')"
python3 - "$TMP_DIR/gateway-values.yaml" \
    "${GATEWAY_IMAGE#*@}" "${SANDBOX_RUNTIME_IMAGE#*@}" "${SUPERVISOR_IMAGE#*@}" <<'PY'
import re
import sys
import yaml

path, gateway_digest, sandbox_runtime_digest, supervisor_digest = sys.argv[1:5]
digest_re = re.compile(r"^sha256:[0-9a-f]{64}$")
for name, digest in (("gateway", gateway_digest), ("sandboxRuntime", sandbox_runtime_digest),
                      ("supervisor", supervisor_digest)):
    if not digest_re.match(digest):
        sys.exit(f"versions.json's {name} image is not a bare sha256:<64 hex> digest "
                  f"after the '@' (.images.{name} must be '<ref>@sha256:<64 hex>'): {digest!r}")
values = yaml.safe_load(open(path))
values.setdefault("gateway", {}).setdefault("image", {})["digest"] = gateway_digest
values.setdefault("sandboxRuntime", {}).setdefault("image", {})["digest"] = sandbox_runtime_digest
values.setdefault("supervisor", {}).setdefault("image", {})["digest"] = supervisor_digest
yaml.safe_dump(values, open(path, "w"))
PY
echo "  pinned the gateway, supervisor and sandbox-runtime images by digest"

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

# --force-conflicts: this script later relabels the chart-created credential namespace as
# the sample's (below), which takes over the managed-by field Helm renders on it, so a
# re-run's server-side apply would otherwise refuse with a field-manager conflict. Helm
# takes the field back here, and the relabel below puts the sample's mark back after.
helm upgrade --install "$GATEWAY_RELEASE" "$GATEWAY_CHART" --force-conflicts \
  ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"} \
  -n "$GATEWAY_NAMESPACE" -f "$TMP_DIR/gateway-values.yaml" --timeout 10m ||
  die "the OpenShell gateway chart did not install; 'helm status $GATEWAY_RELEASE -n $GATEWAY_NAMESPACE' says why"
kc rollout status statefulset/"$GATEWAY_RELEASE" -n "$GATEWAY_NAMESPACE" --timeout=5m ||
  die "the gateway did not reach Ready; 'kubectl get pods -n $GATEWAY_NAMESPACE' says why"

# ---------------------------------------------------------------------------
# 8. Who can read Secrets where the workload pods run
# ---------------------------------------------------------------------------

say "who can read Secrets in the namespace the workload pods run in (8/9)"

# The gateway's client-tls Secret is its own mTLS client certificate, and with
# server.auth.allowUnauthenticatedUsers: true it is full administrative access to the
# gateway -- see "Good to know" on the page. One release puts it in the same namespace
# the workload pods run in, so this checks that neither of those pods' own
# ServiceAccounts can read it there, rather than asserting it.
# "<release>-sandbox" is the chart's name for the workload pods' ServiceAccount
# (sandboxServiceAccount.create, with fullnameOverride set to the release). Check it exists,
# so a renamed account cannot pass the checks below by not being there; demo.sh then checks
# the workload pod really runs as it. Besides reading Secrets, creating a pod (which could
# mount one), exec into a pod and adding an ephemeral container are each a way to a Secret
# another pod mounts, so they are refused too.
SANDBOX_SA="$GATEWAY_RELEASE-sandbox"
kc get serviceaccount "$SANDBOX_SA" -n "$SANDBOX_NAMESPACE" -o name >/dev/null ||
  die "the chart's sandbox ServiceAccount $SANDBOX_SA is not in $SANDBOX_NAMESPACE, so the checks below would test an account no pod uses; refusing to continue."
state_put SANDBOX_SA "$SANDBOX_SA"
for sa in "$SANDBOX_SA" default; do
  # A subresource goes in --subresource: "pods/exec" would ask about a pod *named* exec,
  # and answers "no" even when exec is granted.
  for check in "get secrets" "list secrets" "watch secrets" "create pods" \
               "create pods --subresource=exec" "patch pods --subresource=ephemeralcontainers" \
               "update pods --subresource=ephemeralcontainers"; do
    # "kubectl auth can-i" exits non-zero for both "no" and a command failure (a bad
    # --as, an API error), so the exit code alone cannot tell the two apart. Read the
    # text it prints instead: anything other than exactly "yes" or "no" is "could not
    # determine", which this treats as a failure, never as "confirmed safe".
    # shellcheck disable=SC2086  # $check is "<verb> <resource>", split on purpose
    answer="$(kc auth can-i $check -n "$SANDBOX_NAMESPACE" \
      --as="system:serviceaccount:$SANDBOX_NAMESPACE:$sa" 2>&1)" || true
    case "$answer" in
      yes) die "the $sa ServiceAccount in $SANDBOX_NAMESPACE can $check there (kubectl auth can-i), a path to the gateway's own client-tls certificate; refusing to continue. Check what granted it." ;;
      no) ;;
      *) die "could not determine whether the $sa ServiceAccount in $SANDBOX_NAMESPACE can $check there ('kubectl auth can-i' answered '$answer', not yes or no); refusing to continue." ;;
    esac
  done
done
echo "  confirmed: neither $SANDBOX_SA nor the namespace's default ServiceAccount can read Secrets, create pods, exec into pods or add ephemeral containers in $SANDBOX_NAMESPACE"

# The gateway chart creates this namespace (server.credentialDrivers.kubernetesSecrets.
# createNamespace=true) and marks it as that Helm release's. Marking it as this sample's
# too is safe exactly because it is that release's: check the release annotations Helm
# itself put there, not a managed-by label, which a stale or unrelated label could already
# hold and which a bare "is there any label at all" check could mistake for "mine".
credential_ns_json="$(kc get ns "$CREDENTIAL_NAMESPACE" -o json)" ||
  die "could not read the credential namespace $CREDENTIAL_NAMESPACE, which the gateway chart should have created; labelled nothing"
credential_release="$(echo "$credential_ns_json" | python3 -I -c '
import json, sys
meta = json.load(sys.stdin)["metadata"].get("annotations", {})
print(meta.get("meta.helm.sh/release-name", ""))
print(meta.get("meta.helm.sh/release-namespace", ""))
')"
credential_release_name="$(echo "$credential_release" | sed -n 1p)"
credential_release_ns="$(echo "$credential_release" | sed -n 2p)"
if [[ "$credential_release_name" == "$GATEWAY_RELEASE" && "$credential_release_ns" == "$GATEWAY_NAMESPACE" ]]; then
  kc label namespace "$CREDENTIAL_NAMESPACE" "app.kubernetes.io/managed-by=$SAMPLE" --overwrite >/dev/null
  echo "  labelled the credential namespace $CREDENTIAL_NAMESPACE as this sample's"
else
  die "the credential namespace $CREDENTIAL_NAMESPACE exists but was not created by the release this run installed ($GATEWAY_RELEASE in $GATEWAY_NAMESPACE; found release='$credential_release_name' namespace='$credential_release_ns'); labelled nothing. If this is a leftover from an earlier run, delete it and re-run."
fi

# ---------------------------------------------------------------------------
# 9. The demo echo API
# ---------------------------------------------------------------------------

say "the demo echo API this sample's policy and provider point at (9/9)"

if kc get pod echo-api -n "$SANDBOX_NAMESPACE" >/dev/null 2>&1; then
  echo "  reusing the echo-api pod already in $SANDBOX_NAMESPACE"
else
  # Two labels, not one: "app=echo-api" is what the Service below selects on, and
  # "managed-by" is only for this sample's own ownership tracking. demo.sh's node-probe
  # pod carries that same managed-by label for the same tracking reason, and "kubectl
  # expose pod" (not used here, for exactly this reason) would have copied every one of
  # the pod's own labels into the Service's selector -- which would have matched
  # node-probe too, and did: an EndpointSlice with both pods behind this one Service,
  # found live on this sample's own cluster run, intermittently routing the credential
  # and refusal demos to a busybox pod with nothing listening on port 8080.
  kc run echo-api --image="$ECHO_IMAGE" --port=8080 -n "$SANDBOX_NAMESPACE" \
    --labels="app=echo-api,app.kubernetes.io/managed-by=$SAMPLE" --restart=Always
  kc wait pod/echo-api -n "$SANDBOX_NAMESPACE" --for=condition=Ready --timeout=120s
fi
kc get service echo-api -n "$SANDBOX_NAMESPACE" >/dev/null 2>&1 || kc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: echo-api
  namespace: $SANDBOX_NAMESPACE
  labels:
    app.kubernetes.io/managed-by: $SAMPLE
spec:
  selector:
    app: echo-api
  ports:
    - port: 80
      targetPort: 8080
EOF
echo "  echo-api Ready, reachable in-cluster at echo-api.$SANDBOX_NAMESPACE.svc.cluster.local:80"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

say "ready"
cat <<EOF
  namespace:            $GATEWAY_NAMESPACE (the gateway and its sandboxes)
  credential namespace: $CREDENTIAL_NAMESPACE
  release:              $GATEWAY_RELEASE (OpenShell $UPSTREAM_REF)
  run record:           $STATE_FILE

Next: reach the gateway and create a sandbox.
  kubectl -n $GATEWAY_NAMESPACE port-forward svc/$GATEWAY_RELEASE 8080:8080
  ./scripts/demo.sh
EOF
