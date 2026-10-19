---
name: second-review
description: Get the second review AGENTS.md requires for any change to a check, a credential path or a security claim in this repository - write a scoped brief, run a reviewer that cannot edit the tree, label each finding real or false positive, fix the real ones, and record the review in the pull request. Use before a pull request that touches a guard, an IAM policy, a network policy, a clean-up script or a claim on a page leaves draft, or when asked for a review of your own commit.
---

# Get a second review

`AGENTS.md` requires a second reviewer, a person or another agent, for any change to a
check, a credential path or a security claim, because those fail silently: the sample still
runs and the page still reads well. In this repository's samples, agent reviews found an
`||` that should have been `&&` in a check, an adopted IAM role that could keep extra
permissions, and clean-up scripts that reported "gone" for things they never checked. Each
time, the author had already read the code.

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
3. **Run the reviewer** read-only, with the brief on standard input. On the maintainers'
   workstation that is the Codex command in `AGENTS.md`, "The agent reviewer on the
   maintainers' workstation". Elsewhere, see [Run it](#run-it).
4. **Triage** each finding against the files, following [Use the result](#use-the-result).
5. **Record** the review in the pull request's second-reviewer box.

## Write the brief

- **Say it is your code, and what it must do.** Write it as the maintainer asking for a
  check of your own commit against stated invariants, naming the files. Why: a brief
  framed as hunting for attacks has been refused outright by a reviewer's safety filter,
  after burning its whole budget.
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

- **The reviewer must not be able to write.** Use a read-only mode, and point it at the
  snapshot in `tmp/review/tree`, not your working tree.
- **Keep the brief, the output and any trace in `tmp/review/`.** A trace can hold
  credential details: read it with `tail` or a targeted search, and never paste it into a
  pull request, an issue or Slack.
- **An agent of your own tool works too**, as long as it starts with no context from your
  session. Name the model explicitly when you start it: a default such as "Auto" may not be
  available, and the start then fails.
- **If the reviewer cannot start, report the exact error and stop.** Do not change its
  configuration or credentials to make it run. Why: those decide which account a review
  bills, and an error at start-up is a fact the maintainers need.

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
- **Stop when no must-fix finding remains.** Optional findings go in the pull request as
  notes. Why: each round should check the fixes, not widen the assignment.

## Record it

Fill in the pull request's second-reviewer box with: who or what reviewed it (a person, or
the agent and model), which commit, what it found, what was fixed and in which commit, and
which findings were false positives and why. Name any commit that changes a check and was
not reviewed. Describe each proof as it ran: which stub cases reached which message, and
which paths no case reached. A box ticked with no account of the review does not count.
