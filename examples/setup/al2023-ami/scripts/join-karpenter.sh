#!/usr/bin/env bash
# join-karpenter.sh: provision nodes from the AL2023 Nitro Sandbox AMI with Karpenter. Renders
# deploy/karpenter-ec2nodeclass.yaml (spec.enclaveOptions.enabled: true, amiSelectorTerms pinned
# to the built AMI) and deploy/karpenter-nodepool.yaml with this run's values and applies them.
# Karpenter must already be installed (00c-check-cluster.sh verifies it); this blueprint reuses
# a shared Karpenter install as it is and never changes it.
#
# This path uses ONLY enclaveOptions.enabled + the custom AMI. It does NOT use the Nitro Enclaves
# device plugin, NodeOverlay or hugepages from Karpenter's "Using Nitro Enclaves" task: those are
# for running enclave applications, not for pod-isolation nodes.
#
#   RUN_ID=<id> AMI_ID=<ami> NODE_ROLE=<karpenter-node-role> scripts/join-karpenter.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
require_run_id
require_identity RESOURCE_PREFIX CLUSTER_NAME AWS_REGION NAMESPACE KUBERNETES_VERSION
require_kube_context
mkdir -p "$RUN_STATE_DIR" "$EVIDENCE_DIR" || die "could not create $EVIDENCE_DIR"
resolve_run_ami   # the run's recorded AMI, checked for this run's tags and NODE_ARCH
: "${NODE_ROLE:?set NODE_ROLE to the Karpenter node IAM role name (e.g. KarpenterNodeRole-\$CLUSTER_NAME)}"

# Confirm Karpenter is present before touching anything (reused, never installed here).
kc get crd ec2nodeclasses.karpenter.k8s.aws >/dev/null 2>&1 \
  || die "Karpenter not installed (ec2nodeclasses.karpenter.k8s.aws CRD absent). Install it at a pinned version first; this blueprint reuses a shared install as it is."

render() { # render <template> -> stdout, filling the run's placeholders
  sed -e "s|@AMI_ID@|$AMI_ID|g" \
      -e "s|@CLUSTER_NAME@|$CLUSTER_NAME|g" \
      -e "s|@NODE_ROLE@|$NODE_ROLE|g" \
      -e "s|@NODE_ARCH@|$NODE_ARCH|g" \
      -e "s|@RESOURCE_PREFIX@|$RESOURCE_PREFIX|g" \
      -e "s|@RUN_ID@|$RUN_ID|g" "$1"
}
out="$RUN_STATE_DIR/karpenter"
mkdir -p "$out"
render "$SAMPLE_DIR/deploy/karpenter-ec2nodeclass.yaml" > "$out/ec2nodeclass.yaml"
render "$SAMPLE_DIR/deploy/karpenter-nodepool.yaml"     > "$out/nodepool.yaml"
for f in "$out/ec2nodeclass.yaml" "$out/nodepool.yaml"; do
  grep -q '@[A-Z_]*@' "$f" && die "unrendered placeholder left in $f"
done

# Both objects have fixed names. Applying over one that is not this blueprint's would take it
# over, so stop if either exists without this blueprint's label.
# Only an explicit NotFound means absent; any other failed lookup stops the run.
for kind in nodepool ec2nodeclass; do
  err=$(mktemp)
  if existing=$(kc get "$kind" al2023-nitro-sandbox -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}/{.metadata.labels.app\.kubernetes\.io/instance}' 2>"$err"); then
    [ "$existing" = "$RESOURCE_PREFIX/$RUN_ID" ] || die "$kind al2023-nitro-sandbox already exists and is not run $RUN_ID's (labels '$existing'); not applying over it"
  elif ! grep -Eq 'Error from server \(NotFound\)' "$err"; then
    msg=$(head -n 2 "$err"); rm -f "$err"; die "could not determine whether $kind al2023-nitro-sandbox exists: $msg"
  fi
  rm -f "$err"
done

log "applying Karpenter EC2NodeClass and NodePool (AMI $AMI_ID)"
kc apply -f "$out/ec2nodeclass.yaml"
kc apply -f "$out/nodepool.yaml"

log "waiting for a Karpenter node with label $NODE_LABEL (provisioned on first sandbox pod demand)"
{
  printf 'KARPENTER_EC2NODECLASS=%s\n' "al2023-nitro-sandbox"
  printf 'KARPENTER_NODEPOOL=%s\n'     "al2023-nitro-sandbox"
} >> "$EVIDENCE_DIR/run-evidence.env"
echo "Karpenter EC2NodeClass + NodePool applied. A node is provisioned when a sandbox pod that tolerates the NodePool taint is scheduled (setup.sh applies the pods next)."
