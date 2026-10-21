# Coding agents for developers

A developer opens a web app, picks a coding agent (Claude Code, Codex, Kiro CLI, OpenCode,
pi or oh-my-pi) and gets a live terminal running that agent a second or two later. Each
session runs in its own Nitro sandbox, claimed from a warm pool for that CLI, with its
workspace on [Amazon S3 Files](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-files-mounting-eks.html)
so it survives the pod going away. A session's pod can open only its own folder, through a
short-lived credential scoped to that one folder: even as root inside the sandbox, it is
refused on any other session's folder. The web app is trusted first-party code and stays an
ordinary pod; it is reached only with `kubectl port-forward`.

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run these samples first, which this one builds on:

- [Getting started > Coding agent](../../getting-started/coding-agent/README.md): Amazon
  Bedrock through EKS Pod Identity, turning on network policy enforcement, and an
  `ApplicationNetworkPolicy` with host names.
- [Getting started > Warm pool](../../getting-started/warm-pool/README.md): agent-sandbox,
  a `SandboxWarmPool`, and claims that adopt a pod that is already running.
- [AI agents > Claude Managed Agents](../../managed-agents/claude-managed-agents/README.md):
  an app outside the sandbox that claims sandboxes from a pool, and a `SandboxTemplate` with
  `networkPolicyManagement: Unmanaged`.

The commands below use files from this repository, so clone it if you have not already, and
run them from this sample's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/ai-agents/coding-agents-for-developers
```

For this sample you also need [Docker](https://docs.docker.com/get-docker/) to build the
images, the AWS CLI with the `aws s3files` commands, and `kubectl`. A run costs Amazon
Bedrock usage per token for the five CLIs that use it, and S3 and S3 Files storage for the
data each session keeps; the warm pools keep one pod per CLI running by default, each
reserving its full memory request. Kiro CLI usage counts against the developer's own Kiro
plan.

## Overview

- **Any coding agent, one platform.** Each CLI has its own image, `SandboxTemplate` and
  `SandboxWarmPool`, built on one shared base image. Adding a seventh takes one Dockerfile,
  one template, one pool and one line in the app's agent list.
- **A warm start with a folder of its own.** New agent and Restore both claim a pod that is
  already running, then mount that session's folder into it.
- **Per-session permissions.** The pod's own role cannot mount any folder. For each session
  the app hands the pod a short-lived credential that can mount only that session's access
  point. Even as root inside the sandbox, the pod is refused on any other session's folder.
- **Every session in its own sandbox.** Two terminals open side by side are two pods, each
  with its own kernel build, boot and virtio disks.
- **No model API key in the sandbox.** The five CLIs that use Amazon Bedrock reach it
  through EKS Pod Identity, with a role that may only invoke models. Kiro CLI uses the
  developer's own Kiro sign-in, done once in the terminal and kept in the session's folder.

*Figure 1: A developer picks a CLI in the web app; the app claims a warm Nitro sandbox pod
from that CLI's pool, mounts the session's S3 Files folder into the guest with a credential
scoped to that one access point, and drives a terminal over the Kubernetes exec API. The
pod reaches Amazon Bedrock through a Pod Identity role that may only invoke models; its
egress policy refuses everything else.*

![A developer, outside AWS, reaches the web app over the Kubernetes exec API through kubectl port-forward. Inside the AWS Cloud, an Amazon EKS cluster holds the web app, an ordinary trusted first-party pod that claims a pod and drives the terminal. The app claims a red Nitro sandbox pod (isolated-sandbox, one per session) from a dashed SandboxWarmPool per CLI, and mounts the session folder into it with a per-session credential. The sandbox pod runs tmux and the CLI with its workspace at /workspace. To the right, outside the cluster, it mounts its own S3 Files access point only (one per session), which syncs with an S3 bucket (one prefix per session), and it invokes models on Amazon Bedrock through a Pod Identity role that may only invoke models. Below, a red dashed arrow to the internet, AWS APIs and other pods is refused by the egress policy.](figures/architecture.png)

## Versions

This folder was built against these releases. Pin each to its latest when you build, and
the images record what they installed.

| Component | Version |
|---|---|
| agent-sandbox controller ([kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)) | v1.0.6 |
| S3 Files mount helper ([amazon-efs-utils](https://github.com/aws/efs-utils)) | 3.3.4 |
| Claude Code ([`@anthropic-ai/claude-code`](https://www.npmjs.com/package/@anthropic-ai/claude-code)) | 2.1.306 |
| Codex CLI ([`@openai/codex`](https://www.npmjs.com/package/@openai/codex)) | 0.163.0 |
| Kiro CLI ([kiro.dev](https://kiro.dev/docs/cli/)) | TODO: from the build |
| OpenCode ([`opencode-ai`](https://www.npmjs.com/package/opencode-ai)) | 1.19.3 |
| pi ([`@earendil-works/pi-coding-agent`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)) | 1.3.0 |
| oh-my-pi ([`@oh-my-pi/pi-coding-agent`](https://github.com/can1357/oh-my-pi)) | 18.12.5 |
| xterm.js ([`@xterm/xterm`](https://www.npmjs.com/package/@xterm/xterm)) | 6.0.0 |

## Files

| File | What it is |
|---|---|
| [`app/`](app/) | The web app: the server ([`server/`](app/server/)) and the xterm.js UI ([`public/`](app/public/)), and its [`Dockerfile`](app/Dockerfile) |
| [`images/base/`](images/base/) | The shared base image: the S3 Files mount helper, tmux, git, and [`session-entrypoint.sh`](images/base/session-entrypoint.sh) |
| [`images/<cli>/`](images/) | One Dockerfile per CLI, each `FROM` the base |
| [`deploy/sandbox-template.yaml`](deploy/sandbox-template.yaml) | The per-CLI `SandboxTemplate` and `SandboxWarmPool` |
| [`deploy/egress-policy.yaml`](deploy/egress-policy.yaml) | The per-CLI egress policy |
| [`deploy/rbac.yaml`](deploy/rbac.yaml), [`deploy/app.yaml`](deploy/app.yaml) | The service accounts and RBAC, and the app Deployment and Service |
| [`iam/`](iam/) | The Bedrock, App and Mount role policies and trusts, and the per-session mount session policy |
| [`scripts/setup.sh`](scripts/setup.sh), [`scripts/clean.sh`](scripts/clean.sh) | Create everything and apply it; remove it |
| `.env.example` | The local values the sample needs; copy to `.env`, which git ignores |

## Quick start

With `.env` filled in (from `.env.example`) and the shared installs in place:

```bash
cp .env.example .env     # set CLUSTER_NAME and AWS_REGION
./scripts/setup.sh
kubectl -n coding-agents-for-developers port-forward svc/agent-app 8080:8080
```

Then open <http://127.0.0.1:8080>.

```text
TODO: output from the fresh run
```

**Step 1: The shared installs.** `setup.sh` checks for agent-sandbox, the EFS CSI driver
(3.0.0 or newer, for S3 Files) and network policy enforcement, and stops with the command to
add any that is missing. It never installs a cluster-wide thing for you. If you have run
Getting started and the storage samples, they are already there.

**Step 2: The AWS resources.** `setup.sh` creates the sample's own versioned S3 bucket, its
S3 Files file system and mount targets, and three IAM roles, each with only what it needs:

| Role | Used by | May |
|---|---|---|
| Bedrock | Every CLI pod that uses Bedrock, through Pod Identity | `bedrock:InvokeModel*`, and nothing else; no S3 Files access |
| App | The web app, through Pod Identity | Create, tag and delete this file system's access points; create and delete objects under session prefixes; assume the Mount role |
| Mount | Assumed only by the app, narrowed per session | `s3files:ClientMount` and `s3files:ClientWrite` on the file system, and read objects in the bucket; each session policy narrows it to one access point |

Everything it creates is tagged `ManagedBy=coding-agents-for-developers`, so the clean up
removes only what the sample made.

**Step 3: The images.** `setup.sh` builds the base image, the six CLI images and the app,
and pushes them to ECR.

**Step 4: The templates, pools and app.** For each CLI it applies a `SandboxTemplate`, a
`SandboxWarmPool` and an egress policy, then the app's Deployment, Service and RBAC. The
warm pods boot with no workspace; the folder is mounted after the claim (see
[How a session starts](#how-a-session-starts)).

**Step 5: Open the app.** `kubectl port-forward` to the ClusterIP Service, then the browser.
The sign-in is a drop-down of three demo developers with the password pre-filled: it is a
picker, not authentication, and the app is reachable only through your own port-forward.

```text
TODO: output from the fresh run
```

## How a session starts

A warm pod boots before its session exists, and a `SandboxClaim` that adds a volume forces a
cold start, so the warm pods boot with no workspace and idle. New agent and Restore both go
through the same steps:

1. The app claims a pod from the CLI's pool. The claim adopts a pod that is already running,
   so it is Ready in under a second; the pool boots a replacement.
2. The app creates the session's access point (or finds it, on restore), rooted at
   `/<developer>/<session>` with a fixed POSIX user. Because an S3 Files access point does
   not create its own root directory, the app creates the session's folder in the bucket
   first, with the App role.
3. The app assumes the Mount role with a session policy that names only that access point,
   and writes the resulting short-lived credential into the pod through the exec API's
   standard input, to a memory-backed file. It is never on a command line or in the pod
   spec.
4. Inside the guest, `session-entrypoint.sh` mounts the access point at `/workspace` with the
   S3 Files mount helper and that credential. Only this step runs as root, with the
   `SYS_ADMIN` capability the mount needs. Then tmux and the CLI start as an unprivileged
   user whose home sits inside `/workspace`, so its settings, sign-in and history persist
   with the code.
5. While the session runs, the app refreshes the credential before it expires.

The mount needs root inside the guest, which is what the sandbox is for: the guest kernel
belongs to the pod, not the node.

```text
TODO: output from the fresh run
```

## The session lifecycle

| Action | What happens |
|---|---|
| New agent | The app claims a warm pod, creates the access point, mounts the folder and starts the CLI. The pool boots a replacement. |
| Minimize, or close the browser | Nothing changes in the cluster. The pod and the CLI keep running. |
| No terminal activity for the idle period (default 30 minutes) | The app reads tmux's last-activity time in each pod every minute. Once the period passes, it deletes the `SandboxClaim`: the pod goes, the folder stays. |
| Close the window | Same as idle: the claim is released, the folder stays, and the session moves to the session list. |
| Restore | The app claims a new warm pod (a new pod UID), mounts the same folder and starts the CLI with its own resume option. |
| Delete | The app removes the access point and the session's prefix in the bucket. |

The session list is built from the access-point tags (the developer, the CLI, the session
name and when it was last used), so the app keeps no database.

```text
TODO: output from the fresh run
```

## It runs in a sandbox

Each session pod is a Nitro sandbox. Read its runtime class, the kernel and disks it sees,
and which model credentials it holds. The last command prints variable names only:

```bash
POD=$(kubectl -n coding-agents-for-developers get pods -l agent-cli=claude-code \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n coding-agents-for-developers get pod $POD -o jsonpath='{.spec.runtimeClassName}{"\n"}'
kubectl -n coding-agents-for-developers exec $POD -- sh -c 'uname -rv; cut -d" " -f1 /proc/uptime; ls /sys/block | tr "\n" " "; echo'
kubectl -n coding-agents-for-developers exec $POD -- sh -c 'env | cut -d= -f1 | grep -iE "^AWS_|BEDROCK|ANTHROPIC" || true'
```

```text
TODO: output from the fresh run
```

The sandbox runs its own kernel, its uptime matches the pod's age because the VM booted with
the pod, and it sees virtio disks (`vda`, `vdb`, `vdc`) where an ordinary pod on the same
node sees the instance's `nvme` devices. No model API key is in the pod: the Bedrock CLIs
sign their requests with the Pod Identity role, resolved from the pod's credential endpoint.

## Per-session scoping, both ways

The security property is that a session's pod can mount only its own folder. The app gives
each session a credential from the Mount role narrowed with this session policy (the whole
file is [`iam/mount-session-policy.json`](iam/mount-session-policy.json)); the condition key
`s3files:AccessPointArn` is what ties the credential to one access point:

```json
{
  "Sid": "MountOnlyThisSession",
  "Effect": "Allow",
  "Action": ["s3files:ClientMount", "s3files:ClientWrite"],
  "Resource": "arn:aws:s3files:<AWS_REGION>:<ACCOUNT_ID>:file-system/<S3_FILES_FS_ID>",
  "Condition": {
    "StringEquals": {
      "s3files:AccessPointArn": "arn:aws:s3files:<AWS_REGION>:<ACCOUNT_ID>:file-system/<S3_FILES_FS_ID>/access-point/<SESSION_AP_ID>"
    }
  }
}
```

To show it both ways, mount the session's own access point from inside its pod (it mounts),
then try another session's access point with the same credential, as root (it is refused):

```bash
TODO: command from the fresh run
```

```text
TODO: output from the fresh run
```

The pod's own Pod Identity role is the Bedrock role, which has no S3 Files permission at all,
so it cannot mount any access point. The mount credential is the only thing that can, and it
is scoped to one access point, so a pod cannot reach another session's folder even as root.

From outside the cluster, the bucket shows each session under its own prefix:

```bash
aws s3 ls s3://<S3_BUCKET_NAME>/coding-agents/ --recursive
```

```text
TODO: output from the fresh run
```

## How the network policy works

S3 Files cannot be used on a network-isolated pod, because the mount needs a network to
reach the mount target (Amazon EKS User Guide, *Isolated and confidential pods
limitations*). So the session pods have a network, and an egress policy is what limits where
code in the sandbox can connect. Each `SandboxTemplate` sets
`networkPolicyManagement: Unmanaged` and ships its own policy. Here is
[`egress-policy.yaml`](deploy/egress-policy.yaml) in full, without its header comment;
`setup.sh` fills in the mount-target addresses at apply time:

```yaml
apiVersion: networking.k8s.aws/v1alpha1
kind: ApplicationNetworkPolicy
metadata:
  name: agent-<CLI>-egress
spec:
  podSelector:
    matchLabels:
      agent-cli: <CLI>
  policyTypes:
    - Ingress
    - Egress
  ingress: []
  egress:
    - to:
        - ipBlock: { cidr: 0.0.0.0/0 }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to: <MOUNT_TARGET_CIDRS>
      ports:
        - { protocol: TCP, port: 2049 }
    - to:
        - ipBlock: { cidr: 169.254.170.23/32 }
      ports:
        - { protocol: TCP, port: 80 }
    - to:
        - domainNames:
            - s3.<AWS_REGION>.amazonaws.com
            - bedrock-runtime.<AWS_REGION>.amazonaws.com
            - github.com
            - codeload.github.com
            - objects.githubusercontent.com
            - registry.npmjs.org
            - pypi.org
            - files.pythonhosted.org
      ports:
        - { protocol: TCP, port: 443 }
```

| In the YAML | What it does |
|---|---|
| `podSelector`, `agent-cli: <CLI>` | Selects this CLI's session pods. |
| `policyTypes`, `Ingress` and `Egress` | Default-deny both ways, so only the rules below are allowed. |
| `ingress: []` | Denies all ingress. The app reaches the pod through the Kubernetes exec API, which is not pod network traffic, so it needs no ingress rule. |
| `egress` to `0.0.0.0/0` on 53 | DNS, to resolve every host below. A name lookup carries no data out, so the sample allows it broadly rather than pinning the CoreDNS address. |
| `egress` to `<MOUNT_TARGET_CIDRS>` on 2049 | The S3 Files mount targets, NFS over TLS. |
| `egress` to `169.254.170.23` on 80 | The Pod Identity agent on the node, for the Bedrock role. |
| `egress` to the `domainNames` on 443 | The S3 endpoint the mount helper reads objects from, the Bedrock runtime endpoint, and the developer hosts the agents fetch from. |

Enforcement is turned on once per cluster with the `amazon-vpc-cni` ConfigMap in
`kube-system`, which `setup.sh` checks and stops without if it is off. It is enforced on the
node, outside the guest, so a command in the sandbox, even as root, cannot change it. A
`domainNames` rule allows the addresses a name resolves to, so another name served from the
same addresses is reachable too; a pod can always reach its own node.

```text
TODO: output from the fresh run
```

## Good to know

- **The idle period and the pool size are settings.** The idle timeout is `IDLE_MINUTES` on
  the app (default 30). Each CLI's pool keeps `POOL_REPLICAS` pods warm (default 1); size it
  to the peak claim rate, not the number of sessions, and turn off the CLIs you do not need
  by trimming the app's agent list. Each warm pod reserves its full memory request.
- **Sessions are capped by the access-point quota.** Each retained session is one access
  point, kept until Delete. S3 Files allows 25,000 access points per file system (Amazon S3
  Files service quota *Access points per file system*, not adjustable), which is the ceiling
  on retained sessions; Delete reclaims one.
- **The credential is refreshed.** An assumed-role credential lasts an hour; the app rewrites
  it well before then, so an agent left running keeps writing to its folder past an hour.
- **The sign-in is a demo picker, not authentication.** The app is first-party code reachable
  only through `kubectl port-forward` on the operator's own machine.

## Clean up

Run the clean up when you finish, after your last session, so a sandbox pod is not left
holding capacity other demos share:

```bash
./scripts/clean.sh
```

It deletes in reverse order (the warm pools first, so they stop booting replacements, then
the claims, templates, policies and the app), removes only resources tagged
`ManagedBy=coding-agents-for-developers` (re-checking the bucket's tag before deleting it),
and exits non-zero if it skipped something or could not confirm a delete. It never removes a
shared install: agent-sandbox, the EFS CSI driver and network policy enforcement stay, and
the page above has the command to remove each if nothing else uses it. To remove the
namespace and the cluster, follow the
[hello sandbox clean up](../../getting-started/hello-sandbox/README.md#clean-up).
