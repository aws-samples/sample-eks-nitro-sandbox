#!/usr/bin/env bash
# Show that the sandboxed pods run in a sandbox, and what the in-guest detector can see: the kernel it runs on, how long that kernel has
# been up, and every process it can list. With hostPID: true in a sandbox, that is the
# sandbox's own guest, not the node: no kubelet, no containerd, no other pod's processes.
#
# Read-only. Run it after scripts/run-detector.sh.
#
# Overridable: NAMESPACE (default runtime-detection), KUBE_CONTEXT (default: current).
set -euo pipefail

NAMESPACE="${NAMESPACE:-runtime-detection}"
KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
kc() { kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" "$@"; }

echo "=== app-sandboxed-detector, detector container ==="
kc get pod app-sandboxed-detector \
  -o 'jsonpath=runtimeClassName: {.spec.runtimeClassName}  hostPID: {.spec.hostPID}{"\n"}'
kc exec -i app-sandboxed-detector -c detector -- python3 - <<'EOF'
import os
print("kernel:   ", " ".join(os.uname()[2:4]))
print("uptime(s):", open("/proc/uptime").read().split()[0])
print("disks:    ", " ".join(sorted(os.listdir("/sys/block"))))
procs = []
for pid in sorted((p for p in os.listdir("/proc") if p.isdigit()), key=int):
    try:
        cmd = open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\0", b" ").decode().strip()
    except OSError:
        continue
    if cmd:  # kernel threads have no command line
        procs.append((pid, cmd))
print(f"processes with a command line: {len(procs)}")
for pid, cmd in procs:
    print(f"  {pid:>6}  {cmd[:90]}")
names = " ".join(cmd for _, cmd in procs)
for absent in ("kubelet", "containerd"):
    print(f"sees {absent}: {'yes' if absent in names else 'no'}")
# Every app pod in this blueprint runs `sleep infinity`; only this pod's own is in this guest.
print("sleep infinity processes:", sum(cmd == "sleep infinity" for _, cmd in procs))
EOF
for pod in app-sandboxed app-standard; do
  echo
  echo "=== $pod: runtimeClassName '$(kc get pod "$pod" -o 'jsonpath={.spec.runtimeClassName}')' ==="
  kc exec "$pod" -c app -- sh -c 'uname -rv; printf "uptime(s): "; cut -d" " -f1 /proc/uptime; printf "disks:     "; ls /sys/block | tr "\n" " "; echo'
done
cat <<'NOTE'

A sandboxed pod runs its own kernel build (#1), booted with the pod, so its uptime is the
pod's age and its disks are virtio (vd*). The ordinary pod shows the node's build (#2), the
node's uptime and the instance's nvme disks.
NOTE
