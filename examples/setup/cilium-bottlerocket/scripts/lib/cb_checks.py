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
# The reservation line of the Nitro Enclaves driver, from the kernel patch of the AL2023 SRPM that
# the Bottlerocket 6.18 kernel uses (0144-nitro_enclaves-Amazon-Nitro-Enclaves-extension-port-.patch):
#   pr_info("nitro_enclaves: CMA pool: %llu MiB reserved in %d region(s), %llu MiB requested\n")
# and the lines it prints when it reserves nothing ("EFI table absent, skipping CMA reservation",
# "mempool=...@<node> resolved to 0, skipping", and "no reserved CMA pool on this boot"). A
# "CMA region ... not reserved: ...; truncating the pool here" line is not a failure: the driver
# keeps the regions that it reserved, and the CMA pool line reports them. The kernel's echo of
# the command line ("Kernel command line: ... nitro_enclaves.mempool=...") matches neither pattern.
MEMPOOL_RESERVED = re.compile(r"nitro_enclaves: CMA pool: ([0-9]+) MiB reserved in ([0-9]+) region\(s\), ([0-9]+) MiB requested")
MEMPOOL_SKIPPED = re.compile(
    r"nitro_enclaves: (?:.*skipping CMA reservation|mempool=\S+ resolved to 0, skipping|no reserved CMA pool on this boot)")
MEMPOOL_ARG = "nitro_enclaves.mempool=95%-1G"
KUBELET_KUBECONFIG = "/etc/kubernetes/kubelet/kubeconfig"
NO_ENTRIES = re.compile(r"^-- No entries --$")
SECONDARY_ENI = re.compile(r"eth[1-9][0-9]*")


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
    """The build-time parameter is on the command line, and the driver's own reservation line
    reports more than 0 MiB in at least one region. A skip or a failed region is a rejection."""
    cmdline = read_input(args.cmdline)
    log = read_input(args.kernel_log)
    require(MEMPOOL_ARG in cmdline.split(), f"the kernel command line has no {MEMPOOL_ARG}")
    skipped = [line.strip() for line in log.splitlines() if MEMPOOL_SKIPPED.search(line)]
    require(not skipped, f"the driver did not reserve the pool: {skipped[:1]}")
    found = [(line.strip(), m) for line in log.splitlines() for m in [MEMPOOL_RESERVED.search(line)] if m]
    require(found, "the kernel log has no 'nitro_enclaves: CMA pool: ... MiB reserved' line")
    m = found[-1][1]
    require(int(m.group(1)) > 0 and int(m.group(2)) > 0, f"the driver reserved {m.group(1)} MiB in {m.group(2)} region(s)")
    print(f"kernel command line has {MEMPOOL_ARG}; driver: {m.group(0)}")


def cmd_check_kubeconfig_path(args):
    """The shim reads the kubelet kubeconfig of Bottlerocket: kubeconfig_path in
    nitro-sandbox.toml is /etc/kubernetes/kubelet/kubeconfig, and that file is on the node and
    not empty (capture 'KUBECONFIG_BYTES=<n>' or 'KUBECONFIG_ABSENT'; only stat reads it)."""
    found = re.findall(r'^\s*kubeconfig_path\s*=\s*"([^"]*)"\s*(?:#.*)?$', read_input(args.shim_toml), re.M)
    require(len(found) == 1, f"nitro-sandbox.toml has {len(found)} kubeconfig_path lines")
    require(found[0] == KUBELET_KUBECONFIG, f"kubeconfig_path is {found[0]!r}, want {KUBELET_KUBECONFIG}")
    capture = read_input(args.kubeconfig).strip()
    require(capture != "KUBECONFIG_ABSENT", f"{KUBELET_KUBECONFIG} is not on the node")
    size = re.fullmatch(r"KUBECONFIG_BYTES=([0-9]+)", capture)
    if not size:
        raise Unknown("the kubeconfig capture is not KUBECONFIG_BYTES=<n> or KUBECONFIG_ABSENT")
    require(int(size.group(1)) > 0, f"{KUBELET_KUBECONFIG} is empty")
    print(f"kubeconfig_path {found[0]}: present on the node ({size.group(1)} bytes)")


def cmd_check_mkfs_erofs(args):
    """`mkfs.erofs -V` of the host (erofs-utils) lists zstd in its "available compressors" line."""
    text = read_input(args.file)
    version = re.search(r"^mkfs\.erofs \(erofs-utils\) (\S+)$", text, re.M)
    found = re.search(r"^available compressors: (.*)$", text, re.M)
    if not version or not found:
        raise Unknown("the capture is not the 'mkfs.erofs -V' output of erofs-utils")
    names = [n.strip() for n in found.group(1).split(",") if n.strip()]
    require("zstd" in names, f"mkfs.erofs {version.group(1)} has no zstd compressor (it has: {', '.join(names) or 'none'})")
    print(f"mkfs.erofs {version.group(1)} on the host: compressors {', '.join(names)}")


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


def cmd_check_max_pods(args):
    """The max-pods that setup.sh derived from the instance type (--want) against each input
    given: the launch template max-pods and the node's capacity pods."""
    seen = {}
    if args.launch_template:
        seen["launch template max-pods"] = lt_max_pods(read_json(args.launch_template))
    if args.node:
        raw = read_json(args.node).get("status", {}).get("capacity", {}).get("pods")
        if raw is None or re.fullmatch(r"[0-9]+", str(raw)) is None:
            raise Unknown(f"the node capacity pods is {raw!r}, not a number")
        seen["node capacity pods"] = int(raw)
    if not seen:
        raise Unknown("check-max-pods got no input to compare")
    wrong = [f"{k}={v!r}" for k, v in seen.items() if v != args.want]
    require(not wrong, f"the derived max-pods is {args.want} but " + ", ".join(wrong))
    print(f"max-pods: derived {args.want} equals " + ", ".join(f"{k} ({v})" for k, v in seen.items()))


SLOT_LINE = re.compile(r"^(pcie_slots_total|pcie_slots|max_pcie_devices)=([0-9]+)$")
ADVERTISED = re.compile(r"advertising ([0-9]+) nitro-sandbox slots \(target=([0-9]+)\)")


def cmd_check_slots(args):
    """SANDBOX_SLOTS against the slot pool: it must not be above the driver's pcie_slots_total,
    and the driver's pcie_slots and the node's eks.amazonaws.com/nitro-sandbox capacity must both
    equal it. The runtime's own "advertising N nitro-sandbox slots (target=M)" line, when the
    journal has one, must say N = SANDBOX_SLOTS. An unreadable value is exit 2."""
    slots = int_setting("SANDBOX_SLOTS", 1, 250)
    driver = dict(m.groups() for line in read_input(args.driver).splitlines() for m in [SLOT_LINE.match(line.strip())] if m)
    missing = [k for k in ("pcie_slots_total", "pcie_slots", "max_pcie_devices") if k not in driver]
    if missing:
        raise Unknown(f"the driver capture has no {', '.join(missing)}")
    total, current = int(driver["pcie_slots_total"]), int(driver["pcie_slots"])
    node = read_json(args.node).get("status", {})
    raw = (node.get("capacity") or {}).get("eks.amazonaws.com/nitro-sandbox")
    if raw is None or re.fullmatch(r"[0-9]+", str(raw)) is None:
        raise Unknown(f"the node capacity eks.amazonaws.com/nitro-sandbox is {raw!r}, not a number")
    capacity = int(raw)
    wrong = []
    if slots > total:
        wrong.append(f"SANDBOX_SLOTS={slots} is above the slot pool of the instance, pcie_slots_total={total}")
    if current != slots:
        wrong.append(f"the driver's pcie_slots is {current}")
    if capacity != slots:
        wrong.append(f"the node capacity eks.amazonaws.com/nitro-sandbox is {capacity}")
    runtime = ""
    if args.journal:
        found = [m for line in read_input(args.journal).splitlines() for m in [ADVERTISED.search(line)] if m]
        if found:
            n, target = found[-1].groups()
            runtime = f", runtime: advertising {n} (target={target})"
            if int(n) != slots:
                wrong.append(f"the runtime advertised {n} slots")
    require(not wrong, f"SANDBOX_SLOTS={slots}, but " + "; ".join(wrong))
    print(f"slots: SANDBOX_SLOTS={slots}, pcie_slots_total={total}, driver pcie_slots={current}, "
          f"node capacity eks.amazonaws.com/nitro-sandbox={capacity}, max_pcie_devices={driver['max_pcie_devices']}{runtime}")


def cmd_check_density(args):
    """SANDBOX_SLOTS against each input given: the SandboxSlots tag of the AMI and pcie_slots in
    the shim configuration of the node. max-pods is check-max-pods; the slot pool is check-slots."""
    slots = args.slots if args.slots is not None else int_setting("SANDBOX_SLOTS", 1, 250)
    seen = {}
    if args.ami_tags:
        images = read_json(args.ami_tags).get("Images", [])
        require(len(images) == 1, f"expected one image, got {len(images)}")
        tags = {t["Key"]: t["Value"] for t in images[0].get("Tags", [])}
        seen["AMI tag SandboxSlots"] = tags.get("SandboxSlots")
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
        lines = [line for line in read_input(path).splitlines() if line.strip()]
        # journalctl prints "-- No entries --" when it reads nothing: that is no evidence.
        if not [line for line in lines if not NO_ENTRIES.match(line.strip())]:
            raise Unknown(f"{path} has no log entry")
        found += [line.strip() for line in lines if AVC_DENIED.search(line)]
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


def cmd_check_networkd(args):
    """Each eth[1-9]* interface (a secondary ENI that Cilium manages) must be unmanaged by
    systemd-networkd. The capture is the one that networkd_states reads."""
    admin = networkd_states(read_input(args.file))
    secondary = sorted(n for n in admin if SECONDARY_ENI.fullmatch(n))
    if not secondary:
        raise Unknown("the node has no secondary ENI (eth1 or later) yet; nothing to check")
    wrong = [f"{n} is {admin[n] or 'not listed'}" for n in secondary if admin[n] != "unmanaged"]
    require(not wrong, "systemd-networkd manages a Cilium ENI: " + ", ".join(wrong))
    print("systemd-networkd: " + ", ".join(f"{n} unmanaged" for n in secondary))


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


def cmd_check_eni_capture(args):
    """Capture A, taken once an endpoint uses an ENI after eth0. For each eth1 and later link:
    networkd lists it as unmanaged; no address has the dynamic flag; each IPv4 address is in the
    CiliumNode ENI record with that MAC, and each IPv6 address is link-local; no route has proto
    dhcp or ra; the IPv4 routes are the ones that Cilium 1.20 sets for that ENI
    (pkg/datapath/linux/routing: table 10 + the ENI number, "<gw> dev <link> scope link" and
    "default via <gw>", <gw> the first address of the ENI subnet), apart from the kernel routes of
    an address of the record; each rule that looks up that table is from an address of the ENI,
    and no rule sends an address of the ENI to the table of another ENI. At least one link must
    carry the Cilium routes and a rule from one of its addresses, or there is nothing to prove
    (exit 2)."""
    state, rules = eni_state(read_input(args.capture))
    if not state:
        raise Unknown("no eth1 or later interface in the capture")
    admin = networkd_states(read_input(args.networkd))
    by_mac = ciliumnode_enis(args.ciliumnode)
    wrong, proved = [], []
    for name, link in sorted(state.items()):
        if admin.get(name) != "unmanaged":
            wrong.append(f"{name} is {admin.get(name) or 'not listed'} in networkd")
        wrong += [f"{name} has a dynamic address: {line[:120]}" for line in link["dynamic"]]
        wrong += [f"{name} has the IPv6 address {a}, which is not link-local" for a in link["inet6"]
                  if not ipaddress.ip_interface(a).ip.is_link_local]
        wrong += [f"{name} has a networkd route: {r}" for r in link["routes"] + link["routes6"]
                  if re.search(r"\bproto (dhcp|ra|16|9)\b", r)]
        eni = by_mac.get(link["mac"])
        if eni is None:
            wrong.append(f"{name} ({link['mac']}) is not an ENI of the CiliumNode")
            continue
        wrong += [f"{name} has the address {a}, which is not in the ENI record {eni.get('id')}"
                  for a in link["inet"] if not in_eni(a.split("/")[0], eni)]
        cidr = (eni.get("subnet") or {}).get("cidr")
        if not cidr:
            raise Unknown(f"the CiliumNode ENI record {eni.get('id')} has no subnet CIDR")
        gw = str(ipaddress.ip_network(cidr, strict=False).network_address + 1)
        table = str(10 + int(eni.get("number") or 0))
        cilium = {f"default via {gw} dev {name} table {table}", f"{gw} dev {name} table {table} scope link"}
        seen = set()
        for route in link["routes"]:
            base = re.sub(r" proto \S+", "", route)
            src = re.search(r"\bsrc (\S+)", route)
            if base in cilium:
                seen.add(base)
            elif "table local" in route or (
                    " table " not in route and "proto kernel" in route and src and in_eni(src.group(1), eni)):
                continue   # the kernel routes of an address that the record has
            else:
                wrong.append(f"{name} has a route that Cilium does not set (table {table}, gateway {gw}): {route}")
        endpoint = [r for r in rules if re.search(rf"\blookup {table}\b", r)]
        wrong += [f"{name}: the rule '{r}' looks up table {table}, but its source is not an address of {eni.get('id')}"
                  for r in endpoint if not in_eni(rule_source(r), eni)]
        for rule in rules:
            other = re.search(r"\blookup ([0-9]+)\b", rule)
            if in_eni(rule_source(rule), eni) and other and int(other.group(1)) >= 10 and other.group(1) != table:
                wrong.append(f"{name}: the rule '{rule}' sends an address of {eni.get('id')} to another ENI table")
        # Cilium keeps the routes of a table after its last endpoint goes (routing.Delete removes
        # only the rules), so both routes and no rule is a Cilium state too; it proves nothing.
        if seen == cilium and endpoint:
            proved.append(f"{name} unmanaged, table {table} via {gw}, {len(endpoint)} endpoint rule(s)")
        elif (seen and seen != cilium) or endpoint:
            wrong.append(f"{name}: table {table} has {len(seen)} of the 2 Cilium routes and {len(endpoint)} rule(s)")
    require(not wrong, "; ".join(wrong))
    if not proved:
        raise Unknown("no endpoint uses an ENI after eth0, so no link has the Cilium per-ENI routes yet")
    print("Cilium ENIs as Cilium sets them: " + "; ".join(proved))


def cmd_check_eni_stable(args):
    """Capture A against capture B (the end of test.sh): for each eth1 and later link, the same
    MAC, addresses, IPv4 and IPv6 routes (all tables), and rules that look up its tables; each
    IPv4 address is in the CiliumNode ENI record with that MAC."""
    before, rules_before = eni_state(read_input(args.before))
    after, rules_after = eni_state(read_input(args.after))
    if not after:
        raise Unknown("no eth1 or later interface in the capture after the event")
    by_mac = ciliumnode_enis(args.ciliumnode)
    wrong = []
    for name in sorted(set(before) | set(after)):
        if name not in before or name not in after:
            wrong.append(f"{name} is in only one capture")
            continue
        b, a = before[name], after[name]
        for key, what in (("mac", "MAC"), ("inet", "IPv4 addresses"), ("inet6", "IPv6 addresses"),
                          ("routes", "IPv4 routes"), ("routes6", "IPv6 routes")):
            if b[key] != a[key]:
                change = f"{b[key]} -> {a[key]}" if key == "mac" else str(sorted(set(b[key]) ^ set(a[key]))[:3])
                wrong.append(f"{name} {what} changed: {change}")
        tables = (set(b["tables"]) | set(a["tables"])) - {"local", "main"}
        rb = [r for r in rules_before if any(re.search(rf"\blookup {re.escape(t)}\b", r) for t in tables)]
        ra = [r for r in rules_after if any(re.search(rf"\blookup {re.escape(t)}\b", r) for t in tables)]
        if rb != ra:
            wrong.append(f"{name} rules for tables {sorted(tables)} changed: {sorted(set(rb) ^ set(ra))[:3]}")
        eni = by_mac.get(a["mac"])
        if eni is None:
            wrong.append(f"{name} ({a['mac']}) is not an ENI of the CiliumNode")
            continue
        stray = [x for x in a["inet"] if not in_eni(x.split("/")[0], eni)]
        if stray:
            wrong.append(f"{name} has addresses {stray} that are not in the ENI record {eni.get('id')}")
    require(not wrong, "; ".join(wrong))
    print("Cilium ENIs unchanged by networkd: " + ", ".join(
        f"{n} ({len(after[n]['inet'])} addresses, {len(after[n]['routes'])} routes, tables {','.join(after[n]['tables']) or '-'})"
        for n in sorted(after)))


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
