Closes #

<!-- For a new sample, the number of its spec issue. For a fix with no issue, replace the line above with what it fixes. -->

## What this changes

## How it was checked

- [ ] For a sample: ran it end to end from a fresh run on a live cluster, and every output block on the page comes from that run
- [ ] For a sample: added to the `mkdocs.yml` nav (`--strict` does not catch a missing entry), and `docs/ROADMAP.md` and the root `README.md` updated
- [ ] `mkdocs build --strict` passes, and nothing under `examples/` changed that this pull request does not mean to change
- [ ] `./scripts/check-agent-files.sh` passes
- [ ] Any check added or changed is proved both ways: an input it must accept, and an input it must reject
- [ ] No values from your own account or environment (account IDs, keys, tokens, names of your clusters or hosts, user names, internal URLs) in the changed files
- [ ] No Ingress, LoadBalancer or NodePort; sandbox egress is restricted by network policy, or the sandbox has no network
- [ ] A second reviewer looked at any change to a check, a credential path or a security claim

By submitting this pull request, I confirm that you can use, modify, copy, and redistribute this contribution, under the terms of your choice.
