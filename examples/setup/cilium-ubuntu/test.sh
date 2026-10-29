#!/usr/bin/env bash
# Prove what the page claims about the Cilium-on-Ubuntu cluster setup.sh built:
#   1. the VPC CNI and kube-proxy are absent; Cilium is the only CNI and replaces kube-proxy,
#      with its socket load balancer in the host namespace only, fully up on both Ubuntu nodes;
#   2. the Nitro sandbox pod runs in its own guest kernel (the pinned guest release) on the
#      Ubuntu sandbox node (the pinned host release), scheduled there by the GA isolated-sandbox
#      RuntimeClass whose two labels only the sandbox node carries, with AppArmor Unconfined
#      on the sandbox pod alone;
#   3. its IP is a VPC address, on an ENI of its node, with a CiliumEndpoint;
#   4. it reaches an ordinary pod and is reached by one, and reaches a Service by DNS, as the
#      ordinary pods beside it and on the other node do; the node itself reaches the Service;
#   5. one CiliumNetworkPolicy allows and denies the same L3/L4 connections for the sandbox
#      pod as for an ordinary pod;
#   6. an L7 HTTP rule on that same policy allows one path and denies another on a separate
#      target, the deny answered by the node-local Envoy proxy with an HTTP 403, identically
#      for the sandbox pod and an ordinary pod, and does not change stage 5's verdicts;
#   7. a toFQDNs rule allows one DNS name and denies another, read from the Cilium agent's own
#      fqdn cache rather than assumed from the HTTP result, identically for the sandbox pod and
#      an ordinary pod, with the deny proven to be the policy (the name still resolves, and an
#      unselected pod still reaches it) and not a network failure;
#   8. every AWS resource the cluster owns is tagged auto-delete=no.
#
# Read-only: it changes nothing and leaves the demo running. It needs the cluster setup.sh
# built, so run ./setup.sh first.
#
#   ./test.sh
#
# The negative control for socketLB.hostNamespaceOnly (a sandbox pod CANNOT reach a ClusterIP
# Service or Service-based DNS with the setting off) is a separate reader step,
# scripts/socketlb-control.sh, run after this script and followed by this script again; test.sh
# stays read-only and does not flip the live Helm value. The both-ways proof that the stage 6 and 7 denies are the policy
# (not a timeout that would show with or without the rule) is likewise done once, offline,
# against a scratch policy object, and recorded on the page; it is not part of this script.
set -uo pipefail
SAMPLE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SAMPLE_DIR/scripts/common.sh"

require_commands aws kubectl python3
require_caller_account
[[ "$(cluster_state)" == ACTIVE ]] || die "cluster $CLUSTER_NAME is not ACTIVE; run ./setup.sh first"
require_demo_cluster
[[ -s "$KUBECONFIG" ]] || die "$KUBECONFIG is missing; run ./setup.sh first"

ns=(-n "$NAMESPACE")

# jget <jsonpath> <kubectl get args...>: one field, or empty when the read fails.
jget() {
  local path=$1; shift
  kubectl get "$@" -o "jsonpath=$path" 2>/dev/null || true
}

# probe <from-pod> <url>: sets PROBE_OUT (stdout+stderr) and PROBE_RC. busybox wget, 5 s
# timeout. Run in the current shell (no $( ) around it) so the globals survive.
PROBE_OUT="" PROBE_RC=0
probe() {
  PROBE_RC=0
  PROBE_OUT="$(kubectl "${ns[@]}" exec "$1" -- wget -q -T 5 -O - "$2" 2>&1)" || PROBE_RC=$?
}

# absent_ds <name>: the kube-system DaemonSet read fails with exactly NotFound.
absent_ds() {
  local out
  if out="$(kubectl -n kube-system get daemonset "$1" -o name 2>&1)"; then
    return 1
  fi
  grep -qx "Error from server (NotFound): daemonsets.apps \"$1\" not found" <<<"$out"
}

# setup.sh builds the cluster, installs Cilium and brings up both Ubuntu node groups, then
# hands off to this script: it does NOT apply the sample's own workloads or network policy, so
# this script applies them and waits for every pod to be Ready before it proves anything.
# Applying a Pod or Namespace that already exists is reused, not recreated, so re-running
# test.sh is safe. The namespace manifest carries the sample's part-of label, which the
# ownership checks and clean.sh key on.
step "0. Apply the sample's workloads and the egress network policy"
# AppArmor Unconfined on the sandbox pod and on no ordinary pod, checked before anything is
# applied (an Ubuntu host needs it for every isolated-sandbox pod; see the README).
python3 "$PY" check-workloads || die "deploy/workloads.yaml fails the AppArmor check above"
kubectl apply -f "$SAMPLE_DIR/deploy/workloads.yaml" >/dev/null || die "could not apply deploy/workloads.yaml"
kubectl apply -f "$SAMPLE_DIR/deploy/policy.yaml" >/dev/null || die "could not apply deploy/policy.yaml"
echo "waiting for the seven pods to be Ready (the sandbox pod boots a guest VM, so this can take a few minutes)..."
for pod in nitro neighbor node-probe control server other api; do
  kubectl "${ns[@]}" wait --for=condition=Ready "pod/$pod" --timeout=10m >/dev/null \
    || die "pod/$pod never became Ready; inspect it with: kubectl ${ns[*]} describe pod $pod"
done
echo "all seven pods Ready; the egress policy clients-egress is applied."

step "1. No VPC CNI and no kube-proxy: Cilium is the only CNI and replaces kube-proxy on both Ubuntu nodes"
absent_ds aws-node; assert "no aws-node DaemonSet (the VPC CNI was never installed)" $?
absent_ds kube-proxy; assert "no kube-proxy DaemonSet (kube-proxy was never installed)" $?
addons="$(aws eks list-addons --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --query addons --output text)"
addon_rc=$?
addons="$(tr '\t' '\n' <<<"$addons")"
# The message is built BEFORE the check: a $(...) inside assert's own arguments would run
# after it and hand assert that substitution's exit status in place of the check's.
msg="EKS add-ons: no vpc-cni and no kube-proxy; CoreDNS and the Pod Identity agent added back ($(tr '\n' ' ' <<<"$addons"))"
((addon_rc == 0)) && ! grep -qxF vpc-cni <<<"$addons" && ! grep -qxF kube-proxy <<<"$addons" \
  && grep -qxF coredns <<<"$addons" && grep -qxF eks-pod-identity-agent <<<"$addons"
assert "$msg" $?

agent_nodes="$(kubectl -n kube-system get pods -l k8s-app=cilium \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.status.containerStatuses[?(@.name=="cilium-agent")].ready}{"\n"}{end}' 2>/dev/null)"
groups=""
while read -r node ready; do
  [[ -n "$node" ]] || continue
  [[ "$ready" == true ]] || groups+="NOT-READY:"
  groups+="$(jget '{.metadata.labels.eks\.amazonaws\.com/nodegroup}' node "$node") "
done <<<"$agent_nodes"
[[ "$(tr ' ' '\n' <<<"$groups" | grep -v '^$' | sort | tr '\n' ' ')" == "sandbox system " ]]
assert "Cilium agent Ready on exactly the system and sandbox Ubuntu nodes (${groups% })" $?

agents="$(kubectl -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
healthy=0 total=0 clean=0 kpr=0 no_rules=0 clean_note="" kpr_note="" rules_note=""
for pod in $agents; do
  total=$((total + 1))
  group="$(jget '{.metadata.labels.eks\.amazonaws\.com/nodegroup}' node "$(jget '{.spec.nodeName}' -n kube-system pod "$pod")")"
  brief="$(kubectl -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg status --brief 2>&1)"
  [[ "$brief" == OK ]] && healthy=$((healthy + 1))
  # KubeProxyReplacement True, the socket load balancer on, and limited to the node's own
  # network namespace, read from the agent itself rather than from the Helm values.
  out="$(kubectl -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg status --verbose 2>/dev/null \
    | python3 "$PY" kpr-status 2>&1)" && kpr=$((kpr + 1))
  kpr_note+="${group:-?}: $(tail -n1 <<<"$out"); "
  # kube-proxy was never installed, so no Service rule of its can sit in the node's iptables
  # and make a Service answer for the wrong reason. The agent runs in the node's network
  # namespace, so its save tools read the node's own tables: IPv4 and IPv6, on the nft backend
  # the node uses and on the legacy one, each marked with its exit code.
  out="$(kubectl -n kube-system exec "$pod" -c cilium-agent -- sh -c \
    'for s in iptables-nft-save ip6tables-nft-save iptables-legacy-save ip6tables-legacy-save; do
       echo "#### $s"; "$s"; echo "#### rc=$?"; done' 2>/dev/null \
    | python3 "$PY" kube-proxy-rules 2>&1)" && no_rules=$((no_rules + 1))
  rules_note+="${group:-?}: $(tail -n1 <<<"$out"); "
  # A node kernel without BTF makes the agent retry its datapath load forever while the pod
  # still reads Running; Ready alone does not show it. Read the agent's own log. Both Ubuntu
  # node kernels must be built with BTF for this to come up clean.
  out="$(kubectl -n kube-system logs "$pod" -c cilium-agent 2>/dev/null | python3 "$PY" datapath-failures 2>&1)" \
    && clean=$((clean + 1))
  clean_note+="${group:-?}: $(tail -n1 <<<"$out"); "
done
((total == 2 && healthy == 2)); assert "cilium-dbg status --brief is OK on both agents ($healthy/$total)" $?
((total == 2 && kpr == 2))
assert "both agents replace kube-proxy, socket load balancer in the host namespace only (${kpr_note%; })" $?
((total == 2 && no_rules == 2))
assert "neither Ubuntu node's iptables holds a kube-proxy chain (${rules_note%; })" $?
((total == 2 && clean == 2))
assert "both Ubuntu node kernels expose valid BTF: both agents loaded their full eBPF datapath (${clean_note%; })" $?
cilium_svc="$(kubectl -n kube-system exec "$(jget '{.items[0].metadata.name}' -n kube-system pods -l k8s-app=cilium \
  --field-selector "spec.nodeName=$(jget '{.spec.nodeName}' "${ns[@]}" pod nitro)")" -c cilium-agent -- \
  cilium-dbg service list 2>/dev/null)"
svc_ip="$(jget '{.spec.clusterIP}' "${ns[@]}" service server)"
backend_ip="$(jget '{.status.podIP}' "${ns[@]}" pod server)"
[[ -n "$svc_ip" && -n "$backend_ip" ]] && grep -Eq "^[0-9]+[[:space:]]+${svc_ip//./\\.}:80/TCP[[:space:]]+ClusterIP[[:space:]]+1 => ${backend_ip//./\\.}:8080/TCP[[:space:]]+\(active\)[[:space:]]*$" <<<"$cilium_svc"
assert "Cilium on the sandbox node holds the server ClusterIP in its own load balancer ($svc_ip:80 -> $backend_ip:8080, active)" $?

step "1b. The Cilium operator's AWS credentials"
op_pod="$(kubectl -n kube-system get pods -l name=cilium-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
op_env="$(kubectl -n kube-system get pod "$op_pod" \
  -o jsonpath='{range .spec.containers[*].env[*]}{.name}{"\n"}{end}' 2>/dev/null)"
[[ -n "$op_pod" ]] && grep -qx AWS_CONTAINER_CREDENTIALS_FULL_URI <<<"$op_env"
assert "the operator pod ($op_pod) gets its credentials from EKS Pod Identity" $?
python3 "$PY" check-operator-role
assert "the operator's role allows exactly Cilium's documented ENI actions, and no node role has AmazonEKS_CNI_Policy" $?

step "2. The Nitro sandbox pod runs in its own guest kernel"
nitro_node="$(jget '{.spec.nodeName}' "${ns[@]}" pod nitro)"
control_node="$(jget '{.spec.nodeName}' "${ns[@]}" pod control)"
[[ "$(jget '{.spec.runtimeClassName}' "${ns[@]}" pod nitro)" == isolated-sandbox ]] \
  && [[ "$(jget '{.status.conditions[?(@.type=="Ready")].status}' "${ns[@]}" pod nitro)" == True ]]
assert "pod nitro is Ready with runtimeClassName isolated-sandbox" $?
[[ -n "$nitro_node" && "$(jget '{.metadata.labels.eks\.amazonaws\.com/nodegroup}' node "$nitro_node")" == sandbox ]]
assert "pod nitro runs on the Ubuntu sandbox node ($nitro_node)" $?
# The RuntimeClass the GA bundle defines, and the node labels it schedules on: both on the
# sandbox node, neither on the ordinary system node.
# Each message is built from the captured output BEFORE assert runs, so assert gets the check's
# own exit status, not that of a $(...) in its arguments.
out="$(kubectl get runtimeclass isolated-sandbox -o json 2>/dev/null | python3 "$PY" check-runtimeclass 2>&1)"; rc=$?
msg="the isolated-sandbox RuntimeClass matches the GA bundle's ($(tail -n1 <<<"$out"))"
assert "$msg" "$rc"
out="$(kubectl get node "$nitro_node" -o json 2>/dev/null | python3 "$PY" check-node-labels sandbox 2>&1)"; rc=$?
msg="$(tail -n1 <<<"$out")"
assert "$msg" "$rc"
out="$(kubectl get node "$control_node" -o json 2>/dev/null | python3 "$PY" check-node-labels system 2>&1)"; rc=$?
msg="$(tail -n1 <<<"$out"), so no sandbox pod can be scheduled on it"
assert "$msg" "$rc"
# AppArmor as the API server has it, for every pod at once: Unconfined at pod level on the
# sandbox pod only, and on no ordinary pod. The read must succeed; a failed read is a FAIL, never
# "the ordinary pods kept their default profile".
live_pods="$(kubectl "${ns[@]}" get pods -o json 2>/dev/null)"; rc=$?
if ((rc == 0)); then
  out="$(python3 "$PY" check-workloads --file - <<<"$live_pods" 2>&1)"; rc=$?
  ((rc == 0)) || sed 's/^/    /' <<<"$out"
  msg="live pods: AppArmor Unconfined at pod level on the sandbox pod only, which an Ubuntu host needs ($(tail -n1 <<<"$out"))"
else
  msg="could not read the pods in $NAMESPACE (kubectl exit $rc), so the AppArmor scope is not proven"
  rc=1
fi
assert "$msg" "$rc"
sandbox_kernel="$(jget '{.status.nodeInfo.kernelVersion}' node "$nitro_node")"
out="$(python3 "$PY" kernel-release "$HOST_KERNEL_RELEASE" "$sandbox_kernel" 2>&1)"; rc=$?
assert "the sandbox node runs the pinned host kernel ($out)" "$rc"
# ACCEPT: the node's allocatable capacity for the actual extended resource the EKS Pod
# Isolation device plugin advertises, not just the RuntimeClass object's existence (a
# RuntimeClass can exist with no node able to run it). Same key and same both-ways proof as
# ../ubuntu-ami's test.sh ("5/7 positive sandbox capacity"), since this sample's sandbox node
# runs the same AMI and runtime.
sandbox_capacity="$(jget '{.status.allocatable.eks\.amazonaws\.com/nitro-sandbox}' node "$nitro_node")"
[[ "${sandbox_capacity:-0}" =~ ^[0-9]+$ && "${sandbox_capacity:-0}" -gt 0 ]]
assert "sandbox node $nitro_node advertises positive allocatable eks.amazonaws.com/nitro-sandbox (${sandbox_capacity:-0})" $?
# REJECT: the same lookup against a bogus resource key on the same node must read absent,
# proving the check discriminates rather than matching any allocatable field. The read must
# succeed and name the node, so a failed read (empty output) is not taken as "absent".
bogus_read="$(kubectl get node "$nitro_node" -o 'jsonpath={.metadata.name}|{.status.allocatable.eks\.amazonaws\.com/nitro-sandbox-bogus}' 2>/dev/null)"; rc=$?
[[ "$rc" == 0 && -n "$nitro_node" && "$bogus_read" == "$nitro_node|" ]]
assert "the capacity check reads absent for a nonexistent allocatable key on $nitro_node (reject control)" $?
nitro_guest="$(kubectl "${ns[@]}" exec nitro -- uname -r 2>/dev/null)"
nitro_host="$(jget '{.status.nodeInfo.kernelVersion}' node "$nitro_node")"
[[ -n "$nitro_guest" && -n "$nitro_host" && "$nitro_guest" != "$nitro_host" ]]
assert "sandbox pod guest kernel ($nitro_guest) differs from its Ubuntu node's kernel ($nitro_host)" $?
out="$(python3 "$PY" kernel-release "$GUEST_KERNEL_RELEASE" "$nitro_guest" 2>&1)"; rc=$?
assert "sandbox pod runs the pinned guest kernel from the bundle's guest image ($out)" "$rc"
control_guest="$(kubectl "${ns[@]}" exec control -- uname -r 2>/dev/null)"
control_host="$(jget '{.status.nodeInfo.kernelVersion}' node "$control_node")"
[[ -n "$control_guest" && "$control_guest" == "$control_host" ]]
assert "control: an ordinary pod shares its node's kernel ($control_guest), so the check above discriminates" $?
neighbor_node="$(jget '{.spec.nodeName}' "${ns[@]}" pod neighbor)"
neighbor_kernel="$(kubectl "${ns[@]}" exec neighbor -- uname -r 2>/dev/null)"
[[ -n "$nitro_node" && "$neighbor_node" == "$nitro_node" && -n "$neighbor_kernel" && "$neighbor_kernel" == "$nitro_host" ]]
assert "neighbor: an ordinary pod on the same Ubuntu sandbox node runs on that node's kernel ($neighbor_kernel)" $?
# The workload still has its own guest: boot uptime and virtio disks prove the networked
# sandbox pod is a VM, not a container on the node kernel, unlike the ordinary neighbor.
nitro_uptime="$(kubectl "${ns[@]}" exec nitro -- cat /proc/uptime 2>/dev/null | awk '{print $1}')"
nitro_disks="$(kubectl "${ns[@]}" exec nitro -- sh -c 'ls /sys/block 2>/dev/null | tr "\n" " "' 2>/dev/null)"
neighbor_disks="$(kubectl "${ns[@]}" exec neighbor -- sh -c 'ls /sys/block 2>/dev/null | tr "\n" " "' 2>/dev/null)"
[[ -n "$nitro_uptime" && -n "$nitro_disks" && "$nitro_disks" != *nvme* && "$nitro_disks" == *vd* ]]
assert "sandbox pod sees its own virtio disks ($nitro_disks), no node nvme, and its own boot (uptime ${nitro_uptime}s)" $?
[[ "$neighbor_disks" == *nvme* ]]
assert "neighbor: the ordinary pod on the same node sees the node's nvme disks ($neighbor_disks), so the check above discriminates" $?

step "3. Its IP is a VPC address with a CiliumEndpoint"
mapfile -t cidrs < <(python3 "$PY" vpc-cidrs)
for lane in nitro neighbor control; do
  ip="$(jget '{.status.podIP}' "${ns[@]}" pod "$lane")"
  node="$(jget '{.spec.nodeName}' "${ns[@]}" pod "$lane")"
  node_ip="$(jget '{.status.addresses[?(@.type=="InternalIP")].address}' node "$node")"
  [[ -n "$ip" && -n "$node_ip" && "$ip" != "$node_ip" ]] && ((${#cidrs[@]} > 0)) \
    && python3 "$PY" in-cidrs "$ip" "${cidrs[@]}" >/dev/null
  assert "$lane: pod IP $ip is in the VPC (${cidrs[*]}) and is not the node's own IP $node_ip" $?
  instance="$(jget '{.spec.providerID}' node "$node")"; instance="${instance##*/}"
  # One row per ENI holding the address: its instance, and whether the address is that ENI's
  # PRIMARY one (a node's own address) or a secondary one (handed to a pod by Cilium).
  eni_owner="$(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
    --filters "Name=addresses.private-ip-address,Values=$ip" "Name=attachment.instance-id,Values=$instance" \
    --query "NetworkInterfaces[].[Attachment.InstanceId, PrivateIpAddresses[?PrivateIpAddress=='$ip'].Primary | [0]]" \
    --output text 2>/dev/null)"
  [[ -n "$ip" && "$instance" =~ ^i-[0-9a-f]+$ && "$eni_owner" == "$instance"$'\t'False ]]
  assert "$lane: $ip is a secondary address on an ENI of its own instance ($instance)" $?
  cep_ips="$(jget '{.status.networking.addressing[*].ipv4}' "${ns[@]}" ciliumendpoint "$lane")"
  [[ -n "$ip" && " $cep_ips " == *" $ip "* ]] \
    && [[ "$(jget '{.status.state}' "${ns[@]}" ciliumendpoint "$lane")" == ready ]]
  assert "$lane: CiliumEndpoint is ready and carries $ip" $?
done

step "4. Connectivity: pod to pod both ways, ClusterIP Service, DNS; and from the node itself"
server_ip="$(jget '{.status.podIP}' "${ns[@]}" pod server)"
cluster_ip="$(jget '{.spec.clusterIP}' "${ns[@]}" service server)"
fqdn="server.$NAMESPACE.svc.cluster.local"
coredns_ip="$(jget '{.items[0].status.podIP}' -n kube-system pods -l k8s-app=kube-dns)"
kube_dns_ip="$(jget '{.spec.clusterIP}' -n kube-system service kube-dns)"
for lane in nitro neighbor control; do
  lane_ip="$(jget '{.status.podIP}' "${ns[@]}" pod "$lane")"
  probe "$lane" "http://$server_ip:8080/"
  [[ "$PROBE_RC" == 0 && "$PROBE_OUT" == server ]]
  assert "$lane -> ordinary pod server ($server_ip:8080)" $?
  probe server "http://$lane_ip:8080/"
  [[ "$PROBE_RC" == 0 && "$PROBE_OUT" == "$lane" ]]
  assert "ordinary pod server -> $lane ($lane_ip:8080)" $?
  probe "$lane" "http://$cluster_ip/"
  [[ "$PROBE_RC" == 0 && "$PROBE_OUT" == server ]]
  # All three clients are under the egress policy, which allows server:8080 and nothing on
  # :80. So this can pass only if Cilium translated the ClusterIP before its policy check: per
  # packet at the pod's interface, since the socket load balancer serves the host namespace
  # only (step 1), and no kube-proxy rule exists to translate it anywhere else. For the
  # sandbox lane this is the whole point: the guest's connect() the node's socket hooks never
  # see still reaches the Service, because the translation happens at the pod interface.
  assert "$lane -> ClusterIP Service server ($cluster_ip:80), translated by Cilium before its egress policy" $?
  answer="$(kubectl "${ns[@]}" exec "$lane" -- nslookup "$fqdn" 2>/dev/null \
    | awk '/^Name:/{named=1; next} named && /^Address:/{print $2}' | head -n1)"
  [[ -n "$cluster_ip" && "$answer" == "$cluster_ip" ]]
  assert "$lane: DNS through the kube-dns Service resolves $fqdn to the ClusterIP ($answer)" $?
  answer="$(kubectl "${ns[@]}" exec "$lane" -- nslookup "$fqdn" "$coredns_ip" 2>/dev/null \
    | awk '/^Name:/{named=1; next} named && /^Address:/{print $2}' | head -n1)"
  [[ -n "$coredns_ip" && "$answer" == "$cluster_ip" ]]
  assert "$lane: CoreDNS answers at its pod IP $coredns_ip too (DNS works apart from the Service)" $?
  probe "$lane" "http://$fqdn/"
  [[ "$PROBE_RC" == 0 && "$PROBE_OUT" == server ]]
  assert "$lane -> http://$fqdn/ (DNS name and Service together)" $?
done
# The node's own network namespace, where the socket load balancer does the translating.
[[ "$(jget '{.spec.hostNetwork}' "${ns[@]}" pod node-probe)" == true && -n "$nitro_node" \
  && "$(jget '{.spec.nodeName}' "${ns[@]}" pod node-probe)" == "$nitro_node" \
  && "$(jget '{.status.podIP}' "${ns[@]}" pod node-probe)" == "$(jget '{.status.addresses[?(@.type=="InternalIP")].address}' node "$nitro_node")" ]]
assert "node-probe runs in the sandbox node's own network namespace (hostNetwork, the node's IP)" $?
probe node-probe "http://$cluster_ip/"
[[ "$PROBE_RC" == 0 && "$PROBE_OUT" == server ]]
assert "the sandbox node itself -> ClusterIP Service server ($cluster_ip:80), by Cilium's socket load balancer" $?
answer="$(kubectl "${ns[@]}" exec node-probe -- nslookup "$fqdn" "$kube_dns_ip" 2>/dev/null \
  | awk '/^Name:/{named=1; next} named && /^Address:/{print $2}' | head -n1)"
[[ -n "$kube_dns_ip" && -n "$cluster_ip" && "$answer" == "$cluster_ip" ]]
assert "the sandbox node itself: the kube-dns Service ($kube_dns_ip) resolves $fqdn to the ClusterIP" $?

step "5. L3/L4 policy: one CiliumNetworkPolicy, the same verdicts for the sandbox pod and an ordinary pod"
# policy_enabled <pod>: what the Cilium agent on the pod's node enforces on its endpoint
# (none / ingress / egress / both), read from the agent itself.
policy_enabled() {
  local id node agent
  id="$(jget '{.status.id}' "${ns[@]}" ciliumendpoint "$1")"
  node="$(jget '{.spec.nodeName}' "${ns[@]}" pod "$1")"
  agent="$(jget '{.items[0].metadata.name}' -n kube-system pods -l k8s-app=cilium --field-selector "spec.nodeName=$node")"
  [[ -n "$id" && -n "$agent" ]] || return 0
  kubectl -n kube-system exec "$agent" -c cilium-agent -- \
    cilium-dbg endpoint get "$id" -o 'jsonpath={[0].status.policy.realized.policy-enabled}' 2>/dev/null
}
# identity_labels <pod>: the labels Cilium derived the endpoint's security identity from, minus
# the pod's own app= label, one per line.
identity_labels() {
  jget '{range .status.identity.labels[*]}{@}{"\n"}{end}' "${ns[@]}" ciliumendpoint "$1" | grep -v '^k8s:app=' | sort
}
nitro_labels="$(identity_labels nitro)"
[[ -n "$nitro_labels" && "$nitro_labels" == "$(identity_labels control)" && "$nitro_labels" == "$(identity_labels neighbor)" ]]
assert "Cilium derives the sandbox pod's identity from its labels alone, exactly as for the neighbor and control pods" $?
[[ "$(policy_enabled server)" == none ]]
assert "control: pod server is not selected by the policy (enforcement: none)" $?
other_ip="$(jget '{.status.podIP}' "${ns[@]}" pod other)"
probe server "http://$other_ip:8080/"
[[ "$PROBE_RC" == 0 && "$PROBE_OUT" == other ]]
assert "control: pod other serves ($other_ip:8080 answers a pod the policy does not select)" $?
for lane in nitro neighbor control; do
  enforced="$(policy_enabled "$lane")"
  [[ "$enforced" == egress ]]
  assert "$lane: Cilium enforces egress policy on this endpoint (enforcement: ${enforced:-unreadable})" $?
  probe "$lane" "http://$server_ip:8080/"
  [[ "$PROBE_RC" == 0 && "$PROBE_OUT" == server ]]
  assert "$lane -> server:8080 ALLOWED by the policy" $?
  probe "$lane" "http://$other_ip:8080/"
  [[ "$PROBE_RC" != 0 ]] && grep -qx 'wget: download timed out' <<<"$PROBE_OUT"
  assert "$lane -> other:8080 DENIED by the policy (connection dropped: timed out)" $?
done

step "6. L7 HTTP policy: the same allow and deny for the sandbox pod and an ordinary pod"
# monitor_l7 <agent-pod> <seconds> <probe-commands...>: capture `cilium-dbg monitor --type l7`
# on one agent while running the given probes, so the allowed and denied requests this step
# makes are the ones in the capture. Runs the capture in the BACKGROUND and the probes in the
# FOREGROUND of the current shell (not a $( ) around the whole thing, so a monitor that
# outlives its window does not leave an orphaned kubectl exec). Sets MONITOR_OUT.
#
# A request made before the monitor is listening is not in the capture, so the probes wait for
# the monitor's own ready lines, "Listening for events on <n> CPUs with 64x4096 of shared memory"
# and then "Press Ctrl-C to quit", for up to MONITOR_READY_WAIT seconds. If they do not come, or
# the monitor exits first, no probe runs and the lane's L7 checks report "nothing was checked".
# The capture window is <seconds> from readiness and stays open at least a second after the
# last probe; then this shell stops its kubectl exec. The timeout inside the pod only bounds a
# monitor whose output nobody reads any more.
MONITOR_OUT=""
MONITOR_READY_WAIT=20
monitor_l7() {
  local agent=$1 seconds=$2; shift 2
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cilium-l7-monitor.XXXXXX")"
  kubectl -n kube-system exec "$agent" -c cilium-agent -- \
    timeout "$((MONITOR_READY_WAIT + seconds + 30))" cilium-dbg monitor --type l7 >"$tmp" 2>&1 &
  local mon_pid=$! ready=0 i
  for ((i = 0; i < MONITOR_READY_WAIT * 5; i++)); do
    if grep -qE '^Listening for events on [0-9]+ CPUs with [0-9]+x[0-9]+ of shared memory$' "$tmp" \
      && grep -qx 'Press Ctrl-C to quit' "$tmp"; then
      ready=1
      break
    fi
    kill -0 "$mon_pid" 2>/dev/null || break
    sleep 0.2
  done
  if ((ready)); then
    local ready_at end last
    ready_at="$(date +%s)"
    "$@"
    end=$((ready_at + seconds)) last=$(($(date +%s) + 2))
    if ((end < last)); then end=$last; fi
    while (($(date +%s) < end)) && kill -0 "$mon_pid" 2>/dev/null; do sleep 0.2; done
  else
    warn "cilium-dbg monitor on $agent printed no ready line within ${MONITOR_READY_WAIT}s, or exited first: no request was sent, so this lane's L7 checks have nothing to check"
  fi
  kill "$mon_pid" 2>/dev/null || true
  wait "$mon_pid" 2>/dev/null || true
  MONITOR_OUT="$(cat "$tmp")"
  rm -f "$tmp"
}
api_ip="$(jget '{.status.podIP}' "${ns[@]}" pod api)"
# cilium-envoy actually Running on the sandbox node, read from the pods themselves rather than
# from rollout status (an over-narrow toleration can schedule 0 pods on a tainted node while
# `rollout status` still reports success for the pods it DID place).
envoy_pods="$(kubectl -n kube-system get pods -l k8s-app=cilium-envoy -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null)"
envoy_on_sandbox=0
while read -r node phase; do
  [[ "$node" == "$nitro_node" && "$phase" == Running ]] && envoy_on_sandbox=1
done <<<"$envoy_pods"
((envoy_on_sandbox == 1))
assert "a cilium-envoy pod is Running on the sandbox node ($nitro_node), not just on the DaemonSet overall" $?
for lane in nitro neighbor control; do
  lane_id="$(jget '{.status.id}' "${ns[@]}" ciliumendpoint "$lane")"
  lane_agent="$(jget '{.items[0].metadata.name}' -n kube-system pods -l k8s-app=cilium --field-selector "spec.nodeName=$(jget '{.spec.nodeName}' "${ns[@]}" pod "$lane")")"
  monitor_l7 "$lane_agent" 6 bash -c "
    kubectl ${ns[*]} exec '$lane' -- wget -q -T 5 -O - 'http://$api_ip:8080/' >/dev/null 2>&1
    kubectl ${ns[*]} exec '$lane' -- wget -q -T 5 -O - 'http://$api_ip:8080/admin' >/dev/null 2>&1
  "
  # Judge THIS lane's own endpoint, and require Cilium's own verdict on the request, not just
  # the HTTP status the client saw: an allow is the proxy forwarding the request (verdict
  # Forwarded) and a 200; a deny is the node-local proxy refusing the request (verdict Denied)
  # and a 403 it generated. A bare "=> 403" could be an app-issued 403 the proxy merely
  # forwarded, so the Request verdict is what makes "DENIED by the policy" a real claim. The
  # endpoint id scopes the match to this client, so another pod's traffic on the same agent
  # cannot satisfy it.
  allow_out="$(python3 "$PY" l7-verdict "$lane_id" ":8080/" Forwarded 200 <<<"$MONITOR_OUT" 2>&1)"; allow_rc=$?
  ((allow_rc == 0))
  assert "$lane -> api:8080/ ALLOWED by the L7 policy, proxy forwarded (${allow_out})" $?
  deny_out="$(python3 "$PY" l7-verdict "$lane_id" "/admin" Denied 403 <<<"$MONITOR_OUT" 2>&1)"; deny_rc=$?
  ((deny_rc == 0))
  assert "$lane -> api:8080/admin DENIED by the L7 policy, proxy answered 403 not a timeout (${deny_out})" $?
done
# Stage 6's verdicts are unaffected: the L7 rule targets "api", a different endpoint selector
# (app: api), and the toFQDNs rule has no toEndpoints at all, so neither overlaps the
# "server:8080" rule and Cilium cannot have merged them.
probe nitro "http://$server_ip:8080/"
[[ "$PROBE_RC" == 0 && "$PROBE_OUT" == server ]]
assert "nitro -> server:8080 is still ALLOWED after the L7 rules" $?
probe nitro "http://$other_ip:8080/"
[[ "$PROBE_RC" != 0 ]] && grep -qx 'wget: download timed out' <<<"$PROBE_OUT"
assert "nitro -> other:8080 is still DENIED after the L7 rules (stage 5's verdict is unchanged)" $?

step "7. FQDN (toFQDNs) policy: the same allow and deny for the sandbox pod and an ordinary pod"
# The allowlisted name resolves to several IPs that rotate between lookups (an AWS edge
# service), which is why toFQDNs is a DNS-proxy feature and not a static IP allowlist: the
# fqdn cache below records what the proxy actually saw, whichever addresses answered this run.
ALLOW_FQDN="checkip.amazonaws.com"
DENY_FQDN="example.net"
for lane in nitro neighbor control; do
  lane_id="$(jget '{.status.id}' "${ns[@]}" ciliumendpoint "$lane")"
  lane_node="$(jget '{.spec.nodeName}' "${ns[@]}" pod "$lane")"
  lane_agent="$(jget '{.items[0].metadata.name}' -n kube-system pods -l k8s-app=cilium --field-selector "spec.nodeName=$lane_node")"
  probe "$lane" "http://$ALLOW_FQDN/"
  [[ "$PROBE_RC" == 0 ]]
  assert "$lane -> $ALLOW_FQDN ALLOWED by the toFQDNs policy" $?
  probe "$lane" "http://$DENY_FQDN/"
  [[ "$PROBE_RC" != 0 ]] && grep -qx 'wget: download timed out' <<<"$PROBE_OUT"
  assert "$lane -> $DENY_FQDN DENIED by the policy (connection dropped: timed out, not a DNS failure)" $?
  # The deny is the policy, not the network: the name still resolves. Count ANSWER records
  # only, the Address: lines that follow the "Name:" line, exactly as step 4 does.
  answered="$(kubectl "${ns[@]}" exec "$lane" -- nslookup "$DENY_FQDN" 2>/dev/null \
    | awk '/^Name:/{named=1; next} named && /^Address:/{n++} END{print n+0}')"
  (( answered > 0 ))
  assert "$lane: $DENY_FQDN still RESOLVES ($answered answer record(s); the deny is the egress policy, not a broken lookup)" $?
  # ...read from the Cilium agent on this lane's own node (the sandbox node for nitro and
  # neighbor, the system node for control), not the cilium-config ConfigMap.
  cache="$(kubectl -n kube-system exec "$lane_agent" -c cilium-agent -- cilium-dbg fqdn cache list 2>/dev/null)"
  echo "$cache" | python3 "$PY" fqdn-cache-has "$lane_id" "$ALLOW_FQDN" >/dev/null 2>&1
  assert "$lane: this lane's node agent fqdn cache recorded a DNS lookup of $ALLOW_FQDN (endpoint $lane_id)" $?
done
# An unselected pod (server) still reaches the denied name, so the timeout above is the policy
# and not the NAT gateway or the name itself being down.
probe server "http://$DENY_FQDN/"
[[ "$PROBE_RC" == 0 ]]
assert "control: pod server (not selected by the policy) still reaches $DENY_FQDN" $?
probe nitro "http://$server_ip:8080/"
[[ "$PROBE_RC" == 0 && "$PROBE_OUT" == server ]]
assert "nitro -> server:8080 is still ALLOWED (the toFQDNs and DNS rules changed nothing else)" $?

step "8. Every AWS resource the cluster owns is tagged auto-delete=no"
# setup.sh's step 8 (tag-sweep) tagged what AWS creates without a tag; this stage only reads.
# ENIs get their own line: they are created by three different parties (EKS for the control
# plane, the node launch templates for each instance's primary interface, and the Cilium
# operator for pod addresses), and a CNI's ENIs are the ones most often left untagged.
vpc_id="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" \
  --query cluster.resourcesVpcConfig.vpcId --output text)"
eni_out="$(python3 "$PY" eni-tags "$vpc_id" 2>&1)"; eni_rc=$?
grep -E '^untagged ' <<<"$eni_out" | sed 's/^/    /'
msg="ENIs in $vpc_id (control plane, nodes, Cilium): $(tail -n1 <<<"$eni_out")"
((eni_rc == 0)); assert "$msg" $?
audit_out="$(python3 "$PY" audit-tags 2>&1)"; audit_rc=$?
grep -Ev '^ok ' <<<"$audit_out" | sed 's/^/    /'
msg="tag audit: $(tail -n1 <<<"$audit_out")"
((audit_rc == 0)); assert "$msg" $?
check_out="$(python3 "$PY" check-tracked 2>&1)"; check_rc=$?
((check_rc == 0)) || sed 's/^/    /' <<<"$check_out"
msg="tracked files under this sample carry no account-specific values: $(tail -n1 <<<"$check_out")"
((check_rc == 0)); assert "$msg" $?

demo_summary "Cilium on Ubuntu, cluster $CLUSTER_NAME"
