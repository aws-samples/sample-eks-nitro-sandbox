#!/usr/bin/env python3
"""A small fake of eksctl, for this sample's offline tests only.

It reads the rendered ClusterConfig that the real script passes with -f, records it in the call
log, and changes the world state (fakelib.py) as eksctl would:

  create cluster -f       an ACTIVE cluster with the config's metadata.tags, its cluster stack,
                          a VPC, two private and two public subnets, an internet gateway, one NAT
                          gateway and one Elastic IP address, each marked with the stack name and
                          the config's tags; writes the kubeconfig named by --kubeconfig
  create nodegroup -f     each managedNodeGroups entry: a node group and its stack
  create podidentityassociation -f
                          each iam.podIdentityAssociations entry: an association and its role
  utils write-kubeconfig  writes a placeholder kubeconfig at --kubeconfig
  get cluster             the cluster, as eksctl lists it
  delete nodegroup        the node group and its stack
  delete podidentityassociation
                          the association and the role eksctl made for it
  delete cluster          node groups, associations, then the cluster stack and every resource
                          marked with it. Like CloudFormation, it fails (exit 1, "DELETE_FAILED")
                          when the VPC still holds something the stack did not create: a live
                          instance, an ENI or a non-default security group (#281 M9).
                          It records the stack events (cloudformation.events) as CloudFormation
                          does. A cluster with "DeleteRefusals": N is refused by EKS on the
                          first N deletes with the 409 of an update in progress; a cluster with
                          "DeleteFailReason" fails each delete with that ControlPlane reason.

Set state["eksctl"]["fail"] to {"<verb> <noun>": "message"} to make one verb fail after it logs.
Environment: FAKE_EKSCTL_VERSION (default 0.232.0), plus FAKE_STATE, FAKE_LOG, FAKE_FAIL.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fakelib  # noqa: E402
from fakelib import taglist  # noqa: E402

try:
    import yaml
except ImportError:
    sys.stderr.write("fake_eksctl.py: the offline tests need PyYAML (requirements-test.txt)\n")
    sys.exit(98)


def opts_of(argv):
    pos, opts, i = [], {}, 0
    while i < len(argv):
        t = argv[i]
        if t.startswith("--") and "=" in t:
            k, v = t[2:].split("=", 1)
            opts[k] = v
        elif t.startswith("-") and i + 1 < len(argv) and not argv[i + 1].startswith("-"):
            opts[t.lstrip("-")] = argv[i + 1]
            i += 1
        elif t.startswith("-"):
            opts[t.lstrip("-")] = "true"
        else:
            pos.append(t)
        i += 1
    return pos, opts


def write_kubeconfig(path, name):
    if not path:
        return
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as f:
        f.write(f"apiVersion: v1\nkind: Config\ncurrent-context: fake@{name}\nclusters: []\ncontexts: []\nusers: []\n")
    os.chmod(path, 0o600)


def ec2(state, kind):
    return state.setdefault("ec2", {}).setdefault(kind, [])


def create_cluster(state, cfg, opts):
    meta = cfg["metadata"]
    name, tags = meta["name"], dict(meta.get("tags") or {})
    clusters = state.setdefault("eks", {}).setdefault("clusters", {})
    if name in clusters:
        print(f"Error: creating CloudFormation stack \"eksctl-{name}-cluster\": AlreadyExistsException", file=sys.stderr)
        return 1
    stack = f"eksctl-{name}-cluster"
    n = len(ec2(state, "vpcs")) + 1
    vpc = f"vpc-0fa{n:014d}"
    mark = dict(tags, **{"alpha.eksctl.io/cluster-name": name, "aws:cloudformation:stack-name": stack})
    ec2(state, "vpcs").append({"VpcId": vpc, "Tags": taglist(mark), "Stack": stack})
    subnets = []
    for j, kind in enumerate(("Private", "Private", "Public", "Public"), 1):
        sid = f"subnet-0fa{n:06d}{j:08d}"
        subnets.append(sid)
        ec2(state, "subnets").append({"SubnetId": sid, "VpcId": vpc, "MapPublicIpOnLaunch": kind == "Public",
                                      "Tags": taglist(dict(mark, **{"kubernetes.io/role/internal-elb" if kind == "Private"
                                                                    else "kubernetes.io/role/elb": "1"})),
                                      "AvailabilityZone": f"us-west-2{'bc'[j % 2]}", "Stack": stack})
    ec2(state, "internet_gateways").append({"InternetGatewayId": f"igw-0fa{n:014d}", "Attachments": [{"VpcId": vpc}],
                                            "Tags": taglist(mark), "Stack": stack})
    ec2(state, "addresses").append({"AllocationId": f"eipalloc-0fa{n:014d}", "Domain": "vpc", "Tags": taglist(mark),
                                    "Stack": stack})
    ec2(state, "nat_gateways").append({"NatGatewayId": f"nat-0fa{n:014d}", "VpcId": vpc, "State": "available",
                                       "Tags": taglist(mark), "Stack": stack})
    ec2(state, "security_groups").append({"GroupId": f"sg-0fa{n:014d}", "GroupName": "default", "VpcId": vpc,
                                          "IpPermissions": [], "Tags": [], "Stack": stack})
    # EKS makes the cluster security group itself, with no tag of the sample.
    ec2(state, "security_groups").append({"GroupId": f"sg-0fe{n:014d}", "GroupName": f"eks-cluster-sg-{name}", "VpcId": vpc,
                                          "IpPermissions": [], "Tags": [], "Stack": stack})
    service_role = f"{stack}-ServiceRole"
    state.setdefault("iam", {}).setdefault("roles", {}).setdefault(service_role, {
        "Tags": taglist(mark), "Attached": [], "Inline": {}, "Stack": stack})
    clusters[name] = {"status": "ACTIVE", "version": cfg.get("metadata", {}).get("version"), "tags": mark,
                      "roleArn": f"arn:aws:iam::{state.get('account', '')}:role/{service_role}",
                      "endpoint": f"https://FAKE{n:04d}.gr7.us-west-2.eks.amazonaws.com",
                      "identity": {"oidc": {"issuer": f"https://oidc.eks.us-west-2.amazonaws.com/id/FAKE{n:04d}"}},
                      "certificateAuthority": {"data": "RkFLRS1DQQ=="},
                      "kubernetesNetworkConfig": {"serviceIpv4Cidr": "10.100.0.0/16"},
                      "resourcesVpcConfig": {"vpcId": vpc, "subnetIds": subnets,
                                             "clusterSecurityGroupId": f"sg-0fe{n:014d}"}}
    state.setdefault("cloudformation", {}).setdefault("stacks", {})[stack] = {
        "StackStatus": "CREATE_COMPLETE", "Tags": taglist(mark)}
    write_kubeconfig(opts.get("kubeconfig"), name)
    print(f"EKS cluster \"{name}\" in \"{meta.get('region')}\" region is ready")
    return 0


def create_nodegroups(state, cfg):
    name = cfg["metadata"]["name"]
    ngs = state.setdefault("eks", {}).setdefault("nodegroups", {})
    for ng in cfg.get("managedNodeGroups", []):
        key = f"{name}/{ng['name']}"
        if key in ngs:
            print(f"nodegroup {ng['name']} exists, skipping")
            continue
        tags = dict(cfg["metadata"].get("tags") or {}, **(ng.get("tags") or {}))
        # The node instance role eksctl makes in the node group stack, with the attachPolicyARNs.
        ngstack = f"eksctl-{name}-nodegroup-{ng['name']}"
        role = f"{ngstack}-NodeInstanceRole"
        state.setdefault("iam", {}).setdefault("roles", {}).setdefault(role, {
            "Tags": taglist(tags), "Attached": list((ng.get("iam") or {}).get("attachPolicyARNs") or []),
            "Inline": {}, "Stack": ngstack})
        # The subnets of the node group, as eksctl picks them: in its zones, private with
        # privateNetworking, of the cluster's VPC.
        vpc = ((state["eks"].get("clusters", {}).get(name) or {}).get("resourcesVpcConfig") or {}).get("vpcId")
        subnets = [x["SubnetId"] for x in ec2(state, "subnets") if x.get("VpcId") == vpc
                   and x.get("AvailabilityZone") in (ng.get("availabilityZones") or [])
                   and x.get("MapPublicIpOnLaunch") is not bool(ng.get("privateNetworking"))]
        ngs[key] = {"status": "ACTIVE", "tags": tags, "labels": ng.get("labels") or {},
                    "nodeRole": f"arn:aws:iam::{state.get('account', '')}:role/{role}",
                    # EKS writes the taint effect as NO_SCHEDULE, PREFER_NO_SCHEDULE or NO_EXECUTE.
                    "taints": [dict(t, effect={"NoSchedule": "NO_SCHEDULE", "PreferNoSchedule": "PREFER_NO_SCHEDULE",
                                               "NoExecute": "NO_EXECUTE"}.get(t.get("effect"), t.get("effect")))
                               for t in ng.get("taints") or []],
                    "scalingConfig": {"minSize": ng.get("minSize"), "maxSize": ng.get("maxSize"),
                                      "desiredSize": ng.get("desiredCapacity")},
                    "subnets": subnets,
                    "launchTemplate": ng.get("launchTemplate") or {}, "amiType": ng.get("amiFamily", "CUSTOM")}
        state.setdefault("cloudformation", {}).setdefault("stacks", {})[f"eksctl-{name}-nodegroup-{ng['name']}"] = {
            "StackStatus": "CREATE_COMPLETE", "Tags": taglist(dict(tags, **{"alpha.eksctl.io/cluster-name": name}))}
    return 0


def create_pia(state, cfg, acct):
    name = cfg["metadata"]["name"]
    pia = state.setdefault("eks", {}).setdefault("pod_identity", {})
    roles = state.setdefault("iam", {}).setdefault("roles", {})
    for a in (cfg.get("iam") or {}).get("podIdentityAssociations", []):
        rn = a.get("roleName") or f"eksctl-{name}-podidentityrole-{a['serviceAccountName']}"
        # The trust policy that eksctl gives the role: the EKS Pod Identity service principal.
        trust = {"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Principal": {"Service": "pods.eks.amazonaws.com"},
                                                         "Action": ["sts:AssumeRole", "sts:TagSession"]}]}
        roles.setdefault(rn, {"Trust": trust, "Tags": taglist(dict(cfg["metadata"].get("tags") or {}, **(a.get("tags") or {}))),
                              "Attached": list(a.get("permissionPolicyARNs") or []),
                              "Inline": {"inline": a["permissionPolicy"]} if a.get("permissionPolicy") else {},
                              "MadeByEksctl": True})
        aid = f"a-fake{len(pia) + 1:012d}"
        pia[aid] = {"clusterName": name, "namespace": a["namespace"], "serviceAccount": a["serviceAccountName"],
                    "roleArn": f"arn:aws:iam::{acct}:role/{rn}", "roleName": rn,
                    "tags": dict(cfg["metadata"].get("tags") or {}, **(a.get("tags") or {}))}
    return 0


def stack_event(state, stack, logical, rtype, status, reason=""):
    """Append one CloudFormation stack event (cloudformation.events, oldest first)."""
    cfn = state.setdefault("cloudformation", {})
    n = cfn["event_seq"] = cfn.get("event_seq", 0) + 1
    cfn.setdefault("events", {}).setdefault(stack, []).append({
        "EventId": f"fake-event-{n:06d}", "LogicalResourceId": logical, "ResourceType": rtype,
        "ResourceStatus": status, "ResourceStatusReason": reason,
        "Timestamp": f"2026-01-01T{n // 3600:02d}:{n // 60 % 60:02d}:{n % 60:02d}.000000+00:00"})


def delete_cluster(state, name):
    clusters = state.setdefault("eks", {}).setdefault("clusters", {})
    if name not in clusters:
        print(f"Error: unable to describe cluster control plane: ResourceNotFoundException: No cluster found for name: {name}.", file=sys.stderr)
        return 1
    stack = f"eksctl-{name}-cluster"
    vpc = clusters[name]["resourcesVpcConfig"]["vpcId"]
    for ng in [k.split("/", 1)[1] for k in list(state["eks"].get("nodegroups", {})) if k.startswith(name + "/")]:
        delete_nodegroup(state, name, ng)
    for aid in [a for a, v in state["eks"].get("pod_identity", {}).items() if v.get("clusterName") == name]:
        del state["eks"]["pod_identity"][aid]
    stacks = state.setdefault("cloudformation", {}).setdefault("stacks", {})
    stack_event(state, stack, stack, "AWS::CloudFormation::Stack", "DELETE_IN_PROGRESS", "User Initiated")
    cl = clusters[name]
    refusals = int(cl.get("DeleteRefusals", 0))
    reason = cl.get("DeleteFailReason", "")
    if refusals > 0:
        # As EKS answered in Phase 3b of #281: CloudFormation tries DeleteCluster, EKS refuses it.
        cl["DeleteRefusals"] = refusals - 1
        reason = (f"Cannot delete because cluster {name} currently has an update in progress (Service: Eks, "
                  f"Status Code: 409, Request ID: 00000000-0000-4000-8000-feed{refusals:08x}) (SDK Attempt Count: 1)")
    if reason:
        stack_event(state, stack, "ControlPlane", "AWS::EKS::Cluster", "DELETE_FAILED", reason)
        stack_event(state, stack, stack, "AWS::CloudFormation::Stack", "DELETE_FAILED",
                    "The following resource(s) failed to delete: [ControlPlane]. ")
        stacks[stack]["StackStatus"] = "DELETE_FAILED"
        print("1 error(s) occurred while deleting cluster with nodegroup(s)\nwaiter state transitioned to Failure\n"
              "Error: failed to delete cluster with nodegroup(s)", file=sys.stderr)
        return 1
    prefix = f"eksctl-{name}-"
    mine = lambda x: str(x.get("Stack", "")).startswith(prefix)  # noqa: E731
    blockers = [x["InstanceId"] for x in ec2(state, "instances")
                if x.get("VpcId") == vpc and (x.get("State") or {}).get("Name") != "terminated" and not mine(x)]
    blockers += [x["NetworkInterfaceId"] for x in ec2(state, "network_interfaces") if x.get("VpcId") == vpc and not mine(x)]
    blockers += [x["GroupId"] for x in ec2(state, "security_groups") if x.get("VpcId") == vpc and not mine(x)]
    if blockers:
        stacks[stack]["StackStatus"] = "DELETE_FAILED"
        stack_event(state, stack, "VPC", "AWS::EC2::VPC", "DELETE_FAILED",
                    f"The vpc '{vpc}' has dependencies and cannot be deleted.")
        stack_event(state, stack, stack, "AWS::CloudFormation::Stack", "DELETE_FAILED",
                    "The following resource(s) failed to delete: [VPC]. ")
        print(f"Error: failed to delete cluster stack {stack}: DELETE_FAILED, the VPC {vpc} has dependencies: "
              f"{' '.join(blockers)}", file=sys.stderr)
        return 1
    for kind in list(state.get("ec2", {})):
        if isinstance(state["ec2"][kind], list):
            state["ec2"][kind] = [x for x in state["ec2"][kind] if not mine(x)]
    for coll in ("roles", "profiles"):
        objs = state.setdefault("iam", {}).setdefault(coll, {})
        for n in [n for n, v in objs.items() if mine(v)]:
            del objs[n]
    for k in [k for k in state["eks"].get("addons", {}) if k.startswith(name + "/")]:
        del state["eks"]["addons"][k]
    # eksctl deletes the IAM OIDC provider whose URL is the cluster issuer, when there is one.
    issuer = str(((clusters[name].get("identity") or {}).get("oidc") or {}).get("issuer", ""))
    oidc = state.setdefault("iam", {}).setdefault("oidc_providers", [])
    oidc[:] = [a for a in oidc if not (issuer and a.endswith(":oidc-provider/" + issuer.split("://", 1)[-1]))]
    # EKS deletes the access entries, Fargate profiles and identity provider configs with the cluster.
    for coll, sep in (("access_entries", "|"), ("fargate_profiles", "/"), ("identity_provider_configs", "/")):
        for k in [k for k in state["eks"].get(coll, {}) if k.startswith(name + sep)]:
            del state["eks"][coll][k]
    del clusters[name]
    for s in [s for s in stacks if s.startswith(prefix)]:
        stacks[s]["StackStatus"] = "DELETE_COMPLETE"
    print("all cluster resources were deleted")
    return 0


def delete_nodegroup(state, cluster, ng):
    """A managed node group goes with its instances (and the volumes and primary ENIs they delete on
    termination), its Auto Scaling group, its launch template copy and its node instance profile;
    a secondary ENI that Cilium attached stays, available (as EC2 leaves it)."""
    ngs = state.setdefault("eks", {}).setdefault("nodegroups", {})
    key = f"{cluster}/{ng}"
    if ngs.get(key, {}).get("StaysAfterDelete"):
        return
    ngs.pop(key, None)
    stack = f"eksctl-{cluster}-nodegroup-{ng}"
    for inst in ec2(state, "instances"):
        tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
        if tags.get("eks:nodegroup-name") != ng or (inst.get("State") or {}).get("Name") == "terminated":
            continue
        inst["State"] = {"Name": "terminated"}
        iid = inst["InstanceId"]
        state["ec2"]["volumes"] = [v for v in ec2(state, "volumes")
                                   if not ((v.get("Attachment") or {}).get("InstanceId") == iid and v.get("DeleteOnTermination", True))]
        for e in list(ec2(state, "network_interfaces")):
            att = e.get("Attachment") or {}
            if att.get("InstanceId") != iid:
                continue
            if att.get("DeviceIndex") == 0 or att.get("DeleteOnTermination"):
                state["ec2"]["network_interfaces"].remove(e)
            else:
                e["Status"] = "available"
                e.pop("Attachment", None)
    for kind in ("launch_templates",):
        state["ec2"][kind] = [x for x in ec2(state, kind) if x.get("Stack") != stack]
    groups = state.setdefault("autoscaling", {}).setdefault("groups", {})
    for n in [n for n, g in groups.items() if g.get("Stack") == stack]:
        del groups[n]
    for coll in ("profiles", "roles"):
        objs = state.setdefault("iam", {}).setdefault(coll, {})
        for n in [n for n, p in objs.items() if p.get("Stack") == stack]:
            del objs[n]
    stacks = state.setdefault("cloudformation", {}).setdefault("stacks", {})
    if stack in stacks:
        stacks[stack]["StackStatus"] = "DELETE_COMPLETE"


def main(argv):
    if argv[:1] == ["version"]:
        print(os.environ.get("FAKE_EKSCTL_VERSION", "0.232.0"))
        return 0
    fakelib.require_state("eksctl")
    pos, opts = opts_of(argv)
    call = " ".join(pos[:2])
    cfg_text = None
    if opts.get("f") or opts.get("config-file"):
        path = opts.get("f") or opts.get("config-file")
        cfg_text = sys.stdin.read() if path == "-" else open(path).read()
    fakelib.log_call("eksctl", call, argv, {"config": cfg_text} if cfg_text else None)
    code = fakelib.injected_failure("eksctl", call, argv)
    if code:
        print(f"Error: {code}: injected by the test", file=sys.stderr)
        return 1
    cfg = yaml.safe_load(cfg_text) if cfg_text else None
    with fakelib.world() as (state, _):
        fail = (state.get("eksctl") or {}).get("fail", {}).get(call)
        if fail:
            print(f"Error: {fail}", file=sys.stderr)
            return 1
        acct = state.get("account", "")
        if call == "create cluster":
            return create_cluster(state, cfg, opts)
        if call == "create nodegroup":
            return create_nodegroups(state, cfg)
        if call == "create podidentityassociation":
            return create_pia(state, cfg, acct)
        if call == "utils write-kubeconfig":
            write_kubeconfig(opts.get("kubeconfig"), opts.get("cluster", ""))
            return 0
        if call == "get cluster":
            name = opts.get("name") or opts.get("cluster")
            cl = state.get("eks", {}).get("clusters", {})
            if name and name not in cl:
                print(f"Error: unable to describe cluster control plane: ResourceNotFoundException: No cluster found for name: {name}.", file=sys.stderr)
                return 1
            for n in ([name] if name else sorted(cl)):
                print(f"{n}\t{cl[n].get('status')}")
            return 0
        if call == "delete nodegroup":
            key = f"{opts.get('cluster')}/{opts.get('name')}"
            if key not in state.get("eks", {}).get("nodegroups", {}):
                print(f"Error: nodegroup {opts.get('name')} not found", file=sys.stderr)
                return 1
            delete_nodegroup(state, opts.get("cluster"), opts.get("name"))
            return 0
        if call == "delete podidentityassociation":
            pia = state.get("eks", {}).get("pod_identity", {})
            hit = [a for a, v in pia.items() if v.get("clusterName") == opts.get("cluster")
                   and v.get("namespace") == opts.get("namespace")
                   and v.get("serviceAccount") == opts.get("service-account-name")]
            for a in hit:
                rn = pia[a].get("roleName")
                role = state.get("iam", {}).get("roles", {}).get(rn)
                if role and role.get("MadeByEksctl"):
                    del state["iam"]["roles"][rn]
                del pia[a]
            return 0
        if call == "delete cluster":
            return delete_cluster(state, opts.get("name") or opts.get("cluster"))
    print(f"FAKE eksctl: unexpected call not modelled by the test: {' '.join(argv)}", file=sys.stderr)
    return 97


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
