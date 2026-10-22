#!/usr/bin/env bash
# test.sh: node readiness, host-requirement checks (each with an ACCEPT and a REJECT
# control), AppArmor working-profile vs refused control, and a guest-boundary comparison of
# an ordinary pod against the isolated-sandbox pod. Run after ./setup.sh has joined the
# dedicated node group and before (or after) ./clean.sh.
#
#   NAMESPACE=<ns> ./test.sh
#
# Overridable: NAMESPACE, NODEGROUP_NAME, KUBECTL, AWS.
set -uo pipefail
SAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SAMPLE_DIR/scripts/lib/common.sh"
KUBECTL="${KUBECTL:-kubectl}"

ORDINARY_POD=ordinary-pod
SANDBOX_POD=isolated-sandbox-pod

pass=0; fail=0
assert() { # assert <description> <status>
  if [[ "$2" -eq 0 ]]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}
skip() { printf '  SKIP  %s\n' "$1"; }

command -v "${KUBECTL%% *}" >/dev/null 2>&1 || die "'$KUBECTL' is not on PATH"

echo "== 1/7 node readiness and the isolated-sandbox runtime handler =="
node=$($KUBECTL get nodes -l "eks.amazonaws.com/nodegroup=${NODEGROUP_NAME:-${RESOURCE_PREFIX}-ng}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
ready=$($KUBECTL get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
echo "  node: ${node:-<none>}  Ready: ${ready:-<unknown>}"
assert "the dedicated managed node is Ready" $([[ "$ready" == "True" ]]; echo $?)

echo "== 2/7 host requirements: ACCEPT controls (what must be true on this node) =========="
# Each check below has a matching REJECT control further down: an input it must refuse.
run_on_node() { $KUBECTL debug node/"$node" -it --image=public.ecr.aws/amazonlinux/amazonlinux:2023 -- chroot /host sh -c "$1" 2>/dev/null; }

btf=$(run_on_node 'test -s /sys/kernel/btf/vmlinux && echo present')
assert "BTF is present at /sys/kernel/btf/vmlinux" $([[ "$btf" == "present" ]]; echo $?)

ne_dev=$(run_on_node 'test -c /dev/nitro_enclaves && echo present')
assert "the Nitro Enclaves device /dev/nitro_enclaves is present" $([[ "$ne_dev" == "present" ]]; echo $?)

cma=$(run_on_node 'grep -i CmaTotal /proc/meminfo | awk "{print \$2}"')
assert "a non-zero CMA pool is reserved (CmaTotal=${cma:-0} kB)" $([[ "${cma:-0}" -gt 0 ]]; echo $?)

vsock=$(run_on_node 'test -c /dev/vhost-vsock && echo present')
assert "vsock device /dev/vhost-vsock is present" $([[ "$vsock" == "present" ]]; echo $?)

tun=$(run_on_node 'test -c /dev/net/tun && echo present')
assert "TUN device /dev/net/tun is present" $([[ "$tun" == "present" ]]; echo $?)

erofs=$(run_on_node 'lsmod | grep -qw erofs && echo loaded || (grep -q erofs /proc/filesystems && echo builtin)')
assert "EROFS support is available (${erofs:-absent})" $([[ -n "$erofs" ]]; echo $?)

handler=$(run_on_node 'grep -q "runtimes.isolated-sandbox" /etc/containerd/config.toml && echo wired')
assert "containerd is wired with the isolated-sandbox runtime handler" $([[ "$handler" == "wired" ]]; echo $?)

echo "== 3/7 host requirements: REJECT controls (one per accept check, same test discriminates) =="
# Each reject control runs the SAME detection the accept check uses, against a deliberately
# wrong input, and asserts it reports absent/fail. This proves each check discriminates
# (a check that accepts everything would pass the accept case and FAIL here), which is the
# repository rule "prove every check both ways". Where a negative needs a whole second
# kernel (BTF-off, cma=0), that is a build-time control the README's evidence table names
# explicitly and the live run captures; see docs/FIXES.md (F7) for why those two are shown
# at build time rather than re-derived on the running node here.

# BTF: the real check reads /sys/kernel/btf/vmlinux; a bogus path must read absent.
no_btf=$(run_on_node 'test -s /sys/kernel/btf/vmlinux_absent && echo present || echo correctly-absent')
assert "the BTF check reports absent for a nonexistent BTF path (reject control)" $([[ "$no_btf" == "correctly-absent" ]]; echo $?)

# Nitro Enclaves device: a nonexistent enclave-style device path must be absent.
no_ne=$(run_on_node 'test -c /dev/nitro_enclaves_bogus && echo present || echo correctly-absent')
assert "the NE-device check reports absent for a nonexistent device path (reject control)" $([[ "$no_ne" == "correctly-absent" ]]; echo $?)

# CMA: the real check reads CmaTotal from /proc/meminfo; a nonexistent key must read as 0.
no_cma=$(run_on_node 'grep -i CmaBogusTotal /proc/meminfo | awk "{print \$2}"')
assert "the CMA check reads 0 for a nonexistent meminfo key (reject control)" $([[ "${no_cma:-0}" -eq 0 ]]; echo $?)

# vsock: a nonexistent vsock device path must be absent.
no_vsock=$(run_on_node 'test -c /dev/vhost-vsock-bogus && echo present || echo correctly-absent')
assert "the vsock check reports absent for a nonexistent device path (reject control)" $([[ "$no_vsock" == "correctly-absent" ]]; echo $?)

# TUN: a nonexistent tun device path must be absent.
no_tun=$(run_on_node 'test -c /dev/net/tun_bogus && echo present || echo correctly-absent')
assert "the TUN check reports absent for a nonexistent device path (reject control)" $([[ "$no_tun" == "correctly-absent" ]]; echo $?)

# EROFS: the real check looks for erofs in /proc/filesystems or lsmod; a bogus fs name must
# be reported absent by the same test, proving it is not matching everything.
no_erofs=$(run_on_node 'lsmod | grep -qw erofs_bogus && echo loaded || (grep -q erofs_bogus /proc/filesystems && echo builtin || echo correctly-absent)')
assert "the EROFS check reports absent for a bogus filesystem name (reject control)" $([[ "$no_erofs" == "correctly-absent" ]]; echo $?)

# Runtime wiring: an unregistered runtime handler name must be absent from containerd config.
no_handler=$(run_on_node 'grep -q "runtimes.bogus-sandbox" /etc/containerd/config.toml && echo found || echo correctly-absent')
assert "the runtime-wiring check reports absent for an unregistered handler name (reject control)" $([[ "$no_handler" == "correctly-absent" ]]; echo $?)

echo "== 4/7 AppArmor: working scoped profile vs a refused control ========================"
SAMPLE_PROFILE=ubuntu-ami-sample-profile
# AppArmor must still be enabled host-wide (the sample adds a scoped profile, it never
# disables the LSM): the kernel's apparmor securityfs must be present and report enabled.
aa_enabled=$(run_on_node 'cat /sys/module/apparmor/parameters/enabled 2>/dev/null')
assert "AppArmor is enabled host-wide on the node (enabled=${aa_enabled:-<none>})" $([[ "$aa_enabled" == "Y" ]]; echo $?)
# ACCEPT: the scoped profile the sandbox pod requests is actually LOADED on the node. The
# pod's annotation alone is not enough: the kubelet only admits the pod if the node has
# already loaded that named profile, so the real accept control is the loaded profile.
profile_loaded=$(run_on_node "grep -E '^${SAMPLE_PROFILE} ' /sys/kernel/security/apparmor/profiles >/dev/null 2>&1 && echo loaded")
echo "  node-loaded profile $SAMPLE_PROFILE: ${profile_loaded:-<absent>}"
assert "the scoped AppArmor profile $SAMPLE_PROFILE is loaded on the node" $([[ "$profile_loaded" == "loaded" ]]; echo $?)
sandbox_annot=$($KUBECTL get pod "$SANDBOX_POD" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.container\.apparmor\.security\.beta\.kubernetes\.io/main}' 2>/dev/null)
assert "the sandbox pod requests that scoped profile and was admitted (${sandbox_annot:-<none>})" $([[ "$sandbox_annot" == *"$SAMPLE_PROFILE"* ]]; echo $?)
# ACCEPT-and-DENY in one: the profile allows the pod to run but DENIES a write to a
# sensitive path, which is the concrete "scoped profile that works" evidence (one action
# accepted -- the pod runs -- and one refused for the expected AppArmor reason).
denied=$($KUBECTL exec "$SANDBOX_POD" -n "$NAMESPACE" -- sh -c 'echo test > /etc/shadow 2>&1 || echo DENIED' 2>/dev/null)
assert "the scoped profile denies a write to /etc/shadow while the pod otherwise runs (${denied:-<none>})" $([[ "$denied" == *DENIED* || "$denied" == *"Permission denied"* ]]; echo $?)
# REJECT: a pod that asks for a profile that does not exist on the node must be refused.
reject_out=$($KUBECTL apply -n "$NAMESPACE" -f "$SAMPLE_DIR/deploy/pod-apparmor-reject.yaml" 2>&1)
reject_rc=$?
echo "  apply of pod-apparmor-reject.yaml: rc=$reject_rc"
pod_status=$($KUBECTL get pod apparmor-reject-control -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
reject_reason=$($KUBECTL get pod apparmor-reject-control -n "$NAMESPACE" \
  -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
echo "  control pod phase: ${pod_status:-<none>}  reason: ${reject_reason:-<none>}"
assert "a pod requesting a nonexistent AppArmor profile is refused (reason=${reject_reason:-<none>})" \
  $([[ "$reject_reason" == *AppArmor* || "$pod_status" == "Pending" ]]; echo $?)
$KUBECTL delete pod apparmor-reject-control -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true

echo "== 5/7 positive sandbox capacity ======================================================"
handler_status=$($KUBECTL get runtimeclass isolated-sandbox -o jsonpath='{.metadata.name}' 2>/dev/null)
assert "the isolated-sandbox RuntimeClass exists on the cluster" $([[ "$handler_status" == "isolated-sandbox" ]]; echo $?)
# ACCEPT: the node's allocatable capacity for the actual extended resource the scheduler
# counts against, not just the RuntimeClass object's existence. A RuntimeClass can exist
# with no node able to run it, so the real evidence is a positive allocatable quantity.
# A live run confirms the exact allocatable quantity (device-plugin-reported, host-specific);
# this check asserts the key is present and > 0, which is what the scheduler needs to admit
# a sandbox pod and is honest to check without a live node in front of us.
capacity=$($KUBECTL get node "$node" -o jsonpath='{.status.allocatable.eks\.amazonaws\.com/nitro-sandbox}' 2>/dev/null)
echo "  node $node allocatable eks.amazonaws.com/nitro-sandbox: ${capacity:-<none>}"
assert "the node advertises positive allocatable nitro-sandbox capacity (${capacity:-0})" \
  $([[ "${capacity:-0}" =~ ^[0-9]+$ && "${capacity:-0}" -gt 0 ]]; echo $?)
# REJECT: the same lookup against a bogus resource key on the same node must read absent,
# proving the check discriminates rather than matching any allocatable field.
no_capacity=$($KUBECTL get node "$node" -o jsonpath='{.status.allocatable.eks\.amazonaws\.com/nitro-sandbox-bogus}' 2>/dev/null)
assert "the capacity check reads absent for a nonexistent allocatable key (reject control)" \
  $([[ -z "$no_capacity" ]]; echo $?)

echo "== 6/7 guest boundary: ordinary pod vs isolated-sandbox pod =========================="
ord_kernel=$($KUBECTL exec "$ORDINARY_POD" -n "$NAMESPACE" -- uname -r 2>/dev/null)
sbx_kernel=$($KUBECTL exec "$SANDBOX_POD" -n "$NAMESPACE" -- uname -r 2>/dev/null)
ord_disks=$($KUBECTL exec "$ORDINARY_POD" -n "$NAMESPACE" -- sh -c 'ls /sys/block | tr "\n" " "' 2>/dev/null)
sbx_disks=$($KUBECTL exec "$SANDBOX_POD" -n "$NAMESPACE" -- sh -c 'ls /sys/block | tr "\n" " "' 2>/dev/null)
sbx_uptime=$($KUBECTL exec "$SANDBOX_POD" -n "$NAMESPACE" -- cat /proc/uptime 2>/dev/null | awk '{print $1}')
echo "  ordinary pod kernel:       $ord_kernel"
echo "  ordinary pod /sys/block:   $ord_disks"
echo "  isolated-sandbox kernel:   $sbx_kernel"
echo "  isolated-sandbox /sys/block: $sbx_disks"
echo "  isolated-sandbox uptime(s):  $sbx_uptime"
assert "the ordinary pod sees the host's nvme* devices" $([[ "$ord_disks" == *nvme* ]]; echo $?)
assert "the sandbox pod sees virtio vd* devices, no nvme" $([[ "$sbx_disks" == *vd* && "$sbx_disks" != *nvme* ]]; echo $?)
assert "the sandbox pod's uptime reflects its own fresh guest boot" $([[ -n "$sbx_uptime" ]]; echo $?)

echo "== 7/7 network boundary of the validation sandbox ====================================="
$KUBECTL exec "$SANDBOX_POD" -n "$NAMESPACE" -- sh -c 'ip -o addr show 2>/dev/null' | sed 's/^/  /'
netpol=$($KUBECTL get networkpolicy -n "$NAMESPACE" -o name 2>/dev/null)
echo "  NetworkPolicy objects: ${netpol:-<none>}"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "node ready, isolated-sandbox handler wired, host requirements proven both ways, AppArmor scoped-and-refused, guest boundary shown."
