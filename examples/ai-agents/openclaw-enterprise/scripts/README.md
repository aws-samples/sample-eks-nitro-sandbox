# OpenClaw Enterprise script reference

Use [the main blueprint](../README.md) for the runnable deployment order. This
page records each script's contract and the detailed tenant-onboarding steps.

Run scripts from the repository root with an explicit kube context. Run
`--help` before a mutating command. Store state, receipts, credentials, and
evidence in a private directory outside the repository.

## Command order

| Order | Command | Purpose |
|---|---|---|
| 1 | `setup-storage-class.sh` | Create or verify the blueprint-owned EKS Auto Mode StorageClass. |
| 2 | Apply `deploy/auto-mode-network-policy.yaml` | Enable the EKS Auto Mode network-policy controller field. |
| 3 | `setup-agentgateway-pod-identity.sh` | Create or verify AgentGateway's IAM role, Bedrock policy, and Pod Identity association. |
| 4 | `render-adapter-manifest.sh` | Replace adapter image placeholders with digest-qualified build outputs. |
| 5 | `install-oce.sh` | Install the pinned OCE revision through `occ installation install`. |
| 6 | `configure-tenant-model-gateway.sh` | Add AgentGateway CA trust and restricted egress to each tenant namespace. |
| 7 | `validate-live.sh` | Validate the two same-tenant paths and two cross-tenant denials. |
| 8 | `cleanup.sh` | Remove only receipt-matched, ownership-verified resources. |

AgentGateway and the admission adapter must be Ready before the first OCE Agent
deployment.

## `setup-storage-class.sh`

Run:

```bash
examples/ai-agents/openclaw-enterprise/scripts/setup-storage-class.sh \
  --kube-context '<eks-kube-context>'
```

The script returns `openclaw-enterprise-gp3`. It creates a non-default,
encrypted `gp3` StorageClass with the EKS Auto Mode provisioner
`ebs.csi.eks.amazonaws.com`. If that name already exists, the script verifies
the complete storage and ownership contract. It never patches or adopts the
existing resource.

Apply the Auto Mode network-policy controller setting separately:

```bash
kubectl --context '<eks-kube-context>' apply \
  --server-side \
  --field-manager=openclaw-enterprise-blueprint \
  --filename \
  examples/ai-agents/openclaw-enterprise/deploy/auto-mode-network-policy.yaml
```

This updates only `data.enable-network-policy-controller` on
`kube-system/amazon-vpc-cni`. Server-side apply reports a conflict if another
manager owns that field. Cleanup removes the field only when
`openclaw-enterprise-blueprint` is its sole manager and its value remains
`true`.

## `setup-agentgateway-pod-identity.sh`

Create the AgentGateway namespace and ServiceAccount from
`deploy/agentgateway.yaml`, then run:

```bash
examples/ai-agents/openclaw-enterprise/scripts/setup-agentgateway-pod-identity.sh \
  --aws-region us-west-2 \
  --aws-account-id '<12-digit-account-id>' \
  --eks-cluster-name '<eks-cluster-name>' \
  --kube-context '<eks-kube-context>'
```

The script binds only `openclaw-enterprise-agw/agentgateway` to the
blueprint-owned IAM role. Its inline policy permits
`amazon.nova-lite-v1:0` in the selected Region. Record the returned Pod
Identity association ID for cleanup.

## `render-adapter-manifest.sh`

Provide the three digest-qualified outputs from the same successful CodeBuild
run:

```bash
examples/ai-agents/openclaw-enterprise/scripts/render-adapter-manifest.sh \
  examples/ai-agents/openclaw-enterprise/deploy/adapter-webhook.yaml \
  "$ADAPTER_IMAGE" \
  "$OWNERSHIP_INIT_IMAGE" \
  "$RUNTIME_IMAGE" |
  kubectl --context "$KUBE_CONTEXT" apply --filename -
```

Never apply the raw manifest. The script requires Mike Farah `yq` version 4 and
rejects mutable image references.

The adapter handles only the pinned OCE pod's RuntimeClass, incompatible PVC
mount, private CA trust, and related strict Nitro compatibility. OCE's native
shared `modelProvider`, not the adapter, routes model requests to AgentGateway.

## `install-oce.sh`

The installer accepts only OCE commit
`86c8c12310f691bb21651118ffffd6bfd460e9ff` from
`https://github.com/openclaw/openclaw-enterprise.git`. The checkout must be
clean. Provide either an `occ` binary built from that checkout or `--build-occ`.

Run `install-oce.sh --help` for the complete required argument set.

The installer writes OCE's shared native model-provider configuration as:

```yaml
modelProvider:
  protocol: openai-responses
  baseUrl: https://agentgateway.openclaw-enterprise-agw.svc.cluster.local/v1
```

It disables browser gateway routing and agent native administration. It also
configures direct Pod API clients with a deliberately unmatched selector:

```yaml
podLabels:
  app.kubernetes.io/name: oce-direct-pod-api-clients-disabled
  openclaw.dev/direct-pod-api-client: disabled
```

No Pod matches that selector. Run OCE administration from a local terminal
through `kubectl port-forward`.

Choose one database mode:

- `--validation-postgres` plus a digest-pinned PostgreSQL image creates one
  disposable pod with `emptyDir` storage. The EKS cluster must carry the exact
  tag key `Environment` with value `validation`, matched case-insensitively.
  The installer rejects production-tagged clusters.
- External mode requires protected application URL, migration URL, and CA
  files plus at least one exact database `/32` CIDR. Both URLs must use a DNS
  hostname, set `sslmode=verify-full`, and set
  `sslrootcert=/etc/openclaw/database-ca/ca.pem`. The CA file must contain only
  trusted PEM CA certificates. The installer mounts it into every chart
  database client.

Repeat `--cluster-api-cidr` or `--database-cidr` for multiple exact `/32`
addresses. The receipt must be a new path below `--state-dir`.

## Access the OCE API locally

Start a loopback-only port-forward in a dedicated terminal:

```bash
kubectl --context "$KUBE_CONTEXT" \
  --namespace "$OCE_NAMESPACE" \
  port-forward --address=127.0.0.1 \
  service/openclaw-enterprise-api 18080:8080
```

In another terminal:

```bash
export OCC_URL='http://127.0.0.1:18080'
export OCC_SERVICE_KEY_FILE='<protected-service-key-response.json>'
chmod 600 "$OCC_SERVICE_KEY_FILE"
```

The local Kubernetes identity needs permission to read the Service and selected
Pod and create `pods/portforward`. The forwarded API is outside the tenant
NetworkPolicy path. Any local process can reach it while the command runs, so
bind only to loopback and stop the process when finished.

The installer writes the initial bootstrap service-key response once to
`pvc/oce-sample-bootstrap-output` as
`initial-admin-service-key.json`. Retrieve it with a short-lived, UID 1000
reader pod that mounts the claim read-only. Copy it directly into a new mode
`0600` file, then delete the reader pod. Permission to read this claim is
administrator access. Do not print `.data.key` or put it in a command argument.

## Onboard two tenants

Repeat this order for tenant A and tenant B. Complete one tenant before starting
the next.

1. Create an OCE Namespace with `occ namespace create '<name>'`. Record its
   `ns_...` ID.
2. Find the one Kubernetes namespace labelled
   `openclaw.dev/namespace=<ns_ID>`.
3. Create these RoleBindings in that Kubernetes namespace:
   `openclaw-enterprise-worker` binds
   `oce-openclaw-tenant-worker` to
   `openclaw-system:openclaw-enterprise-worker`;
   `openclaw-enterprise-api-secrets` binds
   `oce-openclaw-tenant-api` to
   `openclaw-system:openclaw-enterprise-api`; and
   `openclaw-enterprise-api-configuration` binds
   `oce-openclaw-tenant-configuration` to the same API ServiceAccount.
4. Configure private CA trust and egress:

   ```bash
   examples/ai-agents/openclaw-enterprise/scripts/configure-tenant-model-gateway.sh \
     '<eks-kube-context>' '<oce-backing-kubernetes-namespace>'
   ```

5. Put that tenant's raw AgentGateway key in a protected JSON file as
   `{"name":"openai-model-key","value":"<key>"}`. Create the OCE Secret with
   `occ secret create --file <protected-json-file>`, then delete the temporary
   file.
6. Create a `kind: agent` Configuration that selects model name and ID
   `nova-lite` through the installation's shared `openai-responses`
   `modelProvider`.
7. Create an embedded Agent with `harnessAuth.method: api_key`. Point its
   Secret source to that tenant Namespace and model Secret.
8. Create a Namespace Role with
   `{"action":"operate","resourceKind":"secret"}`. Bind the Agent service
   principal to only its own model Secret.
9. Review the saved Configuration generation. Deploy it with:

   ```bash
   occ agent deploy-first '<agent-id>' \
     --configuration '<configuration-id>' \
     --generation '<generation>' \
     --key '<unique-request-key>' \
     --output json
   occ agent deployment-status '<agent-id>'
   ```

10. Create a separate validator service principal. Grant it `read` on only the
    exact Namespace and Agent. Issue its key into a new protected file:

    ```bash
    occ service-key create \
      --service-principal '<service-principal-id>' \
      --name '<validator-key-name>' \
      --out '<new-protected-file>'
    ```

Use different AgentGateway and validator keys for the two tenants. `occ`
expects the complete service-key response selected by
`OCC_SERVICE_KEY_FILE`. The live validator accepts the same JSON file or a file
containing exactly one raw key line.

## `configure-tenant-model-gateway.sh`

The script accepts the kube context and OCE-created backing namespace as
positional arguments:

```bash
examples/ai-agents/openclaw-enterprise/scripts/configure-tenant-model-gateway.sh \
  '<eks-kube-context>' '<oce-backing-kubernetes-namespace>'
```

It verifies OCE ownership, adds the private AgentGateway CA as an immutable
ConfigMap, and applies default-deny egress with only DNS and the AgentGateway
ClusterIP `/32` allowed for adapted runtime pods.

## `validate-live.sh`

See [Validation](../VALIDATION.md) for the complete command and acceptance
criteria. The script starts and stops its own local loopback port-forward. It
does not deploy an API client pod.

## `cleanup.sh`

Pass the exact state directory, receipt, kube context, release, and tenant
namespaces used during setup. To remove AWS resources, also pass all six AWS
arguments together: Region, account ID, cluster name, Pod Identity association
ID, IAM role name, and inline policy name.

Cleanup verifies resource identity and ownership before deletion. It uninstalls
the receipt-matched OCE release, removes blueprint-owned shared namespaces and
tenant additions, and deletes the optional Pod Identity and IAM resources.

It preserves OCE-created tenant namespaces and any external database. It
deletes `openclaw-enterprise-gp3` only when no PVC references it. It removes
`enable-network-policy-controller` only when the blueprint is the field's sole
manager and the value remains `true`. A changed, shared, unowned, or referenced
resource is preserved; cleanup reports an incomplete result instead of taking
ownership by optimism. Fair call.
