#!/usr/bin/env bash
# 00b-stage-bucket.sh: the per-run S3 staging bucket that carries this run's files to the build
# host (the sample's scripts and the ~150 MB runtime archive, whose guest disk unpacks to
# 2 GiB), so nothing large is pushed through an SSM shell. Runs on the operator's workstation
# with the operator's credentials; setup.sh calls it with RUN_ID set.
#
#   RUN_ID=<id> scripts/00b-stage-bucket.sh create <file>...
#       create the bucket, harden it, upload each file under <run-id>/, and give this run's
#       build role read on that prefix only; writes STAGE_BUCKET to $RUN_STATE_DIR/stage.env
#   RUN_ID=<id> scripts/00b-stage-bucket.sh revoke <bucket> <file-name>...
#       once the build host has verified its copies: delete the staged objects and the build
#       role's read policy, then CONFIRM both are gone. Any failure, or anything still present,
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

render() { # render <template> <bucket> : the policy JSON with placeholders filled, no Comment key
  python3 - "$1" "$2" "$RUN_ID" <<'PY'
import json, sys
text = open(sys.argv[1]).read().replace("@STAGE_BUCKET@", sys.argv[2]).replace("@RUN_ID@", sys.argv[3])
doc = json.loads(text)
doc.pop("Comment", None)
if "@" in json.dumps(doc):
    sys.exit("unrendered placeholder left in policy")
print(json.dumps(doc))
PY
}
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
    # Record it before anything else can fail, so clean.sh and a re-run know its name.
    printf 'export STAGE_BUCKET=%q\nexport STAGE_ACCOUNT=%q\nexport STAGE_RUN_ID=%q\n' "$bucket" "$account" "$RUN_ID" > "$RUN_STATE_DIR/stage.env"
    if ! aws s3api put-bucket-tagging --bucket "$bucket" --region "$AWS_REGION" "${owner[@]}" \
      --tagging "TagSet=[{Key=${TAGS_OWNER_KEY},Value=${TAGS_OWNER_VALUE}},{Key=${TAGS_RUN_KEY},Value=${RUN_ID}},{Key=Name,Value=${bucket}}]"; then
      # An untagged bucket is one clean.sh will (rightly) refuse to delete, so remove the empty
      # bucket this call just created before stopping.
      aws s3api delete-bucket --bucket "$bucket" --region "$AWS_REGION" "${owner[@]}" \
        || warn "could not delete the untagged bucket $bucket this run just created; delete it by hand"
      die "could not tag staging bucket $bucket"
    fi
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
      aws s3api put-object --bucket "$bucket" --key "$key" --body "$f" --region "$AWS_REGION" "${owner[@]}" \
        --checksum-algorithm SHA256 --checksum-sha256 "$(b64_sha256 "$f")" >/dev/null
    done

    log "granting $BUILD_ROLE_NAME read on s3://$bucket/$RUN_ID/ only ($STAGE_POLICY_NAME)"
    aws iam put-role-policy --role-name "$BUILD_ROLE_NAME" --policy-name "$STAGE_POLICY_NAME" \
      --policy-document "$(render "$DEPLOY_DIR/iam-build-host-policy.json" "$bucket")"
    echo "STAGE_BUCKET=$bucket"
    ;;
  revoke)
    bucket="${1:?usage: revoke <bucket> <file-name>...}"; shift
    [[ "$bucket" == "${STAGE_BUCKET_PREFIX}-"* ]] || die "bucket $bucket is not this run's staging bucket (${STAGE_BUCKET_PREFIX}-*)"
    residue=()
    err=$(mktemp); trap 'rm -f "$err"' EXIT
    if account=$(caller_account 2>"$err"); then
      for name in "$@"; do
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
    else
      residue+=("objects under s3://$bucket/$RUN_ID/: not deleted, the caller's account could not be read: $(head -n 1 "$err")")
    fi
    aws iam delete-role-policy --role-name "$BUILD_ROLE_NAME" --policy-name "$STAGE_POLICY_NAME" --output json >/dev/null 2>"$err" \
      || residue+=("inline policy $STAGE_POLICY_NAME on $BUILD_ROLE_NAME: delete failed: $(head -n 1 "$err")")
    if aws iam get-role-policy --role-name "$BUILD_ROLE_NAME" --policy-name "$STAGE_POLICY_NAME" --output json >/dev/null 2>"$err"; then
      residue+=("inline policy $STAGE_POLICY_NAME on $BUILD_ROLE_NAME: still present")
    elif ! aws_err_is "$err" NoSuchEntity; then
      residue+=("inline policy $STAGE_POLICY_NAME on $BUILD_ROLE_NAME: could not confirm it is gone: $(head -n 1 "$err")")
    fi
    if [ "${#residue[@]}" -gt 0 ]; then
      printf '%s\n' "${residue[@]}" > "$RUN_STATE_DIR/stage-residue.txt"
      printf 'FAIL: staging revocation incomplete (recorded in %s):\n' "$RUN_STATE_DIR/stage-residue.txt" >&2
      printf '  %s\n' "${residue[@]}" >&2
      exit 1
    fi
    rm -f "$RUN_STATE_DIR/stage-residue.txt"
    log "confirmed: the staged objects are gone and $BUILD_ROLE_NAME no longer has $STAGE_POLICY_NAME; the empty bucket $bucket stays for clean.sh"
    ;;
  *) die "usage: 00b-stage-bucket.sh create <file>... | revoke <bucket> <file-name>... (RUN_ID set)" ;;
esac
