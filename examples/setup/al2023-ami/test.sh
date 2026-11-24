#!/usr/bin/env bash
# test.sh: read live evidence that the AL2023 Nitro Sandbox AMI blueprint works. Node readiness
# and the eks.amazonaws.com/nitro-sandbox label, positive sandbox capacity, the guest-boundary
# comparison (the isolated-sandbox pod reports its own guest kernel and virtio disks, the
# ordinary pod the host kernel and host disks), and that the isolated pod, booted
# network-isolated, has only loopback. Run after ./setup.sh, before ./clean.sh.
#
#   KUBE_CONTEXT=<your-context> ./test.sh
#
# Every kubectl call passes --context "$KUBE_CONTEXT" (required; never the current context), and
# the context is checked against CLUSTER_NAME's API endpoint first. It reads the run recorded by
# setup.sh, or RUN_ID=<id>.
set -uo pipefail
SAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SAMPLE_DIR/scripts/lib/common.sh"
require_run_id
require_identity RESOURCE_PREFIX CLUSTER_NAME AWS_REGION NAMESPACE

ISO_POD=isolated-sandbox-hello
ORD_POD=ordinary-hello
LABEL_KEY="${NODE_LABEL%%=*}"; LABEL_VAL="${NODE_LABEL#*=}"

pass=0; fail=0
assert() { if [ "$2" -eq 0 ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }

command -v kubectl >/dev/null 2>&1 || die "kubectl is not on PATH"
require_kube_context

echo "== 1/5 the sandbox node is Ready and carries $NODE_LABEL =="
# The node the isolated pod landed on (works for both join paths).
node=$(kc get pod -n "$NAMESPACE" "$ISO_POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
[ -n "$node" ] || die "pod $ISO_POD has no node yet; run ./setup.sh and wait for it to schedule"
ready=$(kc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
echo "  node: $node  Ready: ${ready:-<unknown>}"
assert "the sandbox node is Ready" "$([ "$ready" = True ]; echo $?)"
has_label=$(kc get node "$node" -o json | json_get "d['metadata']['labels'].get('$LABEL_KEY')")
assert "the node carries $NODE_LABEL" "$([ "$has_label" = "$LABEL_VAL" ]; echo $?)"

echo "== 2/5 the node advertises sandbox capacity =="
cap=$(kc get node "$node" -o json | json_get "d['status']['allocatable'].get('eks.amazonaws.com/nitro-sandbox','0')")
echo "  eks.amazonaws.com/nitro-sandbox allocatable: ${cap:-0}"
assert "allocatable eks.amazonaws.com/nitro-sandbox > 0" "$([[ "${cap:-}" =~ ^[1-9][0-9]*$ ]]; echo $?)"

echo "== 3/5 the isolated pod runs in a sandbox: its own guest kernel and virtio disks =="
iso_kernel=$(kc exec -n "$NAMESPACE" "$ISO_POD" -- uname -r 2>/dev/null)
ord_kernel=$(kc exec -n "$NAMESPACE" "$ORD_POD" -- uname -r 2>/dev/null)
echo "  isolated pod kernel: ${iso_kernel:-<none>}"
echo "  ordinary pod kernel: ${ord_kernel:-<none>}"
assert "the isolated pod's kernel differs from the ordinary pod's (its own guest kernel)" \
  "$([ -n "$iso_kernel" ] && [ -n "$ord_kernel" ] && [ "$iso_kernel" != "$ord_kernel" ]; echo $?)"
iso_blk=$(kc exec -n "$NAMESPACE" "$ISO_POD" -- sh -c 'ls -1 /sys/block' 2>/dev/null | tr '\n' ' ')
echo "  isolated pod /sys/block: ${iso_blk:-<none>}"
assert "the isolated pod has virtio disks (vda, vdb, ...), not the host's nvme" \
  "$(printf '%s\n' $iso_blk | grep -Eq '^vd[a-z]+$' && ! printf '%s\n' $iso_blk | grep -Eq '^nvme'; echo $?)"

echo "== 4/5 the isolated pod has its own boot clock: a younger uptime than the ordinary pod's node =="
iso_up=$(kc exec -n "$NAMESPACE" "$ISO_POD" -- sh -c "awk '{print \$1}' /proc/uptime" 2>/dev/null)
ord_up=$(kc exec -n "$NAMESPACE" "$ORD_POD" -- sh -c "awk '{print \$1}' /proc/uptime" 2>/dev/null)
echo "  isolated pod boot uptime (s): ${iso_up:-<none>}   ordinary pod (its node's) uptime (s): ${ord_up:-<none>}"
num='^[0-9]+([.][0-9]+)?$'
assert "the isolated pod's uptime is shorter than the ordinary pod's (its own boot, after the node's)" \
  "$([[ "${iso_up:-}" =~ $num ]] && [[ "${ord_up:-}" =~ $num ]] && awk -v a="$iso_up" -v b="$ord_up" 'BEGIN{exit !(a<b)}'; echo $?)"

echo "== 5/5 the network-isolated pod has only loopback =="
# The isolated pod is booted sandbox.amazonaws.com/network-isolated=true. The guest's own kernel
# tables show it: the local IPv4 addresses in /proc/net/fib_trie are 127.0.0.1 only, and
# /proc/net/route has its header line and no route. The image has no `ip`, so the files are read
# directly; each must be read to its end marker, and an exec that fails fails both checks.
NET_READ='for f in /proc/net/fib_trie /proc/net/route; do
  if [ -r "$f" ]; then echo "BEGIN $f"; cat "$f" || echo "READ-ERROR $f"; echo "END $f"; else echo "MISSING $f"; fi
done; echo NET-READ-END'
net_rc=0
net_out=$(kc exec -n "$NAMESPACE" "$ISO_POD" -- sh -c "$NET_READ" 2>/dev/null) || net_rc=$?
net=$(printf '%s\n' "$net_out" | python3 -c '
import re, sys
lines = sys.stdin.read().split("\n")
sec, cur, ok = {}, None, "NET-READ-END" in lines
for l in lines:
    if cur is not None:
        if l == "END " + cur: cur = None
        elif l == "READ-ERROR " + cur: ok = False
        else: sec[cur].append(l)
    elif l.startswith("BEGIN "): cur = l[6:]; sec[cur] = []
    elif l.startswith("MISSING "): ok = False
if cur is not None: ok = False
fib, leaf, a4 = sec.get("/proc/net/fib_trie"), None, set()
for x in fib or []:
    m = re.match(r"\s*\|-- (\S+)$", x)
    if m: leaf = m.group(1)
    elif re.match(r"\s*/32 host\b", x) and leaf: a4.add(leaf)
rt = [x for x in sec.get("/proc/net/route") or [] if x.strip()]
print("addr4=" + (" ".join(sorted(a4)) or "<none>"))
print("addr4_ok=" + ("yes" if ok and fib and a4 == {"127.0.0.1"} else "no"))
print("route=" + ("none (header line only)" if len(rt) == 1 and rt[0].startswith("Iface") else str(len(rt) - 1) + " entries" if rt else "<unreadable>"))
print("route_ok=" + ("yes" if ok and len(rt) == 1 and rt[0].startswith("Iface") else "no"))
')
kv() { printf '%s\n' "$net" | sed -n "s/^$1=//p"; }
[ "$net_rc" = 0 ] || echo "  could not read the guest's network tables (kubectl exec exit $net_rc)"
echo "  local IPv4 addresses: $(kv addr4)   IPv4 routes: $(kv route)"
assert "the network-isolated pod's only IPv4 address is loopback (127.0.0.1)" "$([ "$net_rc" = 0 ] && [ "$(kv addr4_ok)" = yes ]; echo $?)"
assert "the network-isolated pod has no route" "$([ "$net_rc" = 0 ] && [ "$(kv route_ok)" = yes ]; echo $?)"

echo
echo "== summary: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
