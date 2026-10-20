Closes #

<!-- The issue this pull request implements. For a change with no issue, replace the line above with what it changes, and delete the "From the issue" section. -->

## What this changes

## From the issue

<!-- Paste every box from the issue's "Acceptance criteria" section here, word for word (the command is in AGENTS.md, Review). Tick a box only when it is met, and add a pointer to the evidence after it: the page section, the log under tmp/, the commit. If one is not met, leave it unticked and say why. For a sample, open this pull request as a draft (gh pr create --draft) until the fresh-run box is true. -->

## Every pull request

- [ ] `mkdocs build --strict` and `./scripts/check-agent-files.sh` pass
- [ ] Only the files this pull request means to change are changed; logs, captured output, stubs and hand-off scripts stay in `tmp/`
- [ ] No values from your own account or environment (account IDs, keys, tokens, names of your clusters or hosts, user names, internal URLs) in the changed files
- [ ] Any check added or changed is proved both ways: an input it must accept, and an input it must reject
- [ ] A second reviewer looked at any change to a check, a credential path or a security claim (see "Second review")

## Second review

<!-- Who or what reviewed it, which commit, what it found, what was fixed and where, and which findings were false positives and why (the second-review skill says how). If the change needed none, say why. -->

By submitting this pull request, I confirm that you can use, modify, copy, and redistribute this contribution, under the terms of your choice.
