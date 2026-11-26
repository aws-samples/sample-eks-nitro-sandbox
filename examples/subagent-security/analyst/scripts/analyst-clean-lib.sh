#!/usr/bin/env bash
# analyst-clean-lib.sh -- the AWS half of a Subagent security sample's clean up: delete the
# IAM role, the S3 bucket and the ECR repositories the sample's setup created, each only when
# it is provably the sample's, and say what could not be done.
#
# Source it, do not run it, after analyst-lib.sh, which supplies `lookup`. It is a separate
# file because analyst-lib.sh is the setup half and says nothing in it deletes anything.
#
# The caller must define, before calling any of these:
#   SAMPLE        the sample's name, which is also its ManagedBy tag value
#   AWS_REGION    the Region of the run
#   note_fail     a function that records an incomplete clean up (and makes the script exit
#                 non-zero at the end)
#
# Every function follows the rule the clean up scripts share. A lookup that fails means
# "could not determine", which is a failure and never "already gone". A resource without this
# sample's ManagedBy tag is left alone and reported. After each delete the resource is looked
# up again, and only the service's own not-found answer counts as deleted.

# analyst_clean_role <role name> <the one inline policy the sample puts on it>
#
# The tag says the role is this sample's; it does not say the role still carries only what
# the sample granted. A role with another inline policy, or any managed policy attached, is
# left in place: deleting it would take someone else's grant with it.
analyst_clean_role() {
  local role="$1" policy="$2" got inline attached tag rc
  if [[ -z "$role" ]]; then
    note_fail "no IAM role name in the run record or .env, so the role could not be removed"
    return
  fi
  got="$(lookup NoSuchEntity iam get-role --role-name "$role" --output json)"; rc=$?
  if [[ "$rc" == 1 ]]; then
    echo "  the IAM role $role is already gone."
    return
  elif [[ "$rc" != 0 ]]; then
    note_fail "could not determine whether the IAM role $role exists; left it alone"
    return
  fi
  tag="$(jq -r '.Role.Tags[]? | select(.Key=="ManagedBy") | .Value' <<<"$got")"
  if [[ "$tag" != "$SAMPLE" ]]; then
    note_fail "the IAM role $role does not carry ManagedBy=$SAMPLE (found '$tag'); left it alone"
    return
  fi
  # Each list call has to succeed AND answer with the shape the check below reads. An answer
  # that is not JSON, or has no PolicyNames, makes jq print nothing, and nothing reads as "no
  # other policy": the role would then be deleted on a read that never worked.
  if ! inline="$(aws iam list-role-policies --role-name "$role" --output json 2>/dev/null)" ||
     ! attached="$(aws iam list-attached-role-policies --role-name "$role" --output json 2>/dev/null)" ||
     ! jq -e '.PolicyNames | type == "array"' <<<"$inline" >/dev/null 2>&1 ||
     ! jq -e '.AttachedPolicies | type == "array"' <<<"$attached" >/dev/null 2>&1; then
    note_fail "could not list the policies on the IAM role $role; left it in place"
    return
  elif [[ -n "$(jq -r --arg p "$policy" '.PolicyNames[] | select(. != $p)' <<<"$inline")" ||
          "$(jq '.AttachedPolicies | length' <<<"$attached")" != 0 ]]; then
    note_fail "the IAM role $role carries a policy this sample did not create; left it in place"
    return
  fi
  if [[ "$(jq -r --arg p "$policy" '.PolicyNames | index($p)' <<<"$inline")" != "null" ]]; then
    aws iam delete-role-policy --role-name "$role" --policy-name "$policy" >/dev/null 2>&1 ||
      note_fail "could not delete the inline $policy policy on $role"
  fi
  aws iam delete-role --role-name "$role" >/dev/null 2>&1 ||
    note_fail "could not delete the IAM role $role"
  lookup NoSuchEntity iam get-role --role-name "$role" --output json >/dev/null 2>&1; rc=$?
  case "$rc" in
    1) echo "  deleted the IAM role $role." ;;
    0) note_fail "the IAM role $role is still present after the delete" ;;
    *) note_fail "could not confirm the IAM role $role was deleted" ;;
  esac
}

# analyst_clean_bucket <bucket name>
analyst_clean_bucket() {
  local bucket="$1" tags tag rc
  if [[ -z "$bucket" ]]; then
    note_fail "no bucket name in the run record or .env, so the bucket could not be removed"
    return
  fi
  tags="$(lookup NoSuchBucket s3api get-bucket-tagging --bucket "$bucket" --output json)"; rc=$?
  if [[ "$rc" == 1 ]]; then
    echo "  the bucket $bucket is already gone."
    return
  elif [[ "$rc" != 0 ]]; then
    note_fail "could not determine whether the bucket $bucket exists; left it alone"
    return
  fi
  tag="$(jq -r '.TagSet[]? | select(.Key=="ManagedBy") | .Value' <<<"$tags")"
  if [[ "$tag" != "$SAMPLE" ]]; then
    note_fail "the bucket $bucket does not carry ManagedBy=$SAMPLE (found '$tag'); left it alone"
    return
  fi
  aws s3 rm "s3://$bucket" --recursive --region "$AWS_REGION" >/dev/null 2>&1 ||
    note_fail "could not empty the bucket $bucket"
  aws s3api delete-bucket --bucket "$bucket" >/dev/null 2>&1 ||
    note_fail "could not delete the bucket $bucket"
  lookup NoSuchBucket s3api get-bucket-tagging --bucket "$bucket" --output json \
    >/dev/null 2>&1; rc=$?
  case "$rc" in
    1) echo "  deleted the bucket $bucket, with this sample's reports in it." ;;
    0) note_fail "the bucket $bucket is still present after the delete" ;;
    *) note_fail "could not confirm the bucket $bucket was deleted" ;;
  esac
}

# analyst_clean_repository <NAME OF the run-record variable that holds the repository name>
#
# Named rather than passed by value, so a record missing one of them is reported instead of
# quietly skipped: an empty name used to be skipped, and left the repository in the account
# with the clean up still exiting 0.
analyst_clean_repository() {
  local var="$1" repo got arn tags rc
  repo="${!var:-}"
  if [[ -z "$repo" ]]; then
    note_fail "the run record names no $var, so that ECR repository could not be found or removed"
    return
  fi
  got="$(lookup RepositoryNotFoundException ecr describe-repositories \
    --repository-names "$repo" --output json)"; rc=$?
  if [[ "$rc" == 1 ]]; then
    echo "  the ECR repository $repo is already gone."
    return
  elif [[ "$rc" != 0 ]]; then
    note_fail "could not determine whether the ECR repository $repo exists; left it alone"
    return
  fi
  arn="$(jq -r '.repositories[0].repositoryArn' <<<"$got")"
  if ! tags="$(aws ecr list-tags-for-resource --resource-arn "$arn" --output json 2>/dev/null)" ||
     ! jq -e '.tags | type == "array"' <<<"$tags" >/dev/null 2>&1; then
    note_fail "could not read the tags on the ECR repository $repo; left it alone"
    return
  elif [[ "$(jq -r '.tags[]? | select(.Key=="ManagedBy") | .Value' <<<"$tags")" != "$SAMPLE" ]]; then
    note_fail "the ECR repository $repo does not carry ManagedBy=$SAMPLE; left it alone"
    return
  fi
  aws ecr delete-repository --repository-name "$repo" --force >/dev/null 2>&1 ||
    note_fail "could not delete the ECR repository $repo"
  lookup RepositoryNotFoundException ecr describe-repositories \
    --repository-names "$repo" --output json >/dev/null 2>&1; rc=$?
  case "$rc" in
    1) echo "  deleted the ECR repository $repo." ;;
    0) note_fail "the ECR repository $repo is still present after the delete" ;;
    *) note_fail "could not confirm the ECR repository $repo was deleted" ;;
  esac
}
