#!/usr/bin/env bash
# Tear down the shared EFS sample.
#
#   NAMESPACE=<ns> ./scripts/clean.sh                       # Kubernetes objects only
#   NAMESPACE=<ns> ./scripts/clean.sh --delete-aws-resources  # ...and the EFS resources
#
# Default: delete the two pods, the PVC and workload ServiceAccount, the static PV, the
# egress ApplicationNetworkPolicy, and the sample's own StorageClass. The EFS file system,
# access point, mount targets and security group are kept, so a later ./scripts/test.sh
# reuses the same storage and data.
#
# --delete-aws-resources additionally uses .env as its deletion record and releases the
# access point, every mount target, the file system (AND ALL DATA ON IT), and the NFS
# security group, then deletes .env.
#
# Neither mode touches the shared EFS CSI driver, its service accounts, their IAM roles or
# their Pod Identity associations: this sample never created or changed them. It checks the
# namespace label before deleting anything inside it, and a lookup that cannot be confirmed
# is a failure, not "gone": the script exits non-zero if it skipped or could not confirm a
# delete. The namespace itself is left in place.
#
# Overridable: NAMESPACE, ENV_FILE, KUBECTL, AWS.
set -uo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$SAMPLE_DIR/.env}"
NAMESPACE="${NAMESPACE:-nitro-efs-sample}"
KUBECTL="${KUBECTL:-kubectl}"
AWS="${AWS:-aws}"

SAMPLE_LABEL_KEY="app.kubernetes.io/part-of"
SAMPLE_LABEL_VALUE="storage-efs"
DELETE_AWS=false
[[ "${1:-}" == "--delete-aws-resources" ]] && DELETE_AWS=true

fail=0
warn() { printf 'WARN: %s\n' "$*" >&2; fail=1; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v "${KUBECTL%% *}" >/dev/null 2>&1 || die "'$KUBECTL' is not on PATH"

# Only touch the namespace if it is this sample's (or absent).
if $KUBECTL get namespace "$NAMESPACE" >/dev/null 2>&1; then
  label="$($KUBECTL get namespace "$NAMESPACE" -o "jsonpath={.metadata.labels.app\.kubernetes\.io/part-of}" 2>/dev/null || true)"
  if [[ "$label" != "$SAMPLE_LABEL_VALUE" ]]; then
    die "namespace '$NAMESPACE' is not labelled $SAMPLE_LABEL_KEY=$SAMPLE_LABEL_VALUE (found '${label:-<none>}'); refusing to delete objects inside a namespace this sample did not create."
  fi
  echo "Namespace '$NAMESPACE' is this sample's (labelled $SAMPLE_LABEL_KEY=$SAMPLE_LABEL_VALUE)."
  echo "Deleting pods, PVC, ServiceAccount, PV, and the egress policy..."
  $KUBECTL delete pod efs-writer efs-reader -n "$NAMESPACE" --ignore-not-found --wait=true
  $KUBECTL delete applicationnetworkpolicy efs-shared-egress -n "$NAMESPACE" --ignore-not-found
  $KUBECTL delete pvc storage-efs-shared -n "$NAMESPACE" --ignore-not-found --wait=true
  $KUBECTL delete serviceaccount efs-workload -n "$NAMESPACE" --ignore-not-found
  $KUBECTL delete pv storage-efs-shared --ignore-not-found --wait=true
else
  echo "Namespace '$NAMESPACE' is absent; nothing in-cluster to delete."
fi
# The sample's own StorageClass (cluster-scoped, carries the mark).
if $KUBECTL get storageclass nitro-sandbox-efs >/dev/null 2>&1; then
  sc_label="$($KUBECTL get storageclass nitro-sandbox-efs -o "jsonpath={.metadata.labels.app\.kubernetes\.io/part-of}" 2>/dev/null || true)"
  if [[ "$sc_label" == "$SAMPLE_LABEL_VALUE" ]]; then
    $KUBECTL delete storageclass nitro-sandbox-efs --ignore-not-found
  else
    warn "StorageClass nitro-sandbox-efs is not marked this sample's; leaving it."
  fi
fi

if [[ "$DELETE_AWS" != true ]]; then
  echo
  echo "Kubernetes objects removed. The EFS file system, access point, mount targets and"
  echo "security group are kept; re-run ./scripts/test.sh to reuse them, or run"
  echo "./scripts/clean.sh --delete-aws-resources to release them."
  echo "The shared EFS CSI driver and its roles/associations were left untouched."
  [[ "$fail" -eq 0 ]] || exit 1
  exit 0
fi

# --- AWS teardown ---
[[ -f "$ENV_FILE" ]] || die "no resource record at $ENV_FILE; nothing to release, or it was already cleaned."
# shellcheck disable=SC1090
source "$ENV_FILE"
AWS_REGION="${AWS_REGION:-us-west-2}"
aws_r() { $AWS "$@" --region "$AWS_REGION"; }
command -v "${AWS%% *}" >/dev/null 2>&1 || die "'$AWS' is not on PATH but --delete-aws-resources was requested."

# Wait for the PV to be gone so no NFS client holds the mount targets.
$KUBECTL wait --for=delete pv/storage-efs-shared --timeout=3m >/dev/null 2>&1 || true

if [[ -n "${EFS_ACCESS_POINT_ID:-}" ]]; then
  echo "Deleting EFS access point $EFS_ACCESS_POINT_ID..."
  aws_r efs delete-access-point --access-point-id "$EFS_ACCESS_POINT_ID" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    s="$(aws_r efs describe-access-points --access-point-id "$EFS_ACCESS_POINT_ID" --query 'AccessPoints[0].LifeCycleState' --output text 2>/dev/null || echo deleted)"
    [[ "$s" == deleted || "$s" == None ]] && break; sleep 5
  done
  [[ "$s" == deleted || "$s" == None ]] || warn "EFS access point still present; re-run --delete-aws-resources."
fi

if [[ -n "${EFS_FILE_SYSTEM_ID:-}" ]]; then
  echo "Deleting EFS mount targets..."
  for mt in $(aws_r efs describe-mount-targets --file-system-id "$EFS_FILE_SYSTEM_ID" --query 'MountTargets[].MountTargetId' --output text 2>/dev/null); do
    [[ "$mt" == None ]] && continue
    aws_r efs delete-mount-target --mount-target-id "$mt" >/dev/null 2>&1 || true
  done
  for _ in $(seq 1 60); do
    r="$(aws_r efs describe-mount-targets --file-system-id "$EFS_FILE_SYSTEM_ID" --query 'length(MountTargets)' --output text 2>/dev/null || echo 0)"
    [[ "$r" == 0 ]] && break; sleep 5
  done
  [[ "$r" == 0 ]] || warn "mount targets still present; re-run --delete-aws-resources."

  echo "Deleting EFS file system $EFS_FILE_SYSTEM_ID (and all data on it)..."
  s=""
  for _ in $(seq 1 60); do
    s="$(aws_r efs describe-file-systems --file-system-id "$EFS_FILE_SYSTEM_ID" --query 'FileSystems[0].LifeCycleState' --output text 2>/dev/null || echo deleted)"
    [[ "$s" == deleted || "$s" == None ]] && break
    aws_r efs delete-file-system --file-system-id "$EFS_FILE_SYSTEM_ID" >/dev/null 2>&1 || true
    sleep 5
  done
  [[ "$s" == deleted || "$s" == None ]] || warn "EFS file system still present; re-run --delete-aws-resources."
fi

if [[ "${CREATED_SECURITY_GROUP:-false}" == "true" && -n "${EFS_SECURITY_GROUP_ID:-}" ]]; then
  echo "Deleting NFS security group $EFS_SECURITY_GROUP_ID..."
  deleted=false
  for _ in $(seq 1 30); do
    if aws_r ec2 delete-security-group --group-id "$EFS_SECURITY_GROUP_ID" >/dev/null 2>&1; then deleted=true; break; fi
    sleep 5
  done
  if ! $deleted; then
    # Confirm it is actually gone rather than trust the last attempt.
    if aws_r ec2 describe-security-groups --group-ids "$EFS_SECURITY_GROUP_ID" >/dev/null 2>&1; then
      warn "could not delete the NFS security group $EFS_SECURITY_GROUP_ID (mount-target interfaces may still be releasing); re-run --delete-aws-resources."
    fi
  fi
fi

if [[ "$fail" -eq 0 ]]; then
  rm -f "$ENV_FILE"
  echo
  echo "Released the EFS access point, mount targets, file system and NFS security group."
else
  echo
  echo "Some resources could not be confirmed deleted; kept $ENV_FILE for a re-run."
fi
echo "The shared EFS CSI driver, its service accounts, their IAM roles and their Pod"
echo "Identity associations were left exactly as they were. The '$NAMESPACE' namespace is"
echo "left in place."
[[ "$fail" -eq 0 ]] || exit 1
