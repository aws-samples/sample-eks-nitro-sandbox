# Pause and resume a sandbox

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run the [hello sandbox](../../getting-started/hello-sandbox/README.md)
sample first so you have a cluster with the runtime classes. This sample uses the
agent-sandbox `Sandbox` API, installed in [warm pool](../../getting-started/warm-pool/README.md)
step 1. The commands below use files from this repository, so clone it if you have not
already, and run them from this sample's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/agent-sandbox/pause-resume
```

An idle agent session costs you no compute if you can throw away its compute and keep its
disk, then bring the session back later with its workspace intact. That is what suspend and
resume do for a sandbox: `operatingMode: Suspended` terminates the pod and its guest, so you
stop paying for the compute, while the controller keeps the `Sandbox` and its EBS volume;
`operatingMode: Running` brings up a new pod on the same volume. The file you wrote before
the suspend is still there, with a new line appended on the new boot, so disk state survived
even though process memory did not.

The workload is a single agent-sandbox [`Sandbox`](https://github.com/kubernetes-sigs/agent-sandbox)
whose pod runs in a Nitro sandbox, with an Amazon EBS workspace from `volumeClaimTemplates`.
It boots network-isolated, so it has no network besides loopback and needs no network
policy, and it still mounts its EBS workspace, which the node-side CSI driver attaches from
outside the guest, before and after the resume.

- **Suspend releases the pod and its compute, and keeps the EBS volume.** The pod goes
  away (`kubectl get pod` reports `NotFound`) while the workspace `PersistentVolumeClaim`
  stays `Bound`. The volume stays provisioned and billed so the workspace can come back:
  that is the trade this sample is about.
- **Resume brings the data back on a new pod.** A new pod, with a new UID, mounts the same
  volume. The earlier line is still in the file, with a new line from this boot.
- **The resumed pod is a fresh sandbox, not the old one woken up.** The three sandbox
  signals read before the suspend and again after the resume: the guest's own kernel build,
  a boot time that matches the new pod's age, and virtio `vd*` disks. This is how the page
  shows the resume booted a new guest, not the same one.

*Figure 1: Pause and resume a sandbox. Suspending the sandbox terminates its pod and guest VM but keeps the EBS workspace volume; resuming brings up a new pod that re-attaches the same volume with its data intact.*

![Inside an AWS Cloud frame and an Amazon EKS cluster, three states run left to right. On the left, a red Nitro sandbox pod frame marked isolated-sandbox plus network-isolated holds an Agent pod for pause-resume guest VM number 1, running. An arrow labelled operatingMode Suspended leads to the middle, a dashed frame marked operatingMode Suspended, pod terminated, you stop paying for the guest, which contains an empty placeholder reading no pod. An arrow labelled operatingMode Running leads to the right, a second red Nitro sandbox pod frame with an Agent pod for pause-resume guest VM number 2 with a new pod UID. Below the three states sits a single Amazon EBS workspace volume, created from volumeClaimTemplates, whose PVC stays Bound. The left pod connects down to it labelled mounts /workspace, and the right pod connects down to the same volume labelled same volume re-attached, data intact, showing that the one volume outlives each pod.](images/figure-1-pause-resume.png)

## Versions

| Component | Pin |
|---|---|
| agent-sandbox controller ([kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)) | v1.0.6, as in [Warm pool](../../getting-started/warm-pool/README.md) |

Nothing else is pinned beyond the image in the manifest
(`public.ecr.aws/docker/library/busybox:1.36`).

## Files

| File | What it is |
|---|---|
| [`deploy/sandbox.yaml`](deploy/sandbox.yaml) | The `Sandbox` with its EBS `volumeClaimTemplates`. Its container appends one line to `/workspace/boots.log` per boot. |
| [`scripts/setup.sh`](scripts/setup.sh) | Create the namespace and the `Sandbox`, and wait for the guest to boot with `/workspace` mounted. |
| [`scripts/suspend.sh`](scripts/suspend.sh) | Suspend the sandbox and show the pod gone and the volume kept. |
| [`scripts/resume.sh`](scripts/resume.sh) | Resume the sandbox and show the workspace back on a new pod. |
| [`scripts/cleanup.sh`](scripts/cleanup.sh) | Delete the `Sandbox`, its PVC, the EBS volume and the namespace. |
| [`.env.example`](.env.example) | The local values the sample needs, with no secrets. |

The scripts read `.env` (copy it from `.env.example`). `NAMESPACE` defaults to
`pause-resume`; set `KUBE_CONTEXT` to the context of the cluster you ran Getting started on,
so a run never depends on the machine's current context.

**Step 1: Install agent-sandbox**, if you have not already from the warm pool sample. This
folder was built against v1.0.6:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.6/sandbox-with-extensions.yaml
kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller
```

**Step 2: Create the Sandbox and wait for the guest.** [`deploy/sandbox.yaml`](deploy/sandbox.yaml)
is one `Sandbox` on `isolated-sandbox`, booted network-isolated, with a 10Gi EBS workspace
from `volumeClaimTemplates`. Its container appends one line to `/workspace/boots.log` on
every boot, so the file is a running record: one line per guest the workspace has been
attached to. Here is the part that matters:

```yaml
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: pause-resume
spec:
  operatingMode: Running          # Running | Suspended
  podTemplate:
    metadata:
      annotations:
        sandbox.amazonaws.com/network-isolated: "true"   # no network besides loopback
        karpenter.sh/do-not-disrupt: "true"              # pin the node while the single-attach volume is mounted
    spec:
      runtimeClassName: isolated-sandbox
      containers:
        - name: workspace
          image: public.ecr.aws/docker/library/busybox:1.36
          command:
            - sh
            - -c
            - |
              mkdir -p /workspace
              echo "boot at $(date -u +%Y-%m-%dT%H:%M:%SZ) on kernel $(uname -r), hostname $(hostname)" >> /workspace/boots.log
              cat /workspace/boots.log
              exec sleep infinity
          volumeMounts:
            - name: workspace
              mountPath: /workspace
          resources:
            requests: { cpu: "1", memory: 768Mi }
            limits:   { cpu: "1", memory: 768Mi }
  volumeClaimTemplates:
    - metadata:
        name: workspace
      spec:
        accessModes: [ReadWriteOncePod]
        storageClassName: auto-ebs-sc
        resources:
          requests:
            storage: 10Gi
```

```bash
./scripts/setup.sh
```

```text
context: sandbox-demo (pinned)   namespace: pause-resume

== 1/3 namespace pause-resume ==
namespace/pause-resume created
namespace/pause-resume labeled
created namespace pause-resume, labelled app.kubernetes.io/managed-by=pause-resume

== 2/3 apply sandbox/pause-resume ==
sandbox.agents.x-k8s.io/pause-resume created

== 3/3 wait for the guest to boot and mount the EBS workspace ==
sandbox.agents.x-k8s.io/pause-resume condition met

sandbox/pause-resume is Running with /workspace mounted.
```

The first sandboxed pod on a cold cluster waits for Auto Mode to launch a node; after that
a new one is Ready in about 5 to 6 seconds.

**Step 3: Record the running guest, and prove it is a sandbox.** Read the boot log, the pod
UID and the PV, then the three signals that show the pod ran in a sandbox of its own. The
context and namespace are pinned, shown here as `kc`:

```bash
alias kc='kubectl --context "$KUBE_CONTEXT" -n pause-resume'   # the context from your .env
kc exec pause-resume -- cat /workspace/boots.log
kc get pod pause-resume -o jsonpath='uid={.metadata.uid}{"\n"}'
kc get pvc workspace-pause-resume
kc exec pause-resume -- uname -rv
kc exec pause-resume -- cat /proc/uptime
kc exec pause-resume -- ls /sys/block
kc exec pause-resume -- sh -c 'awk "\$2==\"/workspace\"{print \$1}" /proc/mounts'
```

```text
boot at 2026-10-20T02:59:43Z on kernel 6.18.51, hostname pause-resume
uid=63aaeb66-3d0d-4a94-b35e-19283400a56a
NAME                     STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
workspace-pause-resume   Bound    pvc-8fd30514-9d0d-4d13-8c5e-18eee71249c2   10Gi       RWOP           auto-ebs-sc    33s
6.18.51 #1 SMP PREEMPT_DYNAMIC Thu Oct  1 23:28:07 UTC 2026
28.60 26.46
dm-0
vda
vdb
vdc
vdd
/dev/vdd
```

One line in the file; one pod UID; the claim `Bound` with access mode `RWOP`
(`ReadWriteOncePod`). The guest runs its own kernel, built for the VM: the version string
here matches the node's (`6.18.51`), but the uptime is the pod's, about 29 seconds, where an
ordinary pod would report the node's uptime, hours or days. The block devices are virtio
`vd*`, and `/workspace` is one of them (`/dev/vdd`), where an ordinary pod would see the
instance's `nvme*` devices. Together they show the containers ran in a VM of their own.

It is network-isolated, so it has no network to restrict and ships no network policy. Only
loopback has an address, there is no route out, and a lookup fails:

```bash
kc exec pause-resume -- ip -4 -o addr show
kc exec pause-resume -- ip route show default
kc exec pause-resume -- wget -T 5 -O /dev/null https://aws.amazon.com
```

```text
1: lo    inet 127.0.0.1/8 scope host lo
wget: bad address 'aws.amazon.com'
command terminated with exit code 1
```

`ip route show default` prints nothing: there is no default route. `kubectl exec` still
works, because it uses the guest's internal control channel, not the network.

**Step 4: Suspend.** `operatingMode: Suspended` tells the controller to delete the pod and
keep the `Sandbox` and its volume. No `sync` is needed first: the platform flushes and
releases the CSI mount before killing the guest.

```bash
./scripts/suspend.sh
```

```text
context: sandbox-demo (pinned)   namespace: pause-resume

== suspend sandbox/pause-resume ==
sandbox.agents.x-k8s.io/pause-resume patched
sandbox.agents.x-k8s.io/pause-resume condition met

The pod is gone (you stop paying for the guest); the EBS volume is kept:
  pod/pause-resume: NotFound (deleted)
  NAME                     STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
  workspace-pause-resume   Bound    pvc-8fd30514-9d0d-4d13-8c5e-18eee71249c2   10Gi       RWOP           auto-ebs-sc    98s
```

The pod is `NotFound`: suspend deleted it, so you stop paying for the guest. The PVC is
still `Bound` on the same PV (`pvc-8fd30514...`), so the EBS volume was not reclaimed. The
`Sandbox` reports why it is not Ready, so a caller can tell "parked on purpose" from
"broken":

```bash
kc get sandbox pause-resume
```

```text
NAME           READY   REASON             AGE
pause-resume   False   SandboxSuspended   100s
```

**Step 5: Resume.** `operatingMode: Running` schedules a new pod that mounts the same
volume.

```bash
./scripts/resume.sh
```

```text
context: sandbox-demo (pinned)   namespace: pause-resume

== resume sandbox/pause-resume ==
sandbox.agents.x-k8s.io/pause-resume patched
sandbox.agents.x-k8s.io/pause-resume condition met

The workspace came back on a new pod, with its history intact:
  boot at 2026-10-20T02:59:43Z on kernel 6.18.51, hostname pause-resume
  boot at 2026-10-20T03:01:27Z on kernel 6.18.51, hostname pause-resume
```

The file has both lines now: the one from before the suspend, and a new one from this
boot. Disk state survived; process memory did not.

**Step 6: Prove the resumed pod is a new sandbox, same volume.** Read the pod UID, the PV
and the three signals again:

```bash
kc get pod pause-resume -o jsonpath='uid={.metadata.uid}{"\n"}'
kc get pvc workspace-pause-resume -o jsonpath='phase={.status.phase}{"\n"}pv={.spec.volumeName}{"\n"}'
kc exec pause-resume -- uname -rv
kc exec pause-resume -- cat /proc/uptime
kc exec pause-resume -- ls /sys/block
kc exec pause-resume -- sh -c 'awk "\$2==\"/workspace\"{print \$1}" /proc/mounts'
```

```text
uid=06a3dd8b-af40-4561-a5cd-adc523eb96fa
phase=Bound
pv=pvc-8fd30514-9d0d-4d13-8c5e-18eee71249c2
6.18.51 #1 SMP PREEMPT_DYNAMIC Thu Oct  1 23:28:07 UTC 2026
17.72 15.96
dm-0
vda
vdb
vdc
vdd
/dev/vdd
```

The pod UID changed (`63aaeb66...` to `06a3dd8b...`): this is a new pod, not the old one
restarted. The PV is the same (`pvc-8fd30514...`), so the workspace was re-attached, not
recreated. The guest kernel build is read again here; the uptime is this pod's, about 18
seconds, so the guest booted with the pod; and the block devices are virtio `vd*` with
`/workspace` on `/dev/vdd`: the thing that re-attached the volume is a new sandbox guest.

## Good to know

- **Suspend preserves data; delete does not.** The PVC carries the `Sandbox` as its
  `ownerReference`, so deleting the `Sandbox` deletes the `PersistentVolumeClaim` and the
  EBS volume behind it. Only suspend keeps the workspace.
- **The EBS volume is billed while suspended.** Suspend releases the pod and its compute,
  so you stop paying for the guest, but the 10Gi EBS volume stays provisioned and billed so
  the workspace can come back. That is the trade.
- **The workspace claim is `ReadWriteOncePod`.** Only one pod may mount the workspace at a
  time. Plain `ReadWriteOnce` promises only one node, so two pods on that node could mount
  the same workspace together, which a per-session workspace must not allow.
- **`volumeClaimTemplates` is immutable after the `Sandbox` is created.** Changing the
  size, class or access mode means deleting and recreating the `Sandbox`, which deletes the
  workspace. `setup.sh` detects a mismatch with an existing `Sandbox` and tells you to run
  the clean up and set up again, rather than letting the apply fail with a message that does
  not mention the workspace it is about to cost.
- **The single-attach volume pins the node.** The pod template sets
  `karpenter.sh/do-not-disrupt: "true"` so the node is not consolidated with the volume
  still attached, which could stall the detach. The controller re-creates the pod on resume,
  so this does not prevent the suspend and resume cycle.

## Clean up

Set the variables again if you are in a new shell, then remove everything the sample
created: the `Sandbox`, its PVC, the EBS volume behind it, and the namespace.

```bash
cp .env.example .env    # if you have not already; set KUBE_CONTEXT and NAMESPACE
./scripts/cleanup.sh
```

```text
context: sandbox-demo (pinned)   namespace: pause-resume

== 1/3 delete sandbox/pause-resume (and, by ownerReference, pvc/workspace-pause-resume + its EBS volume) ==
sandbox.agents.x-k8s.io "pause-resume" deleted from pause-resume namespace
== 2/3 confirm the workspace PVC and its EBS volume are gone ==
persistentvolumeclaim "workspace-pause-resume" deleted from pause-resume namespace
persistentvolume/pvc-8fd30514-9d0d-4d13-8c5e-18eee71249c2 condition met
  pv pvc-8fd30514-9d0d-4d13-8c5e-18eee71249c2: gone
== 3/3 delete namespace pause-resume ==
namespace "pause-resume" deleted
  namespace pause-resume deleted

clean up complete: the Sandbox, its PVC, the EBS volume and the namespace are gone.
```

The clean up deletes a resource only when it carries the sample's label, checks the
namespace label before deleting anything inside it, and exits non-zero if it skipped
something or could not confirm the EBS volume is gone, so an incomplete clean up is never
reported as done.

The agent-sandbox controller is shared with the warm pool sample and other agent-sandbox
samples, so this clean up leaves it installed. To remove it, follow the
[warm pool clean up](../../getting-started/warm-pool/README.md#clean-up). If this is the only
sample you ran, follow the
[hello sandbox clean up](../../getting-started/hello-sandbox/README.md#clean-up) to remove
the cluster.
