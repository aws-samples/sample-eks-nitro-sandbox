"""Security contracts for tenant isolation around the central Bedrock gateway."""

from __future__ import annotations

import copy
import importlib.util
import pathlib
import re
from types import ModuleType
from typing import Any

import pytest
import yaml

SAMPLE = pathlib.Path(__file__).resolve().parent.parent
ADAPTER_PATH = SAMPLE / "adapter" / "adapter.py"
AGENT_FIXTURE = SAMPLE / "tests" / "fixtures" / "oce-agent-pod.yaml"
AGENTGATEWAY_MANIFEST = SAMPLE / "deploy" / "agentgateway.yaml"
DESIGN_NOTE = SAMPLE / "README.md"

RUNTIME_IMAGE = f"example.invalid/oce-runtime@sha256:{'a' * 64}"
OWNERSHIP_IMAGE = f"example.invalid/ownership-helper@sha256:{'b' * 64}"
AWS_CREDENTIAL_ENV_NAMES = {
    "AWS_ACCESS_KEY_ID",
    "AWS_CONTAINER_AUTHORIZATION_TOKEN",
    "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
    "AWS_CONTAINER_CREDENTIALS_FULL_URI",
    "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
    "AWS_ROLE_ARN",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AWS_WEB_IDENTITY_TOKEN_FILE",
}


def _adapter() -> ModuleType:
    spec = importlib.util.spec_from_file_location("tenant_contract_adapter", ADAPTER_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _yaml_documents(path: pathlib.Path) -> list[dict[str, Any]]:
    return [
        document
        for document in yaml.safe_load_all(path.read_text(encoding="utf-8"))
        if document
    ]


def _one(
    documents: list[dict[str, Any]], kind: str, name: str
) -> dict[str, Any]:
    matches = [
        document
        for document in documents
        if document.get("kind") == kind
        and document.get("metadata", {}).get("name") == name
    ]
    assert len(matches) == 1, f"expected one {kind}/{name}, found {len(matches)}"
    return matches[0]


def _fixture() -> dict[str, Any]:
    pod = _yaml_documents(AGENT_FIXTURE)[0]
    for container in [
        *pod["spec"].get("initContainers", []),
        *pod["spec"]["containers"],
    ]:
        container["image"] = RUNTIME_IMAGE
    return pod


def _apply_json_patch(
    document: dict[str, Any], patch: list[dict[str, Any]]
) -> dict[str, Any]:
    result = copy.deepcopy(document)
    for operation in patch:
        parts = [
            part.replace("~1", "/").replace("~0", "~")
            for part in operation["path"].strip("/").split("/")
        ]
        parent: Any = result
        for part in parts[:-1]:
            parent = parent[int(part)] if isinstance(parent, list) else parent[part]
        key = parts[-1]
        if isinstance(parent, list):
            index = len(parent) if key == "-" else int(key)
            if operation["op"] == "add":
                parent.insert(index, operation["value"])
            elif operation["op"] == "remove":
                parent.pop(index)
            else:
                parent[index] = operation["value"]
        elif operation["op"] == "remove":
            del parent[key]
        else:
            parent[key] = operation["value"]
    return result


def _admit(pod: dict[str, Any], monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    adapter = _adapter()
    monkeypatch.setenv(adapter.RUNTIME_IMAGES_ENV, RUNTIME_IMAGE)
    monkeypatch.setenv(adapter.OWNERSHIP_INIT_IMAGE_ENV, OWNERSHIP_IMAGE)
    admitted = _apply_json_patch(pod, adapter.build_patch(pod))
    adapter.validate_pod(admitted)
    return admitted


def _retarget_gateway(pod: dict[str, Any], gateway_id: str) -> None:
    metadata = pod["metadata"]
    labels = metadata["labels"]
    owner = metadata["ownerReferences"][0]
    old_gateway_id = labels["app.kubernetes.io/name"].removeprefix("gateway-")

    labels["app.kubernetes.io/name"] = f"gateway-{gateway_id}"
    metadata["name"] = metadata["name"].replace(old_gateway_id, gateway_id)
    metadata["generateName"] = metadata["generateName"].replace(
        old_gateway_id, gateway_id
    )
    owner["name"] = owner["name"].replace(old_gateway_id, gateway_id)
    pod["spec"]["serviceAccountName"] = f"agent-{gateway_id}"
    state = next(
        volume
        for volume in pod["spec"]["volumes"]
        if volume["name"] == "openclaw-gateway-state"
    )
    state["persistentVolumeClaim"]["claimName"] = f"gateway-state-{gateway_id}"
    configuration = next(
        volume
        for volume in pod["spec"]["volumes"]
        if volume["name"] == "openclaw-configuration"
    )
    configuration["configMap"]["name"] = configuration["configMap"]["name"].replace(
        old_gateway_id, gateway_id
    )
    gateway = pod["spec"]["containers"][0]
    for entry in gateway["env"]:
        secret = entry.get("valueFrom", {}).get("secretKeyRef")
        if isinstance(secret, dict) and "name" in secret:
            secret["name"] = secret["name"].replace(old_gateway_id, gateway_id)


def test_admitted_agent_has_a_nitro_boundary_and_no_credential_injection(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    admitted = _admit(_fixture(), monkeypatch)
    pod_spec = admitted["spec"]
    gateway = next(
        container
        for container in pod_spec["containers"]
        if container["name"] == "gateway"
    )

    assert pod_spec["runtimeClassName"] == "isolated-sandbox"
    assert pod_spec["automountServiceAccountToken"] is False
    assert gateway["securityContext"] == {
        "allowPrivilegeEscalation": False,
        "capabilities": {"drop": ["ALL"]},
        "privileged": False,
        "readOnlyRootFilesystem": True,
        "runAsNonRoot": True,
        "runAsUser": 1000,
        "runAsGroup": 1000,
        "seccompProfile": {"type": "RuntimeDefault"},
    }

    env_names = {entry["name"] for entry in gateway.get("env", [])}
    assert env_names.isdisjoint(AWS_CREDENTIAL_ENV_NAMES)
    assert "envFrom" not in gateway
    assert "eks.amazonaws.com/role-arn" not in admitted["metadata"].get(
        "annotations", {}
    )

    token_projections = [
        source["serviceAccountToken"]
        for volume in pod_spec["volumes"]
        for source in volume.get("projected", {}).get("sources", [])
        if "serviceAccountToken" in source
    ]
    assert token_projections == [
        {
            "audience": "openclaw-enterprise",
            "expirationSeconds": 900,
            "path": "token",
        }
    ]


def test_each_gateway_uses_its_derived_pvc_and_cannot_mount_another(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    first = _fixture()
    second = _fixture()
    _retarget_gateway(second, "b2c3d4e5f6a7")  # pragma: allowlist secret -- synthetic fixture identity

    first_admitted = _admit(first, monkeypatch)
    second_admitted = _admit(second, monkeypatch)

    def state_claim(pod: dict[str, Any]) -> str:
        state = next(
            volume
            for volume in pod["spec"]["volumes"]
            if volume["name"] == "openclaw-gateway-state"
        )
        return state["persistentVolumeClaim"]["claimName"]

    assert state_claim(first_admitted) == "gateway-state-a1b2c3d4e5f6"
    assert state_claim(second_admitted) == "gateway-state-b2c3d4e5f6a7"
    assert state_claim(first_admitted) != state_claim(second_admitted)

    for admitted in (first_admitted, second_admitted):
        gateway = admitted["spec"]["containers"][0]
        state_mounts = [
            mount
            for mount in gateway["volumeMounts"]
            if mount["name"] == "openclaw-gateway-state"
        ]
        assert state_mounts == [
            {
                "name": "openclaw-gateway-state",
                "mountPath": "/home/node/.openclaw",
            }
        ]

    foreign_claim = _fixture()
    foreign_claim["spec"]["volumes"][3]["persistentVolumeClaim"]["claimName"] = (
        state_claim(second_admitted)
    )
    adapter = _adapter()
    monkeypatch.setenv(adapter.RUNTIME_IMAGES_ENV, RUNTIME_IMAGE)
    monkeypatch.setenv(adapter.OWNERSHIP_INIT_IMAGE_ENV, OWNERSHIP_IMAGE)
    with pytest.raises(
        adapter.AdmissionError, match="inconsistent gateway state claim"
    ):
        adapter.build_patch(foreign_claim)


def test_sample_adds_only_required_service_connectivity_network_policies() -> None:
    manifests = [
        document
        for path in (SAMPLE / "deploy").glob("*.yaml")
        for document in yaml.safe_load_all(path.read_text(encoding="utf-8"))
        if document
    ]
    sample = (SAMPLE / "README.md").read_text(encoding="utf-8")
    scripts = "\n".join(
        path.read_text(encoding="utf-8")
        for path in (SAMPLE / "scripts").glob("*.sh")
    )

    assert not any(document.get("kind") == "NetworkPolicy" for document in manifests)
    # The scripts may read the cluster-wide enforcement setting, but never change it.
    assert "get configmap amazon-vpc-cni" in scripts
    assert not re.search(
        r"\b(apply|patch|create|replace|edit|delete)\b.*amazon-vpc-cni", scripts
    )
    assert '"enable-network-policy-controller":"true"' not in scripts
    assert 'enable-network-policy-controller: "true"' not in scripts
    assert "oce-eks-cluster-dns" in scripts
    assert "oce-private-service-egress" in scripts
    assert "../../isolation/network-policy/README.md" in sample
    assert (
        "It does not provide general tenant network isolation."
        in " ".join(sample.split())
    )


def test_tenant_rolebindings_are_rerunnable() -> None:
    sample = (SAMPLE / "README.md").read_text(encoding="utf-8")

    assert sample.count("create rolebinding openclaw-enterprise-") == 3
    assert sample.count("--dry-run=client --output=yaml |") == 3
    assert sample.count(
        'kubectl --context "$KUBE_CONTEXT" apply --filename -'
    ) >= 3


def test_central_gateway_has_separate_tenant_slots_and_one_bedrock_identity() -> None:
    documents = _yaml_documents(AGENTGATEWAY_MANIFEST)
    config_map = _one(documents, "ConfigMap", "agentgateway-config")
    deployment = _one(documents, "Deployment", "agentgateway")
    service_account = _one(documents, "ServiceAccount", "agentgateway")
    config = yaml.safe_load(config_map["data"]["config.yaml"])
    pod_spec = deployment["spec"]["template"]["spec"]
    container = pod_spec["containers"][0]

    api_key = config["llm"]["policies"]["apiKey"]
    assert api_key["mode"] == "strict"
    assert api_key["location"] == {
        "header": {"name": "authorization", "prefix": "Bearer "}
    }
    assert len(api_key["keys"]) >= 2
    assert all(key["allowedModels"] == ["nova-lite"] for key in api_key["keys"])

    hash_sources = {
        entry["valueFrom"]["secretKeyRef"]["key"]
        for entry in container["env"]
        if entry["name"].startswith("AGW_TENANT_")
    }
    assert hash_sources == {"tenant-a-sha256", "tenant-b-sha256"}

    assert len(config["llm"]["models"]) == 1
    assert config["llm"]["models"][0]["auth"] == {"aws": {}}
    assert service_account["automountServiceAccountToken"] is False
    assert pod_spec["serviceAccountName"] == service_account["metadata"]["name"]
    assert not any(
        "inferenceProfile" in key or "inference-profile" in key
        for tenant_key in api_key["keys"]
        for key in tenant_key
    )


def test_database_and_control_plane_claim_limit_is_explicitly_documented() -> None:
    text = DESIGN_NOTE.read_text(encoding="utf-8").lower()

    assert "database and control-plane boundary" in text
    assert "does not modify upstream oce" in text
    assert "does not enable postgresql" in text
    assert "row-level security" in text
    assert "cross-tenant" in text and "403" in text
    assert "per-tenant bedrock inference profiles are not required" in text


def test_unselected_pod_reasons_do_not_claim_the_sample_ships_no_policy() -> None:
    ash = yaml.safe_load(
        (SAMPLE.parents[2] / ".ash" / ".ash.yaml").read_text(encoding="utf-8")
    )
    reasons = {
        row["path"]: row["reason"]
        for row in ash["global_settings"]["suppressions"]
        if row["rule_id"] == "CKV2_K8S_6"
        and row["path"].startswith("examples/ai-agents/openclaw-enterprise/deploy/")
    }
    manifests = {
        "adapter-webhook.yaml": "admission adapter Pod",
        "agentgateway.yaml": "AgentGateway Pods",
        "oce-validation-postgres.yaml": "disposable validation database Pod",
    }
    scripts = "\n".join(
        path.read_text(encoding="utf-8") for path in (SAMPLE / "scripts").glob("*.sh")
    )
    # Every pod selector of a NetworkPolicy the sample creates, as the scripts render it.
    selectors = (
        {"app.kubernetes.io/name": "openclaw-enterprise"},
        {
            "app.kubernetes.io/managed-by": "openclaw-enterprise",
            "openclaw.dev/workload-role": "gateway",
        },
        {"app.kubernetes.io/name": "oce-api-loopback-relay"},
    )
    assert "app.kubernetes.io/name: openclaw-enterprise\n" in scripts
    assert '"app.kubernetes.io/managed-by": "openclaw-enterprise",' in scripts
    assert '"app.kubernetes.io/name": "oce-api-loopback-relay",' in scripts
    for name, subject in manifests.items():
        reason = reasons[f"examples/ai-agents/openclaw-enterprise/deploy/{name}"]
        assert "ships no NetworkPolicy" not in reason
        assert reason.startswith(f"No NetworkPolicy selects the {subject}:")
        for document in yaml.safe_load_all(
            (SAMPLE / "deploy" / name).read_text(encoding="utf-8")
        ):
            if not document or document.get("kind") not in ("Deployment", "StatefulSet"):
                continue
            labels = document["spec"]["template"]["metadata"]["labels"]
            for selector in selectors:
                assert not selector.items() <= labels.items(), (name, selector)
