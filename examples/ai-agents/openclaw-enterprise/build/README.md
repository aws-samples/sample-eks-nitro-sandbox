# CodeBuild image path

This stack creates four private ECR repositories and one CodeBuild project. The
repositories use immutable tags, a customer managed KMS key, and scan every
pushed image. CodeBuild clones this sample and OpenClaw Enterprise (OCE) at full
commit SHAs, builds all four images from source, waits for their ECR scans, and
exports digest-qualified image references.

The default OCE revision is
`c6541831756ae40d0485d16d8f0ffeab9851372d`. Set `SampleGitRevision` to the full
commit SHA containing the adapter and this build directory.

## Build the images

Create or update the build resources:

```bash
aws cloudformation deploy \
  --stack-name openclaw-enterprise-images \
  --template-file examples/ai-agents/openclaw-enterprise/build/template.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides SampleGitRevision="$(git rev-parse HEAD)"
```

Start the source build:

```bash
project_name="$(
  aws cloudformation describe-stacks \
    --stack-name openclaw-enterprise-images \
    --query 'Stacks[0].Outputs[?OutputKey==`ProjectName`].OutputValue' \
    --output text
)"
build_id="$(
  aws codebuild start-build \
    --project-name "$project_name" \
    --query 'build.id' \
    --output text
)"
aws codebuild batch-get-builds \
  --ids "$build_id" \
  --query 'builds[0].{status:buildStatus,images:exportedEnvironmentVariables}'
```

Wait for `status` to become `SUCCEEDED`. The build exports `ADAPTER_IMAGE`,
`CONTROLLER_IMAGE`, `OWNERSHIP_INIT_IMAGE`, and `RUNTIME_IMAGE` in
`repository@sha256:<digest>` form. Use those values, not the temporary build
tags.

## Deploy the adapter

Install `kubectl`, `jq`, `yq` 4, and cert-manager before running these commands.
Retrieve the two sample-owned image references from the successful build:

```bash
set -euo pipefail
build_json="$(aws codebuild batch-get-builds --ids "$build_id")"
test "$(jq -r '.builds[0].buildStatus' <<<"$build_json")" = "SUCCEEDED"

ADAPTER_IMAGE="$(
  jq -er '.builds[0].exportedEnvironmentVariables[]
    | select(.name == "ADAPTER_IMAGE").value' <<<"$build_json"
)"
OWNERSHIP_INIT_IMAGE="$(
  jq -er '.builds[0].exportedEnvironmentVariables[]
    | select(.name == "OWNERSHIP_INIT_IMAGE").value' <<<"$build_json"
)"
export ADAPTER_IMAGE OWNERSHIP_INIT_IMAGE
```

Render both digest references into the adapter Deployment before applying the
manifest:

```bash
adapter_manifest="examples/ai-agents/openclaw-enterprise/deploy/adapter-webhook.yaml"
./examples/ai-agents/openclaw-enterprise/scripts/render-adapter-manifest.sh \
  "$adapter_manifest" "$ADAPTER_IMAGE" "$OWNERSHIP_INIT_IMAGE" \
  | kubectl apply --filename -

kubectl --namespace openclaw-enterprise-adapter rollout status \
  deployment/openclaw-enterprise-nitro-adapter
```

Do not apply the raw manifest: its adapter image is a placeholder and it omits
`OCE_OWNERSHIP_INIT_IMAGE`. The rendered stream gives the Deployment both
digest references in the same apply as the fail-closed webhook configurations.
During a first install, matching pod creation and ephemeral-container updates
can fail until the adapter Deployment becomes Ready.

`OCE_OWNERSHIP_INIT_IMAGE` is mandatory. The adapter denies OCE pod creation if
the value is missing, is not digest-pinned, contains whitespace, or matches a
workload runtime image.

The ownership helper has a scratch runtime containing only BusyBox entry points
for `/bin/sh`, `/bin/chown`, and `/bin/chmod`, copied from a digest-pinned base.
The init container runs as UID and GID 0 with only `CHOWN`, `DAC_OVERRIDE`, and
`FOWNER` added. The OpenClaw runtime remains non-root with all Linux
capabilities dropped. Admission also rejects `envFrom` and explicit unsafe
loader or shell-bootstrap variables on adapted runtime containers.

Deploy `CONTROLLER_IMAGE` and `RUNTIME_IMAGE` through the matching image
settings in the pinned OCE Helm chart. This sample does not provide a stable
upstream values contract, so copying guessed `--set` keys here would be
misleading.

The CodeBuild role can write only its logs and the four repositories. The
project accepts only public GitHub repository URLs and exact lowercase commit
SHAs; it has no source credential or local Docker path.
