# Shared base image for every coding-agent session pod.
#
# It carries the S3 Files mount helper (amazon-efs-utils, with botocore so the helper
# can resolve the mount target), tmux, git, and the session entrypoint. Each CLI image
# is FROM this base and adds one agent CLI (see ../claude-code, ../codex, ...).
#
# Amazon Linux 2023 so the efs-utils installer is supported; the mount helper is the
# one piece the sample cannot get from a generic base.
FROM public.ecr.aws/amazonlinux/amazonlinux:2023

# tmux keeps the CLI running after the browser detaches; git is what the agents use;
# shadow-utils gives us useradd; procps-ng/iproute help when reading pod state.
# curl-minimal is preinstalled and conflicts with curl, so do not install curl.
RUN set -eu; \
    dnf install -y \
        ca-certificates tar gzip unzip jq \
        tmux git openssh-clients \
        stunnel nfs-utils \
        python3 python3-pip python3-botocore \
        shadow-utils procps-ng iproute; \
    dnf clean all

# amazon-efs-utils provides /sbin/mount.s3files. The installer pulls the latest release,
# which is >= 3.0.0 and carries S3 Files support. Pinned by the running version, which
# the README records from the build.
RUN set -eu; \
    curl -fsSL https://amazon-efs-utils.aws.com/efs-utils-installer.sh -o /tmp/efs-installer.sh; \
    sh /tmp/efs-installer.sh --install; \
    rm -f /tmp/efs-installer.sh; \
    test -x /sbin/mount.s3files

# An unprivileged user for the CLI. uid/gid 1000 matches the S3 Files access point's
# POSIX user, so files the agent writes are owned by the access point's identity.
RUN set -eu; \
    groupadd -g 1000 dev; \
    useradd -m -u 1000 -g 1000 -s /bin/bash dev; \
    mkdir -p /workspace; \
    chown dev:dev /workspace

COPY --chmod=0755 session-entrypoint.sh /usr/local/bin/session-entrypoint.sh

# A warm pod boots with NO session: it just idles here. When the app claims the pod it
# runs session-entrypoint.sh through `kubectl exec`, passing the session parameters and
# the mount credential, and that script mounts the access point (as root, with SYS_ADMIN
# inside the guest) and starts tmux + the CLI as the dev user. The guest kernel belongs
# to the pod, so the root the mount uses is the pod's own, not the node's.
CMD ["sleep", "infinity"]
