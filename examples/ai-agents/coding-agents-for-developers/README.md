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
data each session keeps; the warm pools keep one pod per CLI running by default. Kiro CLI usage counts against the developer's own Kiro
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
  through EKS Pod Identity, with a role that may only invoke models (Codex's own role may
  also use Bedrock's server-side web search). Kiro CLI uses the developer's own Kiro
  sign-in, done once in the terminal and kept in the session's folder.

*Figure 1: A developer picks a CLI in the web app; the app claims a warm Nitro sandbox pod
from that CLI's pool, mounts the session's S3 Files folder into the guest with a credential
scoped to that one access point, and relays a terminal to a small server in the pod over the
pod network. The
pod reaches Amazon Bedrock through a Pod Identity role that may only invoke models; its
egress policy refuses everything else.*

![A developer, outside AWS, reaches the web app's terminal through kubectl port-forward. Inside the AWS Cloud, an Amazon EKS cluster holds the web app, an ordinary trusted first-party pod that claims a pod and drives the terminal. The app claims a red Nitro sandbox pod (isolated-sandbox, one per session) from a dashed SandboxWarmPool per CLI, and mounts the session folder into it with a per-session credential. A second arrow, labelled terminal (TLS), runs from the app to the sandbox pod, which runs tmux and the CLI, session-bridge on port 7681, and its workspace at /workspace. To the right, outside the cluster, it mounts its own S3 Files access point only (one per session), which syncs with an S3 bucket (one prefix per session), and it invokes models on Amazon Bedrock through a Pod Identity role that may only invoke models. Below, a red dashed arrow to the internet, AWS APIs and other pods is refused by the egress policy.](figures/architecture.png)

## Versions

This folder was built against these releases. Pin each to its latest when you build, and
the images record what they installed.

| Component | Version |
|---|---|
| agent-sandbox controller ([kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)) | v1.0.6 |
| S3 Files mount helper ([amazon-efs-utils](https://github.com/aws/efs-utils)) | 3.3.4 |
| Claude Code ([`@anthropic-ai/claude-code`](https://www.npmjs.com/package/@anthropic-ai/claude-code)) | 2.1.306 |
| Codex CLI ([`@openai/codex`](https://www.npmjs.com/package/@openai/codex)) | 0.163.0 |
| Kiro CLI ([kiro.dev](https://kiro.dev/docs/cli/)) | 3.0.0 |
| OpenCode ([`@opencode/cli`](https://www.npmjs.com/package/@opencode/cli)) | 2.1.2 |
| pi ([`@earendil-works/pi-coding-agent`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)) | 1.3.0 |
| oh-my-pi ([`@oh-my-pi/pi-coding-agent`](https://github.com/can1357/oh-my-pi)) | 18.12.5 |
| xterm.js ([`@xterm/xterm`](https://www.npmjs.com/package/@xterm/xterm)) | 6.0.0 |
| Go, to build `session-bridge` ([`golang`](https://gallery.ecr.aws/docker/library/golang) image) | 1.27 |

## Files

| File | What it is |
|---|---|
| [`app/`](app/) | The web app: the server ([`server/`](app/server/)) and the xterm.js UI ([`public/`](app/public/)), and its [`Dockerfile`](app/Dockerfile) |
| [`images/base/`](images/base/) | The shared base image: the S3 Files mount helper, tmux, git, [`session-entrypoint.sh`](images/base/session-entrypoint.sh), and [`session-bridge/`](images/base/session-bridge/main.go), the small server that gives the app the session's terminal |
| [`images/<cli>/`](images/) | One Dockerfile per CLI, each `FROM` the base |
| [`deploy/sandbox-template.yaml`](deploy/sandbox-template.yaml) | The per-CLI `SandboxTemplate` and `SandboxWarmPool` |
| [`deploy/egress-policy.yaml`](deploy/egress-policy.yaml) | The per-CLI egress policy |
| [`deploy/rbac.yaml`](deploy/rbac.yaml), [`deploy/app.yaml`](deploy/app.yaml) | The service accounts and RBAC, and the app Deployment and Service |
| [`iam/`](iam/) | The Bedrock, Codex, App and Mount role policies and trusts, and the per-session mount session policy |
| [`scripts/setup.sh`](scripts/setup.sh), [`scripts/clean.sh`](scripts/clean.sh) | Create everything and apply it; remove it |
| `.env.example` | The local values the sample needs; copy to `.env`, which git ignores |

## Quick start

With `.env` filled in (from `.env.example`) and the shared installs in place:

```bash
cp .env.example .env     # set CLUSTER_NAME and AWS_REGION
./scripts/setup.sh
kubectl -n coding-agents-for-developers port-forward svc/agent-app 8080:8080
```

Then open `http://127.0.0.1:8080`. Pick a CLI under **Start an agent** to open a terminal;
your sessions are listed below, each with **Open** (while running) or **Restore** (once
idle) and **Delete**.

![The web app. A "Start an agent" row of six tiles -- claude-code, codex, kiro-cli, opencode, pi, oh-my-pi -- each labelled "New agent". Below, a "Your sessions" table lists several sessions with their CLI and status, each row with a Restore and a Delete button.](figures/screenshots/launcher-and-sessions.png)

**Step 1: The shared installs.** `setup.sh` checks for agent-sandbox, the EFS CSI driver
(3.0.0 or newer, for S3 Files) and network policy enforcement, and stops with the command to
add any that is missing. It never installs a cluster-wide thing for you. If you have run
Getting started and the storage samples, they are already there.

**Step 2: The AWS resources.** `setup.sh` creates the sample's own S3 bucket, its S3 Files
file system and mount targets, the four IAM roles below, each with only what it needs, and
the role S3 Files itself assumes to sync the file system with the bucket. The bucket
has S3 Versioning turned on because S3 Files requires it to sync the file system with the
bucket ([S3 Files prerequisites](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-files-prereq-policies.html)).
The sessions do not use the versions, but a deleted or overwritten file leaves one behind,
which is why Delete removes every version under the session's prefix.

| Role | Used by | May |
|---|---|---|
| Bedrock | The pods of claude-code, opencode, pi and oh-my-pi (service account `agent-session`), through Pod Identity | `bedrock:InvokeModel*` scoped to this account's inference profiles and the Anthropic foundation models; nothing else, no S3 Files access |
| Codex | Codex's pods only (service account `agent-session-codex`), through Pod Identity | `bedrock-mantle:CreateInference` for its model on the Bedrock "Mantle" endpoint, and the `bedrock-websearch` actions for its server-side web search; nothing else, no S3 Files access |
| App | The web app, through Pod Identity | Create (with tags), list and delete this file system's access points; list and delete object versions under the sample's prefix when a session is deleted; assume the Mount role |
| Mount | Assumed only by the app, narrowed per session | `s3files:ClientMount` and `s3files:ClientWrite` on the file system, and read objects in the bucket; each session policy narrows it to one access point |

kiro-cli's pods have no role: they run as service account `agent-session-kiro`, which has
no Pod Identity association, because Kiro CLI signs in with the developer's own Kiro
identity rather than AWS credentials.

Everything it creates is tagged `ManagedBy=coding-agents-for-developers`, so the clean up
removes only what the sample made.

**Step 3: The images.** `setup.sh` builds the base image, the six CLI images and the app,
and pushes them to ECR under a fixed tag, `IMAGE_TAG` in `.env` (default `v1`). The pods
use `imagePullPolicy: IfNotPresent`, so a node that already pulled a tag keeps its cached
copy: after you change an image, set a new tag (for example `v2`) and run `setup.sh` again.

**Step 4: The templates, pools and app.** For each CLI it applies a `SandboxTemplate`, a
`SandboxWarmPool` and an egress policy, then the app's Deployment, Service and RBAC. The
warm pods boot with no workspace; the folder is mounted after the claim (see
[How a session starts](#how-a-session-starts)).

**Step 5: Open the app.** `kubectl port-forward` to the ClusterIP Service, then the browser.
The sign-in is a drop-down of three demo developers with the password pre-filled: it is a
picker, not authentication, and the app is reachable only through your own port-forward.

```text
==> Wait for the warm pools, then open the app
sandboxwarmpool.extensions.agents.x-k8s.io/agent-claude-code condition met
sandboxwarmpool.extensions.agents.x-k8s.io/agent-codex condition met
sandboxwarmpool.extensions.agents.x-k8s.io/agent-kiro-cli condition met
sandboxwarmpool.extensions.agents.x-k8s.io/agent-opencode condition met
sandboxwarmpool.extensions.agents.x-k8s.io/agent-pi condition met
sandboxwarmpool.extensions.agents.x-k8s.io/agent-oh-my-pi condition met
deployment "agent-app" successfully rolled out

Done. Open the app on your machine:

  kubectl --context <CLUSTER_NAME> -n coding-agents-for-developers port-forward svc/agent-app 8080:8080

Then browse to http://127.0.0.1:8080
```

`setup.sh` prints your `CLUSTER_NAME` where this shows `<CLUSTER_NAME>`.

## What a session looks like

Each terminal is a floating window wired to the CLI running in its sandbox pod. These are
the six CLIs answering the same prompt, each on its own model: the five Bedrock CLIs on the
inference profile in the app's agent list (Claude Sonnet here), and Codex on a GPT model
served through the Bedrock "Mantle" OpenAI-compatible endpoint. These screenshots are from
earlier runs of this sample. On the fresh run, each of the five Bedrock CLIs completed turns
in the Restore check below, Codex also ran a shell command for you (see
[Good to know](#good-to-know)), and Kiro CLI stopped at its sign-in menu, since its
sign-in is the developer's own rather than Bedrock:

```text
? Select login method ›
❯ Use with Builder ID
  Use with Google
  Use with GitHub
  Use with Your Organization
```

A second fresh run of the same code (after the clean up, `setup.sh` again) then had a
developer sign in from that menu with their own Kiro identity and ask one question. The
terminal, abridged to the turn:

```text
  In one sentence what is EKS Auto Mode
• EKS Auto Mode is an Amazon EKS feature that fully automates cluster
  infrastructure management — including compute provisioning, scaling, and
  updates — so you don't have to manage EC2 nodes manually.
▸ Credits: turn 0.06 • session 0.06 | Time: 1s
```

The terminal has tmux mouse mode on (`set -g mouse on` in the session's tmux config), so
the mouse wheel scrolls the CLI's output in the browser rather than its prompt history.

| | |
|---|---|
| ![claude-code answering "In one sentence, what is EKS Auto Mode?" -- the Claude Code banner shows Sonnet 5.5 and Amazon Bedrock, and a one-paragraph answer about AWS managing the cluster's data plane.](figures/screenshots/claude-code.png) | ![codex answering the same prompt -- the status line shows GPT-5.6 on the amazon-bedrock provider, with a one-sentence answer about EKS Auto Mode managing compute, networking, storage and load balancing.](figures/screenshots/codex.png) |
| ![opencode answering the same prompt -- the status line shows Claude Sonnet 5.5 (US) on Amazon Bedrock with the token cost, and a one-paragraph answer.](figures/screenshots/opencode.png) | ![pi answering the same prompt -- the status line shows us.anthropic.claude-sonnet-5-5 and the token cost, with a one-paragraph answer.](figures/screenshots/pi.png) |
| ![oh-my-pi answering the same prompt -- the status line shows Sonnet 5.5 (US) and the cost, with a one-paragraph answer.](figures/screenshots/oh-my-pi.png) | ![kiro-cli V3 answering the same prompt -- signed in through the developer's own Kiro sign-in (not Amazon Bedrock), with a one-sentence answer that EKS Auto Mode automates cluster infrastructure management (compute provisioning, scaling and updates) so you do not manage EC2 nodes manually.](figures/screenshots/kiro-cli.png) |

## How a session starts

A warm pod boots before its session exists, and a `SandboxClaim` that adds a volume forces a
cold start, so the warm pods boot with no workspace and idle. That is why this sample has no
PersistentVolumeClaim: the session's folder is an S3 Files access point that the pod mounts
itself, after the claim.

*Figure 2: Claims and warm pools. Each session is a SandboxClaim that adopts a pod its CLI's
warm pool already has Ready, and the pool boots a replacement. The claim carries no volume,
because a volume would force a cold start, so the workspace is mounted inside the pod after
the claim.*

![Inside the AWS Cloud, an Amazon EKS cluster holds the namespace coding-agents-for-developers. On the left, the web app, an ordinary trusted first-party pod, makes one claim per session. An arrow labelled "1. claim a sandbox (New agent, Restore)" runs from the web app to a SandboxClaim named agent- plus the session name, with warmPoolRef naming the CLI's pool. The claim sits in a dashed group, the agent-sandbox controller, which also holds the CLI's SandboxWarmPool (replicas 1) and its SandboxTemplate; there is one such pair for each of the six CLIs. An arrow labelled "2. under a second: adopt a Ready pod" runs from the claim to the warm pool, and another runs from the claim down to the claimed pod. Below, a red frame holds the Nitro sandbox pods, isolated-sandbox, booted with no volume: the claimed pod, the session's pod with its workspace mounted after the claim, and a warm pod, Ready and waiting, which the pool boots along an arrow labelled "refill: boot a replacement". A dashed grey arrow from the web app to a box labelled "cold start, not taken in this sample" reads "no volume on the claim: a volume would force a cold start".](figures/claims-and-warm-pools.png)

New agent and Restore both go through the same steps:

1. The app claims a pod from the CLI's pool. The claim adopts a pod that is already running,
   so it is Ready in under a second; the pool boots a replacement.
2. The app creates the session's access point (or finds it, on restore), rooted at
   `/<developer>/<cli>/<session>` with a fixed POSIX user (uid/gid 1000) and
   `creationPermissions` that make the access point create its own root directory owned by
   that user. The app does not pre-create the folder as a bucket object: an object written
   under the prefix first is imported owned by root, which the access point's user could not
   then write, so the CLI's home could not be created.
3. The app assumes the Mount role with a session policy that names only that access point,
   and writes the resulting short-lived credential into the pod through the exec API's
   standard input, to a memory-backed file, together with a fresh token for the pod's
   `session-bridge`. Neither is ever on a command line or in the pod spec.
4. Inside the guest, `session-entrypoint.sh` mounts the access point at `/workspace` with the
   S3 Files mount helper and that credential. Only this step runs as root, with the
   `SYS_ADMIN` capability the mount needs. Then tmux and the CLI start as an unprivileged
   user whose home is `/workspace/home`, so its settings, sign-in and history persist with
   the code. The CLI starts in `/workspace/project`, a folder of its own: Claude Code keeps
   its answer to "do you trust this folder?" per folder, but not for the home directory,
   so started in its home it asked again on every Restore.
   Before tmux and the CLI start, the entrypoint starts `session-bridge`, which the next
   section describes, and the app reads back the certificate it made.
5. While the session runs, the app refreshes the credential before it expires, through
   `session-bridge`.

### How the terminal reaches the pod

Each session pod runs `session-bridge`, a small server built from
[`images/base/session-bridge/`](images/base/session-bridge/main.go) with the Go standard
library only. The app reaches it directly on the pod network, on TCP 7681, for the three
things a session needs while it runs:

| Request | What it does |
|---|---|
| `GET /v1/terminal` | A WebSocket to a PTY running `tmux attach` as the session's user. The app relays the browser's terminal to it, keystrokes and resizes both ways. |
| `GET /v1/activity` | The last time the terminal had input or output, which the app reads every minute to find idle sessions. |
| `PUT /v1/credential` | Replaces the session's mount credential. It accepts only a well-formed credential, so a bad request leaves the running one in place. |

The app uses the Kubernetes exec API only at the edges of a session: two calls to start it
(run the entrypoint, then read back the bridge's certificate) and one to stop it, plus one
per running pod after an app restart (below). So the traffic between the app and a running
session's pod, however many developers have terminals open, does not go through the API
server. The browser's own connection to the app still does in this sample, because it
comes in through `kubectl port-forward`; a deployment that puts an authenticated endpoint
in front of the app takes the API server off that leg too.

- **Only the app can connect.** The pod's policy admits ingress from the app's pods on 7681
  and nothing else, so another session's pod, or any other pod, is refused at the network.
- **Only this session's token is accepted.** The app makes a fresh token for each session
  start and hands it over on the start exec's standard input. The pod keeps it in a
  root-only file; the CLI runs as uid 1000 and cannot read it.
- **The connection is pinned.** At start the bridge makes its own TLS key and a self-signed
  certificate, and writes only the certificate to a root-only file. The app reads it once,
  over exec, and trusts that one certificate and nothing else, so code in the sandbox cannot
  stand in for the bridge: it has neither the key nor a way to replace the certificate.
- **It starts before the CLI.** The bridge holds its port before any code in the sandbox
  runs, and a warm pod that no session has claimed listens on nothing.

After an app restart, the app reads each running pod's token and certificate back over exec,
once, so the sessions it picks up keep their terminals.

On a run of this sample, codex in the sandbox echoed a keystroke in 18.9 ms (median) from
inside its own pod, 23.9 ms from the app through `session-bridge`, and 25.9 ms from the app
over the exec API. The terminal is not faster for leaving the exec API: what changes is that
the API server is off the path between the app and the pod. What a developer feels is one
round trip from the browser to the cluster's Region, through `kubectl port-forward`.

*Figure 3: How a session's folder reaches its pod. The pod boots with no folder. The web app
hands it a short-lived credential that can mount only that session's S3 Files access point,
so any other session's access point is refused.*

![The AWS Cloud holds an Amazon EKS cluster on the left and the session's storage on the right. In the cluster, the web app runs as an ordinary, trusted first-party pod whose own Pod Identity role can create, list and delete access points. Beside it, a dashed SandboxWarmPool for the CLI holds a Nitro sandbox pod, isolated-sandbox, booted with no folder. The web app's arrow "1. claim a warm pod" goes to that pod. Its arrow "2. create or find the access point" goes to the session's S3 Files access point, rooted at the developer, CLI and session path, with POSIX user uid and gid 1000. Its arrow "3. assume the Mount role, scoped to one access point" goes to the Mount role, whose credential expires in 60 minutes. Two more arrows go from the web app to a short-lived credential kept in a memory-backed file inside the pod: "4. credential over exec stdin" and "refresh every 30 min". Inside the pod the credential feeds the session entrypoint, which mounts as root with SYS_ADMIN; its arrow "5. mount at /workspace" goes to the access point, and it then starts tmux and the CLI as uid 1000 with its home in /workspace. The access point syncs with a versioned S3 bucket that holds one prefix per session. A red dashed arrow from the pod to other sessions' access points is labelled refused.](figures/session-start.png)

The mount needs root inside the guest, which is what the sandbox is for: the guest kernel
belongs to the pod, not the node.

```text
POST /api/new
/api/new developer=carlos cli=opencode
start mvltsxn1-calm-tapir: ensureAccessPoint
start mvltsxn1-calm-tapir: claimPod (ap=fsap-0f915406942f92491)
start mvltsxn1-calm-tapir: pod=agent-opencode-5gls5 node=i-008d8e6f8738ef2d0
start mvltsxn1-calm-tapir: startSession azId=usw2-az3
session started in agent-opencode-5gls5
/api/new done session=mvltsxn1-calm-tapir
```

## The session lifecycle

A session pauses and resumes by releasing its claim and claiming a new one: the pod is
disposable, the folder is not.

*Figure 4: Pause and resume a session. Close or idle removes the claim and the pod, Restore
mounts the same folder in a new pod, and only Delete removes the folder.*

![Four stages of a session, left to right, above a shared storage row. The storage row, "Session folder, outlives every pod; only Delete removes it", holds the session's S3 Files access point, which syncs with the versioned S3 bucket, one prefix per session. Stage a, Running: a SandboxClaim points to a Nitro sandbox pod with pod UID A, isolated-sandbox, running the CLI in tmux with the folder at /workspace, and an edge labelled "mount at /workspace" runs down to the access point. A note says minimizing or closing the browser changes nothing in the cluster. An arrow labelled "Close, or idle 30 min: delete the SandboxClaim" leads to stage b, Paused: no SandboxClaim and no pod, while the access point and its data in S3 stay. An arrow labelled "Restore: claim a new warm pod" leads to stage c, Restored: a new SandboxClaim points to a new pod with pod UID B, which mounts the same access point, and the CLI resumes the last chat with its own continue option, reading its history from its home inside the folder. An arrow labelled Delete runs from Paused to stage d, Deleted: the access point, then every object version and delete marker under the session prefix, is deleted, and nothing remains.](figures/session-lifecycle.png)

| Action | What happens |
|---|---|
| New agent | The app claims a warm pod, creates the access point, mounts the folder and starts the CLI. The pool boots a replacement. |
| Minimize, or close the browser | Nothing changes in the cluster. The pod and the CLI keep running. |
| No terminal activity for the idle period (default 30 minutes) | The app reads, every minute, the last time each session's terminal had key input or printed output (tmux's `session_activity` and `window_activity`). An agent still working on its own keeps printing, so it is not idle; a CLI waiting at its prompt prints nothing. Once the period passes, it stops the session cleanly (below) and deletes the `SandboxClaim`: the pod goes, the folder stays. |
| Close the window | Same as idle: the session is stopped and the claim released, the folder stays, and the session moves to the session list. |
| Restore | The app claims a new warm pod (a new pod UID), mounts the same folder and starts the CLI with its own continue-the-last-conversation option: `claude --continue`, `codex resume --last`, `kiro-cli chat --v3 --resume`, `opencode --continue`, `pi --continue` and `omp --continue`. The history is in the CLI's home inside the folder, so it comes back with it; a session restored before its first prompt starts the CLI fresh. |
| Delete | The app deletes the access point first, so nothing can mount the folder again, then every object version and delete marker under the session's prefix in the (versioned) bucket. S3 Files exports writes to the bucket asynchronously, so a write made just before Delete can arrive after the drain: the app lists the prefix again every 20 seconds and deletes whatever came back, until two lists in a row are empty. If objects keep coming back, or a delete fails, it puts the access point back, so the session stays in the list and Delete can be retried, and returns the error. |

On the fresh run, a pi session wrote 30 files into its folder and was deleted straight
away. The exports kept arriving after the first drain, and the app log shows each round
that found something:

```text
session mvlthlq3-quiet-crane: stopped in agent-pi-qmjnq
delete mvlthlq3-quiet-crane: removed 16 version(s) in round 1
delete mvlthlq3-quiet-crane: removed 1 version(s) in round 2
delete mvlthlq3-quiet-crane: removed 10 version(s) in round 4
delete mvlthlq3-quiet-crane: removed 20 version(s) in round 5
```

Rounds 6 and 7 found nothing, so Delete returned (`{"ok":true}`, after 122 seconds).
Afterwards `get-access-point` for the session's access point answered
`ResourceNotFoundException`, and `list-object-versions` for its prefix found no versions
and no delete markers.

Before it releases a pod, the app runs `session-stop.sh` in it through the exec API: it
ends every process of the session's user, then unmounts `/workspace`. The CLIs keep SQLite
databases and lock files in their home on the S3 Files mount, and a lock on that mount is
a lease the server holds for the client. When a pod was deleted with the CLI still
running, nothing released those locks until the lease ran out, so a quick Restore found
the Codex conversation "open in another app" and opencode reported "database disk image
is malformed". Ending the processes first releases the locks at once. Every step of the
stop is bounded, so it ends within about 90 seconds: TERM, then KILL after 10 seconds, a
`sync` of at most 30 seconds, then the unmount, retried for up to 30 seconds while the mount
finishes closing files. It usually takes a second or two. If the stop fails, the app logs
it and releases the pod anyway.

What the app cannot read or do, it reports rather than assumes. If it cannot read a
session's activity time, it logs the failure and keeps the session; only a pod whose tmux
session is gone counts as idle since it started. If the `SandboxClaim` cannot be deleted,
Close and Delete return the error, the app keeps the session in its list so the next
minute's check retries the release, and Delete leaves the folder in place.

New agent is fast because the pod is already warm. On the fresh run, the time from the
click (`POST /api/new`) to a terminal with the CLI running was:

| New agent | Time |
|---|---|
| The first session on a new file system (codex, from the browser) | 17.5 s |
| Each later session, from a warm pod (kiro-cli, claude-code, opencode, oh-my-pi, pi) | 1.9 to 3.4 s |
| A second claude-code session while its pool of one was still refilling | failed after 120 s |
| Restore, from a warm pod, for each of the five Bedrock CLIs | 1.3 to 4.4 s |

The first session is slower because it is the first mount of a new file system. The third
row is a cold start: with the warm pod already claimed, the claim makes a pod of its own,
and on the fresh run the cluster had no free memory for it (`0/4 nodes are available: 2
Insufficient memory`), so it waited for EKS Auto Mode to add a node, longer than the app's
120-second limit. The app then released the claim and returned the error; the session's
folder stayed, so it was listed as idle, and its Restore took 1.4 s once the pool had a
warm pod again. Two Restores on the same run hit the same wait, and passed when retried.
So size `POOL_REPLICAS` to the rate at which sessions start, and expect a start that finds
both the pool and the cluster full to fail rather than wait for a node. While a start is
in flight, its tile reads **Starting...** and ignores further clicks, so a second click
does not claim a second pod; if the start fails, the tile shows the error and the next
click tries again.

Close then Restore is the same path against the existing folder, so a restored session comes
up on a **new pod** (a new pod UID) and the CLI continues its conversation. For pi on the
fresh run (abridged to the lines that matter; the prompts were typed into the terminal):

```text
before: pod=agent-pi-tzm6p uid=b22ffe6e-8ff5-4351-94fa-a3fbf429451f
 Remember the code word FINCH-9. Reply with only: noted.
 noted.
POST /api/close   -> {"ok":true}                                                                    HTTP 200 in 0.663697s
POST /api/restore -> {"error":"claim agent-mvltt29k-nimble-heron did not resolve to a ready pod in time"}   HTTP 500 in 120.351248s
POST /api/restore -> {"session":"mvltt29k-nimble-heron","display":"nimble-heron","cli":"pi"}           HTTP 200 in 3.675040s
after: pod=agent-pi-kh9gs uid=46ed4ff2-4ffe-4f48-832c-a28508923430
 What code word did I ask you to remember? Reply with only the word.
 FINCH-9
```

The first Restore found the pi pool and the cluster both full and failed at the app's
120-second limit (see the timings above); the second, once a node had been added and the
pool had a warm pod, came back on a new pod with the conversation intact. The same check
passed for claude-code (also on its second Restore, for the same reason), codex, opencode
and oh-my-pi on the same run, each on a new pod UID.

Close works on any running session, including one the app did not start itself. On start,
the app lists the sample's `SandboxClaim`s and picks up each session that still has a pod
and an access point, so a session keeps its idle check and credential refresh across an
app restart. On the fresh run, the app pod was restarted with three sessions running, and
its log showed:

```text
session mvltgu4k-clever-tapir: picked up after an app restart (pod agent-codex-jssg7)
session mvlthr1m-clever-lynx: picked up after an app restart (pod agent-mvlthr1m-clever-lynx)
session mvltkhlp-merry-heron: picked up after an app restart (pod agent-kiro-cli-b5wfm)
picked up 3 running session(s) after start
session mvltgu4k-clever-tapir: mount credential refreshed
session mvlthr1m-clever-lynx: mount credential refreshed
session mvltkhlp-merry-heron: mount credential refreshed
```

Nobody had re-opened those sessions. Closing `clever-lynx` afterwards stopped its CLI
(`session mvlthr1m-clever-lynx: stopped in agent-mvlthr1m-clever-lynx`), deleted its
claim, and left it in the list as idle, with its folder.

Minimizing a window or closing the browser only detaches the terminal; the CLI keeps
running in tmux in its pod. On an earlier run of this sample, claude-code was asked to print a timestamp
every 10 seconds for two minutes, and the browser was closed at 20:04:25, about 20 seconds
in. The CLI kept working with no browser attached (the app was opened briefly at 20:05:40,
while the task was still running), and when it was opened again at 20:07 the task had
finished:

![The claude-code window for session clever-wombat, opened again after the browser was closed. Below the request to run a loop printing a tick every 10 seconds, Claude reports that the command ran to completion and that all 12 ticks printed, 10 seconds apart, from 20:04:03 to 20:05:53 UTC, and the turn shows done at 8:06 PM.](figures/screenshots/output-while-browser-closed.png)

Two sessions open at once, with the claude-code window minimized to the dock at the bottom
and the opencode window open over the session list:

![The web app with an opencode window for session proud-vole open, showing its restored conversation about the code word OTTER-3. At the bottom of the page, a dock holds one chip, "claude-code · gentle-otter", the minimized window of a second session.](figures/screenshots/two-sessions-one-minimized.png)

The app keeps no database. It builds the session list from the access points' own root
paths -- each one is `/<developer>/<cli>/<session>`, so one `ListAccessPoints` call for the
file system yields every session's developer, CLI and name with no per-session tag read
(which matters at scale: a developer with thousands of sessions would otherwise be thousands
of tag lookups against the S3 Files control-plane rate limit). The session name carries a
creation-time prefix, so the list sorts newest-first from the path alone. The access points
also carry tags (`ManagedBy`, `developer`, `cli`, `session`, `lastUsed`) that mark ownership
for the clean up, but the list does not depend on them. The access points, one per session:

```text
$ aws s3files list-access-points --file-system-id <S3_FILES_FS_ID> --region <AWS_REGION> \
    --query 'accessPoints[].{id:accessPointId,path:rootDirectory.path}' --output table
-------------------------------------------------------------------------
|                           ListAccessPoints                            |
+-------------------------+---------------------------------------------+
|           id            |                    path                     |
+-------------------------+---------------------------------------------+
|  fsap-0f915406...       |  /carlos/opencode/mvltsxn1-calm-tapir       |
|  fsap-06785465...       |  /priya/oh-my-pi/mvltt0an-gentle-vole       |
|  fsap-0e1553a1...       |  /carlos/claude-code/mvltsw76-eager-marten  |
|  fsap-0cd3c381...       |  /sam/kiro-cli/mvltkhlp-merry-heron         |
|  fsap-0cb55b1b...       |  /priya/pi/mvltt29k-nimble-heron            |
|  fsap-0611c55d...       |  /carlos/codex/mvltgu4k-clever-tapir        |
|  fsap-069ccc47...       |  /carlos/pi/mvlthr1m-clever-lynx            |
|  fsap-0be84e10...       |  /sam/claude-code/mvltt8t6-lively-fox       |
+-------------------------+---------------------------------------------+
```

The access-point ids are shortened here; the command prints them in full.

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
isolated-sandbox
6.18.51 #1 SMP PREEMPT_DYNAMIC Thu Oct  1 23:28:07 UTC 2026
202.28
dm-0 vda vdb vdc
AWS_CONTAINER_CREDENTIALS_FULL_URI
AWS_DEFAULT_REGION
AWS_REGION
AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE
CLAUDE_CODE_USE_BEDROCK
ANTHROPIC_MODEL
AWS_STS_REGIONAL_ENDPOINTS
```

The first four lines are from the fresh run. The variable names are from an earlier run of
this sample: on the fresh run they were read from the pod spec and the image instead, and
the set was the same (`AWS_STS_REGIONAL_ENDPOINTS`, `AWS_DEFAULT_REGION`, `AWS_REGION`,
`AWS_CONTAINER_CREDENTIALS_FULL_URI` and `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` from the
pod spec; `CLAUDE_CODE_USE_BEDROCK` and `ANTHROPIC_MODEL` among the image's).

The same commands in the app's pod, an ordinary pod with no runtime class, on a node of the
same cluster:

```text
6.18.51 #2 SMP PREEMPT_DYNAMIC Wed Oct  7 22:33:11 UTC 2026
117374.72
dm-0 nvme0n1 nvme1n1 nvme2n1 zram0
```

The sandbox runs its own kernel build (`#1`, built Oct 1; the node's is `#2`, built Oct 7),
its uptime of 202 seconds matches the pod's age (it started 204 seconds before the command)
because the sandbox booted with the pod (the node has been up for 32 hours), and it sees virtio disks (`vda`, `vdb`, `vdc`, with a
`dm-0` device-mapper node on top) where the ordinary pod sees the instance's `nvme`
devices. No model API
key is in the pod: the only AWS variables are the Pod Identity credential endpoint
(`AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`) and the
Region, so the Bedrock CLIs sign their requests with the Pod Identity role resolved from
that endpoint, not a stored key.

## Can one developer reach another developer's files?

It depends on the layer.

- **From an agent's pod: no.** Isolation is per session, which is stricter than per
  developer: a pod can mount only its own session's folder, so not another developer's, and
  not another session of the same developer either. The credential that mounts the folder is
  scoped to that one access point, the pod's own role has no S3 Files access at all, and the
  pods' policy admits ingress only from the app, to `session-bridge`, so session pods cannot
  reach each other. The next section
  proves it, as root inside the sandbox.
- **Through this web app: yes, by design of the demo.** The sign-in is a picker, not
  authentication, so anyone who can reach your `kubectl port-forward` can pick any developer
  and open, close or delete any session. The app checks only that each name is well formed.
- **For a real deployment**, put real authentication in front of the app, and check on every
  call that the session belongs to the signed-in developer. That includes the terminal
  WebSocket (`/ws`) and Close, which today take only a session name.

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
then try another session's access point with the same credential, as root (it is refused).
`$OTHER_AP` is a second session's access point id; the credential is the one the app wrote
to this pod at `/dev/shm/session/credentials`:

```bash
POD=agent-claude-code-...     # this session's pod
OTHER_AP=fsap-...             # a different session's access point

# This session's own access point is already mounted at /workspace:
kubectl -n coding-agents-for-developers exec $POD -- mountpoint /workspace

# Try another session's access point with this pod's own mount credential, as root:
kubectl -n coding-agents-for-developers exec $POD -- sh -c \
  "mkdir -p /tmp/other; id -u; AWS_SHARED_CREDENTIALS_FILE=/dev/shm/session/credentials AWS_PROFILE=session \
   mount.s3files <S3_FILES_FS_ID> /tmp/other \
   -o tls,iam,awsprofile=session,region=<AWS_REGION>,azid=<POD_AZ_ID>,accesspoint=$OTHER_AP; echo \"exit \$?\""

# Try this session's OWN access point with the pod's own Pod Identity role (no mount
# credential), as root:
OWN_AP=fsap-...               # this session's access point
kubectl -n coding-agents-for-developers exec $POD -- sh -c \
  "mkdir -p /tmp/own; mount.s3files <S3_FILES_FS_ID> /tmp/own \
   -o tls,iam,region=<AWS_REGION>,azid=<POD_AZ_ID>,accesspoint=$OWN_AP; echo \"exit \$?\""
```

```text
/workspace is a mountpoint

0
Could not start amazon-efs-mount-watchdog, unrecognized init system "sleep"
Mount attempt 1/3 failed due to b'mount.nfs4: access denied by server while mounting 127.0.0.1:/\n', wait 1 sec before next attempt.
Mount attempt 2/3 failed due to b'mount.nfs4: access denied by server while mounting 127.0.0.1:/\n', wait 2 sec before next attempt.
b'mount.nfs4: access denied by server while mounting 127.0.0.1:/'
exit 32

Could not start amazon-efs-mount-watchdog, unrecognized init system "sleep"
Mount attempt 1/3 failed due to b'mount.nfs4: access denied by server while mounting 127.0.0.1:/\n', wait 1 sec before next attempt.
Mount attempt 2/3 failed due to b'mount.nfs4: access denied by server while mounting 127.0.0.1:/\n', wait 1 sec before next attempt.
b'mount.nfs4: access denied by server while mounting 127.0.0.1:/'
exit 32
```

The own access point is mounted. As root (`id -u` prints `0`), the other session's access
point is refused by the server (`access denied`, exit 32), because the credential's session
policy allows `s3files:ClientMount` only on this session's own access-point ARN. The pod's
own Pod Identity role is refused even on its own access point (kiro-cli's pods have no role at all): it is the Bedrock role, with
no S3 Files permission at all (nor has the Codex role), so it cannot mount any access point. The mount credential is
the only thing that can, and it is scoped to one access point. (The watchdog line is the
mount helper noting that the container has no init system for its background watchdog; it
does not affect the mount.)

From outside the cluster, the bucket shows each session under its own prefix (abridged to
two sessions and their folder structure; the CLI's home fills in below each session, 1,324
objects across the eight sessions of the fresh run):

```bash
aws s3 ls s3://<S3_BUCKET_NAME>/coding-agents/ --recursive
```

```text
2026-10-24 03:06:06          0 coding-agents/carlos/
2026-10-24 03:15:13          0 coding-agents/carlos/claude-code/
2026-10-24 03:15:15          0 coding-agents/carlos/claude-code/mvltsw76-eager-marten/
2026-10-24 03:24:01          0 coding-agents/carlos/claude-code/mvltsw76-eager-marten/home/
2026-10-24 03:23:35        224 coding-agents/carlos/claude-code/mvltsw76-eager-marten/home/.tmux.conf
2026-10-24 03:15:20          0 coding-agents/carlos/claude-code/mvltsw76-eager-marten/project/
...
2026-10-24 03:08:41          0 coding-agents/sam/
2026-10-24 03:18:05          0 coding-agents/sam/claude-code/
2026-10-24 03:18:06          0 coding-agents/sam/claude-code/mvltt8t6-lively-fox/
2026-10-24 03:18:06          0 coding-agents/sam/claude-code/mvltt8t6-lively-fox/home/
2026-10-24 03:19:04        224 coding-agents/sam/claude-code/mvltt8t6-lively-fox/home/.tmux.conf
2026-10-24 03:18:06          0 coding-agents/sam/claude-code/mvltt8t6-lively-fox/project/
...
```

## How the network policy works

S3 Files cannot be used on a network-isolated pod, because the mount needs a network to
reach the mount target (Amazon EKS User Guide, *Isolated and confidential pods
limitations*). So the session pods have a network, and an egress policy is what limits where
code in the sandbox can connect. Each `SandboxTemplate` sets
`networkPolicyManagement: Unmanaged` and ships its own policy. Here is
[`egress-policy.yaml`](deploy/egress-policy.yaml) in full, without its header comment;
`setup.sh` fills in the mount-target addresses at apply time, and adds one extra rule for
kiro-cli (shown below the table):

```yaml
apiVersion: networking.k8s.aws/v1alpha1
kind: ApplicationNetworkPolicy
metadata:
  name: agent-<CLI>-egress
  labels:
    app.kubernetes.io/part-of: coding-agents-for-developers
spec:
  podSelector:
    matchLabels:
      agent-cli: <CLI>
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: agent-app
      ports:
        - { protocol: TCP, port: 7681 }
  egress:
    - to:
        - ipBlock: { cidr: 0.0.0.0/0 }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to:
        - ipBlock: { cidr: 169.254.170.23/32 }
      ports:
        - { protocol: TCP, port: 80 }
    - to:
        - domainNames:
            - bedrock-runtime.<AWS_REGION>.amazonaws.com
            - bedrock-mantle.<AWS_REGION>.api.aws
            - docs.aws.amazon.com
            - github.com
            - codeload.github.com
            - objects.githubusercontent.com
            - registry.npmjs.org
            - pypi.org
            - files.pythonhosted.org
      ports:
        - { protocol: TCP, port: 443 }
    - to: <MOUNT_TARGET_CIDRS>
      ports:
        - { protocol: TCP, port: 2049 }
```

| In the YAML | What it does |
|---|---|
| `podSelector`, `agent-cli: <CLI>` | Selects this CLI's session pods. |
| `policyTypes`, `Ingress` and `Egress` | Default-deny both ways, so only the rules below are allowed. |
| `ingress` from `app: agent-app` on 7681 | Admits the app's pods, to `session-bridge` only (see [How the terminal reaches the pod](#how-the-terminal-reaches-the-pod)). Everything else in is denied, including other session pods. The label is what the rule trusts, so whoever can create pods in this namespace can pass it; the bridge's token and pinned certificate still stand behind it. The session's start and stop use the Kubernetes exec API, which is not pod network traffic. |
| `egress` to `0.0.0.0/0` on 53 | Allows egress to any address on UDP and TCP 53. This is a project choice to keep the sample simple: it does not depend on how a given cluster serves DNS (on EKS Auto Mode the resolver is node-local rather than a pod behind a ClusterIP). What it allows is wider than DNS resolution: any process in the sandbox can reach any host on UDP or TCP 53, so it can send data out over DNS or to anything listening on port 53. What it costs is that port-53 egress is not confined to the cluster's own resolver. It still opens only port 53; every other port and protocol stays denied. |
| `egress` to `169.254.170.23` on 80 | The Pod Identity agent on the node, for the pod's role (the Bedrock role, or the Codex role for Codex). kiro-cli's pods have no role, so the agent gives them no credential. |
| `egress` to the `domainNames` on 443 | The Bedrock runtime endpoint the Bedrock CLIs call their model on, the Bedrock "Mantle" endpoint Codex uses for its GPT model, `docs.aws.amazon.com` so the agents can fetch AWS documentation, and the short list of developer hosts (GitHub, npm, PyPI) the agents fetch from. The S3 Files mount reads over NFS (2049), not an S3 443 endpoint, so none is needed here. |
| `egress` to `<MOUNT_TARGET_CIDRS>` on 2049 | The S3 Files mount targets, NFS over TLS. They are ENIs in the cluster VPC reached by resolved IP, so `setup.sh` resolves this file system's mount-target IPs and fills in one `/32` per target -- egress on 2049 is allowed to the sample's own mount targets only, not to anything on 2049 in the VPC. |

kiro-cli is the one CLI that does not use Amazon Bedrock: it reaches the developer's own
Kiro / Amazon Q Developer sign-in (IAM Identity Center OIDC) and the CodeWhisperer streaming
service on `*.amazonaws.com`, and the Kiro desktop service on `*.kiro.dev` (the sign-in
device-authorization flow at `prod.<region>.auth.desktop.kiro.dev`, plus `app.kiro.dev`,
`runtime.<region>.kiro.dev` and the telemetry hosts, which sit across several sub-hierarchies
of `kiro.dev`). Those endpoints live in the developer's Kiro Region, independent of this
cluster's Region, so `setup.sh` adds one rule to the kiro-cli policy only, allowing both
suffixes on 443 -- wide within AWS and within Kiro's own first-party domain, but no arbitrary
internet host. A deployment that wants it tighter can pin the exact
`oidc.`/`q.`/`codewhisperer.<region>.amazonaws.com` hosts and the specific `kiro.dev`
subdomains its Region and workflow use.

```yaml
    - to:
        - domainNames:
            - "*.amazonaws.com"
            - "*.kiro.dev"
      ports:
        - { protocol: TCP, port: 443 }
```

Enforcement is turned on once per cluster with the `amazon-vpc-cni` ConfigMap in
`kube-system`, which `setup.sh` checks and stops without if it is off. It is enforced on the
node, outside the guest, so a command in the sandbox, even as root, cannot change it. Its
limits: DNS is open on port 53 to any address, so a resolver is always reachable, and a pod
can always reach its own node; that also means port-53 egress is not confined to the
cluster's resolver, so a process in the sandbox can send data out over DNS or to anything
listening on port 53 (see the `0.0.0.0/0` row above). A `domainNames` rule allows the
addresses a name resolves to, so another name served from the same addresses is reachable
too. Everything beyond port 53, the allowed hosts and the mount targets is denied.

To see it from inside a session pod, connect to an allowed endpoint and to a denied one
(`curl` exits 0 once the TCP connection is established; exit 28 is a connect timeout, which
is how a blocked destination shows):

```bash
POD=$(kubectl -n coding-agents-for-developers get pods -l agent-cli=claude-code \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
for url in https://bedrock-runtime.<AWS_REGION>.amazonaws.com/ https://github.com/ \
           https://example.com/ https://github.com:22/; do
  kubectl -n coding-agents-for-developers exec $POD -- \
    sh -c "curl -sS -o /dev/null --connect-timeout 8 $url; echo \"$url -> exit \$?\""
done
```

```text
https://bedrock-runtime.<AWS_REGION>.amazonaws.com/ -> exit 0   # allowed host, 443: connected
https://github.com/ -> exit 0                                   # allowed host, 443: connected
curl: (28) Connection timed out after 8001 milliseconds
https://example.com/ -> exit 28                                 # host not in the policy: blocked
curl: (28) Connection timed out after 8002 milliseconds
https://github.com:22/ -> exit 28                               # allowed host, port 22 not allowed: blocked
```

The `#` comments are added here; the rest is the fresh run's output, where each `curl:`
error line goes to standard error and so can print before or after its exit line.

## Good to know

- **The idle period and the pool size are settings.** The idle timeout is `IDLE_MINUTES` on
  the app (default 30). Each CLI's pool keeps `POOL_REPLICAS` pods warm (default 1); size it
  to the peak claim rate, not the number of sessions, and turn off the CLIs you do not need
  by trimming the app's agent list. Each warm pod reserves its memory request.
- **The session pods request memory, and set nothing else.** A Nitro sandbox's memory comes
  from the pod's `resources.requests.memory` (Amazon EKS User Guide, *Isolated and
  confidential pods limitations*). With no request, a run of this sample gave each guest
  about 129 MiB (`MemTotal: 132568 kB`): Claude Code could not start, and exec into a Codex
  pod failed. So the `SandboxTemplate` requests 1536 MiB of memory, with no CPU request and
  no limits. The app's Deployment sets no `resources` at all. This is each CLI's pod 15
  seconds after the same long-answer prompt was sent to five of them on the fresh run
  (`kubectl top pod`):

  ```text
  NAME                         CPU(cores)   MEMORY(bytes)
  agent-app-796f6444c7-stbm8   0m           118Mi
  agent-claude-code-9bkpp      0m           0Mi
  agent-claude-code-bqzsh      1m           147Mi
  agent-claude-code-mhpfn      2m           177Mi
  agent-codex-c7nm9            0m           0Mi
  agent-codex-ck4xv            20m          404Mi
  agent-kiro-cli-b5wfm         1m           51Mi
  agent-kiro-cli-jhg97         0m           0Mi
  agent-oh-my-pi-8k6gx         0m           0Mi
  agent-oh-my-pi-jm2mn         22m          580Mi
  agent-opencode-fd9hb         4m           353Mi
  agent-opencode-t9jgf         0m           0Mi
  agent-pi-kh9gs               6m           94Mi
  agent-pi-l9qbd               0m           0Mi
  ```

  The claude-code (`mhpfn`), codex (`ck4xv`), oh-my-pi (`jm2mn`), opencode (`fd9hb`) and
  pi (`kh9gs`) pods had the prompt. `bqzsh` is a second claude-code session at its first-run
  screen, kiro-cli (`b5wfm`) is at its sign-in menu, and the pods at `0Mi` are warm pods
  waiting for a claim. The largest, oh-my-pi, used 580 MiB of its 1536 MiB request; on an
  earlier run, Codex reached 803 MiB during a turn.
- **Sessions are capped by the access-point quota.** Each retained session is one access
  point, kept until Delete. S3 Files allows 25,000 access points per file system (Amazon S3
  Files service quota *Access points per file system*, not adjustable), which is the ceiling
  on retained sessions; Delete reclaims one.
- **The credential is refreshed.** An assumed-role credential lasts an hour; the app rewrites
  it after 30 minutes, so an agent left running keeps writing to its folder past an hour. A
  refresh that fails is logged by the app with the session's name
  (`kubectl logs deploy/agent-app`) and retried every minute; if it kept failing until the
  hour ran out, the session's writes to its folder would start to fail. On the fresh run, a
  kiro-cli session started at 03:08 UTC; the app was restarted at 03:13 and refreshed the
  session's credential when it picked the session up. From 03:24 a job in its terminal
  appended a line to a file in its folder every minute. The app log showed the refresh
  every 30 minutes after that, and the folder had every minute's line through 04:15, past
  the hour of both the first credential and the one from 03:13:

  ```text
  session mvltkhlp-merry-heron: mount credential refreshed     # 03:13:37, after the restart
  session mvltkhlp-merry-heron: mount credential refreshed     # 03:43:37
  session mvltkhlp-merry-heron: mount credential refreshed     # 04:13:38
  $ head -1 /workspace/project/heartbeat.log; tail -2 /workspace/project/heartbeat.log
  beat 1 03:24:46
  beat 51 04:14:47
  beat 52 04:15:47
  ```

  The times after `#` are from the log's timestamps. The job kept the terminal printing, so
  the idle check kept that session while it released the six idle ones, at 30 or 31 idle
  minutes each (`session mvltsw76-eager-marten: released after 30 idle minutes`).
- **Codex's web search runs on the Mantle side, outside the egress policy.** Codex runs on
  a GPT model served through the Bedrock "Mantle" endpoint, and that model can call a
  server-side web search and web fetch tool that Amazon Bedrock runs itself. The Codex role
  grants it with the `bedrock-websearch` actions `InvokeSearch` and `InvokeFetch` (scoped to
  this Region's tools) and `ExternalWebAccess`, which has no resource type to scope to;
  without them Mantle answers `Access denied: web search is not authorized for this
  identity` and the turn ends. The trade-off: those searches and fetches are made by
  Bedrock, not by the pod, so the sandbox egress policy does not limit them. The pod's own
  egress is still restricted, but any process in a Codex pod, not only the CLI, can use
  this role to have Bedrock search and read public web pages. Only Codex's pods have the
  grant: four of the other CLIs run under the Bedrock role, which has none of it, and
  kiro-cli has no AWS role at all. Remove the
  two `WebSearch...` statements from [`iam/codex-policy.json`](iam/codex-policy.json) to
  turn this off.
- **Codex runs without its own command sandbox; the pod is the boundary.** On Linux, Codex
  runs the shell commands it makes for you inside bubblewrap, which needs to create user
  namespaces. The Nitro sandbox's guest kernel allows none (`max_user_namespaces` is `0`, for
  root too), so bubblewrap fails with `Creating new namespace failed ... (ENOSPC)`, whether
  it is the system one or the one Codex bundles, and so does every command Codex runs.
  So the Codex config the image writes sets `sandbox_mode = "danger-full-access"`.
  Despite its name, that only drops Codex's second, inner boundary; it does not reach past
  the pod's own: the sandbox's own kernel, the egress policy, and a mount credential for
  this one session's folder. The sample leaves Codex's approval policy at its default, and
  Codex's `/status` on the fresh run read `Permissions: Custom (danger-full-access, Ask for
  approval)`. Asked in its terminal to run a command, Codex ran it as the session's
  unprivileged user and showed no sandbox warning:

  ```text
  • Ran id -u; uname -r; echo fix9 > fix9.txt; cat fix9.txt
    └ 1000
      6.18.51
      fix9
  ```
- **Session pods are not consolidated away.** The `SandboxTemplate` sets
  `karpenter.sh/do-not-disrupt: "true"` on every pod it makes, so EKS Auto Mode does not
  evict one to consolidate an underutilized node. That covers the warm pods waiting in the
  pools as well as the claimed ones, so a node holding only warm pods is not packed down
  either. A claimed pod still goes when its claim is released (close, idle timeout). The
  cost is that a node holding a session or a warm pod is not consolidated until that pod
  goes.
- **The session pods turn the Nitro sandbox network and disk throttles off.** A sandbox pod
  has built-in defaults -- 100 Mbit/s ingress and egress (capped by a 1500 packets/second
  bucket), a 400 Mbit/s overlay (scratch) disk and 1500 overlay IOPS -- which are tight for
  an interactive agent that streams model output, clones repos and installs packages, and
  show up as a sluggish session. The `SandboxTemplate` sets the `ingress-bandwidth`,
  `egress-bandwidth`, their `-packets-per-second` partners and the `overlay-disk-bandwidth`
  and `-iops` annotations to `disabled` (the value must be `disabled`; `0` is rejected and
  leaves the pod stuck creating). The trade-off, per the Amazon EKS User Guide, is that the
  pod may then use a larger share of its node's ENI and disk budget; a deployment that packs
  many sessions per node can set explicit caps instead.
- **kiro-cli signs in with the developer's own Kiro identity, not Bedrock.** The other five
  CLIs reach Amazon Bedrock through the pod's Pod Identity role; kiro-cli uses an IAM
  Identity Center / Builder ID sign-in and the CodeWhisperer service. The interactive
  device-flow login (`kiro-cli login --use-device-flow`) offers Builder ID, Google, GitHub
  and organization sign-in; it reaches the Kiro auth service at `*.kiro.dev`, which the
  kiro-cli egress rule allows alongside `*.amazonaws.com`. The sign-in is the developer's own
  and is stored in their session's folder, so a restored session stays signed in; the
  sample injects no shared sign-in token into the pods, because whatever the agent's home
  holds the agent can read, and the folder is persisted to the bucket. An identity whose
  sign-in is gated behind a corporate network gateway cannot load models from inside the
  sandbox, which has no route to that gateway; a Builder ID, Google or GitHub identity that
  is not so gated works.
- **The sign-in is a demo picker, not authentication.** The app is first-party code reachable
  only through `kubectl port-forward` on the operator's own machine.

## Clean up

Run the clean up when you finish, after your last session, so a sandbox pod is not left
holding capacity other demos share:

```bash
./scripts/clean.sh
```

It deletes in reverse order: the warm pools first, so they stop booting replacements, then
the claims, templates, policies and the app; the Pod Identity associations; the file
system's access points and mount targets, then the file system, waiting until it is gone so
it stops exporting to the bucket (if it still has writes pending export after 5 minutes of
retries, it deletes it with `--force-delete`, which drops only data the next step deletes
anyway); every object version in the bucket, then the bucket; the
IAM roles, the security group and the ECR repositories; the cluster-scoped ClusterRole and
ClusterRoleBinding; and the namespace last. It decides what is the sample's in three ways.
The file system, bucket, IAM roles and ECR repositories must carry the tag
`ManagedBy=coding-agents-for-developers`, and the security group is looked up by that tag
and its name; anything without the tag is left alone. Pod Identity associations are
matched by the sample's namespace and service accounts, and access points and mount
targets by the sample's own file system, once that file system's tag is confirmed. The
ClusterRole and binding, and the namespace, must carry the `app.kubernetes.io/part-of`
label, and everything inside the namespace is selected by that label. A resource that is
already gone is not an error, but a lookup that fails, a delete that is refused or a
resource it left alone makes it exit non-zero with an `INCOMPLETE:` line saying which. If it
cannot read the namespace's label at all, it stops before deleting anything, since it
cannot tell whose the namespace is; and if it cannot list the file system's access points
or mount targets, it leaves the file system and the bucket for the next run. It
never removes a shared install: agent-sandbox, the EFS CSI driver and network policy
enforcement stay, and the page above has the command to remove each if nothing else uses
it. To remove the cluster, follow the
[hello sandbox clean up](../../getting-started/hello-sandbox/README.md#clean-up).
