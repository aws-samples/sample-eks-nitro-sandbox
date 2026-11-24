#!/usr/bin/env python3
"""Apply reviewed security backports to the exact pinned OCE source tree."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any

OPENSSL_PATCH_FILE_NAME = "openssl-cve-2026-95692.patch"
OPENSSL_PATCH_SHA256 = "ab26acb8f611cd6d07e9d9e30af45ed58e316b6011cb08847bb99fa5ff67f94c"  # pragma: allowlist secret -- public patch checksum
OPENSSL_CVE_PATCH_FILE_NAME = "openssl-cve-2026-88823.patch"
OPENSSL_CVE_PATCH_DESTINATION_FILE_NAME = "CVE-2026-88823.patch"
OPENSSL_CVE_PATCH_SHA256 = "a945077c0a978dbfe5af5e4f7174a2151466547f8fb94562f395baa7b6b7c147"  # pragma: allowlist secret -- public patch checksum
OPENSSL_CVE_TEST_PATCH_FILE_NAME = "openssl-cve-2026-88823-test.patch"
OPENSSL_CVE_TEST_PATCH_DESTINATION_FILE_NAME = "CVE-2026-88823-test.patch"
OPENSSL_CVE_TEST_PATCH_SHA256 = "c7885d44f2659d97c0fc71fcdc8a6ef04cbe2ccdd36a72c28e7dfd1452033f2d"  # pragma: allowlist secret -- public patch checksum
OPENSSL_EC_ORDER_PATCH_FILE_NAME = "openssl-cve-2026-107496.patch"
OPENSSL_EC_ORDER_PATCH_DESTINATION_FILE_NAME = "CVE-2026-107496.patch"
OPENSSL_EC_ORDER_PATCH_SHA256 = "77d3759d279c71af59629c4a0fa82d8272a099762f2fa9e3f66d7ca5ed544157"  # pragma: allowlist secret -- public patch checksum
OPENSSL_EC_ORDER_UPSTREAM_COMMIT = "a0051cfe699bf5a047bc1c4faef65f80f7987366"  # pragma: allowlist secret -- public source revision
OPENSSL_SOURCE_METADATA_SHA256 = "267f1dd8cf4d58f4e9bda194c1d88f870367d5d525d4a79ba4a1a2d033a6d669"  # pragma: allowlist secret -- reviewed metadata checksum
OPENSSL_DEBIAN_VERSION = "3.5.9-1~deb13u1"
OPENSSL_PACKAGE_VERSION = f"{OPENSSL_DEBIAN_VERSION}+oce2"
OPENCLAW_PATCH_FILE_NAME = "openclaw-security-overrides.patch"
OPENCLAW_PATCH_SHA256 = "2b1fb478649494c0b74879bbed20c55155658575555ebe37a88050d372aef451"  # pragma: allowlist secret -- reviewed patch checksum
CURL_PATCH_FILE_NAME = "curl-cve-2026-86414-trixie.patch"
CURL_PATCH_DESTINATION_FILE_NAME = "CVE-2026-86414.patch"
CURL_PATCH_SHA256 = "cdd2c3db9c85552d0a2633e873fdab4f96f7ea996a4f6c87d3348a1b34bae824"  # pragma: allowlist secret -- reviewed patch checksum
NPM_RUNTIME_VERSION = "11.21.3"
NPM_RUNTIME_ARCHIVE_SHA256 = "ee5fc68e724c4bdba38db9d96d9c661d4e736e4be7001ae44d2fbbaa52159514"  # pragma: allowlist secret -- public archive checksum
NPM_RUNTIME_UNDICI_VERSION = "6.29.1"
RUNTIME_DEPENDENCY_METADATA_SHA256 = {
    "git": "b8f6f175739b1d77487cc88a0b1c127ebefe9f16070fc48f11d16e1a6e71d9cf",  # pragma: allowlist secret -- public source metadata checksum
    "expat": "bc9edc727635b4a9e9c08c49c687065f3f8d3565587cec3c171c7cb3e8b860e6",  # pragma: allowlist secret -- public source metadata checksum
}
GH_CLI_OLD_VERSION = "2.103.2"
GH_CLI_VERSION = "2.105.0"
GH_CLI_OLD_CHECKSUMS_SHA256 = "414d6009dc7f9f936d70831af818d1a32aa0ff07a77646861efd207356a36b2d"  # pragma: allowlist secret -- public checksum
GH_CLI_CHECKSUMS_SHA256 = "4597138ea96e474c68001370c0a4955ff4834ba603c53900de6ebbef4cb0bed9"  # pragma: allowlist secret -- public checksum
GOG_OLD_VERSION = "0.46.0"
GOG_VERSION = "0.48.1"
NODE_BASE_IMAGE_REPLACEMENTS = {
    "docker.io/library/node:24.22.1-bookworm@sha256:"
    "6449e19d8184d84062525b6a7524def03146c2cb04a7f08b076680d0e8e4240a": (  # pragma: allowlist secret -- public image digest
        "docker.io/library/node:24.22.1-trixie@sha256:"
        "f1e034976f948cf212ef1f659c12e5dd58ac7eab947831813e81a62401ca38be"  # pragma: allowlist secret -- public image digest
    ),
    "docker.io/library/node:24.22.1-bookworm-slim@sha256:"
    "55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205": (  # pragma: allowlist secret -- public image digest
        "docker.io/library/node:24.22.1-trixie-slim@sha256:"
        "89c5244bc22a9bc3287d89ebc7e49b9cb5bb84cd40e6175ac3421d5a9f68b95a"  # pragma: allowlist secret -- public image digest
    ),
}
GOG_RELEASE_REPLACEMENTS = {
    '"version": "0.46.0"': '"version": "0.48.1"',
    "https://github.com/openclaw/gogcli/releases/download/v0.46.0/"
    "gogcli_0.46.0_linux_amd64.tar.gz": (
        "https://github.com/openclaw/gogcli/releases/download/v0.48.1/"
        "gogcli_0.48.1_linux_amd64.tar.gz"
    ),
    "d53cf89f0c2a2338211212e380b3efcacadd4e27e500cb8e7ed2cd82a739da2e": (  # pragma: allowlist secret -- public checksum
        "dcd956e09d1222a07c1304d836f8acd55266b2fa241ef466580ced6a02453d72"  # pragma: allowlist secret -- public checksum
    ),
    "36551bb5725a7c7f22413826109ed455ce9de9a1aecaa81e918a5d461072787a": (  # pragma: allowlist secret -- public checksum
        "c943659544d425aee0c21b46b8f4c7939a4db2f12d5928dcf99f83ddecfb255f"  # pragma: allowlist secret -- public checksum
    ),
    "https://github.com/openclaw/gogcli/releases/download/v0.46.0/"
    "gogcli_0.46.0_linux_arm64.tar.gz": (
        "https://github.com/openclaw/gogcli/releases/download/v0.48.1/"
        "gogcli_0.48.1_linux_arm64.tar.gz"
    ),
    "9ae69d117cef895aa1c50b5859d7d3def45c5580886b25dc1c7f3cfe128ed0dd": (  # pragma: allowlist secret -- public checksum
        "c091fa2014dc3d5608acef4d09fb3bb4a3eb71e4cff898b5eaddd9703599e45c"  # pragma: allowlist secret -- public checksum
    ),
    "ad84f12b8efd889f65bd7c45c4eb6152fa963f623394fdf50938b14c57b9b694": (  # pragma: allowlist secret -- public checksum
        "520cbe587cea302d3e7770c43704856d8582ad888de344c8d1f7812997020a9c"  # pragma: allowlist secret -- public checksum
    ),
}
CURL_BUILD_REPLACEMENTS = {
    "# TODO: Remove this backport when Bookworm publishes a CVE-2026-86414 fix.": (
        "# TODO: Remove this backport when Trixie publishes a CVE-2026-86414 fix."
    ),
    "version=7.88.1-10+deb12u15": "version=8.14.1-2+deb13u7",
    (
        'for file in "curl_${version}.dsc" curl_7.88.1.orig.tar.gz '
        'curl_7.88.1.orig.tar.gz.asc "curl_${version}.debian.tar.xz"; do'
    ): (
        'for file in "curl_${version}.dsc" curl_8.14.1.orig.tar.gz '
        'curl_8.14.1.orig.tar.gz.asc "curl_${version}.debian.tar.xz"; do'
    ),
    (
        "2744f12e3aef161c0361743fa1b318296b122e566e47f381e4a63320fbcc23f4  "
        "curl_7.88.1-10+deb12u15.dsc\n"
        "cdb38b72e36bc5d33d5b8810f8018ece1baa29a8f215b4495e495ded82bbf3c7  "
        "curl_7.88.1.orig.tar.gz\n"
        "7a5a55d7123149a1b357f298cf895bd0a601e3a2807005ef6c95f3752803485f  "
        "curl_7.88.1.orig.tar.gz.asc\n"
        "961b78bc48492c5693e4decb352ddd176f343260a8956f48b2887874048ef23b  "
        "curl_7.88.1-10+deb12u15.debian.tar.xz"
    ): (
        "a559b829ff852b2ee1ac0e448b5d9c18e0f94875bc820d037609d4d807ac6f57  "
        "curl_8.14.1-2+deb13u7.dsc\n"
        "6766ada7101d292b42b8b15681120acd68effa4a9660935853cf6d61f0d984d4  "
        "curl_8.14.1.orig.tar.gz\n"
        "39cc2ec8ddc39d04e3e7101bbed46d858d0875cbb297a6bfa20959fa2bc7d5c7  "
        "curl_8.14.1.orig.tar.gz.asc\n"
        "e0f627ee2b9ae61078b2835edc25c8b94a0b57e180a1bc72dd8636ef260c370b  "
        "curl_8.14.1-2+deb13u7.debian.tar.xz"
    ),
    (
        "cd source\n"
        "export QUILT_PATCHES=debian/patches"
    ): (
        "cd source\n"
        "# Git needs HTTP(S), but OCE does not use curl's LDAP transports. Disable\n"
        "# them so the runtime does not inherit libldap and its Cyrus SASL plugins.\n"
        "printf '\\nCONFIGURE_ARGS += --disable-ldap --disable-ldaps\\n' "
        ">> debian/rules\n"
        "export QUILT_PATCHES=debian/patches"
    ),
    (
        "quilt pop -a\n"
        "cp /tmp/curl/CVE-2026-86414.patch debian/patches/\n"
        "# Debian copies the tree for each backend while applying its final two patches.\n"
        "# The security fix must precede both, so it reaches OpenSSL and GnuTLS alike.\n"
        "sed -i '/^90_gnutls.patch$/i CVE-2026-86414.patch' debian/patches/series\n"
        "quilt push -a"
    ): (
        "cp /tmp/curl/CVE-2026-86414.patch debian/patches/\n"
        "# Trixie builds OpenSSL and GnuTLS from the same patched source tree.\n"
        "# Append the reviewed fix after Debian's patches so it reaches both backends.\n"
        "printf '%s\\n' CVE-2026-86414.patch >> debian/patches/series\n"
        "quilt push"
    ),
    "curl (7.88.1-10+deb12u15+oce1) bookworm; urgency=medium": (
        "curl (8.14.1-2+deb13u7+oce1) trixie; urgency=medium"
    ),
    "for package in curl libcurl4 libcurl3-gnutls; do": (
        "for package in curl libcurl4t64 libcurl3t64-gnutls; do"
    ),
    (
        "done\n"
        "sha256sum ../*.dsc ../*.orig.tar.gz ../*.debian.tar.xz "
        "/tmp/curl/CVE-2026-86414.patch > /out/source.sha256"
    ): (
        "done\n"
        'gnutls_package="/out/libcurl3t64-gnutls_${version}+oce1_'
        '$(dpkg --print-architecture).deb"\n'
        'test -f "$gnutls_package"\n'
        'if dpkg-deb -f "$gnutls_package" Depends | '
        "grep -Eq '(^|, )libldap'; then\n"
        '  echo "The runtime curl package still depends on LDAP" >&2\n'
        "  exit 1\n"
        "fi\n"
        "sha256sum ../*.dsc ../*.orig.tar.gz ../*.debian.tar.xz "
        "/tmp/curl/CVE-2026-86414.patch > /out/source.sha256"
    ),
    "sha256sum ../*.dsc ../*.orig.tar.gz ../*.debian.tar.xz "
    "/tmp/curl/CVE-2026-86414.patch > /out/source.sha256": (
        "sha256sum ../*.dsc ../*.orig.tar.gz ../*.debian.tar.xz "
        "/tmp/curl/CVE-2026-86414.patch > /out/source.sha256"
    ),
}
CURL_VERIFY_REPLACEMENTS = {
    (
        'cd "/build/curl/source/debian/$backend/tests" &&\n'
        "    make -C server -j2 all &&"
    ): (
        'cd "/build/curl/source/debian/$backend/tests" &&\n'
        "    make -C certs -j2 all &&\n"
        "    test -s certs/test-localhost.pem &&\n"
        "    make -C server -j2 all &&"
    ),
}
EXPECTED_NODE_SOURCE: dict[str, Any] = {
    "version": "24.22.1",
    "commit": "ce7aaf1cee78b8cf0ce17364260535c418d3ed26",  # pragma: allowlist secret -- public source revision
    "sourceArchiveSha256": (
        "4f5379796280cdaeb0c2f358fd04b6a16cc4fb7dfa83b5a8c91a9d963b435231"  # pragma: allowlist secret -- public archive checksum
    ),
    "patchSha256": ("4ca82f5f04473f4a79b89e57064f71d6f01e6fcacf6794930fc128177306b5c9"),  # pragma: allowlist secret -- public patch checksum
    "modules": "137",
    "napi": "10",
}
EXPECTED_OPENCLAW_SOURCE: dict[str, Any] = {
    "commit": "513c12703ad9a9161cc123e0b8ed4ecb811aa6b3",  # pragma: allowlist secret -- public source revision
    "sourceArchiveSha256": (
        "dab8e21f38603bace955a157f804ddec32b0097ab52286c87b0c0886d45b7730"  # pragma: allowlist secret -- public archive checksum
    ),
    "buildTimestamp": "2026-11-04T17:24:42Z",
}
EXPECTED_OPENSSL_SOURCE: dict[str, Any] = {
    "debianVersion": OPENSSL_DEBIAN_VERSION,
    "packageVersion": OPENSSL_PACKAGE_VERSION,
    "sourceBaseUrl": "https://deb.debian.org/debian/pool/main/o/openssl",
    "sourceFiles": [
        {
            "name": "openssl_3.5.9-1~deb13u1.dsc",
            "sha256": "b038dfab5ee111242b7439e07c820d228519273e7fd1f514014b039e929aad9f",  # pragma: allowlist secret -- public source checksum
        },
        {
            "name": "openssl_3.5.9.orig.tar.gz",
            "sha256": "603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a",  # pragma: allowlist secret -- public source checksum
        },
        {
            "name": "openssl_3.5.9.orig.tar.gz.asc",
            "sha256": "bdccf2057a7c4ae377b40e832cb8c632ae8b532d4fb64cc7b843066eee748f89",  # pragma: allowlist secret -- public source checksum
        },
        {
            "name": "openssl_3.5.9-1~deb13u1.debian.tar.xz",
            "sha256": "7d5158a87cd24641316b050de419be4ebddb1f180afd7ebaa3bc990036c38ec6",  # pragma: allowlist secret -- public source checksum
        },
    ],
    "sourceAnchors": {
        "providers/implementations/ciphers/cipher_aes_gcm_siv.c": (
            "25012f573a36a465f0a68fe004366ef586f3a153d60a5a53db55df9b7b1da5c3"  # pragma: allowlist secret -- public source checksum
        ),
        "providers/implementations/ciphers/cipher_aes_gcm_siv_hw.c": (
            "37f4e407d03117c6b74e5d1385efb233f2d71225788f82857bff2368e7fd0457"  # pragma: allowlist secret -- public source checksum
        ),
        "test/evp_extra_test.c": (
            "4b4b36c42febb276a7efe258b14939e944e9fff3a6ce4597659b5b48790fa627"  # pragma: allowlist secret -- public source checksum
        ),
    },
    "upstreamFixCommit": "159e1de0c448d7b9f09ad768c8e141def4aa1eb4",  # pragma: allowlist secret -- public source revision
    "upstreamTestCommit": "9d0d29bcf98ae5c1fb91653ba635e993260176d8",  # pragma: allowlist secret -- public source revision
    "fixPatchSha256": OPENSSL_CVE_PATCH_SHA256,
    "testPatchSha256": OPENSSL_CVE_TEST_PATCH_SHA256,
    "ecOrderFixCommit": OPENSSL_EC_ORDER_UPSTREAM_COMMIT,
    "ecOrderPatchSha256": OPENSSL_EC_ORDER_PATCH_SHA256,
    "runtimePackages": ["libssl3t64", "openssl", "openssl-provider-legacy"],
    "buildPackages": ["libssl-dev"],
}


def fail(message: str) -> None:
    print(f"OCE security backport: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value: Any = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"could not read {path}: {error}")
    if not isinstance(value, dict):
        fail(f"{path} is not a JSON object")
    return value


parser = argparse.ArgumentParser()
parser.add_argument("oce_source", type=pathlib.Path)
parser.add_argument("expected_revision")
parser.add_argument("node_openssl_patch", type=pathlib.Path)
parser.add_argument("openclaw_patch", type=pathlib.Path)
parser.add_argument("curl_patch", type=pathlib.Path)
parser.add_argument("openssl_source_assets", type=pathlib.Path)
parser.add_argument("openssl_cve_patch", type=pathlib.Path)
parser.add_argument("openssl_cve_test_patch", type=pathlib.Path)
parser.add_argument("openssl_ec_order_patch", type=pathlib.Path)
parser.add_argument(
    "--git-source-assets",
    type=pathlib.Path,
    default=pathlib.Path(__file__).resolve().parent / "git",
)
parser.add_argument(
    "--expat-source-assets",
    type=pathlib.Path,
    default=pathlib.Path(__file__).resolve().parent / "expat",
)
args = parser.parse_args()

runtime_dependency_assets = {
    "git": args.git_source_assets,
    "expat": args.expat_source_assets,
}
for dependency, asset_dir in runtime_dependency_assets.items():
    try:
        entries = {path.name for path in asset_dir.iterdir()}
        required_entries = {"build.sh", "source.json", "verify.sh"}
        optional_entries = (
            {"README.md", "test.Dockerfile"} if dependency == "git" else set()
        )
        if (
            not required_entries <= entries
            or entries - required_entries - optional_entries
            or any(
                not (asset_dir / name).is_file() or (asset_dir / name).is_symlink()
                for name in entries
            )
        ):
            fail(f"the {dependency} assets contain missing, unexpected or unsafe files")
        metadata_sha = hashlib.sha256(
            (asset_dir / "source.json").read_bytes()
        ).hexdigest()
    except OSError as error:
        fail(f"could not read the {dependency} source assets: {error}")
    if metadata_sha != RUNTIME_DEPENDENCY_METADATA_SHA256[dependency]:
        fail(f"the {dependency} source metadata changed; review the release")

if not re.fullmatch(r"[0-9a-f]{40}", args.expected_revision):
    fail("expected revision must be a full lowercase Git commit SHA")

try:
    actual_revision = subprocess.run(
        ["git", "-C", str(args.oce_source), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
except (OSError, subprocess.CalledProcessError) as error:
    fail(f"could not read the OCE Git revision: {error}")
if actual_revision != args.expected_revision:
    fail(f"OCE checkout is {actual_revision!r}, expected {args.expected_revision!r}")

node_dir = args.oce_source / "deploy" / "runtime" / "node"
source_json = node_dir / "source.json"
fetch_script = node_dir / "fetch.sh"
if read_json(source_json) != EXPECTED_NODE_SOURCE:
    fail("the pinned Node source metadata changed; review the backport before building")

try:
    openssl_patch_bytes = args.node_openssl_patch.read_bytes()
except OSError as error:
    fail(f"could not read {args.node_openssl_patch}: {error}")
if hashlib.sha256(openssl_patch_bytes).hexdigest() != OPENSSL_PATCH_SHA256:
    fail("the OpenSSL patch checksum does not match the reviewed upstream patch")
if b"Fixes: CVE-2026-95692" not in openssl_patch_bytes:
    fail("the reviewed CVE identifier is missing from the OpenSSL patch")
try:
    with tempfile.TemporaryDirectory(prefix="oce-openssl-patch-check-") as check_dir:
        subprocess.run(
            [
                "git",
                "apply",
                "--numstat",
                "--unsafe-paths",
                str(args.node_openssl_patch.resolve()),
            ],
            cwd=check_dir,
            check=True,
            capture_output=True,
            text=True,
        )
except (OSError, subprocess.CalledProcessError) as error:
    fail(f"the reviewed OpenSSL patch is not a valid Git patch: {error}")

expected_openssl_assets = {"build.sh", "source.json", "verify.sh"}
try:
    openssl_asset_entries = set(path.name for path in args.openssl_source_assets.iterdir())
except OSError as error:
    fail(f"could not read {args.openssl_source_assets}: {error}")
if openssl_asset_entries != expected_openssl_assets:
    fail("the OpenSSL source asset set changed; expected build.sh, source.json, verify.sh")
if any(
    not (args.openssl_source_assets / name).is_file()
    or (args.openssl_source_assets / name).is_symlink()
    for name in expected_openssl_assets
):
    fail("OpenSSL source assets must be regular, non-symlink files")
openssl_source_metadata = args.openssl_source_assets / "source.json"
try:
    openssl_source_metadata_bytes = openssl_source_metadata.read_bytes()
    openssl_cve_patch_bytes = args.openssl_cve_patch.read_bytes()
    openssl_cve_test_patch_bytes = args.openssl_cve_test_patch.read_bytes()
    openssl_ec_order_patch_bytes = args.openssl_ec_order_patch.read_bytes()
except OSError as error:
    fail(f"could not read the OpenSSL backport inputs: {error}")
if (
    hashlib.sha256(openssl_source_metadata_bytes).hexdigest()
    != OPENSSL_SOURCE_METADATA_SHA256
    or read_json(openssl_source_metadata) != EXPECTED_OPENSSL_SOURCE
):
    fail("the pinned Debian OpenSSL source metadata changed")
if hashlib.sha256(openssl_cve_patch_bytes).hexdigest() != OPENSSL_CVE_PATCH_SHA256:
    fail("the CVE-2026-88823 fix patch checksum does not match upstream")
if (
    hashlib.sha256(openssl_cve_test_patch_bytes).hexdigest()
    != OPENSSL_CVE_TEST_PATCH_SHA256
):
    fail("the CVE-2026-88823 test patch checksum does not match upstream")
if (
    hashlib.sha256(openssl_ec_order_patch_bytes).hexdigest()
    != OPENSSL_EC_ORDER_PATCH_SHA256
):
    fail("the CVE-2026-107496 patch checksum does not match upstream")
for patch_bytes, markers in (
    (
        openssl_cve_patch_bytes,
        (
            b"From 159e1de0c448d7b9f09ad768c8e141def4aa1eb4 ",
            b"Fixes: CVE-2026-88823",
        ),
    ),
    (
        openssl_cve_test_patch_bytes,
        (
            b"From 9d0d29bcf98ae5c1fb91653ba635e993260176d8 ",
            b"Merged-from: https://github.com/openssl/openssl/pull/33456",
        ),
    ),
    (
        openssl_ec_order_patch_bytes,
        (
            f"From {OPENSSL_EC_ORDER_UPSTREAM_COMMIT} ".encode(),
            b"Fixes: CVE-2026-107496",
        ),
    ),
):
    for marker in markers:
        if marker not in patch_bytes:
            fail(f"an OpenSSL CVE-2026-88823 patch is missing marker {marker!r}")
try:
    with tempfile.TemporaryDirectory(prefix="oce-openssl-cve-patch-check-") as check_dir:
        openssl_cve_patch_summary = subprocess.run(
            [
                "git",
                "apply",
                "--numstat",
                "--unsafe-paths",
                str(args.openssl_cve_patch.resolve()),
            ],
            cwd=check_dir,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        openssl_cve_test_patch_summary = subprocess.run(
            [
                "git",
                "apply",
                "--numstat",
                "--unsafe-paths",
                str(args.openssl_cve_test_patch.resolve()),
            ],
            cwd=check_dir,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        openssl_ec_order_patch_summary = subprocess.run(
            [
                "git",
                "apply",
                "--numstat",
                "--unsafe-paths",
                str(args.openssl_ec_order_patch.resolve()),
            ],
            cwd=check_dir,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
except (OSError, subprocess.CalledProcessError) as error:
    fail(f"an OpenSSL CVE-2026-88823 input is not a valid Git patch: {error}")
if openssl_cve_patch_summary != (
    "10\t0\tproviders/implementations/ciphers/cipher_aes_gcm_siv.c\n"
    "1\t6\tproviders/implementations/ciphers/cipher_aes_gcm_siv_hw.c\n"
):
    fail("the CVE-2026-88823 fix changes files outside the reviewed backport")
if openssl_cve_test_patch_summary != "407\t1\ttest/evp_extra_test.c\n":
    fail("the CVE-2026-88823 tests change files outside the upstream regression test")
if openssl_ec_order_patch_summary != (
    "5\t0\tcrypto/ec/ec_key.c\n"
    "33\t0\ttest/ectest.c\n"
):
    fail("the CVE-2026-107496 patch changes files outside the reviewed backport")

try:
    fetch = fetch_script.read_text(encoding="utf-8")
except (OSError, UnicodeError) as error:
    fail(f"could not read {fetch_script}: {error}")

node_codename_before = 'test "$VERSION_CODENAME" = bookworm'
node_codename_after = 'test "$VERSION_CODENAME" = trixie'
if fetch.count(node_codename_before) != 1:
    fail("the pinned Node distribution guard changed; review the Debian update")

checksum_before = """patch_sha=$(node -p 'require("./source.json").patchSha256')
printf '%s  /build/node.tar.xz\\n%s  worker-esm-termination.patch\\n' "$archive_sha" "$patch_sha" | sha256sum --check --strict
"""
checksum_after = f"""patch_sha=$(node -p 'require("./source.json").patchSha256')
security_patch_sha="{OPENSSL_PATCH_SHA256}"
cve_2026_88823_patch_sha="{OPENSSL_CVE_PATCH_SHA256}"
cve_2026_107496_patch_sha="{OPENSSL_EC_ORDER_PATCH_SHA256}"
printf '%s  /build/node.tar.xz\\n%s  worker-esm-termination.patch\\n%s  {OPENSSL_PATCH_FILE_NAME}\\n%s  {OPENSSL_CVE_PATCH_FILE_NAME}\\n%s  {OPENSSL_EC_ORDER_PATCH_FILE_NAME}\\n' "$archive_sha" "$patch_sha" "$security_patch_sha" "$cve_2026_88823_patch_sha" "$cve_2026_107496_patch_sha" | sha256sum --check --strict
"""
apply_before = "git apply /node-repair/worker-esm-termination.patch\n"
apply_after = (
    apply_before
    + "git apply -p1 --directory=deps/openssl/openssl "
    + f"/node-repair/{OPENSSL_PATCH_FILE_NAME}\n"
    + "git apply -p1 --directory=deps/openssl/openssl "
    + f"/node-repair/{OPENSSL_CVE_PATCH_FILE_NAME}\n"
    # Node's vendored OpenSSL archive omits upstream regression tests. Apply the
    # production fix here; the Debian OpenSSL build applies the complete patch.
    + "git apply -p1 --directory=deps/openssl/openssl "
    + "--include=deps/openssl/openssl/crypto/ec/ec_key.c "
    + f"/node-repair/{OPENSSL_EC_ORDER_PATCH_FILE_NAME}\n"
)
if fetch.count(checksum_before) != 1 or fetch.count(apply_before) != 1:
    fail("the pinned Node fetch script changed; review the backport before building")

patched_fetch = (
    fetch.replace(checksum_before, checksum_after)
    .replace(apply_before, apply_after)
    .replace(node_codename_before, node_codename_after)
)
openclaw_source_json = args.oce_source / "deploy" / "runtime" / "openclaw-source.json"
if read_json(openclaw_source_json) != EXPECTED_OPENCLAW_SOURCE:
    fail("the pinned OpenClaw source metadata changed; review the patch before building")

try:
    openclaw_patch_bytes = args.openclaw_patch.read_bytes()
except OSError as error:
    fail(f"could not read {args.openclaw_patch}: {error}")
if hashlib.sha256(openclaw_patch_bytes).hexdigest() != OPENCLAW_PATCH_SHA256:
    fail("the OpenClaw patch checksum does not match the reviewed patch")
for marker in (
    b'"npm": "12.2.2"',
    b'"@openclaw/crabline@0.1.31>re2js": 2.8.7',
    b'"mailauth@7.3.1>joi": 18.3.2',
    b'"mailauth@7.3.1>undici": 8.12.3',
    b'npm@12.2.0',
    b"re2js@2.8.6",
    b"joi@18.2.9",
    b"undici@8.11.2",
):
    if marker not in openclaw_patch_bytes:
        fail(f"the OpenClaw patch is missing reviewed marker {marker!r}")
try:
    with tempfile.TemporaryDirectory(prefix="oce-openclaw-patch-check-") as check_dir:
        patch_summary = subprocess.run(
            [
                "git",
                "apply",
                "--numstat",
                "--unsafe-paths",
                str(args.openclaw_patch.resolve()),
            ],
            cwd=check_dir,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
except (OSError, subprocess.CalledProcessError) as error:
    fail(f"the reviewed OpenClaw patch is not a valid Git patch: {error}")
if patch_summary != (
    "1\t1\tpackage.json\n"
    "17\t20\tpnpm-lock.yaml\n"
    "7\t0\tpnpm-workspace.yaml\n"
):
    fail("the OpenClaw patch changes files outside the reviewed dependency update")

runtime_dockerfile = args.oce_source / "deploy" / "runtime" / "Dockerfile"
runtime_assets_script = args.oce_source / "scripts" / "build-runtime-assets.mjs"
try:
    dockerfile = runtime_dockerfile.read_text(encoding="utf-8")
    runtime_assets = runtime_assets_script.read_text(encoding="utf-8")
except (OSError, UnicodeError) as error:
    fail(f"could not read the OpenClaw runtime build files: {error}")

docker_anchor = """# Record every patch applied here in appliedPatches in scripts/build-runtime-assets.mjs,
# which writes provenance; runtime-assets.test.mjs compares the two.
"""
docker_insertion = docker_anchor + f"""# Pin reviewed transitive dependencies used by the bundled IMAP plugin.
COPY deploy/runtime/{OPENCLAW_PATCH_FILE_NAME} /tmp/{OPENCLAW_PATCH_FILE_NAME}
RUN echo '{OPENCLAW_PATCH_SHA256}  /tmp/{OPENCLAW_PATCH_FILE_NAME}' | sha256sum --check --strict \\
    && git apply /tmp/{OPENCLAW_PATCH_FILE_NAME}
"""
assets_anchor = "const appliedPatches = [\n"
assets_insertion = assets_anchor + f"""  {{
    file: "{OPENCLAW_PATCH_FILE_NAME}",
    sha256: "{OPENCLAW_PATCH_SHA256}",
  }},
"""
npm_stage_anchor = "FROM node-build-base AS node-source\n"
npm_stage_insertion = f"""FROM node-build-base AS npm-runtime
RUN --mount=type=secret,id=build-ca,required=false \\
    set -eu; \\
    if [ -f /run/secrets/build-ca ]; then export CURL_CA_BUNDLE=/run/secrets/build-ca; fi; \\
    curl --fail --location --no-progress-meter --retry 6 --retry-all-errors \\
      https://registry.npmjs.org/npm/-/npm-{NPM_RUNTIME_VERSION}.tgz -o /tmp/npm.tgz; \\
    echo '{NPM_RUNTIME_ARCHIVE_SHA256}  /tmp/npm.tgz' | sha256sum --check --strict; \\
    mkdir /out; \\
    tar -xzf /tmp/npm.tgz --strip-components=1 -C /out; \\
    rm /tmp/npm.tgz; \\
    test "$(node /out/bin/npm-cli.js --version)" = "{NPM_RUNTIME_VERSION}"; \\
    test "$(node -p 'require("/out/node_modules/undici/package.json").version')" = "{NPM_RUNTIME_UNDICI_VERSION}"

FROM node-build-base AS openssl-packages
COPY deploy/runtime/openssl /tmp/openssl
RUN --mount=type=secret,id=build-ca,required=false \\
    set -eu; \\
    if [ -f /run/secrets/build-ca ]; then export CURL_CA_BUNDLE=/run/secrets/build-ca; fi; \\
    sh /tmp/openssl/build.sh
RUN --network=none sh /tmp/openssl/verify.sh

FROM node-build-base AS dependency-build-base
RUN apt-get update --error-on=any \\
    && apt-get install -y --no-install-recommends \\
      build-essential dpkg-dev pkg-config libcurl4-openssl-dev zlib1g-dev \\
      ca-certificates curl xz-utils \\
    && rm -rf /var/lib/apt/lists/*

FROM dependency-build-base AS git-packages
COPY deploy/runtime/git /tmp/git
RUN --mount=type=secret,id=build-ca,required=false \\
    set -eu; \\
    if [ -f /run/secrets/build-ca ]; then export CURL_CA_BUNDLE=/run/secrets/build-ca; fi; \\
    sh /tmp/git/build.sh
RUN --network=none sh /tmp/git/verify.sh --packages /out

FROM dependency-build-base AS expat-packages
COPY deploy/runtime/expat /tmp/expat
RUN --mount=type=secret,id=build-ca,required=false \\
    set -eu; \\
    if [ -f /run/secrets/build-ca ]; then export CURL_CA_BUNDLE=/run/secrets/build-ca; fi; \\
    sh /tmp/expat/build.sh
RUN --network=none sh /tmp/expat/verify.sh --packages /out

{npm_stage_anchor}"""
curl_stage_before = """FROM node-build-base AS curl-packages
COPY deploy/runtime/curl /tmp/curl
RUN --mount=type=secret,id=build-ca,required=false \\
    set -eu; \\
    if [ -f /run/secrets/build-ca ]; then export CURL_CA_BUNDLE=/run/secrets/build-ca; fi; \\
    sh /tmp/curl/build.sh
"""
curl_stage_after = f"""FROM node-build-base AS curl-packages
COPY deploy/runtime/curl /tmp/curl
RUN --mount=type=bind,from=openssl-packages,source=/out,target=/tmp/openssl-packages \\
    --mount=type=secret,id=build-ca,required=false \\
    set -eu; \\
    if [ -f /run/secrets/build-ca ]; then export CURL_CA_BUNDLE=/run/secrets/build-ca; fi; \\
    cd /tmp/openssl-packages; \\
    sha256sum --check --strict packages.sha256; \\
    arch="$(dpkg --print-architecture)"; \\
    expected="{OPENSSL_PACKAGE_VERSION}"; \\
    expected_runtime="$(printf '%s\\n' "libssl3t64_${{expected}}_${{arch}}.deb" "openssl_${{expected}}_${{arch}}.deb" "openssl-provider-legacy_${{expected}}_${{arch}}.deb")"; \\
    test "$(cat runtime-packages.list)" = "$expected_runtime"; \\
    test "$(cat build-packages.list)" = "libssl-dev_${{expected}}_${{arch}}.deb"; \\
    apt-get update --error-on=any; \\
    sed 's#^#/tmp/openssl-packages/#' runtime-packages.list build-packages.list \\
      | xargs apt-get install -y --no-install-recommends; \\
    for package in libssl3t64 openssl openssl-provider-legacy libssl-dev; do \\
      test "$(dpkg-query -W -f='${{Version}}' "$package")" = "$expected"; \\
    done; \\
    cd /; \\
    sh /tmp/curl/build.sh
"""
runtime_stage_anchor = "FROM node-runtime-base AS runtime\n\n"
runtime_stage_insertion = runtime_stage_anchor + f"""# Replace the npm bundled by the Node base with a reviewed maintenance release.
RUN rm -rf /usr/local/lib/node_modules/npm
COPY --from=npm-runtime /out/ /usr/local/lib/node_modules/npm/
RUN test "$(npm --version)" = "{NPM_RUNTIME_VERSION}" \\
    && test "$(node -p 'require("/usr/local/lib/node_modules/npm/node_modules/undici/package.json").version')" = "{NPM_RUNTIME_UNDICI_VERSION}"

"""
runtime_packages_before = """RUN --mount=type=bind,from=curl-packages,source=/out,target=/tmp/curl-packages \\
    apt-get update --error-on=any \\
    && candidate="$(apt-cache policy curl | sed -n 's/^  Candidate: //p')" \\
    && expected="$(cat /tmp/curl-packages/debian-version)" \\
    && { [ "$candidate" = "$expected" ] || { echo "Refresh the curl backport: Debian candidate is $candidate, source is $expected" >&2; exit 1; }; } \\
    && apt-get install -y --no-install-recommends tini git ca-certificates openssh-client libstdc++6 libgomp1 python3 procps /tmp/curl-packages/*.deb \\
    && mkdir -p /usr/share/doc/curl/oce \\
    && cp /tmp/curl-packages/*.sha256 /usr/share/doc/curl/oce/ \\
    && rm -rf /var/lib/apt/lists/*
"""
runtime_packages_after = f"""RUN --mount=type=bind,from=openssl-packages,source=/out,target=/tmp/openssl-packages \\
    --mount=type=bind,from=curl-packages,source=/out,target=/tmp/curl-packages \\
    --mount=type=bind,from=git-packages,source=/out,target=/tmp/git-packages \\
    --mount=type=bind,from=expat-packages,source=/out,target=/tmp/expat-packages \\
    --mount=type=bind,source=deploy/runtime/git,target=/tmp/git-assets \\
    --mount=type=bind,source=deploy/runtime/expat,target=/tmp/expat-assets \\
    set -eu; \\
    cd /tmp/openssl-packages; \\
    sha256sum --check --strict packages.sha256; \\
    arch="$(dpkg --print-architecture)"; \\
    openssl_expected="{OPENSSL_PACKAGE_VERSION}"; \\
    expected_runtime="$(printf '%s\\n' "libssl3t64_${{openssl_expected}}_${{arch}}.deb" "openssl_${{openssl_expected}}_${{arch}}.deb" "openssl-provider-legacy_${{openssl_expected}}_${{arch}}.deb")"; \\
    test "$(cat runtime-packages.list)" = "$expected_runtime"; \\
    apt-get update --error-on=any; \\
    curl_candidate="$(apt-cache policy curl | sed -n 's/^  Candidate: //p')"; \\
    curl_expected="$(cat /tmp/curl-packages/debian-version)"; \\
    test "$curl_candidate" = "$curl_expected" || {{ echo "Refresh the curl backport: Debian candidate is $curl_candidate, source is $curl_expected" >&2; exit 1; }}; \\
    sed 's#^#/tmp/openssl-packages/#' runtime-packages.list \\
      | xargs apt-get install -y --no-install-recommends; \\
    sh /tmp/git-assets/verify.sh --packages /tmp/git-packages; \\
    sh /tmp/expat-assets/verify.sh --packages /tmp/expat-packages; \\
    git_packages="$(sed 's#^#/tmp/git-packages/#' /tmp/git-packages/runtime-packages.list)"; \\
    expat_packages="$(sed 's#^#/tmp/expat-packages/#' /tmp/expat-packages/runtime-packages.list)"; \\
    apt-get install -y --no-install-recommends tini ca-certificates openssh-client libstdc++6 libgomp1 python3 procps /tmp/curl-packages/*.deb $git_packages $expat_packages; \\
    sh /tmp/git-assets/verify.sh --runtime; \\
    sh /tmp/expat-assets/verify.sh --runtime; \\
    if dpkg-query -W libsasl2-2 >/dev/null 2>&1; then \\
      echo "The runtime still contains Cyrus SASL" >&2; exit 1; \\
    fi; \\
    for package in libssl3t64 openssl openssl-provider-legacy; do \\
      test "$(dpkg-query -W -f='${{Version}}' "$package")" = "$openssl_expected"; \\
    done; \\
    test "$(openssl version | awk '{{print $2}}')" = 3.5.9; \\
    mkdir -p /usr/share/doc/openssl/oce /usr/share/doc/curl/oce; \\
    cp /tmp/openssl-packages/source.sha256 /tmp/openssl-packages/packages.sha256 /usr/share/doc/openssl/oce/; \\
    cp /tmp/curl-packages/*.sha256 /usr/share/doc/curl/oce/; \\
    rm -rf /var/lib/apt/lists/*
"""
if (
    dockerfile.count(docker_anchor) != 1
    or dockerfile.count(npm_stage_anchor) != 1
    or dockerfile.count(runtime_stage_anchor) != 1
    or dockerfile.count(curl_stage_before) != 1
    or dockerfile.count(runtime_packages_before) != 1
    or runtime_assets.count(assets_anchor) != 1
):
    fail("the OpenClaw runtime patch anchors changed; review the patch before building")
if any(
    dockerfile.count(old_value) != 1
    for old_value in NODE_BASE_IMAGE_REPLACEMENTS
):
    fail("the pinned Node base images changed; review the Debian update")
runtime_codename_before = (
    'test "${VERSION_CODENAME:-}" = bookworm || { echo "The Node termination '
    'repair requires a Bookworm runtime base." >&2; exit 1; };'
)
runtime_codename_after = (
    'test "${VERSION_CODENAME:-}" = trixie || { echo "The Node termination '
    'repair requires a Trixie runtime base." >&2; exit 1; };'
)
if dockerfile.count(runtime_codename_before) != 1:
    fail("the pinned runtime distribution guard changed; review the Debian update")
gh_cli_fragments = (
    f"releases/download/v{GH_CLI_OLD_VERSION}/gh_{GH_CLI_OLD_VERSION}_linux_",
    f"releases/download/v{GH_CLI_OLD_VERSION}/gh_{GH_CLI_OLD_VERSION}_checksums.txt",
    f"{GH_CLI_OLD_CHECKSUMS_SHA256}  gh_{GH_CLI_OLD_VERSION}_checksums.txt",
    f'grep " gh_{GH_CLI_OLD_VERSION}_linux_',
    f'tar -xzf "gh_{GH_CLI_OLD_VERSION}_linux_',
    f'install -m 0755 "gh_{GH_CLI_OLD_VERSION}_linux_',
    f"rm -rf /tmp/gh_{GH_CLI_OLD_VERSION}*",
    f"grep '^gh version {GH_CLI_OLD_VERSION} '",
)
if any(dockerfile.count(fragment) != 1 for fragment in gh_cli_fragments):
    fail("the pinned GitHub CLI install changed; review the update before building")
if dockerfile.count(GH_CLI_OLD_CHECKSUMS_SHA256) != 1:
    fail("the pinned GitHub CLI checksum changed; review the update before building")
patched_dockerfile = dockerfile
for old_value, new_value in NODE_BASE_IMAGE_REPLACEMENTS.items():
    patched_dockerfile = patched_dockerfile.replace(old_value, new_value)
patched_dockerfile = (
    patched_dockerfile.replace(GH_CLI_OLD_VERSION, GH_CLI_VERSION)
    .replace(GH_CLI_OLD_CHECKSUMS_SHA256, GH_CLI_CHECKSUMS_SHA256)
    .replace(runtime_codename_before, runtime_codename_after)
    .replace(npm_stage_anchor, npm_stage_insertion)
    .replace(curl_stage_before, curl_stage_after)
    .replace(runtime_packages_before, runtime_packages_after)
    .replace(docker_anchor, docker_insertion)
    .replace(runtime_stage_anchor, runtime_stage_insertion)
)
gog_release_path = (
    args.oce_source
    / "apps"
    / "controller"
    / "plugins"
    / "oce-google-workspace"
    / "ai.openclaw.oce"
    / "release.json"
)
try:
    gog_release = gog_release_path.read_text(encoding="utf-8")
except (OSError, UnicodeError) as error:
    fail(f"could not read {gog_release_path}: {error}")
if any(
    gog_release.count(old_value) != 1
    for old_value in GOG_RELEASE_REPLACEMENTS
):
    fail("the pinned Google Workspace CLI release changed; review the update")
patched_gog_release = gog_release
for old_value, new_value in GOG_RELEASE_REPLACEMENTS.items():
    patched_gog_release = patched_gog_release.replace(old_value, new_value)

curl_dir = args.oce_source / "deploy" / "runtime" / "curl"
curl_build_script = curl_dir / "build.sh"
curl_verify_script = curl_dir / "verify.sh"
try:
    curl_patch_bytes = args.curl_patch.read_bytes()
    curl_build = curl_build_script.read_text(encoding="utf-8")
    curl_verify = curl_verify_script.read_text(encoding="utf-8")
except (OSError, UnicodeError) as error:
    fail(f"could not read the curl backport inputs: {error}")
if hashlib.sha256(curl_patch_bytes).hexdigest() != CURL_PATCH_SHA256:
    fail("the curl patch checksum does not match the reviewed upstream patch")
for marker in (
    b"Fixes: CVE-2026-86414",
    b"Upstream-Commit: 2956af6c7451029fb12c12f8166dff211f930d52",
):
    if marker not in curl_patch_bytes:
        fail(f"the curl patch is missing reviewed marker {marker!r}")
try:
    with tempfile.TemporaryDirectory(prefix="oce-curl-patch-check-") as check_dir:
        curl_patch_summary = subprocess.run(
            [
                "git",
                "apply",
                "--numstat",
                "--unsafe-paths",
                str(args.curl_patch.resolve()),
            ],
            cwd=check_dir,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
except (OSError, subprocess.CalledProcessError) as error:
    fail(f"the reviewed curl patch is not a valid Git patch: {error}")
if curl_patch_summary != (
    "2\t4\tlib/cf-h1-proxy.c\n"
    "2\t0\ttests/data/Makefile.am\n"
    "68\t0\ttests/data/test2173\n"
    "1\t1\ttests/testutil.pm\n"
):
    fail("the curl patch changes files outside the reviewed security backport")
if any(curl_build.count(old_value) != 1 for old_value in CURL_BUILD_REPLACEMENTS):
    fail("the pinned curl source build changed; review the Debian update")
if any(
    curl_verify.count(old_value) != 1
    for old_value in CURL_VERIFY_REPLACEMENTS
):
    fail("the pinned curl verification script changed; review the test setup")
patched_curl_build = curl_build
for old_value, new_value in CURL_BUILD_REPLACEMENTS.items():
    patched_curl_build = patched_curl_build.replace(old_value, new_value)
patched_curl_verify = curl_verify
for old_value, new_value in CURL_VERIFY_REPLACEMENTS.items():
    patched_curl_verify = patched_curl_verify.replace(old_value, new_value)

openclaw_destination = (
    args.oce_source / "deploy" / "runtime" / OPENCLAW_PATCH_FILE_NAME
)
openssl_destination = node_dir / OPENSSL_PATCH_FILE_NAME
node_openssl_cve_destination = node_dir / OPENSSL_CVE_PATCH_FILE_NAME
node_openssl_ec_order_destination = node_dir / OPENSSL_EC_ORDER_PATCH_FILE_NAME
openssl_source_destination = args.oce_source / "deploy" / "runtime" / "openssl"
curl_destination = curl_dir / CURL_PATCH_DESTINATION_FILE_NAME
if openssl_source_destination.exists():
    fail("the OpenSSL source asset destination already exists")
try:
    shutil.copyfile(args.node_openssl_patch, openssl_destination)
    shutil.copyfile(args.openssl_cve_patch, node_openssl_cve_destination)
    shutil.copyfile(
        args.openssl_ec_order_patch,
        node_openssl_ec_order_destination,
    )
    fetch_script.write_text(patched_fetch, encoding="utf-8")
    shutil.copytree(args.openssl_source_assets, openssl_source_destination)
    for dependency, asset_dir in runtime_dependency_assets.items():
        dependency_destination = (
            args.oce_source / "deploy" / "runtime" / dependency
        )
        dependency_destination.mkdir()
        for name in ("build.sh", "source.json", "verify.sh"):
            shutil.copyfile(asset_dir / name, dependency_destination / name)
    shutil.copyfile(
        args.openssl_cve_patch,
        openssl_source_destination / OPENSSL_CVE_PATCH_DESTINATION_FILE_NAME,
    )
    shutil.copyfile(
        args.openssl_cve_test_patch,
        openssl_source_destination / OPENSSL_CVE_TEST_PATCH_DESTINATION_FILE_NAME,
    )
    shutil.copyfile(
        args.openssl_ec_order_patch,
        openssl_source_destination / OPENSSL_EC_ORDER_PATCH_DESTINATION_FILE_NAME,
    )
    shutil.copyfile(args.openclaw_patch, openclaw_destination)
    runtime_dockerfile.write_text(
        patched_dockerfile,
        encoding="utf-8",
    )
    runtime_assets_script.write_text(
        runtime_assets.replace(assets_anchor, assets_insertion),
        encoding="utf-8",
    )
    gog_release_path.write_text(patched_gog_release, encoding="utf-8")
    shutil.copyfile(args.curl_patch, curl_destination)
    curl_build_script.write_text(patched_curl_build, encoding="utf-8")
    curl_verify_script.write_text(patched_curl_verify, encoding="utf-8")
except OSError as error:
    fail(f"could not prepare the OpenClaw runtime source tree: {error}")

print(
    "OCE security backport: applied CVE-2026-95692 patch "
    f"{OPENSSL_PATCH_SHA256} to Node {EXPECTED_NODE_SOURCE['version']}; "
    "applied CVE-2026-88823 fix "
    f"{OPENSSL_CVE_PATCH_SHA256} to Node's embedded OpenSSL and Debian OpenSSL "
    f"{OPENSSL_DEBIAN_VERSION}, with upstream regression tests "
    f"{OPENSSL_CVE_TEST_PATCH_SHA256}; "
    "applied CVE-2026-107496 fix and regression test "
    f"{OPENSSL_EC_ORDER_PATCH_SHA256} to Node's embedded OpenSSL and Debian "
    f"OpenSSL package {OPENSSL_PACKAGE_VERSION}; "
    "selected libssl3t64, openssl, and openssl-provider-legacy for runtime "
    "and libssl-dev for the curl build; "
    f"applied OpenClaw dependency patch {OPENCLAW_PATCH_SHA256}; "
    f"pinned npm {NPM_RUNTIME_VERSION} with undici {NPM_RUNTIME_UNDICI_VERSION}; "
    "updated the Node build and runtime bases to Debian 13 (Trixie); "
    f"applied CVE-2026-86414 patch {CURL_PATCH_SHA256} to Debian curl "
    "8.14.1-2+deb13u7 and disabled unused LDAP transports; "
    f"updated GitHub CLI from {GH_CLI_OLD_VERSION} to {GH_CLI_VERSION}; "
    f"updated Google Workspace CLI from {GOG_OLD_VERSION} to {GOG_VERSION}"
    "; installed checksum-pinned Git 2.56.1 and Expat 2.11.0 Debian packages"
)
