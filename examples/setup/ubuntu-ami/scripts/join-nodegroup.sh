#!/usr/bin/env bash
# join-nodegroup.sh: create a dedicated, tainted EKS managed node group on the verified AMI via a
# launch template, joining the EXISTING cluster named by CLUSTER_NAME. Never touches another node
# group; the taint keeps ordinary workloads off this node.
#
#   AMI_ID=<verified-ami-id> NODE_ROLE_ARN=<arn> scripts/join-nodegroup.sh
#   scripts/join-nodegroup.sh --render-user-data        # print the user data it would use
#   scripts/join-nodegroup.sh --check-user-data FILE    # only run the user-data check on FILE
#
# With a custom AMI in the launch template, EKS does not merge its own user data, and it applies
# the node group's API labels and taints asynchronously after the node registers. So the node's
# labels and taint are set by kubelet itself, deterministically, through Canonical's
# /etc/eks/bootstrap.sh --kubelet-extra-args:
#   --node-labels=eks.amazonaws.com/nodegroup=<NODEGROUP_NAME>   (what deploy/pod-*.yaml select)
#                 eks.amazonaws.com/nitro-sandbox=true          (what the shared isolated-sandbox
#                 sandbox.preview/nitro=true                     RuntimeClass selects; NODE_LABELS)
#   --register-with-taints=sandbox.preview/ubuntu-ami=true:NoSchedule
# The same taint is also set on the node group through the API. The bootstrap also gets the
# cluster's API endpoint, CA and DNS address (Canonical's AMI takes these as arguments). The user
# data is checked (check_user_data) before the launch template is created, and the check fails
# closed when any label or the taint is missing.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

NODEGROUP_NAME="${NODEGROUP_NAME:-${RESOURCE_PREFIX}-ng}"
LT_NAME="${RESOURCE_PREFIX}-lt"
TAINT_KEY=sandbox.preview/ubuntu-ami
TAINT_VALUE=true
[[ "$NODEGROUP_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$ ]] || die "NODEGROUP_NAME is not a valid node group name: $NODEGROUP_NAME"
[[ "$NODE_LABELS" =~ ^[A-Za-z0-9./_-]+=[A-Za-z0-9._-]+(,[A-Za-z0-9./_-]+=[A-Za-z0-9._-]+)*$ ]] || die "NODE_LABELS is not a comma-separated key=value list: $NODE_LABELS"
KUBELET_LABELS="eks.amazonaws.com/nodegroup=${NODEGROUP_NAME},${NODE_LABELS}"
KUBELET_TAINT="${TAINT_KEY}=${TAINT_VALUE}:NoSchedule"

# check_user_data <file>: the rendered user data is a #! script that runs bootstrap.sh with
# --node-labels carrying EVERY required label and --register-with-taints carrying the taint.
check_user_data() { # check_user_data <file>
  local f="$1" bad=0 labels taints want
  [ "$(head -n 1 "$f")" = '#!/bin/bash' ] || { echo "FAIL: user data does not start with #!/bin/bash (cloud-init would not run it)" >&2; bad=1; }
  grep -q '/etc/eks/bootstrap.sh ' "$f" || { echo "FAIL: user data does not run /etc/eks/bootstrap.sh" >&2; bad=1; }
  labels=$(grep -oE -- "--node-labels=[^' ]*" "$f" | head -n 1 | sed 's/^--node-labels=//')
  taints=$(grep -oE -- "--register-with-taints=[^' ]*" "$f" | head -n 1 | sed 's/^--register-with-taints=//')
  for want in ${KUBELET_LABELS//,/ }; do
    [[ ",$labels," == *",$want,"* ]] || { echo "FAIL: user data --node-labels lacks $want (has: ${labels:-<none>})" >&2; bad=1; }
  done
  [[ ",$taints," == *",$KUBELET_TAINT,"* ]] || { echo "FAIL: user data --register-with-taints lacks $KUBELET_TAINT (has: ${taints:-<none>})" >&2; bad=1; }
  return "$bad"
}

if [ "${1:-}" = --check-user-data ]; then
  [ -s "${2:-}" ] || die "usage: join-nodegroup.sh --check-user-data <file>"
  if check_user_data "$2"; then echo "USER DATA OK: $2"; exit 0; else echo "USER DATA REFUSED: $2" >&2; exit 1; fi
fi

# --- Render the user data from the cluster's own endpoint, CA and service CIDR (read only) ------
read -r api_endpoint cluster_ca service_cidr < <(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" \
  --query '[cluster.endpoint,cluster.certificateAuthority.data,cluster.kubernetesNetworkConfig.serviceIpv4Cidr]' --output text)
[[ "$api_endpoint" == https://* && -n "$cluster_ca" && -n "$service_cidr" ]] || die "could not read endpoint, CA and service CIDR of cluster $CLUSTER_NAME"
[[ "$cluster_ca" =~ ^[A-Za-z0-9+/=]+$ ]] || die "cluster CA of $CLUSTER_NAME is not base64"
# EKS puts cluster DNS at the service CIDR's network address + 10 (10.100.0.10, 172.20.0.10).
dns_ip=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1]).network_address + 10)' "$service_cidr")
USER_DATA_FILE="$OUT_DIR/nodegroup-user-data.sh"
cat > "$USER_DATA_FILE" <<UD
#!/bin/bash
set -euo pipefail
/etc/eks/bootstrap.sh '$CLUSTER_NAME' \\
  --apiserver-endpoint '$api_endpoint' \\
  --b64-cluster-ca '$cluster_ca' \\
  --dns-cluster-ip '$dns_ip' \\
  --kubelet-extra-args '--node-labels=$KUBELET_LABELS --register-with-taints=$KUBELET_TAINT'
UD
check_user_data "$USER_DATA_FILE" || die "the rendered user data ($USER_DATA_FILE) is missing a required label or the taint; see the FAIL lines above"

if [ "${1:-}" = --render-user-data ]; then
  cat "$USER_DATA_FILE"
  exit 0
fi
[ $# -eq 0 ] || die "unknown argument: $1 (supported: --render-user-data, --check-user-data <file>)"

: "${AMI_ID:?set AMI_ID to the fresh-instance-verified AMI}"
: "${NODE_ROLE_ARN:?set NODE_ROLE_ARN to the EKS node IAM role (EKS worker, ECR pull, VPC CNI, SSM)}"
read -r -a NODE_SUBNET_ARR <<< "$NODE_SUBNET_IDS"
[[ "${#NODE_SUBNET_ARR[@]}" -gt 0 ]] || die "NODE_SUBNET_IDS is empty; set it in config.env"

lt_data=$(python3 - "$AMI_ID" "${NODE_INSTANCE_TYPE:-m8i.xlarge}" "$USER_DATA_FILE" "$NODEGROUP_NAME" "$TAGS_OWNER_KEY" "$TAGS_OWNER_VALUE" <<'PY'
import base64, json, sys
ami, itype, ud, name, okey, oval = sys.argv[1:]
tags = [{"Key": "Name", "Value": name}, {"Key": okey, "Value": oval}]
print(json.dumps({
    "ImageId": ami,
    "InstanceType": itype,
    "EnclaveOptions": {"Enabled": True},
    "UserData": base64.b64encode(open(ud, "rb").read()).decode(),
    "TagSpecifications": [{"ResourceType": "instance", "Tags": tags}, {"ResourceType": "volume", "Tags": tags}],
}))
PY
)

log "creating launch template $LT_NAME"
lt_id=$(aws ec2 create-launch-template \
  --region "$AWS_REGION" \
  --launch-template-name "$LT_NAME" \
  --launch-template-data "$lt_data" \
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
  --taints "key=${TAINT_KEY},value=${TAINT_VALUE},effect=NO_SCHEDULE" \
  --tags "$(printf '%s=%s' "$TAGS_OWNER_KEY" "$TAGS_OWNER_VALUE")" \
  >/dev/null

log "waiting for node group to become ACTIVE (this can take several minutes)"
aws eks wait nodegroup-active --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME"
log "node group $NODEGROUP_NAME is ACTIVE"
printf '%s\n' "$NODEGROUP_NAME"
