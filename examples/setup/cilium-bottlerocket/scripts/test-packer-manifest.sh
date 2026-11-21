#!/usr/bin/env bash
# test-packer-manifest.sh: proves every check of scripts/lib/packer_manifest.py both ways, the
# REAL file, on saved AWS CLI and Packer JSON (scripts/testlib/fixture_aws_json.py): one good
# document set is accepted, and each case changes one value and must be refused with its tag.
#   manifest   exactly one build and one AMI, of this run and this Packer run      (#281)
#   image      the registration values, no UEFI data, the tags and SandboxSlots    (#281)
#   snapshots  exactly two snapshots, from the OS and data volumes, tagged         (#281 M2)
#   builder    no key pair, no public IP, one SG with no inbound rule, IMDSv2      (#281)
#   volumes, sg, owned, gone   the builder's parts, their ownership and their absence after the build
#
#   examples/setup/cilium-bottlerocket/scripts/test-packer-manifest.sh
source "$(dirname "$0")/testlib/harness.sh"
PM="$SAMPLE_DIR_REAL/scripts/lib/packer_manifest.py"
need_file "$PM" "every packer_manifest.py case" || finish
FX="$TESTLIB/fixture_aws_json.py"
G="$WORK/good"
python3 "$FX" good "$G"
COMMON=(--run-id r1 --managed-by cilium-bottlerocket-sample)

# argv_for <command> <dir>: the arguments of a good call on the documents in <dir>.
argv_for() {
  local d="$2"
  case "$1" in
    manifest)  ARGV=(manifest "$d/manifest.json" --run-id r1 --region us-west-2 --uuid 00000000-0000-4000-8000-000000000001) ;;
    image)     ARGV=(image "$d/images.json" --uefi "$d/uefi.json" --ami ami-0fb00000000000001 "${COMMON[@]}" --slots 58) ;;
    snapshots) ARGV=(snapshots "$d/images.json" "$d/snapshots.json" --ami ami-0fb00000000000001 "${COMMON[@]}"
                 --os-volume vol-0fb00000000000003 --data-volume vol-0fb00000000000004 --slots 58) ;;
    builder)   ARGV=(builder "$d/instances.json" "$d/groups.json" --builder i-0fb00000000000001 --sg sg-0fc00000000000001
                 --profile cb-offline-test-r1-builder --subnet subnet-0fa00000000000001 "${COMMON[@]}") ;;
    volumes)   ARGV=(volumes "$d/volumes.json" --ids vol-0fb00000000000001,vol-0fb00000000000002,vol-0fb00000000000003,vol-0fb00000000000004
                 --builder i-0fb00000000000001 "${COMMON[@]}") ;;
    sg)        ARGV=(sg "$d/groups.json" --sg sg-0fc00000000000001 --vpc vpc-0fa00000000000001 "${COMMON[@]}") ;;
    owned-sg)  ARGV=(owned sg "$d/groups.json" "${COMMON[@]}") ;;
    owned-role) ARGV=(owned role "$d/role.json" "${COMMON[@]}") ;;
    owned-profile) ARGV=(owned profile "$d/profile.json" "${COMMON[@]}" --role cb-offline-test-r1-builder) ;;
  esac
}
n=0
# case_run <command> <file> <python change on d> <expected rc> <tag> <description> [<argv edit>]
case_run() {
  local cmd="$1" file="$2" code="$3" want="$4" tag="$5" why="$6" edit="${7:-}" d
  n=$((n + 1)); d="$WORK/case$n"
  cp -r "$G" "$d"
  [[ -z "$file" ]] || python3 "$FX" mutate "$G/$file" "$d/$file" "$code"
  argv_for "$cmd" "$d"
  [[ -z "$edit" ]] || eval "$edit"
  run_real "$WORK/case$n.log" python3 "$PM" "${ARGV[@]}"
  check "$why" "$want" "$RC" "$WORK/case$n.log" "^ERROR: $tag: "
}

echo "== 1/5 manifest ==================================================================="
entry scripts/lib/packer_manifest.py:manifest
argv_for manifest "$G"; run_real "$WORK/m-good.log" python3 "$PM" "${ARGV[@]}"
check "ACCEPT a manifest with one build, one AMI in us-west-2, run r1 and this Packer run" 0 "$RC" "$WORK/m-good.log" '^SANDBOX_AMI_ID=ami-0fb00000000000001$'
cover accept E_MANIFEST_LOCK E_MANIFEST_KEYS E_MANIFEST_COUNT E_MANIFEST_NAME E_MANIFEST_RUN_ID E_MANIFEST_UUID E_MANIFEST_ARTIFACT E_READ
while IFS='|' read -r file code want tag why; do
  [[ -n "$file" ]] || continue
  case_run manifest "$file" "$code" "$want" "$tag" "$why"
done <<'CASES'
manifest.json|d["builds"] = []|1|E_MANIFEST_COUNT|REJECT a manifest with zero builds
manifest.json|d["builds"].append(dict(d["builds"][0], artifact_id="us-west-2:ami-0fb00000000000009"))|1|E_MANIFEST_COUNT|REJECT a manifest with two builds (two AMIs)
manifest.json|d["extra"] = 1|1|E_MANIFEST_KEYS|REJECT a manifest with an unexpected top-level key
manifest.json|del d["builds"][0]["files"]|1|E_MANIFEST_KEYS|REJECT a build without one of its keys
manifest.json|d["builds"][0]["builder_type"] = "amazon-ebs"|1|E_MANIFEST_NAME|REJECT a build from another builder type
manifest.json|d["builds"][0]["custom_data"] = {"run_id": "r2"}|1|E_MANIFEST_RUN_ID|REJECT a manifest of another run
manifest.json|d["last_run_uuid"] = "00000000-0000-4000-8000-000000000009"|1|E_MANIFEST_UUID|REJECT a build whose run UUID is not the last run's
manifest.json|d["builds"][0]["artifact_id"] = "us-east-1:ami-0fb00000000000001"|1|E_MANIFEST_ARTIFACT|REJECT an AMI in another Region
manifest.json|d["builds"][0]["artifact_id"] = "us-west-2:ami-0fb00000000000001,us-west-2:ami-0fb00000000000002"|1|E_MANIFEST_ARTIFACT|REJECT an artifact with two AMIs
manifest.json|d["builds"] = "not a list"|2|E_READ|REJECT builds that is not a list, as unreadable (exit 2)
CASES
case_run manifest "" "" 1 E_MANIFEST_UUID "REJECT a manifest from another Packer run than --uuid" 'ARGV[7]=00000000-0000-4000-8000-000000000009'
n=$((n + 1)); cp -r "$G" "$WORK/case$n"; : > "$WORK/case$n/manifest.json.lock"; argv_for manifest "$WORK/case$n"
run_real "$WORK/case$n.log" python3 "$PM" "${ARGV[@]}"
check "REJECT a manifest whose lock file remains (Packer still writing)" 1 "$RC" "$WORK/case$n.log" '^ERROR: E_MANIFEST_LOCK: '
n=$((n + 1)); cp -r "$G" "$WORK/case$n"; printf '{"builds": [' > "$WORK/case$n/manifest.json"; argv_for manifest "$WORK/case$n"
run_real "$WORK/case$n.log" python3 "$PM" "${ARGV[@]}"
check "REJECT a manifest that is not valid JSON, as unreadable (exit 2)" 2 "$RC" "$WORK/case$n.log" '^ERROR: E_READ: '
n=$((n + 1)); cp -r "$G" "$WORK/case$n"; printf '{"builds": [], "builds": [], "last_run_uuid": ""}' > "$WORK/case$n/manifest.json"; argv_for manifest "$WORK/case$n"
run_real "$WORK/case$n.log" python3 "$PM" "${ARGV[@]}"
check "REJECT a manifest with a key twice, as unreadable (exit 2)" 2 "$RC" "$WORK/case$n.log" '^ERROR: E_READ: '

echo "== 2/5 image ======================================================================"
entry scripts/lib/packer_manifest.py:image
argv_for image "$G"; run_real "$WORK/i-good.log" python3 "$PM" "${ARGV[@]}"
check "ACCEPT the registered AMI: x86_64, hvm, ENA, SR-IOV simple, IMDSv2, uefi-preferred, no UEFI data, two gp3 mappings, tags, SandboxSlots 58" 0 "$RC" "$WORK/i-good.log" '^ROOT_SNAPSHOT_ID=snap-0fb00000000000001$'
cover accept E_INPUT_SANDBOX_SLOTS E_IMAGE_COUNT E_IMAGE_ID E_IMAGE_STATE E_IMAGE_PUBLIC E_IMAGE_ARCHITECTURE E_IMAGE_VIRTUALIZATION \
  E_IMAGE_ENA E_IMAGE_SRIOV E_IMAGE_IMDS E_IMAGE_ROOT E_IMAGE_BOOT_MODE E_IMAGE_TPM E_IMAGE_TAGS E_IMAGE_SLOTS E_IMAGE_UEFI_DATA E_IMAGE_MAPPINGS
while IFS='|' read -r file code want tag why; do
  [[ -n "$file" ]] || continue
  case_run image "$file" "$code" "$want" "$tag" "$why"
done <<'CASES'
images.json|d["Images"].append(dict(d["Images"][0]))|1|E_IMAGE_COUNT|REJECT a read with two images
images.json|d["Images"][0]["ImageId"] = "ami-0fb00000000000009"|1|E_IMAGE_ID|REJECT another AMI ID
images.json|d["Images"][0]["State"] = "pending"|1|E_IMAGE_STATE|REJECT an AMI that is not available
images.json|d["Images"][0]["Public"] = True|1|E_IMAGE_PUBLIC|REJECT a public AMI
images.json|d["Images"][0]["Architecture"] = "arm64"|1|E_IMAGE_ARCHITECTURE|REJECT an arm64 AMI
images.json|d["Images"][0]["VirtualizationType"] = "paravirtual"|1|E_IMAGE_VIRTUALIZATION|REJECT a paravirtual AMI
images.json|d["Images"][0]["EnaSupport"] = False|1|E_IMAGE_ENA|REJECT an AMI without ENA
images.json|del d["Images"][0]["SriovNetSupport"]|1|E_IMAGE_SRIOV|REJECT an AMI without SR-IOV simple
images.json|d["Images"][0]["ImdsSupport"] = None|1|E_IMAGE_IMDS|REJECT an AMI that does not require IMDSv2
images.json|d["Images"][0]["RootDeviceName"] = "/dev/xvdf"|1|E_IMAGE_ROOT|REJECT a root device other than /dev/xvda
images.json|d["Images"][0]["BootMode"] = "uefi"|1|E_IMAGE_BOOT_MODE|REJECT boot mode uefi (the sample registers uefi-preferred)
images.json|d["Images"][0]["TpmSupport"] = "v2.0"|1|E_IMAGE_TPM|REJECT an AMI with TPM support set
images.json|d["Images"][0]["Tags"][1]["Value"] = "r2"|1|E_IMAGE_TAGS|REJECT an AMI of another run (changed RunId tag)
images.json|d["Images"][0]["Tags"][0]["Value"] = "someone-else"|1|E_IMAGE_TAGS|REJECT an AMI of another owner (changed ManagedBy tag)
images.json|d["Images"][0]["Tags"][2]["Value"] = "57"|1|E_IMAGE_SLOTS|REJECT an AMI whose SandboxSlots tag is not the config value
uefi.json|d["UefiData"] = {"Value": "QUJD"}|1|E_IMAGE_UEFI_DATA|REJECT an AMI with UEFI variable data
uefi.json|d["ImageId"] = "ami-0fb00000000000009"|2|E_READ|REJECT a UEFI read for another AMI, as unreadable (exit 2)
images.json|d["Images"][0]["BlockDeviceMappings"].append({"DeviceName": "/dev/xvdc", "Ebs": {"SnapshotId": "snap-0fb00000000000003", "VolumeType": "gp3"}})|1|E_IMAGE_MAPPINGS|REJECT a third EBS mapping (the builder work volume kept)
images.json|d["Images"][0]["BlockDeviceMappings"].append({"DeviceName": "/dev/sdb", "VirtualName": "ephemeral0"})|1|E_IMAGE_MAPPINGS|REJECT an instance store mapping
images.json|d["Images"][0]["BlockDeviceMappings"][1]["Ebs"]["VolumeType"] = "gp2"|1|E_IMAGE_MAPPINGS|REJECT a data mapping that is not gp3
images.json|d["Images"][0]["BlockDeviceMappings"][1]["Ebs"]["SnapshotId"] = "snap-0fb00000000000001"|1|E_IMAGE_MAPPINGS|REJECT one snapshot used for both mappings
CASES
for s in 0 251 abc 058 ""; do
  case_run image "" "" 1 E_INPUT_SANDBOX_SLOTS "REJECT --slots '$s' (not an integer from 1 to 250)" "ARGV[\${#ARGV[@]}-1]='$s'"
done
for s in 1 250; do
  n=$((n + 1)); cp -r "$G" "$WORK/case$n"
  python3 "$FX" mutate "$G/images.json" "$WORK/case$n/images.json" "d['Images'][0]['Tags'][2]['Value'] = '$s'"
  argv_for image "$WORK/case$n"; ARGV[${#ARGV[@]}-1]="$s"
  run_real "$WORK/case$n.log" python3 "$PM" "${ARGV[@]}"
  check "ACCEPT --slots $s with a matching SandboxSlots tag (the ends of 1 to 250)" 0 "$RC" "$WORK/case$n.log" '^DATA_SNAPSHOT_ID='
done

echo "== 3/5 snapshots ==================================================================="
entry scripts/lib/packer_manifest.py:snapshots
argv_for snapshots "$G"; run_real "$WORK/s-good.log" python3 "$PM" "${ARGV[@]}"
check "ACCEPT exactly two completed snapshots, root from the OS volume and data from the data volume, tagged" 0 "$RC" "$WORK/s-good.log" \
  '^SANDBOX_AMI_SNAPSHOT_IDS=snap-0fb00000000000001,snap-0fb00000000000002$'
cover accept E_INPUT E_SNAP_COUNT E_SNAP_VOLUME E_SNAP_STATE E_SNAP_TAGS E_SNAP_SLOTS
while IFS='|' read -r file code want tag why; do
  [[ -n "$file" ]] || continue
  case_run snapshots "$file" "$code" "$want" "$tag" "$why"
done <<'CASES'
images.json|d["Images"][0]["BlockDeviceMappings"].append({"DeviceName": "/dev/xvdc", "Ebs": {"SnapshotId": "snap-0fb00000000000003", "VolumeType": "gp3"}})|1|E_SNAP_COUNT|REJECT an AMI with three snapshots (a builder volume was not omitted)
images.json|d["Images"][0]["BlockDeviceMappings"].pop()|1|E_SNAP_COUNT|REJECT an AMI with one snapshot
snapshots.json|d["Snapshots"].append({"SnapshotId": "snap-0fb00000000000003", "VolumeId": VOLS["/dev/xvda"], "State": "completed", "Tags": []})|1|E_SNAP_COUNT|REJECT a snapshot read that is not exactly the AMI's two
snapshots.json|d["Snapshots"][0]["VolumeId"] = VOLS["/dev/xvda"]|1|E_SNAP_VOLUME|REJECT a root snapshot made from the builder root volume
snapshots.json|d["Snapshots"][1]["State"] = "pending"|1|E_SNAP_STATE|REJECT a snapshot that is not completed
snapshots.json|d["Snapshots"][1]["Tags"] = []|1|E_SNAP_TAGS|REJECT an untagged snapshot
snapshots.json|d["Snapshots"][0]["Tags"] = [t for t in d["Snapshots"][0]["Tags"] if t["Key"] != "SandboxSlots"]|1|E_SNAP_SLOTS|REJECT a snapshot without the SandboxSlots tag
images.json|d["Images"][0]["ImageId"] = "ami-0fb00000000000009"|1|E_IMAGE_ID|REJECT a snapshot check on another AMI
CASES
case_run snapshots "" "" 1 E_INPUT "REJECT the same volume as --os-volume and --data-volume" 'ARGV[10]=vol-0fb00000000000004'

echo "== 4/5 builder, volumes, security group ============================================="
entry scripts/lib/packer_manifest.py:builder
argv_for builder "$G"; run_real "$WORK/b-good.log" python3 "$PM" "${ARGV[@]}"
check "ACCEPT the builder: no key pair, no public IP, one SG with no inbound rule, the profile, IMDSv2 hop 1, the subnet, four volumes" 0 "$RC" "$WORK/b-good.log" \
  '^builder key_name=none public_ip=none inbound_rules=0 http_tokens=required hop_limit=1$'
cover accept E_BUILDER_COUNT E_BUILDER_KEY E_BUILDER_PUBLIC_IP E_BUILDER_SG E_BUILDER_PROFILE E_BUILDER_IMDS E_BUILDER_SUBNET E_BUILDER_TAGS E_BUILDER_VOLUMES E_BUILDER_INBOUND
while IFS='|' read -r file code want tag why; do
  [[ -n "$file" ]] || continue
  case_run builder "$file" "$code" "$want" "$tag" "$why"
done <<'CASES'
instances.json|d["Reservations"][0]["Instances"].append({"InstanceId": "i-0fb00000000000002"})|1|E_BUILDER_COUNT|REJECT a read with two instances
instances.json|d["Reservations"][0]["Instances"][0]["KeyName"] = "a-key"|1|E_BUILDER_KEY|REJECT a builder with an SSH key pair
instances.json|d["Reservations"][0]["Instances"][0]["PublicIpAddress"] = "198.51.100.7"|1|E_BUILDER_PUBLIC_IP|REJECT a builder with a public IP address
instances.json|d["Reservations"][0]["Instances"][0]["NetworkInterfaces"][0]["Association"] = {"PublicIp": "198.51.100.7"}|1|E_BUILDER_PUBLIC_IP|REJECT a builder interface with a public IP address
instances.json|d["Reservations"][0]["Instances"][0]["SecurityGroups"].append({"GroupId": "sg-0fc00000000000009"})|1|E_BUILDER_SG|REJECT a builder with a second security group
instances.json|d["Reservations"][0]["Instances"][0]["IamInstanceProfile"]["Arn"] = d["Reservations"][0]["Instances"][0]["IamInstanceProfile"]["Arn"].replace("r1-builder", "admin")|1|E_BUILDER_PROFILE|REJECT a builder with another instance profile
instances.json|d["Reservations"][0]["Instances"][0]["MetadataOptions"]["HttpTokens"] = "optional"|1|E_BUILDER_IMDS|REJECT a builder with IMDSv1 allowed
instances.json|d["Reservations"][0]["Instances"][0]["MetadataOptions"]["HttpPutResponseHopLimit"] = 2|1|E_BUILDER_IMDS|REJECT a builder with metadata hop limit 2
instances.json|d["Reservations"][0]["Instances"][0]["SubnetId"] = "subnet-0fa00000000000009"|1|E_BUILDER_SUBNET|REJECT a builder in another subnet
instances.json|d["Reservations"][0]["Instances"][0]["Tags"] = []|1|E_BUILDER_TAGS|REJECT an untagged builder
instances.json|d["Reservations"][0]["Instances"][0]["BlockDeviceMappings"].pop()|1|E_BUILDER_VOLUMES|REJECT a builder with three volumes
groups.json|d["SecurityGroups"][0]["IpPermissions"] = [{"IpProtocol": "tcp", "FromPort": 22, "ToPort": 22, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}]|1|E_BUILDER_INBOUND|REJECT a builder security group with an inbound rule
CASES
entry scripts/lib/packer_manifest.py:volumes
argv_for volumes "$G"; run_real "$WORK/v-good.log" python3 "$PM" "${ARGV[@]}"
check "ACCEPT the builder's four gp3 volumes, attached to it and tagged" 0 "$RC" "$WORK/v-good.log" '^builder-volumes count=4'
cover accept E_INPUT E_BUILDER_VOLUMES E_BUILDER_VOLUME_TAGS
while IFS='|' read -r file code want tag why; do
  [[ -n "$file" ]] || continue
  case_run volumes "$file" "$code" "$want" "$tag" "$why"
done <<'CASES'
volumes.json|d["Volumes"].pop()|1|E_BUILDER_VOLUMES|REJECT a volume read that is not the builder's four
volumes.json|d["Volumes"][2]["Attachments"] = [{"InstanceId": "i-0fb00000000000009"}]|1|E_BUILDER_VOLUMES|REJECT a volume attached to another instance
volumes.json|d["Volumes"][3]["VolumeType"] = "io2"|1|E_BUILDER_VOLUMES|REJECT a builder volume that is not gp3
volumes.json|d["Volumes"][1]["Tags"] = [{"Key": "ManagedBy", "Value": "someone-else"}]|1|E_BUILDER_VOLUME_TAGS|REJECT a builder volume of another owner
CASES
case_run volumes "" "" 1 E_INPUT "REJECT --ids that are not four volume IDs" 'ARGV[3]=vol-0fb00000000000001,vol-0fb00000000000002'
entry scripts/lib/packer_manifest.py:sg
argv_for sg "$G"; run_real "$WORK/g-good.log" python3 "$PM" "${ARGV[@]}"
check "ACCEPT the builder security group: no inbound rule, one egress rule TCP 443, tagged" 0 "$RC" "$WORK/g-good.log" '^builder-sg inbound_rules=0 egress=tcp/443'
cover accept E_SG_COUNT E_SG_ID E_SG_INBOUND E_SG_EGRESS E_SG_TAGS
while IFS='|' read -r file code want tag why; do
  [[ -n "$file" ]] || continue
  case_run sg "$file" "$code" "$want" "$tag" "$why"
done <<'CASES'
groups.json|d["SecurityGroups"] = []|1|E_SG_COUNT|REJECT a read with no security group
groups.json|d["SecurityGroups"][0]["VpcId"] = "vpc-0fa00000000000009"|1|E_SG_ID|REJECT a security group in another VPC
groups.json|d["SecurityGroups"][0]["IpPermissions"] = [{"IpProtocol": "-1"}]|1|E_SG_INBOUND|REJECT a security group with an inbound rule
groups.json|d["SecurityGroups"][0]["IpPermissionsEgress"].append({"IpProtocol": "-1", "IpRanges": [{"CidrIp": "0.0.0.0/0"}]})|1|E_SG_EGRESS|REJECT a security group that keeps the default all-traffic egress rule
groups.json|d["SecurityGroups"][0]["IpPermissionsEgress"][0]["FromPort"] = 80|1|E_SG_EGRESS|REJECT an egress rule on another port
groups.json|d["SecurityGroups"][0]["IpPermissionsEgress"][0]["Ipv6Ranges"] = [{"CidrIpv6": "::/0"}]|1|E_SG_EGRESS|REJECT an egress rule that also opens IPv6
groups.json|d["SecurityGroups"][0]["Tags"] = []|1|E_SG_TAGS|REJECT an untagged security group
CASES

echo "== 5/5 ownership read-back and absence after the build ==============================="
entry scripts/lib/packer_manifest.py:owned
for k in sg role profile; do
  argv_for "owned-$k" "$G"; run_real "$WORK/o-$k.log" python3 "$PM" "${ARGV[@]}"
  check "ACCEPT the builder $k as this run's (ownership read again before its delete)" 0 "$RC" "$WORK/o-$k.log" "^$k=owned\$"
  cover accept E_OWNED E_INPUT
done
case_run owned-role role.json 'd["Role"]["Tags"][1]["Value"] = "r2"' 1 E_OWNED "REJECT a builder role whose RunId changed since discovery (changed owner)"
case_run owned-sg groups.json 'd["SecurityGroups"][0]["Tags"][0]["Value"] = "someone-else"' 1 E_OWNED "REJECT a builder security group whose owner changed since discovery"
case_run owned-profile profile.json 'd["InstanceProfile"]["Roles"] = [{"RoleName": "another-role"}]' 1 E_OWNED "REJECT an instance profile that holds another role"
case_run owned-role "" "" 1 E_INPUT "REJECT an unknown kind" 'ARGV[1]=bucket'
entry scripts/lib/packer_manifest.py:gone
printf 'An error occurred (InvalidInstanceID.NotFound) when calling the DescribeInstances operation\n' > "$WORK/nf-instance.err"
printf 'An error occurred (InvalidVolume.NotFound) when calling the DescribeVolumes operation\n' > "$WORK/nf-volume.err"
printf 'An error occurred (InvalidGroup.NotFound) when calling the DescribeSecurityGroups operation\n' > "$WORK/nf-sg.err"
printf 'An error occurred (NoSuchEntity) when calling the GetInstanceProfile operation\n' > "$WORK/nf-profile.err"
printf 'An error occurred (NoSuchEntity) when calling the GetRole operation\n' > "$WORK/nf-role.err"
printf 'An error occurred (AccessDenied) when calling the GetRole operation\n' > "$WORK/denied.err"
: > "$WORK/empty.err"
while IFS='|' read -r kind rc out err want rx why; do
  [[ -n "$kind" ]] || continue
  run_real "$WORK/gone-$kind-$rc-$want.log" python3 "$PM" gone "$kind" "$rc" "$G/$out" "$WORK/$err"
  check "$why" "$want" "$RC" "$WORK/gone-$kind-$rc-$want.log" "$rx"
  [[ "$want" == 0 ]] && cover accept E_LEFTOVER E_READ E_INPUT
done <<'CASES'
instance|0|instances-terminated.json|empty.err|0|^instance=terminated$|ACCEPT a builder instance that reads terminated
instance|254|instances-terminated.json|nf-instance.err|0|^instance=absent$|ACCEPT a builder instance that is not found
volume|254|empty-volumes.json|nf-volume.err|0|^volume=absent$|ACCEPT builder volumes that are not found
sg|254|empty-groups.json|nf-sg.err|0|^sg=absent$|ACCEPT a builder security group that is not found
profile|254|profile.json|nf-profile.err|0|^profile=absent$|ACCEPT a builder instance profile that is not found
role|254|role.json|nf-role.err|0|^role=absent$|ACCEPT a builder role that is not found
instance|0|instances-running.json|empty.err|1|^ERROR: E_LEFTOVER: |REJECT a builder instance that still runs
volume|0|volumes.json|empty.err|1|^ERROR: E_LEFTOVER: |REJECT a builder volume that remains
sg|0|groups.json|empty.err|1|^ERROR: E_LEFTOVER: |REJECT a builder security group that remains
profile|0|profile.json|empty.err|1|^ERROR: E_LEFTOVER: |REJECT a builder instance profile that remains
role|0|role.json|empty.err|1|^ERROR: E_LEFTOVER: |REJECT a builder role that remains
role|254|role.json|denied.err|2|^ERROR: E_READ: |REJECT a read that failed with another error (AccessDenied) as could not determine, never absent
bucket|254|role.json|nf-role.err|1|^ERROR: E_INPUT: |REJECT an unknown kind
role|x|role.json|nf-role.err|1|^ERROR: E_INPUT: |REJECT an exit code that is not a number
CASES
finish
