"""Check a status update, post it to the maintainers' Slack channel, and confirm it landed.

    python3 post.py --show-config
    python3 post.py --text "one-line update"
    python3 post.py update.mrkdwn --text "one-line summary"   # blocks from the file
    python3 post.py ... --dry-run                             # print the command, post nothing

The channel, the people and the commands come from a local settings file,
~/.config/sample-eks-nitro-sandbox/slack.env (or the path in
SLACK_UPDATES_CONFIG), copied from assets/slack.env.example. The repository
is public, so those values never go in it.

SLACK_POST_COMMAND and SLACK_HISTORY_COMMAND are split like a shell command
line, then {channel}, {text} and {blocks} are replaced inside each word. No
shell runs, so a message can never become part of a command.

Exit codes: 0 posted and confirmed (or a dry run, or --show-config), 1 a
finding, a failed post or an unconfirmed one, 2 refused to run (nothing was
posted). Standard library only.
"""
import argparse
import json
import os
import re
import shlex
import subprocess
import sys

sys.dont_write_bytecode = True  # leave no __pycache__ in the skill folder
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_message  # noqa: E402
import make_blocks  # noqa: E402

DEFAULT_CONFIG = os.path.join("~", ".config", "sample-eks-nitro-sandbox", "slack.env")
REQUIRED = ("SLACK_CHANNEL_ID", "SLACK_POST_COMMAND", "SLACK_HISTORY_COMMAND")
PLACEHOLDER = re.compile(r"\{(channel|text|blocks)\}")
TS = re.compile(r'"ts"\s*:\s*"(\d+\.\d+)"')
TIMEOUT = 60


class Refused(Exception):
    """Nothing was posted, and nothing will be until the cause is fixed."""


def config_path():
    return os.path.expanduser(os.environ.get("SLACK_UPDATES_CONFIG") or DEFAULT_CONFIG)


def load_config(path):
    """Read KEY=value lines. Nothing is evaluated: a value is the text after the first '='."""
    if not os.path.isfile(path):
        raise Refused(f"no settings at {path}: copy assets/slack.env.example there and fill it "
                      "in, or comment on the GitHub issue instead")
    values = {}
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, sep, value = line.partition("=")
            if not sep or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key.strip()):
                raise Refused(f"{path}:{n}: expected KEY=value")
            values[key.strip()] = value.strip()
    missing = [k for k in REQUIRED if not values.get(k)]
    if missing:
        raise Refused(f"{path}: no value for {', '.join(missing)}")
    if not re.fullmatch(r"[A-Z0-9]+", values["SLACK_CHANNEL_ID"]):
        raise Refused(f"{path}: SLACK_CHANNEL_ID must be a Slack ID such as C0123ABCD")
    return values


def people(cfg):
    """SLACK_PEOPLE as [(name, id)], from 'Name=ID,Name=ID'."""
    found = []
    for pair in filter(None, (p.strip() for p in cfg.get("SLACK_PEOPLE", "").split(","))):
        name, sep, uid = pair.rpartition("=")
        if not sep or not name.strip() or not re.fullmatch(r"[A-Z0-9]+", uid.strip()):
            raise Refused(f"SLACK_PEOPLE entry {pair!r} is not Name=SlackUserID")
        found.append((name.strip(), uid.strip()))
    return found


def command(template, values, name):
    """Split the template like a shell would, then fill each word. Returns an argv list."""
    try:
        words = shlex.split(template)
    except ValueError as e:
        raise Refused(f"{name} cannot be split: {e}")
    if not words:
        raise Refused(f"{name} is empty")
    used = {m.group(1) for w in words for m in PLACEHOLDER.finditer(w)}
    missing = sorted(set(values) - used)
    if missing:
        raise Refused(f"{name} has no {', '.join('{' + m + '}' for m in missing)}")
    # One pass per word, so a value that contains "{text}" is never filled in again.
    return [PLACEHOLDER.sub(lambda m: values[m.group(1)], w) for w in words]


def run(argv):
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=TIMEOUT)
    except FileNotFoundError:
        raise Refused(f"command not found: {argv[0]}")
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out after {TIMEOUT}s"
    return done.returncode, done.stdout, done.stderr


def show(argv):
    """The argv for a person to read, with a long blocks argument shortened."""
    return " ".join(shlex.quote(a if len(a) <= 200 else a[:200] + "...") for a in argv)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("file", nargs="?", help="a .mrkdwn file with the full update")
    parser.add_argument("--text", help="the one-line message, or the summary for a file")
    parser.add_argument("--dry-run", action="store_true", help="print the command, post nothing")
    parser.add_argument("--show-config", action="store_true",
                        help="print the channel and the people to mention, then stop")
    args = parser.parse_args(argv)

    try:
        cfg = load_config(config_path())
        who = people(cfg)
        if args.show_config:
            print(f"channel: {cfg.get('SLACK_CHANNEL_NAME', '')} {cfg['SLACK_CHANNEL_ID']}".strip())
            for name, uid in who:
                print(f"mention {name} as <@{uid}>")
            return 0
        if not args.text:
            raise Refused("give --text: the one-line message, or the summary for a file")

        findings = check_message.check(args.text, "--text")
        if args.file:
            if not args.file.endswith(".mrkdwn"):
                raise Refused(f"{args.file} is not a .mrkdwn file")
            raw = check_message.read(args.file)
            if raw is None:
                raise Refused(f"cannot read {args.file}")
            found = make_blocks.problems(raw, args.file)
            if found:
                print("\n".join(found))
            parts = make_blocks.paragraphs(raw)
        else:
            found = []
            parts = [args.text.strip()]
        check_message.report(findings)
        if findings or found:
            print(f"post: {len(findings) + len(found)} finding(s); nothing posted")
            return 1
        blocks = [{"type": "section", "text": {"type": "mrkdwn", "text": p}} for p in parts]

        channel = cfg["SLACK_CHANNEL_ID"]
        post = command(cfg["SLACK_POST_COMMAND"],
                       {"channel": channel, "text": args.text,
                        "blocks": json.dumps(blocks, ensure_ascii=False)},
                       "SLACK_POST_COMMAND")
        history = command(cfg["SLACK_HISTORY_COMMAND"], {"channel": channel},
                          "SLACK_HISTORY_COMMAND")
        if args.dry_run:
            print(f"post: dry run, {len(blocks)} block(s); would run:\n{show(post)}")
            return 0

        rc, out, err = run(post)
        if rc != 0:
            print(f"post: the post command failed with exit {rc}:\n{(err or out).strip()}")
            return 1
        ts = TS.search(out)
        if not ts:
            print(f"post: posted, but the command printed no message ts, so it cannot be "
                  f"confirmed. Do not post again; check the channel.\n{out.strip()[:2000]}")
            return 1
        rc, hist, err = run(history)
        if rc == 0 and ts.group(1) in hist:
            print(f"post: posted and confirmed, ts={ts.group(1)}")
            return 0
        print(f"post: posted (ts={ts.group(1)}) but the newest message did not match. "
              f"Do not post again; check the channel.\n{(err or hist).strip()[:2000]}")
        return 1
    except Refused as e:
        print(f"post: refused: {e}; nothing was posted", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
