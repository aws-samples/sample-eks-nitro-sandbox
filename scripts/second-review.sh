#!/usr/bin/env bash
# Run the adversarial second review AGENTS.md requires, and capture what a reader of the
# pull request cannot otherwise check:
#
#   1. the reviewer runs on a different model from the one that wrote the change;
#   2. the thing under review did not change, and that is shown -- the tree is fingerprinted
#      before the run, when the backend returns, and after, and any difference the
#      fingerprint can see (type, mode, size, mtime, symlink target, content, for every
#      path including the tree's own root) fails the run. What it does NOT see: ownership,
#      ACLs, extended attributes, hard-link count, or anything else find's -printf does not
#      report (a hard link made to a file inside the tree, from outside it, changes nothing
#      this fingerprint can see); and a change whose every tracked attribute, including
#      mtime, is put back to match leaves nothing else to catch it either;
#   3. the model that actually answered is recorded, read from the backend's own report
#      rather than from the name that was asked for.
#
# What this script does NOT do, deliberately (issue #100): it does not confine the reviewer.
# A reviewer that cannot run anything cannot find the class of defect that only shows up
# when you execute the thing -- which is where the two most serious findings against this
# very script came from -- so the reviewer is given write and execute in a workspace of its
# own, and invariant 2 is carried by the fingerprint afterwards instead of by a sandbox flag
# beforehand. Read that precisely: the reviewer *can* write to the tree it reviews. If it
# does, this script fails the run and no review is recorded, but the write will have
# happened. Nothing here bounds what it writes outside the tree at all.
#
# Everything else the review needs -- where to put its output, what not to read, what to
# leave alone -- is asked for in the brief rather than enforced here. The brief template is
# .agents/skills/second-review/assets/review-brief.md.
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
#                        alias or a router name. The script refuses to run, and refuses its
#                        own result, when this and --model are the same model. Where the
#                        implementer was itself behind a prompt router, this comparison
#                        establishes nothing on its own: see AGENTS.md, "Running it".
#   --brief              the brief, given to the reviewer on standard input. Default
#                        tmp/review/brief.md.
#   --tree               the snapshot of the commit under review, never your working tree.
#                        Default tmp/review/tree.
#   --out                where the review, the backend's trace and the run's record go. Use
#                        a fresh directory per run: this script overwrites the names it
#                        writes and does not otherwise clear or guard the directory. Keep it
#                        under the repository's gitignored tmp/ -- the trace can hold
#                        credential details -- which is now a rule for you to follow rather
#                        than one this script checks. Default tmp/review.
#   --timeout            seconds to let the reviewer run. Default 5400 (90 minutes).
#
# Environment:
#   SECOND_REVIEW_CODEX_CMD        the codex command. Default "codex".
#   SECOND_REVIEW_CLAUDE_CMD       the claude command. Default "claude".
#   SECOND_REVIEW_CODEX_PROVIDER   optional, passed as codex's model_provider.
#   SECOND_REVIEW_CODEX_EFFORT     optional, passed as codex's model_reasoning_effort.
#   SECOND_REVIEW_CONTEXT_DIR      optional, a directory added as readable for the claude
#                                  backend, which otherwise sees only the tree and its own
#                                  workspace. Put the commit's diff there. Point it at a
#                                  directory holding only what the reviewer may read: that
#                                  is now your judgement, not a check here.
#   SECOND_REVIEW_CLAUDE_SETTINGS  optional, a settings file passed to claude as --settings,
#                                  needed when your claude authenticates through a setting
#                                  (awsCredentialExport, apiKeyHelper), because --restricted
#                                  makes claude ignore the user settings file. Its contents
#                                  are no longer checked: the reviewer holds Bash anyway, so
#                                  an allowlist that stopped a hooks entry executing would be
#                                  defending a property this script no longer holds.
#   SECOND_REVIEW_KEEP_AWS_ENV     keep AWS credential variables in the environment for the
#                                  codex backend. They are removed by default so that a
#                                  machine holding credentials for some other account is not
#                                  billed for the review. Set to 1 only if your codex
#                                  authenticates to Bedrock with exactly those credentials.
#
# The backend's trace (review.err) can hold credential details: read it with tail or a
# targeted search, and never paste it into a pull request, an issue or Slack.
#
# Exit status: 0 the review ran and its record is complete; 1 this script refused the run
# or refused its result; 2 it could not check (a tool it needs is missing).
set -euo pipefail

usage() { awk 'NR>1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; }

# Each refusal carries a stable tag, named in AGENTS.md, so a report can name exactly which
# check stopped the run.
refuse() { printf 'second-review: %s: %s\n' "$1" "$2" >&2; exit 1; }
cannot_check() { printf 'second-review: E_NO_TOOL: %s\n' "$1" >&2; exit 2; }
note() { printf 'second-review: %s\n' "$1"; }

command -v realpath >/dev/null 2>&1 || cannot_check "realpath is needed to resolve the tree and output paths."

BACKEND='' MODEL='' IMPLEMENTER='' BRIEF='tmp/review/brief.md' TREE='tmp/review/tree'
OUT='tmp/review' TIMEOUT=5400

# Take the value of an option, refusing when it was given without one: "--model" at the end
# of the line must not leave the model empty and fall through to a later check.
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

# --- invariant 1: a different model ------------------------------------------------------

case "$BACKEND" in
  codex|claude) ;;
  '') refuse E_BACKEND "--backend is required, and must be codex or claude." ;;
  *)  refuse E_BACKEND "--backend '$BACKEND' is not a backend this script runs; use codex or claude. A sub agent in your own session is a third sanctioned way -- see AGENTS.md, 'The adversarial second reviewer' -- and must meet the same three invariants itself." ;;
esac

[ -n "$MODEL" ] || refuse E_MODEL "--model is required: name the model the reviewer must use."
[ -n "$IMPLEMENTER" ] || refuse E_IMPL_MODEL \
  "--implementer-model is required: a second review means a different model reviewed the change, and this script cannot assert that without the model that wrote it."

# Normalise away a vendor prefix, a Bedrock cross-Region prefix, a version suffix and a
# context-window suffix, so "us.anthropic.claude-sonnet-5-5:0" and "claude-sonnet-5-5"
# compare equal without collapsing genuinely different names.
# Does NOT strip internal whitespace: check_model_charset (always called on the input
# before this) allows a model name to hold a space -- a backend may be pointed at a custom
# model identifier that contains one -- and already refuses a leading or trailing one.
# Second-review finding (issue #100 round 3): this used to "tr -d '[:space:]'", so a
# reported name "a b" normalised to "ab" and was compared equal to an implementer "ab",
# refusing a review by a genuinely different-looking model as E_REPORTED_SAME_MODEL.
normalise_model() {
  local m
  m=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  m=$(printf '%s' "$m" | sed -E 's/^(us|eu|apac|global|us-gov)\.//')
  m=$(printf '%s' "$m" | sed -E 's/^(anthropic|openai|amazon|meta|mistral|cohere|ai21|deepseek|qwen|writer|stability|twelvelabs|luma)\.//')
  m=$(printf '%s' "$m" | sed -E 's/\[[^][]*\]:[0-9]+$//; t
                                  s/:[0-9]+\[[^][]*\]$//; t
                                  s/\[[^][]*\]$//; t
                                  s/:[0-9]+$//')
  # Bedrock's own model-ID spelling, e.g. "anthropic.claude-sonnet-4-5-20250929-v1:0", adds
  # two more things the API name ("claude-sonnet-4-5-20250929" or "claude-sonnet-4-5") never
  # has: a "-vN" revision and a release date. Second-review finding (issue #100 round 6):
  # left unstripped, the same underlying model named the Bedrock way on one side and the API
  # way on the other normalised to two different strings and passed both the same-model and
  # the reported-same-model refusal -- the unsafe direction, since the whole point of this
  # comparison is to catch exactly that pairing. Strip both, in this order (the "-vN" is
  # closer to the end once the Region/vendor/version-suffix stripping above has already run).
  # Stripping the date also makes two genuinely different dated snapshots compare equal,
  # which fails closed (a false "same model" refusal) rather than open, so it is the
  # direction to err in here.
  m=$(printf '%s' "$m" | sed -E 's/-v[0-9]+$//')
  m=$(printf '%s' "$m" | sed -E 's/-[0-9]{8}$//')
  printf '%s' "$m"
}

# Every model name ends up in review-record.txt for a person to read, so it must be a single
# printable-ASCII line with no leading or trailing space: a tab, a newline or an ESC in one
# could forge or alter a field of that record.
check_model_charset() {
  local LC_ALL=C
  case "$1" in
    "" ) return 0 ;;                       # emptiness is check_model_name's business
    " "*|*" " ) refuse E_MODEL_NAME \
      "$2 '$1' begins or ends with a space, so it would be recorded as a different name than the one that answered." ;;
    *[![:print:]]*) refuse E_MODEL_NAME \
      "$2 holds a character that is not printable ASCII, which cannot be carried or recorded safely." ;;
  esac
}

# A name that is nothing but a prefix ("amazon.") normalises to the empty string, and two
# empty strings would compare equal while an empty and a real one would compare different.
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
  codex)  BACKEND_CMD="${SECOND_REVIEW_CODEX_CMD:-codex}"  BACKEND_ENV=SECOND_REVIEW_CODEX_CMD ;;
  claude) BACKEND_CMD="${SECOND_REVIEW_CLAUDE_CMD:-claude}" BACKEND_ENV=SECOND_REVIEW_CLAUDE_CMD ;;
esac
resolved_cmd=$(command -v -- "$BACKEND_CMD" 2>/dev/null) || resolved_cmd=''
[ -n "$resolved_cmd" ] && [ -x "$resolved_cmd" ] || refuse E_CMD_MISSING \
  "cannot run the $BACKEND backend: '$BACKEND_CMD' is not an executable command. Install it, or name the command to use in \$$BACKEND_ENV."

command -v python3 >/dev/null 2>&1 || cannot_check "python3 is needed to read the backend's record of which model answered."
command -v sha256sum >/dev/null 2>&1 || cannot_check "sha256sum is needed to show the tree did not change."
command -v cmp >/dev/null 2>&1 || cannot_check "cmp is needed to compare the tree's fingerprints."

[ -f "$BRIEF" ] || refuse E_BRIEF "no brief at '$BRIEF'. Write one from the second-review skill's assets/review-brief.md."
[ -s "$BRIEF" ] || refuse E_BRIEF "the brief at '$BRIEF' is empty; a reviewer given nothing to check finds nothing."
# Readable, not merely present and non-empty: -f and -s both pass for a mode-000 file, and
# the reviewer is given the brief on standard input, so an unreadable one would otherwise
# fail far later and be misreported as the backend's fault.
[ -r "$BRIEF" ] || refuse E_BRIEF "the brief at '$BRIEF' cannot be read (check its permissions); the reviewer is given it on standard input."
[ -d "$TREE" ] || refuse E_TREE "no tree to review at '$TREE'. Extract the commit there first ('git archive <commit> | tar -x -C $TREE')."

BRIEF_ABS=$(realpath "$BRIEF")
TREE_ABS=$(realpath "$TREE")
# Resolved with -m, which does not require --out to exist yet, and checked for containment
# in the tree BEFORE anything creates it. Second-review finding (issue #100 round 5): doing
# "mkdir -p" first and checking after meant a --out given as a not-yet-existing path inside
# the tree was created -- mutating the tree under review -- and only then refused, leaving
# the directory behind: a refusal with a side effect, in the one script whose whole point is
# that nothing side-effects the tree.
OUT_ABS=$(realpath -m "$OUT")

# --out must sit outside the tree. This is not confinement -- nothing here stops the
# reviewer writing -- it is what keeps the evidence readable: this script's own output
# landing inside the tree would show up as the tree changing and be indistinguishable from
# the reviewer having changed it. With the fingerprint now carrying invariant 2 on its own,
# that matters more than it did when a sandbox flag was also in the way.
tree_prefix="${TREE_ABS%/}/"
case "$OUT_ABS/" in
  "$tree_prefix"*) refuse E_OUT_IN_TREE \
    "--out '$OUT_ABS' is inside the tree under review '$TREE_ABS'; this script's own files would read as the tree changing. Put --out beside the tree, not in it." ;;
esac
mkdir -p "$OUT_ABS"

# Resolved here, before any fingerprint is taken, and only for claude: Codex reads an
# absolute path anywhere regardless of SECOND_REVIEW_CONTEXT_DIR, which does nothing for
# it. Second-review finding (issue #100 round 6): --add-dir grants claude's file tools
# WRITE as well as read, so once the earlier finding gave claude a real write grant, the
# context directory became a third thing invariant 2 had to cover and did not -- the
# reviewer's own main input (typically the commit's diff) could change with nothing
# noticing. Fingerprinted alongside the tree at all three checkpoints below.
CTX_ABS=''
if [ "$BACKEND" = claude ] && [ -n "${SECOND_REVIEW_CONTEXT_DIR:-}" ]; then
  [ -d "$SECOND_REVIEW_CONTEXT_DIR" ] || refuse E_CONTEXT_DIR \
    "\$SECOND_REVIEW_CONTEXT_DIR names '$SECOND_REVIEW_CONTEXT_DIR', which is not a directory."
  CTX_ABS=$(realpath "$SECOND_REVIEW_CONTEXT_DIR")
  # Second-review finding (issue #100 round 7): with no check here, --out equal to or
  # nested inside the context directory meant this script's own output (review.out,
  # review.err, review-record.txt, the fingerprints themselves) landed inside what gets
  # fingerprinted as the context directory, so the run always reported E_CONTEXT_CHANGED
  # and wrongly blamed the reviewer. Checked before any fingerprint is taken, mirroring the
  # --out-inside-the-tree check below -- but that check comes after this one, because OUT_ABS
  # is already resolved by the time this runs and testing it here is just as cheap.
  ctx_prefix="${CTX_ABS%/}/"
  case "$OUT_ABS/" in
    "$ctx_prefix"*) refuse E_CONTEXT_DIR \
      "--out '$OUT_ABS' is inside \$SECOND_REVIEW_CONTEXT_DIR '$CTX_ABS'; this script's own files would read as the context directory changing. Put --out outside it." ;;
  esac
fi

# --- invariant 2: the tree did not change, and here is the evidence ---------------------

# Every path's type, mode, size, modification time and symlink target, and every regular
# file's content hash. This is now the whole of invariant 2: the reviewer is not prevented
# from writing to the tree, so this is what shows whether it did.
#
# What it is not guaranteed to see, stated plainly because nothing else backs the claim up:
# ownership, ACLs, extended attributes, hard-link count, and anything else find's -printf
# below does not report (a hard link made from outside the tree to a file inside it changes
# none of what is tracked here -- verified in a second-review round); a file created and
# deleted inside the run where the directory that held it has every tracked attribute,
# including its mtime, put back before the run ends; and any write anywhere outside the
# tree, which is not looked at at all. The root directory's own metadata IS included
# (-mindepth 0, below): an earlier version excluded it, and a stub both changing the root's
# mode and creating-and-deleting a file directly in it went uncaught, because the one
# directory whose mtime would have shown it was the one the fingerprint skipped.
#
# Records are NUL-delimited: a path may legally hold a newline or " -> ", and with
# line-delimited records two different trees could line up to the same fingerprint.
# The first pipeline carries its own "|| exit 1" rather than relying on set -e, because this
# function is also called from an "if" condition, where set -e is off for the whole call.
tree_fingerprint() {
  ( cd "$1" || exit 1
    { find . -mindepth 0 -printf '%y %m %s %T@ %p -> %l\0' | LC_ALL=C sort -z; } || exit 1
    find . -mindepth 0 -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum -z )
}

# Read the tree once before the run proper, so that a tree which cannot be read is reported
# as the input mistake it is (a mistyped --tree, a file with no read permission) rather than
# surfacing later as a failure to write the baseline.
tree_fingerprint "$TREE_ABS" > /dev/null 2>&1 || refuse E_TREE \
  "the tree at '$TREE_ABS' cannot be fully read, so it cannot be fingerprinted: check it exists and that every file and directory in it is readable."

tree_fingerprint "$TREE_ABS" > "$OUT_ABS/tree-before.sha256"
if [ -n "$CTX_ABS" ]; then
  tree_fingerprint "$CTX_ABS" > "$OUT_ABS/ctx-before.sha256" || refuse E_CONTEXT_DIR \
    "\$SECOND_REVIEW_CONTEXT_DIR '$CTX_ABS' cannot be fully read, so it cannot be fingerprinted."
fi

# A short, per-run line the brief cannot already contain, used to authenticate the preamble
# boundary in codex's trace below. Kept deliberately (maintainer ruling on issue #100): the
# preamble is still where the model name is read on the codex path, and without the boundary
# check a brief holding a line "model: <implementer>" supplies the value this script records
# -- which is exactly how it was found, because a brief reviewing this script quotes
# preambles naturally. bash's own RANDOM is enough, since the brief is written before the run.
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
note "the reviewer may write and run commands; the tree is fingerprinted before and after."
note "this usually takes 10 to 25 minutes, less for a tightly scoped brief; review.out is written at the end."

run_status=0
permissions=''
case "$BACKEND" in
  codex)
    # workspace-write, not read-only: the reviewer is meant to be able to run the thing it
    # is reviewing. approval_policy=never stays, but it is here for non-interactivity --
    # "codex exec" has no one to answer an escalation prompt, so without it a run can stall
    # or silently refuse -- and NOT as a confinement guard. Nothing below reads the preamble
    # back to check either of them; the tree fingerprint is the evidence now.
    #
    # -C points at a workspace of its own (mktemp -d), NOT the tree, mirroring claude below.
    # Found by actually running it: under --sandbox workspace-write, codex's own sandboxing
    # creates and removes something directly in its CWD on every shell command it runs --
    # even a plain "ls", even when the model writes nothing at all -- which changed the
    # CWD's own mtime every time. Pointed at the tree, that tripped the tree-root check
    # issue #100's first review round added on every substantive run, with zero write from
    # the model. Codex still reads an absolute path anywhere regardless of its CWD, so it
    # reaches the tree exactly as before; the brief names its absolute path.
    codex_cwd=$(mktemp -d) || refuse E_NO_CWD \
      "could not make a workspace for the reviewer, so there is nowhere to run it that is outside the tree."
    codex_args=(exec --skip-git-repo-check --sandbox workspace-write
                -c approval_policy="never" -C "$codex_cwd" -m "$MODEL")
    # An "[ x ] && y" here would end the script under set -e whenever x is false.
    if [ -n "${SECOND_REVIEW_CODEX_PROVIDER:-}" ]; then
      codex_args+=(-c "model_provider=\"$SECOND_REVIEW_CODEX_PROVIDER\"")
    fi
    if [ -n "${SECOND_REVIEW_CODEX_EFFORT:-}" ]; then
      codex_args+=(-c "model_reasoning_effort=\"$SECOND_REVIEW_CODEX_EFFORT\"")
    fi
    codex_args+=(-)
    {
      printf '%s\n' "$NONCE_LINE"
      cat "$BRIEF_ABS"
    } > "$OUT_ABS/codex-stdin.txt"
    # Take the AWS credentials out of the environment unless asked not to, so a machine that
    # holds credentials for another account cannot have the review billed to it: the backend
    # is left with whatever its own configuration pins. This is a denylist of the variables
    # the AWS SDKs are known to read, so it reduces that risk rather than removing it, and a
    # backend whose credentials come from a helper named in its own config file is not
    # covered by it at all. Fails closed: a codex that needed those variables now cannot
    # authenticate, and says so through E_RUN_FAILED.
    aws_env=(env)
    if [ "${SECOND_REVIEW_KEEP_AWS_ENV:-0}" != 1 ]; then
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
    permissions="codex ran with --sandbox workspace-write and approval_policy=never in a workspace of its own ($codex_cwd), with the tree reachable by absolute path (writes and commands permitted; approval_policy is for non-interactivity, not confinement)"
    ${timeout_cmd[@]+"${timeout_cmd[@]}"} "${aws_env[@]}" "$resolved_cmd" "${codex_args[@]}" \
      < "$OUT_ABS/codex-stdin.txt" > "$OUT_ABS/review.out" 2> "$OUT_ABS/review.err" || run_status=$?
    ;;
  claude)
    # --tools names the tools the reviewer HOLDS, and it now includes Edit, Write and Bash:
    # a reviewer that cannot run the thing cannot find the defects that only appear when you
    # do. --restricted stays, but for a different reason than before: it makes claude ignore
    # the user, project and local settings files, which keeps the run reproducible on a
    # configured workstation rather than confining it. --strict-mcp-config with no
    # --mcp-config leaves it no MCP server, which is about not reaching other systems, not
    # about the tree.
    #
    # --allowedTools, matching --tools exactly, is load-bearing and was MISSING until a
    # second-review round caught it by trying to write (issue #100 round 6). Holding a tool
    # is not the same as being allowed to use it: every individual Bash/Edit/Write action
    # still asks for approval, and --permission-prompts none does not mean "approve
    # automatically" -- with nobody able to answer, it means every such action is denied.
    # Confirmed directly: a `touch` in the reviewer's own workspace was refused with
    # --tools alone, and ran once --allowedTools was added. Without this, the claude path
    # never actually held directive 1's write-and-execute grant at all; every claude run
    # before this fix, including an earlier read-only smoke test that never needed to write
    # and so never surfaced it, was silently back to read-only.
    claude_args=(-p --output-format json --model "$MODEL"
                 --restricted
                 --strict-mcp-config
                 --tools "Read,Grep,Glob,Edit,Write,Bash"
                 --allowedTools "Read,Grep,Glob,Edit,Write,Bash"
                 --permission-prompts none)
    # Passed through unchecked, deliberately: the allowlist that used to vet this file
    # existed to stop a hooks entry executing a command, and the reviewer now holds Bash, so
    # it would be guarding a property this script no longer has. Put only the authentication
    # setting in it anyway -- it is read on a machine you own.
    if [ -n "${SECOND_REVIEW_CLAUDE_SETTINGS:-}" ]; then
      [ -f "$SECOND_REVIEW_CLAUDE_SETTINGS" ] || refuse E_CLAUDE_SETTINGS \
        "\$SECOND_REVIEW_CLAUDE_SETTINGS names '$SECOND_REVIEW_CLAUDE_SETTINGS', which is not a file."
      claude_args+=(--settings "$(realpath "$SECOND_REVIEW_CLAUDE_SETTINGS")")
    fi
    # A workspace of its own, outside both the tree and --out. Outside the tree so that
    # writing in order to verify does not by itself fail the run; outside --out because that
    # holds the backend's trace, and the reviewer now holds Bash and could read it.
    claude_cwd=$(mktemp -d) || refuse E_NO_CWD \
      "could not make a workspace for the reviewer, so there is nowhere to run it that is outside the tree and the output directory."
    claude_args+=(--add-dir "$TREE_ABS")
    # The brief usually points at the commit's diff, which sits outside the tree, and
    # claude's file tools reach only its workspace and the directories it is given.
    # CTX_ABS was already validated and resolved above, before any fingerprint, so this is
    # only the flag that grants it.
    if [ -n "$CTX_ABS" ]; then claude_args+=(--add-dir "$CTX_ABS"); fi
    # "added through --add-dir": not "added as readable". Second-review finding (issue #100
    # round 6): --add-dir grants claude's file tools read AND WRITE, so the old wording
    # understated what the reviewer could do to its own main input.
    permissions="claude ran with --restricted --strict-mcp-config --tools and --allowedTools both Read,Grep,Glob,Edit,Write,Bash, in a workspace of its own ($claude_cwd), with $TREE_ABS${CTX_ABS:+ and $CTX_ABS} added through --add-dir (writes and commands permitted)"
    ( cd "$claude_cwd" && ${timeout_cmd[@]+"${timeout_cmd[@]}"} "$resolved_cmd" "${claude_args[@]}" ) \
      < "$BRIEF_ABS" > "$OUT_ABS/review.json" 2> "$OUT_ABS/review.err" || run_status=$?
    # Any error the backend reports means no review happened, whatever its wording, so the
    # record is rejected on is_error alone and the error code only chooses the message. This
    # extractor fails CLOSED: it prints one of three fixed ASCII words, and anything else --
    # including python failing outright -- refuses the run. Computed here, but NOT acted on
    # until after the at-return fingerprint below: a reviewer that changes the tree and then
    # reports an error must still be caught as a tree change, not let through as a plain
    # E_RUN_FAILED with the write never looked at. Verified: a stub that changed a tracked
    # file and returned is_error:true used to refuse before any fingerprint after the
    # baseline existed at all.
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
# is_error must be an actual boolean. Second-review finding (issue #100 round 4): a missing
# key or a falsy-but-wrong-type value (absent, 0) used to read the same as is_error:false
# and pass straight through as OK, which is not what a record that does not even have the
# field in the expected shape should mean.
if not isinstance(d.get("is_error"), bool):
    print("NO_RECORD"); raise SystemExit(0)
if not d["is_error"]:
    print("OK"); raise SystemExit(0)
# Only ASCII leaves this script, so no value in the record can break the print.
blob = "%s %s %s" % (d.get("api_error") or "", d.get("result") or "",
                     d.get("api_error_status") or "")
blob = blob.encode("ascii", "replace").decode("ascii").lower()
print("ERROR_AUTH" if ("credential" in blob or "authenticat" in blob or "403" in blob)
      else "ERROR_OTHER")
' "$OUT_ABS/review.json" 2>/dev/null) || claude_status=EXTRACTOR_FAILED
    fi
    ;;
esac

# Fingerprint as soon as the backend returns, and again at the end. A mismatch here with a
# match at the end means something put the tree back *after* the backend returned, which a
# single late fingerprint would have missed. This must happen before any refusal below,
# including the claude is_error check and the run_status check: a backend that wrote to the
# tree and then failed must still be caught as a tree change. It must also be refused,
# rather than left to "set -e", if it cannot complete: the backend may have removed the
# tree or made it unreadable, and a bare pipeline failure here would otherwise end the
# script with no tag at all.
tree_fingerprint "$TREE_ABS" > "$OUT_ABS/tree-at-return.sha256" || refuse E_TREE_CHANGED \
  "the tree at $TREE_ABS could not be fingerprinted after the backend returned: it may have been removed, or made unreadable, while the reviewer ran."
if [ -n "$CTX_ABS" ]; then
  tree_fingerprint "$CTX_ABS" > "$OUT_ABS/ctx-at-return.sha256" || refuse E_CONTEXT_CHANGED \
    "\$SECOND_REVIEW_CONTEXT_DIR '$CTX_ABS' could not be fingerprinted after the backend returned: it may have been removed, or made unreadable, while the reviewer ran."
fi

# --- did a review actually happen -------------------------------------------------------

# A tree or context-directory change takes priority over a reported run failure: a backend
# that wrote to either and then exited non-zero, or that claude reported as is_error, must
# be caught as a change rather than let through as a plain run failure with the write never
# looked at. Checked only here, against the fingerprints already taken above -- not the
# final ones, which are taken separately near the end of the script specifically so a
# process the backend left running has another, later point to be caught at (not because
# much wall-clock time passes before then: only the model-name parsing below runs in
# between, typically well under a second) -- and would wrongly delay reporting a failure
# that already shows in what we have.
# If the review otherwise succeeds, whether either changes later is still caught by the full
# comparison at the end, below. Verified: a stub that changed a tracked file and then
# reported is_error:true used to refuse as a plain E_RUN_FAILED with this comparison never
# made.
review_otherwise_ok=1
[ "$run_status" -eq 0 ] || review_otherwise_ok=0
if [ "$BACKEND" = claude ] && [ "${claude_status:-OK}" != OK ]; then review_otherwise_ok=0; fi
if [ "$review_otherwise_ok" -ne 1 ] && [ -n "$CTX_ABS" ] \
   && ! cmp -s "$OUT_ABS/ctx-before.sha256" "$OUT_ABS/ctx-at-return.sha256"; then
  refuse E_CONTEXT_CHANGED \
    "the $BACKEND backend reported a failure, and \$SECOND_REVIEW_CONTEXT_DIR '$CTX_ABS' had already changed by the time it returned. Compare $OUT_ABS/ctx-before.sha256 with ctx-at-return.sha256."
fi
if [ "$review_otherwise_ok" -ne 1 ] && ! cmp -s "$OUT_ABS/tree-before.sha256" "$OUT_ABS/tree-at-return.sha256"; then
  refuse E_TREE_CHANGED \
    "the $BACKEND backend reported a failure, and the tree at $TREE_ABS had already changed by the time it returned. Compare $OUT_ABS/tree-before.sha256 with tree-at-return.sha256."
fi

# A backend that is missing, unauthenticated or out of credit exits non-zero or says
# nothing. Either way the review did not happen, so say so rather than reporting a pass.
if [ "$run_status" -ne 0 ]; then
  refuse E_RUN_FAILED "the $BACKEND backend exited $run_status and no review was produced. Read the last lines of $OUT_ABS/review.err yourself with tail, and do not paste them into a pull request, an issue or Slack."
fi

if [ "$BACKEND" = claude ]; then
  case "${claude_status:-OK}" in
    OK) ;;
    ERROR_AUTH) refuse E_RUN_FAILED \
      "the claude backend could not authenticate, so no review was produced. The likely cause where claude authenticates through a settings file: --restricted makes it ignore the user settings file, so set \$SECOND_REVIEW_CLAUDE_SETTINGS to a file carrying that authentication setting. Read $OUT_ABS/review.err yourself with tail, and do not paste it into a pull request, an issue or Slack." ;;
    ERROR_OTHER) refuse E_RUN_FAILED \
      "the claude backend reported an error, so no review was produced. Read $OUT_ABS/review.json and $OUT_ABS/review.err yourself with tail, and do not paste them into a pull request, an issue or Slack." ;;
    *) refuse E_BAD_RECORD \
      "could not tell whether the claude backend reported an error (the check returned '$claude_status'), so this run cannot be recorded as a review. Check $OUT_ABS/review.json." ;;
  esac
fi

# --- invariant 3: which model actually answered ------------------------------------------

reported_models=''
case "$BACKEND" in
  codex)
    # Read the model name out of codex's own preamble: the block between the first two rules
    # before its "user" marker. The line right after that marker must be this run's nonce,
    # which is what makes the block codex's own rather than something the brief supplied.
    # The sandbox and approval lines are no longer read -- the reviewer is meant to be able
    # to write, and the tree check is what establishes that it did not.
    echoed_first=$(awk '/^user$/ { if (getline > 0) print; exit }' "$OUT_ABS/review.err")
    grep -qx 'user' "$OUT_ABS/review.err" || refuse E_NO_PREAMBLE \
      "codex's trace has no 'user' marker, so where its own preamble ends and the echoed input begins cannot be told apart, and the model that answered cannot be read from it. Check $OUT_ABS/review.err with tail."
    [ "$echoed_first" = "$NONCE_LINE" ] || refuse E_NO_PREAMBLE \
      "the line after the 'user' marker in codex's trace is not this run's nonce, so that marker is not codex's own and everything before it may be the echoed input rather than codex's preamble. Check $OUT_ABS/review.err with tail."
    awk '/^user$/ { exit } { print }' "$OUT_ABS/review.err" > "$OUT_ABS/pre-user.txt"
    rules=$(grep -c '^--------$' "$OUT_ABS/pre-user.txt" || true)
    [ "${rules:-0}" -ge 2 ] || refuse E_NO_PREAMBLE \
      "codex's trace has ${rules:-0} preamble rule(s) before its 'user' marker, not the two that delimit its own preamble, so the model that answered cannot be read from it. Check $OUT_ABS/review.err with tail."
    awk '/^--------$/ { n++; next } n == 1' "$OUT_ABS/pre-user.txt" > "$OUT_ABS/preamble.txt"
    reported_models=$(sed -n 's/^model: //p' "$OUT_ABS/preamble.txt" | head -1)
    ;;
  claude)
    # One pass over the record, refusing a shape this cannot read rather than guessing: a
    # string-valued modelUsage would otherwise be split into its characters, and a
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
if not isinstance(d.get("is_error"), bool):
    # Second-review finding (issue #100 round 4): a missing or wrong-type is_error (absent,
    # 0) used to read as falsy and pass this check, the same gap as the earlier extractor.
    print("BAD\tis_error is missing or is not a boolean")
    raise SystemExit(0)
if d["is_error"]:
    # Independent of the error check earlier: a failed run must never be recorded as a
    # review, even if that check were bypassed or failed to run.
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
# review-record.txt for a person to read, so: printable ASCII, no plus sign (the separator
# claude itself uses), and no padding whitespace, which would display as another name.
allowed = set(chr(c) for c in range(0x20, 0x7F)) - {"+"}
bad = [k for k in usage if not set(k) <= allowed or k != k.strip()]
if bad:
    print("BAD\ta model name holds something other than printable ASCII without a literal "
          "plus sign, or is padded with whitespace, which this script cannot carry or "
          "display safely: %s" % json.dumps(bad))
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
# permission_denials is a count, reported rather than refused on: --allowedTools above
# should mean this is always zero, and a non-zero count after that fix is a sign something
# the reviewer tried still needed an approval nobody could give -- worth seeing, not by
# itself proof the review is bad (it could be a tool outside --tools entirely, which is
# supposed to be refused).
denials = d.get("permission_denials")
denial_count = len(denials) if isinstance(denials, list) else -1
with open(out, "w") as f:
    f.write(result)
print("OK\t%s\t%d" % ("+".join(sorted(usage)), denial_count))
' "$OUT_ABS/review.json" "$OUT_ABS/review.out" > "$OUT_ABS/record.tsv" || \
      refuse E_BAD_RECORD "could not read the claude backend's JSON record at $OUT_ABS/review.json at all."
    IFS=$'\t' read -r verdict field_a field_b < "$OUT_ABS/record.tsv" || verdict=BAD
    if [ "${verdict:-BAD}" != OK ]; then
      refuse E_BAD_RECORD "the claude backend's JSON record at $OUT_ABS/review.json is not the shape this script can read, so it cannot say which model answered: ${field_a:-no reason given}."
    fi
    reported_models="$field_a"
    permissions="$permissions, $field_b permission request(s) denied"
    ;;
esac

[ -s "$OUT_ABS/review.out" ] || refuse E_EMPTY \
  "the $BACKEND backend exited 0 but wrote no review to $OUT_ABS/review.out. Check $OUT_ABS/review.err with tail."

# Never let the requested model stand in for the model that answered: a backend can route an
# alias ("opus", a prompt router) to something else, including the implementer's model.
[ -n "$reported_models" ] || refuse E_NO_MODEL_REPORTED \
  "the $BACKEND backend did not report which model answered, so this run cannot be recorded as a review by a different model."

# Split on "+" through an array: an unquoted expansion would let a name holding a bracket,
# such as "claude-opus-5-5[1m]", be read as a glob and silently become a filename. Only the
# claude backend joins several names with "+"; codex reports exactly one.
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

# --- invariant 2, concluded --------------------------------------------------------------

# Both fingerprints must match the one taken before the run. The "put back afterwards" case
# is tested first, because it is the one a single late fingerprint would have passed: on its
# own, "after" matches, and the run would have been recorded as clean. Refused, not left to
# "set -e", if the tree cannot be fingerprinted at all now -- the same reasoning as the
# at-return fingerprint above.
tree_fingerprint "$TREE_ABS" > "$OUT_ABS/tree-after.sha256" || refuse E_TREE_CHANGED \
  "the tree at $TREE_ABS could not be fingerprinted after the run: it may have been removed, or made unreadable."
if cmp -s "$OUT_ABS/tree-before.sha256" "$OUT_ABS/tree-after.sha256" \
   && ! cmp -s "$OUT_ABS/tree-before.sha256" "$OUT_ABS/tree-at-return.sha256"; then
  refuse E_TREE_RESTORED \
    "the tree at $TREE_ABS differed from its fingerprint when the backend returned, and matches again now: a change that was put back afterwards is still a change. Compare $OUT_ABS/tree-before.sha256 with tree-at-return.sha256."
fi
if ! cmp -s "$OUT_ABS/tree-before.sha256" "$OUT_ABS/tree-after.sha256"; then
  if cmp -s "$OUT_ABS/tree-before.sha256" "$OUT_ABS/tree-at-return.sha256"; then
    refuse E_TREE_CHANGED \
      "the tree at $TREE_ABS matched its fingerprint when the backend returned and differs now, so something changed it after the run -- a process the backend left behind, or another one. Compare $OUT_ABS/tree-at-return.sha256 with tree-after.sha256."
  fi
  refuse E_TREE_CHANGED \
    "the tree at $TREE_ABS changed while the reviewer ran. The reviewer is permitted to write, so this is not a confinement failure -- but it reviewed something other than the commit, so the run cannot stand. Compare $OUT_ABS/tree-before.sha256 with tree-after.sha256."
fi

# The same three-way comparison, for the context directory, when claude was given one:
# --add-dir grants write as well as read, so this is a third thing invariant 2 has to cover.
if [ -n "$CTX_ABS" ]; then
  tree_fingerprint "$CTX_ABS" > "$OUT_ABS/ctx-after.sha256" || refuse E_CONTEXT_CHANGED \
    "\$SECOND_REVIEW_CONTEXT_DIR '$CTX_ABS' could not be fingerprinted after the run: it may have been removed, or made unreadable."
  if cmp -s "$OUT_ABS/ctx-before.sha256" "$OUT_ABS/ctx-after.sha256" \
     && ! cmp -s "$OUT_ABS/ctx-before.sha256" "$OUT_ABS/ctx-at-return.sha256"; then
    refuse E_CONTEXT_RESTORED \
      "\$SECOND_REVIEW_CONTEXT_DIR '$CTX_ABS' differed from its fingerprint when the backend returned, and matches again now: a change that was put back afterwards is still a change. Compare $OUT_ABS/ctx-before.sha256 with ctx-at-return.sha256."
  fi
  if ! cmp -s "$OUT_ABS/ctx-before.sha256" "$OUT_ABS/ctx-after.sha256"; then
    if cmp -s "$OUT_ABS/ctx-before.sha256" "$OUT_ABS/ctx-at-return.sha256"; then
      refuse E_CONTEXT_CHANGED \
        "\$SECOND_REVIEW_CONTEXT_DIR '$CTX_ABS' matched its fingerprint when the backend returned and differs now. Compare $OUT_ABS/ctx-at-return.sha256 with ctx-after.sha256."
    fi
    refuse E_CONTEXT_CHANGED \
      "\$SECOND_REVIEW_CONTEXT_DIR '$CTX_ABS' changed while the reviewer ran. --add-dir grants write as well as read, so this is not a confinement failure -- but the reviewer's own main input changed under it, so the run cannot stand. Compare $OUT_ABS/ctx-before.sha256 with ctx-after.sha256."
  fi
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
  printf '  permissions     %s\n' "$permissions"
  printf '  review tree     unchanged in every type, mode, size, mtime, symlink target\n'
  printf '                  and content hash this script tracks, matching the fingerprint\n'
  printf '                  taken before the run and the one taken when the backend\n'
  printf '                  returned. The reviewer was NOT prevented from writing to it;\n'
  printf '                  this is the evidence that it did not, and it does not cover\n'
  printf '                  ownership, ACLs, extended attributes or hard links, a change\n'
  printf '                  whose tracked attributes were all put back, or any write made\n'
  printf '                  outside %s.\n' "$TREE_ABS"
  printf '  tree            %s\n' "$TREE_ABS"
  printf '  brief           %s\n' "$BRIEF_ABS"
  printf '  review          %s\n' "$OUT_ABS/review.out"
} | tee "$OUT_ABS/review-record.txt"

note "put 'model answered' above in the pull request's Second review section."
