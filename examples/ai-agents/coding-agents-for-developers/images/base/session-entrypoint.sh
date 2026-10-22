#!/bin/bash
# Session entrypoint for a coding-agent sandbox pod.
#
# The pod boots warm, with no workspace. When the app claims it for a session it:
#   1. writes this session's short-lived mount credential into the pod through
#      `kubectl exec` standard input, to a memory-backed file (never a command line,
#      never the pod spec);
#   2. execs this script, which mounts the session's S3 Files access point at
#      /workspace with that credential, then starts tmux + the CLI as the dev user.
#
# Only the mount step runs as root with SYS_ADMIN. The CLI runs as uid 1000 with no
# added capabilities. The mount needs root inside the guest, which is what the sandbox
# is for: the guest kernel belongs to the pod, not the node.
#
# The app passes these as environment on the exec; none is a secret:
#   S3_FILES_FS_ID     the S3 Files file system id (fs-...)
#   S3_FILES_AP_ID     this session's access point id (fsap-...)
#   AWS_REGION         the file system's Region
#   POD_AZ_ID          the AZ id of the node this pod runs on (usw2-az1, ...)
#   CLI_CMD            the command to run in tmux (the CLI, set by each image)
# The credential arrives on stdin as an AWS credentials file body, written to
# $CRED_FILE below. The script never prints it.
set -euo pipefail

CRED_DIR=/dev/shm/session
CRED_FILE="$CRED_DIR/credentials"
MOUNT=/workspace
PROFILE=session

: "${S3_FILES_FS_ID:?set S3_FILES_FS_ID}"
: "${S3_FILES_AP_ID:?set S3_FILES_AP_ID}"
: "${AWS_REGION:?set AWS_REGION}"
: "${POD_AZ_ID:?set POD_AZ_ID}"
: "${CLI_CMD:?set CLI_CMD}"

# 1. Read the mount credential from stdin into a tmpfs file owned by root, mode 600.
#    /dev/shm is memory-backed, so the credential never touches a disk the node sees.
install -d -m 700 "$CRED_DIR"
# The credential arrives as one base64 line on stdin, newline-terminated. Reading one
# line with `read` returns as soon as the newline arrives, so this does not depend on
# the exec channel signalling end-of-input (which hangs a plain `cat`).
IFS= read -r CRED_B64 || true
if [ -z "${CRED_B64:-}" ]; then
  echo "session-entrypoint: no credential on stdin" >&2
  exit 1
fi
printf '%s' "$CRED_B64" | base64 -d > "$CRED_FILE"
chmod 600 "$CRED_FILE"
if ! grep -q '^aws_access_key_id' "$CRED_FILE"; then
  echo "session-entrypoint: credential malformed" >&2
  exit 1
fi

# 2. Mount this session's access point. The access point roots the mount at the
#    session's own folder and pins POSIX uid/gid 1000, so the dev user owns its files.
#    The credential is scoped (by the app, with an s3files:AccessPointArn session
#    policy) to this one access point, so this pod can mount only its own folder.
#
#    A freshly created access point's root folder is imported into the file system
#    lazily, on first access. Until that import lands, mount.s3files can return 0
#    without leaving a mount behind. So mount in a bounded retry loop: the first
#    attempt triggers the import, and a later attempt lands the mount. On restore the
#    folder is already imported, so the first attempt succeeds. We check the result
#    with `mountpoint`, not the mount helper's exit code, because that is what tells
#    a real mount from a silent no-op.
export AWS_SHARED_CREDENTIALS_FILE="$CRED_FILE" AWS_PROFILE="$PROFILE"
mounted=
for attempt in $(seq 1 12); do
  # Bound each attempt: on a freshly created access point the first mount can block
  # while the file system imports the access point's root folder, so kill a stuck
  # attempt and retry rather than hang the whole session. `timeout` returns 124 on a
  # kill; we judge success from `mountpoint`, not the exit code.
  timeout 20 mount.s3files "$S3_FILES_FS_ID" "$MOUNT" \
    -o "tls,iam,awsprofile=$PROFILE,region=$AWS_REGION,azid=$POD_AZ_ID,accesspoint=$S3_FILES_AP_ID" \
    || true
  if mountpoint -q "$MOUNT"; then
    mounted=yes
    echo "session-entrypoint: /workspace mounted on attempt $attempt" >&2
    break
  fi
  echo "session-entrypoint: /workspace not mounted yet (attempt $attempt), waiting for access-point import" >&2
  sleep 5
done
if [ -z "$mounted" ]; then
  echo "session-entrypoint: /workspace failed to mount after 12 attempts" >&2
  exit 1
fi

# The CLI's home lives inside /workspace, so its settings, sign-in and conversation
# history persist with the code and come back on restore. The access point creates its
# own root directory owned uid/gid 1000 (mode 0770), so the dev user owns /workspace and
# can create home. Create it as the dev user (the access point maps every client to 1000,
# so files the CLI writes are owned 1000 and come back owned 1000 on restore).
setpriv --reuid=1000 --regid=1000 --init-groups --inh-caps=-all \
  /bin/sh -c "mkdir -p '$MOUNT/home'"

# A per-session runtime directory the dev user owns, for tools that write a lock or
# socket to XDG_RUNTIME_DIR. Without this the default is /var/run, which only root can
# write, so a CLI that opens a runtime file there fails with EACCES. It is tmpfs-backed
# and per-pod, so it is not persisted with the workspace (runtime state should not be).
RUNTIME_DIR=/tmp/xdg-runtime
# Create it AS the dev user: the container runs as root but drops CAP_CHOWN, so root
# cannot chown the directory to 1000. Making it as uid 1000 gives it the right owner
# without a chown.
setpriv --reuid=1000 --regid=1000 --init-groups --inh-caps=-all \
  /bin/sh -c "mkdir -p '$RUNTIME_DIR' && chmod 700 '$RUNTIME_DIR'"

# Make the EKS Pod Identity token readable by the dev user. EKS injects the token owned
# by the container's runAsUser (root here, for the mount) with mode 0600 on a read-only
# volume, so uid 1000 cannot read it and the AWS SDK inside the CLI cannot fetch the
# model (Bedrock) credentials ("EACCES ... eks-pod-identity-token"). Copy it to a
# dev-readable tmpfs path and point the SDK's token-file variable at the copy. The token
# rotates, so refresh the copy in the background for as long as the pod lives.
POD_ID_TOKEN_SRC="${AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE:-}"
POD_ID_TOKEN_DST=/tmp/pod-identity-token
if [ -n "$POD_ID_TOKEN_SRC" ] && [ -r "$POD_ID_TOKEN_SRC" ]; then
  copy_token() { cp "$POD_ID_TOKEN_SRC" "$POD_ID_TOKEN_DST.tmp" && chmod 0644 "$POD_ID_TOKEN_DST.tmp" && mv "$POD_ID_TOKEN_DST.tmp" "$POD_ID_TOKEN_DST"; }
  copy_token || true
  # Refresh the copy every 30s (the token is valid far longer) until the pod exits.
  # Detach it fully from this exec's stdio (redirect all fds and disown) so the
  # `kubectl exec` that runs this script returns as soon as the mount and tmux are up;
  # otherwise the open pipe to the background loop keeps the exec channel open and the
  # app's startSession call hangs.
  nohup sh -c 'while :; do sleep 30; cp "$1" "$2.tmp" 2>/dev/null && chmod 0644 "$2.tmp" 2>/dev/null && mv "$2.tmp" "$2" 2>/dev/null || true; done' _ "$POD_ID_TOKEN_SRC" "$POD_ID_TOKEN_DST" </dev/null >/dev/null 2>&1 &
  export AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE="$POD_ID_TOKEN_DST"
fi

# Per-CLI setup. Each CLI image may ship /usr/local/bin/cli-setup.sh, which writes that
# CLI's provider/model configuration (for Amazon Bedrock, model $MODEL_ID) into the dev
# user's home. It runs AS the dev user, after the mount, because the home it writes to is
# the S3 Files workspace mounted above, not a path baked into the image. It is idempotent,
# so it is safe to re-run on restore.
if [ -x /usr/local/bin/cli-setup.sh ]; then
  setpriv --reuid=1000 --regid=1000 --init-groups --inh-caps=-all \
    env HOME="$MOUNT/home" AWS_REGION="$AWS_REGION" MODEL_ID="${MODEL_ID:-}" \
        XDG_CONFIG_HOME="$MOUNT/home/.config" \
        /usr/local/bin/cli-setup.sh || echo "session-entrypoint: cli-setup.sh failed (non-fatal)" >&2
fi

# 3. Drop to the dev user and start the CLI inside a tmux session. Closing the browser
#    only detaches tmux, so the CLI keeps running. The app re-attaches on reconnect.
#    Pass through only what the CLI needs; the mount credential stays with root. The XDG
#    base-directory variables point at writable paths: the cache, config, data and state
#    dirs live under the persisted home, and the runtime dir at the tmpfs path above, so
#    no tool falls back to a root-owned default like /var/run.
# Start tmux DETACHED so this exec returns while the CLI keeps running in the pod. The
# app attaches a browser terminal to the tmux session over a second exec; closing the
# browser only detaches, so the CLI runs on.
setpriv --reuid=1000 --regid=1000 --init-groups --inh-caps=-all \
  env HOME="$MOUNT/home" AWS_REGION="$AWS_REGION" CLI_CMD="$CLI_CMD" \
      AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE="${AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE:-}" \
      TERM=xterm-256color LANG=C.UTF-8 LC_ALL=C.UTF-8 \
      XDG_RUNTIME_DIR="$RUNTIME_DIR" \
      XDG_CACHE_HOME="$MOUNT/home/.cache" \
      XDG_CONFIG_HOME="$MOUNT/home/.config" \
      XDG_DATA_HOME="$MOUNT/home/.local/share" \
      XDG_STATE_HOME="$MOUNT/home/.local/state" \
      /bin/bash -lc 'mkdir -p "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"; cd "$HOME"; \
        tmux set-option -g default-terminal "tmux-256color"; \
        if tmux has-session -t agent 2>/dev/null; then \
          echo "session-entrypoint: tmux agent session already running, leaving it" >&2; \
        else \
          tmux new-session -d -s agent -x 200 -y 50 "$CLI_CMD"; \
          tmux set-option -t agent window-size latest; \
          tmux set-option -t agent aggressive-resize on; \
        fi'
