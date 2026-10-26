Closes #

<!-- The issue this pull request implements. For a change with no issue, replace the line above with what it changes, and delete the "From the issue" section. -->

## What this changes

## From the issue

<!-- Paste every box from the issue's "Acceptance criteria" section here, word for word (the command is in AGENTS.md, Review). Tick a box only when it is met, and add a pointer to the evidence after it: the page section, the log under tmp/, the commit. If one is not met, leave it unticked and say why. -->

## Quality bar

<!-- This repository's bar for every pull request (AGENTS.md). Keep the whole list, even where an issue box above says the same thing. Tick a box only when it is true; leave one that does not apply unticked and say why. For a sample, open this pull request as a draft (gh pr create --draft) until the fresh-run box is true. -->

- [ ] For a sample: ran it end to end from a fresh run on a live cluster, every output block on the page comes from that run, and no `TODO: output from the fresh run` marker is left
- [ ] For a sample: the page shows the pod's own kernel build, boot and virtio disks, each with what an ordinary pod shows instead
- [ ] For a sample: the page claims no network limit that nothing in the sample enforces, and a network-isolated sandbox is shown to have only loopback, no route and no DNS
- [ ] For a sample: the clean up ran after the last run, and anything it could not remove is listed in this description
- [ ] For a sample: added to the `mkdocs.yml` nav (`--strict` does not catch a missing entry), and `docs/ROADMAP.md` (linked, `(available now)`) and the root `README.md` updated
- [ ] `mkdocs build --strict`, `./scripts/check-agent-files.sh` and `./scripts/check-sample-index.sh` pass
- [ ] The branch has the latest `main` merged in (no rebase or force-push), with conflicts resolved as AGENTS.md says, and the checks pass on its current head
- [ ] Only the files this pull request means to change are changed; logs, captured output, stubs and hand-off scripts stay in `tmp/`
- [ ] No values from your own account or environment (account IDs, keys, tokens, names of your clusters or hosts, user names, internal URLs) in the changed files
- [ ] No Ingress, LoadBalancer or NodePort; a new sample ships no network policy, and its IAM role through Pod Identity grants only what it needs
- [ ] Any check added or changed is proved both ways: an input it must accept, and an input it must reject
- [ ] A second reviewer looked at any change to a check, a credential path or a security claim (see "Second review")

## Second review

<!-- Who or what reviewed it, which commit, what it found, what was fixed and where, and which findings were false positives and why (the second-review skill says how). If the change needed none, say why. -->

By submitting this pull request, I confirm that you can use, modify, copy, and redistribute this contribution, under the terms of your choice.
