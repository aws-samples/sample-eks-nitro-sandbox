# Build an Ubuntu AMI for EKS Pod Isolation

!!! danger "Not ready to merge to `main` as an available sample"

    This sample is **not ready to be merged to `main` and marked available** until the
    maintainers make one decision. The runtime binaries and guest image ship as one
    operator-supplied preview archive that a reader obtains from their AWS account team. Its
    exact name and every SHA-256 are pinned below, and it has no public download. Whether that
    meets the Issue #10 criterion that every required input is available to an external
    reader is waiting on the maintainers
    ([Issue #10 comment](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/10#issuecomment-6506808422)).
    The archive's license and redistribution terms are recorded with that decision.

    Until that decision, this sample stays a draft and is not marked `(available now)`.

!!! warning "Status: live-validated on the GA bundle, except the new test.sh section 7/7"

    Run `20261029t165642z8cdf` built the AMI from the Nitro sandbox GA node-build bundle dated
    2026-10-28, verified it on a second, fresh instance, joined the dedicated node group,
    passed every `./test.sh` check it had then (53 passed, 0 failed), and was then cleaned up
    with its AMI kept. After that run, the validation sandbox was changed to boot with no
    network, which replaced `./test.sh` section 7/7. Every output block under
    [Evidence](#evidence) comes from that run except the new section 7/7, which waits for a
    fresh run. Every clusterless check is proven both ways (see
    [Clusterless checks](#clusterless-checks)).

Build a custom Ubuntu 24.04 node AMI for Amazon EKS Pod Isolation, add one dedicated,
tainted managed node group to an **existing cluster**, and run an isolated pod on that
node. Ubuntu is the **node operating system**; application containers can use their own
distributions.

This sample serves readers who manage their own node OS and cannot rely on the managed
AMI that [Getting started](../../getting-started/hello-sandbox/README.md) depends on
(EKS Auto Mode provisions sandbox-capable nodes for you, with no AMI build). It adds one
new, tainted node group; the cluster's existing node groups and workloads are untouched,
and this sample never replaces or reconfigures an existing node group.

!!! warning "Stops on a documented prerequisite"

    The Nitro sandbox runtime archive (`nitro-sandbox-binaries-2026-10-28.zip`: the
    containerd shim and CRI proxy, Firecracker and its jailer, the guest boot image and root
    disk, the policy generator and the key provider) is an **operator-supplied preview
    archive, checksum-pinned, with no public download**. Every other input is public, pinned
    and checksum-verified, including the
    host-kernel change, which is AWS's public kernel commit on GitHub. Until you place the
    archive where `config.env` says, `./setup.sh --prepare` stops cleanly at that
    prerequisite rather than substituting an internal or private artifact. See
    [The runtime archive](#the-runtime-archive).

```mermaid
flowchart TB
  A["Ubuntu 24.04 EKS base AMI"] --> B["Build host: kernel + erofs-utils + runtime"]
  B --> C["Fresh instance verification"]
  C --> D["Dedicated Ubuntu managed node group"]
  D --> E["Isolated pod in a Nitro guest"]
```

Allow a few hours for a fresh build: most of it is the kernel compile on the build host.
This is a planning estimate, not a timing measurement from a live run.

*Figure 1: The ubuntu-ami architecture, from pinned public inputs to the isolated sandbox
pod. Pinned public inputs feed the build host; the user-supplied runtime archive installs
once present. The build host bakes the AMI, a fresh instance verifies it, then the verified
AMI joins the dedicated, tainted managed node group, leaving the cluster's existing node
groups untouched.*

![The ubuntu-ami sample's architecture. Outside AWS Cloud: three pinned public inputs
(Linux kernel source, erofs-utils source, distro packages) feed into the build host, and a
dashed box for the EKS Pod Isolation runtime, marked user-supplied and pending public
release, feeds the build host's SSM Session Manager once installed. Inside AWS Cloud: the
build host (EC2, no inbound rule, reached only over SSM) builds the AMI and bakes it into a
fresh instance for verification. The verified instance joins the existing Amazon EKS
cluster's dedicated managed node group, which carries a NoSchedule taint and is separate
from the cluster's existing, untouched node groups. Inside that node group, the Ubuntu node
(EC2 instance) runs an isolated sandbox pod with runtimeClassName isolated-sandbox,
containing a Nitro guest VM with its own kernel and guest virtio block
devices.](images/architecture.png)

## How this differs from Getting started

[Getting started > Hello sandbox](../../getting-started/hello-sandbox/README.md) needs no
AMI: EKS Auto Mode already runs a sandbox-capable managed AMI, and the runtime classes
are there on day one. This sample is for the opposite case: a cluster that manages its
own node OS, where the sandbox-capable AMI does not exist yet and someone has to build
it.

- **One dedicated, tainted managed node group.** The build produces a launch template and
  a managed node group with a `NoSchedule` taint, so only a pod that explicitly tolerates
  it lands there. No existing node group is modified, relaunched or drained.
- **Starts from Getting started.** Run [hello-sandbox](../../getting-started/hello-sandbox/README.md)
  first so you have a cluster with the `isolated-sandbox` RuntimeClass; this sample adds
  compute to that cluster, it does not create one.
- **A build, not just a deploy.** The other samples apply manifests to compute that
  already exists. This one also builds the node image: resolve the base AMI, build a
  kernel, build `erofs-utils`, install the runtime, bake and verify a fresh instance,
  then join it.

## Prerequisites

- A cluster that has finished [Getting started > Hello sandbox](../../getting-started/hello-sandbox/README.md):
  EKS 1.36 or later with the `isolated-sandbox` RuntimeClass present. The sample reuses
  that RuntimeClass as it is and never creates or changes it; it checks that every label
  the RuntimeClass selects (`eks.amazonaws.com/nitro-sandbox=true`) is one the sample's
  node registers with, and stops if not.
- **The managed `vpc-cni` add-on.** A managed node group node gets its pod network from
  this add-on's `aws-node` DaemonSet; EKS Auto Mode nodes do not need it, so a cluster that
  only ran Getting started can lack it, and then the sample's node never becomes `Ready`.
  Its network policy setting can be on or off: the sample ships no network policy, and its
  validation sandbox boots with no network. This is a cluster-wide install, so you install
  it yourself, at a version you pin; the sample only checks that it is `ACTIVE`
  ([`scripts/00c-check-cluster.sh`](scripts/00c-check-cluster.sh)) and stops with this
  command when it is missing:

  ```bash
  aws eks describe-addon-versions --region <AWS_REGION> --addon-name vpc-cni \
    --kubernetes-version 1.36 --query 'addons[0].addonVersions[].addonVersion'
  aws eks create-addon --region <AWS_REGION> --cluster-name <CLUSTER_NAME> \
    --addon-name vpc-cni --addon-version <VPC_CNI_ADDON_VERSION> \
    --resolve-conflicts NONE
  ```

  `--resolve-conflicts NONE` makes the create fail only when the add-on would have to
  overwrite a value that is already set; it does not leave an existing `amazon-vpc-cni`
  ConfigMap alone. If the cluster already has that
  ConfigMap and nothing owns it, as the cluster this sample was validated on did, the add-on
  adopts it: it adds its chart's default keys and its Helm labels, and keeps
  `enable-network-policy-controller` as it was. Record the version you chose as
  `VPC_CNI_ADDON_VERSION` in `config.env`; each run records the version it found.

  If some of the cluster's nodes run another CNI, keep `aws-node` off them with the add-on's
  `affinity` configuration value. Keep the chart's default requirements and append a `NotIn`
  requirement for those nodes' label to the same term's `matchExpressions`: the requirements in
  one term must all hold, while separate `nodeSelectorTerms` are alternatives, so a term of its
  own would not keep `aws-node` off those nodes. This is the value the validation cluster's
  add-on used, with its node label key shown as `<OTHER_CNI_NODE_LABEL>` (that install also
  set `enableNetworkPolicy`, which this sample does not need). Save it to a file and add
  `--configuration-values file://<file>` to the `create-addon` command:

  ```json
  {
    "affinity": {
      "nodeAffinity": {
        "requiredDuringSchedulingIgnoredDuringExecution": {
          "nodeSelectorTerms": [
            {
              "matchExpressions": [
                {"key": "kubernetes.io/os", "operator": "In", "values": ["linux"]},
                {"key": "kubernetes.io/arch", "operator": "In", "values": ["amd64", "arm64"]},
                {"key": "eks.amazonaws.com/compute-type", "operator": "NotIn", "values": ["fargate", "hybrid", "auto"]},
                {"key": "<OTHER_CNI_NODE_LABEL>", "operator": "NotIn", "values": ["true"]}
              ]
            }
          ]
        }
      }
    }
  }
  ```

- **A kubectl context for the same cluster, named in `KUBE_CONTEXT`.** Every `kubectl` call
  the scripts make passes `--context "$KUBE_CONTEXT"`; there is no fallback to the current
  context, and nothing runs `kubectl config use-context`. Before the first change,
  `./setup.sh`, `./test.sh` and `./clean.sh` compare that context's server URL with the API
  endpoint `aws eks describe-cluster` reports for `CLUSTER_NAME`, and stop on a mismatch or
  an unreadable context, so the kubectl side and the AWS side are always the same cluster.
- Private subnets in the cluster's VPC with egress to Ubuntu's `apt` mirrors, kernel.org,
  git.kernel.org, github.com, Amazon S3, and the EKS, EC2 and SSM APIs. This sample creates
  no network infrastructure.
- [`aws`](https://github.com/aws/aws-cli) CLI v2, [`kubectl`](https://github.com/kubernetes/kubectl),
  the [AWS Session Manager plugin](https://github.com/aws/session-manager-plugin), Python 3,
  `curl` and `tar`.
- Operator IAM permissions to create and remove EC2 instances, images, snapshots, a
  security group, a launch template, IAM roles, inline role policies and instance profiles,
  an S3 bucket (create, tag, Block Public Access, default encryption, bucket policy, put and
  delete objects, delete), and an EKS managed node group; to list and delete the cluster's
  access entries (the clean up removes the one EKS creates for the node role); to read the
  cluster, its add-ons and the Canonical SSM parameter; plus SSM Run Command access to the build and
  verification instances. These are the credentials you run `./setup.sh` with; the sample
  then creates two **scoped** roles of its own (below).
- **The two scoped roles the sample creates for the resources it launches.**
  [`scripts/00a-iam.sh`](scripts/00a-iam.sh) (run for you by `./setup.sh`) creates:
  - a **build-host instance role** with `AmazonSSMManagedInstanceCore` (SSM, no inbound
    rule) and nothing else standing. For the few minutes the build host downloads its
    staged files, `./setup.sh` adds
    [`deploy/iam-build-host-policy.json`](deploy/iam-build-host-policy.json), rendered for
    this run: `s3:GetObject` on `<staging-bucket>/<run-id>/*` and `s3:ListBucket` limited to
    that prefix (the Systems Manager document `AWS-RunRemoteScript` that downloads the
    objects needs both), then deletes it again;
  - an **EKS node role** with the standard worker policies
    ([`deploy/iam-node-trust-policy.json`](deploy/iam-node-trust-policy.json)'s trust plus
    `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonEKS_CNI_Policy`
    and `AmazonSSMManagedInstanceCore`).

  Both are named for the run (`<RESOURCE_PREFIX>-<RUN_ID>-build` and `-node`) and tagged
  `ManagedBy=<RESOURCE_PREFIX>` and `RunId=<RUN_ID>`, so `./clean.sh --delete-aws-resources`
  removes them and nothing else. A same-named role is reused only when it carries both tags,
  the trust policy above, exactly the managed policies above and no inline policy; anything
  else stops the run. Neither is an admin role.
- **IMDSv2 only, hop limit 1, on every instance the sample launches.** The build host, the
  verification instance and the node group's nodes (through the launch template) all require
  IMDSv2 tokens with a response hop limit of 1. That stops an ordinary pod, one that does not
  use the host's network, from getting a token, so it cannot read the node role's credentials
  through the metadata service. It is not a boundary for a pod that runs with
  `hostNetwork: true`, or for a privileged pod, which can enter the host's network: such a pod
  reaches the metadata service as the node does. The VPC CNI's own `aws-node` pods run on the
  host network and use the node role, which is why that role carries `AmazonEKS_CNI_Policy`.
  Any other pod that needs AWS access should use EKS Pod Identity, not the node's role. Each
  launch spec is rendered, checked
  ([`scripts/lib/launch_spec.py`](scripts/lib/launch_spec.py)) and sent to EC2 as that same
  file.
- **SSM-based build-host access, no inbound rule.** The build security group opens no
  inbound port (`./setup.sh` checks it has none); you reach the build and verification
  instances over SSM, which needs no bastion, no SSH key and no open port.
- **A build instance type with room for the kernel compile.** The default build host is
  `m8i.4xlarge`, the type the GA bundle's kernel build was validated on; on `m8i.xlarge`
  the compile takes about four times as long. Nitro Enclaves must be enabled on it (the
  script does that) and Secure Boot off (Canonical's EKS AMI boots with it off; the build
  checks).

### Public inputs, pinned and checksum-verified

Every input in this list is public, and the build verifies each one against the pin
below before using it; a mismatch aborts the build with no override flag. The lock file,
[`packages/sources.lock`](packages/sources.lock), is the one tracked place all of these
pins live, with a note on how each was obtained and verified. The plain-text
[`packages/SOURCES.txt`](packages/SOURCES.txt) gives the same provenance in prose.

| Input | Pin | SHA-256 | Source |
|---|---|---|---|
| Ubuntu 24.04 EKS base AMI | Kubernetes 1.36 | n/a (signed AMI) | Canonical's public EKS AMI SSM parameter path, resolved per Region at build time |
| Linux kernel source | `6.18.56` | `4633bbda2ab95eaf2a7af4041236451d6759c72e6946265531af4b3aacefbf89` | [`linux-6.18.56.tar.xz`](https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.56.tar.xz) on kernel.org |
| Host-kernel patch | commit `1e66c960b982c94bda76ebd0129eaecf0a68b46e` | `051ede9dff52d24fb7ff47dd783a9eb2f6b18c742dbf151926cb48304d72924b` | [amazonlinux/linux 1e66c960 as a patch](https://github.com/amazonlinux/linux/commit/1e66c960b982c94bda76ebd0129eaecf0a68b46e.patch) on GitHub |
| erofs-utils source | `1.8.10` | `05eb4edebe11decce6ecb34e98d2f80c8cd283c2f2967d8ba7efd58418570514` | kernel.org cgit snapshot `erofs-utils-1.8.10.tar.gz` |
| Distro packages | capability-asserted, versions recorded from the run | verified by `apt`'s signed repository metadata | Ubuntu `apt` repositories |

How each pin was checked:

- **Kernel.** The SHA-256 is the `linux-6.18.56.tar.xz` line of kernel.org's
  [`sha256sums.asc`](https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc), whose
  signature verifies with the Kernel.org checksum autosigner key
  (`B8868C80BA62A1FFFAF5FDA9632D3A06589DA6B1`, from kernel.org's `pgpkeys` repository); the
  tarball also verifies against its stable-release signature `linux-6.18.56.tar.sign`
  (`647F28654894E3BD457199BE38DBBDC86092693E`).
- **Host-kernel patch.** One squashed public commit on Amazon Linux's kernel tree,
  `nitro_enclaves: Amazon Nitro Enclaves extension (port onto 6.18.48)`, which applies
  cleanly to kernel.org 6.18.56. GitHub serves any commit as a patch at its commit URL plus
  `.patch`; [`packages/fetch-kernel-patch.sh`](packages/fetch-kernel-patch.sh) checks the
  SHA-256 and the commit id in the patch's first line before the file takes its final name,
  and the kernel build applies it with `git am` and checks it landed as exactly one commit
  with that subject.
- **erofs-utils.** A cgit snapshot of a tag has no upstream-published checksum, so the
  SHA-256 is pinned by this sample itself (confirmed identical across independent fetches).
- **Base AMI.** No SHA-256 to pin: it is a signed image resolved from a Parameter Store
  value Canonical's own AWS account owns. Canonical republishes it under new serials (the
  image name ends in the serial), so the build records the image ID, name and serial it
  resolved rather than hard-coding a Region-specific AMI ID, and checks that image's
  containerd before it builds anything.

No bare `latest` or moving tag is used anywhere in the build. A version bump re-records the
pin and SHA-256 here, in the lock file and in `packages/SOURCES.txt`, and the build
re-asserts the kernel config and re-runs the live checks. Checking a version string alone is
not sufficient.

To produce one offline-consumable archive of the pinned public file inputs (kernel,
host-kernel patch, erofs-utils) with its SBOM, license summary and provenance record, run
[`packages/make-bundle.sh build`](packages/make-bundle.sh); consume a pre-built bundle on
a restricted-network host with `packages/make-bundle.sh consume <bundle-dir>`. The runtime
archive is never bundled.

### The runtime archive

The runtime ships as one flat zip, `nitro-sandbox-binaries-2026-10-28.zip`, with a
`SHA256SUMS` inside that covers all eight files. It is an operator-supplied preview archive, checksum-pinned, with no public download: **ask your AWS account team for it**. Never commit it, and never put
it in this sample folder.

| File | SHA-256 | Installed on the node as |
|---|---|---|
| `nitro-sandbox-binaries-2026-10-28.zip` (the archive) | `6830dc8d0acb356b06753fed609ebb9f03a182e340eaa27cd9ed171f7667ba40` | not installed; verified, unpacked, then removed before baking |
| `containerd-shim-nitro-sandbox-v2` | `991a3786577d19ec3ee5005c90530cc1b2464c052af0218b1064f54c3c2aa7c9` | `/usr/sbin/containerd-shim-nitro-sandbox-v2`, mode 0755 (also the CRI proxy) |
| `firecracker` | `13a369b76af5f87039944f52dd6c4ef292cfdfc818a9b6e87d174b86920f5a31` | `/usr/bin/firecracker`, mode 0755 |
| `jailer` | `b7067964a02a0f6a35244a54a763f8bc420dac8c5ff4d471b2102845357293a3` | `/usr/bin/jailer`, mode 0755 (it unpacks as 0644) |
| `eks-nitro-sandbox-genpolicy` | `8bb076d5f4c631f9a0a91c58f249876f49d1c4f794b7241fbbbb2398da3fbad2` | `/usr/local/bin/eks-nitro-sandbox-genpolicy`, mode 0755 |
| `nitro-sandbox-keyprovider` | `57407a2f47e56ee46736bcdce73d48a6a10af25c613dfa08370cd0c081814c3f` | `/usr/local/bin/nitro-sandbox-keyprovider`, mode 0755 |
| `latest.eif` | `31f21cf805e193710295a1dbee2e98847c4d8a0cc040597cb6abc39d3aad5105` | `/var/lib/nitro-sandbox-images/latest.eif`, mode 0644 (guest boot image, guest kernel 6.18.54) |
| `latest-disk.img` | `932a251aab211785c10620ab17ac314f5c09da3c2b61f7917acdf2208b6c3eb7` | `/var/lib/nitro-sandbox-images/latest-disk.img`, mode 0644, with `rootfs.ext4` linked to it |
| `nitro-sandbox-agent` | `df85d0ea5b5021004110b2322283e2bd35b01c668ffd838573bc8f28bc8b6b8c` | not installed on the host: the copy inside `latest-disk.img` runs in the guest |

Place the archive in `RUNTIME_ARTIFACTS_DIR`, which defaults to the repository's gitignored
`tmp/issue10/run/runtime` (all of this sample's local state lives under `tmp/issue10/run`, in
`logs/`, `out/` and `runtime/`). [`packages/fetch-runtime-artifacts.sh`](packages/fetch-runtime-artifacts.sh)
checks the archive's SHA-256, refuses any member that is not a plain file with a flat name,
unpacks it, and then fails closed unless `SHA256SUMS` lists every unpacked file exactly once,
every hash matches, and every file matches its pin in `packages/sources.lock`, so a
re-packed archive whose `SHA256SUMS` was edited to match is still refused.

## Build

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/setup/ubuntu-ami
cp config.env.example config.env
# Set KUBE_CONTEXT (the kubectl context of CLUSTER_NAME), BUILD_SUBNET_ID, NODE_SUBNET_IDS and
# VPC_CNI_ADDON_VERSION. Your usual CLUSTER_NAME, AWS_REGION and AWS_PROFILE remain in effect.
# The scripts pass --context "$KUBE_CONTEXT" to every kubectl call and never change the
# current context.
$EDITOR config.env

./setup.sh --prepare   # local only: verify every pinned input and the runtime archive
./setup.sh             # check the cluster, build, bake, verify, join, and run the pods
# or in two stages:
#   ./setup.sh --ami-only              # build, verify and tag the AMI; no cluster needed
#   RUN_ID=<id> ./setup.sh --join      # later: join that run's AMI and run the pods
./test.sh              # read live node and guest evidence again
./clean.sh --dry-run   # preview what a full clean up would remove
```

The sample uses its own namespace, `ubuntu-ami-sample` (`NAMESPACE` in `config.env`), not the
home page's `nitro-sandboxes-demo`: `./clean.sh` deletes the namespace the run created, so it
must be one no other sample uses.

```mermaid
flowchart TB
  P["Verify pinned inputs + runtime archive locally"] --> Q["Check vpc-cni add-on + RuntimeClass (read only)"]
  Q --> Z["Create scoped IAM roles + build-host instance profile"]
  Z --> A["Resolve base AMI via SSM; record serial"]
  A --> S["Per-run S3 staging bucket; upload scripts + runtime archive"]
  S --> B["Build host downloads + verifies; containerd 2.1 to 2.3 gate"]
  B --> C["Kernel 6.18.56 + public patch; assert .config after olddefconfig"]
  C --> D["erofs-utils 1.8.10 with zstd"]
  D --> G["Install runtime; wire containerd + kubelet; load AppArmor profile"]
  G --> H["Bake; verify a fresh instance; tag BtfValidated=true"]
  H --> I["Join tainted node group; wait for nitro-sandbox capacity; apply pods"]
```

**Every run has its own id.** `./setup.sh` picks a run id (a UTC timestamp plus four random hex
digits, such as `20261028t221500z3f9a`, or the `RUN_ID` you pass to resume a run), reserves the
run's folder so no other start can share it, and records the id as the current run in
`tmp/issue10/run/out/run-state.env` just before its first AWS change, so a run that stops on a
read-only check leaves the previous run as the current one; the run's private evidence goes under
`tmp/issue10/run/out/runs/<run-id>/evidence/`. Every name the run creates is derived from it
(`<RESOURCE_PREFIX>-<RUN_ID>-build` for the build role and instance profile, `-node` for the
node role, `-build-sg`, `-lt`, `-ng`, `-verify`, `-stage-read` for the staging policy, and
`<RESOURCE_PREFIX>-stage-<RUN_ID>-<6 hex>` for the bucket), checked against the IAM, EKS and
S3 name limits, and every AWS resource it creates carries both `ManagedBy=<RESOURCE_PREFIX>`
and `RunId=<RUN_ID>`, including the verification instance and, through the launch template,
every node instance and volume. A resource with the run's name is reused only when it carries
both tags; a mismatch or a failed lookup stops the run. The namespace carries
`app.kubernetes.io/part-of=<RESOURCE_PREFIX>` and `app.kubernetes.io/instance=<RUN_ID>`. The
run's record (`tmp/issue10/run/out/runs/<run-id>/run-state.env`) also names the
`CLUSTER_NAME` and `AWS_REGION` it started with: a resume, `--join`, `./test.sh` or
`./clean.sh` of that run with another cluster or Region stops before any call. One process at a
time acts on a run: `./setup.sh`, `./test.sh` and `./clean.sh` each take the run's lock first,
and refuse the run while another holds it. `./clean.sh --list-runs` needs no run and no lock.

**Build the AMI now, join it later.** `./setup.sh --ami-only` checks the inputs, runs steps 2
to 7 below through the `BtfValidated=true` tag, records the AMI ID in the run's
`tmp/issue10/run/out/runs/<run-id>/run-state.env`, and stops. It never reads or changes the
cluster, so it needs no `KUBE_CONTEXT`, no `vpc-cni` add-on and no `NODE_SUBNET_IDS`; set
`CLUSTER_NAME` to the cluster you will join, because the run's record keeps it. The
`cilium-ubuntu` sample (issue #11) needs only this AMI. `RUN_ID=<id> ./setup.sh --join` does
step 8 for that run: before it changes anything, it checks that the run's AMI carries
`ManagedBy`, the run's `RunId` and `BtfValidated=true`, that `KUBE_CONTEXT` is
`CLUSTER_NAME`, and that the cluster prerequisites in step 1 hold; then it joins the node group
and applies the pods. It never builds an AMI. Without either flag, `./setup.sh` does both in
one run and checks the cluster first, before anything is created.

**Every wait has a deadline.** The AWS CLI waiters give up after about 100 seconds for an SSM
command and 600 seconds for an AMI, which is less than the kernel build and a large snapshot
can take, so [`scripts/lib/aws-wait.sh`](scripts/lib/aws-wait.sh) polls instead. An SSM
command is read about every 15 seconds until it ends, for up to its own `executionTimeout`
plus 300 seconds, and `Failed`, `Cancelled`, `TimedOut`, `Undeliverable` or `Terminated`
stops the run. A new AMI is read until it is `available`, for up to `AMI_WAIT_SECONDS`
(default 7200, in `config.env`; this sample's 120 GiB AMI took about 55 minutes); `failed`,
`error` or the deadline stops the run and names the
AMI. After the reboot onto the new kernel, the build host must answer with a new boot ID and
`uname -r` equal to `6.18.56-nitro-ga` within `REBOOT_WAIT_SECONDS` (default 1200) before the
next stage runs, and the run's evidence records both boot IDs. A read that keeps failing ends
in "could not determine", which stops the run.

**1. Check the inputs and the cluster.** `./setup.sh --prepare` verifies every pinned input
and the runtime archive on your workstation and creates nothing. A full `./setup.sh` then
reads two cluster-wide prerequisites before it creates anything: the `vpc-cni` add-on is
`ACTIVE`, and the shared `isolated-sandbox` RuntimeClass selects only labels the sample's
node will carry. It stops with the command to run if either is not so.

**2. Resolve the base AMI.** The build resolves the Canonical EKS Ubuntu 24.04 AMI for
Kubernetes 1.36 from the public SSM parameter path for your Region at run time, and records
the image ID, name and serial it got in the run's private evidence (under
`tmp/issue10/run/out/runs/<run-id>/evidence/`), not on the image. It never hard-codes an AMI
ID or serial.

**3. Stage the files through a private, per-run S3 bucket.** The runtime archive is about
150 MB and its guest disk unpacks to 2 GiB, so nothing large is pushed through an SSM shell.
[`scripts/00b-stage-bucket.sh`](scripts/00b-stage-bucket.sh) creates a bucket for this run,
tagged `ManagedBy=<RESOURCE_PREFIX>` and `RunId=<run-id>`, with S3 Block Public Access on,
default encryption (SSE-S3) and the TLS-only policy in
[`deploy/s3-stage-bucket-policy.json`](deploy/s3-stage-bucket-policy.json); it uploads the
sample's scripts and the archive with their SHA-256 (S3 checks it on receipt) and grants the
build-host role read on this run's prefix only. The build host downloads them with its
instance profile and checks each SHA-256 against the value `./setup.sh` sends over SSM, not
one read from the bucket. If any staging step fails after the bucket exists, the helper removes
what it created before it stops. Then the staged objects and the build role's read are deleted,
but only after the bucket and the role are confirmed to carry this run's two tags and the role's
staging policy is confirmed to be exactly this run's read; the revocation then confirms both
are gone: if either is still there, it records what is left in the run's state and the run
stops. The empty bucket stays until
`./clean.sh --delete-aws-resources` removes it.

**4. Check containerd, then build the host kernel.** The build host's first preflight reads
the booted base image's containerd: the GA shim runs on containerd 2.1.x, 2.2.x and 2.3.x,
and the build stops before anything is compiled on 2.4 or later, or anything older than 2.1
(a new Canonical serial can ship a newer containerd). [`scripts/10-kernel.sh`](scripts/10-kernel.sh)
then fetches and verifies kernel.org `linux-6.18.56.tar.xz` and the public patch, applies the
patch in a throwaway git repository and checks it is the expected single commit, and starts
`.config` from the running node's own config. It asserts on the result of `olddefconfig`,
because `olddefconfig` silently drops a symbol whose menu gate is off:

- `CONFIG_NITRO_ENCLAVES=y`, built in and never a module: the `nitro_enclaves.mempool=` boot
  argument reserves the enclave memory pool early in boot, and does nothing when the driver
  is a module;
- `CONFIG_CMA=y`, `CONFIG_DEBUG_INFO_BTF=y` and `CONFIG_DEBUG_INFO_BTF_MODULES=y` (kernel and
  module BTF for eBPF, which Cilium's datapath needs);
- `CONFIG_VHOST_VSOCK`, `CONFIG_EROFS_FS` and `CONFIG_TUN`, built in or modules;
- the menu gates `CONFIG_VIRT_DRIVERS`, `CONFIG_VSOCKETS` and `CONFIG_VHOST_MENU`;
- `CONFIG_EXT4_FS`, built in or a module. The build sets it built in (`y`), which needs no
  module at boot; if `olddefconfig` leaves it a module, the build requires `ext4.ko` in the
  new initramfs.

It installs `dwarves` (pahole, which builds BTF from DWARF), `gawk` (Ubuntu ships `mawk`,
and the link step needs `gawk`) and `libdw-dev` (Canonical's config sets
`CONFIG_GENDWARFKSYMS=y`), compiles with DWARF 4, installs the modules with
`INSTALL_MOD_STRIP=1` (their DWARF is stripped, their BTF stays), checks the kernel release
is `6.18.56-nitro-ga`, adds the `nitro_enclaves.mempool` and `nitro_enclaves.ne_cpus` boot
arguments, and pins the new kernel as the GRUB default (the stock kernel sorts newer).

SSM Run Command returns only the first 24,000 characters of a command's output, and the kernel
stage prints far more than that, so its `.config` assertion lines do not reach the run's
evidence. The kernel configuration on this page is therefore read from
`/boot/config-6.18.56-nitro-ga` on a node launched from the AMI:

```text
SHA256=5b19a3e6b6532ec3f88edafa4f25cff4c27e121d7a7ec59c33c6efa0c50a8f4a
LINES=12010
CONFIG_LOCALVERSION="-nitro-ga"
CONFIG_CMA=y
CONFIG_VSOCKETS=y
CONFIG_TUN=y
CONFIG_VIRT_DRIVERS=y
CONFIG_NITRO_ENCLAVES=y
CONFIG_VHOST_MENU=y
CONFIG_VHOST_VSOCK=m
CONFIG_EXT4_FS=y
CONFIG_EROFS_FS=m
CONFIG_SECURITY_APPARMOR=y
CONFIG_DEBUG_INFO_DWARF4=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_BTF_MODULES=y
```

*Abridged.* Read on the node of run `20261029t165642z8cdf` through one `kubectl debug node`
helper pod: the node printed the file's SHA-256 and line count, then the file, and the block
shows those two lines and the 14 required lines of its 12,010, in file order. No value was
replaced.

**5. Build erofs-utils with zstd.** The containerd shim builds each container's EROFS
filesystem with zstd and has no fallback, and Ubuntu 24.04's erofs-utils 1.7.1 has no zstd.
The build fetches the `1.8.10` snapshot, verifies it, builds it with
`--enable-lz4 --with-libzstd` into `/usr/local`, purges Ubuntu's package, and checks that
`mkfs.erofs` reports 1.8.10 and compresses with zstd when run as a systemd service, which is
how containerd runs it.

**6. Install and wire the runtime.** [`scripts/30-runtime-install.sh`](scripts/30-runtime-install.sh)
re-verifies the archive, installs each file at the path and mode in the table above, links
`rootfs.ext4`, writes `/etc/containerd/nitro-sandbox.toml` with `debug = false` (the
production setting; `SHIM_DEBUG=true` gives debug-mode enclaves for troubleshooting only), and
installs and enables, but does not start, `cri-proxy.service`.
[`scripts/31-wire-containerd.sh`](scripts/31-wire-containerd.sh) adds the `isolated-sandbox`
and `confidential-sandbox` handlers to Canonical's containerd template
`/usr/local/share/eks/containerd-config.toml` (config version 2, with
`discard_unpacked_layers = false` inside its existing cri containerd table) and checks
containerd's own `config migrate` and `config dump` show both, points kubelet's endpoint at
`unix:///run/nitro-sandbox/cri-proxy.sock` in `/usr/local/share/eks/bootstrap.sh`, and adds
the `snap.kubelet-eks.daemon.service.d/50-cri-proxy.conf` ordering drop-in. Both files are
templates because Canonical's bootstrap regenerates the live ones at join.
[`scripts/35-apparmor.sh`](scripts/35-apparmor.sh) loads the sample's scoped AppArmor profile
and stops unless the kernel reports it in enforce mode and its load service is enabled
(`systemctl enable` and `is-enabled` both checked).
[`scripts/36-hold-packages.sh`](scripts/36-hold-packages.sh) finds the package that owns the
`containerd` binary with `dpkg -S` and holds what it finds (on Canonical's serial `20261027`
that was `containerd`), together with the installed Ubuntu kernel meta-packages, with
`apt-mark hold` and in `Unattended-Upgrade::Package-Blacklist`, so an
unattended upgrade can neither move containerd past the GA shim's range nor pull a stock
kernel that GRUB could boot instead of `6.18.56-nitro-ga`. Everything else keeps the base
AMI's update policy: package-list refresh and unattended security upgrades stay on.

> **Trade-off: held packages get updates only through a new AMI build.** containerd and the
> held kernel meta-packages receive no security fix on a running node. Rebuild the AMI to
> pick them up, and replace the node group's nodes with it.

**Observe:** a completed `./setup.sh` writes a plain-text manifest on the image,
`/etc/ubuntu-ami-sample-manifest`, recording the kernel release and the SHA-256 of its
tarball and patch, the erofs-utils version and installed binary hash, each installed runtime
file's path, mode and SHA-256, the observed containerd version and the shim's debug setting,
so a later reader can audit the image without the build host.

**7. Verify a fresh instance, then tag the AMI `BtfValidated=true`.** Before baking,
[`scripts/50-bake-prep.sh`](scripts/50-bake-prep.sh) removes the kernel tree, the downloaded
kernel tarball and patch, the archives, the staged downloads, the build toolchain, SSH host
keys and the machine ID, and refuses to continue if any of them is still there, or if its scan
for them fails ("could not determine" is a failure, never a pass). It does not change the
base AMI's apt update policy. After the AMI
is registered, `./setup.sh` launches a SECOND, fresh instance from it
([`scripts/verify-fresh-instance.sh`](scripts/verify-fresh-instance.sh)) and runs
[`scripts/verify-image.py`](scripts/verify-image.py) and `40-smoke.sh` on that instance, never
on the build host's own run. `verify-image.py` checks the kernel release
`6.18.56-nitro-ga`, `/dev/nitro_enclaves`, BTF, a CMA reservation, vsock, TUN, EROFS,
AppArmor with the scoped profile loaded, containerd 2.1.x to 2.3.x, both handlers, the kubelet
endpoint, `mkfs.erofs` 1.8.10 with zstd as a service sees it, and every installed runtime file
against `SHA256SUMS` and its pin, the AppArmor profile in enforce mode, and the package
holds. Each check raises its own failure (no Python `assert`, which `python3 -O` would
remove). Only once both checks pass does the script tag the AMI
`BtfValidated=true` ([`scripts/lib/btf-tag.sh`](scripts/lib/btf-tag.sh)), alongside the
`ManagedBy=<RESOURCE_PREFIX>` ownership tag, the pinned kernel and erofs-utils versions and
the verification run's id. If verification fails, the AMI never receives `BtfValidated=true`,
and the tagging step refuses any AMI that does not already carry both of this run's tags
(`ManagedBy` and `RunId`). The verification instance is terminated however the script ends. This tag is the contract the `cilium-ubuntu` sample's (issue #11) AMI preflight checks:
`BtfValidated=true` means "a fresh instance booted from this AMI passed this sample's
host-readiness and BTF checks," never "an AMI was merely created."

**8. Join the dedicated node group, then wait for sandbox capacity.**
[`scripts/join-nodegroup.sh`](scripts/join-nodegroup.sh) creates the launch template and the
tainted managed node group. With a custom AMI, EKS does not merge its own user data and
applies the node group's labels and taints only after the node registers, so the node sets
them itself through Canonical's `bootstrap.sh --kubelet-extra-args`:
`--node-labels=eks.amazonaws.com/nodegroup=<NODEGROUP_NAME>,eks.amazonaws.com/nitro-sandbox=true,sandbox.preview/nitro=true`
and `--register-with-taints=sandbox.preview/ubuntu-ami=true:NoSchedule`, checked in the
rendered user data before the launch template is created: with comments and blank lines
stripped, the script must hold exactly one `/etc/eks/bootstrap.sh` command for this cluster,
with nothing after it and the cluster name as its last argument, after every option (the
script's usage is `bootstrap.sh [options] <cluster-name>`), and the labels and taint are read
from that command's own `--kubelet-extra-args`. The launch template data (IMDSv2 required, hop limit 1, enclaves on,
both run tags on every node instance and volume) is checked the same way, and the template
and the node group are named and tagged for the run. Before any pod is applied,
[`scripts/wait-node-ready.sh`](scripts/wait-node-ready.sh) waits until the node is `Ready`
and advertises allocatable `eks.amazonaws.com/nitro-sandbox` greater than zero (the extended
resource the RuntimeClass's overhead requests), and stops with a clear message if it does not.

> **containerd is a gate, not an install.** The build checks that the base image's
> containerd is one the GA shim runs on; it never upgrades or downgrades the containerd
> already on the base AMI.

## Evidence

> **Every block on this page is from one fresh run**, `20261029t165642z8cdf`: `./setup.sh
> --ami-only` (with the fresh-instance verification), then `RUN_ID=20261029t165642z8cdf
> ./setup.sh --join` and `./test.sh` (53 passed, 0 failed, with the section 7/7 it had then).
> The one exception is the new `./test.sh` section 7/7 under
> [The validation sandbox has no network](#the-validation-sandbox-has-no-network), which
> waits for a fresh run. Lines are copied whole and in order. Values from the test account
> are shown as placeholders, and the note under each block says which ones, and whether
> lines were left out.

**Node vs guest kernel, and host vs guest block devices.** The same shape Getting started
uses: the ordinary pod shares the node's kernel, `6.18.56-nitro-ga`, and sees the
instance's `nvme*` disks; the isolated-sandbox pod reports its own guest kernel, `6.18.54`
(the kernel inside `latest.eif`), and sees only virtio `vd*` disks, no `nvme*`.

```text
== 5/7 guest boundary: kernel and block devices, ordinary pod vs isolated-sandbox pod =====
  ordinary pod kernel:         6.18.56-nitro-ga
  ordinary pod /sys/block:     loop0 loop1 loop2 loop3 loop4 loop5 loop6 loop7 loop8 nvme0n1
  isolated-sandbox kernel:     6.18.54
  isolated-sandbox /sys/block: dm-0 vda vdb vdc
  PASS  the ordinary pod shares the host kernel 6.18.56-nitro-ga
  PASS  the sandbox pod runs the guest kernel 6.18.54, not the host's
  PASS  the ordinary pod sees the host's nvme* devices
  PASS  the sandbox pod sees virtio vd* devices and no nvme*
```

*`./test.sh` section 5/7, whole. No value was replaced; the trailing space at the end of the
two `/sys/block` lines was removed.*

**Boot uptime matches the pod's age**, because the VM boots with the pod, while the ordinary
pod reads the host's much longer uptime:

```text
== 6/7 guest boundary: boot uptime matches the sandbox pod's age, not the host's =========
  host uptime (ordinary pod): 582 s
  sandbox guest uptime:       452 s
  sandbox pod age:            460 s (started 2026-10-29T19:01:15Z)
  PASS  the sandbox guest booted with its pod (uptime <= pod age + 120 s)
  PASS  the sandbox guest booted after the host (guest uptime < host uptime)
```

*`./test.sh` section 6/7, whole. No value was replaced.*

**Host-requirement accept/reject controls.** Each control below is proven both ways: one
input that has the requirement and passes, one that is missing it and is refused, per this
repository's rule that a check proven only on good input cannot be told apart from one
that accepts everything.

| Control | Accepts | Refuses |
|---|---|---|
| Kernel config assertion | every required symbol present after `olddefconfig` | `CONFIG_NITRO_ENCLAVES=m`, BTF off or missing, module BTF off, CMA off, `VHOST_VSOCK` or `TUN` dropped, the `VIRT_DRIVERS` gate off |
| Root filesystem at boot | `CONFIG_EXT4_FS=y` with or without `ext4.ko`; `=m` with `ext4.ko` (plain or compressed) in the initramfs | `=m` with no `ext4.ko`, a file that only starts with `ext4.ko`, EXT4 not set |
| Host kernel | the node reports `6.18.56-nitro-ga` | any other release |
| BTF presence | `/sys/kernel/btf/vmlinux` present and non-empty | the same probe on a path that does not exist |
| Nitro Enclaves device | `/dev/nitro_enclaves` present after reboot | the same probe on a device that does not exist |
| CMA pool | a non-zero `CmaTotal` | the same probe on a key that does not exist |
| `vsock` and TUN | `/dev/vhost-vsock` and `/dev/net/tun` present | the same probes on devices that do not exist |
| EROFS + zstd | `mkfs.erofs` 1.8.10 builds a zstd image as a systemd service | erofs-utils without zstd |
| containerd | 2.1.x, 2.2.x, 2.3.x | 2.4.0 and later, 2.0.x and earlier, unreadable versions |
| Runtime archive | the pinned archive, every payload listed once and matching | a wrong archive hash, a tampered payload, a payload missing from `SHA256SUMS`, an unlisted extra file, a duplicate entry, a re-packed payload |
| Runtime wiring | both handlers in containerd's migrated config dump, the endpoint at the CRI proxy | a handler name that is not registered |
| Node labels and taint | one active `bootstrap.sh` command for this cluster, its name last after every option, whose `--kubelet-extra-args` carry all three labels and the taint | any one missing, the strings only in a comment, an `exit` before the command, two commands, a command for another cluster, the cluster name first or before an option |
| Launch specs | IMDSv2 required, hop limit 1, enclaves on, `ManagedBy` and `RunId` on instance and volume | IMDSv1 allowed, hop limit 2, no metadata options, IMDS off, enclaves off, a volume without `RunId`, another run's `RunId` |
| Kube context | the context's server is `CLUSTER_NAME`'s API endpoint | another cluster's server, an unknown context, no `KUBE_CONTEXT` |
| AppArmor stage | the profile loaded in enforce mode, its service enabled | complain mode, a failed `systemctl enable`, a service that is not enabled |
| AppArmor profile rules | `signal (receive)` from `runc` and `unconfined`, `signal (send,receive)` with itself, `audit deny /etc/shadow* w,`, no plain `deny` | a `signal` rule missing or only in a comment, a plain `deny`, no `/etc/shadow` rule, another profile name |
| Package holds | the containerd owner and the kernel meta-packages held and blacklisted | a hold missing from `apt-mark showhold` or from the blacklist |
| Bake residue | no build residue left | residue present, or a scan that fails |
| Sandbox capacity | the node advertises `eks.amazonaws.com/nitro-sandbox` > 0 | zero, absent, or a node that is not `Ready` |
| No network in the validation sandbox | the `network-isolated` annotation read back; only loopback has an address; no route; every interface but `lo` down (a `dummy0` that is down passes); the connect fails with `Network is unreachable` while the ordinary pod's connects | an extra IPv4 or IPv6 address, a route, an interface other than `lo` that is up, a refused or timed-out connect, an unreadable file or an incomplete read |

**`BtfValidated=true` applied only after fresh-instance verification passes.** The AMI tag
`cilium-ubuntu`'s (issue #11) AMI preflight requires before it will use an AMI from this
sample. Written by `scripts/verify-fresh-instance.sh` via `scripts/lib/btf-tag.sh`, never at
`create-image` time, and never when verification fails or the AMI is not this run's own
(`ManagedBy=<RESOURCE_PREFIX>` and `RunId=<RUN_ID>` checked first).

```text
[2026-10-29T18:28:52Z] Step 9/10: fresh-instance verification on a SECOND instance, then tag BtfValidated=true on success (scripts/verify-fresh-instance.sh)
[2026-10-29T18:28:52Z] launching fresh verification instance ubuntu-ami-sample-20261029t165642z8cdf-verify from <AMI_ID>
LAUNCH SPEC OK: <repository>/tmp/issue10/run/out/runs/20261029t165642z8cdf/verify-instance-launch.json
[2026-10-29T18:28:55Z] instance: <INSTANCE_ID>
[2026-10-29T18:32:44Z] running: verify-image.py
Success
{
  "image_configuration": "PASS",
  "failed": [],
  "checks": {
    "host_kernel": {
      "ok": true,
      "detail": "6.18.56-nitro-ga"
    },
    "nitro_enclaves_device": {
      "ok": true,
      "detail": "/dev/nitro_enclaves"
    },
    "btf": {
      "ok": true,
      "detail": "/sys/kernel/btf/vmlinux 6817696 bytes"
    },
    "cma": {
      "ok": true,
      "detail": "CmaTotal 14456832 kB"
    },
    "vsock": {
      "ok": true,
      "detail": "/dev/vhost-vsock"
    },
    "tun": {
      "ok": true,
      "detail": "/dev/net/tun"
    },
    "erofs": {
      "ok": true,
      "detail": "erofs in /proc/filesystems"
    },
    "apparmor": {
      "ok": true,
      "detail": "enabled; ubuntu-ami-sample-profile loaded in enforce mode"
    },
    "containerd_version": {
      "ok": true,
      "detail": "containerd 2.2.1 (2.2.1): supported by the GA shim (2.1.x to 2.3.x)"
    },
    "runtime_wiring": {
      "ok": true,
      "detail": "template, dump, bootstrap endpoint, shim config, drop-in and cri-proxy unit parsed and correct"
    },
    "guest_image": {
      "ok": true,
      "detail": "/var/lib/nitro-sandbox-images: latest.eif, latest-disk.img, rootfs.ext4 -> latest-disk.img"
    },
    "mkfs_erofs": {
      "ok": true,
      "detail": "mkfs.erofs (erofs-utils) 1.8.10; zstd ok as a systemd service"
    },
    "runtime_payloads": {
      "ok": true,
      "detail": "7 installed files match SHA256SUMS and sources.lock, with their modes"
    },
    "package_holds": {
      "ok": true,
      "detail": "held and blacklisted for unattended upgrades: containerd linux-aws linux-headers-aws linux-image-aws"
    }
  }
}
image_configuration: PASS (14 checks)

[2026-10-29T18:41:54Z] running: 40-smoke.sh
Success
crw-rw---- 1 root root  10, 260 Oct 29 18:29 /dev/nitro_enclaves
-rwxr-xr-x 1 root root  4763448 Oct 29 17:29 /usr/bin/firecracker
-rw-r--r-- 1 root root 13004876 Oct 29 17:29 /var/lib/nitro-sandbox-images/latest.eif
lrwxrwxrwx 1 root root       15 Oct 29 17:29 /var/lib/nitro-sandbox-images/rootfs.ext4 -> latest-disk.img
PUT /machine-config -> 204
PUT /boot-source -> 204
PUT /drives/rootfs -> 204
PUT /drives/overlay -> 204
PUT /vsock -> 204
PUT /network-interfaces/eth0 -> 204
PUT /enclave -> 204
PUT /actions -> 204
vsock handshake reply: 'OK 1073741824'
--- process alive: yes; agent reachable: 1 after 3s
smoke 2026-10-29T18:42:01Z: PASS; debug_mode=false

[2026-10-29T18:42:13Z] terminating verification instance <INSTANCE_ID>
[2026-10-29T18:42:46Z] fresh-instance verification PASS
[2026-10-29T18:42:49Z] tagged <AMI_ID> BtfValidated=true (fresh-instance verification passed; ManagedBy=ubuntu-ami-sample preserved)
[2026-10-29T18:42:49Z] --ami-only: done. AMI <AMI_ID> is verified and tagged BtfValidated=true; no node group was created.
```

*`./setup.sh --ami-only` step 9, from the step line to the `--ami-only: done` line, whole. The
AMI id, the verification instance's id and the repository's absolute path are shown as
`<AMI_ID>`, `<INSTANCE_ID>` and `<repository>`; the trailing space at the end of the eight
`PUT` lines was removed. The tag is written 3 s after the `PASS` line, never before it.*

**AppArmor.** AppArmor stays enabled on the host, and the node loads one scoped profile,
[`manifests/ubuntu-ami-sample-profile`](manifests/ubuntu-ami-sample-profile), installed onto
the AMI by [`scripts/35-apparmor.sh`](scripts/35-apparmor.sh). The profile refuses writes to
`/etc/shadow` and a few other paths inside the confined container with `audit deny` rules, so
each refusal is logged; the pod mounts no host filesystem, so these are the container's own
files, not the node's. It lets runc, crun and the host signal the container, as containerd's
own default container profile
does (containerd `contrib/apparmor/template.go`): without those `signal` rules, a pod under
the profile could never be stopped. `./test.sh` shows four things on the sample's node, each
next to its control.

**1. AppArmor is on and enforcing on the host.** The kernel reports AppArmor enabled, the
scoped profile is loaded in enforce mode, and the node's copy of the profile is this sample's
file (same sha256). The same probe reads absent for a profile the node never loaded.

```text
  node> apparmor_enabled=Y
  node> apparmor_profile=loaded
  node> apparmor_profile_bogus=absent
  node> apparmor_profile_mode=enforce
  node> apparmor_profile_sha256=b285f498d97bdc427d0303b96d6c68eb86a8caf83a8d9d2b0570e3ba6381548f
  -- 8a: AppArmor is on and enforcing on the host
  PASS  AppArmor is enabled host-wide on the node (enabled=Y)
  PASS  ACCEPT: the scoped profile ubuntu-ami-sample-profile is loaded on the node in enforce mode (mode=enforce)
  PASS  REJECT: the same probe reads absent for a profile the node never loaded
  PASS  the profile on the node is this sample's manifests/ubuntu-ami-sample-profile (sha256 b285f498d97bdc427d0303b96d6c68eb86a8caf83a8d9d2b0570e3ba6381548f)
```

*Abridged:* the five AppArmor readings `./test.sh` takes on the node in section 2/7, then the
8a lines of section 3/7. No value was replaced.

**2. The scoped profile working, on an ordinary pod.**
[`deploy/pod-apparmor-scoped.yaml`](deploy/pod-apparmor-scoped.yaml) is an ordinary (runc)
pod on the same node that selects the profile with `securityContext.appArmorProfile`
(`type: Localhost`). `./test.sh` checks that its process runs under
`ubuntu-ami-sample-profile (enforce)` (`/proc/self/attr/current`), while the ordinary pod's
label does not name the profile. It checks that the pod's write to `/etc/shadow` is refused
with `Permission denied` and the node's kernel logs the profile's `DENIED` line for it, read
from the node's clock just before the write, while the same pod's write to another file in
`/etc` succeeds. Then it deletes the pod by its exact name and checks that the pod is gone
within its 15 s grace period, with no `DENIED` signal logged under the profile. A profile
the node never loaded has no `DENIED` lines, as the control for both counts.

```text
  -- 8b: the scoped profile works on an ordinary pod on the same node (apparmor-scoped-pod)
  scoped pod: node=<NODE_NAME> type=Localhost profile=ubuntu-ami-sample-profile phase=Running
  PASS  the scoped pod requests Localhost ubuntu-ami-sample-profile and runs on the sandbox node (phase=Running)
  scoped attr/current: 'ubuntu-ami-sample-profile (enforce)'  ordinary attr/current: 'cri-containerd.apparmor.d (enforce)'
  PASS  ACCEPT: the scoped pod's process is confined by 'ubuntu-ami-sample-profile (enforce)' (attr/current)
  PASS  REJECT: the same label read on the ordinary pod, which requests no profile, does not name ubuntu-ami-sample-profile
  scoped pod: write to /etc/shadow: sh: line 1: /etc/shadow: Permission denied WRITE-FAILED
  scoped pod: write to /etc/ubuntu-ami-sample-write-control: WRITTEN
  PASS  ACCEPT: the scoped pod's write to /etc/shadow is refused with EACCES (Permission denied)
  PASS  REJECT: the same pod's write to a path the profile does not deny succeeds (so the refusal is the profile's)
  node DENIED lines since T0=1793300898 for that write: ubuntu-ami-sample-profile 3, profile-that-does-not-exist 0
  PASS  ACCEPT: the node's kernel logged the profile's DENIED line for that write since T0
  PASS  REJECT: the same count for a profile the node never loaded is 0
  scoped pod deleted by its exact name: gone=yes after 2 s (grace 15 s); signal DENIED lines since T0: ubuntu-ami-sample-profile 0, profile-that-does-not-exist 0
  PASS  ACCEPT: deleted by its exact name, the scoped pod is gone within its grace period (2 s <= 15 s)
  PASS  ACCEPT: the node logged no DENIED signal under ubuntu-ami-sample-profile since T0 (the profile lets runc stop the pod)
  PASS  REJECT: the same signal count for a profile the node never loaded is 0
```

*`./test.sh` section 3/7, the 8b lines, whole. The node's host name is shown as `<NODE_NAME>`.*

**Why the profile has `signal` rules and `audit deny`.** The first version of the profile had
neither, and a validation run of this sample on its own AMI showed what that costs. On Ubuntu
24.04, runc runs under its own AppArmor profile, `runc`, so the stop signals a pod receives
come from the peer `runc`. With no `signal` rule, AppArmor refused them: a pod under the
profile could not be stopped, and kubelet kept logging
`runc did not terminate successfully: exit status 1: unable to signal init: permission denied`
(the end of the message). And a plain `deny` rule refuses without logging, so the refused
`/etc/shadow` write left no `DENIED` line. The profile now has the `signal` rules of
containerd's default container profile, and every deny rule is `audit deny`. The block above
shows both on this run: the pod was gone 2 s into its 15 s grace period with 0 signal denials,
and the refused write left the profile's `DENIED` lines.

**3. A pod naming a profile the node never loaded is refused.** The reject control,
[`deploy/pod-apparmor-reject.yaml`](deploy/pod-apparmor-reject.yaml), is an ordinary pod on
the same node that asks for `profile-that-does-not-exist`. `./test.sh` checks that it is
scheduled on the sample's node, is not running, and waits with reason `CreateContainerError`
and containerd's message for a missing profile, matched whole:
`failed to get container spec opts: failed to generate apparmor spec opts: apparmor profile not found profile-that-does-not-exist`.

```text
  -- 8c: a pod naming a profile the node never loaded is refused
  reject control: node=<NODE_NAME> phase=Pending reason=CreateContainerError message: failed to get container spec opts: failed to generate apparmor spec opts: apparmor profile not found profile-that-does-not-exist
  PASS  REJECT: a pod naming an unloaded AppArmor profile is refused on the sandbox node: CreateContainerError 'failed to get container spec opts: failed to generate apparmor spec opts: apparmor profile not found profile-that-does-not-exist'
```

*`./test.sh` section 3/7, the 8c lines, whole. The node's host name is shown as `<NODE_NAME>`.*

**4. Why the sandbox pod runs `Unconfined`.** The isolated-sandbox pod,
[`deploy/pod-isolated-sandbox.yaml`](deploy/pod-isolated-sandbox.yaml), sets
`appArmorProfile` `type: Unconfined`. A sandbox pod's profile is not applied on the host: the
shim passes it into the guest microVM, where runc applies it. The runtime's Ubuntu build notes
(`UBUNTU.md` in the GA node-build bundle) say that on an AppArmor host "every sandbox pod
needs `Unconfined`, or kubelet requests the `RuntimeDefault` profile, the shim forwards it
into the guest, and runc fails with `apparmor failed to apply profile`". A validation run of
this sample on its own AMI showed exactly that. With `type: Localhost` and the scoped
profile, the sandbox pod stopped in `StartError` with
`apparmor failed to apply profile: write fsmount:fscontext:proc/thread-self/attr/exec: invalid argument`
(the end of the message), because the guest runs SELinux and has no AppArmor: its process
label is `system_u:system_r:runtime_t:s0:c0.c1023`. The microVM is the sandbox pod's boundary.
`./test.sh` prints the sandbox's own label and checks that the pod runs with `Unconfined`.

```text
  -- why the sandbox pod runs Unconfined
  sandbox pod: appArmorProfile type=Unconfined phase=Running attr/current (the guest's own label): 'system_u:system_r:runtime_t:s0:c0.c1023'
  PASS  the sandbox pod runs with appArmorProfile Unconfined, as the GA build notes require (phase=Running)
```

*`./test.sh` section 3/7, its last three lines, whole. No value was replaced.*

### The validation sandbox has no network

The isolated-sandbox pod is booted with no network. It needs none: it runs `sleep infinity`,
and every check `./test.sh` makes reaches it through `kubectl exec`. One annotation in
[`deploy/pod-isolated-sandbox.yaml`](deploy/pod-isolated-sandbox.yaml) does it, the same one
[Getting started](../../getting-started/hello-sandbox/README.md) uses. Here is the part of the
manifest that matters:

```yaml
metadata:
  annotations:
    sandbox.amazonaws.com/network-isolated: "true"   # <-- boot the VM with no network besides loopback
```

`./test.sh` section 7/7 reads the annotation back from the API, then reads what the guest
itself reports: only loopback has an address, the sandbox has no route, and every interface
other than `lo` is down. The guest also has a `dummy0` interface, from its image, which is
down and has no address. A TCP connect from the sandbox to the cluster's `kubernetes` Service on port
443 fails with `Network is unreachable`, while the same connect from the ordinary pod on the
same node succeeds, so the failure is the sandbox's and not the Service's. The API still
reports a `podIP` for the sandbox pod: the host side allocates it, and no interface in the
guest carries it.

```text
TODO: output from the fresh run
```

*`./test.sh` section 7/7, whole, once the fresh run fills it. The cluster's `kubernetes`
Service ClusterIP, which test.sh prints once on its own line, is to be shown as
`<API_SERVICE_IP>`, and no other value replaced. test.sh prints each interface's name and
state, not its MAC address.*

The sample ships no network policy, and creates no Ingress, LoadBalancer or NodePort. For
how a network policy restricts where a sandboxed pod can connect, see the
[network policy](../../isolation/network-policy/README.md) sample.

### Clusterless checks

These run with no AWS account and no cluster, against the real scripts with stub commands
first on `PATH` where a live input cannot be made. The fake AWS CLI applies `--query` with the
`jmespath` package, pinned in
[`scripts/testlib/requirements-test.txt`](scripts/testlib/requirements-test.txt); without it,
every fake call stops with exit 98 and an "install jmespath" message, so the suites fail rather
than pass. Install it into a virtual environment under the repository's `tmp/`, and put that
environment first on `PATH` while the suites run (from this sample's folder):

```bash
python3 -m venv ../../../tmp/ubuntu-ami-tests
../../../tmp/ubuntu-ami-tests/bin/pip install -r scripts/testlib/requirements-test.txt
export PATH="$(cd ../../../tmp/ubuntu-ami-tests/bin && pwd):$PATH"
```

```bash
bash packages/test-bundle.sh          # bundle built and consumed against sources.lock; tampered, unlisted and unsafe members refused
bash packages/test-inputs.sh          # runtime archive and host-kernel patch (cached or downloaded), both ways
bash scripts/test-host-gates.sh       # containerd gate, .config assertion, root filesystem at boot, IMDS token never on argv
bash scripts/test-cluster-gates.sh    # kube context, vpc-cni ACTIVE (network policy on or off), RuntimeClass, user data, node capacity, namespace, pod wait
bash scripts/test-launch-specs.sh     # IMDSv2 hop limit 1, enclaves and run tags on the node template, verification instance and build host; strict bootstrap.sh user data
bash scripts/test-run-scope.sh        # per-run IAM, run-scoped clean up, the run's lock and record, IAM by name, the node role's access entry, --keep-ami, every failed lookup, --list-runs, staging revocation
bash scripts/test-image-checks.sh     # containerd wiring, AppArmor stage, package holds, bake residue, verify-image.py (Python 3.11+)
bash scripts/test-apparmor-checks.sh  # test.sh's AppArmor checks (its node probe run on a fake journal), the Unconfined sandbox, the no-network checks and their control, the run's lock and record; the profile's structure, signal and audit-deny rules
bash scripts/test-btf-tag.sh          # BtfValidated=true only after both fresh-instance checks pass, only on this run's AMI
bash scripts/test-setup-flow.sh       # bounded SSM, AMI, status and reboot waits; --ami-only and --join, the run's record (cluster and Region) and lock, both ways
bash scripts/test-local-paths.sh      # local state only under the repository's tmp/; the cluster, Region and namespace defaults
```

## Cost note

A planning estimate, not a measured run: one clean run in `us-west-2` at on-demand prices
is about $6 (the `m8i.4xlarge` build host for about five hours is most of it; the verification
instance, the node, EBS, the AMI snapshot, S3 staging and NAT data are the rest). Resources
that keep billing if a build fails partway: the build EC2 instance and its 120 GiB root
volume, any EBS snapshots already taken, the verification instance (if the build reached
that stage), the empty staging bucket, and, once a node group exists, its EC2 instances.
`Clean up` below removes all of these; run it promptly after a failed or abandoned run so
nothing keeps billing unattended.

## Clean up

Run clean up right after you finish validating, before moving on:

```bash
./clean.sh --dry-run                           # list this run's resources; nothing is removed
./clean.sh                                     # remove this run's Kubernetes workload
./clean.sh --delete-aws-resources              # also remove this run's AWS resources and AMI
./clean.sh --delete-aws-resources --keep-ami   # the same, but keep the AMI and its snapshot
```

`./clean.sh` acts on one run: the one `./setup.sh` recorded in
`tmp/issue10/run/out/run-state.env`, or the one you name with `--run-id <id>`. With neither it
deletes nothing. It lists and deletes only resources that carry both `ManagedBy=<RESOURCE_PREFIX>`
and that run's `RunId`, and re-reads both tags of each resource right before deleting it, so
another run of this sample in the same account is never touched. The IAM roles and the
instance profile are found by their per-run names through IAM itself (the Resource Groups
Tagging API does not list IAM roles). `--dry-run` changes nothing.

A bare `./clean.sh` removes only the Kubernetes validation workload (after confirming the
sample's namespace carries both of the run's labels: the scoped AppArmor pod by its exact
name, then the namespace), leaving the node group and AMI in place
for a longer investigation. `./clean.sh --delete-aws-resources` does the full teardown: it
removes, in order, the Kubernetes workload, the managed node group, the build and
verification EC2 instances, then any of the run's EBS volumes left unattached (an attached one
is left in place and reported), the AMIs and their snapshots, the launch template, the build
security group, the S3 staging bucket (emptied first, every call naming your account as the
expected bucket owner), the access entry EKS created for the node role, and the instance
profile and IAM roles (both tags read again right before the first change to each role). EKS
does not delete that access entry with the node group or the role (Amazon EKS User Guide,
*Create access entries*), and it has no tags, so `./clean.sh` finds it by the node role's
ARN and deletes it only after the node group is gone and while the role still carries both
tags; an entry whose role is already gone is left, with the command that removes it. It then
reads each category
again to confirm nothing of the run remains, and exits non-zero if anything is still there,
if anything was skipped as not the run's, or if any lookup failed: a failed lookup is
"could not determine", never "gone". Before the first delete it checks `KUBE_CONTEXT` against
the cluster, as setup does.

**`--keep-ami`** keeps the run's AMI and the snapshot behind it, and lists them as
"left in place (kept on request)" in `--dry-run` and at the end. The `cilium-ubuntu` sample
(issue #11) builds on that AMI; remove it later with `./clean.sh --run-id <id>
--delete-aws-resources`.

**A lost run id.** `./clean.sh --list-runs` lists every resource marked
`ManagedBy=<RESOURCE_PREFIX>` in the Region (instances, volumes, AMIs, snapshots, security
groups, launch templates, buckets, IAM roles, instance profiles, and the cluster's node groups;
each shown only when its own tags were read and carry that mark), grouped by `RunId`, and
deletes nothing. A tag it could not read makes the list incomplete and the command exits 1. Then
clean each run you find with `./clean.sh --run-id <id> --delete-aws-resources`.

**What stays.** The clean up never removes a shared install. The `isolated-sandbox`
RuntimeClass stays (Getting started created it). The `vpc-cni` add-on you installed as a
prerequisite stays, and `./clean.sh` says so. If you installed it only for this sample, you
can remove it from EKS management yourself:

```bash
aws eks delete-addon --region <AWS_REGION> --cluster-name <CLUSTER_NAME> --addon-name vpc-cni --preserve
```

`--preserve` leaves the add-on's software on the cluster as a self-managed install. Do not
leave it out: without it, EKS deletes the add-on's software, which can include the
`amazon-vpc-cni` ConfigMap the add-on adopted and gave its Helm labels. Where that ConfigMap
was there before the add-on, as on an EKS Auto Mode cluster with network policy turned on, it
holds `enable-network-policy-controller`, the setting that turns network policy enforcement on,
so deleting it can turn enforcement off for every workload.
Removing the software also takes pod networking away from every node that gets it from
`aws-node`, managed node group nodes included; nodes kept off `aws-node` for another CNI are
not affected.

## Troubleshooting

<details>
<summary>Preflight stops with the runtime-archive prerequisite</summary>

Expected until you place `nitro-sandbox-binaries-2026-10-28.zip`, an operator-supplied
preview archive, checksum-pinned, with no public download, which you obtain from your AWS
account team; see
[The runtime archive](#the-runtime-archive). Put it in
`RUNTIME_ARTIFACTS_DIR` (default `tmp/issue10/run/runtime` at the repository root) and re-run
`./setup.sh --prepare`. A SHA-256 or `SHA256SUMS` failure means the file is not the pinned
archive: do not use it.

</details>

<details>
<summary>The build host stops on containerd</summary>

The base image's containerd is outside 2.1.x to 2.3.x, the range the GA shim runs on.
Canonical republishes the base AMI under new serials, and a new serial can ship a newer
containerd. The run evidence records the serial and the version it found; build from a
serial whose containerd is in range. The sample never changes containerd.

</details>

<details>
<summary>Kernel config assertion fails after <code>olddefconfig</code></summary>

A required symbol was present in the merged config but got dropped once `olddefconfig`
resolved dependencies, usually because the symbol's gating menu was off. Check the symbol it
reports against its Kconfig entry's `depends on` line. A missing BTF usually means `pahole`
(`dwarves`) is missing or too old; `CONFIG_NITRO_ENCLAVES=m` must be `=y`.

</details>

<details>
<summary>Build host unreachable over SSM, or the staged download fails</summary>

Confirm the instance has the SSM agent and the sample's instance profile, and that the
subnet has egress to the SSM endpoints and to Amazon S3. There is no SSH fallback: the build
security group opens no inbound rule by design. A download refused with `AccessDenied` means
the build role's per-run staging read was not in place; it is added right before the
download and removed right after.

</details>

<details>
<summary>The node never becomes <code>Ready</code>, or sandbox pods stay <code>Pending</code></summary>

A node that is never `Ready` usually has no pod network: check the `vpc-cni` add-on
([Prerequisites](#prerequisites)). Pods `Pending` on a node selector mean the node lacks a
label: check `kubectl --context <your-context> get node --show-labels` for `eks.amazonaws.com/nodegroup`,
`eks.amazonaws.com/nitro-sandbox=true` and `sandbox.preview/nitro=true`. Pods `Pending` with
`Insufficient eks.amazonaws.com/nitro-sandbox` mean the node advertises no sandbox capacity:
check `cri-proxy.service` and `/dev/nitro_enclaves` on the node. A pod stuck
`ContainerCreating` usually means the CRI proxy socket does not match the kubelet endpoint.

</details>

<details>
<summary>erofs-utils build fails, or images build without zstd</summary>

Confirm `libzstd-dev` is installed before `./configure`, and that the snapshot's SHA-256
still matches the pinned value: cgit can regenerate a snapshot archive's bytes without
changing the tag it names, and this sample's own pin tracks the bytes, not just the tag.

</details>

<details>
<summary>Origin and source layout</summary>

Ported from the maintainers' internal demo for this node and reconciled with the Nitro
sandbox GA node-build bundle dated 2026-10-28, following this repository's rule to leave
behind internal source trees, hosts and URLs. The host kernel is built from public, pinned
inputs (kernel.org and AWS's public kernel commit), and the runtime is consumed as an
operator-supplied preview archive, checksum-pinned, with no public download. See
[Public inputs, pinned and checksum-verified](#public-inputs-pinned-and-checksum-verified)
and [`packages/SOURCES.txt`](packages/SOURCES.txt) for the full provenance record.

The implementation entry points are `setup.sh`, `test.sh` and `clean.sh`. The build
stages live under `scripts/`; `deploy/` holds the validation pods, the node-group taint and
the IAM and bucket policies; `manifests/` holds the containerd handler reference and the
AppArmor profile; `packages/sources.lock` records every pin and checksum this page
summarizes, and `packages/SOURCES.txt` records how each input was obtained and verified.

</details>
