#!/usr/bin/env bash
# 50-write-images.sh (stage write-images, on the builder): write the OS image to the volume at
# /dev/xvdf and the data image to the volume at /dev/xvdb, found by their EBS volume IDs.
# Each image must fit its volume (checked before the write), and the written bytes must read
# back with the image's SHA-256.
# Inputs: CB_OS_VOLUME_ID, CB_DATA_VOLUME_ID.
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
need_volume_id CB_OS_VOLUME_ID
need_volume_id CB_DATA_VOLUME_ID
[ "$CB_OS_VOLUME_ID" != "$CB_DATA_VOLUME_ID" ] || die "E_INPUT: the OS and data volumes are the same"
find_images

root_dev=$(lsblk -nrpo PKNAME "$(findmnt -nvo SOURCE /)")
work_dev=$(findmnt -nvo SOURCE "$WORK")
for pair in "os:$CB_OS_VOLUME_ID:$OS_IMG" "data:$CB_DATA_VOLUME_ID:$DATA_IMG"; do
  IFS=: read -r name vol img <<<"$pair"
  dev=$(volume_device "$vol")
  [ "$dev" != "$root_dev" ] && [ "$dev" != "$work_dev" ] || die "E_TARGET: $vol ($dev) is the builder root or work volume"
  not_in_use "$dev"
  [ "$(lsblk -nrpo NAME "$dev" | wc -l)" = 1 ] || die "E_TARGET: $dev already has partitions"
  raw=$(lz4 -dc "$img" | wc -c)
  size=$(blockdev --getsize64 "$dev")
  [ "$raw" -gt 0 ] && [ "$raw" -le "$size" ] || die "E_BOUNDS: the $name image is $raw bytes; the volume $vol is $size bytes"
  want=$(lz4 -dc "$img" | sha256sum | awk '{print $1}')
  lz4 -dc "$img" | dd of="$dev" bs=4M conv=fsync status=none || die "E_WRITE: writing the $name image failed"
  got=$(head -c "$raw" "$dev" | sha256sum | awk '{print $1}')
  [ "$got" = "$want" ] || die "E_WRITE: the $name volume does not read back the image"
  log "wrote $name image to $vol: bytes=$raw volume_bytes=$size sha256=$want"
done
log "write-images ok"
