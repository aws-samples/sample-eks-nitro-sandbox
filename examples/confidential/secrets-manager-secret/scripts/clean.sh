#!/usr/bin/env bash
# Remove everything scripts/setup.sh and scripts/changed-pod.sh created.
#
#   ./scripts/clean.sh                      # pods, policy, namespace and all five AWS resources
#   ./scripts/clean.sh --keep-aws-resources # cluster objects only; keep the key, secret, repository, role and association
#
# What it will and will not touch:
#   * It deletes each AWS resource only after reading that resource's own tags and finding
#     ManagedBy=secrets-manager-secret on it. A resource without the tag is skipped and the
#     clean up is reported incomplete.
#   * It deletes objects inside the namespace only after confirming the namespace carries
#     this sample's app.kubernetes.io/managed-by label. Inside a namespace that does carry
#     it, everything belongs to the sample.
#   * Each pod is deleted by its exact name, never by a label selector.
#   * A lookup that cannot run means "could not determine", which is a failure, never
#     "already gone". The script exits non-zero when anything was left behind or could not
#     be checked.
#
# Two AWS resources deserve a word. The secret is deleted with no recovery window, so the
# ciphertext goes at once and the name becomes reusable; Secrets Manager does the deletion
# asynchronously, so a run started immediately afterwards can still be told the name is
# taken. The KMS key is scheduled for deletion, which AWS does after a waiting period of at
# least 7 days; there is no way to destroy a key sooner. Its alias is deleted at once, so a
# later run with the same KMS_ALIAS makes a new key rather than finding the old one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/secrets-manager-secret/run"
STATE_FILE="$TMP_DIR/state.env"

MANAGED_BY="secrets-manager-secret"
POD_NAME="secrets-manager-secret-demo"
PLAIN_POD_NAME="secrets-manager-secret-plain"
CREDENTIALS_POD_NAME="secrets-manager-secret-credentials"
CHANGED_POD_NAME="secrets-manager-secret-changed"

if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; . "$SAMPLE_DIR/.env"; set +a; fi
if [[ -f "$STATE_FILE" ]]; then set -a; . "$STATE_FILE"; set +a; fi

NAMESPACE="${NAMESPACE:-secrets-manager-secret-sample}"
ECR_REPOSITORY="${ECR_REPOSITORY:-secrets-manager-secret-sample}"
KMS_ALIAS="${KMS_ALIAS:-alias/secrets-manager-secret-sample}"
IAM_ROLE_NAME="${IAM_ROLE_NAME:-secrets-manager-secret-sample-pod}"
SECRET_NAME="${SECRET_NAME:-secrets-manager-secret-sample}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-secrets-manager-secret-pod}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
AWS_REGION="${AWS_REGION:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"

keep_aws=false
for arg in "$@"; do
  case "$arg" in
    --keep-aws-resources) keep_aws=true ;;
    --help|-h) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

failed=0
note_fail() { echo "INCOMPLETE: $*" >&2; failed=1; }

. "$SCRIPT_DIR/lib.sh"
for c in kubectl aws jq; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 1; }
done

# The Region is required, not optional. Without it the AWS CLI falls back to whatever the
# ambient configuration says, and a regional lookup in the wrong Region comes back with the
# service's own not-found exception: this script would then report the ECR repository, the
# secret and the KMS key as "already gone" and exit 0, while they are still there.
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

# --------------------------------------------------------------- cluster objects
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
  echo "Kept the AWS resources (--keep-aws-resources): the KMS key, the secret, the ECR repository, the IAM role and the Pod Identity association."
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

  # The Secrets Manager secret, with the ciphertext in it. Deleted with no recovery window:
  # the sample's value is a token it generated itself, and a 30 day recovery window would
  # keep the name taken for a reader who wants to run the sample again.
  if secret_json="$(lookup ResourceNotFoundException secretsmanager describe-secret \
    --secret-id "$SECRET_NAME" --output json)"; then
    secret_tag="$(jq -r '[.Tags[]? | select(.Key == "ManagedBy") | .Value][0] // ""' <<<"$secret_json")"
    if [[ "$secret_tag" != "$MANAGED_BY" ]]; then
      note_fail "the secret $SECRET_NAME does not carry ManagedBy=$MANAGED_BY (found '$secret_tag'); left it alone"
    else
      echo "Deleting the secret $SECRET_NAME and the ciphertext in it..."
      aws secretsmanager delete-secret --secret-id "$SECRET_NAME" \
        --force-delete-without-recovery >/dev/null \
        || note_fail "could not delete the secret $SECRET_NAME"
    fi
  elif [[ $? == 1 ]]; then
    echo "Secret $SECRET_NAME is already gone."
  else
    note_fail "could not determine whether the secret $SECRET_NAME exists"
  fi

  # IAM role.
  if role_json="$(lookup NoSuchEntity iam get-role --role-name "$IAM_ROLE_NAME" --query Role --output json)"; then
    role_tag="$(tag_or_empty "$(aws iam list-role-tags --role-name "$IAM_ROLE_NAME" \
      --query "Tags[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null)")"
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
    repo_tag="$(tag_or_empty "$(aws ecr list-tags-for-resource --resource-arn "$repo_arn" \
      --query "tags[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null)")"
    if [[ "$repo_tag" != "$MANAGED_BY" ]]; then
      note_fail "ECR repository $ECR_REPOSITORY does not carry ManagedBy=$MANAGED_BY (found '$repo_tag'); left it alone"
    else
      echo "Deleting ECR repository $ECR_REPOSITORY and the application image in it..."
      aws ecr delete-repository --repository-name "$ECR_REPOSITORY" --force >/dev/null \
        || note_fail "could not delete ECR repository $ECR_REPOSITORY"
    fi
  elif [[ $? == 1 ]]; then
    echo "ECR repository $ECR_REPOSITORY is already gone."
  else
    note_fail "could not determine whether ECR repository $ECR_REPOSITORY exists"
  fi

  # KMS key: delete the alias at once, schedule the key.
  if key_json="$(lookup NotFoundException kms describe-key --key-id "$KMS_ALIAS" --query KeyMetadata --output json)"; then
    key_id="$(jq -r '.KeyId' <<<"$key_json")"
    key_state="$(jq -r '.KeyState' <<<"$key_json")"
    key_tag="$(tag_or_empty "$(aws kms list-resource-tags --key-id "$key_id" \
      --query "Tags[?TagKey=='ManagedBy'].TagValue | [0]" --output text 2>/dev/null)")"
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
# The run files hold the resource ids and the registry credentials, so they are only removed
# when there is nothing left to come back for: not after a clean up that left something
# behind, and not when the AWS resources were kept on purpose. Note that
# --keep-aws-resources still deletes the namespace and the service account, so a later
# scripts/setup.sh is what makes the kept resources usable again, not changed-pod.sh.
#
# Only run/, which is the directory the scripts write and nothing else does. The folder above
# it is yours: output you captured with tee, a review brief, a copy of a state file. The
# rmdir removes that folder too when it holds nothing but run/, and is left to fail quietly
# when it does not.
if [[ "$failed" != 0 ]]; then
  echo "Keeping the run files under $TMP_DIR: the clean up left something behind, and they hold the ids needed to finish it."
elif [[ "$keep_aws" == true ]]; then
  echo "Keeping the run files under $TMP_DIR: they hold the ids of the AWS resources that were kept."
else
  echo "Deleting the run files under $TMP_DIR..."
  # Inspected, because this script runs without set -e: an rm that failed would otherwise
  # leave the run files, holding this account's ARNs, behind under a "Clean up complete".
  if rm -rf "$TMP_DIR"; then
    rmdir "$(dirname "$TMP_DIR")" 2>/dev/null || true
  else
    note_fail "could not remove the run files under $TMP_DIR; they hold this account's resource ids"
  fi
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
