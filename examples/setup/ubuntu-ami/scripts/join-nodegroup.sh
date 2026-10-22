#!/usr/bin/env bash
# join-nodegroup.sh: create a dedicated, tainted EKS managed node group on the verified AMI
# via a launch template, joining the EXISTING cluster named by CLUSTER_NAME. Never touches
# another node group; the taint keeps ordinary workloads off this node.
#
#   AMI_ID=<verified-ami-id> join-nodegroup.sh
#
# The launch template's user data runs Canonical's own EKS bootstrap (/etc/eks/bootstrap.sh,
# patched by scripts/31-wire-containerd.sh on the build host) with no extra containerd or
# kubelet configuration layered on here: the AMI already carries everything the node needs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

: "${AMI_ID:?set AMI_ID to the fresh-instance-verified AMI}"
: "${NODE_ROLE_ARN:?set NODE_ROLE_ARN to the EKS node IAM role (EKS worker, ECR pull, VPC CNI, SSM)}"

NODEGROUP_NAME="${NODEGROUP_NAME:-${RESOURCE_PREFIX}-ng}"
LT_NAME="${RESOURCE_PREFIX}-lt"

read -r -a NODE_SUBNET_ARR <<< "$NODE_SUBNET_IDS"
[[ "${#NODE_SUBNET_ARR[@]}" -gt 0 ]] || die "NODE_SUBNET_IDS is empty; set it in config.env"

USER_DATA_B64=$(printf '%s' "/etc/eks/bootstrap.sh $CLUSTER_NAME" | base64 -w0)

log "creating launch template $LT_NAME"
lt_id=$(aws ec2 create-launch-template \
  --region "$AWS_REGION" \
  --launch-template-name "$LT_NAME" \
  --launch-template-data "{
    \"ImageId\": \"$AMI_ID\",
    \"InstanceType\": \"${NODE_INSTANCE_TYPE:-m8i.xlarge}\",
    \"EnclaveOptions\": {\"Enabled\": true},
    \"UserData\": \"$USER_DATA_B64\",
    \"TagSpecifications\": [
      {\"ResourceType\": \"instance\", \"Tags\": [{\"Key\": \"Name\", \"Value\": \"$NODEGROUP_NAME\"}, {$(ownership_tag_cli)}]},
      {\"ResourceType\": \"volume\",   \"Tags\": [{\"Key\": \"Name\", \"Value\": \"$NODEGROUP_NAME\"}, {$(ownership_tag_cli)}]}
    ]
  }" \
  --tag-specifications "ResourceType=launch-template,Tags=[{$(ownership_tag_cli)}]" \
  --query 'LaunchTemplate.LaunchTemplateId' --output text)
log "launch template: $lt_id"

log "creating managed node group $NODEGROUP_NAME on cluster $CLUSTER_NAME"
aws eks create-nodegroup \
  --region "$AWS_REGION" \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODEGROUP_NAME" \
  --node-role "$NODE_ROLE_ARN" \
  --subnets "${NODE_SUBNET_ARR[@]}" \
  --scaling-config "minSize=${NODE_COUNT:-1},maxSize=${NODE_COUNT:-1},desiredSize=${NODE_COUNT:-1}" \
  --launch-template "id=$lt_id" \
  --taints "key=sandbox.preview/ubuntu-ami,value=true,effect=NO_SCHEDULE" \
  --tags "$(printf '%s=%s' "$TAGS_OWNER_KEY" "$TAGS_OWNER_VALUE")" \
  >/dev/null

log "waiting for node group to become ACTIVE (this can take several minutes)"
aws eks wait nodegroup-active --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME"
log "node group $NODEGROUP_NAME is ACTIVE"
printf '%s\n' "$NODEGROUP_NAME"
