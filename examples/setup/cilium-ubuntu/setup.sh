#!/usr/bin/env bash
# Create a NEW, dedicated EKS cluster whose only CNI is Cilium (the Amazon VPC CNI and
# kube-proxy are never installed), add one ordinary Ubuntu 24.04 node and one dedicated,
# tainted Ubuntu 24.04 EKS Pod Isolation sandbox node, and start the RuntimeClass the
# follow-on sample (test.sh, not part of this change) uses.
#
# Order matters and is fixed: the cluster and the Cilium operator's Pod Identity role exist
# before Cilium is installed; Cilium is installed and its DaemonSet is checked compatible
# with the sandbox node's labels/taint BEFORE that node group is created, so no node of
# either kind ever joins without a CNI that can give its pods an address; and both node
# kernels must show valid BTF before their Cilium agents are treated as ready, because
# kube-proxy replacement's datapath will not load without it.
#
# This sample never attaches to, modifies the CNI on, or removes kube-proxy from an existing
# cluster: it only ever creates its own dedicated, disposable cluster, tagged
# Demo=setup-cilium-ubuntu, and every step that touches an existing resource checks that tag
# first.
#
# Idempotent: every step checks what already exists, so after a failure re-run it and it
# carries on from where it stopped.
set -euo pipefail
# common.sh reads SAMPLE_DIR (config, kubeconfig, the Python helper path) and is shared with
# test.sh and clean.sh, which set the same variable, so the three scripts agree on one name.
SAMPLE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SAMPLE_DIR/scripts/common.sh"   # exports KUBECONFIG=$SAMPLE_DIR/out/kubeconfig

step "1/7 prerequisites"
mkdir -p -m 700 "$SAMPLE_DIR/out"
require_commands aws eksctl helm kubectl python3
require_eksctl_version
require_caller_account
python3 -c 'import yaml' 2>/dev/null || die "python3 needs PyYAML (pip install pyyaml)"
# Both AMI ids are checked now, before any AWS resource is created from them: a bad
# SANDBOX_AMI_ID or SYSTEM_AMI_ID stops the run here, not after the control plane and VPC
# are already billing.
python3 "$PY" check-sandbox-ami
python3 "$PY" check-system-ami

step "2/7 cluster: no VPC CNI, no kube-proxy, no nodes"
python3 "$PY" render-cluster
state="$(cluster_state)"
if [[ "$state" == NONE ]]; then
  eksctl create cluster -f "$SAMPLE_DIR/out/cluster.yaml" --without-nodegroup --kubeconfig "$KUBECONFIG"
else
  echo "Cluster $CLUSTER_NAME already exists ($state)."
  require_demo_cluster
  aws eks wait cluster-active --region "$AWS_REGION" --name "$CLUSTER_NAME"
  # A create that stopped half way may have made the cluster but not its add-ons. Existing
  # add-ons are left alone; missing ones are created.
  addons="$(aws eks list-addons --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --query 'addons' --output text | tr '\t' '\n')"
  # A cluster an earlier run of this sample built runs kube-proxy. Removing the add-on would
  # leave its rules in every node's iptables, where they would keep answering for Services,
  # so such a cluster is rebuilt, not converted. grep exits 1 for "not there"; anything else
  # (found, or grep itself failing) stops here.
  kp_rc=0; grep -qxF kube-proxy <<<"$addons" || kp_rc=$?
  ((kp_rc == 1)) \
    || die "cluster $CLUSTER_NAME has the kube-proxy add-on (an earlier run of this sample built it), or its add-on list could not be read; run ./clean.sh, then ./setup.sh"
  for addon in coredns eks-pod-identity-agent; do
    grep -qxF "$addon" <<<"$addons" || aws eks create-addon --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
      --addon-name "$addon" --tags "auto-delete=no,Demo=$DEMO_TAG_VAL${OWNER_TAG:+,Owner=$OWNER_TAG}" >/dev/null
  done
fi
# eksctl refuses Pod Identity associations in `create cluster` when the VPC CNI is disabled,
# so the operator's association is its own step. It must exist before Cilium is installed:
# EKS injects the credentials when the operator pod is created.
assoc="$(aws eks list-pod-identity-associations --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
  --namespace kube-system --service-account cilium-operator --query 'associations[].associationId' --output text)"
[[ -n "$assoc" ]] || eksctl create podidentityassociation -f "$SAMPLE_DIR/out/pod-identity.yaml"
eksctl utils write-kubeconfig --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --kubeconfig "$KUBECONFIG"
chmod 600 "$KUBECONFIG"
echo "$(green "No aws-node or kube-proxy DaemonSet exists on this cluster, now or ever:")"
kubectl -n kube-system get daemonset aws-node kube-proxy 2>&1 | grep -i notfound || true

step "3/7 Cilium $CILIUM_VERSION (ENI mode, the only CNI, replacing kube-proxy) -- before any node"
endpoint="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --query cluster.endpoint --output text)"
helm_args=(--set "cluster.name=$CLUSTER_NAME" --set "k8sServiceHost=${endpoint#https://}")
[[ -z "$OWNER_TAG" ]] || helm_args+=(--set "eni.eniTags.Owner=$OWNER_TAG")
helm upgrade --install cilium "$CILIUM_CHART" --version "$CILIUM_VERSION" --namespace kube-system \
  -f "$SAMPLE_DIR/cilium-values.yaml" "${helm_args[@]}"
python3 "$PY" preflight-daemonset

step "4/7 launch templates, created with this sample's tags"
lt_system="$(python3 "$PY" launch-template system | tail -n1)"
lt_sandbox="$(python3 "$PY" launch-template sandbox | tail -n1)"
[[ "$lt_system" =~ ^lt-[0-9a-f]{17}$ && "$lt_sandbox" =~ ^lt-[0-9a-f]{17}$ ]] \
  || die "could not create or read the launch templates (got '$lt_system' '$lt_sandbox')"
echo "Launch templates: system $lt_system, sandbox $lt_sandbox"

step "5/7 node groups: system (ordinary Ubuntu 24.04) and sandbox (the Ubuntu Pod Isolation AMI, tainted)"
python3 "$PY" render-nodegroups --system-launch-template "$lt_system" --sandbox-launch-template "$lt_sandbox"
# Existing node groups are skipped, so this is safe to re-run.
eksctl create nodegroup -f "$SAMPLE_DIR/out/nodegroups.yaml"
kubectl wait --for=condition=Ready node -l eks.amazonaws.com/nodegroup=system --timeout=15m
kubectl wait --for=condition=Ready node -l eks.amazonaws.com/nodegroup=sandbox --timeout=15m
kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=10m

step "6/7 BTF gate: both Ubuntu node kernels must expose valid BTF before their Cilium agents are ready"
system_node="$(kubectl get nodes -l eks.amazonaws.com/nodegroup=system -o jsonpath='{.items[0].metadata.name}')"
sandbox_node="$(kubectl get nodes -l eks.amazonaws.com/nodegroup=sandbox -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$system_node" && -n "$sandbox_node" ]] || die "could not read the system or sandbox node name"
python3 "$PY" check-btf system "$system_node"
python3 "$PY" check-btf sandbox "$sandbox_node"
# EKS does not copy node-group tags to the Auto Scaling groups it creates, and a few other
# resources have no create-time tag hook at all. A full tag sweep (ASGs, EKS-copied launch
# template versions, the control plane's and NAT gateway's network interfaces, the VPC's
# default route table / security group / network ACL, and any ENI Cilium itself created) is
# clean.sh's job, run alongside its ownership checks; this step only confirms the two launch
# templates and node groups this script created already carry the tag, which they do from
# creation.

step "7/7 RuntimeClass for the sandbox pods the follow-on test/evidence work applies"
python3 "$PY" runtimeclass | kubectl apply -f -

printf '\n%s\n' "$(green "Cluster $CLUSTER_NAME is up: Cilium is the only CNI, kube-proxy replacement is active, and both Ubuntu node groups are Ready with valid BTF.")"
cat <<EOF

What exists now:
  - cluster:        $CLUSTER_NAME ($AWS_REGION)
  - system node:    $system_node  ($SYSTEM_INSTANCE_TYPE, ordinary Ubuntu 24.04)
  - sandbox node:   $sandbox_node  ($SANDBOX_INSTANCE_TYPE, Ubuntu Pod Isolation, tainted $SANDBOX_TAINT_KEY=true:NoSchedule)
  - Cilium:         $CILIUM_VERSION, ENI IPAM, native routing, kube-proxy replacement, socketLB.hostNamespaceOnly=true
  - RuntimeClass:   isolated-sandbox

This item stops here: the evidence (sandbox networking, policy, BTF negative control,
service-boundary positive/negative controls) and the full website page are a separate,
coordinated item. Remember this cluster bills while it exists (EKS control plane, two EC2
instances, one NAT gateway) -- see the README for cleanup.
EOF
