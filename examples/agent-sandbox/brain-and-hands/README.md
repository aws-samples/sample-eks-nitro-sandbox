# Brain and hands: an agent that runs every command in a claimed sandbox

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run the [hello sandbox](../../getting-started/hello-sandbox/README.md)
sample first so you have a cluster with the runtime classes. This sample builds on
[warm pool](../../getting-started/warm-pool/README.md), whose `SandboxTemplate`,
`SandboxWarmPool` and `SandboxClaim` it uses and whose agent-sandbox install (step 1) it
needs. The commands below use files from this repository, so clone it if you have not
already, and run them from this sample's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/agent-sandbox/brain-and-hands
```

It also needs `docker` on your machine to build the brain image (the run below used
25.0.18), and an Amazon Bedrock model your account can invoke. Beyond the cluster, a run
costs the Amazon Bedrock tokens the agent spends, one ECR repository, and the capacity of
one long-lived ordinary pod plus the warm pod the pool keeps booted. The pods set no CPU or
memory requests, so each guest gets a small default size.

## Overview

An agent that both runs arbitrary code and talks to a model is, in one process, everything
a prompt injection needs: persuade it to run a command and the same process can also send
the result somewhere. This sample takes the agent apart along that line. The **brain**
reasons and holds the credentials, and has no tool that runs a command. The **hands** run
every command, in a pre-booted Nitro sandbox pod claimed from a warm pool, with no network
device at all. The only connection between them is the Kubernetes API.

The brain is [Claude Code](https://code.claude.com/docs/en/overview), chosen because its
tools can be removed in configuration, but the pattern fits any agent whose shell or
code-execution tool can be swapped for one that runs commands in a claimed sandbox. It
follows the design Anthropic describes in
[Scaling Managed Agents: decoupling the brain from the hands](https://www.anthropic.com/engineering/managed-agents),
which the [warm pool](../../getting-started/warm-pool/README.md) page names at the end; this
sample is the worked version of it.

- **The thing that reasons and the thing that runs code are different pods.** The brain is
  an ordinary pod with no `runtimeClassName`. The hands are sandbox pods with
  `runtimeClassName: isolated-sandbox`. Step 4 shows the brain's own list of tools, with no
  shell tool in it, and step 8 shows the hands running with their own kernel build, their
  own boot and virtio disks.
- **The brain's only execution path is one tool.** Every tool that runs a command is denied
  by name in the image's `settings.json`, which Claude Code's documentation says removes the
  tool from the agent's context entirely. What is left is an MCP tool that claims a warm pod
  and drives that one pod. Step 4 shows the agent asked to run a command on its own machine
  and reporting that it has no tool for it.
- **The hands have no network device.** They boot with
  `sandbox.amazonaws.com/network-isolated: "true"`, so there is no route, no DNS, no
  instance metadata and no Pod Identity endpoint. Step 9 reads the interfaces, the route
  table and two failed connections inside the pod.
- **`exec`, `cp` and `logs` still work on that same pod**, because they ride the sandbox's
  internal control channel rather than a network device. That is the brain's only way in,
  and step 10 shows all three.
- **A claim is served in about a second.** A `SandboxWarmPool` keeps a pod booted; a
  `SandboxClaim` adopts it. Step 7 shows the measured time and the pool booting a
  replacement while the claim is held.
- **The hands hold no credential, and the brain's role is the only one the sample makes.**
  The hands have no Pod Identity association, no IAM role and no ServiceAccount token, which
  step 11 checks by name without printing a value. The brain's role allows
  `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` and nothing else, shown
  in full in step 11.
- **The brain can claim and exec in one namespace and nothing else.** Step 12 asks the
  Kubernetes API what its ServiceAccount may do, and shows it refused creating or deleting
  pods, port-forward, Secrets, another namespace and anything cluster-scoped.

*Figure 1: The brain and the hands, in two pods. The brain reasons and holds the credentials but has no tool that runs a command; the hands run every command and have no network device; the Kubernetes API is the only wire between them.*

![Inside an AWS Cloud frame and an Amazon EKS cluster whose sub line reads that one namespace holds both halves, the two halves sit side by side. On the left, an Operator glyph labelled kubectl exec connects into the brain pod frame, marked an ordinary pod with no runtimeClassName, which holds Claude Code labelled no tool that runs a command. A red dashed arrow labelled no network path runs from the brain pod straight across to the Nitro sandbox pods frame on the right, marked isolated-sandbox plus network-isolated, which holds a claimed pod box labelled runs every command and a warm pod box labelled pre-booted, waiting. Below the middle, a Kubernetes API gear labelled the only wire to the hands connects by a two-way arrow left to the brain pod, labelled claim, exec, cp, logs, and by a two-way arrow up into the claimed pod, labelled the sandbox control channel. To its right a SandboxWarmPool document stack labelled replicas: 1 connects up into the claimed pod over an arrow labelled adopt a pre-booted pod in about 1 s, and up into the warm pod over an arrow labelled pool boots a replacement. Below the cluster, an arrow from the brain pod labelled InvokeModel over HTTPS reaches Amazon Bedrock, labelled Claude model, which is joined by a plain line to a red Pod Identity role glyph labelled bedrock:InvokeModel only. A note below the figure reads that the hands have no network device, so no route, no DNS, no instance metadata and no Pod Identity, and that they hold no ServiceAccount token and no IAM role, so a command the model runs finds no credential.](images/figure-1-brain-and-hands.png)

### What this sample does not limit

It is worth being precise about where the boundaries are, because two of them are not
where a reader might assume.

This sample ships **no network policy**. The hands need none: they have no network device
to restrict, which is a property of the sandbox boot and not of a policy. The brain,
though, is an ordinary pod with an ordinary pod's network, and nothing here restricts where
it can connect. What bounds the brain is its tool configuration (no tool that runs a
command, and no `WebFetch` or `WebSearch`), its IAM role (one Bedrock action pair) and its
RBAC Role (claims, `exec` and `logs` in one namespace). If you want the egress mechanism
itself, the [network policy](../../isolation/network-policy/README.md) sample under
Isolation is where it is shown.

The brain's RBAC Role is **namespace-bounded, not pod-bounded**. Kubernetes RBAC selects
resources by name, never by label, and the pods a warm pool hands out have generated names,
so the `exec` and `logs` rules cover every pod in the namespace, the brain's own pod
included. The namespace is the boundary, which is why only the brain and the hands belong in
it. Narrowing the brain to the one pod its claim adopted happens a layer up, in
[`brain/sandbox_tool.py`](brain/sandbox_tool.py), which never takes a pod name as a tool
argument. That is an application-level control, and it is the softer of the two.

## Versions

| Component | Pin |
|---|---|
| agent-sandbox controller ([kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)) | v1.0.6, as in [Warm pool](../../getting-started/warm-pool/README.md) |
| Claude Code ([`@anthropic-ai/claude-code`](https://www.npmjs.com/package/@anthropic-ai/claude-code)) | 2.1.310 |
| `kubectl` in the brain image | v1.37.1, within one minor of the cluster this ran on (Kubernetes 1.37) |
| `mcp` Python package, which the sandbox tool is built on | `>=1.6,<2` |

The Claude Code pin matters more than a version pin usually does: which tools exist, and
what a deny rule does to one, are that version's documented behaviour, and step 4 reads the
tool list from the running agent rather than assuming it. Nothing else is pinned beyond the
images in the manifests (`public.ecr.aws/docker/library/node:22-bookworm-slim` for the brain
and `public.ecr.aws/docker/library/python:3.12-slim` for the hands).

## Files

| File | What it is |
|---|---|
| [`Dockerfile`](Dockerfile) | The brain image: Claude Code, a `kubectl` client, the sandbox tool and the agent configuration, baked in. |
| [`brain/settings.json`](brain/settings.json) | The permission rules: every tool that runs a command denied by name, and the sandbox tool allowed. |
| [`brain/.mcp.json`](brain/.mcp.json) | Registers the sandbox tool as an MCP server named `hands`. |
| [`brain/sandbox_tool.py`](brain/sandbox_tool.py) | The brain's one execution path: claim a warm pod, then `run`, `write_file`, `read_file`, `logs` and `release` on that pod. |
| [`brain/claude.json`](brain/claude.json) | Marks `/workspace` trusted and the MCP server enabled, so a non-interactive run does not stop at the trust prompt. |
| [`brain/kubeconfig.yaml`](brain/kubeconfig.yaml) | The in-cluster kubeconfig the brain's `kubectl` uses, pointed at the projected ServiceAccount token. |
| [`deploy/warm-pool.yaml`](deploy/warm-pool.yaml) | The hands: a network-isolated `SandboxTemplate` and a `SandboxWarmPool` that keeps one booted. |
| [`deploy/brain.yaml`](deploy/brain.yaml) | The brain `Deployment`. No `runtimeClassName`: the brain is not the sandboxed half. |
| [`deploy/rbac.yaml`](deploy/rbac.yaml) | The brain's `ServiceAccount`, `Role` and `RoleBinding`, and the whole of what it may do. |
| [`iam/bedrock-invoke-policy.json`](iam/bedrock-invoke-policy.json) | The brain's only AWS permission: invoke a model. |
| [`iam/pod-identity-trust.json`](iam/pod-identity-trust.json) | The trust policy that lets EKS Pod Identity assume the role. |
| [`scripts/setup.sh`](scripts/setup.sh) | Check the shared installs, build and push the brain image, create the role and the cluster objects. |
| [`scripts/cleanup.sh`](scripts/cleanup.sh) | Delete everything the sample created, and leave the agent-sandbox install alone. |
| [`scripts/common.sh`](scripts/common.sh) | The names, the pinned context, the readings and the guards the scripts share. |
| [`.env.example`](.env.example) | The local values the sample needs, with no values filled in. |

The scripts read `.env` (copy it from `.env.example`). `NAMESPACE` defaults to
`brain-and-hands` and reaches every object they apply. Set `KUBE_CONTEXT` to the context of
the cluster you ran Getting started on, so a run never depends on the machine's current
context, which on a shared cluster another session can change mid-run.

The `context:` line in the output blocks below shows `sandbox-demo`, the shared default
cluster name from the home page; the run that produced this output used a different context
name, changed here to the default. The account ID is shown as `<ACCOUNT_ID>` and the two
node names as `<NODE_A>` and `<NODE_B>` for the same reason.

**Step 1: Install agent-sandbox, once per cluster.** This is a shared install: it adds its
own CRDs and a controller in its own namespace, and another workload on the cluster may
already depend on the version that is there. Install it yourself at the pinned version, as
the [warm pool](../../getting-started/warm-pool/README.md) sample does:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.6/sandbox-with-extensions.yaml
kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller
```

If it is already on your cluster, leave it exactly as it is. `setup.sh` only reads it, and
says which image it found:

```text
reusing the agent-sandbox install as it is (registry.k8s.io/agent-sandbox/agent-sandbox-controller:v1.0.6); this sample was built against v1.0.6
```

When a CRD is missing, or the controller is not `Available`, setup creates nothing and stops
with the command above. A pool with no controller never fills, so the check reads the
controller's condition and not only the CRDs.

**Step 2: Set the local values.** Copy [`.env.example`](.env.example) to `.env`, which git
ignores, and fill in your cluster:

```bash
cp .env.example .env
```

```text
CLUSTER_NAME=          # the EKS cluster the Pod Identity association is created on
AWS_REGION=us-west-2
KUBE_CONTEXT=          # pin the context, so a run never uses the machine's current one
NAMESPACE=brain-and-hands
BEDROCK_MODEL_ID=us.anthropic.claude-sonnet-5-5
ECR_REPOSITORY=brain-and-hands
POD_IDENTITY_ROLE_NAME=brain-and-hands-brain
```

List the models your account can invoke with
`aws bedrock list-inference-profiles --region $AWS_REGION --query 'inferenceProfileSummaries[].inferenceProfileId'`.

**Step 3: Stand it up.** [`scripts/setup.sh`](scripts/setup.sh) checks the shared installs
first, so a missing prerequisite stops the run before anything is created, then builds and
pushes the brain image, creates the brain's role, and applies the hands and the brain:

```bash
./scripts/setup.sh 2>&1 | tee setup.log
```

Abridged: the `docker build` and `docker push` transcripts are cut.

```text
context: sandbox-demo (pinned)   namespace: brain-and-hands   region: us-west-2
reusing the agent-sandbox install as it is (registry.k8s.io/agent-sandbox/agent-sandbox-controller:v1.0.6); this sample was built against v1.0.6

== 1/6 namespace brain-and-hands ==
namespace/brain-and-hands created
namespace/brain-and-hands labeled
created namespace brain-and-hands, labelled app.kubernetes.io/managed-by=brain-and-hands

== 2/6 ECR repository brain-and-hands ==
created ECR repository brain-and-hands, tagged ManagedBy=brain-and-hands

== 3/6 build and push the brain image ==
  <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/brain-and-hands:6b90b913956b3973

== 4/6 the brain's Bedrock role, through EKS Pod Identity ==
created IAM role brain-and-hands-brain, tagged ManagedBy=brain-and-hands
  role: arn:aws:iam::<ACCOUNT_ID>:role/brain-and-hands-brain
  permissions: bedrock-invoke (InvokeModel and InvokeModelWithResponseStream, nothing else)

== 5/6 the brain's identity and RBAC ==
serviceaccount/brain created
role.rbac.authorization.k8s.io/brain created
rolebinding.rbac.authorization.k8s.io/brain created
  created Pod Identity association a-obza8feixlwjltvhk for brain-and-hands/brain

== 6/6 the hands, then the brain ==
sandboxtemplate.extensions.agents.x-k8s.io/hands created
sandboxwarmpool.extensions.agents.x-k8s.io/hands-pool created
deployment.apps/brain created
Waiting for deployment "brain" rollout to finish: 0 of 1 updated replicas are available...
deployment "brain" successfully rolled out
  waiting for the pool to boot its warm pod (the first sandboxed pod on a cold cluster waits for a sandbox-capable node)
  readyReplicas=0/1
NAME         READY   DESIRED   AGE
hands-pool   1       1         10s
NAME    READY   UP-TO-DATE   AVAILABLE   AGE
brain   1/1     1            1           10s
```

The image tag is a digest of the `Dockerfile` and everything under `brain/`, so a change to
either produces a new tag and a push cannot serve a stale image.

```bash
kubectl -n $NAMESPACE get sandboxwarmpool,deploy,pods
```

```text
NAME                                                    READY   DESIRED   AGE
sandboxwarmpool.extensions.agents.x-k8s.io/hands-pool   1       1         11s

NAME                    READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/brain   1/1     1            1           10s

NAME                        READY   STATUS    RESTARTS   AGE
pod/brain-c96d585fb-mwcht   1/1     Running   0          10s
pod/hands-pool-xw8vj        1/1     Running   0          11s
```

Two pods: an ordinary one and a sandboxed one waiting to be claimed.

**Step 4: The brain has no tool that runs a command.** In Claude Code, permission rules
name a tool and what it may do, and a deny rule that names a whole tool does more than block
calls to it: "A bare tool name like `Bash` removes the tool from Claude's context entirely,
so Claude never sees it" ([Configure permissions](https://code.claude.com/docs/en/permissions)).
[`brain/settings.json`](brain/settings.json) uses that, and is baked into the image rather
than mounted, so the image is what decides which tools the agent has:

```json
{
  "permissions": {
    "defaultMode": "default",
    "deny": [
      "Bash",
      "PowerShell",
      "Monitor",
      "LSP",
      "Workflow",
      "Agent",
      "Skill",
      "EnterWorktree",
      "ExitWorktree",
      "WebFetch",
      "WebSearch"
    ],
    "allow": [
      "mcp__hands",
      "Read",
      "Glob",
      "Grep"
    ]
  },
  "enableAllProjectMcpServers": true
}
```

Each denied name is a tool that runs a command or starts a process at the pinned version,
taken from the [tools reference](https://code.claude.com/docs/en/tools-reference): `Bash`
and `PowerShell` are shells, `Monitor` runs a command in the background, `LSP` starts
language servers, `Workflow` and `Agent` run subagents that would have their own tools,
`Skill` executes a skill, and the two worktree tools run `git` and move the session's
working directory. `WebFetch` and `WebSearch` are denied because the brain reaches its model
through its own client and needs no web access of its own. `mcp__hands` allows every tool
the sandbox MCP server provides.

A list of names is only as good as the list it was checked against, so ask the running agent
instead:

```bash
kubectl -n $NAMESPACE exec deploy/brain -- \
  claude -p 'List the exact names of every tool you have available, one per line, and nothing else.'
```

```text
Edit
Glob
Grep
ListAgents
Read
ReportFindings
ScheduleWakeup
ToolSearch
Write
CronCreate
CronDelete
CronList
ListMcpResourcesTool
NotebookEdit
ReadMcpResourceDirTool
ReadMcpResourceTool
SendMessage
TaskStop
mcp__hands__claim
mcp__hands__logs
mcp__hands__read_file
mcp__hands__release
mcp__hands__run
mcp__hands__write_file
```

No `Bash`, and none of the other denied names. What remains besides the `mcp__hands__` tools
reads and writes files in the brain's own workspace, or schedules and messages; none of them
runs a command. `Write`, `Edit` and `NotebookEdit` are present but not in the `allow` list,
so a non-interactive run cannot use them either: asked to write a local file, the agent
reported `Claude requested permissions to write to /workspace/probe.txt, but you haven't
granted it yet`, and no file was created.

Now ask it to run something locally:

```bash
kubectl -n $NAMESPACE exec deploy/brain -- \
  claude -p 'Run "id -un && hostname" directly on your own machine, in your own shell, without using any sandbox. If you cannot, say exactly which tool you would need and whether you have it.'
```

```text
I can't do that. I don't have a tool that runs commands directly in my own shell. My tools are file tools (Read, Write, Edit, Glob, Grep) and scheduling and messaging tools. None of them is a Bash or shell tool.

The only command-execution tool I have is `mcp__hands__run`. Its description says it runs commands "in the claimed sandbox", and that it is "the only way to run a command." It needs `mcp__hands__claim` called first, which adopts a sandbox pod from a warm pool. So it is a sandbox, which is what you asked me to avoid. I haven't run anything with it.

To run `id -un && hostname` on my own machine, I would need a direct shell tool such as Bash, and I don't have one.

If a sandbox is acceptable, I can claim one and run the command there. The output would describe the sandbox pod, not my own machine.
```

The permission rules are enforced by Claude Code, not by the model, so this is not the model
choosing to be careful: the tool is not in its context to call.

**Step 5: The one tool it does have.** [`brain/sandbox_tool.py`](brain/sandbox_tool.py) is a
stdio MCP server registered as `hands` by [`brain/.mcp.json`](brain/.mcp.json). It creates a
`SandboxClaim` against the pool, waits for `status.sandbox.name`, and from then on drives
that one pod. The pod is never a tool argument:

```python
# Configuration, from the brain pod's environment (deploy/brain.yaml). None of
# it is reachable from a tool argument.
NAMESPACE = os.environ.get("HANDS_NAMESPACE", "default")
WARMPOOL = os.environ.get("HANDS_WARMPOOL", "hands-pool")
CLAIM = os.environ.get("HANDS_CLAIM", "brain-session")
CONTAINER = os.environ.get("HANDS_CONTAINER", "hands")
```

```python
@mcp.tool()
def run(command: str, stdin: str = "", timeout_seconds: int = DEFAULT_TIMEOUT) -> str:
    """Run a shell command in the claimed sandbox and return its combined
    output and exit code. This is the only way to run a command. Pass `stdin` to
    feed data on standard input. The sandbox has no network, so a command that
    tries to reach one fails."""
    pod = _pod()
```

The namespace, the pool and the claim name come from the pod spec, so the model cannot point
the tool at another pool or another namespace. Deliberately absent: creating or deleting a
pod, `port-forward`, exec into a pod of the model's choosing, and any passthrough that would
let the model run `kubectl` itself. The hard boundary underneath is the RBAC Role in
[`deploy/rbac.yaml`](deploy/rbac.yaml), which step 12 reads.

**Step 6: Drive it.** The brain is idle until you give it something to do. You reach it with
`kubectl exec`, and it reaches the hands:

```bash
kubectl -n $NAMESPACE exec deploy/brain -- \
  claude -p 'Claim a sandbox. In it, print the kernel build with "uname -rv", then try to fetch https://example.com with python3. Report what each one returned.'
```

```text
I claimed sandbox pod `hands-pool-xw8vj`. It came from the warm pool and was ready in 1.26s. I haven't released it.

- **`uname -rv`** worked (exit 0). It printed `6.18.54 #1 SMP PREEMPT_DYNAMIC Thu Oct 22 17:38:11 UTC 2026`.
- **Python fetch of https://example.com** failed (exit 1). `urllib` raised `URLError: <urlopen error [Errno -3] Temporary failure in name resolution>`. The sandbox has no network, as the tool description says, so DNS lookup failed and no request was sent.

Do you want me to release the sandbox now?
```

That is the whole pattern in one turn: the model decided to run a command, the command ran
in a pre-booted sandbox pod a second away, and the attempt to reach the network from there
failed because there is no network to reach it on. The turn took 10.9 seconds and five
model turns.

**Step 7: The claim adopted a pod that was already running, and the pool refilled.** A
`SandboxClaim` with a `warmPoolRef` adopts a booted pod rather than starting one:

```bash
kubectl -n $NAMESPACE exec deploy/brain -- claude -p 'Claim a sandbox and report how long the claim took.'
```

```text
I claimed a sandbox, and the claim took 1.29 seconds (wall clock, from claim to Ready).

- **Pod:** `hands-pool-7bn59`
- **Launch type:** warm, adopted from the warm pool

The 1.29s figure includes the tool's own kubectl calls.
```

The tool measures its own wall clock, from just before it creates the claim to the moment
the pod is Ready, so the figure includes its `kubectl` round trips. That overstates the
adoption and never understates it. The claim object's own `Ready` condition has one-second
granularity, which for a warm claim reads as zero, so it is the looser number that is
honest here.

The `launch-type` label is how you tell an adoption from a cold start, and the pool boots a
replacement straight away:

```bash
kubectl -n $NAMESPACE get sandboxclaim brain-session
kubectl -n $NAMESPACE get sandbox \
  -o custom-columns='NAME:.metadata.name,LAUNCH-TYPE:.metadata.labels.agents\.x-k8s\.io/launch-type'
kubectl -n $NAMESPACE get sandboxwarmpool hands-pool
```

```text
NAME            READY   SANDBOX            REASON              AGE
brain-session   True    hands-pool-7bn59   DependenciesReady   3s

NAME               LAUNCH-TYPE
hands-pool-7bn59   warm
hands-pool-mllgb   warm

NAME         READY   DESIRED   AGE
hands-pool   1       1         7m34s
```

The pool was back to `readyReplicas=1` about 10 seconds after the claim, so while a session
holds a pod the steady state is two pods: the claimed one and the next one waiting. Size
`replicas` to your peak claim rate rather than your total session count, as the
[warm pool](../../getting-started/warm-pool/README.md) page sets out.

**Step 8: The hands ran in a sandbox.** Three readings together show the pod's containers
ran in a VM of their own, and the brain gives the ordinary-pod comparison for each. The
claimed pod and the pool's replacement are on the same node:

```bash
for p in $HANDS $REPLACEMENT; do
  kubectl -n $NAMESPACE exec $p -c hands -- sh -c \
    'uname -rv; cat /sys/class/dmi/id/product_name; ls /sys/block; cut -d" " -f1 /proc/uptime'
done
kubectl -n $NAMESPACE exec deploy/brain -- sh -c \
  'uname -rv; cat /sys/class/dmi/id/product_name; ls /sys/block; cut -d" " -f1 /proc/uptime'
```

```text
--- the claimed sandbox pod ---
kernel:        6.18.54 #1 SMP PREEMPT_DYNAMIC Thu Oct 22 17:38:11 UTC 2026
product name:  m8i.enclave
disks:         dm-0 vda vdb vdc
uptime:        160.29s
--- the pool's replacement pod, on the same node ---
kernel:        6.18.54 #1 SMP PREEMPT_DYNAMIC Thu Oct 22 17:38:11 UTC 2026
product name:  m8i.enclave
disks:         dm-0 vda vdb vdc
uptime:        7.98s
--- the brain, an ordinary pod ---
kernel:        6.18.54 #2 SMP PREEMPT_DYNAMIC Thu Oct 22 00:16:59 UTC 2026
product name:  m8a.2xlarge
disks:         dm-0 nvme0n1 nvme1n1 zram0
uptime:        44410.11s
```

Read the three rows against each other:

| Reading | The sandbox pods | The brain, an ordinary pod |
|---|---|---|
| `uname -rv` | `6.18.54 #1`, the guest kernel | `6.18.54 #2`, its node's kernel |
| `/sys/class/dmi/id/product_name` | `m8i.enclave`, the VM | `m8a.2xlarge`, the EC2 instance |
| `ls /sys/block` | `vda vdb vdc`, virtio devices | `nvme0n1 nvme1n1`, the instance's disks |
| `/proc/uptime` | 160s and 8s, each pod's own age | 44410s, the node's uptime |

The version string is the same, `6.18.54`, and the build is not: `#1` against `#2`. That is
why `uname -r` alone is not evidence. The two uptimes are the clearest reading of all: both
sandbox pods are on the same node, and each reports its own boot, seconds apart, because
each got its own VM.

```bash
kubectl -n $NAMESPACE get pods \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,RUNTIMECLASS:.spec.runtimeClassName'
```

```text
NAME                    NODE       RUNTIMECLASS
brain-c96d585fb-mwcht   <NODE_A>   <none>
hands-pool-7bn59        <NODE_B>   isolated-sandbox
hands-pool-mllgb        <NODE_B>   isolated-sandbox
```

The runtime class shows what was asked for rather than what ran, which is why the readings
above come first.

**Step 9: The hands have no network device.** This is one annotation in
[`deploy/warm-pool.yaml`](deploy/warm-pool.yaml), and it is the only thing in the sample that
limits where code in the hands can connect:

```yaml
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxTemplate
metadata:
  name: hands
spec:
  networkPolicyManagement: Unmanaged
  podTemplate:
    metadata:
      annotations:
        sandbox.amazonaws.com/network-isolated: "true"
        karpenter.sh/do-not-disrupt: "true"      # keep the node under an idle warm pod
    spec:
      runtimeClassName: isolated-sandbox
      automountServiceAccountToken: false
      enableServiceLinks: false
      containers:
        - name: hands
          image: public.ecr.aws/docker/library/python:3.12-slim
```

`networkPolicyManagement: Unmanaged` is there for a reason worth stating. Left at its
default, `Managed`, the agent-sandbox controller creates a `NetworkPolicy` of its own for
the template's pods, and with no rules from you that policy allows `0.0.0.0/0` less the
private ranges: the public internet. Against a pod with no network device it does nothing,
but it would become a standing permission the moment anyone dropped the annotation above.
`Unmanaged` means the only reason the hands cannot reach the network is that they have no
network.

Read it from inside the pod. Only loopback has an address, and the route table is empty:

```bash
kubectl -n $NAMESPACE exec $HANDS -c hands -- python3 -c '<list each interface and its IPv4 address>'
kubectl -n $NAMESPACE exec $HANDS -c hands -- cat /proc/net/route
```

```text
--- the claimed sandbox pod ---
lo       127.0.0.1
dummy0   (no IPv4 address)
--- the brain, an ordinary pod ---
lo       127.0.0.1
eth0     192.168.127.130

Iface	Destination	Gateway 	Flags	RefCnt	Use	Metric	Mask		MTU	Window	IRTT
```

The brain has an `eth0` with a VPC address and the hands do not. `dummy0` is present with no
address, and the route table has a header and no rows: there is no default route to leave by.
So a name does not resolve, and an address is not reachable either:

```bash
kubectl -n $NAMESPACE exec $HANDS -c hands -- python3 -c 'import socket; socket.gethostbyname("amazonaws.com")'
kubectl -n $NAMESPACE exec $HANDS -c hands -- python3 -c 'import socket; socket.create_connection(("1.1.1.1", 443), timeout=5)'
```

```text
socket.gaierror: [Errno -3] Temporary failure in name resolution
command terminated with exit code 1

OSError: [Errno 101] Network is unreachable
command terminated with exit code 1
```

Both legs matter: the first could be DNS alone, and the second rules that out by skipping
DNS entirely.

**Step 10: `exec`, `cp` and `logs` all reach that same pod anyway.** They travel on the
sandbox's internal control channel rather than over a network device, which is why they keep
working with no network in the guest, and it is the brain's only way in:

```bash
echo 'print("sum:", sum(range(10)))' > /tmp/probe.py
kubectl -n $NAMESPACE cp --no-preserve=true /tmp/probe.py $HANDS:/work/probe.py -c hands
kubectl -n $NAMESPACE exec $HANDS -c hands -- python3 /work/probe.py
kubectl -n $NAMESPACE exec $HANDS -c hands -- sh -c 'echo written in the sandbox > /work/out.txt'
kubectl -n $NAMESPACE cp --no-preserve=true $HANDS:/work/out.txt /tmp/out.txt -c hands && cat /tmp/out.txt
kubectl -n $NAMESPACE logs $HANDS -c hands
```

```text
cp in:  ok
sum: 45
tar: Removing leading `/' from member names
cp out: written in the sandbox
hands ready in a sandbox: kernel 6.18.54 #1 SMP PREEMPT_DYNAMIC Thu Oct 22 17:38:11 UTC 2026, disks dm-0 vda vdb vdc
```

A file went in, a command ran, a file came back out, and the log stream returned the line the
container printed at boot. `--no-preserve=true` is not decoration: `kubectl cp` copies
through `tar`, which by default restores the ownership it recorded, and the hands drop every
capability, so without it `tar` fails even though the bytes land:

```text
$ kubectl -n $NAMESPACE cp /tmp/np.txt $HANDS:/work/np.txt -c hands     # without --no-preserve
tar: np.txt: Cannot change ownership to uid <LOCAL_UID>, gid <LOCAL_GID>: Operation not permitted
tar: Exiting with failure status due to previous errors
command terminated with exit code 2

$ kubectl -n $NAMESPACE cp --no-preserve=true /tmp/np.txt $HANDS:/work/np.txt -c hands
[exit: 0]
```

**Step 11: The hands hold no credential, and the brain's role is the only one.** A command
the model runs in the hands finds nothing to authenticate with. Checked by variable name, so
no value is printed:

```bash
kubectl -n $NAMESPACE exec $HANDS -c hands -- sh -c \
  'env | cut -d= -f1 | grep -E "^(AWS|ANTHROPIC|CLAUDE|BEDROCK)" || echo "(none)"'
kubectl -n $NAMESPACE exec $HANDS -c hands -- ls /var/run/secrets/kubernetes.io/serviceaccount/
kubectl -n $NAMESPACE exec $HANDS -c hands -- python3 -c 'import socket; socket.create_connection(("169.254.170.23", 80), timeout=3)'
kubectl -n $NAMESPACE exec $HANDS -c hands -- python3 -c 'import socket; socket.create_connection(("169.254.169.254", 80), timeout=3)'
```

```text
(none)

ls: cannot access '/var/run/secrets/kubernetes.io/serviceaccount/': No such file or directory
command terminated with exit code 2

OSError: [Errno 101] Network is unreachable
command terminated with exit code 1

OSError: [Errno 101] Network is unreachable
command terminated with exit code 1
```

No AWS or model variables; no ServiceAccount token, because the template sets
`automountServiceAccountToken: false`; and neither the EKS Pod Identity address nor the
instance metadata address is reachable, because a network-isolated pod has no network to
reach them on. The `KUBERNETES_*` variables are present whatever `enableServiceLinks` says,
and they name an address these pods have no route to.

Only the brain has an association, and the association names a namespace and a
ServiceAccount, so the credential is delivered to the brain's pods and nowhere else:

```bash
aws eks list-pod-identity-associations --cluster-name $CLUSTER_NAME --namespace $NAMESPACE \
  --query 'associations[].{serviceAccount:serviceAccount,associationId:associationId}' --output table
```

```text
-------------------------------------------
|       ListPodIdentityAssociations       |
+----------------------+------------------+
|     associationId    | serviceAccount   |
+----------------------+------------------+
|  a-obza8feixlwjltvhk |  brain           |
+----------------------+------------------+
```

With no network policy in this sample, that role is the whole of what the sample grants in
AWS, so it is worth reading in full. It allows two actions and nothing else:

```bash
aws iam get-role-policy --role-name $POD_IDENTITY_ROLE_NAME --policy-name bedrock-invoke --query PolicyDocument
aws iam list-attached-role-policies --role-name $POD_IDENTITY_ROLE_NAME --query AttachedPolicies
aws iam list-role-policies --role-name $POD_IDENTITY_ROLE_NAME --query PolicyNames
```

```text
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "InvokeBedrockModelsOnly",
            "Effect": "Allow",
            "Action": [
                "bedrock:InvokeModel",
                "bedrock:InvokeModelWithResponseStream"
            ],
            "Resource": [
                "arn:aws:bedrock:*::foundation-model/*",
                "arn:aws:bedrock:*:*:inference-profile/*"
            ]
        }
    ]
}
[]
[
    "bedrock-invoke"
]
```

One inline policy, no attached policies, two actions. Narrow the `Resource` further to the
one model you use if you want to; the sample leaves it at any foundation model or inference
profile so that changing `BEDROCK_MODEL_ID` does not also mean editing the policy.

**Step 12: What the brain may do on the Kubernetes API.** Ask the API rather than reading
the Role, using the ServiceAccount as the subject:

```bash
SA=system:serviceaccount:$NAMESPACE/brain
kubectl auth can-i create pods --subresource=exec --as $SA -n $NAMESPACE
kubectl auth can-i create pods --as $SA -n $NAMESPACE
kubectl auth can-i create pods --subresource=exec --as $SA -n default
```

```text
=== the brain's own namespace: what it may do ===
  create sandboxclaims                           in brain-and-hands  -> yes
  delete sandboxclaims                           in brain-and-hands  -> yes
  get sandboxes                                  in brain-and-hands  -> yes
  get pods                                       in brain-and-hands  -> yes
  create pods --subresource=exec                 in brain-and-hands  -> yes
  get pods --subresource=log                     in brain-and-hands  -> yes
=== the brain's own namespace: what it may NOT do ===
  create pods                                    in brain-and-hands  -> no
  delete pods                                    in brain-and-hands  -> no
  create pods --subresource=portforward          in brain-and-hands  -> no
  get secrets                                    in brain-and-hands  -> no
  create sandboxtemplates                        in brain-and-hands  -> no
  delete sandboxwarmpools                        in brain-and-hands  -> no
=== another namespace: the same ServiceAccount ===
  create pods --subresource=exec                 in default          -> no
  get pods                                       in default          -> no
  create sandboxclaims                           in default          -> no
=== cluster-scoped ===
  list nodes                                     (cluster-wide)      -> no
  list namespaces                                (cluster-wide)      -> no
```

The brain can claim a pod and drive it, and cannot make a pod of its own, sandboxed or not,
cannot forward a port, cannot read a Secret, cannot touch another namespace and has nothing
cluster-scoped. Note the `pods/exec` rule carries both `create` and `get`: `kubectl`'s
WebSocket exec executor issues a `GET` and falls back to a SPDY `POST`, so an exec that works
whatever the client version needs both, and `kubectl cp` goes through the same subresource.

**Step 13: Release the claim.** When the session ends the agent deletes the claim, the pod is
torn down, and nothing from that session survives into the next one:

```bash
kubectl -n $NAMESPACE exec deploy/brain -- claude -p 'Release the sandbox you claimed.'
kubectl -n $NAMESPACE get sandboxclaim,sandboxwarmpool,pods
```

```text
I released the sandbox. Its pod is torn down, and the pool will boot a replacement.

NAME                                                    READY   DESIRED   AGE
sandboxwarmpool.extensions.agents.x-k8s.io/hands-pool   1       1         8m21s

NAME                        READY   STATUS    RESTARTS   AGE
pod/brain-c96d585fb-mwcht   1/1     Running   0          8m20s
pod/hands-pool-mllgb        1/1     Running   0          54s
```

Back to one warm pod waiting, about 40 seconds after the release.

## Good to know

- **The brain is not sandboxed, and that is the design.** It is the half that holds the
  credentials and talks to the model, so it is the half with a network. Putting the whole
  agent in a sandbox is the [coding agent](../../getting-started/coding-agent/README.md)
  sample; this one is the contrast.
- **Nothing in this sample limits where the brain can connect.** Its limits are its tool
  configuration, its IAM role and its RBAC Role, each read back above. If you need egress
  restricted as well, take the mechanism from the
  [network policy](../../isolation/network-policy/README.md) sample.
- **The RBAC `exec` rule covers every pod in the namespace,** because RBAC selects by name
  and warm-pool pods have generated names. Keep only the brain and the hands in this
  namespace. The sandbox tool's refusal to take a pod name is an application-level control on
  top, not a second enforcement point.
- **A warm pod can fail to start and not recover by itself.** In this run one pool
  replacement went into `CrashLoopBackOff` with a `StartError` from the sandbox runtime
  (`mount_host_image: gave up after 10s: no single guest disk reports serial ... yet`), and
  the kubelet's restarts did not clear it, so the pool sat at `readyReplicas` empty while the
  pod retried. Deleting that one `Sandbox` by name let the pool boot another, which started
  normally. The Amazon EKS User Guide does not document this, so treat it as something to
  watch for rather than a known limit: read `readyReplicas` on the pool, not just the pool's
  existence, before you rely on a claim being fast.
- **`claude -p` needs the project already trusted.** [`brain/claude.json`](brain/claude.json)
  marks `/workspace` trusted and the MCP server enabled. Without it a non-interactive run
  stops at the trust prompt, which leaves `settings.json` unread and the sandbox tool never
  loaded: the agent would then have its default tools, including a shell.
- **The hands set no CPU or memory requests,** so each guest gets a small default size,
  enough for the commands this sample runs. A real workload sets the requests it needs: the
  sandbox is sized from them, not from the limits.
- **`karpenter.sh/do-not-disrupt: "true"` on the template pins the node** under an idle warm
  pod, since nothing would reschedule a pre-booted pod if consolidation removed the node
  under it. It also keeps that node out of consolidation, which is the trade-off.

## Clean up

Set the variables again if you are in a new shell, then run the clean up. It deletes in
reverse order of creation, starting with the brain so nothing claims another pod while it
runs, and the pool before the template it references:

```bash
./scripts/cleanup.sh
```

```text
context: sandbox-demo (pinned)   namespace: brain-and-hands   region: us-west-2

== 1/9 delete the brain ==
deployment.apps "brain" deleted from brain-and-hands namespace

== 2/9 delete the session claim so its warm pod is released ==
  sandboxclaim/brain-session not present

== 3/9 delete the warm pool so it stops booting replacements ==
sandboxwarmpool.extensions.agents.x-k8s.io "hands-pool" deleted from brain-and-hands namespace
  waiting for the pool's sandboxes to terminate
    the pool's sandboxes are gone

== 4/9 delete the SandboxTemplate ==
sandboxtemplate.extensions.agents.x-k8s.io "hands" deleted from brain-and-hands namespace

== 5/9 delete the brain's RBAC and ServiceAccount ==
rolebinding.rbac.authorization.k8s.io "brain" deleted from brain-and-hands namespace
role.rbac.authorization.k8s.io "brain" deleted from brain-and-hands namespace
serviceaccount "brain" deleted from brain-and-hands namespace

== 6/9 delete the Pod Identity association ==
  Pod Identity association a-obza8feixlwjltvhk is gone

== 7/9 delete the IAM role brain-and-hands-brain ==
  IAM role brain-and-hands-brain is gone

== 8/9 delete the ECR repository brain-and-hands ==
  ECR repository brain-and-hands is gone

== 9/9 delete namespace brain-and-hands ==
namespace "brain-and-hands" deleted
  namespace brain-and-hands deleted

The agent-sandbox controller is left as it is: it is a shared install, and
another workload on the cluster may rely on it.
A local copy of the brain image may still be on your machine: docker image ls

clean up complete: the brain, the claim, the pool, the template, the RBAC,
the Pod Identity association, the IAM role, the ECR repository and the namespace are gone.
```

The script deletes a repository or a role only when it carries the sample's
`ManagedBy=brain-and-hands` tag, and nothing inside the namespace unless the namespace
carries the sample's label. A read that fails counts as "could not determine", which is a
failure and never "gone", and the script exits non-zero when it skipped something or could
not confirm a delete.

**What stays.** The agent-sandbox controller is a shared install and another workload on the
cluster may rely on it, so the clean up leaves it. Remove it yourself, with its CRDs and
every Sandbox resource in the cluster, only if nothing else is using it:

```bash
kubectl delete -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.6/sandbox-with-extensions.yaml
```

A local copy of the brain image may still be on your machine: `docker image ls` and
`docker image rm` the `brain-and-hands` tag. If this is the last sample you ran, follow the
[hello sandbox](../../getting-started/hello-sandbox/README.md#clean-up) clean up to remove the
namespace and the cluster.
