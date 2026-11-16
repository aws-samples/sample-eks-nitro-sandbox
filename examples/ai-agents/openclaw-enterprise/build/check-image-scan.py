#!/usr/bin/env python3
"""Fail closed unless an ECR image scan is complete and has no severe findings."""

from __future__ import annotations

import json
import sys
from typing import Any

PENDING = 10
READY_STATUSES = {"ACTIVE", "COMPLETE"}
PENDING_STATUSES = {"IN_PROGRESS", "PENDING"}


def fail(message: str, status: int = 1) -> None:
    print(f"image scan: {message}", file=sys.stderr)
    raise SystemExit(status)


def require_mapping(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{name} is missing or is not an object")
    return value


try:
    response: Any = json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeDecodeError) as error:
    fail(f"invalid ECR response: {error}")

root = require_mapping(response, "response")
scan_status = require_mapping(root.get("imageScanStatus"), "imageScanStatus")
status = scan_status.get("status")
if status in PENDING_STATUSES:
    fail(f"scan is {status}", PENDING)
if status not in READY_STATUSES:
    fail(f"scan ended with unsupported status {status!r}")

findings = require_mapping(root.get("imageScanFindings"), "imageScanFindings")
if findings.get("imageScanCompletedAt") is None:
    fail(f"{status} scan has no completion timestamp", PENDING)

counts = require_mapping(
    findings.get("findingSeverityCounts"), "findingSeverityCounts"
)
severe_counts: dict[str, int] = {}
for severity in ("CRITICAL", "HIGH"):
    count = counts.get(severity, 0)
    if isinstance(count, bool) or not isinstance(count, int) or count < 0:
        fail(f"{severity} count is not a non-negative integer")
    severe_counts[severity] = count

if any(severe_counts.values()):
    fail(
        "scan found "
        + ", ".join(
            f"{severity}={severe_counts[severity]}"
            for severity in ("CRITICAL", "HIGH")
        )
    )

print(f"image scan: {status} with CRITICAL=0, HIGH=0")
