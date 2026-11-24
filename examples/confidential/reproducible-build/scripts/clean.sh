#!/usr/bin/env bash
# Remove everything scripts/setup.sh and scripts/changed-source.sh created.
#
#   ./scripts/clean.sh                      # pods, service, namespace and all AWS resources
#   ./scripts/clean.sh --keep-aws-resources # cluster objects only; keep the key, repository,
#                                           # role and Pod Identity association
#
# What it will and will not touch:
#   * It deletes each AWS resource only after reading that resource's own tags and finding
#     ManagedBy=reproducible-build on it. A resource without the tag is skipped and the
#     clean up is reported incomplete.
#   * It deletes objects inside the namespace only after confirming the namespace carries
#     this sample's app.kubernetes.io/managed-by label. Inside a namespace that does carry
#     it, everything belongs to the sample.
#   * Each pod is deleted by its exact name, never by a label selector.
#   * A lookup that cannot run means "could not determine", which is a failure, never
#     "already gone". The script exits non-zero when anything was left behind or could not
#     be checked.
#
# The KMS key is scheduled for deletion with a 7-day waiting period (the minimum AWS
# allows); there is no way to destroy it sooner. Its alias is deleted once the key is
# scheduled, so the name is reusable on the next run; a failed schedule keeps it for a
# retry. The IAM role deletion is refused when any identity policy is attached; detach
# them first or set a new ROLE_NAME in .env.
# -e is omitted on purpose: note_fail() accumulates failures and continues; -e would exit
# at the first failed command before note_fail can fire.
set -uo pipefail

# Constants referenced by note_fail and the ownership checks. Top-level so they are always
# in scope when note_fail fires, regardless of call depth.
MANAGED_BY="reproducible-build"
POD_NAME="reproducible-build-demo"
PLAIN_POD_NAME="reproducible-build-plain"
CHANGED_POD_NAME="reproducible-build-changed"
DEBUG_POD_NAME="reproducible-build-debug"
SERVICE_NAME="reproducible-build"

# --- main ---

main() {
  # TMP_DIR and SCRIPT_DIR are uppercase because lib.sh reads them by name (verify_key_policy,
  # read_predicted_pcr17, kc). KUBE_CONTEXT and AWS_REGION are uppercase because they are
  # exported for sub-processes and lib.sh's kc() reads KUBE_CONTEXT.
  local SCRIPT_DIR SAMPLE_DIR REPO_ROOT TMP_DIR STATE_FILE
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  SAMPLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
  REPO_ROOT="$(cd "${SAMPLE_DIR}/../../.." && pwd)"
  TMP_DIR="${REPO_ROOT}/tmp/reproducible-build/run"
  STATE_FILE="${TMP_DIR}/state.env"

  if [[ -f "${SAMPLE_DIR}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    . "${SAMPLE_DIR}/.env"
    set +a
  fi
  if [[ -f "${STATE_FILE}" ]]; then
    set -a
    # shellcheck source=/dev/null
    . "${STATE_FILE}"
    set +a
  fi

  # Lowercase locals for resource names; uppercase for names exported to sub-processes or
  # read by lib.sh functions via dynamic scoping.
  local namespace="${NAMESPACE:-reproducible-build}"
  local repo_name="${REPO_NAME:-reproducible-build}"
  local role_name="${ROLE_NAME:-reproducible-build-pod}"
  local kms_alias="${KMS_ALIAS:-alias/reproducible-build-sample}"
  local debug_kms_alias="${DEBUG_KMS_ALIAS:-alias/reproducible-build-debug}"
  local service_account="${SERVICE_ACCOUNT:-reproducible-build-pod}"
  local cluster_name="${CLUSTER_NAME:-}"
  local KUBE_CONTEXT="${KUBE_CONTEXT:-}" # uppercase: lib.sh's kc() reads this by name
  local AWS_REGION="${AWS_REGION:-}"     # uppercase: exported for aws sub-processes

  local keep_aws=false
  local failed=0

  # note_fail is defined here so it closes over the local `failed` via bash dynamic scoping.
  note_fail() {
    echo "INCOMPLETE: $*" >&2
    failed=1
  }

  # clean_kms_key is nested here so note_fail (and MANAGED_BY) are in scope.
  clean_kms_key() {
    local kms_alias="$1" kms_rc=0 key_json key_id key_state key_tag_rc key_tag_raw key_tag
    key_json="$(lookup NotFoundException kms describe-key --key-id "${kms_alias}" \
      --query KeyMetadata --output json)" || kms_rc=$?
    if [[ "${kms_rc}" == 0 ]]; then
      key_id="$(jq -r '.KeyId' <<<"${key_json}")"
      key_state="$(jq -r '.KeyState' <<<"${key_json}")"
      key_tag_rc=0
      key_tag_raw="$(aws kms list-resource-tags --key-id "${key_id}" \
        --query "Tags[?TagKey=='ManagedBy'].TagValue | [0]" --output text)" \
        || key_tag_rc=$?
      if [[ "${key_tag_rc}" != 0 ]]; then
        note_fail "could not read the tags on the KMS key behind ${kms_alias};" \
          "could not determine whether it is this sample's; left it and its alias alone"
      else
        key_tag="$(tag_or_empty "${key_tag_raw}")"
        if [[ "${key_tag}" != "${MANAGED_BY}" ]]; then
          note_fail "the KMS key behind ${kms_alias} does not carry ManagedBy=${MANAGED_BY}" \
            "(found '${key_tag}'); left it and its alias alone"
        else
          # Schedule first, then drop the alias: the alias is how the next clean up finds the
          # key, so a failed schedule must leave it in place for a retry.
          local scheduled=true
          if [[ "${key_state}" == "PendingDeletion" ]]; then
            echo "The KMS key ${key_id} is already scheduled for deletion."
          else
            echo "Scheduling the KMS key ${key_id} for deletion in 7 days (the shortest AWS allows)..."
            aws kms schedule-key-deletion --key-id "${key_id}" --pending-window-in-days 7 \
              --query '[KeyId,DeletionDate]' --output text \
              || {
                scheduled=false
                note_fail "could not schedule the KMS key ${key_id} for deletion; kept ${kms_alias} for a retry"
              }
          fi
          if [[ "${scheduled}" == true ]]; then
            echo "Deleting the alias ${kms_alias}..."
            aws kms delete-alias --alias-name "${kms_alias}" \
              || note_fail "could not delete the KMS alias ${kms_alias}"
          fi
        fi
      fi
    elif [[ "${kms_rc}" == 1 ]]; then
      echo "No KMS key resolves from ${kms_alias}; it is already gone."
    else
      note_fail "could not determine whether a KMS key resolves from ${kms_alias}"
    fi
  }

  for arg in "$@"; do
    case "${arg}" in
      --keep-aws-resources) keep_aws=true ;;
      --help | -h)
        sed -n '2,25p' "$0"
        exit 0
        ;;
      *)
        echo "unknown argument: ${arg}" >&2
        exit 2
        ;;
    esac
  done

  # shellcheck source=examples/confidential/reproducible-build/scripts/lib.sh
  . "${SCRIPT_DIR}/lib.sh"
  for c in kubectl aws jq; do
    command -v "${c}" >/dev/null 2>&1 || {
      echo "ERROR: ${c} is required" >&2
      exit 1
    }
  done

  # The Region is required, not optional. Without it the AWS CLI falls back to whatever the
  # ambient configuration says, and a regional lookup in the wrong Region comes back with the
  # service's own not-found exception: this script would then report resources as already
  # gone and exit 0, while they are still there.
  [[ -n "${AWS_REGION}" ]] || {
    echo "ERROR: AWS_REGION is not set, so a lookup could run against the wrong Region and" \
      "report resources that still exist as already gone." \
      "Fill it in in .env, or run from the shell that ran setup.sh." >&2
    exit 1
  }
  export AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"

  # Say which cluster and Region this is about to act on: an empty KUBE_CONTEXT means
  # "whatever is current", which on a shared machine is not always this sample's cluster.
  local clean_context
  clean_context="$(kc config current-context 2>/dev/null || true)"
  [[ -n "${clean_context}" ]] || {
    echo "ERROR: could not read the current kube context; set KUBE_CONTEXT in .env" >&2
    exit 1
  }
  echo "Cleaning up in context ${clean_context}, Region ${AWS_REGION}, namespace ${namespace}."

  # --------------------------------------------------------------- cluster objects

  # Determine the namespace's state before touching anything inside it.
  # Four states: unknown (lookup failed), absent (never created), owned (this sample's),
  # foreign (exists but belongs to something else).
  local ns_exists_rc=0 ns_label_rc=0 ns_exists ns_label ns_state
  ns_exists="$(kc get namespace "${namespace}" --ignore-not-found -o name 2>/dev/null)" \
    || ns_exists_rc=$?
  ns_label="$(kc get namespace "${namespace}" --ignore-not-found \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)" \
    || ns_label_rc=$?
  if [[ "${ns_exists_rc}" != 0 || "${ns_label_rc}" != 0 ]]; then
    ns_state=unknown
  elif [[ -z "${ns_exists}" ]]; then
    ns_state=absent
  elif [[ "${ns_label}" == "${MANAGED_BY}" ]]; then
    ns_state=owned
  else
    ns_state=foreign
  fi

  case "${ns_state}" in
    unknown)
      note_fail "could not determine whether namespace ${namespace} is this sample's" \
        "(kubectl lookup failed); deleted nothing in the cluster"
      ;;
    absent)
      echo "Namespace ${namespace} is already gone; nothing to delete in the cluster."
      ;;
    foreign)
      note_fail "namespace ${namespace} is not this sample's (managed-by='${ns_label}');" \
        "deleted nothing in it"
      ;;
    owned)
      # By exact name, never a label selector.
      local p
      for p in "${DEBUG_POD_NAME}" "${CHANGED_POD_NAME}" "${PLAIN_POD_NAME}" "${POD_NAME}"; do
        echo "Deleting pod ${namespace}/${p}..."
        kc delete pod "${p}" -n "${namespace}" --ignore-not-found --wait=true --timeout=5m \
          || note_fail "could not delete pod ${p}"
      done
      echo "Deleting service ${namespace}/${SERVICE_NAME}..."
      kc delete service "${SERVICE_NAME}" -n "${namespace}" --ignore-not-found \
        || note_fail "could not delete service ${SERVICE_NAME}"
      ;;
    *)
      note_fail "unexpected namespace state ${ns_state}; deleted nothing in the cluster"
      ;;
  esac

  # ------------------------------------------------------------------- AWS resources

  if [[ "${keep_aws}" == true ]]; then
    echo "Kept the AWS resources (--keep-aws-resources): the KMS key, the ECR repository," \
      "the IAM role and the Pod Identity association."
  else
    # Pod Identity association. It has no name, so it is identified by its cluster, namespace
    # and service account. Deleting it before the namespace avoids a race where a new pod
    # in a re-run of setup.sh could land credentials before clean up has finished.
    if [[ -n "${cluster_name}" ]]; then
      local assoc_id_rc=0 assoc_id assoc_tag_rc assoc_tag
      assoc_id="$(aws eks list-pod-identity-associations --cluster-name "${cluster_name}" \
        --namespace "${namespace}" --service-account "${service_account}" \
        --query 'associations[0].associationId' --output text 2>/dev/null)" \
        || assoc_id_rc=$?
      if [[ "${assoc_id_rc}" != 0 ]]; then
        note_fail "could not look up the Pod Identity association for ${namespace}/${service_account}"
      elif [[ "${assoc_id}" == "None" || -z "${assoc_id}" ]]; then
        echo "Pod Identity association for ${namespace}/${service_account} is already gone."
      else
        assoc_tag_rc=0
        assoc_tag="$(aws eks describe-pod-identity-association --cluster-name "${cluster_name}" \
          --association-id "${assoc_id}" --query 'association.tags.ManagedBy' \
          --output text 2>/dev/null)" || assoc_tag_rc=$?
        if [[ "${assoc_tag_rc}" != 0 ]]; then
          note_fail "could not read the tags on Pod Identity association ${assoc_id}; left it alone"
        elif [[ "${assoc_tag}" != "${MANAGED_BY}" ]]; then
          note_fail "Pod Identity association ${assoc_id} does not carry ManagedBy=${MANAGED_BY}" \
            "(found '${assoc_tag}'); left it alone"
        else
          echo "Deleting Pod Identity association ${assoc_id}..."
          aws eks delete-pod-identity-association --cluster-name "${cluster_name}" \
            --association-id "${assoc_id}" >/dev/null \
            || note_fail "could not delete Pod Identity association ${assoc_id}"
        fi
      fi
    else
      note_fail "CLUSTER_NAME is not set, so the Pod Identity association could not be looked up"
    fi
  fi

  # Delete the namespace now that the pods, service and association are gone.
  if [[ "${ns_state}" == "owned" ]]; then
    echo "Deleting namespace ${namespace} (carries app.kubernetes.io/managed-by=${MANAGED_BY})..."
    kc delete namespace "${namespace}" --wait=true --timeout=5m \
      || note_fail "could not delete namespace ${namespace}"
    local ns_still_rc=0 ns_still
    ns_still="$(kc get namespace "${namespace}" --ignore-not-found -o name 2>/dev/null)" \
      || ns_still_rc=$?
    if [[ "${ns_still_rc}" != 0 ]]; then
      note_fail "could not confirm namespace ${namespace} was deleted"
    elif [[ -n "${ns_still}" ]]; then
      note_fail "namespace ${namespace} still present after delete"
    fi
  fi

  # Remaining AWS resources, skipped when --keep-aws-resources is set.
  if [[ "${keep_aws}" != true ]]; then
    # IAM role. The role is meant to carry no identity policies; refuse rather than detach.
    local iam_rc=0 role_tag_rc role_tag_raw role_tag inline_rc attached_rc inline_count attached_count
    lookup NoSuchEntity iam get-role --role-name "${role_name}" \
      --query Role --output json >/dev/null || iam_rc=$?
    if [[ "${iam_rc}" == 0 ]]; then
      # Read the tag without 2>/dev/null so a failed call is "could not determine", not
      # "wrong tag". A tag lookup that fails is a different condition from a tag that is absent.
      role_tag_rc=0
      role_tag_raw="$(aws iam list-role-tags --role-name "${role_name}" \
        --query "Tags[?Key=='ManagedBy'].Value | [0]" --output text)" \
        || role_tag_rc=$?
      if [[ "${role_tag_rc}" != 0 ]]; then
        note_fail "could not read the tags on IAM role ${role_name};" \
          "could not determine whether it is this sample's; left it alone"
      else
        role_tag="$(tag_or_empty "${role_tag_raw}")"
        if [[ "${role_tag}" != "${MANAGED_BY}" ]]; then
          note_fail "IAM role ${role_name} does not carry ManagedBy=${MANAGED_BY}" \
            "(found '${role_tag}'); left it alone"
        else
          inline_rc=0
          attached_rc=0
          inline_count="$(aws iam list-role-policies --role-name "${role_name}" \
            --query 'length(PolicyNames)' --output text 2>/dev/null)" || inline_rc=$?
          attached_count="$(aws iam list-attached-role-policies --role-name "${role_name}" \
            --query 'length(AttachedPolicies)' --output text 2>/dev/null)" || attached_rc=$?
          if [[ "${inline_rc}" != 0 || "${attached_rc}" != 0 ]]; then
            note_fail "could not check policies on IAM role ${role_name}; left it alone"
          elif [[ "${inline_count}" != "0" || "${attached_count}" != "0" ]]; then
            note_fail "IAM role ${role_name} carries identity policies" \
              "(${inline_count} inline, ${attached_count} attached); left it alone —" \
              "detach them first, or set a new ROLE_NAME in .env"
          else
            echo "Deleting IAM role ${role_name}..."
            aws iam delete-role --role-name "${role_name}" \
              || note_fail "could not delete IAM role ${role_name}"
          fi
        fi
      fi
    elif [[ "${iam_rc}" == 1 ]]; then
      echo "IAM role ${role_name} is already gone."
    else
      note_fail "could not determine whether IAM role ${role_name} exists"
    fi

    # KMS keys: schedule each key, then delete its alias so the name is reusable.
    clean_kms_key "${debug_kms_alias}"
    clean_kms_key "${kms_alias}"

    # ECR repository, with the application image in it.
    local ecr_rc=0 repo_json repo_arn repo_tag_rc repo_tag_raw repo_tag
    repo_json="$(lookup RepositoryNotFoundException ecr describe-repositories \
      --repository-names "${repo_name}" --query 'repositories[0]' --output json)" \
      || ecr_rc=$?
    if [[ "${ecr_rc}" == 0 ]]; then
      repo_arn="$(jq -r '.repositoryArn' <<<"${repo_json}")"
      repo_tag_rc=0
      repo_tag_raw="$(aws ecr list-tags-for-resource --resource-arn "${repo_arn}" \
        --query "tags[?Key=='ManagedBy'].Value | [0]" --output text)" \
        || repo_tag_rc=$?
      if [[ "${repo_tag_rc}" != 0 ]]; then
        note_fail "could not read the tags on ECR repository ${repo_name};" \
          "could not determine whether it is this sample's; left it alone"
      else
        repo_tag="$(tag_or_empty "${repo_tag_raw}")"
        if [[ "${repo_tag}" != "${MANAGED_BY}" ]]; then
          note_fail "ECR repository ${repo_name} does not carry ManagedBy=${MANAGED_BY}" \
            "(found '${repo_tag}'); left it alone"
        else
          echo "Deleting ECR repository ${repo_name} and the application image in it..."
          aws ecr delete-repository --repository-name "${repo_name}" --force >/dev/null \
            || note_fail "could not delete ECR repository ${repo_name}"
        fi
      fi
    elif [[ "${ecr_rc}" == 1 ]]; then
      echo "ECR repository ${repo_name} is already gone."
    else
      note_fail "could not determine whether ECR repository ${repo_name} exists"
    fi
  fi

  # ---------------------------------------------------------------------- local files

  # The run files hold the resource ids and the registry credentials, so they are removed
  # only when there is nothing left to come back for: not after a clean up that left something
  # behind, and not when the AWS resources were kept on purpose.
  #
  # run/, debug/ and changed/, the directories setup.sh, debug.sh and changed-source.sh
  # write and nothing else does: debug/ and changed/ hold their own registry credentials,
  # plaintext and ciphertexts. The rmdir removes the parent folder too when it holds nothing
  # else, and is left to fail quietly when it does not.
  if [[ "${failed}" != 0 ]]; then
    echo "Keeping the run files under ${TMP_DIR}: the clean up left something behind," \
      "and they hold the ids needed to finish it."
  elif [[ "${keep_aws}" == true ]]; then
    echo "Keeping the run files under ${TMP_DIR}: they hold the ids of the AWS resources" \
      "that were kept."
  else
    echo "Deleting the run files under ${TMP_DIR}..."
    local tmp_root
    tmp_root="$(dirname "${TMP_DIR}")"
    if rm -rf "${TMP_DIR}" "${tmp_root}/debug" "${tmp_root}/changed"; then
      rmdir "${tmp_root}" 2>/dev/null || true
    else
      note_fail "could not remove the run files under ${tmp_root};" \
        "they hold this account's resource ids"
    fi
  fi

  echo
  if [[ "${failed}" == 0 ]]; then
    if [[ "${keep_aws}" == true ]]; then
      echo "Clean up complete. The AWS resources were kept on purpose."
    else
      echo "Clean up complete. The KMS key is scheduled, not yet destroyed;" \
        "AWS removes it after its waiting period."
    fi
  else
    echo "Clean up finished with items left behind (see the INCOMPLETE lines above)." >&2
  fi
  exit "${failed}"
}

main "$@"
