#!/usr/bin/env bash
# Remove everything this sample created, and only that.
#
#   ./scripts/clean.sh
#
# In order: the Jobs and the interactive pod, the comparison pod, the build scripts, the
# egress policy, each EBS layer cache claim (confirming with EC2 that the volume is gone),
# and the namespace. Then, when .docker-builds.state records an Amazon ECR push, the Pod
# Identity association, the IAM role and its policy, and the ECR repository.
#
# It touches only objects in a namespace labelled app.kubernetes.io/part-of=docker-builds and
# AWS resources tagged ManagedBy=docker-builds. Anything it skips or cannot confirm is listed
# at the end and makes it exit non-zero: a lookup that fails means "could not determine",
# never "already gone".
#
# Overridable: NAMESPACE (default docker-builds-sample), KUBE_CONTEXT.
set -uo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SAMPLE_DIR" || exit 2

NAMESPACE="${NAMESPACE:-docker-builds-sample}"
MANAGED_BY="docker-builds"
SAMPLE_LABEL_JSONPATH='app\.kubernetes\.io/part-of'
STATE_FILE="$SAMPLE_DIR/.docker-builds.state"

KUBE_CONTEXT="${KUBE_CONTEXT:-}"
kc() { if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi; }

FAILURES=()
note_fail() { FAILURES+=("$1"); printf '  ! %s\n' "$1"; }

command -v kubectl >/dev/null 2>&1 || { echo "error: kubectl is not on PATH" >&2; exit 2; }

# shellcheck disable=SC1090
[[ -f "$STATE_FILE" ]] && . "$STATE_FILE"

# --- the namespace and everything in it ------------------------------------
ns_exists=true
# A failed read is "could not determine", never "already gone": --ignore-not-found makes an
# absent namespace an empty answer with status 0, so any non-zero status here is a real failure
# (an unreachable API, the wrong context, RBAC) and is reported rather than skipped silently.
ns_name="$(kc get namespace "$NAMESPACE" --ignore-not-found -o name 2>&1)"
ns_rc=$?
if [[ $ns_rc -ne 0 ]]; then
  note_fail "could not determine whether namespace '$NAMESPACE' exists, so nothing in it was touched. kubectl said: $ns_name"
  ns_exists=false
elif [[ -z "$ns_name" ]]; then
  ns_exists=false
  echo "Namespace '$NAMESPACE' is already gone; nothing to delete in the cluster."
else
  mark="$(kc get namespace "$NAMESPACE" -o "jsonpath={.metadata.labels.$SAMPLE_LABEL_JSONPATH}" 2>/dev/null)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    note_fail "could not read the labels of namespace '$NAMESPACE', so nothing in it was touched"
    ns_exists=false
  elif [[ "$mark" != "$MANAGED_BY" ]]; then
    note_fail "namespace '$NAMESPACE' is not labelled app.kubernetes.io/part-of=$MANAGED_BY, so it is not this sample's; nothing in it was touched"
    ns_exists=false
  else
    echo "Namespace '$NAMESPACE' is this sample's (labelled app.kubernetes.io/part-of=$MANAGED_BY)."
  fi
fi

if [[ "$ns_exists" == true ]]; then
  echo "Deleting the Jobs and the pods..."
  # Inside the sample's own namespace the namespace label is the ownership check, so these
  # are deleted by their exact names.
  kc -n "$NAMESPACE" delete job docker-build buildkit-build --ignore-not-found --wait=true \
    || note_fail "could not delete the build Jobs"
  kc -n "$NAMESPACE" delete pod hello-docker ordinary-pod --ignore-not-found --wait=true \
    || note_fail "could not delete the hello-docker and ordinary-pod pods"

  echo "Deleting the build scripts and the egress policy..."
  kc -n "$NAMESPACE" delete configmap docker-build-script buildkit-build-script --ignore-not-found \
    || note_fail "could not delete the build script ConfigMaps"
  kc -n "$NAMESPACE" delete applicationnetworkpolicy docker-builds-egress --ignore-not-found \
    || note_fail "could not delete the egress policy"

  # --- the EBS layer caches ------------------------------------------------
  # Read each claim's EC2 volume ID before deleting the claim, so the volume can be confirmed
  # gone afterwards: the PersistentVolume outlives the claim until the CSI driver has deleted
  # the volume, and that is the cheapest proof it stopped billing.
  # A read that FAILS is "could not determine", not "no volume": it is reported, because the
  # volume would otherwise be deleted with the claim and never confirmed gone. A read that
  # SUCCEEDS and comes back empty is the legitimate unbound case: a claim no pod ever used has
  # no volume to confirm.
  declare -A volume_of=()
  for claim in docker-build-cache buildkit-cache; do
    # The same rule as the namespace read above: --ignore-not-found makes an absent claim an
    # empty answer with status 0, so a non-zero status here is a read that failed.
    claim_out="$(kc -n "$NAMESPACE" get "pvc/$claim" --ignore-not-found -o name 2>&1)"
    claim_rc=$?
    if [[ $claim_rc -ne 0 ]]; then
      note_fail "could not determine whether claim $claim exists, so its EBS volume cannot be confirmed deleted; check it in the EC2 console. kubectl said: $claim_out"
      continue
    fi
    [[ -n "$claim_out" ]] || continue
    pv="$(kc -n "$NAMESPACE" get "pvc/$claim" -o jsonpath='{.spec.volumeName}' 2>&1)"
    pv_rc=$?
    if [[ $pv_rc -ne 0 ]]; then
      note_fail "could not read which PersistentVolume claim $claim is bound to, so its EBS volume cannot be confirmed deleted; check it in the EC2 console. kubectl said: $pv"
      continue
    fi
    if [[ -z "$pv" ]]; then
      echo "  $claim is not bound to a volume (no pod ever used it), so there is no EBS volume to confirm."
      continue
    fi
    vol="$(kc get "pv/$pv" -o jsonpath='{.spec.csi.volumeHandle}' 2>&1)"
    vol_rc=$?
    if [[ $vol_rc -ne 0 || -z "$vol" ]]; then
      note_fail "claim $claim is bound to $pv but its EBS volume ID could not be read, so the volume cannot be confirmed deleted; check it in the EC2 console${vol:+. kubectl said: $vol}"
      continue
    fi
    volume_of["$claim"]="$vol"
  done
  echo "Deleting the EBS layer cache claims (this deletes their volumes)..."
  kc -n "$NAMESPACE" delete pvc docker-build-cache buildkit-cache --ignore-not-found --wait=true \
    || note_fail "could not delete the cache claims"

  echo "Deleting the namespace..."
  kc delete namespace "$NAMESPACE" --wait=true || note_fail "could not delete namespace '$NAMESPACE'"

  if [[ "${#volume_of[@]}" -gt 0 ]]; then
    if command -v aws >/dev/null 2>&1; then
      region="${ECR_AWS_REGION:-${AWS_REGION:-}}"
      if [[ -z "$region" && -f .env ]]; then
        # shellcheck disable=SC1091
        . ./.env
        region="${AWS_REGION:-}"
      fi
      if [[ -z "$region" ]]; then
        for claim in "${!volume_of[@]}"; do
          note_fail "could not confirm EBS volume ${volume_of[$claim]} ($claim) is gone: no AWS Region set (set AWS_REGION)"
        done
      else
        echo "Confirming the EBS volumes are gone (up to 180s for the CSI driver)..."
        for claim in "${!volume_of[@]}"; do
          vol="${volume_of[$claim]}"
          gone=false
          for _ in $(seq 1 36); do
            out="$(aws ec2 describe-volumes --volume-ids "$vol" --region "$region" \
              --query 'Volumes[0].State' --output text 2>&1)"
            if [[ "$out" == *"InvalidVolume.NotFound"* ]]; then gone=true; break; fi
            if [[ "$out" == *"error"* || "$out" == *"Error"* ]]; then
              note_fail "could not read EBS volume $vol ($claim) from EC2: $out"
              gone=skip; break
            fi
            sleep 5
          done
          case "$gone" in
            true) echo "  $claim: volume $vol is gone." ;;
            skip) ;;
            *) note_fail "EBS volume $vol ($claim) still exists after 180s; it is still billing" ;;
          esac
        done
      fi
    else
      for claim in "${!volume_of[@]}"; do
        note_fail "could not confirm EBS volume ${volume_of[$claim]} ($claim) is gone: the AWS CLI is not on PATH"
      done
    fi
  fi
fi

# --- the optional push's AWS resources -------------------------------------
# Act on whatever the state file records, not on whether the push was finished: ecr-setup.sh
# records each resource as soon as it exists, so a setup that stopped part way still leaves a
# repository or a role to remove here. Each one is tag-checked again before it is deleted.
# NAMESPACE identifies the run, so a clean up pointed at another namespace never removes this
# run's AWS resources.
if [[ -n "${ECR_REPO_NAME:-}${ECR_ROLE_NAME:-}${ECR_ASSOCIATION_ID:-}" && "${ECR_NAMESPACE:-}" != "$NAMESPACE" ]]; then
  note_fail "the Amazon ECR push recorded in $(basename "$STATE_FILE") belongs to namespace '${ECR_NAMESPACE:-unknown}', not '$NAMESPACE'; its role, association and repository were left in place (clean up that namespace instead)"
elif [[ -n "${ECR_REPO_NAME:-}${ECR_ROLE_NAME:-}${ECR_ASSOCIATION_ID:-}" ]]; then
  echo "Removing the Amazon ECR push resources recorded in $(basename "$STATE_FILE")..."
  if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    note_fail "the AWS CLI and jq are needed to remove the push resources (role ${ECR_ROLE_NAME:-none}, repository ${ECR_REPO_NAME:-none}); they are left in place"
  else
    region="${ECR_AWS_REGION}"
    # Pod Identity association: delete only the one this sample recorded, and only while it
    # still points at this sample's role. An empty record means setup never got that far.
    if [[ -z "${ECR_ASSOCIATION_ID:-}" ]]; then
      echo "  no Pod Identity association was recorded, so there is none to delete."
    else
      bound="$(aws eks describe-pod-identity-association --cluster-name "$ECR_CLUSTER_NAME" \
        --association-id "$ECR_ASSOCIATION_ID" --region "$region" \
        --query 'association.roleArn' --output text 2>&1)"
      if [[ "$bound" == *"ResourceNotFoundException"* || "$bound" == *"NotFoundException"* ]]; then
        echo "  Pod Identity association $ECR_ASSOCIATION_ID is already gone."
      elif [[ "$bound" == *"arn:aws:iam::"*":role/${ECR_ROLE_NAME}" ]]; then
        aws eks delete-pod-identity-association --cluster-name "$ECR_CLUSTER_NAME" \
          --association-id "$ECR_ASSOCIATION_ID" --region "$region" >/dev/null \
          && echo "  deleted Pod Identity association $ECR_ASSOCIATION_ID." \
          || note_fail "could not delete Pod Identity association $ECR_ASSOCIATION_ID"
      else
        note_fail "Pod Identity association $ECR_ASSOCIATION_ID is not bound to this sample's role (read: $bound); left untouched"
      fi
    fi

    # IAM role: delete only a role tagged ManagedBy=docker-builds. A failed tag read and a
    # failed existence read together must not read as "already gone", so the existence read's
    # own failure is reported.
    if [[ -z "${ECR_ROLE_NAME:-}" ]]; then
      echo "  no IAM role was recorded, so there is none to delete."
    else
      tags_out="$(aws iam list-role-tags --role-name "$ECR_ROLE_NAME" 2>&1)"
      tags_rc=$?
      owner=false
      [[ $tags_rc -eq 0 ]] && owner="$(printf '%s' "$tags_out" \
        | jq -r --arg m "$MANAGED_BY" 'any(.Tags[]?; .Key=="ManagedBy" and .Value==$m)' 2>/dev/null)"
      if [[ "$owner" == "true" ]]; then
        aws iam delete-role-policy --role-name "$ECR_ROLE_NAME" --policy-name "$ECR_POLICY_NAME" 2>/dev/null \
          || true
        aws iam delete-role --role-name "$ECR_ROLE_NAME" >/dev/null 2>&1 \
          && echo "  deleted IAM role $ECR_ROLE_NAME and its policy." \
          || note_fail "could not delete IAM role $ECR_ROLE_NAME"
      elif [[ "$tags_out" == *"NoSuchEntity"* ]]; then
        echo "  IAM role $ECR_ROLE_NAME is already gone."
      elif [[ $tags_rc -ne 0 ]]; then
        note_fail "could not determine whether IAM role $ECR_ROLE_NAME is this sample's; it was left in place. AWS said: $tags_out"
      else
        note_fail "IAM role $ECR_ROLE_NAME is not tagged ManagedBy=$MANAGED_BY; left untouched"
      fi
    fi

    # ECR repository: delete only a repository tagged ManagedBy=docker-builds, with the image
    # the build pushed (--force, since the repository holds this sample's own image).
    if [[ -z "${ECR_REPO_NAME:-}" ]]; then
      echo "  no ECR repository was recorded, so there is none to delete."
    else
      repo_arn="arn:aws:ecr:${region}:${ECR_ACCOUNT_ID}:repository/${ECR_REPO_NAME}"
      repo_out="$(aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$region" 2>&1)"
      repo_rc=$?
      if [[ $repo_rc -ne 0 && "$repo_out" == *"RepositoryNotFoundException"* ]]; then
        echo "  ECR repository $ECR_REPO_NAME is already gone."
      elif [[ $repo_rc -ne 0 ]]; then
        note_fail "could not determine whether ECR repository $ECR_REPO_NAME exists; it was left in place. AWS said: $repo_out"
      else
        tags_out="$(aws ecr list-tags-for-resource --resource-arn "$repo_arn" --region "$region" 2>&1)"
        tags_rc=$?
        owner=false
        [[ $tags_rc -eq 0 ]] && owner="$(printf '%s' "$tags_out" \
          | jq -r --arg m "$MANAGED_BY" 'any(.tags[]?; .Key=="ManagedBy" and .Value==$m)' 2>/dev/null)"
        if [[ "$owner" == "true" ]]; then
          aws ecr delete-repository --repository-name "$ECR_REPO_NAME" --region "$region" --force >/dev/null \
            && echo "  deleted ECR repository $ECR_REPO_NAME and the image in it." \
            || note_fail "could not delete ECR repository $ECR_REPO_NAME"
        elif [[ $tags_rc -ne 0 ]]; then
          note_fail "could not determine whether ECR repository $ECR_REPO_NAME is this sample's; it was left in place. AWS said: $tags_out"
        else
          note_fail "ECR repository $ECR_REPO_NAME is not tagged ManagedBy=$MANAGED_BY; left untouched"
        fi
      fi
    fi
  fi
  [[ "${#FAILURES[@]}" -eq 0 ]] && rm -f "$STATE_FILE"
fi

echo
if [[ "${#FAILURES[@]}" -gt 0 ]]; then
  echo "Clean up incomplete. What it could not do:"
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  echo "Nothing else was touched. Fix the above, then run this again."
  exit 1
fi
echo "Clean up complete: the namespace and everything in it are gone, each EBS layer cache"
echo "volume is confirmed deleted, and the push's role, association and repository are removed"
echo "when the sample created them. Network policy enforcement is a cluster-wide setting this"
echo "sample never changed; it stays on."
