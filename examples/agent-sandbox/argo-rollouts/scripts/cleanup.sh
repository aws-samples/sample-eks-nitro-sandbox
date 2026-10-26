#!/usr/bin/env bash
# Remove what this sample created.
#
#   ./scripts/cleanup.sh                # the sample's own objects
#   ./scripts/cleanup.sh --unregister   # and undo the registration on the controller
#
# By default this removes only the sample's own objects: everything in its
# namespace, and the ClusterRole and ClusterRoleBinding the registration created.
# It leaves the shared install alone, and prints what stays with the commands to
# remove it.
#
# --unregister also undoes the page's registration step, in the one order that is
# safe: take the initContainer off the controller first, then remove the
# stepPlugins key, and only then delete the ECR repository. Deleting the
# repository first would leave the controller unable to start the next time it
# restarted, because its initContainer would have no image to pull.
#
# It exits non-zero when it skipped something or could not tell whether something
# was gone. A lookup that fails means "could not determine", which is a failure,
# never "gone".
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

MODE="${1:-}"
[[ -z "$MODE" || "$MODE" == "--unregister" ]] || die "usage: $0 [--unregister]"

require_commands kubectl
[[ "$MODE" == "--unregister" ]] && require_commands aws jq
show_context

# Anything this script could not remove or could not check is recorded here, and
# makes the run exit non-zero at the end. A clean up that says it is done when it
# is not is worse than one that fails.
INCOMPLETE=()
note_incomplete() { INCOMPLETE+=("$1"); echo "  INCOMPLETE: $1" >&2; }

# --- the sample's own namespace ---------------------------------------------
step "1/3 the sample's namespace $NAMESPACE"
ns_rc=0
namespace_is_ours || ns_rc=$?
case $ns_rc in
  0)
    # Delete the pool FIRST so it stops booting replacements while the rest goes
    # away. Inside a namespace this sample owns, the namespace label is the mark,
    # so there is no need to check each object in it.
    echo "  deleting the warm pool first, so it stops booting replacements"
    kc delete sandboxwarmpool "$POOL" --ignore-not-found --wait=true --timeout=180s \
      || note_incomplete "could not delete sandboxwarmpool/$POOL in $NAMESPACE"
    echo "  deleting the namespace and everything in it"
    if kc_cluster delete namespace "$NAMESPACE" --wait=true --timeout=600s; then
      echo "  deleted namespace $NAMESPACE"
    else
      note_incomplete "could not delete namespace $NAMESPACE"
    fi ;;
  1) note_incomplete "namespace $NAMESPACE exists but is not labelled $NS_LABEL_KEY=$NS_LABEL_VAL, so it is not this sample's and nothing in it was touched" ;;
  2) note_incomplete "could not read namespace $NAMESPACE, so whether it is this sample's could not be determined" ;;
  3) echo "  namespace $NAMESPACE does not exist; nothing to remove" ;;
esac

# --- the cluster-scoped RBAC the registration created -----------------------
# These are outside the namespace, so each is checked for the sample's label
# before it is deleted.
step "2/3 the ClusterRole and ClusterRoleBinding"
delete_if_ours() {   # delete_if_ours <kind> <name>
  local kind=$1 name=$2 owner rc=0
  rc=0; resource_exists kc_cluster "$kind" "$name" || rc=$?
  case $rc in
    1) echo "  $kind/$name does not exist; nothing to remove"; return 0 ;;
    2) note_incomplete "could not read $kind/$name, so whether it is this sample's could not be determined"; return 0 ;;
  esac
  owner="$(kc_cluster get "$kind" "$name" \
    -o "jsonpath={.metadata.labels.app\\.kubernetes\\.io/managed-by}" 2>/dev/null)" || owner="?"
  if [[ "$owner" == "?" ]]; then
    note_incomplete "could not read the labels on $kind/$name"
  elif [[ "$owner" != "$SAMPLE" ]]; then
    note_incomplete "$kind/$name exists but is not labelled app.kubernetes.io/managed-by=$SAMPLE, so it is not this sample's and was left alone"
  elif kc_cluster delete "$kind" "$name" --ignore-not-found; then
    echo "  deleted $kind/$name"
  else
    note_incomplete "could not delete $kind/$name"
  fi
}
delete_if_ours clusterrolebinding argo-rollouts-sandbox-warmpool
delete_if_ours clusterrole argo-rollouts-sandbox-warmpool

# --- the registration on the shared controller ------------------------------
step "3/3 the registration on the Argo Rollouts controller"
if [[ "$MODE" != "--unregister" ]]; then
  cat <<EOF
  Left in place, because it is shared with the rest of the cluster:
    - the Argo Rollouts install in namespace $ARGO_NAMESPACE
    - the stepPlugins key in configmap $ARGO_NAMESPACE/argo-rollouts-config
    - the initContainer on deployment $ARGO_NAMESPACE/argo-rollouts that stages the binary
    - the ECR repository $PLUGIN_REPO
  Undo all four, in a safe order, with:
    ./scripts/cleanup.sh --unregister
EOF
else
  # 1) the controller Deployment. A strategic merge patch deletes list entries by
  #    name, so another initContainer, volume or mount on the controller is kept.
  #    fsGroup goes back to unset, which is what the install ships; the
  #    registration refused to run if it had found a different one, so there is
  #    nothing else it could have been.
  # unpatched stays empty until the controller no longer references the plugin
  # image. The ECR repository is deleted only when it is set: a repository
  # removed while the controller still names its image would stop the controller
  # from starting the next time it restarted, which would break it for every
  # workload on the cluster, not just this sample.
  unpatched=""
  dep_rc=0
  resource_exists kc_cluster -n "$ARGO_NAMESPACE" deployment argo-rollouts || dep_rc=$?
  case $dep_rc in
    1) echo "  deployment $ARGO_NAMESPACE/argo-rollouts does not exist; nothing to unpatch"
       unpatched=1 ;;
    2) note_incomplete "could not read deployment $ARGO_NAMESPACE/argo-rollouts" ;;
    0)
      # A strategic merge patch deletes a list entry by that list's own merge
      # key, which is NOT `name` for every list: volumeMounts merge on
      # mountPath, while initContainers and volumes merge on name. Using `name`
      # for the mount is rejected outright ("does not contain declared merge
      # key: mountPath").
      read -r -d '' unpatch <<'YAML' || true
spec:
  template:
    spec:
      securityContext:
        fsGroup: null
      initContainers:
        - name: copy-sandbox-warmpool-plugin
          $patch: delete
      volumes:
        - name: plugins
          $patch: delete
      containers:
        - name: argo-rollouts
          volumeMounts:
            - mountPath: /plugins
              $patch: delete
YAML
      if kc_cluster -n "$ARGO_NAMESPACE" patch deployment argo-rollouts --type=strategic -p "$unpatch" >/dev/null; then
        echo "  took the initContainer and the /plugins volume off deployment argo-rollouts"
        if kc_cluster -n "$ARGO_NAMESPACE" rollout status deploy/argo-rollouts --timeout=180s; then
          unpatched=1
        else
          note_incomplete "deployment $ARGO_NAMESPACE/argo-rollouts did not settle after the patch was removed; check 'kubectl -n $ARGO_NAMESPACE get pods'"
        fi
      else
        note_incomplete "could not take the plugin staging off deployment $ARGO_NAMESPACE/argo-rollouts"
      fi ;;
  esac

  # 2) the stepPlugins key, removed only when it holds exactly this sample's two
  #    entries. If somebody else has added to it since, leave it and say so.
  reg_rc=0
  registered="$(registered_step_plugins)" || reg_rc=$?
  case $reg_rc in
    1) echo "  configmap $ARGO_NAMESPACE/argo-rollouts-config does not exist; nothing to unregister" ;;
    2) note_incomplete "could not read configmap $ARGO_NAMESPACE/argo-rollouts-config, so the registration was left in place" ;;
    0)
      foreign=""
      while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        [[ "$name" == "$STEP_PATCH" || "$name" == "$STEP_DRAIN" ]] && continue
        foreign+=" $name"
      done <<<"$registered"
      if [[ -n "$foreign" ]]; then
        note_incomplete "configmap $ARGO_NAMESPACE/argo-rollouts-config also registers step plugins that are not this sample's ($foreign), so the stepPlugins key was left as it is. Remove this sample's two entries by hand if you want them gone."
      elif kc_cluster -n "$ARGO_NAMESPACE" patch configmap argo-rollouts-config \
             --type=json -p '[{"op":"remove","path":"/data/stepPlugins"}]' >/dev/null 2>&1; then
        echo "  removed the stepPlugins key from configmap argo-rollouts-config"
      else
        # An absent key is the end state we want, so tell that apart from a failure.
        still="$(registered_step_plugins 2>/dev/null)" || still="?"
        if [[ -z "$still" ]]; then
          echo "  the stepPlugins key is already absent from configmap argo-rollouts-config"
        else
          note_incomplete "could not remove the stepPlugins key from configmap $ARGO_NAMESPACE/argo-rollouts-config"
        fi
      fi ;;
  esac

  # 3) the ECR repository, last, and only when the controller no longer
  #    references its image AND the repository carries this sample's tag.
  if [[ -z "$unpatched" ]]; then
    note_incomplete "the ECR repository $PLUGIN_REPO was left in place, because the plugin staging could not be taken off deployment $ARGO_NAMESPACE/argo-rollouts. Deleting the repository while the controller still names its image would stop the controller starting the next time it restarts. Fix the Deployment first, then run this again."
  elif [[ -z "${AWS_REGION:-}" ]]; then
    note_incomplete "AWS_REGION is not set, so the ECR repository $PLUGIN_REPO was not removed. Set it in .env and run this again."
  else
    acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || acct=""
    if [[ -z "$acct" ]]; then
      note_incomplete "could not read the AWS account, so the ECR repository $PLUGIN_REPO was not removed"
    else
      repo_arn="arn:aws:ecr:${AWS_REGION}:${acct}:repository/${PLUGIN_REPO}"
      if repo_out="$(aws ecr describe-repositories --repository-names "$PLUGIN_REPO" \
                       --region "$AWS_REGION" 2>&1)"; then
        tags_out="$(aws ecr list-tags-for-resource --resource-arn "$repo_arn" --region "$AWS_REGION" 2>&1)" || tags_out=""
        if [[ -z "$tags_out" ]]; then
          note_incomplete "ECR repository $PLUGIN_REPO exists but its tags could not be read, so whether it is this sample's could not be determined; it was left in place"
        else
          owned="$(printf '%s' "$tags_out" | jq -r --arg m "$MANAGED_BY" 'any(.tags[]?; .Key=="ManagedBy" and .Value==$m)' 2>/dev/null)" || owned="?"
          if [[ "$owned" == "true" ]]; then
            if aws ecr delete-repository --repository-name "$PLUGIN_REPO" --region "$AWS_REGION" --force >/dev/null 2>&1; then
              echo "  deleted ECR repository $PLUGIN_REPO"
            else
              note_incomplete "could not delete ECR repository $PLUGIN_REPO"
            fi
          elif [[ "$owned" == "false" ]]; then
            note_incomplete "ECR repository $PLUGIN_REPO exists but is not tagged ManagedBy=$MANAGED_BY, so it is not this sample's and was left alone"
          else
            note_incomplete "could not tell whether ECR repository $PLUGIN_REPO is this sample's; it was left in place"
          fi
        fi
      else
        case "$repo_out" in
          *RepositoryNotFoundException*) echo "  ECR repository $PLUGIN_REPO does not exist; nothing to remove" ;;
          *) note_incomplete "could not read ECR repository $PLUGIN_REPO, so whether it is gone could not be determined" ;;
        esac
      fi
    fi
  fi

  cat <<EOF

  Still installed, because other workloads on the cluster may use it:
    - Argo Rollouts in namespace $ARGO_NAMESPACE
    - the agent-sandbox controller
  If nothing else on this cluster uses Argo Rollouts, remove it with:
    kubectl -n $ARGO_NAMESPACE delete -f \\
      https://github.com/argoproj/argo-rollouts/releases/download/$ARGO_ROLLOUTS_VERSION/install.yaml
    kubectl delete namespace $ARGO_NAMESPACE
EOF
fi

echo
if ((${#INCOMPLETE[@]})); then
  printf 'the clean up did not finish: %d thing(s) were skipped or could not be checked\n' "${#INCOMPLETE[@]}" >&2
  printf '  - %s\n' "${INCOMPLETE[@]}" >&2
  exit 1
fi
echo "clean up complete."
