#!/bin/sh
set -eu
assets=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
printf '%s  %s\n' bc9edc727635b4a9e9c08c49c687065f3f8d3565587cec3c171c7cb3e8b860e6 "$assets/source.json" |
    sha256sum --check --strict
case "${1:-}" in
    --check-metadata) test "$#" = 1; exit 0 ;;
    --check-source)
        test "$#" = 2
        printf '%s  %s\n' 61e7614b602201c28a189dafee78f5bceaee192bbde46a930752ff09cf5542fa "$2" |
            sha256sum --check --strict
        exit 0 ;;
    "") ;;
    *) echo "Usage: build.sh [--check-metadata | --check-source ARCHIVE]" >&2; exit 2 ;;
esac
. /etc/os-release
test "$ID" = debian && test "$VERSION_ID" = 13
arch=$(dpkg --print-architecture)
multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
version=2.11.0-1+oce1
work=/build/expat
mkdir -p "$work" /out
cd "$work"
curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error --retry 3 \
    https://github.com/libexpat/libexpat/releases/download/R_2_11_0/expat-2.11.0.tar.xz \
    -o expat.tar.xz
sh "$assets/build.sh" --check-source "$work/expat.tar.xz"
tar -xJf expat.tar.xz
cd expat-2.11.0
CFLAGS='-O2 -g -fno-strict-aliasing -fstack-protector-strong -D_FORTIFY_SOURCE=2' \
    LDFLAGS='-Wl,-z,relro,-z,now' \
    ./configure --prefix=/usr --libdir=/usr/lib/"$multiarch" \
        --enable-shared --disable-static --without-docbook --without-xmlwf
make -j2
make check
make DESTDIR="$work/stage" install
mkdir -p "$work/libexpat1/usr/lib/$multiarch" "$work/libexpat1/DEBIAN" \
    "$work/libexpat1/usr/share/doc/libexpat1/oce" "$work/libexpat1-dev/DEBIAN"
mv "$work/stage/usr/lib/$multiarch"/libexpat.so.* "$work/libexpat1/usr/lib/$multiarch/"
# Keep headers/pkg-config and the unversioned linker symlink in the matching
# development package. Replace an installed distro -dev package truthfully.
mv "$work/stage/usr" "$work/libexpat1-dev/"
rm "$work/libexpat1-dev/usr/lib/$multiarch/libexpat.la"
cp COPYING "$work/libexpat1/usr/share/doc/libexpat1/copyright"
cp Changes "$work/libexpat1/usr/share/doc/libexpat1/oce/"
cp "$assets/source.json" "$work/libexpat1/usr/share/doc/libexpat1/oce/"
mkdir -p debian
printf 'Source: expat\nSection: libs\nPriority: optional\nMaintainer: OpenClaw Enterprise contributors <noreply@openclaw.ai>\n' >debian/control
deps=$(dpkg-shlibdeps -O -e"$work/libexpat1/usr/lib/$multiarch/libexpat.so.1" |
    sed -n 's/^shlibs:Depends=//p')
test -n "$deps"
cat >"$work/libexpat1/DEBIAN/control" <<EOF
Package: libexpat1
Source: expat
Version: $version
Architecture: $arch
Multi-Arch: same
Maintainer: OpenClaw Enterprise contributors <noreply@openclaw.ai>
Depends: $deps
Description: Expat 2.11.0 XML parser retaining the libexpat.so.1 ABI
 Built from the checksum-pinned upstream release.
EOF
printf 'libexpat 1 libexpat1 (>= 2.11.0)\n' >"$work/libexpat1/DEBIAN/shlibs"
printf '#!/bin/sh\nset -e\nldconfig\n' >"$work/libexpat1/DEBIAN/postinst"
cp "$work/libexpat1/DEBIAN/postinst" "$work/libexpat1/DEBIAN/postrm"
chmod 755 "$work/libexpat1/DEBIAN/postinst" "$work/libexpat1/DEBIAN/postrm"
cat >"$work/libexpat1-dev/DEBIAN/control" <<EOF
Package: libexpat1-dev
Source: expat
Version: $version
Architecture: $arch
Multi-Arch: same
Maintainer: OpenClaw Enterprise contributors <noreply@openclaw.ai>
Depends: libexpat1 (= $version)
Description: Expat 2.11.0 development headers
 Headers and linker metadata matching the runtime library.
EOF
for package in libexpat1 libexpat1-dev; do
    dpkg-deb --root-owner-group --build "$work/$package" \
        "/out/${package}_${version}_${arch}.deb"
done
printf '%s\n' "libexpat1_${version}_${arch}.deb" >/out/runtime-packages.list
printf '%s\n' "libexpat1-dev_${version}_${arch}.deb" >/out/build-packages.list
cp "$assets/source.json" /out/
cd /out
sha256sum ./*.deb >packages.sha256
sha256sum "$work/expat.tar.xz" "$assets/source.json" >source.sha256
sh "$assets/verify.sh" --packages /out
