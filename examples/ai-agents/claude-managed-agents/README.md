# Claude Managed Agents with tool calls in a Nitro sandbox

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run the [hello sandbox](../../getting-started/hello-sandbox/README.md)
sample first so you have a cluster with the runtime classes. Run the commands below from
this folder.

For this sample you also need [Docker](https://docs.docker.com/get-docker/), Python 3 with
`venv`, and a Claude organization with access to
[Claude Managed Agents](https://platform.claude.com/docs/en/managed-agents/overview), where
you can create a self-hosted environment and generate its environment key in the Claude
Console. A session uses Claude API credit; the one in step 8 cost $0.02.

[Claude Managed Agents](https://platform.claude.com/docs/en/managed-agents/overview) runs
an agent's loop for you: Claude, the conversation and the session state stay on
Anthropic's side. With a
[self-hosted sandbox](https://platform.claude.com/docs/en/managed-agents/self-hosted-sandboxes),
the other half, the agent's tool calls, runs on infrastructure you control. Each session
arrives as a work item; a worker of yours claims it, runs every `bash`, `read`, `write`,
`edit`, `glob` and `grep` call Claude decides to make in that session, and posts each
result back.

Those tool calls are code the model chose to run, so this sample gives each session its own
Nitro sandbox:

- **Claude reasons on Anthropic's side; the tools run in your cluster.** An ordinary poller
  Deployment claims work from the environment's queue. It runs no tool calls itself.
- **Each session gets its own pod.** The poller claims a sandbox that is already booted from
  a `SandboxWarmPool` and hands it the session. The sandbox's `SandboxTemplate` sets
  `runtimeClassName: isolated-sandbox`, so the commands run on a kernel no other pod
  shares, and the pod is gone when the session ends.
- **Three credentials, each in one place.** Your organization API key, which can create
  agents and read every session, stays on your machine. The environment key, which can
  claim any session in this environment's queue, is held only by the poller (and the
  optional autoscaler). Each work item carries a secret with a token for that one session;
  the poller hands it to the session's sandbox, and the sandbox runs on that token alone.
  The sandbox holds neither key and refuses to start if it finds one.
- **The sandbox can reach the Claude API and its DNS; the internet, AWS APIs and other
  pods are refused.** An `ApplicationNetworkPolicy` admits the poller inbound, and allows
  the sandbox egress to CoreDNS and `api.anthropic.com`. (The policy allows the addresses
  that name resolves to, so another name served from the same addresses would also be
  reachable.)

*Figure 1: Claude reasons on Anthropic's side and the poller claims the session. A warm
Nitro sandbox runs the session's tool calls, and its egress policy allows only the Claude
API's hostname.*

![The operator starts a session on the Anthropic control plane with the organization API key. In the EKS cluster, an ordinary poller pod holding only the environment key polls the work queue, creates a SandboxClaim that adopts a booted pod from a SandboxWarmPool of two, and posts the session id and its secret to the claimed pod. The claimed pod, an isolated-sandbox Nitro sandbox that holds only that session's token, runs bash, read, write, edit, glob and grep, and exchanges tool calls and results with api.anthropic.com, the one hostname its egress policy allows besides DNS; the policy refuses the internet, AWS APIs and other pods. The pool refills with a new warm pod.](images/claude-managed-agents.png)

This folder was built against these releases:

| Component | Version |
|---|---|
| Anthropic Python SDK (`anthropic`) | 1.13.0 |
| agent-sandbox Python client (`k8s-agent-sandbox`) | 1.0.6 |
| agent-sandbox controller ([kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)) | v1.0.6 |

The files:

| File | What it is |
|---|---|
| [`Dockerfile`](Dockerfile), [`pyproject.toml`](pyproject.toml) | The `claude-sandbox-worker` image: one image for the poller, the sandbox and the optional autoscaler |
| `src/worker/` | The worker: [`poller.py`](src/worker/poller.py), [`sandbox.py`](src/worker/sandbox.py) (claim and dispatch), [`serve.py`](src/worker/serve.py) (runs one session), [`guard.py`](src/worker/guard.py) (refuses any key a role must not hold) |
| [`deploy/sandbox-template.yaml`](deploy/sandbox-template.yaml) | The `SandboxTemplate` that runs tool calls, and a `SandboxWarmPool` of two |
| [`deploy/egress-policy.yaml`](deploy/egress-policy.yaml) | The network fence: the poller in, DNS and `api.anthropic.com` out |
| [`deploy/poller.yaml`](deploy/poller.yaml), [`deploy/rbac.yaml`](deploy/rbac.yaml) | The poller Deployment, and what it may do: manage `SandboxClaims` and read `Sandboxes` |
| [`deploy/autoscaler.yaml`](deploy/autoscaler.yaml) | Optional: sizes the warm pool from the work queue |
| [`scripts/setup_agent.py`](scripts/setup_agent.py), [`submit.py`](scripts/submit.py), [`stats.py`](scripts/stats.py) | Run on your machine with the organization key: create the agent and environment, start a session, read the queue stats |
| `.env.example` | The four values the sample needs; copy it to `.env`, which git ignores |

**Step 1: Install agent-sandbox and turn on network policy.** Install the controller with
its extensions (`SandboxTemplate`, `SandboxWarmPool`, `SandboxClaim`). If you ran the warm
pool sample, this upgrades it in place:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.6/sandbox-with-extensions.yaml
kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller
```

EKS Auto Mode accepts network policies without enforcing them until the Network Policy
Controller is enabled, once per cluster. If you have not run the coding agent sample:

```bash
kubectl apply -f ../../getting-started/coding-agent/enable-network-policy.yaml
```

**Step 2: Create the agent and the self-hosted environment.** On your machine, with your
organization API key in `.env`:

```bash
python3 -m venv .venv && .venv/bin/pip install anthropic==1.13.0
cp .env.example .env     # fill in ANTHROPIC_API_KEY
set -a; . ./.env; set +a
.venv/bin/python scripts/setup_agent.py
```

```text
Created agent agent_... (claude-sonnet-5-5)
Created self-hosted environment env_...

Add these to .env:
  AGENT_ID=agent_...
  ANTHROPIC_ENVIRONMENT_ID=env_...
Then, in the Claude Console, open Workspace > Environments > your
environment > Generate environment key, and add it as
  ANTHROPIC_ENVIRONMENT_KEY=...
```

The agent uses the built-in `agent_toolset_20260401` tools. There is no API that creates
an environment key, so generate it in the Console as the script says, put the three values
in `.env`, and load the file again with `set -a; . ./.env; set +a`.

**Step 3: Build and push the image.**

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGISTRY=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
aws ecr create-repository --repository-name claude-sandbox-worker --region $AWS_REGION
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin $REGISTRY
docker build --platform linux/amd64 -t $REGISTRY/claude-sandbox-worker:latest .
docker push $REGISTRY/claude-sandbox-worker:latest
docker logout $REGISTRY
```

**Step 4: Give the cluster the environment key.** The poller needs the environment key;
the sandboxes get only the environment id. Both are read from `.env`, so the key never
appears on a command line:

```bash
kubectl create secret generic anthropic-env-key \
  --from-env-file=<(grep '^ANTHROPIC_ENVIRONMENT_KEY=' .env)
kubectl create configmap anthropic-env \
  --from-env-file=<(grep '^ANTHROPIC_ENVIRONMENT_ID=' .env)
```

**Step 5: Fence the network.** [`egress-policy.yaml`](deploy/egress-policy.yaml) selects
the sandbox pods. It admits the poller on the dispatch port, and lets out DNS and HTTPS to
the Claude API:

```yaml
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: claude-poller
      ports:
        - { protocol: TCP, port: 8080 }
  egress:
    - to:
        - ipBlock: { cidr: <COREDNS_IP>/32 }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to:
        - domainNames:
            - api.anthropic.com
      ports:
        - { protocol: TCP, port: 443 }
```

Fill in your CoreDNS address, apply it, and wait for its `PolicyEndpoint`, which shows the
controller has handed the policy to the nodes:

```bash
COREDNS_IP=$(kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}')
sed "s|<COREDNS_IP>|$COREDNS_IP|" deploy/egress-policy.yaml | kubectl apply -f -
until kubectl get policyendpoints -o name | grep -q '^policyendpoint.networking.k8s.aws/claude-sandbox-worker-egress-'; do sleep 2; done
```

**Step 6: Deploy the sandbox and the poller.** Here is the part of
[`sandbox-template.yaml`](deploy/sandbox-template.yaml) that matters. The pool keeps two of
these booted:

```yaml
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxTemplate
metadata:
  name: claude-sandbox-worker
spec:
  networkPolicyManagement: Unmanaged   # egress-policy.yaml is the policy for these pods
  podTemplate:
    metadata:
      labels:
        app: claude-sandbox-worker
    spec:
      runtimeClassName: isolated-sandbox
      automountServiceAccountToken: false
      restartPolicy: Never              # one session, then the pod completes
      containers:
        - name: worker
          image: <ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/claude-sandbox-worker:latest
          args: ["serve"]
          env:                          # no Anthropic key: the session's token arrives in the dispatch
            - name: ANTHROPIC_ENVIRONMENT_ID
              valueFrom:
                configMapKeyRef: { name: anthropic-env, key: ANTHROPIC_ENVIRONMENT_ID }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          resources:
            requests: { cpu: "1", memory: 2Gi }
            limits:   { cpu: "1", memory: 2Gi }
```

The pod runs as a non-root user with its own empty `/workspace`, and has no ServiceAccount
token, so a command the model runs cannot reach the Kubernetes API. Apply the RBAC, the
template and pool, and the poller:

```bash
kubectl apply -f deploy/rbac.yaml
sed -e "s|<ACCOUNT_ID>|$ACCOUNT_ID|" -e "s|<AWS_REGION>|$AWS_REGION|" deploy/sandbox-template.yaml | kubectl apply -f -
sed -e "s|<ACCOUNT_ID>|$ACCOUNT_ID|" -e "s|<AWS_REGION>|$AWS_REGION|" deploy/poller.yaml | kubectl apply -f -
kubectl wait sandboxwarmpool/claude-sandbox-worker --for=jsonpath='{.status.readyReplicas}'=2 --timeout=600s
kubectl rollout status deploy/claude-poller
.venv/bin/python scripts/stats.py
```

```text
workers_polling: 1
depth:           0  (waiting to be picked up)
pending:         0  (polled, not yet acknowledged)
```

`workers_polling: 1` is the poller, connected to the queue with the environment key.

**Step 7: Look inside a warm sandbox.** Check its runtime class, the kernel and disks it
sees, and which Anthropic credentials it holds. The last command prints variable names
only, never values:

```bash
POD=$(kubectl get pods -l app=claude-sandbox-worker --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl get pod $POD -o jsonpath='{.spec.runtimeClassName}{"\n"}'
kubectl exec $POD -- sh -c 'uname -rv; cut -d" " -f1 /proc/uptime; ls /sys/block | tr "\n" " "; echo'
kubectl exec $POD -- sh -c 'env | cut -d= -f1 | grep ^ANTHROPIC_'
```

```text
isolated-sandbox
6.18.51 #1 SMP PREEMPT_DYNAMIC Thu Oct  1 23:28:07 UTC 2026
25.01
dm-0 vda vdb vdc
ANTHROPIC_ENVIRONMENT_ID
```

The sandbox runs its own kernel. Its uptime matches the pod's age, about 25 seconds here,
because the sandbox booted with the pod, and it sees virtio disks (`vda`, `vdb`, `vdc`). On the
same node, an ordinary pod reported the node's kernel build, `#2 SMP PREEMPT_DYNAMIC Wed
Oct  7 22:33:11 UTC 2026`, and the instance's `nvme` disks. The version string `6.18.51`
was the same for both; the build and the boot are not. The only Anthropic variable in the
pod is the environment id: no `ANTHROPIC_API_KEY` and no `ANTHROPIC_ENVIRONMENT_KEY`.

**Step 8: Run a session.** Start one from your machine. The script sends the task when it
creates the session, sets a spend ceiling of $1.00 (`--budget-cents` changes it), follows
the session until it settles and prints each tool call with its result:

```bash
.venv/bin/python scripts/submit.py "Run these commands with your bash tool: uname -rv; cat /proc/uptime; ls /sys/block; env | grep -c '^ANTHROPIC_' || true. Write their combined output to report.txt in your working directory, then read report.txt back to me."
```

Abridged; your text will differ:

```text
Session sesn_... created; waiting for the cluster to pick it up...
  -> bash
  -> read

[tool] bash: cd /workspace && { uname -rv; cat /proc/uptime; ls /sys/block; env | grep -c '^ANTHROPIC_' || true; } > report.txt 2>&1; echo done
[result:ok] done

[tool] read: /workspace/report.txt
[result:ok] 6.18.51 #1 SMP PREEMPT_DYNAMIC Thu Oct  1 23:28:07 UTC 2026
         68.94 63.81
         dm-0
         vda
         vdb
         vdc
         0

[agent] I ran the four commands, wrote their combined output to `/workspace/report.txt`, and read the file back. [...]

[idle] end_turn

2 tool calls, 0 errors, list cost 0.02 USD
```

The commands ran in a sandbox: the guest's kernel build, an uptime of about a minute and
virtio disks. The last line of the report is `0`: the agent's `bash` tool runs with every
`ANTHROPIC_*` variable removed from its environment. Beyond that, the sandbox process
itself holds no key to find: its only credential is this session's token, which arrived in
the dispatch rather than in an environment variable.

In the cluster, the poller's log names the `SandboxClaim` it created for the session and
the sandbox that claim adopted, and that sandbox's log shows each tool call it ran (dates
trimmed from the poller's lines, timestamps from the sandbox's):

```bash
kubectl logs deploy/claude-poller | grep -E 'SandboxClaim|claim Ready|-> sandbox='
kubectl logs <SANDBOX>     # the sandbox named in the poller's log; the pod has the same name
```

```text
22:34:59,040 INFO root Creating SandboxClaim 'sandbox-claim-3c315992' in namespace 'claude-managed-agents' using warm pool 'claude-sandbox-worker'...
22:34:59,090 INFO root Resolved sandbox name 'claude-sandbox-worker-zcw2b' from claim status (claim Ready)
22:34:59,114 INFO worker.sandbox session=sesn_... work=sesn_... -> sandbox=claude-sandbox-worker-zcw2b

INFO worker.serve waiting for a dispatch on :8080
INFO worker.serve serving session sesn_... in /workspace
INFO anthropic.lib.tools._beta_session_runner session tool runner starting session_id=sesn_...
INFO anthropic.lib.tools._beta_session_runner executing tool tool=bash tool_use_id=sevt_...
INFO anthropic.lib.tools._beta_session_runner executing tool tool=read tool_use_id=sevt_...
INFO anthropic.lib.tools._beta_session_runner session idle for 60s after its turn ended; stopping
INFO worker.serve session sesn_... finished
```

The claim was Ready about 50 ms after the poller created it, because it adopted a sandbox
that was already running; the pool booted a replacement in the background. When the
session went idle the worker stopped its work item and exited, and the pod completed.

To see the fence, run this in a warm sandbox. The session may have used the pod from
Step 7, so pick a running one again. The Claude API connects; the other two do not:

```bash
POD=$(kubectl get pods -l app=claude-sandbox-worker --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD -- python -c "
import socket
for host in ('api.anthropic.com', 'example.com', 'sts.us-west-2.amazonaws.com'):
    try:
        socket.create_connection((host, 443), timeout=5).close(); print(host, 'connected')
    except OSError as e:
        print(host, type(e).__name__, e)"
```

```text
api.anthropic.com connected
example.com OSError [Errno 101] Network is unreachable
sts.us-west-2.amazonaws.com TimeoutError timed out
```

The two refused hosts report different errors — `example.com` is unreachable,
`sts.us-west-2.amazonaws.com` times out — but they are blocked the same way.
[How the fence works](#how-the-fence-works), below, explains the policy, where it is
enforced, and why the messages differ.

**Optional: size the pool from the queue.** [`autoscaler.yaml`](deploy/autoscaler.yaml)
reads the environment's queue every 15 seconds and sets the pool to one warm sandbox for
each session waiting in the queue, at least 1 and at most 10. The poller acknowledges a
session as soon as it claims it, so a running session no longer counts: the pool grows when
sessions arrive faster than the poller hands them out. The autoscaler uses the environment
key too, and may only resize this one pool:

```bash
sed -e "s|<ACCOUNT_ID>|$ACCOUNT_ID|" -e "s|<AWS_REGION>|$AWS_REGION|" deploy/autoscaler.yaml | kubectl apply -f -
kubectl logs deploy/claude-autoscaler
```

```text
INFO worker.stats_adapter environment=env_... warm pool=.../claude-sandbox-worker replicas in [1, 10] every 15s
INFO worker.stats_adapter depth=0 pending=0 -> claude-sandbox-worker replicas None -> 1 (pool has 2)
```

It sets the replicas on every tick, so if anything else changes them, re-applying
`sandbox-template.yaml` for example, the next tick puts the target back.

## How the fence works

The egress policy from step 5 is an `ApplicationNetworkPolicy`. It selects the sandbox
pods (`app: claude-sandbox-worker`) and declares both `Ingress` and `Egress`, so the pods
are default-deny in both directions. Inbound, the policy allows the poller on TCP 8080.
Outbound, it allows CoreDNS on 53 and `api.anthropic.com` on 443. The public internet, AWS
service endpoints such as STS, and other pods are refused. (One carve-out sits above the
policy: Kubernetes always allows traffic to and from a pod's own node, covered under *No
reusable credential* below.)

*Figure 2: The egress fence around one sandbox pod. The policy admits the poller inbound
and allows egress to CoreDNS for name lookups and the Claude API; the public internet, AWS
APIs such as STS, and other pods are refused. The policy is enforced on the node, outside
the sandbox.*

![A focused view of the egress fence. Inside an EKS Auto Mode node, a red Nitro sandbox pod labeled claude-sandbox-worker (isolated-sandbox) runs the tool calls. The policy admits the poller inbound, reaching the pod on TCP 8080. An ApplicationNetworkPolicy, drawn as a filter that the node's network policy agent enforces in eBPF on the pod's host-side interface outside the guest, governs the pod. Two egress paths are allowed, in green: CoreDNS for name lookups on UDP and TCP 53, and api.anthropic.com, the Claude API, on TCP 443. A red dashed path marks the refused traffic: the internet, AWS APIs such as STS, and other pods. A caveat notes that the rule allows the IP addresses api.anthropic.com resolves to, so another name served from those same addresses would also be reachable.](images/claude-managed-agents-fence.png)

**Where it is enforced.** On EKS Auto Mode, a network policy agent on each node turns the
policy into eBPF programs attached to the pod's host-side virtual interface — on the node,
outside the sandbox's guest. AWS's documentation describes it this way: "The eBPF probes
attached to the Pod veth interface will then filter egress traffic ... based on the rules
in place. This ensures pods can only send cluster-external traffic to the IPs of allow
listed domains."
([EKS network policy documentation](https://docs.aws.amazon.com/eks/latest/userguide/auto-net-pol.html).)
Because the filtering lives on the node rather than in the guest, a command the model runs
inside the sandbox — even as root — cannot see or change it.

**Why the two refused hosts fail differently.** Both hosts are refused the same way: their
IPv4 addresses are not in the allow list, so an IPv4 connection attempt gets no reply and
runs to the timeout. The messages differ only because of the hosts' DNS records.
`example.com` also publishes IPv6 (AAAA) addresses, and the sandbox has no route to global
IPv6 addresses, so an IPv6 attempt fails immediately with "Network is unreachable";
`socket.create_connection` tries the IPv4 addresses first (they time out), then the IPv6
address, and raises the last error it saw — the IPv6 one. `sts.us-west-2.amazonaws.com`
publishes only IPv4 addresses, so its single attempt times out. The IPv4 block is identical
for both; only the surfaced message differs.

**No reusable credential, even if a request left.** The sandbox runs as a non-root user
with all Linux capabilities dropped and a read-only root filesystem, sets
`automountServiceAccountToken: false`, and holds no AWS credentials and no reusable
Anthropic key — only this one session's token, delivered in the dispatch and scoped to that
session. A request that reached some other host would carry no AWS credential and no durable
key to replay. The one carve-out from the fence is node-local traffic, which Kubernetes
always allows: the pod can reach its own node and the node's link-local metadata service,
but that is not a path to the internet, and the metadata service exposes no IAM role to the
pod (its `iam/` paths return 404) while the pod has no Pod Identity — so there is nothing to
assume there either.

<details>
<summary>Reading the enforcement, and the IPv4/IPv6 detail</summary>

Once the controller hands the policy to the nodes it appears as the `PolicyEndpoint` object
that step 5 waits for. On each node the network policy agent attaches the eBPF programs and
holds the resolved allow list for these pods: egress to CoreDNS on 53 and to the addresses
`api.anthropic.com` resolves to on 443, ingress from the poller on 8080, and — as the
always-allowed node carve-out — the pod's own node. That is the policy's rules plus the
node Kubernetes always permits.

The different error messages are a name-resolution artifact, not a difference in how
strongly each host is blocked. `example.com` resolves to both IPv4 and IPv6 addresses;
`sts.us-west-2.amazonaws.com` resolves to IPv4 only. The sandbox has an IPv4 default route
but no route to global IPv6 addresses, so an IPv6 connection attempt returns "Network is
unreachable" at once,
while an IPv4 attempt to a non-allowed address runs to the connect timeout.
`socket.create_connection` works through the resolved addresses in order and raises the
error from the last one it tried, so a host with a trailing IPv6 address reports
"unreachable" and an IPv4-only host reports "timed out".

</details>

## How the hand-off works

A warm sandbox boots before its session exists, so it cannot be given the session at
start-up. Instead:

1. The poller's `client.beta.environments.work.poller(..., auto_stop=False)` claims a work
   item. `auto_stop=False` means the poller does not stop the item when it moves on; the
   sandbox does, when the session ends.
2. [`sandbox.py`](src/worker/sandbox.py) calls `SandboxClient.create_sandbox(warmpool=...)`
   from `k8s-agent-sandbox`. It creates the `SandboxClaim`, waits until the claim is
   Ready, and returns a handle with the sandbox's pod IP.
3. The poller POSTs the session id, the work item id and the work item's `secret` to the
   sandbox's dispatch port. The secret carries a token for this one session, and it is the
   sandbox's only credential: the worker uses it for every call the session needs,
   including mounting any memory stores the session attaches. It goes only to the sandbox
   serving that session and is never logged. A work item without a secret is stopped
   instead of dispatched, and the sandbox refuses a dispatch that does not carry one.
4. [`serve.py`](src/worker/serve.py) hands the session to
   `EnvironmentWorker.handle_item()`. It heartbeats the work item's lease, downloads the
   agent's skills into `/workspace/skills/`, runs each tool call and posts its result, and
   stops the work item when the session goes idle. Then the process exits.

Because the poller only claims and dispatches, sessions run in parallel, one pod each.

## Good to know

- **The file tools' path checks are not a sandbox.** The SDK confines `read`, `write` and
  `edit` to the working directory, but `bash` can run anything. The sandboxed pod is what bounds it.
- **Use one environment per trust boundary.** An environment key reaches every session in
  its environment. Give separate users or tenants separate environments and keys.
- **The dispatch port has no authentication of its own.** A warm sandbox accepts the first
  well-formed POST on port 8080. The network policy is what keeps other pods and the
  internet from reaching it, and the sandbox refuses a dispatch that does not carry the
  session's secret.
- **Each claim has a deadline.** The poller creates claims with a 30-minute lifetime
  (`SHUTDOWN_AFTER_SECONDS`), after which the controller deletes the claim and its pod.
  That is also the longest a session can run; raise it for longer tasks. The sandbox then
  gets 90 seconds (`terminationGracePeriodSeconds`) to stop its work item and save any
  memory store changes before the pod is killed.
- **Set a budget.** A session's `budget` caps its list cost, so a runaway loop stops
  issuing model requests.
- **Size requests honestly.** Each sandbox reserves its full memory request, and the sandbox is
  sized to the pod's limits. Size `replicas` to how many sessions start at once, not to your total
  session count.

## Clean up

The commands use `AWS_REGION` and `REGISTRY` from the walkthrough. In a new shell, set them
again first, replacing `<AWS_REGION>` with the Region you deployed to:

```bash
export AWS_REGION=<AWS_REGION>
export REGISTRY=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$AWS_REGION.amazonaws.com
```

Remove the sample's objects, the image and its repository:

```bash
kubectl delete -f deploy/autoscaler.yaml --ignore-not-found
kubectl delete -f deploy/poller.yaml --ignore-not-found
kubectl delete -f deploy/sandbox-template.yaml --ignore-not-found
kubectl delete sandboxclaims -l anthropic.com/session-id
kubectl delete -f deploy/egress-policy.yaml -f deploy/rbac.yaml --ignore-not-found
kubectl delete secret anthropic-env-key --ignore-not-found
kubectl delete configmap anthropic-env --ignore-not-found
aws ecr delete-repository --repository-name claude-sandbox-worker --region $AWS_REGION --force
docker image rm $REGISTRY/claude-sandbox-worker:latest
rm -rf .venv
```

Keep `.env` if you will run the sample again. Otherwise delete it, and in the Claude Console
revoke the environment key, archive the agent and delete the self-hosted environment that
step 2 created (the SDK's `client.beta.agents.archive` and
`client.beta.environments.delete` do the last two).

agent-sandbox stays installed for other samples. To remove it as well, which deletes its
CRDs and every Sandbox resource in the cluster, delete the release you installed in step 1:

```bash
kubectl delete -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.6/sandbox-with-extensions.yaml
```
