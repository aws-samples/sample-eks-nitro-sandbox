# OpenClaw Enterprise on EKS with Nitro sandboxes

**Status: draft.** A live OpenClaw Enterprise (OCE) installation created an
Agent whose gateway ran in a Nitro sandbox and completed a model turn through
AgentGateway to Amazon Bedrock. Multi-tenant isolation, replacement recovery
and fleet scale still require validation.

## Proven live today

- OCE was installed from its Helm chart, and its API and worker became ready
  against PostgreSQL.
- An OCE-created Agent gateway was mutated by the adapter, scheduled with
  `runtimeClassName: isolated-sandbox`, and ran on a Nitro sandbox node. Its
  guest kernel confirmed that execution occurred inside the sandbox.
- From that OCE-created gateway, AgentGateway called the Amazon Bedrock
  Responses-compatible API through EKS Pod Identity and returned `completed`.
- AgentGateway returned `401` for an invalid tenant key.
- The tenant network policy blocked an unlabelled pod.

## Not yet proven

- A second tenant and Agent, including positive same-tenant access and negative
  cross-tenant access.
- Agent readiness, persistent state and recovery after pod and node
  replacement with the latest adapter image.
- High availability, load, quota and failure-mode behaviour.
- Nested OpenClaw exec isolation. It is unavailable in this deployment, so do
  not claim a second sandbox boundary inside the Nitro sandbox.
- An upstream OCE contract for private model gateways and VM-isolated runtime
  storage. The adapter remains sample-specific.

Do not present this sample as a completed OCE deployment until those checks pass.

## Current design

- The [admission adapter](adapter/) runs as the two fail-closed webhooks defined
  in [`deploy/adapter-webhook.yaml`](deploy/adapter-webhook.yaml). The mutating
  webhook receives every Pod creation request in OCE-managed namespaces,
  adapts `agent` and `gateway` workload roles, and rejects unsupported pod
  shapes. The validating webhook denies every ephemeral-container update in
  those namespaces.
- The [CodeBuild source-build path](build/) builds the adapter, a separate
  ownership helper, and pinned OCE controller and runtime source into four
  private ECR repositories. It waits for image scans and exports
  digest-qualified deployment references.
- [`deploy/agentgateway.yaml`](deploy/agentgateway.yaml) exposes AgentGateway only
  as an HTTPS ClusterIP Service. AgentGateway validates tenant keys and obtains
  Amazon Bedrock credentials through EKS Pod Identity.
- [`scripts/configure-tenant-model-gateway.sh`](scripts/configure-tenant-model-gateway.sh)
  installs the AgentGateway CA as an immutable tenant ConfigMap and applies
  default-deny, DNS and AgentGateway-only egress policies.

The adapter is a compatibility layer for the pinned OCE pod shape, not an
upstream OCE compatibility guarantee. For each compatible Agent or gateway pod,
it:

- Selects the `isolated-sandbox` runtime class.
- Rewrites the designated runtime's `runtime-state` layout for Nitro Pods. It
  replaces the `/home/node` `subPath: home` mount with a whole-volume mount,
  rebases nested `subPath` values from `home/<path>` to `<path>`, and patches
  the validated `prepare-private-state` script to create those descendants at
  the volume root.
- Replaces OCE `openclaw-gateway-state` PVC `subPath` mounts below
  `/home/node/.openclaw` with one PVC-root mount at `/home/node/.openclaw`, so
  `client` remains a real directory. A follow-up init container creates
  relative aliases inside `/gateway-state` only when a mount path and target
  differ. Before applying mount-specific checks, it rejects every volume mount
  path that is not a canonical absolute path, including paths with repeated
  separators or traversal segments.
- Sets `automountServiceAccountToken: false` and removes standard
  auto-injected `kube-api-access-*` volumes and mounts. It preserves unrelated
  projected volumes and custom token mounts.
- Mounts the tenant `agentgateway-ca` ConfigMap at `/etc/agentgateway-ca`, sets
  `NODE_EXTRA_CA_CERTS=/etc/agentgateway-ca/ca.crt`, removes OCE's
  `runtime-temporary` mount at `/tmp`, requires a read-only root filesystem,
  and sets `TMPDIR=/dev/shm`. It rejects other mounts that overlap `/tmp` or
  `/dev/shm`.
- Adds a dedicated root init container from the separately configured
  `OCE_OWNERSHIP_INIT_IMAGE`. The adapter requires an exact digest, rejects the
  workload runtime image as the helper, and denies the pod when the setting is
  absent or invalid. The init mounts the `runtime-state` volume root at
  `/home/node` and sets it to mode `0700`, UID 1000 and GID 1000. Permission
  repair fails closed and is limited to `/home/node`, `/home/node/.openclaw`,
  each direct mapped target below it, and `client/credentials.sqlite`.
- Replaces each runtime container's security context with a fixed allowlist:
  UID and GID 1000, non-root execution, `privileged: false`, no privilege
  escalation, a read-only root filesystem, all Linux capabilities dropped, and
  the `RuntimeDefault` seccomp profile. It rejects privileged, unmasked
  `/proc`, and unconfined seccomp overrides. The runtime command never performs
  the privileged repair.
- Rejects an ordinary runtime or sidecar container that mounts
  `openclaw-gateway-state` at `/gateway-state`. Only the expected init-container
  path and the adapter-generated helpers receive the PVC root.
- Denies ephemeral containers through a separate validating webhook with
  `failurePolicy: Fail`. This prevents a debug container from bypassing the
  creation-time mutation; it also means an unavailable adapter blocks
  ephemeral-container updates.
- Requires exact `repository@sha256:<digest>` image references. The adapter
  rejects `envFrom` and explicit unsafe loader or shell-bootstrap variables on
  adapted runtime containers.

Nitro presents OCE's `/tmp` `subPath` mount as group- and world-writable without
the sticky bit, which OpenClaw's secure temporary-directory check rejects. The
Nitro runtime already provides pod-local, writable, sticky `/dev/shm`, so
OpenClaw can create its user-owned `0700` temporary directory there without a
separate repair step. Because `/dev/shm` is memory-backed and capacity-limited,
this workaround suits OpenClaw's small temporary control files, not large
scratch data.

Nitro presents OCE's `/home/node` `subPath` mount root as mode `2777`, owned by
root with GID 1000. The whole-volume rewrite avoids exposing that mount root to
the runtime. The dedicated helper image contains only BusyBox entry points for
`sh`, `chown`, and `chmod`. Its init container owns this narrow
ownership-repair trust boundary, runs with `CHOWN`, `DAC_OVERRIDE`, and
`FOWNER`, and exits before the OpenClaw runtime starts. It does not recursively
rewrite persisted files. For
`/home/node/.openclaw/client/credentials.sqlite`, it refuses a symlink and
restores UID and GID 1000 with mode `0600`, which OpenClaw requires after an
`fsGroup` mount. Treat this init phase as an explicit compatibility trade-off,
not complete process or tenant isolation. Keeping the helper separate avoids
running ownership repair from the much larger workload image. The runtime still
runs as non-root without Linux capabilities, but operators must build, scan,
pin, and deploy the additional helper image correctly.

The tenant script renders the current AgentGateway ClusterIP as a `/32` alongside
the namespace-and-pod selector. In the live EKS Auto Mode test, the generated
`PolicyEndpoint` did not add that Service IP for selector-based policy, so the
explicit `/32` was required for traffic to the stable ClusterIP.

## One-time EKS Auto Mode prerequisite

Enable the VPC CNI network policy controller once per cluster before testing
tenant isolation:

```bash
kubectl --namespace kube-system patch configmap amazon-vpc-cni \
  --type merge \
  --patch '{"data":{"enable-network-policy":"true","enable-network-policy-controller":"true"}}'
```

Schedule validation workloads on nodes created after this change. Existing
nodes do not gain network-policy enforcement in place.

See [`scripts/README.md`](scripts/README.md) for tenant configuration and
verification boundaries.

## Pinned versions

| Component | Pin |
|---|---|
| OCE source | `86c8c12310f691bb21651118ffffd6bfd460e9ff` |
| AgentGateway | v1.7.0, `cr.agentgateway.dev/agentgateway@sha256:60216aafb03d37f94e952ff3d51d2f630a65b10ecaebdc0a864882f92610c45b` |
| Amazon Bedrock model | `us.anthropic.claude-haiku-4-5-20251001-v1:0` |

## Files

| Path | Purpose |
|---|---|
| [`adapter/`](adapter/) | Admission mutation logic, webhook server and unit tests. |
| [`build/`](build/) | CodeBuild, ECR and source-build resources. |
| [`deploy/adapter-webhook.yaml`](deploy/adapter-webhook.yaml) | Admission adapter deployment plus mutating and validating webhook configurations. |
| [`deploy/agentgateway.yaml`](deploy/agentgateway.yaml) | Private AgentGateway, TLS, Service and ingress policy. |
| [`deploy/tenant-model-gateway.yaml.tpl`](deploy/tenant-model-gateway.yaml.tpl) | Tenant default-deny and allowed egress policy template. |
| [`scripts/configure-tenant-model-gateway.sh`](scripts/configure-tenant-model-gateway.sh) | Tenant CA and network-policy configuration. |
| [`iam/pod-identity-trust.json`](iam/pod-identity-trust.json) | Pod Identity trust policy for the AgentGateway ServiceAccount. |
| [`iam/bedrock-invoke.json`](iam/bedrock-invoke.json) | Restricted Amazon Bedrock invoke policy template. |
| [`tests/`](tests/) | Static deployment and integration contracts. |
