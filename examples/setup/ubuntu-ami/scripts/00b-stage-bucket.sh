#!/usr/bin/env bash
# 00b-stage-bucket.sh: the per-run S3 staging bucket that carries this run's files to the build
# host (the sample's scripts), so nothing is pushed through an SSM shell. The build host downloads
# the runtime release, the guest image and Firecracker from their public locations itself. Runs on
# the operator's workstation with the operator's credentials; setup.sh calls it with RUN_ID set.
#
#   RUN_ID=<id> scripts/00b-stage-bucket.sh create <file>...
#       create the bucket, harden it, upload each file under <run-id>/, and give this run's
#       build role read on that prefix only; writes STAGE_BUCKET to $RUN_STATE_DIR/stage.env
#       (a failure at any step after the bucket exists removes what this call created)
#   RUN_ID=<id> scripts/00b-stage-bucket.sh revoke <bucket> <file-name>...
#       once the build host has verified its copies, and only when the bucket and the build role
#       carry this run's two tags and the role's staging policy is exactly this run's read for
#       this bucket: delete the staged objects and that policy, then CONFIRM both are gone.
#       Otherwise it changes nothing and exits 1. Any failure, or anything still present,
#       is written to $RUN_STATE_DIR/stage-residue.txt and the command exits 1 (setup.sh stops);
#       it never reports a revocation it could not confirm. The empty bucket stays for clean.sh.
#
# The bucket, created fresh per run:
#   * named <RESOURCE_PREFIX>-stage-<RUN_ID>-<random>, so no name is reused;
#   * tagged ManagedBy=<RESOURCE_PREFIX> and RunId=<RUN_ID> right after creation (clean.sh
#     deletes a bucket only when it carries both);
#   * S3 Block Public Access on (all four settings), default encryption SSE-S3, and the TLS-only
#     bucket policy in deploy/s3-stage-bucket-policy.json;
#   * every call passes --expected-bucket-owner, so nothing is written to or read from a bucket
#     another account owns under the same name;
#   * every upload carries its SHA-256, which S3 checks on receipt; the build host checks it
#     again after download (setup.sh).
# The build-host role's read is deploy/iam-build-host-policy.json rendered for this bucket and
# run, as the per-run inline policy <RESOURCE_PREFIX>-<RUN_ID>-stage-read: s3:GetObject on
# <bucket>/<RUN_ID>/* and s3:ListBucket for that prefix only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
require_run_id
DEPLOY_DIR="$HERE/../deploy"
mkdir -p "$RUN_STATE_DIR"

render() { render_policy "$@"; }   # scripts/lib/common.sh
b64_sha256() { python3 -c 'import base64,hashlib,sys; h=hashlib.sha256(); f=open(sys.argv[1],"rb"); [h.update(c) for c in iter(lambda: f.read(1<<20), b"")]; print(base64.b64encode(h.digest()).decode())' "$1"; }
caller_account() {
  local a
  a=$(aws sts get-caller-identity --output json | json_get 'd["Account"]') || return 1
  [[ "$a" =~ ^[0-9]{12}$ ]] || return 1
  printf '%s\n' "$a"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  create)
    [ $# -gt 0 ] || die "create: no files to stage"
    account=$(caller_account) || die "could not read the caller's account (sts get-caller-identity)"
    rand=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
    bucket="${STAGE_BUCKET_PREFIX}-${rand}"
    require_name "S3 bucket" "$bucket" 63 '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'
    owner=(--expected-bucket-owner "$account")

    log "creating staging bucket $bucket in $AWS_REGION"
    if [ "$AWS_REGION" = us-east-1 ]; then
      aws s3api create-bucket --bucket "$bucket" --region "$AWS_REGION" >/dev/null
    else
      aws s3api create-bucket --bucket "$bucket" --region "$AWS_REGION" \
        --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
    fi
    # From here until the last step succeeds, any failure removes what this call created (the
    # read policy, the uploaded objects, the bucket) before the script exits; setup.sh's own
    # guard takes over only after create returns. Anything the rollback cannot remove is
    # written to stage-residue.txt and the bucket name stays in stage.env for clean.sh.
    rb_bucket="$bucket"; rb_keys=(); rb_policy=0
    rollback_create() {
      local rc=$? left=() k e
      [ -n "${rb_bucket:-}" ] || return 0
      e=$(mktemp)
      warn "staging create failed (exit $rc); removing what this call created in $rb_bucket"
      if [ "$rb_policy" = 1 ]; then
        aws iam delete-role-policy --role-name "$BUILD_ROLE_NAME" --policy-name "$STAGE_POLICY_NAME" --output json >/dev/null 2>"$e" \
          || aws_err_is "$e" NoSuchEntity \
          || left+=("inline policy $STAGE_POLICY_NAME on $BUILD_ROLE_NAME: delete failed: $(head -n 1 "$e")")
      fi
      for k in "${rb_keys[@]}"; do
        aws s3api delete-object --bucket "$rb_bucket" --key "$k" --region "$AWS_REGION" "${owner[@]}" --output json >/dev/null 2>"$e" \
          || left+=("object s3://$rb_bucket/$k: delete failed: $(head -n 1 "$e")")
      done
      if [ "${#left[@]}" -eq 0 ] && aws s3api delete-bucket --bucket "$rb_bucket" --region "$AWS_REGION" "${owner[@]}" --output json >/dev/null 2>"$e"; then
        rm -f "$RUN_STATE_DIR/stage.env"
      else
        left+=("bucket $rb_bucket: not deleted${left[*]:+ (it still holds the items above)}: $(head -n 1 "$e")")
      fi
      rm -f "$e"
      if [ "${#left[@]}" -gt 0 ]; then
        printf '%s\n' "${left[@]}" > "$RUN_STATE_DIR/stage-residue.txt"
        warn "the rollback left: ${left[*]} (recorded in $RUN_STATE_DIR/stage-residue.txt; run ./clean.sh --dry-run)"
      else
        log "rollback: removed bucket $rb_bucket and everything this call put in it"
      fi
      return "$rc"
    }
    trap 'rollback_create' EXIT
    # Record it before anything else can fail, so clean.sh and a re-run know its name.
    printf 'export STAGE_BUCKET=%q\nexport STAGE_ACCOUNT=%q\nexport STAGE_RUN_ID=%q\n' "$bucket" "$account" "$RUN_ID" > "$RUN_STATE_DIR/stage.env"
    aws s3api put-bucket-tagging --bucket "$bucket" --region "$AWS_REGION" "${owner[@]}" \
      --tagging "TagSet=[{Key=${TAGS_OWNER_KEY},Value=${TAGS_OWNER_VALUE}},{Key=${TAGS_RUN_KEY},Value=${RUN_ID}},{Key=Name,Value=${bucket}}]"
    aws s3api put-public-access-block --bucket "$bucket" --region "$AWS_REGION" "${owner[@]}" \
      --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    aws s3api put-bucket-encryption --bucket "$bucket" --region "$AWS_REGION" "${owner[@]}" \
      --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    aws s3api put-bucket-policy --bucket "$bucket" --region "$AWS_REGION" "${owner[@]}" \
      --policy "$(render "$DEPLOY_DIR/s3-stage-bucket-policy.json" "$bucket")"
    log "bucket $bucket: tagged ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} ${TAGS_RUN_KEY}=${RUN_ID}; Block Public Access on; SSE-S3; TLS-only policy"

    for f in "$@"; do
      [ -s "$f" ] || die "nothing to stage at $f"
      key="$RUN_ID/$(basename "$f")"
      log "uploading $(basename "$f") to s3://$bucket/$key (S3 checks its SHA-256 on receipt)"
      rb_keys+=("$key")   # before the call: a failed upload may still have written the object
      aws s3api put-object --bucket "$bucket" --key "$key" --body "$f" --region "$AWS_REGION" "${owner[@]}" \
        --checksum-algorithm SHA256 --checksum-sha256 "$(b64_sha256 "$f")" >/dev/null
    done

    log "granting $BUILD_ROLE_NAME read on s3://$bucket/$RUN_ID/ only ($STAGE_POLICY_NAME)"
    rb_policy=1
    aws iam put-role-policy --role-name "$BUILD_ROLE_NAME" --policy-name "$STAGE_POLICY_NAME" \
      --policy-document "$(render "$DEPLOY_DIR/iam-build-host-policy.json" "$bucket")"
    # Committed: setup.sh's revoke guard owns the objects and the policy from here.
    rb_bucket=""; trap - EXIT
    echo "STAGE_BUCKET=$bucket"
    ;;
  revoke)
    bucket="${1:?usage: revoke <bucket> <file-name>...}"; shift
    [[ "$bucket" == "${STAGE_BUCKET_PREFIX}-"* ]] || die "bucket $bucket is not this run's staging bucket (${STAGE_BUCKET_PREFIX}-*)"
    residue=()
    err=$(mktemp); trap 'rm -f "$err"' EXIT
    # bucket_ours / role_ours: read the bucket's two tags (role_ours: the build role's two tags and
    # its staging policy's document) again; print nothing and return 0 while they are still this
    # run's, else print why not and return 1.
    bucket_ours() {
      local t
      t=$(aws s3api get-bucket-tagging --bucket "$bucket" --region "$AWS_REGION" --expected-bucket-owner "$account" --output json 2>"$err") \
        || { echo "could not read the tags of bucket $bucket: $(head -n 1 "$err")"; return 1; }
      printf '%s' "$t" | json_pick 'd.get("TagSet", [])' | tags_match \
        || { echo "bucket $bucket does not carry ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} and ${TAGS_RUN_KEY}=${RUN_ID}"; return 1; }
    }
    role_ours() {
      local t
      t=$(aws iam list-role-tags --role-name "$BUILD_ROLE_NAME" --output json 2>"$err") \
        || { echo "could not read the tags of role $BUILD_ROLE_NAME: $(head -n 1 "$err")"; return 1; }
      printf '%s' "$t" | json_pick 'd.get("Tags", [])' | tags_match \
        || { echo "role $BUILD_ROLE_NAME does not carry ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} and ${TAGS_RUN_KEY}=${RUN_ID}"; return 1; }
      t=$(aws iam get-role-policy --role-name "$BUILD_ROLE_NAME" --policy-name "$STAGE_POLICY_NAME" --output json 2>"$err") \
        || { echo "could not read inline policy $STAGE_POLICY_NAME of $BUILD_ROLE_NAME: $(head -n 1 "$err")"; return 1; }
      printf '%s' "$t" | role_policy_is "$(render "$DEPLOY_DIR/iam-build-host-policy.json" "$bucket")" \
        || { echo "inline policy $STAGE_POLICY_NAME of $BUILD_ROLE_NAME is not this run's read for s3://$bucket/$RUN_ID/"; return 1; }
    }
    fail_residue() { # record what is left, say so, exit 1
      printf '%s\n' "${residue[@]}" > "$RUN_STATE_DIR/stage-residue.txt"
      printf 'FAIL: staging revocation incomplete (recorded in %s):\n' "$RUN_STATE_DIR/stage-residue.txt" >&2
      printf '  %s\n' "${residue[@]}" >&2
      exit 1
    }
    # Ownership first, and nothing is deleted unless all of it holds: the bucket and the build
    # role carry this run's ManagedBy and RunId, and the role's staging policy is exactly this
    # run's read for this bucket (its bucket and its <RUN_ID>/ prefix). Missing, mismatched or
    # unreadable stops here, with nothing changed.
    account=$(caller_account 2>"$err") || die "revoke: could not read the caller's account; nothing was changed: $(head -n 1 "$err")"
    why=$(bucket_ours) || die "revoke: $why; nothing was changed"
    why=$(role_ours) || die "revoke: $why; nothing was changed"
    objs=("$@")
    for i in "${!objs[@]}"; do
      # The bucket's two tags again right before each delete: a bucket re-tagged or unreadable
      # stops the revoke here, with this object, the ones after it and the policy left in place.
      if ! why=$(bucket_ours); then
        for name in "${objs[@]:i}"; do residue+=("object s3://$bucket/$RUN_ID/$name: not deleted: $why"); done
        residue+=("inline policy $STAGE_POLICY_NAME on $BUILD_ROLE_NAME: not deleted: the revoke stopped first")
        fail_residue
      fi
      name="${objs[$i]}"
      aws s3api delete-object --bucket "$bucket" --key "$RUN_ID/$name" --region "$AWS_REGION" \
        --expected-bucket-owner "$account" --output json >/dev/null 2>"$err" \
        || residue+=("object s3://$bucket/$RUN_ID/$name: delete failed: $(head -n 1 "$err")")
    done
    if left=$(aws s3api list-objects-v2 --bucket "$bucket" --prefix "$RUN_ID/" --region "$AWS_REGION" \
                --expected-bucket-owner "$account" --output json 2>"$err"); then
      for name in "$@"; do
        printf '%s' "$left" | json_get '[o["Key"] for o in d.get("Contents", [])]' | grep -qxF -- "$RUN_ID/$name" \
          && residue+=("object s3://$bucket/$RUN_ID/$name: still present after delete")
      done
    else
      residue+=("objects under s3://$bucket/$RUN_ID/: could not confirm they are gone: $(head -n 1 "$err")")
    fi
    # The role's two tags and the policy document again, right before the policy delete.
    if ! why=$(role_ours); then
      residue+=("inline policy $STAGE_POLICY_NAME on $BUILD_ROLE_NAME: not deleted: $why")
      fail_residue
    fi
    aws iam delete-role-policy --role-name "$BUILD_ROLE_NAME" --policy-name "$STAGE_POLICY_NAME" --output json >/dev/null 2>"$err" \
      || residue+=("inline policy $STAGE_POLICY_NAME on $BUILD_ROLE_NAME: delete failed: $(head -n 1 "$err")")
    if names=$(aws iam list-role-policies --role-name "$BUILD_ROLE_NAME" --output json 2>"$err"); then
      printf '%s' "$names" | json_get 'd["PolicyNames"]' | grep -qxF -- "$STAGE_POLICY_NAME" \
        && residue+=("inline policy $STAGE_POLICY_NAME on $BUILD_ROLE_NAME: still present")
    else
      residue+=("inline policy $STAGE_POLICY_NAME on $BUILD_ROLE_NAME: could not confirm it is gone: $(head -n 1 "$err")")
    fi
    [ "${#residue[@]}" -eq 0 ] || fail_residue
    rm -f "$RUN_STATE_DIR/stage-residue.txt"
    log "confirmed: the staged objects are gone and $BUILD_ROLE_NAME no longer has $STAGE_POLICY_NAME; the empty bucket $bucket stays for clean.sh"
    ;;
  *) die "usage: 00b-stage-bucket.sh create <file>... | revoke <bucket> <file-name>... (RUN_ID set)" ;;
esac
