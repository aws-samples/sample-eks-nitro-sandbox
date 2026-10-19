# Generate a Cedar policy and watch the guest enforce it

This sample generates a [Cedar](https://github.com/cedar-policy/cedar) policy from a
workload's own pod spec, attaches it to the pod, and shows the confidential sandbox guest
enforce it. The expected container starts, and an operator who is allowed by Kubernetes to
exec into the pod is still refused by the policy inside the guest. The pod runs in a Nitro
sandbox in confidential mode (`runtimeClassName: confidential-sandbox`), which treats the
node as untrusted and needs a Cedar policy that pins what the pod may run.

Cedar is an open-source authorization language. Its policies are separate from application
code, so they can be authored, read and audited on their own, and each request is decided by
explicit `permit` and `forbid` rules ([cedar-policy/cedar](https://github.com/cedar-policy/cedar)).
Here the generated policy is the check that runs inside the guest and decides what the pod
may run.

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run the [hello sandbox](../../getting-started/hello-sandbox/README.md)
sample first so you have a cluster with the runtime classes. This sample swaps
`isolated-sandbox` for `confidential-sandbox` and reads the sandbox proof from the pod's logs,
because the generated policy refuses exec. The commands below use files from this repository,
so clone it if you have not already, and run them from this sample's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/policy/cedar-policy
```

This sample needs the Cedar policy generator the Amazon EKS User Guide names,
`eks-nitro-sandbox-genpolicy`, on your `PATH`. See the Amazon EKS User Guide,
*Isolated and confidential pods*, *Cedar policies*, for the generator and how to obtain it.
The generator reports no version string of its own; the only pinned artifact is the
workload's base image, resolved to a digest at policy-generation time and shown in the
generated policy. A run creates no AWS resources: one small pod runs while the sample is up.

## Overview

The workload is one pod. Its spec sets a confidential runtime class and the container
settings the guest should accept: a pinned image, explicit numeric user and group IDs, a
read-only root filesystem and all capabilities dropped. The policy generator reads that spec
with its confidential profile and emits a Cedar policy that pins those settings and permits
reading the pod's logs, and nothing else. Setup attaches the policy to the pod as the
`sandbox.amazonaws.com/policy` annotation and starts it.

- **A policy generated from the workload's own spec.** The generator resolves the image to a
  digest and pins it, along with the process arguments, the identity, the filesystem and the
  capabilities. The generated policy document is committed next to the manifest, so you can
  read it without running anything.
- **The guest enforces the policy.** The `confidential-sandbox` guest checks the container
  against the admission policy before it starts, and evaluates every later operation against
  the runtime policy. The expected container starts; a changed spec, without a regenerated
  policy, is refused.
- **Two separate decisions for exec.** Kubernetes RBAC decides whether a caller may request
  an exec; the guest's policy decides whether the exec actually runs. The operator passes RBAC
  and is still refused inside the guest, because the generated policy has no exec permit. This
  is enforcement that sits below the operator, not in an admission controller outside the
  sandbox.

*Figure 1: A Cedar policy generated from the pod spec and enforced inside the confidential
guest. The operator generates the policy from the pod spec with the generator's confidential
profile and attaches it to the pod. The guest admits the expected container, which logs a
ready marker. When the operator runs kubectl exec, Kubernetes RBAC allows the request, and the
guest still denies the Exec action because the policy has no exec permit.*

![An operator on the left generates a Cedar policy from a pod spec with the policy generator's confidential profile, then attaches it to a Nitro sandbox pod inside an Amazon EKS cluster in the AWS Cloud. The pod runs under runtimeClassName confidential-sandbox. The guest Cedar policy admits the expected main container, which starts and logs a ready marker. The operator's kubectl exec reaches Kubernetes RBAC, which allows pods/exec, but the guest policy denies the Exec action, shown as a red dashed refused path, because the policy permits the container and log reads but has no exec permit.](images/figure-1-cedar-policy.png)

This sample demonstrates policy enforcement inside the guest only. It makes no attestation and
no key-release decision; those belong to the planned Confidential section's attested-decryption
samples. The generator does predict the policy's PCR17 measurement, which an external verifier
such as AWS KMS would check before releasing a secret, but this sample does not use it.

## Files

| File | What it is |
|---|---|
| [`deploy/pod.yaml`](deploy/pod.yaml) | The workload: a confidential-sandbox pod with pinned identity, filesystem and capabilities |
| [`deploy/namespace.yaml`](deploy/namespace.yaml) | The `cedar-policy-sample` namespace, labelled as the sample's own |
| [`deploy/egress-policy.yaml`](deploy/egress-policy.yaml), [`deploy/enable-network-policy.yaml`](deploy/enable-network-policy.yaml) | The deny-all egress network policy and the cluster-wide enforcement switch |
| [`policy/confidential-profile.yaml`](policy/confidential-profile.yaml) | The generator profile: the confidential posture, reduced for the preview guest schema |
| [`policy/policy.generated.yaml`](policy/policy.generated.yaml) | The generated Cedar policy, committed so the page can show it without a run |
| [`scripts/setup.sh`](scripts/setup.sh) | Generate the policy, attach it, apply the pod, wait for Ready |
| [`scripts/clean.sh`](scripts/clean.sh) | Delete the pod, the egress policy and the namespace, and verify they are gone |

## How it works

**Confidential mode needs a policy.** `confidential-sandbox` protects the pod from the node as
well as from other pods. Unlike `isolated-sandbox`, which applies a permissive built-in default
when a pod carries no policy, confidential mode enforces a strict default-deny posture: a pod
needs a Cedar policy that pins down what it may run (Amazon EKS User Guide, *Cedar policies*).
That policy is the subject of this sample.

**A reduced confidential profile.** The generator ships a built-in `confidential` profile, and
the Amazon EKS User Guide also documents custom profiles: a YAML file passed to `--profile`
where omitted fields take their defaults. This sample ships a custom profile,
[`policy/confidential-profile.yaml`](policy/confidential-profile.yaml). It pins the container
admission fields (the image digest, process arguments, environment, working directory,
hostname, mounts, identity, capabilities, security settings, masked and read-only paths,
seccomp, AppArmor, namespaces and sysctls) and denies exec and stdin, as the built-in
confidential profile does. It differs from the built-in profile in omitting the fields the
current preview guest schema does not define yet: the OCI-hardening attributes are not pinned,
and encrypted ephemeral-layer enforcement is not required. On this preview guest the built-in
`confidential` profile's policy is rejected at sandbox set-up, before any container starts; the
reduced profile is accepted. When the preview guest schema defines those fields, generate with
`--profile confidential` to pin them too; the exec and admission behaviour this sample shows is
unchanged. The workload has a deny-all egress policy and no Pod Identity association, so the
fields the profile omits change nothing it relies on.

**Step 1: Describe the workload.** [`deploy/pod.yaml`](deploy/pod.yaml) chooses the confidential
runtime and the container settings the guest should accept. Explicit numeric user and group IDs
make the intended identity clear. The exec-refusing policy means the sandbox proof is read from
the pod's logs, so the container prints it at start-up.

```yaml
spec:
  runtimeClassName: confidential-sandbox
  hostname: cedar-policy-demo
  automountServiceAccountToken: false
  enableServiceLinks: false
  securityContext:
    runAsUser: 65534
    runAsGroup: 65534
    runAsNonRoot: true
    supplementalGroupsPolicy: Strict
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: main
      image: public.ecr.aws/amazonlinux/amazonlinux:minimal
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
```

The complete manifest requests 1 vCPU and 1 GiB, with requests equal to limits as every
sandboxed pod on this site does. These settings become the inputs to the generated admission
policy.

**Step 2: Turn on network policy enforcement, once per cluster.** EKS Auto Mode accepts network
policies without enforcing them until the shared `amazon-vpc-cni` ConfigMap in `kube-system`
turns the controller on. This is a cluster-wide setting, so you apply it knowingly rather than
letting the sample change a shared resource for you:

```bash
kubectl apply -f deploy/enable-network-policy.yaml
```

If your cluster already has it on (from another sample, say), this is a no-op. `setup.sh`
checks it is on and stops with this command if it is not.

**Step 3: Generate the policy, attach it and start the pod.** `scripts/setup.sh` runs the
generator with the profile above, decodes the policy envelope into a readable form under the
repository's `tmp/`, renders the pod with the encoded policy in its
`sandbox.amazonaws.com/policy` annotation, applies the deny-all egress policy, and applies the
pod. It creates the `cedar-policy-sample` namespace only if it does not already exist, and
reuses it only when it carries this sample's managed-by label, so it never adopts a namespace
another demo owns.

```bash
./scripts/setup.sh
```

```text
== 1/4 generate the confidential Cedar policy from deploy/pod.yaml ==
info: wrote base64 envelope to .../tmp/cedar-policy/policy.b64
--- Predicted PCR17 ---
04d9658a1753a730560d47023403d89dae79e83a1c54fb6615c7a28944cdc51cbd5196a941e8a7c74d392c59cfadce47
== 2/4 decode the policy envelope into readable form ==
== 3/4 render the pod, namespace and egress policy with the chosen NAMESPACE ==
== 4/4 apply the pod and wait for the guest to admit it ==
namespace/cedar-policy-sample created
networkpolicy.networking.k8s.io/cedar-policy-deny-egress created
pod/cedar-policy-demo created
pod/cedar-policy-demo condition met

cedar-policy-demo is Ready and enforcing its generated Cedar policy.
```

Abridged. The generator prints a predicted PCR17, the measurement an external verifier would
check; this sample does not use it. This capture was taken from a fresh run into a namespace
that did not exist, so it shows the `namespace/... created` line; a re-run into an existing
sample namespace shows `reusing namespace ...` instead. The policy travels to the guest as the
gzipped, base64-encoded JSON envelope in the annotation, which is not readable by eye, so setup
also leaves a decoded copy under `tmp/` and the sample commits a readable copy, shown below.

**Step 4: What the generated policy pins.** The generated admission policy permits creating the
`main` container only when the container matches the settings from the pod spec. Here is the
start of the admission rule from
[`policy/policy.generated.yaml`](policy/policy.generated.yaml), the committed readable copy:

```text
// Container: main
permit(
    principal,
    action == Agent::Action::"CreateContainer",
    resource == Workload::Container::"main"
)
when {
    (context.image_ref == "public.ecr.aws/amazonlinux/amazonlinux@sha256:478c519817ce1c2cdc64700e4395775143446f8706706906b942960f0394ff2e" || ...) &&
    context.run_as_user == 65534 &&
    context.run_as_group == 65534 &&
    context.read_only_rootfs == true &&
    context.capabilities_effective.isEmpty() &&
    context.no_new_privileges == true &&
    ...
};
```

The image tag is resolved to its digest at generation time, so the parent instance cannot
substitute a different image at run time. The runtime policy permits reading logs, stats,
termination logs and the guest's own set-up actions, and has no `Exec` and no stdin permit:

```text
// Runtime: stdin writes are denied (no permit policy)
// Runtime: exec is denied (no permit policy)

// Runtime: allow log reading
permit(
    principal,
    action == Agent::Action::"ReadLogs",
    resource
);
```

The complete policy, admission and runtime, is in
[`policy/policy.generated.yaml`](policy/policy.generated.yaml).

**Step 5: The pod opted into the confidential sandbox.** The pod runs
`runtimeClassName: confidential-sandbox`, and carries the encoded policy in its annotation:

```bash
kubectl -n cedar-policy-sample get pod cedar-policy-demo \
  -o jsonpath='{.spec.runtimeClassName}{"\n"}'
kubectl -n cedar-policy-sample get pod cedar-policy-demo \
  -o jsonpath='{.metadata.annotations.sandbox\.amazonaws\.com/policy}' | wc -c
```

```text
confidential-sandbox
2944
```

**Step 6: Prove the pod ran in a sandbox, from its logs.** The policy refuses exec, so the
sandbox proof is read a different way: the container prints its kernel build, its uptime and its
block devices when it starts, and the page reads them with `kubectl logs`, which the policy
permits.

```bash
kubectl -n cedar-policy-sample logs cedar-policy-demo -c main
```

```text
kernel:  6.18.51 #1 SMP PREEMPT_DYNAMIC Thu Oct  1 23:28:07 UTC 2026
uptime:  3.48s
disks:   dm-0 dm-1 dm-2 loop0 loop1 loop2 loop3 loop4 loop5 loop6 loop7 vda vdb vdc
confidential-policy-ready
```

An ordinary (non-sandbox) pod started on the same cluster shows, instead:

```text
kernel:  6.18.51 #2 SMP PREEMPT_DYNAMIC Wed Oct  7 22:33:11 UTC 2026
uptime:  82970.46s
disks:   dm-0 nvme0n1 nvme1n1 zram0
```

The kernel version string matches, but the build does not (`#1 ... Oct 1` against
`#2 ... Oct 7`): the guest runs its own kernel. The disk list carries `vda vdb vdc`, the
guest's virtio devices, where the ordinary pod sees the instance's `nvme`; confidential mode's
encrypted overlay adds the `dm-` and `loop` devices. And the guest's uptime, about 3 seconds,
matches the just-started pod, because the VM booted with the pod; the ordinary pod's
`/proc/uptime` reports the node's uptime, over 20 hours. The last line, `confidential-policy-ready`,
is the marker that shows the expected container started.

**Step 7: An operator's exec is refused inside the guest.** The caller is allowed to
`create pods/exec` in the namespace, so an exec failure is the guest's policy and not RBAC:

```bash
kubectl auth can-i create pods/exec -n cedar-policy-sample
```

```text
yes
```

The exec is still refused, by the guest, with its Cedar decision:

```bash
kubectl -n cedar-policy-sample exec cedar-policy-demo -c main -- /bin/true
```

```text
error: Internal error occurred: Internal error occurred: error executing command in
container: failed to exec in container: failed to create exec "3ce2...b28c5": policy denied
Agent::Action::"Exec" on container "main" reasons=[] errors=[]
```

Kubernetes allowed the request; the guest denied the operation. The message names the exact
Cedar action, `Agent::Action::"Exec"`, so a generic exec failure (RBAC, a dead pod, a network
blip) cannot pass as policy enforcement. This is the whole point of the sample: the check runs
inside the guest, below the operator.

**Step 8: A changed spec, without a regenerated policy, is refused.** Change one pinned setting
in the workload, here the container's command, and apply it with the policy generated for the
original spec. The guest refuses to start the container, because it no longer matches the
admission policy:

```bash
# cedar-policy-changed carries the original policy annotation but a changed command.
kubectl -n cedar-policy-sample get pod cedar-policy-changed
kubectl -n cedar-policy-sample get pod cedar-policy-changed \
  -o jsonpath='{.status.containerStatuses[0].state.waiting.message}{"\n"}'
```

```text
NAME                   READY   STATUS               RESTARTS   AGE
cedar-policy-changed   0/1     RunContainerError    3          61s
failed to create containerd task: ... policy denied Agent::Action::"CreateContainer" on
container "main": []
```

The admission policy pins the process arguments, so a container with a different command is a
different container to the policy, and the guest denies `Agent::Action::"CreateContainer"`.
Regenerating the policy from the changed spec would let it start again. The policy and the
workload travel together: change one without the other and the pod does not run.

## How the network policy works

The workload makes no outbound connections, so its egress is denied in full. The pod runs under
`confidential-sandbox` with a network (it is not network-isolated), and a deny-all egress policy
selects it and allows nothing out.

Network policy enforcement is turned on once per cluster. EKS Auto Mode accepts network policies
without enforcing them until the `amazon-vpc-cni` ConfigMap in `kube-system` sets
`enable-network-policy-controller: "true"`
([`deploy/enable-network-policy.yaml`](deploy/enable-network-policy.yaml)). This affects the
whole cluster; pods that no policy selects are unaffected.

Here is the whole egress policy
([`deploy/egress-policy.yaml`](deploy/egress-policy.yaml)), without its header comment:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cedar-policy-deny-egress
  namespace: cedar-policy-sample
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: cedar-policy-demo
  policyTypes:
    - Egress
  egress: []
```

| Part | What it does |
|---|---|
| `podSelector` | Selects the workload pod by `app.kubernetes.io/name: cedar-policy-demo`. |
| `policyTypes: [Egress]` | Brings the pod's egress under policy. |
| `egress: []` | No egress rule, so nothing out is allowed. |

A standard Kubernetes `NetworkPolicy` with an empty egress rule set and `Egress` in
`policyTypes` is a deny-all: there are no addresses to allow, so no Auto Mode
`ApplicationNetworkPolicy` with `domainNames` is needed. The policy is enforced on the node,
outside the guest: the node's network policy agent attaches eBPF programs to the pod's
host-side interface, so a command inside the sandbox, even as root, could not change it. The
controller hands the policy to the nodes as a `PolicyEndpoint`:

```bash
kubectl -n cedar-policy-sample get networkpolicy,policyendpoints
```

```text
NAME                                                 POD-SELECTOR                               AGE
networkpolicy.networking.k8s.io/cedar-policy-deny-egress   app.kubernetes.io/name=cedar-policy-demo   4m

NAME                             AGE
cedar-policy-deny-egress-kttst   4m
```

This sample does not probe egress from inside the pod, because the generated policy refuses
exec: the guest denies `Agent::Action::"Exec"`, so there is no way to run a connection test in
the guest. The deny-all egress is the correct posture for a workload that makes no outbound
connections, and the `PolicyEndpoint` above shows the controller has handed it to the nodes.

## Good to know

- **This sample shows policy enforcement inside the guest only.** It makes no attestation and
  no key-release decision. The generator predicts the policy's PCR17 measurement, which an
  external verifier such as AWS KMS would check before releasing a secret, but this sample does
  not use it. The planned Confidential section's attested-decryption samples show that step.
- **The policy and the workload travel together.** The policy annotation is immutable on a
  running pod, so `setup.sh` recreates the pod to apply a regenerated policy. A pod left from an
  earlier run keeps enforcing the earlier policy.
- **A reduced profile on the preview guest.** The sample's profile pins the container
  admission fields and denies exec and stdin, but omits the fields the current preview guest
  schema does not define yet: the OCI-hardening attributes are not pinned, and encrypted
  ephemeral-layer enforcement is not required. Generate with the built-in `--profile
  confidential` to pin those too once the guest schema supports them; the exec and admission
  behaviour the sample shows holds either way.

## Clean up

Set the variables again in a new shell if needed, then remove the sample:

```bash
./scripts/clean.sh                   # delete the pod, the egress policy and the namespace
./scripts/clean.sh --keep-namespace  # delete the pod and egress policy, keep the namespace
```

`clean.sh` deletes the namespace only after confirming it carries this sample's managed-by
label, verifies each deletion, and exits non-zero if anything it was asked to remove is still
there. The sample creates no AWS resources, so there is nothing to delete in the account.
Network policy enforcement is cluster-wide; deleting the cluster removes it, or delete the
`amazon-vpc-cni` ConfigMap in `kube-system` if nothing else relies on it. To remove the cluster,
follow the [hello sandbox clean up](../../getting-started/hello-sandbox/README.md#clean-up).
