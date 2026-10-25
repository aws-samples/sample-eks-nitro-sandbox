#!/usr/bin/env bash
# Publish an image whose every layer is ciphertext, gate its layer key on attestation in
# AWS KMS, and start the approved confidential-sandbox pod under the policy the gate
# expects.
#
#   ./scripts/setup.sh              # the whole flow, ending with both pods running
#   ./scripts/setup.sh --no-pods    # everything except starting the pods
#
# Reads .env (copy it from .env.example). Writes its run files, including the decoded
# policy and the rendered manifests, to the repository's tmp/encrypted-image/.
#
# Every AWS resource it creates is tagged ManagedBy=encrypted-image, and it reuses an
# existing one only when that tag is on it. The namespace carries a matching
# app.kubernetes.io/managed-by label, which clean.sh checks before it deletes anything
# inside. The script changes nothing that is shared by the whole cluster: it checks that
# network policy enforcement is on and stops with the command when it is not.
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHARED_DIR="$(cd "$SAMPLE_DIR/../_shared" && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/encrypted-image"
# The run record goes under the repository's tmp/, with the rest of the run files, and
# never in the sample folder: it holds this account's ARNs and the key ARN.
STATE_FILE="$TMP_DIR/state.env"

MANAGED_BY="encrypted-image"

# ---------------------------------------------------------------------------- settings
if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; . "$SAMPLE_DIR/.env"; set +a; fi

CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
NAMESPACE="${NAMESPACE:-encrypted-image-sample}"
ECR_REPOSITORY="${ECR_REPOSITORY:-encrypted-image-sample}"
KMS_ALIAS="${KMS_ALIAS:-alias/encrypted-image-sample}"
IAM_ROLE_NAME="${IAM_ROLE_NAME:-encrypted-image-sample-pod}"
SOURCE_IMAGE="${SOURCE_IMAGE:-public.ecr.aws/amazonlinux/amazonlinux:minimal}"
SERVICE_ACCOUNT="encrypted-image-pod"
POD_NAME="encrypted-image-demo"
PLAIN_POD_NAME="encrypted-image-plain"
CREDENTIALS_POD_NAME="encrypted-image-credentials"

# The two build-machine tools the Amazon EKS User Guide names, in "Encrypted container
# images" and "Cedar policies". Override either when your copy is named differently.
GENPOLICY="${GENPOLICY:-eks-nitro-sandbox-genpolicy}"
KEYPROVIDER="${KEYPROVIDER:-nitro-sandbox-keyprovider}"
# skopeo runs in a container so it needs no install on the build machine.
CONTAINER_CLI="${CONTAINER_CLI:-docker}"
SKOPEO_IMAGE="${SKOPEO_IMAGE:-quay.io/skopeo/stable:v1.20.0}"

PROFILE="$SHARED_DIR/confidential-profile.yaml"
KEY_POLICY_TEMPLATE="$SHARED_DIR/kms-key-policy.json"
TRUST_POLICY_TEMPLATE="$SHARED_DIR/pod-identity/role-trust-policy.json"

no_pods=false
for arg in "$@"; do
  case "$arg" in
    --no-pods) no_pods=true ;;
    --help|-h) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# ----------------------------------------------------------------------------- helpers
die() { echo "ERROR: $*" >&2; exit 1; }

kc() {
  if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi
}

# A lookup that cannot run is "could not determine", which is a failure, never "absent".
# So absence is proved by the service's own not-found exception and nothing else; any
# other error stops the script before it can create a duplicate of something that is
# already there.
#   lookup <not-found-exception> <aws args...>
#     prints stdout and returns 0 when the resource is there
#     returns 1 only when the named exception came back
lookup() {
  local notfound="$1"; shift
  local out err rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/ei-out.XXXXXX")" || die "mktemp failed"
  err="$(mktemp "${TMPDIR:-/tmp}/ei-err.XXXXXX")" || die "mktemp failed"
  aws "$@" >"$out" 2>"$err" || rc=$?
  if [[ "$rc" == 0 ]]; then
    cat "$out"; rm -f "$out" "$err"; return 0
  fi
  if grep -Fq "$notfound" "$err"; then
    rm -f "$out" "$err"; return 1
  fi
  echo "ERROR: 'aws $*' failed (exit $rc) and not with $notfound, so it is unknown whether the resource exists; created nothing:" >&2
  sed 's/^/  /' "$err" >&2
  rm -f "$out" "$err"
  exit 1
}

# Confirms a resource this script is about to reuse carries the sample's ownership tag.
# A resource with the tag counts as the sample's whichever run created it; one without
# belongs to something else and is never touched.
require_managed_by() {  # require_managed_by <description> <actual-tag-value>
  [[ "$2" == "$MANAGED_BY" ]] ||
    die "$1 already exists and is not this sample's (ManagedBy='$2', expected '$MANAGED_BY'); created and changed nothing. Delete it, or set a new name in .env."
}

state_put() { printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"; }

# ------------------------------------------------------------------ 1/8 preflight
echo "== 1/8 check the tools, the cluster and the Region =="
[[ -n "$CLUSTER_NAME" ]] || die "CLUSTER_NAME is not set; copy .env.example to .env and fill it in"
[[ -n "$AWS_REGION" ]] || die "AWS_REGION is not set; copy .env.example to .env and fill it in"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

for c in aws jq kubectl base64 gzip curl sha256sum "$CONTAINER_CLI"; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required"
done
command -v "$GENPOLICY" >/dev/null 2>&1 ||
  die "$GENPOLICY is not on PATH. The Amazon EKS User Guide, \"Cedar policies\", names the policy generator and how to obtain it; set GENPOLICY in .env if your copy is named differently."
keyprovider_bin="$(command -v "$KEYPROVIDER" 2>/dev/null || true)"
[[ -n "$keyprovider_bin" && -x "$keyprovider_bin" ]] ||
  die "$KEYPROVIDER is not an executable on PATH. The Amazon EKS User Guide, \"Encrypted container images\", lists it as a build-machine prerequisite; set KEYPROVIDER in .env if your copy is named differently."

mkdir -p "$TMP_DIR"

account_id="$(aws sts get-caller-identity --query Account --output text)" ||
  die "could not read the AWS account; check your credentials"
registry="$account_id.dkr.ecr.$AWS_REGION.amazonaws.com"

echo "  context:  $(kc config current-context)"
kc get runtimeclass confidential-sandbox -o name >/dev/null 2>&1 ||
  die "the confidential-sandbox runtime class is not on this cluster; run the Getting started samples first"

# Network policy enforcement is a cluster-wide setting, so this script never changes it:
# the page has the reader make that change once, and this stops with the command.
np_enabled="$(kc get configmap amazon-vpc-cni -n kube-system \
  -o jsonpath='{.data.enable-network-policy-controller}' 2>/dev/null || true)"
[[ "$np_enabled" == "true" ]] || die "network policy enforcement is off on this cluster, so the sandbox's egress would not be restricted. Turn it on once, for the whole cluster, with the step on the page:
    kubectl apply -f deploy/enable-network-policy.yaml
  then re-run this script."
echo "  network policy enforcement: on"

: > "$STATE_FILE"
chmod 600 "$STATE_FILE"
state_put NAMESPACE "$NAMESPACE"
state_put AWS_REGION "$AWS_REGION"
state_put CLUSTER_NAME "$CLUSTER_NAME"

# ------------------------------------------------------- 2/8 ECR repository and KMS key
echo "== 2/8 create the ECR repository and the KMS key =="

if repo_json="$(lookup RepositoryNotFoundException ecr describe-repositories \
  --repository-names "$ECR_REPOSITORY" --query 'repositories[0]' --output json)"; then
  repo_arn="$(jq -r '.repositoryArn' <<<"$repo_json")"
  # ECR does not return tags on describe-repositories, so ownership needs this second call.
  repo_tag="$(aws ecr list-tags-for-resource --resource-arn "$repo_arn" \
    --query "tags[?Key=='ManagedBy'].Value | [0]" --output text)"
  if [[ "$repo_tag" == "None" ]]; then repo_tag=""; fi
  require_managed_by "the ECR repository $ECR_REPOSITORY" "$repo_tag"
  echo "  reusing ECR repository $ECR_REPOSITORY"
  state_put ECR_CREATED false
else
  repo_arn="$(aws ecr create-repository --repository-name "$ECR_REPOSITORY" \
    --image-tag-mutability IMMUTABLE \
    --image-scanning-configuration scanOnPush=false \
    --encryption-configuration encryptionType=AES256 \
    --tags "Key=ManagedBy,Value=$MANAGED_BY" \
    --query 'repository.repositoryArn' --output text)"
  echo "  created ECR repository $ECR_REPOSITORY"
  state_put ECR_CREATED true
fi
state_put ECR_REPOSITORY "$ECR_REPOSITORY"
state_put ECR_REPOSITORY_ARN "$repo_arn"

if key_json="$(lookup NotFoundException kms describe-key --key-id "$KMS_ALIAS" \
  --query 'KeyMetadata' --output json)"; then
  kms_key_id="$(jq -r '.KeyId' <<<"$key_json")"
  kms_key_arn="$(jq -r '.Arn' <<<"$key_json")"
  key_tag="$(aws kms list-resource-tags --key-id "$kms_key_id" \
    --query "Tags[?TagKey=='ManagedBy'].TagValue | [0]" --output text)"
  if [[ "$key_tag" == "None" ]]; then key_tag=""; fi
  require_managed_by "the KMS key behind $KMS_ALIAS" "$key_tag"
  echo "  reusing KMS key $KMS_ALIAS"
  state_put KMS_CREATED false
else
  key_json="$(aws kms create-key \
    --description "Wraps the encrypted image layer key for the EKS Nitro sandbox encrypted-image sample" \
    --key-usage ENCRYPT_DECRYPT --key-spec SYMMETRIC_DEFAULT \
    --tags "TagKey=ManagedBy,TagValue=$MANAGED_BY" \
    --query 'KeyMetadata' --output json)"
  kms_key_id="$(jq -r '.KeyId' <<<"$key_json")"
  kms_key_arn="$(jq -r '.Arn' <<<"$key_json")"
  aws kms create-alias --alias-name "$KMS_ALIAS" --target-key-id "$kms_key_id"
  echo "  created KMS key $kms_key_arn"
  state_put KMS_CREATED true
fi
state_put KMS_ALIAS "$KMS_ALIAS"
state_put KMS_KEY_ID "$kms_key_id"
state_put KMS_KEY_ARN "$kms_key_arn"

# The image tag carries the first eight characters of the key id. A run that makes a new
# key therefore publishes a new image reference, which keeps a node that prepared an
# earlier run's image from offering its layer key, wrapped under the key that run used,
# for this one. That failure arrives as a kms:Decrypt denial and reads exactly like a
# measurement mismatch, which it is not.
IMAGE_TAG="v1-${kms_key_id:0:8}"
ENCRYPTED_IMAGE_URI="$registry/$ECR_REPOSITORY:$IMAGE_TAG"
state_put IMAGE_TAG "$IMAGE_TAG"
state_put ENCRYPTED_IMAGE_URI "$ENCRYPTED_IMAGE_URI"

# -------------------------------------------- 3/8 the pod's role, born with no decrypt
echo "== 3/8 create the pod's IAM role and the born-denied key policy =="

trust_policy="$(jq --arg c "$CLUSTER_NAME" --arg n "$NAMESPACE" --arg s "$SERVICE_ACCOUNT" '
  del(._comment)
  | .Statement[0].Condition.StringEquals["aws:RequestTag/eks-cluster-name"] = $c
  | .Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-namespace"] = $n
  | .Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-service-account"] = $s
' "$TRUST_POLICY_TEMPLATE")"
printf '%s\n' "$trust_policy" > "$TMP_DIR/role-trust-policy.json"

if role_json="$(lookup NoSuchEntity iam get-role --role-name "$IAM_ROLE_NAME" \
  --query 'Role' --output json)"; then
  role_tag="$(aws iam list-role-tags --role-name "$IAM_ROLE_NAME" \
    --query "Tags[?Key=='ManagedBy'].Value | [0]" --output text)"
  if [[ "$role_tag" == "None" ]]; then role_tag=""; fi
  require_managed_by "the IAM role $IAM_ROLE_NAME" "$role_tag"
  role_arn="$(jq -r '.Arn' <<<"$role_json")"
  aws iam update-assume-role-policy --role-name "$IAM_ROLE_NAME" \
    --policy-document "file://$TMP_DIR/role-trust-policy.json"
  echo "  reusing IAM role $IAM_ROLE_NAME"
  state_put IAM_CREATED false
else
  role_arn="$(aws iam create-role --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document "file://$TMP_DIR/role-trust-policy.json" \
    --description "EKS Pod Identity role for the encrypted-image sample; no identity policies by design" \
    --tags "Key=ManagedBy,Value=$MANAGED_BY" \
    --query 'Role.Arn' --output text)"
  echo "  created IAM role $role_arn"
  state_put IAM_CREATED true
fi
state_put IAM_ROLE_NAME "$IAM_ROLE_NAME"
state_put IAM_ROLE_ARN "$role_arn"

# The role must carry no identity policy, attached or inline. One that allowed
# kms:Decrypt would grant it without the attestation condition, and the gate below would
# then decide nothing at all.
inline_count="$(aws iam list-role-policies --role-name "$IAM_ROLE_NAME" \
  --query 'length(PolicyNames)' --output text)"
attached_count="$(aws iam list-attached-role-policies --role-name "$IAM_ROLE_NAME" \
  --query 'length(AttachedPolicies)' --output text)"
[[ "$inline_count" == "0" && "$attached_count" == "0" ]] ||
  die "the role $IAM_ROLE_NAME carries identity policies ($inline_count inline, $attached_count attached). The KMS key policy is meant to be its only grant, so an identity policy could allow kms:Decrypt with no attestation condition and the gate would decide nothing. Remove them, or set a new IAM_ROLE_NAME in .env."
echo "  the role has no identity policies (0 inline, 0 attached)"

# Install the gate shape now, with an all-zero measurement no sandbox can present, and
# replace the measurement in step 7. The key is therefore never, at any moment, able to
# decrypt for anyone: there is no window with an unconditional kms:Decrypt allow on it.
put_key_policy() {  # put_key_policy <expected-pcr17>
  jq --arg account "$account_id" --arg role "$role_arn" --arg pcr17 "$1" '
    del(._comment)
    | (.Statement[] | select(.Sid == "KeyAdministration").Principal.AWS) = "arn:aws:iam::\($account):root"
    | (.Statement[] | select(.Sid == "BuildTimeEncrypt").Principal.AWS) = "arn:aws:iam::\($account):root"
    | (.Statement[] | select(.Sid == "AttestedDecryptOnly").Principal.AWS) = $role
    | (.Statement[] | select(.Sid == "AttestedDecryptOnly").Condition.StringEqualsIgnoreCase["kms:RecipientAttestation:PCR17"]) = $pcr17
    | (.Statement[] | select(.Sid == "DenyUnlessThePolicyMeasurementMatches").Condition.StringNotEqualsIgnoreCase["kms:RecipientAttestation:PCR17"]) = $pcr17
  ' "$KEY_POLICY_TEMPLATE" > "$TMP_DIR/kms-key-policy.json"
  # A key policy that names a role AWS has only just created is refused with
  # MalformedPolicyDocumentException, "one or more invalid principals", until the role is
  # visible to KMS. It is an ordinary propagation delay and it clears in a few seconds,
  # so retry on that one error and on nothing else.
  local attempt err rc
  err="$(mktemp "${TMPDIR:-/tmp}/ei-kp.XXXXXX")" || die "mktemp failed"
  for attempt in $(seq 12); do
    rc=0
    aws kms put-key-policy --key-id "$kms_key_arn" --policy-name default \
      --policy "file://$TMP_DIR/kms-key-policy.json" 2>"$err" || rc=$?
    if [[ "$rc" == 0 ]]; then rm -f "$err"; return 0; fi
    if ! grep -Fq "invalid principals" "$err"; then
      echo "ERROR: kms:PutKeyPolicy failed (exit $rc):" >&2
      sed 's/^/  /' "$err" >&2
      rm -f "$err"
      exit 1
    fi
    if [[ "$attempt" == 1 ]]; then echo "  waiting for the new IAM role to be visible to KMS..."; fi
    sleep 5
  done
  echo "ERROR: kms:PutKeyPolicy kept refusing the role as an invalid principal after 12 tries:" >&2
  sed 's/^/  /' "$err" >&2
  rm -f "$err"
  exit 1
}

# Reads the live policy back and checks the three things a denial's meaning depends on:
# that no principal has an unconditional decrypt, that the one allow is bound to this
# role and this measurement, and that both denies carry the values this run installed.
verify_key_policy() {  # verify_key_policy <expected-pcr17>
  local live
  live="$(aws kms get-key-policy --key-id "$kms_key_arn" --policy-name default \
    --query Policy --output text)"
  printf '%s\n' "$live" | jq . > "$TMP_DIR/kms-key-policy.live.json"
  jq -e --arg role "$role_arn" --arg pcr17 "$1" '
    ([.Statement[] | select(.Effect == "Allow")
      | (.Action | if type == "array" then . else [.] end)[]
      | ascii_downcase] | map(select(. == "kms:*" or . == "kms:decrypt" or . == "kms:reencryptfrom"))
      | length) as $unconditional_decrypt_actions
    | ([.Statement[] | select(.Sid == "AttestedDecryptOnly")
        | select(.Effect == "Allow")
        | select((.Principal.AWS | if type == "array" then . else [.] end) == [$role])
        | select(.Condition.StringEqualsIgnoreCase["kms:RecipientAttestation:PCR17"] == $pcr17)
        | select(.Condition.StringEqualsIgnoreCase["kms:RecipientAttestation:PCR8:ServiceName"] == "eks.amazonaws.com")
      ] | length) as $allows
    | ([.Statement[] | select(.Sid == "DenyUnlessThePolicyMeasurementMatches")
        | select(.Effect == "Deny") | select(.Principal == "*")
        | select(.Condition.StringNotEqualsIgnoreCase["kms:RecipientAttestation:PCR17"] == $pcr17)
      ] | length) as $pcr17_denies
    | ([.Statement[] | select(.Sid == "DenyUnlessTheAttestationComesFromAnEKSSandbox")
        | select(.Effect == "Deny") | select(.Principal == "*")
        | select(.Condition.StringNotEqualsIgnoreCase["kms:RecipientAttestation:PCR8:ServiceName"] == "eks.amazonaws.com")
      ] | length) as $pcr8_denies
    | $unconditional_decrypt_actions == 1
      and $allows == 1 and $pcr17_denies == 1 and $pcr8_denies == 1
  ' "$TMP_DIR/kms-key-policy.live.json" >/dev/null ||
    die "the live KMS key policy is not the gate this script installed (read back into $TMP_DIR/kms-key-policy.live.json). A denial only means the measurement was refused if the gate that produced it is the gate we believe is there."
}

# The allow-list in KeyAdministration holds exactly one of the three actions the check
# above counts, kms:Encrypt aside: none of kms:*, kms:Decrypt or kms:ReEncryptFrom. The
# count of 1 is the single conditional kms:Decrypt in AttestedDecryptOnly.
zero_pcr17="$(printf '0%.0s' $(seq 96))"
put_key_policy "$zero_pcr17"
verify_key_policy "$zero_pcr17"
echo "  the key policy allows no decrypt yet (gated on an all-zero measurement)"

# -------------------------------------- 4/8 namespace, service account and association
echo "== 4/8 create the namespace, the service account, the association and the egress policy =="

render() {  # render <manifest> <jq-filter> <out>
  kc create --dry-run=client --validate=false -o json -f "$1" | jq "$2" > "$3"
}
ns_name_filter="$(printf '.metadata.name = %s' "$(jq -n --arg v "$NAMESPACE" '$v')")"
ns_filter="$(printf '.metadata.namespace = %s' "$(jq -n --arg v "$NAMESPACE" '$v')")"

render "$SAMPLE_DIR/deploy/namespace.yaml" "$ns_name_filter" "$TMP_DIR/rendered-namespace.json"
render "$SAMPLE_DIR/deploy/service-account.yaml" "$ns_filter" "$TMP_DIR/rendered-service-account.json"

# Create the namespace only when it is absent, and reuse it only when it already carries
# this sample's label. Applying over a namespace another demo owns would put the mark on
# it, and clean.sh would then delete it.
if ns_exists="$(kc get namespace "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)" &&
   ns_label="$(kc get namespace "$NAMESPACE" --ignore-not-found \
     -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"; then
  :
else
  die "could not determine whether namespace $NAMESPACE exists (kubectl lookup failed; check the context and permissions); created nothing in the cluster"
fi
if [[ -z "$ns_exists" ]]; then
  kc apply -f "$TMP_DIR/rendered-namespace.json"
  state_put NAMESPACE_CREATED true
elif [[ "$ns_label" != "$MANAGED_BY" ]]; then
  die "namespace $NAMESPACE already exists and is not this sample's (managed-by='$ns_label'); created nothing in it. Delete it, or set a new NAMESPACE in .env."
else
  echo "  reusing namespace $NAMESPACE (carries this sample's managed-by label)"
  state_put NAMESPACE_CREATED false
fi
kc apply -f "$TMP_DIR/rendered-service-account.json"

# The association is adopted by namespace and service account, which is what identifies
# it; it has no name of its own.
assoc_id="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" \
  --query 'associations[0].associationId' --output text)"
if [[ "$assoc_id" == "None" || -z "$assoc_id" ]]; then
  assoc_id="$(aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" --role-arn "$role_arn" \
    --tags "ManagedBy=$MANAGED_BY" \
    --query 'association.associationId' --output text)"
  echo "  created Pod Identity association $assoc_id"
  state_put ASSOCIATION_CREATED true
else
  assoc_role="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --association-id "$assoc_id" --query 'association.roleArn' --output text)"
  [[ "$assoc_role" == "$role_arn" ]] ||
    die "a Pod Identity association for $NAMESPACE/$SERVICE_ACCOUNT already points at $assoc_role, not $role_arn; changed nothing"
  echo "  reusing Pod Identity association $assoc_id"
  state_put ASSOCIATION_CREATED false
fi
state_put SERVICE_ACCOUNT "$SERVICE_ACCOUNT"
state_put ASSOCIATION_ID "$assoc_id"

# The egress policy goes on now, well before any pod, and not in the same breath as the
# pods at the end. Two reasons, both observed on a live cluster:
#   * the sandbox asks AWS KMS for the layer key while it is starting, so the restriction
#     has to be in force before the pod is, not alongside it;
#   * a pod created in the moments after a new policy appears in its namespace can come up
#     with a datapath that does not match the policy, and stay that way. A pod the policy
#     does not select was left with no egress at all for as long as it lived, and a pod it
#     does select reached a host the policy denies. Everything between here and step 8
#     takes minutes, which is time the policy agent uses to settle.
coredns_ip="$(kc get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}')"
[[ -n "$coredns_ip" ]] || die "could not read the CoreDNS Service address"
sed -e "s|<COREDNS_IP>|$coredns_ip|g" -e "s|<AWS_REGION>|$AWS_REGION|g" \
  "$SAMPLE_DIR/deploy/egress-policy.yaml" > "$TMP_DIR/egress-policy.yaml"
kc apply -n "$NAMESPACE" -f "$TMP_DIR/egress-policy.yaml"
# The PolicyEndpoint is how the controller says it has handed the policy to the nodes.
endpoints=0
for _ in $(seq 60); do
  endpoints="$(kc get policyendpoints -n "$NAMESPACE" -o name 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$endpoints" != "0" ]]; then break; fi
  sleep 2
done
[[ "$endpoints" != "0" ]] || die "no PolicyEndpoint appeared for the egress policy in $NAMESPACE; the policy is not in force on the nodes"
echo "  egress policy applied and handed to the nodes ($endpoints PolicyEndpoint)"

# -------------------------------------------------------- 5/8 encrypt and publish
echo "== 5/8 encrypt every layer and push to ECR =="

image_exists=false
if manifest_json="$(lookup ImageNotFoundException ecr batch-get-image \
  --repository-name "$ECR_REPOSITORY" --image-ids "imageTag=$IMAGE_TAG" \
  --accepted-media-types application/vnd.oci.image.manifest.v1+json \
                         application/vnd.docker.distribution.manifest.v2+json \
  --query 'images[0].imageManifest' --output text)"; then
  if [[ -n "$manifest_json" && "$manifest_json" != "None" ]]; then image_exists=true; fi
fi

if [[ "$image_exists" == true ]]; then
  echo "  reusing the published image $ENCRYPTED_IMAGE_URI"
else
  work="$(mktemp -d "${TMPDIR:-/tmp}/ei-build.XXXXXX")" || die "mktemp -d failed"
  skopeo_container=""
  cleanup_build() {
    [[ -n "$skopeo_container" ]] && "$CONTAINER_CLI" rm -f "$skopeo_container" >/dev/null 2>&1 || true
    rm -rf "$work"
  }
  trap cleanup_build EXIT

  "$CONTAINER_CLI" info >/dev/null 2>&1 ||
    die "$CONTAINER_CLI is not running; skopeo runs in a container"

  # The keyprovider configuration the Amazon EKS User Guide, "Encrypted container
  # images", documents, pointing at the path the binary is copied to in the container.
  printf '%s\n' '{"key-providers":{"awskms":{"cmd":{"path":"/run/keyprovider","args":[]}}}}' \
    > "$work/ocicrypt.json"

  # The registry password and the AWS credentials go to files, never onto a command
  # line. The credential chain is resolved once here, because the container gets no
  # access to this machine's profiles, SSO cache or instance role.
  mkdir -p "$work/docker"
  aws ecr get-login-password |
    "$CONTAINER_CLI" --config "$work/docker" login --username AWS --password-stdin "$registry" >/dev/null
  aws configure export-credentials --format process > "$work/exported-credentials.json"
  jq -e '.AccessKeyId and .SecretAccessKey' "$work/exported-credentials.json" >/dev/null ||
    die "the AWS CLI did not export usable credentials for the build container"
  jq -r '
    "[default]",
    "aws_access_key_id = \(.AccessKeyId)",
    "aws_secret_access_key = \(.SecretAccessKey)",
    (if .SessionToken then "aws_session_token = \(.SessionToken)" else empty end)
  ' "$work/exported-credentials.json" > "$work/aws-credentials"
  chmod 600 "$work/aws-credentials"
  rm -f "$work/exported-credentials.json"

  # create, copy the binary and the three config files in, then start: the keyprovider
  # has to be inside the container before skopeo's entrypoint runs.
  #
  # --encrypt-layer is deliberately not passed: that flag selects individual layers, and
  # an image that mixes encrypted and plaintext layers is not supported. The pull fails,
  # naming the layers that are not encrypted, and the policy generator refuses such an
  # image (Amazon EKS User Guide, "Encrypted container images").
  skopeo_container="$("$CONTAINER_CLI" create -i --network host \
    -e AWS_REGION="$AWS_REGION" -e AWS_DEFAULT_REGION="$AWS_REGION" \
    -e AWS_PROFILE=default \
    -e AWS_SHARED_CREDENTIALS_FILE=/run/aws-credentials \
    -e OCICRYPT_KEYPROVIDER_CONFIG=/run/ocicrypt.json \
    "$SKOPEO_IMAGE" \
    copy --dest-authfile /run/authfile.json \
      --encryption-key "provider:awskms:$kms_key_arn" \
      "docker://$SOURCE_IMAGE" "docker://$ENCRYPTED_IMAGE_URI")"
  "$CONTAINER_CLI" cp "$keyprovider_bin" "$skopeo_container:/run/keyprovider"
  "$CONTAINER_CLI" cp "$work/ocicrypt.json" "$skopeo_container:/run/ocicrypt.json"
  "$CONTAINER_CLI" cp "$work/aws-credentials" "$skopeo_container:/run/aws-credentials"
  "$CONTAINER_CLI" cp "$work/docker/config.json" "$skopeo_container:/run/authfile.json"
  "$CONTAINER_CLI" start -a "$skopeo_container"
  "$CONTAINER_CLI" rm "$skopeo_container" >/dev/null
  skopeo_container=""
  cleanup_build
  trap - EXIT
  echo "  published $ENCRYPTED_IMAGE_URI"

  manifest_json="$(aws ecr batch-get-image --repository-name "$ECR_REPOSITORY" \
    --image-ids "imageTag=$IMAGE_TAG" \
    --accepted-media-types application/vnd.oci.image.manifest.v1+json \
                           application/vnd.docker.distribution.manifest.v2+json \
    --query 'images[0].imageManifest' --output text)"
fi

printf '%s\n' "$manifest_json" > "$TMP_DIR/image-manifest.json"

# ------------------------------------------------ 6/8 check what was actually published
echo "== 6/8 check every published layer is ciphertext wrapped with this key =="
# Each layer descriptor must carry an encrypted media type, the public options the
# ocicrypt spec writes, and a key-provider annotation that decodes to THIS key's ARN. The
# last part is what distinguishes "wrapped with the key this run gates" from "wrapped
# with some key", which is the difference between a working sample and a decrypt denial
# that reads like a permissions problem.
jq -e --arg want "$kms_key_arn" '
  (.layers | length) > 0
  and all(.layers[];
    (.mediaType | endswith("+encrypted"))
    and ((.annotations["org.opencontainers.image.enc.pubopts"] // "") | length) > 0
    and ((.annotations["org.opencontainers.image.enc.keys.provider.awskms"] // "")
          | (try (@base64d | fromjson | .key_arn) catch null) == $want))
' "$TMP_DIR/image-manifest.json" >/dev/null ||
  die "the published image's layers are not all encrypted and wrapped with $kms_key_arn (manifest in $TMP_DIR/image-manifest.json)"
layer_count="$(jq '.layers | length' "$TMP_DIR/image-manifest.json")"
echo "  all $layer_count layer(s) encrypted and wrapped with this key"

# The wrapped layer key itself, which the control pod will try to decrypt without an
# attestation. It is ciphertext that anyone who can read the registry already holds.
wrapped_layer_key="$(jq -r '
  .layers[0].annotations["org.opencontainers.image.enc.keys.provider.awskms"]
  | @base64d | fromjson | .ciphertext' "$TMP_DIR/image-manifest.json")"
[[ -n "$wrapped_layer_key" && "$wrapped_layer_key" != "null" ]] ||
  die "could not read the wrapped layer key out of the published manifest"

# ------------------------------------------------------------ 7/8 generate and gate
echo "== 7/8 generate the Cedar policy and set the gate to its measurement =="

image_filter="$(printf '
  .metadata.namespace = %s
  | .spec.containers[0].image = %s
  | .spec.containers[0].env = [
      {name: "AWS_REGION", value: %s},
      {name: "AWS_DEFAULT_REGION", value: %s}
    ]
  | .spec.containers[0].command[2] |= gsub("<AWS_REGION>"; %s)
' "$(jq -n --arg v "$NAMESPACE" '$v')" \
  "$(jq -n --arg v "$ENCRYPTED_IMAGE_URI" '$v')" \
  "$(jq -n --arg v "$AWS_REGION" '$v')" \
  "$(jq -n --arg v "$AWS_REGION" '$v')" \
  "$(jq -n --arg v "$AWS_REGION" '$v')")"
render "$SAMPLE_DIR/deploy/pod.yaml" "$image_filter" "$TMP_DIR/pod-input.json"

# The generator resolves the image, so it needs to authenticate to ECR. The password goes
# into a throwaway HOME, never onto a command line, and is unset as soon as it is written.
genpolicy_home="$TMP_DIR/genpolicy-home"
rm -rf "$genpolicy_home"
mkdir -p "$genpolicy_home/.docker"
ecr_auth="$(printf 'AWS:%s' "$(aws ecr get-login-password)" | base64 | tr -d '\r\n')"
jq -n --arg registry "$registry" --arg auth "$ecr_auth" \
  '{auths: {($registry): {auth: $auth}}}' > "$genpolicy_home/.docker/config.json"
unset ecr_auth
chmod 600 "$genpolicy_home/.docker/config.json"

HOME="$genpolicy_home" "$GENPOLICY" \
  --profile "$PROFILE" --with-pod-identity \
  --output-file-b64 "$TMP_DIR/policy.b64" \
  "$TMP_DIR/pod-input.json" | tee "$TMP_DIR/genpolicy.log"

# The generator prints the measurement it predicts for this policy, under a header line.
# Take the first 96-hex-character line after it: a SHA-384, which is what the agent
# extends into PCR17 (Amazon EKS User Guide, "Cedar policies").
predicted_pcr17="$(awk '
  /--- Predicted PCR17 ---/ { found = 1; next }
  found {
    value = tolower($0); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
    if (value ~ /^[0-9a-f]{96}$/) { print value; exit }
  }' "$TMP_DIR/genpolicy.log")"
[[ "$predicted_pcr17" =~ ^[0-9a-f]{96}$ ]] ||
  die "could not read a predicted PCR17 from the generator's output ($TMP_DIR/genpolicy.log)"
[[ "$predicted_pcr17" != "$zero_pcr17" ]] || die "the predicted PCR17 is all zeros, which is the value that means 'no sandbox can match'"
state_put PREDICTED_PCR17 "$predicted_pcr17"
echo "  predicted PCR17: $predicted_pcr17"

# Decode the envelope so the policy can be read; what travels in the annotation is
# gzipped and base64-encoded, which is not readable by eye.
base64 --decode "$TMP_DIR/policy.b64" > "$TMP_DIR/policy.raw"
if gzip -t "$TMP_DIR/policy.raw" >/dev/null 2>&1; then
  gzip -dc "$TMP_DIR/policy.raw" > "$TMP_DIR/policy.json"
else
  cp "$TMP_DIR/policy.raw" "$TMP_DIR/policy.json"
fi
jq -e '(.version | type) == "number" and (.admission_policy | type) == "string"
       and (.runtime_policy | type) == "string"' "$TMP_DIR/policy.json" >/dev/null ||
  die "the generated policy envelope has an unexpected schema"
jq -r '
  def yaml_block($key):
    .[$key] as $value
    | if ($value | endswith("\n")) then
        "\($key): |+\n" + ($value | rtrimstr("\n") | split("\n") | map("  " + .) | join("\n"))
      else
        "\($key): |-\n" + ($value | split("\n") | map("  " + .) | join("\n"))
      end;
  "version: \(.version)", yaml_block("admission_policy"), yaml_block("runtime_policy")
' "$TMP_DIR/policy.json" > "$TMP_DIR/policy.yaml"

# The image pin has to be an enforced condition under BOTH the CreateContainer and the
# PrepareImage permit, and the same digest under each. The generator also writes the
# digest into a comment, so a plain grep for it passes on a policy that does not enforce
# it; and counting clauses passes when both sit under one permit and none under the other.
pins="$(awk '
  /^[[:space:]]*action == Agent::Action::"CreateContainer"/ { permit = "create"; next }
  /^[[:space:]]*action == Agent::Action::"PrepareImage"/    { permit = "prepare"; next }
  /^[[:space:]]*permit\(/ { permit = "" }
  /^[[:space:]]*context\.image_ref == "/ {
    if (permit != "" && !(permit in seen)) {
      line = $0
      sub(/^[^"]*"/, "", line); sub(/".*$/, "", line)
      seen[permit] = line
    }
  }
  END { printf "%s %s\n", (("create" in seen) ? seen["create"] : "NONE"),
                          (("prepare" in seen) ? seen["prepare"] : "NONE") }
' <<<"$(jq -r '.admission_policy' "$TMP_DIR/policy.json")")"
create_pin="${pins%% *}"; prepare_pin="${pins##* }"
[[ "$create_pin" != "NONE" && "$create_pin" == "$prepare_pin" ]] ||
  die "the generated policy does not enforce one image digest under both the CreateContainer and PrepareImage permits (CreateContainer='$create_pin', PrepareImage='$prepare_pin'); read $TMP_DIR/policy.yaml"
echo "  image digest pinned under both permits: $create_pin"

put_key_policy "$predicted_pcr17"
verify_key_policy "$predicted_pcr17"
echo "  the gate now releases the layer key only to this measurement"
# A key policy change takes a moment to be in force everywhere. Starting the pod before
# it is would produce a decrypt denial that has nothing to do with the measurement.
sleep "${KMS_POLICY_PROPAGATION_WAIT_SECONDS:-15}"

# ------------------------------------------------------------------ 8/8 start the pods
if [[ "$no_pods" == true ]]; then
  echo
  echo "Set up, no pods started. The policy is in $TMP_DIR/policy.yaml."
  exit 0
fi

echo "== 8/8 start the pods =="
policy_b64="$(tr -d '\r\n' < "$TMP_DIR/policy.b64")"
jq --arg name "$POD_NAME" --arg policy "$policy_b64" '
  .metadata.name = $name
  | .metadata.annotations["sandbox.amazonaws.com/policy"] = $policy
' "$TMP_DIR/pod-input.json" > "$TMP_DIR/rendered-pod.json"

# Replace rather than apply over: a pod's policy annotation is immutable, so a pod left
# from an earlier run would go on enforcing the earlier policy.
kc delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
kc apply -f "$TMP_DIR/rendered-pod.json"
if ! kc wait "pod/$POD_NAME" -n "$NAMESPACE" --for=condition=Ready --timeout=15m; then
  kc get pod "$POD_NAME" -n "$NAMESPACE" -o wide 2>/dev/null || true
  kc get pod "$POD_NAME" -n "$NAMESPACE" \
    -o jsonpath='{range .status.containerStatuses[*]}{.state.waiting.message}{"\n"}{end}' 2>/dev/null || true
  die "the approved pod did not become Ready"
fi

node_name="$(kc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')"
[[ -n "$node_name" ]] || die "could not read the node the approved pod landed on"
state_put NODE_NAME "$node_name"

# Wait until the PolicyEndpoint names this pod before starting the two ordinary pods.
# Until the node's policy agent has reconciled the namespace's policy against the pods in
# it, a pod's egress is not yet what the policy says it is: a pod the policy does not
# select can find itself without egress for a minute or two, and a pod it does select can
# briefly reach a host the policy denies. The endpoint listing the pod is the signal that
# the reconciliation has happened.
pe_ready=false
for _ in $(seq 60); do
  if kc get policyendpoints -n "$NAMESPACE" \
      -o jsonpath='{range .items[*]}{range .spec.podSelectorEndpoints[*]}{.name}{"\n"}{end}{end}' 2>/dev/null \
      | grep -Fqx "$POD_NAME"; then
    pe_ready=true; break
  fi
  sleep 5
done
[[ "$pe_ready" == true ]] ||
  die "the egress policy's PolicyEndpoint never listed $POD_NAME, so the policy is not programmed for it on the node"
echo "  the egress policy is programmed for $POD_NAME on its node"

# The plain pod: the same image in its original plaintext form, in an ordinary pod on the
# same node, so the page can show what an ordinary pod reads for the same four readings.
plain_filter="$(printf '
  .metadata.namespace = %s
  | .spec.nodeName = %s
  | .spec.containers[0].image = %s
' "$(jq -n --arg v "$NAMESPACE" '$v')" \
  "$(jq -n --arg v "$node_name" '$v')" \
  "$(jq -n --arg v "$SOURCE_IMAGE" '$v')")"
render "$SAMPLE_DIR/deploy/plain-pod.yaml" "$plain_filter" "$TMP_DIR/rendered-plain-pod.json"
kc delete pod "$PLAIN_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
kc apply -f "$TMP_DIR/rendered-plain-pod.json"
kc wait "pod/$PLAIN_POD_NAME" -n "$NAMESPACE" --for=condition=Ready --timeout=5m ||
  die "the ordinary plain-image pod did not become Ready"

# The credentials pod: an ordinary pod with the same service account, and so the same IAM
# role, asking KMS to decrypt the same wrapped layer key with no attestation document.
# It is not pinned to a node: it stands for anyone holding the credentials, anywhere.
credentials_filter="$(printf '
  .metadata.namespace = %s
  | (.spec.containers[0].env[] | select(.name == "AWS_REGION").value) = %s
  | (.spec.containers[0].env[] | select(.name == "AWS_DEFAULT_REGION").value) = %s
  | (.spec.containers[0].env[] | select(.name == "KMS_KEY_ARN").value) = %s
  | (.spec.containers[0].env[] | select(.name == "WRAPPED_LAYER_KEY").value) = %s
' "$(jq -n --arg v "$NAMESPACE" '$v')" \
  "$(jq -n --arg v "$AWS_REGION" '$v')" \
  "$(jq -n --arg v "$AWS_REGION" '$v')" \
  "$(jq -n --arg v "$kms_key_arn" '$v')" \
  "$(jq -n --arg v "$wrapped_layer_key" '$v')")"
render "$SAMPLE_DIR/deploy/credentials-pod.yaml" "$credentials_filter" "$TMP_DIR/rendered-credentials-pod.json"

# This pod is started up to three times, because a pod can come up on a recycled pod IP
# whose datapath still carries the deleted pod's state and then never reach AWS at all.
# Observed on a busy cluster: this pod sat with no egress for its whole life while a pod
# created minutes later, on the same node, reached AWS KMS first time. A pod that reached
# no decision is not evidence either way about the key policy, so it is replaced rather
# than reported. Only a pod that got an answer from KMS ends the loop.
credentials_log=""
credentials_answered=false
for pod_attempt in 1 2 3; do
  kc delete pod "$CREDENTIALS_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
  kc apply -f "$TMP_DIR/rendered-credentials-pod.json"
  kc wait "pod/$CREDENTIALS_POD_NAME" -n "$NAMESPACE" --for=condition=Ready --timeout=5m ||
    die "the credentials pod did not become Ready"
  for _ in $(seq 90); do
    credentials_log="$(kc logs "$CREDENTIALS_POD_NAME" -n "$NAMESPACE" -c main 2>/dev/null || true)"
    if grep -Fq "encrypted-image-credentials-done" <<<"$credentials_log"; then break; fi
    sleep 5
  done
  if grep -Fq "encrypted-image-credentials-done" <<<"$credentials_log" &&
     grep -Eiq 'AccessDenied|not authorized|explicit deny' <<<"$credentials_log"; then
    credentials_answered=true; break
  fi
  if grep -Eq '^exit:[[:space:]]+0$' <<<"$credentials_log"; then
    credentials_answered=true; break   # a success: step below turns this into a failure
  fi
  echo "  attempt $pod_attempt of the credentials pod reached no answer from KMS; replacing it"
done
[[ "$credentials_answered" == true ]] ||
  die "the credentials pod never got an answer from AWS KMS, in three attempts, so this run does not show whether the key policy refuses a request with no attestation. Its last output:
$(sed 's/^/    /' <<<"$credentials_log")
  Check that a pod in $NAMESPACE can reach the KMS endpoint for $AWS_REGION."

# Its request must have been refused, and refused for the reason this sample is about.
# A non-zero exit alone is not enough: throttling, a network failure and an expired
# credential all produce one, so require the authorization wording that the attestation
# conditions, and only they, produce here.
grep -Eq '^exit:[[:space:]]+[1-9]' <<<"$credentials_log" ||
  die "the credentials pod's kms:Decrypt did NOT fail. The key policy's explicit deny is not refusing a request that carries no attestation document, so this run does not show attestation as the boundary. Read: kubectl -n $NAMESPACE logs $CREDENTIALS_POD_NAME -c main"
grep -Eiq 'AccessDenied|not authorized|explicit deny' <<<"$credentials_log" ||
  die "the credentials pod's kms:Decrypt failed, but not with an authorization denial, so the refusal cannot be attributed to the attestation condition. Read: kubectl -n $NAMESPACE logs $CREDENTIALS_POD_NAME -c main"
echo "  the same role, with no attestation, was refused the layer key"

echo
echo "$POD_NAME is Ready: its layers were decrypted inside the sandbox."
echo "  the sandbox pod's readings:  kubectl -n $NAMESPACE logs $POD_NAME -c main"
echo "  an ordinary pod's, same node: kubectl -n $NAMESPACE logs $PLAIN_POD_NAME -c main"
echo "  the same role, no attestation: kubectl -n $NAMESPACE logs $CREDENTIALS_POD_NAME -c main"
echo "  the generated policy:        less $TMP_DIR/policy.yaml"
echo "  the live key policy:         less $TMP_DIR/kms-key-policy.live.json"
echo "  the refused case:            ./scripts/changed-pod.sh"
echo "  tear down:                   ./scripts/clean.sh"
echo
echo "The sandbox pod prints its two network readings 60 seconds in, once its network"
echo "policy is in force on the node. Read its logs again after that."
