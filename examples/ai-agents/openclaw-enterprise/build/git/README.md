# Git and Expat runtime packages

Build the reviewed upstream releases as ordinary Debian 13 packages. Install
them through `apt-get`; preserve the dpkg database, upstream copyrights,
release notes, debug symbols and provenance.

| Package | Control `Version` | Output filename |
| --- | --- | --- |
| git | `1:2.56.1-1+oce1` | `git_2.56.1-1+oce1_${arch}.deb` |
| git-man | `1:2.56.1-1+oce1` | `git-man_2.56.1-1+oce1_all.deb` |
| libexpat1 | `2.11.0-1+oce1` | `libexpat1_2.11.0-1+oce1_${arch}.deb` |
| libexpat1-dev | `2.11.0-1+oce1` | `libexpat1-dev_2.11.0-1+oce1_${arch}.deb` |

Git retains Debian's epoch `1`, so replacing an installed `1:2.47.3` package
is an upgrade. The filenames omit that epoch, following Debian convention.

[Git 2.56.1 release notes](https://github.com/git/git/blob/v2.56.1/Documentation/RelNotes/2.56.1.adoc)
list CVE-2026-111760 and CVE-2026-105437. The signed tag points to
`03b41523c576f26ad34085378717a0c1b287470f`; archive and man-page hashes come
from [kernel.org's published checksums](https://www.kernel.org/pub/software/scm/git/sha256sums.asc).
[Expat's release history](https://github.com/libexpat/libexpat/blob/R_2_11_0/expat/Changes)
lists CVE-2026-117610 and CVE-2026-118370 under 2.10.0, incorporated in 2.11.0.
Its archive hash matches the
[official 2.11.0 release asset](https://github.com/libexpat/libexpat/releases/tag/R_2_11_0).
The build pins both archives and each complete `source.json` before unpacking.

## Docker integration

Copy `build/git` and `build/expat` into the OCE runtime source tree as
`deploy/runtime/git` and `deploy/runtime/expat`. Use the reviewed Debian 13
`node-build-base`. Install these prerequisites in a shared builder stage:

```dockerfile
RUN apt-get update --error-on=any \
    && apt-get install -y --no-install-recommends \
        build-essential dpkg-dev pkg-config libcurl4-openssl-dev zlib1g-dev \
        ca-certificates curl xz-utils

FROM dependency-build-base AS git-packages
COPY deploy/runtime/git /tmp/git
RUN sh /tmp/git/build.sh && sh /tmp/git/verify.sh --packages /out

FROM dependency-build-base AS expat-packages
COPY deploy/runtime/expat /tmp/expat
RUN sh /tmp/expat/build.sh && sh /tmp/expat/verify.sh --packages /out
```

Git builds with upstream's supported `NO_RUST` C implementation. It disables
DAV/Expat integration, GUI/Tcl, Perl commands, Python contrib tools and gettext,
while retaining local, HTTPS and SSH transports. This reduces optional
dependencies; it changes those optional Git capabilities.

Mount each stage's `/out` in the final runtime. Run `verify.sh --packages`
against each mount before installing the exact runtime packages above.
Install `git-man` with Git. Install `libexpat1-dev` in builders or when the
target already contains an installed distro development package; otherwise
install only `libexpat1`. The Expat package verifier checks both emitted
packages, even when the runtime only needs one.

Install the runtime's `python3`, `openssh-client`, and `ca-certificates` with
the repaired packages. Keep the independently repaired curl/OpenSSL packages
in the same dependency graph. `dpkg-shlibdeps` generates the actual library
dependencies, so use equivalent Debian 13 builder and runtime bases.
Verify the final runtime after all package installations:

```sh
sh /tmp/git/verify.sh --runtime
sh /tmp/expat/verify.sh --runtime
```

Git installs `/usr/bin/git`, `/usr/bin/git-shell`, and
`/usr/lib/git-core/git-remote-https`. Its runtime check exercises a local
clone, HTTPS clone with certificate verification, object integrity and SSH
transport dispatch. The HTTPS test needs GitHub egress; SSH dispatch uses a
local command fixture and does not prove connectivity to a live SSH server.

Expat installs `/usr/lib/${DEB_HOST_MULTIARCH}/libexpat.so.1` with its actual
upstream library version. Its offline check verifies the SONAME's reported
version, Python `pyexpat`, valid and malformed XML, and the initial empty
external-subparser regression shape from CVE-2026-117610.

Every `/out` carries `runtime-packages.list`, `packages.sha256`,
`source.sha256`, and `source.json`. Expat also carries `build-packages.list`.
Preserve the provenance files in the runtime's documentation directory.
Do not infer an Inspector result from these checks: scan the production image
digest after Docker integration and run the live tenant-isolation E2E.

## Standalone probe

Build from the sample directory using `build/git/test.Dockerfile`. It builds
both dependencies, installs actual distro packages, upgrades them through
apt, and runs the package, transport and Python ABI checks:

```sh
docker build --progress=plain -f build/git/test.Dockerfile \
    -t pr264-git-expat-repair:verify .
python -m pytest -q tests/test_runtime_dependency_assets.py
```
