#!/usr/bin/env bash
# Run the four benign test events inside one pod. Each touches only the pod itself:
#
#   1. a shell with a terminal       kubectl exec -it ... sh, which exits at once
#   2. read /etc/shadow              the container's own copy, discarded
#   3. drop and run a new binary     a copy of /bin/true in the container's /tmp, run, removed
#   4. contact the Kubernetes API    one TCP connection, closed at once, with no request
#
# Each maps to a default Falco rule (see the page). Nothing here changes anything outside
# the pod.
#
# Usage: scripts/trigger-events.sh <pod>   # NAMESPACE defaults to runtime-detection; KUBE_CONTEXT optional
set -euo pipefail

POD=${1:?usage: scripts/trigger-events.sh <pod>}
NS=${NAMESPACE:-runtime-detection}
CTX=${KUBE_CONTEXT:-$(kubectl config current-context)}
k() { kubectl --context "$CTX" -n "$NS" exec "$POD" -c app "$@"; }

echo "[$POD] 1/4 shell with a terminal"
# kubectl allocates a terminal only when its own input is one, so `script` provides it.
shell="$(printf 'kubectl --context %q -n %q exec -it %q -c app -- sh -c %q' "$CTX" "$NS" "$POD" 'exit 0')"
if script -V > /dev/null 2>&1; then
  script -qec "$shell" /dev/null > /dev/null       # util-linux (Linux)
else
  script -q /dev/null sh -c "$shell" > /dev/null   # BSD (macOS)
fi
echo "[$POD] 2/4 read /etc/shadow"
k -- cat /etc/shadow > /dev/null
echo "[$POD] 3/4 drop and run a new binary"
k -- sh -c \
  'cp /bin/true /tmp/runtime-detection-test && /tmp/runtime-detection-test && rm /tmp/runtime-detection-test'
echo "[$POD] 4/4 contact the Kubernetes API server"
k -- python3 -c 'import os, socket
socket.create_connection((os.environ["KUBERNETES_SERVICE_HOST"],
                          int(os.environ["KUBERNETES_SERVICE_PORT"])), 5).close()'
