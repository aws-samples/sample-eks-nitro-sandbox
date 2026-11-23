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
OPENCLAW_PATCH_FILE_NAME = "openclaw-security-overrides.patch"
OPENCLAW_PATCH_SHA256 = "2b1fb478649494c0b74879bbed20c55155658575555ebe37a88050d372aef451"  # pragma: allowlist secret -- reviewed patch checksum
CURL_PATCH_FILE_NAME = "curl-cve-2026-86414-trixie.patch"
CURL_PATCH_DESTINATION_FILE_NAME = "CVE-2026-86414.patch"
CURL_PATCH_SHA256 = "e254884af6e63c012ee5c4cfa16910ea91160b104d8a62883a0c7ed24ad11221"  # pragma: allowlist secret -- reviewed patch checksum
NPM_RUNTIME_VERSION = "11.21.3"
NPM_RUNTIME_ARCHIVE_SHA256 = "ee5fc68e724c4bdba38db9d96d9c661d4e736e4be7001ae44d2fbbaa52159514"  # pragma: allowlist secret -- public archive checksum
NPM_RUNTIME_UNDICI_VERSION = "6.29.1"
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
        'for file in "curl_${version}.dsc" curl_8.14.1.orig.tar.xz '
        'curl_8.14.1.orig.tar.xz.asc "curl_${version}.debian.tar.xz"; do'
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
        "curl_8.14.1.orig.tar.xz\n"
        "39cc2ec8ddc39d04e3e7101bbed46d858d0875cbb297a6bfa20959fa2bc7d5c7  "
        "curl_8.14.1.orig.tar.xz.asc\n"
        "e0f627ee2b9ae61078b2835edc25c8b94a0b57e180a1bc72dd8636ef260c370b  "
        "curl_8.14.1-2+deb13u7.debian.tar.xz"
    ),
    "curl (7.88.1-10+deb12u15+oce1) bookworm; urgency=medium": (
        "curl (8.14.1-2+deb13u7+oce1) trixie; urgency=medium"
    ),
    "for package in curl libcurl4 libcurl3-gnutls; do": (
        "for package in curl libcurl4t64 libcurl3t64-gnutls; do"
    ),
    "sha256sum ../*.dsc ../*.orig.tar.gz ../*.debian.tar.xz "
    "/tmp/curl/CVE-2026-86414.patch > /out/source.sha256": (
        "sha256sum ../*.dsc ../*.orig.tar.xz ../*.debian.tar.xz "
        "/tmp/curl/CVE-2026-86414.patch > /out/source.sha256"
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
parser.add_argument("openssl_patch", type=pathlib.Path)
parser.add_argument("openclaw_patch", type=pathlib.Path)
parser.add_argument("curl_patch", type=pathlib.Path)
args = parser.parse_args()

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
    openssl_patch_bytes = args.openssl_patch.read_bytes()
except OSError as error:
    fail(f"could not read {args.openssl_patch}: {error}")
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
                str(args.openssl_patch.resolve()),
            ],
            cwd=check_dir,
            check=True,
            capture_output=True,
            text=True,
        )
except (OSError, subprocess.CalledProcessError) as error:
    fail(f"the reviewed OpenSSL patch is not a valid Git patch: {error}")

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
printf '%s  /build/node.tar.xz\\n%s  worker-esm-termination.patch\\n%s  {OPENSSL_PATCH_FILE_NAME}\\n' "$archive_sha" "$patch_sha" "$security_patch_sha" | sha256sum --check --strict
"""
apply_before = "git apply /node-repair/worker-esm-termination.patch\n"
apply_after = (
    apply_before
    + "git apply -p1 --directory=deps/openssl/openssl "
    + f"/node-repair/{OPENSSL_PATCH_FILE_NAME}\n"
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

{npm_stage_anchor}"""
runtime_stage_anchor = "FROM node-runtime-base AS runtime\n\n"
runtime_stage_insertion = runtime_stage_anchor + f"""# Replace the npm bundled by the Node base with a reviewed maintenance release.
RUN rm -rf /usr/local/lib/node_modules/npm
COPY --from=npm-runtime /out/ /usr/local/lib/node_modules/npm/
RUN test "$(npm --version)" = "{NPM_RUNTIME_VERSION}" \\
    && test "$(node -p 'require("/usr/local/lib/node_modules/npm/node_modules/undici/package.json").version')" = "{NPM_RUNTIME_UNDICI_VERSION}"

"""
if (
    dockerfile.count(docker_anchor) != 1
    or dockerfile.count(npm_stage_anchor) != 1
    or dockerfile.count(runtime_stage_anchor) != 1
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
try:
    curl_patch_bytes = args.curl_patch.read_bytes()
    curl_build = curl_build_script.read_text(encoding="utf-8")
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
):
    fail("the curl patch changes files outside the reviewed security backport")
if any(curl_build.count(old_value) != 1 for old_value in CURL_BUILD_REPLACEMENTS):
    fail("the pinned curl source build changed; review the Debian update")
patched_curl_build = curl_build
for old_value, new_value in CURL_BUILD_REPLACEMENTS.items():
    patched_curl_build = patched_curl_build.replace(old_value, new_value)

openclaw_destination = (
    args.oce_source / "deploy" / "runtime" / OPENCLAW_PATCH_FILE_NAME
)
openssl_destination = node_dir / OPENSSL_PATCH_FILE_NAME
curl_destination = curl_dir / CURL_PATCH_DESTINATION_FILE_NAME
try:
    shutil.copyfile(args.openssl_patch, openssl_destination)
    fetch_script.write_text(patched_fetch, encoding="utf-8")
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
except OSError as error:
    fail(f"could not prepare the OpenClaw runtime source tree: {error}")

print(
    "OCE security backport: applied CVE-2026-95692 patch "
    f"{OPENSSL_PATCH_SHA256} to Node {EXPECTED_NODE_SOURCE['version']}; "
    f"applied OpenClaw dependency patch {OPENCLAW_PATCH_SHA256}; "
    f"pinned npm {NPM_RUNTIME_VERSION} with undici {NPM_RUNTIME_UNDICI_VERSION}; "
    "updated the Node build and runtime bases to Debian 13 (Trixie); "
    f"applied CVE-2026-86414 patch {CURL_PATCH_SHA256} to Debian curl "
    "8.14.1-2+deb13u7; "
    f"updated GitHub CLI from {GH_CLI_OLD_VERSION} to {GH_CLI_VERSION}; "
    f"updated Google Workspace CLI from {GOG_OLD_VERSION} to {GOG_VERSION}"
)
