#!/usr/bin/env bash
# 00a-iam.sh: create this run's two scoped IAM roles and the build-host instance profile, or
# confirm that the ones already there are exactly this run's. Runs on the operator's workstation
# with the operator's credentials, BEFORE any instance or node group is created.
#
#   RUN_ID=<run-id> scripts/00a-iam.sh      # setup.sh passes RUN_ID; or it is read from the run state
#
# Names are per run (scripts/lib/common.sh derive_run_names):
#   <RESOURCE_PREFIX>-<RUN_ID>-build   build-host role, and the instance profile of the same name
#   <RESOURCE_PREFIX>-<RUN_ID>-node    EKS node role
# and every one is created with BOTH tags, ManagedBy=<RESOURCE_PREFIX> and RunId=<RUN_ID>.
#
# Reuse (a resumed run with the same RUN_ID) is allowed only for a role or profile that already
# carries both tags, and only when it is exactly what this script would have created:
#   * the trust policy equals deploy/iam-node-trust-policy.json (EC2 may assume the role);
#   * the attached managed policies are exactly the allowlist below, no more;
#   * no inline policy other than this run's staging read (build role) or none (node role);
#   * the instance profile holds this run's build role and no other role.
# Anything else, and any lookup that fails for a reason other than "does not exist", stops the
# script before it changes anything: it never adopts, re-tags or widens a role it did not create.
# Tag, attach and profile-association failures are never swallowed.
#
# Roles:
#   * build-host role: AmazonSSMManagedInstanceCore only (SSM, no inbound rule). Its only other
#     permission is the per-run staging read in deploy/iam-build-host-policy.json, which
#     scripts/00b-stage-bucket.sh adds for the download and removes right after.
#   * node role: the standard EKS worker managed policies, nothing else.
#
# It writes NODE_ROLE_ARN to $RUN_STATE_DIR/iam.env (the repository's gitignored tmp/).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
require_run_id

DEPLOY_DIR="$HERE/../deploy"
TRUST="$DEPLOY_DIR/iam-node-trust-policy.json"
[ -f "$TRUST" ] || die "missing trust policy $TRUST"
BUILD_MANAGED=(arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore)
NODE_MANAGED=(
  arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
  arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
  arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
  arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
)
TAGS=("Key=${TAGS_OWNER_KEY},Value=${TAGS_OWNER_VALUE}" "Key=${TAGS_RUN_KEY},Value=${RUN_ID}")
ERR=$(mktemp); trap 'rm -f "$ERR"' EXIT

# The trust policy as IAM is given it: the file without the human-readable "Comment" key.
trust_doc() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("Comment",None); print(json.dumps(d, sort_keys=True))' "$TRUST"; }

# iam_read <out-var> <what> <aws args...>: run a read; "absent" only on NoSuchEntity, a
# refusal (could not determine) on every other failure.
iam_read() {
  local __v="$1" what="$2" out; shift 2
  if out=$(aws "$@" --output json 2>"$ERR"); then
    printf -v "$__v" '%s' "$out"
  elif aws_err_is "$ERR" NoSuchEntity; then
    printf -v "$__v" '%s' "__absent__"
  else
    die "could not determine $what (lookup failed, not a report that it is absent): $(head -n 2 "$ERR")"
  fi
}
# require_owned_tags <what> <tags-json>: refuse unless both run tags are present and match.
require_owned_tags() {
  printf '%s' "$2" | tags_match \
    || die "refusing to reuse $1: it does not carry ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} and ${TAGS_RUN_KEY}=${RUN_ID} (tags: $(printf '%s' "$2" | json_get '{t["Key"]: t["Value"] for t in d}'))"
}

# ensure_role <role> <allowed-inline-or-empty> <managed-arn>...
ensure_role() {
  local role="$1" allowed_inline="$2" got tags attached inline extra p; shift 2
  iam_read got "IAM role $role" iam get-role --role-name "$role"
  if [ "$got" = "__absent__" ]; then
    log "creating IAM role $role (tags ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE}, ${TAGS_RUN_KEY}=${RUN_ID})"
    aws iam create-role --role-name "$role" --assume-role-policy-document "$(trust_doc)" \
      --tags "${TAGS[@]}" --output json >/dev/null
  else
    iam_read tags "the tags of IAM role $role" iam list-role-tags --role-name "$role"
    [ "$tags" != "__absent__" ] || die "IAM role $role disappeared while it was being checked"
    require_owned_tags "IAM role $role" "$(printf '%s' "$tags" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["Tags"]))')"
    printf '%s' "$got" | python3 -c '
import json, sys
have = json.load(sys.stdin)["Role"].get("AssumeRolePolicyDocument") or {}
want = json.loads(sys.argv[1])
sys.exit(0 if json.dumps(have, sort_keys=True) == json.dumps(want, sort_keys=True) else 1)
' "$(trust_doc)" || die "refusing to reuse IAM role $role: its trust policy is not deploy/iam-node-trust-policy.json"
    log "IAM role $role already exists and carries both run tags; checking its policies"
  fi
  for p in "$@"; do
    aws iam attach-role-policy --role-name "$role" --policy-arn "$p" --output json >/dev/null
  done
  iam_read attached "the attached policies of $role" iam list-attached-role-policies --role-name "$role"
  extra=$(printf '%s' "$attached" | python3 -c '
import json, sys
have = {p["PolicyArn"] for p in json.load(sys.stdin)["AttachedPolicies"]}
want = set(sys.argv[1:])
print(" ".join(sorted(have ^ want)))
' "$@")
  [ -z "$extra" ] || die "IAM role $role has attached managed policies other than exactly ${*}: differs by $extra; refusing to use it"
  iam_read inline "the inline policies of $role" iam list-role-policies --role-name "$role"
  extra=$(printf '%s' "$inline" | python3 -c '
import json, sys
names = json.load(sys.stdin)["PolicyNames"]
print(" ".join(n for n in names if n != sys.argv[1]))
' "$allowed_inline")
  [ -z "$extra" ] || die "IAM role $role has unexpected inline policies: $extra; refusing to use it"
}

# --- build-host role and its instance profile -----------------------------------------------
ensure_role "$BUILD_ROLE_NAME" "$STAGE_POLICY_NAME" "${BUILD_MANAGED[@]}"

iam_read prof "IAM instance profile $INSTANCE_PROFILE" iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE"
if [ "$prof" = "__absent__" ]; then
  log "creating instance profile $INSTANCE_PROFILE"
  aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE" --tags "${TAGS[@]}" --output json >/dev/null
  prof_roles=""
else
  iam_read ptags "the tags of instance profile $INSTANCE_PROFILE" iam list-instance-profile-tags --instance-profile-name "$INSTANCE_PROFILE"
  [ "$ptags" != "__absent__" ] || die "instance profile $INSTANCE_PROFILE disappeared while it was being checked"
  require_owned_tags "instance profile $INSTANCE_PROFILE" "$(printf '%s' "$ptags" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["Tags"]))')"
  prof_roles=$(printf '%s' "$prof" | json_get '[r["RoleName"] for r in d["InstanceProfile"]["Roles"]]' | tr '\n' ' ' | sed 's/ *$//')
fi
case "$prof_roles" in
  "") log "adding $BUILD_ROLE_NAME to instance profile $INSTANCE_PROFILE"
      aws iam add-role-to-instance-profile --instance-profile-name "$INSTANCE_PROFILE" --role-name "$BUILD_ROLE_NAME" --output json >/dev/null ;;
  "$BUILD_ROLE_NAME") log "instance profile $INSTANCE_PROFILE already holds $BUILD_ROLE_NAME" ;;
  *) die "refusing to use instance profile $INSTANCE_PROFILE: it holds role(s) '$prof_roles', not exactly $BUILD_ROLE_NAME" ;;
esac
aws iam wait instance-profile-exists --instance-profile-name "$INSTANCE_PROFILE"

# --- node role (standard EKS worker set) ---------------------------------------------------
ensure_role "$NODE_ROLE_NAME" "" "${NODE_MANAGED[@]}"
iam_read node "IAM role $NODE_ROLE_NAME" iam get-role --role-name "$NODE_ROLE_NAME"
NODE_ROLE_ARN=$(printf '%s' "$node" | json_get 'd["Role"]["Arn"]')
[[ "$NODE_ROLE_ARN" == arn:aws*:iam::*:role/"$NODE_ROLE_NAME" ]] || die "unexpected node role ARN '$NODE_ROLE_ARN'"

# --- record for downstream stages ----------------------------------------------------------
mkdir -p "$RUN_STATE_DIR"
{
  printf 'export INSTANCE_PROFILE=%q\n' "$INSTANCE_PROFILE"
  printf 'export NODE_ROLE_ARN=%q\n' "$NODE_ROLE_ARN"
  printf 'export BUILD_ROLE_NAME=%q\n' "$BUILD_ROLE_NAME"
  printf 'export NODE_ROLE_NAME=%q\n' "$NODE_ROLE_NAME"
} > "$RUN_STATE_DIR/iam.env"
log "wrote $RUN_STATE_DIR/iam.env (INSTANCE_PROFILE=$INSTANCE_PROFILE, NODE_ROLE_ARN=$NODE_ROLE_ARN)"
echo "IAM: PASS (run $RUN_ID: $BUILD_ROLE_NAME + instance profile and $NODE_ROLE_NAME, tagged ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} ${TAGS_RUN_KEY}=${RUN_ID}, policies exactly as listed)"
