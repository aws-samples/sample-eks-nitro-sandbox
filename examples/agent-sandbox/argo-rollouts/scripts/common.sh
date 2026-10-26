#!/usr/bin/env bash
# Shared setup for the argo-rollouts scripts: read .env, set names, and the
# readings and guards the other scripts use. Sourced, not run.
#
# Every kubectl call goes through kc(), which pins --context and --namespace, so
# a run never depends on the machine's current context (shared clusters change
# it) or default namespace. Cluster-scoped reads use kc_cluster.
set -euo pipefail

SAMPLE=argo-rollouts

# The sample's own objects, all inside the sample's own namespace.
TEMPLATE=rollout-agent
POOL=rollout-agent-pool
ROLLOUT=template-bump
ORDINARY_POD=ordinary-pod

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR="$(cd "$HERE/.." && pwd)"

# Load .env if present, as defaults. A value already set in the environment wins
# over .env, so `NAMESPACE=other ./scripts/setup.sh` overrides the file.
#
# This parses with bash builtins only, reading the file through a plain
# redirect, and deliberately uses NO pipeline and NO process substitution. In
# `< <(grep ... | sed ...)` a failure does not trip `set -e` and does not reach
# the loop: an unreadable file, or a missing grep, simply delivers nothing, and
# the run then falls back to the default namespace and whatever context the
# machine happens to be on. That is the one failure that must never be quiet,
# because it changes which cluster is targeted. A redirect from a file that
# cannot be read fails the command, so `set -e` stops the run; the explicit test
# below says why rather than leaving a bare redirect error.
if [[ -f "$SAMPLE_DIR/.env" ]]; then
  [[ -r "$SAMPLE_DIR/.env" ]] \
    || { echo "error: $SAMPLE_DIR/.env exists but cannot be read; refusing to fall back to the default namespace and the machine's current context" >&2; exit 1; }
  # `|| [[ -n "$_line" ]]` so a final line with no newline is still read.
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    # Trim surrounding whitespace, then skip blanks and whole-line comments. An
    # inline "#" is NOT treated as a comment: it would silently truncate a value
    # that legitimately contains one.
    _line="${_line#"${_line%%[![:space:]]*}"}"
    _line="${_line%"${_line##*[![:space:]]}"}"
    [[ -z "$_line" || "$_line" == '#'* ]] && continue
    [[ "$_line" != *=* ]] && continue
    _k="${_line%%=*}"
    _v="${_line#*=}"
    _k="${_k%"${_k##*[![:space:]]}"}"
    _v="${_v#"${_v%%[![:space:]]*}"}"
    case "$_k" in
      NAMESPACE)      NAMESPACE="${NAMESPACE:-$_v}" ;;
      KUBE_CONTEXT)   KUBE_CONTEXT="${KUBE_CONTEXT:-$_v}" ;;
      ARGO_NAMESPACE) ARGO_NAMESPACE="${ARGO_NAMESPACE:-$_v}" ;;
      AWS_REGION)     AWS_REGION="${AWS_REGION:-$_v}" ;;
      PLUGIN_REPO)    PLUGIN_REPO="${PLUGIN_REPO:-$_v}" ;;
    esac
  done < "$SAMPLE_DIR/.env"
fi

NAMESPACE="${NAMESPACE:-argo-rollouts-sample}"
# The namespace name goes into `sed s/__NAMESPACE__/$NAMESPACE/` when the scripts
# render their manifests, where `/` would end the expression and `&` would expand
# to the matched text, so a name carrying either would quietly produce a
# different manifest from the one you asked for. A Kubernetes namespace can only
# be a DNS label anyway, so requiring that here costs nothing and keeps the
# substitution safe.
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || {
  echo "error: NAMESPACE must be a DNS label (lower-case letters, digits and dashes, starting and ending alphanumeric, at most 63 characters); got '$NAMESPACE'" >&2
  exit 1
}
# The context the run pins. Set KUBE_CONTEXT to the kube context of the cluster
# you ran Getting started on. Empty means "use the current context", which the
# scripts then print so you can see which cluster they used.
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
# Where Argo Rollouts is installed. Argo Rollouts is a shared install: these
# scripts only ever READ this namespace to check the controller is there, except
# for register-step-plugin.sh, which is the page's own reader step and says so.
ARGO_NAMESPACE="${ARGO_NAMESPACE:-argo-rollouts}"
# The Argo Rollouts release this sample was built against. Used in the message
# the scripts print when Argo Rollouts is absent, so the reader installs the
# pinned version, and in the plugin's go.mod.
ARGO_ROLLOUTS_VERSION=v1.10.1
# The agent-sandbox release Getting started > Warm pool installs.
AGENT_SANDBOX_VERSION=v1.0.6

# The step names registered in the controller's ConfigMap and named in
# deploy/rollout.yaml. The prefix before the slash is required by Argo Rollouts
# and is an opaque string it never resolves: it is NOT a Kubernetes namespace, so
# it does not change when NAMESPACE is overridden.
STEP_PATCH=eks-nitro-sandbox/sandbox-template-patch
STEP_DRAIN=eks-nitro-sandbox/sandbox-warmpool-drain
# The staged binary, and where the controller reads it from.
PLUGIN_BIN=sandbox-warmpool-stepplugin
PLUGIN_PATH="/plugins/$PLUGIN_BIN"

# The labels the agent-sandbox controller sets on pool sandboxes at run time.
# LABEL_TEMPLATE_HASH is SandboxTemplateHashLabel in agent-sandbox
# api/v1beta1/sandbox_types.go at v1.0.6; the controller computes it over the
# template's SandboxBlueprint, of which podTemplate is a field, so a change to a
# container's env moves it. It is set by the controller, so it is not in the
# release manifest.
LABEL_POOL_SANDBOX="agents.x-k8s.io/warm-pool-sandbox"
LABEL_TEMPLATE_HASH="agents.x-k8s.io/sandbox-template-hash"
# The same key with its dots escaped, for jsonpath.
LABEL_TEMPLATE_HASH_JP="agents\\.x-k8s\\.io/sandbox-template-hash"

# The revision marker the sample reads by value, and the file the container
# writes it to at boot.
REVISION_ENV=TEMPLATE_REVISION
REVISION_FILE=/tmp/template-revision

# AWS values, used only by register-step-plugin.sh and cleanup.sh. The plugin
# image has to come from a repository the CLUSTER can pull, so the registration
# builds it and pushes it to Amazon ECR in your own account.
AWS_REGION="${AWS_REGION:-}"
PLUGIN_REPO="${PLUGIN_REPO:-nitro-sample-argo-rollouts-stepplugin}"
# The tag that marks the ECR repository as this sample's. Nothing is reused or
# deleted without it.
MANAGED_BY="$SAMPLE"

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

# join_lines : read newline-separated values on standard input and print them on
# one line, comma separated. The readings below return one value per line because
# that is what sorting and counting them needs, but a message that embeds one
# reads as two messages unless it is joined first.
join_lines() { paste -sd, - | sed 's/,/, /g'; }

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

# ---------------------------------------------------------------------------
# The namespace is the mark for everything inside it. The ECR repository, which
# is outside the cluster, carries a ManagedBy tag instead, and the two
# cluster-scoped RBAC objects carry the sample's label. A script reuses or
# deletes an object only when its mark is present; otherwise it stops. A read
# that fails means "could not determine", which is a failure, never "gone".
# ---------------------------------------------------------------------------
NS_LABEL_KEY="app.kubernetes.io/managed-by"
NS_LABEL_VAL="$SAMPLE"

# namespace_is_ours return codes, so callers can tell the cases apart:
#   0  the namespace exists and carries our label  (it is the sample's)
#   1  the namespace exists but does not carry our label  (someone else's)
#   2  the namespace exists but its labels could not be read  (could not tell)
#   3  the namespace does not exist
namespace_is_ours() {
  local out rc
  local key_esc="${NS_LABEL_KEY//./\\.}"   # dots in a label key are escaped in jsonpath
  out="$(kc_cluster get namespace "$NAMESPACE" --ignore-not-found \
    -o "jsonpath={.metadata.labels.${key_esc}}{\"|\"}{.metadata.name}" 2>/dev/null)"
  rc=$?
  [[ $rc -ne 0 ]] && return 2        # the read itself failed: could not determine
  [[ "$out" == "|" || -z "$out" ]] && return 3   # --ignore-not-found printed nothing
  local label="${out%%|*}"
  [[ "$label" == "$NS_LABEL_VAL" ]]
}

# require_our_namespace : stop unless this sample owns the namespace, so a script
# that drives a rollout or deletes things never touches a same-named object in a
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

# resource_exists <runner> <kind/name...> : a failure-aware existence check, so a
# failed read is never mistaken for "absent" or "gone".
#   0  it exists    1  it does not exist    2  the read failed
resource_exists() {
  local runner=$1; shift
  local out rc
  out="$("$runner" get "$@" --ignore-not-found -o name 2>/dev/null)"
  rc=$?
  [[ $rc -ne 0 ]] && return 2
  [[ -n "$out" ]]
}

# ---------------------------------------------------------------------------
# agent-sandbox and Argo Rollouts are shared installs, checked and never changed.
# ---------------------------------------------------------------------------
# require_agent_sandbox : the controller and the three extension CRDs this sample
# uses. Getting started > Warm pool is where they are installed.
require_agent_sandbox() {
  # Every check here tells "it is not there" apart from "the cluster could not be
  # reached". `kubectl get ... || die "not found"` cannot: expired credentials or
  # an unreachable API server both come back non-zero, and the reader is then
  # told to install something that may already be installed, on a cluster this
  # script never actually read. resource_exists returns 2 for a failed read, and
  # a failed read is never an answer.
  local rc=0
  resource_exists kc_cluster runtimeclass isolated-sandbox || rc=$?
  case $rc in
    1) die "runtimeclass isolated-sandbox not found on this cluster; run the Hello sandbox sample first" ;;
    2) die "could not read the cluster's runtime classes, so whether isolated-sandbox exists could not be determined. Check that your credentials are current and that the context is the cluster you mean:
  kubectl ${KUBE_CONTEXT:+--context $KUBE_CONTEXT }get runtimeclass" ;;
  esac

  local crd
  for crd in sandboxtemplates.extensions.agents.x-k8s.io \
             sandboxwarmpools.extensions.agents.x-k8s.io \
             sandboxclaims.extensions.agents.x-k8s.io; do
    rc=0
    resource_exists kc_cluster crd "$crd" || rc=$?
    case $rc in
      1) die "the agent-sandbox CRD $crd is not installed. Install agent-sandbox $AGENT_SANDBOX_VERSION as Getting started > Warm pool step 1 does:
  kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/$AGENT_SANDBOX_VERSION/sandbox-with-extensions.yaml" ;;
      2) die "could not read the cluster's CRDs, so whether agent-sandbox is installed could not be determined; stopping rather than tell you to install over an install that may already be there" ;;
    esac
  done
}

# The command the page tells the reader to run. Printed when Argo Rollouts is
# absent, so the message carries the fix and the pinned version.
argo_install_command() {
  cat <<EOF
  kubectl create namespace $ARGO_NAMESPACE
  kubectl -n $ARGO_NAMESPACE apply --server-side -f \\
    https://github.com/argoproj/argo-rollouts/releases/download/$ARGO_ROLLOUTS_VERSION/install.yaml
  kubectl -n $ARGO_NAMESPACE rollout status deploy/argo-rollouts --timeout=180s
EOF
}

# require_argo_rollouts : check Argo Rollouts is installed and its controller is
# available, and stop with the install command when it is not. It never installs,
# upgrades or reconfigures Argo Rollouts: another workload on the cluster may
# depend on the version and the settings that are there. A read that fails stops
# the run rather than being read as "absent", because "absent" would send the
# reader to install over an install that may already exist.
require_argo_rollouts() {
  local rc=0
  resource_exists kc_cluster crd rollouts.argoproj.io || rc=$?
  case $rc in
    0) : ;;
    1) die "Argo Rollouts is not installed on this cluster (no rollouts.argoproj.io CRD). This sample needs it, and it is a shared install, so install it yourself at the pinned version rather than having this script do it:
$(argo_install_command)" ;;
    2) die "could not read the cluster's CRDs, so whether Argo Rollouts is installed could not be determined; stopping rather than guess" ;;
  esac

  # The CRD alone is not enough: a Rollout with no controller running is an
  # object nothing reconciles, and the steps would simply never run.
  local avail arc=0
  avail="$(kc_cluster -n "$ARGO_NAMESPACE" get deploy argo-rollouts \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" || arc=$?
  [[ $arc -ne 0 ]] && die "the Argo Rollouts CRDs are installed but deploy/argo-rollouts could not be read in namespace $ARGO_NAMESPACE. If Argo Rollouts lives in another namespace on this cluster, set ARGO_NAMESPACE in .env."
  [[ "$avail" == "True" ]] || die "deploy/argo-rollouts in namespace $ARGO_NAMESPACE is not Available (condition: ${avail:-<none>}), so nothing would act on a Rollout. Check it with: kubectl -n $ARGO_NAMESPACE get deploy,pods"

  local ver
  ver="$(kc_cluster -n "$ARGO_NAMESPACE" get deploy argo-rollouts \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  echo "reusing the Argo Rollouts install in namespace $ARGO_NAMESPACE as it is (${ver:-image unreadable}); this sample was built against Argo Rollouts $ARGO_ROLLOUTS_VERSION"
}

# registered_step_plugins : the step-plugin names the controller's ConfigMap
# holds, one per line. Prints them, or prints nothing and returns NON-ZERO when
# the ConfigMap could not be read. The distinction matters: a caller that read a
# failed read as "nothing registered" would send the reader to register over a
# registration that may already be there.
#   0  read it (output may be empty, meaning the key is absent)
#   1  the ConfigMap does not exist
#   2  the read failed
registered_step_plugins() {
  local out rc=0
  out="$(kc_cluster -n "$ARGO_NAMESPACE" get configmap argo-rollouts-config \
    --ignore-not-found -o jsonpath='{.data.stepPlugins}' 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && return 2
  # --ignore-not-found prints nothing for an absent ConfigMap, which is not the
  # same as a ConfigMap with no stepPlugins key, so ask separately.
  local nsrc=0
  resource_exists kc_cluster -n "$ARGO_NAMESPACE" configmap argo-rollouts-config || nsrc=$?
  case $nsrc in
    1) return 1 ;;
    2) return 2 ;;
  esac
  # The value is a YAML list of entries; take the `name:` of each. Strip comments
  # first so a commented-out name is never read as a registered one, and anchor
  # the pattern so it cannot match a `name:` nested under something else.
  printf '%s' "$out" | sed -E 's/#.*$//' | grep -E '^[[:space:]]*-[[:space:]]*name:' \
    | sed -E 's/^[[:space:]]*-[[:space:]]*name:[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//' || true
}

# registered_step_plugin_locations : one "<name> <location>" line per registered
# entry, so a caller can tell "our step name is registered" apart from "our step
# name is registered and points at our binary". Same return codes as
# registered_step_plugins.
registered_step_plugin_locations() {
  local out rc=0
  out="$(kc_cluster -n "$ARGO_NAMESPACE" get configmap argo-rollouts-config \
    --ignore-not-found -o jsonpath='{.data.stepPlugins}' 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && return 2
  local nsrc=0
  resource_exists kc_cluster -n "$ARGO_NAMESPACE" configmap argo-rollouts-config || nsrc=$?
  case $nsrc in
    1) return 1 ;;
    2) return 2 ;;
  esac
  # Pair each "- name:" with the "location:" that follows it, before the next
  # entry starts. Comments are stripped first so a commented-out line is never
  # read as real, and both patterns are anchored.
  printf '%s' "$out" | sed -E 's/#.*$//' | awk '
    /^[[:space:]]*-[[:space:]]*name:/ {
      if (n != "") print n, l
      n = $0; sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", n)
      gsub(/^"|"$|[[:space:]]+$/, "", n); l = ""
      next
    }
    /^[[:space:]]*location:/ {
      l = $0; sub(/^[[:space:]]*location:[[:space:]]*/, "", l)
      gsub(/^"|"$|[[:space:]]+$/, "", l)
      next
    }
    END { if (n != "") print n, l }
  ' || true
}

# require_step_plugin : check the plugin is registered on the controller, that
# the registration points at THIS sample's binary, that the controller has the
# RBAC the plugin needs, and that the binary is staged where the ConfigMap says
# it is.
#
# The registration is a PREREQUISITE the reader performs, like the controller
# install itself: it changes the controller's own ConfigMap and Deployment and
# adds a cluster-scoped ClusterRole, all of which every Rollout on the cluster
# shares. So this only ever READS, and stops with the command when a part is
# missing. It never applies any of it, and the clean up never undoes it.
require_step_plugin() {
  local names rc=0
  names="$(registered_step_plugins)" || rc=$?
  case $rc in
    1) die "the Argo Rollouts controller has no argo-rollouts-config ConfigMap, so this sample's step plugin is not registered. It is a prerequisite you run yourself, because it changes a controller the whole cluster shares:
  ./scripts/register-step-plugin.sh          # plan: changes nothing
  ./scripts/register-step-plugin.sh apply" ;;
    2) die "could not read configmap argo-rollouts-config in namespace $ARGO_NAMESPACE, so whether the step plugin is registered could not be determined; stopping rather than guess" ;;
  esac

  local want missing=()
  for want in "$STEP_PATCH" "$STEP_DRAIN"; do
    printf '%s\n' "$names" | grep -Fxq "$want" || missing+=("$want")
  done
  if ((${#missing[@]})); then
    die "the Argo Rollouts controller does not have this sample's step plugin registered (missing: ${missing[*]}).
It currently registers: ${names:-<none>}
The registration is a prerequisite you run yourself, because it changes a controller the
whole cluster shares:
  ./scripts/register-step-plugin.sh          # plan: changes nothing
  ./scripts/register-step-plugin.sh apply"
  fi

  # Our step names being present is not the same as them pointing at our binary.
  # A registration that names this sample's steps against somebody else's image
  # is NOT this sample's registration, and running the rollout against it would
  # execute code this sample did not build. Stop and say what was found rather
  # than overwrite it: that is the owner's choice, not this script's.
  local pairs prc=0
  pairs="$(registered_step_plugin_locations)" || prc=$?
  [[ $prc -eq 2 ]] && die "could not read the step-plugin locations from configmap argo-rollouts-config in namespace $ARGO_NAMESPACE; stopping rather than guess"
  local pname ploc
  while read -r pname ploc; do
    [[ -z "$pname" ]] && continue
    [[ "$pname" == "$STEP_PATCH" || "$pname" == "$STEP_DRAIN" ]] || continue
    [[ "$ploc" == "file://$PLUGIN_PATH" ]] && continue
    die "step plugin $pname is registered on the controller in namespace $ARGO_NAMESPACE, but against
  $ploc
rather than this sample's
  file://$PLUGIN_PATH
So the registration under that name is not this sample's. Changing it would change a
controller other workloads depend on, which is a question for whoever owns that install.
Nothing has been created."
  done <<<"$pairs"

  # The RBAC the plugin acts with. Without it the steps fail at the API call
  # rather than at load, which reads as a broken drain instead of a missing grant.
  # Both halves are checked: a binding with no role grants nothing.
  local obj crrc
  for obj in clusterrole clusterrolebinding; do
    crrc=0
    resource_exists kc_cluster "$obj" argo-rollouts-sandbox-warmpool || crrc=$?
    case $crrc in
      1) die "$obj argo-rollouts-sandbox-warmpool is missing, so the Argo Rollouts controller has no permission on the agent-sandbox CRDs and both plugin steps would fail. It is part of the registration prerequisite:
  ./scripts/register-step-plugin.sh apply" ;;
      2) die "could not read $obj argo-rollouts-sandbox-warmpool; stopping rather than guess" ;;
    esac
  done

  # The binary the ConfigMap points at. A registration whose location does not
  # resolve on the controller pod makes the controller fail the step with a load
  # error, which is the least obvious of the three failures from the outside.
  #
  # The controller image is distroless, so there is no shell, and no `test`
  # binary, to exec into it and ask whether the file is there. The signal that
  # does not need one is the initContainer that stages the binary: it runs `cp`
  # and the kubelet records its exit code, so a zero there IS the binary being in
  # place. An absent status means the staging initContainer is not on the pod at
  # all, which is a registration that was never finished.
  local pod prc=0
  pod="$(kc_cluster -n "$ARGO_NAMESPACE" get pods -l app.kubernetes.io/name=argo-rollouts \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || prc=$?
  [[ $prc -ne 0 || -z "$pod" ]] && die "could not find the Argo Rollouts controller pod in namespace $ARGO_NAMESPACE, so whether the plugin binary is staged could not be determined"
  local code crc=0
  code="$(kc_cluster -n "$ARGO_NAMESPACE" get pod "$pod" \
    -o 'jsonpath={.status.initContainerStatuses[?(@.name=="copy-sandbox-warmpool-plugin")].state.terminated.exitCode}' 2>/dev/null)" || crc=$?
  [[ $crc -ne 0 ]] && die "could not read the init container statuses on controller pod $pod, so whether the plugin binary is staged could not be determined"
  [[ -n "$code" ]] \
    || die "controller pod $pod has no completed copy-sandbox-warmpool-plugin init container, so the plugin binary the ConfigMap registers is not staged at $PLUGIN_PATH. Re-run the registration:
  ./scripts/register-step-plugin.sh apply"
  [[ "$code" == "0" ]] \
    || die "the copy-sandbox-warmpool-plugin init container on controller pod $pod exited $code, so the plugin binary was not staged at $PLUGIN_PATH. Check 'kubectl -n $ARGO_NAMESPACE logs $pod -c copy-sandbox-warmpool-plugin'"
  echo "the step plugin is registered and staged at $PLUGIN_PATH on $pod"
}

# ---------------------------------------------------------------------------
# Pool and template readings. Each one tells a failed read apart from a real
# answer, because the whole sample is a comparison of values: a read that quietly
# came back empty would make two revisions look equal.
# ---------------------------------------------------------------------------

# template_revision : the revision marker the SandboxTemplate NOW holds, read
# from the API. This is the "what the template says" side of the comparison.
# Prints the value; prints nothing and returns non-zero when the read failed or
# the marker is absent.
template_revision() {
  local v rc=0
  v="$(kc get sandboxtemplate "$TEMPLATE" \
    -o jsonpath="{.spec.podTemplate.spec.containers[0].env[?(@.name=='$REVISION_ENV')].value}" 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 || -z "$v" ]] && return 1
  printf '%s' "$v"
}

# pool_spec_replicas : the pool's requested size, and the value the drain
# restores. Retry on an empty read, so a transient API blip is never read as
# "0 replicas", which would make the drain think there is nothing to drain.
pool_spec_replicas() {
  local v i
  for i in 1 2 3; do
    v="$(kc get sandboxwarmpool "$POOL" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    sleep 1
  done
  return 1
}

# pool_ready_replicas : the capacity outcome. Prints the count, or nothing and
# returns non-zero when the read FAILED. An absent field is a real answer, none
# ready, and prints 0; a failed read is not, and callers must map it to "?"
# rather than to 0.
pool_ready_replicas() {
  local v rc=0
  v="$(kc get sandboxwarmpool "$POOL" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && return 1
  printf '%s' "${v:-0}"
}

# pool_selector : the label selector for this pool's sandboxes, built from the
# pool's status.selector. The controller reports it as
# agents.x-k8s.io/warm-pool-sandbox=<hash of the pool name>, so the value is
# parsed out rather than assumed to be the pool name.
#
# It prints nothing and returns non-zero when the selector is absent or not yet
# in key=value form. Callers must treat that as "not ready", NEVER as "matches
# nothing": an empty selector passed to `kubectl get -l` would match every
# sandbox in the namespace, and an empty result would then read as a drained pool.
pool_selector() {
  local sel rc=0
  sel="$(kc get sandboxwarmpool "$POOL" -o jsonpath='{.status.selector}' 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && return 1
  [[ "$sel" != *=* ]] && return 1
  local hash="${sel#*=}"
  [[ -z "$hash" ]] && return 1
  printf '%s=%s' "$LABEL_POOL_SANDBOX" "$hash"
}

# pool_sandbox_count : how many sandboxes the pool still has, counting a
# Terminating one as present, because a claim could otherwise race onto a pod
# that is going away. Prints the count; returns non-zero when the read failed or
# the selector is not readable.
pool_sandbox_count() {
  local sel out rc=0
  sel="$(pool_selector)" || return 1
  out="$(kc get sandbox -l "$sel" -o name 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && return 1
  printf '%s' "$(printf '%s' "$out" | grep -c . || true)"
}

# pool_template_hashes : the distinct, non-empty template-hash values across the
# pool's sandboxes, one per line. This is the Kubernetes-observable witness: it
# is readable before anything claims a pod. Returns non-zero when the read
# failed or the selector is not readable.
pool_template_hashes() {
  local sel out rc=0
  sel="$(pool_selector)" || return 1
  out="$(kc get sandbox -l "$sel" \
    -o "jsonpath={range .items[*]}{.metadata.labels.$LABEL_TEMPLATE_HASH_JP}{\"\\n\"}{end}" 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && return 1
  printf '%s' "$out" | grep -v '^$' | sort -u || true
}

# pool_sandbox_revisions : the distinct revision markers the pool's sandboxes
# were BOOTED with, one per line, read from each Sandbox's own resolved
# podTemplate rather than from inside a guest, so it needs no exec.
#
# This is what makes the drain a real no-op when there is nothing to do: if every
# pool sandbox already booted with the revision the template now holds, the pool
# is current and draining it would destroy warm capacity for nothing. Returns
# non-zero when the read failed or the selector is not readable.
pool_sandbox_revisions() {
  local sel out rc=0
  sel="$(pool_selector)" || return 1
  out="$(kc get sandbox -l "$sel" \
    -o "jsonpath={range .items[*]}{.spec.podTemplate.spec.containers[0].env[?(@.name=='$REVISION_ENV')].value}{\"\\n\"}{end}" 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && return 1
  printf '%s' "$out" | grep -v '^$' | sort -u || true
}

# pool_sandbox_revisions_each / pool_hashes_each : ONE LINE PER POOL SANDBOX,
# holding that sandbox's revision marker (or template hash) followed by a "|".
# Unlike the de-duplicated readings above, these neither drop the sandboxes that
# reported nothing nor collapse duplicates, which is what lets a caller tell
# "every sandbox reported" apart from "the ones that reported agree".
#
# The trailing "|" is load-bearing. A missing value has to stay visible, and a
# bare empty line cannot do that: `$(...)` strips trailing newlines, so a pool
# whose LAST sandbox had no marker would come back indistinguishable from one
# with no such sandbox at all. With the delimiter every line is non-empty, so
# nothing is lost, and "|" on its own means "this sandbox reported nothing".
pool_sandbox_revisions_each() {
  local sel out rc=0
  sel="$(pool_selector)" || return 1
  out="$(kc get sandbox -l "$sel" \
    -o "jsonpath={range .items[*]}{.spec.podTemplate.spec.containers[0].env[?(@.name=='$REVISION_ENV')].value}{\"|\\n\"}{end}" 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && return 1
  printf '%s' "$out"
}

pool_hashes_each() {
  local sel out rc=0
  sel="$(pool_selector)" || return 1
  out="$(kc get sandbox -l "$sel" \
    -o "jsonpath={range .items[*]}{.metadata.labels.$LABEL_TEMPLATE_HASH_JP}{\"|\\n\"}{end}" 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && return 1
  printf '%s' "$out"
}

# all_agree_on <expected> : read "<value>|" lines on standard input, one per
# sandbox, and succeed only when there is at least one, none of them is empty,
# and all of them equal <expected>. With <expected> empty, any single shared
# value will do.
#
# This is the check that stops a pool holding one pod at the new revision and one
# that reported nothing from looking converged.
all_agree_on() {
  local expected="${1:-}" line val first="" n=0
  while IFS= read -r line; do
    val="${line%|}"
    [[ -z "$val" ]] && return 1           # a sandbox that reported nothing
    n=$((n + 1))
    [[ -z "$first" ]] && first="$val"
    [[ "$val" == "$first" ]] || return 1  # two sandboxes disagree
  done
  ((n > 0)) || return 1                   # no sandboxes at all
  [[ -z "$expected" || "$first" == "$expected" ]]
}

# pool_is_current : 0 when every pool sandbox booted with the revision the
# template now holds, 1 when at least one did not, and 2 when that could not be
# determined. A pool with no sandboxes at all is NOT current (1): there is
# nothing warm, so the re-warm half of the drain still has work to do, and
# neither is a pool holding a sandbox whose marker could not be read.
pool_is_current() {
  local want each
  want="$(template_revision)" || return 2
  each="$(pool_sandbox_revisions_each)" || return 2
  all_agree_on "$want" <<<"$each"
}

# wait_pool_warm <timeout-s> : wait until readyReplicas meets spec.replicas with
# one consistent template hash across the pool. Every read fails closed: a read
# that failed leaves the loop waiting rather than concluding the pool is warm.
wait_pool_warm() {
  local timeout=${1:-900} ready want each hashes count agreed
  local deadline=$((SECONDS + timeout))
  while :; do
    ready="$(pool_ready_replicas)" || ready=""
    want="$(pool_spec_replicas)" || want=""
    # The hash condition is "every pool sandbox carries the same, non-empty
    # hash", not "the hashes I could read were all the same": a sandbox with no
    # hash label yet is one that has not converged.
    each="$(pool_hashes_each)" || each=""
    agreed=1
    [[ -n "$each" ]] && { all_agree_on "" <<<"$each" && agreed=0; }
    hashes="$(pool_template_hashes)" || hashes=""
    count="$(printf '%s' "$hashes" | grep -c . || true)"
    if [[ -n "$ready" && -n "$want" && "$ready" == "$want" && "$ready" != "0" \
          && "$agreed" -eq 0 ]]; then
      return 0
    fi
    printf '  readyReplicas=%s/%s  distinct template hashes=%s\n' \
      "${ready:-?}" "${want:-?}" "${count:-0}"
    ((SECONDS >= deadline)) && return 1
    sleep 5
  done
}

# ---------------------------------------------------------------------------
# Claiming, and reading the marker by value from inside the guest.
# ---------------------------------------------------------------------------

# claim_manifest <name> : one SandboxClaim document on standard output.
claim_manifest() {
  cat <<EOF
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: ${1}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: ${SAMPLE}
spec:
  warmPoolRef:
    name: ${POOL}
EOF
}

# claim_fresh <name> : create ONE claim with `create`, not `apply`, so a claim of
# that name left by an earlier run makes this FAIL instead of being quietly
# updated. Every reading that follows depends on the claim being new: an `apply`
# over an old claim would keep its already-adopted pod, and the revision read
# from it would be the old run's answer.
claim_fresh() {
  claim_manifest "$1" | kc create -f - >/dev/null
}

# claim_pod <name> : the pod the claim adopted, from status.sandbox.name. Prints
# nothing and returns non-zero when the read failed or nothing is adopted yet.
claim_pod() {
  local v rc=0
  v="$(kc get sandboxclaim "$1" -o jsonpath='{.status.sandbox.name}' 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 || -z "$v" ]] && return 1
  printf '%s' "$v"
}

# pod_revision_env <pod> : the marker as the environment variable, read from
# inside the guest. Returns non-zero when the exec failed, so an unreachable pod
# is never reported as an empty revision.
pod_revision_env() {
  local v rc=0
  v="$(kc exec "$1" -- printenv "$REVISION_ENV" 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 || -z "$v" ]] && return 1
  printf '%s' "$v"
}

# pod_revision_file <pod> : the marker as the file the container wrote at boot.
# This is the provenance reading: the value is whatever the pod booted with, so
# it cannot be confused with a value changed on the template since.
pod_revision_file() {
  local v rc=0
  v="$(kc exec "$1" -- cat "$REVISION_FILE" 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 || -z "$v" ]] && return 1
  printf '%s' "$v"
}

# pod_launch_type <pod> : the agents.x-k8s.io/launch-type label, which the
# controller sets to "warm" on a sandbox a warm pool booted. It is what says the
# claim adopted a pod that was already running rather than cold-starting one.
pod_launch_type() {
  local v rc=0
  v="$(kc get sandbox "$1" -o 'jsonpath={.metadata.labels.agents\.x-k8s\.io/launch-type}' 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 || -z "$v" ]] && return 1
  printf '%s' "$v"
}

# pod_template_hash <pod> : the template-hash label on the Sandbox of that name.
#
# This works only on a sandbox still IN the pool. When a claim adopts one, the
# controller takes the pool labels off it (both warm-pool-sandbox and
# sandbox-template-hash) and adds claim-uid in their place, so the hash witness
# has to be read from the pool BEFORE the claim, which is what the page does.
pod_template_hash() {
  local v rc=0
  v="$(kc get sandbox "$1" -o "jsonpath={.metadata.labels.$LABEL_TEMPLATE_HASH_JP}" 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 || -z "$v" ]] && return 1
  printf '%s' "$v"
}

# wait_claim_ready <name> <timeout-s> : wait for the claim to report Ready and
# name an adopted pod. A failed read keeps waiting rather than giving up.
wait_claim_ready() {
  local name=$1 timeout=${2:-120} cond
  local deadline=$((SECONDS + timeout))
  while :; do
    cond="$(kc get sandboxclaim "$name" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [[ "$cond" == "True" ]] && claim_pod "$name" >/dev/null; then return 0; fi
    ((SECONDS >= deadline)) && return 1
    sleep 2
  done
}

# report_claim <name> : the four readings that say which template revision a
# claimed pod came from, printed together. A read that failed shows as "?" and
# never as an empty value, so two revisions can never look equal because one of
# them could not be read.
report_claim() {
  local name=$1 pod env_v file_v hash
  pod="$(claim_pod "$name")" || pod=""
  [[ -z "$pod" ]] && { echo "  claim $name has not adopted a pod"; return 1; }
  env_v="$(pod_revision_env "$pod")" || env_v="?"
  file_v="$(pod_revision_file "$pod")" || file_v="?"
  hash="$(pod_template_hash "$pod")" || hash="?"
  printf '  claim %s -> pod %s\n' "$name" "$pod"
  printf '    %s (env)          = %s\n' "$REVISION_ENV" "$env_v"
  printf '    %s (file at boot) = %s\n' "$REVISION_FILE" "$file_v"
  printf '    %s = %s\n' "$LABEL_TEMPLATE_HASH" "$hash"
}

# ---------------------------------------------------------------------------
# Assertions. Each one prints PASS or FAIL with what it read, and the script
# that sources this owns the exit code through assert_summary.
# ---------------------------------------------------------------------------
ASSERT_PASS=0
ASSERT_FAIL=0
assert() {  # assert <0-or-nonzero> "<what was asserted>"
  if [[ "$1" -eq 0 ]]; then
    ASSERT_PASS=$((ASSERT_PASS + 1))
    printf '  PASS  %s\n' "$2"
  else
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    printf '  FAIL  %s\n' "$2" >&2
  fi
}
assert_summary() {  # assert_summary "<what the run was about>"
  echo
  if [[ $ASSERT_FAIL -ne 0 ]]; then
    printf '%d/%d checks passed: %s\n' "$ASSERT_PASS" "$((ASSERT_PASS + ASSERT_FAIL))" "$1" >&2
    return 1
  fi
  printf '%d/%d checks passed: %s\n' "$ASSERT_PASS" "$ASSERT_PASS" "$1"
}
