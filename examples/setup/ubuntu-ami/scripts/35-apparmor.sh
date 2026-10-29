#!/usr/bin/env bash
# 35-apparmor.sh: install and load the sample's scoped AppArmor profile onto the build host
# so the baked AMI carries it. Runs on the build host over SSM, after 31-wire-containerd.sh
# and before 50-bake-prep.sh (bake-prep must NOT remove /etc/apparmor.d).
#
# Why this stage exists: deploy/pod-apparmor-scoped.yaml, an ordinary (runc) pod, requests
# the Localhost profile `ubuntu-ami-sample-profile` (securityContext.appArmorProfile). A pod
# can only run with a profile already loaded on the node, so without loading this profile on
# the image the "accept" control would be refused exactly like the reject control
# (deploy/pod-apparmor-reject.yaml) and the acceptance criterion's "scoped profile that
# works vs a control that is refused" could not be shown. AppArmor stays enabled host-wide:
# this adds one named profile, it does not disable, replace or reconfigure the host LSM.
#
# The isolated-sandbox pod (deploy/pod-isolated-sandbox.yaml) runs Unconfined: the shim
# forwards a sandbox pod's profile into the guest, where runc applies it, and the guest has no
# AppArmor, so runc there fails with "apparmor failed to apply profile". The GA bundle says so,
# and the sample's first live node run showed it (the README's AppArmor section).
#
# The profile text lives at manifests/ubuntu-ami-sample-profile in this sample; on the build
# host the sample directory is copied under /usr/local/share/ubuntu-ami-sample, so look for
# the profile next to this script first, then at that installed location.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

PROFILE_NAME=ubuntu-ami-sample-profile
DEST="$SYSROOT/etc/apparmor.d/$PROFILE_NAME"
AA_FS="$SYSROOT/sys/kernel/security/apparmor"   # SYSROOT: clusterless tests only

command -v apparmor_parser >/dev/null 2>&1 || die "apparmor_parser not found: the apparmor package must be installed on the base AMI"
[ -d "$AA_FS" ] || die "AppArmor is not enabled on this kernel ($AA_FS absent); this sample requires AppArmor enabled host-wide"

SRC=""
for cand in \
  "$HERE/../manifests/$PROFILE_NAME" \
  "/usr/local/share/ubuntu-ami-sample/manifests/$PROFILE_NAME"; do
  [ -f "$cand" ] && { SRC="$cand"; break; }
done
[ -n "$SRC" ] || die "profile source $PROFILE_NAME not found next to this script or under /usr/local/share/ubuntu-ami-sample"

log "installing AppArmor profile $PROFILE_NAME from $SRC to $DEST"
sudo install -D -m 0644 "$SRC" "$DEST"

# Load it now, in enforce mode, and keep it loaded across reboots: apparmor.service reloads
# every profile under /etc/apparmor.d/ at boot, so the service must be enabled, and that is
# checked, not assumed. A failure of either stops the stage.
log "loading profile with apparmor_parser -r"
sudo apparmor_parser -r "$DEST" || die "apparmor_parser could not load $DEST"
sudo systemctl enable apparmor.service || die "could not enable apparmor.service; the profile would not be reloaded at boot"
enabled=$(systemctl is-enabled apparmor.service 2>/dev/null || true)
[ "$enabled" = enabled ] || die "apparmor.service is '${enabled:-unknown}' after enable, not 'enabled'; the profile would not be reloaded at boot"

# The kernel's own list of loaded profiles is the authority: the profile must be there, and in
# ENFORCE mode. A complain-mode profile only logs, so the /etc/shadow denial the sample shows
# would not happen; that is a failure here, not a pass.
mode=$(sed -n "s/^$PROFILE_NAME (\\(.*\\))\$/\\1/p" "$AA_FS/profiles" 2>/dev/null | head -n 1)
log "AppArmor profile $PROFILE_NAME mode: ${mode:-not loaded}"
[ "$mode" = enforce ] || die "AppArmor profile $PROFILE_NAME is '${mode:-not loaded}', not 'enforce'; the scoped profile would not deny what the sample says it denies"

echo "apparmor profile $PROFILE_NAME installed to /etc/apparmor.d and loaded in enforce mode; apparmor.service enabled; $(date -u +%FT%TZ)" \
  | sudo tee -a "$IMAGE_MANIFEST"

echo "APPARMOR: PASS (profile $PROFILE_NAME loaded in enforce mode; apparmor.service enabled; host AppArmor left enabled)"
