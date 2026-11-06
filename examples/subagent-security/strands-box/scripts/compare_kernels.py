#!/usr/bin/env python3
"""Validate recorded guest observations; this is not an escape or attestation test."""
import argparse
import json
import math
from pathlib import Path
import re
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import strict_json


# Support the PCI-to-virtio disk layout captured by this sample's live runs.
# This checks recorded structure, not path existence or device authenticity.
VIRTIO_PCI_PATH = re.compile(
    r"/sys/devices/pci[0-9a-f]{4}:[0-9a-f]{2}/"
    r"(?:[0-9a-f]{4}:[0-9a-f]{2}:[01][0-9a-f]\.[0-7]/)+"
    r"virtio(?:0|[1-9][0-9]*)/block/[A-Za-z0-9][A-Za-z0-9_.-]*"
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def observation(value, label):
    require(isinstance(value, dict), label + " observation is not an object")
    for key in ("kernel_release", "kernel_version", "kernel_build"):
        require(isinstance(value.get(key), str) and bool(value[key].strip()),
                label + " observation has no " + key)
    require(value.get("architecture") in ("aarch64", "arm64"),
            label + " observation is not ARM64")
    uptime = value.get("uptime_seconds")
    require(type(uptime) in (int, float) and math.isfinite(uptime) and uptime >= 0,
            label + " observation has no finite nonnegative uptime")
    boot_id = value.get("boot_id")
    require(isinstance(boot_id, str) and re.fullmatch(
            r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", boot_id) is not None,
            label + " observation has no valid boot identifier")
    require(uuid.UUID(boot_id).int != 0, label + " observation has an empty boot identifier")
    devices = value.get("block_devices")
    require(isinstance(devices, list), label + " observation has no block-device list")
    names = set()
    for device in devices:
        require(isinstance(device, dict), label + " block-device record is not an object")
        name = device.get("name")
        require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", name) is not None,
                label + " block device has no valid name")
        require(name not in names, label + " block-device names are duplicated")
        names.add(name)
        path = device.get("sysfs_path")
        # Validate raw components: Path would hide dots and repeated separators.
        parts = path.split("/") if isinstance(path, str) else []
        require(len(parts) >= 5 and parts[:3] == ["", "sys", "devices"]
                and all(part not in (".", "..")
                        and re.fullmatch(r"[A-Za-z0-9_.:+-]+", part) is not None
                        for part in parts[1:]),
                label + " block device has no canonical resolved sysfs device path")
        require(parts[-1] == name,
                label + " block-device sysfs path does not end with its reported name")
        virtio_component = any(part.startswith("virtio") for part in parts[3:-1])
        virtio_path = VIRTIO_PCI_PATH.fullmatch(path) is not None
        require(not virtio_component or virtio_path,
                label + " virtio path is outside the supported PCI device layout")
        require(type(device.get("virtio")) is bool, label + " block-device virtio flag is not a Boolean")
        require(device["virtio"] == virtio_path,
                label + " block-device virtio flag differs from its recorded sysfs path")
    return value


def compare(folder, node, mode):
    require(mode in ("nitro", "eks"), "unrecognized deployment mode")
    require(isinstance(node, str) and bool(node.strip()), "the observed worker node is missing")
    analyst = observation(strict_json.loads((folder / "analyst-kernel.json").read_text()), "analyst")
    summary = {"deployment_mode": mode, "worker_node": node}
    if mode == "nitro":
        worker = observation(strict_json.loads((folder / "ordinary-control-kernel.json").read_text()), "ordinary control")
        require(analyst["boot_id"].lower() != worker["boot_id"].lower(),
                "the analyst and ordinary control report the same kernel boot identifier")
        disks = [device["name"] for device in analyst["block_devices"] if device["virtio"]]
        require(bool(disks), "the analyst reports no virtio block device")
        summary.update(
            kernel_releases_differ=analyst["kernel_release"] != worker["kernel_release"],
            kernel_versions_differ=analyst["kernel_version"] != worker["kernel_version"],
            kernel_builds_differ=analyst["kernel_build"] != worker["kernel_build"],
            boot_ids_differ=True, guest_virtio_disks=disks,
            analyst_kernel=analyst, ordinary_control_kernel=worker,
            qualification="Same-node observations are not an escape test or attestation proof.",
        )
        filename = "kernel-comparison.json"
    else:
        worker = strict_json.loads((folder / "worker-node.json").read_text())
        require(isinstance(worker, dict) and worker.get("metadata", {}).get("name") == node,
                "the worker-node record differs from the selected node")
        info = worker.get("status", {}).get("nodeInfo", {})
        require(isinstance(info, dict) and info.get("architecture") == "arm64",
                "the worker-node record is not ARM64")
        require(isinstance(info.get("kernelVersion"), str) and bool(info["kernelVersion"].strip()),
                "the worker-node record has no kernel version")
        summary.update(
            analyst_kernel=analyst, worker_node_info=info,
            qualification="Ordinary EKS observations do not establish a Nitro guest boundary or attestation.",
        )
        filename = "eks-observations.json"
    (folder / filename).write_text(json.dumps(summary, indent=2, allow_nan=False) + "\n")
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_directory", type=Path)
    parser.add_argument("worker_node")
    parser.add_argument("deployment_mode", choices=("nitro", "eks"))
    args = parser.parse_args()
    try:
        summary = compare(args.output_directory, args.worker_node, args.deployment_mode)
    except (AttributeError, KeyError, TypeError, ValueError, OverflowError, OSError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 1
    print(summary["qualification"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
