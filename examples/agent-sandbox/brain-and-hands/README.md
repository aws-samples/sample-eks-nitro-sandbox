# Brain and hands: an agent that runs every command in a claimed sandbox

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run the [hello sandbox](../../getting-started/hello-sandbox/README.md)
sample first so you have a cluster with the runtime classes. This sample builds on
[warm pool](../../getting-started/warm-pool/README.md), whose `SandboxTemplate`,
`SandboxWarmPool` and `SandboxClaim` it uses. The commands below use files from this
repository, so clone it if you have not already, and run them from this sample's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/agent-sandbox/brain-and-hands
```

It also needs `docker` on your machine to build the brain image, and an Amazon Bedrock
model your account can invoke. Your own credentials need `bedrock:GetInferenceProfile` as
well as the usual EKS, ECR and IAM permissions, because setup reads the model ARNs the
inference profile routes to in order to scope the brain's role to them. Beyond the cluster,
a run costs the Amazon Bedrock tokens the agent spends, one ECR repository, and the capacity
of one long-lived ordinary pod plus the warm pod the pool keeps booted. The pods set no CPU
or memory requests, so each guest gets a small default size.

## Overview

An agent that both runs arbitrary code and talks to a model does both of those things in
one process, on one pod, with one set of credentials. This sample takes the agent apart
along that line. The **brain** reasons and holds the credentials, and has no tool that runs
a command. The **hands** run every command, in a pre-booted Nitro sandbox pod claimed from
a warm pool. The brain reaches them through the
[agent-sandbox MCP server](https://github.com/kubernetes-sigs/agent-sandbox/blob/v1.0.10/clients/integrations/mcp-server/README.md),
which talks to [sandboxd](https://github.com/kubernetes-sigs/agent-sandbox/blob/v1.0.10/packages/sandboxd/USER_GUIDE.md),
the agent-sandbox runtime daemon, inside each hands pod: gRPC on port 9090 for commands,
REST on port 8080 for files. The Kubernetes API is used to claim a pod and nothing else, so
it carries none of a session's commands, files or output.

Be precise about what that buys, because it is easy to overstate. Code the model decides to
run never runs on the half that holds the credentials, and it cannot open a connection of
its own. It is **not** an exfiltration boundary: every command's output comes back to the
brain and goes into the next model request, and nothing in this sample restricts where the
brain can connect. *[What this sample does not limit](#what-this-sample-does-not-limit)*
below sets out where the boundaries actually are.

The brain is [Claude Code](https://code.claude.com/docs/en/overview), chosen because its
tools can be removed in configuration, but the pattern fits any agent that speaks MCP and
whose own shell or code-execution tool can be removed. It follows the design Anthropic
describes in
[Scaling Managed Agents: decoupling the brain from the hands](https://www.anthropic.com/engineering/managed-agents),
which the [warm pool](../../getting-started/warm-pool/README.md) page names at the end; this
sample is the worked version of it.

- **The thing that reasons and the thing that runs code are different pods.** The brain is
  an ordinary pod with no `runtimeClassName`. The hands are sandbox pods with
  `runtimeClassName: isolated-sandbox`. Step 4 shows the brain's own list of tools, with no
  shell tool in it, and step 8 shows the hands running with their own kernel build, their
  own boot and virtio disks.
- **The brain's only execution path is the agent-sandbox MCP server.** Every tool that runs
  a command is denied by name in the image's `settings.json`, which Claude Code's
  documentation says removes the tool from the agent's context entirely. What is left is the
  upstream MCP server, run over stdio inside the brain, with the arguments that choose a
  namespace, a pool or a pod's labels hidden from the model. Step 5 shows the tool schema
  the model is given.
- **Commands and files go to sandboxd, not through the Kubernetes API.** The brain's RBAC
  Role covers claims and Sandboxes only: no `pods/exec`, no `pods/log`, no
  `pods/portforward`. Step 6 runs a command and moves a file anyway, and step 12 shows the
  API refusing the brain every one of those subresources.
- **The hands admit only the brain, and send nothing out.** The template's network policy
  admits pods labelled `app=brain` on TCP 8080 and 9090 and has no egress rules, and sandboxd
  refuses any request without the brain's bearer token. Steps 9 and 10 show a connection out
  refused, a pod that is not the brain refused, and a request without the token refused.
- **A claim is served in about a second.** A `SandboxWarmPool` keeps a pod booted; a
  `SandboxClaim` adopts it. Step 7 shows the pod adopted from the pool and the pool booting
  a replacement while the claim is held.
- **The hands hold no credential, and the brain's role is the only one the sample makes.**
  The hands have no Pod Identity association, no IAM role and no ServiceAccount token, which
  step 11 checks by name without printing a value. The only policy the sample puts on the
  brain's role allows `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` on
  the one model it is configured with, shown in full in step 11.

*Figure 1: The brain and the hands, in two pods. The brain reasons and holds the credentials but has no tool that runs a command; the hands run every command; the brain reaches them through sandboxd on two ports that the hands' network policy opens to the brain alone.*

![Inside an AWS Cloud frame and an Amazon EKS cluster, the brain pod on the left and the Nitro sandbox pods on the right. The brain, an ordinary pod with no runtimeClassName, holds Claude Code with no tool that runs a command. The hands are Nitro sandbox pods with runtimeClassName isolated-sandbox: a claimed pod runs every command and a warm pod sits pre-booted and waiting. The brain reaches the hands directly over sandboxd (9090 gRPC for commands, 8080 REST for files) with a bearer token, routed above to avoid the network policy icon between them. The network policy governs the hands: ingress from the brain only. A Kubernetes API icon below is labelled control plane only, reached from the brain for create/read/delete claims and read Sandboxes. Amazon Bedrock and a Pod Identity role sit at the bottom, with the brain reaching the model over HTTPS via InvokeModel and the role authorising that call. A SandboxWarmPool with replicas 1 sits at bottom right, with edges showing it adopts a pre-booted pod in about a second to become the claimed pod and boots a replacement to become the warm pod.](images/figure-1-brain-and-hands.png)

### What this sample does not limit

It is worth being precise about where the boundaries are, because three of them are not
where a reader might assume.

**The hands' policy is the only thing between them and the network.** The hands have a pod
network, because that is how sandboxd is reached. What keeps them from using it is the
network policy the agent-sandbox controller applies from the template, and a network policy
holds only while enforcement is on for the cluster. Step 1 has you turn it on and
`setup.sh` checks it. If you change the template, keep `networkPolicy` with no `egress`
list: supplying any egress rule opens exactly that, and setting
`networkPolicyManagement: Unmanaged` drops the policy altogether.

**The hands can reach the sandbox's metadata endpoint.** With a network, a Nitro sandbox
serves instance metadata at `169.254.169.254` from inside the guest, so the egress policy,
which is enforced on the node, does not reach it. It holds no role: step 11 shows its `iam/`
path returning 404. It is not the same thing as "no instance metadata", and the page does not
claim that.

**The split is not an exfiltration boundary.** The hands cannot open a connection, but
their output is meant to reach the model: the MCP server returns it to the brain, and the
brain puts it in the next request. So anything the hands can read, the brain can carry, and
nothing in this sample restricts where the brain can connect. What the split does is keep
attacker-controlled code off the half that holds the credentials. If you need the stronger
property, restrict the brain's egress as well, with the
[network policy](../../isolation/network-policy/README.md) sample.

The brain's RBAC Role is **namespace-bounded, not claim-bounded**. Kubernetes RBAC selects
resources by name, never by label, and the MCP server names each claim it makes, so the
Role covers every claim and Sandbox in the namespace. The MCP server only acts on claims its
own session created: it labels each claim with the session's ID and checks the label on
every call. That is an application-level control, and it is the softer of the two. The
claim name is a tool argument, as it is upstream; the namespace and the pool are not.

## Versions

| Component | Pin |
|---|---|
| agent-sandbox controller ([kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)) | v1.0.10 |
| `sandboxd` image (`registry.k8s.io/agent-sandbox/sandboxd`) | v1.0.10, the first release with a released `sandboxd` image |
| agent-sandbox MCP server (`clients/integrations/mcp-server`) | the `v1.0.10` tag, installed from the release archive: it is not published to PyPI or as an image |
| `k8s-agent-sandbox` Python SDK, with the `async` and `grpc` extras | as the MCP server at that tag requires (`>=1.0.6,<2.0`); the run used 1.0.10 |
| Claude Code ([`@anthropic-ai/claude-code`](https://www.npmjs.com/package/@anthropic-ai/claude-code)) | 2.1.310 |

Keep the controller, the `sandboxd` image and the MCP server tag on the same release.
The Claude Code pin matters more than a version pin usually does: which tools exist, and
what a deny rule does to one, are that version's documented behaviour, and step 4 reads the
tool list from the running agent rather than assuming it. Nothing else is pinned beyond the
images in the manifests (`public.ecr.aws/docker/library/node:22-bookworm-slim` for the brain
and `public.ecr.aws/docker/library/python:3.12-slim` for the hands).

## Files

| File | What it is |
|---|---|
| [`Dockerfile`](Dockerfile) | The brain image: Claude Code, the agent-sandbox MCP server and the agent configuration, baked in. |
| [`brain/hands_mcp.py`](brain/hands_mcp.py) | Serves the upstream MCP server over stdio, with the namespace, the pool and the pod's labels and annotations hidden from the model, and reads the sandboxd token from its file. |
| [`brain/settings.json`](brain/settings.json) | The permission rules: every tool that runs a command denied by name, and the `hands` MCP server's tools allowed. |
| [`brain/.mcp.json`](brain/.mcp.json) | Registers `brain/hands_mcp.py` as an MCP server named `hands`. |
| [`brain/claude.json`](brain/claude.json) | Marks `/workspace` trusted and the MCP server enabled, so a non-interactive run does not stop at the trust prompt. |
| [`deploy/warm-pool.yaml`](deploy/warm-pool.yaml) | The hands: a `SandboxTemplate` that runs sandboxd with its network policy, and a `SandboxWarmPool` that keeps one booted. |
| [`deploy/brain.yaml`](deploy/brain.yaml) | The brain `Deployment`. No `runtimeClassName`: the brain is not the sandboxed half. |
| [`deploy/rbac.yaml`](deploy/rbac.yaml) | The brain's `ServiceAccount`, `Role` and `RoleBinding`, and the whole of what it may do. |
| [`iam/bedrock-invoke-policy.json`](iam/bedrock-invoke-policy.json) | The brain's only AWS permission: invoke a model. |
| [`iam/pod-identity-trust.json`](iam/pod-identity-trust.json) | The trust policy that lets EKS Pod Identity assume the role. |
| [`scripts/setup.sh`](scripts/setup.sh) | Check the shared installs and the cluster setting, build and push the brain image, create the role, the token and the cluster objects. |
| [`scripts/cleanup.sh`](scripts/cleanup.sh) | Delete everything the sample created, and leave the agent-sandbox install alone. |
| [`scripts/common.sh`](scripts/common.sh) | The names, the pinned context, the readings and the guards the scripts share. |
| [`.env.example`](.env.example) | The local values the sample needs, with no values filled in. |

The scripts read `.env` (copy it from `.env.example`). `NAMESPACE` defaults to
`brain-and-hands` and reaches every object they apply. Set `KUBE_CONTEXT` to the context of
the cluster you ran Getting started on, so a run never depends on the machine's current
context, which on a shared cluster another session can change mid-run.

**Step 1: Install agent-sandbox and turn on network policy enforcement, once per
cluster.** Both are shared: another workload on the cluster may depend on the agent-sandbox
version that is there, and enforcement applies to every network policy on the cluster. So
`setup.sh` checks both and changes neither. Install agent-sandbox yourself at the pinned
version:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.10/sandbox-with-extensions.yaml
kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller
```

If it is already on your cluster at v1.0.10 or later, leave it as it is. `setup.sh` reads its
image, and stops with the command above when a CRD is missing, the controller is not
`Available`, or its version is older than v1.0.10.

EKS Auto Mode accepts network policies without enforcing them until the Network Policy
Controller is turned on, through the `amazon-vpc-cni` ConfigMap in `kube-system`
([EKS network policy documentation](https://docs.aws.amazon.com/eks/latest/userguide/auto-net-pol.html)).
If you have run the [network policy](../../isolation/network-policy/README.md) sample it is
already on:

```bash
kubectl get configmap -n kube-system amazon-vpc-cni \
  -o jsonpath='{.data.enable-network-policy-controller}{"\n"}'
```

If that does not print `true`, turn it on. Pods that no policy selects are unaffected:

```bash
kubectl patch configmap -n kube-system amazon-vpc-cni --type merge \
  -p '{"data":{"enable-network-policy-controller":"true"}}'
```

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
and the enforcement setting first, so a missing prerequisite stops the run before anything is
created, then builds and pushes the brain image, creates the brain's role, mints the sandboxd
token, and applies the hands and the brain:

```bash
./scripts/setup.sh 2>&1 | tee setup.log
```

```text
TODO: output from the fresh run
```

The token is 32 random bytes. It goes into a Secret that only the brain mounts, and the
hands get its SHA-256 digest on sandboxd's command line, so the pod spec of the hands, and
the environment of every process sandboxd starts, hold nothing that opens sandboxd. The image
tag is a digest of the `Dockerfile` and everything under `brain/`, so a change to either
produces a new tag and a push cannot serve a stale image.

```bash
kubectl -n $NAMESPACE get sandboxwarmpool,deploy,pods,networkpolicy
```

```text
TODO: output from the fresh run
```

Two pods, an ordinary one and a sandboxed one waiting to be claimed, and the one network
policy the agent-sandbox controller wrote from the template.

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
the `hands` MCP server provides.

A list of names is only as good as the list it was checked against, so ask the running agent
instead:

```bash
kubectl -n $NAMESPACE exec deploy/brain -- \
  claude -p 'List the exact names of every tool you have available, one per line, and nothing else.'
```

```text
TODO: output from the fresh run
```

Now ask it to run something locally:

```bash
kubectl -n $NAMESPACE exec deploy/brain -- \
  claude -p 'Run "id -un && hostname" directly on your own machine, in your own shell, without using any sandbox. If you cannot, say exactly which tool you would need and whether you have it.'
```

```text
TODO: output from the fresh run
```

The permission rules are enforced by Claude Code, not by the model, so this is not the model
choosing to be careful: the tool is not in its context to call.

**Step 5: The tools it does have.** [`brain/.mcp.json`](brain/.mcp.json) registers
[`brain/hands_mcp.py`](brain/hands_mcp.py) as the `hands` MCP server. It is the upstream
agent-sandbox MCP server, unchanged, served in two ways that differ from upstream's image:

- **Over stdio, as a child of the agent.** The upstream image serves streamable HTTP on
  `0.0.0.0:8000` with no authentication, so any pod that can reach that port could drive
  it. Over stdio there is no listener at all.
- **With the arguments that choose where a sandbox comes from hidden.** `namespace` on every
  tool, and `warmpool`, `labels`, `pod_labels` and `pod_annotations` on `create_sandbox`, are
  taken out of the schema the model sees and filled in from the pod's environment, using
  FastMCP's tool transforms:

```python
for name in TOOLS_WITH_NAMESPACE:
    args = {"namespace": _hidden(NAMESPACE)}
    if name == "create_sandbox":
        args["warmpool"] = _hidden(WARMPOOL)
        args["labels"] = _hidden()
        args["pod_labels"] = _hidden()
        args["pod_annotations"] = _hidden()
    transforms[name] = ToolTransformConfig(arguments=args)
mcp.add_transform(ToolTransform(transforms))
```

The launcher prints the schema the model is given:

```bash
kubectl -n $NAMESPACE exec deploy/brain -- python3 /opt/brain/hands_mcp.py --print-tools
```

```text
TODO: output from the fresh run
```

How the server reaches the hands is its own configuration, set in
[`deploy/brain.yaml`](deploy/brain.yaml):

```yaml
- { name: K8S_SANDBOX_CONNECTION__TYPE, value: sandboxd-in-cluster }
- { name: K8S_SANDBOX_CONNECTION__MODE, value: in-cluster-pod-ip }
```

`sandboxd-in-cluster` dials sandboxd in the claimed pod directly, with no sandbox router
and no `kubectl port-forward`. `in-cluster-pod-ip` takes the address from the Sandbox's
`status.podIPs`, so the template needs no Service. Upstream notes the trade-off: an address
read from status can, in principle, be one a recycled pod now holds. Here the token is what
stops that from mattering, since a pod that is not one of these hands does not accept it.

**Step 6: Drive it.** The brain is idle until you give it something to do. You reach it with
`kubectl exec`, and it reaches the hands:

```bash
kubectl -n $NAMESPACE exec deploy/brain -- \
  claude -p 'Create a sandbox. In it, print the kernel build with "uname -rv", write a Python file that prints 6*7 and run it, then try to fetch https://example.com with python3. Report what each one returned, and delete the sandbox at the end.'
```

```text
TODO: output from the fresh run
```

That is the whole pattern in one turn: the model decided to run a command, the command ran
in a pre-booted sandbox pod, a file went in and its output came back, all through sandboxd,
and the attempt to reach the network from there failed.

**Step 7: The claim adopted a pod that was already running, and the pool refilled.** A
`SandboxClaim` with a `warmPoolRef` adopts a booted pod rather than starting one. That is
the whole reason a claim is fast: nothing boots on the claim path. The pool does the booting
beforehand, and again afterwards, so the cost moves off the path a session waits on.

*Figure 2: The life of one claim against a warm pool. A claim adopts a pod that is already booted; the pool boots a replacement behind it.*

![Three states of one claim against a warm pool, inside an Amazon EKS cluster. State 1 at rest: a Nitro sandbox frame with network policy stating no egress, containing one warm pod that is pre-booted and waiting. State 2 while a claim is held: a wider Nitro sandbox frame with the same network policy, containing a claimed pod with launch-type warm and a replacement pod that is booting. State 3 after release: the same structure as State 1, back to one warm pod. Below the states, a SandboxClaim icon labelled one per session and a SandboxWarmPool icon labelled replicas 1. Four edges: 1. the MCP server creates a SandboxClaim, 2. adopts a pre-booted pod (launch-type: warm), 3. pool boots a replacement (readyReplicas 1 again), 4. claim deleted, pod torn down. A note below the figure reads that the hands' network policy has no egress rules, so all egress is denied, with no route out, no DNS and no Pod Identity; that it admits only pods labelled app=brain on 8080 and 9090; that the metadata endpoint inside the guest still answers but holds no role; and that while a claim is held the node runs two pods.](images/figure-2-claim-lifecycle.png)

Ask the agent to create one and keep it, then read the claim and the pool:

```bash
kubectl -n $NAMESPACE exec deploy/brain -- claude -p 'Create a sandbox, report its claim name and status, and do not delete it.'
kubectl -n $NAMESPACE get sandboxclaim
kubectl -n $NAMESPACE get sandbox \
  -o custom-columns='NAME:.metadata.name,LAUNCH-TYPE:.metadata.labels.agents\.x-k8s\.io/launch-type'
kubectl -n $NAMESPACE get sandboxwarmpool hands-pool
```

```text
TODO: output from the fresh run
```

The `launch-type` label is how you tell an adoption from a cold start. While a session holds
a pod the steady state is two pods: the claimed one and the next one waiting. Size
`replicas` to your peak claim rate rather than your total session count, as the
[warm pool](../../getting-started/warm-pool/README.md) page sets out.

A `claude -p` run is one MCP session, and the server only acts on claims its own session
created, so a later run cannot drive the claim this one left behind. Each run creates its
own; step 13 deletes what is left.

**Step 8: The hands ran in a sandbox.** Three readings together show the pod's containers
ran in a VM of their own, and the brain gives the ordinary-pod comparison for each. Run them
as you, with `kubectl exec`, rather than through the brain, so the comparison is on the same
footing for both pods:

```bash
for p in $HANDS $REPLACEMENT; do
  kubectl -n $NAMESPACE exec $p -c hands -- sh -c \
    'uname -rv; cat /sys/class/dmi/id/product_name; ls /sys/block; cut -d" " -f1 /proc/uptime'
done
kubectl -n $NAMESPACE exec deploy/brain -- sh -c \
  'uname -rv; cat /sys/class/dmi/id/product_name; ls /sys/block; cut -d" " -f1 /proc/uptime'
```

```text
TODO: output from the fresh run
```

The kernel version string is the same in both and the build is not, which is why `uname -r`
alone is not evidence. The product name is the VM in the hands and the EC2 instance in the
brain, the disks are virtio devices in the hands and the instance's own in the brain, and
each sandbox pod reports its own boot, because each got its own VM.

```bash
kubectl -n $NAMESPACE get pods \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,RUNTIMECLASS:.spec.runtimeClassName'
```

```text
TODO: output from the fresh run
```

The runtime class shows what was asked for rather than what ran, which is why the readings
above come first.

**Step 9: The hands admit only the brain, and send nothing out.** The policy is part of the
template in [`deploy/warm-pool.yaml`](deploy/warm-pool.yaml), and the agent-sandbox
controller writes it as one `NetworkPolicy` for every pod made from the template:

```yaml
spec:
  networkPolicyManagement: Managed
  networkPolicy:
    ingress:
      - from:
          - podSelector:
              matchLabels:
                app: brain
        ports:
          - { protocol: TCP, port: 8080 }  # sandboxd REST: files and /v1/health
          - { protocol: TCP, port: 9090 }  # sandboxd gRPC: ProcessService
```

Supplying `networkPolicy` replaces the controller's default, which admits the sandbox router
and lets egress reach the public internet. The controller writes both policy types, so with
no `egress` list at all every connection the hands try to open is denied. Read the object it
wrote:

```bash
kubectl -n $NAMESPACE get networkpolicy hands-network-policy -o yaml
```

```text
TODO: output from the fresh run
```

From inside the hands, nothing resolves and nothing connects, by name or by address:

```bash
kubectl -n $NAMESPACE exec $HANDS -c hands -- python3 -c 'import socket; socket.gethostbyname("amazonaws.com")'
kubectl -n $NAMESPACE exec $HANDS -c hands -- python3 -c 'import socket; socket.create_connection(("1.1.1.1", 443), timeout=5)'
```

```text
TODO: output from the fresh run
```

Both legs matter: the first could be DNS alone, and the second rules that out by skipping
DNS entirely. Replies to the brain's own connections are not egress, which is why sandboxd's
answers still reach it.

And the other direction. A pod in the same namespace that is not labelled `app=brain` cannot
reach either port, while the brain reaches both:

```bash
kubectl -n $NAMESPACE run not-the-brain --restart=Never \
  --image=public.ecr.aws/docker/library/python:3.12-slim -- sleep 300
kubectl -n $NAMESPACE exec not-the-brain -- python3 -c '<connect to the hands pod on 8080 and 9090>'
kubectl -n $NAMESPACE delete pod not-the-brain
```

```text
TODO: output from the fresh run
```

**Step 10: sandboxd refuses a request without the token.** The policy decides who can reach
the ports; the token decides who sandboxd answers. Only `GET /v1/health` is open, so the
kubelet's readiness probe works:

```bash
kubectl -n $NAMESPACE exec deploy/brain -- python3 -c '<GET /v1/health and /v1/files/ with no token, a wrong token and the right one>'
```

```text
TODO: output from the fresh run
```

The token is read from `/var/run/hands/token` by the launcher and set only in the MCP
server's own process. The brain's Secret is the only place it is stored, and the hands hold
its digest.

**Step 11: The hands hold no credential, and the brain's role is the only one.** A command
the model runs in the hands finds nothing to authenticate with. Checked by variable name, so
no value is printed:

```bash
kubectl -n $NAMESPACE exec $HANDS -c hands -- sh -c \
  'env | cut -d= -f1 | grep -E "^(AWS|ANTHROPIC|CLAUDE|BEDROCK|K8S_SANDBOX)" || echo "(none)"'
kubectl -n $NAMESPACE exec $HANDS -c hands -- ls /var/run/secrets/kubernetes.io/serviceaccount/
kubectl -n $NAMESPACE exec $HANDS -c hands -- python3 -c 'import socket; socket.create_connection(("169.254.170.23", 80), timeout=3)'
kubectl -n $NAMESPACE exec $HANDS -c hands -- python3 -c '<IMDSv2: PUT a token, then GET iam/security-credentials/>'
```

```text
TODO: output from the fresh run
```

No AWS, model or MCP server variables; no ServiceAccount token, because the template sets
`automountServiceAccountToken: false`; and the EKS Pod Identity address is not reachable,
because the policy denies all egress. The metadata endpoint is a different case, as
*[What this sample does not limit](#what-this-sample-does-not-limit)* says: it is served
inside the guest, so it answers, and its `iam/` path returns 404 because the pod has no
role.

Only the brain has an association, and the association names a namespace and a
ServiceAccount, so it delivers the role to the brain's ServiceAccount in this namespace:

```bash
aws eks list-pod-identity-associations --cluster-name $CLUSTER_NAME --namespace $NAMESPACE \
  --query 'associations[].{serviceAccount:serviceAccount,associationId:associationId}' --output table
```

```text
TODO: output from the fresh run
```

That role is the whole of what the sample grants in AWS, so it is worth reading in full.
`setup.sh` renders it from [`iam/bedrock-invoke-policy.json`](iam/bedrock-invoke-policy.json)
with your Region, account and `BEDROCK_MODEL_ID`, so it names the one model the brain is
configured with rather than any model:

```bash
aws iam get-role-policy --role-name $POD_IDENTITY_ROLE_NAME --policy-name bedrock-invoke --query PolicyDocument
aws iam list-attached-role-policies --role-name $POD_IDENTITY_ROLE_NAME --query AttachedPolicies
aws iam list-role-policies --role-name $POD_IDENTITY_ROLE_NAME --query PolicyNames
```

```text
TODO: output from the fresh run
```

Two actions, on the one model the brain is configured with. It takes two statements because
a cross-Region inference profile such as `us.anthropic.claude-sonnet-5-5` needs two
resources: the profile, which is addressed in your own account, and the foundation models it
routes to, one per Region behind it. Those ARNs are read from the profile itself at apply
time, with `aws bedrock get-inference-profile`, rather than derived from its ID, because a
derived prefix with a trailing wildcard would also allow any other model whose ID started the
same way.

Read the scope precisely. Those two statements are the whole of what **this sample attaches
to this role**, and `setup.sh` refuses to reuse a tagged role that has picked up anything
else, so the run you get matches the policy above. That is not the same as saying nothing
else can ever reach the role: a trust policy edited afterwards, or a second Pod Identity
association elsewhere naming the same role, are outside what the sample creates or checks.

**Step 12: What the brain may do on the Kubernetes API.** Ask the API rather than reading
the Role, using the ServiceAccount as the subject:

```bash
SA=system:serviceaccount:$NAMESPACE/brain
kubectl auth can-i create sandboxclaims.extensions.agents.x-k8s.io --as $SA -n $NAMESPACE
kubectl auth can-i create pods --subresource=exec --as $SA -n $NAMESPACE
kubectl auth can-i get pods --subresource=log --as $SA -n $NAMESPACE
kubectl auth can-i create pods --subresource=portforward --as $SA -n $NAMESPACE
kubectl auth can-i create sandboxclaims.extensions.agents.x-k8s.io --as $SA -n default
```

```text
TODO: output from the fresh run
```

The brain can create, read, list, watch and delete claims and read Sandboxes in its own
namespace, and nothing else: no `exec`, no logs, no port-forward, no pods at all, no
Secrets, no other namespace and nothing cluster-scoped. Every command and file in steps 6
and 7 went through sandboxd with the Role exactly as shown, which is what says the
Kubernetes API carried none of it.

**Step 13: Delete the claims.** When a session ends the agent deletes its claim with
`delete_sandbox`, the pod is torn down, and nothing from that session survives into the
next one. A claim the agent leaves behind, such as the one step 7 kept, goes when its
`shutdown_after_seconds` passes (300 by default, a tool argument the model can change) or
when you delete it:

```bash
kubectl -n $NAMESPACE delete sandboxclaim <CLAIM_NAME>
kubectl -n $NAMESPACE get sandboxclaim,sandboxwarmpool,pods
```

```text
TODO: output from the fresh run
```

## Good to know

- **The brain is not sandboxed, and that is the design.** It is the half that holds the
  credentials and talks to the model, so it is the half with a network. Putting the whole
  agent in a sandbox is the [coding agent](../../getting-started/coding-agent/README.md)
  sample; this one is the contrast.
- **The Kubernetes API is the control plane here, not the data plane.** Claims go through
  it; commands, files and output go to sandboxd on the pod network. At scale that keeps a
  busy agent's traffic off the API server.
- **Nothing in this sample limits where the brain can connect.** Its limits are its tool
  configuration, its IAM role and its RBAC Role, each read back above. If you need egress
  restricted as well, take the mechanism from the
  [network policy](../../isolation/network-policy/README.md) sample.
- **Keep only the brain and the hands in this namespace.** The hands' policy admits any pod
  here labelled `app=brain`, and the brain's Role covers every claim and Sandbox here.
- **Run the MCP server over stdio, or put authentication in front of it.** The upstream
  server has none of its own. Over stdio, as here, the agent that started it is its only
  client.
- **`claude -p` needs the project already trusted.** [`brain/claude.json`](brain/claude.json)
  marks `/workspace` trusted and the MCP server enabled. Without it a non-interactive run
  stops at the trust prompt, which leaves `settings.json` unread and the MCP server never
  loaded: the agent would then have its default tools, including a shell.
- **Commands run in the hands image.** sandboxd is copied into the hands container by an
  init container and run as its command, so commands find `python3` and a shell from
  `python:3.12-slim`. To give the agent other tools, change that image. Files sandboxd
  serves are confined to `/workspace`.
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
TODO: output from the fresh run
```

The script deletes a repository or a role only when it carries the sample's
`ManagedBy=brain-and-hands` tag, and nothing inside the namespace unless the namespace
carries the sample's label. A read that fails counts as "could not determine", which is a
failure and never "gone", and the script exits non-zero when it skipped something or could
not confirm a delete.

**What stays.** The agent-sandbox controller is a shared install and another workload on the
cluster may rely on it, so the clean up leaves it, and network policy enforcement stays on.
Remove the controller yourself, with its CRDs and every Sandbox resource in the cluster,
only if nothing else is using it:

```bash
kubectl delete -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.10/sandbox-with-extensions.yaml
```

Turn enforcement off again only if you turned it on for this sample and nothing else relies
on it, by setting `enable-network-policy-controller` back to `"false"` in the same
ConfigMap.

A local copy of the brain image may still be on your machine: `docker image ls` and
`docker image rm` the `brain-and-hands` tag. If this is the last sample you ran, follow the
[hello sandbox](../../getting-started/hello-sandbox/README.md#clean-up) clean up to remove the
namespace and the cluster.
