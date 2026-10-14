#!/usr/bin/env bash
# Checks the files coding agents read: AGENTS.md, the CLAUDE.md link, the skills in
# .agents/skills and the per-tool folders that link to them. Needs no cluster and no AWS.
#
# Usage: scripts/check-agent-files.sh [REPO_ROOT]
#   REPO_ROOT defaults to the git work tree this script lives in.
#
# Exit codes:
#   0  clean
#   1  at least one finding (each is printed as one FINDING: line)
#   2  refused to run, so nothing was checked
#
# What it checks:
#   - .agents/skills is a real folder inside the repository (neither it nor .agents is a
#     link), and holds the one copy of every skill.
#   - Each tool folder (.claude/skills, .kiro/skills, and any other .<tool>/skills at the
#     top of the repo) is a relative symbolic link that resolves to .agents/skills.
#   - No SKILL.md that git tracks or would commit (untracked and not ignored) exists
#     outside .agents/skills/<name>/, so no skill has a second copy in the repository.
#   - Nothing inside a skill folder is a symbolic link, working or broken.
#   - Each skill is one folder below .agents/skills with a valid skill name (lowercase
#     letters, digits and single hyphens, at most 64 characters), and its SKILL.md starts
#     with frontmatter whose name equals the folder name and whose description is not
#     empty and at most 1024 characters.
#   - CLAUDE.md is a symbolic link to AGENTS.md.
#   - Every skill folder is listed in the "## Skills" table of AGENTS.md, and every skill
#     that table lists exists. A row counts when its first cell is one name in backticks;
#     rows inside HTML comments and fenced code blocks do not count.
#
# Written for bash 3.2 and POSIX awk, so it runs on macOS as well as Linux.

set -u

refuse() {
  echo "check-agent-files: refused: $*" >&2
  echo "check-agent-files: nothing was checked" >&2
  exit 2
}

if [ "$#" -gt 1 ]; then
  refuse "expected at most one argument, REPO_ROOT"
fi
case "${1:-}" in
  -*) refuse "unknown option: $1 (usage: $0 [REPO_ROOT])" ;;
esac

for cmd in git awk grep readlink mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || refuse "required command not found: $cmd"
done

if [ "$#" -eq 1 ]; then
  [ -d "$1" ] || refuse "not a directory: $1"
  root=$(cd -P "$1" 2>/dev/null && pwd -P) || refuse "cannot enter: $1"
else
  script_dir=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd -P) ||
    refuse "cannot find the folder this script is in"
  root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) ||
    refuse "this script is not inside a git work tree; pass REPO_ROOT"
fi
top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) ||
  refuse "not a git work tree: $root"
top=$(cd -P "$top" 2>/dev/null && pwd -P) || refuse "cannot enter: $top"
[ "$top" = "$root" ] || refuse "$root is not the top of its git work tree ($top)"

# Everything that can refuse runs before the first check, so exit 2 always means that
# nothing was checked. The file list is NUL-separated, so no file name can split a record.
listing_file=$(mktemp "${TMPDIR:-/tmp}/check-agent-files.XXXXXX") ||
  refuse "cannot create a temporary file"
trap 'rm -f "$listing_file"' EXIT
git -C "$root" ls-files --cached --others --exclude-standard -z >"$listing_file" 2>/dev/null ||
  refuse "git ls-files failed in $root"

findings=0
nl='
'
finding() {
  local msg="$*"
  msg=${msg//$nl/\\n} # one finding is always one line
  echo "FINDING: $msg"
  findings=$((findings + 1))
}

skills_rel=.agents/skills
skills_dir="$root/$skills_rel"
win_hint="on Windows, turn on Developer Mode and run 'git config --global core.symlinks true' before cloning"

# --- .agents/skills is the one real folder, inside the repository -----------------------

skills_real=""
if [ -L "$skills_dir" ]; then
  finding "$skills_rel is a symbolic link; it must be the real folder the tool folders link to"
elif [ ! -e "$skills_dir" ]; then
  finding "$skills_rel does not exist"
elif [ ! -d "$skills_dir" ]; then
  finding "$skills_rel is not a folder"
else
  skills_real=$(cd -P "$skills_dir" && pwd -P)
  # $root is a physical path, so a link anywhere above .agents/skills changes this.
  if [ "$skills_real" != "$root/$skills_rel" ]; then
    finding "$skills_rel resolves to $skills_real, outside this repository; .agents and $skills_rel must be real folders"
  fi
fi

# --- each tool folder is a relative link to .agents/skills -----------------------------

check_link() {
  local rel=$1 path target resolved
  path="$root/$rel"
  if [ ! -L "$path" ]; then
    if [ -e "$path" ]; then
      finding "$rel is not a symbolic link; replace it with 'ln -s ../$skills_rel $rel' ($win_hint)"
    else
      finding "$rel is missing; create it with 'ln -s ../$skills_rel $rel'"
    fi
    return
  fi
  target=$(readlink "$path")
  case "$target" in
    /*)
      finding "$rel points at an absolute path ($target), which breaks in every other clone; use '../$skills_rel'"
      return
      ;;
  esac
  if [ ! -d "$path" ]; then
    finding "$rel is a broken link (-> $target)"
    return
  fi
  resolved=$(cd -P "$path" && pwd -P)
  if [ -z "$skills_real" ] || [ "$resolved" != "$skills_real" ]; then
    finding "$rel resolves to $resolved, not to $skills_rel (-> $target)"
  fi
}

# The tools whose skills folder must exist, then any other .<tool>/skills that does.
links=".claude/skills
.kiro/skills"
for d in "$root"/.[!.]*/skills; do
  [ -e "$d" ] || [ -L "$d" ] || continue
  rel=${d#"$root"/}
  case "$rel" in
    "$skills_rel" | .git/*) continue ;;
  esac
  if ! printf '%s\n' "$links" | grep -Fqx -- "$rel"; then
    links="$links
$rel"
  fi
done
link_count=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  link_count=$((link_count + 1))
  check_link "$rel"
done <<<"$links"

# --- no SKILL.md outside .agents/skills/<name>/ -----------------------------------------
# git lists a symbolic link as itself and does not descend into it, so the tool links do
# not show up here; a real folder holding a copy does.

while IFS= read -r -d '' f; do
  case "$f" in
    SKILL.md | */SKILL.md) ;;
    *) continue ;;
  esac
  [ -f "$root/$f" ] || continue
  case "$f" in
    "$skills_rel"/*/SKILL.md)
      inner=${f#"$skills_rel"/}
      inner=${inner%/SKILL.md}
      case "$inner" in
        */*) finding "$f is nested; put each skill one folder below $skills_rel (Kiro CLI reads only .kiro/skills/*/SKILL.md)" ;;
      esac
      ;;
    *)
      finding "$f is a skill outside $skills_rel; keep the one copy in $skills_rel and reach it through a link"
      ;;
  esac
done <"$listing_file"

# --- no link inside a skill folder ------------------------------------------------------
# A skill holds real files. git lists a link as itself, so a broken one shows up here too;
# the tool folders already reach the skills through one link each, and a link inside a skill
# becomes a small text file in a Windows checkout without symlinks.

while IFS= read -r -d '' f; do
  case "$f" in
    "$skills_rel"/*/*)
      if [ -L "$root/$f" ]; then
        finding "$f is a symbolic link inside a skill; put the real file there instead"
      fi
      ;;
  esac
done <"$listing_file"

# --- each skill's frontmatter -----------------------------------------------------------
# Prints one key=value line per fact; the shell decides what is a finding. This is not a
# YAML parser: it reads the top-level name and description lines, plain, quoted or as a
# block scalar, and flags the plain values that YAML would not read as written. A block
# description's length is its lines' text joined by single spaces, as a folded block reads.

read_frontmatter() {
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function clean(v,   q, end) {
      q = substr(v, 1, 1)
      if (q == "#") return ""
      if (q == "\"" || q == "\047") {
        end = index(substr(v, 2), q)
        if (end > 0) return substr(v, 2, end - 1)
        return v
      }
      return v
    }
    function plain_trouble(v,   q) {
      q = substr(v, 1, 1)
      if (q == "\"" || q == "\047" || q == "#") return ""
      # A plain value cannot start with a block indicator; one that reaches here is a
      # malformed block header such as "|0" or ">9000".
      if (q == "|" || q == ">") return "indicator"
      if (index(v, ": ") > 0) return "colon"
      if (index(v, " #") > 0) return "hash"
      return ""
    }
    function field(key, line,   v, t) {
      v = substr(line, length(key) + 2)
      if (v != "" && v !~ /^[ \t]/) print key "_trouble=nospace"
      v = trim(v)
      if (key == "description" && v ~ /^[>|]([1-9][-+]?|[-+][1-9]?)?([ \t]+#.*)?$/) { block = 1; blen = 0; return }
      t = plain_trouble(v)
      if (t != "") print key "_trouble=" t
      v = clean(v)
      if (key == "name") print "name=" v
      else if (v != "") { print "description_ok=1"; print "description_len=" length(v) }
    }
    function end_block() {
      if (blen > 0) { print "description_ok=1"; print "description_len=" blen }
      block = 0
    }
    BEGIN { state = 0; block = 0 }
    { sub(/\r$/, "") }
    NR == 1 {
      if ($0 != "---") exit
      state = 1
      next
    }
    state == 1 && /^---[ \t]*$/ { state = 2; exit }
    state == 1 {
      if (block) {
        if ($0 ~ /^[ \t]*$/) next
        if ($0 ~ /^[ \t]/) { blen += (blen > 0 ? 1 : 0) + length(trim($0)); next }
        end_block()
      }
      if (substr($0, 1, 5) == "name:") field("name", $0)
      else if (substr($0, 1, 12) == "description:") field("description", $0)
    }
    END {
      if (block) end_block()
      if (state == 0) print "error=no-frontmatter"
      else if (state == 1) print "error=unterminated"
    }
  ' "$1"
}

fm_value() {
  printf '%s\n' "$2" | awk -v key="$1" '
    index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
  '
}

check_skill() {
  local rel_file=$1 folder=$2 facts err name len key
  facts=$(read_frontmatter "$root/$rel_file")
  err=$(fm_value error "$facts")
  case "$err" in
    no-frontmatter)
      finding "$rel_file has no frontmatter; its first line must be '---'"
      return
      ;;
    unterminated)
      finding "$rel_file frontmatter is not closed with a '---' line"
      return
      ;;
  esac
  name=$(fm_value name "$facts")
  if [ -z "$name" ]; then
    finding "$rel_file has no name in its frontmatter"
  elif [ "$name" != "$folder" ]; then
    finding "$rel_file name '$name' does not match its folder '$folder'"
  fi
  if ! printf '%s\n' "$folder" | grep -Eqx '[a-z0-9]+(-[a-z0-9]+)*'; then
    finding "$skills_rel/$folder is not a valid skill name: use lowercase letters, digits and single hyphens"
  elif [ "${#folder}" -gt 64 ]; then
    finding "$skills_rel/$folder is longer than 64 characters"
  fi
  if [ -z "$(fm_value description_ok "$facts")" ]; then
    finding "$rel_file has no description in its frontmatter"
  else
    len=$(fm_value description_len "$facts")
    if [ -n "$len" ] && [ "$len" -gt 1024 ]; then
      finding "$rel_file description is $len characters, longer than 1024"
    fi
  fi
  for key in name_trouble description_trouble; do
    case "$(fm_value "$key" "$facts")" in
      colon) finding "$rel_file ${key%_trouble} contains ': ', which breaks YAML; quote the value" ;;
      hash) finding "$rel_file ${key%_trouble} contains ' #', and YAML drops everything after it as a comment; quote the value" ;;
      nospace) finding "$rel_file ${key%_trouble} has no space after the colon, so YAML does not read it as a field" ;;
      indicator) finding "$rel_file ${key%_trouble} starts with '|' or '>' but is not a valid block indicator; quote the value or fix the indicator" ;;
    esac
  done
}

skill_names=""
skill_count=0
if [ -n "$skills_real" ]; then
  # Dot folders too: a skill folder named .something must not escape the checks.
  for d in "$skills_dir"/* "$skills_dir"/.[!.]* "$skills_dir"/..?*; do
    [ -e "$d" ] || [ -L "$d" ] || continue
    folder=${d##*/}
    if [ -L "$d" ]; then
      if [ -d "$d" ]; then
        finding "$skills_rel/$folder is a symbolic link; the real skill folder must live in $skills_rel"
      else
        finding "$skills_rel/$folder is a broken link"
      fi
      continue
    fi
    [ -d "$d" ] || continue
    if [ ! -f "$d/SKILL.md" ]; then
      finding "$skills_rel/$folder has no SKILL.md"
      continue
    fi
    skill_count=$((skill_count + 1))
    skill_names="$skill_names$folder
"
    check_skill "$skills_rel/$folder/SKILL.md" "$folder"
  done
fi

# --- CLAUDE.md links to AGENTS.md -------------------------------------------------------

if [ -L "$root/CLAUDE.md" ]; then
  target=$(readlink "$root/CLAUDE.md")
  if [ "$target" != "AGENTS.md" ]; then
    finding "CLAUDE.md links to $target; it must link to AGENTS.md ('ln -s AGENTS.md CLAUDE.md')"
  elif [ ! -f "$root/CLAUDE.md" ]; then
    finding "CLAUDE.md is a broken link to AGENTS.md"
  fi
elif [ -e "$root/CLAUDE.md" ]; then
  finding "CLAUDE.md is a regular file; make it a link with 'ln -s AGENTS.md CLAUDE.md' ($win_hint)"
else
  finding "CLAUDE.md is missing; create it with 'ln -s AGENTS.md CLAUDE.md'"
fi

# --- AGENTS.md lists exactly the skills that exist --------------------------------------
# Reads rows whose first cell is one name in backticks, in the "## Skills" section only,
# after removing HTML comments and fenced code blocks. A fence closes only on the same
# character repeated at least as many times as it opened with, as in CommonMark.

agents="$root/AGENTS.md"
if [ -L "$agents" ]; then
  finding "AGENTS.md is a symbolic link; it must be the real file CLAUDE.md links to"
fi
if [ ! -f "$agents" ]; then
  finding "AGENTS.md is missing"
else
  listed=$(awk '
    function fence_run(s, c,   n) {
      n = 0
      while (substr(s, n + 1, 1) == c) n++
      return n
    }
    function unindent(s) { sub(/^ ? ? ?/, "", s); return s }
    function fence_opens(s,   c, n) {
      s = unindent(s)
      c = substr(s, 1, 1)
      if (c != "`" && c != "~") return 0
      n = fence_run(s, c)
      if (n < 3) return 0
      # A backtick fence cannot have a backtick in its info string; such a line is text.
      if (c == "`" && index(substr(s, n + 1), "`") > 0) return 0
      fchar = c
      flen = n
      return 1
    }
    function fence_closes(s,   n) {
      s = unindent(s)
      n = fence_run(s, fchar)
      if (n < flen) return 0
      return (substr(s, n + 1) ~ /^[ \t]*$/)
    }
    BEGIN { fence = 0; incomment = 0; section = 0; found = 0 }
    { sub(/\r$/, "") }
    fence {
      if (fence_closes($0)) fence = 0
      next
    }
    {
      line = $0
      if (incomment) {
        e = index(line, "-->")
        if (e == 0) next
        line = substr(line, e + 3)
        incomment = 0
      }
      while ((s = index(line, "<!--")) > 0) {
        rest = substr(line, s + 4)
        e = index(rest, "-->")
        if (e == 0) { line = substr(line, 1, s - 1); incomment = 1; break }
        line = substr(line, 1, s - 1) substr(rest, e + 3)
      }
      if (fence_opens(line)) { fence = 1; next }
      if (line ~ /^## /) {
        section = (line ~ /^## Skills[ \t]*$/)
        if (section) found = 1
        next
      }
      if (section && line ~ /^[|][ \t]*`[^`]+`[ \t]*[|]/) {
        name = substr(line, index(line, "`") + 1)
        print substr(name, 1, index(name, "`") - 1)
      }
    }
    END { if (!found) print "#no-section" }
  ' "$agents")
  if printf '%s\n' "$listed" | grep -Fqx '#no-section'; then
    finding "AGENTS.md has no '## Skills' section"
    listed=""
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! printf '%s\n' "$listed" | grep -Fqx -- "$name"; then
      finding "skill '$name' is not listed in the '## Skills' table of AGENTS.md"
    fi
  done <<<"$skill_names"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! printf '%s' "$skill_names" | grep -Fqx -- "$name"; then
      finding "AGENTS.md lists skill '$name', but $skills_rel/$name does not exist"
    fi
  done <<<"$listed"
fi

if [ "$findings" -gt 0 ]; then
  echo "check-agent-files: $findings finding(s) in $root"
  exit 1
fi
echo "check-agent-files: OK, $skill_count skill(s) in $skills_rel, $link_count tool link(s), CLAUDE.md -> AGENTS.md"
exit 0
