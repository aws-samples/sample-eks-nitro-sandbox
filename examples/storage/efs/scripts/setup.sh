#!/usr/bin/env bash
# Set up the shared EFS sample.
#
#   CLUSTER_NAME=<cluster> AWS_REGION=<region> ./scripts/setup.sh
#
# What it does, in order:
#   1. Checks the Amazon EFS CSI driver is installed at 3.5.1 or newer, comparing every
#      component of the version and not the major alone, and stops with the install or
#      upgrade command when it is not. The driver, its service accounts, their IAM
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
#   5. Deploys the Kubernetes side: the namespace (labelled this sample's), the egress
#      ApplicationNetworkPolicy (waiting for its PolicyEndpoint), the StorageClass, the static
#      PV and PVC, and the writer and reader pods, then waits for both to become Ready.
#
# Idempotent: .env records what already exists, so a re-run resumes instead of creating a
# second file system, and re-applies the Kubernetes side. Tear down with clean.sh.
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
MIN_DRIVER_VERSION=3.5.1

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

# Refuse to adopt an AWS resource that is not this sample's. An EFS resource found by name or
# creation token must carry ManagedBy=storage-efs before setup reuses or retags it, so a run
# can never take over a resource another demo created with a colliding name. A tag read that
# fails is fatal (could not determine ownership), never treated as owned.
efs_require_owner() { # efs_require_owner <resource-id> <human description>
  local id="$1" desc="$2" v
  v="$(aws_r efs list-tags-for-resource --resource-id "$id" \
    --query "Tags[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null)" \
    || die "could not read the ownership tags of $desc ($id); refusing to adopt it until the read succeeds."
  [[ "$v" == "$SAMPLE" ]] \
    || die "$desc ($id) exists but is not tagged ManagedBy=$SAMPLE (found '${v:-<none>}'); refusing to adopt a resource this sample did not create. Use a different RESOURCE_PREFIX, or remove the conflicting resource if it is yours."
}

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
    printf 'export MOUNT_TARGET_IPS=%q\n' "${MOUNT_TARGET_IPS:-}"
  } > "$ENV_FILE"
}

# Is the installed driver at least the minimum? Every component is compared, not the major
# alone: 3.0.0 and 3.4.9 are older than 3.5.1 and must be refused. The version arrives either
# as the EKS add-on version ("v3.5.1-eksbuild.1") or as the efs-csi-node container's image tag
# ("v3.5.1"), so a leading "v" and any "-eksbuild.N" suffix come off before the comparison. A
# version neither source yields, or one that does not parse, is "could not determine", which
# is a refusal and never a pass.
driver_version_at_least() { # driver_version_at_least <found> <minimum major.minor.patch>
  local found="${1#v}" i
  local -a f m
  found="${found%%-*}"
  [[ "$found" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a f <<<"$found"
  IFS=. read -r -a m <<<"$2"
  for i in 0 1 2; do
    if ((10#${f[i]} > 10#${m[i]})); then return 0; fi
    if ((10#${f[i]} < 10#${m[i]})); then return 1; fi
  done
  return 0
}

# ---- 1. The EFS CSI driver is a shared install: check it, reuse it, never change it. ----
echo "Step 1/5: check the Amazon EFS CSI driver (a shared install; reused, never changed)"
# How the driver was installed decides what the refusal below can honestly tell the reader,
# so each lookup has to tell "not there" apart from "could not ask". Both reads were
# "|| true" before, which turned a transient or unauthorized call into "not installed" --
# so a cluster that already had the add-on could be told to run create-addon, which fails.
# list-addons answers whether the add-on exists whichever way the answer goes, so its own
# failure is a failure; kubectl --ignore-not-found exits 0 with no output when there is no
# daemonset and non-zero only on a real error.
addon_present="$(aws_r eks list-addons --cluster-name "$CLUSTER_NAME" \
  --query "addons[?@=='aws-efs-csi-driver'] | [0]" --output text)" \
  || die "could not list the EKS add-ons on cluster '$CLUSTER_NAME' (the error is above), so
whether the Amazon EFS CSI driver is installed as an add-on could not be determined. Fix that,
then re-run."
addon_version=""
if [[ "$addon_present" == aws-efs-csi-driver ]]; then
  addon_version="$(aws_r eks describe-addon --cluster-name "$CLUSTER_NAME" \
    --addon-name aws-efs-csi-driver --query 'addon.addonVersion' --output text)" \
    || die "the aws-efs-csi-driver add-on is installed on cluster '$CLUSTER_NAME', but reading
its version failed (the error is above), so whether it is $MIN_DRIVER_VERSION or newer
could not be determined. Fix that, then re-run."
  if [[ -z "$addon_version" || "$addon_version" == "None" ]]; then
    die "the aws-efs-csi-driver add-on on cluster '$CLUSTER_NAME' reported no version, so
whether it is $MIN_DRIVER_VERSION or newer could not be determined."
  fi
fi
# The daemonset is read only when there is no add-on, which is the only case its answer
# decides anything: the version to compare, and whether the refusal should name create-addon
# or say the driver was installed some other way. Reading it when the add-on already gave an
# authoritative version would let a kubectl hiccup stop a run whose version was never in
# doubt, under a message saying the version could not be determined.
driver_image=""
if [[ "$addon_present" != aws-efs-csi-driver ]]; then
  # One read, two facts: whether the daemonset is there at all, and the efs-plugin image on
  # it. Reading only the image cannot tell "no daemonset" from "a daemonset whose containers
  # are not the ones this expects", and the second must not be answered with create-addon.
  ds_read="$($KUBECTL get daemonset efs-csi-node -n kube-system --ignore-not-found \
    -o jsonpath='{.metadata.name}{"\t"}{.spec.template.spec.containers[?(@.name=="efs-plugin")].image}')" \
    || die "there is no aws-efs-csi-driver add-on on cluster '$CLUSTER_NAME', and reading the
efs-csi-node daemonset in kube-system failed (the error is above), so which version of the
Amazon EFS CSI driver is installed could not be determined. Check the kube context you meant
('kubectl config current-context'), then re-run."
  # The separator is emitted unconditionally by the jsonpath, so a read that found the
  # daemonset always has one. Were it ever missing, driver_image would hold the name, which
  # fails to parse as a version: a refusal, never an accept.
  ds_name="${ds_read%%$'\t'*}"
  driver_image="${ds_read#*$'\t'}"
  if [[ -n "$ds_name" && -z "$driver_image" ]]; then
    die "the efs-csi-node daemonset in kube-system has no efs-plugin container, so which
version of the Amazon EFS CSI driver it runs could not be determined. Check that install, then
re-run."
  fi
fi
driver_version="$addon_version"
[[ -n "$driver_version" ]] || driver_version="${driver_image##*:}"
if ! driver_version_at_least "$driver_version" "$MIN_DRIVER_VERSION"; then
  # Name the command that fits what is on the cluster. update-addon fails when there is no
  # add-on to update, and create-addon fails when there already is one, so printing one of
  # them for every case hands the reader a command that errors. A driver installed some
  # other way (a Helm release, a self-managed daemonset) is neither, and is upgraded the way
  # it was installed. Which add-on build to ask for is the cluster's to answer: an
  # -eksbuild suffix is only offered for some Kubernetes versions, so the message has the
  # reader list the compatible builds rather than pinning one that may not exist there.
  # Every line below is paste-safe: an angle-bracket placeholder would be read as a shell
  # redirection, so the two values the reader supplies arrive as assignments instead.
  pick="  # list the builds offered for this cluster, then set ADDON_VERSION to one of them
  KUBERNETES_VERSION=\$(aws eks describe-cluster --name \"$CLUSTER_NAME\" --region \"$AWS_REGION\" \\
    --query cluster.version --output text)
  aws eks describe-addon-versions --addon-name aws-efs-csi-driver --region \"$AWS_REGION\" \\
    --kubernetes-version \"\$KUBERNETES_VERSION\" \\
    --query 'addons[0].addonVersions[].addonVersion' --output text
  ADDON_VERSION=    # one of those, $MIN_DRIVER_VERSION or newer"
  if [[ "$addon_present" == aws-efs-csi-driver ]]; then
    how="Upgrade the add-on to a compatible build of $MIN_DRIVER_VERSION or newer, then re-run:
$pick
  aws eks update-addon --cluster-name \"$CLUSTER_NAME\" --region \"$AWS_REGION\" \\
    --addon-name aws-efs-csi-driver --addon-version \"\$ADDON_VERSION\""
  elif [[ -z "$driver_image" ]]; then
    how="Neither the aws-efs-csi-driver add-on nor an efs-csi-node daemonset in kube-system is
there, which is the whole of what this check looks for. If the driver is installed some other
way, upgrade that install to $MIN_DRIVER_VERSION or newer. Otherwise install the add-on, then
re-run:
$pick
  aws eks create-addon --cluster-name \"$CLUSTER_NAME\" --region \"$AWS_REGION\" \\
    --addon-name aws-efs-csi-driver --addon-version \"\$ADDON_VERSION\""
  else
    how="The driver runs as the efs-csi-node daemonset rather than as an EKS add-on
($driver_image), so upgrade it to $MIN_DRIVER_VERSION or newer the way it was installed, then
re-run."
  fi
  die "the Amazon EFS CSI driver $MIN_DRIVER_VERSION or newer is required (found: ${driver_version:-no version from either the add-on or the efs-csi-node image; could not determine}).
$how
The page's prerequisites and the EFS CSI driver guide have the detail:
  https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html"
fi
echo "  found aws-efs-csi-driver $driver_version (>= $MIN_DRIVER_VERSION)."

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
echo "Step 2/5: create the sample's security group, file system, mount targets and access point"
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
    # Found by name and VPC: adopt only if it is this sample's (ManagedBy tag) and its ingress
    # is the single expected rule. Otherwise refuse rather than reuse or retag it.
    sg_owner="$(aws_r ec2 describe-security-groups --group-ids "$EFS_SECURITY_GROUP_ID" \
      --query "SecurityGroups[0].Tags[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null)" \
      || die "could not read the ownership tags of security group $EFS_SECURITY_GROUP_ID; refusing to adopt it."
    [[ "$sg_owner" == "$SAMPLE" ]] \
      || die "a security group named '$sg_name' already exists in $VPC_ID but is not tagged ManagedBy=$SAMPLE (found '${sg_owner:-<none>}'); refusing to adopt it. Use a different RESOURCE_PREFIX, or remove the conflicting group if it is yours."
    sg_ingress="$(aws_r ec2 describe-security-groups --group-ids "$EFS_SECURITY_GROUP_ID" \
      --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)" \
      || die "could not read the rules of security group $EFS_SECURITY_GROUP_ID."
    CLUSTER_SG="$CLUSTER_SG" python3 -c 'import json,sys,os
r=json.load(sys.stdin); csg=os.environ["CLUSTER_SG"]
if len(r)!=1: sys.exit(1)
p=r[0]
if not (p.get("FromPort")==2049 and p.get("ToPort")==2049 and p.get("IpProtocol")=="tcp"): sys.exit(1)
if p.get("IpRanges") or p.get("Ipv6Ranges") or p.get("PrefixListIds"): sys.exit(1)
pairs=p.get("UserIdGroupPairs") or []
sys.exit(0 if (len(pairs)==1 and pairs[0].get("GroupId")==csg) else 1)' <<<"$sg_ingress" \
      || die "the existing security group $EFS_SECURITY_GROUP_ID does not have exactly the expected rule (TCP 2049 from the cluster security group $CLUSTER_SG only); refusing to reuse it."
    CREATED_SECURITY_GROUP=true
    echo "  reusing this sample's NFS security group $EFS_SECURITY_GROUP_ID."
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
    efs_require_owner "$EFS_FILE_SYSTEM_ID" "the EFS file system found by creation token"
    echo "  adopting this sample's EFS file system from a previous run: $EFS_FILE_SYSTEM_ID"
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
    efs_require_owner "$EFS_ACCESS_POINT_ID" "the EFS access point found by Name tag"
    # It must be on THIS file system, with the sample's root directory and POSIX identity.
    ap_fs="$(aws_r efs describe-access-points --access-point-id "$EFS_ACCESS_POINT_ID" \
      --query 'AccessPoints[0].FileSystemId' --output text 2>/dev/null)" \
      || die "could not read access point $EFS_ACCESS_POINT_ID; refusing to adopt it."
    [[ "$ap_fs" == "$EFS_FILE_SYSTEM_ID" ]] \
      || die "access point $EFS_ACCESS_POINT_ID is on file system $ap_fs, not this sample's $EFS_FILE_SYSTEM_ID; refusing to adopt it."
    ap_cfg="$(aws_r efs describe-access-points --access-point-id "$EFS_ACCESS_POINT_ID" \
      --query 'AccessPoints[0].[RootDirectory.Path,PosixUser.Uid,PosixUser.Gid]' --output text 2>/dev/null)"
    [[ "$ap_cfg" == $'/storage-efs\t1000\t1000' ]] \
      || die "access point $EFS_ACCESS_POINT_ID does not have the expected root directory /storage-efs and uid/gid 1000 (found: $ap_cfg); refusing to adopt it."
    echo "  adopting this sample's EFS access point from a previous run: $EFS_ACCESS_POINT_ID"
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

# Verify ownership of EVERY resource before retagging it, not only the ones discovered this run.
# An id loaded from .env (from a previous run or another machine) reaches here too, and must not
# be retagged ManagedBy=storage-efs unless it ALREADY carries that tag: otherwise a stale .env
# pointing at a resource another demo owns would be silently adopted. efs_require_owner dies if
# the tag is absent, wrong, or unreadable.
efs_require_owner "$EFS_FILE_SYSTEM_ID" "the EFS file system"
efs_require_owner "$EFS_ACCESS_POINT_ID" "the EFS access point"
sg_owner_check="$(aws_r ec2 describe-security-groups --group-ids "$EFS_SECURITY_GROUP_ID" \
  --query "SecurityGroups[0].Tags[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null)" \
  || die "could not read the ownership tags of security group $EFS_SECURITY_GROUP_ID; refusing to retag it."
[[ "$sg_owner_check" == "$SAMPLE" ]] \
  || die "security group $EFS_SECURITY_GROUP_ID is not tagged ManagedBy=$SAMPLE (found '${sg_owner_check:-<none>}'); refusing to adopt or retag a group this sample did not create."

# Re-tag on every run (idempotent): auto-delete=no may predate an older run's tags. Ownership is
# already confirmed above, so this only refreshes tags on a resource that is this sample's.
aws_r efs tag-resource --resource-id "$EFS_FILE_SYSTEM_ID" \
  --tags Key=ManagedBy,Value=$SAMPLE Key=auto-delete,Value=no
aws_r efs tag-resource --resource-id "$EFS_ACCESS_POINT_ID" \
  --tags Key=ManagedBy,Value=$SAMPLE Key=auto-delete,Value=no
aws_r ec2 create-tags --resources "$EFS_SECURITY_GROUP_ID" \
  --tags Key=ManagedBy,Value=$SAMPLE Key=auto-delete,Value=no

# ---- 3. The file system policy: allow only the CSI node principal, require TLS. ----
echo "Step 3/5: apply the EFS file system policy (TLS required, this access point only, CSI node principal only)"
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
echo "Step 4/5: record the mount-target addresses for the network policy"
# DNS egress is allowed to any address (the policy opens only port 53), because on EKS Auto
# Mode CoreDNS runs as a per-node systemd service rather than a pod behind a ClusterIP, so the
# resolver a pod reaches is node-local. Only the mount-target IPs need recording.
MOUNT_TARGET_IPS="$(aws_r efs describe-mount-targets --file-system-id "$EFS_FILE_SYSTEM_ID" \
  --query 'MountTargets[].IpAddress' --output text | tr '\t' ' ')"
[[ -n "$MOUNT_TARGET_IPS" ]] || die "could not read the mount-target IP addresses"
write_env
echo "  mount targets: $MOUNT_TARGET_IPS"

# ---- 5. Deploy: the namespace, the egress policy, the StorageClass, the PV/PVC and the pods. ----
echo "Step 5/5: deploy the egress policy and the two sandbox pods"
# Create the namespace only when absent; when it exists, require this sample's label before
# applying anything into it, so the run never puts objects in a namespace another demo owns.
ns_errf="$(mktemp)"
if $KUBECTL get namespace "$NAMESPACE" -o name >/dev/null 2>"$ns_errf"; then
  ns_label="$($KUBECTL get namespace "$NAMESPACE" -o "jsonpath={.metadata.labels.app\.kubernetes\.io/part-of}" 2>/dev/null)" \
    || die "could not read the labels of namespace '$NAMESPACE'; refusing to apply into it."
  [[ "$ns_label" == "$SAMPLE" ]] \
    || die "namespace '$NAMESPACE' exists but is not labelled app.kubernetes.io/part-of=$SAMPLE (found '${ns_label:-<none>}'); refusing to apply into a namespace this sample did not create. Choose a different NAMESPACE."
  echo "  namespace '$NAMESPACE' already exists and is this sample's; reusing it."
elif grep -qi 'notfound\|not found' "$ns_errf"; then
  $KUBECTL create namespace "$NAMESPACE" || die "could not create namespace '$NAMESPACE'"
  $KUBECTL label namespace "$NAMESPACE" "app.kubernetes.io/part-of=$SAMPLE" --overwrite \
    || die "could not label namespace '$NAMESPACE'"
  echo "  created namespace '$NAMESPACE' and labelled it this sample's."
else
  rm -f "$ns_errf"; die "could not read namespace '$NAMESPACE' (the lookup failed). Re-run once the cluster reads cleanly."
fi
rm -f "$ns_errf"

# The egress policy: render the checked-in deploy/egress-policy.yaml so the file the page shows
# is the file that is applied. The DNS rule is already a literal 0.0.0.0/0 in the file (DNS is
# allowed to any address), so the only thing to render is <MOUNT_TARGET_BLOCK>, expanded into
# one `- ipBlock: { cidr: <ip>/32 }` line per mount-target IP, preserving the block's indentation.
# Done in Python so neither the shell word-splits the IP list nor a placeholder in a comment is
# corrupted.
python3 - "$SAMPLE_DIR/deploy/egress-policy.yaml" $MOUNT_TARGET_IPS <<'PY' | $KUBECTL apply -n "$NAMESPACE" -f -
import re, sys
path = sys.argv[1]
mt_ips = sys.argv[2:]
with open(path) as f:
    out = []
    for line in f.read().splitlines():
        m = re.match(r'^(\s*)<MOUNT_TARGET_BLOCK>\s*$', line)
        if m:
            indent = m.group(1)
            out.extend(f"{indent}- ipBlock: {{ cidr: {ip}/32 }}" for ip in mt_ips)
        else:
            out.append(line)
text = "\n".join(out)
text = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
sys.stdout.write(text + "\n")
PY
[[ ${PIPESTATUS[0]} -eq 0 && ${PIPESTATUS[1]} -eq 0 ]] || die "could not render or apply the egress policy"

# Wait for the PolicyEndpoint so the rule is programmed before the pods start. A timeout here
# must stop the run: starting the pods with no policy programmed would not restrict egress.
echo "  waiting for the PolicyEndpoint to be programmed..."
pe=0
for _ in $(seq 1 30); do
  n="$($KUBECTL get policyendpoints -n "$NAMESPACE" -o name 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$n" -gt 0 ]] && { pe="$n"; break; }
  sleep 2
done
[[ "$pe" -gt 0 ]] || die "no PolicyEndpoint appeared for the egress policy within the timeout; the policy is not programmed, so the pods were not started. Turn on network policy enforcement (the amazon-vpc-cni ConfigMap), as the coding agent page describes."

# The StorageClass (cluster-scoped, create only if absent; never apply over an existing one),
# then the PV, PVC, ServiceAccount and pods, rendered with the namespace and recorded IDs.
render_efs() {
  sed -e "s|<NAMESPACE>|$NAMESPACE|g" \
      -e "s|<EFS_FILE_SYSTEM_ID>|$EFS_FILE_SYSTEM_ID|g" \
      -e "s|<EFS_ACCESS_POINT_ID>|$EFS_ACCESS_POINT_ID|g" \
      "$SAMPLE_DIR/deploy/efs.yaml"
}
if ! $KUBECTL get storageclass nitro-sandbox-efs >/dev/null 2>&1; then
  render_efs | python3 -c 'import sys
docs = sys.stdin.read().split("\n---\n")
for d in docs:
    if "kind: StorageClass" in d:
        sys.stdout.write(d.strip() + "\n")' | $KUBECTL create -f -
  [[ ${PIPESTATUS[0]} -eq 0 && ${PIPESTATUS[1]} -eq 0 && ${PIPESTATUS[2]} -eq 0 ]] \
    || die "could not create the StorageClass nitro-sandbox-efs"
fi
render_efs | python3 -c 'import sys
docs = sys.stdin.read().split("\n---\n")
out = [d for d in docs if d.strip() and "kind: StorageClass" not in d]
sys.stdout.write("\n---\n".join(out))' | $KUBECTL apply -n "$NAMESPACE" -f -
[[ ${PIPESTATUS[0]} -eq 0 && ${PIPESTATUS[1]} -eq 0 && ${PIPESTATUS[2]} -eq 0 ]] \
  || die "could not render or apply the PV, PVC, ServiceAccount and pods"

echo "  waiting for both pods to become Ready (sandbox VM boot + NFS mount)..."
$KUBECTL wait -n "$NAMESPACE" --for=condition=Ready pod/efs-writer pod/efs-reader --timeout=5m \
  || die "the pods did not become Ready. Check:
  $KUBECTL describe pod efs-writer -n $NAMESPACE
  $KUBECTL logs -n kube-system daemonset/efs-csi-node -c efs-plugin --tail=100"

echo
echo "EFS storage is ready and both pods are Running. Resource IDs and addresses: $ENV_FILE"
echo "$KUBECTL get pods,pvc -n $NAMESPACE"
echo
echo "Clean: NAMESPACE=$NAMESPACE ./scripts/clean.sh                        # Kubernetes objects"
echo "       NAMESPACE=$NAMESPACE ./scripts/clean.sh --delete-aws-resources  # ...and the EFS resources"
