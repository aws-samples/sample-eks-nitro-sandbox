#!/usr/bin/env python3
"""Host-readiness checks for the baked Ubuntu sandbox image, before bootstrap starts kubelet.

Run on the build host after the stages (setup.sh step 7), and again on a SECOND, fresh instance
launched from the finished AMI (scripts/verify-fresh-instance.sh), before EKS uses the AMI.
Every check runs and is reported; the script exits non-zero if any failed, so a broken image
fails loudly rather than joining the cluster.

Checks: host kernel release, /dev/nitro_enclaves, kernel BTF, a CMA reservation, vsock, TUN,
EROFS, AppArmor enabled with the sample's scoped profile loaded, containerd in the GA shim's
2.1.x to 2.3.x range (scripts/30-runtime-install.sh --check-containerd), both runtime handlers
in Canonical's containerd template (and in containerd's own migrated dump), the kubelet
endpoint at the CRI proxy, the kubelet-eks ordering drop-in, the shim config, the guest image
layout, mkfs.erofs 1.8.10 with zstd as a systemd service sees it, and every installed runtime
binary and image file against the archive's SHA256SUMS and packages/sources.lock.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import tomllib

SAMPLE_ROOT = Path(__file__).resolve().parent.parent
LOCK_FILE = Path(os.environ.get("LOCK_FILE", SAMPLE_ROOT / "packages" / "sources.lock"))
RUNTIME_SUMS = Path("/usr/local/share/ubuntu-ami-sample/runtime-SHA256SUMS")
IMAGE_DIR = Path(os.environ.get("NITRO_SANDBOX_IMAGE_DIR", "/var/lib/nitro-sandbox-images"))
DATA_DIR = os.environ.get("NITRO_SANDBOX_DATA_DIR", "/var/lib/nitro-sandbox")
LOCALVERSION = os.environ.get("KERNEL_LOCALVERSION", "-nitro-ga")
SHIM_DEBUG = os.environ.get("SHIM_DEBUG", "false") == "true"
PROFILE_NAME = "ubuntu-ami-sample-profile"
CRI_SOCK = "unix:///run/nitro-sandbox/cri-proxy.sock"


def lock_blocks(path):
    """Parse sources.lock into {id: {key: first-line value}}, the way scripts/lib/common.sh does."""
    blocks, cur = {}, None
    for line in path.read_text().splitlines():
        if not line.strip():
            cur = None
            continue
        if line.startswith("#") or line.startswith(" ") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        if key == "id":
            cur = blocks.setdefault(val, {})
        elif cur is not None:
            cur.setdefault(key, val)
    return blocks


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def is_char(path):
    try:
        return stat.S_ISCHR(os.stat(path).st_mode)
    except OSError:
        return False


def validate(template, bootstrap, shim):
    """The static containerd/kubelet/shim wiring, on already-parsed files."""
    cri = template["plugins"]["io.containerd.grpc.v1.cri"]["containerd"]
    assert cri.get("discard_unpacked_layers") is False, "discard_unpacked_layers must be false in the cri containerd table"
    for name in ("isolated-sandbox", "confidential-sandbox"):
        handler = cri["runtimes"][name]
        assert handler["runtime_type"] == "io.containerd.nitro-sandbox.v2", f"wrong runtime_type: {name}"
        assert handler["sandboxer"] == "shim", f"wrong sandboxer: {name}"
        assert handler["privileged_without_host_devices"] is True, f"host devices enabled: {name}"
    active = "\n".join(line for line in bootstrap.splitlines() if not line.lstrip().startswith("#"))
    endpoint_lines = [line for line in active.splitlines() if "container-runtime-endpoint=" in line]
    assert len(endpoint_lines) == 1, "expected one active kubelet endpoint assignment in bootstrap.sh"
    assert re.search(r"container-runtime-endpoint=([\"']?)unix:///run/nitro-sandbox/cri-proxy\.sock\1(?:\s|$)",
                     endpoint_lines[0]), "bootstrap.sh does not set the cri-proxy endpoint"
    assert shim["nitro_sandbox"] is True, "nitro_sandbox must be true"
    assert shim["kernel_path"] == f"{IMAGE_DIR}/latest.eif", "kernel_path must be the staged latest.eif"
    assert shim["rootfs_path"] == f"{IMAGE_DIR}/rootfs.ext4", "rootfs_path must be the rootfs.ext4 symlink"
    assert shim["cpu_overcommit"] is True, "cpu_overcommit must be true"
    assert shim["debug"] is SHIM_DEBUG, f"debug must be {str(SHIM_DEBUG).lower()} (SHIM_DEBUG)"
    assert not (str(shim["data_base_dir"]).rstrip("/") + "/").startswith(str(IMAGE_DIR) + "/"), \
        "data_base_dir must not be inside the guest image folder"


def checks(lock):
    kernel_ref = lock["linux-kernel-source"]["ref"]

    def kernel():
        rel = run(["uname", "-r"]).stdout.strip()
        assert rel == f"{kernel_ref}{LOCALVERSION}", f"uname -r is {rel}, expected {kernel_ref}{LOCALVERSION}"
        return rel

    def nitro_enclaves():
        assert is_char("/dev/nitro_enclaves"), "/dev/nitro_enclaves is not a character device"
        return "/dev/nitro_enclaves"

    def btf():
        size = Path("/sys/kernel/btf/vmlinux").stat().st_size
        assert size > 0, "/sys/kernel/btf/vmlinux is empty"
        return f"/sys/kernel/btf/vmlinux {size} bytes"

    def cma():
        m = re.search(r"^CmaTotal:\s+(\d+) kB", Path("/proc/meminfo").read_text(), re.M)
        assert m and int(m.group(1)) > 0, "no CMA reservation (CmaTotal is 0 or absent)"
        return f"CmaTotal {m.group(1)} kB"

    def vsock():
        assert is_char("/dev/vhost-vsock"), "/dev/vhost-vsock is not a character device"
        return "/dev/vhost-vsock"

    def tun():
        assert is_char("/dev/net/tun"), "/dev/net/tun is not a character device"
        return "/dev/net/tun"

    def erofs():
        run(["modprobe", "erofs"])
        assert re.search(r"\serofs$", Path("/proc/filesystems").read_text(), re.M), "erofs is not in /proc/filesystems"
        return "erofs in /proc/filesystems"

    def apparmor():
        assert Path("/sys/module/apparmor/parameters/enabled").read_text().strip() == "Y", "AppArmor is not enabled"
        assert Path("/etc/apparmor.d", PROFILE_NAME).is_file(), f"AppArmor profile file missing: {PROFILE_NAME}"
        loaded = Path("/sys/kernel/security/apparmor/profiles").read_text()
        assert any(line.split(" (")[0] == PROFILE_NAME for line in loaded.splitlines()), \
            f"AppArmor profile {PROFILE_NAME} is not loaded"
        return f"enabled; {PROFILE_NAME} loaded"

    def containerd():
        r = run(["bash", str(SAMPLE_ROOT / "scripts" / "30-runtime-install.sh"), "--check-containerd"])
        verdict = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr.strip()
        assert r.returncode == 0, verdict
        return verdict

    def wiring():
        validate(
            tomllib.loads(Path("/usr/local/share/eks/containerd-config.toml").read_text()),
            Path("/usr/local/share/eks/bootstrap.sh").read_text(),
            tomllib.loads(Path("/etc/containerd/nitro-sandbox.toml").read_text()),
        )
        with tempfile.TemporaryDirectory() as d:
            rendered = Path("/usr/local/share/eks/containerd-config.toml").read_text().replace("SANDBOX_IMAGE", "localhost/pause:3.10")
            Path(d, "r.toml").write_text(rendered)
            mig = run(["containerd", "-c", f"{d}/r.toml", "config", "migrate"])
            assert mig.returncode == 0, f"containerd config migrate failed: {mig.stderr.strip()[:200]}"
            Path(d, "v3.toml").write_text(mig.stdout)
            dump = run(["containerd", "-c", f"{d}/v3.toml", "config", "dump"])
            n = dump.stdout.count("io.containerd.nitro-sandbox.v2")
            assert n == 2, f"containerd config dump shows {n} nitro-sandbox handlers, expected 2"
        dropin = Path("/etc/systemd/system/snap.kubelet-eks.daemon.service.d/50-cri-proxy.conf").read_text()
        for line in ("Wants=cri-proxy.service", "After=cri-proxy.service", "PartOf=cri-proxy.service"):
            assert line in dropin, f"kubelet-eks drop-in lacks {line}"
        unit = Path("/etc/systemd/system/cri-proxy.service").read_text()
        assert "ExecStart=/usr/sbin/containerd-shim-nitro-sandbox-v2 cri-proxy --listen /run/nitro-sandbox/cri-proxy.sock" in unit, \
            "cri-proxy.service does not run the shim's cri-proxy on the expected socket"
        assert run(["systemctl", "is-enabled", "cri-proxy.service"]).stdout.strip() == "enabled", "cri-proxy.service is not enabled"
        return f"handlers 2 in migrated dump; endpoint {CRI_SOCK}; drop-in; cri-proxy.service enabled"

    def guest_image():
        link = IMAGE_DIR / "rootfs.ext4"
        assert link.is_symlink() and os.readlink(link) == "latest-disk.img", "rootfs.ext4 is not a symlink to latest-disk.img"
        for name in ("latest.eif", "latest-disk.img"):
            assert (IMAGE_DIR / name).stat().st_size > 0, f"{IMAGE_DIR}/{name} is missing or empty"
        return f"{IMAGE_DIR}: latest.eif, latest-disk.img, rootfs.ext4 -> latest-disk.img"

    def mkfs_erofs():
        want = lock["erofs-utils-source"]["ref"]
        assert run(["dpkg", "-s", "erofs-utils"]).returncode != 0, "Ubuntu's erofs-utils package is still installed"
        where = run(["systemd-run", "--wait", "--pipe", "--quiet", "--collect", "/bin/sh", "-c", "command -v mkfs.erofs"]).stdout.strip()
        assert where == "/usr/local/bin/mkfs.erofs", f"a systemd service finds mkfs.erofs at '{where}', expected /usr/local/bin/mkfs.erofs"
        ver = run(["/usr/local/bin/mkfs.erofs", "--version"])
        first = (ver.stdout or ver.stderr).strip().splitlines()[0] if (ver.stdout or ver.stderr).strip() else ""
        assert want in first, f"mkfs.erofs reports '{first}', expected {want}"
        with tempfile.TemporaryDirectory() as d:
            Path(d, "src").mkdir()
            Path(d, "src", "f").write_text("x\n")
            z = run(["systemd-run", "--wait", "--pipe", "--quiet", "--collect", "/bin/sh", "-c",
                     f"mkfs.erofs -zzstd,1 '{d}/t.img' '{d}/src' >/dev/null"])
            assert z.returncode == 0, "mkfs.erofs -zzstd,1 fails as a systemd service (no zstd?)"
        return f"{first}; zstd ok as a systemd service"

    def runtime_payloads():
        sums = {}
        for line in RUNTIME_SUMS.read_text().splitlines():
            m = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)", line)
            assert m, f"malformed line in {RUNTIME_SUMS}: {line!r}"
            assert m.group(2) not in sums, f"{RUNTIME_SUMS} lists {m.group(2)} twice"
            sums[m.group(2)] = m.group(1)
        payloads = {b["file"]: b for b in lock.values() if b.get("kind") == "runtime-payload"}
        assert set(sums) == set(payloads), f"{RUNTIME_SUMS} and sources.lock list different payloads"
        checked = []
        for name, b in sorted(payloads.items()):
            assert sums[name] == b["sha256"], f"{name}: SHA256SUMS and sources.lock disagree"
            if b.get("install", "none") == "none":
                continue
            dest, mode = b["install"].split()
            st = os.stat(dest)
            assert stat.S_ISREG(st.st_mode), f"{dest} is not a regular file"
            assert stat.S_IMODE(st.st_mode) == int(mode, 8), f"{dest} has mode {oct(stat.S_IMODE(st.st_mode))}, expected {mode}"
            got = sha256(dest)
            assert got == sums[name], f"{dest} has SHA-256 {got}, not its SHA256SUMS line {sums[name]}"
            checked.append(dest)
        return f"{len(checked)} installed files match SHA256SUMS and sources.lock"

    return [
        ("host_kernel", kernel), ("nitro_enclaves_device", nitro_enclaves), ("btf", btf), ("cma", cma),
        ("vsock", vsock), ("tun", tun), ("erofs", erofs), ("apparmor", apparmor),
        ("containerd_version", containerd), ("runtime_wiring", wiring), ("guest_image", guest_image),
        ("mkfs_erofs", mkfs_erofs), ("runtime_payloads", runtime_payloads),
    ]


def main():
    results, failed = {}, []
    for name, check in checks(lock_blocks(LOCK_FILE)):
        try:
            results[name] = {"ok": True, "detail": check()}
        except Exception as e:  # every check runs; each failure is reported, then the exit is non-zero
            results[name] = {"ok": False, "detail": f"{type(e).__name__}: {e}"}
            failed.append(name)
    print(json.dumps({"image_configuration": "FAIL" if failed else "PASS", "failed": failed, "checks": results}, indent=2))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
