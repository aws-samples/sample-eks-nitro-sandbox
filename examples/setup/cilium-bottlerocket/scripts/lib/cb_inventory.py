"""The resource-class inventory (resource-classes.yaml): discovery, tag sweep, tag audit and
the clean-up listing of scripts/cilium_bottlerocket.py.

Every discovery is a read. A failed read is Unknown (exit 2), never "nothing found".
"""

import json

import yaml

from cb_base import (OWNER_TAG, SAMPLE, Unknown, aws, is_ours, require, run_id, setting, state_get,
                     tag_list, tag_map)


def classes():
    try:
        doc = yaml.safe_load((SAMPLE / "scripts/lib/resource-classes.yaml").read_text())
    except (OSError, yaml.YAMLError) as err:
        raise Unknown("could not read scripts/lib/resource-classes.yaml") from err
    return doc["classes"], doc["vpc_types"]


def vpc_id():
    vpc = state_get("VPC_ID")
    if not vpc:
        raise Unknown("the state file has no VPC_ID")
    return vpc


def by_vpc(_kind=""):
    return [f"Name=vpc-id,Values={vpc_id()}"]


def tagged():
    return [f"Name=tag:{OWNER_TAG[0]},Values={OWNER_TAG[1]}", f"Name=tag:RunId,Values={run_id()}"]


def item(ident, tags, **extra):
    return {"id": ident, "tags": tag_map(tags or []) or {}, **extra}


def cluster_doc():
    doc = aws("eks", "describe-cluster", "--name", setting("CLUSTER_NAME"), allow=("ResourceNotFoundException",))
    return None if doc is None else doc["cluster"]


def nodegroup_docs():
    names = aws("eks", "list-nodegroups", "--cluster-name", setting("CLUSTER_NAME"),
                allow=("ResourceNotFoundException",))
    out = []
    for name in (names or {}).get("nodegroups", []):
        out.append(aws("eks", "describe-nodegroup", "--cluster-name", setting("CLUSTER_NAME"), "--nodegroup-name", name)["nodegroup"])
    return out


def enis(filters):
    return aws("ec2", "describe-network-interfaces", "--filters", *filters)["NetworkInterfaces"]


# ---- One discovery function per class (names as in resource-classes.yaml) ----
def d_stacks():
    out = []
    pages = aws("cloudformation", "describe-stacks")["Stacks"]
    for s in pages:
        tags = tag_map(s.get("Tags", [])) or {}
        if tags.get("alpha.eksctl.io/cluster-name") == setting("CLUSTER_NAME") and s["StackStatus"] != "DELETE_COMPLETE":
            out.append(item(s["StackName"], s.get("Tags"), status=s["StackStatus"]))
    return out


def d_cluster():
    c = cluster_doc()
    return [] if c is None else [item(c["name"], c.get("tags"), status=c["status"])]


def d_addons():
    if cluster_doc() is None:
        return []
    out = []
    for name in aws("eks", "list-addons", "--cluster-name", setting("CLUSTER_NAME"))["addons"]:
        a = aws("eks", "describe-addon", "--cluster-name", setting("CLUSTER_NAME"), "--addon-name", name)["addon"]
        out.append(item(name, a.get("tags")))
    return out


def d_vpc():
    doc = aws("ec2", "describe-vpcs", "--vpc-ids", vpc_id(), allow=("InvalidVpcID.NotFound",)) or {"Vpcs": []}
    return [item(v["VpcId"], v.get("Tags")) for v in doc["Vpcs"]]


def d_subnets():
    return [item(s["SubnetId"], s.get("Tags")) for s in aws("ec2", "describe-subnets", "--filters", *by_vpc("s"))["Subnets"]]


def route_tables():
    return aws("ec2", "describe-route-tables", "--filters", *by_vpc("r"))["RouteTables"]


def is_main(rt):
    return any(a.get("Main") for a in rt.get("Associations", []))


def d_route_tables():
    return [item(r["RouteTableId"], r.get("Tags")) for r in route_tables() if not is_main(r)]


def d_main_route_table():
    return [item(r["RouteTableId"], r.get("Tags")) for r in route_tables() if is_main(r)]


def d_network_acls():
    return [item(a["NetworkAclId"], a.get("Tags")) for a in aws("ec2", "describe-network-acls", "--filters", *by_vpc("a"))["NetworkAcls"]]


def d_internet_gateways():
    return [item(g["InternetGatewayId"], g.get("Tags")) for g in aws(
        "ec2", "describe-internet-gateways", "--filters", f"Name=attachment.vpc-id,Values={vpc_id()}")["InternetGateways"]]


def nats():
    return [n for n in aws("ec2", "describe-nat-gateways", "--filter", *by_vpc("n"))["NatGateways"] if n["State"] != "deleted"]


def d_nat_gateways():
    return [item(n["NatGatewayId"], n.get("Tags"), state=n["State"]) for n in nats()]


def d_elastic_ips():
    ids = {a["AllocationId"] for n in nats() for a in n.get("NatGatewayAddresses", []) if a.get("AllocationId")}
    found = aws("ec2", "describe-addresses", "--filters", *tagged())["Addresses"]
    ids |= {a["AllocationId"] for a in found}
    if not ids:
        return []
    return [item(a["AllocationId"], a.get("Tags")) for a in aws("ec2", "describe-addresses", "--allocation-ids", *sorted(ids))["Addresses"]]


def security_groups():
    return aws("ec2", "describe-security-groups", "--filters", *by_vpc("g"))["SecurityGroups"]


def cluster_sg_id():
    c = cluster_doc()
    return (c or {}).get("resourcesVpcConfig", {}).get("clusterSecurityGroupId", "")


def d_stack_security_groups():
    special = {cluster_sg_id(), state_get("BUILDER_SG_ID")}
    return [item(g["GroupId"], g.get("Tags")) for g in security_groups() if g["GroupName"] != "default" and g["GroupId"] not in special]


def d_default_security_group():
    return [item(g["GroupId"], g.get("Tags")) for g in security_groups() if g["GroupName"] == "default"]


def d_cluster_security_group():
    sg = cluster_sg_id()
    return [item(g["GroupId"], g.get("Tags")) for g in security_groups() if g["GroupId"] == sg] if sg else []


def all_enis():
    return enis(by_vpc("e"))


def d_control_plane_enis():
    want = f"Amazon EKS {setting('CLUSTER_NAME')}"
    return [item(e["NetworkInterfaceId"], e.get("TagSet")) for e in all_enis() if e.get("Description") == want]


def d_nat_enis():
    ids = {a.get("NetworkInterfaceId") for n in nats() for a in n.get("NatGatewayAddresses", [])}
    return [item(e["NetworkInterfaceId"], e.get("TagSet")) for e in all_enis() if e["NetworkInterfaceId"] in ids]


def d_cilium_enis():
    return [item(e["NetworkInterfaceId"], e.get("TagSet"), status=e["Status"]) for e in all_enis()
            if (tag_map(e.get("TagSet", [])) or {}).get("io.cilium/cilium-managed") == "true"]


def d_roles():
    names = {setting("OPERATOR_ROLE_NAME")}
    for ng in nodegroup_docs():
        names.add(ng["nodeRole"].rsplit("/", 1)[1])
    c = cluster_doc()
    if c is not None:
        names.add(c["roleArn"].rsplit("/", 1)[1])
    out = []
    for name in sorted(names):
        doc = aws("iam", "list-role-tags", "--role-name", name, allow=("NoSuchEntity",))
        if doc is not None:
            out.append(item(name, doc.get("Tags")))
    return out


def d_pod_identity():
    if cluster_doc() is None:
        return []
    out = []
    for a in aws("eks", "list-pod-identity-associations", "--cluster-name", setting("CLUSTER_NAME"))["associations"]:
        doc = aws("eks", "describe-pod-identity-association", "--cluster-name", setting("CLUSTER_NAME"),
                  "--association-id", a["associationId"])["association"]
        out.append(item(a["associationId"], doc.get("tags"), service_account=f"{a['namespace']}/{a['serviceAccount']}"))
    return out


def d_launch_templates():
    names = {setting("SYSTEM_LT_NAME"), setting("SANDBOX_LT_NAME")}
    found = aws("ec2", "describe-launch-templates", "--filters", *tagged())["LaunchTemplates"]
    return [item(t["LaunchTemplateId"], t.get("Tags"), name=t["LaunchTemplateName"]) for t in found
            if t["LaunchTemplateName"] in names]


def d_nodegroups():
    return [item(ng["nodegroupName"], ng.get("tags"), status=ng["status"]) for ng in nodegroup_docs()]


def asg_docs():
    names = [a["name"] for ng in nodegroup_docs() for a in ng.get("resources", {}).get("autoScalingGroups", [])]
    if not names:
        return []
    return aws("autoscaling", "describe-auto-scaling-groups", "--auto-scaling-group-names", *names)["AutoScalingGroups"]


def d_asgs():
    return [item(a["AutoScalingGroupName"], [{"Key": t["Key"], "Value": t["Value"]} for t in a.get("Tags", [])]) for a in asg_docs()]


def d_lt_copies():
    ids = set()
    for a in asg_docs():
        lt = a.get("LaunchTemplate") or (a.get("MixedInstancesPolicy") or {}).get("LaunchTemplate", {}).get("LaunchTemplateSpecification", {})
        if lt.get("LaunchTemplateId"):
            ids.add(lt["LaunchTemplateId"])
    ours = {state_get("SYSTEM_LAUNCH_TEMPLATE_ID"), state_get("SANDBOX_LAUNCH_TEMPLATE_ID")}
    ids -= ours
    if not ids:
        return []
    return [item(t["LaunchTemplateId"], t.get("Tags")) for t in aws(
        "ec2", "describe-launch-templates", "--launch-template-ids", *sorted(ids))["LaunchTemplates"]]


def node_instance_docs():
    out = []
    for r in aws("ec2", "describe-instances", "--filters", *by_vpc("i"))["Reservations"]:
        out += [i for i in r["Instances"] if i["State"]["Name"] != "terminated"
                and (tag_map(i.get("Tags", [])) or {}).get("eks:nodegroup-name")]
    return out


def d_node_instance_profiles():
    names = {i["IamInstanceProfile"]["Arn"].rsplit("/", 1)[1] for i in node_instance_docs() if i.get("IamInstanceProfile")}
    return [item(n, aws("iam", "list-instance-profile-tags", "--instance-profile-name", n).get("Tags")) for n in sorted(names)]


def d_node_instances():
    return [item(i["InstanceId"], i.get("Tags"), state=i["State"]["Name"]) for i in node_instance_docs()]


def d_node_volumes():
    ids = [i["InstanceId"] for i in node_instance_docs()]
    if not ids:
        return []
    return [item(v["VolumeId"], v.get("Tags")) for v in aws(
        "ec2", "describe-volumes", "--filters", f"Name=attachment.instance-id,Values={','.join(ids)}")["Volumes"]]


def d_node_enis():
    ids = {i["InstanceId"] for i in node_instance_docs()}
    return [item(e["NetworkInterfaceId"], e.get("TagSet")) for e in all_enis()
            if e.get("Attachment", {}).get("InstanceId") in ids and e.get("Attachment", {}).get("DeviceIndex") == 0]


def d_builder_sg():
    return [item(g["GroupId"], g.get("Tags")) for g in aws("ec2", "describe-security-groups", "--filters",
                                                            *tagged(), f"Name=group-name,Values={setting('BUILDER_SG_NAME')}")["SecurityGroups"]]


def d_builder_role():
    doc = aws("iam", "list-role-tags", "--role-name", setting("BUILDER_ROLE_NAME"), allow=("NoSuchEntity",))
    return [] if doc is None else [item(setting("BUILDER_ROLE_NAME"), doc.get("Tags"))]


def d_builder_profile():
    doc = aws("iam", "list-instance-profile-tags", "--instance-profile-name", setting("BUILDER_PROFILE_NAME"), allow=("NoSuchEntity",))
    return [] if doc is None else [item(setting("BUILDER_PROFILE_NAME"), doc.get("Tags"))]


def builder_instance_docs():
    out = []
    for r in aws("ec2", "describe-instances", "--filters", *tagged())["Reservations"]:
        out += [i for i in r["Instances"] if i["State"]["Name"] != "terminated"
                and not (tag_map(i.get("Tags", [])) or {}).get("eks:nodegroup-name")]
    return out


def d_builder_instances():
    return [item(i["InstanceId"], i.get("Tags"), state=i["State"]["Name"]) for i in builder_instance_docs()]


def d_builder_volumes():
    found = {v["VolumeId"]: v for v in aws("ec2", "describe-volumes", "--filters", *tagged())["Volumes"]
             if not any(a.get("InstanceId") in {i["InstanceId"] for i in node_instance_docs()} for a in v.get("Attachments", []))}
    return [item(k, v.get("Tags"), state=v["State"]) for k, v in sorted(found.items())]


def d_builder_enis():
    ids = {i["InstanceId"] for i in builder_instance_docs()}
    return [item(e["NetworkInterfaceId"], e.get("TagSet")) for e in all_enis() if e.get("Attachment", {}).get("InstanceId") in ids]


def d_images():
    return [item(i["ImageId"], i.get("Tags"), name=i.get("Name")) for i in aws(
        "ec2", "describe-images", "--owners", "self", "--filters", *tagged())["Images"]]


def d_snapshots():
    return [item(s["SnapshotId"], s.get("Tags")) for s in aws(
        "ec2", "describe-snapshots", "--owner-ids", "self", "--filters", *tagged())["Snapshots"]]


VPC_SCOPED = {"vpc", "subnets", "route_tables", "main_route_table", "network_acls", "internet_gateways",
              "nat_gateways", "elastic_ips", "stack_security_groups", "default_security_group",
              "cluster_security_group", "control_plane_enis", "nat_enis", "cilium_enis", "node_instances",
              "node_volumes", "node_enis", "node_instance_profiles", "builder_enis", "lt_copies", "asgs"}


def discover(name):
    func = globals().get(f"d_{name}")
    if func is None:
        raise Unknown(f"resource-classes.yaml names discovery {name}, which cb_inventory.py does not have")
    if name in VPC_SCOPED and not state_get("VPC_ID"):
        return []
    return func()


def check_closed(cls):
    have = {c["discover"] for c in cls}
    funcs = {n[2:] for n in globals() if n.startswith("d_")}
    require(have == funcs, f"inventory and discovery differ: {sorted(have ^ funcs)}")


SWEEP = "sweep"


def cmd_audit_tags(args):
    """Every resource of every class carries both tags; every VPC resource belongs to a class."""
    cls, vpc_types = classes()
    check_closed(cls)
    wrong, counts, members = [], {}, {}
    for c in cls:
        found = discover(c["discover"])
        counts[c["class"]] = len(found)
        members[c["class"]] = {f["id"] for f in found}
        if c.get("transient") and found and args.after_build:
            wrong.append(f"{c['class']}: {len(found)} left after the build")
        for f in found:
            if not is_ours(f["tags"]):
                wrong.append(f"{c['class']} {f['id']} lacks ManagedBy or RunId")
    if state_get("VPC_ID"):
        wrong += unmapped(vpc_types, members)
    for c, n in counts.items():
        print(f"{c}: {n}")
    require(not wrong, "; ".join(wrong))
    print(f"tag audit: {sum(counts.values())} resources in {len(counts)} classes, each with both tags")


def unmapped(vpc_types, members):
    reads = {
        "subnet": lambda: [s["SubnetId"] for s in aws("ec2", "describe-subnets", "--filters", *by_vpc("s"))["Subnets"]],
        "route-table": lambda: [r["RouteTableId"] for r in route_tables()],
        "network-acl": lambda: [a["NetworkAclId"] for a in aws("ec2", "describe-network-acls", "--filters", *by_vpc("a"))["NetworkAcls"]],
        "security-group": lambda: [g["GroupId"] for g in security_groups()],
        "network-interface": lambda: [e["NetworkInterfaceId"] for e in all_enis()],
        "nat-gateway": lambda: [n["NatGatewayId"] for n in nats()],
        "internet-gateway": lambda: [g["id"] for g in d_internet_gateways()],
        "instance": lambda: [i["InstanceId"] for r in aws("ec2", "describe-instances", "--filters", *by_vpc("i"))["Reservations"]
                             for i in r["Instances"] if i["State"]["Name"] != "terminated"],
        "vpc-endpoint": lambda: [e["VpcEndpointId"] for e in aws("ec2", "describe-vpc-endpoints", "--filters", *by_vpc("v"))["VpcEndpoints"]],
    }
    require(set(reads) == set(vpc_types), f"vpc_types differ from the audit reads: {sorted(set(reads) ^ set(vpc_types))}")
    wrong = []
    for vtype, names in vpc_types.items():
        known = set().union(*(members.get(n, set()) for n in names)) if names else set()
        for ident in reads[vtype]():
            if ident not in known:
                wrong.append(f"{vtype} {ident} in the VPC belongs to no inventory class")
    return wrong


def cmd_tag_sweep(_):
    """Tag the members of the sweep classes that AWS made with no tag. Before the first write it
    stops when the VPC or the cluster is not this run's."""
    cls, _ = classes()
    check_closed(cls)
    vpcs = d_vpc()
    require(vpcs and is_ours(vpcs[0]["tags"]), "the VPC of the run is not tagged ManagedBy and RunId; nothing tagged")
    require(is_ours((d_cluster() or [{"tags": {}}])[0]["tags"]), "the cluster is not this run's; nothing tagged")
    plan = []
    for c in cls:
        if c["tags"] != SWEEP:
            continue
        for f in discover(c["discover"]):
            other = f["tags"].get(OWNER_TAG[0])
            require(other in (None, OWNER_TAG[1]), f"{c['class']} {f['id']} carries {OWNER_TAG[0]}={other}; nothing tagged")
            if not is_ours(f["tags"]):
                plan.append((c["class"], f["id"]))
    for cls_name, ident in plan:
        if cls_name == "autoscaling-group":
            tags = [f"ResourceId={ident},ResourceType=auto-scaling-group,Key={t['Key']},Value={t['Value']},PropagateAtLaunch=false" for t in tag_list()]
            aws("autoscaling", "create-or-update-tags", "--tags", *tags)
        elif cls_name == "node-instance-profile":
            aws("iam", "tag-instance-profile", "--instance-profile-name", ident, "--tags", json.dumps(tag_list()))
        else:
            aws("ec2", "create-tags", "--resources", ident, "--tags", json.dumps(tag_list()))
        print(f"tagged {cls_name} {ident}")
    print(f"tag sweep: tagged {len(plan)} resources")


def cmd_owned(_):
    """Every resource of the run, by class, as JSON lines (clean.sh --dry-run and its checks)."""
    cls, _ = classes()
    check_closed(cls)
    for c in cls:
        for f in discover(c["discover"]):
            print(json.dumps({"class": c["class"], "id": f["id"], "ours": is_ours(f["tags"]),
                              **{k: v for k, v in f.items() if k not in ("id", "tags")}}, sort_keys=True))
