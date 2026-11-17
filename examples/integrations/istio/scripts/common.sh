#!/usr/bin/env bash
# Shared settings for setup.sh and clean.sh. Sourced, never run on its own.
#
# Every kubectl call goes through kc(), which pins --context when KUBE_CONTEXT is
# set, so a run does not depend on whichever context another session left current.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR="$(cd "$HERE/.." && pwd)"

# Values come from the environment or from .env (copy .env.example). The file is
# read as KEY=VALUE lines and never sourced, so a stray line cannot run code.
if [[ -f "$SAMPLE_DIR/.env" ]]; then
  while IFS='=' read -r _k _v; do
    case "$_k" in
      KUBE_CONTEXT) KUBE_CONTEXT="${KUBE_CONTEXT:-$_v}" ;;
      NAMESPACE)    NAMESPACE="${NAMESPACE:-$_v}" ;;
    esac
  done < <(grep -E '^(KUBE_CONTEXT|NAMESPACE)=' "$SAMPLE_DIR/.env" || true)
fi
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
NAMESPACE="${NAMESPACE:-istio-sandbox-demo}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
# shellcheck disable=SC2034  # used by the scripts that source this file
MARK_KEY='app.kubernetes.io/managed-by'
# shellcheck disable=SC2034  # used by the scripts that source this file
MARK_VALUE='istio-sandbox'

[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] \
  || { echo "error: NAMESPACE '$NAMESPACE' is not a valid namespace name" >&2; exit 1; }

kc() {
  if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi
}

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

require_commands() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"; done
}

show_context() {
  local ctx
  ctx="$(kc config current-context 2>/dev/null)" \
    || die "could not read the kube context; set KUBE_CONTEXT or check your kubeconfig"
  echo "kube context: ${KUBE_CONTEXT:-$ctx}"
  echo "namespace:    $NAMESPACE"
}

# Runs kubectl and prints its stdout only. Its stderr goes to the terminal, never
# into the value, so a warning cannot be read as data. Returns 1 when kubectl
# fails. Lookups pass --ignore-not-found, so "absent" is a successful call with
# empty output, and no error text is ever parsed to decide it.
kc_read() {
  local out rc=0
  out="$(kc "$@")" || rc=$?
  ((rc == 0)) || return 1
  printf '%s' "$out"
}

# Prints the namespace's mark, or nothing when it has none. Returns 2 when the
# namespace is absent and 1 when the lookup failed or answered for something else.
namespace_mark() {
  local out
  out="$(kc_read get namespace "$NAMESPACE" --ignore-not-found \
    -o "jsonpath={.metadata.name}{\"|\"}{.metadata.labels.app\.kubernetes\.io/managed-by}")" || return 1
  [[ -n "$out" ]] || return 2
  [[ "$out" == "$NAMESPACE|"* ]] || { echo "unexpected answer for namespace $NAMESPACE: $out" >&2; return 1; }
  printf '%s' "${out#"$NAMESPACE|"}"
}
