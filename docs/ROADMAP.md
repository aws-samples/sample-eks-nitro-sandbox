# Roadmap

These samples show Amazon EKS Nitro sandboxes (`runtimeClassName: isolated-sandbox`) running AI agents and untrusted code. A sample whose entry links to its page is ready to run, and is marked "available now" on its entry or in its section heading. The rest are planned.

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
- [sandbox-limits](../examples/isolation/sandbox-limits/README.md) (available now): the per-sandbox DNS query-rate limit and the per-pod outbound connection limit, and how to recognise each one when a workload reaches it. Spec: [#16](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/16).

### Policy (`policy`)

Checks that run inside the guest and decide what the pod may run.

- [image-signing](../examples/policy/image-signing/README.md) (available now): an image signed with AWS Signer and verified inside the guest, while an unsigned image is rejected, with an optional no-network variant. Uses `isolated-sandbox`. Spec: [#17](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/17).
- [cedar-policy](../examples/policy/cedar-policy/README.md) (available now): a Cedar policy generated for a workload and enforced inside the guest, which refuses an operator's exec. Uses `confidential-sandbox`. Spec: [#18](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/18).

### AI agents (`ai-agents`)

Coding agents:

- [coding-agents-for-developers](../examples/ai-agents/coding-agents-for-developers/README.md) (available now): a web app where a developer starts Claude Code, Codex, Kiro CLI, OpenCode, pi or oh-my-pi in a browser terminal. Each session runs in its own sandbox, claimed from a warm pool, and can open only its own workspace folder on S3 Files. Spec: [#12](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/12).

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

The [Subagent security section page](../examples/subagent-security/README.md) holds what they share: the analyst, the case, the shared `analyst/` folder and what a confinement layer has to supply.

- [nono](../examples/subagent-security/nono/README.md) (available now): the analyst confined by nono, doing useful work with bounded access. Spec: [#34](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/34).
- bubblewrap: the analyst whose tool processes are confined by bubblewrap, with no network for the restricted tools. Spec: [#35](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/35).
- openshell: the analyst confined by OpenShell, whose supervisor holds the real credentials in its own pod outside the sandbox. Spec: [#36](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/36).

### OpenShell (`openshell`)

[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell), and the NemoClaw reference stack built on it, with Nitro sandboxes.

- kubernetes: OpenShell installed on EKS with its Helm charts. Each OpenShell sandbox's workload pod runs in a Nitro sandbox, and its supervisor, which holds the credentials, stays an ordinary pod. Spec: [#37](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/37).
- nemoclaw: NVIDIA NemoClaw, with OpenClaw, inside one Nitro sandbox pod. NemoClaw supports only a single Docker host today, so the whole stack runs in the sandbox: OpenShell's controls inside, the Nitro sandbox around it. Spec: [#43](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/43).

### Agent sandbox (`agent-sandbox`)

The [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) resources, `Sandbox`, `SandboxTemplate`, `SandboxWarmPool` and `SandboxClaim`, with Nitro sandboxes.

- [pause-resume](../examples/agent-sandbox/pause-resume/README.md) (available now): suspend a sandbox and resume it into a new guest VM with its EBS data intact. Spec: [#30](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/30).
- [warm-pool-autoscaling-keda](../examples/agent-sandbox/warm-pool-autoscaling-keda/README.md) (available now): KEDA scales a warm pool up and down with claim demand, so warm capacity tracks demand instead of a fixed count. Spec: [#31](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/31).
- [ide](../examples/agent-sandbox/ide/README.md) (available now): VS Code in the browser on a persistent EBS workspace. Spec: [#32](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/32).
- [argo-rollouts](../examples/agent-sandbox/argo-rollouts/README.md) (available now): rolling a `SandboxTemplate` change through a warm pool with Argo Rollouts, replacing the warm sandboxes built from the old template. Spec: [#33](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/33).
- [brain-and-hands](../examples/agent-sandbox/brain-and-hands/README.md) (available now): the agent (the brain) runs on an ordinary pod with model access and no local shell. Each command it runs goes to a warm, network-isolated sandbox (the hands) that it claims from a pool and drives with `kubectl exec`. Spec: [#38](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/38).

### Storage (`storage`)

- [ebs](../examples/storage/ebs/README.md) (available now): EBS volumes for sandboxed pods, a single pod and a StatefulSet whose replicas each get their own volume. Spec: [#27](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/27).
- [efs](../examples/storage/efs/README.md) (available now): an EFS file system shared by two sandboxed pods. Spec: [#28](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/28).
- [s3-files](../examples/storage/s3-files/README.md) (available now): an S3 Files access point shared by two sandboxed pods and kept in sync with its S3 bucket. Spec: [#29](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/29).

### CI/CD (`ci-cd`)

- [docker-builds](../examples/ci-cd/docker-builds/README.md) (available now): privileged `docker build` and `docker run` inside a sandbox, without exposing the node, with an EBS layer cache across Job runs and an optional push to Amazon ECR. Spec: [#23](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/23).
- [github-actions](../examples/ci-cd/github-actions/README.md) (available now): GitHub Actions Runner Controller with each untrusted pull request job in its own sandbox, deleted when the job ends. Spec: [#24](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/24).
- [gitlab-ci](../examples/ci-cd/gitlab-ci/README.md) (available now): a self-hosted GitLab whose CI jobs each run in a sandbox, including a privileged `docker build`. Spec: [#25](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/25).

### Integrations (`integrations`)

Other platforms that create and manage sandboxes.

- temporal: Temporal workflows that create, drive, suspend, resume and remove sandboxes. Spec: [#26](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/26).
- opensandbox (blocked until GA): Nitro sandboxes as a secure runtime for OpenSandbox. Waits for Nitro sandboxes to be generally available and the runtime to be added upstream in OpenSandbox. Spec: [#22](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/22).

### Confidential (`confidential`)

These samples use `runtimeClassName: confidential-sandbox`.

The [Confidential section page](../examples/confidential/README.md) holds what they share: the trust boundary, the KMS key-policy shape, the attested decrypt and the measurement caveat.

- [encrypted-image](../examples/confidential/encrypted-image/README.md) (available now): encrypted image layers in Amazon ECR, decrypted inside the sandbox after AWS KMS checks its attested policy. Spec: [#19](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/19).
- [secrets-manager-secret](../examples/confidential/secrets-manager-secret/README.md) (available now): an AWS Secrets Manager secret released only to an approved sandbox. Spec: [#20](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/20).
- [s3-encrypted-file](../examples/confidential/s3-encrypted-file/README.md) (available now): a file encrypted before upload to Amazon S3 and decrypted only inside an approved sandbox. Spec: [#21](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/21).
