# Amazon EKS Nitro sandbox samples

Runnable samples for Nitro Sandboxes on Amazon EKS: hardware-enforced workload isolation where each pod runs its containers inside a lightweight VM carved from a Nitro Partition. The samples are rendered as a documentation site, and a path on the site is the path in this repository.

## Getting started

- [Hello sandbox](examples/getting-started/hello-sandbox/README.md): a plain pod that opts into a sandbox with one line, and a variant with no network.
- [Coding agent](examples/getting-started/coding-agent/README.md): Claude Code in a sandbox that reads a GitHub issue, fixes it and opens a pull request.
- [Warm pool](examples/getting-started/warm-pool/README.md): a pool of pre-booted sandboxes and a claim that adopts one in under 1 second.

Start from the [site home page](examples/README.md) for what a Nitro sandbox is and the prerequisites the samples share.

## Isolation

- [Network policy](examples/isolation/network-policy/README.md): a standard egress NetworkPolicy enforced on a sandboxed pod, side by side with an ordinary pod that is the control.

## Managed agents

- [Claude Managed Agents](examples/managed-agents/claude-managed-agents/README.md): a Claude Managed Agents self-hosted sandbox where each session's tool calls run in a sandbox of their own and the organization API key stays off the cluster.

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
