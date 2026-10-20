# Roadmap

These samples show Amazon EKS Nitro sandboxes (`runtimeClassName: isolated-sandbox`) running AI agents and untrusted code. Getting started, Isolation > network-policy and Claude Managed Agents are available now, and the rest of the samples below are planned.

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
│   └── agent-harnesses/
├── managed-agents/
│   ├── claude-managed-agents/
│   ├── openai-managed-agents/
│   ├── bedrock-managed-agents/
│   ├── cursor-cloud-agents/
│   └── agentcore-mcp/
├── subagent-security/
│   ├── nono/
│   ├── bubblewrap/
│   └── openshell/
├── openshell/
│   ├── kubernetes/
│   └── nemoclaw/
├── agent-sandbox/
│   ├── pause-resume/
│   ├── warm-pool-autoscaling-keda/
│   ├── ide/
│   ├── argo-rollouts/
│   └── brain-and-hands/
├── storage/
│   ├── ebs/
│   ├── efs/
│   └── s3-files/
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

- [network-policy](../examples/isolation/network-policy/README.md) (available now): a standard egress NetworkPolicy enforced on a sandboxed pod, side by side with an ordinary pod. Spec: [#15](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/15).
- [sandbox-limits](../examples/isolation/sandbox-limits/README.md): the per-sandbox DNS query-rate limit and the per-pod outbound connection limit, and how to recognise each one when a workload reaches it. Spec: [#16](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/16).

### Policy (`policy`)

Checks that run inside the guest and decide what the pod may run.

- [image-signing](../examples/policy/image-signing/README.md) (available now): an image signed with AWS Signer and verified inside the guest, while an unsigned image is rejected, with an optional no-network variant. Uses `isolated-sandbox`. Spec: [#17](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/17).
- cedar-policy: a Cedar policy generated for a workload and enforced inside the guest, which refuses an operator's exec. Uses `confidential-sandbox`. Spec: [#18](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/18).

### AI agents (`ai-agents`)

Coding agents:

- **coding-agents-for-developers ★**: a web app where a developer starts Claude Code, Codex, Kiro CLI, OpenCode, pi or oh-my-pi in a browser terminal. Each session runs in its own sandbox, claimed from a warm pool, and can open only its own workspace folder on S3 Files. Spec: [#12](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/12).

Agent frameworks on Amazon Bedrock:

- **agent-frameworks ★**: one web app that runs the same agent in Strands Agents, LangGraph, Deep Agents, CrewAI, Google ADK, OpenAI Agents SDK, Pydantic AI, LlamaIndex, the Claude Agent SDK and Spring AI, each run in a fresh sandbox where the code the model writes executes. Spec: [#13](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/13).

Agent harnesses:

- agent-harnesses: OpenClaw and Hermes, each always on in its own sandbox with root inside it, memory on EBS kept across suspend and resume, and only Amazon Bedrock reachable. Spec: [#14](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/14).

### Managed agents (`managed-agents`)

Agent services that run the agent loop for you and send its tool calls to compute you host. Each sample runs those tool calls in a Nitro sandbox on EKS.

- [claude-managed-agents](../examples/managed-agents/claude-managed-agents/README.md) (available now): a Claude Managed Agents self-hosted sandbox where every tool call runs in the guest and the organization API key never enters it.
- openai-managed-agents: an OpenAI Managed Agents self-hosted sandbox, with each session's tool calls running in a Nitro sandbox. Spec: [#9](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/9).
- bedrock-managed-agents: Bedrock Managed Agents, powered by OpenAI, with the agent's tool calls running in a Nitro sandbox on EKS. Spec: [#40](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/40).
- cursor-cloud-agents: Cursor Cloud Agents on self-hosted machines, with each agent's tool execution in a Nitro sandbox on EKS. Spec: [#39](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/39).
- agentcore-mcp: an Amazon Bedrock AgentCore agent that uses EKS as its sandbox through MCP. An MCP server runs each code-execution tool call in a Nitro sandbox. Spec: [#41](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/41).

### Subagent security (`subagent-security`)

The same procurement analyst agent three ways. Inside its sandbox, a second policy layer confines the tools and subagents it runs, each with only the files, processes and network it needs.

- nono: the analyst confined by nono, doing useful work with bounded access. Spec: [#34](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/34).
- bubblewrap: the analyst whose tool processes are confined by bubblewrap, with no network for the restricted tools. Spec: [#35](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/35).
- openshell: the analyst confined by OpenShell, whose supervisor holds the real credentials in its own pod outside the sandbox. Spec: [#36](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/36).

### OpenShell (`openshell`)

[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell), and the NemoClaw reference stack built on it, with Nitro sandboxes.

- kubernetes: OpenShell installed on EKS with its Helm charts. Each OpenShell sandbox's workload pod runs in a Nitro sandbox, and its supervisor, which holds the credentials, stays an ordinary pod. Spec: [#37](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/37).
- nemoclaw: NVIDIA NemoClaw, with OpenClaw, inside one Nitro sandbox pod. NemoClaw supports only a single Docker host today, so the whole stack runs in the sandbox: OpenShell's controls inside, the Nitro sandbox around it. Spec: [#43](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/43).

### Agent sandbox (`agent-sandbox`)

The [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) resources, `Sandbox`, `SandboxTemplate`, `SandboxWarmPool` and `SandboxClaim`, with Nitro sandboxes.

- [pause-resume](../examples/agent-sandbox/pause-resume/README.md) (available now): suspend a sandbox and resume it into a new guest VM with its EBS data intact. Spec: [#30](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/30).
- **warm-pool-autoscaling-keda ★**: KEDA scales a warm pool up and down with claim demand. Spec: [#31](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/31).
- ide: VS Code in the browser on a persistent EBS workspace. Spec: [#32](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/32).
- argo-rollouts: rolling a `SandboxTemplate` change through a warm pool with Argo Rollouts, replacing the warm sandboxes built from the old template. Spec: [#33](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/33).
- brain-and-hands: the agent (the brain) runs on an ordinary pod with model access and no local shell. Each command it runs goes to a warm, network-isolated sandbox (the hands) that it claims from a pool and drives with `kubectl exec`. Spec: [#38](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/38).

### Storage (`storage`)

- ebs: EBS volumes for sandboxed pods. Spec: [#27](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/27).
- efs: an EFS file system shared by two sandboxed pods. Spec: [#28](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/28).
- s3-files: an S3 Files access point shared by two sandboxed pods and kept in sync with its S3 bucket. Spec: [#29](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/29).

### CI/CD (`ci-cd`)

- **docker-builds ★**: privileged `docker build` and `docker run` inside a sandbox, without exposing the node. Spec: [#23](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/23).
- **github-actions ★**: GitHub Actions Runner Controller with each untrusted pull request job in its own sandbox, deleted when the job ends. Spec: [#24](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/24).
- gitlab-ci: a self-hosted GitLab whose CI jobs each run in a sandbox, including a privileged `docker build`. Spec: [#25](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/25).

### Integrations (`integrations`)

Other platforms that create and manage sandboxes.

- temporal: Temporal workflows that create, drive, suspend, resume and remove sandboxes. Spec: [#26](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/26).
- opensandbox (blocked until GA): Nitro sandboxes as a secure runtime for OpenSandbox. Waits for Nitro sandboxes to be generally available and the runtime to be added upstream in OpenSandbox. Spec: [#22](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/22).

### Confidential (`confidential`)

These samples use `runtimeClassName: confidential-sandbox`.

- encrypted-image: encrypted image layers in Amazon ECR, decrypted inside the sandbox after AWS KMS checks its attested policy. Spec: [#19](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/19).
- secrets-manager-secret: an AWS Secrets Manager secret released only to an approved sandbox. Spec: [#20](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/20).
- s3-encrypted-file: a file encrypted before upload to Amazon S3 and decrypted only inside an approved sandbox. Spec: [#21](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/21).
