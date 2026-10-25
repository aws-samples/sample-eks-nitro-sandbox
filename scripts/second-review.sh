#!/usr/bin/env bash
# Run the second review AGENTS.md requires: a reviewer that cannot edit the tree, on a
# model that is not the one that wrote the change.
#
# Usage: scripts/second-review.sh --backend codex|claude --model <id>
#                                 --implementer-model <id>
#                                 [--brief FILE] [--tree DIR] [--out DIR]
#                                 [--timeout SECONDS]
#
#   --backend            codex or claude.
#   --model              the model the reviewer should use, as that backend names it
#                        ("openai.gpt-5.6-sol", "opus", "claude-opus-5-5").
#   --implementer-model  the model that wrote the change under review, resolved, not an
#                        alias or a router name. The whole point of a second review is
#                        that a different model does it, so this script refuses to run,
#                        and refuses its own result, when the two are the same.
#   --brief              the brief, on standard input to the reviewer. Default
#                        tmp/review/brief.md.
#   --tree               the snapshot of the commit under review. Default
#                        tmp/review/tree.
#   --out                where the brief's output, the backend's trace and the record of
#                        the run go. Default tmp/review.
#   --timeout            seconds to let the reviewer run. Default 5400 (90 minutes).
#
# Which command each backend runs comes from the environment, so this script works on a
# laptop where the collaborator authenticated the backend themselves, and on a shared
# workstation where a wrapper decides which account the review bills:
#
#   SECOND_REVIEW_CODEX_CMD        the codex command. Default "codex".
#   SECOND_REVIEW_CLAUDE_CMD       the claude command. Default "claude".
#   SECOND_REVIEW_CODEX_PROVIDER   optional, passed as codex's model_provider.
#   SECOND_REVIEW_CODEX_EFFORT     optional, passed as codex's model_reasoning_effort.
#
# Everything this writes goes under --out, which belongs under the repository's tmp/.
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
  *)  refuse E_BACKEND "--backend '$BACKEND' is not a backend this script runs; use codex or claude." ;;
esac

[ -n "$MODEL" ] || refuse E_MODEL "--model is required: name the model the reviewer must use."
[ -n "$IMPLEMENTER" ] || refuse E_IMPL_MODEL \
  "--implementer-model is required: a second review means a different model reviewed the change, and this script cannot assert that without the model that wrote it."

# Compare the names the way the backends vary them, so a Bedrock cross-Region prefix, a
# version suffix or a context-window suffix cannot hide that the two models are the same:
# "us.anthropic.claude-sonnet-5-5:0" and "anthropic.claude-sonnet-5-5" are one model.
normalise_model() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[[:space:]]+//g; s/\[[^][]*\]$//; s/^(us|eu|apac|global|us-gov)\.//; s/:[0-9]+$//'
}

want_model=$(normalise_model "$MODEL")
impl_model=$(normalise_model "$IMPLEMENTER")
[ "$want_model" != "$impl_model" ] || refuse E_SAME_MODEL \
  "the reviewer model and the implementer model are the same ('$MODEL' and '$IMPLEMENTER' both normalise to '$want_model'). A second review has to be done by a different model than the one that wrote the change."

# --- what the run needs to exist --------------------------------------------------------

[ -f "$BRIEF" ] || refuse E_BRIEF "no brief at '$BRIEF'. Write one from the second-review skill's assets/review-brief.md."
[ -s "$BRIEF" ] || refuse E_BRIEF "the brief at '$BRIEF' is empty; a reviewer given nothing to check finds nothing."
[ -d "$TREE" ] || refuse E_TREE "no tree to review at '$TREE'. Extract the commit there first ('git archive <commit> | tar -x -C $TREE')."

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

mkdir -p "$OUT"
OUT_ABS=$(cd "$OUT" && pwd)
TREE_ABS=$(cd "$TREE" && pwd)
BRIEF_ABS=$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")

# This script's own output inside the tree would show up as the tree changing, and read
# as a reviewer that wrote to it. Keep them apart rather than explain the false alarm.
case "$OUT_ABS/" in
  "$TREE_ABS"/*) refuse E_OUT_IN_TREE \
    "--out '$OUT_ABS' is inside the tree under review '$TREE_ABS'; this script's own files would read as the reviewer changing the tree. Put --out beside the tree, under the repository's tmp/." ;;
esac

# A reviewer must not be able to change what it reviews. The backend is told to run
# read-only, and this is the check that it did: the tree is fingerprinted before and
# after, and a single added, removed or edited file fails the run.
tree_fingerprint() {
  ( cd "$1" && find . -mindepth 1 -type f -print0 | LC_ALL=C sort -z \
      | xargs -0 -r sha256sum
    cd "$1" && find . -mindepth 1 ! -type f -printf '%y %p\n' | LC_ALL=C sort )
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
    ${timeout_cmd[@]+"${timeout_cmd[@]}"} "$resolved_cmd" "${codex_args[@]}" \
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
if [ "$run_status" -ne 0 ]; then
  refuse E_RUN_FAILED "the $BACKEND backend exited $run_status and no review was produced. Its last lines of trace, from $OUT_ABS/review.err (never paste this into a pull request, an issue or Slack):
$(tail -5 "$OUT_ABS/review.err" 2>/dev/null || true)"
fi

reported_models=''
sandbox_mode=''
approval_mode=''
case "$BACKEND" in
  codex)
    # Anchored, so no pattern can match the brief quoted back in the trace.
    reported_models=$(sed -n 's/^model: //p' "$OUT_ABS/review.err" | head -1)
    sandbox_mode=$(sed -n 's/^sandbox: //p' "$OUT_ABS/review.err" | head -1)
    approval_mode=$(sed -n 's/^approval: //p' "$OUT_ABS/review.err" | head -1)
    ;;
  claude)
    reported_models=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print("+".join(sorted(d.get("modelUsage") or {})))
' "$OUT_ABS/review.json")
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
open(sys.argv[2], "w").write(d.get("result") or "")
' "$OUT_ABS/review.json" "$OUT_ABS/review.out" 2>/dev/null || : > "$OUT_ABS/review.out"
    denials=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("unknown"); sys.exit(0)
print(len(d.get("permission_denials") or []))
' "$OUT_ABS/review.json")
    sandbox_mode="read-only (tools allowed: Read, Grep, Glob; permission requests refused: $denials)"
    ;;
esac

[ -s "$OUT_ABS/review.out" ] || refuse E_EMPTY \
  "the $BACKEND backend exited 0 but wrote no review to $OUT_ABS/review.out. Check $OUT_ABS/review.err with tail."

# Never let the requested model stand in for the model that answered: a backend can route
# an alias ("opus", a prompt router) to something else, including the implementer's model.
[ -n "$reported_models" ] || refuse E_NO_MODEL_REPORTED \
  "the $BACKEND backend did not report which model answered, so this run cannot be recorded as a review by a different model."

if [ "$BACKEND" = codex ]; then
  [ "$sandbox_mode" = read-only ] || refuse E_NOT_READ_ONLY \
    "codex reported its sandbox as '$sandbox_mode', not read-only; a reviewer that can edit the tree is not a reviewer."
  # Read-only is only read-only while nothing can approve an escalation out of it.
  [ "$approval_mode" = never ] || refuse E_APPROVAL_ESCALATION \
    "codex reported its approval policy as '$approval_mode', not never; it can ask to write and a host that answers the ask by itself will let it."
  sandbox_mode="$sandbox_mode, approvals $approval_mode"
fi

# The requested model may be an alias, so apply the principle to what actually answered.
for m in ${reported_models//+/ }; do
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
  printf '  reviewer write  none: %s; the tree fingerprint is unchanged\n' "$sandbox_mode"
  printf '  tree            %s\n' "$TREE_ABS"
  printf '  brief           %s\n' "$BRIEF_ABS"
  printf '  review          %s\n' "$OUT_ABS/review.out"
} | tee "$OUT_ABS/review-record.txt"

note "put 'model answered' above in the pull request's Second review section."
