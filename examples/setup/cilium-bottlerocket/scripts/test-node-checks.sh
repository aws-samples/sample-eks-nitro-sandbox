#!/usr/bin/env bash
# test-node-checks.sh: proves the node, SELinux, network, density, max-pods and slot checks of
# scripts/cilium_bottlerocket.py both ways, the REAL helper, run as setup.sh and test.sh run it
# (after `source scripts/common.sh`), on captures from scripts/testlib/fixture_node.py. Each reject
# case changes one thing in a good capture. Each check also gets a missing capture, which must be
# exit 2 (E_<TAG>_UNKNOWN), never a pass.
# The containerd drop-in case runs a real `containerd config dump` (containerd 2.x, CB_CONTAINERD)
# with the tracked drop-in, with no drop-in, and with a malformed drop-in (#281).
#
#   examples/setup/cilium-bottlerocket/scripts/test-node-checks.sh
source "$(dirname "$0")/testlib/harness.sh"
HELPER="$SAMPLE_DIR_REAL/scripts/cilium_bottlerocket.py"
need_file "$HELPER" "every node check case" || finish
world_reset
G="$WORK/good"; python3 "$TESTLIB/fixture_node.py" "$G"
# nc <log> <subcommand> <args...>: the real helper after common.sh, as setup.sh calls it; sets RC.
nc() {
  local log="$1"; shift
  run_real "$log" bash -c 'SAMPLE_DIR="$1"; shift; source "$SAMPLE_DIR/scripts/common.sh" || exit 1; RUN_ID=r1 derive_names; python3 "$PY" "$@"' nc "$SAMPLE_DIR_REAL" "$@"
}
n=0
# case <subcommand> <file to change> <python: new text from t> <rc> <tag>[~<regex of the text>] <description> <args with @D@ for the case folder>
# The optional text after ~ pins the refusal to one site (a mutant that removes that site then
# fails the case, even when another path of the check prints the same tag).
case_nc() {
  local sub="$1" file="$2" code="$3" want="$4" tag="$5" why="$6" args="$7" d rx
  n=$((n + 1)); d="$WORK/c$n"; cp -r "$G" "$d"
  if [[ "$code" == DELETE ]]; then rm -f "$d/$file"
  elif [[ -n "$code" ]]; then python3 -c 'import sys; p = sys.argv[1]; t = open(p).read(); exec("t = " + sys.argv[2]); open(p, "w").write(t)' "$d/$file" "$code"
  fi
  rx="^ERROR: ${tag%%~*}: "; [[ "$tag" != *~* ]] || rx+="${tag#*~}"
  # shellcheck disable=SC2086
  nc "$WORK/c$n.log" "$sub" ${args//@D@/$d}
  check "$why" "$want" "$RC" "$WORK/c$n.log" "$rx"
}
accept_nc() { # accept_nc <subcommand> <tag> <description> <regex> <args with @D@>
  local sub="$1" tag="$2" why="$3" rx="$4" args="$5"
  entry "scripts/cilium_bottlerocket.py:$sub"
  # shellcheck disable=SC2086
  nc "$WORK/a-$sub.log" "$sub" ${args//@D@/$G}
  check "$why" 0 "$RC" "$WORK/a-$sub.log" "$rx"
  cover accept "$tag" "${tag}_UNKNOWN"
}

echo "== 1/4 the sandbox node before a sandbox pod starts (#281) =========================="
accept_nc check-os-image E_OS_IMAGE "ACCEPT the sandbox node: Bottlerocket OS 1.70.0 (aws-k8s-1.36-nitro-sandbox), kubelet v1.36, amd64" '^sandbox node: Bottlerocket OS 1\.70\.0' "sandbox @D@/node-sandbox.json"
nc "$WORK/a-os-system.log" check-os-image system "$G/node-system.json"
check "ACCEPT the system node: Bottlerocket OS 1.70.0 (aws-k8s-1.36)" 0 "$RC" "$WORK/a-os-system.log" '^system node: Bottlerocket OS 1\.70\.0 \(aws-k8s-1\.36\)'
accept_nc check-btf E_BTF "ACCEPT /sys/kernel/btf/vmlinux with a size above 0" '^/sys/kernel/btf/vmlinux: [0-9]+ bytes$' "@D@/btf.txt"
accept_nc check-mempool E_MEMPOOL "ACCEPT the mempool parameter on the kernel command line and the nitro_enclaves reservation in the kernel log" '^kernel command line has nitro_enclaves\.mempool=95%-1G' "--cmdline @D@/cmdline.txt --kernel-log @D@/kernel-log.txt"
accept_nc check-runtime-endpoint E_RUNTIME_ENDPOINT "ACCEPT the kubelet runtime endpoint unix:///run/nitro-sandbox/cri-proxy.sock" '^kubelet containerRuntimeEndpoint: unix:///run/nitro-sandbox/cri-proxy\.sock$' "@D@/configz.json"
accept_nc check-allocatable E_ALLOCATABLE "ACCEPT allocatable eks.amazonaws.com/nitro-sandbox above 0" '^allocatable eks\.amazonaws\.com/nitro-sandbox: 58$' "@D@/node-sandbox.json"
accept_nc check-density E_DENSITY "ACCEPT SANDBOX_SLOTS 58 equal to the SandboxSlots tag of the AMI and pcie_slots in nitro-sandbox.toml" '^density: SANDBOX_SLOTS=58 equals AMI tag SandboxSlots, node pcie_slots$' "--slots 58 --ami-tags @D@/ami-tags.json --shim-toml @D@/nitro-sandbox.toml"
accept_nc check-max-pods E_MAX_PODS "ACCEPT the derived max-pods 118 (m8i.xlarge) equal to the launch template max-pods and the node's capacity pods" '^max-pods: derived 118 equals launch template max-pods \(118\), node capacity pods \(118\)$' "--want 118 --launch-template @D@/lt-sandbox.json --node @D@/node-sandbox.json"
accept_nc check-slots E_SLOTS "ACCEPT SANDBOX_SLOTS 58: not above pcie_slots_total 58, equal to the driver's pcie_slots, the node capacity and the runtime's advertised count" '^slots: SANDBOX_SLOTS=58, pcie_slots_total=58, driver pcie_slots=58, node capacity eks\.amazonaws\.com/nitro-sandbox=58, max_pcie_devices=32, runtime: advertising 58 \(target=58\)$' "--driver @D@/slots.txt --node @D@/node-sandbox.json --journal @D@/journal.txt"
# An m8i.xlarge sandbox node with SANDBOX_SLOTS 58: the slot pool of the instance is 20, the driver
# and the node have 20, and the runtime clamped its target of 58 to 20. check-slots must stop it.
POOL="$WORK/pool20"; cp -r "$G" "$POOL"
printf 'pcie_slots_total=20\npcie_slots=20\nmax_pcie_devices=32\n' > "$POOL/slots.txt"
printf 'Nov 21 00:00:02 node containerd-shim-nitro-sandbox-v2[900]: advertising 20 nitro-sandbox slots (target=58)\n' > "$POOL/journal.txt"
python3 -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["status"]["capacity"]["eks.amazonaws.com/nitro-sandbox"] = "20"; json.dump(d, open(p, "w"))' "$POOL/node-sandbox.json"
nc "$WORK/pool20.log" check-slots --driver "$POOL/slots.txt" --node "$POOL/node-sandbox.json" --journal "$POOL/journal.txt"
check "REJECT SANDBOX_SLOTS 58 on a node whose slot pool, driver, node capacity and runtime all give 20" 1 "$RC" "$WORK/pool20.log" \
  '^ERROR: E_SLOTS: SANDBOX_SLOTS=58, but SANDBOX_SLOTS=58 is above the slot pool of the instance, pcie_slots_total=20; the driver.s pcie_slots is 20; the node capacity eks\.amazonaws\.com/nitro-sandbox is 20; the runtime advertised 20 slots$'
while IFS='|' read -r sub file code want tag why args; do
  [[ -n "$sub" ]] || continue
  case_nc "$sub" "$file" "$code" "$want" "$tag" "$why" "$args"
done <<'CASES'
check-os-image|node-sandbox.json|t.replace("aws-k8s-1.36-nitro-sandbox", "aws-k8s-1.36")|1|E_OS_IMAGE|REJECT a sandbox node that runs the stock aws-k8s-1.36 variant|sandbox @D@/node-sandbox.json
check-os-image|node-sandbox.json|t.replace("1.70.0", "1.69.2")|1|E_OS_IMAGE|REJECT a sandbox node on Bottlerocket 1.69.2|sandbox @D@/node-sandbox.json
check-os-image|node-sandbox.json|t.replace("v1.36.4", "v1.35.9")|1|E_OS_IMAGE|REJECT a kubelet that is not v1.36|sandbox @D@/node-sandbox.json
check-os-image|node-sandbox.json|t.replace("amd64", "arm64")|1|E_OS_IMAGE|REJECT an arm64 node|sandbox @D@/node-sandbox.json
check-os-image|node-sandbox.json|DELETE|2|E_OS_IMAGE_UNKNOWN|REJECT a node capture that cannot be read, as could not check|sandbox @D@/node-sandbox.json
check-os-image|node-sandbox.json|"not json"|2|E_OS_IMAGE_UNKNOWN|REJECT a node capture that is not JSON, as could not check|sandbox @D@/node-sandbox.json
check-btf|btf.txt|"BTF_BYTES=0\n"|1|E_BTF|REJECT an empty /sys/kernel/btf/vmlinux|@D@/btf.txt
check-btf|btf.txt|"ls: cannot access '/sys/kernel/btf/vmlinux'\n"|2|E_BTF_UNKNOWN~could not check: the BTF capture is not BTF_BYTES=<n>: |REJECT a BTF capture that is an error, as could not check|@D@/btf.txt
check-btf|btf.txt|DELETE|2|E_BTF_UNKNOWN|REJECT a BTF capture that cannot be read, as could not check|@D@/btf.txt
check-mempool|cmdline.txt|t.replace(" nitro_enclaves.mempool=95%-1G", "")|1|E_MEMPOOL|REJECT a kernel command line without the mempool parameter|--cmdline @D@/cmdline.txt --kernel-log @D@/kernel-log.txt
check-mempool|cmdline.txt|t.replace("95%-1G", "50%")|1|E_MEMPOOL|REJECT another mempool value|--cmdline @D@/cmdline.txt --kernel-log @D@/kernel-log.txt
check-mempool|kernel-log.txt|"[    0.000000] Linux version 6.18.62\n"|1|E_MEMPOOL|REJECT a kernel log without the nitro_enclaves reservation|--cmdline @D@/cmdline.txt --kernel-log @D@/kernel-log.txt
check-mempool|kernel-log.txt|""|2|E_MEMPOOL_UNKNOWN|REJECT an empty kernel log capture, as could not check|--cmdline @D@/cmdline.txt --kernel-log @D@/kernel-log.txt
check-runtime-endpoint|configz.json|t.replace("unix:///run/nitro-sandbox/cri-proxy.sock", "unix:///run/containerd/containerd.sock")|1|E_RUNTIME_ENDPOINT|REJECT a kubelet that talks to containerd directly|@D@/configz.json
check-runtime-endpoint|configz.json|DELETE|2|E_RUNTIME_ENDPOINT_UNKNOWN|REJECT a configz capture that cannot be read, as could not check|@D@/configz.json
check-allocatable|node-sandbox.json|t.replace('"eks.amazonaws.com/nitro-sandbox": "58"', '"eks.amazonaws.com/nitro-sandbox": "0"')|1|E_ALLOCATABLE|REJECT allocatable nitro-sandbox 0|@D@/node-sandbox.json
check-allocatable|node-sandbox.json|(lambda d: (d["status"]["allocatable"].pop("eks.amazonaws.com/nitro-sandbox"), __import__("json").dumps(d))[1])(__import__("json").loads(t))|1|E_ALLOCATABLE|REJECT a node that does not advertise nitro-sandbox|@D@/node-sandbox.json
check-allocatable|node-sandbox.json|DELETE|2|E_ALLOCATABLE_UNKNOWN|REJECT a node capture that cannot be read, as could not check|@D@/node-sandbox.json
check-density|ami-tags.json|t.replace('"Value": "58"', '"Value": "57"', 1)|1|E_DENSITY|REJECT an AMI whose SandboxSlots tag differs from SANDBOX_SLOTS|--slots 58 --ami-tags @D@/ami-tags.json
check-density|nitro-sandbox.toml|t.replace("= 58", "= 57")|1|E_DENSITY|REJECT pcie_slots on the node that differs from SANDBOX_SLOTS|--slots 58 --shim-toml @D@/nitro-sandbox.toml
check-density|nitro-sandbox.toml|t + "pcie_slots = 58\n"|1|E_DENSITY|REJECT a nitro-sandbox.toml with two pcie_slots lines|--slots 58 --shim-toml @D@/nitro-sandbox.toml
check-density|ami-tags.json||2|E_DENSITY_UNKNOWN|REJECT check-density with no input to compare, as could not check|--slots 58
check-max-pods|node-sandbox.json|(lambda d: (d["status"]["capacity"].__setitem__("pods", "58"), __import__("json").dumps(d))[1])(__import__("json").loads(t))|1|E_MAX_PODS~the derived max-pods is 118 but node capacity pods=58$|REJECT node capacity pods (58) that differ from the derived max-pods|--want 118 --launch-template @D@/lt-sandbox.json --node @D@/node-sandbox.json
check-max-pods|lt-sandbox.json|__import__("json").dumps({"LaunchTemplateVersions": [{"LaunchTemplateData": {"UserData": __import__("base64").b64encode(b"max-pods = 58\n").decode()}}]})|1|E_MAX_PODS~the derived max-pods is 118 but launch template max-pods=58$|REJECT launch template user data whose max-pods (58) differs from the derived value|--want 118 --launch-template @D@/lt-sandbox.json --node @D@/node-sandbox.json
check-max-pods|lt-sandbox.json|__import__("json").dumps({"LaunchTemplateVersions": [{"LaunchTemplateData": {"UserData": __import__("base64").b64encode(b"max-pods = 118\nmax-pods = 118\n").decode()}}]})|1|E_MAX_PODS~the launch template user data has 2 max-pods lines$|REJECT launch template user data with two max-pods lines|--want 118 --launch-template @D@/lt-sandbox.json
check-max-pods|node-sandbox.json|(lambda d: (d["status"]["capacity"].pop("pods"), __import__("json").dumps(d))[1])(__import__("json").loads(t))|2|E_MAX_PODS_UNKNOWN~could not check: the node capacity pods is None, not a number$|REJECT a node with no capacity pods, as could not check|--want 118 --node @D@/node-sandbox.json
check-max-pods|lt-sandbox.json|'{"LaunchTemplateVersions": [{"LaunchTemplateData": {}}]}'|2|E_MAX_PODS_UNKNOWN~could not check: the launch template input has no base64 user data$|REJECT a launch template with no user data, as could not check|--want 118 --launch-template @D@/lt-sandbox.json
check-max-pods|lt-sandbox.json||2|E_MAX_PODS_UNKNOWN~could not check: check-max-pods got no input to compare$|REJECT check-max-pods with no input to compare, as could not check|--want 118
check-slots|node-sandbox.json|(lambda d: (d["status"]["capacity"].__setitem__("eks.amazonaws.com/nitro-sandbox", "20"), __import__("json").dumps(d))[1])(__import__("json").loads(t))|1|E_SLOTS~SANDBOX_SLOTS=58, but the node capacity eks\.amazonaws\.com/nitro-sandbox is 20$|REJECT a node that advertises fewer slots (20) than SANDBOX_SLOTS|--driver @D@/slots.txt --node @D@/node-sandbox.json --journal @D@/journal.txt
check-slots|slots.txt|t.replace("pcie_slots=58", "pcie_slots=20")|1|E_SLOTS~SANDBOX_SLOTS=58, but the driver's pcie_slots is 20$|REJECT a driver pcie_slots (20) that differs from SANDBOX_SLOTS|--driver @D@/slots.txt --node @D@/node-sandbox.json --journal @D@/journal.txt
check-slots|journal.txt|t.replace("advertising 58 ", "advertising 20 ")|1|E_SLOTS~SANDBOX_SLOTS=58, but the runtime advertised 20 slots$|REJECT a runtime that advertised another slot count (20) than SANDBOX_SLOTS|--driver @D@/slots.txt --node @D@/node-sandbox.json --journal @D@/journal.txt
check-slots|slots.txt|t.replace("pcie_slots_total=58", "pcie_slots_total=20")|1|E_SLOTS~SANDBOX_SLOTS=58, but SANDBOX_SLOTS=58 is above the slot pool of the instance, pcie_slots_total=20$|REJECT SANDBOX_SLOTS 58 above the slot pool, pcie_slots_total 20|--driver @D@/slots.txt --node @D@/node-sandbox.json --journal @D@/journal.txt
check-slots|node-sandbox.json|(lambda d: (d["status"]["capacity"].pop("eks.amazonaws.com/nitro-sandbox"), __import__("json").dumps(d))[1])(__import__("json").loads(t))|2|E_SLOTS_UNKNOWN~could not check: the node capacity eks\.amazonaws\.com/nitro-sandbox is None, not a number$|REJECT a node with no eks.amazonaws.com/nitro-sandbox capacity, as could not check|--driver @D@/slots.txt --node @D@/node-sandbox.json
check-slots|slots.txt|""|2|E_SLOTS_UNKNOWN~could not check: the input .*/slots\.txt is empty$|REJECT an empty driver capture (a failed sysfs read), as could not check|--driver @D@/slots.txt --node @D@/node-sandbox.json
check-slots|slots.txt|"pcie_slots_total=58\n"|2|E_SLOTS_UNKNOWN~could not check: the driver capture has no pcie_slots, max_pcie_devices$|REJECT a driver capture with no pcie_slots, as could not check|--driver @D@/slots.txt --node @D@/node-sandbox.json
check-slots|journal.txt|""|2|E_SLOTS_UNKNOWN~could not check: the input .*/journal\.txt is empty$|REJECT an empty journal capture, as could not check|--driver @D@/slots.txt --node @D@/node-sandbox.json --journal @D@/journal.txt
CASES

echo "== 2/4 the merged containerd configuration: a real containerd config dump (#281) ======"
DROPIN="$SAMPLE_DIR_REAL/variant/packages/nitro-sandbox/50-nitro-sandbox.toml"
if [[ -z "${CB_CONTAINERD:-}" || ! -x "$CB_CONTAINERD" ]] || ! "$CB_CONTAINERD" --version 2>/dev/null | grep -qE ' v?2\.[0-9]+\.'; then
  not_run "the containerd config dump cases" "no containerd 2.x (set CB_CONTAINERD to one)"
elif need_file "$DROPIN" "the containerd config dump cases"; then
  # dump <case> <drop-in content file or "none">: a Bottlerocket-shaped base config importing <case>/config.d
  dump() {
    local d="$WORK/ctrd-$1"; mkdir -p "$d/config.d"
    [[ "$2" == none ]] || cp "$2" "$d/config.d/50-nitro-sandbox.toml"
    sed -e "s#@DROPIN_DIR@#$d/config.d#" -e "s#@WORK@#$d#g" "$TESTLIB/containerd-base.toml" > "$d/config.toml"
    "$CB_CONTAINERD" --config "$d/config.toml" config dump > "$d/dump.txt" 2>&1 || true
  }
  "$CB_CONTAINERD" --version > "$WORK/containerd-version.txt" 2>&1
  dump valid "$DROPIN"
  entry scripts/cilium_bottlerocket.py:check-containerd-dump
  nc "$WORK/ctrd-valid.log" check-containerd-dump "$WORK/ctrd-valid/dump.txt"
  check "ACCEPT the dump with the tracked drop-in: the isolated-sandbox handler and discard_unpacked_layers = false ($(cut -d' ' -f3 "$WORK/containerd-version.txt"))" 0 "$RC" \
    "$WORK/ctrd-valid.log" '^merged containerd config: isolated-sandbox handler'
  cover accept E_CONTAINERD_DUMP E_CONTAINERD_DUMP_UNKNOWN
  dump none none
  nc "$WORK/ctrd-none.log" check-containerd-dump "$WORK/ctrd-none/dump.txt"
  check "REJECT the dump with no drop-in: no isolated-sandbox handler" 1 "$RC" "$WORK/ctrd-none.log" '^ERROR: E_CONTAINERD_DUMP: the merged configuration has no isolated-sandbox runtime handler'
  head -n -3 "$DROPIN" > "$WORK/malformed.toml"; printf '[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.isolated-sandbox\nruntime_type = \n' >> "$WORK/malformed.toml"
  dump malformed "$WORK/malformed.toml"
  nc "$WORK/ctrd-malformed.log" check-containerd-dump "$WORK/ctrd-malformed/dump.txt"
  check "REJECT the dump with a malformed drop-in: containerd prints an error, not a configuration" 1 "$RC" "$WORK/ctrd-malformed.log" '^ERROR: E_CONTAINERD_DUMP: the input is not a containerd version 3 or 4 configuration dump'
  sed 's/^discard_unpacked_layers = false$/discard_unpacked_layers = true/' "$DROPIN" > "$WORK/discard.toml"
  dump discard "$WORK/discard.toml"
  nc "$WORK/ctrd-discard.log" check-containerd-dump "$WORK/ctrd-discard/dump.txt"
  check "REJECT the dump with discard_unpacked_layers = true" 1 "$RC" "$WORK/ctrd-discard.log" '^ERROR: E_CONTAINERD_DUMP: discard_unpacked_layers is'
  sed 's/io\.containerd\.nitro-sandbox\.v2/io.containerd.runc.v2/' "$DROPIN" > "$WORK/runc.toml"
  dump runc "$WORK/runc.toml"
  nc "$WORK/ctrd-runc.log" check-containerd-dump "$WORK/ctrd-runc/dump.txt"
  check "REJECT the dump whose isolated-sandbox handler is runc" 1 "$RC" "$WORK/ctrd-runc.log" '^ERROR: E_CONTAINERD_DUMP: the isolated-sandbox handler does not use runtime_type'
  nc "$WORK/ctrd-missing.log" check-containerd-dump "$WORK/ctrd-valid/no-such-dump.txt"
  check "REJECT a dump capture that cannot be read, as could not check" 2 "$RC" "$WORK/ctrd-missing.log" '^ERROR: E_CONTAINERD_DUMP_UNKNOWN: '
fi

echo "== 3/4 SELinux: enforcing, the audit, the domains =================================="
accept_nc check-selinux-mode E_SELINUX_MODE "ACCEPT SELinux in enforcing mode" '^SELinux: enforcing$' "@D@/selinux-enforce.txt"
accept_nc selinux-audit E_SELINUX_AUDIT "ACCEPT an AVC capture and a journal with no denial" '^SELinux audit: no AVC denial' "@D@/avc.txt @D@/journal.txt"
accept_nc check-selinux-domains E_SELINUX_DOMAINS "ACCEPT the shim and the CRI proxy in the runtime_t domain" '^SELinux domain runtime_t: CRI proxy \(1\) and shim \(1\)' "@D@/domains.txt"
while IFS='|' read -r sub file code want tag why args; do
  [[ -n "$sub" ]] || continue
  case_nc "$sub" "$file" "$code" "$want" "$tag" "$why" "$args"
done <<'CASES'
check-selinux-mode|selinux-enforce.txt|"0\n"|1|E_SELINUX_MODE|REJECT SELinux in permissive mode|@D@/selinux-enforce.txt
check-selinux-mode|selinux-enforce.txt|"cat: /sys/fs/selinux/enforce: No such file\n"|2|E_SELINUX_MODE_UNKNOWN|REJECT an enforce capture that is an error, as could not check|@D@/selinux-enforce.txt
selinux-audit|avc.txt|t + 'type=1400 audit(2.0:3): avc:  denied  { execute } for pid=42 comm="containerd-shim" scontext=system_u:system_r:runtime_t:s0\n'|1|E_SELINUX_AUDIT|REJECT an AVC denial in the kernel audit capture: the audit fails closed|@D@/avc.txt @D@/journal.txt
selinux-audit|journal.txt|t + 'Nov 21 00:00:02 node audit[42]: AVC avc:  denied  { read } for pid=42 comm="firecracker"\n'|1|E_SELINUX_AUDIT|REJECT an AVC denial in the journal: the audit fails closed|@D@/avc.txt @D@/journal.txt
selinux-audit|journal.txt|DELETE|2|E_SELINUX_AUDIT_UNKNOWN|REJECT a journal capture that cannot be read: the audit fails closed (exit 2)|@D@/avc.txt @D@/journal.txt
selinux-audit|avc.txt|""|2|E_SELINUX_AUDIT_UNKNOWN|REJECT an empty AVC capture: the audit fails closed (exit 2)|@D@/avc.txt @D@/journal.txt
check-selinux-domains|domains.txt|t.replace("runtime_t:s0\t/usr/bin/containerd-shim-nitro-sandbox-v2 -namespace", "unconfined_t:s0\t/usr/bin/containerd-shim-nitro-sandbox-v2 -namespace")|1|E_SELINUX_DOMAINS|REJECT a sandbox shim outside runtime_t|@D@/domains.txt
check-selinux-domains|domains.txt|"\n".join(l for l in t.splitlines() if " cri-proxy" not in l) + "\n"|1|E_SELINUX_DOMAINS|REJECT a node where the CRI proxy does not run|@D@/domains.txt
check-selinux-domains|domains.txt|"\n".join(l for l in t.splitlines() if "-namespace" not in l) + "\n"|1|E_SELINUX_DOMAINS|REJECT a node with no sandbox shim process|@D@/domains.txt
check-selinux-domains|domains.txt|"system_u:system_r:system_t:s0\t/usr/bin/kubelet\n"|1|E_SELINUX_DOMAINS|REJECT a node where no shim binary runs at all|@D@/domains.txt
check-selinux-domains|domains.txt|DELETE|2|E_SELINUX_DOMAINS_UNKNOWN|REJECT a process capture that cannot be read, as could not check|@D@/domains.txt
CASES

echo "== 4/4 networkd, dm-verity, the network-isolated pod, the pod IP, Cilium =============="
accept_nc check-networkd E_NETWORKD "ACCEPT eth1, a Cilium ENI, unmanaged by systemd-networkd" '^systemd-networkd: eth1 unmanaged$' "@D@/networkd.txt"
# The ENI capture, the kubeconfig path of the shim, mkfs.erofs, the mempool line.
# The kubeconfig case reads the tracked nitro-sandbox.toml of the package.
cp "$SAMPLE_DIR_REAL/variant/packages/nitro-sandbox/nitro-sandbox.toml" "$G/shim.toml"
awk '{print} /^==route==$/{print "10.0.0.0/19 dev eth1 proto kernel scope link src 10.0.2.10"}' "$G/eni-a.txt" > "$G/eni-a-kernel.txt"
accept_nc check-eni-capture E_ENI_CAPTURE "ACCEPT capture A: eth1 unmanaged, link-local IPv6 only, the two Cilium routes of table 11 via the subnet gateway, one endpoint rule" \
  '^Cilium ENIs as Cilium sets them: eth1 unmanaged, table 11 via 10\.0\.0\.1, 1 endpoint rule\(s\)$' "--capture @D@/eni-a.txt --networkd @D@/networkd-a.txt --ciliumnode @D@/ciliumnode-a.json"
nc "$WORK/a-eni-kernel.log" check-eni-capture --capture "$G/eni-a-kernel.txt" --networkd "$G/networkd-a.txt" --ciliumnode "$G/ciliumnode-a.json"
check "ACCEPT capture A with the kernel route of an address of the ENI record (main table, proto kernel)" 0 "$RC" "$WORK/a-eni-kernel.log" '^Cilium ENIs as Cilium sets them: '
# The mempool line of the driver: a pool cut short that still reserved regions passes.
printf '[    0.000000] Linux version 6.18.62\n[    0.012300] nitro_enclaves: CMA region 7 (2048 MiB, nid 0) not reserved: -12; truncating the pool here\n[    0.012345] nitro_enclaves: CMA pool: 12288 MiB reserved in 6 region(s), 14848 MiB requested\n' > "$WORK/k-trunc.log"
nc "$WORK/a-mempool-trunc.log" check-mempool --cmdline "$G/cmdline.txt" --kernel-log "$WORK/k-trunc.log"
check "ACCEPT a truncated CMA pool that still reserved 6 regions" 0 "$RC" "$WORK/a-mempool-trunc.log" '^kernel command line has nitro_enclaves\.mempool=95%-1G; driver: nitro_enclaves: CMA pool: 12288 MiB reserved in 6 region\(s\)'
accept_nc check-kubeconfig-path E_KUBECONFIG_PATH "ACCEPT the tracked nitro-sandbox.toml: kubeconfig_path /etc/kubernetes/kubelet/kubeconfig, present and not empty on the node" \
  '^kubeconfig_path /etc/kubernetes/kubelet/kubeconfig: present on the node \(5321 bytes\)$' "--shim-toml @D@/shim.toml --kubeconfig @D@/kubeconfig.txt"
accept_nc check-mkfs-erofs E_MKFS_EROFS "ACCEPT mkfs.erofs 1.9.4 of the host with the zstd compressor" '^mkfs.erofs 1\.9\.4 on the host: compressors .*zstd' "@D@/mkfs-erofs.txt"
accept_nc check-eni-stable E_ENI_STABLE "ACCEPT eth1 unchanged across the event: MAC, addresses, routes of every table, rules, all in the CiliumNode ENI record" \
  '^Cilium ENIs unchanged by networkd: eth1 \(1 addresses, 3 routes, tables 11,local\)$' "--before @D@/eni-before.txt --after @D@/eni-after.txt --ciliumnode @D@/ciliumnode.json"
accept_nc check-dm-verity E_DM_VERITY "ACCEPT / on the read-only dm-verity device dm-0" '^dm-verity: / is the read-only dm-0' "@D@/dm-verity.txt"
accept_nc check-network-isolated E_NETWORK_ISOLATED "ACCEPT the network-isolated sandbox: only lo, no route, DNS fails" '^network-isolated pod: only lo, no route, the DNS lookup fails$' "@D@/isolated.txt"
accept_nc pod-in-eni E_POD_IN_ENI "ACCEPT a pod IP that is a secondary IP of a node ENI" '^pod IP 10\.0\.1\.21: secondary IP of eni-' "10.0.1.21 @D@/enis.json"
accept_nc kpr-status E_KPR_STATUS "ACCEPT ENI IPAM, native routing, kube-proxy replacement True and the socket LB for the host namespace only" '^cilium status: ENI IPAM, native routing' "@D@/cilium-status.txt --config @D@/cilium-config.txt"
while IFS='|' read -r sub file code want tag why args; do
  [[ -n "$sub" ]] || continue
  case_nc "$sub" "$file" "$code" "$want" "$tag" "$why" "$args"
done <<'CASES'
check-networkd|networkd.txt|t.replace("3 ADMIN_STATE=unmanaged", "3 ADMIN_STATE=configured")|1|E_NETWORKD|REJECT a Cilium ENI (eth1) that systemd-networkd manages|@D@/networkd.txt
check-networkd|networkd.txt|t.replace("3 ADMIN_STATE=unmanaged OPER_STATE=routable\n", "")|1|E_NETWORKD|REJECT a Cilium ENI with no networkd state line|@D@/networkd.txt
check-networkd|networkd.txt|t.replace("3: eth1: <BROADCAST,UP>\n", "")|2|E_NETWORKD_UNKNOWN|REJECT a node with no secondary ENI yet, as could not check|@D@/networkd.txt
check-networkd|networkd.txt|"ip: command not found\n"|2|E_NETWORKD_UNKNOWN|REJECT a capture without its sections, as could not check|@D@/networkd.txt
check-eni-capture|networkd-a.txt|t.replace("6 ADMIN_STATE=unmanaged", "6 ADMIN_STATE=configured")|1|E_ENI_CAPTURE|REJECT capture A when systemd-networkd manages eth1|--capture @D@/eni-a.txt --networkd @D@/networkd-a.txt --ciliumnode @D@/ciliumnode-a.json
check-eni-capture|eni-a.txt|t.replace("==route==", "6: eth1    inet 10.0.2.10/19 brd 10.0.31.255 scope global dynamic eth1\n==route==")|1|E_ENI_CAPTURE|REJECT a dynamic (DHCP) address on eth1|--capture @D@/eni-a.txt --networkd @D@/networkd-a.txt --ciliumnode @D@/ciliumnode-a.json
check-eni-capture|eni-a.txt|t.replace("==route6==", "default via 10.0.0.1 dev eth1 proto dhcp src 10.0.2.10 metric 1024\n==route6==")|1|E_ENI_CAPTURE|REJECT a proto dhcp route on eth1|--capture @D@/eni-a.txt --networkd @D@/networkd-a.txt --ciliumnode @D@/ciliumnode-a.json
check-eni-capture|eni-a.txt|t.replace("==rule==", "default via fe80::1 dev eth1 proto ra metric 1024 expires 1799sec pref medium\n==rule==")|1|E_ENI_CAPTURE|REJECT a proto ra IPv6 route on eth1|--capture @D@/eni-a.txt --networkd @D@/networkd-a.txt --ciliumnode @D@/ciliumnode-a.json
check-eni-capture|eni-a.txt|t.replace("==route==", "6: eth1    inet6 2600:1f14::5/128 scope global \\       valid_lft forever preferred_lft forever\n==route==")|1|E_ENI_CAPTURE|REJECT a global IPv6 address on eth1|--capture @D@/eni-a.txt --networkd @D@/networkd-a.txt --ciliumnode @D@/ciliumnode-a.json
check-eni-capture|eni-a.txt|t.replace("32766:", "112:\tfrom 10.0.1.21 lookup 11 proto kernel\n32766:")|1|E_ENI_CAPTURE|REJECT a rule that sends an address of eth0's ENI to the eth1 table|--capture @D@/eni-a.txt --networkd @D@/networkd-a.txt --ciliumnode @D@/ciliumnode-a.json
check-eni-capture|eni-a.txt|t.replace("table 11", "table 12").replace("lookup 11 ", "lookup 12 ")|1|E_ENI_CAPTURE|REJECT routes and rule in table 12 for ENI number 1 (Cilium uses 10 + the number)|--capture @D@/eni-a.txt --networkd @D@/networkd-a.txt --ciliumnode @D@/ciliumnode-a.json
check-eni-capture|ciliumnode-a.json|t.replace("10.0.0.0/19", "10.0.96.0/19")|1|E_ENI_CAPTURE|REJECT routes that do not use the gateway of the ENI subnet|--capture @D@/eni-a.txt --networkd @D@/networkd-a.txt --ciliumnode @D@/ciliumnode-a.json
check-eni-capture|eni-a.txt|t.replace("==route6==", "10.0.0.0/19 dev eth1 proto static scope link\n==route6==")|1|E_ENI_CAPTURE|REJECT another route on eth1 in the main table|--capture @D@/eni-a.txt --networkd @D@/networkd-a.txt --ciliumnode @D@/ciliumnode-a.json
check-eni-capture|ciliumnode-a.json|t.replace("0a:00:00:00:00:02", "0a:00:00:00:00:09")|1|E_ENI_CAPTURE|REJECT an eth1 whose MAC is no ENI of the CiliumNode|--capture @D@/eni-a.txt --networkd @D@/networkd-a.txt --ciliumnode @D@/ciliumnode-a.json
check-eni-capture|eni-a.txt|t.replace("111:\tfrom 10.0.2.20 lookup 11 proto kernel\n", "")|2|E_ENI_CAPTURE_UNKNOWN|REJECT the Cilium routes with no endpoint rule: nothing is proved, as could not check|--capture @D@/eni-a.txt --networkd @D@/networkd-a.txt --ciliumnode @D@/ciliumnode-a.json
check-eni-capture|eni-a.txt|t.replace("==route6==\n", "")|2|E_ENI_CAPTURE_UNKNOWN|REJECT a capture without its IPv6 route section, as could not check|--capture @D@/eni-a.txt --networkd @D@/networkd-a.txt --ciliumnode @D@/ciliumnode-a.json
check-eni-capture|ciliumnode-a.json|t.replace('"cidr"', '"nocidr"')|2|E_ENI_CAPTURE_UNKNOWN|REJECT a CiliumNode ENI record with no subnet CIDR, as could not check|--capture @D@/eni-a.txt --networkd @D@/networkd-a.txt --ciliumnode @D@/ciliumnode-a.json
check-eni-capture|eni-a.txt|t.replace("6: eth1: <", "6: dummy0: <")|2|E_ENI_CAPTURE_UNKNOWN|REJECT a capture with no eth1 or later link, as could not check|--capture @D@/eni-a.txt --networkd @D@/networkd-a.txt --ciliumnode @D@/ciliumnode-a.json
check-mempool|kernel-log.txt|t.replace("CMA pool: 14336 MiB reserved in 7 region(s), 14848 MiB requested", "AWSNitroEnclaves EFI table absent, skipping CMA reservation")|1|E_MEMPOOL|REJECT a driver that skipped the CMA reservation|--cmdline @D@/cmdline.txt --kernel-log @D@/kernel-log.txt
check-mempool|kernel-log.txt|t.replace("14336 MiB reserved in 7", "0 MiB reserved in 0")|1|E_MEMPOOL|REJECT a CMA pool of 0 MiB in 0 regions|--cmdline @D@/cmdline.txt --kernel-log @D@/kernel-log.txt
check-mempool|kernel-log.txt|"[    0.000000] Kernel command line: BOOT_IMAGE=(hd0,gpt3)/vmlinuz nitro_enclaves.mempool=95%-1G quiet\n"|1|E_MEMPOOL|REJECT a kernel log with only the kernel's echo of the command line|--cmdline @D@/cmdline.txt --kernel-log @D@/kernel-log.txt
check-kubeconfig-path|shim.toml|t.replace('kubeconfig_path = "/etc/kubernetes/kubelet/kubeconfig"', 'kubeconfig_path = "/var/lib/kubelet/kubeconfig"')|1|E_KUBECONFIG_PATH|REJECT another kubeconfig_path in nitro-sandbox.toml|--shim-toml @D@/shim.toml --kubeconfig @D@/kubeconfig.txt
check-kubeconfig-path|shim.toml|t + 'kubeconfig_path = "/etc/kubernetes/kubelet/kubeconfig"\n'|1|E_KUBECONFIG_PATH|REJECT two kubeconfig_path lines|--shim-toml @D@/shim.toml --kubeconfig @D@/kubeconfig.txt
check-kubeconfig-path|kubeconfig.txt|"KUBECONFIG_ABSENT\n"|1|E_KUBECONFIG_PATH|REJECT a kubeconfig that is not on the node|--shim-toml @D@/shim.toml --kubeconfig @D@/kubeconfig.txt
check-kubeconfig-path|kubeconfig.txt|"KUBECONFIG_BYTES=0\n"|1|E_KUBECONFIG_PATH|REJECT an empty kubeconfig on the node|--shim-toml @D@/shim.toml --kubeconfig @D@/kubeconfig.txt
check-kubeconfig-path|kubeconfig.txt|"stat: permission denied\n"|2|E_KUBECONFIG_PATH_UNKNOWN~could not check: the kubeconfig capture is not KUBECONFIG_BYTES=<n> or KUBECONFIG_ABSENT$|REJECT a kubeconfig capture in neither form, as could not check|--shim-toml @D@/shim.toml --kubeconfig @D@/kubeconfig.txt
check-mkfs-erofs|mkfs-erofs.txt|t.replace(", zstd", "")|1|E_MKFS_EROFS|REJECT a mkfs.erofs without the zstd compressor|@D@/mkfs-erofs.txt
check-mkfs-erofs|mkfs-erofs.txt|"chroot: cannot execute /usr/bin/mkfs.erofs: No such file or directory\n"|2|E_MKFS_EROFS_UNKNOWN~could not check: the capture is not the 'mkfs.erofs -V' output of erofs-utils$|REJECT a capture that is not mkfs.erofs -V output, as could not check|@D@/mkfs-erofs.txt
selinux-audit|journal.txt|"-- No entries --\n"|2|E_SELINUX_AUDIT_UNKNOWN|REJECT a journal of only -- No entries --: no evidence, exit 2|@D@/avc.txt @D@/journal.txt
selinux-audit|avc.txt|"-- No entries --\n"|2|E_SELINUX_AUDIT_UNKNOWN|REJECT a kernel log of only -- No entries --: no evidence, exit 2|@D@/avc.txt @D@/journal.txt
check-eni-stable|eni-after.txt|t.replace("==route==", "3: eth1    inet 10.0.1.21/24 brd 10.0.1.255 scope global secondary eth1\n==route==")|1|E_ENI_STABLE|REJECT an address added to eth1 after the event (even one of its ENI record)|--before @D@/eni-before.txt --after @D@/eni-after.txt --ciliumnode @D@/ciliumnode.json
check-eni-stable|eni-after.txt|t.replace("default via 10.0.1.1 dev eth1 table 11\n", "")|1|E_ENI_STABLE|REJECT a route of eth1 (table 11 default) removed after the event|--before @D@/eni-before.txt --after @D@/eni-after.txt --ciliumnode @D@/ciliumnode.json
check-eni-stable|eni-after.txt|t.replace("20:\tfrom 10.0.1.20 lookup 11\n", "")|1|E_ENI_STABLE|REJECT the ip rule to eth1's table removed after the event|--before @D@/eni-before.txt --after @D@/eni-after.txt --ciliumnode @D@/ciliumnode.json
check-eni-stable|ciliumnode.json|t.replace("0a:00:00:00:00:02", "0a:00:00:00:00:09")|1|E_ENI_STABLE|REJECT an eth1 whose MAC is not an ENI of the CiliumNode|--before @D@/eni-before.txt --after @D@/eni-after.txt --ciliumnode @D@/ciliumnode.json
check-eni-stable|eni-after.txt|t.replace("link/ether 0a:00:00:00:00:02", "link/ether 0a:00:00:00:00:03")|1|E_ENI_STABLE|REJECT an eth1 whose MAC changed after the event|--before @D@/eni-before.txt --after @D@/eni-after.txt --ciliumnode @D@/ciliumnode.json
check-eni-stable|ciliumnode.json|t.replace('"ip": "10.0.1.20"', '"ip": "10.0.1.30"')|1|E_ENI_STABLE|REJECT an eth1 address that is not in its ENI record (unchanged across the event)|--before @D@/eni-before.txt --after @D@/eni-after.txt --ciliumnode @D@/ciliumnode.json
check-eni-stable|eni-after.txt|t.replace("3: eth1: <", "4: eth2: <")|1|E_ENI_STABLE|REJECT an interface that is in only one capture|--before @D@/eni-before.txt --after @D@/eni-after.txt --ciliumnode @D@/ciliumnode.json
check-eni-stable|eni-after.txt|""|2|E_ENI_STABLE_UNKNOWN|REJECT an empty capture after the event, as could not check|--before @D@/eni-before.txt --after @D@/eni-after.txt --ciliumnode @D@/ciliumnode.json
check-eni-stable|eni-after.txt|t.replace("3: eth1: <", "3: dummy0: <")|2|E_ENI_STABLE_UNKNOWN|REJECT a capture after the event with no eth1 or later interface, as could not check|--before @D@/eni-before.txt --after @D@/eni-after.txt --ciliumnode @D@/ciliumnode.json
check-eni-stable|ciliumnode.json|'{"status": {}}'|2|E_ENI_STABLE_UNKNOWN|REJECT a CiliumNode with no ENI status, as could not check|--before @D@/eni-before.txt --after @D@/eni-after.txt --ciliumnode @D@/ciliumnode.json
check-dm-verity|dm-verity.txt|t.replace("==dm==\nroot", "==dm==\nother")|1|E_DM_VERITY|REJECT a dm-0 that is not the root verity device|@D@/dm-verity.txt
check-dm-verity|dm-verity.txt|t.replace(" verity ", " linear ")|1|E_DM_VERITY|REJECT a kernel command line without verity|@D@/dm-verity.txt
check-dm-verity|dm-verity.txt|t.replace("/ / ro,relatime", "/ / rw,relatime")|1|E_DM_VERITY|REJECT a root that is mounted read-write|@D@/dm-verity.txt
check-dm-verity|dm-verity.txt|t.replace("22 1 254:0", "22 1 259:1")|1|E_DM_VERITY|REJECT a root on another device than dm-0|@D@/dm-verity.txt
check-dm-verity|dm-verity.txt|t.split("==mount==")[0]|2|E_DM_VERITY_UNKNOWN~could not check: the capture has no ==dm==, ==dev==, ==cmdline== and ==mount== sections$|REJECT a capture without its mount section, as could not check|@D@/dm-verity.txt
check-network-isolated|isolated.txt|t.replace("==route==", "2: eth0    inet 10.0.1.30/32 scope global eth0\n==route==")|1|E_NETWORK_ISOLATED|REJECT a network-isolated pod that has eth0|@D@/isolated.txt
check-network-isolated|isolated.txt|t.replace("==route==\n", "==route==\ndefault via 169.254.1.1 dev eth0\n")|1|E_NETWORK_ISOLATED|REJECT a network-isolated pod that has a default route|@D@/isolated.txt
check-network-isolated|isolated.txt|t.replace("==dns rc=1==", "==dns rc=0==")|1|E_NETWORK_ISOLATED|REJECT a network-isolated pod whose DNS lookup succeeds|@D@/isolated.txt
check-network-isolated|isolated.txt|DELETE|2|E_NETWORK_ISOLATED_UNKNOWN|REJECT a pod capture that cannot be read, as could not check|@D@/isolated.txt
check-network-isolated|isolated.txt|t.replace("==dns rc=1==", "==dns==")|2|E_NETWORK_ISOLATED_UNKNOWN|REJECT a capture without the DNS exit code, as could not check|@D@/isolated.txt
pod-in-eni|enis.json||1|E_POD_IN_ENI|REJECT a pod IP that is the primary IP of the ENI|10.0.1.20 @D@/enis.json
pod-in-eni|enis.json||1|E_POD_IN_ENI|REJECT a pod IP that no node ENI has|10.0.9.9 @D@/enis.json
pod-in-eni|enis.json|'{"NetworkInterfaces": []}'|2|E_POD_IN_ENI_UNKNOWN|REJECT an ENI read with no interface, as could not check|10.0.1.21 @D@/enis.json
kpr-status|cilium-status.txt|t.replace("  Status:                 True", "  Status:                 False")|1|E_KPR_STATUS|REJECT kube-proxy replacement that is not active|@D@/cilium-status.txt --config @D@/cilium-config.txt
kpr-status|cilium-status.txt|t.replace("Hostns-only", "Full")|1|E_KPR_STATUS|REJECT the socket LB in every namespace (socketLB.hostNamespaceOnly not set)|@D@/cilium-status.txt --config @D@/cilium-config.txt
kpr-status|cilium-status.txt|t.replace("Network: Native", "Network: Tunnel [vxlan]")|1|E_KPR_STATUS|REJECT tunnel routing|@D@/cilium-status.txt --config @D@/cilium-config.txt
kpr-status|cilium-config.txt|t.replace(": eni", ": cluster-pool")|1|E_KPR_STATUS|REJECT an agent with cluster-pool IPAM|@D@/cilium-status.txt --config @D@/cilium-config.txt
kpr-status|cilium-status.txt|"Error: unable to reach the agent\n"|2|E_KPR_STATUS_UNKNOWN|REJECT a status capture with no KubeProxyReplacement line, as could not check|@D@/cilium-status.txt --config @D@/cilium-config.txt
CASES
finish
