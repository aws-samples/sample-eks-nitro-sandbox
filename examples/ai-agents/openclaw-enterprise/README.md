# OpenClaw Enterprise on EKS with Nitro sandboxes

**Status: validation pending.** The hardened working tree has not been tied to
a final sample commit or a fresh live validation run. Record
`<VALIDATED_SAMPLE_COMMIT>` and `<VALIDATED_OCE_COMMIT>` only after the final
procedure completes. This is not an upstream OpenClaw Enterprise (OCE) support
statement.

See [Scoped validation procedure](VALIDATION.md) for the required checks,
expected denials, and evidence placeholders.

## Outside the planned validation scope

- Human SSO was not validated.
- Sustained load and high availability were not validated.
- Deliberate node drain was not validated. The test replaced a pod, not a node.
- Nested OpenClaw exec isolation was not validated. Do not claim a second
  sandbox boundary inside the Nitro sandbox.
- OCE does not provide an upstream-supported contract for this private model
  gateway and VM-isolated runtime storage adaptation. The adapter remains
  sample-specific.

## Current design

- The [admission adapter](adapter/adapter.py) runs as the two fail-closed webhooks defined
  in [`deploy/adapter-webhook.yaml`](deploy/adapter-webhook.yaml). The mutating
  webhook receives every Pod creation request in OCE-managed namespaces,
  adapts the embedded `gateway` workload role, and rejects unsupported pod
  shapes. The validating webhook rechecks the final stored Pod shape and
  denies every ephemeral-container update in those namespaces.
- The [CodeBuild source-build path](build/README.md) builds the adapter, a separate
  ownership helper, and pinned OCE controller and runtime source into four
  private ECR repositories. It waits for image scans and exports
  digest-qualified deployment references.
- [`deploy/agentgateway.yaml`](deploy/agentgateway.yaml) exposes AgentGateway only
  as an HTTPS ClusterIP Service. AgentGateway validates tenant keys and obtains
  Amazon Bedrock credentials through EKS Pod Identity.
- [`scripts/configure-tenant-model-gateway.sh`](scripts/configure-tenant-model-gateway.sh)
  installs the AgentGateway CA as an immutable tenant ConfigMap and applies
  default-deny, DNS and AgentGateway-only egress policies.

### Controller trust chain

The trust boundary follows Kubernetes controller ownership:

1. The OCE worker may create or update gateway Deployments.
2. The Kubernetes Deployment controller may create or update their
   ReplicaSets.
3. Only configured ReplicaSet-controller identities may create Pods in
   OCE-managed namespaces.

The admission adapter then verifies the expected Deployment, ReplicaSet, and
Pod provenance and shape. A tenant cannot qualify a direct Pod request by
copying trusted labels because its caller identity is outside this controller
chain. The request fails before forged labels can grant the trusted workload
path.

The adapter is a compatibility layer for one pinned OCE embedded-gateway pod
shape, not an upstream OCE compatibility guarantee. It verifies the controller
owner, labels, ServiceAccount, PVC, projected service-principal token, runtime
image, two initial init containers, and final adapted Pod. It rejects sidecars,
extra init containers, custom service-account token projections, and other
unreviewed variants. Unrelated volumes may remain only when they do not violate
the protected state, path, token, or image contracts. For each compatible
gateway pod, the adapter:

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
- Sets `automountServiceAccountToken: false` and removes the exact
  auto-injected `kube-api-access-*` volume and mount shape. It allows only the
  exact OCE service-principal token projection and rejects other
  service-account token projections.
- Mounts the tenant `agentgateway-ca` ConfigMap at `/etc/agentgateway-ca`, sets
  `NODE_EXTRA_CA_CERTS=/etc/agentgateway-ca/ca.crt`, removes OCE's
  `runtime-temporary` mount at `/tmp`, requires a read-only root filesystem,
  and sets `TMPDIR=/dev/shm`. It rejects other mounts that overlap `/tmp` or
  `/dev/shm`.
- Adds a dedicated root init container from the separately configured
  `OCE_OWNERSHIP_INIT_IMAGE`. The adapter requires an exact digest, rejects the
  workload runtime image as the helper, and denies the pod when the setting is
  absent or invalid. The init mounts the `runtime-state` volume root at
  `/home/node` and sets it to mode `0700`, UID 1000 and GID 1000. It treats
  `.openclaw/control` as a migration-only optional directory: the helper repairs
  it when present and skips it when absent on a clean PVC. Core runtime
  directories remain mandatory and fail closed. Permission repair stays
  limited to `/home/node`, `/home/node/.openclaw`, each direct mapped target,
  `client/credentials.sqlite`, and the runtime pin database with its known
  SQLite sidecars.
- Replaces each runtime container's security context with a fixed allowlist:
  UID and GID 1000, non-root execution, `privileged: false`, no privilege
  escalation, a read-only root filesystem, all Linux capabilities dropped, and
  the `RuntimeDefault` seccomp profile. It rejects privileged, unmasked
  `/proc`, and unconfined seccomp overrides. The runtime command never performs
  the privileged repair.
- Replaces the expected OCE state-preparation init container's security
  context with non-root UID and GID 1000, a read-only root filesystem, all
  Linux capabilities dropped, and `RuntimeDefault` seccomp. Any other prep
  contract is rejected rather than adapted.
- Rejects an ordinary runtime or sidecar container that mounts
  `openclaw-gateway-state` at `/gateway-state`. Only the expected init-container
  path and the adapter-generated helpers receive the PVC root.
- Revalidates the complete post-mutation Pod through a separate validating
  webhook and denies ephemeral containers with `failurePolicy: Fail`. This
  catches a later mutator changing a trusted field and prevents a debug
  container from bypassing creation-time checks. It also means an unavailable
  adapter blocks matching Pod creation and ephemeral-container updates.
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
the runtime. A small, statically linked Go helper owns this narrow
ownership-repair boundary and exits before OpenClaw starts. It opens only an
explicit relative-path allowlist beneath `/home/node` with Linux `openat2`
constraints, rejects symbolic links and multiply linked regular files, and
changes ownership and mode through the checked file descriptor. It repairs the
required directories plus existing migration-only control state and known
OpenClaw SQLite files and sidecars without walking the PVC recursively. This is
an exact-path compatibility repair, not a general PVC repair. Keeping the
helper in a separate scratch image avoids running the much larger workload
image with ownership capabilities. The runtime still runs as non-root without
Linux capabilities, but operators must build, scan, pin, and deploy the
additional helper image correctly.

The tenant script renders the current AgentGateway ClusterIP as an explicit
`/32`. The generated policy permits HTTPS on TCP port 443 to that stable
ClusterIP; it does not permit direct traffic to AgentGateway Pod IPs.

## One-time EKS Auto Mode prerequisite

Enable the VPC CNI network policy controller once per cluster before testing
tenant isolation:

```bash
KUBE_CONTEXT='<explicit-kube-context>'
kubectl config get-contexts "$KUBE_CONTEXT"
kubectl --context "$KUBE_CONTEXT" --namespace kube-system \
  patch configmap amazon-vpc-cni \
  --type merge \
  --patch '{"data":{"enable-network-policy":"true","enable-network-policy-controller":"true"}}'
```

Schedule validation workloads on nodes created after this change. Existing
nodes do not gain network-policy enforcement in place.

See [`scripts/README.md`](scripts/README.md) for tenant configuration and
verification boundaries.

## Upstream OCE mapping

Carlos opened OCE issues
[#4252](https://github.com/openclaw/openclaw-enterprise/issues/4252),
[#4253](https://github.com/openclaw/openclaw-enterprise/issues/4253), and
[#4254](https://github.com/openclaw/openclaw-enterprise/issues/4254).
[PR #3893](https://github.com/openclaw/openclaw-enterprise/pull/3893) is closed
without merge and covers only dedicated Harnesses.
[PR #4528](https://github.com/openclaw/openclaw-enterprise/pull/4528) directly
addresses the model-provider work tracked by #4254, and
[PR #4866](https://github.com/openclaw/openclaw-enterprise/pull/4866) adds
follow-on per-deployment overrides. Merged
[PR #5346](https://github.com/openclaw/openclaw-enterprise/pull/5346),
[PR #5333](https://github.com/openclaw/openclaw-enterprise/pull/5333), and open
[PR #4432](https://github.com/openclaw/openclaw-enterprise/pull/4432) are
adjacent potential native paths, not formal fixes for #4252 or #4253. This
sample therefore remains a compatibility adapter, not evidence of upstream
support.

## Validation baseline

Record the following only after completing a fresh run:

- Sample commit: `<VALIDATED_SAMPLE_COMMIT>`
- OCE commit: `<VALIDATED_OCE_COMMIT>`
- Validation date: `<VALIDATION_DATE>`
- Automated checks: `<AUTOMATED_TEST_RESULT>`
- Live checks: `<LIVE_VALIDATION_RESULT>`
- Image findings: `<INSPECTOR_RESULT>`

Image digests, tenant identifiers, endpoints, credentials, and account details
are deployment-specific and must not be published. The current AgentGateway
manifest fixes the Amazon Bedrock region and model; parameterize and document
those settings before publication.

## Files

| Path | Purpose |
|---|---|
| [`adapter/adapter.py`](adapter/adapter.py) | Admission mutation logic; its neighbouring files contain the webhook server and unit tests. |
| [`build/README.md`](build/README.md) | CodeBuild, ECR and source-build resources. |
| [`deploy/adapter-webhook.yaml`](deploy/adapter-webhook.yaml) | Admission adapter deployment plus mutating and validating webhook configurations. |
| [`deploy/agentgateway.yaml`](deploy/agentgateway.yaml) | Private AgentGateway, TLS, Service and ingress policy. |
| [`deploy/tenant-model-gateway.yaml.tpl`](deploy/tenant-model-gateway.yaml.tpl) | Tenant default-deny and allowed egress policy template. |
| [`scripts/configure-tenant-model-gateway.sh`](scripts/configure-tenant-model-gateway.sh) | Tenant CA and network-policy configuration. |
| [`iam/pod-identity-trust.json`](iam/pod-identity-trust.json) | Pod Identity trust policy for the AgentGateway ServiceAccount. |
| [`iam/bedrock-invoke.json`](iam/bedrock-invoke.json) | Restricted Amazon Bedrock invoke policy template. |
| [`tests/test_adapter_contract.py`](tests/test_adapter_contract.py) | Static deployment and integration contracts; neighbouring files cover the build, gateway, and tenant configuration. |
| [`VALIDATION.md`](VALIDATION.md) | Scoped validation procedure, expected results, and evidence placeholders. |
