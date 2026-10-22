# btf-tag.sh: the one function that decides whether an AMI gets BtfValidated=true, and
# applies it. Sourced by scripts/verify-fresh-instance.sh (the real caller) and by
# scripts/test-btf-tag.sh (a clusterless, AWS-less stub test), so the same code path that
# runs for real is the code path the test proves.
#
# Issue #11 (Cilium on Ubuntu)'s AMI preflight refuses any AMI that does not carry
# BtfValidated=true, and states that this sample is what sets it. This file is that
# contract's one point of truth:
#
#   - The tag is applied ONLY after a fresh instance launched from the AMI has PASSED
#     scripts/verify-fresh-instance.sh's host-readiness + BTF checks (verify-image.py and
#     40-smoke.sh on a second, fresh instance, never the build host's own run). The tag
#     asserts "a fresh instance from this AMI passed verification", so it must never be
#     applied at scripts/50-bake-prep.sh or create-image time, and never when verification
#     fails or has not run.
#   - The AMI must already carry this sample's own ownership tag
#     (ManagedBy=$TAGS_OWNER_VALUE) before it is tagged. An AMI missing or mismatching that
#     tag is refused, non-zero exit, with a clear message: this function never writes to an
#     AMI it does not already own.
#   - ManagedBy is preserved (never overwritten with a different value; create-tags only
#     adds BtfValidated and the metadata tags below, it does not touch ManagedBy).
#
# Requires scripts/lib/common.sh to already be sourced (TAGS_OWNER_KEY, TAGS_OWNER_VALUE,
# AWS_REGION, log/die/warn). Does not set -e itself: callers choose their own discipline, as
# common.sh's own header documents.

# btf_ami_is_owned <ami-id> : 0 if the AMI carries this run's ManagedBy=$TAGS_OWNER_VALUE
# ownership tag, 1 otherwise (including "could not read the AMI's tags", which must never be
# treated as "owned"). Never guesses: a describe-images call that fails, or an AMI with no
# Tags at all, both fail closed.
btf_ami_is_owned() {
  local ami_id="$1" owner_value
  [[ -n "$ami_id" ]] || { warn "btf_ami_is_owned: no AMI id given"; return 1; }
  owner_value=$(aws ec2 describe-images --region "$AWS_REGION" --image-ids "$ami_id" \
    --query "Images[0].Tags[?Key=='${TAGS_OWNER_KEY}'].Value | [0]" --output text 2>/dev/null)
  [[ "$owner_value" == "$TAGS_OWNER_VALUE" ]]
}

# btf_tag_ami_if_verified <ami-id> <verify-status> [metadata-tag-cli ...] : the one decision
# point. <verify-status> is the exact string "pass" or "fail" (the literal, explicit signal
# scripts/verify-fresh-instance.sh produces after it runs verify-image.py and 40-smoke.sh on
# the fresh instance; never inferred from a partial log). Any value other than "pass" is
# treated as failure, fail-closed. Extra arguments are additional immutable build-metadata
# tags, already formatted as `Key=...,Value=...` (see common.sh's ownership_tag_cli for the
# shape); each is applied alongside BtfValidated=true, never in place of it.
#
# Returns:
#   0  verification passed, the AMI is owned, and BtfValidated=true (plus ManagedBy and any
#      metadata tags) was applied.
#   1  the AMI does not carry this run's ownership tag (refused: never tags an unowned or
#      mismatched AMI, whatever <verify-status> says).
#   2  verification did not pass (fail-closed: the AMI is left exactly as it was, no
#      BtfValidated tag is written, regardless of ownership).
btf_tag_ami_if_verified() {
  local ami_id="$1" verify_status="$2"
  shift 2
  local extra_tags=("$@")

  [[ -n "$ami_id" ]] || { die "btf_tag_ami_if_verified: no AMI id given"; }

  if ! btf_ami_is_owned "$ami_id"; then
    warn "refusing to tag $ami_id BtfValidated=true: it does not carry ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} (not this run's AMI, or the id is wrong)"
    return 1
  fi

  if [[ "$verify_status" != "pass" ]]; then
    warn "NOT tagging $ami_id BtfValidated=true: fresh-instance verification did not pass (status=$verify_status). An AMI that failed verification must never carry this tag."
    return 2
  fi

  # --tags is a LIST of tag structures: each `Key=...,Value=...` is one list element, and
  # elements are separated by spaces (not commas) in the AWS CLI's shorthand syntax. Joining
  # them with commas into a single string would make the CLI parse one tag with a
  # comma-corrupted value instead of several tags.
  local tag_specs=("Key=BtfValidated,Value=true" "Key=${TAGS_OWNER_KEY},Value=${TAGS_OWNER_VALUE}")
  local t
  for t in "${extra_tags[@]}"; do
    [[ -n "$t" ]] && tag_specs+=("$t")
  done

  aws ec2 create-tags --region "$AWS_REGION" --resources "$ami_id" \
    --tags "${tag_specs[@]}" \
    || die "create-tags failed for $ami_id; BtfValidated=true was NOT confirmed applied"

  log "tagged $ami_id BtfValidated=true (fresh-instance verification passed; ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} preserved)"
  return 0
}
