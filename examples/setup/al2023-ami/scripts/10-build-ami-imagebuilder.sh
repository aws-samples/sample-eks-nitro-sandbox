#!/usr/bin/env bash
# 10-build-ami-imagebuilder.sh: build the AL2023 Nitro Sandbox node AMI with EC2 Image Builder.
#
# This is an OPTIONAL alternative to the Packer build (10-build-ami-packer.sh). It drives the EC2
# Image Builder pipeline via the aws imagebuilder CLI to produce the same AL2023 -pod-isolation
# AMI. The install steps are defined in the AWSTOE component (deploy/imagebuilder/component.yaml),
# which mirrors the upstream amazon-eks-ami install-pod-isolation.sh provisioner.
#
#   RUN_ID=<id> scripts/10-build-ami-imagebuilder.sh
#
# NOT RUN LIVE: unlike the Packer path, this script has not been run end to end. The page says so.
#
# CAVEAT: EC2 Image Builder's CreateInfrastructureConfiguration and InstanceConfiguration APIs
# have NO enclave field (verified against the API docs). The ONLY way to get an enclave-enabled
# build instance is the parentInstance-from-ASG path: an Auto Scaling group whose launch template
# sets EnclaveOptions.Enabled=true. This applies to the BUILD phase only. The resulting AMI is
# enclave-capable when consumed by a node group or Karpenter EC2NodeClass that sets
# EnclaveOptions.Enabled=true on its own launch template.
#
# See:
# - https://docs.aws.amazon.com/imagebuilder/latest/userguide/manage-infra-config.html
# - https://docs.aws.amazon.com/imagebuilder/latest/APIReference/API_CreateInfrastructureConfiguration.html
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
require_run_id

: "${BUILD_SUBNET_ID:?set BUILD_SUBNET_ID to a PRIVATE subnet in an AZ with enclave-capable capacity}"
: "${BUILD_INSTANCE_PROFILE:?set BUILD_INSTANCE_PROFILE to an IAM instance profile (SSM + S3 read access)}"
: "${BUILD_SECURITY_GROUP_ID:?set BUILD_SECURITY_GROUP_ID to a security group for the build instance}"
: "${BUILD_ASG_NAME:?set BUILD_ASG_NAME to an Auto Scaling group with EnclaveOptions.Enabled=true on its launch template}"
: "${BUILD_S3_BUCKET:?set BUILD_S3_BUCKET to an S3 bucket for Image Builder logs}"
: "${BUILD_EXECUTION_ROLE:?set BUILD_EXECUTION_ROLE to the execution role ARN for ASG management (imagebuilder.amazonaws.com trust + EC2ImageBuilderExecutionPolicy + ASG permissions)}"
: "${POD_ISOLATION_FIRECRACKER_VERSION:=latest}"
: "${BUILD_SNS_TOPIC_ARN:=}"  # Optional

: "${KUBERNETES_BUILD_DATE:?set KUBERNETES_BUILD_DATE to the amazon-eks bundle build date for KUBERNETES_VERSION (the s3://amazon-eks/<version>/<build date> folder)}"

# These values are substituted into the component's shell commands, so accept only plain values.
[[ "$KUBERNETES_VERSION" =~ ^1\.[0-9]{2}$ ]] || die "KUBERNETES_VERSION '$KUBERNETES_VERSION' must look like 1.36"
[[ "$KUBERNETES_BUILD_DATE" =~ ^[0-9A-Za-z._-]{1,32}$ ]] || die "KUBERNETES_BUILD_DATE '$KUBERNETES_BUILD_DATE' has characters outside [0-9A-Za-z._-]"
[[ "$POD_ISOLATION_FIRECRACKER_VERSION" =~ ^(latest|v[0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "POD_ISOLATION_FIRECRACKER_VERSION '$POD_ISOLATION_FIRECRACKER_VERSION' must be 'latest' or look like v1.18.0"
[[ "$BUILD_EXECUTION_ROLE" =~ ^arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_-]+$ ]] || die "BUILD_EXECUTION_ROLE '$BUILD_EXECUTION_ROLE' must be an IAM role ARN"

mkdir -p "$EVIDENCE_DIR" "$LOG_DIR"

# The architecture follows NODE_ARCH. Parent image: the EKS-optimized AL2023 AMI for that
# architecture, resolved from the public SSM parameter (an AMI id is a valid Image Builder parent).
case "$NODE_ARCH" in
  amd64) SSM_ARCH=x86_64; : "${BUILD_INSTANCE_TYPE:=m8i.4xlarge}" ;;
  arm64) SSM_ARCH=arm64;  : "${BUILD_INSTANCE_TYPE:=m8g.4xlarge}" ;;
esac
arch_matches_type "$BUILD_INSTANCE_TYPE" || die "BUILD_INSTANCE_TYPE '$BUILD_INSTANCE_TYPE' is not a $NODE_ARCH instance type; the parent image follows NODE_ARCH"
PARENT_IMAGE_ARN=$(aws ssm get-parameter --region "$AWS_REGION" \
  --name "/aws/service/eks/optimized-ami/${KUBERNETES_VERSION}/amazon-linux-2023/${SSM_ARCH}/standard/recommended/image_id" \
  --query Parameter.Value --output text) || die "could not resolve the EKS-optimized AL2023 $SSM_ARCH parent image for Kubernetes $KUBERNETES_VERSION"
[[ "$PARENT_IMAGE_ARN" =~ ^ami-[0-9a-f]+$ ]] || die "the parent image lookup returned '$PARENT_IMAGE_ARN', not an AMI id"
log "parent image $PARENT_IMAGE_ARN ($SSM_ARCH), build instance type $BUILD_INSTANCE_TYPE"

# Component, recipe, and pipeline names
COMPONENT_NAME="EKSNitroSandboxAL2023-${RUN_ID}"
RECIPE_NAME="eks-nitro-sandbox-al2023-${RUN_ID}"
INFRA_CONFIG_NAME="eks-nitro-sandbox-build-config-${RUN_ID}"
DISTRO_CONFIG_NAME="eks-nitro-sandbox-distribution-${RUN_ID}"
PIPELINE_NAME="eks-nitro-sandbox-pipeline-${RUN_ID}"

log "Creating EC2 Image Builder component from deploy/imagebuilder/component.yaml"
# Substitute the component variables (KUBERNETES_VERSION, KUBERNETES_BUILD_DATE, FIRECRACKER_VERSION)
# Image Builder expects these as component parameters, but the AWSTOE YAML uses {{ VAR }} syntax.
# For simplicity, we pre-substitute them here before uploading.
COMPONENT_DOC=$(mktemp)
sed -e "s|{{ KUBERNETES_VERSION }}|${KUBERNETES_VERSION}|g" \
    -e "s|{{ KUBERNETES_BUILD_DATE }}|${KUBERNETES_BUILD_DATE}|g" \
    -e "s|{{ FIRECRACKER_VERSION }}|${POD_ISOLATION_FIRECRACKER_VERSION}|g" \
    "$HERE/../deploy/imagebuilder/component.yaml" > "$COMPONENT_DOC"

COMPONENT_ARN=$(aws imagebuilder create-component \
  --name "$COMPONENT_NAME" \
  --semantic-version "1.0.0" \
  --description "EKS Nitro Sandbox runtime for AL2023 (run ${RUN_ID})" \
  --platform Linux \
  --data "file://${COMPONENT_DOC}" \
  --region "$AWS_REGION" \
  --tags "ManagedBy=${TAGS_OWNER_VALUE}" "RunId=${RUN_ID}" "auto-delete=no" \
  --query 'componentBuildVersionArn' \
  --output text)
log "Component created: $COMPONENT_ARN"
printf 'IB_COMPONENT_ARN=%s\n' "$COMPONENT_ARN" >> "$RUN_STATE_DIR/run-state.env"

log "Creating image recipe"
RECIPE_DOC=$(mktemp)
jq --arg parent "$PARENT_IMAGE_ARN" \
   --arg comp "$COMPONENT_ARN" \
   --arg name "$RECIPE_NAME" \
   '.name = $name | .parentImage = $parent | .components[0].componentArn = $comp' \
   "$HERE/../deploy/imagebuilder/image-recipe.json" > "$RECIPE_DOC"

RECIPE_ARN=$(aws imagebuilder create-image-recipe \
  --cli-input-json "file://${RECIPE_DOC}" \
  --region "$AWS_REGION" \
  --tags "ManagedBy=${TAGS_OWNER_VALUE}" "RunId=${RUN_ID}" "auto-delete=no" \
  --query 'imageRecipeArn' \
  --output text)
log "Recipe created: $RECIPE_ARN"
printf 'IB_RECIPE_ARN=%s\n' "$RECIPE_ARN" >> "$RUN_STATE_DIR/run-state.env"

log "Creating infrastructure configuration (parentInstance: ASG $BUILD_ASG_NAME)"
INFRA_DOC=$(mktemp)
jq --arg name "$INFRA_CONFIG_NAME" \
   --arg profile "$BUILD_INSTANCE_PROFILE" \
   --arg sg "$BUILD_SECURITY_GROUP_ID" \
   --arg subnet "$BUILD_SUBNET_ID" \
   --arg bucket "$BUILD_S3_BUCKET" \
   --arg asg "$BUILD_ASG_NAME" \
   --arg sns "$BUILD_SNS_TOPIC_ARN" \
   --arg itype "$BUILD_INSTANCE_TYPE" \
   '.name = $name | .instanceTypes = [$itype] | .instanceProfileName = $profile | .securityGroupIds = [$sg] | .subnetId = $subnet | .logging.s3Logs.s3BucketName = $bucket | .parentInstance.autoScalingGroup.name = $asg | if $sns != "" then .snsTopicArn = $sns else . end' \
   "$HERE/../deploy/imagebuilder/infrastructure-config.json" > "$INFRA_DOC"

INFRA_ARN=$(aws imagebuilder create-infrastructure-configuration \
  --cli-input-json "file://${INFRA_DOC}" \
  --region "$AWS_REGION" \
  --tags "ManagedBy=${TAGS_OWNER_VALUE}" "RunId=${RUN_ID}" "auto-delete=no" \
  --query 'infrastructureConfigurationArn' \
  --output text)
log "Infrastructure config created: $INFRA_ARN"
printf 'IB_INFRA_ARN=%s\n' "$INFRA_ARN" >> "$RUN_STATE_DIR/run-state.env"

log "Creating distribution configuration"
DISTRO_DOC=$(mktemp)
jq --arg name "$DISTRO_CONFIG_NAME" \
   --arg region "$AWS_REGION" \
   --arg k8s "$KUBERNETES_VERSION" \
   --arg runid "$RUN_ID" \
   '.name = $name | .distributions[0].region = $region | .distributions[0].amiDistributionConfiguration.amiTags.KubernetesVersion = $k8s | .distributions[0].amiDistributionConfiguration.amiTags.RunId = $runid' \
   "$HERE/../deploy/imagebuilder/distribution-config.json" > "$DISTRO_DOC"

DISTRO_ARN=$(aws imagebuilder create-distribution-configuration \
  --cli-input-json "file://${DISTRO_DOC}" \
  --region "$AWS_REGION" \
  --tags "ManagedBy=${TAGS_OWNER_VALUE}" "RunId=${RUN_ID}" "auto-delete=no" \
  --query 'distributionConfigurationArn' \
  --output text)
log "Distribution config created: $DISTRO_ARN"
printf 'IB_DISTRO_ARN=%s\n' "$DISTRO_ARN" >> "$RUN_STATE_DIR/run-state.env"

log "Creating image pipeline"
PIPELINE_ARN=$(aws imagebuilder create-image-pipeline \
  --name "$PIPELINE_NAME" \
  --image-recipe-arn "$RECIPE_ARN" \
  --infrastructure-configuration-arn "$INFRA_ARN" \
  --distribution-configuration-arn "$DISTRO_ARN" \
  --execution-role "$BUILD_EXECUTION_ROLE" \
  --region "$AWS_REGION" \
  --tags "ManagedBy=${TAGS_OWNER_VALUE}" "RunId=${RUN_ID}" "auto-delete=no" \
  --query 'imagePipelineArn' \
  --output text)
log "Pipeline created: $PIPELINE_ARN"
printf 'IB_PIPELINE_ARN=%s\n' "$PIPELINE_ARN" >> "$RUN_STATE_DIR/run-state.env"

log "Starting image pipeline execution (this takes ~30-40 min)"
EXECUTION_ARN=$(aws imagebuilder start-image-pipeline-execution \
  --image-pipeline-arn "$PIPELINE_ARN" \
  --region "$AWS_REGION" \
  --query 'imageBuildVersionArn' \
  --output text)
log "Execution started: $EXECUTION_ARN"
printf 'IB_EXECUTION_ARN=%s\n' "$EXECUTION_ARN" >> "$RUN_STATE_DIR/run-state.env"

log "Waiting for Image Builder pipeline to complete (polling every 2 minutes)..."
while true; do
  STATUS=$(aws imagebuilder get-image --image-build-version-arn "$EXECUTION_ARN" --region "$AWS_REGION" \
    --query 'image.state.status' --output text 2>/dev/null || echo "UNKNOWN")
  case "$STATUS" in
    AVAILABLE) log "Build complete"; break ;;
    FAILED|CANCELLED|DEPRECATED|DISABLED) die "Build failed with status: $STATUS" ;;
    UNKNOWN) warn "Could not determine build status, retrying..." ;;
    *) log "Build status: $STATUS" ;;
  esac
  sleep 120
done

log "Retrieving AMI ID from build output"
AMI_ID=$(aws imagebuilder get-image --image-build-version-arn "$EXECUTION_ARN" --region "$AWS_REGION" \
  --query 'image.outputResources.amis[0].image' --output text)
[ -n "$AMI_ID" ] && [[ "$AMI_ID" =~ ^ami-[0-9a-f]+$ ]] || die "Could not retrieve AMI ID from build"
log "AMI created: $AMI_ID"
printf 'AMI_ID=%s\n' "$AMI_ID" >> "$RUN_STATE_DIR/run-state.env"

log "Tagging AMI snapshots with ManagedBy and RunId"
SNAPS=$(aws ec2 describe-images --region "$AWS_REGION" --image-ids "$AMI_ID" \
  --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text)
for snap in $SNAPS; do
  aws ec2 create-tags --region "$AWS_REGION" --resources "$snap" \
    --tags "Key=${TAGS_OWNER_KEY},Value=${TAGS_OWNER_VALUE}" "Key=${TAGS_RUN_KEY},Value=${RUN_ID}" "Key=auto-delete,Value=no" \
    || warn "Could not tag snapshot $snap"
  log "Tagged snapshot: $snap"
done

log ""
log "Image Builder build complete for ${NODE_ARCH} (run $RUN_ID)"
log "  AMI: $AMI_ID"
log "  Component: $COMPONENT_NAME"
log "  Pipeline: $PIPELINE_NAME"
log "  Execution: $EXECUTION_ARN"

# Cleanup temp files
rm -f "$COMPONENT_DOC" "$RECIPE_DOC" "$INFRA_DOC" "$DISTRO_DOC"
printf '%s\n' "$AMI_ID"
