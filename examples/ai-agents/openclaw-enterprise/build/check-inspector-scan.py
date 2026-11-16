#!/usr/bin/env python3
"""Fail closed unless Inspector covered an exact ECR digest with no severe findings."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
from typing import Any

PENDING = 10
PENDING_REASONS = {"PENDING_INITIAL_SCAN", "SCAN_IN_PROGRESS"}


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
if not items:
    print("Inspector image scan: ACTIVE with CRITICAL=0, HIGH=0")
    raise SystemExit(0)

finding = items[0]
if not isinstance(finding, dict):
    fail("finding is not an object")
if finding.get("awsAccountId") != args.account_id:
    fail("finding account does not match the requested image")
if finding.get("status") != "ACTIVE":
    fail("finding status is not ACTIVE")
if finding.get("severity") not in {"CRITICAL", "HIGH"}:
    fail("finding severity is not CRITICAL or HIGH")

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

fail(
    f"scan found {finding['severity']} finding {finding.get('findingArn', '<unknown>')}"
)
