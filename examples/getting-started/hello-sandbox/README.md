# Hello sandbox

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page. Run the commands below from this folder.

The fastest path is EKS Auto Mode: the runtime classes are present on every cluster, and
Auto Mode provisions sandbox-capable nodes on demand. On standard EKS with your own node
groups or Karpenter, the same pod specs work once your nodes run a sandbox-enabled AMI;
see *Building your AMI for Nitro Sandboxes* in the user guide.

**Step 1: Create an Auto Mode cluster.** This takes about 15 minutes.

```bash
eksctl create cluster --name $CLUSTER_NAME --version 1.36 --region $AWS_REGION --enable-auto-mode
```

**Step 2: Confirm the runtime classes are there.** Nothing to install:

```bash
kubectl get runtimeclass
```

```text
NAME                   HANDLER                AGE
confidential-sandbox   confidential-sandbox   5m
isolated-sandbox       isolated-sandbox       5m
```

Create a namespace for everything that follows and make it your default, so the commands
below match the post's:

```bash
kubectl create namespace $NAMESPACE
kubectl config set-context --current --namespace=$NAMESPACE
```

**Step 3: Start by creating a regular (non-sandboxed) pod.** [`hello-default.yaml`](hello-default.yaml)
is an regular pod without node selector, toleration or sidecar.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hello-sandbox
spec:
  containers:
    - name: hello
      image: public.ecr.aws/docker/library/alpine:3.20
      command: ["sh", "-c"]
      args:
        - |
          echo "kernel:  $(uname -r)"
          echo "disks:   $(ls /sys/block | tr '\n' ' ')"
          sleep infinity
      resources:
        requests: { cpu: "1", memory: 768Mi }
        limits:   { cpu: "1", memory: 768Mi }
```

```bash
kubectl apply -f hello-default.yaml
kubectl wait pod/hello-default --for=condition=Ready --timeout=300s
```

**Step 4: Run your first sandboxed pod.** [`hello-sandbox.yaml`](hello-sandbox.yaml)
is the same regular pod from the last step, with one extra line. There is no node selector, toleration or sidecar;
the RuntimeClass carries the scheduling constraints, and Auto Mode brings up a
sandbox-capable node if none is available.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hello-sandbox
spec:
  runtimeClassName: isolated-sandbox   # <-- the only change
  containers:
    - name: hello
      image: public.ecr.aws/docker/library/alpine:3.20
      command: ["sh", "-c"]
      args:
        - |
          echo "kernel:  $(uname -r)"
          echo "disks:   $(ls /sys/block | tr '\n' ' ')"
          sleep infinity
      resources:
        requests: { cpu: "1", memory: 768Mi }
        limits:   { cpu: "1", memory: 768Mi }
```

```bash
kubectl apply -f hello-sandbox.yaml
kubectl wait pod/hello-sandbox --for=condition=Ready --timeout=300s
```

**Step 5: Prove it landed in a VM (sandbox).** The pod's own logs are the evidence:

```bash
kubectl logs hello-sandbox
kubectl exec hello-sandbox -- uname -r
kubectl exec hello-sandbox -- cat /sys/class/dmi/id/product_name
kubectl exec hello-sandbox -- grep -i vmmcall /proc/cpuinfo
```

```text
kernel:  6.18.48
disks:   dm-0 vda vdb vdc
6.18.48
m8a.enclave
flags           : fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush mmx fxsr sse sse2 syscall nx mmxext fxsr_opt pdpe1gb rdtscp lm constant_tsc rep_good nopl xtopology nonstop_tsc cpuid extd_apicid tsc_known_freq pni pclmulqdq ssse3 fma cx16 pcid sse4_1 sse4_2 x2apic movbe popcnt aes xsave avx f16c rdrand hypervisor lahf_lm cr8_legacy abm sse4a misalignsse 3dnowprefetch topoext ssbd ibrs ibpb stibp ibrs_enhanced vmmcall fsgsbase tsc_adjust bmi1 avx2 smep bmi2 erms invpcid avx512f avx512dq adx smap avx512ifma clflushopt clwb avx512cd sha_ni avx512bw avx512vl xsaveopt xsavec xgetbv1 xsaves avx_vnni avx512_bf16 clzero xsaveerptr wbnoinvd arat avx512vbmi pku ospke avx512_vbmi2 gfni vaes vpclmulqdq avx512_vnni avx512_bitalg avx512_vpopcntdq rdpid movdiri movdir64b fsrm avx512_vp2intersect flush_l1d
```

Compare the outputs with the `default` pod.

```bash
kubectl logs hello-default
kubectl exec hello-default -- uname -r
kubectl exec hello-default -- cat /sys/class/dmi/id/product_name
kubectl exec hello-default -- grep -i vmmcall /proc/cpuinfo
```

```text
kernel:  6.18.48
disks:   dm-0 vda vdb vdc
6.18.48
c6i.large                           # Standard instance type
command terminated with exit code 1 # Doesn't have vmmcall, share the host kernel via namespaces, so they cannot invoke hypervisor calls
```

Your kernel version may differ. The disk list is what shows you are in a VM: the
guest sees virtio block devices (`vda`, `vdb`, and so on) where a regular pod on the same
node sees the instance's `nvme0n1`. The kernel is the VM's own, even when its version
string matches the node's. `exec` works as it does for any pod.

The first sandboxed pod on a new cluster waits for Auto Mode to launch a node. After that,
a new sandboxed pod is Ready in about 5 to 6 seconds, most of it EC2 creating the
partition.

One more check: the VM booted with the pod, so its uptime (in seconds) matches the pod's
age, while a regular pod reports the uptime of the node it runs on.

```bash
kubectl exec hello-sandbox -- cat /proc/uptime
kubectl get pod hello-sandbox
```

```text
813.86 810.50
NAME            READY   STATUS    RESTARTS   AGE
hello-sandbox   1/1     Running   0          13m
```

A regular pod started on the same cluster at the same time reported `59191.99`, about
16 hours: the node's uptime.

**Optional: no network besides loopback.** [`hello-network-isolated.yaml`](hello-network-isolated.yaml)
is the same pod with one annotation, and prints its IPv4 addresses and default route:

```yaml
metadata:
  name: hello-network-isolated
  annotations:
    sandbox.amazonaws.com/network-isolated: "true"   # <-- boot the VM with no network besides loopback
```

```bash
kubectl apply -f hello-network-isolated.yaml
kubectl wait pod/hello-network-isolated --for=condition=Ready --timeout=300s
kubectl logs hello-network-isolated
```

```text
kernel:  6.18.48
ipv4:    lo=127.0.0.1/8
route:   none
```

Only loopback has an address, and there is no route out. Remove the annotation and the
same pod gets an `eth0` with a VPC address, a default route, and the in-guest endpoints
that serve instance metadata and Pod Identity credentials. `kubectl exec` still works on
the network-isolated pod:

```bash
kubectl exec hello-network-isolated -- wget -T 5 -O /dev/null https://aws.amazon.com
```

```text
wget: bad address 'aws.amazon.com'
command terminated with exit code 1
```

## Clean up

Delete the pods from this sample:

```bash
kubectl delete -f hello-sandbox.yaml --ignore-not-found
kubectl delete -f hello-network-isolated.yaml --ignore-not-found
```

If this is the only sample you ran, remove the namespace and the cluster. Set the
variables again first in a new shell, with the values you used:

```bash
export CLUSTER_NAME=sandbox-demo AWS_REGION=us-west-2 NAMESPACE=nitro-sandboxes-demo
kubectl config set-context --current --namespace=default
kubectl delete namespace $NAMESPACE
eksctl delete cluster --name $CLUSTER_NAME --region $AWS_REGION
```

If you ran the coding agent sample, follow its clean up first: deleting the cluster also
removes the network policy setting that sample enables.
