#!/usr/bin/env bash
# Remove everything the sample created, and only that. Deletes in reverse order of
# creation, touches only resources marked ManagedBy=coding-agents-for-developers, and
# never removes a shared install (agent-sandbox, the EFS CSI driver, network-policy
# enforcement). Exits non-zero if it skipped something or could not confirm a delete.
set -uo pipefail

SAMPLE=coding-agents-for-developers
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1090
set -a; . "$ROOT/.env"; set +a

CLUSTER_NAME="${CLUSTER_NAME:?set CLUSTER_NAME}"
AWS_REGION="${AWS_REGION:?set AWS_REGION}"
NAMESPACE="${NAMESPACE:-coding-agents-for-developers}"
KCTL=(kubectl --context "$CLUSTER_NAME")
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
APP_ROLE="$SAMPLE-app"; MOUNT_ROLE="$SAMPLE-mount"; BEDROCK_ROLE="$SAMPLE-bedrock"; SYNC_ROLE="$SAMPLE-s3files-sync"
SG_NAME="$SAMPLE-nfs"
FAIL=0
say() { printf '\n==> %s\n' "$*"; }
note_fail() { echo "INCOMPLETE: $*" >&2; FAIL=1; }

# Confirm the namespace is the sample's before deleting anything inside it.
if "${KCTL[@]}" get namespace "$NAMESPACE" >/dev/null 2>&1; then
  owned="$("${KCTL[@]}" get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null || true)"
  [[ "$owned" == "$SAMPLE" ]] || { echo "namespace $NAMESPACE is not labelled for $SAMPLE; refusing." >&2; exit 2; }

  say "Warm pools first (so they stop booting replacements), then claims, then the app"
  "${KCTL[@]}" -n "$NAMESPACE" delete sandboxwarmpool -l app.kubernetes.io/part-of=$SAMPLE --ignore-not-found
  "${KCTL[@]}" -n "$NAMESPACE" delete sandboxclaim -l app.kubernetes.io/part-of=$SAMPLE --ignore-not-found
  "${KCTL[@]}" -n "$NAMESPACE" delete sandboxtemplate -l app.kubernetes.io/part-of=$SAMPLE --ignore-not-found
  "${KCTL[@]}" -n "$NAMESPACE" delete applicationnetworkpolicy -l app.kubernetes.io/part-of=$SAMPLE --ignore-not-found
  "${KCTL[@]}" -n "$NAMESPACE" delete deploy,svc -l app.kubernetes.io/part-of=$SAMPLE --ignore-not-found
fi

# Pod Identity associations (only this sample's namespace/service accounts).
say "Pod Identity associations"
for sa in agent-app agent-session; do
  aid="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --namespace "$NAMESPACE" \
    --service-account "$sa" --region "$AWS_REGION" --query 'associations[0].associationId' --output text 2>/dev/null || true)"
  [[ "$aid" == a-* ]] && aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --association-id "$aid" --region "$AWS_REGION" >/dev/null 2>&1 || true
done

# S3 Files: access points, mount targets, file system.
say "S3 Files access points, mount targets, file system"
FS_ID="${S3_FILES_FS_ID:-$(aws s3files list-file-systems --region "$AWS_REGION" \
  --query "fileSystems[?name=='$SAMPLE'].fileSystemId | [0]" --output text 2>/dev/null)}"
# Before touching its access points and mount targets, confirm the file system still exists
# and is the sample's. An explicit not-found means it is already gone (e.g. a stale id left in
# .env by an earlier run), which is not a failure and must not start a 10-minute wait for
# mount targets that will never drain. Any other lookup error is "could not determine".
fs_ours=
if [[ -n "$FS_ID" && "$FS_ID" != "None" ]]; then
  if fs_err="$(aws s3files get-file-system --file-system-id "$FS_ID" --region "$AWS_REGION" \
      --query status --output text 2>&1)"; then
    fs_owner="$(aws s3files list-tags-for-resource --resource-id "$FS_ID" --region "$AWS_REGION" \
      --query "tags[?key=='ManagedBy'].value | [0]" --output text 2>/dev/null || true)"
    if [[ "$fs_owner" == "$SAMPLE" ]]; then
      fs_ours=yes
    else
      note_fail "file system $FS_ID is not tagged ManagedBy=$SAMPLE (found: ${fs_owner:-none}); left untouched"
    fi
  else
    case "$fs_err" in
      *ResourceNotFoundException*) echo "file system $FS_ID is already gone" ;;
      *) note_fail "file system $FS_ID: lookup failed, not confirmed gone ($(printf '%s' "$fs_err" | head -1))" ;;
    esac
  fi
fi
if [[ -n "$fs_ours" ]]; then
  for ap in $(aws s3files list-access-points --file-system-id "$FS_ID" --region "$AWS_REGION" \
    --query 'accessPoints[].accessPointId' --output text 2>/dev/null); do
    aws s3files delete-access-point --access-point-id "$ap" --region "$AWS_REGION" >/dev/null 2>&1 || note_fail "access point $ap"
  done
  for mt in $(aws s3files list-mount-targets --file-system-id "$FS_ID" --region "$AWS_REGION" \
    --query 'mountTargets[].mountTargetId' --output text 2>/dev/null); do
    aws s3files delete-mount-target --mount-target-id "$mt" --region "$AWS_REGION" >/dev/null 2>&1 || note_fail "mount target $mt"
  done
  # Wait for the mount targets to drain before deleting the file system. A FAILED lookup
  # must not read as "0 left": default to a non-zero sentinel on lookup failure so a
  # transient error does not look like the mount targets are gone.
  left=1
  for i in $(seq 1 60); do
    if left="$(aws s3files list-mount-targets --file-system-id "$FS_ID" --region "$AWS_REGION" --query 'length(mountTargets)' --output text 2>/dev/null)"; then
      [[ "$left" == "0" ]] && break
    else
      left=1   # lookup failed: not confirmed drained
    fi
    sleep 10
  done
  if [[ "$left" == "0" ]]; then
    aws s3files delete-file-system --file-system-id "$FS_ID" --region "$AWS_REGION" >/dev/null 2>&1 || note_fail "file system $FS_ID"
  else
    note_fail "mount targets for $FS_ID did not drain (last count: $left); not deleting the file system"
  fi
fi

# Bucket (owned by this sample: tagged ManagedBy). Re-check the tag before deleting.
# Distinguish "bucket gone" (a 404 from head-bucket) from a lookup FAILURE (any other
# error): the latter must not silently skip cleanup as if the bucket were already gone.
say "Bucket"
bucket_present=
if [[ -n "${S3_BUCKET_NAME:-}" ]]; then
  head_err="$(aws s3api head-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" 2>&1)" && bucket_present=yes || {
    case "$head_err" in
      *404*|*"Not Found"*) bucket_present= ;;   # genuinely gone
      *) note_fail "bucket $S3_BUCKET_NAME: head-bucket lookup failed (not confirmed gone)" ;;
    esac
  }
fi
if [[ -n "$bucket_present" ]]; then
  owner="$(aws s3api get-bucket-tagging --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" \
    --query "TagSet[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null || true)"
  if [[ "$owner" == "$SAMPLE" ]]; then
    # Empty the bucket, then delete it. The bucket is versioned, so emptying means removing
    # BOTH live object versions AND delete markers, and a long-lived session bucket holds
    # far more than one API page of them. Loop: each pass lists at most 1000 entries
    # (Versions and DeleteMarkers combined), deletes them in ONE delete-objects call, and
    # repeats until the listing comes back empty. `--max-keys 1000 --no-paginate` is
    # load-bearing: --max-keys bounds ONE server response to 1000 entries (Versions and
    # DeleteMarkers count toward the same limit), which keeps each page within
    # delete-objects' 1000-key cap, and --no-paginate stops the CLI from stitching several
    # server pages into one response (without it the CLI walks the whole bucket, which on
    # tens of thousands of versions is slow enough to look hung, and returns more than 1000
    # keys for delete-objects to reject). A `s3 rm --recursive` first would be worse than
    # useless here: on a versioned bucket it only adds a delete marker per object.
    emptied=
    for pass in $(seq 1 1000); do
      # A FAILED listing must not read as "empty bucket". Capture the call's status; a
      # failure is a real error (not "already drained"), so report and stop.
      if ! page="$(aws s3api list-object-versions --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" \
        --max-keys 1000 --no-paginate \
        --query '{Objects: [Versions, DeleteMarkers][][].{Key:Key,VersionId:VersionId}}' \
        --output json 2>/dev/null)"; then
        note_fail "bucket $S3_BUCKET_NAME: list-object-versions failed on pass $pass"
        break
      fi
      # Count the entries. The parser prints the count on well-formed JSON and exits
      # NON-ZERO on malformed/empty input, so a parse failure is told apart from a real
      # empty page (Objects null/[] -> 0) rather than both looking like "drained".
      if ! n="$(printf '%s' "$page" | python3 -c 'import json,sys
d = json.load(sys.stdin)
print(len((d or {}).get("Objects") or []))' 2>/dev/null)"; then
        note_fail "bucket $S3_BUCKET_NAME: could not parse list-object-versions output on pass $pass"
        break
      fi
      [[ "$n" == "0" ]] && { emptied=yes; break; }
      # One delete-objects call for this page. A failed call is real (not "already gone"),
      # so report it and stop. delete-objects also reports per-key failures in its `Errors`
      # list while exiting 0, so keep its JSON output and fail on a non-empty Errors too.
      if ! del_out="$(printf '%s' "$page" | aws s3api delete-objects --bucket "$S3_BUCKET_NAME" \
          --region "$AWS_REGION" --delete file:///dev/stdin --output json 2>&1)"; then
        note_fail "bucket $S3_BUCKET_NAME: delete-objects failed on pass $pass"
        break
      fi
      if ! nerr="$(printf '%s' "$del_out" | python3 -c 'import json,sys
d = json.load(sys.stdin)
print(len((d or {}).get("Errors") or []))' 2>/dev/null)"; then
        note_fail "bucket $S3_BUCKET_NAME: could not parse delete-objects output on pass $pass"
        break
      fi
      if [[ "$nerr" != "0" ]]; then
        note_fail "bucket $S3_BUCKET_NAME: delete-objects left $nerr object(s) undeleted on pass $pass"
        break
      fi
    done
    if [[ -n "$emptied" ]]; then
      aws s3api delete-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" >/dev/null 2>&1 \
        || note_fail "bucket $S3_BUCKET_NAME"
    else
      note_fail "bucket $S3_BUCKET_NAME not emptied (see above); not deleting it"
    fi
  else
    note_fail "bucket $S3_BUCKET_NAME is not tagged ManagedBy=$SAMPLE; left untouched"
  fi
fi

# IAM roles (inline policies then the role). Confirm deletion by the error code: only an
# explicit NoSuchEntity means gone. Any other get-role failure (throttle, denied, network)
# is "could not determine", which is a failure, not success.
say "IAM roles"
for role in "$APP_ROLE" "$MOUNT_ROLE" "$BEDROCK_ROLE" "$SYNC_ROLE"; do
  # Delete only a role the sample made: it carries ManagedBy=$SAMPLE (setup.sh tags every
  # role it creates). A role of the same name without the tag belongs to someone else and is
  # left alone. An explicit NoSuchEntity means the role is already gone.
  if role_owner="$(aws iam list-role-tags --role-name "$role" \
      --query "Tags[?Key=='ManagedBy'].Value | [0]" --output text 2>&1)"; then
    if [[ "$role_owner" != "$SAMPLE" ]]; then
      note_fail "IAM role $role is not tagged ManagedBy=$SAMPLE (found: ${role_owner:-none}); left untouched"
      continue
    fi
  else
    case "$role_owner" in
      *NoSuchEntity*) continue ;;   # already gone
      *) note_fail "IAM role $role: tag lookup failed, left untouched ($(printf '%s' "$role_owner" | head -1))"; continue ;;
    esac
  fi
  for p in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$role" --policy-name "$p" >/dev/null 2>&1 || true
  done
  aws iam delete-role --role-name "$role" >/dev/null 2>&1 || true
  if get_err="$(aws iam get-role --role-name "$role" 2>&1)"; then
    note_fail "IAM role $role still present"
  else
    case "$get_err" in
      *NoSuchEntity*) : ;;   # confirmed gone
      *) note_fail "IAM role $role: could not confirm deletion ($(printf '%s' "$get_err" | head -1))" ;;
    esac
  fi
done

# Security group (after the mount targets' ENIs are gone). Find only the sample's own
# group -- filter on the ManagedBy tag as well as the name, so a same-named group another
# demo owns is never deleted here.
say "Security group"
VPC="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query cluster.resourcesVpcConfig.vpcId --output text 2>/dev/null || true)"
# Distinguish a successful "no such group" (empty/None) from a FAILED lookup: a failed
# describe must not silently skip the security group as if it were already gone.
if SG_ID="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=$SG_NAME" "Name=tag:ManagedBy,Values=$SAMPLE" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"; then :; else
  note_fail "security group lookup for $SG_NAME failed (not confirmed gone)"; SG_ID=""
fi
if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
  for i in $(seq 1 30); do aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" >/dev/null 2>&1 && break; sleep 10; done
  # Confirm by error code: only an explicit "not found" means gone.
  if desc_err="$(aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$AWS_REGION" 2>&1)"; then
    note_fail "security group $SG_ID still present"
  else
    case "$desc_err" in
      *InvalidGroup.NotFound*|*does\ not\ exist*) : ;;   # confirmed gone
      *) note_fail "security group $SG_ID: could not confirm deletion ($(printf '%s' "$desc_err" | head -1))" ;;
    esac
  fi
fi

# ECR repositories. Delete only a repository the sample made: build-images.sh tags each one
# ManagedBy=$SAMPLE when it creates it. An explicit RepositoryNotFoundException means already
# gone; any other lookup error, or a repository without the tag, is reported and left alone.
say "ECR repositories"
for name in base claude-code codex kiro-cli opencode pi oh-my-pi app; do
  repo="$SAMPLE-$name"
  if repo_arn="$(aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" \
      --query 'repositories[0].repositoryArn' --output text 2>&1)"; then
    repo_owner="$(aws ecr list-tags-for-resource --resource-arn "$repo_arn" --region "$AWS_REGION" \
      --query "tags[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null || true)"
    if [[ "$repo_owner" == "$SAMPLE" ]]; then
      aws ecr delete-repository --repository-name "$repo" --region "$AWS_REGION" --force >/dev/null 2>&1 \
        || note_fail "ECR repository $repo"
    else
      note_fail "ECR repository $repo is not tagged ManagedBy=$SAMPLE (found: ${repo_owner:-none}); left untouched"
    fi
  else
    case "$repo_arn" in
      *RepositoryNotFoundException*) : ;;   # already gone
      *) note_fail "ECR repository $repo: lookup failed, left untouched ($(printf '%s' "$repo_arn" | head -1))" ;;
    esac
  fi
done

# Cluster-scoped RBAC. rbac.yaml creates one ClusterRole and its ClusterRoleBinding (the app
# reads node labels for the mount's AZ id). Deleting the namespace does not remove
# cluster-scoped objects, so delete each by its exact name, and only when it carries the
# sample's part-of label. An explicit NotFound means already gone.
say "Cluster-scoped RBAC"
for kind in clusterrolebinding clusterrole; do
  obj="$SAMPLE-node-reader"
  if obj_owner="$("${KCTL[@]}" get "$kind" "$obj" \
      -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>&1)"; then
    if [[ "$obj_owner" == "$SAMPLE" ]]; then
      "${KCTL[@]}" delete "$kind" "$obj" --ignore-not-found >/dev/null 2>&1 || note_fail "$kind $obj"
    else
      note_fail "$kind $obj is not labelled app.kubernetes.io/part-of=$SAMPLE (found: ${obj_owner:-none}); left untouched"
    fi
  else
    case "$obj_owner" in
      *NotFound*) : ;;   # already gone
      *) note_fail "$kind $obj: lookup failed, left untouched ($(printf '%s' "$obj_owner" | head -1))" ;;
    esac
  fi
done

# The namespace last. (On this host `kubectl delete namespace` may be blocked; if so the
# empty namespace is left for you to remove, and this is reported.) Confirm it is actually
# gone rather than trusting that the delete request was accepted: a namespace can sit in
# Terminating, and the delete itself may be blocked on this host.
say "Namespace"
if "${KCTL[@]}" delete namespace "$NAMESPACE" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1; then
  # Confirm it is really gone. A successful get means it is still present (Terminating); a
  # get that FAILS is only confirmation when the error is an explicit NotFound -- any other
  # error (auth, connectivity, wrong context) is "could not determine", not "gone".
  if ns_err="$("${KCTL[@]}" get namespace "$NAMESPACE" 2>&1)"; then
    note_fail "namespace $NAMESPACE still present after delete (Terminating?)"
  else
    case "$ns_err" in
      *NotFound*) : ;;   # confirmed gone (kubectl prints "Error from server (NotFound): ...")
      *) note_fail "namespace $NAMESPACE: could not confirm deletion ($(printf '%s' "$ns_err" | head -1))" ;;
    esac
  fi
else
  note_fail "could not delete namespace $NAMESPACE; remove it by hand: kubectl --context $CLUSTER_NAME delete namespace $NAMESPACE"
fi

echo
if [[ "$FAIL" == "0" ]]; then
  echo "Clean up complete. Shared installs (agent-sandbox, the EFS CSI driver, network"
  echo "policy enforcement) were left in place; remove them only if nothing else uses them."
else
  echo "Clean up INCOMPLETE: see the INCOMPLETE lines above." >&2
fi
exit "$FAIL"
