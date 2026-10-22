#!/usr/bin/env bash
# test-btf-tag.sh: proves scripts/lib/btf-tag.sh's BtfValidated=true decision both ways,
# plus the ownership refusal, with no AWS account and no cluster reached.
#
#   scripts/test-btf-tag.sh
#
# Runs the REAL btf_tag_ami_if_verified function from scripts/lib/btf-tag.sh (sourced, not
# copied), against a fake `aws` put first on PATH for this test only. The stub answers only
# `ec2 describe-images` (reports the AMI's tags) and `ec2 create-tags` (records what was
# asked, append-only, never actually tagging anything real); any other aws subcommand the
# function does not use is left unstubbed, so a future call this test does not expect fails
# loudly instead of silently returning fake success.
#
# Proves all three acceptance paths:
#   1/3  successful verification on an OWNED AMI -> create-tags is called with
#        BtfValidated=true (and ManagedBy preserved); the function returns 0.
#   2/3  FAILED verification on the SAME owned AMI -> create-tags is NEVER called; the
#        function returns 2 (verification did not pass).
#   3/3  successful verification on an UNOWNED / mismatched-tag AMI -> refused before
#        create-tags is even considered; the function returns 1, non-zero.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass=0
fail=0
assert_rc() { # assert_rc <description> <expected-rc> <actual-rc>
  if [[ "$3" -eq "$2" ]]; then
    printf '  PASS  %s (rc=%s)\n' "$1" "$3"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s (expected rc=%s, got rc=%s)\n' "$1" "$2" "$3"
    fail=$((fail + 1))
  fi
}
assert_true() { # assert_true <description> <bool-expr-already-evaluated-as-0-or-1>
  if [[ "$2" -eq 0 ]]; then
    printf '  PASS  %s\n' "$1"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s\n' "$1"
    fail=$((fail + 1))
  fi
}

# --- Fake `aws`, first on PATH for this test only -------------------------------------------
# $STUB_AMI_TAGS_FILE holds the one AMI id this test's fake describe-images answers for, and
# the ManagedBy value it reports; $STUB_CREATE_TAGS_LOG records every create-tags call this
# run makes (append-only), so the test can assert exactly what was (or was not) tagged.
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
export STUB_AMI_ID="ami-0test0000000000f"
export STUB_AMI_OWNER_TAG_VALUE="ubuntu-ami-sample"   # what the stubbed AMI actually carries
export STUB_CREATE_TAGS_LOG="$WORK/create-tags.log"
: > "$STUB_CREATE_TAGS_LOG"

cat > "$STUB_BIN/aws" <<'STUB'
#!/usr/bin/env bash
# Fake aws CLI for test-btf-tag.sh. Answers only what btf_tag_ami_if_verified calls; any
# other subcommand is an error, not a silent fake success, so an untested call stands out.
set -uo pipefail
case "$1 $2" in
  "ec2 describe-images")
    # Expected invocation shape: ec2 describe-images --region R --image-ids <id> --query ... --output text
    requested_id=""
    prev=""
    for arg in "$@"; do
      [[ "$prev" == "--image-ids" ]] && requested_id="$arg"
      prev="$arg"
    done
    if [[ "$requested_id" == "$STUB_AMI_ID" ]]; then
      printf '%s\n' "$STUB_AMI_OWNER_TAG_VALUE"
    else
      printf 'None\n'
    fi
    exit 0
    ;;
  "ec2 create-tags")
    printf '%s\n' "$*" >> "$STUB_CREATE_TAGS_LOG"
    exit 0
    ;;
  *)
    echo "STUB aws: unexpected call not covered by test-btf-tag.sh: $*" >&2
    exit 97
    ;;
esac
STUB
chmod +x "$STUB_BIN/aws"
export PATH="$STUB_BIN:$PATH"

# --- Load the real functions under test, with the env btf-tag.sh/common.sh expect ----------
export SAMPLE_DIR="$WORK/sample"
mkdir -p "$SAMPLE_DIR"
export AWS_REGION=us-west-2
export RESOURCE_PREFIX=ubuntu-ami-sample
export TAGS_OWNER_KEY=ManagedBy
export TAGS_OWNER_VALUE="$RESOURCE_PREFIX"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/btf-tag.sh
. "$HERE/lib/btf-tag.sh"

echo "== 1/3 ACCEPT: successful verification on an OWNED AMI -> tagged BtfValidated=true =="
: > "$STUB_CREATE_TAGS_LOG"
rc=0
btf_tag_ami_if_verified "$STUB_AMI_ID" pass "Key=KernelVersion,Value=6.18.39" >"$WORK/out1.log" 2>&1 || rc=$?
cat "$WORK/out1.log"
assert_rc "pass verification on the owned AMI returns 0 (tagged)" 0 "$rc"
assert_true "create-tags was called exactly once" \
  $([[ "$(wc -l < "$STUB_CREATE_TAGS_LOG")" -eq 1 ]]; echo $?)
assert_true "the create-tags call set BtfValidated=true" \
  $(grep -q 'Key=BtfValidated,Value=true' "$STUB_CREATE_TAGS_LOG"; echo $?)
assert_true "the create-tags call preserved ManagedBy=${TAGS_OWNER_VALUE}" \
  $(grep -q "Key=${TAGS_OWNER_KEY},Value=${TAGS_OWNER_VALUE}" "$STUB_CREATE_TAGS_LOG"; echo $?)
assert_true "the create-tags call carried the extra immutable metadata tag" \
  $(grep -q 'Key=KernelVersion,Value=6.18.39' "$STUB_CREATE_TAGS_LOG"; echo $?)

echo
echo "== 2/3 REJECT: FAILED verification on the SAME owned AMI -> NEVER tagged ============"
: > "$STUB_CREATE_TAGS_LOG"
rc=0
btf_tag_ami_if_verified "$STUB_AMI_ID" fail >"$WORK/out2.log" 2>&1 || rc=$?
cat "$WORK/out2.log"
assert_rc "failed verification on the owned AMI returns 2 (not tagged)" 2 "$rc"
assert_true "create-tags was NEVER called when verification failed" \
  $([[ ! -s "$STUB_CREATE_TAGS_LOG" ]]; echo $?)
assert_true "the refusal names verification, not a generic error" \
  $(grep -qi "verification did not pass" "$WORK/out2.log"; echo $?)

echo
echo "== 3/3 REJECT: wrong/unowned AMI (missing/mismatched ManagedBy) -> REFUSED =========="
: > "$STUB_CREATE_TAGS_LOG"
UNOWNED_AMI_ID="ami-0unowned00000000f"   # the stub's describe-images reports no matching tag for this id
rc=0
btf_tag_ami_if_verified "$UNOWNED_AMI_ID" pass >"$WORK/out3.log" 2>&1 || rc=$?
cat "$WORK/out3.log"
assert_rc "an unowned AMI is refused with a non-zero exit, even though verification passed" 1 "$rc"
assert_true "create-tags was NEVER called for an unowned AMI" \
  $([[ ! -s "$STUB_CREATE_TAGS_LOG" ]]; echo $?)
assert_true "the refusal names ownership, not a generic error" \
  $(grep -qi "does not carry" "$WORK/out3.log"; echo $?)

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "btf-tag.sh proven all three ways: pass+owned tags, fail+owned never tags, pass+unowned is refused."
