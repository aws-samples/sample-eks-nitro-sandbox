"""Static security contracts for the AgentGateway EKS deployment."""

from __future__ import annotations

import json
import pathlib
import re
from typing import Any

import yaml

SAMPLE = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = SAMPLE / "deploy" / "agentgateway.yaml"
IAM = SAMPLE / "iam"
README = SAMPLE / "README.md"
SETUP = SAMPLE / "scripts" / "setup-agentgateway.sh"
NAMESPACE = "openclaw-enterprise-agw"
REGION = "us-west-2"
MODEL = "amazon.nova-lite-v1:0"
MODEL_ALIAS = "nova-lite"
REGION_CONFIG_MAP = "agentgateway-aws-region"


def _documents() -> list[dict[str, Any]]:
    return [
        document
        for document in yaml.safe_load_all(MANIFEST.read_text(encoding="utf-8"))
        if document
    ]


def _one(kind: str) -> dict[str, Any]:
    matches = [document for document in _documents() if document["kind"] == kind]
    assert len(matches) == 1, f"expected one {kind}, found {len(matches)}"
    return matches[0]


def _named(kind: str, name: str) -> dict[str, Any]:
    matches = [
        document
        for document in _documents()
        if document["kind"] == kind and document["metadata"]["name"] == name
    ]
    assert len(matches) == 1, f"expected one {kind}/{name}, found {len(matches)}"
    return matches[0]


def _container() -> tuple[dict[str, Any], dict[str, Any]]:
    pod_spec = _one("Deployment")["spec"]["template"]["spec"]
    assert len(pod_spec["containers"]) == 1
    return pod_spec, pod_spec["containers"][0]


def test_namespace_and_service_account_enforce_restricted_identity():
    namespace = _one("Namespace")
    account = _one("ServiceAccount")
    pod_spec, _ = _container()

    assert namespace["metadata"]["name"] == NAMESPACE
    labels = namespace["metadata"]["labels"]
    for mode in ("enforce", "audit", "warn"):
        assert labels[f"pod-security.kubernetes.io/{mode}"] == "restricted"

    assert account["metadata"]["namespace"] == NAMESPACE
    assert account["metadata"]["name"] == "agentgateway"
    assert account["automountServiceAccountToken"] is False
    assert pod_spec["serviceAccountName"] == account["metadata"]["name"]
    assert pod_spec["automountServiceAccountToken"] is False


def test_cert_manager_certificate_matches_service_dns_and_gateway_tls():
    root = _named("Certificate", "agentgateway-root")
    ca_issuer = _named("Issuer", "agentgateway-ca")
    certificate = _named("Certificate", "agentgateway-serving")
    config_map = _one("ConfigMap")
    pod_spec, container = _container()
    config = yaml.safe_load(config_map["data"]["config.yaml"])

    assert root["spec"]["isCA"] is True
    assert root["spec"]["secretName"] == "agentgateway-ca"
    assert ca_issuer["spec"]["ca"]["secretName"] == root["spec"]["secretName"]
    assert certificate["spec"]["issuerRef"]["name"] == ca_issuer["metadata"]["name"]
    assert certificate["spec"]["dnsNames"] == [
        f"agentgateway.{NAMESPACE}.svc",
        f"agentgateway.{NAMESPACE}.svc.cluster.local",
    ]
    assert certificate["spec"]["secretName"] == "agentgateway-tls"

    gateway = config["gateways"]["llm"]
    assert gateway["port"] == 4000
    assert gateway["protocol"] == "HTTPS"
    assert gateway["tls"] == {
        "cert": "/tls/tls.crt",
        "key": "/tls/tls.key",
        "minTLSVersion": "TLS_V1_2",
    }
    assert config["llm"]["gateways"] == ["llm"]

    tls_volume = next(
        volume for volume in pod_spec["volumes"] if volume["name"] == "tls"
    )
    assert tls_volume["secret"]["secretName"] == certificate["spec"]["secretName"]
    assert tls_volume["secret"]["defaultMode"] == 0o440
    tls_mount = next(
        mount for mount in container["volumeMounts"] if mount["name"] == "tls"
    )
    assert tls_mount == {"name": "tls", "mountPath": "/tls", "readOnly": True}


def test_client_key_comes_only_from_a_kubernetes_secret():
    config = yaml.safe_load(_one("ConfigMap")["data"]["config.yaml"])
    _, container = _container()

    api_key = config["llm"]["policies"]["apiKey"]
    assert api_key["mode"] == "strict"
    assert api_key["location"] == {
        "header": {"name": "authorization", "prefix": "Bearer "}
    }
    assert api_key["keys"] == [
        {
            "keyHash": "sha256:${AGW_TENANT_A_KEY_SHA256}",
            "allowedModels": [MODEL_ALIAS],
        },
        {
            "keyHash": "sha256:${AGW_TENANT_B_KEY_SHA256}",
            "allowedModels": [MODEL_ALIAS],
        },
    ]

    for tenant in ("A", "B"):
        client_key = next(
            item
            for item in container["env"]
            if item["name"] == f"AGW_TENANT_{tenant}_KEY_SHA256"
        )
        assert "value" not in client_key
        assert client_key["valueFrom"]["secretKeyRef"] == {
            "name": "agw-client-key",
            "key": f"tenant-{tenant.lower()}-sha256",
            "optional": False,
        }
    session_key = next(
        item for item in container["env"] if item["name"] == "SESSION_KEY"
    )
    assert session_key["valueFrom"]["secretKeyRef"] == {
        "name": "agw-session-key",
        "key": "key",
        "optional": False,
    }
    assert not any(document["kind"] == "Secret" for document in _documents())


def test_setup_labels_agentgateway_secrets_before_any_server_write():
    setup = SETUP.read_text(encoding="utf-8")
    build_start = setup.index('create secret generic agw-client-key')
    plan_end = setup.index('EOF', setup.index('cat >"${destination}/plan"', build_start))
    build = setup[build_start:plan_end]

    for secret_name, output in (
        ("agw-client-key", "secret-client.json"),
        ("agw-session-key", "secret-session.json"),
    ):
        assert f"create secret generic {secret_name}" in build
        assert "--dry-run=client --output=json" in build
        assert f'>"${{destination}}/{output}"' in build

    assert "($owner_label): $owner" in build
    assert "($part_label): $owner" in build
    assert "${KUBECTL[@]} replace" not in build
    assert "${KUBECTL[@]} create --filename" not in build


def test_setup_writes_agentgateway_keys_without_trailing_newlines():
    setup = SETUP.read_text(encoding="utf-8")
    generator = setup[
        setup.index("generate_ed25519_seed() {"):
        setup.index("sha256_value() {")
    ]

    assert "printf '%s' \"${seed}\" >\"${output_file}\"" in generator
    assert "openssl genpkey -algorithm ED25519" in generator
    assert "chmod 600 \"${output_file}\"" in generator


def test_bedrock_model_and_sdk_share_the_runtime_region_source():
    config = yaml.safe_load(_one("ConfigMap")["data"]["config.yaml"])
    _, container = _container()
    model = config["llm"]["models"][0]

    assert model["provider"] == "bedrock"
    assert model["auth"] == {"aws": {}}
    assert model["name"] == MODEL_ALIAS
    assert model["params"] == {"model": MODEL}

    env = {item["name"]: item for item in container["env"]}
    expected_region_source = {
        "configMapKeyRef": {
            "name": REGION_CONFIG_MAP,
            "key": "AWS_REGION",
            "optional": False,
        }
    }
    assert env["AWS_REGION"] == {
        "name": "AWS_REGION",
        "valueFrom": expected_region_source,
    }
    assert env["AWS_DEFAULT_REGION"] == {
        "name": "AWS_DEFAULT_REGION",
        "valueFrom": expected_region_source,
    }

    manifest = MANIFEST.read_text(encoding="utf-8")
    assert "us-west-2" not in manifest
    assert "${AWS_REGION}" not in manifest


def test_deployment_uses_an_immutable_image_and_restricted_container():
    pod_spec, container = _container()

    assert re.fullmatch(
        r"cr\.agentgateway\.dev/agentgateway@sha256:[0-9a-f]{64}",
        container["image"],
    )
    assert pod_spec["enableServiceLinks"] is False
    assert pod_spec["securityContext"]["seccompProfile"] == {"type": "RuntimeDefault"}
    assert pod_spec["securityContext"]["runAsNonRoot"] is True

    security = container["securityContext"]
    assert security["allowPrivilegeEscalation"] is False
    assert security["readOnlyRootFilesystem"] is True
    assert security["runAsNonRoot"] is True
    assert security["capabilities"] == {"drop": ["ALL"]}


def test_deployment_has_resources_health_checks_and_disruption_budget():
    deployment = _one("Deployment")
    budget = _one("PodDisruptionBudget")
    _, container = _container()

    assert deployment["spec"]["replicas"] >= 2
    assert container["resources"]["requests"] == {"cpu": "100m", "memory": "128Mi"}
    assert container["resources"]["limits"] == {"cpu": "1", "memory": "512Mi"}

    assert container["startupProbe"]["httpGet"] == {
        "path": "/healthz/ready",
        "port": "health",
        "scheme": "HTTP",
    }
    assert container["readinessProbe"]["httpGet"] == {
        "path": "/healthz/ready",
        "port": "health",
        "scheme": "HTTP",
    }
    assert container["livenessProbe"]["tcpSocket"] == {"port": "https"}
    assert budget["spec"]["minAvailable"] == 1
    assert budget["spec"]["selector"] == deployment["spec"]["selector"]


def test_service_is_cluster_internal_and_forwards_only_to_https_listener():
    deployment = _one("Deployment")
    service = _one("Service")
    _, container = _container()

    assert service["metadata"]["namespace"] == NAMESPACE
    assert service["spec"]["type"] == "ClusterIP"
    assert service["spec"]["selector"] == deployment["spec"]["selector"]["matchLabels"]
    assert service["spec"]["ports"] == [
        {"name": "https", "port": 443, "targetPort": "https", "protocol": "TCP"}
    ]
    assert {"name": "https", "containerPort": 4000, "protocol": "TCP"} in container[
        "ports"
    ]


def test_bedrock_policy_covers_only_the_configured_regional_foundation_model():
    policy = json.loads((IAM / "bedrock-invoke.json").read_text(encoding="utf-8"))
    assert len(policy["Statement"]) == 1

    statement = policy["Statement"][0]
    expected_actions = {
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
    }
    assert set(statement["Action"]) == expected_actions
    assert statement["Resource"] == (
        f"arn:aws:bedrock:{REGION}::foundation-model/{MODEL}"
    )
    assert statement["Condition"]["StringEquals"] == {
        "aws:RequestedRegion": REGION
    }
    assert "inference-profile" not in json.dumps(policy)
    assert "bedrock:InferenceProfileArn" not in json.dumps(policy)
    assert "*" not in json.dumps(policy)


def test_pod_identity_trust_is_bound_to_agentgateway_service_account():
    policy = json.loads((IAM / "pod-identity-trust.json").read_text(encoding="utf-8"))
    assert len(policy["Statement"]) == 1
    statement = policy["Statement"][0]

    assert statement["Principal"] == {"Service": "pods.eks.amazonaws.com"}
    assert set(statement["Action"]) == {"sts:AssumeRole", "sts:TagSession"}
    assert statement["Condition"]["StringEquals"] == {
        "aws:SourceAccount": "<ACCOUNT_ID>",
        "aws:RequestTag/kubernetes-namespace": NAMESPACE,
        "aws:RequestTag/kubernetes-service-account": "agentgateway",
    }
    assert statement["Condition"]["ArnEquals"] == {
        "aws:SourceArn": ("arn:aws:eks:<REGION>:<ACCOUNT_ID>:cluster/<CLUSTER_NAME>")
    }
