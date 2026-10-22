#!/usr/bin/env bash
# Assert what the shared EFS sample claims:
#   - both pods run in a sandbox (own kernel, boot and virtio disks);
#   - each /shared is an nfs4 mount to the guest's own endpoint, and the node holds no
#     NFS mount for the pods;
#   - the access point pins UID/GID 1000 on /shared, and a non-root container writes it;
#   - the security group admits TCP 2049 from the cluster only; the file system policy
#     requires TLS, is confined to this access point, grants ClientMount/ClientWrite only
#     (no ClientRootAccess), and allows only the CSI node principal;
#   - the pods mount with tls,iam; cross-pod visibility works both ways; an outbound
#     internet connection is refused by the egress policy.
#
#   NAMESPACE=<ns> ./scripts/test.sh
#
# This is the maintainers' own end-to-end check; it is NOT part of the published page (the
# page shows the plain kubectl/aws commands for each stage). It runs ./scripts/setup.sh to
# build and deploy the sample if it is not already up, then asserts every claim on the live
# pods. It leaves the pods running; tear down with ./scripts/clean.sh.
#
# Overridable: NAMESPACE, ENV_FILE, KUBECTL, AWS (e.g. AWS="aws --profile my-profile").
set -uo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$SAMPLE_DIR/.env}"
NAMESPACE="${NAMESPACE:-nitro-efs-sample}"
KUBECTL="${KUBECTL:-kubectl}"
AWS="${AWS:-aws}"

SAMPLE="storage-efs"
SAMPLE_LABEL_KEY="app.kubernetes.io/part-of"
SAMPLE_LABEL_VALUE="storage-efs"
WRITER=efs-writer
READER=efs-reader

pass=0; fail=0
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
assert() { if [[ "$2" -eq 0 ]]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }

command -v "${KUBECTL%% *}" >/dev/null 2>&1 || die "'$KUBECTL' is not on PATH"

# Build the AWS side AND deploy the Kubernetes side: setup.sh does both (its Step 5 deploys the
# egress policy and the pods) and is idempotent. Run it UNCONDITIONALLY, so the live state the
# assertions inspect always matches what .env describes: a shortcut that skipped setup when the
# pods merely existed could assert against a stale deployment (old pods) while the AWS-side
# assertions read the resources in the current .env.
echo "Running ./scripts/setup.sh to build and deploy the sample (idempotent)."
NAMESPACE="$NAMESPACE" ENV_FILE="$ENV_FILE" "$SAMPLE_DIR/scripts/setup.sh"
# shellcheck disable=SC1090
source "$ENV_FILE"
[[ -n "${EFS_FILE_SYSTEM_ID:-}" && -n "${EFS_ACCESS_POINT_ID:-}" ]] \
  || die "$ENV_FILE is missing the EFS IDs; run ./scripts/setup.sh"

AWS_REGION="${AWS_REGION:-us-west-2}"
aws_r() { $AWS "$@" --region "$AWS_REGION"; }

echo "  confirming both pods are Ready..."
$KUBECTL wait -n "$NAMESPACE" --for=condition=Ready pod/$WRITER pod/$READER --timeout=5m \
  || die "the pods are not Ready. Run ./scripts/setup.sh, or check:
  $KUBECTL describe pod $WRITER -n $NAMESPACE
  $KUBECTL logs -n kube-system daemonset/efs-csi-node -c efs-plugin --tail=100"

echo
echo "== 1/9 both pods run in a sandbox =="
node="$($KUBECTL get pod "$WRITER" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')"
node_kernel="$($KUBECTL get node "$node" -o jsonpath='{.status.nodeInfo.kernelVersion}')"
echo "  node kernel: $node_kernel"
# Each pod runs in its own guest. The proof is that the pod sees virtio (vd*) block devices,
# where an ordinary pod on the same node sees nvme, and reports its own kernel and a boot/uptime
# of its own. The guest kernel VERSION may match the node's (the sandbox AMI can share a build
# with the node AMI), so the virtio devices, not a differing version string, are the evidence.
for pod in "$WRITER" "$READER"; do
  rc="$($KUBECTL get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.runtimeClassName}')"
  [[ "$rc" == "isolated-sandbox" ]]; assert "$pod runtimeClassName is isolated-sandbox ($rc)" $?
  gk="$($KUBECTL exec "$pod" -n "$NAMESPACE" -- uname -rv 2>/dev/null)"
  echo "  $pod guest kernel: $gk"
  [[ -n "$gk" ]]; assert "$pod reports its own guest kernel ($gk)" $?
  # The guest booted with the pod, so its uptime is small (far less than the node's). A node's
  # /proc/uptime would be hours or days; a just-booted guest is seconds to minutes.
  up="$($KUBECTL exec "$pod" -n "$NAMESPACE" -- sh -c 'cut -d. -f1 /proc/uptime' 2>/dev/null)"
  echo "  $pod guest uptime: ${up}s"
  # Validate it is numeric BEFORE the arithmetic, so a missing or odd value fails the assertion
  # rather than crashing the shell under set -u.
  if [[ "$up" =~ ^[0-9]+$ ]] && (( up < 86400 )); then
    assert "$pod guest uptime (${up}s) is a freshly booted guest, not the long-running node" 0
  else
    assert "$pod guest uptime (${up:-unknown}) is a freshly booted guest, not the long-running node" 1
  fi
  # Block devices: at least one real virtio vd* entry, and NO nvme entry. The node presents EBS
  # as nvme; a virtio-only device list is the guest's own devices, not the node's passed through.
  disks="$($KUBECTL exec "$pod" -n "$NAMESPACE" -- sh -c 'ls /sys/block' 2>/dev/null)"
  echo "  $pod /sys/block: $(tr '\n' ' ' <<<"$disks")"
  has_vd=1; has_nvme=0
  grep -qE '^vd[a-z]+$' <<<"$disks" && has_vd=0
  grep -qE '^nvme' <<<"$disks" && has_nvme=1
  [[ "$has_vd" -eq 0 && "$has_nvme" -eq 0 ]]; assert "$pod guest has a virtio vd* disk and no nvme (a separate guest, not the node's devices)" $?
done

echo "== 2/9 /shared is an nfs4 mount to the guest's own endpoint =="
for pod in "$WRITER" "$READER"; do
  mnt="$($KUBECTL exec "$pod" -n "$NAMESPACE" -- grep ' /shared ' /proc/mounts || true)"
  echo "  $pod: $mnt"
  grep -q 'nfs4' <<<"$mnt" && grep -q '127.0.0.1' <<<"$mnt"; assert "$pod /shared is an nfs4 mount to the guest's 127.0.0.1 endpoint" $?
done

echo "== 3/9 the node holds no NFS mount for these pods =="
# The guest terminates TLS and runs the NFS client itself, so the node should carry no nfs4
# mount under /var/lib/kubelet for these pods. Run a helper pod with a DETERMINISTIC name on
# the writer's node to read its /proc/mounts via the host mount namespace. This assertion is
# MANDATORY: if the helper cannot start, record a failure rather than skip it. The helper is
# created, discovered and deleted by its exact name only, never by a label selector, so it
# can never match another workload's pod on this shared cluster.
dbgpod="efs-nodecheck-$$"
probe_created=false
# CREATE (not apply): create fails if a pod of this exact name already exists, so this can never
# adopt, and later never delete, a pod it did not make. We only delete when probe_created=true.
if cat <<YAML | $KUBECTL create -n "$NAMESPACE" -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: $dbgpod
  labels:
    app: efs-nodecheck
spec:
  nodeName: $node
  hostPID: true
  restartPolicy: Never
  tolerations:
    - operator: Exists
  containers:
    - name: probe
      image: public.ecr.aws/docker/library/busybox:1.37
      securityContext:
        privileged: true
      command: ["sh", "-c", "sleep 120"]
YAML
then
  probe_created=true
fi
node_nfs=""; probe_rc=1
if $probe_created && $KUBECTL wait -n "$NAMESPACE" --for=condition=Ready "pod/$dbgpod" --timeout=90s >/dev/null 2>&1; then
  # Read the host's /proc/1/mounts (hostPID + privileged) and count nfs4 kubelet mounts.
  node_nfs="$($KUBECTL exec -n "$NAMESPACE" "$dbgpod" -- sh -c 'grep nfs4 /proc/1/mounts 2>/dev/null | grep -c kubelet || true' 2>/dev/null | tr -d ' ')"
  probe_rc=$?
fi
$probe_created && $KUBECTL delete pod "$dbgpod" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1
if [[ "$probe_rc" -ne 0 || -z "$node_nfs" ]]; then
  assert "the node holds no kubelet nfs4 mount for these pods (node probe could not run)" 1
else
  [[ "$node_nfs" == "0" ]]; assert "the node holds no kubelet nfs4 mount for these pods (found $node_nfs)" $?
fi

echo "== 4/9 the access point pins UID/GID on /shared =="
owner="$($KUBECTL exec "$WRITER" -n "$NAMESPACE" -- stat -c '%u %g' /shared 2>/dev/null || $KUBECTL exec "$WRITER" -n "$NAMESPACE" -- sh -c 'ls -ldn /shared | awk "{print \$3, \$4}"')"
echo "  /shared owner uid gid: $owner"
[[ "$owner" == "1000 1000" ]]; assert "/shared is owned by the access point's uid/gid 1000" $?

echo "== 5/9 a non-root container writes /shared =="
id_out="$($KUBECTL exec "$WRITER" -n "$NAMESPACE" -- id)"
echo "  $id_out"
grep -q 'uid=1000' <<<"$id_out"; assert "the writer runs as non-root uid 1000" $?
$KUBECTL exec "$WRITER" -n "$NAMESPACE" -- sh -c 'echo hello-from-writer > /shared/from-writer && cat /shared/from-writer >/dev/null'; assert "the non-root writer wrote /shared" $?

echo "== 6/9 cross-pod visibility both ways =="
$KUBECTL exec "$READER" -n "$NAMESPACE" -- sh -c 'test "$(cat /shared/from-writer)" = hello-from-writer'; assert "the reader sees the file the writer wrote" $?
$KUBECTL exec "$READER" -n "$NAMESPACE" -- sh -c 'echo hello-from-reader > /shared/from-reader'; assert "the reader wrote a file" $?
$KUBECTL exec "$WRITER" -n "$NAMESPACE" -- sh -c 'test "$(cat /shared/from-reader)" = hello-from-reader'; assert "the writer sees the file the reader wrote" $?

echo "== 7/9 the pods mount with tls,iam =="
# Compare the normalized mount-option SET exactly, so a stray option (e.g. notls) cannot pass
# a substring match.
opts_json="$($KUBECTL get pv storage-efs-shared -o jsonpath='{.spec.mountOptions}')"
echo "  PV mountOptions: $opts_json"
printf '%s' "$opts_json" | python3 -c 'import json,sys
try: v=set(json.load(sys.stdin))
except Exception: sys.exit(1)
sys.exit(0 if v=={"tls","iam"} else 1)'; assert "the PV mount options are exactly {tls, iam}" $?
mnt_opt="$($KUBECTL exec "$WRITER" -n "$NAMESPACE" -- grep ' /shared ' /proc/mounts)"
grep -q 'port=' <<<"$mnt_opt"; assert "the live mount runs over the stunnel TLS endpoint (local port)" $?

if command -v "${AWS%% *}" >/dev/null 2>&1; then
  echo "== 8/9 the security group and file system policy =="
  # The cluster SG must be readable; an empty value would let the SG check accept any source.
  CLUSTER_SG="$(aws_r eks describe-cluster --name "${CLUSTER_NAME:-}" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text 2>/dev/null)"
  if [[ $? -ne 0 || -z "$CLUSTER_SG" || "$CLUSTER_SG" == "None" ]]; then
    assert "could read the cluster security group id (needed to check the NFS rule)" 1
    CLUSTER_SG="__UNREADABLE__"
  else
    assert "read the cluster security group id" 0
  fi
  # EVERY mount target must carry only this sample's security group. A failed or empty listing
  # must fail, not pass vacuously.
  mt_ids="$(aws_r efs describe-mount-targets --file-system-id "$EFS_FILE_SYSTEM_ID" --query 'MountTargets[].MountTargetId' --output text 2>/dev/null)"
  mt_list_rc=$?
  mt_count=0; mt_sg_ok=0
  for mt in $mt_ids; do
    mt_count=$((mt_count+1))
    sg_on_mt="$(aws_r efs describe-mount-target-security-groups --mount-target-id "$mt" --query 'SecurityGroups' --output text 2>/dev/null)"
    [[ $? -eq 0 && "$sg_on_mt" == "$EFS_SECURITY_GROUP_ID" ]] || mt_sg_ok=1
  done
  [[ "$mt_list_rc" -eq 0 && "$mt_count" -ge 1 && "$mt_sg_ok" -eq 0 ]]; assert "every mount target (found $mt_count) carries only this sample's security group" $?
  # The security group admits exactly one rule: TCP 2049 from the cluster security group, with
  # no CIDR, no IPv6, no prefix list, and no other group source.
  sg_rules="$(aws_r ec2 describe-security-groups --group-ids "$EFS_SECURITY_GROUP_ID" --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)"
  if [[ $? -ne 0 ]]; then
    assert "the security group admits exactly TCP 2049 from the cluster security group" 1
  else
    CLUSTER_SG="$CLUSTER_SG" python3 -c 'import json,sys,os
r=json.load(sys.stdin); csg=os.environ.get("CLUSTER_SG","")
if not csg or csg=="__UNREADABLE__": sys.exit(1)
if len(r)!=1: sys.exit(1)
p=r[0]
if not (p.get("FromPort")==2049 and p.get("ToPort")==2049 and p.get("IpProtocol")=="tcp"): sys.exit(1)
if p.get("IpRanges") or p.get("Ipv6Ranges") or p.get("PrefixListIds"): sys.exit(1)
pairs=p.get("UserIdGroupPairs") or []
if len(pairs)!=1: sys.exit(1)
if pairs[0].get("GroupId")!=csg: sys.exit(1)
sys.exit(0)' <<<"$sg_rules"; assert "the security group admits exactly TCP 2049 from the cluster security group (no CIDR, IPv6, prefix list or other group)" $?
  fi
  # The file system policy, validated structurally and exactly.
  pol="$(aws_r efs describe-file-system-policy --file-system-id "$EFS_FILE_SYSTEM_ID" --query 'Policy' --output text)"
  ACCOUNT="$(aws_r sts get-caller-identity --query Account --output text)"
  FS_ARN="arn:aws:elasticfilesystem:${AWS_REGION}:${ACCOUNT}:file-system/${EFS_FILE_SYSTEM_ID}"
  AP_ARN="arn:aws:elasticfilesystem:${AWS_REGION}:${ACCOUNT}:access-point/${EFS_ACCESS_POINT_ID}"
  FS_ARN="$FS_ARN" AP_ARN="$AP_ARN" NODE="$EFS_CSI_NODE_ROLE_ARN" python3 -c 'import json,sys,os
p=json.load(sys.stdin); st=p["Statement"]
fs=os.environ["FS_ARN"]; ap=os.environ["AP_ARN"]; node=os.environ["NODE"]
def listify(x): return x if isinstance(x,list) else [x]
allows=[s for s in st if s.get("Effect")=="Allow"]
denies=[s for s in st if s.get("Effect")=="Deny"]
# Every Allow: principal is EXACTLY the node role (a dict with AWS == node, nothing else),
# Resource is the file system, actions are a nonempty subset of {ClientMount, ClientWrite}
# (so ClientRootAccess cannot appear), confined to this access point via a mount target.
def allow_ok(s):
    pr=s.get("Principal")
    if not (isinstance(pr,dict) and list(pr.keys())==["AWS"] and pr["AWS"]==node): return False
    if listify(s.get("Resource"))!=[fs]: return False
    acts=set(listify(s.get("Action")))
    if not acts or not acts<= {"elasticfilesystem:ClientMount","elasticfilesystem:ClientWrite"}: return False
    cond=s.get("Condition",{})
    if cond.get("StringEquals",{}).get("elasticfilesystem:AccessPointArn")!=ap: return False
    if cond.get("Bool",{}).get("elasticfilesystem:AccessedViaMountTarget")!="true": return False
    return True
# An EFFECTIVE universal TLS Deny on this file system: it must apply to every principal and to
# the EFS client actions (Principal "*" and Action "*", or a set covering the client actions),
# on this file system, with no narrowing condition other than aws:SecureTransport=false. A Deny
# scoped to one principal, or to unrelated actions, or carrying an extra condition, would not
# actually force TLS for the mount, so it is rejected.
def tls_deny_ok(s):
    if listify(s.get("Resource"))!=[fs]: return False
    if s.get("Principal")!="*": return False
    acts=listify(s.get("Action"))
    client={"elasticfilesystem:ClientMount","elasticfilesystem:ClientWrite","elasticfilesystem:ClientRootAccess"}
    if not ("*" in acts or client<=set(acts)): return False
    cond=s.get("Condition",{})
    if list(cond.keys())!=["Bool"]: return False
    if cond["Bool"]!={"aws:SecureTransport":"false"}: return False
    return True
ok = (len(allows)>=1 and all(allow_ok(s) for s in allows)
      and any(tls_deny_ok(s) for s in denies))
sys.exit(0 if ok else 1)' <<<"$pol"; assert "the file system policy: every Allow is the CSI node principal only, this file system and access point, mount-target only, actions subset of ClientMount/ClientWrite (no ClientRootAccess), plus an effective universal TLS Deny" $?
else
  echo "== 8/9 security group and file system policy: SKIP (aws not on PATH) =="
fi

echo "== 9/9 an outbound internet connection is refused by the egress policy =="
# The egress policy allows only DNS and NFS to the mount targets, so a TCP connect to a
# public address times out. busybox wget with a short timeout; non-zero means refused.
if $KUBECTL exec "$WRITER" -n "$NAMESPACE" -- sh -c 'wget -T 5 -q -O /dev/null https://example.com 2>/dev/null'; then
  assert "an outbound HTTPS connection to the internet is refused" 1
else
  assert "an outbound HTTPS connection to the internet is refused" 0
fi

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "Shared EFS works: two isolated-sandbox pods mount one access point with tls,iam and read each other's writes."
