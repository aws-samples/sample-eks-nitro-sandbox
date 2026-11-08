#!/usr/bin/env python3
"""Test the real kernel-observation verifier with synthetic fixtures, without AWS."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[4]
SCRIPT = REPO / "examples/subagent-security/strands-box/scripts/compare_kernels.py"
NODE = "synthetic-worker"
PCI_PREFIX = "/sys/devices/pci0000:01/0000:01:00.0/0000:02:00.0/0000:03:00.0/0000:04:00.0/"


def observations():
    # Identical kernel versions are deliberately valid. Separate boot identities
    # and a guest virtio device are required; a different release is not.
    analyst = {"kernel_release": "synthetic-release", "kernel_version": "synthetic-version",
               "kernel_build": "Linux version synthetic-build", "architecture": "aarch64",
               "uptime_seconds": 14.25, "boot_id": "12345678-1234-4234-8234-123456789abc",
               "block_devices": [{"name": "vda", "sysfs_path": PCI_PREFIX + "virtio1/block/vda", "virtio": True}]}
    worker = {**copy.deepcopy(analyst), "uptime_seconds": 172800.5,
              "boot_id": "22345678-1234-4234-8234-123456789abc",
              "block_devices": [{"name": "nvme0n1", "sysfs_path": "/sys/devices/pci0000:00/0000:00:04.0/nvme/nvme0/nvme0n1", "virtio": False}]}
    node = {"metadata": {"name": NODE}, "status": {"nodeInfo": {"architecture": "arm64", "kernelVersion": "synthetic-release"}}}
    return {"analyst-kernel.json": analyst, "ordinary-control-kernel.json": worker, "worker-node.json": node}


class KernelComparisonTests(unittest.TestCase):
    def setUp(self):
        (REPO / "tmp").mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(prefix="box-kernel-test-", dir=REPO / "tmp")
        self.addCleanup(self.scratch.cleanup)
        self.folder = Path(self.scratch.name)
        self.reset()

    def reset(self):
        for filename, value in observations().items():
            (self.folder / filename).write_text(json.dumps(value))

    def edit(self, filename, mutation):
        path = self.folder / filename
        value = json.loads(path.read_text())
        mutation(value)
        path.write_text(json.dumps(value))

    def run_check(self, *, mode="nitro", accepted=False):
        result = subprocess.run([sys.executable, "-B", str(SCRIPT), str(self.folder), NODE, mode],
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0 if accepted else 1, result.stdout+result.stderr)
        if not accepted:
            self.assertTrue(result.stderr.startswith("ERROR: "), result.stderr)
            self.assertNotIn("Traceback", result.stderr)
        return result

    def test_nitro_observations_pass_without_different_kernel_version(self):
        result = self.run_check(accepted=True)
        summary = json.loads((self.folder / "kernel-comparison.json").read_text())
        self.assertFalse(summary["kernel_releases_differ"])
        self.assertFalse(summary["kernel_versions_differ"])
        self.assertFalse(summary["kernel_builds_differ"])
        self.assertTrue(summary["boot_ids_differ"])
        self.assertEqual(summary["guest_virtio_disks"], ["vda"])
        self.assertEqual(summary["analyst_kernel"]["uptime_seconds"], 14.25)
        self.assertEqual(summary["ordinary_control_kernel"]["uptime_seconds"], 172800.5)
        self.assertIn("not an escape test or attestation proof", result.stdout)

    def test_different_kernel_build_is_recorded(self):
        self.edit("ordinary-control-kernel.json", lambda value: value.update(kernel_build="Different synthetic build"))
        self.run_check(accepted=True)
        summary = json.loads((self.folder / "kernel-comparison.json").read_text())
        self.assertTrue(summary["kernel_builds_differ"])
        self.assertFalse(summary["kernel_releases_differ"])

    def test_same_boot_identity_is_rejected(self):
        boot = observations()["analyst-kernel.json"]["boot_id"]
        for value in (boot, boot.upper()):
            with self.subTest(boot=value):
                self.edit("ordinary-control-kernel.json", lambda item: item.update(boot_id=value))
                self.assertIn("same kernel boot identifier", self.run_check().stderr)

    def test_both_observations_require_valid_boot_ids(self):
        for filename in ("analyst-kernel.json", "ordinary-control-kernel.json"):
            for value in (None, "", "boot-id", 123, "00000000-0000-0000-0000-000000000000"):
                with self.subTest(file=filename, value=value):
                    self.reset()
                    self.edit(filename, lambda item: item.update(boot_id=value))
                    self.run_check()

    def test_both_observations_must_be_arm64(self):
        for filename in ("analyst-kernel.json", "ordinary-control-kernel.json"):
            with self.subTest(file=filename):
                self.reset()
                self.edit(filename, lambda value: value.update(architecture="x86_64"))
                self.run_check()

    def test_kernel_release_version_and_build_are_required(self):
        for filename in ("analyst-kernel.json", "ordinary-control-kernel.json"):
            for field in ("kernel_release", "kernel_version", "kernel_build"):
                for value in (None, "", " ", 7):
                    with self.subTest(file=filename, field=field, value=value):
                        self.reset()
                        self.edit(filename, lambda item: item.update({field: value}))
                        self.run_check()

    def test_both_uptimes_must_be_finite_nonnegative_numbers(self):
        for filename in ("analyst-kernel.json", "ordinary-control-kernel.json"):
            for value in (None, -1, True, "10", float("nan"), float("inf"), float("-inf")):
                with self.subTest(file=filename, value=value):
                    self.reset()
                    self.edit(filename, lambda item: item.update(uptime_seconds=value))
                    self.run_check()

    def test_at_least_one_guest_virtio_device_is_required(self):
        for devices in ([], observations()["ordinary-control-kernel.json"]["block_devices"]):
            with self.subTest(devices=devices):
                self.edit("analyst-kernel.json", lambda value: value.update(block_devices=devices))
                self.assertIn("no virtio block device", self.run_check().stderr)

    def test_virtio_flag_is_a_boolean_and_matches_sysfs_path(self):
        for filename in ("analyst-kernel.json", "ordinary-control-kernel.json"):
            for value in (None, 0, 1, "true"):
                with self.subTest(file=filename, flag=value):
                    self.reset()
                    self.edit(filename, lambda item: item["block_devices"][0].update(virtio=value))
                    self.run_check()
        self.reset()
        self.edit("analyst-kernel.json", lambda value: value["block_devices"][0].update(virtio=False))
        self.assertIn("differs from its recorded sysfs path", self.run_check().stderr)

    def test_live_nitro_virtio_paths_are_accepted(self):
        # Exact resolved device paths from the fresh Nitro run. PCI components
        # contain colons and dots; the virtio number need not start at zero.
        prefix = "/sys/devices/pci0000:01/0000:01:00.0/0000:02:00.0/"
        devices = [
            {"name": "vda", "sysfs_path": prefix + "0000:03:00.0/0000:04:00.0/virtio1/block/vda", "virtio": True},
            {"name": "vdb", "sysfs_path": prefix + "0000:03:00.1/0000:05:00.0/virtio2/block/vdb", "virtio": True},
            {"name": "vdc", "sysfs_path": prefix + "0000:03:00.4/0000:08:00.0/virtio5/block/vdc", "virtio": True},
            {"name": "dm-0", "sysfs_path": "/sys/devices/virtual/block/dm-0", "virtio": False},
        ]
        self.edit("analyst-kernel.json", lambda value: value.update(block_devices=devices))
        self.run_check(accepted=True)
        summary = json.loads((self.folder / "kernel-comparison.json").read_text())
        self.assertEqual(summary["guest_virtio_disks"], ["vda", "vdb", "vdc"])

    def test_virtio_requires_a_resolved_block_device_path(self):
        paths = (
            "/sys/virtual/virtio-not-a-device",
            "/sys/block/vda",
            "/sys/devices/platform/virtio-not-a-device/block/vda",
            "/sys/devices/platform/virtio/block/vda",
            "/sys/devices/platform/virtio1junk/block/vda",
            "/sys/devices/platform/virtio0/not-block/vda",
            "/sys/devices/platform/virtio0/other/block/vda",
            "/sys/devices/platform/virtio0/block/vdb",
            "/sys/devices/platform/virtio0/block/vda/device",
        )
        for path in paths:
            with self.subTest(path=path):
                self.reset()
                self.edit("analyst-kernel.json", lambda value: value["block_devices"][0].update(sysfs_path=path))
                self.run_check()

    def test_device_path_must_end_in_the_reported_name(self):
        for filename in ("analyst-kernel.json", "ordinary-control-kernel.json"):
            with self.subTest(file=filename):
                self.reset()
                self.edit(filename, lambda value: value["block_devices"][0].update(name="other-device"))
                self.run_check()

    def test_sysfs_paths_must_not_need_normalization(self):
        paths = (
            "//sys/devices/platform/virtio0/block/vda",
            "/sys//devices/platform/virtio0/block/vda",
            "/sys/devices/platform/./virtio0/block/vda",
            "/sys/devices/platform/other/../virtio0/block/vda",
            "/sys/devices/platform/virtio0//block/vda",
            "/sys/devices/platform/virtio0/block/vda/",
            "/sys/devices/platform/virtio0/block/./vda",
            "/sys/devices/platform/%2e/virtio0/block/vda",
            "/sys/devices/platform\\other/virtio0/block/vda",
            "/sys/devices/platform/virtio0/block/vda\x00",
        )
        for path in paths:
            with self.subTest(path=path):
                self.reset()
                self.edit("analyst-kernel.json", lambda value: value["block_devices"][0].update(sysfs_path=path))
                self.run_check()

    def test_invalid_virtio_ancestor_is_not_hidden_by_a_false_flag(self):
        self.edit("ordinary-control-kernel.json", lambda value: value.update(block_devices=[{
            "name": "vdb", "sysfs_path": "/sys/devices/platform/virtio0/other/block/vdb", "virtio": False}]))
        self.run_check()

    def test_virtio_numbers_use_canonical_decimal_spelling(self):
        for number in ("0", "1", "10"):
            with self.subTest(accepted=number):
                self.reset()
                path = PCI_PREFIX + "virtio" + number + "/block/vda"
                self.edit("analyst-kernel.json", lambda value: value["block_devices"][0].update(sysfs_path=path))
                self.run_check(accepted=True)
        for number in ("00", "01", "0010", "+1", "-1"):
            with self.subTest(rejected=number):
                self.reset()
                path = PCI_PREFIX + "virtio" + number + "/block/vda"
                self.edit("analyst-kernel.json", lambda value: value["block_devices"][0].update(sysfs_path=path))
                self.run_check()

    def test_virtio_ancestry_must_use_the_supported_pci_layout(self):
        paths = (
            "/sys/devices/platform/virtio01/block/vda",
            "/sys/devices/virtual/virtio0/block/vda",
            "/sys/devices/platform/virtio0/virtio1/block/vda",
            PCI_PREFIX + "virtio0/virtio1/block/vda",
            PCI_PREFIX + "invented-parent/virtio1/block/vda",
            "/sys/devices/pci0000:01/virtio1/block/vda",
            "/sys/devices/pci0000:1/0000:01:00.0/virtio1/block/vda",
            "/sys/devices/pci0000:01/0000:01:20.0/virtio1/block/vda",
            "/sys/devices/pci0000:01/0000:01:00.8/virtio1/block/vda",
            "/sys/devices/platform/virtio0/block/vda",
        )
        for path in paths:
            for flag in (True, False):
                with self.subTest(path=path, flag=flag):
                    self.reset()
                    # Check the ordinary receipt too: it cannot hide malformed
                    # virtio ancestry behind a false flag and a valid analyst.
                    self.edit("ordinary-control-kernel.json", lambda value: value.update(block_devices=[{
                        "name": "vda", "sysfs_path": path, "virtio": flag}]))
                    self.run_check()

    def test_truncated_virtio_ancestry_cannot_hide_behind_a_false_flag(self):
        paths = (
            "/sys/devices/virtual/virtio0/vda",
            "/sys/devices/virtual/virtio01/vda",
            PCI_PREFIX + "virtio0/vda",
        )
        for path in paths:
            with self.subTest(path=path):
                self.reset()
                self.edit("ordinary-control-kernel.json", lambda value: value.update(block_devices=[{
                    "name": "vda", "sysfs_path": path, "virtio": False}]))
                self.assertIn("virtio path is outside the supported PCI device layout", self.run_check().stderr)

    def test_duplicate_json_keys_are_rejected_before_observation_validation(self):
        cases = (
            ("analyst-kernel.json", "nitro", '\"kernel_release\": \"synthetic-release\"',
             '\"kernel_release\": \"discarded\", \"kernel_release\": \"synthetic-release\"'),
            ("analyst-kernel.json", "nitro", '\"virtio\": true', '\"virtio\": false, \"virtio\": true'),
            ("ordinary-control-kernel.json", "nitro", '\"kernel_release\": \"synthetic-release\"',
             '\"kernel_release\": \"discarded\", \"kernel_release\": \"synthetic-release\"'),
            ("worker-node.json", "eks", '\"kernelVersion\": \"synthetic-release\"',
             '\"kernelVersion\": null, \"kernelVersion\": \"synthetic-release\"'),
        )
        for filename, mode, needle, replacement in cases:
            with self.subTest(file=filename, key=needle):
                self.reset()
                path = self.folder / filename
                original = path.read_text()
                self.assertIn(needle, original)
                path.write_text(original.replace(needle, replacement, 1))
                self.assertIn("Duplicate JSON object key", self.run_check(mode=mode).stderr)

    def test_block_device_schema_is_required(self):
        for value in (None, {}, [None], [{"name": "vda"}],
                      [{"name": "vda", "sysfs_path": "relative/virtio0", "virtio": True}]):
            with self.subTest(devices=value):
                self.reset()
                self.edit("analyst-kernel.json", lambda item: item.update(block_devices=value))
                self.run_check()
        self.reset()
        self.edit("analyst-kernel.json", lambda item: item["block_devices"].append(item["block_devices"][0]))
        self.assertIn("duplicated", self.run_check().stderr)

    def test_missing_or_nonobject_observation_is_rejected(self):
        for filename in ("analyst-kernel.json", "ordinary-control-kernel.json"):
            with self.subTest(file=filename):
                self.reset()
                (self.folder / filename).rename(self.folder / "withheld.json")
                self.run_check()
                (self.folder / "withheld.json").rename(self.folder / filename)
                (self.folder / filename).write_text("[]")
                self.run_check()
        self.assertFalse((self.folder / "kernel-comparison.json").exists())

    def test_ordinary_mode_records_without_claiming_nitro(self):
        self.edit("analyst-kernel.json", lambda value: value.update(block_devices=[]))
        result = self.run_check(mode="eks", accepted=True)
        summary = json.loads((self.folder / "eks-observations.json").read_text())
        self.assertNotIn("boot_ids_differ", summary)
        self.assertIn("do not establish a Nitro guest boundary", result.stdout)

    def test_ordinary_mode_requires_matching_arm64_worker_record(self):
        mutations = (
            lambda value: value["metadata"].update(name="different-worker"),
            lambda value: value["status"]["nodeInfo"].update(architecture="amd64"),
            lambda value: value["status"]["nodeInfo"].pop("kernelVersion"),
        )
        for mutation in mutations:
            self.reset()
            self.edit("worker-node.json", mutation)
            self.run_check(mode="eks")


if __name__ == "__main__":
    unittest.main()
