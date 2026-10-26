#!/usr/bin/env bash
# Shared settings, readings and guards for the brain-and-hands scripts. Sourced,
# never run on its own.
#
# Every kubectl call goes through kc(), which pins --context and --namespace, so
# a run never depends on the machine's current context (on a shared cluster
# another session can change it) or on a default namespace. Cluster-scoped reads
# go through kc_cluster.
set -euo pipefail

SAMPLE=brain-and-hands

# The sample's own object names, all inside the sample's own namespace.
TEMPLATE=hands
POOL=hands-pool
BRAIN=brain                 # the Deployment, the ServiceAccount, the Role and its binding
SESSION_CLAIM=brain-session # the claim the brain's sandbox tool creates at run time

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

# Load .env as defaults. A value already set in the environment wins over the
# file, so `NAMESPACE=other ./scripts/setup.sh` overrides it.
_ENV_KEYS='CLUSTER_NAME|AWS_REGION|KUBE_CONTEXT|NAMESPACE|BEDROCK_MODEL_ID|ECR_REPOSITORY|POD_IDENTITY_ROLE_NAME'
# A .env that exists but cannot be read would be parsed as an empty file: the
# grep below runs inside a process substitution, where its failure does not trip
# `set -e`. The run would then quietly use the default names and whatever
# context the machine happens to be on, which is the one failure here that
# changes which cluster is targeted.
if [[ -f "$SAMPLE_DIR/.env" && ! -r "$SAMPLE_DIR/.env" ]]; then
  echo "error: $SAMPLE_DIR/.env exists but is not readable, so it would be parsed as empty and the run would fall back to the default names and the machine's current context. Fix its permissions and re-run." >&2
  exit 1
fi
if [[ -f "$SAMPLE_DIR/.env" ]]; then
  while IFS='=' read -r _k _v; do
    case "$_k" in
      CLUSTER_NAME)           CLUSTER_NAME="${CLUSTER_NAME:-$_v}" ;;
      AWS_REGION)             AWS_REGION="${AWS_REGION:-$_v}" ;;
      KUBE_CONTEXT)           KUBE_CONTEXT="${KUBE_CONTEXT:-$_v}" ;;
      NAMESPACE)              NAMESPACE="${NAMESPACE:-$_v}" ;;
      BEDROCK_MODEL_ID)       BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-$_v}" ;;
      ECR_REPOSITORY)         ECR_REPOSITORY="${ECR_REPOSITORY:-$_v}" ;;
      POD_IDENTITY_ROLE_NAME) POD_IDENTITY_ROLE_NAME="${POD_IDENTITY_ROLE_NAME:-$_v}" ;;
    esac
  done < <(grep -E "^[[:space:]]*($_ENV_KEYS)[[:space:]]*=" "$SAMPLE_DIR/.env" \
             | sed -E 's/^[[:space:]]*//; s/[[:space:]]*=[[:space:]]*/=/')
fi

CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-us-west-2}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
NAMESPACE="${NAMESPACE:-brain-and-hands}"
BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-us.anthropic.claude-sonnet-5-5}"
ECR_REPOSITORY="${ECR_REPOSITORY:-brain-and-hands}"
POD_IDENTITY_ROLE_NAME="${POD_IDENTITY_ROLE_NAME:-brain-and-hands-brain}"

# The namespace goes into `sed s|<NAMESPACE>|$NAMESPACE|`, where a `|`, a `&` or
# a `\` would quietly produce a different manifest from the one you asked for. A
# Kubernetes namespace can only be a DNS label anyway, so requiring that costs
# nothing and keeps the substitution safe.
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || {
  echo "error: NAMESPACE must be a DNS label (lower-case letters, digits and dashes, starting and ending alphanumeric, at most 63 characters); got '$NAMESPACE'" >&2
  exit 1
}

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
# The shared installs and the cluster-wide setting, checked and never changed.
# ---------------------------------------------------------------------------

# require_runtime_class : the Nitro sandbox runtime class. On EKS Auto Mode it
# is on every cluster; on standard EKS the nodes need a sandbox-enabled AMI.
require_runtime_class() {
  local rc=0
  resource_exists kc_cluster runtimeclass isolated-sandbox || rc=$?
  case $rc in
    0) : ;;
    1) die "runtimeclass isolated-sandbox is not on this cluster. Run the Hello sandbox sample first." ;;
    2) die "could not read the cluster's runtime classes, so whether isolated-sandbox is there could not be determined; stopping rather than guess" ;;
  esac
}

# require_agent_sandbox : the three agent-sandbox extension CRDs this sample
# uses. agent-sandbox is a shared install: this only reads, and the page has the
# reader install it at the pinned version when it is absent.
AGENT_SANDBOX_VERSION=v1.0.6
agent_sandbox_install_command() {
  cat <<EOF
  kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/$AGENT_SANDBOX_VERSION/sandbox-with-extensions.yaml
  kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller
EOF
}
require_agent_sandbox() {
  local crd rc
  for crd in sandboxtemplates.extensions.agents.x-k8s.io \
             sandboxwarmpools.extensions.agents.x-k8s.io \
             sandboxclaims.extensions.agents.x-k8s.io; do
    rc=0; resource_exists kc_cluster crd "$crd" || rc=$?
    case $rc in
      0) : ;;
      1) die "the agent-sandbox CRD $crd is not installed. This sample needs it, and it is a shared install, so install it yourself at the pinned version rather than having this script do it:
$(agent_sandbox_install_command)" ;;
      2) die "could not read the cluster's CRDs, so whether agent-sandbox is installed could not be determined; stopping rather than guess" ;;
    esac
  done
  # The CRDs ship unconditionally with the chart, so their presence does not
  # prove anything reconciles them. A pool with no controller never fills.
  local avail arc=0
  avail="$(kc_cluster -n agent-sandbox-system get deploy agent-sandbox-controller \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" || arc=$?
  [[ $arc -ne 0 ]] && die "the agent-sandbox CRDs are installed but deploy/agent-sandbox-controller could not be read in namespace agent-sandbox-system; stopping rather than create a warm pool nothing would fill"
  [[ "$avail" == "True" ]] || die "deploy/agent-sandbox-controller in namespace agent-sandbox-system is not Available (condition: ${avail:-<none>}), so nothing would act on a SandboxWarmPool. Check it with: kubectl -n agent-sandbox-system get deploy,pods"
  local ver
  ver="$(kc_cluster -n agent-sandbox-system get deploy agent-sandbox-controller \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  echo "reusing the agent-sandbox install as it is (${ver:-image unreadable}); this sample was built against $AGENT_SANDBOX_VERSION"
}

# This sample ships no network policy. The hands boot with no network device, so
# there is nothing to restrict, and the brain's limits are its tool
# configuration, its Pod Identity role and its RBAC Role rather than anything on
# the wire. So nothing here reads or depends on the cluster-wide network policy
# enforcement setting. The network-policy sample under Isolation is where that
# mechanism is shown.

# ---------------------------------------------------------------------------
# Readings.
# ---------------------------------------------------------------------------

# pool_ready_replicas : how many warm pods the pool has ready. Prints the count,
# or nothing and returns non-zero when the read FAILED. An absent field is a
# real answer, none ready, and prints 0; a failed read is not.
pool_ready_replicas() {
  local v rc=0
  v="$(kc get sandboxwarmpool "$POOL" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && return 1
  printf '%s' "${v:-0}"
}

# wait_pool_warm <timeout-s> : wait until the pool's ready count meets its
# replicas. Both reads fail closed: a read that failed keeps the loop waiting
# rather than concluding the pool is warm.
wait_pool_warm() {
  local timeout=${1:-900} ready want rc
  local deadline=$((SECONDS + timeout))
  while :; do
    ready="$(pool_ready_replicas)" || ready=""
    rc=0
    want="$(kc get sandboxwarmpool "$POOL" -o jsonpath='{.spec.replicas}' 2>/dev/null)" || rc=$?
    [[ $rc -ne 0 ]] && want=""
    if [[ -n "$ready" && -n "$want" && "$ready" == "$want" && "$ready" != "0" ]]; then
      return 0
    fi
    printf '  readyReplicas=%s/%s\n' "${ready:-?}" "${want:-?}"
    ((SECONDS >= deadline)) && return 1
    sleep 5
  done
}

# ---------------------------------------------------------------------------
# AWS teardown verification, with three outcomes. A describe that fails with
# "not found" means gone; one that succeeds means still there; any other failure
# means could not determine, which is never read as deleted.
# ---------------------------------------------------------------------------
# aws_exists <not-found-pattern> -- <command...> : does this AWS resource exist?
#   0  it exists
#   1  it is genuinely absent  (the service said so: the error matched the pattern)
#   2  could not determine     (any other failure: denied, throttled, no network)
#
# The distinction is the whole point. `aws iam get-role >/dev/null 2>&1` fails the
# same way for "no such role" as it does for AccessDenied, a throttle or a
# broken connection, so reading its exit status alone turns every one of those
# into "absent". In the clean up that means reporting a role gone that is still
# there; in setup it means trying to create one on top of a read that never
# answered. Both scripts go through here instead.
aws_exists() {
  local pattern=$1; shift
  [[ "$1" == "--" ]] && shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  [[ $rc -eq 0 ]] && return 0
  grep -q "$pattern" <<<"$out" && return 1
  AWS_LAST_ERROR="$(tr '\n' ' ' <<<"$out")"
  return 2
}
AWS_LAST_ERROR=""

AWS_CLEAN_FAIL=0
# aws_verify_absent "<what>" <not-found-pattern> -- <command...>
aws_verify_absent() {
  local what=$1 pattern=$2; shift 2
  [[ "$1" == "--" ]] && shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "  INCOMPLETE: $what is still present" >&2
    AWS_CLEAN_FAIL=$((AWS_CLEAN_FAIL + 1))
    return 1
  fi
  if grep -q "$pattern" <<<"$out"; then
    echo "  $what is gone"
    return 0
  fi
  echo "  INCOMPLETE: could not determine whether $what is gone: $(tr '\n' ' ' <<<"$out")" >&2
  AWS_CLEAN_FAIL=$((AWS_CLEAN_FAIL + 1))
  return 1
}
