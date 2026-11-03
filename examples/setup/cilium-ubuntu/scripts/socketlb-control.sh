#!/usr/bin/env bash
# The socketLB.hostNamespaceOnly negative control, as a reader step: run it after the first
# ./test.sh, then run ./test.sh again. It BRIEFLY BREAKS Service routing for the sandbox pod on
# this sample's own cluster, shows that, and puts the setting back.
#
#   ./scripts/socketlb-control.sh
#
# 1. Ownership, before any change. It stops, changing nothing, unless every check passes:
#    the caller is in AWS_ACCOUNT_ID (common.sh's require_caller_account); cluster CLUSTER_NAME
#    is ACTIVE and tagged Demo=setup-cilium-ubuntu (the mark setup.sh and clean.sh check); the
#    current context of this sample's own kubeconfig (KUBECONFIG, pinned by common.sh) points at
#    that cluster's endpoint; the Helm release is cilium in kube-system, chart cilium-1.20.2,
#    deployed; its values are exactly setup.sh's (socketLB.hostNamespaceOnly true) and both
#    agents read Socket LB Coverage Hostns-only; the demo namespace carries the sample's label
#    and test.sh's pods are running; and the sandbox pod reaches the ClusterIP Service and the
#    kube-dns Service, so a loss after the change is the change's.
# 2. Off: the same helm upgrade setup.sh step 3 runs (release, chart, version, values file and
#    --set arguments), with only --set socketLB.hostNamespaceOnly=false added; then it waits for
#    the agents to roll.
# 3. Read and probe: both agents must read Socket LB Coverage Full, which kpr-status refuses.
#    From the sandbox pod, the ordinary pod on the sandbox node, the ordinary pod on the system
#    node and the sandbox node's own network namespace (node-probe), it probes the server pod
#    IP, the ClusterIP Service, DNS through the kube-dns Service and DNS at the CoreDNS pod IP.
#    Only the sandbox pod's ClusterIP and kube-dns Service probes must time out; every other
#    probe must succeed.
# 4. Back on, from a trap on EXIT, INT and TERM, so it runs however the script ends once the
#    change has started: the same upgrade without the override, the roll, then both agents
#    must read Hostns-only (kpr-status accepts) and the release's values must be setup.sh's.
#    The restore runs in a session of its own, so a second Ctrl-C or TERM cannot stop it.
# A probe counts as timed out only when its output is the client's own timeout line, plus at
# most kubectl exec's exit line; anything else in it, such as an API error, is a failure.
#
# Exit codes: 0 every expectation held and the restore is verified. 1 checked, and the cluster,
# kube context, release or demo is not the sample's or not in the state setup.sh and test.sh
# leave; nothing changed. 2 could not check (a read failed or came back empty); nothing changed.
# 3 the control did not show what it must (an expectation failed, or a read after the change
# was empty or failed); the restore is verified. 4 the restore failed or could not be verified;
# this overrides every other code, and the message gives the command to restore by hand. An
# interruption after the change exits 130 (INT) or 143 (TERM) once the restore is verified.
#
# It is not on setup.sh's or test.sh's path: test.sh stays read-only.
set -uo pipefail
SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "$SAMPLE_DIR/scripts/common.sh"

ts() { date -u +%FT%TZ; }
refuse() { printf '%s %s\n' "$(_red 'REFUSED:')" "$*" >&2; echo "Nothing was changed (exit 1)." >&2; exit 1; }
cannot() { printf '%s %s\n' "$(_red 'COULD NOT CHECK:')" "$*" >&2; echo "Nothing was changed (exit 2)." >&2; exit 2; }

# The values check: the release's user-supplied values (helm get values -o json) against
# cilium-values.yaml plus the --set values setup.sh step 3 passes. 0 equal, 1 differ, 2 no JSON.
VALUES_PY=$(cat <<'PY'
import json, sys
import yaml
text, values_file, cluster, host, owner = sys.argv[1:6]
try:
    actual = json.loads(text)
except ValueError as e:
    print(f"helm get values returned no JSON ({e})")
    sys.exit(2)
if not isinstance(actual, dict):
    print("helm get values returned no values")
    sys.exit(2)
want = yaml.safe_load(open(values_file)) or {}
sets = [(("cluster", "name"), cluster), (("k8sServiceHost",), host)]
if owner:
    sets.append((("eni", "eniTags", "Owner"), owner))
def get(d, path):
    for k in path:
        if not isinstance(d, dict) or k not in d:
            return None
        d = d[k]
    return d
def put(d, path, value):
    for k in path[:-1]:
        d = d.setdefault(k, {})
    d[path[-1]] = value
for path, value in sets:
    put(want, path, value)
    got = get(actual, path)
    if got is not None and not isinstance(got, (dict, list)):
        put(actual, path, str(got))  # Helm types a --set value; setup.sh passes each as text
problems = []
def walk(a, b, at):
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b), key=str):
            walk(a.get(k, "(absent)"), b.get(k, "(absent)"), at + [str(k)])
    elif a != b:
        problems.append(f"{'.'.join(at)} is {json.dumps(a)}, setup.sh's is {json.dumps(b)}")
walk(actual, want, [])
hns = get(actual, ("socketLB", "hostNamespaceOnly"))
if hns is not True:
    print(f"socketLB.hostNamespaceOnly is {json.dumps(hns)}, not setup.sh's true")
for p in problems[:8]:
    print(p)
if problems or hns is not True:
    sys.exit(1)
print("the release's values are setup.sh's (socketLB.hostNamespaceOnly true)")
PY
)
values_check() { python3 -c "$VALUES_PY" "$1" "$SAMPLE_DIR/cilium-values.yaml" "$CLUSTER_NAME" "$host" "${OWNER_TAG:-}"; }

# node_agent <sandbox|system>: prints "<node> <agent pod>"; 2 when a read fails, 1 when there is
# not exactly one node in the group or one Cilium agent on it (the reason is printed).
node_agent() {
  local node agents
  node="$(kubectl get nodes -l "eks.amazonaws.com/nodegroup=$1" -o 'jsonpath={.items[*].metadata.name}' 2>&1)" \
    || { echo "could not read the $1 node: $node"; return 2; }
  [[ -n "$node" && "$node" != *" "* ]] || { echo "expected exactly one $1 node, found '${node}'"; return 1; }
  agents="$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector "spec.nodeName=$node" \
    -o 'jsonpath={.items[*].metadata.name}' 2>&1)" || { echo "could not read the agent on $node: $agents"; return 2; }
  [[ -n "$agents" && "$agents" != *" "* ]] \
    || { echo "expected exactly one Cilium agent on the $1 node $node, found '${agents}'"; return 1; }
  echo "$node $agents"
}

# read_agent <sandbox|system> <Hostns-only|Full> [brief]: the agent's Socket LB lines and
# kpr-status (with brief, one line). 0 as wanted; 1 another coverage; 2 the read failed or was empty.
read_agent() {
  local group=$1 want=$2 brief=${3:-} na node agent raw rrc kpr krc cov
  na="$(node_agent "$group")"; rrc=$?
  if ((rrc != 0)); then echo "== $(ts) $group node: $na"; return 2; fi
  node="${na% *}" agent="${na#* }"
  raw="$(kubectl -n kube-system exec "$agent" -c cilium-agent -- cilium-dbg status --verbose 2>&1)"; rrc=$?
  kpr="$(python3 "$PY" kpr-status <<<"$raw" 2>&1)"; krc=$?
  cov="$(sed -n 's/^  Socket LB Coverage:[[:space:]]*//p' <<<"$raw" | head -n1)"
  if [[ -n "$brief" ]]; then
    echo "== $(ts) $agent ($group node $node): Socket LB Coverage ${cov:-(none)}, kpr-status rc=$krc"
  else
    echo "== $(ts) $agent ($group node $node): Socket LB lines of cilium-dbg status --verbose"
    grep -E '^KubeProxyReplacement:|^  Status:|^  Socket LB' <<<"$raw"
    echo "-- kpr-status:"
    echo "$kpr"
    echo "kpr-status rc=$krc"
  fi
  if ((rrc != 0)) || [[ -z "$raw" ]] || ((krc == 2)); then
    echo "   UNEXPECTED: the read of $agent failed or was empty (rc=$rrc), so nothing was checked"
    return 2
  fi
  if [[ "$want" == Full ]] && ((krc == 1)) && [[ "$cov" == Full ]]; then
    echo "   as expected: coverage Full, which kpr-status refuses"
  elif [[ "$want" == Hostns-only ]] && ((krc == 0)) && [[ "$cov" == Hostns-only ]]; then
    echo "   as expected: coverage Hostns-only, which kpr-status accepts"
  else
    echo "   UNEXPECTED: wanted coverage $want, got '${cov:-no Socket LB Coverage line}' with kpr-status rc=$krc"
    return 1
  fi
}

# The clients' own timeout lines, as busybox wget and nslookup print them in the sample's pods.
WGET_TIMEOUT='wget: download timed out'
DNS_TIMEOUT=';; connection timed out; no servers could be reached'
# timed_out <client line> <output> <rc>: 0 when the probe failed and its nonblank output is that
# line alone, or that line and kubectl exec's own "command terminated with exit code <rc>", in
# either order (kubectl writes the pod's output and its own line on separate streams). Any other
# line, such as an API error from kubectl, makes it a failure, not a timeout.
timed_out() {
  local lines w="command terminated with exit code $3"
  (($3 != 0)) || return 1
  lines="$(grep -v '^[[:space:]]*$' <<<"$2")"
  [[ "$lines" == "$1" || "$lines" == "$1"$'\n'"$w" || "$lines" == "$w"$'\n'"$1" ]]
}

# probe <pod> <pod-ip|clusterip|kube-dns|coredns> <ok|timeout>: one probe, one line. 0 when it
# came out as wanted. Sets GOT to ok, timeout or failed (any other answer, or none).
GOT=""
probe() {
  local pod=$1 what=$2 want=$3 label out rc answer
  case "$what" in
    pod-ip) label="-> server pod IP $server_ip:8080"
      out="$(kubectl -n "$NAMESPACE" exec "$pod" -- wget -q -T 5 -O - "http://$server_ip:8080/" 2>&1)"; rc=$? ;;
    clusterip) label="-> ClusterIP $cluster_ip:80"
      out="$(kubectl -n "$NAMESPACE" exec "$pod" -- wget -q -T 5 -O - "http://$cluster_ip/" 2>&1)"; rc=$? ;;
    kube-dns) label="nslookup $fqdn via kube-dns Service $kube_dns_ip"
      out="$(kubectl -n "$NAMESPACE" exec "$pod" -- timeout 20 nslookup "$fqdn" "$kube_dns_ip" 2>&1)"; rc=$? ;;
    coredns) label="nslookup $fqdn via CoreDNS pod $coredns_ip"
      out="$(kubectl -n "$NAMESPACE" exec "$pod" -- timeout 20 nslookup "$fqdn" "$coredns_ip" 2>&1)"; rc=$? ;;
  esac
  GOT=failed
  case "$what" in
    pod-ip|clusterip)
      if ((rc == 0)) && [[ "$out" == server ]]; then GOT=ok
      elif timed_out "$WGET_TIMEOUT" "$out" "$rc"; then GOT=timeout; fi ;;
    *)
      answer="$(awk '/^Name:/{named=1; next} named && /^Address:/{print $2}' <<<"$out" | head -n1)"
      if ((rc == 0)) && [[ "$answer" == "$cluster_ip" ]]; then GOT=ok
      elif timed_out "$DNS_TIMEOUT" "$out" "$rc"; then GOT=timeout; fi ;;
  esac
  printf '%-10s %s rc=%s want=%s got=%s%s out=%s\n' "$pod" "$label" "$rc" "$want" "$GOT" \
    "$([[ "$GOT" == "$want" ]] || echo ' UNEXPECTED')" "$(tr '\n' ' ' <<<"$out")"
  [[ "$GOT" == "$want" ]]
}

# wait_for_agents: the roll after an upgrade, then both agents report OK.
wait_for_agents() {
  local i g na ok
  echo "== $(ts) waiting for the agents to roll"
  kubectl -n kube-system rollout status daemonset/cilium --timeout=10m || return 1
  kubectl -n kube-system rollout status deployment/cilium-operator --timeout=10m || return 1
  for ((i = 0; i < 30; i++)); do
    ok=0
    for g in sandbox system; do
      na="$(node_agent "$g")" \
        && [[ "$(kubectl -n kube-system exec "${na#* }" -c cilium-agent -- cilium-dbg status --brief 2>/dev/null)" == OK ]] \
        && ok=$((ok + 1))
    done
    if ((ok == 2)); then echo "both agents report OK"; return 0; fi
    sleep 10
  done
  echo "the two agents did not both report OK within 5 minutes"
  return 1
}

# helm_upgrade [extra args...]: setup.sh step 3's upgrade, with any extra arguments added.
helm_upgrade() {
  local out rc
  echo "== $(ts) helm upgrade: setup.sh step 3's command${*:+, plus $*}"
  out="$(helm "${helm_args[@]}" "$@" 2>&1)"; rc=$?
  echo "helm rc=$rc$(sed -n 's/^REVISION: */, revision /p' <<<"$out" | head -n1)"
  ((rc == 0)) || { tail -n 20 <<<"$out" | sed 's/^/    /'; return 1; }
}

restore() {
  local g bad=0 vals
  helm_upgrade || return 1
  wait_for_agents || return 1
  for g in sandbox system; do read_agent "$g" Hostns-only brief || bad=$((bad + 1)); done
  ((bad == 0)) || { echo "   $bad agent(s) do not read Hostns-only after the restore"; return 1; }
  vals="$(helm -n kube-system get values cilium -o json 2>&1)" || { echo "could not read the release's values: $vals"; return 1; }
  values_check "$vals"
}

# insulate <command...>: runs it in a session of its own and waits for it. Ctrl-C reaches every
# process in the terminal's foreground job, and helm and kubectl handle INT and TERM themselves
# (a Go program that asks for a signal gets it even when this shell ignores it), so ignoring
# them here does not protect the restore; a separate session does. setsid (util-linux) keeps the
# INT and TERM this shell ignores ignored; where it is missing (macOS), Python does the same,
# ignoring both itself, since Python replaces an inherited SIGINT disposition with its own.
INSULATE_PY='import signal, subprocess, sys
signal.signal(signal.SIGINT, signal.SIG_IGN); signal.signal(signal.SIGTERM, signal.SIG_IGN)
sys.exit(subprocess.call(sys.argv[1:], start_new_session=True))'
insulate() {
  if command -v setsid >/dev/null 2>&1; then setsid --wait "$@"; else python3 -c "$INSULATE_PY" "$@"; fi
}

CHANGED=0 RESULT=""
on_exit() {
  local rc=$? kc
  trap - EXIT
  trap '' INT TERM
  if ((CHANGED)); then
    case "$rc" in 130) echo; echo "INTERRUPTED (INT): restoring before exit" ;; 143) echo; echo "INTERRUPTED (TERM): restoring before exit" ;; esac
    step "back on: the same upgrade without the override, in a session of its own (Ctrl-C cannot stop it)"
    export -f restore helm_upgrade wait_for_agents node_agent read_agent values_check ts
    export VALUES_PY PY SAMPLE_DIR CLUSTER_NAME OWNER_TAG host HELM_ARGS_DECL="$(declare -p helm_args)"
    if insulate bash -c 'set -uo pipefail; eval "$HELM_ARGS_DECL"; restore'; then
      echo "restore verified: both agents read Hostns-only and the release's values are setup.sh's"
    else
      rc=4
      printf '\n%s\n' "$(_red "RESTORE FAILED OR UNVERIFIED on cluster $CLUSTER_NAME: socketLB.hostNamespaceOnly may still be false, and then the sandbox pod cannot reach any Service.")" >&2
      # Each command names this sample's kubeconfig, so a shell whose context is another cluster's
      # cannot run the restore there.
      kc="KUBECONFIG=$(printf '%q' "$KUBECONFIG")"
      echo "Restore it by hand, then check it with ./test.sh:" >&2
      printf '  %s %s\n' "$kc" "$(printf '%q ' helm "${helm_args[@]}")" >&2
      printf '  %s kubectl -n kube-system rollout status daemonset/cilium --timeout=10m\n' "$kc" >&2
      echo "Or run ./setup.sh again: its step 3 runs the same upgrade." >&2
    fi
  fi
  case "$rc" in
    0) echo "socketlb-control: PASS: the negative control showed what it must, and the restore is verified (exit 0)" ;;
    3) echo "socketlb-control: INCONCLUSIVE: $RESULT; the restore is verified (exit 3)" ;;
    4) echo "socketlb-control: RESTORE FAILED (exit 4)${RESULT:+; the control itself: $RESULT}" ;;
    130|143) echo "socketlb-control: INTERRUPTED; the restore is verified (exit $rc)" ;;
    *) echo "socketlb-control: stopped with exit $rc after the change; the restore is verified" ;;
  esac
  exit "$rc"
}

# --- 1. ownership, before any change ----------------------------------------------------------
step "1. ownership: is this the sample's cluster, release and demo, in the state setup.sh and test.sh leave?"
for cmd in aws helm kubectl python3; do
  command -v "$cmd" >/dev/null 2>&1 || cannot "$cmd is required but was not found on PATH"
done
[[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || cannot "AWS_ACCOUNT_ID is not set in config.local.env"
account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || cannot "could not read the caller's account (no AWS credentials?)"
[[ "$account" =~ ^[0-9]{12}$ ]] || cannot "the caller's account read back as '$account'"
(require_caller_account) || refuse "the caller is not in AWS_ACCOUNT_ID (above)"
cl_rc=0
cl="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" \
  --query "[cluster.status, cluster.tags.$DEMO_TAG_KEY, cluster.endpoint]" --output text 2>&1)" || cl_rc=$?
if ((cl_rc != 0)); then
  grep -q 'ResourceNotFoundException' <<<"$cl" && refuse "cluster $CLUSTER_NAME does not exist; run ./setup.sh first"
  cannot "could not read cluster $CLUSTER_NAME: $cl"
fi
read -r cl_status cl_demo endpoint <<<"$cl"
[[ "$cl_status" == ACTIVE ]] || refuse "cluster $CLUSTER_NAME is ${cl_status:-unreadable}, not ACTIVE"
[[ "$cl_demo" == "$DEMO_TAG_VAL" ]] \
  || refuse "cluster $CLUSTER_NAME is not tagged $DEMO_TAG_KEY=$DEMO_TAG_VAL (it has '$cl_demo'); it is not this sample's"
[[ "$endpoint" == https://* ]] || cannot "cluster $CLUSTER_NAME's endpoint read back as '$endpoint'"
host="${endpoint#https://}"
echo "cluster $CLUSTER_NAME: ACTIVE, tagged $DEMO_TAG_KEY=$DEMO_TAG_VAL"
[[ -s "$KUBECONFIG" ]] || cannot "$KUBECONFIG is missing; run ./setup.sh first"
context="$(kubectl config current-context 2>&1)" || cannot "no current context in $KUBECONFIG: $context"
server="$(kubectl config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>&1)" \
  || cannot "could not read the current context's server from $KUBECONFIG: $server"
[[ -n "$server" ]] || cannot "the current context in $KUBECONFIG names no server"
[[ "$(tr '[:upper:]' '[:lower:]' <<<"$server")" == "$(tr '[:upper:]' '[:lower:]' <<<"$endpoint")" ]] \
  || refuse "the current context in $KUBECONFIG ($context) points at $server, not cluster $CLUSTER_NAME's endpoint"
echo "kube context: $context, in $KUBECONFIG, points at cluster $CLUSTER_NAME"
rel="$(helm -n kube-system list --filter '^cilium$' -o json 2>&1)" || cannot "could not list the Helm releases in kube-system: $rel"
rel_rc=0
rel_line="$(python3 -c '
import json, sys
try:
    rels = json.loads(sys.argv[1])
except ValueError:
    sys.exit(2)
rels = [r for r in rels if r.get("name") == "cilium" and r.get("namespace") == "kube-system"]
if len(rels) != 1:
    print("none"); sys.exit(1)
r = rels[0]
print(r.get("chart", ""), r.get("status", ""), r.get("revision", ""))
' "$rel" 2>&1)" || rel_rc=$?
((rel_rc == 2)) && cannot "helm list returned no JSON: $rel"
((rel_rc == 0)) || refuse "there is no Helm release cilium in kube-system; setup.sh step 3 installs it"
read -r rel_chart rel_status rel_rev <<<"$rel_line"
[[ "$rel_chart" == "cilium-$CILIUM_VERSION" && "$rel_status" == deployed ]] \
  || refuse "Helm release cilium in kube-system is chart $rel_chart ($rel_status), not setup.sh's cilium-$CILIUM_VERSION, deployed"
echo "Helm release cilium in kube-system: chart $rel_chart, $rel_status, revision $rel_rev"
vals="$(helm -n kube-system get values cilium -o json 2>&1)" || cannot "could not read the release's values: $vals"
v_rc=0; v_out="$(values_check "$vals")" || v_rc=$?
echo "$v_out"
((v_rc == 2)) && cannot "could not read the release's values (above)"
((v_rc == 0)) || refuse "the release's values are not setup.sh's (above), so this is not the state the control starts from"
for g in sandbox system; do
  a_rc=0; a_out="$(read_agent "$g" Hostns-only brief)" || a_rc=$?
  echo "$a_out"
  ((a_rc == 2)) && cannot "could not read the $g node's agent (above)"
  ((a_rc == 0)) || refuse "the $g node's agent does not read setup.sh's Hostns-only (above)"
done
ns_rc=0; namespace_is_ours || ns_rc=$?
case "$ns_rc" in
  0) echo "namespace $NAMESPACE carries $NS_LABEL_KEY=$NS_LABEL_VAL" ;;
  1) refuse "namespace $NAMESPACE exists but is not labelled $NS_LABEL_KEY=$NS_LABEL_VAL; it is not this sample's" ;;
  2) cannot "could not read namespace $NAMESPACE" ;;
  *) refuse "namespace $NAMESPACE does not exist; run ./test.sh first, which creates the demo pods this control probes from" ;;
esac
for pod in nitro neighbor control node-probe server; do
  phase="$(kubectl -n "$NAMESPACE" get pod "$pod" -o 'jsonpath={.status.phase}' 2>/dev/null)"
  [[ "$phase" == Running ]] || refuse "pod/$pod in $NAMESPACE is not Running (${phase:-absent}); run ./test.sh first"
done
server_ip="$(kubectl -n "$NAMESPACE" get pod server -o 'jsonpath={.status.podIP}' 2>/dev/null)"
cluster_ip="$(kubectl -n "$NAMESPACE" get service server -o 'jsonpath={.spec.clusterIP}' 2>/dev/null)"
kube_dns_ip="$(kubectl -n kube-system get service kube-dns -o 'jsonpath={.spec.clusterIP}' 2>/dev/null)"
coredns_ip="$(kubectl -n kube-system get pods -l k8s-app=kube-dns -o 'jsonpath={.items[0].status.podIP}' 2>/dev/null)"
fqdn="server.$NAMESPACE.svc.cluster.local"
[[ -n "$server_ip" && -n "$cluster_ip" && -n "$kube_dns_ip" && -n "$coredns_ip" ]] \
  || cannot "could not read the server pod IP, the server ClusterIP, the kube-dns Service IP or the CoreDNS pod IP"
echo "== $(ts) server pod $server_ip, Service server ClusterIP $cluster_ip, kube-dns $kube_dns_ip, CoreDNS pod $coredns_ip"
for what in clusterip kube-dns; do
  if ! probe nitro "$what" ok; then
    [[ "$GOT" == timeout ]] || cannot "the sandbox pod's $what probe failed before any change (above)"
    refuse "with setup.sh's value the sandbox pod already loses the $what probe (above), so the control would prove nothing; run ./test.sh"
  fi
done

helm_args=(upgrade --install cilium "$CILIUM_CHART" --version "$CILIUM_VERSION" --namespace kube-system
  -f "$SAMPLE_DIR/cilium-values.yaml" --set "cluster.name=$CLUSTER_NAME" --set "k8sServiceHost=$host")
[[ -z "$OWNER_TAG" ]] || helm_args+=(--set "eni.eniTags.Owner=$OWNER_TAG")

# --- 2. off: from here on, the trap restores setup.sh's value however the script ends ----------
trap on_exit EXIT
trap 'trap "" INT TERM; exit 130' INT  # ignore a second signal before on_exit sets that itself
trap 'trap "" INT TERM; exit 143' TERM
CHANGED=1
step "2. off: socketLB.hostNamespaceOnly=false (this briefly breaks Service routing for the sandbox pod)"
if ! helm_upgrade --set socketLB.hostNamespaceOnly=false; then
  RESULT="the off upgrade failed (above)"; exit 3
fi
if ! wait_for_agents; then
  RESULT="the agents did not roll after the off upgrade (above)"; exit 3
fi

# --- 3. read and probe ------------------------------------------------------------------------
step "3. read and probe: both agents must read Full; only the sandbox pod loses the ClusterIP and the kube-dns Service"
bad=0
for g in sandbox system; do read_agent "$g" Full || bad=$((bad + 1)); done
echo "== $(ts) server pod $server_ip, Service server ClusterIP $cluster_ip, kube-dns $kube_dns_ip, CoreDNS pod $coredns_ip"
for pod in nitro neighbor control node-probe; do
  for what in pod-ip clusterip kube-dns coredns; do
    want=ok
    [[ "$pod" == nitro && ( "$what" == clusterip || "$what" == kube-dns ) ]] && want=timeout
    probe "$pod" "$what" "$want" || bad=$((bad + 1))
  done
done
if ((bad > 0)); then
  RESULT="$bad expectation(s) above did not hold (marked UNEXPECTED)"; exit 3
fi
echo "both agents read Full; the sandbox pod lost the ClusterIP and the kube-dns Service and kept both pod IPs; every other lane kept all four"
exit 0
