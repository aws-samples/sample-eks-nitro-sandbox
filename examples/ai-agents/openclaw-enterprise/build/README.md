# CodeBuild image path

This stack creates four private ECR repositories, one CodeBuild project, and a
fixed Step Functions invocation path. The repositories use immutable tags, a
rotating customer managed KMS key, and scan every pushed image. The explicit
CodeBuild and Step Functions CloudWatch log groups use a separate rotating
customer managed KMS key. CodeBuild clones this sample
and OpenClaw Enterprise (OCE) at full commit SHAs, builds all four images from
source, waits for their ECR scans, and exports digest-qualified image
references.

The default OCE revision is
`86c8c12310f691bb21651118ffffd6bfd460e9ff`. It exact-pins
`@azure/msal-node` 7.2.0, after the 7.1.0 fix for CVE-2026-109461. The build
checks that lock entry before building, so changing the revision to one with a
different or missing MSAL version fails closed. Set `SampleGitRevision` to the
full commit SHA containing the adapter and this build directory.

The image gate supports ECR basic scanning and account-level enhanced continuous
scanning. It first checks the ECR scan result. Enhanced scanning can return
`ScanNotFoundException` indefinitely even when Inspector covers the image; in
that case the gate queries Inspector2 for the exact account, repository, and
digest. Inspector coverage must be `ACTIVE` and `SUCCESSFUL`, with a completed
scan timestamp, and there must be no active Critical or High finding for that
same image. Pending coverage is retried. Missing, ambiguous, failed, or malformed
coverage and findings fail the build closed.

The adapter Dockerfile pins its Chainguard Python base with
`latest@sha256:<digest>`. The digest, not the mutable `latest` tag, selects the
base image bytes. When Inspector reports a fixable vulnerability in that base
image:

1. Select the reviewed replacement digest that contains the vendor fix.
2. Replace the digest in `adapter/Dockerfile` while retaining the
   `@sha256:<digest>` pin.
3. Build the candidate commit through this workflow.
4. Accept the new `ADAPTER_IMAGE` only after Inspector completes the scan for
   its exact repository and digest and the Critical/High gate passes.
5. Deploy the new adapter digest and repeat the
   [scoped validation procedure](../VALIDATION.md).

The replacement digest creates a new adapter image and invalidates scan and
validation evidence for the previous digest. Do not treat a Dockerfile update
or a scan of the superseded image as proof that the fix reached the deployment.

The controller uses the sample-owned `controller-runtime.Dockerfile`. Its build
stage installs OCE's production dependencies, while its final stage starts from
a separately pinned Node 24 runtime image and removes package-manager and
build-only `esbuild`, `tsx`, and `drizzle-kit` files. To use a newer patched
Node 24 base, update `ControllerRuntimeBaseImageDigest` when deploying the
stack. The repository and tag are fixed in the build script, and the parameter
accepts only an exact digest. The resulting image must still pass the
Critical/High scan gate.

## Build the images

First mirror a reviewed CodeBuild builder image into a private ECR repository in
the account and Region where this stack runs. Record the digest returned by ECR.
Do not use a tag here: this builder runs privileged Docker and can write release
images. The stack requires the repository name and digest separately, constructs
an account-local digest reference, and grants the build role pull access only to
that repository.

Create or update the build resources:

```bash
aws cloudformation deploy \
  --stack-name openclaw-enterprise-images \
  --template-file examples/ai-agents/openclaw-enterprise/build/template.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    SampleGitRevision="$(git rev-parse HEAD)" \
    BuilderImageRepositoryName="replace-with-reviewed-builder-repository" \
    BuilderImageDigest="sha256:replace-with-64-lowercase-hex-characters" \
    TrustedBuildInvokerArn="arn:aws:iam::<ACCOUNT_ID>:role/<RELEASE_ROLE_NAME>"
```

Assume the generated invocation role and start the fixed workflow. Its definition
passes only `ProjectName` to CodeBuild and ignores execution input, so callers
cannot supply `buildspecOverride`, `imageOverride`, source overrides, or
environment overrides such as `BASH_ENV` and `GIT_CONFIG_*`. The workflow logs
all Step Functions events without execution payloads and publishes traces to
X-Ray.

```bash
invocation_role_arn="$(
  aws cloudformation describe-stacks \
    --stack-name openclaw-enterprise-images \
    --query \
    'Stacks[0].Outputs[?OutputKey==`BuildInvocationRoleArn`].OutputValue' \
    --output text
)"
state_machine_arn="$(
  aws cloudformation describe-stacks \
    --stack-name openclaw-enterprise-images \
    --query \
    'Stacks[0].Outputs[?OutputKey==`BuildStateMachineArn`].OutputValue' \
    --output text
)"
credentials="$(
  aws sts assume-role \
    --role-arn "$invocation_role_arn" \
    --role-session-name openclaw-enterprise-image-build
)"
export AWS_ACCESS_KEY_ID="$(jq -er '.Credentials.AccessKeyId' <<<"$credentials")"
export AWS_SECRET_ACCESS_KEY="$(jq -er '.Credentials.SecretAccessKey' <<<"$credentials")"
export AWS_SESSION_TOKEN="$(jq -er '.Credentials.SessionToken' <<<"$credentials")"
execution_arn="$(
  aws stepfunctions start-execution \
    --state-machine-arn "$state_machine_arn" \
    --input '{}' \
    --query executionArn \
    --output text
)"
while :; do
  execution_json="$(aws stepfunctions describe-execution --execution-arn "$execution_arn")"
  status="$(jq -r '.status' <<<"$execution_json")"
  case "$status" in
    SUCCEEDED)
      build_id="$(jq -er '.output | fromjson | .Build.Id' <<<"$execution_json")"
      break
      ;;
    FAILED|ABORTED|TIMED_OUT)
      jq '{status, error, cause}' <<<"$execution_json" >&2
      exit 1
      ;;
  esac
  sleep 20
done
build_json="$(aws codebuild batch-get-builds --ids "$build_id")"
printf '%s\n' "$build_json" |
  jq '.builds[0] | {buildStatus, exportedEnvironmentVariables}'
```

Wait for `status` to become `SUCCEEDED`. The build exports `ADAPTER_IMAGE`,
`CONTROLLER_IMAGE`, `OWNERSHIP_INIT_IMAGE`, and `RUNTIME_IMAGE` in
`repository@sha256:<digest>` form. Use those values, not the temporary build
tags.

## Deploy the adapter

Install `kubectl`, `jq`, `yq` 4, and cert-manager before running these commands.
Retrieve the three adapter deployment image references from the successful
build:

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
RUNTIME_IMAGE="$(
  jq -er '.builds[0].exportedEnvironmentVariables[]
    | select(.name == "RUNTIME_IMAGE").value' <<<"$build_json"
)"
export ADAPTER_IMAGE OWNERSHIP_INIT_IMAGE RUNTIME_IMAGE
```

Render all three digest references into the adapter Deployment before applying
the manifest:

```bash
adapter_manifest="examples/ai-agents/openclaw-enterprise/deploy/adapter-webhook.yaml"
KUBE_CONTEXT="replace-with-explicit-eks-context"
./examples/ai-agents/openclaw-enterprise/scripts/render-adapter-manifest.sh \
  "$adapter_manifest" \
  "$ADAPTER_IMAGE" \
  "$OWNERSHIP_INIT_IMAGE" \
  "$RUNTIME_IMAGE" \
  | kubectl --context "$KUBE_CONTEXT" apply --filename -

kubectl --context "$KUBE_CONTEXT" \
  --namespace openclaw-enterprise-adapter rollout status \
  deployment/openclaw-enterprise-nitro-adapter
```

Do not apply the raw manifest: its adapter image is a placeholder and it omits
the helper and runtime allowlists. The rendered stream gives the Deployment all
three digest references in the same apply as the fail-closed webhook
configurations.
During a first install, matching pod creation and ephemeral-container updates
can fail until the adapter Deployment becomes Ready.

`OCE_OWNERSHIP_INIT_IMAGE` is mandatory. The adapter denies OCE pod creation if
the value is missing, is not digest-pinned, contains whitespace, or matches a
workload runtime image.

`OCE_RUNTIME_IMAGES` is also mandatory. It is the exact digest allowlist for
the pinned OCE runtime used by the gateway and both OCE init containers.

The ownership helper is a statically linked Go binary in a scratch image. It
opens only an explicit relative-path allowlist with Linux `openat2` constraints,
rejects symbolic links and multiply linked files, and changes metadata through
the checked file descriptor. The init container runs as UID and GID 0 with only
`CHOWN`, `DAC_OVERRIDE`, and `FOWNER` added. The OpenClaw runtime remains
non-root with all Linux capabilities dropped. Admission also rejects `envFrom`
and explicit unsafe loader or shell-bootstrap variables on adapted runtime
containers.

Deploy `CONTROLLER_IMAGE` and `RUNTIME_IMAGE` through the matching image
settings in the pinned OCE Helm chart. This sample does not provide a stable
upstream values contract, so copying guessed `--set` keys here would be
misleading.

The CodeBuild role can pull the pinned builder, write only its logs and the four
release repositories, and query image scan results. The project accepts only
the canonical sample and OpenClaw Enterprise repository URLs plus exact
lowercase commit SHAs; it has no source credential or local Docker path.
Validate contributor forks with a separate build role and repository namespace
rather than granting fork code access to trusted release repositories.

CodeBuild has no project setting or resource policy that rejects every
`StartBuild` override. The workflow boundary is safe only when human and CI
principals cannot call `codebuild:StartBuild`, `codebuild:StartBuildBatch`, or
`codebuild:RetryBuild` on this project directly. Grant release operators only
`sts:AssumeRole` on `BuildInvocationRoleArn`. Remove direct CodeBuild grants and
enforce an explicit deny for the project in the account's permissions boundary
or SCP; the deny must exempt only `ImageBuildWorkflowRole`. Existing broad
administrator permissions can bypass this sample boundary unless the
organisation-level deny covers them. That limitation is an AWS IAM deployment
contract, not something the CodeBuild project can repair after malicious
override code has already started.
