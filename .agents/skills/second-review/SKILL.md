---
name: second-review
description: Get the adversarial second review AGENTS.md requires for any change to a check, a credential path or a security claim in this repository - write a scoped brief, run Claude Code or Codex on a different model from the one that wrote the change, show by fingerprint that the reviewed snapshot is unchanged, label each finding real or false positive, fix the real ones, and record the reviewing model in the pull request. Use before a pull request that touches a guard, an IAM policy, a network policy, a clean-up script or a claim on a page leaves draft, or when asked for a review of your own commit.
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
own session. The invariants below are the requirement; the script *captures* them for you on
the two CLI paths, with limits worth reading under [Run it](#run-it) — the different-model
one rests on the model *names* you give it, and the unchanged-tree one rests on a fingerprint
taken before and after, not on confining the reviewer (see
[What invariant 2 rests on, per backend](../../../AGENTS.md#what-invariant-2-rests-on-per-backend)) —
and you capture them yourself with a sub agent — where the model difference is
the one that needs deliberate effort, because **a sub agent inherits your model unless you
override it**. See
[A sub agent in your own session](../../../AGENTS.md#a-sub-agent-in-your-own-session).

**The reviewer is meant to be able to write and run things.** It gets a workspace of its
own and a shell, because the findings that matter most come from running the change rather
than reading it. What keeps the review honest is not a sandbox flag but the fingerprint of
the reviewed snapshot: if the snapshot differs at all, the round fails. The brief is where
you ask the reviewer to leave it alone, and
[`assets/review-brief.md`](assets/review-brief.md) already does.

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

   The diff goes in `context/`, not beside the output: the Claude backend's **file tools**
   reach only its own workspace, the tree and the directories it is given, so pass that
   folder as `SECOND_REVIEW_CONTEXT_DIR` and it becomes readable. Never point that at
   `--out`, which holds the backend's trace — the script no longer refuses one that does.
   (The reviewer also holds `Bash`, so this bounds where its *file tools* read, not where it
   can read at all.)

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
  an absolute path anywhere; Claude's file tools reach only its own workspace, the tree and
  the directories it is given, so anything you point it at — the diff above all — belongs in
  the folder you pass as `SECOND_REVIEW_CONTEXT_DIR`.
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
- **A reviewer is authoritative on whether a defect exists, never on how bad it is.**
  Severity is yours to decide, with the reviewer's reasoning as input. Two rounds here
  establish it in opposite directions: one backend *cleared* a hole the other then found,
  and later the same backend found a defect, analysed it more thoroughly than the other, and
  **concluded it was optional** — a guard deleting files from the tree it protects, which it
  reasoned was not must-fix because no bad review could get through. That reasoning was
  sound and the conclusion was wrong: a tool whose central promise is that the reviewer
  cannot change the tree must not itself change the tree, whatever else holds. Read the
  argument, then judge the severity yourself against what the thing is *for*.
- **A guard that cannot fire in the circumstance it was written for is worse than none**,
  because it reads like coverage — in the suite, and in the pull request. One here could
  only fire *after* the removal it was guarding had succeeded, since a failing `rm` ended
  the script under `set -e` with its own untagged message; and its wording, "could not be
  removed", was false in the only case that could reach it. Ask of every new refusal: what
  exactly makes this fire, and is that the thing I am worried about?
- **Writing a lesson down does not install it.** The reset-destroys-your-fixture shape
  appeared here for the third time *in a guard written while recording that very lesson*.
  So prefer tooling that enforces the habit over a convention that asks you to remember it:
  this suite's `run()` now plants fixtures itself, rather than documenting that you must
  plant them after the reset — the categorical-over-enumerative rule applied to the harness.
- **When a reviewer *clears* a concern with an argument, the argument is a finding too, and
  wants checking like any other claim.** A plausible clearance is more dangerous than a
  missed finding, because it gets adopted and then cited. One round here cleared a
  fingerprint hole with reasoning — "they can't disagree misleadingly, because every path
  that stops on the early one is a refusal" — which was wrong: the early fingerprint stopped
  nothing, it only fed the refusal messages, and a backend that wrote to the tree and then
  put it back was being recorded as clean. Had the other backend not disagreed, the pull
  request would have carried a written argument for why a real hole was fine. **Read a
  clearance as closely as a finding.**
- **Write a guard that constrains to the good case, not one that enumerates the bad ones.**
  An enumeration is only as complete as your imagination on the day; a constraint is
  complete by construction. Three of the strongest fixes in this tooling have that shape,
  and each replaced something with the other shape:
  - `--allowedTools` *enumerated* which tools could run unasked, and left the reviewer
    holding `SendMessage` and `CronDelete`. `--tools` *sets what it holds* — three tools,
    nothing loadable.
  - The settings check could have blocked `hooks`, then `env`, then `mcpServers`,
    `plugins`, `statusLine`… Instead it permits **exactly two** authentication keys, so
    everything else is refused by the same rule and nobody has to think of it.
  - A check refused the *kind of link* it had thought of, and a hard link walked past it.
    Removing the name covers symbolic links, hard links and FIFOs at once, and touches no
    target: *"refusing only covers the kind of link you thought to test for."*

  This generalises past review tooling: a clean-up or ownership check that lists the bad
  cases will miss one.
- **But if the categorical form of your guard is an *action*, its ordering and scope are
  part of the guard, not details.** The rule above is about coverage and says nothing about
  blast radius. A refusal is inert: it can sit anywhere, early, and the worst case is a
  false refusal. Removing, moving or truncating something is not inert, so it must run
  **after every check that could refuse**, and be **scoped so it cannot reach the thing
  being protected**. A guard here whose whole purpose was "the reviewer cannot change the
  tree" had neither, and deleted two files *from the snapshot* before reporting that the
  output directory was inside the tree. If you take the categorical rule without this
  caveat you will reproduce that.
- **A guard that cannot run in the environment that tests it is worse than none.** One
  candidate fix needed `stat`, which is not on the suite's minimal `PATH`, so the guard
  would have been silently untested there; `rm` is, which is part of why removing the name
  was the right fix.
- **After fixing a case that proved nothing, run it against the code *without* the fix and
  confirm it fails.** This should be the default for any new rejecting case, not the remedy
  after being caught: it is the only way to know the case discriminates. Ten cases here
  needed it, and six more were added in round 20. Making the script under test an overridable variable costs one line and makes
  this a one-command check.
- **The unfixed code you test against has to be shown to parse.** Reverting a fix by cutting
  text is itself a change that can go wrong: one mutation here cut from the middle of a
  comment, left a fragment that was no longer a comment, and the mutant died on its first
  line — so the case "passed" for a reason that had nothing to do with the check, exactly
  as a stub that fails every call stops a script before the check you meant to prove. Cut
  whole blocks, assert the block was found exactly once, and run `bash -n` on the result
  before believing either outcome.
- **A case that prints more than one line needs its verdict read, not its first line.** A
  case asserting both "it refused" and "it kept the earlier result" prints a line for each,
  so taking the first match read a passing sub-assertion as the whole verdict. Treat any
  failing line carrying the case's name as the verdict.
- **Two branches that share a refusal tag each need their own message asserted.** Here the
  tree check has one tag for "changed while the reviewer ran" and "changed after the run";
  swapping the two messages left every case green until each one pinned its own wording.
  `E_OUT_TAINTED` covers three states and had the same gap.
- **A variable set inside an `if` and read later as `"${var:-}"` is an injection point.**
  Bash makes every environment variable a shell variable, so moving a check earlier and
  leaving its *result* to be read further down let an exported lowercase variable supply that
  result with the check never having run — reaching `--settings` with the settings allowlist
  skipped, which is arbitrary execution. Empty such variables before the branch that sets
  them. Found by the Claude backend; Codex missed it.
- **`-f` and `-s` both pass for a file you cannot read.** Add `-r` for anything the script
  will later read, or the failure surfaces much later and gets misattributed — here as "the
  backend exited 1" when the backend had never run.
- **Inside an `if` condition, `set -e` is off for the whole call, subshells included.** A
  function whose body is several pipelines then reports only the last one's status, so an
  earlier failure is silently dropped. Give each pipeline its own `|| exit 1` rather than
  relying on `set -e` being in force.
- **Prefer a deterministic hook to a timing window.** A case needing a change to land
  between two of the script's own steps was first written as a background writer polling for
  a file to appear: it could fire while that file was still being written (wrong branch) or
  after the next step (no refusal at all), and under one mutation the early landing made the
  broken code pass. Replaced with a shim first on `PATH` for a command whose *first* call is
  at that point — no race, and nothing left running afterwards. (The script calls that
  command several times; it is the shim's own marker file that makes it act once. A reviewer
  caught this description claiming the script called it once.)
- **A test harness must clear the environment it is testing.** The suite here passed the
  caller's environment straight through, and `AGENTS.md` tells maintainers to export exactly
  the variables that name the backend command. Measured on a machine with
  `SECOND_REVIEW_CODEX_CMD` exported: **66 invocations of the real backend in one suite run**,
  billed, plus 28 spurious failures — and with `SECOND_REVIEW_CLAUDE_SETTINGS` exported, a
  case that asserts a variable is ignored failed against correct code. `env -u` each one.
  A suite that reads its own environment is not testing the same thing on two machines.
- **A guard that compares paths must resolve them itself.** The one here took `dirname` of
  what it was given and compared it to an already-resolved directory. That worked for the two
  callers whose paths had been through `realpath` and silently failed for the third, where
  `command -v` returns the command as typed: a relative path, or one with `./` in the middle,
  passed the guard and was then deleted. Resolve inside the guard, so adding a caller cannot
  reintroduce it. Resolve the *directory* only when the thing being protected is the name —
  resolving the whole path compares a symbolic link's target instead of the link.
- **`python3 -c` puts the current directory first on `sys.path`.** A validator invoked that
  way can be fed a planted `json.py` from wherever the caller happens to be standing. Checked
  both ways: without `-I`, a planted module made the settings allowlist print `OK` for a file
  carrying `hooks`; with `-I`, the file is refused. Use `python3 -I` for anything whose answer
  is a security decision.
- **A required or forbidden string must not be a prefix of a legitimate value.** Asserting
  the argument list did not contain `--add-dir $work` failed against correct code, because
  the legitimate `--add-dir $work/tree` contains it. The same unanchored-match trap
  `AGENTS.md` warns about for manifests, inside the test harness.
- **Mark code, not comments, when you write a mutation.** Two mutations stopped applying
  because the comment above the code they cut had been reworded. They failed loudly, which
  is the design, but a marker that is code-only does not go stale.
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
  router that resolves to the model you were avoiding defeats the whole exercise. The script
  compares the two **names**, so where the implementer's name is a router's it cannot hold
  this invariant at all — see [Record it](#record-it) for what such a record does show.
- **Either backend, your choice.** Both reviewers hold a shell and can write: `--backend
  claude` runs with `--tools Read,Grep,Glob,Edit,Write,Bash` in a workspace of its own from
  `mktemp -d`, and `--backend codex` runs `--sandbox workspace-write` with the tree as its
  working directory. They differ in one way worth knowing: claude also gets
  `--strict-mcp-config` and so no MCP server, while Codex 0.164 cannot be made to drop that
  machine's MCP servers, so a Codex reviewer can also reach those. That is a fact about the
  backends, not a ranking.
- **The reviewer must not *change* the snapshot — and the fingerprint is how you know.**
  Not "must not be able to write": it can, and it should, because a reviewer that cannot run
  the change finds a narrower class of defect. What the script does is fingerprint `--tree`
  before the run, when the backend returns, and after — every path's type, mode, size,
  modification time, symlink target and content — and fail the round on any difference,
  including a change put back afterwards. Two limits to state when you record it: it is not
  guaranteed to see a file created and deleted inside the run (the holding directory's mtime
  usually gives it away, but not if it was the tree's own root or the mtime was put back),
  and **it says nothing about writes outside the tree**, which both backends can now make.

  Point it at the round's snapshot, never your working tree — that advice matters more now,
  not less, since nothing stops the reviewer writing where you point it.
- **Keep the brief, the output and any trace in the round's folder under `tmp/`.** The script
  no longer checks this, so it is yours to get right. A trace (`review.err`) can hold
  credential details: read it with `tail` or a targeted search, and never paste it into a
  pull request, an issue or Slack. Give every path with no line break in it, too, for the
  reason [Running it](../../../AGENTS.md#running-it) gives: the shell drops a trailing
  newline, so the run would act on the sibling path and report success.
- **A sub agent of your own tool works too**, as long as it starts with no context from
  your session and runs on a different model. **Name the model explicitly**: a sub agent
  inherits the parent's model by default, which would have the implementing model review
  its own work while looking like a real review, and a default such as "Auto" may not be
  available so the start then fails. In Claude Code the Agent tool's `model` parameter is
  the override. Fingerprint the snapshot yourself before and after, since that is what
  carries invariant 2 on this path as well. Show in the pull request how it met the three
  invariants, as
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
  credential path lives; name a file carrying that setting. Its contents are **no longer
  checked**: the old allowlist existed to stop a `hooks` entry running shell commands
  outside the reviewer's tool list, and the reviewer now holds `Bash`, so that check would
  defend a property the script no longer has. Put only the authentication setting in it
  anyway.
- **Know which account your review bills, on any machine.** For the Codex backend the
  script removes the AWS credential variables from the environment before running it, so an
  ambient account is less likely to pay for the review — but that is a *denylist*, so a
  backend reading some other variable is not covered, and a backend whose credentials come
  from a helper named in its own configuration file is not covered by it either — and that
  helper is not untouched: it is normally a child process, so it normally inherits the
  stripped environment, and one that authenticates through those variables or the SDK's
  ordinary configuration lookup may fail under it. If your Codex authenticates
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
  tooling the flag that then confined the Claude reviewer to three read-only tools — at the
  time the most security-relevant line in the change — had **nothing** guarding it:
  reverting it to the weaker flag would have left all 120 cases green, and no one would have
  noticed because the suite still passed. (That flag is gone now, since issue #100 made the
  reviewer deliberately able to write; the lesson about asserting argv is the part that
  carries over.) A fix with no case asserting it is one careless edit from
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
- **Do not trust a fix because it was just reviewed; the next round keeps finding the defect
  inside the last round's fix.** Warm pool autoscaling with KEDA is the record: four
  consecutive rounds each found the new defect in the previous round's fix, and the same five
  lines of narration were wrong in four different ways — round two in a comment written for
  round one's finding, round three in the read-back added for round two's, round four in
  round three's guard on a sentence, round five in the sibling line round four's guard
  missed. So prove a fix against **every** branch it touches and against the unfixed form of
  each, not just the case that was reported. Why: a fix is new code written under the
  impression that the area is now understood, which is exactly when it is not. The
  reviewer tooling in pull request #98 then matched it: six consecutive rounds, each finding
  the defect inside the previous round's fix, twice in a guard added to protect the reviewed
  tree and which damaged it instead.
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

**Record what the reviewer was permitted to do, and that the snapshot came back unchanged.**
Those are two separate facts and the record needs both: the permissions say what the
fingerprint is and is not covering, and the fingerprint is the whole of invariant 2.
`review-record.txt` prints both — a `permissions` line and a `review tree` line. Do not
write "read-only" in a record: neither backend is, and a reader who takes that at face value
will think the reviewer could not have written outside the tree, which nothing establishes.

**If the implementer's name you gave the script is a prompt router's, say so beside the
record, and say what it therefore shows.** The script compares the two names, so it cannot
show that a router name differs from whatever it resolved to. What settles invariant 1 then
is **the model that answered**, read against the set that router can resolve to: an answered
model outside that set — an OpenAI model against a Claude router — holds the invariant however
the router resolved, and one inside it shows only that a session with no context from yours
did the review. The backend does not decide this; `--backend codex` can be pointed at a
Bedrock Anthropic model, and the script never checks the answered model's family. Why say it:
two green records measuring different things read as two records of the same strength, which
is the hazard invariant 3 exists to warn about, landing inside your own evidence.
