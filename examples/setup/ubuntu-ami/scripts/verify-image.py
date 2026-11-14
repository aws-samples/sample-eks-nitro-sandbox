#!/usr/bin/env python3
"""Host-readiness checks for the baked Ubuntu sandbox image, before bootstrap starts kubelet.

Run on the build host after the stages (setup.sh step 7), and again on a SECOND, fresh instance
launched from the finished AMI (scripts/verify-fresh-instance.sh), before EKS uses the AMI.
Every check runs and is reported; the script exits non-zero if any failed, so a broken image
fails loudly rather than joining the cluster.

Checks: host kernel release, /dev/nitro_enclaves, kernel BTF, a CMA reservation, vsock, TUN,
EROFS, AppArmor enabled with the sample's scoped profile loaded in ENFORCE mode, containerd in
the 2.1.x to 2.3.x range this sample is validated on (scripts/30-runtime-install.sh
--check-containerd), both runtime handlers parsed from Canonical's containerd template and from
containerd's own migrated dump, the one active kubelet endpoint at the CRI proxy, the kubelet-eks
ordering drop-in and the cri-proxy unit (directives parsed, comments ignored), the shim config,
the guest image layout, the guest kernel release inside the staged EIF (read from its bzImage
header, equal to the pinned guest_kernel the AMI is tagged with), mkfs.erofs 1.8.10 with zstd as
a systemd service sees it, every file
packages/sources.lock installs on the node at its path, mode and pinned SHA-256, the runtime
release's signed manifest kept on the image (its signature verified again with the committed
public key, and its shim line), and the package holds 36-hold-packages.sh set (containerd and the
kernel meta-packages).

Every condition is checked with require() (scripts/lib/image_checks.py), which raises whatever
the interpreter's optimization level; `python3 -O` and PYTHONOPTIMIZE cannot turn a check off.
SYSROOT prefixes every fixed system path; it is a test hook, empty on every real host.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

SAMPLE_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SAMPLE_ROOT / "scripts" / "lib"))
import image_checks as ic  # noqa: E402
from image_checks import CheckFailed, require  # noqa: E402

SYSROOT = os.environ.get("SYSROOT", "")
LOCK_FILE = Path(os.environ.get("LOCK_FILE", SAMPLE_ROOT / "packages" / "sources.lock"))
IMAGE_DIR = os.environ.get("NITRO_SANDBOX_IMAGE_DIR", "/var/lib/nitro-sandbox-images")
DATA_DIR = os.environ.get("NITRO_SANDBOX_DATA_DIR", ic.DATA_DIR)
LOCALVERSION = os.environ.get("KERNEL_LOCALVERSION", "-nitro-ga")
SHIM_DEBUG = os.environ.get("SHIM_DEBUG", "false") == "true"
PROFILE_NAME = "ubuntu-ami-sample-profile"
# Where 30-runtime-install.sh keeps the runtime release's signed manifest and its signature.
SIGNED_DIR = "/usr/local/share/ubuntu-ami-sample/runtime"


def P(path):
    return Path(SYSROOT + path)


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


def checks(lock):
    kernel_ref = lock["linux-kernel-source"]["ref"]

    def kernel():
        rel = run(["uname", "-r"]).stdout.strip()
        require(rel == f"{kernel_ref}{LOCALVERSION}", f"uname -r is {rel!r}, expected {kernel_ref}{LOCALVERSION}")
        return rel

    def char_dev(path):
        def f():
            require(is_char(P(path)), f"{path} is not a character device")
            return path
        return f

    def btf():
        p = P("/sys/kernel/btf/vmlinux")
        size = p.stat().st_size if p.exists() else 0
        require(size > 0, "/sys/kernel/btf/vmlinux is missing or empty")
        return f"/sys/kernel/btf/vmlinux {size} bytes"

    def cma():
        m = re.search(r"^CmaTotal:\s+(\d+) kB", P("/proc/meminfo").read_text(), re.M)
        require(m is not None and int(m.group(1)) > 0, "no CMA reservation (CmaTotal is 0 or absent)")
        return f"CmaTotal {m.group(1)} kB"

    def erofs():
        run(["modprobe", "erofs"])
        require(re.search(r"\serofs$", P("/proc/filesystems").read_text(), re.M) is not None, "erofs is not in /proc/filesystems")
        return "erofs in /proc/filesystems"

    def apparmor():
        require(P("/sys/module/apparmor/parameters/enabled").read_text().strip() == "Y", "AppArmor is not enabled")
        require(P(f"/etc/apparmor.d/{PROFILE_NAME}").is_file(), f"AppArmor profile file missing: {PROFILE_NAME}")
        modes = [m.group(1) for m in re.finditer(rf"^{re.escape(PROFILE_NAME)} \((\w+)\)$",
                                                 P("/sys/kernel/security/apparmor/profiles").read_text(), re.M)]
        require(modes, f"AppArmor profile {PROFILE_NAME} is not loaded")
        require(modes == ["enforce"], f"AppArmor profile {PROFILE_NAME} is in mode {modes}, must be enforce")
        return f"enabled; {PROFILE_NAME} loaded in enforce mode"

    def containerd():
        r = run(["bash", str(SAMPLE_ROOT / "scripts" / "30-runtime-install.sh"), "--check-containerd"])
        out = r.stdout.strip().splitlines()
        verdict = out[-1] if out else r.stderr.strip()
        require(r.returncode == 0, verdict)
        return verdict

    def wiring():
        template = P("/usr/local/share/eks/containerd-config.toml").read_text()
        ic.check_template(template)
        ic.check_bootstrap(P("/usr/local/share/eks/bootstrap.sh").read_text())
        ic.check_shim(P("/etc/containerd/nitro-sandbox.toml").read_text(), IMAGE_DIR, SHIM_DEBUG, DATA_DIR)
        with tempfile.TemporaryDirectory() as d:
            Path(d, "r.toml").write_text(template.replace("SANDBOX_IMAGE", "localhost/pause:3.10"))
            mig = run(["containerd", "-c", f"{d}/r.toml", "config", "migrate"])
            require(mig.returncode == 0, f"containerd config migrate failed: {mig.stderr.strip()[:200]}")
            Path(d, "v3.toml").write_text(mig.stdout)
            dump = run(["containerd", "-c", f"{d}/v3.toml", "config", "dump"])
            require(dump.returncode == 0, f"containerd config dump failed: {dump.stderr.strip()[:200]}")
            ic.check_dump(dump.stdout)
        ic.check_dropin(P("/etc/systemd/system/snap.kubelet-eks.daemon.service.d/50-cri-proxy.conf").read_text())
        ic.check_cri_unit(P("/etc/systemd/system/cri-proxy.service").read_text())
        en = run(["systemctl", "is-enabled", "cri-proxy.service"]).stdout.strip()
        require(en == "enabled", f"cri-proxy.service is {en!r}, not enabled")
        return "template, dump, bootstrap endpoint, shim config, drop-in and cri-proxy unit parsed and correct"

    def guest_image():
        link = P(f"{IMAGE_DIR}/rootfs.ext4")
        require(link.is_symlink() and os.readlink(link) == "latest-disk.img", "rootfs.ext4 is not a symlink to latest-disk.img")
        for name in ("latest.eif", "latest-disk.img"):
            f = P(f"{IMAGE_DIR}/{name}")
            require(f.is_file() and f.stat().st_size > 0, f"{IMAGE_DIR}/{name} is missing or empty")
        return f"{IMAGE_DIR}: latest.eif, latest-disk.img, rootfs.ext4 -> latest-disk.img"

    def guest_kernel():
        # The pin the AMI's GuestKernelRelease tag carries: it must be what the staged EIF boots,
        # compared whole (the host's 6.18.56-nitro-ga shares the base release and is refused).
        pinned = [b for b in lock.values() if "guest_kernel" in b]
        require(len(pinned) == 1, f"sources.lock has {len(pinned)} blocks with guest_kernel=, expected 1")
        want = pinned[0]["guest_kernel"]
        got = ic.eif_kernel_release(P(f"{IMAGE_DIR}/latest.eif").read_bytes())
        require(got == want, f"latest.eif boots guest kernel {got!r}, not the {want!r} sources.lock pins")
        return f"latest.eif boots guest kernel {got}, the pinned guest_kernel"

    def mkfs_erofs():
        want = lock["erofs-utils-source"]["ref"]
        mk = str(P("/usr/local/bin/mkfs.erofs"))
        require(run(["dpkg", "-s", "erofs-utils"]).returncode != 0, "Ubuntu's erofs-utils package is still installed")
        where = run(["systemd-run", "--wait", "--pipe", "--quiet", "--collect", "/bin/sh", "-c", "command -v mkfs.erofs"]).stdout.strip()
        require(where == mk, f"a systemd service finds mkfs.erofs at {where!r}, expected {mk}")
        ver = run([mk, "--version"])
        text = (ver.stdout or ver.stderr).strip()
        first = text.splitlines()[0] if text else ""
        require(want in first, f"mkfs.erofs reports {first!r}, expected {want}")
        with tempfile.TemporaryDirectory() as d:
            Path(d, "src").mkdir()
            Path(d, "src", "f").write_text("x\n")
            z = run(["systemd-run", "--wait", "--pipe", "--quiet", "--collect", "/bin/sh", "-c",
                     f"mkfs.erofs -zzstd,1 '{d}/t.img' '{d}/src' >/dev/null"])
            require(z.returncode == 0, "mkfs.erofs -zzstd,1 fails as a systemd service (no zstd?)")
        return f"{first}; zstd ok as a systemd service"

    def runtime_files():
        installs = sorted((i, b) for i, b in lock.items() if b.get("install", "none") != "none")
        require(installs, "sources.lock names no file to install on the node")
        checked = []
        for bid, b in installs:
            dest, mode = b["install"].split()
            p = P(dest)
            st = os.lstat(p) if os.path.lexists(p) else None
            require(st is not None and stat.S_ISREG(st.st_mode), f"{dest} is not a regular file")
            require(stat.S_IMODE(st.st_mode) == int(mode, 8), f"{dest} has mode {oct(stat.S_IMODE(st.st_mode))}, expected {mode}")
            got = sha256(p)
            require(got == b["sha256"], f"{dest} has SHA-256 {got}, not the {b['sha256']} sources.lock pins for {bid}")
            checked.append(dest)
        return f"{len(checked)} installed files match their sources.lock pins, with their modes"

    def runtime_signature():
        signed = sorted((i, b) for i, b in lock.items() if b.get("kind") == "signed-archive")
        require(signed, "sources.lock has no signed-archive block")
        for bid, b in signed:
            key = LOCK_FILE.parent / b["public_key"]
            require(key.is_file() and sha256(key) == b["public_key_sha256"],
                    f"the public key {b['public_key']} beside sources.lock is missing or not its pinned SHA-256")
            man = P(f"{SIGNED_DIR}/{bid}.SHA256SUM")
            sig = P(f"{SIGNED_DIR}/{bid}.SHA256SUM.sig")
            require(man.is_file() and sig.is_file(), f"{SIGNED_DIR}/{bid}.SHA256SUM or its .sig is missing")
            require(sha256(man) == b["manifest_sha256"], f"{bid}.SHA256SUM is not the manifest sources.lock pins")
            v = run(["openssl", "dgst", "-sha384", "-verify", str(key), "-signature", str(sig), str(man)])
            require(v.returncode == 0 and v.stdout.strip() == "Verified OK",
                    f"the signature over {bid}.SHA256SUM does not verify: {(v.stdout.strip() or v.stderr.strip())[:120]!r}")
            sums = {}
            for line in man.read_text().splitlines():
                m = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)", line)
                require(m is not None, f"malformed line in {bid}.SHA256SUM: {line!r}")
                sums[m.group(2)] = m.group(1)
            members = [m for m in lock.values() if m.get("kind") == "archive-member" and m.get("archive") == bid]
            for name, want in [(b["file"], b["sha256"])] + [(m["member"], m["sha256"]) for m in members]:
                require(sums.get(name) == want, f"{bid}.SHA256SUM lists {name} as {sums.get(name)!r}, not its pin {want}")
        names = ", ".join(f"{i} {b['ref']}" for i, b in signed)
        return f"{names}: signed manifest Verified OK, and it lists the archive and the shim with their pins"

    def holds():
        listed = [l.strip() for l in P("/usr/local/share/ubuntu-ami-sample/held-packages").read_text().splitlines() if l.strip()]
        require(listed, "held-packages is empty: 36-hold-packages.sh did not run")
        ctr = shutil.which("containerd")
        require(ctr is not None, "containerd not found on the PATH")
        owner = run(["dpkg", "-S", os.path.realpath(ctr)]).stdout.split(":", 1)[0].strip()
        require(owner and owner in listed, f"the package that owns containerd ({owner or 'unknown'}) is not in held-packages")
        shown = run(["apt-mark", "showhold"])
        require(shown.returncode == 0, "could not read apt-mark showhold")
        held = set(shown.stdout.split())
        missing = [p for p in listed if p not in held]
        require(not missing, f"not held (apt-mark showhold): {missing}")
        conf = P("/etc/apt/apt.conf.d/51ubuntu-ami-sample-holds").read_text()
        active = "\n".join(l for l in conf.splitlines() if not l.lstrip().startswith("//"))
        require("Unattended-Upgrade::Package-Blacklist" in active, "no active Unattended-Upgrade::Package-Blacklist")
        for p in listed:
            entry = '"^' + re.sub(r"([.+])", r"\\\1", p) + '$";'
            require(entry in active, f"Unattended-Upgrade::Package-Blacklist has no {entry}")
        return f"held and blacklisted for unattended upgrades: {' '.join(listed)}"

    return [
        ("host_kernel", kernel), ("nitro_enclaves_device", char_dev("/dev/nitro_enclaves")), ("btf", btf),
        ("cma", cma), ("vsock", char_dev("/dev/vhost-vsock")), ("tun", char_dev("/dev/net/tun")), ("erofs", erofs),
        ("apparmor", apparmor), ("containerd_version", containerd), ("runtime_wiring", wiring),
        ("guest_image", guest_image), ("guest_kernel", guest_kernel), ("mkfs_erofs", mkfs_erofs), ("runtime_files", runtime_files),
        ("runtime_signature", runtime_signature), ("package_holds", holds),
    ]


def main():
    results, failed = {}, []
    for name, check in checks(lock_blocks(LOCK_FILE)):
        try:
            results[name] = {"ok": True, "detail": check()}
        except Exception as e:  # noqa: BLE001 - any error in a check is that check failing
            # every check runs; each failure is reported, then the exit is non-zero
            results[name] = {"ok": False, "detail": f"{type(e).__name__}: {e}"}
            failed.append(name)
    print(json.dumps({"image_configuration": "FAIL" if failed else "PASS", "failed": failed, "checks": results}, indent=2))
    print("image_configuration: " + (f"FAIL (failed: {', '.join(failed)})" if failed else f"PASS ({len(results)} checks)"))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
