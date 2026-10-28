#!/usr/bin/env python3
"""Helpers for the Cilium-on-Ubuntu sample, called by setup.sh (and reused by test.sh /
clean.sh for the same rendering and ownership logic).

Everything that touches AWS goes through the aws CLI with the caller's standard credentials.
Everything that touches the cluster goes through kubectl with the KUBECONFIG common.sh
exported (this sample's own kubeconfig under the repo's gitignored tmp/, never the caller's
default one).

This module's local output (the rendered eksctl YAML and the launch-template JSON) is written
under RUN_DIR, the repo-root tmp/issue11/run directory common.sh exports, never beneath the
sample folder: anything in a sample folder is one `git add` from being published (AGENTS.md,
"Keep local files in the repository's tmp/"). When run outside those scripts (so RUN_DIR is
unset), it derives the same path from the repository root.

This module never guesses or publishes an AMI id: SANDBOX_AMI_ID and SYSTEM_AMI_ID always
come from the caller's own config.local.env (gitignored), and cmd_check_sandbox_ami verifies
the sandbox AMI's architecture, owner and expected build metadata before any node group is
created from it.
"""
import argparse
import base64
import copy
import getpass
import ipaddress
import json
import os
import re
import shlex
import string
import subprocess
import sys
from collections import Counter
from pathlib import Path

DEMO = Path(__file__).resolve().parent.parent
REPO = DEMO.parents[2]  # examples/setup/cilium-ubuntu -> repo root
# This run's local output: the kubeconfig (written by the shell scripts), the rendered eksctl
# YAML and the launch-template JSON. It lives under the repo's gitignored tmp/, never beneath
# the sample folder. common.sh exports RUN_DIR; honour it so the shell and Python agree on one
# path, and derive the same repo-root tmp/issue11/run when this module is run on its own.
OUT = Path(os.environ["RUN_DIR"]) if os.environ.get("RUN_DIR") else REPO / "tmp" / "issue11" / "run"
# Placeholder ids the page may show. Any OTHER resource id in a tracked file is a leak.
PLACEHOLDER_IDS = {"ami-0123456789abcdef0", "lt-0123456789abcdef0"}

KEEP = ("auto-delete", "no")
DEMO_TAG = ("Demo", "setup-cilium-ubuntu")
SANDBOX_TAINT_KEY = "sandbox.eks-nitro-sandbox.amazonaws.com/dedicated"
SANDBOX_GROUP = "sandbox"
SYSTEM_GROUP = "system"
NODEGROUP_LABEL = "eks.amazonaws.com/nodegroup"
# The isolated-sandbox RuntimeClass, exactly as the GA node-build bundle's UBUNTU.md (section 5,
# "Create the RuntimeClass and run a sandbox pod") gives it. Its scheduling.nodeSelector sends
# every isolated-sandbox pod to a node carrying BOTH labels, so the sandbox node must carry both
# (UBUNTU.md section 4, "Node labels") and the ordinary system node must carry neither. The
# bundle says to apply it once per cluster; this sample's cluster is new, so setup.sh creates it.
# A RuntimeClass is cluster-scoped, so the namespace's ownership label does not cover it: it
# carries the same mark itself (OWNER_LABEL, the label common.sh's NS_LABEL_KEY/NS_LABEL_VAL put
# on the namespace), and setup.sh reuses an existing one only when it carries that mark.
OWNER_LABEL = ("app.kubernetes.io/part-of", "setup-cilium-ubuntu")
RUNTIMECLASS_NAME = "isolated-sandbox"
RUNTIMECLASS_NODE_SELECTOR = {"eks.amazonaws.com/nitro-sandbox": "true", "sandbox.preview/nitro": "true"}
RUNTIMECLASS = {
    "apiVersion": "node.k8s.io/v1",
    "kind": "RuntimeClass",
    "metadata": {"name": RUNTIMECLASS_NAME, "labels": {OWNER_LABEL[0]: OWNER_LABEL[1]}},
    "handler": RUNTIMECLASS_NAME,
    "overhead": {"podFixed": {"eks.amazonaws.com/nitro-sandbox": "1", "memory": "256Mi"}},
    "scheduling": {"nodeSelector": dict(RUNTIMECLASS_NODE_SELECTOR)},
}
# The labels the sandbox node carries: its node group name (what this sample's pods select on),
# the dedicated label that matches its taint, and the two RuntimeClass labels. setup.sh passes
# them to kubelet through the launch template's bootstrap user data (launch_template_data), and
# the preflight below checks the Cilium agent DaemonSet would schedule on a node with them.
SANDBOX_LABELS = {
    NODEGROUP_LABEL: SANDBOX_GROUP,
    SANDBOX_TAINT_KEY: "true",
    **RUNTIMECLASS_NODE_SELECTOR,
}
KUBELET_LABELS = {"kubernetes.io/os": "linux", "kubernetes.io/arch": "amd64"}
# A Kubernetes label key (optional DNS prefix, then a name) and value, so every label this
# sample renders into kubelet's --node-labels is a plain token with nothing a shell or kubelet
# would read as syntax.
LABEL_KEY = re.compile(r"^(?:[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?/)?[A-Za-z0-9](?:[A-Za-z0-9._-]{0,61}[A-Za-z0-9])?$")
LABEL_VALUE = re.compile(r"^(?:[A-Za-z0-9](?:[A-Za-z0-9._-]{0,61}[A-Za-z0-9])?)?$")
# Expected shape of the Ubuntu Pod Isolation sandbox AMI, from issue #10's build. This sample
# does not rebuild or own that AMI; it only verifies the id given in config.local.env matches
# this shape before using it.
EXPECTED_AMI_ARCH = "x86_64"
EXPECTED_AMI_VIRT_TYPE = "hvm"
# A tag issue #10's sample sets on the AMI it produces, so this sample can tell a
# BTF-validated Ubuntu Pod Isolation build apart from an unrelated AMI that merely happens to
# share the same architecture and owner.
EXPECTED_AMI_TAG = ("BtfValidated", "true")
# #10's own ownership tag (TAGS_OWNER_KEY=ManagedBy, TAGS_OWNER_VALUE=RESOURCE_PREFIX,
# default "ubuntu-ami-sample" -- see ../ubuntu-ami/scripts/lib/common.sh and btf-tag.sh).
# #10's btf-tag.sh refuses to write BtfValidated=true to an AMI that does not already carry
# this tag, so ManagedBy is #10's actual provenance signal for "this run built and verified
# this AMI" -- not the AWS account id alone, which only says who owns the AMI resource, not
# which build produced it. This sample does not rebuild #10's AMI, so it checks for the tag
# value #10's own default produces; a reader who renamed RESOURCE_PREFIX when building the
# AMI sets SANDBOX_AMI_MANAGED_BY_VALUE in config.local.env to match.
EXPECTED_AMI_OWNER_TAG_KEY = "ManagedBy"
DEFAULT_SANDBOX_AMI_MANAGED_BY_VALUE = "ubuntu-ami-sample"


class DemoError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise DemoError(message)


def run(args, *, data=None):
    result = subprocess.run([str(a) for a in args], input=data, text=True, capture_output=True)
    if result.returncode:
        raise DemoError(f"{' '.join(str(a) for a in args[:4])} ... failed ({result.returncode}): "
                         f"{result.stderr.strip()[-2000:]}")
    return result.stdout


def aws(*args):
    region = setting("AWS_REGION")
    text = run(["aws", *args, "--region", region, "--output", "json"])
    return json.loads(text) if text.strip() else {}


def kube_json(*args):
    text = run(["kubectl", *args, "-o", "json"])
    value = json.loads(text) if text.strip() else None
    require(isinstance(value, dict), f"kubectl {' '.join(args)} returned no object")
    return value


def setting(name):
    value = os.environ.get(name, "").strip()
    require(value, f"{name} is empty; set it in config.local.env")
    return value


def demo_tags():
    tags = [KEEP, DEMO_TAG]
    owner = os.environ.get("OWNER_TAG", "").strip()
    if owner:
        tags.append(("Owner", owner))
    return tags


def tag_map(tags):
    """AWS returns tags as [{Key, Value}] (EC2, IAM, ASG, CFN) or {k: v} (EKS)."""
    if isinstance(tags, dict):
        return dict(tags)
    return {t["Key"]: t["Value"] for t in tags or []}


# ---------------------------------------------------------------------------
# Rendering the eksctl configs
# ---------------------------------------------------------------------------

def substitute(text, values):
    """${NAME} substitution on the YAML lines (comments are left alone, so they may mention
    ${...} freely), refusing to leave any placeholder unfilled."""
    lines = [line if line.lstrip().startswith("#") else string.Template(line).substitute(values)
             for line in text.splitlines()]
    rendered = "\n".join(lines) + "\n"
    require(not any("${" in line for line in lines if not line.lstrip().startswith("#")),
            "a ${...} placeholder was left unfilled")
    return rendered


def validate_cluster_config(cfg):
    """The properties stage 1 promises. A rendered config that breaks one is not applied."""
    meta = cfg.get("metadata", {})
    require(meta.get("tags", {}).get(KEEP[0]) == KEEP[1], "cluster tags lack auto-delete=no")
    require(str(meta.get("version")) == "1.36", "cluster version must be 1.36")
    require(cfg.get("addonsConfig", {}).get("disableDefaultAddons") is True,
            "addonsConfig.disableDefaultAddons must be true, or EKS installs vpc-cni")
    names = [a.get("name") for a in cfg.get("addons", [])]
    require("vpc-cni" not in names, "vpc-cni must not be listed as an add-on")
    require("kube-proxy" not in names,
            "kube-proxy must not be listed as an add-on: Cilium replaces it, and the rules "
            "kube-proxy writes into a node's iptables stay there after it is removed")
    require(all(n in names for n in ("coredns", "eks-pod-identity-agent")),
            "CoreDNS and the Pod Identity agent must be added back "
            "(the operator's credentials need the agent)")
    require(not cfg.get("nodeGroups") and not cfg.get("managedNodeGroups"),
            "the cluster is created without node groups; they come after Cilium")
    require(not cfg.get("iam", {}).get("podIdentityAssociations"),
            "eksctl refuses Pod Identity associations at create time without the VPC CNI")
    zones = cfg.get("availabilityZones") or []
    require(len(zones) >= 2, "EKS needs at least two availability zones")
    return cfg


OPERATOR_ACTIONS = {
    "ec2:DescribeNetworkInterfaces", "ec2:DescribeSubnets", "ec2:DescribeVpcs",
    "ec2:DescribeVpcPeeringConnections", "ec2:DescribeRouteTables", "ec2:DescribeSecurityGroups",
    "ec2:DescribeInstances", "ec2:DescribeInstanceTypes", "ec2:DescribeTags",
    "ec2:CreateNetworkInterface", "ec2:AttachNetworkInterface", "ec2:DetachNetworkInterface",
    "ec2:ModifyNetworkInterfaceAttribute", "ec2:AssignPrivateIpAddresses",
    "ec2:UnassignPrivateIpAddresses", "ec2:DeleteNetworkInterface", "ec2:CreateTags",
}


def policy_actions(document):
    """Allowed actions in an IAM policy document; any Deny, NotAction or wildcard action is
    refused, so the operator role can never silently widen past the documented ENI-mode set."""
    statements = document.get("Statement", [])
    if isinstance(statements, dict):
        statements = [statements]
    actions = set()
    for s in statements:
        require(s.get("Effect") == "Allow" and "NotAction" not in s, "unexpected statement shape")
        values = s.get("Action", [])
        values = [values] if isinstance(values, str) else values
        require(not any("*" in a for a in values), f"wildcard action in {values}")
        actions.update(values)
    return actions


def validate_pod_identity_config(cfg):
    assocs = cfg.get("iam", {}).get("podIdentityAssociations", [])
    require(len(assocs) == 1, "expected exactly one Pod Identity association")
    a = assocs[0]
    require((a.get("namespace"), a.get("serviceAccountName")) == ("kube-system", "cilium-operator"),
            "the association must bind kube-system/cilium-operator only")
    require(a.get("tags", {}).get(KEEP[0]) == KEEP[1], "the operator role lacks auto-delete=no")
    require(not a.get("permissionPolicyARNs") and not a.get("wellKnownPolicies"),
            "the operator gets only its inline policy")
    actions = policy_actions(a.get("permissionPolicy", {}))
    require(actions == OPERATOR_ACTIONS,
            f"operator actions differ from the documented ENI-mode set: {sorted(actions ^ OPERATOR_ACTIONS)}")
    return cfg


def validate_nodegroups_config(cfg):
    groups = {g.get("name"): g for g in cfg.get("managedNodeGroups", [])}
    require(set(groups) == {SYSTEM_GROUP, SANDBOX_GROUP},
            "expected exactly the system and sandbox node groups")
    for name, group in groups.items():
        require(group.get("tags", {}).get(KEEP[0]) == KEEP[1], f"node group {name} lacks auto-delete=no")
        require(group.get("desiredCapacity") == 1, f"node group {name} must have one node")
        policies = group.get("iam", {}).get("attachPolicyARNs", [])
        require(policies and not any(p.endswith("/AmazonEKS_CNI_Policy") for p in policies),
                f"node group {name} must not get AmazonEKS_CNI_Policy (the operator has its own role)")
        require(re.fullmatch(r"lt-[0-9a-f]{17}", str(group.get("launchTemplate", {}).get("id", ""))),
                f"the {name} node group needs this sample's launch template id")
    sandbox = groups[SANDBOX_GROUP]
    require(any(t.get("key") == SANDBOX_TAINT_KEY and t.get("effect") == "NoSchedule"
                for t in sandbox.get("taints", [])),
            "the sandbox node group must carry the dedicated taint")
    for name, group in groups.items():
        labels = group.get("labels") or {}
        require(isinstance(labels, dict) and all(
                    isinstance(k, str) and isinstance(v, str) and LABEL_KEY.match(k) and LABEL_VALUE.match(v)
                    for k, v in labels.items()),
                f"node group {name} has a label that is not a plain Kubernetes label key and string value")
        require(NODEGROUP_LABEL not in labels,
                f"node group {name} must not set {NODEGROUP_LABEL}; setup.sh sets it from the group's name")
    # The GA RuntimeClass schedules isolated-sandbox pods onto nodes with BOTH labels, so the
    # sandbox node group must carry both, and the ordinary system node group neither: a system
    # node with one of them could be picked for a sandbox pod it cannot run.
    sandbox_labels = sandbox.get("labels") or {}
    missing = [f"{k}={v}" for k, v in RUNTIMECLASS_NODE_SELECTOR.items() if sandbox_labels.get(k) != v]
    require(not missing, f"the sandbox node group lacks the {RUNTIMECLASS_NAME} RuntimeClass label(s) "
                         f"{', '.join(missing)}, so no sandbox pod could schedule on it")
    require(sandbox_labels.get(SANDBOX_TAINT_KEY) == "true",
            f"the sandbox node group must carry the {SANDBOX_TAINT_KEY}=true label that matches its taint")
    system_labels = groups[SYSTEM_GROUP].get("labels") or {}
    stray = sorted(k for k in list(RUNTIMECLASS_NODE_SELECTOR) + [SANDBOX_TAINT_KEY] if k in system_labels)
    require(not stray, f"the system node group must not carry {', '.join(stray)}: it is an ordinary node")
    return cfg


def load_config(template, values, validate):
    import yaml  # PyYAML; imported here so offline checks that do not render need not have it
    text = substitute((DEMO / "eksctl" / template).read_text(), values)
    return validate(yaml.safe_load(text))


def render_config(template, destination, values, validate):
    import yaml
    cfg = load_config(template, values, validate)
    OUT.mkdir(mode=0o700, parents=True, exist_ok=True)
    destination.write_text(yaml.safe_dump(cfg, sort_keys=False))
    destination.chmod(0o600)
    try:
        shown = destination.relative_to(REPO)
    except ValueError:
        shown = destination
    print(f"Rendered {shown}")


def zones():
    values = setting("AVAILABILITY_ZONES").split()
    require(len(values) >= 2, "AVAILABILITY_ZONES needs two zones")
    return values


def cmd_render_cluster(_):
    render_config("cluster.yaml", OUT / "cluster.yaml", {
        "CLUSTER_NAME": setting("CLUSTER_NAME"), "AWS_REGION": setting("AWS_REGION"),
        "AVAILABILITY_ZONES": json.dumps(zones()),
    }, validate_cluster_config)
    render_config("pod-identity.yaml", OUT / "pod-identity.yaml", {
        "CLUSTER_NAME": setting("CLUSTER_NAME"), "AWS_REGION": setting("AWS_REGION"),
    }, validate_pod_identity_config)


def nodegroup_values(system_lt, sandbox_lt):
    return {
        "CLUSTER_NAME": setting("CLUSTER_NAME"), "AWS_REGION": setting("AWS_REGION"),
        "NODE_ZONE": zones()[0],
        "SYSTEM_LAUNCH_TEMPLATE_ID": system_lt,
        "SANDBOX_LAUNCH_TEMPLATE_ID": sandbox_lt,
    }


def cmd_render_nodegroups(args):
    render_config("nodegroups.yaml", OUT / "nodegroups.yaml",
                  nodegroup_values(args.system_launch_template, args.sandbox_launch_template),
                  validate_nodegroups_config)


def node_labels(group):
    """The labels kubelet registers this group's node with: the node group's name, then every
    label eksctl/nodegroups.yaml gives the group. Read from the same file eksctl applies, and
    validated by validate_nodegroups_config first, so the sandbox node always carries both
    RuntimeClass labels and the system node neither. The launch templates are created before
    their ids exist in nodegroups.yaml, so a placeholder id fills that field here; only the
    labels are used."""
    placeholder = "lt-" + "0" * 17
    cfg = load_config("nodegroups.yaml", nodegroup_values(placeholder, placeholder), validate_nodegroups_config)
    found = [g for g in cfg["managedNodeGroups"] if g.get("name") == group]
    require(len(found) == 1, f"eksctl/nodegroups.yaml has no single node group named {group}")
    return {NODEGROUP_LABEL: group, **(found[0].get("labels") or {})}


# ---------------------------------------------------------------------------
# The sandbox AMI preflight: architecture, owner and expected build metadata
# ---------------------------------------------------------------------------

def cmd_check_sandbox_ami(_):
    """Verify SANDBOX_AMI_ID before any launch template or node group is built from it. This
    never substitutes a different AMI and never guesses one when the check fails: it only
    confirms the id the caller supplied in config.local.env is the shape issue #10's Ubuntu
    Pod Isolation build produces, so a stale or mistyped id (an ordinary Ubuntu AMI, someone
    else's AMI, last month's pre-BTF-fix build) is refused before it reaches EC2."""
    ami = setting("SANDBOX_AMI_ID")
    require(re.fullmatch(r"ami-[0-9a-f]{17}", ami), f"SANDBOX_AMI_ID '{ami}' is not a well-formed AMI id")
    owner_account = setting("AWS_ACCOUNT_ID")
    images = aws("ec2", "describe-images", "--owners", owner_account, "--image-ids", ami).get("Images", [])
    require(images, f"AMI {ami} was not found, or is not owned by account {owner_account}; "
            "this sample refuses to use an AMI it does not own, so it never guesses a published id")
    image = images[0]
    require(image.get("State") == "available", f"AMI {ami} is not in the 'available' state (found '{image.get('State')}')")
    require(image.get("Architecture") == EXPECTED_AMI_ARCH,
            f"AMI {ami} has architecture '{image.get('Architecture')}', expected '{EXPECTED_AMI_ARCH}'")
    require(image.get("VirtualizationType") == EXPECTED_AMI_VIRT_TYPE,
            f"AMI {ami} has virtualization type '{image.get('VirtualizationType')}', expected '{EXPECTED_AMI_VIRT_TYPE}'")
    name = image.get("Name", "")
    require("ubuntu" in name.lower(), f"AMI {ami} name '{name}' does not look like an Ubuntu build")
    tags = tag_map(image.get("Tags"))
    # #10's btf-tag.sh never writes BtfValidated=true to an AMI unless that AMI already
    # carries #10's own ManagedBy ownership tag (btf_ami_is_owned, checked BEFORE tagging).
    # So BtfValidated=true alone does not distinguish "this run's #10 build, verified" from a
    # copy of the tag value on an unrelated AMI; checking ManagedBy too matches what #10
    # actually guarantees, not just the one tag it writes last.
    managed_by_value = os.environ.get("SANDBOX_AMI_MANAGED_BY_VALUE", "").strip() \
        or DEFAULT_SANDBOX_AMI_MANAGED_BY_VALUE
    require(tags.get(EXPECTED_AMI_OWNER_TAG_KEY) == managed_by_value,
            f"AMI {ami} is not tagged {EXPECTED_AMI_OWNER_TAG_KEY}={managed_by_value}; it does not carry "
            "the ../ubuntu-ami build's own ownership tag, so it is not provably that sample's output "
            "(set SANDBOX_AMI_MANAGED_BY_VALUE in config.local.env if you built it with a different "
            "RESOURCE_PREFIX there).")
    require(tags.get(EXPECTED_AMI_TAG[0]) == EXPECTED_AMI_TAG[1],
            f"AMI {ami} is not tagged {EXPECTED_AMI_TAG[0]}={EXPECTED_AMI_TAG[1]}; it was not produced (or was "
            "not re-validated) by the ../ubuntu-ami BTF-enabled build this sample depends on. "
            "Build and tag the AMI with that sample first, or re-check an existing one against its README.")
    root = next((m for m in image.get("BlockDeviceMappings", []) if m.get("DeviceName") == image.get("RootDeviceName")), None)
    require(root is not None, f"AMI {ami} has no root device mapping matching '{image.get('RootDeviceName')}'")
    print(f"AMI {ami}: {name}")
    print(f"  architecture={image['Architecture']} virtualization={image['VirtualizationType']} "
          f"owner={image.get('OwnerId')} {EXPECTED_AMI_OWNER_TAG_KEY}={tags.get(EXPECTED_AMI_OWNER_TAG_KEY)} "
          f"{EXPECTED_AMI_TAG[0]}={tags.get(EXPECTED_AMI_TAG[0])}")
    print("sandbox AMI preflight passed")


def cmd_check_system_ami(_):
    """SYSTEM_AMI_ID is a public Ubuntu 24.04 EKS-optimized AMI, owned by a public account, not
    this caller's. Only existence, state and architecture are checked: this sample does not
    second-guess Canonical/AWS's own published image."""
    ami = setting("SYSTEM_AMI_ID")
    require(re.fullmatch(r"ami-[0-9a-f]{17}", ami), f"SYSTEM_AMI_ID '{ami}' is not a well-formed AMI id")
    images = aws("ec2", "describe-images", "--image-ids", ami).get("Images", [])
    require(images, f"AMI {ami} was not found or is not visible to this account/Region")
    image = images[0]
    require(image.get("State") == "available", f"AMI {ami} is not in the 'available' state")
    require(image.get("Architecture") == EXPECTED_AMI_ARCH,
            f"AMI {ami} has architecture '{image.get('Architecture')}', expected '{EXPECTED_AMI_ARCH}'")
    print(f"AMI {ami}: {image.get('Name', '')}")
    print("system AMI preflight passed")


# ---------------------------------------------------------------------------
# Launch templates
# ---------------------------------------------------------------------------

def tag_specs(group, *resource_types):
    tags = [{"Key": k, "Value": v} for k, v in demo_tags()]
    return [{"ResourceType": r, "Tags": tags + [{"Key": "Name", "Value": f"{setting('CLUSTER_NAME')}-{group}"}]}
            for r in resource_types]


BOOTSTRAP = "/etc/eks/bootstrap.sh"


def cluster_bootstrap_values(info):
    """(endpoint, CA, DNS address) the bootstrap line needs, from a describe-cluster `cluster`
    object, each checked: the endpoint a plain https host, the CA shell-safe and real base64, and
    the DNS address the service CIDR plus 10. Raises DemoError when the object is malformed or
    incomplete, so a caller can tell bad cluster data apart from a mismatch."""
    require(isinstance(info, dict), "the describe-cluster answer holds no cluster object")

    def field(parent, key):
        value = parent.get(key) if isinstance(parent, dict) else None
        return value if value is not None else ""

    endpoint = field(info, "endpoint")
    ca = field(field(info, "certificateAuthority"), "data")
    cidr = field(field(info, "kubernetesNetworkConfig"), "serviceIpv4Cidr")
    require(isinstance(endpoint, str) and re.fullmatch(r"https://[A-Za-z0-9.-]+", endpoint),
            f"cluster endpoint '{endpoint}' is not an https host")
    require(isinstance(ca, str) and re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", ca),
            "the cluster's certificate authority is not base64")
    # The charset check keeps the value shell-safe; decoding it proves it is real base64 (a
    # value of the wrong length passes the charset and would only fail later, at node join).
    try:
        ca_bytes = base64.b64decode(ca, validate=True)
    except ValueError:
        ca_bytes = b""
    require(ca_bytes, "the cluster's certificate authority is not valid base64")
    try:
        dns = str(ipaddress.ip_network(cidr)[10])
    except (ValueError, TypeError, IndexError):
        raise DemoError(f"the cluster's service CIDR '{cidr}' could not be read")
    return endpoint, ca, dns


def bootstrap_user_data(group, info):
    """The node's boot script: Canonical's EKS bootstrap, as the GA bundle's UBUNTU.md section 4
    ("Bake and join") has the launch template run it, with the cluster's API endpoint, CA and
    DNS address and this group's node labels. Both launch templates name an AMI, and Amazon
    EKS merges no user data into a launch template that names an AMI (Amazon EKS User Guide,
    "Customize managed nodes with launch templates"), so without this script no node joins.
    On the sandbox AMI, #10's build already pointed bootstrap.sh's kubelet at the sandbox CRI
    proxy; this script only runs it. Every value is checked against a plain charset first, so
    nothing in it can be read as shell syntax."""
    cluster = setting("CLUSTER_NAME")
    require(re.fullmatch(r"[A-Za-z][A-Za-z0-9-]{0,99}", cluster), f"cluster name '{cluster}' is not a plain name")
    endpoint, ca, dns = cluster_bootstrap_values(info)
    labels = node_labels(group)
    require(all(LABEL_KEY.match(k) and LABEL_VALUE.match(v) for k, v in labels.items()),
            f"a {group} node label is not a plain Kubernetes label")
    joined = ",".join(f"{k}={v}" for k, v in labels.items())
    return "\n".join([
        "#!/bin/bash",
        f"# {cluster}-{group}: rendered by scripts/cilium_ubuntu.py (launch_template_data).",
        "set -euo pipefail",
        f"{BOOTSTRAP} {cluster} \\",
        f"  --apiserver-endpoint {endpoint} \\",
        f"  --b64-cluster-ca {ca} \\",
        f"  --dns-cluster-ip {dns} \\",
        f"  --kubelet-extra-args '--node-labels={joined}'",
    ]) + "\n"


def user_data_parts(script):
    """(bootstrap.sh calls as token lists, every other non-empty logical line with its
    whitespace collapsed) of a user data script; a trailing backslash joins two lines."""
    calls, others = [], []
    for line in script.replace("\\\n", " ").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped == BOOTSTRAP or stripped.startswith(BOOTSTRAP + " "):
            try:
                calls.append(shlex.split(stripped))
            except ValueError:
                calls.append(stripped.split())
        else:
            others.append(" ".join(stripped.split()))
    return calls, others


def bootstrap_call(tokens):
    """(cluster name, {option: value}, problems) of one bootstrap.sh call's tokens."""
    rest = tokens[1:]
    cluster = rest.pop(0) if rest and not rest[0].startswith("--") else None
    options, problems = {}, []
    while rest:
        option = rest.pop(0)
        if not option.startswith("--"):
            problems.append(f"user data passes bootstrap.sh argument '{option}' that setup does not render")
            continue
        if option in options:
            problems.append(f"user data passes bootstrap.sh option {option} twice")
        options[option] = rest.pop(0) if rest else None
    return cluster, options, problems


def node_labels_arg(value):
    """{key: value} from a --kubelet-extra-args value that is exactly --node-labels=k=v,...,
    or None when it is anything else."""
    if not value or not value.startswith("--node-labels=") or any(c.isspace() for c in value):
        return None
    pairs = [p.split("=", 1) for p in value[len("--node-labels="):].split(",")]
    return dict(pairs) if all(len(p) == 2 for p in pairs) else None


def user_data_problems(got, want, role):
    """Every way the UserData script `got` differs from `want`, the script bootstrap_user_data
    renders for this cluster and role, as one diagnostic each; [] only when they are equal byte
    for byte. A difference the diagnostics below do not name is still reported."""
    if got == want:
        return []
    got_calls, got_other = user_data_parts(got)
    want_calls, want_other = user_data_parts(want)
    problems = []
    if len(got_calls) != 1:
        problems.append(f"user data does not run {BOOTSTRAP} once ({len(got_calls)} calls)")
    else:
        got_cluster, got_opts, problems = bootstrap_call(got_calls[0])
        want_cluster, want_opts, _ = bootstrap_call(want_calls[0])
        if got_cluster != want_cluster:
            problems.append(f"user data bootstraps cluster '{got_cluster}', expected '{want_cluster}'")
        problems += [f"user data lacks bootstrap.sh option {o}" for o in want_opts if o not in got_opts]
        problems += [f"user data passes bootstrap.sh option {o} that setup does not render"
                     for o in got_opts if o not in want_opts]
        for option, want_value in want_opts.items():
            got_value = got_opts.get(option, want_value)
            if got_value == want_value:
                continue
            if option == "--apiserver-endpoint":
                problems.append(f"user data --apiserver-endpoint is '{got_value}', expected the cluster's endpoint")
            elif option == "--b64-cluster-ca":
                problems.append("user data --b64-cluster-ca is not the cluster's certificate authority")
            elif option == "--kubelet-extra-args":
                got_labels, want_labels = node_labels_arg(got_value), node_labels_arg(want_value)
                if got_labels is None:
                    problems.append(f"user data --kubelet-extra-args is '{got_value}', expected only "
                                    "--node-labels=<the node's labels>")
                    continue
                if got_labels.get(NODEGROUP_LABEL) != want_labels.get(NODEGROUP_LABEL):
                    problems.append(f"user data node label {NODEGROUP_LABEL}={got_labels.get(NODEGROUP_LABEL)} "
                                    f"(expected {want_labels.get(NODEGROUP_LABEL)})")
                problems += [f"user data lacks node label {k}={v}" for k, v in want_labels.items()
                             if k != NODEGROUP_LABEL and got_labels.get(k) != v]
                problems += [f"user data has node label {k}={v} that setup does not render"
                             for k, v in got_labels.items() if k not in want_labels]
            else:
                problems.append(f"user data {option} is '{got_value}', expected '{want_value}'")
    extra = Counter(got_other) - Counter(want_other)
    missing = Counter(want_other) - Counter(got_other)
    problems += [f"user data has a line setup does not render: '{line}'" for line in extra.elements()]
    problems += [f"user data lacks the line '{line}'" for line in missing.elements()]
    return problems or ["user data differs from what setup renders only in whitespace or layout"]


def cmd_check_user_data(args):
    """Launch-template data JSON on stdin (what `launch-template <group>` writes to RUN_DIR).
    Exit 0 when its UserData is byte for byte the script bootstrap_user_data renders for this
    role and the live cluster (its name, endpoint, CA, DNS address and the node's labels, and
    nothing else); 1 when it differs, with one line per difference; 2 when the input holds no
    readable UserData or the cluster cannot be read (nothing was checked)."""
    text = sys.stdin.read()
    try:
        data = json.loads(text) if text.strip() else None
        script = base64.b64decode(data["UserData"], validate=True).decode()
    except (ValueError, TypeError, KeyError):
        print("no launch-template data with base64 UserData in the input: nothing was checked", file=sys.stderr)
        sys.exit(2)
    cluster = setting("CLUSTER_NAME")
    # Nothing is compared until the expected script is rendered, so every way that can fail is
    # exit 2: a failed read, a read whose cluster data is malformed or incomplete (no endpoint, a
    # CA that is not base64, no service CIDR), or labels that cannot be rendered. Exit 1 is kept
    # for a rendered expected script that the user data does not match.
    try:
        info = cluster_info()
        cluster_bootstrap_values(info)
    except DemoError as e:
        print(f"could not read cluster {cluster}: nothing was checked ({e})", file=sys.stderr)
        sys.exit(2)
    try:
        want = bootstrap_user_data(args.role, info)
    except DemoError as e:
        print(f"could not render the expected {args.role} user data: nothing was checked ({e})", file=sys.stderr)
        sys.exit(2)
    calls, _ = user_data_parts(script)
    labels = node_labels_arg(bootstrap_call(calls[0])[1].get("--kubelet-extra-args")) if len(calls) == 1 else None
    verdict = f" (--node-labels {node_label_verdict(labels, args.role)[1]})" if labels is not None else ""
    problems = user_data_problems(script, want, args.role)
    if not problems:
        print(f"{args.role} user data is byte-for-byte what setup renders for cluster {cluster}{verdict}")
        sys.exit(0)
    for problem in problems:
        print(problem)
    print(f"{args.role} user data differs from what setup renders for cluster {cluster}{verdict}")
    sys.exit(1)


def launch_template_data(group):
    """The launch template each node group uses. Both are created by this sample, so both
    carry the sample's tags from the moment they exist, and so do the instances, volumes and
    network interfaces launched from them. Both carry the bootstrap user data that joins the
    node to this cluster with its labels (bootstrap_user_data)."""
    user_data = bootstrap_user_data(group, cluster_info())
    common = {
        # Hop limit 1: every IMDS consumer on these nodes is host-network (kubelet, the
        # Cilium agent), so a pod, including a sandbox guest, cannot reach the node's
        # credentials through IMDS.
        "MetadataOptions": {"HttpTokens": "required", "HttpPutResponseHopLimit": 1},
        "TagSpecifications": tag_specs(group, "instance", "volume", "network-interface"),
        "UserData": base64.b64encode(user_data.encode()).decode(),
    }
    if group == SYSTEM_GROUP:
        return {
            **common,
            "ImageId": setting("SYSTEM_AMI_ID"),
            "InstanceType": setting("SYSTEM_INSTANCE_TYPE"),
            "BlockDeviceMappings": [{"DeviceName": "/dev/sda1", "Ebs": {
                "VolumeSize": 40, "VolumeType": "gp3", "DeleteOnTermination": True}}],
        }
    require(group == SANDBOX_GROUP, f"unknown node group {group}")
    ami = setting("SANDBOX_AMI_ID")
    images = aws("ec2", "describe-images", "--image-ids", ami).get("Images", [])
    require(images and images[0].get("State") == "available", f"AMI {ami} is not available")
    image = images[0]
    root = next(m for m in image["BlockDeviceMappings"] if m["DeviceName"] == image["RootDeviceName"])
    return {
        **common,
        "ImageId": ami,
        "InstanceType": setting("SANDBOX_INSTANCE_TYPE"),
        # EKS Pod Isolation runs each sandboxed pod in a guest microVM through the Nitro
        # Enclaves device, so the instance must have Nitro Enclaves turned on, and
        # SANDBOX_INSTANCE_TYPE must be a type that supports it. The runtime, the guest image
        # and the kubelet wiring are already on the #10 AMI.
        "EnclaveOptions": {"Enabled": True},
        "BlockDeviceMappings": [{"DeviceName": image["RootDeviceName"], "Ebs": {
            "VolumeSize": root["Ebs"]["VolumeSize"], "VolumeType": "gp3", "DeleteOnTermination": True}}],
    }


def template_mismatch(have, want):
    """Fields of an existing template (version 1) that differ from what setup would create
    now. Every field setup sets is compared, and a field the existing template sets that
    setup does not is a difference too."""
    differs = [k for k in sorted(set(have) - set(want))]
    for key, value in want.items():
        got = have.get(key)
        if isinstance(value, dict) and isinstance(got, dict):
            if any(got.get(k) != v for k, v in value.items()):
                differs.append(key)
        elif got != value:
            differs.append(key)
    return sorted(differs)


def cmd_launch_template(args):
    OUT.mkdir(mode=0o700, parents=True, exist_ok=True)
    name = f"{setting('CLUSTER_NAME')}-{args.group}"
    data = launch_template_data(args.group)
    (OUT / f"{args.group}-launch-template.json").write_text(json.dumps(data, indent=2) + "\n")
    found = aws("ec2", "describe-launch-templates", "--filters",
                f"Name=launch-template-name,Values={name}").get("LaunchTemplates", [])
    if found:
        lt = found[0]
        require(tag_map(lt.get("Tags")).get(DEMO_TAG[0]) == DEMO_TAG[1],
                f"launch template {name} exists and is not this sample's")
        have = aws("ec2", "describe-launch-template-versions", "--launch-template-id",
                   lt["LaunchTemplateId"], "--versions", "1")["LaunchTemplateVersions"][0]["LaunchTemplateData"]
        differs = template_mismatch(have, data)
        require(not differs, f"launch template {name} differs from this configuration ({', '.join(differs)}); "
                "it was made for an earlier cluster or settings. Run ./clean.sh, then ./setup.sh")
        print(lt["LaunchTemplateId"])
        return
    lt_tags = [{"ResourceType": "launch-template",
                "Tags": [{"Key": k, "Value": v} for k, v in demo_tags()]}]
    created = aws("ec2", "create-launch-template", "--launch-template-name", name,
                  "--launch-template-data", json.dumps(data), "--tag-specifications", json.dumps(lt_tags))
    print(created["LaunchTemplate"]["LaunchTemplateId"])


# ---------------------------------------------------------------------------
# Cilium DaemonSet / BTF preflight, run before and after the sandbox node joins
# ---------------------------------------------------------------------------

def compatible_daemonset(ds, node_labels, taint_key):
    """Would this DaemonSet's pod template schedule on a node with these labels and this
    taint key (NoSchedule, no other effect used by this sample)? Checks nodeSelector,
    requiredDuringSchedulingIgnoredDuringExecution node affinity terms, and that some
    toleration matches the taint key with operator Exists or Equal/"true"."""
    spec = ds["spec"]["template"]["spec"]
    selector = spec.get("nodeSelector", {})
    if not all(node_labels.get(k) == v for k, v in selector.items()):
        return False
    affinity = spec.get("affinity", {}).get("nodeAffinity", {})
    terms = affinity.get("requiredDuringSchedulingIgnoredDuringExecution", {}).get("nodeSelectorTerms", [])
    if terms:
        def term_matches(term):
            for expr in term.get("matchExpressions", []):
                key, op, values = expr["key"], expr["operator"], expr.get("values", [])
                have = node_labels.get(key)
                if op == "In" and have not in values:
                    return False
                if op == "NotIn" and have in values:
                    return False
                if op == "Exists" and have is None:
                    return False
                if op == "DoesNotExist" and have is not None:
                    return False
            return True
        if not any(term_matches(t) for t in terms):
            return False
    tolerations = spec.get("tolerations", [])
    tolerated = any(
        t.get("key") in (None, taint_key) and t.get("operator") in (None, "Exists", "Equal")
        for t in tolerations
    )
    return tolerated


def cmd_preflight_daemonset(_):
    """Before the sandbox node exists: would the Cilium agent DaemonSet schedule on it?"""
    ds = kube_json("-n", "kube-system", "get", "daemonset", "cilium")
    require(compatible_daemonset(ds, {**KUBELET_LABELS, **SANDBOX_LABELS}, SANDBOX_TAINT_KEY),
            "the cilium DaemonSet would not schedule on the sandbox node (selector or toleration)")
    print("cilium DaemonSet tolerates the sandbox node's taint and selects its labels")


BTF_PATH = "/sys/kernel/btf/vmlinux"


def cmd_check_btf(args):
    """Stage 5's gate: both Ubuntu node kernels must expose valid BTF (a non-empty
    /sys/kernel/btf/vmlinux) before their Cilium agents are treated as ready. Run once per
    node group, against a Cilium agent pod already scheduled there, so the check reads the
    real running kernel rather than inferring BTF from a kernel config file."""
    nodegroup = args.nodegroup
    pods = kube_json("-n", "kube-system", "get", "pods", "-l", "k8s-app=cilium",
                      "--field-selector", f"spec.nodeName={args.node}").get("items", [])
    require(pods, f"no cilium agent pod is scheduled on node {args.node} (nodegroup {nodegroup})")
    pod_name = pods[0]["metadata"]["name"]
    # The node's own BTF, the GA bundle's check (README, "Cilium with kube-proxy replacement":
    # "Check the node's BTF, not Cilium's status"). On a node without BTF the agent still reads
    # Ready and `cilium-dbg status --brief` says OK, so the agent's status cannot be the gate;
    # the agent container shares the node's kernel, so this reads the node's /sys/kernel/btf.
    out = run(["kubectl", "-n", "kube-system", "exec", pod_name, "-c", "cilium-agent",
               "--", "sh", "-c", f'test -s {BTF_PATH} && echo PRESENT || echo MISSING'])
    require(out.strip() == "PRESENT",
            f"node {args.node} (nodegroup {nodegroup}) has no BTF at {BTF_PATH} (read: {out.strip()[:80]!r}); "
            "its Cilium agent cannot load the kube-proxy-replacement datapath, even though the agent may "
            "still report Ready. This node's kernel was not built with CONFIG_DEBUG_INFO_BTF=y; see "
            "../ubuntu-ami for the BTF-enabled build this sample depends on.")
    print(f"BTF present on node {args.node} (nodegroup {nodegroup})")


def cmd_runtimeclass(_):
    """Print the isolated-sandbox RuntimeClass the GA bundle's UBUNTU.md section 5 gives (the
    isolated-sandbox handler, the per-pod overhead, and a nodeSelector on the two labels only the
    sandbox node carries) plus the sample's ownership label. setup.sh creates it when the
    cluster has none."""
    print(json.dumps(RUNTIMECLASS))


# Fields the API server sets on every object; they say nothing about what the object does.
SERVER_METADATA = ("uid", "resourceVersion", "generation", "creationTimestamp", "managedFields", "selfLink")


def object_diff(want, have, path=""):
    """One line per field where `have` differs from `want`, walking nested mappings."""
    wrong = []
    for key in sorted(set(want) | set(have)):
        where = f"{path}.{key}" if path else f"field {key}"
        if key not in have and isinstance(want[key], dict):
            wrong += object_diff(want[key], {}, f"{path}.{key}" if path else key)
        elif key not in have:
            wrong.append(f"{where} is missing (expected {want[key]!r})")
        elif key not in want:
            wrong.append(f"{where} {have[key]!r} (the sample's RuntimeClass sets none)")
        elif isinstance(want[key], dict) and isinstance(have[key], dict):
            wrong += object_diff(want[key], have[key], f"{path}.{key}" if path else key)
        elif want[key] != have[key]:
            wrong.append(f"{where} {have[key]!r}, expected {want[key]!r}")
    return wrong


def runtimeclass_ownership(rc):
    """[] when the RuntimeClass carries the sample's ownership label, else why not."""
    labels = (rc.get("metadata") or {}).get("labels") or {}
    key, value = OWNER_LABEL
    if key not in labels:
        return [f"RuntimeClass {RUNTIMECLASS_NAME} is not marked as this sample's: it has no {key} label"]
    if labels[key] != value:
        return [f"RuntimeClass {RUNTIMECLASS_NAME} is marked {key}={labels[key]}, not {value}"]
    return []


def runtimeclass_mismatches(rc):
    """Every way a live RuntimeClass differs from RUNTIMECLASS: the whole object (handler,
    overhead, scheduling with its nodeSelector and any tolerations, and metadata such as
    annotations, ownerReferences or finalizers) is compared, after removing only the fields the
    API server sets and the ownership label, which runtimeclass_ownership checks."""
    want, have = copy.deepcopy(RUNTIMECLASS), copy.deepcopy(rc)
    have_meta = have.setdefault("metadata", {})
    for field in SERVER_METADATA:
        have_meta.pop(field, None)
    for meta in (want["metadata"], have_meta):
        labels = meta.pop("labels", None) or {}
        labels.pop(OWNER_LABEL[0], None)
        if labels:
            meta["labels"] = labels
    return object_diff(want, have)


def cmd_check_runtimeclass(_):
    """`kubectl get runtimeclass isolated-sandbox -o json` on stdin. Exit 0 when it carries the
    sample's ownership label and is otherwise exactly the GA RuntimeClass, 1 when it is not the
    sample's or differs, 2 when the input is not a RuntimeClass named isolated-sandbox (nothing
    was checked)."""
    text = sys.stdin.read()
    try:
        rc = json.loads(text) if text.strip() else None
    except ValueError:
        rc = None
    if not isinstance(rc, dict) or rc.get("kind") != "RuntimeClass" \
            or (rc.get("metadata") or {}).get("name") != RUNTIMECLASS_NAME:
        print(f"no RuntimeClass {RUNTIMECLASS_NAME} in the input: nothing was checked", file=sys.stderr)
        sys.exit(2)
    wrong = runtimeclass_ownership(rc) + runtimeclass_mismatches(rc)
    if wrong:
        print(f"RuntimeClass {RUNTIMECLASS_NAME} is not this sample's or differs from the GA bundle's: "
              f"{'; '.join(wrong)}")
        sys.exit(1)
    print(f"RuntimeClass {RUNTIMECLASS_NAME}: marked {OWNER_LABEL[0]}={OWNER_LABEL[1]}, handler {rc['handler']}, nodeSelector "
          f"{','.join(f'{k}={v}' for k, v in sorted(RUNTIMECLASS_NODE_SELECTOR.items()))}, overhead "
          f"{','.join(f'{k}={v}' for k, v in sorted(RUNTIMECLASS['overhead']['podFixed'].items()))}")


def node_label_verdict(labels, role):
    """(ok, summary) for a node's labels. role sandbox: both RuntimeClass labels present with
    value "true". role system: neither present (with any value)."""
    if role == SANDBOX_GROUP:
        missing = [f"{k}={v}" for k, v in RUNTIMECLASS_NODE_SELECTOR.items() if labels.get(k) != v]
        return (not missing), ("carries " + ", ".join(f"{k}={v}" for k, v in RUNTIMECLASS_NODE_SELECTOR.items())
                               if not missing else "lacks " + ", ".join(missing))
    stray = sorted(k for k in RUNTIMECLASS_NODE_SELECTOR if k in labels)
    return (not stray), ("carries neither RuntimeClass label" if not stray else "carries " + ", ".join(stray))


def cmd_check_node_labels(args):
    """`kubectl get node <name> -o json` on stdin. Exit 0 when the node's labels fit its role
    (a sandbox node carries both RuntimeClass labels, the system node neither), 1 when not, 2
    when the input is not a Node (nothing was checked)."""
    text = sys.stdin.read()
    try:
        node = json.loads(text) if text.strip() else None
    except ValueError:
        node = None
    labels = (node or {}).get("metadata", {}).get("labels") if isinstance(node, dict) else None
    if not isinstance(node, dict) or node.get("kind") != "Node" or not isinstance(labels, dict):
        print("no Node object with labels in the input: nothing was checked", file=sys.stderr)
        sys.exit(2)
    ok, summary = node_label_verdict(labels, args.role)
    print(f"{args.role} node {node['metadata'].get('name', '?')} {summary}")
    sys.exit(0 if ok else 1)


# --- The workloads: AppArmor Unconfined on sandbox pods only ----------------
# On an Ubuntu host every isolated-sandbox pod needs appArmorProfile type Unconfined, or kubelet
# requests RuntimeDefault, the shim forwards it into the guest and runc there fails with
# "apparmor failed to apply profile" (GA bundle UBUNTU.md section 5; an open item the bundle
# tracks with the service team). The microVM is that pod's boundary. An ordinary pod runs on the
# host kernel and keeps its default profile, so Unconfined is refused on every ordinary pod.
# The sandbox pod may set AppArmor in one place only, the pod-level field: no container, init
# container, ephemeral container or legacy annotation may set it too. That strict rule holds on
# pods read back from the API server only on Kubernetes 1.34 or later (this sample pins EKS
# 1.36): from 1.34 the API server no longer copies the pod-level field into the legacy
# per-container annotation, as 1.30 to 1.33 did.
APPARMOR_LEGACY_ANNOTATION = "container.apparmor.security.beta.kubernetes.io/"


def apparmor_types(pod):
    """Every AppArmor profile type a Pod sets: pod level, each container (init and ephemeral
    included), and the legacy per-container annotation ("unconfined" read as Unconfined)."""
    spec = pod.get("spec") or {}
    found = []
    pod_type = ((spec.get("securityContext") or {}).get("appArmorProfile") or {}).get("type")
    if pod_type is not None:
        found.append(("pod", pod_type))
    for field in ("initContainers", "containers", "ephemeralContainers"):
        for c in spec.get(field) or []:
            t = ((c.get("securityContext") or {}).get("appArmorProfile") or {}).get("type")
            if t is not None:
                found.append((f"container {c.get('name')}", t))
    for key, value in ((pod.get("metadata") or {}).get("annotations") or {}).items():
        if key.startswith(APPARMOR_LEGACY_ANNOTATION):
            found.append((f"annotation {key}", "Unconfined" if str(value) == "unconfined" else str(value)))
    return found


def workload_apparmor_problems(docs):
    """(pods, isolated-sandbox pods, [problem]) for a list of manifest documents: an
    isolated-sandbox pod whose only AppArmor setting is not the pod-level Unconfined, or an
    ordinary pod with Unconfined anywhere."""
    problems, pods, sandbox_pods = [], 0, 0
    for d in docs:
        if not isinstance(d, dict) or d.get("kind") != "Pod":
            continue
        pods += 1
        name = (d.get("metadata") or {}).get("name", "?")
        types = apparmor_types(d)
        if (d.get("spec") or {}).get("runtimeClassName") == RUNTIMECLASS_NAME:
            sandbox_pods += 1
            if ("pod", "Unconfined") not in types:
                problems.append(f"sandbox pod {name} lacks securityContext.appArmorProfile.type: Unconfined")
            problems += [f"sandbox pod {name} sets {where} AppArmor {t}" for where, t in types if where != "pod"]
        else:
            problems += [f"ordinary pod {name} sets {where} AppArmor Unconfined" for where, t in types
                         if t == "Unconfined"]
    return pods, sandbox_pods, problems


def cmd_check_workloads(args):
    """AppArmor check of deploy/workloads.yaml, of another --file, or of --file - (stdin, such as
    `kubectl get pods -o json`, a List): Unconfined set once, at pod level, on every
    isolated-sandbox pod, and on no ordinary pod. Exit 0 / 1; 2 when the input holds no Pod or
    no isolated-sandbox pod (nothing was checked)."""
    import yaml
    if args.file == "-":
        name, text = "stdin", sys.stdin.read()
    else:
        path = Path(args.file) if args.file else DEMO / "deploy" / "workloads.yaml"
        name, text = path.name, path.read_text()
    docs = []
    for d in yaml.safe_load_all(text):
        docs += (d.get("items") or []) if isinstance(d, dict) and d.get("kind") == "List" else [d]
    pods, sandbox_pods, problems = workload_apparmor_problems(docs)
    if not pods:
        print(f"{name} holds no Pod: nothing was checked", file=sys.stderr)
        sys.exit(2)
    if not sandbox_pods:
        print(f"no isolated-sandbox pod in {name}: nothing was checked", file=sys.stderr)
        sys.exit(2)
    for p in problems:
        print(p)
    print(f"{pods} pods in {name}: {len(problems)} AppArmor problem(s)")
    sys.exit(1 if problems else 0)


# --- cilium-values.yaml: the values the page's claims rest on ---------------
CILIUM_VALUES_EXPECTED = {
    ("kubeProxyReplacement",): True,
    ("socketLB", "hostNamespaceOnly"): True,
    ("eni", "enabled"): True,
    ("ipam", "mode"): "eni",
    ("routingMode",): "native",
}


def cilium_values_problems(values):
    problems = []
    for path, want in CILIUM_VALUES_EXPECTED.items():
        node = values
        for key in path:
            node = node.get(key) if isinstance(node, dict) else None
        if node != want or type(node) is not type(want):
            problems.append(f"{'.'.join(path)} is {node!r}, expected {want!r}")
    return problems


def cmd_check_cilium_values(args):
    """Static check of cilium-values.yaml (or --file): kube-proxy replacement on, the socket
    load balancer limited to the host namespace (the setting a Nitro pod needs), ENI IPAM and
    native routing. Exit 0 / 1."""
    import yaml
    path = Path(args.file) if args.file else DEMO / "cilium-values.yaml"
    values = yaml.safe_load(path.read_text())
    require(isinstance(values, dict), f"{path.name} is not a YAML mapping")
    problems = cilium_values_problems(values)
    for p in problems:
        print(p)
    print(f"{path.name}: {len(problems)} problem(s) with kubeProxyReplacement, socketLB.hostNamespaceOnly, "
          "eni.enabled, ipam.mode, routingMode")
    sys.exit(1 if problems else 0)


def kernel_release_matches(got, want):
    """True when a `uname -r` value is the pinned release, or the pinned release followed by a
    '-' or '+' build suffix (6.18.54 matches 6.18.54 and 6.18.54-1, not 6.18.540)."""
    return bool(got) and (got == want or (got.startswith(want) and got[len(want)] in "-+"))


def cmd_kernel_release(args):
    got = args.got.strip()
    if not got:
        print(f"kernel release unreadable (empty), expected {args.want}")
        sys.exit(1)
    ok = kernel_release_matches(got, args.want)
    print(f"kernel release {got} {'is' if ok else 'is not'} the pinned {args.want}")
    sys.exit(0 if ok else 1)


# ===========================================================================
# test.sh / clean.sh side: proofs read off the running Cilium agents, and the
# AWS tag accounting the clean up deletes by.
#
# Each agent-output parser takes text on stdin and answers with an exit code: 0 the property
# holds, 1 it does not, 2 the input was not a real read (empty/failed/truncated) so nothing
# was checked. A read that cannot be told apart from a good answer is never taken as one.
# ===========================================================================

def cluster_info():
    answer = aws("eks", "describe-cluster", "--name", setting("CLUSTER_NAME"))
    info = answer.get("cluster") if isinstance(answer, dict) else None
    require(isinstance(info, dict), f"describe-cluster for {setting('CLUSTER_NAME')} returned no cluster object")
    return info


def require_demo_cluster_info(info):
    require(tag_map(info.get("tags")).get(DEMO_TAG[0]) == DEMO_TAG[1],
            f"cluster {info['name']} does not carry {DEMO_TAG[0]}={DEMO_TAG[1]}; it is not this sample's")


# --- The agent log: its eBPF datapath loaded, with the kernel's BTF ---------
# On a node whose kernel has no BTF, the GA bundle (README, "Cilium with kube-proxy
# replacement") has the agent report Ready while its log repeats "Failed to initialize datapath"
# with "no BTF found". The agent logs in one of two formats, and this parser reads both with
# one rule:
#   text  a line starting with the key=value prefix `time=<t> level=<l> `; the message and any
#         other attributes (source=, module=, error=) follow in any order;
#   JSON  one JSON object per line with a string "level" (and usually "msg").
# The level may be upper or lower case. In either format a line is a failure when its level is
# warn or worse AND its message starts with "Failed to initialize datapath" or the line carries
# "no BTF found" (in the message or any attribute, such as error=). An info line that only
# quotes either string is not a failure. A line in NEITHER format that carries either string
# cannot be judged: the parser cannot read its level, so it reports that it checked nothing
# (exit 2) rather than reading the log as clean or as failed. A line in neither format that
# carries neither string (a banner, a klog line) is counted and otherwise ignored, and a comment
# line (starting with #) is not evidence at all. A log with no line in either format is not a
# clean log but one this parser cannot read, so it checks nothing.
AGENT_LINE = re.compile(r'^time=\S+ level=(?P<level>[A-Za-z]+) ')
FAILURE_LEVELS = {"warn", "warning", "error", "fatal", "panic"}
DATAPATH_FAILURE_TEXT = "Failed to initialize datapath"
DATAPATH_FAILURE = re.compile(r' msg="?Failed to initialize datapath')
NO_BTF = "no BTF found"


def agent_log_line(line):
    """('text' or 'json', level, whether the message starts with the datapath failure) for a
    line in one of the agent's two log formats, or None for any other line."""
    match = AGENT_LINE.match(line)
    if match:
        return "text", match.group("level"), bool(DATAPATH_FAILURE.search(line))
    if line.lstrip().startswith("{"):
        try:
            obj = json.loads(line)
        except ValueError:
            return None
        level = obj.get("level") if isinstance(obj, dict) else None
        if isinstance(level, str) and level.isalpha():
            msg = obj.get("msg")
            return "json", level, isinstance(msg, str) and msg.startswith(DATAPATH_FAILURE_TEXT)
    return None


def datapath_failures(log_text):
    """(lines read, agent log lines, other lines, [(failure line, format)], [lines in neither
    format that carry a failure string]) in a cilium-agent log. Empty and comment lines are
    neither agent nor other lines."""
    lines = log_text.splitlines()
    agent, other, failures, undecided = 0, 0, [], []
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parsed = agent_log_line(line)
        if parsed:
            fmt, level, starts_with_failure = parsed
            agent += 1
            if level.lower() in FAILURE_LEVELS and (starts_with_failure or NO_BTF in line):
                failures.append((line, fmt))
        else:
            other += 1
            if NO_BTF in line or DATAPATH_FAILURE_TEXT in line:
                undecided.append(line)
    return len(lines), agent, other, failures, undecided


def cmd_datapath_failures(_):
    """A cilium-agent log on stdin. Exit 0 when it holds agent log lines and no failure; 1 when a
    text or JSON agent line is a failure (printed); 2 when nothing was checked: an empty log, a
    log with no agent line, or a line in neither format that carries a failure string."""
    read, agent, other, failures, undecided = datapath_failures(sys.stdin.read())
    if not read:
        print("empty agent log: nothing was checked", file=sys.stderr)
        sys.exit(2)
    summary = (f"{len(failures)} '{DATAPATH_FAILURE_TEXT}' / '{NO_BTF}' lines in {agent} agent log lines "
               f"and {other} other line(s)")
    if failures:
        for line, fmt in failures[:3]:
            print(("(json) " if fmt == "json" else "") + line[:300])
        print(summary)
        sys.exit(1)
    if undecided:
        for line in undecided[:3]:
            print(f"(in neither agent log format) {line[:300]}", file=sys.stderr)
        print(f"{len(undecided)} line(s) in neither agent log format carry '{DATAPATH_FAILURE_TEXT}' or "
              f"'{NO_BTF}', so their level cannot be read: nothing was checked", file=sys.stderr)
        sys.exit(2)
    if not agent:
        print(f"none of {read} lines is an agent log line (key=value text 'time=... level=... ' or JSON "
              "with a level): nothing was checked", file=sys.stderr)
        sys.exit(2)
    print(summary)
    sys.exit(0)


# --- `cilium-dbg status --verbose`: kube-proxy replacement, socket LB host-only ---
# The cilium-config ConfigMap is no substitute: it says bpf-lb-sock "false" under both
# socket-LB settings because kubeProxyReplacement=true turns the socket LB on regardless. Only
# the agent's own coverage line tells "host namespace only" apart from "everywhere".
KPR_EXPECTED = {"Status": "True", "Socket LB": "Enabled", "Socket LB Coverage": "Hostns-only"}


def kpr_details(status_text):
    """(the KubeProxyReplacement line's value, {detail: value}) from `status --verbose`."""
    top, details, inside = None, {}, False
    for line in status_text.splitlines():
        match = re.match(r"^KubeProxyReplacement:\s+(\S+)", line)
        if match:
            top = match.group(1)
            continue
        if line.rstrip() == "KubeProxyReplacement Details:":
            inside = True
            continue
        if inside:
            match = re.match(r"^  ([A-Za-z][A-Za-z0-9 /-]*?):\s+(\S.*?)\s*$", line)
            if match:
                details.setdefault(match.group(1), match.group(2))
            elif not line.startswith("  "):
                inside = False
    return top, details


def kpr_mismatches(top, details):
    wrong = [] if top == "True" else [f"KubeProxyReplacement: {top}"]
    return wrong + [f"{key}: {details.get(key, '(missing)')}" for key, value in KPR_EXPECTED.items()
                    if details.get(key) != value]


def cmd_kpr_status(_):
    top, details = kpr_details(sys.stdin.read())
    if top is None:
        print("no KubeProxyReplacement line: nothing was checked", file=sys.stderr)
        sys.exit(2)
    wrong = kpr_mismatches(top, details)
    if wrong:
        print("; ".join(wrong))
        sys.exit(1)
    print(f"KubeProxyReplacement {top}, Socket LB {details['Socket LB']}, "
          f"coverage {details['Socket LB Coverage']}")


# --- The node's iptables: no kube-proxy chain on any backend ----------------
KUBELET_CHAINS = {"KUBE-KUBELET-CANARY", "KUBE-FIREWALL", "KUBE-IPTABLES-HINT"}
KUBE_CHAIN = re.compile(r"^:(KUBE-\S+) ")
CILIUM_CHAIN = re.compile(r"^:CILIUM_[A-Za-z_]+ ")
SAVE_TOOLS = ("iptables-nft-save", "ip6tables-nft-save", "iptables-legacy-save", "ip6tables-legacy-save")
SECTION = re.compile(r"^#### (\S+)$")
SECTION_END = re.compile(r"^#### rc=(\d+)$")
NFT_TABLES = {"filter", "nat", "mangle"}


def kube_proxy_chains(save_text):
    """(tables read, whether Cilium's own chains are there, kube-proxy chains)."""
    lines = save_text.splitlines()
    tables = [line[1:] for line in lines if re.fullmatch(r"\*[a-z]+", line)]
    cilium = any(CILIUM_CHAIN.match(line) for line in lines)
    chains = [m.group(1) for m in map(KUBE_CHAIN.match, lines) if m and m.group(1) not in KUBELET_CHAINS]
    return tables, cilium, chains


def save_sections(text):
    """{tool: (exit code, output)}, or None when the markers are not one clean closed section
    per tool (a tool listed twice, a section opened inside another, an rc with no open
    section, or a section left open)."""
    sections, tool, body = {}, None, []
    for line in text.splitlines():
        start, end = SECTION.match(line), SECTION_END.match(line)
        if end:
            if tool is None:
                return None
            sections[tool] = (int(end.group(1)), "\n".join(body))
            tool, body = None, []
        elif start:
            if tool is not None or start.group(1) in sections:
                return None
            tool, body = start.group(1), []
        elif tool:
            body.append(line)
    return None if tool is not None else sections


def tables_closed(save_text):
    """True when every *table is followed by its COMMIT before the next table or the end."""
    open_table = False
    for line in save_text.splitlines():
        if re.fullmatch(r"\*[a-z]+", line):
            if open_table:
                return False
            open_table = True
        elif line == "COMMIT":
            if not open_table:
                return False
            open_table = False
    return not open_table


def rules_verdict(text):
    """(verdict 0/1/2, summary) for the marked-up output of every save tool. A truncated or
    failed save would find no kube-proxy chains for the wrong reason, so each read must be
    complete: every table closed by its COMMIT, the nft reads holding the tables kubelet
    always creates, and the IPv4 nft read holding Cilium's own chains."""
    sections = save_sections(text)
    if sections is None:
        return 2, "the save tools' output markers are malformed: nothing was checked"
    missing = [t for t in SAVE_TOOLS if t not in sections or sections[t][0] != 0]
    if missing:
        return 2, f"no complete read from {' '.join(missing)}: nothing was checked"
    found, parts = [], []
    for tool in SAVE_TOOLS:
        output = sections[tool][1]
        tables, cilium, chains = kube_proxy_chains(output)
        commits = sum(1 for line in output.splitlines() if line == "COMMIT")
        incomplete = not tables_closed(output) \
            or ("-nft-" in tool and not NFT_TABLES <= set(tables)) \
            or (tool == "iptables-nft-save" and not cilium)
        if incomplete:
            return 2, (f"{tool} is not a complete read of the node's tables (tables: {' '.join(tables) or 'none'}, "
                       f"{commits} COMMIT, Cilium chains: {'yes' if cilium else 'no'}): nothing was checked")
        found += [f"{tool}: {chain}" for chain in chains]
        parts.append(f"{tool[:-len('-save')]} ({' '.join(tables) or 'no tables'})")
    return (1 if found else 0), "\n".join(found[:5] + [f"{len(found)} kube-proxy chains in " + ", ".join(parts)])


def cmd_kube_proxy_rules(_):
    verdict, summary = rules_verdict(sys.stdin.read())
    print(summary, file=sys.stderr if verdict == 2 else sys.stdout)
    sys.exit(verdict)


# --- `cilium-dbg monitor --type l7`: the Envoy proxy's own verdict ----------
L7_LINE = re.compile(
    r'^-> (?P<direction>Request|Response) (?P<proto>\S+) (?:from|to) (?P<endpoint>\d+) .*?'
    r'\bverdict (?P<verdict>\S+) (?P<method>\S+) (?P<url>\S+) => (?P<code>\d+)\s*$'
)


def l7_requests(monitor_text):
    """[{direction, verdict, method, url, code, endpoint}] for every L7 line in a capture."""
    requests = []
    for line in monitor_text.splitlines():
        match = L7_LINE.match(line)
        if match:
            requests.append({k: match.group(k) for k in
                             ("direction", "verdict", "method", "url", "code", "endpoint")})
    return requests


def l7_verdict(requests, endpoint, path_suffix):
    """(request_verdict, response_code) for the given client endpoint's most recent exchange
    whose url ends with path_suffix, or (None, None). BOTH rows matter and must be the SAME
    exchange: the Request row carries Cilium's verdict (Forwarded/Denied), the Response that
    FOLLOWS it carries the HTTP status. A `=> 403` alone is not a policy deny (an app can
    answer 403 and the proxy forwards it). Paired by ORDER, not global latest of each."""
    indexed = [(i, r) for i, r in enumerate(requests)
               if r["endpoint"] == endpoint and r["url"].endswith(path_suffix)]
    reqs = [(i, r) for i, r in indexed if r["direction"] == "Request"]
    if not reqs:
        return None, None
    req_index, req = reqs[-1]
    resp = next((r for i, r in indexed if i > req_index and r["direction"] == "Response"), None)
    return req["verdict"], (resp["code"] if resp else None)


def cmd_l7_verdict(args):
    """Judge ONE endpoint's request to a path from a monitor capture on stdin. Exit 0 when the
    observed (request verdict, response code) matches <want-verdict> <want-code>, 1 when
    observed but differs, 2 when no such exchange was captured."""
    requests = l7_requests(sys.stdin.read())
    verdict, code = l7_verdict(requests, args.endpoint, args.path_suffix)
    if verdict is None and code is None:
        print(f"no L7 exchange for endpoint {args.endpoint} to a url ending {args.path_suffix}: nothing was checked",
              file=sys.stderr)
        sys.exit(2)
    ok = (verdict == args.want_verdict and code == args.want_code)
    print(f"endpoint {args.endpoint} {args.path_suffix}: request verdict={verdict}, response code={code} "
          f"(wanted {args.want_verdict}/{args.want_code})")
    sys.exit(0 if ok else 1)


def cmd_l7_requests(_):
    requests = l7_requests(sys.stdin.read())
    if not requests:
        print("no L7 request/response lines in the monitor capture: nothing was checked", file=sys.stderr)
        sys.exit(2)
    for r in requests:
        print(f"ep{r['endpoint']} {r['direction']} {r['method']} {r['url']} verdict={r['verdict']} => {r['code']}")
    sys.exit(0)


# --- `cilium-dbg fqdn cache list`: what the DNS proxy has actually seen ------
FQDN_CACHE_ROW = re.compile(r'^(?P<endpoint>\d+)\s+(?P<source>\S+)\s+(?P<fqdn>\S+)\s+(?P<ttl>\d+)\s+'
                            r'(?P<expiry>\S+)\s+(?P<ips>[^,\s]+(?:,[^,\s]+)*)\s*$')


def fqdn_cache_rows(cache_text):
    rows = []
    for line in cache_text.splitlines():
        match = FQDN_CACHE_ROW.match(line)
        if match:
            rows.append({"endpoint": match.group("endpoint"), "source": match.group("source"),
                         "fqdn": match.group("fqdn").rstrip("."), "ips": match.group("ips").split(",")})
    return rows


def cmd_fqdn_cache_has(args):
    """Exit 0 when the fqdn cache (stdin) has a LOOKUP entry for args.endpoint whose fqdn
    equals args.fqdn, 1 when read but no such entry, 2 when no data rows at all. Only a
    `lookup` row proves the DNS proxy observed the resolution; a `connection` row alone does
    not, so it must not satisfy an assertion claiming a lookup."""
    rows = fqdn_cache_rows(sys.stdin.read())
    if not rows:
        print("fqdn cache list returned no rows: nothing was checked", file=sys.stderr)
        sys.exit(2)
    want = args.fqdn.rstrip(".")
    hit = [r for r in rows
           if r["endpoint"] == args.endpoint and r["fqdn"] == want and r["source"] == "lookup"]
    if hit:
        print(f"endpoint {args.endpoint}: lookup {args.fqdn} -> {','.join(hit[-1]['ips'])}")
        sys.exit(0)
    other_sources = sorted({r["source"] for r in rows
                            if r["endpoint"] == args.endpoint and r["fqdn"] == want})
    seen = f" (rows for it with source {','.join(other_sources)} but no lookup)" if other_sources else ""
    print(f"no lookup cache entry for endpoint {args.endpoint}, fqdn {args.fqdn}{seen}; {len(rows)} rows read")
    sys.exit(1)


# --- VPC CIDRs, the operator role, and the tag accounting -------------------

def ip_in_cidrs(ip, cidrs):
    address = ipaddress.ip_address(ip)
    return any(address in ipaddress.ip_network(c) for c in cidrs)


def cmd_vpc_cidrs(_):
    info = cluster_info()
    vpc = aws("ec2", "describe-vpcs", "--vpc-ids", info["resourcesVpcConfig"]["vpcId"])["Vpcs"][0]
    for assoc in vpc.get("CidrBlockAssociationSet", []):
        if assoc.get("CidrBlockState", {}).get("State") == "associated":
            print(assoc["CidrBlock"])


def cmd_in_cidrs(args):
    hits = [c for c in args.cidrs if ip_in_cidrs(args.ip, [c])]
    if hits:
        print(f"{args.ip} is in {hits[0]}")
        sys.exit(0)
    print(f"{args.ip} is in none of {' '.join(args.cidrs)}")
    sys.exit(1)


def cmd_check_operator_role(_):
    """The operator's Pod Identity role allows exactly OPERATOR_ACTIONS (the same set
    validate_pod_identity_config asserts the committed policy holds, so the live role and the
    tracked YAML are kept in lockstep), and no node role carries AmazonEKS_CNI_Policy."""
    cluster = setting("CLUSTER_NAME")
    assocs = aws("eks", "list-pod-identity-associations", "--cluster-name", cluster, "--namespace",
                 "kube-system", "--service-account", "cilium-operator").get("associations", [])
    require(len(assocs) == 1, f"expected one association for kube-system/cilium-operator, found {len(assocs)}")
    assoc = aws("eks", "describe-pod-identity-association", "--cluster-name", cluster,
                "--association-id", assocs[0]["associationId"])["association"]
    role = assoc["roleArn"].rsplit("/", 1)[1]
    attached = aws("iam", "list-attached-role-policies", "--role-name", role).get("AttachedPolicies", [])
    require(not attached, f"operator role {role} has managed policies attached: {[p['PolicyName'] for p in attached]}")
    actions = set()
    for name in aws("iam", "list-role-policies", "--role-name", role).get("PolicyNames", []):
        doc = aws("iam", "get-role-policy", "--role-name", role, "--policy-name", name)["PolicyDocument"]
        actions |= policy_actions(doc)
    require(actions == OPERATOR_ACTIONS, f"operator role actions differ: {sorted(actions ^ OPERATOR_ACTIONS)}")
    print(f"operator role {role}: {len(actions)} actions, exactly Cilium's documented ENI set")
    for group in aws("eks", "list-nodegroups", "--cluster-name", cluster).get("nodegroups", []):
        node_role = aws("eks", "describe-nodegroup", "--cluster-name", cluster, "--nodegroup-name",
                        group)["nodegroup"]["nodeRole"].rsplit("/", 1)[1]
        names = [p["PolicyName"] for p in aws("iam", "list-attached-role-policies", "--role-name",
                                               node_role).get("AttachedPolicies", [])]
        require("AmazonEKS_CNI_Policy" not in names, f"node role {node_role} has AmazonEKS_CNI_Policy")
        print(f"node role {node_role} ({group}): {', '.join(sorted(names))}")


def inventory():
    """[(kind, id, tags)] for every listable AWS resource this sample's cluster owns. Built
    from the cluster outwards: the cluster names its VPC, node groups and add-ons; the node
    groups name their ASGs, launch templates and roles; the VPC holds the subnets, route
    tables, gateways, security groups, network ACLs, ENIs and instances."""
    cluster = setting("CLUSTER_NAME")
    info = cluster_info()
    require_demo_cluster_info(info)
    items = [("eks-cluster", info["arn"], tag_map(info.get("tags")))]
    roles, lts = {info["roleArn"].rsplit("/", 1)[1]}, set()
    asg_names = []
    for group_name in aws("eks", "list-nodegroups", "--cluster-name", cluster).get("nodegroups", []):
        ng = aws("eks", "describe-nodegroup", "--cluster-name", cluster, "--nodegroup-name", group_name)["nodegroup"]
        items.append(("eks-nodegroup", ng["nodegroupArn"], tag_map(ng.get("tags"))))
        roles.add(ng["nodeRole"].rsplit("/", 1)[1])
        if ng.get("launchTemplate", {}).get("id"):
            lts.add(ng["launchTemplate"]["id"])
        asg_names += [a["name"] for a in ng.get("resources", {}).get("autoScalingGroups", [])]
    for addon in aws("eks", "list-addons", "--cluster-name", cluster).get("addons", []):
        a = aws("eks", "describe-addon", "--cluster-name", cluster, "--addon-name", addon)["addon"]
        items.append(("eks-addon", a["addonArn"], tag_map(a.get("tags"))))
    for assoc in aws("eks", "list-pod-identity-associations", "--cluster-name", cluster).get("associations", []):
        p = aws("eks", "describe-pod-identity-association", "--cluster-name", cluster,
                "--association-id", assoc["associationId"])["association"]
        items.append(("eks-pod-identity", p["associationArn"], tag_map(p.get("tags"))))
        roles.add(p["roleArn"].rsplit("/", 1)[1])
    if asg_names:
        for g in aws("autoscaling", "describe-auto-scaling-groups", "--auto-scaling-group-names",
                     *asg_names).get("AutoScalingGroups", []):
            items.append(("asg", g["AutoScalingGroupName"], tag_map(g.get("Tags"))))
            spec = g.get("LaunchTemplate") or g.get("MixedInstancesPolicy", {}).get(
                "LaunchTemplate", {}).get("LaunchTemplateSpecification", {})
            if spec.get("LaunchTemplateId"):
                lts.add(spec["LaunchTemplateId"])
    prefix = f"eksctl-{cluster}-"
    for stack in aws("cloudformation", "describe-stacks").get("Stacks", []):
        if stack["StackName"].startswith(prefix) and stack["StackStatus"] != "DELETE_COMPLETE":
            items.append(("cfn-stack", stack["StackName"], tag_map(stack.get("Tags"))))
            for r in aws("cloudformation", "describe-stack-resources", "--stack-name",
                         stack["StackName"]).get("StackResources", []):
                if r["ResourceType"] == "AWS::IAM::Role" and r.get("PhysicalResourceId"):
                    roles.add(r["PhysicalResourceId"])
                if r["ResourceType"] == "AWS::EC2::LaunchTemplate" and r.get("PhysicalResourceId"):
                    lts.add(r["PhysicalResourceId"])
    for role in sorted(roles):
        items.append(("iam-role", role, tag_map(aws("iam", "get-role", "--role-name", role)["Role"].get("Tags", []))))
        for profile in aws("iam", "list-instance-profiles-for-role", "--role-name", role).get("InstanceProfiles", []):
            name = profile["InstanceProfileName"]
            got = aws("iam", "get-instance-profile", "--instance-profile-name", name)["InstanceProfile"]
            items.append(("instance-profile", name, tag_map(got.get("Tags"))))
    items += vpc_inventory(info["resourcesVpcConfig"]["vpcId"])
    if lts:
        for lt in aws("ec2", "describe-launch-templates", "--launch-template-ids", *sorted(lts)).get(
                "LaunchTemplates", []):
            items.append(("launch-template", lt["LaunchTemplateId"], tag_map(lt.get("Tags"))))
    return items


def vpc_inventory(vpc):
    f = f"Name=vpc-id,Values={vpc}"
    items = [("vpc", v["VpcId"], tag_map(v.get("Tags"))) for v in aws("ec2", "describe-vpcs", "--vpc-ids", vpc)["Vpcs"]]
    items += [("subnet", s["SubnetId"], tag_map(s.get("Tags")))
              for s in aws("ec2", "describe-subnets", "--filters", f)["Subnets"]]
    items += [("route-table", r["RouteTableId"], tag_map(r.get("Tags")))
              for r in aws("ec2", "describe-route-tables", "--filters", f)["RouteTables"]]
    items += [("internet-gateway", g["InternetGatewayId"], tag_map(g.get("Tags")))
              for g in aws("ec2", "describe-internet-gateways", "--filters",
                           f"Name=attachment.vpc-id,Values={vpc}")["InternetGateways"]]
    nats = [n for n in aws("ec2", "describe-nat-gateways", "--filter", f)["NatGateways"]
            if n["State"] not in ("deleted", "deleting")]
    items += [("nat-gateway", n["NatGatewayId"], tag_map(n.get("Tags"))) for n in nats]
    allocations = [a["AllocationId"] for n in nats for a in n.get("NatGatewayAddresses", []) if a.get("AllocationId")]
    if allocations:
        items += [("elastic-ip", a["AllocationId"], tag_map(a.get("Tags")))
                  for a in aws("ec2", "describe-addresses", "--allocation-ids", *allocations)["Addresses"]]
    items += [("security-group", g["GroupId"], tag_map(g.get("Tags")))
              for g in aws("ec2", "describe-security-groups", "--filters", f)["SecurityGroups"]]
    items += [("network-acl", a["NetworkAclId"], tag_map(a.get("Tags")))
              for a in aws("ec2", "describe-network-acls", "--filters", f)["NetworkAcls"]]
    items += [("network-interface", e["NetworkInterfaceId"], tag_map(e.get("TagSet")))
              for e in aws("ec2", "describe-network-interfaces", "--filters", f)["NetworkInterfaces"]]
    instances = [i for r in aws("ec2", "describe-instances", "--filters", f,
                                "Name=instance-state-name,Values=pending,running,stopping,stopped")["Reservations"]
                 for i in r["Instances"]]
    items += [("instance", i["InstanceId"], tag_map(i.get("Tags"))) for i in instances]
    if instances:
        ids = ",".join(i["InstanceId"] for i in instances)
        items += [("volume", v["VolumeId"], tag_map(v.get("Tags")))
                  for v in aws("ec2", "describe-volumes", "--filters", f"Name=attachment.instance-id,Values={ids}")["Volumes"]]
    return items


# The inventory must reach at least the topology setup.sh builds, or it did not really look:
# a kind it never reaches can never fail the audit.
MINIMUM_KINDS = {
    "eks-cluster": 1, "eks-nodegroup": 2, "eks-addon": 2, "eks-pod-identity": 1, "asg": 2,
    "cfn-stack": 4, "iam-role": 4, "instance-profile": 2,
    "vpc": 1, "subnet": 4, "route-table": 3, "internet-gateway": 1, "nat-gateway": 1,
    "elastic-ip": 1, "security-group": 3, "network-acl": 1, "network-interface": 5,
    "instance": 2, "volume": 2, "launch-template": 2,
}


def audit(items):
    """(missing, gaps): resources without auto-delete=no, and kinds the inventory under-reached."""
    missing = [(k, i) for k, i, tags in items if tags.get(KEEP[0]) != KEEP[1]]
    counts = {}
    for kind, _, _ in items:
        counts[kind] = counts.get(kind, 0) + 1
    gaps = [f"{kind} (found {counts.get(kind, 0)}, expected at least {n})"
            for kind, n in MINIMUM_KINDS.items() if counts.get(kind, 0) < n]
    return missing, gaps


def cmd_audit_tags(_):
    items = inventory()
    missing, gaps = audit(items)
    for kind, ident, tags in items:
        state = "ok     " if tags.get(KEEP[0]) == KEEP[1] else "MISSING"
        print(f"{state} {kind:18} {ident}")
    for gap in gaps:
        print(f"GAP     {gap}")
    print(f"{len(items)} resources, {len(missing)} without {KEEP[0]}={KEEP[1]}, {len(gaps)} coverage gaps")
    if gaps:
        sys.exit(2)
    sys.exit(1 if missing else 0)


def cmd_tag_sweep(_):
    """Tag what AWS creates implicitly, where no create-time hook exists: the EKS-managed Auto
    Scaling groups, the launch-template copies EKS makes, the VPC's default route table,
    security group and network ACL, and interfaces other services put in the VPC."""
    tags = demo_tags()
    ec2_ids, asgs = [], []
    for kind, ident, current in inventory():
        if current.get(KEEP[0]) == KEEP[1]:
            continue
        if kind == "asg":
            asgs.append(ident)
        elif kind in ("eks-cluster", "eks-nodegroup", "eks-addon", "eks-pod-identity"):
            aws("eks", "tag-resource", "--resource-arn", ident, "--tags", ",".join(f"{k}={v}" for k, v in tags))
            print(f"tagged {kind} {ident}")
        elif kind == "iam-role":
            aws("iam", "tag-role", "--role-name", ident, "--tags", *[f"Key={k},Value={v}" for k, v in tags])
            print(f"tagged {kind} {ident}")
        elif kind == "instance-profile":
            aws("iam", "tag-instance-profile", "--instance-profile-name", ident,
                "--tags", *[f"Key={k},Value={v}" for k, v in tags])
            print(f"tagged {kind} {ident}")
        elif kind == "cfn-stack":
            print(f"NOT TAGGED {kind} {ident}: stack tags are set by eksctl at create time")
        else:
            ec2_ids.append((kind, ident))
    for asg in asgs:
        aws("autoscaling", "create-or-update-tags", "--tags", json.dumps([
            {"ResourceId": asg, "ResourceType": "auto-scaling-group", "Key": k, "Value": v,
             "PropagateAtLaunch": True} for k, v in tags]))
        print(f"tagged asg {asg} (PropagateAtLaunch)")
    for start in range(0, len(ec2_ids), 50):
        batch = ec2_ids[start:start + 50]
        aws("ec2", "create-tags", "--resources", *[i for _, i in batch],
            "--tags", *[f"Key={k},Value={v}" for k, v in tags])
        for kind, ident in batch:
            print(f"tagged {kind} {ident}")


def cmd_owned(_):
    """List what this sample owns, for clean.sh --dry-run."""
    for kind, ident, _ in inventory():
        print(f"{kind:18} {ident}")


def eni_report(enis):
    """(lines, untagged count). An empty list is not a pass: a VPC with a running cluster
    always has interfaces, so none means the read was wrong."""
    lines, untagged = [], 0
    for eni in enis:
        tags = tag_map(eni.get("TagSet"))
        ok = tags.get(KEEP[0]) == KEEP[1]
        untagged += 0 if ok else 1
        who = eni.get("Description") or eni.get("InterfaceType") or "-"
        lines.append(f"{'ok      ' if ok else 'untagged'} {eni['NetworkInterfaceId']} ({who})")
    return lines, untagged


def cmd_eni_tags(args):
    enis = aws("ec2", "describe-network-interfaces", "--filters", f"Name=vpc-id,Values={args.vpc}").get(
        "NetworkInterfaces", [])
    lines, untagged = eni_report(enis)
    print("\n".join(lines))
    print(f"{len(enis)} ENIs, {untagged} without {KEEP[0]}={KEEP[1]}")
    sys.exit(0 if enis and not untagged else 1)


# --- No account-specific value in a tracked file ----------------------------
ACCOUNT_ID = re.compile(r"(?<![0-9])[0-9]{12}(?![0-9])")
RESOURCE_ID = re.compile(r"\b(?:ami|vpc|subnet|sg|lt|i|eni|vol|igw|nat|eipalloc|rtb|acl)-[0-9a-f]{8}(?:[0-9a-f]{9})?\b")
EKS_ENDPOINT = re.compile(r"\b[0-9A-F]{32}\.[a-z0-9]+\.[a-z0-9-]+\.eks\.amazonaws\.com\b")


def account_values(text, usernames):
    """Every account-specific value in text: (line number, what, value)."""
    found = []
    names = [u for u in usernames if u and len(u) >= 3]
    user_re = re.compile(r"(?<![A-Za-z0-9])(?:" + "|".join(re.escape(u) for u in names) + r")(?![A-Za-z0-9])",
                         re.IGNORECASE) if names else None
    for number, line in enumerate(text.splitlines(), 1):
        found += [(number, "account id", m.group()) for m in ACCOUNT_ID.finditer(line)]
        found += [(number, "resource id", m.group()) for m in RESOURCE_ID.finditer(line)
                  if m.group() not in PLACEHOLDER_IDS]
        found += [(number, "EKS endpoint", m.group()) for m in EKS_ENDPOINT.finditer(line)]
        if user_re:
            found += [(number, "username", m.group()) for m in user_re.finditer(line)]
    return found


def demo_files():
    """Tracked and not-ignored files under this sample, as git sees them."""
    rel = DEMO.relative_to(REPO)
    listed = run(["git", "-C", REPO, "ls-files", "--cached", "--others", "--exclude-standard", "--", str(rel)])
    return [REPO / p for p in listed.splitlines() if p and (REPO / p).is_file()]


def cmd_check_tracked(_):
    usernames = {getpass.getuser(), os.environ.get("USER", ""), os.environ.get("SUDO_USER", "")}
    files = demo_files()
    require(files, "git listed no files for this sample; nothing was checked")
    findings = 0
    for path in files:
        for number, what, value in account_values(path.read_text(errors="replace"), usernames):
            print(f"{path.relative_to(REPO)}:{number}: {what} {value}")
            findings += 1
    print(f"checked {len(files)} files, {findings} account-specific values")
    sys.exit(1 if findings else 0)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("render-cluster").set_defaults(func=cmd_render_cluster)
    p = sub.add_parser("render-nodegroups")
    p.add_argument("--system-launch-template", required=True)
    p.add_argument("--sandbox-launch-template", required=True)
    p.set_defaults(func=cmd_render_nodegroups)
    sub.add_parser("check-sandbox-ami").set_defaults(func=cmd_check_sandbox_ami)
    sub.add_parser("check-system-ami").set_defaults(func=cmd_check_system_ami)
    p = sub.add_parser("launch-template")
    p.add_argument("group", choices=[SYSTEM_GROUP, SANDBOX_GROUP])
    p.set_defaults(func=cmd_launch_template)
    sub.add_parser("preflight-daemonset").set_defaults(func=cmd_preflight_daemonset)
    p = sub.add_parser("check-btf")
    p.add_argument("nodegroup")
    p.add_argument("node")
    p.set_defaults(func=cmd_check_btf)
    sub.add_parser("runtimeclass").set_defaults(func=cmd_runtimeclass)
    sub.add_parser("check-runtimeclass").set_defaults(func=cmd_check_runtimeclass)
    p = sub.add_parser("check-node-labels")
    p.add_argument("role", choices=[SYSTEM_GROUP, SANDBOX_GROUP])
    p.set_defaults(func=cmd_check_node_labels)
    p = sub.add_parser("check-user-data")
    p.add_argument("role", choices=[SYSTEM_GROUP, SANDBOX_GROUP])
    p.set_defaults(func=cmd_check_user_data)
    p = sub.add_parser("check-workloads")
    p.add_argument("--file")
    p.set_defaults(func=cmd_check_workloads)
    p = sub.add_parser("check-cilium-values")
    p.add_argument("--file")
    p.set_defaults(func=cmd_check_cilium_values)
    p = sub.add_parser("kernel-release")
    p.add_argument("want")
    p.add_argument("got")
    p.set_defaults(func=cmd_kernel_release)
    # test.sh / clean.sh side
    sub.add_parser("datapath-failures").set_defaults(func=cmd_datapath_failures)
    sub.add_parser("kpr-status").set_defaults(func=cmd_kpr_status)
    sub.add_parser("kube-proxy-rules").set_defaults(func=cmd_kube_proxy_rules)
    sub.add_parser("l7-requests").set_defaults(func=cmd_l7_requests)
    p = sub.add_parser("l7-verdict")
    p.add_argument("endpoint")
    p.add_argument("path_suffix")
    p.add_argument("want_verdict")
    p.add_argument("want_code")
    p.set_defaults(func=cmd_l7_verdict)
    p = sub.add_parser("fqdn-cache-has")
    p.add_argument("endpoint")
    p.add_argument("fqdn")
    p.set_defaults(func=cmd_fqdn_cache_has)
    sub.add_parser("vpc-cidrs").set_defaults(func=cmd_vpc_cidrs)
    p = sub.add_parser("in-cidrs")
    p.add_argument("ip")
    p.add_argument("cidrs", nargs="+")
    p.set_defaults(func=cmd_in_cidrs)
    sub.add_parser("check-operator-role").set_defaults(func=cmd_check_operator_role)
    sub.add_parser("audit-tags").set_defaults(func=cmd_audit_tags)
    sub.add_parser("tag-sweep").set_defaults(func=cmd_tag_sweep)
    sub.add_parser("owned").set_defaults(func=cmd_owned)
    p = sub.add_parser("eni-tags")
    p.add_argument("vpc")
    p.set_defaults(func=cmd_eni_tags)
    sub.add_parser("check-tracked").set_defaults(func=cmd_check_tracked)
    args = parser.parse_args()
    try:
        args.func(args)
    except DemoError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
