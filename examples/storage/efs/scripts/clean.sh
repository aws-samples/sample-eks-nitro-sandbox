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
# namespace label before deleting anything inside it, verifies ownership tags before deleting
# an AWS resource, and a lookup that cannot be confirmed is a FAILURE, never "gone": the
# script exits non-zero if it skipped or could not confirm a delete. The namespace itself is
# left in place.
#
# Overridable: NAMESPACE, ENV_FILE, KUBECTL, AWS.
set -uo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$SAMPLE_DIR/.env}"
NAMESPACE="${NAMESPACE:-nitro-efs-sample}"
KUBECTL="${KUBECTL:-kubectl}"
AWS="${AWS:-aws}"

SAMPLE="storage-efs"
SAMPLE_LABEL_KEY="app.kubernetes.io/part-of"
SAMPLE_LABEL_VALUE="storage-efs"
DELETE_AWS=false
[[ "${1:-}" == "--delete-aws-resources" ]] && DELETE_AWS=true

fail=0
warn() { printf 'WARN: %s\n' "$*" >&2; fail=1; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v "${KUBECTL%% *}" >/dev/null 2>&1 || die "'$KUBECTL' is not on PATH"

# kexists <kind> [<name>] [-n <ns>]: 0 present, 1 confirmed absent (NotFound), 2 read failed.
# Distinguishes "the object is not there" from "the read itself failed", so a cleanup never
# treats a throttle or RBAC error as "gone".
kexists() {
  local errf out rc
  errf="$(mktemp)"
  out="$($KUBECTL get "$@" -o name 2>"$errf")"; rc=$?
  if [[ $rc -eq 0 ]]; then rm -f "$errf"; [[ -n "$out" ]] && return 0 || return 1; fi
  if grep -qi 'notfound\|not found' "$errf"; then rm -f "$errf"; return 1; fi
  rm -f "$errf"; return 2
}

# kdelete <description> <kind> <name> [-n <ns>]: delete and confirm it is gone. A delete that
# errors, or an object still present afterwards, or a read that could not confirm, is a failure.
kdelete() {
  local desc="$1"; shift
  if ! $KUBECTL delete "$@" --ignore-not-found --wait=true >/dev/null 2>&1; then
    warn "could not delete $desc"
    return
  fi
  kexists "$@" >/dev/null 2>&1
  case $? in
    1) : ;;                                   # confirmed gone
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
    kdelete "pod efs-writer" pod efs-writer -n "$NAMESPACE"
    kdelete "pod efs-reader" pod efs-reader -n "$NAMESPACE"
    kdelete "egress policy" applicationnetworkpolicy efs-shared-egress -n "$NAMESPACE"
    kdelete "PVC storage-efs-shared" pvc storage-efs-shared -n "$NAMESPACE"
    kdelete "ServiceAccount efs-workload" serviceaccount efs-workload -n "$NAMESPACE"
    kdelete "PV storage-efs-shared" pv storage-efs-shared
    ;;
esac

# The sample's own StorageClass (cluster-scoped, carries the mark).
kexists storageclass nitro-sandbox-efs; sc_rc=$?
case $sc_rc in
  2) warn "could not read StorageClass nitro-sandbox-efs; leaving it." ;;
  1) : ;;
  0)
    sc_label="$($KUBECTL get storageclass nitro-sandbox-efs -o "jsonpath={.metadata.labels.app\.kubernetes\.io/part-of}" 2>/dev/null)" \
      || { warn "could not read the label of StorageClass nitro-sandbox-efs; leaving it."; sc_label=""; }
    if [[ "$sc_label" == "$SAMPLE_LABEL_VALUE" ]]; then
      kdelete "StorageClass nitro-sandbox-efs" storageclass nitro-sandbox-efs
    elif [[ -n "$sc_label" ]]; then
      warn "StorageClass nitro-sandbox-efs is not marked this sample's (found '$sc_label'); leaving it."
    fi
    ;;
esac

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

# efs_tag <resource-id>: print the value of the ManagedBy tag, or empty. Returns non-zero only
# when the tag read itself fails (so an unconfirmed ownership read is never read as "owned").
efs_owner_ok() { # efs_owner_ok <resource-id>
  local v
  v="$(aws_r efs list-tags-for-resource --resource-id "$1" \
    --query "Tags[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null)" || return 2
  [[ "$v" == "$SAMPLE" ]]
}

# Wait for the PV to be gone so no NFS client holds the mount targets. A timeout here means an
# NFS client may still hold a mount target, so do NOT start AWS teardown: treat it as a failure.
if ! $KUBECTL wait --for=delete pv/storage-efs-shared --timeout=3m >/dev/null 2>&1; then
  if kexists pv storage-efs-shared >/dev/null 2>&1; then
    die "PV storage-efs-shared is still present after waiting; an NFS client may still hold a mount target. Run './scripts/clean.sh' (no flag) first to remove the pods and PV, then re-run with --delete-aws-resources."
  fi
fi

if [[ -n "${EFS_ACCESS_POINT_ID:-}" ]]; then
  # Verify ownership before deleting, unless the access point is already gone.
  ap_state="$(aws_r efs describe-access-points --access-point-id "$EFS_ACCESS_POINT_ID" \
    --query 'AccessPoints[0].LifeCycleState' --output text 2>/dev/null || echo READ_FAILED)"
  if [[ "$ap_state" == "READ_FAILED" ]]; then
    # Distinguish "not found" from a read error by re-reading and checking the error.
    if aws_r efs describe-access-points --access-point-id "$EFS_ACCESS_POINT_ID" >/dev/null 2>&1; then
      warn "could not read EFS access point $EFS_ACCESS_POINT_ID state; leaving it."
    fi  # a genuine AccessPointNotFound here means it is already gone
  else
    if efs_owner_ok "$EFS_ACCESS_POINT_ID"; then
      echo "Deleting EFS access point $EFS_ACCESS_POINT_ID..."
      aws_r efs delete-access-point --access-point-id "$EFS_ACCESS_POINT_ID" >/dev/null 2>&1 || true
      s=""
      for _ in $(seq 1 60); do
        s="$(aws_r efs describe-access-points --access-point-id "$EFS_ACCESS_POINT_ID" \
          --query 'AccessPoints[0].LifeCycleState' --output text 2>&1)"
        if grep -qi 'AccessPointNotFound' <<<"$s"; then s=deleted; break; fi
        [[ "$s" == deleted || "$s" == None ]] && break
        sleep 5
      done
      [[ "$s" == deleted || "$s" == None ]] || warn "EFS access point still present or unconfirmed; re-run --delete-aws-resources."
    else
      [[ $? -eq 2 ]] && warn "could not read ownership tags of access point $EFS_ACCESS_POINT_ID; leaving it." \
                     || warn "access point $EFS_ACCESS_POINT_ID is not tagged ManagedBy=$SAMPLE; leaving it."
    fi
  fi
fi

if [[ -n "${EFS_FILE_SYSTEM_ID:-}" ]]; then
  # Verify the file system is this sample's before deleting its mount targets and itself.
  fs_state="$(aws_r efs describe-file-systems --file-system-id "$EFS_FILE_SYSTEM_ID" \
    --query 'FileSystems[0].LifeCycleState' --output text 2>&1)"
  if grep -qi 'FileSystemNotFound' <<<"$fs_state"; then
    : # already gone
  elif ! [[ "$fs_state" =~ ^(available|creating|updating|deleting|error)$ ]]; then
    warn "could not read EFS file system $EFS_FILE_SYSTEM_ID state ($fs_state); leaving it and its mount targets."
  elif ! efs_owner_ok "$EFS_FILE_SYSTEM_ID"; then
    [[ $? -eq 2 ]] && warn "could not read ownership tags of file system $EFS_FILE_SYSTEM_ID; leaving it." \
                   || warn "file system $EFS_FILE_SYSTEM_ID is not tagged ManagedBy=$SAMPLE; leaving it."
  else
    echo "Deleting EFS mount targets..."
    mts="$(aws_r efs describe-mount-targets --file-system-id "$EFS_FILE_SYSTEM_ID" \
      --query 'MountTargets[].MountTargetId' --output text 2>&1)"
    if grep -qiE 'error|exception' <<<"$mts"; then
      warn "could not list mount targets of $EFS_FILE_SYSTEM_ID; leaving the file system."
    else
      for mt in $mts; do
        [[ "$mt" == None ]] && continue
        aws_r efs delete-mount-target --mount-target-id "$mt" >/dev/null 2>&1 || true
      done
      r=""
      for _ in $(seq 1 60); do
        r="$(aws_r efs describe-mount-targets --file-system-id "$EFS_FILE_SYSTEM_ID" \
          --query 'length(MountTargets)' --output text 2>/dev/null)"
        [[ "$r" == 0 ]] && break; sleep 5
      done
      if [[ "$r" != 0 ]]; then
        warn "mount targets still present or unconfirmed; re-run --delete-aws-resources."
      else
        echo "Deleting EFS file system $EFS_FILE_SYSTEM_ID (and all data on it)..."
        s=""
        for _ in $(seq 1 60); do
          s="$(aws_r efs describe-file-systems --file-system-id "$EFS_FILE_SYSTEM_ID" \
            --query 'FileSystems[0].LifeCycleState' --output text 2>&1)"
          if grep -qi 'FileSystemNotFound' <<<"$s"; then s=deleted; break; fi
          [[ "$s" == deleted || "$s" == None ]] && break
          aws_r efs delete-file-system --file-system-id "$EFS_FILE_SYSTEM_ID" >/dev/null 2>&1 || true
          sleep 5
        done
        [[ "$s" == deleted || "$s" == None ]] || warn "EFS file system still present or unconfirmed; re-run --delete-aws-resources."
      fi
    fi
  fi
fi

# Delete the NFS security group by OWNERSHIP, not a historical boolean: an owned group recovered
# after a lost or older .env must still be removed. Find it by name and VPC when the id is absent.
sg_id="${EFS_SECURITY_GROUP_ID:-}"
if [[ -z "$sg_id" || "$sg_id" == "None" ]] && [[ -n "${RESOURCE_PREFIX:-}" ]]; then
  vpc="$(aws_r eks describe-cluster --name "${CLUSTER_NAME:-}" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || true)"
  if [[ -n "$vpc" && "$vpc" != "None" ]]; then
    sg_id="$(aws_r ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=$vpc" "Name=group-name,Values=${RESOURCE_PREFIX}-nfs" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
    [[ "$sg_id" == "None" ]] && sg_id=""
  fi
fi
if [[ -n "$sg_id" ]]; then
  sg_owner="$(aws_r ec2 describe-security-groups --group-ids "$sg_id" \
    --query "SecurityGroups[0].Tags[?Key=='ManagedBy'].Value | [0]" --output text 2>&1)"
  if grep -qi 'InvalidGroup.NotFound' <<<"$sg_owner"; then
    : # already gone
  elif [[ "$sg_owner" == "$SAMPLE" ]]; then
    echo "Deleting NFS security group $sg_id..."
    gone=false
    for _ in $(seq 1 30); do
      if aws_r ec2 delete-security-group --group-id "$sg_id" >/dev/null 2>&1; then gone=true; break; fi
      sleep 5
    done
    if ! $gone; then
      if aws_r ec2 describe-security-groups --group-ids "$sg_id" >/dev/null 2>&1; then
        warn "could not delete the NFS security group $sg_id (mount-target interfaces may still be releasing); re-run --delete-aws-resources."
      fi  # a NotFound on the confirm read means it did go away
    fi
  elif grep -qiE 'error|exception' <<<"$sg_owner"; then
    warn "could not read ownership tags of security group $sg_id; leaving it."
  else
    warn "security group $sg_id is not tagged ManagedBy=$SAMPLE; leaving it."
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
