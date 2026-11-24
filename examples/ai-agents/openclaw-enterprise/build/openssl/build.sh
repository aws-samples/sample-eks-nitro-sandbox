#!/bin/sh
set -eu

debian_version=3.5.9-1~deb13u1
package_version=3.5.9-1~deb13u1+oce1
source_base_url=https://deb.debian.org/debian/pool/main/o/openssl
asset_dir=/tmp/openssl
build_dir=/build/openssl
source_dir="$build_dir/source"

echo 'b144a173be41c9e6af5e4169b6e373f7e0e124ffeff7ffdb782d7782ca1f08a5  /tmp/openssl/source.json' |
  sha256sum --check --strict
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
printf '%s  %s\n' \
  a945077c0a978dbfe5af5e4f7174a2151466547f8fb94562f395baa7b6b7c147 \
  "$asset_dir/CVE-2026-88823.patch" \
  c7885d44f2659d97c0fc71fcdc8a6ef04cbe2ccdd36a72c28e7dfd1452033f2d \
  "$asset_dir/CVE-2026-88823-test.patch" |
  sha256sum --check --strict

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
sha256sum --check --strict <<'ANCHORS'
25012f573a36a465f0a68fe004366ef586f3a153d60a5a53db55df9b7b1da5c3  providers/implementations/ciphers/cipher_aes_gcm_siv.c
37f4e407d03117c6b74e5d1385efb233f2d71225788f82857bff2368e7fd0457  providers/implementations/ciphers/cipher_aes_gcm_siv_hw.c
4b4b36c42febb276a7efe258b14939e944e9fff3a6ce4597659b5b48790fa627  test/evp_extra_test.c
ANCHORS

export QUILT_PATCHES=debian/patches
cp "$asset_dir/CVE-2026-88823.patch" debian/patches/
cp "$asset_dir/CVE-2026-88823-test.patch" debian/patches/
printf '%s\n' CVE-2026-88823.patch CVE-2026-88823-test.patch >>debian/patches/series
quilt push -a
cat >debian/changelog.oce <<'CHANGELOG'
openssl (3.5.9-1~deb13u1+oce1) trixie; urgency=medium

  * Backport upstream 159e1de0c448d7b9f09ad768c8e141def4aa1eb4
    for CVE-2026-88823 and regression tests from
    9d0d29bcf98ae5c1fb91653ba635e993260176d8.

 -- OpenClaw Enterprise contributors <noreply@openclaw.ai>  Wed, 04 Nov 2026 00:00:00 +0000

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
  "$asset_dir/CVE-2026-88823.patch" \
  "$asset_dir/CVE-2026-88823-test.patch" \
  >/out/source.sha256
printf '%s\n' "$debian_version" >/out/debian-version
printf '%s\n' "$package_version" >/out/package-version
cd /out
sha256sum ./*.deb >packages.sha256
