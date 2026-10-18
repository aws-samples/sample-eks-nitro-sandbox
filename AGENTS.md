# AGENTS.md

This repository holds runnable samples for Nitro Sandboxes on Amazon EKS, published as a
documentation site. These rules apply to everyone who changes it, people and coding agents
alike. Each rule says why it exists, so you can tell when a case is new.

## Layout

| Path | What it is |
|---|---|
| `examples/` | The site. `docs_dir` in `mkdocs.yml` points here, so a path on the site is the path in the repo. |
| `examples/README.md` | The home page: what a Nitro sandbox is, and the prerequisites every sample shares. |
| `examples/<section>/<sample>/` | One sample. Its page is `README.md`, next to the files it applies, with diagrams in `images/` and, when it has them, `deploy/`, `scripts/` and `src/`. |
| `docs/ROADMAP.md` | The planned samples, the section names and the layout conventions. |
| `mkdocs.yml` | The site configuration, including the left menu (`nav`). |
| `.agents/skills/` | The agent skills, one copy each. The other skills folders are links to it. |
| `scripts/` | Checks that run with no cluster and no AWS account. |

## Preview and build the site

```bash
pip install -r requirements.txt
mkdocs serve                 # http://127.0.0.1:8000, on your machine only
mkdocs build --strict        # must pass before a pull request
```

`mkdocs build --strict` turns a broken link into an error, which is what a reader would
otherwise hit first. It does not catch a page missing from `nav`: that page still builds
but has no entry in the left menu, so add the `nav` line yourself.

## A sample starts as a spec in a GitHub issue

- **No sample implementation starts before a GitHub issue holds its spec.** Write it with
  the `sample-spec` skill or the **Sample spec** issue form. Why: the issue is where scope
  and acceptance criteria are agreed, before anyone spends cluster time or reviewer time.
- **The pull request that implements a sample says `Closes #<issue>`.** Why: it ties the
  work to the criteria it must meet, and closes the spec when it merges.

Issue #2 is the model spec.

## Start from an internal demo

Many samples on the roadmap already have a working demo in the maintainers' internal
repository, `git@ssh.gitlab.aws.dev:carrlos/eks-nitro-sandbox-testing.git`.

- **Before you implement a sample, clone the internal repository and search it for the same
  or a close implementation.** Clone it next to this repository, not inside it, and look
  under its `examples/` (`isolated/`, `confidential/`, `integrations/`) and the rest of the
  tree. Reuse and adjust what you find instead of starting over, and say in the pull request
  which internal demo the sample came from. Why: a ported demo starts from something that
  already ran, with its findings and fixes.
- **Treat the internal clone as read-only reference, and do the work in this repository.**
  Bring over manifests, scripts and findings; leave behind its `AGENTS.md`, skills, review
  tooling and publishing steps, and follow this file instead. Why: the internal repository
  has its own conventions, internal values and rules that do not apply here.
- **Port it to this repository's rules**: its layout, its page structure, and placeholders in
  place of every value from the internal repository's account and cluster. Then prove the
  sample with a fresh run here. Why: output copied from the internal demo did not come from
  this sample.

The internal repository's URL is the one internal value this file holds, at the
maintainers' choice. Remove it before this repository is made public.

## Security rules

- **No Ingress, LoadBalancer or NodePort.** Reach a service with ClusterIP and
  `kubectl port-forward`. Why: a sample must never put a public endpoint on a reader's
  account.
- **Restrict the egress of every sandbox that has a network with a network policy, and
  show the whole policy on the page.** Why: the policy is what limits where code in the
  sandbox can connect, so a reader needs to see every rule. A sandbox booted with
  `sandbox.amazonaws.com/network-isolated: "true"` has no network to restrict; show that
  instead.
- **No values from your own account or environment in tracked files**: no account IDs,
  keys, tokens, names of your clusters or hosts, user names or internal URLs. The one
  exception is the repository URL in
  [Start from an internal demo](#start-from-an-internal-demo). Use
  placeholders such as `<ACCOUNT_ID>` and a gitignored local env file; the shared defaults
  on the home page (`sandbox-demo`, `us-west-2`, `nitro-sandboxes-demo`) are fine. Why:
  the repository is public, so anything committed is published.
- **Never put a secret on a command line.** Read it from a file or standard input, as the
  coding agent and Claude Managed Agents samples do. Why: a command line is visible to
  other processes and lands in shell history.
- **Give each IAM role only what the sample needs**, through EKS Pod Identity. Why: the
  role is what code inside the sandbox can use.

## Verification rules

- **Show only output from a real run**, and say when it is abridged. Why: readers compare
  their own output with the page.
- **Until that run, put `TODO: output from the fresh run` in each output block**, never
  output you wrote yourself. Why: written output reads like a real run, so neither you nor a
  reviewer can tell later which blocks were run.
- **Check each claim on a live cluster**, not only in the manifests. Why: a static check
  passes on things that are wrong at runtime.
- **Prove a sample with a fresh run**, not by resuming an earlier one. Why: a resumed run
  can skip the very steps whose output the page shows.
- **Prove every check both ways**: one input it must accept, one it must reject. Why: a
  check run only on good input cannot be told apart from one that accepts everything.
- **Anchor search patterns (`^`) and strip comments before matching.** Why: an unanchored
  pattern can match its own explanatory comment, as in `# type: ClusterIP` written above
  `type: LoadBalancer`.

## Review

- **Get a second reviewer, a person or another agent, for any change to a check, a
  credential path or a security claim.** Why: those fail silently; the sample still runs
  and the page still reads well.
- **Open a sample's pull request as a draft until its fresh run is on the page**
  (`gh pr create --draft`), then mark it ready. Why: a ready pull request invites review
  and merge of output that has not been run yet.
- **Do not force-push a shared branch.** Why: it rewrites history other people have built
  on.
- Write commit messages that say what was wrong and how the fix was proved. Why: the next
  reader should not have to work it out again.

## Skills

| Skill | Use it to |
|---|---|
| `sample-spec` | Write a new sample's spec as a GitHub issue, before any implementation. |
| `sample-page` | Build the sample and write its page: layout, stages, network policy section, clean up, nav entry and roadmap update. |
| `nitro-sandbox-pods` | Get the facts right about how a Nitro sandbox pod works, in `isolated-sandbox` and `confidential-sandbox` mode, and how a sample proves it ran in one. |
| `aws-diagrams` | Draw draw.io architecture diagrams in the style of the existing figures, exported to PNG. |
| `slack-updates` | Post a status update to the maintainers' Slack channel, checked and confirmed, using the local settings a maintainer gives you. |

Edit skills only in `.agents/skills/`. Then run `./scripts/check-agent-files.sh`, which
fails on a broken link, a second copy of a skill, or a skill this table does not list.

## Where each tool finds these files

| Tool | Instructions it reads | Skills folder it reads |
|---|---|---|
| Kiro CLI | `AGENTS.md` | `.kiro/skills`, a link to `.agents/skills` |
| Kiro Crew | `AGENTS.md` (its sessions run on Kiro CLI) | `.kiro/skills`, once you trust the project |
| Claude Code | `CLAUDE.md`, a link to `AGENTS.md` | `.claude/skills`, a link to `.agents/skills` |
| Codex | `AGENTS.md` | `.agents/skills` |
| opencode | `AGENTS.md` | `.agents/skills`, and `.claude/skills` too |
| pi | `AGENTS.md` | `.agents/skills`, once you trust the project |

opencode reads both folders, so it sees each skill twice and may warn about a duplicate
name; the content is the same. `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` stops it reading
`.claude/skills`.

## Windows

The links above are git symbolic links. Before you clone, turn on Developer Mode (or run
Git as an administrator) and run:

```bash
git config --global core.symlinks true
```

Without it, git checks out each link as a small text file holding the target path, and the
tools find no skills and no `CLAUDE.md` content.
