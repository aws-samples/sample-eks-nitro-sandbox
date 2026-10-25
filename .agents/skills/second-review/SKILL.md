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
two CLI paths, and you hold them yourself with a sub agent — where the model difference is
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
| `assets/review-brief.md` | A brief to copy into `tmp/review/` and fill in. |

## Quick start

1. **Snapshot what is reviewed**, so the reviewer reads exactly that commit and cannot
   change your work:

   ```bash
   mkdir -p tmp/review/tree
   git archive <commit> | tar -x -C tmp/review/tree
   git show <commit> > tmp/review/change.diff
   ```

2. **Write the brief**: copy `assets/review-brief.md` to `tmp/review/brief.md` and fill it
   in, following [Write the brief](#write-the-brief).
3. **Run the reviewer** on a model that is not the one that wrote the change, with either
   backend:

   ```bash
   ./scripts/second-review.sh --backend codex  --model openai.gpt-5.6-sol \
     --implementer-model <the model that wrote the change> \
     --brief tmp/review/brief.md --tree tmp/review/tree --out tmp/review

   ./scripts/second-review.sh --backend claude --model opus \
     --implementer-model <the model that wrote the change> ...
   ```

   See [Run it](#run-it) for what the script refuses and why.
4. **Triage** each finding against the files, following [Use the result](#use-the-result).
5. **Record** the review in the pull request's second-reviewer box, from
   `tmp/review/review-record.txt`, which names the model that actually answered.

## Write the brief

- **Say it is your code, and what it must do.** Write it as the maintainer asking for a
  check of your own commit against stated invariants, naming the files. Why: a brief
  framed as hunting for attacks has been refused outright by a reviewer's safety filter,
  after burning its whole budget. This is how "adversarial" is expressed: the brief tells
  the reviewer to assume your code is wrong and to try to break the claims it makes, which
  is the next three bullets, and `assets/review-brief.md` is worded that way already. It
  needs no change between the Codex and Claude backends; both have taken it as written.
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
- **Say what earlier reviews covered**, and ask it not to repeat them. Why: its attention
  is the scarce part.
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
  runs with `--restricted` and `--strict-mcp-config`, so the reviewer holds only `Read`,
  `Grep` and `Glob`, while Codex 0.164 cannot be made to drop the host's MCP servers, so a
  Codex reviewer can also reach those. That is a fact about the backends, not a ranking.
- **The reviewer must not be able to write.** Two separate things, so keep them apart when
  you record the review: the backend is *configured* to refuse writes, and the script
  *checks afterwards* that no persistent change it can see was left in `--tree` — every
  path's type, mode, size, modification time, symlink target and content. It cannot see a
  file created and deleted inside the run, or any write outside the tree. Point it at the
  snapshot in `tmp/review/tree`, never your working tree. A read-only flag on its own is
  not enough: Codex's `--sandbox read-only` still asked to write and a host that answers
  the ask let it through, which is why the script pins the approval policy too and refuses
  a run whose reported mode is anything else.
- **Keep the brief, the output and any trace in `tmp/review/`.** The script refuses an
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
- **Check that each case still fails for the reason it claims, every round.** A fix often
  moves a case onto an *earlier* check than the one it was written for. The case still
  passes, the suite stays green, and the check it was supposed to cover is no longer tested
  at all — so a hole can reopen in silence. Read the message each rejecting case actually
  produced, not just its exit status, and make the expected tag part of the assertion.
  Why: in the review tooling's own history this happened three times in six rounds. Once a
  fix made every "good" stub stop emitting the marker a new check looked for, so an
  81-case green suite was quietly demonstrating that the marker's *absence* was acceptable
  — the opposite of what the case was named for. Twice a case was rejected by a newer
  check while still being reported as proving an older one. **Twice the defect a round
  found was in the proof harness rather than the code**, which is the thing to expect:
  a green suite is evidence only for what it still exercises.
- **A case that would pass either way proves nothing.** One round found two cases comparing
  a value against something unrelated, so they passed whether or not the code under test
  was correct. Pick the comparison that fails if the defect returns.
- **Stop when no must-fix finding remains.** Optional findings go in the pull request as
  notes. Why: each round should check the fixes, not widen the assignment.

## Record it

Tick the second-reviewer box in the description's "Quality bar" list, and write under its
"Second review" heading: who or what reviewed it (a person, or the backend and the model
that answered, which `tmp/review/review-record.txt` names — not the model you asked for),
the model that wrote the change, so a reader can see the two differ, which commit, what it
found, what was fixed and in which commit, and which findings were false positives and
why. Name any commit that changes a check and was not reviewed. Describe each proof as it ran: which stub cases reached which message, and
which paths no case reached. A box ticked with no account of the review does not count.
