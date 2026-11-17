#!/usr/bin/env bash
# setup.sh: build the AL2023 Nitro Sandbox AMI with the upstream amazon-eks-ami packer flow,
# add it to an EXISTING standard (non-Auto-Mode) cluster via Karpenter and/or a managed node
# group, and run a hello-world isolated-sandbox pod beside an ordinary pod to prove it.
#
#   ./setup.sh                 # pick a run id, check prereqs, build, join (JOIN_MODE), run pods
#   ./setup.sh --ami-only      # build and tag the AMI only; no cluster change
#   RUN_ID=<id> ./setup.sh --join   # join a run's already-built AMI and run the pods
#
# This blueprint never creates a cluster, a node group's VPC, or any cluster-wide install; it
# adds one dedicated, tainted node group and/or a Karpenter NodePool, and reuses the cluster's
# vpc-cni, RuntimeClasses and (for the Karpenter path) Karpenter as they are.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR="$HERE"
. "$HERE/scripts/lib/common.sh"

mode=full
case "${1:-}" in
  --ami-only) mode=ami-only ;;
  --join)     mode=join ;;
  "")         mode=full ;;
  *) die "unknown argument: ${1:-} (use --ami-only or --join)" ;;
esac

# Pick or resume the run id.
if [ "$mode" = full ] || [ "$mode" = ami-only ]; then
  if [ -z "${RUN_ID:-}" ]; then RUN_ID="$(new_run_id)"; fi
fi
require_run_id
mkdir -p "$RUN_STATE_DIR" "$EVIDENCE_DIR"
# Record the run's identity once, for resume/join/clean. A later command (a resume, --join) must
# match it, and never adds a second record: clean.sh reads the first and refuses any other.
STATE_FILE="$RUN_STATE_DIR/run-state.env"
account=$(aws sts get-caller-identity --query Account --output text) \
  || die "could not read the current AWS account (sts get-caller-identity failed); nothing was changed"
[[ "$account" =~ ^[0-9]{12}$ ]] || die "sts get-caller-identity returned '$account', not an account id; nothing was changed"
identity() { # identity <KEY> <VALUE>: record it if the run has none, otherwise it must match
  local have; have=$(sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | head -n 1)
  if [ -z "$have" ]; then printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"
  elif [ "$have" != "$2" ]; then die "$1 is '$2' but run $RUN_ID recorded '$have'; refusing to continue. Use the recorded value, or start a new run."; fi
}
for kv in "ACCOUNT_ID=$account" "RUN_ID=$RUN_ID" "RESOURCE_PREFIX=$RESOURCE_PREFIX" "CLUSTER_NAME=$CLUSTER_NAME" \
          "AWS_REGION=$AWS_REGION" "NAMESPACE=$NAMESPACE"; do
  identity "${kv%%=*}" "${kv#*=}"
done
grep -q '^JOIN_MODE=' "$STATE_FILE" || printf 'JOIN_MODE=%s\n' "$JOIN_MODE" >> "$STATE_FILE"
printf 'RUN_ID=%s\n' "$RUN_ID" > "$RUN_STATE_FILE"
log "run id: $RUN_ID (mode: $mode, JOIN_MODE: $JOIN_MODE)"

# --- Build the AMI (full, ami-only) ----------------------------------------------------------
if [ "$mode" = full ] || [ "$mode" = ami-only ]; then
  log "=== building the AL2023 Nitro Sandbox AMI (upstream packer) ==="
  RUN_ID="$RUN_ID" "$HERE/scripts/10-build-ami-packer.sh" > /dev/null || die "the AMI build failed"
  # The builder records the AMI in the run state; read it back from there and check it.
  AMI_ID="$(sed -n 's/^AMI_ID=//p' "$RUN_STATE_DIR/run-state.env" | tail -n 1)"
  [[ "$AMI_ID" =~ ^ami-[0-9a-f]+$ ]] || die "the build recorded no valid AMI id in $RUN_STATE_DIR/run-state.env (got '$AMI_ID')"
  export AMI_ID
  log "AMI built: $AMI_ID"
  if [ "$mode" = ami-only ]; then
    echo "AMI-only run complete: $AMI_ID (RunId=$RUN_ID). Join later with: RUN_ID=$RUN_ID ./setup.sh --join"
    exit 0
  fi
fi

# --- Cluster prerequisites (full, join) ------------------------------------------------------
log "=== checking cluster prerequisites (read only) ==="
RUN_ID="$RUN_ID" "$HERE/scripts/00c-check-cluster.sh"

# Ensure the namespace exists (create only when absent, per AGENTS.md), labelled as the blueprint's.
if ! kc get namespace "$NAMESPACE" >/dev/null 2>&1; then
  kc create namespace "$NAMESPACE"
  kc label namespace "$NAMESPACE" "app.kubernetes.io/part-of=$RESOURCE_PREFIX" "app.kubernetes.io/instance=$RUN_ID" --overwrite
else
  log "namespace $NAMESPACE already exists; reusing it (checking its label before anything is deleted is clean.sh's job)"
fi

: "${AMI_ID:=$(sed -n 's/^AMI_ID=//p' "$RUN_STATE_DIR/run-state.env" 2>/dev/null | tail -n 1)}"
: "${AMI_ID:?no AMI_ID for this run; run ./setup.sh (full) or --ami-only first}"
export AMI_ID

# --- Join (full, join) -----------------------------------------------------------------------
joined_nodegroup=0 joined_karpenter=0
if [[ "$JOIN_MODE" == nodegroup || "$JOIN_MODE" == both ]]; then
  log "=== join path: managed node group ==="
  RUN_ID="$RUN_ID" AMI_ID="$AMI_ID" "$HERE/scripts/join-nodegroup.sh"
  joined_nodegroup=1
fi
if [[ "$JOIN_MODE" == karpenter || "$JOIN_MODE" == both ]]; then
  log "=== join path: Karpenter ==="
  RUN_ID="$RUN_ID" AMI_ID="$AMI_ID" "$HERE/scripts/join-karpenter.sh"
  joined_karpenter=1
fi

# --- Run the proof pods ----------------------------------------------------------------------
# Target the node brought up by whichever path ran. Prefer the node group (a concrete node
# exists); for karpenter-only, the NodePool label selects and a node is provisioned on demand.
if [ "$joined_nodegroup" = 1 ]; then
  sel_key="eks.amazonaws.com/nodegroup"; sel_val="$NODEGROUP_NAME"
else
  sel_key="sandbox.blueprint/al2023-ami"; sel_val="true"
fi
log "=== applying the hello-world isolated pod and the ordinary contrast pod ==="
render_pod() {
  sed -e "s|@NODE_SELECTOR_KEY@|$sel_key|g" -e "s|@NODE_SELECTOR_VALUE@|$sel_val|g" \
      -e "s|namespace: al2023-ami-sample|namespace: $NAMESPACE|g" "$1"
}
render_pod "$SAMPLE_DIR/deploy/pod-isolated-sandbox.yaml" | kc apply -n "$NAMESPACE" -f -
render_pod "$SAMPLE_DIR/deploy/pod-ordinary.yaml"         | kc apply -n "$NAMESPACE" -f -

log "waiting for the isolated pod to run"
kc wait -n "$NAMESPACE" --for=condition=Ready pod/isolated-sandbox-hello --timeout=300s || true
kc wait -n "$NAMESPACE" --for=condition=Ready pod/ordinary-hello --timeout=300s || true

echo
echo "=== setup complete (RunId=$RUN_ID) ==="
echo "Inspect with ./test.sh, or directly:"
echo "  kubectl --context \$KUBE_CONTEXT -n $NAMESPACE logs isolated-sandbox-hello"
echo "  kubectl --context \$KUBE_CONTEXT -n $NAMESPACE logs ordinary-hello"
echo "Clean up with ./clean.sh"
