# Hello sandbox

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page. The commands below use files from this repository, so clone it and run
them from this sample's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/getting-started/hello-sandbox
```

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
is a regular pod without node selector, toleration or sidecar.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hello-default
spec:
  containers:
    - name: hello
      image: public.ecr.aws/amazonlinux/amazonlinux:2023
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c"]
      args:
        - |
          echo "/sys/class/dmi/id/product_name:  $(cat /sys/class/dmi/id/product_name)"
          echo "disks:   $(ls /sys/block | tr '\n' ' ')"
          sleep infinity
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
      image: public.ecr.aws/amazonlinux/amazonlinux:2023
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c"]
      args:
        - |
          echo "/sys/class/dmi/id/product_name:  $(cat /sys/class/dmi/id/product_name)"
          echo "disks:   $(ls /sys/block | tr '\n' ' ')"
          sleep infinity
```

```bash
kubectl apply -f hello-sandbox.yaml
kubectl wait pod/hello-sandbox --for=condition=Ready --timeout=300s
```

**Step 5: Prove it landed in a VM (sandbox).** The pod's own logs are the evidence:

```bash
kubectl logs hello-sandbox
```

```text
/sys/class/dmi/id/product_name:  m8i.enclave
disks:   dm-0 vda vdb vdc
```

Compare the output with the `default` pod:

```bash
kubectl logs hello-default
```

```text
/sys/class/dmi/id/product_name:  m8a.xlarge
disks:   dm-0 nvme0n1 nvme1n1 zram0
```

The product name is the machine the pod's own view reports. The sandbox reports its VM,
`m8i.enclave`, while the regular pod reports the EC2 instance it shares with the other pods
on its node, here an `m8a.xlarge`. The disk list says the same: the guest sees virtio block
devices (`vda`, `vdb`, and so on) where a regular pod sees the instance's `nvme` devices.
Your instance types may differ. `exec` works as it does for any pod.

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
23.73 21.39
NAME            READY   STATUS    RESTARTS   AGE
hello-sandbox   1/1     Running   0          27s
```

The `hello-default` pod, started on the same cluster a few seconds earlier, reported
`11413.84`, about 3 hours: the uptime of its node.

These pods set no CPU or memory requests, so the VM gets a small default size. On this run
it had one vCPU and about 130 MiB of memory:

```bash
kubectl exec hello-sandbox -- nproc
kubectl exec hello-sandbox -- grep MemTotal /proc/meminfo
```

```text
1
MemTotal:         132568 kB
```

That is enough for these pods. A real workload sets the CPU and memory requests it needs:
the VM is sized from them, as the [coding agent](../coding-agent/README.md) sample shows.

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
/sys/class/dmi/id/product_name:  m8i.enclave
ipv4:    127.0.0.1
route:   none
```

Only loopback has an address, and there is no route out. Remove the annotation and the
same pod gets an `eth0` with a VPC address, a default route, and the in-guest endpoints
that serve instance metadata and Pod Identity credentials. `kubectl exec` still works on
the network-isolated pod:

```bash
kubectl exec hello-network-isolated -- curl -sS -m 5 -o /dev/null https://aws.amazon.com
```

```text
curl: (6) Could not resolve host: aws.amazon.com
command terminated with exit code 6
```

## Clean up

Delete the pods from this sample:

```bash
kubectl delete -f hello-default.yaml --ignore-not-found
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
