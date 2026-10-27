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

The boundary's public name is **Nitro sandbox**, which is what the Amazon EKS User Guide
uses throughout (*Isolated and confidential pods overview*, "Concepts": "A dedicated
hardware-isolated environment with its own Linux kernel, created by the AWS Nitro
hypervisor"). **"Nitro Partition" is an internal name that the guide never uses: never write
it on a page, in a figure, in a manifest comment or in a skill.** Where a sentence is about
the hardware mechanism rather than the product, name what the guide names: the AWS Nitro
System, and the Nitro hypervisor, which enforces the CPU and memory isolation **between
sandboxes**. The sandbox *is* the lightweight VM with its own kernel, and it runs as a
first-level guest, "not through emulation or nested virtualization" (*overview*): so never
write that a VM runs *inside* a Nitro sandbox, which claims a layer that does not exist.

Prefer "Nitro sandbox" with a lower-case "s", which is the form this site uses in running
prose and in every figure label; the capitalised "Nitro Sandbox" is reserved for a title, a
quoted document title, or a sentence naming the product itself, as the home page's heading
and the blog post's title do.

## What changes and what does not

From the outside a sandboxed pod is an ordinary pod: the scheduler places it, it gets an IP
from your VPC, it mounts volumes through the same CSI drivers, and it answers to
`kubectl exec`, `logs` and `port-forward`. What changes is what sits between the kubelet and
the containers: containerd on the node launches a Nitro sandbox for the pod, a dedicated
hardware-isolated environment with its own kernel, created by the Nitro hypervisor, which
enforces the CPU and memory isolation between sandboxes. The sandbox is a lightweight VM,
and a first-level guest rather than anything emulated or nested, so the pod's containers run
in it and share its kernel with each other, and that kernel belongs to the pod alone.
(`examples/README.md`, "How it works", and Figure 1.)

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

How the mechanism works on this platform. All of it is still true; what changed is who
uses it. **A new sample ships no network policy**: `examples/isolation/network-policy` is
the one sample about it, and a new page links there instead of having its own policy and
its own "How the network policy works" section (the maintainers set this on 2026-10-26, and
`AGENTS.md`, Security rules has it). The samples merged before that date ship the policies
they were proved with and are cited below as the evidence for these facts; they are not
edited to match the change. Read this section to get the facts right when you explain, work
on or review the dedicated sample, or when you need to know what *is not* limited in a
sample that has no policy.

- **With no policy, a sandbox that has a network reaches what any pod reaches.** Nothing
  about a sandbox runtime class restricts the network; the boundary a sandbox adds is the
  VM. So a page for a sample with no policy must not claim the workload's reach is limited
  (`AGENTS.md`, "Say only what your sample actually limits").
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
  attaches eBPF programs to the pod's host-side interface, which the guest has no access to,
  so nothing inside the sandbox can change the policy, whatever UID it runs as. Kubernetes
  always allows traffic between a pod and its own node.
  (`examples/managed-agents/claude-managed-agents/README.md`, "How the network
  policy works".)
- **Do not write "even as root" unless the pod can actually be root.** The point above holds
  at any UID, so it needs no root hypothetical — and most samples here set
  `runAsNonRoot: true`, which makes root a state the sample cannot be in. A reader who tries
  to check such a claim gets the pod's own UID instead, so say what that UID is and keep the
  claim to what the sample shows. **Exactly one sample records UID 0 directly:**
  `examples/ai-agents/coding-agents-for-developers` sets `runAsUser: 0` with
  `allowPrivilegeEscalation: true`, and its page prints `id -u` as `0`. Two more are
  root-capable but record something narrower, and the gap is the thing to notice:
  `examples/ci-cd/docker-builds` records full privilege over the guest kernel — step 5 writes
  `/proc/sys/vm/swappiness` from a `privileged: true` container — but never records the
  process UID; and `examples/ci-cd/github-actions` records `uid=0(root)` only inside a build
  container on the pod's own `docker:dind` daemon, not in any container of its PodSpec.
  (`AGENTS.md`, "Say only what your sample actually limits".)
- **`privileged: true` is not by itself evidence of UID 0**, and neither is the absence of a
  `securityContext`: both leave the identity to the image's own `USER`. Nor is a root-only
  *looking* operation, because a capability such as `CAP_SYS_ADMIN` lets a non-root process do
  it — which is why `docker-builds`' sysctl write above is privilege evidence and not UID
  evidence. So cite the UID the sample records, and **name the exact execution context that
  evidence covers.** `examples/ci-cd/github-actions` is the worked example: its `uid=0(root)`
  comes from a `docker build` `RUN` step on the job's nested daemon, so it says nothing about
  the UID of the *runner container*, whose image's own `USER` is not root. That sentence once
  said "a command in the runner"; it now names the build container on the pod's own daemon,
  which is what the output actually pins. **Widening a noun is not a fix if the wider noun is
  still not what the evidence pins** — "the runner pod" was an improvement and still too loose,
  because a build container on the in-pod daemon is not a container of the PodSpec. Name the
  context, do not just enlarge it (issue #103).
- **"Cannot change the policy" is not "cannot get data out".** A filter can stay unmodified
  and still be routed around — through an allowed `domainNames` host that serves something
  else, over open port 53, or to the pod's own node. Write "cannot change" or "cannot
  reconfigure" for the enforcement point, and claim "cannot bypass" only where the sample
  establishes that separately. Every page here states the policy's own limits in the same
  section as this claim; keep that pairing.
- **Refusals can look different.** A blocked host can time out on IPv4 or fail at once with
  "Network is unreachable" when it also publishes IPv6 addresses; both are the same block.
  (Same section.)
- **`networkPolicyManagement: Unmanaged` on a `SandboxTemplate`.** With the default,
  `Managed`, the agent-sandbox controller creates its own `NetworkPolicy` for the template's
  pods, which with no rules of your own allows the public internet. Network policies are
  additive, so that policy would undo yours. Set `Unmanaged` only when the sample ships its
  own policy, which a new sample does not: leave the default.
  **Then do not read that controller-created policy as a limit.** A template at the default
  has a `NetworkPolicy` object attached to its pods that restricts nothing, which is easy to
  mistake for one on a page or in a diagram.
  (`examples/managed-agents/claude-managed-agents/README.md`; upstream
  [API reference](https://github.com/kubernetes-sigs/agent-sandbox/blob/v1.0.6/docs/api.md#networkpolicymanagement).)

## Pod Identity and the metadata service

- **Credentials come from EKS Pod Identity.** Give the pod's ServiceAccount a Pod Identity
  association with a role scoped to what the sample needs.
  (`examples/getting-started/coding-agent/README.md`, step 3;
  <https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html>.)
- **The pod gets both endpoints.** With a network, the pod gets the in-guest endpoints that
  serve instance metadata and Pod Identity credentials
  (`examples/getting-started/hello-sandbox/README.md`).
- **Where there is a role, it is a limit the sample enforces.** For a sample with no network
  policy that gives the pod AWS permissions, the Pod Identity role is the boundary it creates
  in the reader's account, so scope it to what the sample needs and show its policy document
  on the page. That is a limit the page can claim, because the sample is what makes it true.
  It is not the *only* boundary a sample can have, and a sample that calls no AWS API has no
  role at all: the VM boundary of the runtime class, a sandbox booted network-isolated, and
  Kubernetes RBAC are limits too. Claim the ones the sample actually creates.
- **Pod Identity requests go through a network policy, where there is one.** The sandbox
  passes credential requests to `169.254.170.23` on to the Pod Identity Agent on the node
  (Amazon EKS User Guide, *Security model and parent instance trust assumptions*), and an
  egress policy applies to them: without a rule allowing `169.254.170.23` on TCP 80 they
  time out, from a sandboxed pod as from an ordinary one. So any egress policy for a pod
  with a Pod Identity association needs that rule.
  (`examples/getting-started/coding-agent/egress-policy.yaml`.)
- **The metadata service holds no role.** At `169.254.169.254` it answers with placement and
  service details only, and its `iam/` paths return 404, so a pod with no Pod Identity
  association has no role to assume. (`examples/managed-agents/claude-managed-agents/README.md`,
  "No reusable credential".)
- **A network-isolated pod has neither endpoint.** (`examples/README.md`.)

## Sizing and start-up

- **A sample sets no CPU or memory requests or limits.** A customer sizes a pod for their own
  workload in production; a sample that sets a size reads as if a sandbox needs it. With
  none, the VM gets a small default size: the hello sandbox pods got one vCPU and about
  130 MiB of memory, enough for a pod that prints and sleeps.
  (`examples/getting-started/hello-sandbox/README.md`, step 5.)
- **Set them only when the sample cannot run without them**, such as an agent that needs more
  memory than the default VM has, or when sizing is what the sample shows. Then the page says
  why it sets them. A pod with no requests is `BestEffort`, which the kubelet evicts first
  when a node runs short of resources: fine for a sample, and one reason production sets
  requests.
- **Requests and limits do not need to match.** A sandboxed pod whose requests are below its
  limits is admitted and boots. Its VM is sized from the requests: the sandbox's memory
  follows `resources.requests.memory` (Amazon EKS User Guide, *Limitations*, the memory
  overhead and sandbox kernel sections), and a limit above the request does not make the VM
  bigger. Measured on the maintainers' cluster on 2026-10-21: requests of 500m and 256Mi with
  limits of 2 CPU and 1Gi booted with one vCPU and `MemTotal: 390040 kB`, while requests of
  2 CPU and 1Gi, with or without equal limits, booted with two vCPUs and
  `MemTotal: 1161132 kB`.
- In production, each sandbox reserves its full memory request up front, so bin-packing is by
  reservation, not usage: expect fewer, larger pods per node than with ordinary containers.
  (`examples/getting-started/warm-pool/README.md`, "Sizing".)
- After the first node is up, a new sandboxed pod is Ready in about 5 to 6 seconds, most of
  it the sandbox being created and booting its kernel. A warm-pool claim adopts a pod that
  is already running and is Ready in under 1 second.
  (`examples/getting-started/hello-sandbox/README.md`;
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
| `SandboxTemplate` | `extensions.agents.x-k8s.io/v1beta1` | A reusable pod template. Set `runtimeClassName` here. Leave `networkPolicyManagement` at its default unless the sample ships its own policy, which a new sample does not. A pod made from a template has `automountServiceAccountToken` defaulted to `false` unless the template sets it. | Warm pool and Claude Managed Agents pages; upstream API reference |
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
  for it, and never on slides or in videos; show the sample's actual requests, or that it
  sets none, instead.
- Do not say requests must equal limits, or that the VM is sized to the pod's limits. It is
  sized from the requests (see "Sizing and start-up").
- Do not describe confidential-mode policy generation or attestation from memory; point to
  the Amazon EKS User Guide.
