#!/usr/bin/env bash
# 31-wire-containerd.sh: register the isolated-sandbox / confidential-sandbox runtime
# handlers in Canonical's containerd TEMPLATE, and point Ubuntu's kubelet-eks snap bootstrap
# at the CRI proxy socket. Both files are the Ubuntu analogue of what nodeadm's config
# rendering does on AL2023: anything written directly to /etc/containerd/config.toml or
# passed as kubelet extra-args is overwritten at cluster join, because bootstrap.sh renders
# the TEMPLATE fresh every time. Patch the sources, not the outputs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

EKS_SHARE=/usr/local/share/eks
TEMPLATE="$EKS_SHARE/containerd-config.toml"
BOOTSTRAP="$EKS_SHARE/bootstrap.sh"
CRI_SOCK=unix:///run/nitro-sandbox/cri-proxy.sock
test -f "$TEMPLATE"; test -f "$BOOTSTRAP"; test -x /etc/eks/bootstrap.sh

[ -e "$TEMPLATE.orig" ]  || sudo cp -p "$TEMPLATE"  "$TEMPLATE.orig"
[ -e "$BOOTSTRAP.orig" ] || sudo cp -p "$BOOTSTRAP" "$BOOTSTRAP.orig"

# --- 1. Patch the containerd TEMPLATE (v2) that bootstrap.sh renders at join ---------------
if ! grep -q '^\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.isolated-sandbox\]$' "$TEMPLATE"; then
  sudo sed -i '/^default_runtime_name = "runc"$/a discard_unpacked_layers = false' "$TEMPLATE"
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
grep -q '^version = 2$' "$TEMPLATE"
grep -q '^discard_unpacked_layers = false$' "$TEMPLATE"
diff -u "$TEMPLATE.orig" "$TEMPLATE" | tee "$LOG_DIR/containerd-template.diff" || true

# --- 2. Patch bootstrap.sh: kubelet dials cri-proxy, not containerd -----------------------
[ "$(grep -c 'container-runtime-endpoint=' "$BOOTSTRAP")" = 1 ]
sudo sed -i "s#container-runtime-endpoint=unix:///run/containerd/containerd.sock#container-runtime-endpoint=${CRI_SOCK}#" "$BOOTSTRAP"
grep -q "container-runtime-endpoint=${CRI_SOCK}" "$BOOTSTRAP"
bash -n "$BOOTSTRAP"
diff -u "$BOOTSTRAP.orig" "$BOOTSTRAP" | tee "$LOG_DIR/bootstrap.diff" || true

# --- 3. cri-proxy unit + kubelet snap ordering ----------------------------------------------
sudo tee /etc/systemd/system/cri-proxy.service >/dev/null <<UNIT
[Unit]
Description=Nitro Sandbox CRI proxy
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/containerd-shim-nitro-sandbox-v2 cri-proxy --listen /run/nitro-sandbox/cri-proxy.sock --containerd /run/containerd/containerd.sock
Restart=always
RuntimeDirectory=nitro-sandbox

[Install]
WantedBy=multi-user.target
UNIT
sudo mkdir -p /etc/systemd/system/snap.kubelet-eks.daemon.service.d
sudo tee /etc/systemd/system/snap.kubelet-eks.daemon.service.d/50-cri-proxy.conf >/dev/null <<'UNIT'
[Unit]
Wants=cri-proxy.service
After=cri-proxy.service
PartOf=cri-proxy.service
UNIT
sudo systemctl daemon-reload
sudo systemctl enable cri-proxy.service

# --- 4. shim config --------------------------------------------------------------------------
sudo tee /etc/containerd/nitro-sandbox.toml >/dev/null <<TOML
# Written by scripts/31-wire-containerd.sh.
nitro_sandbox = true
kernel_path   = "${NITRO_SANDBOX_DIR_INSTALL}/vmlinuz"
rootfs_path   = "${NITRO_SANDBOX_DIR_INSTALL}/rootfs.ext4"
# debug = true routes the guest console to the shim log and makes every sandbox a
# DEBUG-MODE enclave (PCR0/1/2/5/8 all read zero). Attestation from such a node is
# meaningless; this sample makes no attestation claim. Set false for anything but a demo.
debug         = ${SHIM_DEBUG}
cpu_overcommit = true
TOML

echo "containerd handlers isolated-sandbox, confidential-sandbox appended to $TEMPLATE (.orig kept); bootstrap endpoint -> $CRI_SOCK (.orig kept); cri-proxy.service enabled; debug=${SHIM_DEBUG}; $(date -u +%FT%TZ)" \
  | sudo tee -a /etc/nip-custom-ami-manifest
