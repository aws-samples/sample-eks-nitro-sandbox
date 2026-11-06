#!/usr/bin/env python3
"""Collect guest/worker observations; this is not an escape or attestation test."""
import json
import os
from pathlib import Path

uname = os.uname()
devices = []
for device in sorted(Path("/sys/block").iterdir()):
    target = device.resolve(strict=True)
    devices.append({"name": device.name, "sysfs_path": str(target),
                    "virtio": any(part.startswith("virtio") for part in target.parts)})
print(json.dumps({"kernel_release": uname.release, "kernel_version": uname.version,
                  "kernel_build": Path("/proc/version").read_text().strip(),
                  "architecture": uname.machine,
                  "uptime_seconds": float(Path("/proc/uptime").read_text().split()[0]),
                  "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
                  "block_devices": devices}, indent=2))
