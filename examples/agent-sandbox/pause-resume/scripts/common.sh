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
      NAMESPACE)     NAMESPACE="${NAMESPACE:-$_v}" ;;
      AWS_REGION)    AWS_REGION="${AWS_REGION:-$_v}" ;;
      KUBE_CONTEXT)  KUBE_CONTEXT="${KUBE_CONTEXT:-$_v}" ;;
    esac
  done < <(grep -E '^[[:space:]]*(NAMESPACE|AWS_REGION|KUBE_CONTEXT)[[:space:]]*=' "$SAMPLE_DIR/.env" \
             | sed -E 's/^[[:space:]]*//; s/[[:space:]]*=[[:space:]]*/=/')
fi

NAMESPACE="${NAMESPACE:-pause-resume}"
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
