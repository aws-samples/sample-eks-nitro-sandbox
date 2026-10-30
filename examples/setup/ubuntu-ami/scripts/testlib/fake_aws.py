#!/usr/bin/env python3
"""A small fake of the AWS CLI, for this sample's clusterless tests only.

It answers the EC2, EKS, IAM, S3, SSM Run Command, STS and Resource Groups Tagging API calls
that 00a-iam.sh, 00b-stage-bucket.sh, clean.sh, join-nodegroup.sh, verify-fresh-instance.sh
and btf-tag.sh make, from a JSON state file, the way the real APIs would: server-side filters and tag
filters, NotFound errors for missing resources, conflicts for deletes that the real API
refuses. It prints JSON unless a call asks for --output text. Every call is appended to a log
the test reads.

Environment:
  FAKE_AWS_STATE  path to the JSON state file (read, updated by mutating calls)
  FAKE_AWS_LOG    path of the call log, one JSON object per line
  FAKE_AWS_FAIL   optional rules "service op|substring|ErrorCode[|N];..." : a call whose
                  "service op" matches and whose joined argv contains substring (empty
                  matches all) fails with that error code, so a test fails only the call
                  under test; with N, only the first N matching calls fail (a transient
                  error). ErrorCode 404 gives the S3 head-bucket "Not Found" shape, and
                  WaiterMaxAttempts what an AWS CLI waiter prints, with exit 255, when it
                  runs out of attempts.

It applies --query (JMESPath, as the CLI does on the client side) and --output text. JMESPath
comes from the jmespath package, pinned in requirements-test.txt next to this file. Without it,
every call stops with exit 98 and an "install jmespath" message before it reads or changes the
state, so a suite goes red rather than passing on calls the fake could not answer.

Any call this fake does not implement exits 97, so an untested call cannot pass silently.
Never put this on the PATH of a real shell: it does nothing against AWS.
"""
import json
import os
import re
import sys

try:
    import jmespath
except ImportError:
    _req = os.path.join(os.path.dirname(os.path.abspath(__file__)), "requirements-test.txt")
    sys.stderr.write(
        "fake_aws.py: the offline tests need the jmespath package (pinned in %s), and the python3 "
        "on PATH does not have it. Install jmespath into a virtual environment under the "
        "repository's tmp/ and put it first on PATH, as the README's Clusterless checks say:\n"
        "  python3 -m venv tmp/ubuntu-ami-tests && tmp/ubuntu-ami-tests/bin/pip install -r %s\n" % (_req, _req))
    sys.exit(98)

ARGV = sys.argv[1:]
STATE_PATH = os.environ.get("FAKE_AWS_STATE", "")
LOG_PATH = os.environ.get("FAKE_AWS_LOG", "")


class ApiError(Exception):
    def __init__(self, code, op, msg="", rc=254):
        super().__init__(code)
        self.code, self.op, self.msg, self.rc = code, op, msg, rc


def parse(argv):
    if len(argv) < 2:
        raise ApiError("ParamValidation", "parse", "need <service> <op>", 252)
    service, op, rest = argv[0], argv[1], argv[2:]
    sub = None
    if op == "wait":
        sub, rest = rest[0], rest[1:]
    opts, key = {}, None
    for tok in rest:
        if tok.startswith("--"):
            key = tok[2:]
            opts.setdefault(key, [])
        elif key is not None:
            opts[key].append(tok)
    return service, op, sub, opts


def one(opts, name, default=None):
    v = opts.get(name)
    return v[0] if v else default


def load():
    with open(STATE_PATH) as f:
        return json.load(f)


def save(state):
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=1)
    os.replace(tmp, STATE_PATH)


def read_value(v):
    if v.startswith("file://"):
        with open(v[len("file://"):]) as f:
            return f.read()
    return v


def tagmap(tags):
    if isinstance(tags, dict):
        return dict(tags)
    return {t["Key"]: t["Value"] for t in tags or []}


def taglist(m):
    return [{"Key": k, "Value": v} for k, v in m.items()]


def shorthand_tags(text):
    return {k: v for k, v in re.findall(r"\{?Key=([^,}\s]+),Value=([^,}\]\s]*)\}?", text)}


def parse_filters(opts):
    out = []
    for f in opts.get("filters", []):
        m = re.fullmatch(r"Name=([^,]+),Values=(.*)", f)
        if not m:
            raise ApiError("InvalidParameterValue", "filters", f"bad filter {f}")
        out.append((m.group(1), m.group(2).split(",")))
    return out


FIELD = {"group-name": "GroupName", "vpc-id": "VpcId", "instance-state-name": "State.Name",
         "launch-template-name": "LaunchTemplateName", "status": "State"}


def get_field(obj, path):
    for part in path.split("."):
        obj = (obj or {}).get(part)
    return obj


def match_filters(obj, filters):
    tags = tagmap(obj.get("Tags", []))
    for name, values in filters:
        if name.startswith("tag:"):
            if tags.get(name[4:]) not in values:
                return False
        elif name in FIELD:
            if get_field(obj, FIELD[name]) not in values:
                return False
        else:
            raise ApiError("InvalidParameterValue", "filters", f"filter {name} not supported by the fake")
    return True


def ec2_describe(state, kind, id_key, ids_opt, opts, notfound):
    items = state["ec2"][kind]
    ids = opts.get(ids_opt, [])
    if ids:
        out = []
        for i in ids:
            hit = [x for x in items if x[id_key] == i]
            if not hit:
                raise ApiError(notfound, "describe", f"The id '{i}' does not exist")
            obj = dict(hit[0])
            if "RecheckTags" in obj:          # what a by-id lookup sees after a tag change
                obj["Tags"] = obj["RecheckTags"]
            obj.pop("RecheckTags", None)
            out.append(obj)
        return out
    filters = parse_filters(opts)
    res = []
    for x in items:
        if match_filters(x, filters):
            obj = dict(x)
            obj.pop("RecheckTags", None)
            res.append(obj)
    return res


def read_tags(obj):
    """An IAM role's or S3 bucket's tags as one read returns them. Another owner can re-tag it
    between reads: "TagsAfterFirstRead" (tags) takes effect from the second read,
    "TagsAfterReads" ({"after": n, "tags": [...]}) from read n + 1, and "TransientTagsOnRead"
    ({"read": n, "tags": [...]}) on read n only (every other read answers its own tags)."""
    obj["TagReads"] = obj.get("TagReads", 0) + 1
    once = obj.get("TransientTagsOnRead")
    if once and obj["TagReads"] == once["read"]:
        return once["tags"]
    if "TagsAfterFirstRead" in obj and obj["TagReads"] > 1:
        return obj["TagsAfterFirstRead"]
    later = obj.get("TagsAfterReads")
    if later and obj["TagReads"] > later["after"]:
        return later["tags"]
    return obj.get("Tags", [])


def acct(state):
    return state.get("account", "")


def handle(state, service, op, sub, opts):
    a = acct(state)
    key = f"{service} {op}" + (f" {sub}" if sub else "")
    # ---------------- STS
    if key == "sts get-caller-identity":
        return {"Account": a, "Arn": f"arn:aws:sts::{a}:assumed-role/test/test", "UserId": "TEST"}
    # ---------------- EC2
    if service == "ec2":
        e = state.setdefault("ec2", {})
        for k in ("instances", "images", "snapshots", "security_groups", "launch_templates", "volumes"):
            e.setdefault(k, [])
        # EBS volumes: {"VolumeId", "State": "in-use"|"available", "AttachedTo": <instance id>,
        # "DeleteOnTermination": bool, "Tags"}. Terminating an instance deletes the volumes it
        # holds with DeleteOnTermination and leaves the others "available", as EC2 does.
        if op == "describe-volumes":
            return {"Volumes": ec2_describe(state, "volumes", "VolumeId", "volume-ids", opts, "InvalidVolume.NotFound")}
        if op == "delete-volume":
            i = one(opts, "volume-id")
            hit = [x for x in e["volumes"] if x["VolumeId"] == i]
            if not hit:
                raise ApiError("InvalidVolume.NotFound", op, i)
            if hit[0]["State"] != "available":
                raise ApiError("VolumeInUse", op, f"Volume {i} is currently attached")
            e["volumes"] = [x for x in e["volumes"] if x["VolumeId"] != i]
            return None
        if op == "wait" and sub == "volume-deleted":
            for i in opts.get("volume-ids", []):
                if any(x["VolumeId"] == i for x in e["volumes"]):
                    raise ApiError("WaiterFailed", "wait", f"{i} not deleted", 255)
            return None
        if op == "describe-instances":
            inst = ec2_describe(state, "instances", "InstanceId", "instance-ids", opts, "InvalidInstanceID.NotFound")
            return {"Reservations": [{"Instances": inst}] if inst else []}
        if op == "describe-images":
            for x in e["images"]:   # an image create-image made moves on by one read
                if "PendingReads" in x and x["ImageId"] in opts.get("image-ids", []):
                    x["Reads"] = x.get("Reads", 0) + 1
                    x["State"] = "pending" if x["Reads"] <= x["PendingReads"] else x.get("Final", "available")
            return {"Images": ec2_describe(state, "images", "ImageId", "image-ids", opts, "InvalidAMIID.NotFound")}
        if op == "describe-snapshots":
            return {"Snapshots": ec2_describe(state, "snapshots", "SnapshotId", "snapshot-ids", opts, "InvalidSnapshot.NotFound")}
        if op == "describe-security-groups":
            return {"SecurityGroups": ec2_describe(state, "security_groups", "GroupId", "group-ids", opts, "InvalidGroup.NotFound")}
        if op == "describe-launch-templates":
            return {"LaunchTemplates": ec2_describe(state, "launch_templates", "LaunchTemplateId", "launch-template-ids", opts, "InvalidLaunchTemplateId.NotFound")}
        if op == "terminate-instances":
            out = []
            for i in opts.get("instance-ids", []):
                hit = [x for x in e["instances"] if x["InstanceId"] == i]
                if not hit:
                    raise ApiError("InvalidInstanceID.NotFound", op, i)
                hit[0]["State"] = {"Name": "terminated"}
                for v in [v for v in e["volumes"] if v.get("AttachedTo") == i]:
                    if v.get("DeleteOnTermination"):
                        e["volumes"].remove(v)
                    else:
                        v["State"], v["AttachedTo"] = "available", None
                out.append({"InstanceId": i})
            return {"TerminatingInstances": out}
        if op == "deregister-image":
            i = one(opts, "image-id")
            if not any(x["ImageId"] == i for x in e["images"]):
                raise ApiError("InvalidAMIID.NotFound", op, i)
            e["images"] = [x for x in e["images"] if x["ImageId"] != i]
            return {}
        if op == "delete-snapshot":
            i = one(opts, "snapshot-id")
            if not any(x["SnapshotId"] == i for x in e["snapshots"]):
                raise ApiError("InvalidSnapshot.NotFound", op, i)
            for img in e["images"]:
                if any((b.get("Ebs") or {}).get("SnapshotId") == i for b in img.get("BlockDeviceMappings", [])):
                    raise ApiError("InvalidSnapshot.InUse", op, f"{i} is in use by {img['ImageId']}")
            e["snapshots"] = [x for x in e["snapshots"] if x["SnapshotId"] != i]
            return {}
        if op == "delete-security-group":
            i = one(opts, "group-id")
            if not any(x["GroupId"] == i for x in e["security_groups"]):
                raise ApiError("InvalidGroup.NotFound", op, i)
            e["security_groups"] = [x for x in e["security_groups"] if x["GroupId"] != i]
            return {}
        if op == "delete-launch-template":
            i = one(opts, "launch-template-id")
            if not any(x["LaunchTemplateId"] == i for x in e["launch_templates"]):
                raise ApiError("InvalidLaunchTemplateId.NotFound", op, i)
            e["launch_templates"] = [x for x in e["launch_templates"] if x["LaunchTemplateId"] != i]
            return {"LaunchTemplate": {"LaunchTemplateId": i}}
        if op == "wait" and sub == "instance-terminated":
            for i in opts.get("instance-ids", []):
                hit = [x for x in e["instances"] if x["InstanceId"] == i]
                if hit and hit[0]["State"]["Name"] != "terminated":
                    raise ApiError("WaiterFailed", "wait", f"{i} not terminated", 255)
            return None
        if op == "wait" and sub in ("instance-status-ok", "image-available"):
            return None
        if op == "run-instances":
            spec = json.loads(read_value(one(opts, "cli-input-json", "{}")))
            n = len(e["instances"]) + 1
            iid = f"i-fakerun{n:03d}"
            tags = {}
            for ts in spec.get("TagSpecifications", []):
                if ts.get("ResourceType") == "instance":
                    tags = tagmap(ts.get("Tags", []))
            e["instances"].append({"InstanceId": iid, "State": {"Name": "pending"}, "Tags": taglist(tags),
                                   "ImageId": spec.get("ImageId"), "BootId": f"00000000-0000-4000-8000-b{n:011d}",
                                   "Kernel": state.get("boot", {}).get("first_kernel", "stock-kernel")})
            return {"Instances": [{"InstanceId": iid}]}
        # A reboot gives the instance a new boot id and the kernel state["boot"]["after_reboot"]
        # (the default: the one 10-kernel.sh installs); state["boot"]["no_reboot"] keeps both.
        # Boot ids end b<n> (first boot) and c<n> (n-th reboot), 11 digits after the letter.
        if op == "reboot-instances":
            b = state.get("boot", {})
            for i in opts.get("instance-ids", []):
                hit = [x for x in e["instances"] if x["InstanceId"] == i]
                if not hit:
                    raise ApiError("InvalidInstanceID.NotFound", op, i)
                if not b.get("no_reboot"):
                    hit[0]["Reboots"] = hit[0].get("Reboots", 0) + 1
                    hit[0]["BootId"] = f"00000000-0000-4000-9000-c{hit[0]['Reboots']:011d}"
                    hit[0]["Kernel"] = b.get("after_reboot", "6.18.56-nitro-ga")
            return None
        if op == "describe-subnets":
            subs = [s for s in state.get("ec2", {}).get("subnets", []) if s["SubnetId"] in opts.get("subnet-ids", [])]
            if len(subs) != len(opts.get("subnet-ids", [])):
                raise ApiError("InvalidSubnetID.NotFound", op, str(opts.get("subnet-ids")))
            return {"Subnets": subs}
        if op == "create-security-group":
            n = len(e["security_groups"]) + 1
            gid = f"sg-fakerun{n:03d}"
            tags = {}
            for ts in opts.get("tag-specifications", []):
                tags.update(shorthand_tags(ts))
            e["security_groups"].append({"GroupId": gid, "GroupName": one(opts, "group-name"), "VpcId": one(opts, "vpc-id"),
                                         "IpPermissions": [], "Tags": taglist(tags)})
            return {"GroupId": gid}
        # create-image: the image is "pending" for state["image"]["pending_reads"] describe-images
        # reads by id, then state["image"]["final"] (default "available"). The id is hex, as a
        # real one is (ami-0fa002 for the second image), so setup.sh's ^ami-[0-9a-f]+$ checks hold.
        if op == "create-image":
            n = len(e["images"]) + 1
            img = {"ImageId": f"ami-0fa{n:03d}", "Name": one(opts, "name"), "State": "pending", "Reads": 0,
                   "PendingReads": state.get("image", {}).get("pending_reads", 0),
                   "Final": state.get("image", {}).get("final", "available"), "Tags": []}
            snap = {"SnapshotId": f"snap-fakerun{n:03d}", "VolumeSize": 120, "Tags": []}
            for ts in opts.get("tag-specifications", []):
                if ts.startswith("ResourceType=image,"):
                    img["Tags"] = taglist(shorthand_tags(ts))
                elif ts.startswith("ResourceType=snapshot,"):
                    snap["Tags"] = taglist(shorthand_tags(ts))
            img["BlockDeviceMappings"] = [{"DeviceName": "/dev/sda1", "Ebs": {"SnapshotId": snap["SnapshotId"]}}]
            e["images"].append(img)
            e["snapshots"].append(snap)
            return {"ImageId": img["ImageId"]}
        if op == "create-tags":
            new = {}
            for t in opts.get("tags", []):
                new.update(shorthand_tags(t))
            for rid in opts.get("resources", []):
                hit = [x for x in e["images"] if x["ImageId"] == rid]
                if not hit:
                    raise ApiError("InvalidAMIID.NotFound", op, rid)
                t = tagmap(hit[0].get("Tags", []))
                t.update(new)
                hit[0]["Tags"] = taglist(t)
            return None
        if op == "create-launch-template":
            n = len(e["launch_templates"]) + 1
            lid = f"lt-fakerun{n:03d}"
            tags = {}
            for ts in opts.get("tag-specifications", []):
                tags.update(shorthand_tags(ts))
            e["launch_templates"].append({"LaunchTemplateId": lid, "LaunchTemplateName": one(opts, "launch-template-name"),
                                          "Tags": taglist(tags)})
            return {"LaunchTemplate": {"LaunchTemplateId": lid}}
    # ---------------- EKS
    if service == "eks":
        k = state.setdefault("eks", {})
        ngs = k.setdefault("nodegroups", {})
        cl, ng = one(opts, "cluster-name"), one(opts, "nodegroup-name")
        if op == "describe-cluster":
            c = k.get("clusters", {}).get(one(opts, "name"))
            if not c:
                raise ApiError("ResourceNotFoundException", "DescribeCluster", "No cluster found")
            return {"cluster": c}
        if op == "describe-addon":
            ad = k.get("addons", {}).get(f"{cl}/{one(opts, 'addon-name')}")
            if not ad:
                raise ApiError("ResourceNotFoundException", "DescribeAddon", f"No addon: {one(opts, 'addon-name')} found in cluster: {cl}")
            return {"addon": ad}
        # access entries, keyed "<cluster>/<principal ARN>" (an ARN holds '/', the cluster name never)
        aes = k.setdefault("access_entries", {})
        if op == "list-access-entries":
            return {"accessEntries": sorted(x.split("/", 1)[1] for x in aes if x.split("/", 1)[0] == cl)}
        if op == "delete-access-entry":
            ak = f"{cl}/{one(opts, 'principal-arn')}"
            if ak not in aes:
                raise ApiError("ResourceNotFoundException", "DeleteAccessEntry", "The specified access entry resource is not found.")
            if aes[ak].get("StaysAfterDelete"):   # a delete that answers success and leaves the entry
                return {}
            del aes[ak]
            return {}
        nk = f"{cl}/{ng}"
        if op == "list-nodegroups":
            return {"nodegroups": sorted(k_.split("/", 1)[1] for k_ in ngs if k_.split("/", 1)[0] == cl)}
        if op == "describe-nodegroup":
            if nk not in ngs:
                raise ApiError("ResourceNotFoundException", "DescribeNodegroup", f"No node group found for name: {ng}.")
            return {"nodegroup": dict(ngs[nk], nodegroupName=ng, clusterName=cl)}
        if op == "delete-nodegroup":
            if nk not in ngs:
                raise ApiError("ResourceNotFoundException", "DeleteNodegroup", ng)
            del ngs[nk]
            return {"nodegroup": {"nodegroupName": ng, "status": "DELETING"}}
        if op == "create-nodegroup":
            tags = dict(t.split("=", 1) for t in ",".join(opts.get("tags", [])).split(",") if "=" in t)
            ngs[nk] = {"status": "ACTIVE", "tags": tags}
            return {"nodegroup": {"nodegroupName": ng, "status": "CREATING"}}
        if op == "wait" and sub == "nodegroup-deleted":
            if nk in ngs:
                raise ApiError("WaiterFailed", "wait", f"{ng} still exists", 255)
            return None
        if op == "wait" and sub == "nodegroup-active":
            return None
    # ---------------- IAM
    if service == "iam":
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
        arn = lambda n: f"arn:aws:iam::{a}:role/{n}"
        if op == "list-roles":
            return {"Roles": [{"RoleName": n, "Arn": arn(n)} for n in sorted(roles)]}
        if op == "get-role":
            r = role()
            return {"Role": {"RoleName": rn, "Arn": arn(rn), "AssumeRolePolicyDocument": r.get("Trust", {})}}
        if op == "create-role":
            if rn in roles:
                raise ApiError("EntityAlreadyExists", op, rn)
            roles[rn] = {"Trust": json.loads(read_value(one(opts, "assume-role-policy-document"))),
                         "Tags": taglist(shorthand_tags(" ".join(opts.get("tags", [])))), "Attached": [], "Inline": {}}
            return {"Role": {"RoleName": rn, "Arn": arn(rn)}}
        if op == "list-role-tags":
            r = role()
            t = read_tags(r)
            # "GoneAfterReads": n, another owner deleted the role after tag read n: from read n + 1
            # its tags answer NoSuchEntity (only the tag reads; nothing else sees it go).
            if r.get("GoneAfterReads") is not None and r["TagReads"] > r["GoneAfterReads"]:
                raise ApiError("NoSuchEntity", op, f"The role with name {rn} cannot be found.")
            return {"Tags": t}
        if op == "attach-role-policy":
            r = role()
            p = one(opts, "policy-arn")
            if p not in r["Attached"]:
                r["Attached"].append(p)
            return None
        if op == "detach-role-policy":
            r = role()
            p = one(opts, "policy-arn")
            if p not in r["Attached"]:
                raise ApiError("NoSuchEntity", op, p)
            r["Attached"].remove(p)
            return None
        if op == "list-attached-role-policies":
            return {"AttachedPolicies": [{"PolicyArn": p, "PolicyName": p.rsplit("/", 1)[-1]} for p in role()["Attached"]]}
        if op == "list-role-policies":
            return {"PolicyNames": sorted(role()["Inline"])}
        if op == "put-role-policy":
            role()["Inline"][one(opts, "policy-name")] = json.loads(read_value(one(opts, "policy-document")))
            return None
        if op == "get-role-policy":
            p = one(opts, "policy-name")
            if p not in role()["Inline"]:
                raise ApiError("NoSuchEntity", op, f"The role policy with name {p} cannot be found.")
            return {"RoleName": rn, "PolicyName": p, "PolicyDocument": role()["Inline"][p]}
        if op == "delete-role-policy":
            p = one(opts, "policy-name")
            if p not in role()["Inline"]:
                raise ApiError("NoSuchEntity", op, p)
            del role()["Inline"][p]
            return None
        if op == "delete-role":
            r = role()
            if r["Attached"] or r["Inline"] or any(rn in pr["Roles"] for pr in profiles.values()):
                raise ApiError("DeleteConflict", op, "Cannot delete entity, must detach all policies first.")
            del roles[rn]
            return None
        if op == "get-instance-profile":
            p = prof()
            return {"InstanceProfile": {"InstanceProfileName": pn, "Roles": [{"RoleName": x} for x in p["Roles"]],
                                        "Tags": p.get("Tags", [])}}
        if op == "create-instance-profile":
            if pn in profiles:
                raise ApiError("EntityAlreadyExists", op, pn)
            profiles[pn] = {"Roles": [], "Tags": taglist(shorthand_tags(" ".join(opts.get("tags", []))))}
            return {"InstanceProfile": {"InstanceProfileName": pn}}
        if op == "list-instance-profiles":
            return {"InstanceProfiles": [{"InstanceProfileName": n} for n in sorted(profiles)]}
        if op == "list-instance-profile-tags":
            return {"Tags": prof().get("Tags", [])}
        if op == "add-role-to-instance-profile":
            p = prof()
            if p["Roles"]:
                raise ApiError("LimitExceeded", op, "Cannot exceed quota for InstanceSessionsPerInstanceProfile: 1")
            role()
            p["Roles"].append(rn)
            return None
        if op == "remove-role-from-instance-profile":
            p = prof()
            if rn not in p["Roles"]:
                raise ApiError("NoSuchEntity", op, rn)
            p["Roles"].remove(rn)
            return None
        if op == "delete-instance-profile":
            p = prof()
            if p["Roles"]:
                raise ApiError("DeleteConflict", op, "Cannot delete entity, must remove roles from instance profile first.")
            del profiles[pn]
            return None
        if op == "list-instance-profiles-for-role":
            role()
            return {"InstanceProfiles": [{"InstanceProfileName": n} for n, p in profiles.items() if rn in p["Roles"]]}
        if op == "wait" and sub == "instance-profile-exists":
            prof()
            return None
    # ---------------- SSM (Run Command), as verify-fresh-instance.sh uses it
    # state["ssm"] = {"online": bool, "results": [{"match": substring of the command,
    #                 "Status": "Success"|"Failed", "stdout": str, "stderr": str}], "commands": {}}
    if service == "ssm":
        m = state.setdefault("ssm", {})
        cmds = m.setdefault("commands", {})
        # Bound to EC2: only an instance that exists and is pending or running is registered
        # with SSM, a command targets exactly one such instance, and a wait or an invocation read
        # must name the command's own instance.
        live = {x["InstanceId"] for x in state.get("ec2", {}).get("instances", [])
                if x["State"]["Name"] in ("pending", "running")}
        if op == "describe-instance-information":
            ids = []
            for f in opts.get("filters", []):
                mm = re.fullmatch(r"Key=InstanceIds,Values=(.*)", f)
                if not mm:
                    raise ApiError("InvalidFilterKey", op, f"filter {f} not supported by the fake")
                ids += mm.group(1).split(",")
            if not ids:
                raise ApiError("InvalidFilterKey", op, "the fake answers only an InstanceIds filter")
            online = m.get("online", True)
            return {"InstanceInformationList": [{"InstanceId": i, "PingStatus": "Online"} for i in ids if online and i in live]}
        if op == "send-command":
            targets = opts.get("instance-ids", [])
            if len(targets) != 1 or targets[0] not in live:
                raise ApiError("InvalidInstanceId", op, f"instance {targets} is not registered with SSM")
            text = " ".join(opts.get("parameters", []))
            res = next((r for r in m.get("results", []) if r["match"] in text), None)
            if res is None:
                raise ApiError("FakeUnsupported", key, "no ssm result for this command", 97)
            cid = f"cmd-{len(cmds) + 1:03d}"
            c = dict(res, instance=targets[0])
            if c.get("stdout") == "@bootinfo":   # the instance's own boot id and kernel release
                inst = [x for x in state["ec2"]["instances"] if x["InstanceId"] == targets[0]][0]
                c["stdout"] = f"{inst.get('BootId', '00000000-0000-4000-8000-b00000000001')}\n{inst.get('Kernel', 'stock-kernel')}\n"
            cmds[cid] = c
            return {"Command": {"CommandId": cid}}
        # A result may carry "progress": n, the number of reads that see it InProgress before its
        # final Status, and "reads": the reads so far.
        if op in ("get-command-invocation",) or (op == "wait" and sub == "command-executed"):
            c = cmds.get(one(opts, "command-id"))
            if c is None or c["instance"] != one(opts, "instance-id"):
                raise ApiError("InvocationDoesNotExist", op, "no such command on that instance")
            if op == "wait":
                # The CLI waiter: 20 attempts 5 s apart, then exit 255 (botocore waiters-2.json).
                c["reads"] = c.get("reads", 0) + 20
                if c["reads"] <= c.get("progress", 0):
                    raise ApiError("WaiterMaxAttempts", "wait", "Waiter CommandExecuted failed: Max attempts exceeded", 255)
                if c["Status"] != "Success":
                    raise ApiError("WaiterFailure", "wait", f"Waiter CommandExecuted failed: terminal status {c['Status']}", 255)
                return None
            c["reads"] = c.get("reads", 0) + 1
            if c["reads"] <= c.get("progress", 0):
                return {"Status": "InProgress", "StandardOutputContent": "", "StandardErrorContent": ""}
            return {"Status": c["Status"], "StandardOutputContent": c.get("stdout", ""), "StandardErrorContent": c.get("stderr", "")}
        if op == "get-parameter":
            p = m.get("parameters", {}).get(one(opts, "name"))
            if p is None:
                raise ApiError("ParameterNotFound", op, one(opts, "name"))
            return {"Parameter": {"Name": one(opts, "name"), "Value": p}}
    # ---------------- Resource Groups Tagging API
    if key == "resourcegroupstaggingapi get-resources":
        types = opts.get("resource-type-filters", [])
        want = []
        for tf in opts.get("tag-filters", []):
            m = re.fullmatch(r"Key=([^,]+),Values=(.*)", tf)
            want.append((m.group(1), m.group(2).split(",")))
        out = []
        cands = []
        # "The GetResources operation does not currently support IAM users and roles" (Resource
        # Groups Tagging API reference), so an iam:role filter finds nothing here either: a
        # script that discovers roles this way sees none and leaves them behind.
        if "s3" in types:
            cands += [(f"arn:aws:s3:::{n}", b.get("Tags", [])) for n, b in state.get("s3", {}).get("buckets", {}).items()]
        for arn_, tags in cands:
            t = tagmap(tags)
            if all(t.get(k) in v for k, v in want):
                out.append({"ResourceARN": arn_, "Tags": tags})
        return {"ResourceTagMappingList": out}
    # ---------------- S3
    if service == "s3api":
        buckets = state.setdefault("s3", {}).setdefault("buckets", {})
        b = one(opts, "bucket")
        exp = one(opts, "expected-bucket-owner")
        if op == "create-bucket":
            if b in buckets:
                raise ApiError("BucketAlreadyOwnedByYou", op, b)
            buckets[b] = {"owner": a, "Tags": [], "objects": []}
            return {"Location": f"http://{b}.s3.amazonaws.com/"}
        if b not in buckets:
            if op == "head-bucket":
                raise ApiError("404", "HeadBucket", "Not Found")
            raise ApiError("NoSuchBucket", op, "The specified bucket does not exist")
        bk = buckets[b]
        if exp is not None and exp != bk.get("owner", a):
            raise ApiError("AccessDenied", op, "Access Denied (expected bucket owner does not match)")
        if op == "head-bucket":
            return {"BucketRegion": "us-west-2"}
        if op == "get-bucket-tagging":
            t = read_tags(bk)
            if not t:
                raise ApiError("NoSuchTagSet", "GetBucketTagging", "The TagSet does not exist")
            return {"TagSet": t}
        if op == "put-bucket-tagging":
            bk["Tags"] = taglist(shorthand_tags(one(opts, "tagging", "")))
            return None
        if op in ("put-public-access-block", "put-bucket-encryption", "put-bucket-policy"):
            bk.setdefault("config", {})[op] = True
            return None
        if op == "put-object":
            k_ = one(opts, "key")
            if k_ not in bk.setdefault("objects", []):
                bk["objects"].append(k_)
            return {"ChecksumSHA256": one(opts, "checksum-sha256", "")}
        if op == "list-objects-v2":
            objs = bk.get("objects", [])
            return {"Contents": [{"Key": k} for k in objs], "KeyCount": len(objs)} if objs else {"KeyCount": 0}
        if op == "delete-objects":
            req = json.loads(read_value(one(opts, "delete")))
            keys = [o["Key"] for o in req.get("Objects", [])]
            bk["objects"] = [k for k in bk.get("objects", []) if k not in keys]
            return {"Deleted": [{"Key": k} for k in keys]}
        if op == "delete-object":
            k_ = one(opts, "key")
            bk["objects"] = [k for k in bk.get("objects", []) if k != k_]
            return {}
        if op == "delete-bucket":
            if bk.get("objects"):
                raise ApiError("BucketNotEmpty", op, "The bucket you tried to delete is not empty")
            del buckets[b]
            return None
    raise ApiError("FakeUnsupported", key, "not implemented by fake_aws.py", 97)


def main():
    try:
        service, op, sub, opts = parse(ARGV)
    except ApiError as e:
        print(f"fake aws: {e.msg}", file=sys.stderr)
        return e.rc
    entry = {"argv": ARGV, "call": f"{service} {op}" + (f" {sub}" if sub else "")}
    for opt, field in (("cli-input-json", "cli_input_json"), ("launch-template-data", "launch_template_data")):
        v = one(opts, opt)
        if v:
            entry[field] = json.loads(read_value(v))
    if LOG_PATH:
        with open(LOG_PATH, "a") as f:
            f.write(json.dumps(entry) + "\n")
    joined = " ".join(ARGV)
    for n, rule in enumerate(filter(None, os.environ.get("FAKE_AWS_FAIL", "").split(";"))):
        call, substr, code, times = (rule.split("|") + ["", "", ""])[:4]
        if call.strip() == entry["call"] and substr in joined:
            if times:   # fail only the first <times> matching calls (a transient error)
                cpath = STATE_PATH + ".failcounts"
                counts = json.load(open(cpath)) if os.path.exists(cpath) else {}
                counts[str(n)] = counts.get(str(n), 0) + 1
                json.dump(counts, open(cpath, "w"))
                if counts[str(n)] > int(times):
                    continue
            if code == "404":
                print("\nAn error occurred (404) when calling the HeadBucket operation: Not Found", file=sys.stderr)
            elif code == "WaiterMaxAttempts":   # what an AWS CLI waiter prints when it runs out of attempts
                print(f"\nWaiter {sub or op} failed: Max attempts exceeded", file=sys.stderr)
                return 255
            else:
                print(f"\nAn error occurred ({code or 'AccessDenied'}) when calling the {op} operation: injected by the test", file=sys.stderr)
            return 254
    state = load()
    try:
        out = handle(state, service, op, sub, opts)
    except ApiError as e:
        if e.rc == 97:
            print(f"FAKE aws: unexpected call not covered by the test: {joined}", file=sys.stderr)
            return 97
        if e.code == "404":
            print("\nAn error occurred (404) when calling the HeadBucket operation: Not Found", file=sys.stderr)
        else:
            print(f"\nAn error occurred ({e.code}) when calling the {e.op} operation: {e.msg}", file=sys.stderr)
        return e.rc
    save(state)
    if out is not None:
        q = one(opts, "query")
        if q:   # the CLI applies --query (JMESPath) on the client side; so does the fake
            out = jmespath.search(q, out)
        if one(opts, "output") == "text":
            print(as_text(out))
        else:
            print(json.dumps(out))
    return 0


def as_text(v):
    """The AWS CLI's text output for the shapes this sample's --query calls produce: a scalar on
    one line ("None" for null), a list of scalars tab-joined, a list of lists one row each."""
    if v is None:
        return "None"
    if isinstance(v, bool):
        return "True" if v else "False"
    if isinstance(v, list):
        if all(isinstance(x, list) for x in v) and v:
            return "\n".join(as_text(x) for x in v)
        return "\t".join(as_text(x) for x in v)
    if isinstance(v, dict):
        return "\t".join(as_text(x) for x in v.values())
    return str(v)


if __name__ == "__main__":
    sys.exit(main())
