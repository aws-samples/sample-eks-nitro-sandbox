# Configure a tenant model gateway

Use `configure-tenant-model-gateway.sh` after AgentGateway is ready and OCE has
created the tenant namespace. This procedure configures the Pod Security
profile, trust, and network isolation. The live validation completed one
OCE-created Agent flow; repeat the procedure for each tenant namespace.

The separate admission adapter consumes the CA ConfigMap created here when it
adapts compatible OCE Agent and gateway pods. Treat that adapter as a
sample-specific compatibility layer, not an upstream OCE compatibility
guarantee.

## Prerequisites

- Install `kubectl`, `jq`, `sed`, `base64` and `cmp`.
- Configure `kubectl` access to the target EKS Auto Mode cluster.
- Deploy AgentGateway in `openclaw-enterprise-agw`.
- Use an OCE tenant namespace labelled
  `app.kubernetes.io/managed-by=openclaw-enterprise`.

Enable the VPC CNI network policy controller once per cluster:

```bash
kubectl --namespace kube-system patch configmap amazon-vpc-cni \
  --type merge \
  --patch '{"data":{"enable-network-policy":"true","enable-network-policy-controller":"true"}}'
```

Schedule the protected workloads on nodes created after this change. Existing
nodes do not gain network-policy enforcement in place.

## Configure the tenant

From the repository root, run:

```bash
tenant_namespace="replace-with-oce-tenant-namespace"
./examples/ai-agents/openclaw-enterprise/scripts/configure-tenant-model-gateway.sh \
  "$tenant_namespace"
```

The script:

1. Verifies that OCE manages the tenant namespace.
2. Enforces the Kubernetes baseline Pod Security Standard and keeps restricted
   policy checks in audit and warning mode.
3. Reads the stable AgentGateway ClusterIP.
4. Copies the AgentGateway root certificate into the tenant namespace as the
   immutable `agentgateway-ca` ConfigMap.
5. Applies default-deny egress plus explicit DNS and AgentGateway egress.

Baseline is required because the Nitro compatibility wrapper briefly starts as
root with only `CHOWN`, `SETUID`, `SETGID`, and `SETPCAP`. It locks
`/home/node` to UID 1000 and mode `0700`, changes to UID and GID 1000, and
clears its capability sets before OCE starts. Review this bootstrap trade-off
against your workload policy.

If an immutable CA ConfigMap already exists, the script stops when its
certificate differs. Recreate that ConfigMap only as a deliberate CA rotation.

The generated AgentGateway rule includes the Service ClusterIP as an explicit
`/32`. In the live EKS Auto Mode test, the `PolicyEndpoint` did not add that
Service IP for the selector-based policy. Without the `/32`, traffic to the
stable ClusterIP was blocked before reaching the selected AgentGateway pods.

## Evidence boundary

The live test proved that an OCE-created Agent gateway ran in a Nitro sandbox,
reached AgentGateway, used EKS Pod Identity for Amazon Bedrock credentials, and
received a `completed` Responses-compatible API result. An invalid key returned
`401`, and an unlabelled pod was blocked.

The test did not prove a second tenant, cross-tenant denial through OCE,
replacement recovery with the latest adapter image, high availability or
fleet-scale behaviour.
