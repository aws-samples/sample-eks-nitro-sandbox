"""Check a Slack status update about this repository before posting it.

    python3 check_message.py FILE [FILE ...]
    python3 check_message.py --text "one-line message"

Prints one FINDING line per problem: a bare issue number, a plain @ mention,
Markdown where Slack expects mrkdwn, a 12-digit account ID, an em dash.
Text inside Slack entities (<url|label>, <@ID>) and inside code is not read
as message text, so a linked #37 or a `#5` in code is fine.

Exit codes: 0 clean, 1 at least one finding, 2 refused to run (nothing was
checked). Standard library only.
"""
import argparse
import re
import sys

# Slack entities: <url|label>, <@U123>, <#C123>, <!here>. What is inside one is not text.
ENTITY = re.compile(r"<[^<>\n]*>")
CODE_BLOCK = re.compile(r"```.*?```", re.S)
CODE_SPAN = re.compile(r"`[^`\n]*`")

# Rules read the text with entities and code removed.
TEXT_RULES = [
    ("bare-issue", re.compile(r"(?<![\w&/])#\d+\b"),
     "link it as <https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/N|#N>; "
     "Slack turns a bare #N into a link to any channel named N"),
    ("plain-mention", re.compile(r"(?<![\w.])@[A-Za-z][\w.-]*"),
     "mention as <@ID> from the people table; a plain @name notifies nobody"),
    ("markdown-bold", re.compile(r"\*\*[^*\n]+\*\*"),
     "Slack bold is *one asterisk*; **two** shows up literally"),
    ("markdown-link", re.compile(r"\[[^\]\n]+\]\([^)\s]+\)"),
     "write a link as <url|label>; [label](url) shows up literally"),
    ("markdown-heading", re.compile(r"(?m)^#{1,6} "),
     "Slack has no headings; use a *bold* line"),
]
# Rules read the raw text, links included: an account ID in a URL is still published.
RAW_RULES = [
    ("account-id", re.compile(r"(?<!\d)\d{12}(?!\d)"),
     "write <ACCOUNT_ID>, never a real account ID"),
    ("em-dash", re.compile("\u2014"),
     "use a colon, a comma or two sentences"),
]


def _blank(match):
    """Replace a removed span with its newlines only, so line numbers stay right."""
    return "\n" * match.group(0).count("\n")


def message_text(raw):
    """The message as Slack shows it as text: no code, no entity contents."""
    text = CODE_BLOCK.sub(_blank, raw)
    text = CODE_SPAN.sub("", text)
    return ENTITY.sub("", text)


def check(raw, source="text"):
    """Return a list of (source, line, code, matched, advice) for one message."""
    found = []
    for text, rules in ((message_text(raw), TEXT_RULES), (raw, RAW_RULES)):
        for code, pattern, advice in rules:
            for m in pattern.finditer(text):
                line = text.count("\n", 0, m.start()) + 1
                found.append((source, line, code, m.group(0).strip(), advice))
    return sorted(found, key=lambda f: (f[0], f[1], f[2]))


def report(findings):
    for source, line, code, matched, advice in findings:
        print(f"FINDING: {source}:{line}: {code}: {matched!r}: {advice}")


def read(path):
    """Return the file's text, or None after printing why it cannot be read."""
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError) as e:
        print(f"check_message: refused: cannot read {path}: {e}", file=sys.stderr)
        return None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("files", nargs="*", help=".mrkdwn files to check")
    parser.add_argument("--text", action="append", default=[],
                        help="a message given inline, such as the --message fallback line")
    args = parser.parse_args(argv)
    if not args.files and not args.text:
        print("check_message: refused: give a FILE or --text; nothing was checked", file=sys.stderr)
        return 2

    sources = []
    for path in args.files:
        raw = read(path)
        if raw is None:
            print("check_message: nothing was checked", file=sys.stderr)
            return 2
        sources.append((path, raw))
    sources += [("text", t) for t in args.text]

    findings = [f for source, raw in sources for f in check(raw, source)]
    report(findings)
    if findings:
        print(f"check_message: {len(findings)} finding(s)")
        return 1
    print(f"check_message: OK, {len(sources)} message(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
