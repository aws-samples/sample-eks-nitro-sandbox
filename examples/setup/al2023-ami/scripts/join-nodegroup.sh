#!/usr/bin/env bash
# join-nodegroup.sh: add one dedicated, tainted managed node group that runs the AL2023 Nitro
# Sandbox AMI to the EXISTING cluster. A custom AMI forces a launch template (EKS does not merge
# its own user data then), which is also where EnclaveOptions.Enabled=true and IMDSv2 hop-limit-1
# go. AL2023 nodes join via a NodeConfig MIME part, NOT an Ubuntu bootstrap.sh.
#
#   RUN_ID=<id> AMI_ID=<ami> NODE_ROLE_ARN=<arn> scripts/join-nodegroup.sh
#   RUN_ID=<id> scripts/join-nodegroup.sh --render-user-data   # print the MIME user data only
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
require_run_id
require_identity RESOURCE_PREFIX CLUSTER_NAME AWS_REGION NAMESPACE
mkdir -p "$RUN_STATE_DIR" "$EVIDENCE_DIR" || die "could not create $EVIDENCE_DIR"

# The AMI is the one the run's build recorded, checked for this run's tags and NODE_ARCH.
resolve_run_ami

# --- Render the AL2023 NodeConfig MIME user data from the cluster's own endpoint/CA/CIDR ------
read -r endpoint ca cidr < <(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --output json \
  | json_get '[d["cluster"]["endpoint"], d["cluster"]["certificateAuthority"]["data"], d["cluster"].get("kubernetesNetworkConfig",{}).get("serviceIpv4Cidr","")]' | paste -sd' ')
[ -n "$endpoint" ] && [ -n "$ca" ] || die "could not read cluster $CLUSTER_NAME endpoint/CA"
[ -n "$cidr" ] || die "cluster $CLUSTER_NAME reports no serviceIpv4Cidr (an IPv6 cluster?); this blueprint supports IPv4 clusters only"

USER_DATA_FILE="$RUN_STATE_DIR/nodegroup-user-data.mime"
mkdir -p "$RUN_STATE_DIR"
sed -e "s|@CLUSTER_NAME@|$CLUSTER_NAME|g" \
    -e "s|@API_SERVER@|$endpoint|g" \
    -e "s|@CLUSTER_CA@|$ca|g" \
    -e "s|@SERVICE_CIDR@|$cidr|g" \
    "$SAMPLE_DIR/deploy/nodegroup-user-data.mime.tmpl" > "$USER_DATA_FILE"
grep -q '@[A-Z_]*@' "$USER_DATA_FILE" && die "unrendered placeholder left in $USER_DATA_FILE"

if [ "${1:-}" = --render-user-data ]; then cat "$USER_DATA_FILE"; exit 0; fi
: "${NODE_ROLE_ARN:?set NODE_ROLE_ARN to the EKS node IAM role (EKS worker, ECR pull, VPC CNI, SSM)}"
: "${NODE_SUBNET_IDS:?set NODE_SUBNET_IDS (space-separated PRIVATE subnets) in config.env}"
read -r -a NODE_SUBNET_ARR <<< "$NODE_SUBNET_IDS"
[ "${#NODE_SUBNET_ARR[@]}" -gt 0 ] || die "NODE_SUBNET_IDS is empty"

# Fail fast on a known trap: an EKS node gets no public IP by default, so a node group in a
# PUBLIC subnet (one whose route table has a 0.0.0.0/0 route to an internet gateway, not a NAT)
# never registers and the node group hangs in CREATING with no instances. Check each subnet's
# default route points at a NAT gateway, and stop with a clear message otherwise.
for sn in "${NODE_SUBNET_ARR[@]}"; do
  rt=$(aws ec2 describe-route-tables --region "$AWS_REGION" \
        --filters "Name=association.subnet-id,Values=$sn" \
        --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].[GatewayId,NatGatewayId]' \
        --output text 2>/dev/null)
  # If the subnet has no explicit association, AWS uses the VPC main route table; check that too.
  if [ -z "$rt" ]; then
    vpc=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$sn" --query 'Subnets[0].VpcId' --output text 2>/dev/null)
    rt=$(aws ec2 describe-route-tables --region "$AWS_REGION" \
          --filters "Name=vpc-id,Values=$vpc" "Name=association.main,Values=true" \
          --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].[GatewayId,NatGatewayId]' \
          --output text 2>/dev/null)
  fi
  case "$rt" in
    *nat-*) : ;;  # default route via a NAT gateway: a private subnet, good
    *igw-*) die "NODE_SUBNET_IDS contains a PUBLIC subnet ($sn): its default route goes to an internet gateway, not a NAT. EKS nodes get no public IP by default, so a node group here hangs in CREATING forever. Use private subnets with a NAT route (see config.env)." ;;
    *) warn "could not determine the default route of subnet $sn; if the node group hangs in CREATING with no instances, it is probably a public subnet without a NAT route (see NODEGROUP-DIAGNOSIS)." ;;
  esac
done

# --- Render + check the launch template data, then create it exactly as checked --------------
LT_DATA="$RUN_STATE_DIR/nodegroup-launch-template.json"
launch_spec render-lt --name "$NODEGROUP_NAME" --image-id "$AMI_ID" --instance-type "$NODE_INSTANCE_TYPE" \
  --user-data-file "$USER_DATA_FILE" > "$LT_DATA"
launch_spec check-lt "$LT_DATA" || die "launch template data $LT_DATA failed its check (EnclaveOptions/IMDSv2/tags)"

log "creating launch template $LT_NAME"
lt_id=$(aws ec2 create-launch-template --region "$AWS_REGION" --launch-template-name "$LT_NAME" \
  --launch-template-data "file://$LT_DATA" \
  --tag-specifications "ResourceType=launch-template,Tags=[$(run_tags_cli)]" \
  --output json | json_get 'd["LaunchTemplate"]["LaunchTemplateId"]')
[ -n "$lt_id" ] || die "create-launch-template returned no id"

log "creating managed node group $NODEGROUP_NAME on cluster $CLUSTER_NAME"
aws eks create-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODEGROUP_NAME" --node-role "$NODE_ROLE_ARN" \
  --subnets "${NODE_SUBNET_ARR[@]}" \
  --scaling-config "minSize=${NODE_COUNT},maxSize=${NODE_COUNT},desiredSize=${NODE_COUNT}" \
  --launch-template "id=$lt_id" \
  --taints "key=${TAINT_KEY},value=${TAINT_VALUE},effect=NO_SCHEDULE" \
  --tags "${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE},${TAGS_RUN_KEY}=${RUN_ID},auto-delete=no" \
  --output json >/dev/null

log "waiting for node group to become ACTIVE (several minutes)"
aws eks wait nodegroup-active --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME"
log "node group $NODEGROUP_NAME is ACTIVE"
printf 'NODEGROUP_NAME=%s\nNODEGROUP_LT=%s\n' "$NODEGROUP_NAME" "$lt_id" >> "$EVIDENCE_DIR/run-evidence.env"
printf '%s\n' "$NODEGROUP_NAME"
