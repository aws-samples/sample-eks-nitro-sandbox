#!/usr/bin/env bash
# 00c-check-cluster.sh: read-only checks of the cluster-wide prerequisites this blueprint uses
# but never installs or changes (AGENTS.md: leave cluster-wide settings to the reader; a shared
# install is reused as it is). Runs on the operator's workstation before setup.sh creates
# anything, and stops with the command to run when a prerequisite is missing.
#
#   scripts/00c-check-cluster.sh
#
# 1. The cluster is STANDARD (not Auto Mode). Auto Mode manages its own nodes, so neither a
#    managed node group with a custom AMI nor a Karpenter EC2NodeClass applies there.
# 2. The managed vpc-cni add-on, ACTIVE. A node from this blueprint's AMI gets its pod network
#    from the aws-node DaemonSet this add-on runs; without it the node never goes Ready.
# 3. Both sandbox RuntimeClasses (isolated-sandbox, confidential-sandbox), each with a handler
#    matching its name and a nodeSelector the blueprint's node label satisfies. Read, never
#    applied over: other workloads use them.
# 4. When JOIN_MODE includes karpenter: Karpenter is installed (its CRDs). Reused as it is;
#    if absent, the reader installs it as a step.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
require_run_id
require_kube_context
: "${VPC_CNI_ADDON_VERSION:=<VPC_CNI_ADDON_VERSION>}"
evidence() { [ -n "${EVIDENCE_DIR:-}" ] && { mkdir -p "$EVIDENCE_DIR"; printf '%s=%q\n' "$1" "$2" >> "$EVIDENCE_DIR/run-evidence.env"; } || true; }

# --- 1. Standard (non-Auto-Mode) cluster -----------------------------------------------------
auto=$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --output json \
  | json_get 'bool((d["cluster"].get("computeConfig") or {}).get("enabled"))')
log "cluster $CLUSTER_NAME computeConfig.enabled=$auto"
evidence CLUSTER_AUTO_MODE "$auto"
[ "$auto" = False ] || die "PREREQUISITE NOT MET: cluster $CLUSTER_NAME is EKS Auto Mode (computeConfig.enabled=true). This blueprint adds a managed node group and/or a Karpenter EC2NodeClass that run a custom AMI, which Auto Mode does not support. Use a standard (non-Auto-Mode) cluster."

# --- 2. vpc-cni add-on, ACTIVE ---------------------------------------------------------------
create_cmd="aws eks create-addon --region $AWS_REGION --cluster-name $CLUSTER_NAME --addon-name vpc-cni --addon-version $VPC_CNI_ADDON_VERSION --resolve-conflicts NONE"
err=$(mktemp)
if addon=$(aws eks describe-addon --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --addon-name vpc-cni \
     --query 'addon.[status,addonVersion]' --output json 2>"$err"); then
  rm -f "$err"
else
  msg=$(cat "$err"); rm -f "$err"
  if [[ "$msg" == *ResourceNotFoundException* ]]; then
    die "PREREQUISITE NOT MET: cluster $CLUSTER_NAME has no managed vpc-cni add-on, so a node from this blueprint's AMI gets no pod network and never goes Ready.
This blueprint does not change cluster-wide settings. Install the add-on yourself, at the version you pin, then re-run:
  $create_cmd
(find the version: aws eks describe-addon-versions --region $AWS_REGION --addon-name vpc-cni --kubernetes-version ${KUBERNETES_VERSION})"
  fi
  die "could not read the vpc-cni add-on of cluster $CLUSTER_NAME (could not determine, not absent): $msg"
fi
read -r cni_status cni_version < <(python3 -c 'import json,sys; s,v=json.loads(sys.argv[1]); print(s,v)' "$addon")
log "vpc-cni add-on: status=$cni_status version=$cni_version"
evidence VPC_CNI_ADDON "$cni_version status=$cni_status"
[ "$cni_status" = ACTIVE ] || die "the vpc-cni add-on of cluster $CLUSTER_NAME is $cni_status, not ACTIVE; wait for it or fix it, then re-run"

# --- 3. Both sandbox RuntimeClasses, read only -----------------------------------------------
label_key="${NODE_LABEL%%=*}"; label_val="${NODE_LABEL#*=}"
for rc in isolated-sandbox confidential-sandbox; do
  rc_err=$(mktemp)
  if ! rc_json=$(kc get runtimeclass "$rc" -o json 2>"$rc_err"); then
    msg=$(cat "$rc_err"); rm -f "$rc_err"
    if [[ "$msg" == *NotFound* || "$msg" == *"not found"* ]]; then
      die "PREREQUISITE NOT MET: the cluster has no $rc RuntimeClass. Install the isolated-sandbox and confidential-sandbox RuntimeClass objects once (Amazon EKS User Guide, Create and update a Nitro Sandbox AMI > Install the RuntimeClass objects). This blueprint reuses them and never creates or changes them."
    fi
    die "could not read RuntimeClass $rc (could not determine): $msg"
  fi
  rm -f "$rc_err"
  verdict=$(python3 -c '
import json, sys
rc = json.loads(sys.argv[1]); key, val = sys.argv[2], sys.argv[3]
sel = (rc.get("scheduling") or {}).get("nodeSelector") or {}
missing = [f"{k}={v}" for k, v in sorted(sel.items()) if not (k == key and v == val) and True]
# a RuntimeClass that selects only the node label is satisfied; report any selector the node label does not provide
miss = [f"{k}={v}" for k, v in sorted(sel.items()) if (k, v) != (key, val)]
print("handler=" + str(rc.get("handler")))
print("missing=" + ",".join(miss))
' "$rc_json" "$label_key" "$label_val")
  handler=$(printf '%s\n' "$verdict" | sed -n 's/^handler=//p')
  missing=$(printf '%s\n' "$verdict" | sed -n 's/^missing=//p')
  [ "$handler" = "$rc" ] || die "RuntimeClass $rc has handler '$handler', not $rc; this is a question for the spec. The blueprint does not change a shared RuntimeClass."
  [ -z "$missing" ] || die "RuntimeClass $rc selects $missing, which the blueprint's node label ($NODE_LABEL) does not provide. A question for the spec; the blueprint does not change a shared RuntimeClass."
  log "RuntimeClass $rc: handler=$handler nodeSelector satisfied by $NODE_LABEL"
  evidence "RUNTIMECLASS_${rc//-/_}" "handler=$handler"
done

# --- 4. Karpenter, when the karpenter join path is selected ----------------------------------
if [[ "$JOIN_MODE" == karpenter || "$JOIN_MODE" == both ]]; then
  if kc get crd ec2nodeclasses.karpenter.k8s.aws >/dev/null 2>&1 && kc get crd nodepools.karpenter.sh >/dev/null 2>&1; then
    kver=$(kc get deployment -n "${KARPENTER_NAMESPACE:-kube-system}" karpenter -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo unknown)
    log "Karpenter present (ec2nodeclasses + nodepools CRDs): $kver"
    evidence KARPENTER "$kver"
  else
    die "PREREQUISITE NOT MET (JOIN_MODE=$JOIN_MODE): Karpenter is not installed (ec2nodeclasses.karpenter.k8s.aws / nodepools.karpenter.sh CRDs absent). Install Karpenter at a pinned version first (https://karpenter.sh/docs/getting-started/), then re-run. The blueprint reuses a shared Karpenter install as it is and never changes it. (Set JOIN_MODE=nodegroup to skip the Karpenter path.)"
  fi
fi

echo "CLUSTER PREREQUISITES OK: standard cluster; vpc-cni $cni_version ACTIVE; isolated-sandbox and confidential-sandbox RuntimeClasses reused as they are${JOIN_MODE:+; JOIN_MODE=$JOIN_MODE}"
