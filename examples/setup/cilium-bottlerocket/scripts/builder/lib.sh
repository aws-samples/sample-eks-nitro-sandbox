# shellcheck shell=bash disable=SC2034  # the stage scripts use these variables
# lib.sh: shared helpers of the stage scripts that run on the Amazon Linux 2023 builder.
# scripts/packer-stage.sh sends each stage as one SSM Run Command, run as root.

OVERLAY=/opt/cilium-bottlerocket/overlay   # the uploaded sample files (stage upload)
WORK=/work                                 # the work volume (/dev/xvdc), mounted in host-setup
CLONE=$WORK/bottlerocket                   # the Bottlerocket clone
INPUTS=$WORK/inputs                        # the verified downloads
TOOLS=$WORK/tools
LOCK=$OVERLAY/packages/sources.lock
TOOLS_LOCK=$OVERLAY/packer/tools.lock
VARIANT=aws-k8s-1.36-nitro-sandbox
export RUSTUP_HOME=$TOOLS/rustup CARGO_HOME=$TOOLS/cargo
export HOME="${HOME:-/root}"   # SSM Run Command may start the script with no HOME
export PATH=$CARGO_HOME/bin:$PATH

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "builder: $*"; }

# tool_lock <key>: the one value of <key> in packer/tools.lock.
tool_lock() {
  local n
  n=$(grep -c "^$1=" "$TOOLS_LOCK" || true)
  [ "$n" = 1 ] || die "E_TOOLS_LOCK: $1 must appear exactly once in tools.lock"
  sed -n "s/^$1=//p" "$TOOLS_LOCK"
}

# lock_field <id> <key>: one value of one block of packages/sources.lock.
lock_field() { python3 -I "$OVERLAY/packages/lib/runtime_verify.py" field "$LOCK" "$1" "$2"; }

# need_volume_id <name>: the variable holds an EBS volume ID.
need_volume_id() {
  [[ "${!1:-}" =~ ^vol-[0-9a-f]{8,17}$ ]] || die "E_INPUT: $1 is not a volume ID"
}

# volume_device <volume-id>: the NVMe device of an attached EBS volume, by its serial.
volume_device() {
  local p="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${1/-/}"
  [ -b "$p" ] || die "E_VOLUME_DEVICE: no block device for volume $1"
  readlink -f "$p"
}

# not_in_use <device>: no mount and no mounted partition on it.
not_in_use() {
  if lsblk -nrpo MOUNTPOINT "$1" | grep -q .; then die "E_VOLUME_IN_USE: $1 or a partition of it is mounted"; fi
}

# fetch_verified <url> <file> <sha256>: download over HTTPS and check the digest.
fetch_verified() {
  curl -fsSL --proto '=https' --tlsv1.2 --max-time 1800 -o "$2.part" "$1" || die "E_DOWNLOAD: $1"
  [ "$(sha256sum "$2.part" | awk '{print $1}')" = "$3" ] || die "E_DIGEST: $(basename "$2") does not have the pinned sha256"
  mv "$2.part" "$2"
}

# find_images: the OS and data images of the build. Twoliter's imghelper writes one file per
# image and three links to it; the link without a version names it.
find_images() {
  IMG_DIR="$CLONE/build/images/x86_64-$VARIANT/latest"
  local os="$IMG_DIR/bottlerocket-$VARIANT-x86_64.img.lz4" data="$IMG_DIR/bottlerocket-$VARIANT-x86_64-data.img.lz4"
  [ -d "$IMG_DIR" ] || die "E_IMAGES: no $IMG_DIR"
  [ -f "$os" ] && [ -f "$data" ] || die "E_IMAGES: the build has no $(basename "$os") or $(basename "$data")"
  OS_IMG=$(readlink -f "$os"); DATA_IMG=$(readlink -f "$data")
  [ "$OS_IMG" != "$DATA_IMG" ] || die "E_IMAGES: the OS and data images are the same file"
}
