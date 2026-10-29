#!/usr/bin/env bash
# Create a NEW, dedicated EKS cluster whose only CNI is Cilium (the Amazon VPC CNI and
# kube-proxy are never installed), add one ordinary Ubuntu 24.04 node and one dedicated,
# tainted Ubuntu 24.04 EKS Pod Isolation sandbox node, and create the isolated-sandbox
# RuntimeClass the sandbox pod in test.sh uses.
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
source "$SAMPLE_DIR/scripts/common.sh"   # exports RUN_DIR and KUBECONFIG=$RUN_DIR/kubeconfig

step "1/8 prerequisites"
# RUN_DIR is under the repository's gitignored tmp/ (set in common.sh), never the sample
# folder, so this run's kubeconfig and rendered manifests are never one `git add` from being
# published. Mode 700 so the kubeconfig written into it stays private.
mkdir -p -m 700 "$RUN_DIR"
require_commands aws eksctl helm kubectl python3
require_eksctl_version
require_caller_account
python3 -c 'import yaml' 2>/dev/null || die "python3 needs PyYAML (pip install pyyaml)"
# The Helm values the page's claims rest on (kube-proxy replacement, the socket load balancer
# in the host namespace only, ENI IPAM, native routing), checked before anything bills.
python3 "$PY" check-cilium-values
# Both AMI ids are checked now, before any AWS resource is created from them: a bad
# SANDBOX_AMI_ID or SYSTEM_AMI_ID stops the run here, not after the control plane and VPC
# are already billing.
python3 "$PY" check-sandbox-ami
python3 "$PY" check-system-ami

step "2/8 cluster: no VPC CNI, no kube-proxy, no nodes"
python3 "$PY" render-cluster
state="$(cluster_state)"
if [[ "$state" == NONE ]]; then
  eksctl create cluster -f "$RUN_DIR/cluster.yaml" --without-nodegroup --kubeconfig "$KUBECONFIG"
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
[[ -n "$assoc" ]] || eksctl create podidentityassociation -f "$RUN_DIR/pod-identity.yaml"
eksctl utils write-kubeconfig --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --kubeconfig "$KUBECONFIG"
chmod 600 "$KUBECONFIG"
echo "$(green "No aws-node or kube-proxy DaemonSet exists on this cluster, now or ever:")"
kubectl -n kube-system get daemonset aws-node kube-proxy 2>&1 | grep -i notfound || true

step "3/8 Cilium $CILIUM_VERSION (ENI mode, the only CNI, replacing kube-proxy) -- before any node"
endpoint="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --query cluster.endpoint --output text)"
helm_args=(--set "cluster.name=$CLUSTER_NAME" --set "k8sServiceHost=${endpoint#https://}")
[[ -z "$OWNER_TAG" ]] || helm_args+=(--set "eni.eniTags.Owner=$OWNER_TAG")
helm upgrade --install cilium "$CILIUM_CHART" --version "$CILIUM_VERSION" --namespace kube-system \
  -f "$SAMPLE_DIR/cilium-values.yaml" "${helm_args[@]}"
python3 "$PY" preflight-daemonset

step "4/8 launch templates, created with this sample's tags and each node's bootstrap user data"
# Both templates name an AMI, so EKS adds no user data of its own: each carries Canonical's
# bootstrap.sh line with the cluster's endpoint, CA and DNS address and the node's labels, and
# the sandbox node's labels include the two the isolated-sandbox RuntimeClass schedules on.
lt_system="$(python3 "$PY" launch-template system | tail -n1)"
lt_sandbox="$(python3 "$PY" launch-template sandbox | tail -n1)"
[[ "$lt_system" =~ ^lt-[0-9a-f]{17}$ && "$lt_sandbox" =~ ^lt-[0-9a-f]{17}$ ]] \
  || die "could not create or read the launch templates (got '$lt_system' '$lt_sandbox')"
python3 "$PY" check-user-data system <"$RUN_DIR/system-launch-template.json"
python3 "$PY" check-user-data sandbox <"$RUN_DIR/sandbox-launch-template.json"
echo "Launch templates: system $lt_system, sandbox $lt_sandbox"

step "5/8 node groups: system (ordinary Ubuntu 24.04) and sandbox (the Ubuntu Pod Isolation AMI, tainted)"
python3 "$PY" render-nodegroups --system-launch-template "$lt_system" --sandbox-launch-template "$lt_sandbox"
# Existing node groups are skipped, so this is safe to re-run.
eksctl create nodegroup -f "$RUN_DIR/nodegroups.yaml"
kubectl wait --for=condition=Ready node -l eks.amazonaws.com/nodegroup=system --timeout=15m
kubectl wait --for=condition=Ready node -l eks.amazonaws.com/nodegroup=sandbox --timeout=15m
kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=10m

step "6/8 BTF gate: both Ubuntu node kernels must expose valid BTF before their Cilium agents are ready"
system_node="$(kubectl get nodes -l eks.amazonaws.com/nodegroup=system -o jsonpath='{.items[0].metadata.name}')"
sandbox_node="$(kubectl get nodes -l eks.amazonaws.com/nodegroup=sandbox -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$system_node" && -n "$sandbox_node" ]] || die "could not read the system or sandbox node name"
python3 "$PY" check-btf system "$system_node"
python3 "$PY" check-btf sandbox "$sandbox_node"

step "7/8 the isolated-sandbox RuntimeClass"
# The GA node-build bundle (UBUNTU.md, section 5) has the operator create this RuntimeClass once
# per cluster, and this cluster is new, so nobody else has. It is created only when absent, and
# whatever is there afterwards must match the bundle's: handler isolated-sandbox, the per-pod
# overhead, and a nodeSelector on the two labels only the sandbox node carries.
rc_json="$(kubectl get runtimeclass isolated-sandbox --ignore-not-found -o json)" \
  || die "could not read the isolated-sandbox RuntimeClass"
if [[ -z "$rc_json" ]]; then
  python3 "$PY" runtimeclass | kubectl create -f -
  rc_json="$(kubectl get runtimeclass isolated-sandbox -o json)" || die "could not read the RuntimeClass back"
fi
# A RuntimeClass is cluster-scoped, so the namespace's label does not cover it: an existing one
# is reused only when it carries the sample's own mark (app.kubernetes.io/part-of, the label the
# namespace carries) and is otherwise exactly the bundle's, tolerations and metadata included.
python3 "$PY" check-runtimeclass <<<"$rc_json" \
  || die "the isolated-sandbox RuntimeClass on $CLUSTER_NAME is not this sample's or differs from the GA bundle's (see above); setup.sh never changes an existing RuntimeClass. Inspect it with: kubectl get runtimeclass isolated-sandbox -o yaml"
sandbox_node_json="$(kubectl get node "$sandbox_node" -o json)" || die "could not read node $sandbox_node"
python3 "$PY" check-node-labels sandbox <<<"$sandbox_node_json" \
  || die "the sandbox node does not carry both labels the isolated-sandbox RuntimeClass schedules on"
system_node_json="$(kubectl get node "$system_node" -o json)" || die "could not read node $system_node"
python3 "$PY" check-node-labels system <<<"$system_node_json" \
  || die "the ordinary system node carries an isolated-sandbox RuntimeClass label"

step "8/8 tag what AWS created for this cluster without a tag"
# AWS creates some of this cluster's resources with no way to tag them at creation. tag-sweep
# writes the sample's tags to exactly these, each found by one exact relation: the Auto Scaling
# group of each of the two node groups, the EKS copy of the launch template each one launches
# from, the instance profile its node uses, the cluster security group describe-cluster names,
# the VPC's main route table, default security group and default network ACL, the interfaces
# described "Amazon EKS <cluster>" in the cluster security group, and the NAT gateway's
# interface. It writes nothing else and prints one line per resource tagged. Before its first
# write it stops, tagging nothing, on a cluster or VPC without Demo=setup-cilium-ubuntu (exit 1),
# on a read that comes up short, such as an empty list (exit 2), and on a member of that set
# carrying another Demo value (exit 1). This runs last, once every node group exists, and here
# rather than in test.sh, which stays read-only.
python3 "$PY" tag-sweep
# Then the same audit test.sh's stage 8 runs: every resource the cluster owns must now carry
# auto-delete=no (exit 1 names any that does not; exit 2 means the inventory came up short).
audit_rc=0; audit_out="$(python3 "$PY" audit-tags 2>&1)" || audit_rc=$?
sed '/^ok /d' <<<"$audit_out"
((audit_rc == 0)) \
  || die "after the sweep the tag audit still finds a resource without auto-delete=no, or a kind it could not reach (above), so test.sh's stage 8 would fail"

printf '\n%s\n' "$(green "Cluster $CLUSTER_NAME is up: Cilium is the only CNI, kube-proxy replacement is active, and both Ubuntu node groups are Ready with valid BTF.")"
cat <<EOF

What exists now:
  - cluster:        $CLUSTER_NAME ($AWS_REGION)
  - system node:    $system_node  ($SYSTEM_INSTANCE_TYPE, ordinary Ubuntu 24.04)
  - sandbox node:   $sandbox_node  ($SANDBOX_INSTANCE_TYPE, Ubuntu Pod Isolation, tainted $SANDBOX_TAINT_KEY=true:NoSchedule)
  - Cilium:         $CILIUM_VERSION, ENI IPAM, native routing, kube-proxy replacement, socketLB.hostNamespaceOnly=true
  - RuntimeClass:   isolated-sandbox (schedules on eks.amazonaws.com/nitro-sandbox=true, sandbox.preview/nitro=true)

Next: run ./test.sh to apply the workloads and policy and prove the networking, BTF and
policy claims (see the README's Evidence section). This cluster bills while it exists (EKS
control plane, two EC2 instances, one NAT gateway); see the README for cleanup.
EOF
