#!/usr/bin/env bash
# Delete everything the sample created, and only that.
#
#   ./scripts/cleanup.sh
#
# ORDER MATTERS:
#   1. the brain          -- so nothing claims another pod while this runs.
#   2. the session claim  -- it holds a warm pod; deleting it releases the pod.
#   3. the warm pool      -- a pool boots a replacement for every pod that goes,
#                            so removing it stops the loop; then wait for its
#                            pods to actually terminate.
#   4. the template       -- the pool references it, so it goes after the pool.
#   5. the brain's RBAC and ServiceAccount.
#   6. the AWS resources  -- the Pod Identity association first, because the
#                            role it names goes next, then the ECR repository.
#   7. the namespace      -- last.
#
# WHAT STAYS: the agent-sandbox controller is a shared install, and another
# workload on the cluster may rely on it, so this never removes it. The page
# says what stays and how to remove it.
#
# The namespace label is the mark inside the cluster, and the ManagedBy tag is
# the mark in AWS: this deletes a repository or a role only when it carries the
# tag, and nothing inside the namespace unless the namespace carries the label.
# A read that fails means "could not determine", which is a failure, never
# "gone" and never "not ours". The script exits non-zero when it skipped
# something or could not confirm a delete. Safe to run at any time, including
# when nothing was set up.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

# One failed delete must not stop the ones after it; track failures and own the
# exit code at the end.
set +e

require_commands kubectl aws grep sed tr seq
show_context

failures=0
note_fail() { echo "  INCOMPLETE: $*" >&2; failures=$((failures + 1)); }

# del <kind> <name...> : delete objects in the sample's namespace, by exact
# name, reporting a failed read as a failure rather than as "gone". Only called
# once the namespace has been confirmed the sample's.
del() {
  local kind=$1; shift
  local name rc
  for name in "$@"; do
    rc=0; resource_exists kc "$kind/$name" || rc=$?
    case $rc in
      0) kc delete "$kind" "$name" --wait=true --timeout=180s \
           || note_fail "$kind/$name did not delete cleanly" ;;
      1) echo "  $kind/$name not present" ;;
      2) note_fail "could not read $kind/$name; not reporting it gone" ;;
    esac
  done
}

# The namespace must be the sample's before anything inside it, or any AWS
# resource scoped to it, is touched. A read that fails is a failure.
ns_absent=0
namespace_is_ours
ns_rc=$?
case $ns_rc in
  0) : ;;
  1) die "namespace $NAMESPACE exists but is not the sample's ($NS_LABEL_KEY=$NS_LABEL_VAL); refusing to touch it or the Pod Identity association scoped to it" ;;
  2) die "could not read namespace $NAMESPACE; refusing to delete anything (a failed read is not 'gone')" ;;
  3) ns_absent=1; echo "namespace $NAMESPACE does not exist; nothing of this sample's is left in the cluster." ;;
esac

if [[ $ns_absent -eq 0 ]]; then
  step "1/9 delete the brain"
  del deployment "$BRAIN"

  step "2/9 delete the session claim so its warm pod is released"
  # By exact name: the brain's sandbox tool only ever creates this one claim,
  # named from HANDS_CLAIM in deploy/brain.yaml.
  del sandboxclaim "$SESSION_CLAIM"

  step "3/9 delete the warm pool so it stops booting replacements"
  del sandboxwarmpool "$POOL"
  echo "  waiting for the pool's sandboxes to terminate"
  # Take the list and kubectl's status BEFORE filtering. Piping a failed list
  # straight into grep produces no output, which would read as "the sandboxes
  # are gone" and then let the namespace be deleted on a lookup that never
  # answered.
  leftover=""; sb_gone=""; sb_unreadable=""
  for _ in $(seq 1 60); do   # 60 * 5s = 5m
    sb_rc=0
    sb_list="$(kc get sandboxes -o name 2>/dev/null)" || sb_rc=$?
    if [[ $sb_rc -ne 0 ]]; then
      sb_unreadable=1; leftover=""
      echo "    could not list sandboxes; retrying"
    else
      sb_unreadable=""
      leftover="$(printf '%s' "$sb_list" | sed 's|.*/||' | grep -E "^${POOL}-" | tr '\n' ' ')"
      [[ -z "$leftover" ]] && { sb_gone=1; break; }
      echo "    still terminating: $leftover"
    fi
    sleep 5
  done
  if [[ -n "$sb_gone" ]]; then
    echo "    the pool's sandboxes are gone"
  elif [[ -n "$sb_unreadable" ]]; then
    note_fail "could not list the sandboxes in $NAMESPACE, so whether the pool's sandboxes are gone is unknown (a failed read is not 'gone')"
  else
    note_fail "these sandboxes of the pool are still present after 5m: $leftover"
  fi

  step "4/9 delete the SandboxTemplate"
  del sandboxtemplate "$TEMPLATE"

  step "5/9 delete the brain's RBAC and ServiceAccount"
  del rolebinding "$BRAIN"
  del role "$BRAIN"
  del serviceaccount "$BRAIN"
fi

step "6/9 delete the Pod Identity association"
# Scoped to this namespace and this ServiceAccount, and the namespace has either
# been confirmed the sample's or is already gone, so an association found here
# is the sample's.
assoc_rc=0
assoc="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" --namespace "$NAMESPACE" --service-account "$BRAIN" \
  --query 'associations[0].associationId' --output text 2>/dev/null)" || assoc_rc=$?
if [[ -z "$CLUSTER_NAME" ]]; then
  note_fail "CLUSTER_NAME is not set, so the Pod Identity association could not be looked up; set it in .env and re-run"
elif [[ $assoc_rc -ne 0 ]]; then
  note_fail "could not list the Pod Identity associations on cluster $CLUSTER_NAME, so whether this sample's is gone is unknown"
elif [[ -z "$assoc" || "$assoc" == "None" ]]; then
  echo "  no Pod Identity association for $NAMESPACE/$BRAIN"
else
  aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" --association-id "$assoc" >/dev/null 2>&1
  aws_verify_absent "Pod Identity association $assoc" ResourceNotFoundException -- \
    aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" --association-id "$assoc" \
    || failures=$((failures + 1))
fi

step "7/9 delete the IAM role $POD_IDENTITY_ROLE_NAME"
if aws iam get-role --role-name "$POD_IDENTITY_ROLE_NAME" >/dev/null 2>&1; then
  tags_rc=0
  tags="$(aws iam list-role-tags --role-name "$POD_IDENTITY_ROLE_NAME" \
    --query "Tags[?Key=='ManagedBy'].Value" --output text 2>/dev/null)" || tags_rc=$?
  if [[ $tags_rc -ne 0 ]]; then
    note_fail "could not read the tags on IAM role $POD_IDENTITY_ROLE_NAME; not deleting a role I cannot verify is the sample's"
  elif [[ "$tags" != "$MANAGED_BY" ]]; then
    note_fail "IAM role $POD_IDENTITY_ROLE_NAME is not tagged ManagedBy=$MANAGED_BY (read: '${tags:-<none>}'); it belongs to something else, so it was left alone and this clean up is incomplete"
  else
    aws iam delete-role-policy --role-name "$POD_IDENTITY_ROLE_NAME" \
      --policy-name bedrock-invoke >/dev/null 2>&1
    aws iam delete-role --role-name "$POD_IDENTITY_ROLE_NAME" >/dev/null 2>&1
    aws_verify_absent "IAM role $POD_IDENTITY_ROLE_NAME" NoSuchEntity -- \
      aws iam get-role --role-name "$POD_IDENTITY_ROLE_NAME" \
      || failures=$((failures + 1))
  fi
else
  echo "  IAM role $POD_IDENTITY_ROLE_NAME not present"
fi

step "8/9 delete the ECR repository $ECR_REPOSITORY"
repo_arn_rc=0
repo_arn="$(aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" \
  --region "$AWS_REGION" --query 'repositories[0].repositoryArn' --output text 2>/dev/null)" \
  || repo_arn_rc=$?
if [[ $repo_arn_rc -ne 0 ]]; then
  echo "  ECR repository $ECR_REPOSITORY not present"
else
  tags_rc=0
  tags="$(aws ecr list-tags-for-resource --resource-arn "$repo_arn" --region "$AWS_REGION" \
    --query "tags[?Key=='ManagedBy'].Value" --output text 2>/dev/null)" || tags_rc=$?
  if [[ $tags_rc -ne 0 ]]; then
    note_fail "could not read the tags on ECR repository $ECR_REPOSITORY; not deleting a repository I cannot verify is the sample's"
  elif [[ "$tags" != "$MANAGED_BY" ]]; then
    note_fail "ECR repository $ECR_REPOSITORY is not tagged ManagedBy=$MANAGED_BY (read: '${tags:-<none>}'); it belongs to something else, so it was left alone and this clean up is incomplete"
  else
    aws ecr delete-repository --repository-name "$ECR_REPOSITORY" --region "$AWS_REGION" \
      --force >/dev/null 2>&1
    aws_verify_absent "ECR repository $ECR_REPOSITORY" RepositoryNotFoundException -- \
      aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" --region "$AWS_REGION" \
      || failures=$((failures + 1))
  fi
fi

step "9/9 delete namespace $NAMESPACE"
# Only when everything above succeeded. If a delete failed or a read could not
# be confirmed, something may still be in the namespace, and deleting it would
# hide an incomplete clean up.
if [[ $ns_absent -eq 1 ]]; then
  echo "  namespace $NAMESPACE not present"
elif [[ $failures -ne 0 ]]; then
  echo "  SKIPPED: not deleting namespace $NAMESPACE while $failures item(s) above are unconfirmed; resolve them first." >&2
elif kc_cluster delete namespace "$NAMESPACE" --wait=true --timeout=300s; then
  echo "  namespace $NAMESPACE deleted"
else
  note_fail "namespace $NAMESPACE did not delete cleanly"
fi

echo
echo "The agent-sandbox controller is left as it is: it is a shared install, and"
echo "another workload on the cluster may rely on it."
echo "A local copy of the brain image may still be on your machine: docker image ls"

echo
if [[ $failures -ne 0 ]]; then
  echo "clean up INCOMPLETE: $failures item(s) could not be removed or confirmed (see above)." >&2
  echo "Check with: kubectl get sandboxwarmpool,sandboxclaim,sandbox,deploy -n $NAMESPACE" >&2
  echo "        and kubectl get ns $NAMESPACE" >&2
  exit 1
fi
if [[ $ns_absent -eq 1 ]]; then
  echo "clean up complete: nothing of this sample's was in the cluster."
else
  echo "clean up complete: the brain, the claim, the pool, the template, the RBAC,"
  echo "the Pod Identity association, the IAM role, the ECR repository and the namespace are gone."
fi
