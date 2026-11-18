"""Contracts for the per-tenant private model-gateway path."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import textwrap
from typing import Any

import pytest
import yaml

SAMPLE = pathlib.Path(__file__).resolve().parent.parent
TEMPLATE = SAMPLE / "deploy" / "tenant-model-gateway.yaml.tpl"
SCRIPT = SAMPLE / "scripts" / "configure-tenant-model-gateway.sh"
NETWORK_PROFILE_LABEL = "openclaw.dev/network-profile"
NITRO_RESTRICTED_PROFILE = "nitro-central-gateway-v1"
OWNER = "openclaw-enterprise-blueprint"
CONTEXT = "shared-cluster"
TENANT = "tenant-a"
TENANT_RESOURCES = (
    "configmap/agentgateway-ca",
    "networkpolicy.networking.k8s.io/default-deny-egress",
    "networkpolicy.networking.k8s.io/allow-dns",
    "networkpolicy.networking.k8s.io/allow-agentgateway",
)


def _network_policies() -> list[dict]:
    rendered = (
        TEMPLATE.read_text(encoding="utf-8")
        .replace("OCE_TENANT_NAMESPACE", "tenant-a")
        .replace("OCE_AGENTGATEWAY_SERVICE_CIDR", "10.100.0.42/32")
    )
    return [
        document for document in yaml.safe_load_all(rendered) if document is not None
    ]


def _named(name: str) -> dict:
    matches = [
        policy for policy in _network_policies() if policy["metadata"]["name"] == name
    ]
    assert len(matches) == 1
    return matches[0]


def _write_executable(path: pathlib.Path, source: str) -> None:
    path.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
    path.chmod(0o755)


def _install_fake_kubectl(bin_dir: pathlib.Path) -> None:
    _write_executable(
        bin_dir / "kubectl",
        """
        #!/usr/bin/env python3
        import base64
        import json
        import os
        import pathlib
        import sys

        import yaml

        args = sys.argv[1:]
        state_path = pathlib.Path(os.environ["FAKE_KUBE_STATE"])
        state = json.loads(state_path.read_text())
        stdin = sys.stdin.read()
        with pathlib.Path(os.environ["FAKE_KUBE_LOG"]).open("a") as log:
            log.write(json.dumps({"args": args, "stdin": stdin}) + "\\n")

        if args[:2] == ["config", "get-contexts"]:
            if len(args) > 2 and args[2] == state["context"]:
                print(state["context"])
            raise SystemExit(0)

        if args[:2] != ["--context", state["context"]]:
            print("wrong context", file=sys.stderr)
            raise SystemExit(40)
        command = args[2:]

        if command == ["get", "--raw=/readyz"]:
            print("ok")
        elif command[:2] == ["get", f"namespace/{state['tenant']}"]:
            print(
                f"{state['tenant']}|"
                f"{state.get('namespace_owner', 'openclaw-enterprise')}"
            )
        elif command[:3] == ["get", "service", "agentgateway"]:
            print(state.get("service_ip", "10.100.0.42"))
        elif command[:2] == ["wait", "--namespace"]:
            pass
        elif command[:3] == ["get", "secret", "agentgateway-ca"]:
            print(base64.b64encode(b"test-ca").decode())
        elif command and command[0] == "get":
            resource = command[1]
            owner = state.get("resources", {}).get(resource)
            if owner is not None:
                print(f"{resource.rsplit('/', 1)[1]}|{owner}")
        elif command[:2] == ["label", "--local"]:
            documents = [item for item in yaml.safe_load_all(stdin) if item]
            for document in documents:
                document.setdefault("metadata", {}).setdefault("labels", {})[
                    "app.kubernetes.io/managed-by"
                ] = "openclaw-enterprise-blueprint"
            print(yaml.safe_dump_all(documents), end="")
        elif command[:2] == ["label", f"namespace/{state['tenant']}"]:
            pass
        elif command[:3] == ["create", "configmap", "agentgateway-ca"]:
            print(
                json.dumps(
                    {
                        "apiVersion": "v1",
                        "kind": "ConfigMap",
                        "metadata": {
                            "name": "agentgateway-ca",
                            "namespace": state["tenant"],
                        },
                        "data": {"ca.crt": "test-ca"},
                    }
                )
            )
        elif command == ["create", "--filename", "-"]:
            document = json.loads(stdin)
            resource = f"configmap/{document['metadata']['name']}"
            state.setdefault("resources", {})[resource] = document["metadata"][
                "labels"
            ]["app.kubernetes.io/managed-by"]
            state_path.write_text(json.dumps(state))
        elif command == ["apply", "--filename", "-"]:
            for document in yaml.safe_load_all(stdin):
                resource = (
                    "networkpolicy.networking.k8s.io/"
                    f"{document['metadata']['name']}"
                )
                state.setdefault("resources", {})[resource] = document["metadata"][
                    "labels"
                ]["app.kubernetes.io/managed-by"]
            state_path.write_text(json.dumps(state))
        else:
            print(f"unsupported kubectl call: {args}", file=sys.stderr)
            raise SystemExit(41)
        """,
    )


def _run_configure(
    tmp_path: pathlib.Path,
    *,
    state: dict[str, Any] | None = None,
    context: str = CONTEXT,
) -> tuple[subprocess.CompletedProcess[str], list[dict[str, Any]]]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _install_fake_kubectl(bin_dir)
    state_path = tmp_path / "kube-state.json"
    state_path.write_text(
        json.dumps(
            state
            or {
                "context": CONTEXT,
                "tenant": TENANT,
                "resources": {},
            }
        ),
        encoding="utf-8",
    )
    log_path = tmp_path / "kubectl.log"
    log_path.write_text("", encoding="utf-8")
    result = subprocess.run(
        ["bash", str(SCRIPT), context, TENANT],
        check=False,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "FAKE_KUBE_STATE": str(state_path),
            "FAKE_KUBE_LOG": str(log_path),
        },
    )
    calls = [
        json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()
    ]
    return result, calls


def _mutating_calls(calls: list[dict[str, Any]]) -> list[dict[str, Any]]:
    mutations = {"apply", "create", "label"}
    return [
        call
        for call in calls
        if any(argument in mutations for argument in call["args"])
    ]


def test_default_deny_applies_to_every_tenant_pod() -> None:
    policy = _named("default-deny-egress")

    assert policy["spec"] == {
        "podSelector": {},
        "policyTypes": ["Egress"],
    }


def test_dns_egress_is_explicitly_allowed() -> None:
    policy = _named("allow-dns")

    assert policy["spec"]["podSelector"] == {
        "matchLabels": {
            NETWORK_PROFILE_LABEL: NITRO_RESTRICTED_PROFILE,
        }
    }
    assert policy["spec"]["egress"] == [
        {
            "to": [
                {
                    "namespaceSelector": {
                        "matchLabels": {"kubernetes.io/metadata.name": "kube-system"}
                    },
                    "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}},
                }
            ],
            "ports": [
                {"protocol": "UDP", "port": 53},
                {"protocol": "TCP", "port": 53},
            ],
        }
    ]


def test_network_policy_limits_egress_to_private_agentgateway() -> None:
    policy = _named("allow-agentgateway")

    assert policy["kind"] == "NetworkPolicy"
    assert policy["metadata"] == {
        "name": "allow-agentgateway",
        "namespace": "tenant-a",
    }
    assert policy["spec"]["podSelector"]["matchLabels"] == {
        NETWORK_PROFILE_LABEL: NITRO_RESTRICTED_PROFILE,
    }
    assert policy["spec"]["podSelector"]["matchExpressions"] == [
        {
            "key": "openclaw.dev/workload-role",
            "operator": "In",
            "values": ["agent", "gateway"],
        }
    ]
    assert policy["spec"]["policyTypes"] == ["Egress"]
    assert policy["spec"]["egress"] == [
        {
            "to": [{"ipBlock": {"cidr": "10.100.0.42/32"}}],
            "ports": [{"protocol": "TCP", "port": 443}],
        }
    ]


def test_configure_script_copies_only_public_ca_and_applies_policy() -> None:
    script = SCRIPT.read_text(encoding="utf-8")

    assert "set -euo pipefail" in script
    assert 'readonly -a KUBECTL=(kubectl --context "${KUBE_CONTEXT}")' in script
    assert 'kubectl config get-contexts "${KUBE_CONTEXT}"' in script
    assert "app\\.kubernetes\\.io/managed-by" in script
    assert "pod-security.kubernetes.io/enforce=baseline" in script
    assert "pod-security.kubernetes.io/audit=restricted" in script
    assert "pod-security.kubernetes.io/warn=restricted" in script
    assert "tls\\.crt" in script
    assert "tls\\.key" not in script
    assert "--dry-run=client" in script
    assert ".immutable = true" in script
    assert "agentgateway_cidr" in script
    assert "OCE_AGENTGATEWAY_SERVICE_CIDR" in script


def test_configure_marks_every_created_or_applied_tenant_resource(
    tmp_path: pathlib.Path,
) -> None:
    result, calls = _run_configure(tmp_path)

    assert result.returncode == 0, result.stderr
    created = next(
        call
        for call in calls
        if call["args"][2:] == ["create", "--filename", "-"]
    )
    config_map = json.loads(created["stdin"])
    assert config_map["metadata"]["labels"] == {
        "app.kubernetes.io/managed-by": OWNER
    }

    applied = next(
        call
        for call in calls
        if call["args"][2:] == ["apply", "--filename", "-"]
    )
    policies = [item for item in yaml.safe_load_all(applied["stdin"]) if item]
    assert {item["metadata"]["name"] for item in policies} == {
        "default-deny-egress",
        "allow-dns",
        "allow-agentgateway",
    }
    assert all(
        item["metadata"]["labels"]["app.kubernetes.io/managed-by"] == OWNER
        for item in policies
    )


@pytest.mark.parametrize("resource", TENANT_RESOURCES)
def test_configure_refuses_unowned_existing_tenant_resources_before_mutation(
    tmp_path: pathlib.Path,
    resource: str,
) -> None:
    result, calls = _run_configure(
        tmp_path,
        state={
            "context": CONTEXT,
            "tenant": TENANT,
            "resources": {resource: "another-sample"},
        },
    )

    assert result.returncode != 0
    assert "does not carry the exact" in result.stderr
    assert _mutating_calls(calls) == []


def test_configure_rejects_a_context_that_does_not_exist_exactly(
    tmp_path: pathlib.Path,
) -> None:
    result, calls = _run_configure(tmp_path, context="shared-cluster-typo")

    assert result.returncode != 0
    assert "does not exist exactly" in result.stderr
    assert _mutating_calls(calls) == []
