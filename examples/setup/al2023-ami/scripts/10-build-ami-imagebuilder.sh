#!/usr/bin/env bash
# 10-build-ami-imagebuilder.sh: build the AL2023 Nitro Sandbox node AMI with EC2 Image Builder.
#
# An optional alternative to the Packer build (10-build-ami-packer.sh) that produces the same
# AL2023 -pod-isolation AMI. The install steps are the AWSTOE component in
# deploy/imagebuilder/component.yaml, which mirrors the upstream amazon-eks-ami
# install-pod-isolation.sh provisioner.
#
#   RUN_ID=<id> BUILD_SUBNET_ID="<private subnet> [<private subnet> ...]" scripts/ib-prereqs.sh up
#   RUN_ID=<id> KUBERNETES_BUNDLE_VERSION=1.37.1 KUBERNETES_BUILD_DATE=<date> scripts/10-build-ami-imagebuilder.sh
#
# The build instance must have Nitro Enclaves enabled, and an infrastructure configuration has no
# enclave setting. Image Builder therefore takes the build instance from the Auto Scaling group
# ib-prereqs.sh creates (parentInstance), whose launch template enables enclaves. That instance
# keeps the group's AMI, instance type, profile, subnet and security group; this script checks
# the template before it starts. See "Build on an instance from an Auto Scaling group":
# https://docs.aws.amazon.com/imagebuilder/latest/userguide/infra-config-parent-instance.html
#
# Each Image Builder resource is tagged ManagedBy and RunId and its ARN is recorded in the run
# state as soon as it exists, so `ib-prereqs.sh down` can remove it. The output AMI and its
# snapshots carry the same tags and the AMI id is recorded, so clean.sh can remove them.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
require_run_id
STATE="$RUN_STATE_DIR/run-state.env"
rec()    { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -n 1; }
rec1()   { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -n 1; }   # identity: the first record is the run's
record() { printf '%s=%s\n' "$1" "$2" >> "$STATE"; }
aw()     { aws --region "$AWS_REGION" "$@"; }

: "${BUILD_ASG_NAME:=$(rec IB_ASG_NAME)}"
: "${BUILD_SECURITY_GROUP_ID:=$(rec IB_SECURITY_GROUP_ID)}"
: "${BUILD_INSTANCE_PROFILE:=$(rec IB_INSTANCE_PROFILE)}"
: "${BUILD_EXECUTION_ROLE:=$(rec IB_EXECUTION_ROLE)}"
: "${BUILD_SUBNET_ID:=$(rec BUILD_SUBNET_ID)}"
: "${BUILD_S3_BUCKET:=}"            # optional: also write the build logs to this bucket
: "${POD_ISOLATION_FIRECRACKER_VERSION:=latest}"
: "${BUILD_WAIT_MINUTES:=120}"
: "${KUBERNETES_BUNDLE_VERSION:?set KUBERNETES_BUNDLE_VERSION to the full Kubernetes version of the amazon-eks bundle, e.g. 1.37.1 (the s3://amazon-eks/<version>/<build date> folder)}"
: "${KUBERNETES_BUILD_DATE:?set KUBERNETES_BUILD_DATE to the build date of the bundle (the s3://amazon-eks/<version>/<build date> folder)}"
for v in BUILD_ASG_NAME BUILD_SECURITY_GROUP_ID BUILD_INSTANCE_PROFILE BUILD_EXECUTION_ROLE BUILD_SUBNET_ID; do
  [ -n "${!v}" ] || die "$v is not set and run $RUN_ID has no value for it; run scripts/ib-prereqs.sh up first"
done

# These values are substituted into the component's shell commands, so accept only plain values.
case "$KUBERNETES_VERSION" in 1.36|1.37) ;; *) die "KUBERNETES_VERSION '$KUBERNETES_VERSION': the pod isolation runtime is published for 1.36 and 1.37 only" ;; esac
[[ "$KUBERNETES_BUNDLE_VERSION" =~ ^1\.[0-9]{2}\.[0-9]{1,3}$ ]] && [ "${KUBERNETES_BUNDLE_VERSION%.*}" = "$KUBERNETES_VERSION" ] \
  || die "KUBERNETES_BUNDLE_VERSION '$KUBERNETES_BUNDLE_VERSION' must be a full version of $KUBERNETES_VERSION, like $KUBERNETES_VERSION.1"
[[ "$KUBERNETES_BUILD_DATE" =~ ^[0-9A-Za-z._-]{1,32}$ ]] || die "KUBERNETES_BUILD_DATE '$KUBERNETES_BUILD_DATE' has characters outside [0-9A-Za-z._-]"
[[ "$POD_ISOLATION_FIRECRACKER_VERSION" =~ ^(latest|v[0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "POD_ISOLATION_FIRECRACKER_VERSION '$POD_ISOLATION_FIRECRACKER_VERSION' must be 'latest' or look like v1.18.0"
[[ "$BUILD_EXECUTION_ROLE" =~ ^arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$ ]] || die "BUILD_EXECUTION_ROLE '$BUILD_EXECUTION_ROLE' must be an IAM role ARN"
mkdir -p "$EVIDENCE_DIR" "$LOG_DIR"

# The account and Region ib-prereqs.sh recorded for the run.
account=$(aw sts get-caller-identity --query Account --output text) || die "could not read the current AWS account"
[ "$(rec1 ACCOUNT_ID)" = "$account" ] || die "credentials are for a different account than run $RUN_ID's prerequisites"
[ "$(rec1 AWS_REGION)" = "$AWS_REGION" ] || die "AWS_REGION is '$AWS_REGION' but run $RUN_ID's prerequisites are in '$(rec1 AWS_REGION)'"

# The group's launch template decides the build instance. Image Builder takes any InService
# instance of the group, so check the numbered template version the group is pinned to (never
# $Latest or $Default, which can move), that every InService instance was launched from that
# version, and that the version has enclaves on and the architecture NODE_ARCH asks for.
info=$(aw autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$BUILD_ASG_NAME" \
  --query 'AutoScalingGroups[0].LaunchTemplate.[LaunchTemplateName,Version]' --output text) \
  || die "could not read Auto Scaling group $BUILD_ASG_NAME"
read -r lt ltver <<<"$info"
[ -n "${lt:-}" ] && [ "$lt" != None ] || die "Auto Scaling group $BUILD_ASG_NAME has no launch template"
[[ "${ltver:-}" =~ ^[0-9]+$ ]] || die "Auto Scaling group $BUILD_ASG_NAME launches from template version '${ltver:-}'; pin it to a version number, because \$Latest and \$Default can change"
vers=$(aw autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$BUILD_ASG_NAME" \
  --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].LaunchTemplate.Version" --output text) \
  || die "could not read the instances of Auto Scaling group $BUILD_ASG_NAME"
[ -n "$vers" ] || die "Auto Scaling group $BUILD_ASG_NAME has no InService instance for Image Builder to take"
for v in $vers; do
  [ "$v" = "$ltver" ] || die "an InService instance of $BUILD_ASG_NAME was launched from template version '$v', not the pinned $ltver; wait for the group to replace it"
done
info=$(aw ec2 describe-launch-template-versions --launch-template-name "$lt" --versions "$ltver" \
  --query 'LaunchTemplateVersions[0].LaunchTemplateData.[InstanceType,EnclaveOptions.Enabled]' --output text) \
  || die "could not read launch template $lt version $ltver"
read -r itype enclave <<<"$info"
[ "$enclave" = True ] || die "launch template $lt does not enable Nitro Enclaves; the build needs them"
arch_matches_type "$itype" || die "launch template $lt uses $itype, which is not a $NODE_ARCH instance type"
case "$NODE_ARCH" in amd64) ssm_arch=x86_64 ;; arm64) ssm_arch=arm64 ;; esac
parent=$(aw ssm get-parameter \
  --name "/aws/service/eks/optimized-ami/${KUBERNETES_VERSION}/amazon-linux-2023/${ssm_arch}/standard/recommended/image_id" \
  --query Parameter.Value --output text) || die "could not resolve the EKS-optimized AL2023 $ssm_arch image for Kubernetes $KUBERNETES_VERSION"
[[ "$parent" =~ ^ami-[0-9a-f]+$ ]] || die "the parent image lookup returned '$parent', not an AMI id"
log "group $BUILD_ASG_NAME: $itype from $lt, enclaves on; parent image $parent ($ssm_arch)"

name="${RESOURCE_PREFIX}-ib-${RUN_ID}"
tags="$TAGS_OWNER_KEY=$TAGS_OWNER_VALUE,$TAGS_RUN_KEY=$RUN_ID,auto-delete=no"
D="$SAMPLE_DIR/deploy/imagebuilder"
tmpd=$(mktemp -d); trap 'rm -rf "$tmpd"' EXIT

# The build's log group, created tagged before Image Builder writes to it, so clean up can check it.
lg="/aws/imagebuilder/$name"
found=$(aw logs describe-log-groups --log-group-name-prefix "$lg" --query "logGroups[?logGroupName=='$lg'].logGroupName | [0]" --output text) \
  || die "could not determine whether log group $lg exists"
if [ "$found" = "$lg" ]; then
  aw logs list-tags-log-group --log-group-name "$lg" --query tags --output json | tags_match \
    || die "log group $lg exists and is not run $RUN_ID's"
else
  aw logs create-log-group --log-group-name "$lg" --tags "$tags" || die "could not create log group $lg"
fi

sed -e "s|{{ KUBERNETES_VERSION }}|${KUBERNETES_VERSION}|g" \
    -e "s|{{ KUBERNETES_BUNDLE_VERSION }}|${KUBERNETES_BUNDLE_VERSION}|g" \
    -e "s|{{ KUBERNETES_BUILD_DATE }}|${KUBERNETES_BUILD_DATE}|g" \
    -e "s|{{ FIRECRACKER_VERSION }}|${POD_ISOLATION_FIRECRACKER_VERSION}|g" "$D/component.yaml" > "$tmpd/component.yaml"
arn=$(aw imagebuilder create-component --name "$name" --semantic-version 1.0.0 --platform Linux \
  --description "EKS Nitro Sandbox runtime for AL2023 (run $RUN_ID)" --data "file://$tmpd/component.yaml" \
  --tags "$tags" --query componentBuildVersionArn --output text)
record IB_COMPONENT_ARN "$arn"; log "component $arn"

jq --arg name "$name" --arg parent "$parent" --arg comp "$arn" \
  '.name = $name | .parentImage = $parent | .components[0].componentArn = $comp' "$D/image-recipe.json" > "$tmpd/recipe.json"
arn=$(aw imagebuilder create-image-recipe --cli-input-json "file://$tmpd/recipe.json" --tags "$tags" \
  --query imageRecipeArn --output text)
record IB_RECIPE_ARN "$arn"; recipe=$arn; log "recipe $arn"

jq --arg name "$name" --arg profile "$BUILD_INSTANCE_PROFILE" --arg sg "$BUILD_SECURITY_GROUP_ID" \
   --arg subnet "${BUILD_SUBNET_ID%% *}" --arg asg "$BUILD_ASG_NAME" --arg itype "$itype" --arg bucket "$BUILD_S3_BUCKET" \
   --arg owner "$TAGS_OWNER_VALUE" --arg run "$RUN_ID" \
   '.name = $name | .instanceTypes = [$itype] | .instanceProfileName = $profile | .securityGroupIds = [$sg]
    | .subnetId = $subnet | .parentInstance.autoScalingGroup.name = $asg
    | .resourceTags = {"ManagedBy": $owner, "RunId": $run, "auto-delete": "no"}
    | if $bucket == "" then del(.logging) else .logging.s3Logs.s3BucketName = $bucket end' \
   "$D/infrastructure-config.json" > "$tmpd/infra.json"
arn=$(aw imagebuilder create-infrastructure-configuration --cli-input-json "file://$tmpd/infra.json" --tags "$tags" \
  --query infrastructureConfigurationArn --output text)
record IB_INFRA_ARN "$arn"; infra=$arn; log "infrastructure configuration $arn"

jq --arg name "$name" --arg region "$AWS_REGION" --arg k8s "$KUBERNETES_VERSION" \
   --arg owner "$TAGS_OWNER_VALUE" --arg run "$RUN_ID" \
   '.name = $name | .distributions[0].region = $region
    | .distributions[0].amiDistributionConfiguration.amiTags += {"KubernetesVersion": $k8s, "ManagedBy": $owner, "RunId": $run}' \
   "$D/distribution-config.json" > "$tmpd/distribution.json"
arn=$(aw imagebuilder create-distribution-configuration --cli-input-json "file://$tmpd/distribution.json" --tags "$tags" \
  --query distributionConfigurationArn --output text)
record IB_DISTRIBUTION_ARN "$arn"; dist=$arn; log "distribution configuration $arn"

# Image tests would launch a separate test instance from the infrastructure configuration, which
# cannot enable enclaves; the component's own build phase checks what it installs.
arn=$(aw imagebuilder create-image-pipeline --name "$name" --image-recipe-arn "$recipe" \
  --infrastructure-configuration-arn "$infra" --distribution-configuration-arn "$dist" \
  --execution-role "$BUILD_EXECUTION_ROLE" --image-tests-configuration imageTestsEnabled=false \
  --tags "$tags" --query imagePipelineArn --output text)
record IB_PIPELINE_ARN "$arn"; pipeline=$arn; log "pipeline $arn"

image=$(aw imagebuilder start-image-pipeline-execution --image-pipeline-arn "$pipeline" \
  --query imageBuildVersionArn --output text)
record IB_IMAGE_ARN "$image"; log "build started: $image"
# The image resource does not inherit the pipeline's tags; tag it, as clean up checks it.
aw imagebuilder tag-resource --resource-arn "$image" --tags "$tags" || die "could not tag $image"

log "waiting for the build (up to $BUILD_WAIT_MINUTES min)"
status=""
for _ in $(seq 1 "$BUILD_WAIT_MINUTES"); do
  status=$(aw imagebuilder get-image --image-build-version-arn "$image" --query image.state.status --output text 2>/dev/null || echo UNKNOWN)
  case "$status" in AVAILABLE|FAILED|CANCELLED|DELETED) break ;; esac
  sleep 60
done
log "build status: $status"
if [ "$status" != AVAILABLE ]; then
  reason=$(aw imagebuilder get-image --image-build-version-arn "$image" --query image.state.reason --output text 2>/dev/null || true)
  die "the Image Builder build ended $status: ${reason:-no reason given}. Logs: CloudWatch log group /aws/imagebuilder/$name"
fi

ami=$(aw imagebuilder get-image --image-build-version-arn "$image" \
  --query "image.outputResources.amis[?region=='$AWS_REGION'].image | [0]" --output text)
[[ "$ami" =~ ^ami-[0-9a-f]+$ ]] || die "the build reported '$ami', which is not an AMI id"
record AMI_ID "$ami"   # before tagging, so clean.sh can find it even if a later step fails
# Each lookup is captured first: a failure inside a `for` list or a process substitution would
# not stop the script.
info=$(aw ec2 describe-images --image-ids "$ami" --query 'Images[0].[Name,Architecture]' --output text) \
  || die "could not read AMI $ami"
read -r ami_name ami_arch <<<"$info"
snap_ids=$(aw ec2 describe-images --image-ids "$ami" --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text) \
  || die "could not read the snapshots of $ami"
for snap in $snap_ids; do
  [ "$snap" = None ] && continue
  [[ "$snap" =~ ^snap-[0-9a-f]+$ ]] || die "AMI $ami lists '$snap', which is not a snapshot id"
  record SNAPSHOT_ID "$snap"   # before tagging: clean up finds it even after the AMI is deregistered
done
aw ec2 create-tags --resources "$ami" \
  --tags "Key=$TAGS_OWNER_KEY,Value=$TAGS_OWNER_VALUE" "Key=$TAGS_RUN_KEY,Value=$RUN_ID" "Key=auto-delete,Value=no"
for snap in $snap_ids; do
  [ "$snap" = None ] && continue
  aw ec2 create-tags --resources "$snap" \
    --tags "Key=$TAGS_OWNER_KEY,Value=$TAGS_OWNER_VALUE" "Key=$TAGS_RUN_KEY,Value=$RUN_ID" "Key=auto-delete,Value=no"
done
printf 'AMI_ID=%s\nAMI_NAME=%s\nAMI_ARCH=%s\nAMI_BUILDER=imagebuilder\n' "$ami" "$ami_name" "$ami_arch" >> "$EVIDENCE_DIR/run-evidence.env"
log "built AMI: $ami ($ami_name, $ami_arch)"
printf '%s\n' "$ami"
