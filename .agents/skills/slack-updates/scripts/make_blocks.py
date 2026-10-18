"""Turn a Slack mrkdwn file into Block Kit section blocks, after checking it.

    python3 make_blocks.py update.mrkdwn     # writes update.blocks.json beside it

Each paragraph (text between blank lines) becomes one section block. Writes
nothing when check_message.py finds a problem, when a paragraph is longer than
Slack's 3000-character limit for a section, or when there would be more than
Slack's 50 blocks. A blocks file left from an earlier run is removed then, so
it cannot be posted by mistake.

Exit codes: 0 written, 1 a finding, 2 refused to run. Standard library only.
"""
import json
import os
import sys

sys.dont_write_bytecode = True  # leave no __pycache__ in the skill folder
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_message  # noqa: E402

MAX_SECTION = 3000
MAX_BLOCKS = 50


def paragraphs(raw):
    return [p.strip() for p in raw.replace("\r\n", "\n").split("\n\n") if p.strip()]


def problems(raw, source):
    """Every reason not to write the blocks, as finding lines."""
    lines = [f"FINDING: {s}:{n}: {code}: {m!r}: {advice}"
             for s, n, code, m, advice in check_message.check(raw, source)]
    parts = paragraphs(raw)
    if not parts:
        lines.append(f"FINDING: {source}: empty: the file has no text")
    for i, part in enumerate(parts, 1):
        if len(part) > MAX_SECTION:
            lines.append(f"FINDING: {source}: paragraph {i} is {len(part)} characters, "
                         f"over Slack's {MAX_SECTION}; split it with a blank line")
    if len(parts) > MAX_BLOCKS:
        lines.append(f"FINDING: {source}: {len(parts)} paragraphs, over Slack's {MAX_BLOCKS} blocks")
    return lines


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1 or not argv[0].endswith(".mrkdwn"):
        print("make_blocks: refused: usage: make_blocks.py <name>.mrkdwn", file=sys.stderr)
        return 2
    src = argv[0]
    out = src[: -len(".mrkdwn")] + ".blocks.json"
    raw = check_message.read(src)
    if raw is None:
        return 2

    found = problems(raw, src)
    if found:
        print("\n".join(found))
        if os.path.exists(out):
            os.unlink(out)
            print(f"make_blocks: removed {out} from an earlier run")
        print(f"make_blocks: {len(found)} finding(s); nothing written")
        return 1

    blocks = [{"type": "section", "text": {"type": "mrkdwn", "text": p}} for p in paragraphs(raw)]
    with open(out, "w", encoding="utf-8") as f:
        json.dump(blocks, f, ensure_ascii=False)
    print(f"make_blocks: {len(blocks)} block(s) written to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
