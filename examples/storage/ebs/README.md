# EBS volumes for sandboxed pods

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run the [hello sandbox](../../getting-started/hello-sandbox/README.md)
sample first so you have an EKS Auto Mode cluster with the runtime classes. The commands
below use files from this repository, so clone it if you have not already, and run them
from this sample's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/storage/ebs
```

This sample needs the AWS CLI, which the home page already lists, for one step that reads
the provisioned volume back from EC2. What it costs beyond the cluster is the EBS volumes
it provisions: one for the single pod and one per StatefulSet replica, each billed while it
exists. The clean up deletes them.

A sandboxed pod is an ordinary pod in most ways, and storage is one of them: it mounts
volumes through the same CSI drivers. This sample gives an `isolated-sandbox` pod a
dynamically provisioned Amazon EBS volume, and a StatefulSet whose replicas each get their
own volume that outlives the pod. The volume is provisioned by the EKS Auto Mode EBS CSI
driver, attached to the node, and passed into the guest, where the pod sees it as a virtio
block device. The pod spec is an ordinary one with the runtime class added.

- **The CSI driver stays an ordinary part of the cluster.** It runs on the node, attaches
  the EBS volume to the node, and passes the block device into the guest. Nothing about the
  sandbox changes how a volume is provisioned.
- **Inside the guest the volume is a virtio device.** The pod sees `/data` on a `/dev/vd*`
  device, where an ordinary pod on the same node sees an `nvme` device for the same kind of
  volume.
- **The pod needs no network for its storage.** The EBS data path does not use the pod
  network, so the pod boots with `sandbox.amazonaws.com/network-isolated: "true"`: only
  loopback, no route out, and it still mounts and writes its volume.
- **Single-writer by design.** The claim is `ReadWriteOncePod`, so a second pod claiming
  the same volume stays `Pending`. For data shared by several pods at once, use the EFS or
  S3 Files sample in this section.

*Figure 1: How an EBS volume reaches a sandboxed pod. The EKS Auto Mode EBS CSI driver on
the node attaches the volume and passes the block device into the guest, where the pod
mounts it at `/data` as a virtio device.*

![Inside an EKS node (an EC2 instance), an EBS volume that is gp3 and encrypted is attached to the node by the EBS CSI driver (ebs.csi.eks.amazonaws.com), which then passes the block device into a Nitro sandbox whose runtimeClassName is isolated-sandbox. Inside the sandbox a lightweight VM with its own kernel for this pod only holds the pod container, which sees the volume at /data as /dev/vdX, a virtio device.](images/ebs-volume-passthrough.png)

This folder was built against these releases:

| Component | Version |
|---|---|
| EKS Auto Mode EBS CSI driver (`ebs.csi.eks.amazonaws.com`) | built into EKS Auto Mode; not separately installed |
| `busybox` image ([public.ecr.aws/docker/library/busybox](https://gallery.ecr.aws/docker/library/busybox)) | `1.37` |

The files:

| File | What it is |
|---|---|
| [`deploy/storage-class.yaml`](deploy/storage-class.yaml) | The `auto-ebs-sc` StorageClass the reader applies once per cluster: gp3, encrypted, not the cluster default. |
| [`deploy/pod-ebs.yaml`](deploy/pod-ebs.yaml) | One `isolated-sandbox` pod on a `ReadWriteOncePod` claim, non-root with `fsGroup`, network-isolated. |
| [`deploy/pod-ebs-second.yaml`](deploy/pod-ebs-second.yaml) | A second pod that claims the same volume, to show it stays `Pending`. |
| [`deploy/pod-ordinary.yaml`](deploy/pod-ordinary.yaml) | An ordinary (non-sandboxed) pod with its own EBS volume, for the virtio-vs-nvme comparison in Step 3. |
| [`deploy/statefulset-ebs.yaml`](deploy/statefulset-ebs.yaml) | A StatefulSet whose replicas each get their own volume via `volumeClaimTemplates`, with a headless Service. |
| [`scripts/setup.sh`](scripts/setup.sh) | Checks the StorageClass, then applies the PVC and pod and waits for the volume to attach. |
| [`scripts/test.sh`](scripts/test.sh) | Checks the claims: the sandbox, the virtio device, the non-root write, data surviving the pod, the `Pending` second pod, and the volume read back from EC2. |
| [`scripts/clean.sh`](scripts/clean.sh) | Deletes the pods, the StatefulSet and the Service, and every PVC this sample creates and its EBS volume. |

The walkthrough uses the shared Region default from the home page, and a namespace of its
own so the sample's objects are easy to find and remove on a shared cluster. Set them in
your shell:

```bash
export AWS_REGION=us-west-2
export NAMESPACE=nitro-ebs-sample
```

`setup.sh` creates the namespace if it is absent and labels it as this sample's, so the
clean up only ever touches objects this sample created.

**Step 1: Create the StorageClass, once per cluster.** EKS Auto Mode ships no StorageClass,
so the reader creates one. [`deploy/storage-class.yaml`](deploy/storage-class.yaml) is the
Auto Mode class from the Amazon EKS User Guide, *Create a storage class*: it names the Auto
Mode EBS provisioner, asks for gp3 and encryption, and binds on first consumer so the volume
is created in the pod's Availability Zone after scheduling. It carries no default-class
annotation, so applying it does not change what every other workload on the cluster
provisions through.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: auto-ebs-sc
allowedTopologies:
  - matchLabelExpressions:
      - key: eks.amazonaws.com/compute-type
        values:
          - auto
provisioner: ebs.csi.eks.amazonaws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
  encrypted: "true"
```

A StorageClass is a cluster-wide object, so this sample's scripts never create, change or
delete it: you apply it once, and the clean up leaves it. If `auto-ebs-sc` already exists on
your cluster, this command fails because its `parameters` are immutable; that is fine, the
sample reuses the existing class as long as it uses the Auto Mode provisioner.

```bash
kubectl apply -f deploy/storage-class.yaml
kubectl get storageclass auto-ebs-sc
```

```text
NAME          PROVISIONER                 RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
auto-ebs-sc   ebs.csi.eks.amazonaws.com   Delete          WaitForFirstConsumer   false                  60d
```

The run above reused a cluster that already had an `auto-ebs-sc` with the Auto Mode
provisioner, so `kubectl apply` was not needed and the `AGE` is the existing class's. Look
at the `PROVISIONER` column: it must read `ebs.csi.eks.amazonaws.com`. `setup.sh` checks
exactly that and stops with this command when the class is missing or uses another
provisioner.

**Step 2: Create the pod and its claim.** [`scripts/setup.sh`](scripts/setup.sh) confirms
the StorageClass, creates the namespace if it is absent, and applies
[`deploy/pod-ebs.yaml`](deploy/pod-ebs.yaml): a `ReadWriteOncePod` claim and an
`isolated-sandbox` pod that mounts it at `/data`. The pod runs as a non-root user with
`fsGroup` set, and boots network-isolated.

```yaml
spec:
  runtimeClassName: isolated-sandbox   # the one-line opt-in
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 2000
```

```yaml
spec:
  accessModes:
    - ReadWriteOncePod
  storageClassName: auto-ebs-sc
  resources:
    requests:
      storage: 10Gi
```

```bash
./scripts/setup.sh
```

```text
Step 1/3: confirm the 'auto-ebs-sc' StorageClass exists with the Auto Mode EBS provisioner
  'auto-ebs-sc' exists with provisioner 'ebs.csi.eks.amazonaws.com'. Leaving it as-is.
Step 2/3: create the namespace (only if absent) and apply the PVC and pod
  created namespace 'nitro-ebs-sample' and labelled it 'app.kubernetes.io/part-of=nitro-sandbox-ebs'.
persistentvolumeclaim/ebs-sandbox-data created
pod/ebs-sandbox created
Step 3/3: wait for the volume to attach and the guest to boot
pod/ebs-sandbox condition met

ebs-sandbox is Ready with its EBS volume mounted at /data.
NAME               STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
ebs-sandbox-data   Bound    pvc-58e3b9fc-a9db-4592-874a-9b7d32fe2b70   10Gi       RWOP           auto-ebs-sc    <unset>                 17s
```

`volumeBindingMode: WaitForFirstConsumer` means the volume is not created until the pod is
scheduled, so the claim stays `Pending` until then and is `Bound` once the pod is Ready.

**Step 3: Prove the pod ran in a sandbox.** The pod's own view is the evidence: its kernel
is the guest's, its uptime matches the pod's age because the VM booted with the pod, and its
disks are virtio where an ordinary pod sees `nvme`.

```bash
kubectl exec ebs-sandbox -n "$NAMESPACE" -- uname -rv
kubectl exec ebs-sandbox -n "$NAMESPACE" -- cat /proc/uptime
kubectl exec ebs-sandbox -n "$NAMESPACE" -- sh -c 'ls /sys/block'
kubectl exec ebs-sandbox -n "$NAMESPACE" -- df -hT /data
```

```text
6.18.51 #1 SMP PREEMPT_DYNAMIC Thu Oct  1 23:28:07 UTC 2026
21.30 19.55
dm-0
vda
vdb
vdc
vdd
Filesystem           Type            Size      Used Available Use% Mounted on
/dev/vdd             ext4            9.7G     28.0K      9.7G   0% /data
```

The kernel is the guest's own build, the uptime (`21.30` seconds) matches the pod's age
because the VM booted with the pod, the disks are virtio (`vda`, `vdb`, ...), and `/data` is
on `/dev/vdd`. Apply [`deploy/pod-ordinary.yaml`](deploy/pod-ordinary.yaml), an ordinary
pod that mounts the same kind of EBS volume, and it shows an `nvme` device instead:

```bash
kubectl apply -f deploy/pod-ordinary.yaml -n "$NAMESPACE"
kubectl wait --for=condition=Ready pod/ordinary-pod -n "$NAMESPACE" --timeout=5m
kubectl exec ordinary-pod -n "$NAMESPACE" -- sh -c 'ls /sys/block'
kubectl exec ordinary-pod -n "$NAMESPACE" -- df -hT /data
```

```text
dm-0
nvme0n1
nvme1n1
nvme2n1
nvme3n1
nvme4n1
zram0
Filesystem           Type            Size      Used Available Use% Mounted on
/dev/nvme4n1         ext4            9.7G     24.0K      9.7G   0% /data
```

The same kind of EBS volume is presented to an ordinary pod as an `nvme` device; the
sandboxed pod sees its own volume passed into the guest as a virtio `/dev/vd*` device.
Remove the comparison pod and its claim when you are done with it, since `clean.sh` does not
own it:

```bash
kubectl delete -f deploy/pod-ordinary.yaml -n "$NAMESPACE"
kubectl delete pvc ordinary-ebs-data -n "$NAMESPACE"
```

**Step 4: A non-root process writes the volume.** The container runs as uid 1000 with
`fsGroup: 2000`. Kubernetes applies the `fsGroup` as the group owner of the mounted volume
and makes it group-writable, so the unprivileged process writes `/data` without root.

```bash
kubectl exec ebs-sandbox -n "$NAMESPACE" -- id
kubectl exec ebs-sandbox -n "$NAMESPACE" -- ls -ld /data
kubectl exec ebs-sandbox -n "$NAMESPACE" -- sh -c 'echo hello > /data/from-non-root && cat /data/from-non-root'
```

```text
uid=1000 gid=1000 groups=1000,2000
drwxrwsr-x    3 root     2000          4096 Oct 20 12:25 /data
hello
```

The mount is group-owned by gid 2000, the `fsGroup`, and group-writable (`drwxrwsr-x`), so
the uid-1000 process writes it without root.

**Step 5: The pod has no network, and still writes its volume.** The pod booted with
`sandbox.amazonaws.com/network-isolated: "true"`, so only loopback has an address and there
is no route out. The EBS data path does not use the pod network, so the volume still mounts
and writes.

```bash
kubectl exec ebs-sandbox -n "$NAMESPACE" -- ip -o addr show
kubectl exec ebs-sandbox -n "$NAMESPACE" -- ip route show default
```

```text
1: lo    inet 127.0.0.1/8 scope host lo
1: lo    inet6 ::1/128 scope host noprefixroute
```

Only `lo` has an address and `ip route show default` prints nothing, yet Step 4 wrote to
`/data`: the storage path and the network are independent.

**Step 6: Data survives the pod.** Delete the pod and let `setup.sh` recreate it. The claim
stays `Bound` with no pod, the replacement binds the same PersistentVolume, and what the
previous pod wrote is still there.

```bash
kubectl exec ebs-sandbox -n "$NAMESPACE" -- sh -c 'echo "marker $(date -u)" >> /data/boot-log.txt'
kubectl delete pod ebs-sandbox -n "$NAMESPACE"
kubectl get pvc ebs-sandbox-data -n "$NAMESPACE"
./scripts/setup.sh
kubectl exec ebs-sandbox -n "$NAMESPACE" -- cat /data/boot-log.txt
```

```text
pod "ebs-sandbox" deleted from nitro-ebs-sample namespace
NAME               STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
ebs-sandbox-data   Bound    pvc-58e3b9fc-a9db-4592-874a-9b7d32fe2b70   10Gi       RWOP           auto-ebs-sc    <unset>                 8m44s
...
booted 2026-10-20T12:25:42Z as uid 1000
booted 2026-10-20T12:33:22Z as uid 1000
marker Tue Oct 20 12:33:38 UTC 2026
booted 2026-10-20T12:34:53Z as uid 1000
```

The PVC stayed `Bound` while no pod existed, the replacement bound the same
PersistentVolume, and `/data` still holds the lines earlier guests wrote, including the
marker: the data outlived the guest that wrote it. (The `setup.sh` output between the two is
omitted here; it is the same as Step 2.)

**Step 7: One pod at a time.** The claim is `ReadWriteOncePod`, so while `ebs-sandbox` holds
it a second pod claiming the same volume stays `Pending`. Apply
[`deploy/pod-ebs-second.yaml`](deploy/pod-ebs-second.yaml), which claims `ebs-sandbox-data`.

```bash
kubectl apply -f deploy/pod-ebs-second.yaml -n "$NAMESPACE"
kubectl get pod ebs-sandbox-second -n "$NAMESPACE"
kubectl get pod ebs-sandbox-second -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}{"\n"}'
kubectl delete pod ebs-sandbox-second -n "$NAMESPACE"
```

```text
NAME                 READY   STATUS    RESTARTS   AGE
ebs-sandbox-second   0/1     Pending   0          14s
0/11 nodes are available: 1 Insufficient cpu, 2 node(s) unavailable due to PersistentVolumeClaim with ReadWriteOncePod access mode already in-use by another pod, 3 node(s) had untolerated taint(s), 5 node(s) didn't match Pod's node affinity/selector. preemption: 0/11 nodes are available: 3 No preemption victims found for incoming pod, 8 Preemption is not helpful for scheduling.
```

The second pod stays `Pending`: `ReadWriteOncePod` restricts the volume to one pod
cluster-wide, which is the constraint a single-attach block device needs. `ReadWriteOnce`
would restrict it only to one node, letting two pods on that node both claim it, so this
sample uses `ReadWriteOncePod` for every claim.

**Step 8: Read the volume back from EC2.** `encrypted: "true"` in the StorageClass is a
request. Read the answer back off the EC2 volume so the gp3-and-encrypted claim is checked
against AWS, not against the class that asked for it.

```bash
VOL=$(kubectl get pv "$(kubectl get pvc ebs-sandbox-data -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')" \
  -o jsonpath='{.spec.csi.volumeHandle}')
aws ec2 describe-volumes --volume-ids "$VOL" --region "$AWS_REGION" \
  --query 'Volumes[0].{VolumeType:VolumeType,Encrypted:Encrypted}' --output table
```

```text
-----------------------------
|      DescribeVolumes      |
+------------+--------------+
|  Encrypted | VolumeType   |
+------------+--------------+
|  True      |  gp3         |
+------------+--------------+
```

AWS reports the volume as `gp3` and `Encrypted: True`: the StorageClass request reached the
volume.

**Step 9: Per-replica volumes with a StatefulSet.** A bare pod is not recreated when its
node is removed, so anything expected to survive node churn uses a controller.
[`deploy/statefulset-ebs.yaml`](deploy/statefulset-ebs.yaml) runs two `isolated-sandbox`
replicas, each with its own volume through `volumeClaimTemplates`, which is what EBS under a
sandbox requires: a block device attaches to exactly one guest, so replicas cannot share one
claim.

```yaml
  volumeClaimTemplates:
    - metadata:
        name: data
        labels:
          app: ebs-sandbox-set
      spec:
        accessModes:
          - ReadWriteOncePod
        storageClassName: auto-ebs-sc
        resources:
          requests:
            storage: 10Gi
```

```bash
kubectl apply -f deploy/statefulset-ebs.yaml -n "$NAMESPACE"
kubectl rollout status statefulset/ebs-sandbox-set -n "$NAMESPACE" --timeout=10m
kubectl logs ebs-sandbox-set-0 -n "$NAMESPACE"
kubectl delete pod ebs-sandbox-set-0 -n "$NAMESPACE"
kubectl rollout status statefulset/ebs-sandbox-set -n "$NAMESPACE" --timeout=10m
kubectl logs ebs-sandbox-set-0 -n "$NAMESPACE"
```

```text
service/ebs-sandbox-set created
statefulset.apps/ebs-sandbox-set created
partitioned roll out complete: 2 new pods have been updated...
--- /data/boot-log.txt ---
booted 2026-10-20T12:35:47Z as ebs-sandbox-set-0
--- device backing /data ---
Filesystem           Type            Size      Used Available Use% Mounted on
/dev/vdd             ext4            9.7G     28.0K      9.7G   0% /data
pod "ebs-sandbox-set-0" deleted from nitro-ebs-sample namespace
partitioned roll out complete: 2 new pods have been updated...
--- /data/boot-log.txt ---
booted 2026-10-20T12:35:47Z as ebs-sandbox-set-0
booted 2026-10-20T12:36:45Z as ebs-sandbox-set-0
--- device backing /data ---
Filesystem           Type            Size      Used Available Use% Mounted on
/dev/vdd             ext4            9.7G     28.0K      9.7G   0% /data
```

Each replica has its own claim, `data-ebs-sandbox-set-0` and `data-ebs-sandbox-set-1`.
Deleting `ebs-sandbox-set-0` brings it back on the same volume, and its boot log gains a
second line: the per-replica data outlived the pod too.

## Good to know

- **A StorageClass is cluster-wide; this one is not the default.**
  [`deploy/storage-class.yaml`](deploy/storage-class.yaml) carries no
  `storageclass.kubernetes.io/is-default-class` annotation, so applying it does not change
  what other workloads provision through. Every claim in this sample names
  `storageClassName: auto-ebs-sc` explicitly, so it binds whether or not the cluster has a
  default. If you want a default class, set one yourself, deliberately and once.
- **`ReadWriteOncePod`, not `ReadWriteOnce`.** `ReadWriteOnce` restricts a volume to one
  node, so two pods on that node could both claim it, which a single-attach block device
  cannot honour. `ReadWriteOncePod` restricts it to one pod cluster-wide. For data several
  pods read and write at once, use the EFS or S3 Files sample in this section.
- **Mount a claim into exactly one container per pod.** Neither access mode restricts two
  containers in the same pod. Share data between containers with an `emptyDir` instead.
- **A volume cannot be expanded while the pod runs.** `auto-ebs-sc` sets the default
  `allowVolumeExpansion: false`. To test expansion, set it to `true` in the class before you
  provision the volumes.
- **Deleting a StatefulSet leaves its claims.** The default
  `persistentVolumeClaimRetentionPolicy` is `Retain`, so the per-replica claims, and their
  EBS volumes, outlive the StatefulSet until deleted. The clean up removes them.
- **Workloads in a sandbox get no IAM credentials from the metadata service.** Use EKS Pod
  Identity if a workload talks to S3 or another AWS service alongside its EBS volume.

## Clean up

The commands use the variables from the walkthrough. In a new shell, set them again first,
with the values you used (these are the shared defaults from the home page):

```bash
export AWS_REGION=us-west-2 NAMESPACE=nitro-ebs-sample
```

[`scripts/clean.sh`](scripts/clean.sh) deletes the pods, the StatefulSet and its headless
Service, and every PVC this sample creates, which deletes the EBS volume each one holds. It
reads each volume's ID before deleting the claim and then confirms with EC2 that the volume
is gone, and it exits non-zero if anything could not be deleted or confirmed.

```bash
NAMESPACE="$NAMESPACE" ./scripts/clean.sh
```

```text
Deleting pods...
pod "ebs-sandbox" deleted from nitro-ebs-sample namespace
Deleting the StatefulSet and its headless Service (a no-op unless applied)...
statefulset.apps "ebs-sandbox-set" deleted from nitro-ebs-sample namespace
service "ebs-sandbox-set" deleted from nitro-ebs-sample namespace
pod "ebs-sandbox-set-0" deleted from nitro-ebs-sample namespace
pod "ebs-sandbox-set-1" deleted from nitro-ebs-sample namespace
Deleting the single-pod claim (this deletes its EBS volume)...
persistentvolumeclaim "ebs-sandbox-data" deleted from nitro-ebs-sample namespace
Deleting any data-ebs-sandbox-set-* per-replica claims (one EBS volume each)...
persistentvolumeclaim "data-ebs-sandbox-set-0" deleted from nitro-ebs-sample namespace
persistentvolumeclaim "data-ebs-sandbox-set-1" deleted from nitro-ebs-sample namespace
Confirming the EBS volumes are gone (waiting up to 180s for the CSI driver to delete them)...
  ebs-sandbox-data: volume vol-0d1bd4697270611d2 is gone.
  data-ebs-sandbox-set-0: volume vol-09e05571aa5b6bbaa is gone.
  data-ebs-sandbox-set-1: volume vol-0276354d3de4d8148 is gone.
Left the StorageClass in place (cluster-wide and shared). To remove it, see the page's clean up.

Clean up complete: every pod, the StatefulSet, the Service and every PVC this sample created are gone, and their EBS volumes are confirmed deleted.
```

The StorageClass stays, because it is cluster-wide and shared. Remove it only if nothing
else on the cluster uses it, and only if you created it for this sample:

```bash
kubectl delete storageclass auto-ebs-sc
```

If this is the last sample you ran, follow the
[hello sandbox](../../getting-started/hello-sandbox/README.md#clean-up) clean up to remove
the namespace and the cluster.
