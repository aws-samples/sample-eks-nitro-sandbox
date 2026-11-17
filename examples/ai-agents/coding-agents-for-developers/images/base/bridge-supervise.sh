#!/bin/sh
# Keep session-bridge running for the life of the session. The entrypoint starts this as
# root, from /, with a clean environment. If the bridge exits, it is started again a second
# later: it reads the same token from /dev/shm/session/bridge-token and makes a new key and
# certificate, which the app reads back over exec when its next check fails to connect.
# Without this, a bridge that exited left the session unreachable until the app released
# it after five failed checks.
echo $$ > /dev/shm/session/bridge-supervisor.pid
while :; do
  /usr/local/bin/session-bridge
  echo "bridge-supervise: session-bridge exited ($?), starting it again" >&2
  sleep 1
done
