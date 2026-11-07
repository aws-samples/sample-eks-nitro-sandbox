#!/usr/bin/env bash
# Tests check-sample-index.sh both ways, on throwaway git repositories in a temporary
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
# Usage: scripts/test-check-sample-index.sh     Exit: 0 all passed, 1 a test failed.

set -u

here=$(cd -P "$(dirname "$0")" && pwd -P)
CHECK="$here/check-sample-index.sh"
[ -x "$CHECK" ] || { echo "not executable: $CHECK" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/check-sample-index-test.XXXXXX") || exit 1
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

passed=0
failed=0
check_cmd=$CHECK # the copy under test; two cases run a copy placed elsewhere
want_stderr=     # set by the one case where the check is expected to write to stderr

# --- fixtures ---------------------------------------------------------------------------

# The layout the check must accept: two samples in two sections, one marked available in
# its roadmap heading and one on its own line, a README.md deeper inside a sample (not a
# sample), and the site home page examples/README.md (not a sample either).
new_repo() { # name -> prints the repo path
  local d="$work/$1"
  mkdir -p "$d/docs" "$d/examples/getting-started/hello" "$d/examples/policy/signing/app"
  git -C "$d" init -q
  printf '# Hello\n' >"$d/examples/getting-started/hello/README.md"
  printf '# Signing\n' >"$d/examples/policy/signing/README.md"
  printf '# The app inside the signing sample\n' >"$d/examples/policy/signing/app/README.md"
  printf '# Home\n' >"$d/examples/README.md"
  cat >"$d/mkdocs.yml" <<'EOF'
site_name: Test
docs_dir: examples
nav:
  - Home: README.md
  - Getting started:
      - Hello: getting-started/hello/README.md
  - Policy:
      - Signing: policy/signing/README.md
EOF
  cat >"$d/docs/ROADMAP.md" <<'EOF'
# Roadmap

## Planned samples by section

### Getting started (`getting-started`, available now)

- [hello](../examples/getting-started/hello/README.md): the first sample.

### Policy (`policy`)

Policy samples.

- [signing](../examples/policy/signing/README.md) (available now): a signed image.
- planned-one: not written yet.
EOF
  cat >"$d/README.md" <<'EOF'
# Samples

## Getting started

- [Hello](examples/getting-started/hello/README.md): the first sample.

## Policy

- [Signing](examples/policy/signing/README.md): a signed image.
EOF
  git -C "$d" add -A
  printf '%s\n' "$d"
}

# Replace the first line matching a fixed string in a file with the given lines (none to
# delete it). Plain shell rather than awk -v, which some awks refuse for multi-line values.
# Stops the whole test when no line matches, so a case cannot pass on an unchanged fixture.
replace_line() { # file match line...
  local f=$1 match=$2 line done=0
  shift 2
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"$match"*)
        if [ "$done" -eq 0 ]; then
          done=1
          [ "$#" -gt 0 ] && printf '%s\n' "$@"
          continue
        fi ;;
    esac
    printf '%s\n' "$line"
  done <"$f" >"$f.new" || { echo "fixture error: cannot rewrite $f" >&2; exit 1; }
  if [ "$done" -eq 0 ]; then
    echo "fixture error: no line in $f matches: $match" >&2
    exit 1
  fi
  mv "$f.new" "$f"
}

# Append lines to a file.
append_lines() { # file line...
  local f=$1
  shift
  printf '%s\n' "$@" >>"$f"
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
  elif ! tail -n 1 "$work/out" | grep -q '^check-sample-index: OK, '; then report_fail "$label: no OK footer"
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
  if [ -n "$want_stderr" ]; then
    if ! grep -Fq -- "$want_stderr" "$work/err"; then report_fail "$label: stderr lacks: $want_stderr"; return; fi
  elif [ -s "$work/err" ]; then report_fail "$label: wrote to stderr"; return; fi
  if ! tail -n 1 "$work/out" | grep -q "^check-sample-index: $# finding(s) in "; then
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
  elif ! grep -q '^check-sample-index: refused: ' "$work/err"; then report_fail "$label: no refusal line"
  elif ! grep -Fq -- "$text" "$work/err"; then report_fail "$label: refusal lacks: $text"
  elif ! grep -q '^check-sample-index: nothing was checked$' "$work/err"; then report_fail "$label: no 'nothing was checked'"
  else pass "$label"
  fi
}

# --- must accept -------------------------------------------------------------------------

d=$(new_repo accept-plain)
expect_ok "accept: the plain layout" "OK, 2 sample(s)" "$d"

d=$(new_repo "accept with spaces")
expect_ok "accept: a repository path with spaces" "OK, 2 sample(s)" "$d"

d=$(new_repo accept-untracked-sample)
mkdir -p "$d/examples/policy/draft"
printf '# Draft, not added to git yet\n' >"$d/examples/policy/draft/README.md"
expect_ok "accept: an untracked sample folder is not a sample yet" "OK, 2 sample(s)" "$d"

d=$(new_repo accept-nav-trailing-comment)
replace_line "$d/mkdocs.yml" "Signing: policy" "      - Signing: policy/signing/README.md  # added by #55"
expect_ok "accept: a nav entry with a YAML comment after it" "OK, 2 sample(s)" "$d"

d=$(new_repo accept-crlf)
for f in mkdocs.yml docs/ROADMAP.md README.md; do
  awk '{ printf "%s\r\n", $0 }' "$d/$f" >"$d/$f.new" && mv "$d/$f.new" "$d/$f"
done
expect_ok "accept: CRLF line endings in all three index files" "OK, 2 sample(s)" "$d"

d=$(new_repo accept-marker-lookalikes)
cat >"$d/CONTRIBUTING.md" <<'EOF'
# Contributing

Resolving a conflict
====================

Git writes `<<<<<<< HEAD` and `>>>>>>> origin/main` around a conflict; delete both.
    <<<<<<< HEAD (an indented example is not at the start of a line)
<<<<<<<< eight is not a marker
EOF
git -C "$d" add CONTRIBUTING.md
printf '<<<<<<< HEAD\n' >"$d/untracked-notes.txt"
expect_ok "accept: marker text inside a line, an ===== underline, and an untracked file" "no conflict markers" "$d"

d=$(new_repo accept-nav-forms)
cat >"$d/mkdocs.yml" <<'EOF'
site_name: Test
nav:
- Home: README.md
- "Getting started":
  - "Hello: the first one": getting-started/hello/README.md
- Policy:  # one section
  - Signing: "policy/signing/README.md"
markdown_extensions:
  - toc:
      permalink: true
EOF
git -C "$d" add mkdocs.yml
expect_ok "accept: a nav at column 0, quoted titles and paths, a title with ': ', a key after it" \
  "OK, 2 sample(s)" "$d"

d=$(new_repo accept-nav-titles)
replace_line "$d/mkdocs.yml" "Hello: getting-started" \
  "      - Hello, it's here: getting-started/hello/README.md  # an apostrophe, then a comment"
replace_line "$d/mkdocs.yml" "Signing: policy" "      - \"Signing #1\": policy/signing/README.md"
expect_ok "accept: an apostrophe inside a title, and ' #' inside a quoted title" "OK, 2 sample(s)" "$d"

d=$(new_repo accept-nav-escaped-quotes)
replace_line "$d/mkdocs.yml" "Hello: getting-started" \
  "      - 'It''s # one': getting-started/hello/README.md  # a doubled single quote"
replace_line "$d/mkdocs.yml" "Signing: policy" \
  "      - \"A \\\" # b\": policy/signing/README.md  # an escaped double quote"
expect_ok "accept: ' #' after an escaped quote inside a quoted title" "OK, 2 sample(s)" "$d"

d=$(new_repo accept-nav-bare-path)
replace_line "$d/mkdocs.yml" "Signing: policy" "      - policy/signing/README.md"
expect_ok "accept: a nav page given as a bare path, which mkdocs also lists" "OK, 2 sample(s)" "$d"

d=$(new_repo accept-entry-after-nested-fence)
replace_line "$d/README.md" "](examples/policy/signing/README.md)" \
  '````markdown' '```' '## Policy' '- [Example](examples/policy/example/README.md): an example.' '```' '````' \
  "- [Signing](examples/policy/signing/README.md): a signed image."
replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
  '~~~text' '```' '~~~' \
  "- [signing](../examples/policy/signing/README.md) (available now): a signed image."
expect_ok "accept: an entry after a fence that holds a shorter fence or the other fence character" \
  "OK, 2 sample(s)" "$d"

d=$(new_repo accept-default-root)
mkdir -p "$d/scripts"
cp "$CHECK" "$d/scripts/check-sample-index.sh"
check_cmd="$d/scripts/check-sample-index.sh"
expect_ok "accept: no argument checks the repo the script is in" "OK, 2 sample(s)"
check_cmd=$CHECK

# --- must reject: mkdocs.yml ---------------------------------------------------------------

d=$(new_repo reject-no-nav)
replace_line "$d/mkdocs.yml" "Signing: policy"
expect_findings "reject: a sample with no nav entry" "$d" "policy/signing is not in the mkdocs.yml nav"

d=$(new_repo reject-nav-in-comment)
replace_line "$d/mkdocs.yml" "Signing: policy" "      # - Signing: policy/signing/README.md"
expect_findings "reject: a nav entry only in a YAML comment" "$d" "policy/signing is not in the mkdocs.yml nav"

d=$(new_repo reject-nav-after-comment)
replace_line "$d/mkdocs.yml" "Signing: policy" "      - Old: legacy.md  # was - Signing: policy/signing/README.md"
expect_findings "reject: a nav path only in the comment after another entry" "$d" \
  "policy/signing is not in the mkdocs.yml nav"

d=$(new_repo reject-nav-outside-nav)
replace_line "$d/mkdocs.yml" "Signing: policy"
append_lines "$d/mkdocs.yml" "extra:" "  pages:" "    - Signing: policy/signing/README.md"
expect_findings "reject: a nav-like line after the nav block has ended" "$d" \
  "policy/signing is not in the mkdocs.yml nav"

d=$(new_repo reject-no-nav-block)
replace_line "$d/mkdocs.yml" "nav:" "plugins:"
expect_findings "reject: no nav: block at all" "$d" "mkdocs.yml has no top-level nav: block"

d=$(new_repo reject-nav-top-level)
replace_line "$d/mkdocs.yml" "Signing: policy"
replace_line "$d/mkdocs.yml" "Home: README.md" "  - Home: README.md" "  - Signing: policy/signing/README.md"
expect_findings "reject: a sample in the nav but not under a section heading" "$d" \
  "policy/signing is in the mkdocs.yml nav but not under a section heading"

d=$(new_repo reject-nav-top-level-after-section)
replace_line "$d/mkdocs.yml" "Signing: policy" "  - Signing: policy/signing/README.md"
expect_findings "reject: a top-level nav page after the last section, not inside it" "$d" \
  "policy/signing is in the mkdocs.yml nav but not under a section heading"

d=$(new_repo reject-nav-duplicate)
replace_line "$d/mkdocs.yml" "Signing: policy" \
  "      - Signing: policy/signing/README.md" "      - Signing: policy/signing/README.md"
expect_findings "reject: the same nav entry twice, as a keep-both merge can leave it" "$d" \
  "policy/signing is in the mkdocs.yml nav 2 times"

d=$(new_repo reject-nav-wrong-heading)
mkdir -p "$d/examples/policy/cedar"
printf '# Cedar\n' >"$d/examples/policy/cedar/README.md"
git -C "$d" add examples/policy/cedar/README.md
replace_line "$d/mkdocs.yml" "Signing: policy" "      - Cedar: policy/cedar/README.md"
replace_line "$d/mkdocs.yml" "Hello: getting-started" \
  "      - Hello: getting-started/hello/README.md" "      - Signing: policy/signing/README.md"
append_lines "$d/docs/ROADMAP.md" "- [cedar](../examples/policy/cedar/README.md) (available now): a Cedar policy."
append_lines "$d/README.md" "- [Cedar](examples/policy/cedar/README.md): a Cedar policy."
expect_findings "reject: a sample under another section's nav heading" "$d" \
  "mkdocs.yml nav heading 'Getting started' holds samples from more than one section folder: getting-started, policy" \
  "the policy/ samples are under more than one mkdocs.yml nav heading: 'Getting started', 'Policy'"

d=$(new_repo reject-nav-heading-twice)
mkdir -p "$d/examples/policy/cedar"
printf '# Cedar\n' >"$d/examples/policy/cedar/README.md"
git -C "$d" add examples/policy/cedar/README.md
append_lines "$d/mkdocs.yml" "  - Policy:" "      - Cedar: policy/cedar/README.md"
append_lines "$d/docs/ROADMAP.md" "- [cedar](../examples/policy/cedar/README.md) (available now): a Cedar policy."
append_lines "$d/README.md" "- [Cedar](examples/policy/cedar/README.md): a Cedar policy."
expect_findings "reject: one nav heading twice, as a keep-both merge of two new sections leaves it" "$d" \
  "mkdocs.yml nav has the heading 'Policy' more than once (lines 7, 9)"

d=$(new_repo reject-nav-other-path)
replace_line "$d/mkdocs.yml" "Signing: policy" "      - Signing: old/policy/signing/README.md"
expect_findings "reject: a nav entry for a longer path that ends the same way" "$d" \
  "policy/signing is not in the mkdocs.yml nav"

# --- must reject: docs/ROADMAP.md ----------------------------------------------------------

d=$(new_repo reject-no-roadmap-link)
replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" "- signing: not linked."
expect_findings "reject: a roadmap entry that does not link the sample" "$d" \
  "policy/signing is not linked in docs/ROADMAP.md"

d=$(new_repo reject-roadmap-not-available)
replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
  "- [signing](../examples/policy/signing/README.md): a signed image."
expect_findings "reject: a roadmap link with no '(available now)'" "$d" \
  "policy/signing is linked in docs/ROADMAP.md but not marked '(available now)'"

d=$(new_repo reject-heading-not-available)
replace_line "$d/docs/ROADMAP.md" "### Getting started" "### Getting started (\`getting-started\`)"
expect_findings "reject: the section heading lost 'available now'" "$d" \
  "getting-started/hello is linked in docs/ROADMAP.md but not marked '(available now)'"

d=$(new_repo reject-roadmap-in-comment)
replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
  "<!--" "- [signing](../examples/policy/signing/README.md) (available now): a signed image." "-->"
expect_findings "reject: a roadmap link only inside a multi-line HTML comment" "$d" \
  "policy/signing is not linked in docs/ROADMAP.md"

d=$(new_repo reject-roadmap-in-fence)
replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
  '~~~' "- [signing](../examples/policy/signing/README.md) (available now): a signed image." '~~~'
expect_findings "reject: a roadmap link only inside a fenced code block" "$d" \
  "policy/signing is not linked in docs/ROADMAP.md"

d=$(new_repo reject-roadmap-indented-code)
replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
  "    - [signing](../examples/policy/signing/README.md) (available now): indented four spaces, so code."
expect_findings "reject: a roadmap entry indented as code" "$d" \
  "policy/signing is not linked in docs/ROADMAP.md"

d=$(new_repo reject-roadmap-heading-twice)
append_lines "$d/docs/ROADMAP.md" "" "### Policy (\`policy\`)"
expect_findings "reject: a roadmap section heading twice" "$d" \
  "docs/ROADMAP.md has the heading '### Policy (\`policy\`)' more than once (lines 9, 16)"

d=$(new_repo reject-heading-ends-at-h2)
replace_line "$d/docs/ROADMAP.md" "](../examples/getting-started/hello/README.md)" \
  "## Elsewhere" "" "- [hello](../examples/getting-started/hello/README.md): the first sample."
expect_findings "reject: a '## ' heading ends the available '### ' section" "$d" \
  "getting-started/hello is linked in docs/ROADMAP.md but not marked '(available now)'"

# --- explicit draft status -----------------------------------------------------------------

# A draft is still a tracked sample. Its entry must remain in all three indexes.
# Only a visible status immediately after its own roadmap link opts into draft status.
d=$(new_repo accept-explicit-draft)
replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
  "- [signing](../examples/policy/signing/README.md) (draft): a sample awaiting a maintainer decision."
expect_ok "accept: an explicit draft remains indexed without claiming availability" "OK, 2 sample(s)" "$d"

d=$(new_repo accept-draft-overrides-heading)
replace_line "$d/docs/ROADMAP.md" "](../examples/getting-started/hello/README.md)" \
  "- [hello](../examples/getting-started/hello/README.md) (draft): an unfinished sample."
expect_ok "accept: per-entry draft overrides inherited availability" "OK, 2 sample(s)" "$d"

d=$(new_repo accept-spaced-draft)
spaced="- [signing](../examples/policy/signing/README.md)$(printf '\t  ')(draft)$(printf '\t '): an unfinished sample."
replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" "$spaced"
expect_ok "accept: spaces and tabs around the explicit draft marker" "OK, 2 sample(s)" "$d"

d=$(new_repo accept-consistent-draft-entries)
replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
  "- [signing](../examples/policy/signing/README.md) (draft): an unfinished sample."
append_lines "$d/docs/ROADMAP.md" "- [signing](../examples/policy/signing/README.md) (draft): the same status."
expect_ok "accept: repeated roadmap entries with the same explicit draft status" "OK, 2 sample(s)" "$d"

# Repeated entries may inherit availability from their section. Only an explicit
# available status conflicts with an explicit draft, regardless of entry order.
for first in inherited draft; do
  d=$(new_repo "accept-draft-overrides-duplicate-$first")
  if [ "$first" = inherited ]; then
    first_status=''
    second_status=' (draft)'
  else
    first_status=' (draft)'
    second_status=''
  fi
  replace_line "$d/docs/ROADMAP.md" "](../examples/getting-started/hello/README.md)" \
    "- [hello](../examples/getting-started/hello/README.md)$first_status: the first entry." \
    "- [hello](../examples/getting-started/hello/README.md)$second_status: the repeated entry."
  expect_ok "accept: explicit draft overrides duplicate inherited availability with $first first" "OK, 2 sample(s)" "$d"
done

for ending in '' ' unfinished'; do
  d=$(new_repo "accept-draft-boundary-$passed")
  replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
    "- [signing](../examples/policy/signing/README.md) (draft)$ending"
  expect_ok "accept: draft marker followed by end of line or whitespace: '$ending'" "OK, 2 sample(s)" "$d"
done

# A whole link and status inside inline code cannot count as a visible entry.
# A code example before a real link must neither supply nor hide that link's status.
for ticks in '`' '``'; do
  d=$(new_repo "reject-draft-whole-inline-code-$passed")
  replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
    "- ${ticks}[signing](../examples/policy/signing/README.md) (draft): a code example.${ticks}"
  expect_findings "reject: a whole draft entry inside $ticks inline code" "$d" \
    "policy/signing is not linked in docs/ROADMAP.md"

  d=$(new_repo "reject-draft-code-before-visible-$passed")
  replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
    "- ${ticks}[signing](../examples/policy/signing/README.md) (draft): a code example.${ticks} Actual [signing](../examples/policy/signing/README.md): no status."
  expect_findings "reject: $ticks code example cannot supply the visible link's draft status" "$d" \
    "policy/signing is linked in docs/ROADMAP.md but not marked '(available now)' or '(draft)'"

  d=$(new_repo "accept-draft-after-inline-code-$passed")
  replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
    "- ${ticks}[signing](../examples/policy/signing/README.md): a code example.${ticks} Actual [signing](../examples/policy/signing/README.md) (draft): unfinished."
  expect_ok "accept: a visible draft link after a $ticks code example" "OK, 2 sample(s)" "$d"
done

d=$(new_repo reject-draft-inline-code-gap)
replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
  '- [signing](../examples/policy/signing/README.md) `example` (draft): the marker is not immediate.'
expect_findings "reject: removing inline code must not join a link to a later draft marker" "$d" \
  "policy/signing is linked in docs/ROADMAP.md but not marked '(available now)' or '(draft)'"

for ticks in '`' '``'; do
  d=$(new_repo "reject-draft-mismatched-inner-delimiter-$passed")
  if [ "$ticks" = '`' ]; then inner='``'; else inner='`'; fi
  replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
    "- ${ticks}example ${inner} [signing](../examples/policy/signing/README.md) (draft)${ticks} Actual [signing](../examples/policy/signing/README.md): no status."
  expect_findings "reject: $inner does not close a $ticks code span containing a draft example" "$d" \
    "policy/signing is linked in docs/ROADMAP.md but not marked '(available now)' or '(draft)'"
done

d=$(new_repo accept-draft-after-unmatched-backtick)
replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
  '- unmatched ` text [signing](../examples/policy/signing/README.md) (draft): unfinished.'
expect_ok "accept: an unmatched backtick does not hide a visible draft link" "OK, 2 sample(s)" "$d"

d=$(new_repo accept-draft-with-escaped-backticks)
replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
  '- \`[signing](../examples/policy/signing/README.md) (draft): literal delimiters.\`'
expect_ok "accept: escaped backticks do not hide a visible draft link" "OK, 2 sample(s)" "$d"

for status in '(drafting)' '(draft)extra' ': the description mentions (draft).' '`(draft)`'; do
  d=$(new_repo "reject-nonstatus-$passed")
  replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
    "- [signing](../examples/policy/signing/README.md) $status"
  expect_findings "reject: text that is not an explicit draft status: $status" "$d" \
    "policy/signing is linked in docs/ROADMAP.md but not marked '(available now)' or '(draft)'"
done

d=$(new_repo reject-draft-heading-only)
replace_line "$d/docs/ROADMAP.md" '### Policy' '### Policy (`policy`) (draft)'
replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
  "- [signing](../examples/policy/signing/README.md): an unfinished sample."
expect_findings "reject: a draft heading cannot mark every sample as draft" "$d" \
  "policy/signing is linked in docs/ROADMAP.md but not marked '(available now)' or '(draft)'"

d=$(new_repo reject-draft-readme-only)
append_lines "$d/examples/policy/signing/README.md" "" "Status: draft."
replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
  "- [signing](../examples/policy/signing/README.md): an unfinished sample."
expect_findings "reject: README draft prose cannot supply a roadmap status" "$d" \
  "policy/signing is linked in docs/ROADMAP.md but not marked '(available now)' or '(draft)'"

d=$(new_repo reject-draft-inline-comment)
replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
  "- [signing](../examples/policy/signing/README.md) <!-- (draft) -->: an unfinished sample."
expect_findings "reject: a draft marker hidden in an inline HTML comment" "$d" \
  "policy/signing is linked in docs/ROADMAP.md but not marked '(available now)' or '(draft)'"

for hidden in comment fence; do
  d=$(new_repo "reject-draft-$hidden")
  if [ "$hidden" = comment ]; then
    opener='<!--'
    closer='-->'
  else
    opener='```markdown'
    closer='```'
  fi
  replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
    "$opener" "- [signing](../examples/policy/signing/README.md) (draft): a hidden entry." "$closer" \
    "- [signing](../examples/policy/signing/README.md): the visible entry has no status."
  expect_findings "reject: a hidden draft entry in a $hidden cannot supply status" "$d" \
    "policy/signing is linked in docs/ROADMAP.md but not marked '(available now)' or '(draft)'"
done

for statuses in '(available now) (draft)' '(draft) (available now)'; do
  d=$(new_repo "reject-conflicting-status-line-$passed")
  replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
    "- [signing](../examples/policy/signing/README.md) $statuses: conflicting statuses."
  expect_findings "reject: both explicit statuses on one line: $statuses" "$d" \
    "policy/signing has conflicting '(available now)' and '(draft)' statuses in docs/ROADMAP.md"
done

for first in available draft; do
  d=$(new_repo "reject-conflicting-status-entries-$first")
  if [ "$first" = available ]; then
    first_status='(available now)'
    second_status='(draft)'
  else
    first_status='(draft)'
    second_status='(available now)'
  fi
  replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
    "- [signing](../examples/policy/signing/README.md) $first_status: the first entry."
  append_lines "$d/docs/ROADMAP.md" \
    "- [signing](../examples/policy/signing/README.md) $second_status: the conflicting entry."
  expect_findings "reject: conflicting duplicate entries with $first first" "$d" \
    "policy/signing has conflicting '(available now)' and '(draft)' statuses in docs/ROADMAP.md"
done

for missing in nav readme roadmap-link; do
  d=$(new_repo "reject-draft-missing-$missing")
  replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
    "- [signing](../examples/policy/signing/README.md) (draft): an unfinished sample."
  case "$missing" in
    nav)
      replace_line "$d/mkdocs.yml" "Signing: policy"
      expected="policy/signing is not in the mkdocs.yml nav"
      ;;
    readme)
      replace_line "$d/README.md" "](examples/policy/signing/README.md)"
      expected="policy/signing is not listed in README.md"
      ;;
    roadmap-link)
      replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" "- signing (draft): no link."
      expected="policy/signing is not linked in docs/ROADMAP.md"
      ;;
  esac
  expect_findings "reject: draft status does not waive the $missing requirement" "$d" "$expected"
done

d=$(new_repo reject-draft-conflict-marker)
replace_line "$d/docs/ROADMAP.md" "](../examples/policy/signing/README.md)" \
  "- [signing](../examples/policy/signing/README.md) (draft): an unfinished sample."
append_lines "$d/examples/policy/signing/README.md" '<<<<<<< HEAD'
expect_findings "reject: conflict markers remain errors inside a draft sample" "$d" \
  "merge conflict marker left at examples/policy/signing/README.md:2"

# --- must reject: README.md ----------------------------------------------------------------

d=$(new_repo reject-readme-in-fence)
replace_line "$d/README.md" "](examples/policy/signing/README.md)" \
  '```markdown' "- [Signing](examples/policy/signing/README.md): a signed image." '```'
expect_findings "reject: a README.md entry only inside a fenced code block" "$d" \
  "policy/signing is not listed in README.md"

d=$(new_repo reject-readme-heading-twice)
append_lines "$d/README.md" "## Policy"
expect_findings "reject: a README.md section heading twice" "$d" \
  "README.md has the heading '## Policy' more than once (lines 7, 10)"

d=$(new_repo reject-readme-indented-code)
replace_line "$d/README.md" "](examples/policy/signing/README.md)" \
  "    - [Signing](examples/policy/signing/README.md): indented four spaces, so code."
expect_findings "reject: a README.md entry indented as code" "$d" \
  "policy/signing is not listed in README.md"

d=$(new_repo reject-readme-in-long-fence)
replace_line "$d/README.md" "](examples/policy/signing/README.md)" \
  '````markdown' '```' "- [Signing](examples/policy/signing/README.md): a signed image." '````'
expect_findings "reject: an entry inside a four-backtick fence, after a three-backtick line" "$d" \
  "policy/signing is not listed in README.md"

d=$(new_repo reject-no-readme)
replace_line "$d/README.md" "](examples/policy/signing/README.md)"
expect_findings "reject: a sample missing from README.md" "$d" "policy/signing is not listed in README.md"

d=$(new_repo reject-readme-in-comment)
replace_line "$d/README.md" "](examples/policy/signing/README.md)" \
  "<!-- Hidden until it is ready:" "- [Signing](examples/policy/signing/README.md): a signed image." "-->"
expect_findings "reject: a README.md entry only inside a multi-line HTML comment" "$d" \
  "policy/signing is not listed in README.md"

d=$(new_repo reject-readme-in-inline-comment)
replace_line "$d/README.md" "](examples/policy/signing/README.md)" \
  "- Signing <!-- [Signing](examples/policy/signing/README.md) -->: a signed image."
expect_findings "reject: a README.md link only inside an inline HTML comment" "$d" \
  "policy/signing is not listed in README.md"

d=$(new_repo reject-readme-prose)
replace_line "$d/README.md" "](examples/policy/signing/README.md)" \
  "See [Signing](examples/policy/signing/README.md) for a signed image."
expect_findings "reject: a README.md link in prose, not a list item" "$d" \
  "policy/signing is not listed in README.md"

# --- must reject: a new sample, and conflict markers -----------------------------------------

d=$(new_repo reject-new-sample-unindexed)
mkdir -p "$d/examples/policy/cedar"
printf '# Cedar\n' >"$d/examples/policy/cedar/README.md"
git -C "$d" add examples/policy/cedar/README.md
expect_findings "reject: a new tracked sample listed nowhere" "$d" \
  "policy/cedar is not in the mkdocs.yml nav" \
  "policy/cedar is not linked in docs/ROADMAP.md" \
  "policy/cedar is not listed in README.md"

d=$(new_repo reject-conflict-markers)
replace_line "$d/README.md" "](examples/policy/signing/README.md)" \
  "<<<<<<< HEAD" \
  "- [Signing](examples/policy/signing/README.md): a signed image." \
  "=======" \
  "- [Cedar](examples/policy/cedar/README.md): a Cedar policy." \
  ">>>>>>> origin/main"
expect_findings "reject: conflict markers left in an index file" "$d" \
  "merge conflict marker left at README.md:9" "merge conflict marker left at README.md:13"

d=$(new_repo reject-bare-marker)
printf 'text\n>>>>>>>\n' >"$d/notes.txt"
git -C "$d" add notes.txt
expect_findings "reject: a bare closing marker in another tracked file" "$d" \
  "merge conflict marker left at notes.txt:2"

# --- must reject: the nav could not be read ----------------------------------------------------

# A stub awk on PATH fails only the nav reader (its program is the one that mentions
# sawnav) and runs the real awk for every other call, so the check gets past its own
# command checks and reaches the guard.
stub="$work/stub-bin"
mkdir -p "$stub"
real_awk=$(command -v awk)
{
  printf '#!/bin/sh\n'
  printf 'case "$*" in *sawnav*) echo "awk: simulated failure" >&2; exit 3 ;; esac\n'
  printf 'exec "%s" "$@"\n' "$real_awk"
} >"$stub/awk"
chmod +x "$stub/awk"
d=$(new_repo reject-nav-reader-fails)
saved_path=$PATH
PATH="$stub:$PATH"
want_stderr="awk: simulated failure"
expect_findings "reject: a nav reader that fails is a finding, not a pass" "$d" \
  "could not read the mkdocs.yml nav (awk exit 3)"
want_stderr=
PATH=$saved_path

# --- the fixture helper itself ---------------------------------------------------------------

d=$(new_repo fixture-replace-line)
if (replace_line "$d/README.md" "no line has this text" "x") 2>"$work/err"; then
  failed=$((failed + 1))
  echo "FAIL fixture: replace_line carried on when nothing matched"
elif ! grep -q '^fixture error: no line in ' "$work/err"; then
  failed=$((failed + 1))
  echo "FAIL fixture: replace_line stopped without saying why"
else
  pass "fixture: replace_line stops the test when nothing matches"
fi

# --- must refuse ----------------------------------------------------------------------------------

mkdir -p "$work/not-a-repo"
expect_refused "refuse: a folder that is not a git work tree" "not a git work tree" "$work/not-a-repo"
expect_refused "refuse: a folder that does not exist" "not a directory" "$work/does-not-exist"
expect_refused "refuse: an unknown option" "unknown option" --bogus
expect_refused "refuse: two arguments" "at most one argument" "$work" "$work"

d=$(new_repo refuse-subfolder)
expect_refused "refuse: a subfolder of a work tree" "is not the top of its git work tree" "$d/docs"

for f in mkdocs.yml docs/ROADMAP.md README.md; do
  d=$(new_repo "refuse-missing-$(basename "$f")")
  rm "$d/$f"
  expect_refused "refuse: no $f" "missing $f" "$d"
done

d=$(new_repo refuse-no-samples)
git -C "$d" rm -q --cached -r examples
expect_refused "refuse: no tracked samples at all" "no samples found" "$d"

mkdir -p "$work/loose"
cp "$CHECK" "$work/loose/check-sample-index.sh"
check_cmd="$work/loose/check-sample-index.sh"
expect_refused "refuse: no argument, and the script is outside any work tree" "not inside a git work tree"
check_cmd=$CHECK

echo
echo "test-check-sample-index: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
