#!/bin/sh
# Configure Codex to use Amazon Bedrock, authenticating ambiently through the pod's Pod
# Identity (no API key). Codex has a built-in `amazon-bedrock` provider that reaches the
# Bedrock "Mantle" OpenAI-compatible endpoint (https://bedrock-mantle.<region>.api.aws/
# openai/v1) and signs requests with the standard AWS credential chain when no bearer
# token or profile is set -- which is exactly the pod's Pod Identity credentials. That
# provider serves OpenAI GPT models hosted on Bedrock (openai.gpt-*), not Claude, so the
# model here is a GPT model, unlike the other CLIs.
#
# The session entrypoint runs this as the dev user after the workspace is mounted, because
# ~/.codex lives under the mounted home. Idempotent: it rewrites config.toml each start.
set -eu
DIR="$HOME/.codex"
mkdir -p "$DIR"

# On its first start, Codex copies its own binaries (about 411 MB) into ~/.codex/packages
# to run its background app server from there. The home is the session's S3 Files folder,
# so that copy went over the mount, took long enough that the first start failed with
# "app server did not become ready" (losing the developer's first prompt), and was then
# exported to the bucket for every Codex session. The binaries come with the image, so
# keep them on the pod's own disk instead: a fresh copy per pod, nothing in the bucket.
LOCAL_PACKAGES=/tmp/codex-packages
mkdir -p "$LOCAL_PACKAGES"
if [ ! -L "$DIR/packages" ]; then
  rm -rf "$DIR/packages"
  ln -s "$LOCAL_PACKAGES" "$DIR/packages"
fi

# The app server's run-time state (pid files, locks, sockets, logs) belongs to the pod that
# wrote it. A Restore brought it back in the folder on a new pod, beside an empty packages
# directory, and Codex took it for an installed daemon whose binary had gone: every start
# failed with "daemon executable not found", and so did `codex app-server daemon start`.
# The first time this runs on a pod, Codex has not run on it yet, so whatever is there is
# another pod's: remove it, and Codex installs and starts its daemon as on a first start.
# Once per pod: a marker on the pod's own disk records that it was done, and a lock makes a
# second run on the same pod (the entrypoint run again) wait for the first and then leave
# the directory alone, since this pod's daemon may be using it by then. (It cannot be a
# symlink to the pod's disk, as packages is: Codex refuses one there.)
(
  flock 9
  if [ ! -e /tmp/codex-daemon-state-cleared ]; then
    rm -rf "$DIR/app-server-daemon"
    : > /tmp/codex-daemon-state-cleared
  fi
) 9> /tmp/codex-daemon-state.lock

# Preserve any non-managed lines Codex itself wrote (e.g. the tui screen-reader flag), then
# write the managed model/provider block.
# Codex's built-in amazon-bedrock provider only accepts overriding base_url, auth,
# http_headers and the aws.* sub-keys -- setting other fields (e.g. name) is rejected. So
# set only model, model_provider and aws.region.
# gpt-5.6-terra is the OpenAI model this account's Bedrock Mantle serves in us-west-2
# (gpt-5.6-sol is us-east-2 only). Verified live: codex answers with it here.
# sandbox_mode: Codex's own command sandbox on Linux is bubblewrap, which needs to create
# user namespaces. The Nitro sandbox's guest kernel allows none (max_user_namespaces = 0,
# for root as well), so bubblewrap -- the system one or the one Codex bundles -- fails with
# ENOSPC and every shell command Codex runs for you fails. The pod is the boundary instead:
# its own kernel, the egress policy, and a folder credential for this one session. So
# "danger-full-access" here means no second boundary inside the pod, not more than the pod
# allows. approval_policy is left at Codex's default, which still asks for approval
# (/status: "Custom (danger-full-access, Ask for approval)").
cat > "$DIR/config.toml" <<TOML
model = "openai.gpt-5.6-terra"
model_provider = "amazon-bedrock"
sandbox_mode = "danger-full-access"
# The image pins Codex's version; its update prompt on every start would only offer an
# npm install the session user cannot do.
check_for_update_on_startup = false

# Codex's own client-side web search tool stays off. The GPT model on Mantle has a separate
# server-side web search and fetch tool that Amazon Bedrock runs (not the pod), which the
# Codex role (Codex's pods only) grants with the bedrock-websearch actions; see the README.
[tools]
web_search = false

[model_providers.amazon-bedrock.aws]
region = "${AWS_REGION:-us-west-2}"
TOML
