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
#   SECOND_REVIEW_KEEP_AWS_ENV     keep the AWS credentials in the environment when
#                                  running the codex backend. They are removed by
#                                  default, so that a machine holding credentials for
#                                  some other account cannot end up billed for the
#                                  review. Set this to 1 only if your codex authenticates
#                                  to Bedrock with exactly those credentials.
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

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

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
  *)  refuse E_BACKEND "--backend '$BACKEND' is not a backend this script runs; use codex or claude. To use another agent, see AGENTS.md, 'Bringing your own reviewer': run it yourself and show it meets the same three invariants." ;;
esac

[ -n "$MODEL" ] || refuse E_MODEL "--model is required: name the model the reviewer must use."
[ -n "$IMPLEMENTER" ] || refuse E_IMPL_MODEL \
  "--implementer-model is required: a second review means a different model reviewed the change, and this script cannot assert that without the model that wrote it."

# Compare the names the way the backends vary them, so a vendor prefix, a Bedrock
# cross-Region prefix, a version suffix or a context-window suffix cannot hide that two
# names are one model: "us.anthropic.claude-sonnet-5-5:0", "anthropic.claude-sonnet-5-5"
# and "claude-sonnet-5-5" all normalise the same.
normalise_model() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[[:space:]]+//g
              s/\[[^][]*\]$//
              s/^(us|eu|apac|global|us-gov)\.//
              s/^(anthropic|openai|amazon|meta|mistral|cohere|ai21|deepseek|qwen|writer|stability|twelvelabs|luma|nova)\.//
              s/:[0-9]+$//'
}

want_model=$(normalise_model "$MODEL")
impl_model=$(normalise_model "$IMPLEMENTER")
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

# The trace lands in --out and can hold credential details, so --out has to stay in the
# gitignored tmp/. Checked before anything is created, so a refused run leaves nothing
# behind in a tracked folder. -m resolves a path that does not exist yet.
OUT_ABS=$(realpath -m "$OUT")
TMP_ABS=$(realpath -m "$REPO_ROOT/tmp")
case "$OUT_ABS/" in
  "$TMP_ABS"/*) ;;
  *) refuse E_OUT_NOT_TMP \
    "--out '$OUT_ABS' is not under this repository's gitignored tmp/ ('$TMP_ABS'). The backend's trace can hold credential details, and anything in a tracked folder is one 'git add' from being published." ;;
esac

mkdir -p "$OUT_ABS"
TREE_ABS=$(realpath "$TREE")
BRIEF_ABS=$(realpath "$BRIEF")

# This script's own output inside the tree would show up as the tree changing, and read
# as a reviewer that wrote to it. Keep them apart rather than explain the false alarm.
case "$OUT_ABS/" in
  "$TREE_ABS"/*) refuse E_OUT_IN_TREE \
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
tree_fingerprint "$TREE_ABS" > "$OUT_ABS/tree-before.sha256"

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
    # Take the AWS credentials out of the environment unless asked not to, so a machine
    # that holds credentials for another account cannot have the review billed to it: the
    # backend is left with whatever its own configuration pins. Fails closed -- a codex
    # that needed those credentials now cannot authenticate, and says so through
    # E_RUN_FAILED rather than quietly billing someone else.
    aws_env=(env)
    if [ "${SECOND_REVIEW_KEEP_AWS_ENV:-0}" != 1 ]; then
      aws_env=(env -u AWS_PROFILE -u AWS_DEFAULT_PROFILE -u AWS_CONFIG_FILE
               -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN
               -u AWS_BEARER_TOKEN_BEDROCK -u AWS_CREDENTIAL_EXPIRATION
               -u AWS_CONTAINER_CREDENTIALS_FULL_URI
               -u AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
               -u AWS_CONTAINER_AUTHORIZATION_TOKEN
               -u AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE
               -u AWS_WEB_IDENTITY_TOKEN_FILE -u AWS_ROLE_ARN -u AWS_ROLE_SESSION_NAME
               AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true)
    fi
    ${timeout_cmd[@]+"${timeout_cmd[@]}"} "${aws_env[@]}" "$resolved_cmd" "${codex_args[@]}" \
      < "$BRIEF_ABS" > "$OUT_ABS/review.out" 2> "$OUT_ABS/review.err" || run_status=$?
    ;;
  claude)
    # --restricted takes away the tools that run commands or code and ignores the user,
    # project and local settings files, so none of them can hand a write tool back;
    # --strict-mcp-config with no --mcp-config leaves the reviewer no MCP server, which
    # is where the write-capable tools on a configured workstation live;
    # --disallowedTools is the deny list for the rest; and --permission-prompts none
    # means nothing can answer a permission request, so a tool that needs one is refused.
    ( cd "$TREE_ABS" && ${timeout_cmd[@]+"${timeout_cmd[@]}"} "$resolved_cmd" -p \
        --output-format json \
        --model "$MODEL" \
        --restricted \
        --strict-mcp-config \
        --allowedTools "Read,Grep,Glob" \
        --disallowedTools "Edit,Write,NotebookEdit,Bash,BashOutput,KillShell,Task,Agent,WebFetch,WebSearch" \
        --permission-prompts none ) \
      < "$BRIEF_ABS" > "$OUT_ABS/review.json" 2> "$OUT_ABS/review.err" || run_status=$?
    ;;
esac

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
    # Read only codex's own preamble, the block between the first two rules, so a line of
    # the brief echoed back into the trace cannot supply any of these three values.
    # Anchored, and the brief is never inside this block.
    awk '/^-{8}$/ { n++; next } n == 1' "$OUT_ABS/review.err" > "$OUT_ABS/preamble.txt"
    reported_models=$(sed -n 's/^model: //p' "$OUT_ABS/preamble.txt" | head -1)
    sandbox_mode=$(sed -n 's/^sandbox: //p' "$OUT_ABS/preamble.txt" | head -1)
    approval_mode=$(sed -n 's/^approval: //p' "$OUT_ABS/preamble.txt" | head -1)
    [ "$sandbox_mode" = read-only ] || refuse E_NOT_READ_ONLY \
      "codex reported its sandbox as '${sandbox_mode:-(not reported)}', not read-only; a reviewer that can edit the tree is not a reviewer."
    # Read-only is only read-only while nothing can approve an escalation out of it.
    [ "$approval_mode" = never ] || refuse E_APPROVAL_ESCALATION \
      "codex reported its approval policy as '${approval_mode:-(not reported)}', not never; it can ask to write and a host that answers the ask by itself will let it."
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
usage = d.get("modelUsage")
if not isinstance(usage, dict) or not usage:
    print("BAD\tmodelUsage is %s, not a non-empty object of model names"
          % json.dumps(usage))
    raise SystemExit(0)
if not all(isinstance(k, str) and k for k in usage):
    print("BAD\tmodelUsage has a name that is not a non-empty string")
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
    confinement="claude was run with --restricted --strict-mcp-config, tools Read/Grep/Glob, and refused $field_b permission request(s)"
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
IFS='+' read -r -a answered_models <<< "$reported_models"
for m in "${answered_models[@]}"; do
  got=$(normalise_model "$m")
  [ "$got" != "$impl_model" ] || refuse E_REPORTED_SAME_MODEL \
    "'$MODEL' was answered by '$m', which is the model that wrote the change ('$IMPLEMENTER'). Ask for a different model."
done

tree_fingerprint "$TREE_ABS" > "$OUT_ABS/tree-after.sha256"
if ! cmp -s "$OUT_ABS/tree-before.sha256" "$OUT_ABS/tree-after.sha256"; then
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
