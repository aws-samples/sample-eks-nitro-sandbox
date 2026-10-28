#!/usr/bin/env bash
# 00c-check-cluster.sh: read-only checks of the two cluster-wide prerequisites this sample uses
# but never installs or changes (AGENTS.md: leave cluster-wide settings to the reader; a shared
# install is reused as it is). Runs on the operator's workstation before setup.sh creates
# anything, and stops with the command to run when a prerequisite is missing.
#
#   scripts/00c-check-cluster.sh
#
# 1. The managed vpc-cni add-on, ACTIVE, with enableNetworkPolicy=true in its configuration
#    values. A managed node group node gets its pod network from the aws-node DaemonSet this
#    add-on runs (EKS Auto Mode nodes do not need it, so a cluster that finished Getting started
#    on Auto Mode can lack it, and then the sample's node never goes Ready), and network policy
#    on is what enforces deploy/network-policy.yaml on that node.
# 2. The shared isolated-sandbox RuntimeClass (created by Getting started), with handler
#    isolated-sandbox, and every label in its scheduling.nodeSelector among the labels this
#    sample's node registers with (scripts/join-nodegroup.sh). It is read, never applied over:
#    other workloads use it. A RuntimeClass that selects something the sample's node does not
#    carry is a question for the spec, not something this script changes.
# 3. Cluster DNS pods labelled k8s-app=kube-dns in kube-system: deploy/network-policy.yaml allows
#    the sandbox's DNS egress to those pods only, so without them the sandbox would have no DNS.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
require_run_id   # the node group name the node's labels carry is per run
require_kube_context   # KUBE_CONTEXT is set and is cluster CLUSTER_NAME (the AWS calls below read the same one)
: "${VPC_CNI_ADDON_VERSION:=<VPC_CNI_ADDON_VERSION>}"
evidence() { [ -n "${EVIDENCE_DIR:-}" ] && printf '%s=%q\n' "$1" "$2" >> "$EVIDENCE_DIR/run-evidence.env" || true; }

# --- 1. vpc-cni add-on with network policy on --------------------------------------------------
create_cmd="aws eks create-addon --region $AWS_REGION --cluster-name $CLUSTER_NAME --addon-name vpc-cni \\
    --addon-version $VPC_CNI_ADDON_VERSION --resolve-conflicts NONE \\
    --configuration-values '{\"enableNetworkPolicy\":\"true\"}'"
# Turning network policy enforcement on is cluster-wide: every NetworkPolicy already on the
# cluster starts being enforced, for every workload, not only this sample's.
netpol_warning="WARNING: turning network policy enforcement on is cluster-wide. Every NetworkPolicy object already on
cluster $CLUSTER_NAME starts being enforced, for every workload, not only this sample's. Review them first
(kubectl --context \"\$KUBE_CONTEXT\" get networkpolicy --all-namespaces) and test the change on a cluster that is
not production before you make it on a shared one."
err=$(mktemp)
if addon=$(aws eks describe-addon --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --addon-name vpc-cni \
     --query 'addon.[status,addonVersion,configurationValues]' --output json 2>"$err"); then
  rm -f "$err"
else
  msg=$(cat "$err"); rm -f "$err"
  if [[ "$msg" == *ResourceNotFoundException* ]]; then
    die "PREREQUISITE NOT MET: cluster $CLUSTER_NAME has no managed vpc-cni add-on, so a managed node group node gets no pod network and never goes Ready.
This sample does not change cluster-wide settings. Install the add-on yourself, at the version you
pin, without overwriting an existing amazon-vpc-cni ConfigMap, then re-run:
  $create_cmd
$netpol_warning
(find the version for your cluster with: aws eks describe-addon-versions --region $AWS_REGION --addon-name vpc-cni --kubernetes-version ${KUBERNETES_VERSION:-1.36})"
  fi
  die "could not read the vpc-cni add-on of cluster $CLUSTER_NAME (this is 'could not determine', not 'absent'): $msg"
fi
verdict=$(python3 -c '
import json, re, sys
status, version, values = json.loads(sys.argv[1])
on = False
if values:
    try:
        v = json.loads(values).get("enableNetworkPolicy")
        on = v is True or str(v).lower() == "true"
    except (ValueError, AttributeError):
        on = re.search(r"(?m)^\s*enableNetworkPolicy\s*:\s*[\"\x27]?true[\"\x27]?\s*$", values) is not None
print(status, version, "on" if on else "off")
' "$addon")
read -r cni_status cni_version cni_netpol <<<"$verdict"
log "vpc-cni add-on: status=$cni_status version=$cni_version network policy=$cni_netpol"
evidence VPC_CNI_ADDON "$cni_version status=$cni_status networkPolicy=$cni_netpol"
[ "$cni_status" = ACTIVE ] || die "the vpc-cni add-on of cluster $CLUSTER_NAME is $cni_status, not ACTIVE; wait for it, or fix it, then re-run"
if [ "$cni_netpol" != on ]; then
  die "PREREQUISITE NOT MET: the vpc-cni add-on of cluster $CLUSTER_NAME runs with network policy off, so deploy/network-policy.yaml would not be enforced on the sample's node.
This sample does not change cluster-wide settings. Turn it on yourself, keeping your other values, then re-run:
  aws eks update-addon --region $AWS_REGION --cluster-name $CLUSTER_NAME --addon-name vpc-cni \\
    --resolve-conflicts PRESERVE --configuration-values '{\"enableNetworkPolicy\":\"true\"}'
(merge enableNetworkPolicy into your existing configuration values if you set others)
$netpol_warning"
fi

# --- 2. The shared isolated-sandbox RuntimeClass, read only -------------------------------------
rc_err=$(mktemp)
if ! rc_json=$(kc get runtimeclass isolated-sandbox -o json 2>"$rc_err"); then
  msg=$(cat "$rc_err"); rm -f "$rc_err"
  if [[ "$msg" == *NotFound* || "$msg" == *"not found"* ]]; then
    die "PREREQUISITE NOT MET: the cluster has no isolated-sandbox RuntimeClass. Finish Getting started > Hello sandbox first; this sample reuses that RuntimeClass and never creates or changes it."
  fi
  die "could not read RuntimeClass isolated-sandbox (could not determine): $msg"
fi
rm -f "$rc_err"
node_labels="eks.amazonaws.com/nodegroup=${NODEGROUP_NAME},${NODE_LABELS}"
rc_verdict=$(python3 -c '
import json, sys
rc = json.loads(sys.argv[1])
have = dict(kv.split("=", 1) for kv in sys.argv[2].split(","))
sel = (rc.get("scheduling") or {}).get("nodeSelector") or {}
missing = [f"{k}={v}" for k, v in sorted(sel.items()) if have.get(k) != v]
print("handler=" + str(rc.get("handler")))
print("selector=" + ",".join(f"{k}={v}" for k, v in sorted(sel.items())))
print("missing=" + ",".join(missing))
' "$rc_json" "$node_labels")
rc_handler=$(printf '%s\n' "$rc_verdict" | sed -n 's/^handler=//p')
rc_selector=$(printf '%s\n' "$rc_verdict" | sed -n 's/^selector=//p')
rc_missing=$(printf '%s\n' "$rc_verdict" | sed -n 's/^missing=//p')
log "RuntimeClass isolated-sandbox: handler=$rc_handler nodeSelector=${rc_selector:-<none>}"
evidence RUNTIMECLASS_ISOLATED_SANDBOX "handler=$rc_handler nodeSelector=${rc_selector:-none}"
[ "$rc_handler" = isolated-sandbox ] || die "RuntimeClass isolated-sandbox has handler '$rc_handler', not isolated-sandbox; the containerd handler this sample registers would not be used. This is a question for the spec; the sample does not change a shared RuntimeClass."
[ -z "$rc_missing" ] || die "RuntimeClass isolated-sandbox selects $rc_missing, which the sample's node does not register with ($node_labels). This is a question for the spec; the sample does not change a shared RuntimeClass."

# --- 3. Cluster DNS pods the network policy allows -----------------------------------------------
dns_err=$(mktemp)
if ! dns_json=$(kc get pods -n kube-system -l k8s-app=kube-dns -o json 2>"$dns_err"); then
  msg=$(cat "$dns_err"); rm -f "$dns_err"
  die "could not list the cluster DNS pods in kube-system (could not determine): $msg"
fi
rm -f "$dns_err"
dns_pods=$(printf '%s' "$dns_json" | json_get 'len(d.get("items", []))')
log "cluster DNS pods labelled k8s-app=kube-dns in kube-system: $dns_pods"
evidence CLUSTER_DNS_PODS "k8s-app=kube-dns in kube-system: $dns_pods"
[ "${dns_pods:-0}" -gt 0 ] || die "no pod in kube-system carries k8s-app=kube-dns. deploy/network-policy.yaml allows the sandbox's DNS egress only to those pods, so on this cluster the sandbox would have no DNS. This is a question for the spec: check the label your cluster DNS pods carry (kubectl get pods -n kube-system --show-labels)."

echo "CLUSTER PREREQUISITES OK: vpc-cni $cni_version ACTIVE with network policy on; RuntimeClass isolated-sandbox reused as it is (nodeSelector ${rc_selector:-none} is satisfied by the node's labels); $dns_pods cluster DNS pod(s) labelled k8s-app=kube-dns"
