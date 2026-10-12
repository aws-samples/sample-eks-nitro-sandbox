# Amazon EKS Nitro sandbox samples

Runnable samples for Nitro Sandboxes on Amazon EKS: hardware-enforced workload isolation where each pod runs its containers inside a lightweight VM carved from a Nitro Partition. The samples are rendered as a documentation site, and a path on the site is the path in this repository.

## Getting started

- [Hello sandbox](examples/getting-started/hello-sandbox/README.md): a plain pod that opts into a sandbox with one line, and a variant with no network.
- [Coding agent](examples/getting-started/coding-agent/README.md): Claude Code in a sandbox that reads a GitHub issue, fixes it and opens a pull request.
- [Warm pool](examples/getting-started/warm-pool/README.md): a pool of pre-booted sandboxes and a claim that is served in about two seconds.

Start from the [site home page](examples/README.md) for what a Nitro sandbox is and the prerequisites the samples share.

## Preview the site locally

```bash
pip install -r requirements-docs.txt
mkdocs serve
```

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.
