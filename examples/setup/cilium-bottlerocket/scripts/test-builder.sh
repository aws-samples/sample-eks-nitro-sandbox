#!/usr/bin/env bash
# test-builder.sh: proves the checks of scripts/builder/ both ways, in the REAL files, with stub
# commands first on PATH. No builder, no root, no block device is written.
#
# Safety: the suite refuses to run as root, and before each case it checks that every command
# that can write a disk or change the host (DISK_WRITERS below) resolves to this suite's stub
# folder on the PATH the case runs with; if one does not, the suite stops (exit 2).
#
#   1  lib.sh helpers:
#      lib.sh sourced in a subshell, CLONE set after the source.
#        fetch_verified   E_DIGEST E_DOWNLOAD (a curl stub writes a fixture to the -o path)
#        find_images      E_IMAGES (fixture trees under the work folder)
#        not_in_use       E_VOLUME_IN_USE (an lsblk stub)
#        volume_device    E_VOLUME_DEVICE, reject side (a volume ID with no device node)
#
#   examples/setup/cilium-bottlerocket/scripts/test-builder.sh
source "$(dirname "$0")/testlib/harness.sh"
LIB="$SAMPLE_DIR_REAL/scripts/builder/lib.sh"
need_file "$LIB" "every builder case" || finish
if [[ "$(id -u)" == 0 ]]; then
  echo "ERROR: $SUITE refuses to run as root: a builder stage run by root could write a real disk" >&2
  exit 2
fi

# ---- stubs -----------------------------------------------------------------------------------
BSTUB="$WORK/bstub"; mkdir -p "$BSTUB"
export BSTUB_LOG="$WORK/bstub.log"; : > "$BSTUB_LOG"
DISK_WRITERS=(dd sgdisk sfdisk parted partprobe mkfs mkfs.xfs mkfs.ext4 mkfs.erofs mount umount losetup
  blockdev wipefs blkdiscard udevadm modprobe systemctl dnf docker chroot)
# Each disk writer is a stub that records its call and refuses it (exit 97) unless a case
# replaces it with one that answers.
for c in "${DISK_WRITERS[@]}"; do
  printf '#!/bin/sh\necho "%s $*" >> "$BSTUB_LOG"\necho "STUB %s: call not modelled by this case: $*" >&2\nexit 97\n' "$c" "$c" > "$BSTUB/$c"
  chmod 0755 "$BSTUB/$c"
done
# stub <name> <sh body>: a stub that records its call, then runs the body ("$@" are its arguments).
stub() {
  printf '#!/bin/sh\necho "%s $*" >> "$BSTUB_LOG"\n%s\n' "$1" "$2" > "$BSTUB/$1"
  chmod 0755 "$BSTUB/$1"
}
BPATH="$BSTUB:$PATH"
# assert_stubs <PATH>: every disk writer on that PATH is this suite's stub, else stop the suite.
assert_stubs() {
  local c p
  for c in "${DISK_WRITERS[@]}"; do
    p="$(PATH="$1" command -v "$c" 2>/dev/null || true)"
    if [[ "$p" != "$BSTUB/$c" ]]; then
      echo "ERROR: $SUITE: $c resolves to '${p:-nothing}', not $BSTUB/$c; stopping before any stage runs" >&2
      exit 2
    fi
  done
}
# lb <log> '<bash code>': source the REAL lib.sh in a fresh bash (as the stages do, with set -e),
# then run the code; sets RC. lib.sh puts $CARGO_HOME/bin first on PATH; it is checked too.
lb() {
  local log="$1" code="$2"
  assert_stubs "/work/tools/cargo/bin:$BPATH"
  run_real "$log" env PATH="$BPATH" bash -c 'set -euo pipefail; . "$1"; eval "$2"' lb "$LIB" "$code"
}

# BLOCK_NODE: a block device node the host already has, for the by-id links of the accept cases.
# The test user must be able neither to read nor to
# write it; if it can do either, the suite stops before any case. With no such node, the accept
# cases that need one are NOT RUN.
BLOCK_NODE=""
for __n in /dev/*; do
  if [[ -b "$__n" && ! -L "$__n" ]]; then BLOCK_NODE="$__n"; break; fi
done
unset __n
if [[ -n "$BLOCK_NODE" && ( -r "$BLOCK_NODE" || -w "$BLOCK_NODE" ) ]]; then
  echo "ERROR: $SUITE: the test user can read or write the block node $BLOCK_NODE; refusing to run" >&2
  exit 2
fi

echo "== 0/1 the harness refuses a disk writer that is not a stub =========================="
mkdir -p "$WORK/early"; ln -s "$WORK/sysbin/cat" "$WORK/early/dd"   # any real program named dd
( assert_stubs "$WORK/early:$BPATH" ) > "$WORK/assert.log" 2>&1
check "REJECT (harness) a PATH on which dd is not the stub: the suite would stop" 2 $? "$WORK/assert.log" "dd resolves to '$WORK/early/dd'"
( assert_stubs "$BPATH" ) > "$WORK/assert-ok.log" 2>&1
check "ACCEPT (harness) the case PATH: every disk writer is the stub" 0 $? "$WORK/assert-ok.log"

echo "== 1/1 lib.sh helpers ================================================================"
# fetch_verified: curl writes the fixture to the -o path; the digest decides.
printf 'fixture download for test-builder\n' > "$WORK/fixture.bin"
good_sha="$(sha256sum "$WORK/fixture.bin" | awk '{print $1}')"
stub curl "out=''; prev=''; for a in \"\$@\"; do [ \"\$prev\" = -o ] && out=\"\$a\"; prev=\"\$a\"; done
case \"\$*\" in *fail.example*) exit 22 ;; esac
cp '$WORK/fixture.bin' \"\$out\""
mkdir -p "$WORK/dl"
entry scripts/builder/lib.sh:fetch_verified
lb "$WORK/fv-ok.log" "fetch_verified https://downloads.example/tool '$WORK/dl/tool' $good_sha; ls '$WORK/dl'"
check "ACCEPT fetch_verified: the download has the pinned sha256 and is moved to its name" 0 "$RC" "$WORK/fv-ok.log" '^tool$'
cover accept E_DIGEST E_DOWNLOAD
rm -rf "$WORK/dl"; mkdir -p "$WORK/dl"
lb "$WORK/fv-bad.log" "fetch_verified https://downloads.example/tool '$WORK/dl/tool' $(printf '0%.0s' {1..64})"
check "REJECT fetch_verified of a download whose sha256 is not the pin" 1 "$RC" "$WORK/fv-bad.log" '^ERROR: E_DIGEST: tool does not have the pinned sha256$'
[[ ! -e "$WORK/dl/tool" ]]; check "  ... and no file is left at the target name" 0 $? "$WORK/fv-bad.log"
lb "$WORK/fv-fail.log" "fetch_verified https://fail.example/tool '$WORK/dl/tool2' $good_sha"
check "REJECT fetch_verified when curl fails" 1 "$RC" "$WORK/fv-fail.log" '^ERROR: E_DOWNLOAD: https://fail.example/tool$'
[[ ! -e "$WORK/dl/tool2" ]]; check "  ... and no file is left at the target name" 0 $? "$WORK/fv-fail.log"

# find_images: the image folder of the variant build in a fixture clone.
entry scripts/builder/lib.sh:find_images
img_tree() { # img_tree <name>: a clone whose image folder holds two images, each behind its link
  local d="$WORK/clone-$1/build/images/x86_64-aws-k8s-1.36-nitro-sandbox/latest"
  mkdir -p "$d"
  printf 'os\n' > "$d/bottlerocket-aws-k8s-1.36-nitro-sandbox-x86_64-1.70.0-abc.img.lz4"
  printf 'data\n' > "$d/bottlerocket-aws-k8s-1.36-nitro-sandbox-x86_64-1.70.0-abc-data.img.lz4"
  ln -s bottlerocket-aws-k8s-1.36-nitro-sandbox-x86_64-1.70.0-abc.img.lz4 "$d/bottlerocket-aws-k8s-1.36-nitro-sandbox-x86_64.img.lz4"
  ln -s bottlerocket-aws-k8s-1.36-nitro-sandbox-x86_64-1.70.0-abc-data.img.lz4 "$d/bottlerocket-aws-k8s-1.36-nitro-sandbox-x86_64-data.img.lz4"
  IMGD="$d"
}
img_tree good
lb "$WORK/fi-ok.log" "CLONE='$WORK/clone-good'; find_images; echo \"\$OS_IMG\"; echo \"\$DATA_IMG\""
check "ACCEPT find_images: the OS and data images are two files behind their links" 0 "$RC" "$WORK/fi-ok.log" 'x86_64-1\.70\.0-abc-data\.img\.lz4$'
cover accept E_IMAGES
lb "$WORK/fi-nodir.log" "CLONE='$WORK/clone-none'; find_images"
check "REJECT find_images when the build made no image folder" 1 "$RC" "$WORK/fi-nodir.log" '^ERROR: E_IMAGES: no .*/latest$'
img_tree missing; rm "$IMGD/bottlerocket-aws-k8s-1.36-nitro-sandbox-x86_64-data.img.lz4"
lb "$WORK/fi-missing.log" "CLONE='$WORK/clone-missing'; find_images"
check "REJECT find_images when the data image is missing" 1 "$RC" "$WORK/fi-missing.log" '^ERROR: E_IMAGES: the build has no '
img_tree same; ln -sfn bottlerocket-aws-k8s-1.36-nitro-sandbox-x86_64-1.70.0-abc.img.lz4 "$IMGD/bottlerocket-aws-k8s-1.36-nitro-sandbox-x86_64-data.img.lz4"
lb "$WORK/fi-same.log" "CLONE='$WORK/clone-same'; find_images"
check "REJECT find_images when both links name one file" 1 "$RC" "$WORK/fi-same.log" '^ERROR: E_IMAGES: the OS and data images are the same file$'

# not_in_use: lsblk lists the mount points of the device and its partitions.
entry scripts/builder/lib.sh:not_in_use
stub lsblk 'case "$*" in *MOUNTPOINT*/dev/busy*) printf "\n/mnt/data\n" ;; *MOUNTPOINT*) printf "\n\n" ;; *) exit 97 ;; esac'
lb "$WORK/nu-ok.log" "not_in_use /dev/free; echo free"
check "ACCEPT not_in_use: no mount point on the device or its partitions" 0 "$RC" "$WORK/nu-ok.log" '^free$'
cover accept E_VOLUME_IN_USE
lb "$WORK/nu-bad.log" "not_in_use /dev/busy"
check "REJECT not_in_use when a partition of the device is mounted" 1 "$RC" "$WORK/nu-bad.log" '^ERROR: E_VOLUME_IN_USE: /dev/busy or a partition of it is mounted$'

# volume_device: the reject side here; part 2 runs the accept side on the by-id folder of a fixture SYSROOT.
entry scripts/builder/lib.sh:volume_device
lb "$WORK/vd-none.log" "volume_device vol-0fb00000000000999"
check "REJECT volume_device of a volume ID with no device node" 1 "$RC" "$WORK/vd-none.log" '^ERROR: E_VOLUME_DEVICE: no block device for volume vol-0fb00000000000999$'

# ---- 2: the real stage scripts against a fixture SYSROOT ---------------------------------------
# lib.sh must take SYSROOT from the environment; without that, the stage cases are NOT RUN.
if ! grep -q '^SYSROOT="\${SYSROOT:-}"' "$LIB"; then
  not_run "every builder stage case" "lib.sh does not take SYSROOT from the environment"
  finish
fi
if [[ -z "$BLOCK_NODE" ]]; then
  not_run "every builder stage case" "this host has no block device node for the by-id links"
  finish
fi
SR="$WORK/sysroot"
OV="$SR/opt/cilium-bottlerocket/overlay"
FIX="$WORK/fix"; mkdir -p "$FIX/dl" "$FIX/dd"
export FIX_DL="$FIX/dl" FIX_DD="$FIX/dd"
VOL_WORK=vol-0fb000000000000c1 VOL_OS=vol-0fb000000000000c2 VOL_DATA=vol-0fb000000000000c3

# The runtime inputs of a good build (fixture_inputs.py), fetched once by the real verifier: the
# overlay's sources.lock pins them, and the ROOT-A fixture holds them at their install= paths.
python3 "$TESTLIB/fixture_inputs.py" "$FIX/inputs" "$FIX/sources.lock" good > "$FIX/inputs.log" 2>&1 \
  && python3 "$SAMPLE_DIR_REAL/packages/lib/runtime_verify.py" fetch "$FIX/sources.lock" "$FIX/fetched" > "$FIX/fetch.log" 2>&1 \
  || { cat "$FIX/inputs.log" "$FIX/fetch.log"; echo "ERROR: $SUITE: could not make the runtime input fixtures" >&2; exit 2; }
# The downloads of host-setup, each a small stand-in whose digest the fixture tools.lock pins.
tl() { sed -n "s/^$1=//p" "$SAMPLE_DIR_REAL/packer/tools.lock"; }
BX_V="$(tl BUILDX_VERSION)" RU_V="$(tl RUSTUP_VERSION)" TOOLCHAIN="$(tl RUST_TOOLCHAIN)"
CM_V="$(tl CARGO_MAKE_VERSION)" TL_V="$(tl TWOLITER_VERSION)"
printf '#!/bin/sh\necho "docker buildx stand-in"\n' > "$FIX_DL/buildx-$BX_V.linux-amd64"
cat > "$FIX_DL/rustup-init" <<RUSTUP
#!/bin/sh
# rustup-init stand-in: installs a rustc that reports the pinned toolchain (or FIX_RUSTC_V).
[ -z "\${FIX_RUSTUP_FAIL:-}" ] || exit 1
mkdir -p "\$CARGO_HOME/bin"
printf '#!/bin/sh\\necho "rustc \${FIX_RUSTC_V:-$TOOLCHAIN} (fixture 2026-11-01)"\\n' > "\$CARGO_HOME/bin/rustc"
chmod 0755 "\$CARGO_HOME/bin/rustc"
RUSTUP
mkdir -p "$FIX/tl/twoliter-x86_64-unknown-linux-musl"
printf '#!/bin/sh\necho "twoliter ${FIX_TWOLITER_V:-%s}"\n' "${TL_V#v}" > "$FIX/tl/twoliter-x86_64-unknown-linux-musl/twoliter"
chmod 0755 "$FIX/tl/twoliter-x86_64-unknown-linux-musl/twoliter"
tar -cJf "$FIX_DL/twoliter-x86_64-unknown-linux-musl.tar.xz" -C "$FIX/tl" twoliter-x86_64-unknown-linux-musl
printf 'cargo-make crate stand-in\n' > "$FIX_DL/cargo-make.crate"
printf 'another crate\n' > "$FIX_DL/cargo-make-bad.crate"
sha() { sha256sum "$1" | awk '{print $1}'; }
sed -e "s/^BUILDX_SHA256_LINUX_AMD64=.*/BUILDX_SHA256_LINUX_AMD64=$(sha "$FIX_DL/buildx-$BX_V.linux-amd64")/" \
    -e "s/^RUSTUP_INIT_SHA256=.*/RUSTUP_INIT_SHA256=$(sha "$FIX_DL/rustup-init")/" \
    -e "s/^TWOLITER_SHA256_X86_64=.*/TWOLITER_SHA256_X86_64=$(sha "$FIX_DL/twoliter-x86_64-unknown-linux-musl.tar.xz")/" \
    -e "s/^CARGO_MAKE_CRATE_SHA256=.*/CARGO_MAKE_CRATE_SHA256=$(sha "$FIX_DL/cargo-make.crate")/" \
    "$SAMPLE_DIR_REAL/packer/tools.lock" > "$FIX/tools.lock"

# The stage stubs. Each reads FIX_* from the environment the case gives the stage; FIX_FAIL names
# the one call that fails.
stub findmnt 'case "$*" in "-nvo SOURCE /") echo "${FIX_ROOT_SRC:-/dev/nvme0n1p1}" ;; *"-nvo SOURCE "*) echo "${FIX_WORK_SRC:-/dev/nvme2n1}" ;; *) exit 97 ;; esac'
stub lsblk 'dev=""; for a in "$@"; do dev="$a"; done
case "$*" in
  *MOUNTPOINT*) if [ "${FIX_MOUNTED:-}" = "$dev" ]; then printf "\n/mnt/data\n"; else printf "\n\n"; fi ;;
  *NAME,PARTLABEL*) printf "%s\n" "$dev"
    for p in ${FIX_PARTS:-${dev}p1:EFI-A ${dev}p2:BOTTLEROCKET-ROOT-A ${dev}p3:BOTTLEROCKET-ROOT-B}; do echo "$p" | tr ":" " "; done ;;
  *PKNAME*) echo "${FIX_ROOT_DISK:-/dev/nvme0n1}" ;;
  *"-nrpo NAME "*) printf "%s\n" "$dev"; [ "${FIX_HAS_PARTS:-}" != "$dev" ] || printf "%sp1\n" "$dev" ;;
  *) exit 97 ;;
esac'
# blkid: -s PART_ENTRY_NAME answers the partition's GPT name (FIX_PART_NAME, which may be set
# empty), -s TYPE the file system type (FIX_FSTYPE).
stub blkid 'case "$*" in
  *PART_ENTRY_NAME*) if [ "${FIX_PART_NAME+set}" = set ]; then echo "$FIX_PART_NAME"; else echo BOTTLEROCKET-ROOT-A; fi ;;
  *) echo "${FIX_FSTYPE:-}" ;;
esac'
stub df 'printf "Size\n 200G\n"'
stub blockdev 'case "$1" in
  --getsize64) echo "${FIX_DEV_BYTES:-1073741824}" ;;
  --rereadpt) [ "${FIX_FAIL:-}" != rereadpt ] || exit 1 ;;
  --flushbufs) [ "${FIX_FAIL:-}" != flushbufs ] || exit 1 ;;
  *) exit 97 ;;
esac'
stub udevadm 'exit 0'
stub modprobe 'exit 0'
stub sync 'exit 0'
stub umount 'exit 0'
stub mkfs.xfs '[ "${FIX_FAIL:-}" != mkfs ] || exit 1'
stub mount 'case "$*" in
  "-t erofs -o ro "*) [ "${FIX_FAIL:-}" != mount-root ] || exit 32
     for a in "$@"; do mnt="$a"; done; cp -a "$FIX_ROOTA/." "$mnt/" ;;
  *) [ "${FIX_FAIL:-}" != mount-work ] || exit 32 ;;
esac'
# sgdisk -p: a 1 GiB volume (2097152 sectors) with three partitions; FIX_PART_END moves the last
# end. ROOT-A is partition FIX_ROOTA_N (default 2); FIX_ROOTA_COUNT 0 renames it, 2 gives the
# third partition the ROOT-A name too.
stub sgdisk 'case "$1" in
  -v) if [ "${FIX_FAIL:-}" = sgdisk-v ]; then echo "Problem: The secondary header is not at the end of the disk."; else echo "No problems found. 0 free sectors"; fi ;;
  -p) a=BOTTLEROCKET-ROOT-A; b=BOTTLEROCKET-ROOT-B
      [ "${FIX_ROOTA_COUNT:-1}" != 0 ] || a=BOTTLEROCKET-ROOT-X
      [ "${FIX_ROOTA_COUNT:-1}" != 2 ] || b=BOTTLEROCKET-ROOT-A
      printf "Number  Start (sector)    End (sector)  Size       Code  Name\n"
      printf "   1            2048            4095   1024.0 KiB  EF00  EFI-A\n"
      printf "   %s            4096         1048575   510.0 MiB   8300  %s\n" "${FIX_ROOTA_N:-2}" "$a"
      printf "   3         1048576         %s   512.0 MiB   8300  %s\n" "${FIX_PART_END:-2097151}" "$b" ;;
  *) exit 97 ;;
esac'
# chroot: only "chroot <ROOT-A> /usr/bin/mkfs.erofs -V" is answered: the erofs-utils
# version line and "available compressors: $FIX_COMPRESSORS" (default "deflate, zstd"; set it
# empty for an empty list); FIX_FAIL=chroot makes it fail as a missing loader would.
stub chroot 'case "$*" in
  *" /usr/bin/mkfs.erofs -V")
    if [ "${FIX_FAIL:-}" = chroot ]; then echo "chroot: failed to run command /usr/bin/mkfs.erofs: No such file or directory" >&2; exit 127; fi
    echo "mkfs.erofs (erofs-utils) 1.9.4"; echo "available compressors: ${FIX_COMPRESSORS-deflate, zstd}" ;;
  *) exit 97 ;;
esac'
# uname: the real one, except -m answers FIX_UNAME_M when it is set (a builder of another arch).
stub uname "if [ \"\$1\" = -m ] && [ -n \"\${FIX_UNAME_M:-}\" ]; then echo \"\$FIX_UNAME_M\"; exit 0; fi
exec '$WORK/sysbin/uname' \"\$@\""
# readlink: the real one, except -f of a by-id link when FIX_DEV_NAME names the device the link
# should resolve to (a device name this host has no block node for, such as /dev/xvdf).
stub readlink "if [ \"\$1\" = -f ] && [ -n \"\${FIX_DEV_NAME:-}\" ]; then case \"\$2\" in */dev/disk/by-id/*) echo \"\$FIX_DEV_NAME\"; exit 0 ;; esac; fi
exec '$WORK/sysbin/readlink' \"\$@\""
# dd: the write keeps the bytes in FIX_DD/<device name>; the read-back serves them (or other bytes).
stub dd 'of=""; inf=""; count=""; for a in "$@"; do case "$a" in of=*) of="${a#of=}" ;; if=*) inf="${a#if=}" ;; count=*) count="${a#count=}" ;; esac; done
if [ -n "$of" ]; then [ "${FIX_FAIL:-}" != dd-write ] || exit 1; cat > "$FIX_DD/$(basename "$of")"; exit 0; fi
if [ -n "$inf" ]; then [ "${FIX_FAIL:-}" != dd-readback ] || { echo "other bytes"; exit 0; }; head -c "$count" "$FIX_DD/$(basename "$inf")"; exit 0; fi
exit 97'
# lz4: the fixture images are stored raw, so -dc is cat.
stub lz4 'case "$1" in -dc) cat "$2" ;; --version) echo "*** LZ4 command line interface 64-bits v1.9.4, by Yann Collet ***" ;; *) exit 97 ;; esac'
stub dnf '[ "${FIX_FAIL:-}" != dnf ] || exit 1'
stub systemctl '[ "${FIX_FAIL:-}" != systemctl ] || exit 1'
stub docker "case \"\$*\" in
  \"buildx version\") echo \"github.com/docker/buildx \${FIX_BUILDX_V:-$BX_V} 0123abcd\" ;;
  \"version --format\"*) [ \"\${FIX_FAIL:-}\" != docker-version ] || exit 1; echo \"\${FIX_DOCKER_V:-25.0.8}\" ;;
  *) exit 97 ;;
esac"
stub git "case \"\$*\" in --version) echo 'git version 2.47.1' ;; *) exec '$WORK/sysbin/git' \"\$@\" ;; esac"
stub curl 'out=""; prev=""; url=""; for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; url="$a"; done
name="$(basename "$url")"
[ "${FIX_FAIL:-}" != "curl-$name" ] || exit 22
cp "$FIX_DL/$name" "$out"'
# cargo: install (cargo-make into CARGO_HOME, its crate in the registry cache) and make (the build).
stub cargo 'case "$1" in
  install) [ "${FIX_FAIL:-}" != cargo-install ] || { echo "error: failed to compile cargo-make"; exit 101; }
    v=""; prev=""; for a in "$@"; do [ "$prev" = --version ] && v="${a#=}"; prev="$a"; done
    mkdir -p "$CARGO_HOME/registry/cache/index.crates.io-1949cf8c6b5b557f" "$CARGO_HOME/bin"
    cp "$FIX_DL/cargo-make${FIX_CRATE_BAD:+-bad}.crate" "$CARGO_HOME/registry/cache/index.crates.io-1949cf8c6b5b557f/cargo-make-$v.crate"
    printf "#!/bin/sh\nexit 0\n" > "$CARGO_HOME/bin/cargo-make"; chmod 0755 "$CARGO_HOME/bin/cargo-make" ;;
  make) [ "${FIX_FAIL:-}" != cargo-make ] || { echo "error: buildsys failed"; exit 7; }
    d="build/images/x86_64-aws-k8s-1.36-nitro-sandbox/latest"; mkdir -p "$d"
    v="bottlerocket-aws-k8s-1.36-nitro-sandbox-x86_64"
    printf "fixture OS image\n" > "$d/$v-1.70.0-fix.img.lz4"; printf "fixture data image\n" > "$d/$v-1.70.0-fix-data.img.lz4"
    ln -sf "$v-1.70.0-fix.img.lz4" "$d/$v.img.lz4"; ln -sf "$v-1.70.0-fix-data.img.lz4" "$d/$v-data.img.lz4"
    # rpm2img (Twoliter v0.27.0) writes the ROOT-A use under the key ROOT-A: used is the root
    # image size, total the partition size.
    [ -n "${FIX_NO_META:-}" ] || printf "{\"disk_usage\": {\"%s\": {\"bytes_used\": %s, \"bytes_total\": %s, \"percentage_bytes\": 50}, \"DATA\": {\"bytes_used\": 1, \"bytes_total\": 4, \"percentage_bytes\": 25}}}\n" \
      "${FIX_META_KEY:-ROOT-A}" "${FIX_ROOT_USED:-1342177280}" "${FIX_ROOT_TOTAL:-2147483648}" > "$d/artifact-metadata.json" ;;
  *) exit 97 ;;
esac'

# new_sysroot: a fresh fixture system tree: the overlay (a copy of the sample with the fixture
# tools.lock and sources.lock), the by-id links of the three builder volumes, the stores.
new_sysroot() {
  rm -rf "$SR" "$FIX_DD"; mkdir -p "$OV" "$SR/dev/disk/by-id" "$SR/mnt" "$FIX_DD"
  cp -r "$SAMPLE_DIR_REAL/packages" "$SAMPLE_DIR_REAL/packer" "$SAMPLE_DIR_REAL/variant" "$OV/"
  cp "$FIX/tools.lock" "$OV/packer/tools.lock"; cp "$FIX/sources.lock" "$OV/packages/sources.lock"
  local v
  for v in "$VOL_WORK" "$VOL_OS" "$VOL_DATA"; do ln -s "$BLOCK_NODE" "$SR/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${v/-/}"; done
}
DEV="$(readlink -f "$BLOCK_NODE")"
# stage <log> <script> [VAR=value ...]: the REAL stage script with the stubs first on PATH.
stage() {
  local log="$1" script="$2"; shift 2
  assert_stubs "$SR/work/tools/cargo/bin:$BPATH"
  run_real "$log" env PATH="$BPATH" SYSROOT="$SR" CB_WORK_VOLUME_ID="$VOL_WORK" CB_OS_VOLUME_ID="$VOL_OS" \
    CB_DATA_VOLUME_ID="$VOL_DATA" CB_SANDBOX_SLOTS=58 FIX_ROOTA="$FIX/roota" "$@" bash "$SAMPLE_DIR_REAL/scripts/builder/$script"
}

echo "== 2/6 70-release.sh =================================================================="
entry scripts/builder/70-release.sh
new_sysroot
stage "$WORK/rel.log" 70-release.sh
check "ACCEPT release: both volumes not in use, their buffers flushed" 0 "$RC" "$WORK/rel.log" '^builder: release ok$'
cover accept E_RELEASE E_VOLUME_DEVICE
stage "$WORK/rel-flush.log" 70-release.sh FIX_FAIL=flushbufs
check "REJECT release when a device buffer flush fails" 1 "$RC" "$WORK/rel-flush.log" "^ERROR: E_RELEASE: could not flush $DEV\$"
rm "$SR/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOL_DATA/-/}"
stage "$WORK/rel-nodev.log" 70-release.sh
check "REJECT release when the data volume has no device node" 1 "$RC" "$WORK/rel-nodev.log" "^ERROR: E_VOLUME_DEVICE: no block device for volume $VOL_DATA\$"
new_sysroot
stage "$WORK/rel-busy.log" 70-release.sh "FIX_MOUNTED=$DEV"
check "REJECT release when the OS volume is still mounted" 1 "$RC" "$WORK/rel-busy.log" "^ERROR: E_VOLUME_IN_USE: $DEV or a partition of it is mounted\$"
cover accept E_VOLUME_IN_USE

echo "== 3/6 60-verify-root.sh =============================================================="
entry scripts/builder/60-verify-root.sh
# roota <dir>: a ROOT-A tree as the build writes it: each install= file, the rootfs.ext4 link,
# the shim config with pcie_slots = 58 and the containerd drop-in of the package.
roota() {
  rm -rf "$1"; mkdir -p "$1"
  python3 - "$FIX/sources.lock" "$FIX/fetched" "$1" <<'PY'
import os, re, shutil, sys
lock, dl, root = sys.argv[1:4]
for block in open(lock).read().split("\n\n"):
    kv = dict(l.split("=", 1) for l in block.splitlines() if re.match(r"^[a-z_0-9]+=", l))
    m = re.fullmatch(r"(/usr/\S+) (0[0-7]{3})", kv.get("install", "none"))
    if not m:
        continue
    src = os.path.join(dl, "members", kv["id"]) if kv["kind"] == "archive-member" else os.path.join(dl, kv["file"])
    dst = root + m.group(1)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    os.chmod(dst, int(m.group(2), 8))
PY
  ln -sfn latest-disk.img "$1/usr/share/nitro-sandbox/rootfs.ext4"
  # erofs-utils and libzstd of the image: an executable mkfs.erofs and the libzstd
  # shared object with its soname link. The chroot stub answers the -V run.
  mkdir -p "$1/usr/bin" "$1/usr/lib"
  printf '#!/bin/sh\necho "mkfs.erofs stand-in"\n' > "$1/usr/bin/mkfs.erofs"; chmod 0755 "$1/usr/bin/mkfs.erofs"
  printf 'libzstd stand-in\n' > "$1/usr/lib/libzstd.so.1.5.7"; ln -sfn libzstd.so.1.5.7 "$1/usr/lib/libzstd.so.1"
  mkdir -p "$1/usr/share/factory/etc/containerd/config.d"
  printf 'runtime = "firecracker"\npcie_slots = 58\n' > "$1/usr/share/factory/etc/containerd/nitro-sandbox.toml"
  printf '[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.isolated-sandbox]\nruntime_type = "io.containerd.nitro-sandbox.v2"\n\n[plugins."io.containerd.cri.v1.images"]\ndiscard_unpacked_layers = false\n' \
    > "$1/usr/share/factory/etc/containerd/config.d/50-nitro-sandbox.toml"
}
new_sysroot; roota "$FIX/roota"
stage "$WORK/vr.log" 60-verify-root.sh
check "ACCEPT verify-root: a valid GPT inside the volume, one ROOT-A mounted read-only, every pinned file, pcie_slots = 58, the drop-in" 0 "$RC" "$WORK/vr.log" '^builder: verify-root ok$'
cover accept E_GPT E_BOUNDS E_ROOT_A E_ROOT_FILES E_ROOT_SLOTS
while IFS='~' read -r env prep rx why; do
  [[ -n "$why" ]] || continue
  new_sysroot; roota "$FIX/roota"; eval "$prep"
  # shellcheck disable=SC2086 # env is a fixed list of VAR=value words from the table
  stage "$WORK/vr-bad.log" 60-verify-root.sh $env
  check "$why" 1 "$RC" "$WORK/vr-bad.log" "$rx"
done <<CASES
FIX_FAIL=rereadpt~:~^ERROR: E_GPT: could not read the partition table of $DEV\$~REJECT verify-root when the partition table cannot be read
FIX_FAIL=sgdisk-v~:~^ERROR: E_GPT: sgdisk -v reports a problem on $DEV\$~REJECT verify-root when sgdisk -v reports a problem
FIX_PART_END=2097152~:~^ERROR: E_BOUNDS: partition BOTTLEROCKET-ROOT-B \(1048576-2097152\) is outside the volume\$~REJECT a partition that ends one sector past the volume
FIX_ROOTA_COUNT=0~:~^ERROR: E_ROOT_A: not exactly one BOTTLEROCKET-ROOT-A partition on $DEV\$~REJECT a volume whose GPT (sgdisk -p) has no BOTTLEROCKET-ROOT-A partition
FIX_ROOTA_COUNT=2~:~^ERROR: E_ROOT_A: not exactly one BOTTLEROCKET-ROOT-A partition on $DEV\$~REJECT a volume whose GPT (sgdisk -p) has two BOTTLEROCKET-ROOT-A partitions
FIX_PART_NAME=BOTTLEROCKET-ROOT-B~:~^ERROR: E_ROOT_A: ${DEV}p2 is not the BOTTLEROCKET-ROOT-A partition of $DEV\$~REJECT a partition whose own GPT name (blkid -p) is another one
FIX_PART_NAME=~:~^ERROR: E_ROOT_A: ${DEV}p2 is not the BOTTLEROCKET-ROOT-A partition of $DEV\$~REJECT a partition whose GPT name blkid cannot read (empty)
FIX_FAIL=mount-root~:~^ERROR: E_ROOT_A: could not mount ${DEV}p2 read-only as erofs\$~REJECT a ROOT-A that does not mount read-only as erofs
X=1~printf 'changed\n' >> "\$FIX/roota/usr/share/nitro-sandbox/latest-disk.img"~^ERROR: E_ROOT_FILES: a file on the root volume does not match sources.lock\$~REJECT a root whose guest disk image is not its pin
X=1~ln -sfn other.img "\$FIX/roota/usr/share/nitro-sandbox/rootfs.ext4"~^ERROR: E_ROOT_FILES: rootfs.ext4 is not a link to latest-disk.img\$~REJECT a rootfs.ext4 link to another file
X=1~sed -i 's/^pcie_slots = 58/pcie_slots = 57/' "\$FIX/roota/usr/share/factory/etc/containerd/nitro-sandbox.toml"~^ERROR: E_ROOT_SLOTS: nitro-sandbox.toml does not set pcie_slots = 58\$~REJECT a shim config with pcie_slots = 57 when SANDBOX_SLOTS is 58
X=1~sed -i 's/^discard_unpacked_layers = false/discard_unpacked_layers = true/' "\$FIX/roota/usr/share/factory/etc/containerd/config.d/50-nitro-sandbox.toml"~^ERROR: E_ROOT_FILES: the containerd drop-in is not the package one\$~REJECT a drop-in with discard_unpacked_layers = true
CASES
# On the blkid refusal, the lsblk view (kernel and udev) goes to stderr for the log.
new_sysroot; roota "$FIX/roota"; : > "$BSTUB_LOG"
stage "$WORK/vr-view.log" 60-verify-root.sh FIX_PART_NAME=BOTTLEROCKET-ROOT-B
grep -qx "${DEV}p2 BOTTLEROCKET-ROOT-A" "$WORK/vr-view.log" && ! grep -q '^mount -t erofs' "$BSTUB_LOG"
check "  ... the blkid refusal shows the lsblk NAME,PARTLABEL view on stderr, and nothing is mounted" 0 $? "$WORK/vr-view.log"
# The partition device name: <dev>p<N> for a device that ends in a digit, <dev><N> otherwise,
# as the mount stub receives it. FIX_DEV_NAME makes the by-id link resolve to that name (the
# readlink stub); ROOT-A is partition 4.
for pair in /dev/nvme3n1:/dev/nvme3n1p4 /dev/xvdf:/dev/xvdf4; do
  new_sysroot; roota "$FIX/roota"; : > "$BSTUB_LOG"
  stage "$WORK/vr-name.log" 60-verify-root.sh "FIX_DEV_NAME=${pair%%:*}" FIX_ROOTA_N=4
  check "ACCEPT ROOT-A partition 4 of ${pair%%:*}: it mounts ${pair#*:}" 0 "$RC" "$WORK/vr-name.log" '^builder: verify-root ok$'
  grep -qx "mount -t erofs -o ro ${pair#*:} $SR/mnt/cilium-bottlerocket-root" "$BSTUB_LOG" \
    && grep -qx "blkid -p -o value -s PART_ENTRY_NAME ${pair#*:}" "$BSTUB_LOG"
  check "  ... blkid and mount both receive ${pair#*:}" 0 $? "$BSTUB_LOG"
done
# erofs-utils and libzstd in ROOT-A, and the image's own mkfs.erofs lists zstd.
grep -qx 'builder: root volume mkfs.erofs: mkfs.erofs (erofs-utils) 1.9.4; available compressors: deflate, zstd' "$WORK/vr.log"
check "  ... the first verify-root logged the compressors line of the image's mkfs.erofs -V" 0 $? "$WORK/vr.log"
cover accept E_ROOT_EROFS
for list in "zstd" "zstd, deflate" "lz4, lz4hc, zstd, deflate"; do
  new_sysroot; roota "$FIX/roota"
  stage "$WORK/vr-comp.log" 60-verify-root.sh "FIX_COMPRESSORS=$list"
  check "ACCEPT a mkfs.erofs whose compressors are '$list'" 0 "$RC" "$WORK/vr-comp.log" '^builder: verify-root ok$'
done
for list in "deflate" "libzstd" ""; do
  new_sysroot; roota "$FIX/roota"
  stage "$WORK/vr-comp.log" 60-verify-root.sh "FIX_COMPRESSORS=$list"
  check "REJECT a mkfs.erofs whose compressors are '${list:-(none)}'" 1 "$RC" "$WORK/vr-comp.log" \
    "^ERROR: E_ROOT_EROFS: mkfs.erofs in ROOT-A has no zstd compressor \\(available compressors: ${list:-none}\\)\$"
done
while IFS='~' read -r prep env rx why; do
  [[ -n "$why" ]] || continue
  new_sysroot; roota "$FIX/roota"; eval "$prep"
  # shellcheck disable=SC2086 # env is a fixed list of VAR=value words from the table
  stage "$WORK/vr-erofs.log" 60-verify-root.sh $env
  check "$why" 1 "$RC" "$WORK/vr-erofs.log" "$rx"
done <<CASES
rm "\$FIX/roota/usr/bin/mkfs.erofs"~X=1~^ERROR: E_ROOT_EROFS: ROOT-A has no executable regular file /usr/bin/mkfs.erofs \(erofs-utils\)\$~REJECT a ROOT-A with no mkfs.erofs
chmod 0644 "\$FIX/roota/usr/bin/mkfs.erofs"~X=1~^ERROR: E_ROOT_EROFS: ROOT-A has no executable regular file /usr/bin/mkfs.erofs~REJECT a mkfs.erofs of mode 0644
mv "\$FIX/roota/usr/bin/mkfs.erofs" "\$FIX/roota/usr/bin/mkfs.erofs.real"; ln -s mkfs.erofs.real "\$FIX/roota/usr/bin/mkfs.erofs"~X=1~^ERROR: E_ROOT_EROFS: ROOT-A has no executable regular file /usr/bin/mkfs.erofs~REJECT a mkfs.erofs that is a symlink
rm "\$FIX/roota/usr/lib/libzstd.so.1.5.7"~X=1~^ERROR: E_ROOT_EROFS: ROOT-A has no libzstd shared object in /usr/lib \(libzstd\)\$~REJECT a dangling libzstd.so.1 link (no libzstd.so.1.5.7)
rm "\$FIX/roota/usr/lib/libzstd.so.1.5.7" "\$FIX/roota/usr/lib/libzstd.so.1"~X=1~^ERROR: E_ROOT_EROFS: ROOT-A has no libzstd shared object in /usr/lib~REJECT a ROOT-A with no libzstd
:~FIX_FAIL=chroot~^ERROR: E_ROOT_EROFS: mkfs.erofs -V did not run in ROOT-A: chroot: failed to run command~REJECT a mkfs.erofs -V that does not run in ROOT-A (chroot fails)
rm "\$FIX/roota/usr/bin/mkfs.erofs"~FIX_UNAME_M=aarch64~^ERROR: E_ROOT_EROFS: ROOT-A has no executable regular file~REJECT on an aarch64 builder too: no mkfs.erofs (the file checks run on every arch)
rm "\$FIX/roota/usr/lib/libzstd.so.1.5.7"~FIX_UNAME_M=aarch64~^ERROR: E_ROOT_EROFS: ROOT-A has no libzstd shared object~REJECT on an aarch64 builder too: no libzstd
CASES
new_sysroot; roota "$FIX/roota"; : > "$BSTUB_LOG"
stage "$WORK/vr-arm.log" 60-verify-root.sh FIX_UNAME_M=aarch64 FIX_FAIL=chroot
check "ACCEPT on an aarch64 builder: the file checks pass and mkfs.erofs -V is not run" 0 "$RC" "$WORK/vr-arm.log" '^builder: root volume mkfs.erofs: -V not run \(the builder is aarch64, not x86_64\)$'
! grep -q '^chroot ' "$BSTUB_LOG"; check "  ... no chroot call was made" 0 $? "$BSTUB_LOG"

echo "== 4/6 50-write-images.sh ============================================================="
entry scripts/builder/50-write-images.sh
# images: the clone's image folder after a good build (the cargo stub's own layout).
images() { (mkdir -p "$SR/work/bottlerocket" && cd "$SR/work/bottlerocket" && PATH="$BPATH" CARGO_HOME="$SR/work/tools/cargo" cargo make >/dev/null); }
new_sysroot; images
stage "$WORK/wi.log" 50-write-images.sh
check "ACCEPT write-images: two free targets, each image fits, written and read back with its sha256" 0 "$RC" "$WORK/wi.log" '^builder: write-images ok$'
cover accept E_TARGET E_BOUNDS E_WRITE E_IMAGES E_INPUT
[[ "$(cat "$FIX_DD/$(basename "$DEV")")" == "fixture data image" ]]
check "  ... and the dd stub holds the data image, the last one written" 0 $? "$WORK/wi.log"
while IFS='~' read -r env rx why; do
  [[ -n "$why" ]] || continue
  new_sysroot; images
  # shellcheck disable=SC2086 # env is a fixed list of VAR=value words from the table
  stage "$WORK/wi-bad.log" 50-write-images.sh $env
  check "$why" 1 "$RC" "$WORK/wi-bad.log" "$rx"
done <<CASES
FIX_ROOT_DISK=$DEV~^ERROR: E_TARGET: $VOL_OS \($DEV\) is the builder root or work volume\$~REJECT a target that is the builder root disk
FIX_WORK_SRC=$DEV~^ERROR: E_TARGET: $VOL_OS \($DEV\) is the builder root or work volume\$~REJECT a target that is the work volume
FIX_HAS_PARTS=$DEV~^ERROR: E_TARGET: $DEV already has partitions\$~REJECT a target that already has partitions
FIX_DEV_BYTES=18~^ERROR: E_BOUNDS: the data image is 19 bytes; the volume $VOL_DATA is 18 bytes\$~REJECT an image one byte larger than its volume (19 bytes on 18)
FIX_FAIL=dd-write~^ERROR: E_WRITE: writing the os image failed\$~REJECT a failed write
FIX_FAIL=dd-readback~^ERROR: E_WRITE: the os volume does not read back the image\$~REJECT a volume that reads back other bytes
CB_OS_VOLUME_ID=$VOL_DATA~^ERROR: E_INPUT: the OS and data volumes are the same\$~REJECT the same volume for OS and data
CASES
new_sysroot
stage "$WORK/wi-noimg.log" 50-write-images.sh
check "REJECT write-images when the build left no image folder" 1 "$RC" "$WORK/wi-noimg.log" '^ERROR: E_IMAGES: no .*/latest$'
new_sysroot; images
stage "$WORK/wi-fits.log" 50-write-images.sh FIX_DEV_BYTES=19
check "ACCEPT a data image of 19 bytes on a volume of 19 (an exact fit)" 0 "$RC" "$WORK/wi-fits.log" '^builder: write-images ok$'

echo "== 5/6 40-build.sh ===================================================================="
entry scripts/builder/40-build.sh
# built_tree: what overlay and host-setup leave: the variant in the clone, Twoliter and cargo-make.
built_tree() {
  mkdir -p "$SR/work/bottlerocket/variants/aws-k8s-1.36-nitro-sandbox" "$SR/work/tools/twoliter-x86_64-unknown-linux-musl" "$SR/work/tools/cargo/bin"
  printf '[package]\nname = "aws-k8s-1_36-nitro-sandbox"\n' > "$SR/work/bottlerocket/variants/aws-k8s-1.36-nitro-sandbox/Cargo.toml"
  cp "$FIX/tl/twoliter-x86_64-unknown-linux-musl/twoliter" "$SR/work/tools/twoliter-x86_64-unknown-linux-musl/"
  printf '#!/bin/sh\nexit 0\n' > "$SR/work/tools/cargo/bin/cargo-make"; chmod 0755 "$SR/work/tools/cargo/bin/cargo-make"
}
new_sysroot; built_tree
stage "$WORK/bd.log" 40-build.sh
check "ACCEPT build: cargo make exits 0, two images, the partition use read" 0 "$RC" "$WORK/bd.log" '^builder: build ok$'
cover accept E_BUILD
grep -q '^builder: partition-use ROOT-A bytes_used=1342177280 bytes_total=2147483648 percent=50$' "$WORK/bd.log" \
  && grep -qx 'builder: root-fit ROOT-A used=1342177280 total=2147483648 ok' "$WORK/bd.log"
check "  ... and it prints the ROOT-A partition use and the root-fit line (the os-image-size-gib measurement)" 0 $? "$WORK/bd.log"
cover accept E_ROOT_FIT
# ROOT-A must fit its partition; rpm2img copies it with no size check.
new_sysroot; built_tree
stage "$WORK/bd-fit-eq.log" 40-build.sh FIX_ROOT_USED=2147483648
check "ACCEPT a root image exactly the size of ROOT-A (used = total)" 0 "$RC" "$WORK/bd-fit-eq.log" '^builder: root-fit ROOT-A used=2147483648 total=2147483648 ok$'
new_sysroot; built_tree
stage "$WORK/bd-fit-over.log" 40-build.sh FIX_ROOT_USED=2147483649
check "REJECT a root image one byte larger than ROOT-A" 1 "$RC" "$WORK/bd-fit-over.log" \
  '^ERROR: E_ROOT_FIT: ROOT-A used=2147483649 total=2147483648 bytes; the root file system with the guest image pair does not fit os-image-size-gib$'
! grep -q '^builder: build ok$' "$WORK/bd-fit-over.log"
check "  ... and the stage does not report build ok" 0 $? "$WORK/bd-fit-over.log"
new_sysroot; built_tree
stage "$WORK/bd-fit-key.log" 40-build.sh FIX_META_KEY=BOTTLEROCKET-ROOT-A
check "REJECT an artifact-metadata.json with no ROOT-A key (another key name)" 1 "$RC" "$WORK/bd-fit-key.log" \
  '^ERROR: E_ROOT_FIT: artifact-metadata.json has no ROOT-A bytes_used and bytes_total$'
new_sysroot; built_tree
stage "$WORK/bd-fit-num.log" 40-build.sh FIX_ROOT_TOTAL='"two"'
check "REJECT a ROOT-A entry whose bytes_total is not a number" 1 "$RC" "$WORK/bd-fit-num.log" \
  '^ERROR: E_ROOT_FIT: artifact-metadata.json has no ROOT-A bytes_used and bytes_total$'
new_sysroot
stage "$WORK/bd-novar.log" 40-build.sh
check "REJECT build when the overlay left no variant" 1 "$RC" "$WORK/bd-novar.log" '^ERROR: E_BUILD: no variant; overlay did not pass$'
new_sysroot; built_tree
stage "$WORK/bd-fail.log" 40-build.sh FIX_FAIL=cargo-make
check "REJECT build when cargo make exits non-zero" 1 "$RC" "$WORK/bd-fail.log" '^ERROR: E_BUILD: cargo make exited 7$'
grep -q '^error: buildsys failed$' "$WORK/bd-fail.log"
check "  ... and the useful lines of the build log are on stdout" 0 $? "$WORK/bd-fail.log"
new_sysroot; built_tree
stage "$WORK/bd-meta.log" 40-build.sh FIX_NO_META=1
check "REJECT build when the build wrote no artifact-metadata.json" 1 "$RC" "$WORK/bd-meta.log" '^ERROR: E_BUILD: no partition use in .*/artifact-metadata\.json$'

echo "== 6/6 10-host-setup.sh ==============================================================="
entry scripts/builder/10-host-setup.sh
new_sysroot
stage "$WORK/hs.log" 10-host-setup.sh
check "ACCEPT host-setup: a new empty work volume mounted, packages, Docker 25 with the pinned buildx, Rust, cargo-make and Twoliter verified" 0 "$RC" "$WORK/hs.log" '^builder: host-setup ok$'
cover accept E_WORK_VOLUME E_DNF E_DOCKER E_RUST E_CARGO_MAKE E_TWOLITER E_DIGEST E_DOWNLOAD E_INPUT
while IFS='~' read -r env rx why; do
  [[ -n "$why" ]] || continue
  new_sysroot
  # shellcheck disable=SC2086 # env is a fixed list of VAR=value words from the table
  stage "$WORK/hs-bad.log" 10-host-setup.sh $env
  check "$why" 1 "$RC" "$WORK/hs-bad.log" "$rx"
done <<CASES
FIX_ROOT_SRC=$DEV~^ERROR: E_WORK_VOLUME: $DEV is the root device\$~REJECT a work volume that is the root device
FIX_FSTYPE=xfs~^ERROR: E_WORK_VOLUME: $DEV already has a file system\$~REJECT a work volume that already has a file system
FIX_MOUNTED=$DEV~^ERROR: E_VOLUME_IN_USE: $DEV or a partition of it is mounted\$~REJECT a work volume that is mounted
FIX_FAIL=dnf~^ERROR: E_DNF: the package install failed\$~REJECT a failed dnf install
FIX_FAIL=curl-buildx-$BX_V.linux-amd64~^ERROR: E_DOWNLOAD: https://github.com/docker/buildx/releases/download/~REJECT a buildx download that fails
FIX_FAIL=systemctl~^ERROR: E_DOCKER: docker did not start\$~REJECT a Docker that does not start
FIX_BUILDX_V=v0.38.0~^ERROR: E_DOCKER: docker buildx is not $BX_V\$~REJECT a docker buildx that is not the pinned version
FIX_FAIL=docker-version~^ERROR: E_DOCKER: docker does not answer\$~REJECT a Docker daemon that does not answer
FIX_DOCKER_V=19.03.15~^ERROR: E_DOCKER: Docker 19.03.15 is older than 20.10.10\$~REJECT Docker 19.03
FIX_DOCKER_V=20.10.25~^ERROR: E_DOCKER: Docker 20.10.25; this build needs 21 or later\$~REJECT Docker 20.10
FIX_RUSTUP_FAIL=1~^ERROR: E_RUST: rustup-init failed\$~REJECT a failed rustup-init
FIX_RUSTC_V=1.99.0~^ERROR: E_RUST: rustc is not $TOOLCHAIN\$~REJECT a rustc that is not the pinned toolchain
FIX_FAIL=cargo-install~^ERROR: E_CARGO_MAKE: cargo install failed\$~REJECT a failed cargo install of cargo-make
FIX_CRATE_BAD=1~^ERROR: E_CARGO_MAKE: the cargo-make crate does not have the pinned checksum\$~REJECT a cargo-make crate that is not the pinned one
FIX_TWOLITER_V=0.26.0~^ERROR: E_TWOLITER: the binary does not report $TL_V\$~REJECT a Twoliter binary that reports another version
CASES
new_sysroot; printf 'changed\n' >> "$FIX_DL/rustup-init"
stage "$WORK/hs-digest.log" 10-host-setup.sh
check "REJECT a rustup-init download that is not the pinned file" 1 "$RC" "$WORK/hs-digest.log" '^ERROR: E_DIGEST: rustup-init does not have the pinned sha256$'
[[ ! -e "$SR/work/tools/rustup-init" ]]; check "  ... and no rustup-init is left at its name" 0 $? "$WORK/hs-digest.log"
finish
