from __future__ import annotations

import base64
import io
import json
import os
import unittest
from unittest import mock

from server import AdmissionHandler, admit, validate
from test_adapter import target_pod

OWNERSHIP_INIT_IMAGE = f"example.invalid/ownership-helper@sha256:{'b' * 64}"


def review(
    pod: dict,
    *,
    operation: str = "CREATE",
    subresource: str | None = None,
) -> dict:
    request = {
        "uid": "test-uid",
        "operation": operation,
        "namespace": "oce-tenant-test",
        "resource": {"group": "", "version": "v1", "resource": "pods"},
        "object": pod,
    }
    if subresource is not None:
        request["subResource"] = subresource
    return {
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "request": request,
    }


@mock.patch.dict(
    os.environ,
    {"OCE_OWNERSHIP_INIT_IMAGE": OWNERSHIP_INIT_IMAGE},
)
class AdmitTests(unittest.TestCase):
    def test_returns_an_encoded_json_patch(self) -> None:
        response = admit(review(target_pod()))["response"]
        self.assertTrue(response["allowed"])
        self.assertEqual(response["uid"], "test-uid")
        self.assertEqual(response["patchType"], "JSONPatch")
        patch = json.loads(base64.b64decode(response["patch"]))
        self.assertTrue(
            any(operation["path"] == "/spec/runtimeClassName" for operation in patch)
        )

    def test_denies_an_unmatched_workload(self) -> None:
        pod = target_pod()
        pod["metadata"]["labels"]["openclaw.dev/workload-role"] = "controller"
        response = admit(review(pod))["response"]
        self.assertFalse(response["allowed"])
        self.assertEqual(response["status"]["code"], 400)
        self.assertIn("workload role", response["status"]["message"])

    def test_denies_an_unsafe_target_pod(self) -> None:
        pod = target_pod()
        pod["spec"]["containers"][-1]["volumeMounts"][-1]["subPathExpr"] = "$x"
        response = admit(review(pod))["response"]
        self.assertFalse(response["allowed"])
        self.assertEqual(response["status"]["code"], 400)
        self.assertIn("subPathExpr", response["status"]["message"])

    def test_validation_denies_ephemeral_container_updates(self) -> None:
        response = validate(
            review(
                target_pod(),
                operation="UPDATE",
                subresource="ephemeralcontainers",
            )
        )["response"]

        self.assertEqual(response["uid"], "test-uid")
        self.assertFalse(response["allowed"])
        self.assertEqual(response["status"]["code"], 403)
        self.assertEqual(response["status"]["reason"], "Forbidden")
        self.assertIn("ephemeral containers", response["status"]["message"])
        self.assertNotIn("patch", response)


class AdmissionHandlerTests(unittest.TestCase):
    def test_validate_path_uses_the_ephemeral_container_denial(self) -> None:
        body = json.dumps(
            review(
                target_pod(),
                operation="UPDATE",
                subresource="ephemeralcontainers",
            )
        ).encode("utf-8")
        handler = AdmissionHandler.__new__(AdmissionHandler)
        handler.path = "/validate"
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = io.BytesIO(body)
        handler._write_json = mock.Mock()
        handler.send_error = mock.Mock()

        handler.do_POST()

        handler.send_error.assert_not_called()
        status, admission_review = handler._write_json.call_args.args
        self.assertEqual(status, 200)
        self.assertFalse(admission_review["response"]["allowed"])
        self.assertEqual(admission_review["response"]["status"]["code"], 403)


if __name__ == "__main__":
    unittest.main()
