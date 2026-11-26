"""Contracts for the dedicated namespace-controller deletion exception."""

from __future__ import annotations

import importlib.util
import pathlib

import pytest
import yaml

SAMPLE = pathlib.Path(__file__).resolve().parent.parent
CONTROLLER = "system:serviceaccount:kube-system:namespace-controller"
WORKER = "system:serviceaccount:openclaw-system:openclaw-enterprise-worker"
WEBHOOK = "protect-revision-configmaps.openclaw-enterprise.sandbox.eks.amazonaws.com"


def _documents() -> list[dict]:
    return [
        doc
        for doc in yaml.safe_load_all(
            (SAMPLE / "deploy" / "adapter-webhook.yaml").read_text()
        )
        if doc
    ]


def test_only_configmap_webhook_exempts_authenticated_controller_deletes() -> None:
    configurations = [
        doc
        for doc in _documents()
        if doc["kind"]
        in {"ValidatingWebhookConfiguration", "MutatingWebhookConfiguration"}
    ]
    webhooks = [hook for doc in configurations for hook in doc["webhooks"]]
    exempt = [hook for hook in webhooks if hook.get("matchConditions")]
    assert [hook["name"] for hook in exempt] == [WEBHOOK]
    webhook = exempt[0]
    assert webhook["failurePolicy"] == "Fail"
    assert webhook["namespaceSelector"] == {
        "matchLabels": {"app.kubernetes.io/managed-by": "openclaw-enterprise"}
    }
    assert "objectSelector" not in webhook
    assert webhook["rules"] == [
        {
            "apiGroups": [""],
            "apiVersions": ["v1"],
            "operations": ["CREATE", "UPDATE", "DELETE"],
            "resources": ["configmaps"],
            "scope": "Namespaced",
        }
    ]
    assert webhook["matchConditions"] == [
        {
            "name": "exclude-authenticated-namespace-controller-deletes",
            "expression": (
                "!(request.operation == 'DELETE' && "
                f"request.userInfo.username == '{CONTROLLER}' && "
                "'system:authenticated' in request.userInfo.groups && "
                "'system:serviceaccounts:kube-system' in request.userInfo.groups)"
            ),
        }
    ]


def test_deployment_allowlist_still_contains_only_worker() -> None:
    deployment = next(doc for doc in _documents() if doc["kind"] == "Deployment")
    environment = {
        item["name"]: item["value"]
        for item in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
    }
    assert environment["OCE_ALLOWED_DEPLOYMENT_USERS"] == WORKER


@pytest.fixture
def server(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.syspath_prepend(str(SAMPLE / "adapter"))
    spec = importlib.util.spec_from_file_location(
        "namespace_admission_contract_server", SAMPLE / "adapter" / "server.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setenv("OCE_ALLOWED_DEPLOYMENT_USERS", WORKER)
    return module


def _revision_review(username: str, operation: str) -> dict:
    configmap = {
        "metadata": {
            "name": "gateway-b59473701485-rev-deadbeefcafe",
            "labels": {
                "app.kubernetes.io/managed-by": "openclaw-enterprise",
                "openclaw.dev/agent": "agt_test",
                "openclaw.dev/namespace": "ns_test",
            },
        },
        "immutable": True,
        "data": {"openclaw.json": "{}"},
    }
    return {
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "request": {
            "uid": "namespace-admission-test",
            "namespace": "oce-tenant-test",
            "operation": operation,
            "subResource": "",
            "resource": {"group": "", "version": "v1", "resource": "configmaps"},
            "userInfo": {
                "username": username,
                "groups": ["system:authenticated", "system:masters"],
            },
            "object": None if operation == "DELETE" else configmap,
            "oldObject": configmap if operation == "DELETE" else None,
        },
    }


@pytest.mark.parametrize("operation", ["CREATE", "UPDATE", "DELETE"])
@pytest.mark.parametrize(
    "username",
    [
        "tenant-user",
        "cluster-admin",
        "system:kube-controller-manager",
        "system:serviceaccount:oce-tenant-test:namespace-controller",
        "system:serviceaccount:kube-system:generic-garbage-collector",
    ],
)
def test_revision_validator_still_denies_other_callers(server, username, operation):
    response = server.validate(_revision_review(username, operation))["response"]
    assert response["allowed"] is False
    assert "not an allowed controller identity" in response["status"]["message"]


@pytest.mark.parametrize("operation", ["CREATE", "UPDATE"])
def test_namespace_controller_cannot_write_revisions(server, operation):
    response = server.validate(_revision_review(CONTROLLER, operation))["response"]
    assert response["allowed"] is False


@pytest.mark.parametrize("operation", ["CREATE", "UPDATE", "DELETE"])
def test_worker_revision_access_is_preserved(server, operation):
    assert server.validate(_revision_review(WORKER, operation))["response"]["allowed"]
