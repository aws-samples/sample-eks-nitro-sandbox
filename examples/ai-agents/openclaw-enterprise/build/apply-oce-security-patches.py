#!/usr/bin/env python3
"""Apply reviewed security backports to the exact pinned OCE source tree."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any

OPENSSL_PATCH_FILE_NAME = "openssl-cve-2026-95692.patch"
OPENSSL_PATCH_SHA256 = "ab26acb8f611cd6d07e9d9e30af45ed58e316b6011cb08847bb99fa5ff67f94c"  # pragma: allowlist secret -- public patch checksum
OPENCLAW_PATCH_FILE_NAME = "openclaw-mailauth-security-overrides.patch"
OPENCLAW_PATCH_SHA256 = "ec982d8627084f2f0fba0c09a073aa79d028cee9a1cbe07d09a47740e17449ea"  # pragma: allowlist secret -- reviewed patch checksum
EXPECTED_NODE_SOURCE: dict[str, Any] = {
    "version": "24.22.1",
    "commit": "ce7aaf1cee78b8cf0ce17364260535c418d3ed26",  # pragma: allowlist secret -- public source revision
    "sourceArchiveSha256": (
        "4f5379796280cdaeb0c2f358fd04b6a16cc4fb7dfa83b5a8c91a9d963b435231"  # pragma: allowlist secret -- public archive checksum
    ),
    "patchSha256": ("4ca82f5f04473f4a79b89e57064f71d6f01e6fcacf6794930fc128177306b5c9"),  # pragma: allowlist secret -- public patch checksum
    "modules": "137",
    "napi": "10",
}
EXPECTED_OPENCLAW_SOURCE: dict[str, Any] = {
    "commit": "513c12703ad9a9161cc123e0b8ed4ecb811aa6b3",  # pragma: allowlist secret -- public source revision
    "sourceArchiveSha256": (
        "dab8e21f38603bace955a157f804ddec32b0097ab52286c87b0c0886d45b7730"  # pragma: allowlist secret -- public archive checksum
    ),
    "buildTimestamp": "2026-11-04T17:24:42Z",
}


def fail(message: str) -> None:
    print(f"OCE security backport: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value: Any = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"could not read {path}: {error}")
    if not isinstance(value, dict):
        fail(f"{path} is not a JSON object")
    return value


parser = argparse.ArgumentParser()
parser.add_argument("oce_source", type=pathlib.Path)
parser.add_argument("expected_revision")
parser.add_argument("openssl_patch", type=pathlib.Path)
parser.add_argument("openclaw_patch", type=pathlib.Path)
args = parser.parse_args()

if not re.fullmatch(r"[0-9a-f]{40}", args.expected_revision):
    fail("expected revision must be a full lowercase Git commit SHA")

try:
    actual_revision = subprocess.run(
        ["git", "-C", str(args.oce_source), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
except (OSError, subprocess.CalledProcessError) as error:
    fail(f"could not read the OCE Git revision: {error}")
if actual_revision != args.expected_revision:
    fail(f"OCE checkout is {actual_revision!r}, expected {args.expected_revision!r}")

node_dir = args.oce_source / "deploy" / "runtime" / "node"
source_json = node_dir / "source.json"
fetch_script = node_dir / "fetch.sh"
if read_json(source_json) != EXPECTED_NODE_SOURCE:
    fail("the pinned Node source metadata changed; review the backport before building")

try:
    openssl_patch_bytes = args.openssl_patch.read_bytes()
except OSError as error:
    fail(f"could not read {args.openssl_patch}: {error}")
if hashlib.sha256(openssl_patch_bytes).hexdigest() != OPENSSL_PATCH_SHA256:
    fail("the OpenSSL patch checksum does not match the reviewed upstream patch")
if b"Fixes: CVE-2026-95692" not in openssl_patch_bytes:
    fail("the reviewed CVE identifier is missing from the OpenSSL patch")
try:
    with tempfile.TemporaryDirectory(prefix="oce-openssl-patch-check-") as check_dir:
        subprocess.run(
            [
                "git",
                "apply",
                "--numstat",
                "--unsafe-paths",
                str(args.openssl_patch.resolve()),
            ],
            cwd=check_dir,
            check=True,
            capture_output=True,
            text=True,
        )
except (OSError, subprocess.CalledProcessError) as error:
    fail(f"the reviewed OpenSSL patch is not a valid Git patch: {error}")

try:
    fetch = fetch_script.read_text(encoding="utf-8")
except (OSError, UnicodeError) as error:
    fail(f"could not read {fetch_script}: {error}")

checksum_before = """patch_sha=$(node -p 'require("./source.json").patchSha256')
printf '%s  /build/node.tar.xz\\n%s  worker-esm-termination.patch\\n' "$archive_sha" "$patch_sha" | sha256sum --check --strict
"""
checksum_after = f"""patch_sha=$(node -p 'require("./source.json").patchSha256')
security_patch_sha="{OPENSSL_PATCH_SHA256}"
printf '%s  /build/node.tar.xz\\n%s  worker-esm-termination.patch\\n%s  {OPENSSL_PATCH_FILE_NAME}\\n' "$archive_sha" "$patch_sha" "$security_patch_sha" | sha256sum --check --strict
"""
apply_before = "git apply /node-repair/worker-esm-termination.patch\n"
apply_after = (
    apply_before
    + "git apply -p1 --directory=deps/openssl/openssl "
    + f"/node-repair/{OPENSSL_PATCH_FILE_NAME}\n"
)
if fetch.count(checksum_before) != 1 or fetch.count(apply_before) != 1:
    fail("the pinned Node fetch script changed; review the backport before building")

patched_fetch = fetch.replace(checksum_before, checksum_after).replace(
    apply_before, apply_after
)
openclaw_source_json = args.oce_source / "deploy" / "runtime" / "openclaw-source.json"
if read_json(openclaw_source_json) != EXPECTED_OPENCLAW_SOURCE:
    fail("the pinned OpenClaw source metadata changed; review the patch before building")

try:
    openclaw_patch_bytes = args.openclaw_patch.read_bytes()
except OSError as error:
    fail(f"could not read {args.openclaw_patch}: {error}")
if hashlib.sha256(openclaw_patch_bytes).hexdigest() != OPENCLAW_PATCH_SHA256:
    fail("the OpenClaw patch checksum does not match the reviewed patch")
for marker in (
    b'"mailauth@7.3.1>joi": 18.3.2',
    b'"mailauth@7.3.1>undici": 8.12.3',
    b"joi@18.2.9",
    b"undici@8.11.2",
):
    if marker not in openclaw_patch_bytes:
        fail(f"the OpenClaw patch is missing reviewed marker {marker!r}")
try:
    with tempfile.TemporaryDirectory(prefix="oce-openclaw-patch-check-") as check_dir:
        patch_summary = subprocess.run(
            [
                "git",
                "apply",
                "--numstat",
                "--unsafe-paths",
                str(args.openclaw_patch.resolve()),
            ],
            cwd=check_dir,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
except (OSError, subprocess.CalledProcessError) as error:
    fail(f"the reviewed OpenClaw patch is not a valid Git patch: {error}")
if patch_summary != "7\t11\tpnpm-lock.yaml\n4\t0\tpnpm-workspace.yaml\n":
    fail("the OpenClaw patch changes files outside the reviewed dependency override")

runtime_dockerfile = args.oce_source / "deploy" / "runtime" / "Dockerfile"
runtime_assets_script = args.oce_source / "scripts" / "build-runtime-assets.mjs"
try:
    dockerfile = runtime_dockerfile.read_text(encoding="utf-8")
    runtime_assets = runtime_assets_script.read_text(encoding="utf-8")
except (OSError, UnicodeError) as error:
    fail(f"could not read the OpenClaw runtime build files: {error}")

docker_anchor = """# Record every patch applied here in appliedPatches in scripts/build-runtime-assets.mjs,
# which writes provenance; runtime-assets.test.mjs compares the two.
"""
docker_insertion = docker_anchor + f"""# Pin reviewed transitive dependencies used by the bundled IMAP plugin.
COPY deploy/runtime/{OPENCLAW_PATCH_FILE_NAME} /tmp/{OPENCLAW_PATCH_FILE_NAME}
RUN echo '{OPENCLAW_PATCH_SHA256}  /tmp/{OPENCLAW_PATCH_FILE_NAME}' | sha256sum --check --strict \\
    && git apply /tmp/{OPENCLAW_PATCH_FILE_NAME}
"""
assets_anchor = "const appliedPatches = [\n"
assets_insertion = assets_anchor + f"""  {{
    file: "{OPENCLAW_PATCH_FILE_NAME}",
    sha256: "{OPENCLAW_PATCH_SHA256}",
  }},
"""
if dockerfile.count(docker_anchor) != 1 or runtime_assets.count(assets_anchor) != 1:
    fail("the OpenClaw runtime patch anchors changed; review the patch before building")

openclaw_destination = (
    args.oce_source / "deploy" / "runtime" / OPENCLAW_PATCH_FILE_NAME
)
openssl_destination = node_dir / OPENSSL_PATCH_FILE_NAME
try:
    shutil.copyfile(args.openssl_patch, openssl_destination)
    fetch_script.write_text(patched_fetch, encoding="utf-8")
    shutil.copyfile(args.openclaw_patch, openclaw_destination)
    runtime_dockerfile.write_text(
        dockerfile.replace(docker_anchor, docker_insertion),
        encoding="utf-8",
    )
    runtime_assets_script.write_text(
        runtime_assets.replace(assets_anchor, assets_insertion),
        encoding="utf-8",
    )
except OSError as error:
    fail(f"could not prepare the OpenClaw runtime source tree: {error}")

print(
    "OCE security backport: applied CVE-2026-95692 patch "
    f"{OPENSSL_PATCH_SHA256} to Node {EXPECTED_NODE_SOURCE['version']}; "
    f"applied OpenClaw dependency patch {OPENCLAW_PATCH_SHA256}"
)
