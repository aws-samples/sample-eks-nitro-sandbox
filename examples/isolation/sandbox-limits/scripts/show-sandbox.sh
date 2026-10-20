#!/usr/bin/env bash
# Show that probe-sandboxed runs in a sandbox, next to what probe-standard shows on
# the same cluster: the kernel build, the boot (uptime matching the pod's age) and
# the virtio disks. This is the same evidence Getting started > Hello sandbox prints.
#
# Read-only: it runs uname/uptime/ls inside the two probe pods and reads their
# runtime class with kubectl get. It changes nothing. Run it after run-comparison.sh
# has deployed the pods.
#
# Usage: scripts/show-sandbox.sh      # takes no arguments
set -euo pipefail

NS=sandbox-limits

for pod in probe-sandboxed probe-standard; do
  printf '\n=== %s ===\n' "$pod"
  printf 'runtimeClassName: %s\n' \
    "$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.runtimeClassName}')"
  kubectl -n "$NS" exec "$pod" -- sh -c 'uname -rv; printf "uptime(s): "; cut -d" " -f1 /proc/uptime; printf "disks:     "; ls /sys/block | tr "\n" " "; echo'
done

cat <<'NOTE'

The sandboxed probe runs its OWN kernel: its uptime (seconds) matches the pod's
age, because the VM booted with the pod, and it sees virtio disks (vda, vdb, vdc).
The ordinary probe reports the node's kernel build and uptime and the instance's
nvme disks. The kernel version string may match; the build and the boot do not.
NOTE
