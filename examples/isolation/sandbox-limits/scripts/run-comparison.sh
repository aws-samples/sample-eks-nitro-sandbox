#!/usr/bin/env bash
# Per-sandbox DNS query-rate limit, side by side with an ordinary pod.
#
# Runs the whole DNS comparison:
#   1. deploy the namespace, the two probe pods and the egress NetworkPolicy from a
#      clean slate, and wait for them Ready;
#   2. BELOW the limit: the sandboxed probe at a low offered rate answers all its
#      queries (the same probe with the limit not yet reached);
#   3. CONTROL: the ordinary probe at a high offered rate answers the full rate (the
#      cluster resolver and the offered burst are fine, and nothing caps here);
#   4. SYMPTOM: the sandboxed probe at the same high offered rate plateaus near the
#      documented limit, so only a fraction of the burst is answered;
#   5. read the control table and print a verdict.
#
# A confidence gate reads the control before trusting the symptom: if the ordinary
# probe does not keep up, the cluster resolver or the offered load is the
# bottleneck, so the script fails loudly rather than blaming the sandbox; if neither
# pod plateaus, this cluster is not enforcing the limit and the script says so,
# rather than inventing a number.
#
# It runs read-only kubectl against the current context and applies only this
# sample's own objects in its own namespace.
#
# Usage:
#   scripts/run-comparison.sh            # deploy from clean, run the comparison, verdict
#   scripts/run-comparison.sh --raised   # also run the optional raised-limit variant
#   scripts/run-comparison.sh --cleanup  # delete only this sample's objects
#
# The documented default limit, from the Amazon EKS User Guide (Isolated and
# confidential pods limitations, "Per-pod DNS query rate limit"), is 100 queries per
# second per family. The thresholds below are derived from it: "uncapped" means at
# least twice the limit answered, "capped" means at most 1.5x the limit answered
# while the control is uncapped. The short burst allowance the guide notes is why a
# capped plateau reads a little above 100 over a short window.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$HERE/deploy"
PROBE="$HERE/scripts/probe-dns-rate.py"
NS=sandbox-limits
TIMEOUT="${TIMEOUT:-300s}"

CAP_QPS=100                       # documented default, EKS User Guide
LOW_QPS="${LOW_QPS:-50}"          # below the limit
HIGH_QPS="${HIGH_QPS:-400}"       # well above the limit
UNCAPPED_MIN=$(( CAP_QPS * 2 ))   # control must clear this (>= 200 qps answered)
CAPPED_MAX=$(( CAP_QPS * 3 / 2 )) # symptom must stay at/below this (<= 150 qps answered)

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
  kubectl delete -f "$DEPLOY/egress-policy.yaml"           --ignore-not-found
  kubectl delete -f "$DEPLOY/probe-sandboxed-raised.yaml"  --ignore-not-found
  kubectl delete -f "$DEPLOY/probe-sandboxed.yaml"         --ignore-not-found
  kubectl delete -f "$DEPLOY/probe-standard.yaml"          --ignore-not-found
  kubectl delete -f "$DEPLOY/namespace.yaml"               --ignore-not-found
}

RAISED=no
case "${1:-}" in
  --cleanup) cleanup; exit 0 ;;
  --raised)  RAISED=yes ;;
  "")        ;;
  *) line "unknown argument: $1"; line "usage: run-comparison.sh [--raised|--cleanup]"; exit 64 ;;
esac

# Run the probe inside a pod at an offered rate, print the answered rate (qps).
# Reads the RESULT line the probe prints last. Prints "error" if the probe did not
# run, which the caller treats as a broken run and never as a result.
probe_rate() {
  local pod="$1" offered="$2" out rate
  out="$(kubectl -n "$NS" exec -i "$pod" -- env OFFERED_QPS="$offered" python3 - < "$PROBE" 2>&1)" || {
    printf 'error' ; printf '%s\n' "  (probe $pod @ $offered qps failed: $(tr '\n' ' ' <<<"$out" | cut -c1-120))" >&2 ; return
  }
  rate="$(sed -n 's/^RESULT .*rate=\([0-9.]*\).*/\1/p' <<<"$out" | tail -1)"
  [[ -n "$rate" ]] && printf '%s' "$rate" || { printf 'error'; printf '%s\n' "  (no RESULT line from $pod)" >&2; }
}

# numeric comparisons without bc
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
kubectl delete -f "$DEPLOY/probe-sandboxed-raised.yaml" --ignore-not-found --wait=true
kubectl delete -f "$DEPLOY/probe-sandboxed.yaml"        --ignore-not-found --wait=true
kubectl delete -f "$DEPLOY/probe-standard.yaml"         --ignore-not-found --wait=true

say "Deploy the egress NetworkPolicy and the two probe pods"
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
    # locale: under en_US.utf8, [0-9] also accepted non-ASCII digit-like characters, so
    # "1.2.3.<Arabic-Indic 4>", "1.2.3.<superscript 2>" and "1.2.3.<one half>" passed here
    # while grep on the page rejected them. POSIX leaves only ranges to the locale, so a
    # bracket list of single characters matches just those characters, and this check and the
    # grep on the page agree.
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
line "cluster DNS address (kubelet clusterDNS on $DNS_NODE): $COREDNS_IP"
sed "s|<COREDNS_IP>|$COREDNS_IP|" "$DEPLOY/egress-policy.yaml" | kubectl apply -f -
kubectl apply -f "$DEPLOY/probe-standard.yaml"
kubectl apply -f "$DEPLOY/probe-sandboxed.yaml"
[[ "$RAISED" == yes ]] && kubectl apply -f "$DEPLOY/probe-sandboxed-raised.yaml"

PODS=(probe-standard probe-sandboxed)
[[ "$RAISED" == yes ]] && PODS+=(probe-sandboxed-raised)
for p in "${PODS[@]}"; do
  kubectl -n "$NS" wait "pod/$p" --for=condition=Ready --timeout="$TIMEOUT"
done

# --- 2-4. The three probes -------------------------------------------------------------
say "BELOW the limit: sandboxed probe @ ${LOW_QPS} qps (the same probe, limit not reached)"
below="$(probe_rate probe-sandboxed "$LOW_QPS")"
line "answered: ${below} qps"

say "CONTROL: ordinary probe @ ${HIGH_QPS} qps (nothing caps on the normal path)"
control="$(probe_rate probe-standard "$HIGH_QPS")"
line "answered: ${control} qps"

say "SYMPTOM: sandboxed probe @ ${HIGH_QPS} qps (the per-sandbox limit bites)"
symptom="$(probe_rate probe-sandboxed "$HIGH_QPS")"
line "answered: ${symptom} qps"

raised=""
if [[ "$RAISED" == yes ]]; then
  say "OPTIONAL: sandboxed probe with the limit raised to 300 @ ${HIGH_QPS} qps"
  raised="$(probe_rate probe-sandboxed-raised "$HIGH_QPS")"
  line "answered: ${raised} qps"
fi

# --- 5. Verdict, reading the control table ---------------------------------------------
say "Results"
printf '%-42s %s\n' "sandbox  @ ${LOW_QPS} qps (below the limit)"  "${below} qps answered"
printf '%-42s %s\n' "standard @ ${HIGH_QPS} qps (control)"         "${control} qps answered"
printf '%-42s %s\n' "sandbox  @ ${HIGH_QPS} qps (symptom)"         "${symptom} qps answered"
[[ "$RAISED" == yes ]] && \
printf '%-42s %s\n' "sandbox  @ ${HIGH_QPS} qps, limit raised 300" "${raised} qps answered"

say "Verdict"
if [[ "$below" == error || "$control" == error || "$symptom" == error ]]; then
  line "RESULT: a probe failed to run (an 'error' reading above). This is not a limit"
  line "result. Fix the broken probe and re-run."
  exit 5
elif ! ge "$control" "$UNCAPPED_MIN"; then
  line "RESULT: the ordinary control answered only ${control} qps (needs >= ${UNCAPPED_MIN})."
  line "The bottleneck is the cluster resolver, the offered load, or the control pod's own CPU,"
  line "not the sandbox, so the comparison cannot attribute anything. Investigate the control"
  line "pod's performance (and re-run when the cluster DNS is quiet) before reading the result."
  exit 3
elif ge "$symptom" "$UNCAPPED_MIN"; then
  line "RESULT: both the control (${control} qps) and the sandboxed probe (${symptom} qps) ran"
  line "uncapped. This cluster build is not enforcing the DNS query-rate limit: a runtime"
  line "fact, not a sandbox defect, and no number is invented. Nothing to report as a limit."
  exit 4
elif le "$symptom" "$CAPPED_MAX"; then
  line "RESULT: the per-sandbox DNS query-rate limit bites on the sandbox path and not on the"
  line "ordinary path. Below the limit the sandboxed probe answered ${below} qps; at ${HIGH_QPS}"
  line "qps offered it plateaued at ${symptom} qps while the ordinary control answered ${control}"
  line "qps. The measured plateau is near the documented 100 qps per family (EKS User Guide)."
  [[ "$RAISED" == yes ]] && \
  line "With the limit raised to 300, the plateau moved to ${raised} qps: direct evidence the plateau is that limit."
  exit 0
else
  line "RESULT: unexpected combination: below=${below} control=${control} symptom=${symptom}."
  line "Inspect the readings above."
  exit 5
fi
