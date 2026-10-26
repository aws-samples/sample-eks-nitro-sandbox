# Roll out a SandboxTemplate change with Argo Rollouts

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run the [hello sandbox](../../getting-started/hello-sandbox/README.md)
sample first so you have a cluster with the runtime classes. This sample builds on
[warm pool](../../getting-started/warm-pool/README.md), whose `SandboxTemplate`,
`SandboxWarmPool` and `SandboxClaim` it uses and whose agent-sandbox install (step 1) it
needs. The commands below use files from this repository, so clone it if you have not
already, and run them from this sample's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/agent-sandbox/argo-rollouts
```

It also needs [Argo Rollouts](https://argo-rollouts.readthedocs.io/en/stable/) on the
cluster, which Step 1 has you install if it is not there already, and these on your machine:
`kubectl`, `jq` (1.6 or later), `docker` (the run below used 25.x) and the `aws` CLI (v2),
because the step plugin is built in a container and pushed to Amazon ECR in your own
account. You need no Go toolchain: the build runs inside `golang:1.26`. Beyond the cluster
the only AWS resource is one ECR repository holding a single small image. The pool holds two
warm pods for as long as the sample is up, and there is no model or API call anywhere in it.
These pods set no CPU or memory requests, so each guest gets a small default size.

## Overview

Patching a `SandboxTemplate` is not a rollout. The agent-sandbox controller uses the
template as it stands **at boot time**, so a patch changes what the *next* pod will be built
from and leaves every pod already warm in the pool exactly as it is. A `SandboxClaim` made
after the patch adopts one of those pre-booted pods, so it gets the **old** template. That
is the stale-adoption window, and it stays open until something replaces the warm pods.

This sample measures that window by value, closes it with a drain, and then drives the same
patch-then-drain progression from an Argo Rollouts canary timeline.

- **The hazard is read, not inferred.** The template carries a revision marker,
  `TEMPLATE_REVISION`, and the container writes it to a file at boot. After a patch with no
  drain the API template says `rev-2` while the claimed pod reports `rev-1`, from both the
  environment variable and the file it wrote when it booted. The page shows the two side by
  side.
- **The drain closes it.** The drain scales the pool to zero, waits for it to empty
  (counting a Terminating pod as still present), scales it back, and waits for the pool to
  be ready again with one consistent template hash at the new revision. A claim after that
  adopts a pod reporting `rev-2`.
- **There is a witness before anything claims a pod.** The agent-sandbox controller stamps
  `agents.x-k8s.io/sandbox-template-hash` on each pool sandbox, so you can read which
  template the warm pods came from without claiming one or exec'ing into it.
- **Argo Rollouts runs the drain as a canary step plugin.** Two `plugin` steps under
  `strategy.canary.steps` patch the template and then drain the pool, inside the controller
  process, with the controller's RBAC. If the rollout is aborted or terminated mid-drain,
  the plugin's `Abort` and `Terminate` put the pool's replica count back, so warm capacity
  is never stranded at zero.
- **Only the warm pods are sandboxes.** The Argo Rollouts controller and the step plugin are
  first-party software the cluster operator installed, so they stay ordinary pods. The warm
  pods run with `runtimeClassName: isolated-sandbox` and boot with
  `sandbox.amazonaws.com/network-isolated: "true"`, so they have no network to restrict and
  the sample ships no network policy.

*Figure 1: Rolling a SandboxTemplate change through a warm pool with Argo Rollouts. The controller stays an ordinary pod and runs the step plugin in-process; notice that patching the template and draining the pool are two separate steps, because the patch alone leaves the already-warm pods on the old revision.*

![Inside an AWS Cloud frame sits an Amazon EKS cluster. On the left of the cluster, a box labelled argo-rollouts controller pod, an ordinary pod with no runtimeClassName, holds the Argo Rollouts controller, which runs the step plugin in-process. Two arrows leave the controller. The first, labelled 1. patch the revision marker, goes up and to the right to a SandboxTemplate named rollout-agent. The second, labelled 3. drain and re-warm the pool, goes down and to the right to a SandboxWarmPool named rollout-agent-pool. From the SandboxTemplate, an arrow labelled warm pods boot from the template as it stands runs right and then down into a red Nitro sandbox pods frame, marked isolated-sandbox plus network-isolated, which holds three boxes each labelled warm pod. From the SandboxWarmPool, a short arrow labelled keeps replicas booted points right into that same frame. At the bottom left, a SandboxClaim made after the rollout sends a long arrow right and then up into one of the warm pods, labelled adopts a pre-booted pod, at the revision the pool last re-warmed at. A note below the figure says that patching the template alone does not reboot the pool, because pods already warm keep the revision they booted with, so a claim made after the patch can adopt a stale pod, and that the drain step replaces them and the warm pods have no network besides loopback.](images/figure-1-argo-rollouts.png)

## Versions

| Component | Pin |
|---|---|
| agent-sandbox controller ([kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)) | v1.0.6, as in [Warm pool](../../getting-started/warm-pool/README.md) |
| Argo Rollouts ([argoproj/argo-rollouts](https://github.com/argoproj/argo-rollouts)) | v1.10.1 |
| Step plugin build image | `public.ecr.aws/docker/library/golang:1.26` |
| Warm pod and marker container image | `public.ecr.aws/docker/library/busybox:1.36` |

The step plugin is built against the Argo Rollouts Go module at the same pin, v1.10.1, and
the compiled binary is deliberately not committed: the registration builds it and pushes it
to a repository your cluster can pull from.

## Files

| File | What it is |
|---|---|
| [`deploy/warm-pool.yaml`](deploy/warm-pool.yaml) | The sample's `SandboxTemplate` at `rev-1`, carrying the revision marker, and its `SandboxWarmPool` at two replicas. |
| [`deploy/ordinary-pod.yaml`](deploy/ordinary-pod.yaml) | The same container with no `runtimeClassName`, so each sandbox reading has something to be compared against. |
| [`deploy/rollout.yaml`](deploy/rollout.yaml) | The `Rollout`: a marker container to version, and the canary steps that patch the template and drain the pool. |
| [`deploy/step-plugin-config.yaml`](deploy/step-plugin-config.yaml) | The `stepPlugins` registration for the controller's `argo-rollouts-config` ConfigMap. |
| [`deploy/step-plugin-rbac.yaml`](deploy/step-plugin-rbac.yaml) | The `ClusterRole` and `ClusterRoleBinding` that let the controller act on the agent-sandbox CRDs. |
| [`plugin/main.go`](plugin/main.go) | The go-plugin server and the Argo Rollouts step-plugin handshake. |
| [`plugin/plugin.go`](plugin/plugin.go) | The `StepPlugin` itself: the template patch, the drain state machine, and `Abort`/`Terminate`. |
| [`plugin/Dockerfile`](plugin/Dockerfile) | Builds the plugin in a container, so the sample needs no Go toolchain on your machine. |
| [`scripts/register-step-plugin.sh`](scripts/register-step-plugin.sh) | Step 2: build, push and register the plugin on the controller. Defaults to a plan that changes nothing. |
| [`scripts/setup.sh`](scripts/setup.sh) | Step 3: check the shared installs, create the namespace, apply the template, the pool and the ordinary pod. |
| [`scripts/patch-template.sh`](scripts/patch-template.sh) | Step 4: patch the revision marker and nothing else, which opens the window. |
| [`scripts/claim.sh`](scripts/claim.sh) | Steps 5 and 7: claim a pod and read its revision by value. |
| [`scripts/drain-pool.sh`](scripts/drain-pool.sh) | Step 6: the drain, as a plain script, with no controller involved. |
| [`scripts/run-rollout.sh`](scripts/run-rollout.sh) | Steps 10 and 11: drive the same work from a `Rollout`, and abort mid-drain on purpose. |
| [`scripts/cleanup.sh`](scripts/cleanup.sh) | Remove the sample's objects, and optionally undo the registration. |
| [`scripts/common.sh`](scripts/common.sh) | The names, the pinned context, the readings and the guards the scripts share. |
| [`.env.example`](.env.example) | The local values the sample needs, with no values filled in. |

Copy the env file before you start, and set `KUBE_CONTEXT` to the cluster you mean. Every
script pins `--context` and `--namespace` from it, so a run never depends on the machine's
current context:

```bash
cp .env.example .env
```

## Step 1: Install Argo Rollouts, or reuse the install that is there

Argo Rollouts is a cluster-wide controller, and another workload on your cluster may already
depend on the version and the settings it has. The scripts therefore never install, upgrade
or reconfigure it. They check for it and stop with the command when it is missing:

```bash
kubectl create namespace argo-rollouts
kubectl -n argo-rollouts apply --server-side -f \
  https://github.com/argoproj/argo-rollouts/releases/download/v1.10.1/install.yaml
kubectl -n argo-rollouts rollout status deploy/argo-rollouts --timeout=180s
```

If Argo Rollouts already lives somewhere other than `argo-rollouts` on your cluster, set
`ARGO_NAMESPACE` in `.env` instead of installing a second copy. When the install is present
the scripts say so and move on, naming the image they found so you can see what you are
reusing:

```text
reusing the Argo Rollouts install in namespace argo-rollouts as it is (quay.io/argoproj/argo-rollouts:v1.10.1); this sample was built against Argo Rollouts v1.10.1
```

## Step 2: Register the step plugin on the controller

An Argo Rollouts step plugin is a [hashicorp go-plugin](https://github.com/hashicorp/go-plugin)
binary that the controller runs as a child process. The controller discovers it from the
`stepPlugins` key of its own `argo-rollouts-config` ConfigMap and loads it at start-up, so
registering a step plugin means changing the controller: its ConfigMap, a `ClusterRole` that
lets it act on the agent-sandbox CRDs, and an initContainer on its Deployment that stages the
binary.

**This step changes state the whole cluster shares.** That is why it is a step you run, not
something `setup.sh` does: the other scripts only ever read the registration and stop with
this command when it is missing. Run it on a cluster whose Argo Rollouts install is yours to
change. It defaults to a plan that changes nothing:

```bash
./scripts/register-step-plugin.sh
```

```text
context: sandbox-demo (pinned)   namespace: argo-rollouts-sample
reusing the Argo Rollouts install in namespace argo-rollouts as it is (quay.io/argoproj/argo-rollouts:v1.10.1); this sample was built against Argo Rollouts v1.10.1

PLAN. Nothing below has been done; run './scripts/register-step-plugin.sh apply' to do it.

  Argo Rollouts   namespace argo-rollouts, controller pod argo-rollouts-6bf59fc774-f7jpf on node <NODE_NAME> (amd64)
  registered now  <nothing>
  ECR repository  nitro-sample-argo-rollouts-stepplugin in us-west-2 (account <ACCOUNT_ID>), tagged ManagedBy=argo-rollouts
  plugin image    <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nitro-sample-argo-rollouts-stepplugin:v1.10.1

  1. create or adopt the ECR repository above
  2. docker build plugin/ for amd64 and push it
  3. read the built binary's sha256
  4. set data.stepPlugins on configmap argo-rollouts/argo-rollouts-config to register
       eks-nitro-sandbox/sandbox-template-patch
       eks-nitro-sandbox/sandbox-warmpool-drain
     (created when absent; otherwise ONLY this key is merged, other keys are left alone)
  5. apply clusterrole and clusterrolebinding argo-rollouts-sandbox-warmpool
  6. patch deployment argo-rollouts/argo-rollouts with an initContainer that stages the
     binary into an emptyDir at /plugins, and wait for it to roll out

  Steps 4, 5 and 6 CHANGE SHARED STATE: the controller's own ConfigMap, a cluster-scoped
  ClusterRole, and the controller's Deployment. The clean up removes the ClusterRole and
  ClusterRoleBinding; the page's clean up section has the commands to undo the ConfigMap key
  and the Deployment patch, and to remove Argo Rollouts if nothing else on the cluster uses it.
```

The account ID and the node name are replaced with placeholders above; your run prints your
own. Read the plan, then apply it:

```bash
./scripts/register-step-plugin.sh apply
```

```text
TODO: output from the fresh run
```

The registration refuses to write over an install that is not yours. If the ConfigMap
already registers step plugins that are not this sample's, or if the Deployment already sets
a different `securityContext.fsGroup` from the one staging the binary needs, it stops and
says what it found rather than changing a controller other workloads depend on. It merges
only the `stepPlugins` key, so another key such as `trafficRouterPlugins` is left alone, and
it patches the Deployment with a strategic merge so another initContainer or volume survives.

Here is the registration the ConfigMap receives. Both step names point at the same binary,
because the plugin dispatches on the step name it is called with:

```yaml
stepPlugins: |
  - name: eks-nitro-sandbox/sandbox-template-patch
    location: "file:///plugins/sandbox-warmpool-stepplugin"
    sha256: "__PLUGIN_SHA256__"
  - name: eks-nitro-sandbox/sandbox-warmpool-drain
    location: "file:///plugins/sandbox-warmpool-stepplugin"
    sha256: "__PLUGIN_SHA256__"
```

`__PLUGIN_SHA256__` is filled in by the registration from the binary it just built, and the
controller verifies that hash before it will load the plugin. The prefix before the slash is
required: Argo Rollouts validates a step-plugin name against
`^([a-zA-Z0-9\-]+)/([a-zA-Z0-9_\-.]+)$` and rejects a bare name. It is an opaque string the
controller never resolves, so it is **not** a Kubernetes namespace and it does not change
when you override `NAMESPACE`.

The `ClusterRole` is the other half. The plugin runs inside the controller process, so it
acts with the controller's ServiceAccount, which by default has no access to the
agent-sandbox CRDs at all:

```yaml
rules:
  - apiGroups: ["extensions.agents.x-k8s.io"]
    resources: ["sandboxwarmpools", "sandboxtemplates"]
    verbs: ["get", "list", "watch", "patch", "update"]
  - apiGroups: ["agents.x-k8s.io"]
    resources: ["sandboxes"]
    verbs: ["get", "list", "watch"]
```

`SandboxWarmPool` and `SandboxTemplate` are in the `extensions.agents.x-k8s.io` group and the
plugin writes to both, so they carry `patch` and `update`. `Sandbox` objects are in the core
`agents.x-k8s.io` group and the plugin only counts them and reads their hash label, so there
is no write verb for them.

## Step 3: Set up the sample

This creates the sample's own namespace, labelled so the other scripts can tell it is the
sample's, and applies the `SandboxTemplate` at `rev-1`, the `SandboxWarmPool` at two
replicas, and the ordinary pod the sandbox readings are compared against. Nothing here
touches the controller.

```bash
./scripts/setup.sh
```

```text
context: sandbox-demo (pinned)   namespace: argo-rollouts-sample

== 1/4 namespace argo-rollouts-sample ==
namespace/argo-rollouts-sample created
namespace/argo-rollouts-sample labeled
created namespace argo-rollouts-sample, labelled app.kubernetes.io/managed-by=argo-rollouts

== 2/4 apply the SandboxTemplate at rev-1 and the SandboxWarmPool ==
sandboxtemplate.extensions.agents.x-k8s.io/rollout-agent created
sandboxwarmpool.extensions.agents.x-k8s.io/rollout-agent-pool created

== 3/4 apply the ordinary pod the sandbox readings are compared with ==
pod/ordinary-pod created

== 4/4 wait for the pool to be warm at one template revision ==
  readyReplicas=0/2  distinct template hashes=1
NAME                 READY   DESIRED   AGE
rollout-agent-pool   2       2         13s

the SandboxTemplate says TEMPLATE_REVISION=rev-1
the pool's sandboxes carry agents.x-k8s.io/sandbox-template-hash:
  cbed2ff8
```

The pool is warm at `rev-1`, and its two sandboxes agree on one template hash, `cbed2ff8`.
Here is the part of [`deploy/warm-pool.yaml`](deploy/warm-pool.yaml) that matters, the
revision marker and the two annotations:

```yaml
spec:
  podTemplate:
    metadata:
      annotations:
        sandbox.amazonaws.com/network-isolated: "true"
        karpenter.sh/do-not-disrupt: "true"
    spec:
      runtimeClassName: isolated-sandbox
      automountServiceAccountToken: false
      containers:
        - name: agent
          image: public.ecr.aws/docker/library/busybox:1.36
          env:
            - name: TEMPLATE_REVISION
              value: "rev-1"
          command:
            - sh
            - -c
            - |
              printf %s "$TEMPLATE_REVISION" > /tmp/template-revision
              echo "booted TEMPLATE_REVISION=$TEMPLATE_REVISION"
              exec sleep infinity
```

The marker is written to a file once, at boot. That is what makes it provenance rather than
a current reading: the file records the value this pod started with, and no later patch to
the template can change it. `karpenter.sh/do-not-disrupt` is there because a warm pod sits
Ready and idle; nothing would reschedule it if consolidation removed the node under it, and
the pool's revisions would then change for reasons that have nothing to do with the rollout.
The pool asks for two replicas, not one, so "every pool pod carries the same template hash"
is a reading that could actually fail.

## Step 4: Patch the template, and watch nothing happen to the pool

This is the deploy on its own. It changes the revision marker on the `SandboxTemplate` and
touches nothing else.

```bash
./scripts/patch-template.sh rev-2
```

```text
context: sandbox-demo (pinned)   namespace: argo-rollouts-sample
sandboxtemplate/rollout-agent: TEMPLATE_REVISION rev-1 -> rev-2

The pool has NOT been rebooted. Its sandboxes still carry:
  booted at rev-1
  template hash cbed2ff8

Claim a pod now and it adopts one of those:  ./scripts/claim.sh stale
```

The template now says `rev-2`. The pool still holds the two pods it booted from `rev-1`, at
the same hash `cbed2ff8` it had before the patch. This is the stale-adoption window, and it
is open right now. Note that you can see it without claiming anything or exec'ing into
anything: the hash label on the pool's sandboxes is a Kubernetes-observable witness.

## Step 5: Claim a pod, and read the stale revision by value

```bash
./scripts/claim.sh stale
```

```text
context: sandbox-demo (pinned)   namespace: argo-rollouts-sample

  the SandboxTemplate now says          : TEMPLATE_REVISION=rev-2
  the claim adopted pod                 : rollout-agent-pool-55d92
  that pod's TEMPLATE_REVISION (env)    : rev-1
  /tmp/template-revision (at boot)      : rev-1
  agents.x-k8s.io/launch-type           : warm

STALE: the template says rev-2, and the adopted pod booted from rev-1.
A claim made now still gets a pod from the old template, because patching a
SandboxTemplate does not reboot the pool. ./scripts/drain-pool.sh closes this.
```

There is the hazard, by value and side by side. The API template says `rev-2`. The pod the
claim adopted reports `rev-1` twice: once from the live environment variable, and once from
the file it wrote when it booted. `launch-type: warm` says it was adopted from the pool
rather than cold-started for this claim, which is why it carries the old template at all.

The script reads both in-guest values and requires them to be present and equal to each
other before it compares either with the template, so an exec that failed can never make a
stale pod look fresh.

## Step 6: Drain the pool to close the window

The drain is what a template patch does not do. It reads the pool's `spec.replicas`, patches
it to zero, waits until no sandbox matches the pool's selector, patches the count back, and
waits until the pool is ready again with one consistent template hash at the revision the
template now holds.

```bash
./scripts/drain-pool.sh
```

```text
context: sandbox-demo (pinned)   namespace: argo-rollouts-sample
[drain] the SandboxTemplate says TEMPLATE_REVISION=rev-2
[drain] the pool selects sandboxes with agents.x-k8s.io/warm-pool-sandbox=fc450e7f
[drain] the pool's sandboxes booted at: rev-1, rev-2 (want rev-2), so a drain is needed
[drain] pre-drain template hashes: 5e642565, cbed2ff8
[drain] spec.replicas=2 (will scale to 0, then back to 2)
[drain] patched spec.replicas=0; waiting for the pool to empty (timeout 300s)
[drain] the pool is empty: 0 sandboxes match the pool selector
[drain] patched spec.replicas=2; waiting for the pool to re-warm at rev-2 (timeout 600s)
  readyReplicas=0/2  distinct hashes=1  revisions=rev-2
[drain] the pool has re-warmed: readyReplicas=2, all sandboxes at TEMPLATE_REVISION=rev-2
[drain] template hash: 5e642565, cbed2ff8 -> 5e642565
```

Look at the third line. By the time the drain ran, the pool held **both** revisions:
`rev-1` and `rev-2`. That is the claim in Step 5 refilling the pool. The claim took a
`rev-1` pod out, and the pool booted its replacement from the template as it stood then,
which was already `rev-2`. So a pool in the stale window does not serve uniformly stale
pods, it serves a mixture, and which one a given claim gets depends on which pod the
controller hands it. That is worse than a clean failure, because it is intermittent.

After the drain the pool is at one hash, `5e642565`, and every sandbox reports `rev-2`. The
witness reads the same way straight from the API:

```bash
kubectl -n argo-rollouts-sample get sandbox -l agents.x-k8s.io/warm-pool-sandbox=fc450e7f \
  -L agents.x-k8s.io/sandbox-template-hash
```

```text
NAME                       READY   REASON              AGE     SANDBOX-TEMPLATE-HASH
rollout-agent-pool-qmb49   True    DependenciesReady   2m52s   5e642565
rollout-agent-pool-w7cxz   True    DependenciesReady   2m24s   5e642565
```

The selector hash `fc450e7f` is the pool's own, from its `status.selector`. Read it from
there rather than assuming it is the pool name: the scripts do, and an unreadable selector
is treated as "not ready" and never as "matches nothing", because an empty selector passed
to `kubectl get -l` would match every sandbox in the namespace and an empty result would
then read as a drained pool.

The drain waits on the revision as well as the hash. Waiting on `readyReplicas` alone would
pass while a replacement was still coming up, and waiting on one consistent hash alone would
be satisfied by a pool that is uniformly on the *old* template, which is the state the drain
exists to leave behind.

## Step 7: Claim again, and read the new revision

```bash
./scripts/claim.sh fresh
```

```text
context: sandbox-demo (pinned)   namespace: argo-rollouts-sample

  the SandboxTemplate now says          : TEMPLATE_REVISION=rev-2
  the claim adopted pod                 : rollout-agent-pool-n4987
  that pod's TEMPLATE_REVISION (env)    : rev-2
  /tmp/template-revision (at boot)      : rev-2
  agents.x-k8s.io/launch-type           : warm

CURRENT: the adopted pod booted from the revision the template now holds (rev-2).
```

Still `launch-type: warm`, so this claim was still adopted from the pool and still got the
sub-second path. It is the same mechanism as Step 5, with the window closed.

## Step 8: The drain is a safe no-op when the pool is already current

Running the drain again must not throw away warm capacity for nothing. It checks the pool
before it scales anything, by reading the revision each pool sandbox actually booted with
rather than comparing hashes it would have to have remembered:

```bash
./scripts/drain-pool.sh
```

```text
context: sandbox-demo (pinned)   namespace: argo-rollouts-sample
[drain] the SandboxTemplate says TEMPLATE_REVISION=rev-2
[drain] the pool selects sandboxes with agents.x-k8s.io/warm-pool-sandbox=fc450e7f
[drain] every pool sandbox already booted at TEMPLATE_REVISION=rev-2; nothing to drain
  template hash: 5e642565
```

That is the same action proved both ways: Step 6 ran it on a pool that needed draining and
it drained, and Step 8 ran it on a pool that did not and it changed nothing. A pool with no
sandboxes at all counts as *not* current, because the re-warm half of the drain still has
work to do.

## Step 9: The claimed pod really ran in a Nitro sandbox

The pool's pods are the only part of this sample in a sandbox, so it is worth reading that
off the running pod rather than trusting the manifest. Each reading is next to the same
reading from [`deploy/ordinary-pod.yaml`](deploy/ordinary-pod.yaml), which is the same
container with the single line `runtimeClassName: isolated-sandbox` left out.

```bash
kubectl -n argo-rollouts-sample exec rollout-agent-pool-n4987 -- sh -c \
  'uname -rv; cat /proc/uptime; ls /sys/block; cat /sys/class/dmi/id/product_name'
kubectl -n argo-rollouts-sample exec ordinary-pod -- sh -c \
  'uname -rv; cat /proc/uptime; ls /sys/block; cat /sys/class/dmi/id/product_name'
```

| Reading | Claimed sandbox pod | Ordinary pod on the same cluster |
|---|---|---|
| `uname -rv` | `6.18.54 #1 SMP PREEMPT_DYNAMIC Thu Oct 22 17:38:11 UTC 2026` | `6.18.54 #2 SMP PREEMPT_DYNAMIC Thu Oct 22 00:16:59 UTC 2026` |
| `cat /proc/uptime` | `65.05 61.37` | `42618.04 338641.00` |
| `ls /sys/block` | `dm-0 vda vdb vdc` | `dm-0 nvme0n1 nvme1n1 zram0` |
| `cat /sys/class/dmi/id/product_name` | `m8i.enclave` | `m8a.2xlarge` |

The kernel **version** is the same, 6.18.54, which is exactly why `uname -r` on its own is
not evidence. The **build** is not: `#1` built at 17:38 against `#2` built at 00:16. The
uptime is 65 seconds, which is the age of the pod, because the VM booted with it; the
ordinary pod reports the node's 42618 seconds. The block devices are virtio disks, `vda`
through `vdc`, where the ordinary pod sees the instance's NVMe devices. And the DMI product
name reads the VM in the sandbox rather than the EC2 instance type the ordinary pod reads.

## No network to restrict

The warm pods boot with one annotation:

```yaml
metadata:
  annotations:
    sandbox.amazonaws.com/network-isolated: "true"
```

The guest then comes up with only loopback: no route out and no DNS. This sample ships no
network policy, because a pod with no network interface gives a policy nothing to allow or
deny. For a sandbox that does have a network, and how to restrict where it can reach, see
the [network policy](../../isolation/network-policy/README.md) sample.

Rather than assert the isolation, here it is read from the claimed pod, with the ordinary
pod beside it:

```bash
kubectl -n argo-rollouts-sample exec rollout-agent-pool-n4987 -- sh -c 'ip -o addr; ip route'
kubectl -n argo-rollouts-sample exec rollout-agent-pool-n4987 -- nslookup example.com
```

```text
1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever preferred_lft forever
1: lo    inet6 ::1/128 scope host noprefixroute \       valid_lft forever preferred_lft forever

nslookup: can't connect to remote host (8.8.8.8): Network is unreachable
command terminated with exit code 1
```

`ip -o addr` lists only `lo`, `ip route` prints nothing at all, and a lookup fails with
"Network is unreachable". The ordinary pod, for contrast, has an `eth0` with a VPC address
and a default route:

```text
1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever preferred_lft forever
3: eth0    inet 192.168.127.129/32 scope global eth0\       valid_lft forever preferred_lft forever

default via 169.254.1.1 dev eth0
169.254.1.1 dev eth0 scope link
```

`kubectl exec`, `cp` and `logs` keep working on the network-isolated pod throughout, because
they use the guest's internal control channel rather than the network. That is how every
in-guest reading on this page was taken.

## Step 10: Drive the same work from a Rollout

Everything above used plain scripts, so you could see the mechanism without a controller in
the way. This step runs the same two operations as canary steps of an Argo Rollouts
`Rollout`.

```bash
./scripts/run-rollout.sh rev-3
```

```text
TODO: output from the fresh run
```

Here are the canary steps from [`deploy/rollout.yaml`](deploy/rollout.yaml):

```yaml
  strategy:
    canary:
      steps:
        - plugin:
            name: eks-nitro-sandbox/sandbox-template-patch
            config:
              namespace: __NAMESPACE__
              template: rollout-agent
              revision: __REVISION__
        - pause:
            duration: 30s
        - plugin:
            name: eks-nitro-sandbox/sandbox-warmpool-drain
            config:
              namespace: __NAMESPACE__
              pool: rollout-agent-pool
              waitForNewTemplateHash: true
              timeoutSeconds: 600
        - setWeight: 100
```

| Step | What it does |
|---|---|
| `sandbox-template-patch` | Writes the new revision onto the `SandboxTemplate`. On its own this *is* the hazard: it opens exactly the window Step 4 opened by hand. |
| `pause: 30s` | Holds, so the window is long enough to observe rather than being passed through too fast to read. |
| `sandbox-warmpool-drain` | Drains and re-warms the pool. `waitForNewTemplateHash: true` makes it wait for the pool's sandboxes to carry the hash of the patched template, not merely for `readyReplicas` to come back. |
| `setWeight: 100` | Finishes the canary. It moves the marker Deployment's own pods and nothing else. |

The drain step is written as a non-blocking state machine rather than a long blocking call.
Each invocation advances one phase and returns `Running` with a requeue, so the controller's
RPC is never held open for the length of a pool reboot, and the phase and the replica count
to restore are persisted in the step's own status between calls.

### What the Argo Rollouts documentation does not cover

Three things on this page are this sample's own design, not something the Argo Rollouts
documentation describes, and it is worth being explicit about which:

- **Step plugins driving agent-sandbox CRDs.** The plugin interface is documented; using it
  to patch a `SandboxTemplate` and drive a `SandboxWarmPool` is not. The `ClusterRole` in
  Step 2 exists only because of it.
- **The marker-container bridge.** A `Rollout` progresses a Deployment-shaped workload. It
  does not watch a `SandboxTemplate` or a `SandboxWarmPool` and has no concept of warm
  capacity. So this sample's `Rollout` runs one small marker container whose
  `TEMPLATE_REVISION` is the value a CI system bumps, purely to give Argo Rollouts something
  to version, and the plugin steps do the real work. The marker pod holds no warm capacity
  and nothing claims it.
- **`setWeight` does not apply to a warm pool.** Progressive traffic weighting assumes two
  versions running side by side with traffic split between them. A warm pool has one active
  template, so there is nothing to split. This sample claims no progressive weighting: the
  progression it shows is patch, then drain.

One more behaviour worth knowing, because it decides how the script drives the rollout: Argo
Rollouts **skips the canary steps the first time a `Rollout` is created**, because there is
no previous revision to progress away from. So `run-rollout.sh` seeds the `Rollout` at the
revision the template already holds, which makes that skip a no-op, and only then bumps it.
Without the seed the plugin steps would never run at all.

## Step 11: Abort mid-drain, and keep the warm capacity

A drain scales the pool to zero on its way. If a rollout is aborted in that window, the
worst outcome is not a stale pool, it is a pool stuck at zero replicas, which serves no
claims at all. The plugin's `Abort` and `Terminate` exist for that, and this step aborts a
rollout on purpose to show it.

```bash
./scripts/run-rollout.sh rev-4 --abort-during-drain
```

```text
TODO: output from the fresh run
```

The script polls the pool's `spec.replicas` and aborts only once it has actually observed
zero, so the abort really does land inside the window rather than before or after it. If the
drain finishes faster than the poll, the script says so and stops rather than reporting a
test it did not run.

The plugin covers the other way a drain can stop, too. A step that *fails* does not get
`Abort` or `Terminate` called on it, so a drain that times out restores the replica count
itself before returning failure.

## Good to know

- **A template patch is not a rollout, and the pool is not a Deployment.** A
  `SandboxWarmPool` has no surge, no `maxUnavailable` and no rolling update. The only way to
  move warm pods to a new template is to replace them, which means a window with less warm
  capacity than usual. The drain takes the pool to zero for the length of one pod boot; if
  that matters for your workload, drain in batches rather than all at once.
- **The stale window serves a mixture, not a uniformly old pool.** As Step 6 showed, each
  claim during the window takes a pod out and the pool refills from the current template, so
  the pool drifts to a mix of revisions. Intermittent staleness is harder to notice than
  total staleness, which is the argument for closing the window rather than tolerating it.
- **The template hash moves with the whole blueprint.** The agent-sandbox controller computes
  `agents.x-k8s.io/sandbox-template-hash` over the template's `SandboxBlueprint`, of which
  `podTemplate` is one field, so any change to the template moves it, not only a change to
  the revision marker. Do not read a hash change as "the marker changed".
- **The hash label is readable only before a claim adopts the pod.** When a `SandboxClaim`
  adopts a sandbox, the controller takes the pool's labels off it, both
  `warm-pool-sandbox` and `sandbox-template-hash`, and adds a claim reference instead. So
  read the hash witness from the pool, which is what Step 4 and Step 6 do, and read the
  in-guest marker from the claimed pod.
- **The plugin runs with the controller's permissions, not the pod's.** A step plugin is
  loaded into the Argo Rollouts controller process, so it acts with the controller's
  ServiceAccount cluster-wide. That is a real grant: the `ClusterRole` in Step 2 lets the
  controller patch `SandboxTemplate` and `SandboxWarmPool` objects in **every** namespace,
  not just this sample's. Scope it to a Role in one namespace if that is too broad for you.
- **The warm pods hold no API credential.** The template sets
  `automountServiceAccountToken: false`. A pod built from a `SandboxTemplate` has that
  defaulted to false already, so the line says out loud what the pod relies on rather than
  changing it: a warm pod runs untrusted code and has no reason to hold a token for the
  cluster it runs on.
- **A warm pod costs whatever it reserves, for as long as it is booted.** These pods set no
  requests, so each guest gets a small default size, but a real template sizes its pods for
  the workload and a sandbox reserves its full memory request up front.
- **The compiled plugin binary is not in this repository.** It is built in a container and
  pushed to your own ECR repository, so the binary the controller loads is one you built and
  whose hash you registered.

## Clean up

Set the variables again if you are in a new shell. By default the clean up removes only the
sample's own objects and leaves the shared Argo Rollouts install, its ConfigMap key and the
ECR repository in place, printing what stays:

```bash
cp .env.example .env    # if you have not already; set KUBE_CONTEXT and NAMESPACE
./scripts/cleanup.sh
```

```text
TODO: output from the fresh run
```

To undo the registration as well, in an order that cannot break the controller, add
`--unregister`. It takes the initContainer off the Deployment first, then removes the
`stepPlugins` key, and only then deletes the ECR repository: deleting the repository while
the controller still names its image would stop the controller starting the next time it
restarted, which would break it for every workload on the cluster rather than just this
sample.

```bash
./scripts/cleanup.sh --unregister
```

The block below is from the run that reset this cluster before the fresh run on this page,
so it is real output taken at a different point in the session rather than from the final
clean up above:

```text
context: sandbox-demo (pinned)   namespace: argo-rollouts-sample

== 1/3 the sample's namespace argo-rollouts-sample ==
  deleting the warm pool first, so it stops booting replacements
sandboxwarmpool.extensions.agents.x-k8s.io "rollout-agent-pool" deleted from argo-rollouts-sample namespace
  deleting the namespace and everything in it
namespace "argo-rollouts-sample" deleted
  deleted namespace argo-rollouts-sample

== 2/3 the ClusterRole and ClusterRoleBinding ==
clusterrolebinding.rbac.authorization.k8s.io "argo-rollouts-sandbox-warmpool" deleted
  deleted clusterrolebinding/argo-rollouts-sandbox-warmpool
clusterrole.rbac.authorization.k8s.io "argo-rollouts-sandbox-warmpool" deleted
  deleted clusterrole/argo-rollouts-sandbox-warmpool

== 3/3 the registration on the Argo Rollouts controller ==
  took the initContainer and the /plugins volume off deployment argo-rollouts
deployment "argo-rollouts" successfully rolled out
  removed the stepPlugins key from configmap argo-rollouts-config
  deleted ECR repository nitro-sample-argo-rollouts-stepplugin

  Still installed, because other workloads on the cluster may use it:
    - Argo Rollouts in namespace argo-rollouts
    - the agent-sandbox controller
  If nothing else on this cluster uses Argo Rollouts, remove it with:
    kubectl -n argo-rollouts delete -f \
      https://github.com/argoproj/argo-rollouts/releases/download/v1.10.1/install.yaml
    kubectl delete namespace argo-rollouts

clean up complete.
```

The clean up checks the namespace carries the sample's label before it deletes anything
inside it, deletes the pool first so it stops booting replacements, and checks the sample's
label on each cluster-scoped object before removing it. It removes the `stepPlugins` key
only when that key holds exactly this sample's two entries, and the ECR repository only when
it carries this sample's `ManagedBy` tag. A lookup that fails means "could not determine",
which it reports as a failure rather than as "gone", and the script exits non-zero when it
skipped something, so an incomplete clean up is never reported as done.

**What stays.** Two shared installs, because another workload on the cluster may rely on
either:

- **Argo Rollouts.** Remove it only if nothing else uses it. Check first, across the whole
  cluster, and only then uninstall:

  ```bash
  kubectl get rollout,analysisrun,experiment -A
  # all empty? then:
  kubectl -n argo-rollouts delete -f \
    https://github.com/argoproj/argo-rollouts/releases/download/v1.10.1/install.yaml
  kubectl delete namespace argo-rollouts
  ```

  Anything listed there is another workload's, so leave Argo Rollouts where it is.
- **The agent-sandbox controller**, shared with the warm pool sample and the other
  agent-sandbox samples. To remove it, follow the
  [warm pool clean up](../../getting-started/warm-pool/README.md#clean-up).

If this is the only sample you ran, follow the
[hello sandbox clean up](../../getting-started/hello-sandbox/README.md#clean-up) to remove
the namespace and the cluster.
