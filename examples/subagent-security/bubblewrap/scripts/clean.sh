#!/usr/bin/env bash
# clean.sh -- remove what this sample created, and only that.
#
# Usage:
#   ./scripts/clean.sh                      # the cluster objects and the namespace
#   ./scripts/clean.sh --delete-aws         # also the bucket, the IAM role, the ECR
#                                           # repositories and the local images it built
#   ./scripts/clean.sh --delete-aws --delete-node
#                                           # also the sandbox node, and any NodeClaim, the
#                                           # run's pods were given
#   ./scripts/clean.sh --delete-aws --delete-node --allow-instance-termination
#                                           # and, if deleting the node through EKS fails,
#                                           # cordon it and terminate its EC2 instance
#
# It reads the same run record setup.sh wrote, so there is nothing to set again. setup.sh
# and run.sh run it with --delete-aws --delete-node themselves when they fail, and so does
# scripts/deadline.sh at the run's clean-up deadline. It takes the run lock first, so it
# never runs beside a setup, a run or another clean up, and it stops before its first
# delete if this shell no longer acts as the account, role, cluster, endpoint, Region and
# kube context setup recorded. Every call it makes gives up on its own, and all of them
# together stop after CLEAN_BUDGET_S seconds.
#
# It does not stop at the first failure. A lookup that fails means "could not determine",
# which is a failure and never "already gone": anything it could not delete or confirm is
# named at the end and makes it exit non-zero. It touches a resource only when that
# resource carries this sample's ManagedBy tag, or sits inside a namespace carrying this
# sample's managed-by label, and leaves anything else alone. The Pod Identity association,
# the local images and the node must also be the exact ones the run record names.
#
# It never removes a shared install or a cluster-wide setting; this sample changes none, so
# there is nothing of that kind to undo. What stays is listed at the end. It needs no cost
# snapshot: refusing to clean up would only leave billing running.
set -uo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
SAMPLE="bubblewrap"
# Every call below shares this one budget, and the cost check reads both numbers from here.
CLEAN_BUDGET_S=2400
# The most times one run record is cleaned up with S3 calls; the cost check counts them.
CLEAN_RUNS_MAX=8

delete_aws=false delete_node=false allow_terminate=false
for arg in "$@"; do
  case "$arg" in
    --delete-aws) delete_aws=true ;;
    --delete-node) delete_node=true ;;
    --allow-instance-termination) allow_terminate=true ;;
    --help|-h) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[[ "$delete_node" != true || "$delete_aws" == true ]] ||
  { echo "--delete-node also needs --delete-aws" >&2; exit 2; }
[[ "$allow_terminate" != true || "$delete_node" == true ]] ||
  { echo "--allow-instance-termination also needs --delete-node" >&2; exit 2; }

failed=0
note_fail() { echo "INCOMPLETE: $*" >&2; failed=1; }
say() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
# shellcheck source=run-lib.sh
. "$SAMPLE_DIR/scripts/run-lib.sh"

# .env first and the run record second, so the record wins: it holds the names the run
# actually created, .env what the next run would use. Which node is the run's, and the
# identity setup acted as, come from the run record alone, never from .env.
if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; . "$SAMPLE_DIR/.env"; set +a; fi
unset NODE_NAME NODE_UID NODE_PROVIDER_ID NODE_CREATED_AT NODE_POOL NODE_AT_START \
  NODECLAIM_NAME NODECLAIM_UID NODECLAIM_CREATED_AT NODECLAIM_POOL RUN_STARTED_AT \
  NOMINATED_NODECLAIMS ACCOUNT_ID CALLER_ROLE_ARN CLUSTER_ARN CLUSTER_ENDPOINT CLEAN_RUNS_DONE
have_record=false
if [[ -e "$STATE_FILE" ]]; then
  state_load || die "$STATE_FILE is not a run record this script can read; touched nothing"
  have_record=true
fi

NAMESPACE="${NAMESPACE:-subagent-security-bubblewrap}"
AWS_REGION="${AWS_REGION:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"

# Without a Region, a regional lookup runs in whichever Region the environment happens to
# name, and comes back with the service's own not-found exception. This script would then
# report resources as "already gone" and exit 0 while they are still there.
[[ -n "$AWS_REGION" ]] ||
  die "AWS_REGION is not set, so a lookup could run in the wrong Region and report a resource that still exists as already gone. Set it in .env, or run ./scripts/setup.sh first so the run record has it."
[[ "$KUBE_CONTEXT" =~ ^[A-Za-z0-9_.:@/-]+$ ]] ||
  die "KUBE_CONTEXT is not set, or is not a context name, so this clean up could act on whichever cluster is current; touched nothing"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION" AWS_MAX_ATTEMPTS=3 AWS_RETRY_MODE=standard

for c in aws jq kubectl; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required"
done

lock_take 0 ||
  die "another setup, run or clean up of this sample holds $LOCK_DIR (process $(cat "$LOCK_DIR/pid" 2>/dev/null || echo unknown)); touched nothing"
trap lock_release EXIT

clean_end=$((SECONDS + CLEAN_BUDGET_S)) out_of_time=false
in_budget() {
  (( SECONDS < clean_end )) && return 0
  [[ "$out_of_time" == true ]] ||
    note_fail "the clean up used its ${CLEAN_BUDGET_S}s; every step after this was skipped"
  out_of_time=true
  return 1
}
# Each Kubernetes request gives up after a minute; each AWS CLI request after 10 seconds
# connecting and 60 reading, three tries at most.
kc() { in_budget || return 1; kubectl --context "$KUBE_CONTEXT" --request-timeout=60s "$@"; }
aws() { in_budget || return 1; command aws --cli-connect-timeout 10 --cli-read-timeout 60 "$@"; }
gone_within() { # <seconds> <arguments for kc get...>: true once the object is gone
  local end=$((SECONDS + $1)) tries=$(( $1 / 10 )) got
  shift
  while (( SECONDS < end && tries-- > 0 )) && in_budget; do
    got="$(kc get "$@" --ignore-not-found -o name 2>/dev/null)" || got=unknown
    [[ -z "$got" ]] && return 0
    sleep 10
  done
  return 1
}

# The identity setup acted as, again, before anything is deleted and again before an
# instance is terminated.
want=""
identity_matches() {
  local now
  now="$(identity_now)" && [[ -n "$now" && "$(jq -cS . <<<"$now")" == "$want" ]]
}
if [[ "$have_record" == true ]]; then
  want="$(jq -cSn --arg a "${ACCOUNT_ID:-}" --arg r "${CALLER_ROLE_ARN:-}" --arg c "${CLUSTER_ARN:-}" \
    --arg e "${CLUSTER_ENDPOINT:-}" --arg g "$AWS_REGION" --arg k "$KUBE_CONTEXT" \
    '{account: $a, role: $r, cluster_arn: $c, endpoint: $e, region: $g, context: $k}')"
  [[ -n "${ACCOUNT_ID:-}" && -n "${CALLER_ROLE_ARN:-}" && -n "${CLUSTER_ARN:-}" && -n "${CLUSTER_ENDPOINT:-}" ]] ||
    die "the run record does not hold the identity setup acted as; touched nothing"
  identity_matches ||
    die "this shell does not act as the account, role, cluster, endpoint, Region and kube context setup recorded ($want), or that could not be read; touched nothing"
  CLEAN_RUNS_DONE=$(( ${CLEAN_RUNS_DONE:-0} + 1 ))
  state_put CLEAN_RUNS_DONE "$CLEAN_RUNS_DONE"
fi

say "1/5 the namespace's own objects"

# Four states, and only one of them lets anything inside the namespace be deleted.
ns_state=unknown ns_gone=false
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
  absent) echo "  namespace $NAMESPACE is already gone."; ns_gone=true ;;
  foreign) note_fail "namespace $NAMESPACE is not this sample's (its managed-by label is not '$SAMPLE'); deleted nothing in it" ;;
  unknown) note_fail "could not determine whether namespace $NAMESPACE exists or whose it is; deleted nothing in it" ;;
  owned)
    # Which NodeClaims EKS Auto Mode launched for this run's pods, read from the
    # namespace's events while they still exist, and kept in the run record.
    if [[ "$have_record" == true ]]; then
      if nominated="$(nominated_claims 2>/dev/null)"; then
        state_put NOMINATED_NODECLAIMS "$(printf '%s\n%s\n' "${NOMINATED_NODECLAIMS:-}" "$nominated" |
          tr ' ' '\n' | grep . | sort -u | tr '\n' ' ' | sed 's/ *$//')"
        state_load
      else
        note_fail "could not read the events in $NAMESPACE, so a NodeClaim launched for this run's pods may be left"
      fi
    fi
    # Inside this sample's own namespace, the namespace label is the ownership check. The
    # analyst pod goes first: it is what holds sandbox capacity other demos on the cluster
    # share. Each object is named exactly, never selected by label.
    for p in pod/analyst pod/ordinary-comparison pod/supplier-api deployment/supplier-api; do
      { kc delete "$p" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null &&
        gone_within 300 "$p" -n "$NAMESPACE"; } || note_fail "could not delete $p in $NAMESPACE"
    done
    if kc delete namespace "$NAMESPACE" --wait=false >/dev/null &&
       gone_within 300 namespace "$NAMESPACE"; then
      ns_gone=true
    else
      note_fail "could not delete namespace $NAMESPACE, or confirm it is gone"
    fi
    ;;
esac

say "2/5 the run's own sandbox node"

# Only with --delete-aws --delete-node, and only after the namespace is confirmed gone;
# clean-node.sh says what else must hold.
# shellcheck source=clean-node.sh
. "$SAMPLE_DIR/scripts/clean-node.sh"
if [[ "$delete_node" != true ]]; then
  echo "  left the node to EKS Auto Mode, which removes it once it is empty; --delete-node deletes it now."
elif [[ "$ns_gone" != true ]]; then
  note_fail "namespace $NAMESPACE is not confirmed gone, so no node was deleted"
elif [[ "$have_record" != true ]]; then
  echo "  there is no run record, so there is no node this clean up can call the run's."
else
  if [[ -n "${NODE_NAME:-}" && "${NODE_AT_START:-}" == true ]]; then
    echo "  the analyst pod ran on node $NODE_NAME, which the cluster had before the run; it is not this run's to delete."
  elif [[ -n "${NODE_NAME:-}" ]]; then
    delete_run_node
  fi
  if [[ -z "${NOMINATED_NODECLAIMS+set}" ]]; then
    note_fail "the run record does not say which NodeClaims were launched for this run's pods, so any such NodeClaim was left"
  else
    for c in $NOMINATED_NODECLAIMS; do
      [[ "$c" == "${NODECLAIM_NAME:-}" ]] || delete_nominated_claim "$c"
    done
    [[ -n "${NODE_NAME:-}$NOMINATED_NODECLAIMS" ]] || echo "  no node was launched for this run's pods."
  fi
fi
# Any other NodeClaim that appeared after the run started is named, never touched: nothing
# ties it to this run. setup.sh refuses a run that has one.
if [[ -f "$TMP_DIR/nodeclaims-at-start.json" ]] &&
   claims="$(kc get nodeclaims -o json 2>/dev/null)" &&
   others="$(jq -r --slurpfile start "$TMP_DIR/nodeclaims-at-start.json" --arg mine "${NODECLAIM_UID:-}" \
     --arg named " ${NOMINATED_NODECLAIMS:-} " \
     '[.items[] | select((.metadata.uid as $u | $start[0] | index($u)) == null)
       | select(.metadata.uid != $mine and ($named | contains(" \(.metadata.name) ") | not))
       | .metadata.name] | join(" ")' <<<"$claims")" &&
   [[ -n "$others" ]]; then
  echo "  NodeClaims that appeared after the run started and are not this run's record, left alone: $others"
fi

say "3/5 the EKS Pod Identity association"

# Only the association the run record names, and only while it is still exactly that one:
# the one association for this namespace and service account, with the recorded id, this
# cluster, the recorded role and this sample's tag. Anything else is left in place.
saved_id="${POD_IDENTITY_ASSOCIATION:-}"
if [[ -z "$CLUSTER_NAME" ]]; then
  note_fail "CLUSTER_NAME is not set, so the Pod Identity association could not be looked up or removed"
else
  assoc="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" --service-account analyst --output json 2>/dev/null)"
  count="$(jq '.associations | length' <<<"$assoc" 2>/dev/null)"
  if [[ -z "$assoc" || -z "$count" ]]; then
    note_fail "could not list the Pod Identity associations for $NAMESPACE/analyst on $CLUSTER_NAME"
  elif [[ "$count" == 0 ]]; then
    echo "  no association for $NAMESPACE/analyst; already gone."
  elif [[ "$count" != 1 ]]; then
    note_fail "there are $count Pod Identity associations for $NAMESPACE/analyst on $CLUSTER_NAME, not the one this run recorded; left them in place"
  elif [[ -z "$saved_id" ]]; then
    note_fail "the run record names no Pod Identity association, so the one for $NAMESPACE/analyst was left in place"
  else
    id="$(jq -r '.associations[0].associationId' <<<"$assoc")"
    detail="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
      --association-id "$saved_id" --output json 2>/dev/null)"
    want_assoc="$(jq -cn --arg i "$saved_id" --arg c "$CLUSTER_NAME" --arg n "$NAMESPACE" \
      --arg r "${ROLE_ARN:-}" --arg m "$SAMPLE" '[$i, $c, $n, "analyst", $r, $m]')"
    if [[ "$id" != "$saved_id" ]]; then
      note_fail "the Pod Identity association for $NAMESPACE/analyst is $id, not the $saved_id this run recorded; left it in place"
    elif [[ -z "$detail" ]]; then
      note_fail "could not read the Pod Identity association $id, so it was left in place"
    elif [[ "$(jq -c '.association | [.associationId, .clusterName, .namespace,
               .serviceAccount, .roleArn, (.tags.ManagedBy // "")]' <<<"$detail" 2>/dev/null)" != "$want_assoc" ]]; then
      note_fail "the Pod Identity association $id no longer matches the run record (its cluster, namespace, service account, role or ManagedBy=$SAMPLE tag); left it in place"
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

say "4/5 the AWS resources"

if [[ "$delete_aws" != true ]]; then
  echo "  kept the bucket, the IAM role and the images; pass --delete-aws to remove them."
else
  bucket="${BUCKET:-}"
  if [[ -z "$bucket" ]]; then
    note_fail "no bucket name in the run record or .env, so the bucket could not be removed"
  elif (( ${CLEAN_RUNS_DONE:-0} > CLEAN_RUNS_MAX )); then
    note_fail "this run's clean up has run ${CLEAN_RUNS_DONE} times, more than the $CLEAN_RUNS_MAX whose S3 requests the cost check counted, so the bucket $bucket was left; its objects expire a day after they were written"
  else
    tags="$(lookup NoSuchBucket s3api get-bucket-tagging --bucket "$bucket" --output json)"; rc=$?
    if [[ "$rc" == 0 ]]; then
      tag="$(jq -r '.TagSet[]? | select(.Key=="ManagedBy") | .Value' <<<"$tags")"
      if [[ "$tag" != "$SAMPLE" ]]; then
        note_fail "the bucket $bucket does not carry ManagedBy=$SAMPLE (found '$tag'); left it alone"
      else
        # One list request and one batch delete: a run writes at most a few objects, and a
        # bucket holding more than one page is not emptied here.
        empty='{}'
        if ! listed="$(aws s3api list-objects-v2 --bucket "$bucket" --max-keys 1000 --no-paginate --output json)"; then
          note_fail "could not list the objects in the bucket $bucket"
        elif [[ "$(jq -r '.IsTruncated // false' <<<"${listed:-$empty}")" != false ]]; then
          note_fail "the bucket $bucket holds more than 1000 objects, more than this sample writes; left it"
        elif [[ "$(jq '.Contents // [] | length' <<<"${listed:-$empty}")" != 0 ]] &&
             ! aws s3api delete-objects --bucket "$bucket" --delete "$(jq -c \
               '{Objects: [.Contents[] | {Key}], Quiet: true}' <<<"$listed")" >/dev/null; then
          note_fail "could not empty the bucket $bucket"
        fi
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

  # The local images this run built, each by the exact reference the run record holds, and
  # only while that reference still names the image id recorded when it was built. An empty
  # id means the run reused an image already in ECR and built nothing here.
  if ! docker_err="$(mktemp "${TMPDIR:-/tmp}/bubblewrap-docker.XXXXXX")"; then
    note_fail "could not make a scratch file, so the local images were not checked or removed"
  else
    for pair in "${SUPPLIER_API_IMAGE:-}|${SUPPLIER_API_LOCAL_IMAGE_ID:-}" \
                "${ANALYST_LOCAL_IMAGE_REF:-}|${ANALYST_LOCAL_IMAGE_ID:-}"; do
      ref="${pair%%|*}" want_id="${pair#*|}"
      [[ -n "$want_id" ]] || continue
      if [[ -z "$ref" ]]; then
        note_fail "the run record has a local image id ($want_id) with no reference; left it alone"
      elif have="$(docker image inspect --format '{{.Id}}' "$ref" 2>"$docker_err")"; then
        if [[ "$have" != "$want_id" ]]; then
          note_fail "the local image $ref is now $have, not the $want_id this run built; left it alone"
        elif ! docker image rm "$ref" >/dev/null 2>&1; then
          note_fail "could not remove the local image $ref"
        elif docker image inspect "$ref" >/dev/null 2>"$docker_err"; then
          note_fail "the local image $ref is still present after the remove"
        elif grep -q 'No such image' "$docker_err"; then
          echo "  removed the local image $ref."
        else
          note_fail "could not confirm the local image $ref was removed"
        fi
      elif grep -q 'No such image' "$docker_err"; then
        echo "  the local image $ref is already gone."
      else
        note_fail "could not determine whether the local image $ref exists; left it alone"
      fi
    done
    rm -f "$docker_err"
  fi
fi

say "5/5 the local run files"

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
