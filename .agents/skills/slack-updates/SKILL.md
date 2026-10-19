---
name: slack-updates
description: Post a status update about this repository to the maintainers' Slack channel - a pull request opened or merged, a sample available, a blocker - with mentions that notify, issue numbers that stay links, and a check that the post landed. Use when asked to tell the team, post an update, or notify a maintainer. Needs the local settings file a maintainer gives you; without it, comment on the GitHub issue instead.
---

# Post a status update to the maintainers' Slack channel

The maintainers follow this repository in a Slack channel. This skill writes an update,
checks it, posts it with your own Slack command-line tool and confirms it landed. The
channel, the people and the commands are in a local settings file, because they belong to
your Slack workspace and the repository must not hold them (see the security rules in
`AGENTS.md`).

No settings file? Then you are not set up to post: comment on the spec issue with
`gh issue comment <number> --repo aws-samples/sample-eks-nitro-sandbox --body-file <file>`
instead, and stop here.

`assets/example-update.mrkdwn` is the model: a first line that mentions the reviewers and
says what happened with a link, bullets with one bold lead each, and a short paragraph for
the reason behind a decision.

| File (in this skill's folder) | What it is for |
|---|---|
| `assets/slack.env.example` | The settings file to copy and fill in. |
| `assets/example-update.mrkdwn` | The model update, to copy the shape from. |
| `scripts/post.py` | Checks an update, posts it with the commands in your settings, and confirms it landed. |
| `scripts/check_message.py` | The message checks on their own: bare issue numbers, plain `@` mentions, Markdown instead of Slack mrkdwn, account IDs, em dashes. |
| `scripts/make_blocks.py` | Turns a `.mrkdwn` file into Block Kit sections after the same checks, to preview them. |
| `scripts/test_scripts.py` | Proves the checks both ways; run it after changing a script. |

Run the commands below from the repository root. The scripts use only Python's standard
library.

## Quick start

**Set up once per machine.** Copy the example and fill it in with the values a maintainer
gives you:

```bash
mkdir -p ~/.config/sample-eks-nitro-sandbox
cp .agents/skills/slack-updates/assets/slack.env.example ~/.config/sample-eks-nitro-sandbox/slack.env
python3 .agents/skills/slack-updates/scripts/post.py --show-config
```

`--show-config` prints the channel and each person as the `<@ID>` to write. Put the file
somewhere else with `SLACK_UPDATES_CONFIG=<path>`.

**Post an update** with this loop:

1. Write it to `tmp/slack/<name>.mrkdwn` (`tmp/` is gitignored), with a blank line between
   parts; each paragraph becomes one Slack section.
2. Dry run it: `python3 .agents/skills/slack-updates/scripts/post.py tmp/slack/<name>.mrkdwn --text "<one-line summary>" --dry-run`.
   It prints every finding, or the command it would run. `--text` is what a notification
   shows, so it is checked too.
3. Fix each finding and repeat, then run the same command without `--dry-run`, as its own
   command.
4. Read the result: `posted and confirmed, ts=...` means the new message is the newest in
   the channel.

For a one-line update, leave out the file: `post.py --text "<message>"`.

## What a message may say

`check_message.py` catches the first five of these.

- **Mention as `<@ID>`**, from `--show-config`, never `@name`. Why: a plain `@name` is only
  text and notifies nobody.
- **Write issue and pull request numbers as links**:
  `<https://github.com/aws-samples/sample-eks-nitro-sandbox/issues/15|#15>`. Why: Slack turns a
  bare `#9` into a link to any channel whose name is `9`; one update linked two unrelated
  channels that way.
- **Slack mrkdwn, not Markdown**: `*bold*`, `_italic_`, `` `code` ``, `<url|label>`, `•` for
  bullets. Why: `**bold**`, `[label](url)` and `## headings` show up literally.
- **No account IDs, keys or tokens.** Write `<ACCOUNT_ID>`. Why: a channel is wider than an
  account's owners.
- **No em dashes.** Use a colon, a comma or two sentences, as on the site.
- **Say what happened and what you need**, with the link. Leave out how the work was done:
  check counts, review rounds, retries.

## Post

- **Post only through `post.py`.** Why: it runs the checks first, and it fills the message
  into the command as one argument with no shell, so no text in a message can run.
- **Run the post as its own command**, not chained with the command that writes the file.
  Why: the post then reads a file that may not be written yet.
- **Do not post a test message.** The channel is shared; `--dry-run` and the tests are the
  test.
- **Never post again after a post that printed `posted`**, even an unconfirmed one. Read
  the channel first. Why: a repeat is a duplicate everyone is notified of.
- If the post command fails, report its exact error rather than trying another tool.

## When to post

Post when something the maintainers can act on happens: a pull request opened for review, a
pull request merged, a sample available, a blocker that needs someone. Not for each commit or
check run. One message per event.

Not when you start work. Comment on the spec issue instead, so the plan is recorded where
the review happens, and post when there is a pull request to look at.

## The settings file

| Key | What it holds |
|---|---|
| `SLACK_CHANNEL_NAME` | The channel's name, for people reading `--show-config`. |
| `SLACK_CHANNEL_ID` | The channel's ID, which the commands use. |
| `SLACK_PEOPLE` | Who may be mentioned, as `Name=SlackUserID` pairs separated by commas. |
| `SLACK_POST_COMMAND` | Your Slack tool's post command, with `{channel}`, `{text}` and `{blocks}`. |
| `SLACK_HISTORY_COMMAND` | Its command that prints the channel's newest message as JSON, with `{channel}`. |

Each command is split like a shell command line, so quote a word that holds spaces or
JSON, then each placeholder is filled in as part of its word. Nothing is run by a shell.
`post.py` confirms a post by finding the `"ts"` its post command printed in what the
history command prints.
