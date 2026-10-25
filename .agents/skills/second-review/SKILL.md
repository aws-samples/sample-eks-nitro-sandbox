---
name: second-review
description: Get the adversarial second review AGENTS.md requires for any change to a check, a credential path or a security claim in this repository - write a scoped brief, run Claude Code or Codex on a different model from the one that wrote the change and with no write access to the tree, label each finding real or false positive, fix the real ones, and record the reviewing model in the pull request. Use before a pull request that touches a guard, an IAM policy, a network policy, a clean-up script or a claim on a page leaves draft, or when asked for a review of your own commit.
---

# Get a second review

`AGENTS.md` requires a second reviewer, a person or another agent, for any change to a
check, a credential path or a security claim, because those fail silently: the sample still
runs and the page still reads well. In this repository's samples, agent reviews found an
`||` that should have been `&&` in a check, an adopted IAM role that could keep extra
permissions, and clean-up scripts that reported "gone" for things they never checked. Each
time, the author had already read the code.

**Three ways to do it, all sanctioned, your pick, no approval needed:** the Codex CLI or
the Claude Code CLI, both through `scripts/second-review.sh`, or a fresh sub agent in your
own session. The invariants below are the requirement; the script holds them for you on the
two CLI paths (establishing the read-only one by different means for each — see
[What "read-only" rests on, per backend](../../../AGENTS.md#what-read-only-rests-on-per-backend)),
and you hold them yourself with a sub agent — where the model difference is
the one that needs deliberate effort, because **a sub agent inherits your model unless you
override it**. See
[A sub agent in your own session](../../../AGENTS.md#a-sub-agent-in-your-own-session).

The review is **adversarial**: the reviewer assumes your code is wrong and tries to break
the claims it makes. That is a description of its job, not of how you word the brief — see
[Write the brief](#write-the-brief), where a brief worded as an attack exercise is the
mistake to avoid.

The reviewer is a person or an agent with none of your session's context. This skill covers
the parts that decide whether the review finds anything: what you ask, how it runs, and what
you do with the answer.

| File (in this skill's folder) | What it is for |
|---|---|
| `assets/review-brief.md` | A brief to copy into the round's folder and fill in. |

## Quick start

1. **Snapshot what is reviewed**, so the reviewer reads exactly that commit and cannot
   change your work. Make a new directory for each round rather than reusing one: `tar -x`
   over an earlier round's tree leaves behind files the new commit deleted, so "exactly
   that commit" stops being true from the second round onwards — and this way nothing has
   to be deleted:

   ```bash
   mkdir -p tmp                      # gitignored, so absent in a fresh clone
   round=$(mktemp -d tmp/review.XXXXXX)
   mkdir -p "$round/tree" "$round/context"
   git archive <commit> | tar -x -C "$round/tree"
   git show <commit> > "$round/context/change.diff"
   ```

   The diff goes in `context/`, not beside the output: the Claude backend confines its file
   tools to the tree and the directories it is given, so pass that folder as
   `SECOND_REVIEW_CONTEXT_DIR` and it becomes readable. Never point that at `--out`, which
   holds the backend's trace.

2. **Write the brief**: copy `assets/review-brief.md` to `"$round/brief.md"` and fill it
   in, following [Write the brief](#write-the-brief). Where it names the diff, give an
   **absolute** path — `$round` above is relative, so write `"$PWD/$round/context/change.diff"`
   — because a path the reviewer cannot read is a round wasted.
3. **Run the reviewer** on a model that is not the one that wrote the change, with either
   backend. Keep using `$round` — every path below comes from it, so nothing points at an
   earlier round's snapshot:

   ```bash
   ./scripts/second-review.sh --backend codex  --model openai.gpt-5.6-sol \
     --implementer-model <the model that wrote the change> \
     --brief "$round/brief.md" --tree "$round/tree" --out "$round/out"

   SECOND_REVIEW_CONTEXT_DIR="$round/context" \
     ./scripts/second-review.sh --backend claude --model opus \
     --implementer-model <the model that wrote the change> \
     --brief "$round/brief.md" --tree "$round/tree" --out "$round/out-claude"
   ```

   See [Run it](#run-it) for what the script refuses and why.
4. **Triage** each finding against the files, following [Use the result](#use-the-result).
5. **Record** the review in the pull request's second-reviewer box, from the
   `review-record.txt` in whichever `--out` you used — `"$round/out"` for the codex run
   above, `"$round/out-claude"` for the claude one. It names the model that actually
   answered.

## Write the brief

- **Say it is your code, and what it must do.** Write it as the maintainer asking for a
  check of your own commit against stated invariants, naming the files. Why: a brief
  framed as hunting for attacks has been refused outright by a reviewer's safety filter,
  after burning its whole budget. This is how "adversarial" is expressed: the brief tells
  the reviewer to assume your code is wrong and to try to break the claims it makes, which
  is the next three bullets, and `assets/review-brief.md` is worded that way already. Both backends
  have taken it as written, with one difference to respect: a path in the brief must be one
  the reviewer can actually read. Codex is given the tree as its working root and will read
  an absolute path anywhere; Claude confines its file tools to the tree and the directories
  it is given, so anything you point it at — the diff above all — belongs in the folder you
  pass as `SECOND_REVIEW_CONTEXT_DIR`.
- **State the requirements from the spec, not from memory.** Quote the issue's criteria
  where they matter. Why: one brief said "must not bake the signature" when the spec's
  optional variant exists to do exactly that, and the reviewer flagged it as a defect twice.
- **Name the classes of defect to look for, with an example of each.** A reviewer finds
  what it is pointed at. For a sample, start from these:
  - a check that fails open, or reports success when a lookup failed;
  - a script that reuses, changes or deletes something without checking it is the sample's;
  - a value a check compares that does not match what the creating step writes;
  - a credential on a command line, in a log, or in a broader role than the sample needs;
  - a claim on the page that the output blocks do not show;
  - shell traps: `set -euo pipefail` with `|| true` and command substitutions, unset
    variables, an unchecked tool, an unanchored pattern matching its own comment.
- **If the change ships prose beside a check, ask about the prose too:** does any sentence
  claim more than the code establishes — "cannot" where the code reduces a risk, "verified"
  where it was requested, "proves" where it was checked afterwards and partially? Point the
  reviewer at the gap between what the script's own comments say and what the page or
  `AGENTS.md` says; where they disagree, the comments are usually the honest ones. Why: this
  skill's own tooling was reviewed nine times, and the first eight briefs all scoped the
  reviewer to the script's checks. The ninth asked this question and immediately found two
  overclaims the others had no reason to look at — a reviewer answers the question you ask
  it, and a narrow brief run eight times is still a narrow brief.
- **Write the brief even when you are not going to run the round.** Composing the question
  forces you to state the contract the code is supposed to meet, and a contract stated
  plainly is one you can see being broken. Asking "is this the right refusal tag for a
  failed `mktemp`?" is what revealed that the tag used there meant "could not check" and
  exits 2 everywhere else, while that one use exited 1 — a contradiction nobody had seen in
  twelve rounds of reading the code. The brief found it before the reviewer ran.
- **Say what earlier reviews covered**, and ask it not to repeat them. Why: its attention
  is the scarce part.
- **A single clean round from one backend is not enough for a claim about both.** This is
  the rule; two rounds of this tooling are the evidence for it, and they argue it from
  different directions:
  - *Round 15* — both backends, run independently, found the **same** containment hole
    (`SECOND_REVIEW_CONTEXT_DIR=/` slipping past a `"$dir"/*` pattern, which would have
    handed the reviewer the whole filesystem). Convergence from two runtimes is a stronger
    signal than either alone.
  - *Round 16* — they **disagreed**, and the one that found a defect was right. So neither
    is a rubber stamp for the other.

  The reason is not redundancy, it is **different axes of observation**. A Codex reviewer
  cannot see which tools a Claude reviewer holds; fourteen Codex rounds here all read "the
  reviewer holds only `Read`, `Grep` and `Glob`" and none could check it, while the first
  Claude round asked itself and found it false. And a Claude reviewer reading the page as a
  *user* found that `mktemp -d tmp/review.XXXXXX` fails in a fresh clone — `tmp/` is
  gitignored, so absent — leaving the variable empty and turning the next line into
  `mkdir -p /tree`: a new collaborator's first command trying to create a directory at the
  filesystem root. That is not a reasoning failure a line-by-line read would surface. Ask
  each reviewer the questions its runtime can actually answer.
- **When a reviewer *clears* a concern with an argument, the argument is a finding too, and
  wants checking like any other claim.** A plausible clearance is more dangerous than a
  missed finding, because it gets adopted and then cited. One round here cleared a
  fingerprint hole with reasoning — "they can't disagree misleadingly, because every path
  that stops on the early one is a refusal" — which was wrong: the early fingerprint stopped
  nothing, it only fed the refusal messages, and a backend that wrote to the tree and then
  put it back was being recorded as clean. Had the other backend not disagreed, the pull
  request would have carried a written argument for why a real hole was fine. **Read a
  clearance as closely as a finding.**
- **When a reviewer names one instance of a class, check whether the class is bigger before
  fixing the instance.** Twice here the reported case was the smaller one: a trailing-slash
  pattern was named for one containment check and turned out to affect three, and a
  symlink-following write was reported for the record file when in fact both `>` and `tee`
  follow links, so *every* name written under the output directory was a vector. Fixing only
  what was reported would have left most of each hole open.
- **Vary what you scope a later round to.** Repeating a round against the same classes
  mostly re-checks the last fix. If several rounds have come back with only small or
  theoretical findings, that may mean the code is converging, or it may mean every brief has
  been asking the same thing; change the question before concluding the former.
- **Tell it to assume your own fixes are wrong.** Why: in this repository's history, the
  defect a review finds is often in the fix to the previous finding.
- **Ask it to say when a class is clean**, and to label each finding must-fix or optional
  with the smallest change that fixes it. Why: otherwise it invents findings to fill a
  section, and you cannot tell a clean area from an unchecked one.

## Run it

`scripts/second-review.sh` runs either backend. It takes `--backend codex` or
`--backend claude`, `--model`, and `--implementer-model`; `AGENTS.md`,
[The adversarial second reviewer](../../../AGENTS.md#the-adversarial-second-reviewer),
covers the three invariants, the environment variables that name each backend's command,
and the host-specific options on the maintainers' workstation.

- **A different model from the one that wrote the change.** That is the one thing a second
  review has to get right, so the script refuses to start when the two models match, and
  refuses its own result when the model that answered turns out to be the implementer's
  anyway. Give the implementer's resolved model, not an alias or a prompt router name: a
  router that resolves to the model you were avoiding defeats the whole exercise.
- **Either backend, your choice.** They differ in one way worth knowing: `--backend claude`
  runs with `--tools Read,Grep,Glob` and `--strict-mcp-config`, so it is asked to hold only
  those three — a reviewer under those flags reports exactly them and no loadable extras,
  which is its own self-report rather than something the script verifies — while Codex 0.164 cannot be made to drop that machine's MCP
  servers, so a Codex reviewer can also reach those. That is a fact about the backends, not
  a ranking. The flag matters: `--allowedTools` would only say which tools may run without
  asking, leaving the reviewer holding others — including some that act outside the tree,
  where the fingerprint cannot see them.
- **The reviewer must not be able to write — and say which way you established that.**
  Three separate things, so keep them apart when you record the review:
  - the backend is *configured* to refuse writes;
  - for Codex only, it also *reports* its mode, and the script reads that report **after
    the run** and refuses the result unless it says `sandbox: read-only` and
    `approval: never`. That is a check on what happened, not a gate before it, so on a
    refusal the reviewer has already run and the message says whether the tree changed.
    Claude reports nothing back, so on that path the record states what it was asked to be,
    not something it confirmed;
  - for both, the script *checks afterwards* that no persistent change it can see was left
    in `--tree` — every path's type, mode, size, modification time, symlink target and
    content. It cannot see a file created and deleted inside the run, or any write outside
    the tree.

  Point it at the round's snapshot, never your working tree. A read-only flag
  on its own is not enough: Codex's `--sandbox read-only` still asked to write and a host
  that answers the ask let it through, which is why the script pins the approval policy too.
- **Keep the brief, the output and any trace in the round's folder under `tmp/`.** The script refuses an
  `--out` outside the repository's gitignored `tmp/`. A trace (`review.err`) can hold
  credential details: read it with `tail` or a targeted search, and never paste it into a
  pull request, an issue or Slack.
- **A sub agent of your own tool works too**, as long as it starts with no context from
  your session and runs on a different model. **Name the model explicitly**: a sub agent
  inherits the parent's model by default, which would have the implementing model review
  its own work while looking like a real review, and a default such as "Auto" may not be
  available so the start then fails. In Claude Code the Agent tool's `model` parameter is
  the override. Give it reading tools only, since there is no sandbox flag on that path.
  Show in the pull request how it met the three invariants, as
  [Bringing a different reviewer again](../../../AGENTS.md#bringing-a-different-reviewer-again) says.
- **If the reviewer cannot start, report the exact error and stop.** The script names the
  check that refused, tagged (`E_SAME_MODEL`, `E_CMD_MISSING`, `E_RUN_FAILED`,
  `E_BAD_RECORD`). Prefer pointing the script at a different command
  (`SECOND_REVIEW_CODEX_CMD`, `SECOND_REVIEW_CLAUDE_CMD`) over editing a backend's global
  configuration: the machine may be shared, that configuration can decide which account a
  review bills, and a collaborator on a laptop has none of those files.
- **A claude backend that will not authenticate usually needs
  `SECOND_REVIEW_CLAUDE_SETTINGS`.** The `--restricted` flag the script uses makes claude
  ignore the user settings file, which is where an `awsCredentialExport` or `apiKeyHelper`
  credential path lives; name a file carrying **only** that setting. The script says so when
  it recognises the failure, and it refuses a settings file that sets anything else: a
  `hooks` entry in one runs shell commands outside the reviewer's tool list, which was
  verified to execute and write under the full read-only flag set. Note what that check
  does *not* claim — both permitted keys are themselves commands claude runs, so it removes
  every other way a settings file could run something rather than eliminating execution.
- **Know which account your review bills, on any machine.** For the Codex backend the
  script removes the AWS credential variables from the environment before running it, so an
  ambient account is less likely to pay for the review — but that is a *denylist*, so a
  backend reading some other variable is not covered, and a backend whose credentials come
  from its own configuration file is not affected by it at all. If your Codex authenticates
  *from* environment credentials, that removal is what breaks it: set
  `SECOND_REVIEW_KEEP_AWS_ENV=1`, which is the fix for the `E_RUN_FAILED` you would
  otherwise get. None of this is specific to the maintainers' machine.
- **Try the other backend before giving up on one.** They are equally sanctioned, so a
  backend that will not authenticate is a reason to switch, not a blocker to report.

## Use the result

- **Label each finding REAL or FALSE POSITIVE after reading the file and line it names.**
  Write down why for each false positive. Why: a reviewer is not an oracle; relaying its
  findings is not reviewing them.
- **Fix the real must-fix findings as new commits** whose messages say what was wrong and
  how the fix was proved. No force-push.
- **A fix to a check is a change to a check.** Prove it both ways in the script itself (see
  `AGENTS.md`, Verification rules), and get it reviewed again, scoped to the fix. Repeat
  until the last commit that changes a check has been reviewed. Why: in one sample the
  second round found that the fixes from the first could skip their own error messages.
- **Check that each case still fails for the reason it claims, every round. This is the
  single most common defect in this repository's own review tooling: seven separate
  instances in one change.** Not seven kinds of bug — seven times a case sat green in a
  passing suite while testing nothing it was named for. A fix often moves a case onto an
  *earlier* check than the one it was written for, so the case still passes, the suite stays
  green, and the check it was supposed to cover is no longer tested at all — a hole can
  reopen in silence. Read the message each rejecting case actually produced, not just its
  exit status, and make the expected tag part of the assertion. If you take one thing from
  this skill, take this.
  Why: in the review tooling's own history this happened three times in six rounds. Once a
  fix made every "good" stub stop emitting the marker a new check looked for, so an
  81-case green suite was quietly demonstrating that the marker's *absence* was acceptable
  — the opposite of what the case was named for. Twice a case was rejected by a newer
  check while still being reported as proving an older one. **Twice the defect a round
  found was in the proof harness rather than the code**, which is the thing to expect:
  a green suite is evidence only for what it still exercises.
- **A case that would pass either way proves nothing.** One round found two cases comparing
  a value against something unrelated, so they passed whether or not the code under test
  was correct. Pick the comparison that fails if the defect returns. The surest way to know
  is to run the case against the superseded code and watch it fail: in this tooling a case
  meant to prove a reviewer no longer ran inside the reviewed tree reported the *logical*
  working directory, which shows a symbolic link and hides that the directory physically
  **was** the tree — it passed against the unfixed script, and only a side-by-side run
  revealed that.
- **Say which cases are regressions and which are coverage.** A case that exercises a rule
  older than the commit you are proving is worth having, but it is not evidence for that
  commit. Label them separately in the pull request, because a reader who assumes every case
  is a regression will overestimate what the suite shows. Do not invent artificial
  regressions to even up the numbers.
- **Set a case's fixture up from inside whatever resets the workspace, not before it.** A
  harness that clears state between cases will clear your fixture too, and the case then
  passes for the wrong reason. Here a symbolic link planted before calling the run helper
  was deleted by that helper's own reset, so the case passed against the very code it was
  written to catch. This is the shape most likely to recur elsewhere in this repository,
  because every sample's guard tests reset state between cases: if a case needs the world
  to be in an odd state, arrange that after the reset and assert it is still so.
- **Assert the arguments the tool was actually given, not only what it returned.** A stub
  that ignores its argv makes every case indifferent to the flags under test. In this
  tooling the flag that confines the Claude reviewer to three read-only tools — the most
  security-relevant line in the change — had **nothing** guarding it: reverting it to the
  weaker flag would have left all 120 cases green, and no one would have noticed because
  the suite still passed. A fix with no case asserting it is one careless edit from
  silently disappearing. Have the stub record its arguments and assert the ones that
  matter.
- **A harness can be structurally unable to express the claim you think it is testing.**
  Not merely wrong — incapable. One assertion here checked the script's own output for a
  path, which could never work, because the script always prints that path itself; the claim
  needed a different assertion against the review. If a case cannot fail for the reason it
  names, no amount of care in the expected value fixes it.
- **Defence in depth leaves layers no test can reach, and that is the right trade.** After
  a check failed open, this tooling grew a second, independent check of the same condition.
  While the first works the second is unreachable, so nothing can test it. Keep it, and say
  in the pull request that it is unreached redundancy rather than dead code — otherwise
  someone later deletes it for being untested and re-centralises the risk.
- **Stop when no must-fix finding remains.** Optional findings go in the pull request as
  notes. Why: each round should check the fixes, not widen the assignment.

## Record it

Tick the second-reviewer box in the description's "Quality bar" list, and write under its
"Second review" heading: who or what reviewed it (a person, or the backend and the model
that answered, which the run's own `review-record.txt` names — not the model you asked for),
the model that wrote the change, so a reader can see the two differ, which commit, what it
found, what was fixed and in which commit, and which findings were false positives and
why. Name any commit that changes a check and was not reviewed. Describe each proof as it ran: which stub cases reached which message, and
which paths no case reached. A box ticked with no account of the review does not count.
