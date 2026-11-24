"""Exercise reviewed OpenSSL patch, source and regression recipe guards."""

from __future__ import annotations

import hashlib
import json
import pathlib
import shutil
import subprocess
import sys

import pytest

BUILD = pathlib.Path(__file__).resolve().parents[1] / "build"
ASSETS = BUILD / "openssl"
GUARD = ASSETS / "security_assets.py"
CVES = (
    "CVE-2026-95691",
    "CVE-2026-107493",
    "CVE-2026-124709",
    "CVE-2026-121482",
    "CVE-2026-107494",
    "CVE-2026-84786",
)


def run_guard(command, assets, source=None):
    arguments = [
        sys.executable, str(GUARD), command, "--assets", str(assets),
    ]
    if source is not None:
        arguments.extend(["--source", str(source)])
    return subprocess.run(arguments, capture_output=True, text=True, check=False)


@pytest.fixture
def staged_assets(tmp_path):
    destination = tmp_path / "assets"
    shutil.copytree(ASSETS, destination)
    metadata = json.loads((destination / "source.json").read_text())
    for original, staged in (
        ("openssl-cve-2026-88823.patch", "CVE-2026-88823.patch"),
        ("openssl-cve-2026-88823-test.patch", "CVE-2026-88823-test.patch"),
        ("openssl-cve-2026-107496.patch", "CVE-2026-107496.patch"),
    ):
        shutil.copyfile(BUILD / "patches" / original, destination / staged)
    for patch in metadata["additionalBackports"]:
        shutil.copyfile(
            BUILD / "patches" / patch["repoPatchFile"],
            destination / patch["patchFile"],
        )
    return destination


def test_reviewed_series_and_original_upstream_bytes(staged_assets):
    metadata = json.loads((staged_assets / "source.json").read_text())
    assert metadata["packageVersion"] == "3.5.9-1~deb13u1+oce3"
    assert tuple(p["cve"] for p in metadata["additionalBackports"]) == CVES
    assert all(p["branch"] == "openssl-3.5" for p in metadata["additionalBackports"])
    result = subprocess.run(
        ["sh", str(ASSETS / "build.sh"), "--check-assets", str(staged_assets)],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode == 0, result.stderr
    result = run_guard("patch-files", staged_assets)
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == [
        "CVE-2026-88823.patch",
        "CVE-2026-88823-test.patch",
        "CVE-2026-107496.patch",
        "CVE-2026-95692.patch",
        *(f"{cve}.patch" for cve in CVES),
        "CVE-2026-124709-test.patch",
    ]


def test_debian_nonce_fix_uses_exact_existing_node_patch(staged_assets):
    metadata = json.loads((staged_assets / "source.json").read_text())
    entry, = metadata["debianOnlyBackports"]
    assert entry["cve"] == "CVE-2026-95692"
    assert (staged_assets / entry["patchFile"]).read_bytes() == (
        BUILD / "patches" / entry["repoPatchFile"]
    ).read_bytes()
    for name, expected in metadata["patchedSourceAnchors"].items():
        assert metadata["debianPatchedSourceAnchors"][name] == expected
    patch = staged_assets / entry["patchFile"]
    patch.write_bytes(patch.read_bytes() + b"\nunreviewed\n")
    result = run_guard("check-assets", staged_assets)
    assert result.returncode != 0
    assert "patch checksum mismatch: CVE-2026-95692.patch" in result.stderr


def test_nonce_regression_asset_is_pinned(staged_assets):
    regression = staged_assets / "iv_length_regression.c"
    regression.write_bytes(regression.read_bytes() + b"\nunreviewed\n")
    result = run_guard("check-assets", staged_assets)
    assert result.returncode != 0
    assert "regression checksum mismatch" in result.stderr


@pytest.mark.parametrize("cve", CVES)
def test_modified_or_missing_patch_rejected_before_build(staged_assets, cve):
    patch = staged_assets / f"{cve}.patch"
    patch.write_bytes(patch.read_bytes() + b"\nUnreviewed change\n")
    result = subprocess.run(
        ["sh", str(ASSETS / "build.sh"), "--check-assets", str(staged_assets)],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode != 0
    assert f"patch checksum mismatch: {cve}.patch" in result.stderr
    patch.unlink()
    result = run_guard("check-assets", staged_assets)
    assert result.returncode != 0
    assert f"{cve}.patch" in result.stderr


def test_metadata_drift_rejected_before_build(staged_assets):
    manifest = staged_assets / "source.json"
    metadata = json.loads(manifest.read_text())
    metadata["packageVersion"] = "3.5.10-1"
    manifest.write_text(json.dumps(metadata))
    result = subprocess.run(
        ["sh", str(ASSETS / "build.sh"), "--check-assets", str(staged_assets)],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode != 0
    assert "source.json checksum mismatch" in result.stderr


def test_node_scope_cannot_drop_required_internal_header(staged_assets):
    manifest = staged_assets / "source.json"
    metadata = json.loads(manifest.read_text())
    patch = next(
        p for p in metadata["additionalBackports"] if p["cve"] == "CVE-2026-95691"
    )
    patch["nodeFiles"].remove("include/internal/quic_strm_reas.h")
    manifest.write_text(json.dumps(metadata))
    result = run_guard("check-assets", staged_assets)
    assert result.returncode != 0
    assert "Node production patch scope mismatch" in result.stderr


def test_patch_commit_identity_is_checked(staged_assets):
    manifest = staged_assets / "source.json"
    metadata = json.loads(manifest.read_text())
    metadata["additionalBackports"][0]["commit"] = "0" * 40
    manifest.write_text(json.dumps(metadata))
    result = run_guard("check-assets", staged_assets)
    assert result.returncode != 0
    assert "patch source commit mismatch" in result.stderr


@pytest.mark.parametrize("cve", CVES)
def test_noop_anchor_receipt_is_rejected(staged_assets, cve):
    manifest = staged_assets / "source.json"
    metadata = json.loads(manifest.read_text())
    patch = next(p for p in metadata["additionalBackports"] if p["cve"] == cve)
    patch["patchedSourceAnchors"] = dict(patch["sourceAnchors"])
    manifest.write_text(json.dumps(metadata))
    result = run_guard("check-assets", staged_assets)
    assert result.returncode != 0
    assert f"no-op before/after source anchors: {cve}.patch" in result.stderr


def test_parent_git_successful_skip_cannot_pass_patched_source_guard(tmp_path):
    """Reproduce git apply's zero-exit skip inside a parent repository."""
    parent = tmp_path / "parent"
    source = parent / "scratch/source"
    source.mkdir(parents=True)
    subprocess.run(["git", "init", "--quiet", str(parent)], check=True)
    original = b"original source\n"
    repaired = b"repaired source\n"
    path = source / "crypto.c"
    path.write_bytes(original)
    patch = tmp_path / "repair.patch"
    patch.write_text(
        "diff --git a/crypto.c b/crypto.c\n"
        "--- a/crypto.c\n"
        "+++ b/crypto.c\n"
        "@@ -1 +1 @@\n"
        "-original source\n"
        "+repaired source\n"
    )
    result = subprocess.run(
        ["git", "apply", str(patch)], cwd=source,
        capture_output=True, text=True, check=False,
    )
    assert result.returncode == 0
    assert path.read_bytes() == original
    metadata = {
        "patchedSourceAnchors": {
            "crypto.c": hashlib.sha256(repaired).hexdigest(),
        },
        "testRecipes": [],
    }
    (tmp_path / "source.json").write_text(json.dumps(metadata))
    result = run_guard("check-patched-source", tmp_path, source)
    assert result.returncode != 0
    assert "OpenSSL source anchor mismatch: crypto.c" in result.stderr


@pytest.mark.parametrize("command,key", [
    ("check-source", "sourceAnchors"),
    ("check-patched-source", "patchedSourceAnchors"),
])
def test_source_guard_accepts_expected_bytes_rejects_drift(tmp_path, command, key):
    source = tmp_path / "source"
    source.mkdir()
    path = source / "crypto.c"
    path.write_bytes(b"reviewed source bytes\n")
    metadata = {
        key: {"crypto.c": hashlib.sha256(path.read_bytes()).hexdigest()},
        "testRecipes": [],
    }
    (tmp_path / "source.json").write_text(json.dumps(metadata))
    result = run_guard(command, tmp_path, source)
    assert result.returncode == 0, result.stderr
    path.write_bytes(b"unexpected source bytes\n")
    result = run_guard(command, tmp_path, source)
    assert result.returncode != 0
    assert "OpenSSL source anchor mismatch: crypto.c" in result.stderr


def test_missing_regression_recipe_cannot_pass_source_verification(tmp_path):
    source = tmp_path / "source"
    (source / "test/recipes").mkdir(parents=True)
    metadata = {"patchedSourceAnchors": {}, "testRecipes": ["test_quicapi"]}
    (tmp_path / "source.json").write_text(json.dumps(metadata))
    result = run_guard("check-patched-source", tmp_path, source)
    assert result.returncode != 0
    assert "missing or ambiguous test recipe: test_quicapi" in result.stderr
    (source / "test/recipes/75-test_quicapi.t").write_text("reviewed recipe\n")
    result = run_guard("check-patched-source", tmp_path, source)
    assert result.returncode == 0, result.stderr


def test_unknown_build_mode_is_rejected():
    result = subprocess.run(
        ["sh", str(ASSETS / "build.sh"), "--unreviewed"],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode == 2
    assert "usage:" in result.stderr
