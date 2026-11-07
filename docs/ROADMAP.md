# Roadmap

These samples run AI agents and untrusted code in Amazon EKS Nitro sandboxes (`runtimeClassName: isolated-sandbox`). Sample owners maintain readiness labels on entries or section headings. A link means the sample has a page; it does not establish that the sample is ready to run. Unlinked entries are planned.

## Layout

- Folders are named, not numbered: `examples/<section>/<sample>/`. Each sample folder holds its website page as `README.md`, the files the sample applies, and an `images/` folder when it has diagrams.
- The website's left menu has one section per folder, in the order below: a heading with its pages always listed under it.

```text
examples/
├── getting-started/
│   ├── hello-sandbox/
│   ├── coding-agent/
│   └── warm-pool/
├── setup/
│   ├── ubuntu-ami/
│   └── cilium-ubuntu/
├── isolation/
│   ├── network-policy/
│   └── sandbox-limits/
├── policy/
│   └── cedar-policy/
├── ai-agents/
│   ├── coding-agents-for-developers/
│   ├── agent-frameworks/
│   ├── hermes/
│   └── openclaw-enterprise/
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
    ├── s3-encrypted-file/
    └── signer-policy/
```

## Planned samples by section

Samples marked ★ are the next six to be added.

### Getting started (`getting-started`, available now)

- [hello-sandbox](../examples/getting-started/hello-sandbox/README.md): a plain pod that opts into a sandbox with one line, and a variant with no network.
- [coding-agent](../examples/getting-started/coding-agent/README.md): Claude Code in a sandbox that reads a GitHub issue, fixes it and opens a pull request.
- [warm-pool](../examples/getting-started/warm-pool/README.md): a pool of pre-booted sandboxes, ready for a claim to pick one up.

### Setup (`setup`)

Cluster node-OS setup for a reader who manages their own node AMI instead of relying on EKS
Auto Mode's managed one. Cluster and node-group lifecycle were previously treated as out of
scope here; this section is an intentional, narrow addition: it covers building a node AMI
for an existing cluster, not creating or managing the cluster itself.

- [ubuntu-ami](../examples/setup/ubuntu-ami/README.md): build a custom Ubuntu 24.04 node
  AMI for EKS Pod Isolation and add one dedicated, tainted managed node group to an
  existing cluster. Every public input (base AMI, kernel 6.18.56 plus AWS's public
  host-kernel commit 1e66c960, erofs-utils 1.8.10, distro packages) is pinned and
  checksum-verified. The Nitro sandbox runtime is an operator-supplied preview archive,
  checksum-pinned, with no public download. Validated end to end on a live cluster; whether
  that archive meets the spec's public-input criterion is waiting on the maintainers. Spec:
  [#10](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/10).
- [cilium-ubuntu](../examples/setup/cilium-ubuntu/README.md) (available now): a dedicated
  disposable cluster with Cilium as the only CNI, in ENI mode with kube-proxy replacement, and
  the two Ubuntu node groups (system and sandbox) from `ubuntu-ami` above joining it. Spec: [#11](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/11).

### Isolation (`isolation`)

- [network-policy](../examples/isolation/network-policy/README.md) (available now): a standard egress NetworkPolicy enforced on a sandboxed pod, side by side with an ordinary pod. Spec: [#15](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/15).
- [sandbox-limits](../examples/isolation/sandbox-limits/README.md) (available now): the per-sandbox DNS query-rate limit and the per-pod outbound connection limit, and how to recognise each one when a workload reaches it. Spec: [#16](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/16).

### Policy (`policy`)

Checks that run inside the guest and decide what the pod may run.

- [cedar-policy](../examples/policy/cedar-policy/README.md) (available now): a Cedar policy generated for a workload and enforced inside the guest, which refuses an operator's exec. Uses `confidential-sandbox`. Spec: [#18](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/18).

### AI agents (`ai-agents`)

Coding agents:

- [coding-agents-for-developers](../examples/ai-agents/coding-agents-for-developers/README.md) (available now): a web app where a developer starts Claude Code, Codex, Kiro CLI, OpenCode, pi or oh-my-pi in a browser terminal. Each session runs in its own sandbox, claimed from a warm pool, and can open only its own workspace folder on S3 Files. Spec: [#12](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/12).

Agent frameworks on Amazon Bedrock:

- **agent-frameworks ★**: one web app that runs the same agent in Strands Agents, LangGraph, Deep Agents, CrewAI, Google ADK, OpenAI Agents SDK, Pydantic AI, LlamaIndex, the Claude Agent SDK and Spring AI, each run in a fresh sandbox where the code the model writes executes. Spec: [#13](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/13).

Agent harnesses:

- hermes: the Hermes Agent harness, always on in its own sandbox with root inside it, memory on EBS kept across suspend and resume, and Amazon Bedrock with no API key in the sandbox. Spec: [#14](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/14).
- openclaw-enterprise: OpenClaw Enterprise on EKS, each Agent in a Nitro sandbox, with the model call going through agentgateway to Amazon Bedrock. Spec: [#133](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/133).

### Managed agents (`managed-agents`)

Agent services that run the agent loop for you and send its tool calls to compute you host. Each sample runs those tool calls in a Nitro sandbox on EKS.

- [claude-managed-agents](../examples/managed-agents/claude-managed-agents/README.md) (available now): a Claude Managed Agents self-hosted sandbox where every tool call runs in the guest and the organization API key never enters it.
- [openai-managed-agents](../examples/managed-agents/openai-managed-agents/README.md) (available now): an OpenAI Agents API self-hosted sandbox where `codex exec-server` runs the tool calls in the guest, the application key never enters the cluster, and the sandbox holds only the environment key. Spec: [#9](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/9).
- bedrock-managed-agents: Bedrock Managed Agents, powered by OpenAI, with the agent's tool calls running in a Nitro sandbox on EKS. Spec: [#40](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/40).
- cursor-cloud-agents: Cursor Cloud Agents on self-hosted machines, with each agent's tool execution in a Nitro sandbox on EKS. Spec: [#39](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/39).
- agentcore-mcp: an Amazon Bedrock AgentCore agent that uses EKS as its sandbox through MCP. An MCP server runs each code-execution tool call in a Nitro sandbox. Spec: [#41](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/41).

### Subagent security (`subagent-security`)

The same procurement analyst agent, with four choices for confining its tools. Inside its sandbox, a second policy layer confines the tools and subagents it runs, each with only the files, processes and network it needs.

The [Subagent security section page](../examples/subagent-security/README.md) holds what they share: the analyst, the case, the shared `analyst/` folder and what a confinement layer has to supply.

- [nono](../examples/subagent-security/nono/README.md) (available now): the analyst confined by nono, doing useful work with bounded access. Spec: [#34](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/34).
- [bubblewrap](../examples/subagent-security/bubblewrap/README.md) (available now): the analyst whose tool processes are confined by bubblewrap, with no network for the restricted tools. Spec: [#35](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/35).
- [openshell](../examples/subagent-security/openshell/README.md) (available now): the analyst confined by OpenShell, whose supervisor holds the real credentials in its own pod outside the sandbox. Spec: [#36](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/36).

- [strands-box](../examples/subagent-security/strands-box/README.md) (available now): a procurement analyst in a Nitro sandbox, with separate role Boxes and history-dependent HTTP policies. Spec: [#156](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/156).

### OpenShell (`openshell`)

[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell), and the NemoClaw reference stack built on it, with Nitro sandboxes.

- [kubernetes](../examples/openshell/kubernetes/README.md) (available now): OpenShell installed on EKS with its Helm charts. Each OpenShell sandbox's workload pod runs in a Nitro sandbox, and its supervisor, which holds the credentials, stays an ordinary pod. Spec: [#37](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/37).
- nemoclaw: NVIDIA NemoClaw, with OpenClaw, inside one Nitro sandbox pod. NemoClaw supports only a single Docker host today, so the whole stack runs in the sandbox: OpenShell's controls inside, the Nitro sandbox around it. Spec: [#43](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/43).

### Agent sandbox (`agent-sandbox`)

The [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) resources, `Sandbox`, `SandboxTemplate`, `SandboxWarmPool` and `SandboxClaim`, with Nitro sandboxes.

- [pause-resume](../examples/agent-sandbox/pause-resume/README.md) (available now): suspend a sandbox and resume it into a new guest VM with its EBS data intact. Spec: [#30](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/30).
- [warm-pool-autoscaling-keda](../examples/agent-sandbox/warm-pool-autoscaling-keda/README.md) (available now): KEDA scales a warm pool up and down with claim demand, so warm capacity tracks demand instead of a fixed count. Spec: [#31](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/31).
- [ide](../examples/agent-sandbox/ide/README.md) (available now): VS Code in the browser on a persistent EBS workspace. Spec: [#32](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/32).
- [argo-rollouts](../examples/agent-sandbox/argo-rollouts/README.md) (available now): rolling a `SandboxTemplate` change through a warm pool with Argo Rollouts, replacing the warm sandboxes built from the old template. Spec: [#33](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/33).
- [brain-and-hands](../examples/agent-sandbox/brain-and-hands/README.md) (available now): the agent (the brain) runs on an ordinary pod with model access and no local shell. Each command it runs goes to a warm sandbox (the hands) that it claims from a pool through the agent-sandbox MCP server and drives through sandboxd, with a template network policy that admits only pods labelled `app=brain` and allows no egress. Spec: [#38](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/38), updated in [#168](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/168).

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

- [temporal](../examples/integrations/temporal/README.md) (available now): Temporal workflows that create, drive, suspend, resume and remove sandboxes. Spec: [#26](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/26).
- opensandbox (blocked until GA): Nitro sandboxes as a secure runtime for OpenSandbox. Waits for Nitro sandboxes to be generally available and the runtime to be added upstream in OpenSandbox. Spec: [#22](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/22).

### Confidential (`confidential`)

These samples use `runtimeClassName: confidential-sandbox`.

The [Confidential section page](../examples/confidential/README.md) holds what they share: the trust boundary, the KMS key-policy shape, the attested decrypt and the measurement caveat.

- [encrypted-image](../examples/confidential/encrypted-image/README.md) (available now): encrypted image layers in Amazon ECR, decrypted inside the sandbox after AWS KMS checks its attested policy. Spec: [#19](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/19).
- [secrets-manager-secret](../examples/confidential/secrets-manager-secret/README.md) (available now): an AWS Secrets Manager secret released only to an approved sandbox. Spec: [#20](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/20).
- [s3-encrypted-file](../examples/confidential/s3-encrypted-file/README.md) (available now): a file encrypted before upload to Amazon S3 and decrypted only inside an approved sandbox. Spec: [#21](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/21).
- [signer-policy](../examples/confidential/signer-policy/README.md) (available now): the section's reference for signer-based image trust. A generated Cedar policy names an AWS Signer profile instead of pinning one digest, so a provider's next release runs with no policy regenerated, shown beside the default digest pin refusing that same release. Spec: [#119](https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/119).
