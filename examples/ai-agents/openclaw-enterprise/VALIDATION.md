# Validate OpenClaw Enterprise tenant isolation

Use this procedure after completing [the deployment stages](README.md). It
validates one blueprint revision and one exact set of image digests. It does
not establish a general OCE support claim.

The live validator writes test markers and replaces tenant A's runtime pod.
Run it only against retained validation tenants.

## Prerequisites

- Two deployed OCE Agents in distinct OCE and Kubernetes namespaces.
- A Ready admission adapter and AgentGateway.
- The exact digest-qualified runtime image used by both Agents.
- The OCE source revision
  `86c8c12310f691bb21651118ffffd6bfd460e9ff`.
- AWS CLI v2, `jq`, `kubectl`, Python 3, and Mike Farah `yq` version 4.
- One explicit kube context.
- One unused local TCP port.
- One new private evidence directory path.
- One protected credential file per tenant, mode `0400` or `0600`.

Each credential file can contain the complete OCE service-key response JSON,
with the key at `.data.key`, or exactly one raw service-key line. It must be a
regular file, not a symbolic link.

The local Kubernetes identity must be able to read the OCE API Service and its
selected Pod and create `pods/portforward`. It also needs the cluster and
namespace permissions exercised by the validator. The script binds its
port-forward to `127.0.0.1`, refuses an occupied port, and stops the process on
exit. Any local process can reach that loopback port while the validator runs.

## Run the static contracts

From the repository root:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install \
  --requirement examples/ai-agents/openclaw-enterprise/tests/requirements.txt
python -m pytest \
  examples/ai-agents/openclaw-enterprise/adapter \
  examples/ai-agents/openclaw-enterprise/tests
```

These tests cover source and image pins, manifests, installer and cleanup
guards, tenant network configuration, Pod Identity, and admission behaviour.
They do not prove live network enforcement, OCE authorization, or Bedrock
access.

```text
TODO: output from the fresh run
```

## Run the two-tenant live validation

Resolve the current runtime pod and container names for both Agents. Choose an
unused local port, then run:

```bash
export SAMPLE_DIR='examples/ai-agents/openclaw-enterprise'
export EVIDENCE_DIR='<new-private-evidence-directory>'

"$SAMPLE_DIR/scripts/validate-live.sh" \
  --account-id '<12-digit-account-id>' \
  --region us-west-2 \
  --cluster '<eks-cluster-name>' \
  --kube-context '<eks-kube-context>' \
  --tenant-a-namespace '<tenant-a-kubernetes-namespace>' \
  --tenant-a-pod '<tenant-a-runtime-pod>' \
  --tenant-a-container '<tenant-a-runtime-container>' \
  --tenant-b-namespace '<tenant-b-kubernetes-namespace>' \
  --tenant-b-pod '<tenant-b-runtime-pod>' \
  --tenant-b-container '<tenant-b-runtime-container>' \
  --runtime-image '<runtime-repository>@sha256:<digest>' \
  --oce-api-local-port 18081 \
  --oce-system-namespace openclaw-system \
  --oce-source-revision \
    86c8c12310f691bb21651118ffffd6bfd460e9ff \
  --tenant-a-oce-namespace '<tenant-a-ns_ID>' \
  --tenant-a-agent-id '<tenant-a-agt_ID>' \
  --tenant-a-credential-file '<protected-tenant-a-service-key-file>' \
  --tenant-b-oce-namespace '<tenant-b-ns_ID>' \
  --tenant-b-agent-id '<tenant-b-agt_ID>' \
  --tenant-b-credential-file '<protected-tenant-b-service-key-file>' \
  --evidence-dir "$EVIDENCE_DIR" \
  --confirm-pod-replacement
```

`--confirm-pod-replacement` acknowledges the destructive tenant A check. The
validator creates its own local `kubectl port-forward` to
`service/openclaw-enterprise-api`; it does not create an in-cluster API client.
It removes temporary markers, policies, the network canary namespace, and the
port-forward on exit.

```text
TODO: output from the fresh run
```

## Acceptance criteria

The command exits zero only after it records all these results:

1. Both runtimes use `isolated-sandbox`, the pinned image, and the expected
   non-root security context.
2. Each sandbox has its own kernel and boot identity.
3. Neither runtime receives AWS credentials.
4. The two runtimes use distinct PVCs and PVs, and a cross-tenant PVC mount is
   denied.
5. EKS Auto Mode enforces the temporary deny, allow, and deny network-policy
   sequence.
6. Public HTTPS and the EKS Pod Identity Agent endpoint are denied.
7. Both tenants receive a valid `nova-lite` response through the shared
   AgentGateway.
8. Each service key reads its own OCE Namespace and Agent.
9. Both cross-tenant reads return HTTP `403` with code `FORBIDDEN`.
10. Forged Pod and revision ConfigMap requests receive the expected admission
    denials.
11. An ephemeral-container update is denied.
12. Tenant A's `.openclaw` marker survives controller-driven pod replacement,
    while its generic home marker does not.
13. Tenant A receives another model response after replacement.

Retain the evidence privately. It contains deployment identifiers and topology
details, but the validator does not write service keys into the bundle. Use
`--kms-signing-key-id` when your evidence process requires a KMS signature.

## Claim limits

A passing run validates the Kubernetes, OCE API, AgentGateway, and Bedrock paths
listed above for the exact inputs. It does not prove database-level tenant
isolation, human SSO, sustained load, high availability, node-drain behaviour,
nested OpenClaw execution isolation, or compatibility with another OCE
revision.
