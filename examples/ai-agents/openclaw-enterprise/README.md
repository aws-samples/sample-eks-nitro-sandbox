# OpenClaw Enterprise on EKS, with each Agent in a Nitro sandbox

**Status: draft.** This page is not yet a walkthrough. The pieces below are proven
in isolation, and every output block marked `TODO` comes from a fresh run that has
not happened yet. Nothing on this page is a real run of OpenClaw Enterprise (OCE)
installed by this sample.

## What is proven

- **OCE's Embedded gateway pod layout, rebuilt from its Kubernetes Compute driver**
  at commit `998a59e`, with the published runtime image by digest, runs in a Nitro
  sandbox (guest kernel 6.18.54) once the admission policy in
  [`deploy/nitro-adapter.yaml`](deploy/nitro-adapter.yaml) is applied. The policy sets
  `runtimeClassName` and rewrites the gateway-state `subPath` mounts into one PVC mount
  plus symlinks. SQLite in WAL mode works through the links, and a second pod on the
  same PVC reads the first pod's rows.
- **The model path, outside OCE:** OCE's runtime image (OpenClaw 2026.10.8) in a
  sandbox completed a turn with a tool call through
  [agentgateway](deploy/agentgateway.yaml) v1.7.0 to Amazon Bedrock. agentgateway
  answered 401 to a missing or wrong key and 200 to its own key, in `mode: strict`.
  The sandbox had no `AWS_*` variables.

## What is not proven yet

1. OCE installed from its chart and images, and an Agent created through the Console
   or the `occ` CLI. The proven pod is a reconstruction, not a pod OCE created.
2. The admission policy against a pod OCE created: OCE's real init scripts, its
   readiness probe through the symlinked state, and its own checks.
3. Database CIDRs for an in-cluster PostgreSQL, and an install with
   `gatewayRouting.enabled: false`, `agentNativeAdmin.enabled: false` and a loopback
   `auth.baseUrl`.
4. OCC accepting `models.providers.openai.baseUrl` for an Embedded Agent, and the
   Harness binding delivering the gateway key as `OPENAI_API_KEY`.
5. The Bedrock invoke policy in [`iam/bedrock-invoke.json`](iam/bedrock-invoke.json)
   has not been applied to a role yet; its ARNs contain `<ACCOUNT_ID>`.

## Pinned versions

| Component | Pin |
|---|---|
| OCE source and chart | commit `998a59e` of [openclaw-enterprise](https://github.com/openclaw/openclaw-enterprise); chart `deploy/helm/openclaw-enterprise` (version `0.1.0`) |
| OCE controller image | `ghcr.io/openclaw/openclaw-enterprise-controller@sha256:968ef69a70c0f2ac927e0e7515ba8c07c9887e7b23211351f58bbf706662ffed` (resolved 2026-10-30) |
| OCE runtime image | `ghcr.io/openclaw/openclaw-enterprise-runtime@sha256:6d0af87f6b2b803975cba47305bf69cd59aef69427290f0490da31f488855cb9` (resolved 2026-10-30) |
| agentgateway | v1.7.0, `cr.agentgateway.dev/agentgateway@sha256:60216aafb03d37f94e952ff3d51d2f630a65b10ecaebdc0a864882f92610c45b` |
| Amazon Bedrock model | `us.anthropic.claude-haiku-4-5-20251001-v1:0` |

## Stages (to be written from the fresh run)

### 1. Install OCE

TODO: output from the fresh run

### 2. Create the Agent and check its pod

The admission policy applies only to pods in namespaces labelled
`app.kubernetes.io/managed-by: openclaw-enterprise` and to pods labelled
`openclaw.dev/workload-role`. It is shown in full in
[`deploy/nitro-adapter.yaml`](deploy/nitro-adapter.yaml).

TODO: output from the fresh run

### 3. The model path

TODO: output from the fresh run

### 4. A real turn

TODO: output from the fresh run

## Clean up

TODO: list what the clean-up removes, including the admission policy, the Helm
release, the tenant namespaces OCE created, PostgreSQL and its volume, agentgateway,
the Pod Identity association and the IAM role.

## Files

| File | What it is |
|---|---|
| [`deploy/nitro-adapter.yaml`](deploy/nitro-adapter.yaml) | The `MutatingAdmissionPolicy` that puts the Agent pod in a sandbox and fixes its state mounts. |
| [`deploy/agentgateway.yaml`](deploy/agentgateway.yaml) | The model gateway: config, Deployment and ClusterIP Service. |
| [`iam/pod-identity-trust.json`](iam/pod-identity-trust.json) | The Pod Identity trust policy for agentgateway's ServiceAccount. |
| [`iam/bedrock-invoke.json`](iam/bedrock-invoke.json) | The permission policy: one model, invoke only. |
