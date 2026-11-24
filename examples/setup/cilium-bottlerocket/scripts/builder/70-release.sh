#!/usr/bin/env bash
# 70-release.sh (stage release, on the builder): nothing on the OS and data volumes stays
# mounted, and their data is on the disks before Packer stops the builder and makes the
# snapshots. Inputs: CB_OS_VOLUME_ID, CB_DATA_VOLUME_ID.
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
need_volume_id CB_OS_VOLUME_ID
need_volume_id CB_DATA_VOLUME_ID
sync
for vol in "$CB_OS_VOLUME_ID" "$CB_DATA_VOLUME_ID"; do
  dev=$(volume_device "$vol")
  not_in_use "$dev"
  blockdev --flushbufs "$dev" || die "E_RELEASE: could not flush $dev"
  log "released $vol"
done
log "release ok"
