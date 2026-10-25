# AGENTS.md

This repository holds runnable samples for Nitro Sandboxes on Amazon EKS, published as a
documentation site. These rules apply to everyone who changes it, people and coding agents
alike. Each rule says why it exists, so you can tell when a case is new.

Questions and review pings go to the internal Slack channel `#eks-nitro-sandbox-interest`.

## Layout

| Path | What it is |
|---|---|
| `examples/` | The site. `docs_dir` in `mkdocs.yml` points here, so a path on the site is the path in the repo. |
| `examples/README.md` | The home page: what a Nitro sandbox is, and the prerequisites every sample shares. |
| `examples/<section>/<sample>/` | One sample. Its page is `README.md`, next to the files it applies, with diagrams in `images/` and, when it has them, `deploy/`, `scripts/` and `src/`. |
| `docs/ROADMAP.md` | The planned samples, the section names and the layout conventions. |
| `mkdocs.yml` | The site configuration, including the left menu (`nav`). |
| `.agents/skills/` | The agent skills, one copy each. The other skills folders are links to it. |
| `scripts/` | Checks that run with no cluster and no AWS account, and `second-review.sh`, which runs a second review on a reviewer backend you name. |

## Preview and build the site

```bash
pip install -r requirements.txt
mkdocs serve                 # http://127.0.0.1:8000, on your machine only
mkdocs build --strict        # must pass before a pull request
```

`mkdocs build --strict` turns a broken link into an error, which is what a reader would
otherwise hit first. It does not catch a page missing from `nav`: that page still builds
but has no entry in the left menu, so add the `nav` line yourself.
`./scripts/check-sample-index.sh` does catch it. It also catches a sample missing from
`docs/ROADMAP.md` or the root `README.md`, a section heading left twice, and a conflict
marker left in any tracked file.

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

### The adversarial second reviewer

`AGENTS.md` requires a second review for any change to a check, a credential path or a
security claim. **There are three sanctioned ways to do it, and they are interchangeable:**

1. **The Codex CLI**, through `scripts/second-review.sh --backend codex`.
2. **The Claude Code CLI**, through `scripts/second-review.sh --backend claude`.
3. **A fresh sub agent in your own session**, dispatched with no context from the work you
   are asking it to review.

You pick, and no approval is needed. What matters is not which one you use but the three
invariants below. The script works to hold them for you on paths 1 and 2 — by different
means for each, and with limits worth reading, set out under [Running it](#running-it) — and
you hold them yourself on path 3.

**Adversarial** describes what the reviewer does, not how the brief is worded: it assumes
the implementer's code is wrong and tries to break the claims it makes. It does not mean
writing the brief as an attack exercise — a brief framed that way has been refused outright
by a reviewer's safety filter. The `second-review` skill ships a brief template, written as
a maintainer asking for a check of their own commit against stated invariants, that works
unchanged on both backends.

Three invariants make a second review worth having, and they are what to keep whichever
reviewer you use:

1. **It runs on a different model from the one that wrote the change.** Why: a model
   reviewing its own work repeats its own reasoning.
2. **It must not be able to write to the tree it reviews, and is shown to have left it
   unchanged.** Those are two separate things — how the backend was confined, and what the
   tree looked like afterwards — and the two backends do not establish them identically.
   Why: a reviewer that edits the code is no longer telling you what the code says.
3. **The model that actually answered is recorded in the pull request.** Why: an alias such
   as `opus`, or a Bedrock prompt router, can resolve to the very model you were avoiding,
   so the name you asked for is not evidence.

#### Running it

`scripts/second-review.sh` runs either backend. It holds the different-model and
recorded-model invariants the same way for both, and the read-only one by different means
for each — see [What "read-only" rests on, per backend](#what-read-only-rests-on-per-backend)
below. Run it from the repository root, with the brief, the snapshot of the commit and the
output under `tmp/`:

```bash
# $round is the folder the second-review skill's quick start prepares: one per round, with
# tree/ extracted from the commit, brief.md written, and context/change.diff in place. Set
# it up there first -- these commands only run the reviewer.

./scripts/second-review.sh --backend codex  --model openai.gpt-5.6-sol \
  --implementer-model <the model that wrote the change> \
  --brief "$round/brief.md" --tree "$round/tree" --out "$round/out"

# Claude needs a context directory, because its file tools reach only the tree, the
# directories it is given, and its own working directory -- so the diff the brief names
# must be in one. Add SECOND_REVIEW_CLAUDE_SETTINGS as well only if your claude
# authenticates through a settings file; it is not needed otherwise.
SECOND_REVIEW_CONTEXT_DIR="$round/context" \
  ./scripts/second-review.sh --backend claude --model opus \
  --implementer-model <the model that wrote the change> \
  --brief "$round/brief.md" --tree "$round/tree" --out "$round/out-claude"
```

- **Give the implementer's resolved model**, not an alias or a router name. The script
  refuses the run when the two models match, and refuses its own result when the model that
  answered turns out to be the implementer's anyway.
- **Review the snapshot, not your working tree.** `--tree "$round/tree"` is the plain
  extract of the commit that the `second-review` skill makes, in a folder made fresh for
  this round.
- **`SECOND_REVIEW_CONTEXT_DIR` is how the Claude backend reads anything outside the tree**,
  such as the commit's diff. Its file tools reach the tree, the directories it is given, and
  its own fresh working directory, and nothing else. The folder is added as readable, and
  the script refuses one that is or contains `--out`, because that holds the trace. Codex needs none of this: it is
  given the tree as its working root and will read an absolute path anywhere.
- **`--brief` and `--out` must be under this repository's gitignored `tmp/`**, and the
  script refuses anything else. Why: it writes the backend's trace into `--out`, and a
  trace can hold credential details, so it must never land in a tracked folder.
- **Never paste a trace** (`review.err`) into a pull request, an issue or Slack. Read it
  with `tail` or a targeted search.
- **`review-record.txt` is what goes in the pull request**: the backend, the model that
  answered, the implementer's model, and what the reviewer was confined to.
- **Do not edit `scripts/second-review.sh` while a review is running.** Bash reads a script
  as it executes, so changing the file in place can move the offsets under the running shell
  and make it die part-way with a syntax error — after the backend has spent its time, and
  before the record is written. (Replacing the file atomically may leave the running inode
  alone, so this is a hazard rather than a certainty.) One round was lost that way: the
  review itself completed and `review.out` was there, but `review-record.txt` never
  appeared. Wait for the run, or work on a copy.
- **It takes 10 to 25 minutes**, and `review.out` is written at the end. To run it in the
  background, redirect to a log under `tmp/` and check it with
  `pgrep -f '[s]econd-review.sh'`. Why the brackets: without them the pattern also matches
  the shell running `pgrep`, so a review that has exited still looks alive.
- **Report the exact error and stop, whenever the script refuses.** It names the check that
  refused, tagged: before the run (`E_SAME_MODEL`, `E_CMD_MISSING`, `E_NOT_IN_TMP`) or
  after it (`E_RUN_FAILED`, `E_BAD_RECORD`, `E_NOT_READ_ONLY`, `E_TREE_CHANGED`). Either
  way no review happened, and that is a fact the maintainers need rather than something to
  configure around.

##### What "read-only" rests on, per backend

Read-only is not one flag, and the two backends do not establish it the same way. Say which
one you used when you record a review, rather than writing "read-only" as if it meant the
same thing.

- **Codex: configured, then read back afterwards.** `--sandbox read-only` on its own does
  **not** stop Codex writing — it leaves the approval policy at `on-request`, and a host
  whose configuration answers that ask by itself lets the write through. A run on
  2026-10-25 with exactly that flag created a file in the review tree and appended to a
  page, and reported both as successful. The script passes `-c approval_policy="never"` as
  well, and **reads Codex's own preamble after the run, refusing the result unless Codex
  reported `sandbox: read-only` and `approval: never`**. Note *after*: that is a check on
  what happened, not a gate before it. If it refuses, the reviewer has already run, so the
  message also says whether the tree changed.
- **Claude: configured, and checked only by the tree.** The script runs it with
  `--restricted`, `--strict-mcp-config`, `--tools Read,Grep,Glob` and no answerer for
  permission prompts. **`--tools` is the load-bearing flag: it sets which tools the reviewer
  *holds*.** An earlier version used `--allowedTools`, which only says which tools may run
  without asking and takes nothing away — under it the reviewer still held `ToolSearch`,
  `Skill`, `ListAgents`, `ReportFindings` and `ScheduleWakeup`, and could load
  `SendMessage`, `EnterWorktree`, `ExitWorktree`, `CronList` and `CronDelete`. Three of
  those act **outside the tree, where the fingerprint cannot see them**: `SendMessage`
  reaches other sessions on the machine, `EnterWorktree` acts on the enclosing repository,
  `CronDelete` removes scheduled tasks. Asked to list its tools, a reviewer under the old
  flags named all of them and said it *could* message another session; under `--tools` it
  names exactly three and says it cannot.
  A settings file granting `Bash`, `Write` and `Edit` was also tried and still could not
  write, because a permission grant cannot resurrect a tool that is not present.
  But **Claude does not report its confinement back**, so there is nothing to parse and
  verify: the record states what Claude was *asked* to be. The evidence that it did not
  write is the tree check below, not a backend report.
  - `--restricted` also makes claude ignore the **user settings file**, which is where a
    `awsCredentialExport` or `apiKeyHelper` credential path lives. Set
    `SECOND_REVIEW_CLAUDE_SETTINGS` to a file carrying only that setting; `--settings` is
    still read under `--restricted`. Without it the backend cannot authenticate, or
    authenticates as whatever ambient credentials exist. The script names this cause when
    the run fails that way.
  - **The script checks that file and allows exactly one of `awsCredentialExport` and
    `apiKeyHelper`, non-empty, and nothing else.** Why: `--settings` restores *executable*
    configuration, not just values. A permission grant in it is inert, as above — but a
    `hooks` entry runs shell commands outside the reviewer's tool list entirely. A
    `SessionStart` command hook was tried under the full read-only flag set and **it
    executed and created a file**. A settings file can also carry MCP servers, plugins, a
    status line, extra readable directories and a model override, so the check is an
    allowlist of the two authentication keys rather than a list of things to block; each of
    those keys is refused by the same rule, with a case for each.
  - **This does not mean "no executable configuration", and the docs should not say it
    does.** Both permitted keys *are* commands claude runs — that is what naming a
    credential helper means. What the check removes is every *other* way a settings file
    could run something. The helper is a command you chose, trusted for that purpose.
  - **The reviewer runs from a directory made fresh for the run, not from the tree**, with
    the tree added as a readable directory. Why: a permitted helper would otherwise execute
    with the thing under review as its working directory. The directory is made with
    `mktemp -d` rather than at a fixed name, because `--out` can be reused and `mkdir -p` on
    a path that is already a symbolic link succeeds without replacing it — so a stale or
    planted link there pointing at the tree would have put the helper straight back inside
    it. Checked both: `mkdir -p` does behave that way, and the old fixed-name version puts
    the reviewer physically in the tree while the new one does not.
  - A consequence worth knowing rather than glossing: an *incidental* relative write by such
    a command now lands beside the output instead of in the tree, so the tree fingerprint is
    *less* likely to notice it. A command that deliberately writes to `../tree` is not
    stopped by this at all. **The isolation reduces the exposure and the detection
    together.**
  - **This costs you nothing else, because `--restricted` ignores settings *files*, not the
    environment.** Everything that is not a credential helper — the provider switch, a
    Region, a profile — goes in your shell as it normally would, and reaches the reviewer;
    the run proving this backend worked relied on an ambient `CLAUDE_CODE_USE_BEDROCK`. The
    settings file is for the one thing the environment cannot carry.
  - Being exact about what the allowlist does and does not buy: `apiKeyHelper` also names a
    command that claude executes, so permitting it permits execution — of the credential
    helper you chose, which is the point of naming it. What the check removes is every
    *other* way a settings file could run something, `hooks` above all, none of which the
    reviewer needs.
- **Both: the tree is fingerprinted before and after** — every path's type, mode, size,
  modification time, symlink target and content — and the run fails if anything changed.
  That check has limits: it cannot see a file created and deleted within the run, and it
  says nothing about writes outside the tree. It is still the check that caught the write
  above, and on the Claude path it is the whole of the after-the-fact evidence.

#### Limits that apply wherever you run it

These are not host-specific, and the section below is not where to look for them.

- **The review should not be billed to an account whose credentials merely happen to be
  present.** The script removes the AWS credential variables from the environment before
  running the Codex backend, which leaves it whatever its own configuration pins and so
  **reduces the risk** of an ambient account paying for a review. It does not eliminate it:
  the removal is a **denylist** of the variables the AWS SDKs are known to read, so a
  backend that reads some other variable is not covered, and a backend whose credentials
  come from a helper named in its own configuration file is not affected by it at all.
  Knowing which account your backend bills is still yours to establish. Set
  `SECOND_REVIEW_KEEP_AWS_ENV=1` only if your Codex authenticates to Bedrock with exactly
  those credentials. Why: this workstation holds live credentials for an unrelated account,
  and the removal is what keeps them out of the reviewer.
- **The two backends differ in what else the reviewer can reach.** `--backend claude` runs
  with `--tools Read,Grep,Glob` and `--strict-mcp-config`, so it is asked to hold only those
  three and no MCP server. A reviewer under those flags reports exactly them, with nothing
  loadable; that is the reviewer's own self-report, not something the script verifies, which
  is why the tree check is what the record rests on. Codex 0.164 cannot clear `mcp_servers` from the
  command line, so a Codex review can also reach whatever MCP servers that machine's
  `~/.codex/config.toml` defines — any machine's, not only a configured workstation — and
  some of those write to other systems. Both backends are equally sanctioned; this is a
  difference to know about, not a reason to pick one. In both cases the review tree is
  checked afterwards, and writes outside it are not.

#### A sub agent in your own session

The third path needs no script: dispatch a fresh agent, give it the brief, and have it read
the snapshot. It is the most convenient of the three and **the easiest to get wrong**,
because the invariants that come almost free on the two CLI paths — where a different
vendor's tool means a different model by construction — are yours to arrange here.

- **A sub agent inherits the parent's model unless you say otherwise.** So a naive dispatch
  has the implementing model reviewing its own work, which looks exactly like a real review
  and satisfies none of its purpose. **Pass an explicit model override that differs from the
  implementing model** — in Claude Code that is the Agent tool's `model` parameter — and
  record the model that actually ran, not the one you asked for.
- **Give it a read-only tool set.** There is no sandbox flag here: the reviewer is read-only
  because it holds no edit, write or shell tool, so hand it reading tools only.
- **No context from your session is load-bearing.** A fork that inherits the implementer's
  reasoning will repeat it and is not an independent review. Start it fresh, with the brief
  and the snapshot as its only input.
- **Show the tree unchanged afterwards**, the same way the script does: fingerprint it
  before and after and compare.

This is the path the coding-agent sample's review took while the Codex command was broken,
and it worked.

#### Bringing a different reviewer again

Another tool entirely is fine too — the three paths above are what this repository has used,
not a closed list. If you wire up your own, show in the pull request that it met the same
three invariants:

- which model answered, and that it differs from the model that wrote the change — from the
  tool's own report of the model, not the name you asked for;
- that it could not write to the tree: name the read-only mode you used, and show the tree
  unchanged after the run (`scripts/second-review.sh` writes `tree-before.sha256` and
  `tree-after.sha256`, and you can compare the same way);
- that the brief, the output and the trace stayed under `tmp/`.

Verify this with a run that tries to write, and show it refused, rather than asserting it
from the flags. Why: two of the three reviewers tried here would have passed a
flags-only check while still being able to write.

#### Host-specific options, where you are on that machine

These are local conveniences: a particular build to name, and a wrapper not to use. The
limits that apply to every run are above, under
[Limits that apply wherever you run it](#limits-that-apply-wherever-you-run-it) — do not
skip those because you are not on this machine.

- **The maintainers' workstation Codex.** Name the toolbox build and its Bedrock provider,
  because the `codex` the shared `PATH` finds first can be an older standalone build:

  ```bash
  SECOND_REVIEW_CODEX_CMD=~/.toolbox/bin/codex SECOND_REVIEW_CODEX_PROVIDER=amazon-bedrock \
    ./scripts/second-review.sh --backend codex --model openai.gpt-5.6-sol ...
  ```

  Its Bedrock calls bill the toolbox-managed builder account, because the host
  `~/.codex/config.toml` pins the provider with a `credential_export` running the toolbox
  Codex credential helper.
- **`~/.kiro/crew/codex/codex-builder`** is the older wrapper that did that removal outside
  the script. It no longer starts: it appends
  `-c model_providers.amazon-bedrock.aws.profile=...` unconditionally, and Codex 0.164
  refuses a provider carrying both that and the host config's `aws.credential_export`
  ("provider aws.credential_export cannot be combined with aws.profile"). No `-c` option
  avoids it, because Codex merges `-c` into the config rather than replacing a table.
  Dropping it appears to cost nothing: on the maintainers' workstation its profile and the
  host config's `credential_export` were observed to resolve to the same builder-account
  role. That is one observation on one machine, not a guarantee, and a review's output
  identifies no billed account — so treat it as a reason not to worry rather than as proof.
  Use the wrapper only if you have fixed it, by pointing `SECOND_REVIEW_CODEX_CMD` at it.
- **Each backend authenticates through its own configured credential path, and the two do
  not resolve to the same account.** That is expected: they are different vendors' traffic.
  On the maintainers' workstation both are accounts the maintainers intend.
  - **Codex** takes its credentials from the provider's `credential_export` helper in
    `~/.codex/config.toml`, which resolves to the toolbox-managed builder account
    (confirmed three ways: the helper's identity, `codex amzn usage` attribution, and that
    ambient credentials do not displace it).
  - **Claude** takes its credentials from its own `awsCredentialExport` helper in
    `~/.claude/settings.json`, which resolves to a different account. On the maintainers'
    workstation, use `SECOND_REVIEW_CLAUDE_CMD=~/.toolbox/bin/claude`: that is the build the
    maintainers have set up for the account they intend for Claude usage.
  - **The credential removal described above is Codex-only, and gives the Claude backend
    no protection**, because the environment is not where that helper is named. But
    **something else does reach it**: the `--restricted` flag the Claude backend runs with
    makes claude ignore the user settings file, which is exactly where
    `awsCredentialExport` lives. Without `SECOND_REVIEW_CLAUDE_SETTINGS` the credential
    path is therefore discarded and the run falls back to ambient credentials — failing
    when there are none, and billing the ambient account when there are. Set that variable
    to a file carrying only the authentication setting. Why this is spelled out: the
    backend shipped broken this way, and the failure looked like an expired-token problem
    rather than a flag interaction.
  - **Anywhere else, which account you bill is yours to establish**, by asking your
    backend's own credential helper who it is rather than reading the shell's ambient
    identity. The two differ, and a review's output shows neither.

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

The two repository URLs, the backend commands and wrapper named above and the preview
generator's name are the only internal values this file holds, at the maintainers' choice.
Remove them before this repository is made public, which needs Nitro sandboxes to be
generally available first: until then the pages above, and any sample that quotes them,
describe an unreleased feature. `scripts/second-review.sh` itself holds none of them: it
takes every command from the environment.

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
- **A shared install is reused as it is, never changed.** A controller, operator, CSI driver
  or EKS add-on the sample needs (KEDA, Argo Rollouts, the GitHub Actions Runner Controller,
  the EFS CSI driver, a Helm chart's cluster-wide parts) may already be on the cluster,
  installed by someone else. Check for it before the run: its CRDs, its namespace, its Helm
  release or its add-on.
  - **Present:** use it as it is. No `helm upgrade`, no reinstall, and no change to its
    values, its service accounts, or their IAM roles and Pod Identity associations.
  - **Absent:** the page has the reader install it as a step, at a pinned version, and the
    setup script checks for it and stops with the command, as for a cluster-wide setting.
  - **Present, but set up differently from what the sample needs:** the script stops and says
    what it found. That is a question for the spec, not something to change.

  Put the sample's own objects in the sample's own namespace, not the controller's, and never
  create an object at a fixed upstream name (such as the controller's namespace) unless the
  install is absent. The clean up never removes a shared install; the page says what stays
  and how to remove it. Why: other workloads use the same controller. On the maintainers' test
  cluster the EFS CSI driver already carries the Pod Identity roles another demo's mounts
  depend on, so a sample that set its own role on it would cut those mounts off.
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

- **Get a second reviewer, a person or another agent on a different model from the one
  that wrote the change, for any change to a check, a credential path or a security
  claim.** The `second-review` skill says how to brief one, run it with
  `scripts/second-review.sh` and record the result, and
  [The adversarial second reviewer](#the-adversarial-second-reviewer) covers the backends. Why: those fail silently;
  the sample still runs and the page still reads well.
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

## Keep a pull request current with `main`

Every sample pull request adds a line to the same three files: the `mkdocs.yml` nav,
`docs/ROADMAP.md` and the root `README.md`. So once one sample merges, the next one
usually conflicts in those files.

- **Merge `main` into your branch. Do not rebase or force-push.**

  ```bash
  git fetch origin
  git merge origin/main
  ```

  Do it before you mark the pull request ready, and again when GitHub says it has
  conflicts. Why: a rebase rewrites the commits a reviewer already read, and pushing it
  needs a force-push. Maintainers squash-merge, so your merge commits never reach `main`.
- **In the three index files, keep both sides.** A conflict there is nearly always two
  samples added to the same list. Keep both entries, in roadmap order. Keep each section
  heading once, with a blank line before and after it. Do not resolve an index file with
  `git checkout --ours` or `--theirs`. Why: picking one side drops the other sample from
  the menu or the list, and `mkdocs build --strict` does not notice.
- **Anywhere else, read both sides before you choose.** If the other side is someone
  else's sample or a rule change, keep their change and fit yours around it, or ask on the
  pull request.
- **Check the merge before you commit it:**

  ```bash
  ./scripts/check-sample-index.sh   # every sample in the nav, the roadmap and README.md; no conflict markers
  ./scripts/check-agent-files.sh
  mkdocs build --strict
  git commit --no-edit
  git push
  ```

  The two scripts exit 1 on a finding and 2 when they could not check; treat 2 as not
  checked. Why: a merge commit is new code, and checks that passed on your old head say
  nothing about it.
- **Wait for the checks on the new head** (`gh pr checks <pr> --watch`) before you say it
  is ready. If the merge changed a file your sample reads or runs, check again the boxes
  that depend on it.

### Merging (maintainers)

- **Merge one pull request at a time, oldest first.** After each merge, the next pull
  request is brought up to date as above, by its author or by you, before it merges.
- **Merge only when every check has passed on the current head**, and pin that head:

  ```bash
  gh pr checks <pr>
  gh pr merge <pr> --squash --match-head-commit <sha>
  ```

  Why: `--match-head-commit` refuses the merge if someone pushed after you looked. One
  pull request was merged a minute before CodeQL had run on its new merge-commit head.
- **Check `main` after the merge** with `./scripts/check-sample-index.sh`, and fix any
  finding in a follow-up pull request. Why: two samples merged without their `README.md`
  line or their `(available now)` marker, and no conflict showed it.
- **Take the `in progress` label off the closed issue**:
  `gh issue edit <issue> --repo aws-samples/sample-eks-nitro-sandbox --remove-label "in progress"`.
  Why: closing an issue keeps its labels, so the board shows finished work as in progress.
- Post the merge with the `slack-updates` skill.

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
