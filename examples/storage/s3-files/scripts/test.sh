#!/usr/bin/env bash
# Assert what the shared S3 Files sample claims:
#   - both pods run in a sandbox (own kernel, boot and virtio disks);
#   - each /shared is an nfs4 mount to the guest's own endpoint, and the node holds no
#     NFS mount for the pods;
#   - the access points pin UID/GID 1000 on /shared, and a non-root container writes it;
#   - both pods share ONE dataset (same file system, two access points rooted at the same
#     directory): a file the writer writes is read by the reader;
#   - the reader is READ-ONLY: a write through the reader access point is refused, enforced
#     by IAM (the reader access point has no ClientWrite), while the writer can write;
#   - the security group admits TCP 2049 from the cluster only; the file system policy gives
#     the CSI node principal read-write via the writer access point and read-only via the
#     reader access point, by the s3files:AccessPointArn condition (no ClientRootAccess,
#     and the EC2 node role is not named); the bucket policy requires TLS;
#   - the workload ServiceAccount has no AWS identity and mounts no API token;
#   - the pods mount with tls,iam;
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
[[ -n "${S3_FILES_FILE_SYSTEM_ID:-}" && -n "${S3_FILES_WRITER_AP_ID:-}" && -n "${S3_FILES_READER_AP_ID:-}" && -n "${S3_BUCKET_NAME:-}" ]] \
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
# A FAILED lookup must fail this assertion, never pass as "no association": capture status
# separately, so only a successful response that contains no association passes.
wl_errf="$(mktemp)"
wl_assoc="$(aws_r eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME:-}" \
  --namespace "$NAMESPACE" --service-account s3-files-workload \
  --query 'associations[0].associationId' --output text 2>"$wl_errf")"; wl_rc=$?
rm -f "$wl_errf"
if [[ $wl_rc -ne 0 ]]; then
  assert "the workload ServiceAccount has no Pod Identity association (lookup failed)" 1
else
  [[ -z "$wl_assoc" || "$wl_assoc" == "None" ]]; assert "the workload ServiceAccount has no Pod Identity association" $?
fi

echo "== 7/10 one shared dataset: the writer writes, the reader reads; the reader cannot write =="
run_id="$(cut -d. -f1 /proc/uptime 2>/dev/null)-$$"
sent="hello-from-writer-$run_id"
# The writer (read-write access point) writes; the reader (read-only access point) sees it.
# Same file system, both access points rooted at /storage-s3-files, so it is one dataset.
$KUBECTL exec "$WRITER" -n "$NAMESPACE" -- sh -c "printf '%s' '$sent' > /shared/from-writer"; assert "the non-root writer wrote /shared through the writer access point" $?
seen="$($KUBECTL exec "$READER" -n "$NAMESPACE" -- cat /shared/from-writer 2>/dev/null | tr -d '\r')"
[[ "$seen" == "$sent" ]]; assert "the reader sees the file the writer wrote (one shared dataset)" $?
# The reader is read-only: a write through the reader access point must FAIL, and fail for the
# RIGHT reason. A bare non-zero exit, or merely finding "read-only file system" somewhere in the
# output, could also come from a missing pod or a transport error, so neither alone proves the
# write was executed and refused. Have the remote shell attempt the write and THEN echo a unique
# sentinel: the sentinel is printed only if the container's shell actually ran to completion, and
# the EROFS line is printed only if the kernel refused the write. Require BOTH. A kubectl/runtime
# failure that never reached the container prints no sentinel and fails the assertion closed.
wr_sentinel="reader-write-ran-$run_id"
wr_out="$($KUBECTL exec "$READER" -n "$NAMESPACE" -- sh -c "printf '%s' 'nope-$run_id' > /shared/from-reader; echo $wr_sentinel" 2>&1)"
if printf '%s\n' "$wr_out" | grep -qF "$wr_sentinel" \
   && printf '%s\n' "$wr_out" | grep -qi 'read-only file system'; then
  assert "the reader's write to /shared is refused with a read-only-filesystem error (sentinel proves the write ran)" 0
else
  echo "    reader write out=[$wr_out] (expected sentinel $wr_sentinel + a read-only-filesystem error)"
  assert "the reader's write to /shared is refused with a read-only-filesystem error (sentinel proves the write ran)" 1
fi
# And the refused write left nothing behind: the file does not exist on the shared dataset. Probe
# from the writer with a command that prints a distinct token for present vs absent, so a failure
# to run the exec at all (empty output) is NOT read as "absent".
probe="$($KUBECTL exec "$WRITER" -n "$NAMESPACE" -- sh -c '[ -e /shared/from-reader ] && echo FOUND || echo MISSING' 2>/dev/null | tr -d '\r')"
[[ "$probe" == "MISSING" ]]; assert "the reader's refused write created no file on the shared dataset (probe returned MISSING, not an empty/failed exec)" $?

echo "== 8/10 both pods mount with tls,iam; the reader mount is read-only =="
for pv in storage-s3-files-writer storage-s3-files-reader; do
  opts_json="$($KUBECTL get pv "$pv" -o jsonpath='{.spec.mountOptions}')"
  echo "  $pv mountOptions: $opts_json"
  printf '%s' "$opts_json" | python3 -c 'import json,sys
try: v=set(json.load(sys.stdin))
except Exception: sys.exit(1)
sys.exit(0 if v=={"tls","iam"} else 1)'; assert "$pv mount options are exactly {tls, iam}" $?
done
mnt_opt="$($KUBECTL exec "$WRITER" -n "$NAMESPACE" -- grep ' /shared ' /proc/mounts)"
grep -q 'port=' <<<"$mnt_opt"; assert "the live mount runs over the stunnel TLS endpoint (local port)" $?
# The reader's volumeMount is readOnly in the pod spec (defense in depth), and the live mount
# carries 'ro'.
ro_spec="$($KUBECTL get pod "$READER" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].volumeMounts[?(@.mountPath=="/shared")].readOnly}')"
[[ "$ro_spec" == "true" ]]; assert "the reader pod mounts /shared readOnly in its spec" $?
reader_mnt="$($KUBECTL exec "$READER" -n "$NAMESPACE" -- grep ' /shared ' /proc/mounts || true)"
grep -qE '(^| )ro(,| )' <<<"$reader_mnt"; assert "the reader's live /shared mount is read-only (ro)" $?

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
  # The S3 Files file system policy, validated structurally and exactly: the SAME CSI node
  # principal gets read-write via the writer access point and read-only via the reader access
  # point, by the s3files:AccessPointArn condition. No ClientRootAccess anywhere; the writer
  # grant never applies to the reader access point; and a ClientWrite through the reader access
  # point is explicitly denied.
  pol="$(aws_r s3files get-file-system-policy --file-system-id "$S3_FILES_FILE_SYSTEM_ID" --query 'policy' --output text 2>/dev/null)"
  ACCOUNT="$(aws_r sts get-caller-identity --query Account --output text)"
  FS_ARN="arn:aws:s3files:${AWS_REGION}:${ACCOUNT}:file-system/${S3_FILES_FILE_SYSTEM_ID}"
  # S3 Files forms an access point ARN as .../file-system/<fs>/access-point/<ap>; read the real
  # ARNs back from the API rather than constructing them, so the check matches the live policy.
  WRITER_AP_ARN="$(aws_r s3files get-access-point --access-point-id "$S3_FILES_WRITER_AP_ID" --query 'accessPointArn' --output text 2>/dev/null)"
  READER_AP_ARN="$(aws_r s3files get-access-point --access-point-id "$S3_FILES_READER_AP_ID" --query 'accessPointArn' --output text 2>/dev/null)"
  FS_ARN="$FS_ARN" NODE="$S3_FILES_CSI_NODE_ROLE_ARN" WRITER_AP="$WRITER_AP_ARN" READER_AP="$READER_AP_ARN" python3 -c 'import json,sys,os
p=json.loads(sys.stdin.read())
if isinstance(p,str): p=json.loads(p)
st=p["Statement"]
fs=os.environ["FS_ARN"]; node=os.environ["NODE"]
writer_ap=os.environ["WRITER_AP"]; reader_ap=os.environ["READER_AP"]
# The split is meaningless if the two access point ARNs are empty, unread ("None"), or the same
# ARN twice: the reader ClientWrite Deny would then also match the writer ARN. Require both to be
# real and distinct before judging the policy.
if not writer_ap or not reader_ap or writer_ap in ("None",) or reader_ap in ("None",) or writer_ap==reader_ap:
    sys.exit(1)
def L(x): return x if isinstance(x,list) else [x]
def principal_is_node(s):
    pr=s.get("Principal")
    return isinstance(pr,dict) and list(pr.keys())==["AWS"] and pr["AWS"]==node
def ap_cond(s):
    return (s.get("Condition",{}).get("StringEquals",{}) or {}).get("s3files:AccessPointArn")
# No statement anywhere may grant ClientRootAccess.
if any("s3files:ClientRootAccess" in L(s.get("Action")) for s in st): sys.exit(1)
allows=[s for s in st if s.get("Effect")=="Allow"]
denies=[s for s in st if s.get("Effect")=="Deny"]
# Writer access point: exactly one Allow, node principal, on this fs, exactly ClientMount+
# ClientWrite, conditioned on the writer access point ARN.
def writer_allow(s):
    return (principal_is_node(s) and L(s.get("Resource"))==[fs]
            and set(L(s.get("Action")))=={"s3files:ClientMount","s3files:ClientWrite"}
            and ap_cond(s)==writer_ap)
# Reader access point: exactly one Allow, node principal, on this fs, exactly ClientMount
# (NO ClientWrite), conditioned on the reader access point ARN.
def reader_allow(s):
    return (principal_is_node(s) and L(s.get("Resource"))==[fs]
            and set(L(s.get("Action")))=={"s3files:ClientMount"}
            and ap_cond(s)==reader_ap)
# Reader access point: a Deny of ClientWrite, node principal, conditioned on the reader AP.
def reader_write_deny(s):
    return (principal_is_node(s) and L(s.get("Resource"))==[fs]
            and "s3files:ClientWrite" in L(s.get("Action"))
            and ap_cond(s)==reader_ap)
ok=(len([s for s in allows if writer_allow(s)])==1
    and len([s for s in allows if reader_allow(s)])==1
    # every Allow is one of those two (no third, unconditioned or broader grant)
    and all(writer_allow(s) or reader_allow(s) for s in allows)
    and any(reader_write_deny(s) for s in denies))
sys.exit(0 if ok else 1)' <<<"$pol"; assert "the file system policy: read-write only via the writer access point and read-only via the reader access point (ClientMount only, ClientWrite denied), by s3files:AccessPointArn, no ClientRootAccess" $?
  # The CSI node role carries NO S3 Files identity permission, so the mount is authorized by
  # the file system resource policy ALONE. Read every inline and attached policy on the node
  # role and fail if any grants an s3files: action or names an S3 Files resource. A lookup
  # failure fails the assertion (could not prove the absence), never passes it.
  node_role_name="${S3_FILES_CSI_NODE_ROLE_ARN##*/}"
  # s3files_grant <policy-doc-json> on stdin: exit 1 if any Allow grants an s3files: action, a
  # wildcard action, or names an S3 Files resource; exit 0 if none does; exit 2 if the doc could
  # not be parsed. Only Effect:Allow statements count (a Deny is not a grant).
  s3files_grant() {
    python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(2)
if isinstance(d,str):
    try: d=json.loads(d)
    except Exception: sys.exit(2)
st=d.get("Statement",[])
if isinstance(st,dict): st=[st]
def L(x): return x if isinstance(x,list) else [x]
for s in st:
    if s.get("Effect")!="Allow": continue
    acts=[str(a).lower() for a in L(s.get("Action",[]))]
    res=[str(r).lower() for r in L(s.get("Resource",[]))]
    if any(a.startswith("s3files:") or a=="*" for a in acts) or any("s3files" in r for r in res):
        sys.exit(1)
sys.exit(0)'
  }
  nr_ok=0
  inline_list="$(aws_r iam list-role-policies --role-name "$node_role_name" --query 'PolicyNames' --output text 2>/dev/null)" || nr_ok=1
  attached_arns="$(aws_r iam list-attached-role-policies --role-name "$node_role_name" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null)" || nr_ok=1
  if [[ "$nr_ok" -ne 0 ]]; then
    assert "the CSI node role has no S3 Files identity permission (could not read the role's policies)" 1
  else
    s3files_grant_found=0  # 0 none, 1 grant found, 2 a read/parse failed
    # Inline policies: inspect each document.
    for pn in $inline_list; do
      [[ "$pn" == "None" || "$s3files_grant_found" -ne 0 ]] && continue
      doc="$(aws_r iam get-role-policy --role-name "$node_role_name" --policy-name "$pn" --query 'PolicyDocument' --output json 2>/dev/null)" || { s3files_grant_found=2; continue; }
      printf '%s' "$doc" | s3files_grant || { rc=$?; [[ $rc -eq 1 ]] && s3files_grant_found=1 || s3files_grant_found=2; }
    done
    # Attached managed policies: fetch each one's DEFAULT VERSION document and inspect it, rather
    # than matching by name (an arbitrarily named customer-managed policy could grant s3files).
    for arn in $attached_arns; do
      [[ "$arn" == "None" || "$s3files_grant_found" -ne 0 ]] && continue
      ver="$(aws_r iam get-policy --policy-arn "$arn" --query 'Policy.DefaultVersionId' --output text 2>/dev/null)" || { s3files_grant_found=2; continue; }
      adoc="$(aws_r iam get-policy-version --policy-arn "$arn" --version-id "$ver" --query 'PolicyVersion.Document' --output json 2>/dev/null)" || { s3files_grant_found=2; continue; }
      printf '%s' "$adoc" | s3files_grant || { rc=$?; [[ $rc -eq 1 ]] && s3files_grant_found=1 || s3files_grant_found=2; }
    done
    if [[ "$s3files_grant_found" -eq 2 ]]; then
      assert "the CSI node role has no S3 Files identity permission (a policy document could not be read)" 1
    else
      [[ "$s3files_grant_found" -eq 0 ]]; assert "the CSI node role has no S3 Files identity permission, so the file system resource policy alone authorizes the mount" $?
    fi
  fi

  # The bucket policy: a TLS-only deny. (The EC2 node role is not named by this sample.)
  bpol="$(aws_r s3api get-bucket-policy --bucket "$S3_BUCKET_NAME" --query 'Policy' --output text 2>/dev/null)"
  python3 -c 'import json,sys
p=json.loads(sys.stdin.read())
if isinstance(p,str): p=json.loads(p)
st=p["Statement"]
def listify(x): return x if isinstance(x,list) else [x]
def tls_deny(s):
    return (s.get("Effect")=="Deny" and s.get("Principal")=="*"
            and "s3:*" in listify(s.get("Action"))
            and s.get("Condition",{}).get("Bool",{}).get("aws:SecureTransport")=="false")
sys.exit(0 if any(tls_deny(s) for s in st) else 1)' <<<"$bpol"; assert "the bucket policy denies insecure transport (TLS-only)" $?
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
echo "Shared S3 Files works: two isolated-sandbox pods share one dataset over tls,iam; the writer writes and the reader reads it, the reader's own write is refused (read-only access point), and the dataset stays in sync with the bucket both ways."
