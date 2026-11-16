from __future__ import annotations

import copy
import json
import os
import unittest
from unittest import mock

from adapter import (
    AGW_CA_MOUNT_PATH,
    AGW_CA_PATH,
    AGW_CA_VOLUME,
    LINK_INIT_NAME,
    NODE_CA_ENV,
    OPENCLAW_HOME_PATH,
    OWNERSHIP_SCRIPT,
    RUNTIME_TMP_VOLUME,
    SHM_MOUNT_PATH,
    TMP_MOUNT_PATH,
    TMPDIR_ENV,
    TMPDIR_PATH,
    AdmissionError,
    build_patch,
)

RUNTIME_IMAGE = f"example.invalid/oce@sha256:{'a' * 64}"
OWNERSHIP_INIT_IMAGE_ENV = "OCE_OWNERSHIP_INIT_IMAGE"
OWNERSHIP_INIT_IMAGE = f"example.invalid/ownership-helper@sha256:{'b' * 64}"
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


def test_ownership_script_uses_only_helper_image_paths() -> None:
    assert "/bin/chown" in OWNERSHIP_SCRIPT
    assert "/bin/chmod" in OWNERSHIP_SCRIPT
    assert "/usr/bin/chown" not in OWNERSHIP_SCRIPT
    assert "/usr/bin/chmod" not in OWNERSHIP_SCRIPT


def target_pod() -> dict:
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "namespace": "oce-tenant-test",
            "labels": {"openclaw.dev/workload-role": "gateway"},
        },
        "spec": {
            "initContainers": [
                *[
                    {"name": f"setup-{index}", "image": "example.invalid/oce:test"}
                    for index in range(9)
                ],
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
            ],
            "containers": [
                *[
                    {
                        "name": f"helper-{index}",
                        "image": RUNTIME_IMAGE,
                        "securityContext": runtime_security_context(),
                    }
                    for index in range(5)
                ],
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
                    "persistentVolumeClaim": {"claimName": "gateway-state"},
                },
            ],
        },
    }


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
                "projected": {"sources": [{"configMap": {"name": "runtime-settings"}}]},
            },
            {
                "name": "custom-api-token",
                "projected": {
                    "sources": [
                        {
                            "serviceAccountToken": {
                                "audience": "agentgateway",
                                "expirationSeconds": 600,
                                "path": "credentials/token",
                            }
                        }
                    ]
                },
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
            {
                "name": "custom-api-token",
                "mountPath": "/var/run/openclaw/tokens",
                "readOnly": True,
            },
        ]
    )
    return pod


def apply_patch(document: dict, patch: list[dict]) -> dict:
    result = copy.deepcopy(document)
    for operation in patch:
        parts = operation["path"].strip("/").split("/")
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
    {OWNERSHIP_INIT_IMAGE_ENV: OWNERSHIP_INIT_IMAGE},
)
class BuildPatchTests(unittest.TestCase):
    def test_moves_ownership_repair_to_dedicated_init_container(self) -> None:
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
        ownership_command = " ".join(
            [
                *ownership_init.get("command", []),
                *ownership_init.get("args", []),
            ]
        )
        self.assertIn("/bin/chown", ownership_command)
        self.assertIn("1000:1000", ownership_command)
        self.assertIn("/bin/chmod", ownership_command)
        self.assertEqual(
            {mount["name"] for mount in ownership_init["volumeMounts"]},
            {"runtime-state", "openclaw-gateway-state"},
        )
        self.assertEqual(ownership_init["image"], OWNERSHIP_INIT_IMAGE)
        self.assertNotEqual(ownership_init["image"], RUNTIME_IMAGE)
        self.assertEqual(ownership_init["command"], ["/bin/sh", "-eu", "-c"])
        self.assertEqual(ownership_init["args"][1], "--")
        self.assertIn(
            f"{OPENCLAW_HOME_PATH}/sessions",
            ownership_init["args"][2:],
        )
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
                environment = {} if image is None else {OWNERSHIP_INIT_IMAGE_ENV: image}
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
                pod["spec"]["initContainers"][-1].update(mutation)
                with self.assertRaisesRegex(
                    AdmissionError,
                    "prepare-private-state|designated runtime",
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
                del pod["spec"]["initContainers"][-1][omitted]
                with self.assertRaisesRegex(
                    AdmissionError,
                    "fixed prepare-private-state command",
                ):
                    build_patch(pod)

        pod = target_pod()
        pod["spec"]["initContainers"][-1]["args"] = [
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
                "mountPath": (
                    "/home/node/.openclaw/agents/main/agent/codex-home"
                ),
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
                "mountPath": (
                    "/home/node/.openclaw/agents/main/agent/codex-home"
                ),
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
            if container["name"] not in {
                *{
                    original["name"]
                    for original in pod["spec"]["initContainers"]
                },
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
        directories = json.loads(
            directories_line[len(prefix) : -len(suffix)]
        )
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
                directory.startswith("/runtime-state/home")
                for directory in directories
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
            copy.deepcopy(
                duplicate["spec"]["containers"][-1]["volumeMounts"][0]
            )
        )

        for name, pod in (
            ("malformed", malformed),
            ("missing", missing),
            ("duplicate", duplicate),
        ):
            with self.subTest(name=name), self.assertRaisesRegex(
                AdmissionError,
                "runtime-state|/home/node",
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
                pod["spec"]["initContainers"][-1]["volumeMounts"][0].update(mutation)
                with self.assertRaisesRegex(
                    AdmissionError,
                    "prepare-private-state volume-mount contract",
                ):
                    build_patch(pod)

        pod = target_pod()
        pod["spec"]["initContainers"][-1]["volumeMounts"].append(
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
        rendered = apply_patch(pod, build_patch(pod))
        self.assertEqual(rendered["spec"]["containers"][0]["image"], alternate_image)

        for field, value in (
            ("image", "example.invalid/helper:latest"),
            ("securityContext", {}),
        ):
            with self.subTest(field=field):
                pod = target_pod()
                pod["spec"]["containers"][0][field] = value
                with self.assertRaises(AdmissionError):
                    build_patch(pod)

    def test_rejects_state_mounts_on_non_designated_containers(self) -> None:
        mounts = (
            {
                "name": "runtime-state",
                "mountPath": "/home/node",
                "subPath": "home",
            },
            {
                "name": "openclaw-gateway-state",
                "mountPath": "/home/node/.openclaw/sessions",
                "subPath": "sessions",
            },
        )
        for mount in mounts:
            with self.subTest(volume=mount["name"]):
                pod = target_pod()
                pod["spec"]["containers"][0]["volumeMounts"] = [mount]
                with self.assertRaisesRegex(
                    AdmissionError,
                    "not a designated state consumer",
                ):
                    build_patch(pod)

    def test_rejects_state_mounts_on_non_designated_init_containers(self) -> None:
        for volume, mount_path in (
            ("runtime-state", "/runtime-state"),
            ("openclaw-gateway-state", "/gateway-state"),
        ):
            with self.subTest(volume=volume):
                pod = target_pod()
                pod["spec"]["initContainers"][0]["volumeMounts"] = [
                    {"name": volume, "mountPath": mount_path}
                ]
                with self.assertRaisesRegex(
                    AdmissionError,
                    "not a designated state consumer",
                ):
                    build_patch(pod)

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
                    "((overlaps|duplicate) /tmp|normalized absolute path)",
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
        preserved = copy.deepcopy(pod["spec"]["volumes"][-2:])

        volumes = apply_patch(pod, build_patch(pod))["spec"]["volumes"]

        self.assertNotIn(
            "kube-api-access-k82tq",
            [volume["name"] for volume in volumes],
        )
        for volume in preserved:
            self.assertIn(volume, volumes)

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
        custom_token_mount = {
            "name": "custom-api-token",
            "mountPath": "/var/run/openclaw/tokens",
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
        self.assertIn(custom_token_mount, rendered_gateway["volumeMounts"])

    def test_rewrites_structurally_and_preserves_unrelated_mounts(self) -> None:
        pod = target_pod()
        workspace = copy.deepcopy(pod["spec"]["containers"][-1]["volumeMounts"][1])

        rendered = apply_patch(pod, build_patch(pod))
        spec = rendered["spec"]

        self.assertEqual(spec["runtimeClassName"], "isolated-sandbox")
        self.assertIs(spec["automountServiceAccountToken"], False)
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
        with self.assertRaisesRegex(AdmissionError, "workload role"):
            build_patch(pod)

        pod = target_pod()
        pod["metadata"]["labels"]["openclaw.dev/workload-role"] = "controller"
        with self.assertRaisesRegex(AdmissionError, "workload role"):
            build_patch(pod)

    def test_rejects_state_free_oce_pods(self) -> None:
        pod = target_pod()
        pod["spec"]["volumes"] = [{"name": "runtime-state", "emptyDir": {}}]
        pod["spec"]["containers"][-1]["volumeMounts"] = []
        pod["spec"]["initContainers"][-1]["volumeMounts"] = [
            {"name": "runtime-state", "mountPath": "/runtime-state"}
        ]
        with self.assertRaisesRegex(AdmissionError, "requires openclaw-gateway-state"):
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
        with self.assertRaisesRegex(
            AdmissionError,
            "not a designated state consumer",
        ):
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
        missing_prep["spec"]["initContainers"][-1]["name"] = "not-prepare"
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
