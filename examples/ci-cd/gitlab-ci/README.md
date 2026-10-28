# GitLab CI jobs, each in its own sandbox

A continuous integration system runs whatever is in the repository. On a self-hosted runner
that is your hardware, and the job that needs a Docker daemon is the hardest case: either the
daemon is privileged on the node, where a `Dockerfile` or a test can reach the other jobs and
the node's credentials, or it is not privileged and the build cannot be done at all.

This sample takes that choice away for a whole GitLab, not for one hand-written pod. A
self-hosted GitLab runs in the cluster, a GitLab Runner with the Kubernetes executor runs
beside it as an ordinary pod, and **one line in the runner's `config.toml` puts every job pod
it creates in a Nitro sandbox**. A pipeline with two jobs then runs: an ordinary job, and a
privileged `docker build` that starts its own Docker daemon, builds a multi-stage image and
runs it. Both land in their own sandbox, with their own kernel. No pipeline has to know.

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and these samples, which this one builds on:

- [Getting started > Hello sandbox](../../getting-started/hello-sandbox/README.md): the
  one-line opt-in, and how a pod shows that it ran in a sandbox.
- [CI/CD > Docker builds](../docker-builds/README.md): that a privileged `docker build` and
  `docker run` are contained to one sandbox. Here a real CI system schedules that build.
- [CI/CD > GitHub Actions runners](../github-actions/README.md): the same shape on the other
  forge, with the controller as an ordinary pod and one sandbox per queued job.

The commands below use files from this repository, so clone it if you have not already, and
run them from this sample's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/ci-cd/gitlab-ci
```

Besides `kubectl`, the scripts need [`jq`](https://jqlang.github.io/jq/) to read pod JSON,
`openssl` to generate GitLab's initial root password, and `base64` and `awk`, which carry
values into GitLab and the token into the rendered `config.toml` without putting either on a
command line. The clean up also uses the AWS CLI, to confirm that the EBS volume behind
GitLab's data went with its claim. They run on `bash`, version 4 or later, for the associative
arrays `scripts/run-pipeline.sh` keeps the job pods in. The run on this page used `kubectl`
v1.35.0, `jq` 1.8.1, AWS CLI 2.38.0, OpenSSL 3.5.8 and `bash` 5.2.15.

You need no GitLab account and no GitLab.com project: the GitLab this sample talks to is the
one it installs, and the runner's authentication token is minted from it.

Every output block on this page is from one run of this sample, after `scripts/clean.sh` had
removed the previous one, so the run started with none of its resources present. Local names
in that output are replaced by the placeholders the commands use, because this repository is
public: `<CLUSTER_NAME>` for the kube context and `<NODE_NAME>` for an EC2 instance id. Pod
names, pod UIDs, kernel builds, uptimes, device lists and timings are as the run printed
them.

There is no model or API cost. While the sample is up, one GitLab pod and its EBS volume run
on the general-purpose pool; each pipeline run holds sandbox capacity for the length of its
jobs, and the build pulls its base images over the cluster's existing egress.

## Overview

**Every job pod is a sandbox, and one line decides it.**
`runtime_class_name = "isolated-sandbox"` in the Kubernetes executor block of the runner's
`config.toml` sets the RuntimeClass on every pod the runner creates for a job. A pipeline
committed before the runner was ever configured is isolated too, because the decision is the
runner's and not the pipeline's.

**The runner manager stays an ordinary pod.** It is the long-lived component: it holds the
runner authentication token, polls GitLab, and creates and deletes job pods through the
Kubernetes API. It runs no pipeline code, so it is not what needs isolating, and its pod spec
carries no `runtimeClassName`. Step 6 reads that back off the running pod.

**One sandbox per job, and nothing between jobs.** A job pod is created when its job starts
and deleted when the job ends. The two jobs in the pipeline get two pods with two different
pod UIDs, so no checkout, build cache or leftover credential carries from one to the next.

**The privileged daemon is privileged over the pod's own kernel.** `privileged = true` in the
same block is what lets the build job's `docker:dind` container start. That container is in
the job pod, so the sandbox's single `runtimeClassName` covers it: the daemon it runs is root
inside a kernel that belongs to the job pod. The node never has a privileged daemon on it.

**Nothing is exposed outside the cluster.** GitLab is a ClusterIP Service, reached from your
own machine with `kubectl port-forward`. There is no Ingress, LoadBalancer or NodePort
anywhere in this folder.

**What this sample does not limit.** It ships no network policy, so a job pod, which has a
network, reaches what any pod on the cluster reaches, including the internet. The boundary
this sample creates is the sandbox's: the job's containers run in a lightweight VM with a
kernel of their own, so a container escape inside a job reaches that kernel and not the
node's. To restrict where a job pod can connect, see the
[network policy](../../isolation/network-policy/README.md) sample. The sample creates no IAM
role and no EKS Pod Identity association, so a job pod has no role to assume in your account
and this page claims no limit from one.

*Figure 1: Only the job pods are sandboxes. GitLab and the runner manager stay ordinary pods
in `gitlab-ci-demo`, the manager creates one sandbox pod per CI job, and the runner
authentication token stays with the manager.*

![Outside AWS sits the operator's machine, which reaches the cluster only with kubectl port-forward on 8080, and its arrow in is labelled the only way in. Inside the AWS Cloud, an Amazon EKS cluster holds the namespace gitlab-ci-demo. Along the top of that namespace are the long-lived ordinary pods: a ClusterIP Service gitlab, which the operator's arrow reaches and which selects pod gitlab, GitLab CE in one container, and pod gitlab mounts an Amazon EBS volume holding 30Gi of GitLab data. To their right, a Kubernetes Secret holding the runner token has an arrow labelled mounted by the manager running to pod gitlab-runner, the runner manager, which has no runtime class. An arrow from the runner manager down into the namespace is labelled one pod per CI job. Below sit two Nitro sandbox pods framed in red, each carrying runtimeClassName isolated-sandbox and the note one per CI job, deleted when the job ends. The first holds the sandbox-evidence container, the ordinary job. The second holds the docker-build build container beside a docker:dind container that is privileged in the guest. An arrow from each sandbox pod runs back to the Service gitlab, labelled clone and report status, because a job pod uses the in-cluster Service address, and an arrow from each runs out to Amazon ECR Public for base images, labelled pull base images. Below both sandbox pods, inside the cluster, is the shared EC2 node, whose kernel is never the job pod's. A note under the figure says that the sandbox is the boundary: the Docker daemon the docker-build job starts is privileged over its own job pod's guest kernel, never over the shared node's, the runner authentication token stays in the manager and no job pod mounts the Secret, and GitLab has no Ingress, LoadBalancer or NodePort, so the only way in is kubectl port-forward.](images/architecture.png)

The two sandbox pods are side by side in the figure because that is what the runner does with
them, one per job. In this pipeline the two jobs are in two stages, so they run one after the
other, and the two pods overlap only while the first is being deleted.

## Versions

This folder was built against these releases. Pin each to its latest when you build, and
check the executor settings and the token workflow against the GitLab documentation for the
version you pin.

| Component | Version | Why this one |
|---|---|---|
| [`gitlab/gitlab-ce`](https://hub.docker.com/r/gitlab/gitlab-ce) | `19.5.0-ce.0` | The single-container image: git, Postgres, Redis, Sidekiq and the web app in one pod, so nothing needs an Ingress or a LoadBalancer to come up |
| [`gitlab/gitlab-runner`](https://hub.docker.com/r/gitlab/gitlab-runner) | `v19.5.0` | The manager. No release older than **v17.5.3**: `runtime_class_name` is what this sample rests on, and an older runner would ignore it and run the job as an ordinary pod |
| [`docker:29.9.2-dind`](https://gallery.ecr.aws/docker/library/docker) and `29.9.2-cli` | `29.9.2` | The build job's daemon and its client, from Amazon ECR Public rather than Docker Hub, so a run is not subject to Docker Hub's pull limits |
| [`alpine`](https://gallery.ecr.aws/docker/library/alpine) | `3.24.3` | The ordinary job's image, and the comparison pod's |
| [`golang`](https://gallery.ecr.aws/docker/library/golang) | `1.27.2-alpine3.24` | The first stage of the image the build job builds |

The runner's helper image is left at the runner's own default for its version, which is the
matching `gitlab-runner-helper` tag. It is amd64, so `node_selector` keeps the job pods on
amd64 nodes.

This sample installs no agent-sandbox resources. The job pods are sandboxes because of one
line of runner configuration, not because of a `SandboxTemplate` or a warm pool.

## Files

| File | What it is |
|---|---|
| [`deploy/gitlab.yaml`](deploy/gitlab.yaml) | GitLab: the Deployment, its ClusterIP Service and its volume |
| [`deploy/runner.yaml`](deploy/runner.yaml) | The runner manager: ServiceAccount, namespaced Role and RoleBinding, Deployment |
| [`deploy/ordinary-pod.yaml`](deploy/ordinary-pod.yaml) | An ordinary pod, for the comparison in Step 4 only |
| [`runner/config.toml.template`](runner/config.toml.template) | The runner configuration, and where this sample happens |
| [`pipeline/.gitlab-ci.yml`](pipeline/.gitlab-ci.yml) | The pipeline: an ordinary job and a privileged `docker build` job |
| [`pipeline/ci/Dockerfile`](pipeline/ci/Dockerfile), [`pipeline/ci/main.go`](pipeline/ci/main.go), [`pipeline/ci/go.mod`](pipeline/ci/go.mod) | The multi-stage build context the privileged job builds |
| [`scripts/setup.sh`](scripts/setup.sh) | The namespace and the self-hosted GitLab |
| [`scripts/bootstrap-runner.sh`](scripts/bootstrap-runner.sh) | The project, the runner authentication token, and the runner manager |
| [`scripts/run-pipeline.sh`](scripts/run-pipeline.sh) | Starts a pipeline, records the job pods while they exist, prints the logs |
| [`scripts/clean.sh`](scripts/clean.sh) | Removes everything the sample created, and confirms it is gone |
| [`scripts/common.sh`](scripts/common.sh) | Shared by the four: `.env`, the pinned context, the namespace check |
| [`.env.example`](.env.example) | The local values the sample needs; copy to `.env`, which git ignores |

## Quick start

```bash
cp .env.example .env && $EDITOR .env    # KUBE_CONTEXT and NAMESPACE
./scripts/setup.sh                      # the namespace and GitLab (several minutes)
./scripts/bootstrap-runner.sh           # the project, the runner token, the runner manager
./scripts/run-pipeline.sh               # a pipeline, its job pods, and its logs
./scripts/clean.sh                      # when you are done
```

The steps below are those four, with what each one does and what it printed.

## Step 1: Install the self-hosted GitLab

`scripts/setup.sh` creates the namespace, generates GitLab's initial root password into a
Secret, and applies the GitLab Deployment, its ClusterIP Service and a 30Gi claim for its
data. It changes nothing cluster-wide and creates no AWS resource: the only thing that
reaches your account is the EBS volume the CSI driver provisions for that claim, which
belongs to the claim.

The namespace is created only when it is absent, and is labelled `ManagedBy=gitlab-ci`. A
namespace of that name that exists without the label is refused, because on a shared cluster
it is someone else's. Every later script checks that one label before it writes anything, and
the clean up checks it before it deletes anything.

**This sample installs nothing shared, and needs no controller or operator.** Unlike the
GitHub Actions sample, which needs one Actions Runner Controller for the whole cluster, GitLab
Runner with the Kubernetes executor is a plain Deployment with a namespaced `Role`: both
GitLab and the runner manager are this sample's own objects, in this sample's own namespace.
The one shared thing it relies on is the cluster's EBS CSI driver, which EKS Auto Mode
provides, and it is used exactly as it is: the script chooses a class, never creates or
changes one.

The StorageClass is chosen here and never changed. With `STORAGE_CLASS` unset the script
takes the cluster's default class and checks its provisioner is the EKS Auto Mode EBS CSI
driver; it never creates a class and never applies over one, because a StorageClass is
cluster-scoped and applying over the default class can take its default annotation away,
which changes how every other claim on the cluster is provisioned.

```bash
cp .env.example .env && $EDITOR .env
./scripts/setup.sh
```

```text
TODO: output from the fresh run
```

GitLab's own readiness endpoint is what the wait is on, not just a running container: the
single-container image migrates its database and starts Postgres, Redis, Gitaly, Sidekiq,
Puma and nginx on a first boot, and `kubectl get pods` shows `Running` for several minutes
before any of that is usable.

To look at it yourself, forward the Service to your own machine. Nothing is published outside
the cluster, so this is the only way in:

```bash
kubectl --context <CLUSTER_NAME> -n gitlab-ci-demo port-forward svc/gitlab 8080:8080
kubectl --context <CLUSTER_NAME> -n gitlab-ci-demo get secret gitlab-root \
  -o go-template='{{index .data "password" | base64decode}}{{"\n"}}'
```

Then open `http://localhost:8080` and sign in as `root`. GitLab's `external_url` is set to
`http://localhost:8080` so that the links on its own pages point back at your forwarded port.
The runner and the job pods do not use `external_url`: they are given the in-cluster Service
address instead, which is the next step.

## Step 2: Create the project, mint the runner's token, and start the runner manager

`scripts/bootstrap-runner.sh` does four things against the GitLab from Step 1: it creates a
project, commits the pipeline to it, mints a project runner authentication token, and starts
the runner manager with that token.

Everything it asks GitLab to do, it sends to GitLab's own administration console on standard
input, so nothing it sends is ever an argument to a command. A reader who would rather click
can do all of it in the UI from Step 1: create a project, add the files from `pipeline/`,
then **Settings > CI/CD > Runners > New project runner**, and paste the `glrt-` token into
`runner/config.toml.template` yourself.

The pipeline files are committed with `[ci skip]` in the commit message, so that commit starts
no pipeline. Step 3 starts one, once there is a runner online to take it, which is what makes
the run on this page one you can watch from the beginning.

```bash
./scripts/bootstrap-runner.sh
```

```text
TODO: output from the fresh run
```

The token is a **runner authentication token**: GitLab gives it the `glrt-` prefix, and it
replaced the registration tokens that had no prefix and are scheduled for removal. It never
appears on a command line, in the pod spec, or on this page. It leaves GitLab on standard
output, goes into a file in a private temporary directory, and reaches the Secret through
`kubectl create secret --from-file`. The script prints the prefix and refuses to go on if the
value it got does not start with `glrt-`.

`create`, not `apply`, is what writes that Secret. A client-side apply copies the whole
object, token and all, into a `kubectl.kubernetes.io/last-applied-configuration` annotation,
and `kubectl describe secret` prints annotations even though it hides `data`.

### The two lines that are the whole sample

Here is the part of [`runner/config.toml.template`](runner/config.toml.template) that matters.
The script renders `<GITLAB_URL>`, `<NAMESPACE>` and `<RUNNER_TOKEN>` into it before storing
it in the Secret:

```toml
[[runners]]
  name = "nitro-sandbox-runner"
  url = "<GITLAB_URL>"
  token = "<RUNNER_TOKEN>"
  executor = "kubernetes"
  clone_url = "<GITLAB_URL>"

  [runners.kubernetes]
    namespace = "<NAMESPACE>"

    # Every job pod this runner creates gets this RuntimeClass, so every CI job in every
    # pipeline runs in its own Nitro sandbox. No .gitlab-ci.yml changes.
    runtime_class_name = "isolated-sandbox"

    # Lets the build job start its own Docker daemon. The daemon is privileged over the
    # sandbox's kernel, which belongs to the job pod, and not over the node's.
    privileged = true
```

`clone_url` is there because a job pod is inside the cluster: without it the runner hands the
job GitLab's `external_url`, which is the port-forward on your own machine, and the clone
fails. `url` and `clone_url` both point at
`http://gitlab.gitlab-ci-demo.svc.cluster.local:8080`.

The sizes are in the same block, and unlike most pods on this site these job pods do set
requests:

```toml
    cpu_request = "1"
    cpu_limit = "1"
    memory_request = "2Gi"
    memory_limit = "2Gi"
    helper_cpu_request = "250m"
    helper_cpu_limit = "500m"
    helper_memory_request = "512Mi"
    helper_memory_limit = "512Mi"
    service_cpu_request = "1"
    service_cpu_limit = "1"
    service_memory_request = "2Gi"
    service_memory_limit = "2Gi"
```

A sandbox is sized when it boots and cannot be resized in place (Amazon EKS User Guide,
*Isolated and confidential pods limitations*, In-place resource resize), so a job pod has to
ask for what the job needs up front. With no request at all the VM gets the small default
size, and a job that unpacks a toolchain is killed for running out of memory with no log line
to say so. These are this sample's values for this pipeline, not a platform minimum.

A job pod's VM is sized from the whole pod's requests, so the build job's sandbox is the sum
of its build, helper and service containers: 2.25 CPU and 4.5Gi, plus the RuntimeClass's own
overhead. The ordinary job has no service container, so its sandbox is smaller.

## Step 3: Run the pipeline, and watch the job pods while they exist

`scripts/run-pipeline.sh` starts a pipeline on the project's default branch, which is what
GitLab's own **Run pipeline** button does, and then polls the namespace for job pods. That
polling is the only chance to see them: the runner creates a job pod when its job starts and
deletes it when the job ends, so a `kubectl get pods` afterwards finds nothing.

The script records each pod's name, UID, runtime class and node as it appears, and it refuses
the run if any job pod turned out not to carry `runtimeClassName: isolated-sandbox`, because
that would mean the job had run as an ordinary pod on the node.

```bash
./scripts/run-pipeline.sh
```

```text
TODO: output from the fresh run
```

Two pods, two UIDs, both `isolated-sandbox`. The first job needed no privileges at all and
was isolated anyway.

## Step 4: What a job pod sees, next to what an ordinary pod on the same node sees

The first job is an ordinary CI job. Its script reads the three things that tell a pod running
in a Nitro sandbox apart from any pod on the node, and
[`pipeline/.gitlab-ci.yml`](pipeline/.gitlab-ci.yml) is where it does so:

```yaml
sandbox-evidence:
  stage: evidence
  image: public.ecr.aws/docker/library/alpine:3.24.3
  script:
    - echo "pod $(hostname), job $CI_JOB_ID of pipeline $CI_PIPELINE_ID"
    - echo "--- its own kernel (an ordinary pod reports the node's) ---"
    - uname -rv
    - echo "--- its own boot (matches this pod's age, not the node's uptime) ---"
    - cut -d' ' -f1 /proc/uptime
    - echo "--- virtio disks (an ordinary pod sees the instance's nvme devices) ---"
    - ls /sys/block
```

This is what that job printed:

```text
TODO: output from the fresh run
```

And this is what an ordinary pod, on the same node, printed for the same readings. The script
creates it on the node a job pod ran on, reads it, and deletes it by its exact name:

```text
TODO: output from the fresh run
```

The kernel **version** can be the same on both sides, so the version string is not the
evidence. What is: the kernel **build** differs, the job pod's uptime is its own age rather
than the node's, and the job pod's disks are `vd*` virtio devices where the ordinary pod sees
the instance's `nvme*` disks. The product name is a fourth reading in the same direction: the
job pod reads the VM in its sandbox, the ordinary pod reads the EC2 instance type.

The job also prints `id`, and the UID that prints is worth being exact about. It is the UID of
the **job script's own process, in the build container of the job pod**, which is UID 0
because this sample sets no `securityContext` and the job's image runs as root. That says
nothing about any other container of the pod, each of which has its own image and its own
`USER`. Both job pods are scheduled on a shared EC2 node, and that root is root inside the
pod's own guest kernel.

The two job pods do not have to land on the same node, and in this run they did not. The
script creates the comparison pod on the node the first job pod it saw was scheduled on, and
names that node in its output, so the two readings being compared come from one machine.

## Step 5: The privileged `docker build`, contained to the job's own sandbox

The second job is the case that forces the choice this sample removes. It gets a Docker
daemon of its own as a service container in the same job pod, builds a two-stage image and
runs it:

```yaml
docker-build:
  stage: build
  image: public.ecr.aws/docker/library/docker:29.9.2-cli
  services:
    - name: public.ecr.aws/docker/library/docker:29.9.2-dind
      alias: docker
  variables:
    DOCKER_HOST: tcp://localhost:2375
    DOCKER_TLS_CERTDIR: ""
  script:
    - docker build -t hello-nitro:$CI_PIPELINE_ID .
    - docker run --rm hello-nitro:$CI_PIPELINE_ID
```

Nothing in that job asks for a sandbox or for privilege. `privileged = true` in the runner's
configuration is what lets the daemon run, and the runner's `runtime_class_name` is what puts
the whole pod, daemon included, in a sandbox. Because the daemon and its client are containers
of the same pod, they are in the same guest: `DOCKER_HOST` is plain TCP on the pod's own
loopback, inside the VM, and nothing outside the pod can reach that port.

**`privileged` is a runner setting, not a per-job one, and the run shows that.** The pod table
in Step 3 prints every container of every job pod with its `privileged` flag, and the ordinary
job's containers carry it too, because one `privileged = true` in `[runners.kubernetes]`
applies to every pod this runner creates. Only the build job uses it. That is worth knowing
rather than glossing: the privilege is bounded by each pod's own sandbox, so a job that does
not need it cannot reach past its own guest kernel either way, but it is more than that job
asks for. To hand privilege only to the daemon, the Kubernetes executor has
`allowed_privileged_images` and `allowed_privileged_services`, and a second runner with
`privileged = false` and its own tag is the other way; check both against the GitLab Runner
documentation for the version you pin. This sample keeps the single setting, because the
sandbox is what it is about.

This is the build job's log:

```text
TODO: output from the fresh run
```

The readings at the top of that log are the second pod's, and they differ from the first
job's: a different boot, because it is a different VM. The daemon reports the guest's kernel,
not the node's. The last `docker run` is a container started by that daemon, nested inside the
job pod's sandbox, and it still sees the same guest kernel and the same virtio disks.

## Step 6: The runner manager is an ordinary pod

Only the job pods are sandboxes. The manager holds the token and talks to the Kubernetes API,
so it is the component you would least want running pipeline code, and it does not:

```bash
kubectl --context <CLUSTER_NAME> -n gitlab-ci-demo get pod \
  -l app=gitlab-runner \
  -o custom-columns='POD:.metadata.name,RUNTIME CLASS:.spec.runtimeClassName,SA:.spec.serviceAccountName'
```

```text
TODO: output from the fresh run
```

Its RBAC is a namespaced `Role`, not a `ClusterRole`: it creates job pods only in this
sample's own namespace, which is the `namespace` its `config.toml` names. Nothing in this
sample is cluster-scoped.

### Where the token is, and where it is not

The token is in one place, Secret `gitlab-runner-config`, mounted into the manager. The job
pods do not get it, and that is read off each job pod's own spec while its job is in flight,
by the names of what it mounts rather than by any value. A job pod is deleted when its job
ends, so there is nothing left to read afterwards: `scripts/run-pipeline.sh` records it during
the watch and prints it with the pod table in Step 3, and refuses the run if any job pod
mounted that Secret. These are the lines from that output:

```text
TODO: output from the fresh run
```

`kube-api-access-*` is the ServiceAccount token every pod gets by default, not this sample's
Secret. What the job pods mount is the runner's own build and script volumes.

The manager is the other side of that. Its own spec names the Secret, which is the one place
the token is:

```bash
kubectl --context <CLUSTER_NAME> -n gitlab-ci-demo get pod -l app=gitlab-runner \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n  volumes: "}{.spec.volumes[*].name}{"\n  vol secrets: "}{.spec.volumes[*].secret.secretName}{"\n"}{end}'
```

```text
TODO: output from the fresh run
```

## Good to know

- **The runner floor is a real floor.** `runtime_class_name` is the whole of this sample, and
  a GitLab Runner older than v17.5.3 does not know the setting. An older runner does not fail:
  it ignores the line and runs the job as an ordinary pod on the node, which is exactly the
  outcome the sample exists to avoid. `scripts/run-pipeline.sh` refuses a run in which any job
  pod lacked `runtimeClassName: isolated-sandbox`, so a runner that ignored it is caught
  rather than quietly accepted.
- **The job pods have a network, and nothing here restricts it.** They clone from the GitLab
  Service, pull base images from Amazon ECR Public and report status back, and with no network
  policy they can reach anything else the cluster can reach. The sandbox boundary is the VM,
  not the network, and the Overview links the sample that shows how to limit the network.
- **`CI_SERVER_URL` inside a job is the port-forward address, not a reachable one.** GitLab
  builds it from `external_url`, which this sample sets to `http://localhost:8080` so its web
  UI works through `kubectl port-forward`. Cloning is unaffected, because `clone_url` in the
  runner's configuration overrides it, but a job that calls the GitLab API itself would need
  the in-cluster address instead. A reader who does not want the web UI can set `external_url`
  to the Service address and drop `clone_url`.
- **A job pod's size is the sandbox's size.** The VM is sized from the pod's requests, so the
  build job's sandbox is the sum of its build, helper and service containers' requests. In
  production each sandbox reserves its full memory request up front, so plan node capacity by
  reservation rather than by usage: expect fewer, larger pods per node than with ordinary
  containers.
- **A reader who already runs GitLab can skip Step 1.** Point `url` and `clone_url` in
  `runner/config.toml.template` at their instance and paste a runner authentication token
  from it. The only requirements are that the runner manager can reach it and that you can
  create a runner there. Everything from Step 2 on is unchanged, and nothing about the
  isolation depends on where GitLab runs.
- **A first `FailedMount` on a brand-new node is not a failure.** When Karpenter has just
  provisioned the node GitLab lands on, the first attach can report `FailedMount` and then
  succeed within seconds. It is worth waiting through before reading it as a problem.
- **GitLab's own health endpoints answer only on localhost, which breaks an `httpGet` probe.**
  `/-/readiness`, `/-/liveness` and `/-/health` return 404 to every source address but
  localhost, and the kubelet probes from the node. An `httpGet` readiness probe on
  `/-/readiness` therefore never passes: the pod stays `0/1 Running` with no error anywhere,
  its Service gets no endpoint, and the runner reports `connection refused` against a GitLab
  that is up and healthy. Measured on this cluster: `/-/readiness` answered 200 on localhost
  and 404 from another pod at the same moment, while `/explore` answered 200 to both.
  [`deploy/gitlab.yaml`](deploy/gitlab.yaml) therefore uses an `exec` probe that curls
  localhost inside the container. The other way out is to add the pod's own network to
  GitLab's health-check address list, which needs a CIDR for your cluster; the `exec` probe
  needs nothing cluster-specific and asks GitLab the same question.
- **Nginx inside the GitLab container must not be put on 8080.** GitLab's Puma binds
  `127.0.0.1:8080` itself, so nginx fails to start with
  `Address already in use - bind(2) for "127.0.0.1" port 8080` and keeps restarting.
  `deploy/gitlab.yaml` leaves nginx on GitLab's own port 80 in the container and uses
  `nginx['listen_port']` to keep `external_url` at the forwarded `localhost:8080`, which is
  what that setting is for.
- **A `script:` line in `.gitlab-ci.yml` that holds a colon and a space is parsed as a
  mapping.** GitLab then refuses the whole job with `jobs:<name>:script config should be a
  string or a nested array of strings up to 10 levels deep`, which does not mention YAML or
  point at the line. The one line in
  [`pipeline/.gitlab-ci.yml`](pipeline/.gitlab-ci.yml) that needs a colon is quoted for that
  reason.

## Clean up

```bash
./scripts/clean.sh
```

```text
TODO: output from the fresh run
```

It deletes the runner manager first, so no new job pod is created while the rest goes, then
the comparison pod by its exact name, then the namespace, which takes GitLab, its claim, the
runner's RBAC and both Secrets with it. The project, its pipeline and the runner's record in
GitLab go with GitLab itself: they were only ever rows in the database on that volume, so
there is nothing separate to delete and nothing left in any GitLab you own.

It then confirms three things rather than assuming them: the namespace is gone, no pod
labelled `app=gitlab-ci-job` is left anywhere on the cluster, and the EBS volume behind
GitLab's claim was deleted. It reads that volume's id before deleting the claim, because
afterwards there is nothing left to read it from and "no claim" would look like "no volume".
Anything it could not confirm is reported and the script exits non-zero, because a lookup
that failed means "could not determine" and never "gone".

Nothing is left behind. This sample installs nothing shared, changes no cluster-wide setting,
and creates no IAM role, Pod Identity association or ECR repository. To remove the sandbox
runtime class and the cluster itself, see the
[Hello sandbox clean up](../../getting-started/hello-sandbox/README.md#clean-up).
