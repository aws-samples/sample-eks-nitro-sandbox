from __future__ import annotations

import copy
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

import yaml
from adapter import (
    AGW_CA_MOUNT_PATH,
    AGW_CA_PATH,
    AGW_CA_VOLUME,
    HOME_ENV,
    HOME_MOUNT_PATH,
    LINK_INIT_NAME,
    LINK_SCRIPT,
    NODE_CA_ENV,
    OCE_CONFIGURATION_MOUNT_PATH,
    OCE_CONFIGURATION_VOLUME,
    OCE_SERVICE_PRINCIPAL_MOUNT_PATH,
    OCE_SERVICE_PRINCIPAL_VOLUME,
    OPENCLAW_HOME_PATH,
    OWNER_SCRIPT,
    OWNERSHIP_INIT_NAME,
    RUNTIME_IMAGES_ENV,
    RUNTIME_TMP_VOLUME,
    RUNTIME_VOLUME,
    SHM_MOUNT_PATH,
    STATE_VOLUME,
    TMP_MOUNT_PATH,
    TMPDIR_ENV,
    TMPDIR_PATH,
    AdmissionError,
    build_patch,
    validate_pod,
)

RUNTIME_IMAGE = f"example.invalid/oce@sha256:{'a' * 64}"
OWNERSHIP_INIT_IMAGE_ENV = "OCE_OWNERSHIP_INIT_IMAGE"
OWNERSHIP_INIT_IMAGE = f"example.invalid/ownership-helper@sha256:{'b' * 64}"
NETWORK_PROFILE_LABEL = "openclaw.dev/network-profile"
OCE_BROAD_EGRESS_PROFILE = "broad-egress-v1"
UNSAFE_GLIBC_ENV_NAMES = (
    "GCONV_PATH",
    "GLIBC_TUNABLES",
    "LD_ASSUME_KERNEL",
    "LD_AUDIT",
    "LD_BIND_NOT",
    "LD_BIND_NOW",
    "LD_DEBUG",
    "LD_DEBUG_OUTPUT",
    "LD_DYNAMIC_WEAK",
    "LD_HWCAP_MASK",
    "LD_LIBRARY_PATH",
    "LD_ORIGIN_PATH",
    "LD_POINTER_GUARD",
    "LD_PREFER_MAP_32BIT_EXEC",
    "LD_PRELOAD",
    "LD_PROFILE",
    "LD_PROFILE_OUTPUT",
    "LD_SHOW_AUXV",
    "LD_TRACE_LOADED_OBJECTS",
    "LD_USE_LOAD_BIAS",
    "LD_VERBOSE",
    "LD_WARN",
)
UNSAFE_SHELL_ENV_NAMES = (
    "BASHOPTS",
    "BASH_ENV",
    "ENV",
    "PS4",
    "SHELLOPTS",
    "ZDOTDIR",
)


def run_link_script(
    state_root: pathlib.Path,
    links: list[dict[str, str]],
) -> subprocess.CompletedProcess[str]:
    root_declaration = 'const root = "/gateway-state";'
    if LINK_SCRIPT.count(root_declaration) != 1:
        raise AssertionError("LINK_SCRIPT state root declaration changed")
    script = LINK_SCRIPT.replace(
        root_declaration,
        f"const root = {json.dumps(str(state_root))};",
        1,
    )
    environment = os.environ.copy()
    environment["OCE_STATE_LINKS"] = json.dumps(links)
    return subprocess.run(
        ["node", "-e", script],
        capture_output=True,
        check=False,
        env=environment,
        text=True,
        timeout=10,
    )


def runtime_security_context() -> dict:
    return {
        "allowPrivilegeEscalation": False,
        "capabilities": {"drop": ["ALL"]},
        "privileged": False,
        "readOnlyRootFilesystem": True,
        "runAsNonRoot": True,
        "runAsUser": 1000,
        "runAsGroup": 1000,
        "seccompProfile": {"type": "RuntimeDefault"},
    }


def prep_security_context() -> dict:
    return {
        "allowPrivilegeEscalation": False,
        "readOnlyRootFilesystem": True,
        "capabilities": {"drop": ["ALL"]},
    }


PREP_SCRIPT = """const { chmodSync, mkdirSync } = require("node:fs");
for (const path of ["/runtime-state/home","/runtime-temporary/tmp","/runtime-state/home/gateway-codex-home","/gateway-state/sessions","/runtime-state/home/.openclaw","/gateway-state/agents"]) {
  mkdirSync(path, { recursive: true });
  chmodSync(path, 0o700);
}
mkdirSync("/runtime-temporary/tmp", { recursive: true, mode: 0o700 });"""


def target_pod() -> dict:
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": "gateway-a1b2c3d4e5f6-abc123def-test1",
            "generateName": "gateway-a1b2c3d4e5f6-abc123def-",
            "namespace": "oce-tenant-test",
            "labels": {
                "app.kubernetes.io/managed-by": "openclaw-enterprise",
                "app.kubernetes.io/name": "gateway-a1b2c3d4e5f6",
                "openclaw.dev/agent": "agt_11111111-1111-1111-1111-111111111111",
                "openclaw.dev/namespace": "ns_22222222-2222-2222-2222-222222222222",
                "openclaw.dev/revision": "rev_33333333-3333-3333-3333-333333333333",
                "openclaw.dev/service-principal": (
                    "service-agent-agt_11111111-1111-1111-1111-111111111111"
                ),
                "openclaw.dev/workload-role": "gateway",
                NETWORK_PROFILE_LABEL: OCE_BROAD_EGRESS_PROFILE,
            },
            "ownerReferences": [
                {
                    "apiVersion": "apps/v1",
                    "controller": True,
                    "kind": "ReplicaSet",
                    "name": "gateway-a1b2c3d4e5f6-abc123def",
                    "uid": "11111111-2222-3333-4444-555555555555",
                }
            ],
        },
        "spec": {
            "serviceAccountName": "agent-a1b2c3d4e5f6",
            "initContainers": [
                {
                    "name": "prepare-private-state",
                    "image": RUNTIME_IMAGE,
                    "imagePullPolicy": "IfNotPresent",
                    "command": ["/usr/bin/tini", "-s", "--", "node", "-e"],
                    "args": [PREP_SCRIPT],
                    "securityContext": prep_security_context(),
                    "volumeMounts": [
                        {
                            "name": "runtime-state",
                            "mountPath": "/runtime-state",
                            "mountPropagation": "HostToContainer",
                        },
                        {
                            "name": "openclaw-gateway-state",
                            "mountPath": "/gateway-state",
                        },
                        {
                            "name": "runtime-temporary",
                            "mountPath": "/runtime-temporary",
                        },
                    ],
                },
                {
                    "name": "prepare-embedded-gateway-owner",
                    "image": RUNTIME_IMAGE,
                    "command": ["node", "-e"],
                    "args": [OWNER_SCRIPT],
                    "securityContext": {
                        "allowPrivilegeEscalation": False,
                        "readOnlyRootFilesystem": True,
                        "capabilities": {"drop": ["ALL"]},
                    },
                    "volumeMounts": [
                        {
                            "name": "gateway-owner-key",
                            "mountPath": "/run/oce-gateway-owner-key",
                        },
                        {
                            "name": "gateway-owner-start",
                            "mountPath": "/run/oce-gateway-owner-start",
                        },
                    ],
                },
            ],
            "containers": [
                {
                    "name": "gateway",
                    "image": RUNTIME_IMAGE,
                    "command": ["/usr/bin/tini", "--", "node", "-e"],
                    "args": ["console.log('gateway')"],
                    "securityContext": runtime_security_context(),
                    "volumeMounts": [
                        {
                            "name": "runtime-state",
                            "mountPath": "/home/node",
                            "subPath": "home",
                            "mountPropagation": "HostToContainer",
                        },
                        {
                            "name": "workspace",
                            "mountPath": "/workspace",
                            "subPathExpr": "$(TENANT)/workspace",
                            "readOnly": True,
                            "recursiveReadOnly": "Enabled",
                        },
                        {
                            "name": "runtime-temporary",
                            "mountPath": TMP_MOUNT_PATH,
                            "subPath": "tmp",
                        },
                        {
                            "name": "openclaw-gateway-state",
                            "mountPath": "/home/node/.openclaw/sessions",
                            "subPath": "sessions",
                        },
                        {
                            "name": "openclaw-gateway-state",
                            "mountPath": "/home/node/.openclaw/agents",
                            "subPath": "agents",
                        },
                    ],
                },
            ],
            "volumes": [
                {"name": "runtime-state", "emptyDir": {}},
                {"name": "runtime-temporary", "emptyDir": {}},
                {"name": "workspace", "emptyDir": {}},
                {
                    "name": "openclaw-gateway-state",
                    "persistentVolumeClaim": {
                        "claimName": "gateway-state-a1b2c3d4e5f6"
                    },
                },
                {"name": "gateway-owner-key", "emptyDir": {}},
                {"name": "gateway-owner-start", "emptyDir": {}},
                {
                    "name": "openclaw-service-principal",
                    "projected": {
                        "sources": [
                            {
                                "serviceAccountToken": {
                                    "audience": "openclaw-enterprise",
                                    "expirationSeconds": 900,
                                    "path": "token",
                                }
                            }
                        ]
                    },
                },
            ],
        },
    }


def prepare_private_state_container(pod: dict) -> dict:
    return next(
        container
        for container in pod["spec"]["initContainers"]
        if container["name"] == "prepare-private-state"
    )


def admitted_target_pod() -> dict:
    pod = target_pod()
    pod["spec"]["volumes"].extend(
        [
            {
                "name": "kube-api-access-k82tq",
                "projected": {
                    "defaultMode": 420,
                    "sources": [
                        {
                            "serviceAccountToken": {
                                "expirationSeconds": 3607,
                                "path": "token",
                            }
                        },
                        {
                            "configMap": {
                                "name": "kube-root-ca.crt",
                                "items": [{"key": "ca.crt", "path": "ca.crt"}],
                            }
                        },
                        {
                            "downwardAPI": {
                                "items": [
                                    {
                                        "path": "namespace",
                                        "fieldRef": {
                                            "apiVersion": "v1",
                                            "fieldPath": "metadata.namespace",
                                        },
                                    }
                                ]
                            }
                        },
                    ],
                },
            },
            {
                "name": "projected-settings",
                "emptyDir": {},
            },
        ]
    )

    for container in [
        *pod["spec"]["initContainers"],
        *pod["spec"]["containers"],
    ]:
        container.setdefault("volumeMounts", []).append(
            {
                "name": "kube-api-access-k82tq",
                "readOnly": True,
                "mountPath": "/var/run/secrets/kubernetes.io/serviceaccount",
            }
        )

    pod["spec"]["containers"][-1]["volumeMounts"].extend(
        [
            {
                "name": "projected-settings",
                "mountPath": "/etc/runtime-settings",
                "readOnly": True,
            },
        ]
    )
    return pod


def apply_patch(document: dict, patch: list[dict]) -> dict:
    result = copy.deepcopy(document)
    for operation in patch:
        parts = [
            part.replace("~1", "/").replace("~0", "~")
            for part in operation["path"].strip("/").split("/")
        ]
        parent = result
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
        else:
            if operation["op"] == "remove":
                del parent[key]
            else:
                parent[key] = operation["value"]
    return result


@mock.patch.dict(
    os.environ,
    {
        OWNERSHIP_INIT_IMAGE_ENV: OWNERSHIP_INIT_IMAGE,
        RUNTIME_IMAGES_ENV: RUNTIME_IMAGE,
    },
)
class BuildPatchTests(unittest.TestCase):
    def test_preserves_oce_broad_egress_profile(self) -> None:
        pod = target_pod()

        rendered = apply_patch(pod, build_patch(pod))

        self.assertEqual(
            rendered["metadata"]["labels"][NETWORK_PROFILE_LABEL],
            OCE_BROAD_EGRESS_PROFILE,
        )
        self.assertFalse(
            any(
                operation["path"] == "/metadata/labels/openclaw.dev~1network-profile"
                for operation in build_patch(pod)
            )
        )
        validate_pod(rendered)

    def test_refuses_absent_network_profile(self) -> None:
        pod = target_pod()
        pod["metadata"]["labels"].pop(NETWORK_PROFILE_LABEL)

        with self.assertRaisesRegex(AdmissionError, "must use.*network-profile"):
            build_patch(pod)

    def test_refuses_unknown_network_profile(self) -> None:
        pod = target_pod()
        pod["metadata"]["labels"][NETWORK_PROFILE_LABEL] = "unexpected-profile"

        with self.assertRaisesRegex(AdmissionError, "must use.*network-profile"):
            build_patch(pod)

    def test_final_validator_rejects_network_profile_tampering(self) -> None:
        rendered = apply_patch(target_pod(), build_patch(target_pod()))

        for value in (None, "unexpected-profile"):
            with self.subTest(value=value):
                tampered = copy.deepcopy(rendered)
                labels = tampered["metadata"]["labels"]
                if value is None:
                    labels.pop(NETWORK_PROFILE_LABEL)
                else:
                    labels[NETWORK_PROFILE_LABEL] = value

                with self.assertRaisesRegex(AdmissionError, "final OCE Pod must use"):
                    validate_pod(tampered)

    def test_preinjected_agentgateway_ca_contract_is_idempotent(self) -> None:
        pod = target_pod()
        gateway = pod["spec"]["containers"][0]
        pod["spec"]["volumes"].append(
            {
                "name": AGW_CA_VOLUME,
                "configMap": {
                    "name": AGW_CA_VOLUME,
                    "items": [{"key": "ca.crt", "path": "ca.crt"}],
                    "defaultMode": 420,
                },
            }
        )
        gateway["volumeMounts"].append(
            {
                "name": AGW_CA_VOLUME,
                "mountPath": AGW_CA_MOUNT_PATH,
                "readOnly": True,
            }
        )
        gateway.setdefault("env", []).append(
            {"name": NODE_CA_ENV, "value": f"{AGW_CA_MOUNT_PATH}/ca.crt"}
        )

        rendered = apply_patch(pod, build_patch(pod))

        self.assertEqual(
            sum(
                volume.get("name") == AGW_CA_VOLUME
                for volume in rendered["spec"]["volumes"]
            ),
            1,
        )
        rendered_gateway = rendered["spec"]["containers"][0]
        self.assertEqual(
            sum(
                mount.get("name") == AGW_CA_VOLUME
                for mount in rendered_gateway["volumeMounts"]
            ),
            1,
        )
        self.assertEqual(
            sum(entry.get("name") == NODE_CA_ENV for entry in rendered_gateway["env"]),
            1,
        )
        validate_pod(rendered)

    def test_final_validator_accepts_canonical_prepare_mounts_in_any_order(
        self,
    ) -> None:
        pod = target_pod()
        prep = prepare_private_state_container(pod)
        prep["volumeMounts"] = [
            prep["volumeMounts"][0],
            prep["volumeMounts"][2],
            prep["volumeMounts"][1],
        ]

        rendered = apply_patch(pod, build_patch(pod))

        validate_pod(rendered)

    def test_final_validator_accepts_kubernetes_init_container_defaults(
        self,
    ) -> None:
        pod = target_pod()
        rendered = apply_patch(pod, build_patch(pod))
        init_containers = rendered["spec"]["initContainers"]
        for name in (OWNERSHIP_INIT_NAME, LINK_INIT_NAME):
            container = next(
                item for item in init_containers if item.get("name") == name
            )
            container.update(
                {
                    "imagePullPolicy": "IfNotPresent",
                    "resources": {
                        "limits": {"cpu": "4", "memory": "2Gi"},
                        "requests": {"cpu": "100m", "memory": "128Mi"},
                    },
                    "terminationMessagePath": "/dev/termination-log",
                    "terminationMessagePolicy": "File",
                }
            )

        validate_pod(rendered)

    def test_final_validator_accepts_nested_state_link_parent_directory(
        self,
    ) -> None:
        pod = target_pod()
        nested_mount = next(
            mount
            for mount in pod["spec"]["containers"][0]["volumeMounts"]
            if mount.get("mountPath") == "/home/node/.openclaw/agents"
        )
        nested_mount["mountPath"] = "/home/node/.openclaw/agents/main/agent"
        nested_mount["subPath"] = "agent"
        prep = prepare_private_state_container(pod)
        prep["args"] = [
            PREP_SCRIPT.replace(
                '"/gateway-state/agents"]',
                '"/runtime-state/home/.openclaw/agents/main","/gateway-state/agent"]',
            )
        ]

        rendered = apply_patch(pod, build_patch(pod))

        validate_pod(rendered)

    def test_final_validator_rejects_nondefault_init_container_fields(
        self,
    ) -> None:
        pod = target_pod()
        rendered = apply_patch(pod, build_patch(pod))
        ownership = next(
            item
            for item in rendered["spec"]["initContainers"]
            if item.get("name") == OWNERSHIP_INIT_NAME
        )
        ownership["terminationMessagePath"] = "/attacker-controlled"

        with self.assertRaisesRegex(
            AdmissionError,
            "terminationMessagePath does not match the Kubernetes default",
        ):
            validate_pod(rendered)

    def test_rejects_noncanonical_preinjected_agentgateway_ca_contract(self) -> None:
        base = target_pod()
        canonical_volume = {
            "name": AGW_CA_VOLUME,
            "configMap": {
                "name": AGW_CA_VOLUME,
                "items": [{"key": "ca.crt", "path": "ca.crt"}],
            },
        }
        canonical_mount = {
            "name": AGW_CA_VOLUME,
            "mountPath": AGW_CA_MOUNT_PATH,
            "readOnly": True,
        }
        cases = []

        wrong_volume = copy.deepcopy(base)
        wrong_volume["spec"]["volumes"].append(
            {
                "name": AGW_CA_VOLUME,
                "configMap": {
                    "name": "attacker-controlled",
                    "items": [{"key": "ca.crt", "path": "ca.crt"}],
                },
            }
        )
        cases.append(wrong_volume)

        wrong_mount = copy.deepcopy(base)
        wrong_mount["spec"]["volumes"].append(copy.deepcopy(canonical_volume))
        wrong_mount["spec"]["containers"][0]["volumeMounts"].append(
            {
                "name": AGW_CA_VOLUME,
                "mountPath": AGW_CA_MOUNT_PATH,
                "readOnly": False,
            }
        )
        cases.append(wrong_mount)

        init_mount = copy.deepcopy(base)
        init_mount["spec"]["volumes"].append(copy.deepcopy(canonical_volume))
        init_mount["spec"]["initContainers"][0]["volumeMounts"].append(
            copy.deepcopy(canonical_mount)
        )
        cases.append(init_mount)

        missing_mount = copy.deepcopy(base)
        missing_mount["spec"]["volumes"].append(copy.deepcopy(canonical_volume))
        cases.append(missing_mount)

        for pod in cases:
            with self.subTest(pod=pod), self.assertRaises(AdmissionError):
                build_patch(pod)

    def test_published_admission_fixture_is_accepted_and_hardened(self) -> None:
        fixture = (
            pathlib.Path(__file__).resolve().parent.parent
            / "tests"
            / "fixtures"
            / "oce-agent-pod.yaml"
        )
        pod = yaml.safe_load(fixture.read_text(encoding="utf-8"))
        for group in ("initContainers", "containers"):
            for container in pod["spec"][group]:
                container["image"] = RUNTIME_IMAGE

        rendered = apply_patch(pod, build_patch(pod))
        self.assertEqual(rendered["spec"]["runtimeClassName"], "isolated-sandbox")
        self.assertFalse(rendered["spec"]["automountServiceAccountToken"])

        gateway = next(
            container
            for container in rendered["spec"]["containers"]
            if container["name"] == "gateway"
        )
        self.assertEqual(
            gateway["securityContext"],
            runtime_security_context(),
        )
        self.assertEqual(
            {entry["name"] for entry in gateway["env"]},
            {
                "OPENAI_API_KEY",
                "OPENCLAW_GATEWAY_PASSWORD",
                "OPENCLAW_HARNESS_CREDENTIAL_ENV",
                "OPENCLAW_POD_UID",
                HOME_ENV,
                NODE_CA_ENV,
                TMPDIR_ENV,
            },
        )
        self.assertEqual(
            {mount["name"] for mount in gateway["volumeMounts"]},
            {
                RUNTIME_VOLUME,
                "workspace",
                STATE_VOLUME,
                AGW_CA_VOLUME,
                OCE_CONFIGURATION_VOLUME,
            },
        )

        ownership = next(
            container
            for container in rendered["spec"]["initContainers"]
            if container["name"] == OWNERSHIP_INIT_NAME
        )
        self.assertEqual(ownership["image"], OWNERSHIP_INIT_IMAGE)
        self.assertEqual(ownership["command"], ["/ownership-helper"])

    def test_runs_path_safe_ownership_helper_with_explicit_allowlists(self) -> None:
        pod = target_pod()
        rendered = apply_patch(pod, build_patch(pod))
        original_init_names = {
            container["name"] for container in pod["spec"]["initContainers"]
        }
        ownership_init_containers = [
            container
            for container in rendered["spec"]["initContainers"]
            if container["name"] not in original_init_names
            and container["name"] != LINK_INIT_NAME
        ]

        self.assertEqual(len(ownership_init_containers), 1)
        ownership_init = ownership_init_containers[0]
        self.assertEqual(
            {mount["name"] for mount in ownership_init["volumeMounts"]},
            {"runtime-state", "openclaw-gateway-state"},
        )
        self.assertEqual(ownership_init["image"], OWNERSHIP_INIT_IMAGE)
        self.assertNotEqual(ownership_init["image"], RUNTIME_IMAGE)
        self.assertEqual(ownership_init["command"], ["/ownership-helper"])

        args = ownership_init["args"]
        self.assertEqual(args[:2], ["--root", "/home/node"])
        allowlist_args = args[2:]
        self.assertEqual(len(allowlist_args) % 2, 0)
        allowlists = {
            (allowlist_args[index], allowlist_args[index + 1])
            for index in range(0, len(allowlist_args), 2)
        }
        self.assertEqual(
            allowlists,
            {
                ("--dir", "."),
                ("--dir", ".openclaw"),
                ("--dir", ".openclaw/agents"),
                ("--dir", ".openclaw/sessions"),
                ("--optional-dir", ".openclaw/control"),
                ("--file", ".openclaw/client/credentials.sqlite"),
                ("--file", ".openclaw/control/services.sqlite"),
                ("--file", ".openclaw/control/services.sqlite-wal"),
                ("--file", ".openclaw/control/services.sqlite-shm"),
                ("--file", ".openclaw/control/services.sqlite-journal"),
            },
        )
        for flag, path in allowlists:
            self.assertIn(flag, {"--dir", "--optional-dir", "--file"})
            self.assertFalse(path.startswith("/"))
        self.assertEqual(ownership_init.get("env", []), [])

        ownership_index = rendered["spec"]["initContainers"].index(ownership_init)
        link_index = next(
            index
            for index, container in enumerate(rendered["spec"]["initContainers"])
            if container["name"] == LINK_INIT_NAME
        )
        self.assertLess(ownership_index, link_index)

    def test_requires_separately_configured_digest_pinned_ownership_image(
        self,
    ) -> None:
        invalid_images = (
            None,
            "example.invalid/ownership-helper:latest",
            f"example.invalid/ownership helper@sha256:{'b' * 64}",
            RUNTIME_IMAGE,
        )
        for image in invalid_images:
            with self.subTest(image=image):
                environment = {RUNTIME_IMAGES_ENV: RUNTIME_IMAGE}
                if image is not None:
                    environment[OWNERSHIP_INIT_IMAGE_ENV] = image
                with (
                    mock.patch.dict(os.environ, environment, clear=True),
                    self.assertRaisesRegex(
                        AdmissionError,
                        OWNERSHIP_INIT_IMAGE_ENV,
                    ),
                ):
                    build_patch(target_pod())

    def test_requires_trustworthy_prepare_private_state_contract(self) -> None:
        mutations = (
            ("unpinned image", {"image": "example.invalid/oce:latest"}),
            (
                "whitespace image",
                {"image": f"example.invalid/oce runtime@sha256:{'a' * 64}"},
            ),
            (
                "different image",
                {"image": f"example.invalid/other@sha256:{'c' * 64}"},
            ),
            ("custom command", {"command": ["/bin/sh", "-c", "id"]}),
            ("custom args", {"args": [f"{PREP_SCRIPT}\nprocess.exit(0);"]}),
            (
                "custom environment",
                {"env": [{"name": "NODE_OPTIONS", "value": "-r x"}]},
            ),
            ("custom security", {"securityContext": runtime_security_context()}),
        )
        for name, mutation in mutations:
            with self.subTest(name=name):
                pod = target_pod()
                prepare_private_state_container(pod).update(mutation)
                with self.assertRaisesRegex(
                    AdmissionError,
                    "prepare-private-state|designated runtime|runtime allowlist|unsafe bootstrap",
                ):
                    build_patch(pod)

    def test_requires_fixed_embedded_owner_contract(self) -> None:
        mutations = (
            ("custom args", {"args": ["console.log('attacker')"]}),
            (
                "custom environment",
                {"env": [{"name": "NODE_OPTIONS", "value": "-r x"}]},
            ),
            ("custom command", {"command": ["/bin/sh", "-c"]}),
        )
        for name, mutation in mutations:
            with self.subTest(name=name):
                pod = target_pod()
                owner = next(
                    container
                    for container in pod["spec"]["initContainers"]
                    if container["name"] == "prepare-embedded-gateway-owner"
                )
                owner.update(mutation)
                with self.assertRaisesRegex(
                    AdmissionError,
                    "embedded-owner|unsafe bootstrap",
                ):
                    build_patch(pod)

    def test_rejects_native_sidecars(self) -> None:
        pod = target_pod()
        pod["spec"]["initContainers"].insert(
            0,
            {
                "name": "native-sidecar",
                "image": RUNTIME_IMAGE,
                "restartPolicy": "Always",
                "securityContext": {"runAsUser": 0},
            },
        )
        with self.assertRaisesRegex(AdmissionError, "native sidecars"):
            build_patch(pod)

    def test_requires_prepare_private_state_command_and_exact_directories(
        self,
    ) -> None:
        for omitted in ("command", "args"):
            with self.subTest(omitted=omitted):
                pod = target_pod()
                del prepare_private_state_container(pod)[omitted]
                with self.assertRaisesRegex(
                    AdmissionError,
                    "fixed prepare-private-state command",
                ):
                    build_patch(pod)

        pod = target_pod()
        prepare_private_state_container(pod)["args"] = [
            PREP_SCRIPT.replace(
                '"/gateway-state/agents"]',
                '"/gateway-state/agents","/gateway-state/arbitrary"]',
            )
        ]
        with self.assertRaisesRegex(
            AdmissionError,
            "directories do not match the mount contract",
        ):
            build_patch(pod)

    def test_accepts_pinned_oce_gateway_codex_home_source_directory(self) -> None:
        pod = target_pod()
        gateway = pod["spec"]["containers"][-1]
        gateway["volumeMounts"].append(
            {
                "name": "runtime-state",
                "mountPath": ("/home/node/.openclaw/agents/main/agent/codex-home"),
                "subPath": "home/gateway-codex-home",
            }
        )
        rendered = apply_patch(pod, build_patch(pod))

        self.assertEqual(
            rendered["spec"]["containers"][-1]["securityContext"]["runAsUser"],
            1000,
        )

    def test_relocates_designated_runtime_home_to_runtime_state_root(self) -> None:
        pod = target_pod()

        rendered = apply_patch(pod, build_patch(pod))

        gateway = rendered["spec"]["containers"][-1]
        home_mounts = [
            mount
            for mount in gateway["volumeMounts"]
            if mount.get("mountPath") == "/home/node"
        ]
        self.assertEqual(
            home_mounts,
            [
                {
                    "name": "runtime-state",
                    "mountPath": "/home/node",
                    "mountPropagation": "HostToContainer",
                }
            ],
        )

    def test_rebases_nested_runtime_state_subpaths_from_relocated_home(self) -> None:
        pod = target_pod()
        gateway = pod["spec"]["containers"][-1]
        gateway["volumeMounts"].append(
            {
                "name": "runtime-state",
                "mountPath": ("/home/node/.openclaw/agents/main/agent/codex-home"),
                "subPath": "home/gateway-codex-home",
            }
        )

        rendered = apply_patch(pod, build_patch(pod))

        gateway = rendered["spec"]["containers"][-1]
        codex_home_mount = next(
            mount
            for mount in gateway["volumeMounts"]
            if mount.get("mountPath")
            == "/home/node/.openclaw/agents/main/agent/codex-home"
        )
        self.assertEqual(codex_home_mount["subPath"], "gateway-codex-home")

    def test_mounts_runtime_state_root_in_ownership_init_container(self) -> None:
        pod = target_pod()

        rendered = apply_patch(pod, build_patch(pod))

        ownership_init = next(
            container
            for container in rendered["spec"]["initContainers"]
            if container["name"]
            not in {
                *{original["name"] for original in pod["spec"]["initContainers"]},
                LINK_INIT_NAME,
            }
        )
        runtime_mount = next(
            mount
            for mount in ownership_init["volumeMounts"]
            if mount["name"] == "runtime-state"
        )
        self.assertEqual(
            runtime_mount,
            {
                "name": "runtime-state",
                "mountPath": "/home/node",
            },
        )

    def test_marks_only_migration_control_directory_as_optional(self) -> None:
        pod = target_pod()

        rendered = apply_patch(pod, build_patch(pod))

        ownership_init = next(
            container
            for container in rendered["spec"]["initContainers"]
            if container["name"]
            not in {
                *{original["name"] for original in pod["spec"]["initContainers"]},
                LINK_INIT_NAME,
            }
        )
        allowlists = set(
            zip(ownership_init["args"][2::2], ownership_init["args"][3::2])
        )
        self.assertEqual(
            {path for flag, path in allowlists if flag == "--optional-dir"},
            {".openclaw/control"},
        )
        self.assertTrue(
            {
                ".",
                ".openclaw",
                ".openclaw/agents",
                ".openclaw/sessions",
            }.issubset({path for flag, path in allowlists if flag == "--dir"})
        )

    def test_patches_prepare_private_state_for_relocated_runtime_root(self) -> None:
        pod = target_pod()

        rendered = apply_patch(pod, build_patch(pod))

        prep = next(
            container
            for container in rendered["spec"]["initContainers"]
            if container["name"] == "prepare-private-state"
        )
        directories_line = prep["args"][0].splitlines()[1]
        prefix = "for (const path of "
        suffix = ") {"
        directories = json.loads(directories_line[len(prefix) : -len(suffix)])
        self.assertEqual(
            set(directories),
            {
                "/runtime-temporary/tmp",
                "/runtime-state/gateway-codex-home",
                "/gateway-state/sessions",
                "/runtime-state/.openclaw",
                "/gateway-state/agents",
            },
        )
        self.assertFalse(
            any(
                directory.startswith("/runtime-state/home") for directory in directories
            )
        )

    def test_rejects_malformed_missing_or_duplicate_runtime_home_mounts(
        self,
    ) -> None:
        malformed = target_pod()
        malformed_home = malformed["spec"]["containers"][-1]["volumeMounts"][0]
        malformed_home.pop("subPath")
        malformed_home["subPathExpr"] = "$(RUNTIME_HOME)"

        missing = target_pod()
        missing["spec"]["containers"][-1]["volumeMounts"] = [
            mount
            for mount in missing["spec"]["containers"][-1]["volumeMounts"]
            if mount.get("mountPath") != "/home/node"
        ]

        duplicate = target_pod()
        duplicate["spec"]["containers"][-1]["volumeMounts"].append(
            copy.deepcopy(duplicate["spec"]["containers"][-1]["volumeMounts"][0])
        )

        for name, pod in (
            ("malformed", malformed),
            ("missing", missing),
            ("duplicate", duplicate),
        ):
            with (
                self.subTest(name=name),
                self.assertRaisesRegex(
                    AdmissionError,
                    "runtime-state|/home/node",
                ),
            ):
                build_patch(pod)

    def test_rejects_another_volume_masking_runtime_home(self) -> None:
        for mount_path in ("/home/node", "/home"):
            with self.subTest(mount_path=mount_path):
                pod = target_pod()
                pod["spec"]["containers"][-1]["volumeMounts"].append(
                    {
                        "name": "workspace",
                        "mountPath": mount_path,
                    }
                )
                with self.assertRaisesRegex(
                    AdmissionError,
                    "runtime home",
                ):
                    build_patch(pod)

    def test_rejects_noncanonical_mount_paths(self) -> None:
        for mount_path in (
            "/home/node/../../gateway-state/arbitrary/leaf",
            "/home//node/.openclaw/sessions",
            "//home/node/.openclaw/sessions",
            "home/node/.openclaw/sessions",
        ):
            with self.subTest(mount_path=mount_path):
                pod = target_pod()
                pod["spec"]["containers"][-1]["volumeMounts"][1]["mountPath"] = (
                    mount_path
                )
                with self.assertRaisesRegex(
                    AdmissionError,
                    "(normalized absolute|absolute) path",
                ):
                    build_patch(pod)

    def test_rejects_prepare_private_state_mount_contract_drift(self) -> None:
        mutations = (
            {"readOnly": True},
            {"subPath": "home"},
            {"mountPropagation": "Bidirectional"},
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                pod = target_pod()
                prepare_private_state_container(pod)["volumeMounts"][0].update(mutation)
                with self.assertRaisesRegex(
                    AdmissionError,
                    "prepare-private-state volume-mount contract",
                ):
                    build_patch(pod)

        pod = target_pod()
        prepare_private_state_container(pod)["volumeMounts"].append(
            {"name": "workspace", "mountPath": "/usr/bin"}
        )
        with self.assertRaisesRegex(
            AdmissionError,
            "prepare-private-state volume-mount contract",
        ):
            build_patch(pod)

    def test_runtime_container_remains_non_root_and_unwrapped(self) -> None:
        pod = target_pod()
        original_gateway = copy.deepcopy(pod["spec"]["containers"][-1])
        rendered = apply_patch(pod, build_patch(pod))
        gateway = rendered["spec"]["containers"][-1]

        self.assertEqual(gateway["command"], original_gateway["command"])
        self.assertEqual(gateway["args"], original_gateway["args"])
        self.assertEqual(gateway["securityContext"]["runAsUser"], 1000)
        self.assertEqual(gateway["securityContext"]["runAsGroup"], 1000)
        self.assertTrue(gateway["securityContext"]["runAsNonRoot"])
        self.assertFalse(gateway["securityContext"]["allowPrivilegeEscalation"])
        self.assertTrue(gateway["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual(
            gateway["securityContext"]["capabilities"],
            {"drop": ["ALL"]},
        )

    def test_rejects_runtime_without_hardened_security_context(self) -> None:
        for change in (
            {"securityContext": {"readOnlyRootFilesystem": True}},
            {
                "securityContext": {
                    "allowPrivilegeEscalation": False,
                    "capabilities": {
                        "drop": ["ALL"],
                        "add": ["SYS_ADMIN"],
                    },
                    "readOnlyRootFilesystem": True,
                }
            },
        ):
            with self.subTest(change=change):
                pod = target_pod()
                pod["spec"]["containers"][-1].update(change)
                with self.assertRaises(AdmissionError):
                    build_patch(pod)

    def test_rejects_privileged_runtime_security_overrides(self) -> None:
        for field, value in (
            ("privileged", True),
            ("procMount", "Unmasked"),
            ("seccompProfile", {"type": "Unconfined"}),
        ):
            with self.subTest(field=field):
                pod = target_pod()
                pod["spec"]["containers"][-1]["securityContext"][field] = value
                with self.assertRaisesRegex(AdmissionError, "must start as"):
                    build_patch(pod)

    def test_applies_runtime_contract_to_every_regular_container(self) -> None:
        rendered = apply_patch(target_pod(), build_patch(target_pod()))

        for container in rendered["spec"]["containers"]:
            self.assertEqual(container["image"], RUNTIME_IMAGE)
            self.assertEqual(
                container["securityContext"],
                runtime_security_context(),
                container["name"],
            )

        pod = target_pod()
        alternate_image = f"example.invalid/helper@sha256:{'d' * 64}"
        pod["spec"]["containers"][0]["image"] = alternate_image
        with self.assertRaisesRegex(AdmissionError, "runtime allowlist"):
            build_patch(pod)

        for field, value in (
            ("image", "example.invalid/helper:latest"),
            ("securityContext", {}),
        ):
            with self.subTest(field=field):
                pod = target_pod()
                pod["spec"]["containers"][0][field] = value
                with self.assertRaises(AdmissionError):
                    build_patch(pod)

    def test_rejects_state_mounts_in_sidecars_before_rewrite(self) -> None:
        pod = target_pod()
        sidecar = copy.deepcopy(pod["spec"]["containers"][0])
        sidecar["name"] = "unexpected-state-consumer"
        sidecar["volumeMounts"] = [
            {
                "name": RUNTIME_VOLUME,
                "mountPath": HOME_MOUNT_PATH,
                "subPath": "home",
            }
        ]
        pod["spec"]["containers"].append(sidecar)

        with self.assertRaisesRegex(
            AdmissionError,
            "embedded gateway contract permits no sidecars",
        ):
            build_patch(pod)

    def test_rejects_state_mounts_in_additional_init_containers_before_rewrite(
        self,
    ) -> None:
        pod = target_pod()
        extra_init = copy.deepcopy(pod["spec"]["initContainers"][0])
        extra_init["name"] = "unexpected-state-consumer"
        extra_init["volumeMounts"] = [
            {
                "name": STATE_VOLUME,
                "mountPath": "/gateway-state",
            }
        ]
        pod["spec"]["initContainers"].append(extra_init)

        with self.assertRaisesRegex(
            AdmissionError,
            "embedded gateway contract permits only its two OCE init containers",
        ):
            build_patch(pod)

    @unittest.skipUnless(
        pathlib.Path("/proc/self/fd").is_dir(),
        "secure descriptor traversal requires Linux /proc",
    )
    def test_link_script_creates_nested_links_without_following_parents(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            state_root = pathlib.Path(temporary_directory) / "gateway-state"
            state_root.mkdir()
            (state_root / "agent").mkdir()

            result = run_link_script(
                state_root,
                [{"link": "nested/state/agent", "target": "agent"}],
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            link = state_root / "nested" / "state" / "agent"
            self.assertTrue(link.is_symlink())
            self.assertEqual(link.resolve(), state_root / "agent")

    @unittest.skipUnless(
        pathlib.Path("/proc/self/fd").is_dir(),
        "secure descriptor traversal requires Linux /proc",
    )
    def test_link_script_rejects_symlinked_parent_without_writing_through_it(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = pathlib.Path(temporary_directory)
            state_root = temporary_root / "gateway-state"
            outside = temporary_root / "outside"
            state_root.mkdir()
            outside.mkdir()
            (state_root / "nested").mkdir()
            (state_root / "nested" / "hostile").symlink_to(
                outside,
                target_is_directory=True,
            )

            result = run_link_script(
                state_root,
                [{"link": "nested/hostile/state/agent", "target": "agent"}],
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("refusing unsafe state-link parent", result.stderr)
            self.assertFalse((outside / "state").exists())

    def test_rejects_read_only_gateway_state_rewrites(self) -> None:
        for field, value in (
            ("readOnly", True),
            ("recursiveReadOnly", "Enabled"),
        ):
            with self.subTest(field=field):
                pod = target_pod()
                pod["spec"]["containers"][-1]["volumeMounts"][-1][field] = value
                with self.assertRaisesRegex(
                    AdmissionError,
                    "read-only subPath mounts cannot be safely rewritten",
                ):
                    build_patch(pod)

    def test_configures_private_runtime_tmp_directory(self) -> None:
        rendered = apply_patch(target_pod(), build_patch(target_pod()))
        gateway = next(
            container
            for container in rendered["spec"]["containers"]
            if container["name"] == "gateway"
        )
        self.assertIn(
            {"name": TMPDIR_ENV, "value": TMPDIR_PATH},
            gateway["env"],
        )

    def test_uses_runtime_shm_for_openclaw_temporary_files(self) -> None:
        rendered = apply_patch(target_pod(), build_patch(target_pod()))
        gateway = next(
            container
            for container in rendered["spec"]["containers"]
            if container["name"] == "gateway"
        )
        source_tmp = next(
            mount
            for mount in target_pod()["spec"]["containers"][-1]["volumeMounts"]
            if mount["mountPath"] == TMP_MOUNT_PATH
        )
        self.assertEqual(source_tmp["subPath"], "tmp")
        self.assertFalse(
            any(
                mount["mountPath"] == TMP_MOUNT_PATH
                for mount in gateway["volumeMounts"]
            )
        )
        self.assertIn(
            {"name": TMPDIR_ENV, "value": SHM_MOUNT_PATH},
            gateway["env"],
        )

    def test_accepts_missing_tmp_mount(self) -> None:
        pod = target_pod()
        pod["spec"]["containers"][-1]["volumeMounts"] = [
            mount
            for mount in pod["spec"]["containers"][-1]["volumeMounts"]
            if mount["mountPath"] != TMP_MOUNT_PATH
        ]
        rendered = apply_patch(pod, build_patch(pod))
        gateway = rendered["spec"]["containers"][-1]
        self.assertFalse(
            any(
                mount["mountPath"] == TMP_MOUNT_PATH
                for mount in gateway["volumeMounts"]
            )
        )

    def test_rejects_mounts_that_overlap_runtime_tmp(self) -> None:
        for mount_path in ("/", "/tmp/cache", "//tmp", "//tmp/cache"):
            with self.subTest(mount_path=mount_path):
                pod = target_pod()
                pod["spec"]["containers"][-1]["volumeMounts"].append(
                    {
                        "name": "workspace",
                        "mountPath": mount_path,
                    }
                )
                with self.assertRaisesRegex(
                    AdmissionError,
                    "((overlaps|duplicate) /tmp|normalized absolute path|trusted bootstrap)",
                ):
                    build_patch(pod)

    def test_rejects_unexpected_existing_tmp_mount(self) -> None:
        pod = target_pod()
        for field, value in (
            ("name", "workspace"),
            ("subPath", "cache"),
            ("subPathExpr", "$(TMP_SUBPATH)"),
            ("readOnly", True),
        ):
            with self.subTest(field=field):
                changed = copy.deepcopy(pod)
                changed_mount = changed["spec"]["containers"][-1]["volumeMounts"][2]
                changed_mount[field] = value
                with self.assertRaisesRegex(
                    AdmissionError, f"{RUNTIME_TMP_VOLUME} subPath tmp"
                ):
                    build_patch(changed)

    def test_requires_runtime_temporary_empty_dir(self) -> None:
        pod = target_pod()
        temporary_volume = next(
            volume
            for volume in pod["spec"]["volumes"]
            if volume["name"] == RUNTIME_TMP_VOLUME
        )
        del temporary_volume["emptyDir"]
        temporary_volume["persistentVolumeClaim"] = {"claimName": "unexpected"}
        with self.assertRaisesRegex(AdmissionError, "exactly one emptyDir"):
            build_patch(pod)

    def test_rejects_mount_that_overlaps_runtime_shm(self) -> None:
        pod = target_pod()
        pod["spec"]["containers"][-1]["volumeMounts"].append(
            {"name": "workspace", "mountPath": SHM_MOUNT_PATH}
        )
        with self.assertRaisesRegex(AdmissionError, "/dev/shm"):
            build_patch(pod)

    def test_rejects_mounts_over_trusted_bootstrap_executables(self) -> None:
        for mount_path in (
            "/bin",
            "/bin/sh",
            "/usr",
            "/usr/bin",
            "/usr/bin/chmod",
            "/usr/bin/chown",
            "/usr/bin/setpriv",
            "/lib",
            "/lib64",
            "/usr/lib",
            "/usr/lib64",
            "/etc/ld.so.cache",
            "/etc/ld.so.preload",
        ):
            with self.subTest(mount_path=mount_path):
                pod = target_pod()
                pod["spec"]["containers"][-1]["volumeMounts"].append(
                    {"name": "workspace", "mountPath": mount_path}
                )
                with self.assertRaisesRegex(AdmissionError, "trusted bootstrap path"):
                    build_patch(pod)

    def test_rejects_nonempty_env_from_on_wrapped_runtime(self) -> None:
        for source in (
            {"configMapRef": {"name": "runtime-environment"}},
            {"secretRef": {"name": "runtime-secrets"}},
        ):
            with self.subTest(source=source):
                pod = target_pod()
                pod["spec"]["containers"][-1]["envFrom"] = [source]
                with self.assertRaisesRegex(AdmissionError, "envFrom"):
                    build_patch(pod)

    def test_rejects_explicit_unsafe_bootstrap_environment(self) -> None:
        for name in UNSAFE_GLIBC_ENV_NAMES:
            with self.subTest(name=name):
                pod = target_pod()
                pod["spec"]["containers"][-1].setdefault("env", []).append(
                    {"name": name, "value": "attacker-controlled"}
                )
                with self.assertRaisesRegex(
                    AdmissionError, f"unsafe bootstrap environment {name}"
                ):
                    build_patch(pod)

    def test_rejects_explicit_shell_control_environment(self) -> None:
        for name in UNSAFE_SHELL_ENV_NAMES:
            with self.subTest(name=name):
                pod = target_pod()
                pod["spec"]["containers"][-1].setdefault("env", []).append(
                    {"name": name, "value": "attacker-controlled"}
                )
                with self.assertRaisesRegex(
                    AdmissionError, f"unsafe bootstrap environment {name}"
                ):
                    build_patch(pod)

    def test_rejects_aws_credential_environment(self) -> None:
        names = (
            "AWS_ACCESS_KEY",
            "AWS_ACCESS_KEY_ID",
            "AWS_CREDENTIAL_PROFILES_FILE",
            "AWS_CONFIG_FILE",
            "AWS_CONTAINER_AUTHORIZATION_TOKEN",
            "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
            "AWS_CONTAINER_CREDENTIALS_FULL_URI",
            "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
            "AWS_DEFAULT_PROFILE",
            "AWS_PROFILE",
            "AWS_ROLE_ARN",
            "AWS_SECRET_KEY",
            "AWS_SECRET_ACCESS_KEY",
            "AWS_SECURITY_TOKEN",
            "AWS_SESSION_TOKEN",
            "AWS_SHARED_CREDENTIALS_FILE",
            "AWS_WEB_IDENTITY_TOKEN_FILE",
            "BOTO_CONFIG",
        )
        for value_source in (
            {"value": "attacker-controlled"},
            {"valueFrom": {"secretKeyRef": {"name": "aws", "key": "credential"}}},
        ):
            for name in names:
                with self.subTest(name=name, value_source=value_source):
                    pod = target_pod()
                    pod["spec"]["containers"][-1].setdefault("env", []).append(
                        {"name": name, **value_source}
                    )
                    with self.assertRaisesRegex(
                        AdmissionError,
                        f"prohibited AWS credential environment {name}",
                    ):
                        build_patch(pod)

    def test_rejects_revision_bound_legacy_aws_credential_environment(
        self,
    ) -> None:
        for name in ("AWS_ACCESS_KEY", "AWS_SECRET_KEY"):
            with self.subTest(name=name):
                pod = target_pod()
                pod["spec"]["volumes"].append(
                    {
                        "name": OCE_CONFIGURATION_VOLUME,
                        "configMap": {
                            "name": "gateway-a1b2c3d4e5f6-rev-012345abcdef",
                            "items": [
                                {"key": "openclaw.json", "path": "openclaw.json"}
                            ],
                        },
                    }
                )
                pod["spec"]["containers"][-1].setdefault("env", []).extend(
                    [
                        {
                            "name": name,
                            "valueFrom": {
                                "secretKeyRef": {
                                    "name": (
                                        "harness-secrets-a1b2c3d4e5f6-012345abcdef"
                                    ),
                                    "key": name,
                                }
                            },
                        },
                        {
                            "name": "OPENCLAW_HARNESS_CREDENTIAL_ENV",
                            "value": name,
                        },
                    ]
                )

                with self.assertRaisesRegex(
                    AdmissionError,
                    f"prohibited AWS credential environment {name}",
                ):
                    build_patch(pod)

    def test_pins_runtime_home_environment(self) -> None:
        rendered = apply_patch(target_pod(), build_patch(target_pod()))
        gateway = rendered["spec"]["containers"][-1]

        self.assertIn(
            {"name": HOME_ENV, "value": HOME_MOUNT_PATH},
            gateway["env"],
        )

        for value_source in (
            {"value": "/workspace/aws-home"},
            {"valueFrom": {"configMapKeyRef": {"name": "home", "key": "path"}}},
        ):
            with self.subTest(value_source=value_source):
                pod = target_pod()
                pod["spec"]["containers"][-1].setdefault("env", []).append(
                    {"name": HOME_ENV, **value_source}
                )
                with self.assertRaisesRegex(AdmissionError, HOME_ENV):
                    build_patch(pod)

    def test_rejects_unsupported_environment_value_sources(self) -> None:
        sources = (
            {"secretKeyRef": {"name": "tenant-secret", "key": "value"}},
            {"configMapKeyRef": {"name": "tenant-config", "key": "value"}},
            {"fieldRef": {"apiVersion": "v1", "fieldPath": "metadata.labels"}},
            {
                "resourceFieldRef": {
                    "containerName": "gateway",
                    "resource": "limits.cpu",
                }
            },
        )
        for source in sources:
            with self.subTest(source=source):
                pod = target_pod()
                pod["spec"]["containers"][-1].setdefault("env", []).append(
                    {"name": "UNTRUSTED_VALUE", "valueFrom": source}
                )
                with self.assertRaisesRegex(
                    AdmissionError, "unsupported environment value source"
                ):
                    build_patch(pod)

    def test_accepts_exact_oce_environment_value_sources(self) -> None:
        for credential_name in (
            "ANTHROPIC_API_KEY",
            "OCE_MODEL_API_KEY",
            "OPENAI_API_KEY",
        ):
            with self.subTest(credential_name=credential_name):
                pod = target_pod()
                pod["spec"]["volumes"].append(
                    {
                        "name": OCE_CONFIGURATION_VOLUME,
                        "configMap": {
                            "name": "gateway-a1b2c3d4e5f6-rev-012345abcdef",
                            "items": [
                                {"key": "openclaw.json", "path": "openclaw.json"}
                            ],
                        },
                    }
                )
                pod["spec"]["containers"][-1].setdefault("env", []).extend(
                    [
                        {
                            "name": "OPENCLAW_POD_UID",
                            "valueFrom": {
                                "fieldRef": {
                                    "apiVersion": "v1",
                                    "fieldPath": "metadata.uid",
                                }
                            },
                        },
                        {
                            "name": "OPENCLAW_GATEWAY_PASSWORD",
                            "valueFrom": {
                                "secretKeyRef": {
                                    "name": "gateway-password-a1b2c3d4e5f6",
                                    "key": "gateway-password",
                                }
                            },
                        },
                        {
                            "name": credential_name,
                            "valueFrom": {
                                "secretKeyRef": {
                                    "name": (
                                        "harness-secrets-a1b2c3d4e5f6-012345abcdef"
                                    ),
                                    "key": credential_name,
                                }
                            },
                        },
                        {
                            "name": "OPENCLAW_HARNESS_CREDENTIAL_ENV",
                            "value": credential_name,
                        },
                    ]
                )

                rendered = apply_patch(pod, build_patch(pod))
                validate_pod(rendered)

    def test_rejects_bootstrap_environment_as_harness_credential(self) -> None:
        for credential_name in (
            "PATH",
            "NODE_PATH",
            "PYTHONPATH",
            "OPENSSL_CONF",
        ):
            with self.subTest(credential_name=credential_name):
                pod = target_pod()
                pod["spec"]["volumes"].append(
                    {
                        "name": OCE_CONFIGURATION_VOLUME,
                        "configMap": {
                            "name": "gateway-a1b2c3d4e5f6-rev-012345abcdef",
                            "items": [
                                {"key": "openclaw.json", "path": "openclaw.json"}
                            ],
                        },
                    }
                )
                pod["spec"]["containers"][-1].setdefault("env", []).extend(
                    [
                        {
                            "name": credential_name,
                            "valueFrom": {
                                "secretKeyRef": {
                                    "name": (
                                        "harness-secrets-a1b2c3d4e5f6-012345abcdef"
                                    ),
                                    "key": credential_name,
                                }
                            },
                        },
                        {
                            "name": "OPENCLAW_HARNESS_CREDENTIAL_ENV",
                            "value": credential_name,
                        },
                    ]
                )

                with self.assertRaisesRegex(
                    AdmissionError,
                    (
                        "selects unsupported harness credential environment "
                        f"{credential_name}"
                    ),
                ):
                    build_patch(pod)

    def test_rejects_oce_secret_reference_not_bound_to_gateway_revision(
        self,
    ) -> None:
        invalid_credentials = (
            {"name": "OPENAI_API_KEY", "value": "literal-secret"},
            {
                "name": "OPENAI_API_KEY",
                "valueFrom": {
                    "secretKeyRef": {
                        "name": "harness-secrets-other-tenant-deadbeefcafe",
                        "key": "OPENAI_API_KEY",
                    }
                },
            },
            None,
        )
        for credential in invalid_credentials:
            with self.subTest(credential=credential):
                pod = target_pod()
                pod["spec"]["volumes"].append(
                    {
                        "name": OCE_CONFIGURATION_VOLUME,
                        "configMap": {
                            "name": "gateway-a1b2c3d4e5f6-rev-012345abcdef",
                            "items": [
                                {"key": "openclaw.json", "path": "openclaw.json"}
                            ],
                        },
                    }
                )
                environment = pod["spec"]["containers"][-1].setdefault("env", [])
                if credential is not None:
                    environment.append(credential)
                environment.append(
                    {
                        "name": "OPENCLAW_HARNESS_CREDENTIAL_ENV",
                        "value": "OPENAI_API_KEY",
                    }
                )

                with self.assertRaisesRegex(AdmissionError, "revision-bound Secret"):
                    build_patch(pod)

    def test_rejects_oce_secret_reference_from_another_revision(self) -> None:
        pod = target_pod()
        pod["spec"]["volumes"].append(
            {
                "name": OCE_CONFIGURATION_VOLUME,
                "configMap": {
                    "name": "gateway-a1b2c3d4e5f6-rev-012345abcdef",
                    "items": [{"key": "openclaw.json", "path": "openclaw.json"}],
                },
            }
        )
        pod["spec"]["containers"][-1].setdefault("env", []).extend(
            [
                {
                    "name": "OPENAI_API_KEY",
                    "valueFrom": {
                        "secretKeyRef": {
                            "name": "harness-secrets-a1b2c3d4e5f6-deadbeefcafe",
                            "key": "OPENAI_API_KEY",
                        }
                    },
                },
                {
                    "name": "OPENCLAW_HARNESS_CREDENTIAL_ENV",
                    "value": "OPENAI_API_KEY",
                },
            ]
        )

        with self.assertRaisesRegex(AdmissionError, "revision-bound Secret"):
            build_patch(pod)

    def test_rejects_duplicate_environment_names(self) -> None:
        pod = target_pod()
        pod["spec"]["containers"][-1]["env"] = [
            {"name": "DUPLICATE", "value": "first"},
            {"name": "DUPLICATE", "value": "second"},
        ]
        with self.assertRaisesRegex(
            AdmissionError, "duplicate environment entries: DUPLICATE"
        ):
            build_patch(pod)

    def test_rejects_file_backed_aws_credentials(self) -> None:
        for volume_source in (
            {"secret": {"secretName": "aws-credentials"}},
            {"configMap": {"name": "aws-credentials"}},
            {
                "projected": {
                    "sources": [
                        {"secret": {"name": "aws-credentials"}},
                    ]
                }
            },
        ):
            with self.subTest(volume_source=volume_source):
                pod = target_pod()
                pod["spec"]["volumes"].append(
                    {"name": "aws-credentials", **volume_source}
                )
                pod["spec"]["containers"][-1]["volumeMounts"].append(
                    {
                        "name": "aws-credentials",
                        "mountPath": f"{HOME_MOUNT_PATH}/.aws",
                        "readOnly": True,
                    }
                )
                with self.assertRaisesRegex(
                    AdmissionError, "provide AWS credential files"
                ):
                    build_patch(pod)

    def test_rejects_credential_capable_mounts_outside_approved_paths(self) -> None:
        for volume_source in (
            {"secret": {"secretName": "tenant-bootstrap"}},
            {"configMap": {"name": "tenant-bootstrap"}},
            {"projected": {"sources": [{"secret": {"name": "tenant-bootstrap"}}]}},
            {"csi": {"driver": "secrets-store.csi.k8s.io"}},
            {
                "persistentVolumeClaim": {
                    "claimName": "attacker-credentials",
                }
            },
            {"hostPath": {"path": "/var/lib/credentials"}},
            {"nfs": {"server": "nfs.example.invalid", "path": "/credentials"}},
            {
                "ephemeral": {
                    "volumeClaimTemplate": {
                        "spec": {
                            "accessModes": ["ReadOnlyMany"],
                            "resources": {"requests": {"storage": "1Gi"}},
                        }
                    }
                }
            },
        ):
            with self.subTest(volume_source=volume_source):
                pod = target_pod()
                pod["spec"]["volumes"].append(
                    {"name": "tenant-bootstrap", **volume_source}
                )
                pod["spec"]["containers"][-1]["volumeMounts"].append(
                    {
                        "name": "tenant-bootstrap",
                        "mountPath": "/credentials/.aws",
                        "readOnly": True,
                    }
                )
                with self.assertRaisesRegex(
                    AdmissionError, "unsupported credential-capable volume mount"
                ):
                    build_patch(pod)

    def test_accepts_exact_oce_credential_capable_mounts(self) -> None:
        pod = target_pod()
        pod["spec"]["volumes"].append(
            {
                "name": OCE_CONFIGURATION_VOLUME,
                "configMap": {
                    "name": "gateway-a1b2c3d4e5f6-rev-012345abcdef",
                    "items": [{"key": "openclaw.json", "path": "openclaw.json"}],
                },
            }
        )
        pod["spec"]["containers"][-1]["volumeMounts"].extend(
            [
                {
                    "name": OCE_CONFIGURATION_VOLUME,
                    "mountPath": OCE_CONFIGURATION_MOUNT_PATH,
                    "readOnly": True,
                },
                {
                    "name": OCE_SERVICE_PRINCIPAL_VOLUME,
                    "mountPath": OCE_SERVICE_PRINCIPAL_MOUNT_PATH,
                    "readOnly": True,
                },
            ]
        )

        rendered = apply_patch(pod, build_patch(pod))
        validate_pod(rendered)

    def test_rejects_tampered_oce_configuration_volume(self) -> None:
        pod = target_pod()
        pod["spec"]["volumes"].append(
            {
                "name": OCE_CONFIGURATION_VOLUME,
                "configMap": {
                    "name": "aws-credentials",
                    "items": [{"key": "credentials", "path": "openclaw.json"}],
                },
            }
        )
        pod["spec"]["containers"][-1]["volumeMounts"].append(
            {
                "name": OCE_CONFIGURATION_VOLUME,
                "mountPath": OCE_CONFIGURATION_MOUNT_PATH,
                "readOnly": True,
            }
        )

        with self.assertRaisesRegex(
            AdmissionError, "unsupported credential-capable volume mount"
        ):
            build_patch(pod)

    def test_rejects_tampered_oce_service_principal_volume(self) -> None:
        pod = target_pod()
        service_principal = next(
            volume
            for volume in pod["spec"]["volumes"]
            if volume["name"] == OCE_SERVICE_PRINCIPAL_VOLUME
        )
        service_principal["projected"]["sources"].append(
            {"secret": {"name": "aws-credentials"}}
        )
        pod["spec"]["containers"][-1]["volumeMounts"].append(
            {
                "name": OCE_SERVICE_PRINCIPAL_VOLUME,
                "mountPath": OCE_SERVICE_PRINCIPAL_MOUNT_PATH,
                "readOnly": True,
            }
        )

        with self.assertRaisesRegex(
            AdmissionError, "unsupported credential-capable volume mount"
        ):
            build_patch(pod)

    def test_final_validator_rejects_aws_credential_mount_tampering(self) -> None:
        for volume_source in (
            {"secret": {"secretName": "aws-credentials"}},
            {
                "persistentVolumeClaim": {
                    "claimName": "attacker-credentials",
                }
            },
            {"hostPath": {"path": "/var/lib/credentials"}},
            {"nfs": {"server": "nfs.example.invalid", "path": "/credentials"}},
            {
                "ephemeral": {
                    "volumeClaimTemplate": {
                        "spec": {
                            "accessModes": ["ReadOnlyMany"],
                            "resources": {"requests": {"storage": "1Gi"}},
                        }
                    }
                }
            },
        ):
            with self.subTest(volume_source=volume_source):
                rendered = apply_patch(target_pod(), build_patch(target_pod()))
                rendered["spec"]["volumes"].append(
                    {"name": "aws-credentials", **volume_source}
                )
                rendered["spec"]["containers"][-1]["volumeMounts"].append(
                    {
                        "name": "aws-credentials",
                        "mountPath": f"{HOME_MOUNT_PATH}/.aws",
                        "readOnly": True,
                    }
                )

                with self.assertRaisesRegex(
                    AdmissionError, "provide AWS credential files"
                ):
                    validate_pod(rendered)

    def test_final_validator_requires_runtime_environment(self) -> None:
        for name, value in (
            (HOME_ENV, HOME_MOUNT_PATH),
            (NODE_CA_ENV, AGW_CA_PATH),
            (TMPDIR_ENV, TMPDIR_PATH),
        ):
            with self.subTest(name=name):
                rendered = apply_patch(target_pod(), build_patch(target_pod()))
                gateway = rendered["spec"]["containers"][-1]
                gateway["env"] = [
                    entry for entry in gateway["env"] if entry.get("name") != name
                ]

                with self.assertRaisesRegex(
                    AdmissionError, f"must configure {name}={value}"
                ):
                    validate_pod(rendered)

    def test_rejects_exec_lifecycle_hooks_and_probes(self) -> None:
        exec_action = {"exec": {"command": ["/bin/sh", "-c", "id"]}}
        cases = (
            ("postStart", "lifecycle", {"postStart": exec_action}),
            ("preStop", "lifecycle", {"preStop": exec_action}),
            ("livenessProbe", "livenessProbe", exec_action),
            ("readinessProbe", "readinessProbe", exec_action),
            ("startupProbe", "startupProbe", exec_action),
        )
        for name, field, value in cases:
            with self.subTest(name=name):
                pod = target_pod()
                pod["spec"]["containers"][-1][field] = copy.deepcopy(value)
                with self.assertRaises(AdmissionError):
                    build_patch(pod)

    def test_does_not_inject_glibc_loader_environment(self) -> None:
        rendered = apply_patch(target_pod(), build_patch(target_pod()))
        gateway = rendered["spec"]["containers"][-1]
        self.assertFalse(
            {
                entry["name"]
                for entry in gateway["env"]
                if entry["name"] in UNSAFE_GLIBC_ENV_NAMES
            }
        )

    def test_requires_digest_pinned_image_for_wrapped_runtime(self) -> None:
        pod = target_pod()
        pod["spec"]["containers"][-1]["image"] = "example.invalid/oce:latest"

        with self.assertRaisesRegex(AdmissionError, "exact sha256 digest"):
            build_patch(pod)

    def test_requires_read_only_root_filesystem(self) -> None:
        pod = target_pod()
        pod["spec"]["containers"][-1]["securityContext"] = {}
        with self.assertRaisesRegex(AdmissionError, "read-only root filesystem"):
            build_patch(pod)

    def test_removes_preinjected_service_account_volume_only(self) -> None:
        pod = admitted_target_pod()
        preserved = copy.deepcopy(pod["spec"]["volumes"][-1:])

        volumes = apply_patch(pod, build_patch(pod))["spec"]["volumes"]

        self.assertNotIn(
            "kube-api-access-k82tq",
            [volume["name"] for volume in volumes],
        )
        for volume in preserved:
            self.assertIn(volume, volumes)

    def test_rejects_mixed_service_account_projection(self) -> None:
        pod = admitted_target_pod()
        default_projection = next(
            volume
            for volume in pod["spec"]["volumes"]
            if volume["name"] == "kube-api-access-k82tq"
        )
        default_projection["projected"]["sources"].append(
            {"secret": {"name": "tenant-bootstrap"}}
        )

        with self.assertRaisesRegex(
            AdmissionError,
            "does not match Kubernetes' default service-account projection",
        ):
            build_patch(pod)

    def test_removes_preinjected_service_account_mounts_only(self) -> None:
        pod = admitted_target_pod()
        service_account_mount = {
            "name": "kube-api-access-k82tq",
            "readOnly": True,
            "mountPath": "/var/run/secrets/kubernetes.io/serviceaccount",
        }
        unrelated_mount = {
            "name": "projected-settings",
            "mountPath": "/etc/runtime-settings",
            "readOnly": True,
        }
        rendered = apply_patch(pod, build_patch(pod))
        spec = rendered["spec"]

        for container in [
            *spec["initContainers"],
            *spec["containers"],
        ]:
            self.assertNotIn(
                service_account_mount,
                container.get("volumeMounts", []),
                container["name"],
            )
        rendered_gateway = next(
            container
            for container in spec["containers"]
            if container["name"] == "gateway"
        )
        self.assertIn(unrelated_mount, rendered_gateway["volumeMounts"])

    def test_rewrites_structurally_and_preserves_unrelated_mounts(self) -> None:
        pod = target_pod()
        workspace = copy.deepcopy(pod["spec"]["containers"][-1]["volumeMounts"][1])

        rendered = apply_patch(pod, build_patch(pod))
        spec = rendered["spec"]

        self.assertEqual(spec["runtimeClassName"], "isolated-sandbox")
        self.assertIs(spec["automountServiceAccountToken"], False)
        prep = next(
            container
            for container in spec["initContainers"]
            if container["name"] == "prepare-private-state"
        )
        self.assertEqual(
            prep["securityContext"],
            {
                "allowPrivilegeEscalation": False,
                "readOnlyRootFilesystem": True,
                "runAsUser": 1000,
                "runAsGroup": 1000,
                "runAsNonRoot": True,
                "capabilities": {"drop": ["ALL"]},
                "seccompProfile": {"type": "RuntimeDefault"},
            },
        )
        gateway_mounts = spec["containers"][-1]["volumeMounts"]
        self.assertEqual(gateway_mounts[1], workspace)
        self.assertEqual(
            [
                mount
                for mount in gateway_mounts
                if mount["name"] == "openclaw-gateway-state"
            ],
            [
                {
                    "name": "openclaw-gateway-state",
                    "mountPath": OPENCLAW_HOME_PATH,
                }
            ],
        )
        self.assertIn(
            {
                "name": AGW_CA_VOLUME,
                "mountPath": AGW_CA_MOUNT_PATH,
                "readOnly": True,
            },
            gateway_mounts,
        )
        self.assertIn(
            {"name": NODE_CA_ENV, "value": AGW_CA_PATH},
            spec["containers"][-1]["env"],
        )
        self.assertEqual(
            spec["volumes"][-1],
            {
                "name": AGW_CA_VOLUME,
                "configMap": {
                    "name": AGW_CA_VOLUME,
                    "items": [{"key": "ca.crt", "path": "ca.crt"}],
                },
            },
        )

        prep_index = next(
            index
            for index, container in enumerate(spec["initContainers"])
            if container["name"] == "prepare-private-state"
        )
        link_init = spec["initContainers"][prep_index + 2]
        self.assertEqual(link_init["name"], LINK_INIT_NAME)
        self.assertIn("if (item.link === item.target) continue", link_init["args"][0])
        self.assertIn("path.posix.relative", link_init["args"][0])
        self.assertEqual(
            [mount["name"] for mount in link_init["volumeMounts"]],
            ["runtime-state", "openclaw-gateway-state"],
        )
        self.assertEqual(
            json.loads(link_init["env"][0]["value"]),
            [
                {"link": "agents", "target": "agents"},
                {"link": "sessions", "target": "sessions"},
            ],
        )

    def test_rejects_missing_or_unknown_oce_workload_role(self) -> None:
        pod = target_pod()
        pod["metadata"]["labels"] = {"app": "unrelated"}
        with self.assertRaisesRegex(
            AdmissionError,
            "managed by OpenClaw Enterprise",
        ):
            build_patch(pod)

        pod = target_pod()
        pod["metadata"]["labels"]["openclaw.dev/workload-role"] = "controller"
        with self.assertRaisesRegex(AdmissionError, "embedded gateway workload"):
            build_patch(pod)

    def test_rejects_state_free_oce_pods(self) -> None:
        pod = target_pod()
        pod["spec"]["volumes"] = [{"name": "runtime-state", "emptyDir": {}}]
        pod["spec"]["containers"][-1]["volumeMounts"] = []
        prepare_private_state_container(pod)["volumeMounts"] = [
            {"name": "runtime-state", "mountPath": "/runtime-state"}
        ]
        with self.assertRaisesRegex(AdmissionError, "gateway state claim"):
            build_patch(pod)

    def test_deduplicates_link_input_deterministically(self) -> None:
        pod = target_pod()
        duplicate = copy.deepcopy(pod["spec"]["containers"][-1]["volumeMounts"][-1])
        pod["spec"]["containers"][-1]["volumeMounts"].append(duplicate)

        rendered = apply_patch(pod, build_patch(pod))
        link_init = next(
            container
            for container in rendered["spec"]["initContainers"]
            if container["name"] == LINK_INIT_NAME
        )
        self.assertEqual(len(json.loads(link_init["env"][0]["value"])), 2)

    def test_rejects_target_sub_path_expr(self) -> None:
        pod = target_pod()
        mount = pod["spec"]["containers"][-1]["volumeMounts"][-1]
        mount.pop("subPath")
        mount["subPathExpr"] = "$(TENANT)/sessions"
        with self.assertRaisesRegex(AdmissionError, "subPathExpr"):
            build_patch(pod)

    def test_rejects_state_subpath_on_init_container(self) -> None:
        pod = target_pod()
        pod["spec"]["initContainers"].append(
            {
                "name": "later-state-user",
                "image": "example.invalid/init:latest",
                "volumeMounts": [
                    {
                        "name": "openclaw-gateway-state",
                        "mountPath": "/home/node/.openclaw/client",
                        "subPath": "client",
                    }
                ],
            }
        )
        with self.assertRaisesRegex(AdmissionError, "only its two OCE init containers"):
            build_patch(pod)

    def test_rejects_gateway_state_root_mounts_on_regular_containers(self) -> None:
        for container_index in (0, -1):
            with self.subTest(container_index=container_index):
                pod = target_pod()
                pod["spec"]["containers"][container_index].setdefault(
                    "volumeMounts", []
                ).append(
                    {
                        "name": "openclaw-gateway-state",
                        "mountPath": "/gateway-state",
                    }
                )
                with self.assertRaisesRegex(
                    AdmissionError,
                    "(not a designated state consumer|regular containers "
                    "cannot mount openclaw-gateway-state at its root)",
                ):
                    build_patch(pod)

    def test_rejects_unsafe_or_conflicting_target_shapes(self) -> None:
        cases = []

        unsafe = target_pod()
        unsafe["spec"]["containers"][-1]["volumeMounts"][-1]["subPath"] = "../sessions"
        cases.append(unsafe)

        collision = target_pod()
        collision["spec"]["containers"][-1]["volumeMounts"].append(
            {"name": "other", "mountPath": "/gateway-state"}
        )
        cases.append(collision)

        missing_prep = target_pod()
        prepare_private_state_container(missing_prep)["name"] = "not-prepare"
        cases.append(missing_prep)

        wrong_runtime = target_pod()
        wrong_runtime["spec"]["runtimeClassName"] = "runc"
        cases.append(wrong_runtime)

        for pod in cases:
            with self.subTest(pod=pod), self.assertRaises(AdmissionError):
                build_patch(pod)

    def test_refuses_dedicated_workspace(self) -> None:
        pod = target_pod()
        pod["spec"]["volumes"].append(
            {
                "name": "openclaw-workspace",
                "persistentVolumeClaim": {"claimName": "dedicated-workspace"},
            }
        )
        with self.assertRaisesRegex(AdmissionError, "dedicated"):
            build_patch(pod)

    def test_refuses_conflicting_ca_configuration(self) -> None:
        pod = target_pod()
        pod["spec"]["containers"][-1]["env"] = [
            {"name": NODE_CA_ENV, "value": "/different/ca.crt"}
        ]
        with self.assertRaisesRegex(AdmissionError, NODE_CA_ENV):
            build_patch(pod)


if __name__ == "__main__":
    unittest.main()
