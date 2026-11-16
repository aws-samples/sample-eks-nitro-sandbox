"""Static deployment contracts for the OCE Nitro admission adapter."""

from __future__ import annotations

import pathlib
import subprocess
from typing import Any

import yaml

SAMPLE = pathlib.Path(__file__).resolve().parent.parent
DEPLOY = SAMPLE / "deploy"
RENDER_SCRIPT = SAMPLE / "scripts" / "render-adapter-manifest.sh"
ADMISSION_FIXTURE = SAMPLE / "tests" / "fixtures" / "oce-agent-pod.yaml"


def _yaml_documents(path: pathlib.Path) -> list[dict[str, Any]]:
    documents = list(yaml.safe_load_all(path.read_text(encoding="utf-8")))
    return [document for document in documents if document]


def _one(documents: list[dict[str, Any]], kind: str, name: str) -> dict[str, Any]:
    matches = [
        document
        for document in documents
        if document.get("kind") == kind
        and document.get("metadata", {}).get("name") == name
    ]
    assert len(matches) == 1, f"expected one {kind}/{name}, found {len(matches)}"
    return matches[0]


def test_webhook_matches_all_pods_in_oce_namespaces_and_fails_closed() -> None:
    documents = _yaml_documents(DEPLOY / "adapter-webhook.yaml")
    webhook_configuration = _one(
        documents,
        "MutatingWebhookConfiguration",
        "openclaw-enterprise-nitro-adapter",
    )
    webhook = webhook_configuration["webhooks"][0]

    assert webhook["failurePolicy"] == "Fail"
    assert webhook["sideEffects"] == "None"
    assert webhook["reinvocationPolicy"] == "Never"
    assert webhook["namespaceSelector"] == {
        "matchLabels": {"app.kubernetes.io/managed-by": "openclaw-enterprise"}
    }
    assert "objectSelector" not in webhook
    assert webhook["rules"] == [
        {
            "apiGroups": [""],
            "apiVersions": ["v1"],
            "operations": ["CREATE"],
            "resources": ["pods"],
            "scope": "Namespaced",
        }
    ]


def test_supported_admission_fixture_matches_current_adapter_input() -> None:
    pod = _yaml_documents(ADMISSION_FIXTURE)[0]
    spec = pod["spec"]

    assert pod["metadata"]["labels"]["openclaw.dev/workload-role"] == "gateway"
    assert (
        len(
            [
                container
                for container in spec["containers"]
                if container["name"] == "gateway"
            ]
        )
        == 1
    )
    assert (
        len(
            [
                container
                for container in spec["initContainers"]
                if container["name"] == "prepare-private-state"
            ]
        )
        == 1
    )

    volumes = {volume["name"]: volume for volume in spec["volumes"]}
    assert "persistentVolumeClaim" in volumes["openclaw-gateway-state"]
    assert "emptyDir" in volumes["runtime-state"]
    assert "emptyDir" in volumes["runtime-temporary"]


def test_controller_chain_and_ephemeral_updates_are_validated_fail_closed() -> None:
    documents = _yaml_documents(DEPLOY / "adapter-webhook.yaml")
    webhook_configuration = _one(
        documents,
        "ValidatingWebhookConfiguration",
        "openclaw-enterprise-nitro-policy",
    )
    controller_webhook, pod_webhook = webhook_configuration["webhooks"]

    for webhook in (controller_webhook, pod_webhook):
        assert webhook["failurePolicy"] == "Fail"
        assert webhook["sideEffects"] == "None"
        assert webhook["clientConfig"]["service"]["path"] == "/validate"
        assert webhook["namespaceSelector"] == {
            "matchLabels": {"app.kubernetes.io/managed-by": "openclaw-enterprise"}
        }
    assert controller_webhook["rules"] == [
        {
            "apiGroups": ["apps"],
            "apiVersions": ["v1"],
            "operations": ["CREATE", "UPDATE"],
            "resources": ["deployments", "replicasets"],
            "scope": "Namespaced",
        }
    ]
    assert pod_webhook["namespaceSelector"] == {
        "matchLabels": {"app.kubernetes.io/managed-by": "openclaw-enterprise"}
    }
    assert pod_webhook["rules"] == [
        {
            "apiGroups": [""],
            "apiVersions": ["v1"],
            "operations": ["CREATE"],
            "resources": ["pods"],
            "scope": "Namespaced",
        },
        {
            "apiGroups": [""],
            "apiVersions": ["v1"],
            "operations": ["UPDATE"],
            "resources": ["pods/ephemeralcontainers"],
            "scope": "Namespaced",
        },
    ]


def test_webhook_pod_has_restricted_security_and_no_service_account_token() -> None:
    documents = _yaml_documents(DEPLOY / "adapter-webhook.yaml")
    deployment = _one(
        documents,
        "Deployment",
        "openclaw-enterprise-nitro-adapter",
    )
    pod = deployment["spec"]["template"]["spec"]
    container = pod["containers"][0]

    assert pod["automountServiceAccountToken"] is False
    assert pod["enableServiceLinks"] is False
    assert pod["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault"
    assert container["securityContext"] == {
        "allowPrivilegeEscalation": False,
        "readOnlyRootFilesystem": True,
        "runAsNonRoot": True,
        "runAsUser": 65532,
        "runAsGroup": 65532,
        "capabilities": {"drop": ["ALL"]},
    }
    assert container["resources"]["requests"]
    assert container["resources"]["limits"]
    assert container["livenessProbe"]["httpGet"]["scheme"] == "HTTPS"
    assert container["readinessProbe"]["httpGet"]["scheme"] == "HTTPS"


def test_webhook_certificate_and_service_names_match() -> None:
    documents = _yaml_documents(DEPLOY / "adapter-webhook.yaml")
    certificate = _one(
        documents,
        "Certificate",
        "openclaw-enterprise-nitro-adapter-serving",
    )
    service = _one(
        documents,
        "Service",
        "openclaw-enterprise-nitro-adapter",
    )
    namespace = service["metadata"]["namespace"]
    service_name = service["metadata"]["name"]
    expected_names = {
        f"{service_name}.{namespace}.svc",
        f"{service_name}.{namespace}.svc.cluster.local",
    }

    assert set(certificate["spec"]["dnsNames"]) == expected_names
    assert service["spec"]["type"] == "ClusterIP"
    assert service["spec"]["ports"] == [
        {
            "name": "https",
            "port": 443,
            "targetPort": "https",
            "protocol": "TCP",
        }
    ]


def test_rendered_deployment_uses_exact_distinct_images() -> None:
    adapter_image = f"example.invalid/adapter@sha256:{'a' * 64}"
    ownership_image = f"example.invalid/ownership@sha256:{'b' * 64}"
    runtime_image = f"example.invalid/runtime@sha256:{'c' * 64}"
    result = subprocess.run(
        [
            str(RENDER_SCRIPT),
            str(DEPLOY / "adapter-webhook.yaml"),
            adapter_image,
            ownership_image,
            runtime_image,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    documents = [document for document in yaml.safe_load_all(result.stdout) if document]
    deployment = _one(
        documents,
        "Deployment",
        "openclaw-enterprise-nitro-adapter",
    )
    container = deployment["spec"]["template"]["spec"]["containers"][0]

    assert container["image"] == adapter_image
    assert {entry["name"]: entry["value"] for entry in container["env"]}[
        "OCE_OWNERSHIP_INIT_IMAGE"
    ] == ownership_image
    assert {entry["name"]: entry["value"] for entry in container["env"]}[
        "OCE_RUNTIME_IMAGES"
    ] == runtime_image


def test_render_script_rejects_unpinned_or_shared_images() -> None:
    manifest = str(DEPLOY / "adapter-webhook.yaml")
    adapter_image = f"example.invalid/adapter@sha256:{'a' * 64}"
    runtime_image = f"example.invalid/runtime@sha256:{'c' * 64}"

    for ownership_image in ("example.invalid/ownership:latest", adapter_image):
        result = subprocess.run(
            [
                str(RENDER_SCRIPT),
                manifest,
                adapter_image,
                ownership_image,
                runtime_image,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        assert result.returncode == 65


def test_render_script_rejects_manifest_without_target_deployment() -> None:
    adapter_image = f"example.invalid/adapter@sha256:{'a' * 64}"
    ownership_image = f"example.invalid/ownership@sha256:{'b' * 64}"
    runtime_image = f"example.invalid/runtime@sha256:{'c' * 64}"
    result = subprocess.run(
        [
            str(RENDER_SCRIPT),
            str(DEPLOY / "agentgateway.yaml"),
            adapter_image,
            ownership_image,
            runtime_image,
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert result.stdout == ""
