"""Exercise the actual dependency guards with accepted and rejected inputs."""

import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

BUILD = Path(__file__).resolve().parents[1] / "build"
PINS = {
    "git": ("2.56.1", "1:2.56.1-1+oce1",
            "f0b0bf89264b9bd2e1c640363e7529643989da76281600473c50745cd34a607f"),  # pragma: allowlist secret -- published Git archive checksum
    "expat": ("2.11.0", "2.11.0-1+oce1",
              "61e7614b602201c28a189dafee78f5bceaee192bbde46a930752ff09cf5542fa"),  # pragma: allowlist secret -- published Expat archive checksum
}


@pytest.fixture(autouse=True)
def portable_checksum_tool(tmp_path, monkeypatch):
    """Use real SHA-256 on macOS, whose sha256sum lacks GNU's option names."""
    if sys.platform == "darwin":
        tool = tmp_path / "checksum-bin"
        tool.mkdir()
        script = tool / "sha256sum"
        script.write_text('#!/bin/sh\nexec shasum -a 256 "$@"\n')
        script.chmod(0o755)
        monkeypatch.setenv("PATH", f"{tool}:{os.environ['PATH']}")


def run(script, *args, env=None):
    return subprocess.run(
        ["sh", str(script), *map(str, args)], capture_output=True, text=True,
        env=env, check=False,
    )


@pytest.mark.parametrize("name", PINS)
def test_exact_release_metadata_accepted(name):
    assets = BUILD / name
    metadata = json.loads((assets / "source.json").read_text())
    version, package, checksum = PINS[name]
    assert metadata["version"] == version
    assert metadata["packageVersion"] == package
    assert metadata["sources"][0]["sha256"] == checksum
    result = run(assets / "build.sh", "--check-metadata")
    assert result.returncode == 0, result.stderr
    assert hashlib.sha256((assets / "source.json").read_bytes()).hexdigest() in (
        assets / "build.sh"
    ).read_text()


@pytest.mark.parametrize("name", PINS)
@pytest.mark.parametrize("field,value", [
    ("version", "0.0.0"), ("packageVersion", "99.0.0-1"),
    ("sources", [{"url": "https://example.com/unreviewed.tar.xz", "sha256": "0" * 64}]),
])
def test_metadata_drift_rejected_before_download(tmp_path, name, field, value):
    assets = tmp_path / name
    shutil.copytree(BUILD / name, assets)
    manifest = assets / "source.json"
    metadata = json.loads(manifest.read_text())
    metadata[field] = value
    manifest.write_text(json.dumps(metadata))
    result = run(assets / "build.sh", "--check-metadata")
    assert result.returncode != 0
    assert "source.json" in result.stdout + result.stderr


@pytest.mark.parametrize("name", PINS)
def test_wrong_archive_rejected_before_unpack_or_package_install(tmp_path, name):
    archive = tmp_path / "bad.tar.xz"
    archive.write_bytes(b"an archive with the wrong source")
    result = run(BUILD / name / "build.sh", "--check-source", archive)
    assert result.returncode != 0
    assert "FAILED" in result.stdout + result.stderr


@pytest.mark.parametrize("name", PINS)
def test_unknown_build_mode_rejected(name):
    result = run(BUILD / name / "build.sh", "--unreviewed")
    assert result.returncode != 0
    assert "usage:" in result.stderr.lower()


@pytest.mark.parametrize("name", PINS)
@pytest.mark.parametrize("bad", [
    None, "package-name", "package-version", "architecture", "bytes",
    "missing-package", "missing-checksum", "missing-checksum-entry",
    "duplicate-checksum-entry", "unexpected-package", "unexpected-deb",
])
def test_package_guard_accepts_exact_artifacts_rejects_drift(tmp_path, name, bad):
    """Run verify.sh itself; stub only the unavailable macOS dpkg-deb binary."""
    metadata = json.loads((BUILD / name / "source.json").read_text())
    version = metadata["packageVersion"]
    output = tmp_path / "out"
    output.mkdir()
    def filename(package):
        file_version = metadata.get("packageFileVersion", version)
        return f"{package}_{file_version}_{'all' if package == 'git-man' else 'amd64'}.deb"

    runtime_debs = [filename(p) for p in metadata["runtimePackages"]]
    build_debs = [filename(p) for p in metadata.get("buildPackages", [])]
    debs = runtime_debs + build_debs
    (output / "runtime-packages.list").write_text("\n".join(runtime_debs) + "\n")
    if build_debs:
        (output / "build-packages.list").write_text("\n".join(build_debs) + "\n")
    for deb in debs:
        (output / deb).write_bytes(b"reviewed package fixture")
    (output / "packages.sha256").write_text("".join(
        f"{hashlib.sha256((output / p).read_bytes()).hexdigest()}  {p}\n" for p in debs
    ))
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    query = bin_dir / "dpkg"
    query.write_text(
        "#!/bin/sh\ntest \"$#\" = 1 && test \"$1\" = --print-architecture || exit 99\n"
        "printf '%s\\n' amd64\n"
    )
    query.chmod(0o755)
    query = bin_dir / "dpkg-deb"
    legacy_version = "1:2.47.3-0+deb13u1" if name == "git" else "2.9.0-1"
    query.write_text(
        "#!/bin/sh\n"
        'test "$#" = 3 && test "$1" = --field || exit 99\n'
        'file=${2##*/}; package=${file%%_*}\n'
        'case "$3" in\nPackage) '
        + ('echo unreviewed' if bad == "package-name" else 'echo "$package"')
        + ";;\n"
        f"Version) echo '{legacy_version if bad == 'package-version' else version}';;\n"
        "Architecture) "
        + ("echo arm64" if bad == "architecture" else
           'if [ "$package" = git-man ]; then echo all; else echo amd64; fi')
        + ";;\n"
        "*) exit 2;;\nesac\n"
    )
    query.chmod(0o755)
    if bad == "bytes":
        (output / debs[0]).write_bytes(b"tampered")
    elif bad == "missing-package":
        (output / debs[0]).unlink()
    elif bad == "missing-checksum":
        (output / "packages.sha256").write_text("")
    elif bad == "missing-checksum-entry":
        lines = (output / "packages.sha256").read_text().splitlines()
        (output / "packages.sha256").write_text("\n".join(lines[1:]) + "\n")
    elif bad == "duplicate-checksum-entry":
        manifest = output / "packages.sha256"
        manifest.write_text(manifest.read_text() + manifest.read_text().splitlines()[0] + "\n")
    elif bad == "unexpected-package":
        (output / "runtime-packages.list").write_text(
            (output / "runtime-packages.list").read_text() + "unreviewed.deb\n"
        )
    elif bad == "unexpected-deb":
        (output / "unreviewed.deb").write_bytes(b"not in the manifests")
    result = run(
        BUILD / name / "verify.sh", "--packages", output,
        env={**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"},
    )
    assert (result.returncode == 0) == (bad is None), result.stdout + result.stderr


def test_minimal_git_retains_transports_and_expat_retains_system_abi():
    git_build = (BUILD / "git/build.sh").read_text()
    assert "NO_EXPAT=YesPlease" in git_build
    assert "NO_TCLTK=YesPlease" in git_build
    assert "NO_RUST=YesPlease" in git_build
    assert "NO_CURL" not in git_build
    assert "dpkg-shlibdeps" in git_build
    expat_build = (BUILD / "expat/build.sh").read_text()
    assert "--libdir=/usr/lib/" in expat_build
    assert "--enable-shared" in expat_build
    assert "--disable-static" in expat_build
    for name in PINS:
        script = (BUILD / name / "build.sh").read_text()
        assert "dpkg-deb --root-owner-group --build" in script
        assert "/var/lib/dpkg" not in script
        assert "--strip" not in script
    expat_verify = (BUILD / "expat/verify.sh").read_text()
    assert "pyexpat" in expat_verify
    assert "ExternalEntityParserCreate" in expat_verify
    assert "libexpat.so.1" in expat_verify
