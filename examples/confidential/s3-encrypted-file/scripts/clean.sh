#!/usr/bin/env bash
# Remove everything scripts/setup.sh and scripts/changed-pod.sh created.
#
#   ./scripts/clean.sh                      # pods, policy, namespace and every AWS resource
#   ./scripts/clean.sh --keep-aws-resources # cluster objects only; keep the bucket, key,
#                                           # repository, role and association
#
# What it will and will not touch:
#   * It deletes each AWS resource only after reading that resource's own tags and finding
#     ManagedBy=s3-encrypted-file on it. A resource without the tag is skipped and the
#     clean up is reported incomplete. That check matters most for the S3 bucket: emptying
#     a bucket deletes its objects, and their versions, and there is no undoing it.
#   * It deletes objects inside the namespace only after confirming the namespace carries
#     this sample's app.kubernetes.io/managed-by label. Inside a namespace that does carry
#     it, everything belongs to the sample.
#   * Each pod is deleted by its exact name, never by a label selector.
#   * A lookup that cannot run means "could not determine", which is a failure, never
#     "already gone". The script exits non-zero when anything was left behind or could not
#     be checked.
#
# The KMS key is scheduled for deletion, which AWS does after a waiting period of at least
# 7 days; there is no way to destroy a key sooner. Its alias is deleted at once, so a later
# run with the same KMS_ALIAS makes a new key rather than finding the old one. An S3 bucket
# name stays unavailable for a while after the bucket is deleted, so a later run may need a
# new S3_BUCKET.
set -uo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/s3-encrypted-file"
STATE_FILE="$TMP_DIR/state.env"

MANAGED_BY="s3-encrypted-file"
POD_NAME="s3-encrypted-file-demo"
PLAIN_POD_NAME="s3-encrypted-file-plain"
CREDENTIALS_POD_NAME="s3-encrypted-file-credentials"
CHANGED_POD_NAME="s3-encrypted-file-changed"

if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; . "$SAMPLE_DIR/.env"; set +a; fi
if [[ -f "$STATE_FILE" ]]; then set -a; . "$STATE_FILE"; set +a; fi

NAMESPACE="${NAMESPACE:-s3-encrypted-file-sample}"
ECR_REPOSITORY="${ECR_REPOSITORY:-s3-encrypted-file-sample}"
KMS_ALIAS="${KMS_ALIAS:-alias/s3-encrypted-file-sample}"
IAM_ROLE_NAME="${IAM_ROLE_NAME:-s3-encrypted-file-sample-pod}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-s3-encrypted-file-pod}"
S3_BUCKET="${S3_BUCKET:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
AWS_REGION="${AWS_REGION:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"

keep_aws=false
for arg in "$@"; do
  case "$arg" in
    --keep-aws-resources) keep_aws=true ;;
    --help|-h) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

failed=0
note_fail() { echo "INCOMPLETE: $*" >&2; failed=1; }

kc() {
  if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi
}
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl is required" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "ERROR: the AWS CLI is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }

# The Region is required, not optional. Without it the AWS CLI falls back to whatever the
# ambient configuration says, and a regional lookup in the wrong Region comes back with the
# service's own not-found exception: this script would then report the ECR repository and
# the KMS key as "already gone" and exit 0, while they are still there.
[[ -n "$AWS_REGION" ]] || {
  echo "ERROR: AWS_REGION is not set, so a lookup could run against the wrong Region and report resources that still exist as already gone. Fill it in in .env (next to this script's sample folder), or run from the shell that ran setup.sh." >&2
  exit 1
}
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

# Say which cluster and Region this is about to act on, for the same reason: an empty
# KUBE_CONTEXT means "whatever is current", which on a shared machine is not always this
# sample's cluster.
clean_context="$(kc config current-context 2>/dev/null || true)"
[[ -n "$clean_context" ]] || { echo "ERROR: could not read the current kube context; set KUBE_CONTEXT in .env" >&2; exit 1; }
echo "Cleaning up in context $clean_context, Region $AWS_REGION, namespace $NAMESPACE."

# Same contract as setup.sh: absence is proved by the service's own not-found exception.
# Returns 0 and prints stdout when present, 1 when the exception came back, 2 otherwise.
lookup() {
  local notfound="$1"; shift
  local out err rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/s3ef-c-out.XXXXXX")" || return 2
  err="$(mktemp "${TMPDIR:-/tmp}/s3ef-c-err.XXXXXX")" || return 2
  aws "$@" >"$out" 2>"$err" || rc=$?
  if [[ "$rc" == 0 ]]; then cat "$out"; rm -f "$out" "$err"; return 0; fi
  if grep -Fq "$notfound" "$err"; then rm -f "$out" "$err"; return 1; fi
  sed 's/^/  /' "$err" >&2
  rm -f "$out" "$err"
  return 2
}

# --------------------------------------------------------------- cluster objects
# Check who owns the namespace before deleting anything inside it.
ns_exists="$(kc get namespace "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)"
ns_exists_rc=$?
ns_label="$(kc get namespace "$NAMESPACE" --ignore-not-found \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"
ns_label_rc=$?
if [[ "$ns_exists_rc" != 0 || "$ns_label_rc" != 0 ]]; then
  ns_state=unknown
elif [[ -z "$ns_exists" ]]; then
  ns_state=absent
elif [[ "$ns_label" == "$MANAGED_BY" ]]; then
  ns_state=owned
else
  ns_state=foreign
fi

case "$ns_state" in
  unknown)
    note_fail "could not determine whether namespace $NAMESPACE is this sample's (kubectl lookup failed); deleted nothing in the cluster" ;;
  absent)
    echo "Namespace $NAMESPACE is already gone; nothing to delete in the cluster." ;;
  foreign)
    note_fail "namespace $NAMESPACE is not this sample's (managed-by='$ns_label'); deleted nothing in it" ;;
  owned)
    # By exact name, never a label selector: a selector meant for these pods could match
    # another demo's pod.
    for p in "$CHANGED_POD_NAME" "$CREDENTIALS_POD_NAME" "$PLAIN_POD_NAME" "$POD_NAME"; do
      echo "Deleting pod $NAMESPACE/$p..."
      kc delete pod "$p" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m \
        || note_fail "could not delete pod $p"
    done
    kc delete serviceaccount "$SERVICE_ACCOUNT" -n "$NAMESPACE" --ignore-not-found \
      || note_fail "could not delete the service account"
    echo "Deleting namespace $NAMESPACE (carries app.kubernetes.io/managed-by=$MANAGED_BY)..."
    kc delete namespace "$NAMESPACE" --wait=true --timeout=5m \
      || note_fail "could not delete namespace $NAMESPACE"
    still="$(kc get namespace "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)"
    if [[ $? != 0 ]]; then
      note_fail "could not confirm namespace $NAMESPACE was deleted"
    elif [[ -n "$still" ]]; then
      note_fail "namespace $NAMESPACE still present after delete"
    fi
    ;;
esac

# ------------------------------------------------------------------- AWS resources
if [[ "$keep_aws" == true ]]; then
  echo "Kept the AWS resources (--keep-aws-resources): the S3 bucket and its objects, the KMS key, the ECR repository, the IAM role and the Pod Identity association."
else
  # Pod Identity association. It has no name, so it is identified by its cluster, namespace
  # and service account, and only deleted when it carries the sample's tag.
  if [[ -n "$CLUSTER_NAME" ]]; then
    assoc_id="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
      --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" \
      --query 'associations[0].associationId' --output text 2>/dev/null)"
    if [[ $? != 0 ]]; then
      note_fail "could not look up the Pod Identity association for $NAMESPACE/$SERVICE_ACCOUNT"
    elif [[ "$assoc_id" == "None" || -z "$assoc_id" ]]; then
      echo "Pod Identity association for $NAMESPACE/$SERVICE_ACCOUNT is already gone."
    else
      assoc_tag="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
        --association-id "$assoc_id" --query 'association.tags.ManagedBy' --output text 2>/dev/null)"
      if [[ "$assoc_tag" != "$MANAGED_BY" ]]; then
        note_fail "Pod Identity association $assoc_id does not carry ManagedBy=$MANAGED_BY (found '$assoc_tag'); left it alone"
      else
        echo "Deleting Pod Identity association $assoc_id..."
        aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" \
          --association-id "$assoc_id" >/dev/null \
          || note_fail "could not delete Pod Identity association $assoc_id"
      fi
    fi
  else
    note_fail "CLUSTER_NAME is not set, so the Pod Identity association could not be looked up"
  fi

  # IAM role.
  if role_json="$(lookup NoSuchEntity iam get-role --role-name "$IAM_ROLE_NAME" --query Role --output json)"; then
    role_tag="$(aws iam list-role-tags --role-name "$IAM_ROLE_NAME" \
      --query "Tags[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null)"
    if [[ "$role_tag" != "$MANAGED_BY" ]]; then
      note_fail "IAM role $IAM_ROLE_NAME does not carry ManagedBy=$MANAGED_BY (found '$role_tag'); left it alone"
    else
      echo "Deleting IAM role $IAM_ROLE_NAME..."
      aws iam delete-role --role-name "$IAM_ROLE_NAME" \
        || note_fail "could not delete IAM role $IAM_ROLE_NAME"
    fi
  elif [[ $? == 1 ]]; then
    echo "IAM role $IAM_ROLE_NAME is already gone."
  else
    note_fail "could not determine whether IAM role $IAM_ROLE_NAME exists"
  fi

  # ECR repository, with the application image in it.
  if repo_json="$(lookup RepositoryNotFoundException ecr describe-repositories \
    --repository-names "$ECR_REPOSITORY" --query 'repositories[0]' --output json)"; then
    repo_arn="$(jq -r '.repositoryArn' <<<"$repo_json")"
    repo_tag="$(aws ecr list-tags-for-resource --resource-arn "$repo_arn" \
      --query "tags[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null)"
    if [[ "$repo_tag" != "$MANAGED_BY" ]]; then
      note_fail "ECR repository $ECR_REPOSITORY does not carry ManagedBy=$MANAGED_BY (found '$repo_tag'); left it alone"
    else
      echo "Deleting ECR repository $ECR_REPOSITORY and the image in it..."
      aws ecr delete-repository --repository-name "$ECR_REPOSITORY" --force >/dev/null \
        || note_fail "could not delete ECR repository $ECR_REPOSITORY"
    fi
  elif [[ $? == 1 ]]; then
    echo "ECR repository $ECR_REPOSITORY is already gone."
  else
    note_fail "could not determine whether ECR repository $ECR_REPOSITORY exists"
  fi

  # The S3 bucket, with the ciphertext and the manifest in it. Emptying a bucket cannot be
  # undone, so nothing here runs until the bucket's own tags say it is this sample's: not
  # the name, not the run record, the tags on the bucket.
  bucket_rc=0
  if [[ -n "$S3_BUCKET" ]]; then
    lookup "(404)" s3api head-bucket --bucket "$S3_BUCKET" >/dev/null || bucket_rc=$?
  fi
  if [[ -z "$S3_BUCKET" ]]; then
    note_fail "S3_BUCKET is not set, so the bucket could not be looked up or deleted"
  elif [[ "$bucket_rc" == 1 ]]; then
    echo "S3 bucket $S3_BUCKET is already gone."
  elif [[ "$bucket_rc" == 2 ]]; then
    note_fail "could not determine whether the S3 bucket $S3_BUCKET exists; left it and its objects alone"
  else
    tag_rc=0
    bucket_tags="$(lookup NoSuchTagSet s3api get-bucket-tagging --bucket "$S3_BUCKET" \
      --query 'TagSet' --output json)" || tag_rc=$?
    bucket_tag=""
    if [[ "$tag_rc" == 0 ]]; then
      bucket_tag="$(jq -r '(map(select(.Key == "ManagedBy")) | first | .Value) // ""' <<<"$bucket_tags")"
    fi
    if [[ "$tag_rc" == 2 ]]; then
      note_fail "could not read the tags of the S3 bucket $S3_BUCKET; left it and its objects alone"
    elif [[ "$bucket_tag" != "$MANAGED_BY" ]]; then
      note_fail "the S3 bucket $S3_BUCKET does not carry ManagedBy=$MANAGED_BY (found '$bucket_tag'); left it and its objects alone"
    else
      echo "Emptying S3 bucket $S3_BUCKET (carries ManagedBy=$MANAGED_BY)..."
      emptied=true
      for _ in $(seq 10); do
        listing="$(aws s3api list-object-versions --bucket "$S3_BUCKET" --output json 2>/dev/null)"
        if [[ $? != 0 ]]; then
          note_fail "could not list the objects in $S3_BUCKET"
          emptied=false; break
        fi
        # Versions and delete markers together: the sample does not turn versioning on, and
        # on a bucket where it is off every object comes back with VersionId "null", which
        # delete-objects accepts. A bucket somebody turned it on for is emptied properly
        # rather than refusing to delete.
        payload="$(jq -c '{Objects: [((.Versions // []) + (.DeleteMarkers // []))[]
                                     | {Key: .Key, VersionId: .VersionId}][0:1000],
                           Quiet: true}' <<<"$listing")"
        count="$(jq '.Objects | length' <<<"$payload")"
        if [[ "$count" == 0 ]]; then break; fi
        echo "  deleting $count object version(s)..."
        aws s3api delete-objects --bucket "$S3_BUCKET" --delete "$payload" >/dev/null || {
          note_fail "could not delete objects in $S3_BUCKET"
          emptied=false; break
        }
      done
      if [[ "$emptied" == true ]]; then
        echo "Deleting S3 bucket $S3_BUCKET..."
        aws s3api delete-bucket --bucket "$S3_BUCKET" \
          || note_fail "could not delete the S3 bucket $S3_BUCKET"
        confirm_rc=0
        lookup "(404)" s3api head-bucket --bucket "$S3_BUCKET" >/dev/null || confirm_rc=$?
        if [[ "$confirm_rc" == 0 ]]; then
          note_fail "the S3 bucket $S3_BUCKET is still there after the delete"
        elif [[ "$confirm_rc" != 1 ]]; then
          note_fail "could not confirm the S3 bucket $S3_BUCKET was deleted"
        fi
      fi
    fi
  fi

  # KMS key: delete the alias at once, schedule the key.
  if key_json="$(lookup NotFoundException kms describe-key --key-id "$KMS_ALIAS" --query KeyMetadata --output json)"; then
    key_id="$(jq -r '.KeyId' <<<"$key_json")"
    key_state="$(jq -r '.KeyState' <<<"$key_json")"
    key_tag="$(aws kms list-resource-tags --key-id "$key_id" \
      --query "Tags[?TagKey=='ManagedBy'].TagValue | [0]" --output text 2>/dev/null)"
    if [[ "$key_tag" != "$MANAGED_BY" ]]; then
      note_fail "the KMS key behind $KMS_ALIAS does not carry ManagedBy=$MANAGED_BY (found '$key_tag'); left it and its alias alone"
    else
      echo "Deleting the alias $KMS_ALIAS..."
      aws kms delete-alias --alias-name "$KMS_ALIAS" \
        || note_fail "could not delete the KMS alias $KMS_ALIAS"
      if [[ "$key_state" == "PendingDeletion" ]]; then
        echo "The KMS key $key_id is already scheduled for deletion."
      else
        echo "Scheduling the KMS key $key_id for deletion in 7 days (the shortest AWS allows)..."
        aws kms schedule-key-deletion --key-id "$key_id" --pending-window-in-days 7 \
          --query '[KeyId,DeletionDate]' --output text \
          || note_fail "could not schedule the KMS key $key_id for deletion"
      fi
    fi
  elif [[ $? == 1 ]]; then
    echo "No KMS key resolves from $KMS_ALIAS; it is already gone."
  else
    note_fail "could not determine whether a KMS key resolves from $KMS_ALIAS"
  fi
fi

# ---------------------------------------------------------------------- local files
# The run files hold the resource ids, the registry credentials and the plaintext file, so
# they are only removed when there is nothing left to come back for: not after a clean up
# that left something behind, and not when the AWS resources were kept on purpose. Note
# that --keep-aws-resources still deletes the namespace and the service account, so a later
# scripts/setup.sh is what makes the kept resources usable again, not changed-pod.sh.
if [[ "$failed" != 0 ]]; then
  echo "Keeping the run files under $TMP_DIR: the clean up left something behind, and they hold the ids needed to finish it."
elif [[ "$keep_aws" == true ]]; then
  echo "Keeping the run files under $TMP_DIR: they hold the ids of the AWS resources that were kept."
else
  echo "Deleting the run files under $TMP_DIR, including the plaintext file..."
  rm -rf "$TMP_DIR"
fi

echo
if [[ "$failed" == 0 ]]; then
  if [[ "$keep_aws" == true ]]; then
    echo "Clean up complete. The AWS resources were kept on purpose."
  else
    echo "Clean up complete. The KMS key is scheduled, not yet destroyed; AWS removes it after its waiting period."
  fi
else
  echo "Clean up finished with items left behind (see the INCOMPLETE lines above)." >&2
fi
exit "$failed"
