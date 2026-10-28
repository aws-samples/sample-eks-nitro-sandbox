#!/usr/bin/env bash
# Encrypt a file, upload the ciphertext and its wrapped data key to Amazon S3, gate that
# key on attestation in AWS KMS, and run the approved confidential-sandbox pod that reads
# the file back.
#
#   ./scripts/setup.sh              # the whole flow, ending with the pods finished
#   ./scripts/setup.sh --no-pods    # everything except starting the pods
#
# Reads .env (copy it from .env.example). Writes its run files, including the plaintext
# file, the ciphertext and the decoded policy, to the repository's tmp/s3-encrypted-file/.
#
# Every AWS resource it creates is tagged ManagedBy=s3-encrypted-file, and it reuses an
# existing one only when that tag is on it. The namespace carries a matching
# app.kubernetes.io/managed-by label, which clean.sh checks before it deletes anything
# inside. The script changes nothing that is shared by the whole cluster.
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHARED_DIR="$(cd "$SAMPLE_DIR/../_shared" && pwd)"
CONFIDENTIAL_DIR="$(cd "$SAMPLE_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/s3-encrypted-file"
# The run record goes under the repository's tmp/, with the rest of the run files, and
# never in the sample folder: it holds this account's ARNs and the key ARN.
STATE_FILE="$TMP_DIR/state.env"
WORK_DIR="$TMP_DIR/work"

MANAGED_BY="s3-encrypted-file"

# ---------------------------------------------------------------------------- settings
if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; . "$SAMPLE_DIR/.env"; set +a; fi

CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
S3_BUCKET="${S3_BUCKET:-}"
NAMESPACE="${NAMESPACE:-s3-encrypted-file-sample}"
ECR_REPOSITORY="${ECR_REPOSITORY:-s3-encrypted-file-sample}"
KMS_ALIAS="${KMS_ALIAS:-alias/s3-encrypted-file-sample}"
IAM_ROLE_NAME="${IAM_ROLE_NAME:-s3-encrypted-file-sample-pod}"
FILE_SIZE_BYTES="${FILE_SIZE_BYTES:-102400}"
SERVICE_ACCOUNT="s3-encrypted-file-pod"
POD_NAME="s3-encrypted-file-demo"
PLAIN_POD_NAME="s3-encrypted-file-plain"
CREDENTIALS_POD_NAME="s3-encrypted-file-credentials"
S3_CIPHERTEXT_KEY="confidential/report.bin"
S3_MANIFEST_KEY="confidential/report.bin.manifest.json"

# The Cedar policy generator the Amazon EKS User Guide names in "Cedar policies". Override
# it when your copy is named differently.
GENPOLICY="${GENPOLICY:-eks-nitro-sandbox-genpolicy}"
CONTAINER_CLI="${CONTAINER_CLI:-docker}"

PROFILE="$SHARED_DIR/confidential-profile.yaml"
KEY_POLICY_TEMPLATE="$SHARED_DIR/kms-key-policy.json"
TRUST_POLICY_TEMPLATE="$SHARED_DIR/pod-identity/role-trust-policy.json"
BUCKET_POLICY_TEMPLATE="$SAMPLE_DIR/deploy/bucket-policy.json"
GATE_CHECK="$SAMPLE_DIR/scripts/kms-gate-check.jq"

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
# So absence is proved by the service's own not-found exception and nothing else; any other
# error has to stop the script before it can create a duplicate of something that is
# already there.
#   lookup <not-found-exception> <aws args...>
#     prints stdout and returns 0 when the resource is there
#     returns 1 only when the named exception came back
#     returns 2 when it could not be determined, having printed the AWS error
#
# It returns 2 rather than exiting, because every caller runs it inside a command
# substitution: an exit there would leave the subshell only, and the caller would read the
# non-zero status as "absent" and go on to create the resource.
lookup() {
  local notfound="$1"; shift
  local out err rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/s3ef-out.XXXXXX")" || return 2
  err="$(mktemp "${TMPDIR:-/tmp}/s3ef-err.XXXXXX")" || return 2
  aws "$@" >"$out" 2>"$err" || rc=$?
  if [[ "$rc" == 0 ]]; then
    cat "$out"; rm -f "$out" "$err"; return 0
  fi
  if grep -Fq "$notfound" "$err"; then
    rm -f "$out" "$err"; return 1
  fi
  echo "ERROR: 'aws $*' failed (exit $rc) and not with $notfound, so it is unknown whether the resource exists:" >&2
  sed 's/^/  /' "$err" >&2
  rm -f "$out" "$err"
  return 2
}

# The other half of that contract, at the call site. A lookup that could not run must never
# reach the create path.
stop_if_undetermined() {  # stop_if_undetermined <lookup-rc> <description>
  [[ "$1" != 2 ]] ||
    die "could not determine whether $2 exists (the AWS error is above), so this run created and changed nothing. Re-run once the call succeeds."
}

# Confirms a resource this script is about to reuse carries the sample's ownership tag. A
# resource with the tag counts as the sample's whichever run created it; one without belongs
# to something else and is never touched.
require_managed_by() {  # require_managed_by <description> <actual-tag-value>
  [[ "$2" == "$MANAGED_BY" ]] ||
    die "$1 already exists and is not this sample's (ManagedBy='$2', expected '$MANAGED_BY'); created and changed nothing. Delete it, or set a new name in .env."
}

state_put() { printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"; }

# ------------------------------------------------------------------- 1/9 preflight
echo "== 1/9 check the tools, the cluster and the Region =="
[[ -n "$CLUSTER_NAME" ]] || die "CLUSTER_NAME is not set; copy .env.example to .env and fill it in"
[[ -n "$AWS_REGION" ]] || die "AWS_REGION is not set; copy .env.example to .env and fill it in"
[[ -n "$S3_BUCKET" ]] || die "S3_BUCKET is not set. An S3 bucket name is global, so this sample has no default: pick a name nobody has taken and set it in .env."
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

for c in aws jq kubectl base64 gzip sha256sum "$CONTAINER_CLI"; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required"
done
command -v "$GENPOLICY" >/dev/null 2>&1 ||
  die "$GENPOLICY is not on PATH. The Amazon EKS User Guide, \"Cedar policies\", names the policy generator and how to obtain it; set GENPOLICY in .env if your copy is named differently."
[[ -f "$GATE_CHECK" ]] || die "the key policy check $GATE_CHECK is missing"

mkdir -p "$TMP_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 700 "$WORK_DIR"

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
state_put S3_BUCKET "$S3_BUCKET"
state_put S3_CIPHERTEXT_KEY "$S3_CIPHERTEXT_KEY"
state_put S3_MANIFEST_KEY "$S3_MANIFEST_KEY"

# ------------------------------------------------- 2/9 the bucket, the repository, the key
echo "== 2/9 create the private bucket, the ECR repository and the KMS key =="

bucket_rc=0
lookup "(404)" s3api head-bucket --bucket "$S3_BUCKET" >/dev/null || bucket_rc=$?
stop_if_undetermined "$bucket_rc" "the S3 bucket $S3_BUCKET (a bucket name is global, so this also happens when somebody else owns it)"
if [[ "$bucket_rc" == 0 ]]; then
  tag_rc=0
  bucket_tags="$(lookup NoSuchTagSet s3api get-bucket-tagging --bucket "$S3_BUCKET" \
    --query 'TagSet' --output json)" || tag_rc=$?
  stop_if_undetermined "$tag_rc" "the tags of the S3 bucket $S3_BUCKET"
  bucket_tag=""
  if [[ "$tag_rc" == 0 ]]; then
    bucket_tag="$(jq -r '(map(select(.Key == "ManagedBy")) | first | .Value) // ""' <<<"$bucket_tags")"
  fi
  require_managed_by "the S3 bucket $S3_BUCKET" "$bucket_tag"
  echo "  reusing S3 bucket $S3_BUCKET"
  state_put BUCKET_CREATED false
else
  # us-east-1 is the one Region that must not be named in a LocationConstraint.
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$S3_BUCKET" >/dev/null
  else
    aws s3api create-bucket --bucket "$S3_BUCKET" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
  fi
  # S3 creates a bucket without tags, so the mark goes on in the next call.
  aws s3api put-bucket-tagging --bucket "$S3_BUCKET" \
    --tagging "TagSet=[{Key=ManagedBy,Value=$MANAGED_BY}]"
  echo "  created S3 bucket $S3_BUCKET"
  state_put BUCKET_CREATED true
fi

# Public access is blocked and server-side encryption is on, every run, whether the bucket
# was created here or reused: a bucket this sample uses has to be private either way.
aws s3api put-public-access-block --bucket "$S3_BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
# SSE-S3 (AES256), not SSE-KMS with this sample's key. S3 would have to call kms:Decrypt
# itself to serve an object encrypted with that key, and it has no attestation document, so
# the gate would refuse it and nobody could read the object at all. The confidentiality here
# comes from the application encryption, which is the point of the sample; this is the
# at-rest default every object in the bucket gets as well.
aws s3api put-bucket-encryption --bucket "$S3_BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
      "BucketKeyEnabled": true
    }]
  }'

# Read both back. A setting that was applied but is not in force is the case worth catching:
# the page says the bucket blocks public access and encrypts at rest, so the run has to show
# the bucket saying so itself.
pab="$(aws s3api get-public-access-block --bucket "$S3_BUCKET" \
  --query 'PublicAccessBlockConfiguration' --output json)" ||
  die "could not read the public access block of $S3_BUCKET"
jq -e '.BlockPublicAcls == true and .IgnorePublicAcls == true
       and .BlockPublicPolicy == true and .RestrictPublicBuckets == true' <<<"$pab" >/dev/null ||
  die "the bucket $S3_BUCKET does not block public access in all four ways: $(jq -c . <<<"$pab")"
sse="$(aws s3api get-bucket-encryption --bucket "$S3_BUCKET" \
  --query 'ServerSideEncryptionConfiguration.Rules' --output json)" ||
  die "could not read the server-side encryption of $S3_BUCKET"
jq -e 'any(.[]; .ApplyServerSideEncryptionByDefault.SSEAlgorithm != null)' <<<"$sse" >/dev/null ||
  die "the bucket $S3_BUCKET has no default server-side encryption: $(jq -c . <<<"$sse")"
echo "  the bucket blocks public access (all four) and encrypts at rest ($(jq -r '.[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' <<<"$sse"))"

repo_json=""; repo_rc=0
repo_json="$(lookup RepositoryNotFoundException ecr describe-repositories \
  --repository-names "$ECR_REPOSITORY" --query 'repositories[0]' --output json)" || repo_rc=$?
stop_if_undetermined "$repo_rc" "the ECR repository $ECR_REPOSITORY"
if [[ "$repo_rc" == 0 ]]; then
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

key_json=""; key_rc=0
key_json="$(lookup NotFoundException kms describe-key --key-id "$KMS_ALIAS" \
  --query 'KeyMetadata' --output json)" || key_rc=$?
stop_if_undetermined "$key_rc" "the KMS key behind $KMS_ALIAS"
zero_pcr17="$(printf '0%.0s' $(seq 96))"
if [[ "$key_rc" == 0 ]]; then
  kms_key_id="$(jq -r '.KeyId' <<<"$key_json")"
  kms_key_arn="$(jq -r '.Arn' <<<"$key_json")"
  key_tag="$(aws kms list-resource-tags --key-id "$kms_key_id" \
    --query "Tags[?TagKey=='ManagedBy'].TagValue | [0]" --output text)"
  if [[ "$key_tag" == "None" ]]; then key_tag=""; fi
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
  # build-time encrypt are there, and so are both denies, carrying an all-zero measurement
  # no sandbox can present. So the key denies every decrypt from the moment it exists, and
  # step 3 adds the allow once the role is there.
  jq --arg account "$account_id" --arg pcr17 "$zero_pcr17" '
    del(._comment)
    | (.Statement[] | select(.Sid == "KeyAdministration").Principal.AWS) = "arn:aws:iam::\($account):root"
    | (.Statement[] | select(.Sid == "BuildTimeEncrypt").Principal.AWS) = "arn:aws:iam::\($account):root"
    | (.Statement[] | select(.Sid == "DenyUnlessThePolicyMeasurementMatches").Condition.StringNotEqualsIgnoreCase["kms:RecipientAttestation:PCR17"]) = $pcr17
    | .Statement |= map(select(.Sid != "AttestedDecryptOnly"))
  ' "$KEY_POLICY_TEMPLATE" > "$TMP_DIR/kms-key-policy.birth.json"
  # The same file the gate check below uses, in its birth mode, so the two checks in this
  # script cannot disagree about what can reach the data key.
  jq -e --arg mode birth --arg role "" --arg roleid "" --arg pcr17 "" \
    -f "$GATE_CHECK" "$TMP_DIR/kms-key-policy.birth.json" >/dev/null ||
    die "the birth key policy would allow something that can reach a decrypt; refusing to create the key"
  key_json="$(aws kms create-key \
    --description "Wraps the data key of the encrypted S3 file for the EKS Nitro sandbox s3-encrypted-file sample" \
    --key-usage ENCRYPT_DECRYPT --key-spec SYMMETRIC_DEFAULT \
    --policy "file://$TMP_DIR/kms-key-policy.birth.json" \
    --tags "TagKey=ManagedBy,TagValue=$MANAGED_BY" \
    --query 'KeyMetadata' --output json)"
  kms_key_id="$(jq -r '.KeyId' <<<"$key_json")"
  kms_key_arn="$(jq -r '.Arn' <<<"$key_json")"
  aws kms create-alias --alias-name "$KMS_ALIAS" --target-key-id "$kms_key_id"
  echo "  created KMS key $kms_key_arn"
  echo "  it denies every decrypt already: created with a policy, not the default one"
  state_put KMS_CREATED true
fi
state_put KMS_ALIAS "$KMS_ALIAS"
state_put KMS_KEY_ID "$kms_key_id"
state_put KMS_KEY_ARN "$kms_key_arn"

# ------------------------------------- 3/9 the pod's role, the gate, and the bucket policy
echo "== 3/9 create the pod's IAM role, the born-denied key policy and the bucket policy =="

trust_policy="$(jq --arg c "$CLUSTER_NAME" --arg n "$NAMESPACE" --arg s "$SERVICE_ACCOUNT" '
  del(._comment)
  | .Statement[0].Condition.StringEquals["aws:RequestTag/eks-cluster-name"] = $c
  | .Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-namespace"] = $n
  | .Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-service-account"] = $s
' "$TRUST_POLICY_TEMPLATE")"
printf '%s\n' "$trust_policy" > "$TMP_DIR/role-trust-policy.json"

role_json=""; role_rc=0
role_json="$(lookup NoSuchEntity iam get-role --role-name "$IAM_ROLE_NAME" \
  --query 'Role' --output json)" || role_rc=$?
stop_if_undetermined "$role_rc" "the IAM role $IAM_ROLE_NAME"
if [[ "$role_rc" == 0 ]]; then
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
    --description "EKS Pod Identity role for the s3-encrypted-file sample; no identity policies by design" \
    --tags "Key=ManagedBy,Value=$MANAGED_BY" \
    --query 'Role.Arn' --output text)"
  echo "  created IAM role $role_arn"
  state_put IAM_CREATED true
fi
# The role's unique id, as well as its ARN. A key policy naming a role that has only just
# been created, or recreated under a name that existed before, can come back from KMS with
# this id in place of the ARN: both name the same principal, and the id names only this
# role, never a later one of the same name. The gate check accepts either form.
role_id="$(aws iam get-role --role-name "$IAM_ROLE_NAME" --query 'Role.RoleId' --output text)"
[[ -n "$role_id" && "$role_id" != "None" ]] || die "could not read the unique id of the role $IAM_ROLE_NAME"
state_put IAM_ROLE_NAME "$IAM_ROLE_NAME"
state_put IAM_ROLE_ARN "$role_arn"
state_put IAM_ROLE_ID "$role_id"

# The role must carry no identity policy, attached or inline. One that allowed kms:Decrypt
# would grant it without the attestation condition, and the gate below would then decide
# nothing at all; one that allowed s3:GetObject more widely would widen what the pod can
# read past the two objects the bucket policy names.
inline_count="$(aws iam list-role-policies --role-name "$IAM_ROLE_NAME" \
  --query 'length(PolicyNames)' --output text)"
attached_count="$(aws iam list-attached-role-policies --role-name "$IAM_ROLE_NAME" \
  --query 'length(AttachedPolicies)' --output text)"
[[ "$inline_count" == "0" && "$attached_count" == "0" ]] ||
  die "the role $IAM_ROLE_NAME carries identity policies ($inline_count inline, $attached_count attached). The KMS key policy and the S3 bucket policy are meant to be its only grants, so an identity policy could allow kms:Decrypt with no attestation condition and the gate would decide nothing. Remove them, or set a new IAM_ROLE_NAME in .env."
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
  # visible to KMS. It is an ordinary propagation delay and it clears in a few seconds, so
  # retry on that one error and on nothing else.
  local attempt err rc
  err="$(mktemp "${TMPDIR:-/tmp}/s3ef-kp.XXXXXX")" || die "mktemp failed"
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

# A put that lands while the role is still propagating is stored with the role's unique id
# in place of its ARN. The gate is the same either way, but the ARN is the readable form, so
# put it again a few times to let it settle on the ARN. This never loops on a wrong gate: it
# only ever re-sends the same document, and it gives up quietly, leaving verify_key_policy
# to accept the id form.
settle_key_policy_principal() {
  local attempt stored
  for attempt in $(seq 6); do
    stored="$(aws kms get-key-policy --key-id "$kms_key_arn" --policy-name default \
      --query Policy --output text \
      | jq -r '[.Statement[] | select(.Sid == "AttestedDecryptOnly")
                | (.Principal.AWS | if type == "array" then .[] else . end)] | join(",")')"
    [[ "$stored" != "$role_arn" ]] || return 0
    # No AttestedDecryptOnly at all is not something waiting will fix; leave it to
    # verify_key_policy, which has the error message for it.
    [[ -n "$stored" ]] || return 0
    sleep 5
    aws kms put-key-policy --key-id "$kms_key_arn" --policy-name default \
      --policy "file://$TMP_DIR/kms-key-policy.json" >/dev/null 2>&1 || true
  done
  return 0
}

# Reads the live policy back and checks it is the gate this run installed, through
# scripts/kms-gate-check.jq.
verify_key_policy() {  # verify_key_policy <expected-pcr17>
  aws kms get-key-policy --key-id "$kms_key_arn" --policy-name default \
    --query Policy --output text | jq . > "$TMP_DIR/kms-key-policy.live.json"
  jq -e --arg mode gate --arg role "$role_arn" --arg roleid "$role_id" --arg pcr17 "$1" \
    -f "$GATE_CHECK" "$TMP_DIR/kms-key-policy.live.json" >/dev/null ||
    die "the live KMS key policy is not the gate this script installed (read back into $TMP_DIR/kms-key-policy.live.json). A denial only means the measurement was refused if the gate that produced it is the gate we believe is there."
}

put_key_policy "$zero_pcr17"
settle_key_policy_principal
verify_key_policy "$zero_pcr17"
echo "  the key policy allows no decrypt yet (gated on an all-zero measurement)"

# The bucket policy is the role's only access to the bucket, as the key policy is its only
# access to the key. It names the two objects, key by key.
jq --arg role "$role_arn" --arg bucket "$S3_BUCKET" \
   --arg ciphertext "$S3_CIPHERTEXT_KEY" --arg manifest "$S3_MANIFEST_KEY" '
  del(._comment)
  | (.Statement[] | select(.Sid == "PodMayReadTheCiphertextAndItsManifest").Principal.AWS) = $role
  | (.Statement[] | select(.Sid == "PodMayReadTheCiphertextAndItsManifest").Resource) =
      ["arn:aws:s3:::\($bucket)/\($ciphertext)", "arn:aws:s3:::\($bucket)/\($manifest)"]
  | (.Statement[] | select(.Sid == "DenyUnencryptedTransport").Resource) =
      ["arn:aws:s3:::\($bucket)", "arn:aws:s3:::\($bucket)/*"]
' "$BUCKET_POLICY_TEMPLATE" > "$TMP_DIR/bucket-policy.json"
aws s3api put-bucket-policy --bucket "$S3_BUCKET" --policy "file://$TMP_DIR/bucket-policy.json"
# Read it back. The one thing that must be true of it is that it grants the role no KMS
# action and nothing on the bucket beyond reading the two objects: if it did, the key policy
# would not be the only thing standing between the credentials and the data key.
aws s3api get-bucket-policy --bucket "$S3_BUCKET" --query Policy --output text \
  | jq . > "$TMP_DIR/bucket-policy.live.json"
jq -e --arg role "$role_arn" --arg bucket "$S3_BUCKET" \
      --arg ciphertext "$S3_CIPHERTEXT_KEY" --arg manifest "$S3_MANIFEST_KEY" '
  def actions: (.Action | if type == "array" then . else [.] end);
  ([.Statement[] | select(.Effect == "Allow")] | length) as $allows
  | ([.Statement[] | select(.Effect == "Allow")
      | select((.Principal.AWS | if type == "array" then . else [.] end) == [$role])
      | select(actions == ["s3:GetObject"])
      | select((.Resource | if type == "array" then . else [.] end | sort)
               == (["arn:aws:s3:::\($bucket)/\($ciphertext)",
                    "arn:aws:s3:::\($bucket)/\($manifest)"] | sort))
      | select(.Condition == null)
     ] | length) as $read_allows
  | ([.Statement[] | select(.Effect == "Allow") | actions[]
      | select(ascii_downcase | startswith("kms:") or . == "*")] | length) as $kms_allows
  | $allows == 1 and $read_allows == 1 and $kms_allows == 0
' "$TMP_DIR/bucket-policy.live.json" >/dev/null ||
  die "the live bucket policy is not the one this script installed: it must hold exactly one Allow, for s3:GetObject on the two objects by the pod's role, and grant no KMS action (read back into $TMP_DIR/bucket-policy.live.json)"
echo "  the bucket policy grants the pod s3:GetObject on the two objects and nothing else"

# ------------------------------------- 4/9 namespace, service account and the association
echo "== 4/9 create the namespace, the service account and the association =="

ns_name_filter="$(printf '.metadata.name = %s' "$(jq -n --arg v "$NAMESPACE" '$v')")"
ns_filter="$(printf '.metadata.namespace = %s' "$(jq -n --arg v "$NAMESPACE" '$v')")"
render() {  # render <manifest> <jq-filter> <out>
  kc create --dry-run=client --validate=false -o json -f "$1" | jq "$2" > "$3"
}

render "$SAMPLE_DIR/deploy/namespace.yaml" "$ns_name_filter" "$TMP_DIR/rendered-namespace.json"
render "$SAMPLE_DIR/deploy/service-account.yaml" "$ns_filter" "$TMP_DIR/rendered-service-account.json"

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
    --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" --role-arn "$role_arn" \
    --tags "ManagedBy=$MANAGED_BY" \
    --query 'association.associationId' --output text)"
  echo "  created Pod Identity association $assoc_id"
  state_put ASSOCIATION_CREATED true
else
  assoc_json="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --association-id "$assoc_id" --query 'association' --output json)"
  # The same ownership test the other AWS resources get, and the one clean.sh applies before
  # it will delete this association.
  assoc_tag="$(jq -r '.tags.ManagedBy // ""' <<<"$assoc_json")"
  require_managed_by "the Pod Identity association for $NAMESPACE/$SERVICE_ACCOUNT" "$assoc_tag"
  assoc_role="$(jq -r '.roleArn' <<<"$assoc_json")"
  [[ "$assoc_role" == "$role_arn" ]] ||
    die "a Pod Identity association for $NAMESPACE/$SERVICE_ACCOUNT already points at $assoc_role, not $role_arn; changed nothing"
  echo "  reusing Pod Identity association $assoc_id"
  state_put ASSOCIATION_CREATED false
fi
state_put SERVICE_ACCOUNT "$SERVICE_ACCOUNT"
state_put ASSOCIATION_ID "$assoc_id"

# ------------------------------------------------------- 5/9 build and push the image
echo "== 5/9 build the application image and push it to ECR =="

# The tag carries a digest of the sources that go into the image, so a change to the
# application or to the attested recipient publishes a new reference rather than reusing a
# stale one under a tag that cannot be overwritten.
src_digest="$(cat "$SAMPLE_DIR/Dockerfile" "$SAMPLE_DIR/src/requirements.txt" \
  "$SAMPLE_DIR/src/app.py" "$SAMPLE_DIR/src/encrypt_file.py" \
  "$SHARED_DIR/attested_recipient.py" | sha256sum | cut -c1-12)"
IMAGE_TAG="v1-$src_digest"
APP_IMAGE_URI="$registry/$ECR_REPOSITORY:$IMAGE_TAG"
state_put IMAGE_TAG "$IMAGE_TAG"
state_put APP_IMAGE_URI "$APP_IMAGE_URI"

# The local build tag is the same reference, so the encrypt helper below runs the very image
# the pod runs.
"$CONTAINER_CLI" build -f "$SAMPLE_DIR/Dockerfile" -t "$APP_IMAGE_URI" "$CONFIDENTIAL_DIR"

image_rc=0
pushed_manifest="$(lookup ImageNotFoundException ecr batch-get-image \
  --repository-name "$ECR_REPOSITORY" --image-ids "imageTag=$IMAGE_TAG" \
  --accepted-media-types application/vnd.oci.image.manifest.v1+json \
                         application/vnd.docker.distribution.manifest.v2+json \
  --query 'images[0].imageManifest' --output text)" || image_rc=$?
stop_if_undetermined "$image_rc" "the published image $APP_IMAGE_URI"
if [[ "$image_rc" == 0 && -n "$pushed_manifest" && "$pushed_manifest" != "None" ]]; then
  echo "  the image is already in ECR under this tag; not pushing again"
else
  # The registry password goes to a throwaway container config, never onto a command line
  # and never into the reader's own ~/.docker/config.json.
  mkdir -p "$TMP_DIR/docker"
  chmod 700 "$TMP_DIR/docker"
  aws ecr get-login-password |
    "$CONTAINER_CLI" --config "$TMP_DIR/docker" login --username AWS --password-stdin "$registry" >/dev/null
  "$CONTAINER_CLI" --config "$TMP_DIR/docker" push "$APP_IMAGE_URI"
  echo "  pushed $APP_IMAGE_URI"
fi
pushed_digest="$(aws ecr describe-images --repository-name "$ECR_REPOSITORY" \
  --image-ids "imageTag=$IMAGE_TAG" --query 'imageDetails[0].imageDigest' --output text)"
[[ "$pushed_digest" == sha256:* ]] ||
  die "could not read the digest of the published image $APP_IMAGE_URI"
state_put APP_IMAGE_DIGEST "$pushed_digest"

# --------------------------------------------------- 6/9 encrypt the file and upload it
echo "== 6/9 encrypt the file, wrap its data key and upload both =="

# The file this sample protects. Random bytes: what matters is that only the sandbox can
# read them back, and a file whose every byte is unpredictable makes "the stored object is
# not the file" easy to see.
head -c "$FILE_SIZE_BYTES" /dev/urandom > "$WORK_DIR/report.bin"
plaintext_bytes="$(wc -c < "$WORK_DIR/report.bin" | tr -d ' ')"
[[ "$plaintext_bytes" == "$FILE_SIZE_BYTES" ]] ||
  die "could not create a $FILE_SIZE_BYTES byte file (got $plaintext_bytes)"

# The data key never goes on a command line, and it is deleted as soon as the file is
# encrypted and the key wrapped. It is the only secret on the setup machine.
( umask 077; head -c 32 /dev/urandom > "$WORK_DIR/data-key.bin" )
aws kms encrypt --key-id "$kms_key_arn" \
  --plaintext "fileb://$WORK_DIR/data-key.bin" \
  --query CiphertextBlob --output text > "$WORK_DIR/wrapped-data-key.b64"
[[ -s "$WORK_DIR/wrapped-data-key.b64" ]] || die "kms:Encrypt returned no wrapped data key"

# The encrypt helper runs in the image that was just built, so the setup machine needs no
# Python packages of its own. It writes into the run's work directory as the invoking user.
summary="$("$CONTAINER_CLI" run --rm \
  --user "$(id -u):$(id -g)" \
  --network none \
  -v "$WORK_DIR:/work" \
  --entrypoint python \
  "$APP_IMAGE_URI" /app/encrypt_file.py \
    --plaintext /work/report.bin \
    --data-key /work/data-key.bin \
    --ciphertext /work/report.bin.enc \
    --manifest /work/manifest.json \
    --bucket "$S3_BUCKET" \
    --ciphertext-key "$S3_CIPHERTEXT_KEY" \
    --key-arn "$kms_key_arn" \
    --encrypted-data-key-file /work/wrapped-data-key.b64)"
shred -u "$WORK_DIR/data-key.bin" 2>/dev/null || rm -f "$WORK_DIR/data-key.bin"
[[ ! -e "$WORK_DIR/data-key.bin" ]] || die "could not remove the plaintext data key from $WORK_DIR"

plaintext_sha256="$(jq -r '.plaintext_sha256' <<<"$summary")"
expected_length="$(jq -r '.plaintext_length' <<<"$summary")"
ciphertext_sha256="$(jq -r '.ciphertext_sha256' <<<"$summary")"
ciphertext_length="$(jq -r '.ciphertext_length' <<<"$summary")"
[[ "$plaintext_sha256" =~ ^[0123456789abcdef]{64}$ && "$expected_length" == "$plaintext_bytes" ]] ||
  die "the encrypt helper did not report a usable summary: $summary"
state_put EXPECTED_SHA256 "$plaintext_sha256"
state_put EXPECTED_LENGTH "$expected_length"
echo "  encrypted $expected_length bytes with AES-256-GCM into $ciphertext_length bytes of ciphertext"

aws s3api put-object --bucket "$S3_BUCKET" --key "$S3_CIPHERTEXT_KEY" \
  --body "$WORK_DIR/report.bin.enc" --content-type application/octet-stream >/dev/null
aws s3api put-object --bucket "$S3_BUCKET" --key "$S3_MANIFEST_KEY" \
  --body "$WORK_DIR/manifest.json" --content-type application/json >/dev/null
echo "  uploaded s3://$S3_BUCKET/$S3_CIPHERTEXT_KEY and the manifest beside it"

# What is actually stored is read back and checked, rather than assumed from what was
# uploaded: the page claims the object is ciphertext and not the file.
aws s3api get-object --bucket "$S3_BUCKET" --key "$S3_CIPHERTEXT_KEY" \
  "$WORK_DIR/stored.bin" >/dev/null
stored_sha256="$(sha256sum "$WORK_DIR/stored.bin" | cut -d' ' -f1)"
stored_length="$(wc -c < "$WORK_DIR/stored.bin" | tr -d ' ')"
[[ "$stored_sha256" != "$plaintext_sha256" ]] ||
  die "the object stored in S3 IS the plaintext file; the upload did not encrypt anything"
[[ "$stored_sha256" == "$ciphertext_sha256" && "$stored_length" == "$ciphertext_length" ]] ||
  die "the object in S3 is not the ciphertext this run uploaded ($stored_length bytes, sha256 $stored_sha256)"
# AES-GCM adds a 16 byte authentication tag and nothing else, so this is the whole
# difference in length between the file and the object.
[[ "$stored_length" == "$((expected_length + 16))" ]] ||
  die "the stored object is $stored_length bytes, not the expected $((expected_length + 16)) (the file plus the 16 byte GCM tag)"
echo "  the stored object differs from the file and is 16 bytes longer (the GCM tag)"

wrapped_data_key="$(jq -r '.encrypted_data_key' "$WORK_DIR/manifest.json")"
[[ -n "$wrapped_data_key" && "$wrapped_data_key" != "null" ]] ||
  die "could not read the wrapped data key out of the manifest"
state_put WRAPPED_DATA_KEY "$wrapped_data_key"

# ------------------------------------------------------- 7/9 generate and gate
echo "== 7/9 generate the Cedar policy and set the gate to its measurement =="

# One map of values for every manifest the run applies, so a name the reader changed in
# .env reaches every object that uses it.
values_json="$(jq -n \
  --arg AWS_REGION "$AWS_REGION" \
  --arg APP_IMAGE_URI "$APP_IMAGE_URI" \
  --arg S3_BUCKET "$S3_BUCKET" \
  --arg S3_CIPHERTEXT_KEY "$S3_CIPHERTEXT_KEY" \
  --arg S3_MANIFEST_KEY "$S3_MANIFEST_KEY" \
  --arg KMS_KEY_ARN "$kms_key_arn" \
  --arg EXPECTED_SHA256 "$plaintext_sha256" \
  --arg EXPECTED_LENGTH "$expected_length" \
  --arg WRAPPED_DATA_KEY "$wrapped_data_key" \
  '$ARGS.named')"

fill() {  # fill <manifest> <out>  (substitutes <PLACEHOLDER>s and the namespace)
  kc create --dry-run=client --validate=false -o json -f "$1" \
    | jq --argjson v "$values_json" --arg ns "$NAMESPACE" '
        def sub_all:
          if type == "string"
          then reduce ($v | keys_unsorted[]) as $k (.; gsub("<" + $k + ">"; $v[$k]))
          else . end;
        walk(sub_all) | .metadata.namespace = $ns
      ' > "$2"
}

# Nothing of the kind "<SOMETHING>" may be left in a manifest that is about to be applied:
# an unfilled placeholder would otherwise be measured into the policy and read on the page
# as if it were a value. The pattern wants the whole JSON string to be the placeholder, so
# it does not match the "<ACCOUNT_ID>" the credentials pod's own redaction writes.
#
# The ranges here are deliberate, where the patterns that read a measurement write their
# character classes out. This one stops the script when it MATCHES, so a range that the
# locale widens makes it stop more often, never less: the risk runs the safe way. Narrowing
# it to the 26 ASCII letters would be the change that could let a placeholder through.
no_placeholders_left() {  # no_placeholders_left <rendered-json> <what>
  ! grep -qE '"<[A-Z0-9_]+>"' "$1" ||
    die "the rendered $2 still holds an unfilled placeholder: $(grep -oE '"<[A-Z0-9_]+>"' "$1" | sort -u | tr '\n' ' ')"
}

fill "$SAMPLE_DIR/deploy/pod.yaml" "$TMP_DIR/pod-input.json"
no_placeholders_left "$TMP_DIR/pod-input.json" "sandbox pod"

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

# The generator prints the measurement it predicts for this policy, under a header line.
# Take the first 96-hex-character line after it: a SHA-384, which is what the agent extends
# into PCR17 (Amazon EKS User Guide, "Cedar policies").
#
# Every digit and hex class in this script is written out rather than written as a range
# such as 0-9, because both bash and awk match a bracket range against the locale's
# collating order: under en_US.utf8 the range form also accepts characters that are not
# ASCII hex digits. This value is about to become the condition in a KMS key policy, so a
# pattern that accepted one of those would gate the data key on a measurement no sandbox
# can present, and the sample would look like a working gate that nothing can pass.
predicted_pcr17="$(awk '
  /--- Predicted PCR17 ---/ { found = 1; next }
  found {
    value = tolower($0); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
    if (value ~ /^[0123456789abcdef]{96}$/) { print value; exit }
  }' "$TMP_DIR/genpolicy.log")"
[[ "$predicted_pcr17" =~ ^[0123456789abcdef]{96}$ ]] ||
  die "could not read a predicted PCR17 from the generator's output ($TMP_DIR/genpolicy.log)"
[[ "$predicted_pcr17" != "$zero_pcr17" ]] ||
  die "the predicted PCR17 is all zeros, which is the value that means 'no sandbox can match'"
state_put PREDICTED_PCR17 "$predicted_pcr17"
echo "  predicted PCR17: $predicted_pcr17"

# Decode the envelope so the policy can be read; what travels in the annotation is gzipped
# and base64-encoded, which is not readable by eye.
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

# What the policy has to pin for the measurement to mean anything here. The generator also
# writes values into comments, so comment lines go first and the comparison is on the
# policy's own text with its whitespace removed, which is how a clause split across lines is
# matched without depending on where it was wrapped.
admission_text="$(jq -r '.admission_policy' "$TMP_DIR/policy.json" \
  | sed '/^[[:space:]]*\/\//d' | tr -d '[:space:]')"
# The image, under the permit that creates the container, and the digest this run pushed.
pins="$(awk '
  /^[[:space:]]*permit\(/ { rule = "permit"; which = ""; next }
  /^[[:space:]]*forbid\(/ { rule = "forbid"; which = ""; next }
  /^[[:space:]]*action == Agent::Action::"CreateContainer"/ { which = "create"; next }
  /^[[:space:]]*context\.image_ref == "/ {
    if (rule == "permit" && which == "create" && !("create" in seen)) {
      line = $0
      sub(/^[^"]*"/, "", line); sub(/".*$/, "", line)
      seen["create"] = line
    }
  }
  END { print (("create" in seen) ? seen["create"] : "NONE") }
' <<<"$(jq -r '.admission_policy' "$TMP_DIR/policy.json")")"
[[ "$pins" == "$registry/$ECR_REPOSITORY@$pushed_digest" ]] ||
  die "the generated policy pins '$pins' under its CreateContainer permit, which is not the image this run published ($registry/$ECR_REPOSITORY@$pushed_digest); read $TMP_DIR/policy.yaml"
echo "  image digest pinned under the CreateContainer permit: $pins"
# And the environment the application trusts. EXPECTED_SHA256 and EXPECTED_LENGTH are what
# it validates the decrypted file against, and S3_BUCKET, S3_MANIFEST_KEY and KMS_KEY_ARN
# are where it goes and which key it accepts an answer from. Pinned means an operator cannot
# move any of them without changing the measurement, and so without losing the data key.
for pair in "EXPECTED_SHA256=$plaintext_sha256" "EXPECTED_LENGTH=$expected_length" \
            "S3_BUCKET=$S3_BUCKET" "S3_MANIFEST_KEY=$S3_MANIFEST_KEY" \
            "KMS_KEY_ARN=$kms_key_arn"; do
  name="${pair%%=*}"; value="${pair#*=}"
  grep -Fq "{\"name\":\"$name\",\"value\":\"$value\"}" <<<"$admission_text" ||
    die "the generated policy does not pin $name to the value this run set; read $TMP_DIR/policy.yaml"
done
echo "  the policy pins the bucket, the manifest key, the key ARN, and the expected length and digest"

put_key_policy "$predicted_pcr17"
settle_key_policy_principal
verify_key_policy "$predicted_pcr17"
echo "  the gate now releases the data key only to this measurement"
# A key policy change takes a moment to be in force everywhere. Starting the pod before it
# is would produce a decrypt denial that has nothing to do with the measurement.
sleep "${KMS_POLICY_PROPAGATION_WAIT_SECONDS:-15}"

# ------------------------------------------------------------------ 8/9 the two pods
if [[ "$no_pods" == true ]]; then
  echo
  echo "Set up, no pods started. The policy is in $TMP_DIR/policy.yaml."
  exit 0
fi

echo "== 8/9 run the approved pod, and an ordinary pod on the same node =="
policy_b64="$(tr -d '\r\n' < "$TMP_DIR/policy.b64")"
jq --arg name "$POD_NAME" --arg policy "$policy_b64" '
  .metadata.name = $name
  | .metadata.annotations["sandbox.amazonaws.com/policy"] = $policy
' "$TMP_DIR/pod-input.json" > "$TMP_DIR/rendered-pod.json"

# Replace rather than apply over: a pod's policy annotation is immutable, so a pod left from
# an earlier run would go on enforcing the earlier policy.
kc delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
kc apply -f "$TMP_DIR/rendered-pod.json"

# The pod decrypts and exits, so what is waited for is a terminal phase, not Ready.
phase=""
for _ in $(seq 120); do
  phase="$(kc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]]; then break; fi
  sleep 5
done
node_name="$(kc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
if [[ "$phase" != "Succeeded" ]]; then
  kc get pod "$POD_NAME" -n "$NAMESPACE" -o wide 2>/dev/null || true
  kc logs "$POD_NAME" -n "$NAMESPACE" -c main 2>/dev/null | sed 's/^/    /' || true
  kc get pod "$POD_NAME" -n "$NAMESPACE" \
    -o jsonpath='{range .status.containerStatuses[*]}{.state.waiting.message}{.state.terminated.message}{"\n"}{end}' 2>/dev/null || true
  die "the approved pod did not end Succeeded (phase '$phase'). Its logs are above."
fi
[[ -n "$node_name" ]] || die "could not read the node the approved pod landed on"
state_put NODE_NAME "$node_name"

approved_log="$(kc logs "$POD_NAME" -n "$NAMESPACE" -c main)"
printf '%s\n' "$approved_log" > "$TMP_DIR/approved-pod.log"
grep -Eq '^attested-s3-ok bytes=[0123456789]+ sha256=[0123456789abcdef]{64}$' <<<"$approved_log" ||
  die "the approved pod ended Succeeded but printed no validation marker; read $TMP_DIR/approved-pod.log"
grep -Fq "attested-s3-ok bytes=$expected_length sha256=$plaintext_sha256" <<<"$approved_log" ||
  die "the approved pod validated a file that is not the one this run uploaded; read $TMP_DIR/approved-pod.log"
echo "  $POD_NAME ended Succeeded: $(grep -E '^attested-s3-ok' <<<"$approved_log")"

# The ordinary pod: the same image and the same code, with --readings-only, on the same node,
# so the page can show what an ordinary pod reads for the same four readings.
fill "$SAMPLE_DIR/deploy/plain-pod.yaml" "$TMP_DIR/plain-pod-input.json"
jq --arg node "$node_name" '.spec.nodeName = $node' \
  "$TMP_DIR/plain-pod-input.json" > "$TMP_DIR/rendered-plain-pod.json"
no_placeholders_left "$TMP_DIR/rendered-plain-pod.json" "ordinary pod"
kc delete pod "$PLAIN_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
kc apply -f "$TMP_DIR/rendered-plain-pod.json"
plain_phase=""
for _ in $(seq 60); do
  plain_phase="$(kc get pod "$PLAIN_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$plain_phase" == "Succeeded" || "$plain_phase" == "Failed" ]]; then break; fi
  sleep 5
done
[[ "$plain_phase" == "Succeeded" ]] ||
  die "the ordinary pod on $node_name did not end Succeeded (phase '$plain_phase')"
kc logs "$PLAIN_POD_NAME" -n "$NAMESPACE" -c main > "$TMP_DIR/plain-pod.log"
echo "  the ordinary pod on the same node printed its own readings"

# --------------------------------------- 9/9 the same role, with no attestation document
echo "== 9/9 the same role, with no attestation document =="
fill "$SAMPLE_DIR/deploy/credentials-pod.yaml" "$TMP_DIR/rendered-credentials-pod.json"
no_placeholders_left "$TMP_DIR/rendered-credentials-pod.json" "credentials pod"

# This pod is started up to three times, because a pod can come up with a datapath that is
# not ready and then never reach AWS at all. Observed on a busy cluster: a pod sat with no
# egress for its whole life while a pod created minutes later, on the same node, reached AWS
# first time. A pod that reached no decision is not evidence either way about the key policy,
# so it is replaced rather than reported. Only a pod that got an answer from KMS ends the
# loop.
credentials_log=""
credentials_answered=false
for pod_attempt in 1 2 3; do
  kc delete pod "$CREDENTIALS_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
  kc apply -f "$TMP_DIR/rendered-credentials-pod.json"
  # Long enough for the pod's own retries to run out: it asks up to five times, with short
  # timeouts, which is about six minutes at worst. Giving up sooner than the pod does would
  # report a pod that was still asking as one that reached no answer.
  for _ in $(seq 150); do
    credentials_log="$(kc logs "$CREDENTIALS_POD_NAME" -n "$NAMESPACE" -c main 2>/dev/null || true)"
    if grep -Fq "s3-encrypted-file-credentials-done" <<<"$credentials_log"; then break; fi
    sleep 5
  done
  if grep -Fq "s3-encrypted-file-credentials-done" <<<"$credentials_log" &&
     grep -Eiq 'AccessDenied|not authorized|explicit deny' <<<"$credentials_log"; then
    credentials_answered=true; break
  fi
  if grep -Eq '^exit:[[:space:]]+0$' <<<"$credentials_log"; then
    credentials_answered=true; break   # a success: the check below turns this into a failure
  fi
  echo "  attempt $pod_attempt of the credentials pod reached no answer from KMS; replacing it"
done
printf '%s\n' "$credentials_log" > "$TMP_DIR/credentials-pod.log"
[[ "$credentials_answered" == true ]] ||
  die "the credentials pod never got an answer from AWS KMS, in three attempts, so this run does not show whether the key policy refuses a request with no attestation. Its last output is in $TMP_DIR/credentials-pod.log. Check that a pod in $NAMESPACE can reach the S3 and KMS endpoints for $AWS_REGION."

# It had to read the object, and it had to be refused the data key. The read is half the
# claim: a caller who can read the object still does not have the file.
grep -Eq '^s3:[[:space:]]+read [0123456789]+ bytes of ciphertext' <<<"$credentials_log" ||
  die "the credentials pod could not read the encrypted object, so this run does not show that reading it is not enough. Read $TMP_DIR/credentials-pod.log"
# A non-zero exit alone is not enough: throttling, a network failure and an expired
# credential all produce one, so require the authorization wording that the attestation
# conditions, and only they, produce here.
grep -Eq '^exit:[[:space:]]+[123456789]' <<<"$credentials_log" ||
  die "the credentials pod's kms:Decrypt did NOT fail. The key policy's explicit deny is not refusing a request that carries no attestation document, so this run does not show attestation as the boundary. Read $TMP_DIR/credentials-pod.log"
grep -Eiq 'AccessDenied|not authorized|explicit deny' <<<"$credentials_log" ||
  die "the credentials pod's kms:Decrypt failed, but not with an authorization denial, so the refusal cannot be attributed to the attestation condition. Read $TMP_DIR/credentials-pod.log"
echo "  it read the ciphertext, and the same role with no attestation was refused the data key"

echo
echo "$POD_NAME decrypted the file inside the sandbox and ended Succeeded."
echo "  the sandbox pod's own readings:  kubectl -n $NAMESPACE logs $POD_NAME -c main"
echo "  an ordinary pod's, same node:    kubectl -n $NAMESPACE logs $PLAIN_POD_NAME -c main"
echo "  the same role, no attestation:   kubectl -n $NAMESPACE logs $CREDENTIALS_POD_NAME -c main"
echo "  the generated policy:            less $TMP_DIR/policy.yaml"
echo "  the live key policy:             less $TMP_DIR/kms-key-policy.live.json"
echo "  the refused case:                ./scripts/changed-pod.sh"
echo "  tear down:                       ./scripts/clean.sh"
