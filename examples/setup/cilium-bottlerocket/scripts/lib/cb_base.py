"""Shared helpers of scripts/cilium_bottlerocket.py: settings, state, tags, CLI calls, and the
parsers of the ENI captures.

Exit codes of every check: 0 accept, 1 reject, 2 could not check. Each refusal prints one
line on stderr that starts with "ERROR: ". The helpers call the aws and kubectl CLIs by bare
name through PATH, so the offline tests can put stub commands first on PATH.
"""

import ipaddress
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SAMPLE = Path(__file__).resolve().parents[2]
OWNER_TAG = ("ManagedBy", "cilium-bottlerocket-sample")
RUN_TAG_KEY = "RunId"
NS_LABEL = ("app.kubernetes.io/part-of", "cilium-bottlerocket-sample")
SANDBOX_TAINT_KEY = "sandbox.eks-nitro-sandbox.amazonaws.com/dedicated"
NODEGROUP_LABEL = "eks.amazonaws.com/nodegroup"
SANDBOX_NODE_LABEL = ("eks.amazonaws.com/nitro-sandbox", "true")
SYSTEM_AMI_NAME = "bottlerocket-aws-k8s-1.36-x86_64-v1.70.0-59b0684a"
SANDBOX_VARIANT = "aws-k8s-1.36-nitro-sandbox"
CRI_PROXY_ENDPOINT = "unix:///run/nitro-sandbox/cri-proxy.sock"
NAMESPACE = "cilium-bottlerocket-demo"
AMI_ID = re.compile(r"^ami-[0-9a-f]{8}(?:[0-9a-f]{9})?$")
LT_ID = re.compile(r"^lt-[0-9a-f]{17}$")


class Reject(Exception):
    """The input is wrong, or a resource is not the sample's (exit 1)."""


class Unknown(Exception):
    """A lookup failed or an answer is malformed (exit 2)."""


def require(condition, message):
    if not condition:
        raise Reject(message)


def setting(name, required=True):
    value = os.environ.get(name, "")
    if required and not value:
        raise Unknown(f"{name} is not set (source scripts/common.sh first)")
    return value


def int_setting(name, low, high):
    raw = setting(name)
    require(re.fullmatch(r"[0-9]{1,4}", raw) is not None and low <= int(raw) <= high,
            f"{name}={raw} is not an integer from {low} to {high}")
    return int(raw)


def run_id():
    value = setting("RUN_ID")
    require(re.fullmatch(r"[a-z0-9]{1,20}", value) is not None, f"RUN_ID '{value}' is not valid")
    return value


def sample_tags():
    return {OWNER_TAG[0]: OWNER_TAG[1], RUN_TAG_KEY: run_id()}


def tag_list():
    return [{"Key": k, "Value": v} for k, v in sample_tags().items()]


def tag_map(tags):
    """A tag list or map as a dict. None when the input is not a tag set."""
    if isinstance(tags, dict):
        return tags
    if isinstance(tags, list):
        try:
            return {t["Key"]: t["Value"] for t in tags}
        except (KeyError, TypeError):
            return None
    return None


def is_ours(tags):
    tags = tag_map(tags or [])
    return tags is not None and all(tags.get(k) == v for k, v in sample_tags().items())


def run(args, data=None):
    """Run a command. Returns (rc, stdout, stderr); never raises for a non-zero exit."""
    try:
        proc = subprocess.run(args, input=data, capture_output=True, text=True, check=False)
    except OSError as err:
        raise Unknown(f"could not run {args[0]}: {err}") from err
    return proc.returncode, proc.stdout, proc.stderr


def aws(*args, allow=()):
    """An AWS CLI call in the configured Region, as JSON. A listed error code returns None."""
    rc, out, err = run(["aws", *args, "--region", setting("AWS_REGION"), "--output", "json"])
    if rc != 0:
        for code in allow:
            if f"({code})" in err:
                return None
        raise Unknown(f"aws {' '.join(args[:2])} failed: {err.strip()}")
    try:
        return json.loads(out) if out.strip() else {}
    except ValueError as err:
        raise Unknown(f"aws {' '.join(args[:2])} returned no JSON") from err


def kubectl(*args):
    """kubectl with the pinned kubeconfig and context."""
    return run(["kubectl", "--kubeconfig", setting("KUBECONFIG"), "--context", setting("KUBE_CONTEXT"), *args])


def kube_json(*args):
    rc, out, err = kubectl(*args, "-o", "json")
    if rc != 0:
        raise Unknown(f"kubectl {' '.join(args)} failed: {err.strip()}")
    try:
        return json.loads(out)
    except ValueError as err:
        raise Unknown(f"kubectl {' '.join(args)} returned no JSON") from err


def state_get(key):
    """The last value of a key in the run state file, or '' when absent."""
    path = Path(setting("RUN_STATE_FILE"))
    try:
        lines = path.read_text().splitlines()
    except OSError as err:
        raise Unknown(f"could not read {path}: {err}") from err
    value = ""
    for line in lines:
        if line.startswith(key + "="):
            value = line[len(key) + 1:]
    return value


def read_input(path=None):
    """The text of a file argument, or of stdin. Unreadable or empty input is Unknown."""
    try:
        text = Path(path).read_text() if path and path != "-" else sys.stdin.read()
    except OSError as err:
        raise Unknown(f"could not read {path}: {err}") from err
    if not text.strip():
        raise Unknown(f"the input {path or '<stdin>'} is empty")
    return text


def read_json(path=None):
    try:
        return json.loads(read_input(path))
    except ValueError as err:
        raise Unknown(f"the input {path or '<stdin>'} is not JSON") from err


def substitute(text, values):
    """Fill ${NAME} placeholders, outside comments. Every placeholder must have a value."""
    def one(match):
        name = match.group(1)
        if name not in values:
            raise Unknown(f"no value for ${{{name}}}")
        return str(values[name])
    out = []
    for line in text.splitlines(keepends=True):
        if line.lstrip().startswith("#"):
            out.append(line)
        else:
            out.append(re.sub(r"\$\{([A-Z_]+)\}", one, line))
    return "".join(out)


def check_tag(command):
    """The stable tag of one subcommand: check-containerd-dump is E_CONTAINERD_DUMP."""
    name = command[len("check-"):] if command.startswith("check-") else command
    return "E_" + name.upper().replace("-", "_")


def main_wrapper(command, func, args):
    """Run one subcommand. A rejection prints "ERROR: E_<TAG>: <text>" and returns 1; a
    check that could not run prints "ERROR: E_<TAG>_UNKNOWN: <text>" and returns 2."""
    tag = check_tag(command)
    try:
        func(args)
    except Reject as err:
        print(f"ERROR: {tag}: {err}", file=sys.stderr)
        return 1
    except Unknown as err:
        print(f"ERROR: {tag}_UNKNOWN: could not check: {err}", file=sys.stderr)
        return 2
    except (KeyError, IndexError, TypeError, AttributeError) as err:
        print(f"ERROR: {tag}_UNKNOWN: could not check: unexpected input shape ({err!r})", file=sys.stderr)
        return 2
    return 0


# ---- Parsers of the probe captures that check-eni-capture and check-eni-stable read ----
def networkd_states(text):
    """The networkd capture of probe_capture: '==links==', the host `ip -o link` lines, then
    '==states==', one line per networkd link state file, '<ifindex> ADMIN_STATE=<s> ...'.
    Returns {interface name: ADMIN_STATE, or None when networkd has no state file for it}."""
    if "==links==" not in text or "==states==" not in text:
        raise Unknown("the capture has no ==links== and ==states== sections")
    links_text, states_text = text.split("==states==", 1)
    names = {}
    for line in links_text.split("==links==", 1)[1].splitlines():
        match = re.match(r"^([0-9]+): ([^:@ ]+)[:@]", line.strip())
        if match:
            names[match.group(1)] = match.group(2)
    if not names:
        raise Unknown("no interface in the ip -o link capture")
    states = {}
    for line in states_text.splitlines():
        match = re.match(r"^([0-9]+) .*ADMIN_STATE=(\S+)", line.strip())
        if match:
            states[match.group(1)] = match.group(2)
    return {name: states.get(index) for index, name in names.items()}


def eni_state(text):
    """One capture of probe_eni_capture (the iproute2 of the host): '==link==' `ip -o link`,
    '==addr==' `ip -o addr`, '==route==' `ip -4 route show table all`, '==route6=='
    `ip -6 route show table all`, '==rule==' `ip -4 rule`. Returns ({name: link}, rules) for
    eth1 and later. A link has its MAC, its IPv4 and IPv6 addresses, its address lines with the
    dynamic flag, its IPv4 and IPv6 routes, and the tables of its IPv4 routes. Each line has
    single spaces and no "expires <n>", so two captures compare line by line."""
    parts = dict(re.findall(r"^==(link|addr|route|route6|rule)==\n(.*?)(?=^==|\Z)", text, re.M | re.S))
    if set(parts) != {"link", "addr", "route", "route6", "rule"}:
        raise Unknown("the capture has no ==link==, ==addr==, ==route==, ==route6== and ==rule== sections")

    def lines(section):
        return [" ".join(re.sub(r" expires \S+", "", line).split()) for line in parts[section].splitlines() if line.strip()]

    def on_link(section, name):
        return sorted(line for line in lines(section) if re.search(rf"\bdev {re.escape(name)}\b", line))

    state = {}
    for line in lines("link"):
        match = re.match(r"^[0-9]+: (eth[1-9][0-9]*)[:@].*link/ether ([0-9a-f:]{17})", line)
        if not match:
            continue
        name = match.group(1)
        addr = [f for f in (line.split() for line in lines("addr")) if len(f) > 3 and f[1] == name]
        routes = on_link("route", name)
        state[name] = {
            "mac": match.group(2),
            "inet": sorted(f[3] for f in addr if f[2] == "inet"),
            "inet6": sorted(f[3] for f in addr if f[2] == "inet6"),
            "dynamic": sorted(" ".join(f) for f in addr if "dynamic" in f),
            "routes": routes,
            "routes6": on_link("route6", name),
            "tables": sorted({m.group(1) for r in routes for m in [re.search(r"\btable (\S+)", r)] if m}),
        }
    return state, sorted(lines("rule"))


def ciliumnode_enis(path):
    """{MAC: ENI record} of `kubectl get ciliumnode <node> -o json`."""
    try:
        enis = read_json(path)["status"]["eni"]["enis"]
    except (KeyError, TypeError) as err:
        raise Unknown("the CiliumNode has no status.eni.enis") from err
    return {e.get("mac", "").lower(): e for e in enis.values()}


def in_eni(ip, eni):
    """True when ip is the primary IP, a secondary IP, or in a delegated prefix of the ENI."""
    if ip and (ip == eni.get("ip") or ip in (eni.get("addresses") or [])):
        return True
    try:
        addr = ipaddress.ip_address(ip)
        return any(addr in ipaddress.ip_network(p, strict=False) for p in eni.get("prefixes") or [])
    except ValueError:
        return False


def rule_source(rule):
    """The address of 'from <address>' in an ip rule line, or "" for 'from all' and no source."""
    match = re.search(r"\bfrom (\S+)", rule)
    return "" if not match or match.group(1) == "all" else match.group(1).split("/")[0]
