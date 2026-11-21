#!/usr/bin/env python3
"""packer_manifest.py: checks of the Packer AMI build, each on saved AWS CLI JSON.

  manifest  <manifest.json> --run-id R --region G [--uuid U]
  image     <describe-images.json> --uefi <describe-image-attribute.json> --ami A --run-id R
            --managed-by O --slots N
  snapshots <describe-images.json> <describe-snapshots.json> --ami A --run-id R --managed-by O
            --os-volume V1 --data-volume V2 --slots N
  builder   <describe-instances.json> <describe-security-groups.json> --builder I --sg G
            --profile P --subnet S --run-id R --managed-by O
  volumes   <describe-volumes.json> --ids V1,V2,V3,V4 --builder I --run-id R --managed-by O
  sg        <describe-security-groups.json> --sg G --vpc V --run-id R --managed-by O
  owned     <sg|role|profile> <read.json> --run-id R --managed-by O [--role ROLE]
  gone      <kind> <rc> <stdout-file> <stderr-file>     kind: instance volume sg profile role

The AMI ID comes from the manifest only, never from the build log. Each command prints
KEY=value lines. Exit 0 accepted; 1 refused (one line: ERROR: E_<TAG>: <text>); 2 an input is
unreadable or malformed.
"""
import argparse
import json
import os
import re
import sys

sys.dont_write_bytecode = True

BUILD_KEYS = {"name", "builder_type", "build_time", "files", "artifact_id", "packer_run_uuid", "custom_data"}
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
AMI = r"ami-[0-9a-f]{8,17}"
SNAP = re.compile(r"snap-[0-9a-f]{8,17}")
VOL = re.compile(r"vol-[0-9a-f]{8,17}")
DEVICES = ["/dev/xvda", "/dev/xvdb", "/dev/xvdc", "/dev/xvdf"]
NOT_FOUND = {
    "instance": "InvalidInstanceID.NotFound",
    "volume": "InvalidVolume.NotFound",
    "sg": "InvalidGroup.NotFound",
    "profile": "NoSuchEntity",
    "role": "NoSuchEntity",
    "image": "InvalidAMIID.NotFound",
    "snapshot": "InvalidSnapshot.NotFound",
}


class Refused(Exception):
    def __init__(self, tag, text, code=1):
        super().__init__(f"ERROR: {tag}: {text}")
        self.code = code


def need(cond, tag, text="", code=1):
    if not cond:
        raise Refused(tag, text, code)


def load(path, limit=4 * 1024 * 1024):
    try:
        with open(path, "rb") as f:
            raw = f.read(limit + 1)
    except OSError as e:
        raise Refused("E_READ", f"{path}: {e.strerror}", 2)
    need(len(raw) <= limit, "E_READ", f"{path} is too large", 2)
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=no_duplicates)
    except (ValueError, UnicodeDecodeError) as e:
        raise Refused("E_READ", f"{path} is not valid JSON ({e})", 2)


def no_duplicates(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise ValueError(f"duplicate key {k}")
        d[k] = v
    return d


def tags(items):
    out = {}
    for t in items or []:
        need(isinstance(t, dict) and isinstance(t.get("Key"), str), "E_READ", "a tag is malformed", 2)
        out[t["Key"]] = t.get("Value")
    return out


def owned(t, a, tag):
    need(t.get("ManagedBy") == a.managed_by and t.get("RunId") == a.run_id, tag,
         f"ManagedBy={t.get('ManagedBy')!r} RunId={t.get('RunId')!r}, expected {a.managed_by!r} {a.run_id!r}")


def slots_arg(a):
    need(re.fullmatch(r"[1-9][0-9]{0,2}", a.slots) is not None and int(a.slots) <= 250, "E_INPUT_SANDBOX_SLOTS",
         f"--slots must be an integer from 1 to 250, got {a.slots!r}")


def one(listing, key, tag):
    items = listing.get(key) if isinstance(listing, dict) else None
    need(isinstance(items, list), "E_READ", f"no {key} list", 2)
    need(len(items) == 1, tag, f"{len(items)} {key}, expected exactly one")
    need(isinstance(items[0], dict), "E_READ", f"{key}[0] is not an object", 2)
    return items[0]


def cmd_manifest(a):
    need(not os.path.lexists(a.path + ".lock"), "E_MANIFEST_LOCK", "a manifest lock file remains")
    m = load(a.path, 64 * 1024)
    need(isinstance(m, dict) and set(m) == {"builds", "last_run_uuid"}, "E_MANIFEST_KEYS", "top-level keys")
    b = m["builds"]
    need(isinstance(b, list), "E_READ", "builds is not a list", 2)
    need(len(b) == 1, "E_MANIFEST_COUNT", f"{len(b)} builds, expected exactly one")
    b = b[0]
    need(isinstance(b, dict) and set(b) == BUILD_KEYS, "E_MANIFEST_KEYS", "build keys")
    need(b["name"] == "bottlerocket" and b["builder_type"] == "amazon-ebssurrogate", "E_MANIFEST_NAME",
         f"{b['name']!r} {b['builder_type']!r}")
    need(b["custom_data"] == {"run_id": a.run_id}, "E_MANIFEST_RUN_ID", f"custom_data {b['custom_data']!r}")
    uuid = b["packer_run_uuid"]
    need(isinstance(uuid, str) and UUID.fullmatch(uuid) is not None and uuid == m["last_run_uuid"],
         "E_MANIFEST_UUID", "packer_run_uuid")
    need(a.uuid is None or uuid == a.uuid, "E_MANIFEST_UUID", "not this Packer run")
    art = b["artifact_id"] if isinstance(b["artifact_id"], str) else ""
    mm = re.fullmatch(re.escape(a.region) + ":(" + AMI + ")", art)
    need(mm is not None, "E_MANIFEST_ARTIFACT", f"artifact_id {art!r}: expected one AMI in {a.region}")
    print(f"SANDBOX_AMI_ID={mm.group(1)}")
    print(f"PACKER_RUN_UUID={uuid}")


def image_maps(im):
    maps = im.get("BlockDeviceMappings")
    need(isinstance(maps, list), "E_READ", "no BlockDeviceMappings", 2)
    ebs = {}
    for x in maps:
        need(isinstance(x, dict), "E_READ", "a mapping is malformed", 2)
        need("Ebs" in x and isinstance(x["Ebs"], dict), "E_IMAGE_MAPPINGS", f"{x.get('DeviceName')} is not an EBS mapping")
        need(x.get("DeviceName") not in ebs, "E_IMAGE_MAPPINGS", f"{x.get('DeviceName')} twice")
        ebs[x.get("DeviceName")] = x["Ebs"]
    need(sorted(ebs) == ["/dev/xvda", "/dev/xvdb"], "E_IMAGE_MAPPINGS", f"mappings {sorted(ebs)}, expected /dev/xvda and /dev/xvdb")
    for d, e in ebs.items():
        need(e.get("VolumeType") == "gp3", "E_IMAGE_MAPPINGS", f"{d} is {e.get('VolumeType')}, not gp3")
        need(isinstance(e.get("SnapshotId"), str) and SNAP.fullmatch(e["SnapshotId"]), "E_IMAGE_MAPPINGS", f"{d} has no snapshot")
    need(ebs["/dev/xvda"]["SnapshotId"] != ebs["/dev/xvdb"]["SnapshotId"], "E_IMAGE_MAPPINGS", "one snapshot twice")
    return ebs


def cmd_image(a):
    slots_arg(a)
    im = one(load(a.images), "Images", "E_IMAGE_COUNT")
    expect = [
        ("ImageId", a.ami, "E_IMAGE_ID"), ("State", "available", "E_IMAGE_STATE"),
        ("Public", False, "E_IMAGE_PUBLIC"), ("Architecture", "x86_64", "E_IMAGE_ARCHITECTURE"),
        ("VirtualizationType", "hvm", "E_IMAGE_VIRTUALIZATION"), ("EnaSupport", True, "E_IMAGE_ENA"),
        ("SriovNetSupport", "simple", "E_IMAGE_SRIOV"), ("ImdsSupport", "v2.0", "E_IMAGE_IMDS"),
        ("RootDeviceName", "/dev/xvda", "E_IMAGE_ROOT"), ("RootDeviceType", "ebs", "E_IMAGE_ROOT"),
        ("BootMode", "uefi-preferred", "E_IMAGE_BOOT_MODE"),
    ]
    for key, want, tag in expect:
        need(im.get(key) == want, tag, f"{key} is {im.get(key)!r}, expected {want!r}")
    need("TpmSupport" not in im, "E_IMAGE_TPM", "TpmSupport is set")
    t = tags(im.get("Tags"))
    owned(t, a, "E_IMAGE_TAGS")
    need(t.get("SandboxSlots") == a.slots, "E_IMAGE_SLOTS", f"SandboxSlots={t.get('SandboxSlots')!r}, expected {a.slots!r}")
    u = load(a.uefi)
    need(isinstance(u, dict) and u.get("ImageId") == a.ami, "E_READ", "the uefiData read is not for this AMI", 2)
    ud = u.get("UefiData")
    value = ud.get("Value") if isinstance(ud, dict) else ud
    need(value in (None, ""), "E_IMAGE_UEFI_DATA", "the AMI has UEFI variable data")
    ebs = image_maps(im)
    print(f"ROOT_SNAPSHOT_ID={ebs['/dev/xvda']['SnapshotId']}")
    print(f"DATA_SNAPSHOT_ID={ebs['/dev/xvdb']['SnapshotId']}")


def cmd_snapshots(a):
    slots_arg(a)
    need(VOL.fullmatch(a.os_volume) and VOL.fullmatch(a.data_volume) and a.os_volume != a.data_volume,
         "E_INPUT", "--os-volume and --data-volume must be two volume IDs")
    im = one(load(a.images), "Images", "E_IMAGE_COUNT")
    need(im.get("ImageId") == a.ami, "E_IMAGE_ID", "another AMI")
    maps = im.get("BlockDeviceMappings")
    need(isinstance(maps, list), "E_READ", "no BlockDeviceMappings", 2)
    ids = [x.get("Ebs", {}).get("SnapshotId") for x in maps if isinstance(x, dict) and isinstance(x.get("Ebs"), dict)]
    need(len(ids) == 2 and len(set(ids)) == 2, "E_SNAP_COUNT", f"{len(ids)} snapshots, expected exactly two")
    ebs = image_maps(im)
    sl = load(a.snaps).get("Snapshots")
    need(isinstance(sl, list), "E_READ", "no Snapshots list", 2)
    by_id = {s.get("SnapshotId"): s for s in sl if isinstance(s, dict)}
    need(sorted(by_id) == sorted(ids) and len(sl) == 2, "E_SNAP_COUNT", "DescribeSnapshots is not the AMI's two snapshots")
    for dev, vol in (("/dev/xvda", a.os_volume), ("/dev/xvdb", a.data_volume)):
        s = by_id[ebs[dev]["SnapshotId"]]
        need(s.get("VolumeId") == vol, "E_SNAP_VOLUME", f"{dev} snapshot is from {s.get('VolumeId')}, expected {vol}")
        need(s.get("State") == "completed", "E_SNAP_STATE", f"{s.get('SnapshotId')} is {s.get('State')}")
        t = tags(s.get("Tags"))
        owned(t, a, "E_SNAP_TAGS")
        need(t.get("SandboxSlots") == a.slots, "E_SNAP_SLOTS", f"{s.get('SnapshotId')} SandboxSlots={t.get('SandboxSlots')!r}")
    print(f"SANDBOX_AMI_SNAPSHOT_IDS={ebs['/dev/xvda']['SnapshotId']},{ebs['/dev/xvdb']['SnapshotId']}")


def cmd_builder(a):
    res = load(a.instances).get("Reservations")
    need(isinstance(res, list), "E_READ", "no Reservations", 2)
    insts = [i for r in res if isinstance(r, dict) for i in (r.get("Instances") or [])]
    need(len(insts) == 1 and isinstance(insts[0], dict), "E_BUILDER_COUNT", f"{len(insts)} instances, expected one")
    i = insts[0]
    need(i.get("InstanceId") == a.builder, "E_BUILDER_COUNT", "another instance")
    need(not i.get("KeyName"), "E_BUILDER_KEY", f"key pair {i.get('KeyName')!r}")
    need(not i.get("PublicIpAddress"), "E_BUILDER_PUBLIC_IP", "the builder has a public IP address")
    for n in i.get("NetworkInterfaces") or []:
        need(not (n.get("Association") or {}).get("PublicIp"), "E_BUILDER_PUBLIC_IP", "an interface has a public IP address")
    sgs = [g.get("GroupId") for g in i.get("SecurityGroups") or []]
    need(sgs == [a.sg], "E_BUILDER_SG", f"security groups {sgs}, expected [{a.sg}]")
    arn = (i.get("IamInstanceProfile") or {}).get("Arn", "")
    need(re.fullmatch(r"arn:aws[a-z-]*:iam::[0-9]{12}:instance-profile/" + re.escape(a.profile), arn) is not None,
         "E_BUILDER_PROFILE", "the builder does not have the run instance profile")
    md = i.get("MetadataOptions") or {}
    need(md.get("HttpTokens") == "required" and md.get("HttpPutResponseHopLimit") == 1, "E_BUILDER_IMDS",
         f"HttpTokens={md.get('HttpTokens')!r} hop limit={md.get('HttpPutResponseHopLimit')!r}")
    need(i.get("SubnetId") == a.subnet, "E_BUILDER_SUBNET", f"subnet {i.get('SubnetId')!r}")
    owned(tags(i.get("Tags")), a, "E_BUILDER_TAGS")
    vols = {}
    for m in i.get("BlockDeviceMappings") or []:
        v = (m.get("Ebs") or {}).get("VolumeId")
        need(isinstance(v, str) and VOL.fullmatch(v), "E_BUILDER_VOLUMES", f"{m.get('DeviceName')} has no volume")
        vols[m.get("DeviceName")] = v
    need(sorted(vols) == DEVICES and len(set(vols.values())) == 4, "E_BUILDER_VOLUMES",
         f"devices {sorted(vols)}, expected {DEVICES}")
    g = one(load(a.groups), "SecurityGroups", "E_BUILDER_SG")
    need(g.get("GroupId") == a.sg, "E_BUILDER_SG", "another security group")
    need(g.get("IpPermissions") == [], "E_BUILDER_INBOUND", f"{len(g.get('IpPermissions') or [])} inbound rules, expected 0")
    owned(tags(g.get("Tags")), a, "E_BUILDER_TAGS")
    print("BUILDER_VOLUME_IDS=" + ",".join(vols[d] for d in DEVICES))
    print(f"OS_VOLUME_ID={vols['/dev/xvdf']}")
    print(f"DATA_VOLUME_ID={vols['/dev/xvdb']}")
    print("builder key_name=none public_ip=none inbound_rules=0 http_tokens=required hop_limit=1")


def cmd_volumes(a):
    ids = a.ids.split(",")
    need(len(ids) == 4 and all(VOL.fullmatch(v) for v in ids), "E_INPUT", "--ids must be four volume IDs")
    vl = load(a.volumes).get("Volumes")
    need(isinstance(vl, list), "E_READ", "no Volumes list", 2)
    by_id = {v.get("VolumeId"): v for v in vl if isinstance(v, dict)}
    need(sorted(by_id) == sorted(ids), "E_BUILDER_VOLUMES", "DescribeVolumes is not the builder's four volumes")
    for v in by_id.values():
        att = [x.get("InstanceId") for x in v.get("Attachments") or []]
        need(att == [a.builder], "E_BUILDER_VOLUMES", f"{v.get('VolumeId')} is attached to {att}")
        need(v.get("VolumeType") == "gp3", "E_BUILDER_VOLUMES", f"{v.get('VolumeId')} is {v.get('VolumeType')}")
        owned(tags(v.get("Tags")), a, "E_BUILDER_VOLUME_TAGS")
    print("builder-volumes count=4 attached=builder tags=ok")


def cmd_sg(a):
    g = one(load(a.groups), "SecurityGroups", "E_SG_COUNT")
    need(g.get("GroupId") == a.sg and g.get("VpcId") == a.vpc, "E_SG_ID", "another group or VPC")
    need(g.get("IpPermissions") == [], "E_SG_INBOUND", f"{len(g.get('IpPermissions') or [])} inbound rules, expected 0")
    eg = g.get("IpPermissionsEgress")
    need(isinstance(eg, list) and len(eg) == 1, "E_SG_EGRESS", f"{len(eg or [])} egress rules, expected one")
    r = eg[0]
    ranges = [x.get("CidrIp") for x in r.get("IpRanges") or []]
    need(r.get("IpProtocol") == "tcp" and r.get("FromPort") == 443 and r.get("ToPort") == 443 and ranges == ["0.0.0.0/0"]
         and not r.get("Ipv6Ranges") and not r.get("UserIdGroupPairs") and not r.get("PrefixListIds"),
         "E_SG_EGRESS", "the egress rule is not TCP 443 to 0.0.0.0/0 only")
    owned(tags(g.get("Tags")), a, "E_SG_TAGS")
    print("builder-sg inbound_rules=0 egress=tcp/443 tags=ok")


def cmd_owned(a):
    d = load(a.file)
    if a.kind == "sg":
        item = one(d, "SecurityGroups", "E_OWNED")
    elif a.kind == "role":
        item = d.get("Role") if isinstance(d, dict) else None
    elif a.kind == "profile":
        item = d.get("InstanceProfile") if isinstance(d, dict) else None
    else:
        raise Refused("E_INPUT", f"unknown kind {a.kind}")
    need(isinstance(item, dict), "E_READ", f"no {a.kind} in the read", 2)
    owned(tags(item.get("Tags")), a, "E_OWNED")
    if a.kind == "profile":
        roles = [r.get("RoleName") for r in item.get("Roles") or []]
        need(a.role is None or roles in ([], [a.role]), "E_OWNED", f"the profile holds roles {roles}")
    print(f"{a.kind}=owned")


def cmd_gone(a):
    need(a.kind in NOT_FOUND, "E_INPUT", f"unknown kind {a.kind}")
    need(re.fullmatch(r"[0-9]+", a.rc) is not None, "E_INPUT", "rc must be a number")
    try:
        with open(a.stderr, encoding="utf-8", errors="replace") as f:
            err = f.read()
    except OSError as e:
        raise Refused("E_READ", f"{a.stderr}: {e.strerror}", 2)
    if a.rc != "0":
        need(f"({NOT_FOUND[a.kind]})" in err, "E_READ", f"{a.kind}: the read failed with another error", 2)
        print(f"{a.kind}=absent")
        return
    out = load(a.stdout)
    if a.kind == "instance":
        insts = [i for r in out.get("Reservations") or [] for i in r.get("Instances") or []]
        states = {(i.get("State") or {}).get("Name") for i in insts}
        need(states <= {"terminated"}, "E_LEFTOVER", f"instance state {sorted(str(s) for s in states)}")
        print("instance=terminated" if insts else "instance=absent")
        return
    if a.kind == "volume":
        need(not out.get("Volumes"), "E_LEFTOVER", "a builder volume remains")
    elif a.kind == "sg":
        need(not out.get("SecurityGroups"), "E_LEFTOVER", "the builder security group remains")
    elif a.kind == "image":
        need(not out.get("Images"), "E_LEFTOVER", "an AMI of this run exists")
    elif a.kind == "snapshot":
        need(not out.get("Snapshots"), "E_LEFTOVER", "a snapshot of this run exists")
    else:
        raise Refused("E_LEFTOVER", f"the builder {a.kind} remains")
    print(f"{a.kind}=absent")


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("manifest")
    p.add_argument("path")
    p.add_argument("--run-id", required=True)
    p.add_argument("--region", required=True)
    p.add_argument("--uuid")
    p = sp.add_parser("image")
    p.add_argument("images")
    for k in ("--uefi", "--ami", "--run-id", "--managed-by", "--slots"):
        p.add_argument(k, required=True)
    p = sp.add_parser("snapshots")
    p.add_argument("images")
    p.add_argument("snaps")
    for k in ("--ami", "--run-id", "--managed-by", "--os-volume", "--data-volume", "--slots"):
        p.add_argument(k, required=True)
    p = sp.add_parser("builder")
    p.add_argument("instances")
    p.add_argument("groups")
    for k in ("--builder", "--sg", "--profile", "--subnet", "--run-id", "--managed-by"):
        p.add_argument(k, required=True)
    p = sp.add_parser("volumes")
    p.add_argument("volumes")
    for k in ("--ids", "--builder", "--run-id", "--managed-by"):
        p.add_argument(k, required=True)
    p = sp.add_parser("sg")
    p.add_argument("groups")
    for k in ("--sg", "--vpc", "--run-id", "--managed-by"):
        p.add_argument(k, required=True)
    p = sp.add_parser("owned")
    p.add_argument("kind")
    p.add_argument("file")
    for k in ("--run-id", "--managed-by"):
        p.add_argument(k, required=True)
    p.add_argument("--role")
    p = sp.add_parser("gone")
    for k in ("kind", "rc", "stdout", "stderr"):
        p.add_argument(k)
    a = ap.parse_args()
    cmds = {"manifest": cmd_manifest, "image": cmd_image, "snapshots": cmd_snapshots,
            "builder": cmd_builder, "volumes": cmd_volumes, "sg": cmd_sg, "owned": cmd_owned,
            "gone": cmd_gone}
    try:
        cmds[a.cmd](a)
    except Refused as e:
        print(str(e), file=sys.stderr)
        return e.code
    except (KeyError, TypeError, AttributeError) as e:
        print(f"ERROR: E_READ: the input has an unexpected shape ({type(e).__name__})", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
