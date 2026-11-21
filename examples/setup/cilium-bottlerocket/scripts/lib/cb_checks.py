"""Node, SELinux, network and density checks of scripts/cilium_bottlerocket.py.

Each check reads a capture (a file argument or stdin) that setup.sh or test.sh made on the
live cluster, so the offline tests can give it a fixture.
"""

import base64
import ipaddress
import re

from cb_base import (CRI_PROXY_ENDPOINT, SANDBOX_VARIANT, Reject, Unknown, int_setting, read_input,
                     read_json, require, setting)

OS_IMAGE = {
    "system": "Bottlerocket OS 1.70.0 (aws-k8s-1.36)",
    "sandbox": f"Bottlerocket OS 1.70.0 ({SANDBOX_VARIANT})",
}
SHIM_NAME = "containerd-shim-nitro-sandbox-v2"
AVC_DENIED = re.compile(r"\bavc:\s+denied\b")
# shortcut: the reservation line of the Nitro Enclaves driver is not known from a Bottlerocket
# node yet. This pattern accepts a kernel log line that names nitro_enclaves together with a
# reservation or the CMA pool. Phase 3 replaces it with the exact line of the live node.
MEMPOOL_LINE = re.compile(r"nitro_enclaves.*(?:reserv|mempool|cma)|cma: Reserved .*nitro", re.IGNORECASE)
MEMPOOL_ARG = "nitro_enclaves.mempool=95%-1G"


def cmd_check_os_image(args):
    node = read_json(args.file)
    info = node.get("status", {}).get("nodeInfo", {})
    got = info.get("osImage")
    require(got == OS_IMAGE[args.group], f"{args.group} node OS image is {got!r}, want {OS_IMAGE[args.group]!r}")
    require(str(info.get("kubeletVersion", "")).startswith("v1.36."), f"kubelet is {info.get('kubeletVersion')!r}, want v1.36")
    require(info.get("architecture") == "amd64", f"node architecture is {info.get('architecture')!r}")
    print(f"{args.group} node: {got}, kubelet {info['kubeletVersion']}, kernel {info.get('kernelVersion')}")


def cmd_check_btf(args):
    text = read_input(args.file).strip()
    match = re.fullmatch(r"BTF_BYTES=([0-9]+)", text)
    if not match:
        raise Unknown(f"the BTF capture is not BTF_BYTES=<n>: {text[:80]!r}")
    require(int(match.group(1)) > 0, "/sys/kernel/btf/vmlinux is empty")
    print(f"/sys/kernel/btf/vmlinux: {match.group(1)} bytes")


def cmd_check_mempool(args):
    cmdline = read_input(args.cmdline)
    log = read_input(args.kernel_log)
    require(MEMPOOL_ARG in cmdline.split(), f"the kernel command line has no {MEMPOOL_ARG}")
    lines = [line for line in log.splitlines() if MEMPOOL_LINE.search(line)]
    require(lines, "the kernel log has no nitro_enclaves memory reservation line")
    print(f"kernel command line has {MEMPOOL_ARG}; kernel log: {lines[0].strip()}")


def cmd_check_runtime_endpoint(args):
    doc = read_json(args.file)
    got = doc.get("kubeletconfig", {}).get("containerRuntimeEndpoint")
    require(got == CRI_PROXY_ENDPOINT, f"kubelet runtime endpoint is {got!r}, want {CRI_PROXY_ENDPOINT}")
    print(f"kubelet containerRuntimeEndpoint: {got}")


def cmd_check_containerd_dump(args):
    """A merged `containerd config dump`. A malformed drop-in makes containerd print an error
    instead of a configuration, which this check refuses like a missing handler."""
    text = read_input(args.file)
    # containerd 2.3 on Bottlerocket 1.70.0 reads a version 3 file and dumps it as version 4,
    # with each table indented (live system node, Phase 1).
    require(re.search(r"^version = [34]$", text, re.M) is not None,
            "the input is not a containerd version 3 or 4 configuration dump (a malformed drop-in, or an error)")
    q = r"""['"]?"""
    table = re.compile(r"^\s*\[plugins\." + q + r"io\.containerd\.cri\.v1\.runtime" + q
                       + r"\.containerd\.runtimes\." + q + r"isolated-sandbox" + q + r"\]$", re.M)
    head = table.search(text)
    require(head is not None, "the merged configuration has no isolated-sandbox runtime handler")
    body = re.split(r"\n\s*\[", text[head.end():], maxsplit=1)[0]
    require(re.search(r"^\s*runtime_type = ['\"]io\.containerd\.nitro-sandbox\.v2['\"]$", body, re.M) is not None,
            "the isolated-sandbox handler does not use runtime_type io.containerd.nitro-sandbox.v2")
    values = re.findall(r"^\s*discard_unpacked_layers = (\S+)$", text, re.M)
    require(values and set(values) == {"false"}, f"discard_unpacked_layers is {values or 'unset'}, want false")
    print("merged containerd config: isolated-sandbox handler with io.containerd.nitro-sandbox.v2, discard_unpacked_layers = false")


def cmd_check_allocatable(args):
    node = read_json(args.file)
    raw = node.get("status", {}).get("allocatable", {}).get("eks.amazonaws.com/nitro-sandbox")
    require(raw is not None and re.fullmatch(r"[0-9]+", str(raw)) is not None and int(raw) > 0,
            f"allocatable eks.amazonaws.com/nitro-sandbox is {raw!r}, want more than 0")
    print(f"allocatable eks.amazonaws.com/nitro-sandbox: {raw}")


def lt_max_pods(doc):
    try:
        data = doc["LaunchTemplateVersions"][0]["LaunchTemplateData"]["UserData"]
        text = base64.b64decode(data, validate=True).decode()
    except (KeyError, IndexError, TypeError, ValueError) as err:
        raise Unknown("the launch template input has no base64 user data") from err
    found = re.findall(r"^max-pods = ([0-9]+)$", text, re.M)
    require(len(found) == 1, f"the launch template user data has {len(found)} max-pods lines")
    return int(found[0])


def cmd_check_density(args):
    """SANDBOX_SLOTS against each input given: the AMI tag, the launch template max-pods, the
    allocatable pods of the node, and pcie_slots in the shim configuration of the node."""
    slots = args.slots if args.slots is not None else int_setting("SANDBOX_SLOTS", 1, 250)
    seen = {}
    if args.ami_tags:
        images = read_json(args.ami_tags).get("Images", [])
        require(len(images) == 1, f"expected one image, got {len(images)}")
        tags = {t["Key"]: t["Value"] for t in images[0].get("Tags", [])}
        seen["AMI tag SandboxSlots"] = tags.get("SandboxSlots")
    if args.launch_template:
        seen["launch template max-pods"] = lt_max_pods(read_json(args.launch_template))
    if args.node:
        seen["node allocatable pods"] = read_json(args.node).get("status", {}).get("allocatable", {}).get("pods")
    if args.shim_toml:
        found = re.findall(r"^\s*pcie_slots\s*=\s*([0-9]+)\s*(?:#.*)?$", read_input(args.shim_toml), re.M)
        require(len(found) == 1, f"nitro-sandbox.toml has {len(found)} pcie_slots lines")
        seen["node pcie_slots"] = found[0]
    if not seen:
        raise Unknown("check-density got no input to compare")
    wrong = [f"{k}={v!r}" for k, v in seen.items() if str(v) != str(slots)]
    require(not wrong, f"SANDBOX_SLOTS={slots} but " + ", ".join(wrong))
    print(f"density: SANDBOX_SLOTS={slots} equals " + ", ".join(seen))


def cmd_check_selinux_mode(args):
    text = read_input(args.file).strip()
    if text not in ("0", "1"):
        raise Unknown(f"/sys/fs/selinux/enforce reads {text[:20]!r}")
    require(text == "1", "SELinux is not in enforcing mode")
    print("SELinux: enforcing")


def cmd_selinux_audit(args):
    """Fails closed: any AVC denial is a rejection; a missing, unreadable or empty capture is
    exit 2, never a pass."""
    found = []
    for path in (args.avc_file, args.journal_file):
        found += [line.strip() for line in read_input(path).splitlines() if AVC_DENIED.search(line)]
    require(not found, f"{len(found)} SELinux denial(s), first: {found[0] if found else ''}")
    print("SELinux audit: no AVC denial in the kernel log or the journal")


def cmd_check_selinux_domains(args):
    """A capture of '<SELinux label>\\t<command line>' per host process. The shim and the CRI
    proxy must both run, and each process of the shim binary must be in runtime_t."""
    rows = []
    for line in read_input(args.file).splitlines():
        if "\t" not in line:
            continue
        label, cmd = line.split("\t", 1)
        argv0 = cmd.split(" ", 1)[0]
        if argv0.rsplit("/", 1)[-1] == SHIM_NAME:
            rows.append((label.strip(), cmd.strip()))
    if not rows:
        raise Reject(f"no {SHIM_NAME} process runs on the node")
    proxies = [r for r in rows if " cri-proxy" in r[1]]
    shims = [r for r in rows if " cri-proxy" not in r[1]]
    require(proxies, "the CRI proxy does not run")
    require(shims, "no sandbox shim process runs (start the sandbox pod first)")
    wrong = [r for r in rows if len(r[0].split(":")) < 3 or r[0].split(":")[2] != "runtime_t"]
    require(not wrong, f"{len(wrong)} shim process(es) not in runtime_t: {wrong[0]}" if wrong else "")
    print(f"SELinux domain runtime_t: CRI proxy ({len(proxies)}) and shim ({len(shims)}): {rows[0][0]}")


def cmd_check_networkd(args):
    """Capture: '==links==', the host `ip -o link` lines, '==states==', one line per networkd
    link state file, '<ifindex> ADMIN_STATE=<s> OPER_STATE=<s>'. Each eth[1-9]* interface (a
    secondary ENI that Cilium manages) must be unmanaged by systemd-networkd."""
    text = read_input(args.file)
    if "==links==" not in text or "==states==" not in text:
        raise Unknown("the capture has no ==links== and ==states== sections")
    links_text, states_text = text.split("==states==", 1)
    names = {}
    for line in links_text.split("==links==", 1)[1].splitlines():
        match = re.match(r"^([0-9]+): ([^:@ ]+)[:@]", line.strip())
        if match:
            names[match.group(1)] = match.group(2)
    states = {}
    for line in states_text.splitlines():
        match = re.match(r"^([0-9]+) .*ADMIN_STATE=(\S+)", line.strip())
        if match:
            states[match.group(1)] = match.group(2)
    if not names:
        raise Unknown("no interface in the ip -o link capture")
    secondary = {i: n for i, n in names.items() if re.fullmatch(r"eth[1-9][0-9]*", n)}
    if not secondary:
        raise Unknown("the node has no secondary ENI (eth1 or later) yet; nothing to check")
    wrong = [f"{n} is {states.get(i, 'not listed')}" for i, n in sorted(secondary.items()) if states.get(i) != "unmanaged"]
    require(not wrong, "systemd-networkd manages a Cilium ENI: " + ", ".join(wrong))
    print("systemd-networkd: " + ", ".join(f"{n} unmanaged" for n in sorted(secondary.values())))


def eni_state(text):
    """One host capture: '==link==' `ip -o link`, '==addr==' `ip -o addr`, '==route=='
    `ip route show table all`, '==rule==' `ip rule`. Returns {name: (mac, addrs, routes, tables)}
    for eth1 and later, and the rule lines."""
    parts = dict(re.findall(r"^==(link|addr|route|rule)==\n(.*?)(?=^==|\Z)", text, re.M | re.S))
    if set(parts) != {"link", "addr", "route", "rule"}:
        raise Unknown("the capture has no ==link==, ==addr==, ==route== and ==rule== sections")
    links = {}
    for line in parts["link"].splitlines():
        m = re.match(r"^[0-9]+: (eth[1-9][0-9]*)[:@].*link/ether ([0-9a-f:]{17})", line.strip())
        if m:
            links[m.group(1)] = m.group(2)
    state = {}
    for name, mac in links.items():
        addrs = sorted(line.split()[3] for line in parts["addr"].splitlines()
                       if len(line.split()) > 3 and line.split()[1] == name and line.split()[2] == "inet")
        routes = sorted(re.sub(r" expires \S+", "", line.strip()) for line in parts["route"].splitlines()
                        if re.search(rf"\bdev {name}\b", line))
        tables = sorted({m.group(1) for line in routes for m in [re.search(r"\btable (\S+)", line)] if m})
        state[name] = (mac, addrs, routes, tables)
    rules = sorted(line.strip() for line in parts["rule"].splitlines() if line.strip())
    return state, rules


def cmd_check_eni_stable(args):
    """For each eth1 and later interface: the same MAC, IPv4 addresses, routes (all tables) and
    the ip rules that point to its route tables, before and after the event; each IPv4 address
    is an address of the CiliumNode ENI record with that MAC."""
    before, rules_before = eni_state(read_input(args.before))
    after, rules_after = eni_state(read_input(args.after))
    if not after:
        raise Unknown("no eth1 or later interface in the capture after the event")
    try:
        enis = read_json(args.ciliumnode)["status"]["eni"]["enis"]
    except (KeyError, TypeError) as err:
        raise Unknown("the CiliumNode has no status.eni.enis") from err
    by_mac = {e.get("mac", "").lower(): e for e in enis.values()}
    wrong = []
    for name in sorted(set(before) | set(after)):
        if name not in before or name not in after:
            wrong.append(f"{name} is in only one capture")
            continue
        (mac_b, addr_b, route_b, tab_b), (mac_a, addr_a, route_a, tab_a) = before[name], after[name]
        if mac_b != mac_a:
            wrong.append(f"{name} MAC changed {mac_b} -> {mac_a}")
        if addr_b != addr_a:
            wrong.append(f"{name} addresses changed {addr_b} -> {addr_a}")
        if route_b != route_a:
            wrong.append(f"{name} routes changed: {sorted(set(route_b) ^ set(route_a))[:3]}")
        tables = set(tab_b) | set(tab_a)
        rb = [r for r in rules_before if any(re.search(rf"\blookup {re.escape(t)}\b", r) for t in tables)]
        ra = [r for r in rules_after if any(re.search(rf"\blookup {re.escape(t)}\b", r) for t in tables)]
        if rb != ra:
            wrong.append(f"{name} rules for tables {sorted(tables)} changed: {sorted(set(rb) ^ set(ra))[:3]}")
        eni = by_mac.get(mac_a)
        if eni is None:
            wrong.append(f"{name} ({mac_a}) is not an ENI of the CiliumNode")
            continue
        known = set(eni.get("addresses", [])) | {eni.get("ip")}
        stray = [a for a in addr_a if a.split("/")[0] not in known]
        if stray:
            wrong.append(f"{name} has addresses {stray} that are not in the ENI record {eni.get('id')}")
    require(not wrong, "; ".join(wrong))
    print("Cilium ENIs unchanged by networkd: " + ", ".join(
        f"{n} ({len(after[n][1])} addresses, {len(after[n][2])} routes, tables {','.join(after[n][3]) or '-'})" for n in sorted(after)))


def cmd_check_dm_verity(args):
    """Capture: '==dm==' the name of /sys/block/dm-0, '==dev==' its major:minor, '==cmdline=='
    /proc/cmdline, '==mount==' the mountinfo line of /. The root is the read-only dm-verity
    device dm-0. Bottlerocket 1.70.0 names the mount source /dev/root, so the check compares
    the device number of / with that of dm-0 (live system node, Phase 1)."""
    text = read_input(args.file)
    parts = dict(re.findall(r"^==(dm|dev|cmdline|mount)==\n(.*?)(?=^==|\Z)", text, re.M | re.S))
    if set(parts) != {"dm", "dev", "cmdline", "mount"}:
        raise Unknown("the capture has no ==dm==, ==dev==, ==cmdline== and ==mount== sections")
    require(parts["dm"].strip() == "root", f"dm-0 is {parts['dm'].strip()!r}, not root")
    tokens = parts["cmdline"].replace('"', " ").split()
    require("root=/dev/dm-0" in tokens and "verity" in tokens and any(t.startswith("dm-mod.create=root,") for t in tokens),
            "the kernel command line does not create the root dm-verity device dm-0")
    mounts = [line.split() for line in parts["mount"].splitlines() if line.strip()]
    root = [m for m in mounts if len(m) > 5 and m[4] == "/"]
    require(root, "no mount of / in the capture")
    fields = root[0]
    require(fields[2] == parts["dev"].strip(), f"/ is on device {fields[2]}, not dm-0 ({parts['dev'].strip()})")
    require("ro" in fields[5].split(","), f"/ is not read-only: {fields[5]}")
    print(f"dm-verity: / is the read-only dm-0 'root' (device {fields[2]}), created with verity on the kernel command line")


def sections(text):
    out, name = {}, None
    for line in text.splitlines():
        head = re.fullmatch(r"==(addr|route|dns rc=([0-9]+))==", line.strip())
        if head:
            name = "dns" if head.group(1).startswith("dns") else head.group(1)
            out[name] = []
            if name == "dns":
                out["dns_rc"] = int(head.group(2))
            continue
        if name:
            out[name].append(line)
    return out


def cmd_check_network_isolated(args):
    """Capture: '==addr==', the `ip -o addr` lines, '==route==', the `ip route` lines,
    '==dns rc=<n>==', the nslookup output. Only loopback, no route, and DNS fails."""
    got = sections(read_input(args.file))
    if not {"addr", "route", "dns"} <= set(got):
        raise Unknown("the capture has no ==addr==, ==route== and ==dns rc=<n>== sections")
    devices = {line.split()[1].rstrip(":") for line in got["addr"] if len(line.split()) > 1}
    require(devices == {"lo"}, f"the pod has interfaces {sorted(devices) or 'none'}, want lo only")
    routes = [line for line in got["route"] if line.strip()]
    require(not routes, f"the pod has routes: {routes[:1]}")
    require(got["dns_rc"] != 0, "a DNS lookup succeeded")
    print("network-isolated pod: only lo, no route, the DNS lookup fails")


def cmd_pod_in_eni(args):
    """The pod IP is a secondary private IP of an ENI attached to the node's instance."""
    ip = str(ipaddress.ip_address(args.pod_ip))
    enis = read_json(args.file).get("NetworkInterfaces", [])
    if not enis:
        raise Unknown("no network interface in the input")
    for eni in enis:
        for addr in eni.get("PrivateIpAddresses", []):
            if addr.get("PrivateIpAddress") == ip:
                require(not addr.get("Primary"), f"{ip} is the primary IP of {eni['NetworkInterfaceId']}")
                device = eni.get("Attachment", {}).get("DeviceIndex")
                print(f"pod IP {ip}: secondary IP of {eni['NetworkInterfaceId']} (device index {device})")
                return
    raise Reject(f"pod IP {ip} is not an IP of any ENI of the node")


KPR_EXPECTED = {"Status": "True", "Socket LB": "Enabled", "Socket LB Coverage": "Hostns-only"}


def cmd_kpr_status(args):
    """`cilium-dbg status --verbose` (file) and `cilium-dbg config --all` (--config) of one
    agent: ENI IPAM, native routing, kube-proxy replacement True, and the socket load balancer
    for the host namespace only."""
    text = read_input(args.file)
    top, details, inside = None, {}, False
    for line in text.splitlines():
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
    if top is None:
        raise Unknown("no KubeProxyReplacement line in the status")
    wrong = [] if top == "True" else [f"KubeProxyReplacement: {top}"]
    wrong += [f"{k}: {details.get(k, '(missing)')}" for k, v in KPR_EXPECTED.items() if details.get(k) != v]
    if not re.search(r"^Routing:\s+Network:\s+Native\b", text, re.M):
        wrong.append("routing is not native")
    # Cilium 1.20.5 prints "IPAM: IPv4: 1 IPAM pool(s) available," in the status, with no mode,
    # so the mode comes from the agent's own configuration (`cilium-dbg config --all`).
    config = read_input(args.config)
    if not re.search(r"^IPAM\s*:\s*eni\s*$", config, re.M):
        wrong.append("the agent configuration has no 'IPAM : eni'")
    if not re.search(r"^RoutingMode\s*:\s*native\s*$", config, re.M):
        wrong.append("the agent configuration has no 'RoutingMode : native'")
    require(not wrong, "; ".join(wrong))
    print(f"cilium status: ENI IPAM, native routing, kube-proxy replacement {top}, socket LB {details['Socket LB Coverage']}")
