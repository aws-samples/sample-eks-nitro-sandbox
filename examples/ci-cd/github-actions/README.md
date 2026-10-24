# GitHub Actions runners, each job in its own sandbox

A pull request from a fork runs code you have not read on hardware you own. The job
usually needs a Docker daemon, and on a shared self-hosted runner that daemon is either
privileged on the node, where a malicious `Dockerfile` or test gets at the other jobs and
the node's credentials, or crippled, so continuous integration cannot build anything.

This sample removes that choice. It runs the official
[GitHub Actions Runner Controller](https://docs.github.com/en/actions/concepts/runners/actions-runner-controller)
(ARC) on Amazon EKS so that every ephemeral runner pod ARC creates for a queued job is its
own sandbox, with its own kernel, and is deleted when the job ends. A workflow that stands
in for an untrusted pull request, a privileged `docker build` plus a unit-test run, runs
contained to that one pod. The controller and its listener stay ordinary pods: only the
untrusted work is in a sandbox.

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run these samples first, which this one builds on:

- [Getting started > Hello sandbox](../../getting-started/hello-sandbox/README.md): the
  one-line opt-in, and how a pod shows that it ran in a sandbox.
- [Getting started > Coding agent](../../getting-started/coding-agent/README.md): turning
  on network policy enforcement once per cluster, an `ApplicationNetworkPolicy` with host
  names, and a GitHub credential held in a Secret created from a file.
- CI/CD > docker-builds, at `examples/ci-cd/docker-builds/`: that a privileged
  `docker build` and `docker run` are safe inside a sandbox without exposing the node.
  Here a real continuous integration system schedules that build for you, triggered by code
  you do not trust.

The commands below use files from this repository, so clone it if you have not already, and
run them from this sample's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/ci-cd/github-actions
```

For this sample you also need [Helm](https://helm.sh/docs/intro/install/) 3.8 or later, which
installs the two ARC charts from an OCI registry, and [`jq`](https://jqlang.github.io/jq/),
which the scripts use to read Helm's JSON. You also need two things of your own: a
**test repository** you own and can afford to run untrusted-shaped jobs in, and a
**least-privilege GitHub credential** for it. Both are described in Step 2.

There is no model cost. The controller and listener are small ordinary pods that run
continuously; a sandboxed runner pod exists only while a job runs. The only cost beyond the
cluster is the outbound data the job's image pulls use, over the cluster's existing egress.

## Overview

**Only the runner pods are sandboxed.** ARC's controller reconciles custom resources and
its listener holds one outbound connection to GitHub. Both are trusted, both stay ordinary
pods. The one thing that runs code from a pull request, the ephemeral runner pod, is the one
thing that gets a sandbox.

**One sandbox per queued job, and nothing between jobs.** With `minRunners: 0` no runner pod
exists until a job is queued. ARC creates one fresh pod for the job, runs it, and deletes it
when the job finishes. The next job gets a new pod with a new pod UID, so no build cache,
no checkout and no leaked credential carries from one job to the next.

**The privileged daemon is privileged only inside the guest.** `containerMode: dind` puts a
`docker:dind` sidecar in the runner's own pod. Because the runner and its Docker daemon
share one pod, the single `runtimeClassName` line covers both, and a `docker build` that
gets root does so inside the pod's own kernel.

**The credential never reaches the runner.** The GitHub credential is used by the controller
and the listener to register runners just in time. The runner pod is given no GitHub admin
credential and no AWS role, and the page checks both by variable name.

*Figure 1: The GitHub Actions service outside AWS; inside an Amazon EKS cluster, the ARC
controller and listener as ordinary pods in `arc-systems`, and one per-job sandbox pod in
`arc-runners` holding the runner and its privileged `docker:dind` sidecar, with an egress
policy on the pod and the shared EC2 node untouched beneath it.*

![Outside the AWS Cloud, the GitHub Actions service at github.com. Inside the AWS Cloud, an Amazon EKS cluster contains two namespaces. The namespace arc-systems holds the ARC controller and the listener, both drawn as ordinary pods; the listener makes a single outbound long-poll HTTPS connection to the GitHub Actions service, and nothing accepts an inbound connection. The namespace arc-runners holds a GitHub credential Secret, read only by the controller and the listener, and one per-job pod drawn as a sandbox labelled runtimeClassName isolated-sandbox, created one per queued job and deleted when the job ends. Inside that sandbox pod are two containers side by side, the runner container and a docker:dind sidecar marked privileged inside the guest only, connected over a Docker socket. An egress network policy on the sandbox pod restricts its outbound traffic to the GitHub Actions hosts and the base-image registry. A dashed line from the credential Secret to the runner pod is crossed out, showing the credential does not reach it. Beneath the cluster, the shared EC2 node carries the pods but is untouched by the job.](images/architecture.png)

## Versions

This folder was built against these releases. Pin each to its latest when you build.

| Component | Version |
|---|---|
| [`gha-runner-scale-set-controller`](https://github.com/actions/actions-runner-controller/releases) chart | 0.15.1 |
| [`gha-runner-scale-set`](https://github.com/actions/actions-runner-controller/releases) chart | 0.15.1, the same as the controller |
| [`ghcr.io/actions/actions-runner`](https://github.com/actions/runner/releases) | the chart's own default tag, `latest` |
| `docker:dind` sidecar | owned by the chart through `containerMode: dind` |

Both charts must be on the same version: the controller refuses a runner scale set built by
a different one, and `scripts/setup.sh` stops if they disagree.

The runner image tracks the chart's default rather than a pinned tag on purpose. GitHub
stops queuing jobs to a runner more than 30 days behind a release, and its broker refuses a
deprecated runner outright (Amazon EKS clusters are not special here; the same happens on an
ordinary runner). A pinned older tag therefore turns into a broken sample a month later. If
you need a reproducible tag, pin it and plan to move it at least monthly.

This sample installs no agent-sandbox resources. The runner pods are sandboxes because of
one `runtimeClassName` line in the chart's `template.spec`, not because of a
`SandboxTemplate` or a warm pool.

## Files

| File | What it is |
|---|---|
| [`deploy/runner-scale-set-values.yaml`](deploy/runner-scale-set-values.yaml) | The runner scale set's Helm values: the `runtimeClassName`, `containerMode: dind`, and the runner container's size |
| [`deploy/egress-policy.yaml`](deploy/egress-policy.yaml) | The runner pods' egress `ApplicationNetworkPolicy` |
| [`deploy/ordinary-pod.yaml`](deploy/ordinary-pod.yaml) | An ordinary pod, for the comparison in Step 6 only |
| [`workflow/untrusted-pr-workflow.yaml`](workflow/untrusted-pr-workflow.yaml) | The untrusted-shaped workflow to copy into your test repository |
| [`scripts/setup.sh`](scripts/setup.sh) | Creates the namespace, the credential Secret, the egress policy and the runner scale set |
| [`scripts/clean.sh`](scripts/clean.sh) | Removes what this sample created, and says what stays |
| [`.env.example`](.env.example) | The local values the sample needs; copy to `.env`, which git ignores |

## Quick start

```bash
# 1. the shared ARC controller, once per cluster (see Step 1)
helm install arc oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --version 0.15.1 --namespace arc-systems --create-namespace

# 2. your test repository and credential
cp .env.example .env && $EDITOR .env

# 3. the credential Secret, the egress policy and the runner scale set
./scripts/setup.sh

# 4. copy the workflow into your test repository, commit and push, then run it
#    from the repository's Actions tab, and watch the sandbox appear and go
kubectl get pods -n arc-runners -w
```

## Steps

**Step 1: Install the ARC controller, once per cluster.** The controller and the four ARC
custom resource definitions are shared by everything on the cluster that uses ARC: one
controller watches every namespace, and each definition holds every team's objects of that
kind. This sample therefore never installs, upgrades or reconfigures them. If ARC is already
on your cluster, skip this step and set `ARC_VERSION` in `.env` to the version that is
installed. If it is not, install it yourself at the version this sample pins:

```bash
helm install arc oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --version 0.15.1 --namespace arc-systems --create-namespace
```

```text
TODO: output from the fresh run
```

The controller goes in `arc-systems` and the runners in `arc-runners`, in a later step.
Keeping them apart is GitHub's documented practice in the
[ARC quickstart](https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/quickstart):
the controller is trusted, the runners are not.

**Step 2: Supply a test repository and a least-privilege credential.** Copy `.env.example`
to `.env`, which git ignores, and fill in your cluster name, your test repository URL and
one credential. Use a repository you own and are willing to run untrusted-shaped jobs in,
not one that matters.

A **GitHub App** is the least-privilege choice and rotates its own tokens. For a
repository-scoped runner set it needs **Administration: read and write** and
**Metadata: read-only**; for an organization-scoped set it needs **Self-hosted runners:
read and write** instead of Administration. Install it on the one test repository, not on
every repository in the account. A **fine-grained personal access token** whose repository
access is only that one repository, with the same two permissions, works too. Either way,
the credential goes in a file of its own and only its path goes in `.env`:

```bash
# a token, in a file by itself, with no trailing newline and nothing else in it
printf '%s' 'github_pat_...' > ~/.github-arc-token
chmod 600 ~/.github-arc-token
```

`scripts/setup.sh` builds a Kubernetes Secret from that file with
`kubectl create secret generic --from-file`, so the credential is never an argument to a
command, never in your shell history and never visible to another process in `ps`. The Helm
values reference the Secret by name, so it is not in the release's values either:

```yaml
githubConfigSecret: __GITHUB_SECRET_NAME__   # a NAME, never an inline token
```

Authenticating ARC to GitHub, and the practice of referencing a Secret rather than inlining
a credential, are described in
[authenticating ARC to the GitHub API](https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/authenticate-to-the-api).

**Step 3: Create the runner scale set.** `scripts/setup.sh` checks the cluster before it
changes anything: the `isolated-sandbox` RuntimeClass is present, network policy enforcement
is on, and the ARC controller is installed at the pinned version. It stops with the command
to run if any of those is not true. Then it creates the `arc-runners` namespace and labels
it `ManagedBy=github-actions`, creates the credential Secret, applies the egress policy and
waits for its `PolicyEndpoint`, and installs the runner scale set.

```bash
./scripts/setup.sh
```

```text
TODO: output from the fresh run
```

The listener pod is the thing to watch for. It runs in `arc-systems`, not with the runners,
and its readiness is what "registered with GitHub" means. It holds a single outbound
long-poll HTTPS connection and creates no runner pods until a job is queued, so this sample
needs no Ingress, no LoadBalancer and no NodePort: nothing accepts an inbound connection.

**Step 4: Only the runner pods carry the runtime class.** The `gha-runner-scale-set` chart
exposes `template.spec`, an ordinary Kubernetes PodSpec. That is where this sample sets the
runtime class, so every ephemeral runner pod boots as a sandbox:

```yaml
template:
  spec:
    runtimeClassName: isolated-sandbox
    nodeSelector:
      kubernetes.io/arch: amd64
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:latest
        command: ["/home/runner/run.sh"]
        resources:
          requests: { cpu: "1", memory: "2Gi" }
          limits:   { cpu: "1", memory: "2Gi" }
```

Most samples here set no CPU or memory requests. This one does, for two reasons: a real
`docker build` needs more memory than the default sandbox size, and equal requests and
limits give the pod Guaranteed quality of service, so one queued job takes exactly one
sandbox of a known size. Change them to suit your own builds.

Ask the Kubernetes API what each pod actually asked for. The controller and the listener
report no runtime class; the runner pod template reports `isolated-sandbox`:

```bash
kubectl get pods -n arc-systems \
  -o custom-columns='POD:.metadata.name,RUNTIME CLASS:.spec.runtimeClassName'
kubectl get autoscalingrunnerset -n arc-runners \
  -o jsonpath='{.items[0].spec.template.spec.runtimeClassName}{"\n"}'
```

```text
TODO: output from the fresh run
```

In `dind` container mode the chart renders the `docker:dind` sidecar itself and ignores any
container you name `dind` in `template.spec`, so its storage driver and volumes cannot be
set through these values. The chart's default, `overlay2` on an `emptyDir` inside the guest,
builds and runs images in the sandbox, so this sample mounts no
`/etc/docker/daemon.json`. If a future guest cannot run `overlay2`, the fallback is to mount
one setting `storage-driver: vfs`.

**Step 5: Queue a job and watch one sandbox appear, then go.** Copy the workflow into your
test repository, commit and push it, then run it from the repository's Actions tab. Its
`runs-on` matches the runner scale set's release name, so a run makes ARC create one pod:

```bash
cp workflow/untrusted-pr-workflow.yaml <your-clone>/.github/workflows/
```

Watch the namespace before, during and after the run:

```bash
kubectl get pods -n arc-runners -w
```

```text
TODO: output from the fresh run
```

Nothing is running before the job is queued, one pod appears for it, and the pod is gone
when the job finishes. Run the workflow a second time and the new pod has a different pod
UID, which is how you can tell it is a fresh pod and not a reused one:

```bash
kubectl get pods -n arc-runners \
  -o custom-columns='POD:.metadata.name,UID:.metadata.uid,RUNTIME CLASS:.spec.runtimeClassName,NODE:.spec.nodeName'
```

```text
TODO: output from the fresh run
```

**Step 6: Read the job's own account of the machine it ran on.** The workflow's first step
prints three readings. Take them from the job log in the Actions tab:

```text
TODO: output from the fresh run
```

Now the same three readings from an ordinary pod on the same node. Fill the runner pod's
node into the comparison pod and apply it:

```bash
NODE=$(kubectl get pods -n arc-runners -o jsonpath='{.items[0].spec.nodeName}')
sed "s|<NODE_NAME>|$NODE|" deploy/ordinary-pod.yaml | kubectl apply -n arc-runners -f -
kubectl wait --for=condition=Ready pod/ordinary-comparison -n arc-runners --timeout=120s
kubectl exec -n arc-runners ordinary-comparison -- \
  sh -c 'uname -rv; cut -d" " -f1 /proc/uptime; ls /sys/block | tr "\n" " "; echo'
```

```text
TODO: output from the fresh run
```

The runner pod runs its own kernel build, its uptime matches the pod's age because the
sandbox booted with the pod, and it sees virtio disks where the ordinary pod sees the
instance's `nvme` devices. Note that the kernel **version** can be the same in both: it is
the build and the boot that differ, so compare `uname -rv` and not `uname -r`.

Remove the comparison pod when you are done with it, by its exact name:

```bash
kubectl delete pod ordinary-comparison -n arc-runners
```

**Step 7: The privileged build and the arbitrary test code both complete.** The workflow does
the two things that make continuous integration dangerous, on purpose. It builds an
attacker-shaped `Dockerfile`, which needs a real Docker daemon, and it runs unit tests,
which is arbitrary code execution. Both run on the job's own in-pod daemon:

```yaml
- name: Untrusted docker build
  run: |
    docker build -t untrusted-pr:ci .
    docker run --rm untrusted-pr:ci
    echo "DOCKER-BUILD-CONFIRMED"
```

```text
TODO: output from the fresh run
```

The runner image ships no `pip`, so the tests run in a throwaway container on that same
daemon, which is also how untrusted test code should be run. The test file goes in on
standard input because a bind mount would resolve against the dind daemon's filesystem
rather than the runner container's.

**Step 8: No credential reached the runner pod.** Runners register just in time, so the
admin credential stays with the controller and the listener. The workflow prints variable
names, never values, and the same can be read from the live pod's spec:

```bash
kubectl get pods -n arc-runners -o jsonpath='{.items[0].spec.containers[*].env[*].name}{"\n"}'
kubectl get pods -n arc-runners -o jsonpath='{.items[0].spec.volumes[*].name}{"\n"}'
```

```text
TODO: output from the fresh run
```

No `github_token`, `github_app_private_key` or `AWS_` variable is present, and the credential
Secret is not among the pod's volumes. The runner pods are also given no EKS Pod Identity
association, so there is no AWS role to assume: the build pulls its public base images
anonymously. The chart gives the runner pod a ServiceAccount with no permissions of its own.

**Step 9: The escape probes, and what they are worth.** The workflow's last step tries to
reach the node's instance-metadata credentials, list the node's `nvme` devices and open the
node's container runtime socket, and fails the job if any of them succeeds.

```text
TODO: output from the fresh run
```

Be clear about what this does and does not establish. On EKS a plain namespaced pod already
cannot reach any of those three, so an ordinary runner passes these probes too. They are
worth running because they fail closed, so a future regression that did expose the node
would break the job rather than pass quietly, but they do not by themselves show that the
job ran in a sandbox. The load-bearing evidence for that is Step 6: the pod's own kernel
build, its own boot and its virtio disks.

## How the network policy works

Every ephemeral runner pod ARC creates carries the label
`actions-ephemeral-runner: "True"`, so one policy covers every per-job pod without naming
any of them. Here is the whole file, as it is in the folder, with `<COREDNS_IP>` filled in
by `scripts/setup.sh` from your cluster's CoreDNS Service address:

```yaml
apiVersion: networking.k8s.aws/v1alpha1
kind: ApplicationNetworkPolicy
metadata:
  name: github-actions-runner-egress
  labels:
    ManagedBy: github-actions
spec:
  podSelector:
    matchLabels:
      actions-ephemeral-runner: "True"
  policyTypes:
    - Ingress
    - Egress
  ingress: []
  egress:
    - to:
        - ipBlock: { cidr: <COREDNS_IP>/32 }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to:
        - domainNames:
            - github.com                             # register the runner, fetch the job
            - api.github.com                         # the Actions API
            - "*.actions.githubusercontent.com"      # the Actions broker and job service
            - codeload.github.com                    # download the actions a workflow uses
            - ghcr.io                                # GitHub container registry
            - "*.pkg.github.com"                     # GitHub Packages
            - pkg-containers.githubusercontent.com   # container layer downloads
            - public.ecr.aws                         # base images this sample's build pulls
            - "*.cloudfront.net"
      ports:
        - { protocol: TCP, port: 443 }
```

| In the YAML | What it does |
|---|---|
| `podSelector` on `actions-ephemeral-runner: "True"` | Selects every ephemeral runner pod ARC creates, present and future, and nothing else |
| `policyTypes: [Ingress, Egress]` | Both directions are governed, so anything not allowed below is refused |
| `ingress: []` | Nothing reaches a runner pod. The job is driven by the runner's own outbound long poll, so no inbound connection is ever needed |
| `ipBlock: <COREDNS_IP>/32` on 53 | Name lookups, to the cluster's CoreDNS Service only, not to any other resolver |
| `github.com`, `api.github.com`, `*.actions.githubusercontent.com` | What a self-hosted runner needs to register, collect a job and report back, from GitHub's list in the [self-hosted runners reference](https://docs.github.com/en/actions/reference/self-hosted-runners-reference) |
| `codeload.github.com` | Downloads the actions a workflow refers to |
| `ghcr.io`, `*.pkg.github.com`, `pkg-containers.githubusercontent.com` | Container and package pulls from GitHub, on the same reference list |
| `public.ecr.aws` and `*.cloudfront.net` | The base images this sample's `docker build` pulls. Amazon ECR Public answers a layer download with a redirect to CloudFront at a generated host name, so the pull needs both |
| no rule for `169.254.170.23` | The runner pods have no EKS Pod Identity association and need no AWS credential. A policy for a pod that does have a role needs that rule, or its credential requests time out |

Enforcement is turned on once per cluster with the `amazon-vpc-cni` ConfigMap in
`kube-system`, which `scripts/setup.sh` checks and stops without. It is enforced on the
node, outside the guest: the node's network policy agent attaches to the pod's host-side
interface, so a command in the runner, even as root, cannot change it. `setup.sh` waits for
the policy's `PolicyEndpoint` before you queue a job, because that is how the controller
says it has handed the policy to the nodes.

Its limits are worth stating plainly. A `domainNames` rule allows the addresses a name
resolves to, so another name served from the same addresses is reachable too; `*.cloudfront.net`
is the widest entry here, and it allows every host served from CloudFront, not only Amazon
ECR Public. Kubernetes always allows traffic between a pod and its own node, which is not a
path to the internet. GitHub notes its host list can change, so re-check it against the
self-hosted runners reference when you build.

The workflow asks the policy both ways, from inside the runner, so a pass cannot be confused
with a policy that allows everything:

```yaml
- name: Egress policy, both ways
  run: |
    for url in https://api.github.com https://example.com https://registry-1.docker.io; do
      curl -sS -o /dev/null --connect-timeout 8 "$url" 2>/dev/null
      echo "$url -> exit $?"
    done
```

```text
TODO: output from the fresh run
```

`curl` exits 0 when it connects and 28 when the connection times out. A refusal has two
shapes, and both mean the same thing: a name that publishes only IPv4 addresses times out,
while a name that also publishes IPv6 addresses can fail at once with "Network is
unreachable". Neither is a broken cluster.

## Optional: a genuine fork pull request

The bundled workflow is untrusted-shaped rather than genuinely untrusted: it writes its own
`Dockerfile` and tests inline instead of checking out pull-request contents, so a run is
self-contained and the same every time. The property it shows, a privileged build plus
arbitrary code contained to a per-job sandbox, is the same either way.

To run real pull-request code, the workflow already has a `pull_request` trigger. Turn on
your repository's setting for running workflows from fork pull requests, open a pull request
from a fork, and add a checkout step. Everything on this page holds unchanged: the job still
gets one fresh sandbox, the credential still stays out of it, and the egress policy still
applies. What changes is that the code in the sandbox is now genuinely someone else's, which
is the case this sample exists for.

## Good to know

- **The controller and the CRDs are shared, so this sample does not own them.** One
  controller watches every namespace, and deleting an ARC custom resource definition deletes
  every team's objects of that kind. `scripts/setup.sh` checks for the controller and stops
  with the command rather than installing it, and `scripts/clean.sh` never removes it.
- **Both charts must be on one version.** The controller refuses a runner scale set built by
  a different version, which shows up as a scale set that never produces a listener.
- **A pinned older runner image breaks the sample, not just the version number.** GitHub's
  broker refuses a deprecated runner, the runner exits, and ARC reads that exit as "outdated"
  and tears down the listener, which leaves the queued job with nowhere to go. This is not
  specific to sandboxes: an ordinary runner pinned to the same old tag fails the same way.
- **`maxRunners` is the cap on concurrent sandboxes.** This sample sets 2. Each runner pod
  reserves its full memory request up front, so plan node capacity by reservation rather than
  by average use.
- **The `dind` sidecar is the chart's, not yours.** In `dind` container mode the chart
  ignores a container you name `dind` in `template.spec`, so you cannot change its storage
  driver, arguments or volumes through the values.
- **`kubectl exec` into a runner pod still works**, because the sandbox's control channel is
  not the network. That is useful when a job fails, and it is also why a job's own output is
  not the only way to inspect a run.
- **The escape probes are not the proof.** They are necessary but not sufficient: an ordinary
  namespaced pod passes them too. Step 6's kernel build, boot and virtio disks are what show
  the job ran in a sandbox.

## Clean up

Set the variables again if you are in a new shell, then remove what the sample created:

```bash
cd sample-eks-nitro-sandbox/examples/ci-cd/github-actions
./scripts/clean.sh
```

```text
TODO: output from the fresh run
```

`clean.sh` uninstalls the runner scale set first, because that is what creates runner pods,
waits for any in-flight runner pod to go, then deletes the egress policy, the credential
Secret and the `arc-runners` namespace. It only touches a namespace labelled
`ManagedBy=github-actions`, and a lookup that fails counts as "could not determine" rather
than "already gone", so anything it could not delete or confirm is named at the end and
makes it exit non-zero.

It leaves the ARC controller and the four ARC CRDs, and prints the commands to remove them,
because they are shared cluster-wide and this sample did not install them. If you installed
them only for this sample, check that nothing else uses ARC first:

```bash
kubectl get autoscalingrunnersets -A
```

Network policy enforcement is a cluster-wide setting and also stays. Two things outside the
cluster are yours to remove: the workflow file in your test repository, and the credential
you created on GitHub, which should be revoked or uninstalled rather than left to expire.

To remove the namespace the Getting started samples created, and the cluster itself, follow
the [Hello sandbox clean up](../../getting-started/hello-sandbox/README.md#clean-up).
