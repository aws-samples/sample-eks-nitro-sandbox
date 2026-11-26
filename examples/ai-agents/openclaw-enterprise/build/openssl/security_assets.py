#!/usr/bin/env python3
"""Validate reviewed OpenSSL inputs and emit the ordered Debian patch series."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def patch_entries(metadata: dict) -> list[dict]:
    return [
        {
            "patchFile": "CVE-2026-88823.patch",
            "patchSha256": metadata["fixPatchSha256"],
            "commit": metadata["upstreamFixCommit"],
        },
        {
            "patchFile": "CVE-2026-88823-test.patch",
            "patchSha256": metadata["testPatchSha256"],
            "commit": metadata["upstreamTestCommit"],
        },
        {
            "patchFile": "CVE-2026-107496.patch",
            "patchSha256": metadata["ecOrderPatchSha256"],
            "commit": metadata["ecOrderFixCommit"],
        },
        *metadata["debianOnlyBackports"],
        *metadata["additionalBackports"],
        *metadata["regressionPatches"],
    ]


def check_assets(assets: Path, metadata: dict) -> None:
    entries = patch_entries(metadata)
    names = [entry["patchFile"] for entry in entries]
    if len(names) != len(set(names)):
        raise ValueError("duplicate patch in reviewed series")
    for entry in entries:
        name = entry["patchFile"]
        if Path(name).name != name or not name.endswith(".patch"):
            raise ValueError(f"invalid patch asset name: {name}")
        path = assets / name
        if path.is_symlink() or digest(path) != entry["patchSha256"]:
            raise ValueError(f"patch checksum mismatch: {name}")
        text = path.read_text()
        if not text.startswith(f"From {entry['commit']} "):
            raise ValueError(f"patch source commit mismatch: {name}")
        if "cve" in entry and entry["cve"] not in text:
            raise ValueError(f"patch CVE reference missing: {name}")
        if "sourceAnchors" in entry:
            before = entry["sourceAnchors"]
            after = entry["patchedSourceAnchors"]
            if not before or set(before) != set(after):
                raise ValueError(f"incomplete before/after source anchors: {name}")
            if any(before[path] == after[path] for path in before):
                raise ValueError(f"no-op before/after source anchors: {name}")
        if "nodeFiles" in entry:
            paths = set(re.findall(r"^\+\+\+ b/(.+)$", text, re.MULTILINE))
            expected = set(entry["sourceAnchors"])
            if paths != expected:
                raise ValueError(f"patch scope mismatch: {name}")
            if set(entry["nodeFiles"]) != {
                path for path in paths if not path.startswith("test/")
            }:
                raise ValueError(f"Node production patch scope mismatch: {name}")
    for entry in metadata["localRegressionTests"]:
        name = entry["file"]
        if Path(name).name != name:
            raise ValueError(f"invalid regression asset name: {name}")
        path = assets / name
        if path.is_symlink() or digest(path) != entry["sha256"]:
            raise ValueError(f"regression checksum mismatch: {name}")


def check_source(source: Path, anchors: dict[str, str]) -> None:
    for name, expected in anchors.items():
        path = source / name
        if path.is_symlink() or digest(path) != expected:
            raise ValueError(f"OpenSSL source anchor mismatch: {name}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=(
            "check-assets",
            "check-source",
            "check-patched-source",
            "patch-files",
            "test-recipes",
        ),
    )
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--expected-metadata-sha256")
    args = parser.parse_args()
    try:
        manifest = args.assets / "source.json"
        if manifest.is_symlink() or (
            args.expected_metadata_sha256
            and digest(manifest) != args.expected_metadata_sha256
        ):
            raise ValueError("source.json checksum mismatch")
        metadata = json.loads(manifest.read_text())
        if args.command == "check-assets":
            check_assets(args.assets, metadata)
        elif args.command in ("check-source", "check-patched-source"):
            if args.source is None:
                raise ValueError("--source is required")
            key = (
                "sourceAnchors"
                if args.command == "check-source"
                else (
                    "debianPatchedSourceAnchors"
                    if "debianPatchedSourceAnchors" in metadata
                    else "patchedSourceAnchors"
                )
            )
            check_source(args.source, metadata[key])
            if args.command == "check-patched-source":
                for recipe in metadata["testRecipes"]:
                    matches = list(
                        (args.source / "test/recipes").glob(f"*-{recipe}.t")
                    )
                    if len(matches) != 1:
                        raise ValueError(f"missing or ambiguous test recipe: {recipe}")
        elif args.command == "patch-files":
            for entry in patch_entries(metadata):
                print(entry["patchFile"])
        elif args.command == "test-recipes":
            print(" ".join(metadata["testRecipes"]))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"OpenSSL security asset validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
