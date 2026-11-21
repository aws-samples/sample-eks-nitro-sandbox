"""Config, rendering and launch-template checks of scripts/cilium_bottlerocket.py."""

import base64
import ipaddress
import json
import re
import urllib.parse
from pathlib import Path

import yaml

from cb_base import (CRI_PROXY_ENDPOINT, LT_ID, NODEGROUP_LABEL, NS_LABEL, OWNER_TAG, SAMPLE,
                     SANDBOX_NODE_LABEL, SANDBOX_TAINT_KEY, Reject, Unknown, aws, int_setting,
                     is_ours, read_input, read_json, require, run_id, sample_tags, setting, state_get,
                     tag_list)

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
    require(re.fullmatch(r"[a-z][a-z0-9-]{2,31}", setting("CLUSTER_NAME")) is not None,
            f"CLUSTER_NAME '{setting('CLUSTER_NAME')}' must be 3 to 32 lowercase letters, digits and hyphens")
    zones()
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
    print("config: names, zones, instance types, slot count and volume sizes are valid")


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
    require(isinstance(values, dict), f"{path} is not a map")
    wrong = [f"{'.'.join(p)}={dig(values, p)!r} (want {v!r})" for p, v in CILIUM_EXPECTED.items()
             if dig(values, p) != v]
    require(not wrong, f"{path}: " + "; ".join(wrong))
    body = "\n".join(line.split("#", 1)[0] for line in text.splitlines())
    require(re.search(r"\b1\.[0-9]+\.[0-9]+\b", body) is None and "image" not in values,
            f"{path} states a version or an image; cilium.lock is the one version source")
    print("cilium values: ENI IPAM, native routing, kube-proxy replacement, socketLB.hostNamespaceOnly=true")


def fill(obj, values):
    """Fill ${NAME} in every string. A string that is only ${NAME} takes the value's type."""
    if isinstance(obj, dict):
        return {k: fill(v, values) for k, v in obj.items()}
    if isinstance(obj, list):
        return [fill(v, values) for v in obj]
    if isinstance(obj, str):
        whole = re.fullmatch(r"\$\{([A-Z_]+)\}", obj)
        if whole:
            if whole.group(1) not in values:
                raise Unknown(f"no value for ${{{whole.group(1)}}}")
            return values[whole.group(1)]

        def one(match):
            if match.group(1) not in values:
                raise Unknown(f"no value for ${{{match.group(1)}}}")
            return str(values[match.group(1)])
        return re.sub(r"\$\{([A-Z_]+)\}", one, obj)
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
    doc = fill(load_template("eksctl/cluster.yaml"), {**base_values(), "AVAILABILITY_ZONES": zones()})
    names = [a["name"] for a in doc.get("addons", [])]
    require(doc["metadata"]["version"] == "1.36", "the cluster must be Kubernetes 1.36")
    require(doc.get("addonsConfig", {}).get("disableDefaultAddons") is True, "default add-ons must be off")
    require(not {"vpc-cni", "kube-proxy"} & set(names), f"the cluster must not have vpc-cni or kube-proxy: {names}")
    require(doc["metadata"]["tags"] == sample_tags(), "the cluster tags must be ManagedBy and RunId")
    write_rendered("cluster.yaml", doc)


def policy_actions(document):
    actions = set()
    for statement in document.get("Statement", []):
        require(statement.get("Effect") == "Allow" and "NotAction" not in statement, "unexpected policy statement")
        action = statement.get("Action", [])
        actions |= {action} if isinstance(action, str) else set(action)
    return actions


def cmd_render_pod_identity(_):
    doc = fill(load_template("eksctl/pod-identity.yaml"),
               {**base_values(), "OPERATOR_ROLE_NAME": setting("OPERATOR_ROLE_NAME")})
    assocs = doc["iam"]["podIdentityAssociations"]
    require(len(assocs) == 1 and assocs[0]["serviceAccountName"] == "cilium-operator"
            and assocs[0]["namespace"] == "kube-system", "exactly one association, for kube-system/cilium-operator")
    actions = policy_actions(assocs[0]["permissionPolicy"])
    require(actions == OPERATOR_ACTIONS, f"operator actions differ from the Cilium list: {sorted(actions ^ OPERATOR_ACTIONS)}")
    write_rendered("pod-identity.yaml", doc)


def cmd_render_nodegroup(args):
    group = args.group
    lt = state_get(f"{group.upper()}_LAUNCH_TEMPLATE_ID")
    require(LT_ID.fullmatch(lt) is not None, f"the state file has no {group} launch template ID")
    doc = load_template("eksctl/nodegroups.yaml")
    doc["managedNodeGroups"] = [g for g in doc["managedNodeGroups"] if g["name"] == group]
    doc = fill(doc, {**base_values(), "NODE_ZONE": zones()[0], f"{group.upper()}_LAUNCH_TEMPLATE_ID": lt})
    require(len(doc["managedNodeGroups"]) == 1, f"nodegroups.yaml has no single group {group}")
    ng = doc["managedNodeGroups"][0]
    require((ng["minSize"], ng["maxSize"], ng["desiredCapacity"]) == (1, 1, 1), f"{group} must be exactly one node")
    policies = set(ng["iam"]["attachPolicyARNs"])
    require(policies == NODE_POLICY_ARNS, f"{group} node role policies must be {sorted(NODE_POLICY_ARNS)}, got {sorted(policies)}")
    require(ng["tags"] == sample_tags(), f"{group} tags must be ManagedBy and RunId")
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
    """What differs between a node group that EKS has (describe-nodegroup) and the managed node
    group rendered from eksctl/nodegroups.yaml: the two tags, the launch template and its
    version, the sizes, the labels and taints, private subnets of the run's VPC in the node zone,
    no remote access, and a node role of this run with exactly the two AWS managed policies."""
    wrong = []
    if not is_ours(found.get("tags")):
        wrong.append(f"tags {found.get('tags')} are not {OWNER_TAG[0]}={OWNER_TAG[1]} RunId={run_id()}")
    lt, want_lt = found.get("launchTemplate") or {}, ng["launchTemplate"]
    if (lt.get("id"), str(lt.get("version"))) != (want_lt["id"], str(want_lt["version"])):
        wrong.append(f"launch template {lt.get('id')} version {lt.get('version')}, "
                     f"want {want_lt['id']} version {want_lt['version']}")
    sizes = found.get("scalingConfig") or {}
    want_sizes = {"minSize": ng["minSize"], "maxSize": ng["maxSize"], "desiredSize": ng["desiredCapacity"]}
    if {k: sizes.get(k) for k in want_sizes} != want_sizes:
        wrong.append(f"sizes {sizes}, want {want_sizes}")
    labels, want_labels = found.get("labels") or {}, ng.get("labels") or {}
    # eksctl adds its own alpha.eksctl.io/ labels to a managed node group.
    if {k: v for k, v in labels.items() if not k.startswith("alpha.eksctl.io/")} != want_labels:
        wrong.append(f"labels {labels}, want {want_labels}")
    taints = sorted((t.get("key"), t.get("value"), TAINT_EFFECTS.get(t.get("effect"), t.get("effect")))
                    for t in found.get("taints") or [])
    want_taints = sorted((t["key"], t["value"], TAINT_EFFECTS.get(t["effect"], t["effect"])) for t in ng.get("taints") or [])
    if taints != want_taints:
        wrong.append(f"taints {taints}, want {want_taints}")
    if found.get("remoteAccess"):
        wrong.append(f"remote access is set: {found['remoteAccess']}")
    subnets = found.get("subnets") or []
    if not subnets:
        wrong.append("no subnets")
    else:
        zone, vpc = zones()[0], state_get("VPC_ID")
        for subnet in aws("ec2", "describe-subnets", "--subnet-ids", *subnets).get("Subnets", []):
            if (subnet.get("VpcId"), subnet.get("AvailabilityZone"), subnet.get("MapPublicIpOnLaunch")) != (vpc, zone, False):
                wrong.append(f"subnet {subnet.get('SubnetId')} is not a private subnet of {vpc or 'the run VPC'} in {zone}")
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
    """What is wrong with a node role: its managed policies must be exactly the two AWS managed
    policy ARNs of eksctl/nodegroups.yaml, and it must have no inline policy."""
    arns = {p.get("PolicyArn") for p in aws("iam", "list-attached-role-policies", "--role-name", role).get("AttachedPolicies", [])}
    inline = aws("iam", "list-role-policies", "--role-name", role).get("PolicyNames", [])
    wrong = []
    if arns != NODE_POLICY_ARNS:
        wrong.append(f"managed policies {sorted(arns)}, want exactly {sorted(NODE_POLICY_ARNS)}")
    if inline:
        wrong.append(f"inline policies {inline}, want none")
    return wrong


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
    """(max-pods, ENI formula, ceiling, vCPUs) of one describe-instance-types entry. The ENI
    formula of the Amazon EKS AMIs is ENIs x (IPv4 per ENI - 1) + 2. The ceiling is the one of the
    Amazon EKS max-pods calculator: Amazon EKS User Guide, "Choose an optimal Amazon EC2 node
    instance type", section "How maxPods is determined"
    (https://docs.aws.amazon.com/eks/latest/userguide/choosing-instance-type.html#max-pods-precedence),
    110 for less than 30 vCPUs and 250 for more. The guide does not place exactly 30 vCPUs; the
    sample gives it 250. m8i.xlarge (4 vCPUs, 4 ENIs, 30 IPv4 each): formula 118, ceiling 110."""
    net = info.get("NetworkInfo")
    if not isinstance(net, dict):
        raise Unknown("the instance type has no NetworkInfo")
    formula = (positive(net, "NetworkInfo", "MaximumNetworkInterfaces")
               * (positive(net, "NetworkInfo", "Ipv4AddressesPerInterface") - 1) + 2)
    vcpus = positive(info.get("VCpuInfo"), "VCpuInfo", "DefaultVCpus")
    ceiling = 110 if vcpus < 30 else 250
    return min(formula, ceiling), formula, ceiling, vcpus


def cmd_derive_max_pods(args):
    """Print '<max-pods> <ENI formula> <ceiling> <vCPUs>' of an instance type, all from one
    ec2 describe-instance-types read."""
    require(INSTANCE_TYPE.fullmatch(args.instance_type) is not None, f"{args.instance_type!r} is not an instance type")
    types = aws("ec2", "describe-instance-types", "--instance-types", args.instance_type).get("InstanceTypes") or []
    if len(types) != 1:
        raise Unknown(f"describe-instance-types gave {len(types)} entries for {args.instance_type}")
    print(*derived_max_pods(types[0]))


def max_pods(group):
    """The max-pods of a node group, as setup.sh derived and recorded it (MAX_PODS_SYSTEM or
    MAX_PODS_SANDBOX in the run state)."""
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


def parse_toml(text):
    """The small TOML subset that user_data writes: tables, quoted or bare keys, strings,
    integers and arrays of strings. Anything else is malformed."""
    doc, table = {}, None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        head = re.fullmatch(r"\[([a-z0-9.-]+)\]", line)
        if head:
            table = doc.setdefault(head.group(1), {})
            continue
        pair = re.fullmatch(r'("(?:[^"\\]|\\.)*"|[A-Za-z0-9_-]+)\s*=\s*(.+)', line)
        if not pair or table is None:
            raise Reject(f"user data line is not valid TOML here: {raw!r}")
        key = json.loads(pair.group(1)) if pair.group(1).startswith('"') else pair.group(1)
        try:
            table[key] = json.loads(pair.group(2))
        except ValueError as err:
            raise Reject(f"user data value is not valid: {raw!r}") from err
    return doc


def cluster_info():
    cluster = aws("eks", "describe-cluster", "--name", setting("CLUSTER_NAME"))["cluster"]
    require(is_ours(cluster.get("tags", {})), f"cluster {cluster['name']} is not this run's")
    cidr = cluster["kubernetesNetworkConfig"]["serviceIpv4Cidr"]
    dns = str(ipaddress.ip_network(cidr).network_address + 10)
    return {"name": cluster["name"], "endpoint": cluster["endpoint"],
            "ca": cluster["certificateAuthority"]["data"], "dns": dns}


def launch_template_data(group, info):
    ami = state_get("SYSTEM_AMI_ID" if group == "system" else "SANDBOX_AMI_ID")
    require(AMI.fullmatch(ami) is not None, f"the state file has no {group} AMI ID")
    data = {
        "ImageId": ami,
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


def user_data_problems(group, data):
    """What is wrong with launch template data for this group."""
    wrong = []
    meta = data.get("MetadataOptions", {})
    if meta.get("HttpTokens") != "required" or meta.get("HttpPutResponseHopLimit") != 1:
        wrong.append(f"IMDS must be v2 required with hop limit 1, got {meta}")
    enclave = data.get("EnclaveOptions", {}).get("Enabled") is True
    if enclave != (group == "sandbox"):
        wrong.append(f"Nitro Enclaves enabled={enclave} on the {group} node")
    try:
        doc = parse_toml(base64.b64decode(data.get("UserData", ""), validate=True).decode())
    except (ValueError, UnicodeDecodeError):
        return wrong + ["the user data is not base64 TOML"]
    kube = doc.get("settings.kubernetes", {})
    labels = doc.get("settings.kubernetes.node-labels", {})
    want_pods = max_pods(group)
    if kube.get("cluster-name") != setting("CLUSTER_NAME"):
        wrong.append(f"cluster-name is {kube.get('cluster-name')!r}")
    if kube.get("max-pods") != want_pods:
        wrong.append(f"max-pods is {kube.get('max-pods')!r}, want {want_pods}")
    endpoint = kube.get("container-runtime-endpoint")
    if endpoint != (CRI_PROXY_ENDPOINT if group == "sandbox" else None):
        wrong.append(f"container-runtime-endpoint is {endpoint!r} on the {group} node")
    if labels != node_labels(group):
        wrong.append(f"node-labels are {labels}, want {node_labels(group)}")
    if "settings.boot" in doc or "settings.kernel" in doc:
        wrong.append("the user data sets boot or kernel settings; the mempool parameter is build-time only")
    return wrong


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
        # The whole readback must be the rendered data: also a field that the sample does not set
        # (a key pair, network interfaces, security groups, an instance profile) stops the reuse.
        diff = sorted(k for k in data if have.get(k) != data[k])
        extra = sorted(k for k in have if k not in data)
        require(not diff and not extra, f"launch template {name} exists with other values: {diff}, "
                f"and fields the sample does not set: {extra}; run ./clean.sh")
        lt_id = lt["LaunchTemplateId"]
    else:
        spec = {"ResourceType": "launch-template", "Tags": tag_list()}
        lt_id = aws("ec2", "create-launch-template", "--launch-template-name", name,
                    "--launch-template-data", json.dumps(data),
                    "--tag-specifications", json.dumps([spec]))["LaunchTemplate"]["LaunchTemplateId"]
    require(LT_ID.fullmatch(lt_id) is not None, f"launch template ID {lt_id!r} is malformed")
    print(lt_id)


def cmd_check_user_data(args):
    doc = read_json(args.file)
    try:
        data = doc["LaunchTemplateVersions"][0]["LaunchTemplateData"]
    except (KeyError, IndexError, TypeError) as err:
        raise Unknown("the input is not describe-launch-template-versions output") from err
    wrong = user_data_problems(args.group, data)
    require(not wrong, f"{args.group} launch template: " + "; ".join(wrong))
    print(f"{args.group} launch template: IMDSv2 hop limit 1, TOML settings as rendered")


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
    """What is wrong with the trust policy of the operator role: one statement that allows the
    EKS Pod Identity service principal sts:AssumeRole and sts:TagSession, and nothing more (no
    other principal, action, condition or statement)."""
    if isinstance(document, str):  # IAM sends the document URL-encoded; the AWS CLI decodes it
        try:
            document = json.loads(urllib.parse.unquote(document))
        except ValueError as err:
            raise Unknown("the trust policy is not JSON") from err
    statements = document.get("Statement") if isinstance(document, dict) else None
    statements = [statements] if isinstance(statements, dict) else statements
    if not isinstance(statements, list) or len(statements) != 1 or not isinstance(statements[0], dict):
        return [f"the trust policy must have exactly one statement, got {statements!r}"]
    st, wrong = statements[0], []
    if set(st) - {"Sid", "Effect", "Principal", "Action"}:
        wrong.append(f"the statement also has {sorted(set(st) - {'Sid', 'Effect', 'Principal', 'Action'})}")
    if st.get("Effect") != "Allow":
        wrong.append(f"Effect is {st.get('Effect')!r}")
    principal = st.get("Principal")
    service = principal.get("Service") if isinstance(principal, dict) and set(principal) == {"Service"} else None
    if (service if isinstance(service, list) else [service]) != [POD_IDENTITY_PRINCIPAL]:
        wrong.append(f"Principal is {principal!r}, want only Service {POD_IDENTITY_PRINCIPAL}")
    action = st.get("Action")
    actions = {action} if isinstance(action, str) else set(action) if isinstance(action, list) else None
    if actions != POD_IDENTITY_ACTIONS:
        wrong.append(f"Action is {action!r}, want {sorted(POD_IDENTITY_ACTIONS)}")
    return wrong
