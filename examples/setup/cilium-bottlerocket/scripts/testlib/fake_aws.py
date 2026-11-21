#!/usr/bin/env python3
"""A small fake of the AWS CLI v2, for this sample's offline tests only.

Ported from examples/setup/ubuntu-ami/scripts/testlib/fake_aws.py and widened to the calls that
setup.sh, test.sh, clean.sh, scripts/10-build-ami-packer.sh and scripts/packer-stage.sh make. It
answers from the world state file that fakelib.py describes, the way the real APIs would:
server-side filters (with * wildcards) and tag filters, NotFound errors for missing resources,
DependencyViolation and InUse errors for deletes the real API refuses. It applies --query
(JMESPath, client side, as the CLI does) and --output text.

State shape (every key optional):
  account                       the caller's account (the AWS documentation example account)
  caller_arn                    the caller's ARN (default an assumed-role ARN in that account)
  ec2.<kind>                    lists of resource objects, kinds in KINDS below; an object may
                                carry "RecheckTags": what a by-ID read returns after discovery
                                (another owner re-tagged the resource), "StaysAfterDelete":
                                a delete that answers success and leaves the resource, and
                                (instances) "AgedOut": EC2 no longer lists it; a read by its ID
                                answers an empty list and the terminated waiter never ends
  ssm.parameters                {name: value}; ssm.online, ssm.results, ssm.commands as in ubuntu-ami
  quotas                        {"<service-code>/<quota-code>": value}
  eks.clusters                  {name: cluster object with "tags"}
  eks.nodegroups                {"<cluster>/<name>": nodegroup object; "Statuses": the status of
                                 each describe in turn, the last one stays}
  eks.addons                    {"<cluster>/<name>": addon object}
  eks.pod_identity              {association id: {"clusterName", "namespace", "serviceAccount",
                                 "roleArn", "tags"}}
  iam.roles, iam.profiles       as in ubuntu-ami (roles: Trust, Tags, Attached, Inline)
  iam.oidc_providers            [provider ARN, ...] (list-open-id-connect-providers)
  cloudformation.stacks         {name: {"StackStatus", "Tags"}}
  cloudformation.events         {stack name: [event, ...] oldest first}, written by fake_eksctl.py

Environment:
  FAKE_AWS_VERSION   the version `aws --version` prints (default 2.31.0)
  plus FAKE_STATE, FAKE_LOG, FAKE_FAIL (fakelib.py).

Any call this fake does not model exits 97. Never put it on the PATH of a real shell.
"""
import fnmatch
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fakelib  # noqa: E402
from fakelib import tagmap, taglist  # noqa: E402

try:
    import jmespath
except ImportError:
    _req = os.path.join(os.path.dirname(os.path.abspath(__file__)), "requirements-test.txt")
    sys.stderr.write("fake_aws.py: the offline tests need the jmespath package (pinned in %s). Install it "
                     "into a virtual environment under the repository's tmp/ and put it first on PATH.\n" % _req)
    sys.exit(98)

GLOBAL_WITH_VALUE = {"--region", "--profile", "--output", "--query", "--endpoint-url", "--cli-read-timeout",
                     "--cli-connect-timeout"}
GLOBAL_FLAGS = {"--no-cli-pager", "--no-paginate", "--debug", "--no-verify-ssl", "--no-sign-request"}


class ApiError(Exception):
    def __init__(self, code, op, msg="", rc=254):
        super().__init__(code)
        self.code, self.op, self.msg, self.rc = code, op, msg, rc


def parse(argv):
    """<global opts> <service> <op> [<waiter>] <opts>; global options may come anywhere."""
    pos, opts, key = [], {}, None
    i = 0
    while i < len(argv):
        tok = argv[i]
        if tok in GLOBAL_FLAGS:
            opts.setdefault(tok[2:], []).append("true")
            key = None
        elif tok.startswith("--"):
            name = tok[2:]
            if "=" in name:
                name, val = name.split("=", 1)
                opts.setdefault(name, []).append(val)
                key = None
            else:
                opts.setdefault(name, [])
                key = name
                if tok in GLOBAL_WITH_VALUE and i + 1 < len(argv):
                    opts[name].append(argv[i + 1])
                    i += 1
                    key = None
        elif key is not None:
            opts[key].append(tok)
        else:
            pos.append(tok)
        i += 1
    if len(pos) < 2:
        raise ApiError("ParamValidation", "parse", "need <service> <op>", 252)
    service, op = pos[0], pos[1]
    sub = pos[2] if op == "wait" and len(pos) > 2 else None
    return service, op, sub, opts


def one(opts, name, default=None):
    v = opts.get(name)
    return v[0] if v else default


def read_value(v):
    if v.startswith("file://"):
        with open(v[len("file://"):]) as f:
            return f.read()
    return v


def shorthand_tags(text):
    return {k: v for k, v in re.findall(r"\{?Key=([^,}\s]+),Value=([^,}\]\s]*)\}?", text)}


def opt_tags(opts):
    """Tags from --tags, in shorthand (Key=k,Value=v ...) or JSON ([{"Key": .., "Value": ..}])."""
    out = {}
    for t in opts.get("tags", []):
        t = read_value(t)
        if t.lstrip().startswith(("[", "{")):
            out.update(tagmap(json.loads(t)))
        else:
            out.update(shorthand_tags(t))
    return out


def tag_specs(opts, rtype=None):
    """Tags from --tag-specifications, shorthand or JSON; only the given ResourceType when named."""
    out = {}
    for ts in opts.get("tag-specifications", []):
        ts = read_value(ts)
        if ts.lstrip().startswith(("[", "{")):
            doc = json.loads(ts)
            for spec in doc if isinstance(doc, list) else [doc]:
                if rtype is None or spec.get("ResourceType") == rtype:
                    out.update(tagmap(spec.get("Tags", [])))
        elif rtype is None or ts.startswith(f"ResourceType={rtype},"):
            out.update(shorthand_tags(ts))
    return out


def parse_filters(opts):
    out = []
    for f in opts.get("filters", []) + opts.get("filter", []):
        f = read_value(f)
        if f.lstrip().startswith("["):
            for item in json.loads(f):
                out.append((item["Name"], [str(v) for v in item["Values"]]))
            continue
        m = re.fullmatch(r"Name=([^,]+),Values=(.*)", f)
        if not m:
            raise ApiError("InvalidParameterValue", "filters", f"bad filter {f}")
        out.append((m.group(1), m.group(2).split(",")))
    return out


# kind -> (id key, ids option, NotFound code, list key in the answer)
KINDS = {
    "instances": ("InstanceId", "instance-ids", "InvalidInstanceID.NotFound", None),
    "volumes": ("VolumeId", "volume-ids", "InvalidVolume.NotFound", "Volumes"),
    "images": ("ImageId", "image-ids", "InvalidAMIID.NotFound", "Images"),
    "snapshots": ("SnapshotId", "snapshot-ids", "InvalidSnapshot.NotFound", "Snapshots"),
    "security_groups": ("GroupId", "group-ids", "InvalidGroup.NotFound", "SecurityGroups"),
    "launch_templates": ("LaunchTemplateId", "launch-template-ids", "InvalidLaunchTemplateId.NotFound", "LaunchTemplates"),
    "network_interfaces": ("NetworkInterfaceId", "network-interface-ids", "InvalidNetworkInterfaceID.NotFound", "NetworkInterfaces"),
    "vpcs": ("VpcId", "vpc-ids", "InvalidVpcID.NotFound", "Vpcs"),
    "subnets": ("SubnetId", "subnet-ids", "InvalidSubnetID.NotFound", "Subnets"),
    "nat_gateways": ("NatGatewayId", "nat-gateway-ids", "NatGatewayNotFound", "NatGateways"),
    "addresses": ("AllocationId", "allocation-ids", "InvalidAllocationID.NotFound", "Addresses"),
    "internet_gateways": ("InternetGatewayId", "internet-gateway-ids", "InvalidInternetGatewayID.NotFound", "InternetGateways"),
    "key_pairs": ("KeyPairId", "key-pair-ids", "InvalidKeyPair.NotFound", "KeyPairs"),
    "route_tables": ("RouteTableId", "route-table-ids", "InvalidRouteTableID.NotFound", "RouteTables"),
    "network_acls": ("NetworkAclId", "network-acl-ids", "InvalidNetworkAclID.NotFound", "NetworkAcls"),
    "vpc_endpoints": ("VpcEndpointId", "vpc-endpoint-ids", "InvalidVpcEndpointId.NotFound", "VpcEndpoints"),
}
DESCRIBE = {f"describe-{k.replace('_', '-')}": k for k in KINDS}
DESCRIBE["describe-addresses"] = "addresses"

FIELD = {
    "instance-state-name": "State.Name", "instance-id": "InstanceId", "image-id": "ImageId",
    "vpc-id": "VpcId", "subnet-id": "SubnetId", "group-name": "GroupName", "group-id": "GroupId",
    "launch-template-name": "LaunchTemplateName", "status": "Status|State", "state": "State",
    "name": "Name", "key-name": "KeyName", "description": "Description", "domain": "Domain",
    "attachment.instance-id": "Attachment.InstanceId", "attachment.vpc-id": "Attachments.0.VpcId",
    "volume-id": "VolumeId", "snapshot-id": "SnapshotId", "network-interface-id": "NetworkInterfaceId",
    "interface-type": "InterfaceType", "owner-id": "OwnerId", "iam-instance-profile.arn": "IamInstanceProfile.Arn",
    "association.public-ip": "PublicIp", "map-public-ip-on-launch": "MapPublicIpOnLaunch",
}


def get_field(obj, path):
    for part in path.split("."):
        if isinstance(obj, list):
            obj = obj[int(part)] if part.isdigit() and int(part) < len(obj) else None
        else:
            obj = (obj or {}).get(part)
    if isinstance(obj, dict) and "Name" in obj and path.endswith("State"):
        return obj["Name"]
    return obj


def value_match(have, wants):
    if have is None:
        return False
    have = str(have).lower() if isinstance(have, bool) else str(have)  # EC2 filters spell booleans true and false
    return any(fnmatch.fnmatchcase(have, w) for w in wants)


def match_filters(obj, filters):
    # ENIs carry their tags in TagSet, every other EC2 shape in Tags (as the real API answers).
    tags = tagmap(obj.get("TagSet") if "TagSet" in obj else obj.get("Tags", []))
    for name, values in filters:
        if name.startswith("tag:"):
            if not value_match(tags.get(name[4:]), values):
                return False
        elif name == "tag-key":
            if not any(value_match(k, values) for k in tags):
                return False
        elif name in FIELD:
            paths = FIELD[name].split("|")
            have = next((get_field(obj, p) for p in paths if get_field(obj, p) is not None), None)
            if name == "attachment.instance-id" and have is None:
                have = next((a.get("InstanceId") for a in obj.get("Attachments") or [] if isinstance(a, dict)), None)
            if not value_match(have, values):
                return False
        else:
            raise ApiError("InvalidParameterValue", "filters", f"filter {name} not modelled by fake_aws.py", 97)
    return True


def visible(obj, by_id):
    """What a read returns. "RecheckTags" replace the tags on a by-ID read (the owner changed after
    a filtered discovery), or on any read once "ChangeAfterCall" names a call the log holds."""
    o = json.loads(json.dumps(obj))
    if "RecheckTags" in o and ((by_id and "ChangeAfterCall" not in o) or fakelib.happened(o.get("ChangeAfterCall"))):
        o["TagSet" if "TagSet" in o else "tags" if "tags" in o and "Tags" not in o else "Tags"] = o["RecheckTags"]
    for k in ("RecheckTags", "StaysAfterDelete", "DeleteFails", "Stack", "ChangeAfterCall", "AgedOut", "Statuses",
              "DeleteRefusals", "DeleteFailReason"):
        o.pop(k, None)
    return o


def ec2_items(state, kind):
    return state.setdefault("ec2", {}).setdefault(kind, [])


def ec2_describe(state, kind, opts):
    id_key, ids_opt, notfound, _ = KINDS[kind]
    items = ec2_items(state, kind)
    ids = opts.get(ids_opt, [])
    if kind == "launch_templates" and opts.get("launch-template-names"):
        names = opts["launch-template-names"]
        hits = [x for x in items if x.get("LaunchTemplateName") in names]
        if len(hits) != len(names):
            raise ApiError("InvalidLaunchTemplateName.NotFoundException", "DescribeLaunchTemplates",
                           "At least one of the launch templates specified in the request does not exist.")
        return [visible(x, True) for x in hits]
    if kind == "key_pairs" and opts.get("key-names"):
        ids_opt, id_key, ids = "key-names", "KeyName", opts["key-names"]
    out = []
    if ids:
        for i in ids:
            hit = [x for x in items if x.get(id_key) == i]
            if not hit:
                raise ApiError(notfound, "describe", f"The id '{i}' does not exist")
            # "AgedOut": EC2 stops listing an instance some time after it terminated; a read by
            # its ID then answers an empty list (exit 0), not InvalidInstanceID.NotFound.
            if hit[0].get("AgedOut"):
                continue
            out.append(visible(hit[0], True))
        filters = parse_filters(opts)
        return [o for o in out if match_filters(o, filters)]
    filters = parse_filters(opts)
    return [visible(x, False) for x in items if match_filters(x, filters) and not x.get("AgedOut")]


def ec2_delete(state, kind, rid, op):
    id_key, _, notfound, _ = KINDS[kind]
    items = ec2_items(state, kind)
    hit = [x for x in items if x.get(id_key) == rid]
    if not hit:
        raise ApiError(notfound, op, f"The id '{rid}' does not exist")
    if hit[0].get("DeleteFails"):
        raise ApiError(hit[0]["DeleteFails"], op, f"{rid}: injected by the test state")
    if hit[0].get("StaysAfterDelete"):
        return hit[0]
    items.remove(hit[0])
    return hit[0]


def live_instances(state):
    return [x for x in ec2_items(state, "instances") if get_field(x, "State.Name") not in ("terminated",)]


def handle_ec2(state, op, sub, opts):
    if op in DESCRIBE:
        kind = DESCRIBE[op]
        res = ec2_describe(state, kind, opts)
        if kind == "instances":
            return {"Reservations": [{"Instances": res}] if res else []}
        return {KINDS[kind][3]: res}
    if op == "describe-launch-template-versions":
        lid, name = one(opts, "launch-template-id"), one(opts, "launch-template-name")
        hit = [x for x in ec2_items(state, "launch_templates")
               if (lid and x["LaunchTemplateId"] == lid) or (name and x.get("LaunchTemplateName") == name)]
        if not hit:
            raise ApiError("InvalidLaunchTemplateId.NotFound", op, lid or name)
        lt = hit[0]
        return {"LaunchTemplateVersions": [{"LaunchTemplateId": lt["LaunchTemplateId"],
                                            "LaunchTemplateName": lt.get("LaunchTemplateName"),
                                            "VersionNumber": 1, "DefaultVersion": True,
                                            "LaunchTemplateData": lt.get("LaunchTemplateData", {})}]}
    if op == "create-launch-template":
        items = ec2_items(state, "launch_templates")
        name = one(opts, "launch-template-name")
        if any(x.get("LaunchTemplateName") == name for x in items):
            raise ApiError("InvalidLaunchTemplateName.AlreadyExistsException", op, name)
        lid = "lt-0fa%014d" % (len(items) + 1)
        data = json.loads(read_value(one(opts, "launch-template-data", "{}")))
        items.append({"LaunchTemplateId": lid, "LaunchTemplateName": name,
                      "Tags": taglist(tag_specs(opts, "launch-template")), "LaunchTemplateData": data})
        return {"LaunchTemplate": {"LaunchTemplateId": lid, "LaunchTemplateName": name}}
    if op == "terminate-instances":
        out = []
        for i in opts.get("instance-ids", []):
            hit = [x for x in ec2_items(state, "instances") if x["InstanceId"] == i]
            if not hit:
                raise ApiError("InvalidInstanceID.NotFound", op, i)
            if hit[0].get("StaysAfterDelete"):
                out.append({"InstanceId": i})
                continue
            hit[0]["State"] = {"Name": "terminated"}
            for v in [v for v in ec2_items(state, "volumes") if get_field(v, "Attachment.InstanceId") == i]:
                if v.get("DeleteOnTermination"):
                    ec2_items(state, "volumes").remove(v)
                else:
                    v["State"], v["Attachments"] = "available", []
                    v.pop("Attachment", None)
            for e in [e for e in ec2_items(state, "network_interfaces") if get_field(e, "Attachment.InstanceId") == i]:
                if get_field(e, "Attachment.DeleteOnTermination") is not False or get_field(e, "Attachment.DeviceIndex") == 0:
                    ec2_items(state, "network_interfaces").remove(e)
                else:
                    e["Status"] = "available"
                    e.pop("Attachment", None)
            out.append({"InstanceId": i})
        return {"TerminatingInstances": out}
    if op == "delete-volume":
        rid = one(opts, "volume-id")
        hit = [x for x in ec2_items(state, "volumes") if x["VolumeId"] == rid]
        if hit and hit[0].get("State") == "in-use":
            raise ApiError("VolumeInUse", op, f"Volume {rid} is currently attached")
        ec2_delete(state, "volumes", rid, op)
        return None
    if op == "delete-network-interface":
        rid = one(opts, "network-interface-id")
        hit = [x for x in ec2_items(state, "network_interfaces") if x["NetworkInterfaceId"] == rid]
        if hit and hit[0].get("Status") == "in-use":
            raise ApiError("InvalidNetworkInterface.InUse", op, f"Interface {rid} is currently in use")
        ec2_delete(state, "network_interfaces", rid, op)
        return None
    if op == "deregister-image":
        ec2_delete(state, "images", one(opts, "image-id"), op)
        return {"Return": True}
    if op == "delete-snapshot":
        rid = one(opts, "snapshot-id")
        for img in ec2_items(state, "images"):
            if any((b.get("Ebs") or {}).get("SnapshotId") == rid for b in img.get("BlockDeviceMappings", [])):
                raise ApiError("InvalidSnapshot.InUse", op, f"The snapshot {rid} is currently in use by {img['ImageId']}")
        ec2_delete(state, "snapshots", rid, op)
        return None
    if op == "delete-security-group":
        rid = one(opts, "group-id")
        users = [x["InstanceId"] for x in live_instances(state)
                 if rid in [g.get("GroupId") for g in x.get("SecurityGroups", [])]]
        users += [e["NetworkInterfaceId"] for e in ec2_items(state, "network_interfaces")
                  if rid in [g.get("GroupId") for g in e.get("Groups", [])]]
        if users:
            raise ApiError("DependencyViolation", op, f"resource {rid} has a dependent object")
        ec2_delete(state, "security_groups", rid, op)
        return None
    if op == "delete-launch-template":
        rid = one(opts, "launch-template-id")
        if rid is None:
            name = one(opts, "launch-template-name")
            hit = [x for x in ec2_items(state, "launch_templates") if x.get("LaunchTemplateName") == name]
            if not hit:
                raise ApiError("InvalidLaunchTemplateName.NotFoundException", op, name)
            rid = hit[0]["LaunchTemplateId"]
        lt = ec2_delete(state, "launch_templates", rid, op)
        return {"LaunchTemplate": {"LaunchTemplateId": rid, "LaunchTemplateName": lt.get("LaunchTemplateName")}}
    if op == "delete-key-pair":
        rid, name = one(opts, "key-pair-id"), one(opts, "key-name")
        hit = [x for x in ec2_items(state, "key_pairs") if x.get("KeyPairId") == rid or (name and x.get("KeyName") == name)]
        if hit:
            ec2_items(state, "key_pairs").remove(hit[0])
        return {"Return": True}
    if op == "delete-nat-gateway":
        rid = one(opts, "nat-gateway-id")
        hit = [x for x in ec2_items(state, "nat_gateways") if x["NatGatewayId"] == rid]
        if not hit:
            raise ApiError("NatGatewayNotFound", op, rid)
        if not hit[0].get("StaysAfterDelete"):
            hit[0]["State"] = "deleted"
        return {"NatGatewayId": rid}
    if op == "release-address":
        ec2_delete(state, "addresses", one(opts, "allocation-id"), op)
        return None
    if op == "delete-vpc":
        rid = one(opts, "vpc-id")
        deps = [x for x in ec2_items(state, "subnets") if x.get("VpcId") == rid]
        deps += [x for x in live_instances(state) if x.get("VpcId") == rid]
        deps += [x for x in ec2_items(state, "network_interfaces") if x.get("VpcId") == rid]
        deps += [x for x in ec2_items(state, "security_groups") if x.get("VpcId") == rid and x.get("GroupName") != "default"]
        deps += [x for x in ec2_items(state, "internet_gateways")
                 if rid in [a.get("VpcId") for a in x.get("Attachments", [])]]
        if deps:
            raise ApiError("DependencyViolation", op, f"The vpc '{rid}' has dependencies and cannot be deleted.")
        ec2_delete(state, "vpcs", rid, op)
        return None
    if op == "create-tags":
        new = opt_tags(opts)
        for rid in opts.get("resources", []):
            found = False
            for kind, (id_key, _, _, _) in KINDS.items():
                for x in ec2_items(state, kind):
                    if x.get(id_key) == rid:
                        t = tagmap(x.get("Tags", []))
                        t.update(new)
                        x["Tags"] = taglist(t)
                        found = True
            if not found:
                raise ApiError("InvalidID", op, f"The ID '{rid}' is not valid")
        return None
    if op == "create-security-group":
        items = ec2_items(state, "security_groups")
        name, vpc = one(opts, "group-name"), one(opts, "vpc-id")
        if any(x.get("GroupName") == name and x.get("VpcId") == vpc for x in items):
            raise ApiError("InvalidGroup.Duplicate", "CreateSecurityGroup", f"The security group '{name}' already exists")
        gid = "sg-0fc%014d" % (len(items) + 1)
        items.append({"GroupId": gid, "GroupName": name, "VpcId": vpc, "Description": one(opts, "description", ""),
                      "IpPermissions": [], "Tags": taglist(tag_specs(opts, "security-group")),
                      "IpPermissionsEgress": [{"IpProtocol": "-1", "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}]})
        return {"GroupId": gid}
    if op in ("authorize-security-group-egress", "revoke-security-group-egress",
              "authorize-security-group-ingress", "revoke-security-group-ingress"):
        gid = one(opts, "group-id")
        hit = [x for x in ec2_items(state, "security_groups") if x["GroupId"] == gid]
        if not hit:
            raise ApiError("InvalidGroup.NotFound", op, gid)
        field = "IpPermissionsEgress" if "egress" in op else "IpPermissions"
        perms = json.loads(read_value(one(opts, "ip-permissions", "[]")))
        cur = hit[0].setdefault(field, [])
        if op.startswith("authorize"):
            cur.extend(perms)
        else:
            for p in perms:
                if p in cur:
                    cur.remove(p)
                else:
                    raise ApiError("InvalidPermission.NotFound", op, "The specified rule does not exist in this security group.")
        return {"Return": True}
    if op == "describe-image-attribute":
        rid, attr = one(opts, "image-id"), one(opts, "attribute")
        hit = [x for x in ec2_items(state, "images") if x["ImageId"] == rid]
        if not hit:
            raise ApiError("InvalidAMIID.NotFound", op, rid)
        if attr == "uefiData":
            v = hit[0].get("UefiData")
            return {"ImageId": rid, "UefiData": {"Value": v} if v else {}}
        raise ApiError("FakeUnsupported", f"ec2 {op} {attr}", "attribute not modelled by fake_aws.py", 97)
    if op == "wait":
        return ec2_wait(state, sub, opts)
    if op == "describe-instance-types":
        types = state.get("instance_types", {})
        out = [dict(types[t], InstanceType=t) for t in opts.get("instance-types", []) if t in types]
        return {"InstanceTypes": out}
    if op == "describe-availability-zones":
        return {"AvailabilityZones": state.get("availability_zones", [])}
    raise ApiError("FakeUnsupported", f"ec2 {op}", "not modelled by fake_aws.py", 97)


def ec2_wait(state, sub, opts):
    if sub == "instance-terminated":
        for i in opts.get("instance-ids", []):
            hit = [x for x in ec2_items(state, "instances") if x["InstanceId"] == i]
            # The waiter of an instance that EC2 no longer lists never sees "terminated".
            if hit and (hit[0].get("AgedOut") or get_field(hit[0], "State.Name") != "terminated"):
                raise ApiError("WaiterMaxAttempts", "wait", "Waiter InstanceTerminated failed: Max attempts exceeded", 255)
        return None
    if sub == "volume-deleted":
        for i in opts.get("volume-ids", []):
            if any(x["VolumeId"] == i for x in ec2_items(state, "volumes")):
                raise ApiError("WaiterMaxAttempts", "wait", "Waiter VolumeDeleted failed: Max attempts exceeded", 255)
        return None
    if sub == "nat-gateway-deleted":
        for i in opts.get("nat-gateway-ids", []):
            hit = [x for x in ec2_items(state, "nat_gateways") if x["NatGatewayId"] == i]
            if hit and hit[0].get("State") != "deleted":
                raise ApiError("WaiterMaxAttempts", "wait", "Waiter NatGatewayDeleted failed: Max attempts exceeded", 255)
        return None
    if sub == "snapshot-completed" or sub == "image-available" or sub == "instance-running":
        return None
    raise ApiError("FakeUnsupported", f"ec2 wait {sub}", "not modelled by fake_aws.py", 97)


def handle_eks(state, op, sub, opts):
    k = state.setdefault("eks", {})
    clusters = k.setdefault("clusters", {})
    ngs = k.setdefault("nodegroups", {})
    cl = one(opts, "cluster-name") or one(opts, "name")
    if op == "list-clusters":
        return {"clusters": sorted(clusters)}
    if op == "describe-cluster":
        c = clusters.get(one(opts, "name"))
        if not c:
            raise ApiError("ResourceNotFoundException", "DescribeCluster", f"No cluster found for name: {one(opts, 'name')}.")
        return {"cluster": dict(visible(c, False), name=one(opts, "name"))}
    if op == "update-kubeconfig":
        name = one(opts, "name")
        c = clusters.get(name)
        if not c:
            raise ApiError("ResourceNotFoundException", "DescribeCluster", f"No cluster found for name: {name}.")
        path = one(opts, "kubeconfig") or os.environ.get("KUBECONFIG", "")
        if not path:
            raise ApiError("FakeUnsupported", "eks update-kubeconfig", "the fake writes only to --kubeconfig or KUBECONFIG", 97)
        alias = one(opts, "alias") or f"arn:aws:eks:us-west-2:{state.get('account', '')}:cluster/{name}"
        doc = {"apiVersion": "v1", "kind": "Config", "current-context": alias,
               "clusters": [{"name": alias, "cluster": {"server": c.get("endpoint"),
                                                         "certificate-authority-data": (c.get("certificateAuthority") or {}).get("data")}}],
               "contexts": [{"name": alias, "context": {"cluster": alias, "user": alias}}],
               "users": [{"name": alias, "user": {"exec": {"apiVersion": "client.authentication.k8s.io/v1beta1",
                                                            "command": "aws", "args": ["eks", "get-token", "--cluster-name", name]}}}]}
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w") as f:
            json.dump(doc, f, indent=1)
        os.chmod(path, 0o600)
        print(f"Added new context {alias} to {path}")
        return None
    if op == "list-tags-for-resource":
        arn = one(opts, "resource-arn", "")
        name = arn.rsplit("/", 1)[-1]
        if name not in clusters:
            raise ApiError("NotFoundException", op, arn)
        return {"tags": clusters[name].get("tags", {})}
    if op == "list-nodegroups":
        return {"nodegroups": sorted(x.split("/", 1)[1] for x in ngs if x.split("/", 1)[0] == cl)}
    nk = f"{cl}/{one(opts, 'nodegroup-name')}"
    if op == "describe-nodegroup":
        if nk not in ngs:
            raise ApiError("ResourceNotFoundException", "DescribeNodegroup", f"No node group found for name: {one(opts, 'nodegroup-name')}.")
        # "Statuses": the status of each read in turn (the last one stays), e.g. CREATING then ACTIVE.
        seq = ngs[nk].get("Statuses")
        if seq:
            ngs[nk]["status"] = seq[0]
            if len(seq) > 1:
                ngs[nk]["Statuses"] = seq[1:]
        return {"nodegroup": dict(visible(ngs[nk], False), nodegroupName=one(opts, "nodegroup-name"), clusterName=cl)}
    if op == "delete-nodegroup":
        if nk not in ngs:
            raise ApiError("ResourceNotFoundException", "DeleteNodegroup", nk)
        if not ngs[nk].get("StaysAfterDelete"):
            del ngs[nk]
        return {"nodegroup": {"status": "DELETING"}}
    addons = k.setdefault("addons", {})
    if op == "list-addons":
        return {"addons": sorted(x.split("/", 1)[1] for x in addons if x.split("/", 1)[0] == cl)}
    if op == "describe-addon":
        ad = addons.get(f"{cl}/{one(opts, 'addon-name')}")
        if not ad:
            raise ApiError("ResourceNotFoundException", "DescribeAddon", f"No addon: {one(opts, 'addon-name')} found in cluster: {cl}")
        return {"addon": ad}
    pia = k.setdefault("pod_identity", {})
    if op == "list-pod-identity-associations":
        out = []
        for aid, a in sorted(pia.items()):
            if a.get("clusterName") != cl:
                continue
            if one(opts, "namespace") and a.get("namespace") != one(opts, "namespace"):
                continue
            if one(opts, "service-account") and a.get("serviceAccount") != one(opts, "service-account"):
                continue
            out.append({"associationId": aid, "clusterName": cl, "namespace": a.get("namespace"),
                        "serviceAccount": a.get("serviceAccount")})
        return {"associations": out}
    if op in ("describe-pod-identity-association", "delete-pod-identity-association"):
        aid = one(opts, "association-id")
        a = pia.get(aid)
        if not a or a.get("clusterName") != cl:
            raise ApiError("ResourceNotFoundException", op, f"association {aid} not found")
        if op == "delete-pod-identity-association" and not a.get("StaysAfterDelete"):
            del pia[aid]
        return {"association": dict(visible(a, False), associationId=aid)}
    # The other children that EKS deletes with the cluster (eks.access_entries keyed
    # "<cluster>|<principal ARN>", eks.fargate_profiles and eks.identity_provider_configs keyed
    # "<cluster>/<name>"). A read for a cluster that does not exist is ResourceNotFoundException.
    if op in ("list-access-entries", "describe-access-entry", "list-fargate-profiles", "describe-fargate-profile",
              "list-identity-provider-configs", "describe-identity-provider-config") and cl not in clusters:
        raise ApiError("ResourceNotFoundException", op, f"No cluster found for name: {cl}.")
    entries = k.setdefault("access_entries", {})
    if op == "list-access-entries":
        return {"accessEntries": sorted(x.split("|", 1)[1] for x in entries if x.split("|", 1)[0] == cl)}
    if op == "describe-access-entry":
        e = entries.get(f"{cl}|{one(opts, 'principal-arn')}")
        if not e:
            raise ApiError("ResourceNotFoundException", op, f"The specified principalArn could not be found: {one(opts, 'principal-arn')}")
        return {"accessEntry": dict(visible(e, False), clusterName=cl, principalArn=one(opts, "principal-arn"))}
    fps = k.setdefault("fargate_profiles", {})
    if op == "list-fargate-profiles":
        return {"fargateProfileNames": sorted(x.split("/", 1)[1] for x in fps if x.split("/", 1)[0] == cl)}
    if op == "describe-fargate-profile":
        fp = fps.get(f"{cl}/{one(opts, 'fargate-profile-name')}")
        if not fp:
            raise ApiError("ResourceNotFoundException", op, f"No Fargate Profile found with name: {one(opts, 'fargate-profile-name')}.")
        return {"fargateProfile": dict(visible(fp, False), fargateProfileName=one(opts, "fargate-profile-name"), clusterName=cl)}
    idps = k.setdefault("identity_provider_configs", {})
    if op == "list-identity-provider-configs":
        return {"identityProviderConfigs": [{"type": "oidc", "name": x.split("/", 1)[1]} for x in sorted(idps)
                                            if x.split("/", 1)[0] == cl]}
    if op == "describe-identity-provider-config":
        ref = dict(p.split("=", 1) for p in one(opts, "identity-provider-config", "").split(",") if "=" in p)
        idp = idps.get(f"{cl}/{ref.get('name', '')}")
        if not idp or ref.get("type") != "oidc":
            raise ApiError("ResourceNotFoundException", op, f"identity provider config {ref} not found")
        return {"identityProviderConfig": {"oidc": dict(visible(idp, False), identityProviderConfigName=ref["name"], clusterName=cl)}}
    if op == "wait":
        if sub == "cluster-active" or sub == "nodegroup-active":
            return None
        if sub == "nodegroup-deleted":
            if nk in ngs:
                raise ApiError("WaiterMaxAttempts", "wait", "Waiter NodegroupDeleted failed: Max attempts exceeded", 255)
            return None
        if sub == "cluster-deleted":
            if one(opts, "name") in clusters:
                raise ApiError("WaiterMaxAttempts", "wait", "Waiter ClusterDeleted failed: Max attempts exceeded", 255)
            return None
    raise ApiError("FakeUnsupported", f"eks {op}", "not modelled by fake_aws.py", 97)


def handle_iam(state, op, sub, opts, acct):
    i = state.setdefault("iam", {})
    roles, profiles = i.setdefault("roles", {}), i.setdefault("profiles", {})
    rn, pn = one(opts, "role-name"), one(opts, "instance-profile-name")

    def role():
        if rn not in roles:
            raise ApiError("NoSuchEntity", op, f"The role with name {rn} cannot be found.")
        return roles[rn]

    def prof():
        if pn not in profiles:
            raise ApiError("NoSuchEntity", op, f"Instance Profile {pn} cannot be found.")
        return profiles[pn]

    def tags_of(obj):
        """The tags one read sees: "RecheckTags" from the second read on (the owner changed after
        discovery), or once the "ChangeAfterCall" call is in the log."""
        obj["TagReads"] = obj.get("TagReads", 0) + 1
        if "RecheckTags" in obj:
            if "ChangeAfterCall" in obj:
                if fakelib.happened(obj["ChangeAfterCall"]):
                    return obj["RecheckTags"]
            elif obj["TagReads"] > 1:
                return obj["RecheckTags"]
        return obj.get("Tags", [])

    arn = lambda n: f"arn:aws:iam::{acct}:role/{n}"  # noqa: E731
    parn = lambda n: f"arn:aws:iam::{acct}:instance-profile/{n}"  # noqa: E731
    if op == "create-role":
        if rn in roles:
            raise ApiError("EntityAlreadyExists", "CreateRole", f"Role with name {rn} already exists.")
        roles[rn] = {"Trust": json.loads(read_value(one(opts, "assume-role-policy-document", "{}"))),
                     "Tags": taglist(opt_tags(opts)), "Attached": [], "Inline": {}}
        return {"Role": {"RoleName": rn, "Arn": arn(rn)}}
    if op == "attach-role-policy":
        r = role()
        p = one(opts, "policy-arn")
        r.setdefault("Attached", [])
        if p not in r["Attached"]:
            r["Attached"].append(p)
        return None
    if op == "put-role-policy":
        role().setdefault("Inline", {})[one(opts, "policy-name")] = json.loads(read_value(one(opts, "policy-document")))
        return None
    if op == "create-instance-profile":
        if pn in profiles:
            raise ApiError("EntityAlreadyExists", "CreateInstanceProfile", f"Instance Profile {pn} already exists.")
        profiles[pn] = {"Roles": [], "Tags": taglist(opt_tags(opts))}
        return {"InstanceProfile": {"InstanceProfileName": pn, "Arn": parn(pn)}}
    if op == "add-role-to-instance-profile":
        p = prof()
        role()
        if p.get("Roles"):
            raise ApiError("LimitExceeded", "AddRoleToInstanceProfile", "Cannot exceed quota for InstanceSessionsPerInstanceProfile: 1")
        p.setdefault("Roles", []).append(rn)
        return None
    if op == "wait" and sub in ("instance-profile-exists", "role-exists"):
        prof() if sub == "instance-profile-exists" else role()
        return None
    if op == "list-roles":
        return {"Roles": [{"RoleName": n, "Arn": arn(n)} for n in sorted(roles)]}
    if op == "get-role":
        r = role()
        return {"Role": {"RoleName": rn, "Arn": arn(rn), "AssumeRolePolicyDocument": r.get("Trust", {}),
                         "Tags": tags_of(r)}}
    if op == "list-role-tags":
        return {"Tags": tags_of(role())}
    if op == "list-attached-role-policies":
        return {"AttachedPolicies": [{"PolicyArn": p, "PolicyName": p.rsplit("/", 1)[-1]} for p in role().get("Attached", [])]}
    if op == "list-role-policies":
        return {"PolicyNames": sorted(role().get("Inline", {}))}
    if op == "get-role-policy":
        p = one(opts, "policy-name")
        if p not in role().get("Inline", {}):
            raise ApiError("NoSuchEntity", op, f"The role policy with name {p} cannot be found.")
        return {"RoleName": rn, "PolicyName": p, "PolicyDocument": role()["Inline"][p]}
    if op == "detach-role-policy":
        r = role()
        p = one(opts, "policy-arn")
        if p not in r.get("Attached", []):
            raise ApiError("NoSuchEntity", op, p)
        r["Attached"].remove(p)
        return None
    if op == "delete-role-policy":
        r = role()
        p = one(opts, "policy-name")
        if p not in r.get("Inline", {}):
            raise ApiError("NoSuchEntity", op, p)
        del r["Inline"][p]
        return None
    if op == "delete-role":
        r = role()
        if r.get("Attached") or r.get("Inline") or any(rn in pr.get("Roles", []) for pr in profiles.values()):
            raise ApiError("DeleteConflict", op, "Cannot delete entity, must detach all policies first.")
        if not r.get("StaysAfterDelete"):
            del roles[rn]
        return None
    if op == "get-instance-profile":
        p = prof()
        return {"InstanceProfile": {"InstanceProfileName": pn, "Arn": parn(pn),
                                    "Roles": [{"RoleName": x, "Arn": arn(x)} for x in p.get("Roles", [])],
                                    "Tags": tags_of(p)}}
    if op == "list-instance-profile-tags":
        return {"Tags": tags_of(prof())}
    if op == "list-instance-profiles":
        return {"InstanceProfiles": [{"InstanceProfileName": n, "Arn": parn(n)} for n in sorted(profiles)]}
    if op == "list-instance-profiles-for-role":
        role()
        return {"InstanceProfiles": [{"InstanceProfileName": n, "Arn": parn(n)} for n, p in sorted(profiles.items())
                                     if rn in p.get("Roles", [])]}
    if op == "remove-role-from-instance-profile":
        p = prof()
        if rn not in p.get("Roles", []):
            raise ApiError("NoSuchEntity", op, rn)
        p["Roles"].remove(rn)
        return None
    if op == "delete-instance-profile":
        p = prof()
        if p.get("Roles"):
            raise ApiError("DeleteConflict", op, "Cannot delete entity, must remove roles from instance profile first.")
        if not p.get("StaysAfterDelete"):
            del profiles[pn]
        return None
    if op == "list-open-id-connect-providers":
        return {"OpenIDConnectProviderList": [{"Arn": a} for a in i.get("oidc_providers", [])]}
    raise ApiError("FakeUnsupported", f"iam {op}", "not modelled by fake_aws.py", 97)


def handle_ssm(state, op, sub, opts, key):
    m = state.setdefault("ssm", {})
    cmds = m.setdefault("commands", {})
    live = {x["InstanceId"] for x in live_instances(state) if get_field(x, "State.Name") in ("pending", "running")}
    if op == "get-parameter":
        p = m.get("parameters", {}).get(one(opts, "name"))
        if p is None:
            raise ApiError("ParameterNotFound", "GetParameter", one(opts, "name"))
        return {"Parameter": {"Name": one(opts, "name"), "Value": p, "Type": "String"}}
    if op == "get-parameters":
        names = opts.get("names", [])
        params = m.get("parameters", {})
        return {"Parameters": [{"Name": n, "Value": params[n]} for n in names if n in params],
                "InvalidParameters": [n for n in names if n not in params]}
    if op == "describe-instance-information":
        ids = []
        for f in opts.get("filters", []):
            mm = re.fullmatch(r"Key=InstanceIds,Values=(.*)", f)
            if not mm:
                raise ApiError("InvalidFilterKey", op, f"filter {f} not modelled by fake_aws.py", 97)
            ids += mm.group(1).split(",")
        online = m.get("online", True)
        return {"InstanceInformationList": [{"InstanceId": i, "PingStatus": "Online"} for i in ids if online and i in live]}
    if op == "send-command":
        targets = opts.get("instance-ids", [])
        if len(targets) != 1 or targets[0] not in live:
            raise ApiError("InvalidInstanceId", "SendCommand", f"instance {targets} is not registered with SSM")
        text = " ".join(read_value(p) for p in opts.get("parameters", []))
        res = next((r for r in m.get("results", []) if r["match"] in text), None)
        if res is None:
            raise ApiError("FakeUnsupported", key, "no ssm result in the test state for this command", 97)
        cid = "00000000-0000-4000-8000-%012d" % (len(cmds) + 1)
        cmds[cid] = dict(res, instance=targets[0], text=text)
        return {"Command": {"CommandId": cid, "Status": "Pending"}}
    if op == "get-command-invocation" or (op == "wait" and sub == "command-executed"):
        c = cmds.get(one(opts, "command-id"))
        if c is None or c["instance"] != one(opts, "instance-id"):
            raise ApiError("InvocationDoesNotExist", op, "no such command on that instance")
        c["reads"] = c.get("reads", 0) + (20 if op == "wait" else 1)
        if c["reads"] <= c.get("progress", 0):
            if op == "wait":
                raise ApiError("WaiterMaxAttempts", "wait", "Waiter CommandExecuted failed: Max attempts exceeded", 255)
            return {"Status": "InProgress", "StandardOutputContent": "", "StandardErrorContent": ""}
        if op == "wait":
            if c["Status"] != "Success":
                raise ApiError("WaiterFailure", "wait", f"Waiter CommandExecuted failed: terminal status {c['Status']}", 255)
            return None
        return {"CommandId": one(opts, "command-id"), "InstanceId": c["instance"], "Status": c["Status"],
                "ResponseCode": 0 if c["Status"] == "Success" else 1,
                "StandardOutputContent": c.get("stdout", ""), "StandardErrorContent": c.get("stderr", "")}
    raise ApiError("FakeUnsupported", f"ssm {op}", "not modelled by fake_aws.py", 97)


def handle_cfn(state, op, sub, opts):
    stacks = state.setdefault("cloudformation", {}).setdefault("stacks", {})
    name = one(opts, "stack-name")
    if op == "describe-stacks":
        if name:
            s = stacks.get(name)
            if not s or s.get("StackStatus") == "DELETE_COMPLETE":
                raise ApiError("ValidationError", "DescribeStacks", f"Stack with id {name} does not exist")
            return {"Stacks": [visible(dict(s, StackName=name), True)]}
        return {"Stacks": [visible(dict(s, StackName=n), False) for n, s in sorted(stacks.items())
                           if s.get("StackStatus") != "DELETE_COMPLETE"]}
    if op == "list-stacks":
        want = opts.get("stack-status-filter", [])
        return {"StackSummaries": [{"StackName": n, "StackStatus": s.get("StackStatus")} for n, s in sorted(stacks.items())
                                   if not want or s.get("StackStatus") in want]}
    if op == "delete-stack":
        s = stacks.get(name)
        if s and not s.get("StaysAfterDelete") and s.get("StackStatus") != "DELETE_COMPLETE":
            # As CloudFormation does: the stack's own resources go with it ("Stack" names the
            # stack), unless something outside the stack still sits in the stack's VPC; then the
            # stack ends DELETE_FAILED and its resources stay.
            e = state.get("ec2", {})
            mine = lambda x: x.get("Stack") == name  # noqa: E731
            vpcs = {x["VpcId"] for x in e.get("vpcs", []) if mine(x)}
            inside = lambda kind: [x for x in e.get(kind, []) if x.get("VpcId") in vpcs and not mine(x)]  # noqa: E731
            blockers = [x for x in inside("instances") if (x.get("State") or {}).get("Name") != "terminated"]
            blockers += inside("network_interfaces") + inside("security_groups")
            if blockers:
                s["StackStatus"] = "DELETE_FAILED"
            else:
                for kind in list(e):
                    if isinstance(e[kind], list):
                        e[kind] = [x for x in e[kind] if not mine(x)]
                for coll in ("roles", "profiles"):
                    objs = state.setdefault("iam", {}).setdefault(coll, {})
                    for n in [n for n, v in objs.items() if mine(v)]:
                        del objs[n]
                s["StackStatus"] = "DELETE_COMPLETE"
        return None
    if op == "describe-stack-events":
        # The events that fake_eksctl.py records (cloudformation.events), newest first, as CloudFormation
        # lists them. A stack that never existed is a ValidationError.
        if name not in stacks:
            raise ApiError("ValidationError", "DescribeStackEvents", f"Stack [{name}] does not exist")
        events = state.get("cloudformation", {}).get("events", {}).get(name, [])
        return {"StackEvents": [dict(e, StackName=name) for e in reversed(events)]}
    if op == "wait" and sub == "stack-delete-complete":
        s = stacks.get(name)
        if s and s.get("StackStatus") != "DELETE_COMPLETE":
            raise ApiError("WaiterMaxAttempts", "wait", "Waiter StackDeleteComplete failed: Max attempts exceeded", 255)
        return None
    raise ApiError("FakeUnsupported", f"cloudformation {op}", "not modelled by fake_aws.py", 97)


def handle(state, service, op, sub, opts):
    acct = state.get("account", "")
    key = f"{service} {op}" + (f" {sub}" if sub else "")
    if key == "sts get-caller-identity":
        return {"Account": acct, "Arn": state.get("caller_arn", f"arn:aws:sts::{acct}:assumed-role/test/test"),
                "UserId": "AROATESTEXAMPLE:test"}
    if service == "ec2":
        return handle_ec2(state, op, sub, opts)
    if service == "eks":
        return handle_eks(state, op, sub, opts)
    if service == "iam":
        return handle_iam(state, op, sub, opts, acct)
    if service == "ssm":
        return handle_ssm(state, op, sub, opts, key)
    if service == "cloudformation":
        return handle_cfn(state, op, sub, opts)
    if key == "autoscaling describe-auto-scaling-groups":
        asgs = state.get("autoscaling", {}).get("groups", {})
        names = opts.get("auto-scaling-group-names", [])
        return {"AutoScalingGroups": [dict(asgs[n], AutoScalingGroupName=n) for n in (names or sorted(asgs)) if n in asgs]}
    if key == "autoscaling create-or-update-tags":
        return None
    if key == "service-quotas get-service-quota":
        q = state.get("quotas", {}).get(f"{one(opts, 'service-code')}/{one(opts, 'quota-code')}")
        if q is None:
            raise ApiError("NoSuchResourceException", "GetServiceQuota", "quota not in the test state")
        return {"Quota": {"ServiceCode": one(opts, "service-code"), "QuotaCode": one(opts, "quota-code"), "Value": q}}
    raise ApiError("FakeUnsupported", key, "not modelled by fake_aws.py", 97)


def as_text(v):
    """The AWS CLI text output for the shapes a --query produces."""
    if v is None:
        return "None"
    if isinstance(v, bool):
        return "True" if v else "False"
    if isinstance(v, list):
        if v and all(isinstance(x, list) for x in v):
            return "\n".join(as_text(x) for x in v)
        if v and all(isinstance(x, dict) for x in v):
            return "\n".join(as_text(x) for x in v)
        return "\t".join(as_text(x) for x in v)
    if isinstance(v, dict):
        return "\t".join(as_text(x) for x in v.values())
    return str(v)


def main(argv):
    if argv[:1] == ["--version"]:
        print(f"aws-cli/{os.environ.get('FAKE_AWS_VERSION', '2.31.0')} Python/3.13.7 Linux/6.1 exe/x86_64")
        return 0
    fakelib.require_state("aws")
    try:
        service, op, sub, opts = parse(argv)
    except ApiError as e:
        print(f"fake aws: {e.msg}", file=sys.stderr)
        return e.rc
    call = f"{service} {op}" + (f" {sub}" if sub else "")
    fakelib.log_call("aws", call, argv)
    code = fakelib.injected_failure("aws", call, argv)
    if code:
        if code == "WaiterMaxAttempts":
            print(f"\nWaiter {sub or op} failed: Max attempts exceeded", file=sys.stderr)
            return 255
        print(f"\nAn error occurred ({code}) when calling the {op} operation: injected by the test", file=sys.stderr)
        return 254
    with fakelib.world() as (state, holder):
        try:
            out = handle(state, service, op, sub, opts)
        except ApiError as e:
            holder["save"] = e.rc != 97
            if e.rc == 97:
                print(f"FAKE aws: unexpected call not modelled by the test: {' '.join(argv)} ({e.msg})", file=sys.stderr)
                return 97
            if e.code.startswith("Waiter"):
                print(f"\n{e.msg}", file=sys.stderr)
            else:
                print(f"\nAn error occurred ({e.code}) when calling the {e.op} operation: {e.msg}", file=sys.stderr)
            return e.rc
    if out is not None:
        q = one(opts, "query")
        if q:
            out = jmespath.search(q, out)
        if one(opts, "output") == "text":
            print(as_text(out))
        else:
            print(json.dumps(out, indent=4))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
