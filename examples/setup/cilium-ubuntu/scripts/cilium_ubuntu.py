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
import getpass
import ipaddress
import json
import os
import re
import string
import subprocess
import sys
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
# The node group name label is what the sample's pods select on; the taint key doubles as a
# label so the sandbox RuntimeClass's node affinity (if any) and this sample's own selectors
# agree on one name.
SANDBOX_LABELS = {
    "eks.amazonaws.com/nodegroup": SANDBOX_GROUP,
    SANDBOX_TAINT_KEY: "true",
}
KUBELET_LABELS = {"kubernetes.io/os": "linux", "kubernetes.io/arch": "amd64"}
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
    return cfg


def render_config(template, destination, values, validate):
    import yaml  # PyYAML; imported here so offline checks that do not render need not have it
    text = substitute((DEMO / "eksctl" / template).read_text(), values)
    cfg = validate(yaml.safe_load(text))
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


def cmd_render_nodegroups(args):
    render_config("nodegroups.yaml", OUT / "nodegroups.yaml", {
        "CLUSTER_NAME": setting("CLUSTER_NAME"), "AWS_REGION": setting("AWS_REGION"),
        "NODE_ZONE": zones()[0],
        "SYSTEM_LAUNCH_TEMPLATE_ID": args.system_launch_template,
        "SANDBOX_LAUNCH_TEMPLATE_ID": args.sandbox_launch_template,
    }, validate_nodegroups_config)


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


def launch_template_data(group):
    """The launch template each node group uses. Both are created by this sample, so both
    carry the sample's tags from the moment they exist, and so do the instances, volumes and
    network interfaces launched from them."""
    common = {
        # Hop limit 1: every IMDS consumer on these nodes is host-network (kubelet, the
        # Cilium agent), so a pod, including a sandbox guest, cannot reach the node's
        # credentials through IMDS.
        "MetadataOptions": {"HttpTokens": "required", "HttpPutResponseHopLimit": 1},
        "TagSpecifications": tag_specs(group, "instance", "volume", "network-interface"),
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
        # EKS Pod Isolation runs each sandboxed pod in a guest VM through the Nitro Enclaves
        # device; the ../ubuntu-ami build enables this on the AMI's own nodeadm user data, so
        # the launch template only needs the device itself turned on.
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
    out = run(["kubectl", "-n", "kube-system", "exec", pod_name, "-c", "cilium-agent",
               "--", "sh", "-c", f'test -s {BTF_PATH} && echo PRESENT || echo MISSING'])
    require("PRESENT" in out,
            f"node {args.node} (nodegroup {nodegroup}) has no BTF at {BTF_PATH}; its Cilium agent "
            "cannot load the kube-proxy-replacement datapath. This node's kernel was not built with "
            "CONFIG_DEBUG_INFO_BTF=y; see ../ubuntu-ami for the BTF-enabled build this sample depends on.")
    print(f"BTF present on node {args.node} (nodegroup {nodegroup})")


def cmd_runtimeclass(_):
    """Print the isolated-sandbox RuntimeClass this sample's pods use. Scheduling onto the
    dedicated sandbox node group is left to the pod spec's own nodeSelector/toleration (as
    deploy/ shows), not to a RuntimeClass-level node affinity, so the RuntimeClass object
    itself needs no sample-specific fields beyond the published handler name."""
    rc = {
        "apiVersion": "node.k8s.io/v1",
        "kind": "RuntimeClass",
        "metadata": {"name": "isolated-sandbox"},
        "handler": "isolated-sandbox",
    }
    print(json.dumps(rc))


# ===========================================================================
# test.sh / clean.sh side: proofs read off the running Cilium agents, and the
# AWS tag accounting the clean up deletes by.
#
# Each agent-output parser takes text on stdin and answers with an exit code: 0 the property
# holds, 1 it does not, 2 the input was not a real read (empty/failed/truncated) so nothing
# was checked. A read that cannot be told apart from a good answer is never taken as one.
# ===========================================================================

def cluster_info():
    return aws("eks", "describe-cluster", "--name", setting("CLUSTER_NAME"))["cluster"]


def require_demo_cluster_info(info):
    require(tag_map(info.get("tags")).get(DEMO_TAG[0]) == DEMO_TAG[1],
            f"cluster {info['name']} does not carry {DEMO_TAG[0]}={DEMO_TAG[1]}; it is not this sample's")


# --- The agent log: its eBPF datapath loaded, with the kernel's BTF ---------
AGENT_LINE = re.compile(r'^time=\S+ level=[a-z]+ msg=')
DATAPATH_FAILURE = re.compile(r'^time=\S+ level=(?:warn|error) msg="Failed to initialize datapath')
NO_BTF = "no BTF found"


def datapath_failures(log_text):
    """(lines read, failure lines) in a cilium-agent log. Anchored on the agent's log-line
    prefix, so a line that only quotes the text (a comment, a grep) is not a failure."""
    lines = log_text.splitlines()
    return len(lines), [line for line in lines
                        if DATAPATH_FAILURE.match(line) or (AGENT_LINE.match(line) and NO_BTF in line)]


def cmd_datapath_failures(_):
    read, failures = datapath_failures(sys.stdin.read())
    if not read:
        print("empty agent log: nothing was checked", file=sys.stderr)
        sys.exit(2)
    for line in failures[:3]:
        print(line[:300])
    print(f"{len(failures)} 'Failed to initialize datapath' / '{NO_BTF}' lines in {read} log lines")
    sys.exit(1 if failures else 0)


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
    sys.exit(0 if ip_in_cidrs(args.ip, args.cidrs) else 1)


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
