#!/usr/bin/env bash
# Shared setup for the warm-pool-autoscaling-keda scripts: read .env, set names,
# and the readings and guards the other scripts use. Sourced, not run.
#
# Every kubectl call goes through kc(), which pins --context and --namespace, so
# a run never depends on the machine's current context (shared clusters change
# it) or default namespace. Cluster-scoped reads use kc_cluster.
set -euo pipefail

SAMPLE=warm-pool-autoscaling-keda

# The sample's own objects, all inside the sample's own namespace.
POOL=warm-pool
TEMPLATE=warm-pool-agent
SCALEDOBJECT=warm-pool
EXPORTER=claim-exporter
EXPORTER_SRC_CM=claim-exporter-src

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR="$(cd "$HERE/.." && pwd)"

# grep and sed are checked HERE, before .env is read, and not left to
# require_commands further down. The parser below pipes through both inside a
# process substitution, where a failure does not trip `set -e`: a missing grep
# would silently leave .env unread, and the run would then use the default
# namespace and whatever context the machine happens to be on. Every other
# missing command fails the run; this one would have changed which cluster was
# targeted, which is the one failure that must not be quiet.
for _c in grep sed; do
  command -v "$_c" >/dev/null 2>&1 \
    || { echo "error: missing required command: $_c, which is needed to read .env; refusing to fall back to the default namespace and the machine's current context" >&2; exit 1; }
done

# Load .env if present, as defaults. A value already set in the environment wins
# over .env, so `NAMESPACE=other ./scripts/setup.sh` overrides the file.
if [[ -f "$SAMPLE_DIR/.env" ]]; then
  while IFS='=' read -r _k _v; do
    case "$_k" in
      NAMESPACE)    NAMESPACE="${NAMESPACE:-$_v}" ;;
      KUBE_CONTEXT) KUBE_CONTEXT="${KUBE_CONTEXT:-$_v}" ;;
      KEDA_NAMESPACE) KEDA_NAMESPACE="${KEDA_NAMESPACE:-$_v}" ;;
    esac
  done < <(grep -E '^[[:space:]]*(NAMESPACE|KUBE_CONTEXT|KEDA_NAMESPACE)[[:space:]]*=' "$SAMPLE_DIR/.env" \
             | sed -E 's/^[[:space:]]*//; s/[[:space:]]*=[[:space:]]*/=/')
fi

NAMESPACE="${NAMESPACE:-warm-pool-autoscaling-keda}"
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
# Where KEDA is installed. KEDA is a shared install: these scripts only ever
# READ this namespace, to check the operator is there before they create
# anything. They never install, upgrade, reconfigure or remove it.
KEDA_NAMESPACE="${KEDA_NAMESPACE:-keda}"
# The KEDA release this sample was built against. Only used in the message the
# scripts print when KEDA is absent, so the reader installs the pinned version.
KEDA_VERSION=2.21.0
KEDA_CHART_VERSION=2.21.0

# The label on this sample's claims. The exporter counts exactly the claims that
# carry it, so a claim another sample happened to leave in this namespace is not
# read as demand.
CLAIM_SELECTOR="app.kubernetes.io/part-of=$SAMPLE"
# Load-generator claim names: demand-1, demand-2, ... Named, never selected by
# label when deleting, so a delete can only remove the claims this sample made.
CLAIM_PREFIX=demand
# The hard cap on the load the sample generates, so a run on a shared cluster
# cannot ask for more warm capacity than the pool's own maxReplicaCount. Keep it
# at or below the maxReplicaCount in deploy/scaledobject.yaml.
MAX_CLAIMS=3

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

# ---------------------------------------------------------------------------
# The namespace is the mark. This sample creates no AWS resources, so there is
# nothing to tag: the sample's label on its own namespace is what says an object
# is the sample's. A script reuses or deletes the namespace, or anything in it,
# only when the label is present; otherwise it stops. A read that fails means
# "could not determine", which is a failure, never "gone".
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
# that drives demand or deletes things never touches a same-named object in a
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
# KEDA is a shared install, checked and never changed.
# ---------------------------------------------------------------------------
# The command the page tells the reader to run. Printed when KEDA is absent, so
# the message carries the fix and the pinned version.
keda_install_command() {
  cat <<EOF
  helm repo add kedacore https://kedacore.github.io/charts
  helm repo update kedacore
  helm install keda kedacore/keda --namespace $KEDA_NAMESPACE --create-namespace \\
    --version $KEDA_CHART_VERSION --wait
EOF
}

# require_keda : check KEDA is installed and its operator is available, and stop
# with the install command when it is not. It never installs, upgrades or
# reconfigures KEDA: another workload on the cluster may depend on the version
# and the settings that are there. A read that fails stops the run rather than
# being read as "absent", because "absent" would send the reader to install over
# an install that may already exist.
require_keda() {
  local rc=0
  resource_exists kc_cluster crd scaledobjects.keda.sh || rc=$?
  case $rc in
    0) : ;;
    1) die "KEDA is not installed on this cluster (no scaledobjects.keda.sh CRD). This sample needs it, and it is a shared install, so install it yourself at the pinned version rather than having this script do it:
$(keda_install_command)" ;;
    2) die "could not read the cluster's CRDs, so whether KEDA is installed could not be determined; stopping rather than guess" ;;
  esac

  # The CRD alone is not enough: a ScaledObject with no operator running is an
  # object nothing reconciles, and the pool would simply never move.
  local avail arc=0
  avail="$(kc_cluster -n "$KEDA_NAMESPACE" get deploy keda-operator \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" || arc=$?
  [[ $arc -ne 0 ]] && die "the KEDA CRDs are installed but deploy/keda-operator could not be read in namespace $KEDA_NAMESPACE. If KEDA lives in another namespace on this cluster, set KEDA_NAMESPACE in .env."
  [[ "$avail" == "True" ]] || die "deploy/keda-operator in namespace $KEDA_NAMESPACE is not Available (condition: ${avail:-<none>}), so nothing would act on a ScaledObject. Check it with: kubectl -n $KEDA_NAMESPACE get deploy,pods"

  # The metrics apiserver is what the HPA reads the trigger's value from. Without
  # it the HPA reports a metric error and never writes spec.replicas.
  local mavail mrc=0
  mavail="$(kc_cluster -n "$KEDA_NAMESPACE" get deploy keda-operator-metrics-apiserver \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" || mrc=$?
  [[ $mrc -ne 0 ]] && die "deploy/keda-operator-metrics-apiserver could not be read in namespace $KEDA_NAMESPACE; the HPA reads the trigger's value from it, so stopping rather than create a ScaledObject nothing can serve."
  [[ "$mavail" == "True" ]] || die "deploy/keda-operator-metrics-apiserver in namespace $KEDA_NAMESPACE is not Available (condition: ${mavail:-<none>}), so the HPA could not read the trigger's value. Check it with: kubectl -n $KEDA_NAMESPACE get deploy,pods"

  local ver
  ver="$(kc_cluster -n "$KEDA_NAMESPACE" get deploy keda-operator \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  echo "reusing the KEDA install in namespace $KEDA_NAMESPACE as it is (${ver:-image unreadable}); this sample was built against KEDA $KEDA_VERSION"
}

# ---------------------------------------------------------------------------
# Pool readings. spec.replicas is the SCALING DECISION the KEDA-created HPA
# writes; status.readyReplicas is the capacity OUTCOME, which lags it and which
# the pool's own replenishment maintains without any scaling decision. Every
# assertion in these scripts is on spec.replicas; readyReplicas is printed
# beside it so the two are never confused.
# ---------------------------------------------------------------------------
# pool_spec_replicas : retry on an empty read, so a transient API blip is never
# read as "0 replicas", which would satisfy a "scaled back down" wait on no
# evidence. Prints nothing and returns non-zero if still empty after the retries.
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

# claim_count : how many of this sample's claims exist. Prints the count, or
# nothing and returns non-zero when the read FAILED.
#
# `kubectl ... | grep -c .` cannot be used on its own here: grep prints 0 and
# succeeds whatever kubectl did, so a failed read would be indistinguishable from
# "no claims" and would satisfy the baseline assertion on no evidence. Take the
# output and kubectl's status first, then count.
claim_count() {
  local out rc=0
  out="$(kc get sandboxclaims -l "$CLAIM_SELECTOR" -o name 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && return 1
  printf '%s' "$(printf '%s' "$out" | grep -c . || true)"
}

# exporter_metric : the claim count the exporter last served, read from its own
# timestamped log line. The readiness probe polls /metrics every 5 seconds, so
# this is always fresh, and it is the same signal KEDA's trigger reads.
exporter_metric() {
  kc logs "deploy/$EXPORTER" --tail=1 2>/dev/null || true
}

# wait_exporter_metric <n> <timeout-s> : wait until the exporter's last log line
# reports n claims, so a reading taken right after the claims were created is the
# exporter's answer to the new demand and not its answer to the old. Returns
# non-zero on timeout; the caller prints whatever it got either way.
#
# A line carrying ` error=` does not count, even when its number is the one we
# want. On an API error the exporter serves its last good count, so that line is
# the count it remembers rather than the count it just read. The control asserts
# on this to establish that the demand signal KEDA would have read was really
# there, and a remembered number is not that.
wait_exporter_metric() {
  local want=$1 timeout=${2:-60} line
  local deadline=$((SECONDS + timeout))
  while :; do
    line="$(exporter_metric)"
    [[ "$line" == *"active_claims=$want "* && "$line" != *" error="* ]] && return 0
    ((SECONDS >= deadline)) && return 1
    sleep 2
  done
}

# print_stage "<label>" : one reading line, with the decision and the outcome
# side by side and the demand that produced them. A read that failed shows as "?"
# and never as 0, so a reading line can never be mistaken for a measurement that
# was taken.
print_stage() {
  local sr rr cc
  sr="$(pool_spec_replicas)" || sr="?"
  rr="$(pool_ready_replicas)" || rr="?"
  cc="$(claim_count)" || cc="?"
  printf '  [reading] %-10s spec.replicas=%s  status.readyReplicas=%s  claims=%s\n' \
    "$1" "${sr:-?}" "${rr:-?}" "${cc:-?}"
}

# hpa_for_pool : the name of the HPA whose scaleTargetRef names our pool. Prints
# the name, prints nothing when there is no such HPA, and returns NON-ZERO when
# the read failed. The distinction matters: a caller that reads a failed list as
# "no HPA" would report "nothing is autoscaling the pool" having established
# nothing, which is the one thing the control must never do.
# The newline in the range is a separator, not decoration: without it two HPAs
# that both target the pool would come back as one run-together word, which every
# caller would then print as a single impossible name and pass to `kubectl get
# hpa`. Separated, the same case is visibly two names and still fails closed.
hpa_for_pool() {
  local out rc=0
  out="$(kc get hpa -o jsonpath="{range .items[?(@.spec.scaleTargetRef.name=='$POOL')]}{.metadata.name}{\"\n\"}{end}" 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && return 1
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# The bounded load generator.
# ---------------------------------------------------------------------------
# claim_manifest <n> : one SandboxClaim document on standard output.
claim_manifest() {
  cat <<EOF
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: ${CLAIM_PREFIX}-${1}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: ${SAMPLE}
spec:
  warmPoolRef:
    name: ${POOL}
EOF
}

# create_claim_fresh <n> : create ONE claim with `create`, not `apply`, so a claim
# of that name that already exists makes this FAIL instead of being quietly
# updated. The adoption readings in demand.sh depend on the claim being new: an
# `apply` over a claim left by an earlier run would keep that claim's own
# creationTimestamp and its already-Ready condition, and the adoption checks would
# all pass without a single thing having been adopted.
create_claim_fresh() {
  claim_manifest "$1" | kc create -f - >/dev/null
}

# make_claims <n> : bring the demand up to n claims, clamped to MAX_CLAIMS.
#
# It creates the claims that are absent and leaves the ones that are there,
# rather than applying over them. Nothing here ever uses `kubectl apply` on a
# claim: applying over a claim created with `create` warns about the missing
# last-applied-configuration annotation, and, worse, it is the operation that
# would let a claim from an earlier run stand in for one this run made.
# Returns non-zero if any claim could not be created or read.
make_claims() {
  local n=$1 i rc=0 crc
  ((n > MAX_CLAIMS)) && n=$MAX_CLAIMS
  for ((i = 1; i <= n; i++)); do
    crc=0; resource_exists kc "sandboxclaim/${CLAIM_PREFIX}-${i}" || crc=$?
    case $crc in
      0) : ;;   # already there: leave it, it is this sample's demand either way
      1) create_claim_fresh "$i" || rc=1 ;;
      2) echo "  could not read sandboxclaim/${CLAIM_PREFIX}-${i}; not creating over it" >&2
         rc=1 ;;
    esac
  done
  return $rc
}

# delete_claims : delete this sample's claims BY EXACT NAME, never by label
# selector, so a delete can only ever remove the claims this sample made.
# Returns kubectl's status; callers that go on to read a claim must also call
# wait_claims_gone, because this does not wait.
delete_claims() {
  local names=() i
  for ((i = 1; i <= MAX_CLAIMS; i++)); do names+=("${CLAIM_PREFIX}-${i}"); done
  # --request-timeout because the control calls this from inside a trap that
  # ignores INT, TERM and HUP, where a hung call could only be escaped with a
  # SIGKILL.
  kc delete sandboxclaim "${names[@]}" --ignore-not-found --wait=false \
    --request-timeout=30s >/dev/null 2>&1
}

# wait_claims_gone <timeout-s> : wait until none of this sample's demand claims
# exist, by exact name. A read that fails keeps waiting rather than concluding
# they are gone, and a timeout returns non-zero.
wait_claims_gone() {
  local timeout=${1:-120} i rc left
  local deadline=$((SECONDS + timeout))
  while :; do
    left=""
    for ((i = 1; i <= MAX_CLAIMS; i++)); do
      rc=0; resource_exists kc "sandboxclaim/${CLAIM_PREFIX}-${i}" || rc=$?
      case $rc in
        0) left+=" ${CLAIM_PREFIX}-${i}" ;;
        2) left+=" ${CLAIM_PREFIX}-${i}(unreadable)" ;;
      esac
    done
    [[ -z "$left" ]] && return 0
    ((SECONDS >= deadline)) && { printf '  still present:%s\n' "$left"; return 1; }
    sleep 3
  done
}

# wait_spec_replicas "<test expression using \$v>" <timeout-s> : wait until the
# pool's spec.replicas satisfies the expression. An empty read is "unknown",
# never 0, so a blip cannot satisfy a "<=" condition on no evidence.
wait_spec_replicas() {
  local expr=$1 timeout=${2:-180} v
  local deadline=$((SECONDS + timeout))
  while :; do
    v="$(pool_spec_replicas)" || v=""
    if [[ -n "$v" ]] && eval "[[ $expr ]]"; then return 0; fi
    ((SECONDS >= deadline)) && return 1
    sleep 5
  done
}

# wait_pool_warm <timeout-s> : wait until readyReplicas meets spec.replicas with
# nothing terminating, so the pool is genuinely warm at whatever size it is.
# Every one of the three reads fails closed: a read that failed leaves the loop
# waiting rather than concluding the pool is warm.
wait_pool_warm() {
  local timeout=${1:-600} ready want pods prc terminating
  local deadline=$((SECONDS + timeout))
  while :; do
    ready="$(pool_ready_replicas)" || ready=""
    want="$(pool_spec_replicas)" || want=""
    # Take the pod list and kubectl's status before filtering: a failed list
    # produces no output, which would otherwise read as "nothing terminating".
    prc=0
    pods="$(kc get pods \
      -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}' \
      2>/dev/null)" || prc=$?
    if [[ $prc -ne 0 ]]; then
      terminating="?"
    else
      terminating="$(printf '%s' "$pods" | grep "^${POOL}-" | tr '\n' ' ' || true)"
    fi
    if [[ -n "$ready" && -n "$want" && "$ready" == "$want" && "$ready" != "0" \
          && -z "$terminating" ]]; then
      return 0
    fi
    printf '  readyReplicas=%s/%s%s\n' "${ready:-?}" "${want:-?}" \
      "${terminating:+ (terminating: $terminating)}"
    ((SECONDS >= deadline)) && return 1
    sleep 5
  done
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
