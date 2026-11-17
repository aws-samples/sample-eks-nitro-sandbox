#!/usr/bin/env bash
# Shared settings, readings and guards for the temporal sample's scripts.
# Sourced, never run on its own.
#
# Every kubectl call goes through kc(), which pins --context and --namespace, so
# a run never depends on the machine's current context (on a shared cluster
# another session can change it) or on a default namespace. Cluster-scoped reads
# go through kc_cluster, and reads of the shared Temporal server's namespace go
# through kc_temporal, which only ever reads.
set -euo pipefail

SAMPLE=temporal

# The sample's own object names, all inside the sample's own namespace.
# shellcheck disable=SC2034  # used by the scripts that source this file
WORKER=temporal-sandbox-worker   # the Deployment, ServiceAccount, Role and binding
# shellcheck disable=SC2034  # used by the scripts that source this file
PREFLIGHT_POD=temporal-preflight # the one-shot pod that reads the Temporal server

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR="$(cd "$HERE/.." && pwd)"

# grep and sed are checked here, before .env is read, rather than left to
# require_commands below. The parser pipes through both inside a process
# substitution, where a failure does not trip `set -e`: a missing grep would
# leave .env unread, and the run would then use the default names and whatever
# context the machine happens to be on. Every other missing command fails the
# run; this one would have changed which cluster was targeted.
for _c in grep sed; do
  command -v "$_c" >/dev/null 2>&1 \
    || { echo "error: missing required command: $_c, which is needed to read .env; refusing to fall back to default names and the machine's current context" >&2; exit 1; }
done

_ENV_KEYS='AWS_REGION|KUBE_CONTEXT|NAMESPACE|ECR_REPOSITORY|IMAGE_TAG|STORAGE_CLASS|TEMPORAL_K8S_NAMESPACE|TEMPORAL_RELEASE|TEMPORAL_NAMESPACE|TASK_QUEUE|SANDBOX_NAME|SUSPENDED_SECONDS'
# A .env that exists but cannot be read would be parsed as an empty file,
# because the grep below runs inside a process substitution where its failure
# does not trip `set -e`. The run would then quietly use the default names and
# whatever context the machine happens to be on, which is the one failure here
# that changes which cluster is targeted.
if [[ -f "$SAMPLE_DIR/.env" && ! -r "$SAMPLE_DIR/.env" ]]; then
  echo "error: $SAMPLE_DIR/.env exists but is not readable, so it would be parsed as empty and the run would fall back to the default names and the machine's current context. Fix its permissions and re-run." >&2
  exit 1
fi
if [[ -f "$SAMPLE_DIR/.env" ]]; then
  while IFS='=' read -r _k _v; do
    case "$_k" in
      AWS_REGION)             AWS_REGION="${AWS_REGION:-$_v}" ;;
      KUBE_CONTEXT)           KUBE_CONTEXT="${KUBE_CONTEXT:-$_v}" ;;
      NAMESPACE)              NAMESPACE="${NAMESPACE:-$_v}" ;;
      ECR_REPOSITORY)         ECR_REPOSITORY="${ECR_REPOSITORY:-$_v}" ;;
      IMAGE_TAG)              IMAGE_TAG="${IMAGE_TAG:-$_v}" ;;
      STORAGE_CLASS)          STORAGE_CLASS="${STORAGE_CLASS:-$_v}" ;;
      TEMPORAL_K8S_NAMESPACE) TEMPORAL_K8S_NAMESPACE="${TEMPORAL_K8S_NAMESPACE:-$_v}" ;;
      TEMPORAL_RELEASE)       TEMPORAL_RELEASE="${TEMPORAL_RELEASE:-$_v}" ;;
      TEMPORAL_NAMESPACE)     TEMPORAL_NAMESPACE="${TEMPORAL_NAMESPACE:-$_v}" ;;
      TASK_QUEUE)             TASK_QUEUE="${TASK_QUEUE:-$_v}" ;;
      SANDBOX_NAME)           SANDBOX_NAME="${SANDBOX_NAME:-$_v}" ;;
      SUSPENDED_SECONDS)      SUSPENDED_SECONDS="${SUSPENDED_SECONDS:-$_v}" ;;
    esac
  done < <(grep -E "^[[:space:]]*($_ENV_KEYS)[[:space:]]*=" "$SAMPLE_DIR/.env" \
             | sed -E 's/^[[:space:]]*//; s/[[:space:]]*=[[:space:]]*/=/')
fi

AWS_REGION="${AWS_REGION:-us-west-2}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
NAMESPACE="${NAMESPACE:-temporal-sandboxes}"
ECR_REPOSITORY="${ECR_REPOSITORY:-temporal-sandbox-worker}"
IMAGE_TAG="${IMAGE_TAG:-}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
# Where the shared Temporal server is, and under what Helm release name, which
# is what its Service names are derived from.
TEMPORAL_K8S_NAMESPACE="${TEMPORAL_K8S_NAMESPACE:-temporal}"
TEMPORAL_RELEASE="${TEMPORAL_RELEASE:-temporal}"
# The Temporal namespace the runs land in, and the task queue the Worker polls.
TEMPORAL_NAMESPACE="${TEMPORAL_NAMESPACE:-nitro-sandbox}"
TASK_QUEUE="${TASK_QUEUE:-nitro-sandbox-lifecycle}"
SANDBOX_NAME="${SANDBOX_NAME:-lifecycle}"
SUSPENDED_SECONDS="${SUSPENDED_SECONDS:-120}"

TEMPORAL_FRONTEND_SVC="${TEMPORAL_RELEASE}-frontend"
TEMPORAL_WEB_SVC="${TEMPORAL_RELEASE}-web"
# shellcheck disable=SC2034  # used by the scripts that source this file
TEMPORAL_ADDRESS="${TEMPORAL_FRONTEND_SVC}.${TEMPORAL_K8S_NAMESPACE}.svc:7233"

# The sample's own EBS StorageClass, created only when no fitting default class
# exists, and removed by the clean up.
SAMPLE_STORAGE_CLASS="temporal-sandboxes-gp3"
EBS_PROVISIONER="ebs.csi.eks.amazonaws.com"
CHOSEN_STORAGE_CLASS=""

# The versions this sample was built against. The scripts never install any of
# them: they are shared installs, and the page has the reader install them.
AGENT_SANDBOX_VERSION=v1.0.10
TEMPORAL_CHART_VERSION=1.7.0

# Each of these goes into `sed s/__X__/value/`, where a `/`, a `&` or a `\`
# would quietly produce a different manifest from the one you asked for. The
# namespace and the sandbox name can only be DNS labels anyway, and the rest are
# names of the same shape, so requiring that costs nothing and keeps every
# substitution safe.
for _pair in "NAMESPACE=$NAMESPACE" "SANDBOX_NAME=$SANDBOX_NAME" \
             "TEMPORAL_K8S_NAMESPACE=$TEMPORAL_K8S_NAMESPACE" \
             "TEMPORAL_RELEASE=$TEMPORAL_RELEASE" \
             "TEMPORAL_NAMESPACE=$TEMPORAL_NAMESPACE" \
             "TASK_QUEUE=$TASK_QUEUE"; do
  _name="${_pair%%=*}"; _value="${_pair#*=}"
  [[ "$_value" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || {
    echo "error: $_name must be a DNS label (lower-case letters, digits and dashes, starting and ending alphanumeric, at most 63 characters); got '$_value'" >&2
    exit 1
  }
done
[[ "$SUSPENDED_SECONDS" =~ ^[0-9]+$ ]] \
  || { echo "error: SUSPENDED_SECONDS must be a whole number of seconds; got '$SUSPENDED_SECONDS'" >&2; exit 1; }

kc() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" "$@"
  else
    kubectl --namespace "$NAMESPACE" "$@"
  fi
}
kc_cluster() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    kubectl --context "$KUBE_CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}
# kc_temporal: reads of the shared Temporal server's namespace. Every use of
# this is a get; nothing in this sample applies, patches or deletes anything in
# the Temporal server's namespace.
kc_temporal() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    kubectl --context "$KUBE_CONTEXT" --namespace "$TEMPORAL_K8S_NAMESPACE" "$@"
  else
    kubectl --namespace "$TEMPORAL_K8S_NAMESPACE" "$@"
  fi
}

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }

require_commands() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
}

# Print which cluster the run is pinned to, so a shared machine's current
# context can never be mistaken for the one you meant.
show_context() {
  local ctx
  ctx="$(kc_cluster config current-context 2>/dev/null || true)"
  if [[ -n "$KUBE_CONTEXT" ]]; then
    echo "context: $KUBE_CONTEXT (pinned)   namespace: $NAMESPACE   region: $AWS_REGION"
  else
    echo "context: ${ctx:-<none>} (current; set KUBE_CONTEXT in .env to pin it)   namespace: $NAMESPACE   region: $AWS_REGION"
  fi
}

# ---------------------------------------------------------------------------
# What is the sample's, and what is not.
#
# In the cluster, the label on the sample's own namespace is the mark: a script
# reuses or deletes the namespace, or anything inside it, only when the label is
# there. In AWS, the ManagedBy tag is the mark. A read that fails means "could
# not determine", which is a failure, never "gone" and never "not ours".
# ---------------------------------------------------------------------------
NS_LABEL_KEY="app.kubernetes.io/managed-by"
NS_LABEL_VAL="$SAMPLE"
# shellcheck disable=SC2034  # used by the scripts that source this file
MANAGED_BY="$SAMPLE"

# namespace_is_ours return codes, so callers can tell the cases apart:
#   0  it exists and carries our label  (the sample's)
#   1  it exists and does not           (someone else's)
#   2  it exists but could not be read  (could not tell)
#   3  it does not exist
namespace_is_ours() {
  local out rc
  local key_esc="${NS_LABEL_KEY//./\\.}"   # dots in a label key are escaped in jsonpath
  out="$(kc_cluster get namespace "$NAMESPACE" --ignore-not-found \
    -o "jsonpath={.metadata.labels.${key_esc}}{\"|\"}{.metadata.name}" 2>/dev/null)"
  rc=$?
  [[ $rc -ne 0 ]] && return 2
  [[ "$out" == "|" || -z "$out" ]] && return 3   # --ignore-not-found printed nothing
  local label="${out%%|*}"
  [[ "$label" == "$NS_LABEL_VAL" ]]
}

# require_our_namespace : stop unless this sample owns the namespace, so no
# mutating script ever touches a same-named object in a namespace that belongs
# to something else. A failed read stops the run too.
require_our_namespace() {
  local rc=0
  namespace_is_ours || rc=$?
  case $rc in
    0) return 0 ;;
    1) die "namespace $NAMESPACE exists but is not labelled $NS_LABEL_KEY=$NS_LABEL_VAL; it belongs to something else. Set NAMESPACE in .env to the one you ran ./scripts/setup.sh with." ;;
    2) die "could not read namespace $NAMESPACE; stopping rather than act on a namespace I cannot verify" ;;
    3) die "namespace $NAMESPACE does not exist; run ./scripts/setup.sh first" ;;
  esac
}

# resource_exists <runner> <kind/name...> : a failure-aware existence check, so
# a failed read is never mistaken for "absent".
#   0  it exists    1  it does not    2  the read failed
resource_exists() {
  local runner=$1; shift
  local out rc
  out="$("$runner" get "$@" --ignore-not-found -o name 2>/dev/null)"
  rc=$?
  [[ $rc -ne 0 ]] && return 2
  [[ -n "$out" ]]
}

# ---------------------------------------------------------------------------
# The shared installs, checked and never changed.
# ---------------------------------------------------------------------------

require_runtime_class() {
  local rc=0
  resource_exists kc_cluster runtimeclass isolated-sandbox || rc=$?
  case $rc in
    0) : ;;
    1) die "runtimeclass isolated-sandbox is not on this cluster. Run the Hello sandbox sample first." ;;
    2) die "could not read the cluster's runtime classes, so whether isolated-sandbox is there could not be determined; stopping rather than guess" ;;
  esac
}

agent_sandbox_install_command() {
  cat <<EOF
  kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/$AGENT_SANDBOX_VERSION/sandbox-with-extensions.yaml
  kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller
EOF
}

# require_agent_sandbox : the Sandbox CRD and a controller that reconciles it.
# agent-sandbox is a shared install: this only reads, and the page has the
# reader install it at the pinned version when it is absent.
require_agent_sandbox() {
  local rc=0
  resource_exists kc_cluster crd sandboxes.agents.x-k8s.io || rc=$?
  case $rc in
    0) : ;;
    1) die "the agent-sandbox Sandbox CRD (sandboxes.agents.x-k8s.io) is not installed. This sample needs it, and it is a shared install, so install it yourself at the pinned version rather than having this script do it:
$(agent_sandbox_install_command)" ;;
    2) die "could not read the cluster's CRDs, so whether agent-sandbox is installed could not be determined; stopping rather than guess" ;;
  esac
  # The CRD ships unconditionally with the release manifest, so its presence
  # does not prove anything reconciles it. A Sandbox with no controller never
  # gets a pod, and the workflow's provision activity would wait out its whole
  # timeout for a sandbox nothing was ever going to create.
  local avail arc=0
  avail="$(kc_cluster -n agent-sandbox-system get deploy agent-sandbox-controller \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" || arc=$?
  [[ $arc -ne 0 ]] && die "the agent-sandbox CRD is installed but deploy/agent-sandbox-controller could not be read in namespace agent-sandbox-system; stopping rather than create a Sandbox nothing would act on"
  [[ "$avail" == "True" ]] || die "deploy/agent-sandbox-controller in namespace agent-sandbox-system is not Available (condition: ${avail:-<none>}), so nothing would act on a Sandbox. Check it with: kubectl -n agent-sandbox-system get deploy,pods"
  local ver
  ver="$(kc_cluster -n agent-sandbox-system get deploy agent-sandbox-controller \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  echo "reusing the agent-sandbox install as it is (${ver:-image unreadable}); this sample was built against $AGENT_SANDBOX_VERSION"
}

temporal_install_command() {
  cat <<EOF
  kubectl create namespace $TEMPORAL_K8S_NAMESPACE
  openssl rand -base64 24 | tr -d '\n' \\
    | kubectl -n $TEMPORAL_K8S_NAMESPACE create secret generic temporal-postgresql --from-file=password=/dev/stdin
  kubectl -n $TEMPORAL_K8S_NAMESPACE apply -f deploy/temporal/postgresql.yaml
  kubectl -n $TEMPORAL_K8S_NAMESPACE rollout status statefulset/temporal-postgresql
  helm repo add temporal https://go.temporal.io/helm-charts && helm repo update temporal
  helm install $TEMPORAL_RELEASE temporal/temporal --version $TEMPORAL_CHART_VERSION \\
    --namespace $TEMPORAL_K8S_NAMESPACE -f deploy/temporal/values.yaml --timeout 15m --wait
EOF
}

# require_temporal_server : the shared Temporal server, checked from the
# Kubernetes side only. Three readings, each failing closed:
#
#   1. the frontend Service exists in TEMPORAL_K8S_NAMESPACE;
#   2. it has at least one ready endpoint address, which is what shows a pod is
#      actually behind it rather than a Service left over from a failed install;
#   3. the Web UI Service exists, because the page has you port-forward it.
#
# Whether the Temporal NAMESPACE the sample needs exists is a question for the
# server itself, not for Kubernetes, so setup.sh asks it separately with the
# preflight pod. A Temporal server is a shared install: nothing here installs,
# upgrades or reconfigures it.
require_temporal_server() {
  local rc=0
  resource_exists kc_temporal service "$TEMPORAL_FRONTEND_SVC" || rc=$?
  case $rc in
    0) : ;;
    1) die "no service/$TEMPORAL_FRONTEND_SVC in namespace $TEMPORAL_K8S_NAMESPACE, so there is no Temporal server for the Worker to connect to. A Temporal server is a shared install, so install it yourself rather than having this script do it:
$(temporal_install_command)
If yours is installed elsewhere or under another release name, set TEMPORAL_K8S_NAMESPACE and TEMPORAL_RELEASE in .env." ;;
    2) die "could not read service/$TEMPORAL_FRONTEND_SVC in namespace $TEMPORAL_K8S_NAMESPACE, so whether a Temporal server is there could not be determined; stopping rather than guess" ;;
  esac

  # EndpointSlice, not Endpoints: Endpoints is deprecated and on a cluster that
  # has stopped serving it the read would fail, which this would then report as
  # a server that is not ready rather than as a reading it could not take.
  local addrs arc=0
  addrs="$(kc_temporal get endpointslice -l "kubernetes.io/service-name=$TEMPORAL_FRONTEND_SVC" \
    -o jsonpath='{range .items[*]}{range .endpoints[?(@.conditions.ready==true)]}{.addresses[0]}{" "}{end}{end}' 2>/dev/null)" || arc=$?
  [[ $arc -ne 0 ]] && die "could not read the endpoints of service/$TEMPORAL_FRONTEND_SVC in namespace $TEMPORAL_K8S_NAMESPACE, so whether the Temporal frontend is serving could not be determined; stopping rather than guess"
  [[ -n "${addrs// /}" ]] || die "service/$TEMPORAL_FRONTEND_SVC in namespace $TEMPORAL_K8S_NAMESPACE has no ready endpoint, so the Temporal frontend is not serving. Check it with: kubectl -n $TEMPORAL_K8S_NAMESPACE get pods"

  local wrc=0
  resource_exists kc_temporal service "$TEMPORAL_WEB_SVC" || wrc=$?
  case $wrc in
    0) : ;;
    1) die "service/$TEMPORAL_WEB_SVC is not in namespace $TEMPORAL_K8S_NAMESPACE. The Temporal server is there but its Web UI is not, and the page's steps port-forward it. That is a server set up differently from what this sample needs, so this script stops rather than change a shared install: install the Web UI (web.enabled: true), or re-run with a server that has it." ;;
    2) die "could not read service/$TEMPORAL_WEB_SVC in namespace $TEMPORAL_K8S_NAMESPACE; stopping rather than guess" ;;
  esac

  local ver
  ver="$(kc_temporal get deploy "${TEMPORAL_RELEASE}-frontend" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  echo "reusing the Temporal server in namespace $TEMPORAL_K8S_NAMESPACE as it is (${ver:-frontend image unreadable}); this sample was built against chart $TEMPORAL_CHART_VERSION"
}

# ---------------------------------------------------------------------------
# The StorageClass the workspace claim names. Chosen, never changed.
# ---------------------------------------------------------------------------

# sc_field <class> <jsonpath> : one field of a StorageClass. Prints the value,
# empty when the field or the class is absent, and returns non-zero only when
# the read itself failed, so a caller can tell "absent" from "could not read".
sc_field() {
  local class=$1 path=$2 out rc=0
  out="$(kc_cluster get storageclass "$class" --ignore-not-found -o "jsonpath=$path" 2>/dev/null)" || rc=$?
  printf '%s' "$out"
  return $rc
}

# sc_fits <class> : EBS CSI provisioner, type gp3 (or unset, which is gp3), and
# encrypted "true".  0 fits  1 does not  2 a read failed. Never a fit on a
# failed read.
sc_fits() {
  local class=$1 prov type enc rc=0
  prov="$(sc_field "$class" '{.provisioner}')" || rc=$?
  type="$(sc_field "$class" '{.parameters.type}')" || rc=$?
  enc="$(sc_field "$class" '{.parameters.encrypted}')" || rc=$?
  [[ $rc -ne 0 ]] && return 2
  [[ "$prov" == "$EBS_PROVISIONER" ]] || return 1
  [[ -z "$type" || "$type" == "gp3" ]] || return 1
  [[ "$enc" == "true" ]] || return 1
  return 0
}

# choose_storage_class : decide which class the workspace claim names and set
# CHOSEN_STORAGE_CLASS. Never patches a class and never `kubectl apply`s one,
# which on a class created with apply would strip its default annotation and
# change how every other claim on the cluster is provisioned.
choose_storage_class() {
  if [[ -n "$STORAGE_CLASS" ]]; then
    if [[ "$STORAGE_CLASS" == "$SAMPLE_STORAGE_CLASS" ]]; then
      echo "STORAGE_CLASS names the sample's own class $SAMPLE_STORAGE_CLASS"
      ensure_sample_storage_class
      CHOSEN_STORAGE_CLASS="$SAMPLE_STORAGE_CLASS"
      return 0
    fi
    local prov rc=0
    prov="$(sc_field "$STORAGE_CLASS" '{.provisioner}')" || rc=$?
    [[ $rc -ne 0 ]] && die "could not read storageclass/$STORAGE_CLASS; stopping rather than guess (a failed read is not 'absent')"
    [[ -z "$prov" ]] && die "storageclass/$STORAGE_CLASS (from STORAGE_CLASS) not found. Set it to a class that uses $EBS_PROVISIONER, or unset it to let setup choose."
    [[ "$prov" != "$EBS_PROVISIONER" ]] && die "storageclass/$STORAGE_CLASS (from STORAGE_CLASS) uses provisioner '$prov', not '$EBS_PROVISIONER'; its volumes are not EBS CSI volumes."
    CHOSEN_STORAGE_CLASS="$STORAGE_CLASS"
    echo "using storageclass $CHOSEN_STORAGE_CLASS (from STORAGE_CLASS), provisioner $prov"
    return 0
  fi

  local defaults rc=0
  defaults="$(kc_cluster get storageclass \
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
    echo "using the cluster default storageclass ${CHOSEN_STORAGE_CLASS} (it fits: $EBS_PROVISIONER, gp3, encrypted); creating no class"
    return 0
  fi
  if [[ ${#fitting[@]} -gt 1 ]]; then
    echo "note: ${#fitting[@]} default StorageClasses fit; not guessing which. Using the sample's own class ${SAMPLE_STORAGE_CLASS}."
  else
    echo "note: no default StorageClass fits ($EBS_PROVISIONER, gp3, encrypted). Using the sample's own class ${SAMPLE_STORAGE_CLASS}."
  fi
  ensure_sample_storage_class
  CHOSEN_STORAGE_CLASS="$SAMPLE_STORAGE_CLASS"
}

# ensure_sample_storage_class : create the sample's own class from the manifest
# with `kubectl create` only when absent; reuse an existing one only when it
# carries the sample's mark and the right provisioner; stop otherwise.
ensure_sample_storage_class() {
  local prov rc=0
  prov="$(sc_field "$SAMPLE_STORAGE_CLASS" '{.provisioner}')" || rc=$?
  [[ $rc -ne 0 ]] && die "could not read storageclass/$SAMPLE_STORAGE_CLASS; stopping rather than guess"
  if [[ -z "$prov" ]]; then
    echo "creating storageclass/$SAMPLE_STORAGE_CLASS from deploy/storage-class.yaml"
    kc_cluster create -f "$SAMPLE_DIR/deploy/storage-class.yaml" \
      || die "could not create storageclass/$SAMPLE_STORAGE_CLASS"
    return 0
  fi
  local mark mrc=0
  mark="$(sc_field "$SAMPLE_STORAGE_CLASS" '{.metadata.labels.app\.kubernetes\.io/managed-by}')" || mrc=$?
  [[ $mrc -ne 0 ]] && die "could not read the labels on storageclass/$SAMPLE_STORAGE_CLASS; stopping rather than guess"
  [[ "$mark" != "$SAMPLE" ]] && die "storageclass/$SAMPLE_STORAGE_CLASS already exists without the sample's mark ($NS_LABEL_KEY=$SAMPLE); it belongs to something else. Remove it or set STORAGE_CLASS to a class that uses $EBS_PROVISIONER."
  [[ "$prov" != "$EBS_PROVISIONER" ]] && die "storageclass/$SAMPLE_STORAGE_CLASS exists with provisioner '$prov', not '$EBS_PROVISIONER'; not reusing it."
  echo "reusing storageclass/$SAMPLE_STORAGE_CLASS (carries the sample's mark, provisioner $prov)"
}

# ---------------------------------------------------------------------------
# AWS reads, with three outcomes. A call that fails with the service's own
# not-found code means absent; one that succeeds means present; any other
# failure means could not determine, which is never read as absent or as gone.
# ---------------------------------------------------------------------------
AWS_LAST_ERROR=""
AWS_CLEAN_FAIL=0

# aws_matched_not_found <code> <output> : did the CLI report exactly this error
# code? The code is matched inside the CLI's own error framing, "An error
# occurred (<Code>) when calling ...", and not anywhere in the output. An
# unanchored search for the bare code would also match the code appearing inside
# a resource name echoed back in some other error, so an AccessDenied on a
# repository whose name contained the code would have read as "absent".
aws_matched_not_found() {
  local code=$1 out=$2
  grep -Fq "An error occurred ($code) when calling" <<<"$out"
}

# aws_exists <not-found-code> -- <command...>
#   0  it exists
#   1  it is genuinely absent  (the service said so)
#   2  could not determine     (denied, throttled, no network, anything else)
aws_exists() {
  local code=$1; shift
  [[ "$1" == "--" ]] && shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  [[ $rc -eq 0 ]] && return 0
  aws_matched_not_found "$code" "$out" && return 1
# shellcheck disable=SC2034  # used by the scripts that source this file
  AWS_LAST_ERROR="$(tr '\n' ' ' <<<"$out")"
  return 2
}

# aws_verify_absent "<what>" <not-found-code> -- <command...> : for the clean up.
# Prints what it found and counts an incomplete result, so a clean up never
# reports a resource gone on a read that did not answer.
aws_verify_absent() {
  local what=$1 code=$2; shift 2
  [[ "$1" == "--" ]] && shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "  INCOMPLETE: $what is still present" >&2
    AWS_CLEAN_FAIL=$((AWS_CLEAN_FAIL + 1))
    return 1
  fi
  if aws_matched_not_found "$code" "$out"; then
    echo "  $what is gone"
    return 0
  fi
  echo "  INCOMPLETE: could not determine whether $what is gone: $(tr '\n' ' ' <<<"$out")" >&2
  AWS_CLEAN_FAIL=$((AWS_CLEAN_FAIL + 1))
  return 1
}

# ---------------------------------------------------------------------------
# Assertions, for the scripts that check a claim the page makes.
# ---------------------------------------------------------------------------
ASSERT_PASS=0
ASSERT_TOTAL=0
assert() {
  local rc=$1; shift
  ASSERT_TOTAL=$((ASSERT_TOTAL + 1))
  if [[ "$rc" -eq 0 ]]; then
    ASSERT_PASS=$((ASSERT_PASS + 1))
    echo "  PASS  $*"
  else
    echo "  FAIL  $*" >&2
  fi
}
assert_summary() {
  echo
  echo "$ASSERT_PASS/$ASSERT_TOTAL checks passed: $*"
  [[ "$ASSERT_PASS" -eq "$ASSERT_TOTAL" ]]
}
