#!/usr/bin/env bash
# Assert what the shared S3 Files sample claims:
#   - both pods run in a sandbox (own kernel, boot and virtio disks);
#   - each /shared is an nfs4 mount to the guest's own endpoint, and the node holds no
#     NFS mount for the pods;
#   - the access point pins UID/GID 1000 on /shared, and a non-root container writes it;
#   - the security group admits TCP 2049 from the cluster only; the file system policy
#     allows only the CSI node principal ClientMount/ClientWrite (no ClientRootAccess) and
#     denies the EC2 node role; the bucket policy requires TLS and denies the EC2 node role;
#   - the workload ServiceAccount has no AWS identity and mounts no API token;
#   - the pods mount with tls,iam; cross-pod visibility works both ways;
#   - a file written through /shared appears as an object in the bucket, and an object put
#     in the bucket appears as a file on /shared (both ways, asynchronous, polled);
#   - an outbound internet connection is refused by the egress policy.
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
NAMESPACE="${NAMESPACE:-nitro-s3-files-sample}"
KUBECTL="${KUBECTL:-kubectl}"
AWS="${AWS:-aws}"

SAMPLE="storage-s3-files"
WRITER=s3-files-writer
READER=s3-files-reader

pass=0; fail=0
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
assert() { if [[ "$2" -eq 0 ]]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }

command -v "${KUBECTL%% *}" >/dev/null 2>&1 || die "'$KUBECTL' is not on PATH"

echo "Running ./scripts/setup.sh to build and deploy the sample (idempotent)."
NAMESPACE="$NAMESPACE" ENV_FILE="$ENV_FILE" "$SAMPLE_DIR/scripts/setup.sh"
# shellcheck disable=SC1090
source "$ENV_FILE"
[[ -n "${S3_FILES_FILE_SYSTEM_ID:-}" && -n "${S3_FILES_ACCESS_POINT_ID:-}" && -n "${S3_BUCKET_NAME:-}" ]] \
  || die "$ENV_FILE is missing the S3 Files IDs; run ./scripts/setup.sh"

AWS_REGION="${AWS_REGION:-us-west-2}"
aws_r() { $AWS "$@" --region "$AWS_REGION"; }

echo "  confirming both pods are Ready..."
$KUBECTL wait -n "$NAMESPACE" --for=condition=Ready pod/$WRITER pod/$READER --timeout=15m \
  || die "the pods are not Ready. Run ./scripts/setup.sh, or check:
  $KUBECTL describe pod $WRITER -n $NAMESPACE
  $KUBECTL logs -n kube-system daemonset/efs-csi-node -c efs-plugin --tail=100"

echo
echo "== 1/10 both pods run in a sandbox =="
node="$($KUBECTL get pod "$WRITER" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')"
node_kernel="$($KUBECTL get node "$node" -o jsonpath='{.status.nodeInfo.kernelVersion}')"
echo "  node kernel: $node_kernel"
for pod in "$WRITER" "$READER"; do
  rc="$($KUBECTL get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.runtimeClassName}')"
  [[ "$rc" == "isolated-sandbox" ]]; assert "$pod runtimeClassName is isolated-sandbox ($rc)" $?
  gk="$($KUBECTL exec "$pod" -n "$NAMESPACE" -- uname -rv 2>/dev/null)"
  echo "  $pod guest kernel: $gk"
  [[ -n "$gk" ]]; assert "$pod reports its own guest kernel ($gk)" $?
  up="$($KUBECTL exec "$pod" -n "$NAMESPACE" -- sh -c 'cut -d. -f1 /proc/uptime' 2>/dev/null)"
  echo "  $pod guest uptime: ${up}s"
  if [[ "$up" =~ ^[0-9]+$ ]] && (( up < 86400 )); then
    assert "$pod guest uptime (${up}s) is a freshly booted guest, not the long-running node" 0
  else
    assert "$pod guest uptime (${up:-unknown}) is a freshly booted guest, not the long-running node" 1
  fi
  disks="$($KUBECTL exec "$pod" -n "$NAMESPACE" -- sh -c 'ls /sys/block' 2>/dev/null)"
  echo "  $pod /sys/block: $(tr '\n' ' ' <<<"$disks")"
  has_vd=1; has_nvme=0
  grep -qE '^vd[a-z]+$' <<<"$disks" && has_vd=0
  grep -qE '^nvme' <<<"$disks" && has_nvme=1
  [[ "$has_vd" -eq 0 && "$has_nvme" -eq 0 ]]; assert "$pod guest has a virtio vd* disk and no nvme (a separate guest, not the node's devices)" $?
done

echo "== 2/10 /shared is an nfs4 mount to the guest's own endpoint =="
for pod in "$WRITER" "$READER"; do
  mnt="$($KUBECTL exec "$pod" -n "$NAMESPACE" -- grep ' /shared ' /proc/mounts || true)"
  echo "  $pod: $mnt"
  grep -q 'nfs4' <<<"$mnt" && grep -q '127.0.0.1' <<<"$mnt"; assert "$pod /shared is an nfs4 mount to the guest's 127.0.0.1 endpoint" $?
done

echo "== 3/10 the node holds no NFS mount for these pods =="
dbgpod="s3-files-nodecheck-$$"
probe_created=false
if cat <<YAML | $KUBECTL create -n "$NAMESPACE" -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: $dbgpod
  labels:
    app: s3-files-nodecheck
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
  node_nfs="$($KUBECTL exec -n "$NAMESPACE" "$dbgpod" -- sh -c 'grep nfs4 /proc/1/mounts 2>/dev/null | grep -c kubelet || true' 2>/dev/null | tr -d ' ')"
  probe_rc=$?
fi
$probe_created && $KUBECTL delete pod "$dbgpod" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1
if [[ "$probe_rc" -ne 0 || -z "$node_nfs" ]]; then
  assert "the node holds no kubelet nfs4 mount for these pods (node probe could not run)" 1
else
  [[ "$node_nfs" == "0" ]]; assert "the node holds no kubelet nfs4 mount for these pods (found $node_nfs)" $?
fi

echo "== 4/10 the access point pins UID/GID on /shared =="
owner="$($KUBECTL exec "$WRITER" -n "$NAMESPACE" -- stat -c '%u %g' /shared 2>/dev/null || $KUBECTL exec "$WRITER" -n "$NAMESPACE" -- sh -c 'ls -ldn /shared | awk "{print \$3, \$4}"')"
echo "  /shared owner uid gid: $owner"
[[ "$owner" == "1000 1000" ]]; assert "/shared is owned by the access point's uid/gid 1000" $?

echo "== 5/10 a non-root container writes /shared =="
id_out="$($KUBECTL exec "$WRITER" -n "$NAMESPACE" -- id)"
echo "  $id_out"
grep -q 'uid=1000' <<<"$id_out"; assert "the writer runs as non-root uid 1000" $?

echo "== 6/10 the workload ServiceAccount has no AWS identity and mounts no API token =="
for pod in "$WRITER" "$READER"; do
  sa="$($KUBECTL get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.serviceAccountName}')"
  [[ "$sa" == "s3-files-workload" ]]; assert "$pod uses the s3-files-workload ServiceAccount ($sa)" $?
  tok="$($KUBECTL get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.automountServiceAccountToken}')"
  [[ "$tok" == "false" ]]; assert "$pod does not mount a Kubernetes API token" $?
done
wl_assoc="$(aws_r eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME:-}" \
  --namespace "$NAMESPACE" --service-account s3-files-workload \
  --query 'associations[0].associationId' --output text 2>/dev/null || true)"
[[ -z "$wl_assoc" || "$wl_assoc" == "None" ]]; assert "the workload ServiceAccount has no Pod Identity association" $?

echo "== 7/10 cross-pod visibility both ways =="
run_id="$(cut -d. -f1 /proc/uptime 2>/dev/null)-$$"
sent="hello-from-writer-$run_id"
reply="hello-from-reader-$run_id"
$KUBECTL exec "$WRITER" -n "$NAMESPACE" -- sh -c "printf '%s' '$sent' > /shared/from-writer"; assert "the non-root writer wrote /shared" $?
seen="$($KUBECTL exec "$READER" -n "$NAMESPACE" -- cat /shared/from-writer 2>/dev/null | tr -d '\r')"
[[ "$seen" == "$sent" ]]; assert "the reader sees the file the writer wrote" $?
$KUBECTL exec "$READER" -n "$NAMESPACE" -- sh -c "printf '%s' '$reply' > /shared/from-reader"; assert "the reader wrote a file" $?
seen="$($KUBECTL exec "$WRITER" -n "$NAMESPACE" -- cat /shared/from-reader 2>/dev/null | tr -d '\r')"
[[ "$seen" == "$reply" ]]; assert "the writer sees the file the reader wrote" $?

echo "== 8/10 the pods mount with tls,iam =="
opts_json="$($KUBECTL get pv storage-s3-files-shared -o jsonpath='{.spec.mountOptions}')"
echo "  PV mountOptions: $opts_json"
printf '%s' "$opts_json" | python3 -c 'import json,sys
try: v=set(json.load(sys.stdin))
except Exception: sys.exit(1)
sys.exit(0 if v=={"tls","iam"} else 1)'; assert "the PV mount options are exactly {tls, iam}" $?
mnt_opt="$($KUBECTL exec "$WRITER" -n "$NAMESPACE" -- grep ' /shared ' /proc/mounts)"
grep -q 'port=' <<<"$mnt_opt"; assert "the live mount runs over the stunnel TLS endpoint (local port)" $?

if command -v "${AWS%% *}" >/dev/null 2>&1; then
  echo "== 9/10 the security group, file system policy and bucket policy =="
  CLUSTER_SG="$(aws_r eks describe-cluster --name "${CLUSTER_NAME:-}" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text 2>/dev/null)"
  if [[ $? -ne 0 || -z "$CLUSTER_SG" || "$CLUSTER_SG" == "None" ]]; then
    assert "could read the cluster security group id (needed to check the NFS rule)" 1
    CLUSTER_SG="__UNREADABLE__"
  else
    assert "read the cluster security group id" 0
  fi
  sg_rules="$(aws_r ec2 describe-security-groups --group-ids "$S3_FILES_SECURITY_GROUP_ID" --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)"
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
  # The S3 Files file system policy, validated structurally and exactly.
  pol="$(aws_r s3files get-file-system-policy --file-system-id "$S3_FILES_FILE_SYSTEM_ID" --query 'policy' --output text 2>/dev/null)"
  ACCOUNT="$(aws_r sts get-caller-identity --query Account --output text)"
  FS_ARN="arn:aws:s3files:${AWS_REGION}:${ACCOUNT}:file-system/${S3_FILES_FILE_SYSTEM_ID}"
  FS_ARN="$FS_ARN" NODE="$S3_FILES_CSI_NODE_ROLE_ARN" EC2="$EC2_NODE_ROLE_ARN" python3 -c 'import json,sys,os
p=json.loads(sys.stdin.read())
if isinstance(p,str): p=json.loads(p)
st=p["Statement"]
fs=os.environ["FS_ARN"]; node=os.environ["NODE"]; ec2=os.environ["EC2"]
def listify(x): return x if isinstance(x,list) else [x]
allows=[s for s in st if s.get("Effect")=="Allow"]
denies=[s for s in st if s.get("Effect")=="Deny"]
def allow_ok(s):
    pr=s.get("Principal")
    if not (isinstance(pr,dict) and list(pr.keys())==["AWS"] and pr["AWS"]==node): return False
    if listify(s.get("Resource"))!=[fs]: return False
    acts=set(listify(s.get("Action")))
    if not acts or not acts<= {"s3files:ClientMount","s3files:ClientWrite"}: return False
    return True
def ec2_deny_ok(s):
    pr=s.get("Principal")
    if not (isinstance(pr,dict) and pr.get("AWS")==ec2): return False
    if listify(s.get("Resource"))!=[fs]: return False
    acts=set(listify(s.get("Action")))
    return {"s3files:ClientMount","s3files:ClientWrite"}<=acts
ok=(len(allows)>=1 and all(allow_ok(s) for s in allows) and any(ec2_deny_ok(s) for s in denies))
sys.exit(0 if ok else 1)' <<<"$pol"; assert "the file system policy: every Allow is the CSI node principal only (ClientMount/ClientWrite, no ClientRootAccess) on this file system, plus a Deny of the EC2 node role" $?
  # The bucket policy: TLS-only deny, and an EC2-node-role deny.
  bpol="$(aws_r s3api get-bucket-policy --bucket "$S3_BUCKET_NAME" --query 'Policy' --output text 2>/dev/null)"
  EC2="$EC2_NODE_ROLE_ARN" python3 -c 'import json,sys,os
p=json.loads(sys.stdin.read())
if isinstance(p,str): p=json.loads(p)
st=p["Statement"]; ec2=os.environ["EC2"]
def listify(x): return x if isinstance(x,list) else [x]
def tls_deny(s):
    return (s.get("Effect")=="Deny" and s.get("Principal")=="*"
            and "s3:*" in listify(s.get("Action"))
            and s.get("Condition",{}).get("Bool",{}).get("aws:SecureTransport")=="false")
def ec2_deny(s):
    return (s.get("Effect")=="Deny" and s.get("Principal")=="*"
            and "s3:*" in listify(s.get("Action"))
            and s.get("Condition",{}).get("ArnEquals",{}).get("aws:PrincipalArn")==ec2)
sys.exit(0 if (any(tls_deny(s) for s in st) and any(ec2_deny(s) for s in st)) else 1)' <<<"$bpol"; assert "the bucket policy denies insecure transport and denies the EC2 node role" $?
else
  echo "== 9/10 security group, file system policy and bucket policy: SKIP (aws not on PATH) =="
fi

echo "== 10/10 two-way synchronization with the backing bucket, and egress is refused =="
# The access point roots at /storage-s3-files, so a file at /shared/<f> is the bucket object
# storage-s3-files/<f>. Address the bucket under that prefix in both directions.
AP_PREFIX="storage-s3-files"
# A file written through /shared appears as an object in the bucket (asynchronous: poll).
sync_val="written-through-s3-files-$run_id"
sync_file="sandbox-to-s3-$run_id"
$KUBECTL exec "$WRITER" -n "$NAMESPACE" -- sh -c "printf '%s' '$sync_val' > /shared/$sync_file"; assert "wrote a file through /shared to synchronize to S3" $?
if command -v "${AWS%% *}" >/dev/null 2>&1; then
  got=""
  for _ in $(seq 1 45); do
    got="$(aws_r s3 cp "s3://$S3_BUCKET_NAME/$AP_PREFIX/$sync_file" - --only-show-errors 2>/dev/null || true)"
    [[ "$got" == "$sync_val" ]] && break
    sleep 4
  done
  [[ "$got" == "$sync_val" ]]; assert "the file written through /shared appears as an object in the bucket" $?
  # An object put in the bucket under the access point's prefix appears as a file on /shared.
  seed_val="seeded-through-s3-$run_id"
  seed_file="seeded-from-s3-$run_id"
  printf '%s' "$seed_val" | aws_r s3 cp - "s3://$S3_BUCKET_NAME/$AP_PREFIX/$seed_file" --only-show-errors >/dev/null 2>&1; assert "put an object directly in the bucket under the access point prefix" $?
  seen=""
  for _ in $(seq 1 45); do
    seen="$($KUBECTL exec "$READER" -n "$NAMESPACE" -- cat "/shared/$seed_file" 2>/dev/null | tr -d '\r' || true)"
    [[ "$seen" == "$seed_val" ]] && break
    sleep 4
  done
  [[ "$seen" == "$seed_val" ]]; assert "the object put in the bucket appears as a file on /shared" $?
else
  echo "  bucket synchronization: SKIP (aws not on PATH)"
fi

if $KUBECTL exec "$WRITER" -n "$NAMESPACE" -- sh -c 'wget -T 5 -q -O /dev/null https://example.com 2>/dev/null'; then
  assert "an outbound HTTPS connection to the internet is refused" 1
else
  assert "an outbound HTTPS connection to the internet is refused" 0
fi

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "Shared S3 Files works: two isolated-sandbox pods mount one access point with tls,iam, read each other's writes, and stay in sync with the bucket both ways."
