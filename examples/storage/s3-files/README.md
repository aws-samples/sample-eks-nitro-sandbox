# Shared S3 Files storage for sandboxed pods

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run the [hello sandbox](../../getting-started/hello-sandbox/README.md)
sample first so you have an EKS Auto Mode cluster with the runtime classes. This sample also
builds on the [coding agent](../../getting-started/coding-agent/README.md) sample for turning
on network policy enforcement once per cluster. The commands below use files from this
repository, so clone it if you have not already, and run them from this sample's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/storage/s3-files
```

This sample needs the AWS CLI, which the home page already lists, new enough for the
`aws s3files` commands (a current 2.x release), for the steps that create the storage and
read it back. It also needs the **Amazon EFS CSI driver** installed on the cluster as a
shared prerequisite, at **3.5.1 or newer** for S3 Files;
[Install the EFS CSI driver for S3 Files](#install-the-efs-csi-driver-for-s3-files) below
has the one-time setup for a cluster that does not have it. What it costs beyond the cluster
is the backing S3 bucket, billed for the objects stored and for S3 requests including the
synchronization traffic; the two pods are small and the shared directory holds a couple of
tiny files, and the clean up deletes the bucket and the file system.

Two sandboxed pods, a writer and a reader, share one
[Amazon S3 Files](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-files-mounting-eks.html)
dataset, backed by a versioned S3 bucket, each over TLS with IAM authorization. They mount the
same data through two access points on one file system, both rooted at the same directory: the
writer's access point is read-write and the reader's is read-only. The writer writes a file at
`/shared` and the reader reads it; the reader's own write is refused. A file written through
`/shared` also appears as an object in the backing bucket, and an object put in the bucket
appears as a file on `/shared`. Each pod is an ordinary pod spec with one line added, the
runtime class.

- **Two sandboxed pods share one dataset, with different access.** The writer and the reader
  are both `isolated-sandbox` pods. They mount the same file system through two access points
  rooted at the same directory, so it is one shared dataset, not two. The writer mounts the
  read-write access point; the reader mounts the read-only one.
- **Read and write are split per access point, enforced by IAM.** The file system policy gives
  the one CSI node principal `ClientMount` and `ClientWrite` through the writer access point and
  `ClientMount` only through the reader access point, using the `s3files:AccessPointArn`
  condition. A write through the reader access point is refused at the mount, not just by the
  kernel.
- **Files and S3 objects are the same data.** A file written through `/shared` appears as an
  object in the backing bucket, and an object put in the bucket appears as a file on `/shared`.
  Synchronization is asynchronous, so the page waits rather than assuming it is immediate.
- **Each pod runs in its own sandbox.** Both pods show their own kernel build and their own
  virtio disks, next to what an ordinary pod shows. ([hello sandbox](../../getting-started/hello-sandbox/README.md).)
- **The mount lives inside the guest.** In each pod, `/shared` is an `nfs4` mount whose
  endpoint is the guest's own loopback TLS endpoint, and the node holds no NFS mount for
  these pods. The guest terminates its own TLS to the mount target; the node coordinates the
  CSI operation but is not on the file-data path.
- **The access points pin the identity, and the workload holds no AWS identity.** Every mount
  runs as one POSIX UID/GID, and the pods' ServiceAccount has no AWS association and mounts no
  Kubernetes API token. What authorizes each mount is the CSI driver's node identity, allowed
  on this one file system per access point by the sample's own file system policy. The managed
  EC2 node instance-profile role is neither read nor named by the sample.

*Figure 1: Two sandboxed pods share one S3 Files dataset with different access. A writer and a
reader, each an `isolated-sandbox` pod, mount the same file system through two access points
rooted at the same directory, over TLS with IAM authorization. Each reaches the file system
through a mount target whose security group admits NFS from the cluster only. The file system
policy, keyed on the access point, gives the CSI node principal read-write through the writer
access point and read-only through the reader access point. The file system stays in sync with
a versioned Amazon S3 bucket, so the same data is a POSIX file and an S3 object.*

![Inside the AWS Cloud, an Amazon EKS cluster holds two Nitro sandbox frames, each a lightweight VM with its own kernel. The upper frame holds the Writer pod and the lower frame holds the Reader pod, both isolated-sandbox pods with /shared mounted. From the writer a line runs right, out of the cluster, to a writer S3 Files access point labelled read-write; from the reader a line runs to a reader access point labelled read-only. Both access points sit on one S3 Files file system reached through a mount target inside a security group labelled TCP 2049 from the cluster. The mount flow is labelled mount over tls and iam, signed by the CSI node role. The file system keeps in two-way sync with a versioned Amazon S3 bucket on the right. Below, an EFS CSI driver node role icon sits beside a note: the file system policy grants that one role read-write via the writer access point and read-only via the reader access point, by the s3files:AccessPointArn condition.](images/s3-files-shared-storage.png)

This folder was built against these releases:

| Component | Version |
|---|---|
| Amazon EFS CSI driver add-on ([kubernetes-sigs/aws-efs-csi-driver](https://github.com/kubernetes-sigs/aws-efs-csi-driver)) | `v3.5.1-eksbuild.1` on the run below; the sample needs **3.5.1 or newer** for S3 Files |
| AWS CLI with the `aws s3files` commands ([aws/aws-cli](https://github.com/aws/aws-cli)) | `2.36.47` on the run below; any current 2.x release |
| `busybox` image ([public.ecr.aws/docker/library/busybox](https://gallery.ecr.aws/docker/library/busybox)) | `1.37` |

The files:

| File | What it is |
|---|---|
| [`deploy/s3-files.yaml`](deploy/s3-files.yaml) | The sample's non-default `nitro-sandbox-s3-files` StorageClass, two static access-point PVs (`tls,iam`, `s3files:` volume handles) and their PVCs, a workload ServiceAccount with no identity, and the writer (read-write) and reader (read-only) `isolated-sandbox` pods. |
| [`deploy/egress-policy.yaml`](deploy/egress-policy.yaml) | The egress `ApplicationNetworkPolicy`: DNS on port 53 to any address and NFS (TCP 2049) to the mount targets, deny all ingress. |
| [`iam/file-system-policy.json`](iam/file-system-policy.json) | The S3 Files file system policy template: the CSI node principal gets read-write via the writer access point and read-only via the reader access point, by the `s3files:AccessPointArn` condition; never `ClientRootAccess`. |
| [`iam/bucket-policy.json`](iam/bucket-policy.json) | The backing bucket's policy template: TLS required. |
| [`iam/sync-role-trust.json`](iam/sync-role-trust.json) / [`iam/sync-role-permissions.json`](iam/sync-role-permissions.json) | The synchronization role's trust (the S3 Files service, this file system) and permissions (this bucket only). |
| [`scripts/setup.sh`](scripts/setup.sh) | Checks the EFS CSI driver (shared, reused, never changed); creates the bucket, synchronization role, file system, NFS security group, mount targets and the writer and reader access points; applies the file system and bucket policies; then deploys the namespace, the egress policy, the StorageClass, the PVs, the PVCs and the two pods. |
| [`scripts/clean.sh`](scripts/clean.sh) | Deletes the Kubernetes objects; `--delete-aws-resources` also releases the two access points, mount targets, file system, synchronization role, security group and (only when the sample created it) the bucket. |

The walkthrough uses the shared Region default from the home page, a cluster of your own, and
a namespace of its own so the sample's objects are easy to find and remove on a shared
cluster. Set them in your shell:

```bash
export CLUSTER_NAME=<your-cluster>
export AWS_REGION=us-west-2
export NAMESPACE=nitro-s3-files-sample
```

## Create the storage and deploy the pods

**Step 1: Run setup.** [`scripts/setup.sh`](scripts/setup.sh) does everything the walkthrough
below needs. It first confirms the Amazon EFS CSI driver is installed at 3.5.1 or newer and
reads, without changing it, which IAM role the driver's node service account uses. It creates
the sample's own resources, each tagged `ManagedBy=storage-s3-files` and `auto-delete=no`: a
versioned, encrypted S3 bucket with Block Public Access and a TLS-only bucket policy; a
synchronization role scoped to that bucket; an S3 Files file system on the bucket; an NFS
security group that admits TCP 2049 from the cluster security group only; one mount target per
cluster Availability Zone; and two access points, both pinning UID/GID 1000 and rooted at the
same directory `/storage-s3-files`, so they expose one shared dataset: a writer access point and
a reader access point. It applies a file system policy that gives the CSI node principal
read-write through the writer access point and read-only through the reader access point, keyed
on `s3files:AccessPointArn`. Finally it deploys the Kubernetes side: the namespace, the egress
`ApplicationNetworkPolicy` (waiting for its `PolicyEndpoint` before the pods start), the
StorageClass, two static PVs, two `ReadWriteMany` PVCs, and the writer and reader pods, and
waits for both to become Ready.

The writer PV mounts the writer access point; the reader PV mounts the reader access point and
the reader pod mounts it `readOnly`. Both volume handles start with `s3files:`, so the driver
mounts an S3 Files file system. The pods run as a non-root user with `fsGroup` so the writer's
unprivileged process can write the shared directory:

```yaml
# writer PV: the writer access point
spec:
  mountOptions: [tls, iam]
  csi:
    driver: efs.csi.aws.com
    volumeHandle: s3files:<S3_FILES_FILE_SYSTEM_ID>::<S3_FILES_WRITER_AP_ID>
# reader PV: the reader access point (same file system, same root directory, read-only)
spec:
  mountOptions: [tls, iam]
  csi:
    driver: efs.csi.aws.com
    volumeHandle: s3files:<S3_FILES_FILE_SYSTEM_ID>::<S3_FILES_READER_AP_ID>
```

```yaml
# the reader pod mounts its volume read-only (defense in depth; the reader access
# point is already read-only at the IAM layer)
      volumeMounts:
        - name: shared
          mountPath: /shared
          readOnly: true
```

```bash
./scripts/setup.sh
```

The run below started on a cluster with none of the sample's AWS resources present. The
`nitro-s3-files-sample` namespace already existed, empty, from an earlier run (the sample never
deletes the namespace, only what is inside it), so setup reused it rather than creating it.
This block is exactly what that run printed, and it predates the correction of the minimum:
the check then enforced 3.0.0, so its first line reads `(>= 3.0.0)` where the current check
prints `(>= 3.5.1)`. The driver that run found, `v3.5.1-eksbuild.1`, already met 3.5.1, so
nothing else in the block is affected.

```text
Step 1/6: check the Amazon EFS CSI driver (a shared install; reused, never changed)
  found aws-efs-csi-driver v3.5.1-eksbuild.1 (>= 3.0.0).
  CSI node principal (read, not changed): arn:aws:iam::<ACCOUNT_ID>:role/AmazonEKS_EFS_CSI_NodeRole
Step 2/6: create the sample's bucket, synchronization role, file system, security group, mount targets and the writer and reader access points
  creating the S3 bucket <S3_BUCKET_NAME>...
  applying the bucket policy (TLS-only)...
  creating the synchronization role storage-s3-files-<cluster>-sync...
  creating the S3 Files file system on <S3_BUCKET_NAME>...
  created NFS security group sg-EXAMPLE (TCP 2049 from sg-CLUSTER only).
  ensuring one S3 Files mount target per cluster Availability Zone...
  creating the writer-ap access point (uid/gid 1000, root /storage-s3-files)...
  creating the reader-ap access point (uid/gid 1000, root /storage-s3-files)...
Step 3/6: apply the S3 Files file system policy (writer AP read-write, reader AP read-only, by s3files:AccessPointArn)
  file system policy applied.
Step 4/6: record the mount-target addresses for the network policy
  mount targets: <MOUNT_TARGET_IP> <MOUNT_TARGET_IP> <MOUNT_TARGET_IP>
Step 5/6: deploy the egress policy and the two sandbox pods
  namespace 'nitro-s3-files-sample' already exists and is this sample's; reusing it.
applicationnetworkpolicy.networking.k8s.aws/s3-files-shared-egress created
  waiting for the PolicyEndpoint to be programmed...
storageclass.storage.k8s.io/nitro-sandbox-s3-files created
serviceaccount/s3-files-workload created
persistentvolume/storage-s3-files-writer created
persistentvolume/storage-s3-files-reader created
persistentvolumeclaim/storage-s3-files-writer created
persistentvolumeclaim/storage-s3-files-reader created
pod/s3-files-writer created
pod/s3-files-reader created
Step 6/6: wait for both pods to become Ready (sandbox VM boot + NFS mount)
pod/s3-files-writer condition met
pod/s3-files-reader condition met

S3 Files storage is ready and both pods are Running. Resource IDs and addresses: .../examples/storage/s3-files/.env
```

Setup writes the resource IDs and the mount-target addresses to a gitignored `.env`, which it
uses to render the manifests. The EFS CSI driver, its service accounts, their IAM roles and
their Pod Identity associations are a shared install and are not touched.

**Step 2: Both claims are bound and both pods are Running.** Each pod has its own
`ReadWriteMany` claim, one bound to the writer access point and one to the reader.

```bash
kubectl get pods,pvc -n "$NAMESPACE"
```

```text
NAME                  READY   STATUS    RESTARTS   AGE
pod/s3-files-reader   1/1     Running   0          23m
pod/s3-files-writer   1/1     Running   0          23m

NAME                                            STATUS   VOLUME                    CAPACITY   ACCESS MODES   STORAGECLASS             VOLUMEATTRIBUTESCLASS   AGE
persistentvolumeclaim/storage-s3-files-reader   Bound    storage-s3-files-reader   5Gi        RWX            nitro-sandbox-s3-files   <unset>                 23m
persistentvolumeclaim/storage-s3-files-writer   Bound    storage-s3-files-writer   5Gi        RWX            nitro-sandbox-s3-files   <unset>                 23m
```

**Step 3: Prove each pod ran in a sandbox.** Each pod's own view is the evidence: its kernel
is the guest's build, and its disks are virtio where an ordinary pod sees `nvme`.

```bash
kubectl exec s3-files-writer -n "$NAMESPACE" -- uname -rv
kubectl exec s3-files-writer -n "$NAMESPACE" -- sh -c 'ls /sys/block'
```

```text
6.18.51 #1 SMP PREEMPT_DYNAMIC Thu Oct  1 23:28:07 UTC 2026
dm-0
vda
vdb
vdc
```

The kernel is the guest's own build and the disks are virtio (`vda`, `vdb`, ...). An ordinary
pod on the same kind of node sees `nvme` devices instead, as the
[hello sandbox](../../getting-started/hello-sandbox/README.md) page shows side by side.

**Step 4: The mount lives inside the guest, and the reader's is read-only.** In each pod,
`/shared` is an `nfs4` mount whose server address is the guest's own `127.0.0.1`: the NFS client
and the TLS endpoint run inside the guest, reached over a local port the mount helper opens. The
writer's mount is `rw`; the reader's is `ro`.

```bash
kubectl exec s3-files-writer -n "$NAMESPACE" -- grep ' /shared ' /proc/mounts
kubectl exec s3-files-reader -n "$NAMESPACE" -- grep ' /shared ' /proc/mounts
```

```text
127.0.0.1:/ /shared nfs4 rw,relatime,vers=4.2,rsize=1048576,wsize=1048576,namlen=255,hard,noresvport,fatal_neterrors=none,proto=tcp,port=38187,...
127.0.0.1:/ /shared nfs4 ro,relatime,vers=4.2,rsize=1048576,wsize=1048576,namlen=255,hard,noresvport,fatal_neterrors=none,proto=tcp,port=39827,...
```

The server is `127.0.0.1` and the connection runs over a local port: the guest terminates its
own TLS to the mount target. The node holds no NFS mount for these pods, so the plaintext file
traffic does not traverse the node. The writer line begins `rw` and the reader line `ro`.

**Step 5: One shared dataset: the writer writes, the reader reads.** The writer runs as uid 1000
with `fsGroup: 1000` and writes `/shared` through its read-write access point. The reader, on the
read-only access point rooted at the same directory, sees the same file.

```bash
kubectl exec s3-files-writer -n "$NAMESPACE" -- id
kubectl exec s3-files-writer -n "$NAMESPACE" -- sh -c 'echo hello-from-writer > /shared/from-writer'
kubectl exec s3-files-reader -n "$NAMESPACE" -- cat /shared/from-writer
```

```text
uid=1000 gid=1000 groups=1000
hello-from-writer
```

The reader sees the file the writer wrote: one shared dataset, not two empty mounts.

**Step 6: The reader cannot write.** A write through the reader is refused. The reader pod mounts
`/shared` with `readOnly: true`, so the guest kernel refuses the write before it leaves the pod:

```bash
kubectl exec s3-files-reader -n "$NAMESPACE" -- sh -c 'echo nope > /shared/from-reader'
echo "exit: $?"
kubectl exec s3-files-writer -n "$NAMESPACE" -- ls /shared
```

```text
sh: can't create /shared/from-reader: Read-only file system
exit: 1
from-writer
```

That is the kernel mount refusing the write, which is defense in depth, not the IAM policy. To
show the **file system policy** refusing it on its own, start a throwaway pod of the sample's own
that mounts the same reader access point **without** `readOnly`, so the kernel mount is
read-write and the only thing that can refuse a write is the policy's
`DenyWriteThroughReaderAccessPoint` statement, keyed on the reader access point ARN. (S3 Files
surfaces an IAM denial to the NFS client as a read-only-filesystem error.)

```bash
# A reader-access-point pod with a read-WRITE kernel mount (no readOnly).
kubectl apply -n "$NAMESPACE" -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: s3-files-reader-rw-probe
  namespace: nitro-s3-files-sample
  labels: { app: s3-files-shared }
spec:
  runtimeClassName: isolated-sandbox
  serviceAccountName: s3-files-workload
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: shell
      image: public.ecr.aws/docker/library/busybox:1.37
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "while true; do sleep 3600; done"]
      resources: { requests: { cpu: "1", memory: 1Gi }, limits: { cpu: "1", memory: 1Gi } }
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ["ALL"] }, readOnlyRootFilesystem: true }
      volumeMounts:
        - { name: shared, mountPath: /shared }   # no readOnly: kernel mount is read-write
  volumes:
    - name: shared
      persistentVolumeClaim: { claimName: storage-s3-files-reader }
EOF
kubectl wait -n "$NAMESPACE" --for=condition=Ready pod/s3-files-reader-rw-probe --timeout=5m
kubectl exec s3-files-reader-rw-probe -n "$NAMESPACE" -- grep ' /shared ' /proc/mounts
kubectl exec s3-files-reader-rw-probe -n "$NAMESPACE" -- sh -c 'echo nope > /shared/iam-probe-write'
echo "exit: $?"
kubectl delete pod s3-files-reader-rw-probe -n "$NAMESPACE"
```

```text
pod/s3-files-reader-rw-probe created
pod/s3-files-reader-rw-probe condition met
127.0.0.1:/ /shared nfs4 rw,relatime,vers=4.2,...
sh: can't create /shared/iam-probe-write: Read-only file system
exit: 1
pod "s3-files-reader-rw-probe" deleted
```

The probe's own kernel mount is `rw`, yet the write is still refused: nothing but the file system
policy could have refused it, so the split is enforced by IAM, not only by the reader pod's
`readOnly` mount. Nothing it tried to write appears on the shared dataset. The reader pod keeps
`readOnly` as defense in depth on top of this.

**Step 7: A file on `/shared` is an object in the bucket.** S3 Files keeps the file system and
the backing bucket in sync. Synchronization is asynchronous, so wait a few seconds, then list the
bucket under the access points' shared root prefix (`storage-s3-files/`). The file the writer
wrote is there as an object.

```bash
aws s3 ls "s3://$S3_BUCKET_NAME/storage-s3-files/"
aws s3api get-object --bucket "$S3_BUCKET_NAME" --key storage-s3-files/from-writer /dev/stdout
```

```text
2026-10-21 23:30:46         18 from-writer
hello-from-writer
```

The file written through `/shared` appears as an object under the shared prefix, and the object
holds exactly what was written on the mount.

**Step 8: An object in the bucket is a file on `/shared`.** The other direction works too. Put an
object directly in the bucket under the shared prefix, wait for the synchronization, and read it
back on `/shared` through the reader.

```bash
echo hello-from-s3 | aws s3 cp - "s3://$S3_BUCKET_NAME/storage-s3-files/from-s3"
# wait a few seconds for the synchronization
kubectl exec s3-files-reader -n "$NAMESPACE" -- cat /shared/from-s3
```

```text
hello-from-s3
```

The object appears as a file on `/shared`, so the same data is reachable both as a POSIX file and
as an S3 object. (An object that enters through the bucket rather than through an access point
keeps the object's own POSIX ownership, uid/gid 0, rather than the access point's uid/gid 1000;
the access point's identity applies to writes made through the mount.)

**Step 9: IAM authorizes each mount per access point.** The pods mount with `tls,iam`, so the
mount helper signs the connection with the CSI driver's node identity, and the file system policy
decides by principal and by access point. For a principal in the same account, an `Allow` in this
resource policy is enough to authorize the mount, so the sample adds nothing to the shared CSI
node role, and on the run below that role carried no S3 Files identity policy at all. Read the
policy back from S3 Files:

```bash
aws s3files get-file-system-policy --file-system-id "$S3_FILES_FILE_SYSTEM_ID" \
  --query 'policy' --output text
```

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "WriterAccessPointReadWrite",
            "Effect": "Allow",
            "Principal": { "AWS": "arn:aws:iam::<ACCOUNT_ID>:role/AmazonEKS_EFS_CSI_NodeRole" },
            "Action": [ "s3files:ClientMount", "s3files:ClientWrite" ],
            "Resource": "arn:aws:s3files:us-west-2:<ACCOUNT_ID>:file-system/<S3_FILES_FILE_SYSTEM_ID>",
            "Condition": { "StringEquals": { "s3files:AccessPointArn": "arn:aws:s3files:us-west-2:<ACCOUNT_ID>:file-system/<S3_FILES_FILE_SYSTEM_ID>/access-point/<S3_FILES_WRITER_AP_ID>" } }
        },
        {
            "Sid": "ReaderAccessPointReadOnly",
            "Effect": "Allow",
            "Principal": { "AWS": "arn:aws:iam::<ACCOUNT_ID>:role/AmazonEKS_EFS_CSI_NodeRole" },
            "Action": "s3files:ClientMount",
            "Resource": "arn:aws:s3files:us-west-2:<ACCOUNT_ID>:file-system/<S3_FILES_FILE_SYSTEM_ID>",
            "Condition": { "StringEquals": { "s3files:AccessPointArn": "arn:aws:s3files:us-west-2:<ACCOUNT_ID>:file-system/<S3_FILES_FILE_SYSTEM_ID>/access-point/<S3_FILES_READER_AP_ID>" } }
        },
        {
            "Sid": "DenyWriteThroughReaderAccessPoint",
            "Effect": "Deny",
            "Principal": { "AWS": "arn:aws:iam::<ACCOUNT_ID>:role/AmazonEKS_EFS_CSI_NodeRole" },
            "Action": "s3files:ClientWrite",
            "Resource": "arn:aws:s3files:us-west-2:<ACCOUNT_ID>:file-system/<S3_FILES_FILE_SYSTEM_ID>",
            "Condition": { "StringEquals": { "s3files:AccessPointArn": "arn:aws:s3files:us-west-2:<ACCOUNT_ID>:file-system/<S3_FILES_FILE_SYSTEM_ID>/access-point/<S3_FILES_READER_AP_ID>" } }
        }
    ]
}
```

The one CSI node role is allowed `ClientMount` and `ClientWrite` only through the writer access
point, `ClientMount` only through the reader access point, and is explicitly denied `ClientWrite`
through the reader access point. Never `ClientRootAccess`. S3 Files evaluates
`s3files:AccessPointArn` on every mount, so the read/write split rides on which access point a
pod mounts. The backing bucket's policy requires TLS:

```bash
aws s3api get-bucket-policy --bucket "$S3_BUCKET_NAME" --query 'Policy' --output text
```

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "DenyInsecureTransport",
            "Effect": "Deny",
            "Principal": "*",
            "Action": "s3:*",
            "Resource": [
                "arn:aws:s3:::<S3_BUCKET_NAME>",
                "arn:aws:s3:::<S3_BUCKET_NAME>/*"
            ],
            "Condition": { "Bool": { "aws:SecureTransport": "false" } }
        }
    ]
}
```

The mount-target security group admits exactly one rule, TCP 2049 from the cluster security
group:

```bash
aws ec2 describe-security-groups --group-ids "$S3_FILES_SECURITY_GROUP_ID" \
  --query 'SecurityGroups[0].IpPermissions' --output json
```

```json
[
  {
    "IpProtocol": "tcp",
    "FromPort": 2049,
    "ToPort": 2049,
    "UserIdGroupPairs": [ { "UserId": "<ACCOUNT_ID>", "GroupId": "sg-CLUSTER" } ],
    "IpRanges": [],
    "Ipv6Ranges": [],
    "PrefixListIds": []
  }
]
```

The group admits NFS from a security group, not a CIDR, so only interfaces that carry the
cluster security group, the cluster's own nodes and pods, can reach the mount targets.

## How the network policy works

These pods have a network: they reach the mount targets to mount the file system. So the sample
restricts their egress with an `ApplicationNetworkPolicy`, an EKS Auto Mode NetworkPolicy, and
does not set `sandbox.amazonaws.com/network-isolated` on them, because that would remove the
device used to reach the mount target.

[`deploy/egress-policy.yaml`](deploy/egress-policy.yaml) allows DNS on port 53 to any address
and NFS to the mount targets, and denies everything else, including all ingress. It is shown
here as it is in the repository, with its one placeholder: `setup.sh` (Step 5, the deploy)
expands `<MOUNT_TARGET_BLOCK>` into one `ipBlock` line per mount-target IP, from the addresses
it recorded in `.env`. The DNS rule is a literal `0.0.0.0/0` and needs no substitution.

```yaml
spec:
  podSelector:
    matchLabels:
      app: s3-files-shared
  policyTypes:
    - Ingress
    - Egress
  egress:
    - to:
        - ipBlock: { cidr: 0.0.0.0/0 }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to:
        <MOUNT_TARGET_BLOCK>
      ports:
        - { protocol: TCP, port: 2049 }
```

| Part | What it does |
| --- | --- |
| `podSelector: app=s3-files-shared` | Selects the writer and reader pods. |
| `policyTypes: [Ingress, Egress]` | Governs both directions; with no ingress rule, all ingress is denied. |
| First egress rule, `0.0.0.0/0` port 53 | Allows egress to any address on UDP and TCP 53. This is a project choice to keep the sample simple: it does not depend on how a given cluster serves DNS (on EKS Auto Mode the resolver is node-local rather than a pod behind a ClusterIP). What it allows is wider than DNS resolution: any process in the sandbox can reach any host on UDP or TCP 53, so it can send data out over DNS or to anything listening on port 53. What it costs is that port-53 egress is not confined to the cluster's own resolver. It still opens only port 53; every other port and protocol stays denied. |
| Second egress rule, `<MOUNT_TARGET_BLOCK>` | NFS (TCP 2049) to each S3 Files mount-target IP, one per Availability Zone. `setup.sh` expands one `- ipBlock: { cidr: <ip>/32 }` line per address from `aws s3files list-mount-targets`. |

The direct read-from-S3 optimization that S3 Files can enable runs in the driver on the node,
outside the guest, so the pod's own egress needs no S3 rule. This sample does not enable that
optimization, so nothing is granted on the shared node role; the mount and all reads still work
over NFS.

Network policy is turned on once per cluster through the `amazon-vpc-cni` ConfigMap, as the
[coding agent](../../getting-started/coding-agent/README.md) page describes; `setup.sh` waits for
the policy's `PolicyEndpoint` to appear before it starts the pods. The policy is enforced on the
node, outside the guest, so a command inside the sandbox cannot change it. Its limit: DNS is
open on port 53 to any address, so a resolver is always reachable, and a pod can always reach
its own node; that also means port-53 egress is not confined to the cluster's resolver (see the
first egress rule above). Everything beyond port 53 and the mount targets is denied.

With only DNS and NFS allowed, an outbound internet connection from inside the sandbox is
refused:

```bash
kubectl exec s3-files-writer -n "$NAMESPACE" -- wget -T 5 -q -O /dev/null https://example.com
echo "exit: $?"
```

```text
wget: download timed out
exit: 1
```

The connection times out and `wget` exits non-zero: the only egress the pods have is to DNS and
the mount targets.

## Good to know

- **Read and write are split by access point, not by pod identity.** S3 Files authorizes a
  mount with the CSI driver's node identity, the same principal for both pods, so the split
  cannot come from per-pod IAM. Instead the file system policy keys on `s3files:AccessPointArn`:
  the writer access point is granted `ClientWrite`, the reader access point is not (and is
  explicitly denied it). The two access points are rooted at the same directory, so they are one
  dataset with two levels of access.
- **Three identities, each scoped.** S3 Files separates the mount identity, the synchronization
  identity and the workload, and the sample gives each only what it needs.

  | Identity | Used for | Scoped to |
  |---|---|---|
  | CSI node role (`efs-csi-node-sa`) | Mounting the access points | Used as it is: the sample never changes it. The sample's own file system policy grants this principal read-write via the writer access point and read-only via the reader access point. |
  | Synchronization role | Assumed by S3 Files to keep the file system and the bucket in sync | This bucket only; its trust is narrowed to the exact file system once that exists. |
  | Workload ServiceAccount | The two pods | No AWS association at all; giving an application pod a role does not satisfy the mount helper. |

- **The EFS CSI driver is a shared install.** The sample reads which role the driver's node
  service account uses and never changes the driver, its service accounts, their IAM roles or
  their Pod Identity associations. The least privilege for this file system lives in the file
  system policy, which belongs to the sample's own file system, not on the shared node role.
  Public documentation describes the node role with the broad `AmazonS3FilesClientFullAccess`
  managed policy; this sample grants the mount actions from the resource side instead, scoped to
  this one file system and split per access point.
- **The managed EC2 node role is left alone.** An Auto Mode EC2 node instance-profile role is a
  shared, managed role that should keep what it ships with. The sample never reads, grants to, or
  denies it: the file system is default-deny and authorized only through the per-access-point
  file system policy, so the node role is not part of the design.
- **The pods have no AWS identity of their own, but their mount uses a shared one.** The pods'
  ServiceAccount has no Pod Identity association and mounts no API token. The mount is signed
  with the CSI driver's node role, the same role every mount through the driver on the cluster
  uses. What bounds these pods' use of it is the egress policy, which lets them reach only this
  file system's mount targets, and the file system policy, which allows that role read-write
  through the writer access point and read-only through the reader access point, by the
  `s3files:AccessPointArn` condition, on this file system only.
- **What else the shared node role can mount is the cluster owner's choice.** If you own the
  cluster, check the role's own IAM policies: a broad client policy such as
  `AmazonS3FilesClientFullAccess` is not limited to one file system. To narrow it, scope the
  role's mount permissions to named file systems or to a resource tag. The sample does not
  change the role, because other workloads' mounts depend on it.
- **The backing bucket is versioned and encrypted.** S3 Files requires S3 Versioning and
  server-side encryption to synchronize; the sample also turns on Block Public Access and a
  TLS-only bucket policy. The clean up deletes only a bucket this sample created and tagged.
- **Shared on purpose, with asymmetric access.** Unlike an EBS volume, which one pod holds at a
  time, this dataset is mounted by both pods at once, the writer read-write and the reader
  read-only. For a single pod that needs durable block storage, use the [EBS](../ebs/README.md)
  sample; for shared POSIX files with no S3 object view, use the [EFS](../efs/README.md) sample.
  This sample is the choice when the same data must be both a shared POSIX file system and plain
  S3 objects.
- **Do not set `network-isolated` on these pods.** They need a network to reach the mount target,
  so they take an egress network policy instead of the network-isolated annotation.
- **The pods pin their node while the sample is up.** They are bare pods, and nothing recreates
  a bare pod that EKS Auto Mode removes when it consolidates an underused node, so both carry
  `karpenter.sh/do-not-disrupt: "true"`. That also keeps their node from being consolidated
  until the clean up deletes them. A real workload runs under a controller instead.

## Install the EFS CSI driver for S3 Files

This sample needs the Amazon EFS CSI driver on the cluster, at **3.5.1 or newer** for S3 Files,
with EKS Pod Identity roles for its controller and node service accounts. On the maintainers'
cluster it was already installed; on a cluster without it, install it once following the
[S3 Files CSI guide](https://docs.aws.amazon.com/eks/latest/userguide/s3files-csi.html), and
`setup.sh` will find and reuse it. The driver's node service account must carry a Pod Identity
association, because S3 Files always mounts with IAM authorization, which needs the mount signed
with the node role's identity. `setup.sh` compares every component of the installed version
against 3.5.1, not the major alone, so a 3.x driver older than 3.5.1 is caught. It then stops
with the command that fits the cluster: `create-addon` when there is no add-on, `update-addon`
when the add-on is too old, and for a driver installed some other way, a note to upgrade it the
way it was installed rather than a command that would fail. A lookup it cannot make — listing
the add-ons, reading the add-on's version, reading the daemonset — stops the run saying the
version could not be determined, which is never read as "not installed". It also stops when the
node service account has no association, and it never creates or changes the driver's roles.

## Clean up

The commands use the variables from the walkthrough. In a new shell, set them again first:

```bash
export CLUSTER_NAME=<your-cluster> AWS_REGION=us-west-2 NAMESPACE=nitro-s3-files-sample
```

[`scripts/clean.sh`](scripts/clean.sh) deletes the two pods, the two PVCs and the workload
ServiceAccount, the two static PVs, the egress policy, and the sample's own StorageClass. It
checks the namespace carries the sample's label before deleting anything inside it, and exits
non-zero if it skipped or could not confirm a delete.

```bash
NAMESPACE="$NAMESPACE" ./scripts/clean.sh
```

To release the S3 Files file system, the bucket and everything else `setup.sh` created, add
`--delete-aws-resources`. It uses `.env` as its deletion record and deletes the two access
points, every mount target, the file system, the synchronization role, the NFS security group,
and (**only when the sample created it**, re-proven by the live bucket tag) every object version
in the bucket **and the bucket itself**, then deletes `.env`:

```bash
NAMESPACE="$NAMESPACE" ./scripts/clean.sh --delete-aws-resources
```

```text
Namespace 'nitro-s3-files-sample' is this sample's (labelled app.kubernetes.io/part-of=storage-s3-files).
Deleting pods, PVC, ServiceAccount, PV, and the egress policy...
Deleting writer access point fsap-EXAMPLE...
Deleting reader access point fsap-EXAMPLE...
Deleting S3 Files mount targets...
Deleting S3 Files file system fs-EXAMPLE...
Deleting synchronization role storage-s3-files-<cluster>-sync...
Deleting NFS security group sg-EXAMPLE...
Deleting all object versions from s3://<S3_BUCKET_NAME>...
Deleting bucket s3://<S3_BUCKET_NAME>...

Released the S3 Files access points, mount targets, file system, synchronization role,
NFS security group and bucket.
The shared EFS CSI driver, its service accounts, their IAM roles and their Pod
Identity associations were left exactly as they were. The 'nitro-s3-files-sample' namespace is
left in place.
```

Neither mode touches the shared EFS CSI driver, its service accounts, their IAM roles or their
Pod Identity associations. The bucket is deleted only when its live `ManagedBy=storage-s3-files`
tag proves the sample created it; a bucket without that tag is left untouched. If a mount-target
delete reports the interface is still in use, wait for the mount-target network interfaces to
disappear and run it again; `clean.sh` is safe to re-run.

If this is the last sample you ran, follow the
[hello sandbox](../../getting-started/hello-sandbox/README.md#clean-up) clean up to remove the
namespace and the cluster.
