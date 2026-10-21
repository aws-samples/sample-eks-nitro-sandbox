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

# efs_owner_rc <resource-id>: 0 = tagged ManagedBy=storage-efs (this sample's), 1 = tagged
# something else or untagged, 2 = the tag read itself failed. Called on its own line with the
# status captured into a variable, never inside `! ...` (which would change $?).
efs_owner_rc() {
  local v
  v="$(aws_r efs list-tags-for-resource --resource-id "$1" \
    --query "Tags[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null)" || return 2
  [[ "$v" == "$SAMPLE" ]] && return 0 || return 1
}

# efs_gone <describe-cmd...> <not-found-token>: run an EFS describe; 0 = the resource is
# confirmed gone (the error names <not-found-token>), 1 = present, 2 = the read failed for
# another reason. Lets a confirmation loop tell "deleted" from "could not tell".
efs_gone() {
  local token="${!#}" out
  set -- "${@:1:$(($#-1))}"
  out="$(aws_r "$@" 2>&1)"
  if [[ $? -eq 0 ]]; then return 1; fi
  grep -qi "$token" <<<"$out" && return 0 || return 2
}

# Wait for the PV to be gone so no NFS client holds the mount targets. A timeout here means an
# NFS client may still hold a mount target, so do NOT start AWS teardown. Die both when the PV is
# still present AND when its state cannot be read: either way teardown is unsafe.
if ! $KUBECTL wait --for=delete pv/storage-efs-shared --timeout=3m >/dev/null 2>&1; then
  kexists pv storage-efs-shared; pv_rc=$?
  case $pv_rc in
    0) die "PV storage-efs-shared is still present after waiting; an NFS client may still hold a mount target. Run './scripts/clean.sh' (no flag) first to remove the pods and PV, then re-run with --delete-aws-resources." ;;
    2) die "could not confirm PV storage-efs-shared was deleted (the lookup failed); refusing to start AWS teardown while a mount target may still be held. Re-run once the cluster reads cleanly." ;;
  esac
fi

if [[ -n "${EFS_ACCESS_POINT_ID:-}" ]]; then
  # Is it already gone? (read errors other than NotFound are a failure, not "gone").
  efs_gone efs describe-access-points --access-point-id "$EFS_ACCESS_POINT_ID" AccessPointNotFound
  case $? in
    0) : ;;  # already gone
    2) warn "could not read EFS access point $EFS_ACCESS_POINT_ID; leaving it." ;;
    1)
      efs_owner_rc "$EFS_ACCESS_POINT_ID"; ap_owner_rc=$?
      case $ap_owner_rc in
        2) warn "could not read ownership tags of access point $EFS_ACCESS_POINT_ID; leaving it." ;;
        1) warn "access point $EFS_ACCESS_POINT_ID is not tagged ManagedBy=$SAMPLE; leaving it." ;;
        0)
          echo "Deleting EFS access point $EFS_ACCESS_POINT_ID..."
          aws_r efs delete-access-point --access-point-id "$EFS_ACCESS_POINT_ID" >/dev/null 2>&1 || true
          ap_rc=1
          for _ in $(seq 1 60); do
            efs_gone efs describe-access-points --access-point-id "$EFS_ACCESS_POINT_ID" AccessPointNotFound; ap_rc=$?
            [[ "$ap_rc" != 1 ]] && break
            sleep 5
          done
          [[ "$ap_rc" == 0 ]] || warn "EFS access point still present or unconfirmed; re-run --delete-aws-resources."
          ;;
      esac
      ;;
  esac
fi

if [[ -n "${EFS_FILE_SYSTEM_ID:-}" ]]; then
  efs_gone efs describe-file-systems --file-system-id "$EFS_FILE_SYSTEM_ID" FileSystemNotFound; fs_rc=$?
  case $fs_rc in
    0) : ;;  # already gone
    2) warn "could not read EFS file system $EFS_FILE_SYSTEM_ID; leaving it and its mount targets." ;;
    1)
      efs_owner_rc "$EFS_FILE_SYSTEM_ID"; fs_owner_rc=$?
      case $fs_owner_rc in
        2) warn "could not read ownership tags of file system $EFS_FILE_SYSTEM_ID; leaving it." ;;
        1) warn "file system $EFS_FILE_SYSTEM_ID is not tagged ManagedBy=$SAMPLE; leaving it." ;;
        0)
          echo "Deleting EFS mount targets..."
          mts="$(aws_r efs describe-mount-targets --file-system-id "$EFS_FILE_SYSTEM_ID" \
            --query 'MountTargets[].MountTargetId' --output text 2>&1)"
          if [[ $? -ne 0 ]] || grep -qiE 'error|exception' <<<"$mts"; then
            warn "could not list mount targets of $EFS_FILE_SYSTEM_ID; leaving the file system."
          else
            for mt in $mts; do
              [[ "$mt" == None ]] && continue
              aws_r efs delete-mount-target --mount-target-id "$mt" >/dev/null 2>&1 || true
            done
            r="unknown"
            for _ in $(seq 1 60); do
              r="$(aws_r efs describe-mount-targets --file-system-id "$EFS_FILE_SYSTEM_ID" \
                --query 'length(MountTargets)' --output text 2>/dev/null)" || { r="unknown"; sleep 5; continue; }
              [[ "$r" == 0 ]] && break; sleep 5
            done
            if [[ "$r" != 0 ]]; then
              warn "mount targets still present or unconfirmed; re-run --delete-aws-resources."
            else
              echo "Deleting EFS file system $EFS_FILE_SYSTEM_ID (and all data on it)..."
              fs_del_rc=1
              for _ in $(seq 1 60); do
                efs_gone efs describe-file-systems --file-system-id "$EFS_FILE_SYSTEM_ID" FileSystemNotFound; fs_del_rc=$?
                [[ "$fs_del_rc" != 1 ]] && break
                aws_r efs delete-file-system --file-system-id "$EFS_FILE_SYSTEM_ID" >/dev/null 2>&1 || true
                sleep 5
              done
              [[ "$fs_del_rc" == 0 ]] || warn "EFS file system still present or unconfirmed; re-run --delete-aws-resources."
            fi
          fi
          ;;
      esac
      ;;
  esac
fi

# Delete the NFS security group by OWNERSHIP, not a historical boolean: an owned group recovered
# after a lost or older .env must still be removed. Find it by name and VPC when the id is absent;
# a failed lookup there is a failure, not "no group".
sg_id="${EFS_SECURITY_GROUP_ID:-}"
if [[ -z "$sg_id" || "$sg_id" == "None" ]] && [[ -n "${RESOURCE_PREFIX:-}" && -n "${CLUSTER_NAME:-}" ]]; then
  vpc="$(aws_r eks describe-cluster --name "$CLUSTER_NAME" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null)"
  if [[ $? -ne 0 || -z "$vpc" || "$vpc" == "None" ]]; then
    warn "could not resolve the cluster VPC to find the NFS security group by name; it may be left behind. Re-run with EFS_SECURITY_GROUP_ID set, or once the cluster reads cleanly."
  else
    sg_lookup="$(aws_r ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=$vpc" "Name=group-name,Values=${RESOURCE_PREFIX}-nfs" \
      --query 'SecurityGroups[0].GroupId' --output text 2>&1)"
    if [[ $? -ne 0 ]]; then
      warn "could not look up the NFS security group by name; it may be left behind. Re-run once EC2 reads cleanly."
    elif [[ "$sg_lookup" != "None" && -n "$sg_lookup" ]]; then
      sg_id="$sg_lookup"
    fi
  fi
fi
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
        fi  # InvalidGroup.NotFound on the confirm read means it did go away
      fi
    else
      warn "security group $sg_id is not tagged ManagedBy=$SAMPLE; leaving it."
    fi
  elif grep -qi 'InvalidGroup.NotFound' <<<"$sg_owner"; then
    : # already gone
  else
    warn "could not read ownership tags of security group $sg_id; leaving it."
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
