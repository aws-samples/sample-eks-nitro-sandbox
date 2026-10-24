#!/bin/sh
# Configure opencode to use Amazon Bedrock with the model the base image pins in MODEL_ID,
# authenticating ambiently through the pod's Pod Identity (no API key). The session
# entrypoint runs this as the dev user after the workspace is mounted, because opencode's
# config lives under the mounted home. Idempotent: it rewrites the config each start.
set -eu
MODEL="${MODEL_ID:-us.anthropic.claude-sonnet-5-5}"
DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
mkdir -p "$DIR"

# opencode reads AWS credentials through the AI SDK's amazon-bedrock provider, which uses
# the default AWS credential chain (Pod Identity here). Setting the model and provider
# region is enough; no key is stored.
cat > "$DIR/opencode.json" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "amazon-bedrock/$MODEL",
  "provider": {
    "amazon-bedrock": {
      "options": {
        "region": "${AWS_REGION:-us-west-2}"
      }
    }
  }
}
JSON
