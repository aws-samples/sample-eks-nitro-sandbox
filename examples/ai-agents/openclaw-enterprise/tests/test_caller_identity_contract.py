"""Every sample script that changes AWS resources runs only as OPENCLAW_EXPECTED_CALLER_ARN.

The build scripts under build/ are not operator entry points: they run inside CodeBuild as the stack's own
service role. The behavioral wrong-role controls live with each script's contract tests.
"""

from __future__ import annotations

import pathlib
import re

SAMPLE = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = SAMPLE / "scripts"
# An AWS CLI call, in shell or in cleanup.sh's Python, whose action creates, deletes, changes or deploys.
MUTATING_AWS_CALL = re.compile(
    r'(?:\baws|"\$\{AWS\[@\]\}")\s+[a-z0-9]+\s+'
    r"(?:create|delete|put|update|deploy|tag|untag|attach|detach|associate|disassociate|modify)[a-z-]*"
    r'|self\.aws(?:_json)?\(\s*"[a-z0-9]+",\s*'
    r'"(?:create|delete|put|update|deploy|tag|untag|attach|detach|associate|disassociate|modify)[a-z-]*"'
)
ENTRY_POINTS = {
    "cleanup.sh",
    "manage-builder-repository.sh",
    "manage-image-build-stack.sh",
    "setup-agentgateway-pod-identity.sh",
}
CALLER_ARN_FORM = (
    "^arn:aws[a-z-]*:(iam::[0-9]{12}:user/[A-Za-z0-9+=,.@_/-]+"
    "|sts::[0-9]{12}:assumed-role/[A-Za-z0-9+=,.@_-]+)$"
)
SHELL_COMPARISON = (
    '.Arn == $expected\n'
    "{indent}or (\n"
    '{indent}  ($expected | contains(":assumed-role/"))\n'
    '{indent}  and (.Arn | startswith($expected + "/"))\n'
    '{indent}  and (.Arn | ltrimstr($expected + "/") | test("^[A-Za-z0-9+=,.@_-]{{2,64}}$"))\n'
    "{indent})"
)


def _source(name: str) -> str:
    return (SCRIPTS / name).read_text(encoding="utf-8")


def test_the_aws_mutating_entry_points_are_exactly_the_checked_scripts() -> None:
    mutating = {
        path.name
        for path in SCRIPTS.glob("*.sh")
        if MUTATING_AWS_CALL.search(path.read_text(encoding="utf-8"))
    }

    assert mutating == ENTRY_POINTS
    for name in ENTRY_POINTS:
        assert "OPENCLAW_EXPECTED_CALLER_ARN" in _source(name), name


def test_each_entry_point_compares_the_full_caller_before_its_first_change() -> None:
    for name in ("manage-builder-repository.sh", "manage-image-build-stack.sh"):
        source = _source(name)
        check = source.split("require_expected_caller() {", 1)[1].split("\n}\n", 1)[0]
        assert CALLER_ARN_FORM in check, name
        assert "aws sts get-caller-identity --output json" in check, name
        assert SHELL_COMPARISON.format(indent="      ") in check, name
        # Called once in the main flow, before either operation runs.
        assert source.count("\nrequire_expected_caller\n") == 1, name
        assert source.index("\nrequire_expected_caller\n") < source.index(
            '\nif [[ "$action" == create ]]; then\n'
        ), name

    pod_identity = _source("setup-agentgateway-pod-identity.sh")
    check = pod_identity.split('expected_caller="${OPENCLAW_EXPECTED_CALLER_ARN:-}"', 1)[1]
    check = check.split("\ncluster_json=", 1)[0]
    assert CALLER_ARN_FORM in check
    assert SHELL_COMPARISON.format(indent="    ") in check
    assert "<<<\"${caller_json}\"" in check
    first_change = min(
        pod_identity.index(action)
        for action in ("iam create-role", "iam put-role-policy", "eks create-pod-identity-association")
    )
    assert pod_identity.index('expected_caller="${OPENCLAW_EXPECTED_CALLER_ARN:-}"') < first_change

    cleanup = _source("cleanup.sh")
    check = cleanup.split("def validate_expected_caller(self):", 1)[1].split("\n    def ", 1)[0]
    assert 'os.environ.get("OPENCLAW_EXPECTED_CALLER_ARN", "")' in check
    assert 'self.aws_json("sts", "get-caller-identity").get("Arn")' in check
    assert "arn != expected and not (" in check
    run = cleanup.split("    def run(self):", 1)[1]
    # The first change in a cleanup run is the freeze recovery; the caller check comes first.
    assert run.index("self.validate_expected_caller()") < run.index("self.recover_freeze()")


def test_readme_names_the_expected_caller_once() -> None:
    readme = (SAMPLE / "README.md").read_text(encoding="utf-8")

    assert readme.count("export OPENCLAW_EXPECTED_CALLER_ARN=") == 1
    assert (
        "export OPENCLAW_EXPECTED_CALLER_ARN="
        "'arn:aws:sts::<12-digit-account-id>:assumed-role/<role-name>'"
    ) in readme
