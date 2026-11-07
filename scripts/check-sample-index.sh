#!/usr/bin/env bash
# Checks that every tracked sample is listed in the three index files every sample pull
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
#   - mkdocs.yml has exactly one page "- <Title>: <s>/README.md" (or a bare "- <path>",
#     which mkdocs also shows in the menu) in its nav: block, under a section heading
#     ("- <Section>:"). Each nav heading title holds the samples of one <section> folder,
#     each folder's samples sit under one heading title, and no heading title appears
#     twice under one parent.
#   - docs/ROADMAP.md has a list item linking ../examples/<s>/README.md.
#     Sample owners maintain readiness labels; this check does not require or interpret them.
#   - README.md at the top of the repository has a list item linking examples/<s>/README.md.
# A list item starts with "- ", indented at most three spaces, as in every index file here.
# A YAML comment (#), an HTML comment or a fenced code block does not count. It also checks
# that no "## " heading in README.md and no "### " heading in docs/ROADMAP.md appears
# twice, and that no tracked text file has a line starting with a conflict marker,
# "<<<<<<< " or ">>>>>>> ".
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
samples=$(git -C "$root" -c core.quotePath=false ls-files -- 'examples/*/*/README.md' 2>/dev/null) ||
  refuse "git ls-files failed in $root"
samples=$(printf '%s\n' "$samples" | awk -F/ 'NF == 4 && $4 == "README.md" { print $2 "/" $3 }')
[ -n "$samples" ] || refuse "no samples found under examples/<section>/<sample>/README.md"

findings=0
finding() {
  echo "FINDING: $*"
  findings=$((findings + 1))
}

# Prints a Markdown file with HTML comments removed and fenced code blocks blanked, line for
# line, so a commented-out entry or an example in a code block does not count. A fence
# closes only on the same character repeated at least as many times as it opened with, as
# in CommonMark (and as in check-agent-files.sh).
markdown_text() { # file
  awk '
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
    BEGIN { fence = 0; incomment = 0 }
    { sub(/\r$/, "") }
    fence {
      if (fence_closes($0)) fence = 0
      print ""
      next
    }
    {
      line = $0
      if (incomment) {
        e = index(line, "-->")
        if (e == 0) { print ""; next }
        line = substr(line, e + 3)
        incomment = 0
      }
      while ((s = index(line, "<!--")) > 0) {
        rest = substr(line, s + 4)
        e = index(rest, "-->")
        if (e == 0) { line = substr(line, 1, s - 1); incomment = 1; break }
        line = substr(line, 1, s - 1) substr(rest, e + 3)
      }
      if (fence_opens(line)) { fence = 1; print ""; next }
      print line
    }
  ' "$1"
}

# Prints one line per nav problem. Reads the sample list on standard input, then the
# top-level nav: block of mkdocs.yml, where a "- <Section>:" item is a heading and a
# "- <Title>: <path>" item is a page under the nearest heading indented less than it.
nav_problems() {
  printf '%s\n' "$samples" | awk '
    function unquote(s,   c) {
      c = substr(s, 1, 1)
      if ((c == "\"" || c == q) && length(s) >= 2 && substr(s, length(s), 1) == c)
        s = substr(s, 2, length(s) - 2)
      return s
    }
    # Drops a YAML comment: a "#" after a space or tab, outside quotes. Inside double
    # quotes a backslash escapes the next character; inside single quotes '' is a quote.
    function uncomment(s,   i, c, inq) {
      inq = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (inq == "\"" && c == "\\") { i++; continue }
        if (inq == q && c == q && substr(s, i + 1, 1) == q) { i++; continue }
        if (inq != "") { if (c == inq) inq = ""; continue }
        # A quote opens a quoted scalar only at its start, as in "Title": or : "path".
        if ((c == "\"" || c == q) && (i == 1 || substr(s, i - 2, 2) == ": ")) { inq = c; continue }
        if (c == "#" && i > 1 && substr(s, i - 1, 1) ~ /[ \t]/) return substr(s, 1, i - 1)
      }
      return s
    }
    BEGIN { q = sprintf("%c", 39); innav = 0; sawnav = 0; nh = 0; ns = 0; nhead = 0; nsec = 0; ndup = 0 }
    FNR == NR { if ($0 != "") { ns++; order[ns] = $0; is_sample[$0] = 1 }; next }
    { sub(/\r$/, "") }
    !innav { if ($0 ~ /^nav:[ \t]*(#.*)?$/) { innav = 1; sawnav = 1 }; next }
    /^[^ \t#-]/ { innav = 0; next } # the next top-level key ends the nav
    {
      match($0, /^[ \t]*/)
      ind = RLENGTH
      rest = substr($0, ind + 1)
      if (substr(rest, 1, 2) != "- ") next # also skips a whole-line comment, "# - ..."
      rest = uncomment(substr(rest, 3))
      sub(/[ \t]+$/, "", rest)
      while (nh > 0 && hind[nh] >= ind) nh--
      if (rest ~ /:$/) {
        nh++
        hind[nh] = ind
        hline[nh] = FNR
        htitle[nh] = unquote(substr(rest, 1, length(rest) - 1))
        # Two headings with one title under one parent: what a keep-both merge leaves
        # when two pull requests each added the section.
        k = (nh > 1 ? hline[nh - 1] : 0) SUBSEP htitle[nh]
        if (k in hfirst) {
          if (!(k in hdup)) { ndup++; duporder[ndup] = k; hdup[k] = htitle[nh] }
          hlines[k] = hlines[k] ", " FNR
        } else { hfirst[k] = FNR; hlines[k] = FNR }
        next
      }
      path = rest
      for (i = length(rest) - 1; i > 0; i--)
        if (substr(rest, i, 2) == ": ") { path = substr(rest, i + 2); break }
      path = unquote(path)
      if (length(path) <= 10 || substr(path, length(path) - 9) != "/README.md") next
      s = substr(path, 1, length(path) - 10)
      if (!(s in is_sample)) next
      n[s]++
      h = (nh > 0 ? htitle[nh] : "")
      head[s] = h
      if (h == "") next
      sec = s
      sub(/\/.*/, "", sec)
      if ((h SUBSEP sec) in pair) next
      pair[h, sec] = 1
      if (!(h in hcount)) { nhead++; horder[nhead] = h; hsecs[h] = sec }
      else hsecs[h] = hsecs[h] ", " sec
      hcount[h]++
      if (!(sec in scount)) { nsec++; sorder[nsec] = sec; sheads[sec] = q h q }
      else sheads[sec] = sheads[sec] ", " q h q
      scount[sec]++
    }
    END {
      if (!sawnav) { print "mkdocs.yml has no top-level nav: block"; exit 0 }
      for (i = 1; i <= ndup; i++)
        print "mkdocs.yml nav has the heading " q hdup[duporder[i]] q " more than once (lines " hlines[duporder[i]] "); merge them into one"
      for (i = 1; i <= ns; i++) {
        s = order[i]
        if (!(s in n))
          print s " is not in the mkdocs.yml nav; add " q "- <Title>: " s "/README.md" q " under its section heading"
        else if (n[s] > 1) print s " is in the mkdocs.yml nav " n[s] " times; keep one entry"
        else if (head[s] == "") print s " is in the mkdocs.yml nav but not under a section heading"
      }
      for (i = 1; i <= nhead; i++)
        if (hcount[horder[i]] > 1)
          print "mkdocs.yml nav heading " q horder[i] q " holds samples from more than one section folder: " hsecs[horder[i]]
      for (i = 1; i <= nsec; i++)
        if (scount[sorder[i]] > 1)
          print "the " sorder[i] "/ samples are under more than one mkdocs.yml nav heading: " sheads[sorder[i]]
    }
  ' - "$root/mkdocs.yml"
}

# 0 when docs/ROADMAP.md has a list item linking this sample, regardless of readiness labels.
in_roadmap() { # sample
  markdown_text "$root/docs/ROADMAP.md" | awk -v link="](../examples/$1/README.md)" '
    /^ ? ? ?- / && index($0, link) > 0 { found = 1; exit }
    END { exit (found ? 0 : 1) }
  '
}

# 0 when the root README.md has a list item linking this sample.
in_readme() { # sample
  markdown_text "$root/README.md" | awk -v link="](examples/$1/README.md)" '
    /^ ? ? ?- / && index($0, link) > 0 { found = 1; exit }
    END { exit (found ? 0 : 1) }
  '
}

# Prints one line per heading of one level that appears more than once in a Markdown
# file: what a keep-both merge leaves when two pull requests each added the section.
duplicate_headings() { # file marker ("## " or "### ")
  markdown_text "$root/$1" | awk -v marker="$2" -v file="$1" '
    BEGIN { q = sprintf("%c", 39); nd = 0 }
    { sub(/[ \t]+$/, "") }
    substr($0, 1, length(marker)) == marker {
      if ($0 in first) {
        if (!($0 in dup)) { nd++; order[nd] = $0; dup[$0] = first[$0] }
        dup[$0] = dup[$0] ", " FNR
      } else first[$0] = FNR
    }
    END {
      for (i = 1; i <= nd; i++)
        print file " has the heading " q order[i] q " more than once (lines " dup[order[i]] "); merge them into one"
    }
  '
}

emit() { # lines -> one finding each
  while IFS= read -r m; do
    [ -z "$m" ] || finding "$m"
  done <<<"$1"
}

if navout=$(nav_problems); then
  emit "$navout"
else
  finding "could not read the mkdocs.yml nav (awk exit $?)"
fi
if dupout=$(duplicate_headings README.md '## '); then
  emit "$dupout"
else
  finding "could not read the README.md headings (awk exit $?)"
fi
if dupout=$(duplicate_headings docs/ROADMAP.md '### '); then
  emit "$dupout"
else
  finding "could not read the docs/ROADMAP.md headings (awk exit $?)"
fi

count=0
while IFS= read -r s; do
  [ -n "$s" ] || continue
  count=$((count + 1))
  in_roadmap "$s" ||
    finding "$s is not linked in docs/ROADMAP.md; link its entry to ../examples/$s/README.md"
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
