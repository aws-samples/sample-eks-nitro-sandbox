#!/usr/bin/env bash
# Checks that every published sample is listed in the three index files every sample pull
# request edits, and that no merge conflict markers are left in tracked text files. Needs no
# cluster and no AWS.
#
# Usage: scripts/check-sample-index.sh [REPO_ROOT]
#   REPO_ROOT defaults to the git work tree this script lives in.
#
# Exit codes:
#   0  clean
#   1  at least one finding (each is printed as one FINDING: line)
#   2  refused to run, so nothing was checked
#
# A sample is a tracked examples/<section>/<sample>/README.md, exactly two folders below
# examples/ (a README.md deeper inside a sample, such as an app's, is not a sample). For
# each sample <s> = <section>/<sample> it checks:
#   - mkdocs.yml has a nav entry "- <Title>: <s>/README.md".
#   - docs/ROADMAP.md has a list item linking ../examples/<s>/README.md, marked
#     "(available now)" on that line or in the "### " heading of the section it is under.
#   - README.md at the top of the repository has a list item linking examples/<s>/README.md.
# A line in a YAML comment (#) or an HTML comment does not count. It also checks that no
# tracked text file has a line starting with a conflict marker, "<<<<<<< " or ">>>>>>> ".
#
# Written for bash 3.2 and POSIX awk, so it runs on macOS as well as Linux.

set -u

refuse() {
  echo "check-sample-index: refused: $*" >&2
  echo "check-sample-index: nothing was checked" >&2
  exit 2
}

if [ "$#" -gt 1 ]; then
  refuse "expected at most one argument, REPO_ROOT"
fi
case "${1:-}" in
  -*) refuse "unknown option: $1 (usage: $0 [REPO_ROOT])" ;;
esac

for cmd in git awk grep; do
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

for f in mkdocs.yml docs/ROADMAP.md README.md; do
  [ -f "$root/$f" ] || refuse "missing $f"
done

# Everything that can refuse runs before the first check, so exit 2 always means that
# nothing was checked.
samples=$(git -C "$root" ls-files -- 'examples/*/*/README.md' 2>/dev/null) ||
  refuse "git ls-files failed in $root"
samples=$(printf '%s\n' "$samples" | awk -F/ 'NF == 4 && $4 == "README.md" { print $2 "/" $3 }')
[ -n "$samples" ] || refuse "no samples found under examples/<section>/<sample>/README.md"

findings=0
finding() {
  echo "FINDING: $*"
  findings=$((findings + 1))
}

# Prints the file with HTML comments removed, so a commented-out entry does not count.
strip_html_comments() {
  awk '
    BEGIN { incomment = 0 }
    { sub(/\r$/, ""); line = $0
      if (incomment) {
        e = index(line, "-->")
        if (e == 0) { print ""; next }
        line = substr(line, e + 3); incomment = 0
      }
      while ((s = index(line, "<!--")) > 0) {
        rest = substr(line, s + 4); e = index(rest, "-->")
        if (e == 0) { line = substr(line, 1, s - 1); incomment = 1; break }
        line = substr(line, 1, s - 1) substr(rest, e + 3)
      }
      print line
    }
  ' "$1"
}

# 0 when mkdocs.yml has "- <Title>: <path>" for this path, outside a YAML comment.
in_nav() { # path
  awk -v want="$1" '
    { sub(/\r$/, "") }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (substr(line, 1, 2) != "- ") next # also skips a whole-line comment, "# - ..."
      sub(/[ \t]+#.*$/, "", line)
      sub(/[ \t]+$/, "", line)
      n = length(line); w = length(want)
      if (n > w + 2 && substr(line, n - w - 1) == ": " want) { found = 1; exit }
    }
    END { exit (found ? 0 : 1) }
  ' "$root/mkdocs.yml"
}

# Prints "linked", "available" (linked and marked available now) or nothing, for the
# roadmap list item that links this sample.
roadmap_state() { # sample
  strip_html_comments "$root/docs/ROADMAP.md" | awk -v link="](../examples/$1/README.md)" '
    /^### / { heading = $0; next }
    /^[ \t]*- / && index($0, link) > 0 {
      if (index($0, "(available now)") > 0 || index(heading, "available now") > 0) { state = "available" }
      else if (state == "") { state = "linked" }
    }
    END { if (state != "") print state }
  '
}

# 0 when the root README.md has a list item linking this sample.
in_readme() { # sample
  strip_html_comments "$root/README.md" | awk -v link="](examples/$1/README.md)" '
    /^[ \t]*- / && index($0, link) > 0 { found = 1; exit }
    END { exit (found ? 0 : 1) }
  '
}

count=0
while IFS= read -r s; do
  [ -n "$s" ] || continue
  count=$((count + 1))
  in_nav "$s/README.md" ||
    finding "$s is not in the mkdocs.yml nav; add '- <Title>: $s/README.md' under its section heading"
  case "$(roadmap_state "$s")" in
    available) ;;
    linked) finding "$s is linked in docs/ROADMAP.md but not marked '(available now)'" ;;
    *) finding "$s is not linked in docs/ROADMAP.md; link its entry to ../examples/$s/README.md and mark it '(available now)'" ;;
  esac
  in_readme "$s" ||
    finding "$s is not listed in README.md; add '- [<Title>](examples/$s/README.md): <one line>' under its section heading"
done <<<"$samples"

# Conflict markers: anchored at the start of a line, in tracked text files only.
markers=$(git -C "$root" grep -n -I -E '^(<<<<<<<|>>>>>>>)( |$)' 2>/dev/null)
rc=$?
if [ "$rc" -gt 1 ]; then
  finding "could not search tracked files for conflict markers (git grep exit $rc)"
elif [ -n "$markers" ]; then
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    finding "merge conflict marker left at ${m%%:*}:$(printf '%s' "$m" | cut -d: -f2)"
  done <<<"$markers"
fi

if [ "$findings" -gt 0 ]; then
  echo "check-sample-index: $findings finding(s) in $root"
  exit 1
fi
echo "check-sample-index: OK, $count sample(s) in the nav, the roadmap and README.md, no conflict markers"
exit 0
