# Amazon EKS Nitro sandbox samples

Runnable samples for Nitro Sandboxes on Amazon EKS: hardware-enforced workload isolation where each pod runs its containers inside its own Nitro sandbox, a hardware-isolated environment with its own kernel. The samples are rendered as a documentation site, and a path on the site is the path in this repository.

## Getting started

- [Hello sandbox](examples/getting-started/hello-sandbox/README.md): a plain pod that opts into a sandbox with one line, and a variant with no network.
- [Coding agent](examples/getting-started/coding-agent/README.md): Claude Code in a sandbox that reads a GitHub issue, fixes it and opens a pull request.
- [Warm pool](examples/getting-started/warm-pool/README.md): a pool of pre-booted sandboxes and a claim that adopts one in under 1 second.

Start from the [site home page](examples/README.md) for what a Nitro sandbox is and the prerequisites the samples share.

## Isolation

- [Network policy](examples/isolation/network-policy/README.md): a standard egress NetworkPolicy enforced on a sandboxed pod, side by side with an ordinary pod that is the control.
- [Sandbox limits](examples/isolation/sandbox-limits/README.md): the per-sandbox DNS query-rate limit and the per-pod outbound connection limit, made visible on your own cluster side by side with an ordinary pod, and how to recognise each one.

## Policy

- [Image signing](examples/policy/image-signing/README.md): an image signed with AWS Signer and verified with Notation inside the guest, while an unsigned image is rejected, with an optional variant that verifies with no network at all.
- [Cedar policy](examples/policy/cedar-policy/README.md): a Cedar policy generated from a workload's pod spec and enforced inside a confidential sandbox guest, which admits the expected container and refuses an operator's exec.

## AI agents

- [Coding agents for developers](examples/ai-agents/coding-agents-for-developers/README.md): a web app where a developer picks a coding agent and gets a browser terminal, each session in its own sandbox claimed from a warm pool, with a per-session S3 Files workspace only that session's pod can mount.

## Managed agents

- [Claude Managed Agents](examples/managed-agents/claude-managed-agents/README.md): a Claude Managed Agents self-hosted sandbox where each session's tool calls run in a sandbox of their own and the organization API key stays off the cluster.

## Subagent security

The same procurement analyst three ways, with a second policy layer confining the tool processes it runs inside its sandbox. The [section page](examples/subagent-security/README.md) covers the analyst, the case and what the three samples share.

- [Procurement analyst confined by nono](examples/subagent-security/nono/README.md): reader, evaluator and writer run as separate processes under per-role nono profiles inside one sandbox, with nono's proxy holding the supplier API key and allowing one hostname and a short list of HTTP operations, while the analyst still produces a cited recommendation checked against a deterministic comparison.

## Agent sandbox

- [Pause and resume](examples/agent-sandbox/pause-resume/README.md): suspend a sandbox to release its compute and keep its EBS workspace, then resume onto a new guest with the data intact.
- [Warm pool autoscaling with KEDA](examples/agent-sandbox/warm-pool-autoscaling-keda/README.md): KEDA reads a count of `SandboxClaim` objects and drives a warm pool's `spec.replicas` up and back down with it, with a no-autoscaler control that stays flat under the same demand.
- [IDE in the browser](examples/agent-sandbox/ide/README.md): code-server (VS Code in the browser) in a sandbox on a persistent EBS workspace, reached only by `kubectl port-forward`, with its password an argon2 hash from a Kubernetes Secret.
- [Roll out a SandboxTemplate change with Argo Rollouts](examples/agent-sandbox/argo-rollouts/README.md): patching a `SandboxTemplate` leaves the warm pool serving pods built from the old one, so a claim can adopt a stale pod; an Argo Rollouts canary step plugin patches the template and then drains and re-warms the pool.
- [Brain and hands](examples/agent-sandbox/brain-and-hands/README.md): an agent split in two, a brain that reasons with no tool that runs a command and hands that run every command in a network-isolated sandbox pod claimed from a warm pool, with the Kubernetes API the only wire between them.

## Storage

- [EBS volumes](examples/storage/ebs/README.md): a sandboxed pod and a StatefulSet backed by dynamically provisioned, encrypted EBS volumes that outlive the pod, seen inside the guest as virtio devices.
- [Shared EFS storage](examples/storage/efs/README.md): two sandboxed pods share one EFS file system through a single access point, mounted over TLS with IAM authorization, so each pod reads and writes the same `/shared` directory.
- [Shared S3 Files storage](examples/storage/s3-files/README.md): two sandboxed pods share one S3 Files access point, backed by a versioned S3 bucket, so the same data is both a shared `/shared` POSIX file system and plain S3 objects addressable from outside the cluster.

## CI/CD

- [Docker builds](examples/ci-cd/docker-builds/README.md): a privileged Docker daemon builds and runs container images inside a sandbox, by hand and as an unattended Job, with an EBS layer cache across Job runs and an optional push to Amazon ECR through a role scoped to one repository.
- [GitHub Actions runners](examples/ci-cd/github-actions/README.md): the GitHub Actions Runner Controller on EKS, where every ephemeral runner pod for a queued job is its own sandbox, running a privileged `docker build` and arbitrary test code that never reach the shared node, and is deleted when the job ends.
- [GitLab CI jobs](examples/ci-cd/gitlab-ci/README.md): a self-hosted GitLab and a GitLab Runner on EKS, where one line of runner configuration puts every CI job pod in its own sandbox, including a privileged `docker build` that starts its own Docker daemon, while the runner manager stays an ordinary pod.

## Confidential

Samples that use `runtimeClassName: confidential-sandbox`, where the node is untrusted and AWS KMS releases a key only to a sandbox whose attestation matches. The [section page](examples/confidential/README.md) covers what they share.

- [Encrypted image](examples/confidential/encrypted-image/README.md): a container image whose every layer is ciphertext in Amazon ECR, decrypted inside the sandbox by the guest image runtime once KMS has checked the attested policy measurement, while the same credentials used from outside the sandbox are refused.
- [Secrets Manager secret](examples/confidential/secrets-manager-secret/README.md): a secret stored as a KMS ciphertext envelope in AWS Secrets Manager, read and decrypted by the application inside the sandbox under an attestation KMS accepts, while an ordinary pod holding the same role can read the ciphertext and is refused the value.
- [S3 encrypted file](examples/confidential/s3-encrypted-file/README.md): a file encrypted with AES-256-GCM before it is uploaded to Amazon S3, whose data key AWS KMS releases only to an approved sandbox, so the application decrypts it in guest memory while a holder of the same credentials outside the sandbox can read the object and not the file.

## Preview the site locally

```bash
pip install -r requirements.txt
mkdocs serve
```

See [ROADMAP.md](docs/ROADMAP.md) for the samples planned next. To add one, start with [CONTRIBUTING](CONTRIBUTING.md#adding-a-sample) and [AGENTS.md](AGENTS.md).

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.
