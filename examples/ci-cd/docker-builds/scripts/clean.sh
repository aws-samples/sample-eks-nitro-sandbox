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

# The state file is the only thing that may set these. They are unset first because
# ECR_REPO_NAME and ROLE_NAME are reader-facing overrides that .env.example offers and that
# ecr-setup.sh reads from the environment: either one set without a state file would otherwise
# look like a record of a push, and the check below would report a clean up as incomplete over
# a push that was never set up.
unset ECR_PUSH_READY ECR_ACCOUNT_ID ECR_AWS_REGION ECR_CLUSTER_NAME ECR_NAMESPACE \
      ECR_REPO_NAME ECR_ROLE_NAME ECR_POLICY_NAME ECR_ASSOCIATION_ID ECR_STATE_END
# shellcheck disable=SC1090
if [[ -f "$STATE_FILE" ]]; then
  # A state file that cannot be read whole is "could not determine": without this the script
  # would carry on and report "Clean up complete" while the push's resources were still there.
  # ECR_STATE_END is the marker ecr-setup.sh writes last, because `.` reports only its last
  # command's status. Every name is unset again on a bad read: values from before the bad line
  # survive the failed `.`, and a half-read record is worse than none, because a lost
  # association line with the role line kept would delete the role while its association lived.
  # shellcheck disable=SC1090
  if ! . "$STATE_FILE" || [[ "${ECR_STATE_END:-}" != 1 ]]; then
    note_fail "$(basename "$STATE_FILE") exists but is not a complete state file, so any Amazon ECR push it records was left in place. Fix or move the file aside, then run this again"
    unset ECR_PUSH_READY ECR_ACCOUNT_ID ECR_AWS_REGION ECR_CLUSTER_NAME ECR_NAMESPACE \
          ECR_REPO_NAME ECR_ROLE_NAME ECR_POLICY_NAME ECR_ASSOCIATION_ID
  fi
fi

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
  # The Region those volumes are in, taken from the cluster that provisioned them rather than
  # from the environment: a state file, a stale .env or an exported Region can all name a
  # Region the volumes are not in, where a live volume reads as InvalidVolume.NotFound. Read
  # before the namespace goes, while the cluster is certainly still reachable.
  vol_region=""
  if [[ "${#volume_of[@]}" -gt 0 ]]; then
    vol_region="$(kc get nodes \
      -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/region}' 2>/dev/null)" \
      || vol_region=""
  fi

  # Read each volume once while it still exists. A later "not found" only means "deleted" if a
  # "found" was possible to begin with: a shell whose credentials are for another account (a
  # kubeconfig can pin its own AWS_PROFILE, so the cluster is reachable while the CLI is
  # elsewhere), or a Region that came back wrong, would answer InvalidVolume.NotFound for a
  # volume that is alive and billing, and that would be reported as gone.
  if [[ -n "$vol_region" ]] && command -v aws >/dev/null 2>&1; then
    for claim in "${!volume_of[@]}"; do
      vol="${volume_of[$claim]}"
      seen="$(aws ec2 describe-volumes --volume-ids "$vol" --region "$vol_region" \
        --query 'Volumes[0].State' --output text 2>&1)"
      seen_rc=$?
      if [[ $seen_rc -ne 0 || -z "$seen" || "$seen" == "None" ]]; then
        note_fail "could not confirm EBS volume $vol ($claim) is gone: it was not visible to these credentials in $vol_region before deletion, so a later 'not found' would not mean deleted. Check this volume ID in the EC2 console. AWS said: $seen"
        unset "volume_of[$claim]"
      fi
    done
  fi

  echo "Deleting the EBS layer cache claims (this deletes their volumes)..."
  kc -n "$NAMESPACE" delete pvc docker-build-cache buildkit-cache --ignore-not-found --wait=true \
    || note_fail "could not delete the cache claims"

  echo "Deleting the namespace..."
  kc delete namespace "$NAMESPACE" --wait=true || note_fail "could not delete namespace '$NAMESPACE'"

  if [[ "${#volume_of[@]}" -gt 0 ]]; then
    if command -v aws >/dev/null 2>&1; then
      region="$vol_region"
      if [[ -z "$region" ]]; then
        for claim in "${!volume_of[@]}"; do
          note_fail "could not confirm EBS volume ${volume_of[$claim]} ($claim) is gone: the cluster's Region could not be read from its nodes, and no other source is reliable enough to check a volume against. Check this volume ID in the EC2 console"
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
  elif [[ -z "${ECR_AWS_REGION:-}" || -z "${ECR_CLUSTER_NAME:-}" || -z "${ECR_ACCOUNT_ID:-}" ]]; then
    # Checked before anything reads them: under `set -u` an absent name would abort the script
    # after the namespace is gone and before the summary, which reads as a crash.
    note_fail "$(basename "$STATE_FILE") records a push (role ${ECR_ROLE_NAME:-none}, repository ${ECR_REPO_NAME:-none}) but is missing the Region, cluster or account it belongs to; those resources were left in place. Remove them by hand, or restore the file and run this again"
  elif ! here_acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
       || [[ "$here_acct" != "$ECR_ACCOUNT_ID" ]]; then
    # The one check that makes the three deletes below safe to do by name: in another account
    # every lookup answers "does not exist", which would read as "already gone" and would also
    # put a same-named tagged role in the current account at risk.
    note_fail "$(basename "$STATE_FILE") records a push in AWS account $ECR_ACCOUNT_ID, but these credentials are for ${here_acct:-an account that could not be read}; its role, association and repository were left in place. Re-run with credentials for account $ECR_ACCOUNT_ID"
  else
    region="${ECR_AWS_REGION}"
    keep_role=false
    # Pod Identity association: delete only the one this sample recorded, and only while it
    # still points at this sample's role. An empty record means setup never got that far.
    if [[ -z "${ECR_ASSOCIATION_ID:-}" ]]; then
      echo "  no Pod Identity association was recorded, so there is none to delete."
    else
      bound="$(aws eks describe-pod-identity-association --cluster-name "$ECR_CLUSTER_NAME" \
        --association-id "$ECR_ASSOCIATION_ID" --region "$region" \
        --query 'association.roleArn' --output text 2>&1)"
      bound_rc=$?
      if [[ $bound_rc -ne 0 && ( "$bound" == *"ResourceNotFoundException"* || "$bound" == *"NotFoundException"* ) ]]; then
        echo "  Pod Identity association $ECR_ASSOCIATION_ID is already gone."
      elif [[ $bound_rc -ne 0 ]]; then
        # A read that failed is "could not determine", so the association stays and the role
        # below is left alone too: deleting the role out from under a live association would
        # leave it pointing at nothing.
        note_fail "could not determine which role Pod Identity association $ECR_ASSOCIATION_ID is bound to; it was left in place. AWS said: $bound"
        keep_role=true
      # The account is pinned as well as the role name: a bare *:role/<name> match would accept
      # a same-named role in any account.
      elif [[ -n "${ECR_ROLE_NAME:-}" && "$bound" == "arn:aws:iam::${ECR_ACCOUNT_ID}:role/${ECR_ROLE_NAME}" ]]; then
        if aws eks delete-pod-identity-association --cluster-name "$ECR_CLUSTER_NAME" \
             --association-id "$ECR_ASSOCIATION_ID" --region "$region" >/dev/null; then
          echo "  deleted Pod Identity association $ECR_ASSOCIATION_ID."
        else
          # Same reason as a failed read: the association may still be live, so the role it is
          # bound to is left alone rather than stranded.
          note_fail "could not delete Pod Identity association $ECR_ASSOCIATION_ID"
          keep_role=true
        fi
      else
        note_fail "Pod Identity association $ECR_ASSOCIATION_ID is not bound to this sample's role (read: $bound); left untouched"
      fi
    fi

    # IAM role: delete only a role tagged ManagedBy=docker-builds. A failed tag read and a
    # failed existence read together must not read as "already gone", so the existence read's
    # own failure is reported.
    if [[ -z "${ECR_ROLE_NAME:-}" ]]; then
      echo "  no IAM role was recorded, so there is none to delete."
    elif [[ "$keep_role" == true ]]; then
      note_fail "IAM role $ECR_ROLE_NAME was left in place because the association above could not be read or could not be deleted; removing the role could strand a live association. Run this again once AWS answers cleanly"
    else
      tags_out="$(aws iam list-role-tags --role-name "$ECR_ROLE_NAME" 2>&1)"
      tags_rc=$?
      owner=false
      [[ $tags_rc -eq 0 ]] && owner="$(printf '%s' "$tags_out" \
        | jq -r --arg m "$MANAGED_BY" 'any(.Tags[]?; .Key=="ManagedBy" and .Value==$m)' 2>/dev/null)"
      if [[ "$owner" == "true" ]]; then
        aws iam delete-role-policy --role-name "$ECR_ROLE_NAME" --policy-name "${ECR_POLICY_NAME:-docker-builds-ecr-push}" 2>/dev/null \
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

# A .docker-builds.state.tmp that a killed scripts/ecr-setup.sh left behind is not a record of
# anything, but it does hold the account ID. It is removed from here, not from the push block
# above, because that block is only entered when the state file records a push.
[[ "${#FAILURES[@]}" -eq 0 ]] && rm -f "$STATE_FILE.tmp"

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
