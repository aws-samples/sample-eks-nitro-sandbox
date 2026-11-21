#!/usr/bin/env bash
# Prove the claims of the sample on the cluster that ./setup.sh made. It is read-only except for
# the probe pod and the filler pods that it creates and deletes by exact name, and one scratch
# folder for each containerd drop-in case under /run/cb-probe on the sandbox node.
#
#   RUN_ID=<id> ./test.sh     (RUN_ID defaults to the last run of setup.sh)
#
# Each check prints PASS, FAIL or SKIP!. A check that could not run (SKIP!) counts as a failure,
# and the script exits non-zero unless every check passed.
# shellcheck source=../../../scripts/lib/require-bash.sh
. "$(dirname "$0")/../../../scripts/lib/require-bash.sh"
set -uo pipefail
SAMPLE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SAMPLE_DIR/scripts/common.sh"

require_commands aws kubectl python3
require_region
require_caller_account
require_run_id
check_run_record
lock_run   # never beside setup.sh or clean.sh of the same run
[[ "$(state_get STAGE_DONE)" == workloads ]] || die E_RUN_STAGE "run $RUN_ID has not finished setup (STAGE_DONE=$(state_get STAGE_DONE)); run RUN_ID=$RUN_ID ./setup.sh"
require_sample_cluster
require_kube_context
OUT="$EVIDENCE_DIR/test"
private_dirs "$OUT" || die E_RUN_DIR "could not create $OUT"
SYSTEM_NODE="$(state_need SYSTEM_NODE)" || exit 1
SANDBOX_NODE="$(state_need SANDBOX_NODE)" || exit 1
probe="$(probe_name sandbox)"
fillers=()
dropin_started=no
# dropin_cleanup: remove the scratch folder of each drop-in case on the node (through the probe).
dropin_cleanup() {
  probe_exec "$probe" rm -rf /host-run-probe/valid /host-run-probe/missing /host-run-probe/malformed >/dev/null \
    || warn "could not remove the drop-in case folders under /run/cb-probe on $SANDBOX_NODE"
}
# On any exit, also an interrupt: the drop-in case folders, then the filler pods and the probe
# pod, each by exact name. After a normal end, step 7 has already deleted the pods.
test_cleanup() {
  local f
  if [[ "$dropin_started" == yes && " ${CB_PROBES[*]-} " == *" $probe "* ]]; then dropin_cleanup; fi
  for f in ${fillers[@]+"${fillers[@]}"}; do
    kc -n "$NAMESPACE" delete pod "$f" --ignore-not-found --wait=false >/dev/null \
      || warn "could not delete the filler pod $f; delete it with: kubectl -n $NAMESPACE delete pod $f"
  done
  probe_cleanup
}
trap test_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# The slot count that setup.sh recorded for the run, not the config file (it can change later).
SANDBOX_SLOTS="$(state_need SANDBOX_SLOTS)" || exit 1
export SANDBOX_SLOTS
# The max-pods that setup.sh derived from the instance type of the sandbox node: the ENI formula,
# capped at the ceiling of its vCPU count.
MAX_PODS_SANDBOX="$(state_need MAX_PODS_SANDBOX)" || exit 1
MAX_PODS_FORMULA="$(state_need MAX_PODS_FORMULA_SANDBOX)" || exit 1
MAX_PODS_CEILING="$(state_need MAX_PODS_CEILING_SANDBOX)" || exit 1
NS="$NAMESPACE"
SVC_HOST="cb-server.$NS.svc.cluster.local"

# pyc <subcommand> [args]: one helper check; its exit code (0, 1, 2) is the result.
pyc() { python3 "$PY" "$@"; }
# in_pod <pod> <command...>: run a command in a workload pod of the sample.
in_pod() { local pod="$1"; shift; kc -n "$NS" exec "$pod" -- "$@"; }
# save <file> <command...>: the output of a command, or an empty file when it fails.
save() { local f="$1"; shift; "$@" >"$f" 2>"$f.err" || : >"$f"; }
eq() { [[ "$1" == "$2" ]]; }

step "1. the dedicated cluster and its CNI"
check "cluster $CLUSTER_NAME is Kubernetes $KUBERNETES_VERSION and this run's" \
  eq "$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --query cluster.version --output text)" "$KUBERNETES_VERSION"
addons="$(aws eks list-addons --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --query addons --output text 2>/dev/null)" || addons="<unreadable>"
addons="${addons//$'\t'/ }"   # the text output separates the names with tabs
no_cni_addon() { [[ "$addons" != "<unreadable>" ]] || return 2; [[ " $addons " != *" vpc-cni "* && " $addons " != *" kube-proxy "* ]]; }
check "no vpc-cni and no kube-proxy add-on (add-ons: $addons)" no_cni_addon
no_cni_ds() { local out; out="$(kc -n kube-system get daemonset aws-node kube-proxy --ignore-not-found -o name)" || return 2; [[ -z "$out" ]]; }
check "no aws-node and no kube-proxy DaemonSet" no_cni_ds
node_count() { local n; n="$(kc get nodes -l "eks.amazonaws.com/nodegroup=$1" -o name | wc -l)" || return 2; eq "$n" 1; }
check "exactly one system node" node_count system
check "exactly one sandbox node" node_count sandbox
operator_ready() { local r; r="$(kc -n kube-system get deployment cilium-operator -o jsonpath='{.status.readyReplicas}')" || return 2; eq "$r" 1; }
check "the Cilium operator is Ready on the system node group" operator_ready
agent_image() {
  local images; images="$(kc -n kube-system get daemonset cilium -o jsonpath='{.spec.template.spec.containers[*].image}')" || return 2
  [[ "$images" =~ cilium/cilium:v${CILIUM_VERSION//./\\.}(@|$) ]]
}
check "the Cilium agent image is v$CILIUM_VERSION (cilium.lock)" agent_image
for node in "$SYSTEM_NODE" "$SANDBOX_NODE"; do
  agent="$(kc -n kube-system get pods -l k8s-app=cilium --field-selector "spec.nodeName=$node" -o jsonpath='{.items[0].metadata.name}')"
  save "$OUT/cilium-status-$node.txt" kc -n kube-system exec "$agent" -c cilium-agent -- cilium-dbg status --verbose
  save "$OUT/cilium-config-$node.txt" kc -n kube-system exec "$agent" -c cilium-agent -- cilium-dbg config --all
  check "cilium status on $node: ENI IPAM, native routing, kube-proxy replacement, Socket LB Hostns-only" \
    pyc kpr-status "$OUT/cilium-status-$node.txt" --config "$OUT/cilium-config-$node.txt"
done

step "2. the AMIs of the node groups"
instance_ami() { # instance_ami <node> <want>
  local ami; ami="$(aws ec2 describe-instances --region "$AWS_REGION" --filters "Name=private-dns-name,Values=$1" \
    --query 'Reservations[].Instances[].ImageId' --output text)" || return 2
  eq "$ami" "$2"
}
check "the system node runs the stock Bottlerocket AMI that setup.sh recorded" instance_ami "$SYSTEM_NODE" "$(state_get SYSTEM_AMI_ID)"
check "the sandbox node runs the sandbox AMI of the run" instance_ami "$SANDBOX_NODE" "$(state_get SANDBOX_AMI_ID)"

step "3. the sandbox node: runtime, SELinux, networkd, containerd, density"
save "$OUT/node-sandbox.json" kc get node "$SANDBOX_NODE" -o json
save "$OUT/configz-sandbox.json" kc get --raw "/api/v1/nodes/$SANDBOX_NODE/proxy/configz"
probe_start "$probe" "$SANDBOX_NODE"
probe_capture "$probe" "$OUT/probe-sandbox"
P="$OUT/probe-sandbox"
check "OS image Bottlerocket $BOTTLEROCKET_VERSION ($SANDBOX_VARIANT)" pyc check-os-image sandbox "$OUT/node-sandbox.json"
check "/sys/kernel/btf/vmlinux is present" pyc check-btf "$P/btf.txt"
check "the nitro_enclaves driver reserved its CMA pool (its own kernel log line)" pyc check-mempool --cmdline "$P/cmdline.txt" --kernel-log "$P/kernel.log"
check "the shim reads the kubelet kubeconfig at /etc/kubernetes/kubelet/kubeconfig, and the file is there" \
  pyc check-kubeconfig-path --shim-toml "$P/nitro-sandbox.toml" --kubeconfig "$P/kubeconfig.txt"
check "mkfs.erofs on the host has the zstd compressor" pyc check-mkfs-erofs "$P/mkfs-erofs.txt"
check "the kubelet runtime endpoint is $CRI_PROXY_ENDPOINT" pyc check-runtime-endpoint "$OUT/configz-sandbox.json"
check "the merged containerd config has the isolated-sandbox handler and discard_unpacked_layers = false" \
  pyc check-containerd-dump "$P/containerd-dump.toml"
check "allocatable eks.amazonaws.com/nitro-sandbox is more than 0" pyc check-allocatable "$OUT/node-sandbox.json"
check "pcie_slots in nitro-sandbox.toml equals SANDBOX_SLOTS=$SANDBOX_SLOTS" \
  pyc check-density --shim-toml "$P/nitro-sandbox.toml"
check "the slot pool: SANDBOX_SLOTS=$SANDBOX_SLOTS is not above pcie_slots_total, and equals the driver's pcie_slots and the node's eks.amazonaws.com/nitro-sandbox capacity" \
  pyc check-slots --driver "$P/slots.txt" --node "$OUT/node-sandbox.json" --journal "$P/journal.log"
check "the node's capacity pods equals the max-pods derived from $SANDBOX_INSTANCE_TYPE ($MAX_PODS_SANDBOX: ENI formula $MAX_PODS_FORMULA, ceiling $MAX_PODS_CEILING)" \
  pyc check-max-pods --want "$MAX_PODS_SANDBOX" --formula "$MAX_PODS_FORMULA" --ceiling "$MAX_PODS_CEILING" --node "$OUT/node-sandbox.json"
# The capacity of the sandbox node, for the page: the slot pool bounds the sandbox pods, max-pods
# bounds all pods. A value that could not be read prints as "?".
# shellcheck disable=SC2016
python3 -c '
import json, sys
slots = dict(l.strip().split("=", 1) for l in open(sys.argv[1]) if "=" in l)
try:
    cap = json.load(open(sys.argv[2]))["status"]["capacity"]
except (OSError, ValueError, KeyError):
    cap = {}
print("sandbox node capacity: pcie_slots_total=%s, driver pcie_slots=%s, node eks.amazonaws.com/nitro-sandbox=%s, "
      "max-pods derived=%s, node capacity pods=%s" % (slots.get("pcie_slots_total", "?"), slots.get("pcie_slots", "?"),
      cap.get("eks.amazonaws.com/nitro-sandbox", "?"), sys.argv[3], cap.get("pods", "?")))' \
  "$P/slots.txt" "$OUT/node-sandbox.json" "$MAX_PODS_SANDBOX"
shim_file() { probe_exec "$probe" test -x "/host$SHIM_PATH"; }
check "the shim is at $SHIM_PATH" shim_file
check "SELinux is enforcing" pyc check-selinux-mode "$P/selinux-enforce.txt"
check "the shim and the CRI proxy run in the SELinux domain runtime_t" pyc check-selinux-domains "$P/domains.txt"
check "no SELinux denial in the kernel log or the journal since boot (fails closed)" \
  pyc selinux-audit "$P/kernel.log" "$P/journal.log"
check "the root file system is the read-only dm-verity device" pyc check-dm-verity "$P/dm-verity.txt"

# The drop-in test: containerd config dump of the node's own containerd with a copy of its
# config.toml whose imports point at a scratch folder holding the valid drop-in, no drop-in,
# or a malformed drop-in. Each case uses /run/cb-probe/<case> on the node, removed after the case.
# The case prints the dump (stdout and stderr of containerd), and "CB_CONTAINERD_RC=<exit>" on
# its own stderr.
# shellcheck disable=SC2016
dropin_case() { # dropin_case <valid|missing|malformed>
  probe_exec "$probe" sh -c '
    set -e; c="$1"; s=/host-run-probe/$c; rm -rf "$s"; mkdir -p "$s/config.d"
    src=$(grep -l "isolated-sandbox" /host/etc/containerd/config.d/*.toml | head -n1)
    [ -n "$src" ] || { echo "no drop-in with isolated-sandbox" >&2; exit 3; }
    sed "s#/etc/containerd/config.d/#/run/cb-probe/$c/config.d/#g" /host/etc/containerd/config.toml > "$s/config.toml"
    case "$c" in
      valid) cp "$src" "$s/config.d/" ;;
      malformed) { cat "$src"; echo "[[[ not toml"; } > "$s/config.d/${src##*/}" ;;
    esac
    rc=0; chroot /host /usr/bin/containerd --config "/run/cb-probe/$c/config.toml" config dump 2>&1 || rc=$?
    rm -rf "$s"; echo "CB_CONTAINERD_RC=$rc" >&2' sh "$1"
}
dropin_started=yes
for c in valid missing malformed; do save "$OUT/containerd-dump-$c.toml" dropin_case "$c"; done
dropin_cleanup   # a case that stopped part way leaves its folder; remove all three again
# expect_refusal <tag> <case> <zero|nonzero> <text the dump must have, or ""> <error of the node check>:
# one negative case fails in the expected way only: containerd exits as expected, its output has
# the expected text, and check-containerd-dump refuses the dump (exit 1) with the expected error.
expect_refusal() {
  local tag="$1" f="$OUT/containerd-dump-$2.toml" crc out rc=0
  crc="$(sed -n 's/^CB_CONTAINERD_RC=//p' "$f.err")"
  [[ "$crc" =~ ^[0-9]+$ ]] || { printf 'ERROR: %s_UNKNOWN: the %s case did not run (see %s.err)\n' "$tag" "$2" "$f" >&2; return 2; }
  if { [[ "$3" == zero ]] && ((crc != 0)); } || { [[ "$3" == nonzero ]] && ((crc == 0)); }; then
    printf 'ERROR: %s: containerd exited %s in the %s case, want %s\n' "$tag" "$crc" "$2" "$3" >&2; return 1
  fi
  if [[ -n "$4" ]] && ! grep -qF -- "$4" "$f"; then
    printf "ERROR: %s: the %s case has no '%s' in the containerd output\n" "$tag" "$2" "$4" >&2; return 1
  fi
  out="$(pyc check-containerd-dump "$f" 2>&1)" || rc=$?
  if ((rc != 1)) || [[ "$out" != *"ERROR: E_CONTAINERD_DUMP: $5"* ]]; then
    printf "ERROR: %s: check-containerd-dump of the %s case exited %s, want 1 with '%s'\n" "$tag" "$2" "$rc" "$5" >&2; return 1
  fi
}
check "containerd config dump with the valid drop-in: the handler is there" pyc check-containerd-dump "$OUT/containerd-dump-valid.toml"
check "containerd config dump with no drop-in: containerd loads it, the node check refuses it for the missing handler (E_DROPIN_MISSING)" \
  expect_refusal E_DROPIN_MISSING missing zero "" "the merged configuration has no isolated-sandbox runtime handler"
check "containerd config dump with a malformed drop-in: containerd stops on the TOML error, the node check refuses it (E_DROPIN_MALFORMED)" \
  expect_refusal E_DROPIN_MALFORMED malformed nonzero "failed to unmarshal TOML" "the input is not a containerd version 3 or 4 configuration dump"

# networkd and the Cilium ENIs. Cilium gives pods the secondary addresses of eth0 first, so a
# second ENI comes only when the node needs more addresses. test.sh starts ordinary filler
# pods on the sandbox node, by exact name (at most 40, and never more than the free pods of the
# derived max-pods), until the CiliumNode lists two ENIs and a pod of the node has an address of an ENI
# after eth0. Cilium has then set the routes and rules of that ENI. Capture A follows at once:
# networkd, and the links, addresses, routes and rules that check-eni-capture reads. The probe
# pod and the filler pods stay until capture B in step 7, because Cilium removes the rule of a
# pod when the pod goes. No pod on an ENI after eth0 is a failure (E_NETWORKD_ENI), never a skip.
cilium_node() { kc get ciliumnode "$SANDBOX_NODE" -o json; }
cilium_enis() { # the number of ENIs in the CiliumNode of the sandbox node
  kc get ciliumnode "$SANDBOX_NODE" -o jsonpath='{.status.eni.enis}' \
    | python3 -c 'import json, sys; t = sys.stdin.read().strip(); print(len(json.loads(t)) if t else 0)'
}
# eni_in_use: 0 when the CiliumNode lists two ENIs or more, and a pod of the node has a secondary
# address of an ENI with number 1 or more.
# shortcut: secondary addresses only; the values do not turn on prefix delegation. With prefix
# delegation, also match the pod IP against status.eni.enis[].prefixes.
eni_in_use() {
  local cn ips
  cn="$(cilium_node)" || return 1
  ips="$(kc get pods -A --field-selector "spec.nodeName=$SANDBOX_NODE" -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}')" || return 1
  python3 -c '
import json, sys
enis = ((json.load(sys.stdin).get("status") or {}).get("eni") or {}).get("enis") or {}
ips = set(sys.argv[1].split())
used = [e for e in enis.values() if (e.get("number") or 0) >= 1 and ips & set(e.get("addresses") or [])]
sys.exit(0 if len(enis) >= 2 and used else 1)' "$ips" <<<"$cn"
}
pods_on_node="$(kc get pods -A --field-selector "spec.nodeName=$SANDBOX_NODE" -o name | wc -l)"
filler_max=$((MAX_PODS_SANDBOX - pods_on_node))   # filler pods are ordinary pods: max-pods bounds them
((filler_max <= 40)) || filler_max=40
for ((i = 1; i <= filler_max; i++)); do
  eni_in_use && break
  f="cb-filler-$i-$RUN_ID"
  pyc render-filler --name "$f" --node "$SANDBOX_NODE" | kc create -f - >/dev/null || break
  fillers+=("$f")
  kc -n "$NS" wait --for=condition=Ready "pod/$f" --timeout=3m >/dev/null || break
done
# The operator attaches the ENI after it sees the demand: wait for it and its first pod.
eni_in_use || wait_until "${CB_WAIT_TRIES:-30}" "a pod on an ENI after eth0 on $SANDBOX_NODE" eni_in_use || true
printf 'filler pods started: %d (limit %d); ENIs in the CiliumNode of %s: %s\n' \
  "${#fillers[@]}" "$filler_max" "$SANDBOX_NODE" "$(cilium_enis)"
A="$OUT/eni-a"
B="$OUT/eni-b"
if eni_in_use; then
  probe_capture "$probe" "$A"
  probe_eni_capture "$probe" "$A/eni.txt"
  save "$A/ciliumnode.json" cilium_node
  check "capture A: systemd-networkd leaves each ENI after eth0 unmanaged; no DHCP or RA address or route, only the routes and rules of Cilium" \
    pyc check-eni-capture --capture "$A/eni.txt" --networkd "$A/networkd.txt" --ciliumnode "$A/ciliumnode.json"
else
  printf 'ERROR: E_NETWORKD_ENI: no pod on an ENI after eth0 on %s after %d filler pods\n' "$SANDBOX_NODE" "${#fillers[@]}" >&2
  assert "a pod on a second Cilium ENI of the sandbox node, for the networkd and ENI checks (E_NETWORKD_ENI)" 1
fi

step "4. the sandbox pod runs in its own guest"
sandbox_ip="$(kc -n "$NS" get pod cb-sandbox -o jsonpath='{.status.podIP}')"
server_ip="$(kc -n "$NS" get pod cb-server -o jsonpath='{.status.podIP}')"
check "cb-sandbox has runtimeClassName isolated-sandbox" eq "$(kc -n "$NS" get pod cb-sandbox -o jsonpath='{.spec.runtimeClassName}')" isolated-sandbox
check "cb-sandbox runs on the sandbox node" eq "$(kc -n "$NS" get pod cb-sandbox -o jsonpath='{.spec.nodeName}')" "$SANDBOX_NODE"
guest="$(in_pod cb-sandbox uname -rv)"; host="$(in_pod cb-ordinary-sandbox-node uname -rv)"
printf 'sandbox pod  uname -rv: %s\nordinary pod uname -rv: %s\n' "$guest" "$host"
differ() { [[ -n "$1" && -n "$2" && "$1" != "$2" ]]; }
check "the sandbox pod has its own kernel build" differ "$guest" "$host"
up_guest="$(in_pod cb-sandbox cut -d. -f1 /proc/uptime)"; up_host="$(in_pod cb-ordinary-sandbox-node cut -d. -f1 /proc/uptime)"
printf 'sandbox pod uptime %ss, ordinary pod (node) uptime %ss\n' "$up_guest" "$up_host"
younger() { [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]] || return 2; (($1 < $2)); }
check "the sandbox pod booted with the pod, after the node" younger "$up_guest" "$up_host"
disks_guest="$(in_pod cb-sandbox ls /sys/block | tr '\n' ' ')"; disks_host="$(in_pod cb-ordinary-sandbox-node ls /sys/block | tr '\n' ' ')"
printf 'sandbox pod disks: %s\nordinary pod disks: %s\n' "$disks_guest" "$disks_host"
virtio() { [[ " $1" == *" vd"* && " $1" != *" nvme"* && " $2" == *" nvme"* ]]; }
check "the sandbox pod sees virtio vd* disks, the ordinary pod the nvme disks of the instance" virtio "$disks_guest" "$disks_host"
printf 'product_name: sandbox %s, ordinary %s\n' "$(in_pod cb-sandbox cat /sys/class/dmi/id/product_name)" \
  "$(in_pod cb-ordinary-sandbox-node cat /sys/class/dmi/id/product_name)"

step "5. pod networking: ENI address, CiliumEndpoint, pod to pod, ClusterIP Service, DNS"
sandbox_instance="$(aws ec2 describe-instances --region "$AWS_REGION" --filters "Name=private-dns-name,Values=$SANDBOX_NODE" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"
save "$OUT/enis-sandbox.json" aws ec2 describe-network-interfaces --region "$AWS_REGION" \
  --filters "Name=attachment.instance-id,Values=$sandbox_instance" --output json
check "the sandbox pod IP $sandbox_ip is a secondary IP of an ENI of its node" pyc pod-in-eni "$sandbox_ip" "$OUT/enis-sandbox.json"
check "the CiliumEndpoint of cb-sandbox is ready" eq "$(kc -n "$NS" get ciliumendpoint cb-sandbox -o jsonpath='{.status.state}')" ready
check "Service cb-server is ClusterIP" eq "$(kc -n "$NS" get service cb-server -o jsonpath='{.spec.type}')" ClusterIP
fetch() { local out; out="$(in_pod "$1" wget -q -T 5 -O- "$2")" || return 1; [[ "$out" == cb-server-ok ]]; }
resolve() { in_pod "$1" nslookup "$SVC_HOST" >/dev/null 2>&1; }
for pod in cb-sandbox cb-ordinary-sandbox-node cb-ordinary-system-node; do
  check "$pod: pod to pod (http://$server_ip:8080/)" fetch "$pod" "http://$server_ip:8080/"
  check "$pod: ClusterIP Service (http://$SVC_HOST/)" fetch "$pod" "http://$SVC_HOST/"
  check "$pod: DNS ($SVC_HOST)" resolve "$pod"
done
isolated_capture() {
  { echo "==addr=="; in_pod cb-sandbox-isolated ip -o addr; echo "==route=="; in_pod cb-sandbox-isolated ip route
    local rc=0; out="$(in_pod cb-sandbox-isolated nslookup "$SVC_HOST" 2>&1)" || rc=$?
    echo "==dns rc=$rc=="; printf '%s\n' "$out"; }
}
save "$OUT/network-isolated.txt" isolated_capture
check "the network-isolated sandbox pod has only loopback, no route and no DNS" pyc check-network-isolated "$OUT/network-isolated.txt"

step "6. AWS permissions and exposure"
check "the Cilium operator role has only the EC2 actions of the Cilium list; node roles have none" pyc check-operator-role
only_operator() {
  local out; out="$(aws eks list-pod-identity-associations --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
    --query 'associations[].[namespace,serviceAccount]' --output text)" || return 2
  eq "$out" "$(printf 'kube-system\tcilium-operator')"
}
check "the only Pod Identity association is kube-system/cilium-operator" only_operator
no_creds() { local n; n="$(in_pod "$1" sh -c 'env | cut -d= -f1 | grep -c "^AWS_" || true')" || return 2; eq "$n" 0; }
for pod in cb-sandbox cb-ordinary-sandbox-node cb-ordinary-system-node; do
  check "$pod has no AWS credential variable" no_creds "$pod"
done
cluster_ip_only() {
  local types; types="$(kc get services -A -o jsonpath='{range .items[*]}{.spec.type}{"\n"}{end}' | sort -u)" || return 2
  eq "$types" ClusterIP
}
check "every Service of the cluster is ClusterIP (no LoadBalancer, no NodePort)" cluster_ip_only
none_of() { local out; out="$(kc get "$1" -A -o name 2>/dev/null)" || return 2; [[ -z "$out" ]]; }
check "no Ingress" none_of ingresses.networking.k8s.io
check "no NetworkPolicy" none_of networkpolicies.networking.k8s.io
check "no CiliumNetworkPolicy" none_of ciliumnetworkpolicies.cilium.io
check "no CiliumClusterwideNetworkPolicy" none_of ciliumclusterwidenetworkpolicies.cilium.io
check "every resource of every class carries ManagedBy and RunId" pyc audit-tags --after-build

step "7. the sandbox node at the end: the Cilium ENIs since capture A, and the SELinux audit"
# Capture B, with the probe pod and the filler pods of capture A still on the node. Then the
# filler pods and the probe pod go, by exact name.
probe_capture "$probe" "$B"
probe_eni_capture "$probe" "$B/eni.txt"
save "$B/ciliumnode.json" cilium_node
check "capture B: each ENI after eth0 has no DHCP or RA address or route, only the routes and rules of Cilium" \
  pyc check-eni-capture --capture "$B/eni.txt" --networkd "$B/networkd.txt" --ciliumnode "$B/ciliumnode.json"
check "the addresses, routes and rules of each ENI after eth0 are the same in capture A and capture B" \
  pyc check-eni-stable --before "$A/eni.txt" --after "$B/eni.txt"
check "no SELinux denial on the sandbox node from its boot to the end of test.sh (fails closed)" \
  pyc selinux-audit "$B/kernel.log" "$B/journal.log"
kept=()
for f in ${fillers[@]+"${fillers[@]}"}; do
  kc -n "$NS" delete pod "$f" --ignore-not-found --wait=false >/dev/null || kept+=("$f")
done
fillers=(${kept[@]+"${kept[@]}"})   # the exit trap tries again for any that is left
probe_stop "$probe" || warn "could not delete the probe pod $probe; the exit trap tries again"

demo_summary "the Cilium on Bottlerocket sample (run $RUN_ID)"
