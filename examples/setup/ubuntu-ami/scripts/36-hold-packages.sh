#!/usr/bin/env bash
# 36-hold-packages.sh: keep unattended upgrades from replacing what this image pins, while leaving
# the base AMI's update policy (package-list refresh and unattended security upgrades) as it is.
# Runs on the build host after 35-apparmor.sh and before 40-smoke.sh and verify-image.py.
#
# Held, with `apt-mark hold` AND listed in Unattended-Upgrade::Package-Blacklist
# (/etc/apt/apt.conf.d/51ubuntu-ami-sample-holds):
#   * the package that owns /usr/bin/containerd (read with dpkg -S, so the name is the base
#     image's own: containerd-app on Ubuntu 24.04): the GA shim runs only on containerd 2.1.x to
#     2.3.x and an upgrade to 2.4 would leave it on a containerd it refuses;
#   * the installed Ubuntu kernel META-packages (linux-aws, linux-image-aws, linux-generic and
#     the like; never a versioned linux-image-<x.y.z-n>-... package): they pull newer stock
#     kernels, which sort ahead of 6.18.56-nitro-ga and are what GRUB boots if the pinned entry
#     is ever lost, and which fill /boot. 10-kernel.sh pins the default by entry id.
# Everything else keeps receiving updates. The trade-off, stated in the README: the held
# packages get security fixes only through a new AMI build.
#
# It records the held names in /usr/local/share/ubuntu-ami-sample/held-packages, which
# scripts/verify-image.py checks against `apt-mark showhold` and the blacklist file.
# SYSROOT (scripts/lib/common.sh) prefixes the written paths, for the clusterless tests only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
HELD_LIST="$SYSROOT/usr/local/share/ubuntu-ami-sample/held-packages"
UU_CONF="$SYSROOT/etc/apt/apt.conf.d/51ubuntu-ami-sample-holds"

# --- the package that owns containerd ---------------------------------------------------------
ctr=$(command -v containerd) || die "containerd not found on the PATH"
ctr_real=$(readlink -f "$ctr")
owner=$(dpkg -S "$ctr_real" 2>/dev/null | head -n 1 | cut -d: -f1) || true
[[ "$owner" =~ ^[a-z0-9][a-z0-9.+-]+$ ]] || die "no Debian package owns $ctr_real (dpkg -S); refusing to bake an image whose containerd cannot be held"
held=("$owner")

# --- installed kernel meta-packages -------------------------------------------------------------
# The query's output and exit status are captured first: a process substitution's failure never
# reaches set -e or pipefail, and would leave only containerd held.
dpkg_rc=0
pkg_list=$(dpkg-query -W -f='${Package} ${db:Status-Status}\n') || dpkg_rc=$?
[ "$dpkg_rc" = 0 ] || die "dpkg-query failed (exit $dpkg_rc); cannot list the installed kernel meta-packages to hold"
while read -r pkg status; do
  [ "$status" = installed ] || continue
  [[ "$pkg" =~ ^linux-(image-|headers-|modules-|modules-extra-|tools-)?(aws|generic|virtual|kvm)([-.a-z0-9]*)?$ ]] || continue
  [[ "$pkg" =~ [0-9]+\.[0-9]+\.[0-9]+-[0-9]+ ]] && continue   # a versioned kernel, not a meta-package
  held+=("$pkg")
done <<<"$pkg_list"
[ "${#held[@]}" -gt 1 ] || die "dpkg-query lists no installed Ubuntu kernel meta-package (linux-aws, linux-image-aws, linux-generic and the like); refusing to bake an image whose stock kernel updates cannot be held"
log "holding: ${held[*]}"

sudo apt-mark hold "${held[@]}" >/dev/null || die "apt-mark hold failed for: ${held[*]}"
shown=$(apt-mark showhold) || die "could not read apt-mark showhold"
for p in "${held[@]}"; do
  printf '%s\n' "$shown" | grep -qxF -- "$p" || die "$p is not held after apt-mark hold"
done

# Unattended-Upgrade::Package-Blacklist entries are regular expressions: anchor and escape each name.
sudo install -d -m 0755 "$(dirname "$UU_CONF")" "$(dirname "$HELD_LIST")"
{
  echo "// Written by scripts/36-hold-packages.sh (ubuntu-ami sample). These packages are pinned by the"
  echo "// image (containerd for the Nitro sandbox shim; the kernel meta-packages next to the built"
  echo "// 6.18.56-nitro-ga kernel) and are updated by rebuilding the AMI, not by unattended upgrades."
  echo "// Every other package keeps the base AMI's update policy."
  echo "Unattended-Upgrade::Package-Blacklist {"
  for p in "${held[@]}"; do printf '    "^%s$";\n' "$(printf '%s' "$p" | sed 's/[.+]/\\&/g')"; done
  echo "};"
} | sudo tee "$UU_CONF" >/dev/null
printf '%s\n' "${held[@]}" | sudo tee "$HELD_LIST" >/dev/null
sudo chmod 0644 "$UU_CONF" "$HELD_LIST"

echo "held (apt-mark hold + Unattended-Upgrade::Package-Blacklist): ${held[*]}; base update policy unchanged; $(date -u +%FT%TZ)" \
  | sudo tee -a "$IMAGE_MANIFEST"
echo "HOLDS: PASS (${#held[@]} package(s) held: ${held[*]})"
