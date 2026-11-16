# Build an AL2023 AMI for EKS Pod Isolation and run it with Karpenter or a node group

Build a custom Amazon Linux 2023 node AMI for Amazon EKS Pod Isolation with the upstream
`amazon-eks-ami` Packer flow, add it to an **existing standard (non-Auto-Mode) cluster** two
ways, with **Karpenter** and with a **managed node group**, and run a hello-world pod in a
Nitro sandbox on the result. AL2023 is the **node operating system**; application containers
use their own images.

This blueprint serves readers who run a standard cluster and manage their own node AMI, rather
than relying on the managed AMI that [Getting started](../../getting-started/hello-sandbox/README.md)
uses (EKS Auto Mode provisions sandbox-capable nodes with no AMI build). It adds compute to a
cluster you already have; it never creates or reconfigures the cluster.

```mermaid
flowchart TB
  A["EKS-optimized AL2023 base AMI (kernel 6.18.51+)"] --> B["Packer: make os_distro=al2023 enable_pod_isolation=true"]
  B --> C["AL2023 -pod-isolation AMI (runtime, guest image, Firecracker, NodeConfig label)"]
  C --> D["Managed node group (launch template: EnclaveOptions.Enabled=true)"]
  C --> E["Karpenter EC2NodeClass (enclaveOptions.enabled: true)"]
  D --> F["isolated-sandbox pod in a Nitro guest VM"]
  E --> F
```

*Figure 1: The same AL2023 Nitro Sandbox AMI feeds two node consumers. The upstream amazon-eks-ami Packer build produces an AL2023 -pod-isolation AMI with kernel 6.18.51+. Both a managed node group (via launch template with EnclaveOptions.Enabled=true) and a Karpenter EC2NodeClass (via enclaveOptions.enabled: true) consume this AMI to provision EKS nodes labelled eks.amazonaws.com/nitro-sandbox=true. The resulting node runs an isolated-sandbox pod inside a Nitro sandbox, which is a lightweight VM with its own guest kernel and virtio disks nested within the EKS node.*

![Architecture diagram showing the upstream amazon-eks-ami Packer build on the left producing an AL2023 -pod-isolation AMI with kernel 6.18.51+. The AMI feeds two consumers inside the AWS Cloud frame: a managed node group with launch template at the top, and a Karpenter EC2NodeClass at the bottom. Both enable Nitro via the enclave option and produce an EKS node labelled eks.amazonaws.com/nitro-sandbox=true. Inside the EKS cluster frame, the EKS node (EC2 instance) contains a Nitro sandbox frame, which contains a Nitro sandbox pod box with runtimeClassName: isolated-sandbox and two container icons inside.](images/architecture.png)

## Prerequisites and clone

The [shared prerequisites](../../README.md#prerequisites) (an AWS account, the AWS CLI,
`kubectl`, Git), plus:

- **A standard (non-Auto-Mode) EKS cluster**, Kubernetes 1.36 or 1.37, with the managed
  `vpc-cni` add-on `ACTIVE` and the `isolated-sandbox` and `confidential-sandbox` RuntimeClass
  objects installed. Auto Mode already ships sandbox support, so this blueprint is for the
  standard-cluster case. See the Amazon EKS User Guide, *Create and update a Nitro Sandbox AMI*.
- **An enclave-capable build instance type** (for example `m8i.4xlarge`). The build must run
  with Nitro Enclaves enabled; on `amazon-eks-ami` v20261112 and later the Packer template sets
  that on the builder for you when `enable_pod_isolation=true`, so an enclave-capable
  `instance_type` is enough. The Makefile default (`m5.xlarge`/`m6g.xlarge`) is not
  enclave-capable, so pass one.
- [`eksctl`](https://eksctl.io/), [`packer`](https://developer.hashicorp.com/packer), `git`,
  `jq`, and (for the Karpenter path) [`helm`](https://helm.sh/).

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/setup/al2023-ami
cp config.env.example config.env
# Set CLUSTER_NAME, AWS_REGION, KUBE_CONTEXT, KUBERNETES_VERSION, EKS_AMI_REF,
# BUILD_SUBNET_ID / NODE_SUBNET_IDS (PRIVATE subnets), and JOIN_MODE.
$EDITOR config.env
```

Cost beyond the cluster: one short-lived enclave-capable build instance, the AMI and its
snapshot, and the node-group / Karpenter node instances for the duration of a run. No model
tokens or API credit.

## Overview

- **The AMI is built by the upstream flow, not by this blueprint.** `make os_distro=al2023
  enable_pod_isolation=true` installs the Nitro Sandboxes runtime and guest image from the
  public EKS S3 bundle (unsigned fetch, no instance profile), Firecracker ≥ v1.18.0, asserts
  the AL2023 kernel is ≥ 6.18.51, reserves the enclave memory pool, registers the
  `isolated-sandbox` and `confidential-sandbox` containerd handlers and the CRI proxy, and
  labels the node `eks.amazonaws.com/nitro-sandbox=true`. The AMI name gets a `-pod-isolation`
  suffix.
- **The same AMI, two consumers.** A managed node group (launch template with
  `EnclaveOptions.Enabled=true`) and a Karpenter `EC2NodeClass`
  (`spec.enclaveOptions.enabled: true`) each produce a node labelled
  `eks.amazonaws.com/nitro-sandbox=true`. Both enable Nitro the same way, via the enclave option
  on the launch template.
- **The limit this blueprint enforces is the Nitro Sandbox VM boundary** and IMDSv2 with a hop
  limit of 1 on every node it launches (so an ordinary pod cannot read the node role's
  credentials from the metadata service). The hello-world pod boots with
  `sandbox.amazonaws.com/network-isolated: "true"`, so it has no network at all. This blueprint
  ships no network policy; to restrict where a sandbox pod can connect, see the
  [network policy](../../isolation/network-policy/README.md) blueprint. It gives the pod no AWS
  permissions and creates no Pod Identity association.

## Architecture: x86_64 and arm64

The upstream build supports both **x86_64** and **arm64 (Graviton)**. The pod-isolation
provisioner keys on `uname -m` and fetches the matching runtime and guest image from the EKS S3
bundle (`.../linux/amd64/...` or `.../linux/arm64/...`), so **the AMI's architecture follows the
instance the Packer build runs on**: build on an x86_64 enclave instance for an x86_64 AMI, on a
Graviton enclave instance for an arm64 AMI. There is no separate build flag.

This blueprint defaults to **x86_64** (`NODE_ARCH=amd64`, `m8i` instance types), and the
walkthrough output below is from an x86_64 run. To run **arm64**, set in `config.env`:

- `NODE_ARCH=arm64`.

The build and node instance types then default to `m8g` (Graviton, enclave-capable), and a type
of the other architecture is refused. The AMI is built on the Graviton builder. The managed node
group follows `NODE_INSTANCE_TYPE`;
the Karpenter `NodePool`'s `kubernetes.io/arch` requirement is rendered from `NODE_ARCH`, and its
`amiSelectorTerms` must point at the arm64 AMI. Everything else is identical.

### arm64 run

The arm64 path was run end to end on a Graviton builder (`m8g.4xlarge`) and node (`m8g.xlarge`).
The build produced an `arm64` AMI, the node joined with the sandbox capacity, and an
`isolated-sandbox` pod reached `Running` with its own guest kernel — the same evidence the x86_64
walkthrough below shows, on `aarch64`:

```text
$ kubectl get nodes -o wide
NAME                       STATUS   VERSION               OS-IMAGE                        KERNEL-VERSION                             ARCH
ip-10-0-0-1.ec2.internal   Ready    v1.37.1-eks-9adbfea   Amazon Linux 2023.12.20261112   6.18.62-127.179.amzn2023.aarch64           arm64

$ kubectl get node ip-10-0-0-1.ec2.internal \
    -o jsonpath='{.status.allocatable.eks\.amazonaws\.com/nitro-sandbox}'
20

# isolated-sandbox pod (guest VM)             # ordinary pod (host)
$ uname -r && uname -m                         $ uname -r && uname -m
6.18.56                                        6.18.62-127.179.amzn2023.aarch64
aarch64                                        aarch64

$ ls /sys/block                                $ ls /sys/block
vda  vdb  vdc   (virtio)                        nvme0n1  loop0..  (host NVMe)
```

As on x86_64, the isolated pod boots its own guest kernel (`6.18.56`) distinct from the host
(`6.18.62-127.179.amzn2023.aarch64`) and gets virtio disks rather than the node's NVMe. (Captured
from a live arm64 run on a standard EKS 1.37 cluster; those arm64 resources were then torn down.)

## Files

| File | What it is |
|---|---|
| [`setup.sh`](setup.sh) | Build the AMI, join (node group / Karpenter / both), run the pods |
| [`test.sh`](test.sh) | Read live node and guest evidence |
| [`clean.sh`](clean.sh) | Remove everything a run created, and only that |
| [`scripts/10-build-ami-packer.sh`](scripts/10-build-ami-packer.sh) | Drive the upstream Packer build |
| [`scripts/join-nodegroup.sh`](scripts/join-nodegroup.sh) | Launch template + managed node group |
| [`scripts/join-karpenter.sh`](scripts/join-karpenter.sh) | Apply the EC2NodeClass / NodePool |
| `deploy/` | The launch-template MIME user data, Karpenter manifests, and the two pods |

## Versions

| Component | Pin |
|---|---|
| `amazon-eks-ami` ([repo](https://github.com/awslabs/amazon-eks-ami)) | a tag ≥ `v20261112` (pod isolation) |
| Kubernetes / EKS | 1.36 or 1.37 |
| AL2023 kernel | `kernel6.18 >= 1:6.18.51` (asserted by the build) |
| Firecracker ([releases](https://github.com/firecracker-microvm/firecracker/releases)) | ≥ `v1.18.0` |
| Karpenter ([docs](https://karpenter.sh/)) | ≥ `v1.15.2` (v1 API + NodeOverlay; see the Karpenter section) |

## Step 1: Build the AL2023 Nitro Sandbox AMI

`scripts/10-build-ami-packer.sh` clones `amazon-eks-ami` at `EKS_AMI_REF` and runs the upstream
build on an enclave-capable instance. It does not reimplement the install; `enable_pod_isolation=true`
does the work.

```bash
./setup.sh --ami-only     # build and tag the AMI; no cluster change
```

```text
Note: this walkthrough reused a pre-built AMI (built earlier with `./setup.sh --ami-only`
from amazon-eks-ami v20261115 for EKS 1.37) rather than rebuilding. `<AMI_ID>` is the
`-pod-isolation` image `./setup.sh --ami-only` produced; your build prints its own id.

$ aws ec2 describe-images --region <AWS_REGION> --image-ids <AMI_ID> \
    --query 'Images[0].[ImageId,Name,State]' --output table
-------------------------------------------------------------------
|                         DescribeImages                          |
+-----------------------------------------------------------------+
|  <AMI_ID>                                                       |
|  amazon-eks-al2023-pod-isolation-node-1.37-v20261115            |
|  available                                                      |
+-----------------------------------------------------------------+
```

## Step 2: Join the AMI to the cluster

`./setup.sh` checks the cluster prerequisites (read only), then joins by `JOIN_MODE`.

### Managed node group

A custom AMI forces a launch template, which carries the AL2023 **NodeConfig MIME** user data
([`deploy/nodegroup-user-data.mime.tmpl`](deploy/nodegroup-user-data.mime.tmpl)) and
`EnclaveOptions.Enabled=true` with IMDSv2 hop-limit-1
([`scripts/lib/launch_spec.py`](scripts/lib/launch_spec.py)). The node group lands in **private
subnets** (an EKS node gets no public IP, so a node group in a public subnet never registers).

```text
$ kubectl get nodes
NAME                              STATUS   ROLES    AGE     VERSION
ip-10-0-0-1.ec2.internal          Ready    <none>   6m24s   v1.37.1-eks-9adbfea

$ kubectl get node ip-10-0-0-1.ec2.internal \
    --show-labels | grep eks.amazonaws.com/nitro-sandbox
...,eks.amazonaws.com/nitro-sandbox=true,...

$ kubectl get node ip-10-0-0-1.ec2.internal \
    -o jsonpath='{.status.allocatable.eks\.amazonaws\.com/nitro-sandbox}'
20
```

### Karpenter

See [Karpenter: the enclave node and the #9904 limit](#karpenter-the-enclave-node-and-the-9904-limit)
below for what Karpenter can and cannot do for sandbox pods today.

## Step 3: Run a pod in the sandbox, beside an ordinary pod

`./setup.sh` applies [`deploy/pod-isolated-sandbox.yaml`](deploy/pod-isolated-sandbox.yaml)
(`runtimeClassName: isolated-sandbox`, booted `network-isolated`) and
[`deploy/pod-ordinary.yaml`](deploy/pod-ordinary.yaml) on the same node. The isolated pod runs in
its own Nitro guest VM, so its kernel, boot and disks are the guest's, not the node's:

```text
# isolated-sandbox pod                       # ordinary pod
$ uname -r                                    $ uname -r
6.18.56                                       6.18.62-127.179.amzn2023.x86_64

$ ls /sys/block                               $ ls /sys/block
vda  vdb  vdc   (virtio)                       nvme0n1  loop0..loop7   (host NVMe)
```

The isolated pod reports a **guest kernel** (`6.18.56`) distinct from the node's host kernel
(`6.18.62-127.179.amzn2023.x86_64`), and **virtio** block devices rather than the host's NVMe:
it is a separate VM with its own kernel and virtual disks. (Captured from a live run on a
standard EKS 1.37 cluster; the ordinary pod shares the node kernel.)

Because the isolated pod is booted with `sandbox.amazonaws.com/network-isolated: "true"`, it has
no network besides loopback, no route and no DNS. `./test.sh` reads this back from the running
pod.

```text
$ ./test.sh
== 1/5 the sandbox node is Ready and carries eks.amazonaws.com/nitro-sandbox=true ==
  node: ip-10-0-0-1.ec2.internal  Ready: True
  PASS  the sandbox node is Ready
  PASS  the node carries eks.amazonaws.com/nitro-sandbox=true
== 2/5 the node advertises sandbox capacity ==
  eks.amazonaws.com/nitro-sandbox allocatable: 20
  PASS  allocatable eks.amazonaws.com/nitro-sandbox > 0
== 3/5 the isolated pod runs in a sandbox: its own guest kernel and virtio disks ==
  isolated pod kernel: 6.18.56
  ordinary pod kernel: 6.18.62-127.179.amzn2023.x86_64
  PASS  the isolated pod's kernel differs from the ordinary pod's (its own guest kernel)
  isolated pod /sys/block: dm-0 vda vdb vdc
  PASS  the isolated pod has virtio disks (vd*), not the host's nvme
== 4/5 the isolated pod boots fresh (low uptime) ==
  isolated pod boot uptime (s): 32.61
  PASS  the isolated pod reports a boot uptime (fresh guest boot)
== 5/5 the network-isolated pod has only loopback ==
  interfaces with an address: <none>  routes: <none>
  PASS  the network-isolated pod has no default route

== summary: 7 passed, 0 failed ==
```

## Karpenter: the enclave node and the #9904 limit

Karpenter provisions the **sandbox-capable node** cleanly: the committed
[`deploy/karpenter-ec2nodeclass.yaml`](deploy/karpenter-ec2nodeclass.yaml) sets
`spec.enclaveOptions.enabled: true` (which Karpenter turns into `EnclaveOptions.Enabled=true` on
the launch template it generates and makes it filter to enclave-capable instance types), pinned
to the custom AMI, and [`deploy/karpenter-nodepool.yaml`](deploy/karpenter-nodepool.yaml) selects
it. This requires **Karpenter ≥ v1.15.2** (the v1 `EC2NodeClass`/`NodePool` API; `enclaveOptions`
landed in v1.15.1), installed on a cluster that already has nodes (Karpenter's controller needs a
node to run on).

!!! note "Scheduling a sandbox pod onto a Karpenter node needs more than the node"

    A pod that sets `runtimeClassName: isolated-sandbox` carries a per-pod overhead of
    `eks.amazonaws.com/nitro-sandbox: "1"` from the RuntimeClass. No EC2 instance type advertises
    that resource until a node has booted, so self-managed Karpenter's scheduler reports
    `label eks.amazonaws.com/nitro-sandbox does not have known values` and does not provision a
    node for the pod. This is an open upstream limitation tracked in
    [aws/karpenter-provider-aws#9904](https://github.com/aws/karpenter-provider-aws/issues/9904).

    The forward path is the alpha **NodeOverlay**
    ([`deploy/karpenter-nodeoverlay.yaml`](deploy/karpenter-nodeoverlay.yaml), behind the
    `nodeOverlay` feature gate), which advertises the slot capacity to the scheduler. On the
    versions available while this blueprint was written, applying it (Ready and validated) did not
    yet make a sandbox pod schedulable, so **run sandbox pods via the managed node group**, or on
    EKS Auto Mode, which models this natively. Use Karpenter here to provision the enclave-capable
    nodes; schedule the sandbox pods through the node group until #9904 ships.

## Optional: build with EC2 Image Builder

**Packer is the primary proven path.** This section describes an optional EC2 Image Builder
alternative, which was **authored but not run live** because Image Builder requires the
**parentInstance-from-ASG workaround** to enable Nitro Enclaves on the build instance.

EC2 Image Builder's `CreateInfrastructureConfiguration` and `InstanceConfiguration` APIs have
**no enclave field** (verified against the [EC2 Image Builder API
Reference](https://docs.aws.amazon.com/imagebuilder/latest/APIReference/Welcome.html)). The
**only way** to get an enclave-enabled build instance is the **parentInstance-from-ASG path**: an
Auto Scaling group whose launch template sets `EnclaveOptions.Enabled=true`. This applies to the
**build phase only**; the resulting AMI is enclave-capable when consumed by a node group or
Karpenter `EC2NodeClass` that sets `EnclaveOptions.Enabled=true` on its own launch template.

See:
- [EC2 Image Builder User Guide: Infrastructure
  configuration](https://docs.aws.amazon.com/imagebuilder/latest/userguide/manage-infra-config.html)
- [AWS CLI Command Reference: aws imagebuilder
  create-infrastructure-configuration](https://awscli.amazonaws.com/v2/documentation/api/latest/reference/imagebuilder/create-infrastructure-configuration.html)

The Image Builder configurations are in `deploy/imagebuilder/`:

- **[`component.yaml`](deploy/imagebuilder/component.yaml)**: AWSTOE component that performs the
  same install as the upstream `amazon-eks-ami` `install-pod-isolation.sh` provisioner (fetch and
  verify the runtime and guest image from the public EKS S3 bundle, Firecracker ≥ v1.18.0, assert
  kernel ≥ 1:6.18.51, `nitro_enclaves.mempool`, containerd handlers, CRI proxy, the
  `eks.amazonaws.com/nitro-sandbox` NodeConfig label).
- **[`image-recipe.json`](deploy/imagebuilder/image-recipe.json)**: the EKS-optimized AL2023
  parent image (the driver looks up its AMI id for `NODE_ARCH` in the public SSM parameter) + the
  component.
- **[`infrastructure-config.json`](deploy/imagebuilder/infrastructure-config.json)**:
  `parentInstance.autoScalingGroup` pointing at an enclave-enabled ASG (build phase only), with
  placeholders.
- **[`distribution-config.json`](deploy/imagebuilder/distribution-config.json)**: AMI distribution
  and tagging.

A reference driver script is at
[`scripts/10-build-ami-imagebuilder.sh`](scripts/10-build-ami-imagebuilder.sh). It checks its
inputs, picks the parent image and build instance type for `NODE_ARCH`, substitutes the
placeholders and drives the pipeline via the `aws imagebuilder` CLI. Like the rest of this
section it has **not been run live**:

```bash
# Prerequisites:
# - An Auto Scaling group with EnclaveOptions.Enabled=true on its launch template
# - IAM instance profile, security group, private subnet
# - S3 bucket for build logs

export BUILD_ASG_NAME=<asg-with-enclave-enabled>
export BUILD_INSTANCE_PROFILE=<instance-profile-name>
export BUILD_SECURITY_GROUP_ID=<sg-id>
export BUILD_SUBNET_ID=<private-subnet-id>
export BUILD_S3_BUCKET=<log-bucket>
export KUBERNETES_BUILD_DATE=<build date folder under s3://amazon-eks/<version>/>

RUN_ID=<id> ./scripts/10-build-ami-imagebuilder.sh
```

The script creates the component, recipe, infrastructure configuration, distribution configuration,
and pipeline, then starts an execution. Monitor progress in the EC2 Image Builder console or via:

```bash
aws imagebuilder get-image --image-build-version-arn <execution-arn> --region <region>
```

The resulting AMI is named with a `-pod-isolation` suffix by the distribution configuration, the
same as the Packer path.

## Good to know

- **The build does not enable enclaves on the builder on older refs.** On `amazon-eks-ami`
  before v20261112 the Packer template did not set `EnclaveOptions` on the builder; pin a ref
  ≥ v20261112, or ensure the build instance is enclave-enabled yourself.
- **Nodes must be in private subnets with a NAT route.** A managed node group in a public subnet
  hangs in `CREATING` forever (EKS nodes get no public IP). `scripts/join-nodegroup.sh` fails
  fast if you point it at a public subnet.
- **Supported Kubernetes versions are 1.36 and 1.37**; the build errors on anything else.

## Clean up

```bash
RUN_ID=<id> ./clean.sh --dry-run   # preview
RUN_ID=<id> ./clean.sh             # remove everything this run created
```

`clean.sh` needs `KUBE_CONTEXT` set, like setup. It stops if the AWS account is not the one the run
was created in. It deletes a resource only when it carries this run's mark: the
`app.kubernetes.io/part-of=al2023-ami` and `app.kubernetes.io/instance=<id>` labels on the
namespace, `NodePool` and `EC2NodeClass`, and the `ManagedBy=al2023-ami` and `RunId=<id>` tags on
the node group, launch template, AMI and each of the AMI's snapshots (the build tags the
snapshots too). A resource without the
mark is left alone, and a lookup that fails is reported as "could not determine", never as gone.
Either leaves the clean up incomplete and the script exits non-zero.

The launch template, AMI and snapshot deletes (`ec2 delete-*`, `deregister-image`) are written to
`tmp/al2023-ami/run/out/runs/<id>/teardown-remaining.sh` for you to run, and the script exits
non-zero until you have. It never removes the shared `vpc-cni` add-on, the RuntimeClasses, or
Karpenter itself. See the [hello-sandbox](../../getting-started/hello-sandbox/README.md) clean up for
removing the namespace and the cluster.
