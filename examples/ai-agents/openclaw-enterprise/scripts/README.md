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
- Deploy the admission adapter with both digest-pinned images as described in
  [`build/README.md`](../build/README.md#deploy-the-adapter).
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

Baseline is required because the adapter-generated ownership init container
starts as UID and GID 0 with `allowPrivilegeEscalation: false` and only `CHOWN`,
`DAC_OVERRIDE`, and `FOWNER`. Restricted requires non-root execution and
permits only `NET_BIND_SERVICE` to be added after dropping all capabilities.

At runtime, the PVC root is mounted at `/home/node/.openclaw`, so `client` and
the mapped target paths are real directories. The link init container creates
a relative symlink inside `/gateway-state` only when a mount path differs from
its target.

The separately built ownership helper contains only BusyBox entry points for
`/bin/sh`, `/bin/chown`, and `/bin/chmod`. The adapter takes its image from the
mandatory `OCE_OWNERSHIP_INIT_IMAGE` setting and requires an exact digest that
differs from the workload image. Permission repair fails closed: every
directory check, `chmod`, and `chown` must succeed before OCE starts. The helper
repairs `/home/node`, `/home/node/.openclaw`, and each direct
`/home/node/.openclaw/<target>` path rather than an alias symlink. It does not
recursively change persisted files. The unwrapped OCE command then starts as
UID and GID 1000 with all capabilities dropped.

The mutating webhook rejects ordinary runtime and sidecar containers that mount
the `openclaw-gateway-state` PVC root at `/gateway-state`; only the expected
init-container path and adapter-generated helpers receive that root. A separate
validating webhook denies every ephemeral-container update in OCE-managed
namespaces. Both webhooks use `failurePolicy: Fail`, so an unavailable adapter
blocks matching pod creation and ephemeral-container updates. That is the
intended sample posture, but it raises adapter availability from a convenience
to a tenant scheduling dependency.

The adapter also rejects every volume mount path that is not a canonical
absolute path, including paths with repeated separators or traversal segments.
It requires digest-pinned workload images, rejects non-empty `envFrom` and
explicit unsafe loader or shell-bootstrap variables, and rejects mounts over
trusted bootstrap paths. These controls narrow the reviewed compatibility
boundary; they do not turn this sample into a general OCE security profile.

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
