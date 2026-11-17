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
require_network_policy_enforcement

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

step "1/7 namespace $NAMESPACE"
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

step "2/7 ECR repository $ECR_REPOSITORY"
# Three outcomes, not two: a read that failed is never taken for "absent", which
# would send the run on to create a repository on top of an answer it never got.
repo_arn=""
repo_rc=0
aws_exists RepositoryNotFoundException -- aws ecr describe-repositories \
  --repository-names "$ECR_REPOSITORY" --region "$AWS_REGION" || repo_rc=$?
[[ $repo_rc -eq 2 ]] && die "could not read ECR repository $ECR_REPOSITORY, so whether it exists could not be determined; stopping rather than create one on a read that never answered: $AWS_LAST_ERROR"
if [[ $repo_rc -eq 0 ]]; then
  # It exists. Reuse it only if it is the sample's; a repository of this name in
  # a shared account may be someone else's.
  repo_arn="$(aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" \
    --region "$AWS_REGION" --query 'repositories[0].repositoryArn' --output text 2>/dev/null)" \
    || die "could not read the ARN of ECR repository $ECR_REPOSITORY"
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

step "3/7 build and push the brain image"
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

step "4/7 the brain's Bedrock role, through EKS Pod Identity"
role_rc=0
aws_exists NoSuchEntity -- aws iam get-role --role-name "$POD_IDENTITY_ROLE_NAME" || role_rc=$?
[[ $role_rc -eq 2 ]] && die "could not read IAM role $POD_IDENTITY_ROLE_NAME, so whether it exists could not be determined; stopping rather than create one on a read that never answered: $AWS_LAST_ERROR"
if [[ $role_rc -eq 0 ]]; then
  role_arn="$(aws iam get-role --role-name "$POD_IDENTITY_ROLE_NAME" \
    --query Role.Arn --output text 2>/dev/null)" \
    || die "could not read the ARN of IAM role $POD_IDENTITY_ROLE_NAME"
  tags="$(aws iam list-role-tags --role-name "$POD_IDENTITY_ROLE_NAME" \
    --query "Tags[?Key=='ManagedBy'].Value" --output text 2>/dev/null)" \
    || die "could not read the tags on IAM role $POD_IDENTITY_ROLE_NAME; stopping rather than change a role I cannot verify is the sample's"
  [[ "$tags" == "$MANAGED_BY" ]] \
    || die "IAM role $POD_IDENTITY_ROLE_NAME exists but is not tagged ManagedBy=$MANAGED_BY (read: '${tags:-<none>}'); it belongs to something else. Set POD_IDENTITY_ROLE_NAME in .env to a free name and re-run."
  # The tag says the role is the sample's. It does not say the role still only
  # carries what the sample put on it: a role from an earlier life, or one
  # someone widened by hand, can keep attached managed policies and other inline
  # policies, and the page describes the only policies this sample attaches.
  # So check that before reusing it, and refuse rather than quietly make the
  # page's claim false for this run.
  attached="$(aws iam list-attached-role-policies --role-name "$POD_IDENTITY_ROLE_NAME" \
    --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null)" \
    || die "could not list the attached policies on IAM role $POD_IDENTITY_ROLE_NAME; stopping rather than reuse a role whose permissions I cannot read"
  [[ -z "$attached" ]] \
    || die "IAM role $POD_IDENTITY_ROLE_NAME is tagged as this sample's but has managed policies attached ($attached). This sample's page describes the only policies it attaches to this role, which would not match what is on it for this run. Remove them, or set POD_IDENTITY_ROLE_NAME in .env to a free name and re-run."
  inline="$(aws iam list-role-policies --role-name "$POD_IDENTITY_ROLE_NAME" \
    --query 'PolicyNames[]' --output text 2>/dev/null)" \
    || die "could not list the inline policies on IAM role $POD_IDENTITY_ROLE_NAME; stopping rather than reuse a role whose permissions I cannot read"
  [[ -z "$inline" || "$inline" == "bedrock-invoke" ]] \
    || die "IAM role $POD_IDENTITY_ROLE_NAME is tagged as this sample's but carries inline policies other than bedrock-invoke ($inline), so the page's account of what is attached to this role would not hold. Remove them, or set POD_IDENTITY_ROLE_NAME in .env to a free name and re-run."
  echo "reusing IAM role $POD_IDENTITY_ROLE_NAME (ManagedBy=$MANAGED_BY, no other policies on it)"
else
  role_arn="$(aws iam create-role --role-name "$POD_IDENTITY_ROLE_NAME" \
    --assume-role-policy-document "file://$SAMPLE_DIR/iam/pod-identity-trust.json" \
    --description "brain-and-hands sample: the brain's Bedrock access" \
    --tags "Key=ManagedBy,Value=$MANAGED_BY" --query Role.Arn --output text)" \
    || die "could not create IAM role $POD_IDENTITY_ROLE_NAME"
  echo "created IAM role $POD_IDENTITY_ROLE_NAME, tagged ManagedBy=$MANAGED_BY"
fi

# Whose role would the brain actually be given? The Pod Identity association is
# what decides that, so read it HERE, before a permission is written or any
# RBAC is applied, rather than at step 5 where it is created. An association
# left over for this namespace and ServiceAccount that names some other role
# would hand the brain permissions this sample never scoped, while the page
# describes the ones it did, and refusing after writing a policy would mean
# refusing with the account already changed.
assoc="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" --namespace "$NAMESPACE" --service-account "$BRAIN" \
  --query 'associations[0].associationId' --output text 2>/dev/null)" \
  || die "could not list the Pod Identity associations on cluster $CLUSTER_NAME"
if [[ -n "$assoc" && "$assoc" != "None" ]]; then
  assoc_role="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" --association-id "$assoc" \
    --query association.roleArn --output text 2>/dev/null)" \
    || die "could not describe the existing Pod Identity association $assoc for $NAMESPACE/$BRAIN; stopping rather than leave the brain holding a role I could not read"
  [[ "$assoc_role" == "$role_arn" ]] \
    || die "a Pod Identity association already exists for $NAMESPACE/$BRAIN ($assoc) and names a different role:
  it names:  $assoc_role
  we expect: $role_arn
The brain's pods would be given that role, not this sample's, so the page's account of what the brain may do in AWS would not hold. Delete that association, or set NAMESPACE in .env to a free name and re-run."
fi

# The one permission the brain gets: invoke the one model it is configured with.
# It is the only role the sample creates, and with no network policy restricting
# the brain it is the only AWS boundary the brain has, so it is scoped to the one
# model rather than to "any model".
#
# A cross-Region inference profile such as us.anthropic.claude-sonnet-5-5 needs
# two resources: the profile itself, which is addressed in your own account, and
# the foundation models it routes to, one per Region behind the profile.
#
# Those model ARNs are read from the profile rather than derived from its ID. A
# derived prefix with a trailing wildcard would also allow any other model whose
# ID starts the same way, which is not what this policy says it allows.
fm_arns="$(aws bedrock get-inference-profile \
  --inference-profile-identifier "$BEDROCK_MODEL_ID" --region "$AWS_REGION" \
  --query 'models[].modelArn' --output json 2>/dev/null | tr -d ' \n')" \
  || die "could not read the inference profile $BEDROCK_MODEL_ID in $AWS_REGION. List what your account has with: aws bedrock list-inference-profiles --region $AWS_REGION --query 'inferenceProfileSummaries[].inferenceProfileId'"
# Fail closed on anything that is not a plain list of Bedrock foundation-model
# ARNs. An empty list would be a policy that grants nothing, and the brain would
# fail its first model call with AccessDenied for a reason nothing here
# explained; anything carrying a sed metacharacter would produce a different
# policy from the one asked for.
[[ "$fm_arns" == '["arn:aws:bedrock:'*'"]' && "$fm_arns" != *'|'* \
   && "$fm_arns" != *'&'* && "$fm_arns" != *'\'* ]] \
  || die "the inference profile $BEDROCK_MODEL_ID did not return a usable list of foundation-model ARNs (got '${fm_arns:-<empty>}'); stopping rather than write a policy that may grant nothing or something else"
bedrock_policy="$(sed -e "s|<AWS_REGION>|$AWS_REGION|g" \
                      -e "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" \
                      -e "s|<BEDROCK_MODEL_ID>|$BEDROCK_MODEL_ID|g" \
                      -e "s|\[\"<FOUNDATION_MODEL_ARNS>\"\]|$fm_arns|" \
                      "$SAMPLE_DIR/iam/bedrock-invoke-policy.json")"
aws iam put-role-policy --role-name "$POD_IDENTITY_ROLE_NAME" --policy-name bedrock-invoke \
  --policy-document "$bedrock_policy" \
  || die "could not put the bedrock-invoke policy on $POD_IDENTITY_ROLE_NAME"
echo "  role: $role_arn"
echo "  permissions: bedrock-invoke, two actions on $BEDROCK_MODEL_ID only"

step "5/7 the brain's identity and RBAC"
sed -e "s|<NAMESPACE>|$NAMESPACE|g" "$SAMPLE_DIR/deploy/rbac.yaml" | kc apply -f -

# The association names a namespace and a ServiceAccount, so it delivers the
# role to the brain's pods in this namespace. Whether one already existed, and
# whether it names this sample's role, was settled in step 4 before any
# permission was written; here it is only created when it was absent.
if [[ -z "$assoc" || "$assoc" == "None" ]]; then
  assoc="$(aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" --namespace "$NAMESPACE" --service-account "$BRAIN" \
    --role-arn "$role_arn" --tags "ManagedBy=$MANAGED_BY" \
    --query association.associationId --output text)" \
    || die "could not create the Pod Identity association"
  echo "  created Pod Identity association $assoc for $NAMESPACE/$BRAIN"
else
  echo "  reusing Pod Identity association $assoc for $NAMESPACE/$BRAIN (checked in step 4: it names this sample's role)"
fi

step "6/7 the sandboxd token"
# sandboxd in the hands refuses every request without this bearer token. The
# token lives only in a Secret the brain mounts; the hands get its SHA-256
# digest on sandboxd's command line. Reused when the Secret is already there,
# so a re-run does not leave warm pods expecting a token nobody holds. The value
# passes through a file and bash builtins only, never a command line.
tok_rc=0
resource_exists kc "secret/$TOKEN_SECRET" || tok_rc=$?
case $tok_rc in
  0) token="$(kc get secret "$TOKEN_SECRET" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)" \
       || die "could not read secret/$TOKEN_SECRET"
     echo "  reusing secret/$TOKEN_SECRET" ;;
  1) tok_dir="$(mktemp -d)"
     trap 'rm -rf "${docker_cfg:-}" "$tok_dir"' EXIT
     # 32 random bytes, base64: printable ASCII with no spaces, as sandboxd and
     # the SDK require.
     head -c 32 /dev/urandom | base64 | tr -d '\n' >"$tok_dir/token"
     chmod 600 "$tok_dir/token"
     kc create secret generic "$TOKEN_SECRET" --from-file=token="$tok_dir/token" >/dev/null \
       || die "could not create secret/$TOKEN_SECRET"
     token="$(<"$tok_dir/token")"
     echo "  created secret/$TOKEN_SECRET" ;;
  2) die "could not read secret/$TOKEN_SECRET, so whether it exists could not be determined; stopping rather than mint a second token" ;;
esac
[[ "$token" =~ ^[A-Za-z0-9+/=]{16,}$ ]] || die "secret/$TOKEN_SECRET does not hold a usable token"
token_sha256="$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)"
unset token
[[ "$token_sha256" =~ ^[0-9a-f]{64}$ ]] || die "could not compute the token's digest"
echo "  sandboxd will require the token whose sha256 is ${token_sha256:0:12}..."

# A warm pool does not replace the pods it already booted when its template
# changes. So a re-run over an existing install is safe only if the template AND
# every hands pod already running sandboxd with this exact digest: a template or
# pod from before sandboxd (no --auth-token-sha256 at all), or from before the
# token Secret was deleted and minted again, would leave pods the brain cannot
# drive while the pool still reports them ready. The digest must be one whole
# argument of the hands container's command, not a substring of the command
# line or an argument of some other container. kubectl prints the command as a
# JSON array, which escapes quotes and newlines inside an element, so an
# unescaped [ or , followed by " is an element boundary: anchoring on those means
# no single argument can smuggle the flag in as part of a longer string.
has_digest() { grep -Eq "(^\[|,)\"--auth-token-sha256=${token_sha256}\"(,|\]\$)" <<<"$1"; }
stale_hint="Run ./scripts/cleanup.sh and then this script again."
pool_rc=0; resource_exists kc "sandboxwarmpool/$POOL" || pool_rc=$?
tpl_rc=0;  resource_exists kc "sandboxtemplate/$TEMPLATE" || tpl_rc=$?
[[ $pool_rc -eq 2 ]] && die "could not read sandboxwarmpool/$POOL, so whether warm pods are already here could not be determined; stopping rather than apply over them"
[[ $tpl_rc -eq 2 ]]  && die "could not read sandboxtemplate/$TEMPLATE, so whether one is already here could not be determined; stopping rather than apply over it"
if [[ $pool_rc -eq 0 || $tpl_rc -eq 0 ]]; then
  [[ $tpl_rc -eq 0 ]] || die "sandboxwarmpool/$POOL exists but sandboxtemplate/$TEMPLATE does not, so what its warm pods were booted from cannot be told. $stale_hint"
  tpl_cmd="$(kc get sandboxtemplate "$TEMPLATE" -o jsonpath='{.spec.podTemplate.spec.containers[?(@.name=="hands")].command}' 2>/dev/null)" \
    || die "could not read sandboxtemplate/$TEMPLATE, so whether its pods expect this token could not be determined; stopping rather than apply over it"
  has_digest "$tpl_cmd" \
    || die "sandboxtemplate/$TEMPLATE already exists and its hands container does not run sandboxd with this token's digest (it is from an earlier version of this sample, or the token Secret was recreated). Its warm pods would not be replaced by applying over it. $stale_hint"
  pods="$(kc get pods -l app=hands -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)" \
    || die "could not list the hands pods, so whether they expect this token could not be determined; stopping rather than apply over them"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    pod_cmd="$(kc get pod "$p" -o jsonpath='{.spec.containers[?(@.name=="hands")].command}' 2>/dev/null)" \
      || die "could not read pod/$p, so whether it expects this token could not be determined; stopping rather than apply over it"
    has_digest "$pod_cmd" \
      || die "pod/$p is running without sandboxd and this token's digest (it was booted from an earlier template). The pool would keep serving it. $stale_hint"
  done <<<"$pods"
  echo "  the existing template and hands pods already expect this token"
fi

step "7/7 the hands, then the brain"
# The hands first: the template and the pool, so a warm pod is on its way
# before the brain that claims it is up.
sed -e "s|<NAMESPACE>|$NAMESPACE|g" \
    -e "s|<SANDBOXD_TOKEN_SHA256>|$token_sha256|g" \
    "$SAMPLE_DIR/deploy/warm-pool.yaml" | kc apply -f -

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
echo "  kubectl -n $NAMESPACE exec deploy/$BRAIN -- claude -p 'Create a sandbox, print its kernel, and tell me whether you can reach the internet from it.'"
echo "Tear it down:   ./scripts/cleanup.sh"
