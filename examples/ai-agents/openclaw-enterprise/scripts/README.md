# Configure a tenant model gateway

Use `configure-tenant-model-gateway.sh` after AgentGateway is ready and OCE has
created the tenant namespace. This procedure configures the Pod Security
profile, trust, and network isolation. Repeat the procedure for each tenant
namespace, then run the checks in [`VALIDATION.md`](../VALIDATION.md).

The separate admission adapter consumes the CA ConfigMap created here when it
adapts the compatible OCE embedded-gateway pod. Treat that adapter as a
sample-specific compatibility layer, not an upstream OCE compatibility
guarantee.

## Prerequisites

- Install `kubectl`, `jq`, `sed`, `base64` and `cmp`.
- Configure `kubectl` access to the target EKS Auto Mode cluster and choose an
  explicit context.
- Deploy AgentGateway in `openclaw-enterprise-agw`.
- Deploy the admission adapter with all required digest-pinned images as described in
  [`build/README.md`](../build/README.md#deploy-the-adapter).
- Use an OCE tenant namespace labelled
  `app.kubernetes.io/managed-by=openclaw-enterprise`.

Enable the VPC CNI network policy controller once per cluster:

```bash
kube_context="replace-with-explicit-eks-context"
kubectl config get-contexts "$kube_context"
kubectl --context "$kube_context" --namespace kube-system \
  patch configmap amazon-vpc-cni \
  --type merge \
  --patch '{"data":{"enable-network-policy":"true","enable-network-policy-controller":"true"}}'
```

Schedule the protected workloads on nodes created after this change. Existing
nodes do not gain network-policy enforcement in place.

## Configure the tenant

From the repository root, run:

```bash
kube_context="replace-with-explicit-eks-context"
tenant_namespace="replace-with-oce-tenant-namespace"
kubectl config get-contexts "$kube_context"
./examples/ai-agents/openclaw-enterprise/scripts/configure-tenant-model-gateway.sh \
  "$kube_context" "$tenant_namespace"
```

The script:

1. Verifies that OCE manages the tenant namespace.
2. Enforces the Kubernetes baseline Pod Security Standard and keeps restricted
   policy checks in audit and warning mode.
3. Reads the stable AgentGateway ClusterIP.
4. Copies the AgentGateway root certificate into the tenant namespace as the
   immutable `agentgateway-ca` ConfigMap.
5. Applies default-deny egress plus explicit DNS and HTTPS egress to the
   AgentGateway ClusterIP. Direct traffic to AgentGateway Pod IPs is not
   allowed.

The DNS and AgentGateway allow policies select
`openclaw.dev/network-profile=nitro-central-gateway-v1`. The admission adapter
replaces OCE's `broad-egress-v1` value with that profile, so adapted runtime
pods do not match OCE's public HTTPS egress policy.

Baseline is required because the adapter-generated ownership init container
starts as UID and GID 0 with `allowPrivilegeEscalation: false` and only `CHOWN`,
`DAC_OVERRIDE`, and `FOWNER`. Restricted requires non-root execution and
permits only `NET_BIND_SERVICE` to be added after dropping all capabilities.

At runtime, the PVC root is mounted at `/home/node/.openclaw`, so `client` and
the mapped target paths are real directories. The link init container creates
a relative symlink inside `/gateway-state` only when a mount path differs from
its target.

The separately built ownership helper is a statically linked binary in a
scratch image. The adapter takes its image from the mandatory
`OCE_OWNERSHIP_INIT_IMAGE` setting and requires an exact digest that differs
from the workload image. Permission repair fails closed: the helper opens only
the explicit relative-path allowlist with Linux `openat2` constraints, rejects
symbolic links and multiply linked files, and changes ownership and mode
through the checked file descriptor. The helper repairs `/home/node`,
`/home/node/.openclaw`, and each direct
`/home/node/.openclaw/<target>` path rather than an alias symlink. It does not
recursively change persisted files. Kubernetes `fsGroup` metadata on a retained
PVC can leave the existing OpenClaw runtime pin store with incompatible
ownership or modes. The helper restores `/home/node/.openclaw/control` to UID
and GID 1000 with mode `0700`, and repairs an existing `services.sqlite` and
the known `-wal`, `-shm`, and `-journal` sidecars to UID and GID 1000 with mode
`0600`. It refuses those file paths when they are symlinks or non-regular
files. The unwrapped OCE command then starts as UID and GID 1000 with all
capabilities dropped.

The mutating webhook rejects sidecars and extra init containers. It also
rejects ordinary runtime containers that mount the `openclaw-gateway-state`
PVC root at `/gateway-state`; only the expected init-container path and
adapter-generated helpers receive that root. A separate validating webhook
rechecks the complete final Pod on creation and denies every
ephemeral-container update in OCE-managed namespaces. Both webhooks use
`failurePolicy: Fail`, so an unavailable adapter blocks matching Pod creation
and ephemeral-container updates. That is the intended sample posture, but it
raises adapter availability from a convenience to a tenant scheduling
dependency.

The controller trust chain is narrower than the namespace label. The OCE worker
may create or update gateway Deployments, the Kubernetes Deployment controller
may create or update their ReplicaSets, and only configured ReplicaSet-controller
identities may create Pods. The adapter verifies that provenance. A tenant's
direct Pod request is denied even if it copies the trusted labels.

The adapter also rejects every volume mount path that is not a canonical
absolute path, including paths with repeated separators or traversal segments.
It requires digest-pinned workload images, rejects non-empty `envFrom` and
explicit unsafe loader or shell-bootstrap variables, and rejects mounts over
trusted bootstrap paths. These controls narrow the defined compatibility
boundary; they do not turn this sample into a general OCE security profile.

If an immutable CA ConfigMap already exists, the script stops when its
certificate differs. Recreate that ConfigMap only as a deliberate CA rotation.

The generated AgentGateway rule includes the Service ClusterIP as an explicit
`/32`. The central AgentGateway alone receives AWS identity and invokes Amazon
Bedrock; tenant runtime pods receive neither an IRSA role nor an EKS Pod
Identity association.
