#!/usr/bin/env bash
# Show that client-sandboxed runs in a sandbox, next to what client-standard shows on the
# same cluster: the kernel build, the boot (uptime matching the pod's age) and the virtio
# disks. This is the same evidence Getting started > Hello sandbox prints.
#
# Read-only: it runs uname/uptime/ls inside the two client pods and reads their age with
# kubectl get. It changes nothing. Run it after run-comparison.sh has deployed the pods.
#
# Usage: scripts/show-sandbox.sh      # takes no arguments
set -euo pipefail

for pod in client-sandboxed client-standard; do
  printf '\n=== %s ===\n' "$pod"
  printf 'runtimeClassName: %s\n' \
    "$(kubectl get pod "$pod" -o jsonpath='{.spec.runtimeClassName}')"
  kubectl exec "$pod" -- sh -c 'uname -rv; printf "uptime(s): "; cut -d" " -f1 /proc/uptime; printf "disks:     "; ls /sys/block | tr "\n" " "; echo'
  printf 'created:   '
  kubectl get pod "$pod" --no-headers -o custom-columns=CREATED:.metadata.creationTimestamp
  printf 'age:       '
  kubectl get pod "$pod" --no-headers -o custom-columns=AGE:.status.startTime | \
    awk 'NR==1{print $0}'   # startTime; compare against uptime(s) above
done

cat <<'NOTE'

The sandboxed client runs its OWN kernel: its uptime (seconds) matches the pod's age,
because the VM booted with the pod, and it sees virtio disks (vda, vdb, vdc). The
ordinary client reports the node's kernel build and uptime and the instance's nvme disks.
The kernel VERSION string may match; the build and the boot do not.
NOTE
