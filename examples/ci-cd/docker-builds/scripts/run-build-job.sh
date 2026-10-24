#!/usr/bin/env bash
# Run the Docker-in-Docker build as a Job, unattended, and wait for it to finish.
#
#   ./scripts/run-build-job.sh           build the image and run it, with no registry
#   ./scripts/run-build-job.sh --push    also push it to the sample's ECR repository
#
# Run it twice to see the EBS layer cache at work: the claim is kept between runs, so the
# second build reuses the layers the first one wrote. A Job's pod template is immutable, so
# an earlier Job of this sample is deleted first (and only one that carries this sample's
# label).
#
# --push needs scripts/ecr-setup.sh to have created the repository, the role and the Pod
# Identity association; it reads what that script recorded in .docker-builds.state.
#
# Overridable: NAMESPACE (default docker-builds-sample), KUBE_CONTEXT.
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SAMPLE_DIR"

NAMESPACE="${NAMESPACE:-docker-builds-sample}"
SAMPLE_LABEL_JSONPATH='app\.kubernetes\.io/part-of'
STATE_FILE="$SAMPLE_DIR/.docker-builds.state"
JOB=docker-build
PUSH=false

for arg in "$@"; do
  case "$arg" in
    --push) PUSH=true ;;
    *) printf 'error: unknown argument: %s (supported: --push)\n' "$arg" >&2; exit 2 ;;
  esac
done

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

KUBE_CONTEXT="${KUBE_CONTEXT:-}"
kc() { if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi; }
command -v kubectl >/dev/null 2>&1 || die "kubectl is not on PATH"

# Everything this script touches is inside the sample's own namespace, so the namespace's
# label is the ownership check.
mark="$(kc get namespace "$NAMESPACE" -o "jsonpath={.metadata.labels.$SAMPLE_LABEL_JSONPATH}" 2>/dev/null || true)"
[[ "$mark" == "docker-builds" ]] || die "namespace '$NAMESPACE' is not this sample's (it is not labelled
app.kubernetes.io/part-of=docker-builds). Run ./scripts/setup.sh first."

ECR_REGISTRY=""
ECR_REPO=""
AWS_REGION_RENDER="${AWS_REGION:-}"
init_block=""
if [[ "$PUSH" == true ]]; then
  [[ -f "$STATE_FILE" ]] || die "--push needs ./scripts/ecr-setup.sh to have run first (no $STATE_FILE)"
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  [[ "${ECR_PUSH_READY:-false}" == "true" ]] \
    || die "--push needs ./scripts/ecr-setup.sh to have completed (the state file does not record a ready push)"
  # The association is namespaced, so a push set up for another namespace is not this run's.
  [[ "${ECR_NAMESPACE:-}" == "$NAMESPACE" ]] \
    || die "the recorded Amazon ECR push belongs to namespace '${ECR_NAMESPACE:-unknown}', not '$NAMESPACE'.
Run ./scripts/ecr-setup.sh for this namespace, or drop --push."
  ECR_REGISTRY="${ECR_ACCOUNT_ID}.dkr.ecr.${ECR_AWS_REGION}.amazonaws.com"
  ECR_REPO="${ECR_REPO_NAME}"
  AWS_REGION_RENDER="${ECR_AWS_REGION}"
  # The init container exists only on the push path: it turns the credential EKS Pod Identity
  # vends to this pod's ServiceAccount into an Amazon ECR authorization token, and writes it
  # to a file in the pod's own guest for `docker login` to read on standard input. The token
  # is never printed and never appears on a command line.
  init_block=$(cat <<'YAML'
      initContainers:
        - name: ecr-token
          image: public.ecr.aws/aws-cli/aws-cli:2.38.5
          command: ["/bin/sh", "-c"]
          args:
            - |
              umask 077
              aws ecr get-login-password --region "$AWS_REGION" > /ecr/token
              echo "wrote an Amazon ECR authorization token for $ECR_REGISTRY"
          env:
            - { name: AWS_REGION,   value: "<AWS_REGION>" }
            - { name: ECR_REGISTRY, value: "<ECR_REGISTRY>" }
          volumeMounts:
            - name: ecr-token
              mountPath: /ecr
YAML
)
  echo "Pushing to $ECR_REGISTRY/$ECR_REPO when the build succeeds."
else
  echo "Building and running the image with no registry (pass --push to also push to Amazon ECR)."
fi

if kc -n "$NAMESPACE" get "job/$JOB" >/dev/null 2>&1; then
  job_mark="$(kc -n "$NAMESPACE" get "job/$JOB" -o "jsonpath={.metadata.labels.$SAMPLE_LABEL_JSONPATH}")"
  [[ "$job_mark" == "docker-builds" ]] || die "a Job named $JOB exists in '$NAMESPACE' without this sample's
label; refusing to delete it"
  echo "Deleting the previous $JOB Job so this run starts clean (its pod template is immutable)."
  # --wait so the old pod releases the ReadWriteOncePod cache volume before the new one
  # tries to attach it.
  kc -n "$NAMESPACE" delete "job/$JOB" --wait=true
fi

# Render the Job: the namespace, the registry values, and the init container block (nothing
# at all unless --push).
sed -e "s|<NAMESPACE>|$NAMESPACE|g" \
    -e "s|<ECR_REGISTRY>|$ECR_REGISTRY|g" \
    -e "s|<ECR_REPO>|$ECR_REPO|g" \
    -e "s|<AWS_REGION>|$AWS_REGION_RENDER|g" \
    deploy/build-job.yaml \
  | awk -v block="$init_block" '{ if ($0 == "<ECR_INIT_CONTAINER>") { if (block != "") print block } else print }' \
  | sed -e "s|<AWS_REGION>|$AWS_REGION_RENDER|g" -e "s|<ECR_REGISTRY>|$ECR_REGISTRY|g" \
  | kc apply -f -

echo "Waiting for the build to finish (a cold build pulls base images and compiles; a warm one is much faster)."
# Poll for either terminal condition, so a build that fails is reported when it fails rather
# than after the whole timeout.
done_at=$(( SECONDS + 1200 ))
while :; do
  if kc -n "$NAMESPACE" get "job/$JOB" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' | grep -q True; then
    break
  fi
  if kc -n "$NAMESPACE" get "job/$JOB" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' | grep -q True; then
    kc -n "$NAMESPACE" logs "job/$JOB" --tail=40 | sed 's/^/  /' || true
    die "the $JOB Job failed; read the whole log with: kubectl logs job/$JOB -n $NAMESPACE"
  fi
  [[ "$SECONDS" -lt "$done_at" ]] \
    || die "the $JOB Job did not finish within 20m; check: kubectl describe job/$JOB -n $NAMESPACE"
  sleep 5
done

echo
kc -n "$NAMESPACE" logs "job/$JOB"
echo
echo "Run it again for a warm cache: NAMESPACE=$NAMESPACE ./scripts/run-build-job.sh${*:+ $*}"
