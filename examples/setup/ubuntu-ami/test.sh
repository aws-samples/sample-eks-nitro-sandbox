#!/usr/bin/env bash
# test.sh: node readiness and labels, host-requirement checks (each with an ACCEPT and a REJECT
# control), AppArmor working-profile vs refused control, positive sandbox capacity, a
# guest-boundary comparison of an ordinary pod against the isolated-sandbox pod, and that the
# isolated-sandbox pod, booted network-isolated, has no network (with its control). Run after
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
# (6.18.54). Every helper pod this script creates (one kubectl debug pod, the AppArmor scoped pod
# and the AppArmor reject control) lives in the sample's namespace and is deleted by its exact
# name. The scoped AppArmor profile is proven on an ordinary pod on the same node, because the
# sandbox pod runs Unconfined (deploy/pod-isolated-sandbox.yaml says why). Overridable bounded
# waits: SCOPED_POD_TRIES (24) and SCOPED_POD_POLL_SECONDS (5) for the scoped pod to run,
# SCOPED_DELETE_MARGIN (20 s past its grace period) for its delete, REJECT_POD_TRIES (24) and
# REJECT_POD_POLL_SECONDS (5) for the reject control's refusal.
set -uo pipefail
SAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SAMPLE_DIR/scripts/lib/common.sh"
require_run_id

ORDINARY_POD=ordinary-pod
SANDBOX_POD=isolated-sandbox-pod
SCOPED_POD=apparmor-scoped-pod
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
# The scoped AppArmor profile is shown on an ordinary (runc) pod on the same node: a sandbox pod
# cannot take a host profile, because runc applies it inside the guest, which has no AppArmor
# (deploy/pod-isolated-sandbox.yaml). deploy/pod-apparmor-scoped.yaml selects the profile; it is
# rendered with this run's node group and namespace, applied, waited for (bounded), read below,
# and deleted by its exact name before the node probe; section 3 asserts what was read.
scoped_rendered=$(mktemp)
sed -e "s/@NODEGROUP@/$NODEGROUP_NAME/g" -e "s/^  namespace: ubuntu-ami-sample$/  namespace: $NAMESPACE/" \
  "$SAMPLE_DIR/deploy/pod-apparmor-scoped.yaml" > "$scoped_rendered"
kc apply -n "$NAMESPACE" -f "$scoped_rendered" >/dev/null 2>&1
rm -f "$scoped_rendered"
scp_phase=""
for _ in $(seq 1 "${SCOPED_POD_TRIES:-24}"); do
  scp_phase=$(kc get pod "$SCOPED_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$scp_phase" == Running || "$scp_phase" == Failed || "$scp_phase" == Succeeded ]] && break
  sleep "${SCOPED_POD_POLL_SECONDS:-5}"
done
# T0: the node's clock (epoch seconds) before this attempt's /etc/shadow write; see section 3.
T0=$(kc exec "$ORDINARY_POD" -n "$NAMESPACE" -- date -u +%s 2>/dev/null)
[[ "$T0" =~ ^[0-9]+$ ]] || T0=unreadable
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
echo apparmor_profile_mode=$(sed -n "s/^'"$SAMPLE_PROFILE"' (\(.*\))$/\1/p" /sys/kernel/security/apparmor/profiles | head -n 1)
echo apparmor_profile_sha256=$(sha256sum /etc/apparmor.d/'"$SAMPLE_PROFILE"' 2>/dev/null | cut -d" " -f1)
echo apparmor_shadow_denials=$(journalctl -k --no-pager --since "@'"$T0"'" 2>/dev/null | grep "apparmor=\"DENIED\"" | grep "profile=\"'"$SAMPLE_PROFILE"'\"" | grep -c "name=\"/etc/shadow\"")
echo apparmor_bogus_denials=$(journalctl -k --no-pager --since "@'"$T0"'" 2>/dev/null | grep "apparmor=\"DENIED\"" | grep "profile=\"profile-that-does-not-exist\"" | grep -c "name=\"/etc/shadow\"")
echo apparmor_signal_denials=$(journalctl -k --no-pager --since "@'"$T0"'" 2>/dev/null | grep "apparmor=\"DENIED\"" | grep "operation=\"signal\"" | grep -c "profile=\"'"$SAMPLE_PROFILE"'\"")
echo apparmor_bogus_signal_denials=$(journalctl -k --no-pager --since "@'"$T0"'" 2>/dev/null | grep "apparmor=\"DENIED\"" | grep "operation=\"signal\"" | grep -c "profile=\"profile-that-does-not-exist\"")
'
# The AppArmor evidence in section 3, all gathered from T0 on (the node's clock read just before
# the scoped pod's writes; the ordinary pod shares it):
#   * each pod's own AppArmor label (/proc/self/attr/current): the scoped pod's must name the
#     profile in enforce mode, the ordinary pod's (no profile requested) must not;
#   * the scoped pod's write to /etc/shadow must fail with EACCES ("Permission denied"), while
#     the same pod's write to a path the profile does not deny succeeds;
#   * the node's kernel journal must hold the profile's DENIED line for that write (the profile's
#     deny rules are `audit deny`), and none for a profile the node never loaded;
#   * deleted by its exact name, the scoped pod must be gone within its grace period, and the
#     journal must hold no DENIED line for a signal under the profile (a pod whose profile
#     refuses runc's stop signals can never be stopped).
# The sandbox pod's label is printed too: it is the guest's own (SELinux) label, which is why the
# sandbox runs Unconfined.
scp_attr=$(kc exec "$SCOPED_POD" -n "$NAMESPACE" -- cat /proc/self/attr/current 2>/dev/null | tr -d '\0')
ord_attr=$(kc exec "$ORDINARY_POD" -n "$NAMESPACE" -- cat /proc/self/attr/current 2>/dev/null | tr -d '\0')
sbx_attr=$(kc exec "$SANDBOX_POD" -n "$NAMESPACE" -- cat /proc/self/attr/current 2>/dev/null | tr -d '\0')
# The shell's own error for the failed redirection is caught on stdout ({ ...; } 2>&1), so the
# check reads the error itself, not only that the write failed.
denied=$(kc exec "$SCOPED_POD" -n "$NAMESPACE" -- sh -c '{ echo test > /etc/shadow; } 2>&1 || echo WRITE-FAILED' 2>/dev/null)
# Control for that refusal: the same pod, as the same user, writes a file in /etc the profile does
# not deny, so the refusal is the profile's deny rule, not a read-only filesystem or file mode.
allowed=$(kc exec "$SCOPED_POD" -n "$NAMESPACE" -- sh -c '{ echo test > /etc/ubuntu-ami-sample-write-control; } 2>&1 && echo WRITTEN' 2>/dev/null)
scp_type=$(kc get pod "$SCOPED_POD" -n "$NAMESPACE" -o jsonpath='{.spec.securityContext.appArmorProfile.type}' 2>/dev/null)
scp_profile=$(kc get pod "$SCOPED_POD" -n "$NAMESPACE" -o jsonpath='{.spec.securityContext.appArmorProfile.localhostProfile}' 2>/dev/null)
scp_node=$(kc get pod "$SCOPED_POD" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
scp_grace=$(kc get pod "$SCOPED_POD" -n "$NAMESPACE" -o jsonpath='{.spec.terminationGracePeriodSeconds}' 2>/dev/null)
[[ "$scp_grace" =~ ^[0-9]+$ ]] || scp_grace=30
# Delete it by its exact name, before the node probe reads the journal, and time how long it takes
# to be gone. kubectl waits at most the grace period plus SCOPED_DELETE_MARGIN (20 s), so a pod
# that cannot be stopped is measured, not waited for forever.
scp_t=$SECONDS
kc delete pod "$SCOPED_POD" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout="$((scp_grace + ${SCOPED_DELETE_MARGIN:-20}))s" >/dev/null 2>&1
scp_gone_s=$((SECONDS - scp_t))
scp_after=$(kc get pod "$SCOPED_POD" -n "$NAMESPACE" -o name 2>&1)
if [[ "$scp_after" == *NotFound* ]]; then scp_gone=yes; else scp_gone=no; fi
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

echo "== 3/7 AppArmor (criterion 8): host on and enforcing, scoped profile working, refused control"
echo "  -- 8a: AppArmor is on and enforcing on the host"
assert "AppArmor is enabled host-wide on the node (enabled=$(v apparmor_enabled))" $([[ "$(v apparmor_enabled)" == "Y" ]]; echo $?)
assert "ACCEPT: the scoped profile $SAMPLE_PROFILE is loaded on the node in enforce mode (mode=$(v apparmor_profile_mode))" \
  $([[ "$(v apparmor_profile)" == loaded && "$(v apparmor_profile_mode)" == enforce ]]; echo $?)
assert "REJECT: the same probe reads absent for a profile the node never loaded" $([[ "$(v apparmor_profile_bogus)" == absent ]]; echo $?)
want_sha=$(sha256sum "$SAMPLE_DIR/manifests/$SAMPLE_PROFILE" | cut -d' ' -f1)
assert "the profile on the node is this sample's manifests/$SAMPLE_PROFILE (sha256 $(v apparmor_profile_sha256))" \
  $([[ -n "$(v apparmor_profile_sha256)" && "$(v apparmor_profile_sha256)" == "$want_sha" ]]; echo $?)
echo "  -- 8b: the scoped profile works on an ordinary pod on the same node ($SCOPED_POD)"
echo "  scoped pod: node=${scp_node:-<none>} type=${scp_type:-<none>} profile=${scp_profile:-<none>} phase=${scp_phase:-<none>}"
assert "the scoped pod requests Localhost $SAMPLE_PROFILE and runs on the sandbox node (phase=${scp_phase:-<none>})" \
  $([[ "$scp_type" == Localhost && "$scp_profile" == "$SAMPLE_PROFILE" && "$scp_phase" == Running && "$scp_node" == "$node" ]]; echo $?)
echo "  scoped attr/current: '${scp_attr:-<unreadable>}'  ordinary attr/current: '${ord_attr:-<unreadable>}'"
assert "ACCEPT: the scoped pod's process is confined by '$SAMPLE_PROFILE (enforce)' (attr/current)" $([[ "$scp_attr" == "$SAMPLE_PROFILE (enforce)" ]]; echo $?)
assert "REJECT: the same label read on the ordinary pod, which requests no profile, does not name $SAMPLE_PROFILE" \
  $([[ -n "$ord_attr" && "$ord_attr" != "$SAMPLE_PROFILE"* ]]; echo $?)
echo "  scoped pod: write to /etc/shadow: $(printf '%s' "${denied:-<none>}" | tr '\n' ' ')"
echo "  scoped pod: write to /etc/ubuntu-ami-sample-write-control: ${allowed:-<none>}"
assert "ACCEPT: the scoped pod's write to /etc/shadow is refused with EACCES (Permission denied)" \
  $([[ "$denied" == *"/etc/shadow: Permission denied"* && "$denied" == *WRITE-FAILED* ]]; echo $?)
assert "REJECT: the same pod's write to a path the profile does not deny succeeds (so the refusal is the profile's)" \
  $([[ "$allowed" == WRITTEN ]]; echo $?)
echo "  node DENIED lines since T0=$T0 for that write: $SAMPLE_PROFILE $(v apparmor_shadow_denials), profile-that-does-not-exist $(v apparmor_bogus_denials)"
assert "ACCEPT: the node's kernel logged the profile's DENIED line for that write since T0" \
  $([[ "$(v apparmor_shadow_denials)" =~ ^[0-9]+$ && "$(v apparmor_shadow_denials)" -gt 0 ]]; echo $?)
assert "REJECT: the same count for a profile the node never loaded is 0" $([[ "$(v apparmor_bogus_denials)" == 0 ]]; echo $?)
echo "  scoped pod deleted by its exact name: gone=$scp_gone after ${scp_gone_s} s (grace ${scp_grace} s); signal DENIED lines since T0: $SAMPLE_PROFILE $(v apparmor_signal_denials), profile-that-does-not-exist $(v apparmor_bogus_signal_denials)"
assert "ACCEPT: deleted by its exact name, the scoped pod is gone within its grace period (${scp_gone_s} s <= ${scp_grace} s)" \
  $([[ "$scp_gone" == yes && "$scp_gone_s" -le "$scp_grace" ]]; echo $?)
assert "ACCEPT: the node logged no DENIED signal under $SAMPLE_PROFILE since T0 (the profile lets runc stop the pod)" \
  $([[ "$(v apparmor_signal_denials)" == 0 ]]; echo $?)
assert "REJECT: the same signal count for a profile the node never loaded is 0" $([[ "$(v apparmor_bogus_signal_denials)" == 0 ]]; echo $?)
echo "  -- 8c: a pod naming a profile the node never loaded is refused"
# REJECT control: an ordinary pod on the same node naming a profile the node never loaded. It
# must be refused for the AppArmor reason, on THIS node (a pod that never schedules would be
# Pending for the wrong reason), with containerd's own message for a missing profile, matched
# whole. Rendered with this run's node group and namespace.
REJ=apparmor-reject-control
REJ_REASON=CreateContainerError
REJ_MESSAGE='failed to get container spec opts: failed to generate apparmor spec opts: apparmor profile not found profile-that-does-not-exist'
rendered=$(mktemp)
sed -e "s/@NODEGROUP@/$NODEGROUP_NAME/g" -e "s/^  namespace: ubuntu-ami-sample$/  namespace: $NAMESPACE/" \
  "$SAMPLE_DIR/deploy/pod-apparmor-reject.yaml" > "$rendered"
kc apply -n "$NAMESPACE" -f "$rendered" >/dev/null 2>&1
rm -f "$rendered"
rej_node=""; rej_reason=""; rej_msg=""
for _ in $(seq 1 "${REJECT_POD_TRIES:-24}"); do
  rej_node=$(kc get pod "$REJ" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  rej_reason=$(kc get pod "$REJ" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
  rej_msg=$(kc get pod "$REJ" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.waiting.message}' 2>/dev/null)
  [[ "$rej_reason" == "$REJ_REASON" ]] && break
  sleep "${REJECT_POD_POLL_SECONDS:-5}"
done
rej_phase=$(kc get pod "$REJ" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
echo "  reject control: node=${rej_node:-<none>} phase=${rej_phase:-<none>} reason=${rej_reason:-<none>} message: ${rej_msg:-<none>}"
assert "REJECT: a pod naming an unloaded AppArmor profile is refused on the sandbox node: $REJ_REASON '$REJ_MESSAGE'" \
  $([[ "$rej_node" == "$node" && "$rej_reason" == "$REJ_REASON" && "$rej_msg" =~ ^"$REJ_MESSAGE"$ && "$rej_phase" != Running ]]; echo $?)
kc delete pod "$REJ" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
echo "  -- why the sandbox pod runs Unconfined"
# The sandbox pod runs Unconfined: its profile would be applied by runc inside the guest, which runs
# SELinux and has no AppArmor. Its own label is the guest's.
sbx_type=$(kc get pod "$SANDBOX_POD" -n "$NAMESPACE" -o jsonpath='{.spec.securityContext.appArmorProfile.type}' 2>/dev/null)
sbx_phase=$(kc get pod "$SANDBOX_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
echo "  sandbox pod: appArmorProfile type=${sbx_type:-<none>} phase=${sbx_phase:-<none>} attr/current (the guest's own label): '${sbx_attr:-<unreadable>}'"
assert "the sandbox pod runs with appArmorProfile Unconfined, as the GA build notes require (phase=${sbx_phase:-<none>})" \
  $([[ "$sbx_type" == Unconfined && "$sbx_phase" == Running ]]; echo $?)

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

echo "== 7/7 the validation sandbox has no network ============================================"
# The sandbox pod is booted with sandbox.amazonaws.com/network-isolated: "true"
# (deploy/pod-isolated-sandbox.yaml), so its microVM has no network. Shown by what the guest
# itself reports, and by a connect that cannot leave it:
#   the annotation, read back from the API (the live pod, not the file);
#   only loopback has an address: the local IPv4 addresses in /proc/net/fib_trie are 127.0.0.1
#   only, and /proc/net/if_inet6 lists ::1 on lo only, or nothing, or is absent (no IPv6);
#   the sandbox has no route: /proc/net/route has its header line and no entry;
#   every interface in /sys/class/net other than lo is down. They are printed: the guest also
#   has dummy0, from its image, which is down and has no address;
#   a TCP connect from the sandbox to the cluster's kubernetes Service ClusterIP on 443 fails with
#   "Network is unreachable" (ENETUNREACH); a refusal, a timeout, an exec error or empty output
#   FAILS;
#   the same connect from the ordinary pod succeeds, so the address and port are reachable from
#   the node's pod network and the sandbox's failure is its missing network.
# Each read must show that it ran to its end: an exec that fails, a file the guest could not
# read, or output without the end marker FAILS. The API still reports a podIP for the sandbox
# pod: the host side allocates it, and no interface in the guest carries it.
sbx_iso=$(kc get pod "$SANDBOX_POD" -n "$NAMESPACE" -o 'jsonpath={.metadata.annotations.sandbox\.amazonaws\.com/network-isolated}' 2>/dev/null)
echo "  sandbox pod annotation sandbox.amazonaws.com/network-isolated: ${sbx_iso:-<absent>}"
assert "the sandbox pod carries sandbox.amazonaws.com/network-isolated=\"true\" (read back from the API)" $([[ "$sbx_iso" == "true" ]]; echo $?)
# In the guest: each file whole between BEGIN and END lines (MISSING when it cannot be read,
# READ-ERROR when cat fails), one IF line per interface with its operstate, then the end marker.
NET_READ='for f in /proc/net/fib_trie /proc/net/route /proc/net/if_inet6; do
  if [ -r "$f" ]; then echo "BEGIN $f"; cat "$f" || echo "READ-ERROR $f"; echo "END $f"; else echo "MISSING $f"; fi
done
if [ -d /sys/class/net ]; then
  for d in /sys/class/net/*; do [ -e "$d" ] && echo "IF ${d##*/} $(cat "$d/operstate" 2>/dev/null || echo unreadable)"; done
else echo "MISSING /sys/class/net"; fi
echo NET-READ-END'
# On this machine: what that output shows, as KEY=VALUE lines. Anything it cannot read is a "no".
NET_PARSE='import ipaddress, re, socket, struct, sys
sec, cur, ifs, missing, bad, junk = {}, None, [], set(), set(), False
for l in sys.stdin.read().split("\n"):
    if cur is not None:
        if l == "END " + cur: cur = None
        elif l == "READ-ERROR " + cur: bad.add(cur)
        else: sec[cur].append(l)
        continue
    m = re.fullmatch(r"(BEGIN|MISSING) (/\S+)", l)
    if m and m.group(1) == "BEGIN": cur = m.group(2); sec[cur] = []
    elif m: missing.add(m.group(2))
    elif re.fullmatch(r"IF \S+ \S+", l): ifs.append(tuple(l.split()[1:]))
    elif l.strip() and l != "NET-READ-END": junk = True
if cur is not None: bad.add(cur); junk = True
def got(f):
    return None if f in bad or f not in sec else [x for x in sec[f] if x.strip()]
yn = lambda b: "yes" if b else "no"
fib, leaf, a4 = got("/proc/net/fib_trie"), None, set()
for x in fib or []:
    m = re.match(r"\s*\|-- (\S+)$", x)
    if m: leaf = m.group(1)
    elif re.match(r"\s*/32 host\b", x) and leaf: a4.add(leaf)
print("addr4=" + (" ".join(sorted(a4)) or "<none>" if fib else "<unreadable>"))
print("addr4_ok=" + yn(bool(fib) and a4 == {"127.0.0.1"}))
v6 = got("/proc/net/if_inet6")
rows = [x.split() for x in v6 or []]
v6_ok = v6 is not None and all(len(r) == 6 and re.fullmatch(r"[0-9a-f]{32}", r[0]) for r in rows)
a6 = [(str(ipaddress.IPv6Address(int(r[0], 16))), r[5]) for r in rows] if v6_ok else []
if "/proc/net/if_inet6" in missing and v6 is None: print("addr6=absent (no IPv6)"); print("addr6_ok=yes")
else:
    print("addr6=" + (", ".join(a + " on " + i for a, i in a6) or "<none>" if v6_ok else "<unreadable>"))
    print("addr6_ok=" + yn(v6_ok and all(x == ("::1", "lo") for x in a6)))
rt = got("/proc/net/route")
def ip(h):  # /proc/net/route writes an IPv4 address as 8 hex digits, little-endian
    return socket.inet_ntoa(struct.pack("<I", int(h, 16))) if re.fullmatch(r"[0-9A-Fa-f]{8}", h) else h
def route(x):
    f = x.split() + ["?", "?", "?"]
    return "%s dst %s gw %s" % (f[0], ip(f[1]), ip(f[2]))
if not rt or not rt[0].startswith("Iface"): print("route4=<unreadable>"); print("route4_ok=no")
else:
    print("route4=" + ("none (header line only)" if len(rt) == 1 else "; ".join(route(x) for x in rt[1:])))
    print("route4_ok=" + yn(len(rt) == 1))
if "/sys/class/net" in missing: print("ifaces=<unreadable>"); print("ifaces_ok=no")
else:
    print("ifaces=" + (", ".join(n + " " + s for n, s in ifs) or "<none>"))
    print("ifaces_ok=" + yn(any(n == "lo" for n, s in ifs) and all(s == "down" for n, s in ifs if n != "lo")))
print("parse_ok=" + yn(not junk))'
net_rc=0
net_out=$(kc exec "$SANDBOX_POD" -n "$NAMESPACE" -- sh -c "$NET_READ" 2>/dev/null) || net_rc=$?
net_kv=$(printf '%s\n' "$net_out" | python3 -c "$NET_PARSE" 2>/dev/null)
nv() { local x; x=$(printf '%s\n' "$net_kv" | sed -n "s/^$1=//p" | head -n 1); printf '%s' "${x:-<unread>}"; }
net_done=1
[[ "$net_rc" == 0 && "$(printf '%s\n' "$net_out" | grep -cx 'NET-READ-END')" == 1 && "$(printf '%s\n' "$net_out" | tail -n 1)" == NET-READ-END \
   && "$(nv parse_ok)" == yes ]] && net_done=0
echo "  sandbox interfaces (/sys/class/net, operstate): $(nv ifaces)"
echo "  sandbox IPv4 local addresses (/proc/net/fib_trie): $(nv addr4)"
echo "  sandbox IPv6 addresses (/proc/net/if_inet6): $(nv addr6)"
echo "  sandbox IPv4 routes (/proc/net/route): $(nv route4)"
[[ "$net_done" == 0 ]] || echo "  (the sandbox's network read did not complete: exec rc=$net_rc; the next three checks fail)"
assert "only loopback has an address in the sandbox (IPv4: $(nv addr4); IPv6: $(nv addr6))" \
  $([[ "$net_done" == 0 && "$(nv addr4_ok)" == yes && "$(nv addr6_ok)" == yes ]]; echo $?)
assert "the sandbox has no route (/proc/net/route: $(nv route4))" $([[ "$net_done" == 0 && "$(nv route4_ok)" == yes ]]; echo $?)
assert "every sandbox interface other than lo is down ($(nv ifaces))" $([[ "$net_done" == 0 && "$(nv ifaces_ok)" == yes ]]; echo $?)
# One connect attempt, in Python (the image has no nc or ip), printing one PROBE line: connected,
# timeout, or the errno name with its message.
CONNECT_PROBE='import errno, socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(5)
try:
    s.connect((sys.argv[1], 443))
    print("PROBE connected")
except socket.timeout:
    print("PROBE timeout")
except OSError as e:
    print("PROBE errno=%s (%s)" % (errno.errorcode.get(e.errno, e.errno), e.strerror))'
api_ip=$(kc get service kubernetes -n default -o 'jsonpath={.spec.clusterIP}' 2>/dev/null)
echo "  kubernetes Service ClusterIP (read from the API): ${api_ip:-<unreadable>}"
probe() { # probe <pod>: the PROBE line, or <exec failed: rc=N> / <no PROBE line>
  local out rc=0
  [[ "$api_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "<no ClusterIP>"; return; }
  out=$(kc exec "$1" -n "$NAMESPACE" -- python3 -c "$CONNECT_PROBE" "$api_ip" 2>/dev/null) || rc=$?
  if [[ "$rc" != 0 ]]; then echo "<exec failed: rc=$rc>"
  elif [[ "$(printf '%s\n' "$out" | grep -c '^PROBE ')" != 1 ]]; then echo "<no PROBE line>"
  else printf '%s\n' "$out" | grep '^PROBE ' | sed 's/^PROBE //'; fi
}
sbx_conn=$(probe "$SANDBOX_POD")
echo "  sandbox TCP connect to ${api_ip:-?}:443: $sbx_conn"
assert "the sandbox's TCP connect to the API Service fails with Network is unreachable (ENETUNREACH)" \
  $([[ "$sbx_conn" == "errno=ENETUNREACH (Network is unreachable)" ]]; echo $?)
ord_conn=$(probe "$ORDINARY_POD")
echo "  ordinary pod TCP connect to ${api_ip:-?}:443: $ord_conn"
assert "the same connect from the ordinary pod succeeds (control for the previous check)" $([[ "$ord_conn" == connected ]]; echo $?)

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "node ready and labelled, host requirements proven both ways, AppArmor on with the scoped profile working and the control refused, guest boundary and the sandbox's missing network shown."
