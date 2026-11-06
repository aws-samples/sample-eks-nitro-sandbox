#!/usr/bin/env python3
"""Exercise the real shared supplier handler through the sample's HTTP launcher."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import sys
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SAMPLE = ROOT / "examples/subagent-security/strands-box"
sys.path.insert(0, str(ROOT / "examples/subagent-security/analyst/src"))
from business import CASE
spec = importlib.util.spec_from_file_location("local_supplier", SAMPLE / "scripts/local_supplier.py")
local_supplier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local_supplier)


class SupplierTests(unittest.TestCase):
    def setUp(self):
        self.fixture = local_supplier.LocalSupplier(ROOT / "tmp/strands-box-supplier-tests")
        self.fixture.start()
        self.addCleanup(self.fixture.close)
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(self, path, method="GET", request_id="test-1", body=None, *, alias=False, headers=None):
        values = {} if request_id is None else {"X-Analyst-Request-ID": request_id}
        values.update(headers or {})
        data = None if body is None else json.dumps(body).encode()
        if data is not None:
            values["Content-Type"] = "application/json"
        origin = self.fixture.alias_origin if alias else self.fixture.origin
        request = urllib.request.Request(origin + path, data=data, headers=values, method=method)
        try:
            response = self.opener.open(request, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, json.load(response)

    def test_anonymous_fixture_and_alias_reach_the_same_supplier(self):
        self.assertTrue(self.fixture.origin.startswith("http://127.0.0.1:"))
        self.assertTrue(self.fixture.alias_origin.startswith("http://localhost:"))
        path = f"/cases/{CASE}/suppliers"
        first = self.request(path, request_id="primary-1")
        second = self.request(path, request_id="alias-1", alias=True)
        self.assertEqual(first[0], 200)
        self.assertEqual(second, first)
        self.assertEqual(self.fixture.requests, [
            {"request_id": "primary-1", "method": "GET", "path": path},
            {"request_id": "alias-1", "method": "GET", "path": path},
        ])

    def test_supplier_accepts_operations_that_box_must_refuse(self):
        cases = [("GET", "/cases/rfp-other/suppliers"),
                 ("PATCH", "/suppliers/example"), ("POST", "/purchase-orders")]
        for index, (method, path) in enumerate(cases):
            with self.subTest(method=method, path=path):
                status, body = self.request(path, method, f"control-{index}",
                                            None if method == "GET" else {"synthetic": True})
                self.assertEqual(status, 200)
                self.assertTrue(body)
        for index in range(4):
            status, body = self.request(f"/cases/{CASE}/recommendations", "POST",
                                        f"draft-{index}", {"draft": index})
            self.assertEqual(status, 201)
            self.assertEqual(body, {"saved": True, "request_id": f"draft-{index}"})
        self.assertEqual(len(self.fixture.requests), 7)
        self.assertEqual({row["request_id"] for row in self.fixture.drafts},
                         {f"draft-{index}" for index in range(4)})

    def test_bad_request_identifier_is_rejected_before_logging(self):
        path = f"/cases/{CASE}/suppliers"
        self.assertEqual(self.request(path, request_id=None)[0], 400)
        self.assertEqual(self.request(path, request_id="bad/id")[0], 400)
        self.assertEqual(self.fixture.requests, [])
        self.assertEqual(self.request(path, request_id="good-id")[0], 200)
        self.assertEqual(len(self.fixture.requests), 1)

    def test_unknown_path_is_logged_as_an_arrival(self):
        self.assertEqual(self.request("/missing", request_id="unknown-1")[0], 404)
        self.assertEqual(self.fixture.requests,
                         [{"request_id": "unknown-1", "method": "GET", "path": "/missing"}])

    def test_health_probe_does_not_count_as_a_role_request(self):
        self.assertEqual(self.request("/healthz", request_id=None), (200, {"healthy": True}))
        self.assertEqual(self.fixture.requests, [])

    def test_ledger_contains_no_headers_or_body(self):
        marker = "synthetic-header-and-body-value"
        self.assertEqual(self.request(f"/cases/{CASE}/recommendations", "POST", "ledger-1",
                                      {"draft": marker}, headers={"Authorization": marker})[0], 201)
        self.assertEqual(set(self.fixture.requests[0]), {"request_id", "method", "path"})
        self.assertNotIn(marker, json.dumps(self.fixture.requests))

    def test_fixture_does_not_change_the_controller_environment(self):
        with patch.dict(os.environ, {"SUPPLIER_KEY_FILE": "controller-setting", "SUPPLIER_STATE_DIR": "controller-state"}):
            before = dict(os.environ)
            with local_supplier.LocalSupplier(ROOT / "tmp/strands-box-supplier-tests") as other:
                self.assertEqual(dict(os.environ), before)
                self.assertFalse(hasattr(other, "key_file"))
                self.assertFalse(hasattr(other, "ca_file"))
                self.assertFalse(list(other.directory.glob("*.pem")))
            self.assertEqual(dict(os.environ), before)

    def test_close_stops_only_the_owned_server_and_refuses_restart(self):
        from urllib.parse import urlsplit
        port = urlsplit(self.fixture.origin).port
        self.fixture.close()
        self.fixture.close()
        self.assertIsNotNone(self.fixture._process.poll())
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", port), timeout=1)
        with self.assertRaisesRegex(RuntimeError, "closed"):
            self.fixture.start()


if __name__ == "__main__":
    unittest.main()
