#!/usr/bin/env bash
# Set up the shared S3 Files sample.
#
#   CLUSTER_NAME=<cluster> AWS_REGION=<region> ./scripts/setup.sh
#
# What it does, in order:
#   1. Checks the Amazon EFS CSI driver is installed at 3.5.1 or newer, comparing every
#      component of the version and not the major alone, and stops with the install or
#      upgrade command when it is not.
#      The driver, its service accounts, their IAM roles and their Pod Identity
#      associations are a SHARED INSTALL: this sample reads them and never changes
#      them (no role created, no policy attached, no association touched). It only
#      reads which role the CSI node service account uses, so the file system policy
#      can allow that principal. The managed EC2 node instance-profile role is neither
#      read nor named: it keeps what Auto Mode ships with.
#   2. Creates the sample's own resources, each tagged ManagedBy=storage-s3-files and
#      auto-delete=no: a versioned, encrypted S3 bucket with Block Public Access and a
#      TLS-only bucket policy; a synchronization role scoped to this bucket; an S3 Files
#      file system on that bucket; an NFS security group (TCP 2049 from the cluster
#      security group only); one mount target per cluster Availability Zone; and TWO
#      access points, both fixed UID/GID 1000 and rooted at the SAME directory
#      (/storage-s3-files) so they share one dataset: a writer access point and a
#      reader access point.
#   3. Applies a file system policy that gives the SAME CSI node principal different
#      access per access point, using the s3files:AccessPointArn condition: read-write
#      through the writer access point, read-only through the reader access point (with
#      an explicit deny of ClientWrite there). For a same-account principal an Allow in
#      this resource policy is enough to authorize the mount, so nothing is added to the
#      shared CSI node role and the EC2 node role is not involved at all.
#   4. Records the resource IDs and the mount-target addresses in a local
#      env file (.env, gitignored) so test.sh can render the manifests.
#   5. Deploys the Kubernetes side: the namespace (labelled this sample's), the egress
#      ApplicationNetworkPolicy (waiting for its PolicyEndpoint), the StorageClass, the
#      two static PVs and PVCs (writer and reader), and the writer and reader pods, then
#      waits for both Ready.
#
# Idempotent: .env records what already exists, so a re-run resumes instead of creating
# a second bucket or file system, and re-applies the Kubernetes side. Tear down with
# clean.sh.
#
# The bucket is the one resource whose contents cannot be recreated, so it carries a
# stronger rule than the record: this script tags every bucket it creates with
# ManagedBy=storage-s3-files, adopts an existing bucket only when that tag matches, and
# re-checks the tag on the live bucket before deleting anything (in clean.sh).
#
# Overridable (defaults match the page):
#   NAMESPACE        the namespace to run in                 (default nitro-s3-files-sample)
#   RESOURCE_PREFIX  prefix for AWS resource names           (default storage-s3-files-<cluster>)
#   S3_BUCKET_NAME   the bucket to create                    (default derived from prefix+account+region)
#   ENV_FILE         where resource IDs are written          (default <sample>/.env)
#   KUBECTL          the kubectl command                     (default "kubectl")
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$SAMPLE_DIR/.env}"
NAMESPACE="${NAMESPACE:-nitro-s3-files-sample}"
KUBECTL="${KUBECTL:-kubectl}"

SAMPLE="storage-s3-files"
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
RESOURCE_PREFIX="${RESOURCE_PREFIX:-storage-s3-files-${CLUSTER_NAME}}"
RESOURCE_PREFIX="${RESOURCE_PREFIX:0:48}"
bucket_prefix="${RESOURCE_PREFIX:0:30}"
S3_BUCKET_NAME="${S3_BUCKET_NAME:-${bucket_prefix,,}-${ACCOUNT_ID}-${AWS_REGION}}"
S3_BUCKET_NAME="${S3_BUCKET_NAME//_/-}"

S3_FILES_FILE_SYSTEM_ID="${S3_FILES_FILE_SYSTEM_ID:-}"
S3_FILES_WRITER_AP_ID="${S3_FILES_WRITER_AP_ID:-}"
S3_FILES_READER_AP_ID="${S3_FILES_READER_AP_ID:-}"
S3_FILES_SECURITY_GROUP_ID="${S3_FILES_SECURITY_GROUP_ID:-}"
S3_FILES_CSI_NODE_ROLE_ARN="${S3_FILES_CSI_NODE_ROLE_ARN:-}"
S3_FILES_SYNC_ROLE_NAME="${S3_FILES_SYNC_ROLE_NAME:-}"
S3_FILES_SYNC_ROLE_ARN="${S3_FILES_SYNC_ROLE_ARN:-}"
CREATED_BUCKET="${CREATED_BUCKET:-false}"
CREATED_SYNC_ROLE="${CREATED_SYNC_ROLE:-false}"
CREATED_SECURITY_GROUP="${CREATED_SECURITY_GROUP:-false}"

# The access point's root directory: both access points share it, so the two pods
# see the same data. The writer access point is read-write, the reader read-only.
AP_ROOT="/storage-s3-files"

aws_r() { aws "$@" --region "$AWS_REGION"; }

# The tag that proves this sample created a bucket. It is the ONLY thing that
# authorizes clean.sh to delete one, and it is written once, at creation time.
# Ownership is never inferred from an attached S3 Files file system: S3 Files is a
# general-purpose service, so a caller may have their own file system on their own
# bucket, and treating that as proof would authorize deleting object versions this
# sample never created. (Deleting object versions is not recoverable.)
BUCKET_OWNER_TAG_KEY=ManagedBy

write_env() {
  {
    printf 'export CLUSTER_NAME=%q\n' "$CLUSTER_NAME"
    printf 'export AWS_REGION=%q\n' "$AWS_REGION"
    printf 'export NAMESPACE=%q\n' "$NAMESPACE"
    printf 'export RESOURCE_PREFIX=%q\n' "$RESOURCE_PREFIX"
    printf 'export S3_BUCKET_NAME=%q\n' "$S3_BUCKET_NAME"
    printf 'export S3_FILES_FILE_SYSTEM_ID=%q\n' "$S3_FILES_FILE_SYSTEM_ID"
    printf 'export S3_FILES_WRITER_AP_ID=%q\n' "$S3_FILES_WRITER_AP_ID"
    printf 'export S3_FILES_READER_AP_ID=%q\n' "$S3_FILES_READER_AP_ID"
    printf 'export S3_FILES_SECURITY_GROUP_ID=%q\n' "$S3_FILES_SECURITY_GROUP_ID"
    printf 'export S3_FILES_CSI_NODE_ROLE_ARN=%q\n' "$S3_FILES_CSI_NODE_ROLE_ARN"
    printf 'export S3_FILES_SYNC_ROLE_NAME=%q\n' "$S3_FILES_SYNC_ROLE_NAME"
    printf 'export S3_FILES_SYNC_ROLE_ARN=%q\n' "$S3_FILES_SYNC_ROLE_ARN"
    printf 'export CREATED_BUCKET=%q\n' "$CREATED_BUCKET"
    printf 'export CREATED_SYNC_ROLE=%q\n' "$CREATED_SYNC_ROLE"
    printf 'export CREATED_SECURITY_GROUP=%q\n' "$CREATED_SECURITY_GROUP"
    printf 'export MOUNT_TARGET_IPS=%q\n' "${MOUNT_TARGET_IPS:-}"
  } > "$ENV_FILE"
}

bucket_owner_marker() { # bucket_owner_marker <bucket>: print this sample's marker, or nothing.
  local value
  value="$(aws_r s3api get-bucket-tagging --bucket "$1" \
    --query "TagSet[?Key=='$BUCKET_OWNER_TAG_KEY'].Value | [0]" --output text 2>/dev/null || true)"
  [[ "$value" == "None" ]] && value=""
  printf '%s' "$value"
}

wait_for_s3_files() {
  local state=""
  for _ in $(seq 1 90); do
    state="$(aws_r s3files get-file-system --file-system-id "$S3_FILES_FILE_SYSTEM_ID" \
      --query 'status' --output text)"
    state="${state^^}"
    [[ "$state" == "AVAILABLE" ]] && return 0
    [[ "$state" == "ERROR" ]] && die "the S3 Files file system entered an error state"
    sleep 5
  done
  die "timed out waiting for the S3 Files file system"
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
echo "Step 1/6: check the Amazon EFS CSI driver (a shared install; reused, never changed)"
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
  die "the Amazon EFS CSI driver $MIN_DRIVER_VERSION or newer is required for S3 Files (found: ${driver_version:-no version from either the add-on or the efs-csi-node image; could not determine}).
$how
The page's prerequisites and the S3 Files CSI guide have the detail:
  https://docs.aws.amazon.com/eks/latest/userguide/s3files-csi.html"
fi
echo "  found aws-efs-csi-driver $driver_version (>= $MIN_DRIVER_VERSION)."

# Read the CSI node service account's Pod Identity role WITHOUT changing it.
node_assoc="$(aws_r eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
  --namespace kube-system --service-account efs-csi-node-sa \
  --query 'associations[0].associationId' --output text 2>/dev/null || true)"
[[ -n "$node_assoc" && "$node_assoc" != "None" ]] \
  || die "the efs-csi-node-sa service account has no EKS Pod Identity association.
S3 Files always mounts with IAM authorization, which needs the CSI node service account to
carry an identity. Configure the driver's Pod Identity roles as the page's prerequisites describe."
S3_FILES_CSI_NODE_ROLE_ARN="$(aws_r eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
  --association-id "$node_assoc" --query 'association.roleArn' --output text)"
[[ "$S3_FILES_CSI_NODE_ROLE_ARN" == arn:aws:iam::"$ACCOUNT_ID":role/* ]] \
  || die "unexpected CSI node role ARN: $S3_FILES_CSI_NODE_ROLE_ARN"
echo "  CSI node principal (read, not changed): $S3_FILES_CSI_NODE_ROLE_ARN"
# The managed Auto Mode EC2 node instance-profile role is deliberately NOT read or named:
# it must keep what it ships with, and the file system is already default-deny, authorized
# only through the sample's own per-access-point file system policy below.
write_env

# ---- 2. The sample's own AWS resources. ----
echo "Step 2/6: create the sample's bucket, synchronization role, file system, security group, mount targets and the writer and reader access points"
VPC_ID="$(aws_r eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
CLUSTER_SG="$(aws_r eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)"
read -r -a SUBNET_IDS <<<"$(aws_r eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.subnetIds' --output text)"

declare -A SUBNET_BY_AZ=()
while read -r az subnet; do
  [[ -n "$az" && -n "$subnet" ]] || continue
  [[ -n "${SUBNET_BY_AZ[$az]:-}" ]] || SUBNET_BY_AZ[$az]="$subnet"
done < <(aws_r ec2 describe-subnets --subnet-ids "${SUBNET_IDS[@]}" \
  --query 'Subnets[].[AvailabilityZoneId,SubnetId]' --output text)
[[ ${#SUBNET_BY_AZ[@]} -gt 0 ]] || die "could not discover the cluster's subnets"

# The backing bucket: versioned, encrypted, Block Public Access, TLS-only bucket policy.
if aws_r s3api head-bucket --bucket "$S3_BUCKET_NAME" >/dev/null 2>&1; then
  marker="$(bucket_owner_marker "$S3_BUCKET_NAME")"
  if [[ "$marker" == "$SAMPLE" ]]; then
    [[ "$CREATED_BUCKET" == "true" ]] || { echo "  adopting this sample's bucket $S3_BUCKET_NAME (tagged $BUCKET_OWNER_TAG_KEY=$SAMPLE)."; CREATED_BUCKET=true; write_env; }
  elif [[ -n "$marker" ]]; then
    die "bucket $S3_BUCKET_NAME is tagged $BUCKET_OWNER_TAG_KEY=$marker, not this sample's; set S3_BUCKET_NAME to a new name."
  else
    die "bucket $S3_BUCKET_NAME already exists and does not carry $BUCKET_OWNER_TAG_KEY=$SAMPLE, so this sample cannot
prove it created it and will neither reconfigure nor delete it. Set S3_BUCKET_NAME to a new name, or, if this really
is an older run's bucket, claim it explicitly:
  aws s3api put-bucket-tagging --bucket $S3_BUCKET_NAME --region $AWS_REGION --tagging 'TagSet=[{Key=$BUCKET_OWNER_TAG_KEY,Value=$SAMPLE}]'
That is a deliberate statement that clean.sh --delete-aws-resources may delete the bucket and every object version in it."
  fi
else
  echo "  creating the S3 bucket $S3_BUCKET_NAME..."
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws_r s3api create-bucket --bucket "$S3_BUCKET_NAME" >/dev/null
  else
    aws_r s3api create-bucket --bucket "$S3_BUCKET_NAME" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
  fi
  # Claim it immediately, before anything else can fail, so a run that created the bucket
  # and died does not leave an untagged bucket no later run can adopt or clean up.
  aws_r s3api put-bucket-tagging --bucket "$S3_BUCKET_NAME" \
    --tagging "TagSet=[{Key=$BUCKET_OWNER_TAG_KEY,Value=$SAMPLE},{Key=auto-delete,Value=no}]"
  CREATED_BUCKET=true
  write_env
fi
# S3 Files requires Versioning and server-side encryption; Block Public Access is good practice.
aws_r s3api put-bucket-versioning --bucket "$S3_BUCKET_NAME" \
  --versioning-configuration Status=Enabled
aws_r s3api put-bucket-encryption --bucket "$S3_BUCKET_NAME" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws_r s3api put-public-access-block --bucket "$S3_BUCKET_NAME" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
# Keep the ManagedBy/auto-delete tags fresh (idempotent) now that ownership is confirmed.
aws_r s3api put-bucket-tagging --bucket "$S3_BUCKET_NAME" \
  --tagging "TagSet=[{Key=$BUCKET_OWNER_TAG_KEY,Value=$SAMPLE},{Key=auto-delete,Value=no}]"

# The bucket policy: deny insecure transport (TLS-only).
echo "  applying the bucket policy (TLS-only)..."
bucket_policy_file="$(mktemp)"
trap 'rm -f "$bucket_policy_file" "${sync_perm_file:-}" "${sync_trust_file:-}" "${fs_policy_file:-}"' EXIT
python3 - "$SAMPLE_DIR/iam/bucket-policy.json" "arn:aws:s3:::$S3_BUCKET_NAME" > "$bucket_policy_file" <<'PY'
import json, sys
tmpl, bucket_arn = sys.argv[1:3]
with open(tmpl) as f: doc = json.load(f)
doc.pop("Comment", None)
repl = {"<S3_BUCKET_ARN>": bucket_arn}
def sub(x):
    if isinstance(x, str):
        for k, v in repl.items(): x = x.replace(k, v)
        return x
    if isinstance(x, list): return [sub(v) for v in x]
    if isinstance(x, dict): return {k: sub(v) for k, v in x.items()}
    return x
json.dump(sub(doc), sys.stdout, indent=2)
PY
aws_r s3api put-bucket-policy --bucket "$S3_BUCKET_NAME" --policy "file://$bucket_policy_file" >/dev/null

# The synchronization role: create (trust wide at first), attach scoped permissions.
if [[ -z "$S3_FILES_SYNC_ROLE_ARN" ]]; then
  S3_FILES_SYNC_ROLE_NAME="${S3_FILES_SYNC_ROLE_NAME:-${RESOURCE_PREFIX}-sync}"
  S3_FILES_SYNC_ROLE_NAME="${S3_FILES_SYNC_ROLE_NAME:0:64}"
  S3_FILES_SYNC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${S3_FILES_SYNC_ROLE_NAME}"
  sync_trust_file="$(mktemp)"
  python3 - "$SAMPLE_DIR/iam/sync-role-trust.json" "$ACCOUNT_ID" "arn:aws:s3files:$AWS_REGION:$ACCOUNT_ID:file-system/*" > "$sync_trust_file" <<'PY'
import json, sys
tmpl, account, src_arn = sys.argv[1:4]
with open(tmpl) as f: doc = json.load(f)
doc.pop("Comment", None)
repl = {"<ACCOUNT_ID>": account, "<S3_FILES_FILE_SYSTEM_ARN>": src_arn}
def sub(x):
    if isinstance(x, str):
        for k, v in repl.items(): x = x.replace(k, v)
        return x
    if isinstance(x, list): return [sub(v) for v in x]
    if isinstance(x, dict): return {k: sub(v) for k, v in x.items()}
    return x
json.dump(sub(doc), sys.stdout, indent=2)
PY
  if aws_r iam get-role --role-name "$S3_FILES_SYNC_ROLE_NAME" >/dev/null 2>&1; then
    # Adopt an earlier run's role only on the evidence this sample made it: its inline policy.
    aws_r iam get-role-policy --role-name "$S3_FILES_SYNC_ROLE_NAME" --policy-name S3FilesSync >/dev/null 2>&1 \
      || die "IAM role $S3_FILES_SYNC_ROLE_NAME already exists and is not this sample's; choose another RESOURCE_PREFIX."
    echo "  adopting the synchronization role from a previous run: $S3_FILES_SYNC_ROLE_NAME"
  else
    echo "  creating the synchronization role $S3_FILES_SYNC_ROLE_NAME..."
    aws_r iam create-role --role-name "$S3_FILES_SYNC_ROLE_NAME" \
      --assume-role-policy-document "file://$sync_trust_file" \
      --tags Key=ManagedBy,Value=$SAMPLE Key=auto-delete,Value=no >/dev/null
  fi
  CREATED_SYNC_ROLE=true
  sync_perm_file="$(mktemp)"
  python3 - "$SAMPLE_DIR/iam/sync-role-permissions.json" "arn:aws:s3:::$S3_BUCKET_NAME" "$ACCOUNT_ID" > "$sync_perm_file" <<'PY'
import json, sys
tmpl, bucket_arn, account = sys.argv[1:4]
with open(tmpl) as f: doc = json.load(f)
doc.pop("Comment", None)
repl = {"<S3_BUCKET_ARN>": bucket_arn, "<ACCOUNT_ID>": account}
def sub(x):
    if isinstance(x, str):
        for k, v in repl.items(): x = x.replace(k, v)
        return x
    if isinstance(x, list): return [sub(v) for v in x]
    if isinstance(x, dict): return {k: sub(v) for k, v in x.items()}
    return x
json.dump(sub(doc), sys.stdout, indent=2)
PY
  aws_r iam put-role-policy --role-name "$S3_FILES_SYNC_ROLE_NAME" \
    --policy-name S3FilesSync --policy-document "file://$sync_perm_file"
  write_env
fi

# The S3 Files file system on the bucket, created with the synchronization role.
if [[ -z "$S3_FILES_FILE_SYSTEM_ID" || "$S3_FILES_FILE_SYSTEM_ID" == "None" ]]; then
  # Resume without .env: find a file system already attached to this (owned) bucket.
  if [[ "$CREATED_BUCKET" == "true" ]]; then
    S3_FILES_FILE_SYSTEM_ID="$(aws_r s3files list-file-systems \
      --query "fileSystems[?bucket=='arn:aws:s3:::$S3_BUCKET_NAME' && status!='deleted'].fileSystemId | [0]" \
      --output text 2>/dev/null || true)"
    [[ "$S3_FILES_FILE_SYSTEM_ID" == "None" ]] && S3_FILES_FILE_SYSTEM_ID=""
  fi
  if [[ -n "$S3_FILES_FILE_SYSTEM_ID" ]]; then
    echo "  adopting the S3 Files file system from a previous run: $S3_FILES_FILE_SYSTEM_ID"
  else
    echo "  creating the S3 Files file system on $S3_BUCKET_NAME..."
    client_token="${RESOURCE_PREFIX}-$(date +%s)"; client_token="${client_token:0:64}"
    S3_FILES_FILE_SYSTEM_ID="$(aws_r s3files create-file-system \
      --bucket "arn:aws:s3:::$S3_BUCKET_NAME" --role-arn "$S3_FILES_SYNC_ROLE_ARN" \
      --client-token "$client_token" --query fileSystemId --output text)"
  fi
  write_env
fi
wait_for_s3_files
# Prove the file system is this sample's before mutating it (applying its policy, narrowing the
# role trust) or, later, letting clean.sh delete it. Its identity is the bucket it is attached
# to: that bucket is already proven this sample's by the ManagedBy tag gate above, so a file
# system whose `bucket` is that bucket is this sample's too. A file system ID loaded from a
# stale .env that points at another bucket is refused here rather than adopted. A read that
# fails is fatal (could not determine ownership), never treated as owned.
fs_bucket="$(aws_r s3files get-file-system --file-system-id "$S3_FILES_FILE_SYSTEM_ID" \
  --query 'bucket' --output text 2>/dev/null)" \
  || die "could not read the S3 Files file system $S3_FILES_FILE_SYSTEM_ID to verify it is this sample's; refusing to use it until the read succeeds."
[[ "$fs_bucket" == "arn:aws:s3:::$S3_BUCKET_NAME" ]] \
  || die "the S3 Files file system $S3_FILES_FILE_SYSTEM_ID is attached to '$fs_bucket', not this sample's bucket arn:aws:s3:::$S3_BUCKET_NAME; refusing to adopt a file system this sample did not create. Run './scripts/clean.sh --delete-aws-resources' to clear a stale .env, or set ENV_FILE to a different file."
S3_FILES_ARN="arn:aws:s3files:$AWS_REGION:$ACCOUNT_ID:file-system/$S3_FILES_FILE_SYSTEM_ID"

# Narrow the synchronization role's trust to exactly this file system.
sync_trust_narrow="$(mktemp)"
python3 - "$SAMPLE_DIR/iam/sync-role-trust.json" "$ACCOUNT_ID" "$S3_FILES_ARN" > "$sync_trust_narrow" <<'PY'
import json, sys
tmpl, account, fs_arn = sys.argv[1:4]
with open(tmpl) as f: doc = json.load(f)
doc.pop("Comment", None)
repl = {"<ACCOUNT_ID>": account, "<S3_FILES_FILE_SYSTEM_ARN>": fs_arn}
def sub(x):
    if isinstance(x, str):
        for k, v in repl.items(): x = x.replace(k, v)
        return x
    if isinstance(x, list): return [sub(v) for v in x]
    if isinstance(x, dict): return {k: sub(v) for k, v in x.items()}
    return x
json.dump(sub(doc), sys.stdout, indent=2)
PY
aws_r iam update-assume-role-policy --role-name "$S3_FILES_SYNC_ROLE_NAME" \
  --policy-document "file://$sync_trust_narrow"
rm -f "$sync_trust_narrow"

# Security group: NFS 2049 from the cluster security group only.
if [[ -z "$S3_FILES_SECURITY_GROUP_ID" || "$S3_FILES_SECURITY_GROUP_ID" == "None" ]]; then
  sg_name="${RESOURCE_PREFIX}-nfs"
  S3_FILES_SECURITY_GROUP_ID="$(aws_r ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$sg_name" \
    --query 'SecurityGroups[0].GroupId' --output text)"
  if [[ "$S3_FILES_SECURITY_GROUP_ID" == "None" ]]; then
    S3_FILES_SECURITY_GROUP_ID="$(aws_r ec2 create-security-group --group-name "$sg_name" \
      --description "NFS from the EKS cluster security group for the storage-s3-files sample" \
      --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$sg_name},{Key=ManagedBy,Value=$SAMPLE},{Key=auto-delete,Value=no}]" \
      --query GroupId --output text)"
    aws_r ec2 authorize-security-group-ingress --group-id "$S3_FILES_SECURITY_GROUP_ID" \
      --protocol tcp --port 2049 --source-group "$CLUSTER_SG" >/dev/null
    CREATED_SECURITY_GROUP=true
    echo "  created NFS security group $S3_FILES_SECURITY_GROUP_ID (TCP 2049 from $CLUSTER_SG only)."
  else
    sg_owner="$(aws_r ec2 describe-security-groups --group-ids "$S3_FILES_SECURITY_GROUP_ID" \
      --query "SecurityGroups[0].Tags[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null)" \
      || die "could not read the ownership tags of security group $S3_FILES_SECURITY_GROUP_ID; refusing to adopt it."
    [[ "$sg_owner" == "$SAMPLE" ]] \
      || die "a security group named '$sg_name' already exists in $VPC_ID but is not tagged ManagedBy=$SAMPLE (found '${sg_owner:-<none>}'); refusing to adopt it. Use a different RESOURCE_PREFIX, or remove the conflicting group if it is yours."
    CREATED_SECURITY_GROUP=true
    echo "  reusing this sample's NFS security group $S3_FILES_SECURITY_GROUP_ID."
  fi
  write_env
fi

echo "  ensuring one S3 Files mount target per cluster Availability Zone..."
for az in "${!SUBNET_BY_AZ[@]}"; do
  existing="$(aws_r s3files list-mount-targets --file-system-id "$S3_FILES_FILE_SYSTEM_ID" \
    --query "mountTargets[?availabilityZoneId=='$az' && status!='deleted'].mountTargetId | [0]" --output text 2>/dev/null || echo None)"
  if [[ "$existing" == "None" || -z "$existing" ]]; then
    aws_r s3files create-mount-target --file-system-id "$S3_FILES_FILE_SYSTEM_ID" \
      --subnet-id "${SUBNET_BY_AZ[$az]}" --security-groups "$S3_FILES_SECURITY_GROUP_ID" >/dev/null
  fi
done
for _ in $(seq 1 90); do
  statuses="$(aws_r s3files list-mount-targets --file-system-id "$S3_FILES_FILE_SYSTEM_ID" \
    --query 'mountTargets[].status' --output text 2>/dev/null || true)"
  pending=0; count=0
  for st in $statuses; do
    [[ "$st" == "None" ]] && continue
    count=$((count+1)); [[ "${st^^}" == "AVAILABLE" ]] || pending=$((pending+1))
  done
  [[ "$pending" == 0 && "$count" -eq "${#SUBNET_BY_AZ[@]}" ]] && break
  sleep 5
done
[[ "$pending" == 0 && "$count" -eq "${#SUBNET_BY_AZ[@]}" ]] || die "timed out waiting for the S3 Files mount targets"

# Two access points, both fixed UID/GID 1000 and rooted at the SAME directory ($AP_ROOT), so
# they expose one shared dataset; the file system policy makes one read-write and one read-only.
# ensure_access_point <name-suffix> <current-id-var>: adopt the sample's AP by Name tag if it
# exists on this file system, else create it; then wait for it AVAILABLE and verify it is on
# this sample's file system. Echoes the (possibly new) access point ID.
ensure_access_point() {
  local suffix="$1" apid="$2" ap_name="${RESOURCE_PREFIX}-${1}"
  if [[ -z "$apid" || "$apid" == "None" ]]; then
    apid="$(aws_r s3files list-access-points --file-system-id "$S3_FILES_FILE_SYSTEM_ID" \
      --query "accessPoints[?name=='$ap_name' && status!='deleted'].accessPointId | [0]" --output text 2>/dev/null || true)"
    [[ "$apid" == "None" ]] && apid=""
    if [[ -n "$apid" ]]; then
      echo "  adopting the $suffix access point from a previous run: $apid" >&2
    else
      echo "  creating the $suffix access point (uid/gid 1000, root $AP_ROOT)..." >&2
      local ap_input; ap_input="$(mktemp)"
      cat > "$ap_input" <<JSON
{
  "clientToken": "${RESOURCE_PREFIX:0:40}-${suffix}",
  "fileSystemId": "$S3_FILES_FILE_SYSTEM_ID",
  "tags": [
    { "key": "Name", "value": "$ap_name" },
    { "key": "ManagedBy", "value": "$SAMPLE" },
    { "key": "auto-delete", "value": "no" }
  ],
  "posixUser": { "uid": 1000, "gid": 1000 },
  "rootDirectory": {
    "path": "$AP_ROOT",
    "creationPermissions": { "ownerUid": 1000, "ownerGid": 1000, "permissions": "0770" }
  }
}
JSON
      apid="$(aws_r s3files create-access-point --cli-input-json "file://$ap_input" --query accessPointId --output text)"
      rm -f "$ap_input"
    fi
  fi
  local st
  for _ in $(seq 1 60); do
    st="$(aws_r s3files get-access-point --access-point-id "$apid" --query status --output text 2>/dev/null)"; st="${st^^}"
    [[ "$st" == "AVAILABLE" ]] && break
    [[ "$st" == "ERROR" ]] && die "the $suffix access point entered an error state"
    sleep 5
  done
  [[ "$st" == "AVAILABLE" ]] || die "timed out waiting for the $suffix access point"
  # Prove the access point is THIS sample's before using it. A stale .env or a Name-tag clash on
  # a shared file system could hand us an access point we did not create, or one rooted somewhere
  # else, so check every value the sample fixes, not just the file system:
  #   - it is on this sample's file system;
  #   - its real ARN, which S3 Files forms as .../file-system/<fs>/access-point/<ap> (NOT a bare
  #     .../access-point/<ap>): the file system policy's s3files:AccessPointArn condition must use
  #     that exact ARN or the mount is denied;
  #   - it is tagged ManagedBy=<sample> and Name=<this sample's AP name>;
  #   - it is rooted at $AP_ROOT with posix uid/gid 1000 (so both access points share one dataset
  #     and the writer's non-root process can write it).
  # A failed read, or any mismatch, is fatal: refuse to adopt rather than reuse the wrong one.
  # get-access-point returns fileSystemId, accessPointArn, rootDirectory, posixUser and tags in
  # one document, so read it as JSON and check every field with python (robust to tag order and
  # to --output text splitting on tab). The expected ManagedBy tag, Name tag, root and uid/gid
  # are passed in the environment; a parse failure or any mismatch exits non-zero, which the
  # `|| die` below turns into a refusal.
  local ap_json ap_arn
  ap_json="$(aws_r s3files get-access-point --access-point-id "$apid" --output json 2>/dev/null)" \
    || die "could not read the $suffix access point $apid to verify it is this sample's; refusing to use it until the read succeeds."
  ap_arn="$(printf '%s' "$ap_json" | AP_ID="$apid" WANT_FS="$S3_FILES_FILE_SYSTEM_ID" \
    WANT_ROOT="$AP_ROOT" WANT_NAME="$ap_name" WANT_MANAGED="$SAMPLE" python3 -c '
import json, os, sys
try:
    ap = json.load(sys.stdin)
except Exception:
    sys.exit(1)
apid = os.environ["AP_ID"]
if ap.get("fileSystemId") != os.environ["WANT_FS"]: sys.exit(1)
arn = ap.get("accessPointArn")
if not arn or arn == "None": sys.exit(1)
if (ap.get("rootDirectory") or {}).get("path") != os.environ["WANT_ROOT"]: sys.exit(1)
pu = ap.get("posixUser") or {}
if pu.get("uid") != 1000 or pu.get("gid") != 1000: sys.exit(1)
tags = {t.get("key"): t.get("value") for t in (ap.get("tags") or [])}
if tags.get("ManagedBy") != os.environ["WANT_MANAGED"]: sys.exit(1)
if tags.get("Name") != os.environ["WANT_NAME"]: sys.exit(1)
sys.stdout.write(arn)
')" || die "the $suffix access point $apid does not match this sample's expected file system, root ($AP_ROOT), uid/gid 1000, ManagedBy=$SAMPLE tag and Name=$ap_name tag; refusing to adopt an access point this sample did not create. Clear a stale .env with './scripts/clean.sh --delete-aws-resources', or set ENV_FILE to a different file."
  [[ -n "$ap_arn" ]] || die "could not read the ARN of the $suffix access point $apid."
  # Echo "<id> <arn>" so the caller gets both.
  printf '%s %s' "$apid" "$ap_arn"
}

writer_ap_out="$(ensure_access_point writer-ap "$S3_FILES_WRITER_AP_ID")" || die "could not ensure the writer access point"
read -r S3_FILES_WRITER_AP_ID WRITER_AP_ARN <<<"$writer_ap_out"
write_env
reader_ap_out="$(ensure_access_point reader-ap "$S3_FILES_READER_AP_ID")" || die "could not ensure the reader access point"
read -r S3_FILES_READER_AP_ID READER_AP_ARN <<<"$reader_ap_out"
write_env
# The read/write split depends on the two access points being DIFFERENT: if a stale .env named
# the same access point for both, the reader's ClientWrite Deny would also match the writer ARN
# and break the split. Refuse to continue unless both IDs and both ARNs are set and distinct.
[[ -n "$S3_FILES_WRITER_AP_ID" && -n "$S3_FILES_READER_AP_ID" && -n "$WRITER_AP_ARN" && -n "$READER_AP_ARN" ]] \
  || die "a writer or reader access point id/ARN is empty; refusing to apply a file system policy that cannot enforce the split."
[[ "$S3_FILES_WRITER_AP_ID" != "$S3_FILES_READER_AP_ID" && "$WRITER_AP_ARN" != "$READER_AP_ARN" ]] \
  || die "the writer and reader access points resolved to the same access point ($S3_FILES_WRITER_AP_ID); the read/write split needs two distinct access points. Clear a stale .env with './scripts/clean.sh --delete-aws-resources'."

# ---- 3. The file system policy: read-write via the writer AP, read-only via the reader AP. ----
echo "Step 3/6: apply the S3 Files file system policy (writer AP read-write, reader AP read-only, by s3files:AccessPointArn)"
fs_policy_file="$(mktemp)"
python3 - "$SAMPLE_DIR/iam/file-system-policy.json" "$S3_FILES_ARN" "$S3_FILES_CSI_NODE_ROLE_ARN" "$WRITER_AP_ARN" "$READER_AP_ARN" > "$fs_policy_file" <<'PY'
import json, sys
tmpl, fs_arn, node_role, writer_ap_arn, reader_ap_arn = sys.argv[1:6]
with open(tmpl) as f: doc = json.load(f)
doc.pop("Comment", None)
repl = {"<S3_FILES_FILE_SYSTEM_ARN>": fs_arn, "<S3_FILES_CSI_NODE_ROLE_ARN>": node_role,
        "<S3_FILES_WRITER_AP_ARN>": writer_ap_arn, "<S3_FILES_READER_AP_ARN>": reader_ap_arn}
def sub(x):
    if isinstance(x, str):
        for k, v in repl.items(): x = x.replace(k, v)
        return x
    if isinstance(x, list): return [sub(v) for v in x]
    if isinstance(x, dict): return {k: sub(v) for k, v in x.items()}
    return x
json.dump(sub(doc), sys.stdout, indent=2)
PY
aws_r s3files put-file-system-policy --file-system-id "$S3_FILES_FILE_SYSTEM_ID" \
  --policy "file://$fs_policy_file" >/dev/null
echo "  file system policy applied."

# ---- 4. Record the addresses the network policy needs. ----
echo "Step 4/6: record the mount-target addresses for the network policy"
# DNS egress is allowed to any address (the policy opens only port 53), because on EKS Auto
# Mode CoreDNS runs as a per-node systemd service rather than a pod behind a ClusterIP, so the
# resolver a pod reaches is node-local. Only the mount-target IPs need recording.
MOUNT_TARGET_IPS="$(aws_r s3files list-mount-targets --file-system-id "$S3_FILES_FILE_SYSTEM_ID" \
  --query 'mountTargets[].ipv4Address' --output text | tr '\t' ' ')"
[[ -n "$MOUNT_TARGET_IPS" ]] || die "could not read the mount-target IP addresses"
write_env
echo "  mount targets: $MOUNT_TARGET_IPS"

# ---- 5. Deploy: the namespace, the egress policy, the StorageClass, the PV/PVC and the pods. ----
echo "Step 5/6: deploy the egress policy and the two sandbox pods"
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

# The egress policy: render deploy/egress-policy.yaml so the file the page shows is the file
# that is applied. The DNS rule is already a literal 0.0.0.0/0 in the file (DNS is allowed to
# any address), so the only thing to render is <MOUNT_TARGET_BLOCK>, expanded into one
# `- ipBlock: { cidr: <ip>/32 }` line per mount-target IP, preserving indentation.
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

echo "  waiting for the PolicyEndpoint to be programmed..."
pe=0
for _ in $(seq 1 30); do
  n="$($KUBECTL get policyendpoints -n "$NAMESPACE" -o name 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$n" -gt 0 ]] && { pe="$n"; break; }
  sleep 2
done
[[ "$pe" -gt 0 ]] || die "no PolicyEndpoint appeared for the egress policy within the timeout; the policy is not programmed, so the pods were not started. Turn on network policy enforcement (the amazon-vpc-cni ConfigMap), as the coding agent page describes."

render_manifests() {
  sed -e "s|<NAMESPACE>|$NAMESPACE|g" \
      -e "s|<S3_FILES_FILE_SYSTEM_ID>|$S3_FILES_FILE_SYSTEM_ID|g" \
      -e "s|<S3_FILES_WRITER_AP_ID>|$S3_FILES_WRITER_AP_ID|g" \
      -e "s|<S3_FILES_READER_AP_ID>|$S3_FILES_READER_AP_ID|g" \
      "$SAMPLE_DIR/deploy/s3-files.yaml"
}
if ! $KUBECTL get storageclass nitro-sandbox-s3-files >/dev/null 2>&1; then
  render_manifests | python3 -c 'import sys
docs = sys.stdin.read().split("\n---\n")
for d in docs:
    if "kind: StorageClass" in d:
        sys.stdout.write(d.strip() + "\n")' | $KUBECTL create -f -
  [[ ${PIPESTATUS[0]} -eq 0 && ${PIPESTATUS[1]} -eq 0 && ${PIPESTATUS[2]} -eq 0 ]] \
    || die "could not create the StorageClass nitro-sandbox-s3-files"
fi
render_manifests | python3 -c 'import sys
docs = sys.stdin.read().split("\n---\n")
out = [d for d in docs if d.strip() and "kind: StorageClass" not in d]
sys.stdout.write("\n---\n".join(out))' | $KUBECTL apply -n "$NAMESPACE" -f -
[[ ${PIPESTATUS[0]} -eq 0 && ${PIPESTATUS[1]} -eq 0 && ${PIPESTATUS[2]} -eq 0 ]] \
  || die "could not render or apply the PV, PVC, ServiceAccount and pods"

echo "Step 6/6: wait for both pods to become Ready (sandbox VM boot + NFS mount)"
$KUBECTL wait -n "$NAMESPACE" --for=condition=Ready pod/s3-files-writer pod/s3-files-reader --timeout=15m \
  || die "the pods did not become Ready. Check:
  $KUBECTL describe pod s3-files-writer -n $NAMESPACE
  $KUBECTL logs -n kube-system daemonset/efs-csi-node -c efs-plugin --tail=100"

echo
echo "S3 Files storage is ready and both pods are Running. Resource IDs and addresses: $ENV_FILE"
echo "$KUBECTL get pods,pvc -n $NAMESPACE"
echo
echo "Clean: NAMESPACE=$NAMESPACE ./scripts/clean.sh                        # Kubernetes objects"
echo "       NAMESPACE=$NAMESPACE ./scripts/clean.sh --delete-aws-resources  # ...and the S3 Files resources + bucket"
