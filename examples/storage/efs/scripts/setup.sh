#!/usr/bin/env bash
# Set up the shared EFS sample.
#
#   CLUSTER_NAME=<cluster> AWS_REGION=<region> ./scripts/setup.sh
#
# What it does, in order:
#   1. Checks the Amazon EFS CSI driver is installed at 2.0.0 or newer, and stops with
#      the install command when it is not. The driver, its service accounts, their IAM
#      roles and their Pod Identity associations are a SHARED INSTALL: this sample reads
#      them and never changes them (no role created, no policy attached, no association
#      touched). It only reads which role the CSI node service account uses, so the file
#      system policy can allow that principal.
#   2. Creates the sample's own resources, each tagged ManagedBy=storage-efs and
#      auto-delete=no: an NFS security group (TCP 2049 from the cluster security group
#      only), an encrypted EFS file system, one mount target per cluster Availability
#      Zone, and an access point (fixed UID/GID 1000, root directory /storage-efs).
#   3. Applies a file system policy that requires TLS, confines every allow to this
#      access point reached through a mount target, grants only ClientMount/ClientWrite,
#      and allows ONLY the CSI node principal (an IAM-signed mount by anyone else is
#      refused). The least privilege lives in the file system policy, which belongs to
#      this sample's own file system, not on the shared node role.
#   4. Records the resource IDs and the CoreDNS and mount-target addresses in a local
#      env file (.env, gitignored) so test.sh can render the manifests.
#
# It does NOT apply the Kubernetes manifests or run the pods; that is test.sh. Idempotent:
# .env records what already exists, so a re-run resumes instead of creating a second file
# system. Tear down with clean.sh.
#
# Overridable (defaults match the page):
#   NAMESPACE        the namespace to run in                 (default nitro-efs-sample)
#   RESOURCE_PREFIX  prefix for AWS resource names           (default storage-efs-<cluster>)
#   ENV_FILE         where resource IDs are written          (default <sample>/.env)
#   KUBECTL          the kubectl command                     (default "kubectl")
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$SAMPLE_DIR/.env}"
NAMESPACE="${NAMESPACE:-nitro-efs-sample}"
KUBECTL="${KUBECTL:-kubectl}"

SAMPLE="storage-efs"
MIN_DRIVER_MAJOR=2

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for c in aws "${KUBECTL%% *}"; do
  command -v "$c" >/dev/null 2>&1 || die "'$c' is required and not on PATH"
done

# Resolve cluster and region, preferring an existing record so a re-run is consistent.
if [[ -f "$ENV_FILE" ]]; then
  caller_cluster="${CLUSTER_NAME:-}"; caller_region="${AWS_REGION:-}"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  if [[ -n "$caller_cluster" && "$caller_cluster" != "${CLUSTER_NAME:-}" ]]; then
    die "$ENV_FILE records cluster '${CLUSTER_NAME:-}', but CLUSTER_NAME=$caller_cluster was given.
Run './scripts/clean.sh --delete-aws-resources' to release those resources first, or set ENV_FILE to a different file."
  fi
  if [[ -n "$caller_region" && "$caller_region" != "${AWS_REGION:-}" ]]; then
    die "$ENV_FILE records region '${AWS_REGION:-}', but AWS_REGION=$caller_region was given.
Run './scripts/clean.sh --delete-aws-resources' first, or set ENV_FILE to a different file."
  fi
fi

CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
[[ -z "$AWS_REGION" ]] && AWS_REGION="$(aws configure get region 2>/dev/null || true)"
[[ -n "$CLUSTER_NAME" ]] || die "set CLUSTER_NAME to your EKS cluster"
[[ -n "$AWS_REGION" ]] || die "set AWS_REGION or configure a default AWS CLI region"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
RESOURCE_PREFIX="${RESOURCE_PREFIX:-storage-efs-${CLUSTER_NAME}}"
RESOURCE_PREFIX="${RESOURCE_PREFIX:0:48}"

EFS_FILE_SYSTEM_ID="${EFS_FILE_SYSTEM_ID:-}"
EFS_ACCESS_POINT_ID="${EFS_ACCESS_POINT_ID:-}"
EFS_SECURITY_GROUP_ID="${EFS_SECURITY_GROUP_ID:-}"
EFS_CSI_NODE_ROLE_ARN="${EFS_CSI_NODE_ROLE_ARN:-}"
CREATED_SECURITY_GROUP="${CREATED_SECURITY_GROUP:-false}"

aws_r() { aws "$@" --region "$AWS_REGION"; }

write_env() {
  {
    printf 'export CLUSTER_NAME=%q\n' "$CLUSTER_NAME"
    printf 'export AWS_REGION=%q\n' "$AWS_REGION"
    printf 'export NAMESPACE=%q\n' "$NAMESPACE"
    printf 'export RESOURCE_PREFIX=%q\n' "$RESOURCE_PREFIX"
    printf 'export EFS_FILE_SYSTEM_ID=%q\n' "$EFS_FILE_SYSTEM_ID"
    printf 'export EFS_ACCESS_POINT_ID=%q\n' "$EFS_ACCESS_POINT_ID"
    printf 'export EFS_SECURITY_GROUP_ID=%q\n' "$EFS_SECURITY_GROUP_ID"
    printf 'export EFS_CSI_NODE_ROLE_ARN=%q\n' "$EFS_CSI_NODE_ROLE_ARN"
    printf 'export CREATED_SECURITY_GROUP=%q\n' "$CREATED_SECURITY_GROUP"
    printf 'export COREDNS_IP=%q\n' "${COREDNS_IP:-}"
    printf 'export MOUNT_TARGET_IPS=%q\n' "${MOUNT_TARGET_IPS:-}"
  } > "$ENV_FILE"
}

# ---- 1. The EFS CSI driver is a shared install: check it, reuse it, never change it. ----
echo "Step 1/4: check the Amazon EFS CSI driver (a shared install; reused, never changed)"
addon_version="$(aws_r eks describe-addon --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-efs-csi-driver --query 'addon.addonVersion' --output text 2>/dev/null || true)"
driver_image="$($KUBECTL get daemonset efs-csi-node -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="efs-plugin")].image}' 2>/dev/null || true)"
driver_version="$addon_version"
[[ -n "$driver_version" && "$driver_version" != "None" ]] || driver_version="${driver_image##*:}"
driver_major="${driver_version#v}"; driver_major="${driver_major%%.*}"
if ! [[ "$driver_major" =~ ^[0-9]+$ && "$driver_major" -ge "$MIN_DRIVER_MAJOR" ]]; then
  die "the Amazon EFS CSI driver ${MIN_DRIVER_MAJOR}.0.0 or newer is required (found: ${driver_version:-none}).
Install it as the page's prerequisites describe, following the EFS CSI guide, then re-run:
  https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html"
fi
echo "  found aws-efs-csi-driver $driver_version (>= ${MIN_DRIVER_MAJOR}.0.0)."

# Read the CSI node service account's Pod Identity role WITHOUT changing it.
node_assoc="$(aws_r eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
  --namespace kube-system --service-account efs-csi-node-sa \
  --query 'associations[0].associationId' --output text 2>/dev/null || true)"
[[ -n "$node_assoc" && "$node_assoc" != "None" ]] \
  || die "the efs-csi-node-sa service account has no EKS Pod Identity association.
This sample mounts with IAM authorization, which needs the CSI node service account to carry
an identity. Configure the driver's Pod Identity roles as the page's prerequisites describe."
EFS_CSI_NODE_ROLE_ARN="$(aws_r eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
  --association-id "$node_assoc" --query 'association.roleArn' --output text)"
[[ "$EFS_CSI_NODE_ROLE_ARN" == arn:aws:iam::"$ACCOUNT_ID":role/* ]] \
  || die "unexpected CSI node role ARN: $EFS_CSI_NODE_ROLE_ARN"
echo "  CSI node principal (read, not changed): $EFS_CSI_NODE_ROLE_ARN"
write_env

# ---- 2. The sample's own AWS resources. ----
echo "Step 2/4: create the sample's security group, file system, mount targets and access point"
VPC_ID="$(aws_r eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
CLUSTER_SG="$(aws_r eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)"
read -r -a SUBNET_IDS <<<"$(aws_r eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.subnetIds' --output text)"

# One subnet per AZ (first seen), so one mount target per AZ.
declare -A SUBNET_BY_AZ=()
while read -r az subnet; do
  [[ -n "$az" && -n "$subnet" ]] || continue
  [[ -n "${SUBNET_BY_AZ[$az]:-}" ]] || SUBNET_BY_AZ[$az]="$subnet"
done < <(aws_r ec2 describe-subnets --subnet-ids "${SUBNET_IDS[@]}" \
  --query 'Subnets[].[AvailabilityZoneId,SubnetId]' --output text)
[[ ${#SUBNET_BY_AZ[@]} -gt 0 ]] || die "could not discover the cluster's subnets"

# Security group: NFS 2049 from the cluster security group only.
if [[ -z "$EFS_SECURITY_GROUP_ID" || "$EFS_SECURITY_GROUP_ID" == "None" ]]; then
  sg_name="${RESOURCE_PREFIX}-nfs"
  EFS_SECURITY_GROUP_ID="$(aws_r ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$sg_name" \
    --query 'SecurityGroups[0].GroupId' --output text)"
  if [[ "$EFS_SECURITY_GROUP_ID" == "None" ]]; then
    EFS_SECURITY_GROUP_ID="$(aws_r ec2 create-security-group --group-name "$sg_name" \
      --description "NFS from the EKS cluster security group for the storage-efs sample" \
      --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$sg_name},{Key=ManagedBy,Value=$SAMPLE},{Key=auto-delete,Value=no}]" \
      --query GroupId --output text)"
    aws_r ec2 authorize-security-group-ingress --group-id "$EFS_SECURITY_GROUP_ID" \
      --protocol tcp --port 2049 --source-group "$CLUSTER_SG" >/dev/null
    CREATED_SECURITY_GROUP=true
    echo "  created NFS security group $EFS_SECURITY_GROUP_ID (TCP 2049 from $CLUSTER_SG only)."
  else
    echo "  reusing NFS security group $EFS_SECURITY_GROUP_ID."
  fi
  write_env
fi

# File system, found by its deterministic creation token so a lost .env does not create a second.
if [[ -z "$EFS_FILE_SYSTEM_ID" || "$EFS_FILE_SYSTEM_ID" == "None" ]]; then
  EFS_FILE_SYSTEM_ID="$(aws_r efs describe-file-systems --creation-token "${RESOURCE_PREFIX}-fs" \
    --query 'FileSystems[0].FileSystemId' --output text 2>/dev/null || true)"
  [[ "$EFS_FILE_SYSTEM_ID" == "None" ]] && EFS_FILE_SYSTEM_ID=""
  if [[ -z "$EFS_FILE_SYSTEM_ID" ]]; then
    echo "  creating an encrypted EFS file system..."
    EFS_FILE_SYSTEM_ID="$(aws_r efs create-file-system --creation-token "${RESOURCE_PREFIX}-fs" \
      --encrypted --performance-mode generalPurpose --throughput-mode elastic \
      --tags "Key=Name,Value=${RESOURCE_PREFIX}-fs" "Key=ManagedBy,Value=$SAMPLE" "Key=auto-delete,Value=no" \
      --query FileSystemId --output text)"
  else
    echo "  adopting the EFS file system from a previous run: $EFS_FILE_SYSTEM_ID"
  fi
  write_env
fi
for _ in $(seq 1 60); do
  st="$(aws_r efs describe-file-systems --file-system-id "$EFS_FILE_SYSTEM_ID" \
    --query 'FileSystems[0].LifeCycleState' --output text)"
  [[ "$st" == available ]] && break
  [[ "$st" == error ]] && die "the EFS file system entered an error state"
  sleep 5
done
[[ "$st" == available ]] || die "timed out waiting for the EFS file system"

echo "  ensuring one mount target per cluster Availability Zone..."
for az in "${!SUBNET_BY_AZ[@]}"; do
  existing="$(aws_r efs describe-mount-targets --file-system-id "$EFS_FILE_SYSTEM_ID" \
    --query "MountTargets[?AvailabilityZoneId=='$az'].MountTargetId | [0]" --output text)"
  if [[ "$existing" == "None" ]]; then
    aws_r efs create-mount-target --file-system-id "$EFS_FILE_SYSTEM_ID" \
      --subnet-id "${SUBNET_BY_AZ[$az]}" --security-groups "$EFS_SECURITY_GROUP_ID" >/dev/null
  fi
done
for _ in $(seq 1 60); do
  pending="$(aws_r efs describe-mount-targets --file-system-id "$EFS_FILE_SYSTEM_ID" \
    --query 'length(MountTargets[?LifeCycleState!=`available`])' --output text)"
  [[ "$pending" == 0 ]] && break
  sleep 5
done
[[ "$pending" == 0 ]] || die "timed out waiting for the EFS mount targets"

# Access point: fixed UID/GID 1000, root /storage-efs.
if [[ -z "$EFS_ACCESS_POINT_ID" || "$EFS_ACCESS_POINT_ID" == "None" ]]; then
  EFS_ACCESS_POINT_ID="$(aws_r efs describe-access-points --file-system-id "$EFS_FILE_SYSTEM_ID" \
    --query "AccessPoints[?Tags[?Key=='Name' && Value=='${RESOURCE_PREFIX}-ap']].AccessPointId | [0]" \
    --output text 2>/dev/null || true)"
  [[ "$EFS_ACCESS_POINT_ID" == "None" ]] && EFS_ACCESS_POINT_ID=""
  if [[ -z "$EFS_ACCESS_POINT_ID" ]]; then
    echo "  creating the EFS access point (uid/gid 1000, root /storage-efs)..."
    EFS_ACCESS_POINT_ID="$(aws_r efs create-access-point --file-system-id "$EFS_FILE_SYSTEM_ID" \
      --posix-user Uid=1000,Gid=1000 \
      --root-directory "Path=/storage-efs,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=0770}" \
      --tags "Key=Name,Value=${RESOURCE_PREFIX}-ap" "Key=ManagedBy,Value=$SAMPLE" "Key=auto-delete,Value=no" \
      --query AccessPointId --output text)"
  else
    echo "  adopting the EFS access point from a previous run: $EFS_ACCESS_POINT_ID"
  fi
  write_env
fi
for _ in $(seq 1 60); do
  st="$(aws_r efs describe-access-points --access-point-id "$EFS_ACCESS_POINT_ID" \
    --query 'AccessPoints[0].LifeCycleState' --output text)"
  [[ "$st" == available ]] && break
  [[ "$st" == error ]] && die "the EFS access point entered an error state"
  sleep 5
done
[[ "$st" == available ]] || die "timed out waiting for the EFS access point"

# Re-tag on every run: an adopted resource from an older run may predate the tags.
aws_r efs tag-resource --resource-id "$EFS_FILE_SYSTEM_ID" \
  --tags Key=ManagedBy,Value=$SAMPLE Key=auto-delete,Value=no
aws_r efs tag-resource --resource-id "$EFS_ACCESS_POINT_ID" \
  --tags Key=ManagedBy,Value=$SAMPLE Key=auto-delete,Value=no
aws_r ec2 create-tags --resources "$EFS_SECURITY_GROUP_ID" \
  --tags Key=ManagedBy,Value=$SAMPLE Key=auto-delete,Value=no

# ---- 3. The file system policy: allow only the CSI node principal, require TLS. ----
echo "Step 3/4: apply the EFS file system policy (TLS required, this access point only, CSI node principal only)"
FS_ARN="arn:aws:elasticfilesystem:$AWS_REGION:$ACCOUNT_ID:file-system/$EFS_FILE_SYSTEM_ID"
AP_ARN="arn:aws:elasticfilesystem:$AWS_REGION:$ACCOUNT_ID:access-point/$EFS_ACCESS_POINT_ID"
policy_file="$(mktemp)"
trap 'rm -f "$policy_file"' EXIT
# Build the JSON with the file tool's companion renderer, not inline, so a value cannot be
# mangled by the shell. We render here with python from the sample's iam/ template.
python3 - "$SAMPLE_DIR/iam/file-system-policy.json" "$FS_ARN" "$AP_ARN" "$EFS_CSI_NODE_ROLE_ARN" > "$policy_file" <<'PY'
import json, sys
tmpl_path, fs_arn, ap_arn, node_role = sys.argv[1:5]
with open(tmpl_path) as f:
    doc = json.load(f)
doc.pop("Comment", None)
repl = {"<EFS_FILE_SYSTEM_ARN>": fs_arn, "<EFS_ACCESS_POINT_ARN>": ap_arn,
        "<EFS_CSI_NODE_ROLE_ARN>": node_role}
def sub(x):
    if isinstance(x, str):
        return repl.get(x, x)
    if isinstance(x, list):
        return [sub(v) for v in x]
    if isinstance(x, dict):
        return {k: sub(v) for k, v in x.items()}
    return x
json.dump(sub(doc), sys.stdout, indent=2)
PY
aws_r efs put-file-system-policy --file-system-id "$EFS_FILE_SYSTEM_ID" \
  --policy "file://$policy_file" >/dev/null
echo "  file system policy applied."

# ---- 4. Record the addresses the network policy needs. ----
echo "Step 4/4: record the CoreDNS and mount-target addresses for the network policy"
COREDNS_IP="$($KUBECTL get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
[[ -n "$COREDNS_IP" ]] || die "could not read the CoreDNS Service address (kube-dns in kube-system)"
MOUNT_TARGET_IPS="$(aws_r efs describe-mount-targets --file-system-id "$EFS_FILE_SYSTEM_ID" \
  --query 'MountTargets[].IpAddress' --output text | tr '\t' ' ')"
[[ -n "$MOUNT_TARGET_IPS" ]] || die "could not read the mount-target IP addresses"
write_env
echo "  CoreDNS: $COREDNS_IP"
echo "  mount targets: $MOUNT_TARGET_IPS"

echo
echo "EFS storage is ready. Resource IDs and addresses: $ENV_FILE"
echo "Next:  NAMESPACE=$NAMESPACE ./scripts/test.sh    # deploy the pods and assert"
echo "Clean: NAMESPACE=$NAMESPACE ./scripts/clean.sh                        # Kubernetes objects"
echo "       NAMESPACE=$NAMESPACE ./scripts/clean.sh --delete-aws-resources  # ...and the EFS resources"
