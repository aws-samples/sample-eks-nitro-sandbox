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
BACKPORT_CVE = "CVE-2026-95692"
BACKPORT_PATCH_SHA256 = (
    "ab26acb8f611cd6d07e9d9e30af45ed58e316b6011cb08847bb99fa5ff67f94c"
)
BACKPORT_REFERENCE = (
    "https://github.com/openssl/openssl/commit/257a3427aa0ef8d9dd2ef5b3e2d1c021a221b116"
)
BACKPORT_PATHS = {
    "/usr/local/include/node/openssl/archs/linux-x86_64/"
    f"{variant}/include/openssl/opensslv.h"
    for variant in ("asm", "asm_avx2", "no-asm")
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


parser = argparse.ArgumentParser()
parser.add_argument("coverage", type=pathlib.Path)
parser.add_argument("findings", type=pathlib.Path)
parser.add_argument("resource_id")
parser.add_argument("account_id")
parser.add_argument("repository")
parser.add_argument("digest")
parser.add_argument("--backport-patch", type=pathlib.Path)
args = parser.parse_args()

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


def is_reviewed_backport(finding: dict[str, Any]) -> bool:
    if args.backport_patch is None or finding.get("severity") != "HIGH":
        return False
    try:
        patch_sha256 = hashlib.sha256(args.backport_patch.read_bytes()).hexdigest()
    except OSError as error:
        fail(f"could not read the backport patch: {error}")
    if patch_sha256 != BACKPORT_PATCH_SHA256:
        fail("backport patch checksum does not match the reviewed upstream patch")

    details = finding.get("packageVulnerabilityDetails")
    if not isinstance(details, dict):
        return False
    packages = details.get("vulnerablePackages")
    references = details.get("referenceUrls")
    if (
        details.get("vulnerabilityId") != BACKPORT_CVE
        or not isinstance(packages, list)
        or len(packages) != len(BACKPORT_PATHS)
        or not isinstance(references, list)
        or BACKPORT_REFERENCE not in references
    ):
        return False

    actual_paths: set[str] = set()
    for package in packages:
        if not isinstance(package, dict):
            return False
        if (
            package.get("name") != "openssl/openssl"
            or package.get("version") != "3.5.9"
            or package.get("fixedInVersion") != "3.5.10"
            or package.get("packageManager") != "GENERIC"
            or not isinstance(package.get("filePath"), str)
        ):
            return False
        actual_paths.add(package["filePath"])
    return actual_paths == BACKPORT_PATHS


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
    "Inspector image scan: ACTIVE with CRITICAL=0, HIGH=0; "
    f"accepted {accepted_backports} reviewed source backport"
)
