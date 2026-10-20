#!/usr/bin/env bash
# Assert what the EBS sample claims: a sandboxed pod honours its EBS volume, the data
# outlives the pod, a non-root process writes it, the second ReadWriteOncePod claimant
# stays Pending, and the volume AWS provisioned is an encrypted gp3.
#
#   NAMESPACE=<ns> ./scripts/test.sh
#
# Run ./scripts/setup.sh first. This deletes and recreates the pod to prove durability,
# so it takes a few minutes. It changes nothing cluster-wide, and leaves the pod running;
# tear down with ./scripts/clean.sh.
#
# Overridable: NAMESPACE, STORAGE_CLASS, KUBECTL, AWS (the aws CLI, e.g.
#   AWS="aws --profile my-profile"). The EC2-side checks are skipped when aws is absent.
set -uo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NAMESPACE="${NAMESPACE:-nitro-ebs-sample}"
STORAGE_CLASS="${STORAGE_CLASS:-auto-ebs-sc}"
KUBECTL="${KUBECTL:-kubectl}"
AWS="${AWS:-aws}"

POD=ebs-sandbox
PVC=ebs-sandbox-data

pass=0; fail=0
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
assert() { # assert <description> <status>
  if [[ "$2" -eq 0 ]]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}
skip() { printf '  SKIP  %s\n' "$1"; }

command -v "${KUBECTL%% *}" >/dev/null 2>&1 || die "'$KUBECTL' is not on PATH"
$KUBECTL get pod "$POD" -n "$NAMESPACE" >/dev/null 2>&1 \
  || die "pod/$POD not found in namespace '$NAMESPACE'. Run ./scripts/setup.sh first."

echo "== the cluster default StorageClass before the run =="
# Record whatever class (if any) carries the default annotation, so the end of the run
# can show it is unchanged. "none" is a valid answer.
default_before="$($KUBECTL get storageclass \
  -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null)"
default_before="${default_before:-none}"
echo "  default class: ${default_before}"
# This sample's shipped manifest must carry no default annotation.
shipped_default="$($KUBECTL create --dry-run=client -f "$SAMPLE_DIR/deploy/storage-class.yaml" \
  -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null)"
echo "  deploy/storage-class.yaml is-default-class annotation: '${shipped_default:-<none>}'"

echo "== 1/6 what the pod reported at boot =="
$KUBECTL logs "$POD" -n "$NAMESPACE" | sed 's/^/  /'

echo "== 2/6 the sandbox, the device backing /data, and the mount ownership =="
rc="$($KUBECTL get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.runtimeClassName}')"
kernel="$($KUBECTL exec "$POD" -n "$NAMESPACE" -- uname -rv)"
disks="$($KUBECTL exec "$POD" -n "$NAMESPACE" -- sh -c 'ls /sys/block | tr "\n" " "')"
uptime_pod="$($KUBECTL exec "$POD" -n "$NAMESPACE" -- cat /proc/uptime | awk '{print $1}')"
data_dev="$($KUBECTL exec "$POD" -n "$NAMESPACE" -- sh -c 'df /data | tail -1 | awk "{print \$1}"' | tr -d '[:space:]')"
mount_owner="$($KUBECTL exec "$POD" -n "$NAMESPACE" -- sh -c 'ls -ld /data' )"
run_uid="$($KUBECTL exec "$POD" -n "$NAMESPACE" -- id -u | tr -d '[:space:]')"
pv_before="$($KUBECTL get pvc "$PVC" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')"
pvc_modes="$($KUBECTL get pvc "$PVC" -n "$NAMESPACE" -o jsonpath='{.spec.accessModes[*]}')"
boots_before="$($KUBECTL exec "$POD" -n "$NAMESPACE" -- sh -c 'grep -c booted /data/boot-log.txt' | tr -d '[:space:]')"
echo "  runtimeClassName:  $rc"
echo "  guest kernel:      $kernel"
echo "  /sys/block:        $disks"
echo "  pod uptime (s):    $uptime_pod"
echo "  /data device:      ${data_dev:-<none>}"
echo "  /data ownership:   $mount_owner"
echo "  process uid:       $run_uid"
echo "  PersistentVolume:  $pv_before"
echo "  PVC access modes:  ${pvc_modes:-<none>}"
echo "  boot log lines:    $boots_before"

echo "== 3/6 the network-isolated pod has only loopback =="
addrs="$($KUBECTL exec "$POD" -n "$NAMESPACE" -- sh -c 'ip -o addr show 2>/dev/null | awk "{print \$2\"=\"\$4}" | tr "\n" " "' 2>/dev/null)"
route="$($KUBECTL exec "$POD" -n "$NAMESPACE" -- sh -c 'ip route show default 2>/dev/null' 2>/dev/null)"
echo "  addresses:  ${addrs:-<none>}"
echo "  default route:  ${route:-<none>}"

echo "== 4/6 a non-root process writes /data, flushed to the volume =="
marker="written-at-$($KUBECTL exec "$POD" -n "$NAMESPACE" -- date -u +%s | tr -d '[:space:]')"
# dd ... conv=fsync writes the file and fsync()s it, so the bytes reach the EBS volume
# before step 5 tears the guest down; a plain echo only dirties the guest page cache.
$KUBECTL exec "$POD" -n "$NAMESPACE" -- sh -c "printf '%s\n' '$marker' | dd of=/data/marker.txt conv=fsync 2>/dev/null && sync"
flushed=$?
readback="$($KUBECTL exec "$POD" -n "$NAMESPACE" -- cat /data/marker.txt | tr -d '[:space:]')"
echo "  wrote + fsynced:  $([[ $flushed -eq 0 ]] && echo ok || echo "FAILED (exit $flushed)")"
echo "  read back:        ${readback:-<empty>}"

echo "== 5/6 delete the pod, recreate it, and check the data survived =="
echo "  deleting $POD (the PVC and its EBS volume are left alone)..."
$KUBECTL delete pod "$POD" -n "$NAMESPACE" --wait=true
phase_after_delete="$($KUBECTL get pvc "$PVC" -n "$NAMESPACE" -o jsonpath='{.status.phase}')"
echo "  PVC phase with no pod: $phase_after_delete"
NAMESPACE="$NAMESPACE" STORAGE_CLASS="$STORAGE_CLASS" KUBECTL="$KUBECTL" \
  "$SAMPLE_DIR/scripts/setup.sh" >/dev/null || die "recreating the pod failed; run ./scripts/setup.sh to see why"
$KUBECTL wait -n "$NAMESPACE" --for=condition=Ready pod/"$POD" --timeout=5m >/dev/null \
  || die "recreated pod never became Ready"
pv_after="$($KUBECTL get pvc "$PVC" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')"
pod_uid_after="$($KUBECTL get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
boots_after="$($KUBECTL exec "$POD" -n "$NAMESPACE" -- sh -c 'grep -c booted /data/boot-log.txt' | tr -d '[:space:]')"
marker_after="$($KUBECTL exec "$POD" -n "$NAMESPACE" -- cat /data/marker.txt 2>/dev/null | tr -d '[:space:]')"
echo "  PersistentVolume:  $pv_after"
echo "  new pod UID:       $pod_uid_after"
echo "  boot log lines:    $boots_after"
echo "  marker.txt:        ${marker_after:-<gone>}"

echo "== 6/6 a second pod claiming the same ReadWriteOncePod volume stays Pending =="
$KUBECTL apply -n "$NAMESPACE" -f "$SAMPLE_DIR/deploy/pod-ebs-second.yaml" >/dev/null
# Give the scheduler a moment to make its decision.
sleep 10
second_phase="$($KUBECTL get pod ebs-sandbox-second -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)"
second_reason="$($KUBECTL get pod ebs-sandbox-second -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].reason} {.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null)"
echo "  ebs-sandbox-second phase:  ${second_phase:-<none>}"
echo "  PodScheduled:              ${second_reason:-<none>}"

echo "== what AWS says about the provisioned volume =="
# aws_available distinguishes the two reasons the EC2 checks might not produce a value:
# aws is not installed (a genuine SKIP), versus aws is installed but the lookup failed (a
# FAIL, not a skip). ec2_ok is set only when the describe-volumes call actually succeeded.
vol_id=""; vol_encrypted=""; vol_type=""; aws_available=no; ec2_ok=no
if command -v "${AWS%% *}" >/dev/null 2>&1; then
  aws_available=yes
  vol_id="$($KUBECTL get pv "$pv_after" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)"
  vol_zone="$($KUBECTL get pv "$pv_after" \
    -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[*].matchExpressions[?(@.key=="topology.kubernetes.io/zone")].values[0]}' 2>/dev/null)"
  vol_region="${AWS_REGION:-${vol_zone%[a-z]}}"
  # Capture the command's output AND its exit status (process substitution with read drops
  # the status, turning a failed lookup into a silent skip). On success parse the fields; on
  # failure leave ec2_ok=no so the assertion FAILS rather than skips.
  ec2_err="$(mktemp)"
  if ec2_out="$($AWS ec2 describe-volumes --volume-ids "$vol_id" --region "$vol_region" \
      --query 'Volumes[0].[Encrypted,VolumeType]' --output text 2>"$ec2_err")"; then
    read -r vol_encrypted vol_type <<<"$ec2_out"
    ec2_ok=yes
  else
    echo "  describe-volumes failed: $(sed 's/^/    /' "$ec2_err")"
  fi
  rm -f "$ec2_err"
  echo "  EC2 volume:   ${vol_id:-<unknown>} in ${vol_region:-<unknown>}"
  echo "  Encrypted:    ${vol_encrypted:-<unknown>}"
  echo "  VolumeType:   ${vol_type:-<unknown>}"
else
  echo "  aws CLI not on PATH; skipping the EC2-side checks."
fi

echo "== the cluster default StorageClass after the run =="
default_after="$($KUBECTL get storageclass \
  -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null)"
default_after="${default_after:-none}"
echo "  default class: ${default_after}"

echo "== assertions =="
[[ "$rc" == "isolated-sandbox" ]]; assert "pod opted into the isolated-sandbox runtime class" $?
[[ "$pvc_modes" == "ReadWriteOncePod" ]]; assert "the claim is ReadWriteOncePod (${pvc_modes:-none}), one pod not just one node" $?
[[ "$data_dev" == /dev/vd* ]]; assert "/data is a virtio device ($data_dev), not the node's nvme*" $?
[[ -n "$disks" && "$disks" != *nvme* ]]; assert "the guest sees virtio disks ($disks), no nvme device" $?
[[ "$run_uid" != "0" ]]; assert "the writer runs as a non-root uid ($run_uid)" $?
case "$mount_owner" in *" 2000 "*) m=0;; *) m=1;; esac; assert "/data is group-owned by the fsGroup gid 2000 ($mount_owner)" "$m"
[[ "$readback" == "$marker" ]]; assert "/data is writable by the non-root process and reads back what was written" $?
[[ "$flushed" -eq 0 ]]; assert "the marker write was fsync'd to the volume before teardown (flush exit $flushed)" $?
# network-isolated: only loopback has an address and there is no default route
case "$addrs" in *"eth0"*) n=1;; *"lo=127.0.0.1/8"*) n=0;; *) n=1;; esac; assert "only loopback has an address ($addrs)" "$n"
[[ -z "$route" ]]; assert "the network-isolated pod has no default route" $?
[[ "$phase_after_delete" == "Bound" ]]; assert "the PVC stayed Bound while no pod existed" $?
[[ "$pv_after" == "$pv_before" ]]; assert "the same PersistentVolume was re-attached to the new guest ($pv_after)" $?
[[ "${boots_after:-0}" -gt "${boots_before:-0}" ]]; assert "the boot log grew from $boots_before to $boots_after lines, earlier writes survived" $?
[[ "$marker_after" == "$marker" ]]; assert "the marker written by the previous guest is still readable" $?
[[ "$second_phase" == "Pending" ]]; assert "the second ReadWriteOncePod claimant stays Pending ($second_phase)" $?
[[ "$shipped_default" != "true" ]]; assert "deploy/storage-class.yaml carries no default-class annotation (is-default-class='${shipped_default:-<none>}')" $?
[[ "$default_after" == "$default_before" ]]; assert "the cluster default class is unchanged across the run ($default_before -> $default_after)" $?
if [[ "$aws_available" == no ]]; then
  # aws genuinely absent: this check cannot run, so skip it rather than fail it.
  skip "the provisioned EC2 volume is an encrypted gp3 (needs the aws CLI and ec2:DescribeVolumes)"
elif [[ "$ec2_ok" != yes ]]; then
  # aws IS installed but the lookup failed: that is a failure to verify the claim, not a
  # skip. Report it as a FAIL so a broken read cannot pass as "not checked".
  assert "the provisioned EC2 volume could be read back (describe-volumes succeeded)" 1
else
  [[ "${vol_encrypted,,}" == "true" ]]; assert "AWS reports the provisioned volume $vol_id as encrypted (Encrypted=${vol_encrypted:-unknown})" $?
  [[ "$vol_type" == "gp3" ]]; assert "AWS reports it as gp3 ($vol_type), the StorageClass request reached the volume" $?
fi

echo
echo "cleaning up the second pod (it never started)..."
$KUBECTL delete pod ebs-sandbox-second -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "EBS data outlived the guest VM that wrote it, and nothing cluster-wide changed."
