# Build a Bottlerocket AMI with Packer and run Nitro sandbox pods on Cilium

Before you start, read the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page. This blueprint creates its own cluster, so you do not need the cluster of
the [hello sandbox](../../getting-started/hello-sandbox/README.md) blueprint. The cluster
design comes from the [Cilium on Ubuntu nodes](../cilium-ubuntu/README.md) blueprint. The
runtime checks come from the [Ubuntu AMI](../ubuntu-ami/README.md) blueprint. The commands
use files from this repository.

Clone the repository. Run the commands from the folder of this blueprint:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/setup/cilium-bottlerocket
```

For this blueprint, you also need these tools on the operator machine. `setup.sh` examines each
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

![The operator machine, with Packer and the AWS CLI, is outside the AWS Cloud frame. Its first arrow, labeled build stages, goes to AWS Systems Manager Run Command. Systems Manager has an arrow, labeled runs each stage, to the builder instance in a private subnet with no SSH. The builder instance has an arrow, labeled two EBS snapshots, to the sandbox AMI, a Bottlerocket variant. The sandbox AMI has an arrow, labeled launch template, to the Bottlerocket sandbox node. The second arrow of the operator machine, labeled eksctl and Helm, goes to the Amazon EKS cluster frame. The cluster uses the Cilium CNI in ENI mode with kube-proxy replacement. In the cluster, the Bottlerocket system node uses the stock aws-k8s-1.36 AMI. It holds the Cilium operator for ENI IPAM, the operator's Pod Identity role with the Cilium ENI actions, and CoreDNS behind a ClusterIP Service. The Pod Identity role has an arrow, labeled creates and attaches ENIs, to the Amazon EC2 ENI API. The Bottlerocket sandbox node uses the custom AMI and has a taint. It holds a Nitro sandbox pod with runtimeClassName isolated-sandbox, and an ordinary pod with the node kernel. The sandbox workload in the Nitro sandbox pod has its own guest kernel and a VPC address, an ENI secondary IP address. A two-way arrow, labeled DNS and ClusterIP Service, connects the Nitro sandbox pod and CoreDNS.](images/architecture.png)

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
| Docker buildx, the BuildKit client, on the builder ([releases](https://github.com/docker/buildx/releases)) | v0.39.1 |
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
| [`setup.sh`](setup.sh) | Creates the cluster, installs Cilium, builds the AMI, adds the node groups, examines each node and applies the pods and the Service in `deploy/` |
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
| [`packer/tools.lock`](packer/tools.lock) | The versions and digests of Packer, the plugin, Twoliter, the BuildKit client and the Rust tools |
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
| [`deploy/probe/node-probe.yaml`](deploy/probe/node-probe.yaml) | The privileged probe pod that reads the node for the node checks, with no service account token |
| [`deploy/probe/filler-pod.yaml`](deploy/probe/filler-pod.yaml) | The ordinary filler pod that `test.sh` starts on the sandbox node for the networkd and ENI checks, with no service account token |

The output blocks on this page come from one fresh run in `us-west-2`. Before that run, no
resource of the blueprint was present. The block below gives the commit and the run ID of
that run.

```text
New run 20261122t204150zca9f, state file tmp/cilium-bottlerocket/run/runs/20261122t204150zca9f/state.env
Source: commit 3465e48991bf9c0c40e9dfda3a97ba3222d88a55, dirty=no (recorded in tmp/cilium-bottlerocket/run/runs/20261122t204150zca9f/source.log)
```

The other blocks show the run ID as `<RUN_ID>`. They show placeholders, for example
`<ACCOUNT_ID>`, `<SYSTEM_NODE>` and `<VPC_ID>`, for the values of the account and the run.

**Step 1: Make the local configuration file.** `config.env.example` holds all the settings,
with placeholders and shared defaults only. Copy it to `config.local.env`, which git ignores.
Then set your account ID in the copy. Here is the part of `config.env.example` that you must
change:

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
Before any tool check or AWS call, the `preflight` stage examines the form of `CLUSTER_NAME`.
Then it examines the tools, the Region, the account, the quota and the other blueprint names.
It also examines the settings, the Helm values in `cilium-values.yaml` and the manifests in
`deploy/`.

Then it runs `scripts/10-build-ami-packer.sh check-tools`, which verifies Packer and the
plugin against the signed HashiCorp checksums. The signature must come from the key with the
full fingerprint `HASHICORP_KEY_FPR`. The stage also examines these items:

- The sandbox instance type supports Nitro Enclaves.
- The stock Bottlerocket AMI for the system node. When `SYSTEM_AMI_ID` is empty, `setup.sh`
  reads the AMI ID from the public SSM parameter of Bottlerocket. Then it writes the ID into
  `config.local.env`, so each later run uses the same AMI.

`setup.sh` creates no resource until all of these checks pass.

Here is the part of `packer/tools.lock` that pins Packer, the plugin and the HashiCorp key:

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
=== 1/8 preflight: tools, versions, account, Region, quota and names ===
config: zones, instance types, AMI IDs, slot count and volume sizes are valid
cilium values: ENI IPAM, native routing, kube-proxy replacement, socketLB.hostNamespaceOnly=true
deploy/: 8 manifests, ClusterIP only, no Ingress or network policy, no resources, pinned image
Cilium 1.20.5, chart oci://quay.io/cilium/charts/cilium (cilium.lock)
packer-tools packer=v1.16.2 plugin=1.8.4 platform=linux_amd64 signer=C874011F0AB405110D02105534365D9472D7468F
Caller: arn:aws:sts::<ACCOUNT_ID>:assumed-role/<ROLE_NAME>/<SESSION_NAME>
New run <RUN_ID>, state file tmp/cilium-bottlerocket/run/runs/<RUN_ID>/state.env
Source: commit 3465e48991bf9c0c40e9dfda3a97ba3222d88a55, dirty=no (recorded in tmp/cilium-bottlerocket/run/runs/<RUN_ID>/source.log)
VPCs: 7 used of 10
internet gateways: 7 used of 10
NAT gateways per zone: 3 used of 5
Elastic IP addresses: 3 used of 5
names: cluster nitro-cilium-bottlerocket, its stack, both launch templates, the operator and builder roles, the builder instance profile and security group, and the AMI name are free or this run's
system AMI <SYSTEM_AMI_ID>: bottlerocket-aws-k8s-1.36-x86_64-v1.70.0-59b0684a, owner alias amazon
max-pods of the system node: 110 (m8i.xlarge, 4 vCPUs: ENI formula 118, ceiling 110)
max-pods of the sandbox node: 110 (m8i.xlarge, 4 vCPUs: ENI formula 118, ceiling 110)
```

Abridged: the block shows only stage `1/8` of the output. The next steps show other stages.

Each run has a run ID. `setup.sh` keeps the state of the run in
`tmp/cilium-bottlerocket/run/runs/<RUN_ID>/` in the repository. Each stage writes the IDs
that the next stages and `clean.sh` need to `state.env` in that folder. The scripts find
the other resources by their names, their tags or the resources that hold them.

Every AWS resource of the run gets the tags `ManagedBy=cilium-bottlerocket-sample` and
`RunId=<RUN_ID>`. AWS creates some resources with no tag, for example the main route table
of the VPC. `setup.sh` adds the two tags to these resources. Before it tags a resource, it
examines the `RunId` tag of the resource. A `RunId` of another run stops the stage with
`E_TAG_SWEEP`, and `setup.sh` tags nothing. One exception applies: an AMI from an earlier run
keeps the `RunId` tag of that run, as Step 6 shows.

Packer tags the network interface of the builder when it starts the builder. When this
interface remains after the build, `clean.sh` finds it by its tags or by its ID in the state
file of the run. This includes the interface of an earlier build attempt of the run.

To stop after one stage, give `--stop-after <stage>`. To continue an interrupted run, give
its run ID:

```bash
RUN_ID=<RUN_ID> ./setup.sh
```

A continued run starts after the last stage that the run finished. It stops with
`E_RUN_RECORD` when `CLUSTER_NAME` or `AWS_REGION` is different from the value that the run
recorded. If you give
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
Error from server (NotFound): daemonsets.apps "aws-node" not found
Error from server (NotFound): daemonsets.apps "kube-proxy" not found
```

Both lines must show `NotFound`. The cluster has no `aws-node` and no `kube-proxy`.

**Step 4: Give the Cilium operator its own AWS role.** In ENI mode, the Cilium operator is
the only component that calls the EC2 API. The operator creates ENIs for the nodes and
assigns their secondary IP addresses to pods. In the `cilium` stage, an EKS Pod Identity
association gives the operator the role `<CLUSTER_NAME>-cilium-operator`. `setup.sh` creates
the association before it installs Cilium, because EKS gives the credentials to the operator
pod when the pod starts.

Before `setup.sh` records the association or installs Cilium, it examines the association and
the role. It also does this when the association already exists. These are the conditions:

- The association and the role have the tags `ManagedBy=cilium-bottlerocket-sample` and the
  `RunId` of the run.
- The trust policy of the role has one statement with no condition. Only
  `pods.eks.amazonaws.com` can assume the role, with `sts:AssumeRole` and `sts:TagSession`.
  The Amazon EKS User Guide gives this trust policy in
  [*Create IAM role with trust policy required by EKS Pod Identity*](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-role.html).
- The role has no managed policy. Its inline policies give exactly the EC2 actions of the
  policy document below.

A difference stops the stage with `E_OPERATOR_ROLE`.

The role allows only the EC2 actions in the
[required privileges](https://docs.cilium.io/en/stable/network/concepts/ipam/eni/#required-privileges)
of Cilium for this configuration. The list includes `ec2:DescribeTags`, because ENI garbage
collection is on. It has no `ec2:UnassignPrivateIpAddresses`, because the release of excess
IP addresses is off. It has no `ec2:DescribeInstances`, because the configuration uses no
instance tag filter. This is the policy document, from `eksctl/pod-identity.yaml`:

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

The node roles get only the AWS managed policies `AmazonEKSWorkerNodePolicy` and
`AmazonEC2ContainerRegistryPullOnly`, and no inline policy. The checks compare the policy
ARNs, so a policy of your account with one of these names fails the check. Neither node role
has `AmazonEKS_CNI_Policy` or the EC2 permissions of Cilium. The workload pods get no Pod
Identity association, so they get no AWS permissions.

```text
=== 6. AWS permissions and exposure ===
operator role nitro-cilium-bottlerocket-cilium-operator: association and role tagged for run <RUN_ID>, EKS Pod Identity trust only, exactly the 13 EC2 actions of the Cilium list
node role eksctl-nitro-cilium-bottlerocket-n-NodeInstanceRole-<SUFFIX_3> (sandbox): AmazonEC2ContainerRegistryPullOnly, AmazonEKSWorkerNodePolicy (AWS managed), no inline policy, no Cilium EC2 action
node role eksctl-nitro-cilium-bottlerocket-n-NodeInstanceRole-<SUFFIX_2> (system): AmazonEC2ContainerRegistryPullOnly, AmazonEKSWorkerNodePolicy (AWS managed), no inline policy, no Cilium EC2 action
  [PASS] the Cilium operator role has only the EC2 actions of the Cilium list; node roles have none
  [PASS] the only Pod Identity association is kube-system/cilium-operator
```

When both node groups exist, `test.sh` prints these lines in its step 6. The output shows
the Pod Identity association of `cilium-operator`, and the policies of the two node roles.

**Step 5: Before you add the system node, install Cilium.** Helm installs Cilium 1.20.5 before a
node joins the cluster. Because of this, the first node has a CNI when it starts. In ENI
mode, each pod gets a VPC IP address, and the traffic uses native routing with no overlay.
Cilium also replaces kube-proxy and does the Service translation in eBPF.

`socketLB.hostNamespaceOnly` is `true`, so the per-packet load balancer serves the traffic of
the sandbox pod. The Cilium on Ubuntu nodes blueprint explains why a sandbox pod needs this
value.

Here is the part of `cilium-values.yaml` that matters, without its comments. `setup.sh` gives
three more values on the command line: the cluster name, the API server host and the `RunId`
tag of the ENIs.

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

```python
def user_data(group, info):
    max_pods_value = max_pods(group)
    lines = ["[settings.kubernetes]",
             f"cluster-name = {toml_str(info['name'])}",
             f"api-server = {toml_str(info['endpoint'])}",
             f"cluster-certificate = {toml_str(info['ca'])}",
             f"cluster-dns-ip = {toml_str(info['dns'])}",
             f"max-pods = {max_pods_value}"]
    if group == "sandbox":
        lines.append(f"container-runtime-endpoint = {toml_str(CRI_PROXY_ENDPOINT)}")
    lines += ["", "[settings.kubernetes.node-labels]"]
    lines += [f"{toml_str(k)} = {toml_str(v)}" for k, v in node_labels(group).items()]
    if group == "sandbox":
        lines += ["", "[settings.kubernetes.node-taints]", f"{toml_str(SANDBOX_TAINT_KEY)} = [\"true:NoSchedule\"]"]
    return "\n".join(lines) + "\n"
```

Bottlerocket needs an explicit `max-pods` with a CNI other than the Amazon VPC CNI.
`max-pods` is the maximum number of pods of all types on a node. It is not a setting.
After the `preflight` stage, `setup.sh` calculates it for each node group from one
`aws ec2 describe-instance-types` result of the instance type:

- The ENI formula is ENIs x (IPv4 addresses per ENI - 1) + 2.
- The ceiling is 110 for less than 30 vCPUs, and 250 for 30 vCPUs or more.
- `max-pods` is the lower of the two values.

The ceiling is the cap that Amazon EKS sets for a managed node group without a custom AMI.
The Amazon EKS User Guide gives it in the section "How maxPods is determined" of
[*Choose an optimal Amazon EC2 node instance type*](https://docs.aws.amazon.com/eks/latest/userguide/choosing-instance-type.html#max-pods-precedence).
The guide gives 110 for less than 30 vCPUs and 250 for more than 30 vCPUs. `setup.sh` uses
250 for exactly 30 vCPUs.

An `m8i.xlarge` instance has 4 vCPUs and 4 ENIs, with 30 IPv4 addresses for each ENI. The ENI
formula gives 4 x 29 + 2 = 118, and the ceiling is 110. Because of this, with the default
instance types, `max-pods` is 110 on each node.

`setup.sh` records the formula, the ceiling and `max-pods` in `state.env`, and prints one line
for each node group. A continued run stops with `E_MAX_PODS` when the instance type gives a
different value. When the system node joins, `setup.sh` examines its pod capacity. A capacity
that is not equal to `max-pods` stops the run with `E_MAX_PODS`.

It is possible that a launch template or a node group of the run already exists, for example
after an interrupted run. `setup.sh` uses such a launch template only when it has the tags of
the run and its version 1 is equal to the rendered data. A field that the blueprint does not
set also stops the stage with `E_LAUNCH_TEMPLATE`. Examples of these fields are a key pair, a
network interface, a security group and an instance profile.

`setup.sh` uses such a node group only when it meets all of these conditions:

- It has the tags of the run, and it uses version 1 of the launch template of the run.
- It has exactly one node, the rendered labels and taints, and no SSH access.
- Its only subnet is the private subnet of the run VPC in the first zone of
  `AVAILABILITY_ZONES`. The `cluster` stage records this subnet, and `setup.sh` reads it again
  to verify the run VPC, that zone and `MapPublicIpOnLaunch` false.
- Its node role has the tags of the run, only the two AWS managed policies of the node roles,
  and no inline policy.

Otherwise, the stage stops with `E_RENDER_NODEGROUP` before it makes a change in the cluster.

Before the AMI build starts, `setup.sh` examines the system node and the Cilium operator.
Then it tags the resources that AWS created for the cluster and the system node group with
no tag. It also examines the tags of each resource class of the run.

```text
=== 4/8 the system node: stock Bottlerocket v1.70.0 aws-k8s-1.36, then the Cilium operator ===
system launch template: the rendered data (IMDSv2 hop limit 1, TOML settings)
2026-11-22 20:57:03 [ℹ]  will use version 1.36 for new nodegroup(s) based on control plane version
2026-11-22 20:57:05 [ℹ]  nodegroup "system" will use "" [AmazonLinux2023/1.36]
2026-11-22 20:57:06 [ℹ]  1 nodegroup (system) was included (based on the include/exclude rules)
2026-11-22 20:57:06 [ℹ]  will create a CloudFormation stack for each of 1 managed nodegroups in cluster "nitro-cilium-bottlerocket"
2026-11-22 20:57:06 [!]  "aws-node" was not found
2026-11-22 20:57:06 [ℹ]
2 sequential tasks: { fix cluster compatibility, 1 task: { 1 task: { create managed nodegroup "system" } }
}
2026-11-22 20:57:06 [ℹ]  checking cluster stack for missing resources
2026-11-22 20:57:06 [ℹ]  cluster stack has all required resources
2026-11-22 20:57:07 [ℹ]  building managed nodegroup stack "eksctl-nitro-cilium-bottlerocket-nodegroup-system"
2026-11-22 20:57:07 [ℹ]  deploying stack "eksctl-nitro-cilium-bottlerocket-nodegroup-system"
2026-11-22 20:57:07 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-system"
2026-11-22 20:57:37 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-system"
2026-11-22 20:58:29 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-system"
2026-11-22 20:59:50 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-system"
2026-11-22 20:59:50 [ℹ]  no tasks
2026-11-22 20:59:50 [✔]  created 0 nodegroup(s) in cluster "nitro-cilium-bottlerocket"
2026-11-22 20:59:51 [ℹ]  nodegroup "system" has 1 node(s)
2026-11-22 20:59:51 [ℹ]  node "<SYSTEM_NODE>" is ready
2026-11-22 20:59:51 [ℹ]  waiting for at least 1 node(s) to become ready in "system"
2026-11-22 20:59:51 [ℹ]  nodegroup "system" has 1 node(s)
2026-11-22 20:59:51 [ℹ]  node "<SYSTEM_NODE>" is ready
2026-11-22 20:59:51 [✔]  created 1 managed nodegroup(s) in cluster "nitro-cilium-bottlerocket"
2026-11-22 20:59:51 [ℹ]  checking security group configuration for all nodegroups
2026-11-22 20:59:51 [ℹ]  all nodegroups have up-to-date cloudformation templates
node/<SYSTEM_NODE> condition met
daemon set "cilium" successfully rolled out
deployment "cilium-operator" successfully rolled out
max-pods: derived 110 (ENI formula 118, ceiling 110) equals node capacity pods (110)
system node: Bottlerocket OS 1.70.0 (aws-k8s-1.36), kubelet v1.36.5-eks-577a51e, kernel 6.18.62
operator role nitro-cilium-bottlerocket-cilium-operator: association and role tagged for run <RUN_ID>, EKS Pod Identity trust only, exactly the 13 EC2 actions of the Cilium list
node role eksctl-nitro-cilium-bottlerocket-n-NodeInstanceRole-<SUFFIX_2> (system): AmazonEC2ContainerRegistryPullOnly, AmazonEKSWorkerNodePolicy (AWS managed), no inline policy, no Cilium EC2 action
/sys/kernel/btf/vmlinux: 5178250 bytes
tagged main-route-table <ROUTE_TABLE_ID_4>
tagged network-acl <ACL_ID_1>
tagged default-security-group <SG_ID_3>
tagged cluster-security-group <SG_ID_4>
tagged control-plane-eni <ENI_ID_2>
tagged control-plane-eni <ENI_ID_1>
tagged nat-gateway-eni <ENI_ID_3>
tagged autoscaling-group eks-system-<NODEGROUP_UUID_2>
tagged eks-launch-template-copy <LAUNCH_TEMPLATE_ID_1>
tagged node-instance-profile eks-<NODEGROUP_UUID_2>
tag sweep: tagged 10 resources
cfn-stack: 3
eks-cluster: 1
eks-addon: 2
vpc: 1
subnet: 4
route-table: 3
main-route-table: 1
network-acl: 1
internet-gateway: 1
nat-gateway: 1
elastic-ip: 1
security-group: 2
default-security-group: 1
cluster-security-group: 1
control-plane-eni: 2
nat-gateway-eni: 1
iam-role: 3
pod-identity-association: 1
cilium-eni: 0
launch-template: 1
eks-nodegroup: 1
autoscaling-group: 1
eks-launch-template-copy: 1
node-instance-profile: 1
node-instance: 1
node-volume: 2
node-eni: 1
builder-security-group: 0
builder-role: 0
builder-instance-profile: 0
builder-instance: 0
builder-volume: 0
builder-eni: 0
ami: 0
ami-snapshot: 0
tag audit: 39 resources in 35 classes, each with both tags
The system node <SYSTEM_NODE> and the Cilium operator are healthy. The AMI build can start.
```

Run this command to see the Cilium operator pod:

```bash
kubectl --context cb-<RUN_ID> -n kube-system get pods -o wide -l io.cilium/app=operator,name=cilium-operator
```

```text
NAME                             READY   STATUS    RESTARTS   AGE   IP             NODE                                         NOMINATED NODE   READINESS GATES
cilium-operator-d6d4b8b8-cfqtl   1/1     Running   0          28m   <PRIVATE_IP_2>   <SYSTEM_NODE>   <none>           <none>
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

When the build script stops before Packer starts, it deletes only the parts that it created.
Before each delete, it reads the part and its two tags again. It leaves a part with other tags,
or a part that it cannot read, for `clean.sh`. After the deletes, it reads each part again.
Then it stops with `E_UNDONE`. When a part remains, or when it cannot read a part, it stops
with `E_UNDO_LEFTOVER`.

Each Packer `shell-local` stage runs `scripts/packer-stage.sh` on the operator machine. The
`bind` stage runs on the operator machine only. For each later stage except `upload`, the
stage driver sends one AWS Systems Manager Run Command to the builder. The `upload` stage
sends one command for each part of the upload, and one more command to unpack the parts.
The stage driver waits for each command to stop, and it continues only when the status is
`Success`. Here is the first stage, from `packer/bottlerocket.pkr.hcl`:

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
| `bind` | Operator machine | Examines the builder instance and its network interfaces with their two tags, then waits until Systems Manager shows the instance as `Online` |
| `upload` | Builder | Copies one archive of `variant/`, `packages/`, `scripts/builder/` and `packer/tools.lock` to the builder, and verifies its SHA-256 |
| `host-setup` | Builder | Formats and mounts the work volume. Installs Docker, the BuildKit client, the Rust tools, cargo-make and Twoliter, and verifies each pinned download against `packer/tools.lock`. |
| `fetch-verify` | Builder | Clones Bottlerocket, examines the tag and the commit against the lock file, then downloads and verifies every input |
| `overlay` | Builder | Adds the variant and the `nitro-sandbox` package to the clone, and writes `SANDBOX_SLOTS` as `pcie_slots` into `nitro-sandbox.toml` |
| `build` | Builder | Builds the variant with Twoliter. Then it records the use of each partition. It stops with `E_ROOT_FIT` when the root file system does not fit its partition. |
| `write-images` | Builder | Writes the OS image and the data image to two attached EBS volumes. Then it reads each volume again to verify the write. |
| `verify-root` | Builder | Verifies the partition bounds and mounts the root partition read-only. Then it verifies the SHA-256 of each file that `packages/sources.lock` installs, which includes the guest image pair. It also examines `pcie_slots` in `nitro-sandbox.toml` and the containerd drop-in. Last, it examines that the root partition holds `/usr/bin/mkfs.erofs` and `libzstd`, and that `mkfs.erofs -V` lists the `zstd` compressor. |
| `release` | Builder | Writes all cached data to the disks. Then it examines that the OS volume and the data volume are not mounted, and flushes their buffers. |

Before the build uses a downloaded file, it compares the SHA-256 of the file with the lock
file. For the runtime archive, it also verifies the ECDSA signature of the downloaded
`SHA256SUM` with `nitro-sandboxes-runtime-v1.pub`. A changed checksum or a changed signature
stops the build. The Amazon EKS User Guide,
[*Download and verify the runtime binaries*](https://docs.aws.amazon.com/eks/latest/userguide/sandboxing-download-binaries.html),
gives the signature procedure.

The run folder keeps this record of the build in `evidence/ami-build.txt`:

```text
overlay archive=24042 base64=32056 chunks=1 chunk_max=48000 sha256=bd9c55246592234a179a6e2ba0985f903c327d1d1f68ef7e90080ffedc7556da
packer-tools packer=v1.16.2 plugin=1.8.4 platform=linux_amd64 signer=C874011F0AB405110D02105534365D9472D7468F
builder-sg inbound_rules=0 egress=tcp/443 tags=ok
builder-volumes count=4 attached=builder tags=ok
builder-enis count=1 attached=builder tags=ok
builder key_name=none public_ip=none inbound_rules=0 http_tokens=required hop_limit=1
packer-stage bind builder=bound ssm=Online
packer-stage upload-1 command_id=7438cb6b-918b-4792-832c-09efa7259b0a
packer-stage upload-1 command_id=7438cb6b-918b-4792-832c-09efa7259b0a status=Success
packer-stage upload-unpack command_id=d9a87cb0-a9cc-4dbd-9a8b-98461dcff1b5
packer-stage upload-unpack command_id=d9a87cb0-a9cc-4dbd-9a8b-98461dcff1b5 status=Success
packer-stage host-setup command_id=80531213-e8a7-4541-bffe-3ff97e88110d
packer-stage host-setup command_id=80531213-e8a7-4541-bffe-3ff97e88110d status=Success
packer-stage fetch-verify command_id=6233196c-e7b0-49af-be81-cde06a880bf6
packer-stage fetch-verify command_id=6233196c-e7b0-49af-be81-cde06a880bf6 status=Success
packer-stage overlay command_id=4f74faed-a51b-4e40-92ee-c1b57526b8f0
packer-stage overlay command_id=4f74faed-a51b-4e40-92ee-c1b57526b8f0 status=Success
packer-stage build command_id=e1197a88-fb5a-4f46-9650-5853370691c7
packer-stage build command_id=e1197a88-fb5a-4f46-9650-5853370691c7 status=Success
partition-use BOOT-A bytes_used=17727488 bytes_total=30963712 percent=57
partition-use ROOT-A bytes_used=479629312 bytes_total=1929379840 percent=24
root-fit ROOT-A used=479629312 total=1929379840 ok
packer-stage write-images command_id=32f46fb6-5a93-44a8-b9ee-6d1775830615
packer-stage write-images command_id=32f46fb6-5a93-44a8-b9ee-6d1775830615 status=Success
packer-stage verify-root command_id=c2985e0d-d6d0-4eb8-a6cf-fbd0fe5dac05
packer-stage verify-root command_id=c2985e0d-d6d0-4eb8-a6cf-fbd0fe5dac05 status=Success
packer-stage release command_id=059366f5-bebe-4434-80ff-1fac020b0dfe
packer-stage release command_id=059366f5-bebe-4434-80ff-1fac020b0dfe status=Success
builder-gone instance=terminated volumes=absent sg=absent profile=absent role=absent
manifest builds=1 builder_type=amazon-ebssurrogate sha256=f311ecf2ee35eecd9c22a89feaf49440ecf448449b82bcedbada279619942821
image x86_64 hvm ena=true sriov=simple imds=v2.0 root=/dev/xvda data=/dev/xvdb gp3 boot_mode=uefi-preferred uefi_data=none snapshots=2 SandboxSlots=20
```

The output shows the key pair, the public IP address and the inbound rule count of the
builder. It also shows the command ID and the status of each Run Command.

The build clones `bottlerocket` at `v1.70.0`, as the Amazon EKS User Guide page
[*Build a custom Bottlerocket AMI variant for Amazon EKS*](https://docs.aws.amazon.com/eks/latest/userguide/bottlerocket-custom-variant.html)
shows. The variant `aws-k8s-1.36-nitro-sandbox` is different from `aws-k8s-1.36` in four
items only:

- The variant name.
- The `nitro-sandbox` package.
- The OS image size, `os-image-size-gib = 4`, from a measured build. Twoliter gives the root
  partition 460 MiB for each GiB of this value. The root file system of the build uses
  457 MiB. With 4 GiB, the root partition is 1,840 MiB, and it is 25% full. The Bottlerocket
  default of 2 GiB gives a root partition of 920 MiB, with 463 MiB free. The larger value
  leaves space for a larger guest image.
- The kernel parameter `nitro_enclaves.mempool=95%-1G`. The kernel reserves the enclave
  memory early in the boot. A value in the user data arrives after that point, so the
  parameter is in the build-time kernel parameters of the variant.

```text
--- variants/aws-k8s-1.36/Cargo.toml
+++ variants/aws-k8s-1.36-nitro-sandbox/Cargo.toml
@@ -1,7 +1,7 @@
 [package]
-# This is the aws-k8s-1.36 variant. "." is not allowed in crate names, but we
+# This is the aws-k8s-1.36-nitro-sandbox variant. "." is not allowed in crate names, but we
 # don't use this crate name anywhere.
-name = "aws-k8s-1_36"
+name = "aws-k8s-1_36-nitro-sandbox"
 version = "0.1.0"
 edition = "2021"
 publish = false
@@ -16,6 +16,11 @@
 erofs-root-partition = true
 systemd-networkd = true
 external-kmod-development = false
+
+# Twoliter gives ROOT-A 460 MiB for each GiB of this value: 4 gives 1,840 MiB. A measured build
+# used 479,363,072 bytes of ROOT-A (about 25 percent of 1,840 MiB).
+[package.metadata.build-variant.image-layout]
+os-image-size-gib = 4

 [package.metadata.build-variant]
 included-packages = [
@@ -36,6 +41,8 @@
     "digestion-image-verifier",
     "notation-image-verifier",
     "thar-be-image-verifiers",
+# nitro sandbox
+    "nitro-sandbox",
 ]
 kernel-parameters = [
     "console=tty0",
@@ -43,6 +50,7 @@
     "net.ifnames=0",
     "netdog.default-interface=eth0:dhcp4,dhcp6?",
     "quiet",
+    "nitro_enclaves.mempool=95%-1G",
 ]

 [lib]
@@ -52,3 +60,4 @@
 settings-defaults = { path = "../../packages/settings-defaults" }
 settings-plugins = { path = "../../packages/settings-plugins" }
 settings-migrations = { path = "../../packages/settings-migrations" }
+nitro-sandbox = { path = "../../packages/nitro-sandbox" }
register-variant variant=aws-k8s-1.36-nitro-sandbox slots=20 os_image_gib=4 registrations=5 ok
register-variant cargo-lock added=aws-k8s-1_36-nitro-sandbox,nitro-sandbox ok
builder: nitro-sandbox.toml pcie_slots      = 20
builder: overlay ok
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

The package also requires `erofs-utils` from the core kit, so the image has `mkfs.erofs`. The
shim makes the EROFS file system of each container with `mkfs.erofs` and zstd.

The package installs the release binaries with no change. The package spec stops the strip
step of the Bottlerocket SDK, so the `verify-root` stage can compare each installed file
with `packages/sources.lock`.

Here is the containerd drop-in, `variant/packages/nitro-sandbox/50-nitro-sandbox.toml`,
without its first comment lines. The containerd configuration of Bottlerocket imports
`/etc/containerd/config.d/*.toml`:

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
{
    "Images": [
        {
            "PlatformDetails": "Linux/UNIX",
            "UsageOperation": "RunInstances",
            "BlockDeviceMappings": [
                {
                    "Ebs": {
                        "DeleteOnTermination": true,
                        "SnapshotId": "<SNAPSHOT_ID_1>",
                        "VolumeSize": 4,
                        "VolumeType": "gp3",
                        "Encrypted": false
                    },
                    "DeviceName": "/dev/xvda"
                },
                {
                    "Ebs": {
                        "DeleteOnTermination": true,
                        "SnapshotId": "<SNAPSHOT_ID_2>",
                        "VolumeSize": 18,
                        "VolumeType": "gp3",
                        "Encrypted": false
                    },
                    "DeviceName": "/dev/xvdb"
                }
            ],
            "Description": "Bottlerocket aws-k8s-1.36-nitro-sandbox (cilium-bottlerocket sample)",
            "EnaSupport": true,
            "Hypervisor": "xen",
            "Name": "nitro-cilium-bottlerocket-<RUN_ID>-aws-k8s-1.36-nitro-sandbox",
            "RootDeviceName": "/dev/xvda",
            "RootDeviceType": "ebs",
            "SriovNetSupport": "simple",
            "Tags": [
                {
                    "Key": "BottlerocketRelease",
                    "Value": "v1.70.0"
                },
                {
                    "Key": "RunId",
                    "Value": "<RUN_ID>"
                },
                {
                    "Key": "Name",
                    "Value": "nitro-cilium-bottlerocket-<RUN_ID>-aws-k8s-1.36-nitro-sandbox"
                },
                {
                    "Key": "GuestImage",
                    "Value": "1.36.5/2026-11-06"
                },
                {
                    "Key": "SandboxSlots",
                    "Value": "20"
                },
                {
                    "Key": "NitroRuntime",
                    "Value": "0.1.4274.0"
                },
                {
                    "Key": "Variant",
                    "Value": "aws-k8s-1.36-nitro-sandbox"
                },
                {
                    "Key": "Firecracker",
                    "Value": "v1.18.0"
                },
                {
                    "Key": "ManagedBy",
                    "Value": "cilium-bottlerocket-sample"
                }
            ],
            "VirtualizationType": "hvm",
            "BootMode": "uefi-preferred",
            "ImdsSupport": "v2.0",
            "DeregistrationProtection": "disabled",
            "FreeTierEligible": true,
            "ImageId": "<SANDBOX_AMI_ID>",
            "ImageLocation": "<ACCOUNT_ID>/nitro-cilium-bottlerocket-<RUN_ID>-aws-k8s-1.36-nitro-sandbox",
            "State": "available",
            "OwnerId": "<ACCOUNT_ID>",
            "CreationDate": "2026-11-22T21:18:50.000Z",
            "Public": false,
            "Architecture": "x86_64",
            "ImageType": "machine"
        }
    ]
}
```

The output shows `x86_64`, `hvm`, ENA, SR-IOV `simple` and IMDSv2 required. It shows the root
device `/dev/xvda` and the data device `/dev/xvdb`, both gp3. It shows the boot mode
`uefi-preferred`. `describe-images` does not show the UEFI data. The build script examines
it and prints this line for the AMI:

```text
sandbox AMI <SANDBOX_AMI_ID>: x86_64, hvm, ENA, SR-IOV simple, IMDSv2, uefi-preferred with no UEFI data, /dev/xvda and /dev/xvdb gp3, two tagged snapshots, SandboxSlots=20
```

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
builder instance <BUILDER_INSTANCE_ID>: gone
builder security-group <BUILDER_SG_ID>: gone
builder instance-profile nitro-cilium-bottlerocket-<RUN_ID>-builder: gone
builder iam-role nitro-cilium-bottlerocket-<RUN_ID>-builder: gone
builder volume <VOLUME_ID_5>: gone
builder volume <VOLUME_ID_6>: gone
builder volume <VOLUME_ID_7>: gone
builder volume <VOLUME_ID_8>: gone
```

**Build again after a failed AMI build.** The build script runs Packer with
`-on-error=cleanup`. After a failed build, Packer terminates the builder, and EC2 deletes
its volumes. The build script then deletes the builder security group, the instance profile
and the role. `setup.sh` stops with `E_AMI_BUILD`, and the cluster and the system node stay.

The error message names two paths: build again in the same run, or delete the full run with
`./clean.sh`. To keep the cluster, build again in the same run:

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
and a `SandboxSlots` tag equal to `SANDBOX_SLOTS`, and it must pass the AMI checks. The AMI
and its two snapshots must have the same `RunId` tag, the `RunId` of the earlier run. Because
the AMI keeps this tag, `clean.sh` of the new run does not delete the AMI or its snapshots.

**Step 7: Add a sandbox node that passes the node checks.** In the `sandbox-node` stage,
`setup.sh` adds the sandbox node group with exactly one node. The launch template enables
Nitro Enclaves. The TOML user data sets `settings.kubernetes.container-runtime-endpoint` to
`unix:///run/nitro-sandbox/cri-proxy.sock`. `SANDBOX_DATA_VOLUME_GIB` sets the size of the
data volume `/dev/xvdb` of the sandbox node, and EBS encrypts the volume. The rules of Step 5
for a launch template or a node group that already exists also apply to the sandbox node
group.

The sandbox node has two different pod limits. `max-pods` bounds all pods on the node, as
Step 5 shows. The slot pool bounds only the sandbox pods:

- The Nitro Enclaves driver gives the slot pool of the instance in
  `/sys/class/misc/nitro_enclaves/pcie_slots_total`. On `m8i.xlarge`, the pool has 20 slots.
- `SANDBOX_SLOTS` sets the slot count that the runtime asks for. The build writes the value as
  `pcie_slots` in `nitro-sandbox.toml` of the AMI. The AMI and its snapshots record it in the
  `SandboxSlots` tag.
- The runtime asks the driver for that count, but for no more than the pool. Then the runtime
  advertises the slots that it got as the node resource `eks.amazonaws.com/nitro-sandbox`.

The runtime logs both counts in the journal of the node. For example, with `pcie_slots = 58`
on `m8i.xlarge`, the journal has the line `advertising 20 nitro-sandbox slots (target=58)`.
`target` is the `pcie_slots` value of the configuration. The first number is the slot count
that the node advertises, and the pool of 20 slots limits it. The default
`SANDBOX_SLOTS="20"` is the full pool of `m8i.xlarge`.

Each sandbox pod uses one unit of `eks.amazonaws.com/nitro-sandbox`, from the `overhead` of
the `isolated-sandbox` RuntimeClass. The scheduler places a sandbox pod on the node only when a
unit is free, whatever the value of `max-pods`. Because of this, at most 20 sandbox pods and
at most 110 pods in total run on one `m8i.xlarge` node. The sandbox pods count in both limits.

Here is the slot count in `config.env.example`, with its comment on the two limits:

```bash
# The sandbox slot count: the number of sandbox pods that one sandbox node can run. It sets
# pcie_slots in the runtime configuration of the AMI, and the AMI records it in its SandboxSlots
# tag. It must not be above the slot pool of the instance, which the Nitro Enclaves driver gives
# in /sys/class/misc/nitro_enclaves/pcie_slots_total (20 on m8i.xlarge). setup.sh and test.sh
# stop when the driver's pcie_slots or the node's eks.amazonaws.com/nitro-sandbox capacity is not
# this value, or when it is above pcie_slots_total.
#
# max-pods is not a setting. setup.sh derives it for each node from the instance type: the ENI
# formula ENIs x (IPv4 addresses per ENI - 1) + 2, capped at 110 below 30 vCPUs and at 250 from
# 30 vCPUs, as the Amazon EKS max-pods calculator does (m8i.xlarge: formula 118, ceiling 110,
# max-pods 110). Bottlerocket needs an explicit max-pods with a CNI other than the Amazon VPC CNI.
SANDBOX_SLOTS="20"
```

Here is the part of `launch_template_data` in `scripts/lib/cb_render.py` that enables Nitro
Enclaves on the sandbox node:

```python
    if group == "sandbox":
        data["EnclaveOptions"] = {"Enabled": True}
```

Before `setup.sh` adds the sandbox node group, it examines the `max-pods` value in the launch
template. A value that is not equal to `max-pods` stops the run with `E_MAX_PODS`.

In the `node-checks` stage, `setup.sh` examines the sandbox node before a sandbox pod starts.
It reads the node object, the kubelet configuration and the output of a privileged probe pod
on the node. `setup.sh` deletes the probe pod by its exact name. These are the checks:

- The OS image is Bottlerocket v1.70.0.
- `/sys/kernel/btf/vmlinux` is present.
- The kernel command line has `nitro_enclaves.mempool=95%-1G`, and the kernel log shows the
  `nitro_enclaves` memory reservation.
- `kubeconfig_path` in `nitro-sandbox.toml` is `/etc/kubernetes/kubelet/kubeconfig`, the
  kubeconfig of kubelet on Bottlerocket, and the file is on the node.
- `mkfs.erofs` on the node has the zstd compressor.
- The kubelet runtime endpoint is `unix:///run/nitro-sandbox/cri-proxy.sock`.
- The merged containerd configuration contains the `isolated-sandbox` handler and
  `discard_unpacked_layers = false`.
- The allocatable `eks.amazonaws.com/nitro-sandbox` value is more than 0.
- `pcie_slots` in `nitro-sandbox.toml` on the node is equal to `SANDBOX_SLOTS`.
- The pod capacity of the node is equal to `max-pods`.
- `SANDBOX_SLOTS` is not more than `pcie_slots_total`. The driver `pcie_slots` value and the
  node capacity `eks.amazonaws.com/nitro-sandbox` are both equal to `SANDBOX_SLOTS`. When the
  journal has the `advertising` line of the runtime, its slot count is also equal to
  `SANDBOX_SLOTS`. A different value stops the run with `E_SLOTS`.
- SELinux is in enforcing mode.
- The kernel log and the journal have no SELinux denial since the boot of the node.
- dm-verity verifies the root file system.

```text
=== 6/8 the sandbox node group: exactly one node on the built AMI, Nitro Enclaves on ===
density: SANDBOX_SLOTS=20 equals AMI tag SandboxSlots
sandbox launch template: the rendered data (IMDSv2 hop limit 1, TOML settings)
max-pods: derived 110 (ENI formula 118, ceiling 110) equals launch template max-pods (110)
2026-11-22 21:19:46 [ℹ]  will use version 1.36 for new nodegroup(s) based on control plane version
2026-11-22 21:19:48 [ℹ]  nodegroup "sandbox" will use "" [AmazonLinux2023/1.36]
2026-11-22 21:19:49 [ℹ]  1 existing nodegroup(s) (system) will be excluded
2026-11-22 21:19:49 [ℹ]  1 nodegroup (sandbox) was included (based on the include/exclude rules)
2026-11-22 21:19:49 [ℹ]  will create a CloudFormation stack for each of 1 managed nodegroups in cluster "nitro-cilium-bottlerocket"
2026-11-22 21:19:49 [!]  "aws-node" was not found
2026-11-22 21:19:49 [ℹ]
2 sequential tasks: { fix cluster compatibility, 1 task: { 1 task: { create managed nodegroup "sandbox" } }
}
2026-11-22 21:19:49 [ℹ]  checking cluster stack for missing resources
2026-11-22 21:19:50 [ℹ]  cluster stack has all required resources
2026-11-22 21:19:50 [ℹ]  building managed nodegroup stack "eksctl-nitro-cilium-bottlerocket-nodegroup-sandbox"
2026-11-22 21:19:50 [ℹ]  deploying stack "eksctl-nitro-cilium-bottlerocket-nodegroup-sandbox"
2026-11-22 21:19:50 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-sandbox"
2026-11-22 21:20:21 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-sandbox"
2026-11-22 21:21:05 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-sandbox"
2026-11-22 21:22:21 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-sandbox"
2026-11-22 21:22:21 [ℹ]  no tasks
2026-11-22 21:22:21 [✔]  created 0 nodegroup(s) in cluster "nitro-cilium-bottlerocket"
2026-11-22 21:22:21 [ℹ]  nodegroup "sandbox" has 1 node(s)
2026-11-22 21:22:21 [ℹ]  node "<SANDBOX_NODE>" is ready
2026-11-22 21:22:21 [ℹ]  waiting for at least 1 node(s) to become ready in "sandbox"
2026-11-22 21:22:21 [ℹ]  nodegroup "sandbox" has 1 node(s)
2026-11-22 21:22:21 [ℹ]  node "<SANDBOX_NODE>" is ready
2026-11-22 21:22:21 [✔]  created 1 managed nodegroup(s) in cluster "nitro-cilium-bottlerocket"
2026-11-22 21:22:22 [ℹ]  checking security group configuration for all nodegroups
2026-11-22 21:22:22 [ℹ]  all nodegroups have up-to-date cloudformation templates
node/<SANDBOX_NODE> condition met
daemon set "cilium" successfully rolled out
Exactly one sandbox node joined: <SANDBOX_NODE>

=== 7/8 the sandbox node checks, before any sandbox pod starts ===
sandbox node: Bottlerocket OS 1.70.0 (aws-k8s-1.36-nitro-sandbox), kubelet v1.36.5-eks-577a51e, kernel 6.18.62
/sys/kernel/btf/vmlinux: 5178250 bytes
kernel command line has nitro_enclaves.mempool=95%-1G; driver: nitro_enclaves: CMA pool: 14192 MiB reserved in 16 region(s), 14192 MiB requested
kubeconfig_path /etc/kubernetes/kubelet/kubeconfig: present on the node (577 bytes)
mkfs.erofs 1.9.4 on the host: compressors deflate, zstd
kubelet containerRuntimeEndpoint: unix:///run/nitro-sandbox/cri-proxy.sock
merged containerd config: isolated-sandbox handler with io.containerd.nitro-sandbox.v2, discard_unpacked_layers = false
allocatable eks.amazonaws.com/nitro-sandbox: 20
density: SANDBOX_SLOTS=20 equals node pcie_slots
max-pods: derived 110 (ENI formula 118, ceiling 110) equals node capacity pods (110)
slots: SANDBOX_SLOTS=20, pcie_slots_total=20, driver pcie_slots=20, node capacity eks.amazonaws.com/nitro-sandbox=20, max_pcie_devices=32, runtime: advertising 20 (target=20)
SELinux: enforcing
SELinux audit: no AVC denial in the kernel log or the journal
dm-verity: / is the read-only dm-0 'root' (device 252:0), created with verity on the kernel command line
tagged autoscaling-group eks-sandbox-<NODEGROUP_UUID_1>
tagged eks-launch-template-copy <LAUNCH_TEMPLATE_ID_2>
tagged node-instance-profile eks-<NODEGROUP_UUID_1>
tag sweep: tagged 3 resources
cfn-stack: 4
eks-cluster: 1
eks-addon: 2
vpc: 1
subnet: 4
route-table: 3
main-route-table: 1
network-acl: 1
internet-gateway: 1
nat-gateway: 1
elastic-ip: 1
security-group: 2
default-security-group: 1
cluster-security-group: 1
control-plane-eni: 2
nat-gateway-eni: 1
iam-role: 4
pod-identity-association: 1
cilium-eni: 0
launch-template: 2
eks-nodegroup: 2
autoscaling-group: 2
eks-launch-template-copy: 2
node-instance-profile: 2
node-instance: 2
node-volume: 4
node-eni: 2
builder-security-group: 0
builder-role: 0
builder-instance-profile: 0
builder-instance: 0
builder-volume: 0
builder-eni: 0
ami: 1
ami-snapshot: 2
tag audit: 53 resources in 35 classes, each with both tags
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
and `test.sh` then exits with a non-zero code. The `node-checks` stage of `setup.sh` runs the
same audit before a sandbox pod starts. `test.sh` runs the audit again at its end, so the audit
covers the time from the boot of the node to the end of `test.sh`.

```text
SELinux: enforcing
  [PASS] SELinux is enforcing
SELinux domain runtime_t: CRI proxy (1) and shim (2): system_u:system_r:runtime_t:s0:c0.c1023
  [PASS] the shim and the CRI proxy run in the SELinux domain runtime_t
SELinux audit: no AVC denial in the kernel log or the journal
  [PASS] no SELinux denial in the kernel log or the journal since boot (fails closed)
...
=== 7. the sandbox node at the end: the Cilium ENIs since capture A, and the SELinux audit ===
...
SELinux audit: no AVC denial in the kernel log or the journal
  [PASS] no SELinux denial on the sandbox node from its boot to the end of test.sh (fails closed)
```

Abridged: the block shows the SELinux lines of steps 3 and 7 of `test.sh`. The output shows
the SELinux mode, the domain of the shim and the CRI proxy, and the audit result.

`test.sh` also shows that systemd-networkd does not manage the Cilium ENIs. Cilium gives
pods the secondary IP addresses of `eth0` first. Cilium attaches a second ENI, `eth1`, only
after the pods use the addresses of `eth0`. On `m8i.xlarge`, each ENI has 30 IPv4 addresses,
so `eth0` has 29 secondary addresses. Because of this, `test.sh` does these steps:

1. It starts ordinary filler pods on the sandbox node, one at a time, with exact names
   `cb-filler-<n>-<RUN_ID>`. It stops when the CiliumNode of the sandbox node lists a second
   ENI and a pod of the node has an address of that ENI. It starts 40 filler pods at most,
   and never more than the free pods under `max-pods`.
2. Immediately, it captures each ENI after `eth0` (capture A). The capture has the
   systemd-networkd link state, and the links, addresses, routes and rules on the node.
3. It examines capture A. systemd-networkd must list each ENI after `eth0` as `unmanaged`.
   The ENI gets no address or route from DHCP or a router advertisement. Each IPv4
   address is an address of that ENI in the CiliumNode. The routes are the routes that Cilium
   sets for that ENI, and each rule into its table is from an address of the ENI.
4. At the end of `test.sh`, it makes capture B, with the filler pods still on the node. It
   examines capture B in the same way. The addresses, routes and rules of each ENI after
   `eth0` must be the same in capture A and capture B.
5. It deletes each filler pod by its exact name. Then it verifies that no filler pod remains.
   If `test.sh` cannot delete a filler pod, the check fails.

The filler pods stay until capture B, because Cilium removes the rule of a pod when `test.sh`
deletes the pod. In one run, Cilium attached `eth1` after 24 filler pods. The limit of 40
gives a margin over that count. When no pod gets an address of a second ENI, the check fails
with `E_NETWORKD_ENI`.

The filler pods set no CPU or memory requests or limits. They get no service account token,
and they use the `RuntimeDefault` seccomp profile. Their container has no capabilities and a
read-only root file system.

```text
filler pods started: 24 (limit 40); ENIs in the CiliumNode of <SANDBOX_NODE>: 2
Cilium ENIs as Cilium sets them: eth1 unmanaged, table 11 via <PRIVATE_IP_12>, 1 endpoint rule(s)
  [PASS] capture A: systemd-networkd leaves each ENI after eth0 unmanaged; no DHCP or RA address or route, only the routes and rules of Cilium
```

The output shows the number of filler pods and the ENIs of the node. It also shows capture A,
where systemd-networkd lists each Cilium ENI as `unmanaged`. Each ENI has only the addresses,
routes and rules that Cilium sets. The `test.sh` output of Step 8 shows the result of
capture B.

To compare the sandbox node with the system node, list the nodes:

```bash
kubectl --context cb-<RUN_ID> get nodes -o wide
```

```text
NAME                                         STATUS   ROLES    AGE     VERSION               INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                                              KERNEL-VERSION    CONTAINER-RUNTIME
<SANDBOX_NODE>    Ready    <none>   3m33s   v1.36.5-eks-577a51e   <PRIVATE_IP_1>    <none>        Bottlerocket OS 1.70.0 (aws-k8s-1.36-nitro-sandbox)   6.18.62 (amd64)   containerd://2.3.7+bottlerocket
<SYSTEM_NODE>   Ready    <none>   26m     v1.36.5-eks-577a51e   <PRIVATE_IP_2>   <none>        Bottlerocket OS 1.70.0 (aws-k8s-1.36)                 6.18.62 (amd64)   containerd://2.3.7+bottlerocket
```

The `OS-IMAGE`, `KERNEL-VERSION` and `CONTAINER-RUNTIME` columns show the Bottlerocket
release, the kernel version and the containerd version of each node.

**Step 8: Run the tests on the pods.** In the `workloads` stage, `setup.sh` creates the
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

The pods set no CPU or memory requests or limits. Each pod has these settings:

- It runs as user 65534, and it gets no service account token.
- It uses the default seccomp profile of the runtime, `RuntimeDefault`.
- Its container has a read-only root file system, no privilege escalation and no
  capabilities.
- Its manifest pins the image by digest.

No command that `test.sh` runs in the pods writes a file or needs a capability. The four pods
that run `sleep` have exec readiness and liveness probes, `kill -0 1`. This command succeeds
while the main process of the container runs. kubelet runs the probe through the same exec
path as `kubectl exec`. Because of this, a Ready pod also accepts the `kubectl exec` commands
of `test.sh`.

`cb-server` has HTTP readiness and liveness probes, `GET /` on port 8080. It writes the page
that it serves to the emptyDir volume `www` of 1 MiB, at `/tmp/www`. The ordinary pods have the
same settings and probes as the sandbox pod. Because of this, the runtime class is the only
difference in the comparison.

Here is the `spec` of `deploy/pod-sandbox.yaml`. The RuntimeClass selects the sandbox node,
and the toleration lets the pod use the tainted node:

```yaml
spec:
  runtimeClassName: isolated-sandbox
  automountServiceAccountToken: false
  tolerations:
    - key: sandbox.eks-nitro-sandbox.amazonaws.com/dedicated
      operator: Equal
      value: "true"
      effect: NoSchedule
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: main
      image: public.ecr.aws/docker/library/busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec
      command: ["sleep", "86400"]
      # The probes check the container's main process: kill -0 1 succeeds while PID 1 (the
      # sleep) runs, with no write and no capability. kubelet runs them through the runtime's
      # exec in the guest, so Ready also means the pod takes the kubectl exec that test.sh uses.
      readinessProbe:
        exec:
          command: ["kill", "-0", "1"]
        timeoutSeconds: 5
      livenessProbe:
        exec:
          command: ["kill", "-0", "1"]
        periodSeconds: 30
        timeoutSeconds: 5
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
```

Here is the part of `deploy/pod-sandbox-network-isolated.yaml` that removes the network:

```yaml
  annotations:
    sandbox.amazonaws.com/network-isolated: "true"
spec:
  runtimeClassName: isolated-sandbox
```

Here is `deploy/service.yaml`, without its comments:

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
Caller: arn:aws:sts::<ACCOUNT_ID>:assumed-role/<ROLE_NAME>/<SESSION_NAME>

=== 1. the dedicated cluster and its CNI ===
  [PASS] cluster nitro-cilium-bottlerocket is Kubernetes 1.36 and this run's
  [PASS] no vpc-cni and no kube-proxy add-on (add-ons: coredns eks-pod-identity-agent)
  [PASS] no aws-node and no kube-proxy DaemonSet
  [PASS] exactly one system node
  [PASS] exactly one sandbox node
  [PASS] the Cilium operator is Ready on the system node group
  [PASS] the Cilium agent image is v1.20.5 (cilium.lock)
cilium status: ENI IPAM, native routing, kube-proxy replacement True, socket LB Hostns-only
  [PASS] cilium status on <SYSTEM_NODE>: ENI IPAM, native routing, kube-proxy replacement, Socket LB Hostns-only
cilium status: ENI IPAM, native routing, kube-proxy replacement True, socket LB Hostns-only
  [PASS] cilium status on <SANDBOX_NODE>: ENI IPAM, native routing, kube-proxy replacement, Socket LB Hostns-only

=== 2. the AMIs of the node groups ===
  [PASS] the system node runs the stock Bottlerocket AMI that setup.sh recorded
  [PASS] the sandbox node runs the sandbox AMI of the run

=== 3. the sandbox node: runtime, SELinux, networkd, containerd, density ===
sandbox node: Bottlerocket OS 1.70.0 (aws-k8s-1.36-nitro-sandbox), kubelet v1.36.5-eks-577a51e, kernel 6.18.62
  [PASS] OS image Bottlerocket 1.70.0 (aws-k8s-1.36-nitro-sandbox)
/sys/kernel/btf/vmlinux: 5178250 bytes
  [PASS] /sys/kernel/btf/vmlinux is present
kernel command line has nitro_enclaves.mempool=95%-1G; driver: nitro_enclaves: CMA pool: 14192 MiB reserved in 16 region(s), 14192 MiB requested
  [PASS] the nitro_enclaves driver reserved its CMA pool (its own kernel log line)
kubeconfig_path /etc/kubernetes/kubelet/kubeconfig: present on the node (577 bytes)
  [PASS] the shim reads the kubelet kubeconfig at /etc/kubernetes/kubelet/kubeconfig, and the file is there
mkfs.erofs 1.9.4 on the host: compressors deflate, zstd
  [PASS] mkfs.erofs on the host has the zstd compressor
kubelet containerRuntimeEndpoint: unix:///run/nitro-sandbox/cri-proxy.sock
  [PASS] the kubelet runtime endpoint is unix:///run/nitro-sandbox/cri-proxy.sock
merged containerd config: isolated-sandbox handler with io.containerd.nitro-sandbox.v2, discard_unpacked_layers = false
  [PASS] the merged containerd config has the isolated-sandbox handler and discard_unpacked_layers = false
allocatable eks.amazonaws.com/nitro-sandbox: 20
  [PASS] allocatable eks.amazonaws.com/nitro-sandbox is more than 0
density: SANDBOX_SLOTS=20 equals node pcie_slots
  [PASS] pcie_slots in nitro-sandbox.toml equals SANDBOX_SLOTS=20
slots: SANDBOX_SLOTS=20, pcie_slots_total=20, driver pcie_slots=20, node capacity eks.amazonaws.com/nitro-sandbox=20, max_pcie_devices=32, runtime: advertising 20 (target=20)
  [PASS] the slot pool: SANDBOX_SLOTS=20 is not above pcie_slots_total, and equals the driver's pcie_slots and the node's eks.amazonaws.com/nitro-sandbox capacity
max-pods: derived 110 (ENI formula 118, ceiling 110) equals node capacity pods (110)
  [PASS] the node's capacity pods equals the max-pods derived from m8i.xlarge (110: ENI formula 118, ceiling 110)
sandbox node capacity: pcie_slots_total=20, driver pcie_slots=20, node eks.amazonaws.com/nitro-sandbox=20, max-pods derived=110, node capacity pods=110
  [PASS] the shim is at /usr/bin/containerd-shim-nitro-sandbox-v2
SELinux: enforcing
  [PASS] SELinux is enforcing
SELinux domain runtime_t: CRI proxy (1) and shim (2): system_u:system_r:runtime_t:s0:c0.c1023
  [PASS] the shim and the CRI proxy run in the SELinux domain runtime_t
SELinux audit: no AVC denial in the kernel log or the journal
  [PASS] no SELinux denial in the kernel log or the journal since boot (fails closed)
dm-verity: / is the read-only dm-0 'root' (device 252:0), created with verity on the kernel command line
  [PASS] the root file system is the read-only dm-verity device
  [PASS] the drop-in case folders are removed from /run/cb-probe on the sandbox node
merged containerd config: isolated-sandbox handler with io.containerd.nitro-sandbox.v2, discard_unpacked_layers = false
  [PASS] containerd config dump with the valid drop-in: the handler is there
  [PASS] containerd config dump with no drop-in: containerd loads it, the node check refuses it for the missing handler (E_DROPIN_MISSING)
  [PASS] containerd config dump with a malformed drop-in: containerd stops on the TOML error, the node check refuses it (E_DROPIN_MALFORMED)
filler pods started: 24 (limit 40); ENIs in the CiliumNode of <SANDBOX_NODE>: 2
Cilium ENIs as Cilium sets them: eth1 unmanaged, table 11 via <PRIVATE_IP_12>, 1 endpoint rule(s)
  [PASS] capture A: systemd-networkd leaves each ENI after eth0 unmanaged; no DHCP or RA address or route, only the routes and rules of Cilium

=== 4. the sandbox pod runs in its own guest ===
  [PASS] cb-sandbox has runtimeClassName isolated-sandbox
  [PASS] cb-sandbox runs on the sandbox node
sandbox pod  uname -rv: 6.18.56 #1 SMP PREEMPT_DYNAMIC Tue Oct 27 17:34:18 UTC 2026
ordinary pod uname -rv: 6.18.62 #2 SMP PREEMPT_DYNAMIC Fri Nov 13 22:13:38 UTC 2026
  [PASS] the sandbox pod has its own kernel build
sandbox pod uptime 199s, ordinary pod (node) uptime 424s
  [PASS] the sandbox pod booted with the pod, after the node
sandbox pod disks: dm-0 vda vdb vdc
ordinary pod disks: dm-0 loop0 loop1 loop2 loop3 loop4 loop5 loop6 loop7 nvme0n1 nvme1n1 zram0
  [PASS] the sandbox pod sees virtio vd* disks, the ordinary pod the nvme disks of the instance
product_name: sandbox m8i.enclave, ordinary m8i.xlarge

=== 5. pod networking: ENI address, CiliumEndpoint, pod to pod, ClusterIP Service, DNS ===
pod IP <PRIVATE_IP_5>: secondary IP of <ENI_ID_6> (device index 0)
  [PASS] the sandbox pod IP <PRIVATE_IP_5> is a secondary IP of an ENI of its node
  [PASS] the CiliumEndpoint of cb-sandbox is ready
  [PASS] Service cb-server is ClusterIP
  [PASS] cb-sandbox: pod to pod (http://<PRIVATE_IP_7>:8080/)
  [PASS] cb-sandbox: ClusterIP Service (http://cb-server.cilium-bottlerocket-demo.svc.cluster.local/)
  [PASS] cb-sandbox: DNS (cb-server.cilium-bottlerocket-demo.svc.cluster.local)
  [PASS] cb-ordinary-sandbox-node: pod to pod (http://<PRIVATE_IP_7>:8080/)
  [PASS] cb-ordinary-sandbox-node: ClusterIP Service (http://cb-server.cilium-bottlerocket-demo.svc.cluster.local/)
  [PASS] cb-ordinary-sandbox-node: DNS (cb-server.cilium-bottlerocket-demo.svc.cluster.local)
  [PASS] cb-ordinary-system-node: pod to pod (http://<PRIVATE_IP_7>:8080/)
  [PASS] cb-ordinary-system-node: ClusterIP Service (http://cb-server.cilium-bottlerocket-demo.svc.cluster.local/)
  [PASS] cb-ordinary-system-node: DNS (cb-server.cilium-bottlerocket-demo.svc.cluster.local)
network-isolated pod: only lo, no route, the DNS lookup fails
  [PASS] the network-isolated sandbox pod has only loopback, no route and no DNS

=== 6. AWS permissions and exposure ===
operator role nitro-cilium-bottlerocket-cilium-operator: association and role tagged for run <RUN_ID>, EKS Pod Identity trust only, exactly the 13 EC2 actions of the Cilium list
node role eksctl-nitro-cilium-bottlerocket-n-NodeInstanceRole-<SUFFIX_3> (sandbox): AmazonEC2ContainerRegistryPullOnly, AmazonEKSWorkerNodePolicy (AWS managed), no inline policy, no Cilium EC2 action
node role eksctl-nitro-cilium-bottlerocket-n-NodeInstanceRole-<SUFFIX_2> (system): AmazonEC2ContainerRegistryPullOnly, AmazonEKSWorkerNodePolicy (AWS managed), no inline policy, no Cilium EC2 action
  [PASS] the Cilium operator role has only the EC2 actions of the Cilium list; node roles have none
  [PASS] the only Pod Identity association is kube-system/cilium-operator
  [PASS] cb-sandbox has no AWS credential variable
  [PASS] cb-ordinary-sandbox-node has no AWS credential variable
  [PASS] cb-ordinary-system-node has no AWS credential variable
  [PASS] every Service of the cluster is ClusterIP (no LoadBalancer, no NodePort)
  [PASS] no Ingress
  [PASS] no NetworkPolicy
  [PASS] no CiliumNetworkPolicy
  [PASS] no CiliumClusterwideNetworkPolicy
cfn-stack: 4
eks-cluster: 1
eks-addon: 2
vpc: 1
subnet: 4
route-table: 3
main-route-table: 1
network-acl: 1
internet-gateway: 1
nat-gateway: 1
elastic-ip: 1
security-group: 2
default-security-group: 1
cluster-security-group: 1
control-plane-eni: 2
nat-gateway-eni: 1
iam-role: 4
pod-identity-association: 1
cilium-eni: 1
launch-template: 2
eks-nodegroup: 2
autoscaling-group: 2
eks-launch-template-copy: 2
node-instance-profile: 2
node-instance: 2
node-volume: 4
node-eni: 2
builder-security-group: 0
builder-role: 0
builder-instance-profile: 0
builder-instance: 0
builder-volume: 0
builder-eni: 0
ami: 1
ami-snapshot: 2
tag audit: 54 resources in 35 classes, each with both tags
  [PASS] every resource of every class carries ManagedBy and RunId

=== 7. the sandbox node at the end: the Cilium ENIs since capture A, and the SELinux audit ===
Cilium ENIs as Cilium sets them: eth1 unmanaged, table 11 via <PRIVATE_IP_12>, 1 endpoint rule(s)
  [PASS] capture B: each ENI after eth0 has no DHCP or RA address or route, only the routes and rules of Cilium
Cilium ENIs unchanged by networkd: eth1 (1 addresses, 4 routes, tables 11,local)
  [PASS] the addresses, routes and rules of each ENI after eth0 are the same in capture A and capture B
SELinux audit: no AVC denial in the kernel log or the journal
  [PASS] no SELinux denial on the sandbox node from its boot to the end of test.sh (fails closed)
  [PASS] each filler pod is deleted by its exact name, and none is left
  [PASS] the probe pod cb-probe-sandbox-<RUN_ID> is deleted by its exact name, and it is gone

RESULT: the Cilium on Bottlerocket sample (run <RUN_ID>): 66/66 assertions passed.
```

The fresh run set `RUN_ID=<RUN_ID>` for `test.sh`, as the last lines of `setup.sh` show.

The output has these results:

- The cluster runs Kubernetes 1.36 with no `vpc-cni` or `kube-proxy` add-on or DaemonSet.
  Each node group has exactly one node, and the Cilium operator is ready. The Cilium agent
  image has the version in `cilium.lock`.
- `test.sh` reads `cilium-dbg status --verbose` and `cilium-dbg config --all` from the agent on
  each node. Together, they show ENI IPAM, native routing and kube-proxy replacement. The status
  also shows `Socket LB Coverage: Hostns-only`, which `socketLB.hostNamespaceOnly: true` sets.
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
- The sandbox node passes the node checks of Step 7 again. The line that starts with
  `sandbox node capacity:` gives the two limits of the node. These are `pcie_slots_total`, the
  driver `pcie_slots`, the node capacity `eks.amazonaws.com/nitro-sandbox`, the calculated
  `max-pods` and the pod capacity of the node.
- With the valid containerd drop-in, `containerd config dump` on the sandbox node shows the
  `isolated-sandbox` handler. With no drop-in and with a malformed drop-in, the node check
  refuses the result. `test.sh` makes each case in its own folder under `/run/cb-probe` on
  the node, and removes that folder after the case. Then it verifies that no case folder
  remains. If `test.sh` cannot remove a case folder, the check fails.
- The only Pod Identity association is `kube-system/cilium-operator`. The association and the
  operator role pass the checks of Step 4 again. The workload pods have no AWS credential
  variable.
- Each Service of the cluster is a ClusterIP Service. The cluster has no Ingress, no
  NetworkPolicy, no CiliumNetworkPolicy and no CiliumClusterwideNetworkPolicy.
- Each resource of the run has the `ManagedBy` and `RunId` tags.
- In capture B at the end, each ENI after `eth0` has the same addresses, routes and rules as
  in capture A. The SELinux audit finds no denial from the boot of the node to the end of
  `test.sh`.
- At the end, `test.sh` deletes the filler pods and the probe pod by their exact names. Then
  it verifies that no filler pod or probe pod remains.

A check that `test.sh` cannot complete counts as a failure. `test.sh` exits with a non-zero
code when a check does not pass. It also exits with a non-zero code when it cannot remove a
helper pod or a case folder at its exit.

## IAM matrix

The blueprint uses five principals. The table gives the actions of each principal, by
resource. The builder instance and the Cilium operator get only the actions in their rows,
because the blueprint creates their roles. The cluster creator, the Packer and SSM caller and
the cleaner are your own short-lived credentials. For least privilege, give these credentials
only the actions in their rows.

`test.sh` uses the credentials of the cluster creator. It calls only read actions of the
cluster creator rows, and the Kubernetes API. In the table, `<CLUSTER_NAME>` and `<RUN_ID>` are
the values of your run.

A row for "The account" holds actions that take no resource, for example the EC2 describe
actions. Some rows name a tag to identify the resources of the run. The scripts read the
`ManagedBy` and `RunId` tags of a resource again before they change or delete it.

| Principal | Resource | Actions |
|---|---|---|
| Cluster creator | The account, and the four VPC and EC2 quotas that `setup.sh` reads | `sts:GetCallerIdentity`, `servicequotas:GetServiceQuota`, `autoscaling:DescribeAutoScalingGroups`, `ec2:DescribeAvailabilityZones`, `ec2:DescribeVpcs`, `ec2:DescribeVpcAttribute`, `ec2:DescribeSubnets`, `ec2:DescribeRouteTables`, `ec2:DescribeNetworkAcls`, `ec2:DescribeInternetGateways`, `ec2:DescribeNatGateways`, `ec2:DescribeAddresses`, `ec2:DescribeSecurityGroups`, `ec2:DescribeSecurityGroupRules`, `ec2:DescribeNetworkInterfaces`, `ec2:DescribeVpcEndpoints`, `ec2:DescribeInstances`, `ec2:DescribeVolumes`, `ec2:DescribeInstanceTypes`, `ec2:DescribeImages`, `ec2:DescribeImageAttribute`, `ec2:DescribeSnapshots`, `ec2:DescribeLaunchTemplates`, `ec2:DescribeLaunchTemplateVersions`. CloudFormation also calls `iam:GetAccountSummary` with these credentials when it creates the IAM roles of the eksctl stacks. |
| Cluster creator | All the CloudFormation stacks of the Region. The tag audit reads them all, then keeps the stacks of the cluster. | `cloudformation:DescribeStacks` with no stack name, `cloudformation:ListStacks` |
| Cluster creator | The public SSM parameter of the Bottlerocket `aws-k8s-1.36` v1.70.0 AMI | `ssm:GetParameter` |
| Cluster creator | The CloudFormation stacks `eksctl-<CLUSTER_NAME>-*` | `cloudformation:CreateStack`, `cloudformation:DescribeStacks`, `cloudformation:DescribeStackResources`, `cloudformation:GetTemplate` |
| Cluster creator | The VPC, subnets, internet gateway, route tables, Elastic IP address, NAT gateway and security groups that CloudFormation creates in the eksctl stacks | `ec2:CreateVpc`, `ec2:ModifyVpcAttribute`, `ec2:CreateSubnet`, `ec2:ModifySubnetAttribute`, `ec2:CreateInternetGateway`, `ec2:AttachInternetGateway`, `ec2:CreateRouteTable`, `ec2:CreateRoute`, `ec2:AssociateRouteTable`, `ec2:AllocateAddress`, `ec2:CreateNatGateway`, `ec2:CreateSecurityGroup`, `ec2:AuthorizeSecurityGroupIngress`, `ec2:CreateTags` |
| Cluster creator | The cluster `<CLUSTER_NAME>`, its add-ons, its node groups and its Pod Identity association | `eks:CreateCluster`, `eks:DescribeCluster`, `eks:DescribeClusterVersions`, `eks:CreateAddon`, `eks:DescribeAddon`, `eks:DescribeAddonVersions`, `eks:ListAddons`, `eks:CreateNodegroup`, `eks:DescribeNodegroup`, `eks:ListNodegroups`, `eks:CreatePodIdentityAssociation`, `eks:DescribePodIdentityAssociation`, `eks:ListPodIdentityAssociations` |
| Cluster creator | The Kubernetes API of the cluster | Cluster administrator, through the access entry that EKS creates for the creator of the cluster. `setup.sh` and `test.sh` call no access entry action. `clean.sh` only lists and reads the access entries. |
| Cluster creator | The cluster role and the node roles `eksctl-<CLUSTER_NAME>-*`, and the role `<CLUSTER_NAME>-cilium-operator` | `iam:CreateRole`, `iam:TagRole`, `iam:AttachRolePolicy`, `iam:PutRolePolicy`, `iam:GetRole`, `iam:GetRolePolicy`, `iam:ListAttachedRolePolicies`, `iam:ListRolePolicies`, `iam:ListRoleTags`. Also `iam:PassRole` of the cluster role and the node roles to `eks.amazonaws.com`, and of the role `<CLUSTER_NAME>-cilium-operator` for its Pod Identity association. |
| Cluster creator | The service-linked roles of EKS, EKS node groups and Auto Scaling, only when the account does not have them | `iam:CreateServiceLinkedRole` |
| Cluster creator | The builder role and the builder instance profile `<CLUSTER_NAME>-<RUN_ID>-builder`. `setup.sh` reads each name before the run (the name must be free or a resource of the run), after the AMI build (the resource must be gone) and in each tag audit. `test.sh` reads them in its tag audit. | `iam:GetRole`, `iam:ListRoleTags`, `iam:GetInstanceProfile`, `iam:ListInstanceProfileTags` |
| Cluster creator | The launch templates `<CLUSTER_NAME>-<RUN_ID>-system` and `<CLUSTER_NAME>-<RUN_ID>-sandbox` | `ec2:CreateLaunchTemplate`, `ec2:CreateTags`, and `ec2:RunInstances` as a dry run only, with which eksctl examines each launch template |
| Cluster creator | The main route table, the network ACL, and the default and cluster security groups of the run VPC, which have no tag | `ec2:CreateTags` |
| Cluster creator | The ENIs of the control plane and the NAT gateway, and the launch template copies of the node groups, which have no tag | `ec2:CreateTags` |
| Cluster creator | The Auto Scaling groups of the two node groups | `autoscaling:CreateOrUpdateTags` |
| Cluster creator | The instance profiles that EKS creates for the node groups | `iam:ListInstanceProfileTags`, `iam:TagInstanceProfile` |
| Packer and SSM caller | The account | `sts:GetCallerIdentity`, `ec2:DescribeRegions`, `ec2:DescribeSubnets`, `ec2:DescribeSecurityGroups`, `ec2:DescribeInstances`, `ec2:DescribeNetworkInterfaces`, `ec2:DescribeVolumes`, `ec2:DescribeImages`, `ec2:DescribeImageAttribute`, `ec2:DescribeSnapshots`, `ssm:GetCommandInvocation`, `ssm:DescribeInstanceInformation` |
| Packer and SSM caller | The public SSM parameter of the Amazon Linux 2023 AMI | `ssm:GetParameter` |
| Packer and SSM caller | The builder security group in the cluster VPC | `ec2:CreateSecurityGroup`, `ec2:RevokeSecurityGroupEgress`, `ec2:AuthorizeSecurityGroupEgress`, `ec2:DeleteSecurityGroup`, `ec2:CreateTags` |
| Packer and SSM caller | The builder role and the builder instance profile `<CLUSTER_NAME>-<RUN_ID>-builder` | `iam:CreateRole`, `iam:TagRole`, `iam:GetRole`, `iam:DeleteRole`, `iam:AttachRolePolicy` and `iam:DetachRolePolicy` of `AmazonSSMManagedInstanceCore` only, `iam:CreateInstanceProfile`, `iam:TagInstanceProfile`, `iam:GetInstanceProfile`, `iam:AddRoleToInstanceProfile`, `iam:RemoveRoleFromInstanceProfile`, `iam:DeleteInstanceProfile`. Also `iam:PassRole` of the builder role, for `iam:AddRoleToInstanceProfile` and for the builder instance (`ec2.amazonaws.com`). |
| Packer and SSM caller | The builder instance, its four volumes and its network interface, in the build subnet with the builder security group and the Amazon Linux 2023 AMI | `ec2:RunInstances`, `ec2:CreateTags`, `ec2:StopInstances`, `ec2:ModifyInstanceAttribute`, `ec2:TerminateInstances` |
| Packer and SSM caller | The AMI and its two snapshots | `ec2:CreateSnapshot`, `ec2:RegisterImage`, `ec2:ModifyImageAttribute`, `ec2:CreateTags`. After a failed build only: `ec2:DeregisterImage`, `ec2:DeleteSnapshot`, `ec2:DeleteVolume`. |
| Packer and SSM caller | The document `AWS-RunShellScript`, and the builder instance with the tag `ManagedBy=cilium-bottlerocket-sample` | `ssm:SendCommand` |
| Builder instance | The builder role of the run, which only `ec2.amazonaws.com` can assume | Only the AWS managed policy `AmazonSSMManagedInstanceCore`. The stage scripts on the builder call no AWS API. |
| Cilium operator | The role `<CLUSTER_NAME>-cilium-operator`, which only `pods.eks.amazonaws.com` can assume. The policy gives each action on all resources (`Resource: "*"`). The operator uses the actions on the ENIs of the nodes in the cluster VPC. | Only the 13 actions in the policy document of Step 4 |
| Cleaner | The account | `sts:GetCallerIdentity`, `autoscaling:DescribeAutoScalingGroups`, `ec2:DescribeKeyPairs`, and the EC2 describe actions of the cluster creator |
| Cleaner | All the CloudFormation stacks of the Region. The resource list of `clean.sh` reads them all, then keeps the stacks of the cluster. | `cloudformation:DescribeStacks` with no stack name, `cloudformation:ListStacks` |
| Cleaner | The instance profiles that EKS creates for the node groups | `iam:ListInstanceProfileTags` |
| Cleaner | The Kubernetes API of the cluster | Cluster administrator, through the access entry that EKS creates for the creator of the cluster. Use the role that created the cluster to run `clean.sh`. With another role, `clean.sh` keeps the cluster. `clean.sh` reads the Services, the Ingresses (`networking.k8s.io`) and the Gateways (`gateway.networking.k8s.io`) in all namespaces. It deletes the namespace `cilium-bottlerocket-demo` and the RuntimeClass `isolated-sandbox`, only when each has the label of the blueprint. `eksctl delete nodegroup` and `eksctl delete cluster` drain each node first. |
| Cleaner | The cluster `<CLUSTER_NAME>`, and its node groups, add-ons, Fargate profiles, identity provider configs, access entries and Pod Identity associations | `eks:DescribeCluster`, `eks:DescribeClusterVersions`, `eks:ListNodegroups`, `eks:DescribeNodegroup`, `eks:DeleteNodegroup`, `eks:ListAddons`, `eks:DescribeAddon`, `eks:DeleteAddon`, `eks:ListFargateProfiles`, `eks:DescribeFargateProfile`, `eks:ListIdentityProviderConfigs`, `eks:DescribeIdentityProviderConfig`, `eks:ListAccessEntries`, `eks:DescribeAccessEntry`, `eks:ListPodIdentityAssociations`, `eks:DescribePodIdentityAssociation`, `eks:DeletePodIdentityAssociation`, `eks:DeleteCluster` |
| Cleaner | The ENIs that Cilium created, the builder network interfaces, the builder instances, their volumes and the builder security group, each with the tag `RunId=<RUN_ID>` | `ec2:DeleteNetworkInterface`, `ec2:TerminateInstances`, `ec2:DeleteVolume`, `ec2:DeleteSecurityGroup` |
| Cleaner | The launch templates of the run | `ec2:DeleteLaunchTemplate` |
| Cleaner | The AMI and its snapshots, each with the tag `RunId=<RUN_ID>` | `ec2:DeregisterImage`, `ec2:DeleteSnapshot` |
| Cleaner | The CloudFormation stacks `eksctl-<CLUSTER_NAME>-*` | `cloudformation:DescribeStacks`, `cloudformation:DescribeStackEvents`, `cloudformation:UpdateTerminationProtection`, `cloudformation:DeleteStack` |
| Cleaner | The VPC objects that CloudFormation deletes with the eksctl stacks | `ec2:DeleteNatGateway`, `ec2:DisassociateAddress`, `ec2:ReleaseAddress`, `ec2:DetachInternetGateway`, `ec2:DeleteInternetGateway`, `ec2:DeleteRoute`, `ec2:DisassociateRouteTable`, `ec2:DeleteRouteTable`, `ec2:DeleteSubnet`, `ec2:RevokeSecurityGroupIngress`, `ec2:RevokeSecurityGroupEgress`, `ec2:DeleteSecurityGroup`, `ec2:DeleteVpc` |
| Cleaner | The builder role, the role `<CLUSTER_NAME>-cilium-operator` and the roles `eksctl-<CLUSTER_NAME>-*` | `iam:GetRole`, `iam:ListRoleTags`, `iam:ListAttachedRolePolicies`, `iam:ListRolePolicies`, `iam:DetachRolePolicy`, `iam:DeleteRolePolicy`, `iam:DeleteRole` |
| Cleaner | The IAM OIDC providers of the account. `clean.sh` lists the IAM OIDC providers to find one whose URL matches the OIDC issuer of the cluster. If it finds one, it keeps the cluster. `eksctl delete cluster` tries to read the IAM OIDC provider for the OIDC issuer of the cluster. | `iam:ListOpenIDConnectProviders`, `iam:GetOpenIDConnectProvider` |
| Cleaner | The builder instance profile `<CLUSTER_NAME>-<RUN_ID>-builder` | `iam:GetInstanceProfile`, `iam:ListInstanceProfileTags`, `iam:RemoveRoleFromInstanceProfile`, `iam:DeleteInstanceProfile` |

The node roles are not principals of the blueprint. Each node role has only the AWS managed
policies `AmazonEKSWorkerNodePolicy` and `AmazonEC2ContainerRegistryPullOnly`. The checks
compare the policy ARNs.

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

In the fresh run, `setup.sh` took 43 min 4 s. `test.sh` took 6 min 10 s, and 66 of 66
assertions passed. `clean.sh` took 16 min 15 s. The resources of the run cost USD 1.19:

```text
| Item | Time (UTC) | Hours | USD |
|---|---|---|---|
| EKS control plane | 20:42:11 to 21:48:14 | 1.10 | 0.11 |
| NAT gateway (hours) | the same | 1.10 | 0.05 |
| Public IPv4 address | the same | 1.10 | 0.01 |
| system node m8i.xlarge with 32 GiB gp3 | 20:57:07 to 21:42:26 | 0.76 | 0.16 |
| sandbox node m8i.xlarge with 84 GiB gp3 | 21:19:50 to 21:39:00 | 0.32 | 0.07 |
| builder m8i.4xlarge with 202 GiB gp3 | 21:02:42 to 21:19:28 | 0.28 | 0.24 |
| AMI snapshots, at most 22 GB | 21:19:28 to 21:48:14 | 0.48 | 0.00 |
| NAT data, 12.132 GB | CloudWatch |  | 0.55 |
| **Total** | | | **1.19** |
```

The cost calculation uses these `us-west-2` on-demand list prices in USD:

- EKS control plane: 0.10 for each hour.
- NAT gateway: 0.045 for each hour, and 0.045 for each GB of data.
- Public IPv4 address: 0.005 for each hour.
- `m8i.xlarge`: 0.21168 for each hour. `m8i.4xlarge`: 0.84672 for each hour.
- gp3 volumes: 0.08 for each GiB-month. Snapshots: 0.05 for each GB-month.

The script logs give the time ranges in the table. Each range can be a few minutes longer
than the time that the resource existed. CloudWatch gives the NAT data.

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

Use the profile of the role that ran `setup.sh` and created the cluster. With another role,
`clean.sh` keeps the cluster, as the access entry rules below show.

`clean.sh` acts on the run that `setup.sh` started last. To select a different run, give
`--run-id <RUN_ID>`. First, list the resources of the run. The dry run lists only resources
with the tags of the blueprint and the run. It changes no AWS resource and no Kubernetes
object. It writes only local files in the run folder.

```bash
./clean.sh --dry-run
```

```text
=== dry run: the resources of run <RUN_ID> that ./clean.sh would delete ===
  cfn-stack                    eksctl-nitro-cilium-bottlerocket-nodegroup-sandbox
  cfn-stack                    eksctl-nitro-cilium-bottlerocket-nodegroup-system
  cfn-stack                    eksctl-nitro-cilium-bottlerocket-podidentityrole-kube-system-cilium-operator
  cfn-stack                    eksctl-nitro-cilium-bottlerocket-cluster
  eks-cluster                  nitro-cilium-bottlerocket
  eks-addon                    coredns
  eks-addon                    eks-pod-identity-agent
  vpc                          <VPC_ID>
  subnet                       <SUBNET_ID_1>
  subnet                       <SUBNET_ID_2>
  subnet                       <SUBNET_ID_3>
  subnet                       <SUBNET_ID_4>
  route-table                  <ROUTE_TABLE_ID_1>
  route-table                  <ROUTE_TABLE_ID_2>
  route-table                  <ROUTE_TABLE_ID_3>
  main-route-table             <ROUTE_TABLE_ID_4>
  network-acl                  <ACL_ID_1>
  internet-gateway             <IGW_ID_1>
  nat-gateway                  <NAT_ID_1>
  elastic-ip                   <EIP_ALLOC_ID_1>
  security-group               <SG_ID_1>
  security-group               <SG_ID_2>
  default-security-group       <SG_ID_3>
  cluster-security-group       <SG_ID_4>
  control-plane-eni            <ENI_ID_1>
  control-plane-eni            <ENI_ID_2>
  nat-gateway-eni              <ENI_ID_3>
  iam-role                     eksctl-nitro-cilium-bottlerocket-cluste-ServiceRole-<SUFFIX_1>
  iam-role                     eksctl-nitro-cilium-bottlerocket-n-NodeInstanceRole-<SUFFIX_2>
  iam-role                     eksctl-nitro-cilium-bottlerocket-n-NodeInstanceRole-<SUFFIX_3>
  iam-role                     nitro-cilium-bottlerocket-cilium-operator
  pod-identity-association     <ASSOCIATION_ID>
  cilium-eni                   <ENI_ID_4>
  launch-template              <SYSTEM_LAUNCH_TEMPLATE_ID>
  launch-template              <SANDBOX_LAUNCH_TEMPLATE_ID>
  eks-nodegroup                sandbox
  eks-nodegroup                system
  autoscaling-group            eks-sandbox-<NODEGROUP_UUID_1>
  autoscaling-group            eks-system-<NODEGROUP_UUID_2>
  eks-launch-template-copy     <LAUNCH_TEMPLATE_ID_1>
  eks-launch-template-copy     <LAUNCH_TEMPLATE_ID_2>
  node-instance-profile        eks-<NODEGROUP_UUID_2>
  node-instance-profile        eks-<NODEGROUP_UUID_1>
  node-instance                <INSTANCE_ID_1>
  node-instance                <INSTANCE_ID_2>
  node-volume                  <VOLUME_ID_1>
  node-volume                  <VOLUME_ID_2>
  node-volume                  <VOLUME_ID_3>
  node-volume                  <VOLUME_ID_4>
  node-eni                     <ENI_ID_5>
  node-eni                     <ENI_ID_6>
  ami                          <SANDBOX_AMI_ID>
  ami-snapshot                 <SNAPSHOT_ID_2>
  ami-snapshot                 <SNAPSHOT_ID_1>
No AWS resource or Kubernetes object was changed. Run ./clean.sh without --dry-run to delete these.
```

Then delete the resources of the run. `clean.sh` asks you to type the cluster name before
it deletes a resource. For a run with no terminal, set `CLEAN_CONFIRM` to the cluster name.
When the typed name is different, `clean.sh` stops with `E_NOT_CONFIRMED` and deletes nothing.
After the confirmation, `clean.sh` lists the resources again. When that list fails, it stops
with `E_CLEAN_INVENTORY` and deletes nothing.

```bash
./clean.sh
```

```text
=== 1/5 workloads, node groups and the ENIs that Cilium created ===
deleted namespace cilium-bottlerocket-demo
deleted RuntimeClass isolated-sandbox
2026-11-22 21:36:18 [ℹ]  1 nodegroup (sandbox) was included (based on the include/exclude rules)
2026-11-22 21:36:18 [ℹ]  will drain 1 nodegroup(s) in cluster "nitro-cilium-bottlerocket"
2026-11-22 21:36:18 [ℹ]  starting parallel draining, max in-flight of 1
2026-11-22 21:36:19 [ℹ]  cordon node "<SANDBOX_NODE>"
2026-11-22 21:36:19 [✔]  drained all nodes: [<SANDBOX_NODE>]
2026-11-22 21:36:19 [ℹ]  will delete 1 nodegroups from cluster "nitro-cilium-bottlerocket"
2026-11-22 21:36:19 [ℹ]  1 task: { 1 task: { delete nodegroup "sandbox" } }
2026-11-22 21:36:20 [ℹ]  will delete stack "eksctl-nitro-cilium-bottlerocket-nodegroup-sandbox"
2026-11-22 21:36:20 [ℹ]  waiting for stack "eksctl-nitro-cilium-bottlerocket-nodegroup-sandbox" to get deleted
2026-11-22 21:36:20 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-sandbox"
2026-11-22 21:36:50 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-sandbox"
2026-11-22 21:37:35 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-sandbox"
2026-11-22 21:38:20 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-sandbox"
2026-11-22 21:39:00 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-sandbox"
2026-11-22 21:39:00 [✔]  deleted 1 nodegroup(s) from cluster "nitro-cilium-bottlerocket"
2026-11-22 21:39:02 [ℹ]  1 nodegroup (system) was included (based on the include/exclude rules)
2026-11-22 21:39:02 [ℹ]  will drain 1 nodegroup(s) in cluster "nitro-cilium-bottlerocket"
2026-11-22 21:39:02 [ℹ]  starting parallel draining, max in-flight of 1
2026-11-22 21:39:02 [ℹ]  cordon node "<SYSTEM_NODE>"
2026-11-22 21:39:14 [✔]  drained all nodes: [<SYSTEM_NODE>]
2026-11-22 21:39:14 [ℹ]  will delete 1 nodegroups from cluster "nitro-cilium-bottlerocket"
2026-11-22 21:39:14 [ℹ]  1 task: { 1 task: { delete nodegroup "system" } }
2026-11-22 21:39:14 [ℹ]  will delete stack "eksctl-nitro-cilium-bottlerocket-nodegroup-system"
2026-11-22 21:39:14 [ℹ]  waiting for stack "eksctl-nitro-cilium-bottlerocket-nodegroup-system" to get deleted
2026-11-22 21:39:14 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-system"
2026-11-22 21:39:45 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-system"
2026-11-22 21:40:28 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-system"
2026-11-22 21:41:40 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-system"
2026-11-22 21:42:26 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-nodegroup-system"
2026-11-22 21:42:26 [✔]  deleted 1 nodegroup(s) from cluster "nitro-cilium-bottlerocket"

=== 2/5 builder instances, their volumes, the builder security group, instance profile and role ===
instance <BUILDER_INSTANCE_ID>: already gone
volume <VOLUME_ID_5>: already gone
volume <VOLUME_ID_6>: already gone
volume <VOLUME_ID_7>: already gone
volume <VOLUME_ID_8>: already gone
security-group <BUILDER_SG_ID>: already gone
instance-profile nitro-cilium-bottlerocket-<RUN_ID>-builder: already gone
iam-role nitro-cilium-bottlerocket-<RUN_ID>-builder: already gone

=== 3/5 launch templates ===
deleted launch-template <SYSTEM_LAUNCH_TEMPLATE_ID>
deleted launch-template <SANDBOX_LAUNCH_TEMPLATE_ID>

=== 4/5 the AMI and its snapshots ===
deleted image <SANDBOX_AMI_ID>
deleted snapshot <SNAPSHOT_ID_2>
deleted snapshot <SNAPSHOT_ID_1>

=== 5/5 the Pod Identity association and the cluster stacks ===
deleted Pod Identity association <ASSOCIATION_ID>
2026-11-22 21:45:07 [ℹ]  deleting EKS cluster "nitro-cilium-bottlerocket"
2026-11-22 21:45:08 [ℹ]  deleted 0 Fargate profile(s)
2026-11-22 21:45:09 [ℹ]  cleaning up AWS load balancers created by Kubernetes objects of Kind Service, Ingress, or Gateway
2026-11-22 21:45:11 [ℹ]
2 sequential tasks: { deleting IAM resources stack "eksctl-nitro-cilium-bottlerocket-podidentityrole-kube-system-cilium-operator", delete cluster control plane "nitro-cilium-bottlerocket"
}
2026-11-22 21:45:11 [ℹ]  will delete stack "eksctl-nitro-cilium-bottlerocket-podidentityrole-kube-system-cilium-operator"
2026-11-22 21:45:11 [ℹ]  waiting for stack "eksctl-nitro-cilium-bottlerocket-podidentityrole-kube-system-cilium-operator" to get deleted
2026-11-22 21:45:11 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-podidentityrole-kube-system-cilium-operator"
2026-11-22 21:45:41 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-podidentityrole-kube-system-cilium-operator"
2026-11-22 21:45:42 [ℹ]  will delete stack "eksctl-nitro-cilium-bottlerocket-cluster"
2026-11-22 21:45:42 [ℹ]  waiting for stack "eksctl-nitro-cilium-bottlerocket-cluster" to get deleted
2026-11-22 21:45:42 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-cluster"
2026-11-22 21:46:12 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-cluster"
2026-11-22 21:46:55 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-cluster"
2026-11-22 21:48:14 [ℹ]  waiting for CloudFormation stack "eksctl-nitro-cilium-bottlerocket-cluster"
2026-11-22 21:48:14 [✔]  all cluster resources were deleted

=== read back ===

CLEAN: run <RUN_ID> of the Cilium on Bottlerocket sample (nitro-cilium-bottlerocket): nothing left behind.
```

`clean.sh` writes its verdict to `evidence/clean/verdict.txt` in the run folder:

```text
run=<RUN_ID> time=2026-11-22T21:49:17Z keep_ami=0 keep_cluster=0 failures=0 verdict=clean
```

In the fresh run, both `clean.sh` commands had `--run-id <RUN_ID>`, and `CLEAN_CONFIRM` held
the cluster name.

`clean.sh` deletes the resources in this sequence:

1. The workloads, the node groups and the ENIs that Cilium created.
2. The tagged builder instances with their volumes, a builder network interface that is
   left, and the builder security group, instance profile and role.
3. The launch templates.
4. The AMI and its tagged snapshots, unless you give `--keep-ami`.
5. The Pod Identity association and the cluster stacks, with the VPC, the NAT gateway, the
   Elastic IP address and the roles.

It is possible that EKS refuses the cluster delete with HTTP 409 "currently has an update in
progress". In one run, EKS gave this answer for some minutes after `clean.sh` deleted the last
node group and the Pod Identity association. At that time, `aws eks list-updates` showed no
update. On this answer, `clean.sh` runs `eksctl delete cluster` again. It makes at most 4
tries, 120 s apart, and it starts no retry later than 25 minutes after the first try. Each
retry prints a line that starts with `CLEAN RETRY E_CLUSTER_DELETE_BUSY:`.

If all 4 tries fail, `clean.sh` stops with `E_CLUSTER_DELETE_BUSY` and keeps the cluster.
It also stops in this way when the next retry is due later than 25 minutes after the first
try. In that case, run `./clean.sh` again later. `clean.sh` does not retry any other failure
of the cluster delete.

Before each delete of an AWS resource, `clean.sh` reads the ownership tags of the resource
again. It deletes only a resource with the tags `ManagedBy=cilium-bottlerocket-sample` and
the `RunId` of the run. For the namespace and the RuntimeClass, it reads the label of the
blueprint again. When `clean.sh` deletes a node group or the cluster, eksctl also deletes
the resources that the node group or the cluster holds.

Because of this, `clean.sh` reads each object that eksctl or EKS deletes with the cluster.
`clean.sh` completes these reads before `clean.sh` deletes the cluster. It keeps the cluster
when one of these objects is not a resource of the run, or when it cannot read one:

- Each node group, add-on, Fargate profile and identity provider config of the cluster.
- Each Pod Identity association of the cluster, in all namespaces.
- Each access entry of the cluster.
- Each eksctl stack of the cluster.
- The IAM OIDC provider whose URL is the OIDC issuer of the cluster, in any letter case.
  eksctl deletes this provider with the cluster. The blueprint makes no such provider, so
  this provider always keeps the cluster. A provider of another issuer does not keep the
  cluster.

A Service of type LoadBalancer, an Ingress or a Gateway in any namespace also keeps the
cluster. eksctl deletes the AWS load balancers of these objects, and the blueprint makes none.

Apart from the IAM OIDC provider, an object of this list is a resource of the run when it has
the tags of the run. EKS makes three kinds of access entry with no tag. `clean.sh` uses the
exact principal ARN to count such an entry as a resource of the run. It counts the entry only
in these cases:

- The entry of the cluster creator: only when its principal is the ARN of the IAM role or user
  that runs `clean.sh`. When another role or user runs `clean.sh`, this entry is not a
  resource of the run, and `clean.sh` keeps the cluster.
- The entry of the node role of a node group: only when its principal is an ARN in the node
  role record of the run. Before `clean.sh` deletes a node group of the run, it adds the node
  role ARN of that node group to `NODE_ROLE_ARNS` in the state file. A later `clean.sh` of the
  same run reads this record too. Because of this, the entry stays a resource of the run after
  eksctl deletes the node role with its node group. `clean.sh` does not read the role in IAM.
- The entry of the EKS service-linked role `AWSServiceRoleForAmazonEKS`: only when its
  principal is
  `arn:aws:iam::<AWS_ACCOUNT_ID>:role/aws-service-role/eks.amazonaws.com/AWSServiceRoleForAmazonEKS`.
  EKS creates this entry with the cluster and deletes it with the cluster. The blueprint never
  creates this entry, and no caller can create it. The Amazon EKS User Guide,
  [*Create access entries*](https://docs.aws.amazon.com/eks/latest/userguide/creating-access-entries.html),
  says that a caller cannot create an access entry whose principal ARN is a service-linked role.

`clean.sh` keeps the cluster for a node role entry in these cases:

- The run has no node role record, or `clean.sh` cannot read the record.
- The record holds a value that is not a role ARN of the account.
- The principal of the entry is not in the record, for example the cluster role or the
  operator role.

When `clean.sh` cannot add the node role ARN of a node group to the record, it keeps that node
group and the cluster.

When eksctl or a person deletes the IAM role of an access entry, EKS keeps the entry. Such
an entry does not match a new role with the same name, because EKS stores the ID of the role.
The Amazon EKS User Guide,
[*Create access entries*](https://docs.aws.amazon.com/eks/latest/userguide/creating-access-entries.html),
gives this behavior.

`clean.sh` also keeps the cluster and its VPC when a node group delete does not finish. It
keeps them when a builder part remains, for example a builder network interface, or when it
cannot read a builder part.

After the deletes, `clean.sh` examines each resource again. When a resource remains or a lookup
fails, `clean.sh` exits with a non-zero code. After an interrupted run, `clean.sh` finds the
resources of the run through their tags and the state file, and deletes them.

An earlier, separate run, `20261120t233952zb5b5`, shows a clean-up after an interrupted run.
The values in this paragraph come from that run, not from the fresh run. `setup.sh` resumed
that run after stage `ami`, at commit
[`fb4aca3`](https://github.com/aws-samples/sample-eks-nitro-sandbox/commit/fb4aca3ec70d5c84e50c46e3254690a2c7090403)
of pull request #282, with `dirty=no`. The run stopped at stage `7/8` with
`E_MKFS_EROFS_UNKNOWN`, because the `mkfs.erofs -V` capture from the node was empty. Then three
`clean.sh` passes ran. The first pass deleted the namespace, the node groups, the launch
templates and the AMI with its snapshots. EC2 no longer listed the builder instance, and
`clean.sh` could not read it. Thus the first pass kept the cluster and its VPC, and 35 steps did
not complete. The second pass deleted the Pod Identity association and the cluster. It could
not read the operator role, so 1 step did not complete. Both passes exited with code 1. With
commit
[`da01d1c`](https://github.com/aws-samples/sample-eks-nitro-sandbox/commit/da01d1c074a4eb2d68b32c0f44b223313dc287a1)
of pull request #282, `clean.sh` reads an instance that EC2 no longer lists as gone. For the
operator role, that commit only keeps the error text of a failed read. A dry run before the
third pass listed no resource of the run. The third pass exited with code 0, and its read back
printed "nothing left behind". Its verdict shows `keep_ami=0`, `keep_cluster=0`, `failures=0`
and `verdict=clean`. The three passes record no commit, and the current `clean.sh` is newer
than the one they ran.

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
