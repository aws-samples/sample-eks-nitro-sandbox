# Build a Bottlerocket AMI with Packer and run Nitro sandbox pods on Cilium

Before you start, read the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page. This blueprint creates its own cluster, so you do not need the cluster of
the [hello sandbox](../../getting-started/hello-sandbox/README.md) blueprint. The cluster
design comes from the [Cilium on Ubuntu nodes](../cilium-ubuntu/README.md) blueprint. The
runtime checks come from the [Ubuntu AMI](../ubuntu-ami/README.md) blueprint. The commands
use files from this repository. Clone the repository, and run the commands from the folder
of this blueprint:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/setup/cilium-bottlerocket
```

For this blueprint, you also need these tools on your machine. `setup.sh` examines each
tool before it creates a resource. When a tool is not available, `setup.sh` stops with an
error message that names the tool. It also stops when a tool has a version that is not in
the list.

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) v2.
- [eksctl](https://eksctl.io/installation/) 0.230.0 or later.
- [Helm](https://helm.sh/docs/intro/install/) v3.19.0.
- [kubectl](https://kubernetes.io/docs/tasks/tools/) 1.35, 1.36 or 1.37.
- Python 3 with PyYAML.
- bash 4 or later.
- `curl`, `gpg`, `unzip` and `sha256sum`. `scripts/10-build-ami-packer.sh` uses these tools
  to download Packer 1.16.2 and the Packer plugin for Amazon 1.8.4. It verifies both downloads
  against the signed HashiCorp checksums. It keeps both tools in
  `tmp/cilium-bottlerocket/run/tools/` in the repository.

The AWS account must have these items:

- Short-lived credentials in a named profile, for example through `AWS_PROFILE`. The
  scripts do not read or show the credential values. The [IAM matrix](#iam-matrix) gives
  the actions of each principal.
- Quota for one more VPC, internet gateway, NAT gateway and Elastic IP address in
  `us-west-2`. `setup.sh` examines this quota before it creates a resource. For the NAT
  gateway, it compares all the NAT gateways in the Region with the quota for one zone.
  Because of this, the check can stop a run when the zone has quota.
- EC2 capacity for one `m8i.4xlarge` builder and two `m8i.xlarge` nodes. The sandbox node
  uses Nitro Enclaves.

One run with the default settings and no pause costs about USD 2 at list prices. The
blueprint creates every resource that costs money, and [Cost](#cost) gives the details.

## Overview

This blueprint runs Nitro sandbox pods on Bottlerocket nodes. Bottlerocket has a read-only
root file system and no package manager. Because of this, the build puts the Nitro Sandbox
runtime into the AMI. Packer builds this AMI from a custom
[Bottlerocket](https://github.com/bottlerocket-os/bottlerocket) variant.

The blueprint creates a dedicated Amazon EKS cluster with its own VPC.
[Cilium](https://docs.cilium.io/) is the only CNI of the cluster. Cilium operates in ENI mode
with kube-proxy replacement, as in the Cilium on Ubuntu nodes blueprint. A system node on the
stock Bottlerocket AMI runs the system pods. One sandbox node runs the AMI from the build.

- **Cilium is the only CNI.** The cluster has no `aws-node` and no `kube-proxy`. The Cilium
  operator and CoreDNS run on the system node.
- **Packer builds the sandbox AMI with no SSH access.** The `amazon-ebssurrogate` builder
  uses `communicator = "none"`. AWS Systems Manager Run Command runs the build stages on a
  builder in a private subnet of the cluster VPC.
- **A Bottlerocket variant holds the runtime.** The variant `aws-k8s-1.36-nitro-sandbox` is a
  copy of `aws-k8s-1.36` with one added package, `nitro-sandbox`. The variant also has a
  larger OS image and one more kernel parameter.
- **The sandbox pod gets normal pod networking.** The pod gets a VPC IP address from an ENI
  of its node, and a CiliumEndpoint. The pod connects to another pod, to a ClusterIP Service
  and to the cluster DNS.
- **The workload runs in its own guest.** A pod with `runtimeClassName: isolated-sandbox`
  runs in its own Nitro sandbox. Its containers run in a lightweight VM with its own kernel.
  An ordinary pod on the same node uses the node kernel.
- **Among the pods, only the Cilium operator gets AWS permissions.** Its EKS Pod Identity
  role allows only the EC2 actions that Cilium lists for ENI mode. The workload pods get no
  AWS permissions. Neither node role has the EC2 permissions of Cilium.

*Figure 1: Cilium on Bottlerocket nodes. Packer builds the sandbox AMI in the cluster VPC.
The sandbox node runs this AMI beside a system node on the stock Bottlerocket AMI.*

![The operator machine, with Packer and the AWS CLI, is outside the AWS Cloud frame. Its first arrow, labelled build stages, goes to AWS Systems Manager Run Command. Systems Manager has an arrow, labelled runs each stage, to the builder instance in a private subnet with no SSH. The builder instance has an arrow, labelled two EBS snapshots, to the sandbox AMI, which is a Bottlerocket variant. The sandbox AMI has an arrow, labelled launch template, to the Bottlerocket sandbox node. The second arrow of the operator machine, labelled eksctl and Helm, goes to the Amazon EKS cluster frame. The cluster uses the Cilium CNI in ENI mode with kube-proxy replacement. In the cluster, the Bottlerocket system node uses the stock aws-k8s-1.36 AMI. It holds the Cilium operator for ENI IPAM, the Pod Identity role with the Cilium ENI actions, and CoreDNS behind a ClusterIP Service. The Pod Identity role has an arrow, labelled creates and attaches ENIs, to the Amazon EC2 ENI API. The Bottlerocket sandbox node uses the custom AMI and has a taint. It holds a Nitro sandbox pod with runtimeClassName isolated-sandbox, and an ordinary pod on the same node with the node kernel. In the Nitro sandbox pod, the sandbox workload has its own guest kernel and a VPC address, which is an ENI secondary IP address. A two-way arrow, labelled DNS and ClusterIP Service, connects the Nitro sandbox pod and CoreDNS.](images/architecture.png)

This folder uses these releases:

| Component | Version |
|---|---|
| Amazon EKS Kubernetes ([versions](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)) | 1.36 |
| Bottlerocket ([releases](https://github.com/bottlerocket-os/bottlerocket/releases)) | v1.70.0, commit `59b0684a040705cebc4af1658f5e16a0c528e73f`. The system node uses the variant `aws-k8s-1.36`. The sandbox node uses the variant `aws-k8s-1.36-nitro-sandbox`. |
| Twoliter ([releases](https://github.com/bottlerocket-os/twoliter/releases)) | v0.27.0, the version that `Makefile.toml` of Bottlerocket v1.70.0 sets |
| Bottlerocket SDK and kits | SDK 0.83.0, kernel-kit 9.8.0 and core-kit 18.1.0, from `Twoliter.toml` of Bottlerocket v1.70.0 |
| Host kernel and containerd | Kernel 6.18.62 from kernel-kit 9.8.0, and containerd 2.3.7 from core-kit 18.1.0 |
| Nitro Sandbox runtime ([Download and verify the runtime binaries](https://docs.aws.amazon.com/eks/latest/userguide/sandboxing-download-binaries.html)) | 0.1.4274.0 |
| Guest image ([Create and update a Nitro Sandbox AMI](https://docs.aws.amazon.com/eks/latest/userguide/sandboxing-ami-create-update.html)) | 1.36.5/2026-11-06, with the EIF and the disk image as one matched pair |
| Firecracker and jailer ([releases](https://github.com/firecracker-microvm/firecracker/releases)) | v1.18.0 |
| Cilium Helm chart ([releases](https://github.com/cilium/cilium/releases)) | 1.20.5 |
| eksctl ([releases](https://github.com/eksctl-io/eksctl/releases)) | 0.230.0 or later |
| Helm client ([releases](https://github.com/helm/helm/releases)) | v3.19.0 |
| Packer ([releases](https://github.com/hashicorp/packer/releases)) | 1.16.2 |
| Packer plugin for Amazon ([releases](https://github.com/hashicorp/packer-plugin-amazon/releases)) | 1.8.4 |
| rustup, Rust toolchain and cargo-make, on the builder | rustup 1.29.3, Rust 1.100.0 and cargo-make 0.37.24 |
| Builder AMI | Amazon Linux 2023 x86_64, from the public SSM parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`. Each run records the AMI ID. |
| System node AMI | The stock Bottlerocket `aws-k8s-1.36` v1.70.0 AMI, from the public SSM parameter `/aws/service/bottlerocket/aws-k8s-1.36/x86_64/1.70.0/image_id`. `setup.sh` records the AMI ID. |

Lock files hold the pins. [`packer/tools.lock`](packer/tools.lock) holds the versions and the
digests of the build tools. [`packages/sources.lock`](packages/sources.lock) holds the
Bottlerocket source and the runtime inputs, each with its digest.
[`cilium.lock`](cilium.lock) holds the Cilium version. The scripts read the Cilium version
from `cilium.lock` only. The Cilium version on this page is the value in `cilium.lock`.

The files:

| File | What it is |
|---|---|
| [`config.env.example`](config.env.example) | The settings, with placeholders and shared defaults only. Copy it to `config.local.env`, which git ignores. |
| [`setup.sh`](setup.sh) | Creates the cluster, installs Cilium, builds the AMI, adds the node groups and examines each node |
| [`test.sh`](test.sh) | Examines the nodes, the pod network and the guest boundary. It starts probe pods and filler pods, and deletes each one by its exact name. |
| [`clean.sh`](clean.sh) | Lists and deletes the resources of one run, and examines each resource again after the deletes |
| [`cilium.lock`](cilium.lock) | The Cilium chart and version |
| [`cilium-values.yaml`](cilium-values.yaml) | The Helm values of Cilium |
| [`eksctl/cluster.yaml`](eksctl/cluster.yaml) | The cluster and its add-ons |
| [`eksctl/pod-identity.yaml`](eksctl/pod-identity.yaml) | The Pod Identity role of the Cilium operator |
| [`eksctl/nodegroups.yaml`](eksctl/nodegroups.yaml) | The system node group and the sandbox node group |
| [`packer/bottlerocket.pkr.hcl`](packer/bottlerocket.pkr.hcl) | The Packer template: one `amazon-ebssurrogate` source and one `shell-local` provisioner for each build stage |
| [`packer/variables.pkr.hcl`](packer/variables.pkr.hcl) | The Packer variables |
| [`packer/builder-trust-policy.json`](packer/builder-trust-policy.json) | The trust policy of the builder role. Only `ec2.amazonaws.com` can assume the role. |
| [`packer/tools.lock`](packer/tools.lock) | The versions and digests of Packer, the plugin, Twoliter and the Rust tools |
| [`variant/`](variant/) | The variant `aws-k8s-1.36-nitro-sandbox` and the `nitro-sandbox` package, which the build adds to the Bottlerocket clone |
| [`variant/register-variant.py`](variant/register-variant.py) | Makes the variant from `aws-k8s-1.36` in the clone, and stops when an edit does not apply |
| [`packages/sources.lock`](packages/sources.lock) | The Bottlerocket source, the runtime, the guest image pair and Firecracker, each with its digest |
| [`packages/nitro-sandboxes-runtime-v1.pub`](packages/nitro-sandboxes-runtime-v1.pub) | The public key that verifies the signature of the runtime release |
| [`packages/lib/runtime_verify.py`](packages/lib/runtime_verify.py) | Verifies the SHA-256 of each input and the signature of the runtime release |
| [`scripts/10-build-ami-packer.sh`](scripts/10-build-ami-packer.sh) | Verifies the build tools (`check-tools`) and builds the AMI with Packer (`build`) |
| [`scripts/packer-stage.sh`](scripts/packer-stage.sh) | The stage driver. It sends the Systems Manager Run Commands of each build stage to the builder. |
| [`scripts/builder/`](scripts/builder/) | The stage scripts that run on the builder |
| [`scripts/common.sh`](scripts/common.sh) | The shared settings, version pins, guards and helpers of the scripts |
| [`scripts/lib/`](scripts/lib/) | The Python helpers that write the eksctl files and the launch templates, do the checks, read AWS and read the Packer manifest |
| [`deploy/namespace.yaml`](deploy/namespace.yaml) | The namespace `cilium-bottlerocket-demo`, with the label of the blueprint |
| [`deploy/pod-sandbox.yaml`](deploy/pod-sandbox.yaml) | The sandbox pod |
| [`deploy/pod-sandbox-network-isolated.yaml`](deploy/pod-sandbox-network-isolated.yaml) | The network-isolated sandbox pod |
| [`deploy/pod-ordinary.yaml`](deploy/pod-ordinary.yaml) | The two ordinary pods, one on each node |
| [`deploy/pod-server.yaml`](deploy/pod-server.yaml) | The HTTP server pod on the system node |
| [`deploy/service.yaml`](deploy/service.yaml) | The ClusterIP Service of the server pod |
| [`deploy/probe/node-probe.yaml`](deploy/probe/node-probe.yaml) | The privileged probe pod that reads the node for the node checks |
| [`deploy/probe/filler-pod.yaml`](deploy/probe/filler-pod.yaml) | The ordinary filler pod that `test.sh` starts on the sandbox node for the networkd check |

The output blocks on this page come from one fresh run in `us-west-2`. Before that run, no
resource of the blueprint was present. The block below gives the commit and the run ID of
that run.

```text
TODO: output from the fresh run
```

**Step 1: Make the local configuration file.** `config.env.example` holds all the settings,
with placeholders and shared defaults only. Copy it to `config.local.env`, which git ignores.
Then set your account ID in the copy. Here is the part of `config.env.example` that you must
change:

<!-- provisional excerpt: config.env.example. Refresh it from the frozen commit. -->
```bash
# The account and the Region of the new cluster. The scripts stop when the caller is in a
# different account. The sample is tested in us-west-2 only.
AWS_ACCOUNT_ID=""
AWS_REGION="us-west-2"
```

```bash
cp config.env.example config.local.env
export AWS_PROFILE=<your-profile>
```

Write your account ID into `config.local.env` with an editor. Do not put a credential in the
file. `setup.sh` stops when the caller account is not equal to `AWS_ACCOUNT_ID`.

**Step 2: Start the setup script.** `setup.sh` runs eight stages in sequence: `preflight`,
`cluster`, `cilium`, `system-node`, `ami`, `sandbox-node`, `node-checks` and `workloads`.
The `preflight` stage examines the tools, the Region, the account, the quota and the
blueprint names. It also runs `scripts/10-build-ami-packer.sh check-tools`, which verifies
Packer and the plugin against the signed HashiCorp checksums. The signature must come from
the key with the full fingerprint `HASHICORP_KEY_FPR`. The stage also examines these items:

- The sandbox instance type supports Nitro Enclaves.
- The stock Bottlerocket AMI for the system node. When `SYSTEM_AMI_ID` is empty, `setup.sh`
  reads the AMI ID from the public SSM parameter of Bottlerocket. Then it writes the ID into
  `config.local.env`, so each later run uses the same AMI.

`setup.sh` creates no resource until all of these checks pass.

Here is the part of `packer/tools.lock` that pins Packer, the plugin and the HashiCorp key:

<!-- provisional excerpt: packer/tools.lock. Refresh it from the frozen commit. -->
```text
PACKER_VERSION=1.16.2
PACKER_ZIP_SHA256_LINUX_AMD64=abbfe0cf74985084112659b53e3565f264f70a20914c3b7c4f789f54f61c2414
PACKER_ZIP_SHA256_LINUX_ARM64=5d7d6de86a49b2d64f3c0eef5766855b580e10a7c45bd6605ba8f1dead7815ea
PACKER_ZIP_SHA256_DARWIN_AMD64=cca17e6889754c8f6e9d9a2646a9f9cc650a70dfdafc8e7da7e5279977b7d812
PACKER_ZIP_SHA256_DARWIN_ARM64=3d7e4df8e7e8c21bdf495c4f63ad9189e22540dc8126dee6db791aa8519e8b3a
AMAZON_PLUGIN_VERSION=1.8.4
AMAZON_PLUGIN_API=x5.0
AMAZON_PLUGIN_ZIP_SHA256_LINUX_AMD64=8c86e53023a436d7b3e1ee41f48e0ac7a563200ebc01d3c1dfae82500d1e4332
AMAZON_PLUGIN_ZIP_SHA256_LINUX_ARM64=d072dd2a104355c186458c5c17c000d2c7616f04125daa7d742b03d3f4ae5db4
AMAZON_PLUGIN_ZIP_SHA256_DARWIN_AMD64=6f540452b0d307e053486ef488c90862ceff6ba922d656d627ab8be7766d9ebd
AMAZON_PLUGIN_ZIP_SHA256_DARWIN_ARM64=9944848b18d912d6070b677cb59b7e9e9301209546162cac09890c2345e311c7
HASHICORP_RELEASES_URL=https://releases.hashicorp.com
HASHICORP_KEY_URL=https://www.hashicorp.com/.well-known/pgp-key.txt
HASHICORP_KEY_FPR=C874011F0AB405110D02105534365D9472D7468F
```

```bash
./setup.sh
```

```text
TODO: output from the fresh run
```

Each run has a run ID. `setup.sh` keeps the state of the run in
`tmp/cilium-bottlerocket/run/runs/<RUN_ID>/` in the repository. Each stage writes the IDs
that the next stages and `clean.sh` need to `state.env` in that folder. The scripts find
the other resources by their names, their tags or the resources that hold them.

Every AWS resource of the run gets the tags `ManagedBy=cilium-bottlerocket-sample` and
`RunId=<RUN_ID>`. AWS creates some resources with no tag, for example the main route table
of the VPC. `setup.sh` adds the two tags to these resources. Two exceptions apply:

- The network interface of the builder has no tag. EC2 deletes it with the builder.
- An AMI from an earlier run keeps the `RunId` tag of that run, as Step 6 shows.

To stop after one stage, give `--stop-after <stage>`. To continue an interrupted run, give
its run ID:

```bash
RUN_ID=<RUN_ID> ./setup.sh
```

A continued run starts after the last stage that the run finished. If you give
`--stop-after` with `RUN_ID`, the stage must come after that last stage. Otherwise,
`setup.sh` stops with `E_USAGE` before it runs a stage.

The same folder holds the kubeconfig of the cluster, with the context `cb-<RUN_ID>`.
`setup.sh` does not change your default kubeconfig. To use `kubectl` yourself, set
`KUBECONFIG` from the repository root:

```bash
export KUBECONFIG="$(git rev-parse --show-toplevel)/tmp/cilium-bottlerocket/run/runs/<RUN_ID>/kubeconfig"
```

**Step 3: Create the cluster without `aws-node` or `kube-proxy`.** In the `cluster` stage,
eksctl creates a new VPC and an EKS 1.36 control plane. `disableDefaultAddons` stops the
installation of the default network add-ons of EKS. The cluster adds CoreDNS and the EKS Pod
Identity Agent again. The VPC CNI and kube-proxy are not on the list, because Cilium does the
work of both. The blueprint never changes the CNI of a cluster that it did not create.

Here is the part of `eksctl/cluster.yaml` that matters:

<!-- provisional excerpt: eksctl/cluster.yaml. Refresh it from the frozen commit. -->
```yaml
autoModeConfig:
  enabled: false
addonsConfig:
  disableDefaultAddons: true
addons:
  - name: coredns
    tags:
      ManagedBy: cilium-bottlerocket-sample
      RunId: ${RUN_ID}
  - name: eks-pod-identity-agent
    tags:
      ManagedBy: cilium-bottlerocket-sample
      RunId: ${RUN_ID}
```

```bash
kubectl --context cb-<RUN_ID> -n kube-system get daemonset aws-node kube-proxy
```

```text
TODO: output from the fresh run
```

Both lines must show `NotFound`. The cluster has no `aws-node` and no `kube-proxy`.

**Step 4: Give the Cilium operator its own AWS role.** In ENI mode, the Cilium operator is
the only component that calls the EC2 API. The operator creates ENIs for the nodes and
assigns their secondary IP addresses to pods. In the `cilium` stage, an EKS Pod Identity
association gives the operator the role `<CLUSTER_NAME>-cilium-operator`. `setup.sh` creates
the association before it installs Cilium, because EKS gives the credentials to the operator
pod when the pod starts.

The role allows only the EC2 actions in the
[required privileges](https://docs.cilium.io/en/stable/network/concepts/ipam/eni/#required-privileges)
of Cilium for this configuration. The list includes `ec2:DescribeTags`, because ENI garbage
collection is on. It has no `ec2:UnassignPrivateIpAddresses`, because the release of excess
IP addresses is off. It has no `ec2:DescribeInstances`, because the configuration uses no
instance tag filter. This is the policy document, from `eksctl/pod-identity.yaml`:

<!-- provisional excerpt: eksctl/pod-identity.yaml. Refresh it from the frozen commit. -->
```yaml
iam:
  podIdentityAssociations:
    - namespace: kube-system
      serviceAccountName: cilium-operator
      roleName: ${OPERATOR_ROLE_NAME}
      tags:
        ManagedBy: cilium-bottlerocket-sample
        RunId: ${RUN_ID}
      permissionPolicy:
        Version: "2012-10-17"
        Statement:
          - Sid: CiliumEniRead
            Effect: Allow
            Action:
              - ec2:DescribeInstanceTypes
              - ec2:DescribeNetworkInterfaces
              - ec2:DescribeSubnets
              - ec2:DescribeVpcs
              - ec2:DescribeRouteTables
              - ec2:DescribeSecurityGroups
              - ec2:DescribeTags
            Resource: "*"
          - Sid: CiliumEniWrite
            Effect: Allow
            Action:
              - ec2:CreateNetworkInterface
              - ec2:AttachNetworkInterface
              - ec2:ModifyNetworkInterfaceAttribute
              - ec2:AssignPrivateIpAddresses
              - ec2:DeleteNetworkInterface
              - ec2:CreateTags
            Resource: "*"
```

The read actions let the operator read the ENIs, the VPC and the subnets. They also let the
operator read the route tables, the security groups, the instance type limits and the tags.
The write actions control the life cycle of the ENIs that the operator manages. The role
cannot start or stop an instance. It cannot change a security group rule or a route table.

The node roles get only `AmazonEKSWorkerNodePolicy` and
`AmazonEC2ContainerRegistryPullOnly`. Neither node role has `AmazonEKS_CNI_Policy` or the EC2
permissions of Cilium. The workload pods get no Pod Identity association, so they get no AWS
permissions.

```text
TODO: output from the fresh run
```

The output shows the Pod Identity association of `cilium-operator`, and the policies of the
two node roles.

**Step 5: Install Cilium, then add the system node.** Helm installs Cilium 1.20.5 before a
node joins the cluster. Because of this, the first node has a CNI when it starts. In ENI
mode, each pod gets a VPC IP address, and the traffic uses native routing with no overlay.
Cilium also replaces kube-proxy and does the Service translation in eBPF.
`socketLB.hostNamespaceOnly` is `true`, so the per-packet load balancer serves the traffic of
the sandbox pod. The Cilium on Ubuntu nodes blueprint explains why a sandbox pod needs this
value.

Here is the part of `cilium-values.yaml` that matters, without its comments. `setup.sh` gives
three more values on the command line: the cluster name, the API server host and the `RunId`
tag of the ENIs.

<!-- provisional excerpt: cilium-values.yaml (comments removed). Refresh it from the frozen commit. -->
```yaml
eni:
  enabled: true
  eniTags:
    ManagedBy: cilium-bottlerocket-sample
ipam:
  mode: eni
routingMode: native
kubeProxyReplacement: true
k8sServicePort: 443
socketLB:
  hostNamespaceOnly: true
operator:
  replicas: 1
  nodeSelector:
    eks.amazonaws.com/nodegroup: system
```

Apart from the tags, the values of this blueprint have one difference from the values of the
Cilium on Ubuntu nodes blueprint. They remove the `sysctlfix` init container of Cilium.
Here is that part of `cilium-values.yaml`, with its comment:

<!-- provisional excerpt: cilium-values.yaml. Refresh it from the frozen commit. -->
```yaml
# No sysctlfix init container. It writes a file into /etc/sysctl.d on the host. On Bottlerocket,
# SELinux denies that write (an AVC denial for "cilium-sysctlfi", control_t on etc_t), so the
# container has no effect, and its denial would stop the boot-wide SELinux audit of the sandbox
# node. This is the only Bottlerocket-specific difference from the values of ../cilium-ubuntu.
sysctlfix:
  enabled: false
```

The `preflight` checks stop the run when `cilium-values.yaml` does not set
`sysctlfix.enabled: false`. [Good to know](#good-to-know) gives the reason.

In the `system-node` stage, `setup.sh` adds the system node group. The system node uses the
stock `aws-k8s-1.36` AMI of Bottlerocket v1.70.0, with the AMI ID that the `preflight` stage
recorded. The launch template gives the node settings in TOML user data, with IMDSv2
required and a hop limit of 1. Here is the function in `scripts/lib/cb_render.py` that
writes the user data of both node groups:

<!-- provisional excerpt: scripts/lib/cb_render.py, function user_data. Refresh it from the frozen commit. -->
```python
def user_data(group, info):
    max_pods = int_setting("SANDBOX_SLOTS" if group == "sandbox" else "SYSTEM_MAX_PODS", 1, 250)
    lines = ["[settings.kubernetes]",
             f"cluster-name = {toml_str(info['name'])}",
             f"api-server = {toml_str(info['endpoint'])}",
             f"cluster-certificate = {toml_str(info['ca'])}",
             f"cluster-dns-ip = {toml_str(info['dns'])}",
             f"max-pods = {max_pods}"]
    if group == "sandbox":
        lines.append(f"container-runtime-endpoint = {toml_str(CRI_PROXY_ENDPOINT)}")
    lines += ["", "[settings.kubernetes.node-labels]"]
    lines += [f"{toml_str(k)} = {toml_str(v)}" for k, v in node_labels(group).items()]
    if group == "sandbox":
        lines += ["", "[settings.kubernetes.node-taints]", f"{toml_str(SANDBOX_TAINT_KEY)} = [\"true:NoSchedule\"]"]
    return "\n".join(lines) + "\n"
```

Bottlerocket needs an explicit `max-pods` with a CNI other than the Amazon VPC CNI.
`SYSTEM_MAX_PODS` gives the value for the system node.

Before the AMI build starts, `setup.sh` examines the system node and the Cilium operator.
Then it tags the resources that AWS created for the cluster and the system node group with
no tag. It also examines the tags of each resource class of the run.

```text
TODO: output from the fresh run
```

The system node must be `Ready`, and the Cilium operator pod must be `Running` on it.

**Step 6: Build the sandbox AMI with Packer.** In the `ami` stage, `setup.sh` runs
`scripts/10-build-ami-packer.sh build`. Packer uses the `amazon-ebssurrogate` builder with
`communicator = "none"`. A builder instance (the builder) runs Amazon Linux 2023 in a
private subnet of the cluster VPC. The builder connects to the internet through the NAT
gateway of the cluster.

The builder has no SSH key pair, no inbound rule in its security group and no public IP
address. Its security group allows only outbound TCP 443. The builder requires IMDSv2, with
a hop limit of 1.

Here is the part of `packer/bottlerocket.pkr.hcl` that sets the network and the access of
the builder:

<!-- provisional excerpt: packer/bottlerocket.pkr.hcl, builder network and access. Refresh it from the frozen commit. -->
```hcl
  subnet_id                   = var.subnet_id
  associate_public_ip_address = false
  security_group_id           = var.security_group_id
  iam_instance_profile        = var.instance_profile

  # No SSH: no communicator, so no key pair and no inbound rule.
  communicator            = "none"
  ssh_agent_auth          = true
  skip_metadata_api_check = true

  shutdown_behavior     = "stop"
  disable_stop_instance = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }
```

The builder role has only the `AmazonSSMManagedInstanceCore` policy, and only
`ec2.amazonaws.com` can assume it. The build script creates the role, the instance profile
and the security group before Packer starts. It deletes them after Packer stops.

Each Packer `shell-local` stage runs `scripts/packer-stage.sh` on the operator machine. The
`bind` stage runs on the operator machine only. For each later stage except `upload`, the
stage driver sends one AWS Systems Manager Run Command to the builder. The `upload` stage
sends one command for each part of the upload, and one more command to unpack the parts.
The stage driver waits for each command to stop, and it continues only when the status is
`Success`. Here is the first stage, from `packer/bottlerocket.pkr.hcl`:

<!-- provisional excerpt: packer/bottlerocket.pkr.hcl, first shell-local stage. Refresh it from the frozen commit. -->
```hcl
  provisioner "shell-local" {
    inline  = ["exec bash '${var.stage_driver}'"]
    env     = { CB_STAGE = "bind", CB_BUILDER_ID = build.ID, CB_PACKER_RUN_UUID = build.PackerRunUUID, RUN_STATE_DIR = var.run_state_dir }
    timeout = "15m"
  }
```

The stages run in this sequence:

| Stage | Where it runs | What it does |
|---|---|---|
| `bind` | Operator machine | Examines the builder instance, then waits until Systems Manager shows the instance as `Online` |
| `upload` | Builder | Copies the variant, the package and the stage scripts to the builder, and verifies their SHA-256 |
| `host-setup` | Builder | Installs Docker, the Rust tools and Twoliter on the builder |
| `fetch-verify` | Builder | Clones Bottlerocket, examines the tag and the commit against the lock file, then downloads and verifies every input |
| `overlay` | Builder | Adds the variant and the `nitro-sandbox` package to the clone, and writes `SANDBOX_SLOTS` as `pcie_slots` into `nitro-sandbox.toml` |
| `build` | Builder | Builds the variant with Twoliter |
| `write-images` | Builder | Writes the OS image and the data image to two attached EBS volumes, then reads them back |
| `verify-root` | Builder | Verifies the partition bounds and mounts the root partition read-only. Then it verifies the SHA-256 of each file that `packages/sources.lock` installs, which includes the guest image pair. It also examines `pcie_slots` in `nitro-sandbox.toml` and the containerd drop-in. |
| `release` | Builder | Writes all cached data to the disks. Then it examines that the OS volume and the data volume are not mounted, and flushes their buffers. |

Before the build uses a downloaded file, it compares the SHA-256 of the file with the lock
file. For the runtime archive, it also verifies the ECDSA signature of the downloaded
`SHA256SUM` with `nitro-sandboxes-runtime-v1.pub`. A changed checksum or a changed signature
stops the build. The Amazon EKS User Guide,
[*Download and verify the runtime binaries*](https://docs.aws.amazon.com/eks/latest/userguide/sandboxing-download-binaries.html),
gives the signature procedure.

```text
TODO: output from the fresh run
```

The output shows the key pair, the public IP address and the inbound rule count of the
builder. It also shows the command ID and the status of each Run Command.

The build clones `bottlerocket` at `v1.70.0`, as the Amazon EKS User Guide page
[*Build a custom Bottlerocket AMI variant for Amazon EKS*](https://docs.aws.amazon.com/eks/latest/userguide/bottlerocket-custom-variant.html)
shows. The variant `aws-k8s-1.36-nitro-sandbox` is different from `aws-k8s-1.36` in four
items only:

- The variant name.
- The `nitro-sandbox` package.
- The OS image size, `os-image-size-gib`, from a measured build. The guest disk image is
  2 GiB, so the default OS image of 2 GiB is too small.
- The kernel parameter `nitro_enclaves.mempool=95%-1G`. The kernel reserves the enclave
  memory early in the boot. A value in the user data arrives after that point, so the
  parameter is in the build-time kernel parameters of the variant.

```text
TODO: output from the fresh run
```

The diff shows the four items, and no other change.

The `nitro-sandbox` package holds the runtime files. The stock kernel, containerd, kubelet
and SELinux policy stay unchanged. The package contains these files:

- The shim at `/usr/bin/containerd-shim-nitro-sandbox-v2` and its logger wrapper, and
  Firecracker and jailer in `/usr/bin`.
- The guest image pair in `/usr/share/nitro-sandbox/`.
- `nitro-sandbox.toml`, the configuration of the shim.
- A containerd drop-in with the runtime handlers and `discard_unpacked_layers = false`.
- The CRI proxy unit, and a kubelet drop-in that starts kubelet after the CRI proxy.
- A systemd-networkd unit that marks `eth[1-9]*` as unmanaged, as the Cilium
  [ENI node configuration](https://docs.cilium.io/en/stable/network/concepts/ipam/eni/#node-configuration)
  specifies.
- A `tmpfiles.d` file that copies the two containerd files to `/etc/containerd/` at each
  boot, because `/etc/containerd` is a tmpfs on Bottlerocket.
- A `modules-load.d` file that loads the `tun` module. The shim makes one TAP device for
  each sandbox.

The package installs the release binaries with no change. The package spec stops the strip
step of the Bottlerocket SDK, so the `verify-root` stage can compare each installed file
with `packages/sources.lock`.

Here is the containerd drop-in, `variant/packages/nitro-sandbox/50-nitro-sandbox.toml`,
without its first comment lines. The containerd configuration of Bottlerocket imports
`/etc/containerd/config.d/*.toml`:

<!-- provisional excerpt: variant/packages/nitro-sandbox/50-nitro-sandbox.toml. Refresh it from the frozen commit. -->
```toml
[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.isolated-sandbox]
runtime_type = "io.containerd.nitro-sandbox.v2"
runtime_path = "/usr/bin/containerd-shim-nitro-sandbox-v2"
sandboxer = "shim"
privileged_without_host_devices = true

[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.confidential-sandbox]
runtime_type = "io.containerd.nitro-sandbox.v2"
runtime_path = "/usr/bin/containerd-shim-nitro-sandbox-v2"
sandboxer = "shim"
privileged_without_host_devices = true

# The User Guide requires the unpacked layers to stay. false is also the default; this
# sample sets it explicitly.
[plugins."io.containerd.cri.v1.images"]
discard_unpacked_layers = false
```

Here is the systemd-networkd unit,
`variant/packages/nitro-sandbox/00-nitro-sandbox-eni-unmanaged.network`, without its
comments:

<!-- provisional excerpt: variant/packages/nitro-sandbox/00-nitro-sandbox-eni-unmanaged.network. Refresh it from the frozen commit. -->
```ini
[Match]
Name=eth[1-9]*

[Link]
Unmanaged=yes
```

The builder writes the two images to two EBS volumes. Packer makes a snapshot of each of
these volumes and registers the AMI from them. The root volume and the work volume of the
builder have `omit_from_artifact = true`, so Packer makes no snapshot of them.

Packer registers the AMI with the values that the Bottlerocket `pubsys` tool uses for this variant.
The Packer manifest names exactly one AMI. The AMI and its two snapshots have the tags
`ManagedBy=cilium-bottlerocket-sample`, `RunId`, `Name` and `SandboxSlots`. They also have the
tags `BottlerocketRelease`, `Variant`, `NitroRuntime`, `GuestImage` and `Firecracker`, which
give the pins of the build.

Here are the two volumes of the builder that Packer omits, from `packer/bottlerocket.pkr.hcl`:

<!-- provisional excerpt: packer/bottlerocket.pkr.hcl, omitted builder volumes. Refresh it from the frozen commit. -->
```hcl
  # The builder root: omitted from the AMI.
  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_type           = "gp3"
    volume_size           = var.builder_root_gib
    delete_on_termination = true
    omit_from_artifact    = true
  }
  # The work volume for the clone and the Twoliter build: omitted from the AMI.
  launch_block_device_mappings {
    device_name           = "/dev/xvdc"
    volume_type           = "gp3"
    volume_size           = var.work_gib
    delete_on_termination = true
    omit_from_artifact    = true
  }
```

Here are the root device and the registration values, from the same file:

<!-- provisional excerpt: packer/bottlerocket.pkr.hcl, root device and registration. Refresh it from the frozen commit. -->
```hcl
  ami_root_device {
    source_device_name    = "/dev/xvdf"
    device_name           = "/dev/xvda"
    volume_type           = "gp3"
    volume_size           = var.os_image_gib
    delete_on_termination = true
  }

  ami_name                = var.ami_name
  ami_description         = "Bottlerocket aws-k8s-1.36-nitro-sandbox (cilium-bottlerocket sample)"
  ami_architecture        = "x86_64"
  ami_virtualization_type = "hvm"
  ena_support             = true
  sriov_support           = true
  imds_support            = "v2.0"
  # No uefi_data: one Packer pass cannot include the UEFI variables that the build makes,
  # so the firmware does not enforce Secure Boot.
  boot_mode = "uefi-preferred"
```

```bash
aws ec2 describe-images --region us-west-2 --image-ids <SANDBOX_AMI_ID>
```

```text
TODO: output from the fresh run
```

The output shows `x86_64`, `hvm`, ENA, SR-IOV `simple` and IMDSv2 required. It shows the root
device `/dev/xvda` and the data device `/dev/xvdb`, both gp3. It shows the boot mode
`uefi-preferred` and no UEFI data.

**The firmware does not enforce Secure Boot on this AMI.** The variant enables UEFI Secure
Boot, and Twoliter makes the UEFI variable data during the build. Packer reads the UEFI data
before the build starts, so one Packer pass cannot include that data. Because of this, Packer
registers the AMI with no UEFI variable data.

dm-verity still verifies the root file system, but dm-verity and Secure Boot are two
different mechanisms. Secure Boot verifies the boot loader and the kernel before they start.
dm-verity verifies the blocks of the root file system when the kernel reads them. The node
checks in Step 7 show the dm-verity evidence from the node.

After Packer stops, `setup.sh` examines the builder instance, its volumes, its security
group, its instance profile and its role. Each resource must be absent, or the instance must
be `terminated`. A lookup that fails stops the run.

```text
TODO: output from the fresh run
```

**Build again after a failed AMI build.** The build script runs Packer with
`-on-error=cleanup`. After a failed build, Packer terminates the builder, and EC2 deletes
its volumes. The build script then deletes the builder security group, the instance profile
and the role. `setup.sh` stops with `E_AMI_BUILD`, and the cluster and the system node stay.
The error message tells you to run `./clean.sh`, which deletes the full run. To keep the
cluster, build again in the same run:

```bash
RUN_ID=<RUN_ID> ./setup.sh
```

The `ami` stage builds again only when each part of the last attempt is absent. The stage
reads the builder instance, its volumes, the security group, the instance profile and the
role. It also reads the AMIs and the snapshots of the run, by tag and by name. When a part
is present or a read fails, the stage stops with `E_RESUME` and changes nothing. In that
case, run `./clean.sh --dry-run` to see the part. When all parts are absent, the stage moves
the files of the last attempt to `packer.attempt<N>/` in the run folder, and it deletes nothing.

**Use an AMI from an earlier run.** To skip the build, set `REUSE_SANDBOX_AMI_ID` in
`config.local.env` to an AMI that an earlier run of this blueprint built. The `ami` stage
then creates no builder. The AMI must have the tag `ManagedBy=cilium-bottlerocket-sample`
and a `SandboxSlots` tag equal to `SANDBOX_SLOTS`, and it must pass the AMI checks. The AMI keeps the `RunId`
tag of the earlier run. Because of this, `clean.sh` of the new run does not delete the AMI
or its snapshots.

**Step 7: Add the sandbox node and examine it.** In the `sandbox-node` stage, `setup.sh`
adds the sandbox node group with exactly one node. The launch template enables Nitro
Enclaves. The TOML user data sets `settings.kubernetes.container-runtime-endpoint` to
`unix:///run/nitro-sandbox/cri-proxy.sock`. `SANDBOX_DATA_VOLUME_GIB` sets the size of the
data volume `/dev/xvdb` of the sandbox node, and EBS encrypts the volume.

One value, `SANDBOX_SLOTS`, sets the sandbox density. It is `max-pods` in the user data of
the sandbox node, and `pcie_slots` in `nitro-sandbox.toml` of the AMI. The AMI and its
snapshots record the value in the `SandboxSlots` tag. A difference between these values
stops the run. Here is the value in `config.env.example`:

<!-- provisional excerpt: config.env.example, SANDBOX_SLOTS. Refresh it from the frozen commit. -->
```bash
# The sandbox slot count. This one value sets max-pods on the sandbox node and pcie_slots in the
# runtime configuration of the AMI. The AMI records it in its SandboxSlots tag. setup.sh stops
# when the AMI, the launch template or the node shows a different value.
SANDBOX_SLOTS="58"
```

Here is the part of `launch_template_data` in `scripts/lib/cb_render.py` that enables Nitro
Enclaves on the sandbox node:

<!-- provisional excerpt: scripts/lib/cb_render.py, function launch_template_data. Refresh it from the frozen commit. -->
```python
    if group == "sandbox":
        data["EnclaveOptions"] = {"Enabled": True}
```

In the `node-checks` stage, `setup.sh` examines the sandbox node before a sandbox pod starts.
It reads the node object, the kubelet configuration and the output of a privileged probe pod
on the node. `setup.sh` deletes the probe pod by its exact name. These are the checks:

- The OS image is Bottlerocket v1.70.0.
- `/sys/kernel/btf/vmlinux` is present.
- The kernel command line has `nitro_enclaves.mempool=95%-1G`, and the kernel log shows the
  `nitro_enclaves` memory reservation.
- The kubelet runtime endpoint is `unix:///run/nitro-sandbox/cri-proxy.sock`.
- The merged containerd configuration contains the `isolated-sandbox` handler and
  `discard_unpacked_layers = false`.
- The allocatable `eks.amazonaws.com/nitro-sandbox` value is more than 0.
- The allocatable pods of the node and `pcie_slots` in `nitro-sandbox.toml` on the node are
  both equal to `SANDBOX_SLOTS`.
- SELinux is in enforcing mode.
- dm-verity verifies the root file system.

```text
TODO: output from the fresh run
```

Each line must show the expected value. An absent value or a wrong value stops the run.
Then `setup.sh` again tags the resources that AWS created for the cluster and the node
groups with no tag. It also examines the tags of each resource class of the run again.

SELinux stays in enforcing mode on the sandbox node. The blueprint makes no policy change
and no mode change. The Bottlerocket SELinux policy gives the label `runtime_exec_t` to
`/usr/bin/containerd*` files. Because of this, the shim and the CRI proxy run in the
`runtime_t` domain.

`test.sh` reads the kernel log and the journal of the node, and examines the AVC records
since boot. A denial fails the check. A log that `test.sh` cannot read also fails the check,
and `test.sh` then exits with a non-zero code.

```text
TODO: output from the fresh run
```

The output shows the SELinux mode, the domain of the shim and the CRI proxy, and the audit
result.

`test.sh` also shows that systemd-networkd does not manage the Cilium ENIs. Cilium gives
pods the secondary IP addresses of `eth0` first. A second ENI, `eth1`, comes only when the
node needs more addresses. Because of this, `test.sh` does these steps:

1. It starts ordinary filler pods on the sandbox node, one at a time, with exact names
   `cb-filler-<n>-<RUN_ID>`. It stops when the CiliumNode of the sandbox node lists a second
   ENI. It starts 16 filler pods at most, and never more than the free pod slots of the node.
2. It reads the link state of each interface in systemd-networkd. Each `eth1` and later
   interface must be `unmanaged`.
3. It deletes each filler pod by its exact name.

When no second ENI comes, the check fails with `E_NETWORKD_ENI`. The filler pods set no CPU
or memory requests or limits.

```text
TODO: output from the fresh run
```

The output shows the number of filler pods and the ENIs of the node. It also shows that
systemd-networkd lists each Cilium ENI as `unmanaged`, so networkd does not change the
addresses or the routes that Cilium sets.

To compare the sandbox node with the system node, list the nodes:

```bash
kubectl --context cb-<RUN_ID> get nodes -o wide
```

```text
TODO: output from the fresh run
```

The `OS-IMAGE`, `KERNEL-VERSION` and `CONTAINER-RUNTIME` columns show the Bottlerocket
release, the kernel version and the containerd version of each node.

**Step 8: Run the pods and the tests.** In the `workloads` stage, `setup.sh` creates the
`isolated-sandbox` RuntimeClass when it is absent. The `system-node` stage creates the
namespace `cilium-bottlerocket-demo` with the label of the blueprint, for the probe pod. The
`workloads` stage examines that label again. Then `setup.sh` applies the pods and the
ClusterIP Service from `deploy/`. The pods are:

- `cb-sandbox`, a sandbox pod with `runtimeClassName: isolated-sandbox`.
- `cb-sandbox-isolated`, a second sandbox pod that boots with
  `sandbox.amazonaws.com/network-isolated: "true"`.
- `cb-ordinary-sandbox-node`, an ordinary pod on the sandbox node.
- `cb-ordinary-system-node`, an ordinary pod on the system node.
- `cb-server`, an HTTP server on the system node, which the ClusterIP Service selects.

The pods set no CPU or memory requests or limits.

Here is the part of `deploy/pod-sandbox.yaml` that matters. The RuntimeClass selects the
sandbox node, and the toleration lets the pod use the tainted node:

<!-- provisional excerpt: deploy/pod-sandbox.yaml. Refresh it from the frozen commit. -->
```yaml
spec:
  runtimeClassName: isolated-sandbox
  tolerations:
    - key: sandbox.eks-nitro-sandbox.amazonaws.com/dedicated
      operator: Equal
      value: "true"
      effect: NoSchedule
```

Here is the part of `deploy/pod-sandbox-network-isolated.yaml` that removes the network:

<!-- provisional excerpt: deploy/pod-sandbox-network-isolated.yaml. Refresh it from the frozen commit. -->
```yaml
  annotations:
    sandbox.amazonaws.com/network-isolated: "true"
spec:
  runtimeClassName: isolated-sandbox
```

Here is `deploy/service.yaml`, without its comments:

<!-- provisional excerpt: deploy/service.yaml (comments removed). Refresh it from the frozen commit. -->
```yaml
apiVersion: v1
kind: Service
metadata:
  name: cb-server
  namespace: cilium-bottlerocket-demo
  labels:
    app.kubernetes.io/part-of: cilium-bottlerocket-sample
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: cb-server
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
```

When `setup.sh` stops with no error, run `test.sh`:

```bash
./test.sh
```

```text
TODO: output from the fresh run
```

The output has these results:

- `cilium status` on each node shows ENI IPAM, native routing and kube-proxy replacement.
  `test.sh` reads `socketLB.hostNamespaceOnly: true` from the live agent on each node.
- The sandbox pod has its own guest. Its kernel build, its boot uptime and its virtio `vd*`
  disks are different from the results of the ordinary pod on the same node. The ordinary
  pod shows the kernel build of the node, the uptime of the node and the `nvme*` disks of
  the node.
- The IP address of the sandbox pod is a secondary IP address of an ENI on its node. The
  CiliumEndpoint of the pod is in the ready state.
- The pod-to-pod, ClusterIP Service and DNS tests pass from the sandbox pod. The same tests
  pass from the ordinary pod on the sandbox node and from the ordinary pod on the system
  node.
- The network-isolated sandbox pod has only loopback. It has no route, and a DNS lookup
  fails.
- The system node runs the stock Bottlerocket AMI that `setup.sh` recorded. The sandbox node
  runs the sandbox AMI of the run.
- With the valid containerd drop-in, `containerd config dump` on the sandbox node shows the
  `isolated-sandbox` handler. With no drop-in and with a malformed drop-in, the node check
  refuses the result. `test.sh` makes each case in its own folder under `/run/cb-probe` on
  the node, and removes that folder after the case.
- The only Pod Identity association is `kube-system/cilium-operator`. The workload pods have
  no AWS credential variable.
- Each Service of the cluster is a ClusterIP Service. The cluster has no Ingress, no
  NetworkPolicy, no CiliumNetworkPolicy and no CiliumClusterwideNetworkPolicy.
- Each resource of the run has the `ManagedBy` and `RunId` tags.

A check that `test.sh` cannot complete counts as a failure. `test.sh` exits with a non-zero
code when a check does not pass.

## IAM matrix

The blueprint uses five principals. The table gives the actions of each principal, by
resource. The builder instance and the Cilium operator get only the actions in their rows,
because the blueprint creates their roles. The cluster creator, the Packer and SSM caller and
the cleaner are your own short-lived credentials. For least privilege, give these credentials
only the actions in their rows. In the table, `<CLUSTER_NAME>` and `<RUN_ID>` are the values
of your run.

A row for "The account" holds actions that take no resource, for example the EC2 describe
actions. Some rows name a tag to identify the resources of the run. The scripts read the
`ManagedBy` and `RunId` tags of a resource again before they change or delete it.

<!-- provisional matrix (plan review R8). Sources: lanes/iam-actions-cluster.md (sections 1, 2 and 4, with the section 6 CloudTrail corrections of the Phase 1 run) and lanes/iam-actions-ami.md (sections 1 to 3 and fix 2). Not yet confirmed: the IAM rows (IAM events are in us-east-1, not read), the Packer and SSM caller rows (no CloudTrail comparison of a build yet), and the cleaner rows (clean.sh not run yet). Rebuild every row from the fresh run. -->

| Principal | Resource | Actions |
|---|---|---|
| Cluster creator | The account, and the four VPC and EC2 quotas that `setup.sh` reads | `sts:GetCallerIdentity`, `servicequotas:GetServiceQuota`, `autoscaling:DescribeAutoScalingGroups`, `ec2:DescribeAvailabilityZones`, `ec2:DescribeVpcs`, `ec2:DescribeVpcAttribute`, `ec2:DescribeSubnets`, `ec2:DescribeRouteTables`, `ec2:DescribeNetworkAcls`, `ec2:DescribeInternetGateways`, `ec2:DescribeNatGateways`, `ec2:DescribeAddresses`, `ec2:DescribeSecurityGroups`, `ec2:DescribeSecurityGroupRules`, `ec2:DescribeNetworkInterfaces`, `ec2:DescribeVpcEndpoints`, `ec2:DescribeInstances`, `ec2:DescribeVolumes`, `ec2:DescribeInstanceTypes`, `ec2:DescribeImages`, `ec2:DescribeImageAttribute`, `ec2:DescribeSnapshots`, `ec2:DescribeLaunchTemplates`, `ec2:DescribeLaunchTemplateVersions` |
| Cluster creator | The public SSM parameter of the Bottlerocket `aws-k8s-1.36` v1.70.0 AMI | `ssm:GetParameter` |
| Cluster creator | The CloudFormation stacks `eksctl-<CLUSTER_NAME>-*` | `cloudformation:CreateStack`, `cloudformation:DescribeStacks`, `cloudformation:DescribeStackResources`, `cloudformation:GetTemplate`, `cloudformation:ListStacks` |
| Cluster creator | The VPC, subnets, internet gateway, route tables, Elastic IP address, NAT gateway and security groups that CloudFormation creates in the eksctl stacks | `ec2:CreateVpc`, `ec2:ModifyVpcAttribute`, `ec2:CreateSubnet`, `ec2:ModifySubnetAttribute`, `ec2:CreateInternetGateway`, `ec2:AttachInternetGateway`, `ec2:CreateRouteTable`, `ec2:CreateRoute`, `ec2:AssociateRouteTable`, `ec2:AllocateAddress`, `ec2:CreateNatGateway`, `ec2:CreateSecurityGroup`, `ec2:AuthorizeSecurityGroupIngress`, `ec2:CreateTags` |
| Cluster creator | The cluster `<CLUSTER_NAME>`, its add-ons, its node groups and its Pod Identity association | `eks:CreateCluster`, `eks:DescribeCluster`, `eks:DescribeClusterVersions`, `eks:CreateAddon`, `eks:DescribeAddon`, `eks:DescribeAddonVersions`, `eks:ListAddons`, `eks:CreateNodegroup`, `eks:DescribeNodegroup`, `eks:ListNodegroups`, `eks:CreatePodIdentityAssociation`, `eks:DescribePodIdentityAssociation`, `eks:ListPodIdentityAssociations` |
| Cluster creator | The Kubernetes API of the cluster | Cluster administrator, through the access entry that EKS creates for the creator of the cluster. The scripts call no access entry action. |
| Cluster creator | The cluster role and the node roles `eksctl-<CLUSTER_NAME>-*`, and the role `<CLUSTER_NAME>-cilium-operator` | `iam:CreateRole`, `iam:TagRole`, `iam:AttachRolePolicy`, `iam:PutRolePolicy`, `iam:GetRole`, `iam:GetRolePolicy`, `iam:ListAttachedRolePolicies`, `iam:ListRolePolicies`, `iam:ListRoleTags`, and `iam:PassRole` of the cluster role and the node roles to `eks.amazonaws.com` |
| Cluster creator | The service-linked roles of EKS, EKS node groups and Auto Scaling, only when the account does not have them | `iam:CreateServiceLinkedRole` |
| Cluster creator | The builder role and the builder instance profile `<CLUSTER_NAME>-<RUN_ID>-builder`, which must not exist before the run | `iam:GetRole`, `iam:ListRoleTags`, `iam:GetInstanceProfile`, `iam:ListInstanceProfileTags` |
| Cluster creator | The launch templates `<CLUSTER_NAME>-<RUN_ID>-system` and `<CLUSTER_NAME>-<RUN_ID>-sandbox` | `ec2:CreateLaunchTemplate`, `ec2:CreateTags`, and `ec2:RunInstances` as a dry run only, with which eksctl examines each launch template |
| Cluster creator | The main route table, the network ACL, and the default and cluster security groups of the run VPC, which have no tag | `ec2:CreateTags` |
| Cluster creator | The ENIs of the control plane and the NAT gateway, and the launch template copies of the node groups, which have no tag | `ec2:CreateTags` |
| Cluster creator | The Auto Scaling groups of the two node groups | `autoscaling:CreateOrUpdateTags` |
| Cluster creator | The instance profiles that EKS creates for the node groups | `iam:ListInstanceProfileTags`, `iam:TagInstanceProfile` |
| Packer and SSM caller | The account | `sts:GetCallerIdentity`, `ec2:DescribeRegions`, `ec2:DescribeSubnets`, `ec2:DescribeSecurityGroups`, `ec2:DescribeInstances`, `ec2:DescribeVolumes`, `ec2:DescribeImages`, `ec2:DescribeImageAttribute`, `ec2:DescribeSnapshots`, `ssm:GetCommandInvocation`, `ssm:DescribeInstanceInformation` |
| Packer and SSM caller | The public SSM parameter of the Amazon Linux 2023 AMI | `ssm:GetParameter` |
| Packer and SSM caller | The builder security group in the cluster VPC | `ec2:CreateSecurityGroup`, `ec2:RevokeSecurityGroupEgress`, `ec2:AuthorizeSecurityGroupEgress`, `ec2:DeleteSecurityGroup`, `ec2:CreateTags` |
| Packer and SSM caller | The builder role and the builder instance profile `<CLUSTER_NAME>-<RUN_ID>-builder` | `iam:CreateRole`, `iam:TagRole`, `iam:GetRole`, `iam:DeleteRole`, `iam:AttachRolePolicy` and `iam:DetachRolePolicy` of `AmazonSSMManagedInstanceCore` only, `iam:CreateInstanceProfile`, `iam:TagInstanceProfile`, `iam:GetInstanceProfile`, `iam:AddRoleToInstanceProfile`, `iam:RemoveRoleFromInstanceProfile`, `iam:DeleteInstanceProfile`, and `iam:PassRole` of the builder role to `ec2.amazonaws.com` |
| Packer and SSM caller | The builder instance, its four volumes and its network interface, in the build subnet with the builder security group and the Amazon Linux 2023 AMI | `ec2:RunInstances`, `ec2:CreateTags`, `ec2:StopInstances`, `ec2:ModifyInstanceAttribute`, `ec2:TerminateInstances` |
| Packer and SSM caller | The AMI and its two snapshots | `ec2:CreateSnapshot`, `ec2:RegisterImage`, `ec2:ModifyImageAttribute`, `ec2:CreateTags`. After a failed build only: `ec2:DeregisterImage`, `ec2:DeleteSnapshot`, `ec2:DeleteVolume`. |
| Packer and SSM caller | The document `AWS-RunShellScript`, and the builder instance with the tag `ManagedBy=cilium-bottlerocket-sample` | `ssm:SendCommand` |
| Builder instance | The builder role of the run, which only `ec2.amazonaws.com` can assume | Only the AWS managed policy `AmazonSSMManagedInstanceCore`. The stage scripts on the builder call no AWS API. |
| Cilium operator | The ENIs in the cluster VPC, through the role `<CLUSTER_NAME>-cilium-operator`, which only `pods.eks.amazonaws.com` can assume | Only the 13 actions in the policy document of Step 4 |
| Cleaner | The account | `sts:GetCallerIdentity`, `autoscaling:DescribeAutoScalingGroups`, and the EC2 describe actions of the cluster creator |
| Cleaner | The instance profiles that EKS creates for the node groups | `iam:ListInstanceProfileTags` |
| Cleaner | The Kubernetes API of the cluster | Delete the namespace `cilium-bottlerocket-demo` and the RuntimeClass `isolated-sandbox`, only when each has the label of the blueprint |
| Cleaner | The cluster `<CLUSTER_NAME>`, its node groups, its add-ons, its access entries and its Pod Identity association | `eks:DescribeCluster`, `eks:ListNodegroups`, `eks:DescribeNodegroup`, `eks:DeleteNodegroup`, `eks:ListAddons`, `eks:DescribeAddon`, `eks:DeleteAddon`, `eks:ListAccessEntries`, `eks:DeleteAccessEntry`, `eks:ListPodIdentityAssociations`, `eks:DescribePodIdentityAssociation`, `eks:DeletePodIdentityAssociation`, `eks:DeleteCluster` |
| Cleaner | The ENIs that Cilium created, the builder instances, their volumes and the builder security group, each with the tag `RunId=<RUN_ID>` | `ec2:DeleteNetworkInterface`, `ec2:TerminateInstances`, `ec2:DeleteVolume`, `ec2:DeleteSecurityGroup` |
| Cleaner | The launch templates of the run | `ec2:DeleteLaunchTemplate` |
| Cleaner | The AMI and its snapshots, each with the tag `RunId=<RUN_ID>` | `ec2:DeregisterImage`, `ec2:DeleteSnapshot` |
| Cleaner | The CloudFormation stacks `eksctl-<CLUSTER_NAME>-*` | `cloudformation:DescribeStacks`, `cloudformation:ListStacks`, `cloudformation:DescribeStackEvents`, `cloudformation:DeleteStack` |
| Cleaner | The VPC objects that CloudFormation deletes with the eksctl stacks | `ec2:DeleteNatGateway`, `ec2:DisassociateAddress`, `ec2:ReleaseAddress`, `ec2:DetachInternetGateway`, `ec2:DeleteInternetGateway`, `ec2:DeleteRoute`, `ec2:DisassociateRouteTable`, `ec2:DeleteRouteTable`, `ec2:DeleteSubnet`, `ec2:RevokeSecurityGroupIngress`, `ec2:RevokeSecurityGroupEgress`, `ec2:DeleteSecurityGroup`, `ec2:DeleteVpc` |
| Cleaner | The builder role, the role `<CLUSTER_NAME>-cilium-operator` and the roles `eksctl-<CLUSTER_NAME>-*` | `iam:GetRole`, `iam:ListRoleTags`, `iam:ListAttachedRolePolicies`, `iam:ListRolePolicies`, `iam:DetachRolePolicy`, `iam:DeleteRolePolicy`, `iam:DeleteRole` |
| Cleaner | The builder instance profile `<CLUSTER_NAME>-<RUN_ID>-builder` | `iam:GetInstanceProfile`, `iam:ListInstanceProfileTags`, `iam:RemoveRoleFromInstanceProfile`, `iam:DeleteInstanceProfile` |

The node roles are not principals of the blueprint. Each node role has only
`AmazonEKSWorkerNodePolicy` and `AmazonEC2ContainerRegistryPullOnly`.

## Good to know

- **The firmware does not enforce Secure Boot.** dm-verity verifies the root file system,
  but Secure Boot and dm-verity are different mechanisms. To enforce Secure Boot, the AMI
  needs the UEFI variable data from the build, and one Packer pass cannot include it.
- **The AMI is not a FIPS image.** The variant enables no FIPS image feature of Bottlerocket.
  The release binaries of the shim and Firecracker use aws-lc-rs with no FIPS build. Because
  of this, the build of the `nitro-sandbox` package does not run the FIPS check of the
  Bottlerocket SDK.
- **Cilium runs with no `sysctlfix` init container.** This init container writes a file into
  `/etc/sysctl.d` on the node. On Bottlerocket, SELinux denies this write, so the init
  container has no effect. With the init container, the SELinux audit of the sandbox node
  finds an AVC denial and stops the run. Because of this, `cilium-values.yaml` sets
  `sysctlfix.enabled: false`.
- **The Kubernetes API server endpoint of the cluster is public.** This is the default of
  eksctl, and the Cilium on Ubuntu nodes blueprint uses the same setting. IAM authenticates
  each caller, and Kubernetes RBAC controls what the caller can do. The Amazon EKS User
  Guide,
  [*Cluster API server endpoint*](https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html),
  tells how to limit or remove the public access. The workloads of this blueprint use only
  ClusterIP Services, so no workload has a public endpoint.
- **This blueprint does not restrict where the networked pods can connect.** The sandbox pod
  and the ordinary pods connect to the same destinations as any pod on the cluster. The
  network-isolated sandbox pod has no network: only `lo` has an address, it has no route, and
  a DNS lookup fails, as Step 8 shows. The blueprint ships no network policy. To restrict a
  pod that has a network, see the [network policy](../../isolation/network-policy/README.md)
  blueprint.
- **The blueprint enforces three limits.** These limits are the VM boundary of each sandbox,
  the network-isolated sandbox pod, and the Pod Identity role of the Cilium operator.
- **A change to the mempool parameter needs a new AMI.** The parameter is in the build-time
  kernel parameters of the variant, not in the user data.
- **The blueprint builds and tests x86_64 only.** It does not cover aarch64 nodes or
  `runtimeClassName: confidential-sandbox`.
- **The blueprint uses a dedicated cluster.** The blueprint creates the cluster and deletes
  it at the end. It reuses no shared installation.

## Cost

One run with the default settings and no pause costs about USD 2 at list prices. This value
is an estimate:

- The `m8i.4xlarge` builder runs for about 1 hour.
- The cluster runs for about 2 hours. It has the EKS control plane, two `m8i.xlarge` nodes,
  one NAT gateway and one public IPv4 address.
- The EBS volumes and snapshots add less than USD 0.10 when `clean.sh` runs on the same day.

The fresh run took this time and cost this amount:

```text
TODO: output from the fresh run
```

Some resources continue to cost money after a failed build or a failed setup. After a
failure, run `./clean.sh` immediately. After a failed AMI build, you can also build again in
the same run, as Step 6 shows.

- After a failed build: the cluster and the system node, until you build again or run
  `./clean.sh`. Also, the builder instance and its four EBS volumes, if Packer did not
  terminate the instance. Also, the snapshots and the AMI, if Packer made them.
- After a failed setup: the EKS control plane, the NAT gateway, the public IPv4 address, the
  node instances and their EBS volumes. When the setup fails after the `ami` stage, also the
  AMI and its two snapshots.
- With `--keep-ami`: the AMI snapshots, until you delete them.

## Clean-up

In a new shell, go to the folder of this blueprint. Then set the AWS profile again:

```bash
export AWS_PROFILE=<your-profile>
```

`clean.sh` acts on the run that `setup.sh` started last. To select a different run, give
`--run-id <RUN_ID>`. First, list the resources of the run. The dry run lists only resources
with the tags of the blueprint and the run. It changes no AWS resource and no Kubernetes
object. It writes only local files in the run folder.

```bash
./clean.sh --dry-run
```

```text
TODO: output from the fresh run
```

Then delete the resources of the run. `clean.sh` asks you to type the cluster name before
it deletes a resource. For a run with no terminal, set `CLEAN_CONFIRM` to the cluster name.

```bash
./clean.sh
```

```text
TODO: output from the fresh run
```

`clean.sh` deletes the resources in this sequence:

1. The workloads, the node groups and the ENIs that Cilium created.
2. The tagged builder instances with their volumes, and the builder security group,
   instance profile and role.
3. The launch templates.
4. The AMI and its tagged snapshots, unless you give `--keep-ami`.
5. The Pod Identity association and the cluster stacks, with the VPC, the NAT gateway, the
   Elastic IP address and the roles.

Before each delete of an AWS resource, `clean.sh` reads the ownership tags of the resource
again. It deletes only a resource with the tags `ManagedBy=cilium-bottlerocket-sample` and
the `RunId` of the run. For the namespace and the RuntimeClass, it reads the label of the
blueprint again. When `clean.sh` deletes a node group or the cluster, eksctl also deletes
the resources that the node group or the cluster holds. `clean.sh` keeps the cluster when a
node group or the Pod Identity association is not a resource of the run. It also keeps the
cluster when it cannot read one of them.

After the deletes, `clean.sh` examines each resource again. When a resource remains or a lookup
fails, `clean.sh` exits with a non-zero code. After an interrupted run, `clean.sh` finds the
resources of the run through their tags and the state file, and deletes them.

To keep the AMI for a later run, give `--keep-ami`:

```bash
./clean.sh --keep-ami
```

The AMI snapshots continue to cost money until you delete them. To delete them later, run
`./clean.sh --run-id <RUN_ID>` without `--keep-ami`.

After `clean.sh` without `--keep-ami`, no resource of the run stays. `clean.sh` deletes the
cluster of this blueprint. This blueprint does not use the cluster of the hello sandbox
blueprint. To delete that cluster, follow the
[hello sandbox clean-up](../../getting-started/hello-sandbox/README.md#clean-up).
