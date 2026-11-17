# OpenClaw Enterprise on EKS with Nitro sandboxes

This sample adds an admission adapter and supporting infrastructure to run
OpenClaw Enterprise (OCE) gateway workloads in Nitro sandboxes. It is a
sample-specific compatibility layer, not an upstream OCE support statement.

See [Tenant isolation boundary](TENANT-ISOLATION.md) for the compute, storage,
network, credential, gateway, and database controls—and their limits.

## Scope and limitations

- This sample does not cover human SSO, sustained-load testing, high
  availability, or deliberate node-drain testing.
- This sample does not add a second sandbox boundary for nested OpenClaw
  execution inside the Nitro sandbox.
- The private model gateway and VM-isolated runtime storage adaptation target
  the documented OCE pod shape. Verify compatibility before changing OCE
  versions.

## Architecture

- The [admission adapter](adapter/adapter.py) runs as the two fail-closed webhooks defined
  in [`deploy/adapter-webhook.yaml`](deploy/adapter-webhook.yaml). The mutating
  webhook receives every Pod creation request in OCE-managed namespaces,
  adapts the embedded `gateway` workload role, and rejects unsupported pod
  shapes. It replaces OCE's
  `openclaw.dev/network-profile=broad-egress-v1` label with
  `nitro-central-gateway-v1`. The validating webhook rechecks the final stored
  Pod shape and denies every ephemeral-container update in those namespaces.
- The [CodeBuild source-build path](build/README.md) builds the adapter, a separate
  ownership helper, and pinned OCE controller and runtime source into four
  private ECR repositories. It waits for image scans and exports
  digest-qualified deployment references.
- [`deploy/agentgateway.yaml`](deploy/agentgateway.yaml) exposes AgentGateway only
  as an HTTPS ClusterIP Service. This central AgentGateway alone receives AWS
  identity through EKS Pod Identity and invokes the centrally configured
  Amazon Bedrock model.
- [`scripts/configure-tenant-model-gateway.sh`](scripts/configure-tenant-model-gateway.sh)
  installs the AgentGateway CA as an immutable tenant ConfigMap and applies
  default-deny egress. Its allow policies select
  `openclaw.dev/network-profile=nitro-central-gateway-v1` and permit only DNS
  plus HTTPS to the central AgentGateway Service.

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
unsupported variants. Unrelated volumes may remain only when they do not violate
the protected state, path, token, or image contracts. For each compatible
gateway pod, the adapter:

- Selects the `isolated-sandbox` runtime class. It adds the restricted network
  profile when the label is absent, replaces OCE's `broad-egress-v1` profile,
  and rejects any other profile.
- Rewrites the designated runtime's `runtime-state` layout for Nitro Pods. It
  replaces the `/home/node` `subPath: home` mount with a whole-volume mount,
  rebases nested `subPath` values from `home/<path>` to `<path>`, and patches
  the expected `prepare-private-state` script to create those descendants at
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
  service-account token projections. It pins the runtime's `HOME` to
  `/home/node` and allows only empty scratch volumes, the verified agent-state
  claim, and the exact OCE configuration, service-principal token, and
  AgentGateway CA inputs.
- Mounts the tenant `agentgateway-ca` ConfigMap at `/etc/agentgateway-ca`, sets
  `NODE_EXTRA_CA_CERTS=/etc/agentgateway-ca/ca.crt`, removes OCE's
  `runtime-temporary` mount at `/tmp`, requires a read-only root filesystem,
  and sets `TMPDIR=/dev/shm`. It rejects other mounts that overlap `/tmp` or
  `/dev/shm`.
- Protects immutable `gateway-*-rev-*` ConfigMaps so only the OCE worker can
  create, update, or delete the configuration mounted by a runtime.

The adapter deployment includes a NetworkPolicy that permits ingress only on
its TLS listener port, 8443, and adds no egress allowance. Kubernetes
NetworkPolicies are additive, so cluster operators must review other policies
that select these pods. The adapter initiates no network connections.
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
  adapted runtime containers. It also rejects arbitrary environment value
  sources and accepts only OCE's Pod UID, gateway password, and
  revision-bound harness secret references.

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

The tenant allow policies select only the adapter's
`nitro-central-gateway-v1` profile. Adapted runtime pods therefore do not match
OCE's public HTTPS egress policy for `broad-egress-v1`. The tenant script
resolves the AgentGateway ClusterIP and renders it as an explicit `/32`; it
does not permit direct traffic to AgentGateway Pod IPs.

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

Schedule workloads on nodes created after this change. Existing
nodes do not gain network-policy enforcement in place.

See [`scripts/README.md`](scripts/README.md) for tenant configuration and
verification boundaries.

Image digests, tenant identifiers, endpoints, credentials, and account details
are deployment-specific. Do not commit them to source control. Configure the
Amazon Bedrock region and model in the AgentGateway manifest for your
deployment.

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
| [`tests/test_tenant_isolation_contract.py`](tests/test_tenant_isolation_contract.py) | Static contracts for compute, storage, network, credential, gateway, and documented database boundaries. |
| [`TENANT-ISOLATION.md`](TENANT-ISOLATION.md) | Tenant isolation model, residual risks, and claim limits. |
| [`VALIDATION.md`](VALIDATION.md) | Reproducible source, admission, network, credential, and model-path checks. |
