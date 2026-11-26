#!/usr/bin/env python3
"""Require identical compiled inputs before reusing ancestor-built images."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

SAMPLE = "examples/ai-agents/openclaw-enterprise/"
# These files orchestrate or check builds; they are not copied into images.
EXCLUDED_BUILD_FILES = {
    "build-images.sh",
    "check-inspector-scan.py",
    "check-image-scan.py",
    "check-enhanced-scanning.py",
    "check-oce-lock.py",
    "template.yaml",
}


def git(repo: Path, *arguments: str) -> bytes:
    return subprocess.check_output(
        ["git", "-C", str(repo), *arguments], stderr=subprocess.PIPE
    )


def compiled_inputs(repo: Path, revision: str) -> list[bytes]:
    records = git(
        repo, "ls-tree", "-r", "-z", "--full-tree", revision, "--",
        SAMPLE + "adapter", SAMPLE + "ownership-helper", SAMPLE + "build",
    )
    result = []
    for record in records.split(b"\0"):
        if not record:
            continue
        path = record.split(b"\t", 1)[1].decode()
        relative = path.removeprefix(SAMPLE)
        if relative.startswith("build/") and relative[6:] in EXCLUDED_BUILD_FILES:
            continue
        result.append(record)
    if not result:
        raise ValueError("compiled image inputs are missing")
    return sorted(result)


def validate(repo: Path, source: str, candidate: str) -> str:
    for revision in (source, candidate):
        if re.fullmatch(r"[0-9a-f]{40}", revision) is None:
            raise ValueError("image and candidate revisions must be full lowercase commit SHAs")
        git(repo, "cat-file", "-e", revision + "^{commit}")
    if git(repo, "rev-parse", "--verify", "HEAD^{commit}").decode().strip() != candidate:
        raise ValueError("candidate revision must match the checkout HEAD")
    git(repo, "merge-base", "--is-ancestor", source, candidate)
    if compiled_inputs(repo, source) != compiled_inputs(repo, candidate):
        raise ValueError("compiled image inputs differ; rebuild and scan the candidate images")
    return source


def main() -> int:
    if len(sys.argv) != 4:
        print("Usage: check-image-source-revision.py REPO IMAGE_SOURCE CANDIDATE", file=sys.stderr)
        return 2
    try:
        print(validate(Path(sys.argv[1]), sys.argv[2], sys.argv[3]))
    except (ValueError, subprocess.CalledProcessError, OSError) as error:
        detail = str(error) if isinstance(error, ValueError) else "Git source verification failed"
        print(detail, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
