#!/usr/bin/env bash
# Delete what setup.sh created, and verify it is gone. Run it from this sample's
# folder.
#
#   ./scripts/clean.sh                        delete the Kubernetes objects (the
#                                             three pods, the ServiceAccount, the
#                                             namespace, the egress policy) and the
#                                             Pod Identity association; keep the ECR
#                                             repositories, IAM role and AWS Signer
#                                             profile (slow to rebuild).
#   ./scripts/clean.sh --delete-aws-resources also delete the ECR repositories and
#                                             IAM role, and CANCEL the AWS Signer
#                                             signing profile (it has no hard delete).
#
# Safe to run at any time, including after a failed setup.sh: an object already
# gone is not an error. Deletions are verified; clean.sh exits non-zero if
# anything it was asked to remove is still there.
set -uo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SAMPLE_DIR"

delete_aws_resources=false
for arg in "$@"; do
  case "$arg" in
    --delete-aws-resources) delete_aws_resources=true ;;
    --help|-h) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[[ -f .env ]] || { echo "ERROR: .env not found. Copy .env.example to .env and fill it in." >&2; exit 2; }
# shellcheck disable=SC1091
. ./.env
: "${CLUSTER_NAME:?set CLUSTER_NAME in .env}"
: "${AWS_REGION:?set AWS_REGION in .env}"

NAMESPACE="image-signing-sample"
SERVICE_ACCOUNT="image-signing-verifier"
# Must match the name setup.sh used (it reads SIGNING_PROFILE from .env too).
SIGNING_PROFILE="${SIGNING_PROFILE:-nitro_sample_image_signing}"
ECR_REPO_SIGNED="nitro-sample-image-signing-signed"
ECR_REPO_UNSIGNED="nitro-sample-image-signing-unsigned"
ROLE_NAME="nitro-sample-image-signing-verify"
STATE_FILE="$SAMPLE_DIR/.image-signing.state"
PODS=(verify-signed verify-unsigned verify-signed-denied)

# Pin the kube context for this run so a kubectl call never lands on whatever the
# shared current context happens to be. Set KUBE_CONTEXT=<context-name>; leave it
# empty to use the current context after confirming it below. Every kubectl call
# goes through kc().
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
kc() { if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi; }
ctx_now="$(kc config current-context 2>/dev/null || true)"
[[ -n "$ctx_now" ]] || { echo "ERROR: no kube context (set KUBE_CONTEXT in your env or a current context)." >&2; exit 2; }
echo "kube context: $ctx_now"

CREATED_ECR_SIGNED=false CREATED_ECR_UNSIGNED=false
CREATED_IAM_ROLE=false CREATED_SIGNING_PROFILE=false
# shellcheck disable=SC1090
[[ -f "$STATE_FILE" ]] && . "$STATE_FILE"

FAIL=0
step() { printf '\n=== %s ===\n' "$*"; }
# Verify a resource is absent: the read command must fail with a NotFound error.
# A read that SUCCEEDS means still present; a read that fails any OTHER way
# (throttle, expired token) is "could not determine", never read as gone.
verify_absent() {  # verify_absent <label> <notfound-regex> -- <cmd...>
  local label="$1" notfound="$2"; shift 2; [[ "$1" == "--" ]] && shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if (( rc == 0 )); then echo "STILL PRESENT: $label"; FAIL=1
  elif printf '%s' "$out" | grep -qE "$notfound"; then echo "confirmed gone: $label"
  else echo "COULD NOT DETERMINE: $label ($out)"; FAIL=1; fi
}

step "delete the Pod Identity association"
# Build the role ARN only from a confirmed account id. A failed sts call that is
# read as empty would make every "bound to our role" test false and silently skip
# the association, so stop here instead.
acct_out="$(aws sts get-caller-identity --query Account --output text 2>&1)"; acct_rc=$?
if (( acct_rc != 0 )) || [[ -z "$acct_out" || "$acct_out" == "None" ]]; then
  echo "COULD NOT DETERMINE: AWS account id (sts get-caller-identity failed: $acct_out)"; FAIL=1
  ACCOUNT_ID=""
else
  ACCOUNT_ID="$acct_out"
fi

if [[ -n "$ACCOUNT_ID" ]]; then
  OUR_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
  # List the association. Separate a real "no association" (empty / None) from a
  # lookup that failed: only the former is "absent"; the latter is unknown.
  assoc_out="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" --region "$AWS_REGION" \
    --query 'associations[0].associationId' --output text 2>&1)"; assoc_rc=$?
  if (( assoc_rc != 0 )); then
    echo "COULD NOT DETERMINE: Pod Identity association ($assoc_out)"; FAIL=1
  elif [[ -z "$assoc_out" || "$assoc_out" == "None" ]]; then
    echo "confirmed gone: no Pod Identity association for $NAMESPACE/$SERVICE_ACCOUNT"
  else
    assoc_id="$assoc_out"
    # Confirm it is bound to THIS sample's role before deleting. A failed describe
    # is unknown, not permission to delete.
    role_out="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
      --association-id "$assoc_id" --region "$AWS_REGION" \
      --query 'association.roleArn' --output text 2>&1)"; role_rc=$?
    if (( role_rc != 0 )); then
      echo "COULD NOT DETERMINE: role of association $assoc_id ($role_out); leaving it"; FAIL=1
    elif [[ "$role_out" != "$OUR_ROLE_ARN" ]]; then
      echo "SKIP: association $assoc_id is bound to $role_out, not this sample's role $OUR_ROLE_ARN; leaving it (clean up incomplete)"; FAIL=1
    else
      aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" \
        --association-id "$assoc_id" --region "$AWS_REGION" >/dev/null 2>&1 || true
      # Verify gone: a fresh list must come back empty, and the list must succeed.
      still_out="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
        --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" --region "$AWS_REGION" \
        --query 'associations[0].associationId' --output text 2>&1)"; still_rc=$?
      if (( still_rc != 0 )); then echo "COULD NOT DETERMINE: association after delete ($still_out)"; FAIL=1
      elif [[ -z "$still_out" || "$still_out" == "None" ]]; then echo "confirmed gone: Pod Identity association $assoc_id"
      else echo "STILL PRESENT: Pod Identity association ($still_out)"; FAIL=1; fi
    fi
  fi
fi

step "delete the Kubernetes objects"
# Check ownership BEFORE deleting anything: read the namespace's phase and label in
# one go. Delete the objects inside it only when the namespace is this sample's.
# Separate "absent" (NotFound) from "could not determine" (any other failure).
ns_json="$(kc get namespace "$NAMESPACE" -o jsonpath='{.status.phase}|{.metadata.labels.sample}' 2>&1)"; ns_rc=$?
if (( ns_rc != 0 )); then
  # Only the explicit "not found" error from the API server means absent; any other
  # failure (bad kubeconfig, unreachable server, missing cert) is "could not determine".
  if printf '%s' "$ns_json" | grep -qE '^Error from server \(NotFound\)'; then
    echo "confirmed gone: namespace $NAMESPACE"
  else
    echo "COULD NOT DETERMINE: namespace $NAMESPACE ($ns_json)"; FAIL=1
  fi
else
  ns_label="${ns_json#*|}"
  if [[ "$ns_label" != "image-signing" ]]; then
    echo "SKIP: namespace $NAMESPACE is not labelled sample=image-signing (label: '${ns_label}'); leaving it and its contents (clean up incomplete)"; FAIL=1
  else
    kc -n "$NAMESPACE" delete applicationnetworkpolicy image-signing-egress --ignore-not-found >/dev/null 2>&1 || true
    for p in "${PODS[@]}"; do kc -n "$NAMESPACE" delete pod "$p" --ignore-not-found >/dev/null 2>&1 || true; done
    kc -n "$NAMESPACE" delete serviceaccount "$SERVICE_ACCOUNT" --ignore-not-found >/dev/null 2>&1 || true
    kc delete namespace "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
    # Verify gone. A successful read means still present (Terminating counts as
    # not-yet-gone); a NotFound means gone; any other failure is unknown.
    chk="$(kc get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>&1)"; chk_rc=$?
    if (( chk_rc == 0 )); then echo "STILL PRESENT: namespace $NAMESPACE (phase ${chk:-unknown}; may be Terminating, re-run clean.sh)"; FAIL=1
    elif printf '%s' "$chk" | grep -qE '^Error from server \(NotFound\)'; then echo "confirmed gone: namespace $NAMESPACE and everything in it"
    else echo "COULD NOT DETERMINE: namespace $NAMESPACE after delete ($chk)"; FAIL=1; fi
  fi
fi

if [[ "$delete_aws_resources" == "true" ]]; then
  step "delete the AWS resources this sample created"
  if [[ "${CREATED_IAM_ROLE:-false}" == "true" ]]; then
    for pol in $(aws iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames[]' --output text 2>/dev/null); do
      aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$pol" >/dev/null 2>&1 || true
    done
    aws iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
    verify_absent "IAM role $ROLE_NAME" 'NoSuchEntity' -- \
      aws iam get-role --role-name "$ROLE_NAME"
  fi
  for repo in "$ECR_REPO_SIGNED:${CREATED_ECR_SIGNED}" "$ECR_REPO_UNSIGNED:${CREATED_ECR_UNSIGNED}"; do
    name="${repo%:*}" made="${repo##*:}"
    [[ "$made" == "true" ]] || continue
    aws ecr delete-repository --repository-name "$name" --region "$AWS_REGION" --force >/dev/null 2>&1 || true
    verify_absent "ECR repository $name" 'RepositoryNotFound' -- \
      aws ecr describe-repositories --repository-names "$name" --region "$AWS_REGION"
  done
  if [[ "${CREATED_SIGNING_PROFILE:-false}" == "true" ]]; then
    # AWS Signer has no hard delete; Cancel is the documented teardown.
    aws signer cancel-signing-profile --profile-name "$SIGNING_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1 || true
    status="$(aws signer get-signing-profile --profile-name "$SIGNING_PROFILE" --region "$AWS_REGION" --query 'status' --output text 2>&1)"
    if [[ "$status" == "Canceled" ]]; then echo "confirmed canceled: signing profile $SIGNING_PROFILE"
    else echo "COULD NOT CONFIRM Canceled: signing profile $SIGNING_PROFILE ($status)"; FAIL=1; fi
  fi
  (( FAIL == 0 )) && rm -f "$STATE_FILE"
fi

if (( FAIL == 0 )); then echo; echo "clean up complete."; else echo; echo "clean up finished with unverified items above." >&2; fi
exit $FAIL
