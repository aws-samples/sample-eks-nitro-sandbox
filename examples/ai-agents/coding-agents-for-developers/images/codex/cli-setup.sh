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

# Preserve any non-managed lines Codex itself wrote (e.g. the tui screen-reader flag), then
# write the managed model/provider block.
# Codex's built-in amazon-bedrock provider only accepts overriding base_url, auth,
# http_headers and the aws.* sub-keys -- setting other fields (e.g. name) is rejected. So
# set only model, model_provider and aws.region.
# gpt-5.6-terra is the OpenAI model this account's Bedrock Mantle serves in us-west-2
# (gpt-5.6-sol is us-east-2 only). Verified live: codex answers with it here.
cat > "$DIR/config.toml" <<TOML
model = "openai.gpt-5.6-terra"
model_provider = "amazon-bedrock"

# The sandbox's egress policy allows only the endpoints the session needs (S3 Files, the
# Bedrock endpoints, the developer hosts), so Codex's live web search has nowhere to go:
# left on, the model reaches for the web_search tool, the request is denied, and the turn
# fails with "web search is not authorized for this identity". Turn it off so Codex answers
# from the model directly. A developer who wants web search adds the endpoints to the egress
# policy and sets this back to true.
[tools]
web_search = false

[model_providers.amazon-bedrock.aws]
region = "${AWS_REGION:-us-west-2}"
TOML
