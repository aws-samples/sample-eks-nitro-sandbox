Closes #

<!-- For a new sample, the number of its spec issue. For a fix with no issue, replace the line above with what it fixes. -->

## What this changes

## How it was checked

- [ ] For a sample: ran it end to end from a fresh run on a live cluster, and every output block on the page comes from that run
- [ ] `mkdocs build --strict` passes, and nothing under `examples/` changed that this pull request does not mean to change
- [ ] `./scripts/check-agent-files.sh` passes
- [ ] No account IDs, keys, cluster names, hostnames, user names or internal URLs in the changed files
- [ ] No Ingress, LoadBalancer or NodePort; sandbox egress is restricted by network policy
- [ ] A second reviewer looked at any change to a check, a credential path or a security claim

By submitting this pull request, I confirm that you can use, modify, copy, and redistribute this contribution, under the terms of your choice.
