#!/usr/bin/env bash
# 10-build-ami-packer.sh: build the AL2023 Nitro Sandbox node AMI with the UPSTREAM
# amazon-eks-ami packer flow. This blueprint does NOT reimplement the install; it drives
# `make os_distro=al2023 enable_pod_isolation=true`, which installs the runtime and guest
# image from the public EKS S3 bundle, Firecracker >= v1.18.0, asserts the AL2023 kernel
# (>= 1:6.18.51), reserves nitro_enclaves.mempool=95%-1G, registers the isolated-sandbox and
# confidential-sandbox containerd handlers, the CRI proxy and the eks.amazonaws.com/nitro-sandbox
# node label, and names the AMI with a -pod-isolation suffix.
#
#   RUN_ID=<id> scripts/10-build-ami-packer.sh
#
# Clones amazon-eks-ami at EKS_AMI_REF under tmp/, runs the build on an enclave-capable
# instance type, records the resulting AMI id in the run evidence, and prints it.
#
# On EKS_AMI_REF >= v20261112 the packer template sets EnclaveOptions on the builder itself
# (enable_nitro_enclave = var.enable_pod_isolation == "true"), so you only need an
# enclave-CAPABLE instance type (the Makefile default m5/m6g.xlarge is NOT enclave-capable,
# so BUILD_INSTANCE_TYPE must name one, e.g. m8i.4xlarge). Re-verify this against the exact
# ref you pin: on some earlier commits the attribute was absent and the builder had to be
# made enclave-enabled another way.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
require_run_id
IDENTITY_MAY_BE_NEW="RESOURCE_PREFIX CLUSTER_NAME NAMESPACE" require_identity AWS_REGION RESOURCE_PREFIX CLUSTER_NAME NAMESPACE
require_supported_k8s
: "${EKS_AMI_REF:?set EKS_AMI_REF to the amazon-eks-ami tag/commit to build from (>= v20261112 for pod isolation)}"
: "${BUILD_SUBNET_ID:?set BUILD_SUBNET_ID to a subnet in an AZ with enclave-capable capacity}"
case "$NODE_ARCH" in amd64) : "${BUILD_INSTANCE_TYPE:=m8i.4xlarge}" ;; arm64) : "${BUILD_INSTANCE_TYPE:=m8g.4xlarge}" ;; esac
arch_matches_type "$BUILD_INSTANCE_TYPE" || die "BUILD_INSTANCE_TYPE '$BUILD_INSTANCE_TYPE' is not a $NODE_ARCH instance type; the AMI's architecture follows the builder"
# Optional: the upstream build reads the public bundle unsigned when the builder has no profile.
: "${BUILD_IAM_INSTANCE_PROFILE:=}"
: "${POD_ISOLATION_FIRECRACKER_VERSION:=latest}"

mkdir -p "$EVIDENCE_DIR"
checkout="$RUN_BASE_DIR/amazon-eks-ami"
if [ ! -d "$checkout/.git" ]; then
  log "cloning amazon-eks-ami@$EKS_AMI_REF into $checkout"
  git clone --depth 1 --branch "$EKS_AMI_REF" https://github.com/awslabs/amazon-eks-ami.git "$checkout" \
    || die "clone of amazon-eks-ami@$EKS_AMI_REF failed; is the ref a tag/branch? (a bare commit needs a full clone)"
fi
built_ref=$(git -C "$checkout" rev-parse HEAD) || die "could not read the commit of the checkout $checkout"
# The checkout is reused across runs; building from it is only right if it is the requested ref.
want_ref=$(git -C "$checkout" rev-parse --verify --quiet "refs/tags/$EKS_AMI_REF^{commit}" 2>/dev/null \
  || git -C "$checkout" rev-parse --verify --quiet "$EKS_AMI_REF^{commit}" 2>/dev/null || true)
[ -n "$want_ref" ] && [ "$want_ref" = "$built_ref" ] \
  || die "the checkout $checkout is at $built_ref, not $EKS_AMI_REF${want_ref:+ ($want_ref)}; remove that directory so the next run clones $EKS_AMI_REF"
log "building from amazon-eks-ami $EKS_AMI_REF ($built_ref)"

# Record whether this ref auto-enables enclaves on the builder, so the evidence says which case this run is.
if grep -rq 'enable_nitro_enclave' "$checkout/templates/al2023/template.pkr.hcl" 2>/dev/null; then
  printf 'BUILDER_ENCLAVE=template-auto (enable_nitro_enclave present in template.pkr.hcl)\n' >> "$EVIDENCE_DIR/run-evidence.env"
  log "this ref enables enclaves on the builder via the packer template"
else
  printf 'BUILDER_ENCLAVE=operator-must-ensure (no enable_nitro_enclave in template.pkr.hcl)\n' >> "$EVIDENCE_DIR/run-evidence.env"
  warn "this ref does NOT auto-enable enclaves on the builder; ensure the build instance has EnclaveOptions.Enabled=true"
fi

build_log="$LOG_DIR/build-$RUN_ID.log"
# The checkout is reused, so a manifest from an earlier build must not be mistaken for this one's.
rm -f "$checkout/manifest.json" || die "could not remove the old $checkout/manifest.json"
log "running packer build (log: $build_log); this takes ~20-30 min"
set +e
( cd "$checkout" && make k8s="$KUBERNETES_VERSION" os_distro=al2023 enable_pod_isolation=true \
    aws_region="$AWS_REGION" instance_type="$BUILD_INSTANCE_TYPE" \
    subnet_id="$BUILD_SUBNET_ID" ${BUILD_IAM_INSTANCE_PROFILE:+iam_instance_profile="$BUILD_IAM_INSTANCE_PROFILE"} \
    pod_isolation_firecracker_version="$POD_ISOLATION_FIRECRACKER_VERSION" \
) > "$build_log" 2>&1
rc=$?
set -e
if [ "$rc" != 0 ]; then
  echo "--- last 30 lines of $build_log ---" >&2
  tail -n 30 "$build_log" >&2
  die "packer build failed (rc=$rc); see $build_log"
fi

# The AMI id is in the packer manifest this build wrote (artifact_id is "<region>:<ami>"). There
# is no fallback to the build log: a token in a log is not proof the build made that image.
[ -f "$checkout/manifest.json" ] || die "the build finished but wrote no $checkout/manifest.json; not guessing an AMI from the log"
ami_id=$(AMI_MANIFEST="$checkout/manifest.json" AMI_REGION="$AWS_REGION" python3 "$HERE/lib/read_manifest_ami.py") \
  || die "could not read an AMI for $AWS_REGION from $checkout/manifest.json"
[[ "$ami_id" =~ ^ami-[0-9a-f]+$ ]] || die "the manifest names '$ami_id' for $AWS_REGION, which is not an AMI id"
# Check the image is this build's before the run records it or tags it: in this account, built
# with pod isolation, and of NODE_ARCH's architecture.
img=$(aws ec2 describe-images --region "$AWS_REGION" --owners self --image-ids "$ami_id" \
      --query 'Images[0].[Name,Architecture]' --output text) \
  || die "could not read the built image $ami_id in $AWS_REGION; not recording or tagging it"
read -r ami_name ami_arch <<<"$img"
case "$ami_name" in *-pod-isolation*) ;; *) die "AMI $ami_id is named '$ami_name', without -pod-isolation; the build did not use enable_pod_isolation=true. Not recording or tagging it." ;; esac
case "$NODE_ARCH:$ami_arch" in amd64:x86_64|arm64:arm64) ;; *) die "AMI $ami_id is $ami_arch but NODE_ARCH=$NODE_ARCH; the AMI's architecture follows the builder. Not recording or tagging it." ;; esac
# Record the AMI now, before any tagging, so clean.sh can find it even if a later step fails.
printf 'AMI_ID=%s\n' "$ami_id" >> "$RUN_STATE_DIR/run-state.env"

aws ec2 create-tags --region "$AWS_REGION" --resources "$ami_id" \
  --tags "Key=$TAGS_OWNER_KEY,Value=$TAGS_OWNER_VALUE" "Key=$TAGS_RUN_KEY,Value=$RUN_ID" "Key=auto-delete,Value=no"
# The AMI's snapshots carry the same mark, because clean.sh checks each snapshot's own tags.
snap_ids=$(aws ec2 describe-images --region "$AWS_REGION" --image-ids "$ami_id" \
  --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text) || die "could not read the snapshots of $ami_id"
for snap in $snap_ids; do
  [ "$snap" = None ] && continue
  [[ "$snap" =~ ^snap-[0-9a-f]+$ ]] || die "AMI $ami_id lists '$snap', which is not a snapshot id"
  printf 'SNAPSHOT_ID=%s\n' "$snap" >> "$RUN_STATE_DIR/run-state.env"   # before tagging, for clean.sh
done
for snap in $snap_ids; do
  [ "$snap" = None ] && continue
  aws ec2 create-tags --region "$AWS_REGION" --resources "$snap" \
    --tags "Key=$TAGS_OWNER_KEY,Value=$TAGS_OWNER_VALUE" "Key=$TAGS_RUN_KEY,Value=$RUN_ID" "Key=auto-delete,Value=no"
done

printf 'AMI_ID=%s\n' "$ami_id" >> "$EVIDENCE_DIR/run-evidence.env"
printf 'AMI_NAME=%s\n' "$ami_name" >> "$EVIDENCE_DIR/run-evidence.env"
printf 'AMI_SOURCE_REF=%s (%s)\n' "$EKS_AMI_REF" "$built_ref" >> "$EVIDENCE_DIR/run-evidence.env"
log "built AMI: $ami_id ($ami_name)"
printf '%s\n' "$ami_id"
