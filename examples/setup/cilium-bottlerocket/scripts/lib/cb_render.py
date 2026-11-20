"""Config, rendering and launch-template checks of scripts/cilium_bottlerocket.py."""

import base64
import ipaddress
import json
import re
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
NODE_POLICIES = {"AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly"}
CILIUM_EXPECTED = {
    ("eni", "enabled"): True, ("ipam", "mode"): "eni", ("routingMode",): "native",
    ("kubeProxyReplacement",): True, ("k8sServicePort",): 443,
    ("socketLB", "hostNamespaceOnly"): True, ("operator", "replicas"): 1,
    ("operator", "nodeSelector"): {NODEGROUP_LABEL: "system"},
    ("eni", "eniTags"): {OWNER_TAG[0]: OWNER_TAG[1]},
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
    int_setting("SYSTEM_MAX_PODS", 1, 250)
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
    policies = {p.rsplit("/", 1)[1] for p in ng["iam"]["attachPolicyARNs"]}
    require(policies == NODE_POLICIES, f"{group} node role policies must be {sorted(NODE_POLICIES)}, got {sorted(policies)}")
    require(ng["tags"] == sample_tags(), f"{group} tags must be ManagedBy and RunId")
    write_rendered(f"nodegroups-{group}.yaml", doc)


def cmd_render_probe(args):
    require(re.fullmatch(r"cb-probe-(system|sandbox)-[a-z0-9]{1,20}", args.name) is not None,
            f"probe name {args.name} is not cb-probe-<system|sandbox>-<run ID>")
    require(re.fullmatch(r"[a-z0-9][a-z0-9.-]{0,252}", args.node) is not None, f"node name {args.node} is not valid")
    print(yaml.safe_dump(fill(load_template("deploy/probe/node-probe.yaml"),
                              {"PROBE_NAME": args.name, "NODE_NAME": args.node,
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


def user_data(group, info):
    max_pods = int_setting("SANDBOX_SLOTS" if group == "sandbox" else "SYSTEM_MAX_PODS", 1, 250)
    lines = ["[settings.kubernetes]",
             f"cluster-name = {toml_str(info['name'])}",
             f"api-server = {toml_str(info['endpoint'])}",
             f"cluster-certificate = {toml_str(info['ca'])}",
             f"cluster-dns-ip = {toml_str(info['dns'])}",
             f"max-pods = {max_pods}"]
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
    want_pods = int_setting("SANDBOX_SLOTS" if group == "sandbox" else "SYSTEM_MAX_PODS", 1, 250)
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
        diff = [k for k in data if have.get(k) != data[k]]
        require(not diff, f"launch template {name} exists with other values: {diff}; run ./clean.sh")
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
    assoc = aws("eks", "describe-pod-identity-association", "--cluster-name", cluster,
                "--association-id", assocs[0]["associationId"])["association"]
    role = assoc["roleArn"].rsplit("/", 1)[1]
    require(role == setting("OPERATOR_ROLE_NAME"), f"the association uses role {role}, not {setting('OPERATOR_ROLE_NAME')}")
    attached = aws("iam", "list-attached-role-policies", "--role-name", role).get("AttachedPolicies", [])
    require(not attached, f"operator role {role} has managed policies: {[p['PolicyName'] for p in attached]}")
    actions = set()
    for name in aws("iam", "list-role-policies", "--role-name", role).get("PolicyNames", []):
        actions |= policy_actions(aws("iam", "get-role-policy", "--role-name", role, "--policy-name", name)["PolicyDocument"])
    require(actions == OPERATOR_ACTIONS, f"operator role actions differ: {sorted(actions ^ OPERATOR_ACTIONS)}")
    print(f"operator role {role}: exactly the {len(actions)} EC2 actions of the Cilium list")
    for group in aws("eks", "list-nodegroups", "--cluster-name", cluster).get("nodegroups", []):
        node_role = aws("eks", "describe-nodegroup", "--cluster-name", cluster,
                        "--nodegroup-name", group)["nodegroup"]["nodeRole"].rsplit("/", 1)[1]
        names = {p["PolicyName"] for p in aws("iam", "list-attached-role-policies", "--role-name", node_role).get("AttachedPolicies", [])}
        inline = aws("iam", "list-role-policies", "--role-name", node_role).get("PolicyNames", [])
        require(names == NODE_POLICIES and not inline, f"node role {node_role} ({group}) has {sorted(names)} and inline {inline}")
        print(f"node role {node_role} ({group}): {', '.join(sorted(names))}, no Cilium EC2 action")
