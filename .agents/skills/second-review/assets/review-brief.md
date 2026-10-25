I maintain the sample at examples/<section>/<sample>/ in the repository snapshot at
<absolute path to the round's tree> (a plain extract of commit <commit>; it is not a git
checkout). Please review my own commit, read-only. Its diff is <absolute path to the
round's context/change.diff -- the folder passed as SECOND_REVIEW_CONTEXT_DIR, because a
Claude reviewer can only read the tree and the directories it is given>.

What the commit does, in one or two sentences:
<...>

The requirements it must meet, from the spec issue #<n>:
<quote the acceptance criteria and claims that matter here, as written in the issue>

Already reviewed, please do not re-check except where this commit interacts with it:
<files or areas, and which commit was reviewed>

Assume my own changes contain a mistake, and assume my fixes to earlier findings are
themselves wrong. Try to break each claim below rather than confirm it. Check these,
citing file and line, and say plainly when a check is clean:

1. <class of defect, with a concrete example from these files>
2. <...>
3. <...>

Label each finding must-fix or optional, and for each must-fix give the smallest change
that fixes it.
