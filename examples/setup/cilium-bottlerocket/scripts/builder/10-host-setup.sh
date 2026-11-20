#!/usr/bin/env bash
# 10-host-setup.sh (stage host-setup, on the builder): the work volume, the build packages,
# Docker, Rust, cargo-make and Twoliter. Every download is checked against packer/tools.lock.
# Input: CB_WORK_VOLUME_ID (the volume Packer attached at /dev/xvdc).
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
need_volume_id CB_WORK_VOLUME_ID

# --- the work volume: new, empty, formatted here -------------------------------------------
dev=$(volume_device "$CB_WORK_VOLUME_ID")
[ "$dev" != "$(findmnt -nvo SOURCE /)" ] || die "E_WORK_VOLUME: $dev is the root device"
not_in_use "$dev"
[ -z "$(blkid -p -o value -s TYPE "$dev" 2>/dev/null || true)" ] || die "E_WORK_VOLUME: $dev already has a file system"
mkfs.xfs -q "$dev"
install -d -m 0755 "$WORK"
mount "$dev" "$WORK"
install -d -m 0700 "$TOOLS" "$INPUTS"
log "work volume $CB_WORK_VOLUME_ID ($dev) mounted at $WORK, $(df -h --output=size "$WORK" | tail -n 1 | tr -d ' ')"

# --- packages from the Amazon Linux 2023 repositories (signed repository metadata) ---------
dnf -y -q install docker git lz4 gcc make openssl-devel perl-FindBin perl-lib gdisk xfsprogs \
  || die "E_DNF: the package install failed"
systemctl enable --now docker >/dev/null 2>&1 || die "E_DOCKER: docker did not start"
docker_version=$(docker version --format '{{.Server.Version}}') || die "E_DOCKER: docker does not answer"
case "$docker_version" in
  [2-9][0-9].*) ;;
  *) die "E_DOCKER: Docker $docker_version is older than 20.10.10" ;;
esac
[ "${docker_version%%.*}" -gt 20 ] || die "E_DOCKER: Docker $docker_version; this build needs 21 or later"
log "docker=$docker_version git=$(git --version | awk '{print $3}') lz4=$(lz4 --version 2>&1 | awk '{print $NF; exit}')"

# --- Rust, by rustup-init with the pinned digest ------------------------------------------
rustup_v=$(tool_lock RUSTUP_VERSION); rustup_sha=$(tool_lock RUSTUP_INIT_SHA256); toolchain=$(tool_lock RUST_TOOLCHAIN)
fetch_verified "https://static.rust-lang.org/rustup/archive/$rustup_v/x86_64-unknown-linux-gnu/rustup-init" \
  "$TOOLS/rustup-init" "$rustup_sha"
chmod 0755 "$TOOLS/rustup-init"
"$TOOLS/rustup-init" -y -q --no-modify-path --profile minimal --default-toolchain "$toolchain" >/dev/null \
  || die "E_RUST: rustup-init failed"
[ "$(rustc --version | awk '{print $2}')" = "$toolchain" ] || die "E_RUST: rustc is not $toolchain"
log "rustup-init=$rustup_v sha256=$rustup_sha rust=$toolchain"

# --- cargo-make, from crates.io with its own Cargo.lock ------------------------------------
cm_v=$(tool_lock CARGO_MAKE_VERSION); cm_sha=$(tool_lock CARGO_MAKE_CRATE_SHA256)
cargo install -q --locked --version "=$cm_v" cargo-make >"$WORK/cargo-make-install.log" 2>&1 \
  || { tail -n 30 "$WORK/cargo-make-install.log" >&2; die "E_CARGO_MAKE: cargo install failed"; }
crate=$(find "$CARGO_HOME/registry/cache" -name "cargo-make-$cm_v.crate" | head -n 1)
[ -n "$crate" ] && [ "$(sha256sum "$crate" | awk '{print $1}')" = "$cm_sha" ] \
  || die "E_CARGO_MAKE: the cargo-make crate does not have the pinned checksum"
log "cargo-make=$cm_v crate_sha256=$cm_sha"

# --- Twoliter, the release binary with the digest that Bottlerocket's Makefile.toml sets --------
tl_v=$(tool_lock TWOLITER_VERSION); tl_sha=$(tool_lock TWOLITER_SHA256_X86_64)
fetch_verified "https://github.com/bottlerocket-os/twoliter/releases/download/$tl_v/twoliter-x86_64-unknown-linux-musl.tar.xz" \
  "$TOOLS/twoliter.tar.xz" "$tl_sha"
tar -xJf "$TOOLS/twoliter.tar.xz" -C "$TOOLS" twoliter-x86_64-unknown-linux-musl/twoliter
[ "v$("$TOOLS/twoliter-x86_64-unknown-linux-musl/twoliter" --version | awk '{print $2}')" = "$tl_v" ] \
  || die "E_TWOLITER: the binary does not report $tl_v"
log "twoliter=$tl_v sha256=$tl_sha"
log "host-setup ok"
