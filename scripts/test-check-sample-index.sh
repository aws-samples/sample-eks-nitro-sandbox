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
  done <"$f" >"$f.new" && mv "$f.new" "$f"
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
  if [ -s "$work/err" ]; then report_fail "$label: wrote to stderr"; return; fi
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

# --- must reject: README.md ----------------------------------------------------------------

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
