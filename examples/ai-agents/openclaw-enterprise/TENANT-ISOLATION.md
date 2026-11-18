# Tenant isolation boundary

This blueprint adds infrastructure controls around OpenClaw Enterprise (OCE)
commit `86c8c12310f691bb21651118ffffd6bfd460e9ff`. It does not modify upstream
OCE.

## Enforced boundaries

### Compute and admission

OCE creates each tenant gateway Pod. The fail-closed admission chain verifies
the expected OCE Namespace, Deployment, ReplicaSet, revision ConfigMap, images,
volumes, environment, and security context before it admits the Pod.

The adapter then applies the narrow compatibility changes required by this
blueprint:

- set `runtimeClassName: isolated-sandbox`;
- replace the incompatible OCE state PVC mount with the expected
  `/home/node/.openclaw` and ownership-helper layout;
- add private AgentGateway CA trust;
- apply the associated network-profile and strict Nitro-compatible container,
  volume, and environment rules.

The adapter does not choose a model, configure AgentGateway, or rewrite model
routing. OCE's native shared `modelProvider` sends HTTPS requests to the
AgentGateway Service.

Each admitted runtime runs in its own Nitro sandbox VM with its own kernel.
This boundary separates tenant runtime compute from the EKS node and from the
other tenant runtime.

### Storage

Each runtime receives the PVC derived from its gateway identity. Admission
rejects a different claim. The runtime mounts persistent state at
`/home/node/.openclaw`; allowed init containers mount the same claim at the
expected preparation path.

Separate PVC and PV identities establish the per-runtime storage boundary
tested by the live validator. The blueprint does not encrypt or isolate data
inside an external shared database.

### Network

Each OCE backing namespace receives default-deny egress. Adapted runtimes can
reach only cluster DNS and the central AgentGateway ClusterIP on TCP 443. The
adapter replaces OCE's broad-egress network-profile label, so these runtimes do
not match OCE's public HTTPS egress policy.

These objects depend on the EKS Auto Mode network-policy controller. The live
deny, allow, and deny canary sequence proves enforcement for the tested
cluster.

### AWS identity

Tenant runtimes receive no IRSA annotation or EKS Pod Identity association.
Admission rejects common AWS credential variables and unapproved environment
sources. Tenant egress policy denies the EKS Pod Identity Agent endpoint.

Only `openclaw-enterprise-agw/agentgateway` receives EKS Pod Identity. Its IAM
policy permits the configured Bedrock model in the selected Region.

Per-tenant Bedrock inference profiles are not required because the gateway is
shared and stateless; separate AgentGateway keys authorize tenant requests.

### OCE authorization

Each validator service key receives `read` permission on only its own OCE
Namespace and Agent. The live procedure checks that both same-tenant reads
succeed and both cross-tenant reads return HTTP `403` with code `FORBIDDEN`.

This proves the pinned OCE API authorization path under test. It does not prove
database-level isolation or a broader authorization property.

## Database and control-plane boundary

AgentGateway is a shared, stateless request gateway. It keeps no tenant runtime
state or per-tenant database, but all tenants depend on the same Deployment,
private Service, bearer-key configuration, and Bedrock IAM role.

Each tenant has a separate AgentGateway bearer key. AgentGateway authenticates
that key, but Kubernetes NetworkPolicy does not bind a tenant namespace to one
specific key. A key copied into another allowed runtime would grant that key's
gateway access.

The OCE control plane and database are also shared components. This blueprint
does not modify upstream OCE. It does not enable PostgreSQL row-level security.
It tests authorization at the OCE API and makes no claim about database row
isolation, per-tenant database roles, or protection from a compromised OCE
control plane.

## Outside the boundary

The blueprint does not provide:

- per-tenant IAM roles, Bedrock inference profiles, quotas, or billing
  attribution;
- protection from disclosure of a tenant's OCE or AgentGateway bearer key;
- isolation from a failure or compromise of the shared AgentGateway, OCE
  control plane, or database;
- human SSO, production secret rotation, sustained-load testing, high
  availability validation, or nested OpenClaw execution isolation;
- compatibility guarantees for another OCE revision or pod shape.

If your threat model includes cross-tenant bearer-key theft, add an identity
that AgentGateway binds to the source workload, such as verified workload JWT
claims or mutual TLS. If it requires database isolation, design and validate
that control separately.
