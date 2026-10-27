#!/usr/bin/env bash
# The operator's one-time setup, plus the provider's first release.
#
#   ./scripts/setup.sh
#
# It creates the AWS Signer signing profile and the ECR repository, builds and signs the
# first release, gives the pod a role that can do nothing but check this profile's
# revocation status, generates TWO policies from the same pod spec, and starts the pod
# under the signer-based one:
#
#   policy.signer.b64   --require-signatures --require-any-signer <profile ARN>
#                       --skip-image-ref-container app: trust by signature. This is the
#                       one the pod runs under, and the one that never changes again.
#   policy.pinned.b64   the generator's default for the confidential profile, which pins
#                       the digest this release resolved to. Nothing runs under it here;
#                       scripts/pinned-arm.sh uses it later to show what the digest pin
#                       does to the provider's next release.
#
# Every AWS resource it creates is tagged ManagedBy, and only a resource carrying that tag
# is ever reused, so the sample cannot touch another demo's resources in a shared account.
# Local files, including the run record, go under the repository's gitignored tmp/.
#
# Tear down with ./scripts/clean.sh (add --delete-aws-resources for the ECR repository,
# the IAM role and the signing profile).
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ "${1:-}" == "" ]] || { echo "unknown argument: $1" >&2; exit 2; }

load_env
require_commands aws docker notation kubectl jq base64 gzip
command -v "$GENPOLICY" >/dev/null 2>&1 ||
  die "$GENPOLICY is not on PATH. The Amazon EKS User Guide, \"Cedar policies\", names the generator; set GENPOLICY to your copy if it is named differently."
mkdir -p "$TMP_DIR"

step "1/7 check the cluster and read the identity"
ctx_now="$(kc config current-context 2>/dev/null || true)"
[[ -n "$ctx_now" ]] || die "no kube context (set KUBE_CONTEXT, or select one)"
echo "  kube context: $ctx_now"
# A Cedar policy is mandatory in confidential mode, so the runtime class has to be there
# before anything is created.
kc get runtimeclass confidential-sandbox >/dev/null 2>&1 ||
  die "the confidential-sandbox runtime class is not on this cluster (run the Getting started samples first)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
[[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die "could not read the account ID"
REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
# The profile-level ARN, with no version suffix. The generator's help explains why: "The
# agent presents both profile-level and version-level ARNs in the Cedar context, so
# profile-level ARNs match any version", which is what lets the provider rotate its
# signing certificate without the operator regenerating anything.
SIGNING_PROFILE_ARN="arn:aws:signer:$AWS_REGION:$ACCOUNT_ID:/signing-profiles/$SIGNING_PROFILE"
echo "  account <ACCOUNT_ID>, region $AWS_REGION, cluster $CLUSTER_NAME"
state_put ACCOUNT_ID "$ACCOUNT_ID"
state_put AWS_REGION "$AWS_REGION"
state_put CLUSTER_NAME "$CLUSTER_NAME"
state_put NAMESPACE "$NAMESPACE"
state_put REGISTRY "$REGISTRY"
state_put SIGNING_PROFILE "$SIGNING_PROFILE"
state_put SIGNING_PROFILE_ARN "$SIGNING_PROFILE_ARN"

step "2/7 ensure the AWS Signer signing profile"
# Through lookup(), so that only the documented not-found response means absent. Suppressing
# every failure here would let a denied or misdirected call read as "the name is free", and
# the script would then try to create a profile whose state it never established.
prof_rc=0
profile_status="$(lookup ResourceNotFoundException signer get-signing-profile \
  --profile-name "$SIGNING_PROFILE" --region "$AWS_REGION" \
  --query 'status' --output text)" || prof_rc=$?
stop_if_undetermined "$prof_rc" "the signing profile $SIGNING_PROFILE"
[[ "$prof_rc" == 0 ]] || profile_status=""
if [[ "$profile_status" == "Active" ]]; then
  tag="$(aws signer list-tags-for-resource --resource-arn "$SIGNING_PROFILE_ARN" \
    --region "$AWS_REGION" 2>/dev/null | jq -r '.tags.ManagedBy // empty')"
  require_managed_by "the signing profile $SIGNING_PROFILE" "$tag"
  echo "  reusing signing profile $SIGNING_PROFILE (it carries this sample's tag)"
  state_put SIGNING_PROFILE_CREATED false
elif [[ -n "$profile_status" && "$profile_status" != "None" ]]; then
  # The name exists in some other state, almost always Canceled. AWS Signer keeps a
  # canceled profile until its signatures expire and refuses the name while it is there.
  die "the signing profile $SIGNING_PROFILE already exists with status '$profile_status' and cannot be reused. AWS Signer keeps a canceled profile until its signatures expire, so set a NEW SIGNING_PROFILE in .env and run this again."
else
  aws signer put-signing-profile --profile-name "$SIGNING_PROFILE" \
    --platform-id "$SIGNING_PLATFORM_ID" --region "$AWS_REGION" \
    --tags "ManagedBy=$MANAGED_BY,auto-delete=no" >/dev/null
  echo "  created signing profile $SIGNING_PROFILE ($SIGNING_PLATFORM_ID)"
  state_put SIGNING_PROFILE_CREATED true
fi

step "3/7 ensure the ECR repository"
repo_rc=0
repo_arn="$(lookup RepositoryNotFoundException ecr describe-repositories \
  --repository-names "$ECR_REPOSITORY" --region "$AWS_REGION" \
  --query 'repositories[0].repositoryArn' --output text)" || repo_rc=$?
stop_if_undetermined "$repo_rc" "the ECR repository $ECR_REPOSITORY"
if [[ "$repo_rc" == 0 ]]; then
  # ECR does not return tags on describe-repositories, so ownership needs a second call.
  tag="$(aws ecr list-tags-for-resource --resource-arn "$repo_arn" --region "$AWS_REGION" \
    | jq -r '[.tags[]? | select(.Key=="ManagedBy") | .Value] | first // empty')"
  require_managed_by "the ECR repository $ECR_REPOSITORY" "$tag"
  echo "  reusing ECR repository $ECR_REPOSITORY"
  state_put ECR_CREATED false
else
  aws ecr create-repository --repository-name "$ECR_REPOSITORY" --region "$AWS_REGION" \
    --image-tag-mutability IMMUTABLE \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    --tags "Key=ManagedBy,Value=$MANAGED_BY" Key=auto-delete,Value=no >/dev/null
  echo "  created ECR repository $ECR_REPOSITORY (IMMUTABLE tags)"
  state_put ECR_CREATED true
fi
state_put ECR_REPOSITORY "$ECR_REPOSITORY"

step "4/7 the provider builds, pushes and signs release $RELEASE_ONE"
write_registry_credentials "$REGISTRY"
if ! notation plugin ls 2>/dev/null | grep -q "$SIGNER_PLUGIN_ID"; then
  die "the AWS Signer plugin for Notation is not installed. Install it as the page's prerequisites describe, then run this again."
fi
plugin_version="$(notation plugin ls 2>/dev/null \
  | awk -v id="$SIGNER_PLUGIN_ID" '$1==id {for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}')"
echo "  AWS Signer plugin version: ${plugin_version:-unknown}"
digest_one="$(build_push_sign "$RELEASE_ONE" "$REGISTRY" "$SIGNING_PROFILE_ARN")"
echo "  pushed and signed $ECR_REPOSITORY:$RELEASE_ONE"
echo "  digest: $digest_one"
state_put SIGNER_PLUGIN_VERSION "${plugin_version:-unknown}"
state_put RELEASE_ONE "$RELEASE_ONE"
state_put DIGEST_ONE "$digest_one"

step "5/7 give the pod a role that can only check this profile's revocation status"
# This is the one boundary the sample itself creates and can therefore claim. Signature
# verification runs inside the guest and calls AWS Signer to check whether the profile or
# the certificate has been revoked; it fails closed if either call is refused (Amazon EKS
# User Guide, "Cedar policies"). So the role needs exactly those two read actions and
# nothing else: no ECR, no KMS, no write anywhere.
sed -e "s|<CLUSTER_NAME>|$CLUSTER_NAME|g" -e "s|<NAMESPACE>|$NAMESPACE|g" \
  "$SAMPLE_DIR/iam/pod-identity-trust.json" > "$TMP_DIR/role-trust-policy.json"
role_rc=0
lookup NoSuchEntity iam get-role --role-name "$IAM_ROLE_NAME" --query 'Role.Arn' --output text >/dev/null || role_rc=$?
stop_if_undetermined "$role_rc" "the IAM role $IAM_ROLE_NAME"
if [[ "$role_rc" == 0 ]]; then
  tag="$(aws iam list-role-tags --role-name "$IAM_ROLE_NAME" \
    | jq -r '[.Tags[]? | select(.Key=="ManagedBy") | .Value] | first // empty')"
  require_managed_by "the IAM role $IAM_ROLE_NAME" "$tag"
  # Decide whether this role can be adopted BEFORE changing it. The checks below run again
  # as a post-condition once the sample's own policy is installed, but a role that is going
  # to be refused must be refused before its trust policy is rewritten or anything is
  # granted on it: a refusal is inert, a grant is not.
  attached_now="$(aws iam list-attached-role-policies --role-name "$IAM_ROLE_NAME" --query 'length(AttachedPolicies)' --output text)"
  [[ "$attached_now" == "0" ]] ||
    die "the role $IAM_ROLE_NAME carries $attached_now attached managed policies. This sample's claim is that the pod can do nothing but check revocation status, so remove them or set a new IAM_ROLE_NAME in .env. Changed nothing."
  inline_now="$(aws iam list-role-policies --role-name "$IAM_ROLE_NAME" --query 'PolicyNames' --output json | jq -r 'sort | join(",")')"
  [[ -z "$inline_now" || "$inline_now" == "$SIGNER_POLICY_NAME" ]] ||
    die "the role $IAM_ROLE_NAME carries inline policies this sample did not put there [$inline_now]. Remove them or set a new IAM_ROLE_NAME in .env. Changed nothing."
  aws iam update-assume-role-policy --role-name "$IAM_ROLE_NAME" \
    --policy-document "file://$TMP_DIR/role-trust-policy.json"
  echo "  reusing IAM role $IAM_ROLE_NAME"
  state_put IAM_ROLE_CREATED false
else
  aws iam create-role --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document "file://$TMP_DIR/role-trust-policy.json" \
    --tags "Key=ManagedBy,Value=$MANAGED_BY" Key=auto-delete,Value=no >/dev/null
  echo "  created IAM role $IAM_ROLE_NAME"
  state_put IAM_ROLE_CREATED true
fi
sed -e "s|<AWS_REGION>|$AWS_REGION|g" -e "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" \
  -e "s|<SIGNING_PROFILE>|$SIGNING_PROFILE|g" \
  "$SAMPLE_DIR/iam/signer-verify-policy.json" > "$TMP_DIR/signer-verify-policy.json"
aws iam put-role-policy --role-name "$IAM_ROLE_NAME" \
  --policy-name "$SIGNER_POLICY_NAME" \
  --policy-document "file://$TMP_DIR/signer-verify-policy.json"
# Keep least privilege even on a role that was adopted: it must carry exactly this one
# inline policy and no attached managed policy. An adopted role could otherwise keep a
# pre-existing grant, and the page's claim about what the pod can do would be wrong.
attached="$(aws iam list-attached-role-policies --role-name "$IAM_ROLE_NAME" --query 'length(AttachedPolicies)' --output text)"
[[ "$attached" == "0" ]] ||
  die "the role $IAM_ROLE_NAME carries $attached attached managed policies. This sample's claim is that the pod can do nothing but check revocation status, so remove them or set a new IAM_ROLE_NAME in .env."
inline="$(aws iam list-role-policies --role-name "$IAM_ROLE_NAME" --query 'PolicyNames' --output json | jq -r 'sort | join(",")')"
[[ "$inline" == "$SIGNER_POLICY_NAME" ]] ||
  die "the role $IAM_ROLE_NAME must carry exactly one inline policy ($SIGNER_POLICY_NAME); it carries [$inline]. Remove the others or set a new IAM_ROLE_NAME in .env."
IAM_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$IAM_ROLE_NAME"
state_put IAM_ROLE_NAME "$IAM_ROLE_NAME"
state_put IAM_ROLE_ARN "$IAM_ROLE_ARN"

ensure_namespace
kc apply -f <(sed "s|namespace: signer-policy-sample|namespace: $NAMESPACE|" "$SAMPLE_DIR/deploy/service-account.yaml")
# Not "|| true": a denied, misdirected or throttled call would come back empty and the
# script would create a second association for a service account that may already have one.
# An empty list is a successful call that found nothing, which is different.
assoc_rc=0
assoc="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" --region "$AWS_REGION" \
  --query 'associations[0].associationId' --output text 2>"$TMP_DIR/aws.err")" || assoc_rc=$?
[[ "$assoc_rc" == 0 ]] || {
  cat "$TMP_DIR/aws.err" >&2
  die "could not determine whether a Pod Identity association already exists for $NAMESPACE/$SERVICE_ACCOUNT (the AWS call failed; check the cluster name, Region and permissions). Created no association."
}
if [[ -z "$assoc" || "$assoc" == "None" ]]; then
  assoc="$(aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" \
    --role-arn "$IAM_ROLE_ARN" --region "$AWS_REGION" \
    --query 'association.associationId' --output text)"
  echo "  created the Pod Identity association for $SERVICE_ACCOUNT"
  state_put POD_IDENTITY_CREATED true
else
  # Adopt only an association that already points at this sample's role, so clean.sh can
  # never delete one another owner made for this namespace and service account.
  bound="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --association-id "$assoc" --region "$AWS_REGION" --query 'association.roleArn' --output text)"
  [[ "$bound" == "$IAM_ROLE_ARN" ]] ||
    die "a Pod Identity association for $NAMESPACE/$SERVICE_ACCOUNT already exists and is bound to a different role. Refusing to adopt it."
  echo "  reusing the Pod Identity association for $SERVICE_ACCOUNT"
  state_put POD_IDENTITY_CREATED false
fi
state_put POD_IDENTITY_ASSOCIATION_ID "$assoc"

step "6/7 generate the two policies from the same pod spec"
# Render the pod locally first, with the chosen namespace and the release's tag, so both
# generations read exactly the spec that will be applied. --dry-run=client contacts no
# cluster; --validate=false keeps it from fetching the cluster's OpenAPI schema.
image_uri="$REGISTRY/$ECR_REPOSITORY:$RELEASE_ONE"
kubectl create --dry-run=client --validate=false -o json -f "$SAMPLE_DIR/deploy/pod.yaml" \
  | jq --arg ns "$NAMESPACE" --arg img "$image_uri" --arg region "$AWS_REGION" '
      .metadata.namespace = $ns
      | .spec.containers[0].image = $img
      | .spec.containers[0].env = [ .spec.containers[0].env[]
          | if .value == "<AWS_REGION>" then .value = $region else . end ]
    ' > "$TMP_DIR/pod-input.json"
state_put IMAGE_URI_ONE "$image_uri"

# The signer-based policy: the one the pod runs under, and the one that does not change
# when the provider ships again. --skip-image-ref-container names the container whose
# image_ref constraint is dropped; the generator annotates the policy it writes with its
# own warning that the digest is no longer checked.
#
# Deliberately no --image-architecture: that flag narrows a multi-arch image index to one
# architecture, and the provider's image here is built for one platform, so it is a single
# manifest rather than an index. Passing it makes the generator stop with "user requested
# specific architecture amd64 for a non-index image".
HOME="$GENPOLICY_HOME" "$GENPOLICY" \
  --profile "$PROFILE" --with-pod-identity \
  --require-signatures \
  --require-any-signer "$SIGNING_PROFILE_ARN" \
  --skip-image-ref-container "$CONTAINER_NAME" \
  --output-file-b64 "$TMP_DIR/policy.signer.b64" \
  "$TMP_DIR/pod-input.json" > "$TMP_DIR/genpolicy.signer.log"
decode_policy "$TMP_DIR/policy.signer.b64" "$TMP_DIR/policy.signer.yaml"
grep -q "image_signers" "$TMP_DIR/policy.signer.yaml" ||
  die "the signer policy does not constrain image_signers; it would admit an unsigned image"
grep -q "image_ref ==" "$TMP_DIR/policy.signer.yaml" &&
  die "the signer policy still pins image_ref, so it would refuse the provider's next release and the sample would show nothing"
echo "  signer policy: $TMP_DIR/policy.signer.yaml"

# The digest-pinned policy: the generator's default under the same profile. Nothing runs
# under it now. It is generated here, from this release, because that is what an operator
# who took the default would be holding when the next release arrived.
HOME="$GENPOLICY_HOME" "$GENPOLICY" \
  --profile "$PROFILE" --with-pod-identity \
  --output-file-b64 "$TMP_DIR/policy.pinned.b64" \
  "$TMP_DIR/pod-input.json" > "$TMP_DIR/genpolicy.pinned.log"
decode_policy "$TMP_DIR/policy.pinned.b64" "$TMP_DIR/policy.pinned.yaml"
grep -q "image_ref == \".*@$digest_one\"" "$TMP_DIR/policy.pinned.yaml" ||
  die "the default policy does not pin release $RELEASE_ONE's digest, so the pinned arm would not show a digest pin refusing anything"
echo "  digest-pinned policy: $TMP_DIR/policy.pinned.yaml (pins $digest_one)"

step "7/7 start the pod under the signer policy"
signer_b64="$(tr -d '\r\n' < "$TMP_DIR/policy.signer.b64")"
jq --arg policy "$signer_b64" \
  '.metadata.annotations["sandbox.amazonaws.com/policy"] = $policy' \
  "$TMP_DIR/pod-input.json" > "$TMP_DIR/rendered-pod.json"
# Record the annotation's hash, not the annotation. scripts/new-version.sh checks the
# next release runs under this very string, which is what "no policy change" means.
printf '%s' "$signer_b64" | sha256sum | cut -d' ' -f1 > "$TMP_DIR/policy.signer.sha256"
state_put POLICY_SIGNER_SHA256 "$(cat "$TMP_DIR/policy.signer.sha256")"
# Replace rather than apply over: a pod's policy annotation is immutable, so a pod left
# from an earlier run would keep enforcing the earlier policy.
kc delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
kc apply -f "$TMP_DIR/rendered-pod.json"
if ! wait_for_pod "$POD_NAME" 900; then
  printf '%s\n' "$POD_MESSAGE" | redact
  die "the pod did not become Ready. Its message is above; the full pod is in: kubectl -n $NAMESPACE describe pod $POD_NAME"
fi
state_put POD_NAME "$POD_NAME"

# Read the annotation back off the running pod, rather than trusting the file that was
# applied. This is the baseline scripts/new-version.sh compares the next release against,
# so it has to be what the API server actually holds for the pod that was admitted: a
# mutating webhook, or anything else acting at admission, would otherwise be invisible.
applied_sha="$(kc get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.sandbox\.amazonaws\.com/policy}' \
  | tr -d '\r\n' | sha256sum | cut -d' ' -f1)"
[[ "$applied_sha" == "$(cat "$TMP_DIR/policy.signer.sha256")" ]] ||
  die "the policy annotation on the running pod (sha256 $applied_sha) is not the one this script generated. Something changed it at admission, so the next release would not be compared against the policy that is really enforced."
echo "  the running pod carries the generated policy, sha256 $applied_sha"
state_put POLICY_SIGNER_SHA256_OBSERVED "$applied_sha"

printf '\n%s is Ready on release %s, under a policy that requires this signer.\n' "$POD_NAME" "$RELEASE_ONE"
echo "Read the policy:        less $TMP_DIR/policy.signer.yaml"
echo "Ship the next release:  ./scripts/new-version.sh"
echo "Tear down:              ./scripts/clean.sh"
