"""Check sanitized Inspector inventories through the real digest gate."""

from __future__ import annotations

import copy
import json
import pathlib
import subprocess
import sys

import pytest

BUILD = pathlib.Path(__file__).resolve().parents[1] / "build"
CHECKER = BUILD / "check-inspector-scan.py"
ACCOUNT = "123456789012"
REPOSITORY = "sample/runtime"
DIGEST = "sha256:" + "a" * 64
RESOURCE = f"arn:aws:ecr:us-west-2:{ACCOUNT}:repository/{REPOSITORY}/{DIGEST}"
REMEDIATION = "Update affected packages to fixed version (or newer)."
PATHS = [
    "/usr/local/include/node/openssl/archs/linux-x86_64/"
    f"{variant}/include/openssl/opensslv.h"
    for variant in ("asm", "asm_avx2", "no-asm")
]
# Public upstream references, independent of the checker's policy table.
REFERENCES = {
    "CVE-2026-88823": "159e1de0c448d7b9f09ad768c8e141def4aa1eb4",
    "CVE-2026-95692": "257a3427aa0ef8d9dd2ef5b3e2d1c021a221b116",
    "CVE-2026-107496": "a0051cfe699bf5a047bc1c4faef65f80f7987366",
    "CVE-2026-95691": "f6244675833e097c2429a40d1b206d95385bd42f",
    "CVE-2026-107493": "c8f6d04f8e6d40b1bf83334e4a2ec9daf5943a3d",
    "CVE-2026-124709": "f3acb0a3328046741479482c51cec815839e1b05",
    "CVE-2026-121482": "468c287cf451a834b370b69ab321b8ffdfac23aa",
    "CVE-2026-107494": "734c6cd7444bdbf589bfec917e47598c1b21ddd3",
    "CVE-2026-84786": "1ad851363d5b8588b0d40edcc045fd633e93f0c2",
}
GAP_CVES = ("CVE-2026-88823", "CVE-2026-95692")


def current_finding(cve):
    """Keep the observed package fields; replace image and layer identifiers."""
    return {
        "awsAccountId": ACCOUNT,
        "status": "ACTIVE",
        "severity": "HIGH",
        "findingArn": "sanitized-finding",
        "resources": [{
            "type": "AWS_ECR_CONTAINER_IMAGE",
            "id": RESOURCE,
            "details": {"awsEcrContainerImage": {
                "repositoryName": REPOSITORY,
                "imageHash": DIGEST,
                "registry": ACCOUNT,
            }},
        }],
        "packageVulnerabilityDetails": {
            "vulnerabilityId": cve,
            "referenceUrls": [
                "https://github.com/openssl/openssl/commit/" + REFERENCES[cve],
                "https://nvd.nist.gov/vuln/detail/" + cve,
            ],
            "vulnerablePackages": [{
                "name": "openssl/openssl",
                "version": "3.5.9",
                "epoch": 0,
                "packageManager": "GENERIC",
                "fixedInVersion": "3.5.10",
                "filePath": path,
                "remediation": REMEDIATION,
                "sourceLayerHash": "sha256:" + "b" * 64,
            } for path in PATHS],
        },
    }


def os_package(release="1~deb13u1+oce3"):
    return {
        "name": "openssl",
        "version": "3.5.9",
        "release": release,
        "epoch": 0,
        "arch": "AMD64",
        "packageManager": "OS",
        "fixedInVersion": "NotAvailable",
        "filePath": "/var/lib/dpkg/status",
        "remediation": REMEDIATION,
    }


def run_checker(tmp_path, items, patches=None):
    coverage = {
        "coveredResources": [{
            "resourceType": "AWS_ECR_CONTAINER_IMAGE",
            "resourceId": RESOURCE,
            "accountId": ACCOUNT,
            "scanType": "PACKAGE",
            "resourceMetadata": {"ecrRepository": {"name": REPOSITORY}},
            "scanStatus": {"statusCode": "ACTIVE", "reason": "SUCCESSFUL"},
            "lastScannedAt": "2026-11-26T00:00:00Z",
        }],
    }
    coverage_path = tmp_path / "coverage.json"
    findings_path = tmp_path / "findings.json"
    coverage_path.write_text(json.dumps(coverage))
    findings_path.write_text(json.dumps({"findings": items}))
    arguments = [
        sys.executable, str(CHECKER), str(coverage_path), str(findings_path),
        RESOURCE, ACCOUNT, REPOSITORY, DIGEST,
    ]
    if patches is None:
        patches = [
            BUILD / "patches" / f"openssl-{cve.lower()}.patch"
            for cve in REFERENCES
        ]
    for patch in patches:
        arguments.extend(["--backport-patch", str(patch)])
    return subprocess.run(arguments, capture_output=True, text=True, check=False)


@pytest.mark.parametrize("cve", REFERENCES)
def test_current_exact_generic_inventory_accepted(tmp_path, cve):
    result = run_checker(tmp_path, [current_finding(cve)])
    assert result.returncode == 0, result.stderr
    assert "accepted 1 reviewed HIGH source backport finding(s)" in result.stdout


def test_complete_current_inventory_accepted(tmp_path):
    result = run_checker(tmp_path, [current_finding(cve) for cve in REFERENCES])
    assert result.returncode == 0, result.stderr
    assert "accepted 9 reviewed HIGH source backport finding(s)" in result.stdout


@pytest.mark.parametrize("cve", GAP_CVES)
@pytest.mark.parametrize(("field", "value"), [
    ("name", "unrelated/openssl"),
    ("version", "3.5.8"),
    ("version", "3.5.9+unreviewed"),
    ("epoch", 1),
    ("epoch", "0"),
    ("epoch", 0.0),
    ("epoch", -0.0),
    ("epoch", None),
    ("release", "unreviewed"),
    ("release", None),
    ("arch", "ARM64"),
    ("arch", None),
    ("version", None),
    ("version", ["3.5.9"]),
    ("packageManager", "OS"),
    ("fixedInVersion", "3.5.11"),
    ("filePath", PATHS[0] + ".changed"),
    ("remediation", "Changed remediation"),
])
def test_changed_package_signature_rejected(tmp_path, cve, field, value):
    finding = current_finding(cve)
    packages = finding["packageVulnerabilityDetails"]["vulnerablePackages"]
    packages[0][field] = value
    result = run_checker(tmp_path, [finding])
    assert result.returncode != 0
    assert "scan found HIGH finding sanitized-finding" in result.stderr
    assert "Traceback" not in result.stderr


@pytest.mark.parametrize("cve", REFERENCES)
@pytest.mark.parametrize("epoch", [False, True])
def test_boolean_epoch_cannot_match_reviewed_integer(tmp_path, cve, epoch):
    finding = current_finding(cve)
    finding["packageVulnerabilityDetails"]["vulnerablePackages"][0]["epoch"] = epoch
    result = run_checker(tmp_path, [finding])
    assert result.returncode != 0
    assert "scan found HIGH finding sanitized-finding" in result.stderr


@pytest.mark.parametrize("cve", GAP_CVES)
@pytest.mark.parametrize("field", ["epoch", "remediation"])
def test_partial_metadata_not_normalized(tmp_path, cve, field):
    finding = current_finding(cve)
    for package in finding["packageVulnerabilityDetails"]["vulnerablePackages"]:
        del package[field]
    result = run_checker(tmp_path, [finding])
    assert result.returncode != 0
    assert "scan found HIGH finding sanitized-finding" in result.stderr


@pytest.mark.parametrize("cve", REFERENCES)
@pytest.mark.parametrize("mutation", [
    "critical", "unknown-cve", "missing-reference", "os-only", "mixed-new-os",
    "missing-path", "duplicate-path", "unrelated-finding",
])
def test_real_or_incomplete_findings_rejected(tmp_path, cve, mutation):
    finding = current_finding(cve)
    details = finding["packageVulnerabilityDetails"]
    severity = "HIGH"
    items = [finding]
    if mutation == "critical":
        finding["severity"] = severity = "CRITICAL"
    elif mutation == "unknown-cve":
        details["vulnerabilityId"] = "CVE-2099-99999"
    elif mutation == "missing-reference":
        details["referenceUrls"] = ["https://nvd.nist.gov/vuln/detail/" + cve]
    elif mutation == "os-only":
        details["vulnerablePackages"] = [os_package()]
    elif mutation == "mixed-new-os":
        details["vulnerablePackages"].append(os_package())
    elif mutation == "missing-path":
        details["vulnerablePackages"].pop()
    elif mutation == "duplicate-path":
        details["vulnerablePackages"].append(
            copy.deepcopy(details["vulnerablePackages"][0])
        )
    elif mutation == "unrelated-finding":
        unrelated = copy.deepcopy(finding)
        unrelated["packageVulnerabilityDetails"]["vulnerabilityId"] = "CVE-2099-99999"
        items.append(unrelated)
    result = run_checker(tmp_path, items)
    assert result.returncode != 0
    assert f"scan found {severity} finding sanitized-finding" in result.stderr


@pytest.mark.parametrize("cve", REFERENCES)
def test_missing_patch_rejected(tmp_path, cve):
    result = run_checker(tmp_path, [current_finding(cve)], patches=[])
    assert result.returncode != 0
    assert "scan found HIGH finding sanitized-finding" in result.stderr


@pytest.mark.parametrize("cve", GAP_CVES)
def test_mismatched_patch_rejected(tmp_path, cve):
    patch = tmp_path / "changed.patch"
    original = BUILD / "patches" / f"openssl-{cve.lower()}.patch"
    patch.write_bytes(original.read_bytes() + b"\nchanged\n")
    result = run_checker(tmp_path, [current_finding(cve)], patches=[patch])
    assert result.returncode != 0
    assert "backport patch checksum does not match a reviewed upstream patch" in result.stderr


@pytest.mark.parametrize("cve", GAP_CVES)
def test_historical_exact_inventory_still_accepted(tmp_path, cve):
    finding = current_finding(cve)
    packages = finding["packageVulnerabilityDetails"]["vulnerablePackages"]
    if cve == "CVE-2026-95692":
        for package in packages:
            del package["epoch"]
            del package["remediation"]
    else:
        packages.insert(0, os_package("1~deb13u1+oce1"))
    result = run_checker(tmp_path, [finding])
    assert result.returncode == 0, result.stderr
