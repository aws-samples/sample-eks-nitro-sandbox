"""Pure OCE Pod mutation logic for the Nitro admission webhook."""

from __future__ import annotations

import copy
import json
import os
import posixpath
import re
from pathlib import PurePosixPath
from typing import Any

OCE_ROLE = "gateway"
NETWORK_PROFILE_LABEL = "openclaw.dev/network-profile"
OCE_BROAD_EGRESS_PROFILE = "broad-egress-v1"
PREP_INIT_NAME = "prepare-private-state"
OWNER_INIT_NAME = "prepare-embedded-gateway-owner"
STATE_VOLUME = "openclaw-gateway-state"
RUNTIME_VOLUME = "runtime-state"
RUNTIME_TMP_VOLUME = "runtime-temporary"
DEDICATED_WORKSPACE_VOLUME = "openclaw-workspace"
STATE_ROOT = "/gateway-state"
RUNTIME_ROOT = "/runtime-state"
OPENCLAW_HOME_PATH = "/home/node/.openclaw"
CLIENT_CREDENTIAL_PATH = f"{OPENCLAW_HOME_PATH}/client/credentials.sqlite"
RUNTIME_PIN_DIRECTORY = f"{OPENCLAW_HOME_PATH}/control"
RUNTIME_PIN_PATH = f"{RUNTIME_PIN_DIRECTORY}/services.sqlite"
LINK_INIT_NAME = "nitro-link-gateway-state"
OWNERSHIP_INIT_NAME = "nitro-prepare-runtime-ownership"
OWNERSHIP_INIT_IMAGE_ENV = "OCE_OWNERSHIP_INIT_IMAGE"
RUNTIME_IMAGES_ENV = "OCE_RUNTIME_IMAGES"
AGW_CA_VOLUME = "agentgateway-ca"
AGW_CA_CONFIG_MAP = "agentgateway-ca"
AGW_CA_MOUNT_PATH = "/etc/agentgateway-ca"
AGW_CA_PATH = f"{AGW_CA_MOUNT_PATH}/ca.crt"
OCE_CONFIGURATION_VOLUME = "openclaw-configuration"
OCE_CONFIGURATION_MOUNT_PATH = "/etc/openclaw"
OCE_SERVICE_PRINCIPAL_VOLUME = "openclaw-service-principal"
OCE_SERVICE_PRINCIPAL_MOUNT_PATH = "/var/run/secrets/openclaw/service-principal"
NODE_CA_ENV = "NODE_EXTRA_CA_CERTS"
TMPDIR_ENV = "TMPDIR"
TMPDIR_PATH = "/dev/shm"  # nosec B108
TMP_MOUNT_PATH = "/tmp"  # nosec B108
SHM_MOUNT_PATH = "/dev/shm"  # nosec B108
SERVICE_ACCOUNT_MOUNT_PATH = "/var/run/secrets/kubernetes.io/serviceaccount"
RUNTIME_UID = 1000
RUNTIME_GID = 1000
HOME_MOUNT_PATH = "/home/node"
HOME_ENV = "HOME"
AWS_CREDENTIAL_DIRECTORY = f"{HOME_MOUNT_PATH}/.aws"
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
    "NODE_OPTIONS",
    "PS4",
    "SHELLOPTS",
    "ZDOTDIR",
)
AWS_CREDENTIAL_ENV_NAMES = frozenset(
    {
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
    }
)
HARNESS_CREDENTIAL_ENV_NAMES = frozenset(
    {
        "ANTHROPIC_API_KEY",
        "OCE_MODEL_API_KEY",
        "OPENAI_API_KEY",
    }
)
IMAGE_DIGEST_PATTERN = re.compile(r"^.+@sha256:[0-9a-f]{64}$")
GATEWAY_ID_PATTERN = re.compile(r"^[0-9a-f]{12}$")
OCE_RESOURCE_ID_PATTERN = re.compile(
    r"^(?:agt|ns|rev)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
    r"[0-9a-f]{4}-[0-9a-f]{12}$"
)
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
OWNER_ALLOWED_FIELDS = PREP_ALLOWED_FIELDS

OWNER_SCRIPT = r"""
const fs = require("node:fs");
const crypto = require("node:crypto");
const verifier = "/run/oce-gateway-owner-key/public.pem";
if (!fs.existsSync(verifier)) {
  const keys = crypto.generateKeyPairSync("ed25519", {
    publicKeyEncoding: { type: "spki", format: "pem" },
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
  });
  fs.writeFileSync(verifier, keys.publicKey, { flag: "wx", mode: 0o444 });
  fs.writeFileSync("/run/oce-gateway-owner-start/private.pem", keys.privateKey, { flag: "wx", mode: 0o400 });
}
""".strip()

LINK_SCRIPT = r"""
const fs = require("node:fs");
const path = require("node:path");
const links = JSON.parse(process.env.OCE_STATE_LINKS || "[]");
const root = "/gateway-state";
const descriptorRoot = "/proc/self/fd";
if (!fs.existsSync(descriptorRoot)) {
  throw new Error(`secure state-link traversal requires ${descriptorRoot}`);
}
const directoryFlags =
  fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW;

function openDirectoryNoFollow(directory) {
  const relative = path.posix.relative(root, directory);
  if (relative === ".." || relative.startsWith("../") || path.posix.isAbsolute(relative)) {
    throw new Error(`state-link parent escapes ${root}: ${directory}`);
  }
  const components = relative === "" ? [] : relative.split("/");
  let descriptor = fs.openSync(root, directoryFlags);
  try {
    for (const component of components) {
      const child = `${descriptorRoot}/${descriptor}/${component}`;
      let next;
      try {
        next = fs.openSync(child, directoryFlags);
      } catch (error) {
        if (error.code !== "ENOENT") {
          throw new Error(`refusing unsafe state-link parent ${directory}`, {
            cause: error,
          });
        }
        fs.mkdirSync(child, {mode: 0o700});
        next = fs.openSync(child, directoryFlags);
      }
      fs.closeSync(descriptor);
      descriptor = next;
    }
    return descriptor;
  } catch (error) {
    fs.closeSync(descriptor);
    throw error;
  }
}

for (const item of links) {
  if (item.link === item.target) continue;
  const link = path.posix.join(root, item.link);
  const target = path.posix.join(root, item.target);
  const parent = path.posix.dirname(link);
  const descriptor = openDirectoryNoFollow(parent);
  try {
    const descriptorLink = `${descriptorRoot}/${descriptor}/${path.posix.basename(link)}`;
    let current;
    try {
      current = fs.lstatSync(descriptorLink);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    if (current === undefined) {
      fs.symlinkSync(path.posix.relative(parent, target), descriptorLink);
    } else if (
      !current.isSymbolicLink() ||
      path.posix.resolve(parent, fs.readlinkSync(descriptorLink)) !== target
    ) {
      throw new Error(`refusing to replace ${link}`);
    }
  } finally {
    fs.closeSync(descriptor);
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


def _runtime_images() -> frozenset[str]:
    raw = os.environ.get(RUNTIME_IMAGES_ENV, "")
    images = frozenset(image.strip() for image in raw.split(",") if image.strip())
    if not images or any(not _is_digest_pinned_image(image) for image in images):
        raise AdmissionError(
            f"{RUNTIME_IMAGES_ENV} must contain comma-separated exact sha256 images"
        )
    return images


def _gateway_id(metadata: dict[str, Any]) -> str:
    labels = metadata.get("labels")
    if not isinstance(labels, dict):
        raise AdmissionError("target OCE Pod must declare labels")
    if labels.get("app.kubernetes.io/managed-by") != "openclaw-enterprise":
        raise AdmissionError("target Pod is not managed by OpenClaw Enterprise")
    if labels.get("openclaw.dev/workload-role") != OCE_ROLE:
        raise AdmissionError("only the embedded gateway workload is supported")

    application_name = labels.get("app.kubernetes.io/name")
    if not _is_nonempty_string(application_name) or not application_name.startswith(
        "gateway-"
    ):
        raise AdmissionError("target OCE Pod has an invalid application name")
    gateway_id = application_name.removeprefix("gateway-")
    if GATEWAY_ID_PATTERN.fullmatch(gateway_id) is None:
        raise AdmissionError("target OCE Pod has an invalid gateway identifier")

    for label in (
        "openclaw.dev/agent",
        "openclaw.dev/namespace",
        "openclaw.dev/revision",
    ):
        if OCE_RESOURCE_ID_PATTERN.fullmatch(str(labels.get(label, ""))) is None:
            raise AdmissionError(f"target OCE Pod has an invalid {label} label")
    expected_principal = f"service-agent-{labels['openclaw.dev/agent']}"
    if labels.get("openclaw.dev/service-principal") != expected_principal:
        raise AdmissionError("target OCE Pod has an inconsistent service principal")

    owners = metadata.get("ownerReferences")
    expected_owner_prefix = f"gateway-{gateway_id}-"
    controllers = [
        owner
        for owner in owners or []
        if isinstance(owner, dict) and owner.get("controller") is True
    ]
    if (
        len(controllers) != 1
        or controllers[0].get("apiVersion") != "apps/v1"
        or controllers[0].get("kind") != "ReplicaSet"
        or not str(controllers[0].get("name", "")).startswith(expected_owner_prefix)
    ):
        raise AdmissionError("target OCE Pod must be owned by its gateway ReplicaSet")

    pod_name = metadata.get("name")
    generate_name = metadata.get("generateName")
    if _is_nonempty_string(pod_name) and not pod_name.startswith(expected_owner_prefix):
        raise AdmissionError("target OCE Pod name does not match its gateway")
    if _is_nonempty_string(generate_name) and not generate_name.startswith(
        expected_owner_prefix
    ):
        raise AdmissionError("target OCE Pod generateName does not match its gateway")
    return gateway_id


def _validate_service_account_tokens(volumes: list[Any]) -> None:
    for volume in volumes:
        if not isinstance(volume, dict):
            continue
        projected = volume.get("projected")
        if not isinstance(projected, dict):
            continue
        token_sources = [
            source.get("serviceAccountToken")
            for source in projected.get("sources", [])
            if isinstance(source, dict) and "serviceAccountToken" in source
        ]
        if not token_sources:
            continue
        name = volume.get("name")
        if _is_nonempty_string(name) and name.startswith("kube-api-access-"):
            # Kubernetes injects this projection before admission webhooks run.
            # Its full shape and mounts are validated before mutation removes it.
            continue
        if name != "openclaw-service-principal" or token_sources != [
            {
                "audience": "openclaw-enterprise",
                "expirationSeconds": 900,
                "path": "token",
            }
        ]:
            raise AdmissionError("unsupported service-account token projection")


def _validate_provenance(
    pod: dict[str, Any],
    spec: dict[str, Any],
    volumes: list[Any],
) -> str:
    metadata = pod.get("metadata")
    if not isinstance(metadata, dict):
        raise AdmissionError("target OCE Pod must declare metadata")
    gateway_id = _gateway_id(metadata)
    if spec.get("serviceAccountName") != f"agent-{gateway_id}":
        raise AdmissionError("target OCE Pod has an inconsistent service account")
    claims = [
        volume.get("persistentVolumeClaim", {}).get("claimName")
        for volume in volumes
        if isinstance(volume, dict) and volume.get("name") == STATE_VOLUME
    ]
    if claims != [f"gateway-state-{gateway_id}"]:
        raise AdmissionError("target OCE Pod has an inconsistent gateway state claim")
    _validate_service_account_tokens(volumes)
    return gateway_id


def _safe_relative_path(value: Any, field: str) -> str:
    if not _is_nonempty_string(value):
        raise AdmissionError(f"{field} must be a non-empty relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {".", ".."} for part in path.parts):
        raise AdmissionError(f"{field} must not be absolute or contain dot segments")
    if str(path) != value or "//" in value:
        raise AdmissionError(f"{field} must be a normalized relative path")
    return value


def _safe_absolute_mount_path(value: Any, field: str) -> str:
    if not _is_nonempty_string(value) or not value.startswith("/"):
        raise AdmissionError(f"{field} must be an absolute path")
    canonical = "/" + posixpath.normpath("/" + value.lstrip("/")).lstrip("/")
    if canonical != value:
        raise AdmissionError(f"{field} must be a normalized absolute path")
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


def _validate_trusted_mounts(container: dict[str, Any], location: str) -> None:
    for mount in _mounts(container, location):
        if not isinstance(mount, dict):
            raise AdmissionError(f"{location}.volumeMounts entries must be objects")
        mount_path = _safe_absolute_mount_path(
            mount.get("mountPath"), f"{location}.volumeMounts.mountPath"
        )
        for trusted_path in TRUSTED_BOOTSTRAP_PATHS:
            if _mount_paths_overlap(mount_path, trusted_path):
                raise AdmissionError(
                    f"{location} has a mount that overlaps trusted bootstrap path "
                    f"{trusted_path}"
                )


def _validate_runtime_credential_mounts(
    container: dict[str, Any],
    volumes: list[Any],
    location: str,
    gateway_id: str,
    ignored_volume_names: set[str] | None = None,
) -> None:
    """Reject credential-bearing mounts except the exact OCE runtime inputs."""
    volume_by_name = {
        volume.get("name"): volume
        for volume in volumes
        if isinstance(volume, dict) and _is_nonempty_string(volume.get("name"))
    }
    for mount in _mounts(container, location):
        if not isinstance(mount, dict):
            raise AdmissionError(f"{location}.volumeMounts entries must be objects")
        mount_path = _safe_absolute_mount_path(
            mount.get("mountPath"), f"{location}.volumeMounts.mountPath"
        )
        if mount.get("name") in (ignored_volume_names or set()):
            continue
        if _mount_paths_overlap(mount_path, AWS_CREDENTIAL_DIRECTORY) and not (
            mount.get("name") == RUNTIME_VOLUME
            and mount_path == HOME_MOUNT_PATH
            and mount.get("subPath") in (None, "home")
            and "subPathExpr" not in mount
        ):
            raise AdmissionError(
                f"{location} has a mount that can provide AWS credential files"
            )

        volume = volume_by_name.get(mount.get("name"))
        if not isinstance(volume, dict):
            raise AdmissionError(f"{location} references an unknown volume")
        approved = (
            _is_empty_dir_volume(volume)
            or _is_gateway_state_volume(volume, gateway_id)
            or (
                mount.get("name") == OCE_CONFIGURATION_VOLUME
                and mount
                == {
                    "name": OCE_CONFIGURATION_VOLUME,
                    "mountPath": OCE_CONFIGURATION_MOUNT_PATH,
                    "readOnly": True,
                }
                and _is_oce_configuration_volume(volume, gateway_id)
            )
            or (
                mount.get("name") == OCE_SERVICE_PRINCIPAL_VOLUME
                and mount
                == {
                    "name": OCE_SERVICE_PRINCIPAL_VOLUME,
                    "mountPath": OCE_SERVICE_PRINCIPAL_MOUNT_PATH,
                    "readOnly": True,
                }
                and _is_oce_service_principal_volume(volume)
            )
            or (
                mount.get("name") == AGW_CA_VOLUME
                and _is_agentgateway_ca_mount(mount)
                and _is_agentgateway_ca_volume(volume)
            )
        )
        if not approved:
            raise AdmissionError(
                f"{location} has an unsupported credential-capable volume mount"
            )


def _validate_link_paths(links: dict[str, str]) -> None:
    paths = sorted(PurePosixPath(link).parts for link in links)
    for index, path in enumerate(paths):
        for other in paths[index + 1 :]:
            if len(path) < len(other) and other[: len(path)] == path:
                raise AdmissionError(
                    "gateway-state mount paths must not contain one another"
                )


def _runtime_environment(
    container: dict[str, Any],
    location: str,
    *,
    gateway_id: str | None = None,
    revision_hash: str | None = None,
    require_runtime_values: bool = False,
) -> list[Any]:
    env_from = container.get("envFrom", [])
    if not isinstance(env_from, list):
        raise AdmissionError(f"{location}.envFrom must be a list")
    if env_from:
        raise AdmissionError(
            f"{location}.envFrom is not supported by the adapter contract"
        )
    required = {
        HOME_ENV: HOME_MOUNT_PATH,
        NODE_CA_ENV: AGW_CA_PATH,
        TMPDIR_ENV: TMPDIR_PATH,
    }
    environment = container.get("env", [])
    if not isinstance(environment, list):
        raise AdmissionError(f"{location}.env must be a list")
    environment_names = [
        entry.get("name") for entry in environment if isinstance(entry, dict)
    ]
    duplicate_names = sorted(
        {
            name
            for name in environment_names
            if _is_nonempty_string(name) and environment_names.count(name) > 1
        }
    )
    if duplicate_names:
        raise AdmissionError(
            f"{location} has duplicate environment entries: "
            f"{', '.join(duplicate_names)}"
        )
    credential_names = [
        entry.get("value")
        for entry in environment
        if isinstance(entry, dict)
        and entry.get("name") == "OPENCLAW_HARNESS_CREDENTIAL_ENV"
        and _is_nonempty_string(entry.get("value"))
    ]
    harness_credential_name = credential_names[0] if credential_names else None
    if harness_credential_name is not None:
        if (
            harness_credential_name.startswith("LD_")
            or harness_credential_name in UNSAFE_BOOTSTRAP_ENV_NAMES
        ):
            raise AdmissionError(
                f"{location} configures unsafe bootstrap environment "
                f"{harness_credential_name}"
            )
        if harness_credential_name in AWS_CREDENTIAL_ENV_NAMES:
            raise AdmissionError(
                f"{location} configures prohibited AWS credential environment "
                f"{harness_credential_name}"
            )
        if harness_credential_name not in HARNESS_CREDENTIAL_ENV_NAMES:
            raise AdmissionError(
                f"{location} selects unsupported harness credential environment "
                f"{harness_credential_name}"
            )
        expected_credential = {
            "name": harness_credential_name,
            "valueFrom": {
                "secretKeyRef": {
                    "key": harness_credential_name,
                    "name": (f"harness-secrets-{gateway_id}-{revision_hash}"),
                }
            },
        }
        credential_entries = [
            entry
            for entry in environment
            if isinstance(entry, dict) and entry.get("name") == harness_credential_name
        ]
        if (
            gateway_id is None
            or revision_hash is None
            or credential_entries != [expected_credential]
        ):
            raise AdmissionError(
                f"{location} must source the selected harness credential "
                "from its revision-bound Secret"
            )
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
        if name in AWS_CREDENTIAL_ENV_NAMES:
            raise AdmissionError(
                f"{location} configures prohibited AWS credential environment {name}"
            )
        if name in required and entry != {"name": name, "value": required[name]}:
            raise AdmissionError(f"{location} already configures {name}")
        value_from = entry.get("valueFrom")
        if value_from is None:
            continue
        allowed_value_from = entry == {
            "name": "OPENCLAW_POD_UID",
            "valueFrom": {
                "fieldRef": {
                    "apiVersion": "v1",
                    "fieldPath": "metadata.uid",
                }
            },
        }
        if gateway_id is not None:
            allowed_value_from = allowed_value_from or entry == {
                "name": "OPENCLAW_GATEWAY_PASSWORD",
                "valueFrom": {
                    "secretKeyRef": {
                        "key": "gateway-password",
                        "name": f"gateway-password-{gateway_id}",
                    }
                },
            }
        if (
            gateway_id is not None
            and revision_hash is not None
            and harness_credential_name is not None
        ):
            allowed_value_from = allowed_value_from or entry == {
                "name": harness_credential_name,
                "valueFrom": {
                    "secretKeyRef": {
                        "key": harness_credential_name,
                        "name": (f"harness-secrets-{gateway_id}-{revision_hash}"),
                    }
                },
            }
        if not allowed_value_from:
            raise AdmissionError(
                f"{location} configures an unsupported environment value source"
            )
    for name, value in required.items():
        matches = [
            entry
            for entry in environment
            if isinstance(entry, dict) and entry.get("name") == name
        ]
        if len(matches) > 1:
            raise AdmissionError(f"{location} has duplicate {name} entries")
        if require_runtime_values and matches != [{"name": name, "value": value}]:
            raise AdmissionError(f"{location} must configure {name}={value}")
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
) -> str:
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
                if mount.get("name") != RUNTIME_VOLUME:
                    parent = posixpath.dirname(mount_path)
                    if parent != HOME_MOUNT_PATH:
                        expected_directories.add(
                            parent.replace(HOME_MOUNT_PATH, f"{RUNTIME_ROOT}/home", 1)
                        )
            if mount.get("name") == RUNTIME_VOLUME:
                sub_path = mount.get("subPath")
                if isinstance(sub_path, str) and sub_path != "home":
                    expected_directories.add(
                        f"{RUNTIME_ROOT}/"
                        f"{_safe_relative_path(sub_path, 'runtime-state subPath')}"
                    )
            elif mount.get("name") == STATE_VOLUME:
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

    runtime_home = f"{RUNTIME_ROOT}/home"
    relocated_directories = [
        (
            RUNTIME_ROOT + directory.removeprefix(runtime_home)
            if directory.startswith(f"{runtime_home}/")
            else directory
        )
        for directory in directories
        if directory != runtime_home
    ]
    relocated_lines = copy.deepcopy(lines)
    relocated_lines[1] = (
        f"{prefix}{json.dumps(relocated_directories, separators=(',', ':'))}{suffix}"
    )
    return "\n".join(relocated_lines)


def _validate_owner_init(
    owner: dict[str, Any],
    location: str,
    runtime_image: str,
) -> None:
    unexpected_fields = sorted(set(owner) - OWNER_ALLOWED_FIELDS)
    if unexpected_fields:
        raise AdmissionError(
            f"{location} does not match the fixed embedded-owner contract: "
            f"unexpected fields {unexpected_fields}"
        )
    if owner.get("image") != runtime_image:
        raise AdmissionError(
            f"{location}.image must match the designated runtime image"
        )
    owner_args = owner.get("args")
    owner_script_matches = (
        isinstance(owner_args, list)
        and len(owner_args) == 1
        and isinstance(owner_args[0], str)
        and owner_args[0].strip() == OWNER_SCRIPT
    )
    if (
        owner.get("command")
        not in (
            ["node", "-e"],
            ["/usr/bin/tini", "-s", "--", "node", "-e"],
        )
        or not owner_script_matches
    ):
        raise AdmissionError(
            f"{location} does not match the fixed embedded-owner command contract"
        )
    expected_security = {
        "allowPrivilegeEscalation": False,
        "readOnlyRootFilesystem": True,
        "capabilities": {"drop": ["ALL"]},
    }
    if owner.get("securityContext") != expected_security:
        raise AdmissionError(
            f"{location}.securityContext does not match the fixed embedded-owner "
            "contract"
        )
    mounts = owner.get("volumeMounts")
    if not isinstance(mounts, list):
        raise AdmissionError(
            f"{location}.volumeMounts do not match the fixed embedded-owner contract"
        )
    owner_mounts = [
        mount
        for mount in mounts
        if not (
            isinstance(mount, dict)
            and str(mount.get("name", "")).startswith("kube-api-access-")
            and mount
            == {
                "name": mount["name"],
                "mountPath": SERVICE_ACCOUNT_MOUNT_PATH,
                "readOnly": True,
            }
        )
    ]
    if owner_mounts != [
        {
            "name": "gateway-owner-key",
            "mountPath": "/run/oce-gateway-owner-key",
        },
        {
            "name": "gateway-owner-start",
            "mountPath": "/run/oce-gateway-owner-start",
        },
    ]:
        raise AdmissionError(
            f"{location}.volumeMounts do not match the fixed embedded-owner contract"
        )


def _ownership_init(
    image: str,
    private_paths: list[str],
) -> dict[str, Any]:
    relative_directories = [
        "." if path == HOME_MOUNT_PATH else path.removeprefix(f"{HOME_MOUNT_PATH}/")
        for path in private_paths
    ]
    relative_files = [
        path.removeprefix(f"{HOME_MOUNT_PATH}/")
        for path in (
            CLIENT_CREDENTIAL_PATH,
            RUNTIME_PIN_PATH,
            f"{RUNTIME_PIN_PATH}-wal",
            f"{RUNTIME_PIN_PATH}-shm",
            f"{RUNTIME_PIN_PATH}-journal",
        )
    ]
    arguments = ["--root", HOME_MOUNT_PATH]
    for path in relative_directories:
        option = (
            "--optional-dir"
            if path == RUNTIME_PIN_DIRECTORY.removeprefix(f"{HOME_MOUNT_PATH}/")
            else "--dir"
        )
        arguments.extend([option, path])
    for path in relative_files:
        arguments.extend(["--file", path])
    return {
        "name": OWNERSHIP_INIT_NAME,
        "image": image,
        "command": ["/ownership-helper"],
        "args": arguments,
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
            },
            {
                "name": STATE_VOLUME,
                "mountPath": OPENCLAW_HOME_PATH,
            },
        ],
    }


def _without_admission_defaults(
    container: dict[str, Any],
    expected: dict[str, Any],
) -> dict[str, Any]:
    """Remove only API-server defaults absent from the generated contract."""
    normalized = copy.deepcopy(container)
    for field, default in (
        ("imagePullPolicy", "IfNotPresent"),
        ("terminationMessagePath", "/dev/termination-log"),
        ("terminationMessagePolicy", "File"),
    ):
        if field in expected:
            continue
        value = normalized.pop(field, None)
        if value not in (None, default):
            raise AdmissionError(
                f"final init-container {field} does not match the Kubernetes default"
            )

    if "resources" not in expected:
        resources = normalized.pop("resources", None)
        if resources is not None and not isinstance(resources, dict):
            raise AdmissionError(
                "final init-container resources must be an object when defaulted"
            )
    return normalized


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


def _is_agentgateway_ca_volume(volume: Any) -> bool:
    """Accept only the canonical AgentGateway CA projection."""
    if not isinstance(volume, dict) or set(volume) != {"name", "configMap"}:
        return False
    config_map = volume.get("configMap")
    if not isinstance(config_map, dict):
        return False
    allowed_keys = {"name", "items", "defaultMode", "optional"}
    if not set(config_map).issubset(allowed_keys):
        return False
    if config_map.get("name") != AGW_CA_CONFIG_MAP or config_map.get("items") != [
        {"key": "ca.crt", "path": "ca.crt"}
    ]:
        return False
    if config_map.get("defaultMode", 420) != 420:
        return False
    return config_map.get("optional", False) is False


def _is_agentgateway_ca_mount(mount: Any) -> bool:
    """Accept only the read-only canonical AgentGateway CA mount."""
    return mount == {
        "name": AGW_CA_VOLUME,
        "mountPath": AGW_CA_MOUNT_PATH,
        "readOnly": True,
    }


def _is_oce_configuration_volume(volume: Any, gateway_id: str) -> bool:
    if not isinstance(volume, dict) or set(volume) != {"name", "configMap"}:
        return False
    config_map = volume.get("configMap")
    if not isinstance(config_map, dict):
        return False
    if not set(config_map).issubset({"name", "items", "defaultMode", "optional"}):
        return False
    name = config_map.get("name")
    return (
        _is_nonempty_string(name)
        and re.fullmatch(
            rf"gateway-{re.escape(gateway_id)}-rev-[0-9a-f]{{12}}",
            name,
        )
        is not None
        and config_map.get("items")
        == [{"key": "openclaw.json", "path": "openclaw.json"}]
        and config_map.get("defaultMode", 420) == 420
        and config_map.get("optional", False) is False
    )


def _oce_revision_hash(volumes: list[Any], gateway_id: str) -> str | None:
    matches = [
        volume
        for volume in volumes
        if isinstance(volume, dict)
        and volume.get("name") == OCE_CONFIGURATION_VOLUME
        and _is_oce_configuration_volume(volume, gateway_id)
    ]
    if len(matches) != 1:
        return None
    name = matches[0]["configMap"]["name"]
    return name.rsplit("-", 1)[-1]


def _is_oce_service_principal_volume(volume: Any) -> bool:
    if not isinstance(volume, dict) or set(volume) != {"name", "projected"}:
        return False
    projected = volume.get("projected")
    if (
        not isinstance(projected, dict)
        or not set(projected).issubset({"sources", "defaultMode"})
        or projected.get("defaultMode", 420) != 420
    ):
        return False
    return projected.get("sources") == [
        {
            "serviceAccountToken": {
                "audience": "openclaw-enterprise",
                "expirationSeconds": 900,
                "path": "token",
            }
        }
    ]


def _is_empty_dir_volume(volume: Any) -> bool:
    if not isinstance(volume, dict) or set(volume) != {"name", "emptyDir"}:
        return False
    empty_dir = volume.get("emptyDir")
    return isinstance(empty_dir, dict) and set(empty_dir).issubset(
        {"medium", "sizeLimit"}
    )


def _is_gateway_state_volume(volume: Any, gateway_id: str) -> bool:
    return volume == {
        "name": STATE_VOLUME,
        "persistentVolumeClaim": {
            "claimName": f"gateway-state-{gateway_id}",
        },
    }


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
            and set(source) == {"serviceAccountToken"}
            and isinstance(source.get("serviceAccountToken"), dict)
            and source["serviceAccountToken"].get("path") == "token"
            for source in sources
        )
        has_root_ca = any(
            isinstance(source, dict)
            and set(source) == {"configMap"}
            and isinstance(source.get("configMap"), dict)
            and source["configMap"].get("name") == "kube-root-ca.crt"
            for source in sources
        )
        has_namespace = any(
            isinstance(source, dict)
            and set(source) == {"downwardAPI"}
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
        is_default_projection = (
            len(sources) == 3
            and has_default_token
            and has_root_ca
            and has_namespace
            and references
            and all(
                mount.get("mountPath") == SERVICE_ACCOUNT_MOUNT_PATH
                for mount in references
            )
        )
        if is_default_projection:
            removable.add(name)
        else:
            raise AdmissionError(
                f"volume {name} uses the reserved kube-api-access prefix but "
                "does not match Kubernetes' default service-account projection"
            )
    return removable


def build_patch(pod: dict[str, Any]) -> list[dict[str, Any]]:
    """Return an RFC 6902 patch, or raise AdmissionError for unsafe target Pods."""
    if not isinstance(pod, dict):
        raise AdmissionError("Pod must be an object")

    spec = pod.get("spec")
    if not isinstance(spec, dict):
        raise AdmissionError("target OCE Pod must have a spec")
    volumes = spec.get("volumes", [])
    if not isinstance(volumes, list):
        raise AdmissionError("spec.volumes must be a list")
    gateway_id = _validate_provenance(pod, spec, volumes)
    revision_hash = _oce_revision_hash(volumes, gateway_id)
    init_containers, containers = _container_groups(spec)
    for index, container in enumerate(init_containers):
        if isinstance(container, dict) and container.get("restartPolicy") == "Always":
            raise AdmissionError(
                f"spec.initContainers[{index}] native sidecars are not supported"
            )

    ca_volumes = [
        volume
        for volume in volumes
        if isinstance(volume, dict) and volume.get("name") == AGW_CA_VOLUME
    ]
    if len(ca_volumes) > 1:
        raise AdmissionError(f"expected at most one {AGW_CA_VOLUME} volume")
    if ca_volumes and not _is_agentgateway_ca_volume(ca_volumes[0]):
        raise AdmissionError(f"volume name {AGW_CA_VOLUME} is reserved")

    all_mounts: list[Any] = []
    for group_name, group in (
        ("spec.initContainers", init_containers),
        ("spec.containers", containers),
    ):
        for index, container in enumerate(group):
            location = f"{group_name}[{index}]"
            for mount_index, mount in enumerate(_mounts(container, location)):
                if not isinstance(mount, dict):
                    raise AdmissionError(
                        f"{location}.volumeMounts[{mount_index}] must be an object"
                    )
                _safe_absolute_mount_path(
                    mount.get("mountPath"),
                    f"{location}.volumeMounts[{mount_index}].mountPath",
                )
                all_mounts.append(mount)
    ca_mounts: list[tuple[str, int, dict[str, Any]]] = []
    for group_name, group in (
        ("initContainers", init_containers),
        ("containers", containers),
    ):
        for index, container in enumerate(group):
            for mount in _mounts(container, f"spec.{group_name}[{index}]"):
                if not isinstance(mount, dict):
                    continue
                uses_ca_name = mount.get("name") == AGW_CA_VOLUME
                mount_path = mount.get("mountPath")
                overlaps_ca_path = mount_path != "/" and _mount_paths_overlap(
                    mount_path, AGW_CA_MOUNT_PATH
                )
                if uses_ca_name or overlaps_ca_path:
                    if not _is_agentgateway_ca_mount(mount):
                        raise AdmissionError(
                            f"spec.{group_name}[{index}] uses the reserved "
                            "AgentGateway CA mount"
                        )
                    ca_mounts.append((group_name, index, mount))
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
    initial_init_names = [
        container.get("name") if isinstance(container, dict) else None
        for container in init_containers
    ]
    if len(initial_init_names) != 2 or set(initial_init_names) != {
        PREP_INIT_NAME,
        OWNER_INIT_NAME,
    }:
        raise AdmissionError(
            "the embedded gateway contract permits only its two OCE init containers"
        )
    reserved_container_names = {LINK_INIT_NAME, OWNERSHIP_INIT_NAME}
    for container in [*init_containers, *containers]:
        if (
            isinstance(container, dict)
            and container.get("name") in reserved_container_names
        ):
            raise AdmissionError(f"container name {container['name']} is reserved")

    if len(containers) != 1:
        raise AdmissionError("the embedded gateway contract permits no sidecars")
    designated_indexes = [
        index
        for index, container in enumerate(containers)
        if isinstance(container, dict) and container.get("name") == OCE_ROLE
    ]
    if len(designated_indexes) != 1:
        raise AdmissionError(
            f"expected exactly one designated {OCE_ROLE} runtime container"
        )
    designated_index = designated_indexes[0]
    if len(ca_mounts) > 1:
        raise AdmissionError("expected at most one AgentGateway CA mount")
    if ca_mounts and ca_mounts[0][:2] != ("containers", designated_index):
        raise AdmissionError(
            "only the designated gateway container may mount the AgentGateway CA"
        )
    if bool(ca_volumes) != bool(ca_mounts):
        raise AdmissionError(
            "AgentGateway CA volume and designated gateway mount must be configured together"
        )

    links: dict[str, str] = {}
    mount_patches: list[dict[str, Any]] = []
    environment_patches: list[dict[str, Any]] = []
    runtime_patches: list[dict[str, Any]] = []
    ownership_image = _ownership_init_image()
    allowed_runtime_images = _runtime_images()
    for index, container in enumerate(init_containers):
        location = f"spec.initContainers[{index}]"
        if not isinstance(container, dict):
            raise AdmissionError(f"{location} must be an object")
        if container.get("image") not in allowed_runtime_images:
            raise AdmissionError(
                f"{location}.image is not in the configured OCE runtime allowlist"
            )
        _runtime_environment(container, location)
        if container.get("name") == OWNER_INIT_NAME:
            _validate_owner_init(container, location, container["image"])
            _runtime_contract(container, location)
            _validate_trusted_mounts(container, location)
    designated_runtime_image: str | None = None
    for index, container in enumerate(containers):
        location = f"spec.containers[{index}]"
        runtime_image, runtime_security = _runtime_contract(container, location)
        if runtime_image not in allowed_runtime_images:
            raise AdmissionError(
                f"{location}.image is not in the configured OCE runtime allowlist"
            )
        if runtime_image == ownership_image:
            raise AdmissionError(
                f"{OWNERSHIP_INIT_IMAGE_ENV} must not match a workload runtime image"
            )
        if index == designated_index:
            designated_runtime_image = runtime_image
        _runtime_environment(
            container,
            location,
            gateway_id=gateway_id,
            revision_hash=revision_hash,
        )
        _validate_trusted_mounts(container, location)
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
            runtime_home_count = 0
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
                if mount.get("name") == RUNTIME_VOLUME:
                    if group_name == "initContainers":
                        rewritten.append(copy.deepcopy(mount))
                        continue

                    if "subPathExpr" in mount:
                        raise AdmissionError(
                            f"{RUNTIME_VOLUME} subPathExpr mounts are not supported"
                        )
                    if mount.get("readOnly") is True or "recursiveReadOnly" in mount:
                        raise AdmissionError(
                            f"{RUNTIME_VOLUME} mounts must be writable"
                        )
                    mount_path = _safe_absolute_mount_path(
                        mount.get("mountPath"),
                        f"spec.{group_name}[{index}] runtime-state mountPath",
                    )
                    sub_path = _safe_relative_path(
                        mount.get("subPath"),
                        f"spec.{group_name}[{index}] runtime-state subPath",
                    )
                    relocated_mount = copy.deepcopy(mount)
                    if mount_path == HOME_MOUNT_PATH:
                        if sub_path != "home":
                            raise AdmissionError(
                                f"{RUNTIME_VOLUME} must mount subPath home at "
                                f"{HOME_MOUNT_PATH}"
                            )
                        runtime_home_count += 1
                        relocated_mount.pop("subPath")
                    else:
                        if not mount_path.startswith(f"{HOME_MOUNT_PATH}/"):
                            raise AdmissionError(
                                f"{RUNTIME_VOLUME} subPath mounts must be below "
                                f"{HOME_MOUNT_PATH}/"
                            )
                        if not sub_path.startswith("home/"):
                            raise AdmissionError(
                                f"{RUNTIME_VOLUME} nested subPath mounts must start "
                                "with home/"
                            )
                        relocated_mount["subPath"] = sub_path.removeprefix("home/")
                    rewritten.append(relocated_mount)
                    mounts_changed = True
                    continue

                if mount.get("name") != STATE_VOLUME:
                    if mount.get("mountPath") == STATE_ROOT:
                        raise AdmissionError(
                            f"{STATE_ROOT} is already used by another volume"
                        )
                    mount_path = mount.get("mountPath")
                    if (
                        group_name == "containers"
                        and index == designated_index
                        and _is_nonempty_string(mount_path)
                        and (
                            mount_path == HOME_MOUNT_PATH
                            or HOME_MOUNT_PATH.startswith(f"{mount_path}/")
                        )
                    ):
                        raise AdmissionError(
                            f"{mount_path} would mask the designated runtime home"
                        )
                    if (
                        group_name == "containers"
                        and index == designated_index
                        and _mount_paths_overlap(mount_path, AWS_CREDENTIAL_DIRECTORY)
                    ):
                        raise AdmissionError(
                            f"spec.{group_name}[{index}] has a mount that can "
                            "provide AWS credential files"
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
            if (
                group_name == "containers"
                and index == designated_index
                and runtime_home_count != 1
            ):
                raise AdmissionError(
                    f"spec.{group_name}[{index}] must have exactly one "
                    f"{RUNTIME_VOLUME} subPath home mount at {HOME_MOUNT_PATH}"
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
                    has_ca_mount = any(
                        _is_agentgateway_ca_mount(mount) for mount in rewritten
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
                    if not has_ca_mount:
                        rewritten.append(
                            {
                                "name": AGW_CA_VOLUME,
                                "mountPath": AGW_CA_MOUNT_PATH,
                                "readOnly": True,
                            }
                        )
                    environment = _runtime_environment(
                        container,
                        f"spec.{group_name}[{index}]",
                        gateway_id=gateway_id,
                        revision_hash=revision_hash,
                    )
                    required_environment = [
                        {"name": HOME_ENV, "value": HOME_MOUNT_PATH},
                        {"name": NODE_CA_ENV, "value": AGW_CA_PATH},
                        {"name": TMPDIR_ENV, "value": TMPDIR_PATH},
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

    _validate_runtime_credential_mounts(
        containers[designated_index],
        volumes,
        f"spec.containers[{designated_index}]",
        gateway_id,
        default_service_account_volumes,
    )

    relocated_prep_script = _validate_prepare_private_state(
        prep,
        f"spec.initContainers[{prep_index}]",
        designated_runtime_image,
        default_service_account_volumes,
        containers,
        OCE_ROLE,
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
            RUNTIME_PIN_DIRECTORY,
            *[
                f"{OPENCLAW_HOME_PATH}/{target}"
                for target in sorted(set(links.values()))
            ],
        ],
    )

    patch: list[dict[str, Any]] = []
    labels = pod["metadata"]["labels"]
    network_profile = labels.get(NETWORK_PROFILE_LABEL)
    if network_profile != OCE_BROAD_EGRESS_PROFILE:
        raise AdmissionError(
            f"target OCE Pod must use {NETWORK_PROFILE_LABEL} "
            f"{OCE_BROAD_EGRESS_PROFILE}"
        )

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
            "path": f"/spec/initContainers/{prep_index}/args",
            "value": [relocated_prep_script],
        }
    )
    patch.append(
        {
            "op": "replace",
            "path": f"/spec/initContainers/{prep_index}/securityContext",
            "value": {
                "allowPrivilegeEscalation": False,
                "readOnlyRootFilesystem": True,
                "runAsUser": RUNTIME_UID,
                "runAsGroup": RUNTIME_GID,
                "runAsNonRoot": True,
                "capabilities": {"drop": ["ALL"]},
                "seccompProfile": {"type": "RuntimeDefault"},
            },
        }
    )
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
                        and (
                            volume.get("name") in default_service_account_volumes
                            or volume.get("name") == AGW_CA_VOLUME
                        )
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


def validate_pod(pod: dict[str, Any]) -> None:
    """Validate the complete post-mutation embedded-gateway Pod contract."""
    if not isinstance(pod, dict):
        raise AdmissionError("Pod must be an object")
    spec = pod.get("spec")
    if not isinstance(spec, dict):
        raise AdmissionError("target OCE Pod must have a spec")
    volumes = spec.get("volumes")
    if not isinstance(volumes, list):
        raise AdmissionError("spec.volumes must be a list")
    gateway_id = _validate_provenance(pod, spec, volumes)
    revision_hash = _oce_revision_hash(volumes, gateway_id)
    labels = pod["metadata"]["labels"]
    if labels.get(NETWORK_PROFILE_LABEL) != OCE_BROAD_EGRESS_PROFILE:
        raise AdmissionError(
            f"final OCE Pod must use {NETWORK_PROFILE_LABEL} {OCE_BROAD_EGRESS_PROFILE}"
        )
    if spec.get("runtimeClassName") != "isolated-sandbox":
        raise AdmissionError("final OCE Pod must use runtimeClassName isolated-sandbox")
    if spec.get("automountServiceAccountToken") is not False:
        raise AdmissionError(
            "final OCE Pod must disable automatic service-account tokens"
        )

    init_containers, containers = _container_groups(spec)
    if [
        container.get("name") for container in containers if isinstance(container, dict)
    ] != [OCE_ROLE]:
        raise AdmissionError("final OCE Pod must contain only the gateway container")
    expected_init_names = [
        PREP_INIT_NAME,
        OWNERSHIP_INIT_NAME,
        LINK_INIT_NAME,
        OWNER_INIT_NAME,
    ]
    if [
        container.get("name")
        for container in init_containers
        if isinstance(container, dict)
    ] != expected_init_names:
        raise AdmissionError("final OCE Pod init-container contract is invalid")

    allowed_runtime_images = _runtime_images()
    ownership_image = _ownership_init_image()
    gateway = containers[0]
    gateway_image, _ = _runtime_contract(gateway, "spec.containers[0]")
    if gateway_image not in allowed_runtime_images:
        raise AdmissionError(
            "gateway image is not in the configured OCE runtime allowlist"
        )
    _runtime_environment(
        gateway,
        "spec.containers[0]",
        gateway_id=gateway_id,
        revision_hash=revision_hash,
        require_runtime_values=True,
    )
    _validate_trusted_mounts(gateway, "spec.containers[0]")
    _validate_runtime_credential_mounts(
        gateway,
        volumes,
        "spec.containers[0]",
        gateway_id,
    )

    prep, ownership, link, owner = init_containers
    unexpected_prep_fields = sorted(set(prep) - PREP_ALLOWED_FIELDS)
    if unexpected_prep_fields:
        raise AdmissionError(
            "final prepare-private-state contract contains unexpected fields "
            f"{unexpected_prep_fields}"
        )
    _runtime_environment(prep, "spec.initContainers[0]")
    if prep.get("image") != gateway_image:
        raise AdmissionError("prepare-private-state image does not match the gateway")
    if prep.get("securityContext") != {
        "allowPrivilegeEscalation": False,
        "readOnlyRootFilesystem": True,
        "runAsUser": RUNTIME_UID,
        "runAsGroup": RUNTIME_GID,
        "runAsNonRoot": True,
        "capabilities": {"drop": ["ALL"]},
        "seccompProfile": {"type": "RuntimeDefault"},
    }:
        raise AdmissionError("final prepare-private-state security contract is invalid")
    if prep.get("command") not in (
        ["node", "-e"],
        ["/usr/bin/tini", "-s", "--", "node", "-e"],
    ):
        raise AdmissionError("final prepare-private-state command is invalid")
    prep_mounts = prep.get("volumeMounts")
    allowed_runtime_mounts = (
        {"name": RUNTIME_VOLUME, "mountPath": RUNTIME_ROOT},
        {
            "name": RUNTIME_VOLUME,
            "mountPath": RUNTIME_ROOT,
            "mountPropagation": "HostToContainer",
        },
    )
    expected_prep_mounts = {
        STATE_VOLUME: {"name": STATE_VOLUME, "mountPath": STATE_ROOT},
        RUNTIME_TMP_VOLUME: {
            "name": RUNTIME_TMP_VOLUME,
            "mountPath": RUNTIME_TMP_ROOT,
        },
    }
    if not (
        isinstance(prep_mounts, list)
        and len(prep_mounts) == 3
        and len({mount.get("name") for mount in prep_mounts if isinstance(mount, dict)})
        == 3
        and all(
            isinstance(mount, dict)
            and (
                mount in allowed_runtime_mounts
                if mount.get("name") == RUNTIME_VOLUME
                else mount == expected_prep_mounts.get(mount.get("name"))
            )
            for mount in prep_mounts
        )
    ):
        raise AdmissionError("final prepare-private-state mounts are invalid")

    link_environment = link.get("env")
    if not (
        isinstance(link_environment, list)
        and len(link_environment) == 1
        and isinstance(link_environment[0], dict)
        and link_environment[0].get("name") == "OCE_STATE_LINKS"
        and set(link_environment[0]) == {"name", "value"}
    ):
        raise AdmissionError("final state-link environment contract is invalid")
    try:
        link_data = json.loads(link_environment[0]["value"])
    except (json.JSONDecodeError, TypeError) as error:
        raise AdmissionError("final state-link data is invalid") from error
    if not (
        isinstance(link_data, list)
        and link_data
        and all(
            isinstance(item, dict)
            and set(item) == {"link", "target"}
            and _is_nonempty_string(item["link"])
            and _is_nonempty_string(item["target"])
            for item in link_data
        )
    ):
        raise AdmissionError("final state-link data is invalid")
    links = {item["link"]: item["target"] for item in link_data}
    if len(links) != len(link_data):
        raise AdmissionError("final state-link data contains duplicates")
    for link_path, target_path in links.items():
        _safe_relative_path(link_path, "state link")
        _safe_relative_path(target_path, "state target")
    _validate_link_paths(links)
    canonical_link_data = [
        {"link": link_path, "target": target_path}
        for link_path, target_path in sorted(links.items())
    ]
    if link_data != canonical_link_data:
        raise AdmissionError("final state-link data is not canonical")

    expected_link = {
        "name": LINK_INIT_NAME,
        "image": gateway_image,
        "command": ["node", "-e"],
        "args": [LINK_SCRIPT],
        "env": [
            {
                "name": "OCE_STATE_LINKS",
                "value": json.dumps(
                    canonical_link_data,
                    separators=(",", ":"),
                    sort_keys=True,
                ),
            }
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
        expected_link["imagePullPolicy"] = prep["imagePullPolicy"]
    if _without_admission_defaults(link, expected_link) != expected_link:
        raise AdmissionError("final state-link init-container contract is invalid")

    expected_ownership = _ownership_init(
        ownership_image,
        [
            HOME_MOUNT_PATH,
            OPENCLAW_HOME_PATH,
            RUNTIME_PIN_DIRECTORY,
            *[
                f"{OPENCLAW_HOME_PATH}/{target}"
                for target in sorted(set(links.values()))
            ],
        ],
    )
    if _without_admission_defaults(ownership, expected_ownership) != expected_ownership:
        raise AdmissionError("final ownership init-container contract is invalid")

    prep_args = prep.get("args")
    if not (
        isinstance(prep_args, list)
        and len(prep_args) == 1
        and isinstance(prep_args[0], str)
    ):
        raise AdmissionError("final prepare-private-state arguments are invalid")
    prep_lines = prep_args[0].splitlines()
    prefix = "for (const path of "
    suffix = ") {"
    if (
        len(prep_lines) != 6
        or prep_lines[0] != 'const { chmodSync, mkdirSync } = require("node:fs");'
        or not prep_lines[1].startswith(prefix)
        or not prep_lines[1].endswith(suffix)
        or prep_lines[2:]
        != [
            "  mkdirSync(path, { recursive: true });",
            "  chmodSync(path, 0o700);",
            "}",
            'mkdirSync("/runtime-temporary/tmp", { recursive: true, mode: 0o700 });',
        ]
    ):
        raise AdmissionError("final prepare-private-state script is invalid")
    try:
        prep_directories = json.loads(prep_lines[1][len(prefix) : -len(suffix)])
    except json.JSONDecodeError as error:
        raise AdmissionError("final prepare-private-state script is invalid") from error
    expected_prep_directories = {
        f"{RUNTIME_TMP_ROOT}/tmp",
        f"{RUNTIME_ROOT}/gateway-codex-home",
        f"{RUNTIME_ROOT}/.openclaw",
        *[f"{STATE_ROOT}/{target}" for target in links.values()],
        *[
            f"{RUNTIME_ROOT}/.openclaw/{parent}"
            for link_path in links
            if (parent := posixpath.dirname(link_path)) not in ("", ".")
        ],
    }
    if (
        not isinstance(prep_directories, list)
        or len(prep_directories) != len(set(prep_directories))
        or set(prep_directories) != expected_prep_directories
    ):
        raise AdmissionError("final prepare-private-state directories are invalid")

    for index, container in enumerate(init_containers):
        location = f"spec.initContainers[{index}]"
        if not isinstance(container, dict):
            raise AdmissionError(f"{location} must be an object")
        expected_image = (
            ownership_image
            if container.get("name") == OWNERSHIP_INIT_NAME
            else gateway_image
        )
        if container.get("image") != expected_image:
            raise AdmissionError(f"{location}.image does not match the final contract")
        if container is owner:
            _validate_owner_init(container, location, gateway_image)
            _runtime_environment(container, location)
            _runtime_contract(container, location)
            _validate_trusted_mounts(container, location)

    volume_names = [
        volume.get("name") for volume in volumes if isinstance(volume, dict)
    ]
    if len(volume_names) != len(set(volume_names)):
        raise AdmissionError("final OCE Pod contains duplicate volume names")
    if AGW_CA_VOLUME not in volume_names:
        raise AdmissionError("final OCE Pod is missing the AgentGateway CA volume")
    ca_volume = next(
        volume
        for volume in volumes
        if isinstance(volume, dict) and volume.get("name") == AGW_CA_VOLUME
    )
    if not _is_agentgateway_ca_volume(ca_volume):
        raise AdmissionError("final AgentGateway CA volume contract is invalid")
    if any(
        name.startswith("kube-api-access-")
        for name in volume_names
        if isinstance(name, str)
    ):
        raise AdmissionError("final OCE Pod retains an automatic API token volume")
