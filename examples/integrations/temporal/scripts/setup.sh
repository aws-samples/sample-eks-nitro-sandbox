#!/usr/bin/env bash
# Stand up the sample: the Worker image, the namespace, the Worker's RBAC and
# the Worker itself. It creates no Sandbox: the workflow does that.
#
#   ./scripts/setup.sh
#
# What it does NOT do is install anything shared. The agent-sandbox controller
# and the Temporal server are both shared installs that other workloads on your
# cluster may depend on, so this script reads them, reuses them exactly as they
# stand, and stops with the command when one is missing or is set up differently
# from what this sample needs.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

require_commands kubectl aws docker sed grep tr cut find sort sha256sum mktemp
show_context

# --- the prerequisites, all read before anything is created -----------------
# A missing prerequisite stops the run with no leftovers, which is why these
# come before the ECR repository and the namespace.
step "1/6 prerequisites, reused as they are"
require_runtime_class
require_agent_sandbox
require_temporal_server

# The StorageClass the workflow's workspace claim will name. Chosen here so the
# choice is settled before the Worker is deployed with it in its environment.
choose_storage_class

# --- the image --------------------------------------------------------------
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || die "could not read the AWS account id with 'aws sts get-caller-identity'; check your credentials and AWS_REGION"
[[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die "'aws sts get-caller-identity' returned '$ACCOUNT_ID', which is not a 12-digit account id"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# The tag is derived from every file the image is built from, so a change to any
# of them produces a new tag and the push below cannot serve a stale image.
mapfile -t worker_files < <(cd "$SAMPLE_DIR" && find worker -type f | sort)
((${#worker_files[@]} > 0)) || die "no files under $SAMPLE_DIR/worker; cannot derive an image tag"
# The tag only reproduces the image if every file the Dockerfile copies in is in
# the hashed set. Check that, rather than trusting it: a COPY from outside
# worker/ would leave the tag unchanged while the image content moved.
while read -r _copy _src _dst; do
  [[ "$_src" == worker/* ]] \
    || die "Dockerfile COPY source '$_src' is not under worker/, so it is not in the hashed set and the image tag would not change when it does; move it under worker/ or extend the tag input"
done < <(grep -E '^COPY[[:space:]]' "$SAMPLE_DIR/worker/Dockerfile")
IMAGE_TAG="${IMAGE_TAG:-$( cd "$SAMPLE_DIR" && cat "${worker_files[@]}" | sha256sum | cut -c1-12 )}"
# The tag is built inside a command substitution, where a failure does not trip
# `set -e`, so an unreadable file under worker/ would leave it empty and the
# image reference would be "<repo>:" with no tag. Check its shape rather than
# trust it, and accept a tag the reader set in .env as long as it is a valid
# Docker tag.
[[ -n "$IMAGE_TAG" ]] || die "the image tag came out empty, so one of the files under worker/ could not be read; stopping rather than build an untagged image"
[[ "$IMAGE_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] \
  || die "IMAGE_TAG '$IMAGE_TAG' is not a valid Docker tag (alphanumerics, dots, dashes and underscores, not starting with a dot or dash)"
WORKER_IMAGE="${REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"

step "2/6 ECR repository $ECR_REPOSITORY"
repo_rc=0
aws_exists RepositoryNotFoundException -- aws ecr describe-repositories \
  --repository-names "$ECR_REPOSITORY" --region "$AWS_REGION" || repo_rc=$?
[[ $repo_rc -eq 2 ]] && die "could not read ECR repository $ECR_REPOSITORY, so whether it exists could not be determined; stopping rather than create one on a read that never answered: $AWS_LAST_ERROR"
if [[ $repo_rc -eq 0 ]]; then
  # It is there. Reuse it only when it carries the sample's mark: another demo in
  # this account may well own a repository with a similar name.
  repo_arn="$(aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" \
    --region "$AWS_REGION" --query 'repositories[0].repositoryArn' --output text 2>/dev/null)" \
    || die "could not read the ARN of ECR repository $ECR_REPOSITORY"
  tags="$(aws ecr list-tags-for-resource --resource-arn "$repo_arn" --region "$AWS_REGION" \
    --query "tags[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null)" \
    || die "could not read the tags on ECR repository $ECR_REPOSITORY; stopping rather than push into a repository I cannot verify is the sample's"
  [[ "$tags" == "$MANAGED_BY" ]] \
    || die "ECR repository $ECR_REPOSITORY exists but is not tagged ManagedBy=$MANAGED_BY (read: '${tags:-<none>}'); it belongs to something else. Set ECR_REPOSITORY in .env to a free name and re-run."
  echo "reusing ECR repository $ECR_REPOSITORY (ManagedBy=$MANAGED_BY)"
else
  aws ecr create-repository --repository-name "$ECR_REPOSITORY" --region "$AWS_REGION" \
    --image-scanning-configuration scanOnPush=true \
    --tags "Key=ManagedBy,Value=$MANAGED_BY" >/dev/null \
    || die "could not create ECR repository $ECR_REPOSITORY"
  echo "created ECR repository $ECR_REPOSITORY, tagged ManagedBy=$MANAGED_BY"
fi

step "3/6 build and push the Worker image"
echo "  $WORKER_IMAGE"
# Three outcomes, not two. `>/dev/null 2>&1` on its own would send a denied or
# throttled read down the same branch as "the image is not there", which is the
# fail-open pattern this sample is at pains to avoid everywhere else. Here the
# unsafe direction happens to be the harmless one, a rebuild of an image that
# was already pushed, but the shape is the thing a reader copies.
img_rc=0
aws_exists ImageNotFoundException -- aws ecr describe-images \
  --repository-name "$ECR_REPOSITORY" --region "$AWS_REGION" \
  --image-ids "imageTag=$IMAGE_TAG" || img_rc=$?
[[ $img_rc -eq 2 ]] && die "could not read the images in ECR repository $ECR_REPOSITORY, so whether this tag is already pushed could not be determined; stopping rather than guess: $AWS_LAST_ERROR"
if [[ $img_rc -eq 0 ]]; then
  echo "  already in the repository at this tag; not rebuilding"
else
  # A docker config of its own, so the login token never lands in the machine's
  # shared ~/.docker/config.json.
  docker_cfg="$(mktemp -d)"
  trap 'rm -rf "$docker_cfg"' EXIT
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker --config "$docker_cfg" login --username AWS --password-stdin "$REGISTRY" >/dev/null \
    || die "could not log in to $REGISTRY"
  # linux/amd64 because the Worker runs on the cluster's nodes, not on this
  # machine. The nodes these runs used are amd64; on arm64 nodes pass
  # --platform linux/arm64 here instead.
  docker build --platform linux/amd64 --file "$SAMPLE_DIR/worker/Dockerfile" \
    --tag "$WORKER_IMAGE" "$SAMPLE_DIR" || die "the Worker image build failed"
  docker --config "$docker_cfg" push "$WORKER_IMAGE" || die "the Worker image push failed"
fi

step "4/6 namespace $NAMESPACE"
# Create the namespace only when it is absent, and label it so the clean up can
# tell it is the sample's. Applying over an existing namespace counts as reusing
# it, which would put the sample's label on a namespace another demo owns, so
# check first. A read that fails is never read as "absent".
ns_rc=0
namespace_is_ours || ns_rc=$?
case $ns_rc in
  0) echo "namespace $NAMESPACE already exists and is the sample's; reusing it" ;;
  1) die "namespace $NAMESPACE exists but is not labelled $NS_LABEL_KEY=$NS_LABEL_VAL; it belongs to something else. Set NAMESPACE to a free name in .env and re-run." ;;
  2) die "could not read the labels on namespace $NAMESPACE; stopping rather than guess" ;;
  3) kc_cluster create namespace "$NAMESPACE"
     # If the label does not go on, remove the namespace again rather than leave
     # an unmarked one behind: every later script refuses to touch a namespace
     # without the label, and the clean up would refuse to delete it.
     kc_cluster label namespace "$NAMESPACE" "$NS_LABEL_KEY=$NS_LABEL_VAL" || {
       kc_cluster delete namespace "$NAMESPACE" --wait=false >/dev/null 2>&1 || true
       die "created namespace $NAMESPACE but could not label it $NS_LABEL_KEY=$NS_LABEL_VAL; removed it again rather than leave an unmarked namespace behind"
     }
     echo "created namespace $NAMESPACE, labelled $NS_LABEL_KEY=$NS_LABEL_VAL" ;;
esac

step "5/6 the Temporal server, read from a one-shot pod"
# Whether the Temporal NAMESPACE this sample uses exists is a question for the
# server, not for Kubernetes, so it is asked here with the Worker image's own
# preflight module. The pod reads and changes nothing, and it is deleted by its
# exact name when it finishes.
kc delete pod "$PREFLIGHT_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
preflight_rc=0
# --pod-running-timeout: kubectl waits only 1m for the pod by default, and on EKS
# Auto Mode a new node and the image pull can take longer than that.
kc run "$PREFLIGHT_POD" --image="$WORKER_IMAGE" --restart=Never --attach --rm --quiet \
  --pod-running-timeout=5m \
  --labels="app.kubernetes.io/managed-by=$SAMPLE" \
  --env="TEMPORAL_ADDRESS=$TEMPORAL_ADDRESS" \
  --env="TEMPORAL_NAMESPACE=$TEMPORAL_NAMESPACE" \
  --env="TEMPORAL_TASK_QUEUE=$TASK_QUEUE" \
  --env="SANDBOX_NAMESPACE=$NAMESPACE" \
  --env="SANDBOX_STORAGE_CLASS=$CHOSEN_STORAGE_CLASS" \
  --command -- python -m harness.preflight || preflight_rc=$?
# `kubectl run --rm` deletes the pod itself, but only when it got that far. Make
# sure, by its exact name, never by a label selector.
kc delete pod "$PREFLIGHT_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
case $preflight_rc in
  0) : ;;
  2) die "the Temporal server in namespace $TEMPORAL_K8S_NAMESPACE does not have the Temporal namespace '$TEMPORAL_NAMESPACE' this sample uses. A Temporal server is a shared install, so this script stops rather than add to it: create the namespace with the command the preflight printed, or set TEMPORAL_NAMESPACE in .env to one the server already has." ;;
  *) die "the preflight read of the Temporal server at $TEMPORAL_ADDRESS did not pass, so whether the server is usable could not be determined; stopping rather than deploy a Worker that would sit retrying its connection" ;;
esac

step "6/6 the Worker, its ServiceAccount and its Role"
# Render every manifest with this run's names. Never apply one with a
# placeholder in place, which would create objects in the default-named
# namespace instead of the one this run is using.
sed -e "s/__NAMESPACE__/$NAMESPACE/g" "$SAMPLE_DIR/deploy/rbac.yaml" | kc apply -f -
sed -e "s/__NAMESPACE__/$NAMESPACE/g" \
    -e "s|__WORKER_IMAGE__|$WORKER_IMAGE|g" \
    -e "s/__TEMPORAL_ADDRESS__/$TEMPORAL_ADDRESS/g" \
    -e "s/__TEMPORAL_NAMESPACE__/$TEMPORAL_NAMESPACE/g" \
    -e "s/__TASK_QUEUE__/$TASK_QUEUE/g" \
    -e "s/__SANDBOX_NAME__/$SANDBOX_NAME/g" \
    -e "s/__STORAGE_CLASS__/$CHOSEN_STORAGE_CLASS/g" \
    -e "s/__SUSPENDED_SECONDS__/$SUSPENDED_SECONDS/g" \
    "$SAMPLE_DIR/deploy/worker.yaml" | kc apply -f -
kc rollout status "deploy/$WORKER" --timeout=5m \
  || die "the Worker did not become ready. Its logs say why when the process started and failed, and the pod's events say why when it never started at all:
  kubectl -n $NAMESPACE logs deploy/$WORKER
  kubectl -n $NAMESPACE describe pod -l app.kubernetes.io/name=$WORKER"

echo
echo "the Worker is polling task queue $TASK_QUEUE on $TEMPORAL_ADDRESS, namespace $TEMPORAL_NAMESPACE"
echo "it will drive sandbox/$SANDBOX_NAME in namespace $NAMESPACE, workspace on storageclass $CHOSEN_STORAGE_CLASS"
echo
echo "Start a run:        ./scripts/run-workflow.sh --wait"
echo "Watch it:           kubectl -n $TEMPORAL_K8S_NAMESPACE port-forward svc/$TEMPORAL_WEB_SVC 8080:8080"
echo "Tear it down:       ./scripts/cleanup.sh"
