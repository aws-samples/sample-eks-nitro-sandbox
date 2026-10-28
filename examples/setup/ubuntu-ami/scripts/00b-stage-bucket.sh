#!/usr/bin/env bash
# 00b-stage-bucket.sh: the per-run S3 staging bucket that carries this run's files to the build
# host (the sample's scripts and the ~150 MB runtime archive, whose guest disk unpacks to
# 2 GiB), so nothing large is pushed through an SSM shell. Runs on the operator's workstation
# with the operator's credentials; setup.sh calls it.
#
#   scripts/00b-stage-bucket.sh create <run-id> <build-role> <file>...
#       create the bucket, harden it, upload each file under <run-id>/, and give <build-role>
#       read on that prefix only; writes STAGE_BUCKET and STAGE_ACCOUNT to $OUT_DIR/stage.env
#   scripts/00b-stage-bucket.sh revoke <bucket> <run-id> <build-role> <file-name>...
#       once the build host has verified its copies: delete the staged objects and the
#       build role's read policy (the empty bucket stays for clean.sh to remove)
#
# The bucket, created fresh per run:
#   * named <RESOURCE_PREFIX>-stage-<run-id>-<random>, so no name is reused;
#   * tagged ManagedBy=<RESOURCE_PREFIX> and RunId=<run-id> right after creation (clean.sh
#     deletes a bucket only when it carries ManagedBy=<RESOURCE_PREFIX>);
#   * S3 Block Public Access on (all four settings), default encryption SSE-S3, and the TLS-only
#     bucket policy in deploy/s3-stage-bucket-policy.json;
#   * every call passes --expected-bucket-owner, so nothing is written to a bucket another
#     account owns under the same name;
#   * every upload carries its SHA-256, which S3 checks on receipt; the build host checks it
#     again after download (setup.sh).
# The build-host role's read is deploy/iam-build-host-policy.json rendered for this bucket and
# run id: s3:GetObject on <bucket>/<run-id>/* and s3:ListBucket for that prefix only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
DEPLOY_DIR="$HERE/../deploy"
STAGE_POLICY_NAME="${RESOURCE_PREFIX}-stage-read"

render() { # render <template> <bucket> <run-id> : the policy JSON with placeholders filled, no Comment key
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
text = open(sys.argv[1]).read().replace("@STAGE_BUCKET@", sys.argv[2]).replace("@RUN_ID@", sys.argv[3])
doc = json.loads(text)
doc.pop("Comment", None)
assert "@" not in json.dumps(doc), "unrendered placeholder left in policy"
print(json.dumps(doc))
PY
}
b64_sha256() { python3 -c 'import base64,hashlib,sys; h=hashlib.sha256(); f=open(sys.argv[1],"rb"); [h.update(c) for c in iter(lambda: f.read(1<<20), b"")]; print(base64.b64encode(h.digest()).decode())' "$1"; }

cmd="${1:-}"; shift || true
case "$cmd" in
  create)
    run_id="${1:?run id}"; role="${2:?build role}"; shift 2
    [ $# -gt 0 ] || die "create: no files to stage"
    [[ "$run_id" =~ ^[a-z0-9]+$ ]] || die "run id must be lowercase letters and digits: $run_id"
    account=$(aws sts get-caller-identity --query Account --output text)
    [[ "$account" =~ ^[0-9]{12}$ ]] || die "could not read the caller's account"
    rand=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
    bucket=$(printf '%s-stage-%s-%s' "$RESOURCE_PREFIX" "$run_id" "$rand" | tr '[:upper:]' '[:lower:]')
    [[ "$bucket" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || die "staging bucket name '$bucket' is not a valid S3 bucket name (shorten RESOURCE_PREFIX)"
    owner=(--expected-bucket-owner "$account")

    log "creating staging bucket $bucket in $AWS_REGION"
    if [ "$AWS_REGION" = us-east-1 ]; then
      aws s3api create-bucket --bucket "$bucket" --region "$AWS_REGION" >/dev/null
    else
      aws s3api create-bucket --bucket "$bucket" --region "$AWS_REGION" \
        --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
    fi
    # Record it before anything else can fail, so clean.sh and a re-run know its name.
    printf 'export STAGE_BUCKET=%q\nexport STAGE_ACCOUNT=%q\nexport STAGE_RUN_ID=%q\n' "$bucket" "$account" "$run_id" > "$OUT_DIR/stage.env"
    if ! aws s3api put-bucket-tagging --bucket "$bucket" --region "$AWS_REGION" "${owner[@]}" \
      --tagging "TagSet=[{Key=${TAGS_OWNER_KEY},Value=${TAGS_OWNER_VALUE}},{Key=RunId,Value=${run_id}},{Key=Name,Value=${bucket}}]"; then
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
      --policy "$(render "$DEPLOY_DIR/s3-stage-bucket-policy.json" "$bucket" "$run_id")"
    log "bucket $bucket: tagged ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} RunId=${run_id}; Block Public Access on; SSE-S3; TLS-only policy"

    for f in "$@"; do
      [ -s "$f" ] || die "nothing to stage at $f"
      key="$run_id/$(basename "$f")"
      log "uploading $(basename "$f") to s3://$bucket/$key (S3 checks its SHA-256 on receipt)"
      aws s3api put-object --bucket "$bucket" --key "$key" --body "$f" --region "$AWS_REGION" "${owner[@]}" \
        --checksum-algorithm SHA256 --checksum-sha256 "$(b64_sha256 "$f")" >/dev/null
    done

    log "granting $role read on s3://$bucket/$run_id/ only ($STAGE_POLICY_NAME)"
    aws iam put-role-policy --role-name "$role" --policy-name "$STAGE_POLICY_NAME" \
      --policy-document "$(render "$DEPLOY_DIR/iam-build-host-policy.json" "$bucket" "$run_id")"
    echo "STAGE_BUCKET=$bucket"
    ;;
  revoke)
    bucket="${1:?bucket}"; run_id="${2:?run id}"; role="${3:?build role}"; shift 3
    account=$(aws sts get-caller-identity --query Account --output text)
    for name in "$@"; do
      aws s3api delete-object --bucket "$bucket" --key "$run_id/$name" --region "$AWS_REGION" \
        --expected-bucket-owner "$account" >/dev/null || warn "could not delete s3://$bucket/$run_id/$name; clean.sh removes it"
    done
    aws iam delete-role-policy --role-name "$role" --policy-name "$STAGE_POLICY_NAME" \
      || warn "could not delete $STAGE_POLICY_NAME from $role; clean.sh removes the role's inline policies"
    log "staged objects deleted and $role's staging read revoked; the empty bucket $bucket stays for clean.sh"
    ;;
  *) die "usage: 00b-stage-bucket.sh create <run-id> <build-role> <file>... | revoke <bucket> <run-id> <build-role> <file-name>..." ;;
esac
