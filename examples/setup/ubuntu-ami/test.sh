#!/usr/bin/env bash
# test.sh: node readiness and labels, host-requirement checks (each with an ACCEPT and a REJECT
# control), AppArmor working-profile vs refused control, positive sandbox capacity, and a
# guest-boundary comparison of an ordinary pod against the isolated-sandbox pod. Run after
# ./setup.sh has joined the dedicated node group and before ./clean.sh.
#
#   KUBE_CONTEXT=<your-context> ./test.sh
#
# Every kubectl call passes --context "$KUBE_CONTEXT" (required; never the current context), and
# the context is checked against CLUSTER_NAME's API endpoint first. It tests the run recorded in
# the run state (setup.sh writes it), or RUN_ID=<id>; the node group name is derived from it.
# Overridable: NAMESPACE, POD_READY_TIMEOUT. It first waits,
# bounded, for both validation pods to be Ready (scripts/wait-pods-ready.sh), so a test.sh run
# straight after setup.sh does not read pods that are still starting. Expected values come from
# packages/sources.lock: the host kernel is <linux-kernel-source ref>${KERNEL_LOCALVERSION}
# (6.18.56-nitro-ga) and the sandbox's guest kernel is the runtime archive's guest_kernel
# (6.18.54). Every helper pod this script creates (one kubectl debug pod, the AppArmor reject
# control) lives in the sample's namespace and is deleted by its exact name.
set -uo pipefail
SAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SAMPLE_DIR/scripts/lib/common.sh"
require_run_id

ORDINARY_POD=ordinary-pod
SANDBOX_POD=isolated-sandbox-pod
SAMPLE_PROFILE=ubuntu-ami-sample-profile
HOST_KERNEL="$(lock_field linux-kernel-source ref)${KERNEL_LOCALVERSION}"
GUEST_KERNEL="$(lock_field runtime-archive guest_kernel)"

pass=0; fail=0
assert() { # assert <description> <status>
  if [[ "$2" -eq 0 ]]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}

command -v kubectl >/dev/null 2>&1 || die "kubectl is not on PATH"
require_kube_context   # KUBE_CONTEXT is set and is cluster CLUSTER_NAME, before any read or change
ns_err=$(mktemp)
ns_json=$(kc get namespace "$NAMESPACE" -o json 2>"$ns_err") \
  || { m=$(head -n 2 "$ns_err"); rm -f "$ns_err"; die "could not read namespace $NAMESPACE (${m}); run ./setup.sh first, or check the kube context"; }
rm -f "$ns_err"
ns_owner=$(printf '%s' "$ns_json" | json_get 'd["metadata"].get("labels", {}).get("app.kubernetes.io/part-of", "")')
ns_run=$(printf '%s' "$ns_json" | json_get 'd["metadata"].get("labels", {}).get("app.kubernetes.io/instance", "")')
[[ "$ns_owner" == "$RESOURCE_PREFIX" && "$ns_run" == "$RUN_ID" ]] || die "namespace $NAMESPACE is not run $RUN_ID's (part-of='${ns_owner:-none}', instance='${ns_run:-none}')"

echo "== 0/7 bounded wait for the validation pods to be Ready =================================="
bash "$SAMPLE_DIR/scripts/wait-pods-ready.sh" "$ORDINARY_POD" "$SANDBOX_POD"
assert "both validation pods are Ready within ${POD_READY_TIMEOUT:-300}s" $?

echo "== 1/7 node readiness, labels and the isolated-sandbox runtime handler =="
node=$(kc get nodes -l "eks.amazonaws.com/nodegroup=${NODEGROUP_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -n "$node" ]] || die "no node in node group $NODEGROUP_NAME"
ready=$(kc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
echo "  node: $node  Ready: ${ready:-<unknown>}"
assert "the dedicated managed node is Ready" $([[ "$ready" == "True" ]]; echo $?)
l1=$(kc get node "$node" -o 'jsonpath={.metadata.labels.eks\.amazonaws\.com/nitro-sandbox}' 2>/dev/null)
l2=$(kc get node "$node" -o 'jsonpath={.metadata.labels.sandbox\.preview/nitro}' 2>/dev/null)
lx=$(kc get node "$node" -o 'jsonpath={.metadata.labels.sandbox\.preview/nitro-bogus}' 2>/dev/null)
assert "the node carries eks.amazonaws.com/nitro-sandbox=true (${l1:-<absent>})" $([[ "$l1" == "true" ]]; echo $?)
assert "the node carries sandbox.preview/nitro=true (${l2:-<absent>})" $([[ "$l2" == "true" ]]; echo $?)
assert "the label check reads absent for a label the node does not carry (reject control)" $([[ -z "$lx" ]]; echo $?)

echo "== 2/7 host requirements: ACCEPT and REJECT controls, read on the node itself =========="
# One kubectl debug pod in the sample's namespace runs every probe in the host's root and prints
# KEY=VALUE lines; it is then deleted by its exact name. Each REJECT probe runs the SAME
# detection as its ACCEPT probe against a deliberately wrong input, so a check that accepted
# everything would fail here (the repository rule "prove every check both ways"). The negative
# that needs a whole second kernel (a .config without BTF, NITRO_ENCLAVES=m) is proven on the
# REAL assertion in scripts/test-host-gates.sh, clusterless.
PROBE='
echo KERNEL=$(uname -r)
for p in btf:/sys/kernel/btf/vmlinux btf_bogus:/sys/kernel/btf/vmlinux_absent; do k=${p%%:*}; f=${p#*:}; test -s "$f" && echo "$k=present" || echo "$k=absent"; done
for p in ne:/dev/nitro_enclaves ne_bogus:/dev/nitro_enclaves_bogus vsock:/dev/vhost-vsock vsock_bogus:/dev/vhost-vsock-bogus tun:/dev/net/tun tun_bogus:/dev/net/tun_bogus; do k=${p%%:*}; f=${p#*:}; test -c "$f" && echo "$k=present" || echo "$k=absent"; done
echo cma=$(awk "/^CmaTotal:/{print \$2}" /proc/meminfo)
echo cma_bogus=$(awk "/^CmaBogusTotal:/{print \$2}" /proc/meminfo)
grep -qw erofs /proc/filesystems || modprobe erofs 2>/dev/null; grep -qw erofs /proc/filesystems && echo erofs=present || echo erofs=absent
grep -qw erofs_bogus /proc/filesystems && echo erofs_bogus=present || echo erofs_bogus=absent
grep -q "runtimes.isolated-sandbox" /etc/containerd/config.toml && echo handler=present || echo handler=absent
grep -q "runtimes.bogus-sandbox" /etc/containerd/config.toml && echo handler_bogus=present || echo handler_bogus=absent
echo containerd_gate=$(bash /usr/local/share/ubuntu-ami-sample/scripts/30-runtime-install.sh --check-containerd >/dev/null 2>&1 && echo ok || echo refused)
echo containerd_version=$(containerd --version 2>&1 | head -n 1)
echo apparmor_enabled=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)
grep -qE "^'"$SAMPLE_PROFILE"' " /sys/kernel/security/apparmor/profiles && echo apparmor_profile=loaded || echo apparmor_profile=absent
grep -qE "^profile-that-does-not-exist " /sys/kernel/security/apparmor/profiles && echo apparmor_profile_bogus=loaded || echo apparmor_profile_bogus=absent
echo apparmor_shadow_denials=$( (dmesg 2>/dev/null; journalctl -k --no-pager 2>/dev/null) | grep "apparmor=\"DENIED\"" | grep "profile=\"'"$SAMPLE_PROFILE"'\"" | grep -c "name=\"/etc/shadow\"")
echo apparmor_bogus_denials=$( (dmesg 2>/dev/null; journalctl -k --no-pager 2>/dev/null) | grep "apparmor=\"DENIED\"" | grep "profile=\"profile-that-does-not-exist\"" | grep -c "name=\"/etc/shadow\"")
'
# The AppArmor evidence in section 3 reads the node's kernel log for a denial of the sandbox's
# /etc/shadow write, so that write is attempted here, before the probe reads the log. Each pod's
# own AppArmor label (/proc/self/attr/current) is read first, the ordinary pod's as the control.
sbx_attr=$(kc exec "$SANDBOX_POD" -n "$NAMESPACE" -- cat /proc/self/attr/current 2>/dev/null | tr -d '\0')
ord_attr=$(kc exec "$ORDINARY_POD" -n "$NAMESPACE" -- cat /proc/self/attr/current 2>/dev/null | tr -d '\0')
denied=$(kc exec "$SANDBOX_POD" -n "$NAMESPACE" -- sh -c 'echo test > /etc/shadow 2>&1 || echo DENIED' 2>/dev/null)
dbg_err=$(mktemp)
kc debug "node/$node" -n "$NAMESPACE" --profile=sysadmin \
  --image=public.ecr.aws/amazonlinux/amazonlinux:2023 -- chroot /host sh -c "$PROBE" >"$dbg_err" 2>&1
dbg_pod=$(grep -oE 'node-debugger-[A-Za-z0-9.-]+' "$dbg_err" | head -n 1)
rm -f "$dbg_err"
probe_out=""
if [[ -n "$dbg_pod" ]]; then
  kc wait -n "$NAMESPACE" "pod/$dbg_pod" --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s >/dev/null 2>&1
  probe_out=$(kc logs -n "$NAMESPACE" "$dbg_pod" 2>/dev/null)
  kc delete pod "$dbg_pod" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1
else
  echo "  could not create the node debug pod"
fi
printf '%s\n' "$probe_out" | sed 's/^/  node> /'
v() { printf '%s\n' "$probe_out" | sed -n "s/^$1=//p" | head -n 1; }
assert "the node runs the host kernel $HOST_KERNEL ($(v KERNEL))" $([[ "$(v KERNEL)" == "$HOST_KERNEL" ]]; echo $?)
for k in btf ne vsock tun erofs handler; do
  assert "ACCEPT $k: present on the node" $([[ "$(v $k)" == present ]]; echo $?)
  assert "REJECT $k: the same probe reads absent for a bogus input" $([[ "$(v ${k}_bogus)" == absent ]]; echo $?)
done
cma=$(v cma); cma_bogus=$(v cma_bogus)
assert "ACCEPT cma: a non-zero CMA pool is reserved (CmaTotal=${cma:-0} kB)" $([[ "${cma:-0}" =~ ^[0-9]+$ && "${cma:-0}" -gt 0 ]]; echo $?)
assert "REJECT cma: the same probe reads nothing for a bogus meminfo key" $([[ -z "$cma_bogus" ]]; echo $?)
assert "containerd on the node passes the GA shim's 2.1.x to 2.3.x gate ($(v containerd_version))" $([[ "$(v containerd_gate)" == ok ]]; echo $?)

echo "== 3/7 AppArmor: host LSM enabled, scoped profile loaded, refused control ==============="
assert "AppArmor is enabled host-wide on the node (enabled=$(v apparmor_enabled))" $([[ "$(v apparmor_enabled)" == "Y" ]]; echo $?)
assert "ACCEPT: the scoped profile $SAMPLE_PROFILE is loaded on the node" $([[ "$(v apparmor_profile)" == loaded ]]; echo $?)
assert "REJECT: the same probe reads absent for a profile the node never loaded" $([[ "$(v apparmor_profile_bogus)" == absent ]]; echo $?)
sbx_profile=$(kc get pod "$SANDBOX_POD" -n "$NAMESPACE" -o jsonpath='{.spec.securityContext.appArmorProfile.localhostProfile}' 2>/dev/null)
sbx_phase=$(kc get pod "$SANDBOX_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
echo "  sandbox pod: profile=${sbx_profile:-<none>} phase=${sbx_phase:-<none>}"
assert "the sandbox pod requests the scoped profile and runs (phase=${sbx_phase:-<none>})" $([[ "$sbx_profile" == "$SAMPLE_PROFILE" && "$sbx_phase" == Running ]]; echo $?)
assert "the sandbox's write to /etc/shadow fails while the pod otherwise runs (${denied:-<none>})" $([[ "$denied" == *DENIED* || "$denied" == *"Permission denied"* ]]; echo $?)
# A failed write alone proves nothing about AppArmor (a read-only filesystem or file mode fails it
# too). It counts only with AppArmor evidence: the sandbox process runs under the scoped profile
# in enforce mode, or the node logged an AppArmor denial of that write under that profile.
denials="$(v apparmor_shadow_denials)"
echo "  sandbox attr/current: '${sbx_attr:-<unreadable>}'  ordinary attr/current: '${ord_attr:-<unreadable>}'  node denials: ${denials:-<none>}"
assert "ACCEPT: the write failure is AppArmor's (attr/current is '$SAMPLE_PROFILE (enforce)', or the node logged a denial)" \
  $([[ "$sbx_attr" == "$SAMPLE_PROFILE (enforce)" || ( "${denials:-0}" =~ ^[0-9]+$ && "${denials:-0}" -gt 0 ) ]]; echo $?)
assert "REJECT: the same label read on the ordinary pod does not name $SAMPLE_PROFILE ('${ord_attr:-<unreadable>}')" $([[ "$ord_attr" != "$SAMPLE_PROFILE"* ]]; echo $?)
assert "REJECT: the same denial count for a profile the node never loaded is 0 ($(v apparmor_bogus_denials))" $([[ "$(v apparmor_bogus_denials)" == 0 ]]; echo $?)
# REJECT control: an ordinary pod on the same node naming a profile the node never loaded. It
# must be refused for the AppArmor reason, on THIS node (a pod that never schedules would be
# Pending for the wrong reason). Rendered with this run's node group and namespace.
REJ=apparmor-reject-control
rendered=$(mktemp)
sed -e "s/@NODEGROUP@/$NODEGROUP_NAME/g" -e "s/^  namespace: ubuntu-ami-sample$/  namespace: $NAMESPACE/" \
  "$SAMPLE_DIR/deploy/pod-apparmor-reject.yaml" > "$rendered"
kc apply -n "$NAMESPACE" -f "$rendered" >/dev/null 2>&1
rm -f "$rendered"
rej_node=""; rej_text=""
for _ in $(seq 1 24); do
  rej_node=$(kc get pod "$REJ" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  rej_text=$(kc get pod "$REJ" -n "$NAMESPACE" -o jsonpath='{.status.reason} {.status.message} {.status.containerStatuses[0].state.waiting.reason} {.status.containerStatuses[0].state.waiting.message}' 2>/dev/null)
  [[ "$rej_text" =~ [Aa]pp[Aa]rmor ]] && break
  sleep 5
done
rej_phase=$(kc get pod "$REJ" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
echo "  reject control: node=${rej_node:-<none>} phase=${rej_phase:-<none>} status: ${rej_text:-<none>}"
assert "REJECT: a pod naming an unloaded AppArmor profile is refused on the sandbox node for the AppArmor reason" \
  $([[ "$rej_node" == "$node" && "$rej_text" =~ [Aa]pp[Aa]rmor && "$rej_phase" != Running ]]; echo $?)
kc delete pod "$REJ" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true

echo "== 4/7 positive sandbox capacity ======================================================"
handler_status=$(kc get runtimeclass isolated-sandbox -o jsonpath='{.metadata.name}' 2>/dev/null)
assert "the isolated-sandbox RuntimeClass exists on the cluster" $([[ "$handler_status" == "isolated-sandbox" ]]; echo $?)
capacity=$(kc get node "$node" -o jsonpath='{.status.allocatable.eks\.amazonaws\.com/nitro-sandbox}' 2>/dev/null)
echo "  node $node allocatable eks.amazonaws.com/nitro-sandbox: ${capacity:-<none>}"
assert "the node advertises positive allocatable nitro-sandbox capacity (${capacity:-0})" \
  $([[ "${capacity:-0}" =~ ^[0-9]+$ && "${capacity:-0}" -gt 0 ]]; echo $?)
no_capacity=$(kc get node "$node" -o jsonpath='{.status.allocatable.eks\.amazonaws\.com/nitro-sandbox-bogus}' 2>/dev/null)
assert "the capacity check reads absent for a nonexistent allocatable key (reject control)" \
  $([[ -z "$no_capacity" ]]; echo $?)

echo "== 5/7 guest boundary: kernel and block devices, ordinary pod vs isolated-sandbox pod ====="
ord_kernel=$(kc exec "$ORDINARY_POD" -n "$NAMESPACE" -- uname -r 2>/dev/null)
sbx_kernel=$(kc exec "$SANDBOX_POD" -n "$NAMESPACE" -- uname -r 2>/dev/null)
ord_disks=$(kc exec "$ORDINARY_POD" -n "$NAMESPACE" -- sh -c 'ls /sys/block | tr "\n" " "' 2>/dev/null)
sbx_disks=$(kc exec "$SANDBOX_POD" -n "$NAMESPACE" -- sh -c 'ls /sys/block | tr "\n" " "' 2>/dev/null)
echo "  ordinary pod kernel:         $ord_kernel"
echo "  ordinary pod /sys/block:     $ord_disks"
echo "  isolated-sandbox kernel:     $sbx_kernel"
echo "  isolated-sandbox /sys/block: $sbx_disks"
assert "the ordinary pod shares the host kernel $HOST_KERNEL" $([[ "$ord_kernel" == "$HOST_KERNEL" ]]; echo $?)
assert "the sandbox pod runs the guest kernel $GUEST_KERNEL, not the host's" $([[ "$sbx_kernel" == "$GUEST_KERNEL"* && "$sbx_kernel" != "$HOST_KERNEL" ]]; echo $?)
assert "the ordinary pod sees the host's nvme* devices" $([[ "$ord_disks" == *nvme* ]]; echo $?)
assert "the sandbox pod sees virtio vd* devices and no nvme*" $([[ "$sbx_disks" == *vd* && "$sbx_disks" != *nvme* ]]; echo $?)

echo "== 6/7 guest boundary: boot uptime matches the sandbox pod's age, not the host's ========="
ord_uptime=$(kc exec "$ORDINARY_POD" -n "$NAMESPACE" -- cat /proc/uptime 2>/dev/null | awk '{print int($1)}')
sbx_uptime=$(kc exec "$SANDBOX_POD" -n "$NAMESPACE" -- cat /proc/uptime 2>/dev/null | awk '{print int($1)}')
sbx_start=$(kc get pod "$SANDBOX_POD" -n "$NAMESPACE" -o jsonpath='{.status.startTime}' 2>/dev/null)
sbx_age=$(( $(date -u +%s) - $(date -u -d "${sbx_start:-now}" +%s) ))
echo "  host uptime (ordinary pod): ${ord_uptime:-?} s"
echo "  sandbox guest uptime:       ${sbx_uptime:-?} s"
echo "  sandbox pod age:            ${sbx_age} s (started ${sbx_start:-?})"
assert "the sandbox guest booted with its pod (uptime <= pod age + 120 s)" \
  $([[ "${sbx_uptime:-x}" =~ ^[0-9]+$ && "$sbx_uptime" -le $((sbx_age + 120)) ]]; echo $?)
assert "the sandbox guest booted after the host (guest uptime < host uptime)" \
  $([[ "${sbx_uptime:-x}" =~ ^[0-9]+$ && "${ord_uptime:-x}" =~ ^[0-9]+$ && "$sbx_uptime" -lt "$ord_uptime" ]]; echo $?)

echo "== 7/7 network boundary of the validation sandbox ====================================="
kc exec "$SANDBOX_POD" -n "$NAMESPACE" -- sh -c 'ip -o addr show 2>/dev/null' | sed 's/^/  /'
netpol=$(kc get networkpolicy -n "$NAMESPACE" -o name 2>/dev/null)
echo "  NetworkPolicy objects: ${netpol:-<none>}"
assert "the sandbox pod's egress policy is present" $([[ "$netpol" == *isolated-sandbox-pod-policy* ]]; echo $?)
# The live object, not the file: egress only to kube-system pods labelled k8s-app=kube-dns, port 53.
kc get networkpolicy isolated-sandbox-pod-policy -n "$NAMESPACE" -o json 2>/dev/null \
  | python3 "$SAMPLE_DIR/scripts/check-network-policy.py" | sed 's/^/  /'
assert "the live policy allows egress only to kube-system/k8s-app=kube-dns on port 53" "${PIPESTATUS[1]}"
# The policy at work, three ways, from inside the sandbox:
#   ALLOW DNS: a lookup through the cluster DNS answers;
#   DENY 443:  a TCP connect to the API Service on 443 is refused;
#   DENY 53 to a non-DNS pod: the ordinary pod listens on TCP 53 (deploy/pod-ordinary.yaml); the
#   connect from the sandbox to that pod's IP on 53 is refused, while the same listener answers
#   inside the ordinary pod (so "refused" is the policy, not a missing listener).
api_ip=$(kc exec "$SANDBOX_POD" -n "$NAMESPACE" -- sh -c 'getent hosts kubernetes.default.svc.cluster.local | cut -d" " -f1' 2>/dev/null)
echo "  sandbox DNS lookup of kubernetes.default.svc.cluster.local: ${api_ip:-<no answer>}"
assert "ALLOW: DNS answers from inside the sandbox" $([[ "$api_ip" =~ ^[0-9.]+$ ]]; echo $?)
tcp=$(kc exec "$SANDBOX_POD" -n "$NAMESPACE" -- bash -c "timeout 5 bash -c '</dev/tcp/${api_ip:-0.0.0.0}/443' 2>/dev/null && echo connected || echo refused" 2>/dev/null)
echo "  sandbox TCP connect to ${api_ip:-?}:443: ${tcp:-<none>}"
assert "DENY: a TCP connect the policy does not allow is refused" $([[ "$tcp" == refused ]]; echo $?)
ord_ip=$(kc get pod "$ORDINARY_POD" -n "$NAMESPACE" -o jsonpath='{.status.podIP}' 2>/dev/null)
decoy=$(kc exec "$ORDINARY_POD" -n "$NAMESPACE" -- bash -c "timeout 5 bash -c '</dev/tcp/${ord_ip:-0.0.0.0}/53' 2>/dev/null && echo connected || echo refused" 2>/dev/null)
echo "  ordinary pod's own TCP 53 listener at ${ord_ip:-?}:53, from inside it: ${decoy:-<none>}"
assert "the port-53 decoy listener in the ordinary pod answers (control for the next check)" $([[ "$decoy" == connected ]]; echo $?)
dns53=$(kc exec "$SANDBOX_POD" -n "$NAMESPACE" -- bash -c "timeout 5 bash -c '</dev/tcp/${ord_ip:-0.0.0.0}/53' 2>/dev/null && echo connected || echo refused" 2>/dev/null)
echo "  sandbox TCP connect to the non-DNS pod ${ord_ip:-?}:53: ${dns53:-<none>}"
assert "DENY: port 53 to a pod that is not cluster DNS is refused" $([[ "$dns53" == refused ]]; echo $?)

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "node ready and labelled, host requirements proven both ways, AppArmor scoped-and-refused, guest boundary shown."
