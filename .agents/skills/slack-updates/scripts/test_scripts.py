"""Tests for this skill's scripts, each check proved both ways.

    python3 .agents/skills/slack-updates/scripts/test_scripts.py

Every rule is exercised on a message it must accept (the example update and
look-alikes that are fine) and on one broken in exactly one way that it must
reject. A check that only ever saw bad input could be rejecting everything;
one that only saw good input could be accepting everything. post.py runs
against a stand-in Slack tool written here, so no test posts anything.
Standard library only.
"""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # leave no __pycache__ in the skill folder
sys.path.insert(0, HERE)
import check_message  # noqa: E402
import make_blocks  # noqa: E402
import post  # noqa: E402

EXAMPLE = os.path.join(HERE, "..", "assets", "example-update.mrkdwn")
SETTINGS_EXAMPLE = os.path.join(HERE, "..", "assets", "slack.env.example")
ISSUES = "https://github.com/aws-samples/sample-eks-nitro-sandbox/issues"

# A stand-in Slack tool. "post" records its arguments and prints a ts; "history" prints
# the ts of the last post, or another one when told to. Exit 3 when told to fail.
FAKE_TOOL = r'''
import json, os, sys
state = os.environ["FAKE_STATE"]
if sys.argv[1] == "post":
    with open(state, "w") as f:
        json.dump(sys.argv[2:], f)
    if os.environ.get("FAKE_FAIL"):
        print("channel_not_found", file=sys.stderr)
        sys.exit(3)
    print(json.dumps({"ok": True, "ts": "1700000000.000100"}) if not os.environ.get("FAKE_NO_TS") else "{}")
else:
    ts = os.environ.get("FAKE_HISTORY_TS", "1700000000.000100")
    print(json.dumps({"messages": [{"ts": ts, "channel": sys.argv[2]}]}))
'''


def codes(text):
    return {f[2] for f in check_message.check(text)}


def run(main, argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        rc = main(argv)
    return rc, out.getvalue()


class CheckMessage(unittest.TestCase):
    def test_example_is_clean(self):
        with open(EXAMPLE, encoding="utf-8") as f:
            self.assertEqual(check_message.check(f.read()), [])

    def test_rejects_each_rule(self):
        cases = {
            # From a real update: a bare #9 became a link to an unrelated channel.
            "bare-issue": "OpenAI Managed Agents (#9) now goes in examples/managed-agents/.",
            "plain-mention": "@rodrigo the roadmap is merged",
            "markdown-bold": "**the new roadmap is merged**",
            "markdown-link": "merged in [the roadmap PR](https://github.com/x/y/pull/44)",
            "markdown-heading": "## Changes so far",
            "account-id": "deployed to 123456789012 in us-west-2",
            "em-dash": "merged \u2014 next is the OpenShell sample",
        }
        for code, text in cases.items():
            with self.subTest(code=code):
                self.assertEqual(codes(text), {code})

    def test_accepts_look_alikes(self):
        fine = [
            f"<{ISSUES}/37|#37> and <{ISSUES}/43|issue #43>",  # numbers inside a link label
            "<@UEXAMPLE01> <@UEXAMPLE02> please review",  # real mentions
            "the folder is `#5`, see:\n```\nkubectl get pods # 12 pods\n```",  # code
            "mail someone@example.com about it",  # an address, not a mention
            "it&#39;s merged",  # an HTML entity
            "*bold* and _italic_ and a ts 1792249565.271949",  # mrkdwn, a 10-digit number
            "see https://github.com/x/y/blob/main/README.md#step-3",  # a fragment
        ]
        for text in fine:
            with self.subTest(text=text):
                self.assertEqual(check_message.check(text), [])

    def test_account_id_inside_a_link_is_still_found(self):
        self.assertEqual(codes("<https://example.com/123456789012/x|the role>"), {"account-id"})

    def test_line_numbers_survive_code_blocks(self):
        text = "```\none\ntwo\n```\n#7 is next"
        self.assertEqual([f[1] for f in check_message.check(text)], [5])

    def test_cli_exit_codes(self):
        self.assertEqual(run(check_message.main, ["--text", "<@UEXAMPLE01> ok"])[0], 0)
        self.assertEqual(run(check_message.main, ["--text", "PR #47 is up"])[0], 1)
        self.assertEqual(run(check_message.main, [])[0], 2)
        self.assertEqual(run(check_message.main, ["/nonexistent/x.mrkdwn"])[0], 2)


class MakeBlocks(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.src = os.path.join(self.dir.name, "update.mrkdwn")
        self.out = os.path.join(self.dir.name, "update.blocks.json")

    def tearDown(self):
        self.dir.cleanup()

    def write(self, text):
        with open(self.src, "w", encoding="utf-8") as f:
            f.write(text)

    def test_writes_one_section_per_paragraph(self):
        with open(EXAMPLE, encoding="utf-8") as f:
            self.write(f.read())
        self.assertEqual(run(make_blocks.main, [self.src])[0], 0)
        with open(self.out, encoding="utf-8") as f:
            blocks = json.load(f)
        self.assertEqual(len(blocks), 3)
        self.assertEqual({b["text"]["type"] for b in blocks}, {"mrkdwn"})

    def test_refuses_a_finding_and_removes_stale_output(self):
        with open(self.out, "w") as f:
            f.write("[]")  # left from an earlier, good run
        self.write("PR #47 is up for review")
        rc, out = run(make_blocks.main, [self.src])
        self.assertEqual(rc, 1)
        self.assertIn("bare-issue", out)
        self.assertFalse(os.path.exists(self.out))

    def test_section_and_block_limits(self):
        for text, rc in (("a" * 3001, 1), ("a" * 3000, 0),
                         ("\n\n".join(["x"] * 51), 1), ("\n\n".join(["x"] * 50), 0)):
            with self.subTest(length=len(text)):
                self.write(text)
                self.assertEqual(run(make_blocks.main, [self.src])[0], rc)

    def test_refuses_empty_and_bad_arguments(self):
        self.write("\n\n")
        self.assertEqual(run(make_blocks.main, [self.src])[0], 1)
        self.assertEqual(run(make_blocks.main, [])[0], 2)
        self.assertEqual(run(make_blocks.main, [os.path.join(self.dir.name, "update.txt")])[0], 2)
        self.assertEqual(run(make_blocks.main, [os.path.join(self.dir.name, "none.mrkdwn")])[0], 2)


class Post(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        d = self.dir.name
        self.tool = os.path.join(d, "fake_slack.py")
        with open(self.tool, "w") as f:
            f.write(FAKE_TOOL)
        self.state = os.path.join(d, "posted.json")
        self.settings = os.path.join(d, "slack.env")
        self.write_settings()
        self.env = mock.patch.dict(os.environ, {"SLACK_UPDATES_CONFIG": self.settings,
                                                "FAKE_STATE": self.state})
        self.env.start()
        for key in ("FAKE_FAIL", "FAKE_NO_TS", "FAKE_HISTORY_TS"):
            os.environ.pop(key, None)

    def tearDown(self):
        self.env.stop()
        self.dir.cleanup()

    def write_settings(self, **override):
        tool = f"{sys.executable} {self.tool}"
        values = {
            "SLACK_CHANNEL_NAME": "maintainers",
            "SLACK_CHANNEL_ID": "C0EXAMPLE",
            "SLACK_PEOPLE": "Ada Lovelace=UEXAMPLE01,Grace Hopper=UEXAMPLE02",
            "SLACK_POST_COMMAND": f"{tool} post --channel {{channel}} --message {{text}} --blocks {{blocks}}",
            "SLACK_HISTORY_COMMAND": f"{tool} history {{channel}}",
        }
        values.update(override)
        with open(self.settings, "w") as f:
            f.write("# test settings\n\n")
            f.writelines(f"{k}={v}\n" for k, v in values.items() if v is not None)

    def posted(self):
        if not os.path.exists(self.state):
            return None
        with open(self.state) as f:
            return json.load(f)

    def test_posts_confirms_and_keeps_text_one_argument(self):
        text = "<@UEXAMPLE01> ready; $(touch pwned) `echo hi` {blocks}"
        rc, out = run(post.main, ["--text", text])
        self.assertEqual(rc, 0, out)
        self.assertIn("posted and confirmed, ts=1700000000.000100", out)
        args = self.posted()
        self.assertEqual(args[:4], ["--channel", "C0EXAMPLE", "--message", text])
        blocks = json.loads(args[5])
        self.assertEqual(blocks[0]["text"]["text"], text)
        self.assertFalse(os.path.exists(os.path.join(os.getcwd(), "pwned")))

    def test_posts_a_file_as_blocks(self):
        rc, out = run(post.main, [EXAMPLE, "--text", "roadmap update"])
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(json.loads(self.posted()[5])), 3)

    def test_a_finding_posts_nothing(self):
        for argv in (["--text", "PR #47 is up"],
                     [EXAMPLE, "--text", "**roadmap** update"]):
            with self.subTest(argv=argv):
                rc, out = run(post.main, argv)
                self.assertEqual(rc, 1)
                self.assertIn("nothing posted", out)
                self.assertIsNone(self.posted())

    def test_dry_run_posts_nothing(self):
        rc, out = run(post.main, ["--text", "<@UEXAMPLE01> ready", "--dry-run"])
        self.assertEqual(rc, 0)
        self.assertIn("would run", out)
        self.assertIsNone(self.posted())

    def test_failed_and_unconfirmed_posts(self):
        os.environ["FAKE_FAIL"] = "1"
        rc, out = run(post.main, ["--text", "ready"])
        self.assertEqual(rc, 1)
        self.assertIn("channel_not_found", out)
        del os.environ["FAKE_FAIL"]
        os.environ["FAKE_HISTORY_TS"] = "1700000000.999999"
        rc, out = run(post.main, ["--text", "ready"])
        self.assertEqual(rc, 1)
        self.assertIn("Do not post again", out)
        del os.environ["FAKE_HISTORY_TS"]
        os.environ["FAKE_NO_TS"] = "1"
        rc, out = run(post.main, ["--text", "ready"])
        self.assertEqual(rc, 1)
        self.assertIn("cannot be confirmed", out)

    def test_show_config(self):
        rc, out = run(post.main, ["--show-config"])
        self.assertEqual(rc, 0)
        self.assertIn("mention Ada Lovelace as <@UEXAMPLE01>", out)

    def test_refusals_post_nothing(self):
        cases = {
            "no settings": {"SLACK_UPDATES_CONFIG": os.path.join(self.dir.name, "absent.env")},
        }
        for name, env in cases.items():
            with self.subTest(name), mock.patch.dict(os.environ, env):
                self.assertEqual(run(post.main, ["--text", "ready"])[0], 2)
        broken = {
            "missing key": {"SLACK_HISTORY_COMMAND": None},
            "bad channel id": {"SLACK_CHANNEL_ID": "c-0 example"},
            "bad people": {"SLACK_PEOPLE": "Ada"},
            "post without {blocks}": {"SLACK_POST_COMMAND": f"{sys.executable} {self.tool} post {{channel}} {{text}}"},
            "unbalanced quote": {"SLACK_POST_COMMAND": "tool 'post {channel} {text} {blocks}"},
            "unknown tool": {"SLACK_POST_COMMAND": "no-such-slack-tool-xyz {channel} {text} {blocks}"},
        }
        for name, override in broken.items():
            with self.subTest(name):
                self.write_settings(**override)
                self.assertEqual(run(post.main, ["--text", "ready"])[0], 2)
                self.assertIsNone(self.posted())
        self.write_settings()
        self.assertEqual(run(post.main, [])[0], 2)
        self.assertEqual(run(post.main, ["notes.txt", "--text", "ready"])[0], 2)

    def test_settings_example_is_only_placeholders(self):
        with open(SETTINGS_EXAMPLE, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    key, _, value = line.partition("=")
                    self.assertEqual(value, "", f"{key} has a value in the example")


if __name__ == "__main__":
    unittest.main(verbosity=1)
