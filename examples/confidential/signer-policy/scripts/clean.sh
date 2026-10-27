#!/usr/bin/env bash
# Delete what the sample created, and verify it is gone.
#
#   ./scripts/clean.sh                        the Kubernetes objects and the Pod Identity
#                                             association
#   ./scripts/clean.sh --delete-aws-resources also the ECR repository, the IAM role, and
#                                             CANCEL the AWS Signer signing profile
#
# It deletes only what carries this sample's mark: the namespace label is checked before
# anything inside the namespace is removed, and every AWS resource is checked for its
# ManagedBy tag. A lookup that fails means "could not determine", which is a failure and
# never "gone", so the script says what it could not do and exits non-zero.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

delete_aws=false
case "${1:-}" in
  "") ;;
  --delete-aws-resources) delete_aws=true ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

load_env
require_commands aws kubectl jq
# The run record is how clean.sh knows what this sample made. Without it, fall back to the
# configured names: a reader who lost tmp/ can still tidy up.
[[ -f "$STATE_FILE" ]] && load_state
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGISTRY="${REGISTRY:-$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com}"
SIGNING_PROFILE_ARN="${SIGNING_PROFILE_ARN:-arn:aws:signer:$AWS_REGION:$ACCOUNT_ID:/signing-profiles/$SIGNING_PROFILE}"
IAM_ROLE_ARN="${IAM_ROLE_ARN:-arn:aws:iam::$ACCOUNT_ID:role/$IAM_ROLE_NAME}"

incomplete=()
note_incomplete() { incomplete+=("$1"); echo "  INCOMPLETE: $1" >&2; }

step "1/5 the pods and the namespace"
ns_rc=0
ns_label="$(kc get namespace "$NAMESPACE" --ignore-not-found \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)" || ns_rc=$?
ns_exists="$(kc get namespace "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)" || ns_rc=$?
if [[ "$ns_rc" != 0 ]]; then
  note_incomplete "could not determine whether namespace $NAMESPACE exists (the kubectl lookup failed); deleted nothing in the cluster"
elif [[ -z "$ns_exists" ]]; then
  echo "  namespace $NAMESPACE is already gone"
elif [[ "$ns_label" != "signer-policy-sample" ]]; then
  note_incomplete "namespace $NAMESPACE exists but is not this sample's (managed-by='${ns_label:-unset}'); left it and everything in it alone"
else
  # Each pod by its exact name, never a label selector: a selector meant for this
  # sample's pods has deleted another demo's pod on a shared cluster before.
  for p in "$POD_NAME" "$PINNED_POD_NAME"; do
    kc delete pod "$p" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m >/dev/null
    echo "  deleted pod $p (if it was there)"
  done
  # The namespace carries this sample's label, so everything in it is this sample's:
  # deleting it takes the ServiceAccount with it.
  kc delete namespace "$NAMESPACE" --ignore-not-found --wait=true --timeout=10m >/dev/null
  if [[ -n "$(kc get namespace "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)" ]]; then
    note_incomplete "namespace $NAMESPACE is still present after the delete"
  else
    echo "  deleted namespace $NAMESPACE"
  fi
fi

step "2/5 the Pod Identity association"
assoc_rc=0
assoc="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" --region "$AWS_REGION" \
  --query 'associations[0].associationId' --output text 2>/dev/null)" || assoc_rc=$?
if [[ "$assoc_rc" != 0 ]]; then
  note_incomplete "could not determine whether a Pod Identity association exists for $NAMESPACE/$SERVICE_ACCOUNT"
elif [[ -z "$assoc" || "$assoc" == "None" ]]; then
  echo "  no Pod Identity association for $NAMESPACE/$SERVICE_ACCOUNT"
else
  bound="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --association-id "$assoc" --region "$AWS_REGION" --query 'association.roleArn' --output text 2>/dev/null || true)"
  if [[ "$bound" != "$IAM_ROLE_ARN" ]]; then
    note_incomplete "the Pod Identity association $assoc is bound to $bound, not this sample's role; left it alone"
  else
    aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" \
      --association-id "$assoc" --region "$AWS_REGION" >/dev/null
    echo "  deleted Pod Identity association $assoc"
  fi
fi

if [[ "$delete_aws" != true ]]; then
  step "3/5 AWS resources kept"
  echo "  the ECR repository, the IAM role and the signing profile are still there."
  echo "  Remove them with: ./scripts/clean.sh --delete-aws-resources"
else
  step "3/5 the IAM role"
  role_rc=0
  lookup NoSuchEntity iam get-role --role-name "$IAM_ROLE_NAME" --query 'Role.Arn' --output text >/dev/null || role_rc=$?
  if [[ "$role_rc" == 2 ]]; then
    echo "  IAM role $IAM_ROLE_NAME is already gone"
  elif [[ "$role_rc" != 0 ]]; then
    note_incomplete "could not determine whether IAM role $IAM_ROLE_NAME exists"
  else
    tag="$(aws iam list-role-tags --role-name "$IAM_ROLE_NAME" \
      | jq -r '[.Tags[]? | select(.Key=="ManagedBy") | .Value] | first // empty')"
    if [[ "$tag" != "$MANAGED_BY" ]]; then
      note_incomplete "IAM role $IAM_ROLE_NAME is not this sample's (ManagedBy='${tag:-unset}'); left it alone"
    else
      for p in $(aws iam list-role-policies --role-name "$IAM_ROLE_NAME" --query 'PolicyNames[]' --output text); do
        aws iam delete-role-policy --role-name "$IAM_ROLE_NAME" --policy-name "$p"
      done
      aws iam delete-role --role-name "$IAM_ROLE_NAME"
      echo "  deleted IAM role $IAM_ROLE_NAME"
    fi
  fi

  step "4/5 the ECR repository"
  repo_rc=0
  repo_arn="$(lookup RepositoryNotFoundException ecr describe-repositories \
    --repository-names "$ECR_REPOSITORY" --region "$AWS_REGION" \
    --query 'repositories[0].repositoryArn' --output text)" || repo_rc=$?
  if [[ "$repo_rc" == 2 ]]; then
    echo "  ECR repository $ECR_REPOSITORY is already gone"
  elif [[ "$repo_rc" != 0 ]]; then
    note_incomplete "could not determine whether ECR repository $ECR_REPOSITORY exists"
  else
    tag="$(aws ecr list-tags-for-resource --resource-arn "$repo_arn" --region "$AWS_REGION" \
      | jq -r '[.tags[]? | select(.Key=="ManagedBy") | .Value] | first // empty')"
    if [[ "$tag" != "$MANAGED_BY" ]]; then
      note_incomplete "ECR repository $ECR_REPOSITORY is not this sample's (ManagedBy='${tag:-unset}'); left it alone"
    else
      # --force: the repository holds the two releases and their signatures.
      aws ecr delete-repository --repository-name "$ECR_REPOSITORY" --region "$AWS_REGION" --force >/dev/null
      echo "  deleted ECR repository $ECR_REPOSITORY and the images and signatures in it"
    fi
  fi

  step "5/5 the signing profile"
  # AWS Signer has no hard delete. Canceling retires the profile; it lingers until its
  # signatures expire (about 141 months by default) and the name cannot be reused.
  status="$(aws signer get-signing-profile --profile-name "$SIGNING_PROFILE" \
    --region "$AWS_REGION" --query 'status' --output text 2>/dev/null || true)"
  if [[ -z "$status" || "$status" == "None" ]]; then
    echo "  signing profile $SIGNING_PROFILE is not there"
  elif [[ "$status" == "Canceled" ]]; then
    echo "  signing profile $SIGNING_PROFILE is already Canceled"
  else
    tag="$(aws signer list-tags-for-resource --resource-arn "$SIGNING_PROFILE_ARN" \
      --region "$AWS_REGION" 2>/dev/null | jq -r '.tags.ManagedBy // empty')"
    if [[ "$tag" != "$MANAGED_BY" ]]; then
      note_incomplete "signing profile $SIGNING_PROFILE is not this sample's (ManagedBy='${tag:-unset}'); left it alone"
    else
      aws signer cancel-signing-profile --profile-name "$SIGNING_PROFILE" --region "$AWS_REGION"
      status="$(aws signer get-signing-profile --profile-name "$SIGNING_PROFILE" \
        --region "$AWS_REGION" --query 'status' --output text 2>/dev/null || true)"
      if [[ "$status" == "Canceled" ]]; then
        echo "  canceled signing profile $SIGNING_PROFILE (the name stays taken; set a new SIGNING_PROFILE in .env to run again)"
      else
        note_incomplete "signing profile $SIGNING_PROFILE reads '$status' after the cancel, not 'Canceled'"
      fi
    fi
  fi
fi

echo
if (( ${#incomplete[@]} > 0 )); then
  echo "Clean up INCOMPLETE. ${#incomplete[@]} thing(s) it could not do:" >&2
  printf '  - %s\n' "${incomplete[@]}" >&2
  exit 1
fi
echo "Clean up complete."
[[ "$delete_aws" == true ]] || echo "AWS resources kept; see --delete-aws-resources above."
