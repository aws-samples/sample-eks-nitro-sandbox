#!/usr/bin/env bash
# Per-pod outbound connection limit, side by side with an ordinary pod.
#
# Runs the whole connection-limit comparison:
#   1. deploy the namespace, the egress NetworkPolicy, the sink and the two probe
#      pods from a clean slate, and wait for them Ready;
#   2. CONTROL: the ordinary probe opens outbound connections to the sink past the
#      cap with no drop, so the sink and the path are not the bottleneck;
#   3. SYMPTOM: the sandboxed probe plateaus near the documented cap, where new
#      connections hang and time out while the established ones keep working, and
#      the guest's own connection-tracking count reads at its limit at the plateau;
#   4. read the control table and print a verdict.
#
# A confidence gate reads the control before trusting the symptom: if the ordinary
# probe cannot clear the cap against the same sink, the sink or the path is the
# bottleneck and the script fails loudly rather than blaming the sandbox; if the
# sandboxed probe does not plateau either, this cluster is not enforcing the limit
# and the script says so, rather than inventing a number.
#
# It runs read-only kubectl against the current context and applies only this
# sample's own objects in its own namespace.
#
# Usage:
#   scripts/run-conntrack-comparison.sh            # deploy from clean, compare, verdict
#   scripts/run-conntrack-comparison.sh --raised   # also run the optional raised-limit variant
#   scripts/run-conntrack-comparison.sh --cleanup  # delete only this sample's objects
#
# The documented default limit, from the Amazon EKS User Guide (Isolated and
# confidential pods limitations, "Per-pod outbound connection limit"), is 4096
# simultaneous outbound connections per IP address family. The thresholds below are
# derived from it: the control must clear 1.2x the cap with no drop; the symptom
# must plateau within 0.90 to 1.05x the cap; the guest counter must read at least
# 0.95x the cap at the plateau.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$HERE/deploy"
PROBE="$HERE/scripts/probe-conntrack.py"
NS=sandbox-limits
TIMEOUT="${TIMEOUT:-300s}"

CT_CAP=4096                       # documented default, EKS User Guide
MAX_CONN="${MAX_CONN:-6000}"      # offered connection budget, above the cap
CONTROL_MIN=$(( CT_CAP * 12 / 10 ))   # control must clear this with no drop (>= 4915)
SYM_LO=$(( CT_CAP * 90 / 100 ))       # symptom plateau floor (>= 3686)
SYM_HI=$(( CT_CAP * 105 / 100 ))      # symptom plateau ceiling (<= 4300)
CT_MIN=$(( CT_CAP * 95 / 100 ))       # guest counter at plateau (>= 3891)

say()  { printf '\n=== %s ===\n' "$*"; }
line() { printf '%s\n' "$*"; }

# Read the namespace and classify it: "absent", "owned" (carries this sample's
# label), or "foreign". A lookup that cannot run is a failure, not "absent": it
# prints "error" so the caller stops rather than acting on an unknown namespace.
ns_state() {
  local out
  out="$(kubectl get namespace "$NS" --ignore-not-found \
    -o jsonpath='{.metadata.name}/{.metadata.labels.sample}' 2>/dev/null)" || { printf 'error'; return; }
  case "$out" in
    /*|'')              printf 'absent'  ;;  # no name returned: namespace does not exist
    */sandbox-limits)   printf 'owned'   ;;  # carries this sample's label
    *)                  printf 'foreign' ;;  # exists without this sample's label
  esac
}

cleanup() {
  case "$(ns_state)" in
    error)   line "ERROR: could not determine whether namespace $NS is this sample's (kubectl lookup failed); deleted nothing."; exit 1 ;;
    foreign) line "ERROR: namespace $NS exists but is not this sample's (missing label sample=sandbox-limits); deleted nothing."; exit 1 ;;
    absent)  say "Nothing to clean up: namespace $NS is absent"; return 0 ;;
  esac
  say "Cleaning up this sample's objects"
  kubectl delete -f "$DEPLOY/egress-policy.yaml"                     --ignore-not-found
  kubectl delete -f "$DEPLOY/probe-sandboxed-conntrack-raised.yaml"  --ignore-not-found
  kubectl delete -f "$DEPLOY/probe-sandboxed.yaml"                   --ignore-not-found
  kubectl delete -f "$DEPLOY/probe-standard.yaml"                    --ignore-not-found
  kubectl delete -f "$DEPLOY/sink.yaml"                              --ignore-not-found
  kubectl delete -f "$DEPLOY/namespace.yaml"                         --ignore-not-found
}

RAISED=no
case "${1:-}" in
  --cleanup) cleanup; exit 0 ;;
  --raised)  RAISED=yes ;;
  "")        ;;
  *) line "unknown argument: $1"; line "usage: run-conntrack-comparison.sh [--raised|--cleanup]"; exit 64 ;;
esac

# Run the probe inside a pod against the sink IP, echoing one "established=... errno=...
# ct_at_plateau=..." line. Returns the RESULT fields as "established|errno|ct_at_plateau",
# or "error" if the probe did not run.
probe_conntrack() {
  local pod="$1" out rline
  out="$(kubectl -n "$NS" exec -i "$pod" -- env TARGET_IP="$SINK_IP" MAX_CONN="$MAX_CONN" python3 - < "$PROBE" 2>/dev/null)" || {
    printf 'error'; return
  }
  rline="$(sed -n 's/^RESULT //p' <<<"$out" | tail -1)"
  [[ -z "$rline" ]] && { printf 'error'; return; }
  local est err ct
  est="$(sed -n 's/.*established=\([0-9]*\).*/\1/p' <<<"$rline")"
  err="$(sed -n 's/.*errno=\([A-Z]*\).*/\1/p' <<<"$rline")"
  ct="$(sed -n 's/.*ct_at_plateau=\(-\{0,1\}[0-9]*\).*/\1/p' <<<"$rline")"
  printf '%s|%s|%s' "${est:-error}" "${err:-UNKNOWN}" "${ct:--1}"
}

ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }
le() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 <= b+0)}'; }

# --- 1. Deploy from a clean slate ------------------------------------------------------
# Check who owns the namespace ONCE, before deleting or creating anything, and claim an
# absent one at once with `kubectl create`, which fails if anything created it in the
# meantime. A foreign namespace or a lookup that cannot run stops the run here, so the
# clean-slate deletes below only ever act in a namespace this sample owns.
case "$(ns_state)" in
  error)   line "ERROR: could not determine whether namespace $NS is this sample's (kubectl lookup failed); did nothing."; exit 1 ;;
  foreign) line "ERROR: namespace $NS exists but is not this sample's (missing label sample=sandbox-limits)."; line "Delete it, or run on a cluster without it, then re-run."; exit 1 ;;
  absent)  kubectl create -f "$DEPLOY/namespace.yaml" ;;
  owned)   line "reusing namespace $NS (carries this sample's label)" ;;
  *)       line "ERROR: unexpected namespace state for $NS; did nothing."; exit 1 ;;
esac

say "Start from a clean slate (delete any leftover pods and policy from a prior run)"
kubectl delete -f "$DEPLOY/probe-sandboxed-conntrack-raised.yaml" --ignore-not-found --wait=true
kubectl delete -f "$DEPLOY/probe-sandboxed.yaml"                  --ignore-not-found --wait=true
kubectl delete -f "$DEPLOY/probe-standard.yaml"                   --ignore-not-found --wait=true
kubectl delete -f "$DEPLOY/sink.yaml"                             --ignore-not-found --wait=true

say "Deploy the egress NetworkPolicy, the sink and the two probe pods"
# The cluster's DNS address is the kubelet's clusterDNS, the nameserver pods use. EKS Auto
# Mode serves DNS on the node, so the kube-dns Service still carries this address but has no
# endpoints behind it; this reads it from a node's kubelet configuration instead, which is the
# resolver the probe pods themselves use (the kube-dns ClusterIP and the .10 address of the
# cluster's Service CIDR are the same address, and need less permission -- see the page).
# Reading it this way needs permission to list nodes and get nodes/proxy. Nodes are replaced
# often and a node on its way out does not answer, so try the Ready nodes in turn, each with
# a short timeout, and keep the first Ready node whose FIRST clusterDNS entry is a dotted-quad
# IPv4 address. Only the first entry is read, so a dual-stack node listing an IPv6 address first
# is skipped rather than searched for its IPv4 entry. Sets COREDNS_IP,
# DNS_NODE (the node that answered) and DNS_TRIED (the nodes asked, in order).
read_cluster_dns() {
  local node ip nodes
  COREDNS_IP="" DNS_NODE="" DNS_TRIED=""
  nodes="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    | awk '$2 == "True" {print $1}')" || nodes=""
  for node in $nodes; do
    DNS_TRIED="${DNS_TRIED:+$DNS_TRIED }$node"
    ip="$(kubectl get --raw "/api/v1/nodes/$node/proxy/configz" --request-timeout=10s \
      | sed -n 's/.*"clusterDNS":\["\([^"]*\)".*/\1/p')" || ip=""
    # Canonical dotted quad only: every octet alternative is either one digit or starts 1-9,
    # so 999.999.999.999 and a leading-zero form such as 01.2.3.4 are refused by construction
    # rather than by extra clauses bolted on for each. The digits are written out instead of
    # as [0-9] because bash matches a bracket RANGE against the collating order of the current
    # locale: under en_US.utf8, [0-9] also accepts non-ASCII digits, so "1.2.3.<Arabic-Indic 4>"
    # passed here while grep on the page rejected it. An explicit list is the same in every
    # locale and in every grep, including BSD grep on macOS.
    if [[ "$ip" =~ ^((25[012345]|2[01234][0123456789]|1[0123456789][0123456789]|[123456789][0123456789]|[0123456789])\.){3}(25[012345]|2[01234][0123456789]|1[0123456789][0123456789]|[123456789][0123456789]|[0123456789])$ ]]; then
      COREDNS_IP="$ip" DNS_NODE="$node"
      return 0
    fi
    line "  node $node: no IPv4 clusterDNS (read '${ip}'), skipping"
  done
  return 1
}
if ! read_cluster_dns; then
  line "ERROR: could not read the cluster DNS address: none of the Ready nodes answered with an IPv4 clusterDNS."
  line "Ready nodes tried: ${DNS_TRIED:-<no Ready node found>}"
  line "It comes from kubeletconfig.clusterDNS in:"
  line "  kubectl get --raw /api/v1/nodes/<node>/proxy/configz"
  line "Reading it needs permission to list nodes (to find the Ready ones) and to get nodes/proxy. Applied no policy or pod."
  exit 1
fi
sed "s|<COREDNS_IP>|$COREDNS_IP|" "$DEPLOY/egress-policy.yaml" | kubectl apply -f -
kubectl apply -f "$DEPLOY/sink.yaml"
kubectl apply -f "$DEPLOY/probe-standard.yaml"
kubectl apply -f "$DEPLOY/probe-sandboxed.yaml"
[[ "$RAISED" == yes ]] && kubectl apply -f "$DEPLOY/probe-sandboxed-conntrack-raised.yaml"

PODS=(sink probe-standard probe-sandboxed)
[[ "$RAISED" == yes ]] && PODS+=(probe-sandboxed-conntrack-raised)
for p in "${PODS[@]}"; do
  kubectl -n "$NS" wait "pod/$p" --for=condition=Ready --timeout="$TIMEOUT"
done

SINK_IP="$(kubectl -n "$NS" get pod sink -o jsonpath='{.status.podIP}')"
line "sink pod IP: $SINK_IP"

# --- 2-3. The probes -------------------------------------------------------------------
say "CONTROL: ordinary probe opens up to ${MAX_CONN} outbound flows to the sink"
IFS='|' read -r c_est c_err c_ct <<<"$(probe_conntrack probe-standard)"
line "established=${c_est} first-fail-errno=${c_err}"

say "SYMPTOM: sandboxed probe opens up to ${MAX_CONN} outbound flows to the sink"
IFS='|' read -r s_est s_err s_ct <<<"$(probe_conntrack probe-sandboxed)"
line "established=${s_est} first-fail-errno=${s_err} conntrack-count-at-plateau=${s_ct}"

r_est=""; r_err=""; r_ct=""
if [[ "$RAISED" == yes ]]; then
  say "OPTIONAL: sandboxed probe with the limit raised to 8192"
  IFS='|' read -r r_est r_err r_ct <<<"$(probe_conntrack probe-sandboxed-conntrack-raised)"
  line "established=${r_est} first-fail-errno=${r_err} conntrack-count-at-plateau=${r_ct}"
fi

# --- 4. Verdict, reading the control table ---------------------------------------------
say "Results"
printf '%-46s %s\n' "standard, up to ${MAX_CONN} flows (control)" "established=${c_est} new-conn=${c_err}"
printf '%-46s %s\n' "sandbox,  up to ${MAX_CONN} flows (symptom)" "established=${s_est} new-conn=${s_err} ct=${s_ct}"
[[ "$RAISED" == yes ]] && \
printf '%-46s %s\n' "sandbox,  limit raised to 8192"             "established=${r_est} new-conn=${r_err} ct=${r_ct}"

say "Verdict"
if [[ "$c_est" == error || "$s_est" == error ]]; then
  line "RESULT: a probe failed to run. This is not a limit result. Fix the broken probe and re-run."
  exit 5
elif [[ "$c_err" != NONE ]] || ! ge "$c_est" "$CONTROL_MIN"; then
  line "RESULT: the ordinary control opened only ${c_est} flows (needs >= ${CONTROL_MIN} with no"
  line "drop) before failing with ${c_err}. The sink or the path is the bottleneck, not the"
  line "sandbox, so the comparison cannot attribute anything. Re-run with a fresh sink."
  exit 3
elif [[ "$s_err" == NONE ]] && ge "$s_est" "$CONTROL_MIN"; then
  line "RESULT: both the control (${c_est}) and the sandboxed probe (${s_est}) opened the full"
  line "budget with no drop. This cluster build is not enforcing the outbound connection limit: a"
  line "runtime fact, not a sandbox defect, and no number is invented. Nothing to report as a limit."
  exit 4
elif ge "$s_est" "$SYM_LO" && le "$s_est" "$SYM_HI" && [[ "$s_err" == ETIMEDOUT ]] && ge "$s_ct" "$CT_MIN"; then
  line "RESULT: the per-pod outbound connection limit bites on the sandbox path and not on the"
  line "ordinary path. The ordinary control opened ${c_est} flows with no drop; the sandboxed"
  line "probe plateaued at ${s_est} established flows, the next connection timed out (${s_err}),"
  line "and the guest connection-tracking count read ${s_ct} at the plateau, near the documented"
  line "4096 per family (EKS User Guide)."
  [[ "$RAISED" == yes ]] && \
  line "With the limit raised to 8192, the plateau moved to ${r_est}: direct evidence the plateau is that limit."
  exit 0
else
  line "RESULT: unexpected combination: control established=${c_est}/${c_err};"
  line "sandbox established=${s_est}/${s_err} ct=${s_ct}. Inspect the readings above."
  exit 5
fi
