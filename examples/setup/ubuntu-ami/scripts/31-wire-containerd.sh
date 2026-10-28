#!/usr/bin/env bash
# 31-wire-containerd.sh: register the isolated-sandbox / confidential-sandbox runtime handlers
# in Canonical's containerd TEMPLATE, point the kubelet-eks snap's bootstrap at the CRI proxy
# socket, and order kubelet after cri-proxy.service. Runs after 30-runtime-install.sh, which
# installed the shim, its config and cri-proxy.service.
#
# On Canonical's Ubuntu EKS AMI both files are regenerated at cluster join, so the TEMPLATES
# are patched, never the live files: bootstrap.sh renders /etc/containerd/config.toml from
# /usr/local/share/eks/containerd-config.toml (config version 2), and sets kubelet's endpoint
# with `snap set kubelet-eks container-runtime-endpoint=...` from
# /usr/local/share/eks/bootstrap.sh.
#
# The node labels the isolated-sandbox RuntimeClass schedules on
# (eks.amazonaws.com/nitro-sandbox=true, sandbox.preview/nitro=true) are NOT set here: they
# are passed at join with --kubelet-extra-args in the launch template's user data
# (scripts/join-nodegroup.sh).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

EKS_SHARE=/usr/local/share/eks
TEMPLATE="$EKS_SHARE/containerd-config.toml"
BOOTSTRAP="$EKS_SHARE/bootstrap.sh"
CRI_SOCK=unix:///run/nitro-sandbox/cri-proxy.sock
CRI_TABLE='[plugins."io.containerd.grpc.v1.cri".containerd]'
test -f "$TEMPLATE"; test -f "$BOOTSTRAP"; test -x /etc/eks/bootstrap.sh
command -v containerd >/dev/null 2>&1 || die "containerd not found"

[ -e "$TEMPLATE.orig" ]  || sudo cp -p "$TEMPLATE"  "$TEMPLATE.orig"
[ -e "$BOOTSTRAP.orig" ] || sudo cp -p "$BOOTSTRAP" "$BOOTSTRAP.orig"

# --- 1. Patch the containerd TEMPLATE (v2) that bootstrap.sh renders at join ---------------
grep -q '^version = 2$' "$TEMPLATE" || die "$TEMPLATE is not containerd config 'version = 2'"
[ "$(grep -cxF "$CRI_TABLE" "$TEMPLATE")" = 1 ] || die "$TEMPLATE must have exactly one $CRI_TABLE table to put discard_unpacked_layers in"
# discard_unpacked_layers = false goes INSIDE the existing cri containerd table (a second table
# of that name is a TOML error): insert it right after that table's header line, once.
if ! grep -qE '^discard_unpacked_layers *= *false$' "$TEMPLATE"; then
  grep -qE '^discard_unpacked_layers' "$TEMPLATE" && die "$TEMPLATE already sets discard_unpacked_layers to something other than false; fix it by hand"
  sudo awk -v hdr="$CRI_TABLE" '{ print } $0 == hdr { print "discard_unpacked_layers = false" }' "$TEMPLATE" \
    | sudo tee "$TEMPLATE.new" >/dev/null
  sudo mv "$TEMPLATE.new" "$TEMPLATE"
fi
if ! grep -qxF '[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.isolated-sandbox]' "$TEMPLATE"; then
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
fi
[ "$(grep -cE '^discard_unpacked_layers *= *false$' "$TEMPLATE")" = 1 ] || die "discard_unpacked_layers = false is not in $TEMPLATE exactly once"
diff -u "$TEMPLATE.orig" "$TEMPLATE" | tee "$LOG_DIR/containerd-template.diff" || true

# Validate the template the way containerd will read it: render the placeholder bootstrap.sh
# fills, migrate v2 to the running containerd's schema, dump, and count the two handlers.
work=$(mktemp -d)
sed 's,SANDBOX_IMAGE,localhost/pause:3.10,g' "$TEMPLATE" > "$work/r.toml"
containerd -c "$work/r.toml" config migrate > "$work/migrated.toml" || { rm -rf "$work"; die "containerd config migrate rejected the patched template"; }
n=$(containerd -c "$work/migrated.toml" config dump 2>/dev/null | grep -c 'io.containerd.nitro-sandbox.v2' || true)
rm -rf "$work"
[ "$n" = 2 ] || die "containerd config dump shows $n nitro-sandbox handlers, expected 2"
echo "ok: containerd config migrate + dump shows both nitro-sandbox handlers"

# --- 2. Patch bootstrap.sh: kubelet dials cri-proxy, not containerd -----------------------
[ "$(grep -c 'container-runtime-endpoint=' "$BOOTSTRAP")" = 1 ] || die "expected exactly one container-runtime-endpoint= in $BOOTSTRAP"
sudo sed -i "s#container-runtime-endpoint=unix:///run/containerd/containerd.sock#container-runtime-endpoint=${CRI_SOCK}#" "$BOOTSTRAP"
grep -q "container-runtime-endpoint=${CRI_SOCK}" "$BOOTSTRAP" || die "$BOOTSTRAP does not set container-runtime-endpoint=${CRI_SOCK}"
bash -n "$BOOTSTRAP"
diff -u "$BOOTSTRAP.orig" "$BOOTSTRAP" | tee "$LOG_DIR/bootstrap.diff" || true

# --- 3. kubelet snap ordering: reconnect when the proxy restarts ------------------------------
[ -f /etc/systemd/system/cri-proxy.service ] || die "cri-proxy.service missing: run 30-runtime-install.sh first"
sudo mkdir -p /etc/systemd/system/snap.kubelet-eks.daemon.service.d
sudo tee /etc/systemd/system/snap.kubelet-eks.daemon.service.d/50-cri-proxy.conf >/dev/null <<'UNIT'
[Unit]
Wants=cri-proxy.service
After=cri-proxy.service
PartOf=cri-proxy.service
UNIT
sudo systemctl daemon-reload

echo "containerd handlers isolated-sandbox, confidential-sandbox in $TEMPLATE (migrate+dump: 2); discard_unpacked_layers=false; bootstrap endpoint -> $CRI_SOCK; kubelet-eks drop-in 50-cri-proxy.conf; $(date -u +%FT%TZ)" \
  | sudo tee -a "$IMAGE_MANIFEST"
