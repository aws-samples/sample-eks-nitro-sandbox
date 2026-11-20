# Run OpenClaw Enterprise agents in AWS Nitro Sandboxes on Amazon EKS

Before you start, review the
[prerequisites and shared setup](../../README.md#prerequisites) on the home page
and run the
[hello sandbox](../../getting-started/hello-sandbox/README.md) blueprint. The
commands below use files from this repository, so clone it and enter this
blueprint's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/ai-agents/openclaw-enterprise
```

This blueprint installs OpenClaw Enterprise (OCE) on Amazon EKS and runs two
tenant agent runtimes in separate
[AWS Nitro Sandboxes](https://aws.amazon.com/blogs/containers/aws-nitro-sandboxes-hardware-enforced-workload-isolation-on-amazon-eks/).
Both tenants call Amazon Nova Lite through one private, shared AgentGateway.
Only AgentGateway receives an AWS identity.

Live validation is still pending. Commands below use explicit output
placeholders instead of claiming a successful run.

*Figure 1: OCE manages two tenant agent runtimes. Each runtime has its own
kernel and persistent volume, and only the shared AgentGateway receives AWS
identity and calls Amazon Bedrock.*

![An Amazon EKS cluster runs two OCE tenant agent runtimes in separate Nitro sandboxes, each with its own persistent volume, while a shared AgentGateway with EKS Pod Identity calls Amazon Bedrock.](images/openclaw-enterprise-architecture.png)

Editable diagrams:
[architecture](images/openclaw-enterprise-architecture.drawio),
[model request](images/openclaw-enterprise-model-request.drawio), and
[pod admission](images/openclaw-enterprise-pod-admission.drawio).

## Prerequisites

- An EKS Auto Mode cluster with the `isolated-sandbox` RuntimeClass, created by
  the shared setup.
- Access to Amazon Bedrock model `amazon.nova-lite-v1:0` in `us-west-2`.
- Private OCE authentication and Agent DNS names that resolve from the cluster.
- [cert-manager](https://cert-manager.io/docs/installation/) `v1.21.3`
  for a new installation, or an existing installation that serves the
  `cert-manager.io/v1` `Issuer` and `Certificate` APIs. The adapter and
  AgentGateway manifests create these resources.
- A reviewed, digest-pinned CodeBuild builder image in private Amazon ECR.
- AWS CLI v2, Bash, Git, Go, Helm, `jq`, `kubectl`, OpenSSL, Python 3, and
  [Mike Farah `yq`](https://github.com/mikefarah/yq) `v4.54.3`.
- Kubernetes permission to create cluster-scoped admission resources and a
  StorageClass and create `pods/portforward` requests.
- AWS permission to manage the blueprint IAM role and EKS Pod Identity
  association.

This terminal-managed topology disables OCE gateway routing and native browser
routing. It does not require Gateway API, Envoy Gateway, or their CRDs, and the
blueprint does not install them.

Keep credentials, account details, generated state, receipts, and validation
evidence outside the repository.

This blueprint incurs charges for the EKS cluster and worker capacity,
Amazon EBS volumes, CodeBuild, private ECR storage and scanning, CloudWatch
Logs, KMS keys, and Amazon Bedrock model usage. Delete the resources when you
finish.

## Overview

OCE creates and controls each tenant runtime. Its native shared
`modelProvider` uses the `openai-responses` protocol and the private HTTPS URL
`https://agentgateway.openclaw-enterprise-agw.svc.cluster.local/v1`.
AgentGateway authenticates separate tenant keys and makes the Bedrock request
with EKS Pod Identity.

The admission adapter is a compatibility layer for the pinned OCE pod shape. It
sets the RuntimeClass, replaces the incompatible state PVC mount, installs the
private CA trust, and applies the related strict Nitro compatibility changes.
It does not implement or redirect model routing.

*Figure 2: Tenant runtimes use OCE's native model provider path. The shared,
stateless AgentGateway holds no tenant runtime state.*

![A model request travels from each OCE tenant runtime through a private HTTPS AgentGateway to Amazon Bedrock.](images/openclaw-enterprise-model-request.png)

The blueprint layers these controls:

| Boundary | How the blueprint enforces it | Remaining shared boundary |
|---|---|---|
| Compute | The fail-closed admission chain verifies the OCE controller lineage and expected pod shape, then sets `runtimeClassName: isolated-sandbox`. Each admitted runtime gets its own Nitro sandbox VM, kernel, and memory boundary. | The OCE control plane and EKS cluster remain shared. |
| Storage | The adapter derives the expected PVC from the gateway identity and rejects another claim. Each runtime mounts its own persistent volume. | The OCE database is shared and is outside the runtime storage boundary. |
| Network | The blueprint leaves pod networking at the cluster default so runtimes can reach the private AgentGateway. It makes no network-isolation claim. | Add network controls separately. The pinned OCE revision needs upstream support for private model services before its generated egress policies can be enforced with this topology. |
| AWS identity | Tenant runtimes receive no EKS Pod Identity association, IRSA annotation, common AWS credential variables, or unapproved credential-capable mounts. | AgentGateway alone has a shared IAM role for the configured Bedrock model. |
| OCE authorization | Each validator identity receives `read` permission on only its own OCE namespace and agent. The live test requires same-tenant success and cross-tenant HTTP `403` responses. | A compromised OCE control plane or copied bearer key is outside this boundary. |

The adapter does not modify upstream OCE, choose a model, or rewrite model
routing. It applies a narrow pod-admission compatibility patch only after all
expected ownership and pod-shape checks pass. A mismatch is refused rather
than admitted unchanged.

### Database and control-plane boundary

AgentGateway is shared and stateless. It stores no tenant runtime state, but
all tenants depend on its Deployment, private Service, bearer-key
configuration, and Bedrock IAM role. Separate AgentGateway keys authorize
tenant requests, so per-tenant Bedrock inference profiles are not required.

The OCE control plane and database are also shared. This blueprint does not
modify upstream OCE and does not enable PostgreSQL row-level security. It
validates OCE API authorization and makes no claim about database row
isolation. Use separate control planes, databases, clusters, or AWS accounts
when your threat model requires those stronger boundaries.

## Versions

| Component | Version or constraint |
|---|---|
| OpenClaw Enterprise | Chart `0.1.0` at commit `86c8c12310f691bb21651118ffffd6bfd460e9ff` |
| AgentGateway | `v1.7.0`, digest-pinned in `deploy/agentgateway.yaml` |
| Amazon Bedrock model | `amazon.nova-lite-v1:0` in `us-west-2` |
| Adapter, controller, ownership helper, runtime | Digest-qualified outputs from one successful CodeBuild run |
| cert-manager | `v1.21.3` |
| `yq` | Mike Farah `yq` `v4.54.3` |

## Files

| Path | Purpose |
|---|---|
| [`build/template.yaml`](build/template.yaml) | Build and scan the four deployable images. |
| [`deploy/adapter-webhook.yaml`](deploy/adapter-webhook.yaml) | Define the admission adapter; adjacent manifests define AgentGateway and storage settings. |
| [`scripts/setup-storage-class.sh`](scripts/setup-storage-class.sh) | Create or verify the blueprint-owned EKS Auto Mode StorageClass. |
| [`scripts/setup-agentgateway-pod-identity.sh`](scripts/setup-agentgateway-pod-identity.sh) | Create or verify AgentGateway's IAM role, Bedrock policy, and Pod Identity association. |
| [`scripts/install-oce.sh`](scripts/install-oce.sh) | Install the exact OCE revision in a terminal-managed topology. |
| [`scripts/configure-tenant-model-gateway.sh`](scripts/configure-tenant-model-gateway.sh) | Add private AgentGateway CA trust to one OCE tenant namespace. |
| [`scripts/validate-live.sh`](scripts/validate-live.sh) | Run the destructive two-tenant validation. |
| [`scripts/cleanup.sh`](scripts/cleanup.sh) | Remove resources only after ownership checks pass. |

**Step 1: Set local values and check access**

Use one explicit kube context and kubeconfig throughout:

```bash
export SAMPLE_DIR="$PWD"
export KUBECONFIG='<absolute-kubeconfig-path>'
export KUBE_CONTEXT='<eks-kube-context>'
export AWS_ACCOUNT_ID='<12-digit-account-id>'
export AWS_REGION='us-west-2'
export EKS_CLUSTER_NAME='<eks-cluster-name>'
export PRIVATE_STATE_DIR='<private-directory-outside-the-repository>'
export CERT_MANAGER_VERSION='v1.21.3'
export YQ_VERSION='v4.54.3'

chmod 600 "$KUBECONFIG"
install -d -m 700 "$PRIVATE_STATE_DIR"
kubectl --context "$KUBE_CONTEXT" config get-contexts "$KUBE_CONTEXT"
kubectl --context "$KUBE_CONTEXT" get --raw=/readyz
test "$(yq --version | awk '{print $NF}')" = "$YQ_VERSION"
```

Install the pinned cert-manager release when the cluster does not already have
a shared cert-manager installation:

```bash
if kubectl --context "$KUBE_CONTEXT" \
  --namespace cert-manager get deployment cert-manager >/dev/null 2>&1; then
  existing_cert_manager_version="$(
    kubectl --context "$KUBE_CONTEXT" \
      --namespace cert-manager get deployment \
      cert-manager cert-manager-webhook cert-manager-cainjector \
      --output json |
      jq -er '
        [.items[].metadata.labels["app.kubernetes.io/version"]]
        | unique
        | if length == 1 then .[0]
          else error("cert-manager components have inconsistent versions")
          end
      '
  )"
  printf 'Using existing cert-manager %s without modifying it.\n' \
    "$existing_cert_manager_version"
else
  helm upgrade --install cert-manager \
    oci://quay.io/jetstack/charts/cert-manager \
    --version "$CERT_MANAGER_VERSION" \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true
fi
kubectl --context "$KUBE_CONTEXT" --namespace cert-manager \
  rollout status deployment/cert-manager
kubectl --context "$KUBE_CONTEXT" --namespace cert-manager \
  rollout status deployment/cert-manager-webhook
kubectl --context "$KUBE_CONTEXT" --namespace cert-manager \
  rollout status deployment/cert-manager-cainjector
for crd in issuers.cert-manager.io certificates.cert-manager.io; do
  kubectl --context "$KUBE_CONTEXT" wait \
    --for=condition=Established "customresourcedefinition/$crd"
  kubectl --context "$KUBE_CONTEXT" get \
    "customresourcedefinition/$crd" --output json |
    jq -e '
      any(
        .spec.versions[];
        .name == "v1" and .served == true
      )
    ' >/dev/null
done
```

cert-manager is a shared cluster prerequisite. The cleanup script does not
delete or upgrade it.

```text
TODO: output from the fresh run
```

**Step 2: Build and scan the images**

Mirror a reviewed CodeBuild builder image into private ECR and record its
digest. This image runs privileged Docker and can write release images, so do
not select it by tag.

```bash
aws cloudformation deploy \
  --stack-name openclaw-enterprise-images \
  --template-file build/template.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    SampleGitRevision="$(git -C ../../.. rev-parse HEAD)" \
    BuilderImageRepositoryName='<reviewed-builder-repository>' \
    BuilderImageDigest='sha256:<64-lowercase-hex-characters>' \
    TrustedBuildInvokerArn="arn:aws:iam::${AWS_ACCOUNT_ID}:role/<release-role-name>"
```

The stack creates four encrypted, immutable ECR repositories and a fixed Step
Functions workflow. CodeBuild checks out this repository and OCE at exact
commits, builds the adapter, controller, ownership helper, and runtime images,
waits for their scans, and exports digest-qualified references.

Assume the generated invocation role in a subshell and start the fixed
workflow. The temporary credentials disappear when the subshell exits; only
the four non-secret image references are returned to the operator shell:

```bash
invocation_role_arn="$(
  aws cloudformation describe-stacks \
    --stack-name openclaw-enterprise-images \
    --query 'Stacks[0].Outputs[?OutputKey==`BuildInvocationRoleArn`].OutputValue' \
    --output text
)"
state_machine_arn="$(
  aws cloudformation describe-stacks \
    --stack-name openclaw-enterprise-images \
    --query 'Stacks[0].Outputs[?OutputKey==`BuildStateMachineArn`].OutputValue' \
    --output text
)"
(
credentials="$(
  aws sts assume-role \
    --role-arn "$invocation_role_arn" \
    --role-session-name openclaw-enterprise-image-build
)"
trap 'unset credentials AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN' EXIT
export AWS_ACCESS_KEY_ID="$(
  printf '%s' "$credentials" | jq -er '.Credentials.AccessKeyId'
)"
export AWS_SECRET_ACCESS_KEY="$(
  printf '%s' "$credentials" | jq -er '.Credentials.SecretAccessKey'
)"
export AWS_SESSION_TOKEN="$(
  printf '%s' "$credentials" | jq -er '.Credentials.SessionToken'
)"
execution_arn="$(
  aws stepfunctions start-execution \
    --state-machine-arn "$state_machine_arn" \
    --input '{}' \
    --query executionArn \
    --output text
)"
while :; do
  execution_json="$(
    aws stepfunctions describe-execution --execution-arn "$execution_arn"
  )"
  status="$(printf '%s' "$execution_json" | jq -r '.status')"
  case "$status" in
    SUCCEEDED)
      build_id="$(
        printf '%s' "$execution_json" |
          jq -er '.output | fromjson | .Build.Id'
      )"
      break
      ;;
    FAILED|ABORTED|TIMED_OUT)
      printf '%s' "$execution_json" | jq '{status, error, cause}' >&2
      exit 1
      ;;
  esac
  sleep 20
done
build_json="$(aws codebuild batch-get-builds --ids "$build_id")"
test "$(printf '%s' "$build_json" | jq -r '.builds[0].buildStatus')" = \
  'SUCCEEDED'

image_outputs="$PRIVATE_STATE_DIR/image-build-outputs.json"
printf '%s' "$build_json" |
  jq -e '
    .builds[0].exportedEnvironmentVariables
    | map({key: .name, value: .value})
    | from_entries
    | {
        ADAPTER_IMAGE,
        CONTROLLER_IMAGE,
        OWNERSHIP_INIT_IMAGE,
        RUNTIME_IMAGE
      }
    | if all(.[]; type == "string" and contains("@sha256:"))
      then .
      else error("missing digest-qualified image output")
      end
  ' >"$image_outputs"
chmod 600 "$image_outputs"
)

export ADAPTER_IMAGE="$(
  jq -er '.ADAPTER_IMAGE' "$PRIVATE_STATE_DIR/image-build-outputs.json"
)"
export CONTROLLER_IMAGE="$(
  jq -er '.CONTROLLER_IMAGE' "$PRIVATE_STATE_DIR/image-build-outputs.json"
)"
export OWNERSHIP_INIT_IMAGE="$(
  jq -er '.OWNERSHIP_INIT_IMAGE' "$PRIVATE_STATE_DIR/image-build-outputs.json"
)"
export RUNTIME_IMAGE="$(
  jq -er '.RUNTIME_IMAGE' "$PRIVATE_STATE_DIR/image-build-outputs.json"
)"
```

Use all four outputs from the same build. Do not substitute image tags.

CodeBuild has no project setting or resource policy that blocks every direct
build override. Human and CI principals must not have
`codebuild:StartBuild`, `codebuild:StartBuildBatch`, or
`codebuild:RetryBuild` on this project. Use a permissions boundary or SCP to
enforce that deny, and exempt only `ImageBuildWorkflowRole`. Release operators
should receive only permission to assume the generated invocation role.

```text
TODO: output from the fresh run
```

**Step 3: Configure storage**

Create or verify the non-default, encrypted `gp3` StorageClass:

```bash
export RUNTIME_STORAGE_CLASS="$(
  "$SAMPLE_DIR/scripts/setup-storage-class.sh" \
    --kube-context "$KUBE_CONTEXT"
)"
test "$RUNTIME_STORAGE_CLASS" = 'openclaw-enterprise-gp3'
```

The script creates the StorageClass only when it is absent. It refuses to patch
or adopt an existing resource with the same name unless the complete storage
and ownership contract already matches.

```text
TODO: output from the fresh run
```

**Step 4: Install AgentGateway and Pod Identity**

The setup script creates this IAM policy and attaches it to a role associated
only with the `openclaw-enterprise-agw/agentgateway` ServiceAccount:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InvokeNovaLiteFoundationModelUsWest2",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": "arn:aws:bedrock:us-west-2::foundation-model/amazon.nova-lite-v1:0",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "us-west-2"
        }
      }
    }
  ]
}
```

Create the AgentGateway namespace and ServiceAccount before the Pod Identity
association:

```bash
yq ea '
  select(
    .kind == "Namespace" or
    (.kind == "ServiceAccount" and .metadata.name == "agentgateway")
  )
' "$SAMPLE_DIR/deploy/agentgateway.yaml" |
  kubectl --context "$KUBE_CONTEXT" apply --filename -

"$SAMPLE_DIR/scripts/setup-agentgateway-pod-identity.sh" \
  --aws-region "$AWS_REGION" \
  --aws-account-id "$AWS_ACCOUNT_ID" \
  --eks-cluster-name "$EKS_CLUSTER_NAME" \
  --kube-context "$KUBE_CONTEXT"
```

Record the returned association ID for cleanup:

```bash
export POD_IDENTITY_ASSOCIATION_ID='<association-id-from-script-output>'
```

Create distinct tenant keys and the AgentGateway session key:

```bash
umask 077
openssl rand -hex 32 >"$PRIVATE_STATE_DIR/tenant-a-agentgateway.key"
openssl rand -hex 32 >"$PRIVATE_STATE_DIR/tenant-b-agentgateway.key"
openssl dgst -sha256 -r "$PRIVATE_STATE_DIR/tenant-a-agentgateway.key" |
  awk '{print $1}' >"$PRIVATE_STATE_DIR/tenant-a-sha256"
openssl dgst -sha256 -r "$PRIVATE_STATE_DIR/tenant-b-agentgateway.key" |
  awk '{print $1}' >"$PRIVATE_STATE_DIR/tenant-b-sha256"
openssl rand -hex 32 >"$PRIVATE_STATE_DIR/agentgateway-session.key"

kubectl --context "$KUBE_CONTEXT" \
  --namespace openclaw-enterprise-agw create secret generic agw-client-key \
  --from-file=tenant-a-sha256="$PRIVATE_STATE_DIR/tenant-a-sha256" \
  --from-file=tenant-b-sha256="$PRIVATE_STATE_DIR/tenant-b-sha256" \
  --dry-run=client --output=yaml |
  kubectl --context "$KUBE_CONTEXT" apply --filename -

kubectl --context "$KUBE_CONTEXT" \
  --namespace openclaw-enterprise-agw create secret generic agw-session-key \
  --from-file=key="$PRIVATE_STATE_DIR/agentgateway-session.key" \
  --dry-run=client --output=yaml |
  kubectl --context "$KUBE_CONTEXT" apply --filename -

kubectl --context "$KUBE_CONTEXT" apply \
  --filename "$SAMPLE_DIR/deploy/agentgateway.yaml"
kubectl --context "$KUBE_CONTEXT" \
  --namespace openclaw-enterprise-agw rollout status \
  deployment/agentgateway
```

```text
TODO: output from the fresh run
```

**Step 5: Install the admission adapter**

Render all three digest-qualified image references before applying the
manifest:

```bash
"$SAMPLE_DIR/scripts/render-adapter-manifest.sh" \
  "$SAMPLE_DIR/deploy/adapter-webhook.yaml" \
  "$ADAPTER_IMAGE" \
  "$OWNERSHIP_INIT_IMAGE" \
  "$RUNTIME_IMAGE" |
  kubectl --context "$KUBE_CONTEXT" apply --filename -

kubectl --context "$KUBE_CONTEXT" \
  --namespace openclaw-enterprise-adapter rollout status \
  deployment/openclaw-enterprise-nitro-adapter
```

Do not apply the raw adapter manifest. It contains image placeholders. Wait for
the adapter before creating the first OCE Agent because its admission webhooks
fail closed.

*Figure 3: The adapter accepts only the pinned controller chain and expected pod
shape before applying the Nitro compatibility patch.*

![The admission flow verifies OCE controllers, revisions, images, and pod shape before setting the Nitro RuntimeClass and compatible storage and trust settings.](images/openclaw-enterprise-pod-admission.png)

```text
TODO: output from the fresh run
```

**Step 6: Install the pinned OCE revision**

Clone OCE into a clean directory and verify the exact revision:

```bash
export OCE_SOURCE_DIR='<clean-openclaw-enterprise-checkout>'
git clone https://github.com/openclaw/openclaw-enterprise.git "$OCE_SOURCE_DIR"
git -C "$OCE_SOURCE_DIR" switch --detach \
  86c8c12310f691bb21651118ffffd6bfd460e9ff
test "$(git -C "$OCE_SOURCE_DIR" rev-parse HEAD)" = \
  86c8c12310f691bb21651118ffffd6bfd460e9ff
test -z "$(git -C "$OCE_SOURCE_DIR" status --porcelain)"
```

Use the disposable PostgreSQL mode only on an EKS cluster tagged
`Environment=validation`:

```bash
export OCE_NAMESPACE='openclaw-system'
export OCE_STATE_DIR="$PRIVATE_STATE_DIR/oce-install"
export OCE_RECEIPT_DIR="$OCE_STATE_DIR/receipt"
export OCE_VALIDATION_POSTGRES_IMAGE='<postgres-repository>@sha256:<digest>'

"$SAMPLE_DIR/scripts/install-oce.sh" \
  --aws-account-id "$AWS_ACCOUNT_ID" \
  --aws-region "$AWS_REGION" \
  --eks-cluster-name "$EKS_CLUSTER_NAME" \
  --kubeconfig "$KUBECONFIG" \
  --kube-context "$KUBE_CONTEXT" \
  --oce-source "$OCE_SOURCE_DIR" \
  --build-occ \
  --controller-image "$CONTROLLER_IMAGE" \
  --runtime-image "$RUNTIME_IMAGE" \
  --auth-base-url 'https://<private-auth-host>' \
  --agent-domain '<private-agent-domain>' \
  --admin-email '<initial-admin-email>' \
  --runtime-storage-class "$RUNTIME_STORAGE_CLASS" \
  --pod-cidr '<cluster-pod-cidr>' \
  --cluster-api-cidr '<eks-private-api-ip>/32' \
  --state-dir "$OCE_STATE_DIR" \
  --receipt "$OCE_RECEIPT_DIR" \
  --namespace "$OCE_NAMESPACE" \
  --validation-postgres \
  --validation-postgres-image "$OCE_VALIDATION_POSTGRES_IMAGE"
```

This optional database is a single validation-only pod with `emptyDir`
storage. Its data disappears when the pod or system namespace is removed.

For an external database, omit the two validation flags and provide protected
application URL, migration URL, and CA files plus at least one exact database
`/32` CIDR. Both URLs must use a DNS hostname, `sslmode=verify-full`, and
`sslrootcert=/etc/openclaw/database-ca/ca.pem`. The CA file must contain only
trusted PEM CA certificates. See `install-oce.sh --help`.

The installer uses `occ installation install`. It deliberately disables direct
Pod API clients with an unmatched label selector. It also disables browser
gateway routing and agent native administration. Use local `kubectl
port-forward` for API administration.

```text
TODO: output from the fresh run
```

**Step 7: Onboard two tenants from the terminal**

Complete this sequence once for tenant A and once for tenant B. Finish one
tenant before starting the next, and use separate OCE namespaces, backing
Kubernetes namespaces, AgentGateway keys, agents, and validator service keys.

Open the private OCE API on loopback in a dedicated terminal:

```bash
kubectl --context "$KUBE_CONTEXT" \
  --namespace "$OCE_NAMESPACE" \
  port-forward --address=127.0.0.1 \
  service/openclaw-enterprise-api 18080:8080
```

In another terminal:

```bash
export OCC_URL='http://127.0.0.1:18080'
export OCC_SERVICE_KEY_FILE="$PRIVATE_STATE_DIR/initial-admin-service-key.json"
```

The installer writes the bootstrap response to
`pvc/oce-sample-bootstrap-output` as
`initial-admin-service-key.json`. Retrieve it without printing the key, using a
short-lived pod that mounts the claim read-only:

```bash
export BOOTSTRAP_READER_POD='oce-bootstrap-reader'
bootstrap_key_tmp="$(mktemp "$PRIVATE_STATE_DIR/bootstrap-key.XXXXXX")"
chmod 600 "$bootstrap_key_tmp"
trap 'kubectl --context "$KUBE_CONTEXT" --namespace "$OCE_NAMESPACE" delete \
  pod "$BOOTSTRAP_READER_POD" --ignore-not-found >/dev/null; \
  rm -f "$bootstrap_key_tmp"' EXIT

jq -n \
  --arg namespace "$OCE_NAMESPACE" \
  --arg image "$CONTROLLER_IMAGE" \
  --arg pod "$BOOTSTRAP_READER_POD" \
  '{
    apiVersion: "v1",
    kind: "Pod",
    metadata: {
      name: $pod,
      namespace: $namespace,
      labels: {"app.kubernetes.io/managed-by": "openclaw-enterprise-blueprint"}
    },
    spec: {
      automountServiceAccountToken: false,
      restartPolicy: "Never",
      securityContext: {
        runAsNonRoot: true,
        runAsUser: 1000,
        runAsGroup: 1000,
        fsGroup: 1000,
        seccompProfile: {type: "RuntimeDefault"}
      },
      containers: [{
        name: "reader",
        image: $image,
        command: ["node", "-e", "setInterval(() => {}, 300000)"],
        securityContext: {
          allowPrivilegeEscalation: false,
          readOnlyRootFilesystem: true,
          capabilities: {drop: ["ALL"]}
        },
        volumeMounts: [{
          name: "bootstrap",
          mountPath: "/bootstrap",
          readOnly: true
        }]
      }],
      volumes: [{
        name: "bootstrap",
        persistentVolumeClaim: {
          claimName: "oce-sample-bootstrap-output",
          readOnly: true
        }
      }]
    }
  }' |
  kubectl --context "$KUBE_CONTEXT" apply --filename -
kubectl --context "$KUBE_CONTEXT" --namespace "$OCE_NAMESPACE" \
  wait --for=condition=Ready "pod/$BOOTSTRAP_READER_POD" --timeout=120s
kubectl --context "$KUBE_CONTEXT" --namespace "$OCE_NAMESPACE" \
  exec "$BOOTSTRAP_READER_POD" -- \
  node -e \
    'process.stdout.write(require("fs").readFileSync(
      "/bootstrap/initial-admin-service-key.json"))' \
  >"$bootstrap_key_tmp"
jq -e '.data.key | type == "string" and length > 0' \
  "$bootstrap_key_tmp" >/dev/null
mv "$bootstrap_key_tmp" "$OCC_SERVICE_KEY_FILE"
kubectl --context "$KUBE_CONTEXT" --namespace "$OCE_NAMESPACE" \
  delete pod "$BOOTSTRAP_READER_POD"
trap - EXIT
```

Permission to read this claim is administrator access. Keep the resulting file
at mode `0600`.

The local Kubernetes identity needs permission to read the Service and its
selected Pod and to create `pods/portforward`. Port-forwarding bypasses
in-cluster NetworkPolicy for the operator path and gives local processes on the
workstation access to the forwarded API. Bind only to `127.0.0.1`, protect the
service key, and stop the process when administration is complete.

For each tenant, create an OCE namespace and identify its one Kubernetes
namespace:

```bash
export TENANT_NAME='<tenant-a-or-tenant-b>'
export NAMESPACE_ID="$(
  occ namespace create "$TENANT_NAME" --output json |
    jq -er '.id'
)"
export TENANT_NAMESPACE="$(
  kubectl --context "$KUBE_CONTEXT" get namespaces \
    --selector "openclaw.dev/namespace=$NAMESPACE_ID" \
    --output json |
    jq -er '
      if (.items | length) == 1
      then .items[0].metadata.name
      else error("expected exactly one OCE backing namespace")
      end
    '
)"
```

Give the OCE worker and API only the Kubernetes permissions required in that
namespace:

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_NAMESPACE" \
  create rolebinding openclaw-enterprise-worker \
  --clusterrole oce-openclaw-tenant-worker \
  --serviceaccount openclaw-system:openclaw-enterprise-worker
kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_NAMESPACE" \
  create rolebinding openclaw-enterprise-api-secrets \
  --clusterrole oce-openclaw-tenant-api \
  --serviceaccount openclaw-system:openclaw-enterprise-api
kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_NAMESPACE" \
  create rolebinding openclaw-enterprise-api-configuration \
  --clusterrole oce-openclaw-tenant-configuration \
  --serviceaccount openclaw-system:openclaw-enterprise-api

"$SAMPLE_DIR/scripts/configure-tenant-model-gateway.sh" \
  "$KUBE_CONTEXT" "$TENANT_NAMESPACE"
```

Set the tenant-specific key path and create the namespace-owned model Secret:

```bash
export OCC_NAMESPACE="$NAMESPACE_ID"
export TENANT_MODEL_KEY_FILE="$PRIVATE_STATE_DIR/$TENANT_NAME-agentgateway.key"
export TENANT_WORK_DIR="$PRIVATE_STATE_DIR/$TENANT_NAME"
install -d -m 700 "$TENANT_WORK_DIR"

jq -Rs \
  '{name:"agentgateway-key",value:gsub("\n";"")}' \
  "$TENANT_MODEL_KEY_FILE" >"$TENANT_WORK_DIR/model-secret.json"
export MODEL_SECRET_ID="$(
  occ secret create \
    --file "$TENANT_WORK_DIR/model-secret.json" \
    --output json |
    jq -er '.id'
)"
rm "$TENANT_WORK_DIR/model-secret.json"
```

Create an embedded OpenClaw configuration. The default OpenAI URL is required
in the agent metadata; the installation-level model provider replaces it with
the private AgentGateway URL when OCE prepares the revision.

```bash
cat >"$TENANT_WORK_DIR/configuration.json" <<'JSON'
{
  "kind": "agent",
  "values": {
    "gateway": {
      "mode": "local",
      "bind": "lan",
      "controlUi": {
        "enabled": true,
        "allowedOrigins": [
          "http://127.0.0.1:18789",
          "http://localhost:18789"
        ]
      },
      "auth": {
        "password": {
          "source": "env",
          "provider": "default",
          "id": "OPENCLAW_GATEWAY_PASSWORD"
        }
      },
      "http": {
        "endpoints": {
          "chatCompletions": {
            "enabled": true
          }
        }
      }
    },
    "agents": {
      "defaults": {
        "model": "openai/nova-lite",
        "skipBootstrap": true,
        "models": {
          "openai/nova-lite": {
            "agentRuntime": {
              "id": "openclaw"
            }
          }
        }
      }
    },
    "models": {
      "providers": {
        "openai": {
          "baseUrl": "https://api.openai.com/v1",
          "api": "openai-responses",
          "models": [
            {
              "id": "nova-lite",
              "name": "nova-lite"
            }
          ]
        }
      }
    }
  }
}
JSON

export CONFIGURATION_ID="$(
  occ configuration create \
    --file "$TENANT_WORK_DIR/configuration.json" \
    --output json |
    jq -er '.id'
)"
export CONFIGURATION_GENERATION="$(
  occ configuration get "$CONFIGURATION_ID" --output json |
    jq -er '.generation'
)"
```

Create the agent with its own model credential:

```bash
jq -n \
  --arg name "$TENANT_NAME-agent" \
  --arg configuration "$CONFIGURATION_ID" \
  --arg namespace "$NAMESPACE_ID" \
  --arg secret "$MODEL_SECRET_ID" \
  '{
    name: $name,
    configurationId: $configuration,
    executionMode: "embedded",
    harnessAuth: {
      method: "api_key",
      source: {
        kind: "secret",
        namespaceId: $namespace,
        id: $secret
      }
    }
  }' >"$TENANT_WORK_DIR/agent.json"
export AGENT_RESPONSE="$(
  occ agent create \
    --file "$TENANT_WORK_DIR/agent.json" \
    --output json
)"
export AGENT_ID="$(printf '%s' "$AGENT_RESPONSE" | jq -er '.id')"
export AGENT_SERVICE_PRINCIPAL_ID="$(
  printf '%s' "$AGENT_RESPONSE" |
    jq -er '.servicePrincipalId'
)"
unset AGENT_RESPONSE
```

Give the agent service principal permission to operate only its own model
Secret:

```bash
cat >"$TENANT_WORK_DIR/model-secret-role.json" <<'JSON'
{
  "name": "Use a model Secret",
  "permissions": [
    {
      "action": "operate",
      "resourceKind": "secret"
    }
  ]
}
JSON
export MODEL_SECRET_ROLE_ID="$(
  occ iam role create \
    --file "$TENANT_WORK_DIR/model-secret-role.json" \
    --output json |
    jq -er '.id'
)"
jq -n \
  --arg principal "$AGENT_SERVICE_PRINCIPAL_ID" \
  --arg role "$MODEL_SECRET_ROLE_ID" \
  --arg secret "$MODEL_SECRET_ID" \
  '{
    subjectKind: "identity",
    subjectId: $principal,
    roleId: $role,
    resourceKind: "secret",
    resourceId: $secret
  }' >"$TENANT_WORK_DIR/model-secret-binding.json"
occ iam access-binding create \
  --file "$TENANT_WORK_DIR/model-secret-binding.json" \
  --output json >/dev/null
```

Deploy exactly the configuration generation you reviewed:

```bash
export FIRST_DEPLOYMENT_KEY="$TENANT_NAME-first"
export REVISION_ID="$(
  occ agent deploy-first "$AGENT_ID" \
    --configuration "$CONFIGURATION_ID" \
    --generation "$CONFIGURATION_GENERATION" \
    --key "$FIRST_DEPLOYMENT_KEY" \
    --output json |
    jq -er '.revisionId'
)"
occ agent deployment-status "$AGENT_ID" "$REVISION_ID"
```

Create a separate validator service principal for this tenant. Grant it
`read` on only the exact namespace and agent, then issue its key into a new
protected file:

```bash
export VALIDATOR_SERVICE_PRINCIPAL_ID="$(
  occ iam service-principal create \
    --namespace "$NAMESPACE_ID" \
    --output json |
    jq -er '.id'
)"
cat >"$TENANT_WORK_DIR/validator-role.json" <<'JSON'
{
  "name": "Read Namespace and Agent",
  "permissions": [
    {
      "action": "read",
      "resourceKind": "namespace"
    },
    {
      "action": "read",
      "resourceKind": "agent"
    }
  ]
}
JSON
export VALIDATOR_ROLE_ID="$(
  occ iam role create \
    --file "$TENANT_WORK_DIR/validator-role.json" \
    --output json |
    jq -er '.id'
)"
for target in "namespace:$NAMESPACE_ID" "agent:$AGENT_ID"; do
  jq -n \
    --arg principal "$VALIDATOR_SERVICE_PRINCIPAL_ID" \
    --arg role "$VALIDATOR_ROLE_ID" \
    --arg kind "${target%%:*}" \
    --arg id "${target#*:}" \
    '{
      subjectKind: "identity",
      subjectId: $principal,
      roleId: $role,
      resourceKind: $kind,
      resourceId: $id
    }' >"$TENANT_WORK_DIR/validator-binding.json"
  occ iam access-binding create \
    --file "$TENANT_WORK_DIR/validator-binding.json" \
    --output json >/dev/null
done

export VALIDATOR_KEY_FILE="$TENANT_WORK_DIR/validator-service-key.json"
test ! -e "$VALIDATOR_KEY_FILE"
occ service-key create \
  --namespace "$NAMESPACE_ID" \
  --service-principal "$VALIDATOR_SERVICE_PRINCIPAL_ID" \
  --name "$TENANT_NAME-validator" \
  --expires-in-days 30 \
  --out "$VALIDATOR_KEY_FILE"
jq -e '.data.key | type == "string" and length > 0' \
  "$VALIDATOR_KEY_FILE" >/dev/null
test "$(stat -f '%Lp' "$VALIDATOR_KEY_FILE" 2>/dev/null ||
  stat -c '%a' "$VALIDATOR_KEY_FILE")" = '600'
```

Discover the one ready gateway pod for the deployed revision:

```bash
export RUNTIME_POD="$(
  kubectl --context "$KUBE_CONTEXT" \
    --namespace "$TENANT_NAMESPACE" \
    get pods \
    --selector \
      "app.kubernetes.io/managed-by=openclaw-enterprise,openclaw.dev/workload-role=gateway,openclaw.dev/namespace=$NAMESPACE_ID,openclaw.dev/agent=$AGENT_ID,openclaw.dev/revision=$REVISION_ID" \
    --output json |
    jq -er '
      [
        .items[]
        | select(.metadata.deletionTimestamp == null)
        | select(.status.phase == "Running")
        | select(
            (.status.conditions // [])
            | any(.type == "Ready" and .status == "True")
          )
        | .metadata.name
      ]
      | if length == 1
        then .[0]
        else error("expected exactly one ready gateway pod")
        end
    '
)"
export RUNTIME_CONTAINER="$(
  kubectl --context "$KUBE_CONTEXT" \
    --namespace "$TENANT_NAMESPACE" \
    get pod "$RUNTIME_POD" \
    --output json |
    jq -er '
      [
        .spec.containers[]
        | select(any(.ports[]?; .name == "http"))
        | .name
      ]
      | if length == 1
        then .[0]
        else error("expected exactly one gateway HTTP container")
        end
    '
)"
```

The `--out` path must not exist. `occ` creates it with mode `0600`. Record each
namespace ID, agent ID, backing namespace, runtime pod and container, and
validator key path for the next step.

```text
TODO: output from the fresh run
```

**Step 8: Validate the two-tenant boundary**

Run the static contracts from the repository root:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install \
  --requirement \
  examples/ai-agents/openclaw-enterprise/tests/requirements.txt
python -m pytest \
  examples/ai-agents/openclaw-enterprise/adapter \
  examples/ai-agents/openclaw-enterprise/tests
```

Then run the destructive two-tenant check:

```bash
export EVIDENCE_DIR='<new-private-evidence-directory>'

"$SAMPLE_DIR/scripts/validate-live.sh" \
  --account-id "$AWS_ACCOUNT_ID" \
  --region "$AWS_REGION" \
  --cluster "$EKS_CLUSTER_NAME" \
  --kube-context "$KUBE_CONTEXT" \
  --tenant-a-namespace '<tenant-a-kubernetes-namespace>' \
  --tenant-a-pod '<tenant-a-runtime-pod>' \
  --tenant-a-container '<tenant-a-runtime-container>' \
  --tenant-b-namespace '<tenant-b-kubernetes-namespace>' \
  --tenant-b-pod '<tenant-b-runtime-pod>' \
  --tenant-b-container '<tenant-b-runtime-container>' \
  --runtime-image "$RUNTIME_IMAGE" \
  --oce-api-local-port 18081 \
  --oce-system-namespace "$OCE_NAMESPACE" \
  --oce-source-revision \
    86c8c12310f691bb21651118ffffd6bfd460e9ff \
  --tenant-a-oce-namespace '<tenant-a-ns_ID>' \
  --tenant-a-agent-id '<tenant-a-agt_ID>' \
  --tenant-a-credential-file '<tenant-a-validator-key-file>' \
  --tenant-b-oce-namespace '<tenant-b-ns_ID>' \
  --tenant-b-agent-id '<tenant-b-agt_ID>' \
  --tenant-b-credential-file '<tenant-b-validator-key-file>' \
  --evidence-dir "$EVIDENCE_DIR" \
  --confirm-pod-replacement
```

The validator starts and stops its own loopback API port-forward. It writes
test markers, replaces tenant A's runtime pod, and removes temporary test
resources on exit. Run it only against retained validation tenants.

The command exits zero only after it verifies:

1. Both non-root runtimes use `isolated-sandbox` and the expected image.
2. Each sandbox has a distinct kernel, boot identity, PVC, and PV.
3. Neither runtime receives an AWS credential path.
4. A cross-tenant PVC mount, forged pod, forged revision ConfigMap, and
   ephemeral-container update are denied.
5. Each native OpenClaw gateway rejects an unauthenticated request, then returns
   its requested nonce through AgentGateway and Amazon Bedrock.
6. Each validator key reads its own OCE namespace and agent; both cross-tenant
   reads return HTTP `403` with code `FORBIDDEN`.
7. Tenant A's `.openclaw` marker and model path survive controller-driven pod
   replacement, while a generic home marker does not.

Do not publish successful output until a fresh run has completed against the
exact OCE revision and image digests.

Keep the evidence private. It contains deployment identifiers and topology
details, but not service keys. A passing run validates only the exact
Kubernetes, OCE API, AgentGateway, Bedrock, source revision, and image digests
supplied to the command.

```text
TODO: output from the fresh run
```

## Good to know

- The central AgentGateway is shared and stateless. It stores no tenant runtime
  state, but its availability, bearer-key configuration, and Bedrock IAM role
  remain shared trust and blast-radius boundaries.
- The blueprint tests OCE authorization through the native API. It does not
  claim database-level tenant isolation.
- The adapter supports only the pinned OCE revision and expected pod shape. A
  different revision needs a new compatibility review and live validation.
- The blueprint does not enable Kubernetes NetworkPolicy. Add network controls
  with the [dedicated network-policy sample](../../isolation/network-policy/README.md).
  The pinned OCE revision's generated egress policy excludes private service
  addresses; track [OCE issue #4254](https://github.com/openclaw/openclaw-enterprise/issues/4254)
  before enforcing it with the private AgentGateway.
- The validation procedure is destructive to tenant A's runtime pod. Use
  retained validation tenants.
- The blueprint does not validate human SSO, sustained load, high
  availability, node drain, nested OpenClaw execution isolation, or a different
  OCE revision.

## Clean up

Stop every local OCE API port-forward, then run cleanup with the original
state, receipt, context, tenant namespaces, and Pod Identity values:

```bash
"$SAMPLE_DIR/scripts/cleanup.sh" \
  --kubeconfig "$KUBECONFIG" \
  --kube-context "$KUBE_CONTEXT" \
  --state-dir "$OCE_STATE_DIR" \
  --receipt "$OCE_RECEIPT_DIR" \
  --namespace "$OCE_NAMESPACE" \
  --release oce \
  --tenant-namespace '<tenant-a-kubernetes-namespace>' \
  --tenant-namespace '<tenant-b-kubernetes-namespace>' \
  --aws-region "$AWS_REGION" \
  --aws-account-id "$AWS_ACCOUNT_ID" \
  --eks-cluster-name "$EKS_CLUSTER_NAME" \
  --pod-identity-association-id "$POD_IDENTITY_ASSOCIATION_ID" \
  --iam-role-name openclaw-enterprise-agentgateway \
  --iam-inline-policy-name openclaw-enterprise-bedrock-invoke
```

Cleanup verifies the installation receipt and resource ownership before it
uninstalls the OCE release, deletes the blueprint-owned system, adapter,
AgentGateway, and supplied tenant namespaces, and deletes the verified Pod
Identity and IAM resources. Before deleting a namespace, it inventories every
descendant and stops if it finds a resource that is neither OCE-owned,
blueprint-owned, nor a narrow expected Kubernetes-generated object.

It preserves any external database. It deletes the blueprint StorageClass only
when no PVC still references it. Cleanup exits non-zero when a blueprint-owned
resource must be preserved for safety.

```text
TODO: output from the fresh run
```
