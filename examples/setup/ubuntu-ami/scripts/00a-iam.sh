#!/usr/bin/env bash
# 00a-iam.sh: create the two scoped IAM roles (and the build-host instance profile) this
# sample needs, tagged ManagedBy=<RESOURCE_PREFIX> so clean.sh finds and removes them.
# Runs on the operator's workstation from the operator's own credentials, BEFORE any
# instance or node group is created. Idempotent: re-running reuses an existing owned role
# rather than failing.
#
# Why this stage exists: scripts/verify-fresh-instance.sh needs INSTANCE_PROFILE and
# scripts/join-nodegroup.sh needs NODE_ROLE_ARN. Before this stage those were required
# pre-existing external inputs with nothing in the sample to produce them, and clean.sh
# claimed to remove "the instance profile and the IAM roles it created" that nothing ever
# created. This stage closes that gap: it is the sample's own role-creation step, the
# README's "IAM roles are limited to the build, EKS join and cleanup actions the sample
# needs" criterion made concrete, with the exact policy documents tracked in deploy/.
#
# Two roles:
#   * build-host role (+ instance profile): AmazonSSMManagedInstanceCore (SSM access, no
#     inbound rule) and nothing else at creation. Its only other permission is the per-run
#     staging read in deploy/iam-build-host-policy.json, which setup.sh puts on the role for
#     the few minutes the build host downloads its staged files and then deletes.
#   * node role: the standard EKS worker managed policies, assumed by the managed node
#     group's instances. This is NOT a broad admin role; it is the documented EKS worker set.
#
# It writes the resulting names/ARNs to $OUT_DIR/iam.env (gitignored); setup.sh sources that
# file so verify-fresh-instance.sh and join-nodegroup.sh get INSTANCE_PROFILE / NODE_ROLE_ARN
# without the operator hand-copying ARNs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

DEPLOY_DIR="$HERE/../deploy"
TRUST="$DEPLOY_DIR/iam-node-trust-policy.json"
[ -f "$TRUST" ] || die "missing trust policy $TRUST"

BUILD_ROLE="${RESOURCE_PREFIX}-build-host"
NODE_ROLE="${RESOURCE_PREFIX}-node"
INSTANCE_PROFILE="${RESOURCE_PREFIX}-build-host"
TAGS="Key=${TAGS_OWNER_KEY},Value=${TAGS_OWNER_VALUE}"

# Strip the human-readable "Comment" key the deploy/*.json files carry for readers; IAM
# rejects an unknown top-level key. jq if present, else a tiny python fallback.
strip_comment() { # strip_comment <file>
  if have jq; then jq 'del(.Comment)' "$1"; else
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("Comment",None); print(json.dumps(d))' "$1"
  fi
}

role_exists() { aws iam get-role --role-name "$1" >/dev/null 2>&1; }

ensure_role() { # ensure_role <role-name>
  local role="$1"
  if role_exists "$role"; then
    log "IAM role $role already exists; reusing (tags re-applied)"
    aws iam tag-role --role-name "$role" --tags "$TAGS" >/dev/null 2>&1 || true
  else
    log "creating IAM role $role"
    aws iam create-role --role-name "$role" \
      --assume-role-policy-document "$(strip_comment "$TRUST")" \
      --tags "$TAGS" >/dev/null
  fi
}

attach_managed() { # attach_managed <role> <policy-arn>
  aws iam attach-role-policy --role-name "$1" --policy-arn "$2" >/dev/null
}

# --- build-host role -----------------------------------------------------------------------
ensure_role "$BUILD_ROLE"
attach_managed "$BUILD_ROLE" "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
# An earlier version of this sample attached a standing inline policy (EC2 describe and an SSM
# parameter read) the build host never used. Remove it from a reused role, so the role carries
# only what this version grants.
if aws iam get-role-policy --role-name "$BUILD_ROLE" --policy-name "${RESOURCE_PREFIX}-build-host-inline" >/dev/null 2>&1; then
  log "removing the unused legacy inline policy ${RESOURCE_PREFIX}-build-host-inline from $BUILD_ROLE"
  aws iam delete-role-policy --role-name "$BUILD_ROLE" --policy-name "${RESOURCE_PREFIX}-build-host-inline"
fi

if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE" >/dev/null 2>&1; then
  log "instance profile $INSTANCE_PROFILE already exists; reusing"
else
  log "creating instance profile $INSTANCE_PROFILE"
  aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE" \
    --tags "$TAGS" >/dev/null
fi
# add-role-to-instance-profile fails if the role is already attached; tolerate that.
aws iam add-role-to-instance-profile --instance-profile-name "$INSTANCE_PROFILE" \
  --role-name "$BUILD_ROLE" >/dev/null 2>&1 || true

# --- node role (standard EKS worker set) ---------------------------------------------------
ensure_role "$NODE_ROLE"
for arn in \
  arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy \
  arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly \
  arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy \
  arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore; do
  attach_managed "$NODE_ROLE" "$arn"
done

NODE_ROLE_ARN=$(aws iam get-role --role-name "$NODE_ROLE" --query 'Role.Arn' --output text)

# --- record for downstream stages ----------------------------------------------------------
IAM_ENV="$OUT_DIR/iam.env"
{
  printf 'export INSTANCE_PROFILE=%q\n' "$INSTANCE_PROFILE"
  printf 'export NODE_ROLE_ARN=%q\n' "$NODE_ROLE_ARN"
  printf 'export BUILD_ROLE_NAME=%q\n' "$BUILD_ROLE"
  printf 'export NODE_ROLE_NAME=%q\n' "$NODE_ROLE"
} > "$IAM_ENV"
log "wrote $IAM_ENV (INSTANCE_PROFILE=$INSTANCE_PROFILE, NODE_ROLE_ARN=$NODE_ROLE_ARN)"
echo "IAM: PASS (build-host role + instance profile and node role created/reused, tagged ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE})"
