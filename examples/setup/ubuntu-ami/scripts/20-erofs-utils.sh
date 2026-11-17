#!/usr/bin/env bash
# 20-erofs-utils.sh: build erofs-utils 1.8.10 with zstd from the pinned public source
# (packages/sources.lock, id=erofs-utils-source), install it to /usr/local, purge Ubuntu's
# erofs-utils package, and prove the binary the shim will run is this one.
#
# The containerd shim runs `mkfs.erofs -zzstd,1` with no fallback, from a systemd service
# (containerd), not a login shell. Ubuntu 24.04 ships erofs-utils 1.7.1 without zstd, so:
#   * the source build uses --with-libzstd (and --enable-lz4);
#   * the distro package is purged, so /usr/bin/mkfs.erofs cannot shadow /usr/local/bin;
#   * the check runs `mkfs.erofs` through systemd-run, i.e. with the PATH a systemd service
#     sees, and also checks containerd.service sets no PATH that leaves /usr/local/bin out.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
export DEBIAN_FRONTEND=noninteractive

sudo apt-get -o DPkg::Lock::Timeout=600 install -y --no-install-recommends \
  build-essential libzstd-dev liblz4-dev uuid-dev autoconf automake libtool pkg-config

if [ -x /usr/local/bin/mkfs.erofs ] && /usr/local/bin/mkfs.erofs --version 2>&1 | grep -qF "$EROFS_UTILS_VERSION"; then
  echo "erofs-utils ${EROFS_UTILS_VERSION} already installed at /usr/local/bin"
else
  TARBALL="$(bash "$HERE/../packages/fetch-erofs-utils.sh" "$RUNTIME_ARTIFACTS_DIR" | tail -n 1)"
  BUILD_DIR="$HOME/build-erofs"
  rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
  tar -C "$BUILD_DIR" --strip-components=1 -xzf "$TARBALL"
  cd "$BUILD_DIR"
  ./autogen.sh 2>&1 | tail -n 3
  ./configure --prefix=/usr/local --enable-lz4 --with-libzstd 2>&1 | tee "$LOG_DIR/erofs-utils.configure.log" | tail -n 10
  make -j"$(nproc)" 2>&1 | tee "$LOG_DIR/erofs-utils.build.log" | tail -n 3
  sudo make install 2>&1 | tail -n 3
  sudo ldconfig
fi
# Purge the distro package whether or not this run built anything: it would shadow nothing on
# a standard PATH, but its 1.7.1 binary must not be what any service finds.
if dpkg -s erofs-utils >/dev/null 2>&1; then
  sudo apt-get -o DPkg::Lock::Timeout=600 purge -y erofs-utils 2>&1 | tail -n 2
fi
dpkg -s erofs-utils >/dev/null 2>&1 && die "Ubuntu's erofs-utils package is still installed after purge"
hash -r

# --- Assertions on what a service will actually run -------------------------------------------
ver="$(/usr/local/bin/mkfs.erofs --version 2>&1 | head -n 1)"
[[ "$ver" == *"$EROFS_UTILS_VERSION"* ]] || die "/usr/local/bin/mkfs.erofs reports '$ver', expected $EROFS_UTILS_VERSION"
svc_path="$(sudo systemd-run --wait --pipe --quiet --collect /bin/sh -c 'command -v mkfs.erofs' 2>&1 || true)"
[ "$svc_path" = /usr/local/bin/mkfs.erofs ] || die "a systemd service resolves mkfs.erofs to '${svc_path:-<nothing>}', expected /usr/local/bin/mkfs.erofs (is /usr/local/bin on systemd's default PATH?)"
svc_env="$(systemctl show containerd.service -p Environment --value 2>/dev/null || true)"
if [[ "$svc_env" == *PATH=* ]]; then
  svc_unit_path="$(printf '%s\n' "$svc_env" | tr ' ' '\n' | sed -n 's/^PATH=//p' | tail -n 1)"
  [[ ":$svc_unit_path:" == *:/usr/local/bin:* ]] || die "containerd.service sets PATH=$svc_unit_path without /usr/local/bin; the shim would not find mkfs.erofs"
fi
d=$(mktemp -d); mkdir "$d/src"; echo x > "$d/src/f"
sudo systemd-run --wait --pipe --quiet --collect /bin/sh -c "mkfs.erofs -zzstd,1 '$d/t.img' '$d/src' >/dev/null" \
  || { rm -rf "$d"; die "mkfs.erofs -zzstd,1 fails when run as a systemd service: no zstd support"; }
rm -rf "$d"

echo "erofs-utils ${EROFS_UTILS_VERSION} ($ver; source sha256 $(lock_field erofs-utils-source sha256); /usr/local/bin/mkfs.erofs sha256 $(sha256sum /usr/local/bin/mkfs.erofs | awk '{print $1}'); zstd ok as a systemd service) $(date -u +%FT%TZ)" \
  | sudo tee -a "$IMAGE_MANIFEST"
