#!/usr/bin/env bash
# Tear down the shared S3 Files sample.
#
#   NAMESPACE=<ns> ./scripts/clean.sh                        # Kubernetes objects only
#   NAMESPACE=<ns> ./scripts/clean.sh --delete-aws-resources  # ...and the S3 Files resources + bucket
#
# Default: delete the two pods, the PVC and workload ServiceAccount, the static PV, the
# egress ApplicationNetworkPolicy, and the sample's own StorageClass. The S3 Files file
# system, access point, mount targets, security group, synchronization role and bucket are
# kept, so a later ./scripts/test.sh reuses the same storage and data.
#
# --delete-aws-resources additionally uses .env as its deletion record and releases the
# access point, every mount target, the file system, the synchronization role, the NFS
# security group, and - only when the sample created it, re-proven by the live bucket tag -
# every object version in the bucket AND the bucket itself, then deletes .env.
#
# Neither mode touches the shared EFS CSI driver, its service accounts, their IAM roles or
# their Pod Identity associations: this sample never created or changed them. It checks the
# namespace label before deleting anything inside it, verifies ownership before deleting an
# AWS resource, and a lookup that cannot be confirmed is a FAILURE, never "gone": the script
# exits non-zero if it skipped or could not confirm a delete. The namespace itself is left
# in place.
#
# Overridable: NAMESPACE, ENV_FILE, KUBECTL, AWS.
set -uo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$SAMPLE_DIR/.env}"
NAMESPACE="${NAMESPACE:-nitro-s3-files-sample}"
KUBECTL="${KUBECTL:-kubectl}"
AWS="${AWS:-aws}"

SAMPLE="storage-s3-files"
SAMPLE_LABEL_KEY="app.kubernetes.io/part-of"
SAMPLE_LABEL_VALUE="storage-s3-files"
BUCKET_OWNER_TAG_KEY=ManagedBy
DELETE_AWS=false
[[ "${1:-}" == "--delete-aws-resources" ]] && DELETE_AWS=true

fail=0
warn() { printf 'WARN: %s\n' "$*" >&2; fail=1; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v "${KUBECTL%% *}" >/dev/null 2>&1 || die "'$KUBECTL' is not on PATH"

# kexists <kind> [<name>] [-n <ns>]: 0 present, 1 confirmed absent (NotFound), 2 read failed.
kexists() {
  local errf out rc
  errf="$(mktemp)"
  out="$($KUBECTL get "$@" -o name 2>"$errf")"; rc=$?
  if [[ $rc -eq 0 ]]; then rm -f "$errf"; [[ -n "$out" ]] && return 0 || return 1; fi
  if grep -qi 'notfound\|not found' "$errf"; then rm -f "$errf"; return 1; fi
  rm -f "$errf"; return 2
}

# kdelete <description> <kind> <name> [-n <ns>]: delete and confirm it is gone.
kdelete() {
  local desc="$1"; shift
  if ! $KUBECTL delete "$@" --ignore-not-found --wait=true >/dev/null 2>&1; then
    warn "could not delete $desc"; return
  fi
  kexists "$@" >/dev/null 2>&1
  case $? in
    1) : ;;
    0) warn "$desc still present after delete" ;;
    2) warn "could not confirm $desc was deleted" ;;
  esac
}

# Only touch the namespace if it is this sample's. A lookup failure is fatal, not "absent".
kexists namespace "$NAMESPACE"; ns_rc=$?
case $ns_rc in
  2) die "could not read namespace '$NAMESPACE' (the lookup failed, not a report that it is absent). Re-run once the cluster reads cleanly." ;;
  1) echo "Namespace '$NAMESPACE' is absent; nothing in-cluster to delete." ;;
  0)
    label="$($KUBECTL get namespace "$NAMESPACE" -o "jsonpath={.metadata.labels.app\.kubernetes\.io/part-of}" 2>/dev/null)" \
      || die "could not read the labels of namespace '$NAMESPACE'; refusing to delete anything inside it until the read succeeds."
    [[ "$label" == "$SAMPLE_LABEL_VALUE" ]] \
      || die "namespace '$NAMESPACE' is not labelled $SAMPLE_LABEL_KEY=$SAMPLE_LABEL_VALUE (found '${label:-<none>}'); refusing to delete objects inside a namespace this sample did not create."
    echo "Namespace '$NAMESPACE' is this sample's (labelled $SAMPLE_LABEL_KEY=$SAMPLE_LABEL_VALUE)."
    echo "Deleting pods, PVC, ServiceAccount, PV, and the egress policy..."
    kdelete "pod s3-files-writer" pod s3-files-writer -n "$NAMESPACE"
    kdelete "pod s3-files-reader" pod s3-files-reader -n "$NAMESPACE"
    kdelete "egress policy" applicationnetworkpolicy s3-files-shared-egress -n "$NAMESPACE"
    kdelete "PVC storage-s3-files-shared" pvc storage-s3-files-shared -n "$NAMESPACE"
    kdelete "ServiceAccount s3-files-workload" serviceaccount s3-files-workload -n "$NAMESPACE"
    kdelete "PV storage-s3-files-shared" pv storage-s3-files-shared
    ;;
esac

# The sample's own StorageClass (cluster-scoped, carries the mark).
kexists storageclass nitro-sandbox-s3-files; sc_rc=$?
case $sc_rc in
  2) warn "could not read StorageClass nitro-sandbox-s3-files; leaving it." ;;
  1) : ;;
  0)
    sc_label="$($KUBECTL get storageclass nitro-sandbox-s3-files -o "jsonpath={.metadata.labels.app\.kubernetes\.io/part-of}" 2>/dev/null)" \
      || { warn "could not read the label of StorageClass nitro-sandbox-s3-files; leaving it."; sc_label=""; }
    if [[ "$sc_label" == "$SAMPLE_LABEL_VALUE" ]]; then
      kdelete "StorageClass nitro-sandbox-s3-files" storageclass nitro-sandbox-s3-files
    elif [[ -n "$sc_label" ]]; then
      warn "StorageClass nitro-sandbox-s3-files is not marked this sample's (found '$sc_label'); leaving it."
    fi
    ;;
esac

if [[ "$DELETE_AWS" != true ]]; then
  echo
  echo "Kubernetes objects removed. The S3 Files file system, access point, mount targets,"
  echo "security group, synchronization role and bucket are kept; re-run ./scripts/test.sh to"
  echo "reuse them, or run ./scripts/clean.sh --delete-aws-resources to release them."
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

bucket_owner_marker() {
  local value
  value="$(aws_r s3api get-bucket-tagging --bucket "$1" \
    --query "TagSet[?Key=='$BUCKET_OWNER_TAG_KEY'].Value | [0]" --output text 2>/dev/null || true)"
  [[ "$value" == "None" ]] && value=""
  printf '%s' "$value"
}

# Wait for the PV to be gone so no NFS client holds the mount targets. A timeout here means an
# NFS client may still hold a mount target, so do NOT start AWS teardown.
if ! $KUBECTL wait --for=delete pv/storage-s3-files-shared --timeout=3m >/dev/null 2>&1; then
  kexists pv storage-s3-files-shared; pv_rc=$?
  case $pv_rc in
    0) die "PV storage-s3-files-shared is still present after waiting; an NFS client may still hold a mount target. Run './scripts/clean.sh' (no flag) first to remove the pods and PV, then re-run with --delete-aws-resources." ;;
    2) die "could not confirm PV storage-s3-files-shared was deleted (the lookup failed); refusing to start AWS teardown while a mount target may still be held. Re-run once the cluster reads cleanly." ;;
  esac
fi

# The S3 Files access point.
if [[ -n "${S3_FILES_ACCESS_POINT_ID:-}" ]]; then
  echo "Deleting S3 Files access point $S3_FILES_ACCESS_POINT_ID..."
  aws_r s3files delete-access-point --access-point-id "$S3_FILES_ACCESS_POINT_ID" >/dev/null 2>&1 || true
  ap_state="unknown"
  for _ in $(seq 1 60); do
    ap_state="$(aws_r s3files get-access-point --access-point-id "$S3_FILES_ACCESS_POINT_ID" \
      --query status --output text 2>/dev/null || echo DELETED)"
    ap_state="${ap_state^^}"
    [[ "$ap_state" == "DELETED" ]] && break
    sleep 5
  done
  [[ "$ap_state" == "DELETED" ]] || warn "S3 Files access point still present or unconfirmed; re-run --delete-aws-resources."
fi

# The mount targets and the file system.
if [[ -n "${S3_FILES_FILE_SYSTEM_ID:-}" ]]; then
  echo "Deleting S3 Files mount targets..."
  mts="$(aws_r s3files list-mount-targets --file-system-id "$S3_FILES_FILE_SYSTEM_ID" \
    --query 'mountTargets[].mountTargetId' --output text 2>/dev/null || true)"
  for mt in $mts; do
    [[ "$mt" == None ]] && continue
    aws_r s3files delete-mount-target --mount-target-id "$mt" >/dev/null 2>&1 || true
  done
  remaining="unknown"
  for _ in $(seq 1 90); do
    statuses="$(aws_r s3files list-mount-targets --file-system-id "$S3_FILES_FILE_SYSTEM_ID" \
      --query 'mountTargets[].status' --output text 2>/dev/null || true)"
    remaining=0
    for st in $statuses; do [[ "${st^^}" == "DELETED" || "$st" == "None" ]] || remaining=$((remaining+1)); done
    [[ "$remaining" == 0 ]] && break
    sleep 5
  done
  [[ "$remaining" == 0 ]] || warn "S3 Files mount targets still present or unconfirmed; re-run --delete-aws-resources."

  if [[ "$remaining" == 0 ]]; then
    echo "Deleting S3 Files file system $S3_FILES_FILE_SYSTEM_ID..."
    fs_state="unknown"
    for _ in $(seq 1 90); do
      fs_state="$(aws_r s3files get-file-system --file-system-id "$S3_FILES_FILE_SYSTEM_ID" \
        --query status --output text 2>/dev/null || echo DELETED)"
      fs_state="${fs_state^^}"
      [[ "$fs_state" == "DELETED" ]] && break
      [[ "$fs_state" != "DELETING" ]] && aws_r s3files delete-file-system --file-system-id "$S3_FILES_FILE_SYSTEM_ID" >/dev/null 2>&1 || true
      sleep 5
    done
    [[ "$fs_state" == "DELETED" ]] || warn "S3 Files file system still present or unconfirmed; re-run --delete-aws-resources before deleting the bucket."
  fi
fi

# The synchronization role (only one this sample created).
if [[ "${CREATED_SYNC_ROLE:-false}" == "true" && -n "${S3_FILES_SYNC_ROLE_NAME:-}" ]]; then
  echo "Deleting synchronization role $S3_FILES_SYNC_ROLE_NAME..."
  aws_r iam delete-role-policy --role-name "$S3_FILES_SYNC_ROLE_NAME" --policy-name S3FilesSync >/dev/null 2>&1 || true
  aws_r iam delete-role --role-name "$S3_FILES_SYNC_ROLE_NAME" >/dev/null 2>&1 || true
  if aws_r iam get-role --role-name "$S3_FILES_SYNC_ROLE_NAME" >/dev/null 2>&1; then
    warn "synchronization role $S3_FILES_SYNC_ROLE_NAME still present; re-run --delete-aws-resources."
  fi
fi

# The NFS security group, by ownership tag.
sg_id="${S3_FILES_SECURITY_GROUP_ID:-}"
if [[ -n "$sg_id" && "$sg_id" != "None" ]]; then
  sg_owner="$(aws_r ec2 describe-security-groups --group-ids "$sg_id" \
    --query "SecurityGroups[0].Tags[?Key=='ManagedBy'].Value | [0]" --output text 2>&1)"
  if [[ $? -eq 0 ]]; then
    if [[ "$sg_owner" == "$SAMPLE" ]]; then
      echo "Deleting NFS security group $sg_id..."
      gone=false
      for _ in $(seq 1 30); do
        if aws_r ec2 delete-security-group --group-id "$sg_id" >/dev/null 2>&1; then gone=true; break; fi
        sleep 5
      done
      if ! $gone; then
        confirm="$(aws_r ec2 describe-security-groups --group-ids "$sg_id" 2>&1)"
        if [[ $? -eq 0 ]]; then
          warn "could not delete the NFS security group $sg_id (mount-target interfaces may still be releasing); re-run --delete-aws-resources."
        elif ! grep -qi 'InvalidGroup.NotFound' <<<"$confirm"; then
          warn "could not confirm the NFS security group $sg_id was deleted; re-run --delete-aws-resources."
        fi
      fi
    else
      warn "security group $sg_id is not tagged ManagedBy=$SAMPLE; leaving it."
    fi
  elif grep -qi 'InvalidGroup.NotFound' <<<"$sg_owner"; then
    :
  else
    warn "could not read ownership tags of security group $sg_id; leaving it."
  fi
fi

# The bucket: delete every object version and the bucket itself, but only when the sample
# created it AND the live bucket tag still proves it. Re-prove against the live tag here,
# because .env can go stale; the tag lives on the bucket, so when the two disagree the
# bucket wins and nothing is deleted.
if [[ "${CREATED_BUCKET:-false}" == "true" && -n "${S3_BUCKET_NAME:-}" ]]; then
  if ! aws_r s3api head-bucket --bucket "$S3_BUCKET_NAME" >/dev/null 2>&1; then
    echo "Bucket $S3_BUCKET_NAME is already gone; nothing to delete there."
  else
    marker="$(bucket_owner_marker "$S3_BUCKET_NAME")"
    if [[ "$marker" != "$SAMPLE" ]]; then
      warn "refusing to delete s3://$S3_BUCKET_NAME: it is not tagged $BUCKET_OWNER_TAG_KEY=$SAMPLE on the live bucket (found '${marker:-no marker}'). Nothing in the bucket was touched."
    else
      echo "Deleting all object versions from s3://$S3_BUCKET_NAME..."
      del_ok=true
      while IFS=$'\t' read -r key version_id; do
        [[ -z "$key" || "$key" == "None" ]] && continue
        aws_r s3api delete-object --bucket "$S3_BUCKET_NAME" --key "$key" --version-id "$version_id" >/dev/null 2>&1 || del_ok=false
      done < <(aws_r s3api list-object-versions --bucket "$S3_BUCKET_NAME" --query 'Versions[].[Key,VersionId]' --output text 2>/dev/null)
      while IFS=$'\t' read -r key version_id; do
        [[ -z "$key" || "$key" == "None" ]] && continue
        aws_r s3api delete-object --bucket "$S3_BUCKET_NAME" --key "$key" --version-id "$version_id" >/dev/null 2>&1 || del_ok=false
      done < <(aws_r s3api list-object-versions --bucket "$S3_BUCKET_NAME" --query 'DeleteMarkers[].[Key,VersionId]' --output text 2>/dev/null)
      $del_ok || warn "could not delete every object version in s3://$S3_BUCKET_NAME; leaving the bucket. Re-run --delete-aws-resources."
      if $del_ok; then
        echo "Deleting bucket s3://$S3_BUCKET_NAME..."
        aws_r s3api delete-bucket --bucket "$S3_BUCKET_NAME" >/dev/null 2>&1 || true
        if aws_r s3api head-bucket --bucket "$S3_BUCKET_NAME" >/dev/null 2>&1; then
          warn "bucket $S3_BUCKET_NAME still present after delete; re-run --delete-aws-resources."
        fi
      fi
    fi
  fi
fi

if [[ "$fail" -eq 0 ]]; then
  rm -f "$ENV_FILE"
  echo
  echo "Released the S3 Files access point, mount targets, file system, synchronization role,"
  echo "NFS security group and bucket."
else
  echo
  echo "Some resources could not be confirmed deleted; kept $ENV_FILE for a re-run."
fi
echo "The shared EFS CSI driver, its service accounts, their IAM roles and their Pod"
echo "Identity associations were left exactly as they were. The '$NAMESPACE' namespace is"
echo "left in place."
[[ "$fail" -eq 0 ]] || exit 1
