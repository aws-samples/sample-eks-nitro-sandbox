#!/usr/bin/env bash
# clean.sh -- remove what this sample created, and only that.
#
# Usage:
#   ./scripts/clean.sh                      # the cluster objects and the namespace
#   ./scripts/clean.sh --delete-aws         # also the bucket, the IAM role, the ECR
#                                           # repositories and the local images it built
#   ./scripts/clean.sh --delete-aws --delete-node
#                                           # also the sandbox node the run's pod was given
#   ./scripts/clean.sh --delete-aws --delete-node --allow-instance-termination
#                                           # and, if deleting it through EKS fails,
#                                           # terminate its EC2 instance directly
#
# It reads the same run record setup.sh wrote, so there is nothing to set again. setup.sh
# and run.sh run it with --delete-aws --delete-node themselves when they fail, and so does
# scripts/deadline.sh at the run's clean-up deadline.
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
TMP_DIR="$REPO_ROOT/tmp/$SAMPLE"
STATE_FILE="$TMP_DIR/state.env"

delete_aws=false delete_node=false allow_terminate=false
for arg in "$@"; do
  case "$arg" in
    --delete-aws) delete_aws=true ;;
    --delete-node) delete_node=true ;;
    --allow-instance-termination) allow_terminate=true ;;
    --help|-h) sed -n '2,27p' "$0"; exit 0 ;;
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

# .env first and the run record second, so the record wins. The record holds the names the
# run actually created; .env holds what the next run would use, and the two differ exactly
# when someone has changed a name since. Sourced the other way round, a changed .env would
# send this script after a namespace and a bucket that were never created and leave the
# real ones behind.
if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; . "$SAMPLE_DIR/.env"; set +a; fi
# Which node is the run's comes from the run record alone, never from .env.
unset NODE_NAME NODE_UID NODE_PROVIDER_ID NODE_CREATED_AT NODE_POOL NODE_AT_START \
  NODECLAIM_NAME NODECLAIM_UID NODECLAIM_CREATED_AT NODECLAIM_POOL RUN_STARTED_AT
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
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION" AWS_MAX_ATTEMPTS=3 AWS_RETRY_MODE=standard

for c in aws jq kubectl; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required"
done

kc() {
  if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"
  else kubectl "$@"; fi
}
# A read that gives up after a minute, for the node step, so a clean up that cannot reach
# the cluster still reaches its end, says what it could not do, and stays inside the run's
# deadline. Deletes keep their own --timeout.
kr() { kc --request-timeout=60s "$@"; }

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
      if [[ -z "$still" ]]; then ns_gone=true
      else note_fail "namespace $NAMESPACE is still present after the delete"; fi
    else
      note_fail "could not confirm namespace $NAMESPACE was deleted"
    fi
    ;;
esac

say "2/5 the run's own sandbox node"

# Only with --delete-aws --delete-node, only after the namespace is confirmed gone, and only
# the one node the run record names. Every identity in the record must still hold: the
# Node's name, uid, provider id, creation time and NodePool, the same for its NodeClaim,
# and a timeline in which both appeared after the run started and the Node was not on the
# cluster when it did. A pod other than a DaemonSet's or a static one on the node means
# someone else's work is on it, and the node is left alone. Deleting the NodeClaim is the
# EKS Auto Mode way to remove a node; terminating the instance directly happens only with
# --allow-instance-termination, after that fails, and after every check again.
node_why=""
node_matches() { # fresh reads of the Node, its NodeClaim and the pods on it
  local node claim pods foreign want
  if node="$(kr get node "$NODE_NAME" --ignore-not-found -o json 2>/dev/null)"; then :
  else node_why="could not read node $NODE_NAME"; return 1; fi
  if [[ -n "$node" ]]; then
    want="$(jq -cn --arg a "$NODE_UID" --arg b "$NODE_PROVIDER_ID" --arg c "$NODE_CREATED_AT" \
      --arg d "$NODE_POOL" '[$a, $b, $c, $d]')"
    [[ "$(jq -c '[.metadata.uid, .spec.providerID, .metadata.creationTimestamp,
        .metadata.labels["karpenter.sh/nodepool"]]' <<<"$node" 2>/dev/null)" == "$want" ]] ||
      { node_why="node $NODE_NAME no longer matches the run record"; return 1; }
  fi
  if claim="$(kr get nodeclaim "$NODECLAIM_NAME" --ignore-not-found -o json 2>/dev/null)"; then :
  else node_why="could not read NodeClaim $NODECLAIM_NAME"; return 1; fi
  if [[ -n "$claim" ]]; then
    want="$(jq -cn --arg a "$NODECLAIM_UID" --arg b "$NODE_PROVIDER_ID" \
      --arg c "$NODECLAIM_CREATED_AT" --arg d "$NODECLAIM_POOL" '[$a, $b, $c, $d]')"
    [[ "$(jq -c '[.metadata.uid, .status.providerID, .metadata.creationTimestamp,
        .metadata.labels["karpenter.sh/nodepool"]]' <<<"$claim" 2>/dev/null)" == "$want" ]] ||
      { node_why="NodeClaim $NODECLAIM_NAME no longer matches the run record"; return 1; }
  fi
  if pods="$(kr get pods -A --field-selector "spec.nodeName=$NODE_NAME" -o json 2>/dev/null)" &&
     foreign="$(jq -er '[.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed")
       | select(((.metadata.ownerReferences // []) | map(.kind) | index("DaemonSet")) == null)
       | select((.metadata.annotations // {})["kubernetes.io/config.mirror"] == null)
       | "\(.metadata.namespace)/\(.metadata.name)"] | join(" ")' <<<"$pods")"; then :
  else node_why="could not list the pods on node $NODE_NAME"; return 1; fi
  [[ -z "$foreign" ]] || { node_why="other workloads run on node $NODE_NAME: $foreign"; return 1; }
}
# EC2 calls that give up after 10 seconds connecting and 30 reading, three tries at most.
ec2() { aws ec2 --cli-connect-timeout 10 --cli-read-timeout 30 "$@"; }
instance_state() { # prints the instance's state name, or nothing if it could not be read
  ec2 describe-instances --instance-ids "$instance" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null
}
instance_matches() { # the instance's own tags name this cluster, the NodeClaim and its pool
  local tags
  tags="$(ec2 describe-instances --instance-ids "$instance" --output json 2>/dev/null |
    jq -c '[.Reservations[0].Instances[0].Tags // [] | from_entries
      | .["eks:eks-cluster-name"], .["karpenter.sh/nodeclaim"], .["karpenter.sh/nodepool"]]')"
  [[ "$tags" == "$(jq -cn --arg a "$CLUSTER_NAME" --arg b "$NODECLAIM_NAME" \
      --arg c "$NODECLAIM_POOL" '[$a, $b, $c]')" ]] ||
    { node_why="instance $instance does not carry the tags of this cluster's NodeClaim $NODECLAIM_NAME"; return 1; }
}
wait_terminated() { # up to 60 checks, ten seconds apart, and never past ten minutes
  local _ state end=$((SECONDS + 600))
  for _ in $(seq 60); do
    (( SECONDS < end )) || break
    state="$(instance_state)"
    [[ "$state" == terminated ]] && return 0
    sleep 10
  done
  node_why="instance $instance is ${state:-unreadable}, not terminated, after ten minutes"
  return 1
}
delete_run_node() {
  local field instance _ gone=false dry
  for field in NODE_NAME NODE_UID NODE_PROVIDER_ID NODE_CREATED_AT NODE_POOL NODE_AT_START \
      NODECLAIM_NAME NODECLAIM_UID NODECLAIM_CREATED_AT NODECLAIM_POOL RUN_STARTED_AT CLUSTER_NAME; do
    [[ -n "${!field:-}" ]] ||
      { note_fail "the run record has no $field, so no node was deleted"; return; }
  done
  [[ "$NODE_AT_START" == false && "$NODE_POOL" == "$NODECLAIM_POOL" &&
     "$RUN_STARTED_AT" < "$NODECLAIM_CREATED_AT" && ! "$NODE_CREATED_AT" < "$NODECLAIM_CREATED_AT" ]] ||
    { note_fail "the run record does not show node $NODE_NAME appearing after the run started, so it was left in place"; return; }
  [[ "$NODE_PROVIDER_ID" =~ ^aws:///[a-z0-9-]+/(i-[0-9a-f]{8,17})$ ]] ||
    { note_fail "node $NODE_NAME's provider id is not an EC2 instance; left it in place"; return; }
  instance="${BASH_REMATCH[1]}"
  node_matches || { note_fail "$node_why; left it in place"; return; }

  kr delete nodeclaim "$NODECLAIM_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 ||
    echo "  the NodeClaim delete was not accepted; waiting to see whether the node goes anyway"
  local end=$((SECONDS + 600))
  for _ in $(seq 60); do
    (( SECONDS < end )) || break
    if [[ -z "$(kr get nodeclaim "$NODECLAIM_NAME" --ignore-not-found -o name 2>/dev/null || echo unknown)" &&
          -z "$(kr get node "$NODE_NAME" --ignore-not-found -o name 2>/dev/null || echo unknown)" ]]; then
      gone=true; break
    fi
    sleep 10
  done
  if [[ "$gone" == true ]] && wait_terminated; then
    echo "  deleted node $NODE_NAME through its NodeClaim; instance $instance is terminated."
    return
  fi
  [[ "$gone" == true ]] || node_why="NodeClaim $NODECLAIM_NAME and node $NODE_NAME are still there after ten minutes"
  if [[ "$allow_terminate" != true ]]; then
    note_fail "$node_why; pass --allow-instance-termination to terminate the instance directly"
    return
  fi
  dry="$(ec2 terminate-instances --instance-ids "$instance" --dry-run 2>&1)"
  grep -q 'DryRunOperation' <<<"$dry" ||
    { note_fail "$node_why, and terminating instance $instance directly is not permitted here; left it"; return; }
  if ! { node_matches && instance_matches; }; then
    note_fail "$node_why; left instance $instance in place"
    return
  fi
  ec2 terminate-instances --instance-ids "$instance" >/dev/null 2>&1 ||
    { note_fail "could not terminate instance $instance"; return; }
  wait_terminated || { note_fail "$node_why"; return; }
  echo "  terminated instance $instance directly, after the NodeClaim delete did not finish."
}
if [[ "$delete_node" != true ]]; then
  echo "  left the node to EKS Auto Mode, which removes it once it is empty; --delete-node deletes it now."
elif [[ "$ns_gone" != true ]]; then
  note_fail "namespace $NAMESPACE is not confirmed gone, so no node was deleted"
else
  delete_run_node
fi
# Any other NodeClaim that appeared after the run started is named, never touched: nothing
# ties it to this run. setup.sh refuses a run that has one.
if [[ -f "$TMP_DIR/nodeclaims-at-start.json" ]] &&
   claims="$(kr get nodeclaims -o json 2>/dev/null)" &&
   others="$(jq -r --slurpfile start "$TMP_DIR/nodeclaims-at-start.json" --arg mine "${NODECLAIM_UID:-}" \
     '[.items[] | select((.metadata.uid as $u | $start[0] | index($u)) == null)
       | select(.metadata.uid != $mine) | .metadata.name] | join(" ")' <<<"$claims")" &&
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
    want="$(jq -cn --arg i "$saved_id" --arg c "$CLUSTER_NAME" --arg n "$NAMESPACE" \
      --arg r "${ROLE_ARN:-}" --arg m "$SAMPLE" '[$i, $c, $n, "analyst", $r, $m]')"
    if [[ "$id" != "$saved_id" ]]; then
      note_fail "the Pod Identity association for $NAMESPACE/analyst is $id, not the $saved_id this run recorded; left it in place"
    elif [[ -z "$detail" ]]; then
      note_fail "could not read the Pod Identity association $id, so it was left in place"
    elif [[ "$(jq -c '.association | [.associationId, .clusterName, .namespace,
               .serviceAccount, .roleArn, (.tags.ManagedBy // "")]' <<<"$detail" 2>/dev/null)" != "$want" ]]; then
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

  # The local images this run built, each by the exact reference the run record holds, and
  # only while that reference still names the image id recorded when it was built. An empty
  # id means the run reused an image already in ECR and built nothing here.
  if ! docker_err="$(mktemp "${TMPDIR:-/tmp}/bubblewrap-docker.XXXXXX")"; then
    note_fail "could not make a scratch file, so the local images were not checked or removed"
  else
    for pair in "${SUPPLIER_API_IMAGE:-}|${SUPPLIER_API_LOCAL_IMAGE_ID:-}" \
                "${ANALYST_IMAGE:-}|${ANALYST_LOCAL_IMAGE_ID:-}"; do
      ref="${pair%%|*}" want="${pair#*|}"
      [[ -n "$want" ]] || continue
      if [[ -z "$ref" ]]; then
        note_fail "the run record has a local image id ($want) with no reference; left it alone"
      elif have="$(docker image inspect --format '{{.Id}}' "$ref" 2>"$docker_err")"; then
        if [[ "$have" != "$want" ]]; then
          note_fail "the local image $ref is now $have, not the $want this run built; left it alone"
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
