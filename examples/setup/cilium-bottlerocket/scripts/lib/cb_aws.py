"""AMI, quota, name, builder and clean-up inventory checks of scripts/cilium_bottlerocket.py.

Every lookup that fails is Unknown (exit 2), never "absent". A resource counts as the
run's only when it carries ManagedBy=cilium-bottlerocket-sample and RunId=<run ID>.
"""

import sys

from cb_base import (AMI_ID, OWNER_TAG, SYSTEM_AMI_NAME, Unknown, aws, int_setting, is_ours,
                     read_json, require, run_id, setting, state_get, tag_map)

GONE = {
    "instance": "InvalidInstanceID.NotFound", "volume": "InvalidVolume.NotFound",
    "security-group": "InvalidGroup.NotFound", "network-interface": "InvalidNetworkInterfaceID.NotFound",
    "launch-template": "InvalidLaunchTemplateId.NotFound", "image": "InvalidAMIID.NotFound",
    "snapshot": "InvalidSnapshot.NotFound", "iam-role": "NoSuchEntity", "instance-profile": "NoSuchEntity",
}


def describe(kind, ident):
    """(exists, tags, detail) of one resource, read by its ID or name."""
    calls = {
        "instance": (["ec2", "describe-instances", "--instance-ids", ident], lambda d: d["Reservations"][0]["Instances"][0]),
        "volume": (["ec2", "describe-volumes", "--volume-ids", ident], lambda d: d["Volumes"][0]),
        "security-group": (["ec2", "describe-security-groups", "--group-ids", ident], lambda d: d["SecurityGroups"][0]),
        "network-interface": (["ec2", "describe-network-interfaces", "--network-interface-ids", ident],
                              lambda d: d["NetworkInterfaces"][0]),
        "launch-template": (["ec2", "describe-launch-templates", "--launch-template-ids", ident], lambda d: d["LaunchTemplates"][0]),
        "image": (["ec2", "describe-images", "--image-ids", ident], lambda d: d["Images"][0]),
        "snapshot": (["ec2", "describe-snapshots", "--snapshot-ids", ident], lambda d: d["Snapshots"][0]),
        "iam-role": (["iam", "get-role", "--role-name", ident], lambda d: d["Role"]),
        "instance-profile": (["iam", "get-instance-profile", "--instance-profile-name", ident], lambda d: d["InstanceProfile"]),
    }
    require(kind in calls, f"unknown kind {kind}")
    args, pick = calls[kind]
    doc = aws(*args, allow=(GONE[kind],))
    if doc is None:
        return False, None, None
    try:
        item = pick(doc)
    except (KeyError, IndexError) as err:
        if kind == "image" and not doc.get("Images"):
            return False, None, None
        raise Unknown(f"{kind} {ident}: unexpected answer") from err
    if kind == "instance" and item["State"]["Name"] == "terminated":
        return False, item.get("Tags", []), item
    tags = item.get("Tags", [])
    if kind == "iam-role" and not tags:
        tags = aws("iam", "list-role-tags", "--role-name", ident).get("Tags", [])
    if kind == "instance-profile" and not tags:
        tags = aws("iam", "list-instance-profile-tags", "--instance-profile-name", ident).get("Tags", [])
    return True, tags, item


def cmd_recheck(args):
    """Read one resource's tags again just before a delete. 0 ours, 1 not ours, 3 gone, 2 unknown."""
    exists, tags, _ = describe(args.kind, args.ident)
    if not exists:
        print(f"{args.kind} {args.ident}: gone")
        sys.exit(3)
    require(is_ours(tags), f"{args.kind} {args.ident} is not tagged {OWNER_TAG[0]}={OWNER_TAG[1]} RunId={run_id()}")
    print(f"{args.kind} {args.ident}: ours")


def cmd_resolve_system_ami(_):
    value = aws("ssm", "get-parameter", "--name", setting("SYSTEM_AMI_SSM_PARAMETER"))["Parameter"]["Value"]
    require(AMI_ID.fullmatch(value) is not None, f"the SSM parameter holds {value!r}, not an AMI ID")
    print(value)


def cmd_check_system_ami(args):
    ami = args.ami or setting("SYSTEM_AMI_ID")
    doc = read_json(args.file) if args.file else aws("ec2", "describe-images", "--image-ids", ami)
    images = doc.get("Images", [])
    require(len(images) == 1, f"expected one image {ami}, got {len(images)}")
    img = images[0]
    checks = {"ImageId": ami, "Name": SYSTEM_AMI_NAME, "ImageOwnerAlias": "amazon", "Public": True,
              "State": "available", "Architecture": "x86_64"}
    wrong = [f"{k}={img.get(k)!r}" for k, v in checks.items() if img.get(k) != v]
    require(not wrong, f"system AMI {ami} is not the stock Bottlerocket v1.70.0 aws-k8s-1.36 image: " + ", ".join(wrong))
    print(f"system AMI {ami}: {img['Name']}, owner alias amazon")


def cmd_check_sandbox_ami(args):
    ami = args.ami or state_get("SANDBOX_AMI_ID")
    require(AMI_ID.fullmatch(ami or "") is not None, "no sandbox AMI ID to check")
    doc = read_json(args.images) if args.images else aws("ec2", "describe-images", "--owners", "self", "--image-ids", ami)
    images = doc.get("Images", [])
    require(len(images) == 1, f"expected one image {ami} of this account, got {len(images)}")
    img = images[0]
    tags = tag_map(img.get("Tags", [])) or {}
    want = {"Architecture": "x86_64", "VirtualizationType": "hvm", "EnaSupport": True, "SriovNetSupport": "simple",
            "ImdsSupport": "v2.0", "RootDeviceName": "/dev/xvda", "BootMode": "uefi-preferred",
            "State": "available", "Public": False}
    wrong = [f"{k}={img.get(k)!r}" for k, v in want.items() if img.get(k) != v]
    mappings = {m.get("DeviceName"): m.get("Ebs", {}) for m in img.get("BlockDeviceMappings", [])}
    if sorted(mappings) != ["/dev/xvda", "/dev/xvdb"] or any(e.get("VolumeType") != "gp3" or not e.get("SnapshotId")
                                                            for e in mappings.values()):
        wrong.append(f"block devices {sorted(mappings)} must be /dev/xvda and /dev/xvdb, gp3, from snapshots")
    if tags.get(OWNER_TAG[0]) != OWNER_TAG[1]:
        wrong.append(f"tag {OWNER_TAG[0]}={tags.get(OWNER_TAG[0])!r}")
    if not args.reuse and tags.get("RunId") != run_id():
        wrong.append(f"tag RunId={tags.get('RunId')!r}")
    if tags.get("SandboxSlots") != str(int_setting("SANDBOX_SLOTS", 1, 250)):
        wrong.append(f"tag SandboxSlots={tags.get('SandboxSlots')!r}, config SANDBOX_SLOTS={setting('SANDBOX_SLOTS')}")
    uefi = read_json(args.uefi) if args.uefi else aws("ec2", "describe-image-attribute", "--image-id", ami, "--attribute", "uefiData")
    if (uefi.get("UefiData") or {}).get("Value"):
        wrong.append("the AMI has UEFI variable data")
    snaps = [mappings[d].get("SnapshotId") for d in ("/dev/xvda", "/dev/xvdb") if d in mappings]
    recorded = state_get("SANDBOX_AMI_SNAPSHOT_IDS")
    if not args.reuse and recorded != ",".join(snaps):
        wrong.append(f"snapshots {snaps} differ from the state file {recorded!r}")
    sdoc = read_json(args.snapshots) if args.snapshots else (
        aws("ec2", "describe-snapshots", "--owner-ids", "self", "--snapshot-ids", *snaps) if snaps else {"Snapshots": []})
    for snap in sdoc.get("Snapshots", []):
        stags = tag_map(snap.get("Tags", [])) or {}
        if stags.get(OWNER_TAG[0]) != OWNER_TAG[1] or (not args.reuse and stags.get("RunId") != run_id()):
            wrong.append(f"snapshot {snap.get('SnapshotId')} lacks the sample tags")
    if len(sdoc.get("Snapshots", [])) != 2:
        wrong.append(f"{len(sdoc.get('Snapshots', []))} snapshots found, want 2")
    require(not wrong, f"sandbox AMI {ami}: " + "; ".join(wrong))
    print(f"sandbox AMI {ami}: x86_64, hvm, ENA, SR-IOV simple, IMDSv2, uefi-preferred with no UEFI data, "
          f"/dev/xvda and /dev/xvdb gp3, two tagged snapshots, SandboxSlots={tags['SandboxSlots']}")


def cmd_builder_gone(_):
    """After the build: the builder instance, its volumes, its security group, instance
    profile and role must not exist. A failed read fails the check."""
    items = [("instance", state_get("BUILDER_INSTANCE_ID")), ("security-group", state_get("BUILDER_SG_ID")),
             ("instance-profile", state_get("BUILDER_PROFILE_NAME")), ("iam-role", state_get("BUILDER_ROLE_NAME"))]
    items += [("volume", v) for v in state_get("BUILDER_VOLUME_IDS").split(",") if v]
    missing = [k for k, v in items if not v]
    if missing or not state_get("BUILDER_VOLUME_IDS"):
        raise Unknown(f"the state file does not name the builder {', '.join(missing) or 'volumes'}")
    left = []
    for kind, ident in items:
        exists, _, _ = describe(kind, ident)
        print(f"builder {kind} {ident}: {'STILL EXISTS' if exists else 'gone'}")
        if exists:
            left.append(f"{kind} {ident}")
    require(not left, "builder resources remain: " + ", ".join(left))


QUOTAS = [("vpc", "L-F678F1CE", "VPCs"), ("vpc", "L-A4707A72", "internet gateways"),
          ("vpc", "L-FE5A380F", "NAT gateways per zone"), ("ec2", "L-0263D0A3", "Elastic IP addresses")]


def cmd_quota(_):
    used = {
        "VPCs": len(aws("ec2", "describe-vpcs")["Vpcs"]),
        "internet gateways": len(aws("ec2", "describe-internet-gateways")["InternetGateways"]),
        # shortcut: counts every NAT gateway of the Region against the per-zone quota, which
        # can only over-count; count by zone if a Region is near the limit.
        "NAT gateways per zone": len(aws("ec2", "describe-nat-gateways", "--filter",
                                         "Name=state,Values=pending,available")["NatGateways"]),
        "Elastic IP addresses": len(aws("ec2", "describe-addresses")["Addresses"]),
    }
    short = []
    for service, code, name in QUOTAS:
        limit = aws("service-quotas", "get-service-quota", "--service-code", service, "--quota-code", code)["Quota"]["Value"]
        print(f"{name}: {used[name]} used of {int(limit)}")
        if used[name] + 1 > limit:
            short.append(name)
    require(not short, "no headroom for one more: " + ", ".join(short))


def cmd_check_names(_):
    """Each name the run will create is free, or already this run's."""
    cluster = setting("CLUSTER_NAME")
    found = []
    doc = aws("eks", "describe-cluster", "--name", cluster, allow=("ResourceNotFoundException",))
    if doc is not None and not is_ours(doc["cluster"].get("tags", {})):
        found.append(f"cluster {cluster}")
    stack = f"eksctl-{cluster}-cluster"
    doc = aws("cloudformation", "describe-stacks", "--stack-name", stack, allow=("ValidationError",))
    if doc is not None and not is_ours(doc["Stacks"][0].get("Tags", [])):
        found.append(f"stack {stack}")
    for name in (setting("SYSTEM_LT_NAME"), setting("SANDBOX_LT_NAME")):
        doc = aws("ec2", "describe-launch-templates", "--launch-template-names", name,
                  allow=("InvalidLaunchTemplateName.NotFoundException",))
        if doc is not None and not is_ours(doc["LaunchTemplates"][0].get("Tags", [])):
            found.append(f"launch template {name}")
    for kind, name in (("iam-role", setting("OPERATOR_ROLE_NAME")), ("iam-role", setting("BUILDER_ROLE_NAME")),
                       ("instance-profile", setting("BUILDER_PROFILE_NAME"))):
        exists, tags, _ = describe(kind, name)
        if exists and not is_ours(tags):
            found.append(f"{kind} {name}")
    sgs = aws("ec2", "describe-security-groups", "--filters",
              f"Name=group-name,Values={setting('BUILDER_SG_NAME')}")["SecurityGroups"]
    found += [f"security group {g['GroupId']} ({g['GroupName']})" for g in sgs if not is_ours(g.get("Tags", []))]
    images = aws("ec2", "describe-images", "--owners", "self", "--filters", f"Name=name,Values={setting('AMI_NAME')}")["Images"]
    found += [f"AMI {i['ImageId']} ({i['Name']})" for i in images if not is_ours(i.get("Tags", []))]
    require(not found, "names in use and not this run's: " + ", ".join(found)
            + ". Run ./clean.sh --run-id <the run that made them>, or set another CLUSTER_NAME")
    print(f"names: cluster {cluster}, its stack, both launch templates, the operator and builder roles, "
          "the builder instance profile and security group, and the AMI name are free or this run's")
