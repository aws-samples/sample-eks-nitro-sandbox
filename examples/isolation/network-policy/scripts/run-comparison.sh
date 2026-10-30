#!/usr/bin/env bash
# Network policy on a sandboxed pod, side by side with an ordinary pod.
#
# Runs the whole before/after comparison for the main sample:
#   1. deploy the two servers (web-allowed, web-blocked) and the two clients
#      (client-standard, client-sandboxed) from a clean slate, and wait for them Ready;
#   2. BEFORE the policy, prove each client reaches BOTH servers (the open control state);
#   3. apply the egress NetworkPolicy, wait for its PolicyEndpoint;
#   4. AFTER the policy, show each client still reaching web-allowed and refused
#      web-blocked, and a kubectl exec from inside the sandboxed client refused too;
#   5. read the control table and print a verdict.
#
# It runs read-only kubectl against the current context/namespace and applies only this
# sample's own objects. It makes NO change to the cluster-wide network policy enforcement
# setting -- it checks that setting and points at the one-time operator step if it is off.
#
# Usage:
#   scripts/run-comparison.sh            # deploy from clean, run before+after, verdict
#   scripts/run-comparison.sh --cleanup  # delete only this sample's objects
#
# No arguments are read beyond the single optional flag above.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$HERE/deploy"
TIMEOUT="${TIMEOUT:-300s}"
ALLOWED_PORT=8080

say()  { printf '\n=== %s ===\n' "$*"; }
line() { printf '%s\n' "$*"; }

cleanup() {
  say "Cleaning up this sample's objects"
  kubectl delete -f "$DEPLOY/egress-policy.yaml"    --ignore-not-found
  kubectl delete -f "$DEPLOY/client-standard.yaml"  --ignore-not-found
  kubectl delete -f "$DEPLOY/client-sandboxed.yaml" --ignore-not-found
  kubectl delete -f "$DEPLOY/web-allowed.yaml"      --ignore-not-found
  kubectl delete -f "$DEPLOY/web-blocked.yaml"      --ignore-not-found
  line "The cluster-wide network policy enforcement setting (amazon-vpc-cni ConfigMap) is"
  line "NOT touched by this script; it is left exactly as it was."
}

if [[ "${1:-}" == "--cleanup" ]]; then
  cleanup
  exit 0
fi

# A client reaches a server IP:port over HTTP, or reports why not. Prints one of:
#   reached      the request completed (an allowed egress)
#   timeout      the connection got no reply and ran to the -T deadline (an IPv4 block)
#   unreachable  the stack reported "Network is unreachable" (a blocked name's IPv6 path)
#   error        wget/kubectl-exec itself failed (missing tool, exec error) -- NOT a policy
#                result; the caller treats this as a broken run, not as a refusal.
# Uses busybox wget, present in the alpine client image. -T 8 bounds a blocked connection
# so it shows as a timeout, not a hang.
reach() {
  local pod="$1" ip="$2" port="$3" out rc
  out="$(kubectl exec "$pod" -- wget -q -T 8 -O /dev/null "http://$ip:$port/" 2>&1)" && rc=0 || rc=$?
  if [[ $rc -eq 0 ]]; then
    line "reached"
  elif grep -qi 'unreachable' <<<"$out"; then
    line "unreachable"
  elif grep -qiE 'download timed out|timed out|timeout' <<<"$out"; then
    line "timeout"
  else
    # Not a completion and not a recognised block shape: the tool or exec failed, so this
    # reading is not evidence about the policy. Surface it so it is not read as a refusal.
    line "error"
    printf '      (reach %s -> %s:%s failed to run: %s)\n' "$pod" "$ip" "$port" \
      "$(tr '\n' ' ' <<<"$out" | cut -c1-120)" >&2
  fi
}

refused() { [[ "$1" == timeout || "$1" == unreachable ]]; }   # a genuine policy refusal

# --- 1. Deploy from a clean slate ------------------------------------------------------
say "Check network policy enforcement is on"
ENFORCED=no
if kubectl get configmap -n kube-system amazon-vpc-cni \
     -o jsonpath='{.data.enable-network-policy-controller}' 2>/dev/null | grep -qx true; then
  line "enable-network-policy-controller: true"
  ENFORCED=yes
else
  line "WARNING: the amazon-vpc-cni ConfigMap does not enable the Network Policy Controller."
  line "Network policies will be ACCEPTED BUT NOT ENFORCED, so the comparison shows nothing"
  line "about the sandbox. Turn it on once per cluster (see the sample's README, step 1),"
  line "then re-run. Continuing so you can see the before state."
fi

say "Start from a clean slate (delete any leftover policy and pods from a prior run)"
# The before-state only means something if no policy from a prior run is still in force,
# so remove this sample's objects first, then recreate them. This is what makes the
# "before" readings a true open control rather than possibly a left-over enforced state.
kubectl delete -f "$DEPLOY/egress-policy.yaml"    --ignore-not-found --wait=true
kubectl delete -f "$DEPLOY/client-standard.yaml"  --ignore-not-found --wait=true
kubectl delete -f "$DEPLOY/client-sandboxed.yaml" --ignore-not-found --wait=true

say "Deploy the two servers and the two clients"
kubectl apply -f "$DEPLOY/web-allowed.yaml"
kubectl apply -f "$DEPLOY/web-blocked.yaml"
kubectl apply -f "$DEPLOY/client-standard.yaml"
kubectl apply -f "$DEPLOY/client-sandboxed.yaml"

for p in web-allowed web-blocked client-standard client-sandboxed; do
  kubectl wait "pod/$p" --for=condition=Ready --timeout="$TIMEOUT"
done

ALLOWED_IP="$(kubectl get pod web-allowed -o jsonpath='{.status.podIP}')"
BLOCKED_IP="$(kubectl get pod web-blocked -o jsonpath='{.status.podIP}')"
line "web-allowed pod IP: $ALLOWED_IP"
line "web-blocked pod IP: $BLOCKED_IP"

# --- 2. Before the policy: prove the open control state --------------------------------
say "BEFORE the policy: each client reaches both servers (the open control state)"
b_std_allowed="$(reach client-standard  "$ALLOWED_IP" "$ALLOWED_PORT")"
b_std_blocked="$(reach client-standard  "$BLOCKED_IP" "$ALLOWED_PORT")"
b_box_allowed="$(reach client-sandboxed "$ALLOWED_IP" "$ALLOWED_PORT")"
b_box_blocked="$(reach client-sandboxed "$BLOCKED_IP" "$ALLOWED_PORT")"
printf '%-18s allowed=%-11s blocked=%-11s\n' client-standard  "$b_std_allowed" "$b_std_blocked"
printf '%-18s allowed=%-11s blocked=%-11s\n' client-sandboxed "$b_box_allowed" "$b_box_blocked"

if [[ "$b_std_allowed" != reached || "$b_std_blocked" != reached \
   || "$b_box_allowed" != reached || "$b_box_blocked" != reached ]]; then
  line ""
  line "STOP: before the policy, a client did NOT reach both servers. The control is not"
  line "open, so the after-state would prove nothing. Likely causes: a policy from a prior"
  line "run is still in force, a server is not healthy, or the clients cannot run the probe"
  line "(a reading of 'error' above). Fix that and re-run; do not read the comparison."
  exit 2
fi

# --- 3. Apply the policy ---------------------------------------------------------------
say "Apply the egress NetworkPolicy and wait for its PolicyEndpoint"
# DNS (port 53) is allowed to any address in the policy file already (#104), so there is no
# address to look up or substitute here.
kubectl apply -f "$DEPLOY/egress-policy.yaml"
# The controller programs the datapath a few seconds after the policy lands; the
# PolicyEndpoint appearing shows it has handed the policy to the nodes.
line "Waiting for the netpol-client-egress PolicyEndpoint ..."
pe_seen=no
for _ in $(seq 1 60); do
  if kubectl get policyendpoints -o name 2>/dev/null \
       | grep -q '^policyendpoint.networking.k8s.aws/netpol-client-egress-'; then
    pe_seen=yes
    break
  fi
  sleep 2
done
if [[ "$pe_seen" == yes ]]; then
  kubectl get policyendpoints 2>/dev/null | grep 'netpol-client-egress-' || true
elif [[ "$ENFORCED" == yes ]]; then
  line "STOP: enforcement is on but no PolicyEndpoint for netpol-client-egress appeared in"
  line "about two minutes. The controller has not programmed the policy, so the after-state"
  line "is not ready to read. Check the vpc-cni/network-policy-agent pods and re-run."
  exit 2
else
  line "No PolicyEndpoint appeared -- expected, because enforcement is off (see the warning"
  line "above). The comparison below will show the policy is not enforced."
fi
sleep 5   # let the agent finish programming the pods' interfaces

# --- 4. After the policy ---------------------------------------------------------------
say "AFTER the policy: each client keeps web-allowed, loses web-blocked"
a_std_allowed="$(reach client-standard  "$ALLOWED_IP" "$ALLOWED_PORT")"
a_std_blocked="$(reach client-standard  "$BLOCKED_IP" "$ALLOWED_PORT")"
a_box_allowed="$(reach client-sandboxed "$ALLOWED_IP" "$ALLOWED_PORT")"
a_box_blocked="$(reach client-sandboxed "$BLOCKED_IP" "$ALLOWED_PORT")"
printf '%-18s allowed=%-11s blocked=%-11s\n' client-standard  "$a_std_allowed" "$a_std_blocked"
printf '%-18s allowed=%-11s blocked=%-11s\n' client-sandboxed "$a_box_allowed" "$a_box_blocked"

say "AFTER the policy: a command run INSIDE the sandbox is refused web-blocked too"
printf 'kubectl exec client-sandboxed -> web-blocked: %s\n' \
  "$(reach client-sandboxed "$BLOCKED_IP" "$ALLOWED_PORT")"

# --- 5. Verdict, reading the control table ---------------------------------------------
say "Verdict"
if [[ "$a_std_allowed" == error || "$a_std_blocked" == error \
   || "$a_box_allowed" == error || "$a_box_blocked" == error ]]; then
  line "RESULT: a probe failed to run (an 'error' reading). This is not a policy result."
  line "Fix the broken probe and re-run."
  exit 5
elif [[ "$a_std_blocked" == reached ]]; then
  line "RESULT: ordinary -> blocked REACHED after the policy. Cluster enforcement is OFF --"
  line "this is not a sandbox result. Turn on the Network Policy Controller (README step 1)"
  line "and re-run."
  exit 3
elif [[ "$a_std_allowed" == reached && "$a_box_allowed" == reached ]] \
   && refused "$a_std_blocked" && refused "$a_box_blocked"; then
  line "RESULT: the policy is enforced on the sandboxed path exactly as on the ordinary"
  line "path -- both clients keep web-allowed and are refused web-blocked."
  exit 0
elif refused "$a_std_blocked" && [[ "$a_box_blocked" == reached ]]; then
  line "RESULT: the policy was enforced on the ordinary path but NOT on the sandboxed one."
  line "This contradicts the sample's claim -- do not report success; investigate the"
  line "cluster's network-policy enforcement on sandbox pods."
  exit 4
else
  line "RESULT: unexpected combination -- inspect the readings above."
  line "  std: allowed=$a_std_allowed blocked=$a_std_blocked"
  line "  box: allowed=$a_box_allowed blocked=$a_box_blocked"
  exit 5
fi
