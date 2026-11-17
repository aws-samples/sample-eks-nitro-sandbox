# Tenant isolation boundary

This sample adds infrastructure controls around OpenClaw Enterprise (OCE). It
does not modify upstream OCE.

## Enforced boundaries

- **Nitro compute boundary:** the admission adapter accepts only OCE-created
  gateway pods and assigns the `isolated-sandbox` runtime class. Each admitted
  agent runs inside its own Nitro-backed sandbox VM.
- **Per-runtime storage binding:** the adapter derives the PVC name from the
  gateway ID and rejects a different claim. The runtime container receives it
  at `/home/node/.openclaw`; the expected init containers can mount the PVC
  root at `/gateway-state` before the agent starts.
- **Namespace network policy:** each tenant namespace has default-deny egress.
  The allow policies select
  `openclaw.dev/network-profile=nitro-central-gateway-v1` and permit DNS plus
  the central AgentGateway Service on TCP 443 only. The admission adapter
  replaces OCE's `broad-egress-v1` label, so adapted runtime pods no longer
  match OCE's public HTTPS egress policy. These controls require a
  network-policy implementation that enforces Kubernetes `NetworkPolicy`.
- **No AWS credential injection by the adapter:** it rejects common AWS
  credential environment variables, disables the automatic Kubernetes API
  token, and permits only OCE's audience-scoped service-principal token.
  Operators must also verify that tenant ServiceAccounts have no IRSA
  annotation or EKS Pod Identity association. The tenant policy denies the EKS
  Pod Identity Agent endpoint. A Nitro guest can still receive an HTTP response
  from IMDS, but its IMDS credential path returns no IAM role or credentials.
- **Central gateway authentication:** AgentGateway uses strict bearer
  authentication with a separate secret slot for each tenant key. Operators
  must generate and verify different values for those slots. The central
  AgentGateway alone holds AWS identity and invokes the centrally configured
  Amazon Bedrock model. Per-tenant Bedrock inference profiles are not required.

## Database and control-plane boundary

The OpenClaw Control Plane (OCC) remains the database and control-plane
authority. Before reading or changing tenant state, it authenticates the caller,
checks access to the exact namespace or agent, and scopes database queries by
namespace. This application middleware is the compensating control: the pinned
OCE revision does not enable PostgreSQL row-level security, and its application
database role can read rows across tenants. The sample does not change that
upstream database design.

Validate this boundary through OCE's native API with two tenants:
same-tenant access succeeds and cross-tenant access returns `403`. A direct
AgentGateway request proves gateway-key enforcement only; it does not prove the
OCE database or control-plane boundary.

## Residual risks and claim limits

- Possession of a tenant bearer key grants that tenant's AgentGateway access.
  The network policy limits destinations, but it does not cryptographically
  bind a source namespace to one tenant key. A key disclosed to another tenant
  pod is therefore a boundary breach. Production use needs external key
  issuance, storage, rotation, and verification that tenant keys differ.
- The central AgentGateway and its Bedrock role are a shared trust and blast
  radius boundary. This design does not provide per-tenant IAM isolation,
  quotas, or billing attribution.
- Database isolation depends on upstream OCE authorisation and its data model,
  not on these Kubernetes controls.
- Static tests verify the rendered and admitted configuration contract. They
  do not replace live enforcement tests against the cluster, network plugin,
  storage driver, AgentGateway, OCE, and Bedrock.

If your threat model includes cross-tenant bearer-key theft, add a
namespace-bound identity that AgentGateway verifies, such as workload JWT
claims or mutual TLS, before production use.
