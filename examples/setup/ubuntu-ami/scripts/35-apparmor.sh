#!/usr/bin/env bash
# 35-apparmor.sh: install and load the sample's scoped AppArmor profile onto the build host
# so the baked AMI carries it. Runs on the build host over SSM, after 31-wire-containerd.sh
# and before 50-bake-prep.sh (bake-prep must NOT remove /etc/apparmor.d).
#
# Why this stage exists: deploy/pod-isolated-sandbox.yaml requests the profile
# `localhost/ubuntu-ami-sample-profile`. The kubelet only admits a pod whose requested
# AppArmor profile is already loaded on the node, so without loading this profile on the
# image the "accept" control would be refused exactly like the reject control
# (deploy/pod-apparmor-reject.yaml) and the acceptance criterion's "scoped profile that
# works vs a control that is refused" could not be shown. AppArmor stays enabled host-wide:
# this adds one named profile, it does not disable, replace or reconfigure the host LSM.
#
# The profile text lives at manifests/ubuntu-ami-sample-profile in this sample; on the build
# host the sample directory is copied under /usr/local/share/ubuntu-ami-sample, so look for
# the profile next to this script first, then at that installed location.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

PROFILE_NAME=ubuntu-ami-sample-profile
DEST=/etc/apparmor.d/$PROFILE_NAME

command -v apparmor_parser >/dev/null 2>&1 || die "apparmor_parser not found: the apparmor package must be installed on the base AMI"
[ -d /sys/kernel/security/apparmor ] || die "AppArmor is not enabled on this kernel (/sys/kernel/security/apparmor absent); this sample requires AppArmor enabled host-wide"

SRC=""
for cand in \
  "$HERE/../manifests/$PROFILE_NAME" \
  "/usr/local/share/ubuntu-ami-sample/manifests/$PROFILE_NAME" \
  "/usr/local/share/ubuntu-ami-sample/$PROFILE_NAME"; do
  [ -f "$cand" ] && { SRC="$cand"; break; }
done
[ -n "$SRC" ] || die "profile source $PROFILE_NAME not found next to this script or under /usr/local/share/ubuntu-ami-sample"

log "installing AppArmor profile $PROFILE_NAME from $SRC to $DEST"
sudo install -m 0644 "$SRC" "$DEST"

# Load it now, and keep it loaded across reboots. apparmor.service reloads every profile
# under /etc/apparmor.d/ at boot, so enabling the service is what carries this profile onto
# every instance launched from the baked AMI.
log "loading profile with apparmor_parser -r"
sudo apparmor_parser -r "$DEST"
sudo systemctl enable apparmor.service 2>/dev/null || true

# Verify it actually loaded. aa-status lists loaded profiles; the profile must be present
# (enforce or complain). Fail the stage loudly if it is not, rather than baking an image
# whose accept-control pod would be refused at run time.
if command -v aa-status >/dev/null 2>&1; then
  loaded="$(sudo aa-status --json 2>/dev/null | python3 -c \
    'import json,sys; d=json.load(sys.stdin); print(d.get("profiles",{}).get("'"$PROFILE_NAME"'","absent"))' 2>/dev/null || true)"
else
  loaded="$(sudo grep -Fx "$PROFILE_NAME (enforce)" /sys/kernel/security/apparmor/profiles >/dev/null 2>&1 && echo enforce || echo absent)"
fi
log "AppArmor profile $PROFILE_NAME state: ${loaded:-absent}"
case "$loaded" in
  enforce|complain) : ;;
  *) die "AppArmor profile $PROFILE_NAME did not load (state: ${loaded:-absent}); the accept-control pod would be refused" ;;
esac

echo "apparmor profile $PROFILE_NAME installed to $DEST and loaded ($loaded); apparmor.service enabled; $(date -u +%FT%TZ)" \
  | sudo tee -a /etc/nip-custom-ami-manifest

echo "APPARMOR: PASS (profile $PROFILE_NAME loaded and enforcing; host AppArmor left enabled)"
