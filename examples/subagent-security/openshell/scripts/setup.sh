#!/usr/bin/env bash
# setup.sh -- everything the procurement analyst needs on your cluster, with the analyst
# confined by OpenShell inside one Nitro sandbox.
#
# Usage:
#   cp .env.example .env && $EDITOR .env
#   ./scripts/setup.sh
#
# What it does, in order (the first five stages are the ones every Subagent security
# sample shares, and print their own "N/7" counter from analyst-lib.sh):
#   1. checks the tools, the kube context, the isolated-sandbox RuntimeClass, the Bedrock
#      model, the MutatingAdmissionPolicy API and the shared agent-sandbox install;
#   2. creates the namespace when it is absent, and the analyst ServiceAccount;
#   3. generates the supplier API key and a sample certificate authority;
#   4. builds and pushes the supplier API image and starts it as an ordinary pod;
#   5. creates the S3 bucket and seeds the case, the three proposals and another case's
#      object, so the keys the model has to cite name real objects;
#   6. downloads the pinned OpenShell CLI and chart and verifies both checksums;
#   7. applies this sample's namespace-scoped admission adapter;
#   8. creates the bridge's IAM role and EKS Pod Identity association;
#   9. builds and pushes the analyst image and the CA-extended supervisor image, and
#      starts the model bridge;
#  10. installs the OpenShell gateway from the pinned chart.
#
# This sample ships no network policy and does not touch the cluster-wide network policy
# setting. OpenShell's own driver creates NetworkPolicies for the pods it generates; that
# is upstream behaviour, not something this sample configures, and the page claims no
# limit from it. See examples/isolation/network-policy for restricting a sandbox's egress.
#
# It never changes a cluster-wide setting, never upgrades or reconfigures a shared
# install, and never reuses a resource that is not this sample's: it stops instead, and
# says what it found.
#
# Overridable in .env (the defaults match the page):
#   CLUSTER_NAME AWS_REGION KUBE_CONTEXT NAMESPACE BEDROCK_MODEL_ID BUCKET ROLE_NAME
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SECTION_DIR="$(cd "$SAMPLE_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SECTION_DIR/../.." && pwd)"

SAMPLE="subagent-security-openshell"
# The run record and every scratch file go under the repository's tmp/, which git
# ignores, and never in the sample folder: they hold this account's ARNs, this run's key
# material and the operator's OpenShell client certificate.
TMP_DIR="$REPO_ROOT/tmp/$SAMPLE"
STATE_FILE="$TMP_DIR/state.env"
LOCAL_DIR="$TMP_DIR/local"

for arg in "$@"; do
  case "$arg" in
    --help|-h) sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$TMP_DIR" "$LOCAL_DIR"
chmod 700 "$LOCAL_DIR"
if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; . "$SAMPLE_DIR/.env"; set +a; fi

CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
NAMESPACE="${NAMESPACE:-subagent-security-openshell}"
BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-global.anthropic.claude-sonnet-4-5-20250929-v1:0}"

# shellcheck source=../../analyst/scripts/analyst-lib.sh
. "$SECTION_DIR/analyst/scripts/analyst-lib.sh"

# ---------------------------------------------------------------------------
# This sample's own names and pins
# ---------------------------------------------------------------------------

RELEASE="openshell-analyst"
ADAPTER="$RELEASE-nitro-adapter"
RUNTIME_CLASS="isolated-sandbox"
# OpenShell's resource admission only lets a sandbox use a RuntimeClass an operator
# approved with this label.
APPROVAL_LABEL="openshell.ai/sandbox-attachable"
TEMPLATE="procurement-analyst"

jqr() { jq -r "$1" "$SAMPLE_DIR/versions.json"; }
UPSTREAM_REF="$(jqr '.upstream_ref')"
UPSTREAM_REVISION="$(jqr '.upstream_revision')"
CHART_REF="$(jqr '.chart.ref')"
CHART_VERSION="$(jqr '.chart.version')"
CHART_SHA256="$(jqr '.chart.sha256')"
CLI_ASSET="$(jqr '.cli_asset')"
CLI_SHA256="$(jqr '.cli_sha256')"
BASE_IMAGE="$(jqr '.base_image')"
GATEWAY_IMAGE="$(jqr '.images.gateway')"
SUPERVISOR_IMAGE="$(jqr '.images.supervisor')"
SANDBOX_RUNTIME_IMAGE="$(jqr '.images.sandbox_runtime')"
CLI="$LOCAL_DIR/openshell-$UPSTREAM_REF"

: > "$STATE_FILE"
state_put SAMPLE "$SAMPLE"
state_put NAMESPACE "$NAMESPACE"
state_put RELEASE "$RELEASE"
state_put ADAPTER "$ADAPTER"
state_put TEMPLATE "$TEMPLATE"
state_put CLI "$CLI"
state_put LOCAL_DIR "$LOCAL_DIR"
state_put UPSTREAM_REF "$UPSTREAM_REF"
state_put UPSTREAM_REVISION "$UPSTREAM_REVISION"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# The committed policies are what the page shows, so a stale copy would make the page
# disagree with the run.
python3 "$SAMPLE_DIR/src/policies.py" "$SAMPLE_DIR/policy" --check ||
  die "the files in policy/ are not what src/policies.py produces. Run ./scripts/policies.sh to regenerate them, then re-run this script."

command -v helm >/dev/null 2>&1 || die "helm is required"
command -v curl >/dev/null 2>&1 || die "curl is required"

analyst_preflight

# MutatingAdmissionPolicy is how this sample adapts OpenShell's generated pod to a Nitro
# sandbox. It is stable and on by default from Kubernetes 1.36; this checks the cluster
# actually serves it rather than asserting a version number.
kc api-resources --api-group=admissionregistration.k8s.io -o name 2>/dev/null |
  grep -q '^mutatingadmissionpolicies\.' ||
  die "this cluster does not serve MutatingAdmissionPolicy, which this sample needs to adapt OpenShell's workload pod. It is stable and enabled by default from Kubernetes 1.36. 'kubectl version' shows what this cluster runs."

# agent-sandbox is a shared install: OpenShell's Kubernetes driver creates a Sandbox and
# that controller creates the pod. Reuse it exactly as it is, and stop with the command
# when it is absent rather than installing it here.
kc get crd sandboxes.agents.x-k8s.io -o name >/dev/null 2>&1 ||
  die "the agent-sandbox controller is not on this cluster. Install it as the Getting started > Warm pool sample does, then re-run this script:
  kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.6/sandbox-with-extensions.yaml"
echo "  agent-sandbox: reusing the install already on this cluster"

# OpenShell will not attach a RuntimeClass an operator has not approved. The label is
# shared with any other OpenShell gateway on the cluster and changes nothing for other
# pods, so this sample never removes it, and adds it only when it is absent.
runtime_label="$(kc get runtimeclass "$RUNTIME_CLASS" \
  -o jsonpath="{.metadata.labels['openshell\.ai/sandbox-attachable']}" 2>/dev/null)" ||
  die "could not read the $RUNTIME_CLASS RuntimeClass"
if [[ "$runtime_label" == "true" ]]; then
  echo "  runtime class: $RUNTIME_CLASS already carries $APPROVAL_LABEL=true"
  state_put RUNTIME_CLASS_LABELLED false
else
  kc label runtimeclass "$RUNTIME_CLASS" "$APPROVAL_LABEL=true"
  echo "  runtime class: added $APPROVAL_LABEL=true to $RUNTIME_CLASS"
  state_put RUNTIME_CLASS_LABELLED true
fi

# Refuse a cluster-scoped adapter that is not this sample's, before anything is created.
for kind in mutatingadmissionpolicy mutatingadmissionpolicybinding; do
  owner="$(kc get "$kind" "$ADAPTER" --ignore-not-found \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)" ||
    die "could not determine whether the $kind $ADAPTER exists; created nothing"
  if [[ -n "$owner" && "$owner" != "$SAMPLE" ]]; then
    die "the $kind $ADAPTER already exists and is not this sample's (managed-by='$owner'); created nothing."
  fi
done

# ---------------------------------------------------------------------------
# The parts every Subagent security sample shares
# ---------------------------------------------------------------------------

BUCKET="${BUCKET:-subagent-analyst-$SAMPLE-$ACCOUNT_ID}"
ROLE_NAME="${ROLE_NAME:-subagent-analyst-$SAMPLE-bridge}"
SUPPLIER_API_REPOSITORY="pod-isolation/subagent-analyst-$SAMPLE-supplier-api"
ANALYST_REPOSITORY="pod-isolation/subagent-analyst-$SAMPLE"
state_put BUCKET "$BUCKET"
state_put ROLE_NAME "$ROLE_NAME"
state_put CLUSTER_NAME "$CLUSTER_NAME"
state_put AWS_REGION "$AWS_REGION"
state_put KUBE_CONTEXT "$KUBE_CONTEXT"
state_put BEDROCK_MODEL_ID "$BEDROCK_MODEL_ID"
state_put SUPPLIER_API_REPOSITORY "$SUPPLIER_API_REPOSITORY"
state_put ANALYST_REPOSITORY "$ANALYST_REPOSITORY"

analyst_namespace
analyst_supplier_secrets
analyst_supplier_api
analyst_bucket

# ---------------------------------------------------------------------------
# The pinned OpenShell CLI and chart
# ---------------------------------------------------------------------------

say "the pinned OpenShell CLI and chart ($UPSTREAM_REF)"

if [[ -x "$CLI" ]]; then
  echo "  reusing the verified CLI at $CLI"
else
  curl -fsSL -o "$LOCAL_DIR/$CLI_ASSET" \
    "https://github.com/NVIDIA/OpenShell/releases/download/$UPSTREAM_REF/$CLI_ASSET" ||
    die "could not download the OpenShell CLI $CLI_ASSET for $UPSTREAM_REF"
  echo "$CLI_SHA256  $LOCAL_DIR/$CLI_ASSET" | sha256sum -c - >/dev/null ||
    die "the OpenShell CLI archive does not match the SHA-256 in versions.json; refusing to use it. Delete $LOCAL_DIR/$CLI_ASSET and re-run, and if it fails again the pin and the published asset disagree."
  tar xzf "$LOCAL_DIR/$CLI_ASSET" -C "$LOCAL_DIR" openshell
  mv "$LOCAL_DIR/openshell" "$CLI"
  chmod 755 "$CLI"
  rm -f "$LOCAL_DIR/$CLI_ASSET"
  echo "  downloaded and verified the CLI: $("$CLI" --version)"
fi

CHART="$LOCAL_DIR/helm-chart-$CHART_VERSION.tgz"
if [[ ! -f "$CHART" ]]; then
  helm pull "$CHART_REF" --version "$CHART_VERSION" --destination "$LOCAL_DIR" >/dev/null ||
    die "could not pull the OpenShell chart $CHART_VERSION"
fi
echo "$CHART_SHA256  $CHART" | sha256sum -c - >/dev/null || {
  rm -f "$CHART"
  die "the OpenShell chart does not match the SHA-256 in versions.json; refusing to install it."
}
echo "  verified chart $CHART_VERSION against its pinned checksum"

# ---------------------------------------------------------------------------
# The namespace-scoped admission adapter
# ---------------------------------------------------------------------------

say "the admission adapter that adapts OpenShell's pod to a Nitro sandbox"

analyst_render "$SAMPLE_DIR/deploy/nitro-adapter.yaml" "$TMP_DIR/nitro-adapter.yaml" \
  "s|<ADAPTER_NAME>|$ADAPTER|g"
# Applied before the gateway exists, so no sandbox pod can be created without it.
kc apply -f "$TMP_DIR/nitro-adapter.yaml"
state_put ADAPTER_CREATED true
echo "  applied $ADAPTER, scoped to namespaces labelled managed-by=$SAMPLE"

# ---------------------------------------------------------------------------
# The bridge's IAM role and Pod Identity association
# ---------------------------------------------------------------------------

say "the model bridge's IAM role and its EKS Pod Identity association"

# The bridge is the only component with AWS credentials, and Bedrock on one inference
# profile is all it needs: no S3, no other service. The analyst in the sandbox has no
# role at all.
jq -n --arg ns "$NAMESPACE" --arg sa "$ANALYST_SA" '{
  Version: "2012-10-17",
  Statement: [{
    Effect: "Allow",
    Principal: {Service: "pods.eks.amazonaws.com"},
    Action: ["sts:AssumeRole", "sts:TagSession"],
    Condition: {StringEquals: {
      "aws:RequestTag/kubernetes-namespace": $ns,
      "aws:RequestTag/kubernetes-service-account": $sa}}}]}' \
  > "$TMP_DIR/bridge-trust-policy.json"
jq -n --argjson models "$MODEL_RESOURCES" '{
  Version: "2012-10-17",
  Statement: [{
    Sid: "InvokeTheConfiguredModel",
    Effect: "Allow",
    Action: ["bedrock:InvokeModel"],
    Resource: $models}]}' > "$TMP_DIR/bridge-permissions-policy.json"

rc=0
existing_role="$(lookup NoSuchEntity iam get-role --role-name "$ROLE_NAME" --output json)" || rc=$?
stop_if_undetermined "$rc" "the IAM role $ROLE_NAME"
if [[ "$rc" == 0 ]]; then
  require_managed_by "the IAM role $ROLE_NAME" \
    "$(jq -r '.Role.Tags[]? | select(.Key=="ManagedBy") | .Value' <<<"$existing_role")"
  # The tag says the role is this sample's; it does not say it still carries only what
  # this sample grants. Putting the bridge policy back would not remove a second one, and
  # the page would then show a model-scoped role that in fact holds more.
  inline="$(aws iam list-role-policies --role-name "$ROLE_NAME" --output json)" ||
    die "could not list the inline policies on the IAM role $ROLE_NAME, so it is unknown whether it carries only this sample's; changed nothing."
  attached="$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --output json)" ||
    die "could not list the attached policies on the IAM role $ROLE_NAME, so it is unknown whether it carries only this sample's; changed nothing."
  extra="$(jq -r '.PolicyNames[] | select(. != "bridge")' <<<"$inline" | tr '\n' ' ')"
  [[ -z "$extra" ]] ||
    die "the IAM role $ROLE_NAME carries inline policies this sample did not create ($extra); changed nothing. Delete the role, or set a new ROLE_NAME in .env."
  [[ "$(jq '.AttachedPolicies | length' <<<"$attached")" == 0 ]] ||
    die "the IAM role $ROLE_NAME has managed policies attached ($(jq -r '[.AttachedPolicies[].PolicyName] | join(", ")' <<<"$attached")); changed nothing. Delete the role, or set a new ROLE_NAME in .env."
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
    --policy-document "file://$TMP_DIR/bridge-trust-policy.json"
  ROLE_ARN="$(jq -r '.Role.Arn' <<<"$existing_role")"
  echo "  reusing the IAM role $ROLE_NAME (it carries only this sample's bridge policy)"
else
  ROLE_ARN="$(aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TMP_DIR/bridge-trust-policy.json" \
    --tags "Key=ManagedBy,Value=$SAMPLE" --query Role.Arn --output text)" ||
    die "could not create the IAM role $ROLE_NAME"
  state_put ROLE_CREATED true
  echo "  created the IAM role $ROLE_NAME"
fi
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name bridge \
  --policy-document "file://$TMP_DIR/bridge-permissions-policy.json"
state_put ROLE_ARN "$ROLE_ARN"

assoc="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" --service-account "$ANALYST_SA" --output json)" ||
  die "could not list the Pod Identity associations for $NAMESPACE/$ANALYST_SA on $CLUSTER_NAME"
if [[ "$(jq '.associations | length' <<<"$assoc")" != 0 ]]; then
  id="$(jq -r '.associations[0].associationId' <<<"$assoc")"
  assoc_role="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --association-id "$id" --query association.roleArn --output text)" ||
    die "could not read the existing Pod Identity association $id"
  [[ "$assoc_role" == "$ROLE_ARN" ]] ||
    die "the Pod Identity association for $NAMESPACE/$ANALYST_SA points at $assoc_role, not $ROLE_ARN; changed nothing. Remove it, or set a new NAMESPACE in .env."
  echo "  reusing the Pod Identity association $id"
else
  id="$(aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" --service-account "$ANALYST_SA" --role-arn "$ROLE_ARN" \
    --tags "ManagedBy=$SAMPLE" --query association.associationId --output text)" ||
    die "could not create the Pod Identity association"
  state_put POD_IDENTITY_ASSOCIATION "$id"
  echo "  created the Pod Identity association $id"
fi

# ---------------------------------------------------------------------------
# The analyst image, the supervisor image and the model bridge
# ---------------------------------------------------------------------------

say "the analyst image, the CA-extended supervisor image and the model bridge"

analyst_image "$ANALYST_REPOSITORY" openshell/Dockerfile \
  openshell/src/analyst_probes.py openshell/src/bridge.py openshell/src/policies.py \
  analyst/requirements.txt analyst/src/business.py analyst/src/worker.py \
  analyst/src/analyst_agent.py analyst/fixtures/case.json analyst/fixtures/availability.json \
  analyst/fixtures/proposals/northstar.json analyst/fixtures/proposals/harbor.json \
  analyst/fixtures/proposals/cedar.json
ANALYST_POD_IMAGE="$ANALYST_IMAGE"
state_put ANALYST_IMAGE "$ANALYST_POD_IMAGE"

# The bridge's own certificate authority and server certificate. It cannot share the
# supplier API's: that certificate names the two supplier Services in its subjectAltName,
# and a certificate presented for a name it does not carry is a TLS failure, which must
# never be able to read as a policy refusal on this page.
BRIDGE_HOST="analyst-bridge.$NAMESPACE.svc.cluster.local"
bridge_dir="$TMP_DIR/bridge"
mkdir -p "$bridge_dir"; chmod 700 "$bridge_dir"
if kc get secret bridge-tls -n "$NAMESPACE" -o name >/dev/null 2>&1 &&
   kc get configmap bridge-ca -n "$NAMESPACE" -o name >/dev/null 2>&1; then
  kc get configmap bridge-ca -n "$NAMESPACE" -o jsonpath='{.data.ca\.crt}' \
    > "$bridge_dir/ca.crt"
  echo "  reusing the bridge-tls Secret and the bridge-ca ConfigMap"
else
  # keyUsage on the authority is not optional: OpenSSL's strict X.509 checks reject a CA
  # certificate without keyCertSign, and the supervisor would then fail with a
  # certificate error that a reader could mistake for a policy refusal.
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -subj "/CN=subagent-security-openshell-bridge-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    -keyout "$bridge_dir/ca.key" -out "$bridge_dir/ca.crt" 2>/dev/null
  openssl req -new -newkey rsa:2048 -nodes -subj "/CN=analyst-bridge" \
    -keyout "$bridge_dir/tls.key" -out "$bridge_dir/bridge.csr" 2>/dev/null
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\nsubjectAltName=DNS:%s\n' \
    "$BRIDGE_HOST" > "$bridge_dir/bridge.ext"
  openssl x509 -req -in "$bridge_dir/bridge.csr" -CA "$bridge_dir/ca.crt" \
    -CAkey "$bridge_dir/ca.key" -CAcreateserial -days 30 \
    -extfile "$bridge_dir/bridge.ext" -out "$bridge_dir/tls.crt" 2>/dev/null
  chmod 600 "$bridge_dir"/*.key
  kc create secret tls bridge-tls -n "$NAMESPACE" \
    --cert="$bridge_dir/tls.crt" --key="$bridge_dir/tls.key"
  kc create configmap bridge-ca -n "$NAMESPACE" --from-file=ca.crt="$bridge_dir/ca.crt"
  echo "  created a 30-day certificate authority and the bridge-tls Secret"
fi

# The supervisor verifies TLS against the certificates in its own image, so it needs both
# sample authorities: the shared one that signed the supplier API's certificate, and the
# bridge's. Turning verification off instead would remove a control the sample keeps.
supervisor_dir="$TMP_DIR/supervisor"
mkdir -p "$supervisor_dir"
cp "$SAMPLE_DIR/supervisor/Dockerfile" "$supervisor_dir/Dockerfile"
kc get configmap supplier-ca -n "$NAMESPACE" -o jsonpath='{.data.ca\.crt}' \
  > "$supervisor_dir/ca.crt" ||
  die "could not read the shared supplier-ca ConfigMap, which the supervisor has to trust"
cat "$bridge_dir/ca.crt" >> "$supervisor_dir/ca.crt"
grep -q 'BEGIN CERTIFICATE' "$supervisor_dir/ca.crt" ||
  die "the supervisor trust bundle this run assembled holds no certificate"
! grep -q 'PRIVATE KEY' "$supervisor_dir/ca.crt" ||
  die "the supervisor trust bundle this run assembled holds a private key; refusing to build it into an image"

supervisor_tag="supervisor-$(cat "$SAMPLE_DIR/supervisor/Dockerfile" "$supervisor_dir/ca.crt" \
  "$SAMPLE_DIR/versions.json" | sha256sum | cut -c1-20)"
registry="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
SUPERVISOR_POD_IMAGE="$registry/$ANALYST_REPOSITORY:$supervisor_tag"
if aws ecr describe-images --repository-name "$ANALYST_REPOSITORY" \
    --image-ids "imageTag=$supervisor_tag" >/dev/null 2>&1; then
  echo "  reusing $supervisor_tag (its inputs have not changed)"
else
  docker_config="$(mktemp -d "${TMPDIR:-/tmp}/openshell-docker.XXXXXX")"
  aws ecr get-login-password --region "$AWS_REGION" |
    docker --config "$docker_config" login --username AWS --password-stdin "$registry" \
      >/dev/null || die "could not sign in to $registry"
  docker build --platform linux/amd64 \
    --build-arg "SUPERVISOR_IMAGE=$SUPERVISOR_IMAGE" \
    --build-arg "BASE_IMAGE=$BASE_IMAGE" \
    -t "$SUPERVISOR_POD_IMAGE" "$supervisor_dir" ||
    die "could not build the CA-extended supervisor image"
  docker --config "$docker_config" push "$SUPERVISOR_POD_IMAGE" >/dev/null ||
    die "could not push $SUPERVISOR_POD_IMAGE"
  rm -rf "$docker_config"
  echo "  built and pushed $supervisor_tag"
fi
# Run it by digest, so a retagged repository cannot change what runs.
supervisor_digest="$(aws ecr describe-images --repository-name "$ANALYST_REPOSITORY" \
  --image-ids "imageTag=$supervisor_tag" --query 'imageDetails[0].imageDigest' --output text)" ||
  die "could not read the digest of the supervisor image this run pushed"
SUPERVISOR_POD_IMAGE="$registry/$ANALYST_REPOSITORY@$supervisor_digest"
state_put SUPERVISOR_IMAGE "$SUPERVISOR_POD_IMAGE"

analyst_render "$SAMPLE_DIR/deploy/bridge.yaml" "$TMP_DIR/bridge.yaml" \
  "s|<ANALYST_IMAGE>|$ANALYST_POD_IMAGE|g" \
  "s|<AWS_REGION>|$AWS_REGION|g" \
  "s|<BEDROCK_MODEL_ID>|$BEDROCK_MODEL_ID|g"
kc apply -f "$TMP_DIR/bridge.yaml"
kc rollout status deployment/analyst-bridge -n "$NAMESPACE" --timeout=5m ||
  die "the model bridge did not become ready; 'kubectl describe deployment/analyst-bridge -n $NAMESPACE' says why"

# ---------------------------------------------------------------------------
# The OpenShell gateway
# ---------------------------------------------------------------------------

say "the OpenShell gateway"

if ! kc get secret "$RELEASE-kek" -n "$NAMESPACE" -o name >/dev/null 2>&1; then
  # The gateway encrypts stored provider credentials under this key. It is generated
  # here and read from a file, never passed on a command line.
  openssl rand 32 | base64 | tr -d '\n' > "$LOCAL_DIR/kek"
  chmod 600 "$LOCAL_DIR/kek"
  kc create secret generic "$RELEASE-kek" -n "$NAMESPACE" \
    --from-file=key-encryption-key="$LOCAL_DIR/kek"
  rm -f "$LOCAL_DIR/kek"
  echo "  created the gateway's key-encryption-key Secret"
fi

analyst_render "$SAMPLE_DIR/deploy/gateway-values.yaml" "$TMP_DIR/gateway-values.yaml" \
  "s|<RELEASE>|$RELEASE|g"
# The pinned digests go in here rather than in the committed values file, so the file the
# page shows carries no registry paths and one place (versions.json) holds every pin.
python3 - "$TMP_DIR/gateway-values.yaml" "$GATEWAY_IMAGE" "$SANDBOX_RUNTIME_IMAGE" \
    "$SUPERVISOR_POD_IMAGE" <<'PY'
import sys
import yaml

path, gateway, sandbox_runtime, supervisor = sys.argv[1:5]
values = yaml.safe_load(open(path))
values["gateway"] = {"image": {"digest": gateway.split("@", 1)[1]}}
values["sandboxRuntime"] = {"image": {"digest": sandbox_runtime.split("@", 1)[1]}}
repository, digest = supervisor.split("@", 1)
registry, repository = repository.split("/", 1)
values["supervisor"] = {"image": {"registry": registry, "repository": repository,
                                  "digest": digest}}
yaml.safe_dump(values, open(path, "w"))
PY

# Render and check the chart before it is installed. The rule this sample has to keep is
# that nothing it creates is reachable from outside the cluster, and the chart is the one
# thing here whose objects this sample did not write.
# agentSandbox.preflight.enabled=false is for this render only. The chart's preflight
# template asks the cluster which agent-sandbox API versions are served, which `helm
# template` cannot answer offline, so it would fail the render rather than the check. The
# install below does not pass it, so the real preflight still runs against the cluster,
# and the preflight above already refused when the CRD was absent.
helm template "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$TMP_DIR/gateway-values.yaml" \
  --set agentSandbox.preflight.enabled=false \
  > "$TMP_DIR/gateway-rendered.yaml" ||
  die "could not render the OpenShell chart with this sample's values"
python3 - "$TMP_DIR/gateway-rendered.yaml" <<'PY'
import sys
import yaml

public = {"Ingress", "Gateway", "GRPCRoute", "HTTPRoute", "Route"}
findings = []
for obj in yaml.safe_load_all(open(sys.argv[1])):
    if not obj:
        continue
    kind = obj.get("kind")
    if kind in public:
        findings.append(f"the chart rendered a {kind}, which would be reachable from outside the cluster")
    if kind == "Service" and obj.get("spec", {}).get("type", "ClusterIP") != "ClusterIP":
        findings.append(f"the chart rendered a {obj['spec']['type']} Service, {obj['metadata']['name']}")
if findings:
    for finding in findings:
        print("ERROR: " + finding, file=sys.stderr)
    sys.exit(1)
print("  rendered chart: all Services are ClusterIP, and no Ingress, Gateway or Route")
PY

helm upgrade --install "$RELEASE" "$CHART" \
  ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"} \
  -n "$NAMESPACE" -f "$TMP_DIR/gateway-values.yaml" --wait --timeout 10m ||
  die "the OpenShell gateway did not become ready; 'kubectl get pods -n $NAMESPACE' and 'helm status $RELEASE -n $NAMESPACE' say why"
state_put GATEWAY_INSTALLED true

say "ready"
cat <<EOF
  namespace:   $NAMESPACE
  gateway:     $RELEASE (OpenShell $UPSTREAM_REF)
  bucket:      $BUCKET
  bridge role: $ROLE_NAME
  model:       $BEDROCK_MODEL_ID
  run record:  $STATE_FILE

Run one procurement case:
  ./scripts/run.sh
EOF
