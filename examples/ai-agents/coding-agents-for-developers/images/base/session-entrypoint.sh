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
cat > "$CRED_FILE"
chmod 600 "$CRED_FILE"
if ! grep -q '^aws_access_key_id' "$CRED_FILE"; then
  echo "session-entrypoint: no credential on stdin" >&2
  exit 1
fi

# 2. Mount this session's access point. The access point roots the mount at the
#    session's own folder and pins POSIX uid/gid 1000, so the dev user owns its files.
#    The credential is scoped (by the app, with an s3files:AccessPointArn session
#    policy) to this one access point, so this pod can mount only its own folder.
export AWS_SHARED_CREDENTIALS_FILE="$CRED_FILE" AWS_PROFILE="$PROFILE"
mount.s3files "$S3_FILES_FS_ID" "$MOUNT" \
  -o "tls,iam,awsprofile=$PROFILE,region=$AWS_REGION,azid=$POD_AZ_ID,accesspoint=$S3_FILES_AP_ID"
mountpoint -q "$MOUNT"

# The CLI's home lives inside /workspace, so its settings, sign-in and conversation
# history persist with the code and come back on restore.
chown dev:dev "$MOUNT" 2>/dev/null || true
install -d -o dev -g dev "$MOUNT/home"

# 3. Drop to the dev user and start the CLI inside a tmux session. Closing the browser
#    only detaches tmux, so the CLI keeps running. The app re-attaches on reconnect.
#    Pass through only what the CLI needs; the mount credential stays with root.
exec setpriv --reuid=1000 --regid=1000 --init-groups --inh-caps=-all \
  env HOME="$MOUNT/home" \
      AWS_REGION="$AWS_REGION" \
      TMUX_SESSION=agent \
      /bin/bash -lc '
        cd "$HOME"
        exec tmux new-session -s "$TMUX_SESSION" "$CLI_CMD"
      '
