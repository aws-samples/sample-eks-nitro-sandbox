#!/usr/bin/env bash
# Tests check-agent-files.sh both ways, on throwaway git repositories in a temporary
# folder: layouts it must accept, one or more layouts per check that it must reject, and
# inputs it must refuse. Needs no cluster and no AWS.
#
# Every case asserts how the check ended, not only what it printed:
#   accept   exit 0, no FINDING line, the OK footer, and nothing on stderr
#   reject   exit 1, exactly one FINDING line per expected text (each text matched to its
#            own line), the "N finding(s)" footer, and nothing on stderr
#   refuse   exit 2, nothing on stdout, and the refusal text on stderr
# so a case cannot pass because the check crashed, or failed for some other reason.
#
# Usage: scripts/test-check-agent-files.sh     Exit: 0 all passed, 1 a test failed.

set -u

here=$(cd -P "$(dirname "$0")" && pwd -P)
CHECK="$here/check-agent-files.sh"
[ -x "$CHECK" ] || { echo "not executable: $CHECK" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/check-agent-files-test.XXXXXX") || exit 1
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

passed=0
failed=0
check_cmd=$CHECK # the copy under test; two cases run a copy placed elsewhere

# --- fixtures ---------------------------------------------------------------------------

write_skill() { # repo folder name description
  mkdir -p "$1/.agents/skills/$2"
  printf -- '---\nname: %s\ndescription: %s\n---\n\n# %s\n' "$3" "$4" "$2" \
    >"$1/.agents/skills/$2/SKILL.md"
}

# The layout the check must accept: two skills (one with supporting files), both tool
# links, CLAUDE.md, and an AGENTS.md whose only skill rows are in the Skills section.
new_repo() { # name -> prints the repo path
  local d="$work/$1"
  mkdir -p "$d/.claude" "$d/.kiro"
  git -C "$d" init -q
  write_skill "$d" alpha alpha "Use for alpha work."
  write_skill "$d" beta-two beta-two "Use for beta work."
  mkdir -p "$d/.agents/skills/beta-two/references"
  printf 'supporting notes\n' >"$d/.agents/skills/beta-two/references/notes.md"
  printf '# About these skills\n' >"$d/.agents/skills/README.md"
  cat >"$d/AGENTS.md" <<'EOF'
# AGENTS.md

## Skills

| Skill | Use it to |
|---|---|
| `alpha` | Do alpha work. |
| `beta-two` | Do beta work. |

## Elsewhere

| `not-a-skill` | A row outside the Skills section is not a skill. |
EOF
  ln -s AGENTS.md "$d/CLAUDE.md"
  ln -s ../.agents/skills "$d/.claude/skills"
  ln -s ../.agents/skills "$d/.kiro/skills"
  printf '%s\n' "$d"
}

# Insert lines after the beta-two row of AGENTS.md. Plain shell rather than awk -v,
# which some awks refuse when the value holds a newline.
after_beta_row() { # repo line...
  local d=$1 line
  shift
  while IFS= read -r line; do
    printf '%s\n' "$line"
    case "$line" in
      '| `beta-two` |'*) printf '%s\n' "$@" ;;
    esac
  done <"$d/AGENTS.md" >"$d/AGENTS.md.new" && mv "$d/AGENTS.md.new" "$d/AGENTS.md"
}

# --- assertions -------------------------------------------------------------------------

run_check() {
  "$check_cmd" "$@" >"$work/out" 2>"$work/err"
  rc=$?
  nfind=$(grep -c '^FINDING: ' "$work/out")
}

report_fail() {
  failed=$((failed + 1))
  echo "FAIL $1"
  { sed 's/^/       | /' "$work/out"; sed 's/^/       ! /' "$work/err"; } | head -40
}

pass() {
  passed=$((passed + 1))
  echo "ok   $1"
}

expect_ok() { # label ok-text check-args...
  local label=$1 text=$2
  shift 2
  run_check "$@"
  if [ "$rc" -ne 0 ]; then report_fail "$label: exit $rc, want 0"
  elif [ "$nfind" -ne 0 ]; then report_fail "$label: $nfind finding(s), want 0"
  elif [ -s "$work/err" ]; then report_fail "$label: wrote to stderr"
  elif ! tail -n 1 "$work/out" | grep -q '^check-agent-files: OK, '; then report_fail "$label: no OK footer"
  elif ! tail -n 1 "$work/out" | grep -Fq -- "$text"; then report_fail "$label: footer lacks: $text"
  else pass "$label"
  fi
}

expect_findings() { # label repo text... (one text per expected FINDING line)
  local label=$1 repo=$2 remaining t n
  shift 2
  run_check "$repo"
  if [ "$rc" -ne 1 ]; then report_fail "$label: exit $rc, want 1"; return; fi
  if [ "$nfind" -ne "$#" ]; then report_fail "$label: $nfind finding(s), want $#"; return; fi
  if [ -s "$work/err" ]; then report_fail "$label: wrote to stderr"; return; fi
  if ! tail -n 1 "$work/out" | grep -q "^check-agent-files: $# finding(s) in "; then
    report_fail "$label: no '$# finding(s)' footer"
    return
  fi
  remaining=$(grep '^FINDING: ' "$work/out")
  for t in "$@"; do
    n=$(printf '%s\n' "$remaining" | grep -F -n -- "$t" | head -n 1 | cut -d: -f1)
    if [ -z "$n" ]; then report_fail "$label: no finding left that matches: $t"; return; fi
    remaining=$(printf '%s\n' "$remaining" | sed "${n}d")
  done
  pass "$label"
}

expect_refused() { # label text check-args...
  local label=$1 text=$2
  shift 2
  run_check "$@"
  if [ "$rc" -ne 2 ]; then report_fail "$label: exit $rc, want 2"
  elif [ -s "$work/out" ]; then report_fail "$label: wrote to stdout"
  elif ! grep -q '^check-agent-files: refused: ' "$work/err"; then report_fail "$label: no refusal line"
  elif ! grep -Fq -- "$text" "$work/err"; then report_fail "$label: refusal lacks: $text"
  elif ! grep -q '^check-agent-files: nothing was checked$' "$work/err"; then report_fail "$label: no 'nothing was checked'"
  else pass "$label"
  fi
}

# --- must accept -------------------------------------------------------------------------

d=$(new_repo accept-plain)
expect_ok "accept: the plain layout" "OK, 2 skill(s) in .agents/skills, 2 tool link(s)" "$d"

d=$(new_repo "accept with spaces")
expect_ok "accept: a repository path with spaces" "OK, 2 skill(s)" "$d"

d=$(new_repo accept-comments-and-fences)
write_skill "$d" gamma gamma "Use for gamma work."
after_beta_row "$d" \
  '<!-- | `ghost-one` | a commented-out row is not a skill | -->' \
  '<!--' \
  '| `ghost-two` | nor is a row inside a multi-line comment |' \
  '-->' \
  '```markdown' \
  '| `ghost-three` | nor is an example row in a code block |' \
  '```' \
  '````text' \
  '```' \
  '| `ghost-four` | three backticks do not close a four-backtick fence |' \
  '   `````' \
  '~~~' \
  '```' \
  '| `ghost-five` | backticks do not close a tilde fence |' \
  '~~~ not a closer' \
  '| `ghost-six` | nor does a closing run with text after it |' \
  '~~~' \
  '    | `ghost-seven` | an indented row is not a table row |' \
  '| `gamma` | a real row after all of them still counts |'
expect_ok "accept: rows in comments, code blocks and nested fences are ignored" "OK, 3 skill(s)" "$d"

d=$(new_repo accept-not-a-fence)
write_skill "$d" gamma gamma "Use for gamma work."
after_beta_row "$d" '```not`a`fence' '| `gamma` | listed after a line that only looks like a fence |'
expect_ok "accept: a backtick run with a backtick after it does not open a fence" "OK, 3 skill(s)" "$d"

d=$(new_repo accept-table-spacing)
awk '{ sub(/^[|] `alpha` [|]/, "|`alpha`|"); sub(/^[|] `beta-two` [|]/, "|   `beta-two`\t|"); print }' \
  "$d/AGENTS.md" >"$d/AGENTS.md.new" && mv "$d/AGENTS.md.new" "$d/AGENTS.md"
expect_ok "accept: table rows with other spacing" "OK, 2 skill(s)" "$d"

d=$(new_repo accept-yaml-forms)
printf -- '---\nname: "alpha"\ndescription: "Quoted: a colon and issue #2 are fine here."\n---\n' \
  >"$d/.agents/skills/alpha/SKILL.md"
printf -- '---\nname: beta-two\ndescription: >\n\n  A folded block description that starts\n  after a blank line.\nlicense: MIT-0\n---\n' \
  >"$d/.agents/skills/beta-two/SKILL.md"
expect_ok "accept: quoted values, and a block description after a blank line" "OK, 2 skill(s)" "$d"

d=$(new_repo accept-block-indicators)
printf -- '---\nname: alpha\ndescription: |2\n    Literal block with an indentation indicator.\n---\n' \
  >"$d/.agents/skills/alpha/SKILL.md"
printf -- '---\nname: beta-two\ndescription: >- # folded, and a comment after the indicator\n  Folded block text.\n---\n' \
  >"$d/.agents/skills/beta-two/SKILL.md"
expect_ok "accept: block indicators with an indentation digit or a comment" "OK, 2 skill(s)" "$d"

d=$(new_repo accept-crlf)
printf -- '---\r\nname: alpha\r\ndescription: Written on Windows.\r\n---\r\n' \
  >"$d/.agents/skills/alpha/SKILL.md"
expect_ok "accept: CRLF line endings" "OK, 2 skill(s)" "$d"

d=$(new_repo accept-extra-tool-link)
mkdir -p "$d/.opencode"
ln -s ../.agents/skills "$d/.opencode/skills"
expect_ok "accept: another tool folder that is also a link" "3 tool link(s)" "$d"

d=$(new_repo accept-ignored-copy)
mkdir -p "$d/scratch/alpha"
cp "$d/.agents/skills/alpha/SKILL.md" "$d/scratch/alpha/SKILL.md"
printf 'scratch/\n' >"$d/.gitignore"
expect_ok "accept: a copy in an ignored folder, which git would not commit" "OK, 2 skill(s)" "$d"

d=$(new_repo accept-default-root)
mkdir -p "$d/scripts"
cp "$CHECK" "$d/scripts/check-agent-files.sh"
check_cmd="$d/scripts/check-agent-files.sh"
expect_ok "accept: no argument checks the repo the script is in" "OK, 2 skill(s)"
check_cmd=$CHECK

# --- must reject: .agents/skills and the tool links ---------------------------------------

d=$(new_repo reject-broken-link)
rm "$d/.claude/skills"
ln -s ../.agents/skilz "$d/.claude/skills"
expect_findings "reject: a broken link" "$d" ".claude/skills is a broken link"

d=$(new_repo reject-link-elsewhere)
mkdir -p "$d/other"
rm "$d/.kiro/skills"
ln -s ../other "$d/.kiro/skills"
expect_findings "reject: a link to the wrong folder" "$d" ".kiro/skills resolves to"

d=$(new_repo reject-absolute-link)
rm "$d/.claude/skills"
ln -s "$(cd -P "$d" && pwd -P)/.agents/skills" "$d/.claude/skills"
expect_findings "reject: an absolute link, which breaks in other clones" "$d" "points at an absolute path"

d=$(new_repo reject-missing-link)
rm "$d/.kiro/skills"
expect_findings "reject: a missing tool link" "$d" ".kiro/skills is missing"

d=$(new_repo reject-agents-skills-is-link)
mv "$d/.agents/skills" "$d/shared-skills"
ln -s ../shared-skills "$d/.agents/skills"
expect_findings "reject: .agents/skills itself is a link" "$d" \
  ".agents/skills is a symbolic link" \
  ".claude/skills resolves to" ".kiro/skills resolves to" \
  "shared-skills/alpha/SKILL.md is a skill outside" "shared-skills/beta-two/SKILL.md is a skill outside" \
  "AGENTS.md lists skill 'alpha'" "AGENTS.md lists skill 'beta-two'"

d=$(new_repo reject-agents-dir-is-link)
mv "$d/.agents" "$work/agents-outside-the-repo"
ln -s "$work/agents-outside-the-repo" "$d/.agents"
work_real=$(cd -P "$work" && pwd -P) # /tmp is itself a link on macOS
expect_findings "reject: .agents is a link to a folder outside the repository" "$d" \
  ".agents/skills resolves to $work_real/agents-outside-the-repo/skills, outside this repository"

d=$(new_repo reject-agents-skills-missing)
rm -r "$d/.agents/skills"
expect_findings "reject: no .agents/skills" "$d" \
  ".agents/skills does not exist" ".claude/skills is a broken link" ".kiro/skills is a broken link" \
  "AGENTS.md lists skill 'alpha'" "AGENTS.md lists skill 'beta-two'"

d=$(new_repo reject-agents-skills-is-file)
rm -r "$d/.agents/skills"
printf 'not a folder\n' >"$d/.agents/skills"
expect_findings "reject: .agents/skills is a file" "$d" \
  ".agents/skills is not a folder" ".claude/skills is a broken link" ".kiro/skills is a broken link" \
  "AGENTS.md lists skill 'alpha'" "AGENTS.md lists skill 'beta-two'"

# --- must reject: second copies -----------------------------------------------------------

d=$(new_repo reject-copied-tool-folder)
rm "$d/.claude/skills"
mkdir -p "$d/.claude/skills/alpha"
cp "$d/.agents/skills/alpha/SKILL.md" "$d/.claude/skills/alpha/SKILL.md"
expect_findings "reject: a tool folder that holds a copy" "$d" \
  ".claude/skills is not a symbolic link" ".claude/skills/alpha/SKILL.md is a skill outside"

d=$(new_repo reject-duplicated-skill)
mkdir -p "$d/tools/alpha"
cp "$d/.agents/skills/alpha/SKILL.md" "$d/tools/alpha/SKILL.md"
expect_findings "reject: a duplicated skill elsewhere in the repo" "$d" "tools/alpha/SKILL.md is a skill outside"

d=$(new_repo reject-tracked-copy)
mkdir -p "$d/tools/alpha"
cp "$d/.agents/skills/alpha/SKILL.md" "$d/tools/alpha/SKILL.md"
git -C "$d" add tools/alpha/SKILL.md
printf 'tools/\n' >"$d/.gitignore"
expect_findings "reject: a tracked copy, even under an ignore rule" "$d" "tools/alpha/SKILL.md is a skill outside"

d=$(new_repo reject-newline-in-path)
mkdir -p "$d/tools/a
b"
cp "$d/.agents/skills/alpha/SKILL.md" "$d/tools/a
b/SKILL.md"
expect_findings "reject: a copy in a folder whose name has a newline" "$d" 'tools/a\nb/SKILL.md is a skill outside'

d=$(new_repo reject-extra-real-tool-folder)
mkdir -p "$d/.opencode/skills/alpha"
cp "$d/.agents/skills/alpha/SKILL.md" "$d/.opencode/skills/alpha/SKILL.md"
expect_findings "reject: another tool folder that is a real copy" "$d" \
  ".opencode/skills is not a symbolic link" ".opencode/skills/alpha/SKILL.md is a skill outside"

d=$(new_repo reject-nested-skill)
mkdir -p "$d/.agents/skills/alpha/inner"
cp "$d/.agents/skills/alpha/SKILL.md" "$d/.agents/skills/alpha/inner/SKILL.md"
expect_findings "reject: a skill nested inside another" "$d" "alpha/inner/SKILL.md is nested"

d=$(new_repo reject-broken-link-in-skill)
ln -s missing.md "$d/.agents/skills/beta-two/references/gone.md"
expect_findings "reject: a broken link inside a skill" "$d" \
  ".agents/skills/beta-two/references/gone.md is a symbolic link inside a skill"

d=$(new_repo reject-working-link-in-skill)
ln -s notes.md "$d/.agents/skills/beta-two/references/alias.md"
expect_findings "reject: a working link inside a skill" "$d" \
  ".agents/skills/beta-two/references/alias.md is a symbolic link inside a skill"

d=$(new_repo reject-linked-skill-folder)
mkdir -p "$d/vendor"
mv "$d/.agents/skills/beta-two" "$d/vendor/beta-two"
ln -s ../../vendor/beta-two "$d/.agents/skills/beta-two"
expect_findings "reject: a skill folder that is a link to a copy elsewhere" "$d" \
  ".agents/skills/beta-two is a symbolic link" "vendor/beta-two/SKILL.md is a skill outside" \
  "AGENTS.md lists skill 'beta-two'"

d=$(new_repo reject-broken-skill-link)
ln -s ../../nowhere "$d/.agents/skills/gamma"
expect_findings "reject: a broken link in .agents/skills" "$d" ".agents/skills/gamma is a broken link"

d=$(new_repo reject-dot-folder)
mkdir -p "$d/.agents/skills/.ghost"
printf -- '---\nname: .ghost\ndescription: Hidden.\n---\n' >"$d/.agents/skills/.ghost/SKILL.md"
expect_findings "reject: a skill folder whose name starts with a dot" "$d" \
  ".agents/skills/.ghost is not a valid skill name" "skill '.ghost' is not listed"

# --- must reject: frontmatter ---------------------------------------------------------------

d=$(new_repo reject-name-mismatch)
write_skill "$d" alpha alpha-other "Use for alpha work."
expect_findings "reject: name differs from the folder" "$d" "name 'alpha-other' does not match its folder 'alpha'"

d=$(new_repo reject-no-name)
printf -- '---\ndescription: Use for alpha work.\n---\n' >"$d/.agents/skills/alpha/SKILL.md"
expect_findings "reject: no name" "$d" "has no name in its frontmatter"

d=$(new_repo reject-commented-name)
printf -- '---\n# name: alpha\ndescription: Use for alpha work.\n---\n' >"$d/.agents/skills/alpha/SKILL.md"
expect_findings "reject: a name only in a YAML comment" "$d" "has no name in its frontmatter"

d=$(new_repo reject-name-no-space)
printf -- '---\nname:alpha\ndescription: Use for alpha work.\n---\n' >"$d/.agents/skills/alpha/SKILL.md"
expect_findings "reject: name with no space after the colon" "$d" "name has no space after the colon"

d=$(new_repo reject-description-no-space)
printf -- '---\nname: alpha\ndescription:Use for alpha work.\n---\n' >"$d/.agents/skills/alpha/SKILL.md"
expect_findings "reject: description with no space after the colon" "$d" "description has no space after the colon"

d=$(new_repo reject-empty-description)
printf -- '---\nname: alpha\ndescription:\n---\n' >"$d/.agents/skills/alpha/SKILL.md"
expect_findings "reject: an empty description" "$d" "has no description"

d=$(new_repo reject-comment-description)
printf -- '---\nname: alpha\ndescription: # only a comment\n---\n' >"$d/.agents/skills/alpha/SKILL.md"
expect_findings "reject: a description that is only a YAML comment" "$d" "has no description"

d=$(new_repo reject-empty-block-description)
printf -- '---\nname: alpha\ndescription: >\n---\n' >"$d/.agents/skills/alpha/SKILL.md"
expect_findings "reject: an empty block description" "$d" "has no description"

d=$(new_repo reject-block-then-key)
printf -- '---\nname: alpha\ndescription: |\nlicense: MIT-0\n---\n' >"$d/.agents/skills/alpha/SKILL.md"
expect_findings "reject: a block description that ends before any text" "$d" "has no description"

d=$(new_repo reject-name-outside-frontmatter)
printf -- '---\ndescription: Use for alpha work.\n---\nname: alpha\n' >"$d/.agents/skills/alpha/SKILL.md"
expect_findings "reject: a name after the frontmatter" "$d" "has no name in its frontmatter"

d=$(new_repo reject-no-frontmatter)
printf -- '# alpha\n\nname: alpha\ndescription: Use for alpha work.\n' >"$d/.agents/skills/alpha/SKILL.md"
expect_findings "reject: no frontmatter" "$d" "has no frontmatter"

d=$(new_repo reject-unterminated-frontmatter)
printf -- '---\nname: alpha\ndescription: Use for alpha work.\n' >"$d/.agents/skills/alpha/SKILL.md"
expect_findings "reject: frontmatter that is never closed" "$d" "frontmatter is not closed"

d=$(new_repo reject-bad-name-format)
write_skill "$d" alpha--x alpha--x "Use for alpha work."
after_beta_row "$d" '| `alpha--x` | Listed. |'
expect_findings "reject: a folder name that is not a valid skill name" "$d" "is not a valid skill name"

d=$(new_repo reject-long-name)
long_name=$(printf '%065d' 0 | sed 's/0/a/g')
write_skill "$d" "$long_name" "$long_name" "Use for long work."
after_beta_row "$d" "| \`$long_name\` | Listed. |"
expect_findings "reject: a skill name over 64 characters" "$d" "is longer than 64 characters"

d=$(new_repo reject-colon-in-description)
printf -- '---\nname: alpha\ndescription: Use it for this: alpha work.\n---\n' >"$d/.agents/skills/alpha/SKILL.md"
expect_findings "reject: an unquoted ': ' in the description" "$d" "description contains ': '"

d=$(new_repo reject-hash-in-description)
printf -- '---\nname: alpha\ndescription: Modelled on issue #2.\n---\n' >"$d/.agents/skills/alpha/SKILL.md"
expect_findings "reject: an unquoted ' #' in the description" "$d" "description contains ' #'"

d=$(new_repo reject-long-description)
long=$(printf '%01025d' 0 | sed 's/0/x/g')
write_skill "$d" alpha alpha "$long"
expect_findings "reject: a description over 1024 characters" "$d" "description is 1025 characters"

d=$(new_repo reject-long-block-description)
half=$(printf '%0600d' 0 | sed 's/0/y/g')
printf -- '---\nname: alpha\ndescription: >\n  %s\n\n  %s\n---\n' "$half" "$half" >"$d/.agents/skills/alpha/SKILL.md"
expect_findings "reject: a block description over 1024 characters" "$d" "description is 1201 characters"

d=$(new_repo reject-long-indicator-block)
long=$(printf '%01100d' 0 | sed 's/0/z/g')
printf -- '---\nname: alpha\ndescription: |2\n    %s\n---\n' "$long" >"$d/.agents/skills/alpha/SKILL.md"
expect_findings "reject: an over-long block that has an indentation indicator" "$d" "description is 1100 characters"

d=$(new_repo reject-bad-indicators)
printf -- '---\nname: alpha\ndescription: |0\n  Zero is not an indentation indicator.\n---\n' \
  >"$d/.agents/skills/alpha/SKILL.md"
printf -- '---\nname: beta-two\ndescription: >9000\n  Nor is a four-digit number.\n---\n' \
  >"$d/.agents/skills/beta-two/SKILL.md"
expect_findings "reject: block headers YAML cannot read" "$d" \
  "alpha/SKILL.md description starts with '|' or '>' but is not a valid block indicator" \
  "beta-two/SKILL.md description starts with '|' or '>' but is not a valid block indicator"

d=$(new_repo reject-folder-without-skill)
mkdir -p "$d/.agents/skills/gamma"
printf 'not a skill\n' >"$d/.agents/skills/gamma/notes.md"
expect_findings "reject: a skill folder with no SKILL.md" "$d" ".agents/skills/gamma has no SKILL.md"

# --- must reject: CLAUDE.md -------------------------------------------------------------------

d=$(new_repo reject-claude-regular-file)
rm "$d/CLAUDE.md"
cp "$d/AGENTS.md" "$d/CLAUDE.md"
expect_findings "reject: CLAUDE.md as a regular file" "$d" "CLAUDE.md is a regular file"

d=$(new_repo reject-claude-checked-out-as-text)
rm "$d/CLAUDE.md"
printf 'AGENTS.md' >"$d/CLAUDE.md"
expect_findings "reject: CLAUDE.md checked out as link text (Windows without symlinks)" "$d" "core.symlinks"

d=$(new_repo reject-claude-wrong-target)
rm "$d/CLAUDE.md"
printf '# readme\n' >"$d/README.md"
ln -s README.md "$d/CLAUDE.md"
expect_findings "reject: CLAUDE.md linked to another file" "$d" "CLAUDE.md links to README.md"

d=$(new_repo reject-claude-missing)
rm "$d/CLAUDE.md"
expect_findings "reject: no CLAUDE.md" "$d" "CLAUDE.md is missing"

# --- must reject: AGENTS.md and its skills index ----------------------------------------------

d=$(new_repo reject-unlisted-skill)
write_skill "$d" gamma gamma "Use for gamma work."
expect_findings "reject: a skill AGENTS.md does not list" "$d" "skill 'gamma' is not listed"

d=$(new_repo reject-listed-only-in-comment)
write_skill "$d" gamma gamma "Use for gamma work."
after_beta_row "$d" '<!-- | `gamma` | only in a comment | -->'
expect_findings "reject: a skill listed only inside a comment" "$d" "skill 'gamma' is not listed"

d=$(new_repo reject-listed-only-in-fence)
write_skill "$d" gamma gamma "Use for gamma work."
after_beta_row "$d" '````' '```' '| `gamma` | only in a code block |' '````'
expect_findings "reject: a skill listed only inside a code block" "$d" "skill 'gamma' is not listed"

d=$(new_repo reject-listed-only-elsewhere)
write_skill "$d" gamma gamma "Use for gamma work."
printf '| `gamma` | Listed outside the Skills section. |\n' >>"$d/AGENTS.md"
expect_findings "reject: a skill listed outside the Skills section" "$d" "skill 'gamma' is not listed"

d=$(new_repo reject-listed-missing-skill)
after_beta_row "$d" '| `delta` | Listed, but not in .agents/skills. |'
expect_findings "reject: AGENTS.md lists a skill that does not exist" "$d" "AGENTS.md lists skill 'delta'"

d=$(new_repo reject-listed-invalid-name)
after_beta_row "$d" '| `Gamma_Skill` | Listed with a name no skill can have. |'
expect_findings "reject: AGENTS.md lists a name with capitals and an underscore" "$d" "AGENTS.md lists skill 'Gamma_Skill'"

d=$(new_repo reject-no-skills-section)
awk '{ sub(/^## Skills$/, "## Tools"); print }' "$d/AGENTS.md" >"$d/AGENTS.md.new" &&
  mv "$d/AGENTS.md.new" "$d/AGENTS.md"
expect_findings "reject: AGENTS.md with no Skills section" "$d" \
  "has no '## Skills' section" "skill 'alpha' is not listed" "skill 'beta-two' is not listed"

d=$(new_repo reject-agents-is-link)
mv "$d/AGENTS.md" "$d/team-guide.md"
ln -s team-guide.md "$d/AGENTS.md"
expect_findings "reject: AGENTS.md is itself a link" "$d" "AGENTS.md is a symbolic link"

d=$(new_repo reject-agents-missing)
rm "$d/AGENTS.md"
expect_findings "reject: no AGENTS.md" "$d" "CLAUDE.md is a broken link to AGENTS.md" "AGENTS.md is missing"

# --- must refuse ----------------------------------------------------------------------------------

mkdir -p "$work/not-a-repo"
expect_refused "refuse: a folder that is not a git work tree" "not a git work tree" "$work/not-a-repo"
expect_refused "refuse: a folder that does not exist" "not a directory" "$work/does-not-exist"
expect_refused "refuse: an unknown option" "unknown option" --bogus
expect_refused "refuse: two arguments" "at most one argument" "$work" "$work"

d=$(new_repo refuse-subfolder)
expect_refused "refuse: a subfolder of a work tree" "is not the top of its git work tree" "$d/.agents"

mkdir -p "$work/loose"
cp "$CHECK" "$work/loose/check-agent-files.sh"
check_cmd="$work/loose/check-agent-files.sh"
expect_refused "refuse: no argument, and the script is outside any work tree" "not inside a git work tree"
check_cmd=$CHECK

echo
echo "test-check-agent-files: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
