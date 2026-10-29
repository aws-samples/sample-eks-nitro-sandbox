#!/usr/bin/env bash
# 40-smoke.sh: boot one Firecracker enclave VM by hand, the way the shim does, and pass
# only on a successful vsock handshake with the guest agent. Runs on the build host after
# the reboot, and on any instance launched from the finished AMI.
#
# Mirror the shim precisely or this test lies: no huge pages (the GA archive's Firecracker
# refuses them for a Nitro Enclave, and the GA shim sends none), the shim's boot args, a
# read-only rootfs drive, an overlay data disk, vsock guest_cid 3, one tap network interface,
# then /enclave and InstanceStart. No /entropy: the shim never adds one. PASS is the vsock
# "CONNECT 1024" handshake answering "OK <port>", not console text.
#
# set -uo pipefail, not -e: this script tallies its own pass/fail (the put() PUT calls set
# pass=0 on failure but keep going) so it can still run its cleanup and print a result after
# a failed API call, the same continue-on-error discipline test.sh and clean.sh use. -u is
# on to catch an unset variable rather than let it silently expand empty.
#
# GA bundle note: the guest boot image is now latest.eif (the shim config's kernel_path), not a
# bare guest kernel. This hand boot passes that same path to /boot-source, as the shim does, and
# Firecracker loads it as a pre-built EIF. The guest then boots its own init and starts the agent,
# which answers the handshake within seconds once its data partition is there (see mk_overlay).
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
LOG="${LOG_DIR:-$HOME/logs}"; mkdir -p "$LOG"

# The same paths the shim config (/etc/containerd/nitro-sandbox.toml) names: the GA guest boot
# image (latest.eif, guest kernel inside) and the rootfs.ext4 symlink to latest-disk.img.
K="$NITRO_SANDBOX_IMAGE_DIR/latest.eif"; R="$NITRO_SANDBOX_IMAGE_DIR/rootfs.ext4"; FC=/usr/bin/firecracker
ls -l /dev/nitro_enclaves "$K" "$R" "$FC" || { echo "SMOKE PRECONDITION FAIL"; exit 2; }

BOOT_ARGS="console=ttyS0 reboot=k panic=1 root=/dev/vda ro init=/sbin/nitro-sandbox-agent setup-ephemeral-storage --exec-init overlay_root=vdb rootwait net.ifnames=0 quiet"
NONE_GUID=0FC63DAF-8483-4772-8E79-3D69D8477DE4   # Discoverable Partitions Spec: "Linux generic data"
case "$SHIM_DEBUG" in true|false) ;; *) echo "SMOKE PRECONDITION FAIL: SHIM_DEBUG must be true or false"; exit 2;; esac
ENCLAVE_CFG="{\"debug_mode\":${SHIM_DEBUG},\"pcie_mode\":true,\"direct_mode\":false,\"hotplug_mode\":true,\"cpu_overcommit\":true,\"cpu_accounting\":false}"

put() { local code; code=$(curl -s -o /tmp/smoke-api.out -w '%{http_code}' --unix-socket "$SOCK" -X PUT "http://localhost$1" -H 'Content-Type: application/json' -d "$2")
        echo "PUT $1 -> $code $(cat /tmp/smoke-api.out)"; [[ $code == 2* ]]; }
# The overlay data disk: a GPT with one partition over the whole disk, type "Linux generic data",
# labelled BOTTLEROCKET-DATA (the layout `sgdisk -n 1:0:0` gives: first usable LBA 34, partition
# from sector 2048 to the end). The GA guest in latest.eif is Bottlerocket-based: its storage
# units and the agent's setup-ephemeral-storage wait for /dev/disk/by-partlabel/BOTTLEROCKET-DATA
# and format it themselves, so with any other label the agent never starts. Written with sfdisk
# (package fdisk, installed on Canonical's EKS image); sgdisk (package gdisk) is not on that image.
mk_overlay() { rm -f "$1"; truncate -s 2G "$1" \
  && printf 'label: gpt\nfirst-lba: 34\ntype=%s, name="BOTTLEROCKET-DATA"\n' "$NONE_GUID" | sfdisk -q "$1" >/dev/null; }
mk_tap() { ip link del "$1" 2>/dev/null; ip tuntap add dev "$1" mode tap && ip link set "$1" up; }
agent_up() { python3 - "$1" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(2)
try:
    s.connect(sys.argv[1]); s.sendall(b"CONNECT 1024\n")
    r = s.recv(64).decode(errors="replace").strip()
    print(f"vsock handshake reply: {r!r}"); sys.exit(0 if r.startswith("OK ") else 1)
except Exception as e:
    print(f"vsock handshake: {e}"); sys.exit(1)
PY
}

SOCK=/tmp/smoke.sock; UDS=/tmp/smoke.vsock; OVL=/tmp/smoke.overlay.img; TAP=tap-smoke
rm -f "$SOCK" "$UDS"
mk_overlay "$OVL" || { echo "overlay disk creation failed"; exit 1; }
mk_tap "$TAP" || { echo "tap creation failed"; exit 1; }
"$FC" --api-sock "$SOCK" --log-path "$LOG/smoke.fc.log" --level Debug --show-level --show-log-origin > "$LOG/smoke.console" 2>&1 &
pid=$!
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
pass=1
put /machine-config '{"vcpu_count":2,"mem_size_mib":1024}' || pass=0
put /boot-source "$(printf '{"kernel_image_path":"%s","boot_args":"%s"}' "$K" "$BOOT_ARGS")" || pass=0
put /drives/rootfs "$(printf '{"drive_id":"rootfs","path_on_host":"%s","is_root_device":false,"is_read_only":true,"cache_type":"Unsafe"}' "$R")" || pass=0
put /drives/overlay "$(printf '{"drive_id":"overlay","path_on_host":"%s","is_root_device":false,"is_read_only":false,"cache_type":"Unsafe"}' "$OVL")" || pass=0
put /vsock "$(printf '{"guest_cid":3,"uds_path":"%s"}' "$UDS")" || pass=0
put /network-interfaces/eth0 "$(printf '{"iface_id":"eth0","host_dev_name":"%s","guest_mac":"06:00:ac:10:00:02"}' "$TAP")" || pass=0
put /enclave "$ENCLAVE_CFG" || pass=0
put /actions '{"action_type":"InstanceStart"}' || pass=0

up=0; t=0
if [ "$pass" = 1 ]; then
  for t in $(seq 3 3 150); do
    sleep 3
    kill -0 "$pid" 2>/dev/null || { echo "firecracker exited early"; break; }
    if agent_up "$UDS" >/tmp/smoke-agent.out 2>&1; then up=1; break; fi
  done
  cat /tmp/smoke-agent.out 2>/dev/null || true
fi
echo "--- process alive: $(kill -0 "$pid" 2>/dev/null && echo yes || echo NO); agent reachable: $up after ${t}s"
kill "$pid" 2>/dev/null; sleep 2; kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
ip link del "$TAP" 2>/dev/null; rm -f "$SOCK" "$UDS" "$OVL"

echo "smoke $(date -u +%FT%TZ): $([ "$pass" = 1 ] && [ "$up" = 1 ] && echo PASS || echo FAIL); debug_mode=${SHIM_DEBUG}" \
  | sudo tee -a "$IMAGE_MANIFEST"
[ "$pass" = 1 ] && [ "$up" = 1 ]
