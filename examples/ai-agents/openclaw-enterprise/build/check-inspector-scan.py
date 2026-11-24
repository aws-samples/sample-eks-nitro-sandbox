#!/usr/bin/env python3
"""Fail closed unless Inspector covered an exact ECR digest with no severe findings."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys
from typing import Any

PENDING = 10
PENDING_REASONS = {"PENDING_INITIAL_SCAN", "SCAN_IN_PROGRESS"}
NODE_OPENSSL_PATHS = {
    "/usr/local/include/node/openssl/archs/linux-x86_64/"
    f"{variant}/include/openssl/opensslv.h"
    for variant in ("asm", "asm_avx2", "no-asm")
}
PACKAGE_FIELDS = (
    "name",
    "version",
    "release",
    "epoch",
    "arch",
    "packageManager",
    "fixedInVersion",
    "filePath",
    "remediation",
)
REVIEWED_BACKPORTS = {
    "CVE-2026-95692": {
        "patch_sha256": (
            "ab26acb8f611cd6d07e9d9e30af45ed58e316b6011cb08847bb99fa5ff67f94c"  # pragma: allowlist secret -- public patch checksum
        ),
        "reference": (
            "https://github.com/openssl/openssl/commit/"
            "257a3427aa0ef8d9dd2ef5b3e2d1c021a221b116"  # pragma: allowlist secret -- public source revision
        ),
        "packages": [
            {
                "name": "openssl/openssl",
                "version": "3.5.9",
                "packageManager": "GENERIC",
                "fixedInVersion": "3.5.10",
                "filePath": path,
            }
            for path in sorted(NODE_OPENSSL_PATHS)
        ],
    },
    "CVE-2026-88823": {
        "patch_sha256": (
            "a945077c0a978dbfe5af5e4f7174a2151466547f8fb94562f395baa7b6b7c147"  # pragma: allowlist secret -- public patch checksum
        ),
        "reference": (
            "https://github.com/openssl/openssl/commit/"
            "159e1de0c448d7b9f09ad768c8e141def4aa1eb4"  # pragma: allowlist secret -- public source revision
        ),
        "packages": [
            {
                "name": "openssl",
                "version": "3.5.9",
                "release": "1~deb13u1+oce1",
                "epoch": 0,
                "arch": "AMD64",
                "packageManager": "OS",
                "fixedInVersion": "NotAvailable",
                "filePath": "/var/lib/dpkg/status",
                "remediation": (
                    "Update affected packages to fixed version (or newer)."
                ),
            },
            *[
                {
                    "name": "openssl/openssl",
                    "version": "3.5.9",
                    "epoch": 0,
                    "packageManager": "GENERIC",
                    "fixedInVersion": "3.5.10",
                    "filePath": path,
                    "remediation": (
                        "Update affected packages to fixed version (or newer)."
                    ),
                }
                for path in sorted(NODE_OPENSSL_PATHS)
            ],
        ],
    },
    "CVE-2026-107496": {
        "patch_sha256": (
            "77d3759d279c71af59629c4a0fa82d8272a099762f2fa9e3f66d7ca5ed544157"  # pragma: allowlist secret -- public patch checksum
        ),
        "reference": (
            "https://github.com/openssl/openssl/commit/"
            "a0051cfe699bf5a047bc1c4faef65f80f7987366"  # pragma: allowlist secret -- public source revision
        ),
        "package_sets": [
            [
                {
                    "name": "openssl/openssl",
                    "version": "3.5.9",
                    "epoch": 0,
                    "packageManager": "GENERIC",
                    "fixedInVersion": "3.5.10",
                    "filePath": path,
                    "remediation": (
                        "Update affected packages to fixed version (or newer)."
                    ),
                }
                for path in sorted(NODE_OPENSSL_PATHS)
            ],
            [
                {
                    "name": "openssl",
                    "version": "3.5.9",
                    "release": "1~deb13u1+oce2",
                    "epoch": 0,
                    "arch": "AMD64",
                    "packageManager": "OS",
                    "fixedInVersion": "NotAvailable",
                    "filePath": "/var/lib/dpkg/status",
                    "remediation": (
                        "Update affected packages to fixed version (or newer)."
                    ),
                },
                *[
                    {
                        "name": "openssl/openssl",
                        "version": "3.5.9",
                        "epoch": 0,
                        "packageManager": "GENERIC",
                        "fixedInVersion": "3.5.10",
                        "filePath": path,
                        "remediation": (
                            "Update affected packages to fixed version (or newer)."
                        ),
                    }
                    for path in sorted(NODE_OPENSSL_PATHS)
                ],
            ],
        ],
    },
}


def fail(message: str, status: int = 1) -> None:
    print(f"Inspector image scan: {message}", file=sys.stderr)
    raise SystemExit(status)


def read_object(path: pathlib.Path, name: str) -> dict[str, Any]:
    try:
        value: Any = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeDecodeError) as error:
        fail(f"invalid {name} response: {error}")
    if not isinstance(value, dict):
        fail(f"{name} response is not an object")
    return value


# Only source backports validated by the pinned build manifest may match
# generic Node header records. OS packages and unrelated findings still fail.
security_manifest = pathlib.Path(__file__).resolve().parent / "openssl" / "source.json"
try:
    security_manifest_bytes = security_manifest.read_bytes()
except OSError as error:
    fail(f"could not read reviewed OpenSSL manifest: {error}")
if hashlib.sha256(security_manifest_bytes).hexdigest() != (
    "c54110fa43dafa9542779264036f2864a0b828551564d2400b5e22782b57e8da"  # pragma: allowlist secret -- public metadata checksum
):
    fail("reviewed OpenSSL manifest checksum changed")
security_metadata = read_object(security_manifest, "reviewed OpenSSL manifest")
for entry in security_metadata["additionalBackports"]:
    REVIEWED_BACKPORTS[entry["cve"]] = {
        "patch_sha256": entry["patchSha256"],
        "reference": "https://github.com/openssl/openssl/commit/" + entry["commit"],
        "packages": [
            {
                "name": "openssl/openssl",
                "version": "3.5.9",
                "epoch": 0,
                "packageManager": "GENERIC",
                "fixedInVersion": "3.5.10",
                "filePath": path,
                "remediation": "Update affected packages to fixed version (or newer).",
            }
            for path in sorted(NODE_OPENSSL_PATHS)
        ],
    }


parser = argparse.ArgumentParser()
parser.add_argument("coverage", type=pathlib.Path)
parser.add_argument("findings", type=pathlib.Path)
parser.add_argument("resource_id")
parser.add_argument("account_id")
parser.add_argument("repository")
parser.add_argument("digest")
parser.add_argument(
    "--backport-patch",
    action="append",
    default=[],
    type=pathlib.Path,
)
args = parser.parse_args()

reviewed_patch_cves: dict[str, str] = {}
known_patch_hashes = {
    policy["patch_sha256"]: cve
    for cve, policy in REVIEWED_BACKPORTS.items()
}
for patch in args.backport_patch:
    try:
        patch_sha256 = hashlib.sha256(patch.read_bytes()).hexdigest()
    except OSError as error:
        fail(f"could not read the backport patch: {error}")
    cve = known_patch_hashes.get(patch_sha256)
    if cve is None:
        fail("backport patch checksum does not match a reviewed upstream patch")
    if cve in reviewed_patch_cves:
        fail(f"backport patch for {cve} was provided more than once")
    reviewed_patch_cves[cve] = patch_sha256

coverage = read_object(args.coverage, "coverage")
resources = coverage.get("coveredResources")
if not isinstance(resources, list):
    fail("coveredResources is missing or is not an array")
if not resources:
    fail("coverage is not available yet", PENDING)
if len(resources) != 1 or not isinstance(resources[0], dict):
    fail("coverage did not resolve to exactly one resource")

resource = resources[0]
expected_fields = {
    "resourceType": "AWS_ECR_CONTAINER_IMAGE",
    "resourceId": args.resource_id,
    "accountId": args.account_id,
    "scanType": "PACKAGE",
}
for field, expected in expected_fields.items():
    if resource.get(field) != expected:
        fail(f"coverage {field} does not match the requested image")

metadata = resource.get("resourceMetadata")
if not isinstance(metadata, dict):
    fail("coverage resourceMetadata is missing or is not an object")
ecr_repository = metadata.get("ecrRepository")
if not isinstance(ecr_repository, dict):
    fail("coverage ECR repository metadata is missing")
if ecr_repository.get("name") != args.repository:
    fail("coverage repository does not match the requested image")

scan_status = resource.get("scanStatus")
if not isinstance(scan_status, dict):
    fail("coverage scanStatus is missing or is not an object")
reason = scan_status.get("reason")
if reason in PENDING_REASONS:
    fail(f"scan is pending ({reason})", PENDING)
if scan_status.get("statusCode") != "ACTIVE" or reason != "SUCCESSFUL":
    fail(
        "coverage is not successful "
        f"(statusCode={scan_status.get('statusCode')!r}, reason={reason!r})"
    )
if resource.get("lastScannedAt") is None:
    fail("successful coverage has no lastScannedAt timestamp")

findings = read_object(args.findings, "findings")
items = findings.get("findings")
if not isinstance(items, list):
    fail("findings is missing or is not an array")
if findings.get("nextToken") is not None:
    fail("findings response is truncated")
if not items:
    print("Inspector image scan: ACTIVE with CRITICAL=0, HIGH=0")
    raise SystemExit(0)


def validate_resource(finding: dict[str, Any]) -> None:
    resources = finding.get("resources")
    if not isinstance(resources, list) or not resources:
        fail("finding has no resources")
    matches_image = False
    for finding_resource in resources:
        if not isinstance(finding_resource, dict):
            fail("finding resource is not an object")
        details = finding_resource.get("details")
        if not isinstance(details, dict):
            continue
        image = details.get("awsEcrContainerImage")
        if not isinstance(image, dict):
            continue
        if (
            finding_resource.get("type") == "AWS_ECR_CONTAINER_IMAGE"
            and finding_resource.get("id") == args.resource_id
            and image.get("repositoryName") == args.repository
            and image.get("imageHash") == args.digest
            and image.get("registry") == args.account_id
        ):
            matches_image = True
            break
    if not matches_image:
        fail("finding does not match the requested image")


def package_signature(package: dict[str, Any]) -> tuple[Any, ...]:
    return tuple(package.get(field) for field in PACKAGE_FIELDS)


def is_reviewed_backport(finding: dict[str, Any]) -> bool:
    if finding.get("severity") != "HIGH":
        return False

    details = finding.get("packageVulnerabilityDetails")
    if not isinstance(details, dict):
        return False
    cve = details.get("vulnerabilityId")
    if not isinstance(cve, str):
        return False
    policy = REVIEWED_BACKPORTS.get(cve)
    if policy is None or cve not in reviewed_patch_cves:
        return False

    packages = details.get("vulnerablePackages")
    references = details.get("referenceUrls")
    if not isinstance(packages, list) or not isinstance(references, list):
        return False
    if policy["reference"] not in references:
        return False

    if not all(isinstance(package, dict) for package in packages):
        return False
    actual_packages = sorted(package_signature(package) for package in packages)
    expected_package_sets = policy.get("package_sets")
    if expected_package_sets is None:
        expected_package_sets = [policy["packages"]]
    return any(
        actual_packages
        == sorted(package_signature(package) for package in expected_packages)
        for expected_packages in expected_package_sets
    )


accepted_backports = 0
for finding in items:
    if not isinstance(finding, dict):
        fail("finding is not an object")
    if finding.get("awsAccountId") != args.account_id:
        fail("finding account does not match the requested image")
    if finding.get("status") != "ACTIVE":
        fail("finding status is not ACTIVE")
    if finding.get("severity") not in {"CRITICAL", "HIGH"}:
        fail("finding severity is not CRITICAL or HIGH")
    validate_resource(finding)
    if is_reviewed_backport(finding):
        accepted_backports += 1
        continue
    fail(
        f"scan found {finding['severity']} finding "
        f"{finding.get('findingArn', '<unknown>')}"
    )

print(
    "Inspector image scan: ACTIVE with CRITICAL=0; "
    f"accepted {accepted_backports} reviewed HIGH source backport finding(s)"
)
