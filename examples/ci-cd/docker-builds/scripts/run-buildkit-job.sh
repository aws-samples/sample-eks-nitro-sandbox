#!/usr/bin/env bash
# Optional: run the same build with a standalone BuildKit daemon as a Job, and wait for it.
#
#   ./scripts/run-buildkit-job.sh
#
# It creates a second EBS claim (buildkit-cache) for buildkitd's own cache, because the
# claims are ReadWriteOncePod and the two builders keep their state in different places. The
# clean up removes it.
#
# Overridable: NAMESPACE (default docker-builds-sample), STORAGE_CLASS, KUBE_CONTEXT.
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SAMPLE_DIR"

NAMESPACE="${NAMESPACE:-docker-builds-sample}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
SAMPLE_LABEL_JSONPATH='app\.kubernetes\.io/part-of'
WANT_PROVISIONER="ebs.csi.eks.amazonaws.com"
JOB=buildkit-build

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

KUBE_CONTEXT="${KUBE_CONTEXT:-}"
kc() { if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi; }
command -v kubectl >/dev/null 2>&1 || die "kubectl is not on PATH"

mark="$(kc get namespace "$NAMESPACE" -o "jsonpath={.metadata.labels.$SAMPLE_LABEL_JSONPATH}" 2>/dev/null || true)"
[[ "$mark" == "docker-builds" ]] || die "namespace '$NAMESPACE' is not this sample's (it is not labelled
app.kubernetes.io/part-of=docker-builds). Run ./scripts/setup.sh first."

# The claim for buildkitd's cache, created only when absent, through the same chosen class as
# the Docker-in-Docker cache. Reading the class off that claim keeps the two consistent and
# means this script never has to choose one.
if kc -n "$NAMESPACE" get pvc buildkit-cache >/dev/null 2>&1; then
  echo "Reusing the existing buildkit-cache claim."
else
  class="${STORAGE_CLASS:-$(kc -n "$NAMESPACE" get pvc docker-build-cache -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)}"
  [[ -n "$class" ]] || die "could not tell which StorageClass to use: run ./scripts/setup.sh first, or set STORAGE_CLASS"
  prov="$(kc get storageclass "$class" --ignore-not-found -o jsonpath='{.provisioner}')" \
    || die "could not read StorageClass '$class'; re-run once the cluster reads cleanly"
  [[ "$prov" == "$WANT_PROVISIONER" ]] || die "StorageClass '$class' uses provisioner '${prov:-<none>}', not '$WANT_PROVISIONER'"
  sed -e "s|<NAMESPACE>|$NAMESPACE|g" -e "s|<CACHE_CLAIM>|buildkit-cache|g" -e "s|<STORAGE_CLASS>|$class|g" \
    deploy/cache-pvc.yaml | kc create -f -
fi

if kc -n "$NAMESPACE" get "job/$JOB" >/dev/null 2>&1; then
  job_mark="$(kc -n "$NAMESPACE" get "job/$JOB" -o "jsonpath={.metadata.labels.$SAMPLE_LABEL_JSONPATH}")"
  [[ "$job_mark" == "docker-builds" ]] || die "a Job named $JOB exists in '$NAMESPACE' without this sample's label; refusing to delete it"
  echo "Deleting the previous $JOB Job so this run starts clean."
  kc -n "$NAMESPACE" delete "job/$JOB" --wait=true
fi

sed -e "s|<NAMESPACE>|$NAMESPACE|g" deploy/buildkit-job.yaml | kc apply -f -

echo "Waiting for the BuildKit build to finish."
# Poll for either terminal condition, so a failure is reported when it happens.
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
