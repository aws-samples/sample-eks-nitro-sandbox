#!/usr/bin/env bash
# Tests check-agent-files.sh both ways, on throwaway git repositories in a temporary
# folder: layouts it must accept, one layout per check that it must reject, and inputs it
# must refuse. Needs no cluster and no AWS.
#
# Each rejecting case asserts the exit code, the number of FINDING lines and the text of
# the finding, so a case cannot pass because the check crashed or failed for some other
# reason.
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

# --- fixtures ---------------------------------------------------------------------------

write_skill() { # repo folder name description
  mkdir -p "$1/.agents/skills/$2"
  printf -- '---\nname: %s\ndescription: %s\n---\n\n# %s\n' "$3" "$4" "$2" \
    >"$1/.agents/skills/$2/SKILL.md"
}

# A layout the check must accept: two skills, both links, CLAUDE.md, and an AGENTS.md whose
# only skill rows are in the Skills section.
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

# expect LABEL WANT_RC WANT_FINDINGS WANT_TEXT [CHECK_ARGS...]
# WANT_FINDINGS is the exact number of FINDING lines; WANT_TEXT must appear in the output.
expect() {
  local label=$1 want_rc=$2 want_n=$3 want_text=$4 out rc n
  shift 4
  out=$("$CHECK" "$@" 2>&1)
  rc=$?
  n=$(printf '%s\n' "$out" | grep -c '^FINDING: ')
  if [ "$rc" -ne "$want_rc" ]; then
    report_fail "$label: exit $rc, want $want_rc" "$out"
  elif [ "$n" -ne "$want_n" ]; then
    report_fail "$label: $n finding(s), want $want_n" "$out"
  elif [ -n "$want_text" ] && ! printf '%s\n' "$out" | grep -Fq -- "$want_text"; then
    report_fail "$label: output does not contain: $want_text" "$out"
  elif [ "$want_rc" -ne 2 ] && printf '%s\n' "$out" | grep -q '^check-agent-files: refused'; then
    report_fail "$label: refused instead of checking" "$out"
  else
    passed=$((passed + 1))
    echo "ok   $label"
  fi
}

report_fail() {
  failed=$((failed + 1))
  echo "FAIL $1"
  printf '%s\n' "$2" | sed 's/^/       | /'
}

# --- must accept -------------------------------------------------------------------------

d=$(new_repo accept-plain)
expect "accept: the plain layout" 0 0 "OK, 2 skill(s)" "$d"

d=$(new_repo accept-comments-and-fences)
awk '
  { print }
  /^[|] `beta-two` [|]/ {
    print "<!-- | `ghost-one` | a commented-out row is not a skill | -->"
    print "<!--"
    print "| `ghost-two` | nor is a row inside a multi-line comment |"
    print "-->"
    print "```markdown"
    print "| `ghost-three` | nor is an example row in a code block |"
    print "```"
  }
' "$d/AGENTS.md" >"$d/AGENTS.md.new" && mv "$d/AGENTS.md.new" "$d/AGENTS.md"
expect "accept: rows inside comments and code blocks are ignored" 0 0 "OK, 2 skill(s)" "$d"

d=$(new_repo accept-yaml-forms)
printf -- '---\nname: "alpha"\ndescription: "Quoted: a colon and issue #2 are fine here."\n---\n' \
  >"$d/.agents/skills/alpha/SKILL.md"
printf -- '---\nname: beta-two\ndescription: >\n  A folded block description,\n  over two lines.\n---\n' \
  >"$d/.agents/skills/beta-two/SKILL.md"
expect "accept: quoted values and a block description" 0 0 "OK, 2 skill(s)" "$d"

d=$(new_repo accept-crlf)
printf -- '---\r\nname: alpha\r\ndescription: Written on Windows.\r\n---\r\n' \
  >"$d/.agents/skills/alpha/SKILL.md"
expect "accept: CRLF line endings" 0 0 "OK, 2 skill(s)" "$d"

d=$(new_repo accept-extra-tool-link)
mkdir -p "$d/.opencode"
ln -s ../.agents/skills "$d/.opencode/skills"
expect "accept: another tool folder that is also a link" 0 0 "3 tool link(s)" "$d"

d=$(new_repo accept-default-root)
mkdir -p "$d/scripts"
cp "$CHECK" "$d/scripts/check-agent-files.sh"
out=$("$d/scripts/check-agent-files.sh" 2>&1)
rc=$?
# The fixture has two skills; any other repo would report a different count.
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -Fq "OK, 2 skill(s)"; then
  passed=$((passed + 1))
  echo "ok   accept: no argument checks the repo the script is in"
else
  report_fail "accept: no argument checks the repo the script is in (exit $rc)" "$out"
fi

# --- must reject: tool links ---------------------------------------------------------------

d=$(new_repo reject-broken-link)
rm "$d/.claude/skills"
ln -s ../.agents/skilz "$d/.claude/skills"
expect "reject: a broken link" 1 1 ".claude/skills is a broken link" "$d"

d=$(new_repo reject-link-elsewhere)
mkdir -p "$d/other"
rm "$d/.kiro/skills"
ln -s ../other "$d/.kiro/skills"
expect "reject: a link to the wrong folder" 1 1 ".kiro/skills resolves to" "$d"

d=$(new_repo reject-absolute-link)
rm "$d/.claude/skills"
ln -s "$(cd -P "$d" && pwd -P)/.agents/skills" "$d/.claude/skills"
expect "reject: an absolute link, which breaks in other clones" 1 1 "points at an absolute path" "$d"

d=$(new_repo reject-missing-link)
rm "$d/.kiro/skills"
expect "reject: a missing tool link" 1 1 ".kiro/skills is missing" "$d"

d=$(new_repo reject-agents-skills-is-link)
mv "$d/.agents/skills" "$d/shared-skills"
ln -s ../shared-skills "$d/.agents/skills"
expect "reject: .agents/skills itself is a link" 1 7 ".agents/skills is a symbolic link" "$d"

# --- must reject: second copies -----------------------------------------------------------

d=$(new_repo reject-copied-tool-folder)
rm "$d/.claude/skills"
mkdir -p "$d/.claude/skills/alpha"
cp "$d/.agents/skills/alpha/SKILL.md" "$d/.claude/skills/alpha/SKILL.md"
expect "reject: a tool folder that holds a copy" 1 2 ".claude/skills/alpha/SKILL.md is a skill outside" "$d"

d=$(new_repo reject-duplicated-skill)
mkdir -p "$d/tools/alpha"
cp "$d/.agents/skills/alpha/SKILL.md" "$d/tools/alpha/SKILL.md"
expect "reject: a duplicated skill elsewhere in the repo" 1 1 "tools/alpha/SKILL.md is a skill outside" "$d"

d=$(new_repo reject-extra-real-tool-folder)
mkdir -p "$d/.opencode/skills/alpha"
cp "$d/.agents/skills/alpha/SKILL.md" "$d/.opencode/skills/alpha/SKILL.md"
expect "reject: another tool folder that is a real copy" 1 2 ".opencode/skills is not a symbolic link" "$d"

d=$(new_repo reject-nested-skill)
mkdir -p "$d/.agents/skills/alpha/inner"
cp "$d/.agents/skills/alpha/SKILL.md" "$d/.agents/skills/alpha/inner/SKILL.md"
expect "reject: a skill nested inside another" 1 1 "alpha/inner/SKILL.md is nested" "$d"

d=$(new_repo reject-linked-skill-folder)
mkdir -p "$d/vendor"
mv "$d/.agents/skills/beta-two" "$d/vendor/beta-two"
ln -s ../../vendor/beta-two "$d/.agents/skills/beta-two"
expect "reject: a skill folder that is a link to a copy elsewhere" 1 3 ".agents/skills/beta-two is a symbolic link" "$d"

# --- must reject: frontmatter ---------------------------------------------------------------

d=$(new_repo reject-name-mismatch)
write_skill "$d" alpha alpha-other "Use for alpha work."
expect "reject: name differs from the folder" 1 1 "name 'alpha-other' does not match its folder 'alpha'" "$d"

d=$(new_repo reject-no-name)
printf -- '---\ndescription: Use for alpha work.\n---\n' >"$d/.agents/skills/alpha/SKILL.md"
expect "reject: no name" 1 1 "has no name in its frontmatter" "$d"

d=$(new_repo reject-commented-name)
printf -- '---\n# name: alpha\ndescription: Use for alpha work.\n---\n' >"$d/.agents/skills/alpha/SKILL.md"
expect "reject: a name only in a YAML comment" 1 1 "has no name in its frontmatter" "$d"

d=$(new_repo reject-empty-description)
printf -- '---\nname: alpha\ndescription:\n---\n' >"$d/.agents/skills/alpha/SKILL.md"
expect "reject: an empty description" 1 1 "has no description" "$d"

d=$(new_repo reject-empty-block-description)
printf -- '---\nname: alpha\ndescription: >\n---\n' >"$d/.agents/skills/alpha/SKILL.md"
expect "reject: an empty block description" 1 1 "has no description" "$d"

d=$(new_repo reject-name-outside-frontmatter)
printf -- '---\ndescription: Use for alpha work.\n---\nname: alpha\n' >"$d/.agents/skills/alpha/SKILL.md"
expect "reject: a name after the frontmatter" 1 1 "has no name in its frontmatter" "$d"

d=$(new_repo reject-no-frontmatter)
printf -- '# alpha\n\nname: alpha\ndescription: Use for alpha work.\n' >"$d/.agents/skills/alpha/SKILL.md"
expect "reject: no frontmatter" 1 1 "has no frontmatter" "$d"

d=$(new_repo reject-unterminated-frontmatter)
printf -- '---\nname: alpha\ndescription: Use for alpha work.\n' >"$d/.agents/skills/alpha/SKILL.md"
expect "reject: frontmatter that is never closed" 1 1 "frontmatter is not closed" "$d"

d=$(new_repo reject-bad-name-format)
write_skill "$d" alpha--x alpha--x "Use for alpha work."
awk '/^## Elsewhere/ { print "| `alpha--x` | Listed. |"; print "" } { print }' "$d/AGENTS.md" \
  >"$d/AGENTS.md.new" && mv "$d/AGENTS.md.new" "$d/AGENTS.md"
expect "reject: a folder name that is not a valid skill name" 1 1 "is not a valid skill name" "$d"

d=$(new_repo reject-colon-in-description)
printf -- '---\nname: alpha\ndescription: Use it for this: alpha work.\n---\n' >"$d/.agents/skills/alpha/SKILL.md"
expect "reject: an unquoted ': ' in the description" 1 1 "description contains ': '" "$d"

d=$(new_repo reject-hash-in-description)
printf -- '---\nname: alpha\ndescription: Modelled on issue #2.\n---\n' >"$d/.agents/skills/alpha/SKILL.md"
expect "reject: an unquoted ' #' in the description" 1 1 "description contains ' #'" "$d"

d=$(new_repo reject-long-description)
long=$(printf '%01025d' 0 | tr 0 x)
write_skill "$d" alpha alpha "$long"
expect "reject: a description over 1024 characters" 1 1 "longer than 1024" "$d"

d=$(new_repo reject-folder-without-skill)
mkdir -p "$d/.agents/skills/gamma"
printf 'not a skill\n' >"$d/.agents/skills/gamma/notes.md"
expect "reject: a skill folder with no SKILL.md" 1 1 ".agents/skills/gamma has no SKILL.md" "$d"

# --- must reject: CLAUDE.md -------------------------------------------------------------------

d=$(new_repo reject-claude-regular-file)
rm "$d/CLAUDE.md"
cp "$d/AGENTS.md" "$d/CLAUDE.md"
expect "reject: CLAUDE.md as a regular file" 1 1 "CLAUDE.md is a regular file" "$d"

d=$(new_repo reject-claude-checked-out-as-text)
rm "$d/CLAUDE.md"
printf 'AGENTS.md' >"$d/CLAUDE.md"
expect "reject: CLAUDE.md checked out as link text (Windows without symlinks)" 1 1 "core.symlinks" "$d"

d=$(new_repo reject-claude-wrong-target)
rm "$d/CLAUDE.md"
printf '# readme\n' >"$d/README.md"
ln -s README.md "$d/CLAUDE.md"
expect "reject: CLAUDE.md linked to another file" 1 1 "CLAUDE.md links to README.md" "$d"

d=$(new_repo reject-claude-missing)
rm "$d/CLAUDE.md"
expect "reject: no CLAUDE.md" 1 1 "CLAUDE.md is missing" "$d"

# --- must reject: the AGENTS.md skills index ---------------------------------------------------

d=$(new_repo reject-unlisted-skill)
write_skill "$d" gamma gamma "Use for gamma work."
expect "reject: a skill AGENTS.md does not list" 1 1 "skill 'gamma' is not listed" "$d"

d=$(new_repo reject-listed-only-in-comment)
write_skill "$d" gamma gamma "Use for gamma work."
awk '{ print } /^[|] `beta-two` [|]/ { print "<!-- | `gamma` | only in a comment | -->" }' \
  "$d/AGENTS.md" >"$d/AGENTS.md.new" && mv "$d/AGENTS.md.new" "$d/AGENTS.md"
expect "reject: a skill listed only inside a comment" 1 1 "skill 'gamma' is not listed" "$d"

d=$(new_repo reject-listed-only-elsewhere)
write_skill "$d" gamma gamma "Use for gamma work."
printf '| `gamma` | Listed outside the Skills section. |\n' >>"$d/AGENTS.md"
expect "reject: a skill listed outside the Skills section" 1 1 "skill 'gamma' is not listed" "$d"

d=$(new_repo reject-listed-missing-skill)
awk '{ print } /^[|] `beta-two` [|]/ { print "| `delta` | Listed, but not in .agents/skills. |" }' \
  "$d/AGENTS.md" >"$d/AGENTS.md.new" && mv "$d/AGENTS.md.new" "$d/AGENTS.md"
expect "reject: AGENTS.md lists a skill that does not exist" 1 1 "AGENTS.md lists skill 'delta'" "$d"

d=$(new_repo reject-no-skills-section)
awk '{ sub(/^## Skills$/, "## Tools"); print }' "$d/AGENTS.md" >"$d/AGENTS.md.new" &&
  mv "$d/AGENTS.md.new" "$d/AGENTS.md"
expect "reject: AGENTS.md with no Skills section" 1 3 "has no '## Skills' section" "$d"

d=$(new_repo reject-agents-missing)
rm "$d/AGENTS.md"
expect "reject: no AGENTS.md" 1 2 "AGENTS.md is missing" "$d"

# --- must refuse ----------------------------------------------------------------------------------

mkdir -p "$work/not-a-repo"
expect "refuse: a folder that is not a git work tree" 2 0 "not a git work tree" "$work/not-a-repo"
expect "refuse: a folder that does not exist" 2 0 "not a directory" "$work/does-not-exist"
expect "refuse: an unknown option" 2 0 "unknown option" --bogus
expect "refuse: two arguments" 2 0 "at most one argument" "$work" "$work"

d=$(new_repo refuse-subfolder)
expect "refuse: a subfolder of a work tree" 2 0 "is not the top of its git work tree" "$d/.agents"

mkdir -p "$work/loose"
cp "$CHECK" "$work/loose/check-agent-files.sh"
out=$("$work/loose/check-agent-files.sh" 2>&1)
rc=$?
if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -Fq "not inside a git work tree"; then
  passed=$((passed + 1))
  echo "ok   refuse: no argument, and the script is outside any work tree"
else
  report_fail "refuse: no argument, and the script is outside any work tree (exit $rc)" "$out"
fi

echo
echo "test-check-agent-files: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
