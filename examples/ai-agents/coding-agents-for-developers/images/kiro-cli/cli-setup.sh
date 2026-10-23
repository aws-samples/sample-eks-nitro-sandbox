#!/bin/sh
# Prepare Kiro CLI's home for a session. Kiro CLI signs in with the developer's own identity
# (Builder ID, Google, GitHub or an organization) through the OAuth device flow in the
# terminal (`kiro-cli login --use-device-flow`): it prints a code and a URL the developer
# opens on their own machine. The sign-in is stored under $HOME, which is the session's
# folder on S3 Files, so a restored session stays signed in. No credential is injected into
# the pod.
#
# The session entrypoint runs this as the dev user after the workspace is mounted. It is
# idempotent, so it is safe to re-run on restore.
set -eu

# --- V3 session store on a POSIX filesystem ------------------------------------------------
# The V3 agent engine locks each session with a hardlink under ~/.kiro/sessions/.../
# .lock.acquire. The S3 Files workspace mount does not support hardlinks (link() returns
# EMLINK: "too many links"), so with the session dir on the mounted home the V3 TUI loops on
# that error and never reaches the prompt. Point ~/.kiro/sessions at a pod-local tmpfs path
# instead -- hardlinks work there, and session LOCKS are runtime state that need not persist
# (V3 keeps the durable conversation server-side). Everything else under ~/.kiro and the
# workspace stays on S3 Files, so code, settings and the sign-in still persist across restore.
mkdir -p "$HOME/.kiro" /tmp/kiro-sessions
if [ ! -L "$HOME/.kiro/sessions" ]; then
  # If a real sessions dir exists from an older run, move it aside (never delete here).
  [ -e "$HOME/.kiro/sessions" ] && mv "$HOME/.kiro/sessions" "$HOME/.kiro/sessions.pre-tmpfs.$$" 2>/dev/null || true
  ln -sfn /tmp/kiro-sessions "$HOME/.kiro/sessions"
fi
