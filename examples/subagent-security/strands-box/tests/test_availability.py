#!/usr/bin/env python3
"""Validate real fixture responses and reject altered GET receipts through both checks.

The correlator uses synthetic role receipts. These tests do not run Box or AWS.
All supplier HTTP requests use the unchanged shared handler through LocalSupplier.
"""
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest
import urllib.request
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[4]
SAMPLE = ROOT / "examples/subagent-security/strands-box"
FIXTURE = ROOT / "examples/subagent-security/analyst/fixtures/availability.json"
CORRELATOR = SAMPLE / "scripts/correlate.py"
GET_SCENARIOS = ("reader-get", "writer-get", "control-other-case", "control-alias")
sys.path.insert(0, str(SAMPLE / "src"))
import controller


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


receipt_fixtures = module("availability_receipts", ROOT / "examples/subagent-security/strands-box/tests/test_correlation.py")
local_supplier = module("availability_supplier", SAMPLE / "scripts/local_supplier.py")


class AvailabilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT / "tmp").mkdir(exist_ok=True)
        cls.server = local_supplier.LocalSupplier(ROOT / "tmp/strands-box-availability-tests")
        cls.server.start()
        cls.addClassCleanup(cls.server.close)
        cls.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="box-availability-", dir=ROOT / "tmp")
        self.addCleanup(self.scratch.cleanup)
        self.folder = Path(self.scratch.name)
        self.run = controller.Run.__new__(controller.Run)
        self.run.id = receipt_fixtures.RUN_ID
        self.run.supplier_url = self.server.origin
        self.run.supplier_alias_url = self.server.alias_origin
        self.run.calls, self.run.checks = [], []

    def response(self, path, request_id, alias=False):
        origin = self.server.alias_origin if alias else self.server.origin
        request = urllib.request.Request(origin + path, headers={"X-Analyst-Request-ID": request_id})
        with self.opener.open(request, timeout=5) as response:
            self.assertEqual(response.status, 200)
            return json.load(response)

    def write_actual_get_receipts(self):
        receipt_fixtures.write_receipts(self.folder)
        evidence = json.loads((self.folder / "evidence.json").read_text())
        for call in evidence["calls"]:
            if call.get("method") == "GET" and call.get("actual_status") == 200:
                name = call["request_id"][len(receipt_fixtures.RUN_ID) + 1:]
                call["result"]["body"] = self.response(call["path"], call["request_id"], name == "control-alias")
                self.assertNotIn("request_id", call["result"]["body"])
        self.save(evidence)
        return evidence

    def save(self, evidence):
        (self.folder / "evidence.json").write_text(json.dumps(evidence))
        (self.folder / "calls.json").write_text(json.dumps(evidence["calls"]))

    def correlate(self, accepted):
        result = subprocess.run([sys.executable, "-B", str(CORRELATOR), "--require-cloud",
                                 str(self.folder / "evidence.json"),
                                 str(self.folder / "supplier-api-requests.jsonl")],
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0 if accepted else 1, result.stdout + result.stderr)
        if not accepted:
            self.assertTrue(result.stderr.startswith("ERROR: "), result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertIn("availability", result.stderr.lower())
        return result

    def invalid_availability(self):
        expected = json.loads(FIXTURE.read_text())
        changed = copy.deepcopy(expected)
        changed["northstar"]["available"] = False
        short = copy.deepcopy(expected)
        short.pop("harbor")
        altered_note = copy.deepcopy(expected)
        altered_note["northstar"]["lead_time_note"] = "invented availability note"
        missing_note = copy.deepcopy(expected)
        missing_note["northstar"].pop("lead_time_note")
        extra = copy.deepcopy(expected)
        extra["invented-supplier"] = {"available": True}
        return (
            ("invented malformed record", {"invented-supplier": "not supplier data"}),
            ("nonboolean string", {"northstar": {"available": "false"}}),
            ("integer boolean", {"northstar": {"available": 1}}),
            ("invented valid record", {"invented-supplier": {"available": True}}),
            ("changed Northstar eligibility", changed),
            ("missing supplier", short),
            ("changed note", altered_note),
            ("missing note", missing_note),
            ("additional supplier", extra),
        )

    def test_image_layout_reads_its_packaged_shared_schema_and_fixture(self):
        image = self.folder / "image"
        image_src = image / "strands-box/src"
        image_shared = image / "analyst"
        image_src.mkdir(parents=True)
        (image_shared / "fixtures").mkdir(parents=True)
        shutil.copyfile(SAMPLE / "src/worker_adapter.py", image_src / "worker_adapter.py")
        shutil.copyfile(ROOT / "examples/subagent-security/analyst/src/business.py", image_shared / "business.py")
        expected = json.loads(FIXTURE.read_text())
        expected["northstar"]["lead_time_note"] = "updated synthetic fixture"
        (image_shared / "fixtures/availability.json").write_text(json.dumps(expected))
        packaged = module("packaged_worker_adapter", image_src / "worker_adapter.py")
        body = {"case_id": "rfp-001", "availability": expected}
        packaged.supplier_reply(body, "test-image-layout", "GET", "/cases/rfp-001/suppliers")
        body["availability"] = json.loads(FIXTURE.read_text())
        with self.assertRaisesRegex(AssertionError, "shared synthetic fixture"):
            packaged.supplier_reply(body, "test-image-layout", "GET", "/cases/rfp-001/suppliers")

    def test_actual_fixture_without_echoed_ids_passes_full_correlator(self):
        self.write_actual_get_receipts()
        self.assertIn("28 supplier requests correlated", self.correlate(True).stdout)

    def test_actual_fixture_without_echoed_ids_passes_controller_controls(self):
        cases = (("other-case", "/cases/rfp-other/suppliers", None),
                 ("alias", "/cases/rfp-001/suppliers", self.server.alias_origin))
        for name, path, origin in cases:
            with self.subTest(control=name), contextlib.redirect_stdout(io.StringIO()):
                self.run.control(name, "GET", path, 200, base_url=origin)
                body = self.run.calls[-1]["result"]["body"]
                self.assertNotIn("request_id", body)
                self.assertEqual(body["availability"], json.loads(FIXTURE.read_text()))
        self.assertEqual(len(self.run.calls), 2)
        self.assertTrue(all(check["passed"] for check in self.run.checks))

    def test_correlator_rejects_malformed_and_changed_availability_in_every_get_scenario(self):
        original = self.write_actual_get_receipts()
        for name in GET_SCENARIOS:
            for reason, availability in self.invalid_availability():
                with self.subTest(scenario=name, invalid=reason):
                    evidence = copy.deepcopy(original)
                    call = next(row for row in evidence["calls"]
                                if row.get("request_id") == receipt_fixtures.RUN_ID + "-" + name)
                    call["result"]["body"]["availability"] = availability
                    self.save(evidence)
                    self.correlate(False)

    def test_controller_rejects_malformed_and_changed_availability_before_recording_success(self):
        for name, path in (("other-case", "/cases/rfp-other/suppliers"),
                           ("alias", "/cases/rfp-001/suppliers")):
            for reason, availability in self.invalid_availability():
                with self.subTest(control=name, invalid=reason):
                    body = {"case_id": path.split("/")[2], "availability": availability}
                    response = io.BytesIO(json.dumps(body).encode())
                    response.status = 200
                    with patch.object(controller.urllib.request, "build_opener") as opener:
                        opener.return_value.open.return_value = response
                        with self.assertRaisesRegex(AssertionError, "availability"):
                            self.run.control(name, "GET", path, 200)
                    self.assertEqual(self.run.calls, [])
                    self.assertEqual(self.run.checks, [])


if __name__ == "__main__":
    unittest.main()
