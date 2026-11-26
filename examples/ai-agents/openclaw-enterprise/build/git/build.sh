#!/bin/sh
# Build ordinary Debian packages from the reviewed upstream release.
set -eu
assets=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
printf '%s  %s\n' b8f6f175739b1d77487cc88a0b1c127ebefe9f16070fc48f11d16e1a6e71d9cf "$assets/source.json" |
    sha256sum --check --strict
case "${1:-}" in
    --check-metadata) test "$#" = 1; exit 0 ;;
    --check-source)
        test "$#" = 2
        printf '%s  %s\n' f0b0bf89264b9bd2e1c640363e7529643989da76281600473c50745cd34a607f "$2" |
            sha256sum --check --strict
        exit 0 ;;
    "") ;;
    *) echo "Usage: build.sh [--check-metadata | --check-source ARCHIVE]" >&2; exit 2 ;;
esac
. /etc/os-release
test "$ID" = debian && test "$VERSION_ID" = 13
arch=$(dpkg --print-architecture)
multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
version=1:2.56.1-1+oce1
file_version=2.56.1-1+oce1
work=/build/git
mkdir -p "$work" /out
cd "$work"
curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error --retry 3 \
    https://www.kernel.org/pub/software/scm/git/git-2.56.1.tar.xz -o git.tar.xz
sh "$assets/build.sh" --check-source "$work/git.tar.xz"
curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error --retry 3 \
    https://www.kernel.org/pub/software/scm/git/git-manpages-2.56.1.tar.xz -o manpages.tar.xz
printf '%s  %s\n' 6ea093f15745a9ac85fe1b1d4fe488413d54e68d0fcb10bab62f047f362cf6de manpages.tar.xz |
    sha256sum --check --strict
tar -xJf git.tar.xz
cd git-2.56.1
test "$(cat version)" = 2.56.1
# HTTPS uses libcurl; SSH uses the runtime's openssh-client. DAV, GUI, Perl
# commands and Python contrib tools are outside this runtime's requirements.
make -j2 prefix=/usr gitexecdir=/usr/lib/git-core \
    NO_EXPAT=YesPlease NO_TCLTK=YesPlease NO_PERL=YesPlease \
    NO_PYTHON=YesPlease NO_GETTEXT=YesPlease NO_RUST=YesPlease INSTALL_SYMLINKS=1 \
    CFLAGS='-O2 -g -fstack-protector-strong -D_FORTIFY_SOURCE=2' \
    LDFLAGS='-Wl,-z,relro,-z,now'
make prefix=/usr gitexecdir=/usr/lib/git-core \
    NO_EXPAT=YesPlease NO_TCLTK=YesPlease NO_PERL=YesPlease \
    NO_PYTHON=YesPlease NO_GETTEXT=YesPlease NO_RUST=YesPlease INSTALL_SYMLINKS=1 \
    CFLAGS='-O2 -g -fstack-protector-strong -D_FORTIFY_SOURCE=2' \
    LDFLAGS='-Wl,-z,relro,-z,now' \
    DESTDIR="$work/git" install
mkdir -p "$work/git-man/usr/share/man" "$work/git/DEBIAN" \
    "$work/git/usr/share/doc/git/oce" "$work/git-man/DEBIAN" \
    "$work/git-man/usr/share/doc/git-man"
tar -xJf "$work/manpages.tar.xz" -C "$work/git-man/usr/share/man"
cp COPYING "$work/git/usr/share/doc/git/copyright"
cp COPYING "$work/git-man/usr/share/doc/git-man/copyright"
cp "$assets/source.json" "$work/git/usr/share/doc/git/oce/"
cp Documentation/RelNotes/2.56.1.adoc "$work/git/usr/share/doc/git/oce/"
printf 'Source: git\nSection: vcs\nPriority: optional\nMaintainer: OpenClaw Enterprise contributors <noreply@openclaw.ai>\n' >debian-control
mkdir -p debian
cp debian-control debian/control
deps=$(dpkg-shlibdeps -O -e"$work/git/usr/bin/git" \
    -e"$work/git/usr/lib/git-core/git-remote-http" \
    -l"/usr/lib/$multiarch" | sed -n 's/^shlibs:Depends=//p')
test -n "$deps"
cat >"$work/git/DEBIAN/control" <<EOF
Package: git
Source: git
Version: $version
Architecture: $arch
Maintainer: OpenClaw Enterprise contributors <noreply@openclaw.ai>
Depends: $deps, git-man (= $version), openssh-client, ca-certificates
Description: Git 2.56.1 minimal runtime with local, HTTPS and SSH transports
 Built from the checksum-pinned upstream release without DAV, GUI or Perl.
EOF
cat >"$work/git-man/DEBIAN/control" <<EOF
Package: git-man
Source: git
Version: $version
Architecture: all
Maintainer: OpenClaw Enterprise contributors <noreply@openclaw.ai>
Description: Git 2.56.1 upstream manual pages
 Official checksum-pinned upstream manpages release.
EOF
for package in git git-man; do
    package_arch=$arch
    test "$package" != git-man || package_arch=all
    dpkg-deb --root-owner-group --build "$work/$package" \
        "/out/${package}_${file_version}_${package_arch}.deb"
done
printf '%s\n' "git_${file_version}_${arch}.deb" "git-man_${file_version}_all.deb" >/out/runtime-packages.list
cp "$assets/source.json" /out/
cd /out
sha256sum ./*.deb >packages.sha256
sha256sum "$work/git.tar.xz" "$work/manpages.tar.xz" "$assets/source.json" >source.sha256
sh "$assets/verify.sh" --packages /out
