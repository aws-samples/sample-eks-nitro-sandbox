# Scoped validation procedure

Use this procedure to repeat the scoped checks against an existing OpenClaw
Enterprise deployment. This procedure does not cover clean-account installation
or teardown.

The commands use placeholders for cluster, namespace, Agent, endpoint,
credential, and image digest values. Sanitize substituted values and output
before sharing them.

After an adapter base-image refresh, rebuild and rescan the adapter, deploy the
new digest-qualified `ADAPTER_IMAGE`, and repeat this complete procedure.
Results from an earlier adapter digest do not validate its replacement.

## Prerequisites

- Use an EKS cluster with the `isolated-sandbox` runtime class.
- Install OCE, AgentGateway, the admission adapter, and the ownership helper by
  following the [sample README](README.md) and [build instructions](build/README.md).
- Configure two retained OCE tenants by following the
  [tenant model gateway procedure](scripts/README.md).
- Back one runtime with a clean PVC where `.openclaw/control` is absent, and
  retain one migrated PVC where that directory exists.
- Install `git`, `kubectl`, `jq`, `yq` 4, Python 3, and the AWS CLI.
- Choose one explicit kube context and pass it to every cluster command.
- Keep exact image references and credentials in your deployment environment,
  not in source control.

## Validate the source and automated tests

1. Clone the repository containing the revision under test into a new directory,
   then check out that revision in detached mode. Do not switch an existing
   working tree that may contain local changes.

   ```bash
   git clone '<repository-url>' sample-eks-nitro-sandbox-validation
   cd sample-eks-nitro-sandbox-validation
   validated_sample_commit='<full-commit-sha>'
   git switch --detach "$validated_sample_commit"
   test "$(git rev-parse HEAD)" = "$validated_sample_commit"
   ```

2. Create an isolated Python environment and install the test dependencies.

   ```bash
   python3 -m venv .venv
   . .venv/bin/activate
   python -m pip install -r examples/ai-agents/openclaw-enterprise/tests/requirements.txt
   ```

3. Run the adapter and deployment contract tests.

   ```bash
   python -m pytest \
     examples/ai-agents/openclaw-enterprise/adapter \
     examples/ai-agents/openclaw-enterprise/tests
   ```

## Set deployment placeholders

1. Set placeholders for your two retained tenants and runtime containers.

   ```bash
   export KUBE_CONTEXT='<kube-context>'
   export TENANT_A_NAMESPACE='<tenant-a-namespace>'
   export TENANT_A_POD='<tenant-a-runtime-pod>'
   export TENANT_A_CONTAINER='<tenant-a-runtime-container>'
   export TENANT_A_AGENT='<tenant-a-agent-resource>'
   export TENANT_B_NAMESPACE='<tenant-b-namespace>'
   export TENANT_B_POD='<tenant-b-runtime-pod>'
   export TENANT_B_CONTAINER='<tenant-b-runtime-container>'
   export TENANT_B_AGENT='<tenant-b-agent-resource>'
   export PINNED_RUNTIME_IMAGE='<registry>/<repository>@sha256:<digest>'
   ```

2. Confirm the context before any mutating command.

   ```bash
   kubectl config get-contexts "$KUBE_CONTEXT"
   kubectl --context "$KUBE_CONTEXT" cluster-info
   ```

3. Keep tenant credentials and OCE endpoint values in your existing
   secret-management path. The current AgentGateway manifest fixes the Amazon
   Bedrock region and model; parameterize and review those settings before
   deployment.

Do not export secrets into shell history for this procedure.

## Validate runtime isolation and security

1. Inspect each retained tenant runtime.

   ```bash
   check_runtime() {
     namespace="$1"
     pod="$2"
     container="$3"

     kubectl --context "$KUBE_CONTEXT" --namespace "$namespace" \
       get pod "$pod" -o json |
       jq -e --arg container "$container" '
         .spec.runtimeClassName == "isolated-sandbox"
         and (
           .spec.containers[]
           | select(.name == $container)
           | .securityContext.runAsNonRoot == true
           and .securityContext.runAsUser == 1000
           and .securityContext.runAsGroup == 1000
           and .securityContext.readOnlyRootFilesystem == true
           and .securityContext.allowPrivilegeEscalation == false
           and (.securityContext.capabilities.drop | index("ALL") != null)
           and .securityContext.seccompProfile.type == "RuntimeDefault"
         )
       '
   }

   check_runtime \
     "$TENANT_A_NAMESPACE" "$TENANT_A_POD" "$TENANT_A_CONTAINER"
   check_runtime \
     "$TENANT_B_NAMESPACE" "$TENANT_B_POD" "$TENANT_B_CONTAINER"
   ```

Each command must return `true`.

## Validate network and credential isolation

Run these checks from an adapted runtime pod. The runtime image includes
Node.js, so the commands do not depend on `curl`, `wget`, or a debug sidecar.

1. Confirm that the adapter replaced OCE's broad egress profile.

   ```bash
   kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_A_NAMESPACE" \
     get pod "$TENANT_A_POD" -o json |
     jq -e '
       .metadata.labels["openclaw.dev/network-profile"]
       == "nitro-central-gateway-v1"
     '
   ```

2. Confirm that public TCP 443 and the EKS Pod Identity Agent endpoint are
   denied.

   ```bash
   expect_tcp_denied() {
     name="$1"
     host="$2"
     port="$3"

     kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_A_NAMESPACE" \
       exec -i "$TENANT_A_POD" --container "$TENANT_A_CONTAINER" -- \
       node - "$name" "$host" "$port" <<'NODE'
   const net = require("node:net");
   const [name, host, port] = process.argv.slice(2);
   let finished = false;
   const socket = net.createConnection({host, port: Number(port)});
   const finish = (success, detail) => {
     if (finished) return;
     finished = true;
     socket.destroy();
     console.log(`${name}: ${detail}`);
     process.exitCode = success ? 0 : 1;
   };
   socket.setTimeout(5000);
   socket.once("connect", () => finish(false, "unexpected connection"));
   socket.once("timeout", () => finish(true, "denied"));
   socket.once("error", () => finish(true, "denied"));
   NODE
   }

   expect_tcp_denied "public HTTPS" "1.1.1.1" "443"
   expect_tcp_denied "EKS Pod Identity Agent" "169.254.170.23" "80"
   ```

   Both commands must print `denied` and exit successfully.

3. Confirm that the IMDS credential path returns no IAM role or credentials.

   ```bash
   kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_A_NAMESPACE" \
     exec -i "$TENANT_A_POD" --container "$TENANT_A_CONTAINER" -- \
     node <<'NODE'
   const controller = new AbortController();
   const timeout = setTimeout(() => controller.abort(), 5000);
   (async () => {
     try {
       const response = await fetch(
         "http://169.254.169.254/latest/meta-data/iam/security-credentials/",
         {signal: controller.signal},
       );
       const body = (await response.text()).trim();
       if (response.status === 200 && body) {
         throw new Error("IMDS returned an IAM role");
       }
       console.log(`IMDS credential path: HTTP ${response.status}, no role`);
     } finally {
       clearTimeout(timeout);
     }
   })().catch((error) => {
     console.error(`IMDS check failed: ${error.message}`);
     process.exitCode = 1;
   });
   NODE
   ```

   This check requires an HTTP response from IMDS. It does not claim that IMDS
   transport is blocked inside the Nitro guest.

4. Send an OpenAI Responses request from the runtime pod to the central
   AgentGateway Service.

   ```bash
   kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_A_NAMESPACE" \
     exec -i "$TENANT_A_POD" --container "$TENANT_A_CONTAINER" -- \
     node <<'NODE'
   const https = require("node:https");
   if (!process.env.OPENAI_API_KEY) {
     console.error("AgentGateway request failed: OPENAI_API_KEY is not set");
     process.exit(1);
   }
   const payload = JSON.stringify({
     model: "claude-haiku",
     input: "Reply with exactly OK.",
     max_output_tokens: 16,
   });
   const request = https.request({
     hostname: "agentgateway.openclaw-enterprise-agw.svc.cluster.local",
     port: 443,
     path: "/v1/responses",
     method: "POST",
     headers: {
       authorization: `Bearer ${process.env.OPENAI_API_KEY || ""}`,
       "content-type": "application/json",
       "content-length": Buffer.byteLength(payload),
     },
     timeout: 30000,
   }, (response) => {
     let body = "";
     response.setEncoding("utf8");
     response.on("data", (chunk) => { body += chunk; });
     response.on("end", () => {
       if (response.statusCode < 200 || response.statusCode >= 300) {
         console.error(`AgentGateway request failed: HTTP ${response.statusCode}`);
         process.exitCode = 1;
         return;
       }
       let result;
       try {
         result = JSON.parse(body);
       } catch {
         console.error("AgentGateway request failed: response was not JSON");
         process.exitCode = 1;
         return;
       }
       if (!result.id || !Array.isArray(result.output)) {
         console.error("AgentGateway request failed: model output was absent");
         process.exitCode = 1;
         return;
       }
       console.log(`AgentGateway request: HTTP ${response.statusCode}`);
     });
   });
   request.on("timeout", () => request.destroy(new Error("request timed out")));
   request.on("error", (error) => {
     console.error(`AgentGateway request failed: ${error.message}`);
     process.exitCode = 1;
   });
   request.end(payload);
   NODE
   ```

   The request must return HTTP `2xx`. This path uses the tenant bearer key
   already injected into the runtime and the CA installed by the adapter. The
   central AgentGateway uses its own EKS Pod Identity to invoke Amazon Bedrock;
   the runtime pod receives no AWS identity.

## Validate native turns and tenant authorization

1. Through OCE's native client or API, start a fresh gateway turn for the first
   tenant's own Agent.
2. Through the same interface, start a fresh gateway turn for the second
   tenant's own Agent.
3. Confirm that each turn completed through `openai-responses`, AgentGateway,
   and Amazon Bedrock.
4. Request the first tenant's Agent while authenticated as the second tenant.
5. Request the second tenant's Agent while authenticated as the first tenant.

The expected result is two completed same-tenant requests and HTTP `403` for
both cross-tenant requests. Use the OCE interface supported by the pinned OCE
revision. A direct request to AgentGateway does not validate OCE exact-resource
authorization and cannot replace these checks.

## Validate controller-driven admission and storage scope

1. Write one marker inside `.openclaw` and one marker in generic runtime home.

   ```bash
   kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_A_NAMESPACE" \
     exec "$TENANT_A_POD" --container "$TENANT_A_CONTAINER" -- \
     sh -eu -c '
       printf persisted > /home/node/.openclaw/validation-marker
       printf ephemeral > /home/node/validation-marker
     '
   ```

2. Resolve the Pod's ReplicaSet and gateway Deployment, then delete the Pod.
   Wait for that Deployment to create a healthy replacement.

   ```bash
   old_pod_uid="$(
     kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_A_NAMESPACE" \
       get pod "$TENANT_A_POD" -o jsonpath='{.metadata.uid}'
   )"
   gateway_name="$(
     kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_A_NAMESPACE" \
       get pod "$TENANT_A_POD" \
       -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}'
   )"
   gateway_replicaset="$(
     kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_A_NAMESPACE" \
       get pod "$TENANT_A_POD" \
       -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].name}'
   )"
   gateway_deployment="$(
     kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_A_NAMESPACE" \
       get replicaset "$gateway_replicaset" \
       -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].name}'
   )"
   test -n "$old_pod_uid"
   test -n "$gateway_name"
   test -n "$gateway_replicaset"
   test -n "$gateway_deployment"

   kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_A_NAMESPACE" \
     delete pod "$TENANT_A_POD"
   TENANT_A_POD=''
   for _ in {1..120}; do
     TENANT_A_POD="$(
       kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_A_NAMESPACE" \
         get pods -l "app.kubernetes.io/name=$gateway_name" -o json |
         jq -r --arg old_uid "$old_pod_uid" '
           [
             .items[]
             | select(.metadata.uid != $old_uid)
           ]
           | first
           | .metadata.name // empty
         '
     )"
     [[ -n "$TENANT_A_POD" ]] && break
     sleep 5
   done
   test -n "$TENANT_A_POD"
   export TENANT_A_POD
   kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_A_NAMESPACE" \
     wait --for=condition=Ready "pod/$TENANT_A_POD" --timeout=10m
   kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_A_NAMESPACE" \
     rollout status "deployment/$gateway_deployment" --timeout=10m
   ```

   This is the positive admission check. The OCE worker creates or updates the
   gateway Deployment, the Kubernetes Deployment controller creates or updates
   its ReplicaSet, and an allowed ReplicaSet-controller identity creates the
   replacement Pod. Do not use a hand-authored Pod as the positive case.

3. Confirm that the replacement Pod still belongs to the same gateway
   Deployment.

   ```bash
   replacement_replicaset="$(
     kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_A_NAMESPACE" \
       get pod "$TENANT_A_POD" \
       -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].name}'
   )"
   replacement_deployment="$(
     kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_A_NAMESPACE" \
       get replicaset "$replacement_replicaset" \
       -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].name}'
   )"
   test "$replacement_deployment" = "$gateway_deployment"
   ```

4. Check the two marker paths in the replacement pod.

   ```bash
   kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_A_NAMESPACE" \
     exec "$TENANT_A_POD" --container "$TENANT_A_CONTAINER" -- \
     sh -eu -c '
       test "$(cat /home/node/.openclaw/validation-marker)" = persisted
       test ! -e /home/node/validation-marker
     '
   ```

5. Through OCE's native client or API, start another fresh gateway turn for the
   replacement runtime.
6. Confirm that the post-replacement turn completed through
   `openai-responses`, AgentGateway, and Amazon Bedrock.

The expected result is a persisted `.openclaw` marker, no generic `/home/node`
marker, and a completed post-replacement turn. The ownership helper must skip
an absent migration-only `.openclaw/control` directory on the clean PVC and
repair it when present on the migrated PVC. Missing core runtime directories
must still fail closed.

## Validate negative admission controls

1. Attempt to create a Pod directly with trusted-looking OCE labels. Assert the
   complete expected denial message; any other failure is not a pass.

   ```bash
   expected_controller_denial='admission caller is not an allowed controller '
   expected_controller_denial+='identity for this resource'
   fixture='examples/ai-agents/openclaw-enterprise/tests/fixtures/oce-agent-pod.yaml'
   controller_error="$(
     yq eval \
       ".metadata.namespace = \"$TENANT_A_NAMESPACE\"" \
       "$fixture" |
       kubectl --context "$KUBE_CONTEXT" --namespace "$TENANT_A_NAMESPACE" \
         create --dry-run=server --filename - \
         2>&1 >/dev/null || true
   )"
   if [[ "$controller_error" != *"$expected_controller_denial"* ]]; then
     printf '%s\n' "$controller_error" >&2
     echo 'ERROR: exact controller-identity denial was not observed' >&2
     exit 1
   fi
   ```

   This proves that copying the namespace and workload labels does not let a
   tenant bypass the controller trust chain.

2. Run the automated admission contracts that assert exact denials for an
   unpinned runtime, spoofed OCE provenance, sidecars, extra init containers,
   service-account token projections, and post-mutation tampering.

   ```bash
   python -m pytest \
     examples/ai-agents/openclaw-enterprise/adapter \
     examples/ai-agents/openclaw-enterprise/tests/test_adapter_contract.py
   ```

   These tests exercise the same `build_patch`, `validate_pod`, `admit`, and
   `validate` functions packaged in the adapter image. They complement, but do
   not replace, the controller-created live replacement check.

3. Attempt to add an ephemeral debugger to one managed runtime. Assert the
   complete expected denial message.

   ```bash
   expected_debug_denial='ephemeral containers are not permitted in '
   expected_debug_denial+='OpenClaw Enterprise managed namespaces'
   debug_error="$(
     kubectl --context "$KUBE_CONTEXT" \
       --namespace "$TENANT_A_NAMESPACE" \
       debug "$TENANT_A_POD" \
       --target "$TENANT_A_CONTAINER" --image "$PINNED_RUNTIME_IMAGE" -- true \
       2>&1 >/dev/null || true
   )"
   if [[ "$debug_error" != *"$expected_debug_denial"* ]]; then
     printf '%s\n' "$debug_error" >&2
     echo 'ERROR: exact ephemeral-container denial was not observed' >&2
     exit 1
   fi
   ```

The validating webhook must reject the `pods/ephemeralcontainers` update with
the exact expected message.

## Validate image findings

1. Confirm that `adapter/Dockerfile` selects its base image with an exact
   `@sha256:<digest>` reference.
2. Build the adapter, controller, ownership-helper, and runtime images from the
   source revisions under test by following the
   [source-build procedure](build/README.md).
3. If the revision refreshes an adapter base, confirm that
   `ADAPTER_IMAGE` has a new digest and that Inspector no longer reports the
   fixable finding against that replacement digest.
4. Confirm that the build's exact-digest Inspector gate reports
   `CRITICAL=0, HIGH=0` for all four images.
5. Confirm that Inspector coverage is active and successful for each exact
   repository and digest before accepting the result.

A scan of earlier digests does not validate the images under test.

## Understand the validation scope

This procedure does not validate:

- Human SSO.
- Sustained load or high availability.
- Deliberate node drain.
- Nested OpenClaw exec isolation.
- An upstream-supported OCE contract for the private model gateway or
  VM-isolated runtime storage adaptation.

The adapter remains a sample-specific compatibility layer. Repeat the complete
procedure for every source revision and image digest that you deploy.
