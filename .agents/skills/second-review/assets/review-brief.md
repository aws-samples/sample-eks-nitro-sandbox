I maintain the sample at examples/<section>/<sample>/ in the repository snapshot at
<absolute path to the round's tree> (a plain extract of commit <commit>; it is not a git
checkout). Please review my own commit. Its diff is <absolute path to the round's
context/change.diff -- the folder passed as SECOND_REVIEW_CONTEXT_DIR, because a Claude
reviewer's Read/Grep/Glob tools can only reach its own workspace and the directories it is
given (Bash is not confined by this and can read anywhere it has permission to)>.

You have write and execute in your own working directory, and you are encouraged to use
them: run the scripts, run the checks, try the inputs a check is supposed to reject. A
finding you reached by running something is worth more than one you reached by reading, and
two of the most serious defects ever found in this repository's own review tooling were only
visible that way.

Three things to hold to while you do, because the harness no longer enforces them and a run
that breaks one cannot be recorded as a review:

1. **Do not change the snapshot at <absolute path to the round's tree>.** Read it, copy out
   of it, run things that read it -- but write nothing into it, and move nothing inside it.
   It is fingerprinted before and after this run (every path's type, mode, size,
   modification time, symlink target and every file's content hash), and any difference
   fails the whole round, including a change you make and put back. If you need to run
   something that writes, copy what you need into your own working directory first and work
   on the copy.
2. **Write your own files only in your own working directory.** Do not write into
   <absolute path to the round's out directory>: that is where this run's output and the
   backend's trace go, and the trace can hold credential details. Do not read it either.
3. **Stay on this machine and in these directories.** No network calls, nothing that
   reaches another session, repository, scheduled task or external system, and nothing that
   installs or changes tooling outside your own working directory.

What the commit does, in one or two sentences:
<...>

The requirements it must meet, from the spec issue #<n>:
<quote the acceptance criteria and claims that matter here, as written in the issue>

Already reviewed, please do not re-check except where this commit interacts with it:
<files or areas, and which commit was reviewed>

Assume my own changes contain a mistake, and assume my fixes to earlier findings are
themselves wrong. Try to break each claim below rather than confirm it. Where a claim is
about a check, run the check against an input it must accept AND an input it must reject,
rather than reading it and reasoning about it. Check these, citing file and line, and say
plainly when a check is clean:

1. <class of defect, with a concrete example from these files>
2. <...>
3. <...>

Also tell me, at the end:

- **Which model you are**, as your own runtime reports it, not the alias I asked for.
- **Whether you wrote anything, and where.** Say so plainly even if you believe it was
  harmless or outside the snapshot. If you wrote into the snapshot at any point, say so and
  say whether you put it back: the fingerprint will very likely catch either one (it checks
  every path's type, mode, size, modification time, symlink target and content, including
  the snapshot's own root directory), but it is not a certainty and I would rather read it
  from you than rely on it alone.

Label each finding must-fix or optional, and for each must-fix give the smallest change that
fixes it.
