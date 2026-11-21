#!/usr/bin/env bash
# Create a dedicated EKS 1.36 cluster whose only CNI is Cilium (ENI mode, kube-proxy
# replacement), add one stock Bottlerocket system node, build the sandbox node AMI with Packer,
# add exactly one Bottlerocket sandbox node on it, check that node, and apply the workloads.
#
#   ./setup.sh                          a new run (a new run ID)
#   RUN_ID=<id> ./setup.sh              resume that run after the last stage it finished
#   ./setup.sh --stop-after <stage>     stop after one stage (resume later with RUN_ID)
#
# Stages, in the order of issue #281: preflight, cluster, cilium, system-node, ami,
# sandbox-node, node-checks, workloads. Each stage records STAGE_DONE in the state file of the
# run. The sample never changes a cluster that it did not create. Each refusal prints
# "ERROR: E_<TAG>: <text>" and stops the run.
# shellcheck source=../../../scripts/lib/require-bash.sh
. "$(dirname "$0")/../../../scripts/lib/require-bash.sh"
set -euo pipefail
SAMPLE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SAMPLE_DIR/scripts/common.sh"

STAGES=(preflight cluster cilium system-node ami sandbox-node node-checks workloads)
stop_after=""
case "${1:-}" in
  --stop-after)
    stop_after="${2:-}"
    [[ " ${STAGES[*]} " == *" $stop_after "* ]] || die E_USAGE "--stop-after needs one of: ${STAGES[*]}" ;;
  "") ;;
  *) die E_USAGE "usage: ./setup.sh [--stop-after <stage>]" ;;
esac
CB_BUILD_AMI_CMD="${CB_BUILD_AMI_CMD:-$SAMPLE_DIR/scripts/10-build-ami-packer.sh}"
TRIES="${CB_WAIT_TRIES:-60}"
DEPLOY="$SAMPLE_DIR/deploy"
WORKLOAD_PODS=(cb-server cb-sandbox cb-sandbox-isolated cb-ordinary-sandbox-node cb-ordinary-system-node)

stage_index() { local i; for i in "${!STAGES[@]}"; do [[ "${STAGES[$i]}" == "$1" ]] && { echo "$i"; return; }; done; echo -1; }
# should_run <stage>: 0 when the stage comes after the last finished one.
should_run() {
  local done_stage
  done_stage="$(state_get STAGE_DONE)" || die E_STATE "could not read $RUN_STATE_FILE"
  (( $(stage_index "$1") > $(stage_index "${done_stage:-none}") ))
}
finish() {
  state_set STAGE_DONE "$1"
  if [[ "$1" == "$stop_after" ]]; then
    printf '\nStopped after stage %s. Resume with: RUN_ID=%s ./setup.sh\n' "$1" "$RUN_ID"
    exit 0
  fi
}
ensure_namespace() {
  local rc=0
  namespace_is_ours || rc=$?
  case "$rc" in
    0) ;;
    3) kc create -f "$DEPLOY/namespace.yaml" >/dev/null || die E_NAMESPACE "could not create namespace $NAMESPACE" ;;
    1) die E_NAMESPACE_OWNER "namespace $NAMESPACE exists without $NS_LABEL_KEY=$NS_LABEL_VAL; it is not this sample's" ;;
    *) die E_NAMESPACE "could not read namespace $NAMESPACE" ;;
  esac
}
# one_node <group>: the name of the one node of a node group; stops on zero or more than one.
one_node() {
  local names
  names="$(kc get nodes -l "eks.amazonaws.com/nodegroup=$1" -o jsonpath='{.items[*].metadata.name}')" \
    || die E_NODE_READ "could not list the nodes of node group $1"
  read -r -a arr <<<"$names"
  ((${#arr[@]} == 1)) || die E_NODE_COUNT "node group $1 has ${#arr[@]} nodes, want exactly 1"
  printf '%s\n' "${arr[0]}"
}
has_nodes() { [[ -n "$(kc get nodes -l "eks.amazonaws.com/nodegroup=$1" -o name 2>/dev/null)" ]]; }
cilium_agent_ready() { # cilium_agent_ready <node>
  local ready
  ready="$(kc -n kube-system get pods -l k8s-app=cilium --field-selector "spec.nodeName=$1" \
    -o jsonpath='{.items[*].status.containerStatuses[*].ready}')" || return 1
  [[ -n "$ready" && "$ready" != *false* ]]
}

# ---------------------------------------------------------------------------
step "1/8 preflight: tools, versions, account, Region, quota and names"
require_tool_versions
require_region
python3 "$PY" check-config
python3 "$PY" check-cilium-values
python3 "$PY" check-manifests
echo "Cilium $CILIUM_VERSION, chart $CILIUM_CHART (cilium.lock)"
rc=0; "$CB_BUILD_AMI_CMD" check-tools || rc=$?
((rc == 0)) || die E_AMI_TOOLS "Packer or its Amazon plugin did not pass the pin and signature check (exit $rc)"
require_caller_account
if [[ -n "${RUN_ID:-}" ]]; then
  require_run_id
  check_run_record
  echo "Resuming run $RUN_ID after stage $(state_get STAGE_DONE)"
  # A --stop-after stage that the run already finished would not stop the run: it would go on
  # into the next stage (for example the AMI build). Refuse it before anything runs.
  if [[ -n "$stop_after" ]] && (( $(stage_index "$stop_after") <= $(stage_index "$(state_get STAGE_DONE)") )); then
    die E_USAGE "run $RUN_ID already finished stage $stop_after (STAGE_DONE=$(state_get STAGE_DONE)); --stop-after must name a later stage"
  fi
else
  reserve_run
  echo "New run $RUN_ID, state file $RUN_STATE_FILE"
fi
lock_run
if should_run preflight; then
  python3 "$PY" quota
  python3 "$PY" check-names
  enclave="$(aws ec2 describe-instance-types --region "$AWS_REGION" --instance-types "$SANDBOX_INSTANCE_TYPE" \
    --query 'InstanceTypes[0].NitroEnclavesSupport' --output text)" || die E_ENCLAVE_TYPE "could not read $SANDBOX_INSTANCE_TYPE"
  [[ "$enclave" == supported ]] || die E_ENCLAVE_TYPE "$SANDBOX_INSTANCE_TYPE does not support Nitro Enclaves (got '$enclave')"
  if [[ -z "$SYSTEM_AMI_ID" ]]; then
    SYSTEM_AMI_ID="$(python3 "$PY" resolve-system-ami)"
    export SYSTEM_AMI_ID
    python3 "$PY" check-system-ami
    printf '\n# Recorded by setup.sh from %s (%s).\nSYSTEM_AMI_ID="%s"\n' \
      "$SYSTEM_AMI_SSM_PARAMETER" "$SYSTEM_AMI_NAME" "$SYSTEM_AMI_ID" >>"$CB_LOCAL_CONFIG" \
      || die E_LOCAL_CONFIG "could not record SYSTEM_AMI_ID in $CB_LOCAL_CONFIG"
  else
    python3 "$PY" check-system-ami
  fi
  state_set SYSTEM_AMI_ID "$SYSTEM_AMI_ID"
  finish preflight
fi

# ---------------------------------------------------------------------------
if should_run cluster; then
  step "2/8 cluster: Kubernetes $KUBERNETES_VERSION, its own VPC, no aws-node, no kube-proxy, no nodes"
  python3 "$PY" render-cluster >/dev/null
  if [[ "$(cluster_state)" == NONE ]]; then
    eksctl create cluster -f "$RUN_STATE_DIR/cluster.yaml" --without-nodegroup --write-kubeconfig=false
  else
    require_sample_cluster
    aws eks wait cluster-active --region "$AWS_REGION" --name "$CLUSTER_NAME"
  fi
  require_sample_cluster
fi
# The kube context of this run, in its own kubeconfig. Never ~/.kube/config, never use-context.
if (( $(stage_index "$(state_get STAGE_DONE)") >= $(stage_index preflight) )) && [[ "$(cluster_state)" != NONE ]]; then
  endpoint="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --query cluster.endpoint --output text)"
  [[ "$endpoint" =~ ^https://[A-Za-z0-9.-]+$ ]] || die E_CLUSTER_READ "could not read the endpoint of $CLUSTER_NAME"
  state_set CLUSTER_ENDPOINT "$endpoint"
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG" \
    --alias "$KUBE_CONTEXT" >/dev/null
  chmod 600 "$KUBECONFIG"
  require_kube_context
fi
if should_run cluster; then
  vpc="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --query cluster.resourcesVpcConfig.vpcId --output text)"
  [[ "$vpc" =~ ^vpc-[0-9a-f]+$ ]] || die E_CLUSTER_READ "could not read the VPC of $CLUSTER_NAME"
  state_set VPC_ID "$vpc"
  state_set CLUSTER_SG_ID "$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" \
    --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)"
  private="$(aws ec2 describe-subnets --region "$AWS_REGION" --filters "Name=vpc-id,Values=$vpc" \
    "Name=map-public-ip-on-launch,Values=false" --query 'Subnets[].[AvailabilityZone,SubnetId]' --output text)" \
    || die E_SUBNET_READ "could not read the subnets of $vpc"
  state_set PRIVATE_SUBNET_IDS "$(awk '{print $2}' <<<"$private" | sort | tr '\n' ' ' | sed 's/ $//')"
  read -r -a zones <<<"$AVAILABILITY_ZONES"
  build_subnet="$(awk -v z="${zones[0]}" '$1 == z {print $2}' <<<"$private")"
  [[ "$build_subnet" =~ ^subnet-[0-9a-f]+$ ]] || die E_SUBNET_READ "no single private subnet in ${zones[0]} (got '$build_subnet')"
  state_set BUILD_SUBNET_ID "$build_subnet"
  addons="$(aws eks list-addons --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --query addons --output text)" \
    || die E_ADDON_READ "could not list the add-ons of $CLUSTER_NAME"
  addons="${addons//$'\t'/ }"   # the text output separates the names with tabs
  [[ " $addons " != *" vpc-cni "* && " $addons " != *" kube-proxy "* ]] \
    || die E_CNI_PRESENT "cluster $CLUSTER_NAME has the vpc-cni or kube-proxy add-on: $addons"
  ds="$(kc -n kube-system get daemonset aws-node kube-proxy --ignore-not-found -o name)" \
    || die E_CNI_PRESENT "could not read the DaemonSets of kube-system"
  [[ -z "$ds" ]] || die E_CNI_PRESENT "kube-system has $ds"
  echo "No aws-node and no kube-proxy: add-ons are '$addons'; kube-system has no aws-node or kube-proxy DaemonSet."
  finish cluster
fi

# ---------------------------------------------------------------------------
if should_run cilium; then
  step "3/8 the Pod Identity role of the Cilium operator, then Cilium $CILIUM_VERSION before any node"
  python3 "$PY" render-pod-identity >/dev/null
  assoc="$(aws eks list-pod-identity-associations --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
    --namespace kube-system --service-account cilium-operator --query 'associations[].associationId' --output text)"
  [[ -n "$assoc" ]] || eksctl create podidentityassociation -f "$RUN_STATE_DIR/pod-identity.yaml"
  assoc="$(aws eks list-pod-identity-associations --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
    --namespace kube-system --service-account cilium-operator --query 'associations[].associationId' --output text)"
  [[ "$assoc" =~ ^a-[a-z0-9]+$ ]] || die E_POD_IDENTITY "expected one Pod Identity association for kube-system/cilium-operator, got '$assoc'"
  state_set POD_IDENTITY_ASSOCIATION_ID "$assoc"
  state_set OPERATOR_ROLE_NAME "$OPERATOR_ROLE_NAME"
  python3 "$PY" check-operator-role
  endpoint="$(state_need CLUSTER_ENDPOINT)"
  hc upgrade --install cilium "$CILIUM_CHART" --version "$CILIUM_VERSION" --namespace kube-system \
    -f "$SAMPLE_DIR/cilium-values.yaml" --set "cluster.name=$CLUSTER_NAME" \
    --set "k8sServiceHost=${endpoint#https://}" --set "eni.eniTags.RunId=$RUN_ID"
  kc -n kube-system get daemonset cilium -o json | python3 "$PY" preflight-daemonset
  finish cilium
fi

# ---------------------------------------------------------------------------
if should_run system-node; then
  step "4/8 the system node: stock Bottlerocket $BOTTLEROCKET_RELEASE aws-k8s-1.36, then the Cilium operator"
  lt="$(python3 "$PY" launch-template system | tail -n1)"
  [[ "$lt" =~ ^lt-[0-9a-f]{17}$ ]] || die E_LAUNCH_TEMPLATE "could not create or read the system launch template (got '$lt')"
  state_set SYSTEM_LAUNCH_TEMPLATE_ID "$lt"
  aws ec2 describe-launch-template-versions --region "$AWS_REGION" --launch-template-id "$lt" --versions 1 \
    --output json >"$RUN_STATE_DIR/lt-system-v1.json"
  python3 "$PY" check-user-data system "$RUN_STATE_DIR/lt-system-v1.json"
  python3 "$PY" render-nodegroup system >/dev/null
  aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name system >/dev/null 2>&1 \
    || eksctl create nodegroup -f "$RUN_STATE_DIR/nodegroups-system.yaml"
  wait_until "$TRIES" "a system node" has_nodes system \
    || die E_NODE_COUNT "no system node registered"
  kc wait --for=condition=Ready node -l eks.amazonaws.com/nodegroup=system --timeout=20m
  system_node="$(one_node system)"
  state_set SYSTEM_NODE "$system_node"
  kc -n kube-system rollout status daemonset/cilium --timeout=10m
  kc -n kube-system rollout status deployment/cilium-operator --timeout=10m
  kc get node "$system_node" -o json >"$RUN_STATE_DIR/node-system.json"
  python3 "$PY" check-os-image system "$RUN_STATE_DIR/node-system.json"
  python3 "$PY" check-operator-role
  ensure_namespace
  probe="$(probe_name system)"
  probe_start "$probe" "$system_node"
  probe_capture "$probe" "$EVIDENCE_DIR/probe-system"
  probe_stop "$probe"
  python3 "$PY" check-btf "$EVIDENCE_DIR/probe-system/btf.txt"
  # Tag what AWS made for the cluster and the system node group with no tag, then audit every
  # class, so the run is fully tagged before the AMI build. Stage node-checks does it again for
  # the sandbox node group.
  python3 "$PY" tag-sweep
  python3 "$PY" audit-tags
  echo "The system node $system_node and the Cilium operator are healthy. The AMI build can start."
  finish system-node
fi

# ---------------------------------------------------------------------------
if should_run ami; then
  step "5/8 the sandbox AMI: Packer amazon-ebssurrogate, communicator none, in the private subnet"
  if [[ "$(state_get AMI_BUILD_RESULT)" == ok ]]; then
    echo "Run $RUN_ID already built $(state_get SANDBOX_AMI_ID)."
  elif [[ -n "$REUSE_SANDBOX_AMI_ID" ]]; then
    python3 "$PY" check-sandbox-ami --reuse --ami "$REUSE_SANDBOX_AMI_ID"
    state_set SANDBOX_AMI_ID "$REUSE_SANDBOX_AMI_ID"
    state_set AMI_REUSED yes
  else
    export BUILD_INSTANCE_TYPE BUILD_WORK_VOLUME_GIB AMI_WAIT_SECONDS SANDBOX_SLOTS
    rc=0; "$CB_BUILD_AMI_CMD" build || rc=$?
    ((rc == 0)) || die E_AMI_BUILD "the AMI build did not finish (exit $rc); run ./clean.sh --dry-run, then ./clean.sh"
    [[ "$(state_get AMI_BUILD_RESULT)" == ok ]] || die E_AMI_BUILD "the AMI build exited 0 without AMI_BUILD_RESULT=ok"
  fi
  [[ "$(state_get AMI_REUSED)" == yes ]] || {
    python3 "$PY" check-sandbox-ami
    python3 "$PY" builder-gone
  }
  finish ami
fi

# ---------------------------------------------------------------------------
if should_run sandbox-node; then
  step "6/8 the sandbox node group: exactly one node on the built AMI, Nitro Enclaves on"
  ami="$(state_need SANDBOX_AMI_ID)"
  aws ec2 describe-images --region "$AWS_REGION" --image-ids "$ami" --output json >"$RUN_STATE_DIR/sandbox-ami.json"
  python3 "$PY" check-density --ami-tags "$RUN_STATE_DIR/sandbox-ami.json"
  lt="$(python3 "$PY" launch-template sandbox | tail -n1)"
  [[ "$lt" =~ ^lt-[0-9a-f]{17}$ ]] || die E_LAUNCH_TEMPLATE "could not create or read the sandbox launch template (got '$lt')"
  state_set SANDBOX_LAUNCH_TEMPLATE_ID "$lt"
  aws ec2 describe-launch-template-versions --region "$AWS_REGION" --launch-template-id "$lt" --versions 1 \
    --output json >"$RUN_STATE_DIR/lt-sandbox-v1.json"
  python3 "$PY" check-user-data sandbox "$RUN_STATE_DIR/lt-sandbox-v1.json"
  python3 "$PY" check-density --launch-template "$RUN_STATE_DIR/lt-sandbox-v1.json"
  python3 "$PY" render-nodegroup sandbox >/dev/null
  aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name sandbox >/dev/null 2>&1 \
    || eksctl create nodegroup -f "$RUN_STATE_DIR/nodegroups-sandbox.yaml"
  wait_until "$TRIES" "a sandbox node" has_nodes sandbox \
    || die E_NODE_COUNT "no sandbox node registered"
  kc wait --for=condition=Ready node -l eks.amazonaws.com/nodegroup=sandbox --timeout=20m
  sandbox_node="$(one_node sandbox)"
  state_set SANDBOX_NODE "$sandbox_node"
  kc -n kube-system rollout status daemonset/cilium --timeout=10m
  wait_until "$TRIES" "the Cilium agent on $sandbox_node" cilium_agent_ready "$sandbox_node" \
    || die E_CILIUM_AGENT "the Cilium agent on $sandbox_node is not Ready"
  echo "Exactly one sandbox node joined: $sandbox_node"
  finish sandbox-node
fi

# ---------------------------------------------------------------------------
if should_run node-checks; then
  step "7/8 the sandbox node checks, before any sandbox pod starts"
  sandbox_node="$(state_need SANDBOX_NODE)"
  d="$EVIDENCE_DIR/probe-sandbox"
  kc get node "$sandbox_node" -o json >"$RUN_STATE_DIR/node-sandbox.json"
  kc get --raw "/api/v1/nodes/$sandbox_node/proxy/configz" >"$RUN_STATE_DIR/configz-sandbox.json"
  ensure_namespace
  probe="$(probe_name sandbox)"
  probe_start "$probe" "$sandbox_node"
  probe_capture "$probe" "$d"
  probe_stop "$probe"
  python3 "$PY" check-os-image sandbox "$RUN_STATE_DIR/node-sandbox.json"
  python3 "$PY" check-btf "$d/btf.txt"
  python3 "$PY" check-mempool --cmdline "$d/cmdline.txt" --kernel-log "$d/kernel.log"
  python3 "$PY" check-runtime-endpoint "$RUN_STATE_DIR/configz-sandbox.json"
  python3 "$PY" check-containerd-dump "$d/containerd-dump.toml"
  python3 "$PY" check-allocatable "$RUN_STATE_DIR/node-sandbox.json"
  python3 "$PY" check-density --node "$RUN_STATE_DIR/node-sandbox.json" --shim-toml "$d/nitro-sandbox.toml"
  python3 "$PY" check-selinux-mode "$d/selinux-enforce.txt"
  python3 "$PY" check-dm-verity "$d/dm-verity.txt"
  # Tag what AWS made for the cluster and the node groups with no tag, then audit every class.
  python3 "$PY" tag-sweep
  python3 "$PY" audit-tags --after-build
  finish node-checks
fi

# ---------------------------------------------------------------------------
if should_run workloads; then
  step "8/8 the isolated-sandbox RuntimeClass, the pods and the ClusterIP Service"
  rc_json="$(kc get runtimeclass isolated-sandbox --ignore-not-found -o json)" || die E_RUNTIMECLASS "could not read the RuntimeClass"
  if [[ -z "$rc_json" ]]; then
    python3 "$PY" runtimeclass | kc create -f - >/dev/null
    rc_json="$(kc get runtimeclass isolated-sandbox -o json)" || die E_RUNTIMECLASS "could not read the RuntimeClass back"
  fi
  python3 "$PY" check-runtimeclass <<<"$rc_json"
  ensure_namespace
  for f in "$DEPLOY"/*.yaml; do
    [[ "$f" == "$DEPLOY/namespace.yaml" ]] || kc apply -n "$NAMESPACE" -f "$f"
  done
  kc -n "$NAMESPACE" wait --for=condition=Ready "${WORKLOAD_PODS[@]/#/pod/}" --timeout=10m
  finish workloads
fi

printf '\nRun %s is ready. Next: RUN_ID=%s ./test.sh\n' "$RUN_ID" "$RUN_ID"
cat <<EOF
The cluster bills while it exists (EKS control plane, two EC2 instances, one NAT gateway, one
public IPv4 address, EBS volumes, and the AMI snapshots). Run ./clean.sh when you are done.
EOF
