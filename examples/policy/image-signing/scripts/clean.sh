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

step "delete the Pod Identity association and Kubernetes objects"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
OUR_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
assoc_id="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" --region "$AWS_REGION" \
  --query 'associations[0].associationId' --output text 2>/dev/null || true)"
# Delete the association only when it is bound to THIS sample's role, so clean.sh
# never removes one another owner created for the same namespace/service-account.
assoc_role=""
if [[ -n "$assoc_id" && "$assoc_id" != "None" ]]; then
  assoc_role="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --association-id "$assoc_id" --region "$AWS_REGION" \
    --query 'association.roleArn' --output text 2>/dev/null || true)"
fi
if [[ -n "$assoc_id" && "$assoc_id" != "None" && "$assoc_role" != "$OUR_ROLE_ARN" ]]; then
  echo "SKIP: Pod Identity association $assoc_id is bound to $assoc_role, not this sample's role $OUR_ROLE_ARN; leaving it"
  assoc_id=""
fi
if [[ -n "$assoc_id" && "$assoc_id" != "None" ]]; then
  aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --association-id "$assoc_id" --region "$AWS_REGION" >/dev/null 2>&1 || true
  # Verify it is gone: a fresh list for this namespace/service-account must be empty.
  still="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" --region "$AWS_REGION" \
    --query 'associations[0].associationId' --output text 2>/dev/null || true)"
  if [[ -z "$still" || "$still" == "None" ]]; then echo "confirmed gone: Pod Identity association $assoc_id"
  else echo "STILL PRESENT: Pod Identity association ($still)"; FAIL=1; fi
fi
kubectl -n "$NAMESPACE" delete applicationnetworkpolicy image-signing-egress --ignore-not-found >/dev/null 2>&1 || true
for p in "${PODS[@]}"; do kubectl -n "$NAMESPACE" delete pod "$p" --ignore-not-found >/dev/null 2>&1 || true; done
kubectl -n "$NAMESPACE" delete serviceaccount "$SERVICE_ACCOUNT" --ignore-not-found >/dev/null 2>&1 || true
# Delete the namespace only when it carries this sample's label (set in
# deploy/namespace.yaml), so clean.sh never removes a namespace of the same name
# that something else created.
ns_owned="$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.sample}' 2>/dev/null || true)"
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "confirmed gone: namespace $NAMESPACE and everything in it"
elif [[ "$ns_owned" != "image-signing" ]]; then
  echo "SKIP: namespace $NAMESPACE is not labelled sample=image-signing; leaving it"
else
  kubectl delete namespace "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  # Verify the namespace is gone (terminating counts as not-yet-gone).
  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "STILL PRESENT: namespace $NAMESPACE (may be Terminating; re-run clean.sh)"; FAIL=1
  else
    echo "confirmed gone: namespace $NAMESPACE and everything in it"
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
