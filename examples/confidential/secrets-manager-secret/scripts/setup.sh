#!/usr/bin/env bash
# Store a secret as ciphertext in AWS Secrets Manager, gate its KMS key on attestation, and
# run the approved confidential-sandbox pod that decrypts it inside the guest.
#
#   ./scripts/setup.sh              # the whole flow, ending with the three pods finished
#   ./scripts/setup.sh --no-pods    # everything except starting the pods
#
# Reads .env (copy it from .env.example). Writes its run files, including the decoded Cedar
# policy, the rendered manifests and the live key policy, to the repository's
# tmp/secrets-manager-secret/run/. Nothing it writes goes anywhere else, and clean.sh
# removes that one directory, so your own captured output can sit beside it.
#
# Every AWS resource it creates is tagged ManagedBy=secrets-manager-secret, and it reuses an
# existing one only when that tag is on it. The namespace carries a matching
# app.kubernetes.io/managed-by label, which clean.sh checks before it deletes anything
# inside. The script changes nothing that is shared by the whole cluster.
#
# It applies no network policy. Restricting a sandbox's egress is the subject of its own
# sample, examples/isolation/network-policy, and this one is about the attestation gate on
# the key.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHARED_DIR="$(cd "$SAMPLE_DIR/../_shared" && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
# Everything these scripts write goes under run/, and clean.sh removes exactly that
# directory. The folder above it is where you put your own files: the output you captured
# with tee, a review brief, a copy of a state file. A clean up that removed the whole folder
# would take those with it, which it did once, during this sample's own first run.
TMP_DIR="$REPO_ROOT/tmp/secrets-manager-secret/run"
# The run record goes under the repository's tmp/, with the rest of the run files, and never
# in the sample folder: it holds this account's ARNs, the key ARN and the secret's name.
STATE_FILE="$TMP_DIR/state.env"

MANAGED_BY="secrets-manager-secret"

# ---------------------------------------------------------------------------- settings
if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; . "$SAMPLE_DIR/.env"; set +a; fi

CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
NAMESPACE="${NAMESPACE:-secrets-manager-secret-sample}"
ECR_REPOSITORY="${ECR_REPOSITORY:-secrets-manager-secret-sample}"
KMS_ALIAS="${KMS_ALIAS:-alias/secrets-manager-secret-sample}"
IAM_ROLE_NAME="${IAM_ROLE_NAME:-secrets-manager-secret-sample-pod}"
SECRET_NAME="${SECRET_NAME:-secrets-manager-secret-sample}"
SERVICE_ACCOUNT="secrets-manager-secret-pod"
POD_NAME="secrets-manager-secret-demo"
PLAIN_POD_NAME="secrets-manager-secret-plain"
CREDENTIALS_POD_NAME="secrets-manager-secret-credentials"

# The Cedar policy generator the Amazon EKS User Guide, "Cedar policies", names. Override
# it when your copy is named differently.
GENPOLICY="${GENPOLICY:-eks-nitro-sandbox-genpolicy}"
CONTAINER_CLI="${CONTAINER_CLI:-docker}"

PROFILE="$SHARED_DIR/confidential-profile.yaml"
KEY_POLICY_TEMPLATE="$SHARED_DIR/kms-key-policy.json"
TRUST_POLICY_TEMPLATE="$SHARED_DIR/pod-identity/role-trust-policy.json"
SECRET_POLICY_TEMPLATE="$SAMPLE_DIR/deploy/secret-resource-policy.json"

no_pods=false
for arg in "$@"; do
  case "$arg" in
    --no-pods) no_pods=true ;;
    --help|-h) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

. "$SCRIPT_DIR/lib.sh"
state_put() { printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"; }

# ------------------------------------------------------------------ 1/8 preflight
echo "== 1/8 check the tools, the cluster and the Region =="
[[ -n "$CLUSTER_NAME" ]] || die "CLUSTER_NAME is not set; copy .env.example to .env and fill it in"
[[ -n "$AWS_REGION" ]] || die "AWS_REGION is not set; copy .env.example to .env and fill it in"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

for c in aws jq kubectl base64 sha256sum "$CONTAINER_CLI"; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required"
done
command -v "$GENPOLICY" >/dev/null 2>&1 ||
  die "$GENPOLICY is not on PATH. The Amazon EKS User Guide, \"Cedar policies\", names the policy generator and how to obtain it; set GENPOLICY in .env if your copy is named differently."

mkdir -p "$TMP_DIR"

account_id="$(aws sts get-caller-identity --query Account --output text)" ||
  die "could not read the AWS account; check your credentials"
registry="$account_id.dkr.ecr.$AWS_REGION.amazonaws.com"

echo "  context:  $(kc config current-context)"
kc get runtimeclass confidential-sandbox -o name >/dev/null 2>&1 ||
  die "the confidential-sandbox runtime class is not on this cluster; run the Getting started samples first"

: > "$STATE_FILE"
chmod 600 "$STATE_FILE"
state_put NAMESPACE "$NAMESPACE"
state_put AWS_REGION "$AWS_REGION"
state_put CLUSTER_NAME "$CLUSTER_NAME"

# ------------------------------------------------- 2/8 ECR repository and KMS key
echo "== 2/8 create the ECR repository and the KMS key =="

repo_json=""; repo_rc=0
repo_json="$(lookup RepositoryNotFoundException ecr describe-repositories \
  --repository-names "$ECR_REPOSITORY" --query 'repositories[0]' --output json)" || repo_rc=$?
stop_if_undetermined "$repo_rc" "the ECR repository $ECR_REPOSITORY"
if [[ "$repo_rc" == 0 ]]; then
  repo_arn="$(jq -r '.repositoryArn' <<<"$repo_json")"
  # ECR does not return tags on describe-repositories, so ownership needs this second call.
  repo_tag="$(tag_or_empty "$(aws ecr list-tags-for-resource --resource-arn "$repo_arn" \
    --query "tags[?Key=='ManagedBy'].Value | [0]" --output text)")"
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

# The measurement no sandbox can present. The key is gated on it from the moment it exists,
# and step 7 replaces it with the measurement the generator predicts.
zero_pcr17="$(printf '0%.0s' $(seq 96))"

key_json=""; key_rc=0
key_json="$(lookup NotFoundException kms describe-key --key-id "$KMS_ALIAS" \
  --query 'KeyMetadata' --output json)" || key_rc=$?
stop_if_undetermined "$key_rc" "the KMS key behind $KMS_ALIAS"
if [[ "$key_rc" == 0 ]]; then
  KMS_KEY_ID="$(jq -r '.KeyId' <<<"$key_json")"
  KMS_KEY_ARN="$(jq -r '.Arn' <<<"$key_json")"
  key_tag="$(tag_or_empty "$(aws kms list-resource-tags --key-id "$KMS_KEY_ID" \
    --query "Tags[?TagKey=='ManagedBy'].TagValue | [0]" --output text)")"
  require_managed_by "the KMS key behind $KMS_ALIAS" "$key_tag"
  echo "  reusing KMS key $KMS_ALIAS"
  state_put KMS_CREATED false
else
  # The key is created WITH a policy, never with the default one. kms:CreateKey with no
  # --policy attaches the default key policy, whose "Enable IAM policies" statement allows
  # kms:* to the account root, and that is an unconditional kms:Decrypt: the key would spend
  # the time between here and the gate in step 3 able to decrypt for any sufficiently
  # privileged identity in the account.
  #
  # This birth policy is the gate's template with the one conditional allow removed, so it
  # names no role and does not have to wait for one to exist. Key administration and
  # build-time encrypt are there, and so are both denies, carrying the all-zero measurement.
  # So the key denies every decrypt from the moment it exists, and step 3 adds the allow
  # once the role is there.
  jq --arg account "$account_id" --arg pcr17 "$zero_pcr17" '
    del(._comment)
    | (.Statement[] | select(.Sid == "KeyAdministration").Principal.AWS) = "arn:aws:iam::\($account):root"
    | (.Statement[] | select(.Sid == "BuildTimeEncrypt").Principal.AWS) = "arn:aws:iam::\($account):root"
    | (.Statement[] | select(.Sid == "DenyUnlessThePolicyMeasurementMatches").Condition.StringNotEqualsIgnoreCase["kms:RecipientAttestation:PCR17"]) = $pcr17
    | .Statement |= map(select(.Sid != "AttestedDecryptOnly"))
  ' "$KEY_POLICY_TEMPLATE" > "$TMP_DIR/kms-key-policy.birth.json"
  # The same glob test gate.jq applies to the allow side, so the two checks in this sample
  # cannot disagree about what can reach the secret. A grant cannot beat the two denies, but
  # it has no business in a document whose whole job is to allow nothing that can reach it.
  jq -e --from-file "$SCRIPT_DIR/birth-policy.jq" \
    "$TMP_DIR/kms-key-policy.birth.json" >/dev/null ||
    die "the birth key policy would allow something that can reach a decrypt; refusing to create the key"
  key_json="$(aws kms create-key \
    --description "Wraps the Secrets Manager secret value for the EKS Nitro sandbox secrets-manager-secret sample" \
    --key-usage ENCRYPT_DECRYPT --key-spec SYMMETRIC_DEFAULT \
    --policy "file://$TMP_DIR/kms-key-policy.birth.json" \
    --tags "TagKey=ManagedBy,TagValue=$MANAGED_BY" \
    --query 'KeyMetadata' --output json)"
  KMS_KEY_ID="$(jq -r '.KeyId' <<<"$key_json")"
  KMS_KEY_ARN="$(jq -r '.Arn' <<<"$key_json")"
  aws kms create-alias --alias-name "$KMS_ALIAS" --target-key-id "$KMS_KEY_ID"
  echo "  created KMS key $KMS_KEY_ARN"
  echo "  it denies every decrypt already: created with a policy, not the default one"
  state_put KMS_CREATED true
fi
state_put KMS_ALIAS "$KMS_ALIAS"
state_put KMS_KEY_ID "$KMS_KEY_ID"
state_put KMS_KEY_ARN "$KMS_KEY_ARN"

# -------------------------------------- 3/8 the pod's role, born with no decrypt
echo "== 3/8 create the pod's IAM role and the born-denied key policy =="

jq --arg c "$CLUSTER_NAME" --arg n "$NAMESPACE" --arg s "$SERVICE_ACCOUNT" '
  del(._comment)
  | .Statement[0].Condition.StringEquals["aws:RequestTag/eks-cluster-name"] = $c
  | .Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-namespace"] = $n
  | .Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-service-account"] = $s
' "$TRUST_POLICY_TEMPLATE" > "$TMP_DIR/role-trust-policy.json"

role_json=""; role_rc=0
role_json="$(lookup NoSuchEntity iam get-role --role-name "$IAM_ROLE_NAME" \
  --query 'Role' --output json)" || role_rc=$?
stop_if_undetermined "$role_rc" "the IAM role $IAM_ROLE_NAME"
if [[ "$role_rc" == 0 ]]; then
  role_tag="$(tag_or_empty "$(aws iam list-role-tags --role-name "$IAM_ROLE_NAME" \
    --query "Tags[?Key=='ManagedBy'].Value | [0]" --output text)")"
  require_managed_by "the IAM role $IAM_ROLE_NAME" "$role_tag"
  IAM_ROLE_ARN="$(jq -r '.Arn' <<<"$role_json")"
  aws iam update-assume-role-policy --role-name "$IAM_ROLE_NAME" \
    --policy-document "file://$TMP_DIR/role-trust-policy.json"
  echo "  reusing IAM role $IAM_ROLE_NAME"
  state_put IAM_CREATED false
else
  IAM_ROLE_ARN="$(aws iam create-role --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document "file://$TMP_DIR/role-trust-policy.json" \
    --description "EKS Pod Identity role for the secrets-manager-secret sample; no identity policies by design" \
    --tags "Key=ManagedBy,Value=$MANAGED_BY" \
    --query 'Role.Arn' --output text)"
  echo "  created IAM role $IAM_ROLE_ARN"
  state_put IAM_CREATED true
fi
# The role's unique id, as well as its ARN. A key policy naming a role that has only just
# been created, or recreated under a name that existed before, can come back from KMS with
# this id in place of the ARN: both name the same principal, and the id names only this
# role, never a later one of the same name. gate.jq accepts either form.
IAM_ROLE_ID="$(aws iam get-role --role-name "$IAM_ROLE_NAME" --query 'Role.RoleId' --output text)"
[[ -n "$IAM_ROLE_ID" && "$IAM_ROLE_ID" != "None" ]] ||
  die "could not read the unique id of the role $IAM_ROLE_NAME"
state_put IAM_ROLE_NAME "$IAM_ROLE_NAME"
state_put IAM_ROLE_ARN "$IAM_ROLE_ARN"
state_put IAM_ROLE_ID "$IAM_ROLE_ID"

# The role must carry no identity policy, attached or inline. One that allowed kms:Decrypt
# would grant it without the attestation condition, and the gate below would then decide
# nothing at all.
inline_count="$(aws iam list-role-policies --role-name "$IAM_ROLE_NAME" \
  --query 'length(PolicyNames)' --output text)"
attached_count="$(aws iam list-attached-role-policies --role-name "$IAM_ROLE_NAME" \
  --query 'length(AttachedPolicies)' --output text)"
[[ "$inline_count" == "0" && "$attached_count" == "0" ]] ||
  die "the role $IAM_ROLE_NAME carries identity policies ($inline_count inline, $attached_count attached). The KMS key policy and the secret's resource policy are meant to be its only grants, so an identity policy could allow kms:Decrypt with no attestation condition and the gate would decide nothing. Remove them, or set a new IAM_ROLE_NAME in .env."
echo "  the role has no identity policies (0 inline, 0 attached)"

# Install the gate shape now, with the all-zero measurement, and replace the measurement in
# step 7. The key is therefore never, at any moment, able to decrypt for anyone.
put_key_policy() {  # put_key_policy <expected-pcr17>
  jq --arg account "$account_id" --arg role "$IAM_ROLE_ARN" --arg pcr17 "$1" '
    del(._comment)
    | (.Statement[] | select(.Sid == "KeyAdministration").Principal.AWS) = "arn:aws:iam::\($account):root"
    | (.Statement[] | select(.Sid == "BuildTimeEncrypt").Principal.AWS) = "arn:aws:iam::\($account):root"
    | (.Statement[] | select(.Sid == "AttestedDecryptOnly").Principal.AWS) = $role
    | (.Statement[] | select(.Sid == "AttestedDecryptOnly").Condition.StringEqualsIgnoreCase["kms:RecipientAttestation:PCR17"]) = $pcr17
    | (.Statement[] | select(.Sid == "DenyUnlessThePolicyMeasurementMatches").Condition.StringNotEqualsIgnoreCase["kms:RecipientAttestation:PCR17"]) = $pcr17
  ' "$KEY_POLICY_TEMPLATE" > "$TMP_DIR/kms-key-policy.json"
  # A key policy that names a role AWS has only just created is refused with
  # MalformedPolicyDocumentException, "one or more invalid principals", until the role is
  # visible to KMS. It is an ordinary propagation delay and it clears in a few seconds, so
  # retry on that one error and on nothing else.
  local attempt err rc
  err="$(mktemp "${TMPDIR:-/tmp}/sms-kp.XXXXXX")" || die "mktemp failed"
  for attempt in $(seq 12); do
    rc=0
    aws kms put-key-policy --key-id "$KMS_KEY_ARN" --policy-name default \
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

# A put that lands while the role is still propagating is stored with the role's unique id
# in place of its ARN. The gate is the same either way, but the ARN is the readable form, so
# put it again a few times to let it settle on the ARN. This never loops on a wrong gate: it
# only ever re-sends the same document, and it gives up quietly, leaving gate.jq to accept
# the id form.
settle_key_policy_principal() {
  local attempt stored
  for attempt in $(seq 6); do
    stored="$(aws kms get-key-policy --key-id "$KMS_KEY_ARN" --policy-name default \
      --query Policy --output text \
      | jq -r '[.Statement[] | select(.Sid == "AttestedDecryptOnly")
                | (.Principal.AWS | if type == "array" then .[] else . end)] | join(",")')"
    [[ "$stored" != "$IAM_ROLE_ARN" ]] || return 0
    # No AttestedDecryptOnly at all is not something waiting will fix; leave it to
    # verify_key_policy, which has the error message for it.
    [[ -n "$stored" ]] || return 0
    sleep 5
    aws kms put-key-policy --key-id "$KMS_KEY_ARN" --policy-name default \
      --policy "file://$TMP_DIR/kms-key-policy.json" >/dev/null 2>&1 || true
  done
  return 0
}

put_key_policy "$zero_pcr17"
settle_key_policy_principal
verify_key_policy "$zero_pcr17"
echo "  the key policy allows no decrypt yet (gated on an all-zero measurement)"

# ------------------------------------ 4/8 namespace, service account, association
echo "== 4/8 create the namespace, the service account and the association =="

render() {  # render <manifest> <jq-filter> <out>
  kc create --dry-run=client --validate=false -o json -f "$1" | jq "$2" > "$3"
}
json_string() { jq -n --arg v "$1" '$v'; }

render "$SAMPLE_DIR/deploy/namespace.yaml" \
  ".metadata.name = $(json_string "$NAMESPACE")" "$TMP_DIR/rendered-namespace.json"
render "$SAMPLE_DIR/deploy/service-account.yaml" \
  ".metadata.namespace = $(json_string "$NAMESPACE")" "$TMP_DIR/rendered-service-account.json"

# Create the namespace only when it is absent, and reuse it only when it already carries
# this sample's label. Applying over a namespace another demo owns would put the mark on it,
# and clean.sh would then delete it.
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

# The association is adopted by namespace and service account, which is what identifies it;
# it has no name of its own.
assoc_id="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" \
  --query 'associations[0].associationId' --output text)"
if [[ "$assoc_id" == "None" || -z "$assoc_id" ]]; then
  assoc_id="$(aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" --role-arn "$IAM_ROLE_ARN" \
    --tags "ManagedBy=$MANAGED_BY" \
    --query 'association.associationId' --output text)"
  echo "  created Pod Identity association $assoc_id"
  state_put ASSOCIATION_CREATED true
else
  assoc_json="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --association-id "$assoc_id" --query 'association' --output json)"
  # The same ownership test the other AWS resources get, and the one clean.sh applies before
  # it will delete this association.
  require_managed_by "the Pod Identity association for $NAMESPACE/$SERVICE_ACCOUNT" \
    "$(jq -r '.tags.ManagedBy // ""' <<<"$assoc_json")"
  assoc_role="$(jq -r '.roleArn' <<<"$assoc_json")"
  [[ "$assoc_role" == "$IAM_ROLE_ARN" ]] ||
    die "a Pod Identity association for $NAMESPACE/$SERVICE_ACCOUNT already points at $assoc_role, not $IAM_ROLE_ARN; changed nothing"
  echo "  reusing Pod Identity association $assoc_id"
  state_put ASSOCIATION_CREATED false
fi
state_put SERVICE_ACCOUNT "$SERVICE_ACCOUNT"
state_put ASSOCIATION_ID "$assoc_id"


# ------------------------------------------------- 5/8 build and push the application
echo "== 5/8 build the application image and push it to ECR =="

# The tag is derived from the build inputs, so a run that changes the application publishes
# a new reference and a run that does not reuses the one that is there. The Cedar policy
# pins the image digest, and the key is gated on that policy's measurement, so "the approved
# image" has to mean one exact set of bytes.
image_tag="v1-$(cat "$SAMPLE_DIR/Dockerfile" "$SAMPLE_DIR/src/requirements.txt" \
  "$SAMPLE_DIR/src/app.py" "$SAMPLE_DIR/src/readings.py" "$SAMPLE_DIR/src/no_attestation.py" \
  "$SHARED_DIR/attested_recipient.py" | sha256sum | cut -c1-12)"
APP_IMAGE_URI="$registry/$ECR_REPOSITORY:$image_tag"
state_put IMAGE_TAG "$image_tag"
state_put APP_IMAGE_URI "$APP_IMAGE_URI"

image_rc=0
manifest_json="$(lookup ImageNotFoundException ecr batch-get-image \
  --repository-name "$ECR_REPOSITORY" --image-ids "imageTag=$image_tag" \
  --accepted-media-types application/vnd.oci.image.manifest.v1+json \
                         application/vnd.docker.distribution.manifest.v2+json \
  --query 'images[0].imageManifest' --output text)" || image_rc=$?
stop_if_undetermined "$image_rc" "the published image $APP_IMAGE_URI"

if [[ "$image_rc" == 0 && -n "$manifest_json" && "$manifest_json" != "None" ]]; then
  echo "  reusing the published image $APP_IMAGE_URI"
else
  "$CONTAINER_CLI" info >/dev/null 2>&1 || die "$CONTAINER_CLI is not running"
  # The registry password reaches the client on standard input, never on a command line.
  aws ecr get-login-password |
    "$CONTAINER_CLI" login --username AWS --password-stdin "$registry" >/dev/null
  # The build context is the Confidential section folder, because the image needs the
  # shared attested-recipient helper as well as this sample's own src/.
  "$CONTAINER_CLI" build -f "$SAMPLE_DIR/Dockerfile" -t "$APP_IMAGE_URI" "$SHARED_DIR/.."
  "$CONTAINER_CLI" push "$APP_IMAGE_URI"
  echo "  published $APP_IMAGE_URI"
fi

pushed_digest="$(aws ecr describe-images --repository-name "$ECR_REPOSITORY" \
  --image-ids "imageTag=$image_tag" --query 'imageDetails[0].imageDigest' --output text)"
[[ "$pushed_digest" == sha256:* ]] ||
  die "could not read the digest of the published image $APP_IMAGE_URI"
state_put APP_IMAGE_DIGEST "$pushed_digest"

# ---------------------------------------------- 6/8 encrypt the value and store it
echo "== 6/8 encrypt the secret value and store the ciphertext in Secrets Manager =="

work="$(mktemp -d "${TMPDIR:-/tmp}/sms-secret.XXXXXX")" || die "mktemp -d failed"
chmod 700 "$work"
cleanup_work() { rm -rf "$work"; }
trap cleanup_work EXIT

# A random 64-character token, written straight to a file. printf is a shell builtin, so
# the value never becomes a process argument and never appears in /proc or in a history
# file; everything that reads it afterwards reads the file.
secret_value="$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-64)"
printf '%s' "$secret_value" > "$work/plaintext"
unset secret_value
chmod 600 "$work/plaintext"
EXPECTED_LENGTH="$(wc -c < "$work/plaintext" | tr -d ' ')"
EXPECTED_SHA256="$(sha256sum "$work/plaintext" | cut -d' ' -f1)"
[[ "$EXPECTED_LENGTH" == 64 ]] ||
  die "the generated secret value is $EXPECTED_LENGTH bytes, not 64; refusing to go on with a value this run does not understand"
state_put EXPECTED_LENGTH "$EXPECTED_LENGTH"
state_put EXPECTED_SHA256 "$EXPECTED_SHA256"

# KMS encrypts a value this small directly, so there is no separate data key to manage
# (AWS KMS API Reference, Encrypt). The plaintext goes in as a file, not as an argument.
ciphertext_b64="$(aws kms encrypt --key-id "$KMS_KEY_ARN" \
  --plaintext "fileb://$work/plaintext" --query CiphertextBlob --output text)"
[[ -n "$ciphertext_b64" ]] || die "kms:Encrypt returned no ciphertext"
jq -n --arg k "$KMS_KEY_ARN" --arg c "$ciphertext_b64" \
  '{version: 1, key_arn: $k, ciphertext: $c}' > "$work/envelope.json"

secret_rc=0
secret_json="$(lookup ResourceNotFoundException secretsmanager describe-secret \
  --secret-id "$SECRET_NAME" --output json)" || secret_rc=$?
stop_if_undetermined "$secret_rc" "the secret $SECRET_NAME"
if [[ "$secret_rc" == 0 ]]; then
  SECRET_ARN="$(jq -r '.ARN' <<<"$secret_json")"
  require_managed_by "the secret $SECRET_NAME" \
    "$(jq -r '[.Tags[]? | select(.Key == "ManagedBy") | .Value][0] // ""' <<<"$secret_json")"
  # A secret awaiting deletion still answers describe-secret, but every write to it is
  # refused. Say so, rather than failing later with the service's own wording.
  [[ "$(jq -r '.DeletedDate // ""' <<<"$secret_json")" == "" ]] ||
    die "the secret $SECRET_NAME is scheduled for deletion, so its value cannot be replaced. Restore it with 'aws secretsmanager restore-secret --secret-id $SECRET_NAME', or set a new SECRET_NAME in .env."
  # Reusing the secret means replacing its value, because this run made a new plaintext and
  # may have made a new key. A stored envelope from an earlier run would be ciphertext under
  # a key this run does not gate, and the denial would read like a measurement mismatch.
  aws secretsmanager put-secret-value --secret-id "$SECRET_ARN" \
    --secret-string "file://$work/envelope.json" >/dev/null
  echo "  reusing secret $SECRET_NAME with a new ciphertext envelope"
  state_put SECRET_CREATED false
else
  SECRET_ARN="$(aws secretsmanager create-secret --name "$SECRET_NAME" \
    --description "Ciphertext envelope for the EKS Nitro sandbox secrets-manager-secret sample" \
    --secret-string "file://$work/envelope.json" \
    --tags "Key=ManagedBy,Value=$MANAGED_BY" \
    --query 'ARN' --output text)"
  echo "  created secret $SECRET_NAME"
  state_put SECRET_CREATED true
fi
state_put SECRET_NAME "$SECRET_NAME"
state_put SECRET_ARN "$SECRET_ARN"

# The resource policy is the role's only grant on the secret: GetSecretValue and nothing
# else. It grants nothing on AWS KMS, so it cannot be a second path to the secret's value.
jq --arg role "$IAM_ROLE_ARN" '
  del(._comment)
  | (.Statement[] | select(.Sid == "AllowThePodRoleToReadTheCiphertext").Principal.AWS) = $role
' "$SECRET_POLICY_TEMPLATE" > "$TMP_DIR/secret-resource-policy.json"
aws secretsmanager put-resource-policy --secret-id "$SECRET_ARN" \
  --resource-policy "file://$TMP_DIR/secret-resource-policy.json" >/dev/null

# Read the resource policy back and check it is the one above: one allow, to this role, for
# GetSecretValue only, and nothing on KMS. A policy that had also granted PutSecretValue
# would let the workload replace the ciphertext with one wrapped under a key it chose.
aws secretsmanager get-resource-policy --secret-id "$SECRET_ARN" \
  --query ResourcePolicy --output text | jq . > "$TMP_DIR/secret-resource-policy.live.json"
jq -e --arg role "$IAM_ROLE_ARN" '
  def actions: (.Action | if type == "array" then . else [.] end);
  (.Statement | length) == 1
  and (.Statement[0]
       | .Effect == "Allow"
         and ((.Principal.AWS | if type == "array" then . else [.] end) | . == [$role])
         and (actions | map(ascii_downcase) | . == ["secretsmanager:getsecretvalue"]))
  and ([.Statement[] | actions[] | select(ascii_downcase | startswith("kms:"))] | length) == 0
' "$TMP_DIR/secret-resource-policy.live.json" >/dev/null ||
  die "the live resource policy on $SECRET_NAME is not the one this sample installs (read back into $TMP_DIR/secret-resource-policy.live.json)"
echo "  the secret's resource policy grants this role secretsmanager:GetSecretValue and nothing else"

# What is stored has to be ciphertext, and it has to be ciphertext of THIS run's value under
# THIS run's key. Read it back from the service rather than trusting what was sent.
aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
  --query SecretString --output text > "$work/stored.json"
jq -e --arg k "$KMS_KEY_ARN" '.version == 1 and .key_arn == $k and (.ciphertext | length) > 0' \
  "$work/stored.json" >/dev/null ||
  die "the stored secret is not a version 1 ciphertext envelope for $KMS_KEY_ARN"
jq -r '.ciphertext' "$work/stored.json" | base64 --decode > "$work/stored-ciphertext.bin"
stored_bytes="$(wc -c < "$work/stored-ciphertext.bin" | tr -d ' ')"
stored_sha="$(sha256sum "$work/stored-ciphertext.bin" | cut -d' ' -f1)"
[[ "$stored_sha" != "$EXPECTED_SHA256" ]] ||
  die "the stored value hashes to the plaintext's digest, so what was stored is the secret itself"
# And the plaintext does not appear anywhere in what is stored, in either form. The value is
# a single line of printable characters, which is what makes this a reliable search.
if grep -F -q -f "$work/plaintext" "$work/stored.json" ||
   grep -F -a -q -f "$work/plaintext" "$work/stored-ciphertext.bin"; then
  die "the plaintext secret appears in the stored value; refusing to go on"
fi
echo "  stored $stored_bytes bytes of ciphertext (sha256 $stored_sha)"
echo "  the plaintext ($EXPECTED_LENGTH bytes, sha256 $EXPECTED_SHA256) does not appear in it"
# The plaintext file stays in this run's private temp directory until step 8 has read every
# pod's logs back and checked the value is not in them. The trap above removes the whole
# directory when the script exits, however it exits.

# ------------------------------------------------------ 7/8 generate and set the gate
echo "== 7/8 generate the Cedar policy and set the gate to its measurement =="

pod_filter="$(printf '
  .metadata.namespace = %s
  | .spec.containers[0].image = %s
  | (.spec.containers[0].env[] | select(.name == "AWS_REGION").value) = %s
  | (.spec.containers[0].env[] | select(.name == "AWS_DEFAULT_REGION").value) = %s
  | (.spec.containers[0].env[] | select(.name == "SECRET_ID").value) = %s
  | (.spec.containers[0].env[] | select(.name == "KMS_KEY_ARN").value) = %s
  | (.spec.containers[0].env[] | select(.name == "EXPECTED_LENGTH").value) = %s
  | (.spec.containers[0].env[] | select(.name == "EXPECTED_SHA256").value) = %s
' "$(json_string "$NAMESPACE")" \
  "$(json_string "$APP_IMAGE_URI")" \
  "$(json_string "$AWS_REGION")" \
  "$(json_string "$AWS_REGION")" \
  "$(json_string "$SECRET_ARN")" \
  "$(json_string "$KMS_KEY_ARN")" \
  "$(json_string "$EXPECTED_LENGTH")" \
  "$(json_string "$EXPECTED_SHA256")")"
render "$SAMPLE_DIR/deploy/pod.yaml" "$pod_filter" "$TMP_DIR/pod-input.json"

# The generator resolves the image, so it needs to authenticate to ECR. The password goes
# into a throwaway HOME, never onto a command line, and is unset as soon as it is written.
genpolicy_home="$TMP_DIR/genpolicy-home"
rm -rf "$genpolicy_home"
mkdir -p "$genpolicy_home/.docker"
# The token is checked before it is encoded. Inside a pipeline a failed command substitution
# does not stop the script, so without this the pipeline would happily encode "AWS:" and
# write a well-formed config holding no password: the generator would then fail later with an
# opaque authentication error.
ecr_token="$(aws ecr get-login-password)" ||
  die "could not get an ECR authorization token for the policy generator"
[[ -n "$ecr_token" ]] || die "the ECR authorization token came back empty"
# It reaches jq on standard input, never in its argv: a command line is readable from /proc
# by any local user, and this is a live credential for the registry. The umask is set in the
# subshell that does the writing, so the file is never briefly world-readable.
( umask 077
  printf 'AWS:%s' "$ecr_token" | base64 | tr -d '\r\n' \
    | jq -Rn --arg registry "$registry" '{auths: {($registry): {auth: input}}}' \
    > "$genpolicy_home/.docker/config.json" )
unset ecr_token
jq -e --arg registry "$registry" --arg prefix "QVdTOg" '
  .auths[$registry].auth
  | type == "string" and length > 0
    # "QVdTOg" is base64 for "AWS:", so a token-less "AWS:" encodes to exactly that and
    # nothing more. Anything longer carries a password.
    and . != "QVdTOg==" and (length > ($prefix | length) + 2)
' "$genpolicy_home/.docker/config.json" >/dev/null ||
  die "could not write the registry credentials the policy generator needs"

HOME="$genpolicy_home" "$GENPOLICY" \
  --profile "$PROFILE" --with-pod-identity \
  --output-file-b64 "$TMP_DIR/policy.b64" \
  "$TMP_DIR/pod-input.json" | tee "$TMP_DIR/genpolicy.log"

predicted_pcr17="$(read_predicted_pcr17 "$TMP_DIR/genpolicy.log")"
# Written-out hex class, not [0-9a-f]: a bracket range is matched against the locale's
# collating order, and this value is what the KMS key gets gated on.
[[ "$predicted_pcr17" =~ ^[0123456789abcdef]{96}$ ]] ||
  die "could not read a predicted PCR17 from the generator's output ($TMP_DIR/genpolicy.log)"
[[ "$predicted_pcr17" != "$zero_pcr17" ]] ||
  die "the predicted PCR17 is all zeros, which is the value that means 'no sandbox can match'"
state_put PREDICTED_PCR17 "$predicted_pcr17"
echo "  predicted PCR17: $predicted_pcr17"

# Decode the envelope so the policy can be read; what travels in the annotation is gzipped
# and base64-encoded, which is not readable by eye (Amazon EKS User Guide, "Cedar policies").
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

# The image pin has to be an enforced condition under the CreateContainer permit, and it has
# to name the image this run pushed. The generator also writes the digest into a comment, so
# a plain grep for it passes on a policy that does not enforce it; each rule's head sets
# `rule`, and a clause is only recorded inside a permit, because a forbid rule carrying the
# same image_ref clause pins nothing.
create_pin="$(awk '
  /^[[:space:]]*permit\(/ { rule = "permit"; which = ""; next }
  /^[[:space:]]*forbid\(/ { rule = "forbid"; which = ""; next }
  /^[[:space:]]*action == Agent::Action::"CreateContainer"/ { which = "create"; next }
  /^[[:space:]]*context\.image_ref == "/ {
    if (rule == "permit" && which == "create" && !seen) {
      line = $0
      sub(/^[^"]*"/, "", line); sub(/".*$/, "", line)
      print line; seen = 1
    }
  }' <<<"$(jq -r '.admission_policy' "$TMP_DIR/policy.json")")"
[[ "$create_pin" == "$registry/$ECR_REPOSITORY@$pushed_digest" ]] ||
  die "the generated policy pins '$create_pin' under its CreateContainer permit, which is not the image this run published ($registry/$ECR_REPOSITORY@$pushed_digest); read $TMP_DIR/policy.yaml"
echo "  image digest pinned under the CreateContainer permit: $create_pin"

put_key_policy "$predicted_pcr17"
settle_key_policy_principal
verify_key_policy "$predicted_pcr17"
echo "  the gate now releases the secret only to this measurement"
# A key policy change takes a moment to be in force everywhere. Starting the pod before it
# is would produce a decrypt denial that has nothing to do with the measurement.
sleep "${KMS_POLICY_PROPAGATION_WAIT_SECONDS:-15}"

# ------------------------------------------------------------------ 8/8 the pods
if [[ "$no_pods" == true ]]; then
  echo
  echo "Set up, no pods started. The policy is in $TMP_DIR/policy.yaml."
  exit 0
fi

echo "== 8/8 run the pods =="
policy_b64="$(tr -d '\r\n' < "$TMP_DIR/policy.b64")"
jq --arg name "$POD_NAME" --arg policy "$policy_b64" '
  .metadata.name = $name
  | .metadata.annotations["sandbox.amazonaws.com/policy"] = $policy
' "$TMP_DIR/pod-input.json" > "$TMP_DIR/rendered-pod.json"

# Replace rather than apply over: a pod's policy annotation is immutable, so a pod left from
# an earlier run would go on enforcing the earlier policy.
kc delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
kc apply -f "$TMP_DIR/rendered-pod.json"

# The node, as soon as the pod is scheduled. The ordinary comparison pod is pinned to it, and
# starting it now rather than after the sandboxed pod finishes means both readings are taken
# on the same machine at the same time.
node_name=""
for _ in $(seq 180); do
  node_name="$(kc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  if [[ -n "$node_name" ]]; then break; fi
  sleep 5
done
[[ -n "$node_name" ]] || die "the approved pod was not scheduled to a node within 15 minutes"
state_put NODE_NAME "$node_name"
echo "  the approved pod is on $node_name"

render "$SAMPLE_DIR/deploy/plain-pod.yaml" "$(printf '
  .metadata.namespace = %s
  | .spec.nodeName = %s
  | .spec.containers[0].image = %s
' "$(json_string "$NAMESPACE")" "$(json_string "$node_name")" "$(json_string "$APP_IMAGE_URI")")" \
  "$TMP_DIR/rendered-plain-pod.json"
kc delete pod "$PLAIN_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
kc apply -f "$TMP_DIR/rendered-plain-pod.json"

# Prints the phase a pod settled in, or nothing if it had not settled within the budget.
# All three pods run once and exit, so Succeeded or Failed is the answer, not Ready.
wait_for_finish() {  # wait_for_finish <pod> <tries>
  local phase
  for _ in $(seq "$2"); do
    phase="$(kc get pod "$1" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$phase" == Succeeded || "$phase" == Failed ]]; then printf '%s' "$phase"; return 0; fi
    sleep 5
  done
  return 0
}
wait_for_phase() {  # wait_for_phase <pod> <phase> <tries>
  [[ "$(wait_for_finish "$1" "$3")" == "$2" ]]
}

if ! wait_for_phase "$POD_NAME" Succeeded 180; then
  kc get pod "$POD_NAME" -n "$NAMESPACE" -o wide 2>/dev/null || true
  kc logs "$POD_NAME" -n "$NAMESPACE" -c main 2>/dev/null | redact || true
  kc get pod "$POD_NAME" -n "$NAMESPACE" \
    -o jsonpath='{range .status.containerStatuses[*]}{.state.waiting.message}{.state.terminated.message}{"\n"}{end}' 2>/dev/null | redact || true
  die "the approved pod did not end Succeeded"
fi
kc logs "$POD_NAME" -n "$NAMESPACE" -c main > "$TMP_DIR/approved-pod.log"

# The marker has to be there, and it has to carry this run's own digest. A marker alone
# would also be printed by a pod that had validated some other value.
grep -Fqx "attested-secret-ok bytes=$EXPECTED_LENGTH sha256=$EXPECTED_SHA256" \
  "$TMP_DIR/approved-pod.log" ||
  die "the approved pod ended Succeeded but did not print the validation marker for this run's value. Read: kubectl -n $NAMESPACE logs $POD_NAME -c main"
echo "  the approved pod decrypted the secret in the guest and validated it"

if ! wait_for_phase "$PLAIN_POD_NAME" Succeeded 60; then
  die "the ordinary comparison pod did not end Succeeded"
fi
kc logs "$PLAIN_POD_NAME" -n "$NAMESPACE" -c main > "$TMP_DIR/plain-pod.log"
echo "  the ordinary pod on the same node printed its own readings"

# The no-attestation control. It is started up to three times, because a pod can come up on
# a recycled pod IP whose datapath still carries the deleted pod's state and then never reach
# AWS at all. A pod that reached no decision is not evidence either way about the key policy,
# so it is replaced rather than reported.
render "$SAMPLE_DIR/deploy/credentials-pod.yaml" "$(printf '
  .metadata.namespace = %s
  | .spec.containers[0].image = %s
  | (.spec.containers[0].env[] | select(.name == "AWS_REGION").value) = %s
  | (.spec.containers[0].env[] | select(.name == "AWS_DEFAULT_REGION").value) = %s
  | (.spec.containers[0].env[] | select(.name == "SECRET_ID").value) = %s
  | (.spec.containers[0].env[] | select(.name == "KMS_KEY_ARN").value) = %s
' "$(json_string "$NAMESPACE")" "$(json_string "$APP_IMAGE_URI")" \
  "$(json_string "$AWS_REGION")" "$(json_string "$AWS_REGION")" \
  "$(json_string "$SECRET_ARN")" "$(json_string "$KMS_KEY_ARN")")" \
  "$TMP_DIR/rendered-credentials-pod.json"

# The gate the control is tested against is read back live first. Its refusal only means
# "no attestation was refused" if the gate that produced it is the one this run installed.
verify_key_policy "$predicted_pcr17"

answered=false
for pod_attempt in 1 2 3; do
  kc delete pod "$CREDENTIALS_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
  kc apply -f "$TMP_DIR/rendered-credentials-pod.json"
  if [[ -z "$(wait_for_finish "$CREDENTIALS_POD_NAME" 60)" ]]; then
    echo "  attempt $pod_attempt of the no-attestation pod did not finish; replacing it"
    continue
  fi
  : > "$TMP_DIR/credentials-pod.log"
  kc logs "$CREDENTIALS_POD_NAME" -n "$NAMESPACE" -c main > "$TMP_DIR/credentials-pod.log" 2>/dev/null || true
  # A result line that is not "no decision" is an answer, whichever answer it is: the pod
  # reached AWS and AWS decided. "no decision" means it never got there, which is no
  # evidence either way, so that pod is replaced rather than reported. The assertions below
  # are what turn the wrong answer into a failure.
  if grep -Eq '^result:[[:space:]]+[^[:space:]]' "$TMP_DIR/credentials-pod.log" &&
     ! grep -Eq '^result:[[:space:]]+no decision$' "$TMP_DIR/credentials-pod.log"; then
    answered=true; break
  fi
  echo "  attempt $pod_attempt of the no-attestation pod reached no answer from KMS; replacing it"
done
[[ "$answered" == true ]] ||
  die "the no-attestation pod never got an answer from AWS KMS, in three attempts, so this run does not show whether the key policy refuses a request with no attestation. Its last output:
$(sed 's/^/    /' "$TMP_DIR/credentials-pod.log" 2>/dev/null)
  Check that a pod in $NAMESPACE can reach the Secrets Manager and KMS endpoints for $AWS_REGION."

# It had to be able to read the ciphertext, and it had to be refused the decrypt, and
# refused for the reason this sample is about. A non-zero exit alone is not enough:
# throttling, a network failure and an expired credential all produce one, so require the
# authorization wording that the attestation conditions, and only they, produce here.
grep -Eq '^secret:[[:space:]]+read [0-9]+ bytes of ciphertext' "$TMP_DIR/credentials-pod.log" ||
  die "the no-attestation pod could not read the ciphertext, so this run does not show that the role is allowed the read and refused the decrypt. Read: kubectl -n $NAMESPACE logs $CREDENTIALS_POD_NAME -c main"
grep -Eq '^result:[[:space:]]+refused$' "$TMP_DIR/credentials-pod.log" ||
  die "the no-attestation pod's kms:Decrypt was NOT refused. The key policy's explicit deny is not refusing a request that carries no attestation document, so this run does not show attestation as the boundary. Read: kubectl -n $NAMESPACE logs $CREDENTIALS_POD_NAME -c main"
grep -Eiq 'AccessDenied|not authorized|explicit deny' "$TMP_DIR/credentials-pod.log" ||
  die "the no-attestation pod's kms:Decrypt failed, but not with an authorization denial, so the refusal cannot be attributed to the attestation condition. Read: kubectl -n $NAMESPACE logs $CREDENTIALS_POD_NAME -c main"
echo "  the same role, with no attestation, could read the ciphertext and was refused the secret"

# Last, and the point of the whole sample: the secret itself is in none of the three pods'
# logs. The workload prints a byte count and a digest, and this is what proves it stayed
# that way, on the logs as they actually came back rather than on the code that wrote them.
# The plaintext is a single line of printable characters, which is what makes the search
# reliable; it has been sitting in this run's private temp directory for exactly this.
for pod_log in approved-pod.log plain-pod.log credentials-pod.log; do
  [[ -s "$TMP_DIR/$pod_log" ]] || continue
  ! grep -F -q -f "$work/plaintext" "$TMP_DIR/$pod_log" ||
    die "the secret value appears in $TMP_DIR/$pod_log. Nothing on the page may be copied from these logs; delete them and the pods."
done
echo "  the secret value is in none of the three pods' logs"

echo
echo "$POD_NAME ended Succeeded: it decrypted the secret inside the sandbox."
echo "  the sandbox pod's readings:    kubectl -n $NAMESPACE logs $POD_NAME -c main"
echo "  an ordinary pod's, same node:  kubectl -n $NAMESPACE logs $PLAIN_POD_NAME -c main"
echo "  the same role, no attestation: kubectl -n $NAMESPACE logs $CREDENTIALS_POD_NAME -c main"
echo "  the generated policy:          less $TMP_DIR/policy.yaml"
echo "  the live key policy:           less $TMP_DIR/kms-key-policy.live.json"
echo "  the refused case:              ./scripts/changed-pod.sh"
echo "  tear down:                     ./scripts/clean.sh"
