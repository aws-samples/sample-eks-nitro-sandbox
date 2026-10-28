#!/usr/bin/env bash
# 31-wire-containerd.sh: register the isolated-sandbox / confidential-sandbox runtime handlers
# in Canonical's containerd TEMPLATE, point the kubelet-eks snap's bootstrap at the CRI proxy
# socket, and order kubelet after cri-proxy.service. Runs after 30-runtime-install.sh, which
# installed the shim, its config and cri-proxy.service.
#
#   sudo scripts/31-wire-containerd.sh                 # the stage, on the build host
#   scripts/31-wire-containerd.sh --check-template FILE  # only the structural template check
#
# On Canonical's Ubuntu EKS AMI both files are regenerated at cluster join, so the TEMPLATES
# are patched, never the live files: bootstrap.sh renders /etc/containerd/config.toml from
# /usr/local/share/eks/containerd-config.toml (config version 2), and sets kubelet's endpoint
# with `snap set kubelet-eks container-runtime-endpoint=...` from
# /usr/local/share/eks/bootstrap.sh.
#
# Every check parses what it checks (scripts/lib/image_checks.py): discard_unpacked_layers is
# read from the existing [plugins."io.containerd.grpc.v1.cri".containerd] table itself (not
# anywhere in the file), each named handler is validated field by field in the template AND in
# containerd's own migrated config dump, the endpoint is the one active assignment in
# bootstrap.sh, and the drop-in's directives are read with comments stripped.
#
# The node labels the isolated-sandbox RuntimeClass schedules on are NOT set here: they are passed
# at join with --kubelet-extra-args in the launch template's user data (scripts/join-nodegroup.sh).
# SYSROOT (scripts/lib/common.sh) prefixes every system path, for the clusterless tests only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
PY="${PYTHON:-python3}"
CHECK="$HERE/lib/image_checks.py"

if [ "${1:-}" = --check-template ]; then
  [ -s "${2:-}" ] || die "usage: 31-wire-containerd.sh --check-template <file>"
  "$PY" "$CHECK" template "$2"; exit $?
fi
[ $# -eq 0 ] || die "unknown argument: $1 (supported: --check-template <file>)"

EKS_SHARE="$SYSROOT/usr/local/share/eks"
TEMPLATE="$EKS_SHARE/containerd-config.toml"
BOOTSTRAP="$EKS_SHARE/bootstrap.sh"
EKS_BOOTSTRAP="$SYSROOT/etc/eks/bootstrap.sh"
SYSTEMD_DIR="$SYSROOT/etc/systemd/system"
CRI_SOCK=unix:///run/nitro-sandbox/cri-proxy.sock
CRI_TABLE='[plugins."io.containerd.grpc.v1.cri".containerd]'
[ -f "$TEMPLATE" ] || die "$TEMPLATE missing"
[ -f "$BOOTSTRAP" ] || die "$BOOTSTRAP missing"
[ -x "$EKS_BOOTSTRAP" ] || die "$EKS_BOOTSTRAP missing or not executable"
command -v containerd >/dev/null 2>&1 || die "containerd not found"

[ -e "$TEMPLATE.orig" ]  || sudo cp -p "$TEMPLATE"  "$TEMPLATE.orig"
[ -e "$BOOTSTRAP.orig" ] || sudo cp -p "$BOOTSTRAP" "$BOOTSTRAP.orig"

# --- 1. Patch the containerd TEMPLATE (v2) that bootstrap.sh renders at join ---------------
# Where discard_unpacked_layers stands IN the cri containerd table: absent, false, or other.
state=$("$PY" - "$TEMPLATE" <<'PY'
import sys, tomllib
try:
    doc = tomllib.loads(open(sys.argv[1]).read())
except tomllib.TOMLDecodeError as e:
    print("invalid " + str(e).replace("\n", " ")); sys.exit()
if doc.get("version") != 2:
    print("not-v2"); sys.exit()
cri = ((doc.get("plugins") or {}).get("io.containerd.grpc.v1.cri") or {}).get("containerd")
if not isinstance(cri, dict):
    print("no-table")
elif "discard_unpacked_layers" not in cri:
    print("absent")
else:
    print("false" if cri["discard_unpacked_layers"] is False else "other")
PY
)
case "$state" in
  absent)
    # Insert it right after the table's own header line (a second table of that name is a TOML
    # error), once; the header must appear exactly once as a line of its own.
    [ "$(grep -cxF "$CRI_TABLE" "$TEMPLATE")" = 1 ] || die "$TEMPLATE must have exactly one '$CRI_TABLE' header line to put discard_unpacked_layers under"
    awk -v hdr="$CRI_TABLE" '{ print } $0 == hdr { print "discard_unpacked_layers = false" }' "$TEMPLATE" \
      | sudo tee "$TEMPLATE.new" >/dev/null
    sudo mv "$TEMPLATE.new" "$TEMPLATE" ;;
  false) ;;
  other) die "$TEMPLATE sets discard_unpacked_layers to something other than false in the cri containerd table; fix it by hand" ;;
  not-v2) die "$TEMPLATE is not containerd config 'version = 2'" ;;
  no-table) die "$TEMPLATE has no $CRI_TABLE table" ;;
  *) die "$TEMPLATE is not valid TOML ($state)" ;;
esac
handlers_present=$("$PY" - "$TEMPLATE" <<'PY'
import sys, tomllib
cri = tomllib.loads(open(sys.argv[1]).read())["plugins"]["io.containerd.grpc.v1.cri"]["containerd"]
print(" ".join(n for n in ("isolated-sandbox", "confidential-sandbox") if n in (cri.get("runtimes") or {})))
PY
)
case "$handlers_present" in
  "")
    sudo tee -a "$TEMPLATE" >/dev/null <<'TOML'

# --- ubuntu-ami sample (scripts/31-wire-containerd.sh): Nitro Sandbox runtime handlers.
# bootstrap.sh renders THIS file into /etc/containerd/config.toml at cluster join.
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.isolated-sandbox]
runtime_type = "io.containerd.nitro-sandbox.v2"
sandboxer = "shim"
privileged_without_host_devices = true

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.confidential-sandbox]
runtime_type = "io.containerd.nitro-sandbox.v2"
sandboxer = "shim"
privileged_without_host_devices = true
TOML
    ;;
  "isolated-sandbox confidential-sandbox") ;;   # a re-run: validated below
  *) die "$TEMPLATE already defines only some of the handlers ($handlers_present); fix it by hand" ;;
esac
"$PY" "$CHECK" template "$TEMPLATE" || die "the patched template $TEMPLATE failed its structural check"
diff -u "$TEMPLATE.orig" "$TEMPLATE" | tee "$LOG_DIR/containerd-template.diff" || true

# Validate the template the way containerd will read it: render the placeholder bootstrap.sh
# fills, migrate v2 to the running containerd's schema, dump, and check each named handler.
work=$(mktemp -d)
sed 's,SANDBOX_IMAGE,localhost/pause:3.10,g' "$TEMPLATE" > "$work/r.toml"
containerd -c "$work/r.toml" config migrate > "$work/migrated.toml" || { rm -rf "$work"; die "containerd config migrate rejected the patched template"; }
containerd -c "$work/migrated.toml" config dump > "$work/dump.toml" || { rm -rf "$work"; die "containerd config dump failed on the migrated template"; }
"$PY" "$CHECK" dump "$work/dump.toml" || { rm -rf "$work"; die "containerd's own config dump does not carry both handlers correctly"; }
rm -rf "$work"

# --- 2. Patch bootstrap.sh: kubelet dials cri-proxy, not containerd -----------------------
sudo sed -i "s#container-runtime-endpoint=unix:///run/containerd/containerd.sock#container-runtime-endpoint=${CRI_SOCK}#" "$BOOTSTRAP"
"$PY" "$CHECK" bootstrap "$BOOTSTRAP" || die "$BOOTSTRAP does not set the cri-proxy endpoint exactly once"
bash -n "$BOOTSTRAP"
diff -u "$BOOTSTRAP.orig" "$BOOTSTRAP" | tee "$LOG_DIR/bootstrap.diff" || true

# --- 3. kubelet snap ordering: reconnect when the proxy restarts ------------------------------
[ -f "$SYSTEMD_DIR/cri-proxy.service" ] || die "cri-proxy.service missing: run 30-runtime-install.sh first"
"$PY" "$CHECK" cri-unit "$SYSTEMD_DIR/cri-proxy.service" || die "cri-proxy.service is not the unit 30-runtime-install.sh writes"
DROPIN="$SYSTEMD_DIR/snap.kubelet-eks.daemon.service.d/50-cri-proxy.conf"
sudo mkdir -p "$(dirname "$DROPIN")"
sudo tee "$DROPIN" >/dev/null <<'UNIT'
[Unit]
Wants=cri-proxy.service
After=cri-proxy.service
PartOf=cri-proxy.service
UNIT
"$PY" "$CHECK" dropin "$DROPIN" || die "the kubelet-eks drop-in $DROPIN failed its check"
sudo systemctl daemon-reload

echo "containerd handlers isolated-sandbox, confidential-sandbox in $TEMPLATE (checked in the template and in containerd's migrated dump); discard_unpacked_layers=false in the cri containerd table; bootstrap endpoint -> $CRI_SOCK; kubelet-eks drop-in 50-cri-proxy.conf; $(date -u +%FT%TZ)" \
  | sudo tee -a "$IMAGE_MANIFEST"
