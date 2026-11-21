#!/usr/bin/env python3
"""The fake world of one finished run of this sample, for the clean.sh and cluster helper tests
(scripts/test-clean.sh, scripts/test-cluster-helper.sh), in the shapes scripts/lib/cb_inventory.py reads.

    world_full.py <world.json> <state.env> [<case> ...]

Run r1 of cluster cb-offline-test: the eksctl stacks with their VPC, subnets, route tables,
network ACL, internet gateway, NAT gateway, Elastic IP address and security groups; the cluster
with two add-ons and the Cilium operator's Pod Identity association and role; the system and
sandbox node groups with their Auto Scaling groups, launch template copies, instance profiles,
instances, volumes and primary ENIs; two Cilium ENIs (one attached, one available); the two
sample launch templates; the AMI and its two snapshots; the namespace and the RuntimeClass.
Everything the run made carries ManagedBy=cilium-bottlerocket-sample and RunId=r1.

The world also holds what clean.sh must leave alone: another run's AMI and launch template
(RunId r2), an untagged volume, and another owner's security group in another VPC.

Cases (any number):
  killed-build   a killed build: a running builder, its four volumes and primary ENI, the builder
                 security group, instance profile and role, as a killed build leaves them
  no-cluster     the run stopped before the cluster was created: only the VPC objects exist,
                 and the state file has no VPC_ID
  short-state    the state file has only the run record (an interrupted setup)
"""
import json
import os
import sys

ACCT = "111122223333"
RUN, CL, MB = "r1", "cb-offline-test", "cilium-bottlerocket-sample"
VPC = "vpc-0fa00000000000001"
OURS = [{"Key": "ManagedBy", "Value": MB}, {"Key": "RunId", "Value": RUN}]
STACK = f"eksctl-{CL}-cluster"


def tags(extra=None, base=OURS):
    t = [dict(x) for x in base]
    for k, v in (extra or {}).items():
        t.append({"Key": k, "Value": v})
    return t


def tmap(extra=None):
    return {**{x["Key"]: x["Value"] for x in OURS}, **(extra or {})}


def build(cases):
    s = {"account": ACCT, "ec2": {k: [] for k in (
        "instances", "volumes", "images", "snapshots", "security_groups", "launch_templates", "network_interfaces",
        "vpcs", "subnets", "nat_gateways", "addresses", "internet_gateways", "key_pairs", "route_tables",
        "network_acls", "vpc_endpoints")},
         "eks": {"clusters": {}, "nodegroups": {}, "addons": {}, "pod_identity": {}},
         "iam": {"roles": {}, "profiles": {}}, "cloudformation": {"stacks": {}}, "autoscaling": {"groups": {}},
         "k8s": {"objects": {}, "answers": [], "exec": []}, "helm": {"releases": {}}, "ssm": {"parameters": {}},
         "packer": {}}
    # The Region's own facts (zones, instance types, quotas, the public SSM parameters) are the
    # same as in the empty world: a finished run does not change them.
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "world-empty.json")) as f:
        empty = json.load(f)
    for k in ("availability_zones", "instance_types", "quotas"):
        s[k] = empty[k]
    s["ssm"]["parameters"] = dict(empty["ssm"]["parameters"])
    e = s["ec2"]
    eks_tag = {"alpha.eksctl.io/cluster-name": CL, "aws:cloudformation:stack-name": STACK}
    # ---- the eksctl cluster stack: VPC objects --------------------------------------------
    e["vpcs"].append({"VpcId": VPC, "Tags": tags(eks_tag), "Stack": STACK})
    for i, kind in enumerate(("private", "private", "public", "public"), 1):
        e["subnets"].append({"SubnetId": f"subnet-0fa0000000000000{i}", "VpcId": VPC, "MapPublicIpOnLaunch": kind == "public",
                             "Tags": tags(eks_tag), "Stack": STACK})
    e["route_tables"] += [
        {"RouteTableId": "rtb-0fa00000000000001", "VpcId": VPC, "Associations": [{"Main": True}], "Tags": tags(), "Stack": STACK},
        {"RouteTableId": "rtb-0fa00000000000002", "VpcId": VPC, "Associations": [{"Main": False}], "Tags": tags(eks_tag), "Stack": STACK},
        {"RouteTableId": "rtb-0fa00000000000003", "VpcId": VPC, "Associations": [{"Main": False}], "Tags": tags(eks_tag), "Stack": STACK}]
    e["network_acls"].append({"NetworkAclId": "acl-0fa00000000000001", "VpcId": VPC, "Tags": tags(), "Stack": STACK})
    e["internet_gateways"].append({"InternetGatewayId": "igw-0fa00000000000001", "Attachments": [{"VpcId": VPC}],
                                   "Tags": tags(eks_tag), "Stack": STACK})
    e["addresses"].append({"AllocationId": "eipalloc-0fa00000000000001", "Domain": "vpc", "PublicIp": "198.51.100.10",
                           "Tags": tags(eks_tag), "Stack": STACK})
    e["nat_gateways"].append({"NatGatewayId": "nat-0fa00000000000001", "VpcId": VPC, "State": "available", "Tags": tags(eks_tag),
                              "NatGatewayAddresses": [{"AllocationId": "eipalloc-0fa00000000000001",
                                                       "NetworkInterfaceId": "eni-0fa00000000000101"}], "Stack": STACK})
    cluster_sg, stack_sg = "sg-0fd00000000000001", "sg-0fd00000000000002"
    e["security_groups"] += [
        {"GroupId": "sg-0fd00000000000000", "GroupName": "default", "VpcId": VPC, "IpPermissions": [], "Tags": tags(), "Stack": STACK},
        {"GroupId": cluster_sg, "GroupName": f"eks-cluster-sg-{CL}", "VpcId": VPC, "IpPermissions": [], "Tags": tags(), "Stack": STACK},
        {"GroupId": stack_sg, "GroupName": f"{STACK}-ControlPlaneSecurityGroup", "VpcId": VPC, "IpPermissions": [],
         "Tags": tags(eks_tag), "Stack": STACK}]
    e["network_interfaces"] += [
        {"NetworkInterfaceId": "eni-0fa00000000000101", "VpcId": VPC, "Status": "in-use", "Description": "Interface for NAT Gateway",
         "TagSet": tags(), "Stack": STACK},
        {"NetworkInterfaceId": "eni-0fa00000000000102", "VpcId": VPC, "Status": "in-use", "Description": f"Amazon EKS {CL}",
         "TagSet": tags(), "Groups": [{"GroupId": cluster_sg}], "Stack": STACK}]
    # ---- cluster, add-ons, roles, Pod Identity ---------------------------------------------
    s["eks"]["clusters"][CL] = {"name": CL, "status": "ACTIVE", "version": "1.36", "tags": tmap(eks_tag),
                                "endpoint": "https://FAKE0001.gr7.us-west-2.eks.amazonaws.com",
                                "certificateAuthority": {"data": "RkFLRS1DQQ=="},
                                "roleArn": f"arn:aws:iam::{ACCT}:role/{STACK}-ServiceRole",
                                "kubernetesNetworkConfig": {"serviceIpv4Cidr": "10.100.0.0/16"},
                                "resourcesVpcConfig": {"vpcId": VPC, "clusterSecurityGroupId": cluster_sg,
                                                       "subnetIds": [x["SubnetId"] for x in e["subnets"]]}}
    for a in ("coredns", "eks-pod-identity-agent"):
        s["eks"]["addons"][f"{CL}/{a}"] = {"addonName": a, "status": "ACTIVE", "tags": tmap()}
    roles = s["iam"]["roles"]
    roles[f"{STACK}-ServiceRole"] = {"Tags": tags(eks_tag), "Attached": [], "Inline": {}, "Stack": STACK}
    roles[f"{CL}-cilium-operator"] = {"Tags": tags(), "Attached": [], "Inline": {"cilium-eni": {"Version": "2012-10-17"}},
                                      "Stack": f"eksctl-{CL}-podidentityrole-kube-system-cilium-operator"}
    s["eks"]["pod_identity"]["a-fake000000000001"] = {"clusterName": CL, "namespace": "kube-system",
                                                      "serviceAccount": "cilium-operator", "tags": tmap(),
                                                      "roleArn": f"arn:aws:iam::{ACCT}:role/{CL}-cilium-operator"}
    s["cloudformation"]["stacks"][STACK] = {"StackStatus": "CREATE_COMPLETE", "Tags": tags(eks_tag)}
    s["cloudformation"]["stacks"][f"eksctl-{CL}-podidentityrole-kube-system-cilium-operator"] = {
        "StackStatus": "CREATE_COMPLETE", "Tags": tags(eks_tag)}
    # ---- launch templates of the sample, and the node groups ------------------------------
    lt_ids = {"system": "lt-0fa00000000000001", "sandbox": "lt-0fa00000000000002"}
    for g, lid in lt_ids.items():
        e["launch_templates"].append({"LaunchTemplateId": lid, "LaunchTemplateName": f"{CL}-{RUN}-{g}", "Tags": tags()})
    for n, g in enumerate(("system", "sandbox"), 1):
        ngstack = f"eksctl-{CL}-nodegroup-{g}"
        role = f"{ngstack}-NodeInstanceRole"
        roles[role] = {"Tags": tags(eks_tag), "Attached": [], "Inline": {}, "Stack": ngstack}
        asg = f"eks-{g}-fake{n}"
        copy = f"lt-0fb0000000000000{n}"
        e["launch_templates"].append({"LaunchTemplateId": copy, "LaunchTemplateName": f"eks-{g}-copy", "Tags": tags(), "Stack": ngstack})
        s["autoscaling"]["groups"][asg] = {"Tags": [dict(t, ResourceId=asg) for t in tags()],
                                           "LaunchTemplate": {"LaunchTemplateId": copy}, "Stack": ngstack}
        s["eks"]["nodegroups"][f"{CL}/{g}"] = {"status": "ACTIVE", "tags": tmap(eks_tag), "nodeRole": f"arn:aws:iam::{ACCT}:role/{role}",
                                               "resources": {"autoScalingGroups": [{"name": asg}]},
                                               "launchTemplate": {"id": lt_ids[g], "version": "1"}}
        prof = f"eks-{g}-profile"
        s["iam"]["profiles"][prof] = {"Roles": [role], "Tags": tags(), "Stack": ngstack}
        iid = f"i-0fa0000000000000{n}"
        e["instances"].append({"InstanceId": iid, "State": {"Name": "running"}, "VpcId": VPC, "SubnetId": "subnet-0fa00000000000001",
                               "IamInstanceProfile": {"Arn": f"arn:aws:iam::{ACCT}:instance-profile/{prof}"},
                               "Tags": tags({"eks:nodegroup-name": g, "eks:cluster-name": CL}),
                               "SecurityGroups": [{"GroupId": cluster_sg}]})
        for j, dev in enumerate(("/dev/xvda", "/dev/xvdb"), 1):
            e["volumes"].append({"VolumeId": f"vol-0fa000000000000{n}{j}", "State": "in-use", "VolumeType": "gp3",
                                 "Attachment": {"InstanceId": iid, "Device": dev}, "Attachments": [{"InstanceId": iid, "Device": dev}],
                                 "DeleteOnTermination": True, "Tags": tags()})
        e["network_interfaces"].append({"NetworkInterfaceId": f"eni-0fa0000000000020{n}", "VpcId": VPC, "Status": "in-use",
                                        "Attachment": {"InstanceId": iid, "DeviceIndex": 0}, "TagSet": tags(),
                                        "Groups": [{"GroupId": cluster_sg}]})
    # Cilium ENIs: one on the sandbox node, one already detached.
    cil = tags({"io.cilium/cilium-managed": "true", "io.cilium/cluster-name": CL})
    e["network_interfaces"] += [
        {"NetworkInterfaceId": "eni-0fa00000000000301", "VpcId": VPC, "Status": "in-use", "TagSet": cil,
         "Attachment": {"InstanceId": "i-0fa00000000000002", "DeviceIndex": 1, "DeleteOnTermination": False},
         "Groups": [{"GroupId": cluster_sg}]},
        {"NetworkInterfaceId": "eni-0fa00000000000302", "VpcId": VPC, "Status": "available", "TagSet": cil,
         "Groups": [{"GroupId": cluster_sg}]}]
    # ---- the AMI and its snapshots ---------------------------------------------------------
    img_tags = tags({"SandboxSlots": "58", "Name": f"{CL}-{RUN}-aws-k8s-1.36-nitro-sandbox"})
    e["snapshots"] += [{"SnapshotId": "snap-0fa00000000000001", "State": "completed", "Tags": img_tags},
                       {"SnapshotId": "snap-0fa00000000000002", "State": "completed", "Tags": img_tags}]
    e["images"].append({"ImageId": "ami-0fa00000000000101", "Name": f"{CL}-{RUN}-aws-k8s-1.36-nitro-sandbox", "State": "available",
                        "Tags": img_tags, "BlockDeviceMappings": [
                            {"DeviceName": "/dev/xvda", "Ebs": {"SnapshotId": "snap-0fa00000000000001"}},
                            {"DeviceName": "/dev/xvdb", "Ebs": {"SnapshotId": "snap-0fa00000000000002"}}]})
    # ---- what is not this run's -----------------------------------------------------------
    other = [{"Key": "ManagedBy", "Value": MB}, {"Key": "RunId", "Value": "r2"}]
    e["images"].append({"ImageId": "ami-0fa00000000000202", "Name": f"{CL}-r2-aws-k8s-1.36-nitro-sandbox", "State": "available",
                        "Tags": other, "BlockDeviceMappings": [{"DeviceName": "/dev/xvda", "Ebs": {"SnapshotId": "snap-0fa00000000000202"}}]})
    e["snapshots"].append({"SnapshotId": "snap-0fa00000000000202", "State": "completed", "Tags": other})
    e["launch_templates"].append({"LaunchTemplateId": "lt-0fa00000000000202", "LaunchTemplateName": f"{CL}-r2-system", "Tags": other})
    e["volumes"].append({"VolumeId": "vol-0fa00000000000999", "State": "available", "VolumeType": "gp3", "Tags": []})
    e["vpcs"].append({"VpcId": "vpc-0fa00000000000999", "Tags": [{"Key": "team", "Value": "someone-else"}]})
    e["security_groups"].append({"GroupId": "sg-0fd00000000000999", "GroupName": "someone-elses", "VpcId": "vpc-0fa00000000000999",
                                 "IpPermissions": [], "Tags": [{"Key": "team", "Value": "someone-else"}]})
    # ---- Kubernetes objects of the sample -------------------------------------------------
    lab = {"app.kubernetes.io/part-of": MB}
    s["k8s"]["objects"]["namespaces/-/cilium-bottlerocket-demo"] = {"kind": "Namespace", "metadata": {"name": "cilium-bottlerocket-demo", "labels": lab}}
    s["k8s"]["objects"]["runtimeclasses/-/isolated-sandbox"] = {"kind": "RuntimeClass", "metadata": {"name": "isolated-sandbox", "labels": lab},
                                                                "handler": "isolated-sandbox"}
    state = {"RUN_ID": RUN, "CLUSTER_NAME": CL, "AWS_REGION": "us-west-2", "INTERFACE_VERSION": "cluster-v3",
             "VPC_ID": VPC, "CLUSTER_ENDPOINT": s["eks"]["clusters"][CL]["endpoint"], "KUBE_CONTEXT": f"cb-{RUN}",
             "OPERATOR_ROLE_NAME": f"{CL}-cilium-operator", "POD_IDENTITY_ASSOCIATION_ID": "a-fake000000000001",
             "SYSTEM_LAUNCH_TEMPLATE_ID": lt_ids["system"], "SANDBOX_LAUNCH_TEMPLATE_ID": lt_ids["sandbox"],
             "SANDBOX_AMI_ID": "ami-0fa00000000000101", "SANDBOX_AMI_SNAPSHOT_IDS": "snap-0fa00000000000001,snap-0fa00000000000002",
             "AMI_BUILD_RESULT": "ok", "MAX_PODS_SYSTEM": "110", "MAX_PODS_SANDBOX": "110",
             "MAX_PODS_FORMULA_SYSTEM": "118", "MAX_PODS_FORMULA_SANDBOX": "118",
             "MAX_PODS_CEILING_SYSTEM": "110", "MAX_PODS_CEILING_SANDBOX": "110"}
    if "killed-build" in cases:
        b = f"{CL}-{RUN}-builder"
        bid, sg = "i-0fb00000000000001", "sg-0fc00000000000001"
        btags = tags({"Name": b})
        e["security_groups"].append({"GroupId": sg, "GroupName": b, "VpcId": VPC, "IpPermissions": [], "Tags": btags})
        e["instances"].append({"InstanceId": bid, "State": {"Name": "running"}, "VpcId": VPC, "SubnetId": "subnet-0fa00000000000001",
                               "SecurityGroups": [{"GroupId": sg}], "Tags": btags,
                               "IamInstanceProfile": {"Arn": f"arn:aws:iam::{ACCT}:instance-profile/{b}"}})
        vols = []
        for j, dev in enumerate(("/dev/xvda", "/dev/xvdc", "/dev/xvdf", "/dev/xvdb"), 1):
            vid = f"vol-0fb0000000000000{j}"
            vols.append(vid)
            e["volumes"].append({"VolumeId": vid, "State": "in-use", "VolumeType": "gp3", "DeleteOnTermination": True,
                                 "Attachment": {"InstanceId": bid, "Device": dev}, "Attachments": [{"InstanceId": bid, "Device": dev}],
                                 "Tags": btags})
        e["network_interfaces"].append({"NetworkInterfaceId": "eni-0fb00000000000001", "VpcId": VPC, "Status": "in-use",
                                        "Attachment": {"InstanceId": bid, "DeviceIndex": 0, "DeleteOnTermination": True},
                                        "TagSet": [], "Groups": [{"GroupId": sg}]})
        roles[b] = {"Tags": tags(), "Attached": ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"], "Inline": {}}
        s["iam"]["profiles"][b] = {"Roles": [b], "Tags": tags()}
        state.update(BUILDER_SG_ID=sg, BUILDER_ROLE_NAME=b, BUILDER_PROFILE_NAME=b, BUILDER_INSTANCE_ID=bid,
                     BUILDER_VOLUME_IDS=",".join(vols))
        for k in ("SANDBOX_AMI_ID", "SANDBOX_AMI_SNAPSHOT_IDS", "AMI_BUILD_RESULT"):
            state.pop(k)
    if "no-cluster" in cases:
        # eksctl made the cluster stack and its VPC objects, then the run stopped: no control plane,
        # no node, no Cilium ENI, no launch template, no AMI.
        del s["eks"]["clusters"][CL]
        for k in ("nodegroups", "addons", "pod_identity"):
            s["eks"][k].clear()
        s["autoscaling"]["groups"].clear()
        s["k8s"]["objects"].clear()
        e["instances"] = []
        e["volumes"] = [v for v in e["volumes"] if v["VolumeId"] == "vol-0fa00000000000999"]
        e["network_interfaces"] = [x for x in e["network_interfaces"] if x["NetworkInterfaceId"] == "eni-0fa00000000000101"]
        e["security_groups"] = [g for g in e["security_groups"] if g["GroupId"] != cluster_sg]
        e["launch_templates"] = [t for t in e["launch_templates"] if t["LaunchTemplateId"] == "lt-0fa00000000000202"]
        e["images"] = [i for i in e["images"] if i["ImageId"] == "ami-0fa00000000000202"]
        e["snapshots"] = [x for x in e["snapshots"] if x["SnapshotId"] == "snap-0fa00000000000202"]
        s["iam"]["roles"] = {}
        s["iam"]["profiles"] = {}
        s["cloudformation"]["stacks"] = {STACK: s["cloudformation"]["stacks"][STACK]}
        s["cloudformation"]["stacks"][STACK]["StackStatus"] = "CREATE_IN_PROGRESS"
        for k in ("VPC_ID", "CLUSTER_ENDPOINT", "KUBE_CONTEXT", "POD_IDENTITY_ASSOCIATION_ID", "SYSTEM_LAUNCH_TEMPLATE_ID",
                  "SANDBOX_LAUNCH_TEMPLATE_ID", "SANDBOX_AMI_ID", "SANDBOX_AMI_SNAPSHOT_IDS", "AMI_BUILD_RESULT"):
            state.pop(k, None)
    if "short-state" in cases:
        state = {k: state[k] for k in ("RUN_ID", "CLUSTER_NAME", "AWS_REGION", "INTERFACE_VERSION")}
    return s, state


def main(world, state_file, *cases):
    s, state = build(set(cases))
    with open(world, "w") as f:
        json.dump(s, f, indent=1, sort_keys=True)
    with open(state_file, "w") as f:
        f.write("".join(f"{k}={v}\n" for k, v in state.items()))


if __name__ == "__main__":
    main(*sys.argv[1:])
