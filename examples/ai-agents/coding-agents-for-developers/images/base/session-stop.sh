#!/bin/sh
# Stop a session cleanly before its pod is released. The app runs this through
# `kubectl exec` on Close, on idle release and before Delete.
#
# Why: the CLIs keep SQLite databases (opencode's history, Codex's state) and lock files
# (Codex's per-thread writer lock) in the CLI's home on /workspace, an NFS mount. A lock on
# NFS is a lease the server keeps for the client. When the pod was deleted with the CLI
# still running, nothing released those locks, so the server held them until the lease
# ran out: a Restore within that time found Codex's conversation "open in another app",
# and opencode read a stale SQLite WAL index and reported "database disk image is
# malformed". Ending the processes while the pod is still up releases their locks at once,
# and unmounting flushes what they wrote.
#
# With --wipe (Delete only), it also removes everything in the folder through the mount
# before unmounting. S3 Files exports a change to the bucket only after 60 seconds with no
# writes to the file, so a file written just before Delete and removed here never reaches
# the bucket, and one already exported becomes a delete marker that Delete's drain removes.
set -u
MOUNT=/workspace
WIPE=0
[ "${1:-}" = "--wipe" ] && WIPE=1

# 1. End every process of the dev user: tmux, the CLI and any daemon the CLI started.
#    Signal as uid 1000 itself: the container drops CAP_KILL, so root cannot signal
#    another user's processes. TERM first, so a CLI can close its databases; then KILL
#    whatever is left after 10 seconds. Exiting releases the process's locks either way.
#    Count only live processes: PID 1 is `sleep infinity`, which never reaps, so a process
#    that has exited stays listed as a zombie (state Z). It holds no files and no locks.
as_dev() { setpriv --reuid=1000 --regid=1000 --init-groups --inh-caps=-all "$@"; }
live() { ps -u 1000 -o stat= 2>/dev/null | grep -vc '^Z'; }
wait_gone() {  # $1 = number of half-second checks
  i=0
  while [ "$(live)" -gt 0 ] && [ "$i" -lt "$1" ]; do sleep 0.5; i=$((i + 1)); done
}
as_dev pkill -TERM -u 1000 2>/dev/null || true
wait_gone 20
as_dev pkill -KILL -u 1000 2>/dev/null || true
wait_gone 10
if [ "$(live)" -gt 0 ]; then
  echo "session-stop: $(live) processes of uid 1000 are still running" >&2
  exit 1
fi

# 2. Flush and unmount the session's folder (root, with the SYS_ADMIN the mount used).
#    Retry for up to 30 seconds: right after the processes end, the NFS client can still be
#    closing their files, and umount reports "device is busy" until it has. On a live run
#    the first attempt after a Codex session failed that way, with no process left holding
#    the mount, and the same umount succeeded a minute later.
#    Both are bounded: on a hard NFS mount either can block while the server is
#    unreachable, and the app's exec would otherwise wait out its own two-minute timeout.
if [ "$WIPE" -eq 1 ] && mountpoint -q "$MOUNT"; then
  # As the session's user, who owns everything the CLI wrote; bounded like the rest.
  if ! as_dev timeout 60 find "$MOUNT" -mindepth 1 -delete; then
    echo "session-stop: could not remove everything in $MOUNT" >&2
    exit 1
  fi
fi
timeout 30 sync || echo "session-stop: sync did not finish in 30 seconds" >&2
if mountpoint -q "$MOUNT"; then
  # A deadline, not a count of attempts: each attempt is bounded at 10 seconds, so the whole
  # phase ends within about 40 seconds even if every attempt hangs.
  tries=0
  deadline=$(( $(date +%s) + 30 ))
  until err="$(timeout 10 umount "$MOUNT" 2>&1)"; do
    rc=$?
    tries=$((tries + 1))
    [ "$rc" -eq 124 ] && err="timed out after 10 seconds"
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "session-stop: umount $MOUNT failed after $tries attempts: $err" >&2
      exit 1
    fi
    sleep 1
  done
fi
[ "$WIPE" -eq 1 ] && echo "session-stop: $MOUNT emptied"
echo "session-stop: session processes ended and $MOUNT unmounted"
