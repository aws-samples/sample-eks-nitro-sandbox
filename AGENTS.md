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
- **Pick an issue nobody has claimed.** Skip any issue that is assigned, labeled
  `in progress`, or labeled `blocked`:

  ```bash
  gh issue list --repo aws-samples/sample-eks-nitro-sandbox --state open \
    --search 'no:assignee -label:"in progress" -label:blocked'
  ```

- **Read the issue with its comments**, not only its body:
  `gh issue view <issue> --repo aws-samples/sample-eks-nitro-sandbox --comments`. Why:
  maintainers correct or narrow a spec in a comment, and plain `gh issue view` does not show
  comments. One sample was built on an assumption a scope comment had already corrected.
- **If the spec looks wrong, ask on the issue before working around it.** A criterion
  the platform or this file makes impossible to meet is a question for the maintainers, not
  a box to leave unticked. Why: one spec gave a workload that uses no network a deny-all
  egress policy while refusing exec, so no run could ever show the policy working.
- **Claim the issue before you start work.** Comment on it that you are starting, with a
  line on your plan, then assign it to yourself and add the `in progress` label:

  ```bash
  gh issue comment <issue> --repo aws-samples/sample-eks-nitro-sandbox --body-file tmp/claim.md
  gh issue edit <issue> --repo aws-samples/sample-eks-nitro-sandbox \
    --add-assignee @me --add-label "in progress"
  ```

  If `gh issue edit` is refused because you lack permission, say so in your comment and
  ask a maintainer to assign the issue to you and add the label. Start once the comment is
  posted. Why: the assignee and the label are how the next collaborator knows to pick
  another issue, and the comment is where your plan is recorded.
- **Release the claim if you stop.** Comment on where you stopped, remove yourself and the
  label (`--remove-assignee @me --remove-label "in progress"`), or ask a maintainer to.
  Why: a stale claim keeps everyone else off the issue.
- **The pull request that implements a sample says `Closes #<issue>`.** Why: it ties the
  work to the criteria it must meet, and closes the spec when it merges.
- **One pull request implements the whole issue.** If an issue is too big for one pull
  request, split the spec into separate issues before you start, rather than opening a pull
  request for part of one. Why: a reviewer checks one complete sample against all of its
  criteria, and a partial sample on `main` shows readers something unfinished.

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

### The Amazon EKS User Guide before general availability

Until Nitro sandboxes are generally available, the public Amazon EKS User Guide has no page
for them. The pages that will be published are kept as AsciiDoc in the service team's
package, `ssh://git.amazon.com/pkg/EKSPodIsolationRuntime`, under `docs/eks-user-guide/`.
Clone only that folder, next to this repository:

```bash
git clone --depth 1 --filter=blob:none --sparse ssh://git.amazon.com/pkg/EKSPodIsolationRuntime
git -C EKSPodIsolationRuntime sparse-checkout set docs/eks-user-guide
```

If ssh prints `no such identity` for a key file during either clone, it is skipping a key
you do not have; the clone worked if git reports no error after it.

- **Treat those pages as the Amazon EKS User Guide** wherever this file, a skill or a spec
  asks whether the guide states something, such as a limit value. Start with
  `isolated-confidential-pods.adoc`, which links the rest; limits are in
  `isolated-confidential-pods-limitations.adoc`. Why: the public guide does not have them
  yet, so a check against it finds nothing and reads as "not documented".
- **On a page, cite the guide by page title** ("Amazon EKS User Guide, *Isolated and
  confidential pods limitations*") with no link until the public page exists, and never the
  package path. Why: the package is internal, and a link to a page that does not exist yet
  is broken.

### The agent reviewer on the maintainers' workstation

On the maintainers' shared workstation, the Codex reviewer for a second review (see the
`second-review` skill) runs through a wrapper that bills the team's builder account. Run it
from the folder under review, with the brief and output in the repository's `tmp/`:

```bash
setsid nohup env AWS_REGION=us-east-2 AWS_DEFAULT_REGION=us-east-2 \
  ~/.kiro/crew/codex/codex-builder exec --skip-git-repo-check --sandbox read-only \
  -c model_provider="amazon-bedrock" -c model="openai.gpt-5.6-sol" \
  - < tmp/review/brief.md > tmp/review/review.out 2> tmp/review/review.err &
```

- **Use it exactly as written.** Without an `exec -c` option, Codex refuses to load its
  configuration ("aws.credential_export cannot be combined with aws.profile"); `--sandbox
  read-only` keeps the reviewer from editing the tree; the brief goes on standard input.
  Why: each of these was dropped once, and each time the review failed or ran unconfined.
- **Do not change the wrapper or `~/.codex/config.toml`** to make it start. Why: the
  wrapper's profile setting decides which account the review bills.
- **It takes 10 to 25 minutes.** `review.out` is written only at the end; check that it is
  still running with `pgrep -f '[o]penai.gpt-5.6-sol'`. Read `review.err` only with `tail`
  or a targeted search, and never paste it anywhere: it logs credential details. Why the
  brackets: without them the pattern can also match the shell that runs `pgrep`, so a
  review that has exited still looks alive.

### Other tools on the maintainers' workstation

- **The Cedar policy generator.** The Amazon EKS User Guide names it
  `eks-nitro-sandbox-genpolicy` but does not yet say where to get it. On the workstation
  the preview build is on `PATH` as `eks-cc-genpolicy`; elsewhere, the internal
  repository's `eks-cc-genpolicy` skill builds it from source. Have a sample's script take
  the command from a variable (`GENPOLICY`) that defaults to the published name, and pass
  the preview name when you run it. Do not link or rename it in a shared folder. Why: the
  page must name the published command, and the shared `PATH` is other people's too.
- **The preview generator can be older than its source.** If its output disagrees with
  the source or the User Guide, build your own copy from the source, read-only, with
  `CARGO_TARGET_DIR` under the repository's `tmp/`, and pass it as `GENPOLICY`. Never
  rebuild the shared one, and say in the pull request which source commit you built. Why:
  the shared build once predated the handling of `network-isolated`, so the guest refused
  the pod; and other demos' policies, and the PCR17 a key is released to, come from it.
- **Write stub tools with your agent's file tool**, not a heredoc in a shell command, then
  `chmod +x` the file by its path alone. Why: the agent host on this workstation blocks
  some commands by pattern, and a heredoc holding `/usr/bin/env` trips its `chmod` rule.
- **Do not reword a command the agent host blocked to get it past the block.** Files in
  `tmp/` can stay where they are, and a blocked delete is handed off as "Shared accounts,
  clusters and machines" says. Why: the blocks are the host owner's policy, and getting
  around one hides from them that an agent needed it.

The two repository URLs, this reviewer command and the preview generator's name are the
only internal values this file holds, at the maintainers' choice. Remove them before this
repository is made public, which needs Nitro sandboxes to be generally available first: until then the pages above, and any
sample that quotes them, describe an unreleased feature.

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
  keys, tokens, names of your clusters or hosts, user names or internal URLs. The only
  exceptions are the internal values in
  [Start from an internal demo](#start-from-an-internal-demo). Use
  placeholders such as `<ACCOUNT_ID>` and a gitignored local env file; the shared defaults
  on the home page (`sandbox-demo`, `us-west-2`, `nitro-sandboxes-demo`) are fine. Why:
  the repository is public, so anything committed is published.
- **Never put a secret on a command line.** Read it from a file or standard input, as the
  coding agent and Claude Managed Agents samples do. Why: a command line is visible to
  other processes and lands in shell history.
- **Give each IAM role only what the sample needs**, through EKS Pod Identity. Why: the
  role is what code inside the sandbox can use.

## Shared accounts, clusters and machines

You will often verify a sample in an AWS account, a cluster and on a workstation that other
people's demos use at the same time.

- **Name every resource for the sample**, and take from `.env` any name AWS will not let
  you reuse after deletion. Why: an AWS Signer profile name stays taken for years after the
  profile is canceled, so a second run with the same name fails.
- **Mark what the sample creates, and check the mark before touching anything.** Tag every
  AWS resource the sample creates `ManagedBy=<sample>` and label its namespace. A script
  reuses or deletes only a resource that carries the mark, checks the namespace's label
  before deleting anything inside it, and stops with a clear message otherwise. A resource
  with the mark counts as the sample's, whichever run created it. Applying a manifest over
  an existing object counts as reusing it, so create a namespace only when it is absent.
  Why: other demos in the account use similar names, and three review rounds of one sample
  each found a script that could reuse or delete something it did not own.
- **Inside the sample's own namespace, the namespace check is enough.** Once a script has
  confirmed the namespace carries the sample's label, everything in it is the sample's: do
  not add an ownership check for each object. A volume a CSI driver provisions for a claim
  belongs to the claim, so do not tag it in AWS yourself; the clean up confirms it is gone.
  Why: one sample's review rounds added a check for every object until its helper scripts
  ran to about 300 lines around two patches and a delete, and its setup wrote tags to the
  reader's account that the page never mentioned.
- **Delete what you made for yourself by its exact name.** A helper pod (`kubectl debug
  node/...`, a probe pod) is removed with `kubectl delete pod <name> -n <namespace>`, never
  with a label selector. Why: a selector meant for one helper pod deleted another demo's
  pod on the shared cluster.
- **A name the reader can change reaches every object that uses it.** If a script takes a
  name from a variable (`NAMESPACE=...`), render each manifest it applies with that name,
  and never apply one that hard-codes the default. Why: in one sample the override still
  applied the default-named namespace manifest, which put the sample's label on a namespace
  another demo owned, so the next clean up would have deleted it.
- **Leave cluster-wide settings to the reader.** A script never changes something every
  workload on the cluster shares, such as a ConfigMap in `kube-system`. The page has the
  reader make that change as a step, as the coding agent page does for network policy
  enforcement, and the script checks it and stops with the command when it is off. Why:
  other workloads depend on it, and one setup script changed `amazon-vpc-cni` for everyone.
- **A StorageClass is chosen, never changed.** Setup uses the cluster's default class when
  it fits the sample (provisioner `ebs.csi.eks.amazonaws.com`, and the type and encryption
  the sample needs), and otherwise creates its own class: named for the sample, not the
  default, marked as the sample's, and created with `kubectl create` only when absent. The
  claims always name the class they use. Never `kubectl apply` a manifest over an existing
  class. Why: applying over a class that was created with `kubectl apply` can remove its
  default annotation, which changes how every other claim on the cluster is provisioned.
- **A clean up says what it could not do.** A lookup that fails means "could not
  determine", which is a failure, never "gone"; a resource skipped because it is not the
  sample's leaves the clean up incomplete, and the script exits non-zero. Why: a lookup
  against the wrong cluster once reported a namespace that still existed as deleted.
- **Name the cluster you mean.** Pin the kube context for your own shell, with
  `kubectl --context <name>` or a `KUBECONFIG` whose first file sets only
  `current-context`, check `kubectl config current-context` before a run, and never run
  `kubectl config use-context` on a shared machine. Why: another session changed the
  shared context in the middle of a run.
- **Keep local files in the repository's `tmp/`**, which git ignores: logs, captured
  output, copies of state files, review briefs and output, stub tools, hand-off scripts.
  Never put them in a sample folder or its `.gitignore`. Why: anything in a sample folder is
  one `git add` from being published, and the sample's `.gitignore` is published with it.
- **If your environment blocks a delete, leave the rest as a script in `tmp/`.** List the
  AWS deletes first and the namespace last, with the Region or `--context` named on each,
  and say in the pull request what is left. Why: a step that fails stops the ones after
  it, and a command without a context runs against whatever context is current.
- **Run the clean up when you finish**, after the last run the page uses, and say in the
  pull request what is left. Why: a sandbox pod left running holds capacity other demos on
  the cluster share.
- **Do not change global tool configuration** (shell profiles, files under `~/.config`,
  version managers) to run a sample. Install what it needs under `tmp/`, or say what is
  missing. Why: the machine is shared, and a reader needs the same tools, so the page's
  prerequisites list them with their versions.

## Verification rules

- **Show only output from a real run**, and say when it is abridged. Save each run's
  output under `tmp/` (`./scripts/setup.sh 2>&1 | tee tmp/<sample>/setup.log`) and copy the
  blocks from that file. If the run used a different name from the one the page shows,
  keep the run's name or say on the page, beside the block, that you changed it; a note in
  the pull request is not enough. Why: readers compare their own output with the page, and
  one page showed a line that none of its runs had printed.
- **Until that run, put `TODO: output from the fresh run` in each output block**, never
  output you wrote yourself. Why: written output reads like a real run, so neither you nor a
  reviewer can tell later which blocks were run.
- **Check each claim on a live cluster**, not only in the manifests. Why: a static check
  passes on things that are wrong at runtime.
- **Prove a sample with a fresh run**, not by resuming an earlier one. A fresh run starts
  with none of the sample's resources present: run the clean up first, or point the run at
  new names. Why: a resumed run can skip the very steps whose output the page shows. In one
  sample every run started with its namespace already there, so the step that creates it
  never ran live.
- **Prove every check both ways**: one input it must accept, one it must reject. Why: a
  check run only on good input cannot be told apart from one that accepts everything.
- **Prove the check in the script itself, not in a copy.** For an input you cannot create,
  run the real script with a stub command first on `PATH` (a fake `aws` in `tmp/` that
  prints the case you need). Make the stub fail only the call the check makes. Why: a
  pasted copy of the check stops matching the script at its next edit, and the test keeps
  passing. A stub that fails every call stops the script at its first call, before the
  check you meant to prove.
- **Anchor search patterns (`^`) and strip comments before matching.** Why: an unanchored
  pattern can match its own explanatory comment, as in `# type: ClusterIP` written above
  `type: LoadBalancer`.

## Review

- **Get a second reviewer, a person or another agent, for any change to a check, a
  credential path or a security claim.** The `second-review` skill says how to brief one,
  run it and record the result. Why: those fail silently; the sample still runs and the
  page still reads well.
- **The pull request's checklist is the issue's acceptance criteria plus this
  repository's quality bar.** Copy `.github/pull_request_template.md` to
  `tmp/pr-body.md`, and paste every box from the issue's *Acceptance criteria* under "From
  the issue", word for word:

  ```bash
  gh issue view <issue> --repo aws-samples/sample-eks-nitro-sandbox --json body --jq .body \
    | tr -d '\r' | awk '/^## Acceptance criteria/{f=1; next} /^## /{f=0} f && /^- \[ \]/'
  ```

  Keep the template's "Quality bar" list whole, even where an issue box says the same
  thing, and keep its last line. Tick a box only when it is met, with a pointer to the
  evidence; leave one that does not apply unticked and say why. Pass the file with
  `--body-file` and update it the same way (`gh pr edit --body-file`). For an issue with no
  checkboxes, turn what it says must be true into boxes. Why: the issue's criteria are what
  this change agreed to do, and the quality bar is what every change here must meet, so a
  reviewer checks the pull request against both; and `--body-file` skips the template, so
  a description written from scratch loses both lists and the contribution statement on
  the last line.
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
| `second-review` | Get the second review a change to a check, a credential path or a security claim needs: brief the reviewer, run it without write access, triage what it finds, and record it in the pull request. |

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
