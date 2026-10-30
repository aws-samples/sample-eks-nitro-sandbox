# OpenShell on Amazon EKS

[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) is an open-source runtime for
fleets of autonomous AI agents: you declare in a policy what each agent may touch — which
files, which processes and which network destinations — and OpenShell enforces it on the
kernel, adding real credentials only to requests bound for approved endpoints so the agent
never sees them. This sample installs OpenShell on Amazon EKS from its own Helm charts,
with every OpenShell sandbox's **workload pod** — the one place untrusted agent code runs
— in a Nitro sandbox (`runtimeClassName: isolated-sandbox`). The **supervisor** pod beside
it, which holds the policy engine, the gateway session and the real credentials, stays an
ordinary pod: it is the trusted control side that evaluates policy and opens the approved
upstream connections.

**This is the OpenShell platform install**, not an agent confined by OpenShell. [Subagent
security > openshell](../../subagent-security/openshell/README.md) is a different sample:
one procurement analyst confined by OpenShell inside its own Nitro sandbox, with a
hand-built gateway just big enough to drive that one sandbox. This page is about OpenShell
itself — its gateway and workspace Helm charts, its Kubernetes compute driver, and the
two-pod-per-sandbox shape it creates — mapped onto Nitro sandboxes.

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run these samples first, which this one builds on and does not
re-explain:

- [Getting started > Warm pool](../../getting-started/warm-pool/README.md): installs the
  agent-sandbox controller v1.0.6, whose `Sandbox` API (`agents.x-k8s.io`) OpenShell's
  Kubernetes driver drives.
- [Getting started > Coding agent](../../getting-started/coding-agent/README.md): turns on
  network policy enforcement once per cluster, which OpenShell's own setup guide requires.

The commands below use files from this repository, so clone it if you have not already,
and run them from this sample's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/openshell/kubernetes
```

For this sample you also need [`helm`](https://helm.sh/docs/intro/install/),
[`kubectl`](https://kubernetes.io/docs/reference/kubectl/), `jq`, `curl`, `openssl`,
`python3` and a cluster whose Kubernetes version serves `MutatingAdmissionPolicy` (stable
and enabled by default from Kubernetes 1.36). A run costs the gateway pod, the workspace
prerequisites, and, while a sandbox exists, its workload pod, its supervisor pod and its
EBS workspace volume. No Ingress, no LoadBalancer and no NAT gateway of its own, so there
is no cost beyond the cluster besides that small standing footprint.

Every output block on this page is from one real, fresh run of `./scripts/setup.sh`
followed by `./scripts/demo.sh`. Values from the account and cluster it ran on are replaced
by placeholders because this repository is public: `<ACCOUNT_ID>` and `<NODE_NAME>`. The
Region is left as `us-west-2`, this repository's shared default. Pod names, kernel
timestamps, the demo credential's resolved placeholder and its SHA-256 digest are exactly
as the run printed them. The one value this page never shows, not even as a fake, is the
demo credential's own real value: `scripts/demo.sh` never prints it either, inside the
sandbox or out of it, comparing digests instead -- see "The agent's credential" below.

## Overview

*Figure 1: The OpenShell platform install on Amazon EKS, namespace by namespace. Notice the workload pod's only way out is the boundary channel from the supervisor, and that no line connects it to the credential namespace; a direct attempt to the echo API is refused by the NetworkPolicy.*

![An AWS Cloud frame holds one Amazon EKS cluster. An operator CLI outside the cluster reaches it with kubectl port-forward over mTLS. Inside the cluster, a gateway namespace, created by OpenShell's gateway Helm chart, holds an ordinary ClusterIP pod running the OpenShell gateway. The gateway's Kubernetes driver creates a Sandbox custom resource. A sandbox namespace, created by OpenShell's workspace Helm chart, holds that Sandbox resource, a red Nitro sandbox frame labeled runtimeClassName isolated-sandbox, an OpenShell supervisor pod, and an echo API pod. The agent-sandbox controller turns the Sandbox resource into the workload pod inside the Nitro sandbox frame, where the untrusted agent process runs with its own kernel, boot and virtio disks. A workspace volume, backed by Amazon EBS through a StorageClass, is attached to the workload pod. The OpenShell supervisor pod sits outside the red frame as an ordinary pod with no RuntimeClass; it holds the policy engine and substitutes real credentials. One arrow connects the supervisor to the workload pod, labeled boundary channel port 5500: two NetworkPolicies together allow the workload pod exactly one egress destination, the supervisor on that port, and allow the supervisor ingress to the workload on that same port, and nothing else in either direction; this is the one path out of the sandbox. The supervisor also calls the echo API pod on the agent's behalf, substituting the real credential, and separately reaches a Secret in a credential namespace that holds the real credential; the gateway also reaches that Secret, through its own Kubernetes Secrets credential driver. No line connects the workload pod to the credential namespace. A red dashed arrow runs directly from the workload pod to the echo API pod, labeled a direct connection is refused: NetworkPolicy drops it, showing that a bypass attempt around the supervisor fails.](images/openshell-kubernetes.png)

- **OpenShell installed from its own Helm charts.** The gateway chart
  (`oci://ghcr.io/nvidia/openshell/helm-chart`) installs the control plane; the workspace
  chart (`oci://ghcr.io/nvidia/openshell/openshell-workspace`) installs the namespace-scoped
  sandbox prerequisites — the sandbox `ServiceAccount`, its `Role` and `RoleBinding`, and a
  `NetworkPolicy` — in a separate, pre-provisioned sandbox namespace. The page shows both
  Helm releases, the gateway pod Ready, and `server.defaultRuntimeClassName:
  isolated-sandbox` in the gateway's values, the one line that puts every OpenShell
  sandbox's workload pod in a Nitro sandbox.
- **Each sandbox is a Nitro workload pod plus an ordinary supervisor pod.** Creating one
  OpenShell sandbox produces a `Sandbox` resource, a workload pod and a supervisor pod. The
  page shows the workload pod's `runtimeClassName: isolated-sandbox` and its own kernel
  build, boot and virtio disks, next to what an ordinary pod on the same node shows
  instead; and the supervisor pod with no runtime class at all, running as an ordinary
  pod.
- **The agent gets a credential placeholder, never the real value.** A demo credential is
  stored as a Kubernetes `Secret` through OpenShell's Kubernetes Secrets credential driver,
  in a dedicated credential namespace the gateway reads. The workload pod receives only a
  placeholder: the page shows the agent's own environment holding the placeholder form,
  shows the credential `Secret` by name only, and shows that it is not mounted in the
  workload pod. The supervisor re-originates the request with the real value.
- **Three layers each refuse something.** OpenShell's own policy refuses a file read
  outside the agent's filesystem policy and refuses a connection to a network destination
  the policy does not list. The Nitro boundary keeps the node's own processes and
  filesystem out of the guest, and keeps the supervisor's real credential absent from it
  too. The Kubernetes `NetworkPolicy` OpenShell's driver creates for
  the sandbox denies a direct, workload-initiated connection outright, so a connection from
  the workload pod's own network namespace that does not go through OpenShell at all — this
  page makes one with an ephemeral debug container — is still dropped on the node.
- **The gateway is reached only with `kubectl port-forward`.** The gateway Service is
  ClusterIP. The page reaches it that way, with the mTLS client bundle the chart generates,
  and uses the OpenShell CLI's `sandbox exec` to run commands inside a sandbox. It creates
  no Ingress, LoadBalancer or NodePort.

## What runs in a sandbox, and what does not

| Component | Runtime | Why |
|---|---|---|
| The OpenShell **gateway** (control plane, on its bundled SQLite) | ordinary pod | The trusted control plane that creates and manages sandboxes. OpenShell's [setup guide](https://github.com/NVIDIA/OpenShell/blob/v0.1.6/docs/kubernetes/setup.mdx) runs it as an in-cluster service reached by `kubectl port-forward`. |
| The per-sandbox **supervisor** pod | ordinary pod | OpenShell's own trust boundary: it holds the gateway session, the policy engine and the real credentials, evaluates policy and opens approved upstream connections. Sandboxing it would defeat its job. |
| The per-sandbox **workload** pod | `runtimeClassName: isolated-sandbox` | Where the agent — the place untrusted code executes — runs. This is the one thing that needs hardware-level isolation, and its containers run in a lightweight VM with a kernel of their own. |

## Versions

Pinned to releases, not commits, and confirmed against the published artifacts when this
sample was built (see [`versions.json`](versions.json) for the exact values):
`scripts/setup.sh` verifies both charts against their pinned SHA-256 before installing
either, and pins the gateway, supervisor and sandbox-runtime images by digest in the
rendered values, so what actually runs is not left to each image's tag.

| Component | Pin |
|---|---|
| agent-sandbox controller ([kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)) | v1.0.6, as in Getting started > Warm pool |
| OpenShell gateway chart (`oci://ghcr.io/nvidia/openshell/helm-chart`) | 0.1.6 |
| OpenShell workspace chart (`oci://ghcr.io/nvidia/openshell/openshell-workspace`) | 0.1.6 |
| OpenShell gateway, supervisor and sandbox-runtime images | the chart's `appVersion`, 0.1.6 |
| OpenShell CLI ([releases](https://github.com/NVIDIA/OpenShell/releases)) | v0.1.6 |
| Default workload image | `nvcr.io/nvidia/base/ubuntu:24.04`, the chart's own built-in default — this sample builds no image of its own |

## What OpenShell needs from the cluster, and how this EKS cluster meets it

| OpenShell needs | On this cluster |
|---|---|
| Kubernetes 1.29 or later, with RBAC | Met by every EKS version the Getting started cluster can run. |
| A CNI that enforces ingress and egress `NetworkPolicy` in sandbox namespaces | Off until the network policy controller is enabled, once per cluster — see Getting started > Coding agent. `scripts/setup.sh` checks `enable-network-policy-controller` on the `amazon-vpc-cni` `ConfigMap` and refuses to go on if it is not `"true"`. |
| The agent-sandbox controller and CRDs, installed before the chart | Installed by Getting started > Warm pool. Neither OpenShell chart installs or upgrades it. |
| A StorageClass for each sandbox's workspace PVC (`server.workspaceStorageClass`) | This cluster's own default EBS StorageClass, `auto-ebs-sc` (`ebs.csi.eks.amazonaws.com`, `gp3`, encrypted), already fits what the chart needs — block-backed storage, not a network filesystem — so this sample reuses it rather than creating a class that would duplicate it. Named explicitly in the gateway's values so a cluster with no default StorageClass still works. |
| Block-backed storage for the gateway's SQLite database | The same EBS, via the gateway's own PVC. |
| One gateway replica, or an external PostgreSQL for more | One replica (a `StatefulSet`). This sample needs no database service. |
| A kernel that allows Landlock and an unprivileged, nested seccomp user-notification filter | In a Nitro sandbox, OpenShell's own probe for both runs against the guest's kernel, not the node's, and this page shows it passing: the workload pod reaches `Ready` and runs commands under the sandbox's own policy. |

Two optional OpenShell features stay off: `server.enableUserNamespaces` (a Nitro sandbox
does not support `hostUsers: false`, so this is the chart default left as it is, not
turned on), and the Gateway API ingress path, which would expose the gateway.

## Two gaps this sample's own run found, and what fills them

Proving this sample found two places where OpenShell v0.1.6's own setup guide and its
charts disagree, specifically in the combination the guide's own "Split gateway and
workspace releases" section describes for one pre-provisioned sandbox namespace
(`server.drivers.kubernetes.workspaceMode: shared`, gateway installed with
`workspaceResources.enabled=false`, the workspace chart installed in the sandbox
namespace). Neither is a change to OpenShell: the chart, the gateway, the supervisor and
the in-pod runtime are the upstream v0.1.6 builds `versions.json` pins.

1. **A namespace-scoped RBAC gap.** With that combination, every sandbox create failed
   with `networkpolicies.networking.k8s.io "openshell-sandbox-workloads" is forbidden`. The
   gateway chart's own `Role` — which grants the full set the Kubernetes driver needs in
   shared mode: `sandboxes`, `events`, create/delete/patch/watch on `pods`, create/get on
   `services`, create/get on `networkpolicies`, and create/delete on `secrets` — renders
   only when `workspaceResources.enabled` stays `true`. The cluster-wide `ClusterRole`
   grants that same set, but only when `workspaceMode` is **not** `shared`. The
   `openshell-workspace` chart's own `Role` is narrower: `sandboxes`, `events`, `secrets`
   create/delete, and `pods` **get only** — no `services`, no `networkpolicies`, and no
   create/delete/patch/watch on `pods`. So this exact combination has no source for the
   permissions the driver needs to create the workload pod, the boundary `Service` and the
   per-sandbox `NetworkPolicy`. [`deploy/gateway-sandbox-rbac.yaml`](deploy/gateway-sandbox-rbac.yaml)
   is a `Role` and `RoleBinding`, scoped to this sample's sandbox namespace and to the
   gateway's own `ServiceAccount`, that supplies exactly the missing verbs — nothing the
   gateway chart's own `Role` would not have granted here.
2. **The supervisor pod's `client-tls` Secret is not in the sandbox namespace.** The
   supervisor pod mounts a Secret named `<gateway release>-client-tls`, with no namespace
   qualifier, so it is read from the pod's **own** namespace. In the single-release
   pattern that namespace is the gateway's release namespace, where the chart's PKI job
   always creates that Secret. In the split pattern the supervisor pod is scheduled in the
   **sandbox** namespace instead, and nothing in either chart copies the Secret there, so
   every supervisor pod failed to start with `MountVolume.SetUp failed ... secret
   "openshell-client-tls" not found`. `scripts/setup.sh` copies (never moves or
   regenerates) that Secret into the sandbox namespace each time it runs, so an
   operator-rotated certificate reaches it too.

Both fixes are small, namespace-scoped, and touch nothing OpenShell ships. The first of
OpenShell's own four "prove first" points for this sample — whether the workload pod
starts unchanged, or what adjustment it needs — turned up a third, separate fix, below.

## Adapting the workload pod to a Nitro sandbox

OpenShell's Kubernetes driver generates the workload pod with two details that need
adjusting to start inside a Nitro sandbox guest, both found and fixed the same way in
[Subagent security > openshell](../../subagent-security/openshell/README.md) at this same
v0.1.6 release, and carried over unchanged here because they answer OpenShell's own pod
shape, not anything specific to that sample's image:

1. OpenShell starts its in-pod runtime from a static binary on a pod volume, which a
   sandbox guest refuses to execute directly as a container's entrypoint
   (`exec ... permission denied`): the pod volume carries a different SELinux type from the
   image's own root filesystem. The fix starts the same binary through
   `/bin/sh -c 'exec "$0" "$@"'` instead, which only needs the workload image to provide
   `/bin/sh` — true of this sample's default image.
2. OpenShell mounts the workspace PVC at two paths in one pod (the seeding init container
   and the agent container), and a sandbox guest accepts a PVC mounted only once. The fix
   gives the seeding container an `emptyDir` at its path instead, so the workspace volume
   is mounted once, at `/sandbox`.

A third point from that list needed no fix: init containers with no CPU or memory requests
were admitted in the sandboxed pod unchanged.

Both adjustments are the whole of
[`deploy/nitro-adapter.yaml`](deploy/nitro-adapter.yaml), a `MutatingAdmissionPolicy`
scoped to namespaces carrying this sample's own `managed-by` label and to pods OpenShell
itself labels `openshell.ai/boundary-role: workload` — so it reaches no pod outside this
sample, including another OpenShell gateway's. It changes nothing about the runtime's
command arguments, its user, its capabilities, its seccomp profile or its policy: the page
reads all of those from the running process, so an adapter that changed them would be
changing the thing the sample measures.

## Files

| File | What it is |
|---|---|
| [`versions.json`](versions.json) | Every pin: the two charts' versions and SHA-256, the three image digests, the CLI's version and SHA-256 |
| [`deploy/gateway-values.yaml`](deploy/gateway-values.yaml) | The gateway chart's Helm values |
| [`deploy/workspace-values.yaml`](deploy/workspace-values.yaml) | The workspace chart's Helm values |
| [`deploy/nitro-adapter.yaml`](deploy/nitro-adapter.yaml) | The `MutatingAdmissionPolicy` that fits OpenShell's generated workload pod to a Nitro sandbox guest |
| [`deploy/gateway-sandbox-rbac.yaml`](deploy/gateway-sandbox-rbac.yaml) | The namespace-scoped `Role`/`RoleBinding` that fills the RBAC gap above |
| [`policy/sandbox-policy.json`](policy/sandbox-policy.json) | The OpenShell sandbox policy: filesystem, process and the one network rule |
| [`policy/demo-profile.json`](policy/demo-profile.json) | The endpointless provider profile the demo credential binds through |
| [`scripts/setup.sh`](scripts/setup.sh) | Installs both Helm charts, the admission adapter, the RBAC fix, the RuntimeClass label and the demo echo API |
| [`scripts/demo.sh`](scripts/demo.sh) | Creates one fresh sandbox and shows every claim this page makes, with real output |
| [`scripts/clean.sh`](scripts/clean.sh) | Removes everything this sample created |

## Quick start

**Step 1: Confirm network policy enforcement is on.** `scripts/setup.sh` checks this and
refuses to go on if it is not; the command to turn it on, once per cluster, is in Getting
started > Coding agent:

```bash
kubectl get configmap -n kube-system amazon-vpc-cni -o jsonpath='{.data.enable-network-policy-controller}'
```

**Step 2: Install the gateway chart, the workspace chart, the admission adapter and the
RBAC fix, and start the demo echo API.**

```bash
cp .env.example .env    # optional; defaults match this page
./scripts/setup.sh
```

This block is from a real run, abridged: `helm`'s own multi-line `NAME:`/`LAST DEPLOYED:`/
`NAMESPACE:`/`REVISION:`/`DESCRIPTION:`/`TEST SUITE:` summary after each install is
trimmed to its `STATUS:` line, and the run record path at the end is omitted; every line
shown is printed verbatim by the run, in order.

```text
==> checking tools and the cluster (1/10)
  agent-sandbox: reusing the install already on this cluster
  network policy enforcement: on

==> the gateway and sandbox namespaces (2/10)
namespace/openshell-kubernetes created
namespace/openshell-kubernetes labeled
  created the namespace openshell-kubernetes
namespace/openshell-kubernetes-sandbox created
namespace/openshell-kubernetes-sandbox labeled
  created the namespace openshell-kubernetes-sandbox

==> the isolated-sandbox RuntimeClass's OpenShell approval label (3/10)
  runtime class: isolated-sandbox already carries openshell.ai/sandbox-attachable=true

==> the admission adapter that fits OpenShell's workload pod to a Nitro sandbox (4/10)
mutatingadmissionpolicy.admissionregistration.k8s.io/openshell-kubernetes-nitro-adapter created
mutatingadmissionpolicybinding.admissionregistration.k8s.io/openshell-kubernetes-nitro-adapter created
  applied openshell-kubernetes-nitro-adapter, scoped to namespaces labelled managed-by=openshell-kubernetes

==> the namespace-scoped RBAC this sample's own run found missing (5/10)
role.rbac.authorization.k8s.io/openshell-sandbox-rbac-gap created
rolebinding.rbac.authorization.k8s.io/openshell-sandbox-rbac-gap created
  applied openshell-sandbox-rbac-gap in openshell-kubernetes-sandbox, scoped to the gateway's own ServiceAccount

==> the pinned OpenShell CLI, gateway chart and workspace chart (v0.1.6) (6/10)
  reusing the verified CLI at tmp/openshell-kubernetes/local/openshell-v0.1.6
  verified the gateway chart and the workspace chart against their pinned checksums

==> the OpenShell gateway (7/10)
  pinned the gateway, supervisor and sandbox-runtime images by digest
  rendered chart: all Services are ClusterIP, and no Ingress, Gateway or Route
Release "openshell" does not exist. Installing it now.
STATUS: deployed

==> the sandbox namespace's own prerequisites (8/10)
Release "openshell-workspace" does not exist. Installing it now.
STATUS: deployed
Waiting for 1 pods to be ready...
partitioned roll out complete: 1 new pods have been updated...
secret/openshell-client-tls created
  copied the gateway's client-tls Secret into openshell-kubernetes-sandbox for the supervisor pod
  confirmed: neither the sandbox ServiceAccount nor the namespace's default ServiceAccount can get, list or watch Secrets in openshell-kubernetes-sandbox
  labelled the credential namespace openshell-kubernetes-credentials as this sample's

==> the demo echo API this sample's policy and provider point at (9/10)
pod/echo-api created
pod/echo-api condition met
service/echo-api exposed
  echo-api Ready, reachable in-cluster at echo-api.openshell-kubernetes-sandbox.svc.cluster.local:80

==> ready (10/10)
  gateway namespace:    openshell-kubernetes
  sandbox namespace:    openshell-kubernetes-sandbox
  credential namespace: openshell-kubernetes-credentials
  gateway release:      openshell (OpenShell v0.1.6)
  workspace release:    openshell-workspace
```

The gateway's values set the one line that matters most on this page:

```yaml
server:
  defaultRuntimeClassName: isolated-sandbox
  workspaceStorageClass: auto-ebs-sc
  credentialDrivers:
    kubernetesSecrets:
      enabled: true
      namespace: openshell-kubernetes-credentials
```

Both Helm releases, and the gateway pod Ready:

```text
$ helm list -n openshell-kubernetes
NAME       NAMESPACE              REVISION   STATUS     CHART               APP VERSION
openshell  openshell-kubernetes   1          deployed   helm-chart-0.1.6    0.1.6

$ helm list -n openshell-kubernetes-sandbox
NAME                  NAMESPACE                       REVISION   STATUS     CHART                        APP VERSION
openshell-workspace   openshell-kubernetes-sandbox     1          deployed   openshell-workspace-0.1.6    0.1.6

$ kubectl get pods -n openshell-kubernetes
NAME          READY   STATUS    RESTARTS   AGE
openshell-0   1/1     Running   0          107s
```

**Step 3: Reach the gateway with `kubectl port-forward`, and create one sandbox.** In a
separate terminal:

```bash
kubectl -n openshell-kubernetes port-forward svc/openshell 8080:8080
```

Then:

```bash
./scripts/demo.sh
```

The sections below are that one run's own output.

## The CLI, registered over the port-forward with the generated mTLS bundle

```text
==> the mTLS client bundle and the CLI
✓ Gateway 'k8s' added and set as active
  Endpoint: https://127.0.0.1:8080
  Type: local
✓ TLS certificates present
Server Status

  Gateway: k8s
  Server: https://127.0.0.1:8080
  Status: Connected
  Authentication: Authenticated (mTLS transport)
  Version: 0.1.6
```

## Each sandbox is a Nitro workload pod and an ordinary supervisor pod

```text
==> the two pods of this one sandbox
  workload pod:   default--demo-1793373763
    runtimeClassName: isolated-sandbox
  supervisor pod: os-supervisor-08dab363-f500-4a4a-9e0c-8a2aa126094e
    runtimeClassName:
    (empty means no RuntimeClass: an ordinary pod)
  workspace PVC: Bound on auto-ebs-sc
```

The workload pod's own kernel, boot and virtio disks, next to the same node's own view
from an ordinary pod:

```text
==> the workload pod's own kernel, boot and virtio disks
  guest /proc/version:
Linux version 6.18.54 (builder@buildkitsandbox) (x86_64-bottlerocket-linux-gnu-gcc (Buildroot 2025.05.1) 13.4.0, GNU ld (GNU Binutils) 2.44) #1 SMP PREEMPT_DYNAMIC Thu Oct 22 17:38:11 UTC 2026
  guest /sys/class/dmi/id/product_name and disks:
product_name: m8i.enclave
disks: dm-0 vda vdb vdc vdd vde
  the same node's own view, from an ordinary pod on <NODE_NAME>:
product_name: m8i.xlarge
disks: dm-0 loop0 loop1 loop2 loop3 loop4 loop5 loop6 loop7 nvme0n1 nvme1n1 nvme2n1 zram0
Linux version 6.18.54 (builder@buildkitsandbox) (x86_64-bottlerocket-linux-gnu-gcc (Buildroot 2025.05.1) 13.4.0, GNU ld (GNU Binutils) 2.44) #2 SMP PREEMPT_DYNAMIC Thu Oct 22 00:16:59 UTC 2026
```

Both report the same kernel version and the same toolchain, because both come from this
cluster's own build pipeline — but a different build number and a different build
timestamp (`#1` at `17:38:11` against `#2` at `00:16:59`), because the guest boots its own
kernel, not the node's. The product name and the disk list say the same thing a different
way: the guest is a `m8i.enclave` VM with virtio disks (`vda`, `vdb`, ...), where the
ordinary pod on the very same node reports the node's own `m8i.xlarge` instance and its
`nvme` devices.

## The agent's credential: a placeholder, never the real value

The demo credential is stored once, through OpenShell's Kubernetes Secrets credential
driver, as a `Secret` in its own namespace — shown here by name only:

```text
  the credential Secret, by name only -- never its value:
openshell-cred-44e9cec6427ba71ca7a3a1bd17b9214d05a0b8d2   Opaque
```

The agent's own environment holds a placeholder, never the value:

```text
==> the agent's credential: a placeholder, never the real value
  the agent's own environment:
DEMO_API_KEY=openshell:resolve:env:v16163222340319365196_DEMO_API_KEY
```

A request to the one endpoint this sandbox's policy allows — an in-cluster HTTP echo
service that this sample starts so there is something to send the credential to and get it
back for inspection — shows the **real** value reached the backend, substituted by the
supervisor, outside the sandbox. Echoing the header back is this demo backend's own
doing, not something every approved endpoint does or needs to: a real deployment's own
backend need never reflect a credential back at all, and most do not. Because this one
does, the bytes do pass back through the sandbox on their way to being checked — what
this page holds to is that they are never *printed* anywhere, inside the sandbox or out
of it, and never leave the sandbox in that form either: the SHA-256 digest of the
response's own credential header is computed by a command run *inside* the sandbox, and
only the digest, never the header itself, leaves it; this run's own record of the digest
it stored in the Secret, from when the provider was created, is what it is compared
against:

```text
  the digest of the value the backend received (substituted by the supervisor, outside the sandbox), computed INSIDE the sandbox so the real value is never printed anywhere, including by this script:
  resolved credential digest: 54e0e570af0cb192908cf6e25d7084df84c7dccc48fe8ee93b0539358488accb
  matches the digest of the credential this run stored in the Secret: true
```

And the workload pod mounts no Secret for it at all:

```text
  no Secret for the real credential is mounted in the workload pod:
os-sandbox-08dab363-f500-4a4a-9e0c-8a2aa126094e-67033f850bef
```

(That one Secret is OpenShell's own per-sandbox bootstrap material, not a provider
credential, and the directory it was staged into is already empty by the time the agent
runs.)

## Three layers each refuse something

**Layer 1 — OpenShell's own policy.** A file outside the sandbox's filesystem policy, and a
network destination outside its one allowed endpoint, are both refused inside the guest,
by the policy the gateway gave this sandbox. The refused file is world-readable
(`/var/lib/dpkg/status`, mode `644`), so the refusal below is the policy, not a Unix
permission a root-owned, non-readable file would have produced on its own:

```text
==> layer 1: OpenShell's policy refuses a file outside it and a destination outside it
  a file the policy does not list (world-readable, so this is the policy and not a Unix permission):
644 /var/lib/dpkg/status
cat: /var/lib/dpkg/status: Permission denied
cat exit=1
  control -- a file the policy does list:
default--demo-1793373763
  a destination the policy does not list:
bash: connect: Permission denied
bash: line 1: /dev/tcp/kubernetes.default.svc.cluster.local/443: Permission denied
```

`stat` succeeds and reports the file's own mode, `644`: any process on the node could
read it. `cat` on the very same path, moments later and at the very same uid, is refused
— which is what puts the refusal on OpenShell's policy rather than on a file mode a
root-owned, non-readable file would have produced on its own.

**Layer 2 — the Nitro boundary.** Only the sandbox's own processes are visible in the
guest, and the guest's own environment is checked, not eyeballed, for anything beyond the
one placeholder:

```text
==> layer 2: the Nitro boundary -- the node is invisible, and the credential is absent
  processes visible in the guest (its own, only):
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
ubuntu         1  0.5  9.0 122212 11624 ?        Ssl  13:29   0:00 /.openshell/runtime/openshell-sandbox --bootstrap /.openshell/state/bootstrap/boundary.json
ubuntu        56  0.0  0.0   2708   104 ?        S    13:29   0:00 sleep 3600
ubuntu        71  0.0  0.3   4336   408 ?        S    13:29   0:00 bash -c  exec 3<>/dev/tcp/echo-api.openshell-kubernetes-sandbox.svc.cluster.local/80 ...
ubuntu        76  0.0  0.1   2852   244 ?        S    13:29   0:00 cat
ubuntu        88  0.0  2.9   7904  3808 ?        R    13:29   0:00 ps aux
  the guest's environment, checked rather than eyeballed:
DEMO_API_KEY=openshell:resolve:env:v16163222340319365196_DEMO_API_KEY
  no other credential-shaped variable
```

`ps aux` showing only the sandbox's own processes is true of any pod with its own PID
namespace, sandboxed or not, so it is shown for completeness rather than as Nitro-specific
evidence; the kernel build number and the DMI/disk comparison above are what actually
distinguish the Nitro boundary from an ordinary container. The environment check greps
for every credential-shaped variable name *other than* the placeholder itself, so a real
secret accidentally present alongside it would be caught, not hidden behind a check that
the placeholder's own name would always satisfy.

**Layer 3 — the Kubernetes `NetworkPolicy`.** Because OpenShell's Kubernetes driver creates
`Sandbox` resources directly rather than through a `SandboxTemplate`, agent-sandbox's own
controller applies no managed `NetworkPolicy` of its own to these pods (`networkPolicyManagement`
is a `SandboxTemplate`-only field in the [v1.0.6 API reference](https://github.com/kubernetes-sigs/agent-sandbox/blob/v1.0.6/docs/api.md)).
The page lists every `NetworkPolicy` in the sandbox namespace and checks which select the
workload pod's own labels, rather than assuming there is exactly one: there are two, both
OpenShell's own, and only together do they say what the workload pod may actually reach.

```text
==> layer 3: the Kubernetes NetworkPolicy drops a direct, workload-initiated connection
  every NetworkPolicy in the sandbox namespace, and which select the workload pod's labels:
NAME                                              POD-SELECTOR                                                      AGE
openshell-sandbox-supervisors                     openshell.ai/boundary-role=supervisor                             29s
openshell-sandbox-workloads                       openshell.ai/boundary-role=workload                               29s
openshell-workspace-sandbox-ssh                   openshell.ai/managed-by=openshell                                 68s
os-control-08dab363-f500-4a4a-9e0c-8a2aa126094e   openshell.ai/boundary-pair=08dab363-f500-4a4a-9e0c-8a2aa126094e   29s
  workload pod labels: {"agents.x-k8s.io/sandbox-name-hash":"f890780d","openshell.ai/boundary-pair":"08dab363-f500-4a4a-9e0c-8a2aa126094e","openshell.ai/boundary-role":"workload","topology.kubernetes.io/region":"us-west-2","topology.kubernetes.io/zone":"us-west-2c"}
  the two NetworkPolicies selecting the workload pod (boundary-pair=08dab363-f500-4a4a-9e0c-8a2aa126094e):
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  labels:
    openshell.ai/component: sandbox-workload-fence
    openshell.ai/managed-by: openshell
  name: openshell-sandbox-workloads
  namespace: openshell-kubernetes-sandbox
spec:
  ingress:
  - from:
    - podSelector:
        matchLabels:
          openshell.ai/boundary-role: supervisor
    ports:
    - port: 5500
      protocol: TCP
  podSelector:
    matchLabels:
      openshell.ai/boundary-role: workload
  policyTypes:
  - Ingress
  - Egress
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  labels:
    openshell.ai/component: sandbox-control-egress
    openshell.ai/managed-by: openshell
    openshell.ai/sandbox-id: 08dab363-f500-4a4a-9e0c-8a2aa126094e
  name: os-control-08dab363-f500-4a4a-9e0c-8a2aa126094e
  namespace: openshell-kubernetes-sandbox
spec:
  egress:
  - ports:
    - port: 5500
      protocol: TCP
    to:
    - podSelector:
        matchLabels:
          openshell.ai/boundary-pair: 08dab363-f500-4a4a-9e0c-8a2aa126094e
          openshell.ai/boundary-role: supervisor
  ingress:
  - from:
    - podSelector:
        matchLabels:
          openshell.ai/boundary-pair: 08dab363-f500-4a4a-9e0c-8a2aa126094e
          openshell.ai/boundary-role: workload
    ports:
    - port: 5500
      protocol: TCP
  podSelector:
    matchLabels:
      openshell.ai/boundary-pair: 08dab363-f500-4a4a-9e0c-8a2aa126094e
  policyTypes:
  - Ingress
  - Egress
```

Kubernetes `NetworkPolicy` objects selecting the same pod are additive, so what actually
governs the workload pod is the union of both. `openshell-sandbox-workloads` names
`Egress` as a `policyType` but carries no `egress` rule at all, which alone would deny
every egress connection; `os-control-<boundary-pair>`, generated fresh for this one
sandbox, adds back exactly one: to its own paired supervisor, on port 5500. Combined, the
workload pod may egress to its own supervisor's boundary port and nowhere else -- that
one port, in that one direction, is the whole of the boundary channel out of the
sandbox. `openshell-sandbox-workloads`'s own ingress rule is the wider of the two: it
admits port 5500 from *any* pod labelled `boundary-role: supervisor` in the namespace,
not only this sandbox's own, so it is shared cluster-wide infrastructure rather than
something generated per sandbox; `os-control-<boundary-pair>` narrows that back down to
the paired supervisor specifically for this one sandbox's own ingress rule. Either way,
nothing besides that one port, to or from a supervisor, is open for the workload pod.

To show the echo API's own refusal is attributable to these `NetworkPolicy` objects
alone, and not to OpenShell's own in-pod interception, this page makes the connection
attempt from somewhere OpenShell's own interception cannot reach: an **ephemeral debug
container** (`kubectl debug ... --target=agent`), added to the running pod as its own,
separate OCI container, sharing only the pod's network namespace with the agent's
container. OpenShell's filesystem and process confinement is a seccomp filter and a
Landlock ruleset installed on the agent's own process tree; both are inherited only
through that process's own `fork`/`exec` lineage, which an independently started sibling
container is never part of, so this container runs under neither. What it does share is
the network namespace, which is exactly what a Kubernetes `NetworkPolicy` enforces on —
so a connection attempt from here tests the `NetworkPolicy` alone, with OpenShell's own
interception structurally unable to apply to it, not merely assumed absent. Bypassing
OpenShell entirely does not bypass the `NetworkPolicy`:

```text
  a connection from the workload pod's own network namespace, outside OpenShell's control (an ephemeral debug container sharing it), to the policy-approved backend by IP -- bypassing OpenShell entirely does not bypass the NetworkPolicy:
Connecting to 10.100.168.40 (10.100.168.40:80)
wget: download timed out
EXIT=1
```

The same technique, run instead against the **supervisor** pod — whose own `NetworkPolicy`
(`openshell-sandbox-supervisors`, listed above) allows unrestricted egress — reaches the
same backend immediately, with the same tool, confirming the refusal above is specific to
the workload pod's own `NetworkPolicy` set and not a cluster-wide outage or routing
problem:

```text
  control -- the same technique against the supervisor pod, which carries no such restriction:
Connecting to 10.100.168.40 (10.100.168.40:80)
writing to stdout
{
  "headers": {
    "Connection": [
      "close"
    ],
    "Host": [
      "10.100.168.40"
    ],
    "User-Agent": [
      "Wget"
    ]
  }
}
EXIT=0
```

## Good to know

- **The demo credential and its backend are this sample's own, not OpenShell's.** The
  echo API this sample starts (`docker.io/mccutchen/go-httpbin`) exists only so there is an
  in-cluster destination to send the one credential to and show it substituted. A real
  deployment names a real provider profile and a real backend instead.
- **The gateway's development auth mode is for this page, not for a shared environment.**
  `server.auth.allowUnauthenticatedUsers: true` means transport mTLS and access to the
  client TLS `Secret` are the whole of this gateway's access control. This sample's subject
  is the platform install, not identity; a real deployment configures OpenShell's own OIDC
  or trusted-access-proxy authentication, as its [access control guide](https://github.com/NVIDIA/OpenShell/blob/v0.1.6/docs/kubernetes/access-control.mdx) describes.
- **The `isolated-sandbox` RuntimeClass's approval label is shared.** OpenShell's resource
  admission refuses an unlabeled RuntimeClass, so the label
  (`openshell.ai/sandbox-attachable=true`) has to be there before any sandbox can use it.
  Other OpenShell gateways and other samples on a shared cluster rely on the same label,
  so `scripts/setup.sh` adds it only when it is missing and `scripts/clean.sh` leaves it in
  place, printing the command that removes it.
- **OpenShell's own driver manages the per-sandbox `NetworkPolicy` and `Service`; this
  sample adds none of its own.** The `NetworkPolicy` shown above, and the boundary
  `Service` the supervisor and the workload use to reach each other, come entirely from
  OpenShell's Kubernetes driver. What this sample itself adds is: the admission adapter
  (a `MutatingAdmissionPolicy`, which is cluster-scoped, limited by its own
  `namespaceSelector` to namespaces labelled `managed-by=openshell-kubernetes`), the
  namespace-scoped RBAC fix above, a copy of the gateway's `client-tls` Secret in the
  sandbox namespace (see the next point), and the demo echo API's pod and Service.
- **Copying the gateway's `client-tls` Secret into the sandbox namespace widens where
  that certificate physically sits.** With `allowUnauthenticatedUsers: true` (the point
  above), that certificate is full administrative access to the gateway, and the copy
  puts it in the same namespace the untrusted workload pods live in, rather than only in
  the gateway's own namespace. `scripts/setup.sh` does not just assert this is safe: it
  checks, every run, that neither the sandbox `ServiceAccount` nor the sandbox
  namespace's own `default` `ServiceAccount` can `get`, `list` or `watch` Secrets there
  (`kubectl auth can-i <verb> secrets ... --as=system:serviceaccount:<sandbox namespace>:<sa>`
  reads as literally `yes` or `no` for all six combinations, never just a command's exit
  code, which `can-i` also returns non-zero for on a failure that is not "no" either),
  and refuses to continue if any of them can, or if any answer is neither yes nor no.
  That check is scoped to this sample's own two ServiceAccounts in that one namespace; it
  is not a general guarantee that nothing in the namespace can reach the Secret, so treat
  the copy as a real, if currently unexploited, widening of where that certificate sits.

## Clean up

```bash
./scripts/clean.sh
```

```text
==> the sandbox(es) this run created
sandbox.agents.x-k8s.io "default--demo-1793373763" deleted from openshell-kubernetes-sandbox namespace
pod "node-probe" deleted from openshell-kubernetes-sandbox namespace
pod "echo-api" deleted from openshell-kubernetes-sandbox namespace
service "echo-api" deleted from openshell-kubernetes-sandbox namespace

==> the Helm releases
  These resources were kept due to the resource policy:
  [Namespace] openshell-kubernetes-credentials

release "openshell" uninstalled
release "openshell-workspace" uninstalled

==> the admission adapter and the namespace-scoped RBAC
mutatingadmissionpolicybinding.admissionregistration.k8s.io "openshell-kubernetes-nitro-adapter" deleted
mutatingadmissionpolicy.admissionregistration.k8s.io "openshell-kubernetes-nitro-adapter" deleted
role.rbac.authorization.k8s.io "openshell-sandbox-rbac-gap" deleted from openshell-kubernetes-sandbox namespace
rolebinding.rbac.authorization.k8s.io "openshell-sandbox-rbac-gap" deleted from openshell-kubernetes-sandbox namespace

==> the namespaces
  deleting openshell-kubernetes-credentials
namespace "openshell-kubernetes-credentials" deleted
  deleting openshell-kubernetes-sandbox
namespace "openshell-kubernetes-sandbox" deleted
  deleting openshell-kubernetes
namespace "openshell-kubernetes" deleted

==> left in place on purpose
  The isolated-sandbox RuntimeClass and its openshell.ai/sandbox-attachable=true label:
  other OpenShell gateways and other samples on this cluster share it. To remove the
  label (only do this if nothing else on the cluster needs it):

    kubectl label runtimeclass isolated-sandbox openshell.ai/sandbox-attachable-

  This run's local scratch files under tmp/openshell-kubernetes/ (the downloaded CLI and
  charts, and the CLI's own client certificate for this gateway): gitignored, and not a
  cluster resource, so this script leaves them for the next run to reuse. Delete
  tmp/openshell-kubernetes/ yourself if you want them gone too.
```

Each namespace delete is followed by this script actually waiting for it to finish
terminating (up to 5 minutes) before moving on, rather than reporting "deleting" and
exiting while the delete is still in progress.

This removes both Helm releases and their namespaces, including the credential namespace,
the generated provider-credential `Secret`s and the workspace PVC; the admission adapter
and the namespace-scoped RBAC fix; and the demo echo API. It leaves the shared
`isolated-sandbox` RuntimeClass's approval label in place, and this sample's own local
scratch files under `tmp/`, printing what it left and why.

## References

- [OpenShell](https://github.com/NVIDIA/OpenShell)
- [OpenShell Kubernetes setup guide](https://github.com/NVIDIA/OpenShell/blob/v0.1.6/docs/kubernetes/setup.mdx)
- [OpenShell policy schema reference](https://github.com/NVIDIA/OpenShell/blob/v0.1.6/docs/how-it-works/policies/schema.mdx)
- [OpenShell provider profiles](https://github.com/NVIDIA/OpenShell/blob/v0.1.6/docs/how-it-works/providers/profiles.mdx)
- [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)
- [Subagent security > openshell](../../subagent-security/openshell/README.md): one analyst
  confined by OpenShell, with its own worked example of the same Nitro-sandbox adjustment
