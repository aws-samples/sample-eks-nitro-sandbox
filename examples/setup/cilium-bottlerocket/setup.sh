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
# On any exit, also an interrupt, delete the probe pods that this run started and did not delete.
trap probe_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
# nodegroup_status <group>: the EKS status of the node group of this cluster, or NONE when EKS
# reports no node group of that name. Any other read error stops the run.
nodegroup_status() {
  local out
  if out="$(aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$1" \
    --query nodegroup.status --output text 2>&1)"; then
    printf '%s\n' "$out"
  elif grep -Eq '^(aws: \[ERROR\]: )?An error occurred \(ResourceNotFoundException\)' <<<"$out"; then
    printf 'NONE\n'
  else
    die E_NODEGROUP_READ "could not read node group $1 of $CLUSTER_NAME: $out"
  fi
}
nodegroup_active() { [[ "$(nodegroup_status "$1")" == ACTIVE ]]; }
# ensure_nodegroup <group>: create the node group only when EKS has none of that name, and wait
# for one that is CREATING or UPDATING. Any other status (CREATE_FAILED, DEGRADED, DELETING,
# DELETE_FAILED) stops the run: setup.sh never creates over a failed node group.
ensure_nodegroup() {
  local status
  status="$(nodegroup_status "$1")"
  if [[ "$status" == NONE ]]; then
    eksctl create nodegroup -f "$RUN_STATE_DIR/nodegroups-$1.yaml" \
      || die E_NODEGROUP_CREATE "eksctl create nodegroup $1 failed; read the events of stack eksctl-$CLUSTER_NAME-nodegroup-$1, then run RUN_ID=$RUN_ID ./setup.sh again, or ./clean.sh --dry-run"
    status="$(nodegroup_status "$1")"
  fi
  case "$status" in
    ACTIVE) ;;
    CREATING | UPDATING)
      wait_until "$TRIES" "node group $1 ACTIVE" nodegroup_active "$1" \
        || die E_NODEGROUP_STATE "node group $1 did not become ACTIVE (status $(nodegroup_status "$1"))" ;;
    *) die E_NODEGROUP_STATE "node group $1 is $status; read its health issues with aws eks describe-nodegroup --nodegroup-name $1, then run ./clean.sh --dry-run" ;;
  esac
}
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
# The slot count of the run: the AMI build, max-pods and test.sh use the value in the state file.
# A run records it once; a resume with another SANDBOX_SLOTS in the config stops.
slots="$(state_get SANDBOX_SLOTS)" || die E_STATE "could not read $RUN_STATE_FILE"
if [[ -z "$slots" ]]; then
  state_set SANDBOX_SLOTS "$SANDBOX_SLOTS"
elif [[ "$slots" != "$SANDBOX_SLOTS" ]]; then
  die E_SANDBOX_SLOTS "run $RUN_ID uses SANDBOX_SLOTS=$slots, but the config has SANDBOX_SLOTS=$SANDBOX_SLOTS; restore $slots in the config, or start a new run"
fi
# The source of each setup.sh run, one line per run, in the run folder: the commit of the
# checkout, and dirty=yes when a tracked file of the sample differs from it (untracked files are
# not counted). Outside a git checkout both are "unknown".
commit="$(git -C "$SAMPLE_DIR" rev-parse HEAD 2>/dev/null)" || commit=unknown
dirty=unknown
if changes="$(git -C "$SAMPLE_DIR" status --porcelain --untracked-files=no -- . 2>/dev/null)"; then
  if [[ -n "$changes" ]]; then dirty=yes; else dirty=no; fi
fi
printf 'time=%s stage_done=%s commit=%s dirty=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$(state_get STAGE_DONE)" "$commit" "$dirty" >>"$RUN_STATE_DIR/source.log" \
  || die E_RUN_DIR "could not write $RUN_STATE_DIR/source.log"
echo "Source: commit $commit, dirty=$dirty (recorded in $RUN_STATE_DIR/source.log)"
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
# max-pods of each node group, derived from its instance type (ec2 describe-instance-types:
# ENIs x (IPv4 per ENI - 1) + 2), never set by hand. A run records each value once
# (MAX_PODS_SYSTEM, MAX_PODS_SANDBOX); a resume whose instance type gives another value stops.
for group in system sandbox; do
  type_var="${group^^}_INSTANCE_TYPE"
  derived="$(python3 "$PY" derive-max-pods "${!type_var}")" \
    || die E_MAX_PODS "could not derive max-pods of the $group node from ${!type_var} (see the error above)"
  recorded="$(state_get "MAX_PODS_${group^^}")" || die E_STATE "could not read $RUN_STATE_FILE"
  if [[ -z "$recorded" ]]; then
    state_set "MAX_PODS_${group^^}" "$derived"
  elif [[ "$recorded" != "$derived" ]]; then
    die E_MAX_PODS "run $RUN_ID uses max-pods $recorded on the $group node, but ${!type_var} gives $derived; restore the instance type, or start a new run"
  fi
  echo "max-pods of the $group node: $derived (${!type_var})"
done
mp_system="$(state_need MAX_PODS_SYSTEM)"
mp_sandbox="$(state_need MAX_PODS_SANDBOX)"

# ---------------------------------------------------------------------------
if should_run cluster; then
  step "2/8 cluster: Kubernetes $KUBERNETES_VERSION, its own VPC, no aws-node, no kube-proxy, no nodes"
  python3 "$PY" render-cluster >/dev/null
  if [[ "$(cluster_state)" == NONE ]]; then
    eksctl create cluster -f "$RUN_STATE_DIR/cluster.yaml" --without-nodegroup --write-kubeconfig=false \
      || die E_CLUSTER_CREATE "eksctl create cluster failed; read the events of stack eksctl-$CLUSTER_NAME-cluster, then run ./clean.sh --run-id $RUN_ID --dry-run"
  else
    require_sample_cluster
    aws eks wait cluster-active --region "$AWS_REGION" --name "$CLUSTER_NAME" \
      || die E_CLUSTER_STATE "cluster $CLUSTER_NAME did not become ACTIVE"
  fi
  require_sample_cluster
fi
# The kube context of this run, in its own kubeconfig. Never ~/.kube/config, never use-context.
if (( $(stage_index "$(state_get STAGE_DONE)") >= $(stage_index preflight) )) && [[ "$(cluster_state)" != NONE ]]; then
  endpoint="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --query cluster.endpoint --output text)" \
    || die E_CLUSTER_READ "could not read the endpoint of $CLUSTER_NAME"
  [[ "$endpoint" =~ ^https://[A-Za-z0-9.-]+$ ]] || die E_CLUSTER_READ "could not read the endpoint of $CLUSTER_NAME"
  state_set CLUSTER_ENDPOINT "$endpoint"
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG" \
    --alias "$KUBE_CONTEXT" >/dev/null || die E_KUBECONFIG "could not write the kubeconfig of the run, $KUBECONFIG"
  chmod 600 "$KUBECONFIG" || die E_KUBECONFIG "could not make $KUBECONFIG private"
  require_kube_context
fi
if should_run cluster; then
  vpc="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --query cluster.resourcesVpcConfig.vpcId --output text)" \
    || die E_CLUSTER_READ "could not read the VPC of $CLUSTER_NAME"
  [[ "$vpc" =~ ^vpc-[0-9a-f]+$ ]] || die E_CLUSTER_READ "could not read the VPC of $CLUSTER_NAME"
  state_set VPC_ID "$vpc"
  sg="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" \
    --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)" || die E_CLUSTER_READ "could not read the security group of $CLUSTER_NAME"
  [[ "$sg" =~ ^sg-[0-9a-f]+$ ]] || die E_CLUSTER_READ "could not read the security group of $CLUSTER_NAME (got '$sg')"
  state_set CLUSTER_SG_ID "$sg"
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
    --namespace kube-system --service-account cilium-operator --query 'associations[].associationId' --output text)" \
    || die E_POD_IDENTITY "could not list the Pod Identity associations of $CLUSTER_NAME"
  [[ -n "$assoc" ]] || eksctl create podidentityassociation -f "$RUN_STATE_DIR/pod-identity.yaml" \
    || die E_POD_IDENTITY "eksctl create podidentityassociation failed for kube-system/cilium-operator"
  assoc="$(aws eks list-pod-identity-associations --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
    --namespace kube-system --service-account cilium-operator --query 'associations[].associationId' --output text)" \
    || die E_POD_IDENTITY "could not list the Pod Identity associations of $CLUSTER_NAME"
  [[ "$assoc" =~ ^a-[a-z0-9]+$ ]] || die E_POD_IDENTITY "expected one Pod Identity association for kube-system/cilium-operator, got '$assoc'"
  state_set POD_IDENTITY_ASSOCIATION_ID "$assoc"
  state_set OPERATOR_ROLE_NAME "$OPERATOR_ROLE_NAME"
  python3 "$PY" check-operator-role
  endpoint="$(state_need CLUSTER_ENDPOINT)"
  hc upgrade --install cilium "$CILIUM_CHART" --version "$CILIUM_VERSION" --namespace kube-system \
    -f "$SAMPLE_DIR/cilium-values.yaml" --set "cluster.name=$CLUSTER_NAME" \
    --set "k8sServiceHost=${endpoint#https://}" --set "eni.eniTags.RunId=$RUN_ID" \
    || die E_CILIUM_INSTALL "helm upgrade --install of Cilium $CILIUM_VERSION failed"
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
    --output json >"$RUN_STATE_DIR/lt-system-v1.json" || die E_LAUNCH_TEMPLATE "could not read version 1 of $lt"
  python3 "$PY" check-user-data system "$RUN_STATE_DIR/lt-system-v1.json"
  python3 "$PY" render-nodegroup system >/dev/null
  ensure_nodegroup system
  wait_until "$TRIES" "a system node" has_nodes system \
    || die E_NODE_COUNT "no system node registered"
  kc wait --for=condition=Ready node -l eks.amazonaws.com/nodegroup=system --timeout=20m \
    || die E_NODE_READY "the system node is not Ready after 20 minutes"
  system_node="$(one_node system)"
  state_set SYSTEM_NODE "$system_node"
  kc -n kube-system rollout status daemonset/cilium --timeout=10m \
    || die E_CILIUM_ROLLOUT "the Cilium agent DaemonSet did not roll out"
  kc -n kube-system rollout status deployment/cilium-operator --timeout=10m \
    || die E_CILIUM_ROLLOUT "the Cilium operator Deployment did not roll out"
  kc get node "$system_node" -o json >"$RUN_STATE_DIR/node-system.json" \
    || die E_NODE_READ "could not read node $system_node"
  python3 "$PY" check-max-pods --want "$mp_system" --node "$RUN_STATE_DIR/node-system.json"
  python3 "$PY" check-os-image system "$RUN_STATE_DIR/node-system.json"
  python3 "$PY" check-operator-role
  ensure_namespace
  probe="$(probe_name system)"
  probe_start "$probe" "$system_node"
  probe_capture "$probe" "$EVIDENCE_DIR/probe-system"
  probe_stop "$probe" || die E_PROBE "could not delete the probe pod $probe"
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
    # The reused AMI keeps the RunId of the run that built it, so clean.sh of this run keeps it.
    echo "Run $RUN_ID uses AMI $REUSE_SANDBOX_AMI_ID from an earlier run."
  else
    export BUILD_INSTANCE_TYPE BUILD_WORK_VOLUME_GIB AMI_WAIT_SECONDS SANDBOX_SLOTS
    rc=0; "$CB_BUILD_AMI_CMD" build || rc=$?
    ((rc == 0)) || die E_AMI_BUILD "the AMI build did not finish (exit $rc); to build again in this run, run RUN_ID=$RUN_ID ./setup.sh (it builds only when each builder part is gone); to delete the run, run ./clean.sh --dry-run, then ./clean.sh"
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
  aws ec2 describe-images --region "$AWS_REGION" --image-ids "$ami" --output json >"$RUN_STATE_DIR/sandbox-ami.json" \
    || die E_AMI_READ "could not read the sandbox AMI $ami"
  python3 "$PY" check-density --ami-tags "$RUN_STATE_DIR/sandbox-ami.json"
  lt="$(python3 "$PY" launch-template sandbox | tail -n1)"
  [[ "$lt" =~ ^lt-[0-9a-f]{17}$ ]] || die E_LAUNCH_TEMPLATE "could not create or read the sandbox launch template (got '$lt')"
  state_set SANDBOX_LAUNCH_TEMPLATE_ID "$lt"
  aws ec2 describe-launch-template-versions --region "$AWS_REGION" --launch-template-id "$lt" --versions 1 \
    --output json >"$RUN_STATE_DIR/lt-sandbox-v1.json" || die E_LAUNCH_TEMPLATE "could not read version 1 of $lt"
  python3 "$PY" check-user-data sandbox "$RUN_STATE_DIR/lt-sandbox-v1.json"
  python3 "$PY" check-max-pods --want "$mp_sandbox" --launch-template "$RUN_STATE_DIR/lt-sandbox-v1.json"
  python3 "$PY" render-nodegroup sandbox >/dev/null
  ensure_nodegroup sandbox
  wait_until "$TRIES" "a sandbox node" has_nodes sandbox \
    || die E_NODE_COUNT "no sandbox node registered"
  kc wait --for=condition=Ready node -l eks.amazonaws.com/nodegroup=sandbox --timeout=20m \
    || die E_NODE_READY "the sandbox node is not Ready after 20 minutes"
  sandbox_node="$(one_node sandbox)"
  state_set SANDBOX_NODE "$sandbox_node"
  kc -n kube-system rollout status daemonset/cilium --timeout=10m \
    || die E_CILIUM_ROLLOUT "the Cilium agent DaemonSet did not roll out"
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
  kc get node "$sandbox_node" -o json >"$RUN_STATE_DIR/node-sandbox.json" \
    || die E_NODE_READ "could not read node $sandbox_node"
  kc get --raw "/api/v1/nodes/$sandbox_node/proxy/configz" >"$RUN_STATE_DIR/configz-sandbox.json" \
    || die E_CONFIGZ_READ "could not read the kubelet configz of $sandbox_node"
  ensure_namespace
  probe="$(probe_name sandbox)"
  probe_start "$probe" "$sandbox_node"
  probe_capture "$probe" "$d"
  probe_stop "$probe" || die E_PROBE "could not delete the probe pod $probe"
  python3 "$PY" check-os-image sandbox "$RUN_STATE_DIR/node-sandbox.json"
  python3 "$PY" check-btf "$d/btf.txt"
  python3 "$PY" check-mempool --cmdline "$d/cmdline.txt" --kernel-log "$d/kernel.log"
  python3 "$PY" check-kubeconfig-path --shim-toml "$d/nitro-sandbox.toml" --kubeconfig "$d/kubeconfig.txt"
  python3 "$PY" check-mkfs-erofs "$d/mkfs-erofs.txt"
  python3 "$PY" check-runtime-endpoint "$RUN_STATE_DIR/configz-sandbox.json"
  python3 "$PY" check-containerd-dump "$d/containerd-dump.toml"
  python3 "$PY" check-allocatable "$RUN_STATE_DIR/node-sandbox.json"
  python3 "$PY" check-density --shim-toml "$d/nitro-sandbox.toml"
  python3 "$PY" check-max-pods --want "$mp_sandbox" --node "$RUN_STATE_DIR/node-sandbox.json"
  # The slot pool: SANDBOX_SLOTS not above pcie_slots_total, and equal to the driver's
  # pcie_slots and the node's eks.amazonaws.com/nitro-sandbox capacity.
  python3 "$PY" check-slots --driver "$d/slots.txt" --node "$RUN_STATE_DIR/node-sandbox.json" --journal "$d/journal.log"
  python3 "$PY" check-selinux-mode "$d/selinux-enforce.txt"
  # No SELinux denial since the boot of the sandbox node, before any workload starts. An empty,
  # unreadable or "-- No entries --" log is "could not check" (exit 2), which stops the run too.
  python3 "$PY" selinux-audit "$d/kernel.log" "$d/journal.log"
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
    python3 "$PY" runtimeclass | kc create -f - >/dev/null || die E_RUNTIMECLASS "could not create the RuntimeClass isolated-sandbox"
    rc_json="$(kc get runtimeclass isolated-sandbox -o json)" || die E_RUNTIMECLASS "could not read the RuntimeClass back"
  fi
  python3 "$PY" check-runtimeclass <<<"$rc_json"
  ensure_namespace
  for f in "$DEPLOY"/*.yaml; do
    [[ "$f" == "$DEPLOY/namespace.yaml" ]] || kc apply -n "$NAMESPACE" -f "$f" || die E_WORKLOADS "could not apply $f"
  done
  kc -n "$NAMESPACE" wait --for=condition=Ready "${WORKLOAD_PODS[@]/#/pod/}" --timeout=10m \
    || die E_WORKLOADS_READY "the pods ${WORKLOAD_PODS[*]} are not all Ready after 10 minutes"
  finish workloads
fi

printf '\nRun %s is ready. Next: RUN_ID=%s ./test.sh\n' "$RUN_ID" "$RUN_ID"
cat <<EOF
The cluster bills while it exists (EKS control plane, two EC2 instances, one NAT gateway, one
public IPv4 address, EBS volumes, and the AMI snapshots). Run ./clean.sh when you are done.
EOF
