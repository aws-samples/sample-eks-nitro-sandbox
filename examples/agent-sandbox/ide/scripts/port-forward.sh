#!/usr/bin/env bash
# Open the editor on this machine, and nowhere else.
#
#   ./scripts/port-forward.sh        # then browse http://localhost:8080
#
# kubectl port-forward listens on 127.0.0.1 on the machine you run it from and
# tunnels to the pod through the Kubernetes API server, so the editor is reachable
# from this machine only. Nothing in the cluster publishes its port: there is no
# Ingress, no LoadBalancer and no NodePort, and the egress policy denies all
# ingress to the pod. Press Ctrl-C to close the tunnel.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

require_commands kubectl
show_context
require_our_namespace

resource_exists kc "sandbox/$SANDBOX" \
  || die "sandbox/$SANDBOX is not there (or could not be read); run ./scripts/setup.sh first"

echo
echo "Open http://localhost:$IDE_PORT in your browser on this machine."
if [[ -f "$PASSWORD_FILE" ]]; then
  echo "The password is in $(rel "$PASSWORD_FILE") (cat it when the login page asks)."
fi
echo "Press Ctrl-C to close the tunnel."
echo
# --address 127.0.0.1 is kubectl's default, named here so it is obvious the tunnel
# is not offered to anything else on the network. kc is a shell function, so this
# is a plain call and not an exec: Ctrl-C still ends the tunnel and the script.
kc port-forward --address 127.0.0.1 "pod/$SANDBOX" "$IDE_PORT:$IDE_PORT"
