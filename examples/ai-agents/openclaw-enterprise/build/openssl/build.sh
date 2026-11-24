#!/bin/sh
set -eu

debian_version=3.5.9-1~deb13u1
package_version=3.5.9-1~deb13u1+oce3
source_base_url=https://deb.debian.org/debian/pool/main/o/openssl
asset_dir=/tmp/openssl
build_dir=/build/openssl
source_dir="$build_dir/source"
metadata_sha256=c54110fa43dafa9542779264036f2864a0b828551564d2400b5e22782b57e8da

if [ "${1:-}" = "--check-assets" ] && [ "$#" -eq 2 ]; then
  asset_dir=$2
elif [ "$#" -ne 0 ]; then
  echo "usage: build.sh [--check-assets ASSET_DIRECTORY]" >&2
  exit 2
fi
python3 "$asset_dir/security_assets.py" check-assets --assets "$asset_dir" \
  --expected-metadata-sha256 "$metadata_sha256"
if [ "${1:-}" = "--check-assets" ]; then
  exit 0
fi
mkdir -p "$build_dir" /out
cd "$build_dir"
for file in \
  "openssl_${debian_version}.dsc" \
  openssl_3.5.9.orig.tar.gz \
  openssl_3.5.9.orig.tar.gz.asc \
  "openssl_${debian_version}.debian.tar.xz"; do
  curl --fail --location --silent --show-error --retry 6 \
    "$source_base_url/$file" -o "$file"
done
sha256sum --check --strict <<'CHECKSUMS'
b038dfab5ee111242b7439e07c820d228519273e7fd1f514014b039e929aad9f  openssl_3.5.9-1~deb13u1.dsc
603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a  openssl_3.5.9.orig.tar.gz
bdccf2057a7c4ae377b40e832cb8c632ae8b532d4fb64cc7b843066eee748f89  openssl_3.5.9.orig.tar.gz.asc
7d5158a87cd24641316b050de419be4ebddb1f180afd7ebaa3bc990036c38ec6  openssl_3.5.9-1~deb13u1.debian.tar.xz
CHECKSUMS
apt-get update --error-on=any
candidate=$(apt-cache policy openssl | sed -n 's/^  Candidate: //p')
if [ "$candidate" != "$debian_version" ]; then
  echo "Refresh the OpenSSL backport: Debian candidate is $candidate, source is $debian_version" >&2
  exit 1
fi
apt-get install -y --no-install-recommends quilt
apt-get build-dep -y --no-install-recommends -Pnocheck "./openssl_${debian_version}.dsc"
dpkg-source --no-check -x "openssl_${debian_version}.dsc" "$source_dir"
cd "$source_dir"
python3 "$asset_dir/security_assets.py" check-source --assets "$asset_dir" \
  --source "$source_dir" --expected-metadata-sha256 "$metadata_sha256"

export QUILT_PATCHES=debian/patches
python3 "$asset_dir/security_assets.py" patch-files --assets "$asset_dir" \
  --expected-metadata-sha256 "$metadata_sha256" >"$build_dir/oce-patches.list"
while IFS= read -r patch_file; do
  cp "$asset_dir/$patch_file" debian/patches/
  printf '%s\n' "$patch_file" >>debian/patches/series
done <"$build_dir/oce-patches.list"
quilt push -a
python3 "$asset_dir/security_assets.py" check-patched-source --assets "$asset_dir" \
  --source "$source_dir" --expected-metadata-sha256 "$metadata_sha256"
cat >debian/changelog.oce <<'CHANGELOG'
openssl (3.5.9-1~deb13u1+oce3) trixie; urgency=medium

  * Backport upstream 159e1de0c448d7b9f09ad768c8e141def4aa1eb4
    for CVE-2026-88823 and regression tests from
    9d0d29bcf98ae5c1fb91653ba635e993260176d8.
  * Backport upstream a0051cfe699bf5a047bc1c4faef65f80f7987366
    for CVE-2026-107496 and its regression test.
  * Backport upstream 257a3427aa0ef8d9dd2ef5b3e2d1c021a221b116
    for CVE-2026-95692. Verify AES-GCM-SIV rejects unsupported IV lengths
    through both EVP control and provider parameter APIs.
  * Backport the openssl-3.5 fixes for CVE-2026-95691, CVE-2026-107493,
    CVE-2026-124709, CVE-2026-121482, CVE-2026-107494 and CVE-2026-84786.
    source.json records their ordered upstream commits and patch checksums.
  * Include upstream stream-GC regression tests from
    22291a6af12f158fbb13bfbd572a33dbdbf290d2 (test-only hunk).

 -- OpenClaw Enterprise contributors <noreply@openclaw.ai>  Wed, 25 Nov 2026 00:00:00 +0000

CHANGELOG
cat debian/changelog >>debian/changelog.oce
mv debian/changelog.oce debian/changelog
DEB_BUILD_OPTIONS=nocheck \
  dpkg-buildpackage --build=binary --no-sign --build-profiles=nocheck --jobs=2

arch=$(dpkg --print-architecture)
for package in libssl3t64 openssl openssl-provider-legacy libssl-dev; do
  deb="../${package}_${package_version}_${arch}.deb"
  test -f "$deb"
  cp "$deb" /out/
done
printf '%s\n' \
  "libssl3t64_${package_version}_${arch}.deb" \
  "openssl_${package_version}_${arch}.deb" \
  "openssl-provider-legacy_${package_version}_${arch}.deb" \
  >/out/runtime-packages.list
printf '%s\n' "libssl-dev_${package_version}_${arch}.deb" >/out/build-packages.list
sha256sum \
  "$build_dir"/*.dsc \
  "$build_dir"/*.orig.tar.gz \
  "$build_dir"/*.debian.tar.xz \
  "$asset_dir/source.json" \
  "$asset_dir/iv_length_regression.c" \
  >/out/source.sha256
while IFS= read -r patch_file; do
  sha256sum "$asset_dir/$patch_file" >>/out/source.sha256
done <"$build_dir/oce-patches.list"
cp "$asset_dir/source.json" /out/source.json
cp "$build_dir/oce-patches.list" /out/oce-patches.list
printf '%s\n' "$debian_version" >/out/debian-version
printf '%s\n' "$package_version" >/out/package-version
cd /out
sha256sum ./*.deb >packages.sha256
