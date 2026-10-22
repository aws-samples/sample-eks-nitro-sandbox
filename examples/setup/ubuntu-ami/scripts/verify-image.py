#!/usr/bin/env python3
"""Read the baked Ubuntu image configuration before bootstrap starts kubelet. Run on the
build host after scripts/31-wire-containerd.sh, and again on a fresh instance launched from
the finished AMI, before it is used by EKS. Exits non-zero (an AssertionError) on any
mismatch, so a broken image configuration fails loudly rather than joining the cluster."""
import json
from pathlib import Path
import re
import subprocess
import tomllib

NITRO_SANDBOX_DIR = "/usr/share/nitro-sandbox"


def validate(template, bootstrap, shim):
    cri = template["plugins"]["io.containerd.grpc.v1.cri"]["containerd"]
    assert cri["discard_unpacked_layers"] is False, "unpacked image layers must remain available"
    for name in ("isolated-sandbox", "confidential-sandbox"):
        handler = cri["runtimes"][name]
        assert handler["runtime_type"] == "io.containerd.nitro-sandbox.v2", f"wrong handler: {name}"
        assert handler["sandboxer"] == "shim", f"wrong sandboxer: {name}"
        assert handler["privileged_without_host_devices"] is True, f"host devices enabled: {name}"
    active = "\n".join(line for line in bootstrap.splitlines() if not line.lstrip().startswith("#"))
    endpoint_lines = [line for line in active.splitlines() if "container-runtime-endpoint=" in line]
    assert len(endpoint_lines) == 1, "expected one active kubelet endpoint assignment"
    assert re.search(r"container-runtime-endpoint=([\"']?)unix:///run/nitro-sandbox/cri-proxy\.sock\1(?:\s|$)",
                      endpoint_lines[0]), "bootstrap does not set the cri-proxy endpoint"
    assert shim["nitro_sandbox"] is True, "sandbox mode disabled"
    assert shim["kernel_path"] == f"{NITRO_SANDBOX_DIR}/vmlinuz"
    assert shim["rootfs_path"] == f"{NITRO_SANDBOX_DIR}/rootfs.ext4"
    # cpu_overcommit=true host-schedules enclave vCPUs so many sandbox pods share a node;
    # the alternative (whole-core donation) caps a small instance at one sandbox VM.
    assert shim["cpu_overcommit"] is True, "cpu_overcommit must be true"


def main():
    validate(
        tomllib.loads(Path("/usr/local/share/eks/containerd-config.toml").read_text()),
        Path("/usr/local/share/eks/bootstrap.sh").read_text(),
        tomllib.loads(Path("/etc/containerd/nitro-sandbox.toml").read_text()),
    )
    for name in ("firecracker", "jailer", "containerd-shim-nitro-sandbox-v2", "mkfs.erofs"):
        assert Path("/usr/local/bin", name).is_file(), f"missing {name}"
    for name in ("vmlinuz", "rootfs.ext4"):
        assert Path(NITRO_SANDBOX_DIR, name).stat().st_size > 0, f"missing {name}"
    dropin = Path("/etc/systemd/system/snap.kubelet-eks.daemon.service.d/50-cri-proxy.conf").read_text()
    assert "After=cri-proxy.service" in dropin, "snap kubelet ordering absent"
    # The sample's scoped AppArmor profile (scripts/35-apparmor.sh) must survive the bake and
    # be loaded on this image, or deploy/pod-isolated-sandbox.yaml's requested profile would
    # be refused by the kubelet. Check the on-disk profile file and the kernel's loaded-profile
    # list; the file alone is not enough (a profile can be shipped but never parsed).
    profile_name = "ubuntu-ami-sample-profile"
    assert Path("/etc/apparmor.d", profile_name).is_file(), f"AppArmor profile file missing: {profile_name}"
    loaded = Path("/sys/kernel/security/apparmor/profiles").read_text()
    assert any(line.split(" (")[0] == profile_name for line in loaded.splitlines()), \
        f"AppArmor profile {profile_name} is not loaded (apparmor_parser -r did not run, or it was removed by bake-prep)"
    print(json.dumps({
        "image_configuration": "PASS",
        "kernel": subprocess.check_output(["uname", "-r"], text=True).strip(),
        "apparmor_profile": profile_name,
    }))


if __name__ == "__main__":
    main()
