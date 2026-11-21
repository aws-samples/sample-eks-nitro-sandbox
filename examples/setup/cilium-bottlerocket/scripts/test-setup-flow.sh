#!/usr/bin/env bash
# test-setup-flow.sh: proves the inline guards of setup.sh and test.sh both ways, and the probe
# guards of scripts/common.sh, in the REAL scripts, run with the stub commands first on PATH.
# setup.sh runs one stage at a time: a state file with STAGE_DONE=<the stage before> resumes the
# run (RUN_ID=r1), and --stop-after ends it after the stage under test. The AMI build command is
# the CB_BUILD_AMI_CMD hook, a stub here (scripts/test-packer-build.sh proves the real one).
#   setup.sh preflight     E_AMI_TOOLS E_ENCLAVE_TYPE
#   setup.sh cluster       E_SUBNET_READ E_ADDON_READ E_CNI_PRESENT
#   setup.sh cilium        E_POD_IDENTITY
#   setup.sh system-node   E_NODE_READ E_NODE_COUNT E_NAMESPACE E_NAMESPACE_OWNER (and E_PROBE)
#   setup.sh ami           E_AMI_BUILD
#   setup.sh sandbox-node  E_CILIUM_AGENT
#   test.sh                E_RUN_STAGE
#   common.sh probe_*      E_PROBE
#
#   examples/setup/cilium-bottlerocket/scripts/test-setup-flow.sh
source "$(dirname "$0")/testlib/harness.sh"
SETUP="$SAMPLE_DIR_REAL/setup.sh"
need_file "$SETUP" "every setup.sh case" || finish
export CB_WAIT_TRIES=2
RD="$CB_RUN_DIR/runs/r1"
G_NODE="$WORK/node-fixtures"; python3 "$TESTLIB/fixture_node.py" "$G_NODE"

# A stub for the AMI build command: check-tools and build exit with $AMI_STUB_TOOLS_RC and
# $AMI_STUB_BUILD_RC; a build that exits 0 records AMI_BUILD_RESULT=ok unless AMI_STUB_NO_RESULT=1.
cat > "$WORK/bin/ami-build-stub" <<'STUB'
#!/bin/bash
case "$1" in
  check-tools) exit "${AMI_STUB_TOOLS_RC:-0}" ;;
  build)
    rc="${AMI_STUB_BUILD_RC:-0}"
    if [[ "$rc" == 0 && "${AMI_STUB_NO_RESULT:-}" != 1 ]]; then
      # The keys the real build records (scripts/10-build-ami-packer.sh), for an AMI that ami_world puts
      # in the world and a builder whose parts are all gone.
      f="$CB_RUN_DIR/runs/$RUN_ID/state.env"
      printf '%s\n' BUILDER_INSTANCE_ID=i-0fb00000000000009 BUILDER_VOLUME_IDS=vol-0fb00000000000091,vol-0fb00000000000092 \
        BUILDER_SG_ID=sg-0fb00000000000009 BUILDER_ROLE_NAME=cb-offline-test-$RUN_ID-builder \
        BUILDER_PROFILE_NAME=cb-offline-test-$RUN_ID-builder SANDBOX_AMI_ID=ami-0fb00000000000001 \
        SANDBOX_AMI_SNAPSHOT_IDS=snap-0fb00000000000001,snap-0fb00000000000002 AMI_BUILD_RESULT=ok >> "$f"
    fi
    exit "$rc" ;;
esac
exit 97
STUB
chmod 0755 "$WORK/bin/ami-build-stub"
export CB_BUILD_AMI_CMD="$WORK/bin/ami-build-stub"

# setup <log> [args...]: the real setup.sh; sets RC.
setup() { local log="$1"; shift; run_real "$log" bash "$SETUP" "$@"; }
# snap <name> / restore <name>: the world, the run folder and the local config after a stage
# that passed, so each case of the next stage starts from what the real stage left.
snap() {
  cp "$FAKE_STATE" "$WORK/snap-$1.json"; cp "$CB_LOCAL_CONFIG" "$WORK/snap-$1.env"
  rm -rf "$WORK/snap-$1.run"; cp -a "$CB_RUN_DIR" "$WORK/snap-$1.run"
}
restore() {
  cp "$WORK/snap-$1.json" "$FAKE_STATE"; cp "$WORK/snap-$1.env" "$CB_LOCAL_CONFIG"
  rm -rf "$CB_RUN_DIR"; cp -a "$WORK/snap-$1.run" "$CB_RUN_DIR"
  : > "$FAKE_LOG"; rm -f "$FAKE_STATE.failcounts"; unset FAKE_FAIL
  RUN_ID="$(cat "$CB_RUN_DIR/current-run")"; export RUN_ID
  RD="$CB_RUN_DIR/runs/$RUN_ID"
}
# stage <name> <snapshot to start from> <log>: run setup.sh for that one stage.
stage() { restore "$2"; setup "$3" --stop-after "$1"; }

echo "== 1/4 preflight ===================================================================="
entry setup.sh
world_reset; unset RUN_ID
setup "$WORK/pre.log" --stop-after preflight
check "ACCEPT preflight: the AMI tools pass, the sandbox instance type supports Nitro Enclaves" 0 "$RC" "$WORK/pre.log" '^Stopped after stage preflight\.'
cover accept E_AMI_TOOLS E_ENCLAVE_TYPE
snap preflight
# The run records SANDBOX_SLOTS once, and each run adds one source.log line.
restore preflight
HEAD_COMMIT="$(git -C "$SAMPLE_DIR_REAL" rev-parse HEAD)"
[[ "$(grep -c '^SANDBOX_SLOTS=58$' "$RD/state.env")" == 1 && "$(grep -c . "$RD/source.log")" == 1 ]] \
  && grep -Eqx "time=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z stage_done= commit=$HEAD_COMMIT dirty=(yes|no)" "$RD/source.log"
check "  ... the new run records SANDBOX_SLOTS=58, and source.log has one line with the checkout's HEAD commit" 0 $? "$RD/source.log"
world_reset; unset RUN_ID
AMI_STUB_TOOLS_RC=1 setup "$WORK/pre-tools.log" --stop-after preflight
check "REJECT preflight when Packer or its plugin fails the pin and signature check" 1 "$RC" "$WORK/pre-tools.log" '^ERROR: E_AMI_TOOLS: '
world_reset; unset RUN_ID; config_set 'SANDBOX_INSTANCE_TYPE="m8i.large"'
setup "$WORK/pre-enclave.log" --stop-after preflight
check "REJECT a sandbox instance type without Nitro Enclaves support (m8i.large)" 1 "$RC" "$WORK/pre-enclave.log" '^ERROR: E_ENCLAVE_TYPE: m8i.large does not support Nitro Enclaves'
world_reset; unset RUN_ID
FAKE_FAIL='aws|ec2 describe-instance-types||RequestLimitExceeded' setup "$WORK/pre-enclave-read.log" --stop-after preflight
check "REJECT preflight when the instance type cannot be read" 1 "$RC" "$WORK/pre-enclave-read.log" '^ERROR: E_ENCLAVE_TYPE: could not read'

echo "== 2/4 cluster ======================================================================"
stage cluster preflight "$WORK/cl.log"
check "ACCEPT the cluster stage: private subnets read, no vpc-cni or kube-proxy add-on, no aws-node or kube-proxy DaemonSet" 0 "$RC" "$WORK/cl.log" '^Stopped after stage cluster\.'
cover accept E_SUBNET_READ E_ADDON_READ E_CNI_PRESENT E_SANDBOX_SLOTS E_CLUSTER_CREATE E_KUBECONFIG
[[ "$(grep -c . "$RD/source.log")" == 2 ]] && grep -Eq "^time=.* stage_done=preflight commit=$HEAD_COMMIT dirty=(yes|no)$" "$RD/source.log"
check "  ... and the resumed run adds a second source.log line (stage_done=preflight)" 0 $? "$RD/source.log"
snap cluster
restore preflight; config_set 'SANDBOX_SLOTS="57"'
setup "$WORK/cl-slots.log" --stop-after cluster
check "REJECT a resume whose config has SANDBOX_SLOTS=57 when the run recorded 58" 1 "$RC" "$WORK/cl-slots.log" \
  '^ERROR: E_SANDBOX_SLOTS: run .* uses SANDBOX_SLOTS=58, but the config has SANDBOX_SLOTS=57; restore 58 in the config, or start a new run$'
[[ "$(count_calls eksctl)" == 0 ]]; check "  ... before any eksctl call" 0 $? "$WORK/cl-slots.log"
restore preflight
FAKE_FAIL='eksctl|create cluster||AlreadyExistsException' setup "$WORK/cl-create.log" --stop-after cluster
check "REJECT a failed eksctl create cluster" 1 "$RC" "$WORK/cl-create.log" '^ERROR: E_CLUSTER_CREATE: eksctl create cluster failed; read the events of stack eksctl-cb-offline-test-cluster'
restore preflight
FAKE_FAIL='aws|eks update-kubeconfig||AccessDeniedException' setup "$WORK/cl-kubeconfig.log" --stop-after cluster
check "REJECT a kubeconfig of the run that cannot be written" 1 "$RC" "$WORK/cl-kubeconfig.log" '^ERROR: E_KUBECONFIG: could not write the kubeconfig of the run'
restore preflight
FAKE_FAIL='aws|ec2 describe-subnets||RequestLimitExceeded' setup "$WORK/cl-subnet.log" --stop-after cluster
check "REJECT the cluster stage when the subnets of the VPC cannot be read" 1 "$RC" "$WORK/cl-subnet.log" '^ERROR: E_SUBNET_READ: could not read the subnets of vpc-'
restore preflight; config_set 'AVAILABILITY_ZONES="us-west-2a us-west-2b"'
setup "$WORK/cl-zone.log" --stop-after cluster
check "REJECT the cluster stage when the first zone has no private subnet of the cluster VPC" 1 "$RC" "$WORK/cl-zone.log" '^ERROR: E_SUBNET_READ: no single private subnet in us-west-2a'
restore preflight
FAKE_FAIL='aws|eks list-addons||ServerException' setup "$WORK/cl-addon.log" --stop-after cluster
check "REJECT the cluster stage when the add-ons cannot be listed" 1 "$RC" "$WORK/cl-addon.log" '^ERROR: E_ADDON_READ: '
# The cluster exists (a resumed run): rewind the state to preflight and change the cluster.
rewind() { sed -i "s/^STAGE_DONE=.*/STAGE_DONE=$1/" "$RD/state.env"; }
restore cluster; rewind preflight
world_py 's["eks"]["addons"]["cb-offline-test/vpc-cni"] = {"addonName": "vpc-cni", "status": "ACTIVE", "tags": {}}'
setup "$WORK/cl-vpccni.log" --stop-after cluster
check "REJECT a cluster with the vpc-cni add-on" 1 "$RC" "$WORK/cl-vpccni.log" '^ERROR: E_CNI_PRESENT: cluster cb-offline-test has the vpc-cni or kube-proxy add-on'
restore cluster; rewind preflight
world_py 's["k8s"]["objects"]["daemonsets/kube-system/kube-proxy"] = {"apiVersion": "apps/v1", "kind": "DaemonSet", "metadata": {"name": "kube-proxy", "namespace": "kube-system"}}'
setup "$WORK/cl-kp.log" --stop-after cluster
check "REJECT a cluster whose kube-system has a kube-proxy DaemonSet" 1 "$RC" "$WORK/cl-kp.log" '^ERROR: E_CNI_PRESENT: kube-system has daemonset'
restore cluster; rewind preflight
FAKE_FAIL='kubectl|get daemonset|aws-node|InternalError' setup "$WORK/cl-dsread.log" --stop-after cluster
check "REJECT the cluster stage when the kube-system DaemonSets cannot be read" 1 "$RC" "$WORK/cl-dsread.log" '^ERROR: E_CNI_PRESENT: could not read the DaemonSets of kube-system'
restore cluster; rewind preflight
setup "$WORK/cl-resume.log" --stop-after cluster
check "ACCEPT a resumed cluster stage whose cluster exists: it waits for ACTIVE and goes on" 0 "$RC" "$WORK/cl-resume.log" '^Stopped after stage cluster\.'
cover accept E_CLUSTER_STATE
[[ "$(count_calls eksctl 'create cluster')" == 0 ]]; check "  ... with no eksctl create cluster" 0 $? "$WORK/cl-resume.log"
restore cluster; rewind preflight
FAKE_FAIL='aws|eks wait cluster-active||WaiterMaxAttempts' setup "$WORK/cl-state.log" --stop-after cluster
check "REJECT a resumed cluster stage whose cluster does not become ACTIVE" 1 "$RC" "$WORK/cl-state.log" '^ERROR: E_CLUSTER_STATE: cluster cb-offline-test did not become ACTIVE$'

echo "== 3/4 cilium ======================================================================="
stage cilium cluster "$WORK/ci.log"
check "ACCEPT the cilium stage: exactly one Pod Identity association, the operator role, Cilium installed" 0 "$RC" "$WORK/ci.log" '^Stopped after stage cilium\.'
cover accept E_POD_IDENTITY
snap cilium
# An association of kube-system/cilium-operator that is already there is adopted only when it and
# its role carry the run's tags and the role trusts only EKS Pod Identity. adopt_world <python>:
# the stage resumes after cluster with the association and role of the stage above, changed by
# <python> (a = the association, r = the role, st = its trust statement), and nothing recorded.
adopt_world() {
  restore cilium; rewind cluster; sed -i '/^POD_IDENTITY_ASSOCIATION_ID=/d' "$RD/state.env"
  world_py "a = list(s['eks']['pod_identity'].values())[0]; r = s['iam']['roles']['cb-offline-test-cilium-operator']
st = r['Trust']['Statement'][0]
$1"
}
adopt_world 'pass'
setup "$WORK/ci-adopt.log" --stop-after cilium
check "ACCEPT the cilium stage with this run's association and role already there" 0 "$RC" "$WORK/ci-adopt.log" '^Stopped after stage cilium\.'
[[ "$(count_calls eksctl 'create podidentityassociation')" == 0 ]] && grep -q '^POD_IDENTITY_ASSOCIATION_ID=a-' "$RD/state.env"
check "  ... adopted: no second eksctl create podidentityassociation, the association recorded" 0 $? "$WORK/ci-adopt.log"
while IFS='|' read -r code rx why; do
  [[ -n "$code" ]] || continue
  adopt_world "$code"
  setup "$WORK/ci-adopt-bad.log" --stop-after cilium
  check "$why" 1 "$RC" "$WORK/ci-adopt-bad.log" "^ERROR: E_OPERATOR_ROLE: $rx"
  ! grep -q '^POD_IDENTITY_ASSOCIATION_ID=' "$RD/state.env" && [[ "$(count_calls helm)" == 0 ]]
  check "  ... before the association is recorded and before any helm call" 0 $? "$WORK/ci-adopt-bad.log"
done <<'CASES'
a['tags'] = {}|Pod Identity association a-[a-z0-9]+ is not tagged ManagedBy=cilium-bottlerocket-sample RunId=|REJECT the cilium stage when the association of kube-system/cilium-operator has no tags
a['tags']['RunId'] = 'r2'|Pod Identity association a-[a-z0-9]+ is not tagged ManagedBy=cilium-bottlerocket-sample RunId=|REJECT the cilium stage when the association of kube-system/cilium-operator is of run r2
r['Tags'] = []|operator role cb-offline-test-cilium-operator is not tagged ManagedBy=cilium-bottlerocket-sample RunId=|REJECT the cilium stage when the operator role has no tags
st['Principal'] = {'Service': ['pods.eks.amazonaws.com', 'ec2.amazonaws.com']}|operator role cb-offline-test-cilium-operator trust: the statement is .*'ec2\.amazonaws\.com'.*, want only Effect Allow|REJECT the cilium stage when EC2 can assume the operator role too
CASES
restore cluster
world_py 's["eks"]["pod_identity"]["a-other00000000001"] = {"clusterName": "cb-offline-test", "namespace": "kube-system", "serviceAccount": "cilium-operator", "tags": {}, "roleArn": "arn:aws:iam::111122223333:role/someone-else"}
s["eks"]["pod_identity"]["a-other00000000002"] = dict(s["eks"]["pod_identity"]["a-other00000000001"])'
setup "$WORK/ci-two.log" --stop-after cilium
check "REJECT the cilium stage when kube-system/cilium-operator has two Pod Identity associations" 1 "$RC" "$WORK/ci-two.log" '^ERROR: E_POD_IDENTITY: expected one Pod Identity association'
restore cluster
FAKE_FAIL='helm|upgrade||Timeout' setup "$WORK/ci-helm.log" --stop-after cilium
check "REJECT the cilium stage when the Helm install of Cilium fails" 1 "$RC" "$WORK/ci-helm.log" '^ERROR: E_CILIUM_INSTALL: helm upgrade --install of Cilium [0-9.]+ failed$'
entry setup.sh; restore cluster; setup "$WORK/ci-again.log" --stop-after cilium
check "ACCEPT the Helm install of Cilium on the cilium stage" 0 "$RC" "$WORK/ci-again.log" '^Stopped after stage cilium\.'
cover accept E_CILIUM_INSTALL

echo "== --stop-after on a resumed run ================================"
# The accept side is every stage case above: --stop-after names the stage after STAGE_DONE.
restore cluster
setup "$WORK/sa-next.log" --stop-after cilium
check "ACCEPT --stop-after cilium on a run that finished cluster" 0 "$RC" "$WORK/sa-next.log" '^Stopped after stage cilium\.'
cover accept E_USAGE
restore cluster
setup "$WORK/sa-same.log" --stop-after cluster
check "REJECT --stop-after cluster on a run that already finished cluster (it would go on into the next stages)" 1 "$RC" "$WORK/sa-same.log" '^ERROR: E_USAGE: run .* already finished stage cluster \(STAGE_DONE=cluster\); --stop-after must name a later stage$'
[[ "$(count_calls eksctl)" == 0 && "$(count_calls helm)" == 0 ]]
check "  ... and nothing ran: no eksctl or helm call" 0 $? "$WORK/sa-same.log"
restore cluster
setup "$WORK/sa-earlier.log" --stop-after preflight
check "REJECT --stop-after preflight on a run that finished cluster" 1 "$RC" "$WORK/sa-earlier.log" '^ERROR: E_USAGE: run .* already finished stage preflight'
restore cluster
setup "$WORK/sa-unknown.log" --stop-after nodes
check "REJECT --stop-after with a stage that does not exist" 1 "$RC" "$WORK/sa-unknown.log" '^ERROR: E_USAGE: --stop-after needs one of: preflight cluster cilium system-node ami sandbox-node node-checks workloads$'
restore cluster
setup "$WORK/sa-arg.log" --force
check "REJECT an unknown argument" 1 "$RC" "$WORK/sa-arg.log" '^ERROR: E_USAGE: usage: \./setup\.sh \[--stop-after <stage>\]$'

echo "== 4/4 system-node, ami, sandbox-node ================================================"
SYS_NODE=ip-10-0-1-10.us-west-2.compute.internal
SBX_NODE=ip-10-0-2-20.us-west-2.compute.internal
# add_node <group> <name> <os image>: the node of a node group, registered and Ready.
add_node() {
  world_py "s['k8s']['objects']['nodes/-/$2'] = {'apiVersion': 'v1', 'kind': 'Node', 'metadata': {'name': '$2', 'labels': {'eks.amazonaws.com/nodegroup': '$1', 'kubernetes.io/os': 'linux'}}, 'status': {'conditions': [{'type': 'Ready', 'status': 'True'}], 'nodeInfo': {'osImage': '$3', 'kubeletVersion': 'v1.36.4-eks-fake', 'architecture': 'amd64', 'kernelVersion': '6.18.62'}, 'capacity': {'pods': '110', 'eks.amazonaws.com/nitro-sandbox': '0'}, 'allocatable': {'pods': '110', 'eks.amazonaws.com/nitro-sandbox': '0'}}}"
}
# probe_answers <group>: what the probe pod of that group prints for each capture command.
probe_answers() {
  world_py "s['k8s']['exec'] = [{'target': 'cb-probe-$1-$RUN_ID', 'match': 'wc -c', 'stdout': 'BTF_BYTES=5242880\n'}, {'target': 'cb-probe-$1-$RUN_ID', 'match': '', 'stdout': ''}]"
}
sysnode_world() { restore cilium; add_node system "$SYS_NODE" 'Bottlerocket OS 1.70.0 (aws-k8s-1.36)'; probe_answers system; }
sysnode_world
setup "$WORK/sn.log" --stop-after system-node
check "ACCEPT the system-node stage: one node, the namespace created, the probe pod started and captured" 0 "$RC" "$WORK/sn.log" '^Stopped after stage system-node\.'
cover accept E_NODE_READ E_NODE_COUNT E_NAMESPACE E_NAMESPACE_OWNER E_PROBE E_NODE_READY E_CILIUM_ROLLOUT
[[ "$(count_calls eksctl 'create nodegroup')" == 1 ]]
check "  ... with exactly one eksctl create nodegroup, for the node group EKS did not have" 0 $? "$WORK/sn.log"
snap system-node
restore cilium
setup "$WORK/sn-none.log" --stop-after system-node
check "REJECT the system-node stage when no system node registers" 1 "$RC" "$WORK/sn-none.log" '^ERROR: E_NODE_COUNT: no system node registered'
sysnode_world; add_node system ip-10-0-1-11.us-west-2.compute.internal 'Bottlerocket OS 1.70.0 (aws-k8s-1.36)'
setup "$WORK/sn-two.log" --stop-after system-node
check "REJECT a system node group with two nodes" 1 "$RC" "$WORK/sn-two.log" '^ERROR: E_NODE_COUNT: node group system has 2 nodes, want exactly 1'
# max-pods of each node group, from one ec2 describe-instance-types read: the ENI formula ENIs x
# (IPv4 per ENI - 1) + 2, capped at 110 below 30 vCPUs and 250 from 30, recorded with its formula
# and ceiling, and checked against the system node's capacity pods.
# state_once <file> <KEY=value>...: each line is in the run state exactly once.
state_once() { local f="$1" kv; shift; for kv in "$@"; do [[ "$(grep -cx "$kv" "$f")" == 1 ]] || return 1; done; }
SN_STATE="$WORK/snap-system-node.run/runs/$RUN_ID/state.env"
grep -qx 'max-pods of the system node: 110 (m8i.xlarge, 4 vCPUs: ENI formula 118, ceiling 110)' "$WORK/sn.log" \
  && grep -qx 'max-pods of the sandbox node: 110 (m8i.xlarge, 4 vCPUs: ENI formula 118, ceiling 110)' "$WORK/sn.log" \
  && state_once "$SN_STATE" MAX_PODS_SYSTEM=110 MAX_PODS_FORMULA_SYSTEM=118 MAX_PODS_CEILING_SYSTEM=110 \
    MAX_PODS_SANDBOX=110 MAX_PODS_FORMULA_SANDBOX=118 MAX_PODS_CEILING_SANDBOX=110
check "ACCEPT max-pods of both node groups from m8i.xlarge (4 vCPUs, 4 ENIs x 30 IPv4): ENI formula 118, ceiling 110, max-pods 110, each recorded once in the run state" 0 $? "$WORK/sn.log"
cover accept E_MAX_PODS E_DERIVE_MAX_PODS
while IFS='|' read -r type pods line why; do
  [[ -n "$type" ]] || continue
  sysnode_world; sed -i '/^MAX_PODS_/d' "$RD/state.env"; config_set "SYSTEM_INSTANCE_TYPE=\"$type\""
  world_py "s['k8s']['objects']['nodes/-/$SYS_NODE']['status']['capacity']['pods'] = '$pods'"
  setup "$WORK/mp-shape.log" --stop-after system-node
  grep -qx "max-pods of the system node: $pods ($type, $line)" "$WORK/mp-shape.log" && state_once "$RD/state.env" "MAX_PODS_SYSTEM=$pods"
  check "$why" 0 $(( RC + $? )) "$WORK/mp-shape.log" '^Stopped after stage system-node\.'
done <<'CASES'
m8i.4xlarge|110|16 vCPUs: ENI formula 234, ceiling 110|ACCEPT m8i.4xlarge (16 vCPUs): the ENI formula 234 capped at the ceiling 110, equal to the node's capacity pods
m8i.large|29|2 vCPUs: ENI formula 29, ceiling 110|ACCEPT m8i.large (2 vCPUs): the ENI formula 29 is under the ceiling 110, so max-pods is 29
m8i.16xlarge|250|64 vCPUs: ENI formula 737, ceiling 250|ACCEPT m8i.16xlarge (64 vCPUs): the ENI formula 737 capped at the ceiling 250
CASES
sysnode_world; world_py "s['k8s']['objects']['nodes/-/$SYS_NODE']['status']['capacity']['pods'] = '118'"
setup "$WORK/mp-ceiling.log" --stop-after system-node
check "REJECT a system node whose capacity pods (118, the ENI formula alone) is above the ceiling 110" 1 "$RC" "$WORK/mp-ceiling.log" '^ERROR: E_MAX_PODS: the derived max-pods is 110 \(ENI formula 118, ceiling 110\), but node capacity pods=118, above the ceiling 110$'
sysnode_world; world_py "s['k8s']['objects']['nodes/-/$SYS_NODE']['status']['capacity']['pods'] = '58'"
setup "$WORK/mp-node.log" --stop-after system-node
check "REJECT a system node whose capacity pods (58) is below the derived max-pods (110)" 1 "$RC" "$WORK/mp-node.log" '^ERROR: E_MAX_PODS: the derived max-pods is 110 \(ENI formula 118, ceiling 110\), but node capacity pods=58$'
sysnode_world; world_py "s['instance_types']['m8i.xlarge'].pop('VCpuInfo')"
setup "$WORK/mp-vcpu.log" --stop-after system-node
grep -qx 'ERROR: E_DERIVE_MAX_PODS_UNKNOWN: could not check: VCpuInfo.DefaultVCpus is None, not a number' "$WORK/mp-vcpu.log"
check "REJECT an instance type with no VCpuInfo: setup.sh stops before the system node group" 1 $(( RC + $? )) "$WORK/mp-vcpu.log" '^ERROR: E_MAX_PODS: could not derive max-pods of the system node from m8i\.xlarge'
[[ "$(count_calls eksctl 'create nodegroup')" == 0 ]]; check "  ... and no node group was created" 0 $? "$WORK/mp-vcpu.log"
sysnode_world; world_py "s['instance_types']['m8i.xlarge'].pop('NetworkInfo')"
setup "$WORK/mp-missing.log" --stop-after system-node
check "REJECT an instance type with no NetworkInfo: setup.sh stops before the system node group" 1 "$RC" "$WORK/mp-missing.log" '^ERROR: E_MAX_PODS: could not derive max-pods of the system node from m8i\.xlarge'
[[ "$(count_calls eksctl 'create nodegroup')" == 0 ]]; check "  ... and no node group was created" 0 $? "$WORK/mp-missing.log"
sysnode_world; world_py "s['instance_types']['m8i.xlarge']['NetworkInfo'].pop('Ipv4AddressesPerInterface')"
setup "$WORK/mp-field.log" --stop-after system-node
check "REJECT a NetworkInfo with no Ipv4AddressesPerInterface" 1 "$RC" "$WORK/mp-field.log" '^ERROR: E_MAX_PODS: could not derive max-pods of the system node from m8i\.xlarge'
sysnode_world; world_py "s['instance_types']['m8i.xlarge']['NetworkInfo']['MaximumNetworkInterfaces'] = 0"
setup "$WORK/mp-zero.log" --stop-after system-node
grep -qx 'ERROR: E_DERIVE_MAX_PODS: NetworkInfo.MaximumNetworkInterfaces is 0, want more than 0' "$WORK/mp-zero.log"
check "REJECT MaximumNetworkInterfaces 0" 1 $(( RC + $? )) "$WORK/mp-zero.log" '^ERROR: E_MAX_PODS: could not derive max-pods of the system node from m8i\.xlarge'
sysnode_world
FAKE_FAIL='aws|ec2 describe-instance-types||UnauthorizedOperation' setup "$WORK/mp-read.log" --stop-after system-node
check "REJECT a describe-instance-types read that fails" 1 "$RC" "$WORK/mp-read.log" '^ERROR: E_MAX_PODS: could not derive max-pods of the system node from m8i\.xlarge'
[[ "$(count_calls eksctl 'create nodegroup')" == 0 ]]; check "  ... and no node group was created" 0 $? "$WORK/mp-read.log"
for group in SYSTEM SANDBOX; do
  sysnode_world; config_set "${group}_INSTANCE_TYPE=\"m8i.16xlarge\""
  setup "$WORK/mp-changed.log" --stop-after system-node
  check "REJECT a resume whose $group instance type gives another max-pods (250) than the run recorded (110)" 1 "$RC" "$WORK/mp-changed.log" \
    "^ERROR: E_MAX_PODS: run $RUN_ID uses max-pods 110 on the ${group,,} node, but m8i\\.16xlarge gives 250; "
  state_once "$RD/state.env" "MAX_PODS_$group=110" "MAX_PODS_FORMULA_$group=118" "MAX_PODS_CEILING_$group=110"
  check "  ... and the run state still has MAX_PODS_$group=110, its formula 118 and ceiling 110, once each" 0 $? "$RD/state.env"
done
# A resume whose instance type gives the same max-pods goes on: m8i.4xlarge also gives 110.
sysnode_world; config_set 'SANDBOX_INSTANCE_TYPE="m8i.4xlarge"'
setup "$WORK/mp-same.log" --stop-after system-node
grep -qx 'max-pods of the sandbox node: 110 (m8i.4xlarge, 16 vCPUs: ENI formula 234, ceiling 110)' "$WORK/mp-same.log"
check "ACCEPT a resume whose sandbox instance type (m8i.4xlarge) gives the recorded max-pods 110" 0 $(( RC + $? )) "$WORK/mp-same.log" '^Stopped after stage system-node\.'
sysnode_world
FAKE_FAIL='kubectl|get nodes|jsonpath|InternalError' setup "$WORK/sn-read.log" --stop-after system-node
check "REJECT the system-node stage when the nodes of the group cannot be listed" 1 "$RC" "$WORK/sn-read.log" '^ERROR: E_NODE_READ: could not list the nodes of node group system'
sysnode_world
world_py 's["k8s"]["objects"]["namespaces/-/cilium-bottlerocket-demo"] = {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "cilium-bottlerocket-demo", "labels": {"team": "someone-else"}}}'
setup "$WORK/sn-nsowner.log" --stop-after system-node
check "REJECT a namespace cilium-bottlerocket-demo that exists without the sample's label" 1 "$RC" "$WORK/sn-nsowner.log" '^ERROR: E_NAMESPACE_OWNER: namespace cilium-bottlerocket-demo exists without'
sysnode_world
FAKE_FAIL='kubectl|create||Forbidden' setup "$WORK/sn-nscreate.log" --stop-after system-node
check "REJECT the system-node stage when the namespace cannot be created" 1 "$RC" "$WORK/sn-nscreate.log" '^ERROR: E_NAMESPACE: could not create namespace cilium-bottlerocket-demo'
sysnode_world
FAKE_FAIL='kubectl|get namespace||InternalError' setup "$WORK/sn-nsread.log" --stop-after system-node
check "REJECT the system-node stage when the namespace cannot be read" 1 "$RC" "$WORK/sn-nsread.log" '^ERROR: E_NAMESPACE: could not read namespace cilium-bottlerocket-demo'
sysnode_world
world_py 's["k8s"]["objects"]["namespaces/-/cilium-bottlerocket-demo"] = {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "cilium-bottlerocket-demo", "labels": {"app.kubernetes.io/part-of": "cilium-bottlerocket-sample"}}}'
FAKE_FAIL='kubectl|create||Forbidden' setup "$WORK/sn-probecreate.log" --stop-after system-node
check "REJECT the system-node stage when the probe pod cannot be created" 1 "$RC" "$WORK/sn-probecreate.log" '^ERROR: E_PROBE: could not create the probe pod cb-probe-system-'
sysnode_world
FAKE_FAIL="kubectl|wait pod/cb-probe-system-$RUN_ID||Timeout" setup "$WORK/sn-probewait.log" --stop-after system-node
check "REJECT the system-node stage when the probe pod does not become Ready" 1 "$RC" "$WORK/sn-probewait.log" '^ERROR: E_PROBE: the probe pod cb-probe-system-.* did not become Ready'
sysnode_world; mkdir -p "$RD/evidence"; : > "$RD/evidence/probe-system"
setup "$WORK/sn-probedir.log" --stop-after system-node
check "REJECT the system-node stage when the evidence folder of the probe cannot be created" 1 "$RC" "$WORK/sn-probedir.log" '^ERROR: E_PROBE: could not create .*/evidence/probe-system'
# The EXIT trap deletes the probe pod that the stage started, by exact name.
probe_gone() { # probe_gone <pod>: the pod is not in the world, and one delete named it exactly
  [[ "$(world_get "'pods/cilium-bottlerocket-demo/$1' in s['k8s']['objects']")" == false ]] \
    && python3 -c 'import json, sys
hits = [e for e in map(json.loads, open(sys.argv[1])) if e["tool"] == "kubectl" and e["call"] == "delete pod"]
sys.exit(0 if any(sys.argv[2] in e["argv"] for e in hits) and all(sys.argv[2] in e["argv"] for e in hits) else 1)' "$FAKE_LOG" "$1"
}
probe_gone "cb-probe-system-$RUN_ID"
check "  ... and the exit trap deleted the started probe pod cb-probe-system-<run> by its exact name" 0 $? "$WORK/sn-probedir.log"
sysnode_world
FAKE_FAIL="kubectl|wait pod/cb-probe-system-$RUN_ID||Timeout" setup "$WORK/sn-probewait2.log" --stop-after system-node
probe_gone "cb-probe-system-$RUN_ID"
check "  ... and a probe pod that never became Ready is deleted by the exit trap too" 0 $? "$WORK/sn-probewait2.log"
# ensure_nodegroup. The accept case above found no node group and created
# it once; here the stage resumes (STAGE_DONE=cilium) with the system node group already there.
ngw() { # ngw <python on ng>: the system-node world rewound to cilium, the system node group changed
  restore system-node; rewind cilium
  world_py "ng = s['eks']['nodegroups']['cb-offline-test/system']; $1"
}
ngw 'ng["status"] = "ACTIVE"'
setup "$WORK/ng-active.log" --stop-after system-node
check "ACCEPT a system node group that is ACTIVE: no create, the stage goes on" 0 "$RC" "$WORK/ng-active.log" '^Stopped after stage system-node\.'
cover accept E_NODEGROUP_READ E_NODEGROUP_STATE E_NODEGROUP_CREATE
[[ "$(count_calls eksctl 'create nodegroup')" == 0 ]]; check "  ... and eksctl create nodegroup did not run" 0 $? "$WORK/ng-active.log"
ngw 'ng["Statuses"] = ["CREATING", "CREATING", "ACTIVE"]'
setup "$WORK/ng-creating.log" --stop-after system-node
check "ACCEPT a system node group that is CREATING, then ACTIVE: it waits, with no create" 0 "$RC" "$WORK/ng-creating.log" '^Stopped after stage system-node\.'
[[ "$(count_calls eksctl 'create nodegroup')" == 0 ]]; check "  ... and eksctl create nodegroup did not run" 0 $? "$WORK/ng-creating.log"
for st in CREATE_FAILED DEGRADED DELETING DELETE_FAILED; do
  ngw "ng['status'] = '$st'"
  setup "$WORK/ng-$st.log" --stop-after system-node
  check "REJECT a system node group that is $st: no create over it" 1 "$RC" "$WORK/ng-$st.log" "^ERROR: E_NODEGROUP_STATE: node group system is $st; "
  [[ "$(count_calls eksctl 'create nodegroup')" == 0 ]]; check "  ... and eksctl create nodegroup did not run ($st)" 0 $? "$WORK/ng-$st.log"
done
ngw 'ng["status"] = "CREATING"'
setup "$WORK/ng-stuck.log" --stop-after system-node
check "REJECT a system node group that stays CREATING" 1 "$RC" "$WORK/ng-stuck.log" '^ERROR: E_NODEGROUP_STATE: node group system did not become ACTIVE \(status CREATING\)$'
# A node group of that name is used only when it is this run's and as rendered: render-nodegroup
# reads it first, and a node group that is not stops the stage before any change in the cluster.
# cluster_changes: the calls of the case that change the cluster.
cluster_changes() {
  calls | grep -c -E '^[0-9]+ (eksctl |helm |kubectl (create|apply|delete|patch|label|annotate)|aws eks (create|delete|tag|untag|update-nodegroup))' || true
}
while IFS='|' read -r code rx why; do
  [[ -n "$code" ]] || continue
  ngw "ng['status'] = 'ACTIVE'; $code"
  setup "$WORK/ng-reuse.log" --stop-after system-node
  check "REJECT an ACTIVE system node group $why" 1 "$RC" "$WORK/ng-reuse.log" \
    "^ERROR: E_RENDER_NODEGROUP: node group system exists and is not the one this run renders: .*$rx"
  [[ "$(cluster_changes)" == 0 ]]; check "  ... before any change in the cluster: no eksctl, helm or kubectl change" 0 $? "$WORK/ng-reuse.log"
done <<'CASES'
ng['tags'] = {'team': 'someone-else'}|tags \{'team': 'someone-else'\} are not ManagedBy=cilium-bottlerocket-sample RunId=|with another owner's tags
ng['tags']['RunId'] = 'r2'|tags .*'RunId': 'r2'.* are not ManagedBy=cilium-bottlerocket-sample RunId=|of another run (RunId r2)
ng['launchTemplate']['id'] = 'lt-0fa00000000000999'|launch template and version \('lt-0fa00000000000999', '1'\), want \('lt-[0-9a-f]+', '1'\)|on another launch template
ng['launchTemplate']['version'] = '2'|launch template and version \('lt-[0-9a-f]+', '2'\), want \('lt-[0-9a-f]+', '1'\)|on version 2 of the run's launch template
ng['scalingConfig']['desiredSize'] = 2|min, max and desired size \(1, 1, 2\), want \(1, 1, 1\)|with two nodes
CASES
sysnode_world
FAKE_FAIL='aws|eks describe-nodegroup|system|ServiceUnavailableException' setup "$WORK/ng-render-read.log" --stop-after system-node
check "REJECT the system-node stage when render-nodegroup cannot read the node group, as could not check" 2 "$RC" "$WORK/ng-render-read.log" '^ERROR: E_RENDER_NODEGROUP_UNKNOWN: '
[[ "$(count_calls eksctl 'create nodegroup')" == 0 ]]; check "  ... and eksctl create nodegroup did not run" 0 $? "$WORK/ng-render-read.log"
sysnode_world
FAKE_FAIL='aws|eks describe-nodegroup|system|ServiceUnavailableException||1' setup "$WORK/ng-read.log" --stop-after system-node
check "REJECT a node group read that fails with another error than ResourceNotFoundException" 1 "$RC" "$WORK/ng-read.log" '^ERROR: E_NODEGROUP_READ: could not read node group system of cb-offline-test: '
[[ "$(count_calls eksctl 'create nodegroup')" == 0 ]]; check "  ... and eksctl create nodegroup did not run" 0 $? "$WORK/ng-read.log"
sysnode_world
FAKE_FAIL='eksctl|create nodegroup||ResourceLimitExceeded' setup "$WORK/ng-create.log" --stop-after system-node
check "REJECT a failed eksctl create nodegroup" 1 "$RC" "$WORK/ng-create.log" '^ERROR: E_NODEGROUP_CREATE: eksctl create nodegroup system failed; '
# The node and rollout waits of the system-node stage.
sysnode_world
FAKE_FAIL='kubectl|wait node||Timeout' setup "$WORK/sn-ready.log" --stop-after system-node
check "REJECT a system node that is not Ready" 1 "$RC" "$WORK/sn-ready.log" '^ERROR: E_NODE_READY: the system node is not Ready after 20 minutes$'
for what in 'daemonset/cilium|the Cilium agent DaemonSet' 'deployment/cilium-operator|the Cilium operator Deployment'; do
  sysnode_world
  FAKE_FAIL="kubectl|rollout status|${what%%|*}|Timeout" setup "$WORK/sn-rollout.log" --stop-after system-node
  check "REJECT ${what#*|} that does not roll out" 1 "$RC" "$WORK/sn-rollout.log" "^ERROR: E_CILIUM_ROLLOUT: ${what#*|} did not roll out\$"
done

# ami_world: the AMI and the two snapshots of a good build (fixture_aws_json.py), for this run.
python3 "$TESTLIB/fixture_aws_json.py" good "$WORK/aj"
ami_world() {
  world_py "
imgs = json.load(open('$WORK/aj/images.json'))['Images']; snaps = json.load(open('$WORK/aj/snapshots.json'))['Snapshots']
for o in imgs + snaps:
    for t in o.get('Tags', []):
        if t['Key'] == 'RunId': t['Value'] = '$RUN_ID'
for i in imgs:
    i['Name'] = i.get('Name', '').replace('-r1-', '-$RUN_ID-')
s['ec2']['images'] += imgs; s['ec2']['snapshots'] += snaps"
}
restore system-node; ami_world
setup "$WORK/ami.log" --stop-after ami
check "ACCEPT the ami stage: the build exits 0 and records AMI_BUILD_RESULT=ok, the AMI and the builder read back" 0 "$RC" "$WORK/ami.log" '^Stopped after stage ami\.'
cover accept E_AMI_BUILD
snap ami
restore system-node; ami_world
AMI_STUB_BUILD_RC=3 setup "$WORK/ami-fail.log" --stop-after ami
check "REJECT the ami stage when the build exits non-zero" 1 "$RC" "$WORK/ami-fail.log" '^ERROR: E_AMI_BUILD: the AMI build did not finish \(exit 3\)'
restore system-node; ami_world
AMI_STUB_NO_RESULT=1 setup "$WORK/ami-noresult.log" --stop-after ami
check "REJECT the ami stage when the build exits 0 without AMI_BUILD_RESULT=ok" 1 "$RC" "$WORK/ami-noresult.log" '^ERROR: E_AMI_BUILD: the AMI build exited 0 without AMI_BUILD_RESULT=ok'

# cilium_pod <node> <ready>: the Cilium agent pod on that node.
cilium_pod() {
  world_py "s['k8s']['objects']['pods/kube-system/cilium-$2'] = {'apiVersion': 'v1', 'kind': 'Pod', 'metadata': {'name': 'cilium-$2', 'namespace': 'kube-system', 'labels': {'k8s-app': 'cilium'}}, 'spec': {'nodeName': '$1'}, 'status': {'containerStatuses': [{'name': 'cilium-agent', 'ready': $2}]}}"
}
sbx_world() { restore ami; add_node sandbox "$SBX_NODE" 'Bottlerocket OS 1.70.0 (aws-k8s-1.36-nitro-sandbox)'; }
sbx_world; cilium_pod "$SBX_NODE" True
setup "$WORK/sbx.log" --stop-after sandbox-node
check "ACCEPT the sandbox-node stage: exactly one sandbox node, its Cilium agent Ready" 0 "$RC" "$WORK/sbx.log" '^Exactly one sandbox node joined: '
cover accept E_CILIUM_AGENT E_AMI_READ
snap sandbox-node
sbx_world; cilium_pod "$SBX_NODE" False
setup "$WORK/sbx-agent.log" --stop-after sandbox-node
check "REJECT the sandbox-node stage when the Cilium agent on the sandbox node is not Ready" 1 "$RC" "$WORK/sbx-agent.log" '^ERROR: E_CILIUM_AGENT: the Cilium agent on .* is not Ready'
restore ami
setup "$WORK/sbx-none.log" --stop-after sandbox-node
check "REJECT the sandbox-node stage when no sandbox node registers" 1 "$RC" "$WORK/sbx-none.log" '^ERROR: E_NODE_COUNT: no sandbox node registered'
sbx_world; cilium_pod "$SBX_NODE" True
FAKE_FAIL='aws|ec2 describe-images|ami-0fb00000000000001|RequestLimitExceeded' setup "$WORK/sbx-ami.log" --stop-after sandbox-node
check "REJECT the sandbox-node stage when the sandbox AMI cannot be read" 1 "$RC" "$WORK/sbx-ami.log" '^ERROR: E_AMI_READ: could not read the sandbox AMI ami-0fb00000000000001$'
sbx_world; cilium_pod "$SBX_NODE" True
FAKE_FAIL='kubectl|wait node||Timeout' setup "$WORK/sbx-ready.log" --stop-after sandbox-node
check "REJECT a sandbox node that is not Ready" 1 "$RC" "$WORK/sbx-ready.log" '^ERROR: E_NODE_READY: the sandbox node is not Ready after 20 minutes$'

echo "== node-checks and workloads ===================================="
# node-checks: the node read, then the kubelet configz through the API server proxy.
restore sandbox-node
setup "$WORK/nc-configz.log" --stop-after node-checks
check "REJECT the node-checks stage when the kubelet configz cannot be read" 1 "$RC" "$WORK/nc-configz.log" "^ERROR: E_CONFIGZ_READ: could not read the kubelet configz of $SBX_NODE\$"
restore sandbox-node
world_py "s['k8s']['raw'] = {'/api/v1/nodes/$SBX_NODE/proxy/configz': json.load(open('$G_NODE/configz.json'))}"
setup "$WORK/nc-configz-ok.log" --stop-after node-checks
[[ -s "$RD/configz-sandbox.json" ]] && ! grep -q 'E_CONFIGZ_READ' "$WORK/nc-configz-ok.log" && grep -q '^ERROR: ' "$WORK/nc-configz-ok.log"
check "ACCEPT a configz read: the stage writes configz-sandbox.json and goes on to the probe (it stops later, on the empty captures)" 0 $? "$WORK/nc-configz-ok.log"
cover accept E_CONFIGZ_READ
# workloads: from a run whose node checks are done (the state rewound past node-checks).
restore sandbox-node; rewind node-checks
setup "$WORK/wl.log"
check "ACCEPT the workloads stage: the RuntimeClass, the manifests applied, the pods Ready" 0 "$RC" "$WORK/wl.log" '^Run .* is ready\. Next: RUN_ID=.* \./test\.sh$'
cover accept E_WORKLOADS E_WORKLOADS_READY
restore sandbox-node; rewind node-checks
FAKE_FAIL='kubectl|apply||Forbidden' setup "$WORK/wl-apply.log"
check "REJECT the workloads stage when a manifest cannot be applied" 1 "$RC" "$WORK/wl-apply.log" '^ERROR: E_WORKLOADS: could not apply .*/deploy/[a-z-]+\.yaml$'
restore sandbox-node; rewind node-checks
FAKE_FAIL='kubectl|wait pod/cb-server||Timeout' setup "$WORK/wl-wait.log"
check "REJECT the workloads stage when the pods are not all Ready" 1 "$RC" "$WORK/wl-wait.log" '^ERROR: E_WORKLOADS_READY: the pods cb-server .* are not all Ready after 10 minutes$'

echo "== test.sh: the run must have finished setup ========================================="
entry test.sh
# The checks after the guard are proven by scripts/test-node-checks.sh and test-cluster-helper.sh;
# here the accept side is that test.sh passes the guard and starts its first step.
restore sandbox-node; rewind workloads
run_real "$WORK/t-ok.log" bash "$SAMPLE_DIR_REAL/test.sh"
grep -q '^=== 1\. the dedicated cluster and its CNI ===$' "$WORK/t-ok.log" && ! grep -q 'E_RUN_STAGE' "$WORK/t-ok.log"
check "ACCEPT test.sh on a run whose STAGE_DONE is workloads: it passes the guard and starts step 1" 0 $? "$WORK/t-ok.log"
cover accept E_RUN_STAGE
# Whatever test.sh's checks found on the fake cluster, its exit trap leaves
# no filler pod and no probe pod of the run behind, and each delete names one pod exactly.
python3 - "$FAKE_LOG" "$FAKE_STATE" "$RUN_ID" > "$WORK/t-pods.txt" <<'PY'
import json, re, sys
log, state, run = sys.argv[1:4]
calls = [json.loads(l) for l in open(log)]
made = sorted({o for e in calls if e["tool"] == "kubectl" and e["call"] == "create objects"
               for o in e.get("objects", []) if re.search(r"/cb-(filler-[0-9]+|probe-sandbox)-", o)})
left = sorted(k for k in json.load(open(state))["k8s"]["objects"] if re.search(r"/cb-(filler|probe)-", k))
dels = [e for e in calls if e["tool"] == "kubectl" and e["call"] == "delete pod"]
exact = all(any(re.fullmatch(rf"cb-(filler-[0-9]+|probe-[a-z]+)-{re.escape(run)}", a) for a in e["argv"]) for e in dels)
print("made:", made); print("left:", left); print("deletes:", len(dels), "exact:", exact)
sys.exit(0 if made and not left and exact else 1)
PY
check "  ... and its exit trap leaves no filler or probe pod of the run: each one it made is deleted by its exact name" 0 $? "$WORK/t-pods.txt"
# The filler loop of test.sh: at most 40 filler pods, and never more than the free pods of the
# derived max-pods (filler pods are ordinary pods). The fake CiliumNode never lists a second ENI,
# so the loop runs to its limit.
fillers_made() { # "1-<n>" when the filler pods created were cb-filler-1 to cb-filler-<n>, else the list
  python3 -c 'import json, re, sys
n = sorted({int(m.group(1)) for e in map(json.loads, open(sys.argv[1])) if e["tool"] == "kubectl" and e["call"] == "create objects"
            for o in e.get("objects", []) for m in [re.search(r"/cb-filler-([0-9]+)-", o)] if m})
print(f"1-{len(n)}" if n == list(range(1, len(n) + 1)) else n)' "$FAKE_LOG"
}
grep -q '^filler pods started: 40 (limit 40); ' "$WORK/t-ok.log" && [[ "$(fillers_made)" == 1-40 ]]
check "  ... with max-pods 110 it starts the cap of 40 filler pods, cb-filler-1 to cb-filler-40, and no 41st" 0 $? "$WORK/t-ok.log"
free_ok=0; lim=()
for mp in 30 31; do
  restore sandbox-node; rewind workloads; sed -i "s/^MAX_PODS_SANDBOX=.*/MAX_PODS_SANDBOX=$mp/" "$RD/state.env"
  run_real "$WORK/t-free-$mp.log" bash "$SAMPLE_DIR_REAL/test.sh"
  n="$(sed -nE 's/^filler pods started: ([0-9]+) \(limit \1\); .*/\1/p' "$WORK/t-free-$mp.log")"
  [[ -n "$n" && "$(fillers_made)" == "1-$n" ]] || free_ok=1
  lim+=("${n:-none}")
done
echo "filler limits with max-pods 30 and 31: ${lim[*]}" > "$WORK/t-free.txt"
((free_ok == 0 && lim[0] > 0 && lim[0] <= 30 && lim[1] == lim[0] + 1))
check "  ... under the cap, the limit is max-pods minus the pods on the node: max-pods 31 starts exactly one more than 30" 0 $? "$WORK/t-free.txt"
restore sandbox-node
run_real "$WORK/t-stage.log" bash "$SAMPLE_DIR_REAL/test.sh"
check "REJECT test.sh on a run that stopped after sandbox-node" 1 "$RC" "$WORK/t-stage.log" '^ERROR: E_RUN_STAGE: run .* has not finished setup \(STAGE_DONE=sandbox-node\)'
# test.sh limits its filler pods by the max-pods that setup.sh derived, so a run without it stops.
restore sandbox-node; rewind workloads; sed -i '/^MAX_PODS_SANDBOX=/d' "$RD/state.env"
run_real "$WORK/t-nomp.log" bash "$SAMPLE_DIR_REAL/test.sh"
check "REJECT test.sh on a run whose state has no derived MAX_PODS_SANDBOX" 1 "$RC" "$WORK/t-nomp.log" "^ERROR: E_STATE: run $RUN_ID has no MAX_PODS_SANDBOX in "
restore sandbox-node; rewind workloads; sed -i '/^MAX_PODS_CEILING_SANDBOX=/d' "$RD/state.env"
run_real "$WORK/t-noceil.log" bash "$SAMPLE_DIR_REAL/test.sh"
check "REJECT test.sh on a run whose state has no max-pods ceiling (MAX_PODS_CEILING_SANDBOX)" 1 "$RC" "$WORK/t-noceil.log" "^ERROR: E_STATE: run $RUN_ID has no MAX_PODS_CEILING_SANDBOX in "
finish
