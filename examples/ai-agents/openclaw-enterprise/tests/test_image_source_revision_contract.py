"""Verify image source reuse against real Git commit trees."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

HELPER = (
    Path(__file__).resolve().parent.parent
    / "scripts" / "lib" / "check-image-source-revision.py"
)
SAMPLE = "examples/ai-agents/openclaw-enterprise/"


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        [
            "git", "-C", str(repo), "-c", "core.hooksPath=/dev/null",
            "-c", "commit.gpgsign=false", *args,
        ],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


def _write(repo: Path, relative: str, content: str = "changed\n") -> Path:
    path = repo / SAMPLE / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    return path


def _commit(repo: Path) -> str:
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "contract fixture")
    return _git(repo, "rev-parse", "HEAD")


@pytest.fixture
def history(tmp_path: Path) -> tuple[Path, str]:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "--initial-branch=main")
    _git(repo, "config", "user.name", "Contract Test")
    _git(repo, "config", "user.email", "contract@example.invalid")
    _git(repo, "config", "core.filemode", "true")
    for path in (
        "adapter/adapter.py", "ownership-helper/main.go",
        "build/controller-runtime.Dockerfile", "build/apply-oce-security-patches.py",
        "build/patches/runtime.patch", "build/git/build.sh",
    ):
        _write(repo, path, "original\n")
    return repo, _commit(repo)


def _check(repo: Path, source: str, candidate: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(HELPER), str(repo), source, candidate],
        capture_output=True, text=True, check=False, timeout=10,
    )


def _assert_rejected(result: subprocess.CompletedProcess[str], diagnostic: str) -> None:
    assert result.returncode == 1
    assert result.stdout == ""
    assert diagnostic in result.stderr


def test_exact_head_image_source_is_accepted(history: tuple[Path, str]) -> None:
    repo, head = history
    result = _check(repo, head, head)
    assert result.returncode == 0, result.stderr
    assert result.stdout == f"{head}\n"
    assert result.stderr == ""


@pytest.mark.parametrize(
    "path",
    [
        "README.md", "tests/test_cleanup_contract.py", "docs/evidence.md",
        "deploy/namespace.yaml", "scripts/cleanup.sh", "scripts/validate-live.sh",
        "scripts/lib/check-image-source-revision.py",
        "build/build-images.sh", "build/check-inspector-scan.py",
        "build/check-image-scan.py", "build/check-enhanced-scanning.py",
        "build/check-oce-lock.py", "build/template.yaml",
    ],
)
def test_ancestor_image_source_allows_noncompiled_changes(
    history: tuple[Path, str], path: str,
) -> None:
    repo, source = history
    _write(repo, path)
    candidate = _commit(repo)
    result = _check(repo, source, candidate)
    assert result.returncode == 0, result.stderr
    assert result.stdout == f"{source}\n"
    assert result.stderr == ""


@pytest.mark.parametrize(
    "path",
    [
        "adapter/adapter.py", "ownership-helper/main.go",
        "build/controller-runtime.Dockerfile", "build/apply-oce-security-patches.py",
        "build/patches/runtime.patch", "build/git/build.sh",
        "build/new-compiled-input.sh", "adapter/new-module.py",
        "ownership-helper/new-controller.go", "build/nested/check-image-scan.py",
        "build/template.yaml.extra",
    ],
)
def test_compiled_changes_require_rebuilding_images(
    history: tuple[Path, str], path: str,
) -> None:
    repo, source = history
    _write(repo, path)
    _assert_rejected(
        _check(repo, source, _commit(repo)), "compiled image inputs differ",
    )


@pytest.mark.parametrize("change", ["delete", "executable-mode", "symlink-type"])
def test_compiled_tree_identity_includes_paths_modes_and_types(
    history: tuple[Path, str], change: str,
) -> None:
    repo, source = history
    path = repo / SAMPLE / "build/git/build.sh"
    if change == "delete":
        path.unlink()
    elif change == "executable-mode":
        path.chmod(0o755)
    else:
        path.unlink()
        # Same blob bytes, different Git mode: content-only comparison is unsafe.
        os.symlink("original\n", path)
    _assert_rejected(
        _check(repo, source, _commit(repo)), "compiled image inputs differ",
    )


@pytest.mark.parametrize("argument", ["source", "candidate"])
@pytest.mark.parametrize("revision", ["HEAD", "a" * 39, "A" * 40, "g" * 40])
def test_revisions_must_be_full_lowercase_commit_shas(
    history: tuple[Path, str], argument: str, revision: str,
) -> None:
    repo, head = history
    source, candidate = (revision, head) if argument == "source" else (head, revision)
    _assert_rejected(_check(repo, source, candidate), "full lowercase commit SHAs")


@pytest.mark.parametrize("argument", ["source", "candidate"])
@pytest.mark.parametrize("kind", ["missing", "blob"])
def test_revisions_must_resolve_to_existing_commits(
    history: tuple[Path, str], argument: str, kind: str,
) -> None:
    repo, head = history
    revision = (
        "0" * 40 if kind == "missing"
        else _git(repo, "rev-parse", f"{head}:{SAMPLE}adapter/adapter.py")
    )
    source, candidate = (revision, head) if argument == "source" else (head, revision)
    _assert_rejected(_check(repo, source, candidate), "Git source verification failed")


def test_candidate_must_be_checkout_head(history: tuple[Path, str]) -> None:
    repo, source = history
    _write(repo, "README.md")
    _commit(repo)
    _assert_rejected(
        _check(repo, source, source), "candidate revision must match the checkout HEAD",
    )


def test_nonancestor_source_is_rejected_even_with_identical_inputs(
    history: tuple[Path, str],
) -> None:
    repo, base = history
    _git(repo, "checkout", "-qb", "unrelated")
    _write(repo, "README.md", "source branch\n")
    source = _commit(repo)
    _git(repo, "checkout", "-q", "main")
    assert _git(repo, "rev-parse", "HEAD") == base
    _write(repo, "README.md", "candidate branch\n")
    candidate = _commit(repo)
    _assert_rejected(_check(repo, source, candidate), "Git source verification failed")


def test_empty_compiled_catalog_fails_closed(tmp_path: Path) -> None:
    repo = tmp_path / "empty-repo"
    repo.mkdir()
    _git(repo, "init", "-q", "--initial-branch=main")
    _git(repo, "config", "user.name", "Contract Test")
    _git(repo, "config", "user.email", "contract@example.invalid")
    _write(repo, "build/template.yaml")
    head = _commit(repo)
    _assert_rejected(_check(repo, head, head), "compiled image inputs are missing")
