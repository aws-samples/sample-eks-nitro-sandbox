---
name: nitro-sandbox-pods
description: How a Nitro sandbox pod on Amazon EKS works, for runtimeClassName isolated-sandbox and confidential-sandbox - the trust model, the one-line opt-in, what runs in the guest and what stays on the node, network policy, Pod Identity and the metadata service, sizing, and the agent-sandbox resources. Use when writing, reviewing or explaining a sample or pod spec that uses a sandbox runtime class, or when deciding what a sample must show to prove it ran in a sandbox.
---

# How a Nitro sandbox pod works

Every fact here comes from this site's pages or from public AWS or upstream documentation,
and each one names its source. Paths are relative to the repository root. When a sample
needs something these sources do not state, look it up in the Amazon EKS User Guide
(<https://docs.aws.amazon.com/eks/latest/userguide/>) and cite that page; do not fill the
gap from memory or from unpublished material. Until Nitro sandboxes are generally
available, the guide's pages for them are not public yet: "The Amazon EKS User Guide before
general availability" in `AGENTS.md` says where they are and how to cite them.

The pages call the running unit you pool, claim, exec into and delete a **pod**. They say
**sandbox** for the agent-sandbox resources (`Sandbox`, `SandboxClaim`, `SandboxWarmPool`)
and for the isolation boundary around the pod, and never **VM** or **microVM** for the
claimed thing; **VM** appears only where they explain how the boundary works.

## What changes and what does not

From the outside a sandboxed pod is an ordinary pod: the scheduler places it, it gets an IP
from your VPC, it mounts volumes through the same CSI drivers, and it answers to
`kubectl exec`, `logs` and `port-forward`. What changes is what sits between the kubelet and
the containers: EKS asks EC2 for a Nitro Partition, a hardware-isolated slice of the
instance's CPU and memory, boots a lightweight VM inside it and starts the containers in
that VM. The pod's containers share a kernel with each other, and that kernel belongs to the
pod alone. (`examples/README.md`, "How it works", and Figure 1.)

| Runs in the guest VM | Stays outside the guest |
|---|---|
| The pod's containers and their own kernel (`examples/README.md`) | The kubelet and containerd on the node, which still see an ordinary pod (`examples/README.md`, Figure 1) |
| The endpoints that serve instance metadata and Pod Identity credentials, when the pod has a network (`examples/getting-started/hello-sandbox/README.md`) | Network policy enforcement: eBPF programs on the pod's host-side interface on the node (`examples/managed-agents/claude-managed-agents/README.md`, "Where it is enforced") |
| The pod's network interface: an `eth0` with a VPC address and a default route, unless the pod is network-isolated (`examples/getting-started/hello-sandbox/README.md`) | Scheduling, and the CSI drivers that mount the pod's volumes, which work as they do for any pod (`examples/README.md`) |
| The internal control channel that `exec`, `cp` and `logs` use, which works even with no network (`examples/README.md`) | |

## Two runtime classes

| | `isolated-sandbox` | `confidential-sandbox` |
|---|---|---|
| Protects | The node and the other pods from the pod | The same, and treats the node as untrusted too |
| Policy | A Cedar policy is generated for you | Needs a Cedar policy that pins down what the pod may run; it becomes part of what the sandbox attests to |
| Extra setup | None | KMS attestation conditions |

Source: `examples/README.md`. The samples available today all use `isolated-sandbox`. The
roadmap plans `confidential-sandbox` samples too: cedar-policy under Policy, and
the Confidential section (`docs/ROADMAP.md`). For confidential-mode
policy generation and attestation conditions, follow the Amazon EKS User Guide rather than
this skill.

On EKS Auto Mode both runtime classes are present on every cluster, and Auto Mode
provisions sandbox-capable nodes on demand. On standard EKS the same pod specs work once the
nodes run a sandbox-enabled AMI. (`examples/getting-started/hello-sandbox/README.md`.)
`kubectl get runtimeclass` lists both.

## The one-line opt-in

```yaml
spec:
  runtimeClassName: isolated-sandbox   # <-- the only change
```

No node selector, toleration or sidecar: the RuntimeClass carries the scheduling
constraints. (`examples/getting-started/hello-sandbox/hello-sandbox.yaml` and its page.)

**No network besides loopback** is one annotation:

```yaml
metadata:
  annotations:
    sandbox.amazonaws.com/network-isolated: "true"
```

The VM then boots with only loopback: no route out, no DNS, no instance metadata and no Pod
Identity credentials. `kubectl exec`, `cp` and `logs` keep working, because they use the
VM's internal control channel. (`examples/README.md`;
`examples/getting-started/hello-sandbox/README.md`.)

## How a sample proves it ran in a sandbox

Show these three together, with output from the run, and say what an ordinary pod shows
for each, as the hello sandbox and Claude Managed Agents pages do between them. Together
they show the pod's containers ran in a VM of their own:

- **Its own kernel.** `uname -rv` in the sandbox shows the guest's kernel build; an ordinary
  pod on the same node shows the node's. The version string can match; the build and the
  boot do not. (`examples/managed-agents/claude-managed-agents/README.md`, step 7.)
- **Its own boot.** `cat /proc/uptime` matches the pod's age, because the VM booted with the
  pod; an ordinary pod reports the node's uptime.
  (`examples/getting-started/hello-sandbox/README.md`.)
- **Virtio disks.** `ls /sys/block` shows `vda`, `vdb` and so on, where an ordinary pod sees
  the instance's `nvme` devices. (`examples/getting-started/hello-sandbox/README.md`.)

The hello sandbox page shows a fourth, the **product name**:
`cat /sys/class/dmi/id/product_name` reads the VM in the sandbox (`m8i.enclave` on its run),
where an ordinary pod reads the EC2 instance type (`m8a.xlarge`). `uname -r` alone is not
evidence: the guest's kernel version can match the node's.
(`examples/getting-started/hello-sandbox/README.md`, step 5.)

These support a claim but do not prove the pod ran in a sandbox on their own:

- **The runtime class**, `kubectl get pod <pod> -o jsonpath='{.spec.runtimeClassName}'`,
  shows what was asked for, not what ran.
  (`examples/managed-agents/claude-managed-agents/README.md`, step 7.)
- **No network, when isolated.** Only `127.0.0.1` has an address, there is no route, and a
  request fails to resolve the host (`curl: (6) Could not resolve host`).
  (`examples/getting-started/hello-sandbox/README.md`.)
- **Credentials by name, not value.** `env | cut -d= -f1 | grep ^PREFIX_` shows which
  variables exist without printing a secret.
  (`examples/managed-agents/claude-managed-agents/README.md`, step 7.)

## Network policy

- **Turn enforcement on, once per cluster.** EKS Auto Mode accepts network policies without
  enforcing them until the `amazon-vpc-cni` ConfigMap in `kube-system` sets
  `enable-network-policy-controller: "true"`. It affects the whole cluster; pods no policy
  selects are unaffected. (`examples/getting-started/coding-agent/enable-network-policy.yaml`
  and its page; <https://docs.aws.amazon.com/eks/latest/userguide/auto-net-pol.html>.)
- **Hostnames in egress rules.** The Auto Mode `ApplicationNetworkPolicy`
  (`networking.k8s.aws/v1alpha1`) accepts the standard `NetworkPolicy` fields plus
  `domainNames`. It allows the addresses those names resolve to, so another name served from
  the same addresses is reachable too; say so on the page.
  (`examples/getting-started/coding-agent/README.md`, step 5.)
- **Allow DNS explicitly.** The samples allow egress to the CoreDNS ClusterIP on UDP and TCP
  53, filled in at apply time from `kubectl get svc -n kube-system kube-dns`.
  (`examples/getting-started/coding-agent/egress-policy.yaml` and
  `examples/managed-agents/claude-managed-agents/deploy/egress-policy.yaml`, each page's step 5.)
- **Wait for the `PolicyEndpoint`.** It shows the controller has handed the policy to the
  nodes; start the workload after it appears. (Coding agent, step 5; Claude Managed Agents,
  step 5.)
- **It is enforced on the node, outside the guest.** The node's network policy agent
  attaches eBPF programs to the pod's host-side interface, so a command inside the sandbox,
  even as root, cannot change the policy. Kubernetes always allows traffic between a pod and
  its own node. (`examples/managed-agents/claude-managed-agents/README.md`, "How the network
  policy works".)
- **Refusals can look different.** A blocked host can time out on IPv4 or fail at once with
  "Network is unreachable" when it also publishes IPv6 addresses; both are the same block.
  (Same section.)
- **`networkPolicyManagement: Unmanaged` on a `SandboxTemplate`.** With the default,
  `Managed`, the agent-sandbox controller creates its own `NetworkPolicy` for the template's
  pods, which with no rules of your own allows the public internet. Network policies are
  additive, so that policy would undo yours. Set `Unmanaged` when the sample ships its own
  policy. (`examples/managed-agents/claude-managed-agents/README.md`; upstream
  [API reference](https://github.com/kubernetes-sigs/agent-sandbox/blob/v1.0.6/docs/api.md#networkpolicymanagement).)

## Pod Identity and the metadata service

- **Credentials come from EKS Pod Identity.** Give the pod's ServiceAccount a Pod Identity
  association with a role scoped to what the sample needs.
  (`examples/getting-started/coding-agent/README.md`, step 3;
  <https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html>.)
- **The pod gets both endpoints.** With a network, the pod gets the in-guest endpoints that
  serve instance metadata and Pod Identity credentials
  (`examples/getting-started/hello-sandbox/README.md`).
- **Pod Identity requests go through the network policy.** The sandbox passes credential
  requests to `169.254.170.23` on to the Pod Identity Agent on the node (Amazon EKS User
  Guide, *Security model and parent instance trust assumptions*), and an egress policy
  applies to them: without a rule allowing `169.254.170.23` on TCP 80 they time out, from a
  sandboxed pod as from an ordinary one. Every egress policy for a pod with a Pod Identity
  association needs that rule. (`examples/getting-started/coding-agent/egress-policy.yaml`.)
- **The metadata service holds no role.** At `169.254.169.254` it answers with placement and
  service details only, and its `iam/` paths return 404, so a pod with no Pod Identity
  association has no role to assume. (`examples/managed-agents/claude-managed-agents/README.md`,
  "No reusable credential".)
- **A network-isolated pod has neither endpoint.** (`examples/README.md`.)

## Sizing and start-up

- For a pod that runs a workload, set requests equal to limits, as the samples that run one
  do (`fix-issue.yaml`, `warm-pool.yaml`, `sandbox-template.yaml`). The
  VM is sized to the pod's limits, so the hypervisor bounds the CPU and memory the pod can
  use: with 2 CPU and 4 GiB, `nproc` reports 2 and memory is about 4 GiB inside.
  (`examples/getting-started/coding-agent/README.md`.)
- The hello sandbox pods set no requests or limits, and their VM got a small default size:
  one vCPU and about 130 MiB of memory on its run. That is enough for a pod that prints and
  sleeps, not for a workload. (`examples/getting-started/hello-sandbox/README.md`, step 5.)
- Each sandbox reserves its full memory request up front, so bin-packing is by reservation,
  not usage: size requests honestly and expect fewer, larger pods per node than with
  ordinary containers. (`examples/getting-started/warm-pool/README.md`, "Sizing".)
- After the first node is up, a new sandboxed pod is Ready in about 5 to 6 seconds, most of
  it EC2 creating the partition. A warm-pool claim adopts a pod that is already running and
  is Ready in under 1 second. (`examples/getting-started/hello-sandbox/README.md`;
  `examples/getting-started/warm-pool/README.md`.)
- Size a warm pool's `replicas` to the peak claim rate, not the total number of sessions.
  (`examples/getting-started/warm-pool/README.md`.)

## agent-sandbox resources

[agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) is a Kubernetes SIG
project. A Nitro sandbox is a RuntimeClass on a pod template, so it works with agent-sandbox
unchanged; put `runtimeClassName` in the template's `podTemplate.spec`.
(`examples/getting-started/warm-pool/README.md`.) The warm pool and Claude Managed Agents
samples both pin v1.0.6 and install it with `sandbox-with-extensions.yaml` (each page's
step 1).

| Resource | API group | What it is | Source |
|---|---|---|---|
| `Sandbox` | `agents.x-k8s.io/v1beta1` | One stateful pod with a stable identity. `volumeClaimTemplates` gives it persistent storage (immutable after creation); `operatingMode: Suspended` terminates the pod but keeps the Sandbox and its volumes, and `Running` brings a pod back. | Upstream [README](https://github.com/kubernetes-sigs/agent-sandbox/blob/v1.0.6/README.md) and [API reference](https://github.com/kubernetes-sigs/agent-sandbox/blob/v1.0.6/docs/api.md) |
| `SandboxTemplate` | `extensions.agents.x-k8s.io/v1beta1` | A reusable pod template. Set `runtimeClassName` here, and `networkPolicyManagement: Unmanaged` when you ship your own policy. A pod made from a template has `automountServiceAccountToken` defaulted to `false` unless the template sets it. | Warm pool and Claude Managed Agents pages; upstream API reference |
| `SandboxWarmPool` | `extensions.agents.x-k8s.io/v1beta1` | Keeps `replicas` sandboxes booted from a template, and refills after a claim. | Warm pool page |
| `SandboxClaim` | `extensions.agents.x-k8s.io/v1beta1` | Created per session or task with a `warmPoolRef`; adopts a warm pod. `status.sandbox.name` names it. Setting `env` or `volumeClaimTemplates` on a claim forces a cold start. | Warm pool page; upstream API reference |

For an agent workspace with a persistent home, use a `Sandbox` with `volumeClaimTemplates`
and suspend it with `operatingMode`, not a bare pod with a hand-made PVC: that is the shape
the roadmap gives the workspace samples (`docs/ROADMAP.md`, coding-agents-for-developers and
pause-resume), and the upstream `Sandbox` API provides both fields.

## Claims to avoid

- Do not say "strongest" isolation. Say hardware-level isolation.
- Do not claim a limit, size, density, throttle, region or instance type that the pages and
  the public AWS documentation do not state.
- Do not state a minimum CPU or memory request unless you cite the Amazon EKS documentation
  for it, and never on slides or in videos; show the sample's actual requests instead.
- Do not describe confidential-mode policy generation or attestation from memory; point to
  the Amazon EKS User Guide.
