#!/usr/bin/env bash
# Remove everything this sample created, and only that.
#
#   ./scripts/cleanup.sh
#
# In order, because each step would otherwise be undone by the one before it:
# the Worker first, since a Worker left running can create another Sandbox; then
# any Sandbox a run left behind, by its exact name; then the Worker's RBAC, the
# namespace, the sample's own StorageClass if setup made one, and the ECR
# repository.
#
# It never removes a shared install. The agent-sandbox controller and the
# Temporal server both stay, and the last lines say how to remove them.
#
# A lookup that fails means "could not determine", which is a failure and never
# "gone". Anything skipped or unconfirmed makes this script exit non-zero, so an
# incomplete clean up is never reported as done.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

require_commands kubectl aws grep tr
show_context

INCOMPLETE=0
note_incomplete() { echo "  INCOMPLETE: $*" >&2; INCOMPLETE=$((INCOMPLETE + 1)); }

# Everything in the sample's namespace is the sample's once the namespace
# carries the sample's label, so this one check covers the Worker, its RBAC, any
# leftover Sandbox and the workspace claim. Without it, a NAMESPACE pointing at
# somebody else's namespace would have this script delete their objects.
ns_rc=0
namespace_is_ours || ns_rc=$?
case $ns_rc in
  0) echo "namespace $NAMESPACE carries $NS_LABEL_KEY=$NS_LABEL_VAL; everything in it is the sample's" ;;
  1) die "namespace $NAMESPACE is not the sample's ($NS_LABEL_KEY=$NS_LABEL_VAL); refusing to delete anything in it. Set NAMESPACE in .env to the one you ran ./scripts/setup.sh with." ;;
  2) die "could not read namespace $NAMESPACE; stopping rather than delete from a namespace I cannot verify" ;;
  3) echo "namespace $NAMESPACE does not exist; nothing in the cluster to remove" ;;
esac

if [[ $ns_rc -eq 0 ]]; then
  step "1/6 delete the Worker, so nothing creates another Sandbox"
  kc delete deployment "$WORKER" --ignore-not-found --timeout=2m \
    || note_incomplete "could not delete deploy/$WORKER"
  # The preflight pod is removed by its exact name. Never by a label selector:
  # a selector meant for one helper pod has deleted another demo's pod on a
  # shared cluster before.
  kc delete pod "$PREFLIGHT_POD" --ignore-not-found --timeout=2m \
    || note_incomplete "could not delete pod/$PREFLIGHT_POD"

  step "2/6 delete any Sandbox a run left behind (and, by ownerReference, its workspace volume)"
  # The workflow deletes its own Sandbox in a finally block, so normally there
  # is nothing here. A run that was terminated rather than cancelled, or a
  # Worker that was deleted and never replaced, leaves one.
  sb_rc=0; resource_exists kc "sandbox/$SANDBOX_NAME" || sb_rc=$?
  case $sb_rc in
    1) echo "  sandbox/$SANDBOX_NAME: not present (a completed run deletes its own)" ;;
    2) note_incomplete "could not read sandbox/$SANDBOX_NAME, so whether a run left one behind could not be determined" ;;
    0)
      # Read the PV behind the workspace claim first, so the delete can be
      # confirmed against the volume rather than against the claim alone. The
      # read is NOT allowed to fail quietly: `|| true` here would turn an
      # unreadable claim into an empty name, and the branch below would then
      # report "nothing to confirm" for a volume that may well still exist.
      pv=""; pv_read_rc=0
      pv="$(kc get "pvc/workspace-$SANDBOX_NAME" --ignore-not-found \
        -o jsonpath='{.spec.volumeName}' 2>/dev/null)" || pv_read_rc=$?
      kc delete "sandbox/$SANDBOX_NAME" --timeout=5m \
        || note_incomplete "could not delete sandbox/$SANDBOX_NAME"
      pvc_rc=0; resource_exists kc "pvc/workspace-$SANDBOX_NAME" || pvc_rc=$?
      case $pvc_rc in
        1) echo "  pvc/workspace-$SANDBOX_NAME: gone" ;;
        0) note_incomplete "pvc/workspace-$SANDBOX_NAME is still present after the Sandbox was deleted" ;;
        2) note_incomplete "could not read pvc/workspace-$SANDBOX_NAME, so whether it is gone could not be determined" ;;
      esac
      if [[ $pv_read_rc -ne 0 ]]; then
        note_incomplete "could not read pvc/workspace-$SANDBOX_NAME to get the name of its volume, so whether the EBS volume behind it is gone could not be determined"
      elif [[ -n "$pv" ]]; then
        if kc_cluster wait --for=delete "persistentvolume/$pv" --timeout=5m >/dev/null 2>&1; then
          echo "  pv $pv (its EBS volume): gone"
        else
          pv_rc=0; resource_exists kc_cluster "persistentvolume/$pv" || pv_rc=$?
          case $pv_rc in
            1) echo "  pv $pv (its EBS volume): gone" ;;
            *) note_incomplete "could not confirm pv $pv and its EBS volume are gone" ;;
          esac
        fi
      else
        # The read succeeded and returned nothing, which is a real answer: the
        # claim is not there, so there is no bound volume to confirm.
        echo "  pvc/workspace-$SANDBOX_NAME was already absent, so there is no volume to confirm"
      fi
      ;;
  esac

  step "3/6 delete the Worker's ServiceAccount, Role and RoleBinding"
  for obj in "rolebinding/$WORKER" "role/$WORKER" "serviceaccount/$WORKER"; do
    kc delete "$obj" --ignore-not-found --timeout=2m \
      || note_incomplete "could not delete $obj"
  done

  step "4/6 delete namespace $NAMESPACE"
  kc_cluster delete namespace "$NAMESPACE" --timeout=10m \
    || note_incomplete "could not delete namespace $NAMESPACE"
  after_rc=0; resource_exists kc_cluster "namespace/$NAMESPACE" || after_rc=$?
  case $after_rc in
    1) echo "  namespace $NAMESPACE: gone" ;;
    0) note_incomplete "namespace $NAMESPACE is still present" ;;
    2) note_incomplete "could not read namespace $NAMESPACE, so whether it is gone could not be determined" ;;
  esac
else
  step "1-4/6 the namespace is absent, so there is nothing in the cluster to delete"
fi

step "5/6 delete the sample's own StorageClass, if setup made one"
# Only a class that carries the sample's mark. The cluster default is never
# touched, whatever its name.
mark_rc=0
mark="$(sc_field "$SAMPLE_STORAGE_CLASS" '{.metadata.labels.app\.kubernetes\.io/managed-by}')" || mark_rc=$?
prov_rc=0
prov="$(sc_field "$SAMPLE_STORAGE_CLASS" '{.provisioner}')" || prov_rc=$?
if [[ $mark_rc -ne 0 || $prov_rc -ne 0 ]]; then
  note_incomplete "could not read storageclass/$SAMPLE_STORAGE_CLASS, so whether the sample made one could not be determined"
elif [[ -z "$prov" ]]; then
  echo "  storageclass/$SAMPLE_STORAGE_CLASS not present (setup used the cluster default, or it was already removed)"
elif [[ "$mark" != "$SAMPLE" ]]; then
  note_incomplete "storageclass/$SAMPLE_STORAGE_CLASS exists but does not carry $NS_LABEL_KEY=$SAMPLE, so it is not the sample's; leaving it alone"
else
  kc_cluster delete "storageclass/$SAMPLE_STORAGE_CLASS" --timeout=2m \
    && echo "  storageclass/$SAMPLE_STORAGE_CLASS deleted" \
    || note_incomplete "could not delete storageclass/$SAMPLE_STORAGE_CLASS"
fi

step "6/6 delete the ECR repository $ECR_REPOSITORY"
repo_rc=0
aws_exists RepositoryNotFoundException -- aws ecr describe-repositories \
  --repository-names "$ECR_REPOSITORY" --region "$AWS_REGION" || repo_rc=$?
case $repo_rc in
  1) echo "  ECR repository $ECR_REPOSITORY is gone" ;;
  2) note_incomplete "could not read ECR repository $ECR_REPOSITORY, so whether it exists could not be determined: $AWS_LAST_ERROR" ;;
  0)
    # Read the ARN off the repository that was just read, rather than building
    # it from the account id. An unchecked `$(aws sts get-caller-identity ...)`
    # here exits the whole script under `set -e` when STS fails, which skips
    # note_incomplete and the summary below: the clean up would stop part way
    # and never say it had.
    arn_rc=0
    repo_arn="$(aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" \
      --region "$AWS_REGION" --query 'repositories[0].repositoryArn' --output text 2>&1)" || arn_rc=$?
    if [[ $arn_rc -ne 0 || -z "$repo_arn" || "$repo_arn" == "None" ]]; then
      note_incomplete "ECR repository $ECR_REPOSITORY exists but its ARN could not be read, so whether it is the sample's could not be determined: $(tr '\n' ' ' <<<"$repo_arn")"
      repo_arn=""
    fi
    tags_rc=0
    tags=""
    if [[ -n "$repo_arn" ]]; then
      tags="$(aws ecr list-tags-for-resource --resource-arn "$repo_arn" --region "$AWS_REGION" \
        --query "tags[?Key=='ManagedBy'].Value | [0]" --output text 2>&1)" || tags_rc=$?
    else
      tags_rc=1
    fi
    if [[ $tags_rc -ne 0 ]]; then
      note_incomplete "ECR repository $ECR_REPOSITORY exists but its tags could not be read, so whether it is the sample's could not be determined: $(tr '\n' ' ' <<<"$tags")"
    elif [[ "$tags" != "$MANAGED_BY" ]]; then
      note_incomplete "ECR repository $ECR_REPOSITORY exists but is not tagged ManagedBy=$MANAGED_BY (read: '${tags:-<none>}'), so it is not the sample's; leaving it alone"
    else
      aws ecr delete-repository --repository-name "$ECR_REPOSITORY" --region "$AWS_REGION" --force >/dev/null \
        || note_incomplete "could not delete ECR repository $ECR_REPOSITORY"
      aws_verify_absent "ECR repository $ECR_REPOSITORY" RepositoryNotFoundException -- \
        aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" --region "$AWS_REGION" || true
    fi
    ;;
esac

echo
if (( INCOMPLETE > 0 || AWS_CLEAN_FAIL > 0 )); then
  echo "clean up INCOMPLETE: $((INCOMPLETE + AWS_CLEAN_FAIL)) item(s) above were skipped or could not be confirmed. Nothing is reported as deleted that was not read as gone." >&2
  exit 1
fi
cat <<EOF
clean up complete: the Worker, its RBAC, any leftover Sandbox with its workspace
volume, the namespace, the sample's own StorageClass if it made one, and the ECR
repository are all gone.

What stays, and how to remove it:
  the Temporal server in namespace $TEMPORAL_K8S_NAMESPACE, a shared install. Its PostgreSQL
  holds the durable history of every run, which is the record this sample is
  about, so it is kept by default. To remove it, and lose that history:
    helm uninstall $TEMPORAL_RELEASE --namespace $TEMPORAL_K8S_NAMESPACE
    kubectl -n $TEMPORAL_K8S_NAMESPACE delete statefulset/temporal-postgresql service/temporal-postgresql \\
      configmap/temporal-postgresql-initdb secret/temporal-postgresql
    kubectl -n $TEMPORAL_K8S_NAMESPACE delete pvc/data-temporal-postgresql-0
    kubectl delete namespace $TEMPORAL_K8S_NAMESPACE
  Check nothing else on your cluster uses it first:
    helm list --namespace $TEMPORAL_K8S_NAMESPACE

  the Temporal namespace '$TEMPORAL_NAMESPACE' on that server, which goes with it.

  the agent-sandbox controller, shared with the warm pool and the other
  agent-sandbox samples. To remove it, follow the warm pool clean up.
EOF
