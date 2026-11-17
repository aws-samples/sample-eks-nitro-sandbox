#!/usr/bin/env bash
# ib-prereqs.sh: the AWS resources the EC2 Image Builder path needs, for one run and architecture.
#
#   RUN_ID=<id> BUILD_SUBNET_ID="<private subnet> [<private subnet> ...]" scripts/ib-prereqs.sh up
#   RUN_ID=<id> scripts/ib-prereqs.sh down
#   RUN_ID=<id> scripts/ib-prereqs.sh reset   # only the Image Builder resources, to build again
#
# Image Builder can only build on an enclave-enabled instance by taking one from an Auto Scaling
# group (parentInstance). The build instance keeps everything the group launched it with: AMI,
# instance type, instance profile, subnet, security group and metadata options. So `up` creates:
#   - a launch template: the EKS-optimized AL2023 AMI for NODE_ARCH, an enclave-capable instance
#     type, EnclaveOptions.Enabled=true, IMDSv2 with hop limit 1, no public IP;
#   - an Auto Scaling group of one instance from it, in a private subnet with a NAT route;
#   - the instance role and profile (Systems Manager, Image Builder, read of the public EKS bundle);
#   - a security group (outbound only) and the pipeline's execution role, scoped to the one group.
# Each is named <RESOURCE_PREFIX>-ib-<RUN_ID> and tagged ManagedBy and RunId when it is created.
# `up` waits until the group's instance is online in Systems Manager, which Image Builder needs.
#
# `down` removes them, and the Image Builder resources the build driver recorded, only when they
# carry this run's tags. The output AMI is clean.sh's. EC2 deletes the host may block are written
# to an ordered script for you to run, as clean.sh does. Exits non-zero when anything is left.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
require_run_id
mode="${1:-}"; case "$mode" in up|down|reset) ;; *) die "usage: ib-prereqs.sh up|down|reset" ;; esac

NAME="${RESOURCE_PREFIX}-ib-${RUN_ID}"
require_name "Image Builder prerequisite" "$NAME" 52 '^[a-z0-9-]+$'
STATE="$RUN_STATE_DIR/run-state.env"
mkdir -p "$RUN_STATE_DIR"
TAGS_CLI="Key=$TAGS_OWNER_KEY,Value=$TAGS_OWNER_VALUE Key=$TAGS_RUN_KEY,Value=$RUN_ID Key=auto-delete,Value=no"
rec()    { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -n 1; }
rec1()   { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -n 1; }   # identity: the first record is the run's
record() { printf '%s=%s\n' "$1" "$2" >> "$STATE"; }
aw()     { aws --region "$AWS_REGION" "$@"; }
jtags()  { python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("Tags") or []))'; }

# probe [--tags] <not-found-regex> <command...>: 0 found (PROBE_OUT), 1 the API said not found
# (or, for a describe, gave an empty answer), 2 could not determine. Only 1 may be treated as
# absent. With --tags the command lists a resource's tags, and an empty list means a resource
# without tags, not an absent one.
probe() {
  local tags=0 nf err; [ "$1" = --tags ] && { tags=1; shift; }
  nf="$1"; shift; err=$(mktemp)
  if PROBE_OUT=$("$@" 2>"$err"); then
    rm -f "$err"
    [ "$tags" = 1 ] && { [ -n "$PROBE_OUT" ] && [ "$PROBE_OUT" != None ] || PROBE_OUT='{}'; return 0; }
    case "$PROBE_OUT" in ""|None|null|"[]"|"{}") return 1 ;; esac
    return 0
  fi
  if grep -Eq "$nf" "$err"; then rm -f "$err"; return 1; fi
  warn "could not determine state ($*): $(head -n 2 "$err")"; rm -f "$err"; return 2
}

# Same account the run was created in (recorded at the first `up`).
account=$(aw sts get-caller-identity --query Account --output text) || die "could not read the current AWS account"
recorded=$(rec1 ACCOUNT_ID)
if [ -z "$recorded" ]; then
  [ "$mode" = up ] || die "run $RUN_ID recorded no ACCOUNT_ID; refusing to delete anything"
  record ACCOUNT_ID "$account"; record AWS_REGION "$AWS_REGION"; record RESOURCE_PREFIX "$RESOURCE_PREFIX"
elif [ "$recorded" != "$account" ]; then
  die "credentials are for a different account than run $RUN_ID was created in; refusing"
fi
IDENTITY_MAY_BE_NEW="" require_identity AWS_REGION RESOURCE_PREFIX

# --------------------------------------------------------------------------------------------
if [ "$mode" = up ]; then
  : "${BUILD_SUBNET_ID:?set BUILD_SUBNET_ID to one or more private subnets (space separated) with a NAT route, in AZs with enclave-capable capacity}"
  case "$NODE_ARCH" in amd64) ssm_arch=x86_64; : "${BUILD_INSTANCE_TYPE:=m8i.4xlarge}" ;;
                       arm64) ssm_arch=arm64;  : "${BUILD_INSTANCE_TYPE:=m8g.4xlarge}" ;; esac
  arch_matches_type "$BUILD_INSTANCE_TYPE" || die "BUILD_INSTANCE_TYPE '$BUILD_INSTANCE_TYPE' is not a $NODE_ARCH instance type"

  # Several subnets let Auto Scaling launch in whichever zone has capacity for the instance type.
  [[ "$BUILD_SUBNET_ID" =~ ^subnet-[0-9a-f]+( subnet-[0-9a-f]+)*$ ]] || die "BUILD_SUBNET_ID '$BUILD_SUBNET_ID' must be subnet ids separated by spaces"
  probe 'InvalidSubnetID' aw ec2 describe-subnets --subnet-ids $BUILD_SUBNET_ID \
    --query 'Subnets[].[VpcId,MapPublicIpOnLaunch]' --output text || die "could not read the subnets $BUILD_SUBNET_ID"
  [ "$(printf '%s\n' "$PROBE_OUT" | awk '{print $1}' | sort -u | wc -l)" = 1 ] || die "the subnets $BUILD_SUBNET_ID are not all in one VPC"
  [ "$(printf '%s\n' "$PROBE_OUT" | awk '{print $2}' | sort -u)" = False ] || die "a subnet in $BUILD_SUBNET_ID gives instances a public IP; use private subnets with a NAT route"
  vpc=$(printf '%s\n' "$PROBE_OUT" | awk 'NR==1{print $1}')

  # An existing resource of the same name is reused only if it carries this run's tags.
  # Security group: outbound only (no inbound rule).
  probe 'InvalidGroup' aw ec2 describe-security-groups --filters "Name=group-name,Values=$NAME" "Name=vpc-id,Values=$vpc" \
    --query 'SecurityGroups[0]' --output json; rc=$?
  case $rc in
    0) printf '%s' "$PROBE_OUT" | jtags | tags_match || die "security group $NAME exists and is not run $RUN_ID's"
       sg=$(printf '%s' "$PROBE_OUT" | json_get 'd["GroupId"]') ;;
    1) sg=$(aw ec2 create-security-group --group-name "$NAME" --vpc-id "$vpc" \
         --description "Image Builder build instance for $NAME (outbound only)" \
         --tag-specifications "ResourceType=security-group,Tags=[$(run_tags_cli),{Key=auto-delete,Value=no}]" \
         --query GroupId --output text) || die "could not create security group $NAME" ;;
    *) die "could not determine whether security group $NAME exists" ;;
  esac
  record IB_SECURITY_GROUP_ID "$sg"; log "security group $sg"

  # Instance role + profile. The build instance runs the component through Systems Manager.
  role_owned_or_absent() { # role_owned_or_absent <role name>
    probe --tags 'NoSuchEntity' aws iam list-role-tags --role-name "$1" --query Tags --output json; local rc=$?
    case $rc in 1) return 1 ;;
      0) printf '%s' "$PROBE_OUT" | tags_match || die "IAM role $1 exists and is not run $RUN_ID's"; return 0 ;;
      *) die "could not determine whether IAM role $1 exists" ;; esac
  }
  role="$NAME-instance"
  if ! role_owned_or_absent "$role"; then
    aws iam create-role --role-name "$role" --tags $TAGS_CLI \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
      >/dev/null || die "could not create IAM role $role"
  fi
  for p in AmazonSSMManagedInstanceCore EC2InstanceProfileForImageBuilder; do
    aws iam attach-role-policy --role-name "$role" --policy-arn "arn:aws:iam::aws:policy/$p" || die "could not attach $p to $role"
  done
  aws iam put-role-policy --role-name "$role" --policy-name read-eks-bundle --policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::amazon-eks/*"}]}' \
    || die "could not set the bundle read policy on $role"
  probe 'NoSuchEntity' aws iam get-instance-profile --instance-profile-name "$role" --query 'InstanceProfile.Tags' --output json; rc=$?
  case $rc in
    1) aws iam create-instance-profile --instance-profile-name "$role" --tags $TAGS_CLI >/dev/null \
         || die "could not create instance profile $role"
       aws iam add-role-to-instance-profile --instance-profile-name "$role" --role-name "$role" || die "could not add $role to its profile" ;;
    0) printf '%s' "$PROBE_OUT" | tags_match || die "instance profile $role exists and is not run $RUN_ID's" ;;
    *) die "could not determine whether instance profile $role exists" ;;
  esac
  record IB_INSTANCE_PROFILE "$role"; log "instance profile $role"

  # Execution role: Image Builder takes the instance with it (the service-linked role cannot).
  exec_role="$NAME-exec"
  if ! role_owned_or_absent "$exec_role"; then
    aws iam create-role --role-name "$exec_role" --tags $TAGS_CLI \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"imagebuilder.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
      >/dev/null || die "could not create IAM role $exec_role"
  fi
  aws iam attach-role-policy --role-name "$exec_role" --policy-arn arn:aws:iam::aws:policy/EC2ImageBuilderExecutionPolicy \
    || die "could not attach EC2ImageBuilderExecutionPolicy to $exec_role"
  aws iam put-role-policy --role-name "$exec_role" --policy-name take-from-group --policy-document "$(cat <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["ec2:CreateTags","ec2:DeleteTags"],"Resource":"arn:aws:ec2:*:*:instance/*",
  "Condition":{"StringEquals":{"ec2:ResourceTag/aws:autoscaling:groupName":"$NAME"}}},
 {"Effect":"Allow","Action":"autoscaling:DescribeAutoScalingGroups","Resource":"*"},
 {"Effect":"Allow","Action":"autoscaling:DetachInstances",
  "Resource":"arn:aws:autoscaling:$AWS_REGION:$account:autoScalingGroup:*:autoScalingGroupName/$NAME"}]}
EOF
)" || die "could not set the group policy on $exec_role"
  record IB_EXECUTION_ROLE "arn:aws:iam::$account:role/$exec_role"; log "execution role $exec_role"

  # Launch template for the group.
  ami=$(aw ssm get-parameter --name "/aws/service/eks/optimized-ami/$KUBERNETES_VERSION/amazon-linux-2023/$ssm_arch/standard/recommended/image_id" \
    --query Parameter.Value --output text) || die "could not resolve the EKS-optimized AL2023 $ssm_arch AMI for $KUBERNETES_VERSION"
  [[ "$ami" =~ ^ami-[0-9a-f]+$ ]] || die "the parent AMI lookup returned '$ami'"
  probe 'NotFound' aw ec2 describe-launch-templates --launch-template-names "$NAME" --query 'LaunchTemplates[0].Tags' --output json; rc=$?
  case $rc in
    0) printf '%s' "$PROBE_OUT" | tags_match || die "launch template $NAME exists and is not run $RUN_ID's" ;;
    1) tag_spec() { printf '{"ResourceType":"%s","Tags":[{"Key":"%s","Value":"%s"},{"Key":"%s","Value":"%s"},{"Key":"auto-delete","Value":"no"}]}' \
         "$1" "$TAGS_OWNER_KEY" "$TAGS_OWNER_VALUE" "$TAGS_RUN_KEY" "$RUN_ID"; }
       data=$(cat <<EOF
{"ImageId":"$ami","InstanceType":"$BUILD_INSTANCE_TYPE","IamInstanceProfile":{"Name":"$role"},
 "SecurityGroupIds":["$sg"],"EnclaveOptions":{"Enabled":true},
 "MetadataOptions":{"HttpTokens":"required","HttpPutResponseHopLimit":1},
 "BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":40,"VolumeType":"gp3","DeleteOnTermination":true}}],
 "TagSpecifications":[$(tag_spec instance),$(tag_spec volume)]}
EOF
)
       sleep "${IB_PROFILE_SETTLE:-10}"  # a new instance profile takes a few seconds to be usable in a launch template
       aw ec2 create-launch-template --launch-template-name "$NAME" --launch-template-data "$data" \
         --tag-specifications "ResourceType=launch-template,Tags=[$(run_tags_cli),{Key=auto-delete,Value=no}]" >/dev/null \
         || die "could not create launch template $NAME" ;;
    *) die "could not determine whether launch template $NAME exists" ;;
  esac
  log "launch template $NAME ($ami, $BUILD_INSTANCE_TYPE, enclaves on)"

  # Auto Scaling group of one, pinned to the template's version NUMBER (never $Latest, which can move
  # under an instance that is already running). Image Builder detaches its instance; the group
  # launches another.
  ltver=$(aw ec2 describe-launch-templates --launch-template-names "$NAME" --query 'LaunchTemplates[0].LatestVersionNumber' --output text) \
    || die "could not read launch template $NAME"
  [[ "$ltver" =~ ^[0-9]+$ ]] || die "launch template $NAME reported version '$ltver', not a number"
  # Record the image the template really launches (a reused template may predate today's lookup);
  # the build driver checks the group's pinned version still launches exactly this image.
  tpl_ami=$(aw ec2 describe-launch-template-versions --launch-template-name "$NAME" --versions "$ltver" \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData.ImageId' --output text) \
    || die "could not read launch template $NAME version $ltver"
  [[ "$tpl_ami" =~ ^ami-[0-9a-f]+$ ]] || die "launch template $NAME version $ltver names '$tpl_ami' as its image, not an AMI id"
  record IB_PARENT_AMI "$tpl_ami"
  probe 'xxx-never' aw autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$NAME" \
    --query 'AutoScalingGroups[0].Tags[].{Key:Key,Value:Value}' --output json; rc=$?
  case $rc in
    0) printf '%s' "$PROBE_OUT" | tags_match || die "Auto Scaling group $NAME exists and is not run $RUN_ID's" ;;
    1) aw autoscaling create-auto-scaling-group --auto-scaling-group-name "$NAME" \
         --launch-template "LaunchTemplateName=$NAME,Version=$ltver" --min-size 1 --max-size 1 --desired-capacity 1 \
         --vpc-zone-identifier "${BUILD_SUBNET_ID// /,}" \
         --tags "ResourceId=$NAME,ResourceType=auto-scaling-group,Key=$TAGS_OWNER_KEY,Value=$TAGS_OWNER_VALUE,PropagateAtLaunch=false" \
                "ResourceId=$NAME,ResourceType=auto-scaling-group,Key=$TAGS_RUN_KEY,Value=$RUN_ID,PropagateAtLaunch=false" \
                "ResourceId=$NAME,ResourceType=auto-scaling-group,Key=auto-delete,Value=no,PropagateAtLaunch=false" \
         || die "could not create Auto Scaling group $NAME" ;;
    *) die "could not determine whether Auto Scaling group $NAME exists" ;;
  esac
  record IB_ASG_NAME "$NAME"; record BUILD_SUBNET_ID "$BUILD_SUBNET_ID"; record NODE_ARCH "$NODE_ARCH"

  log "waiting for the group's instance to be online in Systems Manager (up to 15 min)"
  for _ in $(seq 1 90); do
    iid=$(aw autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$NAME" \
      --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId | [0]" --output text 2>/dev/null)
    if [[ "$iid" =~ ^i- ]]; then
      ping=$(aw ssm describe-instance-information --filters "Key=InstanceIds,Values=$iid" \
        --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)
      [ "$ping" = Online ] && { log "instance $iid is InService and online in Systems Manager"; break; }
    fi
    sleep 10
  done
  if [ "${ping:-}" != Online ]; then
    why=$(aw autoscaling describe-scaling-activities --auto-scaling-group-name "$NAME" --max-items 1 \
      --query 'Activities[0].[StatusCode,StatusMessage]' --output text 2>/dev/null | cut -c1-400)
    die "no instance of $NAME came online in Systems Manager. The group's latest activity: ${why:-unknown}. If it launched, check the subnet's NAT route; if it could not launch, use a subnet in another Availability Zone."
  fi
  log "prerequisites ready for run $RUN_ID; run scripts/10-build-ami-imagebuilder.sh next"
  exit 0
fi

# --------------------------------------------------------------------------------------------
# down, reset
incomplete=0
REMAINING="$RUN_STATE_DIR/ib-teardown-remaining.sh"; : > "$REMAINING"
blocked() { # blocked <command...>: shell-quoted, so no value can add a command to the hand-off.
  # The script stops at the first failed delete, so a dependent is never deleted after its consumer.
  local line; line=$(printf '%q ' "$@"); line=${line% }
  [ -s "$REMAINING" ] || printf '#!/usr/bin/env bash\nset -euo pipefail\n' > "$REMAINING"
  printf '%s\n' "$line" >> "$REMAINING"; incomplete=1; warn "not deleted here; recorded in $REMAINING: $line"; }
leave()   { warn "$1"; incomplete=1; }

# Image Builder resources the driver recorded, dependents first. Each must carry this run's tags.
# Every ARN ever recorded for the run is checked, so a retried build leaves nothing behind.
for arn in $(for key in IB_IMAGE_ARN IB_PIPELINE_ARN IB_DISTRIBUTION_ARN IB_INFRA_ARN IB_RECIPE_ARN IB_COMPONENT_ARN; do
               sed -n "s/^$key=//p" "$STATE" 2>/dev/null | awk -v k="$key" '{print k"|"$0}'; done | awk '!seen[$0]++'); do
  key=${arn%%|*}; arn=${arn#*|}
  probe --tags 'NotFoundException|ResourceNotFound' aw imagebuilder list-tags-for-resource --resource-arn "$arn" --query tags --output json; rc=$?
  case $rc in
    0) if printf '%s' "$PROBE_OUT" | tags_match; then
         case $key in
           IB_IMAGE_ARN)        aw imagebuilder delete-image --image-build-version-arn "$arn" >/dev/null ;;
           IB_PIPELINE_ARN)     aw imagebuilder delete-image-pipeline --image-pipeline-arn "$arn" >/dev/null ;;
           IB_DISTRIBUTION_ARN) aw imagebuilder delete-distribution-configuration --distribution-configuration-arn "$arn" >/dev/null ;;
           IB_INFRA_ARN)        aw imagebuilder delete-infrastructure-configuration --infrastructure-configuration-arn "$arn" >/dev/null ;;
           IB_RECIPE_ARN)       aw imagebuilder delete-image-recipe --image-recipe-arn "$arn" >/dev/null ;;
           IB_COMPONENT_ARN)    aw imagebuilder delete-component --component-build-version-arn "$arn" >/dev/null ;;
         esac && log "deleted $arn" || leave "could not delete $arn"
       else leave "$arn is not tagged for run $RUN_ID; leaving it"; fi ;;
    1) log "$arn not present" ;;
    *) incomplete=1 ;;
  esac
done

if [ "$mode" = reset ]; then
  [ "$incomplete" = 0 ] || { echo "IMAGE BUILDER RESET INCOMPLETE: see the warnings above."; exit 1; }
  echo "Image Builder resources of run $RUN_ID removed; the group and roles are kept."; exit 0
fi
# The build group, roles, template and security group are what the Image Builder resources above
# were made from. While one of those is still there, or could not be checked, keep them all.
if [ "$incomplete" != 0 ]; then
  echo "IMAGE BUILDER CLEAN UP INCOMPLETE: an Image Builder resource is still there or could not be checked, so the group, roles, template and security group are kept. Fix the warnings above and run down again."
  exit 1
fi

# The build's log group: the driver creates it, tagged, before the build writes to it.
lg="/aws/imagebuilder/$NAME"
probe 'xxx-never' aw logs describe-log-groups --log-group-name-prefix "$lg" \
  --query "logGroups[?logGroupName=='$lg'].logGroupName | [0]" --output text; rc=$?
case $rc in
  0) probe --tags 'ResourceNotFound' aw logs list-tags-log-group --log-group-name "$lg" --query tags --output json; trc=$?
     if [ "$trc" = 0 ] && printf '%s' "$PROBE_OUT" | tags_match; then
       aw logs delete-log-group --log-group-name "$lg" && log "deleted log group $lg" || leave "could not delete log group $lg"
     elif [ "$trc" = 0 ]; then leave "log group $lg is not tagged for run $RUN_ID; leaving it"
     else incomplete=1; fi ;;
  1) log "log group $lg not present" ;;
  *) incomplete=1 ;;
esac

# Auto Scaling group: empty it, then delete it with its instances.
probe 'xxx-never' aw autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$NAME" \
  --query 'AutoScalingGroups[0]' --output json; rc=$?
case $rc in
  0) if printf '%s' "$PROBE_OUT" | jtags | tags_match; then
       aw autoscaling delete-auto-scaling-group --auto-scaling-group-name "$NAME" --force-delete \
         && log "deleting Auto Scaling group $NAME and its instances" || leave "could not delete Auto Scaling group $NAME"
       for _ in $(seq 1 60); do
         left=$(aw autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$NAME" --query 'length(AutoScalingGroups)' --output text 2>/dev/null)
         [ "$left" = 0 ] && break; sleep 10
       done
       [ "$left" = 0 ] || leave "Auto Scaling group $NAME is still being deleted"
     else leave "Auto Scaling group $NAME is not tagged for run $RUN_ID; leaving it"; fi ;;
  1) log "Auto Scaling group $NAME not present" ;;
  *) incomplete=1 ;;
esac

# IAM: the instance profile, on its own tags (whether or not its role is still there), then the roles.
prof="$NAME-instance"
probe 'NoSuchEntity' aws iam get-instance-profile --instance-profile-name "$prof" --query InstanceProfile --output json; rc=$?
case $rc in
  0) if printf '%s' "$PROBE_OUT" | jtags | tags_match; then
       for pr in $(printf '%s' "$PROBE_OUT" | json_get '[x["RoleName"] for x in d.get("Roles") or []]'); do
         aws iam remove-role-from-instance-profile --instance-profile-name "$prof" --role-name "$pr" || leave "could not remove $pr from $prof"
       done
       aws iam delete-instance-profile --instance-profile-name "$prof" && log "deleted instance profile $prof" || leave "could not delete instance profile $prof"
     else leave "instance profile $prof is not tagged for run $RUN_ID; leaving it"; fi ;;
  1) log "instance profile $prof not present" ;;
  *) incomplete=1 ;;
esac
for r in "$NAME-exec" "$NAME-instance"; do
  probe --tags 'NoSuchEntity' aws iam list-role-tags --role-name "$r" --query Tags --output json; rc=$?
  case $rc in
    0) printf '%s' "$PROBE_OUT" | tags_match || { leave "IAM role $r is not tagged for run $RUN_ID; leaving it"; continue; }
       for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text); do
         aws iam delete-role-policy --role-name "$r" --policy-name "$p" || leave "could not delete policy $p of $r"; done
       for a in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text); do
         aws iam detach-role-policy --role-name "$r" --policy-arn "$a" || leave "could not detach $a from $r"; done
       aws iam delete-role --role-name "$r" && log "deleted IAM role $r" || leave "could not delete IAM role $r" ;;
    1) log "IAM role $r not present" ;;
    *) incomplete=1 ;;
  esac
done

# EC2: launch template and security group (after the instances are gone).
probe 'NotFound' aw ec2 describe-launch-templates --launch-template-names "$NAME" --query 'LaunchTemplates[0]' --output json; rc=$?
case $rc in
  0) if printf '%s' "$PROBE_OUT" | jtags | tags_match; then
       blocked aws ec2 delete-launch-template --region "$AWS_REGION" --launch-template-id "$(printf '%s' "$PROBE_OUT" | json_get 'd["LaunchTemplateId"]')"
     else leave "launch template $NAME is not tagged for run $RUN_ID; leaving it"; fi ;;
  1) log "launch template $NAME not present" ;;
  *) incomplete=1 ;;
esac
sg=$(rec IB_SECURITY_GROUP_ID)
if [ -n "$sg" ]; then
  probe 'InvalidGroup.NotFound' aw ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0]' --output json; rc=$?
  case $rc in
    0) printf '%s' "$PROBE_OUT" | jtags | tags_match && blocked aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$sg" \
         || leave "security group $sg is not tagged for run $RUN_ID; leaving it" ;;
    1) log "security group $sg not present" ;;
    *) incomplete=1 ;;
  esac
fi

[ -s "$REMAINING" ] && { echo "Deletes the host may block are listed in order; run them yourself:"; echo "  $REMAINING"; }
[ "$incomplete" = 0 ] || { echo "IMAGE BUILDER CLEAN UP INCOMPLETE: see the warnings above."; exit 1; }
echo "Image Builder prerequisites removed for run $RUN_ID."
