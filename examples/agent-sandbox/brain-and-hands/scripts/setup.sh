#!/usr/bin/env bash
# Stand up the sample: the brain image, the brain's Bedrock role, and the
# cluster objects for both halves.
#
#   ./scripts/setup.sh
#
# It checks the two shared installs it needs before it creates anything, so a
# missing prerequisite stops the run clean with no leftovers. It never installs,
# upgrades or reconfigures either of them: the runtime class and the
# agent-sandbox controller belong to the cluster, and another workload may
# depend on what is there.
#
# In AWS it reuses only a repository or role that carries the sample's ManagedBy
# tag, and stops when it finds one of those names belonging to something else.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

require_commands kubectl aws docker sed grep sort tr find cut seq sha256sum mktemp
show_context

# Whitespace counts as unset: a blank line in .env leaves CLUSTER_NAME looking
# set, and every aws eks call below would then run against an empty cluster name
# and fail further in, after objects had been created.
[[ "$CLUSTER_NAME" =~ [^[:space:]] ]] \
  || die "set CLUSTER_NAME in .env (cp .env.example .env) to the EKS cluster this runs on; the Pod Identity association is created on it"

# --- the shared installs -----------------------------------------------------
require_runtime_class
require_agent_sandbox

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || die "could not read the AWS account; check your credentials"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# --- the image tag ----------------------------------------------------------
# Derived from the Dockerfile and every file under brain/, so a change to either
# produces a new tag and the push below cannot serve a stale image. find picks
# up dotfiles such as brain/.mcp.json, which a `brain/*` glob would miss.
mapfile -t brain_files < <(cd "$SAMPLE_DIR" && find brain -type f | sort)
((${#brain_files[@]} > 0)) || die "no files under $SAMPLE_DIR/brain; cannot derive an image tag"
# The tag only reproduces the image if every file the Dockerfile copies in is in
# that set. Assert it, so a later COPY from somewhere else cannot leave the tag
# unchanged while the image content moves.
while read -r _kw _src _rest; do
  [[ "$_src" == brain/* ]] \
    || die "Dockerfile COPY source '$_src' is not under brain/, so it is not in the hashed set and the image tag would not change when it does; move it under brain/ or extend the tag input"
done < <(grep -E '^COPY[[:space:]]' "$SAMPLE_DIR/Dockerfile")
IMAGE_TAG="${IMAGE_TAG:-$( cd "$SAMPLE_DIR" && cat Dockerfile "${brain_files[@]}" \
  | sha256sum | cut -c1-16 )}"
BRAIN_IMAGE="${REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"

step "1/6 namespace $NAMESPACE"
# Create the namespace only when it is absent, and label it so the other scripts
# can tell it is the sample's. Applying over an existing namespace counts as
# reusing it, which would put our label on a namespace another demo owns.
ns_rc=0
namespace_is_ours || ns_rc=$?
case $ns_rc in
  0) echo "namespace $NAMESPACE already exists and is the sample's; reusing it" ;;
  1) die "namespace $NAMESPACE exists but is not labelled $NS_LABEL_KEY=$NS_LABEL_VAL; it belongs to something else. Set NAMESPACE in .env to a free name and re-run." ;;
  2) die "could not read the labels on namespace $NAMESPACE; stopping rather than guess" ;;
  3) kc_cluster create namespace "$NAMESPACE"
     # The label is the only thing that marks the namespace as the sample's, so
     # a namespace created without it is one every script here, including the
     # clean up, will refuse from then on. If the label does not take, remove
     # the namespace this command just made.
     if ! kc_cluster label namespace "$NAMESPACE" "$NS_LABEL_KEY=$NS_LABEL_VAL"; then
       echo "could not label namespace $NAMESPACE; deleting the namespace this run just created" >&2
       kc_cluster delete namespace "$NAMESPACE" --wait=true --timeout=120s >&2 \
         || echo "could not delete namespace $NAMESPACE either; remove it by hand: kubectl delete namespace $NAMESPACE" >&2
       die "namespace $NAMESPACE could not be labelled $NS_LABEL_KEY=$NS_LABEL_VAL, so nothing was created"
     fi
     echo "created namespace $NAMESPACE, labelled $NS_LABEL_KEY=$NS_LABEL_VAL" ;;
esac

step "2/6 ECR repository $ECR_REPOSITORY"
repo_arn=""
if repo_arn="$(aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" \
      --region "$AWS_REGION" --query 'repositories[0].repositoryArn' --output text 2>/dev/null)"; then
  # It exists. Reuse it only if it is the sample's; a repository of this name in
  # a shared account may be someone else's.
  tags="$(aws ecr list-tags-for-resource --resource-arn "$repo_arn" \
    --region "$AWS_REGION" --query "tags[?Key=='ManagedBy'].Value" --output text 2>/dev/null)" \
    || die "could not read the tags on ECR repository $ECR_REPOSITORY; stopping rather than push into a repository I cannot verify is the sample's"
  [[ "$tags" == "$MANAGED_BY" ]] \
    || die "ECR repository $ECR_REPOSITORY exists but is not tagged ManagedBy=$MANAGED_BY (read: '${tags:-<none>}'); it belongs to something else. Set ECR_REPOSITORY in .env to a free name and re-run."
  echo "reusing ECR repository $ECR_REPOSITORY (ManagedBy=$MANAGED_BY)"
else
  aws ecr create-repository --repository-name "$ECR_REPOSITORY" --region "$AWS_REGION" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    --tags "Key=ManagedBy,Value=$MANAGED_BY" >/dev/null \
    || die "could not create ECR repository $ECR_REPOSITORY"
  echo "created ECR repository $ECR_REPOSITORY, tagged ManagedBy=$MANAGED_BY"
fi

step "3/6 build and push the brain image"
echo "  $BRAIN_IMAGE"
if aws ecr describe-images --repository-name "$ECR_REPOSITORY" --region "$AWS_REGION" \
     --image-ids "imageTag=$IMAGE_TAG" >/dev/null 2>&1; then
  echo "  already pushed; skipping the build"
else
  docker_cfg="$(mktemp -d)"
  trap 'rm -rf "$docker_cfg"' EXIT
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker --config "$docker_cfg" login --username AWS --password-stdin "$REGISTRY" >/dev/null \
    || die "could not log in to $REGISTRY"
  docker build --platform linux/amd64 --file "$SAMPLE_DIR/Dockerfile" \
    --tag "$BRAIN_IMAGE" "$SAMPLE_DIR" || die "the image build failed"
  docker --config "$docker_cfg" push "$BRAIN_IMAGE" || die "the image push failed"
fi

step "4/6 the brain's Bedrock role, through EKS Pod Identity"
if role_arn="$(aws iam get-role --role-name "$POD_IDENTITY_ROLE_NAME" \
      --query Role.Arn --output text 2>/dev/null)"; then
  tags="$(aws iam list-role-tags --role-name "$POD_IDENTITY_ROLE_NAME" \
    --query "Tags[?Key=='ManagedBy'].Value" --output text 2>/dev/null)" \
    || die "could not read the tags on IAM role $POD_IDENTITY_ROLE_NAME; stopping rather than change a role I cannot verify is the sample's"
  [[ "$tags" == "$MANAGED_BY" ]] \
    || die "IAM role $POD_IDENTITY_ROLE_NAME exists but is not tagged ManagedBy=$MANAGED_BY (read: '${tags:-<none>}'); it belongs to something else. Set POD_IDENTITY_ROLE_NAME in .env to a free name and re-run."
  echo "reusing IAM role $POD_IDENTITY_ROLE_NAME (ManagedBy=$MANAGED_BY)"
else
  role_arn="$(aws iam create-role --role-name "$POD_IDENTITY_ROLE_NAME" \
    --assume-role-policy-document "file://$SAMPLE_DIR/iam/pod-identity-trust.json" \
    --description "brain-and-hands sample: the brain's Bedrock access" \
    --tags "Key=ManagedBy,Value=$MANAGED_BY" --query Role.Arn --output text)" \
    || die "could not create IAM role $POD_IDENTITY_ROLE_NAME"
  echo "created IAM role $POD_IDENTITY_ROLE_NAME, tagged ManagedBy=$MANAGED_BY"
fi
# The one permission the brain gets: invoke a model. Nothing else, in AWS,
# belongs to the brain.
aws iam put-role-policy --role-name "$POD_IDENTITY_ROLE_NAME" --policy-name bedrock-invoke \
  --policy-document "file://$SAMPLE_DIR/iam/bedrock-invoke-policy.json" \
  || die "could not put the bedrock-invoke policy on $POD_IDENTITY_ROLE_NAME"
echo "  role: $role_arn"
echo "  permissions: bedrock-invoke (InvokeModel and InvokeModelWithResponseStream, nothing else)"

step "5/6 the brain's identity and RBAC"
sed -e "s|<NAMESPACE>|$NAMESPACE|g" "$SAMPLE_DIR/deploy/rbac.yaml" | kc apply -f -

# The association binds the role to this namespace and this ServiceAccount, so
# the credential is only delivered to the brain's own pods.
assoc="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" --namespace "$NAMESPACE" --service-account "$BRAIN" \
  --query 'associations[0].associationId' --output text 2>/dev/null)" \
  || die "could not list the Pod Identity associations on cluster $CLUSTER_NAME"
if [[ -z "$assoc" || "$assoc" == "None" ]]; then
  assoc="$(aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" --namespace "$NAMESPACE" --service-account "$BRAIN" \
    --role-arn "$role_arn" --tags "ManagedBy=$MANAGED_BY" \
    --query association.associationId --output text)" \
    || die "could not create the Pod Identity association"
  echo "  created Pod Identity association $assoc for $NAMESPACE/$BRAIN"
else
  echo "  reusing Pod Identity association $assoc for $NAMESPACE/$BRAIN"
fi

step "6/6 the hands, then the brain"
# The hands first: the template and the pool, so a warm pod is on its way
# before the brain that claims it is up.
sed -e "s|<NAMESPACE>|$NAMESPACE|g" "$SAMPLE_DIR/deploy/warm-pool.yaml" | kc apply -f -

sed -e "s|<NAMESPACE>|$NAMESPACE|g" \
    -e "s|<BRAIN_IMAGE>|$BRAIN_IMAGE|g" \
    -e "s|<AWS_REGION>|$AWS_REGION|g" \
    -e "s|<BEDROCK_MODEL_ID>|$BEDROCK_MODEL_ID|g" \
    "$SAMPLE_DIR/deploy/brain.yaml" | kc apply -f -
kc rollout status "deploy/$BRAIN" --timeout=5m \
  || die "the brain never became ready; check 'kubectl -n $NAMESPACE describe deploy/$BRAIN'"
echo "  waiting for the pool to boot its warm pod (the first sandboxed pod on a cold cluster waits for a sandbox-capable node)"
wait_pool_warm 900 \
  || die "the warm pool never became ready; check 'kubectl -n $NAMESPACE describe sandboxwarmpool $POOL' and 'kubectl -n $NAMESPACE get pods'"

kc get sandboxwarmpool "$POOL"
kc get deploy "$BRAIN"
echo
echo "the brain is up with a warm pod waiting. Drive it:"
echo "  kubectl -n $NAMESPACE exec deploy/$BRAIN -- claude -p 'Claim a sandbox, print its kernel, and tell me whether you can reach the internet from it.'"
echo "Tear it down:   ./scripts/cleanup.sh"
