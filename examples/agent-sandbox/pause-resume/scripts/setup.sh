#!/usr/bin/env bash
# Create the pause-resume Sandbox and wait until its guest is Running with the
# EBS workspace mounted.
#
#   ./scripts/setup.sh
#
# One Sandbox with an EBS volumeClaimTemplate. Its container appends a line to
# /workspace/boots.log on every boot, which is the record the suspend/resume
# cycle reads to prove the volume survived.
#
# Idempotent, and idempotent from the suspended state too: the manifest pins
# operatingMode: Running, so re-applying a sandbox an interrupted run left
# Suspended resumes it. A resume appends another boot line, which is why the
# cycle counts lines relative to what it finds rather than expecting exactly one.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

require_commands kubectl sed
show_context

# The runtime class must be present. On EKS Auto Mode it always is; on standard
# EKS the nodes need a sandbox-enabled AMI (see Hello sandbox).
kc_cluster get runtimeclass isolated-sandbox >/dev/null 2>&1 \
  || die "runtimeclass isolated-sandbox not found; run the Hello sandbox sample first"

# The agent-sandbox controller must be installed (Getting started > Warm pool).
kc_cluster get crd sandboxes.agents.x-k8s.io >/dev/null 2>&1 \
  || die "the agent-sandbox Sandbox CRD is not installed; run the Warm pool sample's install step first"

step "1/3 namespace $NAMESPACE"
# Create the namespace only when it is absent, and label it so clean up can tell
# it is the sample's. Applying over an existing namespace counts as reusing it,
# which would put our label on a namespace another demo owns, so check first. A
# read that fails is never read as "absent": we stop rather than create over it.
# namespace_is_ours returns non-zero for cases 1-3, so capture it without letting
# set -e abort the script before the case runs.
ns_rc=0
namespace_is_ours || ns_rc=$?
case $ns_rc in
  0) echo "namespace $NAMESPACE already exists and is the sample's; reusing it" ;;
  1) die "namespace $NAMESPACE exists but is not labelled $NS_LABEL_KEY=$NS_LABEL_VAL; it belongs to something else. Set NAMESPACE to a free name in .env and re-run." ;;
  2) die "could not read the labels on namespace $NAMESPACE; stopping rather than guess" ;;
  3) kc_cluster create namespace "$NAMESPACE"
     kc_cluster label namespace "$NAMESPACE" "$NS_LABEL_KEY=$NS_LABEL_VAL"
     echo "created namespace $NAMESPACE, labelled $NS_LABEL_KEY=$NS_LABEL_VAL" ;;
esac

step "2/3 apply sandbox/$SANDBOX"
# volumeClaimTemplates is immutable on the Sandbox CRD, so a sandbox created from
# an older copy of this manifest (a ReadWriteOnce claim, say) cannot be patched
# into this one. Detect the mismatch and say what to do, rather than letting the
# apply fail with a CEL message that does not mention the workspace it costs.
want_access=ReadWriteOncePod
live_access="$(kc get sandbox "$SANDBOX" \
  -o jsonpath='{.spec.volumeClaimTemplates[0].spec.accessModes[0]}' 2>/dev/null || true)"
if [[ -n "$live_access" && "$live_access" != "$want_access" ]]; then
  die "sandbox/$SANDBOX already exists with accessModes: [$live_access], and this manifest asks for $want_access.
       volumeClaimTemplates is immutable on the Sandbox CRD, so the Sandbox has to be recreated:
         ./scripts/cleanup.sh && ./scripts/setup.sh
       That DELETES the workspace and its EBS volume (boots.log included). Suspend preserves data; delete does not."
fi

# Render the manifest with this run's namespace, so an overridden NAMESPACE
# reaches the object. Never apply the file with its __NAMESPACE__ placeholder.
sed "s/__NAMESPACE__/$NAMESPACE/g" "$SAMPLE_DIR/deploy/sandbox.yaml" | kc apply -f -

step "3/3 wait for the guest to boot and mount the EBS workspace"
# Ready on a Sandbox means its pod is Ready, which also covers the CSI attach of
# the 10Gi auto-ebs-sc volume. The first sandboxed pod on a cold cluster waits
# for Auto Mode to launch a node, so the first run can take minutes.
kc wait --for=condition=Ready "sandbox/$SANDBOX" --timeout=10m \
  || die "sandbox never became Ready; check 'kubectl -n $NAMESPACE describe sandbox $SANDBOX' and 'kubectl -n $NAMESPACE describe pod $SANDBOX' (a stuck EBS attach shows up as FailedAttachVolume)"

# Tag the EBS volume the sample created ManagedBy=pause-resume, so it carries the
# sample's mark like every other AWS resource a sample makes. The namespace and
# the Sandbox's ownerReference are what the clean up uses; this tag is the mark a
# person or another script can filter on. Best effort: it needs the AWS CLI and
# credentials for the cluster's account, and the run does not depend on it, so a
# missing CLI or a denied call prints a note and the setup still succeeds.
tag_ebs_volume() {
  command -v aws >/dev/null 2>&1 || { echo "note: aws CLI not found; skipping the ManagedBy tag on the EBS volume"; return 0; }
  local pv volid
  # Guard each read so set -e does not abort setup on a failed kubectl: the tag
  # is best effort and setup must still succeed without it.
  if ! pv="$(kc get pvc "$PVC" -o jsonpath='{.spec.volumeName}' 2>/dev/null)" || [[ -z "$pv" ]]; then
    echo "note: could not read the PV name; skipping the ManagedBy tag"; return 0
  fi
  if ! volid="$(kc_cluster get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)"; then
    echo "note: could not read the EBS volume id; skipping the ManagedBy tag"; return 0
  fi
  case "$volid" in
    vol-*) ;;
    *) echo "note: PV $pv has no EBS volume id yet; skipping the ManagedBy tag"; return 0 ;;
  esac
  if aws ec2 create-tags --region "$AWS_REGION" --resources "$volid" \
       --tags "Key=ManagedBy,Value=$SAMPLE" >/dev/null 2>&1; then
    echo "tagged EBS volume $volid with ManagedBy=$SAMPLE"
  else
    echo "note: could not tag EBS volume $volid (missing or insufficient AWS credentials for $AWS_REGION); the volume is still tracked by its namespace and the Sandbox ownerReference"
  fi
}
tag_ebs_volume

echo
echo "sandbox/$SANDBOX is Running with /workspace mounted."
echo "Read the boot log:   kubectl -n $NAMESPACE exec $SANDBOX -- cat /workspace/boots.log"
echo "Suspend it:          ./scripts/suspend.sh"
echo "Resume it:           ./scripts/resume.sh"
echo "Tear it down:        ./scripts/cleanup.sh   (deletes the PVC and its EBS volume)"
