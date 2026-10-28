# common.sh: sourced by every script in this sample, on the workstation and on the build
# host alike. Loads config.env, sets defaults, and provides logging, assertion and
# ownership-tag helpers. Sourced, never executed, and never sets `set -e`: callers choose
# their own error discipline, and some stages (bake-prep, smoke) must run to completion so
# they can report why they failed instead of stopping at the first non-zero command.

SAMPLE_DIR="${SAMPLE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# The repository root is three levels up from this sample folder
# (examples/setup/ubuntu-ami). Local runtime artifacts, logs and output belong under the
# repository's gitignored tmp/, never inside the sample folder (see AGENTS.md).
REPO_ROOT="${REPO_ROOT:-$(cd "$SAMPLE_DIR/../../.." && pwd)}"
# IN_CHECKOUT=1 when this copy of the sample sits in a repository checkout
# (<repo>/examples/<section>/<sample>, with AGENTS.md at the root). On the build host and on
# a node the sample is unpacked under /usr/local/share/ubuntu-ami-sample instead, and its
# local state defaults under /var/lib/ubuntu-ami-sample (setup.sh also passes it explicitly).
if [ -f "$REPO_ROOT/AGENTS.md" ] && [ "$(basename "$(cd "$SAMPLE_DIR/../.." && pwd)")" = examples ]; then
  IN_CHECKOUT=1
else
  IN_CHECKOUT=0
fi

# Logging and failure helpers, defined before the path-containment guard below so it can
# `die` with a clear message. Defined once; the rest of the file uses them too.
log()  { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# All local runtime state (logs, output, downloaded runtime artifacts) lives under a single
# repository-root base, tmp/issue10/run, which the root .gitignore already ignores. Nothing
# defaults inside the sample folder: see AGENTS.md ("Keep local files in the repository's
# tmp/ ... Never put them in a sample folder or its .gitignore").
if [ "$IN_CHECKOUT" = 1 ]; then
  : "${ISSUE10_RUN_DIR:=$REPO_ROOT/tmp/issue10/run}"
else
  : "${ISSUE10_RUN_DIR:=/var/lib/ubuntu-ami-sample/run}"
fi
: "${LOG_DIR:=$ISSUE10_RUN_DIR/logs}"
: "${OUT_DIR:=$ISSUE10_RUN_DIR/out}"

# config.env is local and gitignored; config.env.example documents every variable with a
# placeholder. Both the workstation driver and a build-host copy of this directory look for
# it in the sample root.
for __common_cfg in "$SAMPLE_DIR/config.env" "$HOME/ubuntu-ami/config.env"; do
  [ -f "$__common_cfg" ] && { . "$__common_cfg"; break; }
done
unset __common_cfg

: "${AWS_REGION:=us-west-2}"
: "${CLUSTER_NAME:=nitro-sandboxes-demo}"
: "${RESOURCE_PREFIX:=ubuntu-ami-sample}"
: "${TAGS_OWNER_KEY:=ManagedBy}"
: "${TAGS_OWNER_VALUE:=$RESOURCE_PREFIX}"
: "${NAMESPACE:=ubuntu-ami-sample}"
: "${KERNEL_VERSION:=6.18.56}"
# The host kernel's local version suffix: the built kernel reports uname -r
# ${KERNEL_VERSION}${KERNEL_LOCALVERSION} (6.18.56-nitro-ga), as the GA bundle's build does.
: "${KERNEL_LOCALVERSION:=-nitro-ga}"
: "${EROFS_UTILS_VERSION:=1.8.10}"
: "${RUNTIME_ARTIFACTS_DIR:=$ISSUE10_RUN_DIR/runtime}"

# Every local runtime directory must sit where nothing is one `git add` from publication
# (AGENTS.md: "Keep local files in the repository's tmp/ ... Never put them in a sample folder
# or its .gitignore"):
#   * in a checkout, ISSUE10_RUN_DIR, LOG_DIR, OUT_DIR and RUNTIME_ARTIFACTS_DIR must each resolve
#     at or under $REPO_ROOT/tmp/; anything else (inside the sample, elsewhere in the repository,
#     or outside the repository) is refused;
#   * outside a checkout (the build host's unpacked copy), they must not resolve inside that copy.
# A relative override is read relative to the sample folder (a fixed base, not the caller's
# working directory), and every value is canonicalized with `realpath -m` (symlinks in existing
# components resolved, missing components kept), then compared as whole path components. The
# guard runs once, before any directory is created, and replaces each value with its canonical
# absolute path, so a refused path is never created.
canon_path() { # canon_path <path> : absolute canonical path; relative paths are under SAMPLE_DIR
  local p="$1"
  case "$p" in /*) ;; *) p="$SAMPLE_DIR/$p" ;; esac
  if realpath -m / >/dev/null 2>&1; then
    realpath -m -- "$p"
  else
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p"
  fi
}
path_within() { # path_within <path> <base> : 0 when <path> is <base> or below it (whole components)
  [ "$1" = "$2" ] || case "$1/" in "$2"/*) true ;; *) false ;; esac
}
if [ "$IN_CHECKOUT" = 1 ]; then
  __state_root=$(canon_path "$REPO_ROOT/tmp")
else
  __sample_copy=$(canon_path "$SAMPLE_DIR")
fi
guard_state_dir() { # guard_state_dir <var-name> : canonicalize the variable, refuse a forbidden location
  local name="$1" raw resolved
  raw="${!name}"
  [ -n "$raw" ] || die "$name is empty"
  resolved=$(canon_path "$raw") || die "$name: cannot resolve '$raw'"
  if [ "$IN_CHECKOUT" = 1 ]; then
    path_within "$resolved" "$__state_root" \
      || die "$name resolves to '$resolved', which is not under the repository's tmp/ ('$__state_root'). AGENTS.md keeps local files in the repository's gitignored tmp/ ('Keep local files in the repository's tmp/ ... Never put them in a sample folder or its .gitignore'). Leave it unset for the default under tmp/issue10/run, or point it below tmp/."
  else
    ! path_within "$resolved" "$__sample_copy" \
      || die "$name resolves to '$resolved', which is inside the sample copy ('$__sample_copy'); local state must live outside it (default /var/lib/ubuntu-ami-sample/run)."
  fi
  printf -v "$name" '%s' "$resolved"
}
guard_state_dir ISSUE10_RUN_DIR
guard_state_dir LOG_DIR
guard_state_dir OUT_DIR
guard_state_dir RUNTIME_ARTIFACTS_DIR
mkdir -p "$LOG_DIR" "$OUT_DIR" "$RUNTIME_ARTIFACTS_DIR"

: "${LOCK_FILE:=$SAMPLE_DIR/packages/sources.lock}"
# Where the guest image is staged on the node (latest.eif, latest-disk.img and the rootfs.ext4
# symlink), and the shim's own data folder, which must NOT be inside the image folder.
: "${NITRO_SANDBOX_IMAGE_DIR:=/var/lib/nitro-sandbox-images}"
: "${NITRO_SANDBOX_DATA_DIR:=/var/lib/nitro-sandbox}"
# Off by default, the production setting: enclaves attest their real measurements.
# SHIM_DEBUG=true gives debug-mode enclaves whose attestation PCRs read zero; troubleshooting only.
: "${SHIM_DEBUG:=false}"
# SYSROOT is a TEST HOOK, empty on every real host: the build-host stages that write system
# files (31-wire-containerd.sh, 35-apparmor.sh, 50-bake-prep.sh) and scripts/verify-image.py
# prefix their fixed system paths with it, so the tracked clusterless tests can run the real
# scripts against a fixture tree.
: "${SYSROOT:=}"
if [ -n "$SYSROOT" ]; then
  case "$SYSROOT" in /*) ;; *) die "SYSROOT must be an absolute path, got '$SYSROOT'" ;; esac
  [ -d "$SYSROOT" ] || die "SYSROOT '$SYSROOT' is not a directory"
fi
# The on-image provenance manifest every build stage appends one line to.
: "${IMAGE_MANIFEST:=$SYSROOT/etc/ubuntu-ami-sample-manifest}"
# Node labels the isolated-sandbox RuntimeClass schedules on; both must be on the node.
: "${NODE_LABELS:=eks.amazonaws.com/nitro-sandbox=true,sandbox.preview/nitro=true}"

# Assert a condition and say what it means when it does not hold, so a failed build names
# the prerequisite it is missing rather than only a line number.
must() { # must <description> <command...>
  local what=$1; shift
  if "$@"; then printf 'ok: %s\n' "$what"; else printf 'FAILED: %s\n  (%s)\n' "$what" "$*" >&2; return 1; fi
}

# The ownership tag every AWS resource this sample creates must carry, in the shape the AWS
# CLI --tags argument and TagSpecifications both accept.
ownership_tag_cli() { printf 'Key=%s,Value=%s' "$TAGS_OWNER_KEY" "$TAGS_OWNER_VALUE"; }

# --- Run scope ---------------------------------------------------------------------------
# Every AWS resource the sample creates carries TWO tags, ManagedBy=<RESOURCE_PREFIX> and
# RunId=<RUN_ID>, and has a name derived from both, so two runs in one account never share or
# delete each other's resources. setup.sh picks RUN_ID (UTC timestamp, lowercase) and persists it
# in $RUN_STATE_FILE; clean.sh, test.sh and the helper scripts read it from there, or from the
# RUN_ID environment variable (clean.sh: --run-id).
: "${TAGS_RUN_KEY:=RunId}"
: "${RUN_STATE_FILE:=$OUT_DIR/run-state.env}"
valid_run_id() { [[ "${1:-}" =~ ^[a-z0-9]{1,20}$ ]]; }
# load_run_id: RUN_ID from the environment, else from $RUN_STATE_FILE. Returns 1 when neither
# has one; dies when the value found is malformed.
load_run_id() {
  local v
  if [ -n "${RUN_ID:-}" ]; then
    valid_run_id "$RUN_ID" || die "RUN_ID '$RUN_ID' is not 1 to 20 lowercase letters and digits"
    return 0
  fi
  [ -f "$RUN_STATE_FILE" ] || return 1
  v=$(sed -n 's/^RUN_ID=//p' "$RUN_STATE_FILE" | tail -n 1)
  valid_run_id "$v" || die "run state $RUN_STATE_FILE has no valid RUN_ID line"
  RUN_ID=$v
}
# require_name <kind> <name> <max-length> <regex>: refuse a derived name the API would reject.
require_name() {
  local kind="$1" name="$2" max="$3" rx="$4"
  [ "${#name}" -le "$max" ] || die "$kind name '$name' is ${#name} characters; the limit is $max. Shorten RESOURCE_PREFIX ($RESOURCE_PREFIX)."
  [[ "$name" =~ $rx ]] || die "$kind name '$name' has characters the API refuses (allowed: $rx). Change RESOURCE_PREFIX."
}
# derive_run_names: every per-run name, from RESOURCE_PREFIX and RUN_ID, checked against the
# IAM, EC2, EKS and S3 name rules before anything uses it.
derive_run_names() {
  valid_run_id "${RUN_ID:-}" || die "derive_run_names: no valid RUN_ID"
  [[ "$RESOURCE_PREFIX" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "RESOURCE_PREFIX '$RESOURCE_PREFIX' must be lowercase letters, digits and hyphens, starting with a letter or digit"
  BUILD_ROLE_NAME="${RESOURCE_PREFIX}-${RUN_ID}-build"
  NODE_ROLE_NAME="${RESOURCE_PREFIX}-${RUN_ID}-node"
  INSTANCE_PROFILE="${RESOURCE_PREFIX}-${RUN_ID}-build"
  STAGE_POLICY_NAME="${RESOURCE_PREFIX}-${RUN_ID}-stage-read"
  SG_NAME="${RESOURCE_PREFIX}-${RUN_ID}-build-sg"
  LT_NAME="${RESOURCE_PREFIX}-${RUN_ID}-lt"
  NODEGROUP_NAME="${RESOURCE_PREFIX}-${RUN_ID}-ng"
  BUILD_NAME="${RESOURCE_PREFIX}-${RUN_ID}-build"
  VERIFY_NAME="${RESOURCE_PREFIX}-${RUN_ID}-verify"
  AMI_NAME="${RESOURCE_PREFIX}-${RUN_ID}"
  STAGE_BUCKET_PREFIX="${RESOURCE_PREFIX}-stage-${RUN_ID}"   # + "-<6 hex>" at creation
  RUN_STATE_DIR="$OUT_DIR/runs/$RUN_ID"
  EVIDENCE_DIR="${EVIDENCE_DIR:-$RUN_STATE_DIR/evidence}"
  require_name "IAM role" "$BUILD_ROLE_NAME" 64 '^[A-Za-z0-9+=,.@_-]+$'
  require_name "IAM role" "$NODE_ROLE_NAME" 64 '^[A-Za-z0-9+=,.@_-]+$'
  require_name "IAM instance profile" "$INSTANCE_PROFILE" 128 '^[A-Za-z0-9+=,.@_-]+$'
  require_name "IAM inline policy" "$STAGE_POLICY_NAME" 128 '^[A-Za-z0-9+=,.@_-]+$'
  require_name "EC2 security group" "$SG_NAME" 255 '^[A-Za-z0-9._-]+$'
  require_name "EC2 launch template" "$LT_NAME" 128 '^[A-Za-z0-9()./_-]{3,}$'
  require_name "EKS node group" "$NODEGROUP_NAME" 63 '^[A-Za-z0-9][A-Za-z0-9_-]*$'
  require_name "AMI" "$AMI_NAME" 128 '^[A-Za-z0-9()./_ -]{3,}$'
  require_name "S3 bucket" "${STAGE_BUCKET_PREFIX}-ffffff" 63 '^[a-z0-9][a-z0-9-]*[a-z0-9]$'
}
# require_run_id: load RUN_ID (env or run state) and derive the names, or stop.
require_run_id() {
  load_run_id || die "no RUN_ID: no RUN_ID environment variable and no run state at $RUN_STATE_FILE. Pass the run id (clean.sh --run-id <id>) or run ./setup.sh first."
  derive_run_names
}
# run_tags_cli: both tags, as the items a shorthand TagSpecifications Tags=[...] list takes.
run_tags_cli() { printf '{Key=%s,Value=%s},{Key=%s,Value=%s}' "$TAGS_OWNER_KEY" "$TAGS_OWNER_VALUE" "$TAGS_RUN_KEY" "$RUN_ID"; }
# tags_match: read an AWS tag list ([{"Key":..,"Value":..}] or a {key: value} map) as JSON on
# stdin; 0 only when it carries ManagedBy=<RESOURCE_PREFIX> AND RunId=<RUN_ID>.
tags_match() {
  python3 -c '
import json, sys
t = json.load(sys.stdin)
if isinstance(t, list):
    t = {x.get("Key"): x.get("Value") for x in t}
sys.exit(0 if isinstance(t, dict) and t.get(sys.argv[1]) == sys.argv[2] and t.get(sys.argv[3]) == sys.argv[4] else 1)
' "$TAGS_OWNER_KEY" "$TAGS_OWNER_VALUE" "$TAGS_RUN_KEY" "$RUN_ID"
}
# json_get <python-expression over d>: read JSON on stdin and print the expression's value: one
# line per item for a list (an item that is itself a list is tab-joined), nothing for None.
json_get() {
  python3 -c '
import json, sys
d = json.load(sys.stdin)
r = eval(sys.argv[1], {"d": d})
if r is None:
    pass
elif isinstance(r, (list, tuple)):
    for x in r:
        print("\t".join(map(str, x)) if isinstance(x, (list, tuple)) else x)
else:
    print(r)
' "$1"
}
# json_pick <python-expression over d>: read JSON on stdin, print the expression's value as JSON.
json_pick() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1], {"d": d})))' "$1"
}
# launch_spec <render-instance|render-lt|check-instance|check-lt> [args]: scripts/lib/launch_spec.py
# with this run's tag arguments (IMDSv2 hop limit 1, enclaves on, both tags on instance and volume).
launch_spec() {
  local cmd="$1"; shift
  python3 "$SAMPLE_DIR/scripts/lib/launch_spec.py" "$cmd" "$@" \
    --owner-key "$TAGS_OWNER_KEY" --owner-value "$TAGS_OWNER_VALUE" --run-key "$TAGS_RUN_KEY" --run-id "$RUN_ID"
}
# --- The cluster kubectl talks to ----------------------------------------------------------------
# Every kubectl call goes through kc, which always passes --context "$KUBE_CONTEXT". KUBE_CONTEXT
# is required: there is no fallback to the kubeconfig's current context, which another session on
# a shared machine can change, and nothing here runs `kubectl config use-context`.
kc() {
  [ -n "${KUBE_CONTEXT:-}" ] || { printf 'FATAL: KUBE_CONTEXT is not set; set it to the kubectl context of cluster %s\n' "$CLUSTER_NAME" >&2; return 2; }
  kubectl --context "$KUBE_CONTEXT" "$@"
}
# require_kube_context: stop unless KUBE_CONTEXT is set, readable, and its cluster's server URL is
# the API endpoint `aws eks describe-cluster` reports for CLUSTER_NAME. Called before anything
# reads or changes the cluster, so the kubectl side and the AWS side are the same cluster.
require_kube_context() {
  local err server endpoint s e msg
  [ -n "${KUBE_CONTEXT:-}" ] || die "KUBE_CONTEXT is not set. Set it to the kubectl context of cluster $CLUSTER_NAME (see 'kubectl config get-contexts'); this sample never falls back to the current context and never runs 'kubectl config use-context'."
  err=$(mktemp)
  if ! server=$(kubectl --context "$KUBE_CONTEXT" config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>"$err"); then
    msg=$(head -n 2 "$err"); rm -f "$err"
    die "could not read kube context '$KUBE_CONTEXT' (refusing to guess which cluster it is): $msg"
  fi
  if [ -z "$server" ]; then rm -f "$err"; die "kube context '$KUBE_CONTEXT' names no cluster server; refusing to guess which cluster it is"; fi
  if ! endpoint=$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --output json 2>"$err" | json_get 'd["cluster"]["endpoint"]') || [ -z "$endpoint" ]; then
    msg=$(head -n 2 "$err"); rm -f "$err"
    die "could not read the API endpoint of cluster $CLUSTER_NAME (describe-cluster failed), so kube context '$KUBE_CONTEXT' cannot be checked: $msg"
  fi
  rm -f "$err"
  # Compare scheme, host and port; case and a trailing slash or an explicit :443 do not matter.
  s=$(printf '%s' "$server" | tr 'A-Z' 'a-z' | sed -e 's#/*$##' -e 's#^\(https://[^/]*\):443$#\1#')
  e=$(printf '%s' "$endpoint" | tr 'A-Z' 'a-z' | sed -e 's#/*$##' -e 's#^\(https://[^/]*\):443$#\1#')
  [ "$s" = "$e" ] || die "kube context '$KUBE_CONTEXT' points at $server, but cluster $CLUSTER_NAME's API endpoint is $endpoint; refusing to act on a different cluster than the AWS calls use"
  log "kube context $KUBE_CONTEXT is cluster $CLUSTER_NAME ($endpoint)"
}

# arm_staging_revoke <bucket> <file-name>...: from now until disarm_staging_revoke, any exit of
# the calling script (a failed step, die, Ctrl-C) first runs `00b-stage-bucket.sh revoke` for
# these objects, so a failure between staging and the normal revocation never leaves the staged
# files or the build role's read in place. The script's own exit status is kept.
arm_staging_revoke() {
  STAGING_GUARD_ARGS=("$@")
  trap '__staging_rc=$?; __run_staging_revoke; exit $__staging_rc' EXIT
  trap 'exit 130' INT TERM
}
__run_staging_revoke() {
  [ "${#STAGING_GUARD_ARGS[@]}" -gt 0 ] || return 0
  warn "stopping before the staging revocation; revoking the staged objects and the build role's read now"
  bash "$SAMPLE_DIR/scripts/00b-stage-bucket.sh" revoke "${STAGING_GUARD_ARGS[@]}" \
    || warn "the staging revocation did not complete; see $RUN_STATE_DIR/stage-residue.txt, then run ./clean.sh --dry-run"
  STAGING_GUARD_ARGS=()
}
disarm_staging_revoke() { STAGING_GUARD_ARGS=(); trap - EXIT INT TERM; }

# aws_err_is <file> <code>...: 0 when the AWS CLI error text in <file> names one of the codes.
aws_err_is() {
  local f="$1" c; shift
  for c in "$@"; do grep -q -- "($c)" "$f" && return 0; done
  return 1
}

# lock_field <id> <field> : print the named field's value for the block whose id= line
# matches <id>, from LOCK_FILE. Multi-line fields (verify=) return only the first line;
# callers that need the fetch/verify note read the file directly. Returns 1 and prints
# nothing when the id or field is not found, so callers can fail closed rather than build
# with an empty pin.
lock_field() { # lock_field <id> <field>
  local id="$1" field="$2" in_block=0 val=""
  while IFS='=' read -r k v; do
    case "$k" in
      id) if [[ "$v" == "$id" ]]; then in_block=1; else in_block=0; fi ;;
      "") in_block=0 ;;
      "$field") [[ "$in_block" == 1 ]] && { val="$v"; } ;;
    esac
  done < "$LOCK_FILE"
  [[ -n "$val" ]] || return 1
  printf '%s\n' "$val"
}

# lock_ids_where <field> <value> : print, in file order, the id of every LOCK_FILE block whose
# <field> line is exactly <field>=<value> (for example `lock_ids_where kind runtime-payload`).
lock_ids_where() { # lock_ids_where <field> <value>
  awk -F= -v f="$1" -v want="$2" '
    /^id=/ { id = substr($0, 4) }
    /^$/   { id = "" }
    index($0, f "=") == 1 && substr($0, length(f) + 2) == want && id != "" { print id }
  ' "$LOCK_FILE"
}

# verify_sha256 <file> <expected-sha256> : fail closed on any mismatch. No override flag:
# a changed artifact aborts rather than silently entering the build.
verify_sha256() {
  local file="$1" expected="$2" actual
  [[ -s "$file" ]] || die "missing or empty file: $file"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    die "SHA-256 mismatch for $file
  expected: $expected
  actual:   $actual
This artifact does not match packages/sources.lock. Do not use it. Either the download is
corrupt (re-fetch) or the upstream artifact changed (re-pin deliberately in
packages/sources.lock and packages/SOURCES.txt together). There is no override flag."
  fi
  log "verified sha256 $file"
}
