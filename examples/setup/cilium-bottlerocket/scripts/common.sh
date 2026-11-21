# shellcheck shell=bash source-path=SCRIPTDIR
# Shared by setup.sh, test.sh, clean.sh and the AMI build scripts. Source it after you set
# SAMPLE_DIR. It is sourced, never run.
#
# It reads config.env.example (tracked defaults), then config.local.env (gitignored, wins),
# holds the pins, the run folder and state file helpers, the tag helpers, the kube context
# pin, and the pass/fail tallies. On load it makes no AWS or kubectl call and writes nothing
# outside CB_RUN_DIR. Each refusal prints one line, "ERROR: E_<TAG>: <text>", and exits 1.

[[ -n "${SAMPLE_DIR:-}" && -f "$SAMPLE_DIR/config.env.example" ]] \
  || { echo "ERROR: E_SAMPLE_DIR: set SAMPLE_DIR to the sample folder before you source scripts/common.sh" >&2; exit 1; }

# die <E_TAG> <text>: the stable refusal line, then exit 1.
die() {
  local tag="${1:-}"
  if [[ "$tag" =~ ^E_[A-Z0-9_]+$ ]]; then shift; else tag=E_UNTAGGED; fi
  printf 'ERROR: %s: %s\n' "$tag" "$*" >&2
  exit 1
}
warn() { printf 'WARN: %s\n' "$*" >&2; }
log()  { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
step() { printf '\n=== %s ===\n' "$*"; }

# The repository root, from git or from the folder above that holds AGENTS.md.
cb_repo_root() {
  local root dir
  if root="$(git -C "$SAMPLE_DIR" rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$root" ]]; then
    printf '%s\n' "$root"; return 0
  fi
  dir="$SAMPLE_DIR"
  while [[ "$dir" != "/" ]]; do
    [[ -e "$dir/AGENTS.md" ]] && { printf '%s\n' "$dir"; return 0; }
    dir="$(dirname "$dir")"
  done
  return 1
}
REPO_ROOT="$(cb_repo_root)" || die E_REPO_ROOT "could not find the repository root above $SAMPLE_DIR"
# shellcheck source=../../../../scripts/lib/require-bash.sh
. "$REPO_ROOT/scripts/lib/require-bash.sh"

canon_path() { realpath -m -- "$1"; }
# path_within <path> <base>: 0 when <path> is <base> or below it, by whole path components.
path_within() { [[ "$1" == "$2" || "$1/" == "$2"/* ]]; }
TMP_ROOT="$(canon_path "$REPO_ROOT/tmp")"

# Configuration. The local file must be the sample's config.local.env or a file under tmp/.
# shellcheck source=../config.env.example
source "$SAMPLE_DIR/config.env.example"
CB_LOCAL_CONFIG="$(canon_path "${CB_LOCAL_CONFIG:-$SAMPLE_DIR/config.local.env}")"
if [[ "$CB_LOCAL_CONFIG" != "$(canon_path "$SAMPLE_DIR/config.local.env")" ]] \
  && ! path_within "$CB_LOCAL_CONFIG" "$TMP_ROOT"; then
  die E_LOCAL_CONFIG "CB_LOCAL_CONFIG=$CB_LOCAL_CONFIG is not $SAMPLE_DIR/config.local.env and not under $TMP_ROOT"
fi
if [[ -f "$CB_LOCAL_CONFIG" ]]; then
  # shellcheck source=/dev/null
  source "$CB_LOCAL_CONFIG"
fi
export AWS_ACCOUNT_ID AWS_REGION CLUSTER_NAME AVAILABILITY_ZONES SYSTEM_INSTANCE_TYPE \
  SANDBOX_INSTANCE_TYPE BUILD_INSTANCE_TYPE BUILD_WORK_VOLUME_GIB AMI_WAIT_SECONDS SANDBOX_SLOTS \
  SYSTEM_MAX_PODS SYSTEM_DATA_VOLUME_GIB SANDBOX_DATA_VOLUME_GIB SYSTEM_AMI_ID REUSE_SANDBOX_AMI_ID \
  CB_LOCAL_CONFIG REPO_ROOT SAMPLE_DIR

# Pins. The README Versions table states the same values.
KUBERNETES_VERSION=1.36
BOTTLEROCKET_RELEASE=v1.70.0
BOTTLEROCKET_VERSION=1.70.0
SYSTEM_AMI_NAME=bottlerocket-aws-k8s-1.36-x86_64-v1.70.0-59b0684a
SYSTEM_AMI_SSM_PARAMETER=/aws/service/bottlerocket/aws-k8s-1.36/x86_64/1.70.0/image_id
SANDBOX_VARIANT=aws-k8s-1.36-nitro-sandbox
EKSCTL_MIN_VERSION=0.230.0
HELM_VERSION=v3.19.0
# The image of every pod in deploy/ and of the node probe pods: busybox 1.37.0 from the Amazon
# ECR Public mirror of the Docker official image, pinned to the digest of its image index.
BUSYBOX_IMAGE=public.ecr.aws/docker/library/busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec
CRI_PROXY_ENDPOINT=unix:///run/nitro-sandbox/cri-proxy.sock
SHIM_PATH=/usr/bin/containerd-shim-nitro-sandbox-v2
NAMESPACE=cilium-bottlerocket-demo
NS_LABEL_KEY=app.kubernetes.io/part-of
NS_LABEL_VAL=cilium-bottlerocket-sample
SANDBOX_TAINT_KEY=sandbox.eks-nitro-sandbox.amazonaws.com/dedicated
OWNER_TAG_KEY=ManagedBy
OWNER_TAG_VALUE=cilium-bottlerocket-sample
RUN_TAG_KEY=RunId
INTERFACE_VERSION=cluster-v3.1
PY="$SAMPLE_DIR/scripts/cilium_bottlerocket.py"
export INTERFACE_VERSION KUBERNETES_VERSION BOTTLEROCKET_RELEASE BOTTLEROCKET_VERSION SYSTEM_AMI_NAME \
  SYSTEM_AMI_SSM_PARAMETER SANDBOX_VARIANT BUSYBOX_IMAGE CRI_PROXY_ENDPOINT SHIM_PATH NAMESPACE \
  NS_LABEL_KEY NS_LABEL_VAL SANDBOX_TAINT_KEY OWNER_TAG_KEY OWNER_TAG_VALUE RUN_TAG_KEY

# read_cilium_version <lock file>: the one CILIUM_VERSION line of cilium.lock.
read_cilium_version() {
  local f="${1:-}" line
  [[ -f "$f" && -r "$f" ]] || die E_CILIUM_LOCK "$f: the Cilium lock file is missing or unreadable"
  line="$(grep -E '^CILIUM_VERSION=' "$f")" || die E_CILIUM_LOCK "$f: the Cilium lock file has no CILIUM_VERSION line"
  [[ "$line" != *$'\n'* ]] || die E_CILIUM_LOCK "$f: the Cilium lock file has more than one CILIUM_VERSION line"
  [[ "$line" =~ ^CILIUM_VERSION=([0-9]+\.[0-9]+\.[0-9]+)$ ]] \
    || die E_CILIUM_LOCK "$f: the Cilium lock file has a malformed version line '$line'"
  printf '%s\n' "${BASH_REMATCH[1]}"
}
read_cilium_chart() {
  local f="${1:-}" line
  line="$(grep -E '^CILIUM_CHART=' "$f")" || die E_CILIUM_LOCK "$f: the Cilium lock file has no CILIUM_CHART line"
  [[ "$line" != *$'\n'* && "$line" =~ ^CILIUM_CHART=(oci://[a-z0-9./-]+)$ ]] \
    || die E_CILIUM_LOCK "$f: malformed or repeated CILIUM_CHART line"
  printf '%s\n' "${BASH_REMATCH[1]}"
}
CILIUM_VERSION="$(read_cilium_version "$SAMPLE_DIR/cilium.lock")" || exit 1
CILIUM_CHART="$(read_cilium_chart "$SAMPLE_DIR/cilium.lock")" || exit 1
export CILIUM_VERSION CILIUM_CHART

# The run folder root, under the repository's gitignored tmp/ only.
CB_RUN_DIR="$(canon_path "${CB_RUN_DIR:-$REPO_ROOT/tmp/cilium-bottlerocket/run}")"
path_within "$CB_RUN_DIR" "$TMP_ROOT" && [[ "$CB_RUN_DIR" != "$TMP_ROOT" ]] \
  || die E_RUN_DIR "CB_RUN_DIR=$CB_RUN_DIR is not under $TMP_ROOT; local state stays in the repository's tmp/"
# private_dirs <dir>...: create each folder, mode 700.
private_dirs() { mkdir -p "$@" && chmod 700 "$@"; }
private_dirs "$CB_RUN_DIR" || die E_RUN_DIR "could not create $CB_RUN_DIR"
export CB_RUN_DIR

require_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die E_TOOL_MISSING "$cmd is required but was not found on PATH"
  done
}

# version_at_least <have> <want>: dotted numeric comparison.
version_at_least() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

require_tool_versions() {
  local out minor
  require_commands aws eksctl helm kubectl python3
  out="$(aws --version 2>&1)" || die E_TOOL_AWS "could not read the aws CLI version"
  [[ "$out" =~ ^aws-cli/2\.[0-9]+\.[0-9]+ ]] || die E_TOOL_AWS "aws CLI v2 is required (got '${out%%$'\n'*}')"
  out="$(eksctl version 2>/dev/null | head -n1)"; out="${out#v}"
  [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die E_TOOL_EKSCTL "could not read the eksctl version (got '$out')"
  version_at_least "$out" "$EKSCTL_MIN_VERSION" \
    || die E_TOOL_EKSCTL "eksctl $out is too old; this sample needs $EKSCTL_MIN_VERSION or later"
  out="$(helm version --short 2>/dev/null)"
  [[ "$out" =~ ^v3\.19\.0(\+.*)?$ ]] || die E_TOOL_HELM "helm ${out:-<unreadable>} is not $HELM_VERSION; install helm $HELM_VERSION"
  out="$(kubectl version --client -o json 2>/dev/null)" || die E_TOOL_KUBECTL "could not read the kubectl version"
  minor="$(python3 -c 'import json,sys; v=json.load(sys.stdin)["clientVersion"]; print(v["major"]+"."+v["minor"].rstrip("+"))' <<<"$out" 2>/dev/null)" \
    || die E_TOOL_KUBECTL "could not read the kubectl version"
  [[ "$minor" =~ ^1\.3[5-7]$ ]] \
    || die E_TOOL_KUBECTL "kubectl $minor is outside 1.35 to 1.37, the versions that Kubernetes $KUBERNETES_VERSION supports"
  python3 -c 'import yaml' 2>/dev/null || die E_TOOL_PYYAML "python3 needs PyYAML (pip install pyyaml)"
}

require_region() {
  [[ "$AWS_REGION" == "us-west-2" ]] || die E_REGION "AWS_REGION=$AWS_REGION is not us-west-2, the only Region this sample is tested in"
}

# The caller must be in AWS_ACCOUNT_ID, so a wrong profile cannot create or delete anything.
require_caller_account() {
  local out account arn
  [[ "${AWS_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]] || die E_ACCOUNT "AWS_ACCOUNT_ID is not set in config.local.env"
  out="$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>/dev/null)" \
    || die E_ACCOUNT "no AWS credentials: aws sts get-caller-identity failed"
  read -r account arn <<<"$out"
  echo "Caller: $arn"
  [[ "$account" == "$AWS_ACCOUNT_ID" ]] || die E_ACCOUNT "the caller is in account $account, not AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID; refusing"
}
require_account() { require_caller_account; }

# ---- Run ID, run folder and state file ----
valid_run_id() { [[ "${1:-}" =~ ^[a-z0-9]{1,20}$ ]]; }
new_run_id() {
  local r
  r="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')" && [[ "$r" =~ ^[0-9a-f]{4}$ ]] || die E_RUN_ID "could not read /dev/urandom"
  printf '%s%s\n' "$(date -u +%Y%m%dt%H%M%Sz)" "$r"
}
set_run_paths() {
  RUN_STATE_DIR="$CB_RUN_DIR/runs/$RUN_ID"
  RUN_STATE_FILE="$RUN_STATE_DIR/state.env"
  EVIDENCE_DIR="$RUN_STATE_DIR/evidence"
  KUBECONFIG="$RUN_STATE_DIR/kubeconfig"
  export RUN_ID RUN_STATE_DIR RUN_STATE_FILE EVIDENCE_DIR KUBECONFIG
}
# require_name <kind> <name> <max-length> <regex>: refuse a derived name that the API would
# refuse, before any call uses it.
require_name() {
  local kind="$1" name="$2" max="$3" rx="$4"
  ((${#name} <= max)) || die E_NAME_LIMIT "$kind name '$name' is ${#name} characters; the limit is $max. Use a shorter CLUSTER_NAME."
  [[ "$name" =~ $rx ]] || die E_NAME_LIMIT "$kind name '$name' has characters that the API refuses (allowed: $rx)"
}
# derive_names: every per-run name, from CLUSTER_NAME and RUN_ID, checked against the API limits.
# The AMI lane, check-names and clean.sh use these names; none derives its own.
derive_names() {
  [[ "$CLUSTER_NAME" =~ ^[a-z][a-z0-9-]{2,31}$ ]] \
    || die E_NAME "CLUSTER_NAME '$CLUSTER_NAME' must be 3 to 32 lowercase letters, digits and hyphens, starting with a letter"
  valid_run_id "${RUN_ID:-}" || die E_RUN_ID "derive_names: no valid RUN_ID"
  OPERATOR_ROLE_NAME="$CLUSTER_NAME-cilium-operator"
  SYSTEM_LT_NAME="$CLUSTER_NAME-$RUN_ID-system"
  SANDBOX_LT_NAME="$CLUSTER_NAME-$RUN_ID-sandbox"
  SYSTEM_NODEGROUP=system
  SANDBOX_NODEGROUP=sandbox
  BUILDER_NAME="$CLUSTER_NAME-$RUN_ID-builder"
  BUILDER_ROLE_NAME="$CLUSTER_NAME-$RUN_ID-builder"
  BUILDER_PROFILE_NAME="$CLUSTER_NAME-$RUN_ID-builder"
  BUILDER_SG_NAME="$CLUSTER_NAME-$RUN_ID-builder"
  AMI_NAME="$CLUSTER_NAME-$RUN_ID-aws-k8s-1.36-nitro-sandbox"
  KUBE_CONTEXT="cb-$RUN_ID"
  local iam='^[A-Za-z0-9+=,.@_-]+$'
  require_name "IAM role" "$OPERATOR_ROLE_NAME" 64 "$iam"
  require_name "IAM role" "$BUILDER_ROLE_NAME" 64 "$iam"
  require_name "IAM instance profile" "$BUILDER_PROFILE_NAME" 64 "$iam"
  require_name "EC2 launch template" "$SYSTEM_LT_NAME" 128 '^[A-Za-z0-9()./_-]{3,}$'
  require_name "EC2 launch template" "$SANDBOX_LT_NAME" 128 '^[A-Za-z0-9()./_-]{3,}$'
  require_name "EC2 security group" "$BUILDER_SG_NAME" 255 '^[A-Za-z0-9._-]+$'
  require_name "EC2 instance Name tag" "$BUILDER_NAME" 255 '^[A-Za-z0-9._-]+$'
  require_name "AMI" "$AMI_NAME" 128 '^[A-Za-z0-9()./_-]{3,}$'
  export OPERATOR_ROLE_NAME SYSTEM_LT_NAME SANDBOX_LT_NAME SYSTEM_NODEGROUP SANDBOX_NODEGROUP \
    BUILDER_NAME BUILDER_ROLE_NAME BUILDER_PROFILE_NAME BUILDER_SG_NAME AMI_NAME KUBE_CONTEXT
}
RUN_RECORD_KEYS="RUN_ID CLUSTER_NAME AWS_REGION"
# reserve_run: a new RUN_ID and its own folder. mkdir without -p fails when the folder exists.
reserve_run() {
  RUN_ID="$(new_run_id)" || exit 1
  set_run_paths
  private_dirs "$CB_RUN_DIR/runs" || die E_RUN_DIR "could not create $CB_RUN_DIR/runs"
  mkdir -m 700 "$RUN_STATE_DIR" 2>/dev/null || die E_RUN_DIR "run folder $RUN_STATE_DIR already exists; start again for a new run ID"
  mkdir -m 700 "$EVIDENCE_DIR" "$RUN_STATE_DIR/logs" || die E_RUN_DIR "could not create the run folders"
  derive_names
  local k
  for k in $RUN_RECORD_KEYS INTERFACE_VERSION; do state_set "$k" "${!k}"; done
  printf '%s\n' "$RUN_ID" > "$CB_RUN_DIR/current-run" || die E_RUN_DIR "could not write $CB_RUN_DIR/current-run"
}
# load_run: RUN_ID from the environment, else from current-run. 0 found, 1 none.
load_run() {
  local v
  if [[ -n "${RUN_ID:-}" ]]; then
    valid_run_id "$RUN_ID" || die E_RUN_ID "RUN_ID '$RUN_ID' is not 1 to 20 lowercase letters and digits"
  else
    [[ -f "$CB_RUN_DIR/current-run" ]] || return 1
    v="$(head -n1 "$CB_RUN_DIR/current-run")"
    valid_run_id "$v" || die E_RUN_ID "$CB_RUN_DIR/current-run holds no valid run ID"
    RUN_ID="$v"
  fi
  set_run_paths
}
require_run_id() {
  load_run || die E_RUN_ID "no RUN_ID: set RUN_ID=<id> or run ./setup.sh first"
  [[ -d "$RUN_STATE_DIR" ]] || die E_RUN_ID "run $RUN_ID has no folder at $RUN_STATE_DIR"
  private_dirs "$EVIDENCE_DIR" "$RUN_STATE_DIR/logs" || die E_RUN_DIR "could not create the run folders"
  derive_names
}
check_run_record() {
  local k got rc
  for k in $RUN_RECORD_KEYS; do
    rc=0; got="$(state_get "$k")" || rc=$?
    ((rc == 0)) || die E_RUN_RECORD "could not read the record of run $RUN_ID at $RUN_STATE_FILE"
    [[ "$got" == "${!k}" ]] || die E_RUN_RECORD "run $RUN_ID's record has $k=$got, but this run has $k=${!k}; refusing"
  done
}
# lock_run: an exclusive lock on run.lock for the life of this process (fd 9).
lock_run() {
  local f="$RUN_STATE_DIR/run.lock" rc=0
  exec 9>>"$f" || die E_RUN_LOCK "could not open the run lock $f"
  python3 -c 'import errno, fcntl, sys
try:
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError as e:
    sys.exit(3 if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES) else 4)' || rc=$?
  ((rc != 3)) || die E_RUN_LOCK "run $RUN_ID is in use: another process holds $f"
  ((rc == 0)) || die E_RUN_LOCK "could not lock $f"
}
# state_set <KEY> <VALUE>: one line per key, written atomically (temp file, then rename).
state_set() {
  local key="$1" value="$2" tmp rc=0
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die E_STATE "state_set: bad key '$key'"
  [[ "$value" != *$'\n'* ]] || die E_STATE "state_set: the value of $key has a line break"
  [[ -n "${RUN_STATE_FILE:-}" ]] || die E_STATE "state_set: no run is loaded"
  tmp="$(mktemp "$RUN_STATE_FILE.XXXXXX")" || die E_STATE "could not write $RUN_STATE_FILE"
  if [[ -f "$RUN_STATE_FILE" ]]; then
    grep -v "^$key=" "$RUN_STATE_FILE" >"$tmp" || rc=$?
    ((rc <= 1)) || { rm -f "$tmp"; die E_STATE "could not read $RUN_STATE_FILE"; }
  fi
  if ! { printf '%s=%s\n' "$key" "$value" >>"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$RUN_STATE_FILE"; }; then
    rm -f "$tmp"
    die E_STATE "could not write $RUN_STATE_FILE"
  fi
}
# state_get <KEY>: prints the value; prints nothing and returns 0 when the key is absent;
# returns 2 when the file cannot be read.
state_get() {
  local key="$1" out
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die E_STATE "state_get: bad key '$key'"
  [[ -n "${RUN_STATE_FILE:-}" && -r "$RUN_STATE_FILE" ]] || return 2
  out="$(sed -n "s/^$key=//p" "$RUN_STATE_FILE")" || return 2
  [[ -z "$out" ]] || printf '%s\n' "${out##*$'\n'}"
}
# state_need <KEY>: the value, or stop when it is absent or unreadable.
state_need() {
  local v rc=0
  v="$(state_get "$1")" || rc=$?
  ((rc == 0)) && [[ -n "$v" ]] || die E_STATE "run $RUN_ID has no $1 in $RUN_STATE_FILE; run ./setup.sh again with RUN_ID=$RUN_ID"
  printf '%s\n' "$v"
}

# ---- Tags ----
tag_args() { printf 'Key=%s,Value=%s Key=%s,Value=%s\n' "$OWNER_TAG_KEY" "$OWNER_TAG_VALUE" "$RUN_TAG_KEY" "$RUN_ID"; }
tag_spec() {
  printf 'ResourceType=%s,Tags=[{Key=%s,Value=%s},{Key=%s,Value=%s}]\n' "$1" \
    "$OWNER_TAG_KEY" "$OWNER_TAG_VALUE" "$RUN_TAG_KEY" "$RUN_ID"
}
# tags_match: stdin is a tag list ([{"Key":..,"Value":..}]) or a map. 0 ours, 1 not, 2 unreadable.
tags_match() {
  python3 -c 'import json, os, sys
try:
    t = json.load(sys.stdin)
    if isinstance(t, list):
        t = {x["Key"]: x["Value"] for x in t}
    if not isinstance(t, dict):
        raise ValueError
except (ValueError, KeyError, TypeError):
    sys.exit(2)
want = {os.environ["OWNER_TAG_KEY"]: os.environ["OWNER_TAG_VALUE"], os.environ["RUN_TAG_KEY"]: os.environ["RUN_ID"]}
sys.exit(0 if all(t.get(k) == v for k, v in want.items()) else 1)'
}

# ---- Cluster and kube context ----
kc() { kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" "$@"; }
hc() { helm --kubeconfig "$KUBECONFIG" --kube-context "$KUBE_CONTEXT" "$@"; }
require_kube_context() {
  local endpoint server
  endpoint="$(state_need CLUSTER_ENDPOINT)" || exit 1
  [[ -f "$KUBECONFIG" ]] || die E_KUBE_CONTEXT "the kubeconfig $KUBECONFIG does not exist; run ./setup.sh with RUN_ID=$RUN_ID"
  server="$(kubectl --kubeconfig "$KUBECONFIG" config view --minify --context "$KUBE_CONTEXT" \
    -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null)" || server=""
  [[ -n "$server" && "$server" == "$endpoint" ]] \
    || die E_KUBE_CONTEXT "the kubeconfig $KUBECONFIG does not hold context $KUBE_CONTEXT for $endpoint (got '${server:-none}')"
}
# cluster_state: the EKS cluster status, or NONE when it does not exist. Any other read
# failure stops the script, so a clean up never reads a failure as "already gone".
cluster_state() {
  local out rc=0
  out="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" \
    --query cluster.status --output text 2>&1)" || rc=$?
  if ((rc == 0)); then
    printf '%s\n' "$out"
  elif grep -Eq '^(aws: \[ERROR\]: )?An error occurred \(ResourceNotFoundException\)' <<<"$out"; then
    printf 'NONE\n'
  else
    die E_CLUSTER_READ "could not read cluster $CLUSTER_NAME: $out"
  fi
}
require_sample_cluster() {
  local tags rc=0
  tags="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --query cluster.tags --output json)" \
    || die E_CLUSTER_READ "could not read the tags of cluster $CLUSTER_NAME"
  tags_match <<<"$tags" || rc=$?
  ((rc == 0)) || die E_CLUSTER_OWNER "cluster $CLUSTER_NAME exists but is not tagged $OWNER_TAG_KEY=$OWNER_TAG_VALUE $RUN_TAG_KEY=$RUN_ID; it is not this run's"
}
# namespace_is_ours: 0 ours, 1 someone else's, 2 the read failed, 3 absent.
namespace_is_ours() {
  local out key_esc="${NS_LABEL_KEY//./\\.}"
  out="$(kc get namespace "$NAMESPACE" --ignore-not-found \
    -o "jsonpath={.metadata.labels.${key_esc}}{\"|\"}{.metadata.name}" 2>/dev/null)" || return 2
  [[ -z "$out" || "$out" == "|" ]] && return 3
  [[ "${out%%|*}" == "$NS_LABEL_VAL" ]]
}
# wait_until <tries> <what> <command...>: 0 when the command succeeds, 2 when it never does.
wait_until() {
  local tries="$1" what="$2" i
  shift 2
  for ((i = 1; i <= tries; i++)); do
    "$@" && return 0
    sleep "${CB_SLEEP_SECONDS:-10}"
  done
  warn "gave up waiting for $what after $tries tries"
  return 2
}

# ---- Probe pods (one per node, deleted by exact name) ----
probe_name() { printf 'cb-probe-%s-%s\n' "$1" "$RUN_ID"; }
CB_PROBES=()   # the probe pods that this script started and has not deleted yet
probe_start() { # probe_start <name> <node>
  CB_PROBES+=("$1")
  python3 "$PY" render-probe --name "$1" --node "$2" | kc create -f - >/dev/null \
    || die E_PROBE "could not create the probe pod $1 on node $2"
  kc -n "$NAMESPACE" wait --for=condition=Ready "pod/$1" --timeout=5m >/dev/null \
    || die E_PROBE "the probe pod $1 did not become Ready"
}
probe_exec() { local name="$1"; shift; kc -n "$NAMESPACE" exec "$name" -- "$@"; }
probe_stop() {
  local p kept=()
  kc -n "$NAMESPACE" delete pod "$1" --ignore-not-found --wait=true >/dev/null || return 1
  for p in ${CB_PROBES[@]+"${CB_PROBES[@]}"}; do [[ "$p" == "$1" ]] || kept+=("$p"); done
  CB_PROBES=(${kept[@]+"${kept[@]}"})
}
# probe_cleanup: the exit trap of setup.sh and test.sh. It deletes each probe pod that the script
# started and did not delete, by exact name, so that a failure leaves none behind.
probe_cleanup() {
  local p
  for p in ${CB_PROBES[@]+"${CB_PROBES[@]}"}; do
    probe_stop "$p" || warn "could not delete the probe pod $p; delete it with: kubectl -n $NAMESPACE delete pod $p"
  done
}
# probe_capture <probe> <out-dir>: the host evidence of one node, one file per item. Each
# command runs on its own, so an unreadable item is an empty file, which the checks read as
# "could not check" (exit 2).
# The single-quoted scripts run in the probe pod, so they must not expand here.
# shellcheck disable=SC2016
probe_capture() {
  local p="$1" d="$2"
  private_dirs "$d" || die E_PROBE "could not create $d"
  probe_exec "$p" sh -c 'echo "BTF_BYTES=$(wc -c < /host/sys/kernel/btf/vmlinux)"' >"$d/btf.txt" 2>"$d/btf.err" || true
  probe_exec "$p" cat /proc/cmdline >"$d/cmdline.txt" 2>"$d/cmdline.err" || true
  probe_exec "$p" chroot /host /usr/bin/journalctl -k -b --no-pager -o short-iso >"$d/kernel.log" 2>"$d/kernel.err" || true
  probe_exec "$p" chroot /host /usr/bin/journalctl -b --no-pager -o short-iso >"$d/journal.log" 2>"$d/journal.err" || true
  probe_exec "$p" cat /host/sys/fs/selinux/enforce >"$d/selinux-enforce.txt" 2>"$d/selinux-enforce.err" || true
  probe_exec "$p" sh -c 'for d in /proc/[0-9]*; do l=$(cat "$d/attr/current" 2>/dev/null) || continue; c=$(tr "\0" " " < "$d/cmdline" 2>/dev/null); [ -n "$c" ] && printf "%s\t%s\n" "$l" "$c"; done' \
    >"$d/domains.txt" 2>"$d/domains.err" || true
  probe_exec "$p" chroot /host /usr/bin/containerd config dump >"$d/containerd-dump.toml" 2>"$d/containerd-dump.err" || true
  probe_exec "$p" cat /host/etc/containerd/nitro-sandbox.toml >"$d/nitro-sandbox.toml" 2>"$d/nitro-sandbox.err" || true
  # The kubelet kubeconfig that the shim reads: stat only (its size), never its content.
  probe_exec "$p" sh -c 'f=/host/etc/kubernetes/kubelet/kubeconfig; if [ -e "$f" ]; then echo "KUBECONFIG_BYTES=$(stat -L -c %s "$f")"; else echo KUBECONFIG_ABSENT; fi' \
    >"$d/kubeconfig.txt" 2>"$d/kubeconfig.err" || : >"$d/kubeconfig.txt"
  # The version and compressors of the host mkfs.erofs (-V prints them and exits; it writes nothing).
  probe_exec "$p" chroot /host /usr/bin/mkfs.erofs -V >"$d/mkfs-erofs.txt" 2>"$d/mkfs-erofs.err" || : >"$d/mkfs-erofs.txt"
  probe_exec "$p" sh -c 'echo "==links=="; nsenter -t 1 -n ip -o link || exit 1; echo "==states=="; for f in /host/run/systemd/netif/links/*; do printf "%s " "${f##*/}"; grep -E "^(ADMIN_STATE|OPER_STATE)=" "$f" | tr "\n" " "; echo; done' \
    >"$d/networkd.txt" 2>"$d/networkd.err" || : >"$d/networkd.txt"
  probe_exec "$p" nsenter -t 1 -n ip -o addr >"$d/host-addr.txt" 2>"$d/host-addr.err" || true
  probe_exec "$p" nsenter -t 1 -n ip route show table all >"$d/host-route.txt" 2>"$d/host-route.err" || true
  probe_exec "$p" sh -c 'echo "==dm=="; cat /host/sys/block/dm-0/dm/name || exit 1; echo "==dev=="; cat /host/sys/block/dm-0/dev || exit 1; echo "==cmdline=="; cat /proc/cmdline; echo "==mount=="; grep -E "^[0-9]+ [0-9]+ [0-9:]+ / / " /host/proc/1/mountinfo' \
    >"$d/dm-verity.txt" 2>"$d/dm-verity.err" || : >"$d/dm-verity.txt"
}

# probe_eni_capture <probe> <file>: the links, addresses, IPv4 and IPv6 routes (all tables) and
# IPv4 rules of the host network namespace, in the sections that check-eni-capture and
# check-eni-stable read. It runs /usr/sbin/ip of the host (iproute2 of the Bottlerocket release
# package), because busybox ip prints no route protocol (proto dhcp, proto ra). It makes no D-Bus
# or systemctl call. A failed read leaves an empty file, which the checks read as "could not
# check" (exit 2).
# shellcheck disable=SC2016
probe_eni_capture() {
  probe_exec "$1" sh -c 'hip() { nsenter -t 1 -n chroot /host /usr/sbin/ip "$@"; }
    echo "==link=="; hip -o link || exit 1; echo "==addr=="; hip -o addr || exit 1
    echo "==route=="; hip -4 route show table all || exit 1; echo "==route6=="; hip -6 route show table all || exit 1
    echo "==rule=="; hip -4 rule || exit 1' >"$2" 2>"$2.err" || : >"$2"
}

# ---- Tallies ----
DEMO_PASS=0
DEMO_FAIL=0
DEMO_SKIP=0
assert() {
  if [[ "$2" == 0 ]]; then
    printf '  [PASS] %s\n' "$1"; DEMO_PASS=$((DEMO_PASS + 1))
  else
    printf '  [FAIL] %s\n' "$1"; DEMO_FAIL=$((DEMO_FAIL + 1))
  fi
}
# skip: a check that could not run. It counts as a failure.
skip() { printf '  [SKIP!] %s (required evidence missing: counts as a failure)\n' "$1"; DEMO_SKIP=$((DEMO_SKIP + 1)); }
# check "<what it proves>" <command...>: run one check; exit 0 PASS, 1 FAIL, 2 SKIP!.
check() {
  local what="$1" rc=0
  shift
  "$@" || rc=$?
  case "$rc" in
    0) assert "$what" 0 ;;
    2) skip "$what" ;;
    *) assert "$what" 1 ;;
  esac
}
demo_summary() {
  local subject="${1:-the sample}" total=$((DEMO_PASS + DEMO_FAIL))
  printf '\n'
  if ((total == 0)); then
    printf 'RESULT: no assertions ran, so %s is NOT proven (%d skipped).\n' "$subject" "$DEMO_SKIP"; return 1
  fi
  if ((DEMO_FAIL == 0 && DEMO_SKIP == 0)); then
    printf 'RESULT: %s: %d/%d assertions passed.\n' "$subject" "$DEMO_PASS" "$total"
  else
    printf 'RESULT: %d of %d assertion(s) FAILED and %d check(s) could not run, so %s is NOT proven.\n' \
      "$DEMO_FAIL" "$total" "$DEMO_SKIP" "$subject"
  fi
  ((DEMO_FAIL == 0 && DEMO_SKIP == 0))
}
CLEAN_FAIL=0
clean_failed() {
  printf 'CLEAN FAILED: %s\n' "$1" >&2
  [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /' >&2
  CLEAN_FAIL=$((CLEAN_FAIL + 1))
  return 0
}
clean_summary() {
  printf '\n'
  if ((CLEAN_FAIL == 0)); then
    printf 'CLEAN: %s: nothing left behind.\n' "${1:-the sample}"
  else
    printf 'CLEAN: %d step(s) did not complete for %s. See above.\n' "$CLEAN_FAIL" "${1:-the sample}"
  fi
  ((CLEAN_FAIL == 0))
}
