#!/usr/bin/env python3
"""Verify that Inspector enhanced scanning covers every release repository."""

from __future__ import annotations

import json
import pathlib
import re
import sys
from typing import Any


def fail(message: str) -> None:
    raise SystemExit(f"enhanced scanning preflight: {message}")


def load_object(path: str) -> dict[str, Any]:
    try:
        value = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"could not read {path}: {error}")
    if not isinstance(value, dict):
        fail(f"{path} must contain a JSON object")
    return value


def filter_matches(repository: str, pattern: str) -> bool:
    """Apply Amazon ECR's repository filter semantics.

    A filter without an asterisk is a substring match. An asterisk is the only
    wildcard ECR documents for these filters, so all other characters remain
    literal.
    """
    if "*" not in pattern:
        return pattern in repository
    expression = re.escape(pattern).replace(r"\*", ".*")
    return re.fullmatch(expression, repository) is not None


if len(sys.argv) < 5:
    fail(
        "usage: check-enhanced-scanning.py ACCOUNT_STATUS REGISTRY_CONFIG "
        "ACCOUNT_ID REPOSITORY..."
    )

account_status = load_object(sys.argv[1])
registry_config = load_object(sys.argv[2])
account_id = sys.argv[3]
repositories = sys.argv[4:]

if not re.fullmatch(r"[0-9]{12}", account_id):
    fail("account ID must contain 12 digits")
if any(not repository or repository.startswith("/") for repository in repositories):
    fail("repository names must be non-empty relative names")

failed_accounts = account_status.get("failedAccounts", [])
if failed_accounts:
    fail("Inspector did not return a complete account status")
accounts = account_status.get("accounts")
if not isinstance(accounts, list):
    fail("Inspector account status omitted accounts")
account = next(
    (
        value
        for value in accounts
        if isinstance(value, dict) and value.get("accountId") == account_id
    ),
    None,
)
if account is None:
    fail(f"Inspector account status omitted {account_id}")
if account.get("state", {}).get("status") != "ENABLED":
    fail(f"Amazon Inspector is not enabled for account {account_id}")
if account.get("resourceState", {}).get("ecr", {}).get("status") != "ENABLED":
    fail(f"Amazon Inspector ECR scanning is not enabled for account {account_id}")

if registry_config.get("registryId") != account_id:
    fail("ECR registry ID does not match the build account")
configuration = registry_config.get("scanningConfiguration")
if not isinstance(configuration, dict):
    fail("ECR registry scanning configuration is missing")
if configuration.get("scanType") != "ENHANCED":
    fail("ECR registry scan type must be ENHANCED")

filters: list[str] = []
rules = configuration.get("rules")
if not isinstance(rules, list):
    fail("ECR enhanced scanning rules are missing")
for rule in rules:
    if not isinstance(rule, dict) or rule.get("scanFrequency") not in {
        "CONTINUOUS_SCAN",
        "SCAN_ON_PUSH",
    }:
        continue
    repository_filters = rule.get("repositoryFilters")
    if not isinstance(repository_filters, list):
        continue
    for repository_filter in repository_filters:
        if (
            isinstance(repository_filter, dict)
            and repository_filter.get("filterType") == "WILDCARD"
            and isinstance(repository_filter.get("filter"), str)
        ):
            filters.append(repository_filter["filter"])

uncovered = [
    repository
    for repository in repositories
    if not any(filter_matches(repository, pattern) for pattern in filters)
]
if uncovered:
    fail(
        "no enabled enhanced-scanning rule covers: " + ", ".join(sorted(set(uncovered)))
    )
