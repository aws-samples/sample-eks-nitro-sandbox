#!/usr/bin/env bash
# 20-erofs-utils.sh: build erofs-utils with zstd support from the pinned public source
# (packages/sources.lock) and install it to /usr/local, replacing the distro package.
#
# The containerd shim runs `mkfs.erofs -zzstd,1` with no fallback. Ubuntu 24.04 ships
# erofs-utils 1.7.1 without zstd, so this is a source build on Ubuntu specifically (AL2023's
# distro version already has zstd). See packages/SOURCES.txt, input 3.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
export DEBIAN_FRONTEND=noninteractive

sudo apt-get -o DPkg::Lock::Timeout=600 install -y --no-install-recommends \
  libzstd-dev liblz4-dev uuid-dev autoconf automake libtool pkg-config

d=$(mktemp -d); echo x > "$d/f"
if mkfs.erofs -zzstd,1 "$d/t.img" "$d" >/dev/null 2>&1 && [ -x /usr/local/bin/mkfs.erofs ]; then
  echo "erofs-utils with zstd already installed at /usr/local/bin"
else
  TARBALL="$(bash "$HERE/../packages/fetch-erofs-utils.sh" "$RUNTIME_ARTIFACTS_DIR")"
  BUILD_DIR="$HOME/build-erofs"
  rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
  tar -C "$BUILD_DIR" --strip-components=1 -xzf "$TARBALL"
  cd "$BUILD_DIR"
  ./autogen.sh 2>&1 | tail -3
  ./configure --prefix=/usr/local --enable-lz4 --with-libzstd 2>&1 | tee "$LOG_DIR/erofs-utils.configure.log" | tail -10
  make -j"$(nproc)" 2>&1 | tee "$LOG_DIR/erofs-utils.build.log" | tail -3
  sudo make install 2>&1 | tail -3
  sudo ldconfig
  sudo apt-get -o DPkg::Lock::Timeout=600 purge -y erofs-utils 2>&1 | tail -2 || true
  hash -r
fi
rm -rf "$d"
[ "$(command -v mkfs.erofs)" = /usr/local/bin/mkfs.erofs ] || die "mkfs.erofs resolves to $(command -v mkfs.erofs), expected /usr/local/bin/mkfs.erofs"
d=$(mktemp -d); echo x > "$d/f"; mkfs.erofs -zzstd,1 "$d/t.img" "$d"; rm -rf "$d"

echo "erofs-utils ${EROFS_UTILS_VERSION} (source, /usr/local/bin, sha256 $(sha256sum /usr/local/bin/mkfs.erofs | cut -c1-16)) $(date -u +%FT%TZ)" \
  | sudo tee -a /etc/nip-custom-ami-manifest
