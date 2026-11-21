#!/usr/bin/env bash
# test-cluster-helper.sh: proves the config, render, AMI, name, quota, builder, recheck and tag
# checks of scripts/cilium_bottlerocket.py both ways, the REAL helper, run after
# `source scripts/common.sh` as setup.sh and clean.sh run it, against the fake world of a finished
# run (scripts/testlib/world_full.py). A check that reads a tracked input (cilium-values.yaml,
# deploy/, the eksctl templates) gets its reject case from a copy of the sample tree under the work
# folder with that one input changed; the code that runs is the same.
#
#   examples/setup/cilium-bottlerocket/scripts/test-cluster-helper.sh
source "$(dirname "$0")/testlib/harness.sh"
HELPER="$SAMPLE_DIR_REAL/scripts/cilium_bottlerocket.py"
need_file "$HELPER" "every cluster helper case" || finish
RD="$CB_RUN_DIR/runs/r1"
full() {
  world_reset; rm -rf "$CB_RUN_DIR/runs"; mkdir -p -m 700 "$RD"
  python3 "$TESTLIB/world_full.py" "$FAKE_STATE" "$RD/state.env" "$@"; chmod 600 "$RD/state.env"
  printf 'r1\n' > "$CB_RUN_DIR/current-run"; export RUN_ID=r1
}
# h <log> [SAMPLE=<tree>] <subcommand> <args...>: the real helper of the sample tree after common.sh
# and require_run_id; sets RC.
h() {
  local log="$1" tree="$SAMPLE_DIR_REAL"; shift
  if [[ "$1" == SAMPLE=* ]]; then tree="${1#SAMPLE=}"; shift; fi
  run_real "$log" bash -c 'SAMPLE_DIR="$1"; shift; source "$SAMPLE_DIR/scripts/common.sh" || exit 1; require_run_id; python3 "$PY" "$@"' h "$tree" "$@"
}
# tree <name>: a copy of the sample tree, three levels below a copy of scripts/lib/require-bash.sh.
tree() {
  local t="$WORK/tree-$1"
  rm -rf "$t"; mkdir -p "$t/scripts/lib" "$t/examples/setup"
  cp "$REPO_ROOT_REAL/scripts/lib/require-bash.sh" "$t/scripts/lib/"
  cp -r "$SAMPLE_DIR_REAL" "$t/examples/setup/cilium-bottlerocket"
  T="$t/examples/setup/cilium-bottlerocket"
}
acc() { entry "scripts/cilium_bottlerocket.py:$1"; cover accept "$2" "${2}_UNKNOWN"; }

echo "== 1/5 config, Cilium values, manifests =============================================="
full
h "$WORK/cfg.log" check-config
check "ACCEPT the config: names, zones, instance types, slot count and volume sizes" 0 "$RC" "$WORK/cfg.log" '^config: '
acc check-config E_CONFIG
for kv in 'SANDBOX_INSTANCE_TYPE="m8i xlarge"' 'AVAILABILITY_ZONES="us-west-2b us-west-2b"' 'AVAILABILITY_ZONES="us-west-2b us-east-1a"' \
  'SYSTEM_DATA_VOLUME_GIB="10"' 'SYSTEM_AMI_ID="ami-123"' 'SANDBOX_SLOTS="251"'; do
  cp "$CB_LOCAL_CONFIG" "$WORK/cfg.bak"; config_set "$kv"
  h "$WORK/cfg-bad.log" check-config
  check "REJECT the config with $kv" 1 "$RC" "$WORK/cfg-bad.log" '^ERROR: E_CONFIG: '
  cp "$WORK/cfg.bak" "$CB_LOCAL_CONFIG"
done
h "$WORK/cv.log" check-cilium-values
check "ACCEPT the tracked cilium-values.yaml: ENI IPAM, native routing, kube-proxy replacement, socketLB.hostNamespaceOnly, no version" 0 "$RC" "$WORK/cv.log" '^cilium values: '
acc check-cilium-values E_CILIUM_VALUES
while IFS='|' read -r code why; do
  [[ -n "$code" ]] || continue
  python3 -c 'import sys; t = open(sys.argv[1]).read(); exec("t = " + sys.argv[3]); open(sys.argv[2], "w").write(t)' \
    "$SAMPLE_DIR_REAL/cilium-values.yaml" "$WORK/values.yaml" "$code"
  h "$WORK/cv-bad.log" check-cilium-values "$WORK/values.yaml"
  check "$why" 1 "$RC" "$WORK/cv-bad.log" '^ERROR: E_CILIUM_VALUES: '
done <<'CASES'
t.replace("hostNamespaceOnly: true", "hostNamespaceOnly: false")|REJECT socketLB.hostNamespaceOnly false
t.replace("mode: eni", "mode: cluster-pool")|REJECT IPAM mode cluster-pool
t + "\nimage:\n  tag: v1.20.4\n"|REJECT a values file that names an image version (cilium.lock is the one version source)
CASES
printf 'a: [unclosed\n' > "$WORK/notyaml.yaml"; h "$WORK/cv-yaml.log" check-cilium-values "$WORK/notyaml.yaml"
check "REJECT a values file that is not YAML, as could not check" 2 "$RC" "$WORK/cv-yaml.log" '^ERROR: E_CILIUM_VALUES_UNKNOWN: '
h "$WORK/mf.log" check-manifests
check "ACCEPT the tracked deploy/: ClusterIP only, no Ingress or network policy, no resources, the pinned image" 0 "$RC" "$WORK/mf.log" '^deploy/: '
acc check-manifests E_MANIFESTS
while IFS='|' read -r text why; do
  [[ -n "$text" ]] || continue
  rm -rf "$WORK/deploy"; cp -r "$SAMPLE_DIR_REAL/deploy" "$WORK/deploy"; printf '%b' "$text" > "$WORK/deploy/extra.yaml"
  h "$WORK/mf-bad.log" check-manifests "$WORK/deploy"
  check "$why" 1 "$RC" "$WORK/mf-bad.log" '^ERROR: E_MANIFESTS: '
done <<'CASES'
apiVersion: v1\nkind: Service\nmetadata:\n  name: x\nspec:\n  type: LoadBalancer\n|REJECT a Service of type LoadBalancer
apiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n  name: x\n|REJECT an Ingress
apiVersion: cilium.io/v2\nkind: CiliumNetworkPolicy\nmetadata:\n  name: x\n|REJECT a network policy (the sample ships none)
apiVersion: v1\nkind: Pod\nmetadata:\n  name: x\nspec:\n  containers:\n  - name: c\n    image: public.ecr.aws/docker/library/busybox:latest\n|REJECT a pod image that is not the pinned busybox
CASES
mkdir -p "$WORK/emptydeploy"; h "$WORK/mf-empty.log" check-manifests "$WORK/emptydeploy"
check "REJECT a deploy folder with no manifest, as could not check" 2 "$RC" "$WORK/mf-empty.log" '^ERROR: E_MANIFESTS_UNKNOWN: '

echo "== 2/5 rendered eksctl objects, the probe, the RuntimeClass, the DaemonSet ============="
full
h "$WORK/rc.log" render-cluster
check "ACCEPT render-cluster: Kubernetes 1.36, no default add-ons, no vpc-cni or kube-proxy, the sample tags" 0 "$RC" "$WORK/rc.log"
acc render-cluster E_RENDER_CLUSTER
tree addon; python3 -c 'import sys; p = sys.argv[1]; t = open(p).read(); open(p, "w").write(t.replace("addons:\n", "addons:\n  - name: vpc-cni\n", 1))' "$T/eksctl/cluster.yaml"
h "$WORK/rc-bad.log" "SAMPLE=$T" render-cluster
check "REJECT a cluster template with the vpc-cni add-on" 1 "$RC" "$WORK/rc-bad.log" '^ERROR: E_RENDER_CLUSTER: '
h "$WORK/rpi.log" render-pod-identity
check "ACCEPT render-pod-identity: one association, kube-system/cilium-operator, exactly the Cilium EC2 actions" 0 "$RC" "$WORK/rpi.log"
acc render-pod-identity E_RENDER_POD_IDENTITY
tree pia; python3 -c 'import sys; p = sys.argv[1]; t = open(p).read(); assert "ec2:CreateTags" in t; open(p, "w").write(t.replace("ec2:CreateTags", "ec2:CreateTags\n              - ec2:DetachNetworkInterface", 1))' "$T/eksctl/pod-identity.yaml"
h "$WORK/rpi-bad.log" "SAMPLE=$T" render-pod-identity
check "REJECT an operator policy with an action outside the Cilium list (ec2:DetachNetworkInterface)" 1 "$RC" "$WORK/rpi-bad.log" '^ERROR: E_RENDER_POD_IDENTITY: '
h "$WORK/rng.log" render-nodegroup sandbox
check "ACCEPT render-nodegroup sandbox: exactly one node, the two node policies, the sample tags" 0 "$RC" "$WORK/rng.log"
acc render-nodegroup E_RENDER_NODEGROUP
sed -i '/^SANDBOX_LAUNCH_TEMPLATE_ID=/d' "$RD/state.env"
h "$WORK/rng-nolt.log" render-nodegroup sandbox
check "REJECT render-nodegroup with no sandbox launch template in the state file" 1 "$RC" "$WORK/rng-nolt.log" '^ERROR: E_RENDER_NODEGROUP: '
full
h "$WORK/rp.log" render-probe --name cb-probe-sandbox-r1 --node ip-10-0-1-10.us-west-2.compute.internal
check "ACCEPT render-probe for cb-probe-sandbox-r1 on a node" 0 "$RC" "$WORK/rp.log" 'cb-probe-sandbox-r1'
acc render-probe E_RENDER_PROBE
h "$WORK/rp-bad.log" render-probe --name helper-pod --node ip-10-0-1-10.us-west-2.compute.internal
check "REJECT a probe name that is not cb-probe-<group>-<run ID> (deleted by exact name later)" 1 "$RC" "$WORK/rp-bad.log" '^ERROR: E_RENDER_PROBE: '
for n in 40 1; do
  h "$WORK/rf-$n.log" render-filler --name "cb-filler-$n-r1" --node ip-10-0-2-20.us-west-2.compute.internal
  check "ACCEPT render-filler for cb-filler-$n-r1 on the sandbox node (test.sh starts at most 40)" 0 "$RC" "$WORK/rf-$n.log" "name: cb-filler-$n-r1\$"
done
acc render-filler E_RENDER_FILLER
for n in 41 0 07; do
  h "$WORK/rf-bad.log" render-filler --name "cb-filler-$n-r1" --node ip-10-0-2-20.us-west-2.compute.internal
  check "REJECT the filler name cb-filler-$n-r1: not cb-filler-<1 to 40> (deleted by exact name later)" 1 "$RC" "$WORK/rf-bad.log" \
    "^ERROR: E_RENDER_FILLER: filler name cb-filler-$n-r1 is not cb-filler-<1 to 40>-<run ID>\$"
done
h "$WORK/rf-node.log" render-filler --name cb-filler-1-r1 --node 'ip_10_0_2_20'
check "REJECT a filler node name that is not a node name" 1 "$RC" "$WORK/rf-node.log" '^ERROR: E_RENDER_FILLER: node name ip_10_0_2_20 is not valid'
h "$WORK/rtc.log" runtimeclass; cp "$WORK/rtc.log" "$WORK/rtc.json"
h "$WORK/crc.log" check-runtimeclass "$WORK/rtc.json"
check "ACCEPT the rendered RuntimeClass isolated-sandbox: the sample's label, handler, overhead and node selector" 0 "$RC" "$WORK/crc.log"
acc check-runtimeclass E_RUNTIMECLASS
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); d["metadata"]["labels"] = {}; json.dump(d, open(sys.argv[2], "w"))' "$WORK/rtc.json" "$WORK/rtc-foreign.json"
h "$WORK/crc-bad.log" check-runtimeclass "$WORK/rtc-foreign.json"
check "REJECT a RuntimeClass isolated-sandbox without the sample's label (someone else's)" 1 "$RC" "$WORK/crc-bad.log" '^ERROR: E_RUNTIMECLASS: '
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); d["overhead"]["podFixed"]["memory"] = "128Mi"; json.dump(d, open(sys.argv[2], "w"))' "$WORK/rtc.json" "$WORK/rtc-overhead.json"
h "$WORK/crc-oh.log" check-runtimeclass "$WORK/rtc-overhead.json"
check "REJECT a RuntimeClass with another overhead" 1 "$RC" "$WORK/crc-oh.log" '^ERROR: E_RUNTIMECLASS: '
printf '{"spec": {"template": {"spec": {"nodeSelector": {"kubernetes.io/os": "linux"}, "tolerations": [{"operator": "Exists"}]}}}}\n' > "$WORK/ds.json"
h "$WORK/ds.log" preflight-daemonset "$WORK/ds.json"
check "ACCEPT a Cilium DaemonSet that selects and tolerates the sandbox node" 0 "$RC" "$WORK/ds.log" '^cilium DaemonSet: selects and tolerates the sandbox node$'
acc preflight-daemonset E_PREFLIGHT_DAEMONSET
printf '{"spec": {"template": {"spec": {"nodeSelector": {"kubernetes.io/os": "linux"}, "tolerations": []}}}}\n' > "$WORK/ds-bad.json"
h "$WORK/ds-bad.log" preflight-daemonset "$WORK/ds-bad.json"
check "REJECT a Cilium DaemonSet that does not tolerate the sandbox taint" 1 "$RC" "$WORK/ds-bad.log" '^ERROR: E_PREFLIGHT_DAEMONSET: '

echo "== 3/5 launch templates and their user data ========================================="
full; world_py 's["ec2"]["launch_templates"] = [t for t in s["ec2"]["launch_templates"] if not t["LaunchTemplateName"].startswith("cb-offline-test-r1-")]'
h "$WORK/lt.log" launch-template sandbox
check "ACCEPT launch-template sandbox: created with the sample tags, its ID printed" 0 "$RC" "$WORK/lt.log" '^lt-[0-9a-f]{17}$'
acc launch-template E_LAUNCH_TEMPLATE
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); json.dump({"LaunchTemplateVersions": [{"LaunchTemplateData": d}]}, open(sys.argv[2], "w"))' "$RD/lt-sandbox.json" "$WORK/ltv.json"
h "$WORK/ud.log" check-user-data sandbox "$WORK/ltv.json"
check "ACCEPT the sandbox user data as rendered: IMDSv2 hop limit 1, the TOML settings" 0 "$RC" "$WORK/ud.log" '^sandbox launch template: IMDSv2 hop limit 1'
acc check-user-data E_USER_DATA
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); d["LaunchTemplateVersions"][0]["LaunchTemplateData"]["MetadataOptions"]["HttpPutResponseHopLimit"] = 2; json.dump(d, open(sys.argv[2], "w"))' "$WORK/ltv.json" "$WORK/ltv-hop.json"
h "$WORK/ud-hop.log" check-user-data sandbox "$WORK/ltv-hop.json"
check "REJECT sandbox user data with metadata hop limit 2" 1 "$RC" "$WORK/ud-hop.log" '^ERROR: E_USER_DATA: '
printf '{"LaunchTemplates": []}\n' > "$WORK/ltv-bad.json"
h "$WORK/ud-shape.log" check-user-data sandbox "$WORK/ltv-bad.json"
check "REJECT an input that is not describe-launch-template-versions output, as could not check" 2 "$RC" "$WORK/ud-shape.log" '^ERROR: E_USER_DATA_UNKNOWN: '
full
world_py 's["ec2"]["launch_templates"] = [dict(t, Tags=[{"Key": "team", "Value": "someone-else"}]) if t["LaunchTemplateName"] == "cb-offline-test-r1-sandbox" else t for t in s["ec2"]["launch_templates"]]'
h "$WORK/lt-foreign.log" launch-template sandbox
check "REJECT an existing launch template of the same name that is not this run's" 1 "$RC" "$WORK/lt-foreign.log" '^ERROR: E_LAUNCH_TEMPLATE: launch template cb-offline-test-r1-sandbox exists and is not this run'
# max-pods of the user data is the value that setup.sh derived and recorded in the run state
# (MAX_PODS_SANDBOX), never SANDBOX_SLOTS: the slot count of the fixture config is set to 20 here.
full; world_py 's["ec2"]["launch_templates"] = [t for t in s["ec2"]["launch_templates"] if not t["LaunchTemplateName"].startswith("cb-offline-test-r1-")]'
config_set 'SANDBOX_SLOTS="20"'
h "$WORK/lt-mp.log" launch-template sandbox
python3 -c 'import base64, json, re, sys; d = json.load(open(sys.argv[1])); print("\n".join(re.findall(r"^max-pods = .*$", base64.b64decode(d["UserData"]).decode(), re.M)))' "$RD/lt-sandbox.json" > "$WORK/lt-mp.txt" 2>&1
[[ "$RC" == 0 && "$(cat "$WORK/lt-mp.txt")" == 'max-pods = 118' ]]
check "ACCEPT the sandbox user data max-pods: the derived 118 of the run state, not SANDBOX_SLOTS 20" 0 $? "$WORK/lt-mp.txt"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); json.dump({"LaunchTemplateVersions": [{"LaunchTemplateData": d}]}, open(sys.argv[2], "w"))' "$RD/lt-sandbox.json" "$WORK/ltv-mp.json"
sed -i 's/^MAX_PODS_SANDBOX=.*/MAX_PODS_SANDBOX=58/' "$RD/state.env"
h "$WORK/ud-mp.log" check-user-data sandbox "$WORK/ltv-mp.json"
check "REJECT sandbox user data whose max-pods (118) is not the run's derived value (58)" 1 "$RC" "$WORK/ud-mp.log" '^ERROR: E_USER_DATA: .*max-pods is 118, want 58'
sed -i '/^MAX_PODS_SANDBOX=/d' "$RD/state.env"
h "$WORK/ud-nomp.log" check-user-data sandbox "$WORK/ltv-mp.json"
check "REJECT check-user-data when the run state has no derived MAX_PODS_SANDBOX, as could not check" 2 "$RC" "$WORK/ud-nomp.log" '^ERROR: E_USER_DATA_UNKNOWN: could not check: the run state has no derived MAX_PODS_SANDBOX'
full; world_py 's["ec2"]["launch_templates"] = [t for t in s["ec2"]["launch_templates"] if not t["LaunchTemplateName"].startswith("cb-offline-test-r1-")]'
sed -i '/^MAX_PODS_SANDBOX=/d' "$RD/state.env"
h "$WORK/lt-nomp.log" launch-template sandbox
check "REJECT launch-template sandbox when the run state has no derived MAX_PODS_SANDBOX, as could not check" 2 "$RC" "$WORK/lt-nomp.log" '^ERROR: E_LAUNCH_TEMPLATE_UNKNOWN: could not check: the run state has no derived MAX_PODS_SANDBOX'
[[ "$(count_calls aws 'ec2 create-launch-template')" == 0 ]]; check "  ... and no launch template was created" 0 $? "$WORK/lt-nomp.log"
# derive-max-pods: ENIs x (IPv4 per ENI - 1) + 2 from ec2 describe-instance-types (the fake world
# gives m8i.xlarge 4 x 30 and m8i.4xlarge 8 x 30).
full
h "$WORK/dmp.log" derive-max-pods m8i.xlarge
check "ACCEPT derive-max-pods m8i.xlarge (4 ENIs x 30 IPv4): 118" 0 "$RC" "$WORK/dmp.log" '^118$'
acc derive-max-pods E_DERIVE_MAX_PODS
h "$WORK/dmp-4x.log" derive-max-pods m8i.4xlarge
check "ACCEPT a second shape, m8i.4xlarge (8 ENIs x 30 IPv4): 234" 0 "$RC" "$WORK/dmp-4x.log" '^234$'
FAKE_FAIL='aws|ec2 describe-instance-types||UnauthorizedOperation' h "$WORK/dmp-read.log" derive-max-pods m8i.xlarge
check "REJECT a describe-instance-types read that fails, as could not check" 2 "$RC" "$WORK/dmp-read.log" '^ERROR: E_DERIVE_MAX_PODS_UNKNOWN: '
h "$WORK/dmp-none.log" derive-max-pods m8i.24xlarge
check "REJECT an instance type with no describe-instance-types entry, as could not check" 2 "$RC" "$WORK/dmp-none.log" '^ERROR: E_DERIVE_MAX_PODS_UNKNOWN: could not check: describe-instance-types gave 0 entries for m8i\.24xlarge$'
h "$WORK/dmp-name.log" derive-max-pods 'm8i xlarge'
check "REJECT an argument that is not an instance type" 1 "$RC" "$WORK/dmp-name.log" "^ERROR: E_DERIVE_MAX_PODS: 'm8i xlarge' is not an instance type$"
while IFS='|' read -r code want rx why; do
  [[ -n "$code" ]] || continue
  full; world_py "t = s['instance_types']['m8i.xlarge']; $code"
  h "$WORK/dmp-c.log" derive-max-pods m8i.xlarge
  check "$why" "$want" "$RC" "$WORK/dmp-c.log" "$rx"
done <<'CASES'
t.pop('NetworkInfo')|2|^ERROR: E_DERIVE_MAX_PODS_UNKNOWN: could not check: the instance type has no NetworkInfo$|REJECT an instance type with no NetworkInfo, as could not check
t['NetworkInfo'].pop('MaximumNetworkInterfaces')|2|^ERROR: E_DERIVE_MAX_PODS_UNKNOWN: could not check: NetworkInfo\.MaximumNetworkInterfaces is None, not a number$|REJECT a NetworkInfo with no MaximumNetworkInterfaces, as could not check
t['NetworkInfo'].pop('Ipv4AddressesPerInterface')|2|^ERROR: E_DERIVE_MAX_PODS_UNKNOWN: could not check: NetworkInfo\.Ipv4AddressesPerInterface is None, not a number$|REJECT a NetworkInfo with no Ipv4AddressesPerInterface, as could not check
t['NetworkInfo']['Ipv4AddressesPerInterface'] = '30'|2|^ERROR: E_DERIVE_MAX_PODS_UNKNOWN: could not check: NetworkInfo\.Ipv4AddressesPerInterface is '30', not a number$|REJECT a field that is a string, not a number, as could not check
t['NetworkInfo']['MaximumNetworkInterfaces'] = 0|1|^ERROR: E_DERIVE_MAX_PODS: NetworkInfo\.MaximumNetworkInterfaces is 0, want more than 0$|REJECT MaximumNetworkInterfaces 0
t['NetworkInfo']['Ipv4AddressesPerInterface'] = 0|1|^ERROR: E_DERIVE_MAX_PODS: NetworkInfo\.Ipv4AddressesPerInterface is 0, want more than 0$|REJECT Ipv4AddressesPerInterface 0
CASES

echo "== 4/5 AMIs, names, quota, the builder, the operator role ============================="
full
h "$WORK/rsa.log" resolve-system-ami
check "ACCEPT resolve-system-ami: the public Bottlerocket aws-k8s-1.36 1.70.0 parameter holds an AMI ID" 0 "$RC" "$WORK/rsa.log" '^ami-[0-9a-f]+$'
acc resolve-system-ami E_RESOLVE_SYSTEM_AMI
world_py 's["ssm"]["parameters"]["/aws/service/bottlerocket/aws-k8s-1.36/x86_64/1.70.0/image_id"] = "not-an-ami"'
h "$WORK/rsa-bad.log" resolve-system-ami
check "REJECT a system AMI parameter that is not an AMI ID" 1 "$RC" "$WORK/rsa-bad.log" '^ERROR: E_RESOLVE_SYSTEM_AMI: '
world_py 's["ssm"]["parameters"] = {}'
h "$WORK/rsa-none.log" resolve-system-ami
check "REJECT a system AMI parameter that cannot be read, as could not check" 2 "$RC" "$WORK/rsa-none.log" '^ERROR: E_RESOLVE_SYSTEM_AMI_UNKNOWN: '
sysami="$(sed -n 's/^SYSTEM_AMI_NAME=//p' "$SAMPLE_DIR_REAL/scripts/common.sh" | head -n1)"
printf '{"Images": [{"ImageId": "ami-0fa00000000000001", "Name": "%s", "ImageOwnerAlias": "amazon", "Public": true, "State": "available", "Architecture": "x86_64"}]}\n' "$sysami" > "$WORK/sys.json"
h "$WORK/sa.log" check-system-ami "$WORK/sys.json" --ami ami-0fa00000000000001
check "ACCEPT the stock Bottlerocket v1.70.0 aws-k8s-1.36 image, owner alias amazon" 0 "$RC" "$WORK/sa.log" '^system AMI ami-0fa00000000000001: '
acc check-system-ami E_SYSTEM_AMI
sed 's/"amazon"/"aws-marketplace"/' "$WORK/sys.json" > "$WORK/sys-bad.json"
h "$WORK/sa-bad.log" check-system-ami "$WORK/sys-bad.json" --ami ami-0fa00000000000001
check "REJECT a same-name image that is not owned by amazon" 1 "$RC" "$WORK/sa-bad.log" '^ERROR: E_SYSTEM_AMI: '
python3 "$TESTLIB/fixture_aws_json.py" good "$WORK/aj"
python3 "$TESTLIB/fixture_aws_json.py" mutate "$WORK/aj/images.json" "$WORK/aj/images.json" 'd["Images"][0]["BlockDeviceMappings"][0]["Ebs"]["SnapshotId"] = "snap-0fb00000000000001"'
sed -i 's/^SANDBOX_AMI_ID=.*/SANDBOX_AMI_ID=ami-0fb00000000000001/; s/^SANDBOX_AMI_SNAPSHOT_IDS=.*/SANDBOX_AMI_SNAPSHOT_IDS=snap-0fb00000000000001,snap-0fb00000000000002/' "$RD/state.env"
h "$WORK/sba.log" check-sandbox-ami --images "$WORK/aj/images.json" --uefi "$WORK/aj/uefi.json" --snapshots "$WORK/aj/snapshots.json"
check "ACCEPT the sandbox AMI: x86_64, hvm, ENA, SR-IOV, IMDSv2, uefi-preferred, no UEFI data, two tagged gp3 snapshots, SandboxSlots = SANDBOX_SLOTS" 0 "$RC" "$WORK/sba.log" '^sandbox AMI ami-0fb00000000000001: '
acc check-sandbox-ami E_SANDBOX_AMI
config_set 'SANDBOX_SLOTS="57"'
h "$WORK/sba-slots.log" check-sandbox-ami --images "$WORK/aj/images.json" --uefi "$WORK/aj/uefi.json" --snapshots "$WORK/aj/snapshots.json"
check "REJECT a sandbox AMI whose SandboxSlots tag differs from the config SANDBOX_SLOTS" 1 "$RC" "$WORK/sba-slots.log" '^ERROR: E_SANDBOX_AMI: .*SandboxSlots'
config_set 'SANDBOX_SLOTS="58"'
python3 "$TESTLIB/fixture_aws_json.py" mutate "$WORK/aj/uefi.json" "$WORK/aj/uefi-data.json" 'd["UefiData"] = {"Value": "QUJD"}'
h "$WORK/sba-uefi.log" check-sandbox-ami --images "$WORK/aj/images.json" --uefi "$WORK/aj/uefi-data.json" --snapshots "$WORK/aj/snapshots.json"
check "REJECT a sandbox AMI with UEFI variable data" 1 "$RC" "$WORK/sba-uefi.log" '^ERROR: E_SANDBOX_AMI: .*UEFI'
python3 "$TESTLIB/fixture_aws_json.py" mutate "$WORK/aj/images.json" "$WORK/aj/images-r2.json" 'd["Images"][0]["Tags"][1]["Value"] = "r2"'
h "$WORK/sba-reuse.log" check-sandbox-ami --reuse --images "$WORK/aj/images-r2.json" --uefi "$WORK/aj/uefi.json" --snapshots "$WORK/aj/snapshots.json"
check "ACCEPT REUSE_SANDBOX_AMI_ID: an AMI of another run of the sample with the same SandboxSlots (--reuse)" 0 "$RC" "$WORK/sba-reuse.log" '^sandbox AMI '
h "$WORK/sba-r2.log" check-sandbox-ami --images "$WORK/aj/images-r2.json" --uefi "$WORK/aj/uefi.json" --snapshots "$WORK/aj/snapshots.json"
check "REJECT, without --reuse, an AMI whose RunId is another run's" 1 "$RC" "$WORK/sba-r2.log" '^ERROR: E_SANDBOX_AMI: .*RunId'
# Each snapshot carries SandboxSlots equal to the config, with and without
# --reuse. The accept cases above have SandboxSlots=58 on both snapshots.
python3 "$TESTLIB/fixture_aws_json.py" mutate "$WORK/aj/snapshots.json" "$WORK/aj/snap-noslots.json" \
  'd["Snapshots"][1]["Tags"] = [t for t in d["Snapshots"][1]["Tags"] if t["Key"] != "SandboxSlots"]'
python3 "$TESTLIB/fixture_aws_json.py" mutate "$WORK/aj/snapshots.json" "$WORK/aj/snap-57.json" \
  '[t.update(Value="57") for t in d["Snapshots"][1]["Tags"] if t["Key"] == "SandboxSlots"]'
for reuse in "" --reuse; do
  imgs="$WORK/aj/images.json"; [[ -z "$reuse" ]] || imgs="$WORK/aj/images-r2.json"
  # shellcheck disable=SC2086 # reuse is empty or one flag
  h "$WORK/sba-snoslots.log" check-sandbox-ami $reuse --images "$imgs" --uefi "$WORK/aj/uefi.json" --snapshots "$WORK/aj/snap-noslots.json"
  check "REJECT ${reuse:-(no --reuse)}: a data snapshot with no SandboxSlots tag" 1 "$RC" "$WORK/sba-snoslots.log" \
    "^ERROR: E_SANDBOX_AMI: .*snapshot snap-0fb00000000000002 has SandboxSlots=None, config SANDBOX_SLOTS=58"
  # shellcheck disable=SC2086 # reuse is empty or one flag
  h "$WORK/sba-s57.log" check-sandbox-ami $reuse --images "$imgs" --uefi "$WORK/aj/uefi.json" --snapshots "$WORK/aj/snap-57.json"
  check "REJECT ${reuse:-(no --reuse)}: a data snapshot with SandboxSlots=57 when SANDBOX_SLOTS is 58" 1 "$RC" "$WORK/sba-s57.log" \
    "^ERROR: E_SANDBOX_AMI: .*snapshot snap-0fb00000000000002 has SandboxSlots='57', config SANDBOX_SLOTS=58"
done
full
h "$WORK/q.log" quota
check "ACCEPT quota headroom for one more VPC, internet gateway, NAT gateway and Elastic IP address" 0 "$RC" "$WORK/q.log" '^VPCs: [0-9]+ used of 10$'
acc quota E_QUOTA
world_py 's["quotas"]["ec2/L-0263D0A3"] = 1.0'
h "$WORK/q-bad.log" quota
check "REJECT a Region with no Elastic IP address left" 1 "$RC" "$WORK/q-bad.log" '^ERROR: E_QUOTA: no headroom for one more: Elastic IP addresses'
full
h "$WORK/cn.log" check-names
check "ACCEPT check-names: the cluster, stack, templates, roles, profile and SG are free or this run's" 0 "$RC" "$WORK/cn.log"
acc check-names E_NAMES
world_py 's["iam"]["roles"]["cb-offline-test-r1-builder"] = {"Tags": [{"Key": "team", "Value": "someone-else"}], "Attached": [], "Inline": {}}'
h "$WORK/cn-role.log" check-names
check "REJECT a builder role name that someone else's role holds" 1 "$RC" "$WORK/cn-role.log" '^ERROR: E_NAMES: '
full; world_py 's["eks"]["clusters"]["cb-offline-test"]["tags"] = {"team": "someone-else"}'
h "$WORK/cn-cl.log" check-names
check "REJECT a cluster name that someone else's cluster holds" 1 "$RC" "$WORK/cn-cl.log" '^ERROR: E_NAMES: '
full killed-build; world_py 's["ec2"]["instances"] = [i for i in s["ec2"]["instances"] if i["InstanceId"] != "i-0fb00000000000001"]
s["ec2"]["volumes"] = [v for v in s["ec2"]["volumes"] if not v["VolumeId"].startswith("vol-0fb")]
s["ec2"]["security_groups"] = [g for g in s["ec2"]["security_groups"] if g["GroupId"] != "sg-0fc00000000000001"]
del s["iam"]["roles"]["cb-offline-test-r1-builder"]; del s["iam"]["profiles"]["cb-offline-test-r1-builder"]'
h "$WORK/bg.log" builder-gone
check "ACCEPT builder-gone: the builder instance, its volumes, SG, profile and role read back as gone" 0 "$RC" "$WORK/bg.log"
acc builder-gone E_BUILDER_GONE
full killed-build
h "$WORK/bg-left.log" builder-gone
check "REJECT builder-gone while the builder and its parts exist" 1 "$RC" "$WORK/bg-left.log" '^ERROR: E_BUILDER_GONE: builder resources remain'
sed -i '/^BUILDER_VOLUME_IDS=/d' "$RD/state.env"
h "$WORK/bg-state.log" builder-gone
check "REJECT builder-gone when the state file does not name the builder volumes, as could not check" 2 "$RC" "$WORK/bg-state.log" '^ERROR: E_BUILDER_GONE_UNKNOWN: '
full
h "$WORK/rk.log" recheck launch-template lt-0fa00000000000001
check "ACCEPT recheck of this run's launch template (exit 0)" 0 "$RC" "$WORK/rk.log" 'ours$'
acc recheck E_RECHECK
h "$WORK/rk-r2.log" recheck launch-template lt-0fa00000000000202
check "REJECT recheck of run r2's launch template (exit 1)" 1 "$RC" "$WORK/rk-r2.log" '^ERROR: E_RECHECK: '
h "$WORK/rk-gone.log" recheck launch-template lt-0fa00000000000999
check "ACCEPT recheck of a launch template that is gone (exit 3)" 3 "$RC" "$WORK/rk-gone.log" 'gone$'
FAKE_FAIL='aws|ec2 describe-launch-templates||RequestLimitExceeded' h "$WORK/rk-err.log" recheck launch-template lt-0fa00000000000001
check "REJECT recheck when the read fails, as could not check (exit 2)" 2 "$RC" "$WORK/rk-err.log" '^ERROR: E_RECHECK_UNKNOWN: '
# The operator role: made from the rendered pod-identity.yaml by the eksctl stub, as setup.sh makes it.
full; world_py 's["eks"]["pod_identity"] = {}; s["eks"]["nodegroups"] = {}; del s["iam"]["roles"]["cb-offline-test-cilium-operator"]'
h "$WORK/rpi2.log" render-pod-identity
cloud_guard "$PATH"; eksctl create podidentityassociation -f "$RD/pod-identity.yaml" > "$WORK/pia-create.log" 2>&1
h "$WORK/or.log" check-operator-role
check "ACCEPT the operator role: one association, no managed policy, exactly the Cilium EC2 actions" 0 "$RC" "$WORK/or.log" '^operator role cb-offline-test-cilium-operator: exactly the 13 EC2 actions'
acc check-operator-role E_OPERATOR_ROLE
world_py 's["iam"]["roles"]["cb-offline-test-cilium-operator"]["Attached"].append("arn:aws:iam::aws:policy/AmazonEC2FullAccess")'
h "$WORK/or-bad.log" check-operator-role
check "REJECT an operator role with a managed policy attached" 1 "$RC" "$WORK/or-bad.log" '^ERROR: E_OPERATOR_ROLE: '

echo "== 5/5 the tag audit and the tag sweep ======================================="
full
h "$WORK/at.log" audit-tags
check "ACCEPT the tag audit: every resource of every class carries ManagedBy and RunId" 0 "$RC" "$WORK/at.log" '^tag audit: '
acc audit-tags E_AUDIT_TAGS
full; world_py '[x for x in s["ec2"]["route_tables"] if x["RouteTableId"] == "rtb-0fa00000000000002"][0]["Tags"] = []'
h "$WORK/at-untagged.log" audit-tags
check "REJECT a route table of the run without ManagedBy and RunId" 1 "$RC" "$WORK/at-untagged.log" '^ERROR: E_AUDIT_TAGS: '
full; world_py 's["ec2"]["vpc_endpoints"].append({"VpcEndpointId": "vpce-0fa00000000000001", "VpcId": "vpc-0fa00000000000001", "Tags": []})'
h "$WORK/at-class.log" audit-tags
check "REJECT a VPC resource that belongs to no inventory class (a missing class)" 1 "$RC" "$WORK/at-class.log" '^ERROR: E_AUDIT_TAGS: .*belongs to no inventory class'
full; FAKE_FAIL='aws|ec2 describe-subnets||RequestLimitExceeded' h "$WORK/at-read.log" audit-tags
check "REJECT a tag audit whose read fails, as could not check" 2 "$RC" "$WORK/at-read.log" '^ERROR: E_AUDIT_TAGS_UNKNOWN: '
full; world_py '[x for x in s["ec2"]["route_tables"] if x["RouteTableId"] == "rtb-0fa00000000000001"][0]["Tags"] = []'
h "$WORK/ts.log" tag-sweep
check "ACCEPT the tag sweep: the main route table that AWS made with no tag gets both tags" 0 "$RC" "$WORK/ts.log"
acc tag-sweep E_TAG_SWEEP
alive() { [[ "$(world_get "$1")" == true ]]; }
alive '{t["Key"]: t["Value"] for t in [x for x in s["ec2"]["route_tables"] if x["RouteTableId"] == "rtb-0fa00000000000001"][0]["Tags"]}.get("RunId") == "r1"'
check "  ... and the main route table now carries RunId r1" 0 $? "$WORK/ts.log"
full; world_py '[x for x in s["ec2"]["route_tables"] if x["RouteTableId"] == "rtb-0fa00000000000001"][0]["Tags"] = [{"Key": "ManagedBy", "Value": "someone-else"}]'
h "$WORK/ts-other.log" tag-sweep
check "REJECT the tag sweep when a sweep member carries another ManagedBy: nothing is tagged" 1 "$RC" "$WORK/ts-other.log" '^ERROR: E_TAG_SWEEP: '
[[ "$(count_calls aws 'ec2 create-tags')" == 0 ]]; check "  ... and no create-tags call was made" 0 $? "$WORK/ts-other.log"
full; FAKE_FAIL='aws|ec2 describe-route-tables||RequestLimitExceeded' h "$WORK/ts-read.log" tag-sweep
check "REJECT the tag sweep when a sweep class cannot be read, as could not check" 2 "$RC" "$WORK/ts-read.log" '^ERROR: E_TAG_SWEEP_UNKNOWN: '
full; h "$WORK/ow.log" owned
check "ACCEPT owned: every resource of the run, one JSON line each, the VPC among them" 0 "$RC" "$WORK/ow.log" '"class": "vpc", "id": "vpc-0fa00000000000001", "ours": true'
entry "scripts/cilium_bottlerocket.py:owned"; cover accept E_OWNED_UNKNOWN
full; FAKE_FAIL='aws|ec2 describe-vpcs||RequestLimitExceeded' h "$WORK/ow-read.log" owned
check "REJECT owned when the VPC read fails, as could not check" 2 "$RC" "$WORK/ow-read.log" '^ERROR: E_OWNED_UNKNOWN: '

echo "== 6/6 every other subcommand fails closed when its input cannot be read ==============="
# Each accept case is above; each reject here is the "could not check" exit 2 of main_wrapper.
full
entry "scripts/cilium_bottlerocket.py:check-config"
run_real "$WORK/cfg-env.log" env -u CLUSTER_NAME python3 "$HELPER" check-config
check "REJECT check-config run without the config (common.sh not sourced), as could not check" 2 "$RC" "$WORK/cfg-env.log" '^ERROR: E_CONFIG_UNKNOWN: .*CLUSTER_NAME is not set'
# A tracked template that is missing from the tree.
while IFS='|' read -r sub file args; do
  [[ -n "$sub" ]] || continue
  entry "scripts/cilium_bottlerocket.py:$sub"
  tree "missing-$sub"; rm "$T/$file"
  # shellcheck disable=SC2086 # args is a fixed word list from the table below
  h "$WORK/miss-$sub.log" "SAMPLE=$T" "$sub" $args
  tag="$(python3 -c 'import sys; n = sys.argv[1]; n = n[6:] if n.startswith("check-") else n; print("E_" + n.upper().replace("-", "_"))' "$sub")"
  check "REJECT $sub when $file is missing from the tree, as could not check" 2 "$RC" "$WORK/miss-$sub.log" "^ERROR: ${tag}_UNKNOWN: "
done <<'CASES'
render-cluster|eksctl/cluster.yaml|
render-pod-identity|eksctl/pod-identity.yaml|
render-nodegroup|eksctl/nodegroups.yaml|sandbox
render-probe|deploy/probe/node-probe.yaml|--name cb-probe-sandbox-r1 --node ip-10-0-1-10.us-west-2.compute.internal
render-filler|deploy/probe/filler-pod.yaml|--name cb-filler-1-r1 --node ip-10-0-2-20.us-west-2.compute.internal
CASES
# An AWS read that fails with an error the check does not allow.
while IFS=';' read -r sub fail why; do
  [[ -n "$sub" ]] || continue
  entry "scripts/cilium_bottlerocket.py:${sub%% *}"
  # shellcheck disable=SC2086 # sub is the subcommand and its fixed arguments
  full; FAKE_FAIL="$fail" h "$WORK/aws-${sub%% *}.log" $sub
  tag="$(python3 -c 'import sys; n = sys.argv[1].split()[0]; n = n[6:] if n.startswith("check-") else n; print("E_" + n.upper().replace("-", "_"))' "$sub")"
  check "REJECT ${sub%% *} when $why fails, as could not check" 2 "$RC" "$WORK/aws-${sub%% *}.log" "^ERROR: ${tag}_UNKNOWN: "
done <<'CASES'
launch-template sandbox;aws|ec2 describe-launch-templates||RequestLimitExceeded;the launch template read
check-operator-role;aws|eks list-pod-identity-associations||ServerException;the Pod Identity association list
quota;aws|service-quotas get-service-quota||ServiceException;the Service Quotas read
check-names;aws|iam get-role||ServiceFailure;the IAM role read
CASES
# An input file that is not the expected JSON.
printf 'not json\n' > "$WORK/notjson.json"
printf '{"metadata": {}}\n' > "$WORK/nospec.json"
entry "scripts/cilium_bottlerocket.py:check-runtimeclass"
h "$WORK/crc-nj.log" check-runtimeclass "$WORK/notjson.json"
check "REJECT check-runtimeclass of an input that is not JSON, as could not check" 2 "$RC" "$WORK/crc-nj.log" '^ERROR: E_RUNTIMECLASS_UNKNOWN: '
entry "scripts/cilium_bottlerocket.py:preflight-daemonset"
h "$WORK/ds-nj.log" preflight-daemonset "$WORK/nospec.json"
check "REJECT preflight-daemonset of a DaemonSet with no pod spec, as could not check" 2 "$RC" "$WORK/ds-nj.log" '^ERROR: E_PREFLIGHT_DAEMONSET_UNKNOWN: '
entry "scripts/cilium_bottlerocket.py:check-system-ami"
h "$WORK/sa-nj.log" check-system-ami "$WORK/notjson.json" --ami ami-0fa00000000000001
check "REJECT check-system-ami of an input that is not JSON, as could not check" 2 "$RC" "$WORK/sa-nj.log" '^ERROR: E_SYSTEM_AMI_UNKNOWN: '
entry "scripts/cilium_bottlerocket.py:check-sandbox-ami"
python3 "$TESTLIB/fixture_aws_json.py" good "$WORK/aj2"
h "$WORK/sba-nj.log" check-sandbox-ami --images "$WORK/notjson.json" --uefi "$WORK/aj2/uefi.json" --snapshots "$WORK/aj2/snapshots.json"
check "REJECT check-sandbox-ami of an images input that is not JSON, as could not check" 2 "$RC" "$WORK/sba-nj.log" '^ERROR: E_SANDBOX_AMI_UNKNOWN: '
finish
