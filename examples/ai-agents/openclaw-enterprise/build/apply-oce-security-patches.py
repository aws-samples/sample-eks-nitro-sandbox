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

PATCH_FILE_NAME = "openssl-cve-2026-95692.patch"
PATCH_SHA256 = "ab26acb8f611cd6d07e9d9e30af45ed58e316b6011cb08847bb99fa5ff67f94c"
EXPECTED_NODE_SOURCE: dict[str, Any] = {
    "version": "24.22.1",
    "commit": "ce7aaf1cee78b8cf0ce17364260535c418d3ed26",
    "sourceArchiveSha256": (
        "4f5379796280cdaeb0c2f358fd04b6a16cc4fb7dfa83b5a8c91a9d963b435231"
    ),
    "patchSha256": ("4ca82f5f04473f4a79b89e57064f71d6f01e6fcacf6794930fc128177306b5c9"),
    "modules": "137",
    "napi": "10",
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
parser.add_argument("patch", type=pathlib.Path)
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
    patch_bytes = args.patch.read_bytes()
except OSError as error:
    fail(f"could not read {args.patch}: {error}")
if hashlib.sha256(patch_bytes).hexdigest() != PATCH_SHA256:
    fail("the OpenSSL patch checksum does not match the reviewed upstream patch")
if b"Fixes: CVE-2026-95692" not in patch_bytes:
    fail("the reviewed CVE identifier is missing from the OpenSSL patch")
try:
    with tempfile.TemporaryDirectory(prefix="oce-openssl-patch-check-") as check_dir:
        subprocess.run(
            [
                "git",
                "apply",
                "--numstat",
                "--unsafe-paths",
                str(args.patch.resolve()),
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
security_patch_sha="{PATCH_SHA256}"
printf '%s  /build/node.tar.xz\\n%s  worker-esm-termination.patch\\n%s  {PATCH_FILE_NAME}\\n' "$archive_sha" "$patch_sha" "$security_patch_sha" | sha256sum --check --strict
"""
apply_before = "git apply /node-repair/worker-esm-termination.patch\n"
apply_after = (
    apply_before
    + "git apply -p1 --directory=deps/openssl/openssl "
    + f"/node-repair/{PATCH_FILE_NAME}\n"
)
if fetch.count(checksum_before) != 1 or fetch.count(apply_before) != 1:
    fail("the pinned Node fetch script changed; review the backport before building")

patched_fetch = fetch.replace(checksum_before, checksum_after).replace(
    apply_before, apply_after
)
destination = node_dir / PATCH_FILE_NAME
try:
    shutil.copyfile(args.patch, destination)
    fetch_script.write_text(patched_fetch, encoding="utf-8")
except OSError as error:
    fail(f"could not prepare the OCE source tree: {error}")

print(
    "OCE security backport: applied CVE-2026-95692 patch "
    f"{PATCH_SHA256} to Node {EXPECTED_NODE_SOURCE['version']}"
)
