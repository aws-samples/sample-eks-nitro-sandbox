#!/usr/bin/env bash
# Run the adversarial second review AGENTS.md requires, keeping its three invariants:
# the reviewer runs on a different model from the one that wrote the change, it cannot
# write to the tree it reviews, and the model that actually answered is recorded.
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

[ -f "$BRIEF" ] || refuse E_BRIEF "no brief at '$BRIEF'. Write one from the second-review skill's assets/review-brief.md."
[ -s "$BRIEF" ] || refuse E_BRIEF "the brief at '$BRIEF' is empty; a reviewer given nothing to check finds nothing."
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
# A --brief at one of the output names would pass its own [ -f ] check and then be removed
# by the loop below, so refuse it rather than delete the thing we were asked to read.
brief_not_an_output_name() {
  case "$(basename -- "$1")" in
    review.out|review.err|review.json|review-record.txt|record.tsv|preamble.txt|\
    pre-user.txt|codex-stdin.txt|tree-before.sha256|tree-at-return.sha256|tree-after.sha256)
      [ "$(dirname -- "$1")" != "$2" ] || refuse E_BRIEF \
        "the brief '$1' has the name of a file this script writes into --out, and would be removed before being read. Rename it." ;;
  esac
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
brief_not_an_output_name "$BRIEF_ABS" "$OUT_ABS"

TREE_ABS=$(realpath "$TREE")

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
# cannot see: a file created and deleted within the run, and any write outside the tree.
# Records are NUL-delimited, and so is the hash list, because a path may legally hold a
# newline or the text " -> ": with line-delimited records two different trees could line
# up to the same fingerprint. cmp compares the bytes, so the delimiter never has to be
# read back.
tree_fingerprint() {
  ( cd "$1" || exit 1
    find . -mindepth 1 -printf '%y %m %s %T@ %p -> %l\0' | LC_ALL=C sort -z
    find . -mindepth 1 -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum -z )
}
mkdir -p "$OUT_ABS"

# Remove anything already sitting at a name this script writes, immediately before the
# first write and after every refusal that can still happen before the backend runs.
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
for _n in review.out review.err review.json review-record.txt record.tsv \
          preamble.txt pre-user.txt codex-stdin.txt \
          tree-before.sha256 tree-at-return.sha256 tree-after.sha256; do
  # A failing rm would otherwise end the script under set -e with rm's own untagged
  # message, so the refusal below could only ever fire after a *successful* removal.
  if ! rm -f -- "$OUT_ABS/$_n" 2>/dev/null || [ -e "$OUT_ABS/$_n" ] || [ -L "$OUT_ABS/$_n" ]; then
    refuse E_OUT_TAINTED \
      "'$OUT_ABS/$_n' is in the way and this script cannot clear it -- a directory at that name, an unwritable --out, or something re-creating it. It cannot write there safely. Use a fresh --out."
  fi
done

tree_fingerprint "$TREE_ABS" > "$OUT_ABS/tree-before.sha256"

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
note "this takes 10 to 25 minutes; review.out is written at the end."

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
    if [ -n "${SECOND_REVIEW_CLAUDE_SETTINGS:-}" ]; then
      [ -f "$SECOND_REVIEW_CLAUDE_SETTINGS" ] || refuse E_CLAUDE_SETTINGS \
        "\$SECOND_REVIEW_CLAUDE_SETTINGS names '$SECOND_REVIEW_CLAUDE_SETTINGS', which is not a file."
      claude_settings_abs=$(realpath "$SECOND_REVIEW_CLAUDE_SETTINGS") || refuse E_CLAUDE_SETTINGS \
        "could not resolve \$SECOND_REVIEW_CLAUDE_SETTINGS '$SECOND_REVIEW_CLAUDE_SETTINGS'."
      settings_verdict=$(python3 -c '
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
      claude_args+=(--settings "$claude_settings_abs")
    fi
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
    if [ -n "${SECOND_REVIEW_CONTEXT_DIR:-}" ]; then
      [ -d "$SECOND_REVIEW_CONTEXT_DIR" ] || refuse E_CONTEXT_DIR \
        "\$SECOND_REVIEW_CONTEXT_DIR names '$SECOND_REVIEW_CONTEXT_DIR', which is not a directory."
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
      claude_args+=(--add-dir "$context_abs")
    fi
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
      claude_status=$(python3 -c '
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
# own run is invisible to both, as the fingerprint's own note says.
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
    python3 -c '
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

# Both fingerprints must match the one taken before the run, and the later one is tested
# first, and each of the three outcomes has its own message: changed during the run,
# changed after it returned, or put back afterwards. Testing the early one
# first said "it matches again now" even when it did not. A mismatch in both is a change
# during the run, while a
# mismatch only at return means a change that was put back afterwards. Testing the early one
# first said "it matches again now" even when it did not.
tree_fingerprint "$TREE_ABS" > "$OUT_ABS/tree-after.sha256"
if cmp -s "$OUT_ABS/tree-before.sha256" "$OUT_ABS/tree-after.sha256" \
   && ! cmp -s "$OUT_ABS/tree-before.sha256" "$OUT_ABS/tree-at-return.sha256"; then
  refuse E_TREE_RESTORED \
    "the tree at $TREE_ABS differed from its fingerprint when the backend returned, and matches again now: a change that was put back afterwards is still a change, and the reviewer was not read-only. Compare $OUT_ABS/tree-before.sha256 with tree-at-return.sha256."
fi
if ! cmp -s "$OUT_ABS/tree-before.sha256" "$OUT_ABS/tree-after.sha256"; then
  if cmp -s "$OUT_ABS/tree-before.sha256" "$OUT_ABS/tree-at-return.sha256"; then
    # Matched when the backend returned and differs now: the change came afterwards, from
    # something the backend left running or from another process, not from the run itself.
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
