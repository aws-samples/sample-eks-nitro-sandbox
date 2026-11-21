"""Config, rendering and launch-template checks of scripts/cilium_bottlerocket.py."""

import base64
import ipaddress
import json
import re
import urllib.parse
from pathlib import Path

import yaml

from cb_base import (CRI_PROXY_ENDPOINT, LT_ID, NODEGROUP_LABEL, NS_LABEL, OWNER_TAG, SAMPLE,
                     SANDBOX_NODE_LABEL, SANDBOX_TAINT_KEY, Unknown, aws, int_setting, is_ours,
                     read_input, read_json, require, run_id, setting, state_get, tag_list)

AMI = re.compile(r"^ami-[0-9a-f]{8}(?:[0-9a-f]{9})?$")
INSTANCE_TYPE = re.compile(r"^[a-z][a-z0-9-]*\.[0-9a-z]+$")
# The EC2 actions of the Cilium AWS ENI page for this configuration (eksctl/pod-identity.yaml).
OPERATOR_ACTIONS = {
    "ec2:DescribeInstanceTypes", "ec2:DescribeNetworkInterfaces", "ec2:DescribeSubnets",
    "ec2:DescribeVpcs", "ec2:DescribeRouteTables", "ec2:DescribeSecurityGroups", "ec2:DescribeTags",
    "ec2:CreateNetworkInterface", "ec2:AttachNetworkInterface", "ec2:ModifyNetworkInterfaceAttribute",
    "ec2:AssignPrivateIpAddresses", "ec2:DeleteNetworkInterface", "ec2:CreateTags",
}
# The managed policies of each node role (eksctl/nodegroups.yaml), by ARN: a policy of the account
# can carry the same name with other permissions.
NODE_POLICY_ARNS = {"arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
                    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"}
# The trust of the operator role: the EKS Pod Identity principal and the two STS actions it needs
# (Amazon EKS User Guide, "Create IAM role with trust policy required by EKS Pod Identity").
POD_IDENTITY_PRINCIPAL = "pods.eks.amazonaws.com"
POD_IDENTITY_ACTIONS = {"sts:AssumeRole", "sts:TagSession"}
# EKS writes a taint effect as NO_SCHEDULE; eksctl/nodegroups.yaml as NoSchedule.
TAINT_EFFECTS = {"NoSchedule": "NO_SCHEDULE", "PreferNoSchedule": "PREFER_NO_SCHEDULE", "NoExecute": "NO_EXECUTE"}
CILIUM_EXPECTED = {
    ("eni", "enabled"): True, ("ipam", "mode"): "eni", ("routingMode",): "native",
    ("kubeProxyReplacement",): True, ("k8sServicePort",): 443,
    ("socketLB", "hostNamespaceOnly"): True, ("operator", "replicas"): 1,
    ("operator", "nodeSelector"): {NODEGROUP_LABEL: "system"},
    ("eni", "eniTags"): {OWNER_TAG[0]: OWNER_TAG[1]},
    # Bottlerocket SELinux denies the sysctlfix write to /etc/sysctl.d (cilium-values.yaml).
    ("sysctlfix", "enabled"): False,
}
RUNTIMECLASS = {
    "apiVersion": "node.k8s.io/v1", "kind": "RuntimeClass",
    "metadata": {"name": "isolated-sandbox", "labels": {NS_LABEL[0]: NS_LABEL[1]}},
    "handler": "isolated-sandbox",
    "overhead": {"podFixed": {"eks.amazonaws.com/nitro-sandbox": "1", "memory": "256Mi"}},
    "scheduling": {"nodeSelector": {SANDBOX_NODE_LABEL[0]: SANDBOX_NODE_LABEL[1]}},
}


def run_dir():
    return Path(setting("RUN_STATE_DIR"))


def zones():
    names = setting("AVAILABILITY_ZONES").split()
    region = setting("AWS_REGION")
    require(len(names) == 2 and len(set(names)) == 2, f"AVAILABILITY_ZONES needs two distinct zones, got {names}")
    for zone in names:
        require(re.fullmatch(re.escape(region) + r"[a-z]", zone) is not None, f"zone {zone} is not in {region}")
    return names


def cmd_check_config(_):
    zones()  # derive_names (common.sh) checks CLUSTER_NAME, E_NAME, before setup.sh reserves the run
    for name in ("SYSTEM_INSTANCE_TYPE", "SANDBOX_INSTANCE_TYPE", "BUILD_INSTANCE_TYPE"):
        require(INSTANCE_TYPE.fullmatch(setting(name)) is not None, f"{name}={setting(name)} is not an instance type")
    int_setting("SANDBOX_SLOTS", 1, 250)
    int_setting("SYSTEM_DATA_VOLUME_GIB", 20, 200)
    int_setting("SANDBOX_DATA_VOLUME_GIB", 20, 500)
    int_setting("BUILD_WORK_VOLUME_GIB", 100, 400)
    int_setting("AMI_WAIT_SECONDS", 600, 7200)
    for name in ("SYSTEM_AMI_ID", "REUSE_SANDBOX_AMI_ID"):
        value = setting(name, required=False)
        require(not value or AMI.fullmatch(value) is not None, f"{name}={value} is not an AMI ID")
    print("config: zones, instance types, AMI IDs, slot count and volume sizes are valid")


def dig(values, path):
    for key in path:
        if not isinstance(values, dict) or key not in values:
            return None
        values = values[key]
    return values


def cmd_check_cilium_values(args):
    path = Path(args.file) if args.file else SAMPLE / "cilium-values.yaml"
    text = read_input(path)
    try:
        values = yaml.safe_load(text)
    except yaml.YAMLError as err:
        raise Unknown(f"{path} is not YAML") from err
    wrong = [f"{'.'.join(p)}={dig(values, p)!r} (want {v!r})" for p, v in CILIUM_EXPECTED.items()
             if dig(values, p) != v]
    require(not wrong, f"{path}: " + "; ".join(wrong))
    body = "\n".join(line.split("#", 1)[0] for line in text.splitlines())
    require(re.search(r"\b1\.[0-9]+\.[0-9]+\b", body) is None and "image" not in values,
            f"{path} states a version or an image; cilium.lock is the one version source")
    print("cilium values: ENI IPAM, native routing, kube-proxy replacement, socketLB.hostNamespaceOnly=true")


def fill(obj, values):
    """Fill ${NAME} in every string. A string that is only ${NAME} takes the value's type. A name
    with no value is a KeyError, which main_wrapper reports as could not check (exit 2)."""
    if isinstance(obj, dict):
        return {k: fill(v, values) for k, v in obj.items()}
    if isinstance(obj, list):
        return [fill(v, values) for v in obj]
    if isinstance(obj, str):
        whole = re.fullmatch(r"\$\{([A-Z_]+)\}", obj)
        return values[whole.group(1)] if whole else re.sub(r"\$\{([A-Z_]+)\}", lambda m: str(values[m.group(1)]), obj)
    return obj


def load_template(rel):
    try:
        return yaml.safe_load((SAMPLE / rel).read_text())
    except (OSError, yaml.YAMLError) as err:
        raise Unknown(f"could not read {rel}") from err


def base_values():
    return {"CLUSTER_NAME": setting("CLUSTER_NAME"), "AWS_REGION": setting("AWS_REGION"), "RUN_ID": run_id()}


def write_rendered(name, doc):
    out = run_dir() / name
    out.write_text(yaml.safe_dump(doc, sort_keys=False))
    print(out)


def cmd_render_cluster(_):
    # The rendered values are pinned by test-cluster-helper.sh; setup.sh checks the live cluster
    # for vpc-cni, kube-proxy and aws-node (E_CNI_PRESENT), and audit-tags checks its tags.
    write_rendered("cluster.yaml", fill(load_template("eksctl/cluster.yaml"),
                                        {**base_values(), "AVAILABILITY_ZONES": zones()}))


def policy_actions(document):
    actions = set()
    for statement in document.get("Statement", []):
        require(statement.get("Effect") == "Allow" and "NotAction" not in statement, "unexpected policy statement")
        action = statement.get("Action", [])
        actions |= {action} if isinstance(action, str) else set(action)
    return actions


def cmd_render_pod_identity(_):
    # check-operator-role checks the live association and the actions of its role, before Cilium.
    write_rendered("pod-identity.yaml", fill(load_template("eksctl/pod-identity.yaml"),
                                             {**base_values(), "OPERATOR_ROLE_NAME": setting("OPERATOR_ROLE_NAME")}))


def cmd_render_nodegroup(args):
    group = args.group
    lt = state_get(f"{group.upper()}_LAUNCH_TEMPLATE_ID")
    require(LT_ID.fullmatch(lt) is not None, f"the state file has no {group} launch template ID")
    doc = load_template("eksctl/nodegroups.yaml")
    doc["managedNodeGroups"] = [g for g in doc["managedNodeGroups"] if g["name"] == group]
    doc = fill(doc, {**base_values(), "NODE_ZONE": zones()[0], f"{group.upper()}_LAUNCH_TEMPLATE_ID": lt})
    ng = doc["managedNodeGroups"][0]
    # A node group of that name that EKS already has is used only when it is this run's and as
    # rendered; setup.sh renders before ensure_nodegroup, so a mismatch stops before any change.
    found = aws("eks", "describe-nodegroup", "--cluster-name", setting("CLUSTER_NAME"), "--nodegroup-name", group,
                allow=("ResourceNotFoundException",))
    if found is not None:
        wrong = nodegroup_problems(ng, found.get("nodegroup") or {})
        require(not wrong, f"node group {group} exists and is not the one this run renders: " + "; ".join(wrong)
                + "; run ./clean.sh --dry-run")
        print(f"node group {group}: exists, this run's and as rendered")
    write_rendered(f"nodegroups-{group}.yaml", doc)


def nodegroup_problems(ng, found):
    """What differs between a node group that EKS has (describe-nodegroup) and the rendered one, including
    the two tags and a node role of this run with exactly the two AWS managed policies."""
    lt, sizes = found.get("launchTemplate") or {}, found.get("scalingConfig") or {}

    def taints(items):
        return sorted((t.get("key"), t.get("value"), TAINT_EFFECTS.get(t.get("effect"), t.get("effect"))) for t in items or [])
    compare = {  # the field: (what EKS has, what the rendered node group fixes)
        "launch template and version": ((lt.get("id"), str(lt.get("version"))),
                                        (ng["launchTemplate"]["id"], str(ng["launchTemplate"]["version"]))),
        "min, max and desired size": ((sizes.get("minSize"), sizes.get("maxSize"), sizes.get("desiredSize")),
                                      (ng["minSize"], ng["maxSize"], ng["desiredCapacity"])),
        # eksctl adds labels to a managed node group whose Kubernetes label key has the prefix it owns, alpha.eksctl.io.
        "labels": ({k: v for k, v in (found.get("labels") or {}).items() if k.partition("/")[:2] != ("alpha.eksctl.io", "/")},
                   ng.get("labels") or {}),
        "taints": (taints(found.get("taints")), taints(ng.get("taints"))),
        "remote access": (found.get("remoteAccess") or None, None),
        # The cluster stage recorded the private subnet of the run VPC in the node zone as BUILD_SUBNET_ID.
        "subnets": (sorted(found.get("subnets") or []), [state_get("BUILD_SUBNET_ID")]),
    }
    wrong = [f"{name} {got}, want {want}" for name, (got, want) in compare.items() if got != want]
    if not is_ours(found.get("tags")):
        wrong.insert(0, f"tags {found.get('tags')} are not {OWNER_TAG[0]}={OWNER_TAG[1]} RunId={run_id()}")
    role = (found.get("nodeRole") or "").rsplit("/", 1)[-1]
    if not role:
        return wrong + ["no node role"]
    if not is_ours(role_tags(role)):
        wrong.append(f"node role {role} is not tagged {OWNER_TAG[0]}={OWNER_TAG[1]} RunId={run_id()}")
    return wrong + [f"node role {role}: {w}" for w in node_role_problems(role)]


def role_tags(role):
    """The tags of an IAM role (list-role-tags)."""
    return aws("iam", "list-role-tags", "--role-name", role).get("Tags", [])


def node_role_problems(role):
    """A node role must have exactly the two AWS managed policy ARNs of eksctl/nodegroups.yaml and no inline policy."""
    arns = {p.get("PolicyArn") for p in aws("iam", "list-attached-role-policies", "--role-name", role).get("AttachedPolicies", [])}
    inline = aws("iam", "list-role-policies", "--role-name", role).get("PolicyNames", [])
    return ([f"managed policies {sorted(arns)}, want exactly {sorted(NODE_POLICY_ARNS)}"] if arns != NODE_POLICY_ARNS else []) \
        + ([f"inline policies {inline}, want none"] if inline else [])


def cmd_render_probe(args):
    require(re.fullmatch(r"cb-probe-(system|sandbox)-[a-z0-9]{1,20}", args.name) is not None,
            f"probe name {args.name} is not cb-probe-<system|sandbox>-<run ID>")
    require(re.fullmatch(r"[a-z0-9][a-z0-9.-]{0,252}", args.node) is not None, f"node name {args.node} is not valid")
    print(yaml.safe_dump(fill(load_template("deploy/probe/node-probe.yaml"),
                              {"PROBE_NAME": args.name, "NODE_NAME": args.node,
                               "BUSYBOX_IMAGE": setting("BUSYBOX_IMAGE")}), sort_keys=False))


def cmd_render_filler(args):
    """A filler pod for the networkd check of test.sh: cb-filler-<n>-<run ID>, pinned to one node."""
    require(re.fullmatch(r"cb-filler-([1-9]|[1-3][0-9]|40)-[a-z0-9]{1,20}", args.name) is not None,
            f"filler name {args.name} is not cb-filler-<1 to 40>-<run ID>")
    require(re.fullmatch(r"[a-z0-9][a-z0-9.-]{0,252}", args.node) is not None, f"node name {args.node} is not valid")
    print(yaml.safe_dump(fill(load_template("deploy/probe/filler-pod.yaml"),
                              {"FILLER_NAME": args.name, "NODE_NAME": args.node,
                               "BUSYBOX_IMAGE": setting("BUSYBOX_IMAGE")}), sort_keys=False))


FORBIDDEN_KINDS = {"Ingress", "NetworkPolicy", "CiliumNetworkPolicy", "CiliumClusterwideNetworkPolicy"}


def walk(obj, path=()):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield path + (k,), v
            yield from walk(v, path + (k,))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from walk(v, path + (i,))


def cmd_check_manifests(args):
    """Every tracked manifest in deploy/: no Ingress, no network policy, Services ClusterIP
    only, no hostPort, no CPU or memory requests or limits, and each image the pinned busybox."""
    root = Path(args.dir) if args.dir else SAMPLE / "deploy"
    files = sorted(p for p in root.rglob("*.yaml"))
    if not files:
        raise Unknown(f"no manifest under {root}")
    image = setting("BUSYBOX_IMAGE")
    wrong = []
    for path in files:
        try:
            docs = [d for d in yaml.safe_load_all(path.read_text()) if d is not None]
        except (OSError, yaml.YAMLError) as err:
            raise Unknown(f"{path} is not readable YAML") from err
        for doc in docs:
            kind = doc.get("kind")
            if kind in FORBIDDEN_KINDS:
                wrong.append(f"{path.name}: kind {kind}")
            if kind == "Service" and doc.get("spec", {}).get("type", "ClusterIP") != "ClusterIP":
                wrong.append(f"{path.name}: Service type {doc['spec']['type']}")
            for keys, value in walk(doc):
                if keys[-1] == "resources":
                    wrong.append(f"{path.name}: sets resources at {'.'.join(map(str, keys))}")
                if keys[-1] == "hostPort":
                    wrong.append(f"{path.name}: hostPort")
                if keys[-1] == "image" and value not in (image, "${BUSYBOX_IMAGE}"):
                    wrong.append(f"{path.name}: image {value} is not {image}")
    require(not wrong, "; ".join(wrong))
    print(f"deploy/: {len(files)} manifests, ClusterIP only, no Ingress or network policy, no resources, pinned image")


# ---- Launch templates and Bottlerocket TOML user data ----
def toml_str(value):
    return json.dumps(str(value))


def node_labels(group):
    labels = {NODEGROUP_LABEL: group}
    if group == "sandbox":
        labels[SANDBOX_NODE_LABEL[0]] = SANDBOX_NODE_LABEL[1]
        labels[SANDBOX_TAINT_KEY] = "true"
    return labels


def positive(section, name, key):
    """A field of describe-instance-types that must be a number above 0."""
    value = section.get(key) if isinstance(section, dict) else None
    if not isinstance(value, int) or isinstance(value, bool):
        raise Unknown(f"{name}.{key} is {value!r}, not a number")
    require(value > 0, f"{name}.{key} is {value}, want more than 0")
    return value


def derived_max_pods(info):
    """(max-pods, ENI formula, ceiling, vCPUs) of one describe-instance-types entry. The ENI formula of the Amazon
    EKS AMIs is ENIs x (IPv4 per ENI - 1) + 2. The ceiling of the EKS max-pods calculator is 110 below 30 vCPUs and
    250 above; the sample gives exactly 30 vCPUs 250. m8i.xlarge (4 vCPUs, 4 ENIs, 30 IPv4 each): 118, ceiling 110.
    https://docs.aws.amazon.com/eks/latest/userguide/choosing-instance-type.html#max-pods-precedence"""
    net = info.get("NetworkInfo")
    if not isinstance(net, dict):
        raise Unknown("the instance type has no NetworkInfo")
    formula = (positive(net, "NetworkInfo", "MaximumNetworkInterfaces")
               * (positive(net, "NetworkInfo", "Ipv4AddressesPerInterface") - 1) + 2)
    vcpus = positive(info.get("VCpuInfo"), "VCpuInfo", "DefaultVCpus")
    ceiling = 110 if vcpus < 30 else 250
    return min(formula, ceiling), formula, ceiling, vcpus


def cmd_derive_max_pods(args):
    """Print '<max-pods> <ENI formula> <ceiling> <vCPUs>' of an instance type from one describe-instance-types read."""
    require(INSTANCE_TYPE.fullmatch(args.instance_type) is not None, f"{args.instance_type!r} is not an instance type")
    types = aws("ec2", "describe-instance-types", "--instance-types", args.instance_type).get("InstanceTypes") or []
    if len(types) != 1:
        raise Unknown(f"describe-instance-types gave {len(types)} entries for {args.instance_type}")
    print(*derived_max_pods(types[0]))


def max_pods(group):
    """The max-pods of a node group as setup.sh derived it (MAX_PODS_SYSTEM or MAX_PODS_SANDBOX in the run state)."""
    value = state_get(f"MAX_PODS_{group.upper()}")
    if not re.fullmatch(r"[1-9][0-9]{0,3}", value):
        raise Unknown(f"the run state has no derived MAX_PODS_{group.upper()} (got {value!r}); run setup.sh")
    return int(value)


def user_data(group, info):
    max_pods_value = max_pods(group)
    lines = ["[settings.kubernetes]",
             f"cluster-name = {toml_str(info['name'])}",
             f"api-server = {toml_str(info['endpoint'])}",
             f"cluster-certificate = {toml_str(info['ca'])}",
             f"cluster-dns-ip = {toml_str(info['dns'])}",
             f"max-pods = {max_pods_value}"]
    if group == "sandbox":
        lines.append(f"container-runtime-endpoint = {toml_str(CRI_PROXY_ENDPOINT)}")
    lines += ["", "[settings.kubernetes.node-labels]"]
    lines += [f"{toml_str(k)} = {toml_str(v)}" for k, v in node_labels(group).items()]
    if group == "sandbox":
        lines += ["", "[settings.kubernetes.node-taints]", f"{toml_str(SANDBOX_TAINT_KEY)} = [\"true:NoSchedule\"]"]
    return "\n".join(lines) + "\n"


def cluster_info():
    cluster = aws("eks", "describe-cluster", "--name", setting("CLUSTER_NAME"))["cluster"]
    require(is_ours(cluster.get("tags", {})), f"cluster {cluster['name']} is not this run's")
    cidr = cluster["kubernetesNetworkConfig"]["serviceIpv4Cidr"]
    dns = str(ipaddress.ip_network(cidr).network_address + 10)
    return {"name": cluster["name"], "endpoint": cluster["endpoint"],
            "ca": cluster["certificateAuthority"]["data"], "dns": dns}


def launch_template_data(group, info):
    data = {  # setup.sh checked the AMI before it recorded it (check-system-ami; describe-images, check-density)
        "ImageId": state_get("SYSTEM_AMI_ID" if group == "system" else "SANDBOX_AMI_ID"),
        "InstanceType": setting("SANDBOX_INSTANCE_TYPE" if group == "sandbox" else "SYSTEM_INSTANCE_TYPE"),
        "UserData": base64.b64encode(user_data(group, info).encode()).decode(),
        "MetadataOptions": {"HttpEndpoint": "enabled", "HttpTokens": "required", "HttpPutResponseHopLimit": 1},
        "BlockDeviceMappings": [{"DeviceName": "/dev/xvdb", "Ebs": {
            "VolumeSize": int_setting(f"{group.upper()}_DATA_VOLUME_GIB", 20, 500),
            "VolumeType": "gp3", "Encrypted": True, "DeleteOnTermination": True}}],
        "TagSpecifications": [{"ResourceType": t, "Tags": tag_list()} for t in ("instance", "volume", "network-interface")],
    }
    if group == "sandbox":
        data["EnclaveOptions"] = {"Enabled": True}
    return data


def lt_mismatch(data, have):
    """The keys of a launch template readback with another value than the rendered data, and the keys
    that the sample does not set (a key pair, network interfaces, security groups, an instance profile)."""
    return sorted(k for k in data if have.get(k) != data[k]), sorted(k for k in have if k not in data)


def cmd_launch_template(args):
    group = args.group
    name = setting("SANDBOX_LT_NAME" if group == "sandbox" else "SYSTEM_LT_NAME")
    data = launch_template_data(group, cluster_info())
    (run_dir() / f"lt-{group}.json").write_text(json.dumps(data, indent=2) + "\n")
    found = aws("ec2", "describe-launch-templates", "--launch-template-names", name,
                allow=("InvalidLaunchTemplateName.NotFoundException",))
    templates = (found or {}).get("LaunchTemplates", [])
    if templates:
        lt = templates[0]
        require(is_ours(lt.get("Tags", [])), f"launch template {name} exists and is not this run's")
        have = aws("ec2", "describe-launch-template-versions", "--launch-template-id", lt["LaunchTemplateId"],
                   "--versions", "1")["LaunchTemplateVersions"][0]["LaunchTemplateData"]
        diff, extra = lt_mismatch(data, have)  # the whole readback must be the rendered data
        require(not diff and not extra, f"launch template {name} exists with other values: {diff}, "
                f"and fields the sample does not set: {extra}; run ./clean.sh")
        lt_id = lt["LaunchTemplateId"]
    else:
        spec = {"ResourceType": "launch-template", "Tags": tag_list()}
        lt_id = aws("ec2", "create-launch-template", "--launch-template-name", name,
                    "--launch-template-data", json.dumps(data),
                    "--tag-specifications", json.dumps([spec]))["LaunchTemplate"]["LaunchTemplateId"]
    print(lt_id)  # setup.sh checks the printed ID (^lt-[0-9a-f]{17}$) before it records it


def cmd_check_user_data(args):
    """The launch template readback is the data that launch-template rendered (lt-<group>.json of the run)."""
    doc = read_json(args.file)
    try:
        have = doc["LaunchTemplateVersions"][0]["LaunchTemplateData"]
    except (KeyError, IndexError, TypeError) as err:
        raise Unknown("the input is not describe-launch-template-versions output") from err
    diff, extra = lt_mismatch(read_json(str(run_dir() / f"lt-{args.group}.json")), have)
    require(not diff and not extra, f"{args.group} launch template is not the rendered data: other values {diff}, "
            f"fields the sample does not set {extra}")
    print(f"{args.group} launch template: the rendered data (IMDSv2 hop limit 1, TOML settings)")


def cmd_runtimeclass(_):
    print(json.dumps(RUNTIMECLASS, indent=2))


def cmd_check_runtimeclass(args):
    rc = read_json(args.file)
    labels = rc.get("metadata", {}).get("labels", {})
    require(labels.get(NS_LABEL[0]) == NS_LABEL[1], "RuntimeClass isolated-sandbox is not this sample's")
    for key in ("handler", "overhead", "scheduling"):
        require(rc.get(key) == RUNTIMECLASS[key], f"RuntimeClass {key} is {rc.get(key)}, want {RUNTIMECLASS[key]}")
    print("RuntimeClass isolated-sandbox: the sample's, handler, overhead and node selector as the User Guide gives")


def cmd_preflight_daemonset(args):
    ds = read_json(args.file)
    spec = ds["spec"]["template"]["spec"]
    labels = {**node_labels("sandbox"), "kubernetes.io/os": "linux"}
    selector_ok = all(labels.get(k) == v for k, v in spec.get("nodeSelector", {}).items())
    tolerated = any(t.get("operator") == "Exists" and t.get("key") in (None, SANDBOX_TAINT_KEY)
                    or t.get("key") == SANDBOX_TAINT_KEY and t.get("value") == "true"
                    for t in spec.get("tolerations", []))
    require(selector_ok and tolerated, "the cilium DaemonSet would not run on the sandbox node (selector or toleration)")
    print("cilium DaemonSet: selects and tolerates the sandbox node")


def cmd_check_operator_role(_):
    cluster = setting("CLUSTER_NAME")
    assocs = aws("eks", "list-pod-identity-associations", "--cluster-name", cluster, "--namespace",
                 "kube-system", "--service-account", "cilium-operator").get("associations", [])
    require(len(assocs) == 1, f"expected one association for kube-system/cilium-operator, found {len(assocs)}")
    aid = assocs[0]["associationId"]
    assoc = aws("eks", "describe-pod-identity-association", "--cluster-name", cluster, "--association-id", aid)["association"]
    want_tags = f"{OWNER_TAG[0]}={OWNER_TAG[1]} RunId={run_id()}"
    require(is_ours(assoc.get("tags")), f"Pod Identity association {aid} is not tagged {want_tags}: {assoc.get('tags')}")
    role = assoc["roleArn"].rsplit("/", 1)[1]
    require(role == setting("OPERATOR_ROLE_NAME"), f"the association uses role {role}, not {setting('OPERATOR_ROLE_NAME')}")
    require(is_ours(role_tags(role)), f"operator role {role} is not tagged {want_tags}")
    trust = aws("iam", "get-role", "--role-name", role)["Role"].get("AssumeRolePolicyDocument")
    wrong = trust_problems(trust)
    require(not wrong, f"operator role {role} trust: " + "; ".join(wrong))
    attached = aws("iam", "list-attached-role-policies", "--role-name", role).get("AttachedPolicies", [])
    require(not attached, f"operator role {role} has managed policies: {[p['PolicyName'] for p in attached]}")
    actions = set()
    for name in aws("iam", "list-role-policies", "--role-name", role).get("PolicyNames", []):
        actions |= policy_actions(aws("iam", "get-role-policy", "--role-name", role, "--policy-name", name)["PolicyDocument"])
    require(actions == OPERATOR_ACTIONS, f"operator role actions differ: {sorted(actions ^ OPERATOR_ACTIONS)}")
    print(f"operator role {role}: association and role tagged for run {run_id()}, EKS Pod Identity trust only, "
          f"exactly the {len(actions)} EC2 actions of the Cilium list")
    for group in aws("eks", "list-nodegroups", "--cluster-name", cluster).get("nodegroups", []):
        node_role = aws("eks", "describe-nodegroup", "--cluster-name", cluster,
                        "--nodegroup-name", group)["nodegroup"]["nodeRole"].rsplit("/", 1)[1]
        wrong = node_role_problems(node_role)
        require(not wrong, f"node role {node_role} ({group}): " + "; ".join(wrong))
        names = sorted(arn.rsplit("/", 1)[1] for arn in NODE_POLICY_ARNS)
        print(f"node role {node_role} ({group}): {', '.join(names)} (AWS managed), no inline policy, no Cilium EC2 action")


def trust_problems(document):
    """What is wrong with the operator role trust: one statement that allows the EKS Pod Identity principal
    sts:AssumeRole and sts:TagSession, and nothing more (no other principal, action, condition or statement)."""
    if isinstance(document, str):  # IAM sends the document URL-encoded; the AWS CLI decodes it
        try:
            document = json.loads(urllib.parse.unquote(document))
        except ValueError as err:
            raise Unknown("the trust policy is not JSON") from err
    statements = document.get("Statement") if isinstance(document, dict) else None
    statements = [statements] if isinstance(statements, dict) else statements
    if not isinstance(statements, list) or len(statements) != 1 or not isinstance(statements[0], dict):
        return [f"the trust policy must have exactly one statement, got {statements!r}"]

    def as_set(value):  # a policy element is a string or a list of strings
        return {value} if isinstance(value, str) else set(value) if isinstance(value, list) else value
    st = {k: v for k, v in statements[0].items() if k != "Sid"}
    principal = st.get("Principal") if isinstance(st.get("Principal"), dict) else {}
    got = (sorted(st), st.get("Effect"), {k: as_set(v) for k, v in principal.items()}, as_set(st.get("Action")))
    want = (["Action", "Effect", "Principal"], "Allow", {"Service": {POD_IDENTITY_PRINCIPAL}}, POD_IDENTITY_ACTIONS)
    return [] if got == want else [f"the statement is {statements[0]!r}, want only Effect Allow, Principal Service "
                                   f"{POD_IDENTITY_PRINCIPAL} and Action {sorted(POD_IDENTITY_ACTIONS)}"]
