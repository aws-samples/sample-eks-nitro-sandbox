#!/usr/bin/env bash
# Remove this sample's recorded resources. Keep local receipts for inspection.
# Usage: ./scripts/clean.sh [--delete-aws]
# Without --delete-aws, keep the bucket, IAM role, and ECR repositories.
set -uo pipefail
source "$(dirname "$0")/common.sh"
delete_aws=false
for arg in "$@"; do
  case "$arg" in
    --delete-aws) delete_aws=true ;;
    --help|-h) sed -n '2,4p' "$0"; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done
failed=0
note_fail() { echo "INCOMPLETE: $*" >&2; failed=1; }
# Only a parsed exception for this exact read operation confirms absence.
# Keep lookup diagnostics, including failures, with the other local run records.
box_cleanup_lookup() {
  local notfound="$1" operation directory rc=0; shift
  case "$1 $2:$notfound" in
    "s3api get-bucket-tagging:NoSuchBucket") operation=GetBucketTagging ;;
    "iam get-role:NoSuchEntity") operation=GetRole ;;
    "ecr describe-repositories:RepositoryNotFoundException") operation=DescribeRepositories ;;
    *) echo "ERROR: unsupported cleanup absence lookup" >&2; return 2 ;;
  esac
  directory="$(mktemp -d "$TMP_DIR/lookups/cleanup.XXXXXX")" || return 2
  aws "$@" >"$directory/stdout" 2>"$directory/stderr" || rc=$?
  if [[ "$rc" == 0 ]]; then
    cat "$directory/stdout" || return 2
    return 0
  fi
  if [[ -f "$directory/stdout" && ! -s "$directory/stdout" ]] &&
      python3 - "$directory/stderr" "$notfound" "$operation" <<'EXCEPTION'
from pathlib import Path
import re
import sys
# Multiple diagnostics, a local CLI failure, or an unfamiliar format stays unknown.
message = Path(sys.argv[1]).read_text(errors="replace").strip()
match = re.fullmatch(r"(?:aws: \[ERROR\]: )?An error occurred \(([^()\r\n]+)\) when calling the ([A-Za-z0-9]+) operation: [^\r\n]*", message)
sys.exit(0 if match and match.groups() == tuple(sys.argv[2:]) else 1)
EXCEPTION
  then
    return 1
  fi
  echo "ERROR: cleanup read failed (exit $rc); absence is unconfirmed. Diagnostics: $directory" >&2
  sed 's/^/  /' "$directory/stderr" >&2
  return 2
}
confirm_absent() {
  local description="$1" rc=0; shift
  box_cleanup_lookup "$@" >/dev/null || rc=$?
  case "$rc" in
    1) echo "  removed $description" ;;
    0) note_fail "$description is still present" ;;
    *) note_fail "could not confirm removal of $description" ;;
  esac
}
# State loading validates the target-derived owner and ECR names before any deletion.
box_load_env
box_load_state
box_check_target
ns_state="$(box_namespace_state)" || die "namespace ownership is unknown or foreign; deleted nothing"
if [[ "$ns_state" == owned ]]; then
  for pod in analyst ordinary-control; do
    kc delete pod "$pod" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m ||
      note_fail "could not remove pod $pod"
  done
  kc delete deployment supplier-api -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m ||
    note_fail "could not remove the supplier API"
  kc delete namespace "$NAMESPACE" --wait=true --timeout=5m || note_fail "could not remove namespace $NAMESPACE"
  if remaining="$(kc get namespace "$NAMESPACE" --ignore-not-found -o name)"; then
    [[ -z "$remaining" ]] || note_fail "namespace $NAMESPACE is still present"
  else
    note_fail "could not confirm namespace removal"
  fi
else
  echo "  namespace $NAMESPACE is already absent"
fi

say "EKS Pod Identity association"
if associations="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" --service-account analyst --output json)" &&
   count="$(jq -er '.associations | if type=="array" then length else error("invalid response") end' <<<"$associations")"; then
  if [[ "$count" == 0 ]]; then
    echo "  the association is already absent"
  elif [[ "$count" != 1 ]]; then
    note_fail "found multiple associations; left them alone"
  else
    id="$(jq -r '.associations[0].associationId' <<<"$associations")"
    if detail="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
        --association-id "$id" --output json)"; then
      if [[ "$(jq -r '.association.tags.ManagedBy // ""' <<<"$detail")" == "$SAMPLE" ]]; then
        aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" \
          --association-id "$id" >/dev/null || note_fail "could not remove association $id"
        if remaining="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
            --namespace "$NAMESPACE" --service-account analyst --output json)" &&
           jq -e '.associations | type=="array" and length==0' <<<"$remaining" >/dev/null; then
          echo "  the association is absent"
        else
          note_fail "could not confirm association removal"
        fi
      else
        note_fail "association $id is not owned by $SAMPLE; left it alone"
      fi
    else
      note_fail "could not read association $id; left it alone"
    fi
  fi
else
  note_fail "could not list Pod Identity associations"
fi

if [[ "$delete_aws" == true ]]; then
  say "S3 bucket"
  if [[ -z "${BUCKET:-}" ]]; then
    note_fail "the setup record has no bucket name"
  else
    rc=0
    got="$(box_cleanup_lookup NoSuchBucket s3api get-bucket-tagging --bucket "$BUCKET" --output json)" || rc=$?
    if [[ "$rc" == 0 ]]; then
      if [[ "$(jq -r '.TagSet[]? | select(.Key=="ManagedBy") | .Value' <<<"$got")" == "$SAMPLE" ]]; then
        if aws s3 rm "s3://$BUCKET" --recursive --region "$AWS_REGION" >/dev/null; then
          aws s3api delete-bucket --bucket "$BUCKET" >/dev/null || note_fail "could not remove bucket $BUCKET"
          confirm_absent "bucket $BUCKET" NoSuchBucket s3api get-bucket-tagging --bucket "$BUCKET" --output json
        else
          note_fail "could not empty bucket $BUCKET; left the bucket in place"
        fi
      else
        note_fail "bucket $BUCKET is not owned by $SAMPLE; left it alone"
      fi
    elif [[ "$rc" != 1 ]]; then
      note_fail "could not determine whether bucket $BUCKET exists"
    fi
  fi

  say "IAM role"
  if [[ -z "${ROLE_NAME:-}" ]]; then
    note_fail "the setup record has no role name"
  else
    rc=0
    got="$(box_cleanup_lookup NoSuchEntity iam get-role --role-name "$ROLE_NAME" --output json)" || rc=$?
    if [[ "$rc" == 0 ]]; then
      if [[ "$(jq -r '.Role.Tags[]? | select(.Key=="ManagedBy") | .Value' <<<"$got")" != "$SAMPLE" ]]; then
        note_fail "role $ROLE_NAME is not owned by $SAMPLE; left it alone"
      elif inline="$(aws iam list-role-policies --role-name "$ROLE_NAME" --output json)" &&
           attached="$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --output json)" &&
           jq -e '.PolicyNames | type=="array" and all(.=="analyst")' <<<"$inline" >/dev/null &&
           jq -e '.AttachedPolicies | type=="array" and length==0' <<<"$attached" >/dev/null; then
        role_ready=true
        if jq -e '.PolicyNames | index("analyst") != null' <<<"$inline" >/dev/null; then
          aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name analyst >/dev/null || {
            note_fail "could not remove the sample policy from $ROLE_NAME"
            role_ready=false
          }
        fi
        if [[ "$role_ready" == true ]]; then
          aws iam delete-role --role-name "$ROLE_NAME" >/dev/null || note_fail "could not remove role $ROLE_NAME"
          confirm_absent "role $ROLE_NAME" NoSuchEntity iam get-role --role-name "$ROLE_NAME" --output json
        fi
      else
        note_fail "role policies are unknown or include policies this sample does not own; left the role alone"
      fi
    elif [[ "$rc" != 1 ]]; then
      note_fail "could not determine whether role $ROLE_NAME exists"
    fi
  fi

  say "ECR repositories"
  for repository in "${ANALYST_REPOSITORY:-}" "${SUPPLIER_API_REPOSITORY:-}"; do
    if [[ -z "$repository" ]]; then note_fail "an image repository is missing from the setup record"; continue; fi
    rc=0
    got="$(box_cleanup_lookup RepositoryNotFoundException ecr describe-repositories \
      --repository-names "$repository" --output json)" || rc=$?
    if [[ "$rc" == 0 ]]; then
      arn="$(jq -r '.repositories[0].repositoryArn' <<<"$got")"
      if tags="$(aws ecr list-tags-for-resource --resource-arn "$arn" --output json)"; then
        if [[ "$(jq -r '.tags[]? | select(.Key=="ManagedBy") | .Value' <<<"$tags")" == "$SAMPLE" ]]; then
          aws ecr delete-repository --repository-name "$repository" --force >/dev/null ||
            note_fail "could not remove ECR repository $repository"
          confirm_absent "ECR repository $repository" RepositoryNotFoundException ecr describe-repositories \
            --repository-names "$repository" --output json
        else
          note_fail "ECR repository $repository is not owned by $SAMPLE; left it alone"
        fi
      else
        note_fail "could not read ownership of ECR repository $repository"
      fi
    elif [[ "$rc" != 1 ]]; then
      note_fail "could not determine whether ECR repository $repository exists"
    fi
  done
else
  echo "  kept the bucket, role, and images; use --delete-aws to remove them"
fi
# A retained resource or an uncertain deletion still needs this active target record.
# Move it only after full cleanup; preserve the exact record as a local receipt.
if [[ "$delete_aws" == true && "$failed" == 0 ]]; then
  if archive_dir="$(mktemp -d "$TMP_DIR/cleaned.XXXXXX")"; then
    if mv -- "$STATE_FILE" "$archive_dir/state.env"; then
      echo "  archived the completed setup record at $archive_dir/state.env"
    else
      note_fail "could not archive the setup record; keep it for a cleanup retry"
    fi
  else
    note_fail "could not create the cleanup archive; kept the active setup record"
  fi
fi
printf '\nKept local run records at %s\n' "$TMP_DIR"
if [[ "$failed" == 0 ]]; then
  echo "Cleanup complete. Shared controllers and cluster settings remain unchanged."
else
  echo "Cleanup is incomplete; inspect the INCOMPLETE messages above." >&2
fi
exit "$failed"
