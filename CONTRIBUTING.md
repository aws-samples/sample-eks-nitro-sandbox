# Contributing Guidelines

Thank you for your interest in contributing to our project. Whether it's a bug report, new feature, correction, or additional
documentation, we greatly value feedback and contributions from our community.

Please read through this document before submitting any issues or pull requests to ensure we have all the necessary
information to effectively respond to your bug report or contribution.


## Reporting Bugs/Feature Requests

We welcome you to use the GitHub issue tracker to report bugs or suggest features.

When filing an issue, please check existing open, or recently closed, issues to make sure somebody else hasn't already
reported the issue. Please try to include as much information as you can. Details like these are incredibly useful:

* A reproducible test case or series of steps
* The version of our code being used
* Any modifications you've made relevant to the bug
* Anything unusual about your environment or deployment


## Contributing via Pull Requests
Contributions via pull requests are much appreciated. Before sending us a pull request, please ensure that:

1. You are working against the latest source on the *main* branch.
2. You check existing open, and recently merged, pull requests to make sure someone else hasn't addressed the problem already.
3. You open an issue to discuss any significant work - we would hate for your time to be wasted.

To send us a pull request, please:

1. Fork the repository.
2. Modify the source; please focus on the specific change you are contributing. If you also reformat all the code, it will be hard for us to focus on your change.
3. Ensure local tests pass.
4. Commit to your fork using clear commit messages.
5. Send us a pull request, answering any default questions in the pull request interface.
6. Pay attention to any automated CI failures reported in the pull request, and stay involved in the conversation.

GitHub provides additional document on [forking a repository](https://help.github.com/articles/fork-a-repo/) and
[creating a pull request](https://help.github.com/articles/creating-a-pull-request/).


## Adding a sample
A new sample starts as a spec in a GitHub issue: open one with the **Sample spec** issue form. Implementation starts
once the spec is agreed, and the pull request that implements it says `Closes #<issue>`. [AGENTS.md](AGENTS.md) lists
the rules every sample follows, for you and for any coding agent you use, and the agent skills in `.agents/skills/`
walk through writing the spec, the sample and its page.


## Finding contributions to work on
Looking at the existing issues is a great way to find something to contribute on. As our projects, by default, use the default GitHub issue labels (enhancement/bug/duplicate/help wanted/invalid/question/wontfix), looking at any 'help wanted' issues is a great place to start.

Skip issues that are assigned or labeled `in progress` (someone is working on them) or `blocked` (waiting on something outside this repository). Before you start on an issue, comment on it, then assign it to yourself and add the `in progress` label; if you cannot, ask a maintainer in your comment to do it for you. [AGENTS.md](AGENTS.md) has the commands.


## Code of Conduct
This project has adopted the [Amazon Open Source Code of Conduct](https://aws.github.io/code-of-conduct).
For more information see the [Code of Conduct FAQ](https://aws.github.io/code-of-conduct-faq) or contact
opensource-codeofconduct@amazon.com with any additional questions or comments.


## Security scanning
Every commit and every pull request is scanned with the [Automated Security Helper](https://github.com/awslabs/automated-security-helper)
(ASH) v3.7.1, configured in `.ash/.ash.yaml`. A finding of severity Critical or High that no suppression covers blocks
the commit, and fails the **ASH Security Scan** workflow, which runs on every pull request to *main*.

To set it up, install pre-commit and ASH in a virtual environment under `tmp/` (ASH v3.7.1 supports Python 3.10 to 3.12),
then install the hooks:

```bash
python3.12 -m venv tmp/venv-ash
tmp/venv-ash/bin/pip install pre-commit 'git+https://github.com/awslabs/automated-security-helper.git@v3.7.1'
tmp/venv-ash/bin/pre-commit install
```

`pre-commit install` writes `.git/hooks/pre-commit`, which calls the Python in `tmp/venv-ash`, so `git commit` runs the
hooks without activating the environment. If you delete `tmp/venv-ash`, set it up again. On each commit the hooks check
for conflict markers, private keys and AWS credentials, and run a fast ASH scan. Two of them also fix trailing whitespace and missing final newlines; `.pre-commit-config.yaml` says what each hook does.

ASH and pre-commit download scanners and hook environments into your home folder by default. On a shared machine, keep
them under `tmp/` by setting these in the shell you commit and scan from:

```bash
export ASH_BIN_PATH="$PWD/tmp/ash/bin" UV_TOOL_DIR="$PWD/tmp/ash/uv-tools" \
  UV_TOOL_BIN_DIR="$PWD/tmp/ash/uv-bin" PRE_COMMIT_HOME="$PWD/tmp/pre-commit"
```

To run the full scan that CI runs, from the repository root:

```bash
source tmp/venv-ash/bin/activate
ash --mode local --config .ash/.ash.yaml
```

With uv you can skip the virtual environment for this scan:
`uvx --python 3.12 --from 'git+https://github.com/awslabs/automated-security-helper.git@v3.7.1' ash --mode local --config .ash/.ash.yaml`.
Reports go to `.ash/ash_output/`, which git ignores; start with `.ash/ash_output/reports/ash.summary.md`.

`git commit --no-verify` skips the hooks. Use it only in an emergency: the workflow still scans the pull request and
reports the finding.

If a finding is a false positive or an accepted risk, add a suppression under `global_settings` in `.ash/.ash.yaml`, with
the rule ID from the report, the narrowest path that covers it, a reason and an expiration date, and explain it in the
pull request description:

```yaml
global_settings:
  suppressions:
    - rule_id: 'B602'
      path: 'examples/<section>/<sample>/scripts/run.py'
      line_start: 12
      line_end: 14
      reason: 'The command is a fixed list; no reader input reaches the shell'
      expiration: '2027-06-30'
```

`line_start` and `line_end` are optional. After the expiration date the finding counts again.


## Security issue notifications
If you discover a potential security issue in this project we ask that you notify AWS/Amazon Security via our [vulnerability reporting page](http://aws.amazon.com/security/vulnerability-reporting/). Please do **not** create a public github issue.


## Licensing

See the [LICENSE](LICENSE) file for our project's licensing. We will ask you to confirm the licensing of your contribution.
