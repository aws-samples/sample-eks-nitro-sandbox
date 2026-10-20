#!/usr/bin/env bash
# OPTIONAL variant: egress by hostname with an EKS Auto Mode ApplicationNetworkPolicy,
# side by side on a second identical client pair (client-standard-dns, client-sandboxed-dns).
#
# The policy allows one AWS endpoint by name (sts.$AWS_REGION.amazonaws.com) and allows no
# other, so a second AWS endpoint (kms.$AWS_REGION.amazonaws.com) is refused. It shows the
# same side-by-side result as the main sample, for name-based egress:
#   1. deploy the second client pair from a clean slate;
#   2. BEFORE the policy, prove each client reaches BOTH endpoints (the open control);
#   3. apply the ApplicationNetworkPolicy and wait for its PolicyEndpoint;
#   4. AFTER the policy, show each client keeping the allowed name and refused the other;
#   5. print a verdict.
#
# It fills in the CoreDNS address and the Region from your environment -- no account value
# is written into a tracked file. Set AWS_REGION first (defaults to us-west-2).
#
# Usage:
#   scripts/run-dns-comparison.sh            # deploy from clean, before+after, verdict
#   scripts/run-dns-comparison.sh --cleanup  # delete only this variant's objects
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$HERE/deploy"
AWS_REGION="${AWS_REGION:-us-west-2}"
TIMEOUT="${TIMEOUT:-300s}"
ALLOWED_HOST="sts.$AWS_REGION.amazonaws.com"
BLOCKED_HOST="kms.$AWS_REGION.amazonaws.com"

say() { printf '\n=== %s ===\n' "$*"; }

cleanup() {
  say "Cleaning up this variant's objects"
  kubectl delete applicationnetworkpolicy netpol-client-dns-egress --ignore-not-found
  kubectl delete -f "$DEPLOY/client-standard-dns.yaml"  --ignore-not-found
  kubectl delete -f "$DEPLOY/client-sandboxed-dns.yaml" --ignore-not-found
  printf 'The cluster-wide network policy enforcement setting is NOT touched; left as it was.\n'
}

if [[ "${1:-}" == "--cleanup" ]]; then
  cleanup
  exit 0
fi

# TCP:443 reachability to a hostname, with busybox nc. DNS is allowed by the policy, so a
# refusal is the IPv4 connect getting no reply, not a name-resolution failure. Prints:
#   reached   nc connected
#   refused   nc could not connect within the deadline (a genuine block)
#   error     nc is missing or kubectl exec failed -- NOT a policy result
reach443() {
  local pod="$1" host="$2" out rc
  out="$(kubectl exec "$pod" -- sh -c "command -v nc >/dev/null || { echo NO_NC; exit 3; }; nc -z -w 8 $host 443" 2>&1)" && rc=0 || rc=$?
  if [[ $rc -eq 0 ]]; then
    printf 'reached'
  elif grep -q NO_NC <<<"$out" || [[ $rc -eq 3 ]]; then
    printf 'error'; printf '  (nc missing in %s)' "$pod" >&2
  elif [[ $rc -eq 1 ]]; then
    printf 'refused'            # nc's own "could not connect" exit
  else
    printf 'error'; printf '  (reach443 %s -> %s failed: %s)' "$pod" "$host" \
      "$(tr '\n' ' ' <<<"$out" | cut -c1-100)" >&2
  fi
}

report() {   # "<pod>" -> one line with both readings
  local pod="$1"
  printf '%-22s allowed(%s)=%-9s blocked(%s)=%-9s\n' \
    "$pod" "$ALLOWED_HOST" "$(reach443 "$pod" "$ALLOWED_HOST")" \
    "$BLOCKED_HOST" "$(reach443 "$pod" "$BLOCKED_HOST")"
}

say "Start from a clean slate"
kubectl delete applicationnetworkpolicy netpol-client-dns-egress --ignore-not-found --wait=true
kubectl delete -f "$DEPLOY/client-standard-dns.yaml"  --ignore-not-found --wait=true
kubectl delete -f "$DEPLOY/client-sandboxed-dns.yaml" --ignore-not-found --wait=true

say "Deploy the second client pair"
kubectl apply -f "$DEPLOY/client-standard-dns.yaml"
kubectl apply -f "$DEPLOY/client-sandboxed-dns.yaml"
for p in client-standard-dns client-sandboxed-dns; do
  kubectl wait "pod/$p" --for=condition=Ready --timeout="$TIMEOUT"
done

say "BEFORE the policy: each client reaches both endpoints (the open control state)"
b_std_allowed="$(reach443 client-standard-dns  "$ALLOWED_HOST")"
b_std_blocked="$(reach443 client-standard-dns  "$BLOCKED_HOST")"
b_box_allowed="$(reach443 client-sandboxed-dns "$ALLOWED_HOST")"
b_box_blocked="$(reach443 client-sandboxed-dns "$BLOCKED_HOST")"
report client-standard-dns
report client-sandboxed-dns
if [[ "$b_std_allowed" != reached || "$b_std_blocked" != reached \
   || "$b_box_allowed" != reached || "$b_box_blocked" != reached ]]; then
  printf '\nSTOP: before the policy, a client did not reach both endpoints, so the control is\n'
  printf 'not open. A leftover policy, an unhealthy pod, or a failed probe is the likely\n'
  printf 'cause. Fix it and re-run; do not read the comparison.\n'
  exit 2
fi

say "Apply the ApplicationNetworkPolicy (allows $ALLOWED_HOST by name)"
COREDNS_IP="$(kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}')"
sed -e "s|<COREDNS_IP>|$COREDNS_IP|" -e "s|<AWS_REGION>|$AWS_REGION|" \
  "$DEPLOY/app-egress-policy.yaml" | kubectl apply -f -
printf 'Waiting for the netpol-client-dns-egress PolicyEndpoint ...\n'
pe_seen=no
for _ in $(seq 1 60); do
  if kubectl get policyendpoints -o name 2>/dev/null \
       | grep -q '^policyendpoint.networking.k8s.aws/netpol-client-dns-egress-'; then
    pe_seen=yes; break
  fi
  sleep 2
done
[[ "$pe_seen" == yes ]] && kubectl get policyendpoints 2>/dev/null | grep 'netpol-client-dns-egress-' || \
  printf '(no PolicyEndpoint yet -- if enforcement is off, none will appear)\n'
sleep 5

say "AFTER the policy: $ALLOWED_HOST allowed, $BLOCKED_HOST refused"
a_std_allowed="$(reach443 client-standard-dns  "$ALLOWED_HOST")"
a_std_blocked="$(reach443 client-standard-dns  "$BLOCKED_HOST")"
a_box_allowed="$(reach443 client-sandboxed-dns "$ALLOWED_HOST")"
a_box_blocked="$(reach443 client-sandboxed-dns "$BLOCKED_HOST")"
report client-standard-dns
report client-sandboxed-dns

say "Verdict"
if [[ "$a_std_allowed" == error || "$a_std_blocked" == error \
   || "$a_box_allowed" == error || "$a_box_blocked" == error ]]; then
  printf 'RESULT: a probe failed to run (an "error" reading). Not a policy result; fix and re-run.\n'
  exit 5
elif [[ "$a_std_blocked" == reached ]]; then
  printf 'RESULT: ordinary -> %s REACHED after the policy. Cluster enforcement is OFF, or the\n' "$BLOCKED_HOST"
  printf 'ApplicationNetworkPolicy API is not installed -- not a sandbox result. See README step 1.\n'
  exit 3
elif [[ "$a_std_allowed" == reached && "$a_box_allowed" == reached \
     && "$a_std_blocked" == refused && "$a_box_blocked" == refused ]]; then
  printf 'RESULT: name-based egress is enforced on the sandboxed path exactly as on the\n'
  printf 'ordinary path -- both keep %s and are refused %s.\n' "$ALLOWED_HOST" "$BLOCKED_HOST"
  exit 0
elif [[ "$a_std_blocked" == refused && "$a_box_blocked" == reached ]]; then
  printf 'RESULT: the policy holds on the ordinary path but NOT on the sandboxed one. Report it.\n'
  exit 4
else
  printf 'RESULT: unexpected combination -- inspect the readings above.\n'
  exit 5
fi
