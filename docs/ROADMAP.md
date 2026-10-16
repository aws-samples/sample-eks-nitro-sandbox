# Roadmap

These samples show Amazon EKS Nitro sandboxes (`runtimeClassName: isolated-sandbox`) running AI agents and untrusted code. Getting started and Claude Managed Agents are available now, and the rest of the samples below are planned.

## Layout

- Folders are named, not numbered: `examples/<section>/<sample>/`. Each sample folder holds its website page as `README.md`, the files the sample applies, and an `images/` folder when it has diagrams.
- The website's left menu has one section per folder, in the order below: a heading with its pages always listed under it.

```text
examples/
├── getting-started/
│   ├── hello-sandbox/
│   ├── coding-agent/
│   └── warm-pool/
├── isolation/
│   ├── network-policy/
│   └── sandbox-limits/
├── policy/
│   ├── image-signing/
│   └── cedar-policy/
├── ai-agents/
│   ├── coding-agents-for-developers/
│   ├── agent-frameworks/
│   ├── agent-harnesses/
│   ├── claude-code-driver/
│   └── claude-managed-agents/
├── agent-guardrails/
│   ├── nono-nested-subagents/
│   ├── nono-procurement-agent/
│   ├── openshell-composed-isolation/
│   ├── openshell-procurement-agent/
│   ├── openshell-helm-lab/
│   └── bubblewrap-analyst-lab/
├── workspaces-and-scaling/
│   ├── pause-resume/
│   ├── warm-pool-autoscaling/
│   ├── vscode/
│   ├── template-rollouts/
│   ├── storage-ebs/
│   ├── storage-efs/
│   ├── storage-s3-files/
│   └── cold-start-and-density/
├── ci-cd/
│   ├── docker-builds/
│   ├── github-actions/
│   └── gitlab-ci/
├── integrations/
│   ├── temporal/
│   └── opensandbox/
└── confidential/
    ├── encrypted-image/
    ├── secrets-manager-secret/
    └── s3-encrypted-file/
```

## Planned samples by section

Samples marked ★ are the next six to be added.

### Getting started (`getting-started`, available now)

- [hello-sandbox](../examples/getting-started/hello-sandbox/README.md): a plain pod that opts into a sandbox with one line, and a variant with no network.
- [coding-agent](../examples/getting-started/coding-agent/README.md): Claude Code in a sandbox that reads a GitHub issue, fixes it and opens a pull request.
- [warm-pool](../examples/getting-started/warm-pool/README.md): a pool of pre-booted sandboxes, ready for a claim to pick one up.

### Isolation (`isolation`)

- network-policy: a standard egress NetworkPolicy enforced on a sandboxed pod, side by side with an ordinary pod. Spec: [#15](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/15).
- sandbox-limits: the per-sandbox DNS query and connection-tracking limits, and how to recognise each one when a workload reaches it. Spec: [#16](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/16).

### Policy (`policy`)

Checks that run inside the guest and decide what the pod may run.

- image-signing: an image signed with AWS Signer and verified inside the guest, while an unsigned image is rejected. Uses `isolated-sandbox`. Spec: [#17](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/17).
- cedar-policy: a Cedar policy generated for a workload and enforced inside the guest, which refuses an operator's exec. Uses `confidential-sandbox`. Spec: [#18](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/18).

### AI agents (`ai-agents`)

Coding agents:

- **coding-agents-for-developers ★**: a web app where a developer starts Claude Code, Codex, Kiro CLI, OpenCode, pi or oh-my-pi in a browser terminal. Each session runs in its own sandbox, claimed from a warm pool, and can open only its own workspace folder on S3 Files. Spec: [#12](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/12).

Agent frameworks on Amazon Bedrock:

- **agent-frameworks ★**: one web app that runs the same agent in Strands Agents, LangGraph, Deep Agents, CrewAI, Google ADK, OpenAI Agents SDK, Pydantic AI, LlamaIndex, the Claude Agent SDK and Spring AI, each run in a fresh sandbox where the code the model writes executes. Spec: [#13](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/13).

Agent harnesses:

- agent-harnesses: OpenClaw, Hermes and NVIDIA NemoClaw, each always on in its own sandbox with root inside it, memory on EBS kept across suspend and resume, and only Amazon Bedrock reachable. Spec: [#14](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/14).

Agent platforms:

- claude-code-driver: an agent outside drives a warm, network-isolated sandbox that it claims from a pool.

### Agent guardrails (`agent-guardrails`)

A second policy layer running inside the VM, on top of the sandbox.

- nono-nested-subagents: several nono-wrapped sub-agents in one sandbox, with nono restricting each process.
- nono-procurement-agent: a procurement analyst agent that does useful work with bounded access, confined by nono.
- openshell-composed-isolation: OpenShell's file, system call and network policy composed with a sandbox.
- openshell-procurement-agent: a procurement analyst confined by OpenShell, whose supervisor holds the real credentials in its own pod outside the guest.
- openshell-helm-lab: OpenShell's gateway and workspace Helm charts on EKS, with a procurement analyst working in a sandbox.
- bubblewrap-analyst-lab: a procurement analyst whose tool processes are confined by bubblewrap inside one guest, with no network for the restricted tools.

### Workspaces and scaling (`workspaces-and-scaling`)

- **pause-resume ★**: suspend a sandbox and resume it into a new guest VM with its EBS data intact.
- **warm-pool-autoscaling ★**: KEDA scales a warm pool up and down with claim demand.
- vscode: VS Code in the browser on a persistent EBS workspace.
- template-rollouts: rolling a `SandboxTemplate` change through a warm pool with Argo Rollouts, replacing the warm sandboxes built from the old template.
- storage-ebs: EBS volumes for sandboxed pods.
- storage-efs: an EFS file system shared by two sandboxed pods.
- storage-s3-files: an S3 Files access point shared by two sandboxed pods and kept in sync with its S3 bucket.
- cold-start-and-density: measure time to Ready, sandboxes per node and the per-sandbox overhead on your own cluster.

### CI/CD (`ci-cd`)

- **docker-builds ★**: privileged `docker build` and `docker run` inside a sandbox, without exposing the node. Spec: [#23](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/23).
- **github-actions ★**: GitHub Actions Runner Controller with each untrusted pull request job in its own sandbox, deleted when the job ends. Spec: [#24](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/24).
- gitlab-ci: a self-hosted GitLab whose CI jobs each run in a sandbox, including a privileged `docker build`.

### Integrations (`integrations`)

Other platforms that create and manage sandboxes.

- temporal: Temporal workflows that create, drive, suspend, resume and remove sandboxes.
- opensandbox (blocked until GA): Nitro sandboxes as a secure runtime for OpenSandbox. Waits for Nitro sandboxes to be generally available and the runtime to be added upstream in OpenSandbox. Spec: [#22](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/22).

### Confidential (`confidential`)

These samples use `runtimeClassName: confidential-sandbox`.

- encrypted-image: encrypted image layers in Amazon ECR, decrypted inside the sandbox after AWS KMS checks its attested policy. Spec: [#19](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/19).
- secrets-manager-secret: an AWS Secrets Manager secret released only to an approved sandbox. Spec: [#20](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/20).
- s3-encrypted-file: a file encrypted before upload to Amazon S3 and decrypted only inside an approved sandbox. Spec: [#21](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/21).

## Starting with these 6, and why

The six cover three sections with two samples each. Every one builds on a cluster that has finished Getting started, and each runs on standard EKS Auto Mode with no extra platform to install beyond what the sample states.

- **coding-agents-for-developers**: one app for any coding agent. Each session is claimed from a warm pool and keeps its workspace on S3 Files after its pod is gone.
- **agent-frameworks**: ten agent frameworks calling Amazon Bedrock with no stored keys, through EKS Pod Identity, with the code each model writes running in the sandbox.
- **pause-resume**: stop paying for idle sandboxes and pick up the same workspace later.
- **warm-pool-autoscaling**: extends the warm pool from Getting started, so the pool grows and shrinks with demand.
- **docker-builds**: privileged `docker build` and `docker run` without exposing the node, the CI case that used to need workarounds.
- **github-actions**: untrusted pull request jobs, each in its own sandboxed pod that is deleted when the job ends.

## Not planned for this repo

Beyond the cluster that Getting started creates, cluster setup guides, AMI builds and benchmark comparisons stay out of this repo.
