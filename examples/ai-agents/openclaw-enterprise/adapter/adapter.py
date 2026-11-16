"""Pure OCE Pod mutation logic for the Nitro admission webhook."""

from __future__ import annotations

import copy
import json
import os
import posixpath
import re
from pathlib import PurePosixPath
from typing import Any

OCE_ROLES = frozenset({"agent", "gateway"})
PREP_INIT_NAME = "prepare-private-state"
STATE_VOLUME = "openclaw-gateway-state"
RUNTIME_VOLUME = "runtime-state"
RUNTIME_TMP_VOLUME = "runtime-temporary"
DEDICATED_WORKSPACE_VOLUME = "openclaw-workspace"
STATE_ROOT = "/gateway-state"
RUNTIME_ROOT = "/runtime-state"
OPENCLAW_HOME_PATH = "/home/node/.openclaw"
CLIENT_CREDENTIAL_PATH = f"{OPENCLAW_HOME_PATH}/client/credentials.sqlite"
LINK_INIT_NAME = "nitro-link-gateway-state"
OWNERSHIP_INIT_NAME = "nitro-prepare-runtime-ownership"
OWNERSHIP_INIT_IMAGE_ENV = "OCE_OWNERSHIP_INIT_IMAGE"
AGW_CA_VOLUME = "agentgateway-ca"
AGW_CA_CONFIG_MAP = "agentgateway-ca"
AGW_CA_MOUNT_PATH = "/etc/agentgateway-ca"
AGW_CA_PATH = f"{AGW_CA_MOUNT_PATH}/ca.crt"
NODE_CA_ENV = "NODE_EXTRA_CA_CERTS"
TMPDIR_ENV = "TMPDIR"
TMPDIR_PATH = "/dev/shm"  # nosec B108
TMP_MOUNT_PATH = "/tmp"  # nosec B108
SHM_MOUNT_PATH = "/dev/shm"  # nosec B108
SERVICE_ACCOUNT_MOUNT_PATH = "/var/run/secrets/kubernetes.io/serviceaccount"
RUNTIME_UID = 1000
RUNTIME_GID = 1000
HOME_MOUNT_PATH = "/home/node"
RUNTIME_TMP_ROOT = "/runtime-temporary"
TRUSTED_BOOTSTRAP_PATHS = (
    "/bin",
    "/usr/bin",
    "/lib",
    "/lib64",
    "/usr/lib",
    "/usr/lib64",
    "/etc/ld.so.cache",
    "/etc/ld.so.preload",
)
UNSAFE_BOOTSTRAP_ENV_NAMES = (
    "BASHOPTS",
    "BASH_ENV",
    "ENV",
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
    "PS4",
    "SHELLOPTS",
    "ZDOTDIR",
)
IMAGE_DIGEST_PATTERN = re.compile(r"^.+@sha256:[0-9a-f]{64}$")
PREP_ALLOWED_FIELDS = frozenset(
    {
        "args",
        "command",
        "image",
        "imagePullPolicy",
        "name",
        "resources",
        "securityContext",
        "terminationMessagePath",
        "terminationMessagePolicy",
        "volumeMounts",
    }
)

OWNERSHIP_SCRIPT = f"""
for path
do
  if [ -L "$path" ] || [ ! -d "$path" ]; then
    exit 1
  fi
  /bin/chmod 0700 -- "$path"
  /bin/chown {RUNTIME_UID}:{RUNTIME_GID} -- "$path"
done
credentials={CLIENT_CREDENTIAL_PATH}
if [ -L "$credentials" ]; then
  exit 1
fi
if [ -e "$credentials" ]; then
  /bin/chown {RUNTIME_UID}:{RUNTIME_GID} -- "$credentials"
  /bin/chmod 0600 -- "$credentials"
fi
""".strip()

LINK_SCRIPT = r"""
const fs = require("node:fs");
const path = require("node:path");
const links = JSON.parse(process.env.OCE_STATE_LINKS || "[]");
for (const item of links) {
  if (item.link === item.target) continue;
  const link = path.posix.join("/gateway-state", item.link);
  const target = path.posix.join("/gateway-state", item.target);
  fs.mkdirSync(path.posix.dirname(link), {recursive: true});
  let current;
  try {
    current = fs.lstatSync(link);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  if (current === undefined) {
    fs.symlinkSync(path.posix.relative(path.posix.dirname(link), target), link);
  } else if (
    !current.isSymbolicLink() ||
    path.posix.resolve(path.posix.dirname(link), fs.readlinkSync(link)) !== target
  ) {
    throw new Error(`refusing to replace ${link}`);
  }
}
""".strip()


class AdmissionError(ValueError):
    """A target OCE Pod has a shape the adapter cannot safely mutate."""


def _is_nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value)


def _is_digest_pinned_image(value: Any) -> bool:
    return (
        _is_nonempty_string(value)
        and value.strip() == value
        and not any(character.isspace() for character in value)
        and IMAGE_DIGEST_PATTERN.fullmatch(value) is not None
    )


def _safe_relative_path(value: Any, field: str) -> str:
    if not _is_nonempty_string(value):
        raise AdmissionError(f"{field} must be a non-empty relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {".", ".."} for part in path.parts):
        raise AdmissionError(f"{field} must not be absolute or contain dot segments")
    if str(path) != value or "//" in value:
        raise AdmissionError(f"{field} must be a normalized relative path")
    return value


def _container_groups(spec: dict[str, Any]) -> tuple[list[Any], list[Any]]:
    init_containers = spec.get("initContainers", [])
    containers = spec.get("containers")
    if not isinstance(init_containers, list):
        raise AdmissionError("spec.initContainers must be a list")
    if not isinstance(containers, list) or not containers:
        raise AdmissionError("spec.containers must be a non-empty list")
    return init_containers, containers


def _mounts(container: Any, location: str) -> list[Any]:
    if not isinstance(container, dict):
        raise AdmissionError(f"{location} must be an object")
    mounts = container.get("volumeMounts", [])
    if not isinstance(mounts, list):
        raise AdmissionError(f"{location}.volumeMounts must be a list")
    return mounts


def _validate_link_paths(links: dict[str, str]) -> None:
    paths = sorted(PurePosixPath(link).parts for link in links)
    for index, path in enumerate(paths):
        for other in paths[index + 1 :]:
            if len(path) < len(other) and other[: len(path)] == path:
                raise AdmissionError(
                    "gateway-state mount paths must not contain one another"
                )


def _runtime_environment(container: dict[str, Any], location: str) -> list[Any]:
    env_from = container.get("envFrom", [])
    if not isinstance(env_from, list):
        raise AdmissionError(f"{location}.envFrom must be a list")
    if env_from:
        raise AdmissionError(
            f"{location}.envFrom is not supported by the adapter contract"
        )
    environment = container.get("env", [])
    if not isinstance(environment, list):
        raise AdmissionError(f"{location}.env must be a list")
    for entry in environment:
        if not isinstance(entry, dict):
            raise AdmissionError(f"{location}.env entries must be objects")
        name = entry.get("name")
        if not _is_nonempty_string(name):
            raise AdmissionError(f"{location}.env entries must have a name")
        if name.startswith("LD_") or name in UNSAFE_BOOTSTRAP_ENV_NAMES:
            raise AdmissionError(
                f"{location} configures unsafe bootstrap environment {name}"
            )
    required = {
        NODE_CA_ENV: AGW_CA_PATH,
        TMPDIR_ENV: TMPDIR_PATH,
    }
    for name, value in required.items():
        matches = [
            entry
            for entry in environment
            if isinstance(entry, dict) and entry.get("name") == name
        ]
        if len(matches) > 1:
            raise AdmissionError(f"{location} has duplicate {name} entries")
        if matches and matches[0] != {"name": name, "value": value}:
            raise AdmissionError(f"{location} already configures {name}")
    return environment


def _runtime_contract(
    container: dict[str, Any], location: str
) -> tuple[str, dict[str, Any]]:
    image = container.get("image")
    if not _is_digest_pinned_image(image):
        raise AdmissionError(f"{location}.image must use an exact sha256 digest")

    security = container.get("securityContext")
    if not isinstance(security, dict):
        raise AdmissionError(f"{location} must declare securityContext")
    capabilities = security.get("capabilities")
    if (
        security.get("allowPrivilegeEscalation") is not False
        or security.get("readOnlyRootFilesystem") is not True
        or security.get("privileged") not in (None, False)
        or security.get("procMount") not in (None, "Default")
        or (
            security.get("seccompProfile") is not None
            and security.get("seccompProfile") != {"type": "RuntimeDefault"}
        )
        or not isinstance(capabilities, dict)
        or capabilities.get("drop") != ["ALL"]
        or capabilities.get("add") not in (None, [])
        or security.get("runAsUser") not in (None, RUNTIME_UID)
        or security.get("runAsGroup") not in (None, RUNTIME_GID)
        or security.get("runAsNonRoot") not in (None, True)
    ):
        raise AdmissionError(
            f"{location} must start as the non-root runtime user with a "
            "read-only root filesystem and all capabilities dropped"
        )

    for field in ("lifecycle", "livenessProbe", "readinessProbe", "startupProbe"):
        value = container.get(field)
        if isinstance(value, dict):
            handlers = [value]
            if field == "lifecycle":
                handlers = [
                    handler
                    for handler in (value.get("postStart"), value.get("preStop"))
                    if isinstance(handler, dict)
                ]
            if any("exec" in handler for handler in handlers):
                raise AdmissionError(
                    f"{location}.{field} exec handlers are not supported"
                )

    runtime_security = {
        "allowPrivilegeEscalation": False,
        "capabilities": {"drop": ["ALL"]},
        "privileged": False,
        "readOnlyRootFilesystem": True,
        "runAsGroup": RUNTIME_GID,
        "runAsNonRoot": True,
        "runAsUser": RUNTIME_UID,
        "seccompProfile": {"type": "RuntimeDefault"},
    }
    return image, runtime_security


def _ownership_init_image() -> str:
    image = os.environ.get(OWNERSHIP_INIT_IMAGE_ENV)
    if not _is_digest_pinned_image(image):
        raise AdmissionError(
            f"{OWNERSHIP_INIT_IMAGE_ENV} must use an exact sha256 digest"
        )
    return image


def _validate_prepare_private_state(
    prep: dict[str, Any],
    location: str,
    runtime_image: str,
    default_service_account_volumes: set[str],
    containers: list[dict[str, Any]],
    role: str,
) -> None:
    unexpected_fields = sorted(set(prep) - PREP_ALLOWED_FIELDS)
    if unexpected_fields:
        raise AdmissionError(
            f"{location} does not match the fixed prepare-private-state contract: "
            f"unexpected fields {unexpected_fields}"
        )

    image = prep.get("image")
    if not _is_digest_pinned_image(image):
        raise AdmissionError(
            f"{location}.image must use the designated runtime's exact sha256 digest"
        )
    if image != runtime_image:
        raise AdmissionError(
            f"{location}.image must match the designated runtime image"
        )

    expected_security = {
        "allowPrivilegeEscalation": False,
        "readOnlyRootFilesystem": True,
        "capabilities": {"drop": ["ALL"]},
    }
    if prep.get("securityContext") != expected_security:
        raise AdmissionError(
            f"{location}.securityContext does not match the fixed "
            "prepare-private-state contract"
        )

    command = prep.get("command")
    args = prep.get("args")
    if command is None or args is None:
        raise AdmissionError(
            f"{location} must define the fixed prepare-private-state command"
        )
    allowed_commands = (
        ["node", "-e"],
        ["/usr/bin/tini", "-s", "--", "node", "-e"],
    )
    if command not in allowed_commands or not (
        isinstance(args, list) and len(args) == 1 and isinstance(args[0], str)
    ):
        raise AdmissionError(
            f"{location} does not match the fixed prepare-private-state "
            "command contract"
        )
    lines = args[0].splitlines()
    prefix = "for (const path of "
    suffix = ") {"
    if (
        len(lines) != 6
        or lines[0] != 'const { chmodSync, mkdirSync } = require("node:fs");'
        or not lines[1].startswith(prefix)
        or not lines[1].endswith(suffix)
    ):
        raise AdmissionError(
            f"{location} does not match the fixed prepare-private-state "
            "command contract"
        )
    try:
        directories = json.loads(lines[1][len(prefix) : -len(suffix)])
    except json.JSONDecodeError as error:
        raise AdmissionError(
            f"{location} does not match the fixed prepare-private-state "
            "command contract"
        ) from error

    expected_directories = {
        f"{RUNTIME_ROOT}/home",
        f"{RUNTIME_TMP_ROOT}/tmp",
    }
    if role == "gateway":
        expected_directories.add(f"{RUNTIME_ROOT}/home/gateway-codex-home")
    for index, container in enumerate(containers):
        for mount in _mounts(container, f"spec.containers[{index}]"):
            if not isinstance(mount, dict):
                continue
            mount_path = mount.get("mountPath")
            if isinstance(mount_path, str) and mount_path.startswith(
                f"{HOME_MOUNT_PATH}/"
            ):
                if (
                    posixpath.normpath(mount_path) != mount_path
                    or posixpath.commonpath((HOME_MOUNT_PATH, mount_path))
                    != HOME_MOUNT_PATH
                ):
                    raise AdmissionError(
                        f"spec.containers[{index}].volumeMounts contains an "
                        "unsafe home mount path"
                    )
                parent = posixpath.dirname(mount_path)
                if parent != HOME_MOUNT_PATH:
                    expected_directories.add(
                        parent.replace(HOME_MOUNT_PATH, f"{RUNTIME_ROOT}/home", 1)
                    )
            if mount.get("name") == STATE_VOLUME:
                sub_path = mount.get("subPath")
                if (
                    isinstance(sub_path, str)
                    and sub_path
                    and not sub_path.startswith("/")
                    and posixpath.normpath(sub_path) == sub_path
                    and not sub_path.startswith("../")
                ):
                    expected_directories.add(f"{STATE_ROOT}/{sub_path}")

    if (
        not isinstance(directories, list)
        or not all(isinstance(directory, str) for directory in directories)
        or len(directories) != len(set(directories))
        or set(directories) != expected_directories
        or lines[2:]
        != [
            "  mkdirSync(path, { recursive: true });",
            "  chmodSync(path, 0o700);",
            "}",
            'mkdirSync("/runtime-temporary/tmp", { recursive: true, mode: 0o700 });',
        ]
    ):
        raise AdmissionError(
            f"{location} preparation directories do not match the mount contract"
        )

    expected_mounts = {
        RUNTIME_VOLUME: (
            {"name": RUNTIME_VOLUME, "mountPath": RUNTIME_ROOT},
            {
                "name": RUNTIME_VOLUME,
                "mountPath": RUNTIME_ROOT,
                "mountPropagation": "HostToContainer",
            },
        ),
        STATE_VOLUME: {
            "name": STATE_VOLUME,
            "mountPath": STATE_ROOT,
        },
        RUNTIME_TMP_VOLUME: {
            "name": RUNTIME_TMP_VOLUME,
            "mountPath": RUNTIME_TMP_ROOT,
        },
    }
    seen: set[str] = set()
    for mount in _mounts(prep, location):
        if not isinstance(mount, dict):
            raise AdmissionError(f"{location}.volumeMounts entries must be objects")
        name = mount.get("name")
        if name in default_service_account_volumes:
            if mount != {
                "name": name,
                "mountPath": SERVICE_ACCOUNT_MOUNT_PATH,
                "readOnly": True,
            }:
                raise AdmissionError(
                    f"{location} has an unsupported service-account mount"
                )
            continue
        expected = expected_mounts.get(name)
        if expected is None or (
            mount not in expected if isinstance(expected, tuple) else mount != expected
        ):
            raise AdmissionError(
                f"{location} does not match the fixed prepare-private-state "
                "volume-mount contract"
            )
        if name in seen:
            raise AdmissionError(f"{location} has duplicate {name} mounts")
        seen.add(name)

    if not {RUNTIME_VOLUME, STATE_VOLUME}.issubset(seen):
        raise AdmissionError(
            "prepare-private-state must mount runtime-state and gateway state "
            "at their roots"
        )


def _ownership_init(
    image: str,
    private_paths: list[str],
) -> dict[str, Any]:
    return {
        "name": OWNERSHIP_INIT_NAME,
        "image": image,
        "command": ["/bin/sh", "-eu", "-c"],
        "args": [OWNERSHIP_SCRIPT, "--", *private_paths],
        "securityContext": {
            "allowPrivilegeEscalation": False,
            "readOnlyRootFilesystem": True,
            "runAsUser": 0,
            "runAsGroup": 0,
            "runAsNonRoot": False,
            "capabilities": {
                "drop": ["ALL"],
                "add": ["CHOWN", "DAC_OVERRIDE", "FOWNER"],
            },
            "seccompProfile": {"type": "RuntimeDefault"},
        },
        "volumeMounts": [
            {
                "name": RUNTIME_VOLUME,
                "mountPath": HOME_MOUNT_PATH,
                "subPath": "home",
            },
            {
                "name": STATE_VOLUME,
                "mountPath": OPENCLAW_HOME_PATH,
            },
        ],
    }


def _mount_paths_overlap(left: Any, right: str) -> bool:
    if not _is_nonempty_string(left) or not left.startswith("/"):
        return False
    normalized = posixpath.normpath(f"/{left.lstrip('/')}")
    return (
        normalized == "/"
        or normalized == right
        or normalized.startswith(f"{right}/")
        or right.startswith(f"{normalized}/")
    )


def _default_service_account_volumes(volumes: list[Any], mounts: list[Any]) -> set[str]:
    """Find only Kubernetes' standard auto-injected service-account projections."""
    removable: set[str] = set()
    for volume in volumes:
        if not isinstance(volume, dict):
            continue
        name = volume.get("name")
        projected = volume.get("projected")
        if not (
            _is_nonempty_string(name)
            and name.startswith("kube-api-access-")
            and isinstance(projected, dict)
            and isinstance(projected.get("sources"), list)
        ):
            continue

        sources = projected["sources"]
        has_default_token = any(
            isinstance(source, dict)
            and isinstance(source.get("serviceAccountToken"), dict)
            and source["serviceAccountToken"].get("path") == "token"
            for source in sources
        )
        has_root_ca = any(
            isinstance(source, dict)
            and isinstance(source.get("configMap"), dict)
            and source["configMap"].get("name") == "kube-root-ca.crt"
            for source in sources
        )
        has_namespace = any(
            isinstance(source, dict)
            and isinstance(source.get("downwardAPI"), dict)
            and any(
                isinstance(item, dict)
                and item.get("path") == "namespace"
                and isinstance(item.get("fieldRef"), dict)
                and item["fieldRef"].get("fieldPath") == "metadata.namespace"
                for item in source["downwardAPI"].get("items", [])
            )
            for source in sources
        )
        references = [
            mount
            for mount in mounts
            if isinstance(mount, dict) and mount.get("name") == name
        ]
        if (
            has_default_token
            and has_root_ca
            and has_namespace
            and references
            and all(
                mount.get("mountPath") == SERVICE_ACCOUNT_MOUNT_PATH
                for mount in references
            )
        ):
            removable.add(name)
    return removable


def build_patch(pod: dict[str, Any]) -> list[dict[str, Any]]:
    """Return an RFC 6902 patch, or raise AdmissionError for unsafe target Pods."""
    if not isinstance(pod, dict):
        raise AdmissionError("Pod must be an object")

    metadata = pod.get("metadata")
    labels = metadata.get("labels", {}) if isinstance(metadata, dict) else {}
    role = (
        labels.get("openclaw.dev/workload-role") if isinstance(labels, dict) else None
    )
    if role not in OCE_ROLES:
        raise AdmissionError("OCE workload role must be agent or gateway")

    spec = pod.get("spec")
    if not isinstance(spec, dict):
        raise AdmissionError("target OCE Pod must have a spec")
    volumes = spec.get("volumes", [])
    if not isinstance(volumes, list):
        raise AdmissionError("spec.volumes must be a list")
    init_containers, containers = _container_groups(spec)
    for index, container in enumerate(init_containers):
        if isinstance(container, dict) and container.get("restartPolicy") == "Always":
            raise AdmissionError(
                f"spec.initContainers[{index}] native sidecars are not supported"
            )

    reserved_volumes = [
        volume
        for volume in volumes
        if isinstance(volume, dict) and volume.get("name") == AGW_CA_VOLUME
    ]
    if reserved_volumes:
        raise AdmissionError(f"volume name {AGW_CA_VOLUME} is reserved")

    all_mounts = [
        mount
        for group_name, group in (
            ("spec.initContainers", init_containers),
            ("spec.containers", containers),
        )
        for index, container in enumerate(group)
        for mount in _mounts(container, f"{group_name}[{index}]")
    ]
    if any(
        isinstance(mount, dict) and mount.get("name") == AGW_CA_VOLUME
        for mount in all_mounts
    ):
        raise AdmissionError(f"volume mount name {AGW_CA_VOLUME} is reserved")
    default_service_account_volumes = _default_service_account_volumes(
        volumes, all_mounts
    )
    if any(
        isinstance(volume, dict) and volume.get("name") == DEDICATED_WORKSPACE_VOLUME
        for volume in volumes
    ) or any(
        isinstance(mount, dict) and mount.get("name") == DEDICATED_WORKSPACE_VOLUME
        for mount in all_mounts
    ):
        raise AdmissionError(
            "dedicated openclaw-workspace Pods are not supported by this adapter"
        )

    state_volumes = [
        volume
        for volume in volumes
        if isinstance(volume, dict) and volume.get("name") == STATE_VOLUME
    ]
    if not state_volumes:
        raise AdmissionError(f"target OCE Pod requires {STATE_VOLUME}")
    if len(state_volumes) != 1:
        raise AdmissionError(f"expected exactly one {STATE_VOLUME} volume")
    claim = state_volumes[0].get("persistentVolumeClaim")
    if not isinstance(claim, dict) or not _is_nonempty_string(claim.get("claimName")):
        raise AdmissionError(f"{STATE_VOLUME} must be a PersistentVolumeClaim")

    runtime_volumes = [
        volume
        for volume in volumes
        if isinstance(volume, dict) and volume.get("name") == RUNTIME_VOLUME
    ]
    if len(runtime_volumes) != 1 or "emptyDir" not in runtime_volumes[0]:
        raise AdmissionError(f"{RUNTIME_VOLUME} must be exactly one emptyDir volume")
    runtime_tmp_volumes = [
        volume
        for volume in volumes
        if isinstance(volume, dict) and volume.get("name") == RUNTIME_TMP_VOLUME
    ]
    if len(runtime_tmp_volumes) != 1 or "emptyDir" not in runtime_tmp_volumes[0]:
        raise AdmissionError(
            f"{RUNTIME_TMP_VOLUME} must be exactly one emptyDir volume"
        )

    prep_indexes = [
        index
        for index, container in enumerate(init_containers)
        if isinstance(container, dict) and container.get("name") == PREP_INIT_NAME
    ]
    if len(prep_indexes) != 1:
        raise AdmissionError(
            "expected exactly one prepare-private-state init container"
        )
    prep_index = prep_indexes[0]
    prep = init_containers[prep_index]
    reserved_container_names = {LINK_INIT_NAME, OWNERSHIP_INIT_NAME}
    for container in [*init_containers, *containers]:
        if (
            isinstance(container, dict)
            and container.get("name") in reserved_container_names
        ):
            raise AdmissionError(f"container name {container['name']} is reserved")

    designated_indexes = [
        index
        for index, container in enumerate(containers)
        if isinstance(container, dict) and container.get("name") == role
    ]
    if len(designated_indexes) != 1:
        raise AdmissionError(
            f"expected exactly one designated {role} runtime container"
        )
    designated_index = designated_indexes[0]

    links: dict[str, str] = {}
    mount_patches: list[dict[str, Any]] = []
    environment_patches: list[dict[str, Any]] = []
    runtime_patches: list[dict[str, Any]] = []
    ownership_image = _ownership_init_image()
    designated_runtime_image: str | None = None
    for index, container in enumerate(containers):
        location = f"spec.containers[{index}]"
        runtime_image, runtime_security = _runtime_contract(container, location)
        if runtime_image == ownership_image:
            raise AdmissionError(
                f"{OWNERSHIP_INIT_IMAGE_ENV} must not match a workload runtime image"
            )
        if index == designated_index:
            designated_runtime_image = runtime_image
        runtime_patches.append(
            {
                "op": "replace",
                "path": f"/spec/containers/{index}/securityContext",
                "value": runtime_security,
            }
        )

    if designated_runtime_image is None:
        raise AdmissionError("target OCE Pod has no regular runtime container")
    groups = (
        ("initContainers", init_containers),
        ("containers", containers),
    )
    for group_name, group in groups:
        for index, container in enumerate(group):
            mounts = _mounts(container, f"spec.{group_name}[{index}]")
            rewritten: list[dict[str, Any]] = []
            state_root_count = 0
            state_affected = False
            mounts_changed = False

            for mount in mounts:
                if not isinstance(mount, dict):
                    raise AdmissionError(
                        f"spec.{group_name}[{index}].volumeMounts entries must be objects"
                    )
                if (
                    mount.get("name") in default_service_account_volumes
                    and mount.get("mountPath") == SERVICE_ACCOUNT_MOUNT_PATH
                ):
                    mounts_changed = True
                    continue
                if mount.get("name") in {RUNTIME_VOLUME, STATE_VOLUME} and not (
                    (group_name == "containers" and index == designated_index)
                    or (group_name == "initContainers" and index == prep_index)
                ):
                    raise AdmissionError(
                        f"spec.{group_name}[{index}] is not a designated state "
                        f"consumer and cannot mount {mount.get('name')}"
                    )
                if mount.get("name") != STATE_VOLUME:
                    if mount.get("mountPath") == STATE_ROOT:
                        raise AdmissionError(
                            f"{STATE_ROOT} is already used by another volume"
                        )
                    rewritten.append(copy.deepcopy(mount))
                    continue

                if "subPathExpr" in mount:
                    raise AdmissionError(
                        f"{STATE_VOLUME} subPathExpr mounts are not supported"
                    )
                if "subPath" not in mount:
                    if mount.get("mountPath") != STATE_ROOT:
                        raise AdmissionError(
                            f"{STATE_VOLUME} root mounts must use {STATE_ROOT}"
                        )
                    if group_name == "containers":
                        raise AdmissionError(
                            "regular containers cannot mount "
                            f"{STATE_VOLUME} at its root"
                        )
                    state_root_count += 1
                    rewritten.append(copy.deepcopy(mount))
                    continue

                if group_name == "initContainers":
                    raise AdmissionError(
                        f"{STATE_VOLUME} subPath init mounts are not supported"
                    )
                if mount.get("readOnly") is True or "recursiveReadOnly" in mount:
                    raise AdmissionError(
                        f"{STATE_VOLUME} read-only subPath mounts cannot be "
                        "safely rewritten to a writable PVC root"
                    )
                mount_path = mount.get("mountPath")
                state_home_root = f"{OPENCLAW_HOME_PATH}/"
                if not _is_nonempty_string(mount_path) or not mount_path.startswith(
                    state_home_root
                ):
                    raise AdmissionError(
                        f"{STATE_VOLUME} subPath mounts must be below {state_home_root}"
                    )
                link = _safe_relative_path(
                    mount_path.removeprefix(state_home_root),
                    "gateway-state mountPath",
                )
                target = _safe_relative_path(
                    mount.get("subPath"), "gateway-state subPath"
                )
                previous = links.setdefault(link, target)
                if previous != target:
                    raise AdmissionError(
                        f"conflicting gateway-state targets for {mount_path}"
                    )
                state_affected = True

            if state_root_count > 1:
                raise AdmissionError(
                    f"spec.{group_name}[{index}] has duplicate {STATE_ROOT} mounts"
                )
            if state_affected:
                if state_root_count == 0:
                    rewritten.append(
                        {
                            "name": STATE_VOLUME,
                            "mountPath": OPENCLAW_HOME_PATH,
                        }
                    )
                if group_name == "containers":
                    if any(
                        mount.get("name") == AGW_CA_VOLUME
                        or mount.get("mountPath") == AGW_CA_MOUNT_PATH
                        for mount in rewritten
                    ):
                        raise AdmissionError(
                            f"spec.{group_name}[{index}] already uses the AgentGateway CA mount"
                        )
                    existing_tmp_mounts = [
                        mount
                        for mount in rewritten
                        if _is_nonempty_string(mount.get("mountPath"))
                        and posixpath.normpath(mount["mountPath"]) == TMP_MOUNT_PATH
                    ]
                    conflicting_tmp_mounts = [
                        mount
                        for mount in rewritten
                        if _mount_paths_overlap(mount.get("mountPath"), TMP_MOUNT_PATH)
                        and mount not in existing_tmp_mounts
                    ]
                    if conflicting_tmp_mounts:
                        raise AdmissionError(
                            f"spec.{group_name}[{index}] has a mount that overlaps {TMP_MOUNT_PATH}"
                        )
                    if len(existing_tmp_mounts) > 1:
                        raise AdmissionError(
                            f"spec.{group_name}[{index}] has duplicate {TMP_MOUNT_PATH} mounts"
                        )
                    if existing_tmp_mounts:
                        existing_tmp_mount = existing_tmp_mounts[0]
                        if (
                            existing_tmp_mount.get("name") != RUNTIME_TMP_VOLUME
                            or existing_tmp_mount.get("subPath") != "tmp"
                            or "subPathExpr" in existing_tmp_mount
                            or existing_tmp_mount.get("readOnly") is True
                        ):
                            raise AdmissionError(
                                f"spec.{group_name}[{index}] must mount "
                                f"{RUNTIME_TMP_VOLUME} subPath tmp at {TMP_MOUNT_PATH}"
                            )
                        rewritten.remove(existing_tmp_mount)
                    if any(
                        _mount_paths_overlap(mount.get("mountPath"), SHM_MOUNT_PATH)
                        for mount in rewritten
                    ):
                        raise AdmissionError(
                            f"spec.{group_name}[{index}] has a mount that overlaps {SHM_MOUNT_PATH}"
                        )
                    for trusted_path in TRUSTED_BOOTSTRAP_PATHS:
                        if any(
                            _mount_paths_overlap(mount.get("mountPath"), trusted_path)
                            for mount in rewritten
                        ):
                            raise AdmissionError(
                                f"spec.{group_name}[{index}] has a mount that "
                                f"overlaps trusted bootstrap path {trusted_path}"
                            )
                    rewritten.append(
                        {
                            "name": AGW_CA_VOLUME,
                            "mountPath": AGW_CA_MOUNT_PATH,
                            "readOnly": True,
                        }
                    )
                    environment = _runtime_environment(
                        container, f"spec.{group_name}[{index}]"
                    )
                    required_environment = [
                        {"name": NODE_CA_ENV, "value": AGW_CA_PATH},
                        {"name": TMPDIR_ENV, "value": TMPDIR_PATH},
                        *[
                            {"name": name, "value": ""}
                            for name in UNSAFE_BOOTSTRAP_ENV_NAMES
                        ],
                    ]
                    missing_environment = [
                        entry
                        for entry in required_environment
                        if not any(
                            isinstance(current, dict)
                            and current.get("name") == entry["name"]
                            for current in environment
                        )
                    ]
                    if missing_environment:
                        environment_patches.append(
                            {
                                "op": "add" if "env" not in container else "replace",
                                "path": f"/spec/{group_name}/{index}/env",
                                "value": [
                                    *copy.deepcopy(environment),
                                    *missing_environment,
                                ],
                            }
                        )
            if state_affected or mounts_changed:
                mount_patches.append(
                    {
                        "op": "replace",
                        "path": f"/spec/{group_name}/{index}/volumeMounts",
                        "value": rewritten,
                    }
                )

    _validate_prepare_private_state(
        prep,
        f"spec.initContainers[{prep_index}]",
        designated_runtime_image,
        default_service_account_volumes,
        containers,
        role,
    )

    if not links:
        raise AdmissionError(f"{STATE_VOLUME} has no supported subPath mounts to adapt")
    _validate_link_paths(links)

    link_data = [
        {"link": link, "target": target} for link, target in sorted(links.items())
    ]
    link_init: dict[str, Any] = {
        "name": LINK_INIT_NAME,
        "image": prep["image"],
        "command": ["node", "-e"],
        "args": [LINK_SCRIPT],
        "env": [
            {
                "name": "OCE_STATE_LINKS",
                "value": json.dumps(link_data, separators=(",", ":"), sort_keys=True),
            },
        ],
        "securityContext": {
            "allowPrivilegeEscalation": False,
            "readOnlyRootFilesystem": True,
            "runAsNonRoot": True,
            "capabilities": {"drop": ["ALL"]},
            "seccompProfile": {"type": "RuntimeDefault"},
        },
        "volumeMounts": [
            {"name": RUNTIME_VOLUME, "mountPath": RUNTIME_ROOT},
            {"name": STATE_VOLUME, "mountPath": STATE_ROOT},
        ],
    }
    if "imagePullPolicy" in prep:
        link_init["imagePullPolicy"] = prep["imagePullPolicy"]
    ownership_init = _ownership_init(
        ownership_image,
        [
            HOME_MOUNT_PATH,
            OPENCLAW_HOME_PATH,
            *[
                f"{OPENCLAW_HOME_PATH}/{target}"
                for target in sorted(set(links.values()))
            ],
        ],
    )

    patch: list[dict[str, Any]] = []
    runtime_class = spec.get("runtimeClassName")
    if runtime_class is None:
        patch.append(
            {
                "op": "add",
                "path": "/spec/runtimeClassName",
                "value": "isolated-sandbox",
            }
        )
    elif runtime_class != "isolated-sandbox":
        raise AdmissionError(f"refusing to replace runtimeClassName {runtime_class!r}")

    if "automountServiceAccountToken" not in spec:
        patch.append(
            {
                "op": "add",
                "path": "/spec/automountServiceAccountToken",
                "value": False,
            }
        )
    elif spec["automountServiceAccountToken"] is not False:
        patch.append(
            {
                "op": "replace",
                "path": "/spec/automountServiceAccountToken",
                "value": False,
            }
        )

    patch.extend(mount_patches)
    patch.extend(environment_patches)
    patch.extend(runtime_patches)
    patch.append(
        {
            "op": "replace",
            "path": "/spec/volumes",
            "value": [
                *[
                    copy.deepcopy(volume)
                    for volume in volumes
                    if not (
                        isinstance(volume, dict)
                        and volume.get("name") in default_service_account_volumes
                    )
                ],
                {
                    "name": AGW_CA_VOLUME,
                    "configMap": {
                        "name": AGW_CA_CONFIG_MAP,
                        "items": [{"key": "ca.crt", "path": "ca.crt"}],
                    },
                },
            ],
        }
    )
    patch.append(
        {
            "op": "add",
            "path": f"/spec/initContainers/{prep_index + 1}",
            "value": ownership_init,
        }
    )
    patch.append(
        {
            "op": "add",
            "path": f"/spec/initContainers/{prep_index + 2}",
            "value": link_init,
        }
    )
    return patch
