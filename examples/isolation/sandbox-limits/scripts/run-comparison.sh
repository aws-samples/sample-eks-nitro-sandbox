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

cleanup() {
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
say "Start from a clean slate (delete any leftover pods and policy from a prior run)"
kubectl delete -f "$DEPLOY/probe-sandboxed-raised.yaml" --ignore-not-found --wait=true
kubectl delete -f "$DEPLOY/probe-sandboxed.yaml"        --ignore-not-found --wait=true
kubectl delete -f "$DEPLOY/probe-standard.yaml"         --ignore-not-found --wait=true

say "Deploy the namespace, the egress NetworkPolicy and the two probe pods"
kubectl apply -f "$DEPLOY/namespace.yaml"
COREDNS_IP="$(kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}')"
line "CoreDNS Service IP: $COREDNS_IP"
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
