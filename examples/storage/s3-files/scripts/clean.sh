#!/usr/bin/env bash
# Tear down the shared S3 Files sample.
#
#   NAMESPACE=<ns> ./scripts/clean.sh                        # Kubernetes objects only
#   NAMESPACE=<ns> ./scripts/clean.sh --delete-aws-resources  # ...and the S3 Files resources + bucket
#
# Default: delete the two pods, the PVC and workload ServiceAccount, the static PV, the
# egress ApplicationNetworkPolicy, and the sample's own StorageClass. The S3 Files file
# system, access points, mount targets, security group, synchronization role and bucket are
# kept, so a later ./scripts/test.sh reuses the same storage and data.
#
# --delete-aws-resources additionally uses .env as its deletion record and releases the
# writer and reader access points, every mount target, the file system, the synchronization
# role, the NFS security group, and - only when the sample created it, re-proven by the live
# bucket tag - every object version in the bucket AND the bucket itself, then deletes .env.
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
    kdelete "PVC storage-s3-files-writer" pvc storage-s3-files-writer -n "$NAMESPACE"
    kdelete "PVC storage-s3-files-reader" pvc storage-s3-files-reader -n "$NAMESPACE"
    kdelete "ServiceAccount s3-files-workload" serviceaccount s3-files-workload -n "$NAMESPACE"
    kdelete "PV storage-s3-files-writer" pv storage-s3-files-writer
    kdelete "PV storage-s3-files-reader" pv storage-s3-files-reader
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
  echo "Kubernetes objects removed. The S3 Files file system, access points, mount targets,"
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

# s3files_gone <get-command...>: 0 the resource is CONFIRMED gone (the error names the
# service's not-found token), 1 it is present, 2 the read failed for another reason. Lets a
# teardown tell "deleted" from "could not tell", so a throttle or credential error is never
# read as success. The S3 Files errors are ResourceNotFoundException and (for an access point)
# AccessPointNotFound/NotFound.
s3files_gone() {
  local out rc
  out="$(aws_r "$@" 2>&1)"; rc=$?
  [[ $rc -eq 0 ]] && return 1
  # Match only the service's explicit not-found error CODE, and only in a COMPLETE AWS CLI error
  # line ("An error occurred (<Code>) when calling the <Op> operation:"). The line is anchored to
  # the start, allowing the "aws: [ERROR]: " prefix this CLI build prints, so none of these is
  # read as confirmed gone: a code that merely contains a not-found token as a substring
  # ("FileSystemNotFoundational"), arbitrary prose that embeds "(FileSystemNotFound)" mid-line, or
  # a truncated line. grep is line-oriented, so ^ anchors each line of the captured output.
  grep -qE '^(aws: \[ERROR\]: )?An error occurred \((ResourceNotFoundException|AccessPointNotFoundException|AccessPointNotFound|FileSystemNotFound)\) when calling the [^[:space:]]+ operation:' <<<"$out" && return 0
  return 2
}

# head_bucket_status <bucket>: 0 present, 1 confirmed absent (404/NoSuchBucket), 2 the read
# failed for another reason (403, throttle, networking). A failed head-bucket is NEVER read as
# "gone" unless it is specifically a not-found.
head_bucket_status() {
  local out rc
  out="$(aws_r s3api head-bucket --bucket "$1" 2>&1)"; rc=$?
  [[ $rc -eq 0 ]] && return 0
  grep -qiE '\(404\)|Not Found|NoSuchBucket' <<<"$out" && return 1
  return 2
}

# Wait for BOTH PVs to be gone so no NFS client holds the mount targets. A timeout here means an
# NFS client may still hold a mount target, so do NOT start AWS teardown.
for pv in storage-s3-files-writer storage-s3-files-reader; do
  if ! $KUBECTL wait --for=delete "pv/$pv" --timeout=3m >/dev/null 2>&1; then
    kexists pv "$pv"; pv_rc=$?
    case $pv_rc in
      0) die "PV $pv is still present after waiting; an NFS client may still hold a mount target. Run './scripts/clean.sh' (no flag) first to remove the pods and PVs, then re-run with --delete-aws-resources." ;;
      2) die "could not confirm PV $pv was deleted (the lookup failed); refusing to start AWS teardown while a mount target may still be held. Re-run once the cluster reads cleanly." ;;
    esac
  fi
done

# Prove the recorded file system is this sample's before deleting it or its access point: its
# `bucket` must be the recorded bucket, and that bucket must carry ManagedBy=storage-s3-files.
# A stale .env pointing at another sample's file system is refused here. The bucket tag gate is
# the same evidence the bucket delete uses, so the whole S3 Files chain is proven as one.
# A read that fails leaves ownership unproven, so the FS/AP deletes are skipped (never forced).
fs_owned=false
if [[ -n "${S3_FILES_FILE_SYSTEM_ID:-}" ]]; then
  fs_bucket="$(aws_r s3files get-file-system --file-system-id "$S3_FILES_FILE_SYSTEM_ID" \
    --query 'bucket' --output text 2>/dev/null)"; fs_read_rc=$?
  if [[ $fs_read_rc -ne 0 ]]; then
    # Could the file system already be gone? s3files_gone tells "deleted" from "unreadable".
    s3files_gone s3files get-file-system --file-system-id "$S3_FILES_FILE_SYSTEM_ID" --query status
    case $? in
      0) echo "S3 Files file system $S3_FILES_FILE_SYSTEM_ID is already gone." ;;
      *) warn "could not read S3 Files file system $S3_FILES_FILE_SYSTEM_ID to prove ownership; leaving it and its access point. Re-run --delete-aws-resources." ;;
    esac
  elif [[ -n "${S3_BUCKET_NAME:-}" && "$fs_bucket" == "arn:aws:s3:::$S3_BUCKET_NAME" ]]; then
    marker="$(bucket_owner_marker "$S3_BUCKET_NAME")"
    if [[ "$marker" == "$SAMPLE" ]]; then
      fs_owned=true
    else
      warn "refusing to delete S3 Files file system $S3_FILES_FILE_SYSTEM_ID: its bucket $S3_BUCKET_NAME is not tagged $BUCKET_OWNER_TAG_KEY=$SAMPLE on the live bucket (found '${marker:-no marker}'). Leaving the file system and access point."
    fi
  else
    warn "refusing to delete S3 Files file system $S3_FILES_FILE_SYSTEM_ID: it is attached to '$fs_bucket', not this sample's recorded bucket arn:aws:s3:::${S3_BUCKET_NAME:-<unset>}. Leaving the file system and access point."
  fi
fi

# The two S3 Files access points (writer and reader), deleted only when the file system they
# are on is proven this sample's (fs_owned) AND each recorded access point is confirmed to be
# on that proven file system. A stale foreign access point ID alongside an owned file system
# must not be deleted: read each access point's live fileSystemId and require it to equal the
# proven one; any read failure leaves it unconfirmed and untouched.
# delete_access_point <description> <access-point-id>
delete_access_point() {
  local desc="$1" apid="$2"
  [[ "$fs_owned" == true && -n "$apid" && "$apid" != "None" ]] || return 0
  local ap_fs ap_read_rc
  ap_fs="$(aws_r s3files get-access-point --access-point-id "$apid" --query 'fileSystemId' --output text 2>/dev/null)"; ap_read_rc=$?
  if [[ $ap_read_rc -ne 0 ]]; then
    s3files_gone s3files get-access-point --access-point-id "$apid" --query status
    case $? in
      0) echo "$desc access point $apid is already gone." ;;
      *) warn "could not read $desc access point $apid to prove it is on this sample's file system; leaving it. Re-run --delete-aws-resources." ;;
    esac
    return 0
  fi
  if [[ "$ap_fs" != "$S3_FILES_FILE_SYSTEM_ID" ]]; then
    warn "refusing to delete $desc access point $apid: it is on file system $ap_fs, not this sample's proven $S3_FILES_FILE_SYSTEM_ID. Leaving it."
    return 0
  fi
  echo "Deleting $desc access point $apid..."
  aws_r s3files delete-access-point --access-point-id "$apid" >/dev/null 2>&1 || true
  local ap_rc=1  # 0 gone, 1 present, 2 unconfirmed
  for _ in $(seq 1 60); do
    s3files_gone s3files get-access-point --access-point-id "$apid" --query status; ap_rc=$?
    [[ "$ap_rc" != 1 ]] && break
    sleep 5
  done
  [[ "$ap_rc" == 0 ]] || warn "$desc access point still present or could not be confirmed deleted; re-run --delete-aws-resources."
}
delete_access_point "writer" "${S3_FILES_WRITER_AP_ID:-}"
delete_access_point "reader" "${S3_FILES_READER_AP_ID:-}"

# The mount targets and the file system (only when the file system is proven this sample's).
mt_confirmed_empty=false
if [[ "$fs_owned" == true && -n "${S3_FILES_FILE_SYSTEM_ID:-}" ]]; then
  echo "Deleting S3 Files mount targets..."
  # A listing failure is NEVER read as "no mount targets"; it leaves the count unknown so the
  # file system is not deleted while a mount target may still hold a network interface.
  mts_errf="$(mktemp)"
  mts="$(aws_r s3files list-mount-targets --file-system-id "$S3_FILES_FILE_SYSTEM_ID" \
    --query 'mountTargets[].mountTargetId' --output text 2>"$mts_errf")"
  if [[ $? -ne 0 ]]; then
    warn "could not list S3 Files mount targets of $S3_FILES_FILE_SYSTEM_ID; leaving the file system. Re-run --delete-aws-resources."
    rm -f "$mts_errf"
  else
    rm -f "$mts_errf"
    for mt in $mts; do
      [[ "$mt" == None ]] && continue
      aws_r s3files delete-mount-target --mount-target-id "$mt" >/dev/null 2>&1 || true
    done
    remaining="unknown"
    for _ in $(seq 1 90); do
      statuses="$(aws_r s3files list-mount-targets --file-system-id "$S3_FILES_FILE_SYSTEM_ID" \
        --query 'mountTargets[].status' --output text 2>/dev/null)"
      [[ $? -ne 0 ]] && { remaining="unknown"; sleep 5; continue; }
      remaining=0
      for st in $statuses; do [[ "${st^^}" == "DELETED" || "$st" == "None" ]] || remaining=$((remaining+1)); done
      [[ "$remaining" == 0 ]] && break
      sleep 5
    done
    if [[ "$remaining" == 0 ]]; then
      mt_confirmed_empty=true
    else
      warn "S3 Files mount targets still present or could not be confirmed deleted; re-run --delete-aws-resources."
    fi
  fi

  # Delete the file system only once the mount targets are CONFIRMED gone.
  if $mt_confirmed_empty; then
    echo "Deleting S3 Files file system $S3_FILES_FILE_SYSTEM_ID..."
    fs_rc=1  # 0 gone, 1 present, 2 unconfirmed
    for _ in $(seq 1 90); do
      s3files_gone s3files get-file-system --file-system-id "$S3_FILES_FILE_SYSTEM_ID" --query status; fs_rc=$?
      [[ "$fs_rc" == 0 ]] && break
      if [[ "$fs_rc" == 1 ]]; then
        # present: read its state and (re)issue the delete unless it is already deleting.
        fs_state="$(aws_r s3files get-file-system --file-system-id "$S3_FILES_FILE_SYSTEM_ID" --query status --output text 2>/dev/null || true)"
        [[ "${fs_state^^}" != "DELETING" ]] && aws_r s3files delete-file-system --file-system-id "$S3_FILES_FILE_SYSTEM_ID" >/dev/null 2>&1 || true
      fi
      sleep 5
    done
    [[ "$fs_rc" == 0 ]] || warn "S3 Files file system still present or could not be confirmed deleted; re-run --delete-aws-resources before deleting the bucket."
  fi
fi

# The synchronization role (only one this sample created). Re-prove ownership against the live
# role tag before deleting, not from CREATED_SYNC_ROLE alone: .env can go stale, and the role
# name is deterministic, so a differently-owned role could carry the same name. setup.sh tags
# every role it creates ManagedBy=storage-s3-files.
if [[ "${CREATED_SYNC_ROLE:-false}" == "true" && -n "${S3_FILES_SYNC_ROLE_NAME:-}" ]]; then
  role_errf="$(mktemp)"
  role_owner="$(aws_r iam list-role-tags --role-name "$S3_FILES_SYNC_ROLE_NAME" \
    --query "Tags[?Key=='ManagedBy'].Value | [0]" --output text 2>"$role_errf")"
  role_rc=$?
  if [[ $role_rc -ne 0 ]] && grep -qi 'NoSuchEntity' "$role_errf"; then
    rm -f "$role_errf"  # already gone
  elif [[ $role_rc -ne 0 ]]; then
    rm -f "$role_errf"
    warn "could not read ownership tags of synchronization role $S3_FILES_SYNC_ROLE_NAME; leaving it. Re-run --delete-aws-resources."
  else
    rm -f "$role_errf"
    if [[ "$role_owner" != "$SAMPLE" ]]; then
      warn "synchronization role $S3_FILES_SYNC_ROLE_NAME is not tagged ManagedBy=$SAMPLE (found '${role_owner:-<none>}'); leaving it."
    else
      echo "Deleting synchronization role $S3_FILES_SYNC_ROLE_NAME..."
      aws_r iam delete-role-policy --role-name "$S3_FILES_SYNC_ROLE_NAME" --policy-name S3FilesSync >/dev/null 2>&1 || true
      aws_r iam delete-role --role-name "$S3_FILES_SYNC_ROLE_NAME" >/dev/null 2>&1 || true
      del_errf="$(mktemp)"
      if aws_r iam get-role --role-name "$S3_FILES_SYNC_ROLE_NAME" >"$del_errf" 2>&1; then
        warn "synchronization role $S3_FILES_SYNC_ROLE_NAME still present; re-run --delete-aws-resources."
      elif ! grep -qi 'NoSuchEntity' "$del_errf"; then
        warn "could not confirm synchronization role $S3_FILES_SYNC_ROLE_NAME was deleted; re-run --delete-aws-resources."
      fi
      rm -f "$del_errf"
    fi
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
  head_bucket_status "$S3_BUCKET_NAME"; hb_rc=$?
  case $hb_rc in
    1) echo "Bucket $S3_BUCKET_NAME is confirmed gone (404); nothing to delete there." ;;
    2) warn "could not read bucket $S3_BUCKET_NAME (the head-bucket lookup failed, not a 404); refusing to treat it as gone. Nothing was touched. Re-run --delete-aws-resources once S3 reads cleanly." ;;
    0)
      marker="$(bucket_owner_marker "$S3_BUCKET_NAME")"
      if [[ "$marker" != "$SAMPLE" ]]; then
        warn "refusing to delete s3://$S3_BUCKET_NAME: it is not tagged $BUCKET_OWNER_TAG_KEY=$SAMPLE on the live bucket (found '${marker:-no marker}'). Nothing in the bucket was touched."
      else
        echo "Deleting all object versions from s3://$S3_BUCKET_NAME..."
        del_ok=true
        # List each page to a file with an explicitly checked command, so a listing FAILURE is
        # visible (a process substitution's exit status is not), and never read as "no objects".
        for sel in Versions DeleteMarkers; do
          verf="$(mktemp)"
          if ! aws_r s3api list-object-versions --bucket "$S3_BUCKET_NAME" \
               --query "${sel}[].[Key,VersionId]" --output text >"$verf" 2>/dev/null; then
            warn "could not list $sel of s3://$S3_BUCKET_NAME; leaving the bucket. Re-run --delete-aws-resources."
            del_ok=false; rm -f "$verf"; continue
          fi
          while IFS=$'\t' read -r key version_id; do
            [[ -z "$key" || "$key" == "None" ]] && continue
            aws_r s3api delete-object --bucket "$S3_BUCKET_NAME" --key "$key" --version-id "$version_id" >/dev/null 2>&1 || del_ok=false
          done < "$verf"
          rm -f "$verf"
        done
        $del_ok || warn "could not delete every object version in s3://$S3_BUCKET_NAME; leaving the bucket. Re-run --delete-aws-resources."
        if $del_ok; then
          echo "Deleting bucket s3://$S3_BUCKET_NAME..."
          aws_r s3api delete-bucket --bucket "$S3_BUCKET_NAME" >/dev/null 2>&1 || true
          head_bucket_status "$S3_BUCKET_NAME"; hb2=$?
          case $hb2 in
            1) : ;;  # confirmed 404: gone
            0) warn "bucket $S3_BUCKET_NAME still present after delete; re-run --delete-aws-resources." ;;
            2) warn "could not confirm bucket $S3_BUCKET_NAME was deleted (the head-bucket lookup failed); re-run --delete-aws-resources." ;;
          esac
        fi
      fi
      ;;
  esac
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
