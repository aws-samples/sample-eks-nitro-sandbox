#!/usr/bin/env python3
"""Structural checks of the node's containerd, kubelet and systemd wiring, shared by
scripts/31-wire-containerd.sh (which writes the files and checks them) and scripts/verify-image.py
(which checks them again on a fresh instance). Each check parses the file and reads the ACTIVE
setting in the place it must be, never a substring anywhere in the text, so a comment or a value
in the wrong table cannot satisfy it.

  image_checks.py template FILE    Canonical's containerd template (config version 2)
  image_checks.py dump FILE        `containerd config dump` output after `config migrate`
  image_checks.py bootstrap FILE   /usr/local/share/eks/bootstrap.sh
  image_checks.py dropin FILE      snap.kubelet-eks.daemon.service.d/50-cri-proxy.conf
  image_checks.py cri-unit FILE    /etc/systemd/system/cri-proxy.service
  image_checks.py shim FILE        /etc/containerd/nitro-sandbox.toml (SHIM_DEBUG, image and data dirs)
  image_checks.py eif-kernel FILE  print the guest kernel release inside an EIF (its bzImage header)

Exit 0 when the file holds, 1 with a FAIL line naming what is wrong. Raises CheckFailed (never a
bare `assert`, which `python3 -O` would remove). Needs Python 3.11+ (tomllib).
"""
import os
import shlex
import sys

try:
    import tomllib
except ImportError:  # pragma: no cover - the build host and the node run Python 3.12
    tomllib = None

HANDLERS = ("isolated-sandbox", "confidential-sandbox")
RUNTIME_TYPE = "io.containerd.nitro-sandbox.v2"
CRI_SOCK = "unix:///run/nitro-sandbox/cri-proxy.sock"
SHIM = "/usr/sbin/containerd-shim-nitro-sandbox-v2"
# The shim config values scripts/30-runtime-install.sh writes: the keys the Amazon EKS User Guide's
# shim config sets (kernel_path, kubeconfig_path, format_overlay) and the ones AWS's own provisioner
# sets explicitly (cpu_overcommit, pcie_slots 110, data_base_dir NITRO_SANDBOX_DATA_DIR, default
# below, scripts/lib/common.sh), plus debug from SHIM_DEBUG. No other key: the GA shim's config has
# no rootfs_path and no nitro_sandbox (the preview shim's keys), so check_shim refuses any key not
# listed here rather than let a stale one sit in the file.
PCIE_SLOTS = 110
DATA_DIR = "/var/lib/nitro-sandbox"
KUBECONFIG_PATH = "/var/lib/kubelet/kubeconfig"
SHIM_KEYS = ("kernel_path", "kubeconfig_path", "format_overlay", "cpu_overcommit", "pcie_slots",
             "data_base_dir", "debug")


class CheckFailed(Exception):
    pass


def require(cond, msg):
    if not cond:
        raise CheckFailed(msg)


def toml(text, what):
    require(tomllib is not None, "Python 3.11 or later (tomllib) is required for the TOML checks")
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        raise CheckFailed(f"{what} is not valid TOML: {e}")


def handler_ok(h, name, label="handler"):
    require(isinstance(h, dict), f"runtime handler {name} is missing")
    require(h.get("runtime_type") == RUNTIME_TYPE, f"{label} {name} runtime_type is {h.get('runtime_type')!r}, must be {RUNTIME_TYPE!r}")
    require(h.get("sandboxer") == "shim", f"{label} {name} sandboxer is {h.get('sandboxer')!r}, must be 'shim'")
    require(h.get("privileged_without_host_devices") is True,
            f"{label} {name} privileged_without_host_devices is {h.get('privileged_without_host_devices')!r}, must be true")


def check_template(text):
    doc = toml(text, "the containerd template")
    require(doc.get("version") == 2, f"the containerd template is version {doc.get('version')!r}, must be 2")
    cri = (((doc.get("plugins") or {}).get("io.containerd.grpc.v1.cri") or {}).get("containerd"))
    require(isinstance(cri, dict), 'the template has no [plugins."io.containerd.grpc.v1.cri".containerd] table')
    require("discard_unpacked_layers" in cri, 'discard_unpacked_layers is not set in [plugins."io.containerd.grpc.v1.cri".containerd]')
    require(cri["discard_unpacked_layers"] is False, f"discard_unpacked_layers is {cri['discard_unpacked_layers']!r} in the cri containerd table, must be false")
    for n in HANDLERS:
        handler_ok((cri.get("runtimes") or {}).get(n), n)
    return "template: version 2, discard_unpacked_layers = false in the cri containerd table, both handlers"


def find_runtimes(node, path=()):
    """Every (path, runtimes-table) where a dict key path ends in ...containerd.runtimes."""
    if isinstance(node, dict):
        for k, v in node.items():
            p = path + (k,)
            if k == "runtimes" and len(p) >= 2 and p[-2] == "containerd" and isinstance(v, dict):
                yield p, v
            yield from find_runtimes(v, p)


def check_dump(text):
    doc = toml(text, "the containerd config dump")
    found = list(find_runtimes(doc))
    require(found, "the containerd config dump has no containerd runtimes table")
    for n in HANDLERS:
        hs = [rt[n] for _, rt in found if n in rt]
        require(len(hs) == 1, f"the containerd config dump has {len(hs)} definitions of handler {n}, expected exactly 1")
        handler_ok(hs[0], n, "dumped handler")
    return "dump: both handlers, each defined once with the nitro-sandbox runtime_type, sandboxer and privileged_without_host_devices"


def check_bootstrap(text):
    """The endpoint must be set by the active `snap set kubelet-eks` command. Each line naming it is
    split into shell words with comments removed (shlex, comments=True), so a value after `#`, or on
    a commented-out line, does not count."""
    key = "container-runtime-endpoint="
    sets = []
    for line in text.replace("\\\n", " ").splitlines():
        if key not in line:
            continue
        try:
            words = shlex.split(line, comments=True)
        except ValueError as e:
            raise CheckFailed(f"bootstrap.sh line {line.strip()!r} cannot be split into shell words: {e}")
        for i, w in enumerate(words):
            if w.startswith(key):
                sets.append((words[:i], w[len(key):]))
    require(len(sets) == 1, f"bootstrap.sh has {len(sets)} active container-runtime-endpoint assignments, expected 1")
    before, value = sets[0]
    require(any(before[i:i + 3] == ["snap", "set", "kubelet-eks"] for i in range(len(before))),
            "bootstrap.sh sets container-runtime-endpoint outside a `snap set kubelet-eks` command")
    require(value == CRI_SOCK, f"bootstrap.sh sets container-runtime-endpoint to {value!r}, must be {CRI_SOCK!r}")
    return f"bootstrap.sh: one active endpoint, {CRI_SOCK}"


def parse_unit(text):
    """systemd unit: {section: {key: [values]}}, comment (# ;) and blank lines dropped."""
    out, sec = {}, None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line[0] in "#;":
            continue
        if line.startswith("[") and line.endswith("]"):
            sec = line[1:-1]
            out.setdefault(sec, {})
            continue
        if sec is None or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[sec].setdefault(k.strip(), []).append(v.strip())
    return out


def check_dropin(text):
    unit = parse_unit(text).get("Unit") or {}
    for key in ("Wants", "After", "PartOf"):
        vals = " ".join(unit.get(key, [])).split()
        require("cri-proxy.service" in vals, f"the kubelet-eks drop-in has no active [Unit] {key}=cri-proxy.service")
    return "drop-in: [Unit] Wants, After and PartOf cri-proxy.service"


def check_cri_unit(text):
    svc = parse_unit(text).get("Service") or {}
    want = f"{SHIM} cri-proxy --listen /run/nitro-sandbox/cri-proxy.sock --containerd /run/containerd/containerd.sock"
    require(svc.get("ExecStart") == [want], f"cri-proxy.service ExecStart is {svc.get('ExecStart')!r}, must be [{want!r}]")
    return "cri-proxy.service: ExecStart is the shim's cri-proxy on the expected socket"


def check_shim(text, image_dir="/var/lib/nitro-sandbox-images", debug=False, data_dir=DATA_DIR):
    shim = toml(text, "the shim config")
    extra = sorted(set(shim) - set(SHIM_KEYS))
    require(not extra, f"the shim config sets {extra}, which the shim does not read (allowed: {', '.join(SHIM_KEYS)})")
    require(shim.get("kernel_path") == f"{image_dir}/latest.eif",
            f"kernel_path is {shim.get('kernel_path')!r}, must be the staged {image_dir}/latest.eif")
    require(type(shim.get("pcie_slots")) is int and shim["pcie_slots"] == PCIE_SLOTS,
            f"pcie_slots is {shim.get('pcie_slots')!r}, must be {PCIE_SLOTS}")
    require(shim.get("cpu_overcommit") is True, "cpu_overcommit must be true")
    require(shim.get("data_base_dir") == data_dir,
            f"data_base_dir is {shim.get('data_base_dir')!r}, must be {data_dir!r} (NITRO_SANDBOX_DATA_DIR)")
    require(shim.get("kubeconfig_path") == KUBECONFIG_PATH,
            f"kubeconfig_path is {shim.get('kubeconfig_path')!r}, must be {KUBECONFIG_PATH!r}")
    require(shim.get("format_overlay") is True, f"format_overlay is {shim.get('format_overlay')!r}, must be true")
    require(shim.get("debug") is debug, f"debug must be {str(debug).lower()} (SHIM_DEBUG)")
    require_apart(os.path.dirname(str(shim.get("kernel_path", ""))), str(shim.get("data_base_dir", "")))
    return (f"shim config: latest.eif, kubeconfig_path, format_overlay, cpu_overcommit, pcie_slots={PCIE_SLOTS}, "
            f"data_base_dir, debug={str(debug).lower()}, no other key")


def require_apart(image_dir, data_dir):
    """The guest image folder (kernel_path's folder) and data_base_dir must be apart in both directions:
    the Amazon EKS User Guide keeps the EIF and the disk outside data_base_dir, and the shim's data must
    not sit among the guest image files. Compared canonical, as whole path components."""
    require(image_dir.startswith("/") and data_dir.startswith("/"),
            f"the guest image folder {image_dir!r} and data_base_dir {data_dir!r} must both be absolute")
    img, dat = os.path.realpath(image_dir), os.path.realpath(data_dir)
    require(img != dat, f"the guest image folder and data_base_dir are the same folder ({img}); the shim needs them apart")
    require(not (img + "/").startswith(dat.rstrip("/") + "/"),
            f"the guest image folder {img} is inside data_base_dir {dat}; the guest image must stay outside it")
    require(not (dat + "/").startswith(img.rstrip("/") + "/"),
            f"data_base_dir {dat} is inside the guest image folder {img}; the shim needs them apart")


def eif_kernel_release(data):
    """The guest kernel release (what uname -r prints in the guest) inside an Enclave Image File.

    The public EIF layout, big-endian: magic b".eif", version u16, flags u16, default_mem u64,
    default_cpus u64, reserved u16, num_sections u16, then 32 u64 section offsets and 32 u64
    section sizes. Each section starts with section_type u16, flags u16, section_size u64; type 1
    is the kernel, a bzImage. Its setup header (magic b"HdrS" at 0x202) holds at 0x20E the offset,
    less 0x200, of the kernel version string, "<release> (<builder>) #1 ..."; the release is its
    first word."""
    import struct
    require(len(data) >= 540 and data[:4] == b".eif", "latest.eif is not an Enclave Image File (no .eif magic)")
    nsec = struct.unpack(">H", data[26:28])[0]
    require(1 <= nsec <= 32, f"latest.eif says it has {nsec} sections")
    offs = struct.unpack(">32Q", data[28:284])
    kernels = []
    for i in range(nsec):
        o = offs[i]
        require(o + 12 <= len(data), f"latest.eif section {i} starts past the end of the file")
        stype, _flags, size = struct.unpack(">HHQ", data[o:o + 12])
        if stype == 1:
            kernels.append(data[o + 12:o + 12 + size])
    require(len(kernels) == 1, f"latest.eif has {len(kernels)} kernel sections, expected 1")
    k = kernels[0]
    require(len(k) > 0x210 and k[0x202:0x206] == b"HdrS", "latest.eif's kernel section has no bzImage setup header")
    ptr = struct.unpack("<H", k[0x20E:0x210])[0] + 0x200
    require(ptr < len(k), "latest.eif's kernel version pointer is past the end of its kernel section")
    words = k[ptr:ptr + 256].split(b"\0", 1)[0].decode("ascii", "replace").split()
    require(words, "latest.eif's kernel version string is empty")
    return words[0]


CHECKS = {"template": check_template, "dump": check_dump, "bootstrap": check_bootstrap,
          "dropin": check_dropin, "cri-unit": check_cri_unit}


def main(argv):
    if len(argv) == 3 and argv[1] == "eif-kernel":
        try:
            with open(argv[2], "rb") as f:
                print(eif_kernel_release(f.read()))
        except (OSError, CheckFailed) as e:
            print(f"FAIL: {argv[2]}: {e}", file=sys.stderr)
            return 1
        return 0
    if len(argv) != 3 or argv[1] not in list(CHECKS) + ["shim"]:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        with open(argv[2]) as f:
            text = f.read()
        if argv[1] == "shim":
            msg = check_shim(text, os.environ.get("NITRO_SANDBOX_IMAGE_DIR", "/var/lib/nitro-sandbox-images"),
                             os.environ.get("SHIM_DEBUG", "false") == "true",
                             os.environ.get("NITRO_SANDBOX_DATA_DIR", DATA_DIR))
        else:
            msg = CHECKS[argv[1]](text)
    except (OSError, CheckFailed) as e:
        print(f"FAIL: {argv[2]}: {e}", file=sys.stderr)
        return 1
    print(f"ok: {msg}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
