# Roadmap

These samples show Amazon EKS Nitro sandboxes (`runtimeClassName: isolated-sandbox`) running AI agents and untrusted code. Getting started is available now, and the rest of the samples below are planned.

## Layout

- Folders are named, not numbered: `examples/<section>/<sample>/`. Each sample folder holds its website page as `README.md`, the files the sample applies, and an `images/` folder when it has diagrams.
- The website's left menu has one collapsible section per folder, in the order below.

```text
examples/
├── getting-started/
│   ├── hello-sandbox/
│   ├── coding-agent/
│   └── warm-pool/
├── isolation-and-security/
│   ├── host-escape/
│   ├── multi-tenant-saas/
│   ├── network-policy/
│   ├── image-signing/
│   ├── observability/
│   └── sandbox-limits/
├── ai-agents/
│   ├── claude-code-workspace/
│   ├── opencode-workspace/
│   ├── codex-workspace/
│   ├── kiro-cli-workspace/
│   ├── strands-bedrock/
│   ├── claude-agent-sdk/
│   ├── google-adk/
│   ├── crewai/
│   ├── spring-ai/
│   ├── langgraph/
│   ├── strands-harness/
│   ├── strands-token-efficiency/
│   ├── openclaw/
│   ├── hermes/
│   ├── deep-agents/
│   ├── pi/
│   ├── claude-code-driver/
│   ├── mcp-server/
│   ├── kagent/
│   ├── claude-managed-agents/
│   └── strands-decider/
├── agent-guardrails/
│   ├── nono-nested-subagents/
│   ├── nono-procurement-agent/
│   ├── openshell-composed-isolation/
│   ├── openshell-procurement-agent/
│   ├── openshell-helm-lab/
│   ├── bubblewrap-analyst-lab/
│   ├── strands-shell/
│   └── strands-box/
├── workspaces-and-scaling/
│   ├── pause-resume/
│   ├── warm-pool-autoscaling/
│   ├── vscode/
│   ├── template-rollouts/
│   ├── storage-ebs/
│   ├── storage-efs/
│   ├── storage-s3-files/
│   ├── checkpoint-restore/
│   ├── checkpointable-agent-platform/
│   └── cold-start-and-density/
├── ci-cd-and-platforms/
│   ├── docker-builds/
│   ├── github-actions-runners/
│   ├── gitlab-ci/
│   ├── software-factory/
│   ├── temporal/
│   ├── istio/
│   ├── opensandbox/
│   ├── agent-substrate/
│   └── gardener/
└── confidential/
    ├── policy-enforcement/
    ├── encrypted-image/
    ├── secrets-manager-secret/
    └── s3-encrypted-file/
```

## Planned samples by section

Samples marked ★ are the first eight to be added after Getting started.

### Getting started (`getting-started`, available now)

- [hello-sandbox](../examples/getting-started/hello-sandbox/README.md): a plain pod that opts into a sandbox with one line, and a variant with no network.
- [coding-agent](../examples/getting-started/coding-agent/README.md): Claude Code in a sandbox that reads a GitHub issue, fixes it and opens a pull request.
- [warm-pool](../examples/getting-started/warm-pool/README.md): a pool of pre-booted sandboxes, ready for a claim to pick one up.

### Isolation and security (`isolation-and-security`)

- **host-escape ★**: the same node-takeover pod run with and without a sandbox. Without one it reaches the node; with one it reaches only its own VM.
- **multi-tenant-saas ★**: two tenants, each in its own sandbox with its own Pod Identity role and network policy. Cross-tenant access is denied.
- network-policy: a standard egress NetworkPolicy enforced on a sandboxed pod, side by side with an ordinary pod.
- image-signing: an image signed with AWS Signer and verified inside the guest, while an unsigned image is rejected.
- observability: which signals still reach you from a sandbox, and what a node-level monitoring agent sees when it runs inside one.
- sandbox-limits: the per-sandbox DNS query and connection-tracking limits, and how to recognise each one when a workload reaches it.

### AI agents (`ai-agents`)

Coding agents:

- claude-code-workspace: the Claude Code CLI with a persistent EBS workspace that is kept across suspend and resume.
- opencode-workspace: OpenCode with a persistent EBS workspace and an optional Amazon Bedrock turn.
- codex-workspace: the Codex CLI with a persistent EBS workspace that is kept across suspend and resume.
- **kiro-cli-workspace ★**: Kiro CLI with a persistent EBS workspace that is kept across suspend and resume.

Agent frameworks on Amazon Bedrock:

- **strands-bedrock ★**: a Strands Agents agent on Amazon Bedrock, with credentials from EKS Pod Identity and its memory on EBS.
- claude-agent-sdk: the Claude Agent SDK running inside the sandbox, so every command its Bash tool runs stays in the guest.
- google-adk: a Google ADK agent that reaches Amazon Bedrock through LiteLLM and Pod Identity.
- crewai: a CrewAI crew, a researcher and a writer, on Amazon Bedrock, placed in a sandbox with one line.
- spring-ai: a Spring AI application whose JVM calls Amazon Bedrock through the AWS SDK for Java and Pod Identity.
- langgraph: a LangGraph agent on Amazon Bedrock, placed in a sandbox with one line.
- strands-harness: the Strands harness with its real shell and file tools, so every command it generates runs in the guest.
- strands-token-efficiency: the same task on the same model with the Strands harness's context management on and off, and the token count of each run.

Agent harnesses:

- openclaw: an OpenClaw harness with full privileges, boxed in a guest, beside the same harness on an ordinary pod.
- hermes: a long-lived Hermes harness whose state on EBS is kept across suspend and resume, plus a variant with no network.
- deep-agents: LangChain Deep Agents Code in a sandbox, compared with the same harness on an ordinary pod.
- pi: the pi coding agent in a sandbox, with an optional Amazon Bedrock tool turn.

Agent platforms:

- claude-code-driver: an agent outside drives a warm, network-isolated sandbox that it claims from a pool.
- mcp-server: an untrusted MCP server in a sandbox with no network, driven by a trusted client outside it.
- kagent: Kagent's agent pods placed in sandboxes.
- claude-managed-agents: a Claude Managed Agents self-hosted sandbox where every tool call runs in the guest and the organization API key never enters it.
- strands-decider: Strands Decider choosing where each piece of generated code should run.

### Agent guardrails (`agent-guardrails`)

A second policy layer running inside the VM, on top of the sandbox.

- nono-nested-subagents: several nono-wrapped sub-agents in one sandbox, with nono restricting each process.
- nono-procurement-agent: a procurement analyst agent that does useful work with bounded access, confined by nono.
- openshell-composed-isolation: OpenShell's file, system call and network policy composed with a sandbox.
- openshell-procurement-agent: a procurement analyst confined by OpenShell, whose supervisor holds the real credentials in its own pod outside the guest.
- openshell-helm-lab: OpenShell's gateway and workspace Helm charts on EKS, with a procurement analyst working in a sandbox.
- bubblewrap-analyst-lab: a procurement analyst whose tool processes are confined by bubblewrap inside one guest, with no network for the restricted tools.
- strands-shell: Strands Shell, a virtual shell that runs inside the agent's own process, in a sandbox.
- strands-box: Strands Box and its deny-by-default Dogwood policy in a sandbox on a Graviton node.

### Workspaces and scaling (`workspaces-and-scaling`)

- **pause-resume ★**: suspend a sandbox and resume it into a new guest VM with its EBS data intact.
- **warm-pool-autoscaling ★**: KEDA scales a warm pool up and down with claim demand.
- vscode: VS Code in the browser on a persistent EBS workspace.
- template-rollouts: rolling a `SandboxTemplate` change through a warm pool with Argo Rollouts, replacing the warm sandboxes built from the old template.
- storage-ebs: EBS volumes for sandboxed pods.
- storage-efs: an EFS file system shared by two sandboxed pods.
- storage-s3-files: an S3 Files access point shared by two sandboxed pods and kept in sync with its S3 bucket.
- checkpoint-restore: save a running agent and its tools, release the compute, and continue in a fresh sandbox.
- checkpointable-agent-platform: deploy an ordinary HTTP agent and let the platform handle checkpoint, wake and fork.
- cold-start-and-density: measure time to Ready, sandboxes per node and the per-sandbox overhead on your own cluster.

### CI/CD and platforms (`ci-cd-and-platforms`)

- **docker-builds ★**: privileged `docker build` and `docker run` inside a sandbox, without exposing the node.
- **github-actions-runners ★**: GitHub Actions Runner Controller with each untrusted pull request job in its own sandbox, deleted when the job ends.
- gitlab-ci: a self-hosted GitLab whose CI jobs each run in a sandbox, including a privileged `docker build`.
- software-factory: a human-gated GitLab loop from issue to merge request to deploy, where every CI job runs in its own sandbox.
- temporal: Temporal workflows that create, drive, suspend, resume and remove sandboxes.
- istio: a sandboxed pod in an Istio mesh with strict mTLS, behaving like an ordinary meshed pod.
- opensandbox: Nitro sandboxes added as a runtime for OpenSandbox.
- agent-substrate: Agent Substrate on EKS, with each warm worker in a sandbox and agent state checkpointed to S3.
- gardener: Gardener on EKS creating self-managed Kubernetes clusters on EC2, with an optional worker that runs sandboxes.

### Confidential (`confidential`, later)

These samples use `runtimeClassName: confidential-sandbox`.

- policy-enforcement: a Cedar policy generated for a workload and enforced inside the guest, which refuses an operator's exec.
- encrypted-image: encrypted image layers in Amazon ECR, decrypted inside the sandbox after AWS KMS checks its attested policy.
- secrets-manager-secret: an AWS Secrets Manager secret released only to an approved sandbox.
- s3-encrypted-file: a file encrypted before upload to Amazon S3 and decrypted only inside an approved sandbox.

## Starting with these 8, and why

The first eight cover four sections with two samples each. Every one builds on a cluster that has finished Getting started, and each runs on standard EKS Auto Mode with no extra platform to install beyond what the sample states.

- **host-escape**: the clearest picture of the boundary. The same privileged pod owns a node without a sandbox, and only its own VM with one.
- **multi-tenant-saas**: the most common production question, how to keep tenants apart, answered with the sandbox, Pod Identity and network policy together.
- **kiro-cli-workspace**: a coding agent's workspace as an agent-sandbox `Sandbox`, with a persistent home that survives suspend and resume.
- **strands-bedrock**: an agent framework calling Amazon Bedrock with no stored keys, through EKS Pod Identity, with its memory kept on EBS.
- **pause-resume**: stop paying for idle sandboxes and pick up the same workspace later.
- **warm-pool-autoscaling**: extends the warm pool from Getting started, so the pool grows and shrinks with demand.
- **docker-builds**: privileged `docker build` and `docker run` without exposing the node, the CI case that used to need workarounds.
- **github-actions-runners**: untrusted pull request jobs, each in its own VM that is deleted when the job ends.

## Not planned for this repo

Beyond the cluster that Getting started creates, cluster setup guides, AMI builds and benchmark comparisons stay out of this repo.
