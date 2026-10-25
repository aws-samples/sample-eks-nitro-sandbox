#!/usr/bin/env bash
# Run the adversarial second review AGENTS.md requires, keeping its three invariants:
# the reviewer runs on a different model from the one that wrote the change, it is
# confined from writing to the tree it reviews and is shown to have left it unchanged, and
# the model that actually answered is recorded. Note the second one as two things: this
# script configures the confinement and checks the tree afterwards; it does not guarantee
# that nothing could have been written.
#
# Usage: scripts/second-review.sh --backend codex|claude --model <id>
#                                 --implementer-model <id>
#                                 [--brief FILE] [--tree DIR] [--out DIR]
#                                 [--timeout SECONDS]
#
#   --backend            codex or claude. Both are sanctioned; pick either.
#   --model              the model the reviewer should use, as that backend names it
#                        ("openai.gpt-5.6-sol", "opus", "claude-opus-5-5").
#   --implementer-model  the model that wrote the change under review, resolved, not an
#                        alias or a router name. A second review is only worth having if
#                        a different model does it, so this script refuses to run, and
#                        refuses its own result, when the two are the same.
#   --brief              the brief, given to the reviewer on standard input. Default
#                        tmp/review/brief.md.
#   --tree               the snapshot of the commit under review, never your working
#                        tree. Default tmp/review/tree.
#   --out                where the review, the backend's trace and the record of the run
#                        go. Must be under this repository's gitignored tmp/, because the
#                        trace can hold credential details. Default tmp/review.
#   --timeout            seconds to let the reviewer run. Default 5400 (90 minutes).
#
# Which command each backend runs comes from the environment, so this script works on a
# laptop where the collaborator authenticated their own backend, and on a machine where a
# wrapper pins which account the review bills:
#
#   SECOND_REVIEW_CODEX_CMD        the codex command. Default "codex".
#   SECOND_REVIEW_CLAUDE_CMD       the claude command. Default "claude".
#   SECOND_REVIEW_CODEX_PROVIDER   optional, passed as codex's model_provider.
#   SECOND_REVIEW_CODEX_EFFORT     optional, passed as codex's model_reasoning_effort.
#   SECOND_REVIEW_CONTEXT_DIR      optional, a directory added as readable for the claude
#                                  backend, which otherwise sees only the tree and its own
#                                  working directory. Put the commit's diff there, and
#                                  nothing the reviewer may not read: the script refuses a
#                                  directory that is, or contains, --out, because that
#                                  holds the backend's trace.
#   SECOND_REVIEW_CLAUDE_SETTINGS  optional, a settings file passed to claude as
#                                  --settings. Needed when your claude authenticates
#                                  through a setting (awsCredentialExport, apiKeyHelper):
#                                  the --restricted flag this script uses makes claude
#                                  ignore the user settings file, and --settings is how
#                                  that one setting comes back. Put only the
#                                  authentication setting in it.
#   SECOND_REVIEW_KEEP_AWS_ENV     keep the AWS credentials in the environment when
#                                  running the codex backend. The variables the AWS SDKs
#                                  read are removed by default, so that a machine holding
#                                  credentials for some other account does not end up
#                                  billed for the review. It is a denylist, so a backend
#                                  that reads some other variable is not covered; check
#                                  which account a new backend bills before trusting it.
#                                  Set this to 1 only if your codex authenticates to
#                                  Bedrock with exactly those credentials.
#
# The backend's trace (review.err) can hold credential details: read it with tail or a
# targeted search, and never paste it into a pull request, an issue or Slack.
#
# Exit status: 0 the review ran and its record is complete; 1 this script refused the
# run or refused its result; 2 it could not check (a tool it needs is missing).
set -euo pipefail

# Print the comment block above, and stop at the first line that is not a comment, so
# this cannot start spilling the script itself when a line is added below.
usage() { awk 'NR>1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; }

# Each refusal carries a stable tag, so a proof can name the message it reached.
refuse() { printf 'second-review: %s: %s\n' "$1" "$2" >&2; exit 1; }
cannot_check() { printf 'second-review: E_NO_TOOL: %s\n' "$1" >&2; exit 2; }
note() { printf 'second-review: %s\n' "$1"; }

# Resolve the script itself first: invoked through a symbolic link from somewhere else,
# "dirname $0" is the link's directory, and the containment check below would then approve
# that directory's tmp/ instead of this repository's.
SELF=$(realpath "$0" 2>/dev/null || printf '%s' "$0")
REPO_ROOT=$(cd "$(dirname "$SELF")/.." && pwd)

BACKEND='' MODEL='' IMPLEMENTER='' BRIEF='tmp/review/brief.md' TREE='tmp/review/tree'
OUT='tmp/review' TIMEOUT=5400

# Take the value of an option, refusing when it was given without one: "--model" at the
# end of the line must not leave the model empty and fall through to a later check.
need_value() {
  [ "$2" -ge 2 ] || refuse E_ARG "$1 needs a value."
  [ -n "$3" ] || refuse E_ARG "$1 needs a value."
}
while [ $# -gt 0 ]; do
  case "$1" in
    --backend)           need_value "$1" $# "${2-}"; BACKEND="$2"; shift 2 ;;
    --model)             need_value "$1" $# "${2-}"; MODEL="$2"; shift 2 ;;
    --implementer-model) need_value "$1" $# "${2-}"; IMPLEMENTER="$2"; shift 2 ;;
    --brief)             need_value "$1" $# "${2-}"; BRIEF="$2"; shift 2 ;;
    --tree)              need_value "$1" $# "${2-}"; TREE="$2"; shift 2 ;;
    --out)               need_value "$1" $# "${2-}"; OUT="$2"; shift 2 ;;
    --timeout)           need_value "$1" $# "${2-}"; TIMEOUT="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) refuse E_ARG "unknown argument '$1'. Run with --help." ;;
  esac
done

case "$TIMEOUT" in
  ''|*[!0-9]*) refuse E_ARG "--timeout '$TIMEOUT' is not a whole number of seconds." ;;
esac

# --- what the run must say about itself -------------------------------------------------

case "$BACKEND" in
  codex|claude) ;;
  '') refuse E_BACKEND "--backend is required, and must be codex or claude." ;;
  *)  refuse E_BACKEND "--backend '$BACKEND' is not a backend this script runs; use codex or claude. To use another agent, a sub agent in your own session is a third sanctioned way -- see AGENTS.md, 'The adversarial second reviewer' -- and must meet the same three invariants, including an explicit model override so it does not inherit the implementing model." ;;
esac

[ -n "$MODEL" ] || refuse E_MODEL "--model is required: name the model the reviewer must use."
[ -n "$IMPLEMENTER" ] || refuse E_IMPL_MODEL \
  "--implementer-model is required: a second review means a different model reviewed the change, and this script cannot assert that without the model that wrote it."

# Compare the names the way the backends vary them, so a vendor prefix, a Bedrock
# cross-Region prefix, a version suffix or a context-window suffix cannot hide that two
# names are one model: "us.anthropic.claude-sonnet-5-5:0", "anthropic.claude-sonnet-5-5"
# and "claude-sonnet-5-5" all normalise the same. At most one version suffix and one
# context-window suffix come off, in whichever order they appear -- the first matching
# expression wins and `t` ends the script -- so ":0[1m]" and "[1m]:0" reduce alike without
# collapsing genuinely different names: "model:1:2" and "model[a][b]" keep a suffix and
# stay distinct from "model".
normalise_model() {
  local m
  m=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  m=$(printf '%s' "$m" | sed -E 's/^(us|eu|apac|global|us-gov)\.//')
  m=$(printf '%s' "$m" | sed -E 's/^(anthropic|openai|amazon|meta|mistral|cohere|ai21|deepseek|qwen|writer|stability|twelvelabs|luma)\.//')
  m=$(printf '%s' "$m" | sed -E 's/\[[^][]*\]:[0-9]+$//; t
                                  s/:[0-9]+\[[^][]*\]$//; t
                                  s/\[[^][]*\]$//; t
                                  s/:[0-9]+$//')
  printf '%s' "$m"
}

# Every model name is written into review-record.txt for a person to read, and codex's
# reported name and the two names given on the command line were never validated -- only
# claude's modelUsage keys were. A tab, a newline or an ESC in any of them can forge or
# alter a field of that record, so they all go through one check: printable ASCII, and no
# leading or trailing space. "+" is rejected only where claude joins several names with it.
# The whole value is tested as one string, with a shell pattern rather than grep: grep
# works a line at a time, so a name of "good<newline>forged" passed it on the strength of
# its first line, and then reached the record with a line break in it. LC_ALL=C keeps
# [:print:] to the ASCII range the record can carry.
check_model_charset() {
  local LC_ALL=C
  case "$1" in
    "" ) return 0 ;;                       # emptiness is check_model_name's business
    " "*|*" " ) refuse E_MODEL_NAME \
      "$2 '$1' begins or ends with a space, so it would be recorded as a different name than the one that answered." ;;
    *[![:print:]]*) refuse E_MODEL_NAME \
      "$2 holds a character that is not printable ASCII -- a tab, a line break or a control character -- which cannot be carried or recorded safely. The name is in the run's arguments; it is not repeated here because it would break this message across lines." ;;
  esac
}

# A name that is nothing but a prefix ("amazon.") normalises to the empty string, and two
# empty strings would compare equal while an empty and a real one would compare different.
# Neither is a model, so refuse the name instead of comparing it.
check_model_name() {
  [ -n "$2" ] || refuse E_MODEL_NAME \
    "$3 '$1' is not a model name: everything in it is a vendor prefix, a Region prefix or a version suffix, so there is nothing left to compare."
}

check_model_charset "$MODEL" "--model"
check_model_charset "$IMPLEMENTER" "--implementer-model"
want_model=$(normalise_model "$MODEL")
impl_model=$(normalise_model "$IMPLEMENTER")
check_model_name "$MODEL" "$want_model" "--model"
check_model_name "$IMPLEMENTER" "$impl_model" "--implementer-model"
[ "$want_model" != "$impl_model" ] || refuse E_SAME_MODEL \
  "the reviewer model and the implementer model are the same ('$MODEL' and '$IMPLEMENTER' both normalise to '$want_model'). An adversarial second review has to be done by a different model than the one that wrote the change."

# --- the tools and the paths --------------------------------------------------------------

case "$BACKEND" in
  codex)  BACKEND_CMD="${SECOND_REVIEW_CODEX_CMD:-codex}"
          BACKEND_ENV=SECOND_REVIEW_CODEX_CMD ;;
  claude) BACKEND_CMD="${SECOND_REVIEW_CLAUDE_CMD:-claude}"
          BACKEND_ENV=SECOND_REVIEW_CLAUDE_CMD ;;
esac
resolved_cmd=$(command -v -- "$BACKEND_CMD" 2>/dev/null) || resolved_cmd=''
[ -n "$resolved_cmd" ] && [ -x "$resolved_cmd" ] || refuse E_CMD_MISSING \
  "cannot run the $BACKEND backend: '$BACKEND_CMD' is not an executable command. Install it, or name the command to use in \$$BACKEND_ENV."

command -v python3 >/dev/null 2>&1 || cannot_check "python3 is needed to read the backend's record of which model answered."
command -v sha256sum >/dev/null 2>&1 || cannot_check "sha256sum is needed to show the reviewer did not change the tree."
command -v realpath >/dev/null 2>&1 || cannot_check "realpath is needed to check the output path stays under the repository's tmp/."
command -v readlink >/dev/null 2>&1 || cannot_check "readlink is needed to check every link the backend command points through."

[ -f "$BRIEF" ] || refuse E_BRIEF "no brief at '$BRIEF'. Write one from the second-review skill's assets/review-brief.md."
[ -s "$BRIEF" ] || refuse E_BRIEF "the brief at '$BRIEF' is empty; a reviewer given nothing to check finds nothing."
# Readable, not merely present and non-empty: -f and -s both pass for a mode-000 file, and
# the failure then surfaced far later and misattributed. On the codex path "cat" failed and
# set -e ended the run with no tag at all; on the claude path the input redirection failed,
# which was reported as "the claude backend exited 1" when claude had never run.
[ -r "$BRIEF" ] || refuse E_BRIEF "the brief at '$BRIEF' cannot be read (check its permissions); the reviewer is given it on standard input, so the run would fail after the output directory had already been cleared."
[ -d "$TREE" ] || refuse E_TREE "no tree to review at '$TREE'. Extract the commit there first ('git archive <commit> | tar -x -C $TREE')."

# The brief, the review and the trace all belong in the gitignored tmp/, and the trace can
# hold credential details, so both paths are checked before anything is created and a
# refused run leaves nothing behind in a tracked folder. -m resolves a path that does not
# exist yet; both sides are canonical, so a "..", a symbolic link, or a sibling whose name
# merely starts with "tmp" cannot pass.
# tmp/ itself must be a real directory in the repository. Were it a symbolic link to, say,
# examples/, resolving it would make a tracked folder the approved destination and the
# check would wave the trace straight into it.
[ ! -L "$REPO_ROOT/tmp" ] || refuse E_TMP_IS_LINK \
  "'$REPO_ROOT/tmp' is a symbolic link, so where the brief, the review and the trace would land is not this repository's gitignored tmp/. Make it a real directory."
TMP_ABS=$(realpath -m "$REPO_ROOT/tmp") || refuse E_NOT_IN_TMP \
  "could not resolve '$REPO_ROOT/tmp', so there is nothing to check the brief and output paths against."
# Every name this script writes into --out, in one place. The cleanup below clears exactly
# these, and no input the script reads may sit at one of them. Keeping the list in two
# places meant the check and the cleanup had to be kept in step by hand, which is the kind
# of enumeration this script otherwise avoids.
OUT_NAMES="review.out review.err review.json review-record.txt record.tsv
preamble.txt pre-user.txt codex-stdin.txt
tree-before.sha256 tree-at-return.sha256 tree-after.sha256"

# An input at one of those names would pass its own [ -f ] check and then be removed by the
# cleanup before it could be read, so refuse it rather than delete the thing we were asked
# to read. Checked for every input path rather than only the brief: a settings file at one
# of the names was cleared the same way, and because its own check now runs before the
# cleanup, the run went on to hand claude a file that was no longer there.
# $3 names the input in the message, $4 is the tag to refuse with, so each input refuses
# under the tag its own option already uses.
not_an_output_name() {
  local n d
  # The directory is resolved here, not left to the caller. The brief and the settings file
  # arrive already canonical, but the backend command does not: "command -v" hands back the
  # command as typed, so a relative "tmp/review/review.out" or a "./" in the middle gave a
  # dirname that never equalled $2, and the guard passed while the cleanup still unlinked
  # the file. Only the directory is resolved: the cleanup removes the NAME, so a symbolic
  # link at one of these names is cleared whatever it points at, and resolving the whole
  # path would compare the target instead.
  d=$(realpath -m -- "$(dirname -- "$1")" 2>/dev/null) || refuse "$4" \
    "$3 '$1' has a directory this script cannot resolve, so it cannot be shown to sit outside --out. A guard that cannot answer must refuse, as the tmp/ containment check does."
  for n in $OUT_NAMES; do
    [ "$(basename -- "$1")" = "$n" ] || continue
    [ "$d" != "$2" ] || refuse "$4" \
      "$3 '$1' has the name of a file this script writes into --out, and would be removed before being read. Rename it."
  done
}

in_repo_tmp() {
  local p
  # A symlink loop or a path realpath cannot resolve must refuse, not run unchecked.
  p=$(realpath -m "$1" 2>/dev/null) || refuse E_NOT_IN_TMP \
    "could not resolve $2 '$1' to a real path, so it cannot be shown to be under this repository's gitignored tmp/."
  case "$p/" in "${TMP_ABS%/}/"*) printf '%s' "$p"; return 0 ;; esac
  refuse E_NOT_IN_TMP \
    "$2 '$p' is not under this repository's gitignored tmp/ ('$TMP_ABS'). The brief, the review and the backend's trace live there: the trace can hold credential details, and anything in a tracked folder is one 'git add' from being published."
}
OUT_ABS=$(in_repo_tmp "$OUT" --out)
BRIEF_ABS=$(in_repo_tmp "$BRIEF" --brief)
not_an_output_name "$BRIEF_ABS" "$OUT_ABS" "the brief" E_BRIEF
# The backend command is an input path too. A backend binary living inside --out under one
# of these eleven names is far-fetched, but the command path is taken from the environment,
# so it is the caller's to get wrong: the cleanup would unlink it after it had passed its
# own executable check. Not at --version, whose failure is swallowed by
# "|| backend_version=''": the run fails at the backend invocation, as E_RUN_FAILED. The exit
# code depends on the name AND on the backend, because the two do not re-create the same
# names before the call: a command path this script has just re-created as a fresh,
# non-executable file gives 126, and one that is simply not there gives 127. Before the codex
# call the re-created names are review.out, review.err, codex-stdin.txt and
# tree-before.sha256; before the claude call they are review.err, review.json and
# tree-before.sha256 -- review.out is written later, by the record extractor -- so a claude
# command at review.out gives 127 where a codex one gives 126. Measured: a codex command
# pointing at review.out exits 126.
not_an_output_name "$resolved_cmd" "$OUT_ABS" "the $BACKEND command" E_CMD_MISSING
# ...and every link it points THROUGH, not only the name it was given. For the brief and the
# settings file the name is the whole story, because the cleanup removes the name and leaves
# the target alone. The command is different: it is EXECUTED through the path as typed, so
# every link in the chain has to survive the cleanup. A chain
# "PATH/codex -> $OUT/review.out -> /real/codex" passes a check on the first name and a check
# on the final target alike, since both of those are innocent; the cleanup then unlinks the
# middle one, and the run dies at the backend call with any earlier review in that --out
# already gone (measured: E_RUN_FAILED, exit 126). So walk the chain and check each hop. A
# relative target is resolved against the link's own directory, as the kernel does. The walk
# ends by itself, because a loop would already have failed the -x above; the hop bound is a
# backstop against a link created while this runs, not a case a caller can produce.
cmd_hop="$resolved_cmd" cmd_hops=0
while [ -L "$cmd_hop" ]; do
  cmd_hops=$((cmd_hops + 1))
  [ "$cmd_hops" -le 64 ] || refuse E_CMD_MISSING \
    "the $BACKEND command '$resolved_cmd' points through more than 64 symbolic links, so where it leads cannot be established. A guard that cannot answer must refuse."
  cmd_link=$(readlink -- "$cmd_hop") || refuse E_CMD_MISSING \
    "could not read the symbolic link '$cmd_hop' that the $BACKEND command '$resolved_cmd' points through, so where it leads cannot be established. A guard that cannot answer must refuse."
  case "$cmd_link" in
    /*) cmd_hop="$cmd_link" ;;
    *)  cmd_hop="$(dirname -- "$cmd_hop")/$cmd_link" ;;
  esac
  not_an_output_name "$cmd_hop" "$OUT_ABS" "the $BACKEND command points through," E_CMD_MISSING
done
# The walk above ends on "[ -L ] is false", which means BOTH "this is the end of the chain"
# and "this path could not be looked at" -- and the second one silently leaves every hop
# after it unchecked, which is the fail-open shape this commit exists to remove, in the guard
# added to remove it. Two ways to get there, both caller-built: a relative target is
# concatenated rather than normalised, so a chain of long relative targets grows the path
# string past PATH_MAX while the kernel still resolves the chain one target at a time
# (measured: five hops of 960 characters end the walk at 4816 characters, with -x on the
# command still passing); and a component or target ending in a newline loses it to "$( )",
# sending the walk to a different path. So require that the walk arrived at the same file the
# command actually is. -ef compares device and inode with links followed, so it is true
# whenever the walk completed -- including when the command is not a link at all, where
# cmd_hop is still the command -- and false exactly when the walk ended somewhere else.
[ "$cmd_hop" -ef "$resolved_cmd" ] || refuse E_CMD_MISSING \
  "could not follow every link the $BACKEND command '$resolved_cmd' points through -- the walk ended at a path that is not the command's own file -- so the chain cannot be shown to stay clear of --out. A guard that cannot answer must refuse."
# ...and where it ends up with every DIRECTORY component resolved as well. Being exact about
# what this adds, because it is easy to overclaim: once the walk above has completed, almost
# nothing. The walk's last hop is the command's own file, and not_an_output_name resolves the
# directory of every name it is given, so a path that ends at an output name in --out -- by a
# directory link, by "..", or after leaving and re-entering --out -- is already refused up
# there. It is kept as redundancy, deliberately and not as dead code: this is the line that
# was failing open, and the walk is new.
# It refuses when it cannot resolve rather than skipping the check: it used to fall back to an
# empty value and pass. That refusal is unreachable without a stub -- "-x" above has already
# resolved this path through the kernel, so the only ways here are a realpath that cannot
# answer (which is how the proof case reaches it) or the path changing under the run -- but
# the rule is the one not_an_output_name states, a guard that cannot answer must refuse, and a
# later edit must not be able to reintroduce the fallback by accident.
cmd_target=$(realpath -- "$resolved_cmd" 2>/dev/null) || refuse E_CMD_MISSING \
  "could not resolve where the $BACKEND command '$resolved_cmd' points, so it cannot be shown to sit outside --out. A guard that cannot answer must refuse, as the tmp/ containment check does."
[ "$cmd_target" = "$resolved_cmd" ] || \
  not_an_output_name "$cmd_target" "$OUT_ABS" "the $BACKEND command resolves to," E_CMD_MISSING

TREE_ABS=$(realpath "$TREE")

# A newline in the tree's path breaks two things, so it is refused rather than carried.
# First, codex prints "workdir: <tree>" inside its own preamble, on a line ahead of the
# "model:", "sandbox:" and "approval:" lines this script reads back from it, so such a path
# lands inside the block the preamble check parses and could pass itself off as codex's own
# report of how it ran. That path comes from the caller and not from the brief -- a caller who
# wanted to lie could lie in --implementer-model just as cheaply -- so this closes a seam
# rather than an attack, and the nonce check still bounds what the BRIEF can reach.
# Second, and worse, the line above silently loses a TRAILING newline: "$( )" strips it along
# with realpath's own, so a directory genuinely named "tree\n" resolves to the sibling path
# "tree" and the run would fingerprint and review a different tree than the one named.
# Checked: that is what happens, and the run reports no problem when the sibling exists.
# Both are tested on $TREE as well as $TREE_ABS, because only $TREE still holds a newline the
# substitution stripped. Refused on both backends: only codex has a preamble, but neither can
# be given the wrong tree.
case "$TREE$TREE_ABS" in
  *$'\n'*) refuse E_TREE \
    "the tree path contains a line break. Resolving it would quietly drop a trailing one and review a different directory, and on the codex backend such a path lands inside the block this script parses back out of codex's own preamble, where it could pass itself off as codex's report of the mode it ran in. Extract the commit somewhere whose path has no line break in it." ;;
esac

# This script's own output inside the tree would show up as the tree changing, and read
# as a reviewer that wrote to it. Keep them apart rather than explain the false alarm.
tree_prefix="${TREE_ABS%/}/"
case "$OUT_ABS/" in
  "$tree_prefix"*) refuse E_OUT_IN_TREE \
    "--out '$OUT_ABS' is inside the tree under review '$TREE_ABS'; this script's own files would read as the reviewer changing the tree. Put --out beside the tree, under the repository's tmp/." ;;
esac

# A reviewer must not be able to change what it reviews. The backend is told to run
# read-only, and this is the check that it did: every path's type, mode, size, modification
# time and symlink target, and every regular file's content hash, before and after. A
# single added, removed, edited, re-pointed or re-permissioned path fails the run. What it
# is not guaranteed to see: a file created and deleted within the run, and any write outside
# the tree. "Not guaranteed" rather than "cannot", for the first of those: creating and
# removing a file changes the mtime of the directory that held it, and every directory's
# mtime below the root is fingerprinted, so such a change usually does show up -- unless it
# was in the tree's own root directory, which -mindepth 1 skips, or the mtime was put back.
# "Usually" is more optimistic on the codex path than it sounds: codex is given the tree as
# its working directory with -C, so a scratch file it creates and removes lands in exactly
# the root directory that is skipped. The second limit is flat: nothing outside the tree is
# looked at.
# Records are NUL-delimited, and so is the hash list, because a path may legally hold a
# newline or the text " -> ": with line-delimited records two different trees could line
# up to the same fingerprint. cmp compares the bytes, so the delimiter never has to be
# read back.
# The first pipeline carries "|| exit 1" of its own rather than relying on set -e: this
# function is also called from an "if" condition, where set -e is switched off for the whole
# call, and the subshell's status would then come only from the second pipeline. A tree whose
# metadata listing failed but which holds no regular file for the second pipeline to hash
# would otherwise produce a short baseline, and what happened next depended on whether the
# failure persisted -- two different bad outcomes, not one sequence. Persistent: the at-return
# fingerprint runs as a plain command, so set -e ended the run, after the backend had been
# paid for and with no tag. Transient: that fingerprint succeeded, so the short baseline was
# compared against a full one and the reviewer was blamed for "changing" the tree. What this
# buys is refusing early instead, with the right cause.
tree_fingerprint() {
  ( cd "$1" || exit 1
    { find . -mindepth 1 -printf '%y %m %s %T@ %p -> %l\0' | LC_ALL=C sort -z; } || exit 1
    find . -mindepth 1 -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum -z )
}

# Validate the claude backend's two optional paths here, before anything is created or
# removed. They were checked inside the backend branch, which runs after the cleanup below,
# so a mistyped one deleted a completed review and only then refused -- ten to twenty-five
# minutes of billed work lost to a typo.
#
# Emptied first, and deliberately: these two are read much later as "${var:-}" to decide
# whether to pass --settings and --add-dir. Bash makes every environment variable a shell
# variable, so without this an exported lowercase "claude_settings_abs" would reach
# --settings with the allowlist never having run -- a settings file can carry hooks, which
# execute -- and an exported "context_abs" would reach --add-dir without the containment
# check that keeps the trace away from the reviewer. Before these checks were moved, the
# arguments were appended inside the checked branch and neither could happen.
claude_settings_abs='' context_abs=''
if [ "$BACKEND" = claude ]; then
  if [ -n "${SECOND_REVIEW_CLAUDE_SETTINGS:-}" ]; then
    [ -f "$SECOND_REVIEW_CLAUDE_SETTINGS" ] || refuse E_CLAUDE_SETTINGS \
      "\$SECOND_REVIEW_CLAUDE_SETTINGS names '$SECOND_REVIEW_CLAUDE_SETTINGS', which is not a file."
    claude_settings_abs=$(realpath "$SECOND_REVIEW_CLAUDE_SETTINGS") || refuse E_CLAUDE_SETTINGS \
      "could not resolve \$SECOND_REVIEW_CLAUDE_SETTINGS '$SECOND_REVIEW_CLAUDE_SETTINGS'."
    settings_verdict=$(python3 -I -c '
import json, sys
ALLOWED = {"awsCredentialExport", "apiKeyHelper"}
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception as e:
    print("could not read it as JSON: %s" % str(e)[:200]); raise SystemExit(0)
if not isinstance(d, dict):
    print("it is a %s, not an object" % type(d).__name__); raise SystemExit(0)
extra = sorted(set(d) - ALLOWED)
if extra:
    print("it sets %s; only %s may be set here. A settings file can carry hooks, MCP "
          "servers, plugins, a status line, permissions and a model override, and several "
          "of those run a command or widen what the reviewer can reach, so this is an "
          "allowlist of the two authentication keys rather than a list of things to block"
          % (json.dumps(extra)[:200], " or ".join(sorted(ALLOWED)))); raise SystemExit(0)
# Exactly one, so a valid helper cannot sit beside a malformed second one.
if len(d) != 1:
    print("it sets %d of %s; set exactly one"
          % (len(d), " or ".join(sorted(ALLOWED)))); raise SystemExit(0)
k = next(iter(d))
if not isinstance(d[k], str) or not d[k].strip():
    print("its %s is %s, not a non-empty string, so it would restore no credential path "
          "and the run would fall back to ambient credentials"
          % (k, json.dumps(d[k])[:120])); raise SystemExit(0)
print("OK")
' "$claude_settings_abs" 2>/dev/null) || settings_verdict="could not be read"
    [ "$settings_verdict" = OK ] || refuse E_CLAUDE_SETTINGS \
      "the settings file '$claude_settings_abs' cannot be used: $settings_verdict."
    not_an_output_name "$claude_settings_abs" "$OUT_ABS" \
      "the settings file \$SECOND_REVIEW_CLAUDE_SETTINGS names," E_CLAUDE_SETTINGS
  fi
  if [ -n "${SECOND_REVIEW_CONTEXT_DIR:-}" ]; then
    [ -d "$SECOND_REVIEW_CONTEXT_DIR" ] || refuse E_CONTEXT_DIR \
      "\$SECOND_REVIEW_CONTEXT_DIR names '$SECOND_REVIEW_CONTEXT_DIR', which is not a directory."
    # Searchable is the hard requirement: without it nothing inside can be opened at all,
    # and the only symptom would be a reviewer that silently never reads the diff the brief
    # named. Being LISTABLE (-r) is not required, and demanding it refused a legitimate
    # setup: a mode-0711 directory cannot be listed, but a file named in the brief by its
    # absolute path still reads from it -- checked. Since the reviewer also holds Glob and
    # Grep, which do need to list, say so rather than refuse.
    [ -x "$SECOND_REVIEW_CONTEXT_DIR" ] || refuse E_CONTEXT_DIR \
      "\$SECOND_REVIEW_CONTEXT_DIR '$SECOND_REVIEW_CONTEXT_DIR' cannot be searched (check its permissions); nothing inside it could be opened, so the reviewer would silently never read the diff the brief names."
    # The "say so" half of the rule above. Without this the sentence described a message the
    # script never printed, and a 0711 context directory still left Glob and Grep finding
    # nothing in it with no sign of why.
    [ -r "$SECOND_REVIEW_CONTEXT_DIR" ] || note \
      "\$SECOND_REVIEW_CONTEXT_DIR '$SECOND_REVIEW_CONTEXT_DIR' can be searched but cannot be listed, so a file the brief names by its full path still reads, while the reviewer's Glob finds nothing there and its Grep searches only a file it is given by full path."
    context_abs=$(realpath "$SECOND_REVIEW_CONTEXT_DIR") || refuse E_CONTEXT_DIR \
      "could not resolve \$SECOND_REVIEW_CONTEXT_DIR '$SECOND_REVIEW_CONTEXT_DIR'."
    # Compare against a prefix that always ends in exactly one slash. The obvious
    # "$dir"/* is wrong when the directory is "/", because realpath returns that with
    # its own trailing slash and the pattern becomes //*, which matches no ordinary
    # absolute path -- SECOND_REVIEW_CONTEXT_DIR=/ would then have been passed to
    # --add-dir, handing the reviewer the whole filesystem, trace included. Writing it
    # as "${dir%/}"/* is also wrong: that leaves a quoted empty string, which bash does
    # not match either. Checked all three forms against "/" and ordinary paths. This
    # also covers the directory being exactly --out, so no equality test is needed; one
    # was there, could never run, and made a harness case pass with the wrong message.
    context_prefix="${context_abs%/}/"
    case "$OUT_ABS/" in
      "$context_prefix"*) refuse E_CONTEXT_DIR \
        "\$SECOND_REVIEW_CONTEXT_DIR '$context_abs' is, or contains, the output directory, so it would give the reviewer the backend's trace. Use a directory holding only what the reviewer may read." ;;
    esac
  fi
fi

# Read the tree once, discarding the result, before anything is cleared. The baseline
# fingerprint below is a *write*, so it has to come after the cleanup -- but it can fail
# because the TREE cannot be read, which is an input mistake (a mistyped --tree, a file
# with no read permission) and not a write failure at all. Finding that out after the
# cleanup meant a typo destroyed a previous run's review and was then reported as a problem
# with --out. Reading it here costs one extra traversal and keeps every refusal that is
# about the caller's arguments ahead of the cleanup.
tree_fingerprint "$TREE_ABS" > /dev/null 2>&1 || refuse E_TREE \
  "the tree at '$TREE_ABS' cannot be fully read, so it cannot be fingerprinted: check it exists and that every file and directory in it is readable. Nothing has been removed."

mkdir -p "$OUT_ABS"

# Remove anything already sitting at a name this script writes, immediately before the
# first write. Every refusal this script can make from the caller's arguments alone now
# comes earlier. What is left after this point either writes (the baseline fingerprint,
# codex-stdin.txt, the mktemp for the reviewer's working directory) or reads the backend's
# own output. Two honest exceptions, both after the cleanup. An argument only the BACKEND can
# judge -- a bad --model, provider or effort, or credentials its settings file does not
# carry -- still surfaces as E_RUN_FAILED, and that cannot be checked here. And an --out that
# cannot be written is refused in several different places, depending on what is in it and
# when it became unwritable, and all of them were measured with a stub that chmods --out
# while answering --version:
#
#   * unwritable from the start, with an earlier output still there: every rm fails and the
#     second pass below refuses E_OUT_TAINTED, having removed nothing;
#   * unwritable from the start and empty: every rm succeeds, and the first write refuses
#     E_OUT_TAINTED instead;
#   * becoming unwritable after the baseline fingerprint, codex path: the next write is
#     codex-stdin.txt, which is not guarded, so set -e ends the run with bash's own UNTAGGED
#     message. The same for a full disk, and the same later at tree-at-return.sha256;
#   * becoming unwritable after the baseline fingerprint, claude path: the next thing is the
#     mktemp for the reviewer's working directory, which IS guarded -- E_NO_CWD;
#   * a redirection failing at the backend call lands in run_status, so it is reported as
#     E_RUN_FAILED and reads as the backend's fault rather than --out's;
#   * an --out that mkdir -p above cannot create at all is untagged too.
#
# None of these records a review, and none of them removes anything from the tree. Tagging
# the later writes is left to the redesign in issue #100 rather than added here.
# Two reasons for that placement, both learned the hard way: with --out inside the tree
# this loop deleted files from the snapshot and only then refused E_OUT_IN_TREE -- a guard
# in a tool whose whole promise is not touching the tree, destroying files in it -- and a
# re-run into a used --out with some other argument mistyped would throw away the previous
# run's review.out and review-record.txt, which is ten to twenty-five minutes of billed
# work, before refusing for the unrelated mistake.
#
# Removing rather than refusing, because refusing only caught symbolic links: a hard link
# passes [ -L ] and shares its target's file, so ">", tee and python's open all write
# straight into whatever it names. Checked both. Removing a name never touches its target,
# and it covers symbolic links, hard links, FIFOs, sockets and device nodes at once. It can
# only account for what exists before the run: something writing into --out *during* it
# could overwrite tree-before.sha256 itself, which no check here could defend against.
# The names come from $OUT_NAMES, set above and also used to refuse an input sitting at one
# of them, so the cleanup and that check cannot drift apart.
#
# Two passes, because this is an action and not a refusal: a single pass that removed as it
# went had already destroyed the earlier results by the time it met a name it could not
# remove. Being exact about what the first pass buys, because it is easy to overclaim:
#
#   * It refuses a **directory** at any of the names without removing anything. That is the
#     one blocker a caller can actually produce here, and the case that prompted this.
#   * An **unwritable --out** is also atomic, by accident rather than design: every existing
#     name then fails to be removed, so the second pass refuses on the first of them.
#   * It does **not** cover every way `rm -f` can fail. An immutable or append-only file, a
#     bind mount (EBUSY), a file owned by someone else in a sticky directory, or a directory
#     created between the two passes will still refuse in the second pass, by which point
#     earlier names are already gone. Each needs something the ordinary caller does not have:
#     privilege (a bind mount; "chattr +i", checked -- refused without it, on Linux), a
#     SECOND USER's file in a sticky directory, or another process racing this one -- and
#     such a process could overwrite tree-before.sha256 anyway, which no check here defends
#     against. An --out path long enough that only the longest names hit ENAMETOOLONG also
#     qualifies, absurdly.
#     One exception to "needs privilege", for honesty: on macOS a file's OWNER can set
#     "chflags uchg", no privilege required. It is moot here only because this script needs
#     GNU find -printf, realpath -m and sort -z, so it does not run on stock macOS anyway.
#
# So: the first pass makes the reachable case atomic and the second pass is the backstop,
# whose message says only what it knows.
for _n in $OUT_NAMES; do
  if [ -d "$OUT_ABS/$_n" ] && [ ! -L "$OUT_ABS/$_n" ]; then
    refuse E_OUT_TAINTED \
      "'$OUT_ABS/$_n' is a directory, so this script cannot write its output there. Nothing has been removed. Use a fresh --out."
  fi
done
for _n in $OUT_NAMES; do
  if ! rm -f -- "$OUT_ABS/$_n" 2>/dev/null || [ -e "$OUT_ABS/$_n" ] || [ -L "$OUT_ABS/$_n" ]; then
    refuse E_OUT_TAINTED \
      "'$OUT_ABS/$_n' is in the way and this script cannot clear it -- something is re-creating it, or it cannot be removed. Earlier names in the list may already have been cleared, so treat a previous run's output there as lost. Use a fresh --out."
  fi
done

# An --out that cannot be written at all reaches here: removing a name that is not there
# succeeds, so the loop above passes and the first redirection is what fails. Tag that
# failure rather than letting set -e end the run with bash's own untagged message.
#
# The first real write is the probe. A separate one at a fixed name was tried and was a
# hole: ">" follows a symbolic link, so a stale or planted link at that name pointed the
# probe wherever it liked -- checked, and it truncated a file in the tree -- and because
# the probe ran before this fingerprint, the damage was already in the "before" baseline
# and the run reported the tree unchanged. The names above have just been removed, so
# writing to one of them cannot follow a link, and no extra name has to be cleared.
if ! tree_fingerprint "$TREE_ABS" > "$OUT_ABS/tree-before.sha256"; then
  refuse E_OUT_TAINTED \
    "could not write '$OUT_ABS/tree-before.sha256'. The tree was read successfully a moment ago, so this is about the destination: an --out that cannot be written, a full disk, or a read-only filesystem. Nothing in the tree has been touched."
fi

# A short, per-run ASCII line, prepended to what the codex backend reads and used to
# authenticate the preamble boundary below. It only has to be something the brief cannot
# already contain -- the brief is written before the run -- so bash's own RANDOM is
# enough and adds no dependency on another tool.
NONCE_LINE="second-review-nonce-$$-${RANDOM}${RANDOM}${RANDOM} (harness marker, ignore this line)"

timeout_cmd=()
if command -v timeout >/dev/null 2>&1; then timeout_cmd=(timeout "$TIMEOUT"); fi

backend_version=$("$resolved_cmd" --version 2>/dev/null | head -1) || backend_version=''
[ -n "$backend_version" ] || backend_version='(the backend did not report a version)'

note "backend     $BACKEND ($resolved_cmd, $backend_version)"
note "model       $MODEL requested; the implementer was $IMPLEMENTER"
note "tree        $TREE_ABS"
note "brief       $BRIEF_ABS"
note "writing     $OUT_ABS/review.out, review.err, review-record.txt"
note "this usually takes 10 to 25 minutes, less for a tightly scoped brief; review.out is written at the end."

run_status=0
case "$BACKEND" in
  codex)
    # --sandbox read-only alone does NOT stop codex writing: it leaves the approval policy
    # at on-request, so apply_patch asks to escalate, and a host whose config sets
    # approvals_reviewer answers that ask by itself. Observed on 2026-10-25: a reviewer run
    # with --sandbox read-only created a file in the tree and appended to a page, and
    # reported both as successful. approval_policy=never leaves nothing to answer the ask,
    # and the same two writes come back "read-only file system".
    codex_args=(exec --skip-git-repo-check --sandbox read-only -c approval_policy="never"
                -C "$TREE_ABS" -m "$MODEL")
    # An "[ x ] && y" here would end the script under set -e whenever x is false.
    if [ -n "${SECOND_REVIEW_CODEX_PROVIDER:-}" ]; then
      codex_args+=(-c "model_provider=\"$SECOND_REVIEW_CODEX_PROVIDER\"")
    fi
    if [ -n "${SECOND_REVIEW_CODEX_EFFORT:-}" ]; then
      codex_args+=(-c "model_reasoning_effort=\"$SECOND_REVIEW_CODEX_EFFORT\"")
    fi
    codex_args+=(-)
    # What codex actually reads: this run's nonce, then the brief. The nonce is what the
    # preamble boundary is authenticated against below, so it must not be anything the
    # author could have written into the brief.
    {
      printf '%s\n' "$NONCE_LINE"
      cat "$BRIEF_ABS"
    } > "$OUT_ABS/codex-stdin.txt"
    # Take the AWS credentials out of the environment unless asked not to, so a machine
    # that holds credentials for another account cannot have the review billed to it: the
    # backend is left with whatever its own configuration pins. Fails closed -- a codex
    # that needed those credentials now cannot authenticate, and says so through
    # E_RUN_FAILED rather than quietly billing someone else.
    aws_env=(env)
    if [ "${SECOND_REVIEW_KEEP_AWS_ENV:-0}" != 1 ]; then
      # AWS_CONFIG_FILE is pointed at /dev/null rather than unset: unsetting it makes the
      # SDK fall back to the default ~/.aws/config, whose profiles can carry credentials
      # or a credential process, which is the very thing being kept out. Same for the
      # shared credentials file.
      aws_env=(env -u AWS_PROFILE -u AWS_DEFAULT_PROFILE
               -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN
               -u AWS_BEARER_TOKEN_BEDROCK -u AWS_CREDENTIAL_EXPIRATION
               -u AWS_CONTAINER_CREDENTIALS_FULL_URI
               -u AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
               -u AWS_CONTAINER_AUTHORIZATION_TOKEN
               -u AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE
               -u AWS_WEB_IDENTITY_TOKEN_FILE -u AWS_ROLE_ARN -u AWS_ROLE_SESSION_NAME
               -u AWS_ACCESS_KEY -u AWS_SECRET_KEY -u AWS_SECURITY_TOKEN
               -u AWS_CREDENTIAL_PROFILES_FILE
               AWS_CONFIG_FILE=/dev/null BOTO_CONFIG=/dev/null
               AWS_CREDENTIAL_FILE=/dev/null AWS_CREDENTIALS_FILE=/dev/null
               AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true)
    fi
    ${timeout_cmd[@]+"${timeout_cmd[@]}"} "${aws_env[@]}" "$resolved_cmd" "${codex_args[@]}" \
      < "$OUT_ABS/codex-stdin.txt" > "$OUT_ABS/review.out" 2> "$OUT_ABS/review.err" || run_status=$?
    ;;
  claude)
    # --restricted takes away the tools that run commands or code and ignores the user,
    # project and local settings files, so none of them can hand a write tool back;
    # --strict-mcp-config with no --mcp-config leaves the reviewer no MCP server, which
    # is where the write-capable tools on a configured workstation live;
    # --disallowedTools is the deny list for the rest; and --permission-prompts none
    # means nothing can answer a permission request, so a tool that needs one is refused.
    # --tools is the list of tools the reviewer HOLDS. --allowedTools, which this used
    # before, only says which tools may run without asking -- it does not take any away.
    # With it alone the reviewer still held ToolSearch, Skill, ListAgents, ReportFindings
    # and ScheduleWakeup, and could load SendMessage, EnterWorktree, ExitWorktree, CronList
    # and CronDelete. Three of those act outside the tree, where the fingerprint cannot
    # see them: SendMessage reaches other sessions on the machine, EnterWorktree acts on
    # the enclosing repository, CronDelete removes scheduled tasks. Asked to list its
    # tools, a reviewer under the old flags named all of them and said it could message
    # another session; under --tools it names exactly three and says it cannot.
    # --disallowedTools stays as a second layer: --restricted withholds the code-running
    # tools unless --tools names them, so the layer matters if a later edit ever adds one
    # to --tools.
    claude_args=(-p --output-format json --model "$MODEL"
                 --restricted
                 --strict-mcp-config
                 --tools "Read,Grep,Glob"
                 --disallowedTools "Edit,Write,NotebookEdit,Bash,BashOutput,KillShell,Task,Agent,WebFetch,WebSearch"
                 --permission-prompts none)
    # Ignoring the user settings file also throws away how this claude authenticates, when
    # it authenticates through a setting such as awsCredentialExport or apiKeyHelper: the
    # run then falls back to whatever ambient credentials happen to exist, which fails when
    # there are none and bills the wrong account when there are. --settings is still read
    # under --restricted, so naming a file that carries that one setting restores the
    # credential path.
    #
    # The file's contents are checked, and only the authentication keys are allowed,
    # because --settings restores *executable* configuration and not just values. A
    # permission grant in it is harmless -- a file granting Bash, Write and Edit still left
    # the reviewer unable to write, since --restricted removes the tools rather than denying
    # them -- but a `hooks` entry runs shell commands outside the tool list entirely. One
    # with a SessionStart command hook was tried under the full read-only flag set and it
    # executed and created a file, so a settings file this script accepted unchecked would
    # hand the reviewer arbitrary execution.
    if [ -n "${claude_settings_abs:-}" ]; then claude_args+=(--settings "$claude_settings_abs"); fi
    # Run from a directory made fresh for this run rather than from the tree, with the tree
    # added as a readable directory. Why: an allowed credential helper is still a command
    # claude executes, and with the tree as the working directory it would execute inside
    # the very thing under review. --out is already required to sit outside the tree.
    #
    # mktemp -d, not a fixed name: --out can be reused, and "mkdir -p" on a path that is
    # already a symbolic link succeeds without replacing it, so a stale or planted
    # claude-cwd link pointing at the tree would have put the helper straight back inside
    # it. Checked that mkdir -p behaves that way and that cd follows the link. (It would
    # not have widened what the file tools reach: --add-dir already grants the tree.)
    # A distinct tag, not E_NO_TOOL: that one is printed by cannot_check and means "a tool
    # this script needs is missing", which exits 2 for "could not check". This is a refusal
    # of the run, which exits 1, and a caller that treats 2 differently should not see one.
    claude_cwd=$(mktemp -d "$OUT_ABS/claude-cwd.XXXXXX") || refuse E_NO_CWD \
      "could not make a working directory for the reviewer under $OUT_ABS, so there is nowhere to run it that is outside the tree."
    claude_args+=(--add-dir "$TREE_ABS")
    # The brief often points at the commit's diff, which sits outside the tree. Codex is
    # given the tree as its working root and can read an absolute path; claude under
    # --restricted confines its file tools to the working directory and the added ones, so
    # it refused that read until this existed. Name a directory holding only material the
    # reviewer may read -- never --out, which holds the trace.
    if [ -n "${context_abs:-}" ]; then claude_args+=(--add-dir "$context_abs"); fi
    ( cd "$claude_cwd" && ${timeout_cmd[@]+"${timeout_cmd[@]}"} "$resolved_cmd" "${claude_args[@]}" ) \
      < "$BRIEF_ABS" > "$OUT_ABS/review.json" 2> "$OUT_ABS/review.err" || run_status=$?
    # Any error the backend reports means no review happened, whatever its wording, so the
    # record is rejected on `is_error` alone and the error code only chooses the message.
    # This extractor fails CLOSED: it prints one of three fixed ASCII words, and anything
    # else -- including python failing outright -- refuses the run. It used to clear the
    # variable on failure, which meant "no error": a record whose api_error held an
    # unpaired surrogate crashed the print with UnicodeEncodeError, and the run was then
    # recorded as a successful review. The record validator below also rejects is_error on
    # its own, so neither check is the only thing standing between a failed run and a
    # review that looks real.
    if [ -s "$OUT_ABS/review.json" ]; then
      claude_status=$(python3 -I -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    print("NO_RECORD"); raise SystemExit(0)
if not isinstance(d, dict):
    print("NO_RECORD"); raise SystemExit(0)
if not d.get("is_error"):
    print("OK"); raise SystemExit(0)
# Only ASCII leaves this script, so no value in the record can break the print.
blob = "%s %s %s" % (d.get("api_error") or "", d.get("result") or "",
                     d.get("api_error_status") or "")
blob = blob.encode("ascii", "replace").decode("ascii").lower()
print("ERROR_AUTH" if ("credential" in blob or "authenticat" in blob or "403" in blob)
      else "ERROR_OTHER")
' "$OUT_ABS/review.json" 2>/dev/null) || claude_status=EXTRACTOR_FAILED
      case "$claude_status" in
        OK) ;;
        ERROR_AUTH) refuse E_RUN_FAILED \
          "the claude backend could not authenticate, so no review was produced. The most likely cause on a machine where claude authenticates through a settings file: --restricted makes it ignore the user settings file, so set \$SECOND_REVIEW_CLAUDE_SETTINGS to a file carrying only that authentication setting. Read $OUT_ABS/review.err yourself with tail, and do not paste it into a pull request, an issue or Slack." ;;
        ERROR_OTHER) refuse E_RUN_FAILED \
          "the claude backend reported an error, so no review was produced. Read $OUT_ABS/review.json and $OUT_ABS/review.err yourself with tail, and do not paste them into a pull request, an issue or Slack." ;;
        *) refuse E_BAD_RECORD \
          "could not tell whether the claude backend reported an error (the check returned '$claude_status'), so this run cannot be recorded as a review. Check $OUT_ABS/review.json." ;;
      esac
    fi
    ;;
esac

# Fingerprint the tree as soon as the backend returns, so that the two codex confinement
# refusals below can say whether the tree changed: they are read from codex's preamble
# after it ran, and a reader most wants to know that at exactly that moment. This early
# snapshot feeds those messages, and is also compared at the end: a mismatch here with a
# match later means something put the tree back *after the backend returned*, which a single
# late fingerprint would have missed. A change made and undone entirely inside the backend's
# own run is not guaranteed to be seen by either, as the fingerprint's own note says.
tree_fingerprint "$TREE_ABS" > "$OUT_ABS/tree-at-return.sha256"
if cmp -s "$OUT_ABS/tree-before.sha256" "$OUT_ABS/tree-at-return.sha256"; then
  tree_verdict="the tree was unchanged when the backend returned"
else
  tree_verdict="THE TREE HAD CHANGED when the backend returned"
fi

# --- what the run must have produced ----------------------------------------------------

# A backend that is missing, unauthenticated or out of credit exits non-zero or says
# nothing. Either way the review did not happen, so say so instead of reporting a pass.
# The trace itself is not quoted here: it can hold credential details, and a message goes
# wherever the caller's log goes.
if [ "$run_status" -ne 0 ]; then
  refuse E_RUN_FAILED "the $BACKEND backend exited $run_status and no review was produced. Read the last lines of $OUT_ABS/review.err yourself with tail, and do not paste them into a pull request, an issue or Slack."
fi

reported_models=''
confinement=''
case "$BACKEND" in
  codex)
    # Read only codex's own preamble, the block between the first two rules. codex prints
    # it before it echoes the brief, so the first block is always its own. Both rules must
    # be there: with only one, the block would run to the end of the trace and a brief that
    # quotes a preamble -- as a brief reviewing this very script does -- could supply these
    # values itself. Anchored, so only a whole line of exactly eight hyphens counts.
    # Only the part before codex's own "user" marker counts, which is the line it prints
    # straight after its preamble, before echoing the brief. Counting rules over the whole
    # trace was not enough: one real rule plus a rule in the echoed brief also counts two,
    # and the first block would then run into the brief, which could supply these values
    # itself. The marker must be there: without it, "before the marker" is the whole trace
    # and the same brief-supplied block would be believed again.
    # The marker has to be codex's own, not a line of the echoed brief that reads "user".
    # codex echoes what it was given immediately after its marker, so the line after the
    # first marker must be the nonce this run prepended to that input. Authenticating
    # against the brief's own first line was not enough: a brief whose first line is
    # "model: ..." satisfies the comparison while also supplying the parsed fields, so a
    # truncated trace could still be read as a preamble. The nonce is generated per run
    # and is not in anything the author wrote, so the input cannot contain it in advance.
    echoed_first=$(awk '/^user$/ { if (getline > 0) print; exit }' "$OUT_ABS/review.err")
    grep -qx 'user' "$OUT_ABS/review.err" || refuse E_NO_PREAMBLE \
      "codex's trace has no 'user' marker, so where its own preamble ends and the echoed input begins cannot be told apart, and the mode it ran in cannot be read from it. Check $OUT_ABS/review.err with tail."
    [ "$echoed_first" = "$NONCE_LINE" ] || refuse E_NO_PREAMBLE \
      "the line after the 'user' marker in codex's trace is not this run's nonce, so that marker is not codex's own and everything before it may be the echoed input rather than codex's preamble. Check $OUT_ABS/review.err with tail."
    awk '/^user$/ { exit } { print }' "$OUT_ABS/review.err" > "$OUT_ABS/pre-user.txt"
    rules=$(grep -c '^--------$' "$OUT_ABS/pre-user.txt" || true)
    [ "${rules:-0}" -ge 2 ] || refuse E_NO_PREAMBLE \
      "codex's trace has ${rules:-0} preamble rule(s) before its 'user' marker, not the two that delimit its own preamble, so the mode it ran in cannot be read from it. Check $OUT_ABS/review.err with tail."
    awk '/^--------$/ { n++; next } n == 1' "$OUT_ABS/pre-user.txt" > "$OUT_ABS/preamble.txt"
    reported_models=$(sed -n 's/^model: //p' "$OUT_ABS/preamble.txt" | head -1)
    sandbox_mode=$(sed -n 's/^sandbox: //p' "$OUT_ABS/preamble.txt" | head -1)
    approval_mode=$(sed -n 's/^approval: //p' "$OUT_ABS/preamble.txt" | head -1)
    [ "$sandbox_mode" = read-only ] || refuse E_NOT_READ_ONLY \
      "codex reported its sandbox as '${sandbox_mode:-(not reported)}', not read-only; a reviewer that can edit the tree is not a reviewer. This is read from codex's own preamble after it ran, so the run happened: $tree_verdict."
    # Read-only is only read-only while nothing can approve an escalation out of it.
    [ "$approval_mode" = never ] || refuse E_APPROVAL_ESCALATION \
      "codex reported its approval policy as '${approval_mode:-(not reported)}', not never; it can ask to write and a host that answers the ask by itself will let it. This is read from codex's own preamble after it ran, so the run happened: $tree_verdict."
    confinement="codex reported sandbox=read-only, approvals=never"
    ;;
  claude)
    # One pass over the record, refusing a shape this cannot read rather than guessing:
    # a string-valued modelUsage would otherwise be split into its characters, and a
    # non-object record would end the script with no tagged reason.
    python3 -I -c '
import json, sys

path, out = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        d = json.load(f)
except Exception as e:
    print("BAD\tcould not read it as JSON: %s" % e)
    raise SystemExit(0)
if not isinstance(d, dict):
    print("BAD\tthe record is a %s, not an object" % type(d).__name__)
    raise SystemExit(0)
if d.get("is_error"):
    # Independent of the error check earlier: a failed run must never be recorded as a
    # review, even if that check were bypassed or failed to run. While that check works
    # this branch is unreachable, so no test covers it -- it is deliberate redundancy
    # after that check once failed open, not dead code. Do not remove it for being
    # untested; that would put the whole weight back on one check.
    print("BAD\tthe record is flagged is_error, so the backend did not produce a review")
    raise SystemExit(0)
usage = d.get("modelUsage")
if not isinstance(usage, dict) or not usage:
    print("BAD\tmodelUsage is %s, not a non-empty object of model names"
          % json.dumps(usage))
    raise SystemExit(0)
if not all(isinstance(k, str) and k.strip() for k in usage):
    print("BAD\tmodelUsage has a name that is not a non-empty string")
    raise SystemExit(0)
# The names come back to the shell as one tab-separated line joined by "+", and then into
# review-record.txt for a person to read. Allow only visible ASCII without "+": naming the
# characters to reject kept missing some -- first the ESC and DEL controls, then the Zl/Zp
# separators and the Cf zero-width and bidirectional overrides, which can make two
# different names look identical or make the record read as something it is not.
# Space is allowed inside a name, because a backend may be pointed at a custom model
# identifier that contains one, and a space is safe in both a tab-separated line and the
# record; a name padded with whitespace is refused, because it would display as another.
allowed = set(chr(c) for c in range(0x20, 0x7F)) - {"+"}
bad = [k for k in usage if not set(k) <= allowed or k != k.strip()]
if bad:
    print("BAD\ta model name holds something other than printable ASCII without '+', "
          "or is padded with whitespace, which this script cannot carry or display "
          "safely: %s" % json.dumps(bad))
    raise SystemExit(0)
denials = d.get("permission_denials")
if not isinstance(denials, list):
    print("BAD\tpermission_denials is %s, not a list" % json.dumps(denials))
    raise SystemExit(0)
result = d.get("result")
if not isinstance(result, str):
    print("BAD\tresult is %s, not a string" % type(result).__name__)
    raise SystemExit(0)
if not result.strip():
    # A blank review would otherwise satisfy "the file is not empty" and be recorded.
    print("BAD\tresult is %d character(s) of whitespace, which is not a review"
          % len(result))
    raise SystemExit(0)
with open(out, "w") as f:
    f.write(result)
print("OK\t%s\t%d" % ("+".join(sorted(usage)), len(denials)))
' "$OUT_ABS/review.json" "$OUT_ABS/review.out" > "$OUT_ABS/record.tsv" || \
      refuse E_BAD_RECORD "could not read the claude backend's JSON record at $OUT_ABS/review.json at all."
    IFS=$'\t' read -r verdict field_a field_b < "$OUT_ABS/record.tsv" || verdict=BAD
    if [ "${verdict:-BAD}" != OK ]; then
      refuse E_BAD_RECORD "the claude backend's JSON record at $OUT_ABS/review.json is not the shape this script can read, so it cannot say which model answered: ${field_a:-no reason given}."
    fi
    reported_models="$field_a"
    # What claude was asked to be, not something it reports back: the proof that it was
    # read-only is the tree fingerprint below, not this line.
    confinement="claude was run with --restricted --strict-mcp-config --tools Read,Grep,Glob (asked to hold only these), and refused $field_b permission request(s)"
    ;;
esac

[ -s "$OUT_ABS/review.out" ] || refuse E_EMPTY \
  "the $BACKEND backend exited 0 but wrote no review to $OUT_ABS/review.out. Check $OUT_ABS/review.err with tail."

# Never let the requested model stand in for the model that answered: a backend can route
# an alias ("opus", a prompt router) to something else, including the implementer's model.
[ -n "$reported_models" ] || refuse E_NO_MODEL_REPORTED \
  "the $BACKEND backend did not report which model answered, so this run cannot be recorded as a review by a different model."

# The requested model may be an alias, so apply the principle to what actually answered.
# Split on "+" through an array: an unquoted expansion would let a name holding a bracket,
# such as "claude-opus-5-5[1m]", be read as a glob and silently become a filename.
# Only the claude backend joins several names with "+"; codex reports exactly one, and
# splitting it would drop a trailing "+" (bash discards the empty last field), so a model
# literally named "x+" would compare unequal to an implementer of the same name.
if [ "$BACKEND" = claude ]; then
  IFS='+' read -r -a answered_models <<< "$reported_models"
else
  answered_models=("$reported_models")
fi
for m in "${answered_models[@]}"; do
  check_model_charset "$m" "the model the $BACKEND backend reported,"
  got=$(normalise_model "$m")
  check_model_name "$m" "$got" "the model the $BACKEND backend reported,"
  [ "$got" != "$impl_model" ] || refuse E_REPORTED_SAME_MODEL \
    "'$MODEL' was answered by '$m', which is the model that wrote the change ('$IMPLEMENTER'). Ask for a different model."
done

# Both fingerprints must match the one taken before the run, and each of the three ways
# they can differ gets its own message:
#
#   before == after, before != at-return   a change that was put back afterwards
#   before != after, before == at-return    a change made after the backend returned
#   before != after, before != at-return    a change made while the reviewer ran
#
# The "put back afterwards" case is tested first, because it is the one a single late
# fingerprint would have passed: on its own, "after" matches, and the run would have been
# recorded as clean. A change made and undone entirely inside the backend's own run is
# not guaranteed to be seen by either, as tree_fingerprint's own note says.
tree_fingerprint "$TREE_ABS" > "$OUT_ABS/tree-after.sha256"
if cmp -s "$OUT_ABS/tree-before.sha256" "$OUT_ABS/tree-after.sha256" \
   && ! cmp -s "$OUT_ABS/tree-before.sha256" "$OUT_ABS/tree-at-return.sha256"; then
  refuse E_TREE_RESTORED \
    "the tree at $TREE_ABS differed from its fingerprint when the backend returned, and matches again now: a change that was put back afterwards is still a change, and the reviewer was not read-only. Compare $OUT_ABS/tree-before.sha256 with tree-at-return.sha256."
fi
if ! cmp -s "$OUT_ABS/tree-before.sha256" "$OUT_ABS/tree-after.sha256"; then
  if cmp -s "$OUT_ABS/tree-before.sha256" "$OUT_ABS/tree-at-return.sha256"; then
    # Matched when the backend returned and differs now, so the change came after the
    # backend's own run -- from a process it left behind, or from something else on the
    # machine. Either way it is a change to the tree under review, so it refuses.
    refuse E_TREE_CHANGED \
      "the tree at $TREE_ABS matched its fingerprint when the backend returned and differs now, so something changed it after the run -- a process the backend left behind, or another one. Compare $OUT_ABS/tree-at-return.sha256 with tree-after.sha256."
  fi
  refuse E_TREE_CHANGED \
    "the tree at $TREE_ABS changed while the reviewer ran, so the reviewer was not read-only. Compare $OUT_ABS/tree-before.sha256 with tree-after.sha256."
fi

# --- the record that goes in the pull request -------------------------------------------

{
  printf 'second review\n'
  printf '  finished        %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '  backend         %s\n' "$BACKEND"
  printf '  command         %s\n' "$resolved_cmd"
  printf '  version         %s\n' "$backend_version"
  printf '  model requested %s\n' "$MODEL"
  printf '  model answered  %s\n' "$reported_models"
  printf '  implementer     %s\n' "$IMPLEMENTER"
  printf '  confinement     %s\n' "$confinement"
  printf '  review tree     unchanged: every path and content hash matches the fingerprint\n'
  printf '                  taken before the run. This says nothing about writes the\n'
  printf '                  reviewer may have made outside %s.\n' "$TREE_ABS"
  printf '  tree            %s\n' "$TREE_ABS"
  printf '  brief           %s\n' "$BRIEF_ABS"
  printf '  review          %s\n' "$OUT_ABS/review.out"
} | tee "$OUT_ABS/review-record.txt"

note "put 'model answered' above in the pull request's Second review section."
