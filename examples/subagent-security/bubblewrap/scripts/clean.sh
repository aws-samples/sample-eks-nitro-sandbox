#!/usr/bin/env bash
# clean.sh -- remove what this sample created, and only that.
#
# Usage:
#   ./scripts/clean.sh                      # the cluster objects and the namespace
#   ./scripts/clean.sh --delete-aws         # also the bucket, the IAM role and the images
#
# It reads the same run record setup.sh wrote, so there is nothing to set again.
#
# It does not stop at the first failure. A lookup that fails means "could not determine",
# which is a failure and never "already gone": anything it could not delete or confirm is
# named at the end and makes it exit non-zero. It touches a resource only when that
# resource carries this sample's ManagedBy tag, or sits inside a namespace carrying this
# sample's managed-by label, and leaves anything else alone.
#
# It never removes a shared install or a cluster-wide setting; this sample changes none, so
# there is nothing of that kind to undo. What stays is listed at the end.
set -uo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
SAMPLE="bubblewrap"
TMP_DIR="$REPO_ROOT/tmp/$SAMPLE"
STATE_FILE="$TMP_DIR/state.env"

delete_aws=false
for arg in "$@"; do
  case "$arg" in
    --delete-aws) delete_aws=true ;;
    --help|-h) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

failed=0
note_fail() { echo "INCOMPLETE: $*" >&2; failed=1; }
say() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# .env first and the run record second, so the record wins. The record holds the names the
# run actually created; .env holds what the next run would use, and the two differ exactly
# when someone has changed a name since. Sourced the other way round, a changed .env would
# send this script after a namespace and a bucket that were never created and leave the
# real ones behind.
if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; . "$SAMPLE_DIR/.env"; set +a; fi
if [[ -f "$STATE_FILE" ]]; then set -a; . "$STATE_FILE"; set +a; fi

NAMESPACE="${NAMESPACE:-subagent-security-bubblewrap}"
AWS_REGION="${AWS_REGION:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"

# Without a Region, a regional lookup runs in whichever Region the environment happens to
# name, and comes back with the service's own not-found exception. This script would then
# report resources as "already gone" and exit 0 while they are still there.
[[ -n "$AWS_REGION" ]] ||
  die "AWS_REGION is not set, so a lookup could run in the wrong Region and report a resource that still exists as already gone. Set it in .env, or run ./scripts/setup.sh first so the run record has it."
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

for c in aws jq kubectl; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required"
done

kc() {
  if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"
  else kubectl "$@"; fi
}

# See analyst-lib.sh for why this returns 2 rather than exiting.
lookup() {
  local notfound="$1"; shift
  local out err rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/analyst-out.XXXXXX")" || return 2
  err="$(mktemp "${TMPDIR:-/tmp}/analyst-err.XXXXXX")" || return 2
  aws "$@" >"$out" 2>"$err" || rc=$?
  if [[ "$rc" == 0 ]]; then cat "$out"; rm -f "$out" "$err"; return 0; fi
  if grep -Fq "$notfound" "$err"; then rm -f "$out" "$err"; return 1; fi
  echo "ERROR: 'aws $*' failed (exit $rc) and not with $notfound, so it is unknown whether the resource exists:" >&2
  sed 's/^/  /' "$err" >&2
  rm -f "$out" "$err"
  return 2
}

say "1/4 the namespace's own objects"

# Four states, and only one of them lets anything inside the namespace be deleted.
ns_state=unknown
if ns_json="$(kc get namespace "$NAMESPACE" --ignore-not-found -o json 2>/dev/null)"; then
  if [[ -z "$ns_json" ]]; then
    ns_state=absent
  elif [[ "$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<<"$ns_json")" == "$SAMPLE" ]]; then
    ns_state=owned
  else
    ns_state=foreign
  fi
fi
case "$ns_state" in
  absent) echo "  namespace $NAMESPACE is already gone." ;;
  foreign) note_fail "namespace $NAMESPACE is not this sample's (its managed-by label is not '$SAMPLE'); deleted nothing in it" ;;
  unknown) note_fail "could not determine whether namespace $NAMESPACE exists or whose it is; deleted nothing in it" ;;
  owned)
    # Inside this sample's own namespace, the namespace label is the ownership check. The
    # analyst pod goes first: it is what holds sandbox capacity other demos on the cluster
    # share. Each pod is named exactly, never selected by label.
    for p in analyst ordinary-comparison; do
      kc delete pod "$p" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m ||
        note_fail "could not delete pod $p in $NAMESPACE"
    done
    kc delete deployment supplier-api -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=5m ||
      note_fail "could not delete the supplier-api Deployment"
    kc delete namespace "$NAMESPACE" --wait=true --timeout=5m ||
      note_fail "could not delete namespace $NAMESPACE"
    if still="$(kc get namespace "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)"; then
      [[ -z "$still" ]] || note_fail "namespace $NAMESPACE is still present after the delete"
    else
      note_fail "could not confirm namespace $NAMESPACE was deleted"
    fi
    ;;
esac

say "2/4 the EKS Pod Identity association"

if [[ -z "$CLUSTER_NAME" ]]; then
  note_fail "CLUSTER_NAME is not set, so the Pod Identity association could not be looked up or removed"
else
  assoc="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" --service-account analyst --output json 2>/dev/null)"
  if [[ -z "$assoc" ]]; then
    note_fail "could not list the Pod Identity associations for $NAMESPACE/analyst on $CLUSTER_NAME"
  elif [[ "$(jq '.associations | length' <<<"$assoc")" == 0 ]]; then
    echo "  no association for $NAMESPACE/analyst; already gone."
  else
    id="$(jq -r '.associations[0].associationId' <<<"$assoc")"
    detail="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
      --association-id "$id" --output json 2>/dev/null)"
    if [[ -z "$detail" ]]; then
      note_fail "could not read the Pod Identity association $id, so it was left in place"
    elif [[ "$(jq -r '.association.tags.ManagedBy // ""' <<<"$detail")" != "$SAMPLE" ]]; then
      note_fail "the Pod Identity association $id does not carry ManagedBy=$SAMPLE; left it alone"
    else
      aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" \
        --association-id "$id" >/dev/null 2>&1 ||
        note_fail "could not delete the Pod Identity association $id"
      remaining="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
        --namespace "$NAMESPACE" --service-account analyst --output json 2>/dev/null)"
      if [[ -z "$remaining" ]]; then
        note_fail "could not confirm the Pod Identity association was deleted"
      elif [[ "$(jq '.associations | length' <<<"$remaining")" != 0 ]]; then
        note_fail "the Pod Identity association is still present after the delete"
      else
        echo "  deleted the association $id."
      fi
    fi
  fi
fi

say "3/4 the AWS resources"

if [[ "$delete_aws" != true ]]; then
  echo "  kept the bucket, the IAM role and the images; pass --delete-aws to remove them."
else
  bucket="${BUCKET:-}"
  if [[ -z "$bucket" ]]; then
    note_fail "no bucket name in the run record or .env, so the bucket could not be removed"
  else
    tags="$(lookup NoSuchBucket s3api get-bucket-tagging --bucket "$bucket" --output json)"; rc=$?
    if [[ "$rc" == 0 ]]; then
      tag="$(jq -r '.TagSet[]? | select(.Key=="ManagedBy") | .Value' <<<"$tags")"
      if [[ "$tag" != "$SAMPLE" ]]; then
        note_fail "the bucket $bucket does not carry ManagedBy=$SAMPLE (found '$tag'); left it alone"
      else
        aws s3 rm "s3://$bucket" --recursive --region "$AWS_REGION" >/dev/null 2>&1 ||
          note_fail "could not empty the bucket $bucket"
        aws s3api delete-bucket --bucket "$bucket" >/dev/null 2>&1 ||
          note_fail "could not delete the bucket $bucket"
        lookup NoSuchBucket s3api get-bucket-tagging --bucket "$bucket" --output json \
          >/dev/null 2>&1; rc=$?
        case "$rc" in
          1) echo "  deleted the bucket $bucket." ;;
          0) note_fail "the bucket $bucket is still present after the delete" ;;
          *) note_fail "could not confirm the bucket $bucket was deleted" ;;
        esac
      fi
    elif [[ "$rc" == 1 ]]; then
      echo "  the bucket $bucket is already gone."
    else
      note_fail "could not determine whether the bucket $bucket exists; left it alone"
    fi
  fi

  role="${ROLE_NAME:-}"
  if [[ -z "$role" ]]; then
    note_fail "no IAM role name in the run record or .env, so the role could not be removed"
  else
    got="$(lookup NoSuchEntity iam get-role --role-name "$role" --output json)"; rc=$?
    if [[ "$rc" == 0 ]]; then
      tag="$(jq -r '.Role.Tags[]? | select(.Key=="ManagedBy") | .Value' <<<"$got")"
      if [[ "$tag" != "$SAMPLE" ]]; then
        note_fail "the IAM role $role does not carry ManagedBy=$SAMPLE (found '$tag'); left it alone"
      else
        inline="$(aws iam list-role-policies --role-name "$role" --output json 2>/dev/null)"
        attached="$(aws iam list-attached-role-policies --role-name "$role" --output json 2>/dev/null)"
        if [[ -z "$inline" || -z "$attached" ]]; then
          note_fail "could not list the policies on the IAM role $role; left it in place"
        elif [[ -n "$(jq -r '.PolicyNames[] | select(. != "analyst")' <<<"$inline")" ||
                "$(jq '.AttachedPolicies | length' <<<"$attached")" != 0 ]]; then
          note_fail "the IAM role $role carries a policy this sample did not create; left it in place"
        else
          if [[ "$(jq -r '.PolicyNames | index("analyst")' <<<"$inline")" != "null" ]]; then
            aws iam delete-role-policy --role-name "$role" --policy-name analyst >/dev/null 2>&1 ||
              note_fail "could not delete the inline policy on $role"
          fi
          aws iam delete-role --role-name "$role" >/dev/null 2>&1 ||
            note_fail "could not delete the IAM role $role"
          lookup NoSuchEntity iam get-role --role-name "$role" --output json >/dev/null 2>&1; rc=$?
          case "$rc" in
            1) echo "  deleted the IAM role $role." ;;
            0) note_fail "the IAM role $role is still present after the delete" ;;
            *) note_fail "could not confirm the IAM role $role was deleted" ;;
          esac
        fi
      fi
    elif [[ "$rc" == 1 ]]; then
      echo "  the IAM role $role is already gone."
    else
      note_fail "could not determine whether the IAM role $role exists; left it alone"
    fi
  fi

  for repo in "${ANALYST_REPOSITORY:-}" "${SUPPLIER_API_REPOSITORY:-}"; do
    [[ -n "$repo" ]] || continue
    got="$(lookup RepositoryNotFoundException ecr describe-repositories \
      --repository-names "$repo" --output json)"; rc=$?
    if [[ "$rc" == 0 ]]; then
      arn="$(jq -r '.repositories[0].repositoryArn' <<<"$got")"
      tags="$(aws ecr list-tags-for-resource --resource-arn "$arn" --output json 2>/dev/null)"
      if [[ -z "$tags" ]]; then
        note_fail "could not read the tags on the ECR repository $repo; left it alone"
      elif [[ "$(jq -r '.tags[]? | select(.Key=="ManagedBy") | .Value' <<<"$tags")" != "$SAMPLE" ]]; then
        note_fail "the ECR repository $repo does not carry ManagedBy=$SAMPLE; left it alone"
      else
        aws ecr delete-repository --repository-name "$repo" --force >/dev/null 2>&1 ||
          note_fail "could not delete the ECR repository $repo"
        lookup RepositoryNotFoundException ecr describe-repositories \
          --repository-names "$repo" --output json >/dev/null 2>&1; rc=$?
        case "$rc" in
          1) echo "  deleted the ECR repository $repo." ;;
          0) note_fail "the ECR repository $repo is still present after the delete" ;;
          *) note_fail "could not confirm the ECR repository $repo was deleted" ;;
        esac
      fi
    elif [[ "$rc" == 1 ]]; then
      echo "  the ECR repository $repo is already gone."
    else
      note_fail "could not determine whether the ECR repository $repo exists; left it alone"
    fi
  done
fi

say "4/4 the local run files"

if [[ "$failed" == 0 && "$delete_aws" == true ]]; then
  rm -rf "$TMP_DIR"
  echo "  removed $TMP_DIR."
else
  echo "  kept $TMP_DIR, which holds the run record and this run's key material."
  if [[ "$failed" != 0 ]]; then
    echo "  It is needed to finish the items marked INCOMPLETE above."
  fi
fi

say "what stays"
cat <<EOF
  This sample changed no cluster-wide setting and installed nothing shared, so there is
  nothing of that kind to undo.

  The isolated-sandbox RuntimeClass and the cluster itself are not this sample's. The
  hello sandbox sample's clean up covers removing the cluster.
EOF

echo
if [[ "$failed" == 0 ]]; then
  echo "Clean up complete."
else
  echo "Clean up finished with items left behind (see the INCOMPLETE lines above)." >&2
fi
exit "$failed"
