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
shared prerequisite, at **3.0.0 or newer**, which is the version that adds S3 Files;
[Install the EFS CSI driver for S3 Files](#install-the-efs-csi-driver-for-s3-files) below
has the one-time setup for a cluster that does not have it. What it costs beyond the cluster
is the backing S3 bucket, billed for the objects stored and for S3 requests including the
synchronization traffic; the two pods are small and the shared directory holds a couple of
tiny files, and the clean up deletes the bucket and the file system.

Two sandboxed pods, a writer and a reader, mount one
[Amazon S3 Files](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-files-mounting-eks.html)
access point, backed by a versioned S3 bucket, through a single access point at `/shared`,
each over TLS with IAM authorization. A file written through one appears through the other,
and also appears as an object in the backing bucket, and an object put in the bucket appears
as a file on `/shared`. So it is one shared POSIX file system that many hardware-isolated
pods read and write at once, and the same data is addressable as plain S3 objects from
outside the cluster. Each pod is an ordinary pod spec with one line added, the runtime class.

- **Two sandboxed pods share one access point.** The writer and the reader are both
  `isolated-sandbox` pods on the same `ReadWriteMany` claim. The page writes a file through
  the writer and reads it through the reader, then writes back the other way.
- **Files and S3 objects are the same data.** A file written through `/shared` appears as an
  object in the backing bucket, and an object put in the bucket appears as a file on
  `/shared`. Synchronization is asynchronous, so the page waits rather than assuming it is
  immediate.
- **Each pod runs in its own sandbox.** Both pods show their own kernel build and their own
  virtio disks, next to what an ordinary pod shows. ([hello sandbox](../../getting-started/hello-sandbox/README.md).)
- **The mount lives inside the guest.** In each pod, `/shared` is an `nfs4` mount whose
  endpoint is the guest's own loopback TLS endpoint, and the node holds no NFS mount for
  these pods. The guest terminates its own TLS to the mount target; the node coordinates the
  CSI operation but is not on the file-data path.
- **The access point pins the identity, and the workload holds no AWS identity.** Every mount
  through the access point runs as one POSIX UID/GID, and the pods' ServiceAccount has no AWS
  association and mounts no Kubernetes API token. What authorizes the mount is the CSI
  driver's node identity, allowed on this one file system by the sample's own file system
  policy.

*Figure 1: Two sandboxed pods share one S3 Files access point, backed by a versioned S3
bucket. A writer and a reader, each an `isolated-sandbox` pod, mount the same access point at
`/shared` over TLS with IAM authorization. Each reaches the file system through a mount target
whose security group admits NFS from the cluster only, and through one access point that pins
the identity and the root directory. The file system keeps the access point and the S3 bucket
in sync, so the same data is a POSIX file and an S3 object.*

![Inside the AWS Cloud, an Amazon EKS cluster holds two Nitro sandbox frames, each a lightweight VM with its own kernel. The upper frame holds the Writer pod and the lower frame holds the Reader pod, both isolated-sandbox pods with /shared mounted. From each pod a line runs right, out of the cluster, to an S3 Files mount target inside a security group labelled TCP 2049 from the cluster. The mount flow is labelled mount over tls and iam, signed by the CSI node role. From the mount target a line continues to an S3 Files access point, labelled uid/gid 1000 and fixed root, which keeps in two-way sync with a versioned Amazon S3 bucket on the right. Below, an EFS CSI driver node role icon sits beside a note: the file system policy allows the CSI node role on this file system only, and denies the EC2 node role.](images/s3-files-shared-storage.png)

This folder was built against these releases:

| Component | Version |
|---|---|
| Amazon EFS CSI driver add-on ([kubernetes-sigs/aws-efs-csi-driver](https://github.com/kubernetes-sigs/aws-efs-csi-driver)) | `v3.5.1-eksbuild.1` on the run below; the sample needs **3.0.0 or newer** for S3 Files |
| AWS CLI with the `aws s3files` commands ([aws/aws-cli](https://github.com/aws/aws-cli)) | `2.36.47` on the run below; any current 2.x release |
| `busybox` image ([public.ecr.aws/docker/library/busybox](https://gallery.ecr.aws/docker/library/busybox)) | `1.37` |

The files:

| File | What it is |
|---|---|
| [`deploy/s3-files.yaml`](deploy/s3-files.yaml) | The sample's non-default `nitro-sandbox-s3-files` StorageClass, a static access-point PV (mount options `tls,iam`, `s3files:` volume handle), its `ReadWriteMany` PVC, a workload ServiceAccount with no identity, and the writer and reader `isolated-sandbox` pods. |
| [`deploy/egress-policy.yaml`](deploy/egress-policy.yaml) | The egress `ApplicationNetworkPolicy`: DNS to CoreDNS and NFS (TCP 2049) to the mount targets, deny all ingress. |
| [`iam/file-system-policy.json`](iam/file-system-policy.json) | The S3 Files file system policy template: this file system only, `ClientMount`/`ClientWrite` for the CSI node principal only, and an explicit deny of the EC2 node role. |
| [`iam/bucket-policy.json`](iam/bucket-policy.json) | The backing bucket's policy template: TLS required, and the EC2 node role denied every S3 action. |
| [`iam/sync-role-trust.json`](iam/sync-role-trust.json) / [`iam/sync-role-permissions.json`](iam/sync-role-permissions.json) | The synchronization role's trust (the S3 Files service, this file system) and permissions (this bucket only). |
| [`scripts/setup.sh`](scripts/setup.sh) | Checks the EFS CSI driver (shared, reused, never changed); creates the bucket, synchronization role, file system, NFS security group, mount targets and access point; applies the file system and bucket policies; then deploys the namespace, the egress policy, the StorageClass, the PV, the PVC and the two pods. |
| [`scripts/clean.sh`](scripts/clean.sh) | Deletes the Kubernetes objects; `--delete-aws-resources` also releases the access point, mount targets, file system, synchronization role, security group and (only when the sample created it) the bucket. |

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
below needs. It first confirms the Amazon EFS CSI driver is installed at 3.0.0 or newer and
reads, without changing it, which IAM role the driver's node service account uses and which
role the EC2 nodes use. It creates the sample's own resources, each tagged
`ManagedBy=storage-s3-files` and `auto-delete=no`: a versioned, encrypted S3 bucket with
Block Public Access and a TLS-only bucket policy that also denies the EC2 node role; a
synchronization role scoped to that bucket; an S3 Files file system on the bucket; an NFS
security group that admits TCP 2049 from the cluster security group only; one mount target per
cluster Availability Zone; and an access point that pins UID/GID 1000 under `/storage-s3-files`.
It applies a file system policy that allows only the CSI node principal to mount this one file
system and denies the EC2 node role. Finally it deploys the Kubernetes side: the namespace, the
egress `ApplicationNetworkPolicy` (waiting for its `PolicyEndpoint` before the pods start), the
StorageClass, the static PV, the `ReadWriteMany` PVC, and the writer and reader pods, and waits
for both to become Ready.

The PV mounts the access point with `tls,iam`, and its volume handle starts with `s3files:`, so
the driver mounts an S3 Files file system rather than a plain EFS one. The pods run as a
non-root user with `fsGroup` so the unprivileged process can write the shared directory:

```yaml
spec:
  mountOptions:
    - tls
    - iam
  csi:
    driver: efs.csi.aws.com
    volumeHandle: s3files:<S3_FILES_FILE_SYSTEM_ID>::<S3_FILES_ACCESS_POINT_ID>
```

```yaml
spec:
  runtimeClassName: isolated-sandbox      # the one-line opt-in
  serviceAccountName: s3-files-workload   # no AWS identity, no API token
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
```

```bash
./scripts/setup.sh
```

The run below started on a cluster with none of the sample's AWS resources present:

```text
Step 1/6: check the Amazon EFS CSI driver (a shared install; reused, never changed)
  found aws-efs-csi-driver v3.5.1-eksbuild.1 (>= 3.0.0).
  CSI node principal (read, not changed): arn:aws:iam::<ACCOUNT_ID>:role/AmazonEKS_EFS_CSI_NodeRole
  EC2 node role (read, not changed): arn:aws:iam::<ACCOUNT_ID>:role/<EC2_NODE_ROLE>
Step 2/6: create the sample's bucket, synchronization role, file system, security group, mount targets and access point
  creating the S3 bucket <S3_BUCKET_NAME>...
  applying the bucket policy (TLS-only, deny the EC2 node role)...
  creating the synchronization role storage-s3-files-<cluster>-sync...
  creating the S3 Files file system on <S3_BUCKET_NAME>...
  created NFS security group sg-EXAMPLE (TCP 2049 from sg-CLUSTER only).
  ensuring one S3 Files mount target per cluster Availability Zone...
  creating the S3 Files access point (uid/gid 1000, root /storage-s3-files)...
Step 3/6: apply the S3 Files file system policy (this file system, CSI node principal only, deny EC2 node role)
  file system policy applied.
Step 4/6: record the CoreDNS and mount-target addresses for the network policy
  CoreDNS: <COREDNS_IP>
  mount targets: <MOUNT_TARGET_IP> <MOUNT_TARGET_IP> <MOUNT_TARGET_IP>
Step 5/6: deploy the egress policy and the two sandbox pods
  created namespace 'nitro-s3-files-sample' and labelled it this sample's.
applicationnetworkpolicy.networking.k8s.aws/s3-files-shared-egress created
  waiting for the PolicyEndpoint to be programmed...
storageclass.storage.k8s.io/nitro-sandbox-s3-files created
serviceaccount/s3-files-workload created
persistentvolume/storage-s3-files-shared created
persistentvolumeclaim/storage-s3-files-shared created
pod/s3-files-writer created
pod/s3-files-reader created
Step 6/6: wait for both pods to become Ready (sandbox VM boot + NFS mount)
pod/s3-files-writer condition met
pod/s3-files-reader condition met

S3 Files storage is ready and both pods are Running. Resource IDs and addresses: .../examples/storage/s3-files/.env
```

Setup writes the resource IDs and the CoreDNS and mount-target addresses to a gitignored
`.env`, which it uses to render the manifests. The EFS CSI driver, its service accounts, their
IAM roles and their Pod Identity associations are a shared install and are not touched.

**Step 2: The claim is bound and both pods are Running.** The claim binds `ReadWriteMany`, so
both pods mount the same volume.

```bash
kubectl get pods,pvc -n "$NAMESPACE"
```

```text
NAME                  READY   STATUS    RESTARTS   AGE
pod/s3-files-reader   1/1     Running   0          16m
pod/s3-files-writer   1/1     Running   0          16m

NAME                                            STATUS   VOLUME                    CAPACITY   ACCESS MODES   STORAGECLASS             VOLUMEATTRIBUTESCLASS   AGE
persistentvolumeclaim/storage-s3-files-shared   Bound    storage-s3-files-shared   5Gi        RWX            nitro-sandbox-s3-files   <unset>                 16m
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

**Step 4: The mount lives inside the guest.** In each pod, `/shared` is an `nfs4` mount whose
server address is the guest's own `127.0.0.1`: the NFS client and the TLS endpoint run inside
the guest, reached over a local port the mount helper opens.

```bash
kubectl exec s3-files-writer -n "$NAMESPACE" -- grep ' /shared ' /proc/mounts
```

```text
127.0.0.1:/ /shared nfs4 rw,relatime,vers=4.2,rsize=1048576,wsize=1048576,namlen=255,hard,noresvport,fatal_neterrors=none,proto=tcp,port=45151,timeo=600,retrans=2,sec=sys,clientaddr=127.0.0.1,local_lock=none,addr=127.0.0.1 0 0
```

The server is `127.0.0.1` and the connection runs over a local port (`port=45151`): the guest
terminates its own TLS to the mount target. The node holds no NFS mount for these pods, so the
plaintext file traffic does not traverse the node.

**Step 5: The access point pins the identity, and a non-root process writes `/shared`.** The
access point enforces UID/GID 1000 under its fixed root directory, whatever user the client
claims. The container runs as uid 1000 with `fsGroup: 1000`, so the unprivileged process writes
the shared directory.

```bash
kubectl exec s3-files-writer -n "$NAMESPACE" -- id
kubectl exec s3-files-writer -n "$NAMESPACE" -- sh -c 'echo hello-from-writer > /shared/from-writer'
kubectl exec s3-files-writer -n "$NAMESPACE" -- ls -ln /shared
```

```text
uid=1000 gid=1000 groups=1000
total 4
-rw-r--r--    1 1000     1000            18 Oct 21 15:04 from-writer
```

The file is owned by UID/GID 1000, the identity the access point enforces, and the uid-1000
process wrote it without root.

**Step 6: The two pods share one access point.** Read the writer's file through the reader, and
write back the other way.

```bash
kubectl exec s3-files-reader -n "$NAMESPACE" -- cat /shared/from-writer
kubectl exec s3-files-reader -n "$NAMESPACE" -- sh -c 'echo hello-from-reader > /shared/from-reader'
kubectl exec s3-files-writer -n "$NAMESPACE" -- cat /shared/from-reader
```

```text
hello-from-writer
hello-from-reader
```

The reader sees the file the writer wrote, and the writer sees the file the reader wrote: one
shared file system, not two empty mounts.

**Step 7: A file on `/shared` is an object in the bucket.** S3 Files keeps the access point and
the backing bucket in sync. Synchronization is asynchronous, so wait a few seconds, then list
the bucket under the access point's root prefix (`storage-s3-files/`). The file the writer wrote
is there as an object.

```bash
aws s3 ls "s3://$S3_BUCKET_NAME/storage-s3-files/"
aws s3api get-object --bucket "$S3_BUCKET_NAME" --key storage-s3-files/from-writer /dev/stdout
```

```text
2026-10-21 15:12:43         18 from-writer
2026-10-21 15:12:46         18 from-reader
hello-from-writer
```

Both files written through `/shared` appear as objects under the access point's prefix, and the
object holds exactly what was written on the mount.

**Step 8: An object in the bucket is a file on `/shared`.** The other direction works too. Put
an object directly in the bucket under the access point's prefix, wait for the synchronization,
and read it back on `/shared`.

```bash
echo hello-from-s3 | aws s3 cp - "s3://$S3_BUCKET_NAME/storage-s3-files/from-s3"
# wait a few seconds for the synchronization
kubectl exec s3-files-reader -n "$NAMESPACE" -- cat /shared/from-s3
kubectl exec s3-files-reader -n "$NAMESPACE" -- ls -ln /shared
```

```text
hello-from-s3
total 16
-rw-r--r--    1 1000     1000            32 Oct 21 15:11 from-reader
-rw-r--r--    1 1000     1000            18 Oct 21 15:07 from-writer
-rw-r--r--    1 0        0               32 Oct 21 15:13 from-s3
```

The object appears as a file on `/shared`, so the same data is reachable both as a POSIX file
and as an S3 object. Notice the owner: a file written through the access point is uid/gid 1000,
but `from-s3`, which entered through the bucket rather than the access point, keeps the object's
own ownership (uid/gid 0). The access point's POSIX identity applies to writes through the
mount, not to objects synchronized in from S3.

**Step 9: IAM authorizes the mount.** The pods mount with `tls,iam`, so the mount helper signs
the connection with the CSI driver's node identity, and the file system policy decides by
principal. For a principal in the same account, an `Allow` in this resource policy is enough to
authorize the mount, so the sample adds nothing to the shared CSI node role. Read the policy back
from S3 Files:

```bash
aws s3files get-file-system-policy --file-system-id "$S3_FILES_FILE_SYSTEM_ID" \
  --query 'policy' --output text
```

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowCSINodePrincipal",
            "Effect": "Allow",
            "Principal": { "AWS": "arn:aws:iam::<ACCOUNT_ID>:role/AmazonEKS_EFS_CSI_NodeRole" },
            "Action": [ "s3files:ClientMount", "s3files:ClientWrite" ],
            "Resource": "arn:aws:s3files:us-west-2:<ACCOUNT_ID>:file-system/<S3_FILES_FILE_SYSTEM_ID>"
        },
        {
            "Sid": "DenyEC2NodeRole",
            "Effect": "Deny",
            "Principal": { "AWS": "arn:aws:iam::<ACCOUNT_ID>:role/<EC2_NODE_ROLE>" },
            "Action": [ "s3files:ClientMount", "s3files:ClientWrite", "s3files:ClientRootAccess" ],
            "Resource": "arn:aws:s3files:us-west-2:<ACCOUNT_ID>:file-system/<S3_FILES_FILE_SYSTEM_ID>"
        }
    ]
}
```

The policy allows only the CSI node role, only `ClientMount` and `ClientWrite` (never
`ClientRootAccess`), only on this file system, and explicitly denies the EC2 node role. The
backing bucket's policy denies the EC2 node role every S3 action and requires TLS:

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
        },
        {
            "Sid": "DenyEC2NodeRoleDataAccess",
            "Effect": "Deny",
            "Principal": "*",
            "Action": "s3:*",
            "Resource": [
                "arn:aws:s3:::<S3_BUCKET_NAME>",
                "arn:aws:s3:::<S3_BUCKET_NAME>/*"
            ],
            "Condition": { "ArnEquals": { "aws:PrincipalArn": "arn:aws:iam::<ACCOUNT_ID>:role/<EC2_NODE_ROLE>" } }
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

[`deploy/egress-policy.yaml`](deploy/egress-policy.yaml) allows DNS to CoreDNS and NFS to the
mount targets, and denies everything else, including all ingress. It is shown here as it is in
the repository, with its placeholders: `setup.sh` (Step 5, the deploy) fills in `<COREDNS_IP>`
from the CoreDNS Service address and expands `<MOUNT_TARGET_BLOCK>` into one `ipBlock` line per
mount-target IP, both from the addresses it recorded in `.env`.

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
        - ipBlock: { cidr: <COREDNS_IP>/32 }
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
| First egress rule, `<COREDNS_IP>` | DNS to the CoreDNS Service address on UDP and TCP 53. `setup.sh` reads the address with `kubectl get svc -n kube-system kube-dns`. |
| Second egress rule, `<MOUNT_TARGET_BLOCK>` | NFS (TCP 2049) to each S3 Files mount-target IP, one per Availability Zone. `setup.sh` expands one `- ipBlock: { cidr: <ip>/32 }` line per address from `aws s3files list-mount-targets`. |

The direct read-from-S3 optimization that S3 Files can enable runs in the driver on the node,
outside the guest, so the pod's own egress needs no S3 rule. This sample does not enable that
optimization, so nothing is granted on the shared node role; the mount and all reads still work
over NFS.

Network policy is turned on once per cluster through the `amazon-vpc-cni` ConfigMap, as the
[coding agent](../../getting-started/coding-agent/README.md) page describes; `setup.sh` waits for
the policy's `PolicyEndpoint` to appear before it starts the pods. The policy is enforced on the
node, outside the guest, so a command inside the sandbox cannot change it. Its limit: an
`ipBlock` rule allows addresses, so anything else on the same addresses is reachable, and a pod
can always reach its own node.

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

- **Three identities, each scoped.** S3 Files separates the mount identity, the synchronization
  identity and the workload, and the sample gives each only what it needs.

  | Identity | Used for | Scoped to |
  |---|---|---|
  | CSI node role (`efs-csi-node-sa`) | Mounting the access point | Used as it is: the sample never changes it. The sample's own file system policy allows this principal `ClientMount`/`ClientWrite` on this file system only. |
  | Synchronization role | Assumed by S3 Files to keep the file system and the bucket in sync | This bucket only; its trust is narrowed to the exact file system once that exists. |
  | Workload ServiceAccount | The two pods | No AWS association at all; giving an application pod a role does not satisfy the mount helper. |

- **The EFS CSI driver is a shared install.** The sample reads which role the driver's node
  service account uses and never changes the driver, its service accounts, their IAM roles or
  their Pod Identity associations. The least privilege for this file system lives in the file
  system policy, which belongs to the sample's own file system, not on the shared node role.
  Public documentation describes the node role with the broad `AmazonS3FilesClientFullAccess`
  managed policy; this sample grants the same mount actions from the resource side instead,
  scoped to this one file system.
- **The workload has no AWS identity.** The pods' ServiceAccount has no Pod Identity association
  and mounts no API token. What authorizes the mount is the CSI driver's identity and the file
  system policy, so giving an application pod its own role would not change how the volume is
  mounted.
- **The backing bucket is versioned and encrypted.** S3 Files requires S3 Versioning and
  server-side encryption to synchronize; the sample also turns on Block Public Access and a
  TLS-only bucket policy. The clean up deletes only a bucket this sample created and tagged.
- **`ReadWriteMany`, shared on purpose.** Unlike an EBS volume, which one pod holds at a time,
  this access point is mounted by both pods at once. For a single pod that needs durable block
  storage, use the [EBS](../ebs/README.md) sample; for shared POSIX files with no S3 object view,
  use the [EFS](../efs/README.md) sample. This sample is the choice when the same data must be
  both a shared POSIX file system and plain S3 objects.
- **Do not set `network-isolated` on these pods.** They need a network to reach the mount target,
  so they take an egress network policy instead of the network-isolated annotation.

## Install the EFS CSI driver for S3 Files

This sample needs the Amazon EFS CSI driver on the cluster, at **3.0.0 or newer**, which is the
version that adds S3 Files, with EKS Pod Identity roles for its controller and node service
accounts. On the maintainers' cluster it was already installed; on a cluster without it, install
it once following the
[S3 Files CSI guide](https://docs.aws.amazon.com/eks/latest/userguide/s3files-csi.html), and
`setup.sh` will find and reuse it. The driver's node service account must carry a Pod Identity
association, because S3 Files always mounts with IAM authorization, which needs the mount signed
with the node role's identity. `setup.sh` stops with the install guidance when the driver is
absent, older than 3.0.0, or its node service account has no association, and it never creates or
changes the driver's roles.

## Clean up

The commands use the variables from the walkthrough. In a new shell, set them again first:

```bash
export CLUSTER_NAME=<your-cluster> AWS_REGION=us-west-2 NAMESPACE=nitro-s3-files-sample
```

[`scripts/clean.sh`](scripts/clean.sh) deletes the two pods, the PVC and workload ServiceAccount,
the static PV, the egress policy, and the sample's own StorageClass. It checks the namespace
carries the sample's label before deleting anything inside it, and exits non-zero if it skipped or
could not confirm a delete.

```bash
NAMESPACE="$NAMESPACE" ./scripts/clean.sh
```

To release the S3 Files file system, the bucket and everything else `setup.sh` created, add
`--delete-aws-resources`. It uses `.env` as its deletion record and deletes the access point,
every mount target, the file system, the synchronization role, the NFS security group, and
(**only when the sample created it**, re-proven by the live bucket tag) every object version in
the bucket **and the bucket itself**, then deletes `.env`:

```bash
NAMESPACE="$NAMESPACE" ./scripts/clean.sh --delete-aws-resources
```

```text
Namespace 'nitro-s3-files-sample' is this sample's (labelled app.kubernetes.io/part-of=storage-s3-files).
Deleting pods, PVC, ServiceAccount, PV, and the egress policy...
Deleting S3 Files access point fsap-EXAMPLE...
Deleting S3 Files mount targets...
Deleting S3 Files file system fs-EXAMPLE...
Deleting synchronization role storage-s3-files-<cluster>-sync...
Deleting NFS security group sg-EXAMPLE...
Deleting all object versions from s3://<S3_BUCKET_NAME>...
Deleting bucket s3://<S3_BUCKET_NAME>...

Released the S3 Files access point, mount targets, file system, synchronization role,
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
