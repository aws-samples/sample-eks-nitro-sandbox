#!/usr/bin/env bash
# Shared setup for the pause-resume scripts: read .env, set names, and the
# guards the other scripts use. Sourced, not run.
#
# Every kubectl call in these scripts goes through kc(), which pins --context and
# --namespace, so a run never depends on the machine's current context (shared
# clusters change it) or default namespace.
set -euo pipefail

SAMPLE=pause-resume
SANDBOX=pause-resume
# shellcheck disable=SC2034  # PVC is used by the scripts that source this file.
PVC="workspace-${SANDBOX}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR="$(cd "$HERE/.." && pwd)"

# Load .env if present, as defaults. A value already set in the environment wins
# over .env, so `NAMESPACE=other ./scripts/setup.sh` overrides the file. Keep the
# caller's environment, source .env into a subshell, and fill in only the names
# the caller did not set.
if [[ -f "$SAMPLE_DIR/.env" ]]; then
  while IFS='=' read -r _k _v; do
    case "$_k" in
      NAMESPACE)      NAMESPACE="${NAMESPACE:-$_v}" ;;
      STORAGE_CLASS)  STORAGE_CLASS="${STORAGE_CLASS:-$_v}" ;;
      AWS_REGION)     AWS_REGION="${AWS_REGION:-$_v}" ;;
      KUBE_CONTEXT)   KUBE_CONTEXT="${KUBE_CONTEXT:-$_v}" ;;
    esac
  done < <(grep -E '^[[:space:]]*(NAMESPACE|STORAGE_CLASS|AWS_REGION|KUBE_CONTEXT)[[:space:]]*=' "$SAMPLE_DIR/.env" \
             | sed -E 's/^[[:space:]]*//; s/[[:space:]]*=[[:space:]]*/=/')
fi

NAMESPACE="${NAMESPACE:-pause-resume}"
# The StorageClass the workspace claim uses. EKS Auto Mode does not create one, so
# the reader applies deploy/storage-class.yaml once per cluster; the scripts only
# check it is present with the right provisioner (require_storage_class).
STORAGE_CLASS="${STORAGE_CLASS:-auto-ebs-sc}"
# The provisioner the class must use for the EBS CSI driver.
EBS_PROVISIONER="ebs.csi.eks.amazonaws.com"
AWS_REGION="${AWS_REGION:-us-west-2}"
# The context the run pins. Set KUBE_CONTEXT to the name of the kube context for
# the cluster you ran Getting started on. Empty means "use the current context",
# which the scripts then print so you can see which cluster they used.
KUBE_CONTEXT="${KUBE_CONTEXT:-}"

# kc: kubectl pinned to this sample's context and namespace. Cluster-scoped reads
# that must not carry a namespace use kc_cluster.
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

# Print which cluster the run is pinned to, so a shared machine's current context
# can never be mistaken for the one you meant.
show_context() {
  local ctx
  ctx="$(kc_cluster config current-context 2>/dev/null || true)"
  if [[ -n "$KUBE_CONTEXT" ]]; then
    echo "context: $KUBE_CONTEXT (pinned)   namespace: $NAMESPACE"
  else
    echo "context: ${ctx:-<none>} (current; set KUBE_CONTEXT to pin it)   namespace: $NAMESPACE"
  fi
}

# This sample's namespace is the sample's only when it carries the label the
# setup put on it. A script reuses or deletes the namespace, or anything in it,
# only when the label is present; otherwise it stops. A read that fails means
# "could not determine", which is a failure, never "gone".
NS_LABEL_KEY="app.kubernetes.io/managed-by"
NS_LABEL_VAL="$SAMPLE"

# Return codes, so callers can tell the cases apart. A read that fails for any
# reason other than "not found" is NEVER read as "gone".
#   0  the namespace exists and carries our label  (it is the sample's)
#   1  the namespace exists but does not carry our label  (someone else's)
#   2  the namespace exists but its labels could not be read  (could not tell)
#   3  the namespace does not exist
namespace_is_ours() {
  local out rc
  # One authoritative read of the object. --ignore-not-found makes "absent" a
  # clean empty result with rc 0, so a real API error (rc != 0) is distinct from
  # a namespace that simply is not there.
  local key_esc="${NS_LABEL_KEY//./\\.}"   # dots in the label key must be escaped in jsonpath
  out="$(kc_cluster get namespace "$NAMESPACE" --ignore-not-found \
    -o "jsonpath={.metadata.labels.${key_esc}}{\"|\"}{.metadata.name}" 2>/dev/null)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    return 2    # the read itself failed: could not determine
  fi
  if [[ "$out" == "|" || -z "$out" ]]; then
    return 3    # --ignore-not-found printed nothing: the namespace is absent
  fi
  # out is "<label-value>|<name>"; the name is non-empty, so the namespace exists.
  local label="${out%%|*}"
  [[ "$label" == "$NS_LABEL_VAL" ]]
}

# resource_exists <kind/name...> : a failure-aware existence check, so a failed
# read is never mistaken for "absent" or "gone". Uses --ignore-not-found so a
# genuinely missing object is a clean empty result (rc 0), distinct from an API
# error (rc != 0). Pass kc or kc_cluster as the first argument.
#   0  the resource exists
#   1  the resource does not exist
#   2  the read failed (could not determine)
resource_exists() {
  local runner=$1; shift
  local out rc
  out="$("$runner" get "$@" --ignore-not-found -o name 2>/dev/null)"
  rc=$?
  [[ $rc -ne 0 ]] && return 2
  [[ -n "$out" ]]
}

# require_our_namespace : stop unless this sample owns the namespace, so suspend,
# resume and any other mutating script never touch a same-named object in a
# namespace that belongs to something else. A failed read stops too.
require_our_namespace() {
  local rc=0
  namespace_is_ours || rc=$?
  case $rc in
    0) return 0 ;;
    1) die "namespace $NAMESPACE is not the sample's ($NS_LABEL_KEY=$NS_LABEL_VAL); refusing to touch anything in it. Set NAMESPACE in .env to the one you ran ./scripts/setup.sh with." ;;
    2) die "could not read namespace $NAMESPACE; stopping rather than act on a namespace I cannot verify" ;;
    3) die "namespace $NAMESPACE does not exist; run ./scripts/setup.sh first" ;;
  esac
}

# require_storage_class : stop unless the StorageClass named by STORAGE_CLASS
# exists and uses the EBS CSI provisioner. A StorageClass is cluster-wide, so the
# reader applies deploy/storage-class.yaml once (AGENTS.md leaves cluster-wide
# settings to the reader); the scripts never create, patch or label one. A read
# that fails is a failure, never "absent". Run this before setup creates anything.
require_storage_class() {
  local prov rc
  prov="$(kc_cluster get storageclass "$STORAGE_CLASS" --ignore-not-found \
    -o jsonpath='{.provisioner}' 2>/dev/null)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    die "could not read storageclass/$STORAGE_CLASS; stopping rather than guess (a failed read is not 'absent')"
  fi
  if [[ -z "$prov" ]]; then
    die "storageclass/$STORAGE_CLASS not found. EKS Auto Mode does not create one; apply the sample's class once per cluster:
         kubectl apply -f deploy/storage-class.yaml
       Or set STORAGE_CLASS in .env to a class that uses $EBS_PROVISIONER."
  fi
  if [[ "$prov" != "$EBS_PROVISIONER" ]]; then
    die "storageclass/$STORAGE_CLASS uses provisioner '$prov', not '$EBS_PROVISIONER'; its volumes are not EBS CSI volumes. Apply the sample's class under a free name, or set STORAGE_CLASS to one that uses $EBS_PROVISIONER:
         kubectl apply -f deploy/storage-class.yaml"
  fi
}
