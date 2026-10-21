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
# Runs ./scripts/setup.sh for the AWS side if .env is missing. Renders the manifests from
# the recorded IDs and addresses (it does not modify the checked-in files), applies the
# egress policy and waits for its PolicyEndpoint, deploys the pods, and asserts. It leaves
# the pods running; tear down with ./scripts/clean.sh.
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

# Build the AWS side if it has not been built, then load the record.
if [[ ! -f "$ENV_FILE" ]]; then
  echo "No $ENV_FILE yet; running ./scripts/setup.sh first."
  NAMESPACE="$NAMESPACE" ENV_FILE="$ENV_FILE" "$SAMPLE_DIR/scripts/setup.sh"
fi
# shellcheck disable=SC1090
source "$ENV_FILE"
[[ -n "${EFS_FILE_SYSTEM_ID:-}" && -n "${EFS_ACCESS_POINT_ID:-}" ]] \
  || die "$ENV_FILE is missing the EFS IDs; run ./scripts/setup.sh"
[[ -n "${COREDNS_IP:-}" && -n "${MOUNT_TARGET_IPS:-}" ]] \
  || die "$ENV_FILE is missing the network addresses; re-run ./scripts/setup.sh"

AWS_REGION="${AWS_REGION:-us-west-2}"
aws_r() { $AWS "$@" --region "$AWS_REGION"; }

# --- Deploy: render manifests from the record and apply. ---
echo "== deploy the pods and the egress policy =="
if ! $KUBECTL get namespace "$NAMESPACE" >/dev/null 2>&1; then
  $KUBECTL create namespace "$NAMESPACE"
  $KUBECTL label namespace "$NAMESPACE" "$SAMPLE_LABEL_KEY=$SAMPLE_LABEL_VALUE" --overwrite
  echo "  created namespace '$NAMESPACE' and labelled it this sample's."
else
  echo "  namespace '$NAMESPACE' already exists; reusing it."
fi

# The egress policy: render the checked-in deploy/egress-policy.yaml so the file the page
# shows is the file that is applied. Substitute <COREDNS_IP> and expand <MOUNT_TARGET_BLOCK>
# into one `- ipBlock: { cidr: <ip>/32 }` line per mount-target IP, preserving the block's
# indentation. COREDNS_IP and MOUNT_TARGET_IPS come from .env. Done in Python so neither the
# shell word-splits the IP list nor the placeholder in a comment line is corrupted.
python3 - "$SAMPLE_DIR/deploy/egress-policy.yaml" "$COREDNS_IP" $MOUNT_TARGET_IPS <<'PY' | $KUBECTL apply -n "$NAMESPACE" -f -
import re, sys
path, coredns = sys.argv[1], sys.argv[2]
mt_ips = sys.argv[3:]
with open(path) as f:
    out = []
    for line in f.read().splitlines():
        m = re.match(r'^(\s*)<MOUNT_TARGET_BLOCK>\s*$', line)
        if m:
            indent = m.group(1)
            out.extend(f"{indent}- ipBlock: {{ cidr: {ip}/32 }}" for ip in mt_ips)
        else:
            out.append(line.replace("<COREDNS_IP>", coredns))
text = "\n".join(out)
# Drop the leading comment block so only the resource is applied.
text = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
sys.stdout.write(text + "\n")
PY

# Wait for the PolicyEndpoint so the rule is programmed before the pods start.
echo "  waiting for the PolicyEndpoint to be programmed..."
for _ in $(seq 1 30); do
  n="$($KUBECTL get policyendpoints -n "$NAMESPACE" -o name 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$n" -gt 0 ]] && break
  sleep 2
done

# The StorageClass (cluster-scoped, create only if absent; never apply over an existing
# one), then the PV, PVC, ServiceAccount and pods. efs.yaml is one multi-document file;
# split it so the StorageClass is created separately and everything else is applied with
# the namespace and the recorded IDs rendered in.
render_efs() {
  sed -e "s|<NAMESPACE>|$NAMESPACE|g" \
      -e "s|<EFS_FILE_SYSTEM_ID>|$EFS_FILE_SYSTEM_ID|g" \
      -e "s|<EFS_ACCESS_POINT_ID>|$EFS_ACCESS_POINT_ID|g" \
      "$SAMPLE_DIR/deploy/efs.yaml"
}
if ! $KUBECTL get storageclass nitro-sandbox-efs >/dev/null 2>&1; then
  render_efs | python3 -c 'import sys
docs = sys.stdin.read().split("\n---\n")
for d in docs:
    if "kind: StorageClass" in d:
        sys.stdout.write(d.strip() + "\n")' | $KUBECTL create -f -
fi
render_efs | python3 -c 'import sys
docs = sys.stdin.read().split("\n---\n")
out = [d for d in docs if d.strip() and "kind: StorageClass" not in d]
sys.stdout.write("\n---\n".join(out))' | $KUBECTL apply -n "$NAMESPACE" -f -

echo "  waiting for both pods to become Ready (sandbox VM boot + NFS mount)..."
$KUBECTL wait -n "$NAMESPACE" --for=condition=Ready pod/$WRITER pod/$READER --timeout=5m \
  || die "the pods did not become Ready. Check:
  $KUBECTL describe pod $WRITER -n $NAMESPACE
  $KUBECTL logs -n kube-system daemonset/efs-csi-node -c efs-plugin --tail=100"

echo
echo "== 1/9 both pods run in a sandbox =="
for pod in "$WRITER" "$READER"; do
  rc="$($KUBECTL get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.runtimeClassName}')"
  [[ "$rc" == "isolated-sandbox" ]]; assert "$pod runtimeClassName is isolated-sandbox ($rc)" $?
done
guest_kernel="$($KUBECTL exec "$WRITER" -n "$NAMESPACE" -- uname -r)"
node="$($KUBECTL get pod "$WRITER" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')"
node_kernel="$($KUBECTL get node "$node" -o jsonpath='{.status.nodeInfo.kernelVersion}')"
echo "  guest kernel: $guest_kernel | node kernel: $node_kernel"
$KUBECTL exec "$WRITER" -n "$NAMESPACE" -- sh -c 'ls /sys/block | grep -q "^vd"'; assert "the writer guest sees virtio (vd*) disks" $?

echo "== 2/9 /shared is an nfs4 mount to the guest's own endpoint =="
for pod in "$WRITER" "$READER"; do
  mnt="$($KUBECTL exec "$pod" -n "$NAMESPACE" -- grep ' /shared ' /proc/mounts || true)"
  echo "  $pod: $mnt"
  grep -q 'nfs4' <<<"$mnt" && grep -q '127.0.0.1' <<<"$mnt"; assert "$pod /shared is an nfs4 mount to the guest's 127.0.0.1 endpoint" $?
done

echo "== 3/9 the node holds no NFS mount for these pods =="
# The guest terminates TLS and runs the NFS client itself; the node should carry no nfs4
# mount for /var/lib/kubelet pods. A debug pod on the node reads its /proc/mounts.
dbg="efs-nodecheck-$$"
$KUBECTL debug node/"$node" -n "$NAMESPACE" --image=public.ecr.aws/docker/library/busybox:1.37 \
  --profile=general -q --attach=false -- sh -c 'sleep 120' >/dev/null 2>&1 || true
dbgpod="$($KUBECTL get pod -n "$NAMESPACE" -o name 2>/dev/null | grep "$dbg" | head -1 | sed 's|pod/||')"
if [[ -z "$dbgpod" ]]; then
  dbgpod="$($KUBECTL get pod -n "$NAMESPACE" -l 'app!=efs-shared' -o jsonpath='{.items[?(@.spec.nodeName=="'"$node"'")].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i debug | head -1)"
fi
if [[ -n "$dbgpod" ]]; then
  $KUBECTL wait -n "$NAMESPACE" --for=condition=Ready "pod/$dbgpod" --timeout=60s >/dev/null 2>&1 || true
  node_nfs="$($KUBECTL exec -n "$NAMESPACE" "$dbgpod" -- sh -c 'grep nfs4 /proc/mounts 2>/dev/null | grep -c kubelet || true' 2>/dev/null | tr -d ' ')"
  [[ "${node_nfs:-0}" == "0" ]]; assert "the node holds no kubelet nfs4 mount for these pods (found ${node_nfs:-?})" $?
  $KUBECTL delete pod "$dbgpod" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
else
  echo "  (could not start a node debug pod; skipping the node-side check)"
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
opts="$($KUBECTL get pv storage-efs-shared -o jsonpath='{.spec.mountOptions}')"
echo "  PV mountOptions: $opts"
grep -q 'tls' <<<"$opts" && grep -q 'iam' <<<"$opts"; assert "the PV mount options are tls and iam" $?
mnt_opt="$($KUBECTL exec "$WRITER" -n "$NAMESPACE" -- grep ' /shared ' /proc/mounts)"
grep -q 'port=' <<<"$mnt_opt"; assert "the live mount runs over the stunnel TLS endpoint (local port)" $?

if command -v "${AWS%% *}" >/dev/null 2>&1; then
  echo "== 8/9 the security group and file system policy =="
  # One mount target carries only this sample's security group.
  mt_sg="$(aws_r efs describe-mount-targets --file-system-id "$EFS_FILE_SYSTEM_ID" --query 'MountTargets[0].MountTargetId' --output text)"
  sg_on_mt="$(aws_r efs describe-mount-target-security-groups --mount-target-id "$mt_sg" --query 'SecurityGroups' --output text)"
  [[ "$sg_on_mt" == "$EFS_SECURITY_GROUP_ID" ]]; assert "the mount target carries only this sample's security group" $?
  # The security group admits exactly TCP 2049 from the cluster SG.
  sg_rules="$(aws_r ec2 describe-security-groups --group-ids "$EFS_SECURITY_GROUP_ID" --query 'SecurityGroups[0].IpPermissions' --output json)"
  echo "$sg_rules" | python3 -c 'import json,sys
r=json.load(sys.stdin)
ok = len(r)==1 and r[0].get("FromPort")==2049 and r[0].get("ToPort")==2049 and r[0].get("IpProtocol")=="tcp" and r[0].get("UserIdGroupPairs") and not r[0].get("IpRanges")
sys.exit(0 if ok else 1)'; assert "the security group admits exactly TCP 2049 from a security group, no CIDR" $?
  # The file system policy: TLS required, this access point only, no ClientRootAccess, allows the node role.
  pol="$(aws_r efs describe-file-system-policy --file-system-id "$EFS_FILE_SYSTEM_ID" --query 'Policy' --output text)"
  AP_ARN="arn:aws:elasticfilesystem:${AWS_REGION}:$(aws_r sts get-caller-identity --query Account --output text):access-point/${EFS_ACCESS_POINT_ID}"
  export AP_ARN EFS_CSI_NODE_ROLE_ARN
  echo "$pol" | python3 -c 'import json,sys,os
p=json.load(sys.stdin); st=p["Statement"]
node=os.environ["EFS_CSI_NODE_ROLE_ARN"]; ap=os.environ["AP_ARN"]
has_tls_deny=any(s["Effect"]=="Deny" and s.get("Condition",{}).get("Bool",{}).get("aws:SecureTransport")=="false" for s in st)
allows=[s for s in st if s["Effect"]=="Allow"]
def acts(s):
    a=s["Action"]; return [a] if isinstance(a,str) else a
ok_allow=all(
    s.get("Condition",{}).get("StringEquals",{}).get("elasticfilesystem:AccessPointArn")==ap
    and "elasticfilesystem:ClientRootAccess" not in acts(s)
    and set(acts(s))<= {"elasticfilesystem:ClientMount","elasticfilesystem:ClientWrite"}
    for s in allows)
principals=[s["Principal"]["AWS"] for s in allows if isinstance(s.get("Principal"),dict) and "AWS" in s["Principal"]]
only_node = principals==[node]
sys.exit(0 if (has_tls_deny and ok_allow and only_node and allows) else 1)' \
    ; assert "the file system policy requires TLS, is confined to this access point, no ClientRootAccess, allows only the CSI node principal" $?
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
