#!/usr/bin/env bash
# Shared by every script in this folder: read .env, pin the kube context, and confirm the
# namespace is this sample's before anything is written into it.
#
# Not run on its own. Each script sources it.

SAMPLE=gitlab-ci
LABEL_KEY=ManagedBy
LABEL_VALUE="$SAMPLE"

SAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SAMPLE_DIR/.env"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

[[ -f "$ENV_FILE" ]] || die "copy .env.example to .env and fill it in first."
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${KUBE_CONTEXT:?set KUBE_CONTEXT in .env}"
NAMESPACE="${NAMESPACE:-gitlab-ci-demo}"
ROOT_SECRET="${ROOT_SECRET:-gitlab-root}"
RUNNER_SECRET="${RUNNER_SECRET:-gitlab-runner-config}"
PROJECT_PATH="${PROJECT_PATH:-sandbox-ci}"

# The context is named on every call, so a context another session changes mid-run cannot
# redirect it.
KCTL=(kubectl --context "$KUBE_CONTEXT")

# The in-cluster address of the GitLab Service. The runner manager and the job pods use
# this; GitLab's own external_url is the reader's port-forward, which only their machine
# can reach.
GITLAB_URL="http://gitlab.$NAMESPACE.svc.cluster.local:8080"

need_tools() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not on PATH."
  done
}

check_cluster() {
  "${KCTL[@]}" version -o json >/dev/null 2>&1 \
    || die "cannot reach the cluster with context '$KUBE_CONTEXT'. Check KUBE_CONTEXT in .env against 'kubectl config get-contexts'."
  "${KCTL[@]}" get runtimeclass isolated-sandbox >/dev/null 2>&1 \
    || die "the isolated-sandbox RuntimeClass is not on this cluster, so no job pod could run in a sandbox. Work through Getting started > Hello sandbox first."
}

# Confirm the namespace is this sample's. Everything this sample creates lives inside it, so
# this one check is what stands behind every write and every delete that follows.
#
# A read that FAILS is not a report that the namespace is absent: --ignore-not-found keeps
# the two apart, so a transient error or RBAC that denies get never reads as "absent" and
# goes on to create it.
require_namespace() {
  local present owner
  present="$("${KCTL[@]}" get namespace "$NAMESPACE" -o name --ignore-not-found 2>/dev/null)" \
    || die "could not read namespace '$NAMESPACE'. That is a failed read, not a report that it is absent."
  [[ -n "$present" ]] \
    || die "namespace '$NAMESPACE' does not exist. Run scripts/setup.sh first."
  owner="$("${KCTL[@]}" get namespace "$NAMESPACE" -o "jsonpath={.metadata.labels.$LABEL_KEY}" 2>/dev/null)" \
    || die "could not read the labels of namespace '$NAMESPACE'."
  [[ "$owner" == "$LABEL_VALUE" ]] \
    || die "namespace '$NAMESPACE' is not labelled $LABEL_KEY=$LABEL_VALUE (found: ${owner:-none}), so it is not this sample's. Set NAMESPACE in .env to a name this sample owns."
}

# Run a Ruby script on GitLab's own Rails console, with the script on standard input.
#
# This is how the scripts do what the page's reader does in the web UI: create the project,
# commit the pipeline, mint the runner authentication token, start a pipeline and read a job
# log. The script is piped in rather than passed as an argument, so nothing it contains ever
# reaches a command line, and `kubectl exec` has no way to set an environment variable in the
# container anyway.
#
# It returns non-zero rather than calling die, and the pod is resolved on every call. Both
# matter: a caller runs this inside `$(...)`, where die would exit only the subshell and
# leave the script running with an empty result, and run-pipeline.sh calls it repeatedly over
# many minutes, during which GitLab's pod could be replaced and its name go stale.
#
# A pod with a deletionTimestamp is not used: a pod being replaced keeps reporting the
# Running phase while it shuts down, so a `--field-selector` on the phase alone would pick it.
gitlab_exec() {
  local pod
  pod="$("${KCTL[@]}" get pod -n "$NAMESPACE" -l app=gitlab -o json 2>/dev/null \
    | jq -r '[(.items // [])[] | select(.metadata.deletionTimestamp == null)
              | select(.status.phase == "Running")] | .[0].metadata.name // ""' 2>/dev/null)" \
    || return 1
  if [[ -z "$pod" ]]; then
    echo "no GitLab pod is Running in namespace '$NAMESPACE'. Run scripts/setup.sh first." >&2
    return 1
  fi
  "${KCTL[@]}" exec -i -n "$NAMESPACE" "$pod" -- gitlab-rails runner -
}
