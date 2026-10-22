# Amazon EKS Nitro sandbox samples

Runnable samples for Nitro Sandboxes on Amazon EKS: hardware-enforced workload isolation where each pod runs its containers inside a lightweight VM carved from a Nitro Partition. The samples are rendered as a documentation site, and a path on the site is the path in this repository.

## Getting started

- [Hello sandbox](examples/getting-started/hello-sandbox/README.md): a plain pod that opts into a sandbox with one line, and a variant with no network.
- [Coding agent](examples/getting-started/coding-agent/README.md): Claude Code in a sandbox that reads a GitHub issue, fixes it and opens a pull request.
- [Warm pool](examples/getting-started/warm-pool/README.md): a pool of pre-booted sandboxes and a claim that adopts one in under 1 second.

Start from the [site home page](examples/README.md) for what a Nitro sandbox is and the prerequisites the samples share.

## Setup

- [Ubuntu AMI](examples/setup/ubuntu-ami/README.md): build a custom Ubuntu 24.04 node AMI for EKS Pod Isolation and add one dedicated, tainted managed node group to an existing cluster, for readers who manage their own node OS instead of EKS Auto Mode.

## Isolation

- [Network policy](examples/isolation/network-policy/README.md): a standard egress NetworkPolicy enforced on a sandboxed pod, side by side with an ordinary pod that is the control.
- [Sandbox limits](examples/isolation/sandbox-limits/README.md): the per-sandbox DNS query-rate limit and the per-pod outbound connection limit, made visible on your own cluster side by side with an ordinary pod, and how to recognise each one.

## Policy

- [Image signing](examples/policy/image-signing/README.md): an image signed with AWS Signer and verified with Notation inside the guest, while an unsigned image is rejected, with an optional variant that verifies with no network at all.
- [Cedar policy](examples/policy/cedar-policy/README.md): a Cedar policy generated from a workload's pod spec and enforced inside a confidential sandbox guest, which admits the expected container and refuses an operator's exec.

## Managed agents

- [Claude Managed Agents](examples/managed-agents/claude-managed-agents/README.md): a Claude Managed Agents self-hosted sandbox where each session's tool calls run in a sandbox of their own and the organization API key stays off the cluster.

## Agent sandbox

- [Pause and resume](examples/agent-sandbox/pause-resume/README.md): suspend a sandbox to release its compute and keep its EBS workspace, then resume onto a new guest with the data intact.

## Storage

- [EBS volumes](examples/storage/ebs/README.md): a sandboxed pod and a StatefulSet backed by dynamically provisioned, encrypted EBS volumes that outlive the pod, seen inside the guest as virtio devices.
- [Shared EFS storage](examples/storage/efs/README.md): two sandboxed pods share one EFS file system through a single access point, mounted over TLS with IAM authorization, so each pod reads and writes the same `/shared` directory.
- [Shared S3 Files storage](examples/storage/s3-files/README.md): two sandboxed pods share one S3 Files access point, backed by a versioned S3 bucket, so the same data is both a shared `/shared` POSIX file system and plain S3 objects addressable from outside the cluster.

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
