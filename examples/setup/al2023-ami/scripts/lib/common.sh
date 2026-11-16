# common.sh: sourced by every al2023-ami script. Loads config.env, sets defaults, and provides
# logging, run-scope, ownership-tag and kubectl helpers. Sourced, never executed; never sets
# `set -e` (callers choose their own error discipline).
#
# This blueprint is simpler than ubuntu-ami: it builds the AL2023 AMI with the upstream
# amazon-eks-ami packer flow (no kernel build, no private runtime archive, no S3 staging bucket),
# so this lib keeps only the run-scoping, tagging, launch-spec and kube-context helpers.

SAMPLE_DIR="${SAMPLE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$SAMPLE_DIR/../../.." && pwd)}"

log()  { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# All local state lives under the repository's gitignored tmp/ (AGENTS.md), never in the sample
# folder. tmp/al2023-ami/run holds logs/ and out/.
: "${RUN_BASE_DIR:=$REPO_ROOT/tmp/al2023-ami/run}"
: "${LOG_DIR:=$RUN_BASE_DIR/logs}"
: "${OUT_DIR:=$RUN_BASE_DIR/out}"

# config.env is local and gitignored; config.env.example documents every variable.
[ -f "$SAMPLE_DIR/config.env" ] && . "$SAMPLE_DIR/config.env"

: "${AWS_REGION:=us-west-2}"
: "${CLUSTER_NAME:=sandbox-demo}"          # the home page's default; the shell's own value wins
: "${KUBERNETES_VERSION:=1.36}"
: "${RESOURCE_PREFIX:=al2023-ami}"
: "${NAMESPACE:=al2023-ami-sample}"
: "${JOIN_MODE:=both}"                      # nodegroup | karpenter | both
# Architecture: amd64 (x86_64) by default, or arm64 (Graviton). NODE_ARCH must match the AMI's
# architecture, which follows the instance the Packer build ran on, and the node instance type.
: "${NODE_ARCH:=amd64}"
case "$NODE_ARCH" in amd64|arm64) ;; *) die "NODE_ARCH must be amd64 or arm64, got '$NODE_ARCH'" ;; esac
# Enclave-capable instance types. The defaults are x86_64 (m8i); for NODE_ARCH=arm64 set these to
# an enclave-capable Graviton type and build the AMI on an arm64 enclave instance.
: "${NODE_INSTANCE_TYPE:=m8i.xlarge}"
: "${NODE_COUNT:=1}"
: "${TAGS_OWNER_KEY:=ManagedBy}"
: "${TAGS_OWNER_VALUE:=$RESOURCE_PREFIX}"
: "${TAGS_RUN_KEY:=RunId}"
# The node label the baked pod-isolation NodeConfig drop-in registers, which the sandbox
# RuntimeClasses select on. Read-only here: the AMI sets it, this blueprint only checks it.
: "${NODE_LABEL:=eks.amazonaws.com/nitro-sandbox=true}"
# The blueprint's own node taint, tolerated by its pods, so ordinary pods stay off these nodes.
: "${TAINT_KEY:=sandbox.blueprint/al2023-ami}"
: "${TAINT_VALUE:=true}"

mkdir -p "$LOG_DIR" "$OUT_DIR"

: "${RUN_STATE_FILE:=$OUT_DIR/run-state.env}"
valid_run_id() { [[ "${1:-}" =~ ^[a-z0-9]{1,20}$ ]]; }
new_run_id() {
  local r
  r=$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n') && [[ "$r" =~ ^[0-9a-f]{4}$ ]] || die "could not read /dev/urandom for a run id"
  printf '%s%s\n' "$(date -u +%Y%m%dt%H%M%Sz)" "$r"
}
load_run_id() {
  local v
  if [ -n "${RUN_ID:-}" ]; then valid_run_id "$RUN_ID" || die "RUN_ID '$RUN_ID' is not 1-20 lowercase letters/digits"; return 0; fi
  [ -f "$RUN_STATE_FILE" ] || return 1
  v=$(sed -n 's/^RUN_ID=//p' "$RUN_STATE_FILE" | tail -n 1)
  valid_run_id "$v" || die "run state $RUN_STATE_FILE has no valid RUN_ID line"
  RUN_ID=$v
}
require_name() {
  local kind="$1" name="$2" max="$3" rx="$4"
  [ "${#name}" -le "$max" ] || die "$kind name '$name' is ${#name} chars; limit $max. Shorten RESOURCE_PREFIX ($RESOURCE_PREFIX)."
  [[ "$name" =~ $rx ]] || die "$kind name '$name' has characters the API refuses (allowed: $rx). Change RESOURCE_PREFIX."
}
derive_run_names() {
  valid_run_id "${RUN_ID:-}" || die "derive_run_names: no valid RUN_ID"
  [[ "$RESOURCE_PREFIX" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "RESOURCE_PREFIX '$RESOURCE_PREFIX' must be lowercase letters, digits and hyphens"
  NODE_ROLE_NAME="${RESOURCE_PREFIX}-${RUN_ID}-node"
  LT_NAME="${RESOURCE_PREFIX}-${RUN_ID}-lt"
  NODEGROUP_NAME="${RESOURCE_PREFIX}-${RUN_ID}-ng"
  AMI_NAME="${RESOURCE_PREFIX}-${RUN_ID}"
  RUN_STATE_DIR="$OUT_DIR/runs/$RUN_ID"
  EVIDENCE_DIR="${EVIDENCE_DIR:-$RUN_STATE_DIR/evidence}"
  require_name "IAM role" "$NODE_ROLE_NAME" 64 '^[A-Za-z0-9+=,.@_-]+$'
  require_name "EC2 launch template" "$LT_NAME" 128 '^[A-Za-z0-9()./_-]{3,}$'
  require_name "EKS node group" "$NODEGROUP_NAME" 63 '^[A-Za-z0-9][A-Za-z0-9_-]*$'
  require_name "AMI" "$AMI_NAME" 128 '^[A-Za-z0-9()./_ -]{3,}$'
}
require_run_id() {
  load_run_id || die "no RUN_ID: no environment variable and no run state at $RUN_STATE_FILE. Pass RUN_ID=<id> or run ./setup.sh first."
  derive_run_names
}

# Tag helpers (ManagedBy + RunId on everything the blueprint creates).
run_tags_cli() { printf '{Key=%s,Value=%s},{Key=%s,Value=%s}' "$TAGS_OWNER_KEY" "$TAGS_OWNER_VALUE" "$TAGS_RUN_KEY" "$RUN_ID"; }
tags_match() {
  python3 -c '
import json, sys
t = json.load(sys.stdin)
if isinstance(t, list): t = {x.get("Key"): x.get("Value") for x in t}
sys.exit(0 if isinstance(t, dict) and t.get(sys.argv[1]) == sys.argv[2] and t.get(sys.argv[3]) == sys.argv[4] else 1)
' "$TAGS_OWNER_KEY" "$TAGS_OWNER_VALUE" "$TAGS_RUN_KEY" "$RUN_ID"
}
json_get() {
  python3 -c '
import json, sys
d = json.load(sys.stdin); r = eval(sys.argv[1], {"d": d})
if r is None: pass
elif isinstance(r, (list, tuple)):
    for x in r: print("\t".join(map(str, x)) if isinstance(x, (list, tuple)) else x)
else: print(r)
' "$1"
}
# launch_spec render-lt|check-lt: launch_spec.py with this run's tags (EnclaveOptions on,
# IMDSv2 hop-limit-1, ManagedBy+RunId on instance and volume).
launch_spec() {
  local cmd="$1"; shift
  python3 "$SAMPLE_DIR/scripts/lib/launch_spec.py" "$cmd" "$@" \
    --owner-key "$TAGS_OWNER_KEY" --owner-value "$TAGS_OWNER_VALUE" --run-key "$TAGS_RUN_KEY" --run-id "$RUN_ID"
}

# --- The cluster kubectl talks to ----------------------------------------------------------------
kc() {
  [ -n "${KUBE_CONTEXT:-}" ] || { printf 'FATAL: KUBE_CONTEXT is not set; set it to the kubectl context of cluster %s\n' "$CLUSTER_NAME" >&2; return 2; }
  kubectl --context "$KUBE_CONTEXT" "$@"
}
require_kube_context() {
  local err server endpoint s e msg
  [ -n "${KUBE_CONTEXT:-}" ] || die "KUBE_CONTEXT is not set. Set it to the kubectl context of cluster $CLUSTER_NAME; this blueprint never falls back to the current context and never runs 'kubectl config use-context'."
  err=$(mktemp)
  if ! server=$(kubectl --context "$KUBE_CONTEXT" config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>"$err"); then
    msg=$(head -n 2 "$err"); rm -f "$err"; die "could not read kube context '$KUBE_CONTEXT': $msg"
  fi
  [ -n "$server" ] || { rm -f "$err"; die "kube context '$KUBE_CONTEXT' names no cluster server"; }
  if ! endpoint=$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --output json 2>"$err" | json_get 'd["cluster"]["endpoint"]') || [ -z "$endpoint" ]; then
    msg=$(head -n 2 "$err"); rm -f "$err"; die "could not read the API endpoint of cluster $CLUSTER_NAME: $msg"
  fi
  rm -f "$err"
  s=$(printf '%s' "$server" | tr 'A-Z' 'a-z' | sed -e 's#/*$##' -e 's#^\(https://[^/]*\):443$#\1#')
  e=$(printf '%s' "$endpoint" | tr 'A-Z' 'a-z' | sed -e 's#/*$##' -e 's#^\(https://[^/]*\):443$#\1#')
  [ "$s" = "$e" ] || die "kube context '$KUBE_CONTEXT' points at $server, but cluster $CLUSTER_NAME's API endpoint is $endpoint; refusing to act on a different cluster than the AWS calls use"
  log "kube context $KUBE_CONTEXT is cluster $CLUSTER_NAME ($endpoint)"
}
